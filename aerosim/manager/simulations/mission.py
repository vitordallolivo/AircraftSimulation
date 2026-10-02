"""Missão completa em trechos com checkpoints.

    A = piloto automático liga (h_t)     B = início da perna 1     C = início da perna da soltura
O usuário escolhe de onde começar (chão ou um checkpoint já salvo) e até onde ir. Com a
soltura de carga, o manager acha por bisseção, a partir de C, onde soltar para a carga
cair no alvo, e só então termina a missão.
"""
from __future__ import annotations

import numpy as np

from aerosim.interfaces.backend import LogChunk
from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.mission import MissionEvent

from ..analysis import columns, stage_table
from ..runner import Runner, Stop
from .base import SimulationBase

STOPS = ("A (piloto liga)", "B (início da perna 1)", "C (perna da soltura)", "fim")


class MissionSimulation(SimulationBase):
    name = "mission"
    title = "Missão"
    description = "Circuito inteiro (decolagem, curvas, soltura de carga, pouso) com checkpoints A, B, C."

    def parameters(self):
        return [ParamSpec("start", "Começar de", "chão", kind="choice", choices=("chão", "A", "B", "C")),
                ParamSpec("until", "Rodar até", "fim", kind="choice", choices=STOPS),
                ParamSpec("target", "Acertar o alvo com a carga", True, kind="bool"),
                ParamSpec("target_n", "Alvo (norte)", 0.0, unit="m"),
                ParamSpec("iters", "Iterações da bisseção", 8, kind="int", minimum=2, maximum=20),
                ParamSpec("slosh", "Sloshing", True, kind="bool"),
                ParamSpec("gust", "Rajada", False, kind="bool"),
                ParamSpec("chunk", "Fatia de tempo real", 0.5, minimum=0.05, maximum=10, unit="s")]

    def plots(self):
        return [PlotSpec("xy", "Trajetória (vista de cima)", "e", ("n", "pk_n"), "leste (m)", "norte (m)"),
                PlotSpec("h", "Altura", "t", ("h", "href"), "t (s)", "m"),
                PlotSpec("V", "Velocidade", "t", ("Va", "Vref"), "t (s)", "m/s"),
                PlotSpec("ang", "Atitude", "t", ("phi", "theta", "alpha"), "t (s)", "graus"),
                PlotSpec("cmd", "Comandos", "t", ("de", "da", "dr"), "t (s)", "graus"),
                PlotSpec("thr", "Acelerador", "t", ("thr",), "t (s)", "—"),
                PlotSpec("motor", "Potência elétrica", "t", ("P",), "t (s)", "W"),
                PlotSpec("slosh", "Sloshing (tanque 1)", "t", ("slosh_x_0", "slosh_y_0"), "t (s)", "graus"),
                PlotSpec("cg", "Posição do CG", "t", ("xcg", "zcg"), "t (s)", "m"),
                PlotSpec("massa", "Massa", "t", ("m",), "t (s)", "kg"),
                PlotSpec("lapes", "Soltura: ponto x impacto", "s", ("pk_n",), "s de soltura (m)", "impacto norte (m)",
                         live=False, source="series:lapes", scatter=True)]

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        ac.sim.slosh = bool(self.param(ctx, "slosh"))
        ac.environment.gust = bool(self.param(ctx, "gust"))
        mission = ac.mission
        drop = next((e for e in mission.events if e.kind == "drop"), None)
        k_drop = drop.leg if drop else None
        chunk = self.param(ctx, "chunk")
        until = STOPS.index(self.param(ctx, "until"))
        start = self.param(ctx, "start")
        store = ctx.checkpoints
        parts: list[LogChunk] = []
        series = {}

        with Runner(ctx.backend, ac, mission, None, ctx) as r:
            if start == "chão":
                r.start_ground()
                stage = 0
            else:
                r.start_from(store.get(f"missao_{start}"))
                stage = "ABC".index(start) + 1
            plan = [("A", Stop(autopilot=True)), ("B", Stop(segment=1)),
                    ("C", Stop(segment=k_drop) if k_drop is not None else None)]
            out = None
            for i in range(stage, 3):
                if i >= until + 1 or plan[i][1] is None:
                    break
                name, stop = plan[i]
                ctx.on_progress(0.0, f"até o checkpoint {name}")
                out = r.run(stop, chunk=chunk)
                parts.append(out.log)
                if out.status.name != "STOPPED":
                    break
                r.checkpoint(f"missao_{name}", store)
                stage = i + 1
            if until == 3 and (out is None or out.status.name == "STOPPED"):
                if self.param(ctx, "target") and drop is not None and stage == 3 and ac.payload.enabled:
                    s_best, hist = self._target(ctx, ac, mission, store.get("missao_C"), k_drop)
                    series["lapes"] = hist
                    mission = mission.with_events([e for e in mission.events if e.kind != "drop"] +
                                                  [MissionEvent("drop", k_drop, s_best)])
                    r.reconfigure(mission)
                    r.start_from(store.get("missao_C"))
                ctx.on_progress(0.0, "até o fim")
                out = r.run(Stop(), chunk=chunk)
                parts.append(out.log)
            ev = r.session.events()
        log = LogChunk.concat(parts)
        table = stage_table(log, ev, mission.names(), info["Vs"]) if len(log) else []
        if table:
            series["etapas"] = columns(table)
        summary = dict(status=out.status.name if out else "—", t_fim=ev["tend"], energia_Wh=ev["E"],
                       n_LO=ev["nLO"], n_toque=ev["nTD"], n_parada=ev["nStop"], impacto_carga_n=ev["pk_n"],
                       impacto_carga_e=ev["pk_e"], CL_CLmax_max=ev["ratio_mission"], I_pico=ev["Ipeak"],
                       checkpoints=", ".join(store.names()))
        return SimResult(log=log, series=series, summary=summary, events=ev, status=summary["status"])

    def _target(self, ctx, ac, mission, ckC, k):
        """bisseção no ponto de soltura s (perna k) para a carga cair em n = alvo"""
        seg = mission.segments()[k]
        alvo = self.param(ctx, "target_n")
        others = [e for e in mission.events if e.kind != "drop"]
        hist = []

        def impact(sx):
            m = mission.with_events(others + [MissionEvent("drop", k, sx)])
            with Runner(ctx.backend, ac, m, dict(tmax=ckC.t + 300)) as rr:
                rr.start_from(ckC)
                o = rr.run(Stop(segment=k + 1), live=False, log=False)
                if o.events["trel"] > 0 and o.events["pk_t"] <= 0:      # carga ainda no ar
                    o = rr.run(Stop(t=rr.session.time + 30.0), live=False, log=False)
            e = o.events
            hist.append((sx, e["pk_n"], e["pk_e"]))
            return e["pk_n"] - alvo
        a, b = 0.05 * seg["L"], 0.95 * seg["L"]     # o evento precisa cair dentro da perna
        fa = impact(a)
        fb = impact(b)
        if (fa > 0) == (fb > 0):
            s_best = a if abs(fa) < abs(fb) else b
        else:
            for it in range(int(self.param(ctx, "iters"))):
                ctx.check()
                ctx.on_progress(it / self.param(ctx, "iters"), "procurando o ponto de soltura")
                m = 0.5 * (a + b)
                fm = impact(m)
                if (fm > 0) == (fa > 0):
                    a, fa = m, fm
                else:
                    b = m
            s_best = 0.5 * (a + b)
        hist.sort()
        H = np.array(hist)
        return s_best, dict(s=H[:, 0], pk_n=H[:, 1], pk_e=H[:, 2])

"""Decolagem: uma corrida em tempo real e, opcionalmente, o mapa s_R × δe1 com as
restrições (Riboldi et al., 2022) e o melhor ponto."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.mission import takeoff_runway

from ..analysis import takeoff_violations, violation_text
from ..runner import Runner, Stop
from .base import SimulationBase, floats


class TakeoffSimulation(SimulationBase):
    tab = False
    name = "takeoff"
    title = "Decolagem"
    area = "desempenho"
    description = "Só a decolagem, até h_end acima da pista. A varredura procura (s_R, δe1) de menor pista."

    def parameters(self):
        return [ParamSpec("mode", "Comando do profundor", "da aeronave", kind="choice",
                          choices=("da aeronave", "distância s_R", "velocidade V_R"),
                          help="'da aeronave' usa s_R/V_R/δe1 da aba de configuração"),
                ParamSpec("sR", "s_R (distância para puxar)", 37.5, minimum=0, maximum=500, unit="m"),
                ParamSpec("VR", "V_R (velocidade para puxar)", 12.5, minimum=0, maximum=60, unit="m/s"),
                ParamSpec("de1", "δe1 (profundor depois)", -3.0, minimum=-30, maximum=30, unit="°"),
                ParamSpec("h_end", "altura final", 6.0, minimum=1, maximum=50, unit="m"),
                ParamSpec("dtlog", "registro a cada", 0.005, minimum=0.001, maximum=0.1, unit="s"),
                ParamSpec("sweep", "Varrer s_R × δe1", False, kind="bool"),
                ParamSpec("sR_list", "s_R da varredura", "20, 25, 30, 35, 40, 45, 50", kind="floats", unit="m"),
                ParamSpec("de1_list", "δe1 da varredura", "-12, -9, -6, -3, 0", kind="floats", unit="°")]

    def plots(self):
        return [PlotSpec("perfil", "Perfil da decolagem", "n", ("h",), "distância (m)", "h (m)"),
                PlotSpec("vel", "Velocidade", "t", ("Va", "Vg"), "t (s)", "m/s"),
                PlotSpec("ang", "Atitude", "t", ("theta", "alpha", "de"), "t (s)", "graus"),
                PlotSpec("trem", "Reações no trem", "t", ("N_steer", "N_main", "N_skid"), "t (s)", "N"),
                PlotSpec("motor", "Tração e corrente", "t", ("T", "Ibat"), "t (s)", "N / A"),
                PlotSpec("mapa", "Mapa: distância até sair do chão", "sR", ("nLO",), "s_R (m)", "n_LO (m)",
                         live=False, source="series:mapa", scatter=True)]

    def _overrides(self, ctx, sR, de1):
        mode = self.param(ctx, "mode")
        if mode == "da aeronave":
            to = dict(h_end=self.param(ctx, "h_end"))
            if sR is not None:            # varredura: s_R e δe1 vêm da grade
                to.update(sR=sR, de1=math.radians(de1))
        else:
            by_dist = mode.startswith("dist")
            to = dict(sR=sR if by_dist else 0.0, VR=self.param(ctx, "VR"), de1=math.radians(de1),
                      h_end=self.param(ctx, "h_end"))
        return dict(takeoff=to, dtlog=self.param(ctx, "dtlog"), tmax=60.0)

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        runway = takeoff_runway(h=max(15.0, self.param(ctx, "h_end") + 5), V=ac.mission.V0)
        own = self.param(ctx, "mode") == "da aeronave"
        first = (None, None) if own else (self.param(ctx, "sR"), self.param(ctx, "de1"))
        with Runner(ctx.backend, ac, runway, self._overrides(ctx, *first), ctx) as r:
            r.start_ground()
            out = r.run(Stop(takeoff=True), chunk=0.25)
        ev = out.events
        lim = dict(dmin=0.03, kCL=ac.autopilot.kCL, qmax=50.0, gmax=20.0)
        viol = takeoff_violations(ev, info["Vs"], lim)
        summary = dict(status=out.status.name, n_rot=ev["nRot"], n_LO=ev["nLO"], t_LO=ev["tLO"], V_LO=ev["VLO"],
                       n_ht=ev["nHt"], V_ht=ev["VHt"], gamma_ht=math.degrees(ev["gHt"]),
                       cauda_min=ev["hcmin"] if ev["hcmin"] < 1e8 else float("nan"),
                       CL_CLmax_max=ev["ratio_to"], q_pico=math.degrees(ev["qpeak_to"]), I_pico=ev["Ipeak"],
                       restricoes=violation_text(viol), Vs=info["Vs"])
        series = {}
        if self.param(ctx, "sweep"):
            cases = [(a, b) for a in floats(self.param(ctx, "sR_list")) for b in floats(self.param(ctx, "de1_list"))]

            def one(c):
                with Runner(ctx.backend, ac, runway, dict(self._overrides(ctx, *c), dtlog=1.0)) as rr:
                    rr.start_ground()
                    o = rr.run(Stop(takeoff=True), live=False, log=False)
                e = o.events
                return [c[0], c[1], e["nLO"] if e["tLO"] > 0 else np.nan, e["nHt"] if e["completed"] else np.nan,
                        takeoff_violations(e, info["Vs"], lim)]
            M = np.array(self.parallel(ctx, one, cases, "decolagens"), dtype=float)
            ok = (M[:, 4] == 0) & np.isfinite(M[:, 2])
            series["mapa"] = dict(sR=M[:, 0], de1=M[:, 1], nLO=M[:, 2], nHt=M[:, 3], viol=M[:, 4], ok=ok.astype(float))
            if ok.any():
                i = int(np.nanargmin(np.where(ok, M[:, 2], np.inf)))
                summary.update(melhor_sR=M[i, 0], melhor_de1=M[i, 1], melhor_nLO=M[i, 2])
        return SimResult(log=out.log, series=series, summary=summary, events=ev, status=out.status.name)

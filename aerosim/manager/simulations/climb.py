"""Subida em regime: para cada V, nivela (checkpoint) e pede gradientes crescentes a
partir do mesmo checkpoint; o γ obtido satura no máximo que o motor sustenta.
Compara com a subida máxima por equilíbrio (trimagem)."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import TrimKind
from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model
from aerosim.model.mission import Leg, Mission

from ..runner import Runner, Stop
from .base import SimulationBase, floats


class ClimbSimulation(SimulationBase):
    tab = False
    name = "climb"
    title = "Subida"
    description = "Ângulo de subida máximo por velocidade: simulação a partir de checkpoint nivelado e trimagem."

    def parameters(self):
        return [ParamSpec("V_list", "Velocidades", "12, 14, 16", kind="floats", unit="m/s"),
                ParamSpec("grads", "Gradientes pedidos (tan γ)", "0.02, 0.05, 0.08, 0.11, 0.14, 0.17", kind="floats"),
                ParamSpec("window", "Janela de medida", 15.0, minimum=3, maximum=120, unit="s"),
                ParamSpec("h0", "Altura inicial", 30.0, unit="m")]

    def plots(self):
        return [PlotSpec("h", "Altura", "t", ("h",), "t (s)", "m"),
                PlotSpec("gam", "γ obtido × pedido", "gama_pedido", ("gama_med",), "γ pedido (°)", "γ obtido (°)",
                         live=False, source="series:casos", scatter=True),
                PlotSpec("gmax", "γ máximo por V", "V", ("gama_sim", "gama_trim"), "V (m/s)", "graus", live=False,
                         source="series:resumo")]

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        h0 = self.param(ctx, "h0")
        win = self.param(ctx, "window")
        over = dict(env=dict(Vw10=0.0), tmax=1e6)
        cases, res = [], []
        with ctx.backend.session_for(build_model(ac)) as s:
            trims = {V: s.trim(TrimKind.CLIMB, V) for V in floats(self.param(ctx, "V_list"))}
        for V in floats(self.param(ctx, "V_list")):
            m = Mission("subida", [Leg("straight", length=200.0, h=h0, V=V, name="nivelado"),
                                   Leg("straight", length=5000.0, h=h0 + 500.0, V=V, name="subida")], h0=h0, V0=V)
            with Runner(ctx.backend, ac, m, over, ctx) as r:
                r.start_air(0)
                r.run(Stop(segment=1), live=False, log=False)
                ck = r.checkpoint(f"subida_V{V:.1f}")

            def one(g, V=V, ck=ck, m=m):
                with Runner(ctx.backend, ac, m, dict(over, ap=dict(g_up=g))) as rr:
                    rr.start_from(ck)
                    o = rr.run(Stop(t=ck.t + win), live=False)
                T = o.log
                sel = T["t"] >= ck.t + 0.3 * win
                gam = np.degrees(np.arcsin(np.clip(T["hdot"][sel] / T["Va"][sel], -1, 1)))
                return dict(V=V, g=g, gama_pedido=math.degrees(math.atan(g)), gama_med=float(gam.mean()),
                            Va_med=float(T["Va"][sel].mean()), thr_med=float(T["thr"][sel].mean()),
                            razao_max=float(T["ratioCL"][sel].max())), T
            outs = self.parallel(ctx, one, floats(self.param(ctx, "grads")), f"V = {V:g}")
            for c, T in outs:
                cases.append(c)
                ctx.on_chunk(T)
            ok = [c for c, _ in outs if c["Va_med"] >= V - 0.7 and c["razao_max"] <= ac.autopilot.kCL]
            tp = trims[V]
            res.append(dict(V=V, gama_sim=max((c["gama_med"] for c in ok), default=np.nan),
                            gama_trim=math.degrees(tp["gamma"]) if tp["ok"] else np.nan))
        col = lambda rows: {k: np.array([r[k] for r in rows], float) for k in rows[0]}
        best = max(res, key=lambda r: r["gama_sim"] if np.isfinite(r["gama_sim"]) else -1e9)
        return SimResult(series={"casos": col(cases), "resumo": col(res)},
                         summary=dict(gama_max=best["gama_sim"], V_gama_max=best["V"], Vs=info["Vs"]))

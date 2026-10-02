"""Envelope de voo por equilíbrio (sem integrar no tempo): voo nivelado, subida máxima,
planeio, curvas limitadas pelo estol e sustentadas pelo motor, diagrama V-n."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.compile import compile_aircraft

from .base import SimulationBase


class EnvelopeSimulation(SimulationBase):
    name = "envelope"
    title = "Envelope de voo"
    description = "Pontos de equilíbrio por velocidade (Newton), sem forças no tempo."

    def parameters(self):
        return [ParamSpec("V_hi", "V máxima", 24.0, minimum=5, maximum=100, unit="m/s"),
                ParamSpec("V_lo", "V mínima", 8.0, minimum=2, maximum=60, unit="m/s"),
                ParamSpec("dV", "passo", 0.5, minimum=0.05, maximum=5, unit="m/s"),
                ParamSpec("n_max", "n estrutural (V-n)", 3.0, minimum=1.5, maximum=10, unit="g")]

    def plots(self):
        s = "series:perf"
        return [PlotSpec("pot", "Potência elétrica em voo nivelado", "V", ("P_level",), "V (m/s)", "W", live=False, source=s),
                PlotSpec("thr", "Acelerador e α nivelado", "V", ("thr_level", "alpha_level"), "V (m/s)", "— / graus",
                         live=False, source=s),
                PlotSpec("roc", "Razão de subida máx. e de planeio", "V", ("roc_max", "roc_idle"), "V (m/s)", "m/s",
                         live=False, source=s),
                PlotSpec("raio", "Raio mínimo: estol e sustentada", "V", ("R_stall", "R_sust"), "V (m/s)", "m",
                         live=False, source=s),
                PlotSpec("vn", "Diagrama V-n", "V", ("n_stall", "n_sust", "n_lim"), "V (m/s)", "n", live=False,
                         source=s)]

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        ctx.on_progress(0.1, "resolvendo os equilíbrios")
        with ctx.backend.open_session() as s:
            s.configure(compile_aircraft(ac))
            P = s.performance(self.param(ctx, "V_hi"), self.param(ctx, "V_lo"), self.param(ctx, "dV"))
        for k in ("alpha_level", "de_level", "gamma_max", "gamma_idle", "phi_stall", "phi_sust"):
            P[k] = np.degrees(P[k])
        for k in ("R_stall", "R_sust"):
            P[k] = np.where(P[k] > 1e6, np.nan, P[k])
        P["n_lim"] = np.minimum(P["n_stall"], self.param(ctx, "n_max"))
        ok = (P["ok_level"] > 0) & (P["thr_level"] > 0.05) & (P["thr_level"] <= 1.0)
        summary = dict(info)
        if ok.any():
            i = int(np.argmin(np.where(ok, P["P_level"], np.inf)))
            summary.update(V_min_potencia=float(P["V"][i]), P_min=float(P["P_level"][i]),
                           V_max_nivelado=float(P["V"][ok].max()), V_min_nivelado=float(P["V"][ok].min()))
        okc = P["ok_climb"] > 0
        if okc.any():
            j = int(np.argmax(np.where(okc, P["roc_max"], -np.inf)))
            summary.update(roc_max=float(P["roc_max"][j]), V_roc_max=float(P["V"][j]),
                           gamma_max=float(P["gamma_max"][j]))
        Rs = np.where(np.isfinite(P["R_sust"]), P["R_sust"], np.inf)
        if np.isfinite(Rs).any():
            k = int(np.argmin(Rs))
            summary.update(R_sust_min=float(Rs[k]), V_R_sust_min=float(P["V"][k]))
        return SimResult(series={"perf": P}, summary=summary)

"""Tração × velocidade de cada unidade propulsora (equilíbrio de rotação do motor)."""
from __future__ import annotations

import numpy as np

from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model

from .base import SimulationBase, floats


def thrust_curves(backend, aircraft, V_max: float = 30.0, dV: float = 0.5, throttles=(1.0,)) -> dict:
    """{unidade: {thr: colunas}} — usado também pelo botão da aba de configuração"""
    out = {}
    with backend.session_for(build_model(aircraft)) as s:
        units = [u for u in aircraft.propulsion if u.enabled]
        for i, u in enumerate(units):
            out[u.name] = {}
            for thr in throttles:
                rows = [s.prop_point(i, V, thr) for V in np.arange(0.0, V_max + 1e-9, dV)]
                out[u.name][thr] = {k: np.array([r[k] for r in rows]) for k in rows[0]}
    return out


class ThrustSimulation(SimulationBase):
    name = "thrust"
    title = "Tração"
    description = "Curvas de tração, potência, corrente e eficiência da hélice em função da velocidade."

    def parameters(self):
        return [ParamSpec("V_max", "V máxima", 30.0, minimum=5, maximum=120, unit="m/s"),
                ParamSpec("dV", "passo", 0.5, minimum=0.1, maximum=5, unit="m/s"),
                ParamSpec("thr", "Aceleradores", "1.0, 0.75, 0.5", kind="floats")]

    def plots(self):
        return [PlotSpec("T", "Tração", "V", ("T",), "V (m/s)", "N", live=False, source="series:*"),
                PlotSpec("P", "Potência elétrica", "V", ("P_elec",), "V (m/s)", "W", live=False, source="series:*"),
                PlotSpec("I", "Corrente", "V", ("I",), "V (m/s)", "A", live=False, source="series:*"),
                PlotSpec("eta", "Eficiência da hélice", "V", ("eta_prop",), "V (m/s)", "—", live=False,
                         source="series:*")]

    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft
        curves = thrust_curves(ctx.backend, ac, self.param(ctx, "V_max"), self.param(ctx, "dV"),
                               floats(self.param(ctx, "thr")))
        series = {f"{u} @ {thr:g}": cols for u, d in curves.items() for thr, cols in d.items()}
        summary = {f"T estática {u}": d[max(d)]["T"][0] for u, d in curves.items()}
        return SimResult(series=series, summary=summary)

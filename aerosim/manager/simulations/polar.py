"""Polar estática: C_L, C_D, C_m em α e C_Y, C_l, C_n em β (sem integração no tempo)."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model

from .base import SimulationBase


def aircraft_curves(backend, ac, V: float, a0: float, a1: float, da: float, de_deg: float, alpha_beta: float):
    """curvas estáticas da aeronave inteira no núcleo 6GDL (painéis + fuselagem): C_L, C_D, C_m em α
    com δe = 0 e ±δe, e C_Y, C_l, C_n em β; devolve (colunas em α, colunas em β)"""
    de = math.radians(de_deg)
    al = np.arange(a0, a1 + 1e-9, da)
    rows = []
    with backend.session_for(build_model(ac)) as s:
        for a in al:
            c = s.aero_coeffs(V, math.radians(a))
            cm = s.aero_coeffs(V, math.radians(a), de=-de)
            cp = s.aero_coeffs(V, math.radians(a), de=de)
            rows.append(dict(alpha=a, CL=c["CL"], CD=c["CD"], Cm=c["Cm"], CL_wing=c["CL_wing"], CL_ht=c["CL_ht"],
                             CL_de_m=cm["CL"], CL_de_p=cp["CL"], Cm_de_m=cm["Cm"], Cm_de_p=cp["Cm"]))
        ab = math.radians(alpha_beta)
        brow = []
        for b in np.arange(-20, 20.01, 0.5):
            c = s.aero_coeffs(V, ab, math.radians(b))
            brow.append(dict(beta=b, CY=c["CY"], Cl=c["Cl"], Cn=c["Cn"]))
    return ({k: np.array([r[k] for r in rows]) for k in rows[0]}, {k: np.array([r[k] for r in brow]) for k in brow[0]})


class PolarSimulation(SimulationBase):
    tab = False
    name = "polar"
    title = "Polar"
    description = "Curvas estáticas da aeronave inteira (painéis + fuselagem), margem estática e V de estol."

    def parameters(self):
        return [ParamSpec("V", "Velocidade", 12.0, minimum=3, maximum=60, unit="m/s"),
                ParamSpec("a0", "α inicial", -10.0, minimum=-30, maximum=0, unit="°"),
                ParamSpec("a1", "α final", 30.0, minimum=0, maximum=90, unit="°"),
                ParamSpec("da", "passo de α", 0.25, minimum=0.05, maximum=5, unit="°"),
                ParamSpec("de", "δe para comparar", 10.0, minimum=0, maximum=30, unit="°"),
                ParamSpec("alpha_beta", "α da varredura em β", 4.0, unit="°")]

    def plots(self):
        return [PlotSpec("CL", "C_L(α)", "alpha", ("CL", "CL_wing", "CL_ht", "CL_de_m", "CL_de_p"), "α (°)", "C_L",
                         live=False, source="series:alpha"),
                PlotSpec("CD", "Polar de arrasto", "CD", ("CL",), "C_D", "C_L", live=False, source="series:alpha"),
                PlotSpec("Cm", "C_m(α)", "alpha", ("Cm", "Cm_de_m", "Cm_de_p"), "α (°)", "C_m", live=False,
                         source="series:alpha"),
                PlotSpec("beta", "Látero-direcional", "beta", ("CY", "Cl", "Cn"), "β (°)", "coef.", live=False,
                         source="series:beta")]

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        V = self.param(ctx, "V")
        de = math.radians(self.param(ctx, "de"))
        al = np.arange(self.param(ctx, "a0"), self.param(ctx, "a1") + 1e-9, self.param(ctx, "da"))
        rows = []
        with ctx.backend.session_for(build_model(ac)) as s:
            for a in al:
                c = s.aero_coeffs(V, math.radians(a))
                cm = s.aero_coeffs(V, math.radians(a), de=-de)
                cp = s.aero_coeffs(V, math.radians(a), de=de)
                rows.append(dict(alpha=a, CL=c["CL"], CD=c["CD"], Cm=c["Cm"], CL_wing=c["CL_wing"], CL_ht=c["CL_ht"],
                                 CL_de_m=cm["CL"], CL_de_p=cp["CL"], Cm_de_m=cm["Cm"], Cm_de_p=cp["Cm"]))
            ab = math.radians(self.param(ctx, "alpha_beta"))
            brow = []
            for b in np.arange(-20, 20.01, 0.5):
                c = s.aero_coeffs(V, ab, math.radians(b))
                brow.append(dict(beta=b, CY=c["CY"], Cl=c["Cl"], Cn=c["Cn"]))
        cols = {k: np.array([r[k] for r in rows]) for k in rows[0]}
        bcols = {k: np.array([r[k] for r in brow]) for k in brow[0]}
        sb = np.abs(bcols["beta"]) <= 5
        info["Cn_beta"] = float(np.polyfit(np.radians(bcols["beta"][sb]), bcols["Cn"][sb], 1)[0])
        info["Cl_beta"] = float(np.polyfit(np.radians(bcols["beta"][sb]), bcols["Cl"][sb], 1)[0])
        return SimResult(series={"alpha": cols, "beta": bcols}, summary=info)

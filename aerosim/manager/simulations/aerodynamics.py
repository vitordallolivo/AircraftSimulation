"""Aba Aerodinâmica: polares e derivadas de estabilidade pelos métodos disponíveis (núcleo
Zig, lltdrek, AeroSandbox VLM/AeroBuildup/LiftingLine) com momentos no x_CG escolhido,
carregamento na envergadura e estudo de dispositivos de ponta de asa (plano de Trefftz)."""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero import AeroCase, all_solvers, mac_frac, polar_metrics, x_at_mac
from aerosim.aero import tipdevices as td
from aerosim.aero.geometry import _trapz
from aerosim.aero.tipdevices import raymer_oswald
from aerosim.interfaces.aero import DERIVATIVES
from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.compile import compile_aircraft

from .base import SimulationBase

LABEL = {"zig": "Zig", "lltdrek": "lltdrek", "asb_vlm": "ASB VLM", "asb_buildup": "ASB AeroBuildup",
         "asb_ll": "ASB LiftingLine"}


def resolve_cg(backend, ac, xcg_mac: float) -> tuple[float, float, float]:
    """x_CG em % da CMA (< 0: CG da aeronave pelo modelo de massa)"""
    with backend.open_session() as s:
        s.configure(compile_aircraft(ac))
        cg = s.mass_props()["cg"]
    if xcg_mac >= 0:
        return (x_at_mac(ac, xcg_mac / 100), 0.0, cg[2])
    return (cg[0], 0.0, cg[2])


class AerodynamicsSimulation(SimulationBase):
    name = "aerodynamics"
    title = "Aerodinâmica"
    description = ("Comparativo de métodos a partir da geometria: núcleo Zig (faixas), lltdrek (LLT não linear), "
                   "AeroSandbox (VLM, AeroBuildup, LiftingLine). Polares, derivadas com momentos no x_CG, "
                   "ponto neutro, carregamento e dispositivos de ponta de asa (Trefftz/Munk/Kroo, Raymer).")

    def parameters(self):
        return [ParamSpec("V", "Velocidade", 15.0, minimum=3, maximum=80, unit="m/s"),
                ParamSpec("a0", "α inicial", -6.0, minimum=-20, maximum=0, unit="°"),
                ParamSpec("a1", "α final", 18.0, minimum=2, maximum=30, unit="°"),
                ParamSpec("da", "passo de α", 1.0, minimum=0.25, maximum=5, unit="°"),
                ParamSpec("alpha_d", "α das derivadas", 2.0, minimum=-5, maximum=12, unit="°"),
                ParamSpec("xcg", "x_CG (−1: da massa)", -1.0, minimum=-1, maximum=100, unit="% CMA",
                          help="posição dos momentos em % da CMA a partir do bordo de ataque; −1 usa o CG do modelo de massa"),
                ParamSpec("section", "polar 2D (lltdrek)", "modelo", kind="choice", choices=("modelo", "neuralfoil")),
                ParamSpec("n_span", "painéis por semiasa", 12, kind="int", minimum=4, maximum=40),
                ParamSpec("use_zig", "núcleo Zig", True, kind="bool"),
                ParamSpec("use_lltdrek", "lltdrek", True, kind="bool"),
                ParamSpec("use_asb_vlm", "AeroSandbox VLM", True, kind="bool"),
                ParamSpec("use_asb_buildup", "AeroSandbox AeroBuildup", True, kind="bool"),
                ParamSpec("use_asb_ll", "AeroSandbox LiftingLine", False, kind="bool"),
                ParamSpec("tips", "estudo de pontas de asa", True, kind="bool"),
                ParamSpec("CL_tip", "C_L do estudo de pontas", 0.6, minimum=0.05, maximum=2.0),
                ParamSpec("hb_max", "h/b máximo", 0.3, minimum=0.05, maximum=1.0),
                ParamSpec("Cf", "C_f do dispositivo", 0.006, minimum=0.0, maximum=0.05, step=0.001),
                ParamSpec("tip_kind", "traço a desenhar", "winglet", kind="choice",
                          choices=("plana", "winglet", "placa", "caixa", "asa_c")),
                ParamSpec("tip_h", "h/b do traço desenhado", 0.15, minimum=0.0, maximum=1.0)]

    def plots(self):
        return [PlotSpec("CL", "C_L(α)", "alpha", ("CL",), "α (°)", "C_L", live=False, source="series:polar_*"),
                PlotSpec("CD", "Polar de arrasto", "CD", ("CL",), "C_D", "C_L", live=False, source="series:polar_*"),
                PlotSpec("Cm", "C_m(α) no x_CG", "alpha", ("Cm",), "α (°)", "C_m", live=False, source="series:polar_*"),
                PlotSpec("LD", "L/D", "CL", ("LD",), "C_L", "L/D", live=False, source="series:polar_*"),
                PlotSpec("span", "Carregamento na envergadura (α das derivadas)", "eta", ("lltdrek", "eliptico", "schrenk"),
                         "2y/b", "c·c_l / c_ref", live=False, source="series:span"),
                PlotSpec("e", "Pontas de asa: e ótimo (Trefftz)", "h_b",
                         ("e_winglet", "e_placa", "e_caixa", "e_asa_c", "e_raymer_placa"), "h/b", "e",
                         live=False, source="series:tips"),
                PlotSpec("dD", "Pontas de asa: ΔD total (%) com atrito", "h_b",
                         ("dD_winglet", "dD_placa", "dD_caixa", "dD_asa_c", "dD_extensao", "dD_extensao_mesmo_M"),
                         "h/b", "ΔD/D_i (%)", live=False, source="series:tips"),
                PlotSpec("trace", "Traço no plano de Trefftz e Γ ótimo", "y", ("z", "gamma"), "y/b", "z/b ; Γ",
                         live=False, source="series:trace", scatter=True)]

    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        ac.apply_constraints()
        P = lambda k: self.param(ctx, k)
        S, c, b = ac.references()
        ref = resolve_cg(ctx.backend, ac, P("xcg"))
        alphas = np.arange(P("a0"), P("a1") + 1e-9, P("da"))
        case = AeroCase(V=P("V"), alphas=alphas, alpha_d=P("alpha_d"), ref=ref, rho=ac.environment.rho,
                        section=P("section"), n_span=int(P("n_span")))
        chosen = [s for s in all_solvers(ctx.backend) if P("use_" + s.name)]
        series, summary = {}, {}
        summary["x_CG usado (m)"] = ref[0]
        summary["x_CG usado (% CMA)"] = 100 * mac_frac(ac, ref[0])
        summary["S, c, b de referência"] = [S, c, b]
        AR = b * b / S
        summary["e de Oswald (Raymer, AR)"] = raymer_oswald(AR)
        deriv_table = {"derivada": list(DERIVATIVES)}
        span = None
        for k, so in enumerate(chosen):
            ctx.check()
            ctx.on_progress(k / (len(chosen) + 1), f"rodando {so.title}")
            why = so.available()
            if why:
                summary[f"[{LABEL[so.name]}] indisponível"] = why
                continue
            try:
                pol = so.solve(ac, case)
            except Exception as e:      # um método que falha não derruba a comparação
                summary[f"[{LABEL[so.name]}] erro"] = f"{type(e).__name__}: {e}"
                continue
            lab = LABEL[so.name]
            with np.errstate(divide="ignore", invalid="ignore"):
                LD = np.where(pol.CD > 0, pol.CL / pol.CD, np.nan)
            series[f"polar_{lab}"] = dict(alpha=pol.alpha, CL=pol.CL, CD=pol.CD, Cm=pol.Cm, CDi=pol.CDi, LD=LD)
            for key, v in polar_metrics(pol, ac, case).items():
                summary[f"[{lab}] {key}"] = v
            summary[f"[{lab}] tempo (s)"] = pol.elapsed
            summary[f"[{lab}] modelo"] = pol.notes
            deriv_table[lab] = [pol.deriv(d) for d in DERIVATIVES]
            if pol.span is not None and so.name == "lltdrek":
                span = pol.span
        series["derivadas"] = deriv_table
        series["span"] = self._span(ac, span, case)
        if P("tips"):
            ctx.on_progress(len(chosen) / (len(chosen) + 1), "dispositivos de ponta de asa (Trefftz)")
            w = ac.wing
            ctip = w.chord_at(w.semispan) if w is not None else c
            e_pl = raymer_oswald(AR)
            hb = np.linspace(0.0, P("hb_max"), 13)
            tips = td.device_study(b, S, P("CL_tip"), ctip, e_planform=e_pl, Cf=P("Cf"), hb=hb)
            series["tips"] = tips
            for kname in ("winglet", "placa", "caixa", "asa_c"):
                i = int(np.argmin(tips[f"dD_{kname}"]))
                summary[f"[pontas] melhor {kname}: h/b, ΔD (%)"] = [float(hb[i]), float(tips[f"dD_{kname}"][i])]
            ol = td.optimal_loading(td.trace(P("tip_kind"), P("tip_h"), 60))
            gn = ol["gamma"] / max(np.abs(ol["gamma"]).max(), 1e-12) * 0.25
            series["trace"] = dict(y=ol["mid"][:, 0], z=ol["mid"][:, 1], gamma=gn)
            summary[f"[pontas] e de '{P('tip_kind')}' com h/b={P('tip_h'):.2f}"] = td.span_efficiency(P("tip_kind"), P("tip_h"))
            summary["[pontas] diedro da asa: e ótimo"] = td.span_efficiency(
                "diedro", n=60, dihedral_deg=w.dihedral if w is not None else 0.0)
        return SimResult(series=series, summary=summary)

    @staticmethod
    def _span(ac, span, case) -> dict:
        """c c_l / c_ref: lltdrek, elíptico e Schrenk (média da corda real e da elíptica)"""
        w = ac.wing
        S, c, b = ac.references()
        eta = np.linspace(0, 0.995, 60)
        out = {"eta": eta}
        if w is None:
            return out
        s = w.semispan
        CL = None
        if span is not None:
            # C_L da asa a partir do próprio carregamento
            yy = np.asarray(span["y"]) / s
            ccl = np.asarray(span["ccl"])
            out["lltdrek"] = np.interp(eta, yy, ccl, right=0.0)
            CL = 2 * _trapz(np.r_[ccl[0], ccl, 0.0] * c, np.r_[0.0, span["y"], s]) / S
        if CL is None:
            CL = 0.5
        ell = 4 * S * CL / (math.pi * w.span) * np.sqrt(1 - eta ** 2) / c
        chord = np.array([w.chord_at(e * s) for e in eta])
        out["eliptico"] = ell
        out["schrenk"] = 0.5 * (ell + chord * CL / c)
        return out

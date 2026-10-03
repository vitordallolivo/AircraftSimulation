"""Estabilidade estática longitudinal e látero-direcional.

- Ponto neutro numérico (núcleo): x_np = x_ref + c C_mα/C_Lα; margem estática
  MS = (x_CG − x_np)/c (x à frente): C_mα = −C_Lα MS.
- Ponto neutro analítico (Etkin & Reid, Dynamics of Flight, cap. 2; Nelson, Flight Stability and
  Automatic Control, cap. 2):
      x_np = [Σ C_Lα,i (1 − dε/dα)_i η_i (S_i/S) x_ca,i] / C_Lα + c C_mα,fus / C_Lα
- Volumes de cauda V_H = S_h l_h/(S c), V_V = S_v l_v/(S b) contra a tabela 6.4 do Raymer.
- Manche fixo: δe de equilíbrio por V com dδe/dV > 0 (Etkin; o piloto empurra para acelerar).
- Látero-direcional: C_nβ > 0 (cata-vento) e C_lβ < 0 (efeito diedro).
Margem recomendada: 5 a 15 % da CMA para aviação geral / VANT (Raymer, cap. 16; Sadraey,
Aircraft Design: A Systems Engineering Approach, cap. 6 — MS mínima ~5 %).
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero.geometry import RAYMER_TAIL_VOLUME, mac_info, tail_volumes
from aerosim.interfaces.backend import TrimKind
from aerosim.model.geometry import aero_coefficients, wing_downwash

from .probe import Probe


def analytic_np(ac) -> dict[str, float]:
    S, c, b = ac.references()
    _, depsda = wing_downwash(ac)
    num = den = 0.0
    for s in ac.surfaces:
        if not s.enabled or s.vertical or len(s.sections) < 2:
            continue
        co = aero_coefficients(s)
        de = (s.depsda if s.depsda is not None else depsda) if s.downwash else 0.0
        k = co["CLa"] * (1 - de) * s.eta * s.area / S
        num += k * mac_info(s)["x_ac"]
        den += k
    f = ac.fuselage
    Cma_f = f.Cma if f.enabled else 0.0
    x_np = num / den + c * Cma_f / den if den > 0 else float("nan")
    return dict(x_np=x_np, CLa=den, depsda=depsda, Cma_fus=Cma_f)


def static_analysis(probe: Probe, V: float, alpha_deg: float = 2.0, de_max_deg: float = 20.0,
                    V_trim=None) -> tuple[dict, dict]:
    ac = probe.ac
    a = math.radians(alpha_deg)
    out = {}
    lon = probe.deriv(V, a, "alpha", ("CL", "Cm"))
    lat = probe.deriv(V, a, "beta", ("CY", "Cl", "Cn"))
    ctl = probe.deriv(V, a, "de", ("CL", "Cm"))
    x_np = probe.neutral_point(V, a)
    an = analytic_np(ac)
    out.update({"C_Lα (1/rad)": lon["CL"], "C_mα (1/rad)": lon["Cm"], "C_Lδe (1/rad)": ctl["CL"],
                "C_mδe (1/rad)": ctl["Cm"], "C_Yβ (1/rad)": lat["CY"], "C_lβ (1/rad)": lat["Cl"],
                "C_nβ (1/rad)": lat["Cn"]})
    out["x_CG (m)"] = float(probe.cg[0])
    out["x_CG (% CMA)"] = probe.frac(probe.cg[0])
    out["x_np numérico (% CMA)"] = probe.frac(x_np)
    out["x_np analítico (% CMA)"] = probe.frac(an["x_np"])
    out["margem estática (% CMA)"] = 100 * (probe.cg[0] - x_np) / probe.c
    out["margem estática analítica (% CMA)"] = 100 * (probe.cg[0] - an["x_np"]) / probe.c
    out["dε/dα"] = an["depsda"]
    out["longitudinal"] = "estável" if lon["Cm"] < 0 else "INSTÁVEL (C_mα ≥ 0)"
    out["direcional"] = "estável" if lat["Cn"] > 0 else "INSTÁVEL (C_nβ ≤ 0)"
    out["lateral (diedro)"] = "estável" if lat["Cl"] < 0 else "INSTÁVEL (C_lβ ≥ 0)"
    tv = tail_volumes(ac, probe.cg[0])
    out["V_H"] = tv["VH"]
    out["V_V"] = tv["VV"]
    out["braço l_h, l_v (m)"] = [tv["lh"], tv["lv"]]
    series = {}
    series["raymer"] = {"categoria": list(RAYMER_TAIL_VOLUME), "V_H": [v[0] for v in RAYMER_TAIL_VOLUME.values()],
                        "V_V": [v[1] for v in RAYMER_TAIL_VOLUME.values()]}
    # C_m(α) no CG para δe = −máx, 0, +máx
    al = np.arange(-6.0, 20.01, 0.5)
    dm = math.radians(de_max_deg)
    cm = {"alpha": al}
    for lab, de in (("Cm_de_up", -dm), ("Cm_de0", 0.0), ("Cm_de_down", dm)):
        cm[lab] = np.array([probe.C(V, math.radians(x), de=de)["Cm"] for x in al])
    cm["CL"] = np.array([probe.C(V, math.radians(x))["CL"] for x in al])
    series["cm_alpha"] = cm
    # δe de equilíbrio × V (manche fixo)
    if V_trim is not None:
        rows = [probe.s.trim(TrimKind.LEVEL, v) for v in V_trim]
        ok = np.array([r["ok"] for r in rows])
        de = np.degrees([r["de"] for r in rows])
        alp = np.degrees([r["alpha"] for r in rows])
        series["trim"] = {"V": np.asarray(V_trim), "de": np.where(ok, de, np.nan), "alpha": np.where(ok, alp, np.nan),
                          "thr": np.where(ok, [r["thr"] for r in rows], np.nan)}
        good = ok & np.isfinite(de)
        if good.sum() >= 2:
            g = np.polyfit(np.asarray(V_trim)[good], de[good], 1)[0]
            out["dδe/dV (°/(m/s))"] = float(g)
            out["manche fixo"] = "estável (dδe/dV > 0)" if g > 0 else "instável (dδe/dV ≤ 0)"
    return out, series

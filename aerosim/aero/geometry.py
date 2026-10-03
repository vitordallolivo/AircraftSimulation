"""Geometria de referência para as análises: CMA, posição em % da CMA, arrasto parasita,
volumes de cauda e conversão de eixos para os solvers externos.

Eixos: o simulador usa x à frente, y à direita, z para baixo. AeroSandbox e lltdrek usam
x para trás, y à direita, z para cima (rotação de 180° em torno de y): x' = −x, z' = −z;
C_m não muda de sinal, C_l e C_n mudam (as derivadas p, r e β-β não mudam).
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.model.aircraft import Aircraft, LiftingSurface
from aerosim.model.geometry import aero_coefficients

_trapz = getattr(np, "trapezoid", None) or np.trapz   # numpy < 2
MU_AIR = 1.81e-5      # viscosidade dinâmica do ar (Pa s), 15 °C


def mac_info(s: LiftingSurface) -> dict[str, float]:
    """CMA, posição dela na envergadura e o bordo de ataque dela no corpo.
    y_cma = ∫c y dy / ∫c dy (para o trapézio: b/6 (1+2λ)/(1+λ))"""
    ss = sorted(s.sections, key=lambda q: q.y)
    ys = np.linspace(ss[0].y, ss[-1].y, 401) if len(ss) > 1 else np.array([0.0])
    c = np.array([s.chord_at(y) for y in ys])
    area = _trapz(c, ys) if len(ys) > 1 else 0.0
    y_mac = float(_trapz(c * ys, ys) / area) if area > 0 else 0.0
    mac = s.mac
    x_le = s.x - s.xoff_at(y_mac)
    return dict(mac=mac, y_mac=y_mac, x_le=x_le, x_ac=x_le - 0.25 * mac)


def mac_ref(ac: Aircraft) -> tuple[float, float]:
    """(x do bordo de ataque da CMA da asa, CMA de referência)"""
    w = ac.wing
    _, c, _ = ac.references()
    if w is None:
        return 0.0, c
    return mac_info(w)["x_le"], c


def x_at_mac(ac: Aircraft, frac: float) -> float:
    """posição x (corpo) a `frac` da CMA, medida do bordo de ataque para trás"""
    x_le, c = mac_ref(ac)
    return x_le - frac * c


def mac_frac(ac: Aircraft, x: float) -> float:
    x_le, c = mac_ref(ac)
    return (x_le - x) / c


def parasite_cd(ac: Aircraft) -> float:
    """C_D0 das superfícies (C_D0 do perfil × S η) + fuselagem e tubo (C_D S) / S_ref,
    o mesmo que o núcleo soma a α = 0"""
    S, _, _ = ac.references()
    tot = 0.0
    for s in ac.surfaces:
        if s.enabled and len(s.sections) > 1:
            tot += aero_coefficients(s)["CD0"] * s.area * s.eta
    f = ac.fuselage
    if f.enabled:
        tot += f.CDS
    if ac.boom.enabled:
        tot += 0.006 * math.pi * ac.boom.diameter * ac.boom.length
    return tot / S


def tail_volumes(ac: Aircraft, x_cg: float) -> dict[str, float]:
    """V_H = S_h l_h / (S c),  V_V = S_v l_v / (S b), braços do CG ao CA (25 % da CMA) de cada cauda"""
    S, c, b = ac.references()
    out = dict(VH=0.0, VV=0.0, lh=0.0, lv=0.0, Sh=0.0, Sv=0.0)
    for s in ac.surfaces:
        if not s.enabled or len(s.sections) < 2:
            continue
        if s.role == "htail":
            l = x_cg - mac_info(s)["x_ac"]
            out["Sh"] += s.area
            out["lh"] = l
            out["VH"] += s.area * l / (S * c)
        elif s.role == "vtail":
            l = x_cg - mac_info(s)["x_ac"]
            out["Sv"] += s.area
            out["lv"] = l
            out["VV"] += s.area * l / (S * b)
    return out


# Raymer, Aircraft Design: A Conceptual Approach, tabela 6.4 (coeficientes de volume típicos)
RAYMER_TAIL_VOLUME = {
    "planador": (0.50, 0.02),
    "experimental (homebuilt)": (0.50, 0.04),
    "aviação geral monomotor": (0.70, 0.04),
    "aviação geral bimotor": (0.80, 0.07),
    "agrícola": (0.50, 0.04),
    "turboélice bimotor": (0.90, 0.08),
    "anfíbio": (0.70, 0.06),
    "jato de treinamento": (0.70, 0.06),
    "caça": (0.40, 0.07),
    "transporte a jato": (1.00, 0.09),
}


def nu_air(rho: float) -> float:
    return MU_AIR / rho


def reynolds(V: float, c: float, rho: float) -> float:
    return V * c / nu_air(rho)


def to_xz_up(p) -> list[float]:
    """corpo (x frente, z baixo) -> eixos x trás, z cima"""
    return [-float(p[0]), float(p[1]), -float(p[2])]


def surface_stations(s: LiftingSurface) -> list[dict]:
    """seções (y crescente) com bordo de ataque no corpo e torção total (incidência + torção)"""
    dih = math.radians(s.dihedral)
    out = []
    for q in sorted(s.sections, key=lambda q: q.y):
        x_le = s.x - q.x_offset
        if s.vertical:
            p = [x_le, s.y, s.z - q.y]
        else:
            p = [x_le, s.y + q.y * math.cos(dih), s.z - q.y * math.sin(dih)]
        out.append(dict(y=q.y, chord=q.chord, le=p, twist=s.incidence + q.twist if not s.vertical else 0.0,
                        x_offset=q.x_offset))
    return out

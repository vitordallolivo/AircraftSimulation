"""Gráfico tesoura (dimensionamento da EH e da faixa de CG).

Para cada área de EH (S_h/S, mesma razão de aspecto) o núcleo dá:
  - limite traseiro (estabilidade): o CG precisa ficar MS_mín à frente do ponto neutro,
        x_tras = x_np + MS_mín c          (x para frente; em % da CMA: x_np% − MS_mín)
  - limite dianteiro (controle): equilíbrio em C_L de pouso (k · C_Lmax) com o profundor todo
    cabrado, C_m,CG = C_m,P + C_N (x_P − x_CG)/c = 0  ⇒  x_CG = x_P + c C_m,P / C_N
  - limite dianteiro (rotação na decolagem): no trem principal, com δe cabrado em V_R,
        I_tp θ̈ = q S c C_m,tp − W (x_CG − x_tp) + T (z_T − z_tp)     (z para baixo: tração acima do trem pica)
    ⇒ x_CG ≤ x_tp + (q S c C_m,tp + T (z_T − z_tp) − I_tp θ̈) / W
O menor S_h/S em que a faixa de CG desejada cabe entre os limites é o dimensionamento
(Torenbeek, Synthesis of Subsonic Airplane Design, cap. 9; Sadraey, Aircraft Design, cap. 6;
Raymer, cap. 16). MS mínima típica de 5 % da CMA.
"""
from __future__ import annotations

import math

import numpy as np

from .probe import Probe


def scale_htail(ac, k: float):
    """cópia com a EH (área × k, mesma razão de aspecto)"""
    a = ac.copy()
    f = math.sqrt(k)
    for s in a.surfaces:
        if s.role == "htail":
            for q in s.sections:
                q.y *= f
                q.chord *= f
                q.x_offset *= f
    a.apply_constraints()
    return a


def limits(probe: Probe, V: float, SM_min: float, CL_frac: float, de_max: float, VR: float,
           theta_dd: float) -> dict[str, float]:
    """limites em % da CMA para a aeronave da sonda"""
    c = probe.c
    x_np = probe.neutral_point(V)
    out = {"np": probe.frac(x_np), "aft": probe.frac(x_np) - 100 * SM_min}
    # controle: C_L de pouso com profundor cabrado (δe < 0)
    CLm = probe.CLmax(V, de=-de_max)
    a = probe.alpha_for_CL(V, CL_frac * CLm, de=-de_max)
    if a is not None:
        P = [0.0, 0.0, float(probe.cg[2])]
        co = probe.C(V, a, ref=P, de=-de_max)
        x = P[0] + c * co["Cm"] / co["CN"]
        out["fwd_ctrl"] = probe.frac(x)
    else:
        out["fwd_ctrl"] = float("nan")
    # rotação: α do chão (θ = 0)
    tp = probe.main_gear()
    q = 0.5 * probe.rho * VR * VR
    co = probe.C(VR, 0.0, ref=list(tp), de=-de_max)
    T, zT, _ = probe.thrust(VR, 1.0)
    dx = probe.cg - tp
    I_tp = probe.I[1, 1] + probe.m * (dx[0] ** 2 + dx[2] ** 2)
    x = tp[0] + (q * probe.S * c * co["Cm"] + T * (zT - tp[2]) - I_tp * math.radians(theta_dd)) / probe.W
    out["fwd_rot"] = probe.frac(x)
    out["fwd"] = np.nanmax([out["fwd_ctrl"], out["fwd_rot"]])
    return out


def scissor(backend, ac, V, SM_min=0.05, CL_frac=0.9, de_max=math.radians(20), VR=12.0, theta_dd=10.0,
            ks=np.linspace(0.3, 2.0, 18)) -> dict[str, np.ndarray]:
    S, _, _ = ac.references()
    Sh0 = sum(s.area for s in ac.surfaces if s.role == "htail" and s.enabled)
    rows = []
    for k in ks:
        a = scale_htail(ac, k)
        with Probe(backend, a) as p:
            rows.append(limits(p, V, SM_min, CL_frac, de_max, VR, theta_dd))
    col = lambda key: np.array([r[key] for r in rows])
    return {"k": np.asarray(ks), "Sh_S": np.asarray(ks) * Sh0 / S, "np": col("np"), "aft": col("aft"),
            "fwd_ctrl": col("fwd_ctrl"), "fwd_rot": col("fwd_rot"), "fwd": col("fwd")}


def min_tail(sc: dict, cg_fwd: float, cg_aft: float) -> float:
    """menor S_h/S com fwd ≤ cg_fwd e aft ≥ cg_aft (interpolado); NaN se nenhum serve"""
    ok = (sc["fwd"] <= cg_fwd) & (sc["aft"] >= cg_aft)
    if not ok.any():
        return float("nan")
    i = int(np.argmax(ok))
    if i == 0:
        return float(sc["Sh_S"][0])
    # margem = min(cg_fwd − fwd, aft − cg_aft) cruza zero entre i−1 e i
    m = np.minimum(cg_fwd - sc["fwd"], sc["aft"] - cg_aft)
    x0, x1, y0, y1 = sc["Sh_S"][i - 1], sc["Sh_S"][i], m[i - 1], m[i]
    return float(x0 + (0 - y0) * (x1 - x0) / (y1 - y0)) if y1 != y0 else float(x1)

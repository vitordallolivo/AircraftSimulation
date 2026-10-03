"""Dimensionamento das superfícies de comando a partir da asa e das caudas.

Aileron — teoria das faixas (Sadraey, Aircraft Design, cap. 12; Roskam, Airplane Design VI):
    C_lδa = (2 C_Lα,w τ_a / (S b)) ∫_{y_i}^{y_o} c(y) y dy
    P_ss = −(C_lδa / C_lp) δa (2V/b),    τ_R = −2V I_xx / (q S b² C_lp)
    φ(t) = P_ss [t − τ_R (1 − e^{−t/τ_R})]
  requisito MIL-F-8785C (classe I, nível 1): cat. A 60° em 1,3 s; B 60° em 1,7 s; C 30° em 1,3 s
  (classe II: A 45°/1,4 s, B 45°/1,9 s, C 30°/1,8 s; classe III: 30° em 1,5/2,0/2,5 s;
  classe IV: 90°/1,3 s, 90°/1,7 s, 30°/1,0 s).
  τ = dα/dδ pela teoria de perfil fino com fator 0,85 (`flap_effectiveness`).
Profundor — δe para equilibrar o C_L de pouso no CG mais à frente e para a rotação em V_R
  (θ̈ pedido no trem principal); C_mδe ∝ τ_e (corda do profundor / corda da EH).
Leme — vento cruzado (FAR 23.233: 90° com 0,2 V_SO): δr = C_nβ β / C_nδr com β = atan(V_w/V);
  motor crítico parado (multimotor): δr = T y_T / (q S b C_nδr) em V_MC ≈ 1,2 V_S.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero.geometry import _trapz
from aerosim.model.airfoil import flap_effectiveness
from aerosim.model.geometry import aero_coefficients

from .probe import Probe

# (ângulo °, tempo s) por classe e categoria
ROLL_REQ = {
    "I": {"A": (60, 1.3), "B": (60, 1.7), "C": (30, 1.3)},
    "II": {"A": (45, 1.4), "B": (45, 1.9), "C": (30, 1.8)},
    "III": {"A": (30, 1.5), "B": (30, 2.0), "C": (30, 2.5)},
    "IV": {"A": (90, 1.3), "B": (90, 1.7), "C": (30, 1.0)},
}


def _control(ac, role, kinds):
    for s in ac.surfaces:
        if (s.role == role or role is None) and s.enabled:
            for c in s.controls:
                if c.kind in kinds:
                    return s, c
    return None, None


def time_to_bank(Pss: float, tau: float, phi: float) -> float:
    """t com φ(t) = phi (rad), resposta de 1ª ordem"""
    if Pss <= 0:
        return float("inf")
    lo, hi = 0.0, 100.0
    f = lambda t: Pss * (t - tau * (1 - math.exp(-t / tau))) - phi
    if f(hi) < 0:
        return float("inf")
    for _ in range(80):
        m = 0.5 * (lo + hi)
        if f(m) < 0:
            lo = m
        else:
            hi = m
    return 0.5 * (lo + hi)


def aileron_sizing(probe: Probe, V: float, cls="I", cat="B", da_max=math.radians(20), eta_o=0.95,
                   chords=(0.15, 0.20, 0.25, 0.30), etas=np.linspace(0.30, 0.90, 13), req=None) -> tuple[dict, dict]:
    """req = (φ °, t s): requisito de rolagem; None: MIL-F-8785C da classe/fase"""
    ac = probe.ac
    w = ac.wing
    S, c, b = probe.S, probe.c, probe.b
    s = w.semispan
    CLaw = aero_coefficients(w)["CLa"]
    Clp = probe.deriv(V, math.radians(2), "p", ("Cl",), step=0.01 * 2 * V / b)["Cl"] * (2 * V / b)
    q = 0.5 * probe.rho * V * V
    Ixx = probe.I[0, 0]
    tau_R = -2 * V * Ixx / (q * S * b * b * Clp) if Clp < 0 else float("inf")
    phi_req, t_req = req if req is not None else ROLL_REQ[cls][cat]
    ys = np.linspace(0, s, 400)
    cy = np.array([w.chord_at(y) for y in ys])
    series = {"eta_i": np.asarray(etas)}
    best = {}
    for cr in chords:
        tau = flap_effectiveness(cr)
        tt, pp = [], []
        for ei in etas:
            m = (ys >= ei * s) & (ys <= eta_o * s)
            I1 = _trapz(cy[m] * ys[m], ys[m])
            Clda = 2 * CLaw * tau / (S * b) * I1
            Pss = -(Clda / Clp) * da_max * (2 * V / b)
            pp.append(math.degrees(Pss))
            tt.append(time_to_bank(Pss, tau_R, math.radians(phi_req)))
        key = f"ca/c={cr:.2f}"
        series[f"t_{key}"] = np.array(tt)
        series[f"P_{key}"] = np.array(pp)
        okm = np.array(tt) <= t_req
        best[key] = float(etas[okm][-1]) if okm.any() else float("nan")   # η_i mais externo que ainda cumpre
    series["requisito"] = np.full(len(etas), t_req)
    # conferência com o núcleo (geometria atual)
    sw, ctl = _control(ac, "wing", ("aileron", "elevon"))
    out = {"C_lp (núcleo)": Clp, "τ_R (s)": tau_R, "requisito MIL": f"{phi_req}° em {t_req} s (classe {cls}, cat. {cat})",
           "V de rolamento (m/s)": V}
    if ctl is not None:
        Clda_core = probe.deriv(V, math.radians(2), "da", ("Cl",))["Cl"]
        P_core = -(Clda_core / Clp) * da_max * (2 * V / b)
        out["C_lδa atual (núcleo)"] = Clda_core
        out["aileron atual: η, c_a/c"] = [ctl.span_start, ctl.span_end, ctl.chord_frac]
        out["aileron atual: P_ss (°/s), t (s)"] = [math.degrees(P_core), time_to_bank(P_core, tau_R, math.radians(phi_req))]
        m = (ys >= ctl.span_start * s) & (ys <= ctl.span_end * s)
        I1 = _trapz(cy[m] * ys[m], ys[m])
        out["C_lδa atual (faixas)"] = 2 * CLaw * flap_effectiveness(ctl.chord_frac) / (S * b) * I1
    for k, v in best.items():
        out[f"η_i máximo que cumpre ({k}, η_o={eta_o:.2f})"] = v
    return out, series


def elevator_sizing(probe: Probe, V_land: float, VR: float, cg_fwd_pct: float, CL_land: float,
                    de_max=math.radians(20), theta_dd=10.0, ratios=np.linspace(0.15, 0.5, 15)) -> tuple[dict, dict]:
    ac = probe.ac
    sh, ctl = _control(ac, "htail", ("elevator", "elevon", "ruddervator"))
    if ctl is None:
        sh, ctl = _control(ac, None, ("elevon", "ruddervator", "elevator"))
    if ctl is None:
        return {"profundor": "nenhum comando de arfagem na aeronave"}, {}
    tau0 = ctl.tau if ctl.tau is not None else flap_effectiveness(ctl.chord_frac)
    c = probe.c
    x_fwd = probe.x_of(cg_fwd_pct)
    ref = [x_fwd, 0.0, float(probe.cg[2])]
    a = probe.alpha_for_CL(V_land, CL_land)
    out = {"comando de arfagem": f"{sh.name} ({ctl.kind}, c_e/c = {ctl.chord_frac:.2f})"}
    series = {"ce_c": np.asarray(ratios)}
    if a is not None:
        co = probe.C(V_land, a, ref=ref)
        Cmde = probe.deriv(V_land, a, "de", ("Cm",), ref=ref)["Cm"]
        de_trim = [-co["Cm"] / (Cmde * flap_effectiveness(r) / tau0) for r in ratios]
        series["de_pouso"] = np.degrees(de_trim)
        out["δe p/ C_L de pouso, CG dianteiro (atual, °)"] = math.degrees(-co["Cm"] / Cmde)
    # rotação
    tp = probe.main_gear()
    q = 0.5 * probe.rho * VR * VR
    co = probe.C(VR, 0.0, ref=list(tp))
    Cmde_tp = probe.deriv(VR, 0.0, "de", ("Cm",), ref=list(tp))["Cm"]
    T, zT, _ = probe.thrust(VR, 1.0)
    dx = np.array([x_fwd, 0, probe.cg[2]]) - tp
    I_tp = probe.I[1, 1] + probe.m * (dx[0] ** 2 + dx[2] ** 2)
    M0 = q * probe.S * c * co["Cm"] - probe.W * (x_fwd - tp[0]) + T * (zT - tp[2])
    need = I_tp * math.radians(theta_dd) - M0
    de_rot = [need / (q * probe.S * c * Cmde_tp * flap_effectiveness(r) / tau0) for r in ratios]
    series["de_rotacao"] = np.degrees(de_rot)
    series["de_max"] = np.full(len(ratios), -math.degrees(de_max))
    series["de_max_pos"] = np.full(len(ratios), math.degrees(de_max))
    out["δe p/ rotação em V_R (atual, °)"] = math.degrees(need / (q * probe.S * c * Cmde_tp))
    ok = np.ones(len(ratios), bool)
    for k in ("de_pouso", "de_rotacao"):
        if k in series:
            ok &= np.abs(series[k]) <= math.degrees(de_max)
    out["menor c_e/c que cumpre (δe ≤ máx.)"] = float(ratios[ok][0]) if ok.any() else float("nan")
    out["CG dianteiro usado (% CMA)"] = cg_fwd_pct
    return out, series


def rudder_sizing(probe: Probe, V_ap: float, Vw: float, V_mc: float, dr_max=math.radians(25),
                  ratios=np.linspace(0.15, 0.5, 15)) -> tuple[dict, dict]:
    ac = probe.ac
    sv, ctl = _control(ac, "vtail", ("rudder", "ruddervator"))
    if ctl is None:
        sv, ctl = _control(ac, None, ("rudder", "ruddervator"))
    if ctl is None:
        return {"leme": "nenhum leme na aeronave"}, {}
    tau0 = ctl.tau if ctl.tau is not None else flap_effectiveness(ctl.chord_frac)
    a = math.radians(2)
    Cnb = probe.deriv(V_ap, a, "beta", ("Cn",))["Cn"]
    Cndr = probe.deriv(V_ap, a, "dr", ("Cn",))["Cn"]
    beta = math.atan2(Vw, V_ap)
    series = {"cr_c": np.asarray(ratios)}
    sc = np.array([flap_effectiveness(r) / tau0 for r in ratios])
    series["dr_vento"] = np.degrees(np.abs(Cnb * beta / (Cndr * sc)))
    out = {"C_nβ": Cnb, "C_nδr (atual)": Cndr, "β de vento cruzado (°)": math.degrees(beta),
           "δr p/ vento cruzado (atual, °)": math.degrees(abs(Cnb * beta / Cndr))}
    T, _, Ty = probe.thrust(V_mc, 1.0)
    units = [u for u in ac.propulsion if u.enabled]
    if len(units) > 1:
        # motor mais afastado parado: o momento é o dele
        i = int(np.argmax([abs(u.y) for u in units]))
        Ti = probe.s.prop_point(i, V_mc, 1.0)["T"]
        q = 0.5 * probe.rho * V_mc ** 2
        series["dr_motor_parado"] = np.degrees(np.abs(Ti * units[i].y / (q * probe.S * probe.b * Cndr * sc)))
        out["δr com motor crítico parado em V_MC (atual, °)"] = float(series["dr_motor_parado"][np.argmin(np.abs(sc - 1))])
    series["dr_max"] = np.full(len(ratios), math.degrees(dr_max))
    ok = np.ones(len(ratios), bool)
    for k in ("dr_vento", "dr_motor_parado"):
        if k in series:
            ok &= series[k] <= math.degrees(dr_max)
    out["menor c_r/c que cumpre (δr ≤ máx.)"] = float(ratios[ok][0]) if ok.any() else float("nan")
    out["leme atual: c_r/c"] = ctl.chord_frac
    return out, series

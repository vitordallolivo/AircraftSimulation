"""Dimensionamento pela posição do CG e variações "e se" da geometria.

- `trim_at_CL`: α e δ de arfagem que equilibram C_L pedido com o CG em x (Newton 2×2 no núcleo).
- `cg_sweep`: para cada x_CG: margem estática, δ de arfagem para pousar (C_L de pouso), para o
  cruzeiro e para rodar na decolagem. Onde o δ passa do curso, o CG está à frente do limite
  dianteiro; onde a margem fica abaixo da mínima, atrás do limite traseiro.
- `scale_surfaces` / `with_dihedral` + `modes_at`: a mesma análise com a deriva maior ou mais
  diedro, para dizer quanto mudar quando um modo não atende.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.model.compile import compile_aircraft

from .dynamic import modes
from .probe import G0, Probe


def trim_at_CL(probe: Probe, V: float, CL: float, x: float, guess=(0.08, 0.0)) -> tuple[float, float, bool]:
    """(α, δe, convergiu) com C_L = CL e C_m = 0 em torno de (x, 0, z_CG)"""
    ref = [x, 0.0, float(probe.cg[2])]
    a, d = guess

    def r(a_, d_):
        c = probe.C(V, a_, ref=ref, de=d_)
        return np.array([c["CL"] - CL, c["Cm"]])
    for _ in range(30):
        f0 = r(a, d)
        if abs(f0[0]) + abs(f0[1]) < 1e-8:
            return a, d, True
        h = 1e-5
        J = np.column_stack([(r(a + h, d) - f0) / h, (r(a, d + h) - f0) / h])
        try:
            da, dd = np.linalg.solve(J, -f0)
        except np.linalg.LinAlgError:
            break
        a += float(np.clip(da, -0.1, 0.1))
        d = float(np.clip(d + np.clip(dd, -0.2, 0.2), -1.2, 1.2))
    f0 = r(a, d)
    return a, d, abs(f0[0]) + abs(f0[1]) < 1e-5


def trimmed_CLmax(probe: Probe, V: float, x: float, de_max: float) -> float:
    """maior C_L que o comando de arfagem consegue equilibrar com o CG em x (|δ| ≤ δ_máx)"""
    lo, hi = 0.05, probe.CLmax(V) * 1.05
    g = (0.05, 0.0)
    if not _trim_ok(probe, V, lo, x, de_max, g):
        return float("nan")
    for _ in range(30):
        m = 0.5 * (lo + hi)
        if _trim_ok(probe, V, m, x, de_max, g):
            lo = m
        else:
            hi = m
    return lo


def _trim_ok(probe, V, CL, x, de_max, g):
    a, d, ok = trim_at_CL(probe, V, CL, x, g)
    return ok and abs(d) <= de_max + 1e-9


def gear_x_for_rotation(probe: Probe, VR: float, x: float, theta_dd_deg: float, de_max: float,
                        tipback_deg: float = 15.0) -> tuple[float | None, float]:
    """x do trem principal que permite rodar com |δe| ≤ δ_máx; e o x máximo que ainda respeita o
    ângulo de tombamento para trás (Raymer cap. 11: trem principal atrás do CG por ≥ 15°)"""
    tp0 = probe.main_gear()
    x_tip = x - (tp0[2] - probe.cg[2]) * math.tan(math.radians(tipback_deg))
    lo, hi = x - 0.6 * probe.c, x_tip
    f = lambda xt: rotation_de(probe, VR, x, theta_dd_deg, tp=np.array([xt, 0.0, tp0[2]])) + de_max
    if f(hi) < 0:
        return None, x_tip
    if f(lo) > 0:
        return lo, x_tip
    for _ in range(40):
        m = 0.5 * (lo + hi)
        if f(m) > 0:
            hi = m
        else:
            lo = m
    return hi, x_tip


def rotation_de(probe: Probe, VR: float, x: float, theta_dd_deg: float, tp=None) -> float:
    """δe para a aceleração de arfagem pedida no trem principal em V_R, com o CG em x:
    I θ̈ = q S c (C_m,tp + C_mδe,tp δe) − W (x − x_tp) + T (z_T − z_tp)   (z para baixo)"""
    tp = probe.main_gear() if tp is None else tp
    q = 0.5 * probe.rho * VR * VR
    c0 = probe.C(VR, 0.0, ref=list(tp))
    Cmde = probe.deriv(VR, 0.0, "de", ("Cm",), ref=list(tp))["Cm"]
    T, zT, _ = probe.thrust(VR, 1.0)
    dx = np.array([x - tp[0], 0, probe.cg[2] - tp[2]])
    I = probe.I[1, 1] + probe.m * (dx[0] ** 2 + dx[2] ** 2)
    M0 = q * probe.S * probe.c * c0["Cm"] - probe.W * (x - tp[0]) + T * (zT - tp[2])
    return (I * math.radians(theta_dd_deg) - M0) / (q * probe.S * probe.c * Cmde)


def cg_sweep(probe: Probe, pcts, V_cru: float, V_land: float, CL_land: float, VR: float | None,
             theta_dd: float) -> dict[str, np.ndarray]:
    x_np = probe.neutral_point(V_cru)
    np_pct = probe.frac(x_np)
    CL_cru = probe.W / (0.5 * probe.rho * V_cru ** 2 * probe.S)
    out = {"cg": np.asarray(pcts, float), "ME": np_pct - np.asarray(pcts, float)}
    land, cru, rot = [], [], []
    g1, g2 = (0.1, 0.0), (0.05, 0.0)
    for p in pcts:
        x = probe.x_of(p)
        a, d, ok = trim_at_CL(probe, V_land, CL_land, x, g1)
        land.append(math.degrees(d) if ok else np.nan)
        if ok:
            g1 = (a, d)
        a, d, ok = trim_at_CL(probe, V_cru, CL_cru, x, g2)
        cru.append(math.degrees(d) if ok else np.nan)
        if ok:
            g2 = (a, d)
        rot.append(math.degrees(rotation_de(probe, VR, x, theta_dd)) if VR else np.nan)
    out["de_pouso"] = np.array(land)
    out["de_cruzeiro"] = np.array(cru)
    out["de_rotacao"] = np.array(rot)
    out["np"] = np_pct
    out["CL_cru"] = CL_cru
    return out


def limit_crossing(x, y, lim) -> float | None:
    """primeiro x (da esquerda) em que y passa a respeitar |y| ≤ lim, por interpolação"""
    ok = np.isfinite(y) & (np.abs(y) <= lim)
    if not ok.any():
        return None
    i = int(np.argmax(ok))
    if i == 0:
        return float(x[0])
    y0, y1 = abs(y[i - 1]) if np.isfinite(y[i - 1]) else 1e9, abs(y[i])
    return float(x[i - 1] + (lim - y0) * (x[i] - x[i - 1]) / (y1 - y0)) if y1 != y0 else float(x[i])


# ------------------------------------------------------------------ variações da geometria
def scale_surfaces(ac, names, k: float):
    """cópia com as superfícies `names` com área × k (mesma razão de aspecto)"""
    a = ac.copy()
    f = math.sqrt(k)
    for s in a.surfaces:
        if s.name in names:
            for q in s.sections:
                q.y *= f
                q.chord *= f
                q.x_offset *= f
    a.apply_constraints()
    return a


def with_dihedral(ac, wing_name: str, delta_deg: float):
    a = ac.copy()
    for s in a.surfaces:
        if s.name == wing_name:
            s.dihedral += delta_deg
    return a


def modes_at(backend, ac, V: float):
    with backend.open_session() as s:
        s.configure(compile_aircraft(ac))
        lm = s.linearize(V)
    return (modes(lm["A"]) if lm["ok"] else None), lm


def search(backend, make, values, V, ok_fn):
    """primeiro valor (em ordem) em que ok_fn(modos) é verdadeiro; None se nenhum"""
    for v in values:
        m, _ = modes_at(backend, make(v), V)
        if m is not None and ok_fn(m):
            return v, m
    return None, None


def stall_speed(probe: Probe) -> tuple[float, float]:
    CLm = probe.CLmax(15.0)
    return CLm, math.sqrt(2 * probe.m * G0 / (probe.rho * probe.S * CLm))

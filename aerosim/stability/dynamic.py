"""Estabilidade dinâmica pelo modelo linear do núcleo (aerosim_linearize: corpo rígido com
comandos congelados em torno do voo nivelado equilibrado).

Modos (Etkin & Reid; Nelson): longitudinal (u, w, q, θ) → curto período (par de maior ω_n) e
fugóide; látero-direcional (v, p, r, φ) → dutch roll (par complexo), rolamento (real mais
rápido) e espiral (real mais lento). Para cada modo: ω_n, ζ, período, tempo para metade/dobro.

Qualidades de voo: MIL-F-8785C (1980), níveis 1/2/3 por classe de avião (I: pequeno e leve,
II: médio, III: grande, IV: alta manobrabilidade) e categoria de fase de voo (A: manobras
rápidas/precisão, B: subida/cruzeiro/descida, C: decolagem/aproximação/pouso).
Aproximação de Lanchester para o fugóide: ω_n ≈ √2 g/V, ζ ≈ 1/(√2 L/D).
"""
from __future__ import annotations

import math

import numpy as np

LON = [0, 2, 4, 7]       # u, w, q, θ
LAT = [1, 3, 5, 6]       # v, p, r, φ
G0 = 9.80665


def _mode(lam: complex) -> dict:
    wn = abs(lam)
    zeta = -lam.real / wn if wn > 0 else float("nan")
    d = dict(re=lam.real, im=abs(lam.imag), wn=wn, zeta=zeta,
             period=2 * math.pi / abs(lam.imag) if abs(lam.imag) > 1e-9 else float("nan"))
    if lam.real < 0:
        d["t_half"] = math.log(2) / -lam.real
        d["t_double"] = float("nan")
    elif lam.real > 0:
        d["t_double"] = math.log(2) / lam.real
        d["t_half"] = float("nan")
    else:
        d["t_half"] = d["t_double"] = float("inf")
    d["tau"] = -1 / lam.real if abs(lam.imag) < 1e-9 and lam.real != 0 else float("nan")
    return d


def modes(A: np.ndarray) -> dict[str, dict]:
    """classifica os autovalores dos blocos longitudinal e látero-direcional"""
    out = {}
    lon = np.linalg.eigvals(A[np.ix_(LON, LON)])
    lat = np.linalg.eigvals(A[np.ix_(LAT, LAT)])
    cpx = sorted([l for l in lon if l.imag > 1e-9], key=abs)
    real = sorted([l for l in lon if abs(l.imag) <= 1e-9], key=abs)
    if len(cpx) == 2:
        out["fugoide"], out["curto_periodo"] = _mode(cpx[0]), _mode(cpx[1])
    elif len(cpx) == 1:
        # um par complexo: o de maior ω_n entre ele e as raízes reais decide
        if abs(cpx[0]) > max((abs(r) for r in real), default=0):
            out["curto_periodo"] = _mode(cpx[0])
            out["fugoide"] = _mode(real[0]) if real else {}
        else:
            out["fugoide"] = _mode(cpx[0])
            out["curto_periodo"] = _mode(real[-1]) if real else {}
    else:
        out["fugoide"] = _mode(real[0])
        out["curto_periodo"] = _mode(real[-1])
    cpx = [l for l in lat if l.imag > 1e-9]
    real = sorted([l for l in lat if abs(l.imag) <= 1e-9], key=lambda l: l.real)
    if cpx:
        out["dutch_roll"] = _mode(cpx[0])
    if real:
        out["rolamento"] = _mode(real[0])
        out["espiral"] = _mode(real[-1]) if len(real) > 1 else {}
    return out


# ------------------------------------------------------------------ MIL-F-8785C
def _level_range(x, bands):
    for lvl, (lo, hi) in enumerate(bands, start=1):
        if lo <= x <= hi:
            return lvl
    return 4


def mil_check(m: dict, cls: str = "I", cat: str = "B") -> list[dict]:
    """[{critério, valor, exigido (nível 1), nível}] — nível 4 = pior que o 3"""
    rows = []
    sp = m.get("curto_periodo", {})
    if sp.get("zeta") is not None and math.isfinite(sp.get("zeta", float("nan"))) and sp.get("im", 0) > 0:
        bands = ([(0.35, 1.30), (0.25, 2.00), (0.15, 1e9)] if cat in "AC" else [(0.30, 2.00), (0.20, 2.00), (0.15, 1e9)])
        rows.append(dict(criterio="ζ curto período", valor=sp["zeta"], exigido=f"{bands[0][0]}–{bands[0][1]}",
                         nivel=_level_range(sp["zeta"], bands)))
    ph = m.get("fugoide", {})
    if ph:
        z = ph.get("zeta", float("nan"))
        lvl = 1 if z >= 0.04 else 2 if z >= 0 else (3 if ph.get("t_double", 0) >= 55 else 4)
        rows.append(dict(criterio="ζ fugóide", valor=z, exigido="≥ 0,04", nivel=lvl))
    dr = m.get("dutch_roll", {})
    if dr:
        if cat == "A":
            req = (0.19, 0.35, 1.0) if cls in ("I", "IV") else (0.19, 0.35, 0.5)
        elif cat == "B":
            req = (0.08, 0.15, 0.4)
        else:
            req = (0.08, 0.15, 1.0) if cls in ("I", "IV") else (0.08, 0.10, 0.4)
        z, wn = dr["zeta"], dr["wn"]
        l1 = z >= req[0] and z * wn >= req[1] and wn >= req[2]
        l2 = z >= 0.02 and z * wn >= 0.05 and wn >= 0.4
        l3 = z >= 0.0 and wn >= 0.4
        rows.append(dict(criterio="dutch roll ζ / ζω_n / ω_n", valor=[z, z * wn, wn],
                         exigido=f"≥ {req[0]} / {req[1]} / {req[2]}", nivel=1 if l1 else 2 if l2 else 3 if l3 else 4))
    ro = m.get("rolamento", {})
    if ro and math.isfinite(ro.get("tau", float("nan"))):
        if cat == "B" or (cat == "A" and cls in ("II", "III")):
            lim = (1.4, 3.0, 10.0)
        elif cat == "C" and cls == "III":
            lim = (1.4, 3.0, 10.0)
        else:
            lim = (1.0, 1.4, 10.0)
        t = ro["tau"] if ro["tau"] > 0 else float("inf")
        rows.append(dict(criterio="τ_R rolamento (s)", valor=t, exigido=f"≤ {lim[0]}",
                         nivel=next((i + 1 for i, v in enumerate(lim) if t <= v), 4)))
    es = m.get("espiral", {})
    if es:
        lim = (12.0, 8.0, 4.0) if cat in "AC" else (20.0, 8.0, 4.0)
        t2 = es.get("t_double", float("nan"))
        t2 = float("inf") if not math.isfinite(t2) else t2     # estável: ok
        rows.append(dict(criterio="espiral: tempo para dobrar (s)", valor=t2, exigido=f"≥ {lim[0]}",
                         nivel=next((i + 1 for i, v in enumerate(lim) if t2 >= v), 4)))
    return rows


def lanchester(V: float, LD: float) -> dict:
    return dict(wn=math.sqrt(2) * G0 / V, zeta=1 / (math.sqrt(2) * LD) if LD > 0 else float("nan"))


def response(A, B, u_of_t, T=10.0, dt=0.01) -> dict[str, np.ndarray]:
    """resposta linear (RK4) a uma entrada u(t) (δe, δa, δr, acelerador)"""
    n = int(T / dt) + 1
    x = np.zeros(8)
    X = np.zeros((n, 8))
    t = np.arange(n) * dt
    f = lambda tt, xx: A @ xx + B @ u_of_t(tt)
    for k in range(1, n):
        tk = t[k - 1]
        k1 = f(tk, x)
        k2 = f(tk + dt / 2, x + dt / 2 * k1)
        k3 = f(tk + dt / 2, x + dt / 2 * k2)
        k4 = f(tk + dt, x + dt * k3)
        x = x + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
        X[k] = x
    names = ("u", "v", "w", "p", "q", "r", "phi", "theta")
    out = {"t": t}
    for i, nm in enumerate(names):
        out[nm] = X[:, i] if i < 3 else np.degrees(X[:, i])
    return out


def doublet(amp: float, t0: float = 0.5, width: float = 0.5, channel: int = 0):
    def u(t):
        v = np.zeros(4)
        if t0 <= t < t0 + width:
            v[channel] = amp
        elif t0 + width <= t < t0 + 2 * width:
            v[channel] = -amp
        return v
    return u


def pulse(amp: float, t0: float = 0.5, width: float = 1.0, channel: int = 1):
    def u(t):
        v = np.zeros(4)
        if t0 <= t < t0 + width:
            v[channel] = amp
        return v
    return u

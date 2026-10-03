"""Diagrama de restrições do dimensionamento inicial: razão tração/peso (T/W) exigida por cada
requisito em função da carga alar W/S (N/m²), e os limites verticais de carga alar (estol e pouso).
A região viável fica acima de todas as curvas e à esquerda dos limites verticais; o ponto de
projeto é o de menor T/W dentro dela (o menor motor), e a faixa ótima é onde o T/W fica a até
`tol` acima desse mínimo (margem para escolher a asa).

Equações (Gudmundsson, General Aviation Aircraft Design, 2014, cap. 3; Raymer, Aircraft Design,
cap. 5 e 12), polar parabólica C_D = C_D0 + k C_L², k = 1/(π AR e), q = ½ ρ V²:
  curva sustentada n a V:  T/W = q [C_D0/(W/S) + k (n/q)² (W/S)]
  razão de subida V_V a V: T/W = V_V/V + q C_D0/(W/S) + k (W/S)/q
  gradiente de subida G:   T/W = G + q C_D0/(W/S) + k (W/S)/q            (G = sen γ)
  cruzeiro / V máxima a V: T/W = q C_D0/(W/S) + k (W/S)/q
  corrida de decolagem S_G: T/W = V_LOF²/(2 g S_G) + q C_D,TO/(W/S) + μ (1 − q C_L,TO/(W/S)),
                            V_LOF = 1,1 V_S(W/S), q a V_LOF/√2
  teto (V_V residual a ρ_h): como a subida, levado ao nível do mar por (ρ_h/ρ0)^m
  estol:                   W/S ≤ ½ ρ V_S² C_Lmax
  corrida de pouso S_L:    W/S ≤ ρ C_Lmax g μ_f S_L / 1,15²  (toque a 1,15 V_S, frenagem μ_f;
                            simplificado: sem arrasto nem sustentação na frenagem — conservador)
Potência (hélice): P/W = (T/W) V / η_p na velocidade de cada requisito.

A polar vem de fora: da aba Aerodinâmica (o modelo da aeronave) ou de `estimate_polar`
(estimativa estatística, quando ainda não há geometria).
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

G0 = 9.80665


@dataclass
class ParabolicPolar:
    CD0: float = 0.03
    k: float = 0.06            # 1/(π AR e)
    CLmax: float = 1.4
    CL_TO: float = 0.5         # C_L na corrida
    CD_TO: float = 0.05        # C_D na corrida
    mu: float = 0.04           # atrito de rolamento


def estimate_polar(Swet_S: float = 4.0, Cfe: float = 0.0055, AR: float = 7.0, e: float | None = None,
                   CLmax: float = 1.4, CL_TO: float = 0.5, dCD_TO: float = 0.01, mu: float = 0.04) -> ParabolicPolar:
    """sem geometria: C_D0 = C_fe S_molhada/S (Raymer, eq. 12.23 e tab. 12.3: C_fe ≈ 0,0055 monomotor leve,
    0,0045 bimotor leve, 0,0030 planador...); e de Oswald pela eq. 12.49 do Raymer"""
    if e is None:
        e = 1.78 * (1 - 0.045 * AR ** 0.68) - 0.64
    CD0 = Cfe * Swet_S
    k = 1 / (math.pi * AR * e)
    return ParabolicPolar(CD0, k, CLmax, CL_TO, CD0 + k * CL_TO ** 2 + dCD_TO, mu)


@dataclass
class Requirements:
    rho: float = 1.225
    V_stall: float = 11.0      # V_S máxima (m/s)
    S_G: float = 50.0          # corrida de decolagem máxima (m)
    S_L: float = 0.0           # corrida de pouso máxima (m); 0: não verifica
    mu_brake: float = 0.3      # atrito na frenagem
    V_cruise: float = 16.0
    V_max: float = 0.0         # velocidade máxima (m/s); 0: não verifica
    V_climb: float = 13.0
    roc: float = 2.0           # razão de subida (m/s)
    climb_grad: float = 0.0    # gradiente de subida (%); 0: não verifica
    n_turn: float = 2.0        # fator de carga em curva sustentada ...
    V_turn: float = 14.0       # ... a esta velocidade
    h_ceiling: float = 0.0     # teto pedido (m); 0: não verifica
    roc_ceiling: float = 0.5
    thrust_rho_exp: float = 1.0   # T ∝ (ρ/ρ0)^m


# (chave, rótulo) — curvas de T/W
KINDS = (("decolagem", "corrida de decolagem"), ("subida", "razão de subida"), ("gradiente", "gradiente de subida"),
         ("cruzeiro", "velocidade de cruzeiro"), ("vmax", "velocidade máxima"), ("curva", "curva sustentada"),
         ("teto", "teto"))
# limites verticais de W/S
LIMITS = (("estol", "velocidade de estol"), ("pouso", "corrida de pouso"))


def _q(rho, V):
    return 0.5 * rho * V * V


def isa_rho(h: float) -> float:
    return 1.225 * (1 - 2.25577e-5 * h) ** 4.2559


def active_kinds(r: Requirements) -> list[str]:
    out = ["decolagem", "subida", "cruzeiro", "curva"]
    if r.climb_grad > 0:
        out.insert(2, "gradiente")
    if r.V_max > 0:
        out.insert(-1, "vmax")
    if r.h_ceiling > 0:
        out.append("teto")
    return out


def condition_speed(kind: str, ws: float, r: Requirements, a: ParabolicPolar) -> float:
    """velocidade em que o requisito acontece (para a tração da hélice e para P/W)"""
    if kind == "decolagem":
        return 1.1 * math.sqrt(2 * ws / (r.rho * a.CLmax)) / math.sqrt(2)
    if kind in ("subida", "gradiente"):
        return r.V_climb
    if kind == "cruzeiro":
        return r.V_cruise
    if kind == "vmax":
        return r.V_max
    if kind == "curva":
        return r.V_turn
    if kind == "teto":
        return math.sqrt(2 * ws / (isa_rho(r.h_ceiling) * math.sqrt(3 * a.CD0 / a.k)))
    raise ValueError(kind)


def required_tw(kind: str, ws, r: Requirements, a: ParabolicPolar):
    ws = np.asarray(ws, float)
    if kind == "curva":
        q = _q(r.rho, r.V_turn)
        return q * (a.CD0 / ws + a.k * (r.n_turn / q) ** 2 * ws)
    if kind == "subida":
        q = _q(r.rho, r.V_climb)
        return r.roc / r.V_climb + q * a.CD0 / ws + a.k * ws / q
    if kind == "gradiente":
        q = _q(r.rho, r.V_climb)
        return r.climb_grad / 100 + q * a.CD0 / ws + a.k * ws / q
    if kind in ("cruzeiro", "vmax"):
        q = _q(r.rho, r.V_cruise if kind == "cruzeiro" else r.V_max)
        return q * a.CD0 / ws + a.k * ws / q
    if kind == "decolagem":
        Vs = np.sqrt(2 * ws / (r.rho * a.CLmax))
        V_lof = 1.1 * Vs
        q = _q(r.rho, V_lof / math.sqrt(2))
        return V_lof ** 2 / (2 * G0 * r.S_G) + q * a.CD_TO / ws + a.mu * (1 - q * a.CL_TO / ws)
    if kind == "teto":
        rh = isa_rho(r.h_ceiling)
        V = np.sqrt(2 * ws / (rh * math.sqrt(3 * a.CD0 / a.k)))   # V de razão de subida máxima (aprox.)
        q = _q(rh, V)
        tw_h = r.roc_ceiling / V + q * a.CD0 / ws + a.k * ws / q
        return tw_h / (rh / 1.225) ** r.thrust_rho_exp
    raise ValueError(kind)


def stall_ws(r: Requirements, a: ParabolicPolar) -> float:
    return 0.5 * r.rho * r.V_stall ** 2 * a.CLmax


def landing_ws(r: Requirements, a: ParabolicPolar) -> float:
    return r.rho * a.CLmax * G0 * r.mu_brake * r.S_L / 1.15 ** 2 if r.S_L > 0 else float("inf")


def ws_limits(r: Requirements, a: ParabolicPolar) -> dict[str, float]:
    out = {"estol": stall_ws(r, a)}
    if r.S_L > 0:
        out["pouso"] = landing_ws(r, a)
    return out


def constraint_curves(r: Requirements, a: ParabolicPolar, ws) -> dict[str, np.ndarray]:
    out = {"ws": np.asarray(ws, float)}
    for k in active_kinds(r):
        out[k] = required_tw(k, ws, r, a)
    return out


def design_point(r: Requirements, a: ParabolicPolar, ws=None, tol: float = 0.05) -> dict:
    """menor T/W viável, a W/S dele, quem manda em cada lado e a faixa ótima (T/W ≤ (1+tol)·mínimo)"""
    lim = ws_limits(r, a)
    ws_max = min(lim.values())
    limiter = min(lim, key=lim.get)
    ws = np.linspace(0.03 * ws_max, ws_max, 600) if ws is None else np.asarray(ws, float)
    ws = ws[ws <= ws_max]
    c = constraint_curves(r, a, ws)
    keys = [k for k in c if k != "ws"]
    M = np.vstack([c[k] for k in keys])
    env = M.max(axis=0)
    i = int(np.argmin(env))
    band = ws[env <= (1 + tol) * env[i]]
    return dict(ws=float(ws[i]), tw=float(env[i]), active=keys[int(np.argmax(M[:, i]))], ws_max=float(ws_max),
                ws_limiter=limiter, band=(float(band.min()), float(band.max())), env=env, grid=ws,
                at_limit=bool(i == len(ws) - 1))

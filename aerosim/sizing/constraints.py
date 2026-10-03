"""Diagrama de restrições: razão tração/peso (T/W) exigida por cada requisito em função da
carga alar W/S (N/m²). A região viável fica acima de todas as curvas e à esquerda do estol.

Equações (Gudmundsson, General Aviation Aircraft Design, 2014, cap. 3; Raymer, Aircraft Design,
cap. 5), com polar parabólica C_D = C_D0 + k C_L², k = 1/(π AR e), q = ½ ρ V²:
  curva com n a V:          T/W = q [C_D0/(W/S) + k (n/q)² (W/S)]
  subida com V_V a V:       T/W = V_V/V + q C_D0/(W/S) + k (W/S)/q
  cruzeiro (n = 1) a V:     T/W = q C_D0/(W/S) + k (W/S)/q
  corrida de decolagem S_G: T/W = V_LOF²/(2 g S_G) + q C_D,TO/(W/S) + μ (1 − q C_L,TO/(W/S)),
                            V_LOF = 1,1 V_S(W/S), q a V_LOF/√2
  teto (V_V residual a ρ_h): como a subida, com T/W ao nível do mar = (T/W)_h / (ρ_h/ρ0)^m
  estol:                    W/S ≤ ½ ρ V_S² C_Lmax
Hélice: T cai com V; a aba compara cada requisito com a tração disponível da aeronave
naquela velocidade (curva do motor), não com a estática.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

G0 = 9.80665


@dataclass
class AeroModel:
    CD0: float = 0.03
    k: float = 0.06            # 1/(π AR e)
    CLmax: float = 1.4
    CL_TO: float = 0.5         # C_L na corrida
    CD_TO: float = 0.05        # C_D na corrida
    mu: float = 0.04           # atrito de rolamento


@dataclass
class Requirements:
    rho: float = 1.225
    V_stall: float = 11.0      # V_S máxima (m/s)
    S_G: float = 50.0          # corrida de decolagem máxima (m)
    V_cruise: float = 16.0
    V_climb: float = 13.0
    roc: float = 2.0           # razão de subida (m/s)
    n_turn: float = 2.0        # fator de carga em curva sustentada ...
    V_turn: float = 14.0       # ... a esta velocidade
    h_ceiling: float = 0.0     # teto pedido (m); 0: não verifica
    roc_ceiling: float = 0.5
    thrust_rho_exp: float = 1.0   # T ∝ (ρ/ρ0)^m


def _q(rho, V):
    return 0.5 * rho * V * V


def isa_rho(h: float) -> float:
    return 1.225 * (1 - 2.25577e-5 * h) ** 4.2559


def required_tw(kind: str, ws, r: Requirements, a: AeroModel):
    ws = np.asarray(ws, float)
    if kind == "curva":
        q = _q(r.rho, r.V_turn)
        return q * (a.CD0 / ws + a.k * (r.n_turn / q) ** 2 * ws)
    if kind == "subida":
        q = _q(r.rho, r.V_climb)
        return r.roc / r.V_climb + q * a.CD0 / ws + a.k * ws / q
    if kind == "cruzeiro":
        q = _q(r.rho, r.V_cruise)
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


def stall_ws(r: Requirements, a: AeroModel) -> float:
    return 0.5 * r.rho * r.V_stall ** 2 * a.CLmax


KINDS = (("decolagem", "corrida de decolagem"), ("subida", "razão de subida"), ("cruzeiro", "velocidade de cruzeiro"),
         ("curva", "curva sustentada"), ("teto", "teto"))


def constraint_curves(r: Requirements, a: AeroModel, ws) -> dict[str, np.ndarray]:
    out = {"ws": np.asarray(ws, float)}
    for k, _ in KINDS:
        if k == "teto" and r.h_ceiling <= 0:
            continue
        out[k] = required_tw(k, ws, r, a)
    return out


def design_point(r: Requirements, a: AeroModel, ws=None) -> dict:
    """menor T/W viável e a W/S correspondente (respeitando o estol)"""
    ws_max = stall_ws(r, a)
    ws = np.linspace(0.05 * ws_max, ws_max, 400) if ws is None else np.asarray(ws, float)
    ws = ws[ws <= ws_max]
    c = constraint_curves(r, a, ws)
    env = np.max(np.vstack([c[k] for k in c if k != "ws"]), axis=0)
    i = int(np.argmin(env))
    active = max((k for k in c if k != "ws"), key=lambda k: c[k][i])
    return dict(ws=float(ws[i]), tw=float(env[i]), active=active, ws_stall=ws_max)

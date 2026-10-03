"""Pós-processamento dos registros (independente do núcleo): etapas, curvas, decolagem."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import LogChunk

# bits de violação da decolagem
V_TAIL, V_STALL, V_Q, V_VSAFE, V_EARLY, V_NOCLIMB, V_BOUNCE = 1, 2, 4, 8, 16, 32, 64
VIOLATION_NAMES = {V_TAIL: "cauda no chão", V_STALL: "estol", V_Q: "q alto", V_VSAFE: "V/γ em h_t",
                   V_EARLY: "saiu antes de puxar", V_NOCLIMB: "não subiu", V_BOUNCE: "quicou"}


def takeoff_violations(ev: dict, Vs: float, lim: dict) -> int:
    v = 0
    if not ev.get("completed"):
        v |= V_NOCLIMB
    if ev["hcmin"] < lim.get("dmin", 0.03):
        v |= V_TAIL
    if ev["ratio_to"] > lim.get("kCL", 0.95):
        v |= V_STALL
    if math.degrees(ev["qpeak_to"]) > lim.get("qmax", 50.0):
        v |= V_Q
    if ev["VHt"] < 1.2 * Vs or math.degrees(ev["gHt"]) > lim.get("gmax", 20.0):
        v |= V_VSAFE
    if ev["tR"] < 0 or (ev["tLO"] >= 0 and ev["tLO"] < ev["tR"]):
        v |= V_EARLY
    if ev.get("bounced"):
        v |= V_BOUNCE
    return v


def violation_text(v: int) -> str:
    return ", ".join(n for b, n in VIOLATION_NAMES.items() if v & b) or "ok"


def stages(T: LogChunk, ev: dict) -> np.ndarray:
    """0 = corrida no chão, 1..N = pernas, N+1 = rolagem depois do toque"""
    e = T["seg"].astype(int) + 1
    if ev.get("tLO", -1) > 0:
        e[T["t"] < ev["tLO"]] = 0
    if ev.get("tTD", -1) > 0:
        e[T["t"] >= ev["tTD"]] = int(T["seg"].max()) + 2
    return e


def stage_table(T: LogChunk, ev: dict, names: list[str], Vs: float) -> list[dict]:
    if not len(T):
        return []
    et = stages(T, ev)
    nm = ["corrida no chão"] + list(names) + ["rolagem"]
    t = T["t"]
    dt = np.gradient(t) if len(t) > 1 else np.zeros_like(t)
    out = []
    for k in range(len(nm)):
        s = et == k
        if s.sum() < 2:
            continue
        g = lambda c: T[c][s]
        voo = g("Va") > 4
        out.append(dict(
            etapa=nm[k], t_ini=float(t[s][0]), duracao=float(t[s][-1] - t[s][0]),
            distancia=float(np.sum(g("Vg") * dt[s])), h_min=float(g("h").min()), h_max=float(g("h").max()),
            Va_min=float(g("Va").min()), Va_med=float(g("Va").mean()), Va_max=float(g("Va").max()),
            Va_min_Vs=float(g("Va").min() / Vs) if Vs else float("nan"),
            subida_max=float(g("hdot").max()), descida_max=float(-g("hdot").min()),
            phi_max=float(np.degrees(np.abs(g("phi")).max())), nz_max=float(g("nz").max()),
            alfa_max=float(np.degrees(g("alpha")[voo].max())) if voo.any() else 0.0,
            CL_CLmax_max=float(g("ratioCL")[voo].max()) if voo.any() else 0.0,
            acelerador_med=float(g("thr").mean()), energia_Wh=float(g("E")[-1] - g("E")[0])))
    return out


def evaluate_turn(T: LogChunk, seg: dict, k: int, R: float, Vs: float, kCL: float = 0.95,
                  phimax: float = 75.0) -> dict:
    """métricas de uma curva: transitório inteiro e regime (depois de 90°)"""
    s = T["seg"] == k
    if s.sum() < 5:
        return dict(R=R, ok=False, motivo="não chegou à curva")
    dts = np.gradient(T["t"])
    perm = s & (T["s"] >= R * math.pi / 2)
    if perm.sum() < 5:
        perm = s
    d = np.hypot(T["n"] - seg["cn"], T["e"] - seg["ce"])
    o = dict(R=R, V=seg["V1"],
             razao_max=float(T["ratioCL"][s].max()), phi_max=float(np.degrees(np.abs(T["phi"][s]).max())),
             phi_perm=float(np.degrees(np.median(np.abs(T["phi"][perm])))), nz_max=float(T["nz"][s].max()),
             nz_perm=float(np.median(T["nz"][perm])), Va_min=float(T["Va"][s].min()),
             alfa_perm=float(np.degrees(np.median(T["alpha"][perm]))),
             razao_perm=float(np.median(T["ratioCL"][perm])),
             perda_h=float(T["h"][s][0] - T["h"][s].min()), hdot_perm=float(np.mean(T["hdot"][perm])),
             erro_p90=float(np.percentile(np.abs(T["ect"][perm]), 90)), R_real=float(np.median(d[perm])),
             t_estol=float(np.sum(dts[s & (T["ratioCL"] > kCL)])), t_alim=float(np.sum(dts[s & (T["alim"] > 0.5)])))
    tol = max(3.0, 0.15 * R)
    estol = o["t_estol"] > 0.3
    segue = o["erro_p90"] <= tol and abs(o["R_real"] - R) <= tol
    altura = o["perda_h"] <= 3.0 and o["hdot_perm"] > -0.5
    controle = o["phi_max"] <= phimax + 15 and T["h"][s].min() > 0.5 and o["Va_min"] > 0.9 * Vs
    o["ok"] = controle and not estol and segue and altura
    o["motivo"] = ("ok" if o["ok"] else "perda de controle" if not controle else "estol da asa" if estol
                   else "asa no limite de α" if o["t_alim"] > 0.3 else "não segue o raio" if not segue
                   else "perde altura")
    return o


def min_radius(results: list[dict]) -> float:
    """menor raio a partir do qual TODOS os maiores também passam"""
    ordem = sorted(results, key=lambda o: o["R"])
    for i, o in enumerate(ordem):
        if all(p["ok"] for p in ordem[i:]):
            return o["R"]
    return float("nan")


def columns(rows: list[dict]) -> dict[str, list]:
    """lista de dicionários -> dicionário de colunas (para séries do resultado)"""
    if not rows:
        return {}
    return {k: [r.get(k) for r in rows] for k in rows[0]}


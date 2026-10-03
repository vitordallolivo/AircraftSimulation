"""Séries de gráfico de um voo simulado, no estilo dos gráficos do código original (legacy/py/graficos.py):
uma cor por etapa do voo (corrida no chão, cada perna do percurso, rolagem), fundo colorido por
etapa nos gráficos no tempo, estrelas nos eventos (decolou, piloto automático, soltura, impacto,
toque, parada), e janelas ampliadas da decolagem, do pouso e da soltura da carga (LAPES).

Tudo aqui é função pura: registro + eventos -> {nome da série: colunas e estilo}. Quem desenha é a
GUI (LivePlots) ou tools/plot_comparativo.py; quem decide quais gráficos existem é a simulação.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import LogChunk

from .analysis import stages

# cores por etapa (as mesmas do original)
STAGE_COLORS = ["#7f7f7f", "#d62728", "#ff7f0e", "#1f77b4", "#2ca02c", "#9467bd", "#8c564b", "#17becf",
                "#bcbd22", "#e377c2", "#000000", "#aec7e8", "#ffbb78"]
PAYLOAD = "#6a0dad"
# parcelas dos momentos (canal do registro, rótulo, cor)
COMPONENTS = [("wing", "asa", "#1f77b4"), ("ht", "EH", "#2ca02c"), ("vt", "EV", "#9467bd"), ("fus", "fuselagem", "#8c564b"),
              ("prop", "hélice", "#d62728"), ("gyro", "giroscópico", "#e377c2"),
              ("gear", "trem", "#7f7f7f"), ("liq", "líquido", "#17becf"), ("pay", "LAPES", PAYLOAD)]
EVENT_STYLE = {"decolou": "#1f77b4", "piloto automático": "#000000", "soltura da carga": PAYLOAD,
               "impacto da carga": PAYLOAD, "toque no pouso": "#2ca02c", "parada": "#d62728"}
DEG = 180.0 / math.pi


def stage_names(leg_names: list[str]) -> list[str]:
    return ["corrida no chão"] + list(leg_names) + ["rolagem"]


def stage_color(k: int) -> str:
    return STAGE_COLORS[k % len(STAGE_COLORS)]


def _col(T: LogChunk, k: str) -> np.ndarray:
    a = np.asarray(T[k], float)
    return a * DEG if k in ("phi", "theta", "psi", "p", "q", "r", "alpha", "beta", "gamma", "chi", "de", "da", "dr",
                            "dw", "phic", "alc", "thc") else a


def _idx(T: LogChunk, t: float) -> int:
    return int(min(max(np.searchsorted(T["t"], t), 0), len(T["t"]) - 1))


def by_stage(T: LogChunk, ev: dict, leg_names: list[str], prefix: str, cols: dict[str, str]) -> dict:
    """uma tabela por etapa (cor da etapa); `cols`: nome da coluna no gráfico -> canal do registro.
    Cada trecho repete o primeiro ponto do seguinte, para a linha não ter buracos."""
    et = stages(T, ev)
    names = stage_names(leg_names)
    out = {}
    for k in range(len(names)):
        idx = np.where(et == k)[0]
        if not len(idx):
            continue
        j = np.r_[idx, min(idx[-1] + 1, len(et) - 1)]
        label = names[k]
        key = f"{prefix}{label}"
        while key in out:
            key += " "
        out[key] = {c: _col(T, ch)[j] for c, ch in cols.items()}
        out[key]["_color"] = stage_color(k)
        out[key]["_width"] = 2.2
    return out


def stage_spans(T: LogChunk, ev: dict, leg_names: list[str], prefix: str, x: str = "t") -> dict:
    """fundo colorido por etapa (em t ou outra coluna crescente)"""
    et = stages(T, ev)
    names = stage_names(leg_names)
    xs = _col(T, x)
    out = {}
    for k in range(len(names)):
        idx = np.where(et == k)[0]
        if len(idx) < 2:
            continue
        out[f"{prefix}▮ {names[k]}"] = {"_vspan": [float(xs[idx[0]]), float(xs[idx[-1]])], "_color": stage_color(k),
                                        "_alpha": 30, "_label": names[k]}
    return out


def events_points(T: LogChunk, ev: dict) -> list[tuple[str, float]]:
    """(nome, t) dos eventos que aconteceram"""
    pts = []
    for name, key in (("decolou", "tLO"), ("piloto automático", "tHt"), ("soltura da carga", "trel"),
                      ("toque no pouso", "tTD")):
        if ev.get(key, -1) > 0 and ev[key] <= T["t"][-1]:
            pts.append((name, float(ev[key])))
    if ev.get("completed") and ev.get("tTD", -1) > 0:
        pts.append(("parada", float(T["t"][-1])))
    return pts


def event_stars(T: LogChunk, ev: dict, prefix: str, cols: dict[str, str]) -> dict:
    out = {}
    for name, t in events_points(T, ev):
        i = _idx(T, t)
        out[f"{prefix}★ {name}"] = {c: np.array([_col(T, ch)[i]]) for c, ch in cols.items()}
        out[f"{prefix}★ {name}"].update(_symbol="star", _color=EVENT_STYLE.get(name, "#ffcc00"), _size=18)
    if ev.get("pk_t", 0) > 0 and "n" in cols.values():           # impacto da carga (no chão)
        m = {"n": ev["pk_n"], "e": ev["pk_e"], "h": 0.0}
        if all(ch in m for ch in cols.values()):
            out[f"{prefix}★ impacto da carga"] = {c: np.array([m[ch]]) for c, ch in cols.items()}
            out[f"{prefix}★ impacto da carga"].update(_symbol="star", _color=PAYLOAD, _size=18)
    return out


def payload_path(T: LogChunk, prefix: str, cols: dict[str, str]) -> dict:
    """trajetória da carga com paraquedas (canais pk_*)"""
    if "pk_h" not in T.columns:
        return {}
    s = T["pk_h"] > 0
    if s.sum() < 2:
        return {}
    m = {"n": "pk_n", "e": "pk_e", "h": "pk_h"}
    return {f"{prefix}carga LAPES": {c: np.asarray(T[m.get(ch, ch)], float)[s] for c, ch in cols.items()}
            | {"_color": PAYLOAD, "_width": 3.0}}


def terrain_profile(T: LogChunk, prefix: str, x: str = "n") -> dict:
    """chão/mesa/plataforma sob a aeronave"""
    if "hgnd" not in T.columns or not np.any(np.asarray(T["hgnd"]) > 0):
        return {}
    return {f"{prefix}terreno": {x: _col(T, x), "h": np.asarray(T["hgnd"], float),
                                                    "_color": "#5b3a1a", "_width": 3.0}}


# ------------------------------------------------------------------ figuras
def trajectory(T: LogChunk, ev: dict, legs: list[str], target: tuple[float, float] | None = None) -> dict:
    """3D e os três planos, cada um com as etapas coloridas, a carga, os eventos e o terreno"""
    S = {}
    c3 = {"e": "e", "n": "n", "h": "h"}
    S.update(by_stage(T, ev, legs, "t3_", c3))
    S.update(payload_path(T, "t3_", c3))
    S["t3_sombra"] = {"e": _col(T, "e"), "n": _col(T, "n"), "h": np.asarray(T["hgnd"], float)
                              if "hgnd" in T.columns else 0 * _col(T, "h"), "_color": "#b0b0b0", "_width": 1.0}
    S.update(event_stars(T, ev, "t3_", c3))
    for pre, cols in (("xy_", {"n": "n", "e": "e"}), ("xz_", {"n": "n", "h": "h"}), ("zy_", {"e": "e", "h": "h"})):
        S.update(by_stage(T, ev, legs, pre, cols))
        S.update(payload_path(T, pre, cols))
        S.update(event_stars(T, ev, pre, cols))
    S.update(terrain_profile(T, "xz_", "n"))
    if target is not None:
        for pre, cols in (("xy_", ("n", "e")), ("xz_", ("n", "h"))):
            vals = {"n": target[0], "e": target[1], "h": 0.0}
            S[f"{pre}alvo da carga"] = {c: np.array([vals[c]]) for c in cols} | {"_symbol": "t", "_color": "#000000",
                                                                                 "_size": 14}
    return S


def time_series(T: LogChunk, ev: dict, legs: list[str], refs: dict) -> dict:
    """gráficos no tempo com o fundo por etapa: ângulos, rumo, velocidades, altura, C_L, C_D,
    momentos por parcela, comandos, acelerador, subida, fator de carga, motor, energia, sloshing"""
    S = {}
    t = _col(T, "t")
    fly = T["Va"] > 6

    def add(prefix, curves, lines=()):
        S.update(stage_spans(T, ev, legs, prefix))
        for lab, y, color, w in curves:
            S[f"{prefix}{lab}"] = {"t": t, "y": y, "_color": color, "_width": w}
        for lab, v, color, dash in lines:
            S[f"{prefix}{lab}"] = {"_hline": v, "_color": color, "_dash": dash}

    nan = lambda k: np.where(fly, _col(T, k), np.nan)
    add("ang_", [("θ", _col(T, "theta"), "#1f77b4", 1.4), ("α", nan("alpha"), "#d62728", 1.4),
                 ("γ", _col(T, "gamma"), "#2ca02c", 1.2), ("φ", _col(T, "phi"), "#ff7f0e", 1.2),
                 ("β", nan("beta"), "#9467bd", 1.0)],
        [("α de estol", refs.get("alpha_stall", 14.0), "#000000", "dot")])
    add("rumo_", [("ψ", np.degrees(np.unwrap(np.asarray(T["psi"], float))), "#1f77b4", 1.4),
                  ("χ", np.degrees(np.unwrap(np.asarray(T["chi"], float))), "#2ca02c", 1.0)])
    Vs = refs.get("Vs", 0.0)
    add("vel_", [("V_a", _col(T, "Va"), "#d62728", 1.6),
                 ("V_g", _col(T, "Vg"), "#1f77b4", 1.0), ("V_ref", _col(T, "Vref"), "#000000", 0.8)],
        [("V_s", Vs, "#7f7f7f", "dot"), ("1,2 V_s", 1.2 * Vs, "#7f7f7f", "dash")] if Vs else ())
    href = np.where(t >= ev.get("tHt", 1e9) if ev.get("tHt", -1) >= 0 else False, _col(T, "href"), np.nan)
    add("alt_", [("h", _col(T, "h"), "#d62728", 1.6), ("h_ref", href, "#000000", 0.8)]
        + ([("terreno", np.asarray(T["hgnd"], float), "#5b3a1a", 1.5)] if "hgnd" in T.columns and
           np.any(np.asarray(T["hgnd"]) > 0) else []))
    add("cl_", [("C_L", nan("CL"), "#000000", 1.6), ("C_L asa", nan("CL_wing"), "#1f77b4", 1.0),
                ("C_L EH", nan("CL_ht"), "#2ca02c", 1.0),
                ("C_L/C_Lmax", nan("ratioCL"), "#d62728", 0.9)],
        [("limite", refs.get("kCL", 0.95), "#d62728", "dash")])
    add("cd_", [("C_D", nan("CD"), "#000000", 1.6), ("C_Di", nan("CDi"), "#1f77b4", 1.0),
                ("C_D0", nan("CD") - nan("CDi"), "#7f7f7f", 1.0)])
    for ax, label in (("L", "rolamento"), ("M", "arfagem"), ("N", "guinada")):
        cur = []
        for k, lab, c in COMPONENTS:
            y = np.asarray(T[f"{ax}_{k}"], float)
            if np.nanmax(np.abs(y)) > 1e-6:                       # só as parcelas que existem nesta aeronave
                cur.append((lab, y, c, 0.9))
        cur.append(("total", np.asarray(T[f"{ax}_tot"], float), "#000000", 1.6))
        add(f"mom{ax}_", cur)
    cmd = [("$\\delta_e$", _col(T, "de"), "#2ca02c", 1.2), ("$\\delta_a$", _col(T, "da"), "#1f77b4", 1.2),
           ("$\\delta_r$", _col(T, "dr"), "#ff7f0e", 1.2), ("$\\delta_w$", _col(T, "dw"), "#7f7f7f", 1.0)]
    add("cmd_", [c for c in cmd if np.nanmax(np.abs(c[1])) > 1e-6] or cmd[:1])
    add("thr_", [("acelerador", _col(T, "thr"), "#d62728", 1.4)])
    add("roc_", [("dh/dt", _col(T, "hdot"), "#2ca02c", 1.4)], [("zero", 0.0, "#000000", "dot")])
    add("nz_", [("n_z", _col(T, "nz"), "#d62728", 1.4)], [("1 g", 1.0, "#000000", "dot")])
    rpm = np.asarray(T["rpm_0"], float) if "rpm_0" in T.columns else np.full(len(t), np.nan)
    add("motor_", [("rpm/100", rpm / 100.0, "#d62728", 1.2),
                   ("$I$ (A)", _col(T, "Ibat"), "#1f77b4", 1.2),
                   ("$T$ (N)", _col(T, "T"), "#2ca02c", 1.2)])
    add("ene_", [("$E$ (Wh)", _col(T, "E"), "#2ca02c", 1.6)])
    if "slosh_x_0" in T.columns and np.nanmax(np.abs(T["slosh_x_0"])) > 1e-9:
        add("slosh_", [("η_x", np.degrees(np.asarray(T["slosh_x_0"], float)), "#1f77b4", 1.0),
                       ("η_y", np.degrees(np.asarray(T["slosh_y_0"], float)), "#d62728", 1.0)])
    return S


def takeoff_window(T: LogChunk, ev: dict, refs: dict, airfield=None) -> dict:
    """decolagem com a posição na pista no eixo x: altura e folga da cauda, velocidades, ângulos,
    comandos, reações no trem (molas e o modelo do artigo), momentos do trem; com as marcas do
    comando do profundor, saída da bequilha, decolagem, piloto automático e a distância máxima"""
    if not len(T):
        return {}
    t = np.asarray(T["t"], float)
    t1 = ev["tHt"] + 4.0 if ev.get("tHt", -1) > 0 else t[-1]
    s = t <= t1
    if s.sum() < 3:
        return {}
    D = {k: _col(T, k)[s] for k in ("n", "h", "htail", "Va", "Vg", "theta", "alpha", "gamma", "de", "dw", "dr", "da",
                                    "thr", "N_steer", "N_main", "N_skid", "Rnw", "Rmw", "RN", "L_gear", "M_gear",
                                    "N_gear", "hgnd")}
    x = D["n"]
    S = {}
    marks = []
    if ev.get("tR", -1) >= 0:
        marks.append(("aciona o profundor", float(np.interp(ev["tR"], t, T["n"])), "#2ca02c", "dashdot"))
    if ev.get("tRot", -1) > 0:
        marks.append(("bequilha sai do chão", float(ev["nRot"]), "#ff7f0e", "dot"))
    if ev.get("tLO", -1) > 0:
        marks.append(("decolou", float(ev["nLO"]), "#1f77b4", "dot"))
    if ev.get("tHt", -1) > 0:
        marks.append(("h_t", float(ev["nHt"]), "#000000", "dot"))
    lim = refs.get("x_warning", 0.0)
    if airfield is not None and airfield.takeoff_from == "mesa":
        marks.append(("borda da mesa", float(airfield.table_length), "#5b3a1a", "dash"))

    def fig(prefix, curves, hlines=()):
        for lab, y, c, w in curves:
            S[f"{prefix}{lab}"] = {"n": x, "y": y, "_color": c, "_width": w}
        for lab, v, c, d in hlines:
            S[f"{prefix}{lab}"] = {"_hline": v, "_color": c, "_dash": d}
        for lab, v, c, d in marks:
            S[f"{prefix}{lab}"] = {"_vline": v, "_color": c, "_dash": d}
        if lim > 0:
            S[f"{prefix}x_warning = {lim:g} m"] = {"_vline": lim, "_color": "#d62728", "_width": 3,
                                                                    "_dash": None}
    h0 = D["h"][0]
    hcur = [("h do CG", D["h"] - h0, "#d62728", 1.6),
            ("folga da cauda", np.where(D["htail"] < 1e6, D["htail"], np.nan), "#7f7f7f", 1.2)]
    if np.any(D["hgnd"] > 0):
        hcur.append(("mesa", D["hgnd"] - D["hgnd"][0], "#5b3a1a", 2.0))
    zw = refs.get("z_warning")
    fig("dh_", hcur, [("h_t", refs.get("ht", 2.0), "#000000", "dot")]
        + ([(f"z_warning = {zw:g} m", zw, "#d62728", None)] if zw is not None else []))
    Vs = refs.get("Vs", 0.0)
    fig("dv_", [("V_a", D["Va"], "#d62728", 1.6), ("V_g", D["Vg"], "#1f77b4", 1.2)],
        [("V_s", Vs, "#000000", "dot"), ("1,2 V_s", 1.2 * Vs, "#000000", "dash")] if Vs else ())
    fig("da_", [("θ", D["theta"], "#1f77b4", 1.4), ("α", D["alpha"], "#d62728", 1.4), ("γ", D["gamma"], "#2ca02c", 1.2)],
        [("α de estol", refs.get("alpha_stall", 14.0), "#d62728", "dot")]
        + ([("θ cauda", refs["theta_tail"], "#7f7f7f", "dash")] if refs.get("theta_tail") else []))
    cmd = [("$\\delta_e$", D["de"], "#2ca02c", 1.4), ("$\\delta_w$", D["dw"], "#7f7f7f", 1.0),
           ("$\\delta_r$", D["dr"], "#ff7f0e", 1.0), ("$\\delta_a$", D["da"], "#1f77b4", 1.0),
           ("acel. × 10", 10 * D["thr"], "#d62728", 1.0)]
    fig("dc_", [c for c in cmd if np.nanmax(np.abs(c[1])) > 1e-6])
    Rn, Rm, i2 = _article(D)
    fig("dr_", [("TDN", D["N_steer"], "#ff7f0e", 2.0), ("TDP", D["N_main"], "#1f77b4", 2.0)]
        + ([("cauda", D["N_skid"], "#7f7f7f", 1.2)] if np.nanmax(D["N_skid"]) > 0 else [])
        + [("TDN artigo", np.r_[Rn[:i2 + 1], np.full(len(Rn) - i2 - 1, np.nan)], "#ff7f0e", 1.0),
           ("TDP artigo", np.r_[Rm[:i2 + 1], np.full(len(Rm) - i2 - 1, np.nan)], "#1f77b4", 1.0)])
    for k in ("dr_TDN artigo", "dr_TDP artigo"):
        S[k]["_dash"] = "dash"
    fig("dm_", [("$L$", D["L_gear"], "#1f77b4", 1.4), ("$M$", D["M_gear"], "#d62728", 1.6),
                ("$N$", D["N_gear"], "#2ca02c", 1.4)])
    return S


def _article(D: dict):
    """fases do artigo (Riboldi et al.): corrida (eq. 5) até TDN = 0; rotação (eq. 6) até R_N = 0"""
    Rn, Rm, RN = D["Rnw"].copy(), D["Rmw"].copy(), D["RN"].copy()
    i1 = int(np.argmax(Rn <= 0)) if (Rn <= 0).any() else len(Rn)
    Rn[i1:] = 0
    Rm[i1:] = RN[i1:]
    i2 = i1 + (int(np.argmax(RN[i1:] <= 0)) if (RN[i1:] <= 0).any() else len(RN) - i1)
    Rn[i2:] = 0
    Rm[i2:] = 0
    return Rn, Rm, min(i2, len(Rn) - 1)


def landing_window(T: LogChunk, ev: dict, refs: dict, airfield=None, pads=()) -> dict:
    """reações e momentos do trem depois do toque (posição na pista no eixo x), a plataforma e o
    limite de distância de pouso"""
    if ev.get("tTD", -1) <= 0:
        return {}
    t = np.asarray(T["t"], float)
    s = t >= ev["tTD"] - 1.0
    if s.sum() < 3:
        return {}
    x = np.asarray(T["n"], float)[s]
    S = {}

    def fig(prefix, curves):
        for lab, y, c, w, d in curves:
            S[f"{prefix}{lab}"] = {"n": x, "y": np.asarray(y, float)[s], "_color": c, "_width": w, "_dash": d}
        S[f"{prefix}★ toque"] = {"n": np.array([ev["nTD"]]), "y": np.array([0.0]), "_symbol": "star",
                                 "_color": "#2ca02c"}
        if ev.get("completed"):
            S[f"{prefix}★ parada"] = {"n": np.array([ev["nStop"]]), "y": np.array([0.0]), "_symbol": "star",
                                      "_color": "#d62728"}
        for q in pads:
            if q.get("landing"):
                a, b = sorted((q["n0"], q["n0"] + q["L"] * math.cos(q["chi"])))
                S[f"{prefix}▮ plataforma de pouso"] = {"_vspan": [a, b], "_color": "#5b3a1a", "_alpha": 40,
                                                       "_label": "plataforma de pouso"}
        if refs.get("landing_max", 0) > 0:
            S[f"{prefix}distância máxima de pouso"] = {"_vline": ev["nTD"] + refs["landing_max"], "_color": "#d62728",
                                                       "_width": 3}
    fig("pr_", [("TDN", T["N_steer"], "#ff7f0e", 2.0, None),
                ("TDP", T["N_main"], "#1f77b4", 2.0, None),
                ("TDN artigo", np.where((T["N_steer"] > 0) | (T["N_main"] > 0), T["Rnw"], np.nan), "#ff7f0e", 1.0, "dash"),
                ("TDP artigo", np.where((T["N_steer"] > 0) | (T["N_main"] > 0), T["Rmw"], np.nan), "#1f77b4", 1.0, "dash")])
    fig("pm_", [("$L$", T["L_gear"], "#1f77b4", 1.4, None), ("$M$", T["M_gear"], "#d62728", 1.6, None),
                ("$N$", T["N_gear"], "#2ca02c", 1.4, None)])
    return S


def lapes_window(T: LogChunk, ev: dict, target_n: float | None = None, before: float = 2.0, after: float = 5.0) -> dict:
    """zoom na soltura: o CG anda para trás com a carga, a massa cai, a resposta em arfagem e a
    aeronave e a carga no plano xz"""
    if ev.get("tdrop", -1) <= 0:
        return {}
    t = np.asarray(T["t"], float)
    t0 = ev["tdrop"]
    s = (t >= t0 - before) & (t <= t0 + after)
    if s.sum() < 3:
        return {}
    tt = t[s] - t0
    S = {}
    ext = {"_vspan": [0.0, (ev["trel"] - t0) if ev.get("trel", -1) > 0 else 0.0], "_color": PAYLOAD, "_alpha": 35,
           "_label": "extração"}
    S["lc_▮ extração"] = dict(ext)
    S["lc_x_CG"] = {"t": tt, "y": 100 * np.asarray(T["xcg"], float)[s], "_color": "#1f77b4"}
    S["lc_carga na baia"] = {"t": tt, "y": 100 * np.asarray(T["sL"], float)[s], "_color": PAYLOAD}
    S["lm_▮ extração"] = dict(ext)
    S["lm_m"] = {"t": tt, "y": np.asarray(T["m"], float)[s], "_color": "#d62728"}
    S["lp_▮ extração"] = dict(ext)
    for k, lab, c in (("theta", "θ (°)", "#1f77b4"), ("alpha", "α (°)", "#d62728"), ("q", "q (°/s)", "#ff7f0e"),
                      ("de", "δe (°)", "#2ca02c")):
        S[f"lp_{lab}"] = {"t": tt, "y": _col(T, k)[s], "_color": c}
    S["lp_M_pay"] = {"t": tt, "y": np.asarray(T["M_pay"], float)[s], "_color": PAYLOAD, "_label": "M_LAPES (N·m)"}
    w = (t >= t0 - before) & (t <= t0 + after + 4)
    S["lx_aeronave"] = {"n": np.asarray(T["n"], float)[w], "h": np.asarray(T["h"], float)[w], "_color": "#9467bd",
                             "_width": 2.0}
    pk = np.asarray(T["pk_h"], float) > 0
    if pk.any():
        S["lx_carga"] = {"n": np.asarray(T["pk_n"], float)[pk], "h": np.asarray(T["pk_h"], float)[pk],
                                        "_color": PAYLOAD, "_width": 3.0}
    i = _idx(T, t0)
    S["lx_★ extração"] = {"n": np.array([T["n"][i]]), "h": np.array([T["h"][i]]), "_symbol": "star",
                                    "_color": PAYLOAD}
    if ev.get("pk_t", 0) > 0:
        S["lx_★ impacto da carga"] = {"n": np.array([ev["pk_n"]]), "h": np.array([0.0]), "_symbol": "star",
                                      "_color": "#d62728"}
    if target_n is not None:
        S["lx_alvo"] = {"n": np.array([target_n]), "h": np.array([0.0]), "_symbol": "t", "_color": "#000000",
                        "_size": 14}
    return S


# ------------------------------------------------------------------ avião ao longo da trajetória
# silhueta no corpo (x frente, y direita, z baixo), em semienvergaduras: fuselagem, asa, EH e EV
_SHAPE = np.array([[0.45, 0, 0], [-0.75, 0, 0], [0.05, -1, 0], [0.05, 1, 0], [-0.05, -1, 0], [-0.05, 1, 0],
                   [0.05, -1, 0], [-0.05, -1, 0], [0.05, 1, 0], [-0.05, 1, 0],
                   [-0.7, -0.35, 0], [-0.7, 0.35, 0], [-0.7, 0, 0], [-0.78, 0, -0.32]], float)


def _rot(phi, th, psi):
    cf, sf, ct, st, cp, sp = np.cos(phi), np.sin(phi), np.cos(th), np.sin(th), np.cos(psi), np.sin(psi)
    return np.array([[ct * cp, sf * st * cp - cf * sp, cf * st * cp + sf * sp],
                     [ct * sp, sf * st * sp + cf * cp, cf * st * sp - sf * cp],
                     [-st, sf * ct, cf * ct]])


def aircraft_glyphs(T: LogChunk, ev: dict, leg_names: list[str], step: float, span: float, prefix="t3_") -> dict:
    """o avião desenhado a cada `step` metros de trajetória, na atitude daquele instante (cor da etapa).
    Cada tabela traz o centro (e, n, h) e o deslocamento da silhueta (oe, on, oh) de cada ponta de segmento;
    o 3D estica só a altura do centro, não a silhueta. `span`: envergadura desenhada (m)."""
    if step <= 0 or not len(T):
        return {}
    n, e, h = (np.asarray(T[k], float) for k in ("n", "e", "h"))
    ds = np.r_[0.0, np.hypot(np.diff(n), np.diff(e))]
    s = np.cumsum(ds)
    marks = np.arange(0.0, s[-1], step)
    idx = np.unique(np.searchsorted(s, marks).clip(0, len(s) - 1))
    et = stages(T, ev)
    names = stage_names(leg_names)
    shape = _SHAPE * (span / 2)
    out = {}
    for k in np.unique(et[idx]):
        sel = idx[et[idx] == k]
        C, O = [], []
        for i in sel:
            R = _rot(T["phi"][i], T["theta"][i], T["psi"][i])
            p = shape @ R.T                                   # NED
            O.append(np.column_stack([p[:, 1], p[:, 0], -p[:, 2]]))
            C.append(np.repeat([[e[i], n[i], h[i]]], len(shape), axis=0))
        C, O = np.vstack(C), np.vstack(O)
        out[f"{prefix}✈ {names[k]}"] = {"e": C[:, 0], "n": C[:, 1], "h": C[:, 2], "oe": O[:, 0], "on": O[:, 1],
                                        "oh": O[:, 2], "_segments": 1, "_color": stage_color(int(k)), "_nolegend": 1,
                                        "_width": 1.6}
    return out


# ------------------------------------------------------------------ bateria por etapa
def battery_by_stage(T: LogChunk, ev: dict, leg_names: list[str], capacity_mAh: float, peukert_n: float = 1.05,
                     Rt_h: float = 1.0) -> tuple[list[dict], dict]:
    """tempo, corrente média, consumo (mAh) e descarga estimada por etapa (Coulomb e Peukert, Traub 2011);
    devolve (linhas da tabela, séries do gráfico de consumo acumulado)"""
    if not len(T) or "Ibat" not in T.columns:
        return [], {}
    t = np.asarray(T["t"], float)
    I = np.clip(np.asarray(T["Ibat"], float), 0, None)
    dt = np.r_[np.diff(t), 0.0]
    dt = np.where(dt > 0, dt, 0.0)
    C_Ah = max(capacity_mAh / 1000.0, 1e-9)
    # Peukert: com corrente I o pacote dura t(I) = R_t (C / (I R_t))^n -> fração gasta = Σ dt / t(I)
    tI = Rt_h * 3600.0 * np.where(I > 1e-6, (C_Ah / np.maximum(I * Rt_h, 1e-9)) ** peukert_n, np.inf)
    mAh = np.cumsum(I * dt) / 3.6
    pk = np.cumsum(np.where(np.isfinite(tI), dt / tI, 0.0)) * 100
    et = stages(T, ev)
    names = stage_names(leg_names)
    rows = []
    for k in range(len(names)):
        s = et == k
        if s.sum() < 2:
            continue
        dur = float(dt[s].sum())
        q = float((I[s] * dt[s]).sum() / 3.6)
        rows.append(dict(etapa=names[k], tempo_s=dur, corrente_media_A=q * 3.6 / dur if dur > 0 else 0.0,
                         consumo_mAh=q, descarga_peukert_pct=float(np.sum(np.where(np.isfinite(tI[s]), dt[s] / tI[s], 0)) * 100)))
    rows.append(dict(etapa="total", tempo_s=float(dt.sum()), corrente_media_A=float((I * dt).sum() / max(dt.sum(), 1e-9)),
                     consumo_mAh=float(mAh[-1]), descarga_peukert_pct=float(pk[-1])))
    S = stage_spans(T, ev, leg_names, "bat_")
    S["bat_consumo"] = {"t": t, "y": mAh, "_color": "#1f77b4", "_width": 2.2}
    S[f"bat_capacidade ({capacity_mAh:.0f} mAh)"] = {"_hline": capacity_mAh, "_color": "#d62728", "_width": 2}
    S2 = stage_spans(T, ev, leg_names, "batp_")
    S2["batp_Coulomb"] = {"t": t, "y": mAh / capacity_mAh * 100, "_color": "#1f77b4", "_width": 2}
    S2["batp_Peukert"] = {"t": t, "y": pk, "_color": "#d62728", "_width": 2}
    S2["batp_$I$ (A)"] = {"t": t, "y": I, "_color": "#7f7f7f", "_width": 1}
    S.update(S2)
    return rows, S


def takeoff_angles(T: LogChunk, ev: dict, wing_incidence_deg: float, alpha_stall_deg: float, prefix="dt_") -> dict:
    """ângulo da aeronave (θ) e da asa (θ + incidência) no tempo, na decolagem, com o estol da asa"""
    t = np.asarray(T["t"], float)
    t1 = ev["tHt"] + 4.0 if ev.get("tHt", -1) > 0 else t[-1]
    s = t <= t1
    th = np.degrees(np.asarray(T["theta"], float))[s]
    S = {f"{prefix}θ": {"t": t[s], "y": th, "_color": "#1f77b4", "_width": 2.2},
         f"{prefix}θ + i_w": {"t": t[s], "y": th + wing_incidence_deg,
                                                                "_color": "#ff7f0e", "_width": 2.2},
         f"{prefix}α asa": {"t": t[s], "y": np.degrees(np.asarray(T["alpha"], float))[s] + wing_incidence_deg,
                                    "_color": "#2ca02c", "_width": 1.0, "_dash": "dash"},
         f"{prefix}estol ({alpha_stall_deg:.0f}°)": {"_hline": alpha_stall_deg, "_color": "#d62728", "_dash": "dot"}}
    for name, key in (("aciona o profundor", "tR"), ("decolou", "tLO"), ("piloto automático", "tHt")):
        if ev.get(key, -1) > 0:
            S[f"{prefix}{name}"] = {"_vline": float(ev[key]), "_color": "#7f7f7f", "_dash": "dot"}
    return S


def takeoff_time(T: LogChunk, ev: dict, rho: float, S: float) -> dict:
    """decolagem no tempo: C_L, C_D, sustentação e arrasto, e cada momento junto do comando daquele eixo"""
    t = np.asarray(T["t"], float)
    t1 = ev["tHt"] + 4.0 if ev.get("tHt", -1) > 0 else t[-1]
    s = t <= t1
    t = t[s]
    g = lambda k: np.asarray(T[k], float)[s]
    qS = 0.5 * rho * g("Va") ** 2 * S
    out = {"tcl_C_L": {"t": t, "y": g("CL"), "_color": "#000000", "_width": 2},
           "tcl_C_L asa": {"t": t, "y": g("CL_wing"), "_color": "#1f77b4"},
           "tcd_C_D": {"t": t, "y": g("CD"), "_color": "#000000", "_width": 2},
           "tcd_C_Di": {"t": t, "y": g("CDi"), "_color": "#1f77b4"},
           "tld_L": {"t": t, "y": g("CL") * qS, "_color": "#1f77b4", "_width": 2},
           "tld_D": {"t": t, "y": g("CD") * qS, "_color": "#d62728", "_width": 2},
           "tld_W": {"_hline": float(np.asarray(T["m"], float)[0]) * 9.80665, "_color": "#7f7f7f", "_dash": "dot"}}
    if np.nanmax(np.abs(g("CL_ht"))) > 1e-6:
        out["tcl_C_L EH"] = {"t": t, "y": g("CL_ht"), "_color": "#2ca02c"}
    for ax, ctl, lab in (("L", "da", "δ_a"), ("M", "de", "δ_e"), ("N", "dr", "δ_r")):
        out[f"tm{ax}_{ax} (N·m)"] = {"t": t, "y": g(f"{ax}_tot"), "_color": "#000000", "_width": 2}
        d = np.degrees(g(ctl))
        if np.nanmax(np.abs(d)) > 1e-6:
            out[f"tm{ax}_{lab} (°)"] = {"t": t, "y": d, "_color": "#2ca02c" if ax == "M" else "#1f77b4", "_dash": "dash"}
    for name, key in (("aciona", "tR"), ("decolou", "tLO"), ("h_t", "tHt")):
        if ev.get(key, -1) > 0:
            for p in ("tcl_", "tcd_", "tld_", "tmL_", "tmM_", "tmN_"):
                out[f"{p}{name}"] = {"_vline": float(ev[key]), "_color": "#7f7f7f", "_dash": "dot", "_nolegend": 1}
    return out

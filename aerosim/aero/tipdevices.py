"""Dispositivos de ponta de asa pelo arrasto induzido mínimo no plano de Trefftz.

Teoria (Munk, 1921; Cone, 1962; Kroo, "Drag due to lift: concepts for prediction and
reduction", Annu. Rev. Fluid Mech. 33, 2001; Kroo, McMasters e Smith, "Highly nonplanar
lifting systems", 1995): o arrasto induzido de qualquer sistema sustentador depende só do
traço da esteira no plano de Trefftz e da circulação Γ(s) ao longo dele:
    L = ρ V ∮ Γ dy,        D_i = −(ρ/2) ∮ Γ w_n ds
onde w_n é a velocidade normal que os vórtices livres (dΓ/ds) induzem no traço. Com o traço
discretizado em painéis de Γ constante, D_i = Γᵀ M Γ e L = bᵀ Γ; o mínimo de D_i com L fixo é
M Γ ∝ b (condição de Munk: w_n ∝ cos θ). O fator de eficiência do vão é
    e = L² / (π q b² D_i)       (asa plana elíptica: e = 1).
Resultados de referência (Kroo 2001, fig. 7): asa em caixa com h/b = 0,2 → e ≈ 1,46; asa C ≈ 1,45;
e → 3,7 na caixa quando h/b → ∞ (não-plano infinito).

Comparações empíricas: placa de ponta (Raymer, Aircraft Design, eq. 12.48) AR_ef = AR (1 + 1,9 h/b);
winglet de Whitcomb (NASA TN D-8260, 1976): ~20 % menos arrasto induzido em cruzeiro, cerca do
dobro do ganho de uma extensão de ponta com o mesmo momento fletor na raiz. O ganho líquido
desconta o atrito da área molhada do dispositivo: ΔD/q = C_f S_molhada. Com carregamento ótimo e o
mesmo momento fletor na raiz, a extensão de ponta ainda ganha do winglet (Jones, NACA TN 2249;
Kroo 2001): a vantagem prática do winglet aparece quando o vão é limitado (hangar, categoria,
regulamento de competição) — o estudo mostra os dois lados.
"""
from __future__ import annotations

import math

import numpy as np

TWO_PI = 2 * math.pi


def _seg(a, b, ds):
    """pontos igualmente espaçados (ds igual em todos os segmentos: com espaçamento cosseno o
    painel minúsculo junto às junções faz o resultado não convergir)"""
    a, b = np.asarray(a, float), np.asarray(b, float)
    n = max(2, int(round(math.dist(a, b) / ds)))
    return a + np.outer(np.linspace(0, 1, n + 1), b - a)


def trace(kind: str, h: float = 0.2, n: int = 60, cap: float = 0.25, dihedral_deg: float = 0.0,
          span: float = 1.0) -> list[tuple[np.ndarray, np.ndarray]]:
    """segmentos (pontos (k,2) em y, z) do traço de envergadura `span`; h = altura relativa ao vão
    kind: plana | winglet | placa (para cima e para baixo) | caixa | asa_c | diedro;  n: painéis no vão"""
    s = span / 2
    H = h * span
    ds = span / n
    if kind == "diedro":
        dz = s * math.tan(math.radians(dihedral_deg))
        return [_seg((-s, dz), (0, 0), ds), _seg((0, 0), (s, dz), ds)]
    segs = [_seg((-s, 0), (s, 0), ds)]
    if kind in ("winglet", "asa_c"):
        segs.append(_seg((s, 0), (s, H), ds))
        segs.append(_seg((-s, H), (-s, 0), ds))
        if kind == "asa_c":
            segs.append(_seg((s, H), (s - cap * span, H), ds))
            segs.append(_seg((-s + cap * span, H), (-s, H), ds))
    elif kind == "placa":
        for y in (s, -s):
            segs.append(_seg((y, 0), (y, H / 2), ds))
            segs.append(_seg((y, 0), (y, -H / 2), ds))
    elif kind == "caixa":
        segs.append(_seg((s, 0), (s, H), ds))
        segs.append(_seg((s, H), (-s, H), ds))
        segs.append(_seg((-s, H), (-s, 0), ds))
    return segs


def optimal_loading(segs, span: float = 1.0) -> dict:
    """Γ ótimo (ρ = V = 1, L = 1) e o e do sistema"""
    A, B = [], []
    for pts in segs:
        A.append(pts[:-1])
        B.append(pts[1:])
    a = np.vstack(A)
    b = np.vstack(B)
    d = b - a
    ln = np.hypot(d[:, 0], d[:, 1])
    keep = ln > 1e-12
    a, b, d, ln = a[keep], b[keep], d[keep], ln[keep]
    t = d / ln[:, None]
    nrm = np.column_stack([-t[:, 1], t[:, 0]])
    mid = 0.5 * (a + b)

    def infl(p0):     # velocidade em mid por vórtice unitário em p0 (cada coluna)
        r = mid[:, None, :] - p0[None, :, :]
        r2 = np.maximum((r ** 2).sum(-1), 1e-14)
        return np.stack([-r[..., 1], r[..., 0]], -1) / (TWO_PI * r2[..., None])
    # painel j: vórtice +Γ_j no início, −Γ_j no fim
    vel = infl(a) - infl(b)
    Wn = np.einsum("ijk,ik->ij", vel, nrm)
    M = 0.5 * ln[:, None] * Wn
    M = 0.5 * (M + M.T)
    lift = d[:, 0]
    g = np.linalg.lstsq(M, lift, rcond=None)[0]
    g /= lift @ g                                    # L = 1
    D = float(g @ M @ g)
    e = 1.0 / (math.pi * 0.5 * span ** 2 * D)
    # momento fletor na raiz (semiasa direita, L = 1): F = Γ (−Δz, Δy) no ponto médio
    right = mid[:, 0] > 1e-12
    Mroot = float(np.sum(g[right] * (d[right, 0] * mid[right, 0] + d[right, 1] * mid[right, 1])))
    return dict(e=e, D=D, gamma=g, Mroot=Mroot, mid=mid, length=ln, s=np.concatenate([[0], np.cumsum(ln)])[:-1] + ln / 2)


def span_efficiency(kind: str, h: float = 0.2, n: int = 80, **kw) -> float:
    """e com extrapolação de Richardson (o erro da discretização cai com 1/n)"""
    e1 = optimal_loading(trace(kind, h, n, **kw))["e"]
    e2 = optimal_loading(trace(kind, h, 2 * n, **kw))["e"]
    return 2 * e2 - e1


def raymer_endplate(h_over_b) -> np.ndarray:
    """AR_ef / AR de uma placa de ponta (Raymer)"""
    return 1 + 1.9 * np.asarray(h_over_b, float)


def raymer_oswald(AR: float) -> float:
    """e de asa reta (Raymer, eq. 12.49): 1,78 (1 − 0,045 AR^0,68) − 0,64"""
    return 1.78 * (1 - 0.045 * AR ** 0.68) - 0.64


def device_study(span: float, S: float, CL: float, c_tip: float, e_planform: float = 1.0,
                 Cf: float = 0.006, hb=np.linspace(0.0, 0.3, 16), cap: float = 0.25, n: int = 60) -> dict:
    """para cada h/b: e ideal de cada dispositivo e o arrasto total relativo (força/q) com o
    atrito do dispositivo, contra uma extensão de ponta com a mesma área molhada.
    D/q = (C_L S)² / (π b² e e_planform) + C_f S_molhada.   e_planform: perda da asa real em
    relação ao carregamento ótimo (ex.: e_Oswald da asa plana)."""
    L_q = CL * S
    base_i = L_q ** 2 / (math.pi * span ** 2 * e_planform)
    out = {"h_b": np.asarray(hb, float)}
    for kind in ("winglet", "placa", "caixa", "asa_c"):
        es, net = [], []
        for x in hb:
            if x <= 1e-9:
                e = 1.0
                wet = 0.0
            else:
                e = span_efficiency(kind, x, n, cap=cap)
                hh = x * span
                wet = {"winglet": 2 * 2 * hh * c_tip, "placa": 2 * 2 * hh * c_tip,
                       "caixa": 2 * (2 * hh * c_tip + span * c_tip), "asa_c": 2 * 2 * (hh + cap * span) * c_tip}[kind]
            es.append(e)
            net.append((L_q ** 2 / (math.pi * span ** 2 * e * e_planform) + Cf * wet - base_i) / base_i)
        out[f"e_{kind}"] = np.array(es)
        out[f"dD_{kind}"] = 100 * np.array(net)
    # extensão de ponta: mesma área molhada de um par de winglets (2 · 2 h c_tip) vira Δb = 2 h
    ext = []
    for x in hb:
        b2 = span + 2 * x * span
        wet = 2 * 2 * x * span * c_tip
        ext.append((L_q ** 2 / (math.pi * b2 ** 2 * e_planform) + Cf * wet - base_i) / base_i)
    out["dD_extensao"] = 100 * np.array(ext)
    # extensão com o mesmo momento fletor na raiz do winglet (comparação de Whitcomb/Jones):
    # elíptica plana tem M_raiz = (L/2)(4 s / 3π)
    ext_m = []
    Mr0 = optimal_loading(trace("plana", 0.0, n, span=span), span)["Mroot"]
    for x in hb:
        Mr = optimal_loading(trace("winglet" if x > 1e-9 else "plana", x, n, span=span), span)["Mroot"]
        b2 = span * Mr / Mr0          # M_raiz da elíptica cresce linearmente com o vão
        wet = 2 * 2 * max(b2 - span, 0) / 2 * c_tip
        ext_m.append((L_q ** 2 / (math.pi * b2 ** 2 * e_planform) + Cf * wet - base_i) / base_i)
    out["dD_extensao_mesmo_M"] = 100 * np.array(ext_m)
    out["e_raymer_placa"] = raymer_endplate(hb)
    return out


# ------------------------------------------------------------------ a partir do modelo universal
def model_trace(model, with_devices: bool = True, n: int = 80, height_scale: float = 1.0) -> list[np.ndarray]:
    """traço da asa principal (com diedro) e dos dispositivos dela no plano de Trefftz (y, z para cima),
    a partir das estações do modelo universal: dispositivos presos à asa e derivas soltas na ponta"""
    w = model.wing
    if w is None:
        return []
    yz = lambda p: np.array([p[1], -p[2]])
    root, tip = yz(w.stations[0].le), yz(w.tip.le)
    b = 2 * abs(tip[0])
    ds = b / n
    segs = [_seg(root * [-1, 1], tip * [-1, 1], ds), _seg(root, tip, ds)]
    tips = [tip, tip * [-1, 1]]

    def snap(p):
        """base a menos de 2 % do vão da ponta = presa na ponta (dois vórtices quase coincidentes estragam
        a solução)"""
        for t in tips:
            if np.hypot(*(p - t)) < 0.02 * b:
                return t.copy()
        return p
    if with_devices:
        for s in model.devices_of(w.name) + model.tip_fins():
            a0, a1 = yz(s.stations[0].le), yz(s.tip.le)
            for sy in ((1, -1) if s.mirror else (1,)):
                a = snap(a0 * [sy, 1])
                segs.append(_seg(a, a + (a1 - a0) * [sy, 1] * height_scale, ds))
    return segs


def model_efficiency(model, with_devices: bool = True, n: int = 80, height_scale: float = 1.0) -> float:
    """e ótimo da asa (+ dispositivos), com Richardson; vão de referência = envergadura projetada da asa"""
    w = model.wing
    if w is None:
        return float("nan")
    b = 2 * abs(w.tip.le[1])
    e1 = optimal_loading(model_trace(model, with_devices, n, height_scale), b)["e"]
    e2 = optimal_loading(model_trace(model, with_devices, 2 * n, height_scale), b)["e"]
    return 2 * e2 - e1


def devices_wetted_area(model, height_scale: float = 1.0) -> float:
    """área molhada (2 × planta) dos dispositivos da asa e das derivas de ponta, dos dois lados"""
    w = model.wing
    if w is None:
        return 0.0
    return 2 * height_scale * sum(s.total_area for s in model.devices_of(w.name) + model.tip_fins())

"""Cena 3D de uma análise de carga para fora da GUI (página web, outro visualizador): a partir da entrada padrão
(`aerosim.interfaces.loads.LoadResult`) e do avião (o desenho da GUI), monta um dicionário só com números e listas —
as superfícies do modelo com o valor de cada campo em cada vértice, o resto do avião, as setas (linhas e pontas), os
tubos das hélices e o vento relativo. Nenhuma conta aerodinâmica é feita aqui.

    sc = scene(result, aircraft)            # dict pronto para json.dumps
    html = page([("Convencional", sc)])     # página com plotly.js (o mesmo formato do artifact)

Eixos da cena: os da tela, z para cima: (x, −y, −z) do corpo, como em `gui/widgets/view3d.to_gl`.
"""
from __future__ import annotations

import json

import numpy as np

from aerosim.interfaces.loads import CAMPOS, LoadResult, label

SURFACE_KINDS = {"wing", "htail", "vtail", "control", "device"}
B2S = np.array([1.0, -1.0, -1.0])
PART_COLORS = {"fuselage": "#b9bcc4", "boom": "#6c6e74", "motor": "#c64040", "propdisk": "#e08080", "wheel": "#222222",
               "strut": "#555555", "payload": "#8a5a2b", "tank": "#9fd3ee", "liquid": "#2f74e8", "ballast": "#404046"}


def arrow_meshes(origins: np.ndarray, vecs: np.ndarray, head: float):
    """linhas (pares de pontos) e a malha dos cones das pontas (tamanho `head`) de um conjunto de setas"""
    origins, vecs = np.asarray(origins, float).reshape(-1, 3), np.asarray(vecs, float).reshape(-1, 3)
    seg = np.empty((2 * len(vecs), 3))
    seg[0::2], seg[1::2] = origins, origins + vecs
    verts, faces = [], []
    n = 8
    ang = np.linspace(0, 2 * np.pi, n, endpoint=False)
    for o, d in zip(origins, vecs):
        L = np.linalg.norm(d)
        if L < 1e-12:
            continue
        a = d / L
        h = min(head, 0.45 * L)
        u = np.cross(a, [0.0, 0.0, 1.0])
        if np.linalg.norm(u) < 1e-6:
            u = np.cross(a, [0.0, 1.0, 0.0])
        u /= np.linalg.norm(u)
        w = np.cross(a, u)
        base = o + d - h * a
        k = len(verts)
        verts.append(o + d)
        verts += list(base + 0.38 * h * (np.outer(np.cos(ang), u) + np.outer(np.sin(ang), w)))
        faces += [[k, k + 1 + i, k + 1 + (i + 1) % n] for i in range(n)]
    return seg, (np.array(verts, float).reshape(-1, 3), np.array(faces, int).reshape(-1, 3))


def tube_mesh(C: np.ndarray, R: np.ndarray, n: int = 24):
    """superfície do tubo (centros ao longo do eixo e raio em cada um)"""
    C, R = np.asarray(C, float), np.asarray(R, float)
    ax = C[-1] - C[0]
    ax /= np.linalg.norm(ax) or 1.0
    u = np.cross(ax, [0.0, 0.0, 1.0])
    if np.linalg.norm(u) < 1e-6:
        u = np.cross(ax, [0.0, 1.0, 0.0])
    u /= np.linalg.norm(u)
    w = np.cross(ax, u)
    ang = np.linspace(0, 2 * np.pi, n, endpoint=False)
    ring = np.outer(np.cos(ang), u) + np.outer(np.sin(ang), w)
    V = np.vstack([C[i] + R[i] * ring for i in range(len(C))])
    F = []
    for i in range(len(C) - 1):
        for j in range(n):
            a, b = i * n + j, i * n + (j + 1) % n
            F += [[a, b, b + n], [a, b + n, a + n]]
    return V, np.array(F, int)


def _frames(f):
    V = np.asarray(f.vertices, float)
    F = np.asarray(f.faces, int)
    c = V[F].mean(axis=1)
    if F.shape[1] != 4:
        return dict(c=c)
    span = V[F[:, 1]] - V[F[:, 0]]
    hw = 0.5 * np.linalg.norm(span, axis=1)
    u = span / np.maximum(2 * hw, 1e-12)[:, None]
    ch = V[F[:, 0]] - V[F[:, 3]]
    hc = 0.5 * np.linalg.norm(ch, axis=1)
    w = ch / np.maximum(2 * hc, 1e-12)[:, None]
    return dict(c=c, u=u, hw=hw, w=w, hc=hc, n=np.cross(w, u))


def nearest_face(fr: dict, P: np.ndarray) -> np.ndarray:
    """a face do método mais perto de cada ponto, medindo fora do retângulo da face (envergadura e corda) e na normal"""
    d = np.asarray(P, float)[:, None, :] - fr["c"][None, :, :]
    if "u" not in fr:
        return np.argmin(np.sum(d * d, axis=2), axis=1)
    du = np.maximum(np.abs(np.einsum("pfk,fk->pf", d, fr["u"])) - fr["hw"], 0)
    dw = np.maximum(np.abs(np.einsum("pfk,fk->pf", d, fr["w"])) - fr["hc"], 0)
    dn = np.einsum("pfk,fk->pf", d, fr["n"])
    return np.argmin(du * du + dw * dw + 0.25 * dn * dn, axis=1)


def _r(a, nd=4):
    return np.round(np.asarray(a, float), nd).tolist()


def _xyz(P):
    P = np.asarray(P, float).reshape(-1, 3) * B2S
    return dict(x=_r(P[:, 0]), y=_r(P[:, 1]), z=_r(P[:, 2]))


def _mesh(V, F):
    F = np.asarray(F, int).reshape(-1, 3)
    return dict(**_xyz(V), i=F[:, 0].tolist(), j=F[:, 1].tolist(), k=F[:, 2].tolist())


def scene(res: LoadResult, aircraft=None) -> dict:
    """a cena 3D (só números e listas, para json)"""
    from aerosim.model.geometry import aircraft_meshes
    f = res.field
    size = float(np.ptp(f.vertices, axis=0).max()) if len(f.vertices) else 1.0
    fr = _frames(f)
    surf_V, surf_F, vidx = [], [], []
    parts = []
    meshes = aircraft_meshes(aircraft) if aircraft is not None else {}
    for parts_ in meshes.values():
        for (V, F), kind in parts_:
            V = np.asarray(V, float)
            if kind in SURFACE_KINDS:
                base = sum(len(x) for x in surf_V)
                surf_V.append(V)
                surf_F.append(np.asarray(F, int) + base)
                vidx.append(nearest_face(fr, V))
            elif kind != "liquid":
                parts.append(dict(**_mesh(V, F), color=PART_COLORS.get(kind, "#999999"), kind=kind))
    if surf_V:                                       # o modelo da GUI
        V = np.vstack(surf_V)
        F = np.vstack(surf_F)
        k = np.concatenate(vidx)
    else:                                            # sem avião: a malha do método
        V = np.asarray(f.vertices, float)
        tri, src = f.triangles()
        F = tri
        k = np.zeros(len(V), int)
        for t, s in zip(tri, src):
            k[t] = s
    groups = np.asarray(f.face_surface)[k] if f.face_surface is not None else np.array(["?"] * len(k))
    fields = {}
    for name, vals in f.fields.items():
        v = np.asarray(vals, float)[k]
        lab, unit, signed = CAMPOS.get(name, (name, "", True))
        fields[name] = dict(values=_r(v, 5), label=label(name), unit=unit, signed=bool(signed))
    vectors = {}
    for layer in f.vectors:
        mag = np.linalg.norm(layer.vectors, axis=1)
        if not len(mag) or mag.max() <= 1e-12:
            continue
        sc = 0.18 * size / mag.max()
        seg, (cv, cf) = arrow_meshes(layer.origins, sc * np.asarray(layer.vectors, float), 0.025 * size)
        lines = np.full((3 * len(mag), 3), np.nan)
        lines[0::3], lines[1::3] = seg[0::2], seg[1::2]
        L = lines * B2S
        col = "#%02x%02x%02x" % tuple(int(255 * c) for c in layer.color[:3])
        vectors[layer.name] = dict(line=dict(x=[None if np.isnan(a) else round(a, 4) for a in L[:, 0]],
                                             y=[None if np.isnan(a) else round(a, 4) for a in L[:, 1]],
                                             z=[None if np.isnan(a) else round(a, 4) for a in L[:, 2]]),
                                   head=_mesh(cv, cf), color=col, max=float(mag.max()), unit=layer.unit)
    tubes = [_mesh(*tube_mesh(t["centers"], t["radius"])) for t in f.tubes if len(t["centers"]) > 1]
    lo, hi = f.vertices.min(axis=0), f.vertices.max(axis=0)
    wind = None
    if res.meta.get("vento") is not None:
        wd = np.asarray(res.meta["vento"], float)
        tip = np.array([hi[0] + 0.12 * size, 0.0, lo[2] - 0.12 * size])
        seg, (cv, cf) = arrow_meshes((tip - 0.3 * size * wd)[None, :], (0.3 * size * wd)[None, :], 0.05 * size)
        wind = dict(line=_xyz(seg), head=_mesh(cv, cf), start=_xyz((tip - 0.3 * size * wd)[None, :]),
                    text=f"vento relativo ({res.meta.get('V', 0):g} m/s, α = {res.meta.get('alpha', 0):.1f}°)")
    m = res.meta
    info = [m.get("caso", "")]
    if m.get("modificadores"):
        info.append("modificadores: " + "; ".join(m["modificadores"]))
    info.append(f"fonte: {m.get('fonte', '?')}")
    info += ["aviso: " + a for a in m.get("avisos", [])]
    return dict(surfaces=dict(**_mesh(V, F), group=groups.tolist(), fields=fields), parts=parts, vectors=vectors,
                tubes=tubes, wind=wind, info=info, size=size,
                totals={d.surface: round(d.integral("L"), 2) for d in res.distributions if "L" in d.fields})


def scenes_json(items: list[tuple[str, dict]]) -> str:
    return json.dumps({name: sc for name, sc in items}, ensure_ascii=False, separators=(",", ":"))


PAGE = __file__.replace("load_export.py", "load_page.html")


def page(items: list[tuple[str, dict]], standalone: bool = True) -> str:
    """página com a vista 3D interativa (plotly.js) das cenas `items` [(nome, scene(...))]. standalone=False: só o
    conteúdo (para publicar como artifact, que já põe o esqueleto da página)"""
    data = scenes_json(items).replace("</", "<\\/")
    body = open(PAGE, encoding="utf-8").read().replace("__CENAS__", data)
    if not standalone:
        return body
    return ("<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head><body>" + body + "</body></html>")

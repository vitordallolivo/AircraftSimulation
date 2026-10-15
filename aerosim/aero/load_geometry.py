"""Geometria das setas da vista de carga (sem Qt, sem conta aerodinâmica): setas com ponta (linhas + cones).

Eixos do corpo do simulador (x à frente, y à direita, z para baixo).
"""
from __future__ import annotations

import numpy as np


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

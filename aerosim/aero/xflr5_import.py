"""Polar 3D exportada pelo XFLR5 (análise de avião: LLT, VLM1/VLM2 ou painéis), lida como mais um método da
comparação. Não roda nada: lê o arquivo (texto ou CSV) que o XFLR5 exporta em Polars → Export.

Usa as colunas alpha, CL, CDi, CD (ou CDi + CDv) e Cm. O C_m é em torno do CG que estava no XFLR5 (não o
da aba); C_l e C_n ficam de fora (o eixo do XFLR5 é outro). As derivadas saem do ajuste em α:
C_Lα e C_mα perto do α das derivadas; as outras ficam NaN.

    so = Xflr5PolarFile("T1-15_0 m_s-VLM2.txt")
    pol = so.solve(model, case)            # pol.source = "arquivo T1-15_0 m_s-VLM2.txt"
"""
from __future__ import annotations

import math
import os
import re

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar, IAeroSolver


def read_plane_polar(path: str) -> dict:
    """{'alpha', 'CL', 'CD', 'CDi', 'Cm', 'name', 'method', 'V'} do arquivo do XFLR5"""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    head, rows, name, V = None, [], "", float("nan")
    for ln in lines:
        m = re.search(r"Polar name\s*:\s*(.+)", ln, re.I)
        if m:
            name = m.group(1).strip()
        m = re.search(r"(?:Freestream speed|QInf)\s*:\s*([-+0-9.eE]+)", ln, re.I)
        if m:
            V = float(m.group(1))
        parts = [p for p in re.split(r"[,\s;]+", ln.strip()) if p]
        low = [p.lower() for p in parts]
        if head is None:
            if "alpha" in low and "cl" in low:
                head = low
            continue
        try:
            vals = [float(p) for p in parts]
        except ValueError:
            continue
        if len(vals) >= 3:
            rows.append(vals[:len(head)] + [np.nan] * (len(head) - len(vals[:len(head)])))
    if head is None or not rows:
        raise ValueError(f"não achei a tabela 'alpha CL CD ...' em {os.path.basename(path)}")
    a = np.array(rows, float)
    col = lambda k: a[:, head.index(k)] if k in head else np.full(len(a), np.nan)
    o = np.argsort(col("alpha"))
    CD = col("cd")
    if not np.isfinite(CD).any():
        CD = col("cdi") + col("cdv")
    low = name.lower()
    method = "painel" if "panel" in low else ("llt" if "llt" in low else "vlm")
    return dict(alpha=col("alpha")[o], CL=col("cl")[o], CD=CD[o], CDi=col("cdi")[o], Cm=col("cm")[o], name=name,
                method=method, V=V)


class Xflr5PolarFile(IAeroSolver):
    name = "xflr5"
    title = "XFLR5 (polar importada)"
    description = "polar de avião exportada pelo XFLR5 (LLT, VLM ou painéis); não roda nada"
    level = "detalhado"
    supports_beta = supports_rates = False

    def __init__(self, path: str = ""):
        self.path = path

    def available(self):
        if not self.path:
            return "escolha o arquivo da polar exportada pelo XFLR5"
        return None if os.path.exists(self.path) else f"arquivo não encontrado: {self.path}"

    def evaluate(self, model, case, points):
        raise NotImplementedError("polar importada: só a varredura em α que está no arquivo")

    def solve(self, model, case: AeroCase) -> AeroPolar:
        p = read_plane_polar(self.path)
        self.fidelity = p["method"]
        derivs = {}
        a = p["alpha"]
        near = np.abs(a - case.alpha_d) <= 3.0
        for out, k in (("CLa", "CL"), ("Cma", "Cm")):
            ok = near & np.isfinite(p[k])
            if ok.sum() >= 2:
                derivs[out] = float(np.polyfit(np.radians(a[ok]), p[k][ok], 1)[0])
        V = p["V"]
        note = f"XFLR5 '{p['name']}'" + (f", V = {V:g} m/s" if math.isfinite(V) else "") + "; C_m no CG do XFLR5"
        return AeroPolar(self.name, a, p["CL"], p["CD"], p["Cm"], p["CDi"], derivs, notes=note,
                         source=f"arquivo {os.path.basename(self.path)}", fidelity=p["method"])

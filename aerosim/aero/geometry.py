"""Utilidades dos tradutores: eixos dos solvers externos, viscosidade/Reynolds, tabela de volumes
de cauda do Raymer. (Geometria — CMA, áreas, C_D0, volumes — vem só do modelo universal.)

Eixos: o simulador usa x à frente, y à direita, z para baixo. AeroSandbox e lltdrek usam
x para trás, y à direita, z para cima (rotação de 180° em torno de y): x' = −x, z' = −z;
C_m não muda de sinal, C_l e C_n mudam (as derivadas p, r e β-β não mudam).
"""
from __future__ import annotations

import math

import numpy as np


_trapz = getattr(np, "trapezoid", None) or np.trapz   # numpy < 2
MU_AIR = 1.81e-5      # viscosidade dinâmica do ar (Pa s), 15 °C


# Raymer, Aircraft Design: A Conceptual Approach, tabela 6.4 (coeficientes de volume típicos)
RAYMER_TAIL_VOLUME = {
    "planador": (0.50, 0.02),
    "experimental (homebuilt)": (0.50, 0.04),
    "aviação geral monomotor": (0.70, 0.04),
    "aviação geral bimotor": (0.80, 0.07),
    "agrícola": (0.50, 0.04),
    "turboélice bimotor": (0.90, 0.08),
    "anfíbio": (0.70, 0.06),
    "jato de treinamento": (0.70, 0.06),
    "caça": (0.40, 0.07),
    "transporte a jato": (1.00, 0.09),
}


def nu_air(rho: float) -> float:
    return MU_AIR / rho


def reynolds(V: float, c: float, rho: float) -> float:
    return V * c / nu_air(rho)


def to_xz_up(p) -> list[float]:
    """corpo (x frente, z baixo) -> eixos x trás, z cima"""
    return [-float(p[0]), float(p[1]), -float(p[2])]

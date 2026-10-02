"""Perfis: leitura de .dat (Selig ou Lednicer), gerador NACA 4 dígitos e teoria de
perfil fino para tirar α_L0 e C_m,ac da linha média (aproximação geométrica).
"""
from __future__ import annotations

import math
import os
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Airfoil:
    name: str = "NACA 2412"
    path: str = ""                       # arquivo .dat (vazio: usa `name` se for NACA 4 dígitos)
    cl_alpha: float = 5.9                # inclinação 2D (1/rad)
    alpha0: float | None = None          # ângulo de sustentação nula (graus); None: da linha média
    cl_max: float = 1.4
    cd0: float = 0.012
    cm_ac: float | None = None           # None: da linha média
    coords: list[list[float]] = field(default_factory=list)   # contorno (x, y), cordas unitárias

    def outline(self) -> np.ndarray:
        """contorno fechado (N, 2): bordo de fuga -> extradorso -> bordo de ataque -> intradorso"""
        if not self.coords:
            if self.path and os.path.exists(self.path):
                self.coords = read_dat(self.path)[1].tolist()
            else:
                self.coords = naca4(self.name).tolist()
        return np.asarray(self.coords, dtype=float)

    def zero_lift_angle(self) -> float:
        """graus"""
        if self.alpha0 is not None:
            return self.alpha0
        return thin_airfoil(self.outline())[0]

    def moment_ac(self) -> float:
        if self.cm_ac is not None:
            return self.cm_ac
        return thin_airfoil(self.outline())[1]


def naca4(code: str, n: int = 61) -> np.ndarray:
    """contorno NACA de 4 dígitos ('2412' ou 'NACA 2412'), espaçamento cosseno"""
    digits = "".join(ch for ch in code if ch.isdigit())
    if len(digits) != 4:
        digits = "0012"
    m, p, t = int(digits[0]) / 100, int(digits[1]) / 10, int(digits[2:]) / 100
    x = 0.5 * (1 - np.cos(np.linspace(0, math.pi, n)))
    yt = 5 * t * (0.2969 * np.sqrt(x) - 0.1260 * x - 0.3516 * x**2 + 0.2843 * x**3 - 0.1036 * x**4)
    if m > 0 and p > 0:
        yc = np.where(x < p, m / p**2 * (2 * p * x - x**2), m / (1 - p) ** 2 * ((1 - 2 * p) + 2 * p * x - x**2))
        dyc = np.where(x < p, 2 * m / p**2 * (p - x), 2 * m / (1 - p) ** 2 * (p - x))
    else:
        yc = np.zeros_like(x)
        dyc = np.zeros_like(x)
    th = np.arctan(dyc)
    xu, yu = x - yt * np.sin(th), yc + yt * np.cos(th)
    xl, yl = x + yt * np.sin(th), yc - yt * np.cos(th)
    upper = np.column_stack([xu, yu])[::-1]
    lower = np.column_stack([xl, yl])[1:]
    return np.vstack([upper, lower])


def read_dat(path: str) -> tuple[str, np.ndarray]:
    """Selig (um contorno contínuo) ou Lednicer (cabeçalho com contagens, duas metades)"""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    name = lines[0]
    pts = []
    for ln in lines[1:]:
        try:
            a, b = (float(v) for v in ln.replace(",", " ").split()[:2])
        except ValueError:
            continue
        pts.append((a, b))
    arr = np.array(pts, dtype=float)
    if len(arr) and arr[0, 0] > 1.5:              # Lednicer: primeira linha = (n_sup, n_inf)
        nu, nl = int(arr[0, 0]), int(arr[0, 1])
        up, lo = arr[1:1 + nu], arr[1 + nu:1 + nu + nl]
        arr = np.vstack([up[::-1], lo[1:]])
    return name, arr


def write_dat(path: str, name: str, coords: np.ndarray) -> None:
    with open(path, "w") as f:
        f.write(name + "\n")
        for x, y in coords:
            f.write(f" {x:.6f}  {y:.6f}\n")


def camber_line(coords: np.ndarray, n: int = 200) -> tuple[np.ndarray, np.ndarray]:
    """linha média: média entre extradorso e intradorso no mesmo x"""
    i_le = int(np.argmin(coords[:, 0]))
    up, lo = coords[: i_le + 1][::-1], coords[i_le:]
    up = up[np.argsort(up[:, 0])]
    lo = lo[np.argsort(lo[:, 0])]
    x = 0.5 * (1 - np.cos(np.linspace(0, math.pi, n)))
    x0, x1 = coords[:, 0].min(), coords[:, 0].max()
    xs = x0 + (x1 - x0) * x
    zu = np.interp(xs, up[:, 0], up[:, 1])
    zl = np.interp(xs, lo[:, 0], lo[:, 1])
    return x, 0.5 * (zu + zl) / (x1 - x0)


def thin_airfoil(coords: np.ndarray) -> tuple[float, float]:
    """(α_L0 em graus, C_m,ac) pela teoria de perfil fino"""
    x, zc = camber_line(coords)
    th = np.arccos(1 - 2 * x)
    dz = np.gradient(zc, x)
    dz[0], dz[-1] = dz[1], dz[-2]
    alpha0 = -1 / math.pi * np.trapezoid(dz * (np.cos(th) - 1), th)
    A1 = 2 / math.pi * np.trapezoid(dz * np.cos(th), th)
    A2 = 2 / math.pi * np.trapezoid(dz * np.cos(2 * th), th)
    return math.degrees(alpha0), -math.pi / 4 * (A1 - A2)


def flap_effectiveness(chord_frac: float) -> float:
    """τ = dα/dδ de um flape simples (perfil fino) com fator empírico 0,85"""
    cf = min(max(chord_frac, 0.01), 0.99)
    th = math.acos(2 * cf - 1)
    return 0.85 * (1 - (th - math.sin(th)) / math.pi)


def helmbold(a0: float, AR: float) -> float:
    """C_Lα de uma asa finita (por rad) a partir do a0 do perfil"""
    k = a0 / (math.pi * AR)
    return a0 / (math.sqrt(1.0 + k * k) + k)

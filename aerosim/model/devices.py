"""Geometria dos dispositivos de asa (winglet, winglet para baixo, placa de ponta, cerca).

Cada dispositivo vira "pernas" (uma por lado e, na placa, uma para cima e outra para baixo):
ponto de fixação no bordo de ataque local da asa, direção ao longo da altura (no plano y-z) e
estações (bordo de ataque, corda). `aerosim.model.universal` transforma cada perna numa superfície
do modelo universal; painéis, malha 3D, AeroSandbox e Trefftz saem de lá.

Direção (lado direito; z para baixo): para cima u = (0, sen c, −cos c), com c = cant a partir da
vertical (c = 90° continua no plano da asa); para baixo u = (0, sen c, +cos c). Lado esquerdo: y espelhado.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .aircraft import LiftingSurface, WingDevice


@dataclass
class Leg:
    side: int                  # +1 direito, −1 esquerdo, 0 superfície não simétrica
    up: bool
    root: np.ndarray           # bordo de ataque na raiz (corpo)
    u: np.ndarray              # direção da altura (unitária)
    height: float
    c_root: float
    c_tip: float
    sweep: float               # rad

    def station(self, h: float) -> tuple[np.ndarray, float]:
        """(bordo de ataque, corda) a uma distância h da raiz"""
        f = h / self.height if self.height > 0 else 0.0
        le = self.root + self.u * h - np.array([h * math.tan(self.sweep), 0.0, 0.0])
        return le, self.c_root + f * (self.c_tip - self.c_root)

    @property
    def dihedral(self) -> float:
        """ângulo equivalente de diedro (rad) no sentido do núcleo: + sobe para fora"""
        return math.atan2(-self.u[2], abs(self.u[1]))


def attach_point(s: LiftingSurface, eta: float) -> tuple[np.ndarray, float]:
    """bordo de ataque da asa (lado direito) na fração eta da semienvergadura e a corda local"""
    y = min(max(eta, 0.0), 1.0) * s.semispan
    dih = math.radians(s.dihedral)
    le = np.array([s.x - s.xoff_at(y), s.y + y * math.cos(dih), s.z - y * math.sin(dih)])
    return le, s.chord_at(y)


def legs(s: LiftingSurface, d: WingDevice) -> list[Leg]:
    if not d.enabled or d.height <= 0 or s.vertical:
        return []
    le, c_loc = attach_point(s, d.eta)
    le = le - np.array([d.dx, 0.0, 0.0])
    c0 = d.root_chord if d.root_chord > 0 else c_loc
    ct = c0 * d.taper
    c = math.radians(d.cant)
    parts = {"winglet": [(True, d.height)], "winglet_baixo": [(False, d.height)], "cerca": [(True, d.height)],
             "placa": [(True, d.height / 2), (False, d.height / 2)]}.get(d.kind, [(True, d.height)])
    sides = (1, -1) if s.symmetric else (0,)
    out = []
    for side in sides:
        sy = -1.0 if side < 0 else 1.0
        root = le.copy()
        root[1] = sy * root[1] if side else root[1]
        for up, h in parts:
            u = np.array([0.0, sy * math.sin(c), -math.cos(c) if up else math.cos(c)])
            if d.kind == "cerca":         # cerca: sempre vertical, sobre o extradorso
                u = np.array([0.0, 0.0, -1.0])
            out.append(Leg(side, up, root, u, h, c0, ct if d.kind != "cerca" else c0,
                           math.radians(d.sweep if d.kind != "cerca" else 0.0)))
    return out


def device_area(s: LiftingSurface, d: WingDevice) -> float:
    """área de um lado (todas as pernas de um lado)"""
    return sum(0.5 * (l.c_root + l.c_tip) * l.height for l in legs(s, d) if l.side >= 0)

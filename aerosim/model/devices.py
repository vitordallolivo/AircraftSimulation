"""Geometria dos dispositivos de asa (winglet, winglet para baixo, placa de ponta, cerca).

Cada dispositivo vira "pernas" (uma por lado e, na placa, uma para cima e outra para baixo):
ponto de fixação no bordo de ataque local da asa, direção ao longo da altura (no plano y-z) e
estações (bordo de ataque, corda). Daí saem os painéis do núcleo, a malha 3D, as superfícies do
AeroSandbox e o traço no plano de Trefftz — uma única descrição para todos.

Direção (lado direito; z para baixo): para cima u = (0, sen c, −cos c), com c = cant a partir da
vertical (c = 90° continua no plano da asa); para baixo u = (0, sen c, +cos c). Lado esquerdo: y espelhado.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .aircraft import LiftingSurface, WingDevice
from .airfoil import helmbold


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


def device_panels(s: LiftingSurface, d: WingDevice, n: int = 3) -> list[dict]:
    """painéis do núcleo (SI/rad): faixas ao longo da altura, grupo EV (não entram no C_Lmax da asa)"""
    out = []
    A = device_area(s, d)
    for l in legs(s, d):
        AR = max(l.height ** 2 / max(0.5 * (l.c_root + l.c_tip) * l.height, 1e-9), 0.3)
        CLa = helmbold(d.cl_alpha, AR)
        dih = l.dihedral
        for k in range(n):
            h0, h1 = l.height * k / n, l.height * (k + 1) / n
            hm = 0.5 * (h0 + h1)
            le, cm = l.station(hm)
            r = le - np.array([0.25 * cm, 0, 0])
            out.append(dict(r=list(map(float, r)), S=cm * (h1 - h0), c=cm, AR=AR, e=d.oswald, dihedral=dih,
                            incidence=math.radians(d.toe) * (1 if l.up else -1), CLa=CLa, CL0=0.0, CLmax=1.0,
                            CD0=d.cd0, Cmac=0.0, tau=0.0, mix=[0.0, 0.0, 0.0], eta=1.0, eps0=0.0, depsda=0.0,
                            group=2, vertical=0, side=l.side if l.side else 1, downwash=0))
    del A
    return out


def device_meshes(s: LiftingSurface, d: WingDevice, outline: np.ndarray) -> list:
    from .geometry import _loft
    out = []
    for l in legs(s, d):
        n = np.array([0.0, l.u[2], -l.u[1]])          # normal ao dispositivo no plano y-z
        rings = []
        for h in (0.0, l.height):
            le, c = l.station(h)
            rings.append(np.column_stack([le[0] - outline[:, 0] * c,
                                          le[1] + outline[:, 1] * c * n[1],
                                          le[2] + outline[:, 1] * c * n[2]]))
        out.append(_loft(rings))
    return out


def trace_points(s: LiftingSurface, d: WingDevice) -> list[np.ndarray]:
    """segmentos (y, z para cima) do dispositivo no plano de Trefftz"""
    segs = []
    for l in legs(s, d):
        a = l.root[[1, 2]] * np.array([1, -1])
        b = (l.root + l.u * l.height)[[1, 2]] * np.array([1, -1])
        segs.append((a, b))
    return segs

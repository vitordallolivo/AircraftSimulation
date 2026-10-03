"""Percurso como uma corrente de pernas (retas e curvas).

Cada perna começa onde a anterior terminou: mudar o raio de uma curva só altera as
pernas seguintes, e um checkpoint salvo antes dela continua válido. Altura e velocidade
de cada perna vão do valor da anterior ao pedido nela (curva cosseno no núcleo).

Curva com raio 0 = automático: o percurso usa `auto_radius(V)` (inclinação de AUTO_PHI) e a
aba Missão procura, do checkpoint da curva, o menor raio que a aeronave faz de verdade.
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field


AUTO_PHI = 45.0                       # inclinação usada para o raio automático (graus)


def auto_radius(V: float, phi: float = AUTO_PHI) -> float:
    """raio de uma curva nivelada a V com inclinação phi: R = V² / (g tan φ)"""
    return max(V * V / (9.80665 * math.tan(math.radians(phi))), 3.0)


@dataclass
class Leg:
    kind: str = "straight"            # straight | turn
    length: float = 100.0             # reta (m)
    radius: float = 50.0              # curva (m); 0 = automático
    angle: float = 180.0              # curva (graus)
    side: int = 1                     # +1 direita, -1 esquerda
    h: float | None = None            # altura no fim (None: mantém)
    V: float | None = None            # velocidade no fim (None: mantém)
    name: str = "perna"
    takeoff: bool = False
    landing: bool = False
    clearance: float = 0.0            # pouso: toca `clearance` m antes do fim


@dataclass
class MissionEvent:
    kind: str = "drop"                # drop (soltura da carga) | gust (rajada)
    leg: int = 0
    s: float = 0.0                    # distância dentro da perna (m)


@dataclass
class Mission:
    name: str = "missão"
    legs: list[Leg] = field(default_factory=list)
    events: list[MissionEvent] = field(default_factory=list)
    n0: float = 0.0
    e0: float = 0.0
    chi0: float = 0.0                 # graus
    h0: float = 0.0
    V0: float = 14.0

    def segments(self) -> list[dict]:
        """pernas -> segmentos do núcleo (SI, radianos)"""
        segs = []
        n, e, chi, h, V = self.n0, self.e0, math.radians(self.chi0), self.h0, self.V0
        for p in self.legs:
            h1 = h if p.h is None else p.h
            V1 = V if p.V is None else p.V
            sg = dict(h0=h, h1=h1, V0=V, V1=V1, takeoff=int(p.takeoff), landing=int(p.landing),
                      clearance=p.clearance)
            if p.kind == "straight":
                sg.update(arc=0, n0=n, e0=e, chi0=chi, L=p.length)
                n += p.length * math.cos(chi)
                e += p.length * math.sin(chi)
            else:
                lam, a = p.side, math.radians(p.angle)
                R = p.radius if p.radius > 0 else auto_radius(max(V, V1))
                cn, ce = n + R * math.cos(chi + lam * math.pi / 2), e + R * math.sin(chi + lam * math.pi / 2)
                sg.update(arc=1, n0=n, e0=e, cn=cn, ce=ce, R=R, lam=float(lam), L=R * a, chi0=chi)
                fi = math.atan2(e - ce, n - cn) + lam * a
                n, e = cn + R * math.cos(fi), ce + R * math.sin(fi)
                chi += lam * a
            segs.append(sg)
            h, V = h1, V1
        if self.legs and self.legs[0].takeoff:
            segs[0]["h0"] = segs[0]["h1"]
        return segs

    def core_events(self) -> list[dict]:
        return [dict(kind=0 if ev.kind == "drop" else 1, seg=ev.leg, s=ev.s) for ev in self.events]

    def names(self) -> list[str]:
        return [p.name for p in self.legs]

    def with_leg(self, i: int, **changes) -> "Mission":
        """cópia com a perna i alterada (ex.: radius=40, V=13); as seguintes se deslocam"""
        m = copy.deepcopy(self)
        for k, v in changes.items():
            setattr(m.legs[i], k, v)
        return m

    def with_events(self, events: list[MissionEvent]) -> "Mission":
        m = copy.deepcopy(self)
        m.events = list(events)
        return m

    def path_points(self, ds: float = 2.0) -> list[tuple[float, float, float]]:
        """pontos (n, e, h) do percurso nominal, para desenhar"""
        pts = []
        for sg in self.segments():
            k = max(2, int(sg["L"] / ds))
            for i in range(k + 1):
                f = i / k
                hh = sg["h0"] + (sg["h1"] - sg["h0"]) * 0.5 * (1 - math.cos(math.pi * f))
                if sg["arc"]:
                    fi0 = math.atan2(sg["e0"] - sg["ce"], sg["n0"] - sg["cn"])
                    fi = fi0 + sg["lam"] * f * sg["L"] / sg["R"]
                    pts.append((sg["cn"] + sg["R"] * math.cos(fi), sg["ce"] + sg["R"] * math.sin(fi), hh))
                else:
                    pts.append((sg["n0"] + f * sg["L"] * math.cos(sg["chi0"]),
                                sg["e0"] + f * sg["L"] * math.sin(sg["chi0"]), hh))
        return pts


def circuit(radius: float = 250.0 / math.pi, straight: float = 270.0, front: float = 100.0, hc: float = 15.0,
            hL: float = 3.0, Vc: float = 15.0, VL: float = 13.5, Vap: float = 13.0, s_drop: float | None = None,
            s_gust: float = 135.0, clearance: float = 50.0, radii: list[float] | None = None,
            landing_offset: float = 20.0) -> Mission:
    """o circuito do código original: decolagem, 4 curvas, passagem LAPES, pouso. O pouso fica
    `landing_offset` m a leste da pista de decolagem (a última curva é um pouco mais fechada), para
    ver o pouso separado da decolagem"""
    R = radii or [radius] * 3 + [radius - landing_offset / 2]
    back = straight - front
    legs = [
        Leg("straight", length=front, h=hc, V=Vc, name="decolagem + subida", takeoff=True),
        Leg("turn", radius=R[0], h=hc, V=Vc, name="manobra 1"),
        Leg("straight", length=straight, h=hc, V=Vc, name="cruzeiro 1"),
        Leg("turn", radius=R[1], h=hL, V=VL, name="manobra 2 (desce)"),
        Leg("straight", length=straight, h=hL, V=VL, name="passagem LAPES"),
        Leg("turn", radius=R[2], h=hc, V=Vc, name="manobra 3 (sobe)"),
        Leg("straight", length=straight, h=hc, V=Vc, name="cruzeiro 2"),
        Leg("turn", radius=R[3], h=hc, V=Vap, name="manobra 4"),
        Leg("straight", length=back, h=0.0, V=Vap, name="descida e pouso", landing=True, clearance=clearance),
    ]
    ev = [MissionEvent("gust", 2, s_gust), MissionEvent("drop", 4, back if s_drop is None else s_drop)]
    return Mission("circuito", legs, ev, h0=hc, V0=Vc)


def takeoff_runway(length: float = 300.0, h: float = 15.0, V: float = 15.0) -> Mission:
    return Mission("pista", [Leg("straight", length=length, h=h, V=V, name="decolagem", takeoff=True),
                             Leg("straight", length=2000.0, h=h, V=V, name="cruzeiro")], h0=h, V0=V)


def level_turn(V: float, R: float, angle: float = 240.0, h: float = 30.0, lead: float = 150.0, side: int = 1) -> Mission:
    """reta de estabilização + curva nivelada + reta de saída"""
    return Mission("curva", [Leg("straight", length=lead, h=h, V=V, name="estabiliza"),
                             Leg("turn", radius=R, angle=angle, side=side, h=h, V=V, name="curva"),
                             Leg("straight", length=300.0, h=h, V=V, name="saída")], h0=h, V0=V)

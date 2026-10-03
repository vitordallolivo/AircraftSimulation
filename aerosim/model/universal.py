"""Modelo universal da aeronave — construído UMA vez a partir da configuração (`Aircraft`) e
entregue a qualquer solver ou núcleo. Cada um tem um tradutor (`IModelTranslator`) que leva este
modelo ao seu formato nativo e traz o resultado de volta ao formato universal; ninguém mais
deriva geometria da configuração por conta própria.

    Aircraft (o que o usuário edita)  --build_model-->  AircraftModel  --tradutor-->  Zig / lltdrek / ASB / ...

Conteúdo, nos eixos do corpo do simulador (x à frente, y à direita, z para baixo, metros, graus):
  - superfícies (asa, EH, EV e os dispositivos já expandidos em superfícies) como estações:
    posição do bordo de ataque, corda, torção total (incidência + torção), coordenada ao longo da
    envergadura; com espelho (simétrica) ou não, vertical ou não; comandos por faixa; coeficientes
    do perfil já resolvidos (C_Lα 3D, C_L0, C_Lmax, C_D0, C_m,ac); downwash ε0, dε/dα
  - referências S, c, b e a CMA (bordo de ataque e posição)
  - massa seca, CG e inércia (componentes somados)
  - o resto (propulsão, trem, tanques, carga, ambiente, piloto, missão) segue como dado, sem
    reinterpretação
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .aircraft import Aircraft, LiftingSurface
from .airfoil import Airfoil, flap_effectiveness, helmbold, naca4

GROUP = {"wing": 0, "htail": 1, "vtail": 2, "device": 2}


@dataclass
class Control:
    kind: str                  # aileron | elevator | rudder | elevon | ruddervator | flap
    tau: float                 # efetividade dα/dδ
    deflection: float = 0.0    # flape: deflexão fixa (graus)
    chord_frac: float = 0.25   # fração da corda (só para desenhar)


@dataclass
class Station:
    s: float                   # coordenada ao longo da envergadura da superfície (m), a partir da raiz
    le: np.ndarray             # bordo de ataque (corpo, lado direito)
    chord: float
    twist: float               # incidência + torção (graus)


@dataclass
class SurfaceModel:
    name: str
    role: str                  # wing | htail | vtail | device
    index: int                 # posição em Aircraft.surfaces (para a GUI)
    stations: list[Station]
    mirror: bool               # existe o lado esquerdo espelhado
    vertical: bool             # no plano de simetria, normal para +y
    dihedral: float            # graus (+ ponta para cima); dispositivos: a inclinação deles
    strip_controls: list[Control | None]   # um por faixa (entre estações consecutivas)
    airfoil: Airfoil
    CLa: float                 # 1/rad (3D)
    CL0: float
    CLmax: float
    CD0: float
    Cmac: float
    AR: float
    oswald: float
    eta: float = 1.0
    downwash: bool = False
    eps0: float = 0.0          # rad
    depsda: float = 0.0
    parent: str = ""           # dispositivo: superfície onde está preso
    up: bool = True            # dispositivo: perna para cima
    side: int = 0              # dispositivo não espelhado: +1/−1; superfícies: 0

    @property
    def area(self) -> float:
        """área de um lado"""
        st = self.stations
        return sum(0.5 * (a.chord + b.chord) * (b.s - a.s) for a, b in zip(st, st[1:]))

    @property
    def total_area(self) -> float:
        return self.area * (2 if self.mirror else 1)

    @property
    def length(self) -> float:
        return self.stations[-1].s - self.stations[0].s

    def mac(self) -> dict[str, float]:
        """CMA = ∫c² ds / ∫c ds, posição dela na envergadura (∫c s ds / ∫c ds), bordo de ataque e
        centro aerodinâmico (25 %) nessa posição"""
        num = den = sy = 0.0
        for a, b in zip(self.stations, self.stations[1:]):
            ds = b.s - a.s
            c0, c1 = a.chord, b.chord
            num += ds * (c0 * c0 + c0 * c1 + c1 * c1) / 3
            den += ds * (c0 + c1) / 2
            sy += ds * (c0 * (2 * a.s + b.s) + c1 * (a.s + 2 * b.s)) / 6
        mac = num / den if den > 0 else 0.0
        s_mac = sy / den if den > 0 else 0.0
        le = self.le_at(s_mac)
        return dict(mac=mac, s=s_mac, x_le=float(le[0]), x_ac=float(le[0] - 0.25 * mac))

    def le_at(self, s: float) -> np.ndarray:
        st = self.stations
        for a, b in zip(st, st[1:]):
            if s <= b.s or b is st[-1]:
                f = (s - a.s) / (b.s - a.s) if b.s > a.s else 0.0
                return a.le + f * (b.le - a.le)
        return st[-1].le

    def chord_at(self, s: float) -> float:
        ss = [q.s for q in self.stations]
        return float(np.interp(s, ss, [q.chord for q in self.stations]))

    @property
    def tip(self) -> Station:
        return self.stations[-1]

    def strips(self):
        """faixas: (estação 0, estação 1, comando)"""
        return [(a, b, c) for (a, b), c in zip(zip(self.stations, self.stations[1:]), self.strip_controls)]


@dataclass
class AircraftModel:
    name: str
    S: float
    c: float
    b: float
    mac_le: float              # x do bordo de ataque da CMA da asa
    surfaces: list[SurfaceModel]
    mass: dict                 # m, cg (3), I (3×3) — massa seca
    aircraft: Aircraft         # a configuração de origem (dados não geométricos: motores, trem, ...)
    mission: object = None
    features: object = None
    downwash: tuple = (0.0, 0.0)   # ε0 (rad), dε/dα da asa principal

    @property
    def wing(self) -> SurfaceModel | None:
        return next((s for s in self.surfaces if s.role == "wing"), None)

    def by_role(self, role: str) -> list[SurfaceModel]:
        return [s for s in self.surfaces if s.role == role]

    def devices_of(self, name: str) -> list[SurfaceModel]:
        return [s for s in self.surfaces if s.role == "device" and s.parent == name]

    @property
    def htail(self) -> SurfaceModel | None:
        return next((s for s in self.surfaces if s.role == "htail"), None)

    def parasite_cd(self) -> float:
        """C_D0 das superfícies (S η) + fuselagem e tubo (C_D S) / S_ref — o mesmo que o núcleo soma"""
        tot = sum(s.CD0 * s.total_area * s.eta for s in self.surfaces)
        ac = self.aircraft
        if ac.fuselage.enabled:
            tot += ac.fuselage.CDS
        if ac.boom.enabled:
            tot += 0.006 * math.pi * ac.boom.diameter * ac.boom.length
        return tot / self.S

    def tail_volumes(self, x_cg: float) -> dict[str, float]:
        """V_H = S_h l_h / (S c), V_V = S_v l_v / (S b); braços do CG ao CA de cada cauda"""
        out = dict(VH=0.0, VV=0.0, lh=0.0, lv=0.0, Sh=0.0, Sv=0.0)
        for s in self.surfaces:
            if s.role not in ("htail", "vtail"):
                continue
            l = x_cg - s.mac()["x_ac"]
            A = s.total_area
            if s.role == "htail":
                out["Sh"] += A
                out["lh"] = l
                out["VH"] += A * l / (self.S * self.c)
            else:
                out["Sv"] += A
                out["lv"] = l
                out["VV"] += A * l / (self.S * self.b)
        return out

    def find_control(self, kinds, role: str | None = None):
        """(superfície, comando, s0, s1) do primeiro comando de um dos `kinds` (s0, s1: fração da
        envergadura da superfície onde ele está); None se não houver"""
        for s in self.surfaces:
            if role is not None and s.role != role:
                continue
            for k in kinds:
                idx = [i for i, c in enumerate(s.strip_controls) if c is not None and c.kind == k]
                if idx:
                    L = s.length or 1.0
                    return s, s.strip_controls[idx[0]], s.stations[idx[0]].s / L, s.stations[idx[-1] + 1].s / L
        return None

    def tip_fins(self) -> list[SurfaceModel]:
        """derivas soltas na ponta da asa (as que a configuração marca como dispositivos de ponta)"""
        names = {s.name for s in (self.features.tip_devices if self.features is not None else [])}
        return [s for s in self.surfaces if s.name in names]

    def x_at_mac(self, frac: float) -> float:
        return self.mac_le - frac * self.c

    def mac_frac(self, x: float) -> float:
        return (self.mac_le - x) / self.c


# ------------------------------------------------------------------ construção
def _coeffs(s: LiftingSurface) -> dict:
    AR = s.aspect_ratio or 5.0
    CLa = s.CLa if s.CLa is not None else helmbold(s.airfoil.cl_alpha, AR)
    CL0 = s.CL0 if s.CL0 is not None else -CLa * math.radians(s.airfoil.zero_lift_angle())
    return dict(AR=AR, CLa=CLa, CL0=CL0, CLmax=s.CLmax if s.CLmax is not None else 0.9 * s.airfoil.cl_max,
                CD0=s.CD0 if s.CD0 is not None else s.airfoil.cd0,
                Cmac=s.Cmac if s.Cmac is not None else s.airfoil.moment_ac())


def _breaks(s: LiftingSurface) -> list[float]:
    b = s.semispan
    ys = [sec.y for sec in s.sections]
    for c in s.controls:
        ys += [min(max(c.span_start, 0.0), 1.0) * b, min(max(c.span_end, 0.0), 1.0) * b]
    out: list[float] = []
    for y in sorted(min(max(y, 0.0), b) for y in ys):
        if not out or y - out[-1] > 1e-9:
            out.append(y)
    return out


def _control_at(s: LiftingSurface, y: float):
    b = s.semispan
    for c in s.controls:
        if c.span_start * b - 1e-9 <= y <= c.span_end * b + 1e-9:
            return c
    return None


def wing_downwash(ac: Aircraft) -> tuple[float, float]:
    """ε = ε0 + dε/dα α  da asa principal (rad): ε0 = 2 C_L0,w/(π AR), dε/dα = 2 C_Lα/(π AR)"""
    w = ac.wing
    if w is None:
        return 0.0, 0.0
    co = _coeffs(w)
    CLw0 = co["CL0"] + co["CLa"] * math.radians(w.incidence)
    return 2 * CLw0 / (math.pi * co["AR"]), 2 * co["CLa"] / (math.pi * co["AR"])


def _surface(s: LiftingSurface, index: int, dw: tuple[float, float]) -> SurfaceModel:
    co = _coeffs(s)
    dih = math.radians(s.dihedral)
    st = []
    for y in _breaks(s):
        if s.vertical:
            le = np.array([s.x - s.xoff_at(y), s.y, s.z - y])
        else:
            le = np.array([s.x - s.xoff_at(y), s.y + y * math.cos(dih), s.z - y * math.sin(dih)])
        st.append(Station(y, le, s.chord_at(y), s.incidence + s.twist_at(y)))
    ctl = []
    for a, b in zip(st, st[1:]):
        c = _control_at(s, 0.5 * (a.s + b.s))
        ctl.append(None if c is None else
                   Control(c.kind, c.tau if c.tau is not None else flap_effectiveness(c.chord_frac), c.deflection,
                           c.chord_frac))
    return SurfaceModel(
        name=s.name, role=s.role, index=index, stations=st, mirror=bool(s.symmetric and not s.vertical),
        vertical=bool(s.vertical), dihedral=s.dihedral, strip_controls=ctl, airfoil=s.airfoil,
        CLa=co["CLa"], CL0=co["CL0"], CLmax=co["CLmax"], CD0=co["CD0"], Cmac=co["Cmac"], AR=co["AR"],
        oswald=s.oswald, eta=s.eta, downwash=bool(s.downwash),
        eps0=(math.radians(s.eps0) if s.eps0 is not None else dw[0]) if s.downwash else 0.0,
        depsda=(s.depsda if s.depsda is not None else dw[1]) if s.downwash else 0.0)


def _devices(s: LiftingSurface, index: int) -> list[SurfaceModel]:
    """cada perna de cada dispositivo vira uma superfície (lado direito; espelhada se a asa for)"""
    from .devices import legs
    out = []
    for k, d in enumerate(s.devices):
        ls = legs(s, d)
        for j, l in enumerate(x for x in ls if x.side >= 0):
            n = 3
            st = []
            for i in range(n + 1):
                h = l.height * i / n
                le, c = l.station(h)
                st.append(Station(h, le, c, d.toe * (1 if l.up else -1)))
            area = 0.5 * (l.c_root + l.c_tip) * l.height
            AR = max(l.height ** 2 / max(area, 1e-9), 0.3)
            af = Airfoil(d.profile, coords=naca4(d.profile).tolist(), cl_alpha=d.cl_alpha, cd0=d.cd0)
            out.append(SurfaceModel(
                name=f"{s.name}: {d.kind} {k + 1}" + (f".{j + 1}" if d.kind == "placa" else ""), role="device",
                index=index, stations=st, mirror=l.side != 0, vertical=False, dihedral=math.degrees(l.dihedral),
                strip_controls=[None] * n, airfoil=af, CLa=helmbold(d.cl_alpha, AR), CL0=0.0, CLmax=1.0, CD0=d.cd0,
                Cmac=0.0, AR=AR, oswald=d.oswald, parent=s.name, up=l.up, side=0 if l.side else 1))
    return out


def build_model(ac: Aircraft, mission=None) -> AircraftModel:
    from .features import features
    from .massprops import dry_mass
    ac = ac.copy()
    ac.apply_constraints()
    S, c, b = ac.references()
    dw = wing_downwash(ac)
    surfs = []
    for i, s in enumerate(ac.surfaces):
        if not s.enabled or len(s.sections) < 2:
            continue
        surfs.append(_surface(s, i, dw))
        if not s.vertical:
            surfs += _devices(s, i)
    w = next((s for s in surfs if s.role == "wing"), None)
    mac_le = w.mac()["x_le"] if w is not None else 0.0
    dm = dry_mass(ac)
    return AircraftModel(ac.name, S, c, b, mac_le, surfs, dict(m=dm["m"], cg=np.asarray(dm["cg"]), I=dm["I"]),
                         ac, mission if mission is not None else ac.mission, features(ac), dw)

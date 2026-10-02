"""Modelo de dados da aeronave (a "Aircraft Data").

Unidades: metros, kg, segundos; ÂNGULOS EM GRAUS aqui (o núcleo recebe radianos,
`compile.py` converte). Eixos do corpo: x para frente, y para a direita, z para baixo,
origem no ponto de referência O (o CG pode andar em relação a ele).

Tudo é dataclass simples: serializável (serialize.py), editável pela GUI e
independente do núcleo de simulação.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass, field

from .airfoil import Airfoil
from .catalog import Battery, Motor, Propeller, ThrustPoly
from .mission import Mission, circuit


# ------------------------------------------------------------------ superfícies
@dataclass
class WingSection:
    y: float = 0.0             # distância ao longo da envergadura a partir da raiz (m)
    chord: float = 0.3
    x_offset: float = 0.0      # recuo do bordo de ataque em relação à raiz (m, + para trás)
    twist: float = 0.0         # torção (graus, + cabra)


@dataclass
class ControlSurface:
    kind: str = "aileron"      # aileron | elevator | rudder | elevon | ruddervator | flap
    span_start: float = 0.6    # fração da semi-envergadura
    span_end: float = 1.0
    chord_frac: float = 0.25   # fração da corda
    tau: float | None = None   # efetividade (None: perfil fino)
    deflection: float = 0.0    # flape: deflexão fixa (graus)


@dataclass
class LiftingSurface:
    name: str = "asa"
    role: str = "wing"         # wing | htail | vtail
    x: float = 0.0             # bordo de ataque da raiz no corpo (m)
    y: float = 0.0
    z: float = 0.0
    sections: list[WingSection] = field(default_factory=list)
    dihedral: float = 0.0      # graus
    incidence: float = 0.0     # graus
    airfoil: Airfoil = field(default_factory=Airfoil)
    symmetric: bool = True     # espelha em y (meia asa direita e esquerda)
    vertical: bool = False     # EV: seções crescem para cima (−z)
    controls: list[ControlSurface] = field(default_factory=list)
    oswald: float = 0.85
    eta: float = 1.0           # razão de pressão dinâmica
    downwash: bool = False     # sente o downwash da asa principal
    enabled: bool = True
    # sobrescritas (None: calculado a partir do perfil e da geometria)
    CLa: float | None = None
    CL0: float | None = None
    CLmax: float | None = None
    CD0: float | None = None
    Cmac: float | None = None
    eps0: float | None = None      # downwash ε0 (graus); None: da asa principal
    depsda: float | None = None    # dε/dα; None: da asa principal
    mass: float = 0.0          # massa estrutural (entra no modelo de massa por componentes)

    @property
    def semispan(self) -> float:
        return max((s.y for s in self.sections), default=0.0)

    def chord_at(self, y: float) -> float:
        return _interp_sections(self.sections, y, "chord")

    def xoff_at(self, y: float) -> float:
        return _interp_sections(self.sections, y, "x_offset")

    def twist_at(self, y: float) -> float:
        return _interp_sections(self.sections, y, "twist")

    @property
    def area(self) -> float:
        a = 0.0
        ss = sorted(self.sections, key=lambda s: s.y)
        for s0, s1 in zip(ss, ss[1:]):
            a += 0.5 * (s0.chord + s1.chord) * (s1.y - s0.y)
        return a * (2 if self.symmetric and not self.vertical else 1)

    @property
    def span(self) -> float:
        return self.semispan * (2 if self.symmetric and not self.vertical else 1)

    @property
    def aspect_ratio(self) -> float:
        return self.span**2 / self.area if self.area > 0 else 0.0

    @property
    def mac(self) -> float:
        """corda média aerodinâmica"""
        ss = sorted(self.sections, key=lambda s: s.y)
        num = den = 0.0
        for s0, s1 in zip(ss, ss[1:]):
            dy = s1.y - s0.y
            c0, c1 = s0.chord, s1.chord
            num += dy * (c0 * c0 + c0 * c1 + c1 * c1) / 3
            den += dy * (c0 + c1) / 2
        return num / den if den > 0 else 0.0


def _interp_sections(sections: list[WingSection], y: float, attr: str) -> float:
    ss = sorted(sections, key=lambda s: s.y)
    if not ss:
        return 0.0
    if y <= ss[0].y:
        return getattr(ss[0], attr)
    for s0, s1 in zip(ss, ss[1:]):
        if y <= s1.y:
            f = (y - s0.y) / (s1.y - s0.y) if s1.y > s0.y else 0.0
            return getattr(s0, attr) + f * (getattr(s1, attr) - getattr(s0, attr))
    return getattr(ss[-1], attr)


def rect_sections(semispan: float, chord: float, taper: float = 1.0, sweep: float = 0.0,
                  twist_tip: float = 0.0) -> list[WingSection]:
    """asa trapezoidal de duas seções (raiz e ponta)"""
    return [WingSection(0.0, chord, 0.0, 0.0), WingSection(semispan, chord * taper, sweep, twist_tip)]


# ------------------------------------------------------------------ fuselagem e cauda
@dataclass
class Fuselage:
    enabled: bool = True
    x_nose: float = 0.6
    length: float = 1.0
    width: float = 0.15
    height: float = 0.18
    z: float = 0.0
    CDS: float = 0.03          # área de arrasto (m²)
    Cma: float = 0.10
    Cnb: float = -0.03
    CYb: float = -0.15
    aero_point: list[float] | None = None   # None: 40 % do comprimento
    mass: float = 0.0


@dataclass
class TailBoom:
    enabled: bool = False
    x_start: float = -0.3      # onde sai da fuselagem/asa
    length: float = 0.8
    diameter: float = 0.025
    z: float = 0.0
    attach_tail: bool = True   # EH/EV ficam presos na ponta do tubo
    mass: float = 0.0

    @property
    def x_end(self) -> float:
        return self.x_start - self.length


# ------------------------------------------------------------------ propulsão
@dataclass
class PropulsionUnit:
    name: str = "motor 1"
    x: float = 0.55
    y: float = 0.0
    z: float = 0.0
    tilt: float = 3.0          # graus (+ eixo apontando para cima)
    toe: float = 0.0           # graus
    sense: int = 1             # +1 horário visto de trás, −1 anti-horário
    yaw_mix: float = 0.0       # acelerador diferencial por leme
    thrust_model: str = "motor"   # motor (motor + hélice por tabela J) | poly (polinômio de tração)
    thrust_poly: ThrustPoly = field(default_factory=ThrustPoly)
    motor: Motor = field(default_factory=Motor)
    propeller: Propeller = field(default_factory=Propeller)
    battery: Battery = field(default_factory=Battery)
    enabled: bool = True


# ------------------------------------------------------------------ trem de pouso
@dataclass
class GearLeg:
    kind: str = "main"         # steer | main | skid
    x: float = 0.0
    y: float = 0.0
    z: float = 0.2
    k: float = 4000.0
    c: float = 120.0


@dataclass
class LandingGear:
    layout: str = "tricycle"   # tricycle | conventional | custom
    main_x: float = -0.05
    main_track: float = 0.6    # distância entre as rodas principais
    main_z: float = 0.22
    main_k: float = 4000.0
    main_c: float = 120.0
    steer_x: float = 0.45      # bequilha (triciclo) ou roda de cauda (convencional)
    steer_z: float = 0.22
    steer_k: float = 2000.0
    steer_c: float = 60.0
    tail_skid: bool = True     # ponto de cauda (detecta toque da cauda no triciclo)
    skid_x: float = -1.1
    skid_z: float = 0.0
    skid_k: float = 6000.0
    skid_c: float = 150.0
    custom: list[GearLeg] = field(default_factory=list)
    mu_roll: float = 0.04
    mu_lat: float = 0.6
    mu_brake: float = 1.0
    mu_skid: float = 0.35
    mu_landing: float = 0.40

    def legs(self) -> list[GearLeg]:
        if self.layout == "custom":
            return list(self.custom)
        out = [GearLeg("steer", self.steer_x, 0.0, self.steer_z, self.steer_k, self.steer_c),
               GearLeg("main", self.main_x, -self.main_track / 2, self.main_z, self.main_k, self.main_c),
               GearLeg("main", self.main_x, self.main_track / 2, self.main_z, self.main_k, self.main_c)]
        if self.layout == "tricycle" and self.tail_skid:
            out.append(GearLeg("skid", self.skid_x, 0.0, self.skid_z, self.skid_k, self.skid_c))
        return out


# ------------------------------------------------------------------ cargas
@dataclass
class SloshTank:
    name: str = "tanque"
    x: float = 0.1
    y: float = 0.0
    z: float = 0.05
    side: float = 0.14         # lado da base quadrada (ou diâmetro, se cilindro) (m)
    fill: float = 0.08         # altura do líquido (m)
    height: float = 0.12       # altura do tanque (só para desenhar)
    rho: float = 1000.0
    zeta: float = 0.03
    shape: str = "square"      # square | cylinder

    @property
    def liquid_mass(self) -> float:
        import math
        a = self.side
        return self.rho * self.fill * (a * a if self.shape == "square" else math.pi * a * a / 4)


@dataclass
class Payload:
    enabled: bool = False
    mass: float = 2.0
    x: float = -0.05
    y: float = 0.0
    z: float = 0.08
    bay: float = 0.35          # comprimento da baia (m)
    Fext_g: float = 2.0        # força do paraquedas extrator (em g da carga)
    mu_b: float = 0.3
    CdS_chute: float = 0.45


@dataclass
class PointMass:
    name: str = "item"
    mass: float = 0.1
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0


@dataclass
class MassModel:
    """massa seca = base (com inércia própria no CG dela) + itens pontuais
    (+ motores, hélices e baterias, se include_propulsion)"""
    base_mass: float = 8.39
    base_cg: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    Ixx: float = 0.90
    Iyy: float = 1.20
    Izz: float = 1.90
    Ixz: float = 0.04
    items: list[PointMass] = field(default_factory=list)
    include_propulsion: bool = False
    include_structure: bool = False   # massas das superfícies/fuselagem/tubo


# ------------------------------------------------------------------ ambiente e pilotagem
@dataclass
class Environment:
    rho: float = 1.225
    wind_speed: float = 4.0    # a 10 m (m/s)
    wind_from: float = 30.0    # graus (de onde vem; 0 = norte, 90 = leste)
    wind_elev: float = 3.0     # graus
    h_ref: float = 10.0
    gust: bool = False
    gust_T: float = 1.0
    gust_U: list[float] = field(default_factory=lambda: [-1.0, -2.0, -1.0])


@dataclass
class Takeoff:
    VR: float = 12.5           # m/s
    sR: float = 0.0            # m (> 0: usa distância em vez de VR)
    de0: float = 0.0           # graus
    de1: float = -6.0
    rate_de: float = 60.0      # graus/s
    ht: float = 2.0            # altura em que o piloto automático assume
    rate_thr: float = 2.0
    h_end: float = 6.0


@dataclass
class Autopilot:
    auto_calibrate: bool = True  # recalcula CL0, CLa (polar) e Dtrim (trimagem) antes de rodar
    CL0: float = 0.45          # modelo interno do piloto (calibrado pela polar)
    CLa: float = 4.5
    alpha_max: float = 11.0    # graus
    g_up: float = 0.08
    g_down: float = 0.10
    Khr: float = 0.5
    Kvs: float = 0.5
    Kn_h: float = 0.065
    Kn_hd: float = 0.13
    Kn_ih: float = 0.01
    Kae: float = 4.0
    KIa: float = 4.0
    Kfn: float = 1.2
    Lorb: float = 50.0
    tlead: float = 0.8
    Kthe: float = 1.5
    Kqe: float = 0.25
    KV: float = 0.25
    KIV: float = 0.08
    KHT: float = 0.10
    Dtrim: float = 0.55
    Kchi: float = 0.8
    kvf: float = 0.05
    chi_inf: float = 60.0      # graus
    korb: float = 0.5
    phimax: float = 30.0       # graus
    Kphia: float = 2.0
    Kpa: float = 0.10
    Kbeta: float = 1.0
    tau_phi: float = 0.3
    pmax_cmd: float = 60.0     # graus/s
    Ky: float = 0.15
    Ki: float = 0.02
    Kpsi: float = 1.5
    Kr: float = 0.3
    Kbeq: float = 0.5
    hflare: float = 2.5
    tau_flare: float = 1.0
    kCL: float = 0.95
    de_max: float = 20.0       # graus
    da_max: float = 20.0
    dr_max: float = 25.0


ANGLE_KEYS_AP = ("alpha_max", "chi_inf", "phimax", "pmax_cmd", "de_max", "da_max", "dr_max")


@dataclass
class SimSettings:
    dt: float = 1e-3
    tmax: float = 400.0
    dtlog: float = 0.02
    Mst: float = 50.0          # transição linear/estol (Beard e McLain)
    slosh: bool = True


@dataclass
class Aircraft:
    name: str = "aeronave"
    surfaces: list[LiftingSurface] = field(default_factory=list)
    fuselage: Fuselage = field(default_factory=Fuselage)
    boom: TailBoom = field(default_factory=TailBoom)
    propulsion: list[PropulsionUnit] = field(default_factory=list)
    gear: LandingGear = field(default_factory=LandingGear)
    tanks: list[SloshTank] = field(default_factory=list)
    payload: Payload = field(default_factory=Payload)
    mass: MassModel = field(default_factory=MassModel)
    environment: Environment = field(default_factory=Environment)
    takeoff: Takeoff = field(default_factory=Takeoff)
    autopilot: Autopilot = field(default_factory=Autopilot)
    sim: SimSettings = field(default_factory=SimSettings)
    mission: Mission = field(default_factory=circuit)
    shared_battery: bool = False   # True: um pacote para todos os motores (R_int vezes K)
    Sref: float | None = None      # None: da asa principal
    cref: float | None = None
    bref: float | None = None

    # ----------------------------------------------------------- acesso
    def surface(self, role: str) -> LiftingSurface | None:
        return next((s for s in self.surfaces if s.role == role and s.enabled), None)

    @property
    def wing(self) -> LiftingSurface | None:
        return self.surface("wing")

    def references(self) -> tuple[float, float, float]:
        w = self.wing
        S = self.Sref if self.Sref else (w.area if w else 1.0)
        c = self.cref if self.cref else (w.mac if w else 0.3)
        b = self.bref if self.bref else (w.span if w else 1.0)
        return S, c, b

    def copy(self) -> "Aircraft":
        return copy.deepcopy(self)

    def apply_constraints(self) -> None:
        """amarrações geométricas (ex.: cauda na ponta do tubo)"""
        if self.boom.enabled and self.boom.attach_tail:
            for s in self.surfaces:
                if s.role in ("htail", "vtail") and s.sections:
                    root = min(s.sections, key=lambda q: q.y)
                    s.x = self.boom.x_end + root.chord
                    s.z = self.boom.z if s.role == "htail" else self.boom.z - self.boom.diameter / 2

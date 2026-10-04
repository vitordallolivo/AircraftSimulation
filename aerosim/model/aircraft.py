"""Modelo de dados da aeronave (a "Aircraft Data").

Unidades: metros, kg, segundos; ÂNGULOS EM GRAUS aqui (o núcleo recebe radianos,
`compile.py` converte). Eixos do corpo: x para frente, y para a direita, z para baixo,
origem no ponto de referência O (o CG pode andar em relação a ele).

Tudo é dataclass simples: serializável (serialize.py), editável pela GUI e
independente do núcleo de simulação.
"""
from __future__ import annotations

import copy
import math
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


DEVICE_KINDS = ("winglet", "winglet_baixo", "placa", "cerca")


@dataclass
class WingDevice:
    """dispositivo preso a uma superfície (dos dois lados, se ela for simétrica)
    winglet: para cima; winglet_baixo: para baixo; placa: metade para cima e metade para baixo;
    cerca: placa fina sobre o extradorso (fence), em qualquer ponto da envergadura"""
    kind: str = "winglet"
    eta: float = 1.0           # onde, na semienvergadura (0 = raiz, 1 = ponta)
    dx: float = 0.0            # recuo do bordo de ataque do dispositivo em relação ao BA local (m, + para trás)
    height: float = 0.15       # altura (m) — na placa, a soma das duas metades
    root_chord: float = 0.0    # corda na raiz do dispositivo (m); 0: a corda local da asa
    taper: float = 0.6         # corda da ponta / corda da raiz
    sweep: float = 30.0        # enflechamento do bordo de ataque (graus)
    cant: float = 10.0         # inclinação a partir da vertical (graus): 0 = vertical, 90 = no plano da asa
    toe: float = 0.0           # calagem (graus, + bordo de ataque para fora)
    profile: str = "NACA 0010"
    cl_alpha: float = 5.9
    cd0: float = 0.012
    oswald: float = 0.8
    enabled: bool = True


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
    devices: list[WingDevice] = field(default_factory=list)   # winglets, placas, cercas
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
    mount: str = ""            # "" solta | "tubo:i" na ponta do tubo i | "ponta:j" na ponta da superfície j

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
    """tubo (de cauda ou qualquer outro): sai de (x_start, y, z) para trás, com inclinação e guinada livres.
    Tubo duplo = dois tubos (y = ±d). As superfícies se prendem nele pela `mount` delas ("tubo:0")."""
    name: str = "tubo"
    enabled: bool = True
    x_start: float = -0.3      # onde sai da fuselagem/asa
    y: float = 0.0
    z: float = 0.0
    length: float = 0.8
    diameter: float = 0.025
    pitch: float = 0.0         # graus (+ ponta de trás para cima)
    yaw: float = 0.0           # graus (+ ponta de trás para a direita, +y)
    mass: float = 0.0

    @property
    def start(self) -> tuple[float, float, float]:
        return self.x_start, self.y, self.z

    @property
    def end(self) -> tuple[float, float, float]:
        t, p = math.radians(self.pitch), math.radians(self.yaw)
        L = self.length
        return (self.x_start - L * math.cos(t) * math.cos(p), self.y + L * math.cos(t) * math.sin(p),
                self.z - L * math.sin(t))

    @property
    def x_end(self) -> float:
        return self.end[0]

    @property
    def middle(self) -> tuple[float, float, float]:
        return tuple(0.5 * (a + b) for a, b in zip(self.start, self.end))


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
    volume: float = 2.0        # volume de líquido (L)
    height: float = 0.12       # altura do tanque (só para desenhar)
    rho: float = 1000.0        # densidade do líquido (kg/m³; água = 1000)
    zeta: float = 0.03
    shape: str = "square"      # square | cylinder

    @property
    def base_area(self) -> float:
        a = self.side
        return a * a if self.shape == "square" else math.pi * a * a / 4

    @property
    def fill(self) -> float:
        """altura do líquido (m), pelo volume"""
        return self.volume / 1000.0 / self.base_area

    @property
    def liquid_mass(self) -> float:
        return self.rho * self.volume / 1000.0


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
    target_n: float = 0.0      # alvo da carga no chão (m, norte)
    target_e: float = 0.0
    aim: bool = True           # procura onde soltar para a carga cair no alvo


@dataclass
class Ballast:
    """lastro: massa sólida presa na aeronave (para acertar o CG / a estabilidade)"""
    enabled: bool = False
    mass: float = 0.3
    x: float = 0.4
    y: float = 0.0
    z: float = 0.0


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


# ------------------------------------------------------------------ pista, mesa e plataforma
@dataclass
class Airfield:
    """onde a aeronave decola e pousa: no chão, em cima de uma mesa ou numa plataforma
    (cada uma com o seu tamanho). A aeronave parte de n = 0 rumo ao norte."""
    takeoff_from: str = "chão"         # chão | mesa
    table_height: float = 1.0          # altura da mesa (m)
    table_length: float = 8.0          # comprimento da mesa à frente do ponto de partida (m)
    table_back: float = 1.0            # mesa atrás do ponto de partida (m)
    table_width: float = 2.0
    landing_on: str = "chão"           # chão | plataforma
    platform_height: float = 0.5
    platform_length: float = 80.0
    platform_width: float = 6.0
    platform_start: float = 50.0       # a plataforma começa este tanto antes do fim da perna de pouso (m)
    x_warning: float = 60.0            # comprimento de pista exigido (m): tem de "decolar" antes disso
    z_warning: float = 1.0             # altura (m) sobre a superfície de partida que conta como decolado
                                       # (≤ 0 na mesa: quanto pode afundar abaixo dela depois da borda)
    landing_max: float = 0.0           # distância máxima de pouso (m); 0: não verifica

    def pads(self, mission) -> list[dict]:
        """mesas/plataformas no referencial do percurso (n, e, rumo em rad) para o núcleo"""
        out = []
        if self.takeoff_from == "mesa" and self.table_height > 0:
            out.append(dict(n0=-self.table_back, e0=0.0, chi=0.0, L=self.table_back + self.table_length,
                            W=self.table_width, h=self.table_height))
        if self.landing_on == "plataforma" and self.platform_height > 0 and mission is not None:
            segs = mission.segments()
            ld = next((s for s in reversed(segs) if s.get("landing") and not s.get("arc")), None)
            if ld is not None:
                st = max(ld["L"] - self.platform_start, 0.0)
                c, s_ = math.cos(ld["chi0"]), math.sin(ld["chi0"])
                out.append(dict(n0=ld["n0"] + st * c, e0=ld["e0"] + st * s_, chi=ld["chi0"], L=self.platform_length,
                                W=self.platform_width, h=self.platform_height))
        return out


# ------------------------------------------------------------------ ambiente e pilotagem
@dataclass
class Environment:
    """ar e vento. A densidade se escolhe pela altitude-densidade (AD, atmosfera padrão): mudar a AD
    muda ρ (`set_density_altitude`); arquivo antigo sem AD: a AD sai do ρ gravado."""
    rho: float = 1.225
    density_altitude: float = float("nan")  # AD (m); sem valor (arquivo antigo): calculada do ρ
    wind_speed: float = 4.0    # a 10 m (m/s)
    wind_from: float = 30.0    # graus (de onde vem; 0 = norte, 90 = leste)
    wind_elev: float = 3.0     # graus
    h_ref: float = 10.0
    gust: bool = False
    gust_T: float = 1.0
    gust_U: list[float] = field(default_factory=lambda: [-1.0, -2.0, -1.0])

    def __post_init__(self):
        from .atmosphere import density_altitude, isa_density
        if self.density_altitude is None or not math.isfinite(self.density_altitude):
            self.density_altitude = density_altitude(self.rho)
        else:
            self.rho = isa_density(self.density_altitude)

    def set_density_altitude(self, h: float) -> None:
        from .atmosphere import isa_density
        self.density_altitude = float(h)
        self.rho = isa_density(h)


@dataclass
class Takeoff:
    """corrida: acelerador cheio; no ponto de acionamento sR o profundor (ou elevon) vai para de1.
    A aba Missão otimiza sR (e usa a maior deflexão que funciona) para o x_warning e o z_warning."""
    VR: float = 12.5           # m/s (só se sR = 0: aciona por velocidade)
    sR: float = 37.5           # ponto de acionamento do profundor na pista (m)
    de0: float = 0.0           # graus (profundor durante a corrida)
    de1: float = -6.0          # deflexão de decolagem (graus, − cabra)
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
class PerformanceData:
    """dados do envelope de voo "como na planilha" (Envelope_main original)"""
    alpha_cruise: float = 2.0          # ângulo de cruzeiro (graus) — AnguloCruzeiro
    load_factor: float = 2.0           # n de projeto: V* = V_e √n
    rho0: float = 1.225                # densidade de referência (nível do mar)
    cdp_x: float = 12.0                # C_Dp = c1 · cdp_x + c2 (como no código original)
    cdp_wing: list[float] = field(default_factory=lambda: [0.0, 0.012])     # c1, c2 da asa
    cdp_htail: list[float] = field(default_factory=lambda: [0.0, 0.012])    # c1, c2 do EH
    K: float | None = None             # C_Di = K C_L²; None: 1/(π e AR) da asa
    ceiling_min: float = 500.0         # teto mínimo exigido (o original devolve True/False)


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
    booms: list[TailBoom] = field(default_factory=list)
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
    airfield: Airfield = field(default_factory=Airfield)
    ballast: Ballast = field(default_factory=Ballast)
    performance: PerformanceData = field(default_factory=PerformanceData)
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

    @property
    def boom(self) -> TailBoom:
        """o primeiro tubo ligado (compatibilidade: projetos de um tubo só); sem tubo, um desligado"""
        return next((b for b in self.booms if b.enabled), TailBoom(enabled=False))

    @boom.setter
    def boom(self, b: TailBoom) -> None:
        self.booms = [b] if b.enabled else []

    @staticmethod
    def migrate(data: dict) -> dict:
        """arquivos antigos: `boom` único com `attach_tail` → lista `booms` e `mount` nas superfícies de cauda"""
        if "boom" in data and "booms" not in data:
            b = dict(data.pop("boom") or {})
            attach = b.pop("attach_tail", True)
            data["booms"] = [b] if b.get("enabled") else []
            if b.get("enabled") and attach:
                for s in data.get("surfaces", []):
                    if s.get("role") in ("htail", "vtail") and not s.get("mount"):
                        s["mount"] = "tubo:0"
        return data

    def mount_point(self, s: LiftingSurface) -> tuple[float, float, float] | None:
        """onde a raiz de `s` fica presa: 'tubo:i' (bordo de fuga da raiz na ponta do tubo) ou
        'ponta:j' (bordo de ataque da raiz no da ponta da superfície j — cauda em T, winglet...)"""
        kind, _, idx = (s.mount or "").partition(":")
        if not idx.lstrip("-").isdigit() or not s.sections:
            return None
        i = int(idx)
        root = min(s.sections, key=lambda q: q.y)
        if kind == "tubo" and 0 <= i < len(self.booms) and self.booms[i].enabled:
            b = self.booms[i]
            x, y, z = b.end
            return x + root.chord, y, (z - b.diameter / 2 if s.vertical else z)
        if kind == "ponta" and 0 <= i < len(self.surfaces) and self.surfaces[i] is not s:
            t = self.surfaces[i]
            if not t.sections:
                return None
            ys = t.semispan
            if t.vertical:
                return t.x - t.xoff_at(ys), t.y, t.z - ys
            d = math.radians(t.dihedral)
            return t.x - t.xoff_at(ys), (t.y if t.symmetric else t.y + ys * math.cos(d)), t.z - ys * math.sin(d)
        return None

    def apply_constraints(self) -> None:
        """amarrações geométricas: cada superfície com `mount` vai para o ponto dela (na ordem da
        lista, então uma EH em T presa numa EV presa num tubo segue os dois)"""
        for _ in range(2):
            for s in self.surfaces:
                p = self.mount_point(s)
                if p is None:
                    continue
                s.x, s.z = p[0], p[2]
                if s.vertical or not s.symmetric:
                    s.y = p[1]

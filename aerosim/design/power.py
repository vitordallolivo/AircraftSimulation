"""Etapa Motores e montagem: onde ficam os motores (e por consequência a bateria, a carga e o trem) e o
avião inteiro que sai daqui para a Montagem.

`assemble` junta o conjunto guardado (asa + cauda + tubo) com uma fuselagem curta (pod, das regras),
os motores do catálogo, a bateria posta onde o CG cai na margem pedida (se não couber na fuselagem,
lastro), a carga paga no CG e o trem a partir do CG. A fuselagem desestabiliza (Munk:
C_mα ≈ 2 (k2 − k1) Vol / (S c̄)), então o CG é recalculado com ela para a margem continuar a pedida.

`performance` é o desempenho rápido do avião montado: tração disponível × arrasto, razão de subida,
corrida de decolagem e a massa máxima que a pista permite (MTOW pela pista).
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.aircraft import (Aircraft, Ballast, Fuselage, LandingGear, MassModel, PointMass,
                                    PropulsionUnit)
from aerosim.model.catalog import Catalog, builtin_catalog

from .fields import F
from .spec import G0, DesignRules, Requirements, stall_speed
from .tail import SetCandidate, analyze as analyze_set

LAYOUTS = ("tratora no nariz", "dois motores na asa", "propulsora atrás da asa")
THRUST = ("motor + hélice", "conjunto de tração")
GEARS = ("triciclo", "convencional")
K_MUNK = 0.9          # k2 − k1 de um corpo alongado (fineza ~ 6 a 8)


@dataclass
class PowerParams:
    name: str = F("avião 1", "nome", "", "nome do avião que vai para a Montagem")
    set: str = F("conjunto 1", "conjunto", "", "um dos conjuntos guardados na etapa Empenagem")
    layout: str = F("tratora no nariz", "motores", "", "", choices=LAYOUTS)
    thrust_model: str = F("motor + hélice", "tração por", "", "motor + hélice do catálogo ou um conjunto de tração "
                          "(polinômio, aba Tração)", choices=THRUST)
    motor: str = F("Scorpion A-5025-310Kv", "motor")
    propeller: str = F("APC 15x8E", "hélice")
    battery: str = F("LiPo 6S 5000", "bateria", "", "uma por motor")
    thrust_set: str = F("", "conjunto de tração")
    tilt: float = F(0.0, "inclinação do eixo", "°", "+ eixo apontando para cima", -10, 10, 0.5)
    gear: str = F("triciclo", "trem", "", "triciclo: bequilha no nariz; convencional: bequilha na cauda", choices=GEARS)


@dataclass
class AircraftCandidate:
    params: PowerParams = field(default_factory=PowerParams)
    set: SetCandidate = field(default_factory=SetCandidate)
    note: str = ""

    @property
    def name(self) -> str:
        return self.params.name


def _unit(pp: PowerParams, cat: Catalog, name, x, y, z, sense) -> PropulsionUnit:
    u = PropulsionUnit(name=name, x=x, y=y, z=z, tilt=pp.tilt, sense=sense)
    try:
        u.motor = copy.deepcopy(cat.motor(pp.motor))
    except Exception:
        pass
    try:
        u.propeller = copy.deepcopy(cat.propeller(pp.propeller))
    except Exception:
        pass
    try:
        u.battery = copy.deepcopy(cat.battery(pp.battery))
    except Exception:
        pass
    if pp.thrust_model == THRUST[1] and pp.thrust_set:
        try:
            u.thrust_poly = copy.deepcopy(cat.thrust_set(pp.thrust_set))
            u.thrust_model = "poly"
        except Exception:
            pass
    return u


def assemble(cand: AircraftCandidate, req: Requirements, rules: DesignRules | None = None,
             catalog: Catalog | None = None, airfoils: dict | None = None) -> tuple[Aircraft, dict]:
    """o avião inteiro (o mesmo `Aircraft` da Montagem) e as contas da montagem"""
    from aerosim.model.templates import conventional
    rules = rules or DesignRules()
    cat = catalog or builtin_catalog()
    pp = cand.params
    st = analyze_set(cand.set, req, rules, airfoils)
    part, info, wr = st["set"], st["info"], st["wing"]
    ac = conventional()                               # o resto (piloto, missão, pista, simulação) de partida
    ac.name = pp.name
    ac.surfaces = copy.deepcopy(part.surfaces)
    ac.boom = copy.deepcopy(part.boom)
    ac.Sref = ac.cref = ac.bref = None
    ac.tanks = []
    ac.payload.enabled = False
    ac.mission.events = [e for e in ac.mission.events if e.kind != "drop"]
    ac.environment.set_density_altitude(req.density_altitude)
    ac.performance.alpha_cruise = cand.set.wing.params.alpha_cruise
    ac.airfield.x_warning = req.takeoff_run
    w = ac.surfaces[0]
    cr = w.sections[0].chord
    S, c, b = info["S"], info["c"], info["b"]
    D = 0.381
    # ---- fuselagem (pod) e motores
    fw, fh = rules.fuselage_width, rules.fuselage_height
    if pp.layout == LAYOUTS[0]:
        x_nose = rules.nose_length
    else:
        x_nose = 0.6 * rules.nose_length
    length = x_nose + cr + 0.05
    units = []
    if pp.layout == LAYOUTS[0]:
        units = [_unit(pp, cat, "motor 1", x_nose, 0.0, 0.0, 1)]
    elif pp.layout == LAYOUTS[1]:
        D0 = _unit(pp, cat, "m", 0, 0, 0, 1).propeller.D
        y = max(D0 / 2 + fw / 2 + 0.05, 0.15)
        xm = 0.15 + 0.02
        units = [_unit(pp, cat, "motor esq", xm, -y, w.z, 1), _unit(pp, cat, "motor dir", xm, y, w.z, -1)]
    else:
        units = [_unit(pp, cat, "motor 1", -cr - 0.06, 0.0, 0.0, 1)]
    ac.propulsion = units
    D = max(u.propeller.D for u in units)
    vol = math.pi / 6 * fw * fh * length
    Swet = math.pi * 0.5 * (fw + fh) * length * 0.75
    ac.fuselage = Fuselage(enabled=True, x_nose=x_nose, length=length, width=fw, height=fh, z=0.0,
                           CDS=rules.fuselage_cd_wet * Swet, Cma=2 * K_MUNK * vol / (S * c),
                           Cnb=-2 * K_MUNK * vol / (S * b), CYb=-0.15, aero_point=None)
    # ---- CG com a fuselagem (a margem continua a pedida)
    a_w = wr["CLa"]
    h_n = st["h_n"] - ac.fuselage.Cma / a_w
    h_t = h_n - cand.set.params.sm_target / 100
    x_t = info["x_le_mac"] - h_t * c
    # ---- massas
    pf_mass = []                                         # (nome, massa, x, z) — estrutura
    pf_mass.append(("asa", S * rules.wing_density, info["x_le_mac"] - 0.4 * c, w.z))
    for s_ in ac.surfaces[1:]:
        pf_mass.append((s_.name, s_.area * rules.tail_density, s_.x - 0.4 * s_.sections[0].chord, s_.z))
    if ac.boom.enabled:
        pf_mass.append(("tubo de cauda", ac.boom.length * rules.boom_density, 0.5 * (ac.boom.x_start + ac.boom.x_end),
                        ac.boom.z))
    pf_mass.append(("fuselagem", length * rules.fuselage_density, x_nose - 0.45 * length, 0.0))
    pf_mass.append(("trem de pouso", rules.gear_mass, x_t, 0.1))
    m_s = sum(m for _, m, _, _ in pf_mass)
    xs = sum(m * x for _, m, x, _ in pf_mass) / m_s
    zs = sum(m * z for _, m, _, z in pf_mass) / m_s
    I = _base_inertia(pf_mass, xs, zs, b, c, ac)
    items = []
    for u in units:
        k = 1.0 if u.x < 0 else -1.0
        items.append(PointMass(f"{u.name}: motor", u.motor.mass, u.x + k * 0.06, u.y, u.z))
        items.append(PointMass(f"{u.name}: hélice", u.propeller.mass, u.x, u.y, u.z))
    items.append(PointMass("sistemas", rules.systems_mass, 0.5 * x_nose, 0.0, 0.0))
    items.append(PointMass("carga paga", req.payload, x_t, 0.0, 0.03))
    m_bat = sum(u.battery.mass for u in units)
    M = m_s + sum(i.mass for i in items) + m_bat
    Mx = m_s * xs + sum(i.mass * i.x for i in items)
    x_bat = (M * x_t - Mx) / m_bat if m_bat > 0 else x_t
    lo, hi = x_nose - length + 0.08, x_nose - 0.12
    x_bat_c = min(max(x_bat, lo), hi)
    items.append(PointMass("bateria", m_bat, x_bat_c, 0.0, 0.02))
    Mx += m_bat * x_bat_c
    ballast = Ballast(enabled=False, mass=0.0)
    if abs(x_bat_c - x_bat) > 1e-6:
        xb = x_nose - 0.04 if x_bat > x_bat_c else (ac.boom.x_end + 0.05 if ac.boom.enabled else lo)
        mb = (M * x_t - Mx) / (xb - x_t)
        if mb > 0:
            ballast = Ballast(enabled=True, mass=float(mb), x=float(xb), y=0.0, z=0.0)
            M += mb
    ac.ballast = ballast
    ac.mass = MassModel(base_mass=m_s, base_cg=[xs, 0.0, zs], Ixx=I[0], Iyy=I[1], Izz=I[2], Ixz=0.0, items=items,
                        include_propulsion=False, include_structure=False)
    # ---- trem
    gz = (D / 2 + rules.prop_clearance) if pp.layout != LAYOUTS[1] else max(D / 2 + rules.prop_clearance + w.z, 0.12)
    if pp.gear == GEARS[0]:
        ac.gear = LandingGear("tricycle", main_x=x_t - rules.main_gear_aft, main_track=rules.track, main_z=gz,
                              steer_x=x_nose - 0.10, steer_z=gz, tail_skid=ac.boom.enabled,
                              skid_x=ac.boom.x_end if ac.boom.enabled else -1.0, skid_z=0.0, mu_roll=req.mu_roll)
    else:
        ac.gear = LandingGear("conventional", main_x=x_t + 0.10, main_track=rules.track, main_z=gz,
                              steer_x=ac.boom.x_end if ac.boom.enabled else x_t - 0.6, steer_z=0.05, steer_k=1500,
                              steer_c=40, tail_skid=False, mu_roll=req.mu_roll)
    # ---- decolagem e piloto (o piloto ainda se calibra sozinho antes de voar)
    Vs = stall_speed(req, S, wr["CLmax"], M)
    ac.takeoff.VR = round(1.15 * Vs, 2)
    ac.takeoff.sR = 0.0
    ac.autopilot.CL0 = float(wr["CL0"] + wr["CLa"] * math.radians(wr["incidence"]))
    ac.autopilot.CLa = float(wr["CLa"])
    ac.apply_constraints()
    xs_all = [x_nose] + [u.x for u in units] + [s_.x - s_.sections[0].chord for s_ in ac.surfaces]
    total_len = max(xs_all) - min(xs_all + ([ac.boom.x_end] if ac.boom.enabled else []))
    out = dict(set=st, x_cg_target=x_t, h_n=h_n, sm=100 * (h_n - h_t), mass=M, empty=M - req.payload,
               x_bat=x_bat, x_bat_used=x_bat_c, battery_fits=abs(x_bat_c - x_bat) < 1e-6, ballast=ballast.mass,
               length=total_len, structure=m_s, masses=pf_mass, items=items, Vs=Vs, D=D,
               boom_hits_prop=pp.layout == LAYOUTS[2] and ac.boom.enabled)
    return ac, out


def _base_inertia(parts, xs, zs, b, c, ac) -> tuple[float, float, float]:
    Ixx = Iyy = Izz = 0.0
    for name, m, x, z in parts:
        dx, dz = x - xs, z - zs
        Iyy += m * (dx * dx + dz * dz)
        Ixx += m * dz * dz
        Izz += m * dx * dx
        if name == "asa":
            Ixx += m * b * b / 12
            Izz += m * (b * b + c * c) / 12
            Iyy += m * c * c / 12
        elif name in ("tubo de cauda", "fuselagem"):
            L = ac.boom.length if name == "tubo de cauda" else ac.fuselage.length
            Iyy += m * L * L / 12
            Izz += m * L * L / 12
    return max(Ixx, 1e-4), max(Iyy, 1e-4), max(Izz, 1e-4)


# ------------------------------------------------------------------ desempenho rápido
def thrust_of(ac: Aircraft, V: np.ndarray, rho: float, backend=None) -> np.ndarray:
    """tração total com acelerador cheio: o núcleo, se houver; senão o equilíbrio motor + hélice aqui"""
    V = np.asarray(V, float)
    if backend is not None:
        try:
            from aerosim.manager.simulations.thrust import thrust_curves
            ac2 = copy.deepcopy(ac)
            ac2.environment.rho = rho
            cur = thrust_curves(backend, ac2, float(V.max()) + 0.5, 0.5)
            tot = np.zeros_like(V)
            for d in cur.values():
                cols = d[max(d)]
                tot += np.interp(V, cols["V"], cols["T"])
            return tot
        except Exception:
            pass
    tot = np.zeros_like(V)
    for u in ac.propulsion:
        if not u.enabled:
            continue
        if u.thrust_model == "poly":
            tot += np.array([u.thrust_poly.thrust(v, 1.0, 0.0, rho) for v in V])
        else:
            tot += np.array([_motor_prop(u, v, rho) for v in V])
    return tot


def _motor_prop(u: PropulsionUnit, V: float, rho: float) -> float:
    m, p, bt = u.motor, u.propeller, u.battery
    if not p.J:
        return 0.0
    kv = m.Kv * 2 * math.pi / 60
    R = m.Rm + bt.Rint
    D = p.D

    def resid(w):
        I = min((bt.Voc - w / kv) / R, m.Imax)
        Qm = I / kv - m.tauc - m.B * w
        n = w / (2 * math.pi)
        J = V / (n * D) if n > 0 else 0.0
        CP = float(np.interp(J, p.J, p.CP))
        return Qm - CP * rho * n * n * D ** 5 / (2 * math.pi), n, J
    lo, hi = 1.0, bt.Voc * kv
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if resid(mid)[0] > 0:
            lo = mid
        else:
            hi = mid
    _, n, J = resid(0.5 * (lo + hi))
    CT = float(np.interp(J, p.J, p.CT, right=0.0))
    return max(CT * rho * n * n * D ** 4, 0.0)


def performance(ac: Aircraft, asm: dict, req: Requirements, backend=None) -> dict:
    from aerosim.model.universal import build_model
    wr = asm["set"]["wing"]
    model = build_model(ac)
    S = model.S
    CD0 = model.parasite_cd()
    K = 1 / (math.pi * wr["AR"] * min(max(wr["e"], 0.5), 1.0))
    rho = req.rho
    M = asm["mass"]
    W = M * G0
    Vs = stall_speed(req, S, wr["CLmax"], M)
    V = np.linspace(max(0.8 * Vs, 2.0), max(3.0 * Vs, req.V_cruise * 1.8), 120)
    T = thrust_of(ac, V, rho, backend)
    q = 0.5 * rho * V * V
    CL = W / (q * S)
    Dg = q * S * (CD0 + K * CL * CL)
    RC = (T - Dg) * V / W
    ok = T >= Dg
    Vmax = float(V[ok][-1]) if ok.any() else float("nan")
    i = int(np.argmax(RC))
    CLg = wr["CL0"] + wr["CLa"] * math.radians(wr["incidence"])
    T0 = float(thrust_of(ac, np.array([0.0]), rho, backend)[0])
    Vg = np.r_[0.0, V]
    Tgv = np.r_[T0, T]

    def run(mass):
        Vlof = 1.1 * stall_speed(req, S, wr["CLmax"], mass)
        x = v = 0.0
        dt = 0.02
        for _ in range(20000):
            qq = 0.5 * rho * v * v
            L = qq * S * CLg
            Dd = qq * S * (CD0 + K * CLg * CLg)
            a = (np.interp(v, Vg, Tgv) - Dd - req.mu_roll * max(mass * G0 - L, 0.0)) / mass
            if a <= 0:
                return float("inf")
            v += a * dt
            x += v * dt
            if v >= Vlof:
                return x
        return float("inf")
    s_to = run(M)
    lo, hi = max(asm["empty"], 0.1), max(4 * M, 1.0)
    if run(lo) > req.takeoff_run:
        mtow = float("nan")
    else:
        for _ in range(40):
            mid = 0.5 * (lo + hi)
            if run(mid) <= req.takeoff_run:
                lo = mid
            else:
                hi = mid
        mtow = lo
    masses = np.linspace(max(asm["empty"], 0.5), max(2.2 * M, mtow if math.isfinite(mtow) else 0) * 1.05, 25)
    s_curve = np.array([run(m) for m in masses])
    return dict(V=V, T=T, D=Dg, RC=RC, P_req=Dg * V, P_av=T * V, Vs=Vs, Vmax=Vmax, RC_max=float(RC[i]), V_y=float(V[i]),
                CD0=CD0, K=K, s_to=s_to, mtow_runway=mtow, payload_runway=mtow - (M - req.payload) if math.isfinite(mtow)
                else float("nan"), T0=T0, TW=T0 / W, masses=masses, s_curve=s_curve, V_LDmax=math.sqrt(
                    2 * W / (rho * S) * math.sqrt(K / CD0)), LD_max=0.5 / math.sqrt(K * CD0))

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

from aerosim.model.aircraft import (Aircraft, Ballast, Fuselage, LandingGear, MassModel, Payload, PointMass,
                                    PropulsionUnit, SloshTank)
from aerosim.model.catalog import Catalog, builtin_catalog

from .fields import F
from .spec import G0, DesignRules, Requirements, stall_speed
from .tail import SetCandidate, analyze as analyze_set, second_wing

LAYOUTS = ("tratora no nariz", "dois motores na asa", "propulsora atrás da asa", "livre: nariz + asa + atrás")
THRUST = ("motor + hélice", "conjunto de tração")
GEARS = ("triciclo", "convencional")
K_MUNK = 0.9          # k2 − k1 de um corpo alongado (fineza ~ 6 a 8)


@dataclass
class PowerParams:
    name: str = F("avião 1", "nome", "", "nome do avião que vai para a Montagem")
    set: str = F("conjunto 1", "conjunto", "", "um dos conjuntos guardados na etapa Empenagem")
    layout: str = F("tratora no nariz", "motores", "", "livre: soma os motores do nariz, da asa e de trás (ex.: "
                    "trimotor = 1 + 2 + 0; puxa-empurra = 1 + 0 + 1)", choices=LAYOUTS)
    thrust_model: str = F("motor + hélice", "tração por", "", "motor + hélice do catálogo ou um conjunto de tração "
                          "(polinômio, aba Tração)", choices=THRUST)
    motor: str = F("Scorpion A-5025-310Kv", "motor")
    propeller: str = F("APC 15x8E", "hélice")
    battery: str = F("LiPo 6S 5000", "bateria", "", "uma por motor")
    thrust_set: str = F("", "conjunto de tração")
    tilt: float = F(0.0, "inclinação do motor", "°", "+ eixo apontando para cima: parte da tração sustenta na corrida",
                    -10, 15, 0.5)
    motor_y: float = F(0.0, "afastamento dos motores", "m", "motores na asa: do centro ao eixo do primeiro par; 0 = o "
                       "mínimo para a hélice livrar a fuselagem", 0, 1.5, 0.01)
    wing_motors: int = F(2, "motores na asa", "", "arranjo na asa e livre: aos pares, espalhados na envergadura (uma "
                         "hélice + 5 cm de folga entre eles). No arranjo na asa, no mínimo 2", 0, 8, 2)
    nose_motors: int = F(1, "motores no nariz", "", "arranjo livre: tratora no nariz (0 ou 1)", 0, 1, 1)
    rear_motors: int = F(0, "motores atrás", "", "arranjo livre: propulsora atrás da asa (0 ou 1)", 0, 1, 1)
    lapes: bool = F(True, "tem LAPES", "", "carga lançada pela baia, no CG. Só diz se tem: os kg se decidem na "
                    "Montagem (o Desempenho varre a massa total)")
    n_lapes: int = F(1, "quantas cargas LAPES", "", "na mesma baia; a massa (o total) se define na Montagem", 1, 6, 1)
    liquid: bool = F(True, "tem carga líquida", "", "água em tanque(s) no CG — mexe na curva (sloshing). Os litros se "
                     "decidem na Montagem")
    n_tanks: int = F(1, "quantos tanques", "", "lado a lado no CG", 1, 4, 1)
    gear: str = F("triciclo", "trem", "", "triciclo: bequilha no nariz; convencional: bequilha na cauda", choices=GEARS)
    x_tdp: float = F(0.0, "x_TDP: trem principal ao CG", "m", "distância do CG de projeto ao trem principal: atrás "
                     "dele no triciclo, à frente no convencional. 0 = a regra (triciclo) ou 10 cm (convencional)",
                     0.0, 0.6, 0.005)
    x_payload: float = F(0.0, "x da carga paga ao CG", "m", "onde fica a carga paga (LAPES, líquido), medida do CG de "
                         "projeto (+ = à frente). 0 = no CG; fora dele a bateria equilibra junto, e o CG anda quando a "
                         "carga sai. O otimizador escolhe", -0.5, 0.5, 0.005)
    x_tdn: float = F(0.0, "x_TDN: bequilha à frente do CG", "m", "triciclo: distância do CG de projeto à bequilha "
                     "(+ = à frente). 0 = automático (10 cm atrás do nariz)", 0.0, 1.5, 0.005)
    gear_h: float = F(0.0, "altura do trem", "m", "do eixo do corpo ao chão no trem principal. 0 = a mínima para a "
                      "hélice livrar o chão parada; maior desce todas as rodas juntas (a atitude parada não muda)",
                      0.0, 1.0, 0.005)
    ground_pitch: float = F(0.0, "atitude no chão", "°", "triciclo: a bequilha mais comprida deixa o avião parado com o "
                            "nariz para cima, e a asa corre nesse ângulo. Com sustentação bastante ele sai do chão sem "
                            "rodar (asa voadora). 0 = nivelado", 0.0, 15.0, 0.5)


@dataclass
class AircraftCandidate:
    params: PowerParams = field(default_factory=PowerParams)
    set: SetCandidate = field(default_factory=SetCandidate)
    note: str = ""

    @property
    def name(self) -> str:
        return self.params.name


def motor_counts(pp: PowerParams) -> tuple[int, int, int]:
    """(motores no nariz, pares na asa, motores atrás) do arranjo; o livre sem nenhum motor fica com o do nariz"""
    if pp.layout == LAYOUTS[0]:
        return 1, 0, 0
    if pp.layout == LAYOUTS[1]:
        return 0, max(int(pp.wing_motors) // 2, 1), 0
    if pp.layout == LAYOUTS[2]:
        return 0, 0, 1
    n = (min(max(int(pp.nose_motors), 0), 1), max(int(pp.wing_motors), 0) // 2, min(max(int(pp.rear_motors), 0), 1))
    return n if any(n) else (1, 0, 0)


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
    ac.booms = copy.deepcopy(part.booms)
    ac.modifiers += [copy.deepcopy(m) for m in part.modifiers if m.kind == "comando.momento_flape"]   # Empenagem
    ac.Sref = ac.cref = ac.bref = None
    ac.tanks = []
    ac.payload.enabled = False
    from aerosim.model.mission import short_circuit
    ac.mission = short_circuit(Vc=req.V_cruise, VL=0.92 * req.V_cruise, Vap=0.88 * req.V_cruise)   # missão curta
    if not pp.lapes:
        ac.mission.events = [e for e in ac.mission.events if e.kind != "drop"]
    ac.environment.set_density_altitude(req.density_altitude)
    ac.performance.alpha_cruise = cand.set.wing.params.alpha_cruise
    ac.airfield.x_warning = req.takeoff_run
    ac.airfield.z_warning = req.obstacle_h
    w = ac.surfaces[0]
    cr = w.sections[0].chord
    S, c, b = info["S"], info["c"], info["b"]
    D = 0.381
    # ---- fuselagem (pod) e motores
    fw, fh = rules.fuselage_width, rules.fuselage_height
    n_nose, n_pairs, n_rear = motor_counts(pp)
    x_nose = rules.nose_length if n_nose else 0.6 * rules.nose_length
    length = x_nose + cr + 0.05
    tandem = cand.set.wing2 is not None and cand.set.params.layout == "sem cauda"
    if tandem:
        # tandem: o CG fica entre as asas, atrás do bordo de fuga da da frente; o pod vai até lá, com o CG na
        # metade dele (dali para trás o pod afina e a carga já não cabe)
        length = max(length, (x_nose - st["x_cg"]) / 0.5)
    units = []
    if n_nose:
        units.append(_unit(pp, cat, "motor 1", x_nose, 0.0, 0.0, 1))
    if n_pairs:
        D0 = _unit(pp, cat, "m", 0, 0, 0, 1).propeller.D
        y = pp.motor_y if pp.motor_y > 0 else max(D0 / 2 + fw / 2 + 0.05, 0.15)
        if n_nose and pp.motor_y <= 0:          # com hélice no nariz, o primeiro par livra o disco dela
            y = max(y, D0 + 0.05)
        xm = 0.15 + 0.02
        wing = []
        for k in range(n_pairs):                                    # pares, de dentro para fora
            yk = y + k * (D0 + 0.05)
            wing += [_unit(pp, cat, f"motor esq {k + 1}", xm, -yk, w.z, 1),
                     _unit(pp, cat, f"motor dir {k + 1}", xm, yk, w.z, -1)]
        if len(wing) == 2:
            wing[0].name, wing[1].name = "motor esq", "motor dir"
        units += wing
    w2 = second_wing(ac) if tandem else None
    if n_rear:                     # com tratora no nariz, gira ao contrário dela: os torques se cancelam
        # no tandem a propulsora vai no bordo de fuga da asa de trás, na ponta do tubo (o arranjo dos tandem de
        # verdade); atrás da da frente ela giraria no meio do tubo, entre as asas
        xr, zr = (w2.x - w2.sections[0].chord - 0.06, w2.z) if w2 is not None else (-cr - 0.06, 0.0)
        units.append(_unit(pp, cat, "motor atrás" if units else "motor 1", xr, 0.0, zr, -1 if n_nose else 1))
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
        pf_mass.append(("tubo de cauda", ac.boom.length * rules.boom_density, ac.boom.middle[0], ac.boom.middle[2]))
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
    # carga paga: aqui só se diz se tem LAPES e líquido (e quantos). As contas da sprint usam a massa de projeto
    # (Condições: massa estimada); a diferença para o PV é a CP estimada, no CG (soltar ou gastar não mexe no
    # equilíbrio). Os kg de cada coisa (lastro, LAPES, líquido) se decidem na Montagem.
    m_bat = sum(u.battery.mass for u in units)
    m_pv = m_s + sum(i.mass for i in items) + m_bat
    m_cp = max(req.mass - m_pv, 0.0)
    M = m_pv + m_cp
    lo, hi = x_nose - length + 0.08, x_nose - 0.12
    x_cp = min(max(x_t + pp.x_payload, lo), hi) if pp.x_payload else x_t     # a carga paga: o otimizador escolhe onde
    Mx = m_s * xs + sum(i.mass * i.x for i in items) + m_cp * x_cp
    x_bat = (M * x_t - Mx) / m_bat if m_bat > 0 else x_t
    x_bat_c = min(max(x_bat, lo), hi)
    items.append(PointMass("bateria", m_bat, x_bat_c, 0.0, 0.02))
    Mx += m_bat * x_bat_c
    m_eq = 0.0
    balanced = abs(x_bat_c - x_bat) < 1e-6
    if not balanced:                          # a bateria não alcança: lastro de equilíbrio (não é carga paga)
        xb = x_nose - 0.04 if x_bat > x_bat_c else (ac.boom.x_end + 0.05 if ac.boom.enabled else lo)
        mb = (M * x_t - Mx) / (xb - x_t)
        if mb > 0:
            # no tandem o tubo sobe até a asa de trás: o lastro fica nele, não no eixo da fuselagem
            zb = (ac.boom.z - (ac.boom.x_start - xb) * math.tan(math.radians(ac.boom.pitch))
                  if tandem and ac.boom.enabled and x_bat <= x_bat_c else 0.0)
            items.append(PointMass("lastro de equilíbrio", float(mb), float(xb), 0.0, float(zb)))
            m_eq = float(mb)
            M += mb
            Mx += mb * xb
    ac.ballast = Ballast(enabled=False, mass=0.0, x=x_t, y=0.0, z=0.0)         # no CG; os kg, na Montagem
    if pp.liquid:
        side, n = 0.12, max(int(pp.n_tanks), 1)
        ys = [(k - (n - 1) / 2) * (side + 0.01) for k in range(n)]
        ac.tanks = [SloshTank(f"tanque {k + 1}" if n > 1 else "tanque", x_cp, y, 0.03, side=side, volume=0.0, height=0.08)
                    for k, y in enumerate(ys)]
    if pp.lapes:
        ac.payload = Payload(enabled=True, mass=0.0, count=max(int(pp.n_lapes), 1), x=x_cp, y=0.0, z=0.06)
    ac.mass = MassModel(base_mass=m_s, base_cg=[xs, 0.0, zs], Ixx=I[0], Iyy=I[1], Izz=I[2], Ixz=0.0, items=items,
                        include_propulsion=False, include_structure=False)
    z_cg = (m_s * zs + sum(i.mass * i.z for i in items)) / max(m_s + sum(i.mass for i in items), 1e-9)
    ac.design_cg = [float(x_t), 0.0, float(z_cg)]        # CG de projeto: as dimensões se medem dele
    # ---- trem
    gz = (D / 2 + rules.prop_clearance) if not n_pairs else max(D / 2 + rules.prop_clearance + w.z, 0.12)
    if n_pairs and (n_nose or n_rear):                  # a hélice do centro também tem que livrar o chão
        gz = max(gz, D / 2 + rules.prop_clearance)
    dz = max(pp.gear_h - gz, 0.0)                      # trem mais alto que o mínimo: todas as rodas descem juntas
    gz += dz
    x_tdp = pp.x_tdp if pp.x_tdp > 0 else rules.main_gear_aft          # medidas do CG de projeto
    if pp.gear == GEARS[0]:
        x_nw = x_t + pp.x_tdn if pp.x_tdn > 0 else x_nose - 0.10
        z_nw = gz if pp.ground_pitch <= 0 else gz + (x_nw - (x_t - x_tdp)) * math.tan(math.radians(pp.ground_pitch))
        ac.gear = LandingGear("tricycle", main_x=x_t - x_tdp, main_track=rules.track, main_z=gz,
                              steer_x=x_nw, steer_z=z_nw,
                              tail_skid=ac.boom.enabled,
                              skid_x=ac.boom.x_end if ac.boom.enabled else -1.0,
                              skid_z=ac.boom.end[2] if ac.boom.enabled else 0.0, mu_roll=req.mu_roll)   # na ponta do tubo
    else:
        ac.gear = LandingGear("conventional", main_x=x_t + (pp.x_tdp if pp.x_tdp > 0 else 0.10), main_track=rules.track,
                              main_z=gz,
                              steer_x=ac.boom.x_end if ac.boom.enabled else x_t - 0.6,
                              steer_z=(ac.boom.end[2] if ac.boom.enabled else 0.0) + 0.05 + dz, steer_k=1500,
                              steer_c=40, tail_skid=False, mu_roll=req.mu_roll)
    # ---- decolagem e piloto (o piloto ainda se calibra sozinho antes de voar)
    Vs = stall_speed(req, S, wr["CLmax"], M)
    ac.takeoff.VR = round(1.15 * Vs, 2)
    ac.takeoff.sR = 0.0
    ac.autopilot.CL0 = float(wr["CL0"] + wr["CLa"] * math.radians(wr["incidence"]))
    ac.autopilot.CLa = float(wr["CLa"])
    ac.apply_constraints()
    trim = thrust_trim(ac, st, wr, req, rules, x_t, info, M, cand.set.params)
    xs_all = [x_nose] + [u.x for u in units] + [s_.x - s_.sections[0].chord for s_ in ac.surfaces]
    total_len = max(xs_all) - min(xs_all + ([ac.boom.x_end] if ac.boom.enabled else []))
    what = ", ".join(x for x, on in (("LAPES", pp.lapes), ("líquido", pp.liquid)) if on) or "lastro"
    table = [("PV", n, m, x) for n, m, x, _ in pf_mass] + [("PV", i.name, i.mass, i.x) for i in items] + \
        ([("CP", f"estimada = massa de projeto − PV ({what}: os kg na Montagem)", m_cp, x_cp)] if m_cp > 0 else [])
    x_e = (Mx - m_cp * x_cp) / max(M - m_cp, 1e-9)               # o CG sem a carga paga (soltura, consumo)
    sm_empty = 100 * (h_n - (info["x_le_mac"] - x_e) / c)
    out = dict(set=st, x_cg_target=x_t, h_n=h_n, sm=100 * (h_n - h_t), mass=M, empty=M - m_cp, payload=m_cp,
               mass_table=table, x_bat=x_bat, x_bat_used=x_bat_c, battery_fits=balanced, ballast=m_eq,
               x_payload=x_cp, payload_moved=abs(x_cp - x_t) > 1e-6, sm_empty=sm_empty,
               length=total_len, structure=m_s, masses=pf_mass, items=items, Vs=Vs, D=D,
               boom_hits_prop=bool(n_rear) and ac.boom.enabled and w2 is None, trim=trim)
    return ac, out


def _thrust_moment(units, T_each, px, pz) -> float:
    """momento de arfagem (+ cabra) da tração em torno do ponto (px, pz): eixo inclinado e fora do ponto"""
    M = 0.0
    for u in units:
        t = math.radians(u.tilt)
        Fx, Fz = T_each * math.cos(t), -T_each * math.sin(t)
        M += (u.z - pz) * Fx - (u.x - px) * Fz
    return M


def ground_pitch(ac) -> float:
    """a atitude no chão (°) do triciclo montado: da altura da bequilha e do trem principal (0 nivelado)"""
    g = ac.gear
    if g.layout != "tricycle" or g.steer_x == g.main_x:
        return 0.0
    return math.degrees(math.atan((g.steer_z - g.main_z) / (g.steer_x - g.main_x)))


def trimmed_clmax(ac, de_up: float, de_down: float, backend=None) -> tuple[float, float]:
    """(o maior C_L trimado, o maior C_m com o comando em algum ponto do curso), pelo núcleo. Numa asa voadora o
    elevon que trima também tira sustentação, e é este C_L, não o C_L,max da asa, que a sustenta devagar. Em cada α
    (0 a 20°) o comando anda de 2 em 2° pelo curso (de −de_up a +de_down, graus), e o δ de trimagem fica entre os
    dois vizinhos em que C_m troca de sinal (com o curso todo a faixa estola, então os extremos não servem para
    interpolar). −inf: não trima em α nenhum"""
    from aerosim.model.universal import build_model
    be = backend or _core()
    des = np.radians(np.arange(-de_up, de_down + 1e-9, 2.0))
    cl_trim, cm_up = -math.inf, -math.inf
    with be.session_for(build_model(ac)) as s:
        for a in np.radians(np.arange(0.0, 22.0, 2.0)):
            ks = [s.aero_coeffs(10.0, float(a), de=float(d)) for d in des]
            cm_up = max(cm_up, max(k["Cm"] for k in ks))
            for lo, hi in zip(ks, ks[1:]):
                if (lo["Cm"] >= 0) != (hi["Cm"] >= 0):
                    f = lo["Cm"] / (lo["Cm"] - hi["Cm"])
                    cl_trim = max(cl_trim, lo["CL"] + f * (hi["CL"] - lo["CL"]))
    return float(cl_trim), float(cm_up)


def thrust_trim(ac, st, wr, req, rules, x_t, info, mass, tp) -> dict:
    """a EH trimada para o voo COM o momento da tração (motor inclinado ou fora do CG) e o trim de decolagem:
    quanto o profundor fica picando na corrida para o avião não sair do chão antes da hora — dentro do curso
    de picar (cursos assimétricos). Vira `takeoff.de0` do avião montado."""
    from aerosim.model.massprops import dry_mass
    from aerosim.model.universal import build_model
    us = [u for u in ac.propulsion if u.enabled]
    if not us:
        return {}
    S, c = info["S"], info["c"]
    rho = req.rho
    W = mass * G0
    z_cg = float(dry_mass(ac)["cg"][2])
    # ---- voo: no cruzeiro a tração = arrasto
    q = req.q()
    K = 1 / (math.pi * wr["AR"] * min(max(wr["e"], 0.5), 1.0))
    CL = W / (q * S)
    Tc = q * S * (build_model(ac).parasite_cd() + K * CL * CL)
    Cm_T = _thrust_moment(us, Tc / len(us), x_t, z_cg) / (q * S * c)
    dih = 0.0
    if tp.layout != "sem cauda" and st.get("a_h"):
        dih = Cm_T / (tp.tail_eta * st["VH"] * st["a_h"])
        for s_ in ac.surfaces[1:]:
            if s_.role == "htail":
                s_.incidence += math.degrees(dih) * math.cos(math.radians(s_.dihedral))
    out = dict(Cm_T=Cm_T, T_cruise=Tc, dih=math.degrees(dih), hold=0.0, hold_ok=True, rot_ok=True)
    tail = st.get("tail_cm_mg")
    if tail is None or ac.gear.layout != "tricycle":
        return out
    # ---- corrida: momentos no trem principal (+ cabra), com a tração do motor inclinado
    x_mg, gz = ac.gear.main_x, ac.gear.main_z
    CLg = st["CL_ground"]
    th = math.radians(ground_pitch(ac))
    arm_w = x_t - x_mg                                      # braço do peso no trem principal
    if th > 0:                                              # atitude no chão: a asa corre no ângulo, e o CG, mais
        CLg += wr["CLa"] * th                               # alto que a roda, chega para trás dela
        arm_w = arm_w * math.cos(th) - (gz - z_cg) * math.sin(th)
        out["tip_ok"] = arm_w > 0
    # o peso que a bequilha leva parado: o braço do CG sobre a distância entre as rodas. Com pouco peso nela o avião
    # senta para trás no 6GDL ao primeiro empurrão (tandem com o trem a 3 cm do CG: 5 % na bequilha, sentou no tubo).
    # Raymer pede de 8 a 15 % na bequilha ("Aircraft Design: A Conceptual Approach", §11.2, a conferir no PDF); a E&C
    # com os comandos confere (`aeroopt.stages.violation`)
    base = (ac.gear.steer_x - x_mg) * math.cos(th)
    out["nose_load"] = arm_w / base if base > 1e-6 else 0.0
    CLmax = wr["CLmax"]
    if tp.layout == "sem cauda" and any(m.kind == "comando.momento_flape" for m in ac.modifiers):
        # asa voadora com o núcleo nos comandos: quem sustenta devagar é o C_L trimado (o elevon tira sustentação)
        out["CL_trim_max"], out["Cm_up_max"] = trimmed_clmax(ac, rules.de_max, rules.de_down)
        CLmax = min(CLmax, out["CL_trim_max"]) if out["CL_trim_max"] > 0 else CLmax
    Vlof = 1.1 * stall_speed(req, S, CLmax, mass)
    Vs_ = np.linspace(0.5, 1.6 * Vlof, 64)
    Tv = thrust_of(ac, Vs_, rho, None) / len(us)

    def nose_up(i, de):
        qq = 0.5 * rho * Vs_[i] ** 2
        aero = qq * S * c * (wr["Cm_ac"] + CLg * (info["x_ac_w"] - x_mg) / c + tail(CLg, de, x_mg, dih))
        return aero + _thrust_moment(us, Tv[i], x_mg, gz) - W * arm_w
    early = [i for i in range(len(Vs_)) if Vs_[i] <= 0.95 * Vlof]
    lifts = lambda de: any(nose_up(i, de) > 0 for i in early)
    if lifts(0.0):
        lo, hi = 0.0, math.radians(rules.de_down)
        if lifts(hi):
            out.update(hold=rules.de_down, hold_ok=False)
        else:
            for _ in range(30):
                mid = 0.5 * (lo + hi)
                lo, hi = (mid, hi) if lifts(mid) else (lo, mid)
            out["hold"] = math.degrees(hi)
        ac.takeoff.de0 = round(out["hold"], 2)
    up = [Vs_[i] for i in range(len(Vs_)) if nose_up(i, -math.radians(rules.de_max)) > 0]
    out["V_rot"] = float(up[0]) if up else float("inf")      # com a tração e o profundor todo cabrando
    aero_u = lambda de: wr["Cm_ac"] + CLg * (info["x_ac_w"] - x_mg) / c + tail(CLg, de, x_mg, dih)
    Vgrid = np.linspace(0.5, 40.0, 160)
    Tgrid = thrust_of(ac, Vgrid, rho, None) / len(us)
    Mth = np.array([_thrust_moment(us, t, x_mg, gz) for t in Tgrid])
    cm_full = aero_u(-math.radians(rules.de_max))

    rot_a = 0.5 * rho * Vgrid ** 2 * S * c * cm_full + Mth     # momento cabrando, sem o do peso
    rot_arm = arm_w

    def rot_speed(m: float) -> float:
        """V a partir da qual o profundor todo roda o avião com massa m (a corrida rápida espera por ela)"""
        f = rot_a - m * G0 * rot_arm
        k = np.nonzero(f > 0)[0]
        return float(Vgrid[k[0]]) if len(k) else float("inf")
    out["rot_speed"] = rot_speed
    out["rot_table"] = (Vgrid, rot_a, rot_arm)               # a mesma conta, para a corrida no núcleo
    if th > 0:                                               # sai do chão sem rodar quando a asa no ângulo sustenta
        out["ground_stall"] = CLg * 1.21 / wr["CLmax"] - 1   # > 0: corre mais perto do estol que 1,1 V_S
        if "CL_trim_max" in out:
            # sem cauda: só sai do chão nessa atitude o C_L que o comando ainda trima. Acima dele o avião não se
            # segura no ângulo e pica de volta para a bequilha (o tandem com C_L 1,7 no chão e 0,77 trimado
            # corria a 15 m/s nariz para baixo no 6GDL, e a sprint achava que ele saía do chão sozinho)
            CLg = min(CLg, max(out["CL_trim_max"], 0.0))
        out["CL_ground"] = CLg
        out["V_rot"] = min(out["V_rot"], math.sqrt(2 * W / (rho * S * CLg)) if CLg > 0 else math.inf)
    out["V_lof"] = Vlof
    out["rot_ok"] = out["V_rot"] <= Vlof
    return out


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
    """tração total com acelerador cheio: a simulação do núcleo, se houver `backend`; senão o equilíbrio motor +
    hélice em regime (core/src/sizing/motorprop.zig)"""
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
            tot += _core().motor_prop_thrust(motor_prop_spec(u), V, rho)     # a bisseção é do núcleo
    return tot


def motor_prop_spec(u: PropulsionUnit) -> dict:
    """o motor, a bateria e a hélice de uma unidade no formato de `ISimBackend.motor_prop_thrust`"""
    m, p, bt = u.motor, u.propeller, u.battery
    return dict(Kv=m.Kv, Rm=m.Rm, B=m.B, tauc=m.tauc, Imax=m.Imax, Voc=bt.Voc, Rint=bt.Rint, D=p.D,
                J=list(p.J), CT=list(p.CT), CP=list(p.CP))


_CORE = None


def _core():
    """o núcleo para a corrida quando quem chama não passou um (um por processo, carregado uma vez)"""
    global _CORE
    if _CORE is None:
        from aerosim.backend.zig import ZigBackend
        _CORE = ZigBackend()
    return _CORE


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
    us = [u for u in ac.propulsion if u.enabled]
    tl = math.radians(sum(u.tilt for u in us) / len(us)) if us else 0.0       # motor inclinado
    q = 0.5 * rho * V * V
    CL = W / (q * S)
    CDt = trim_drag(asm, CL, CD0 + K * CL * CL)
    Dg = q * S * (CD0 + K * CL * CL + CDt)
    RC = (T * math.cos(tl) - Dg) * V / W
    ok = T * math.cos(tl) >= Dg
    Vmax = float(V[ok][-1]) if ok.any() else float("nan")
    i = int(np.argmax(RC))
    CLg = wr["CL0"] + wr["CLa"] * math.radians(wr["incidence"])
    lift_off = 0
    if "CL_ground" in (asm.get("trim") or {}):              # atitude no chão: corre no ângulo e sai sem rodar
        CLg, lift_off = asm["trim"]["CL_ground"], 1
    CLmax = wr["CLmax"]
    if (asm.get("trim") or {}).get("CL_trim_max", 0.0) > 0:   # asa voadora: sai do chão no C_L trimado
        CLmax = min(CLmax, asm["trim"]["CL_trim_max"])
    T0 = float(thrust_of(ac, np.array([0.0]), rho, backend)[0])
    Vg = np.r_[0.0, V]
    Tgv = np.r_[T0, T]

    # a corrida no chão é do núcleo (core/src/sizing/ground.zig): a mesma conta de antes, bit a bit
    core = backend if hasattr(backend, "ground_runs") else _core()
    rt = (asm.get("trim") or {}).get("rot_table")
    g = core.ground_run(dict(rho=rho, S=S, CLg=CLg, CD0=CD0, K=K, CLmax=CLmax, mu=req.mu_roll,
                             sin_tl=math.sin(tl), cos_tl=math.cos(tl), V=Vg, T=Tgv,
                             rot_V=rt[0] if rt else [], rot_a=rt[1] if rt else [], rot_arm=rt[2] if rt else 0.0,
                             rot_on=1 if rt else 0, lift_off=lift_off))
    s_to = float(core.ground_runs(g, [M])[0])
    lo, hi = max(asm["empty"], 0.1), max(4 * M, 1.0)
    mtow = core.ground_mtow(g, lo, hi, req.takeoff_run)
    masses = np.linspace(max(asm["empty"], 0.5), max(2.2 * M, mtow if math.isfinite(mtow) else 0) * 1.05, 25)
    s_curve = core.ground_runs(g, masses)
    jc = int(np.argmin(np.abs(V - req.V_cruise)))
    return dict(CD_trim_cruise=float(CDt[jc]), V=V, T=T, D=Dg, RC=RC, P_req=Dg * V, P_av=T * V, Vs=Vs, Vmax=Vmax, RC_max=float(RC[i]), V_y=float(V[i]),
                CD0=CD0, K=K, s_to=s_to, mtow_runway=mtow, payload_runway=mtow - asm["empty"] if math.isfinite(mtow)
                else float("nan"), T0=T0, TW=T0 / W, masses=masses, s_curve=s_curve, V_LDmax=math.sqrt(
                    2 * W / (rho * S) * math.sqrt(K / CD0)), LD_max=0.5 / math.sqrt(K * CD0))


def trim_drag(asm: dict, CL, CD_no_trim) -> np.ndarray:
    """arrasto induzido da EH para equilibrar (estabilidade → desempenho): a EH carrega o que falta de C_m —
    C_m,ac da asa, braço do C_L até o CG e o momento da tração (motor inclinado / fora do CG, que cresce com
    a tração = arrasto)
        C_L,h = (C_m,ac + C_L (h_CG − h_ca) + C_m,T) / (η V_H)      C_D,trim = (S_h/S) C_L,h² / (π e_h AR_h)"""
    st = asm["set"]
    CL = np.asarray(CL, float)
    if "a_h" not in st:
        return np.zeros_like(CL)
    tr = asm.get("trim") or {}
    wr = st["wing"]
    tp_eta = st.get("eta", 0.9)
    info = st["info"]
    Sh_S = st["VH"] * info["c"] / info["arm"]
    t = st["set"].surfaces[1]
    AR_h = max(t.aspect_ratio, 1.0)
    CDc = float(np.interp(wr["CL_cruise"], CL[::-1], np.asarray(CD_no_trim, float)[::-1])) if len(CL) > 1 else 0.03
    CmT = tr.get("Cm_T", 0.0) * np.asarray(CD_no_trim, float) / max(CDc, 1e-6)
    CLh = (wr["Cm_ac"] + CL * (st["h_cg"] - st["h_ac"]) + CmT) / (tp_eta * st["VH"])
    return Sh_S * CLh * CLh / (math.pi * 0.8 * AR_h)


def design_point(cand: AircraftCandidate, req: Requirements, rules: DesignRules | None = None,
                 catalog: Catalog | None = None, airfoils: dict | None = None, backend=None, iters: int = 10,
                 tol: float = 0.02) -> dict:
    """ponto de projeto ACOPLADO (retroalimentação entre as áreas, não em ordem):
        massa de projeto m → asa calada para o cruzeiro com m, EH retrimada com a tração, CG pela bateria,
        carga paga estimada = m − PV (no CG) → desempenho → MTOW → m ← MTOW ... até convergir.
    No ponto convergido o avião é dimensionado para voar com a massa que a pista deixa levar, e a
    estabilidade (trim, rotação, trim de decolagem) é verificada nessa massa."""
    rules = rules or DesignRules()
    m = req.mass
    hist = []
    out = None

    def at(m):
        rq = copy.deepcopy(req)
        rq.mass = m
        c = copy.deepcopy(cand)
        ac, asm = assemble(c, rq, rules, catalog, airfoils)    # a massa de projeto é m (o que passa do PV é a CP)
        pf = performance(ac, asm, rq, backend)
        hist.append((m, pf["mtow_runway"]))
        return pf["mtow_runway"], asm["empty"], dict(ac=ac, asm=asm, pf=pf, cand=c, req=rq)

    for _ in range(iters):
        mt, fixed, out = at(m)
        if not math.isfinite(mt):
            break
        if abs(mt - m) < tol:
            break
        m = max(0.5 * (m + mt), fixed)
    # quando o MTOW cresce quase tanto quanto a massa de projeto (tandem, asa voadora: o C_L trimado e a pista
    # mudam com ela), a média anda devagar e as voltas acabam antes. Daí em diante, secante em g(m) = MTOW(m) − m
    # pelas duas últimas voltas. Quem já convergia não chega aqui e fica igual
    if len(hist) >= 2 and math.isfinite(hist[-1][1]) and abs(hist[-1][1] - hist[-1][0]) >= tol:
        for _ in range(iters):
            (m0, t0), (m1, t1) = hist[-2], hist[-1]
            g0, g1 = t0 - m0, t1 - m1
            if g1 == g0:
                break
            m = max(m1 - g1 * (m1 - m0) / (g1 - g0), fixed)
            mt, fixed, out = at(m)
            if not math.isfinite(mt) or abs(mt - m) < tol:
                break
    out.update(history=hist, mass=hist[-1][0], mtow=hist[-1][1],
               converged=len(hist) > 1 and math.isfinite(hist[-1][1]) and abs(hist[-1][1] - hist[-1][0]) < tol)
    return out

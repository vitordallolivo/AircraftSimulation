"""Aeronaves prontas para começar.

    conventional()   monomotor triciclo, asa + EH + EV (a aeronave do código original)
    flying_wing()    asa voadora enflechada com elevons, hélice propulsora, winglets
    twin_boom()      bimotor, trem convencional (bequilha na cauda), tubo de cauda e cauda em V
    empty()          nada: a Montagem começa vazia e o avião aparece no 3D peça por peça
"""
from __future__ import annotations

import math

from .aircraft import (Aircraft, Autopilot, ControlSurface, Fuselage, LandingGear, LiftingSurface, MassModel,
                       Payload, PointMass, PropulsionUnit, SloshTank, TailBoom, Takeoff, WingSection, rect_sections)
from .airfoil import Airfoil
from .catalog import builtin_catalog
from .mission import circuit, short_circuit


def _unit(name, x, y, z, tilt=3.0, sense=1, prop="APC 15x8E", motor="Scorpion A-5025-310Kv",
          bat="LiPo 6S 5000", **kw) -> PropulsionUnit:
    cat = builtin_catalog()
    return PropulsionUnit(name=name, x=x, y=y, z=z, tilt=tilt, sense=sense, motor=cat.motor(motor),
                          propeller=cat.propeller(prop), battery=cat.battery(bat), **kw)


def conventional() -> Aircraft:
    """monomotor convencional (números do código original)"""
    wing = LiftingSurface(
        name="asa", role="wing", x=0.135, z=-0.12, sections=rect_sections(1.25, 0.40), dihedral=3.0, incidence=2.0,
        airfoil=Airfoil("NACA 2412", cl_alpha=5.9, cl_max=1.78, cd0=0.012),
        controls=[ControlSurface("aileron", 0.6, 1.0, 0.25, tau=0.5)], oswald=0.85,
        CL0=0.30, CLmax=1.6, CD0=0.012, Cmac=-0.08)
    ch, bh = math.sqrt(0.2 / 4.0), math.sqrt(0.2 * 4.0)
    htail = LiftingSurface(
        name="EH", role="htail", x=-1.05 + 0.25 * ch, z=-0.05, sections=rect_sections(bh / 2, ch), incidence=-2.0,
        airfoil=Airfoil("NACA 0012", cl_alpha=5.9, cl_max=1.1, cd0=0.012),
        controls=[ControlSurface("elevator", 0.0, 1.0, 0.35, tau=0.5)], oswald=0.8, eta=0.9, downwash=True,
        CL0=0.0, CLmax=1.0, Cmac=0.0)
    cv, bv = math.sqrt(0.12 / 1.6), math.sqrt(0.12 * 1.6)
    vtail = LiftingSurface(
        name="EV", role="vtail", x=-1.10 + 0.25 * cv, z=-0.22 + bv / 2, sections=rect_sections(bv, cv),
        airfoil=Airfoil("NACA 0012", cl_alpha=5.9, cl_max=1.1, cd0=0.012), symmetric=False, vertical=True,
        controls=[ControlSurface("rudder", 0.0, 1.0, 0.35, tau=0.5)], oswald=0.8, eta=0.9,
        CL0=0.0, CLmax=1.0, Cmac=0.0)
    ac = Aircraft(
        name="Convencional (original)",
        surfaces=[wing, htail, vtail],
        fuselage=Fuselage(x_nose=0.62, length=1.30, width=0.16, height=0.18, z=0.0, aero_point=[0.0, 0.0, 0.0]),
        propulsion=[_unit("motor 1", 0.55, 0.0, 0.0)],
        gear=LandingGear("tricycle"),
        tanks=[SloshTank("tanque 1", 0.10, 0.0, 0.05, side=0.08 * math.sqrt(math.pi), volume=2.0, height=0.12)],
        payload=Payload(enabled=True),
        mass=MassModel(),
        takeoff=Takeoff(VR=12.5, sR=37.5, de1=-3.0),
        autopilot=Autopilot(CL0=0.398, CLa=4.747),
        mission=circuit(),
    )
    ac.Sref, ac.cref, ac.bref = 1.0, 0.40, 2.5
    return ac


def _np_x(wing: LiftingSurface) -> float:
    """ponto neutro aproximado de uma asa sozinha: x do quarto de corda médio das faixas (por área)"""
    from .universal import _surface
    sm = _surface(wing, 0, (0.0, 0.0))
    num = den = 0.0
    for a, b, _ in sm.strips():
        S = 0.5 * (a.chord + b.chord) * (b.s - a.s)
        cm = S / (b.s - a.s)
        num += S * (0.5 * (a.le[0] + b.le[0]) - 0.25 * cm)
        den += S
    return num / den


def flying_wing() -> Aircraft:
    wing = LiftingSurface(
        name="asa", role="wing", x=0.25, z=-0.02,
        sections=[WingSection(0.0, 0.45, 0.0, 0.0), WingSection(0.35, 0.36, 0.14, -1.0), WingSection(1.0, 0.22, 0.42, -4.0)],
        dihedral=1.0, incidence=2.0,
        airfoil=Airfoil("NACA 2410", cl_alpha=6.0, cl_max=1.3, cd0=0.011, cm_ac=-0.01),
        controls=[ControlSurface("elevon", 0.30, 0.97, 0.30)], oswald=0.9, mass=0.0)
    fin = dict(role="vtail", sections=[WingSection(0.0, 0.24, 0.0), WingSection(0.26, 0.14, 0.12)],
               airfoil=Airfoil("NACA 0010", cl_alpha=5.9, cl_max=1.0, cd0=0.012), symmetric=False, vertical=True,
               oswald=0.8, eta=1.0, CL0=0.0, Cmac=0.0)
    xt = 0.25 - 0.42
    fins = [LiftingSurface(name="winglet dir", x=xt, y=1.0, z=-0.02 - 0.01, **fin),
            LiftingSurface(name="winglet esq", x=xt, y=-1.0, z=-0.02 - 0.01, **fin)]
    ac = Aircraft(
        name="Asa voadora",
        surfaces=[wing] + fins,
        fuselage=Fuselage(x_nose=0.45, length=0.75, width=0.14, height=0.12, z=0.0, CDS=0.012, Cma=0.02,
                          Cnb=-0.004, CYb=-0.05),
        propulsion=[_unit("motor 1", -0.32, 0.0, 0.0, tilt=0.0, prop="APC 15x8E", motor="Genérico 500Kv",
                          bat="LiPo 4S 4000")],
        gear=LandingGear("tricycle", main_x=-0.02, main_track=0.40, main_z=0.14, steer_x=0.35, steer_z=0.14,
                         tail_skid=True, skid_x=-0.30, skid_z=0.02),
        tanks=[],
        payload=Payload(enabled=False),
        mass=MassModel(base_mass=3.0, Ixx=0.25, Iyy=0.12, Izz=0.35, Ixz=0.0),
        takeoff=Takeoff(VR=11.0, sR=0.0, de0=0.0, de1=-6.0, ht=2.0),
        autopilot=Autopilot(alpha_max=9.0, Kae=3.0, KIa=3.0, Kqe=0.15, phimax=30.0, Kbeta=0.0),
        mission=circuit(Vc=14.0, VL=13.0, Vap=12.5, hL=8.0),
    )
    ac.mission.events = [e for e in ac.mission.events if e.kind != "drop"]
    xnp = _np_x(wing)
    mac = wing.mac
    ac.mass.base_cg = [xnp + 0.12 * mac, 0.0, 0.0]     # margem estática ~12 %
    return ac


def twin_boom() -> Aircraft:
    wing = LiftingSurface(
        name="asa", role="wing", x=0.16, z=-0.10, sections=rect_sections(1.4, 0.36, taper=0.7, sweep=0.03),
        dihedral=4.0, incidence=2.0, airfoil=Airfoil("NACA 4412", cl_alpha=6.0, cl_max=1.6, cd0=0.012),
        controls=[ControlSurface("aileron", 0.55, 0.95, 0.25), ControlSurface("flap", 0.12, 0.5, 0.25, deflection=0.0)],
        oswald=0.85)
    vt = LiftingSurface(
        name="cauda em V", role="htail", x=-1.0, z=-0.06, sections=rect_sections(0.42, 0.20, taper=0.8),
        dihedral=35.0, incidence=-1.5, airfoil=Airfoil("NACA 0012", cl_alpha=5.9, cl_max=1.1, cd0=0.012),
        controls=[ControlSurface("ruddervator", 0.0, 1.0, 0.35)], oswald=0.8, eta=0.9, downwash=True,
        CL0=0.0, Cmac=0.0, mount="tubo:0")
    ac = Aircraft(
        name="Bimotor, convencional, tubo + cauda em V",
        surfaces=[wing, vt],
        fuselage=Fuselage(x_nose=0.55, length=0.85, width=0.16, height=0.17, z=0.0),
        booms=[TailBoom(x_start=-0.25, length=0.95, diameter=0.03, z=-0.04)],
        propulsion=[_unit("motor esq", 0.30, -0.55, -0.06, tilt=2.0, sense=1, prop="Genérica 13x6.5",
                          motor="Genérico 500Kv", bat="LiPo 4S 4000"),
                    _unit("motor dir", 0.30, 0.55, -0.06, tilt=2.0, sense=-1, prop="Genérica 13x6.5",
                          motor="Genérico 500Kv", bat="LiPo 4S 4000")],
        gear=LandingGear("conventional", main_x=0.18, main_track=0.55, main_z=0.24, steer_x=-1.15, steer_z=0.05,
                         steer_k=1500, steer_c=40, tail_skid=False),
        tanks=[SloshTank("tanque dir", 0.10, 0.25, 0.0, side=0.10, volume=0.5, height=0.08),
               SloshTank("tanque esq", 0.10, -0.25, 0.0, side=0.10, volume=0.5, height=0.08)],
        payload=Payload(enabled=False),
        mass=MassModel(base_mass=6.0, base_cg=[0.05, 0.0, 0.0], Ixx=0.9, Iyy=0.8, Izz=1.6, Ixz=0.0,
                       items=[PointMass("eletrônica", 0.3, 0.35, 0.0, 0.0)]),
        takeoff=Takeoff(VR=12.0, sR=0.0, de0=6.0, de1=-6.0, ht=2.0),
        mission=circuit(Vc=15.0, VL=14.0, Vap=13.5, hL=8.0),
    )
    ac.mission.events = [e for e in ac.mission.events if e.kind != "drop"]
    ac.apply_constraints()
    return ac


SAE_RUNWAY = 6.0      # pista de decolagem do padrão (m): SAE AeroDesign


def empty() -> Aircraft:
    """a Montagem sem nada: sem asa, sem fuselagem, sem trem; vai montando peça por peça"""
    ac = Aircraft(name="novo avião", fuselage=Fuselage(enabled=False), payload=Payload(enabled=False),
                  gear=LandingGear("custom"), mass=MassModel(base_mass=0.0, Ixx=0.0, Iyy=0.0, Izz=0.0, Ixz=0.0,
                                                             include_propulsion=True, include_structure=True))
    ac.mission = short_circuit()                     # missão curta, decolagem em 6 m (padrão SAE)
    ac.mission.events = [e for e in ac.mission.events if e.kind != "drop"]
    ac.airfield.x_warning = SAE_RUNWAY
    return ac


EMPTY_MSG = "o avião ainda está vazio: na Montagem, adicione uma asa (+ Asa) e um motor (+ Motor)"


def is_empty(ac: Aircraft) -> bool:
    """sem superfície e sem motor: nada para analisar ainda"""
    return not any(s.enabled for s in ac.surfaces) and not any(u.enabled for u in ac.propulsion)


def not_ready(ac: Aircraft) -> str | None:
    """o que falta para dar para analisar o avião (None: nada falta)"""
    from .massprops import dry_mass
    if is_empty(ac):
        return EMPTY_MSG
    if dry_mass(ac)["m"] <= 0:
        return ("o avião ainda não tem massa: dê massa às peças (campo massa de cada uma) ou em "
                "'Massa e inércia' (massa base)")
    return None


TEMPLATES = {"conventional": conventional, "flying_wing": flying_wing, "twin_boom": twin_boom}

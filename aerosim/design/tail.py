"""Etapa Empenagem e comandos: as superfícies que acompanham a asa escolhida, o tubo de cauda e os comandos.

Dimensionamento por volume de cauda (o braço é do centro aerodinâmico da asa ao da cauda):

    S_h = V_H S c̄ / l        S_v = V_V S b / l

Cauda em V: a mesma área total S_h + S_v, diedro atan √(S_v / S_h). Sem cauda: elevons na asa.

A análise rápida é a estática longitudinal clássica (Etkin; Nelson, cap. 2):

    h_n = h_ac + η V_H (a_h / a) (1 − dε/dα),   dε/dα = 2 a / (π AR)
    C_m = C_m,ac + C_L (h − h_ac) − η V_H' a_h (α_h + τ δe),   α_h = α_w − ε + i_h

com o CG posto na margem estática pedida. A incidência da EH sai para equilibrar o cruzeiro com o
profundor neutro. Faixa de CG: atrás, margem mínima; à frente, o profundor deixa de equilibrar o
C_L,max. Rolagem: p b/2V com o aileron todo (faixas, C_lp de asa trapezoidal).
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.aircraft import Aircraft, ControlSurface, LiftingSurface, TailBoom, WingSection
from aerosim.model.airfoil import Airfoil, flap_effectiveness, helmbold

from .fields import F
from .spec import DesignRules, Requirements
from .wing import WingCandidate, analyze as analyze_wing, planform

LAYOUTS = ("convencional", "em V", "sem cauda")


@dataclass
class TailParams:
    name: str = F("conjunto 1", "nome")
    wing: str = F("asa 1", "asa", "", "uma das asas guardadas na etapa Asa")
    layout: str = F("convencional", "cauda", "", "convencional: EH + EV; em V: duas superfícies inclinadas; "
                    "sem cauda: elevons na asa", choices=LAYOUTS)
    arm: float = F(0.95, "braço da cauda", "m", "do centro aerodinâmico da asa ao da cauda", 0.2, 3.0, 0.01)
    VH: float = F(0.45, "volume de cauda horizontal V_H", "", "0,35 a 0,6 é o usual", 0.1, 1.2, 0.01)
    VV: float = F(0.04, "volume de cauda vertical V_V", "", "0,02 a 0,05 é o usual", 0.005, 0.15, 0.002)
    AR_h: float = F(4.0, "alongamento da EH", "", "", 1.0, 10, 0.1)
    AR_v: float = F(1.6, "alongamento da EV", "", "altura² / área", 0.5, 5, 0.1)
    taper_h: float = F(1.0, "afilamento da EH", "", "", 0.3, 1.0, 0.05)
    taper_v: float = F(0.7, "afilamento da EV", "", "", 0.3, 1.0, 0.05)
    tail_airfoil: str = F("NACA 0012", "perfil da cauda", "", "NACA de 4 dígitos ou um da etapa Perfil")
    elevator: float = F(0.35, "profundor (fração da corda)", "", "", 0.1, 0.6, 0.01)
    rudder: float = F(0.35, "leme (fração da corda)", "", "", 0.1, 0.6, 0.01)
    aileron_start: float = F(0.55, "aileron: início", "", "fração da semienvergadura", 0.0, 0.95, 0.01)
    aileron_end: float = F(0.95, "aileron: fim", "", "", 0.1, 1.0, 0.01)
    aileron_chord: float = F(0.25, "aileron (fração da corda)", "", "", 0.1, 0.5, 0.01)
    sm_target: float = F(12.0, "margem estática desejada", "% CMA", "põe o CG aqui (a etapa Motores arruma as massas)",
                         2, 40, 0.5)
    sm_min: float = F(5.0, "margem estática mínima", "% CMA", "limite traseiro do CG", 0, 20, 0.5)
    tail_eta: float = F(0.9, "η da cauda", "", "pressão dinâmica na cauda / a do voo livre", 0.5, 1.0, 0.01)
    boom_diameter: float = F(0.025, "diâmetro do tubo", "m", "", 0.005, 0.1, 0.001)


@dataclass
class SetCandidate:
    """um conjunto guardado: a asa (cópia) + a empenagem e os comandos"""
    params: TailParams = field(default_factory=TailParams)
    wing: WingCandidate = field(default_factory=WingCandidate)
    note: str = ""

    @property
    def name(self) -> str:
        return self.params.name


def _surface(name, role, b_or_h, area, taper, af, vertical=False, symmetric=True, dihedral=0.0) -> LiftingSurface:
    """trapézio com a linha de 1/4 da corda reta (bordo de ataque da raiz em x = 0)"""
    span = b_or_h
    s = span / 2 if symmetric and not vertical else span
    cr = area / ((1 + taper) * s) if symmetric and not vertical else 2 * area / ((1 + taper) * s)
    ct = cr * taper
    return LiftingSurface(name=name, role=role, sections=[WingSection(0.0, cr, 0.0, 0.0),
                                                          WingSection(s, ct, (cr - ct) / 4, 0.0)],
                          airfoil=copy.deepcopy(af), vertical=vertical, symmetric=symmetric, dihedral=dihedral,
                          oswald=0.8, eta=0.9, downwash=not vertical, CL0=0.0, Cmac=0.0)


def tail_airfoil(name: str, known: dict | None = None) -> Airfoil:
    if known and name in known:
        return copy.deepcopy(known[name])
    digits = "".join(ch for ch in name if ch.isdigit())
    return Airfoil(f"NACA {digits if len(digits) == 4 else '0012'}", cl_alpha=5.9, cl_max=1.1, cd0=0.012)


def build_set(cand: SetCandidate, req: Requirements, rules: DesignRules | None = None, wing_res: dict | None = None,
              airfoils: dict | None = None) -> tuple[Aircraft, dict]:
    """o conjunto como um avião parcial (asa + cauda + tubo, sem motor nem fuselagem) e os números do
    dimensionamento: áreas, envergaduras, braço, posições"""
    rules = rules or DesignRules()
    tp = cand.params
    wr = wing_res or analyze_wing(cand.wing, req, rules)
    w = copy.deepcopy(wr["surface"])
    w.z = rules.wing_z
    pf = planform(w)
    S, c, b = pf["S"], pf["mac"], pf["b"]
    a0, a1 = tp.aileron_start, max(tp.aileron_end, tp.aileron_start + 0.05)
    kind = "elevon" if tp.layout == "sem cauda" else "aileron"
    w.controls = [ControlSurface(kind, a0, min(a1, 1.0), tp.aileron_chord)]
    af_t = tail_airfoil(tp.tail_airfoil, airfoils)
    ac = Aircraft(name=tp.name, surfaces=[w])
    ac.fuselage.enabled = False
    ac.gear.layout = "custom"
    ac.propulsion = []
    ac.tanks = []
    ac.payload.enabled = False
    info = dict(S=S, c=c, b=b, x_ac_w=pf["x_ac"], x_le_mac=pf["x_le_mac"], Sh=0.0, Sv=0.0, bh=0.0, hv=0.0, arm=0.0)
    if tp.layout == "sem cauda":
        return ac, info
    l = tp.arm
    Sh = tp.VH * S * c / l
    Sv = tp.VV * S * b / l
    x_ac_t = pf["x_ac"] - l
    if tp.layout == "convencional":
        bh = math.sqrt(tp.AR_h * Sh)
        eh = _surface("EH", "htail", bh, Sh, tp.taper_h, af_t)
        eh.controls = [ControlSurface("elevator", 0.0, 1.0, tp.elevator)]
        hv = math.sqrt(tp.AR_v * Sv)
        ev = _surface("EV", "vtail", hv, Sv, tp.taper_v, af_t, vertical=True, symmetric=False)
        ev.controls = [ControlSurface("rudder", 0.0, 1.0, tp.rudder)]
        tails = [eh, ev]
    else:
        St = Sh + Sv
        gam = math.degrees(math.atan(math.sqrt(Sv / Sh)))
        bv = math.sqrt(tp.AR_h * St)
        vt = _surface("cauda em V", "htail", bv, St, tp.taper_h, af_t, dihedral=gam)
        vt.controls = [ControlSurface("ruddervator", 0.0, 1.0, tp.elevator)]
        tails = [vt]
        bh, hv = bv, 0.0
        info["gamma"] = gam
    for t in tails:
        t.eta = tp.tail_eta
    main = tails[0]
    cr = main.sections[0].chord
    main.x = x_ac_t + cr / 4                    # c/4 reta: o CA fica a c_r/4 do bordo de ataque da raiz
    x_end = main.x - cr                          # o tubo acaba no bordo de fuga da cauda
    x_start = w.x - 0.25 * w.sections[0].chord
    ac.boom = TailBoom(enabled=True, x_start=x_start, length=max(x_start - x_end, 0.05), diameter=tp.boom_diameter,
                       z=0.0, attach_tail=True)
    ac.surfaces += tails
    ac.apply_constraints()
    info.update(Sh=Sh, Sv=Sv, bh=bh, hv=hv, arm=l, x_ac_t=x_ac_t,
                boom=ac.boom.length, mass_tail=(Sh + Sv) * rules.tail_density, mass_boom=ac.boom.length * rules.boom_density)
    return ac, info


def analyze(cand: SetCandidate, req: Requirements, rules: DesignRules | None = None, airfoils: dict | None = None) -> dict:
    """estática longitudinal do conjunto, faixa de CG, incidência da EH, rolagem e direcional"""
    rules = rules or DesignRules()
    tp = cand.params
    wr = analyze_wing(cand.wing, req, rules)
    ac, info = build_set(cand, req, rules, wr, airfoils)
    S, c, b = info["S"], info["c"], info["b"]
    a = wr["CLa"]
    AR = wr["AR"]
    h_ac = (info["x_le_mac"] - info["x_ac_w"]) / c
    deda = 2 * a / (math.pi * AR)
    out = dict(set=ac, info=info, wing=wr, deda=deda, h_ac=h_ac)
    w = ac.surfaces[0]
    # rolagem: C_lδa por faixas e C_lp de asa trapezoidal (sem cauda: o elevon faz as duas coisas)
    ctl = w.controls[0]
    tau_a = flap_effectiveness(ctl.chord_frac)
    s = w.semispan
    yy = np.linspace(ctl.span_start * s, min(ctl.span_end, 1.0) * s, 60)
    Clda = 2 * a * tau_a / (S * b) * np.trapezoid(np.array([w.chord_at(y) for y in yy]) * yy, yy)
    lam = w.sections[-1].chord / w.sections[0].chord
    Clp = -a / 12 * (1 + 3 * lam) / (1 + lam)
    pb2V = -Clda * math.radians(rules.da_max) / Clp
    out.update(Clda=Clda, Clp=Clp, pb2V=pb2V, tau_a=tau_a)
    CLmax = wr["CLmax"]
    CLc = wr["CL_cruise"]
    if tp.layout == "sem cauda":
        h_n = h_ac
        h_cg = h_n - tp.sm_target / 100
        # elevon: C_mδ ≈ −C_lδa · b/(2 y_m) · ... aqui: arfagem por faixa com o braço até o CA
        x_c = info["x_le_mac"] - h_cg * c
        Cmd = -a * tau_a / (S * c) * 2 * np.trapezoid(np.array([w.chord_at(y) * (x_c - (w.x - w.xoff_at(y) - 0.75 * w.chord_at(y)))
                                                                for y in yy]), yy)
        Cm0 = wr["Cm_ac"]
        de_cru = -(Cm0 + CLc * (h_cg - h_ac)) / Cmd
        de_max_cl = -(Cm0 + CLmax * (h_cg - h_ac)) / Cmd
        out.update(h_n=h_n, h_cg=h_cg, x_cg=x_c, x_np=info["x_le_mac"] - h_n * c, Cmde=Cmd, i_h=0.0,
                   de_cruise=math.degrees(de_cru), de_CLmax=math.degrees(de_max_cl), VH=0.0, VV=0.0, Cnb=float("nan"))
        out.update(_curves(out, wr, req, None))
        return out
    t = ac.surfaces[1]
    af = t.airfoil
    AR_t = t.aspect_ratio if not t.vertical else 2 * t.aspect_ratio
    a_h = helmbold(af.cl_alpha, max(AR_t, 0.5))
    if tp.layout == "em V":
        a_h *= math.cos(math.radians(info.get("gamma", 0.0))) ** 2
    eta = tp.tail_eta
    Sh = info["Sh"] if tp.layout == "convencional" else info["Sh"] + info["Sv"]
    VH_ac = info["Sh"] * info["arm"] / (S * c) if tp.layout == "convencional" else \
        Sh * math.cos(math.radians(info.get("gamma", 0.0))) ** 2 * info["arm"] / (S * c)
    h_n = h_ac + eta * VH_ac * (a_h / a) * (1 - deda)
    h_cg = h_n - tp.sm_target / 100
    x_cg = info["x_le_mac"] - h_cg * c
    tau_e = flap_effectiveness(tp.elevator)
    Cmde = -eta * VH_ac * a_h * tau_e
    # incidência da EH: C_m = 0 no cruzeiro com δe = 0
    eps = lambda CL: 2 * CL / (math.pi * AR)
    a_w = lambda CL: (CL - wr["CL0"]) / a
    def cm(CL, de, ih, h):
        ah = a_w(CL) - eps(CL) + ih
        return wr["Cm_ac"] + CL * (h - h_ac) - eta * VH_ac * a_h * (ah + tau_e * de)
    ih = (wr["Cm_ac"] + CLc * (h_cg - h_ac)) / (eta * VH_ac * a_h) - (a_w(CLc) - eps(CLc))
    de_for = lambda CL, h: -cm(CL, 0.0, ih, h) / Cmde
    de_cru = de_for(CLc, h_cg)
    de_CLmax = de_for(CLmax, h_cg)
    # CG mais à frente em que o profundor ainda equilibra o C_L,max (δe = −δmáx)
    dm = -math.radians(rules.de_max)
    # cm(CLmax, dm, ih, h) = 0 → linear em h
    c0 = cm(CLmax, dm, ih, 0.0)
    h_fwd = -c0 / CLmax
    h_aft = h_n - tp.sm_min / 100
    # direcional: C_nβ da EV
    if tp.layout == "convencional":
        ev = ac.surfaces[2]
        a_v = helmbold(ev.airfoil.cl_alpha, 1.55 * ev.aspect_ratio)
        VV = info["Sv"] * info["arm"] / (S * b)
    else:
        g = math.radians(info.get("gamma", 0.0))
        a_v = a_h / max(math.cos(g) ** 2, 1e-3) * math.sin(g) ** 2
        VV = Sh * math.sin(g) ** 2 * info["arm"] / (S * b)
    Cnb = eta * VV * a_v
    out.update(h_n=h_n, h_cg=h_cg, x_cg=x_cg, x_np=info["x_le_mac"] - h_n * c, a_h=a_h, VH=VH_ac, VV=VV, Cmde=Cmde,
               i_h=math.degrees(ih), de_cruise=math.degrees(de_cru), de_CLmax=math.degrees(de_CLmax),
               h_fwd=h_fwd, h_aft=h_aft, x_cg_fwd=info["x_le_mac"] - h_fwd * c, x_cg_aft=info["x_le_mac"] - h_aft * c,
               Cnb=Cnb, tau_e=tau_e)
    for su in ac.surfaces[1:]:
        if su.role == "htail":
            su.incidence = math.degrees(ih)
    out.update(_curves(out, wr, req, (cm, ih)))
    return out


def _curves(out, wr, req, cmfun) -> dict:
    """C_m × α (CG à frente, no alvo, atrás) e δe de equilíbrio × V"""
    al = np.asarray(wr["alpha"], float)
    CL = np.asarray(wr["CL"], float)
    res = {"alpha": al}
    hs = [("CG no alvo", out["h_cg"])]
    if "h_fwd" in out:
        hs = [("CG à frente (limite)", out["h_fwd"])] + hs + [("CG atrás (limite)", out["h_aft"])]
    Vs = wr["V_stall"]
    V = np.linspace(max(Vs, 1.0), 2.2 * max(Vs, 1.0), 40)
    CLV = req.weight / (0.5 * req.rho * V * V * out["info"]["S"])
    res["V"] = V
    for lab, h in hs:
        if cmfun is None:
            Cm = wr["Cm_ac"] + CL * (h - out["h_ac"])
            de = -(wr["Cm_ac"] + CLV * (h - out["h_ac"])) / out["Cmde"]
        else:
            cm, ih = cmfun
            Cm = np.array([cm(x, 0.0, ih, h) for x in CL])
            de = -np.array([cm(x, 0.0, ih, h) for x in CLV]) / out["Cmde"]
        res[f"Cm:{lab}"] = Cm
        res[f"de:{lab}"] = np.degrees(de)
    return dict(curves=res)

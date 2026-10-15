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

from . import airfoils as afm
from .fields import F
from .spec import DesignRules, Requirements
from .wing import WingCandidate, analyze as analyze_wing, planform

LAYOUTS = ("convencional", "em V", "sem cauda")
ARM_FROM = ("CA da asa", "CG de projeto")


@dataclass
class TailParams:
    name: str = F("conjunto 1", "nome")
    wing: str = F("asa 1", "asa", "", "uma das asas guardadas na etapa Asa")
    layout: str = F("convencional", "cauda", "", "convencional: EH + EV; em V: duas superfícies inclinadas; "
                    "sem cauda: elevons na asa", choices=LAYOUTS)
    arm: float = F(0.95, "braço da cauda", "m", "até o centro aerodinâmico da cauda, medido de onde diz 'braço medido "
                   "do'", 0.2, 3.0, 0.01)
    arm_from: str = F("CA da asa", "braço medido do", "", "CA da asa: do centro aerodinâmico da asa (clássico); CG de "
                      "projeto: do CG (como l_h na planilha antiga) — os volumes de cauda usam este braço",
                      choices=ARM_FROM)
    VH: float = F(0.45, "volume de cauda horizontal V_H", "", "0,35 a 0,6 é o usual", 0.1, 1.2, 0.01)
    VV: float = F(0.04, "volume de cauda vertical V_V", "", "0,02 a 0,05 é o usual", 0.005, 0.15, 0.002)
    AR_h: float = F(4.0, "alongamento da EH", "", "", 1.0, 10, 0.1)
    AR_v: float = F(1.6, "alongamento da EV", "", "altura² / área", 0.5, 5, 0.1)
    taper_h: float = F(1.0, "afilamento da EH", "", "", 0.3, 1.0, 0.05)
    taper_v: float = F(0.7, "afilamento da EV", "", "", 0.3, 1.0, 0.05)
    tail_airfoil: str = F("NACA 0012", "perfil da EH", "", "NACA de 4 dígitos ou um da etapa Perfil (arqueado também: "
                          "a incidência compensa)")
    tail_inverted: bool = F(False, "EH invertida", "", "perfil montado de cabeça para baixo: sustentação para baixo e "
                            "c_l negativo maior — momento cabrador para rodar na decolagem")
    vtail_airfoil: str = F("NACA 0012", "perfil da EV", "", "simétrico (arqueado empurra para o lado sem derrapar)")
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
    boom_pitch: float = F(0.0, "inclinação do tubo", "°", "+ ponta de trás para cima: a cauda sobe (sai da esteira da "
                          "asa) e o tubo livra o chão na rotação; o braço da cauda continua medido na horizontal",
                          -10, 20, 0.5)


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
                          oswald=0.8, eta=0.9, downwash=not vertical)


def tail_airfoil(name: str, known: dict | None = None, Re: float | None = None) -> Airfoil:
    """o perfil da cauda: um da etapa Perfil ou NACA de 4 dígitos, ajustado na polar dele no Re da cauda"""
    return tail_entry(name, known, Re)[0]


def tail_entry(name: str, known: dict | None = None, Re: float | None = None,
               inverted: bool = False) -> tuple[Airfoil, tuple[float, float]]:
    """(perfil ajustado, (c_l mín., c_l máx.) 2D da polar) — os dois lados importam na cauda: a EH trabalha com
    sustentação para baixo, e é o c_l negativo que limita o quanto ela consegue cabrar (perfil invertido ganha)"""
    k = known.get(name) if known else None
    if isinstance(k, Airfoil):
        k = afm.AirfoilEntry(copy.deepcopy(k), source="modelo")
    if k is None:
        digits = "".join(ch for ch in name if ch.isdigit())
        k = afm.entry(afm.from_naca(f"NACA {digits if len(digits) == 4 else '0012'}"))
    if inverted:                       # o mesmo perfil, montado de cabeça para baixo
        k = copy.deepcopy(k)
        k.airfoil.inverted = True
    try:
        p = afm.polar(k, Re or 2e5)
        if afm.metrics(p):
            cl = np.asarray(p["cl"], float)
            return afm.fitted(k.airfoil, p), (float(np.nanmin(cl)), float(np.nanmax(cl)))
    except Exception:
        pass
    af = copy.deepcopy(k.airfoil)
    return af, (-af.cl_max, af.cl_max)


def build_set(cand: SetCandidate, req: Requirements, rules: DesignRules | None = None, wing_res: dict | None = None,
              airfoils: dict | None = None, arm_shift: float = 0.0) -> tuple[Aircraft, dict]:
    """o conjunto como um avião parcial (asa + cauda + tubo, sem motor nem fuselagem) e os números do
    dimensionamento: áreas, envergaduras, braço, posições. As áreas saem do braço dado; a cauda fica a
    `braço + arm_shift` do CA da asa (`analyze` acha o shift quando o braço é medido do CG)"""
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
    ac = Aircraft(name=tp.name, surfaces=[w])
    ac.fuselage.enabled = False
    ac.gear.layout = "custom"
    ac.propulsion = []
    ac.tanks = []
    ac.payload.enabled = False
    info = dict(S=S, c=c, b=b, x_ac_w=pf["x_ac"], x_le_mac=pf["x_le_mac"], Sh=0.0, Sv=0.0, bh=0.0, hv=0.0, arm=0.0)
    if tp.layout == "sem cauda":
        return ac, info
    l = tp.arm + arm_shift                          # do CA da asa ao da cauda (posição)
    Sh = tp.VH * S * c / tp.arm                     # volume de cauda com o braço como foi dado
    Sv = tp.VV * S * b / tp.arm
    x_ac_t = pf["x_ac"] - l
    if tp.layout == "convencional":
        bh = math.sqrt(tp.AR_h * Sh)
        af_t, lim = tail_entry(tp.tail_airfoil, airfoils, req.reynolds(Sh / bh), tp.tail_inverted)
        eh = _surface("EH", "htail", bh, Sh, tp.taper_h, af_t)
        eh.controls = [ControlSurface("elevator", 0.0, 1.0, tp.elevator)]
        hv = math.sqrt(tp.AR_v * Sv)
        af_v = tail_airfoil(tp.vtail_airfoil, airfoils, req.reynolds(Sv / hv))
        ev = _surface("EV", "vtail", hv, Sv, tp.taper_v, af_v, vertical=True, symmetric=False)
        ev.controls = [ControlSurface("rudder", 0.0, 1.0, tp.rudder)]
        tails = [eh, ev]
    else:
        St = Sh + Sv
        gam = math.degrees(math.atan(math.sqrt(Sv / Sh)))
        bv = math.sqrt(tp.AR_h * St)
        af_t, lim = tail_entry(tp.tail_airfoil, airfoils, req.reynolds(St / bv), tp.tail_inverted)
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
    reach = max(x_start - x_end, 0.05)               # o braço é horizontal: inclinado, o tubo fica mais comprido
    ac.booms = [TailBoom(name="tubo de cauda", x_start=x_start, length=reach / math.cos(math.radians(tp.boom_pitch)),
                         diameter=tp.boom_diameter, pitch=tp.boom_pitch)]
    for t in tails:
        t.mount = "tubo:0"
    ac.surfaces += tails
    ac.apply_constraints()
    info.update(Sh=Sh, Sv=Sv, bh=bh, hv=hv, arm=l, x_ac_t=x_ac_t, cl_lim_h=lim,
                boom=ac.boom.length, mass_tail=(Sh + Sv) * rules.tail_density, mass_boom=ac.boom.length * rules.boom_density)
    return ac, info


def analyze(cand: SetCandidate, req: Requirements, rules: DesignRules | None = None, airfoils: dict | None = None) -> dict:
    """estática longitudinal do conjunto, faixa de CG, incidência da EH, rolagem e direcional. Com o braço
    medido do CG de projeto, a cauda é reposicionada até a distância do CG ao CA dela ser o braço dado (o CG
    depende da cauda: ponto fixo, converge em poucas voltas)"""
    rules = rules or DesignRules()
    wr = analyze_wing(cand.wing, req, rules)
    if cand.params.layout == "sem cauda" or cand.params.arm_from != ARM_FROM[1]:
        return _analyze(cand, req, rules, airfoils, wr, 0.0)
    shift = 0.0
    for _ in range(30):
        out = _analyze(cand, req, rules, airfoils, wr, shift)
        err = cand.params.arm - out["arm_cg"]
        if abs(err) < 1e-6:
            break
        shift += err
    return out


def _analyze(cand, req, rules, airfoils, wr, arm_shift) -> dict:
    tp = cand.params
    ac, info = build_set(cand, req, rules, wr, airfoils, arm_shift)
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
    da_eff = 0.5 * (rules.da_max + rules.da_down)         # diferencial: média dos dois lados
    pb2V = -Clda * math.radians(da_eff) / Clp
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
        tw = lambda CL, de, x_mg, dih=0.0: Cmd * (de + dih)
        out.update(rotation(wr, req, rules, x_c, info["x_ac_w"], c, S, tw))
        out["tail_cm_mg"] = tw
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
    # cauda em V: tudo no plano de arfagem — a_h já tem cos²γ (uma vez só); α_L0, incidência e comando são da
    # superfície (α_n = α cos γ + i): equivalem a α_L0/cos γ, i/cos γ e τ/cos γ em arfagem
    cg = math.cos(math.radians(info.get("gamma", 0.0))) if tp.layout == "em V" else 1.0
    VH_ac = Sh * info["arm"] / (S * c)
    h_n = h_ac + eta * VH_ac * (a_h / a) * (1 - deda)
    h_cg = h_n - tp.sm_target / 100
    x_cg = info["x_le_mac"] - h_cg * c
    tau_e = flap_effectiveness(tp.elevator) / cg
    Cmde = -eta * VH_ac * a_h * tau_e
    # incidência da EH: C_m = 0 no cruzeiro com δe = 0
    eps = lambda CL: 2 * CL / (math.pi * AR)
    a_w = lambda CL: (CL - wr["CL0"]) / a
    a0_t = math.radians(af.zero_lift_angle()) / cg     # perfil arqueado (ou invertido) na EH

    lo3, hi3 = (0.9 * cg * v for v in info["cl_lim_h"])   # C_L da cauda limitado pelo estol dela (os dois lados)

    def CLh(CL, de, ih):
        # profundor defletido aumenta o c_l máximo da seção (flape simples: Δc_l,max ≈ 0,9 com deflexão total,
        # ~45°; Raymer, cap. 12), do lado para onde ele defletiu
        dcl = 0.9 * 0.9 * cg * min(abs(math.degrees(de)) / 45.0, 1.0)
        lo, hi = (lo3 - dcl, hi3) if de < 0 else (lo3, hi3 + dcl)
        return min(max(a_h * (a_w(CL) - eps(CL) + ih - a0_t + tau_e * de), lo), hi)

    def cm(CL, de, ih, h):
        return wr["Cm_ac"] + CL * (h - h_ac) - eta * VH_ac * CLh(CL, de, ih)
    ih = (wr["Cm_ac"] + CLc * (h_cg - h_ac)) / (eta * VH_ac * a_h) - (a_w(CLc) - eps(CLc)) + a0_t
    de_for = lambda CL, h: -(wr["Cm_ac"] + CL * (h - h_ac) - eta * VH_ac * a_h * (a_w(CL) - eps(CL) + ih - a0_t)) / Cmde
    de_cru = de_for(CLc, h_cg)
    de_CLmax = de_for(CLmax, h_cg)
    CLh_need = (wr["Cm_ac"] + CLmax * (h_cg - h_ac)) / (eta * VH_ac)     # C_L da EH para equilibrar o C_L,max
    # CG mais à frente em que o profundor ainda equilibra o C_L,max (δe = −δmáx)
    dm = -math.radians(rules.de_max)
    # cm(CLmax, dm, ih, h) = 0 → linear em h
    c0 = cm(CLmax, dm, ih, 0.0)
    h_fwd = -c0 / CLmax
    # rotação na decolagem: a cauda (com o perfil dela, invertido ou não) no braço até o trem principal
    x_act = info["x_ac_t"]
    Sh_S = VH_ac * c / info["arm"]

    def tail_rot(CL, de, x_mg, dih=0.0):
        return eta * Sh_S * CLh(CL, de, ih + dih) * (x_act - x_mg) / c
    out.update(rotation(wr, req, rules, x_cg, info["x_ac_w"], c, S, tail_rot))
    out["tail_cm_mg"] = tail_rot           # a etapa Motores retrima a EH com o momento da tração
    h_aft = h_n - tp.sm_min / 100
    # direcional: C_nβ da EV
    if tp.layout == "convencional":
        ev = ac.surfaces[2]
        a_v = helmbold(ev.airfoil.cl_alpha, 1.55 * ev.aspect_ratio)
        VV = info["Sv"] * info["arm"] / (S * b)
    else:
        g = math.radians(info.get("gamma", 0.0))
        a_v = a_h / max(math.cos(g) ** 2, 1e-3)               # sem projeção: o sen²γ fica no volume
        VV = Sh * math.sin(g) ** 2 * info["arm"] / (S * b)
    Cnb = eta * VV * a_v
    out["arm_cg"] = x_cg - info["x_ac_t"]                  # do CG de projeto ao CA da cauda
    out.update(h_n=h_n, h_cg=h_cg, x_cg=x_cg, x_np=info["x_le_mac"] - h_n * c, a_h=a_h, VH=VH_ac, VV=VV, Cmde=Cmde,
               i_h=math.degrees(ih), de_cruise=math.degrees(de_cru), de_CLmax=math.degrees(de_CLmax),
               h_fwd=h_fwd, h_aft=h_aft, x_cg_fwd=info["x_le_mac"] - h_fwd * c, x_cg_aft=info["x_le_mac"] - h_aft * c,
               Cnb=Cnb, tau_e=tau_e, CLh_CLmax=CLh_need, CLh_lim=(lo3, hi3), eta=eta)
    for su in ac.surfaces[1:]:
        if su.role == "htail":
            su.incidence = math.degrees(ih) * cg
    out.update(_curves(out, wr, req, (cm, ih)))
    return out


def rotation(wr, req, rules, x_cg, x_ac_w, c, S, tail_term) -> dict:
    """velocidade a partir da qual o comando de arfagem roda o avião em torno do trem principal (corrida com a
    fuselagem nivelada; a asa no ângulo de incidência). Momentos cabradores no ponto de contato do trem:
        q S c [C_m,ac + C_L,asa (x_ca − x_tp)/c + cauda(δ)] ≥ W (x_CG − x_tp)
    A EH invertida (ou qualquer EH com sustentação para baixo) soma momento cabrador já com δe = 0."""
    x_mg = x_cg - rules.main_gear_aft
    CLg = wr["CL0"] + wr["CLa"] * math.radians(wr["incidence"])
    d = x_cg - x_mg
    out = {"x_mg": x_mg, "CL_ground": CLg}
    for key, de in (("V_rot", -math.radians(rules.de_max)), ("V_rot0", 0.0)):
        Cm = wr["Cm_ac"] + CLg * (x_ac_w - x_mg) / c + tail_term(CLg, de, x_mg)
        out[key] = math.sqrt(2 * req.weight * d / (req.rho * S * c * Cm)) if Cm > 0 else float("inf")
        out["Cm_mg" if de else "Cm_mg0"] = Cm
    out["V_lof"] = 1.1 * wr["V_stall"]
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

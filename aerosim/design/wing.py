"""Etapa Asa: do perfil escolhido à asa — forma em planta, linha sustentadora e o que ela entrega.

`WingParams` descreve a asa pelo que se decide na sprint (envergadura, área, afilamento, trecho
retangular, enflechamento, torção, diedro) e `build_wing` faz a superfície do modelo de sempre.
A análise rápida é a linha sustentadora de Prandtl (série de Glauert, simétrica) com o perfil
ajustado na etapa Perfil:

    Σ A_n sen(nθ) (sen θ + n μ) = μ (α + ε(y) − α_L0) sen θ,   μ = a1 c / (4 b)
    C_L = π AR A_1      C_Di = π AR Σ n A_n²      c_l(y) = (4 b / c) Σ A_n sen(nθ)

Perfil da ponta (`airfoil_tip`): a mesma asa com dois perfis. A raiz (e o trecho retangular) usa o perfil
da raiz; do fim do trecho retangular até a ponta as propriedades (a1, α_L0, c_l,max, c_d, c_m) são
interpoladas — a linha sustentadora usa a1(y) e α_L0(y), o estol o c_l,max local e o arrasto o c_d local.

C_L,max pela seção crítica (o primeiro ponto da envergadura que chega ao c_l,max do perfil diz também
ONDE o estol começa); arrasto de perfil integrando o c_d da polar 2D no c_l local. A incidência sai
do ângulo de cruzeiro: a asa é calada para a fuselagem voar no ângulo pedido.
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.aircraft import LiftingSurface, WingSection

from . import airfoils as afm
from .fields import F
from .spec import DesignRules, Requirements, cruise_CL, stall_speed


PLANFORMS = ("trapézio", "tabela de seções")
SIZE_BY = ("área", "corda")


@dataclass
class WingStation:
    """uma seção da asa na tabela (da raiz para a ponta); entre seções tudo é interpolado"""
    y: float = F(0.0, "y", "m", "distância da raiz ao longo da semienvergadura", 0.0, 6.0, 0.01)
    chord: float = F(0.3, "corda", "m", "", 0.01, 3.0, 0.005)
    airfoil: str = F("", "perfil", "", "vazio = o perfil da raiz")
    offset: float = F(0.0, "recuo do bordo de ataque", "m", "+ para trás, em relação ao da raiz", -2.0, 2.0, 0.005)
    twist: float = F(0.0, "torção", "°", "− = washout", -10.0, 10.0, 0.25)


@dataclass
class WingParams:
    name: str = F("asa 1", "nome")
    planform: str = F("trapézio", "planta", "", "trapézio: envergadura, área ou corda, afilamento e trecho "
                      "retangular; tabela de seções: uma linha por seção (y, corda, perfil, recuo, torção), quantas "
                      "quiser", choices=PLANFORMS)
    size_by: str = F("área", "dimensionar por", "", "área: digite a área e a corda sai dela; corda: digite a corda "
                     "da raiz e a área sai (trapézio)", choices=SIZE_BY)
    chord: float = F(0.35, "corda da raiz", "m", "vale com 'dimensionar por' = corda", 0.03, 3.0, 0.005)
    airfoil: str = F("NACA 2412", "perfil (raiz)", "", "um dos perfis da etapa Perfil")
    airfoil_tip: str = F("", "perfil da ponta", "", "vazio = o mesmo da raiz; outro perfil: a asa vai do perfil da "
                         "raiz (e do trecho retangular) ao da ponta, interpolando")
    span: float = F(2.4, "envergadura", "m", "de ponta a ponta", 0.3, 8.0, 0.02)
    area: float = F(0.85, "área", "m²", "área em planta (as duas semiasas)", 0.05, 5.0, 0.01)
    taper: float = F(0.6, "afilamento", "", "corda da ponta / corda da raiz (no trecho trapezoidal)", 0.2, 1.0, 0.02)
    rect_frac: float = F(0.4, "trecho retangular", "", "fração da semienvergadura com corda constante", 0.0, 1.0, 0.05)
    sweep: float = F(0.0, "enflechamento (c/4)", "°", "da linha de 1/4 da corda no trecho trapezoidal", -10, 45, 0.5)
    twist: float = F(-1.0, "torção na ponta", "°", "− = washout (a ponta estola depois)", -8, 4, 0.25)
    dihedral: float = F(2.0, "diedro", "°", "", -5, 15, 0.5)
    alpha_cruise: float = F(0.0, "ângulo de cruzeiro (fuselagem)", "°",
                            "a asa é calada para a fuselagem voar neste ângulo no cruzeiro", -4, 8, 0.25)
    stations: list[WingStation] = field(default_factory=list)   # planta "tabela de seções"

    def table(self) -> bool:
        return self.planform == PLANFORMS[1] and len(self.stations) >= 2


@dataclass
class WingCandidate:
    """uma asa guardada: os parâmetros e o perfil (com a polar escolhida) — fica igual mesmo se a lista de
    perfis mudar depois"""
    params: WingParams = field(default_factory=WingParams)
    airfoil: afm.AirfoilEntry = field(default_factory=afm.AirfoilEntry)
    note: str = ""
    airfoil_tip: afm.AirfoilEntry | None = None      # None: um perfil só
    section_airfoils: list[afm.AirfoilEntry] = field(default_factory=list)   # tabela de seções: os outros perfis

    @property
    def name(self) -> str:
        return self.params.name


# ------------------------------------------------------------------ geometria
def stations(p: WingParams) -> list[WingStation]:
    """as seções da tabela, da raiz para a ponta (a primeira vai para y = 0)"""
    st = sorted(p.stations, key=lambda q: q.y)
    if st and st[0].y != 0.0:
        st = copy.deepcopy(st)
        y0 = st[0].y
        for q in st:
            q.y -= y0
    return st


def chords(p: WingParams) -> tuple[float, float, float, float]:
    """(semienvergadura, y da quebra, corda da raiz, corda da ponta)"""
    if p.table():
        st = stations(p)
        return st[-1].y, 0.0, st[0].chord, st[-1].chord
    s = p.span / 2
    yb = min(max(p.rect_frac, 0.0), 1.0) * s
    lam = 1.0 if yb >= s else p.taper
    if p.size_by == SIZE_BY[1]:
        cr = p.chord
    else:
        cr = p.area / (2 * (yb + 0.5 * (1 + lam) * (s - yb)))
    return s, yb, cr, cr * lam


def sync(p: WingParams) -> WingParams:
    """acerta os campos que saem dos outros: área (por corda ou pela tabela), corda da raiz (por área) e
    envergadura (pela tabela) — quem lê `p.area` e `p.span` vê a asa de verdade"""
    if p.table():
        st = stations(p)
        p.span = round(2 * st[-1].y, 6)
        p.area = round(2 * sum(0.5 * (a.chord + b.chord) * (b.y - a.y) for a, b in zip(st, st[1:])), 6)
        p.chord = st[0].chord
        p.airfoil = st[0].airfoil or p.airfoil
        return p
    s, yb, cr, ct = chords(p)
    if p.size_by == SIZE_BY[1]:
        p.area = round(2 * (cr * yb + 0.5 * (cr + ct) * (s - yb)), 6)
    else:
        p.chord = round(cr, 6)
    return p


def stations_from_trapezoid(p: WingParams) -> list[WingStation]:
    """a tabela que reproduz o trapézio atual (ponto de partida para editar)"""
    s, yb, cr, ct = chords(p)
    xt = (cr - ct) / 4 + math.tan(math.radians(p.sweep)) * (s - yb)
    out = [WingStation(0.0, round(cr, 4), p.airfoil, 0.0, 0.0)]
    if 1e-6 < yb < s - 1e-6:
        out.append(WingStation(round(yb, 4), round(cr, 4), "", 0.0, round(p.twist * yb / s, 3)))
    out.append(WingStation(round(s, 4), round(ct, 4), p.airfoil_tip or "", round(xt, 4), p.twist))
    return out


def build_wing(p: WingParams, af, incidence: float = 0.0, af_tip=None, af_map: dict | None = None) -> LiftingSurface:
    """a asa no modelo de sempre, com o bordo de ataque da raiz em x = 0; `af_tip`: perfil da seção da ponta
    (a raiz e a quebra ficam com o da superfície). Tabela de seções: cada seção com o seu perfil (`af_map`:
    nome → perfil; vazio ou o da raiz = o da superfície)"""
    if p.table():
        st = stations(p)
        root = st[0].airfoil or p.airfoil
        secs = [WingSection(q.y, q.chord, q.offset, q.twist,
                            copy.deepcopy(af_map[q.airfoil]) if k > 0 and af_map and q.airfoil and q.airfoil != root
                            and q.airfoil in af_map else None) for k, q in enumerate(st)]
        return LiftingSurface(name="asa", role="wing", x=0.0, z=0.0, sections=secs, dihedral=p.dihedral,
                              incidence=incidence, airfoil=copy.deepcopy(af), controls=[], oswald=0.85)
    s, yb, cr, ct = chords(p)
    xt = (cr - ct) / 4 + math.tan(math.radians(p.sweep)) * (s - yb)
    secs = [WingSection(0.0, cr, 0.0, 0.0)]
    if 1e-6 < yb < s - 1e-6:
        secs.append(WingSection(yb, cr, 0.0, p.twist * yb / s))
    secs.append(WingSection(s, ct, xt, p.twist, copy.deepcopy(af_tip) if af_tip is not None else None))
    return LiftingSurface(name="asa", role="wing", x=0.0, z=0.0, sections=secs, dihedral=p.dihedral,
                          incidence=incidence, airfoil=copy.deepcopy(af), controls=[], oswald=0.85)


def planform(w: LiftingSurface) -> dict:
    """CMA, posição do bordo de ataque da CMA e centro aerodinâmico (eixos do corpo: x à frente)"""
    ys = np.linspace(0.0, w.semispan, 201)
    c = np.array([w.chord_at(y) for y in ys])
    xle = w.x - np.array([w.xoff_at(y) for y in ys])
    half = np.trapezoid(c, ys)
    mac = np.trapezoid(c * c, ys) / half
    x_le_mac = np.trapezoid(c * xle, ys) / half
    y_mac = np.trapezoid(c * ys, ys) / half
    return dict(mac=float(mac), x_le_mac=float(x_le_mac), y_mac=float(y_mac), x_ac=float(x_le_mac - 0.25 * mac),
                S=float(2 * half), b=float(2 * w.semispan), AR=float((2 * w.semispan) ** 2 / (2 * half)))


# ------------------------------------------------------------------ linha sustentadora
def tip_weight(w: LiftingSurface, y) -> np.ndarray:
    """peso do perfil da ponta em y (0 = perfil da superfície, 1 = da seção da ponta), linear entre seções"""
    ss = sorted(w.sections, key=lambda q: q.y)
    tip = ss[-1].airfoil
    ind = [1.0 if (tip is not None and q.airfoil is tip) else 0.0 for q in ss]
    return np.interp(np.asarray(y, float), [q.y for q in ss], ind)


def station_weights(w: LiftingSurface, y) -> tuple[list, np.ndarray]:
    """(perfil de cada seção, pesos k × y): interpolação linear entre seções vizinhas"""
    ss = sorted(w.sections, key=lambda q: q.y)
    ys = [q.y for q in ss]
    y = np.atleast_1d(np.asarray(y, float))
    W = np.array([np.interp(y, ys, np.eye(len(ss))[k]) for k in range(len(ss))])
    return [q.airfoil or w.airfoil for q in ss], W


def section_props(w: LiftingSurface, y) -> dict:
    """a1 (1/rad), α_L0 (rad), c_l,max e c_m do perfil local em y (raiz → ponta): cada seção com o seu
    perfil, interpolado entre seções"""
    afs, W = station_weights(w, y)
    mix = lambda f: np.array([f(a) for a in afs]) @ W
    shape = np.shape(y)
    out = dict(a1=mix(lambda a: a.cl_alpha), a0=np.radians(mix(lambda a: a.zero_lift_angle())),
               clmax=mix(lambda a: a.cl_max), cm=mix(lambda a: a.moment_ac()))
    out = {k: (v.reshape(shape) if shape else float(v[0])) for k, v in out.items()}
    out["w"] = tip_weight(w, y)
    return out


def lifting_line(w: LiftingSurface, n: int = 24) -> dict:
    """coeficientes lineares em α (α da corda da raiz, rad): A(α) = α A_α + A_t; c_l(y) = α g + h"""
    s = w.semispan
    b = 2 * s
    S = w.area
    AR = b * b / S
    lam_c4 = math.radians(_sweep_c4(w))
    th = (np.arange(1, n + 1)) * math.pi / (2 * n)           # 0 < θ ≤ π/2 (ponta → raiz)
    y = s * np.cos(th)
    sp = section_props(w, y)                                  # perfil local (dois perfis: interpolado)
    a1 = sp["a1"] * math.cos(lam_c4)
    c = np.array([w.chord_at(v) for v in y])
    eps = np.radians(np.array([w.twist_at(v) for v in y]))
    a0 = sp["a0"]
    mu = a1 * c / (4 * b)
    odd = 2 * np.arange(n) + 1
    M = np.sin(np.outer(th, odd)) * (np.sin(th)[:, None] + odd[None, :] * mu[:, None])
    rhs_a = mu * np.sin(th)
    rhs_t = mu * (eps - a0) * np.sin(th)
    Aa, At = np.linalg.solve(M, rhs_a), np.linalg.solve(M, rhs_t)
    sn = np.sin(np.outer(th, odd))
    g = 4 * b / c * (sn @ Aa)
    h = 4 * b / c * (sn @ At)
    return dict(y=y, c=c, g=g, h=h, Aa=Aa, At=At, odd=odd, AR=AR, S=S, b=b, a1=a1, clmax=sp["clmax"], w_tip=sp["w"],
                cm=sp["cm"])


def _sweep_c4(w: LiftingSurface) -> float:
    ss = sorted(w.sections, key=lambda q: q.y)
    a, z = ss[-2] if len(ss) > 1 else ss[0], ss[-1]
    dy = z.y - a.y
    if dy <= 0:
        return 0.0
    return math.degrees(math.atan(((z.x_offset + 0.25 * z.chord) - (a.x_offset + 0.25 * a.chord)) / dy))


def analyze(cand: WingCandidate, req: Requirements, rules: DesignRules | None = None) -> dict:
    """tudo o que a etapa Asa mostra: curvas, estol (quanto e onde), polar, L/D, cruzeiro e massa"""
    rules = rules or DesignRules()
    p = cand.params
    pf0 = planform(build_wing(p, cand.airfoil.airfoil))
    Re = req.reynolds(pf0["mac"])
    pol2d = afm.polar(cand.airfoil, Re)
    af = afm.fitted(cand.airfoil.airfoil, pol2d) if afm.metrics(pol2d) else cand.airfoil.airfoil
    af_t, pol_t, pols, af_map = None, None, None, None
    if p.table():                                             # cada seção com o seu perfil, no Re da sua corda
        st = stations(p)
        root = st[0].airfoil or p.airfoil
        entries = {e.name: e for e in cand.section_airfoils}
        fit = {}
        pols = []
        for k, q in enumerate(st):
            name = q.airfoil if k > 0 and q.airfoil and q.airfoil != root and q.airfoil in entries else None
            if name is None:
                pols.append(pol2d)
                continue
            pk = afm.polar(entries[name], req.reynolds(q.chord))
            pols.append(pk)
            if name not in fit:
                fit[name] = afm.fitted(entries[name].airfoil, pk) if afm.metrics(pk) else entries[name].airfoil
        af_map = fit
    elif cand.airfoil_tip is not None:                        # perfil da ponta, no Re da corda da ponta
        Re_t = req.reynolds(chords(p)[3])
        pol_t = afm.polar(cand.airfoil_tip, Re_t)
        af_t = afm.fitted(cand.airfoil_tip.airfoil, pol_t) if afm.metrics(pol_t) else cand.airfoil_tip.airfoil
    w = build_wing(p, af, af_tip=af_t, af_map=af_map)
    pf = planform(w)
    L = lifting_line(w)
    S, AR, odd = L["S"], L["AR"], L["odd"]
    clmax = L["clmax"]                                        # c_l,max local (dois perfis: interpolado)
    with np.errstate(divide="ignore", invalid="ignore"):
        a_st_i = np.where(L["g"] > 0, (clmax - L["h"]) / L["g"], np.inf)
    i_st = int(np.argmin(a_st_i))
    a_st = float(a_st_i[i_st])
    CL_of = lambda a: math.pi * AR * (a * L["Aa"][0] + L["At"][0])
    CLa = math.pi * AR * L["Aa"][0]
    CL0 = math.pi * AR * L["At"][0]
    alpha0_w = -CL0 / CLa
    CLmax = CL_of(a_st)
    alphas = np.radians(np.arange(math.floor(math.degrees(alpha0_w)) - 2, math.degrees(a_st) + 1e-9, 0.25))
    alphas = np.r_[alphas, a_st] if alphas[-1] < a_st - 1e-9 else alphas
    CL, CDi, CDp = [], [], []
    for a in alphas:
        A = a * L["Aa"] + L["At"]
        CL.append(math.pi * AR * A[0])
        CDi.append(math.pi * AR * float(np.sum(odd * A * A)))
        CDp.append(_profile_drag(w, L, a, pol2d, S, pol_t, pols))
    CL, CDi, CDp = np.array(CL), np.array(CDi), np.array(CDp)
    CD = CDi + CDp
    with np.errstate(divide="ignore", invalid="ignore"):
        LD = np.where(CD > 0, CL / CD, np.nan)
    CLc = cruise_CL(req, S)
    a_cru = (CLc - CL0) / CLa
    Ac = a_cru * L["Aa"] + L["At"]
    e = Ac[0] ** 2 / float(np.sum(odd * Ac * Ac)) if abs(Ac[0]) > 1e-12 else float("nan")
    CDc = math.pi * AR * float(np.sum(odd * Ac * Ac)) + _profile_drag(w, L, a_cru, pol2d, S, pol_t, pols)
    j = int(np.nanargmax(LD))
    Vs = stall_speed(req, S, CLmax)
    inc = math.degrees(a_cru) - p.alpha_cruise
    cl_cru = a_cru * L["g"] + L["h"]
    cl_st = a_st * L["g"] + L["h"]
    eta = L["y"] / w.semispan
    o = np.argsort(eta)
    return dict(
        surface=build_wing(p, af, incidence=inc, af_tip=af_t, af_map=af_map), airfoil=af, airfoil_tip=af_t, polar2d=pol2d,
        polar2d_tip=pol_t, Re=Re, planform=pf,
        alpha=np.degrees(alphas), CL=CL, CDi=CDi, CDp=CDp, CD=CD, LD=LD, CLa=CLa, CL0=CL0,
        alpha0=math.degrees(alpha0_w), CLmax=CLmax, alpha_stall=math.degrees(a_st),
        eta_stall=float(L["y"][i_st] / w.semispan), e=e, LD_max=float(LD[j]), CL_LD=float(CL[j]),
        CL_cruise=CLc, alpha_cruise_w=math.degrees(a_cru), CD_cruise=CDc, LD_cruise=CLc / CDc if CDc > 0 else np.nan,
        V_stall=Vs, incidence=inc, wing_loading=req.mass / S, mass=S * rules.wing_density,
        span_eta=eta[o], cl_cruise=cl_cru[o], cl_stall=cl_st[o], cl_max_local=np.asarray(clmax)[o],
        chord=L["c"][o], Re_root=req.reynolds(w.chord_at(0)), Re_tip=req.reynolds(w.chord_at(w.semispan)),
        AR=AR, S=S, b=L["b"], Cm_ac=float(np.trapezoid(L["cm"][o] * L["c"][o] ** 2, eta[o]) /
                                          np.trapezoid(L["c"][o] ** 2, eta[o])) if (af_t is not None or af_map) else af.moment_ac())


def _profile_drag(w, L, a, pol2d, S, pol_t=None, pols=None) -> float:
    """C_Dp = (2/S) ∫ c c_d(c_l local) dy — estações da raiz à ponta, a ponta com o c_d da última estação;
    com perfil da ponta, o c_d local interpola as duas polares; com `pols` (uma polar por seção da tabela),
    interpola entre as seções vizinhas"""
    cl = a * L["g"] + L["h"]
    if pols is not None:
        _, W = station_weights(w, L["y"])
        cd = sum(W[k] * afm.drag_at(pk, cl) for k, pk in enumerate(pols))
    else:
        cd = afm.drag_at(pol2d, cl)
    if pols is None and pol_t is not None:
        cd = cd + (afm.drag_at(pol_t, cl) - cd) * L["w_tip"]
    cd = cd[::-1]
    y, c = L["y"][::-1], L["c"][::-1]
    y, c, cd = np.r_[y, w.semispan], np.r_[c, w.chord_at(w.semispan)], np.r_[cd, cd[-1]]
    return float(2 * np.trapezoid(c * cd, y) / S)

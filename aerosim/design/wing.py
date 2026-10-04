"""Etapa Asa: do perfil escolhido à asa — forma em planta, linha sustentadora e o que ela entrega.

`WingParams` descreve a asa pelo que se decide na sprint (envergadura, área, afilamento, trecho
retangular, enflechamento, torção, diedro) e `build_wing` faz a superfície do modelo de sempre.
A análise rápida é a linha sustentadora de Prandtl (série de Glauert, simétrica) com o perfil
ajustado na etapa Perfil:

    Σ A_n sen(nθ) (sen θ + n μ) = μ (α + ε(y) − α_L0) sen θ,   μ = a1 c / (4 b)
    C_L = π AR A_1      C_Di = π AR Σ n A_n²      c_l(y) = (4 b / c) Σ A_n sen(nθ)

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


@dataclass
class WingParams:
    name: str = F("asa 1", "nome")
    airfoil: str = F("NACA 2412", "perfil", "", "um dos perfis da etapa Perfil")
    span: float = F(2.4, "envergadura", "m", "de ponta a ponta", 0.3, 8.0, 0.02)
    area: float = F(0.85, "área", "m²", "área em planta (as duas semiasas)", 0.05, 5.0, 0.01)
    taper: float = F(0.6, "afilamento", "", "corda da ponta / corda da raiz (no trecho trapezoidal)", 0.2, 1.0, 0.02)
    rect_frac: float = F(0.4, "trecho retangular", "", "fração da semienvergadura com corda constante", 0.0, 1.0, 0.05)
    sweep: float = F(0.0, "enflechamento (c/4)", "°", "da linha de 1/4 da corda no trecho trapezoidal", -10, 45, 0.5)
    twist: float = F(-1.0, "torção na ponta", "°", "− = washout (a ponta estola depois)", -8, 4, 0.25)
    dihedral: float = F(2.0, "diedro", "°", "", -5, 15, 0.5)
    alpha_cruise: float = F(0.0, "ângulo de cruzeiro (fuselagem)", "°",
                            "a asa é calada para a fuselagem voar neste ângulo no cruzeiro", -4, 8, 0.25)


@dataclass
class WingCandidate:
    """uma asa guardada: os parâmetros e o perfil (com a polar escolhida) — fica igual mesmo se a lista de
    perfis mudar depois"""
    params: WingParams = field(default_factory=WingParams)
    airfoil: afm.AirfoilEntry = field(default_factory=afm.AirfoilEntry)
    note: str = ""

    @property
    def name(self) -> str:
        return self.params.name


# ------------------------------------------------------------------ geometria
def chords(p: WingParams) -> tuple[float, float, float, float]:
    """(semienvergadura, y da quebra, corda da raiz, corda da ponta)"""
    s = p.span / 2
    yb = min(max(p.rect_frac, 0.0), 1.0) * s
    lam = 1.0 if yb >= s else p.taper
    cr = p.area / (2 * (yb + 0.5 * (1 + lam) * (s - yb)))
    return s, yb, cr, cr * lam


def build_wing(p: WingParams, af, incidence: float = 0.0) -> LiftingSurface:
    """a asa no modelo de sempre, com o bordo de ataque da raiz em x = 0"""
    s, yb, cr, ct = chords(p)
    xt = (cr - ct) / 4 + math.tan(math.radians(p.sweep)) * (s - yb)
    secs = [WingSection(0.0, cr, 0.0, 0.0)]
    if 1e-6 < yb < s - 1e-6:
        secs.append(WingSection(yb, cr, 0.0, p.twist * yb / s))
    secs.append(WingSection(s, ct, xt, p.twist))
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
def lifting_line(w: LiftingSurface, n: int = 24) -> dict:
    """coeficientes lineares em α (α da corda da raiz, rad): A(α) = α A_α + A_t; c_l(y) = α g + h"""
    s = w.semispan
    b = 2 * s
    S = w.area
    AR = b * b / S
    af = w.airfoil
    lam_c4 = math.radians(_sweep_c4(w))
    a1 = af.cl_alpha * math.cos(lam_c4)
    th = (np.arange(1, n + 1)) * math.pi / (2 * n)           # 0 < θ ≤ π/2 (ponta → raiz)
    y = s * np.cos(th)
    c = np.array([w.chord_at(v) for v in y])
    eps = np.radians(np.array([w.twist_at(v) for v in y]))
    a0 = math.radians(af.zero_lift_angle())
    mu = a1 * c / (4 * b)
    odd = 2 * np.arange(n) + 1
    M = np.sin(np.outer(th, odd)) * (np.sin(th)[:, None] + odd[None, :] * mu[:, None])
    rhs_a = mu * np.sin(th)
    rhs_t = mu * (eps - a0) * np.sin(th)
    Aa, At = np.linalg.solve(M, rhs_a), np.linalg.solve(M, rhs_t)
    sn = np.sin(np.outer(th, odd))
    g = 4 * b / c * (sn @ Aa)
    h = 4 * b / c * (sn @ At)
    return dict(y=y, c=c, g=g, h=h, Aa=Aa, At=At, odd=odd, AR=AR, S=S, b=b, a1=a1)


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
    w = build_wing(p, af)
    pf = planform(w)
    L = lifting_line(w)
    S, AR, odd = L["S"], L["AR"], L["odd"]
    clmax = af.cl_max
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
        CDp.append(_profile_drag(w, L, a, pol2d, S))
    CL, CDi, CDp = np.array(CL), np.array(CDi), np.array(CDp)
    CD = CDi + CDp
    with np.errstate(divide="ignore", invalid="ignore"):
        LD = np.where(CD > 0, CL / CD, np.nan)
    CLc = cruise_CL(req, S)
    a_cru = (CLc - CL0) / CLa
    Ac = a_cru * L["Aa"] + L["At"]
    e = Ac[0] ** 2 / float(np.sum(odd * Ac * Ac)) if abs(Ac[0]) > 1e-12 else float("nan")
    CDc = math.pi * AR * float(np.sum(odd * Ac * Ac)) + _profile_drag(w, L, a_cru, pol2d, S)
    j = int(np.nanargmax(LD))
    Vs = stall_speed(req, S, CLmax)
    inc = math.degrees(a_cru) - p.alpha_cruise
    cl_cru = a_cru * L["g"] + L["h"]
    cl_st = a_st * L["g"] + L["h"]
    eta = L["y"] / w.semispan
    o = np.argsort(eta)
    return dict(
        surface=build_wing(p, af, incidence=inc), airfoil=af, polar2d=pol2d, Re=Re, planform=pf,
        alpha=np.degrees(alphas), CL=CL, CDi=CDi, CDp=CDp, CD=CD, LD=LD, CLa=CLa, CL0=CL0,
        alpha0=math.degrees(alpha0_w), CLmax=CLmax, alpha_stall=math.degrees(a_st),
        eta_stall=float(L["y"][i_st] / w.semispan), e=e, LD_max=float(LD[j]), CL_LD=float(CL[j]),
        CL_cruise=CLc, alpha_cruise_w=math.degrees(a_cru), CD_cruise=CDc, LD_cruise=CLc / CDc if CDc > 0 else np.nan,
        V_stall=Vs, incidence=inc, wing_loading=req.mass / S, mass=S * rules.wing_density,
        span_eta=eta[o], cl_cruise=cl_cru[o], cl_stall=cl_st[o], cl_max_local=np.full(len(o), clmax),
        chord=L["c"][o], Re_root=req.reynolds(w.chord_at(0)), Re_tip=req.reynolds(w.chord_at(w.semispan)),
        AR=AR, S=S, b=L["b"], Cm_ac=af.moment_ac())


def _profile_drag(w, L, a, pol2d, S) -> float:
    """C_Dp = (2/S) ∫ c c_d(c_l local) dy — estações da raiz à ponta, a ponta com o c_d da última estação"""
    cd = afm.drag_at(pol2d, a * L["g"] + L["h"])[::-1]
    y, c = L["y"][::-1], L["c"][::-1]
    y, c, cd = np.r_[y, w.semispan], np.r_[c, w.chord_at(w.semispan)], np.r_[cd, cd[-1]]
    return float(2 * np.trapezoid(c * cd, y) / S)

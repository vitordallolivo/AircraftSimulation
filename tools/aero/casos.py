"""Perfis de teste da aerodinâmica: aviões simples, só superfícies (sem fuselagem e sem motor), para comparar os
coeficientes dos métodos numa velocidade típica (12 m/s).

Cada caso é uma função sem argumentos que devolve um `Aircraft` com a origem no 1/4 da CMA da asa (o ponto dos
momentos). A geometria é a de livro (retangular, trapezoidal, enflechada, diedro), sem número de fonte: o que se
compara são os métodos entre si e, depois, contra a asa do lltdrek que o dono vai mandar.

    from tools.aero.casos import CASOS
    ac = CASOS["ret_ar8"]()
"""
from __future__ import annotations

import math

PERFIL = "2412"          # NACA 4 dígitos de todas as asas (as caudas: 0012)


def _foil(code: str = PERFIL):
    from aerosim.model.airfoil import Airfoil, naca4
    return Airfoil(name=f"NACA {code}", coords=naca4(code).tolist())


def _mac(cr: float, ct: float, semi: float, x_tip: float) -> tuple[float, float]:
    """CMA e posição do bordo de ataque dela (x, para trás) de um trapézio"""
    lam = ct / cr
    mac = 2 / 3 * cr * (1 + lam + lam ** 2) / (1 + lam)
    y = semi / 3 * (1 + 2 * lam) / (1 + lam)
    return mac, x_tip * y / semi


def asa(b: float = 2.0, cr: float = 0.25, ct: float | None = None, sweep_le: float = 0.0, dihedral: float = 0.0,
        twist: float = 0.0, foil: str = PERFIL, name: str = "asa", role: str = "wing", x: float = 0.0,
        z: float = 0.0, incidence: float = 0.0, controls=(), vertical: bool = False):
    """uma superfície trapezoidal; x: bordo de ataque da raiz, para trás a partir do da asa (`aviao` converte para
    o corpo, em que x é para a frente)"""
    from aerosim.model.aircraft import LiftingSurface, WingSection
    ct = cr if ct is None else ct
    semi = b / 2
    x_tip = math.tan(math.radians(sweep_le)) * semi
    return LiftingSurface(name=name, role=role, x=x, z=z, incidence=incidence, dihedral=dihedral,
                          vertical=vertical, symmetric=not vertical,
                          airfoil=_foil(foil), controls=list(controls),
                          sections=[WingSection(0.0, cr, 0.0, 0.0), WingSection(semi, ct, x_tip, twist)])


def aviao(name: str, superficies: list, wing=None):
    """o `Aircraft` sem fuselagem e sem motor, com a origem no 1/4 da CMA da asa principal (x do corpo para a
    frente; nos casos, x das superfícies é para trás a partir do bordo de ataque da raiz da asa)"""
    from aerosim.model.aircraft import Aircraft, Fuselage, MassModel
    w = wing or superficies[0]
    cr, ct = w.sections[0].chord, w.sections[-1].chord
    semi = w.sections[-1].y
    mac, x_mac = _mac(cr, ct, semi, w.sections[-1].x_offset)
    dx = w.x + x_mac + 0.25 * mac               # 1/4 da CMA, para trás: vira a origem
    for s in superficies:
        s.x = dx - s.x
    ac = Aircraft(name=name, surfaces=superficies, fuselage=Fuselage(enabled=False), propulsion=[],
                  mass=MassModel(base_mass=1.0, base_cg=[0.0, 0.0, 0.0]))
    ac.Sref = semi * (cr + ct)
    ac.cref, ac.bref = mac, 2 * semi
    return ac


def _cauda(lt: float = 0.9, S: float = 0.10, AR: float = 4.0, x0: float = 0.0):
    """EH retangular NACA 0012 a lt atrás do bordo de ataque da asa, com profundor de 30 % da corda"""
    from aerosim.model.aircraft import ControlSurface
    b = math.sqrt(S * AR)
    eh = asa(b=b, cr=S / b, foil="0012", name="EH", role="htail", x=x0 + lt,
             controls=[ControlSurface("elevator", 0.0, 1.0, 0.30)])
    eh.downwash = True
    return eh


def ret(AR: float):
    def f():
        c = 0.25
        return aviao(f"retangular AR {AR:g}", [asa(b=AR * c, cr=c)])
    f.__doc__ = f"asa retangular, corda 0,25 m, AR {AR:g}"
    return f


def trapezio():
    """asa trapezoidal, AR 8, afilamento 0,5"""
    return aviao("trapezoidal AR 8 λ 0,5", [asa(b=2.4, cr=0.4, ct=0.2)])


def enflechada():
    """asa trapezoidal AR 8, afilamento 0,5, enflechamento 25° no bordo de ataque"""
    return aviao("enflechada 25°", [asa(b=2.4, cr=0.4, ct=0.2, sweep_le=25.0)])


def diedro():
    """asa retangular AR 8 com 6° de diedro (para o C_lβ)"""
    return aviao("retangular AR 8 diedro 6°", [asa(b=2.0, cr=0.25, dihedral=6.0)])


def torcida():
    """asa trapezoidal AR 8 com −3° de torção na ponta"""
    return aviao("trapezoidal torcida −3°", [asa(b=2.4, cr=0.4, ct=0.2, twist=-3.0)])


def asa_cauda():
    """asa retangular AR 8 com aileron + EH com profundor (sem EV: sem fuselagem, sem leme)"""
    from aerosim.model.aircraft import ControlSurface
    w = asa(b=2.0, cr=0.25, controls=[ControlSurface("aileron", 0.6, 0.95, 0.25)])
    return aviao("asa + EH", [w, _cauda()], wing=w)


def _ev(lt: float = 0.9, S: float = 0.05, h: float = 0.25):
    """EV NACA 0012 trapezoidal (λ 0,6) a lt atrás do bordo de ataque da asa, com leme de 30 % da corda"""
    from aerosim.model.aircraft import ControlSurface
    cr = 2 * S / (h * 1.6)
    return asa(b=2 * h, cr=cr, ct=0.6 * cr, sweep_le=20.0, foil="0012", name="EV", role="vtail", x=lt,
               vertical=True, controls=[ControlSurface("rudder", 0.0, 1.0, 0.30)])


def convencional():
    """asa retangular AR 8 com aileron + EH com profundor + EV com leme (o avião completo, sem fuselagem)"""
    from aerosim.model.aircraft import ControlSurface
    w = asa(b=2.0, cr=0.25, controls=[ControlSurface("aileron", 0.6, 0.95, 0.25)])
    return aviao("asa + EH + EV", [w, _cauda(), _ev()], wing=w)


CASOS = {
    "ret_ar4": ret(4.0), "ret_ar6": ret(6.0), "ret_ar8": ret(8.0), "ret_ar12": ret(12.0),
    "trapezio": trapezio, "enflechada": enflechada, "diedro": diedro, "torcida": torcida,
    "asa_cauda": asa_cauda, "convencional": convencional,
}


PAPEIS = {"asa": "wing", "eh": "htail", "ev": "vtail"}


def so(ac, partes):
    """cópia do avião só com as superfícies de `partes` (nomes de PAPEIS: asa, eh, ev); None se não sobrar nenhuma.
    A referência (S, c, b e a origem no 1/4 da CMA da asa) fica a do avião inteiro, para os números se somarem; sem a
    asa, a EH deixa de ver o downwash dela"""
    import copy
    roles = {PAPEIS[p] for p in partes}
    a = copy.deepcopy(ac)
    a.surfaces = [s for s in a.surfaces if s.role in roles]
    if not a.surfaces:
        return None
    if "wing" not in roles:
        for s in a.surfaces:
            s.downwash = False
    return a


def com_perfil(ac, path: str, partes=("asa",)):
    """cópia do avião com o perfil do arquivo .dat (Selig ou Lednicer) nas superfícies de `partes`; inclinação, c_l
    máx. e c_d0 ficam os padrões do programa (`Airfoil`), α0 e c_m saem da linha média do contorno"""
    import copy

    from aerosim.model.airfoil import Airfoil, read_dat
    name, xy = read_dat(path)
    roles = {PAPEIS[p] for p in partes}
    a = copy.deepcopy(ac)
    for s in a.surfaces:
        if s.role in roles:
            s.airfoil = Airfoil(name=name, path=path, coords=xy.tolist())
            for q in s.sections:
                q.airfoil = None
    a.name += f" [{name}]"
    return a

"""Etapa Empenagem e comandos: as superfícies que acompanham a asa escolhida, o tubo de cauda e os comandos.

Dimensionamento por volume de cauda (o braço é do centro aerodinâmico da asa ao da cauda):

    S_h = V_H S c̄ / l        S_v = V_V S b / l

Cauda em V: a mesma área total S_h + S_v, diedro atan √(S_v / S_h). Sem cauda: elevons na asa. Cauda em H: a EH
da convencional com a EV repartida em duas iguais, uma em cada ponta da EH (S_v/2 cada, o mesmo alongamento). A
estática é a da convencional: a área vertical é a mesma, e o ganho de placa de ponta que as duas EV dão à EH fica de
fora, do lado conservador (Raymer, "Aircraft Design: A Conceptual Approach", cap. 4 e 16, a conferir no PDF).

A análise rápida é a estática longitudinal clássica (Etkin; Nelson, cap. 2):

    h_n = h_ac + η V_H (a_h / a) (1 − dε/dα),   dε/dα = 2 a / (π AR)
    C_m = C_m,ac + C_L (h − h_ac) − η V_H' a_h (α_h + τ δe),   α_h = α_w − ε + i_h

com o CG posto na margem estática pedida. A incidência da EH sai para equilibrar o cruzeiro com o
profundor neutro. Faixa de CG: atrás, margem mínima; à frente, o profundor deixa de equilibrar o
C_L,max. Rolagem: p b/2V com o aileron todo (faixas, C_lp de asa trapezoidal).

Segunda asa (tandem, biplano): outra asa guardada, ou a mesma, posta a um recuo e a um desnível da primeira e
ligada a ela (`Aircraft.wing_group`, o id fica no conjunto). A estática analítica acima continua sendo a da asa 1
com a cauda; com o par, quem dá a margem é o avião inteiro no núcleo (Aerodinâmica → Asas, parte do avião completo).
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.aircraft import Aircraft, ControlSurface, LiftingSurface, TailBoom, WingSection
from aerosim.model.airfoil import Airfoil, flap_effectiveness, helmbold
from aerosim.model.modifiers import Modifier

from . import airfoils as afm
from .fields import F
from .spec import DesignRules, Requirements, cruise_CL
from .wing import WingCandidate, analyze as analyze_wing, lifting_line, planform

LAYOUTS = ("convencional", "em V", "sem cauda", "em H")
WITH_HTAIL = ("convencional", "em H")              # EH e EV separadas (a estática e o C_nβ são os mesmos)
ARM_FROM = ("CA da asa", "CG de projeto")
NO_WING2, SAME_WING = "nenhuma", "a mesma asa"     # TailParams.wing2: sem segunda asa; a da etapa repetida
TANDEM_PITCH = ("asa de trás", "asa da frente", "as duas")   # TailParams.tandem_pitch: onde fica o comando de arfagem
TIP_FIN_WHERE = ("asa de trás", "asa da frente")   # TailParams.tip_fin_where: em qual asa vão as derivas (tandem)


@dataclass
class TailParams:
    name: str = F("conjunto 1", "nome")
    wing: str = F("asa 1", "asa", "", "uma das asas guardadas na etapa Asa")
    wing2: str = F(NO_WING2, "segunda asa (tandem, biplano)", "", "outra asa guardada, ou a mesma (biplano de asas "
                   "iguais); ela fica ligada à primeira: a referência do avião passa a ser o par")
    wing2_dx: float = F(0.0, "recuo da segunda asa", "m", "do bordo de ataque da raiz da primeira ao da segunda; "
                        "+ para trás (tandem)", -3.0, 3.0, 0.01)
    wing2_dz: float = F(0.0, "desnível da segunda asa", "m", "+ para cima (biplano: o vão entre as asas)", -1.0, 1.0,
                        0.01)
    wing2_di: float = F(0.0, "decalagem da segunda asa", "°", "incidência dela menos a da primeira", -12, 8, 0.25)
    wing2_area: float = F(1.0, "área da segunda asa / da primeira", "", "as cordas da segunda asa vezes isto, com a "
                          "mesma envergadura (a envergadura máxima vale para as duas). No tandem a da frente é a "
                          "menor: a de trás trabalha no downwash dela e precisa de mais área para dividir a "
                          "sustentação (Kryvokhatko, IntechOpen, a conferir no PDF). 1 = a mesma asa", 0.5, 2.5, 0.05)
    wing2_span: float = F(1.0, "envergadura da segunda asa / da primeira", "", "a asa de trás do tandem costuma ser "
                          "a maior também na envergadura (o Libellula do dono: 2,3 m atrás, 1,3 m na frente). A área "
                          "fica a de `wing2_area`: só as cordas acompanham. 1 = a mesma", 0.5, 2.5, 0.05)
    wing2_sweep: float = F(0.0, "enflechamento a mais na segunda asa", "°", "do bordo de ataque, somado ao dela. "
                           "Na asa de trás do tandem ele leva o CA dela para trás sem alongar o tubo, e com as "
                           "derivas na ponta aumenta o braço delas (o Libellula tem uns 23°)", 0.0, 40.0, 0.5)
    wing2_airfoil: str = F("", "perfil da segunda asa", "", "vazio = o da asa dela. No tandem, um perfil de pouco "
                           "momento atrás: o C_m picador de um perfil de alta sustentação (S1223) empurra a asa de "
                           "trás para baixo no trim, e a da frente acaba levando quase toda a sustentação")
    tandem_pitch: str = F(TANDEM_PITCH[0], "arfagem do tandem", "", "onde fica o comando de arfagem: na asa de trás "
                          "(profundor, e aileron na da frente), na da frente (elevon que desce para cabrar, como um "
                          "canard) ou nas duas", choices=TANDEM_PITCH)
    tip_fin: float = F(0.0, "deriva na ponta (altura)", "m", "sem cauda: uma superfície vertical em cada ponta da "
                       "asa, com leme. Ela faz a estabilidade direcional que a asa voadora e o tandem não têm, e de "
                       "quebra trabalha como placa de ponta. 0 = nenhuma", 0.0, 0.5, 0.01)
    tip_fin_chord: float = F(0.6, "deriva na ponta: corda", "", "fração da corda da ponta da asa", 0.2, 1.2, 0.05)
    tip_fin_where: str = F(TIP_FIN_WHERE[0], "deriva na ponta: onde", "", "no tandem, em qual asa ficam as derivas (a "
                           "ponta da asa da frente fica quase no CG, sem braço para guinar)",
                           choices=TIP_FIN_WHERE)
    layout: str = F("convencional", "cauda", "", "convencional: EH + EV; em V: duas superfícies inclinadas; "
                    "sem cauda: elevons na asa; em H: EH com uma EV em cada ponta", choices=LAYOUTS)
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
    flap_moment: bool = F(False, "momento próprio dos comandos", "", "o comando também muda o momento no quarto de "
                          "corda da faixa (perfil fino), no núcleo: o elevon da asa voadora cabra o que a teoria dá. "
                          "Liga o modificador comando.momento_flape no avião")
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
    wing2: WingCandidate | None = None      # a segunda asa (cópia); None: monoplano
    group: str = ""                         # id que liga as duas asas no avião (sorteado ao guardar)

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
    if tp.flap_moment:                              # momento próprio dos comandos (core/src/modifiers/flapmoment.zig)
        ac.modifiers.append(Modifier("comando.momento_flape"))
    info = dict(S=S, c=c, b=b, x_ac_w=pf["x_ac"], x_le_mac=pf["x_le_mac"], Sh=0.0, Sv=0.0, bh=0.0, hv=0.0, arm=0.0)
    if tp.layout == "sem cauda":
        _add_wing2(ac, cand, req, rules)
        if cand.wing2 is not None:
            # tandem: a asa de trás é a cauda. Na da frente o comando só rola (um elevon ali, à frente do CG, cabra
            # descendo e pica subindo, o contrário de um profundor); na de trás, no mesmo trecho, ele é o profundor
            # a da frente fica à frente do CG: para cabrar o comando dela desce (ganho de arfagem −1, `mix`)
            front = tp.tandem_pitch in TANDEM_PITCH[1:]
            rear = tp.tandem_pitch != TANDEM_PITCH[1]
            w.controls = [ControlSurface("elevon", a0, min(a1, 1.0), tp.aileron_chord, mix=[-1.0, 1.0, 0.0]) if front
                          else ControlSurface("aileron", a0, min(a1, 1.0), tp.aileron_chord)]
            w2 = second_wing(ac)
            w2.controls = [ControlSurface("elevator", a0, min(a1, 1.0), tp.aileron_chord)] if rear else []
            # atrás da da frente, ela sente o downwash dela, como uma EH (sem isto o núcleo punha o ponto neutro
            # na média dos dois CA, bem atrás do da sprint), e um tubo a liga à fuselagem: a massa dele entra e o
            # lastro, quando falta, vai na ponta dele
            w2.downwash, w2.eta = True, tp.tail_eta
            x_start = w.x - 0.25 * w.sections[0].chord
            reach = max(x_start - (w2.x - w2.sections[0].chord), 0.05)
            pitch = math.degrees(math.atan2(-w2.z, reach))   # da fuselagem (z = 0) à altura da asa de trás
            ac.booms = [TailBoom(name="tubo de cauda", x_start=x_start, length=math.hypot(reach, w2.z),
                                 diameter=tp.boom_diameter, pitch=pitch)]
            w2.mount = "tubo:0"
            ac.apply_constraints()
            info.update(boom=ac.boom.length, mass_boom=ac.boom.length * rules.boom_density)
        if tp.tip_fin > 0:
            info.update(_tip_fins(ac, cand, tp, airfoils, req))
        ac.apply_constraints()
        return ac, info
    l = tp.arm + arm_shift                          # do CA da asa ao da cauda (posição)
    Sh = tp.VH * S * c / tp.arm                     # volume de cauda com o braço como foi dado
    Sv = tp.VV * S * b / tp.arm
    x_ac_t = pf["x_ac"] - l
    if tp.layout in WITH_HTAIL:
        bh = math.sqrt(tp.AR_h * Sh)
        af_t, lim = tail_entry(tp.tail_airfoil, airfoils, req.reynolds(Sh / bh), tp.tail_inverted)
        eh = _surface("EH", "htail", bh, Sh, tp.taper_h, af_t)
        eh.controls = [ControlSurface("elevator", 0.0, 1.0, tp.elevator)]
        n_v = 2 if tp.layout == "em H" else 1          # em H: a EV repartida nas duas pontas da EH
        hv = math.sqrt(tp.AR_v * Sv / n_v)
        af_v = tail_airfoil(tp.vtail_airfoil, airfoils, req.reynolds(Sv / n_v / hv))
        evs = []
        for k in range(n_v):
            ev = _surface("EV" if n_v == 1 else ("EV direita", "EV esquerda")[k], "vtail", hv, Sv / n_v, tp.taper_v,
                          af_v, vertical=True, symmetric=False)
            ev.controls = [ControlSurface("rudder", 0.0, 1.0, tp.rudder)]
            evs.append(ev)
        tails = [eh, *evs]
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
    if tp.layout == "em H":                      # as EV nas pontas da EH (ela fica em [1])
        tails[1].mount, tails[2].mount = "ponta_dir:1", "ponta_esq:1"
    ac.surfaces += tails
    _add_wing2(ac, cand, req, rules)
    ac.apply_constraints()
    info.update(Sh=Sh, Sv=Sv, bh=bh, hv=hv, arm=l, x_ac_t=x_ac_t, cl_lim_h=lim,
                boom=ac.boom.length, mass_tail=(Sh + Sv) * rules.tail_density, mass_boom=ac.boom.length * rules.boom_density)
    return ac, info


def _fin_cnb(info: dict, S: float, b: float, x_cg: float) -> float:
    """C_nβ = η V_V a_v das derivas nas pontas, com o braço do CG ao centro aerodinâmico delas. Sem deriva, NaN: a
    asa sem cauda não tem estabilidade direcional de que falar"""
    if not info.get("n_fins"):
        return float("nan")
    Sv, h = info["Sv"], info["hv"]
    a_v = helmbold(5.9, 2 * h * h / max(Sv, 1e-9))     # as duas metades: alongamento efetivo de placa de ponta
    return float(Sv * (x_cg - info["x_ac_fin"]) / (S * b) * a_v)


def _tip_fins(ac: Aircraft, cand: SetCandidate, tp: TailParams, airfoils, req) -> dict:
    """as derivas nas pontas da asa sem cauda: uma de cada lado, presa à ponta (`mount` "ponta_dir"/"ponta_esq"),
    com leme. Sem cauda não há nada que dê estabilidade direcional, e a asa enflechada sozinha guina de volta
    devagar; a deriva na ponta resolve isso sem tubo nem EV atrás, e ainda trabalha como placa de ponta (o ganho de
    alongamento efetivo fica de fora, do lado conservador; Raymer, "Aircraft Design: A Conceptual Approach", cap. 12,
    a conferir no PDF). Devolve a área, a altura e o braço delas para o C_nβ"""
    # no tandem a ponta da asa da frente fica quase no CG (braço nenhum): as derivas vão na de trás, a não ser que
    # se peça o contrário
    host = second_wing(ac) if (cand.wing2 is not None and tp.tip_fin_where == TIP_FIN_WHERE[0]) else ac.surfaces[0]
    i = ac.surfaces.index(host)
    h = tp.tip_fin
    ct = host.sections[-1].chord
    cr = tp.tip_fin_chord * ct
    af = tail_airfoil(tp.vtail_airfoil, airfoils, req.reynolds(cr))
    out = []
    for name, mount in (("deriva direita", f"ponta_dir:{i}"), ("deriva esquerda", f"ponta_esq:{i}")):
        f_ = _surface(name, "vtail", h, h * cr * (1 + tp.taper_v) / 2, tp.taper_v, af, vertical=True, symmetric=False)
        f_.controls = [ControlSurface("rudder", 0.0, 1.0, tp.rudder)]
        f_.mount, f_.eta = mount, 1.0              # na ponta da asa, fora da esteira da fuselagem
        out.append(f_)
    ac.surfaces += out
    Sv = sum(f_.area for f_ in out)
    x_ac_f = host.x - host.xoff_at(host.semispan) - 0.25 * cr
    return dict(Sv=Sv, hv=h, x_ac_fin=x_ac_f, n_fins=2)


def wing2_candidate(w2: WingCandidate | None, tp: TailParams, lookup) -> WingCandidate | None:
    """a segunda asa do conjunto: uma cópia de `w2` com o perfil `tp.wing2_airfoil` em toda a envergadura, quando
    há um (`lookup(nome)` devolve o `AirfoilEntry` ou None; um nome que não existe deixa o perfil dela)"""
    if w2 is None:
        return None
    w2 = copy.deepcopy(w2)
    e = lookup(tp.wing2_airfoil) if tp.wing2_airfoil else None
    if e is not None:
        w2.airfoil, w2.airfoil_tip, w2.section_airfoils = copy.deepcopy(e), None, []
        w2.params.airfoil, w2.params.airfoil_tip = e.name, ""
        for q in w2.params.partitions:
            q.airfoil = ""
    return w2


def second_wing(ac: Aircraft):
    """a segunda asa (tandem, biplano): a primeira superfície de papel "wing" depois da asa em [0], ou None. Não é
    `surfaces[-1]`: as derivas da ponta entram depois dela, e com elas a estática lia a deriva como asa de trás"""
    return next((s for s in ac.surfaces[1:] if s.role == "wing"), None)


def _add_wing2(ac: Aircraft, cand: SetCandidate, req: Requirements, rules: DesignRules) -> None:
    """a segunda asa no fim da lista (as contas da etapa leem a asa em [0] e a cauda em [1]), ligada à primeira"""
    if cand.wing2 is None:
        return
    tp = cand.params
    w = ac.surfaces[0]
    w2 = copy.deepcopy(analyze_wing(cand.wing2, req, rules)["surface"])
    w2.name = w2.name if w2.name != w.name else f"{w.name} (2)"
    w2.x, w2.y, w2.z = w.x - tp.wing2_dx, w.y, w.z - tp.wing2_dz      # z do corpo para baixo
    if tp.wing2_area != 1.0 or tp.wing2_span != 1.0:
        # a envergadura vezes `wing2_span` e as cordas vezes área/envergadura: a área sai `wing2_area` vezes a da
        # primeira, com a mesma forma em planta (o recuo do bordo de ataque acompanha as cordas)
        kc = tp.wing2_area / tp.wing2_span
        for sec in w2.sections:
            sec.y *= tp.wing2_span
            sec.chord *= kc
            sec.x_offset *= kc
    if tp.wing2_sweep:                                # enflechamento a mais no bordo de ataque
        t = math.tan(math.radians(tp.wing2_sweep))
        for sec in w2.sections:
            sec.x_offset += sec.y * t
    # a decalagem (`wing2_di`) conta da primeira asa. Com o mesmo perfil, é a diferença das incidências, como sempre.
    # Com outro perfil ela é a decalagem aerodinâmica, entre as linhas de sustentação nula das duas: com 0 as duas
    # asas sustentam o mesmo C_L no mesmo α. Antes a asa de trás ficava com a incidência que a etapa Asa daria a ela
    # sozinha, que não conversa com a da frente (NACA 0012 atrás de uma E423: 14,8° contra 4,3°, e o corpo picado a
    # −10° no cruzeiro); e com a diferença das incidências geométricas a de trás, simétrica, ficava ~10° abaixo da
    # sustentação da da frente, e o profundor trimava a 18° (Kryvokhatko, "Tandem wing", IntechOpen, a conferir no PDF)
    if tp.layout == "sem cauda":
        # tandem: as duas asas dividem o peso, e a incidência que a etapa Asa deu à da frente era para ela sozinha
        # levar o avião no cruzeiro (C_L do peso na área dela). Com a de trás sustentando junto, o C_L de cruzeiro é
        # o do peso na soma das áreas, e as duas asas descem a incidência do quanto o C_L cai: ΔCL / C_Lα. Sem isso
        # um tandem de asa da frente pequena saía com 24° nas duas asas, a de trás estolava no cruzeiro e o profundor
        # não mexia no C_m. O biplano ainda não passa por aqui (O31 no tracking)
        wr = analyze_wing(cand.wing, req, rules)
        S1 = w.area
        dCL = cruise_CL(req, S1 + w2.area) - cruise_CL(req, S1)
        w.incidence += math.degrees(dCL / wr["CLa"])
    names = lambda s: [(q.airfoil or s.airfoil).name for q in s.sections]
    if names(w2) != names(w):
        a0 = lambda s: -lifting_line(s)["At"][0] / lifting_line(s)["Aa"][0]       # α da raiz com C_L = 0 (rad)
        w2.incidence = w.incidence + tp.wing2_di + math.degrees(a0(w2) - a0(w))
    else:
        w2.incidence = w.incidence + tp.wing2_di
    w2.controls = []                                  # os comandos ficam na primeira (na Montagem, livre)
    ac.surfaces.append(w2)
    ac.link_wings(w, w2)
    if cand.group:                                    # o id guardado no conjunto (o mesmo até a Montagem)
        w.group = w2.group = cand.group


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
        if cand.wing2 is not None and second_wing(ac) is not None:
            # tandem: a asa de trás é a "cauda". O ponto neutro é a média dos CA ponderada pela sustentação que cada
            # asa ganha com α (a de trás com a eficiência η e o downwash da da frente): x_n = Σ a_i S_i x_ac,i / Σ a_i S_i.
            # Com uma EH pequena isto vira o h_n = h_ac + η V_H (a_t/a)(1 − dε/dα) de sempre, que despreza a
            # sustentação da cauda no total e não serve quando as duas asas são do mesmo tamanho (Etkin e Reid,
            # "Dynamics of Flight", seção 2.3; a conferir no PDF). Antes o tandem ficava com o ponto neutro da asa da
            # frente sozinha: o CG ia para perto dela e o avião não trimava com C_m nenhum
            w2 = second_wing(ac)
            pf2 = planform(w2)
            if tp.wing2_area == 1.0 and tp.wing2_span == 1.0 and not tp.wing2_sweep:
                a2 = analyze_wing(cand.wing2, req, rules)["CLa"]
            else:                                    # com as cordas da razão de áreas: o alongamento cai
                L2 = lifting_line(w2)
                a2 = math.pi * L2["AR"] * L2["Aa"][0]
            k2 = tp.tail_eta * a2 * pf2["S"] * (1 - deda)
            x_np = (a * S * info["x_ac_w"] + k2 * pf2["x_ac"]) / (a * S + k2)
            h_n = (info["x_le_mac"] - x_np) / c
            out.update(x_ac_2=pf2["x_ac"], S2=pf2["S"])
        h_cg = h_n - tp.sm_target / 100
        # elevon, por faixa: o Δc_l = a τ δ no quarto de corda da faixa, com o braço até o CG, mais o momento próprio
        # do flape no quarto de corda (perfil fino: Δc_m,c/4 = −½ sen θ_f (1 − cos θ_f) δ, cos θ_f = 2 c_f/c − 1;
        # Anderson, "Fundamentals of Aerodynamics", seção do flape na teoria do perfil fino, a conferir no PDF),
        # com o mesmo fator empírico 0,85 de `flap_effectiveness`. Antes o Δc_l ia todo a 3/4 da corda, o que dava
        # uns 4 vezes o C_mδ do núcleo (O16 no tracking; tools/rotacao.py compara)
        x_c = info["x_le_mac"] - h_cg * c
        # cada comando com arfagem soma, com o ganho dele (no tandem: o profundor da de trás, o da frente com −1)
        Cmd = 0.0
        for pw_ in (ac.surfaces if cand.wing2 is not None else [w]):
            for pc in pw_.controls:
                g = pc.gains[0]
                if g == 0:
                    continue
                tau_p = flap_effectiveness(pc.chord_frac)
                yp = np.linspace(pc.span_start * pw_.semispan, min(pc.span_end, 1.0) * pw_.semispan, 60)
                th = math.acos(min(max(2 * pc.chord_frac - 1, -1.0), 1.0))
                dcm = -0.85 * 0.5 * math.sin(th) * (1 - math.cos(th))
                ch = np.array([pw_.chord_at(y) for y in yp])
                arm = np.array([x_c - (pw_.x - pw_.xoff_at(y) - 0.25 * pw_.chord_at(y)) for y in yp])
                Cmd += g * 2 / (S * c) * np.trapezoid(-a * tau_p * ch * arm + dcm * ch * ch, yp)
        Cm0 = wr["Cm_ac"]
        de_cru = -(Cm0 + CLc * (h_cg - h_ac)) / Cmd
        de_max_cl = -(Cm0 + CLmax * (h_cg - h_ac)) / Cmd
        tw = lambda CL, de, x_mg, dih=0.0: Cmd * (de + dih)
        out.update(rotation(wr, req, rules, x_c, info["x_ac_w"], c, S, tw))
        out["tail_cm_mg"] = tw
        out.update(h_n=h_n, h_cg=h_cg, x_cg=x_c, x_np=info["x_le_mac"] - h_n * c, Cmde=Cmd, i_h=0.0,
                   de_cruise=math.degrees(de_cru), de_CLmax=math.degrees(de_max_cl), VH=0.0, VV=0.0,
                   Cnb=_fin_cnb(info, S, b, x_c))
        out.update(_curves(out, wr, req, None))
        return out
    t = ac.surfaces[1]
    af = t.airfoil
    AR_t = t.aspect_ratio if not t.vertical else 2 * t.aspect_ratio
    a_h = helmbold(af.cl_alpha, max(AR_t, 0.5))
    if tp.layout == "em V":
        a_h *= math.cos(math.radians(info.get("gamma", 0.0))) ** 2
    eta = tp.tail_eta
    Sh = info["Sh"] if tp.layout in WITH_HTAIL else info["Sh"] + info["Sv"]
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
    if tp.layout in WITH_HTAIL:                            # em H: cada EV tem o alongamento de uma só
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

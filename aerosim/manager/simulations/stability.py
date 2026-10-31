"""Aba Estabilidade — diz se a configuração serve, por quê, e o que mudar.

O formulário e os gráficos dependem da aeronave (`features`): sem EH não há dimensionamento de
EH (asa voadora: a margem vem da própria asa e o elevon divide o curso entre arfagem e rolagem);
sem leme não há dimensionamento de leme; a faixa de CG vem da carga e do líquido quando existem.

Ordem da análise (é a ordem de dimensionamento):
 1. estática longitudinal: ponto neutro, margem × CG, deflexão de equilíbrio × CG
    (limite traseiro = margem mínima; limite dianteiro = comando de arfagem no fim do curso no
    pouso ou na rotação) → a faixa de CG prevista cabe?
 2. EH (se houver): que área a faixa de CG exige
 3. estática látero-direcional: C_nβ > 0, C_lβ < 0, critério da espiral
 4. dinâmica (modelo linear do núcleo) × MIL-F-8785C; quando um modo falha, a mesma análise é
    refeita com a deriva maior ou mais diedro para dizer quanto mudar
 5. comandos: rolagem (aileron ou elevon), profundor, leme
Cada passo gera itens de diagnóstico (estado, valor, critério, causa, o que fazer).
"""
from __future__ import annotations

import math
import re

import numpy as np

from aerosim.aero.geometry import RAYMER_TAIL_VOLUME
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model
from aerosim.model.features import features
from aerosim.stability import Probe, aileron_sizing, mil_check, modes, response, rudder_sizing, scissor
from aerosim.stability.controls import ROLL_REQ, elevator_sizing, time_to_bank
from aerosim.stability.criteria import evaluate
from aerosim.stability.dynamic import doublet, pulse
from aerosim.stability.scissor import min_tail
from aerosim.stability.sizing import (cg_sweep, cm0, gear_x_for_rotation, with_elevon, with_washout, limit_crossing, modes_at, rotation_de,
                                      scale_surfaces, search, slosh_eigs_at, stall_speed, trimmed_CLmax, with_dihedral)
from aerosim.stability.static import analytic_np

from .base import SimulationBase, floats

MODE_LAB = {"curto_periodo": "curto período", "fugoide": "fugóide", "dutch_roll": "dutch roll",
            "rolamento": "rolamento", "espiral": "espiral"}
# a cor e o símbolo de cada modo no mapa dos polos (as cores da paleta da GUI)
MODE_STYLE = {"curto_periodo": ("#1f77b4", "o"), "fugoide": ("#ff7f0e", "s"), "dutch_roll": ("#9467bd", "d"),
              "rolamento": ("#2ca02c", "t"), "espiral": ("#d62728", "x")}


def _cruise_speed(ac) -> float:
    vs = [sg["V1"] for sg in ac.mission.segments() if not sg.get("takeoff") and not sg.get("landing")]
    return float(max(vs)) if vs else 15.0


def _fmt(v, nd=3):
    if isinstance(v, (list, tuple)):
        return ", ".join(_fmt(x, nd) for x in v)
    if isinstance(v, (float, np.floating)):
        if not math.isfinite(v):
            return "∞" if v > 0 else "—"
        return f"{v:.{nd}g}"
    return str(v)


SLOW_MODES = ("fugoide", "dutch_roll", "espiral")     # os polos perto da origem, num gráfico só deles


def _pole_series(rows: list[dict], crit, names=tuple(MODE_LAB), prefix: str = "p_") -> dict:
    """o mapa dos polos: λ = Re + i Im de cada modo em cada V (a metade de cima do plano complexo), a faixa instável
    (Re > 0) e as retas de ζ constante dos mínimos do nível 1. Um polo λ = −ζ ω_n ± i ω_n √(1 − ζ²) fica na reta
    que sai da origem com cos θ = ζ (Etkin e Reid, Dynamics of Flight, 3ª ed., cap. 6; a conferir no PDF)"""
    S, reach, right, high = {}, 0.0, 0.0, 0.0
    for nm in names:
        label = MODE_LAB[nm]
        re_ = np.array([r[f"re_{nm}"] for r in rows], float)
        im_ = np.array([r[f"im_{nm}"] for r in rows], float)
        ok = np.isfinite(re_) & np.isfinite(im_)
        if not ok.any():
            continue
        color, symbol = MODE_STYLE[nm]
        S[f"{prefix}{label}"] = {"re": re_[ok], "im": im_[ok], "_color": color, "_symbol": symbol, "_line": 1, "_size": 9}
        reach = max(reach, float(np.max(np.hypot(re_[ok], im_[ok]))))
        right = max(right, float(np.max(re_[ok])))
        high = max(high, float(np.max(im_[ok])))
    if not S:
        return S
    span = 1.1 * max(reach, 1e-3)
    S[f"{prefix}instável (Re > 0)"] = {"_vspan": [0.0, max(right, 0.0) + 0.08 * span], "_color": "#d62728"}
    for nm, zeta in (("curto_periodo", crit.sp_zeta_min), ("fugoide", crit.ph_zeta_min),
                     ("dutch_roll", crit.dr_zeta_min)):
        if nm in names and 0 < zeta < 1:
            # a reta vai até a altura do polo mais alto, para não esticar o gráfico
            top = 1.15 * max(high, 1e-3)
            length = top / math.sqrt(1 - zeta ** 2)
            S[f"{prefix}ζ = {zeta:g} ({MODE_LAB[nm]})"] = {"re": np.array([0.0, -zeta * length]),
                                                         "im": np.array([0.0, top]),
                                                         "_color": MODE_STYLE[nm][0], "_dash": 1, "_width": 1.0}
    return S


def _match_poles(row: dict, eigs) -> tuple[dict, list]:
    """os polos de um modelo maior (com o líquido) casados com os modos do corpo rígido da linha `row`: cada modo
    fica com o autovalor mais perto do dele (metade de cima do plano); o que sobra são os modos do líquido"""
    found = {f"{part}_{nm}": np.nan for nm in MODE_LAB for part in ("re", "im")}
    if eigs is None:
        return found, []
    free = [complex(lam) for lam in eigs if lam.imag >= -1e-9]
    for nm in MODE_LAB:
        lam0 = complex(row[f"re_{nm}"], row[f"im_{nm}"])
        if not np.isfinite([lam0.real, lam0.imag]).all() or not free:
            continue
        k = int(np.argmin([abs(lam - lam0) for lam in free]))
        lam = free.pop(k)
        found[f"re_{nm}"], found[f"im_{nm}"] = lam.real, abs(lam.imag)
    return found, [lam for lam in free if lam.imag > 1e-9]


def _release_series(before: list[dict], after: list[dict], prefix: str = "s_",
                    names: tuple = ("com carga", "sem carga")) -> dict:
    """os polos de dois modelos lineares, um par por V ligado por um traço fino: com a carga e sem ela (o modelo
    refeito sem a massa da carga, com o CG e a inércia que ficam) ou com o líquido parado e oscilando"""
    S = {}
    for nm, label in MODE_LAB.items():
        color, symbol = MODE_STYLE[nm]
        pairs = [(b[f"re_{nm}"], b[f"im_{nm}"], a[f"re_{nm}"], a[f"im_{nm}"]) for b, a in zip(before, after)]
        pairs = [p for p in pairs if all(np.isfinite(p))]
        if not pairs:
            continue
        P = np.array(pairs, float)
        S[f"{prefix}{label}: {names[0]}"] = {"re": P[:, 0], "im": P[:, 1], "_color": color, "_symbol": symbol,
                                             "_size": 9}
        S[f"{prefix}{label}: {names[1]}"] = {"re": P[:, 2], "im": P[:, 3], "_color": color, "_symbol": "+",
                                             "_size": 12}
        gap = np.full(len(P), np.nan)                     # um traço por V: antes, depois, NaN (corta a linha)
        S[f"{prefix}{label}: movimento"] = {"re": np.column_stack([P[:, 0], P[:, 2], gap]).ravel(),
                                      "im": np.column_stack([P[:, 1], P[:, 3], gap]).ravel(),
                                      "_color": color, "_width": 1.0, "_nolegend": 1}
    return S


def _release_check(before: list[dict], after: list[dict], V: float, item: str = "polos ao soltar a carga",
                   why: str = "sem a carga a massa, o CG e a inércia mudam, e os modos se deslocam (gráfico 'Polos "
                              "ao soltar a carga')"):
    """o que muda nos modos oscilatórios de um modelo para o outro, na velocidade da análise (ou na mais perto)"""
    k = int(np.argmin([abs(b["V"] - V) for b in before]))
    parts = []
    for nm in ("curto_periodo", "fugoide", "dutch_roll"):
        lam0 = complex(before[k][f"re_{nm}"], before[k][f"im_{nm}"])
        lam1 = complex(after[k][f"re_{nm}"], after[k][f"im_{nm}"])
        if not all(np.isfinite([lam0.real, lam0.imag, lam1.real, lam1.imag])) or lam0.imag <= 0 or lam1.imag <= 0:
            continue
        zeta = lambda lam: -lam.real / abs(lam)
        parts.append(f"{MODE_LAB[nm]}: ζ {zeta(lam0):.2f} → {zeta(lam1):.2f}, ω_n {abs(lam0):.2f} → {abs(lam1):.2f}")
    if not parts:
        return None
    return ("info", item, "; ".join(parts), f"em V = {before[k]['V']:g} m/s", why, "")


class StabilitySimulation(SimulationBase):
    name = "stability"
    title = "Estabilidade"
    area = "estabilidade"
    show_aircraft = True
    # análise dinâmica, procura de correção e respostas no tempo: detalhado
    detailed = ("Vs_list", "whatif", "resp")
    description = ("Diz se a configuração é estável e controlável, por quê, e o que mudar: margem estática e "
                   "limites de CG, área de EH, estabilidade direcional e lateral, modos dinâmicos (MIL-F-8785C) e "
                   "tamanho dos comandos. Os campos e gráficos seguem a configuração da aeronave.")

    # ------------------------------------------------------------------ formulário pela aeronave
    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac, values=None):
        values = values or {}
        f = features(ac) if ac is not None else None
        Vc = _cruise_speed(ac) if ac is not None else 15.0
        vl = ", ".join(f"{v:g}" for v in np.round(np.linspace(0.75 * Vc, 1.5 * Vc, 7)))
        apl = ac.autopilot if ac is not None else None
        V_, C_, G_, A_ = "Voo", "Critérios de aprovação", "Faixa de CG", "Análises"
        ps = [ParamSpec("V", "velocidade de cruzeiro", round(Vc, 1), minimum=3, maximum=80, unit="m/s", group=V_),
              ParamSpec("CL_frac", "C_L no pouso", 0.9, minimum=0.3, maximum=1.0,
                        group=V_, help="fração do C_Lmax que o profundor tem de equilibrar no pouso")]
        if f is None or (f.gear and f.pitch):
            ps.append(ParamSpec("roll_takeoff", "decola rodando sobre o trem", True, kind="bool", group=V_,
                                help="desmarque se a aeronave é lançada à mão/catapulta: a rotação deixa de limitar o CG"))
            ps.append(ParamSpec("theta_dd", "aceleração de arfagem na rotação", 10.0, minimum=1, maximum=40,
                                unit="°/s²", group=V_, help="aceleração angular pedida no trem principal em V_R"))
        if f is None or f.yaw:
            ps.append(ParamSpec("Vw", "vento cruzado (−1: 0,2 V_S)", -1.0, minimum=-1, maximum=20, unit="m/s",
                                group=V_, help="−1 usa 0,2 V_S (FAR 23.233)"))
        # ---- critérios
        norm = values.get("norm", "MIL-F-8785C")
        ps.append(ParamSpec("norm", "critérios dos modos e da rolagem", "MIL-F-8785C", kind="choice",
                            choices=NORMS, group=C_, rebuild=True,
                            help="MIL-F-8785C: nível 1 pela classe e fase; personalizado: ligue e digite cada critério; "
                                 "nenhuma: só mostra os valores (a norma pode não valer para o tipo de aeronave)"))
        if norm == "personalizado":
            from aerosim.stability.criteria import FIELDS, GROUPS, mil_8785c
            base = mil_8785c("I", "B")
            lab_of = {k: (lab, unit) for k, lab, unit in FIELDS}
            for g, glab, fields in GROUPS:
                ps.append(ParamSpec(f"use_{g}", f"verificar {glab}", True, kind="bool", group=C_, rebuild=True))
                if values.get(f"use_{g}", True):
                    for k in fields:
                        lab, unit = lab_of[k]
                        ps.append(ParamSpec(f"crit_{k}", lab, getattr(base, k), minimum=0, unit=unit, group=C_))
        elif norm.startswith("nenhuma"):
            pass
        else:
            ps += [ParamSpec("cls", "classe do avião", "I", kind="choice", choices=("I", "II", "III", "IV"), group=C_,
                             help="I: pequeno e leve; II: médio; III: grande; IV: alta manobrabilidade"),
                   ParamSpec("cat", "fase de voo", "B", kind="choice", choices=("A", "B", "C"), group=C_,
                             help="A: manobras e precisão; B: subida, cruzeiro, descida; C: decolagem, aproximação, pouso")]
        ps += [ParamSpec("SM_min", "margem estática mínima", 5.0, minimum=0, maximum=40, unit="% CMA", group=C_,
                         help="limite traseiro do CG (Raymer cap. 16; Sadraey cap. 6)"),
               ParamSpec("SM_max", "margem estática máxima", 15.0, minimum=1, maximum=60, unit="% CMA", group=C_),
               ParamSpec("de_max", "curso máximo de arfagem", apl.de_max if apl else 20.0, minimum=1, maximum=60,
                         unit="°", group=C_)]
        if f is None or f.roll:
            ps.append(ParamSpec("da_max", "curso máximo de rolagem", apl.da_max if apl else 20.0, minimum=1, maximum=60,
                                unit="°", group=C_))
        if f is None or f.yaw:
            ps.append(ParamSpec("dr_max", "curso máximo do leme", apl.dr_max if apl else 25.0, minimum=1, maximum=60,
                                unit="°", group=C_))
        # ---- CG
        if f is None or not (f.payload or f.liquid):
            ps.append(ParamSpec("cg_var", "variação prevista do CG (±)", 2.0, minimum=0, maximum=30, unit="% CMA",
                                group=G_, help="sem carga lançável nem líquido, a variação do CG é informada"))
        else:
            ps.append(ParamSpec("cg_margin", "folga de CG (±)", 2.0, minimum=0, maximum=20,
                                unit="% CMA", group=G_, help="a variação com/sem carga e líquido é calculada"))
        # ---- análises que dependem da configuração
        if f is None or f.htail is not None:
            ps.append(ParamSpec("size_tail", "dimensionar o EH", True, kind="bool", group=A_, help="área do EH pela faixa de CG"))
        if f is not None and f.tailless:
            ps.append(ParamSpec("size_elevon", "dimensionar o elevon", True, kind="bool",
                                group=A_, help="corda × envergadura"))
            ps.append(ParamSpec("washout", "calcular a torção", True, kind="bool", group=A_, help="torção na ponta para C_m0 > 0"))
        if f is None or f.roll_kind == "aileron":
            ps.append(ParamSpec("eta_o", "aileron: fim (fração da semiasa)", 0.95, minimum=0.5, maximum=1.0, group=A_))
        ps += [ParamSpec("Vs_list", "velocidades da análise dinâmica", vl, kind="floats", unit="m/s", group=A_),
               ParamSpec("whatif", "procurar a correção", True, kind="bool", group=A_,
                         help="refaz a análise com deriva maior / mais diedro / EH maior para dizer quanto mudar"),
               ParamSpec("resp", "mostrar respostas no tempo", False, kind="bool", group=A_)]
        if f is not None and f.liquid:
            ps.append(ParamSpec("slosh_lin", "sloshing no modelo linear", False, kind="bool", group=A_,
                                help="refaz os polos com o líquido dos tanques oscilando (pêndulo equivalente, "
                                     "Abramson SP-106): aparecem os modos do líquido e quanto os do avião se deslocam"))
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac, values=None):
        f = features(ac) if ac is not None else None
        pitch = {"elevator": "profundor", "elevon": "elevon", "ruddervator": "cauda em V"}.get(
            f.pitch_kind if f else "elevator", "comando de arfagem")
        cg_x = "posição do CG (% da CMA, a partir do bordo de ataque)"
        ps = [PlotSpec("me", "Margem estática × posição do CG — onde o CG pode ficar", "cg", ("ME",), cg_x,
                       "margem estática (% CMA)", live=False, source="series:me_*"),
              PlotSpec("de", f"Deflexão do {pitch} para equilibrar × posição do CG (tracejado: fim do curso)", "cg",
                       ("δ",), cg_x, f"δ {pitch} (°)", live=False, source="series:de_*"),
              PlotSpec("cm", "Momento de arfagem × ângulo de ataque no CG — tem de descer (estável); "
                             "onde cruza o zero é o equilíbrio", "alpha", ("Cm",), "α (°)", "C_m", live=False,
                       source="series:cm_*"),
              PlotSpec("trim", f"{pitch.capitalize()} de equilíbrio × velocidade — deve crescer com V "
                               "(estável com o comando fixo)", "V", ("δ",), "V (m/s)", f"δ {pitch} (°)", live=False,
                       source="series:trim_*"),
              PlotSpec("cnb", "Guinada × derrapagem: C_n(β) tem de subir (volta ao vento)", "beta", ("Cn",), "β (°)",
                       "C_n", live=False, source="series:beta"),
              PlotSpec("clb", "Rolamento × derrapagem: C_l(β) tem de descer (efeito diedro)", "beta", ("Cl",), "β (°)",
                       "C_l", live=False, source="series:beta")]
        if f is None or f.htail is not None:
            ps.append(PlotSpec("eh", "Área do EH × posição do CG — a faixa de CG prevista tem de caber entre os limites",
                               "Sh_S", ("cg",), "área do EH / área da asa (S_h/S)", cg_x, live=False,
                               source="series:eh_*"))
        if f is None or f.tailless:
            ps += [PlotSpec("wo", "Asa voadora: C_m0 × torção na ponta — precisa ficar acima de zero", "tw", ("v",),
                            "torção extra na ponta (°, negativo = washout)", "C_m0", live=False, source="series:wo_*"),
                   PlotSpec("wc", "Asa voadora: C_L máximo equilibrado × torção na ponta", "tw", ("v",),
                            "torção extra na ponta (°)", "C_L equilibrado", live=False, source="series:wc_*"),
                   PlotSpec("es", "Asa voadora: C_L máximo equilibrado × tamanho do elevon", "eta", ("v",),
                            "início do elevon (fração da semiasa)", "C_L equilibrado", live=False,
                            source="series:es_*")]
        ps += [PlotSpec("zeta", "Amortecimento dos modos oscilatórios × V (tracejado: mínimo do nível 1)", "V", ("ζ",),
                        "V (m/s)", "ζ", live=False, source="series:z_*"),
               PlotSpec("tempo", "Rolamento (constante de tempo) e espiral (tempo para dobrar) × V", "V", ("t",),
                        "V (m/s)", "s", live=False, source="series:t_*"),
               PlotSpec("polos", "Polos dos modos", "re", ("im",),
                        "Re λ (1/s)", "Im λ (rad/s)", live=False, source="series:p_*"),
               PlotSpec("polos_lentos", "Polos lentos", "re", ("im",),
                        "Re λ (1/s)", "Im λ (rad/s)", live=False, source="series:q_*")]
        if f is not None and f.liquid and (values or {}).get("slosh_lin"):
            ps.append(PlotSpec("liquido", "Polos com o líquido",
                               "re", ("im",), "Re λ (1/s)", "Im λ (rad/s)", live=False, source="series:w_*"))
        if f is not None and f.payload:
            ps.append(PlotSpec("solta", "Polos ao soltar a carga", "re", ("im",),
                               "Re λ (1/s)", "Im λ (rad/s)", live=False, source="series:s_*"))
        if f is None or f.roll_kind == "aileron":
            ps.append(PlotSpec("ail", "Aileron: tempo para inclinar × onde o aileron começa (tracejado: requisito)",
                               "eta_i", ("t",), "início do aileron (fração da semiasa)", "t (s)", live=False,
                               source="series:ail_*"))
        if f is not None and f.roll_kind == "elevon":
            ps.append(PlotSpec("elv", "Elevon: curso para equilibrar + curso para rolar × V (tracejado: máximo)", "V",
                               ("δ",), "V (m/s)", "δ (°)", live=False, source="series:elv_*"))
        if f is None or (f.pitch_kind in ("elevator", "ruddervator")):
            ps.append(PlotSpec("prof", f"{pitch.capitalize()}: deflexão para pousar e rodar × corda móvel", "ce_c",
                               ("δ",), "corda móvel / corda da superfície", "δ (°)", live=False,
                               source="series:prof_*"))
        if f is None or f.yaw:
            ps.append(PlotSpec("leme", "Leme: deflexão em vento cruzado × corda do leme", "cr_c", ("δ",),
                               "corda do leme / corda da deriva", "δ (°)", live=False, source="series:leme_*"))
        ps += [PlotSpec("rlon", "Resposta a um doublet de 2° no comando de arfagem", "t", ("q", "theta", "u", "w"),
                        "t (s)", "°/s, °, m/s", live=False, source="series:resp_lon"),
               PlotSpec("rlat", "Resposta a um pulso de 5° no comando de rolagem", "t", ("p", "r", "phi", "v"), "t (s)",
                        "°/s, °, m/s", live=False, source="series:resp_lat")]
        return ps

    # ------------------------------------------------------------------ análise
    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        ac.apply_constraints()
        P = lambda k: self.param(ctx, k)
        f = features(ac)
        V = P("V")
        S_, summ, checks = {}, {}, []
        add = lambda *a, **k: checks.append(_short(Check(*a, **k)))
        pk = lambda k, d: ctx.params.get(k, d)
        de_max = math.radians(pk("de_max", ac.autopilot.de_max))
        da_max = math.radians(pk("da_max", ac.autopilot.da_max))
        dr_max = math.radians(pk("dr_max", ac.autopilot.dr_max))
        SM_min, SM_max = P("SM_min"), P("SM_max")
        crit = _criteria(ctx.params)
        summ["critérios"] = crit.source
        if not f.pitch:
            checks.append(Check("falha", "comando de arfagem", "nenhum", "profundor, elevon ou cauda em V",
                                "sem EH e sem elevon não há como equilibrar nem controlar em arfagem",
                                "transformar os ailerons em elevons (Configuração → asa → comandos → tipo 'elevon') "
                                "ou adicionar uma EH", "estática longitudinal"))
        summ["configuração"] = f.summary()
        if f.wing is None:
            return SimResult(summary=summ, checks=[Check("falha", "asa", "nenhuma", "a aeronave precisa de uma asa")])
        pitch_name = {"elevator": "profundor", "elevon": "elevon", "ruddervator": "cauda em V"}.get(f.pitch_kind, "—")

        # ============ 1. estática longitudinal
        ctx.on_progress(0.02, "estática longitudinal")
        model = build_model(ac)          # o modelo universal (as variações abaixo criam outros)
        with Probe(ctx.backend, model) as pr:
            c = pr.c
            mm = lambda pct: abs(pct) / 100 * c * 1000
            CLmax, Vs = stall_speed(pr)
            V_land = 1.3 * Vs
            CL_land = P("CL_frac") * CLmax
            VR = (ac.takeoff.VR if ac.takeoff.VR > 0 else 1.1 * Vs) if (f.gear and f.pitch) else None
            summ["C_Lmax, V_estol, V_pouso (1,3 V_S)"] = [CLmax, Vs, V_land]
            cg_now = pr.frac(pr.cg[0])
            conds = {"atual": cg_now}
            if f.payload:
                a2 = ac.copy()
                a2.payload.enabled = False
                with Probe(ctx.backend, a2) as p2:
                    conds["sem carga"] = p2.frac(p2.cg[0])
            if f.liquid:
                a2 = ac.copy()
                a2.tanks = []
                with Probe(ctx.backend, a2) as p2:
                    conds["sem líquido"] = p2.frac(p2.cg[0])
                if f.payload:
                    a2.payload.enabled = False
                    with Probe(ctx.backend, a2) as p2:
                        conds["sem carga e sem líquido"] = p2.frac(p2.cg[0])
            if f.payload or f.liquid:
                m = P("cg_margin")
                cg_lo, cg_hi = min(conds.values()) - m, max(conds.values()) + m
            else:
                m = P("cg_var")
                cg_lo, cg_hi = cg_now - m, cg_now + m
            summ["CG nas condições (% CMA)"] = {k: round(v, 2) for k, v in conds.items()}
            summ["faixa de CG prevista (% CMA)"] = [cg_lo, cg_hi]

            x_np = pr.neutral_point(V)
            np_pct = pr.frac(x_np)
            an = analytic_np(model)
            SM = np_pct - cg_now
            summ["ponto neutro: núcleo, analítico (% CMA)"] = [np_pct, pr.frac(an["x_np"])]
            summ["margem estática no CG atual (% CMA)"] = SM
            grid = np.linspace(min(cg_lo, np_pct - 45) - 5, np_pct + 8, 45)
            sw = cg_sweep(pr, grid, V, V_land, CL_land, VR, P("theta_dd") if VR else 10.0)
            dmax = math.degrees(de_max)
            fwd_land = limit_crossing(sw["cg"], sw["de_pouso"], dmax)
            fwd_rot = limit_crossing(sw["cg"], sw["de_rotacao"], dmax) if VR else None
            fwd_cru = limit_crossing(sw["cg"], sw["de_cruzeiro"], dmax)
            use_rot = bool(VR) and bool(P("roll_takeoff"))
            fwd = max([v for v in (fwd_land, fwd_rot if use_rot else None, fwd_cru) if v is not None], default=None)
            aft = np_pct - SM_min
            summ["limites de CG: dianteiro, traseiro (% CMA)"] = [fwd, aft]
            # séries
            lo_hi = (float(sw["cg"][0]), float(sw["cg"][-1]))
            S_["me_margem estática"] = {"cg": sw["cg"], "ME": sw["ME"]}
            S_[f"me_mínima ({SM_min:g} %)"] = {"cg": np.array(lo_hi), "ME": np.full(2, SM_min), "_dash": 1}
            S_[f"me_máxima recomendada ({SM_max:g} %)"] = {"cg": np.array(lo_hi), "ME": np.full(2, SM_max), "_dash": 1}
            yr = (float(np.nanmin(sw["ME"])), float(np.nanmax(sw["ME"])))
            for k, v in conds.items():
                S_[f"me_CG {k}"] = {"cg": np.array([v, v]), "ME": np.array(yr)}
            S_[f"de_pouso (C_L = {CL_land:.2f})"] = {"cg": sw["cg"], "δ": sw["de_pouso"]}
            S_[f"de_cruzeiro (V = {V:g} m/s)"] = {"cg": sw["cg"], "δ": sw["de_cruzeiro"]}
            if VR:
                S_[f"de_rotação (V_R = {VR:.1f} m/s)"] = {"cg": sw["cg"], "δ": sw["de_rotacao"]}
            S_["de_fim do curso"] = {"cg": np.array(lo_hi), "δ": np.full(2, -dmax), "_dash": 1}
            S_["de_fim do curso (picar)"] = {"cg": np.array(lo_hi), "δ": np.full(2, dmax), "_dash": 1}
            allv = np.concatenate([sw["de_pouso"], sw["de_cruzeiro"], [-dmax, dmax]])
            dr_ = (float(np.nanmin(allv)), float(np.nanmax(allv)))
            S_["de_CG atual"] = {"cg": np.array([cg_now, cg_now]), "δ": np.array(dr_)}

            for lab, v in (("limite dianteiro", fwd), ("limite traseiro", aft)):
                if v is not None:
                    S_[f"me_{lab} ({v:.1f} %)"] = {"cg": np.array([v, v]), "ME": np.array(yr), "_dash": 1}
                    S_[f"de_{lab} ({v:.1f} %)"] = {"cg": np.array([v, v]), "δ": np.array(dr_), "_dash": 1}
            # --- diagnóstico: margem no CG atual
            G = "estática longitudinal"
            crit_sm = f"{SM_min:g} % ≤ ME ≤ {SM_max:g} % da CMA (Raymer cap. 16; Sadraey cap. 6)"
            val = f"{SM:.1f} % (CG {cg_now:.1f} %, ponto neutro {np_pct:.1f} %)"
            if SM < 0:
                add("falha", "margem estática no CG atual", val, crit_sm,
                    f"o CG está {mm(SM):.0f} mm atrás do ponto neutro: um aumento de α gera momento cabrador e o "
                    "avião diverge em arfagem",
                    f"levar o CG {mm(SM - SM_min):.0f} mm para frente (até {aft:.1f} % da CMA) ou aumentar o "
                    + ("EH/braço da cauda (ver área do EH abaixo)" if f.htail else "enflechamento/torção da ponta"), G)
            elif SM < SM_min:
                add("atencao", "margem estática no CG atual", val, crit_sm,
                    "estável, mas pouca margem: rajadas e erro de CG podem deixá-lo neutro",
                    f"levar o CG {mm(SM_min - SM):.0f} mm para frente (até {aft:.1f} %)", G)
            elif SM > SM_max:
                add("atencao", "margem estática no CG atual", val, crit_sm,
                    f"estável demais: o {pitch_name} gasta curso para equilibrar e o avião fica pesado no comando",
                    f"o CG pode ir {mm(SM - SM_max):.0f} mm para trás (até {np_pct - SM_max:.1f} %)", G)
            else:
                add("ok", "margem estática no CG atual", val, crit_sm, group=G)
            dn = abs(np_pct - pr.frac(an["x_np"]))
            if dn > 8:
                add("info", "ponto neutro: núcleo × fórmula clássica", f"{np_pct:.1f} % × {pr.frac(an['x_np']):.1f} %",
                    "diferença > 8 % da CMA",
                    "a fórmula (Etkin/Nelson) usa dε/dα da teoria e ignora interação da fuselagem com a asa; o núcleo "
                    "usa a mesma física da simulação", "", G)
            # --- faixa de CG
            if fwd is None:
                add("falha", "limite dianteiro do CG", "nenhum CG equilibra",
                    f"|δ {pitch_name}| ≤ {dmax:g}° no pouso, cruzeiro e rotação",
                    f"o {pitch_name} não tem autoridade para equilibrar em nenhuma posição de CG analisada",
                    f"aumentar a área/corda do {pitch_name} ou o braço; ou rever δ máximo ({dmax:g}°)", G)
            else:
                why_f = ("equilibrar o pouso" if fwd == fwd_land else
                         "rodar na decolagem" if fwd == fwd_rot else "equilibrar o cruzeiro")
                rng = f"permitido {fwd:.1f} … {aft:.1f} %; previsto {cg_lo:.1f} … {cg_hi:.1f} %"
                crit2 = f"dianteiro: {pitch_name} no fim do curso ({dmax:g}°); traseiro: margem {SM_min:g} %"
                problems = []
                if cg_lo < fwd:
                    problems.append(f"o CG mais dianteiro previsto ({cg_lo:.1f} %) está {mm(fwd - cg_lo):.0f} mm à frente "
                                    f"do limite: o {pitch_name} não consegue {why_f}")
                if cg_hi > aft:
                    problems.append(f"o CG mais traseiro previsto ({cg_hi:.1f} %) está {mm(cg_hi - aft):.0f} mm atrás do "
                                    f"limite de margem mínima")
                if aft <= fwd:
                    fix = (f"não existe CG que atenda os dois limites: o limite dianteiro ({why_f}, {fwd:.1f} %) está atrás "
                           f"do traseiro ({aft:.1f} %). Ver os itens de pouso/rotação abaixo")
                elif aft - fwd < cg_hi - cg_lo:
                    fix = (f"a faixa permitida ({aft - fwd:.1f} %) é menor que a prevista ({cg_hi - cg_lo:.1f} %): "
                           + ("aumentar o EH (ver área do EH) ou o comando de arfagem" if f.htail else
                              "reduzir a variação do CG (posição dos tanques/carga perto do CG) ou aumentar o elevon"))
                elif problems:
                    mid_shift = ((fwd + aft) / 2 - (cg_lo + cg_hi) / 2)
                    fix = (f"a faixa cabe: deslocar todo o CG {mm(mid_shift):.0f} mm "
                           f"{'para trás' if mid_shift > 0 else 'para frente'} centraliza a faixa prevista")
                else:
                    fix = ""
                add("falha" if problems else "ok", "faixa de CG prevista dentro da permitida", rng, crit2,
                    "; ".join(problems), fix, G)
            # --- C_L máximo equilibrado (no CG mais dianteiro previsto) e pouso
            xf = pr.x_of(cg_lo)
            CLt = trimmed_CLmax(pr, V_land, xf, de_max)
            if np.isfinite(CLt):
                Vs_t = math.sqrt(2 * pr.W / (pr.rho * pr.S * CLt))
                summ["C_Lmax equilibrado (CG dianteiro), V_estol equilibrada"] = [CLt, Vs_t]
                st = "ok" if CLt >= CL_land else ("atencao" if CLt >= 0.75 * CL_land else "falha")
                add(st, f"C_L de pouso equilibrado pelo {pitch_name} (CG {cg_lo:.1f} %)",
                    f"máx. {CLt:.2f} (pedido {CL_land:.2f} = {P('CL_frac'):g} C_Lmax); V_estol equilibrada {Vs_t:.1f} m/s",
                    f"C_L equilibrado ≥ C_L de pouso com |δ| ≤ {dmax:g}°",
                    "" if st == "ok" else (f"para equilibrar, o {pitch_name} cabra e " +
                                           ("tira sustentação da própria asa (asa voadora)" if f.tailless else
                                            "a força para baixo no EH cresce") + "; o comando chega ao fim do curso antes"),
                    "" if st == "ok" else (f"pousar com C_L ≤ {CLt:.2f} (V de pouso ≥ 1,3 × {Vs_t:.1f} = {1.3 * Vs_t:.1f} m/s), "
                                           "levar o CG para trás ou aumentar o comando de arfagem"), G)
            if VR:
                d_now = math.degrees(rotation_de(pr, VR, pr.cg[0], P("theta_dd")))
                ok_r = abs(d_now) <= dmax
                why = fix = ""
                if not ok_r:
                    xg, xtip = gear_x_for_rotation(pr, VR, pr.cg[0], P("theta_dd"), de_max)
                    tp = pr.main_gear()
                    why = (f"o peso à frente do trem principal ({1000 * (pr.cg[0] - tp[0]):.0f} mm) e o "
                           + ("braço curto do elevon (sem cauda)" if f.tailless else "momento do EH") +
                           " não vencem; θ̈ pedido " + f"{P('theta_dd'):g} °/s²")
                    if xg is not None and xg <= xtip:
                        fix = (f"trem principal {1000 * (xg - tp[0]):+.0f} mm (x = {xg:.3f} m) já roda; limite de "
                               f"tombamento para trás (15°) em x = {xtip:.3f} m")
                    else:
                        fix = ("nem o trem no limite de tombamento resolve: lançar à mão/catapulta (desmarcar 'decola rodando'), "
                               "aumentar V_R ou o comando de arfagem")
                add("ok" if ok_r else "falha", f"rotação na decolagem em V_R = {VR:.1f} m/s",
                    f"δ = {d_now:.1f}° no CG atual", f"|δ| ≤ {dmax:g}° com θ̈ = {P('theta_dd'):g} °/s² no trem principal",
                    why, fix, G)
            # --- curva de equilíbrio × V
            Vt = np.arange(max(1.05 * Vs, 3.0), max(floats(P("Vs_list")) + [V]) + 0.01, 0.5)
            rows = [pr.s.trim(0, v) for v in Vt]
            ok = np.array([r["ok"] for r in rows])
            de_t = np.degrees([r["de"] for r in rows])
            S_["trim_equilíbrio"] = {"V": Vt, "δ": np.where(ok, de_t, np.nan)}
            if ok.sum() >= 2:
                g = float(np.polyfit(Vt[ok], de_t[ok], 1)[0])
                add("ok" if g > 0 else "falha", f"{pitch_name} de equilíbrio cresce com V", f"dδ/dV = {g:.2f} °/(m/s)",
                    "dδ/dV > 0 (Etkin & Reid: estabilidade com o comando fixo)",
                    "" if g > 0 else "para acelerar o piloto teria de cabrar: sinal de margem negativa",
                    "" if g > 0 else "ver margem estática", G)
                sat = Vt[ok & (np.abs(de_t) > dmax)]
                if len(sat):
                    add("falha", f"{pitch_name} satura em voo nivelado", f"{len(sat)} velocidades (ex.: {sat[0]:.1f} m/s)",
                        f"|δ| ≤ {dmax:g}°", "o equilíbrio pede mais deflexão do que existe",
                        "mover o CG para trás ou aumentar a autoridade de arfagem", G)
            # C_m(α)
            al = np.arange(-6.0, 20.01, 0.5)
            for lab, d in (("neutro", 0.0), ("cabrar máximo", -de_max), ("picar máximo", de_max)):
                S_[f"cm_{pitch_name} {lab}"] = {"alpha": al,
                                                "Cm": np.array([pr.C(V, math.radians(x), de=d)["Cm"] for x in al])}
            if f.tailless:
                aL = None
                for x in np.arange(-8, 10, 0.05):
                    if pr.C(V, math.radians(x))["CL"] >= 0:
                        aL = math.radians(x)
                        break
                Cm0 = pr.C(V, aL)["Cm"] if aL is not None else float("nan")
                add("ok" if Cm0 > 0 else "falha", "asa voadora: C_m na sustentação nula (C_m0)", f"{Cm0:.4f}",
                    "C_m0 > 0 para equilibrar com C_L > 0 e ser estável sem cauda (Nickel & Wohlfahrt, Tailless Aircraft)",
                    "" if Cm0 > 0 else "o perfil/torção dá momento picador: para voar estável o elevon fica cabrado e "
                    "come curso de rolagem",
                    "" if Cm0 > 0 else "perfil reflexo, mais torção negativa na ponta (washout) ou mais enflechamento", G)
            else:
                tv = pr.model.tail_volumes(pr.cg[0])
                vh_t, vv_t = RAYMER_TAIL_VOLUME["experimental (homebuilt)"]
                summ["volumes de cauda V_H, V_V"] = [tv["VH"], tv["VV"]]
                add("info", "volume de cauda horizontal V_H", f"{tv['VH']:.3f}",
                    f"típicos (Raymer tab. 6.4): planador 0,50, experimental 0,50, aviação geral 0,70",
                    "referência histórica de partida; quem decide é a margem e os limites de CG acima", "", G)

            # ============ 3. estática látero-direcional
            ctx.on_progress(0.25, "estática látero-direcional")
            G = "estática látero-direcional"
            bet = np.arange(-15, 15.01, 1.0)
            cb = [pr.C(V, math.radians(2), math.radians(b)) for b in bet]
            S_["beta"] = {"beta": bet, "Cn": np.array([x["Cn"] for x in cb]), "Cl": np.array([x["Cl"] for x in cb])}
            a2 = math.radians(2)
            Cnb = pr.deriv(V, a2, "beta", ("Cn",))["Cn"]
            Clb = pr.deriv(V, a2, "beta", ("Cl",))["Cl"]
            hb = 0.01 * 2 * V / pr.b
            Cnr = pr.deriv(V, a2, "r", ("Cn",), step=hb)["Cn"] * 2 * V / pr.b
            Clr = pr.deriv(V, a2, "r", ("Cl",), step=hb)["Cl"] * 2 * V / pr.b
            fins = [s.name for s in (f.vtail or f.tip_devices)]
            fin_word = "deriva" if f.vtail else ("winglets/derivas de ponta" if f.tip_devices else "deriva")
            if Cnb > 0:
                add("ok", "estabilidade direcional C_nβ", f"{Cnb:.4f} /rad", "C_nβ > 0 (cata-vento)", group=G)
            else:
                k_need = None
                if fins:
                    for k in (1.25, 1.5, 1.75, 2.0, 2.5, 3.0):
                        with Probe(ctx.backend, scale_surfaces(ac, fins, k)) as p3:
                            if p3.deriv(V, a2, "beta", ("Cn",))["Cn"] > 0:
                                k_need = k
                                break
                add("falha", "estabilidade direcional C_nβ", f"{Cnb:.4f} /rad", "C_nβ > 0 (cata-vento)",
                    f"a fuselagem ({ac.fuselage.Cnb:+.3f}/rad) e o resto desestabilizam mais do que a {fin_word} estabiliza",
                    (f"área da {fin_word} × {k_need:g} (mesma razão de aspecto) já dá C_nβ > 0" if k_need else
                     f"aumentar a {fin_word} (área ou braço)"), G)
            add("ok" if Clb < 0 else "falha", "efeito diedro C_lβ", f"{Clb:.4f} /rad", "C_lβ < 0",
                "" if Clb < 0 else "derrapar para um lado faz o avião rolar para o mesmo lado",
                "" if Clb < 0 else "mais diedro, asa alta ou enflechamento", G)
            E = Clb * Cnr - Cnb * Clr
            add("ok" if E > 0 else "info", "critério da espiral C_lβ C_nr − C_nβ C_lr", f"{E:.5f}",
                "> 0: espiral estável (Nelson, Flight Stability, cap. 5; Etkin & Reid)",
                "" if E > 0 else "efeito diedro fraco diante da estabilidade direcional: inclinado, o avião tende a "
                "fechar a curva sozinho (ver o tempo para dobrar na dinâmica — pode ser aceitável)", "", G)

            # ============ 5a. comandos (rolagem, profundor, leme) — usam a sonda
            ctx.on_progress(0.35, "comandos")
            G = "comandos"
            phi_req, t_req = crit.roll_phi, crit.roll_t
            Vroll = V_land if crit.cat == "C" else V
            if f.roll_kind == "aileron":
                o, s_ = aileron_sizing(pr, Vroll, crit.cls, crit.cat, da_max, P("eta_o"), req=(phi_req, t_req))
                for k in [k for k in s_ if k.startswith("t_")]:
                    S_[f"ail_{k[2:]}"] = {"eta_i": s_["eta_i"], "t": s_[k]}
                S_["ail_requisito"] = {"eta_i": s_["eta_i"], "t": s_["requisito"], "_dash": 1}
                Pss, tb = o.get("aileron atual: P_ss (°/s), t (s)", [float("nan"), float("nan")])
                crit_r = f"{phi_req:g}° em ≤ {t_req:g} s (δa {math.degrees(da_max):g}°)"
                if not crit.on("roll"):
                    add("info", f"aileron: tempo para inclinar {phi_req:g}°", f"{tb:.2f} s (p = {Pss:.0f} °/s)", "—",
                        group=G)
                elif tb <= t_req:
                    add("ok", "aileron: rolagem", f"{tb:.2f} s (p = {Pss:.0f} °/s a {Vroll:.1f} m/s)", crit_r, group=G,
                        source=crit.source)
                else:
                    best = [(k, v) for k, v in o.items() if k.startswith("η_i máximo") and np.isfinite(v)]
                    fx = "; ".join(f"{k.split('(')[1].split(',')[0]}: começar em {v:.2f} da semiasa" for k, v in best)
                    add("falha", "aileron: rolagem", f"{tb:.2f} s", crit_r,
                        "C_lδa pequeno diante do amortecimento C_lp (aileron curto, perto da raiz ou corda pequena)",
                        fx or "aumentar corda/envergadura do aileron ou o curso", G, source=crit.source)
            elif f.roll_kind == "elevon":
                # elevon: o curso é dividido entre equilibrar (arfagem) e rolar
                surf, ctl = f.roll
                Clp = pr.deriv(Vroll, a2, "p", ("Cl",), step=0.01 * 2 * Vroll / pr.b)["Cl"] * 2 * Vroll / pr.b
                Clda = pr.deriv(Vroll, a2, "da", ("Cl",))["Cl"]
                Vl = np.linspace(max(1.1 * Vs, 3), 1.5 * V, 12)
                trim_d, roll_d = [], []
                for v in Vl:
                    tp_ = pr.s.trim(0, v)
                    trim_d.append(abs(math.degrees(tp_["de"])) if tp_["ok"] else np.nan)
                    q = 0.5 * pr.rho * v * v
                    tau = -2 * v * pr.I[0, 0] / (q * pr.S * pr.b ** 2 * Clp)
                    lo_, hi_ = 0.0, math.radians(60)
                    for _ in range(40):
                        md = 0.5 * (lo_ + hi_)
                        Pss = -(Clda / Clp) * md * 2 * v / pr.b
                        if time_to_bank(Pss, tau, math.radians(phi_req)) > t_req:
                            lo_ = md
                        else:
                            hi_ = md
                    roll_d.append(math.degrees(hi_))
                trim_d, roll_d = np.array(trim_d), np.array(roll_d)
                tot = trim_d + roll_d
                S_["elv_equilíbrio"] = {"V": Vl, "δ": trim_d}
                S_["elv_rolagem exigida"] = {"V": Vl, "δ": roll_d}
                S_["elv_soma"] = {"V": Vl, "δ": tot}
                S_["elv_máximo"] = {"V": Vl, "δ": np.full(len(Vl), math.degrees(da_max)), "_dash": 1}
                bad = Vl[np.isfinite(tot) & (tot > math.degrees(da_max))]
                crit_e = f"equilíbrio + rolagem ({phi_req:g}° em {t_req:g} s) ≤ {math.degrees(da_max):g}°"
                if not crit.on("roll"):
                    add("info", "elevon: curso usado no equilíbrio", f"máx. {np.nanmax(trim_d):.1f}° de "
                        f"{math.degrees(da_max):g}°", "—", group=G)
                elif len(bad):
                    add("falha", "elevon: curso para arfagem + rolagem", f"excede de {bad.min():.1f} a {bad.max():.1f} m/s",
                        crit_e, "nessas velocidades o equilíbrio come o curso que a rolagem precisa",
                        "elevon com mais corda/envergadura, CG mais para trás (menos δ de equilíbrio) ou C_m0 maior "
                        "(reflexo/washout)", G)
                else:
                    add("ok", "elevon: curso para arfagem + rolagem", f"máx. {np.nanmax(tot):.1f}° de "
                        f"{math.degrees(da_max):g}°", crit_e, group=G)
            else:
                add("falha", "comando de rolagem", "nenhum", "aileron ou elevon", "", "adicionar ailerons", G)
            if f.pitch_kind in ("elevator", "ruddervator") and VR:
                o, s_ = elevator_sizing(pr, V_land, VR, cg_lo, CL_land, de_max, P("theta_dd"))
                if s_:
                    S_["prof_pouso"] = {"ce_c": s_["ce_c"], "δ": s_.get("de_pouso", np.full(len(s_["ce_c"]), np.nan))}
                    S_["prof_rotação"] = {"ce_c": s_["ce_c"], "δ": s_["de_rotacao"]}
                    S_["prof_fim do curso"] = {"ce_c": s_["ce_c"], "δ": s_["de_max"], "_dash": 1}
                    cur = f.pitch[1].chord_frac
                    mn = o.get("menor c_e/c que cumpre (δe ≤ máx.)", float("nan"))
                    st = "ok" if np.isfinite(mn) and cur >= mn else "falha"
                    add(st, f"{pitch_name}: corda móvel (CG mais dianteiro {cg_lo:.1f} %)",
                        f"atual {cur:.2f}; mínima {_fmt(mn)}", f"δ para pousar e rodar ≤ {dmax:g}°",
                        "" if st == "ok" else "com o CG mais dianteiro previsto o comando não equilibra/roda",
                        "" if st == "ok" else (f"corda móvel ≥ {mn:.2f}" if np.isfinite(mn) else
                                               "nenhuma corda basta: aumentar a área do EH ou trazer o CG para trás"), G)
            if f.yaw:
                Vw = P("Vw") if P("Vw") >= 0 else 0.2 * Vs
                o, s_ = rudder_sizing(pr, V_land, Vw, 1.2 * Vs, dr_max)
                if s_:
                    S_["leme_vento cruzado"] = {"cr_c": s_["cr_c"], "δ": s_["dr_vento"]}
                    if "dr_motor_parado" in s_:
                        S_["leme_motor crítico parado"] = {"cr_c": s_["cr_c"], "δ": s_["dr_motor_parado"]}
                    S_["leme_fim do curso"] = {"cr_c": s_["cr_c"], "δ": s_["dr_max"], "_dash": 1}
                    need = o.get("δr p/ vento cruzado (atual, °)", float("nan"))
                    st = "ok" if need <= math.degrees(dr_max) else "falha"
                    add(st, "leme: vento cruzado no pouso", f"δr = {need:.1f}° (β = {o['β de vento cruzado (°)']:.1f}°, "
                        f"vento {Vw:.1f} m/s)", f"δr ≤ {math.degrees(dr_max):g}° com 0,2 V_S de través (FAR 23.233)",
                        "" if st == "ok" else "a deriva é estável demais para o leme que tem",
                        "" if st == "ok" else f"corda do leme ≥ {o.get('menor c_r/c que cumpre (δr ≤ máx.)', float('nan')):.2f}", G)
            elif not f.tailless or f.tip_devices:
                add("info", "leme", "nenhum", "", "sem leme a guinada é corrigida só pela rolagem; vento cruzado no pouso "
                    "fica por conta do piloto (caranguejo)", "", "comandos")

        # ============ 2b. asa voadora: torção na ponta e tamanho do elevon
        if f.tailless and f.wing is not None:
            self._tailless(ctx, ac, f, P, S_, summ, add, V, V_land, CL_land, cg_lo, de_max, da_max, crit)

        # ============ 2. área do EH
        if f.htail is not None and P("size_tail"):
            ctx.on_progress(0.45, "área do EH × faixa de CG")
            names = [s.name for s in ac.surfaces if s.role == "htail" and s.enabled]
            sc = scissor(ctx.backend, ac, V, SM_min / 100, P("CL_frac"), de_max, VR or 1.1 * Vs,
                         P("theta_dd") if VR else 0.0)
            S_["eh_limite dianteiro (pouso)"] = {"Sh_S": sc["Sh_S"], "cg": sc["fwd_ctrl"]}
            if VR:
                S_["eh_limite dianteiro (rotação)"] = {"Sh_S": sc["Sh_S"], "cg": sc["fwd_rot"]}
            S_[f"eh_limite traseiro (margem {SM_min:g} %)"] = {"Sh_S": sc["Sh_S"], "cg": sc["aft"]}
            S_["eh_ponto neutro"] = {"Sh_S": sc["Sh_S"], "cg": sc["np"], "_dash": 1}
            for lab, v in (("CG mais dianteiro previsto", cg_lo), ("CG mais traseiro previsto", cg_hi)):
                S_[f"eh_{lab}"] = {"Sh_S": sc["Sh_S"][[0, -1]], "cg": np.full(2, v), "_dash": 1}
            i1 = int(np.argmin(np.abs(sc["k"] - 1.0)))
            sh_now = float(sc["Sh_S"][i1])
            if not VR:
                sc["fwd"] = sc["fwd_ctrl"]
            smin = min_tail(sc, cg_lo, cg_hi)
            summ["S_h/S: atual, mínimo para a faixa de CG"] = [sh_now, smin]
            G = "área do EH"
            if not np.isfinite(smin):
                add("falha", "área do EH para a faixa de CG", f"atual {sh_now:.3f}; nenhuma até {sc['Sh_S'][-1]:.3f}",
                    "a faixa prevista cabe entre os limites dianteiro e traseiro",
                    "a faixa de CG prevista é larga demais para qualquer EH analisado (ou o comando é fraco)",
                    "reduzir a variação do CG (tanques/carga perto do CG) ou aumentar o braço da cauda", G)
            elif smin > sh_now:
                add("falha", "área do EH para a faixa de CG", f"atual {sh_now:.3f} < mínimo {smin:.3f}",
                    "a faixa prevista cabe entre os limites (Torenbeek cap. 9; Sadraey cap. 6)",
                    "com o EH atual a faixa de CG prevista não cabe entre estabilidade e controle",
                    f"aumentar a área do EH em {100 * (smin / sh_now - 1):.0f} % (S_h/S ≥ {smin:.3f}) ou o braço", G)
            else:
                add("ok", "área do EH para a faixa de CG", f"atual {sh_now:.3f} ≥ mínimo {smin:.3f}",
                    "a faixa prevista cabe entre os limites (Torenbeek cap. 9; Sadraey cap. 6)",
                    f"sobra {100 * (1 - smin / sh_now):.0f} % de área" if sh_now > 1.3 * smin else "",
                    f"dá para reduzir o EH até S_h/S = {smin:.3f} (menos arrasto e massa)" if sh_now > 1.3 * smin else "",
                    G)

        # ============ 4. dinâmica
        G = "dinâmica"
        Vlist = floats(P("Vs_list"))
        rows = []
        for k, v in enumerate(Vlist):
            ctx.check()
            ctx.on_progress(0.6 + 0.25 * k / max(len(Vlist), 1), f"modelo linear em V = {v:.1f} m/s")
            md, lm = modes_at(ctx.backend, ac, v)
            if md is None:
                continue
            r = {"V": v}
            for nm in MODE_LAB:
                mm_ = md.get(nm) or {}
                r[f"z_{nm}"] = mm_.get("zeta", np.nan) if mm_.get("im", 0) > 0 else np.nan
            for nm in MODE_LAB:                           # o polo de cada modo (a metade de cima do plano)
                mm_ = md.get(nm) or {}
                r[f"re_{nm}"], r[f"im_{nm}"] = mm_.get("re", np.nan), mm_.get("im", np.nan)
            r["tau_r"] = (md.get("rolamento") or {}).get("tau", np.nan)
            es = md.get("espiral") or {}
            r["t2"] = es.get("t_double", np.nan) if es.get("re", -1) > 0 else np.nan
            rows.append(r)
        if rows:
            Vv = np.array([r["V"] for r in rows])
            for nm, lim in (("curto_periodo", crit.sp_zeta_min), ("fugoide", crit.ph_zeta_min),
                            ("dutch_roll", crit.dr_zeta_min)):
                S_[f"z_{MODE_LAB[nm]}"] = {"V": Vv, "ζ": np.array([r[f"z_{nm}"] for r in rows])}
                S_[f"z_mínimo {MODE_LAB[nm]}"] = {"V": Vv[[0, -1]], "ζ": np.full(2, lim), "_dash": 1}
            S_["t_rolamento τ"] = {"V": Vv, "t": np.array([r["tau_r"] for r in rows])}
            S_["t_espiral: tempo para dobrar"] = {"V": Vv, "t": np.array([r["t2"] for r in rows])}
            S_["t_espiral mínimo"] = {"V": Vv[[0, -1]], "t": np.full(2, crit.spiral_t2_min), "_dash": 1}
            S_["t_rolamento máximo"] = {"V": Vv[[0, -1]], "t": np.full(2, crit.roll_tau_max), "_dash": 1}
            S_.update(_pole_series(rows, crit))
            S_.update(_pole_series(rows, crit, SLOW_MODES, "q_"))
        if f.liquid and P("slosh_lin") and rows:        # os mesmos polos com o líquido oscilando
            ctx.on_progress(0.83, "modelo linear com o líquido oscilando")
            moving, liquid = [], []
            for r in rows:
                ctx.check()
                found, rest = _match_poles(r, slosh_eigs_at(ctx.backend, ac, r["V"]))
                moving.append(found)
                liquid += [(r["V"], lam) for lam in rest]
            S_.update(_release_series(rows, moving, "w_", ("parado", "oscilando")))
            if liquid:
                S_["w_líquido"] = {"re": np.array([lam.real for _, lam in liquid]),
                                     "im": np.array([lam.imag for _, lam in liquid]), "_symbol": "star",
                                     "_color": "#17becf", "_size": 14}
            shifted = _release_check(rows, moving, V, "polos com o líquido oscilando",
                                     "o líquido que oscila troca forças com o avião e desloca os modos (gráfico "
                                     "'Polos com o líquido')")
            if shifted is not None:
                k = int(np.argmin([abs(r["V"] - V) for r in rows]))
                own = [lam for v_, lam in liquid if v_ == rows[k]["V"]]
                if own:
                    lam = max(own, key=lambda l: l.imag)
                    shifted = shifted[:4] + (shifted[4] + f"; o líquido: ω_n = {abs(lam):.1f} rad/s, ζ = "
                                             f"{-lam.real / abs(lam):.3f}",) + shifted[5:]
                add(*shifted, G)
        if f.payload and rows:                            # os mesmos polos sem a carga (logo depois da soltura)
            ctx.on_progress(0.85, "modelo linear sem a carga")
            dropped = ac.copy()
            dropped.payload.enabled = False
            after = []
            for r in rows:
                ctx.check()
                md_after, _ = modes_at(ctx.backend, dropped, r["V"])
                after.append({f"{part}_{nm}": (md_after or {}).get(nm, {}).get(part, np.nan)
                              for nm in MODE_LAB for part in ("re", "im")})
            S_.update(_release_series(rows, after))
            checks_release = _release_check(rows, after, V)
            if checks_release is not None:
                add(*checks_release, G)
        md, lm = modes_at(ctx.backend, ac, V)
        if md is None:
            add("falha", "equilíbrio em voo nivelado", f"não convergiu em {V:g} m/s", "trimagem do núcleo",
                "sem equilíbrio não há modelo linear: falta tração, ou o comando de arfagem satura",
                "ver a faixa de CG e a curva de equilíbrio acima; testar outra velocidade", G)
        else:
            for row in evaluate(md, crit):
                lvl = row["nivel"]
                if row["ok"] is None:
                    st = "info"
                elif row["ok"]:
                    st = "ok"
                else:
                    st = "atencao" if lvl == 2 else "falha"
                why, fix = _mode_advice(row["criterio"], st, f, fin_word) if st in ("falha", "atencao") else ("", "")
                if st in ("falha", "atencao") and P("whatif"):
                    fix = _whatif(ctx, ac, f, V, row["criterio"], crit, fins) or fix
                val = _fmt(row["valor"]) + (f" (nível {lvl if lvl < 4 else '>3'})" if lvl else "")
                add(st, row["criterio"], val, row["limite"], why, fix, G, source=crit.source)
            for nm, m_ in md.items():
                if m_ and m_.get("im", 0) > 0:
                    summ[f"{MODE_LAB[nm]} a {V:g} m/s: ω_n (rad/s), ζ, período (s)"] = [m_["wn"], m_["zeta"], m_["period"]]
            if P("resp"):
                S_["resp_lon"] = response(lm["A"], lm["B"], doublet(math.radians(2), channel=0), 12.0)
                S_["resp_lat"] = response(lm["A"], lm["B"], pulse(math.radians(5), channel=1), 12.0)
        if f.slosh:
            add("info", "líquido livre", "sloshing ligado", "",
                "estática e modelo linear tratam o líquido parado no CG (faixa de CG acima inclui sem líquido); o "
                "acoplamento dinâmico do sloshing só aparece nas simulações no tempo (Missão, Curvas)", "", G)
        return SimResult(series=S_, summary=summ, checks=checks)


def _tailless_impl(self, ctx, ac, f, P, S_, summ, add, V, V_land, CL_land, cg_lo, de_max, da_max, crit):
    G = "asa voadora"
    w = f.wing
    if P("washout"):
        ctx.on_progress(0.42, "asa voadora: torção na ponta")
        deltas = np.arange(0.0, -10.01, -1.0)
        c0, cl = [], []
        for d in deltas:
            with Probe(ctx.backend, with_washout(ac, w.name, d)) as p:
                c0.append(cm0(p, V))
                cl.append(trimmed_CLmax(p, V_land, p.x_of(cg_lo), de_max))
        c0, cl = np.array(c0), np.array(cl)
        S_["wo_C_m0"] = {"tw": deltas, "v": c0}
        S_["wo_zero"] = {"tw": deltas[[0, -1]], "v": np.zeros(2), "_dash": 1}
        S_["wc_C_L máximo equilibrado"] = {"tw": deltas, "v": cl}
        S_["wc_C_L de pouso pedido"] = {"tw": deltas[[0, -1]], "v": np.full(2, CL_land), "_dash": 1}
        need = next((d for d, v in zip(deltas, c0) if v > 0), None)
        if c0[0] > 0:
            add("ok", "torção na ponta (washout) para C_m0 > 0", f"atual já dá C_m0 = {c0[0]:.4f}",
                "C_m0 > 0", "", "", G, source="Nickel & Wohlfahrt, Tailless Aircraft")
        elif need is not None:
            add("falha", "torção na ponta (washout) para C_m0 > 0", f"C_m0 = {c0[0]:.4f}; precisa {need:g}°", "C_m0 > 0",
                "a ponta enflechada atrás do CG precisa voar com menos α para dar momento cabrador",
                f"adicionar {need:g}° de torção na ponta (linear da raiz à ponta) ou usar perfil reflexo", G,
                source="Nickel & Wohlfahrt, Tailless Aircraft")
        else:
            add("falha", "torção na ponta (washout) para C_m0 > 0", "nem −10° resolve", "C_m0 > 0",
                "enflechamento pequeno: a torção na ponta tem braço curto", "aumentar o enflechamento ou usar perfil reflexo",
                G)
    if P("size_elevon") and f.pitch_kind == "elevon":
        ctx.on_progress(0.45, "asa voadora: tamanho do elevon")
        ctl = f.pitch[1]
        cfs = (0.20, 0.25, 0.30, 0.35, 0.40)
        etas = np.array([0.2, 0.35, 0.5, 0.65])
        best = None
        for cf in cfs:
            vals = []
            for ei in etas:
                if ei >= ctl.span_end - 0.05:
                    vals.append(np.nan)
                    continue
                with Probe(ctx.backend, with_elevon(ac, w.name, cf, ei)) as p:
                    v = trimmed_CLmax(p, V_land, p.x_of(cg_lo), de_max)
                vals.append(v)
                area = cf * (ctl.span_end - ei)
                if np.isfinite(v) and v >= CL_land and (best is None or area < best[0]):
                    best = (area, cf, ei, v)
            S_[f"es_c_e/c = {cf:.2f}"] = {"eta": etas, "v": np.array(vals)}
        S_["es_C_L de pouso pedido"] = {"eta": etas[[0, -1]], "v": np.full(2, CL_land), "_dash": 1}
        cur = f"c_e/c {ctl.chord_frac:.2f}, de {ctl.span_start:.2f} a {ctl.span_end:.2f} da semiasa"
        if best:
            add("ok" if ctl.chord_frac * (ctl.span_end - ctl.span_start) >= best[0] - 1e-9 else "info",
                "menor elevon que equilibra o pouso", f"c_e/c {best[1]:.2f}, início {best[2]:.2f} (atual: {cur})",
                f"C_L equilibrado ≥ {CL_land:.2f} no CG dianteiro", "", "", G)
        else:
            add("falha", "menor elevon que equilibra o pouso", f"nenhum até c_e/c 0,40 (atual: {cur})",
                f"C_L equilibrado ≥ {CL_land:.2f} no CG dianteiro",
                "sem cauda, cabrar o elevon tira sustentação da própria asa: o C_L equilibrado fica limitado",
                "pousar com C_L menor (reduzir 'C_L a equilibrar no pouso'), CG mais para trás, ou washout/reflexo "
                "(ver a curva × torção)", G)


def _mode_advice(crit: str, st: str, f, fin_word: str) -> tuple[str, str]:
    if st == "ok":
        return "", ""
    if "curto" in crit:
        return ("amortecimento em arfagem (C_mq) fraco diante da rigidez (C_mα)",
                "aumentar EH/braço (sobe C_mq) ou levar o CG para trás (reduz a rigidez)" if not f.tailless else
                "asa voadora tem C_mq pequeno: aumentar enflechamento/envergadura ou reduzir a margem")
    if "fugóide" in crit:
        return ("o fugóide troca altura por velocidade e é amortecido pelo arrasto: L/D alto amortece pouco "
                "(Lanchester: ζ ≈ 1/(√2 L/D))", "normalmente aceito pelo piloto/piloto automático; não dimensiona o avião")
    if "dutch" in crit:
        return (f"pouco amortecimento em guinada (C_nr) ou diedro forte demais diante da {fin_word}",
                f"aumentar a {fin_word} ou reduzir o diedro")
    if "rolamento" in crit:
        return ("amortecimento em rolamento pequeno para a inércia I_xx", "reduzir I_xx (massas longe da raiz)")
    if "espiral" in crit:
        return ("efeito diedro fraco diante da estabilidade direcional (C_lβ C_nr < C_nβ C_lr)",
                "aumentar o diedro ou reduzir a deriva")
    return "", ""


NORMS = ("MIL-F-8785C", "personalizado", "nenhuma (só valores)")


def _criteria(params: dict):
    from aerosim.stability.criteria import FIELDS, GROUPS, Criteria, mil_8785c, none
    norm = params.get("norm", "MIL-F-8785C")
    if norm == "personalizado":
        base = mil_8785c("I", "B")
        c = Criteria(**{k: float(params.get(f"crit_{k}", getattr(base, k))) for k, _, _ in FIELDS})
        c.use = tuple(g for g, _, _ in GROUPS if params.get(f"use_{g}", True))
        c.source = "definido na aba"
        return c
    if norm.startswith("nenhuma"):
        return none()
    return mil_8785c(params.get("cls", "I"), params.get("cat", "B"))


_SRC = re.compile(r"^(.*?)\s*\(([^()]*(?:MIL|Raymer|Sadraey|Etkin|Nelson|FAR|Torenbeek|Nickel|Munk|Kroo)[^()]*)\)\s*$")


def _short(c: Check) -> Check:
    """critério curto na tabela; a fonte vai para `source`"""
    m = _SRC.match(c.criterion or "")
    if m and not c.source:
        c.criterion, c.source = m.group(1), m.group(2)
    return c


def _whatif(ctx, ac, f, V, crit_name, criteria, fins) -> str:
    """quanto mudar para o modo passar no critério (refaz o modelo linear)"""
    lvl1 = lambda m, key: next((r["ok"] for r in evaluate(m, criteria) if key in r["criterio"]), False)
    crit = crit_name
    if "espiral" in crit and f.wing is not None:
        d, m = search(ctx.backend, lambda x: with_dihedral(ac, f.wing.name, x), (1, 2, 3, 4, 5, 6, 8, 10), V,
                      lambda m: lvl1(m, "espiral") and lvl1(m, "dutch"))
        if d is not None:
            return f"+{d}° de diedro na asa leva a espiral ao nível 1 sem estragar o dutch roll"
        return "nem +10° de diedro resolve: reduzir a deriva ou aceitar (o piloto corrige a espiral lenta)"
    if "dutch" in crit and fins:
        k, m = search(ctx.backend, lambda x: scale_surfaces(ac, fins, x), (1.25, 1.5, 1.75, 2.0, 2.5, 3.0), V,
                      lambda m: lvl1(m, "dutch"))
        if k is not None:
            return f"área da deriva × {k:g} leva o dutch roll ao nível 1"
    if "curto" in crit and f.htail is not None:
        names = [s.name for s in ac.surfaces if s.role == "htail"]
        k, m = search(ctx.backend, lambda x: scale_surfaces(ac, names, x), (1.25, 1.5, 1.75, 2.0), V,
                      lambda m: lvl1(m, "curto"))
        if k is not None:
            return f"área do EH × {k:g} leva o curto período ao nível 1"
    return ""


StabilitySimulation._tailless = _tailless_impl

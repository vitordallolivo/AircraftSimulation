"""Missão (simulação 6GDL) por etapa do voo (corrida no chão, cada perna do percurso, rolagem).

Modos:
  missão                decolagem otimizada para o x_warning e o z_warning (Configuração → Pista) e
                        depois o resto, etapa por etapa. Curva sem raio: procura o menor que a
                        aeronave faz, do checkpoint do início da curva. Cada etapa salva um checkpoint no início dela:
                        dá para parar no fim de qualquer etapa, mudar o percurso dali para frente na
                        Configuração e continuar do início daquela etapa
  só decolagem          otimiza o ponto de acionamento do profundor (ou elevon) e mostra a decolagem
  curvas: raio mínimo   para cada V, o menor raio em curva nivelada (complementa a aba Desempenho)
  MTOW                  bisseção na massa: a maior que decola com x_warning e z_warning, otimizando o
                        acionamento do profundor (e o xCG, se pedido) em cada massa. O MTOW achado fica guardado
                        (enquanto o programa está aberto) para a pista: os outros modos voam com ele em
                        Massa → "MTOW salvo desta pista"

Nos modos missão, decolagem e curvas a massa pode ser a do avião (padrão), o MTOW salvo ou uma digitada, e o
acionamento do profundor (missão e decolagem) o otimizado (padrão) ou um digitado.

Critérios da decolagem: os da pista e o de não estolar (manager/takeoff_opt.py).
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import LogChunk
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.mission import Leg, MissionEvent, auto_radius, level_turn, takeoff_runway
from aerosim.model.universal import build_model

from .. import flightplots as FP
from .. import takeoff_opt as TO
from ..analysis import columns, evaluate_turn, min_radius, stage_table
from ..calibration import calibrate
from ..runner import Runner, Stop
from .base import SimulationBase, floats

MODES = ("missão", "só decolagem", "curvas: raio mínimo", "MTOW (x_warning e z_warning)")
M_MIS, M_TO, M_TURN, M_MTOW = MODES
# a massa com que a missão, a decolagem e as curvas voam: a do avião (padrão), o MTOW que o modo MTOW achou para esta
# pista (guardado enquanto o programa está aberto) ou uma digitada
MASSES = ("a do avião", "MTOW salvo desta pista", "na mão")
MASS_PLANE, MASS_SAVED, MASS_HAND = MASSES
# o acionamento do profundor na decolagem: otimizado para a pista (padrão) ou o que se digita
TRIGGERS = ("otimizado", "na mão")
GM = "Massa e acionamento"
GG = "Rajada"
END = "fim da missão (parada na pista)"
GP = "Pista"
CHUNK = 0.5
GLYPH = 10.0                      # avião desenhado no 3D a cada 10 m
AUTO_PHIS = (65.0, 55.0, 45.0, 37.0, 30.0, 24.0, 18.0)     # inclinações testadas na análise de curvas
AUTO_FRAC = (1.0, 0.85, 0.7, 0.55, 0.42, 0.32)              # raio automático: frações do φ máx. do piloto


KINDS = ("decolagem", "reta", "curva", "pouso")
LEG_COLS = (("name", "etapa", "str"),
            ("kind", "tipo", KINDS),
            ("length", "distância (m)", "float", "comprimento da reta (decolagem, reta, pouso)"),
            ("turn", "virar (°)", "float", "quanto a aeronave gira na curva: + direita, − esquerda. "
                                         "A próxima etapa segue na direção nova"),
            ("radius", "raio (m)", "float", "raio da curva; vazio = automático (procura o menor que a aeronave faz)"),
            ("h", "altura (m)", "float", "altura ao fim da etapa; vazio = mantém a anterior"),
            ("V", "velocidade (m/s)", "float", "velocidade ao fim da etapa; vazio = mantém a anterior"),
            ("gust", "rajada em (m)", "float", "distância dentro da etapa em que a rajada chega; vazio = sem rajada "
                                               "(o tamanho e a duração ficam no grupo Rajada)"))


def _kind(l) -> str:
    return "curva" if l.kind == "turn" else "decolagem" if l.takeoff else "pouso" if l.landing else "reta"


def legs_to_rows(legs, events=()) -> list[dict]:
    """a tabela da trajetória: uma linha por etapa, com a rajada da etapa (se houver) na coluna "rajada em"."""
    gusts = {e.leg: e.s for e in events if e.kind == "gust"}
    rows = []
    for i, l in enumerate(legs):
        k = _kind(l)
        turn = k == "curva"
        rows.append(dict(name=l.name, kind=k, length=None if turn else l.length,
                         turn=(l.side if l.side else 1) * l.angle if turn else None,
                         radius=(l.radius if l.radius > 0 else None) if turn else None, h=l.h, V=l.V,
                         gust=gusts.get(i)))
    return rows


def rows_to_gusts(rows) -> list[MissionEvent]:
    """as rajadas da tabela: uma por etapa que tem "rajada em" preenchido"""
    return [MissionEvent("gust", i, float(r["gust"])) for i, r in enumerate(rows) if r.get("gust") not in (None, "")]


def rows_to_legs(rows, old) -> list:
    out = []
    for i, r in enumerate(rows):
        base = old[i] if i < len(old) else Leg()
        f = lambda k, d: float(r[k]) if r.get(k) not in (None, "") else d
        k = r.get("kind") if r.get("kind") in KINDS else "reta"
        turn = f("turn", (base.side or 1) * base.angle if base.kind == "turn" else 90.0)
        out.append(Leg("turn" if k == "curva" else "straight", length=f("length", base.length),
                       radius=f("radius", 0.0), angle=abs(turn), side=1 if turn >= 0 else -1,
                       h=f("h", None), V=f("V", None), name=str(r.get("name") or f"etapa {i}"),
                       takeoff=k == "decolagem", landing=k == "pouso",
                       clearance=base.clearance if base.landing or k != "pouso" else 50.0))
    return out


MCOLS = (("item", "", "label"), ("min", "mínimo", "float"), ("nom", "nominal", "float"), ("max", "máximo", "float"))
ROWS = {"tot": "Massa total (kg)", "bal": "Lastro (kg)", "pay": "LAPES (kg)", "liq": "Líquido (L)",
        "xcg": "xCG (% CMA)", "xcg_m": "xCG (m)"}     # xCG (m): tabelas antigas (por dentro tudo é em metros)


def xcg_pct(model, x: float) -> float:
    """x do CG (m, corpo) -> % da CMA a partir do bordo de ataque"""
    return 100.0 * model.mac_frac(x)


def total_mass(ac) -> float:
    """massa do avião inteiro: seca (com o lastro) + LAPES + líquido"""
    from aerosim.model.universal import build_model
    m = float(build_model(ac).mass["m"])
    return m + (ac.payload.mass if ac.payload.enabled else 0.0) + sum(t.volume * t.rho / 1000.0 for t in ac.tanks)


def mtow_rows(ac) -> list[dict]:
    """linhas da tabela do MTOW (mínimo, nominal, máximo): a massa total e o xCG. A massa que passa da montada
    entra como massa no CG; quanto é lastro, LAPES ou líquido se decide na Montagem. (As linhas antigas — lastro,
    LAPES, líquido — continuam valendo se vierem na tabela.)"""
    rows = []
    if ac is None:
        return rows
    try:
        from aerosim.model.universal import build_model
        m = total_mass(ac)
        model = build_model(ac)
        p = xcg_pct(model, float(model.mass["cg"][0]))
    except Exception:
        m, p = 0.0, 25.0
    rows.append(dict(item=ROWS["tot"], min=round(m, 3), nom=round(m, 3), max=round(m + 6.0, 3)))
    rows.append(dict(item=ROWS["xcg"], min=round(p - 5.0, 2), nom=round(p, 2), max=round(p + 5.0, 2)))
    return rows


# os MTOW que o modo MTOW achou enquanto o programa está aberto, por (avião, x_warning, z_warning): (cópia com as
# massas, sobreposições do CG, massa total). A missão, a decolagem, as curvas e a Estabilidade leem daqui.
SAVED_MTOW: dict = {}


def saved_mtows(ac) -> list[tuple[str, object]]:
    """os MTOW salvos deste avião, cada um com um rótulo curto da pista ("55 m · 12.51 kg") e a cópia com as massas"""
    name = getattr(ac, "name", "")
    mine = sorted((key[1:], found) for key, found in SAVED_MTOW.items() if key[0] == name)
    twice = {xw for (xw, _), _ in mine if sum(other[0][0] == xw for other in mine) > 1}
    return [(f"{xw:g} m" + (f" (z {zw:g} m)" if xw in twice else "") + f" · {found[2]:.2f} kg", found[0])
            for (xw, zw), found in mine]


def mass_variant(ac, ranges: dict, t: float):
    """cópia com cada massa em mín + t (máx − mín); devolve (cópia, valores por item)"""
    v = ac.copy()
    got = {}
    for key, (lo, hi) in ranges.items():
        m = lo + t * (hi - lo)
        got[key] = m
        if key == "tot":
            continue
        if key == "pay":
            v.payload.mass = m
        elif key == "bal":
            v.ballast.mass = m
        elif key == "liq":
            v0 = sum(q.volume for q in ac.tanks)
            for q, q0 in zip(v.tanks, ac.tanks):
                q.volume = m * (q0.volume / v0 if v0 > 1e-9 else 1.0 / len(ac.tanks))
    if "tot" in ranges:                       # o que falta para a massa total vai como massa no CG
        from aerosim.model.universal import build_model
        base = total_mass(v) - (v.ballast.mass if v.ballast.enabled else 0.0)
        x = float(build_model(v).mass["cg"][0])
        extra = max(got["tot"] - base, 0.0)
        v.ballast.enabled, v.ballast.mass = extra > 0, extra
        v.ballast.x, v.ballast.y, v.ballast.z = x, 0.0, 0.0
    return v, got


def _wing_inc(ac) -> float:
    w = ac.wing
    return float(w.incidence) if w is not None else 0.0


def _angles(log, ev, ac, refs) -> dict:
    i = _wing_inc(ac)
    return FP.takeoff_angles(log, ev, i, refs["alpha_stall"] + i)


def _cg_walk(ctx, ac, log, ev, legs) -> dict:
    """passeio do CG e margem estática no tempo (o ponto neutro de manche fixo vem do núcleo, na velocidade de
    cruzeiro da aba Estabilidade)"""
    if "xcg" not in log.columns:
        return {}
    from aerosim.stability.probe import Probe
    from .stability import _cruise_speed
    try:
        with Probe(ctx.backend, ac) as pr:
            np_pct = pr.frac(pr.neutral_point(_cruise_speed(ac)))
            return FP.cg_series(log, ev, legs, pr.model.mac_le, pr.model.c, np_pct)
    except Exception:                        # sem ponto neutro (ex.: configuração sem sustentação) não há o gráfico
        return {}


def _refs(ac, info, xw, zw) -> dict:
    r = dict(Vs=info["Vs"], alpha_stall=info["alpha_stall"], kCL=ac.autopilot.kCL, ht=ac.takeoff.ht,
             x_warning=xw, z_warning=zw, landing_max=ac.airfield.landing_max, n_lim=ac.performance.load_factor)
    legs = ac.gear.legs()
    mains = [g for g in legs if g.kind == "main"]
    skids = [g for g in legs if g.kind == "skid"]
    if mains and skids and mains[0].x > skids[0].x:
        r["theta_tail"] = math.degrees(math.atan2(mains[0].z - skids[0].z, mains[0].x - skids[0].x))
    return r


class MissionSimulation(SimulationBase):
    name = "mission"
    title = "Missão"
    area = "missao"
    level = "detalhado"    # simulação 6GDL da missão inteira
    show_aircraft = True
    description = ("Voo simulado (6GDL) por etapa. A decolagem é otimizada para a pista (x_warning: comprimento, "
                   "z_warning: altura que conta como decolado) e o resto do voo continua dali, etapa por etapa.")

    # ------------------------------------------------------------------ formulário
    def parameters(self):
        return self.parameters_for(None, {})

    def parameters_for(self, ac, values=None):
        values = values or {}
        mode = values.get("mode", M_MIS)
        P = [ParamSpec("mode", "Análise", M_MIS, kind="choice", choices=MODES, rebuild=True)]
        legs = ac.mission.names() if ac is not None else []
        af = ac.airfield if ac is not None else None
        pista = [ParamSpec("x_warning", "x_warning (pista)", af.x_warning if af else 60.0, minimum=1,
                           maximum=2000, unit="m", group=GP,
                           help="comprimento de pista: tem de 'decolar' (passar do z_warning) antes desta distância"),
                 ParamSpec("z_warning", "z_warning (altura)", af.z_warning if af else 1.0,
                           minimum=-20, maximum=50, unit="m", group=GP,
                           help="altura sobre a superfície de partida que conta como decolado; ≤ 0 na mesa: quanto pode "
                                "afundar abaixo dela"),
                 ParamSpec("busca", "Busca do acionamento", TO.SEARCHES[0], kind="choice", choices=TO.SEARCHES,
                           group=GP, help="grade: 8 pontos na pista e refino em volta do melhor. bisseção: parte de "
                                          "onde o avião sai do chão sem acionar e divide a faixa até achar a janela"),
                 ParamSpec("tolerancia", "Tolerância da bisseção", 0.0, minimum=0.0, maximum=20.0, unit="% x_warning",
                           group=GP, help="só na bisseção: aceita errar o acionamento até isto do x_warning e desiste "
                                          "cedo da massa que nem com o comando todo cabrando sai do chão a tempo. "
                                          "0 = a busca de sempre")]
        hand = []                                   # massa e acionamento: da missão, da decolagem e das curvas
        if mode != M_MTOW:
            hand.append(ParamSpec("mass_source", "Massa", MASS_PLANE, kind="choice", choices=MASSES, rebuild=True,
                                  group=GM, help="a do avião; o MTOW que o modo MTOW achou para esta pista (x_warning e "
                                                 "z_warning), guardado enquanto o programa está aberto; ou a digitada"))
            if values.get("mass_source") == MASS_HAND:
                hand.append(ParamSpec("mass_hand", "Massa total", round(total_mass(ac), 3) if ac is not None else 5.0,
                                      minimum=0.1, maximum=500.0, unit="kg", group=GM,
                                      help="o que passa da massa do avião entra como massa no CG"))
        if mode in (M_MIS, M_TO):
            hand.append(ParamSpec("trigger", "Acionamento do profundor", TRIGGERS[0], kind="choice", choices=TRIGGERS,
                                  rebuild=True, group=GM,
                                  help="otimizado para a pista ou o que se digita (sem procurar)"))
            if values.get("trigger") == TRIGGERS[1]:
                to = ac.takeoff if ac is not None else None
                hand += [ParamSpec("s_hand", "Acionamento em", to.sR if to is not None and to.sR < 1e6 else 10.0,
                                   minimum=0.0, maximum=2000.0, unit="m", group=GM,
                                   help="distância da corrida em que o profundor é acionado"),
                         ParamSpec("de_hand", "Deflexão", to.de1 if to is not None else -10.0, minimum=-45.0,
                                   maximum=45.0, unit="°", group=GM, help="deflexão do profundor (− cabra)")]
        if mode == M_MIS:
            P += [ParamSpec("legs", "Trajetória", legs_to_rows(ac.mission.legs, ac.mission.events) if ac is not None else [],
                            kind="table", columns=LEG_COLS, bound=True,
                            help="uma linha por etapa; passe o mouse no cabeçalho para ver cada coluna"),
                  ParamSpec("start", "Começar de", "chão", kind="choice",
                            choices=("chão",) + tuple(f"início: {n}" for n in legs[1:]),
                            help="do checkpoint salvo no início da etapa; se ainda não houver, voa até lá e salva"),
                  ParamSpec("until", "Parar em", END, kind="choice", choices=(END,) + tuple(f"fim: {n}" for n in legs[:-1]),
                            help="para no fim da etapa (salva o checkpoint para continuar dali)")]
            P += pista[:2] + hand    # a pista que a decolagem da missão tem de cumprir (8 m na micro, 55 m na regular...)
            env = ac.environment if ac is not None else None
            U = list(env.gust_U) if env is not None else [0.0, 0.0, -2.0]
            P += [ParamSpec("gust_on", "rajada ligada", bool(env.gust) if env is not None else False, kind="bool",
                            group=GG, help="liga as rajadas das etapas (coluna \"rajada em\" da Trajetória)"),
                  ParamSpec("gust_up", "vertical", -U[2], minimum=-20.0, maximum=20.0, unit="m/s", group=GG,
                            help="para cima é positivo"),
                  ParamSpec("gust_side", "lateral", U[1], minimum=-20.0, maximum=20.0, unit="m/s", group=GG,
                            help="para leste é positivo"),
                  ParamSpec("gust_T", "duração", env.gust_T if env is not None else 1.0, minimum=0.05, maximum=20.0,
                            unit="s", group=GG, help="a rajada 1 − cos sobe e desce neste tempo")]
        elif mode == M_TO:
            P += pista + hand
        elif mode == M_TURN:
            P += pista[:2] + hand + [ParamSpec("V_list", "Velocidades", "13, 15, 17", kind="floats", unit="m/s",
                            help="para cada V testa raios de inclinação 70° a 20° (R = V²/(g tan φ)) e acha o menor que "
                                 "a aeronave faz sem estolar, sem perder mais de 3 m e seguindo o raio")]
        else:
            P += pista + [
                ParamSpec("masses", "Massas", mtow_rows(ac), kind="table", columns=MCOLS, group="MTOW",
                          help="a massa total vai do mínimo ao máximo (o que passa da montada entra no CG); o xCG, em % da "
                               "CMA a partir do bordo de ataque, é testado nos três valores")]
        return P

    def commit(self, aircraft, values) -> bool:
        changed = self._commit_gust(aircraft, values)
        rows = values.get("legs")
        if not rows:
            return changed
        new = rows_to_legs(rows, aircraft.mission.legs)
        n = len(new)
        events = [e for e in aircraft.mission.events if e.leg < n]
        gusts = rows_to_gusts(rows)
        if sorted((e.leg, e.s) for e in events if e.kind == "gust") != sorted((e.leg, e.s) for e in gusts):
            events = [e for e in events if e.kind != "gust"] + gusts      # só refaz se a tabela mudou as rajadas
        if new == aircraft.mission.legs and events == aircraft.mission.events:
            return changed
        aircraft.mission.legs = new
        aircraft.mission.events = events
        return True

    @staticmethod
    def _commit_gust(aircraft, values) -> bool:
        """o tamanho, a duração e o liga/desliga da rajada (grupo Rajada) no ambiente do avião"""
        if "gust_on" not in values:
            return False
        env = aircraft.environment
        U = [float(env.gust_U[0]), float(values.get("gust_side", env.gust_U[1])), -float(values.get("gust_up", -env.gust_U[2]))]
        new = (bool(values["gust_on"]), U, float(values.get("gust_T", env.gust_T)))
        if new == (bool(env.gust), [float(u) for u in env.gust_U], float(env.gust_T)):
            return False
        env.gust, env.gust_U, env.gust_T = new
        return True

    # ------------------------------------------------------------------ gráficos
    def plots(self):
        return self.plots_for(None, {})

    def plots_for(self, ac, values=None):
        mode = (values or {}).get("mode", M_MIS)
        traj = [PlotSpec("t3", "Trajetória 3D", "e", ("n",), "e (m) — leste",
                         "n (m) — eixo da pista", source="series:t3_*", kind="3d", z="h", height=720),
                PlotSpec("xz", "Plano XZ", "n", ("h",), "$x$ (m)",
                         "$z$ (m)", source="series:xz_*", live_ys=("h",)),
                PlotSpec("xy", "Plano XY", "n", ("e",), "$x$ (m)", "$y$ (m)",
                         source="series:xy_*", live_ys=("e",), aspect=True, invert_y=True),
                PlotSpec("zy", "Plano ZY", "e", ("h",), "$y$ (m)", "$z$ (m)", source="series:zy_*",
                         live_ys=("h",))]
        takeoff = [
            PlotSpec("dt", "Decolagem: ângulo da aeronave e da asa", "t", ("y",), "$t$ (s)",
                     "ângulo (°)", live=False, source="series:dt_*"),
            PlotSpec("dh", "Decolagem: altura", "n", ("y",),
                     "$x$ (m)", "$h$ (m)", source="series:dh_*"),
            PlotSpec("dv", "Decolagem: velocidades", "n", ("y",), "$x$ (m)", "$V$ (m/s)",
                     source="series:dv_*", live_ys=("Va", "Vg")),
            PlotSpec("da", "Decolagem: θ, α, γ", "n", ("y",), "$x$ (m)", "ângulo (°)",
                     source="series:da_*"),
            PlotSpec("dc", "Decolagem: comandos", "n", ("y",), "$x$ (m)", "°",
                     source="series:dc_*"),
            PlotSpec("dr", "Decolagem: reações no trem", "n", ("y",), "$x$ (m)", "N",
                     source="series:dr_*", live_ys=("N_steer", "N_main")),
            PlotSpec("dm", "Decolagem: momentos do trem", "n", ("y",), "$x$ (m)", "N·m", source="series:dm_*")]
        opt = PlotSpec("op", "Acionamento do profundor × n_dec (★ escolhido)", "s", ("y",), "$s$ (m)", "$n_{dec}$ (m)",
                       live=False, source="series:op_*")
        tt = lambda key, title, ylab: PlotSpec(key, title, "t", ("y",), "$t$ (s)", ylab, live=False,
                                               source=f"series:{key}_*")
        first = [traj[1], takeoff[0], takeoff[5],
                 tt("tcl", "Decolagem: $C_L$", "$C_L$"), tt("tcd", "Decolagem: $C_D$", "$C_D$"),
                 tt("tld", "Decolagem: sustentação e arrasto", "N"),
                 tt("tmL", "Decolagem: rolamento $L$ e $\\delta_a$", "N·m / °"),
                 tt("tmM", "Decolagem: arfagem $M$ e $\\delta_e$", "N·m / °"),
                 tt("tmN", "Decolagem: guinada $N$ e $\\delta_r$", "N·m / °")]
        rest = [takeoff[1], takeoff[2], takeoff[3], takeoff[4], takeoff[6], traj[0]]
        if mode == M_TO:
            return first + [opt] + rest
        if mode == M_MTOW:
            return first + [PlotSpec("mt", "MTOW: $n_{dec}$ × massa (★ MTOW)", "m", ("y",), "$m$ (kg)", "$n_{dec}$ (m)",
                                     live=False, source="series:mt_*"),
                            PlotSpec("mc", "Massas × massa de decolagem", "m", ("y",), "$m$ (kg)", "kg ou L",
                                     live=False, source="series:mc_*"),
                            PlotSpec("ma", "Acionamento, $\\delta_e$ e xCG × massa", "m", ("y",), "$m$ (kg)",
                                     "m / ° / % CMA", live=False, source="series:ma_*"),
                            opt] + rest
        if mode == M_TURN:
            return [PlotSpec("cv", "Curvas: trajetórias", "e", ("n",), "e (m)", "n (m)",
                             source="series:cv_*", live_ys=("n",), aspect=True),
                    PlotSpec("cr", "$C_L/C_{Lmax}$ × raio", "R", ("y",), "R (m)", "—",
                             live=False, source="series:cr_*"),
                    PlotSpec("cp", "Inclinação × raio", "R", ("y",), "R (m)", "|φ| (°)", live=False,
                             source="series:cp_*"),
                    PlotSpec("cn", "Fator de carga × raio (em regime)", "R", ("y",), "R (m)", "$n$", live=False,
                             source="series:cn_*"),
                    PlotSpec("ct", "Curvas: fator de carga no tempo (— $n_z$, ··· $n$ no estol)", "t", ("y",),
                             "t desde o início da curva (s)", "$n$", live=False, source="series:ct_*"),
                    PlotSpec("ch", "Altura perdida × raio", "R", ("y",), "R (m)", "m", live=False,
                             source="series:ch_*"),
                    PlotSpec("rmin", "Raio mínimo", "V", ("R",), "V (m/s)", "R mínimo (m)", live=False,
                             source="series:rm_*")]
        has_pay = ac is None or ac.payload.enabled
        has_tank = ac is None or bool(ac.tanks)
        t = lambda key, title, ylab, live=(): PlotSpec(key, title, "t", ("y",), "t (s)", ylab,
                                                       source=f"series:{key}_*", live_ys=live)
        out = traj + [
            t("vel", "Velocidades", "$V$ (m/s)", ("Va", "Vg")),
            t("alt", "Altura", "$h$ (m)", ("h",)),
            t("ang", "Ângulos", "ângulo (°)", ("theta", "alpha", "phi")),
            t("rumo", "Proa e curso", "ângulo (°)"),
            t("momL", "Rolamento $L$", "N·m"),
            t("momM", "Arfagem $M$", "N·m"),
            t("momN", "Guinada $N$", "N·m"),
            t("cmd", "Comandos", "$\\delta$ (°)", ("de", "da", "dr")),
            t("thr", "Acelerador", "0–1", ("thr",)),
            t("cl", "$C_L$", "$C_L$"),
            t("cd", "$C_D$", "$C_D$"),
            t("roc", "Razão de subida", "$\\dot{h}$ (m/s)"),
            t("nz", "Fator de carga", "$n_z$", ("nz",)),
            t("motor", "Motor", "rpm/100, A, N"),
            t("ene", "Energia", "Wh"),
            t("bat", "Consumo de bateria", "mAh"),
            t("batp", "Bateria: SOC", "SOC (%) / $I$ (A)"),
            t("cgp", "Passeio do CG (% CMA, a partir do bordo de ataque)", "% CMA"),
            t("mem", "Margem estática ao longo do voo", "ME (% CMA)")]
        if has_tank:
            out.append(t("slosh", "Sloshing", "ângulo (°)"))
        out += [opt] + takeoff
        out += [PlotSpec("pr", "Pouso: reações no trem", "n", ("y",), "$x$ (m)",
                         "N", live=False, source="series:pr_*"),
                PlotSpec("pm", "Pouso: momentos do trem", "n", ("y",), "$x$ (m)", "N·m", live=False,
                         source="series:pm_*"),
                PlotSpec("fg", "Folga da pá e da cauda sobre o chão", "t", ("y",), "$t$ (s)", "folga (m)",
                         live=False, source="series:fg_*")]
        if has_pay:
            out += [PlotSpec("lx", "LAPES: plano XZ", "n", ("h",), "n (m)", "h (m)",
                             live=False, source="series:lx_*"),
                    PlotSpec("lc", "LAPES: CG e carga", "t", ("y",), "t − t_soltura (s)",
                             "cm", live=False, source="series:lc_*"),
                    PlotSpec("lm", "LAPES: massa", "t", ("y",), "t − t_soltura (s)", "kg", live=False,
                             source="series:lm_*"),
                    PlotSpec("lp", "LAPES: arfagem", "t", ("y",), "t − t_soltura (s)",
                             "° , °/s , N·m", live=False, source="series:lp_*"),
                    PlotSpec("lapes", "LAPES: soltura × impacto", "s", ("y",),
                             "s de soltura na perna (m)", "impacto n (m)", live=False, source="series:ls_*")]
        return out

    # ------------------------------------------------------------------ execução
    def run(self, ctx: RunContext) -> SimResult:
        mode = self.param(ctx, "mode")
        if mode == M_MIS:
            self.commit(ctx.aircraft, ctx.params)            # a trajetória da tabela e a rajada
        p = ctx.params
        xw = float(p.get("x_warning", ctx.aircraft.airfield.x_warning))
        zw = float(p.get("z_warning", ctx.aircraft.airfield.z_warning))
        if mode == M_MTOW:
            ac, info = self.prepare(ctx)
            return self._mtow(ctx, ac, info, _refs(ac, info, xw, zw))
        ac, info, over = self._with_mass(ctx, xw, zw)
        refs = _refs(ac, info, xw, zw)
        if mode == M_TO:
            result = self._takeoff(ctx, ac, info, refs, over)
        elif mode == M_TURN:
            result = self._turns(ctx, ac, info, refs, over)
        else:
            result = self._mission(ctx, ac, info, refs, over)
        source = ctx.params.get("mass_source", MASS_PLANE)
        if source != MASS_PLANE:                    # a massa que voou, quando não é a do avião
            result.checks.insert(0, Check("info", "massa do voo", f"{total_mass(ac):.2f} kg", source,
                                          f"a do avião é {total_mass(ctx.aircraft):.2f} kg", "", "Massa"))
        return result

    # ------------------------------------------------------------------ massa e acionamento
    def _saved(self) -> dict:
        """os MTOW achados nesta sessão, por (avião, x_warning, z_warning): (cópia com as massas, sobreposições do CG,
        massa total)"""
        return SAVED_MTOW

    @staticmethod
    def _runway(ac, xw: float, zw: float) -> tuple:
        return getattr(ac, "name", ""), round(xw, 3), round(zw, 3)

    def _with_mass(self, ctx, xw: float, zw: float):
        """a cópia calibrada com a massa escolhida e as sobreposições do núcleo que ela pede (o CG do MTOW)"""
        source = self.param(ctx, "mass_source") if "mass_source" in ctx.params else MASS_PLANE
        if source == MASS_PLANE:
            ac, info = self.prepare(ctx)
            return ac, info, None
        if source == MASS_SAVED:
            found = self._saved().get(self._runway(ctx.aircraft, xw, zw))
            if found is None:
                raise RuntimeError(f"ainda não há MTOW salvo para x_warning = {xw:g} m e z_warning = {zw:g} m: rode "
                                   f"antes o modo MTOW com esta pista")
            variant, over, _ = found
            ac = variant.copy()
        else:
            m = float(ctx.params.get("mass_hand", total_mass(ctx.aircraft)))
            ac, _ = mass_variant(ctx.aircraft, {"tot": (m, m)}, 0.0)
            over = None
        ctx.on_progress(0.0, "calibrando o piloto pela polar")
        return ac, calibrate(ctx.backend, ac), over

    def _choose(self, ctx, ac, refs, over=None):
        """o acionamento da decolagem: otimizado para a pista ou o digitado (avaliado uma vez)"""
        if ctx.params.get("trigger") != TRIGGERS[1]:
            return self._optimize(ctx, ac, refs, over)
        ctx.on_progress(0.0, "decolagem com o acionamento digitado")
        s_hand = float(ctx.params.get("s_hand", ac.takeoff.sR))
        best = TO.evaluate(ctx.backend, ac, s_hand if TO.pitch_control(ac) else None,
                           float(ctx.params.get("de_hand", ac.takeoff.de1)), refs["x_warning"], refs["z_warning"], over)
        return best, [best]

    # ------------------------------------------------------------------ decolagem
    def _optimize(self, ctx, ac, refs, overrides=None):
        ctx.on_progress(0.0, "otimizando o acionamento do profundor")
        par = lambda fn, items: self.parallel(ctx, fn, items, "decolagens")
        search = ctx.params.get("busca") or TO.SEARCHES[0]
        tol = float(ctx.params.get("tolerancia") or 0.0) / 100.0
        return TO.optimize(ctx.backend, ac, refs["x_warning"], refs["z_warning"], par, overrides, search=search,
                           tol=tol)

    @staticmethod
    def _opt_series(tried, best, refs, prefix="op_") -> dict:
        S = {}
        levels = sorted({r.de for r in tried})
        colors = ["#1f77b4", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf"]
        for i, de in enumerate(sorted(levels)):
            rs = sorted([r for r in tried if r.de == de and np.isfinite(r.s)], key=lambda r: r.s)
            if not rs:
                continue
            s = np.array([r.s for r in rs])
            fin = [r.n_dec for r in tried if np.isfinite(r.n_dec)]
            ceil = 1.15 * max(fin + [refs["x_warning"]])        # "não decolou": desenhado no alto do gráfico
            y = np.array([r.n_dec if np.isfinite(r.n_dec) else ceil for r in rs])
            ok = np.array([r.ok for r in rs])
            c = colors[i % len(colors)]
            S[f"{prefix}δe = {de:g}°" + ("" if ok.any() else " (nenhum ponto passa; no alto: não decolou)")] = dict(
                s=s, y=y, _color=c, _width=1.0)
            S[f"{prefix}δe = {de:g}°: passa"] = dict(s=s[ok], y=y[ok], _symbol="o", _color=c, _size=9, _nolegend=1)
            S[f"{prefix}δe = {de:g}°: não passa"] = dict(s=s[~ok], y=y[~ok], _symbol="x", _color=c, _size=11, _nolegend=1)
        S[f"{prefix}x_warning ({refs['x_warning']:g} m)"] = dict(_hline=refs["x_warning"], _color="#d62728", _width=3)
        if best is not None and np.isfinite(best.s) and np.isfinite(best.n_dec):
            S[f"{prefix}★ escolhido: {best.s:.1f} m, δe = {best.de:g}°"] = dict(
                s=np.array([best.s]), y=np.array([best.n_dec]), _symbol="star", _color="#ffcc00", _size=24)
        return S

    def _takeoff_checks(self, ac, best, refs, ctrl) -> list[Check]:
        G = "Pista"
        xw, zw = refs["x_warning"], refs["z_warning"]
        C = [Check("ok" if best.x_excess == 0 else "falha", "x_warning: decolou dentro da pista",
                   "não decolou" if not np.isfinite(best.n_dec) else f"n_dec = {best.n_dec:.1f} m", f"≤ {xw:g} m",
                   "" if best.x_excess == 0 else f"passou {best.x_excess:.1f} m do comprimento de pista",
                   "" if best.x_excess == 0 else "menos massa, mais tração, mais C_Lmax ou mais área de asa", G),
             Check("ok" if best.z_short == 0 else "falha", "z_warning: altura que conta como decolado",
                   f"menor altura depois de sair do chão: {best.h_min:+.2f} m", f"z_warning = {zw:g} m",
                   "" if best.z_short == 0 else f"faltaram {best.z_short:.2f} m", "" if best.z_short == 0 else
                   "aciona o profundor antes ou com mais deflexão; mesa mais longa", G)]
        if ctrl:
            C.append(Check("info", f"acionamento do {ctrl}", f"em {best.s:.1f} m, deflexão {best.de:g}°",
                           f"máx. {ac.autopilot.de_max:g}°",
                           "a maior deflexão que funciona; ponto com a maior folga até o x_warning" if best.ok else
                           "nenhum ponto passou: este é o menos ruim",
                           "copie para Configuração → Decolagem (sR, de1)" if best.ok else "", G))
            if np.isfinite(getattr(best, "de0", float("nan"))):
                C.append(Check("info", "profundor segurado na corrida", f"{best.de0:+g}° (pica) até o acionamento",
                               "—", "com o profundor neutro o avião saía do chão antes de ter velocidade de voo "
                               "(motor inclinado ou EH que cabra muito)", "Configuração → Decolagem (de0)", G))
        else:
            C.append(Check("info", "sem comando de arfagem", "decola sozinha", "—",
                           "a aeronave não tem profundor/elevon: não há acionamento a otimizar", "", G))
        return C

    def _takeoff(self, ctx, ac, info, refs, over=None) -> SimResult:
        best, tried = self._choose(ctx, ac, refs, over)
        ctrl = TO.pitch_control(ac)
        ctx.on_progress(0.9, "decolagem escolhida")
        res, log = TO.evaluate(ctx.backend, ac, best.s if ctrl else None, best.de, refs["x_warning"],
                               refs["z_warning"], over, dtlog=0.005, log=True, de0=best.de0)
        ctx.on_chunk(log)
        ev = res.events
        S = self._opt_series(tried, best, refs)
        if len(log):
            S.update(self._takeoff_series(log, ev, ac, refs))
        summary = dict(status=res.status, x_warning=refs["x_warning"], z_warning=refs["z_warning"],
                       n_dec=res.n_dec, folga_de_pista=refs["x_warning"] - res.n_dec,
                       acionamento_m=best.s, deflexao_graus=best.de, V_ao_sair_do_chao=ev["VLO"],
                       n_saiu_do_chao=ev["nLO"], massa=info["mass"])
        return SimResult(log=log, series=S, summary=summary, events=ev, status=res.status,
                         checks=self._takeoff_checks(ac, best, refs, ctrl))

    @staticmethod
    def _takeoff_series(log, ev, ac, refs) -> dict:
        S = {}
        S.update(FP.takeoff_window(log, ev, refs, ac.airfield))
        S.update(_angles(log, ev, ac, refs))
        S.update(FP.takeoff_time(log, ev, ac.environment.rho, build_model(ac).S))
        S.update({k: v for k, v in FP.trajectory(log, ev, ["decolagem", "cruzeiro"]).items()
                  if k.startswith(("t3_", "xz_"))})
        S.update(FP.terrain_profile(log, "xz_"))
        return S

    # ------------------------------------------------------------------ missão
    def _mission(self, ctx, ac, info, refs, over=None) -> SimResult:
        mission = ac.mission
        legs = mission.names()
        nseg = len(legs)
        drop = next((e for e in mission.events if e.kind == "drop"), None)
        k_drop = drop.leg if drop is not None and ac.payload.enabled else None
        start, until = self.param(ctx, "start"), self.param(ctx, "until")
        k0 = legs.index(start[len("início: "):]) if start != "chão" and start[len("início: "):] in legs else 0
        stop_at = nseg if until == END or until[len("fim: "):] not in legs else legs.index(until[len("fim: "):]) + 1
        if stop_at <= k0:
            stop_at = nseg
        store = ctx.checkpoints
        key = lambda k: f"missão: início de {legs[k]}"
        series, notes, checks = {}, [], []
        aim = bool(ac.payload.aim) and k_drop is not None
        best = None
        radii = {}
        need_takeoff = k0 == 0 or not store.has(key(k0))
        if need_takeoff:
            best, tried = self._choose(ctx, ac, refs, over)
            series.update(self._opt_series(tried, best, refs))
            if TO.pitch_control(ac) and np.isfinite(best.s):
                ac.takeoff.sR, ac.takeoff.de1 = best.s, best.de
                if np.isfinite(best.de0):                 # segurar o profundor picando na corrida
                    ac.takeoff.de0 = best.de0
            checks += self._takeoff_checks(ac, best, refs, TO.pitch_control(ac))
        parts: list[LogChunk] = []
        out = None
        with Runner(ctx.backend, ac, mission, over, ctx) as r:
            if k0 > 0 and store.has(key(k0)):
                r.start_from(store.get(key(k0)))
            else:
                r.start_ground()
                if k0 > 0:                      # sem checkpoint: voa até lá (sem desenhar) e salva os do caminho
                    notes.append(f"não havia checkpoint no início de '{legs[k0]}': voou do chão até lá e salvou")
                    for k in range(k0):
                        ctx.on_progress(k / max(nseg, 1), f"chegando em '{legs[k0]}': {legs[k]}")
                        o = r.run(Stop(segment=k + 1), live=False, log=False)
                        if o.status.name != "STOPPED":
                            raise RuntimeError(f"o voo terminou ({o.status.name}) em '{legs[k]}', antes de "
                                               f"chegar em '{legs[k0]}'")
                        r.checkpoint(key(k + 1), store)
            def prepare(k):
                """antes da etapa k: raio automático da curva e ponto de soltura da LAPES (do checkpoint)"""
                nonlocal mission, aim
                if not store.has(key(k)):
                    return
                ck = store.get(key(k))
                leg = mission.legs[k]
                if leg.kind == "turn" and leg.radius <= 0:
                    mission, R, why = self._auto_turn(ctx, ac, mission, ck, k, info, over)
                    checks.append(Check("info" if why == "ok" else "atencao", f"raio automático — {legs[k]}",
                                        f"R = {R:.1f} m", "menor raio que a aeronave faz",
                                        "" if why == "ok" else f"nenhum raio testado passou ({why}); usou o maior",
                                        "" if why == "ok" else "mais velocidade nessa curva", "Curvas"))
                    radii[legs[k]] = R
                    r.reconfigure(mission)
                    r.start_from(ck)
                if aim and k == k_drop:
                    mission, hist = self._aim(ctx, ac, mission, ck, k, over)
                    series.update(hist)
                    r.reconfigure(mission)
                    r.start_from(ck)
                    aim = False

            k = k0
            while k + 1 <= min(stop_at, nseg - 1):
                ctx.on_progress(k / max(nseg, 1), f"etapa: {legs[k]}")
                prepare(k)
                out = r.run(Stop(segment=k + 1), chunk=CHUNK)
                parts.append(out.log)
                if out.status.name != "STOPPED":
                    break
                r.checkpoint(key(k + 1), store)
                k += 1
            if stop_at == nseg and (out is None or out.status.name == "STOPPED"):
                prepare(k)
                ctx.on_progress(0.95, f"etapa: {legs[-1]}")
                out = r.run(Stop(), chunk=CHUNK)
                parts.append(out.log)
            ev = r.session.events()
        log = LogChunk.concat([q for q in parts if len(q)])
        target = (ac.payload.target_n, ac.payload.target_e) if k_drop is not None else None
        pl = ac.airfield.pads(mission)
        pads = [dict(q, landing=i == len(pl) - 1 and ac.airfield.landing_on == "plataforma") for i, q in enumerate(pl)]
        table, brows = [], []
        if len(log):
            series.update(FP.trajectory(log, ev, legs, target))
            series.update(FP.time_series(log, ev, legs, refs))
            step = GLYPH
            if step > 0:
                ext = float(max(np.ptp(log["n"]), np.ptp(log["e"]), 10.0))
                series.update(FP.aircraft_glyphs(log, ev, legs, step, max(build_model(ac).b, ext / 35)))
            cap = sum(u.battery.capacity_mAh for u in ac.propulsion if u.enabled)
            if ac.shared_battery and ac.propulsion:
                cap = ac.propulsion[0].battery.capacity_mAh
            brows, bS = FP.battery_by_stage(log, ev, legs, cap)
            series.update(bS)
            if brows:
                series["consumo_por_etapa"] = columns(brows)
            series.update(_cg_walk(ctx, ac, log, ev, legs))
            if brows:
                series["consumo_por_etapa"] = columns(brows)
            if k0 == 0:
                series.update(FP.takeoff_window(log, ev, refs, ac.airfield))
                series.update(_angles(log, ev, ac, refs))
                if best is None:                  # decolagem da Configuração: julga pelo registro
                    n_dec, h_min, xe, zs, ok = TO.judge(log, ev, refs["x_warning"], refs["z_warning"])
                    r_ = TO.TakeoffResult(ac.takeoff.sR, ac.takeoff.de1, n_dec, h_min, xe, zs, ok, "")
                    checks += self._takeoff_checks(ac, r_, refs, TO.pitch_control(ac))
            series.update(FP.landing_window(log, ev, refs, ac.airfield, pads))
            series.update(FP.ground_clearance(log, ev))
            series.update(FP.lapes_window(log, ev, target[0] if target else None))
            table = stage_table(log, ev, legs, info["Vs"])
            if table:
                series["etapas"] = columns(table)
        st = out.status.name if out else "—"
        checks += self._mission_checks(ac, info, ev, table, st, stop_at == nseg, target)
        summary = dict(status=st, começou_de=start, parou_em=until, t_fim=ev["tend"], energia_Wh=ev["E"],
                       n_saiu_do_chao=ev["nLO"], n_toque=ev["nTD"], n_parada=ev["nStop"],
                       impacto_carga_n=ev["pk_n"], impacto_carga_e=ev["pk_e"], CL_CLmax_max=ev["ratio_mission"],
                       I_pico=ev["Ipeak"], checkpoints=", ".join(store.names()))
        if best is not None:
            summary.update(acionamento_profundor_m=best.s, deflexao_graus=best.de, n_dec=best.n_dec)
        if len(log) and brows:
            for r_ in brows:          # como a Tabela 5.1: tempo, corrente, consumo
                summary[f"consumo — {r_['etapa']}"] = (f"{r_['tempo_s']:.1f} s, {r_['corrente_media_A']:.1f} A, "
                                                       f"{r_['consumo_mAh']:.1f} mAh, SOC no fim {r_['soc_fim_pct']:.0f} %")
            tot = brows[-1]
            okb = tot["soc_fim_pct"] > 20
            checks.append(Check("ok" if okb else "falha", "bateria ao fim do trecho",
                                f"SOC = {tot['soc_fim_pct']:.0f} % ({tot['consumo_mAh']:.0f} mAh)",
                                "> 20 % (Peukert)", "" if okb else
                                "a missão gasta quase toda a bateria", "" if okb else
                                "bateria maior, menos tempo de voo ou menos corrente", "Bateria"))
        for nm, R in radii.items():
            summary[f"raio automático — {nm}"] = R
        if notes:
            summary["observação"] = "; ".join(notes)
        return SimResult(log=log, series=series, summary=summary, events=ev, status=st, checks=checks)

    def _auto_turn(self, ctx, ac, mission, ck, k, info, over=None):
        """curva sem raio: do checkpoint, testa raios do φ máx. do piloto automático para baixo e fica com o
        menor que passa"""
        seg = mission.segments()[k]
        V = max(seg["V0"], seg["V1"])
        Rs = [round(auto_radius(V, ac.autopilot.phimax * f), 1) for f in AUTO_FRAC]
        climbs = abs(seg["h1"] - seg["h0"]) > 0.5

        def one(R):
            m = mission.with_leg(k, radius=R)
            sg = m.segments()[k]
            with Runner(ctx.backend, ac, m, over) as rr:
                rr.start_from(ck)
                o = rr.run(Stop(segment=k + 1, t=ck.t + 20 + 3 * sg["L"] / max(V, 1.0)), live=False)
            res = evaluate_turn(o.log, sg, k, R, info["Vs"], ac.autopilot.kCL)
            if climbs and res.get("motivo") == "perde altura":      # curva que sobe/desce: altura não conta
                res["ok"], res["motivo"] = True, "ok"
            return res
        outs = self.parallel(ctx, one, Rs, f"raio automático: {mission.legs[k].name}")
        ok = [o["R"] for o in outs if o["ok"]]
        R = min(ok) if ok else max(Rs)
        why = "ok" if ok else outs[-1].get("motivo", "falha")
        return mission.with_leg(k, radius=R), R, why

    def _aim(self, ctx, ac, mission, ck, k, over=None):
        """bisseção no ponto de soltura s (perna k) para a carga cair no alvo (n)"""
        seg = mission.segments()[k]
        alvo = ac.payload.target_n
        others = [e for e in mission.events if e.kind != "drop"]
        hist = []

        def impact(sx):
            m = mission.with_events(others + [MissionEvent("drop", k, sx)])
            with Runner(ctx.backend, ac, m, dict(over or {}, tmax=ck.t + 300)) as rr:
                rr.start_from(ck)
                o = rr.run(Stop(segment=k + 1), live=False, log=False)
                if o.events["trel"] > 0 and o.events["pk_t"] <= 0:      # carga ainda no ar
                    o = rr.run(Stop(t=rr.session.time + 30.0), live=False, log=False)
            hist.append((sx, o.events["pk_n"]))
            return o.events["pk_n"] - alvo
        a, b = 0.05 * seg["L"], 0.95 * seg["L"]
        fa, fb = impact(a), impact(b)
        if (fa > 0) == (fb > 0):
            s_best = a if abs(fa) < abs(fb) else b
        else:
            for it in range(8):
                ctx.check()
                ctx.on_progress(it / 8, "LAPES: procurando o ponto de soltura")
                m = 0.5 * (a + b)
                fm = impact(m)
                if (fm > 0) == (fa > 0):
                    a, fa = m, fm
                else:
                    b = m
            s_best = 0.5 * (a + b)
        H = np.array(sorted(hist))
        S = {"ls_impacto da carga": dict(s=H[:, 0], y=H[:, 1], _color=FP.PAYLOAD, _symbol="o", _line=1, _size=9),
             "ls_alvo": dict(_hline=alvo, _color="#000000", _dash="dot"),
             "ls_★ soltura escolhida": dict(s=np.array([s_best]), y=np.array([np.interp(s_best, H[:, 0], H[:, 1])]),
                                           _symbol="star", _color="#ffcc00")}
        return mission.with_events(others + [MissionEvent("drop", k, s_best)]), S

    def _mission_checks(self, ac, info, ev, table, status, full, target) -> list[Check]:
        C = []
        kCL = ac.autopilot.kCL
        if status == "CRASHED" and ev.get("tprop", -1) >= 0:
            D = max((u.propeller.D for u in ac.propulsion if u.enabled), default=0.0)
            C.append(Check("falha", "a hélice tocou o chão",
                           f"t = {ev['tprop']:.2f} s, folga {ev['hpmin'] * 100:.1f} cm", "folga da ponta da pá > 0",
                           f"a ponta da pá (hélice de {D / 0.0254:.0f}\") encostou no terreno",
                           "suba o motor, alongue o trem ou use uma hélice menor; veja a folga da pá no gráfico", "Voo"))
        elif status == "CRASHED":
            C.append(Check("falha", "a aeronave caiu ou divergiu", f"t = {ev['tend']:.1f} s", "terminar o voo",
                           "a simulação parou abaixo do terreno, capotada ou com estado não finito",
                           "veja a etapa em que o voo terminou nos gráficos (fundo colorido) e o C_L/C_Lmax dela",
                           "Voo"))
        for row in table:
            nm = row["etapa"]
            if row["CL_CLmax_max"] > kCL:
                C.append(Check("falha", f"margem de estol — {nm}", f"C_L/C_Lmax = {row['CL_CLmax_max']:.2f}",
                               f"≤ {kCL:.2f}", "a meia asa mais carregada passou do limite de sustentação nessa etapa",
                               "aumente a velocidade da etapa, o raio da curva ou a área de asa", "Etapas"))
            if nm not in ("corrida no chão", "rolagem") and row["Va_min_Vs"] < 1.1:
                C.append(Check("atencao", f"velocidade mínima — {nm}", f"V/V_s = {row['Va_min_Vs']:.2f}", "≥ 1,1",
                               "a velocidade chegou perto da de estol", "peça mais velocidade nessa perna", "Etapas"))
        if full and ac.airfield.landing_on == "plataforma" and ev.get("tTD", -1) > 0:
            dz = ac.airfield.platform_height - ev.get("hgnd_td", 0.0)
            C.append(Check("ok" if dz <= 1e-6 else "falha", "pouso em cima da plataforma",
                           f"terreno no toque: {ev.get('hgnd_td', 0):.2f} m", f"= {ac.airfield.platform_height:g} m",
                           "" if dz <= 1e-6 else "tocou fora da plataforma",
                           "" if dz <= 1e-6 else "mude o início/comprimento da plataforma ou a folga do pouso", "Pouso"))
        if target is not None and ev.get("pk_t", 0) > 0:
            err = math.hypot(ev["pk_n"] - target[0], ev["pk_e"] - target[1])
            C.append(Check("ok" if err <= 5 else "atencao", "carga LAPES no alvo", f"erro = {err:.1f} m", "≤ 5 m",
                           "distância entre o impacto da carga e o alvo configurado",
                           "ligue 'procurar onde soltar' ou ajuste o evento de soltura", "LAPES"))
        if full and ev.get("tTD", -1) > 0 and ev.get("completed") and ac.airfield.landing_max > 0:
            d = ev["nStop"] - ev["nTD"]
            C.append(Check("ok" if d <= ac.airfield.landing_max else "falha", "distância de pouso (toque até parar)",
                           f"{d:.1f} m", f"≤ {ac.airfield.landing_max:g} m", "rolagem depois do toque",
                           "aproxime mais devagar ou aumente o atrito de frenagem", "Pouso"))
        C.append(Check("info", "energia gasta", f"{ev['E']:.2f} Wh", "—", "", "", "Voo"))
        return C

    # ------------------------------------------------------------------ curvas
    def _turns(self, ctx, ac, info, refs, mass_over=None) -> SimResult:
        side, ang, phimax = 1, 240.0, 75.0
        h, hloss = 30.0, 3.0
        over = dict(mass_over or {}, tmax=1e6, ap=dict(phimax=math.radians(phimax)))
        Vs_list = floats(self.param(ctx, "V_list"))

        series, checks, rmin_rows, all_cases = {}, [], [], []
        styles = [("#2ca02c", "o"), ("#d62728", "s"), ("#9467bd", "t"), ("#1f77b4", "d"), ("#ff7f0e", "o")]
        for iv, V in enumerate(Vs_list):
            ctx.check()
            Rs = sorted({round(auto_radius(V, phi), 1) for phi in (70.0,) + AUTO_PHIS + (14.0,)})
            m0 = level_turn(V, Rs[-1], ang, h, side=side)
            with Runner(ctx.backend, ac, m0, over, ctx) as r:
                r.start_air(0)
                r.run(Stop(segment=1), live=False, log=False)
                ck = r.checkpoint(f"curva V = {V:g} m/s")

            def one(R, V=V, ck=ck):
                m = level_turn(V, R, ang, h, side=side)
                with Runner(ctx.backend, ac, m, over) as rr:
                    rr.start_from(ck)
                    o = rr.run(Stop(segment=2, t=ck.t + 30 + 3 * R * math.radians(ang) / V), live=False)
                res = evaluate_turn(o.log, m.segments()[1], 1, R, info["Vs"], ac.autopilot.kCL, phimax)
                if res.get("perda_h", 0) > hloss and res["ok"]:
                    res["ok"], res["motivo"] = False, "perde altura"
                return res, o.log
            outs = self.parallel(ctx, one, Rs, f"V = {V:g} m/s: raios")
            c, sym = styles[iv % len(styles)]
            L = [o for o, _ in outs]
            Rm = min_radius(L)
            for io, (o, log) in enumerate(outs):
                o["V"] = V
                all_cases.append(o)
                ctx.on_chunk(log)
                if iv == len(Vs_list) // 2 and len(log):
                    cc = FP.STAGE_COLORS[1 + (io % 9)]
                    series[f"cv_V = {V:g} m/s, R = {o['R']:g} m — {o['motivo']}"] = dict(
                        e=np.asarray(log["e"], float), n=np.asarray(log["n"], float),
                        _color=cc, _width=1.8 if o["ok"] else 1.0, _dash=None if o["ok"] else "dash")
                    # n_z e o n em que a asa estola na V do momento (n_z/ratioCL), na perna da curva
                    sc = np.asarray(log["seg"]) == 1
                    if sc.sum() > 5:
                        tc = np.asarray(log["t"], float)[sc]
                        nzc = np.asarray(log["nz"], float)[sc]
                        rc = np.asarray(log["ratioCL"], float)[sc]
                        lab = f"R = {o['R']:g} m — {o['motivo']}"
                        series[f"ct_{lab}"] = dict(t=tc - tc[0], y=nzc, _color=cc, _width=1.6)
                        series[f"ct_{lab} (estol)"] = dict(t=tc - tc[0], y=np.where(rc > 0.05, nzc / np.maximum(rc, 1e-9),
                                                                                    np.nan),
                                                           _color=cc, _dash="dot", _width=1.0, _nolegend=1)
            Rarr = np.array([o["R"] for o in L])
            okm = np.array([o["ok"] for o in L])
            ne = np.array([o.get("n_estol_perm", np.nan) for o in L], float)
            series[f"cn_V = {V:g} m/s — n no estol"] = dict(R=Rarr, y=ne, _color=c, _dash="dot", _width=1.2)
            for pre, k in (("cr_", "razao_max"), ("cp_", "phi_perm"), ("cn_", "nz_perm"), ("ch_", "perda_h")):
                y = np.array([o.get(k, np.nan) for o in L], float)
                if k == "phi_perm":
                    y = np.minimum(y, 89.0)
                series[f"{pre}V = {V:g} m/s — passa"] = dict(R=Rarr[okm], y=y[okm], _symbol=sym, _color=c, _size=10)
                series[f"{pre}V = {V:g} m/s — falha"] = dict(R=Rarr[~okm], y=y[~okm], _symbol="x", _color=c, _size=12)
                series[f"{pre}V = {V:g} m/s"] = dict(R=Rarr, y=y, _color=c, _width=0.8, _nolegend=1)
            n_min = next((o.get("nz_perm", np.nan) for o in L if o["ok"] and o["R"] == Rm), np.nan)
            rmin_rows.append(dict(V=V, R=Rm, n=n_min))
            nlim = ac.performance.load_factor
            if np.isfinite(n_min):
                okn = n_min <= nlim
                checks.append(Check("ok" if okn else "atencao", f"fator de carga no raio mínimo a {V:g} m/s",
                                    f"n = {n_min:.2f}", f"≤ {nlim:g} (n de projeto)",
                                    "" if okn else "a curva mais fechada passa do fator de carga de projeto da estrutura",
                                    "" if okn else "abra a curva ou suba o n de projeto (Montagem → desempenho)", "Curvas"))
            fails = sorted([o for o in L if not o["ok"] and (not np.isfinite(Rm) or o["R"] < Rm)], key=lambda o: -o["R"])
            why = fails[0]["motivo"] if fails else ""
            checks.append(Check("info" if np.isfinite(Rm) else "falha", f"raio mínimo a {V:g} m/s",
                                f"{Rm:.1f} m" if np.isfinite(Rm) else "nenhum raio passa", "menor R que passa",
                                f"o raio menor seguinte falha por: {why}" if why else "",
                                "mais velocidade, mais área de asa ou mais tração" if why else "", "Curvas"))
        series["cr_limite C_L/C_Lmax"] = dict(_hline=ac.autopilot.kCL, _color="#d62728", _dash="dash")
        series["ch_limite"] = dict(_hline=hloss, _color="#d62728", _dash="dash")
        series[f"cn_n de projeto = {ac.performance.load_factor:g}"] = dict(_hline=ac.performance.load_factor,
                                                                          _color="#d62728", _dash="dash")
        series[f"ct_n de projeto = {ac.performance.load_factor:g}"] = dict(_hline=ac.performance.load_factor,
                                                                          _color="#d62728", _dash="dash")
        V = np.array([r["V"] for r in rmin_rows])
        R = np.array([r["R"] for r in rmin_rows])
        series["rm_R mínimo simulado"] = dict(V=V, R=R, _symbol="o", _line=1, _color="#1f77b4")
        if np.isfinite(R).any():
            i = int(np.nanargmin(R))
            series["rm_★ menor raio"] = dict(V=V[i:i + 1], R=R[i:i + 1], _symbol="star", _color="#ffcc00")
        series["casos"] = {k: np.array([c.get(k, np.nan) for c in all_cases], dtype=object if k == "motivo" else float)
                           for k in ("V", "R", "ok", "phi_perm", "nz_perm", "n_estol_perm", "razao_max", "perda_h",
                                     "R_real", "motivo")}
        summary = {f"R_min @ {r['V']:g} m/s": r["R"] for r in rmin_rows}
        summary.update({f"n no R_min @ {r['V']:g} m/s": r["n"] for r in rmin_rows})
        summary["Vs"] = info["Vs"]
        return SimResult(series=series, summary=summary, checks=checks)

    # ------------------------------------------------------------------ MTOW
    def _xcg_over(self, ctx, v, xcg: float) -> dict:
        """r_dry que põe o CG da aeronave inteira (com carga e líquido) em xcg"""
        model = build_model(v)
        with ctx.backend.session_for(model) as s:
            mp = s.mass_props()
        cg = np.asarray(model.mass["cg"], float)
        d = (xcg - float(mp["cg"][0])) * float(mp["m"]) / float(model.mass["m"])
        return dict(r_dry=[float(cg[0] + d), float(cg[1]), float(cg[2])]), float(mp["m"])

    def _mtow(self, ctx, ac, info, refs) -> SimResult:
        """bisseção em t ∈ [0, 1]: a massa total (ou, em tabelas antigas, lastro, LAPES e líquido juntos) vai do
        mínimo ao máximo; em cada t o xCG é testado no mínimo, nominal e máximo e o acionamento do profundor é
        otimizado"""
        table = {r["item"]: r for r in (ctx.params.get("masses") or mtow_rows(ac))}
        keys = {v_: k for k, v_ in ROWS.items()}
        model = build_model(ac)
        ranges, names = {}, {}
        xcgs = None
        for item, r in table.items():
            k = keys.get(item)
            if k is None:
                continue
            lo, nom, hi = (float(r[c]) if r.get(c) not in (None, "") else None for c in ("min", "nom", "max"))
            nom = nom if nom is not None else (lo if lo is not None else 0.0)
            lo = nom if lo is None else lo
            hi = nom if hi is None else hi
            if k == "xcg":                           # % CMA -> metros
                xcgs = sorted({model.x_at_mac(v_ / 100.0) for v_ in (lo, nom, hi)})
            elif k == "xcg_m":
                xcgs = sorted({lo, nom, hi})
            else:
                ranges[k], names[k] = (lo, hi), item
        if xcgs is None:
            xcgs = [float(info["cg"][0])]
        ctrl = TO.pitch_control(ac)
        rows, saved = [], {}

        def evaluate(t):
            ctx.check()
            v, got = mass_variant(ac, ranges, t)
            best_all, m_tot = None, 0.0
            for x in xcgs:
                over, m_tot = self._xcg_over(ctx, v, x)
                b, tried = self._optimize(ctx, v, refs, over)
                b.xcg, b.over = x, over
                key = lambda r: (r.ok, r.x_warning_margin if r.ok else -(r.x_excess + r.z_short))
                if best_all is None or key(b) > key(best_all):
                    best_all, saved[t] = b, tried
            best_all.variant, best_all.masses, best_all.m_tot = v, got, m_tot
            rows.append(dict(t=t, m=m_tot, ok=float(best_all.ok), n_dec=best_all.n_dec, s=best_all.s, de=best_all.de,
                             xcg=best_all.xcg, x=best_all.x_excess, z=best_all.z_short,
                             **{f"m_{k}": got[k] for k in got}))
            return best_all

        checks = []
        b_lo = evaluate(0.0)
        if not ranges or all(lo == hi for lo, hi in ranges.values()):
            b_hi, tm, best = None, (0.0 if b_lo.ok else float("nan")), b_lo
        else:
            b_hi = evaluate(1.0) if b_lo.ok else None
            if not b_lo.ok:
                tm, best = float("nan"), b_lo
            elif b_hi.ok:
                tm, best = 1.0, b_hi
                checks.append(Check("atencao", "MTOW acima da tabela", "decola com tudo no máximo", "dentro", "",
                                    "aumente os máximos", "MTOW"))
            else:
                lo, hi, best = 0.0, 1.0, b_lo
                for it in range(9):
                    ctx.on_progress((it + 1) / 9, f"MTOW: bisseção {it + 1}/9")
                    mid = 0.5 * (lo + hi)
                    b = evaluate(mid)
                    if b.ok:
                        lo, best = mid, b
                    else:
                        hi = mid
                tm = lo
        if not np.isfinite(tm):
            checks.append(Check("falha", "não decola nem com tudo no mínimo", "x_warning ou z_warning",
                                f"x ≤ {refs['x_warning']:g} m, z = {refs['z_warning']:g} m", "",
                                "baixe os mínimos, aumente a tração, a área de asa ou a pista", "MTOW"))
        rows.sort(key=lambda r: r["m"])
        M = {k: np.array([r[k] for r in rows], float) for k in rows[0]}
        ok = M["ok"] > 0
        S = {"mt_decola": dict(m=M["m"][ok], y=M["n_dec"][ok], _symbol="o", _color="#2ca02c", _size=10),
             "mt_não decola": dict(m=M["m"][~ok], y=np.where(np.isfinite(M["n_dec"][~ok]), M["n_dec"][~ok], np.nan),
                                   _symbol="x", _color="#d62728", _size=12),
             f"mt_x_warning = {refs['x_warning']:g} m": dict(_hline=refs["x_warning"], _color="#d62728", _width=3),
             "mtow_casos": M}
        colors = {"pay": "#6a0dad", "liq": "#17becf", "bal": "#444444", "tot": "#ff7f0e"}
        for k in ranges:
            S[f"mc_{names[k]}"] = dict(m=M["m"], y=M[f"m_{k}"], _symbol="o", _line=1, _color=colors[k])
        S["ma_acionamento (m)"] = dict(m=M["m"][ok], y=M["s"][ok], _symbol="o", _line=1, _color="#2ca02c")
        S["ma_δe (°)"] = dict(m=M["m"][ok], y=M["de"][ok], _symbol="s", _line=1, _color="#1f77b4")
        S["ma_xCG (% CMA)"] = dict(m=M["m"][ok], y=np.array([xcg_pct(model, x) for x in M["xcg"][ok]]), _symbol="d",
                                   _line=1, _color="#9467bd")
        summary = dict(massa_atual=info["mass"], x_warning=refs["x_warning"], z_warning=refs["z_warning"])
        log = None
        if np.isfinite(tm):
            mt = best.m_tot
            summary["MTOW (kg)"] = mt
            # guardado para a missão, a decolagem e as curvas desta pista ("Massa": "MTOW salvo desta pista")
            self._saved()[self._runway(ctx.aircraft, refs["x_warning"], refs["z_warning"])] = (best.variant, best.over, mt)
            for k, m in best.masses.items():
                summary[f"MTOW: {names[k]}"] = m
            summary.update({"MTOW: xCG (m)": best.xcg, "MTOW: xCG (% CMA)": xcg_pct(model, best.xcg), "acionamento (m)": best.s, "δe (°)": best.de,
                            "n_dec (m)": best.n_dec})
            for pre in ("mt_", "mc_", "ma_"):
                S[f"{pre}MTOW = {mt:.2f} kg"] = dict(_vline=mt, _color="#ffcc00", _width=3)
            S["mt_★ MTOW"] = dict(m=np.array([mt]), y=np.array([best.n_dec]), _symbol="star", _color="#ffcc00", _size=24)
            parts = ", ".join(f"{names[k]} = {m:.2f}" for k, m in best.masses.items())
            checks.append(Check("info", "MTOW", f"{mt:.2f} kg", "x e z atendidos",
                                f"{parts}; xCG = {xcg_pct(model, best.xcg):.1f} % CMA ({best.xcg:.3f} m); acionamento em {best.s:.1f} m, δe = {best.de:g}°",
                                "salvo: na missão, na decolagem e nas curvas, Massa → 'MTOW salvo desta pista'", "MTOW"))
            S.update(self._opt_series(saved.get(tm, []), best, refs))
            v = best.variant
            res, log = TO.evaluate(ctx.backend, v, best.s if ctrl else None, best.de, refs["x_warning"], refs["z_warning"],
                                   best.over, dtlog=0.005, log=True, de0=best.de0)
            if len(log):
                S.update(self._takeoff_series(log, res.events, v, refs))
            checks += self._takeoff_checks(v, best, refs, ctrl)
        return SimResult(log=log, series=S, summary=summary, checks=checks)

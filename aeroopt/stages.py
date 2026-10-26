"""As etapas do avaliador em etapas, do aeroopt (o caminho principal; o mini-MDO segue como alternativa).

O processo é o da sprint, quebrado em etapas que todos os candidatos atravessam juntos:

    configurações         as combinações das escolhas discretas livres (motor, hélice, perfil, arranjo, nº de
                          motores): cada combinação é um candidato
    superfícies           para cada configuração, um otimizador pequeno acerta as variáveis contínuas livres
                          (envergadura, área, inclinação...) pela decolagem: cada ponto é o ponto de projeto
                          acoplado (`power.design_point`: asa calada e EH retrimada com a tração, na massa que a
                          pista deixa levar), e ganha o maior MTOW que fecha a estabilidade
    decolagem 6GDL        o MTOW de cada sobrevivente na simulação 6GDL (aba Missão, modo MTOW), um processo
                          por candidato
    nota                  a pontuação do ano (ou o objetivo simples), no núcleo, para todos de uma vez

Entre uma etapa e outra todos esperam (`pipeline.Pipeline`); é isso que deixa cada etapa paralela. As contas
pesadas (linha sustentadora, desempenho, 6GDL, nota) são do núcleo em Zig; aqui só se orquestra.

O otimizador das superfícies é a busca por coordenadas com passo que encolhe ("compass search"): tenta ± passo
em cada variável, aceita a primeira que melhora e, se nenhuma melhora, divide o passo por dois. Kolda, Lewis e
Torczon, "Optimization by direct search", SIAM Review 45(3), 2003, seção 3 (a conferir no PDF). Foi escolhida
porque não precisa de derivada (o ponto de projeto tem saltos: viável ou não) e gasta poucas avaliações com
duas ou três variáveis.

    ev = StagedEvaluator(projeto)
    res = StagedSolver().run(problema, ev, progress=lambda f, t: print(f"{f:4.0%} {t}"))
"""
from __future__ import annotations

import copy
import itertools
import math
import zlib
from dataclasses import dataclass

import numpy as np

from aerosim.design import mdo, study
from aerosim.design import power as pw
from aerosim.design import registry as rg
from aerosim.design import tail as tl
from aerosim.interfaces.optim import (
    IEvaluator,
    ISolver,
    IStage,
    OptProblem,
    OptResult,
    StageItem,
)
from aerosim.parallel import check_cancel

from . import categories as cat
from . import inputs as inp
from . import scoring as sc
from .pipeline import Pipeline
from .problem import apply_to_project, fold_bounds

MAX_CONFIGS = 256
AIRFOIL_KEYS = tuple(k for k, i in inp.all_inputs().items() if i.source == "perfis")
SHORT = {"wing.airfoil": "perfil raiz", "wing.airfoil_tip": "perfil ponta", "tail.airfoil": "perfil EH",
         "tail.vairfoil": "perfil EV", "power.motor": "motor", "power.propeller": "hélice",
         "power.battery": "bateria", "power.motors": "nº de motores", "power.layout": "arranjo",
         "tail.layout": "cauda"}
TAIL_KEY = "tail.layout"


def short(key: str) -> str:
    """o nome curto de uma variável, para o nome da configuração e as tabelas ("airfoil" sozinho não diz qual)"""
    return SHORT.get(key) or key.partition(".")[2] or key


def set_value(project, key: str, value) -> None:
    inp.set_value(project, key, value)


def get_value(project, key: str):
    return inp.get_value(project, key)


def available(project, key: str, catalog=None) -> list[str]:
    """tudo o que uma variável de lista pode escolher (os perfis, o catálogo de motores, hélices e baterias, as
    escolhas do campo)"""
    i = inp.get(key)
    src = i.source if i else ""
    if src == "perfis":
        return list(mdo.airfoil_catalog(project))
    if src in ("escolhas", "sim/não") and i.choices:
        return list(i.choices)
    from aerosim.model.catalog import builtin_catalog
    c = catalog or builtin_catalog()
    if src == "baterias":
        return [b.name for b in c.batteries]
    if src in ("motores", "hélices"):
        return [m.name for m in (c.motors if src == "motores" else c.propellers)]
    return mdo.available(project, key, catalog)


def candidate(project, values: dict):
    """o avião dos rascunhos do projeto com estes valores (a asa, o conjunto e os motores da sprint)"""
    p = copy.deepcopy(project)
    if cat.KEY in values:
        cat.apply(p, values[cat.KEY])
    for k, v in values.items():
        if k == cat.KEY:
            continue
        if k in AIRFOIL_KEYS and v and p.airfoil(v) is None:
            e = mdo.airfoil_catalog(p).get(v)          # perfil da biblioteca que o projeto ainda não tem
            if e is not None:
                p.airfoils.append(copy.deepcopy(e))
        set_value(p, k, v)
    w = p.draft_wing()
    td = p.tail_draft
    w2 = w if td.wing2 == tl.SAME_WING else (p.wing(td.wing2) if td.wing2 and td.wing2 != tl.NO_WING2 else None)
    s = tl.SetCandidate(copy.deepcopy(td), w, wing2=copy.deepcopy(w2) if w2 is not None else None)
    return p, pw.AircraftCandidate(copy.deepcopy(p.power_draft), s)


def apply_values(project, values: dict) -> None:
    """leva os valores de um candidato para os rascunhos do projeto (a categoria primeiro, depois as variáveis)"""
    if cat.KEY in values:
        cat.apply(project, values[cat.KEY])
    p, _ = candidate(project, {k: v for k, v in values.items() if k != cat.KEY})
    for k in values:
        if k != cat.KEY:
            set_value(project, k, get_value(p, k))
    project.airfoils = p.airfoils


def design(project, problem: OptProblem, values: dict, catalog=None) -> dict:
    """o ponto de projeto de um candidato, refeito (para ver o avião: o 3D, as massas)"""
    p = copy.deepcopy(project)
    apply_to_project(problem, p)
    q, cand = candidate(p, values)
    return pw.design_point(cand, q.requirements, q.rules, catalog, q.airfoil_map())


def axes(project, problem: OptProblem, catalog=None) -> list[tuple[str, list]]:
    """os eixos discretos da busca: as categorias escolhidas e cada variável de lista ou inteira livre, com as opções"""
    out = []
    cats = list(problem.params.get("categorias") or [])
    for c in cats:
        cat.fields(c)                                 # nome errado para aqui, antes de rodar
    if cats:
        out.append((cat.KEY, cats))
    for v in problem.free_variables():
        if v.kind == "lista":
            known = available(project, v.key, catalog)
            unknown = [o for o in v.options if known and o not in known]
            if unknown:
                raise ValueError(f"{v.key}: {', '.join(unknown)} não existe (há {', '.join(known)})")
            out.append((v.key, list(dict.fromkeys(v.options)) or known))
        elif v.kind == "inteira":
            out.append((v.key, inp.integer_values(inp.get(v.key), v.lo, v.hi)))
    return out


def config_item(values: dict, index: int) -> StageItem:
    name = ", ".join(str(x) if k == cat.KEY else f"{short(k)}={x}" for k, x in values.items()) or "configuração única"
    return StageItem(name=name, values=dict(values), data={"index": index})


def configurations(project, problem: OptProblem, catalog=None) -> list[StageItem]:
    """um candidato por combinação das variáveis discretas livres (lista e inteira) e das categorias escolhidas;
    acima de MAX_CONFIGS combinações, quem escolhe é o `GenerationsSolver` (aeroopt/generations.py)"""
    ax = axes(project, problem, catalog)
    n = math.prod(len(o) for _, o in ax) if ax else 1
    if n > MAX_CONFIGS:
        raise ValueError(f"{n} configurações (o limite para varrer todas é {MAX_CONFIGS}): use as gerações")
    keys = [k for k, _ in ax]
    return [config_item(dict(zip(keys, combo)), i + 1) for i, combo in enumerate(itertools.product(*(o for _, o in ax)))]


def _rank(r: dict) -> tuple:
    """as regras de viabilidade (Deb, "An efficient constraint handling method for genetic algorithms", Computer
    Methods in Applied Mechanics and Engineering 186, 2000, seção 3, a conferir no PDF): o ponto que fecha ganha de
    todo ponto que não fecha; entre dois que fecham ganha o de maior MTOW; entre dois que não fecham ganha o que viola
    menos. Assim a busca anda para onde o avião passa a fechar, em vez de procurar o MTOW maior entre os que não
    fecham"""
    if r["ok"]:
        m = r["mtow"]
        return (1, m if math.isfinite(m) else -math.inf)
    return (0, -r.get("viol", math.inf))


def _fit(r: dict) -> float:
    """o mesmo `_rank` num número só, para o algoritmo genético do núcleo (que ordena por posição)"""
    a, b = _rank(r)
    if not math.isfinite(b):
        return math.nan
    return b if a else -1e9 + b


def _eval(x: dict, r: dict) -> dict:
    """uma avaliação da busca, para o histórico (e o CSV)"""
    return dict(values=dict(x), mtow=r.get("mtow", math.nan), ok=r["ok"], why=r["why"], pv=r.get("pv", math.nan),
                b=r.get("b", math.nan), m_bat=r.get("m_bat", math.nan), viol=r.get("viol", 0.0))


def violation(d: dict, stab: dict | None = None, stab_params=None, rotation: bool = False) -> tuple[float, list[str]]:
    """quanto um ponto de projeto viola o que é preciso para voar, somado em escalas parecidas (cada termo vale 1
    na fronteira de "bem fora"), e o motivo de cada termo. `d`: o ponto de projeto ou a montagem ({"asm": ...}).
    Com `rotation` (a rodada interna da E&C), o comando de arfagem tem de rodar o avião antes da velocidade de sair
    do chão, e o termo cresce com o quanto falta: V_rot / V_lof − 1, mais 1 se não roda em velocidade nenhuma. Sem
    ele, vale o de sempre: só não rodar em velocidade nenhuma conta"""
    asm = d["asm"]
    tr, st = asm.get("trim") or {}, asm["set"]
    out: list[tuple[float, str]] = []
    v_rot, v_lof = tr.get("V_rot", 0.0), tr.get("V_lof", math.inf)
    if tr.get("lifts_off") and math.isfinite(v_rot):   # sai do chão na atitude da corrida: não precisa rodar
        pass
    elif rotation and "rot_table" in tr and not v_rot <= v_lof:
        if math.isfinite(v_rot):
            gap = v_rot / v_lof - 1.0
        else:                                        # nem a 40 m/s: o quanto o maior momento cabrando não cobre o peso
            _, M, arm = tr["rot_table"]
            need = float(asm["mass"]) * 9.80665 * arm
            gap = 1.0 + max(0.0, 1.0 - float(np.max(M)) / need) if need > 0 else 1.0
        out.append((gap, f"o comando de arfagem só roda o avião a {v_rot:.1f} m/s (sai do chão a {v_lof:.1f})"
                    if math.isfinite(v_rot) else "o profundor não consegue rodar o avião"))
    elif not math.isfinite(v_rot):
        out.append((1.0, "o profundor não consegue rodar o avião"))
    if not tr.get("hold_ok", True):
        out.append((1.0, "trim de decolagem passa do curso de picar"))
    if "CL_trim_max" in tr and not tr["CL_trim_max"] >= tr["CL_lof"]:
        cl = tr["CL_trim_max"]
        out.append(((tr["CL_lof"] / cl - 1.0) if cl > 0 else 2.0 + max(-tr.get("Cm_up_max", 0.0), 0.0) / 0.05,
                    f"trimado, o C_L máximo é {cl:.2f}; a velocidade de estol pedida pede {tr['CL_lof']:.2f}" if cl > -math.inf
                    else "o comando não trima o avião em α nenhum"))
    if tr.get("climb_M", -1.0) > 0:                  # E&C pelo núcleo: o comando não segura o nariz no ar
        out.append((min(tr["climb_M"] / tr["climb_scale"], 3.0) + 0.1,
                    "logo depois de sair do chão o comando todo picando não segura o nariz com o motor cheio"))
    if tr.get("ground_stall", -1.0) > 0:
        out.append((tr["ground_stall"] / 0.2 + 0.1, "na atitude do chão a asa corre perto do estol (sai do chão "
                    "estolada)"))
    if not tr.get("tip_ok", True):
        out.append((1.0, "na atitude do chão o CG fica atrás do trem principal (o avião senta para trás)"))
    if "CLh_lim" in st:
        lo, hi = st["CLh_lim"]
        x = st["CLh_CLmax"]
        if not lo <= x <= hi:
            out.append((min(abs(x - lo), abs(x - hi)) / max(hi - lo, 0.1), "EH estola no C_L,max"))
    if not asm["battery_fits"]:
        out.append((asm["ballast"] / 0.05, f"precisa de {asm['ballast']:.2f} kg de lastro de equilíbrio"))
    sm_min = getattr(getattr(d.get("cand"), "set", None), "params", None)
    sm_min = getattr(sm_min, "sm_min", None)
    if sm_min is not None and asm.get("sm") is not None and asm["sm"] < sm_min:
        out.append(((sm_min - asm["sm"]) / 5.0, f"margem estática {asm['sm']:.1f} % < {sm_min:g} %"))
    if "mtow" in d and not math.isfinite(d["mtow"]):
        out.append((1.0, "não decola na pista"))
    if stab:
        if "Cnb" in stab and stab["Cnb"] <= 0:
            out.append((-stab["Cnb"] / 0.02 + 0.1, f"instável direcional (C_nβ = {stab['Cnb']:.3f} /rad)"))
        if "Clb" in stab and stab["Clb"] >= 0:
            out.append((stab["Clb"] / 0.02 + 0.1, f"instável em rolamento (C_lβ = {stab['Clb']:.3f} /rad)"))
        lim = stab_params.level if stab_params is not None else 3
        for k, v in stab.items():
            if k not in ("Cnb", "Clb") and isinstance(v, int) and v > lim:
                out.append((float(v - lim), f"{k}: nível {v} (aceito até {lim})"))
    return sum(v for v, _ in out), [w for _, w in out]


def core_rotation(ac, asm: dict, rules, rho: float, backend, v_need: float | None = None) -> dict | None:
    """a conta de "o comando de arfagem roda o avião?" da montagem (`power.thrust_trim`) refeita com os
    coeficientes do núcleo, o mesmo modelo da corrida 6GDL, em vez da conta analítica da sprint. Os momentos são no
    trem principal (+ cabra), com o avião no chão (α = 0) e o comando todo cabrando (−de_max):

        M(V) = q S c C_m,CG + q S C_L (x_CG − x_TP) + M_tração(V) − W (x_CG − x_TP)

    a mesma soma de `thrust_trim` (o arrasto na altura do trem fica de fora nas duas). Devolve o `trim` da montagem
    com `V_rot` e `rot_table` do núcleo, ou None quando não há corrida para conferir (sem motor ou sem triciclo)"""
    from aerosim.model.universal import build_model
    tr = asm.get("trim") or {}
    v_need = v_need or tr.get("V_lof", 10.0)
    us = [u for u in ac.propulsion if u.enabled]
    if "rot_table" not in tr or not us or ac.gear.layout != "tricycle":
        return None
    Vgrid, _, _ = tr["rot_table"]
    model = build_model(ac)
    S, c, x_cg, z_cg = model.S, model.c, float(model.mass["cg"][0]), float(model.mass["cg"][2])
    x_mg, gz = ac.gear.main_x, ac.gear.main_z
    th = math.radians(pw.ground_pitch(ac))          # atitude no chão: α da corrida e o braço horizontal
    arm = x_cg - x_mg
    if th > 0:
        arm = arm * math.cos(th) - (gz - z_cg) * math.sin(th)
    W = float(asm["mass"]) * pw.G0
    with backend.session_for(model) as s:
        k = s.aero_coeffs(10.0, th, de=-math.radians(rules.de_max))
        CLg = s.aero_coeffs(10.0, th)["CL"] if th > 0 else 0.0
    Tv = pw.thrust_of(ac, Vgrid, rho, None) / len(us)
    Mth = np.array([pw._thrust_moment(us, t, x_mg, gz) for t in Tv])
    rot_a = 0.5 * rho * Vgrid ** 2 * S * (c * k["Cm"] + k["CL"] * arm) + Mth     # sem o momento do peso
    up = np.nonzero(rot_a - W * arm > 0)[0]
    v_rot = float(Vgrid[up[0]]) if len(up) else math.inf
    if th > 0 and CLg > 0:                          # sai do chão sem rodar quando a asa no ângulo sustenta
        v_rot = min(v_rot, math.sqrt(2 * W / (rho * S * CLg)))
    # logo depois de sair do chão, com o motor cheio: o comando todo picando (de_down) segura o nariz? No α em que
    # a asa sustenta o peso na velocidade de sair do chão, o momento no CG (aerodinâmico + tração) tem de picar.
    # Um motor inclinado para cima ajuda a rodar, mas no ar continua cabrando e, leve e devagar, capota o avião
    v = min(max(v_rot, tr.get("V_lof", v_rot)), float(Vgrid[-1])) if math.isfinite(v_rot) else tr.get("V_lof", 10.0)
    qq = 0.5 * rho * v * v
    dn = math.radians(rules.de_down)
    with backend.session_for(model) as s:
        k0, k1 = s.aero_coeffs(10.0, 0.0, de=dn), s.aero_coeffs(10.0, math.radians(8.0), de=dn)
        a_lof = (W / (qq * S) - k0["CL"]) / max((k1["CL"] - k0["CL"]) / math.radians(8.0), 1e-6)
        a_lof = min(max(a_lof, th), math.radians(20.0))
        Cm = s.aero_coeffs(10.0, a_lof, de=dn)["Cm"]
    if "CL_trim_max" in tr:
        cl_trim, cm_up = tr["CL_trim_max"], tr["Cm_up_max"]
    else:
        cl_trim, cm_up = pw.trimmed_clmax(ac, rules.de_max, rules.de_down, backend)
    T = float(pw.thrust_of(ac, np.array([v]), rho, None)[0]) / len(us)
    M_climb = qq * S * c * Cm + pw._thrust_moment(us, T, x_cg, z_cg)
    return {**tr, "V_rot": v_rot, "rot_table": (Vgrid, rot_a, arm), "rot_core": True, "lifts_off": th > 0 and CLg > 0,
            "climb_M": float(M_climb), "climb_scale": float(qq * S * c * 0.05),
            "CL_trim_max": float(cl_trim), "Cm_up_max": float(cm_up), "CL_lof": float(W / (0.5 * rho * v_need ** 2 * S))}


# os métodos da busca das superfícies (a GUI escolhe no menu Configuração)
SURFACE_METHODS = {"coordenadas": "busca por coordenadas (um eixo por vez, passo cai à metade)",
                   "gerações": "gerações nas contínuas (algoritmo genético do núcleo)",
                   "cma-es": "CMA-ES nas contínuas (aprende a forma da região boa; núcleo)",
                   "de": "evolução diferencial nas contínuas (o passo sai das diferenças da população; núcleo)"}


class SurfaceSizing(IStage):
    """as variáveis contínuas livres de uma configuração, pelo maior MTOW viável na pista"""
    name = "superfícies"

    def __init__(self, project, problem: OptProblem, catalog=None, evals: int = 24, geometry=None,
                 method: str = "coordenadas", stability: StabilityParams | None = None):
        self.project, self.catalog, self.evals = project, catalog, int(evals)
        self.geometry = geometry                   # GeometryParams: cada ponto também passa pela geometria
        self.stability = stability                 # StabilityParams: e pela estabilidade (desligada por padrão)
        self._backend = None                       # criado no processo que roda a etapa
        if method not in SURFACE_METHODS:
            raise ValueError(f"método das superfícies desconhecido: {method}")
        self.method = method
        self.free = [(v.key, min(v.lo, v.hi), max(v.lo, v.hi)) for v in problem.free_variables()
                     if v.kind == "contínua"]

    def __getstate__(self):                        # o núcleo (ctypes) não vai para outro processo
        return {**self.__dict__, "_backend": None}

    def point(self, values: dict) -> dict:
        check_cancel()                             # o Parar combinado: sai entre um ponto e outro
        p, cand = candidate(self.project, values)
        d = pw.design_point(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
        ok, why = study.feasibility(d)
        if ok and self.geometry is not None:
            g = geometry_check(d["ac"], self.geometry)
            if g.only_ground:                     # as superfícies mudaram a cauda: o trem desce de novo
                values = {**values, GEAR_KEY: gear_fix(d["ac"], g)}
                p, cand = candidate(self.project, values)
                d = pw.design_point(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
                ok, why = study.feasibility(d)
                g = geometry_check(d["ac"], self.geometry)
            if ok:
                ok, why = g.ok, ("geometria: " + g.why()) if not g.ok else why
        stab = {}
        if ok and self.stability is not None:
            if self._backend is None:
                from aerosim.backend.zig import ZigBackend
                self._backend = ZigBackend()
            ok, w, stab = stability_check(d["ac"], p.requirements.V_cruise, self.stability, self._backend)
            why = ("estabilidade: " + w) if not ok else why
        viol = 0.0
        if not ok:
            viol, _ = violation(d, stab, self.stability)
            viol = viol or 1.0                    # não fecha por algo que a soma não mede (uma restrição)
        asm = d["asm"]
        m_bat = sum(i.mass for i in asm["items"] if i.name == "bateria")
        return dict(values=dict(values), mtow=float(d["mtow"]), ok=ok, why=why, pv=float(asm["empty"]),
                    m_bat=float(m_bat), b=float(d["cand"].set.wing.params.span), n_sup=n_surfaces(d["cand"].set),
                    s_to=float(p.requirements.takeoff_run), lapes=bool(cand.params.lapes),
                    liquid=bool(cand.params.liquid), cand=d["cand"], req=d["req"], stab=stab, viol=viol)

    def one(self, item: StageItem) -> StageItem:
        # parte do ponto que a etapa "voa" achou, se achou; senão, do avião como está
        x = {k: min(max(float(item.values.get(k, get_value(self.project, k))), lo), hi) for k, lo, hi in self.free}
        best = self.point({**item.values, **x})
        hist = [_eval(x, best)]
        if self.method == "gerações":
            x, best = self._generations(item, x, best, hist)
        elif self.method == "cma-es":
            x, best = self._generations(item, x, best, hist, _cma_search)
        elif self.method == "de":
            x, best = self._generations(item, x, best, hist, _de_search)
        else:
            x, best = self._coordinates(item, x, best, hist)
        item.values = {**item.values, **x, **best["values"]}     # com o trem que a geometria desceu, se desceu
        item.data.update(best, history=hist)
        item.alive, item.why = best["ok"], best["why"]
        return item

    def _coordinates(self, item: StageItem, x: dict, best: dict, hist: list) -> tuple[dict, dict]:
        """busca por coordenadas: anda um passo em cada eixo; sem melhora em nenhum, o passo cai à metade"""
        step = {k: 0.25 * (hi - lo) for k, lo, hi in self.free}
        while self.free and len(hist) < self.evals and any(step[k] > 1e-3 * (hi - lo) for k, lo, hi in self.free):
            moved = False
            for (k, lo, hi), sgn in itertools.product(self.free, (1.0, -1.0)):
                if len(hist) >= self.evals:
                    break
                y = dict(x)
                y[k] = min(max(x[k] + sgn * step[k], lo), hi)
                if y[k] == x[k]:
                    continue
                r = self.point({**item.values, **y})
                hist.append(_eval(y, r))
                if _rank(r) > _rank(best):
                    x, best, moved = y, r, True
                    break
            if not moved:
                step = {k: 0.5 * s for k, s in step.items()}
        return x, best

    def _generations(self, item: StageItem, x: dict, best: dict, hist: list, search=None) -> tuple[dict, dict]:
        """o algoritmo genético do núcleo nas contínuas (`_real_search`): o primeiro indivíduo é o ponto de partida,
        cada gene cai no passo do campo (o diedro de meio em meio grau) e um avião que já apareceu não gasta
        avaliação. Sem isso a população pequena vira cópias do melhor e a busca gasta o total refazendo o mesmo
        ponto. `search` troca a busca (`_cma_search`) mantendo o resto"""
        if not self.free or self.evals <= 1:
            return x, best
        return (search or _real_search)(self.free, x, best, lambda y: self.point({**item.values, **y}), self.evals,
                                        hist, seed=1 + zlib.crc32(item.name.encode()) % 100_000)


# os métodos da etapa "voa" (a GUI escolhe no menu Configuração)
# as caudas que a etapa voa (E&C) pode escolher para um avião, na ordem em que desempatam
TAILS = ("convencional", "em H", "em V", "sem cauda")
LAYOUT_KEY, PUSHER = "power.layout", "propulsora atrás da asa"
TIP_KEY = "wing.airfoil_tip"        # a asa voadora com os comandos: perfil simétrico na ponta, onde fica o elevon
FLAP_KEY = "tail.flap_moment"      # a E&C com os comandos liga o momento próprio deles (modifiers/flapmoment.zig)
# os comandos que a rodada interna da E&C ajusta, por tipo de avião (chave, mínimo, máximo). O curso vai até 30°,
# o que um servo comum dá com folga; o elevon pode ir até a corda de 50 % e da raiz (5 %) à ponta
CONTROLS = {
    "com cauda": (("tail.elevator", 0.25, 0.5), ("rules.de_max", 15.0, 30.0), ("power.tilt", 0.0, 12.0)),
    "asa voadora": (("tail.sm_target", 4.0, 12.0), ("tail.aileron_start", 0.05, 0.6), ("tail.aileron_end", 0.8, 1.0), ("tail.aileron_chord", 0.2, 0.5),
                    ("rules.de_max", 15.0, 30.0), ("power.tilt", 0.0, 12.0), ("power.ground_pitch", 0.0, 12.0),
                    ("power.x_tdp", 0.03, 0.25), ("wing.sweep", 0.0, 40.0), ("wing.twist", -6.0, 0.0),
                    ("wing.rect_frac", 0.0, 1.0), ("wing.taper", 0.4, 1.0)),
}
def elevon_airfoil(project, values: dict) -> str:
    """o perfil da ponta da asa voadora, onde fica o elevon: o primeiro simétrico (pelo nome) entre os do projeto e
    os da biblioteca. A raiz fica com o perfil de alta sustentação da asa (S1223 e afins), que tem um C_m muito
    negativo: sozinho, ele só trima com o elevon para cima, e o elevon para cima tira a sustentação. Um perfil sem
    momento na ponta, com enflechamento e torção para baixo, dá o C_m positivo que trima a asa sem cauda (Nickel e
    Wohlfahrt, "Tailless Aircraft in Theory and Practice", cap. 3; a conferir no PDF). Vazio: nenhum simétrico"""
    from aerosim.design import airfoils as afm
    p, _ = candidate(project, values)
    sym = sorted(n for n, e in p.airfoil_map().items() if afm.symmetric(getattr(e, "airfoil", e)))
    return sym[0] if sym else ""


# de onde a busca dos comandos parte, quando o indivíduo não traz o valor: a asa voadora parte de uma asa enflechada
# com torção para baixo e afilada, que é o que dá C_m positivo sem cauda (a de data/aircraft/Asa_voadora.json tem
# uns 25° e −4°); a reta do exemplo fica longe demais disso para a busca achar
CONTROL_START = {"asa voadora": {"wing.sweep": 25.0, "wing.twist": -5.0, "wing.rect_frac": 0.2, "wing.taper": 0.5,
                                 "tail.sm_target": 6.0, "tail.aileron_start": 0.3, "tail.aileron_chord": 0.35,
                                 "power.ground_pitch": 5.0, "power.tilt": 0.0}}
FLY_METHODS = {"buscar": "achar um ponto que voa (gerações nas contínuas, pelas regras de viabilidade)",
               "cma-es": "achar um ponto que voa (CMA-ES nas contínuas, pelas regras de viabilidade)",
               "de": "achar um ponto que voa (evolução diferencial nas contínuas, pelas regras de viabilidade)",
               "conferir": "só conferir o avião como está"}


class FlightCheck(IStage):
    """antes do desempenho: o avião da configuração voa? Na massa estimada do projeto, sem procurar o MTOW, ele tem
    que trimar (o profundor roda o avião e segura o trim, a EH não estola), equilibrar sem lastro, ter a margem
    estática mínima e, com a restrição de estabilidade ligada, ser estável. É mais barato que um ponto de projeto
    (não corre a pista) e separa os dois problemas: primeiro achar algo que voa, depois fazer voar melhor. Quando o
    avião como está não voa, a etapa procura nas contínuas livres o ponto que viola menos (as regras de viabilidade
    de Deb) até achar um que voa; as superfícies partem dele.

    Com `tails` (algumas de `TAILS`), a etapa também escolhe a cauda, porque a cauda é assunto de estabilidade e
    controle e não um tipo de avião: para a asa (ou o par de asas) de cada configuração ela roda a mesma busca com
    cada cauda e fica com a que voa. Entre as que voam, um ponto de projeto em cada uma desempata: ganha a que
    decola na pista com a maior carga paga (MTOW − PV), e no empate a primeira da lista. Só voar não basta: sem
    cauda o avião é o mais leve e voa, mas pode não rodar na pista. A escolha muda o indivíduo
    (`values["tail.layout"]`), e as etapas seguintes usam essa cauda.
    Uma categoria que já define a cauda (tandem, asa voadora) ou uma cauda livre no problema fica como está. Cada
    cauda gasta até as avaliações da etapa.

    Com `controls`, a busca também mexe nos comandos (`CONTROLS`: a corda e o trecho do elevon, a corda do
    profundor, o curso e a inclinação do motor), além das contínuas livres do problema, e o comando de arfagem tem de
    rodar o avião antes da velocidade de sair do chão (`violation(..., rotation=True)`, pelo núcleo). É o que faz uma
    asa voadora decolar: com o elevon de sempre ela só roda depois de sair do chão. Os comandos achados ficam no
    indivíduo, com o momento próprio dos comandos ligado (`tail.flap_moment`), o mesmo na decolagem 6GDL"""
    name = "voa"

    def __init__(self, project, problem: OptProblem, catalog=None, evals: int = 24, method: str = "buscar",
                 stability: StabilityParams | None = None, tails=None, controls: bool = False):
        if method not in FLY_METHODS:
            raise ValueError(f"método da etapa voa desconhecido: {method}")
        unknown = [t for t in tails or () if t not in TAILS]
        if unknown:
            raise ValueError(f"cauda desconhecida: {', '.join(unknown)} (há {', '.join(TAILS)})")
        self.project, self.catalog, self.evals, self.method = project, catalog, int(evals), method
        self.stability = stability
        self.tails = tuple(t for t in TAILS if t in (tails or ()))     # na ordem de TAILS
        self.tail_free = any(v.key == TAIL_KEY for v in problem.free_variables())
        self.controls = bool(controls)
        self.tip_free = any(v.key == TIP_KEY for v in problem.free_variables())
        self.layout_free = any(v.key == LAYOUT_KEY for v in problem.free_variables())
        self.free = [(v.key, min(v.lo, v.hi), max(v.lo, v.hi)) for v in problem.free_variables()
                     if v.kind == "contínua"]
        self._backend = None

    def __getstate__(self):
        return {**self.__dict__, "_backend": None}

    def point(self, values: dict) -> dict:
        check_cancel()                             # o Parar combinado: sai entre um ponto e outro
        p, cand = candidate(self.project, values)
        ac, asm = pw.assemble(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
        if self.controls and self._backend is None:
            from aerosim.backend.zig import ZigBackend
            self._backend = ZigBackend()
        if self.controls:                          # a rotação pelo núcleo: a conta da sprint superestima o elevon
            tr = core_rotation(ac, asm, p.rules, p.requirements.rho, self._backend, p.requirements.V_stall_max)
            asm = {**asm, "trim": tr} if tr is not None else asm
        d = dict(asm=asm, cand=cand)
        viol, why = violation(d, rotation=self.controls)
        stab = {}
        if not why and self.stability is not None:
            if self._backend is None:
                from aerosim.backend.zig import ZigBackend
                self._backend = ZigBackend()
            _, _, stab = stability_check(ac, p.requirements.V_cruise, self.stability, self._backend)
            viol, why = violation(d, stab, self.stability, rotation=self.controls)
        return dict(values=dict(values), ok=not why, why="; ".join(why), viol=viol, mtow=math.nan, stab=stab,
                    pv=float(asm["empty"]))

    def kind(self, values: dict) -> str:
        """o tipo de avião para os comandos: "asa voadora" (sem cauda), "com cauda" """
        layout = values.get(TAIL_KEY)
        if layout is None and cat.KEY in values:
            layout = cat.fields(values[cat.KEY])["tail_draft.layout"]
        if layout is None:
            layout = self.project.tail_draft.layout
        return "asa voadora" if layout == "sem cauda" else "com cauda"

    def free_for(self, values: dict) -> list:
        """as contínuas da busca: as livres do problema e, com `controls`, os comandos do tipo de avião"""
        if not self.controls:
            return self.free
        have = {k for k, _, _ in self.free}
        return self.free + [c for c in CONTROLS[self.kind(values)] if c[0] not in have]

    def _fly(self, item: StageItem, values: dict):
        """(x, melhor ponto, histórico) da busca de um ponto que voa, partindo de `values`"""
        free = self.free_for(values)
        start = {k: v for k, v in CONTROL_START.get(self.kind(values), {}).items()} if self.controls else {}
        x = {k: min(max(float(values.get(k, start.get(k, get_value(self.project, k)))), lo), hi) for k, lo, hi in free}
        best = self.point({**values, **x})
        hist = [_eval(x, best)]
        if not best["ok"] and self.method in ("buscar", "cma-es", "de") and free:
            search = {"cma-es": _cma_search, "de": _de_search}.get(self.method, _real_search)
            x, best = search(free, x, best, lambda y: self.point({**values, **y}), self.evals, hist,
                                   seed=7 + zlib.crc32(item.name.encode()) % 100_000, stop_ok=True)
        return x, best, hist

    def _runway(self, values: dict) -> float:
        """a carga paga (MTOW na pista − PV) de um ponto que voa, num ponto de projeto; NaN se não decola"""
        check_cancel()
        p, cand = candidate(self.project, values)
        d = pw.design_point(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
        ok, _ = study.feasibility(d)
        m = float(d["mtow"])
        return m - float(d["asm"]["empty"]) if ok and math.isfinite(m) else math.nan

    def chooses_tail(self, item: StageItem) -> bool:
        """a etapa escolhe a cauda deste avião: há caudas pedidas, a cauda não é variável do problema e a categoria
        não define a cauda"""
        if not self.tails or self.tail_free or TAIL_KEY in item.values:
            return False
        c = item.values.get(cat.KEY)
        return c is None or cat.fields(c)["tail_draft.layout"] == cat.BASE_TAIL

    def one(self, item: StageItem) -> StageItem:
        if self.controls:                          # o momento próprio dos comandos no núcleo, daqui até o 6GDL
            item.values = {**item.values, FLAP_KEY: True}
            if self.kind(item.values) == "asa voadora" and TIP_KEY not in item.values and not self.tip_free:
                tip = elevon_airfoil(self.project, item.values)
                if tip:
                    item.values = {**item.values, TIP_KEY: tip}
            if self.kind(item.values) == "asa voadora" and LAYOUT_KEY not in item.values and not self.layout_free:
                # sem cauda nem tubo, a hélice vai atrás: o motor no nariz puxa o CG para a frente do que a asa
                # enflechada pede, e só lastro equilibra (a de data/aircraft/Asa_voadora.json também é propulsora)
                item.values = {**item.values, LAYOUT_KEY: PUSHER}
        if self.chooses_tail(item):
            tried = {}
            for t in self.tails:
                x, best, hist = self._fly(item, {**item.values, TAIL_KEY: t})
                tried[t] = (x, best, hist)
            cp = {t: self._runway({**item.values, TAIL_KEY: t, **tried[t][0]}) if tried[t][1]["ok"] else math.nan
                  for t in self.tails}

            def rank(t):                          # voa; decola na pista, com a maior CP; ou viola menos
                b = tried[t][1]
                if not b["ok"]:
                    return (0, 0, -b["viol"], -self.tails.index(t))
                return (1, 1, cp[t], -self.tails.index(t)) if math.isfinite(cp[t]) else (1, 0, 0.0, -self.tails.index(t))
            pick = max(self.tails, key=rank)
            x, best, hist = tried[pick]
            item.values = {**item.values, TAIL_KEY: pick}
            item.data["caudas"] = {t: dict(ok=b["ok"], viol=b["viol"], pv=b["pv"], cp=cp[t], why=b["why"],
                                           pontos=len(h)) for t, (_, b, h) in tried.items()}
            hist = [e for t in self.tails for e in tried[t][2]]   # todas as caudas no histórico da etapa
        else:
            x, best, hist = self._fly(item, item.values)
        item.values = {**item.values, **x}
        item.data["voa"] = dict(history=hist, viol=best["viol"], stab=best["stab"])
        if not best["ok"]:
            item.data["violacao"] = best["viol"]
            raise ValueError(best["why"] + (f" (melhor de {len(hist)} pontos)" if len(hist) > 1 else ""))
        return item


def _real_search(free, x: dict, best: dict, point, evals: int, hist: list, seed: int, stop_ok: bool = False):
    """o algoritmo genético do núcleo (core/src/optim/ga.zig) nas contínuas `free`, com `_rank` (as regras de
    viabilidade): o primeiro indivíduo é `x`, cada gene cai no passo do campo e um ponto repetido não gasta
    avaliação. Para no total de avaliações (ou no primeiro ponto que fecha, com `stop_ok`)"""
    from aerosim.backend.zig import ZigBackend
    be = ZigBackend()
    pop = max(4, min(10, evals // 3))
    cfg = dict(n_genes=len(free), pop=pop, elite=1, card=[0] * len(free), lo=[lo for _, lo, _ in free],
               hi=[hi for _, _, hi in free], p_mut=0.3, sigma=0.15, seed=seed, generation=0)
    steps = [(inp.get(k).step if inp.get(k) else 0.0) for k, _, _ in free]

    def snap(j, g):
        _, lo, hi = free[j]
        g = round(g / steps[j]) * steps[j] if steps[j] > 0 else g
        return round(min(max(g, lo), hi), 6)
    genes = be.ga_init(cfg)
    genes[0] = [x[k] for k, _, _ in free]
    seen = {tuple(genes[0]): best}
    fit = [math.nan] * pop
    for gen in range(4 * math.ceil(evals / pop) + 1):
        for i in range(pop):
            key = tuple(snap(j, g) for j, g in enumerate(genes[i])) if (gen or i) else tuple(genes[0])
            genes[i] = key
            r = seen.get(key)
            if r is None and len(hist) < evals:
                y = {k: key[j] for j, (k, _, _) in enumerate(free)}
                r = seen[key] = point(y)
                hist.append(_eval(y, r))
                if _rank(r) > _rank(best):
                    x, best = y, r
                if stop_ok and best["ok"]:
                    return x, best
            fit[i] = _fit(r) if r is not None else math.nan
        if len(hist) >= evals:
            break
        cfg["generation"] = gen + 1
        genes = be.ga_next(cfg, genes, fit)
    return x, best


def _cma_search(free, x: dict, best: dict, point, evals: int, hist: list, seed: int, stop_ok: bool = False):
    """o mesmo contrato de `_real_search`, com o CMA-ES do núcleo (core/src/optim/cmaes.zig) no lugar do algoritmo
    genético. As variáveis andam normalizadas pela faixa ([0, 1]), a média começa em `x` e o passo em 0,3 da faixa;
    cada ponto sorteado cai no passo do campo antes de avaliar, e é o ponto que caiu que volta para o núcleo. Um
    ponto que já apareceu não gasta avaliação. A população é a mesma das gerações, para comparar os dois pelo
    mesmo total de avaliações"""
    from aerosim.backend.zig import ZigBackend
    be = ZigBackend()
    lo = [a for _, a, _ in free]
    span = [max(b - a, 1e-12) for _, a, b in free]
    steps = [(inp.get(k).step if inp.get(k) else 0.0) for k, _, _ in free]

    def snap(j, u):
        g = lo[j] + min(max(u, 0.0), 1.0) * span[j]
        g = round(g / steps[j]) * steps[j] if steps[j] > 0 else g
        return round(min(max(g, free[j][1]), free[j][2]), 6)
    st = be.cma_init([(x[k] - lo[j]) / span[j] for j, (k, _, _) in enumerate(free)], 0.3,
                     max(4, min(10, evals // 3)), seed)
    seen = {tuple(x[k] for k, _, _ in free): best}
    lam = getattr(st, "lambda")
    for _ in range(4 * math.ceil(evals / lam) + 1):
        U = be.cma_ask(st)
        fit = []
        for i in range(lam):
            key = tuple(snap(j, u) for j, u in enumerate(U[i]))
            U[i] = [(g - lo[j]) / span[j] for j, g in enumerate(key)]
            r = seen.get(key)
            if r is None and len(hist) < evals:
                y = {k: key[j] for j, (k, _, _) in enumerate(free)}
                r = seen[key] = point(y)
                hist.append(_eval(y, r))
                if _rank(r) > _rank(best):
                    x, best = y, r
                if stop_ok and best["ok"]:
                    return x, best
            fit.append(_fit(r) if r is not None else math.nan)
        if len(hist) >= evals:
            break
        be.cma_tell(st, U, fit)
    return x, best


DE_F, DE_CR = 0.5, 0.9           # os valores de partida de Storn e Price (1997, seção 4; a conferir no PDF)


def _de_search(free, x: dict, best: dict, point, evals: int, hist: list, seed: int, stop_ok: bool = False):
    """o mesmo contrato de `_real_search`, com a evolução diferencial do núcleo (core/src/optim/de.zig, DE/rand/1/bin,
    F = 0,5, CR = 0,9). A população começa com `x` e o resto sorteado na caixa, cada teste cai no passo do campo
    antes de avaliar (e é o ponto que caiu que entra na seleção), e um ponto repetido não gasta avaliação. A
    população é a mesma das gerações, para comparar pelo mesmo total de avaliações"""
    from aerosim.backend.zig import ZigBackend
    be = ZigBackend()
    lo = [a for _, a, _ in free]
    span = [max(b - a, 1e-12) for _, a, b in free]
    steps = [(inp.get(k).step if inp.get(k) else 0.0) for k, _, _ in free]

    def snap(j, u):
        g = lo[j] + min(max(u, 0.0), 1.0) * span[j]
        g = round(g / steps[j]) * steps[j] if steps[j] > 0 else g
        return round(min(max(g, free[j][1]), free[j][2]), 6)
    np_ = max(4, min(10, evals // 3))
    seen = {tuple(x[k] for k, _, _ in free): best}

    def evaluate(U):
        nonlocal x, best
        fit = []
        for i in range(len(U)):
            key = tuple(snap(j, u) for j, u in enumerate(U[i]))
            U[i] = [(g - lo[j]) / span[j] for j, g in enumerate(key)]
            r = seen.get(key)
            if r is None and len(hist) < evals:
                y = {k: key[j] for j, (k, _, _) in enumerate(free)}
                r = seen[key] = point(y)
                hist.append(_eval(y, r))
                if _rank(r) > _rank(best):
                    x, best = y, r
            fit.append(_fit(r) if r is not None else math.nan)
            if stop_ok and best["ok"]:                   # a etapa voa para no primeiro ponto que fecha
                fit += [math.nan] * (len(U) - len(fit))
                break
        return np.ascontiguousarray(fit, float)
    pop = be.de_init([(x[k] - lo[j]) / span[j] for j, (k, _, _) in enumerate(free)], np_, seed)
    fit = evaluate(pop)
    for gen in range(4 * math.ceil(evals / np_) + 1):
        if len(hist) >= evals or (stop_ok and best["ok"]):
            break
        trial = be.de_trials(pop, DE_F, DE_CR, seed, gen)
        tfit = evaluate(trial)
        be.de_select(pop, fit, trial, tfit)
    return x, best


class Takeoff6dof(IStage):
    """o MTOW na simulação 6GDL (bisseção na massa, profundor otimizado), um processo por candidato"""
    name = "decolagem 6GDL"

    def __init__(self, project, catalog=None, backend_cls=None):
        self.project, self.catalog, self.backend_cls = project, catalog, backend_cls

    def one(self, item: StageItem) -> StageItem:
        check_cancel()                             # o Parar combinado: sai entre um ponto e outro
        from aerosim.manager import SimulationManager
        if self.backend_cls is None:
            from aerosim.backend.zig import ZigBackend
            self.backend_cls = ZigBackend
        d = item.data
        top = 1.6 * d["mtow"] if math.isfinite(d["mtow"]) else None    # o 6GDL fica perto do MTOW da pista
        m6 = study._mtow6(d["cand"], d["req"], self.project.rules, self.catalog, self.project.airfoil_map(),
                          SimulationManager(self.backend_cls()), m_max=top)
        d["mtow6"] = m6
        if not math.isfinite(m6):
            item.alive, item.why = False, "não decola no 6GDL"
        return item


def n_surfaces(st) -> int:
    """N da Regular 2026 (7.7.4): as superfícies sustentadoras com função longitudinal, a asa (ou as duas) e a
    EH, ou a cauda em V, que conta como uma. Asa voadora 1, monoplano com cauda 2, tandem 2, biplano com cauda 3"""
    return (2 if st.wing2 is not None else 1) + (1 if st.params.layout in ("convencional", "em H", "em V") else 0)


def inputs(d: dict) -> dict:
    """as grandezas que as pontuações leem, a partir do que as etapas deixaram (SI). A carga paga se divide igual
    entre LAPES e líquido quando o avião leva os dois: é o que dá a maior CP_M = 2·min(C_LAPES, C_Liq)"""
    m6 = d.get("mtow6", math.nan)
    mtow = m6 if math.isfinite(m6) else d["mtow"]
    cp = max(mtow - d["pv"], 0.0)
    both = d["lapes"] and d["liquid"]
    c_lapes = 0.5 * cp if both else (cp if d["lapes"] else 0.0)
    c_liq = 0.5 * cp if both else (cp if d["liquid"] else 0.0)
    return dict(mtow=mtow, pv=d["pv"], cp=cp, ee=cp / d["pv"] if d["pv"] > 0 else 0.0, c_lapes=c_lapes,
                c_liq=c_liq, m_bat=d["m_bat"], s_to=d["s_to"], b=d["b"], n_sup=d.get("n_sup", math.nan))


class Score(IStage):
    """a nota de todos de uma vez, no núcleo"""
    name = "nota"
    batch = True
    parallel = "não"

    def __init__(self, scoring, backend=None):
        self.scoring, self.backend = scoring, backend

    def run(self, items: list[StageItem]) -> list[StageItem]:
        if not items:
            return items
        rows = [inputs(i.data) for i in items]
        for i, r, s in zip(items, rows, sc.evaluate(self.scoring, rows, self.backend)):
            i.data.update(inputs=r, **s)
            # o voo que não vale (corrida, envergadura, bateria ou carga fora das condições) não pontua: a nota é 0.
            # A conta da fórmula fica em "nota_formula", que as gerações usam para ordenar os inválidos entre si
            i.data["nota_formula"] = s["nota"]
            if not s["valido"]:
                i.data["nota"] = 0.0
                i.data["violacao"] = sum(abs(x - float(t.rsplit(" ", 1)[-1].replace(",", ".")))
                                         / max(abs(float(t.rsplit(" ", 1)[-1].replace(",", "."))), 1.0)
                                         for t, ok, x in s["validade"] if not ok)
        return items


@dataclass
class StabilityParams:
    """a restrição de estabilidade de cada ponto de projeto, com a análise que a aba Estabilidade já faz: a
    estática látero-direcional (C_nβ > 0, C_lβ < 0, Nelson, *Flight Stability and Automatic Control*, cap. 3,
    a conferir no PDF) e os modos do modelo linear do núcleo contra a MIL-F-8785C (classe I, categoria B), no
    pior nível que se aceita. É isso que faz o diedro, o enflechamento e a deriva contarem na busca: a corrida de
    decolagem quase não depende deles"""
    level: int = 2                 # pior nível MIL aceito em qualquer modo (1 = o melhor)
    static: bool = True            # confere C_nβ > 0 e C_lβ < 0
    alpha: float = 0.03            # rad, onde as derivadas em β se tiram (perto do cruzeiro)


def stability_check(ac, V: float, params: StabilityParams, backend=None) -> tuple[bool, str, dict]:
    """(passa, motivo, valores) da estabilidade de um avião montado na velocidade V"""
    from aerosim.stability import Probe, mil_check
    from aerosim.stability.sizing import modes_at
    if backend is None:
        from aerosim.backend.zig import ZigBackend
        backend = ZigBackend()
    why, vals = [], {}
    if params.static:
        with Probe(backend, ac) as pb:
            der = pb.deriv(V, params.alpha, "beta", ["Cl", "Cn"])
        vals.update(Clb=float(der["Cl"]), Cnb=float(der["Cn"]))
        if not der["Cn"] > 0:
            why.append(f"instável direcional (C_nβ = {der['Cn']:.3f} /rad)")
        if not der["Cl"] < 0:
            why.append(f"instável em rolamento (C_lβ = {der['Cl']:.3f} /rad: falta diedro)")
    m, _ = modes_at(backend, ac, V)
    if m is None:
        why.append("modelo linear não fecha no cruzeiro")
    else:
        for r in mil_check(m):
            vals[r["criterio"]] = r["nivel"]
            if r["nivel"] > params.level:
                why.append(f"{r['criterio']}: nível {r['nivel']} (aceito até {params.level})")
    return not why, "; ".join(why), vals


GEAR_KEY = "power.gear_h"          # a altura do trem: o que a geometria mexe para nada bater no chão
GEAR_MARGIN = 0.002                # m a mais que o núcleo pediu (a conta é exata; isto só tira o arredondamento)


def gear_fix(ac, g) -> float:
    """a altura do trem que livra o chão: a de agora mais o que o relatório pede, com uma folga de arredondamento"""
    return round(float(ac.gear.main_z) + g.gear_raise + GEAR_MARGIN, 4)


def geometry_check(ac, params):
    """a checagem de geometria do núcleo para um avião montado (o modelo universal sai dele aqui)"""
    from aerosim.backend.zig.geometry import ZigGeometry
    from aerosim.model.universal import build_model
    return ZigGeometry().check(build_model(ac), params)


class GeometryStage(IStage):
    """barata, antes das superfícies: o avião da configuração, montado como está nos rascunhos, cabe? (hélice que
    acerta peça, massa fora da geometria, cauda ou hélice no chão parado e na rotação; peças soltas, se pedido)"""
    name = "geometria"
    parallel = "não"

    def __init__(self, project, params, catalog=None):
        self.project, self.params, self.catalog = project, params, catalog

    def one(self, item: StageItem) -> StageItem:
        p, cand = candidate(self.project, item.values)
        ac, _ = pw.assemble(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
        g = geometry_check(ac, self.params)
        raised = 0.0
        if g.only_ground:                         # conserta: desce as rodas o que o núcleo pediu, e confere de novo
            h = gear_fix(ac, g)
            item.values = {**item.values, GEAR_KEY: h}
            p, cand = candidate(self.project, item.values)
            ac, _ = pw.assemble(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
            raised, g = g.gear_raise, geometry_check(ac, self.params)
        item.data["geometria"] = dict(groups=len(g.groups), ground=[(a, x) for a, x, _ in g.ground],
                                      gear_raise=raised)
        if not g.ok:
            raise ValueError(g.why())
        return item


def warm() -> None:
    """o que cada processo trabalhador carrega ao nascer, antes da primeira etapa: os módulos (vêm com este) e o
    núcleo em Zig (`power._core`, um por processo)"""
    pw._core()


class StagedEvaluator(IEvaluator):
    name = "etapas"
    warm = staticmethod(warm)
    preload = ("aeroopt.stages",)              # forkserver: o que o servidor importa uma vez (aerosim vem junto)

    def __init__(self, project, catalog=None, backend=None, workers: int | None = None, six_dof: bool = True,
                 evals: int = 24, start_method: str | None = None, scoring=None, geometry=True,
                 surfaces: str = "coordenadas", stability: StabilityParams | None = None, fly: str | None = "buscar",
                 executors=None, tails=None, controls: bool | None = None):
        self.project, self.catalog, self.backend = project, catalog, backend
        self.executors = executors                 # os da sessão (aerosim.parallel.session); None: um por rodada
        self.fly = fly                             # o método da etapa "voa" (FLY_METHODS); None: sem a etapa
        self.tails = tails                         # as caudas que a "voa" escolhe; None: as do problema (etapas.caudas)
        self.controls = controls                   # a "voa" ajusta os comandos; None: o do problema (etapas.comandos)
        self.surfaces = surfaces                   # o método da busca das superfícies (SURFACE_METHODS)
        self.stability = stability                 # a restrição de estabilidade de cada ponto (None: desligada)
        self.workers, self.six_dof, self.evals = workers, six_dof, evals
        self.start_method = start_method           # a GUI usa "spawn" (processos novos, sem herdar as linhas do Qt)
        self.scoring = scoring                     # uma pontuação já montada (a GUI edita os campos do .toml)
        # a geometria (core/src/geometry): True usa os GeometryParams padrão sem exigir uma peça só (o montador da
        # sprint ainda não põe montantes nem tubos entre asas); um GeometryParams manda; False desliga
        if geometry is True:
            from aerosim.interfaces.geometry import GeometryParams
            geometry = GeometryParams(connected=False)
        self.geometry = geometry or None

    def quantities(self) -> list[str]:
        return ["mtow", "pv", "cp", "ee", "c_lapes", "c_liq", "m_bat", "s_to", "b", "n_sup"]

    def stages(self, project, problem: OptProblem) -> list[IStage]:
        sts: list[IStage] = [GeometryStage(project, self.geometry, self.catalog)] if self.geometry else []
        if self.fly:
            e = problem.params.get("etapas") or {}
            tails = self.tails if self.tails is not None else e.get("caudas")
            controls = self.controls if self.controls is not None else bool(e.get("comandos"))
            sts.append(FlightCheck(project, problem, self.catalog, self.evals, self.fly, self.stability, tails,
                                   controls))
        sts.append(SurfaceSizing(project, problem, self.catalog, self.evals, self.geometry, self.surfaces,
                                 self.stability))
        if self.six_dof:
            sts.append(Takeoff6dof(project, self.catalog, type(self.backend) if self.backend is not None else None))
        sts.append(Score(self.scoring or sc.scoring_for(problem.scoring), self.backend))
        return sts


# a área de projeto de cada motivo, na ordem do projeto
AREAS = (("geometria", ("geometria", "bate no chão", "hélice acerta", "fora da geometria", "soltas")),
         ("equilíbrio", ("lastro", "EH estola", "profundor", "trim de decolagem")),
         ("estabilidade", ("estabilidade", "instável", "C_nβ", "C_lβ", "nível")),
         ("desempenho", ("não decola", "massa de projeto", "6GDL", "subida", "estol", "corrida")),
         ("restrições", (" ≤ ", " ≥ ", " = ")))


def area(r: dict) -> str:
    """em que área de projeto a configuração está (viva) ou parou: todas as que o motivo cita, na ordem do projeto"""
    if r.get("alive"):
        if math.isfinite(r.get("nota", math.nan)):
            return "nota" if r.get("valido") else "nota (voo inválido)"
        return r.get("stage") or "na fila"
    why = r.get("why", "")
    hit = [name for name, words in AREAS if any(w in why for w in words)]
    return " + ".join(hit) or r.get("stage") or "—"


def row(item: StageItem) -> dict:
    """o candidato em linha de tabela (sem os objetos do avião)"""
    d = item.data
    return dict(index=d.get("index", 0), name=item.name, values=dict(item.values), alive=item.alive, why=item.why, stage=item.stage,
                mtow=d.get("mtow", math.nan), mtow6=d.get("mtow6", math.nan), pv=d.get("pv", math.nan),
                b=d.get("b", math.nan), m_bat=d.get("m_bat", math.nan),
                nota=d.get("nota", math.nan), nota_formula=d.get("nota_formula", d.get("nota", math.nan)),
                violacao=d.get("violacao", math.nan),
                valido=d.get("valido", False), termos=d.get("termos", {}),
                validade=d.get("validade", []), inputs=d.get("inputs", {}), history=d.get("history", []))


class StagedSolver(ISolver):
    name = "etapas (configurações → superfícies → 6GDL → nota)"

    def run(self, problem, evaluator: StagedEvaluator, progress=None, cancel=None, on_item=None) -> OptResult:
        """`on_item(etapa, linha)` a cada candidato que termina uma etapa (a linha de `row`, sem os objetos)"""
        p = copy.deepcopy(evaluator.project)          # o projeto do usuário não muda
        problem = copy.deepcopy(problem)
        fold_bounds(problem, p)                       # envergadura, área, nº de motores: limites, não restrições
        apply_to_project(problem, p)                  # as restrições do problema valem na viabilidade
        items = configurations(p, problem, evaluator.catalog)
        pipe = Pipeline(evaluator.stages(p, problem), evaluator.start_method, getattr(evaluator, "executors", None),
                        initializer=getattr(evaluator, "warm", None), preload=getattr(evaluator, "preload", ()))
        cb = (lambda st, it: on_item(st, row(it))) if on_item else None
        items = pipe.run(items, evaluator.workers, progress, cancel, cb)
        rows = [row(i) for i in items]
        done = [r for r in rows if r["alive"] and math.isfinite(r["nota"])]
        best = max(done, key=lambda r: (r["valido"], r["nota"])) if done else {}
        return OptResult(rows=rows, best=best, names={"etapas": pipe.log})

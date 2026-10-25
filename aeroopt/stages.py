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

from . import categories as cat
from . import scoring as sc
from .pipeline import Pipeline
from .problem import apply_to_project

MAX_CONFIGS = 256                 # acima disso a lista de configurações é grande demais para varrer inteira


def candidate(project, values: dict):
    """o avião dos rascunhos do projeto com estes valores (a asa, o conjunto e os motores da sprint)"""
    p = copy.deepcopy(project)
    if cat.KEY in values:
        cat.apply(p, values[cat.KEY])
    for k, v in values.items():
        if k == cat.KEY:
            continue
        if k in ("wing.airfoil", "wing.airfoil_tip") and v and p.airfoil(v) is None:
            e = mdo.airfoil_catalog(p).get(v)          # perfil da biblioteca que o projeto ainda não tem
            if e is not None:
                p.airfoils.append(copy.deepcopy(e))
        rg.set_input(p, k, v)
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
            rg.set_input(project, k, rg.get_input(p, k))
    project.airfoils = p.airfoils


def design(project, problem: OptProblem, values: dict, catalog=None) -> dict:
    """o ponto de projeto de um candidato, refeito (para ver o avião: o 3D, as massas)"""
    p = copy.deepcopy(project)
    apply_to_project(problem, p)
    q, cand = candidate(p, values)
    return pw.design_point(cand, q.requirements, q.rules, catalog, q.airfoil_map())


def configurations(project, problem: OptProblem, catalog=None) -> list[StageItem]:
    """um candidato por combinação das variáveis discretas livres (lista e inteira) e das categorias escolhidas"""
    axes = []
    cats = list(problem.params.get("categorias") or [])
    for c in cats:
        cat.fields(c)                                 # nome errado para aqui, antes de rodar
    if cats:
        axes.append((cat.KEY, cats))
    for v in problem.free_variables():
        if v.kind == "lista":
            known = mdo.available(project, v.key, catalog)
            unknown = [o for o in v.options if known and o not in known]
            if unknown:
                raise ValueError(f"{v.key}: {', '.join(unknown)} não existe (há {', '.join(known)})")
            axes.append((v.key, list(dict.fromkeys(v.options)) or known))
        elif v.kind == "inteira":
            axes.append((v.key, list(range(round(min(v.lo, v.hi)), round(max(v.lo, v.hi)) + 1))))
    n = math.prod(len(o) for _, o in axes) if axes else 1
    if n > MAX_CONFIGS:
        raise ValueError(f"{n} configurações (o limite é {MAX_CONFIGS}): marque menos opções nas listas")
    keys = [k for k, _ in axes]
    out = []
    for combo in itertools.product(*(o for _, o in axes)):
        vals = dict(zip(keys, combo))
        name = ", ".join(str(x) if k == cat.KEY else f"{k.partition('.')[2]}={x}" for k, x in vals.items()) \
            or "configuração única"
        out.append(StageItem(name=name, values=vals, data={"index": len(out) + 1}))
    return out


def _rank(r: dict) -> tuple:
    m = r["mtow"]
    return (r["ok"], m if math.isfinite(m) else -math.inf)


def _eval(x: dict, r: dict) -> dict:
    """uma avaliação da busca das superfícies, para o histórico (e o CSV)"""
    return dict(values=dict(x), mtow=r["mtow"], ok=r["ok"], why=r["why"], pv=r["pv"], b=r["b"], m_bat=r["m_bat"])


class SurfaceSizing(IStage):
    """as variáveis contínuas livres de uma configuração, pelo maior MTOW viável na pista"""
    name = "superfícies"

    def __init__(self, project, problem: OptProblem, catalog=None, evals: int = 24):
        self.project, self.catalog, self.evals = project, catalog, int(evals)
        self.free = [(v.key, min(v.lo, v.hi), max(v.lo, v.hi)) for v in problem.free_variables()
                     if v.kind == "contínua"]

    def point(self, values: dict) -> dict:
        p, cand = candidate(self.project, values)
        d = pw.design_point(cand, p.requirements, p.rules, self.catalog, p.airfoil_map())
        ok, why = study.feasibility(d)
        asm = d["asm"]
        m_bat = sum(i.mass for i in asm["items"] if i.name == "bateria")
        return dict(values=dict(values), mtow=float(d["mtow"]), ok=ok, why=why, pv=float(asm["empty"]),
                    m_bat=float(m_bat), b=float(d["cand"].set.wing.params.span),
                    s_to=float(p.requirements.takeoff_run), lapes=bool(cand.params.lapes),
                    liquid=bool(cand.params.liquid), cand=d["cand"], req=d["req"])

    def one(self, item: StageItem) -> StageItem:
        x = {k: min(max(float(rg.get_input(self.project, k)), lo), hi) for k, lo, hi in self.free}
        best = self.point({**item.values, **x})
        hist = [_eval(x, best)]
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
        item.values = {**item.values, **x}
        item.data.update(best, history=hist)
        item.alive, item.why = best["ok"], best["why"]
        return item


class Takeoff6dof(IStage):
    """o MTOW na simulação 6GDL (bisseção na massa, profundor otimizado), um processo por candidato"""
    name = "decolagem 6GDL"

    def __init__(self, project, catalog=None, backend_cls=None):
        self.project, self.catalog, self.backend_cls = project, catalog, backend_cls

    def one(self, item: StageItem) -> StageItem:
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
                c_liq=c_liq, m_bat=d["m_bat"], s_to=d["s_to"], b=d["b"])


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
        return items


class StagedEvaluator(IEvaluator):
    name = "etapas"

    def __init__(self, project, catalog=None, backend=None, workers: int | None = None, six_dof: bool = True,
                 evals: int = 24, start_method: str | None = None, scoring=None):
        self.project, self.catalog, self.backend = project, catalog, backend
        self.workers, self.six_dof, self.evals = workers, six_dof, evals
        self.start_method = start_method           # a GUI usa "spawn" (processos novos, sem herdar as linhas do Qt)
        self.scoring = scoring                     # uma pontuação já montada (a GUI edita os campos do .toml)

    def quantities(self) -> list[str]:
        return ["mtow", "pv", "cp", "ee", "c_lapes", "c_liq", "m_bat", "s_to", "b"]

    def stages(self, project, problem: OptProblem) -> list[IStage]:
        sts: list[IStage] = [SurfaceSizing(project, problem, self.catalog, self.evals)]
        if self.six_dof:
            sts.append(Takeoff6dof(project, self.catalog, type(self.backend) if self.backend is not None else None))
        sts.append(Score(self.scoring or sc.scoring_for(problem.scoring), self.backend))
        return sts


def row(item: StageItem) -> dict:
    """o candidato em linha de tabela (sem os objetos do avião)"""
    d = item.data
    return dict(index=d.get("index", 0), name=item.name, values=dict(item.values), alive=item.alive, why=item.why, stage=item.stage,
                mtow=d.get("mtow", math.nan), mtow6=d.get("mtow6", math.nan), pv=d.get("pv", math.nan),
                b=d.get("b", math.nan), m_bat=d.get("m_bat", math.nan),
                nota=d.get("nota", math.nan), valido=d.get("valido", False), termos=d.get("termos", {}),
                validade=d.get("validade", []), inputs=d.get("inputs", {}), history=d.get("history", []))


class StagedSolver(ISolver):
    name = "etapas (configurações → superfícies → 6GDL → nota)"

    def run(self, problem, evaluator: StagedEvaluator, progress=None, cancel=None, on_item=None) -> OptResult:
        """`on_item(etapa, linha)` a cada candidato que termina uma etapa (a linha de `row`, sem os objetos)"""
        p = copy.deepcopy(evaluator.project)          # o projeto do usuário não muda
        apply_to_project(problem, p)                  # as restrições do problema valem na viabilidade
        items = configurations(p, problem, evaluator.catalog)
        pipe = Pipeline(evaluator.stages(p, problem), evaluator.start_method)
        cb = (lambda st, it: on_item(st, row(it))) if on_item else None
        items = pipe.run(items, evaluator.workers, progress, cancel, cb)
        rows = [row(i) for i in items]
        done = [r for r in rows if r["alive"] and math.isfinite(r["nota"])]
        best = max(done, key=lambda r: (r["valido"], r["nota"])) if done else {}
        return OptResult(rows=rows, best=best, names={"etapas": pipe.log})

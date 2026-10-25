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
from . import inputs as inp
from . import scoring as sc
from .pipeline import Pipeline
from .problem import apply_to_project, fold_bounds

MAX_CONFIGS = 256
AIRFOIL_KEYS = tuple(k for k, i in inp.all_inputs().items() if i.source == "perfis")
SHORT = {"wing.airfoil": "perfil raiz", "wing.airfoil_tip": "perfil ponta", "tail.airfoil": "perfil EH",
         "tail.vairfoil": "perfil EV", "power.motor": "motor", "power.propeller": "hélice",
         "power.battery": "bateria", "power.motors": "nº de motores", "power.layout": "arranjo"}


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
    m = r["mtow"]
    return (r["ok"], m if math.isfinite(m) else -math.inf)


def _eval(x: dict, r: dict) -> dict:
    """uma avaliação da busca das superfícies, para o histórico (e o CSV)"""
    return dict(values=dict(x), mtow=r["mtow"], ok=r["ok"], why=r["why"], pv=r["pv"], b=r["b"], m_bat=r["m_bat"])


# os métodos da busca das superfícies (a GUI escolhe no menu Configuração)
SURFACE_METHODS = {"coordenadas": "busca por coordenadas (um eixo por vez, passo cai à metade)",
                   "gerações": "gerações nas contínuas (algoritmo genético do núcleo)"}


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
        asm = d["asm"]
        m_bat = sum(i.mass for i in asm["items"] if i.name == "bateria")
        return dict(values=dict(values), mtow=float(d["mtow"]), ok=ok, why=why, pv=float(asm["empty"]),
                    m_bat=float(m_bat), b=float(d["cand"].set.wing.params.span),
                    s_to=float(p.requirements.takeoff_run), lapes=bool(cand.params.lapes),
                    liquid=bool(cand.params.liquid), cand=d["cand"], req=d["req"], stab=stab)

    def one(self, item: StageItem) -> StageItem:
        x = {k: min(max(float(get_value(self.project, k)), lo), hi) for k, lo, hi in self.free}
        best = self.point({**item.values, **x})
        hist = [_eval(x, best)]
        if self.method == "gerações":
            x, best = self._generations(item, x, best, hist)
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

    def _generations(self, item: StageItem, x: dict, best: dict, hist: list) -> tuple[dict, dict]:
        """o algoritmo genético do núcleo (core/src/optim/ga.zig) com genes reais entre os limites: o primeiro
        indivíduo é o avião como está, e as avaliações param no total pedido. Cada gene cai no passo do campo (o
        diedro de meio em meio grau), e um avião que já apareceu não gasta avaliação: a nota vem da memória. Sem
        isso a população pequena vira cópias do melhor e a busca gasta o total refazendo o mesmo ponto. Voo que não
        fecha fica atrás de todo voo que fecha"""
        if not self.free or self.evals <= 1:
            return x, best
        from aerosim.backend.zig import ZigBackend
        be = ZigBackend()
        pop = max(4, min(10, self.evals // 3))
        cfg = dict(n_genes=len(self.free), pop=pop, elite=1, card=[0] * len(self.free),
                   lo=[lo for _, lo, _ in self.free], hi=[hi for _, _, hi in self.free], p_mut=0.3, sigma=0.15,
                   seed=1 + zlib.crc32(item.name.encode()) % 100_000, generation=0)
        steps = [(inp.get(k).step if inp.get(k) else 0.0) for k, _, _ in self.free]

        def snap(j, g):
            k, lo, hi = self.free[j]
            g = round(g / steps[j]) * steps[j] if steps[j] > 0 else g
            return round(min(max(g, lo), hi), 6)
        genes = be.ga_init(cfg)
        genes[0] = [x[k] for k, _, _ in self.free]
        seen = {tuple(genes[0]): best}
        fit = [math.nan] * pop
        for gen in range(4 * math.ceil(self.evals / pop) + 1):
            for i in range(pop):
                key = tuple(snap(j, g) for j, g in enumerate(genes[i])) if (gen or i) else tuple(genes[0])
                genes[i] = key
                r = seen.get(key)
                if r is None and len(hist) < self.evals:
                    y = {k: key[j] for j, (k, _, _) in enumerate(self.free)}
                    r = seen[key] = self.point({**item.values, **y})
                    hist.append(_eval(y, r))
                    if _rank(r) > _rank(best):
                        x, best = y, r
                m = r["mtow"] if r is not None else math.nan
                fit[i] = (m if r["ok"] else m - 1e9) if math.isfinite(m) else math.nan
            if len(hist) >= self.evals:
                break
            cfg["generation"] = gen + 1
            genes = be.ga_next(cfg, genes, fit)
        return x, best


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
            # o voo que não vale (corrida, envergadura, bateria ou carga fora das condições) não pontua: a nota é 0.
            # A conta da fórmula fica em "nota_formula", que as gerações usam para ordenar os inválidos entre si
            i.data["nota_formula"] = s["nota"]
            if not s["valido"]:
                i.data["nota"] = 0.0
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


class StagedEvaluator(IEvaluator):
    name = "etapas"

    def __init__(self, project, catalog=None, backend=None, workers: int | None = None, six_dof: bool = True,
                 evals: int = 24, start_method: str | None = None, scoring=None, geometry=True,
                 surfaces: str = "coordenadas", stability: StabilityParams | None = None):
        self.project, self.catalog, self.backend = project, catalog, backend
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
        return ["mtow", "pv", "cp", "ee", "c_lapes", "c_liq", "m_bat", "s_to", "b"]

    def stages(self, project, problem: OptProblem) -> list[IStage]:
        sts: list[IStage] = [GeometryStage(project, self.geometry, self.catalog)] if self.geometry else []
        sts.append(SurfaceSizing(project, problem, self.catalog, self.evals, self.geometry, self.surfaces,
                                 self.stability))
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
                nota=d.get("nota", math.nan), nota_formula=d.get("nota_formula", d.get("nota", math.nan)),
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
        pipe = Pipeline(evaluator.stages(p, problem), evaluator.start_method)
        cb = (lambda st, it: on_item(st, row(it))) if on_item else None
        items = pipe.run(items, evaluator.workers, progress, cancel, cb)
        rows = [row(i) for i in items]
        done = [r for r in rows if r["alive"] and math.isfinite(r["nota"])]
        best = max(done, key=lambda r: (r["valido"], r["nota"])) if done else {}
        return OptResult(rows=rows, best=best, names={"etapas": pipe.log})

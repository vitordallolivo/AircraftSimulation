"""Dados de teste do aeroopt: um avaliador sintético, rápido e com o resultado sabido de antemão.

Rodar o otimizador de verdade leva minutos, e quando se mexe no processo em etapas, nas gerações, no paralelismo ou
na janela, o que se quer saber é se a máquina funciona, não qual avião sai. O avaliador sintético troca as contas do
avião por funções simples, com as mesmas etapas (geometria → superfícies → nota) e as mesmas colunas, então tudo o
que vem depois (a tabela, o mapa, o funil, o CSV, as buscas das superfícies, os executores) roda igual e em segundos.
As buscas das superfícies são as de verdade (`SurfaceSizing`: coordenadas, gerações, CMA-ES); só o ponto é falso.

O que acontece com cada configuração é fixo e sai do nome dela (`zlib.crc32`, igual em toda máquina):

- uma em cada cinco para na geometria ("bate no chão"): `crc % 5 == 0`;
- as outras ganham um fator $f \\in [0{,}6;\\ 1]$, e com as contínuas normalizadas $u_k \\in [0, 1]$ e
  $d^2 = \\sum_k (u_k - 0{,}7)^2$:

      MTOW = 4 f (1 − d²)        PV = 2,2 − f        CP = MTOW − PV        EE = CP / PV

- o ponto só fecha com $d^2 \\le 0{,}35$ (a violação é o que passa disso); o voo vale com EE ≥ 0,6, e a nota é
  25 · CP (zero no voo inválido, como na pontuação de verdade).

Então o melhor ponto de toda configuração é $u_k = 0{,}7$ (70 % da faixa de cada contínua), a melhor configuração é a
de maior $f$ e as de $f < 0{,}6286$ voam inválidas até no melhor ponto. `expected` devolve isso para cada uma, e os
testes conferem o que o otimizador achou contra ele. `delay` faz cada ponto demorar, para ver o paralelismo e o
andamento ao vivo como se a conta fosse pesada.

    from aeroopt.synthetic import SyntheticEvaluator, expected
    ev = SyntheticEvaluator(project, evals=24, surfaces="cma-es", delay=0.05)
    res = StagedSolver().run(problem, ev)
    python -m aeroopt --exemplo --sintetico          # a janela com o avaliador sintético
"""
from __future__ import annotations

import math
import time
import zlib

from aerosim.interfaces.optim import IEvaluator, IStage, OptProblem, StageItem
from aerosim.parallel import check_cancel

from . import stages as sg

U_BEST = 0.7                 # o ótimo de cada contínua, na faixa normalizada
D2_MAX = 0.35                # acima disso o ponto não fecha
EE_MIN = 0.6
NOTA_K = 25.0


def _crc(name: str) -> int:
    return zlib.crc32(name.encode())


def factor(name: str) -> float:
    """o fator da configuração, de 0,6 a 1"""
    return 0.6 + 0.4 * ((_crc(name) >> 8) % 1000) / 999


def blocked(name: str) -> bool:
    """a configuração para na geometria"""
    return _crc(name) % 5 == 0


def evaluate(name: str, u: list[float]) -> dict:
    """o ponto sintético de uma configuração com as contínuas normalizadas `u`"""
    f = factor(name)
    d2 = sum((x - U_BEST) ** 2 for x in u)
    mtow, pv = 4 * f * (1 - d2), 2.2 - f
    cp = mtow - pv
    ok = d2 <= D2_MAX
    return dict(mtow=mtow, pv=pv, cp=cp, ee=cp / pv, ok=ok, viol=0.0 if ok else d2 - D2_MAX,
                why="" if ok else f"não fecha (sintético: d² = {d2:.3f} > {D2_MAX})")


def nota(r: dict) -> tuple[float, bool]:
    """(nota da fórmula, voo válido)"""
    return NOTA_K * max(r["cp"], 0.0), r["ee"] >= EE_MIN


def expected(project, problem: OptProblem, catalog=None) -> dict[str, dict]:
    """o que deve acontecer com cada configuração: onde para, e no melhor ponto a nota e se o voo vale"""
    out = {}
    for it in sg.configurations(project, problem, catalog):
        if blocked(it.name):
            out[it.name] = dict(stage="geometria", nota=math.nan, valido=False)
            continue
        n, ok = nota(evaluate(it.name, [U_BEST]))
        out[it.name] = dict(stage="nota", nota=n if ok else 0.0, nota_formula=n, valido=ok)
    return out


def best(project, problem: OptProblem, catalog=None) -> str:
    """o nome da melhor configuração (voo válido, maior nota)"""
    ex = expected(project, problem, catalog)
    return max((k for k, v in ex.items() if v["valido"]), key=lambda k: ex[k]["nota"])


class SyntheticGeometry(IStage):
    name = "geometria"

    def __init__(self, delay: float = 0.0):
        self.delay = delay

    def one(self, item: StageItem) -> StageItem:
        time.sleep(self.delay)
        if blocked(item.name):
            raise ValueError("bate no chão na rotação (sintético)")
        return item


class SyntheticSurfaces(sg.SurfaceSizing):
    """a busca das superfícies de verdade, com o ponto sintético"""

    def __init__(self, project, problem: OptProblem, evals: int = 24, method: str = "coordenadas",
                 delay: float = 0.0):
        super().__init__(project, problem, None, evals, None, method, None)
        self.delay = delay
        self.req = project.requirements

    def point(self, values: dict) -> dict:
        check_cancel()
        time.sleep(self.delay)
        name = values.get("_config", "")
        u = [(float(values.get(k, lo)) - lo) / (hi - lo) if hi > lo else U_BEST for k, lo, hi in self.free]
        r = evaluate(name, u or [U_BEST])
        b = float(values.get("wing.span", sg.get_value(self.project, "wing.span")))
        return dict(values={k: v for k, v in values.items() if k != "_config"}, mtow=r["mtow"], ok=r["ok"],
                    why=r["why"], pv=r["pv"], m_bat=0.3, b=b, s_to=float(self.req.takeoff_run), lapes=True,
                    liquid=True, cand=None, req=self.req, stab={}, viol=r["viol"])

    def one(self, item: StageItem) -> StageItem:
        item.values["_config"] = item.name          # o ponto precisa do nome da configuração (o fator dela)
        try:
            return super().one(item)
        finally:
            item.values.pop("_config", None)


class SyntheticScore(IStage):
    name = "nota"
    batch = True
    parallel = "não"

    def run(self, items: list[StageItem]) -> list[StageItem]:
        for i in items:
            r = sg.inputs(i.data)
            n, ok = nota(dict(cp=r["cp"], ee=r["ee"]))
            i.data.update(inputs=r, nota=n if ok else 0.0, nota_formula=n, valido=ok,
                          termos={"CP": r["cp"], "fator": NOTA_K},
                          validade=[(f"EE ≥ {EE_MIN:g}".replace(".", ","), ok, r["ee"])],
                          violacao=0.0 if ok else (EE_MIN - r["ee"]) / EE_MIN)
        return items


class SyntheticEvaluator(IEvaluator):
    """troca o `StagedEvaluator` nas rodadas de teste: as mesmas etapas e colunas, com o resultado sabido"""
    name = "sintético"

    def __init__(self, project, catalog=None, backend=None, workers: int | None = None, evals: int = 24,
                 surfaces: str = "coordenadas", start_method: str | None = None, delay: float = 0.0, executors=None,
                 **_):
        self.project, self.catalog, self.backend = project, catalog, backend
        self.workers, self.evals, self.surfaces = workers, evals, surfaces
        self.start_method, self.delay, self.executors = start_method, delay, executors

    def quantities(self) -> list[str]:
        return ["mtow", "pv", "cp", "ee", "b"]

    def stages(self, project, problem: OptProblem) -> list[IStage]:
        return [SyntheticGeometry(self.delay), SyntheticSurfaces(project, problem, self.evals, self.surfaces,
                                                                 self.delay), SyntheticScore()]

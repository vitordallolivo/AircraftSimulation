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
de maior $f$ e as de $f < 0{,}6286$ voam inválidas até no melhor ponto.

O $d^2$ acima é a "tigela" (`forma`, o padrão), fácil para qualquer busca. Para comparar as buscas (o banco,
`tools/banco_otimizadores.py`) há mais duas formas, com o mesmo ótimo em $u_k = 0{,}7$ e $d^2 = 0$ nele, então
`expected` vale para as três. Com $z_k = u_k - 0{,}7$ e $n$ contínuas:

- "acoplada": o elipsoide girado (a $f_{10}$ do BBOB, Hansen et al., "Real-parameter black-box optimization
  benchmarking 2009: noiseless functions definitions", INRIA RR-6829, a conferir no PDF). $w = R z$, com $R$ a
  reflexão de Householder ($R = I - 2 v v^T$, $v$ = (1, 2, …, n) normalizado; com o vetor de uns, em duas contínuas
  ela só trocaria uma pela outra), que mistura todas as contínuas, e pesos $\lambda_k = \kappa^{k/(n-1)}$ de média 1, $\kappa = 100$: $d^2 = \sum_k \lambda_k w_k^2$. Andar
  num eixo por vez é ruim aqui; quem aprende a direção (CMA-ES) ganha.
- "multimodal": a tigela com ondulações (a forma da Rastrigin, $f_3$ do BBOB, a conferir no PDF):
  $d^2 = \sum_k [z_k^2 + a (1 - \cos 2\pi m z_k)]$, $a = 0{,}02$, $m = 5$. Há mínimos locais até $|z_k| \approx 0{,}3$, onde a
  busca local para; a global (gerações) passa por cima. `expected` devolve isso para cada uma, e os
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
SHAPES = ("tigela", "acoplada", "multimodal")    # a forma do d² (o docstring do módulo)
KAPPA = 100.0                # "acoplada": a razão entre o maior e o menor peso do elipsoide
RIPPLE_A, RIPPLE_M = 0.02, 5.0   # "multimodal": a altura e o número de ondulações por unidade de u
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


def distance2(u: list[float], shape: str = "tigela") -> float:
    """o d² do ponto `u` (contínuas normalizadas) na forma `shape` (`SHAPES`); 0 no ótimo, em toda forma"""
    z = [x - U_BEST for x in u]
    if shape == "tigela":
        return sum(x * x for x in z)
    if shape == "acoplada":
        n = len(z)
        nv = math.sqrt(sum((k + 1) ** 2 for k in range(n)))
        s = sum((k + 1) / nv * x for k, x in enumerate(z))
        w = [x - 2 * (k + 1) / nv * s for k, x in enumerate(z)]     # R z, R = I − 2 v vᵀ, v = (1, 2, …, n)/|·|
        lam = [KAPPA ** (k / (n - 1)) for k in range(n)] if n > 1 else [1.0]
        m = sum(lam) / n
        return sum(lk / m * wk * wk for lk, wk in zip(lam, w))
    if shape == "multimodal":
        return sum(x * x + RIPPLE_A * (1 - math.cos(2 * math.pi * RIPPLE_M * x)) for x in z)
    raise ValueError(f"forma desconhecida: {shape} (há {', '.join(SHAPES)})")


def evaluate(name: str, u: list[float], shape: str = "tigela") -> dict:
    """o ponto sintético de uma configuração com as contínuas normalizadas `u`, na forma `shape` do d²"""
    f = factor(name)
    d2 = distance2(u, shape)
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
                 delay: float = 0.0, shape: str = "tigela"):
        super().__init__(project, problem, None, evals, None, method, None)
        if shape not in SHAPES:
            raise ValueError(f"forma desconhecida: {shape} (há {', '.join(SHAPES)})")
        self.delay, self.shape = delay, shape
        self.req = project.requirements
        self.axis_keys = [k for k, _ in sg.axes(project, problem)]   # o nome da configuração sai destes valores

    def point(self, values: dict) -> dict:
        check_cancel()
        time.sleep(self.delay)
        name = sg.config_item({k: values[k] for k in self.axis_keys if k in values}, 0).name
        u = [(float(values.get(k, lo)) - lo) / (hi - lo) if hi > lo else U_BEST for k, lo, hi in self.free]
        r = evaluate(name, u or [U_BEST], self.shape)
        b = float(values.get("wing.span", sg.get_value(self.project, "wing.span")))
        return dict(values=dict(values), mtow=r["mtow"], ok=r["ok"],
                    why=r["why"], pv=r["pv"], m_bat=0.3, b=b, s_to=float(self.req.takeoff_run), lapes=True,
                    liquid=True, cand=None, req=self.req, stab={}, viol=r["viol"])


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
                 shape: str = "tigela", **_):
        self.project, self.catalog, self.backend = project, catalog, backend
        self.workers, self.evals, self.surfaces, self.shape = workers, evals, surfaces, shape
        self.start_method, self.delay, self.executors = start_method, delay, executors

    def quantities(self) -> list[str]:
        return ["mtow", "pv", "cp", "ee", "b"]

    def stages(self, project, problem: OptProblem) -> list[IStage]:
        return [SyntheticGeometry(self.delay), SyntheticSurfaces(project, problem, self.evals, self.surfaces,
                                                                 self.delay, self.shape), SyntheticScore()]

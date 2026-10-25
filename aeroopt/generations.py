"""Gerações de aviões: o algoritmo genético escolhe quais configurações o processo em etapas avalia, no lugar de
varrer todas as combinações.

Com poucas categorias e listas, as combinações cabem numa geração e o processo em etapas roda todas, como antes. Com
muitas (cada perfil por região, cada hélice, cada bateria, cada categoria multiplicam a conta, e um problema comum
passa de um milhão), varrer é impossível: cada configuração gasta vários pontos de projeto. As gerações resolvem
isso. Cada indivíduo é uma configuração, e o gene dele é o índice da opção escolhida em cada eixo discreto
(`stages.axes`). A primeira geração é sorteada; cada uma passa pelo processo em etapas inteiro (superfícies, 6GDL,
nota), e a nota volta para o núcleo, que monta a geração seguinte (`core/src/optim/ga.zig`: elite, seleção por
posição, cruzamento num ponto e mutação). O voo inválido fica atrás de todo voo válido, e quem parou numa etapa fica
por último. Uma configuração que já apareceu não roda de novo: a nota dela vem da memória.

    res = GenerationsSolver(population=16, generations=10).run(problem, StagedEvaluator(project))
    res.names["gerações"]     # (geração, configurações novas, melhor nota até ali)
"""
from __future__ import annotations

import copy
import math

from aerosim.interfaces.optim import ISolver, OptResult
from aerosim.parallel import Executors

from .pipeline import Pipeline
from .problem import apply_to_project, fold_bounds
from .stages import StagedEvaluator, axes, config_item, configurations, row


# quanto mais longe nas etapas, melhor: quem parou no 6GDL ganha de quem parou nas superfícies, e assim por diante
STAGE_TIER = {"nota": 0, "decolagem 6GDL": 1, "superfícies": 2, "voa": 3, "geometria": 4}


def fitness(r: dict) -> float:
    """a nota para a seleção, pelas regras de viabilidade (Deb, 2000; ver `stages._rank`): o voo válido pela nota;
    o voo inválido atrás de todo válido, pelo quanto viola as condições de validade; quem parou numa etapa atrás de
    todo voo, primeiro pela etapa a que chegou e depois pelo quanto viola. A seleção do núcleo é por posição: só a
    ordem importa, não a escala"""
    n = r.get("nota", math.nan)
    viol = r.get("violacao", math.nan)
    viol = viol if math.isfinite(viol) else 1.0          # parou sem uma medida de quanto: conta como 1
    if r.get("alive") and math.isfinite(n):
        return n if r.get("valido") else -1e9 - viol
    if r.get("alive"):
        return math.nan
    tier = STAGE_TIER.get(r.get("stage", ""), 5)
    return -1e9 * (2 + tier) - min(viol, 1e8)


def _best(rows: list[dict]) -> float:
    """a melhor nota de voo válido até ali (NaN enquanto nenhum valeu)"""
    return max((r["nota"] for r in rows if r.get("alive") and r.get("valido") and math.isfinite(r["nota"])),
               default=math.nan)


class GenerationsSolver(ISolver):
    name = "gerações (algoritmo genético sobre as configurações)"

    def __init__(self, population: int = 16, generations: int = 8, elite: int = 2, p_cross: float = 0.9,
                 p_mut: float = 0.15, seed: int = 1):
        self.population, self.generations, self.elite = int(population), int(generations), int(elite)
        self.p_cross, self.p_mut, self.seed = p_cross, p_mut, int(seed)

    def run(self, problem, evaluator: StagedEvaluator, progress=None, cancel=None, on_item=None) -> OptResult:
        """`on_item(etapa, linha)` a cada candidato que termina uma etapa; cada linha leva a "geração" dela"""
        p = copy.deepcopy(evaluator.project)          # o projeto do usuário não muda
        problem = copy.deepcopy(problem)
        fold_bounds(problem, p)
        apply_to_project(problem, p)
        ax = axes(p, problem, evaluator.catalog)
        n_all = math.prod(len(o) for _, o in ax) if ax else 1
        log: dict[str, list[int]] = {}
        history: list[tuple[int, int, float]] = []
        rows: list[dict] = []

        # os mesmos trabalhadores para todas as etapas de todas as gerações: os processos nascem uma vez (ou nem isso,
        # quando a janela passa os da sessão)
        own = getattr(evaluator, "executors", None) is None
        executors = (Executors(evaluator.workers, evaluator.start_method, getattr(evaluator, "warm", None),
                               getattr(evaluator, "preload", ())) if own else evaluator.executors)

        def stage_run(items, gen, f0, f1):
            pipe = Pipeline(evaluator.stages(p, problem), evaluator.start_method, executors)
            prog = (lambda f, t: progress(f0 + (f1 - f0) * f, f"geração {gen}: {t}")) if progress else None

            def cb(st, it):
                if on_item:
                    on_item(st, dict(row(it), geração=gen))
            out = pipe.run(items, evaluator.workers, prog, cancel, cb)
            for name, a, b in pipe.log:
                s = log.setdefault(name, [0, 0])
                s[0] += a
                s[1] += b
            return [dict(row(i), geração=gen) for i in out]

        try:
            if n_all <= self.population:                  # cabe numa geração: roda todas
                rows = stage_run(configurations(p, problem, evaluator.catalog), 1, 0.0, 1.0)
                history.append((1, len(rows), _best(rows)))
            else:
                from aerosim.backend.zig import ZigBackend
                be = evaluator.backend if hasattr(evaluator.backend, "ga_next") else ZigBackend()
                cfg = dict(n_genes=len(ax), pop=self.population, elite=self.elite, card=[len(o) for _, o in ax],
                           p_cross=self.p_cross, p_mut=self.p_mut, seed=self.seed, generation=0)
                genes = be.ga_init(cfg)
                seen: dict[tuple, dict] = {}
                for g in range(self.generations):
                    if cancel is not None and cancel():
                        break
                    keys = [tuple(int(round(x)) for x in ind) for ind in genes]
                    new = list(dict.fromkeys(k for k in keys if k not in seen))
                    items = [config_item({name: opts[k[j]] for j, (name, opts) in enumerate(ax)}, len(seen) + i + 1)
                             for i, k in enumerate(new)]
                    for k, r in zip(new, stage_run(items, g + 1, g / self.generations, (g + 1) / self.generations)):
                        seen[k] = r
                        rows.append(r)
                    fit = [fitness(seen[k]) for k in keys]
                    history.append((g + 1, len(new), _best(rows)))
                    cfg["generation"] = g + 1
                    genes = be.ga_next(cfg, genes, fit)
        finally:
            if own:
                executors.close()
        done = [r for r in rows if r["alive"] and math.isfinite(r["nota"])]
        best_row = max(done, key=lambda r: (r["valido"], r["nota"])) if done else {}
        return OptResult(rows=rows, best=best_row, names={"etapas": [(k, a, b) for k, (a, b) in log.items()],
                                                          "gerações": history, "combinações": n_all})

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

from .pipeline import Pipeline
from .problem import apply_to_project, fold_bounds
from .stages import StagedEvaluator, axes, config_item, configurations, row


def fitness(r: dict) -> float:
    """a nota para a seleção: voo válido > voo inválido > parou numa etapa (NaN)"""
    n = r.get("nota", math.nan)
    if not (r.get("alive") and math.isfinite(n)):
        return math.nan
    return n if r.get("valido") else n - 1e9


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

        def stage_run(items, gen, f0, f1):
            pipe = Pipeline(evaluator.stages(p, problem), evaluator.start_method)
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

        if n_all <= self.population:                  # cabe numa geração: roda todas
            rows = stage_run(configurations(p, problem, evaluator.catalog), 1, 0.0, 1.0)
            history.append((1, len(rows), max((fitness(r) for r in rows if math.isfinite(fitness(r))), default=math.nan)))
        else:
            from aerosim.backend.zig import ZigBackend
            be = evaluator.backend if hasattr(evaluator.backend, "ga_next") else ZigBackend()
            cfg = dict(n_genes=len(ax), pop=self.population, elite=self.elite, card=[len(o) for _, o in ax],
                       p_cross=self.p_cross, p_mut=self.p_mut, seed=self.seed, generation=0)
            genes = be.ga_init(cfg)
            seen: dict[tuple, dict] = {}
            best = math.nan
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
                ok = [f for f in fit if math.isfinite(f)]
                if ok:
                    best = max(best, max(ok)) if math.isfinite(best) else max(ok)
                history.append((g + 1, len(new), best))
                cfg["generation"] = g + 1
                genes = be.ga_next(cfg, genes, fit)
        done = [r for r in rows if r["alive"] and math.isfinite(r["nota"])]
        best_row = max(done, key=lambda r: (r["valido"], r["nota"])) if done else {}
        return OptResult(rows=rows, best=best_row, names={"etapas": [(k, a, b) for k, (a, b) in log.items()],
                                                          "gerações": history, "combinações": n_all})

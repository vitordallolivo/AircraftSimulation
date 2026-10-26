"""Gerações: o algoritmo genético do núcleo escolhe as configurações quando as combinações são muitas para varrer."""
import math

import pytest

import aeroopt
from aeroopt import categories as cat
from aeroopt import stages as sg
from aeroopt.generations import GenerationsSolver, fitness
from aerosim.design.project import DesignProject
from aerosim.interfaces.optim import IStage


class Fake(IStage):
    """nota barata: quantos eixos acertam o alvo (no lugar das superfícies, do 6GDL e da nota)"""
    name = "falsa"
    batch = True

    def __init__(self, target):
        self.target = target

    def run(self, items):
        for it in items:
            it.data.update(nota=float(sum(it.values.get(k) == v for k, v in self.target.items())), valido=True)
        return items


class FakeEvaluator(sg.StagedEvaluator):
    def __init__(self, project, target):
        super().__init__(project, workers=1)
        self.target = target

    def stages(self, project, problem):
        return [Fake(self.target)]


def _problem():
    p = DesignProject()
    pr = aeroopt.from_project(p)
    pr.params["categorias"] = list(cat.LEGACY) + [c for c in cat.CATEGORIES if c != "monoplano"]   # as 8 de antes
    names = sg.available(p, "wing.airfoil")
    for k in ("wing.airfoil", "wing.airfoil_tip", "power.propeller", "power.motor"):
        v = pr.variable(k)
        v.free, v.options = True, []
    return p, pr, names


def test_backend_ga_is_deterministic_and_inside_the_options():
    from aerosim.backend.zig import ZigBackend
    be = ZigBackend()
    cfg = dict(n_genes=3, pop=10, elite=2, card=[4, 3, 0], lo=[0, 0, -1], hi=[1, 1, 2], seed=7)
    g = be.ga_init(cfg)
    assert g.shape == (10, 3) and set(g[:, 0]) <= {0, 1, 2, 3} and ((g[:, 2] >= -1) & (g[:, 2] <= 2)).all()
    f = g[:, 0] + g[:, 2]
    assert (be.ga_next(cfg, g, f) == be.ga_next(cfg, g, f)).all()
    assert (be.ga_next(cfg, g, f)[0] == g[f.argmax()]).all()          # a elite passa igual


def test_generations_find_the_best_without_sweeping_everything():
    p, pr, names = _problem()
    ax = sg.axes(p, pr)
    n_all = math.prod(len(o) for _, o in ax)
    assert n_all > sg.MAX_CONFIGS                                       # varrer todas não dá
    with pytest.raises(ValueError, match="gerações"):
        sg.configurations(p, pr)
    target = {k: o[-1] for k, o in ax}
    seen = []
    res = GenerationsSolver(population=24, generations=25, seed=3).run(pr, FakeEvaluator(p, target),
                                                                       on_item=lambda st, r: seen.append(r["geração"]))
    assert res.best["nota"] == len(ax)                                  # achou o alvo
    assert len(res.rows) < n_all / 20                                   # avaliando uma fração das combinações
    assert len({r["name"] for r in res.rows}) == len(res.rows)          # nenhuma configuração roda duas vezes
    gens = res.names["gerações"]
    assert [g for g, _, _ in gens] == list(range(1, len(gens) + 1))
    assert all(b2 >= b1 for (_, _, b1), (_, _, b2) in zip(gens, gens[1:]))   # a melhor nunca piora (elite)
    assert set(seen) <= set(range(1, 26)) and res.names["combinações"] == n_all


def test_few_combinations_run_all_in_one_generation():
    p, pr, _ = _problem()
    pr.params["categorias"] = ["asa alta", "biplano"]
    for k in ("wing.airfoil", "wing.airfoil_tip", "power.motor"):
        pr.variable(k).free = False
    pr.variable("power.propeller").options = ["APC 15x8E", "Genérica 11x7"]
    res = GenerationsSolver(population=8).run(pr, FakeEvaluator(p, {}))
    assert len(res.rows) == 4 and res.names["gerações"][0][:2] == (1, 4)


def test_fitness_orders_valid_invalid_and_dead():
    assert fitness(dict(alive=True, nota=10.0, valido=True)) > fitness(dict(alive=True, nota=99.0, valido=False))
    # as regras de viabilidade: o inválido que viola menos ganha do que viola mais; quem parou numa etapa fica atrás
    # de todo voo, e quem chegou mais longe ganha
    inv = lambda v: fitness(dict(alive=True, nota=0.0, valido=False, violacao=v))
    assert inv(0.1) > inv(2.0) > fitness(dict(alive=False, stage="superfícies", violacao=0.01))
    assert fitness(dict(alive=False, stage="superfícies", violacao=5.0)) > \
        fitness(dict(alive=False, stage="voa", violacao=0.01)) > fitness(dict(alive=False, stage="geometria"))
    assert fitness(dict(alive=False, stage="voa", violacao=0.2)) > fitness(dict(alive=False, stage="voa", violacao=3))
    assert math.isnan(fitness(dict(alive=True, nota=math.nan)))                        # ainda rodando

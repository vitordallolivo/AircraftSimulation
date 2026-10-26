"""Os dados de teste do aeroopt (aeroopt/synthetic.py): o otimizador de verdade acha o que se sabe de antemão."""
import math

import pytest

from aeroopt import synthetic as sy
from aeroopt.generations import GenerationsSolver
from aeroopt.gui import example_project
from aeroopt.stages import SURFACE_METHODS, StagedSolver


@pytest.fixture(scope="module")
def case():
    """o exemplo com as categorias de antes do monoplano único: os nomes fazem os fatores, e com estes o melhor fica
    longe o bastante do segundo para toda busca achar com 24 pontos"""
    p, pr = example_project()
    pr.params["categorias"] = ["asa alta", "asa baixa", "biplano", "asa voadora", "cauda em V"]
    return p, pr


def test_the_landscape_is_what_the_docstring_says():
    r = sy.evaluate("x", [sy.U_BEST, sy.U_BEST])
    f = sy.factor("x")
    assert r["mtow"] == pytest.approx(4 * f) and r["pv"] == pytest.approx(2.2 - f) and r["ok"]
    assert not sy.evaluate("x", [0.0, 0.0])["ok"]                       # d² = 0,98 > 0,35
    assert sy.nota(dict(cp=1.0, ee=0.59)) == (25.0, False)
    # voo inválido até no melhor ponto quando f < 0,6286 (EE = (5f − 2,2)/(2,2 − f) < 0,6)
    assert sy.nota(sy.evaluate("y", [sy.U_BEST]))[1] == (sy.factor("y") >= 0.6286)


@pytest.mark.parametrize("method", list(SURFACE_METHODS))
def test_every_surface_search_finds_the_known_best(case, method):
    p, pr = case
    ex = sy.expected(p, pr)
    res = StagedSolver().run(pr, sy.SyntheticEvaluator(p, evals=24, surfaces=method, workers=1))
    assert res.best["name"] == sy.best(p, pr)
    assert res.best["nota"] == pytest.approx(ex[res.best["name"]]["nota"], rel=0.01)
    for r in res.rows:                                                  # cada uma para onde devia
        e = ex[r["name"]]
        assert (r["stage"] == "geometria" and not r["alive"]) == (e["stage"] == "geometria"), r["name"]
    span = next(v for v in pr.variables if v.key == "wing.span")
    assert res.best["values"]["wing.span"] == pytest.approx(span.lo + sy.U_BEST * (span.hi - span.lo), abs=0.02)


def test_processes_give_the_same_rows_as_serial(case):
    p, pr = case
    rows = []
    for w in (1, 3):
        ev = sy.SyntheticEvaluator(p, evals=12, workers=w, start_method="fork", delay=0.002)
        rows.append([(r["name"], r["alive"], round(r["nota"], 9) if math.isfinite(r["nota"]) else None)
                     for r in StagedSolver().run(pr, ev).rows])
    assert rows[0] == rows[1]


def test_generations_reach_the_best_with_few_configurations(case):
    p, pr = case
    res = GenerationsSolver(population=6, generations=6, seed=3).run(pr, sy.SyntheticEvaluator(p, evals=12,
                                                                                                workers=1))
    ex = sy.expected(p, pr)
    assert res.best["valido"] and res.best["nota"] >= 0.9 * ex[sy.best(p, pr)]["nota"]


@pytest.mark.parametrize("shape", sy.SHAPES)
def test_every_shape_keeps_the_optimum_at_u_best(shape):
    """as três formas do d² têm o ótimo no mesmo ponto, então `expected` vale para todas"""
    assert sy.distance2([sy.U_BEST] * 6, shape) == pytest.approx(0.0, abs=1e-15)
    assert all(sy.distance2([sy.U_BEST + dz] + [sy.U_BEST] * 5, shape) > 0 for dz in (-0.3, -0.05, 0.05, 0.3))


def test_coupled_shape_mixes_the_variables_and_multimodal_has_local_minima():
    d = lambda z0, z1: sy.distance2([sy.U_BEST + z0, sy.U_BEST + z1], "acoplada")
    assert d(0.1, 0.1) - d(0.1, 0.0) - d(0.0, 0.1) + d(0.0, 0.0) != pytest.approx(0.0, abs=1e-6)   # não separável
    assert sy.distance2([sy.U_BEST + 0.1, sy.U_BEST], "tigela") == pytest.approx(0.01)
    m = lambda z: sy.distance2([sy.U_BEST + z], "multimodal")
    assert m(0.18) < m(0.15) and m(0.18) < m(0.21)          # um mínimo local perto de z = 0,18 (a busca local para)
    with pytest.raises(ValueError):
        sy.distance2([0.5], "outra")

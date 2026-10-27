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


def test_rbf_surrogate_passes_through_the_points_and_guesses_between_them():
    """o substituto do núcleo (`rbf_fit`/`rbf_eval`): exato nos pontos, perto da tigela entre eles, e None quando os
    pontos ficam todos numa reta (a cauda linear não fica determinada)"""
    import numpy as np

    from aerosim.backend.zig import ZigBackend
    be = ZigBackend()
    g = np.linspace(0, 1, 5)
    X = np.array([(a, b) for a in g for b in g])
    y = -((X - 0.6) ** 2).sum(1)
    m = be.rbf_fit(X, y)
    assert np.allclose(be.rbf_eval(m, X), y, atol=1e-9)
    mid = np.array([(0.375, 0.625), (0.625, 0.125)])
    assert np.allclose(be.rbf_eval(m, mid), -((mid - 0.6) ** 2).sum(1), atol=0.01)
    assert be.rbf_fit([[0, 0], [0.5, 0.5], [1, 1], [0.25, 0.25]], [1, 2, 3, 4]) is None


def test_surrogate_beats_plain_generations_on_the_coupled_shape():
    """com o mesmo total de pontos, o substituto escolhe filhos melhores que o GA puro na forma acoplada (no banco,
    6 contínuas e 48 pontos, a mediana de 7 sementes foi de 91 % para 98 % do ótimo)"""
    import statistics
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
    import banco_otimizadores as bo
    rows = bo.run_surfaces(["acoplada"], ["gerações", "substituto"], 5, 48, 6)
    med = {m: statistics.median(r["final"] for r in rows if r["method"] == m) for m in ("gerações", "substituto")}
    assert med["substituto"] > med["gerações"] + 0.03 and med["substituto"] >= 0.95

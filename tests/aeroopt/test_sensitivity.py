"""Sensibilidade do melhor (aeroopt/sensitivity.py), conferida com os dados de teste, em que a resposta é sabida.

A nota sintética é 25·(4f(1 − d²) − 2,2 + f), com d² = Σ(u_k − 0,7)² (aeroopt/synthetic.py), então em cada contínua
∂N/∂u_k = −200 f (u_k − 0,7) e ∂²N/∂u_k² = −200 f, exatos: o modelo local, que tem os mesmos termos, tem de dar isso."""
import copy
import math

import pytest

from aeroopt import synthetic as sy
from aeroopt.gui import example_project
from aeroopt.problem import apply_to_project, fold_bounds
from aeroopt.sensitivity import free, sensitivity, snap


@pytest.fixture(scope="module")
def case():
    """o melhor depois da busca das superfícies de verdade (coordenadas), com o histórico dela"""
    p, pr = example_project()
    ev = sy.SyntheticEvaluator(p, evals=16, workers=1)
    name = sy.best(p, pr)
    it = next(i for i in sy.sg.configurations(p, pr) if i.name == name)
    pp, prr = copy.deepcopy(p), copy.deepcopy(pr)
    fold_bounds(prr, pp)
    apply_to_project(prr, pp)
    {s.name: s for s in ev.stages(pp, prr)}["superfícies"].one(it)
    return p, pr, ev, sy.sg.row(it), sy.factor(name)


def _known(pr, row, f):
    for key, lo, hi, _ in free(pr):
        u = (row["values"][key] - lo) / (hi - lo)
        yield key, -200 * f * (u - sy.U_BEST) / (hi - lo), -200 * f / (hi - lo) ** 2


def test_only_the_free_continuous_of_the_best_move(case):
    p, pr, ev, row, _ = case
    s = sensitivity(p, pr, row, ev)
    assert [r["key"] for r in s["rows"]] != []
    assert {r["key"] for r in s["rows"]} == {v.key for v in pr.free_variables() if v.kind == "contínua"}
    for r in s["rows"]:                                 # dentro dos limites do problema
        assert r["lo"] <= r["x_minus"] <= r["x0"] <= r["x_plus"] <= r["hi"]


def test_the_search_history_is_enough_no_new_point(case):
    p, pr, ev, row, f = case
    s = sensitivity(p, pr, row, ev)
    assert s["new"] == 0 and s["quad"] and s["used"] >= 5
    u = [(row["values"][k] - lo) / (hi - lo) for k, lo, hi, _ in free(pr)]
    assert s["base"]["nota"] == pytest.approx(sy.nota(sy.evaluate(row["name"], u))[0], rel=1e-9)
    by = {r["key"]: r for r in s["rows"]}
    for key, g, c in _known(pr, row, f):
        assert by[key]["slope"] == pytest.approx(g, abs=1e-6 * abs(c))
        assert by[key]["curv"] == pytest.approx(c, rel=1e-6)
    swings = [r["swing"] for r in s["rows"]]
    assert swings == sorted(swings, reverse=True)       # da que mais mexe para a que menos


def test_without_history_only_the_axes_are_evaluated(case):
    p, pr, ev, row, f = case
    s = sensitivity(p, pr, {**row, "history": []}, ev)
    n = len(free(pr))
    assert s["new"] == 2 * n + 1                         # o melhor e x₀ ± h em cada eixo, nada mais
    by = {r["key"]: r for r in s["rows"]}
    for key, g, c in _known(pr, row, f):
        assert by[key]["slope"] == pytest.approx(g, abs=1e-6 * abs(c)) and by[key]["asked"]
        assert by[key]["curv"] == pytest.approx(c, rel=1e-6)


def test_a_side_that_does_not_close_is_reported(case):
    p, pr, ev, row, f = case
    (k1, l1, h1, s1), (k2, l2, h2, s2) = free(pr)
    # u₁ ≈ 0,17 e u₂ = 0,7: d² ≈ 0,28 fecha; em u₁ − h ≈ 0,06 (no passo do campo), d² ≈ 0,41 passa do máximo (0,35)
    values = {**row["values"], k1: snap(l1 + 0.17 * (h1 - l1), l1, h1, s1), k2: snap(l2 + 0.7 * (h2 - l2), l2, h2, s2)}
    s = sensitivity(p, pr, {"values": values, "history": []}, ev)
    assert s["base"]["ok"]
    r = next(r for r in s["rows"] if r["key"] == k1)
    assert [side for side, *_ in r["blocked"]] == ["−"] and "não fecha" in r["blocked"][0][2]
    assert r["slope"] > 0 and math.isfinite(r["curv"])  # o ponto em u₀ + h/2 completa a curvatura


def test_processes_give_the_same_answer(case):
    from aerosim.parallel import make_executor
    p, pr, ev, row, _ = case
    serial = sensitivity(p, pr, {**row, "history": []}, ev)
    with make_executor("processos", 2, "fork") as ex:
        par = sensitivity(p, pr, {**row, "history": []}, ev, executor=ex)
    key = lambda s: [(r["key"], round(r["slope"], 9), round(r["curv"], 6)) for r in s["rows"]]  # noqa: E731
    assert key(serial) == key(par)
    assert all(math.isfinite(r["swing"]) for r in serial["rows"])


def test_one_at_a_time_ignores_the_history_and_matches(case):
    from aeroopt.sensitivity import SensParams
    p, pr, ev, row, f = case
    s = sensitivity(p, pr, row, ev, SensParams(method="eixos"))
    assert s["new"] == 2 * len(free(pr))               # o melhor vem do histórico; só os eixos são novos
    by = {r["key"]: r for r in s["rows"]}
    for key, g, c in _known(pr, row, f):
        assert by[key]["slope"] == pytest.approx(g, abs=1e-6 * abs(c))
        assert by[key]["curv"] == pytest.approx(c, rel=1e-6)


def test_morris_effects_of_the_known_quadratic(case):
    """na caixa u₀ ± h, o efeito elementar de uma parábola separável num passo de a para b é a média das
    inclinações nas pontas: μ fica perto da inclinação em u₀ e σ > 0 acusa a curvatura"""
    from aeroopt.sensitivity import SensParams
    p, pr, ev, row, f = case
    sp = SensParams(method="morris", trajectories=8)
    s = sensitivity(p, pr, row, ev, sp)
    k = len(free(pr))
    assert 0 < s["new"] <= sp.trajectories * (k + 1)
    for r in s["rows"]:
        assert r["steps"] == sp.trajectories and r["mustar"] >= abs(r["slope"]) - 1e-12
        assert r["sigma"] > 0 and not math.isfinite(r["curv"])
    by = {r["key"]: r for r in s["rows"]}
    for key, g, c in _known(pr, row, f):              # |μ − g| ≤ |c|·h·faixa (a caixa tem meia largura h·faixa)
        lo, hi = next((lo, hi) for kk, lo, hi, _ in free(pr) if kk == key)
        assert abs(by[key]["slope"] - g) <= abs(c) * 0.1 * (hi - lo) + 1e-9


def test_tolerance_and_elasticity(case):
    from aeroopt.sensitivity import SensParams
    p, pr, ev, row, f = case
    s = sensitivity(p, pr, row, ev, SensParams(tol=0.01))
    for r in s["rows"]:
        d = 0.01 * r["x0"]
        assert r["tol_delta"] == pytest.approx(d)
        assert r["tol_plus"] == pytest.approx(r["slope"] * d + 0.5 * r["curv"] * d * d)
        assert r["tol_minus"] == pytest.approx(-r["slope"] * d + 0.5 * r["curv"] * d * d)
        assert r["elast"] == pytest.approx(r["slope"] * r["x0"] / s["base"]["nota"])
    assert s["sigma"] > 0


def test_limits_of_the_problem(case):
    """os dados de teste não dependem da pista nem das restrições: ∂N/∂L = 0 em todo limite, e cada um custa 2"""
    from aeroopt.sensitivity import SensParams, limits
    p, pr, ev, row, f = case
    s = sensitivity(p, pr, row, ev, SensParams(limits=True))
    pr2 = copy.deepcopy(pr)
    fold_bounds(pr2, copy.deepcopy(p))
    assert {lm["key"] for lm in s["limits"]} == {k for k, *_ in limits(p, pr2)}
    assert "pista" in {lm["key"] for lm in s["limits"]}
    for lm in s["limits"]:
        assert lm["new"] == 2 and lm["dNdL"] == pytest.approx(0.0, abs=1e-9) and not lm["binding"]

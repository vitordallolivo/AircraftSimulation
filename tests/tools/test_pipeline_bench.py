"""tools/pipeline_bench.py: a lei de Amdahl invertida, o sorteio das configurações e uma comparação curta que confere
que série e processos dão o mesmo resultado."""
import math
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))

import pipeline_bench as pb  # noqa: E402


def test_karp_flatt_is_amdahl_inverted():
    """ganho ideal (S = n): nada serial; nenhum ganho (S = 1): tudo serial; Amdahl com f = 0,2 e n = 4 dá
    S = 1/(0,2 + 0,8/4) = 2,5, e a conta invertida devolve os 0,2"""
    assert pb.karp_flatt(4.0, 4) == pytest.approx(0.0)
    assert pb.karp_flatt(1.0, 4) == pytest.approx(1.0)
    assert pb.karp_flatt(2.5, 4) == pytest.approx(0.2)
    assert math.isnan(pb.karp_flatt(1.0, 1))


def test_bench_compares_strategies_with_the_same_result():
    from aeroopt.gui import example_project
    from aeroopt.stages import StagedEvaluator
    p, pr = example_project()
    items = pb.sample(p, pr, 3)
    assert len({i.name for i in items}) == 3 and [i.name for i in pb.sample(p, pr, 3)] == [i.name for i in items]
    ev = StagedEvaluator(p, six_dof=False, evals=2)
    rows = pb.bench(p, pr, ev, items, ["serie", "fork"], [2], log=lambda *_: None)
    assert [(r["strategy"], r["n"]) for r in rows] == [("serie", 1), ("fork", 2)]
    assert all(r["same"] for r in rows) and rows[0]["speedup"] == pytest.approx(1.0)
    assert set(rows[1]["stages"]) == set(rows[0]["stages"]) >= {"geometria", "superfícies", "nota"}
    assert "fork" in pb.table(rows)

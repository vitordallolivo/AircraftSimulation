"""O caminho da busca em coordenadas paralelas (aeroopt/pcoords.py), com os dados de teste."""
import math

import pytest

from aeroopt import pcoords
from aeroopt import synthetic as sy
from aeroopt.gui import example_project
from aeroopt.stages import StagedSolver


@pytest.fixture(scope="module")
def run():
    p, pr = example_project()
    res = StagedSolver().run(pr, sy.SyntheticEvaluator(p, evals=8, workers=1))
    return p, pr, res.rows


def test_axes_and_lines(run):
    p, pr, rows = run
    d = pcoords.data(pr, rows)
    keys = [a["key"] for a in d["axes"]]
    assert {v.key for v in pr.free_variables()} <= set(keys) and keys[-3:] == ["mtow", "pv", "nota"]
    assert len(d["lines"]) == len(rows)
    for line in d["lines"]:
        assert len(line["ys"]) == len(keys)
        assert all(0 <= y <= 1 for y in line["ys"] if math.isfinite(y))
    lst = next(a for a in d["axes"] if a["kind"] == "lista")
    assert lst["names"] == sorted(lst["names"]) and len(lst["names"]) >= 2


def test_path_is_the_best_so_far_and_ends_at_the_best(run):
    p, pr, rows = run
    path = pcoords.path(rows)
    by = {r["name"]: r for r in rows}
    assert path[-1] == sy.best(p, pr)
    idx = [by[n]["index"] for n in path]
    assert idx == sorted(idx)                                   # na ordem de avaliação
    keys = [pcoords._key(by[n]) for n in path]
    assert keys == sorted(keys) and len(set(keys)) == len(keys)  # cada um melhor que o anterior


def test_html_is_self_contained(run, tmp_path):
    p, pr, rows = run
    out = pcoords.write_html(pr, rows, str(tmp_path / "caminho.html"), "teste")
    txt = open(out, encoding="utf-8").read()
    assert txt.startswith("<!doctype html>") and "<svg" in txt and "const D = {" in txt
    assert "http" not in txt.replace("http://www.w3.org/2000/svg", "")   # nada de fora: abre sem internet
    assert "NaN" not in txt.split("const D = ", 1)[1].split(";\n", 1)[0]  # JSON válido (NaN vira null)

"""aeroopt: o problema como arquivo, isolar variáveis e o mini-MDO pelo contrato (O02)."""
import numpy as np
import pytest

import aeroopt
from aeroopt.mini_mdo import MiniMdoEvaluator, MiniMdoSolver
from aerosim.design.project import DesignProject
from aerosim.interfaces.optim import OptProblem


def _project():
    p = DesignProject()
    for v in p.variables:
        if v.key in ("wing.span", "wing.area", "power.tilt"):
            v.mode = "variável"
    p.mdo.particles, p.mdo.iterations = 6, 3
    return p


def test_file_round_trip(tmp_path):
    pr = aeroopt.from_project(_project(), "teste")
    f = tmp_path / "p.opt.json"
    aeroopt.save(pr, str(f))
    assert aeroopt.load(str(f)) == pr
    assert {v.key for v in pr.free_variables()} == {"wing.span", "wing.area", "power.tilt"}
    assert all(v.key != "req.mass" for v in pr.variables)          # "calculado" é saída, não variável


def test_isolate_by_key_and_by_group():
    pr = aeroopt.from_project(_project())
    assert set(pr.isolate("asa")) == {v.key for v in pr.variables if v.key.startswith("wing.")}
    assert pr.isolate("power.tilt") == ["power.tilt"]
    assert set(pr.isolate("wing.span", "propulsão")) == {"wing.span"} | {v.key for v in pr.variables
                                                                         if v.key.startswith("power.")}
    with pytest.raises(KeyError):
        pr.isolate("cauda")
    with pytest.raises(ValueError):
        OptProblem.from_dict({"formato": "outro"})


def test_same_result_as_the_mdo_page_bit_for_bit():
    """o problema lido do projeto e rodado pelo contrato dá as mesmas avaliações que a página MDO"""
    from aerosim.design import mdo
    p = _project()
    rows, best, _ = mdo.run(p)
    res = MiniMdoSolver().run(aeroopt.from_project(p), MiniMdoEvaluator(DesignProject()))
    assert len(res.rows) == len(rows)
    assert np.array_equal([r["x"] for r in res.rows], [r["x"] for r in rows])
    assert np.array_equal([r["score"] for r in res.rows], [r["score"] for r in rows])
    assert res.best["score"] == best["score"]


def test_isolated_variable_is_the_only_one_that_moves():
    p = _project()
    pr = aeroopt.from_project(p)
    pr.isolate("wing.span")
    res = MiniMdoSolver().run(pr, MiniMdoEvaluator(p))
    spans = {r["span"] for r in res.rows}
    assert len(spans) > 1
    assert {r["area"] for r in res.rows} == {p.wing_draft.area}
    assert {r["tilt"] for r in res.rows} == {p.power_draft.tilt}
    assert p.variables == _project().variables                      # o projeto do usuário não mudou

"""aeroopt: o problema como arquivo, isolar variáveis e o mini-MDO pelo contrato (O02)."""
import pytest

import aeroopt
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

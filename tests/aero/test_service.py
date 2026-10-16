"""Cache das polares 3D (aerosim/aero/service.py): a mesma configuração + método + caso não roda de novo;
o método caro também fica em disco; qualquer mudança na configuração ou no caso é outra entrada."""
import numpy as np
import pytest

from aerosim.aero import service
from aerosim.aero.base import AeroSolverBase
from aerosim.interfaces.aero import AeroCase
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model


class Counting(AeroSolverBase):
    """método de mentira: C_L = 0,1 α, conta quantas vezes rodou"""
    name, title, cost, fidelity = "conta", "conta", "caro", "llt"
    supports_beta = supports_rates = False

    def __init__(self):
        self.runs = 0

    def evaluate(self, model, case, points):
        self.runs += 1
        return [dict(CL=0.1 * np.degrees(p.alpha) + 0.01 * model.S, CD=0.02, CDi=0.01, Cm=-0.01, CY=0, Cl=0, Cn=0)
                for p in points]


@pytest.fixture(autouse=True)
def _own_disk(monkeypatch, tmp_path):
    """cada teste com o seu disco (o método de mentira é 'caro': vai para o disco)"""
    monkeypatch.setenv("AEROSIM_CACHE", str(tmp_path))
    service.clear_cache()


@pytest.fixture
def case():
    return AeroCase(V=15, alphas=np.array([0.0, 2.0, 4.0]))


def test_same_question_runs_once(case):
    service.clear_cache()
    so, m = Counting(), build_model(conventional())
    a = service.solve(so, m, case)
    b = service.solve(so, m, case)
    assert so.runs == 1 and a.source == "calculado" and b.source == "cache" and b.fidelity == "llt"
    assert np.allclose(a.CL, b.CL)
    b.CL[:] = 0                                            # quem recebe pode mexer: o guardado não muda
    assert np.allclose(service.solve(so, m, case).CL, a.CL)


def test_changes_are_new_entries(case):
    service.clear_cache()
    so = Counting()
    ac = conventional()
    service.solve(so, build_model(ac), case)
    ac.wing.sections[-1].chord *= 0.9
    service.solve(so, build_model(ac), case)
    service.solve(so, build_model(ac), AeroCase(V=16, alphas=case.alphas))
    assert so.runs == 3


def test_expensive_method_comes_back_from_disk(case, tmp_path):
    so, m = Counting(), build_model(conventional())
    service.solve(so, m, case)
    service.clear_cache()                                  # outra sessão: memória vazia
    p = service.solve(so, m, case)
    assert so.runs == 1 and p.source == "cache" and list((tmp_path / "polar3d").rglob("*.pkl.gz"))
    assert service.solve(so, m, case, use_cache=False).source == "calculado" and so.runs == 2


def test_aerodynamics_tab_uses_the_cache(manager):
    service.clear_cache()
    ac = conventional()
    kw = dict(use_lltdrek=False, use_zig=True, full=False, tips=False)
    r1 = manager.run("aerodynamics", ac, kw)
    r2 = manager.run("aerodynamics", ac, kw)
    assert r1.summary["[modelo interno] de onde"] == "calculado" and r2.summary["[modelo interno] de onde"] == "cache"

"""Comparação dos solvers aerodinâmicos (os externos são pulados se não estiverem instalados)."""
import math

import numpy as np
import pytest

from aerosim.aero import (AeroCase, AsbVLMSolver, LltdrekSolver, ZigPanelSolver, mac_frac, polar_metrics,
                          x_at_mac)
from aerosim.model.templates import conventional


@pytest.fixture(scope="module")
def case():
    return AeroCase(V=15, alphas=np.array([-2.0, 0.0, 2.0, 4.0, 6.0]), alpha_d=2.0, ref=(0.0, 0.0, 0.0), n_span=8)


def test_mac_position_roundtrip():
    ac = conventional()
    assert mac_frac(ac, x_at_mac(ac, 0.25)) == pytest.approx(0.25)


def test_zig_solver(backend, case):
    ac = conventional()
    p = ZigPanelSolver(backend).solve(ac, case)
    assert p.deriv("CLa") > 3 and p.deriv("Cma") < 0 and p.deriv("Cnb") > 0 and p.deriv("Clb") < 0
    assert p.deriv("Clp") < 0 and p.deriv("Cmq") < 0 and p.deriv("Cmde") < 0
    m = polar_metrics(p, ac, case)
    assert 0 < m["SM"] < 60 and m["e"] > 0.5


@pytest.mark.parametrize("cls", [LltdrekSolver, AsbVLMSolver])
def test_external_solver_agrees(backend, case, cls):
    so = cls()
    if so.available():
        pytest.skip(so.available())
    ac = conventional()
    p = so.solve(ac, case)
    z = ZigPanelSolver(backend).solve(ac, case)
    assert p.deriv("CLa") == pytest.approx(z.deriv("CLa"), rel=0.15)
    assert p.deriv("Cma") < 0
    assert p.deriv("Cmq") == pytest.approx(z.deriv("Cmq"), rel=0.35)
    assert np.isfinite(p.CL).all()

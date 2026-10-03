"""Solvers aerodinâmicos: todos recebem o modelo universal e devolvem coeficientes universais
(os externos são pulados se não estiverem instalados)."""
import math

import numpy as np
import pytest

from aerosim.aero import AeroCase, AsbVLMSolver, LltdrekSolver, ZigPanelSolver, parabolic_polar, polar_metrics
from aerosim.interfaces.aero import FlightPoint
from aerosim.model.templates import conventional, flying_wing
from aerosim.model.universal import build_model


@pytest.fixture(scope="module")
def case():
    return AeroCase(V=15, alphas=np.array([-2.0, 0.0, 2.0, 4.0, 6.0]), alpha_d=2.0, ref=(0.0, 0.0, 0.0), n_span=8)


def test_mac_position_roundtrip():
    m = build_model(conventional())
    assert m.mac_frac(m.x_at_mac(0.25)) == pytest.approx(0.25)


def test_zig_solver(backend, case):
    m = build_model(conventional())
    p = ZigPanelSolver(backend).solve(m, case)
    assert p.deriv("CLa") > 3 and p.deriv("Cma") < 0 and p.deriv("Cnb") > 0 and p.deriv("Clb") < 0
    assert p.deriv("Clp") < 0 and p.deriv("Cmq") < 0 and p.deriv("Cmde") < 0
    met = polar_metrics(p, m, case)
    assert 0 < met["SM"] < 60 and met["e"] > 0.5
    fit = parabolic_polar(p)
    assert fit["CD0"] > 0 and fit["k"] > 0


def test_evaluate_is_universal(backend, case):
    """o mesmo ponto de voo universal dá o mesmo que a sessão do núcleo, com taxas adimensionais"""
    m = build_model(conventional())
    so = ZigPanelSolver(backend)
    r = so.evaluate(m, case, [FlightPoint(0.05, p=0.02)])[0]
    with backend.session_for(m) as s:
        raw = s.aero_coeffs_ex(15, 0.05, 0.0, 0.02 * 2 * 15 / m.b, 0, 0, ref=[0, 0, 0])
    assert r["Cl"] == pytest.approx(raw["Cl"]) and set(r) >= {"CL", "CD", "Cm", "Cl", "Cn", "CY"}


@pytest.mark.parametrize("cls", [LltdrekSolver, AsbVLMSolver])
def test_external_solver_agrees(backend, case, cls):
    so = cls()
    if so.available():
        pytest.skip(so.available())
    m = build_model(conventional())
    p = so.solve(m, case)
    z = ZigPanelSolver(backend).solve(m, case)
    assert p.deriv("CLa") == pytest.approx(z.deriv("CLa"), rel=0.15)
    assert p.deriv("Cma") < 0
    assert p.deriv("Cmq") == pytest.approx(z.deriv("Cmq"), rel=0.35)
    assert np.isfinite(p.CL).all()


def test_lltdrek_handles_control_breaks(backend, case):
    """o modelo universal tem estações nos limites dos comandos; o tradutor do lltdrek as junta"""
    so = LltdrekSolver()
    if so.available():
        pytest.skip(so.available())
    p = so.solve(build_model(flying_wing()), case)
    assert np.isfinite(p.CL).all() and p.deriv("CLa") > 3

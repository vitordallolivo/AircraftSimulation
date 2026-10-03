"""Plano de Trefftz: casos de referência da literatura."""
import math

import numpy as np
import pytest

from aerosim.aero import tipdevices as td


def test_planar_is_elliptic():
    assert td.span_efficiency("plana", 0.0, 60) == pytest.approx(1.0, abs=2e-3)


def test_planar_root_moment_elliptic():
    # elíptica: M_raiz = (L/2)(4 s / 3π), L = 1, s = 1/2
    M = td.optimal_loading(td.trace("plana", 0.0, 300))["Mroot"]
    assert M == pytest.approx(0.5 * 4 * 0.5 / (3 * math.pi), rel=5e-3)


def test_box_wing_kroo():
    # Kroo (2001): caixa com h/b = 0,2 → e ≈ 1,46
    assert td.span_efficiency("caixa", 0.2, 60) == pytest.approx(1.46, abs=0.03)


def test_endplate_matches_raymer():
    # placa de ponta: Raymer AR_ef = AR (1 + 1,9 h/b)
    for hb in (0.1, 0.2):
        assert td.span_efficiency("placa", hb, 60) == pytest.approx(float(td.raymer_endplate(hb)), rel=0.03)


def test_ordering():
    e = {k: td.span_efficiency(k, 0.2, 60) for k in ("winglet", "caixa", "asa_c")}
    assert 1.3 < e["winglet"] < e["caixa"]
    assert e["asa_c"] == pytest.approx(e["caixa"], abs=0.02)


def test_device_study_shapes():
    r = td.device_study(2.5, 1.0, 0.6, 0.3, 0.85, hb=np.linspace(0, 0.2, 5))
    assert r["dD_winglet"][0] == 0.0
    assert (np.diff(r["e_winglet"]) > 0).all()

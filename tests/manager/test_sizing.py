"""Dimensionamento inicial: equações, região viável e a aba (polar vinda de fora)."""
import math

import numpy as np
import pytest

from aerosim.sizing import ParabolicPolar, Requirements, design_point, estimate_polar, required_tw
from aerosim.sizing.constraints import landing_ws, stall_ws


def test_cruise_minimum_drag_point():
    # T/W de cruzeiro é mínimo em W/S = q √(C_D0/k) e vale 2 √(C_D0 k)
    r, a = Requirements(V_cruise=20.0), ParabolicPolar(CD0=0.03, k=0.05)
    q = 0.5 * r.rho * 400
    ws = np.linspace(20, 600, 20001)
    tw = required_tw("cruzeiro", ws, r, a)
    assert ws[np.argmin(tw)] == pytest.approx(q * math.sqrt(0.03 / 0.05), rel=1e-3)
    assert tw.min() == pytest.approx(2 * math.sqrt(0.03 * 0.05), rel=1e-4)


def test_design_point_and_optimal_band():
    r, a = Requirements(S_L=30.0, climb_grad=8.0, V_max=22.0), ParabolicPolar()
    dp = design_point(r, a, tol=0.05)
    assert dp["ws"] <= min(stall_ws(r, a), landing_ws(r, a)) + 1e-9
    for k in ("decolagem", "subida", "gradiente", "cruzeiro", "vmax", "curva"):
        assert required_tw(k, [dp["ws"]], r, a)[0] <= dp["tw"] + 1e-9
    b0, b1 = dp["band"]
    assert b0 <= dp["ws"] <= b1
    env = dp["env"][(dp["grid"] >= b0) & (dp["grid"] <= b1)]
    assert env.max() <= 1.05 * dp["tw"] + 1e-9


def test_landing_limit_formula():
    r, a = Requirements(S_L=40.0, mu_brake=0.3), ParabolicPolar(CLmax=1.5)
    # toque a 1,15 V_S, frenagem μ g: S_L = (1,15 V_S)² / (2 μ g)
    ws = landing_ws(r, a)
    Vs = math.sqrt(2 * ws / (r.rho * a.CLmax))
    assert (1.15 * Vs) ** 2 / (2 * 0.3 * 9.80665) == pytest.approx(40.0)


def test_estimate_polar_raymer():
    p = estimate_polar(Swet_S=4.0, Cfe=0.0055, AR=8.0)
    e = 1.78 * (1 - 0.045 * 8 ** 0.68) - 0.64
    assert p.CD0 == pytest.approx(0.022) and p.k == pytest.approx(1 / (math.pi * 8 * e))


def test_sizing_tab_polar_comes_from_outside(manager):
    from aerosim.model.templates import conventional
    sim = manager.get("sizing")
    keys = {p.key for p in sim.parameters_for(conventional(), {})}
    assert "Cfe" in keys and "method" not in keys           # a aba não escolhe método de polar
    r = manager.run("sizing", conventional(), {"S_L": 30.0})
    assert "c_região viável" in r.series and any(k.startswith("c_faixa ótima") for k in r.series)
    assert any(c.item == "corrida de pouso" for c in r.checks)
    # com a polar da aba Aerodinâmica: reaproveita a última calculada para esta configuração
    manager.run("aerodynamics", conventional(), {"use_lltdrek": False, "a0": -4.0, "a1": 16.0, "da": 2.0})
    r = manager.run("sizing", conventional(), {"source": "aba Aerodinâmica (da aeronave)"})
    assert r.summary["polar"].startswith("aba Aerodinâmica")

"""Esteira da hélice (modificador esteira.disco, core/src/modifiers/slipstream.zig): invariâncias pedidas na
literatura e no plano — sem tração nada muda, o sentido de rotação espelha o rolamento, bimotor simétrico com
sentidos opostos não rola, os motores se somam (superposição) e a velocidade bate com a teoria do momento."""
import math

import numpy as np
import pytest

from aerosim.model import modifiers as mods
from aerosim.model.templates import conventional, twin_boom
from aerosim.model.universal import build_model

A = math.radians(4.0)


def coeffs(backend, ac, T, Q, V=10.0, alpha=A, beta=0.0):
    with backend.session_for(build_model(ac)) as s:
        return s.aero_coeffs_thrust(V, alpha, beta, T, Q)


def with_slip(ac, **params):
    ac = ac.copy()
    ac.modifiers = ac.modifiers + [mods.Modifier("esteira.disco", params=params)]
    return ac


def test_zero_thrust_is_bit_identical(backend):
    ac = conventional()
    a = coeffs(backend, ac, [0.0], [0.0])
    b = coeffs(backend, with_slip(ac), [0.0], [0.0])
    assert a == b
    with backend.session_for(build_model(ac)) as s:
        assert s.aero_coeffs(10.0, A, 0.0) == a                     # sem motor ligado = os coeficientes de sempre


def test_thrust_adds_lift_on_the_wing_behind_the_prop(backend):
    ac = with_slip(conventional())
    base = coeffs(backend, ac, [0.0], [0.0])
    on = coeffs(backend, ac, [30.0], [1.2])
    assert on["CL_wing"] > base["CL_wing"] * 1.01
    off = coeffs(backend, with_slip(conventional(), axial=0.0, giro=0.0), [30.0], [1.2])
    assert off == base                                              # os dois efeitos desligados = nada


def test_rotation_sense_mirrors_roll(backend):
    ac = with_slip(conventional(), axial=0.0)                      # só o giro
    r1 = coeffs(backend, ac, [30.0], [1.2])
    ac2 = ac.copy()
    ac2.propulsion[0].sense = -ac2.propulsion[0].sense
    r2 = coeffs(backend, ac2, [30.0], [1.2])
    assert abs(r1["Cl"]) > 1e-5 and r1["Cl"] == pytest.approx(-r2["Cl"], rel=1e-9, abs=1e-12)


def test_symmetric_twin_with_opposite_senses_does_not_roll(backend):
    ac = with_slip(twin_boom())
    assert ac.propulsion[0].sense == -ac.propulsion[1].sense and ac.propulsion[0].y == -ac.propulsion[1].y
    r = coeffs(backend, ac, [25.0, 25.0], [1.0, 1.0])
    base = coeffs(backend, ac, [0.0, 0.0], [0.0, 0.0])
    assert r["CL_wing"] > base["CL_wing"]
    assert abs(r["Cl"]) < 1e-9 and abs(r["Cn"]) < 1e-9 and abs(r["CY"]) < 1e-9


def test_superposition_of_two_motors(backend):
    """as esteiras não se cruzam: o efeito dos dois juntos é a soma do de cada um sozinho"""
    ac = with_slip(twin_boom())
    base = coeffs(backend, ac, [0.0, 0.0], [0.0, 0.0])
    left = coeffs(backend, ac, [25.0, 0.0], [1.0, 0.0])
    right = coeffs(backend, ac, [0.0, 25.0], [0.0, 1.0])
    both = coeffs(backend, ac, [25.0, 25.0], [1.0, 1.0])
    for k in ("CL", "CD", "Cl", "Cm", "Cn"):
        assert both[k] - base[k] == pytest.approx((left[k] - base[k]) + (right[k] - base[k]), abs=1e-12)
    assert left["Cl"] == pytest.approx(-right["Cl"], abs=1e-12)    # cada um sozinho rola para um lado


def test_motor_mask_picks_motors(backend):
    ac = twin_boom()
    ac.modifiers = ac.modifiers + [mods.Modifier("esteira.disco", props=[0])]
    left_only = coeffs(backend, ac, [25.0, 25.0], [1.0, 1.0])
    ac2 = with_slip(twin_boom())
    left = coeffs(backend, ac2, [25.0, 0.0], [1.0, 0.0])
    assert left_only["Cl"] == pytest.approx(left["Cl"], abs=1e-12)


def test_probe_matches_momentum_theory(backend):
    T, D, V, rho = 30.0, 0.38, 10.0, 1.225
    R = D / 2
    w0 = -V / 2 + math.sqrt(V * V / 4 + T / (2 * rho * math.pi * R * R))
    pts = np.array([[0.0, 0, 0], [-0.5, 0, 0], [-100.0, 0, 0], [0.5, 0, 0]])
    out = backend.probe_slipstream(T, 1.2, D, V, rho, 1.0, pts)
    assert out[0, 0] == pytest.approx(w0, rel=1e-12)
    assert out[1, 0] == pytest.approx(w0 * (1 + 0.5 / math.hypot(0.5, R)), rel=1e-12)
    assert out[2, 0] == pytest.approx(2 * w0, rel=1e-4)            # longe atrás: o dobro
    assert 0 < out[3, 0] < w0 and out[3, 1] == out[3, 2] == 0      # à frente: menos e sem giro
    far_R = out[2, 3]
    assert far_R == pytest.approx(R * math.sqrt((V + w0) / (V + 2 * w0)), rel=1e-4)   # contração


def test_takeoff_with_slipstream_runs(manager):
    ac = conventional()
    r0 = manager.run("mission", ac, {"mode": "só decolagem"})
    r1 = manager.run("mission", with_slip(ac), {"mode": "só decolagem"})
    assert np.isfinite(r1.summary["n_saiu_do_chao"]) and r1.summary["n_saiu_do_chao"] != r0.summary["n_saiu_do_chao"]
    assert "esteira" in r1.summary["modificadores"]

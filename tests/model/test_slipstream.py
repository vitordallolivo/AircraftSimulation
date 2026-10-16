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


def test_panel_states_show_the_slipstream(backend):
    """estado por faixa (aerosim_panel_states): sem tração igual à aerodinâmica de sempre; com a esteira, faixas no tubo
    veem mais velocidade, e a soma das sustentações das faixas bate com o C_L do avião (sem fuselagem)"""
    ac = with_slip(twin_boom())
    with backend.session_for(build_model(ac)) as s:
        P0 = s.panel_states(10.0, A, 0.0, [0.0, 0.0], [0.0, 0.0])
        P1 = s.panel_states(10.0, A, 0.0, [25.0, 25.0], [1.0, 1.0])
        c1 = s.aero_coeffs_thrust(10.0, A, 0.0, [25.0, 25.0], [1.0, 1.0])
    ok = P0["group"] >= 0
    assert np.allclose(P0["V"][ok], 10.0 * np.ones(ok.sum()), rtol=0.05)      # só ω×r = 0: quase V∞ no plano
    assert P1["V"].max() > 12.0
    wing = P1["group"] == 0
    assert P1["L"][wing].sum() > P0["L"][wing].sum()
    qS = 0.5 * ac.environment.rho * 100.0 * build_model(ac).S
    assert P1["L"].sum() == pytest.approx(c1["CL"] * qS, rel=0.05)


def test_span_load_tool(tmp_path):
    import subprocess
    import sys
    import os
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    out = tmp_path / "c.csv"
    r = subprocess.run([sys.executable, os.path.join(root, "tools", "span_load.py"),
                        os.path.join(root, "data", "aircraft", "Bimotor_convencional_tubo_cauda_em_V.json"),
                        "--com", "esteira.disco", "--csv", str(out), "--png", str(tmp_path / "c.png")],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "sustentação =" in r.stdout and "rpm" in r.stdout and out.read_text().count("\n") > 20

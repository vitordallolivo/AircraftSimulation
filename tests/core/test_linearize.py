"""Núcleo: coeficientes com rotação/ponto de referência e modelo linear (aerosim_linearize)."""
import math

import numpy as np
import pytest

from aerosim.model.compile import compile_aircraft
from aerosim.model.templates import conventional


@pytest.fixture(scope="module")
def sess(backend):
    s = backend.open_session()
    s.configure(compile_aircraft(conventional()))
    yield s
    s.close()


def test_coeffs_ex_matches_plain_at_cg(sess):
    a = sess.aero_coeffs(15, 0.05, 0.02, de=0.03)
    b = sess.aero_coeffs_ex(15, 0.05, 0.02, de=0.03)
    for k in ("CL", "CD", "CY", "Cl", "Cm", "Cn"):
        assert a[k] == pytest.approx(b[k], abs=1e-12)


def test_moment_transfer(sess):
    cg = sess.mass_props()["cg"]
    c = 0.4
    a = sess.aero_coeffs_ex(15, 0.05, ref=[cg[0], 0, cg[2]])
    b = sess.aero_coeffs_ex(15, 0.05, ref=[cg[0] - 0.1, 0, cg[2]])
    # C_m' = C_m + C_N (x_P − x_P')/c
    assert b["Cm"] == pytest.approx(a["Cm"] + a["CN"] * 0.1 / c, abs=1e-9)


def test_damping_signs(sess):
    V, b, c = 15.0, 2.5, 0.4
    h = 0.01
    d = lambda **kw: sess.aero_coeffs_ex(V, 0.03, **kw)
    Clp = (d(p=h * 2 * V / b)["Cl"] - d(p=-h * 2 * V / b)["Cl"]) / (2 * h)
    Cmq = (d(q=h * 2 * V / c)["Cm"] - d(q=-h * 2 * V / c)["Cm"]) / (2 * h)
    Cnr = (d(r=h * 2 * V / b)["Cn"] - d(r=-h * 2 * V / b)["Cn"]) / (2 * h)
    assert Clp < -0.3 and Cmq < -3 and Cnr < 0


def test_linear_model(sess):
    lm = sess.linearize(15.0)
    assert lm["ok"]
    A = lm["A"]
    assert A.shape == (8, 8) and lm["B"].shape == (8, 4)
    # cinemática exata: dθ/dt = q
    assert A[7, 4] == pytest.approx(1.0, abs=1e-6)
    # todos os modos longitudinais estáveis
    lon = np.linalg.eigvals(A[np.ix_([0, 2, 4, 7], [0, 2, 4, 7])])
    assert (lon.real < 0).all()
    # trimagem igual à do equilíbrio nivelado
    tp = sess.trim(0, 15.0)
    assert lm["alpha"] == pytest.approx(tp["alpha"], abs=2e-3)
    assert lm["de"] == pytest.approx(tp["de"], abs=5e-3)

"""Carga ao longo das superfícies num ponto de operação (aerosim/aero/span_loads.py): conta do núcleo, refino só
de resolução, rotação imposta ou de equilíbrio, esteira e simetria, vetores para o 3D."""
import math

import numpy as np
import pytest

from aerosim.aero.span_loads import LoadCase, compute, refine_surface
from aerosim.model import modifiers as mods
from aerosim.model.templates import conventional, twin_boom
from aerosim.model.universal import build_model


def slip(ac):
    ac = ac.copy()
    ac.modifiers = ac.modifiers + [mods.Modifier("esteira.disco")]
    return ac


def test_refinement_keeps_the_total(backend):
    """sem motor e sem esteira, refinar só muda a resolução: a sustentação total é a mesma"""
    ac = conventional()
    case = LoadCase(V=12, alpha=3, rpm=1e-9)                  # rotação desprezível: sem tração
    fine = compute(backend, ac, case)
    coarse = compute(backend, ac, LoadCase(V=12, alpha=3, rpm=1e-9, refine=False))
    for s in fine.surfaces:
        c = coarse.surface(s.name)
        assert len(s.s) > len(c.s)
        assert s.lift == pytest.approx(c.lift, rel=0.01, abs=1e-3)
    assert fine.props[0].T < 1e-6


def test_geometry_unchanged_by_refine():
    ac = conventional()
    for i, s in enumerate(ac.surfaces):
        r = refine_surface(ac, i, 12).surfaces[i]
        assert r.area == pytest.approx(s.area, rel=1e-9) and r.span == pytest.approx(s.span, rel=1e-12)


def test_imposed_rpm_and_equilibrium(backend):
    ac = conventional()
    lo = compute(backend, ac, LoadCase(V=8, rpm=4000, refine=False)).props[0]
    hi = compute(backend, ac, LoadCase(V=8, rpm=7000, refine=False)).props[0]
    eq = compute(backend, ac, LoadCase(V=8, throttle=1.0, refine=False)).props[0]
    assert lo.rpm == pytest.approx(4000) and hi.rpm == pytest.approx(7000) and hi.T > lo.T > 0
    assert 3000 < eq.rpm < 9000 and eq.T > 0
    with pytest.raises(ValueError):
        compute(backend, twin_boom(), LoadCase(rpm=[5000, 6000, 7000], refine=False))


def test_slipstream_peaks_behind_the_prop(backend):
    ac = twin_boom()
    off = compute(backend, ac, LoadCase(V=8, alpha=2, rpm=7000))
    on = compute(backend, slip(ac), LoadCase(V=8, alpha=2, rpm=7000))
    w0, w1 = off.by_role("wing")[0], on.by_role("wing")[0]
    assert w1.lift > w0.lift * 1.05
    y_prop = abs(ac.propulsion[0].y)
    R = ac.propulsion[0].propeller.D / 2
    inside = np.abs(np.abs(w1.s) - y_prop) < R
    assert np.max(w1.V[inside]) > 1.3 * 8 and np.allclose(w1.V[np.abs(w1.s) < 0.1], w0.V[np.abs(w0.s) < 0.1])
    # bimotor simétrico com sentidos opostos: a carga é espelhada
    assert np.allclose(w1.L, w1.L[::-1], rtol=1e-9, atol=1e-9)
    assert "esteira" in " ".join(on.modifiers)


def test_default_is_level_flight_at_12(backend):
    """sem α: trimagem do voo nivelado a 12 m/s; as superfícies sustentam o peso (menos a tração na vertical)"""
    ac = conventional()
    r = compute(backend, ac)
    assert r.case.V == 12.0 and r.trim is not None and r.trim["ok"]
    assert r.lift == pytest.approx(r.weight, rel=0.1)
    r3 = compute(backend, ac, LoadCase(V=16))
    assert r3.alpha < r.alpha                           # mais rápido, menos α para o mesmo peso
    r2 = compute(backend, ac, LoadCase(V=16, n=2))
    assert r2.trim["ok"] and r2.lift == pytest.approx(2 * r3.lift, rel=0.1) and r2.alpha > r3.alpha
    stall = compute(backend, ac, LoadCase(V=12, n=2, refine=False))    # a 12 m/s não segura n = 2: avisa
    assert not stall.trim["ok"] and stall.notes


def test_vectors_for_3d(backend):
    r = compute(backend, slip(conventional()), LoadCase(V=8, alpha=2, rpm=6000))
    w = r.by_role("wing")[0]
    n = len(w.s)
    assert w.points.shape == w.force.shape == w.velocity.shape == w.induced.shape == (n, 3)
    mag = np.linalg.norm(w.force, axis=1)
    assert np.allclose(mag, np.hypot(w.L, w.D) * w.width, rtol=1e-9)
    assert np.allclose(np.linalg.norm(w.velocity[:, [0, 2]] @ np.eye(2), axis=1) > 0, True)
    assert np.abs(w.induced).max() > 1.0 and np.allclose(w.span_dir[:, 1], 1.0, atol=0.05)
    t = r.tubes(backend)
    assert len(t) == 1 and t[0]["radius"][-1] < t[0]["radius"][0] and t[0]["centers"].shape == (40, 3)

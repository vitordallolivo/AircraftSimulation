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
    """sem motor e sem esteira, refinar só muda a resolução: a sustentação total é a mesma (faixas: igual; linha
    sustentadora: converge com a discretização, então perto)"""
    ac = conventional()
    case = LoadCase(V=12, alpha=3, rpm=1e-9, method="faixas")  # rotação desprezível: sem tração
    fine = compute(backend, ac, case)
    coarse = compute(backend, ac, LoadCase(V=12, alpha=3, rpm=1e-9, refine=False, method="faixas"))
    llt_f = compute(backend, ac, LoadCase(V=12, alpha=3, rpm=1e-9))
    import aerosim.aero.span_loads as sl
    keep = sl.MAX_PER_SIDE
    try:
        sl.MAX_PER_SIDE = 16
        llt_m = compute(backend, ac, LoadCase(V=12, alpha=3, rpm=1e-9))
    finally:
        sl.MAX_PER_SIDE = keep
    # linha sustentadora: converge com faixas mais finas na ponta (34 → 44 faixas na asa: < 0,5 %)
    assert llt_f.by_role("wing")[0].lift == pytest.approx(llt_m.by_role("wing")[0].lift, rel=0.005)
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
    assert np.max(w1.V[inside]) > 1.3 * 8 and np.allclose(w1.V[np.abs(w1.s) < 0.1], w0.V[np.abs(w0.s) < 0.1], rtol=1e-3)
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


def test_without_props(backend):
    """props=False: as superfícies não veem a hélice (mesmo com a esteira ligada no avião)"""
    ac = slip(conventional())
    on = compute(backend, ac, LoadCase(V=12))
    off = compute(backend, ac, LoadCase(V=12, props=False))
    base = compute(backend, conventional(), LoadCase(V=12))
    assert on.lift > off.lift and off.lift == pytest.approx(base.lift, rel=1e-9) and off.notes
    w = on.by_role("wing")[0]
    assert w.wash.max() > 0 and w.wash.min() == 0              # imersão: parte da asa no tubo, parte fora


def test_lifting_line_depends_on_aspect_ratio(backend):
    """linha sustentadora (core/src/loads/llt.zig): ponta descarregada, raiz sem pico, e a ponta mais descarregada
    (relativa à raiz) num alongamento menor; faixas: carga plana. Total perto do peso (a trimagem é a do núcleo)"""
    import copy
    ac = conventional()
    flat = compute(backend, ac, LoadCase(props=False, method="faixas")).by_role("wing")[0]
    assert np.ptp(flat.L) < 1e-6 * abs(flat.L).max()
    r = compute(backend, ac, LoadCase(props=False))
    w = r.by_role("wing")[0]
    mid = len(w.L) // 2
    assert w.L[0] < 0.75 * w.L[mid] and w.L[-1] < 0.75 * w.L[mid]
    assert np.allclose(w.L, w.L[::-1], rtol=1e-6)                       # simétrica
    # a raiz não entra: na quina do diedro a linha sustentadora de Phillips e Snyder é singular (o pico cresce com o
    # refino: +1,4 %, +2,6 %, +3,3 % com 8, 16 e 24 faixas por lado); a correção é a de Reid e Hunsaker (2020),
    # ainda não feita (T55). O total converge (ver test_lifting_line_total_converges)
    total = sum(s.lift for s in r.surfaces)
    assert abs(total - r.weight) < 0.06 * r.weight
    # alongamento menor: mesma área, envergadura menor
    short = copy.deepcopy(ac)
    sw = short.surfaces[0]
    for sec in sw.sections:
        sec.chord *= 1.5
        sec.y /= 1.5
    ws = compute(backend, short, LoadCase(props=False, alpha=r.alpha, de=r.de)).by_role("wing")[0]
    wl = compute(backend, ac, LoadCase(props=False, alpha=r.alpha, de=r.de)).by_role("wing")[0]
    assert ws.L[0] / ws.L.max() < wl.L[0] / wl.L.max() + 0.02
    assert ws.lift < wl.lift                                             # menos alongamento, menos C_L


def test_swept_winglet_unloads_at_its_tip(backend):
    """winglet enflechado da asa voadora: a carga é máxima perto da junção e cai até a ponta (antes da correção dos
    nós no 1/4 de corda ela crescia para a ponta, 45 N/m, e explodia com β: 697 N/m)"""
    from aerosim.model.templates import flying_wing
    for beta in (0.0, 5.0):
        r = compute(backend, flying_wing(), LoadCase(V=12, beta=beta))
        w = r.surface("winglet dir")
        i = np.argsort(w.s)
        L = w.L[i]
        assert np.all(np.isfinite(L))
        assert L[-1] < 0.5 * L.max()                       # descarrega na ponta
        assert np.argmax(L) < 0.6 * len(L)                 # o máximo fica na metade de baixo
        assert L.max() < r.surface("asa").L.max()          # nunca mais carregado que a asa


def test_sweep_lowers_lift_like_the_vlm(backend):
    """mesma asa plana (AR 5, afilamento 0,5, perfil simétrico) reta e com 25° no 1/4 de corda, a 5°: no VLM do
    AeroSandbox (12 × 40 painéis por lado) o enflechamento tira 4,9 % da sustentação (20,81 → 19,79 N); a linha
    sustentadora tem de tirar também (sem os segmentos ligados da outra meia asa ela somava 20 %)"""
    from aerosim.model.airfoil import Airfoil, naca4
    from aerosim.model.aircraft import WingSection
    from aerosim.model.templates import flying_wing

    def wing(x_tip):
        ac = flying_wing()
        ac.surfaces = [s for s in ac.surfaces if s.role == "wing"]
        ac.propulsion = []
        w = ac.surfaces[0]
        w.incidence, w.dihedral, w.controls = 0.0, 0.0, []
        w.sections = [WingSection(0.0, 0.4, 0.0, 0.0), WingSection(1.0, 0.2, x_tip, 0.0)]
        w.airfoil = Airfoil(name="NACA 0012", coords=naca4("0012").tolist(), cl_alpha=2 * math.pi, cl_max=1.4,
                            cd0=0.008, cm_ac=0.0)
        return ac

    case = LoadCase(V=12, alpha=5, de=0, props=False)
    straight = compute(backend, wing(0.05), case).lift
    swept = compute(backend, wing(0.05 + math.tan(math.radians(25))), case).lift
    assert swept < 0.99 * straight


def test_lifting_line_total_converges(backend):
    """sustentação da asa da convencional a α = 11° com 8, 16 e 24 faixas por lado: o total converge (118,1 →
    117,1 → 116,9 N); diferença entre as duas últimas malhas < 0,5 %"""
    import aerosim.aero.span_loads as sl
    keep = sl.MAX_PER_SIDE
    out = []
    try:
        for n in (8, 16, 24):
            sl.MAX_PER_SIDE = n
            out.append(compute(backend, conventional(), LoadCase(props=False, alpha=11.0, de=0)).by_role("wing")[0].lift)
    finally:
        sl.MAX_PER_SIDE = keep
    assert abs(out[2] - out[1]) < 0.005 * out[2]
    assert abs(out[2] - out[1]) < abs(out[1] - out[0])

"""Subaba Asas (Aerodinâmica): só as superfícies escolhidas, sem trimar, sem fuselagem e sem hélice."""
import copy

import numpy as np
import pytest

from aerosim.manager.simulations.wings import SPRINT, wings_only
from aerosim.model.templates import conventional, empty

NL = "linha sustentadora não linear (estol por perfil)"
LIN = "linha sustentadora (Phillips e Snyder)"
FAST = {"use_lltdrek": False, "use_zig": False}        # sem a comparação das polares (a não ser onde se testa)


def _cl_at(r, key, alpha):
    s = r.series[key]
    return float(np.interp(alpha, s["alpha"], s["CL"]))


@pytest.fixture(scope="module")
def single(manager):
    return manager.run("wings", conventional(), {**FAST, "a0": 0.0, "a1": 22.0, "da": 2.0, "compare": LIN,
                                                 "use_zig": True})


def test_wings_only_does_not_touch_the_aircraft():
    ac = conventional()
    before = [(s.enabled, len(s.devices)) for s in ac.surfaces], [u.enabled for u in ac.propulsion]
    w = wings_only(ac, [0], endplate=1.0)
    assert [(s.enabled, len(s.devices)) for s in ac.surfaces] == before[0]
    assert [u.enabled for u in ac.propulsion] == before[1]
    assert [s.enabled for s in w.surfaces] == [True, False, False]
    assert len(w.surfaces[0].devices) == len(ac.surfaces[0].devices) + 1
    assert not any(u.enabled for u in w.propulsion)
    assert ac.fuselage.enabled and not w.fuselage.enabled


def test_single_wing_linear_range_and_stall(single):
    # antes do estol a não linear segue a linear; depois o C_L dela satura e a linear continua subindo
    nl, lin = f"conjunto_{NL}", f"conjunto_{LIN}"
    assert _cl_at(single, nl, 4.0) == pytest.approx(_cl_at(single, lin, 4.0), rel=0.03)
    CLmax, a_max = single.summary[f"[{NL}] C_L máximo, α dele (°)"]
    assert a_max < 22.0
    assert CLmax < _cl_at(single, lin, 22.0)
    assert f"[{NL}] onde o estol começa" in single.summary


def test_single_wing_views_and_method_comparison(single):
    # a vista 3D e a de cima mostram o LoadResult do α da carga; as polares dos solvers marcados entram
    for key in ("v3d", "top"):
        assert single.series[key]["_result"].distributions
        assert not single.series[key]["_aircraft"].fuselage.enabled
    assert single.series["top"]["_camera"]["elevation"] == 90
    assert "polar_modelo interno" in single.series
    assert np.isfinite(single.summary["[modelo interno] CLmax"])


def test_core_sweep_matches_one_compute_per_alpha(backend):
    # a varredura do núcleo (core/src/loads/sweep.zig) dá o mesmo que o caminho padrão da interface
    from aerosim.aero import load_method
    from aerosim.interfaces.loads import ILoadMethod
    from aerosim.model.universal import build_model
    ac = wings_only(conventional(), [0, 1])
    model = build_model(ac)
    method = load_method(backend, "llt_nl")
    alphas = np.array([0.0, 8.0, 18.0])
    fast = method.sweep(model, 12.0, alphas, ac.environment.rho, ["asa", "EH"])
    slow = ILoadMethod.sweep(method, model, 12.0, alphas, ac.environment.rho, ["asa", "EH"])
    assert np.allclose(fast.owner_lift, slow.owner_lift, rtol=1e-12, atol=1e-9)
    assert np.allclose(fast.owner_area, slow.owner_area) and np.allclose(fast.owner_chord, slow.owner_chord)
    assert fast.section_cl.shape == slow.section_cl.shape


def test_sprint_wings_without_aircraft(manager):
    # as asas guardadas na sprint rodam sem avião na Montagem (vazio, sem massa), na posição pedida
    from aerosim.design.project import DesignProject
    project = DesignProject()
    project.keep_wing()
    project.keep_wing()
    manager.shared["sprint"] = project
    try:
        names = [w.name for w in project.wings]
        r = manager.run("wings", empty(), {**FAST, "source": SPRINT, "sprint_0": True, "sprint_1": True,
                                           "h_1": 0.4, "a0": 0.0, "a1": 6.0, "da": 3.0, "alpha_load": 3.0})
    finally:
        manager.shared.pop("sprint", None)
    assert all(f"superficie_{n} · {NL}" in r.series for n in names)
    assert not any(c.status == "falha" for c in r.checks)
    heights = sorted(-s.z for s in r.series["v3d"]["_aircraft"].surfaces)
    assert heights == pytest.approx([0.0, 0.4])


def test_tandem_total_is_area_weighted_sum(manager):
    ac = conventional()
    r = manager.run("wings", ac, {**FAST, "a0": 0.0, "a1": 8.0, "da": 4.0, "surf_1": True})
    S = {s.name: s.area for s in ac.surfaces}
    total = r.series[f"conjunto_{NL}"]["CL"]
    parts = sum(r.series[f"superficie_{n} · {NL}"]["CL"] * S[n] for n in ("asa", "EH"))
    assert np.allclose(total, parts / (S["asa"] + S["EH"]))
    assert r.summary["área de referência (soma das horizontais, m²)"] == pytest.approx(S["asa"] + S["EH"])


def test_biplane_wings_lift_less_than_alone(manager):
    # interferência do biplano: o par sustenta menos que uma asa sozinha no mesmo α, e a de baixo é a que mais perde
    # (a de cima ganha velocidade do vórtice preso da de baixo); Munk, "General biplane theory", NACA Report 151, 1923
    # — a conferir no PDF
    ac = conventional()
    upper = copy.deepcopy(ac.surfaces[0])
    upper.name, upper.z = "asa de cima", ac.surfaces[0].z - 0.3
    ac.surfaces.append(upper)
    p = {**FAST, "a0": 6.0, "a1": 6.0, "da": 1.0, "alpha_load": 6.0}
    alone = manager.run("wings", ac, {**p, "surf_0": False}).series[f"superficie_asa de cima · {NL}"]["CL"][0]
    both = manager.run("wings", ac, p).series          # as duas têm papel "wing": entram por padrão
    lower, upper = (both[f"superficie_{n} · {NL}"]["CL"][0] for n in ("asa", "asa de cima"))
    assert lower < upper
    assert both[f"conjunto_{NL}"]["CL"][0] < alone


def test_endplates_raise_lift_slope(manager):
    # a chapa de ponta aumenta o alongamento efetivo e o C_Lα (Hoerner, "Fluid-Dynamic Lift", 1985 — a conferir no PDF)
    p = {**FAST, "a0": 6.0, "a1": 6.0, "da": 1.0, "alpha_load": 6.0}
    without = manager.run("wings", conventional(), p).series[f"conjunto_{NL}"]["CL"][0]
    with_plates = manager.run("wings", conventional(), {**p, "endplate": 1.0})
    assert with_plates.series[f"conjunto_{NL}"]["CL"][0] > without
    assert not any("placa" in k for k in with_plates.series)


def test_no_surface_chosen_is_a_failure(manager):
    r = manager.run("wings", conventional(), {**FAST, "surf_0": False})
    assert any(c.status == "falha" for c in r.checks)


def test_whole_aircraft_replaces_the_old_subtab(manager):
    # com o avião aberto pronto, a Asas roda também a análise do avião completo (a antiga subaba Avião montado): as
    # curvas do núcleo com profundor e derrapagem, os diagnósticos dele e a polar que fica para o Desempenho
    manager.shared.pop("aero_polar", None)
    r = manager.run("wings", conventional(), {**FAST, "use_zig": True, "a0": -4.0, "a1": 16.0, "da": 2.0})
    assert "paL_C_L total (δe = 0)" in r.series and "full_polar_modelo interno" in r.series
    assert any(k.startswith("avião completo · ") for k in r.summary)
    assert any(c.item == "estabilidade direcional C_nβ" for c in r.checks)
    assert "aero_polar" in manager.shared
    # desligada, a parte do avião completo não roda e o resto fica igual
    off = manager.run("wings", conventional(), {**FAST, "whole": False, "a0": 0.0, "a1": 4.0, "da": 2.0})
    assert not any(k.startswith("paL_") for k in off.series)

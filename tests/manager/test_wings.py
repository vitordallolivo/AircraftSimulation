"""Subaba Asas (Aerodinâmica): só as superfícies escolhidas, sem trimar, sem fuselagem e sem hélice."""
import copy

import numpy as np
import pytest

from aerosim.manager.simulations.wings import wings_only
from aerosim.model.templates import conventional

NL = "linha sustentadora não linear (estol por perfil)"
LIN = "linha sustentadora (Phillips e Snyder)"


def _cl_at(r, key, alpha):
    s = r.series[key]
    return float(np.interp(alpha, s["alpha"], s["CL"]))


@pytest.fixture(scope="module")
def single(manager):
    return manager.run("wings", conventional(), {"a0": 0.0, "a1": 22.0, "da": 2.0, "compare": LIN})


def test_wings_only_does_not_touch_the_aircraft():
    ac = conventional()
    before = [(s.enabled, len(s.devices)) for s in ac.surfaces], [u.enabled for u in ac.propulsion]
    w = wings_only(ac, [0], endplate=1.0)
    assert [(s.enabled, len(s.devices)) for s in ac.surfaces] == before[0]
    assert [u.enabled for u in ac.propulsion] == before[1]
    assert [s.enabled for s in w.surfaces] == [True, False, False]
    assert len(w.surfaces[0].devices) == len(ac.surfaces[0].devices) + 1
    assert not any(u.enabled for u in w.propulsion)


def test_single_wing_linear_range_and_stall(single):
    # antes do estol a não linear segue a linear; depois o C_L dela satura e a linear continua subindo
    nl, lin = f"conjunto_{NL}", f"conjunto_{LIN}"
    assert _cl_at(single, nl, 4.0) == pytest.approx(_cl_at(single, lin, 4.0), rel=0.03)
    CLmax, a_max = single.summary[f"[{NL}] C_L máximo, α dele (°)"]
    assert a_max < 22.0
    assert CLmax < _cl_at(single, lin, 22.0)
    assert f"[{NL}] onde o estol começa" in single.summary


def test_tandem_total_is_area_weighted_sum(manager):
    ac = conventional()
    r = manager.run("wings", ac, {"a0": 0.0, "a1": 8.0, "da": 4.0, "surf_1": True})
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
    p = {"a0": 6.0, "a1": 6.0, "da": 1.0, "alpha_load": 6.0}
    alone = manager.run("wings", ac, {**p, "surf_0": False}).series[f"superficie_asa de cima · {NL}"]["CL"][0]
    both = manager.run("wings", ac, p).series          # as duas têm papel "wing": entram por padrão
    lower, upper = (both[f"superficie_{n} · {NL}"]["CL"][0] for n in ("asa", "asa de cima"))
    assert lower < upper
    assert both[f"conjunto_{NL}"]["CL"][0] < alone


def test_endplates_raise_lift_slope(manager):
    # a chapa de ponta aumenta o alongamento efetivo e o C_Lα (Hoerner, "Fluid-Dynamic Lift", 1985 — a conferir no PDF)
    p = {"a0": 6.0, "a1": 6.0, "da": 1.0, "alpha_load": 6.0}
    without = manager.run("wings", conventional(), p).series[f"conjunto_{NL}"]["CL"][0]
    with_plates = manager.run("wings", conventional(), {**p, "endplate": 1.0})
    assert with_plates.series[f"conjunto_{NL}"]["CL"][0] > without
    assert not any("placa" in k for k in with_plates.series)


def test_no_surface_chosen_is_a_failure(manager):
    r = manager.run("wings", conventional(), {"surf_0": False})
    assert any(c.status == "falha" for c in r.checks)

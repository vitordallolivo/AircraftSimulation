"""Dimensões a partir do CG de projeto (aerosim/design/dims.py) e entradas medidas do CG (x_TDP, x_TDN, braço da
cauda do CG). Só perfis NACA gerados."""
import math

import pytest

from aerosim.design import airfoils as afm
from aerosim.design import power as pw
from aerosim.design import tail as tl
from aerosim.design import wing as wg
from aerosim.design.dims import design_cg, dimensions
from aerosim.design.spec import Requirements
from aerosim.model.templates import conventional


def _set(**kw):
    w = wg.WingCandidate(wg.WingParams(area=1.0), afm.AirfoilEntry(afm.from_naca("NACA 2412")))
    return tl.SetCandidate(tl.TailParams(**kw), w)


def _val(rows, item):
    return next(r[5] for r in rows if r[1] == item)


def test_sprint_aircraft_measures_from_design_cg():
    ac, asm = pw.assemble(pw.AircraftCandidate(pw.PowerParams(x_tdp=0.08, x_tdn=0.35), _set()), Requirements(mass=8))
    assert ac.design_cg[0] == pytest.approx(asm["x_cg_target"]) and ac.design_cg[1] == 0.0
    rows = dimensions(ac)
    assert _val(rows, "TDP (trem principal)") == pytest.approx(0.08)
    assert _val(rows, "TDN (bequilha)") == pytest.approx(0.35)
    h = _val(rows, "altura do CG ao chão")
    assert h > 0 and _val(rows, "ângulo de tombamento") == pytest.approx(math.degrees(math.atan2(0.08, h)))
    eh = next(r for r in rows if r[1] == "EH: CA")
    assert eh[2] == pytest.approx(-eh[5]) and eh[5] > 0                 # atrás do CG, braço positivo
    motor = next(r for r in rows if r[0] == "motores")
    assert motor[2] > 0                                                  # tratora: à frente do CG


def test_default_gear_follows_the_rule():
    ac, asm = pw.assemble(pw.AircraftCandidate(pw.PowerParams(), _set()), Requirements(mass=8))
    from aerosim.design.spec import DesignRules
    assert _val(dimensions(ac), "TDP (trem principal)") == pytest.approx(DesignRules().main_gear_aft)


@pytest.mark.parametrize("arm", [0.8, 1.1])
def test_tail_arm_measured_from_cg(arm):
    r = tl.analyze(_set(arm=arm, arm_from="CG de projeto"), Requirements())
    assert r["arm_cg"] == pytest.approx(arm, abs=1e-5)
    rows = dimensions(r["set"], cg=(r["x_cg"], 0.0, 0.0))
    assert _val(rows, "EH: CA") == pytest.approx(arm, abs=1e-4)
    r0 = tl.analyze(_set(arm=arm), Requirements())                      # do CA da asa: o braço do CG é outro
    assert r0["info"]["arm"] == pytest.approx(arm) and r0["arm_cg"] != pytest.approx(arm, abs=1e-3)
    assert r["info"]["Sh"] == pytest.approx(r0["info"]["Sh"])           # volume de cauda com o braço dado
    assert 100 * (r["h_n"] - r["h_cg"]) == pytest.approx(12.0)          # margem pedida continua


def test_without_design_cg_uses_current_cg():
    ac = conventional()
    assert ac.design_cg is None
    from aerosim.model.universal import build_model
    assert design_cg(ac)[0] == pytest.approx(float(build_model(ac).mass["cg"][0]))
    ac.design_cg = [0.1, 0.0, 0.0]
    rows = dimensions(ac)
    assert _val(rows, "TDP (trem principal)") == pytest.approx(0.1 - ac.gear.main_x)


def test_set_without_gear_has_no_ground_rows():
    r = tl.analyze(_set(), Requirements())
    rows = dimensions(r["set"], cg=(r["x_cg"], 0.0, 0.0))
    items = [x[1] for x in rows]
    assert "altura do CG ao chão" not in items and not any("ao chão" in i for i in items)
    assert "EH: CA" in items and "bordo de ataque da raiz" in items

"""Etapas da sprint (aerosim/design): perfil → asa → empenagem → motores → avião inteiro."""
import math

import numpy as np
import pytest

from aerosim.design import airfoils as afm
from aerosim.design import power as pw
from aerosim.design import tail as tl
from aerosim.design import wing as wg
from aerosim.design.project import DesignProject, next_name
from aerosim.design.spec import Requirements
from aerosim.model.airfoil import helmbold


def _wing(**kw):
    p = wg.WingParams(**kw)
    return wg.WingCandidate(p, afm.AirfoilEntry(afm.from_naca("NACA 2412")))


def test_wing_geometry_matches_params():
    for rf, lam in ((0.0, 0.5), (0.4, 0.6), (1.0, 1.0)):
        p = wg.WingParams(span=2.2, area=0.8, rect_frac=rf, taper=lam)
        w = wg.build_wing(p, afm.from_naca("NACA 2412"))
        assert w.area == pytest.approx(0.8) and w.span == pytest.approx(2.2)


def test_lifting_line_rectangular_vs_helmbold_and_stall_at_root():
    r = wg.analyze(_wing(span=2.4, area=0.72, rect_frac=1.0, twist=0.0), Requirements())
    a1 = r["airfoil"].cl_alpha
    assert r["CLa"] == pytest.approx(helmbold(a1, 8.0), rel=0.03)
    assert r["eta_stall"] < 0.1                     # retangular estola na raiz
    assert 0.9 < r["e"] <= 1.0


def test_taper_moves_stall_out_and_washout_brings_it_back():
    base = dict(span=2.4, area=0.72, rect_frac=0.0, taper=0.35)
    out = wg.analyze(_wing(twist=0.0, **base), Requirements())["eta_stall"]
    back = wg.analyze(_wing(twist=-4.0, **base), Requirements())["eta_stall"]
    assert out > 0.5 and back < out


def test_near_elliptic_planform_has_e_close_to_one():
    r = wg.analyze(_wing(span=2.4, area=0.72, rect_frac=0.0, taper=0.4, twist=0.0), Requirements())
    assert r["e"] > 0.97


def test_incidence_puts_fuselage_at_cruise_angle():
    req = Requirements()
    r = wg.analyze(_wing(area=1.0, alpha_cruise=2.0), req)
    assert r["incidence"] == pytest.approx(r["alpha_cruise_w"] - 2.0)
    assert r["CL_cruise"] == pytest.approx(req.weight / (req.q() * r["S"]))


def test_tail_sizing_by_volume_and_cg_range():
    req = Requirements()
    sc = tl.SetCandidate(tl.TailParams(VH=0.5, VV=0.04, arm=1.0), _wing(area=1.0))
    r = tl.analyze(sc, req)
    i = r["info"]
    assert i["Sh"] == pytest.approx(0.5 * i["S"] * i["c"] / 1.0)
    assert i["Sv"] == pytest.approx(0.04 * i["S"] * i["b"] / 1.0)
    assert r["h_n"] > r["h_ac"]                                  # a cauda leva o ponto neutro para trás
    assert r["h_fwd"] < r["h_cg"] < r["h_aft"] < r["h_n"]
    assert r["h_n"] - r["h_cg"] == pytest.approx(0.12)
    assert abs(r["de_cruise"]) < 1e-6                            # incidência da EH equilibra o cruzeiro
    assert r["de_CLmax"] < 0                                     # cabrar para o C_L,max
    ac = r["set"]                                                # a cauda na ponta do tubo
    eh = ac.surfaces[1]
    assert eh.x - eh.sections[0].chord == pytest.approx(ac.boom.x_end)


def test_v_tail_keeps_total_area_and_flying_wing_has_no_tail():
    req = Requirements()
    v = tl.analyze(tl.SetCandidate(tl.TailParams(layout="em V"), _wing(area=1.0)), req)
    assert v["set"].surfaces[1].area == pytest.approx(v["info"]["Sh"] + v["info"]["Sv"])
    assert v["set"].surfaces[1].controls[0].kind == "ruddervator"
    f = tl.analyze(tl.SetCandidate(tl.TailParams(layout="sem cauda"), _wing(area=1.0)), req)
    assert len(f["set"].surfaces) == 1 and f["set"].surfaces[0].controls[0].kind == "elevon"


def test_assembly_puts_cg_on_target_and_flies_in_the_core(manager, tmp_path):
    from aerosim.data import load_aircraft, save_aircraft
    from aerosim.model.massprops import dry_mass
    req = Requirements()
    cand = pw.AircraftCandidate(pw.PowerParams(), tl.SetCandidate(tl.TailParams(), _wing(area=1.0)))
    ac, asm = pw.assemble(cand, req)
    dm = dry_mass(ac)
    assert asm["battery_fits"] and dm["cg"][0] == pytest.approx(asm["x_cg_target"], abs=1e-6)
    assert dm["m"] == pytest.approx(asm["mass"]) and asm["sm"] == pytest.approx(12.0)
    assert ac.gear.main_x < asm["x_cg_target"] < ac.gear.steer_x       # triciclo: principal atrás do CG
    f = str(tmp_path / "a.json")
    save_aircraft(ac, f)
    ac2 = load_aircraft(f)
    pf = pw.performance(ac2, asm, req, manager.backend)
    assert pf["T0"] > 0 and pf["s_to"] < req.takeoff_run and math.isfinite(pf["mtow_runway"])
    assert pf["mtow_runway"] > asm["mass"]
    assert manager.run("performance", ac2, {}).status in ("ok", "COMPLETED")


def test_python_thrust_matches_core(manager):
    cand = pw.AircraftCandidate(pw.PowerParams(), tl.SetCandidate(tl.TailParams(), _wing(area=1.0)))
    ac, _ = pw.assemble(cand, Requirements())
    V = np.array([0.0, 8.0, 16.0])
    assert pw.thrust_of(ac, V, 1.15, None) == pytest.approx(pw.thrust_of(ac, V, 1.15, manager.backend), rel=0.03)


def test_pusher_with_boom_is_flagged():
    cand = pw.AircraftCandidate(pw.PowerParams(layout="propulsora atrás da asa"),
                                tl.SetCandidate(tl.TailParams(), _wing(area=1.0)))
    _, asm = pw.assemble(cand, Requirements())
    assert asm["boom_hits_prop"]


def test_xflr5_polar_file(tmp_path):
    txt = """xflr5 v6.47

 Calculated polar for: NACA 2412

 1 1 Reynolds number fixed          Mach number fixed

 xtrf =   1.000 (top)        1.000 (bottom)
 Mach =   0.000     Re =     0.300 e 6     Ncrit =   9.000

  alpha      CL        CD       CDp       Cm    Top Xtr  Bot Xtr   Cpmin    Chinge    XCp
 -------- -------- --------- --------- -------- ------- ------- -------- --------- ---------
  -4.000  -0.2100   0.01000   0.00400  -0.0500  0.9000  0.1000  -1.0000   0.0000   0.2000
   0.000   0.2300   0.00800   0.00300  -0.0520  0.7000  0.9000  -1.0000   0.0000   0.2000
   4.000   0.6700   0.00900   0.00400  -0.0540  0.5000  1.0000  -1.0000   0.0000   0.2000
   8.000   1.0500   0.01300   0.00700  -0.0500  0.2000  1.0000  -1.0000   0.0000   0.2000
  12.000   1.3000   0.02200   0.01500  -0.0400  0.1000  1.0000  -1.0000   0.0000   0.2000
  14.000   1.2500   0.04000   0.03000  -0.0400  0.1000  1.0000  -1.0000   0.0000   0.2000
"""
    f = tmp_path / "naca2412_T1_Re0.300.txt"
    f.write_text(txt)
    p = afm.read_polar_file(str(f))
    assert p["Re"] == pytest.approx(3e5) and list(p["alpha"]) == [-4, 0, 4, 8, 12, 14]
    e = afm.AirfoilEntry(afm.Airfoil(name="só parâmetros"), source="arquivo", polar_file=str(f))
    assert afm.kind(e.airfoil) == "parâmetros" and "arquivo" in afm.sources(e) and "neuralfoil" not in afm.sources(e)
    m = afm.metrics(afm.polar(e, 3e5, np.arange(-4, 14.01, 0.5)))
    assert m["cl_max"] == pytest.approx(1.3) and m["alpha0"] == pytest.approx(-2.1, abs=0.2)
    assert not m["cd_const"] and m["cd_min"] == pytest.approx(0.008, abs=1e-3)


def test_project_roundtrip_and_names(tmp_path):
    p = DesignProject()
    p.wing_draft.area = 1.0
    w = p.keep_wing()
    assert w.name == "asa 1" and p.wing_draft.name == "asa 2"
    p.tail_draft.wing = w.name
    s = p.keep_set()
    p.power_draft.set = s.name
    p.keep_aircraft()
    f = str(tmp_path / "sprint.json")
    p.save(f)
    q = DesignProject.load(f)
    assert [x.name for x in q.wings] == ["asa 1"] and q.aircraft[0].set.wing.params.area == 1.0
    assert next_name("conjunto 1", ["conjunto 1", "conjunto 2"]) == "conjunto 3"

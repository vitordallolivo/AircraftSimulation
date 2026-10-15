"""Asa por corda e por tabela de N seções (cada uma com o seu perfil). Só perfis NACA gerados."""
import math

import numpy as np
import pytest

from aerosim.design import airfoils as afm
from aerosim.design import store
from aerosim.design import wing as wg
from aerosim.design.project import DesignProject
from aerosim.design.spec import Requirements
from aerosim.model.serialize import to_dict


def _entry(name):
    return afm.entry(afm.from_naca(name))


def _cand(p, root="NACA 2412", others=()):
    return wg.WingCandidate(p, _entry(root), section_airfoils=[_entry(n) for n in others])


def test_sizing_by_chord_matches_sizing_by_area():
    pa = wg.WingParams(span=2.2, area=0.8, taper=0.6, rect_frac=0.4)
    wg.sync(pa)
    pc = wg.WingParams(span=2.2, taper=0.6, rect_frac=0.4, size_by="corda", chord=pa.chord, area=123.0)
    wg.sync(pc)
    assert pc.area == pytest.approx(0.8, rel=1e-5)
    ra, rc = wg.analyze(_cand(pa), Requirements()), wg.analyze(_cand(pc), Requirements())
    for k in ("CLa", "CLmax", "e", "S", "CD_cruise"):
        assert rc[k] == pytest.approx(ra[k], rel=1e-5)


@pytest.mark.parametrize("tip", ["", "NACA 0012"])
def test_table_from_trapezoid_reproduces_it(tip):
    p = wg.WingParams(span=2.4, area=0.9, taper=0.6, rect_frac=0.5, twist=-1.5, sweep=3.0, airfoil="NACA 2412",
                      airfoil_tip=tip)
    tip_e = _entry(tip) if tip else None
    r0 = wg.analyze(wg.WingCandidate(p, _entry("NACA 2412"), airfoil_tip=tip_e), Requirements())
    q = wg.WingParams(**{**to_dict(p), "stations": []})
    q.stations = wg.stations_from_trapezoid(p)
    q.planform = "tabela de seções"
    wg.sync(q)
    assert q.span == pytest.approx(2.4) and q.area == pytest.approx(0.9, rel=1e-3)
    r1 = wg.analyze(_cand(q, others=[tip] if tip else []), Requirements())
    for k in ("CLa", "CL0", "CLmax", "alpha_stall", "e", "CD_cruise"):
        assert r1[k] == pytest.approx(r0[k], rel=2e-3, abs=1e-6), k


def test_n_sections_each_with_its_airfoil():
    S = wg.WingStation
    p = wg.WingParams(planform="tabela de seções", airfoil="NACA 4412", dihedral=0.0, stations=[
        S(0.0, 0.30, "NACA 4412"), S(0.4, 0.30, ""), S(0.8, 0.25, "NACA 2412", 0.02, -1.0),
        S(1.1, 0.15, "NACA 0012", 0.06, -2.0)])
    wg.sync(p)
    assert p.span == pytest.approx(2.2)
    assert p.area == pytest.approx(2 * (0.4 * 0.30 + 0.4 * 0.275 + 0.3 * 0.20))
    cand = _cand(p, "NACA 4412", ["NACA 2412", "NACA 0012"])
    r = wg.analyze(cand, Requirements())
    w = r["surface"]
    assert [s.y for s in w.sections] == [0.0, 0.4, 0.8, 1.1]
    assert [s.airfoil.name if s.airfoil else None for s in w.sections] == [None, None, "NACA 2412", "NACA 0012"]
    props = wg.section_props(w, np.array([0.0, 0.4, 0.8, 1.1]))
    a0 = np.degrees(props["a0"])
    assert a0[0] == pytest.approx(a0[1]) and a0[0] < a0[2] < a0[3] <= 1e-9      # arqueamento cai para a ponta
    assert np.degrees(wg.section_props(w, 0.95)["a0"]) == pytest.approx(0.5 * (a0[2] + a0[3]))
    assert math.isfinite(r["CLmax"]) and r["S"] == pytest.approx(p.area, rel=1e-3) and 0.5 < r["e"] <= 1.0
    assert r["CDp"].min() > 0


def test_project_copies_section_airfoils_and_round_trips(tmp_path):
    d = DesignProject()
    d.airfoils = [_entry("NACA 4412"), _entry("NACA 2412"), _entry("NACA 0012")]
    S = wg.WingStation
    d.wing_draft.planform = "tabela de seções"
    d.wing_draft.stations = [S(0.0, 0.3, "NACA 4412"), S(0.6, 0.25, "NACA 2412"), S(1.0, 0.15, "NACA 0012")]
    c = d.keep_wing()
    assert c.airfoil.name == "NACA 4412" and [e.name for e in c.section_airfoils] == ["NACA 2412", "NACA 0012"]
    d.airfoils = d.airfoils[:1]                          # apagar o perfil depois não muda a asa guardada
    assert len(c.section_airfoils) == 2
    store.save(d, str(tmp_path))
    assert to_dict(store.load(str(tmp_path))) == to_dict(d)

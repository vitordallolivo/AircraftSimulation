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
    q = wg.WingParams(**{**to_dict(p), "partitions": []})
    q.partitions = wg.partitions_from_trapezoid(p)
    q.planform = "tabela de seções"
    wg.sync(q)
    assert q.span == pytest.approx(2.4) and q.area == pytest.approx(0.9, rel=1e-3)
    assert [r.span for r in q.partitions] == pytest.approx([1.2, 1.2])            # a soma é a envergadura total
    r1 = wg.analyze(_cand(q, others=[tip] if tip else []), Requirements())
    for k in ("CLa", "CL0", "CLmax", "alpha_stall", "e", "CD_cruise"):
        assert r1[k] == pytest.approx(r0[k], rel=2e-3, abs=1e-6), k


def test_straight_wing_is_one_partition():
    p = wg.WingParams(planform="tabela de seções", airfoil="NACA 4412",
                      partitions=[wg.WingPartition(2.2, 0.30, 1.0, "NACA 4412")])
    wg.sync(p)
    assert p.span == pytest.approx(2.2) and p.area == pytest.approx(0.66)
    st = wg.stations(p)
    assert [(q.y, q.chord) for q in st] == [(0.0, 0.30), (1.1, 0.30)]
    r = wg.analyze(_cand(p, "NACA 4412"), Requirements())
    assert r["S"] == pytest.approx(0.66, rel=1e-3) and r["b"] == pytest.approx(2.2)


def test_n_partitions_each_with_its_airfoil_and_chord_step():
    P = wg.WingPartition
    p = wg.WingParams(planform="tabela de seções", airfoil="NACA 4412", dihedral=0.0, partitions=[
        P(0.8, 0.30, 1.0, "NACA 4412"), P(0.8, 0.30, 0.25 / 0.30, "NACA 2412", 0.02, -1.0),
        P(0.6, 0.20, 0.75, "NACA 0012", 0.04, -2.0)])          # degrau de corda na segunda junção (0,25 → 0,20)
    wg.sync(p)
    assert p.span == pytest.approx(2.2)
    assert p.area == pytest.approx(0.8 * 0.30 + 0.8 * 0.275 + 0.6 * 0.175)
    st = wg.stations(p)
    assert [round(q.y, 4) for q in st] == [0.0, 0.4, 0.8, 0.8001, 1.1]           # o degrau num trecho curtinho
    assert [q.airfoil for q in st] == ["NACA 4412", "NACA 4412", "NACA 2412", "NACA 2412", "NACA 0012"]
    assert st[-1].offset == pytest.approx(0.06) and st[-1].twist == -2.0
    cand = _cand(p, "NACA 4412", ["NACA 2412", "NACA 0012"])
    r = wg.analyze(cand, Requirements())
    w = r["surface"]
    names = [s.airfoil.name if s.airfoil else None for s in w.sections]
    assert names == [None, None, "NACA 2412", "NACA 2412", "NACA 0012"]
    a0 = np.degrees(wg.section_props(w, np.array([0.0, 0.4, 0.8, 1.1]))["a0"])
    assert a0[0] == pytest.approx(a0[1]) and a0[1] < a0[2] < a0[3] <= 1e-9       # arqueamento cai para a ponta
    assert np.degrees(wg.section_props(w, 0.6)["a0"]) == pytest.approx(0.5 * (a0[1] + a0[2]))   # passa de um ao outro
    assert math.isfinite(r["CLmax"]) and r["S"] == pytest.approx(p.area, rel=2e-3) and 0.5 < r["e"] <= 1.0
    assert r["CDp"].min() > 0


def test_project_copies_section_airfoils_and_round_trips(tmp_path):
    d = DesignProject()
    d.airfoils = [_entry("NACA 4412"), _entry("NACA 2412"), _entry("NACA 0012")]
    P = wg.WingPartition
    d.wing_draft.planform = "tabela de seções"
    d.wing_draft.partitions = [P(1.2, 0.3, 1.0, "NACA 4412"), P(0.8, 0.3, 0.8, "NACA 2412"),
                               P(0.4, 0.24, 0.6, "NACA 0012")]
    c = d.keep_wing()
    assert c.airfoil.name == "NACA 4412" and [e.name for e in c.section_airfoils] == ["NACA 2412", "NACA 0012"]
    d.airfoils = d.airfoils[:1]                          # apagar o perfil depois não muda a asa guardada
    assert len(c.section_airfoils) == 2
    store.save(d, str(tmp_path))
    assert to_dict(store.load(str(tmp_path))) == to_dict(d)

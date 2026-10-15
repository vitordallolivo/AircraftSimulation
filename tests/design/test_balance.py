"""CG com a carga da Montagem, depois da soltura e acertar o CG de projeto (aerosim/design/balance.py)."""
import numpy as np
import pytest

from aerosim.design import balance as bl
from aerosim.design import checklist as ck
from aerosim.model.aircraft import PointMass
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model


def _ac():
    ac = conventional()
    ac.design_cg = [0.0, 0.0, 0.0]
    ac.mass.items.append(PointMass("bateria", 0.8, 0.0, 0.0, 0.0))
    return ac


def test_full_cg_matches_the_core(backend):
    ac = _ac()
    ac.payload.x, ac.tanks[0].x = 0.12, -0.08
    m, cg = bl.full_cg(ac)
    with backend.session_for(build_model(ac)) as s:
        mp = s.mass_props()
    assert m == pytest.approx(mp["m"]) and np.allclose(cg, mp["cg"], atol=1e-9)
    m2, cg2 = bl.cg_after_drop(ac)
    assert m2 == pytest.approx(m - ac.payload.mass)
    assert cg2[0] < cg[0]                                    # a LAPES à frente saiu: o CG vai para trás


def test_rebalance_brings_cg_back():
    ac = _ac()
    ac.payload.x = 0.06
    ok, msg = bl.rebalance(ac)
    assert ok and bl.full_cg(ac)[1][0] == pytest.approx(0.0, abs=1e-9)
    c = [x for x in ck.define_checks(ac) if x.item == "CG com a carga × CG de projeto"][0]
    assert c.status == ck.OK


def test_rebalance_limited_by_fuselage_says_what_is_missing():
    ac = _ac()
    ac.payload.x = 0.5
    ok, msg = bl.rebalance(ac)
    assert not ok and "limite da fuselagem" in msg
    f = ac.fuselage
    bat = next(i for i in ac.mass.items if i.name == "bateria")
    assert f.x_nose - f.length + 0.05 - 1e-9 <= bat.x <= f.x_nose - 0.05 + 1e-9


def test_without_design_cg_nothing_to_do():
    ac = conventional()
    ok, msg = bl.rebalance(ac)
    assert not ok and "CG de projeto" in msg


def test_checklist_warns_cg_and_drop():
    ac = _ac()
    ac.payload.x = 0.3
    cs = {c.item: c for c in ck.define_checks(ac)}
    assert cs["CG com a carga × CG de projeto"].status == ck.ATT
    assert cs["CG depois da soltura da LAPES"].status == ck.ATT
    ac.payload.x = bl.full_cg(ac, with_payload=False)[1][0]        # LAPES no CG do resto: soltar não mexe
    assert {c.item: c for c in ck.define_checks(ac)}["CG depois da soltura da LAPES"].status == ck.OK

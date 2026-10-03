"""Massa seca (Steiner), tanques e compilação aeronave -> SimSpec."""
import numpy as np
import pytest

from aerosim.model import TEMPLATES
from aerosim.backend.zig.translator import native_spec
from aerosim.model.aircraft import PointMass
from aerosim.model.massprops import dry_mass


def test_point_mass_moves_cg():
    ac = TEMPLATES["conventional"]()
    m0 = dry_mass(ac)
    ac.mass.items.append(PointMass("lastro", 1.0, 0.5, 0, 0))
    m1 = dry_mass(ac)
    assert m1["m"] == pytest.approx(m0["m"] + 1)
    assert m1["cg"][0] == pytest.approx((m0["m"] * m0["cg"][0] + 0.5) / m1["m"])
    assert m1["I"][1, 1] > m0["I"][1, 1]


def test_motor_mass_follows_motor():
    ac = TEMPLATES["twin_boom"]()
    ac.mass.include_propulsion = True
    a = dry_mass(ac)["cg"][0]
    ac.propulsion[0].x += 0.3
    assert dry_mass(ac)["cg"][0] > a


def test_core_mass_includes_liquid_and_payload(backend):
    ac = TEMPLATES["conventional"]()
    with backend.open_session() as s:
        s.configure(native_spec(ac))
        mp = s.mass_props()
    liq = sum(t.liquid_mass for t in ac.tanks)
    assert mp["m"] == pytest.approx(ac.mass.base_mass + liq + ac.payload.mass, rel=1e-9)
    assert np.allclose(mp["I"], mp["I"].T)


def test_square_tank_parameters(backend):
    with backend.open_session() as s:
        s.configure({"m_dry": 1.0, "tank": [dict(side=0.1, fill=0.05, rho=1000)]})
        t = s.derived()["tank"][0]
    w1 = np.sqrt(9.80665 * np.pi / 0.1 * np.tanh(np.pi * 0.5))
    assert t["m_liq"] == pytest.approx(0.5) and t["w1"] == pytest.approx(w1, rel=1e-9) and 0 < t["m1"] < 0.5


def test_overrides_reach_the_core():
    spec = native_spec(TEMPLATES["conventional"](), overrides={"env": {"Vw10": 0.0}, "stop_t": 3.0})
    assert spec["env"]["Vw10"] == 0.0 and spec["env"]["rho"] == 1.225 and spec["stop_t"] == 3.0

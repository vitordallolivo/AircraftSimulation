"""Tração motor + hélice da sprint no núcleo (core/src/sizing/motorprop.zig): bit a bit igual à conta em Python de
antes, com todos os motores, hélices e baterias do catálogo."""
import itertools
import math
import os

import numpy as np
import pytest

from aerosim.data.sources import load_catalog
from aerosim.design import power as pw
from aerosim.model.aircraft import PropulsionUnit

CATALOG = os.path.join(os.path.dirname(__file__), "..", "..", "data", "catalog", "catalog.cfg")


def _python_motor_prop(u, V, rho):
    """a tração como era em aerosim/design/power.py (_motor_prop) antes de ir para o núcleo"""
    m, p, bt = u.motor, u.propeller, u.battery
    if not p.J:
        return 0.0
    kv = m.Kv * 2 * math.pi / 60
    R = m.Rm + bt.Rint
    D = p.D

    def resid(w):
        I = min((bt.Voc - w / kv) / R, m.Imax)
        Qm = I / kv - m.tauc - m.B * w
        n = w / (2 * math.pi)
        J = V / (n * D) if n > 0 else 0.0
        CP = float(np.interp(J, p.J, p.CP))
        return Qm - CP * rho * n * n * D ** 5 / (2 * math.pi), n, J
    lo, hi = 1.0, bt.Voc * kv
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if resid(mid)[0] > 0:
            lo = mid
        else:
            hi = mid
    _, n, J = resid(0.5 * (lo + hi))
    CT = float(np.interp(J, p.J, p.CT, right=0.0))
    return max(CT * rho * n * n * D ** 4, 0.0)


def _units():
    cat = load_catalog(CATALOG)
    props = [p for p in cat.propellers if p.J]
    assert cat.motors and props and cat.batteries
    for m, p, b in itertools.product(cat.motors, props, cat.batteries):
        yield PropulsionUnit(motor=m, propeller=p, battery=b)


def test_core_matches_python_bit_for_bit():
    V = np.r_[0.0, np.linspace(0.3, 45.0, 37), 120.0]          # parado, a faixa de voo e bem depois da tabela
    core = pw._core()
    n = 0
    for u in _units():
        for rho in (1.225, 1.06):
            got = core.motor_prop_thrust(pw.motor_prop_spec(u), V, rho)
            want = np.array([_python_motor_prop(u, v, rho) for v in V])
            assert got.tobytes() == want.tobytes(), (u.motor.name, u.propeller.name, u.battery.name, rho)
            n += 1
    assert n >= 2


def test_thrust_of_uses_core_and_sums_units():
    u = next(_units())
    from aerosim.model.aircraft import Aircraft
    ac = Aircraft(propulsion=[u, PropulsionUnit(motor=u.motor, propeller=u.propeller, battery=u.battery)])
    V = np.linspace(0, 20, 9)
    one = np.array([_python_motor_prop(u, v, 1.2) for v in V])
    assert pw.thrust_of(ac, V, 1.2).tobytes() == (np.zeros_like(V) + one + one).tobytes()


def test_empty_propeller_table_gives_no_thrust():
    u = next(_units())
    u.propeller.J, u.propeller.CT, u.propeller.CP = [], [], []
    assert pw._core().motor_prop_thrust(pw.motor_prop_spec(u), [0.0, 5.0], 1.2).tolist() == [0.0, 0.0]


def test_too_long_table_is_refused():
    u = next(_units())
    u.propeller.J = list(np.linspace(0, 1, 300))
    with pytest.raises(ValueError):
        pw._core().motor_prop_thrust(pw.motor_prop_spec(u), [0.0], 1.2)

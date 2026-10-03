"""Dispositivos de asa: geometria, painéis do núcleo, plano de Trefftz."""
import math

import numpy as np
import pytest

from aerosim.aero import tipdevices as td
from aerosim.model.aircraft import WingDevice
from aerosim.model.devices import device_area, legs
from aerosim.model.features import features
from aerosim.model.geometry import aircraft_meshes, all_panels
from aerosim.model.templates import conventional


def test_legs_geometry():
    ac = conventional()
    w = ac.wing
    d = WingDevice("winglet", height=0.2, cant=0.0, sweep=0.0, taper=1.0)
    ls = legs(w, d)
    assert len(ls) == 2 and {l.side for l in ls} == {1, -1}
    r = next(l for l in ls if l.side == 1)
    tip = r.root + r.u * r.height
    assert tip[2] == pytest.approx(r.root[2] - 0.2)          # para cima (z para baixo)
    assert len(legs(w, WingDevice("placa", height=0.2))) == 4
    assert device_area(w, d) == pytest.approx(0.2 * w.chord_at(w.semispan))


def test_panels_and_meshes():
    ac = conventional()
    n0 = len(all_panels(ac))
    ac.wing.devices.append(WingDevice("winglet", height=0.2, cant=20))
    ps = all_panels(ac)
    assert len(ps) == n0 + 6
    dev = [p for p in ps if p["group"] == 2 and p["vertical"] == 0]
    assert all(abs(math.degrees(p["dihedral"]) - 70) < 1e-9 for p in dev)
    assert len(aircraft_meshes(ac)["surface:0"]) > 2
    f = features(ac)
    assert f.has_tip_devices and f.tip_h_over_b == pytest.approx(0.2 / ac.wing.span)


def test_winglet_raises_span_efficiency_like_generic():
    ac = conventional()
    ac.wing.dihedral = 0.0
    hb = 0.1
    ac.wing.devices.append(WingDevice("winglet", height=hb * ac.wing.span, cant=0.0, sweep=0.0))
    e = td.aircraft_efficiency(ac) / td.aircraft_efficiency(ac, with_devices=False)
    assert e == pytest.approx(td.span_efficiency("winglet", hb, 60), rel=0.02)


def test_device_changes_core_aero(backend):
    from aerosim.model.compile import compile_aircraft
    ac = conventional()
    with backend.open_session() as s:
        s.configure(compile_aircraft(ac))
        cnb0 = s.aero_coeffs(15, 0.05, 0.05)["Cn"]
        ac.wing.devices.append(WingDevice("winglet", height=0.25, cant=0.0, sweep=20))
        s.configure(compile_aircraft(ac))
        assert s.aero_coeffs(15, 0.05, 0.05)["Cn"] != pytest.approx(cnb0, abs=1e-6)

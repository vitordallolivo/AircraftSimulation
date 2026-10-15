"""Colisão (core/src/collision): o tubo de cada hélice contra as superfícies e os objetos do avião. Uma superfície
acima ou abaixo da linha de tração fica de fora ou só em parte dentro."""
import numpy as np
import pytest

from aerosim.aero.collision import tube_hits
from aerosim.model.templates import conventional, flying_wing, twin_boom


def by(hits, comp):
    return next((h for h in hits if h.component == comp), None)


def test_cylinder_hits_what_is_behind_the_prop(backend):
    ac = conventional()
    hits = tube_hits(backend, ac)
    names = {h.component for h in hits}
    assert {"asa", "EH"} <= names
    assert 0 < by(hits, "asa").fraction < 0.3                 # só a parte da asa atrás do disco


def test_surface_above_the_thrust_line_is_out(backend):
    """subindo a asa acima do raio da hélice, ela sai do tubo"""
    ac = conventional()
    R = ac.propulsion[0].propeller.D / 2
    ac.wing.z = ac.propulsion[0].z - (R + 0.10)                # z para baixo: menos = acima
    hits = tube_hits(backend, ac)
    assert by(hits, ac.wing.name) is None


def test_pusher_tube_goes_backwards(backend):
    """asa voadora com hélice atrás: o tubo vai para trás e não pega a asa"""
    hits = tube_hits(backend, flying_wing())
    assert by(hits, flying_wing().wing.name) is None


def test_slipstream_tube_contracts(backend):
    ac = conventional()
    cyl = tube_hits(backend, ac)
    tube = tube_hits(backend, ac, V=12.0, thrust=[20.0])
    assert by(tube, "EH").fraction < by(cyl, "EH").fraction   # o tubo da esteira afina atrás do disco


def test_twin_symmetric(backend):
    hits = tube_hits(backend, twin_boom())
    w = [h for h in hits if h.component == twin_boom().wing.name]
    assert len(w) == 2 and w[0].fraction == pytest.approx(w[1].fraction)


def test_point_hits_direct(backend):
    from aerosim.model.universal import build_model
    ac = conventional()
    u = ac.propulsion[0]
    with backend.session_for(build_model(ac)) as s:
        pts = np.array([[u.x - 0.5, u.y, u.z], [u.x + 0.2, u.y, u.z], [u.x - 0.5, u.y + 1.0, u.z]])
        assert list(s.tube_point_hits(0, pts)) == [True, False, False]

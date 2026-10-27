"""Checagem de geometria do avião montado (core/src/geometry pelo tradutor aerosim/backend/zig/geometry.py)."""
import copy

from aerosim.backend.zig.geometry import ZigGeometry, scene
from aerosim.interfaces.geometry import GeometryParams
from aerosim.model.aircraft import TailBoom
from aerosim.model.templates import conventional, flying_wing
from aerosim.model.universal import build_model


def test_conventional_template_tail_without_boom_is_loose():
    """o modelo convencional não tem tubo: a cauda fica solta, e o relatório diz isso"""
    r = ZigGeometry().check(build_model(conventional()))
    assert not r.ok and len(r.groups) > 1
    assert any("EH" in g for g in r.groups[1:]) and any("soltas" in x for x in r.reasons)
    ok = ZigGeometry().check(build_model(conventional()), GeometryParams(connected=False, rotation=0.0))
    assert not ok.prop_hits                                # a hélice presa no nariz não acerta a fuselagem
    assert len(ok.groups) > 1 and not any("soltas" in x for x in ok.reasons)


def test_boom_through_the_pusher_propeller():
    """asa voadora com hélice propulsora: um tubo de cauda saindo do meio passa pelo disco da hélice"""
    ac = flying_wing()
    u = ac.propulsion[0]
    ac.gear.main_z = ac.gear.steer_z = 0.4                 # trem alto: a hélice não bate no chão
    p = GeometryParams(connected=False, rotation=0.0)
    assert not ZigGeometry().check(build_model(ac), p).prop_hits
    bad = copy.deepcopy(ac)
    bad.booms = [TailBoom(name="tubo", x_start=u.x + 0.2, y=u.y + 0.06, z=u.z, length=0.6)]   # fora do cubo
    r = ZigGeometry().check(build_model(bad), p)
    assert r.prop_hits == [("motor 1: hélice", "tubo")] and "hélice acerta" in r.why()
    side = copy.deepcopy(bad)
    side.booms[0].y = u.y + u.propeller.D / 2 + 0.05       # tubo ao lado do disco
    assert not ZigGeometry().check(build_model(side), p).prop_hits


def test_ground_and_masses():
    ac = flying_wing()
    r = ZigGeometry().check(build_model(ac))
    assert any("bate no chão" in x for x in r.reasons)    # o trem do modelo é baixo para a hélice de 15"
    from aerosim.model.aircraft import PointMass
    ac.mass.items.append(PointMass("rádio", 0.05, 0.0, 3.0, 0.0))     # massa fora de tudo
    r = ZigGeometry().check(build_model(ac))
    assert r.outside == ["rádio"] and "fora da geometria: rádio" in r.why()
    sp, names = scene(build_model(ac))
    assert sp["n"] == len(names) and sp["att"][1] >= sp["att"][0]


def test_many_at_once_matches_one_by_one():
    ms = [build_model(conventional()), build_model(flying_wing())]
    g = ZigGeometry()
    assert [r.reasons for r in g.check_many(ms)] == [g.check(m).reasons for m in ms]

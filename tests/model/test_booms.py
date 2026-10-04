"""tubos genéricos (lista, inclinação, tubo duplo), superfícies presas (cauda em T) e o avião vazio"""
import glob
import json
import math
import os

import pytest

from aerosim.data import load_aircraft
from aerosim.model.aircraft import Aircraft, LiftingSurface, TailBoom, rect_sections
from aerosim.model.geometry import aircraft_meshes
from aerosim.model.massprops import dry_mass
from aerosim.model.serialize import from_dict, to_dict
from aerosim.model.templates import empty, is_empty

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def test_old_single_boom_file_migrates():
    old = {"name": "antigo", "boom": {"enabled": True, "x_start": -0.2, "length": 0.9, "z": -0.05, "attach_tail": True},
           "surfaces": [{"name": "EH", "role": "htail", "sections": [{"y": 0, "chord": 0.2}, {"y": 0.3, "chord": 0.2}]}]}
    ac = from_dict(Aircraft, old)
    assert len(ac.booms) == 1 and ac.boom.length == 0.9 and ac.surfaces[0].mount == "tubo:0"
    ac.apply_constraints()
    assert ac.surfaces[0].x == pytest.approx(-1.1 + 0.2) and ac.surfaces[0].z == pytest.approx(-0.05)
    assert "boom" not in to_dict(ac) and from_dict(Aircraft, to_dict(ac)).booms[0].length == 0.9


def test_old_files_keep_their_tail_where_it_was():
    for p in glob.glob(os.path.join(ROOT, "data", "aircraft", "*.json")):
        with open(p, encoding="utf-8") as f:
            raw = json.load(f)
        ac = load_aircraft(p)
        before = {(s["name"], round(s.get("x", 0), 6), round(s.get("z", 0), 6)) for s in raw.get("aeronave", raw)["surfaces"]}
        ac.apply_constraints()
        assert {(s.name, round(s.x, 6), round(s.z, 6)) for s in ac.surfaces} == before, p


def test_inclined_boom_and_tail_follows():
    b = TailBoom(x_start=-0.2, length=1.0, pitch=10.0, z=0.0)
    x, y, z = b.end
    assert x == pytest.approx(-0.2 - math.cos(math.radians(10))) and z == pytest.approx(-math.sin(math.radians(10)))
    eh = LiftingSurface(name="EH", role="htail", sections=rect_sections(0.4, 0.2), mount="tubo:0")
    ac = Aircraft(booms=[b], surfaces=[eh])
    ac.apply_constraints()
    assert eh.x == pytest.approx(x + 0.2) and eh.z == pytest.approx(z)


def test_twin_boom_with_two_fins_and_t_tail():
    bl = TailBoom(name="esq", x_start=-0.1, y=-0.4, length=0.9)
    br = TailBoom(name="dir", x_start=-0.1, y=0.4, length=0.9)
    evl = LiftingSurface(name="EV esq", role="vtail", vertical=True, symmetric=False,
                         sections=rect_sections(0.3, 0.2), mount="tubo:0")
    evr = LiftingSurface(name="EV dir", role="vtail", vertical=True, symmetric=False,
                         sections=rect_sections(0.3, 0.2), mount="tubo:1")
    eh = LiftingSurface(name="EH em T", role="htail", sections=rect_sections(0.8, 0.18), mount="ponta:1")
    ac = Aircraft(booms=[bl, br], surfaces=[evl, evr, eh])
    ac.apply_constraints()
    assert evl.y == pytest.approx(-0.4) and evr.y == pytest.approx(0.4)
    assert eh.x == pytest.approx(evr.x) and eh.z == pytest.approx(evr.z - evr.semispan) and eh.y == 0.0
    m = aircraft_meshes(ac)
    assert {"boom:0", "boom:1"} <= set(m)


def test_empty_aircraft():
    ac = empty()
    assert is_empty(ac) and dry_mass(ac)["m"] == 0.0 and list(aircraft_meshes(ac)) == ["gear"]
    ac.booms.append(TailBoom())
    assert "boom:0" in aircraft_meshes(ac)


def test_project_keeps_assembly_and_screen(tmp_path):
    from aerosim.design.project import DesignProject, is_project_file
    from aerosim.model.templates import twin_boom
    p = DesignProject()
    p.fleet, p.current, p.ui = [empty(), twin_boom()], 1, {"tab": "Montagem", "sub": 0}
    f = tmp_path / "proj.json"
    p.save(str(f))
    q = DesignProject.load(str(f))
    assert is_project_file(str(f)) and q.current == 1 and q.ui["tab"] == "Montagem"
    assert [a.name for a in q.fleet] == [a.name for a in p.fleet] and q.fleet[1].surfaces[1].mount == "tubo:0"
    assert dict(q.summary())["Montagem"].startswith("novo avião")
    assert not is_project_file(os.path.join(ROOT, "data", "aircraft", "Asa_voadora.json"))

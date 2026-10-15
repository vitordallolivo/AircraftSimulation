"""Exemplo tools/sprint_tres_caudas.py: a mesma asa com três opções de superfícies, num arquivo só."""
import importlib.util
import json
import os

from aerosim.design import power as pw
from aerosim.design import store
from aerosim.design import tail as tl
from aerosim.model.catalog import builtin_catalog
from aerosim.model.serialize import to_dict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _tool():
    spec = importlib.util.spec_from_file_location("sprint_tres_caudas", os.path.join(ROOT, "tools", "sprint_tres_caudas.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _controls(ac):
    return {s.name: [c.kind for c in s.controls] for s in ac.surfaces}


def test_one_wing_file_with_three_options(tmp_path):
    t = _tool()
    assert t.main([str(tmp_path)]) == 0
    assert sorted(os.listdir(tmp_path)) == ["asa S1223.json", "sprint.json"]
    d = json.load(open(tmp_path / "asa S1223.json", encoding="utf-8"))
    assert [s["params"]["layout"] for s in d["superficies"]] == ["convencional", "em V", "sem cauda"]
    assert [a["superficie"] for a in d["avioes"]] == [s["params"]["name"] for s in d["superficies"]]
    p = store.load(str(tmp_path))
    assert to_dict(p) == to_dict(t.build()) and len(p.wings) == 1


def test_each_option_builds_its_controls_and_boom():
    t = _tool()
    p = t.build()
    conv, vee, flying = p.sets
    ac, _ = tl.build_set(conv, p.requirements, p.rules, airfoils=p.airfoil_map())
    assert _controls(ac) == {"asa": ["aileron"], "EH": ["elevator"], "EV": ["rudder"]}
    b = ac.boom
    assert b.pitch == t.BOOM_PITCH and b.end[2] < b.start[2] - 0.05      # z para baixo: a ponta subiu
    eh = next(s for s in ac.surfaces if s.name == "EH")
    assert abs(eh.z - b.end[2]) < 1e-9                                     # a cauda vai junto com a ponta do tubo
    ac, _ = tl.build_set(vee, p.requirements, p.rules, airfoils=p.airfoil_map())
    assert _controls(ac) == {"asa": ["aileron"], "cauda em V": ["ruddervator"]} and ac.boom.pitch == 0
    ac, _ = tl.build_set(flying, p.requirements, p.rules, airfoils=p.airfoil_map())
    assert _controls(ac) == {"asa": ["elevon"]} and not ac.booms


def test_inclined_boom_keeps_the_tail_arm():
    p = _tool().build()
    s = p.sets[0]
    ac1, i1 = tl.build_set(s, p.requirements, p.rules, airfoils=p.airfoil_map())
    s.params.boom_pitch = 0.0
    ac0, i0 = tl.build_set(s, p.requirements, p.rules, airfoils=p.airfoil_map())
    x = lambda ac: next(q.x for q in ac.surfaces if q.name == "EH")
    assert abs(x(ac1) - x(ac0)) < 1e-9 and i1["arm"] == i0["arm"] and ac1.boom.length > ac0.boom.length


def test_three_aircraft_assemble():
    p = _tool().build()
    cat = builtin_catalog()
    tails = []
    for a in p.aircraft:
        ac, asm = pw.assemble(a, p.requirements, p.rules, cat, p.airfoil_map())
        assert asm["mass"] > 0
        tails.append(sorted(s.name for s in ac.surfaces))
    assert tails == [["EH", "EV", "asa"], ["asa", "cauda em V"], ["asa"]]

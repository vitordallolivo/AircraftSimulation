"""Modificadores (model/modifiers.py → core/src/modifiers/): arquivos antigos abrem com o padrão (efeito solo de
McCormick, o de sempre), o tradutor leva para o núcleo e o efeito solo se liga/desliga pela lista."""
import json
import os

import pytest

from aerosim.backend.zig.translator import native_spec
from aerosim.data import load_aircraft, save_aircraft
from aerosim.model import modifiers as mods
from aerosim.model.serialize import to_dict
from aerosim.model.templates import conventional

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
EXAMPLES = sorted(f for f in os.listdir(os.path.join(ROOT, "data", "aircraft")) if f.endswith((".json", ".cfg")))


@pytest.mark.parametrize("name", EXAMPLES)
def test_examples_open_with_the_default(name):
    """nenhum exemplo do repositório tem modificadores: abre com o padrão e vai ao núcleo igual a antes"""
    ac = load_aircraft(os.path.join(ROOT, "data", "aircraft", name))
    assert mods.is_default(ac) and [m.kind for m in ac.modifiers] == ["solo.mccormick"]
    sp = native_spec(ac)
    assert sp["ground"] == 1 and sp["n_mod"] == 0 and sp["mods"] == []


def test_json_round_trip_keeps_the_list(tmp_path):
    ac = conventional()
    ac.modifiers = []                                   # sem efeito solo
    p = tmp_path / "a.json"
    save_aircraft(ac, str(p))
    assert json.load(open(p))["modifiers"] == []
    assert load_aircraft(str(p)).modifiers == []
    ac.modifiers = [mods.Modifier("solo.mccormick", name="teste")]
    save_aircraft(ac, str(p))
    assert to_dict(load_aircraft(str(p)))["modifiers"] == to_dict(ac)["modifiers"]


def test_old_file_without_the_key(tmp_path):
    d = to_dict(conventional())
    d.pop("modifiers")
    p = tmp_path / "antigo.json"
    p.write_text(json.dumps(d))
    assert mods.is_default(load_aircraft(str(p)))


def test_translator_and_limits(backend):
    ac = conventional()
    assert native_spec(ac)["ground"] == 1
    ac.modifiers = []
    assert native_spec(ac)["ground"] == mods.GROUND_OFF
    ac.modifiers = [mods.Modifier("solo.mccormick", enabled=False)]
    assert native_spec(ac)["ground"] == mods.GROUND_OFF
    assert backend.schema.limits["mods"] == mods.MAX_MODS
    assert {"ground", "n_mod", "mods"} <= {f.name for f in backend.schema.structs["Params"].fields}


def test_problems_and_export_warning():
    ac = conventional()
    assert mods.problems(ac) == [] and mods.not_exported(ac, "x.cfg") == []
    ac.modifiers = [mods.Modifier("solo.mccormick"), mods.Modifier("solo.mccormick"), mods.Modifier("futuro.x")]
    pr = mods.problems(ac)
    assert any("desconhecido" in p for p in pr) and any("2 métodos" in p for p in pr)
    assert mods.not_exported(ac, "x.cfg") and not mods.not_exported(ac, "x.json")
    assert native_spec(ac)["ground"] == 1                # o desconhecido é ignorado


def test_ground_effect_switch_changes_the_takeoff(manager):
    """sem efeito solo o arrasto induzido perto do chão é maior: a corrida não pode ficar menor"""
    ac = conventional()
    r1 = manager.run("mission", ac, {"mode": "só decolagem"})
    ac.modifiers = []
    r0 = manager.run("mission", ac, {"mode": "só decolagem"})
    assert "efeito solo: desligado" in r0.summary["modificadores"] and "modificadores" not in r1.summary
    l1, l0 = r1.log, r0.log
    assert len(l1) and len(l0) and (len(l1["t"]) != len(l0["t"]) or (l1["n"] != l0["n"]).any())

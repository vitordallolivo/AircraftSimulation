"""O exemplo tools/sprint_pasta.py: o projeto S1223 da equipe vira a pasta nova, um arquivo por asa."""
import importlib.util
import json
import os

import pytest

from aerosim.design import store
from aerosim.design.project import DesignProject
from aerosim.model.serialize import to_dict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SAMPLE = os.path.join(ROOT, "data", "sprint", "projeto_s1223.json")


def _tool():
    spec = importlib.util.spec_from_file_location("sprint_pasta", os.path.join(ROOT, "tools", "sprint_pasta.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_example_converts_team_project(tmp_path, capsys):
    before = open(SAMPLE, "rb").read()
    dst = tmp_path / "sprint_s1223"
    assert _tool().main([SAMPLE, str(dst)]) == 0
    out = capsys.readouterr().out
    assert sorted(os.listdir(dst)) == ["asa S1223.json", "sprint.json"]
    asa = json.load(open(dst / "asa S1223.json", encoding="utf-8"))
    p = DesignProject.load(SAMPLE)
    assert asa["format"] == store.WING_KIND and asa["nome"] == "asa S1223"
    assert [s["params"]["name"] for s in asa["superficies"]] == [s.name for s in p.sets]      # 4 superfícies
    assert [a["params"]["name"] for a in asa["avioes"]] == [a.name for a in p.aircraft]       # 6 aviões
    assert "cauda em V MH 113 invertida" in out and "S1223, MH 113, HT 14, SD8020" in out
    assert to_dict(store.load(str(dst))) == to_dict(p)           # a pasta abre igual ao projeto antigo
    assert open(SAMPLE, "rb").read() == before                   # a origem não muda


def test_example_refuses_to_write_inside_data(tmp_path):
    with pytest.raises(SystemExit):
        _tool().convert(SAMPLE, os.path.join(ROOT, "data", "sprint", "nao_criar"))
    assert not os.path.exists(os.path.join(ROOT, "data", "sprint", "nao_criar"))

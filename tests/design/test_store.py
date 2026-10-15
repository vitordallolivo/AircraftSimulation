"""Projeto da sprint numa pasta, um arquivo por asa (aerosim/design/store.py)."""
import json
import os
import shutil

from aerosim.design import store
from aerosim.design.project import DesignProject
from aerosim.model.serialize import to_dict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SAMPLE = os.path.join(ROOT, "data", "sprint", "projeto_s1223.json")


def _project() -> DesignProject:
    """asa A com duas superfícies e um avião; asa B com uma superfície"""
    p = DesignProject()
    p.wing_draft.name = "asa A"
    p.keep_wing()
    p.tail_draft.name, p.tail_draft.wing = "cauda em V", "asa A"
    p.tail_draft.layout = "em V"
    p.keep_set()
    p.tail_draft.name, p.tail_draft.layout = "convencional", "convencional"
    p.keep_set()
    p.power_draft.name, p.power_draft.set = "mono", "cauda em V"
    p.keep_aircraft()
    p.wing_draft.name, p.wing_draft.span = "asa B", 2.0
    p.keep_wing()
    p.tail_draft.name, p.tail_draft.wing = "sem cauda", "asa B"
    p.tail_draft.layout = "sem cauda"
    p.keep_set()
    return p


def _files(folder):
    return sorted(n for n in os.listdir(folder) if n.endswith(".json"))


def test_one_file_per_wing_and_round_trip(tmp_path):
    p = _project()
    store.save(p, str(tmp_path))
    assert _files(tmp_path) == ["asa A.json", "asa B.json", "sprint.json"]
    a = json.load(open(tmp_path / "asa A.json", encoding="utf-8"))
    assert a["nome"] == "asa A" and [s["params"]["name"] for s in a["superficies"]] == ["cauda em V", "convencional"]
    assert [x["params"]["name"] for x in a["avioes"]] == ["mono"] and "superficie_copia" not in a["avioes"][0]
    main = json.load(open(tmp_path / "sprint.json", encoding="utf-8"))
    assert not {"wings", "sets", "aircraft"} & set(main)          # as asas só nos arquivos delas
    assert to_dict(store.load(str(tmp_path))) == to_dict(p)


def test_team_sample_round_trips_without_touching_it(tmp_path):
    before = open(SAMPLE, "rb").read()
    p = DesignProject.load(SAMPLE)
    store.save(p, str(tmp_path))
    assert to_dict(store.load(str(tmp_path))) == to_dict(p)
    assert open(SAMPLE, "rb").read() == before


def test_wing_changed_after_a_surface_keeps_the_old_copy(tmp_path):
    p = _project()
    p.wing_draft.name, p.wing_draft.span = "asa A", 2.9            # a asa A mudou depois das superfícies
    p.keep_wing()
    store.save(p, str(tmp_path))
    assert "asa A (2).json" in _files(tmp_path)
    q = store.load(str(tmp_path))
    assert to_dict(q) == to_dict(p)
    assert q.wing("asa A").params.span == 2.9 and q.set("cauda em V").wing.params.span != 2.9


def test_aircraft_with_old_copy_of_the_surface(tmp_path):
    p = _project()
    p.tail_draft.name, p.tail_draft.wing, p.tail_draft.arm = "cauda em V", "asa A", 1.3
    p.tail_draft.layout = "em V"
    p.keep_set()                                                   # a superfície mudou depois do avião
    store.save(p, str(tmp_path))
    a = json.load(open(tmp_path / "asa A.json", encoding="utf-8"))
    assert a["avioes"][0]["superficie_copia"]["params"]["arm"] != 1.3
    q = store.load(str(tmp_path))
    assert to_dict(q) == to_dict(p)


def test_removed_wing_file_goes_away(tmp_path):
    p = _project()
    store.save(p, str(tmp_path))
    p.wings = [w for w in p.wings if w.name != "asa B"]
    p.sets = [s for s in p.sets if s.wing.name != "asa B"]
    store.save(p, str(tmp_path))
    assert _files(tmp_path) == ["asa A.json", "sprint.json"]


def test_wing_file_copied_from_another_project_comes_in(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    store.save(_project(), str(a))
    q = DesignProject()
    q.wing_draft.name = "asa C"
    q.keep_wing()
    store.save(q, str(b))
    shutil.copy(a / "asa B.json", b / "asa B.json")
    r = store.load(str(b))
    assert [w.name for w in r.wings] == ["asa C", "asa B"] and [s.name for s in r.sets] == ["sem cauda"]


def test_old_folder_with_projeto_json_opens_and_stays(tmp_path):
    shutil.copy(SAMPLE, tmp_path / "projeto.json")
    p = store.load(str(tmp_path))
    assert to_dict(p) == to_dict(DesignProject.load(SAMPLE))
    store.save(p, str(tmp_path))
    assert open(tmp_path / "projeto.json", "rb").read() == open(SAMPLE, "rb").read()
    assert to_dict(store.load(str(tmp_path))) == to_dict(p)       # agora abre o formato novo


def test_file_names_are_safe():
    assert store.file_name('asa S1223: v2/final?') == "asa S1223_ v2_final_.json"
    assert store.file_name("sprint") == "sprint (asa).json" and store.file_name("  ") == "asa.json"


def test_runs_go_to_results_folder_and_come_back(tmp_path):
    p = _project()
    p.runs = [dict(sim="stability", aircraft="a", sig="abc123def4567890", params={"V": 12.0}, when="2026-01-01T10:00:00",
                   result=dict(series={}, summary={"x": 1.0}, events={}, status="ok", checks=[], log=None))]
    store.save(p, str(tmp_path))
    assert os.listdir(tmp_path / "resultados") == ["stability_abc123def456.json.gz"]
    main = json.load(open(tmp_path / "sprint.json", encoding="utf-8"))
    assert "result" not in main["runs"][0] and main["runs"][0]["file"].endswith(".json.gz")    # só o índice
    q = store.load(str(tmp_path))
    assert q.runs[0]["result"]["summary"] == {"x": 1.0} and q.runs[0]["params"] == {"V": 12.0}
    q.runs = []
    store.save(q, str(tmp_path))
    assert os.listdir(tmp_path / "resultados") == []                    # saiu do projeto: o arquivo some

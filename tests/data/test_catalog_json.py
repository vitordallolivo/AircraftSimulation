"""os polinômios de tração da equipe (data/catalog/tracao_equipe.json): carregam e reproduzem o T0 da planilha"""
import json
import os

import pytest

from aerosim.data import load_catalog

PATH = os.path.join(os.path.dirname(__file__), "..", "..", "data", "catalog", "tracao_equipe.json")


def test_team_thrust_polynomials_reproduce_T0():
    cat = load_catalog(PATH)
    with open(PATH, encoding="utf-8") as f:
        raw = json.load(f)
    assert len(raw["linhas_como_vieram"]) == 4 and [p["nome"] for p in raw["pendentes"]] == ["16x4E 630kV"]
    assert {t.name for t in cat.thrust_sets} == {"21x6", "20x8E", "16x4 630kv dinâ"}
    for t in cat.thrust_sets:
        assert t.thrust(0.0, rho=1.225) / 9.80665 == pytest.approx(t.T0, rel=0.03)
        assert t.thrust(15.0) < t.thrust(0.0)                 # cai com V

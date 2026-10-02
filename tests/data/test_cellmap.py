"""Planilha Dados_Desempenho.xlsx por mapa de células, incluindo os conjuntos de tração (aba Tracao)."""
import math

import pytest

from aerosim.data.cellmap import CellMapAircraftSource
from aerosim.model import compile_aircraft


def test_reads_fields(desempenho_xlsx, mapping_path):
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    assert not src.warnings
    assert ac.wing.area == pytest.approx(0.9) and ac.wing.span == pytest.approx(2.4)
    assert ac.wing.CLa == pytest.approx(0.08 * 180 / math.pi)
    assert ac.surface("htail").eps0 == 1.5 and ac.tanks == []
    assert ac.mass.base_mass == 7.5 and ac.mass.Ixz == 0.03


def test_reads_thrust_sets(desempenho_xlsx, mapping_path):
    from sheet_fixtures import SETS
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    assert [t.name for t in src.catalog.thrust_sets] == [s[0] for s in SETS]
    u = ac.propulsion[0]
    assert u.thrust_model == "poly" and u.thrust_poly.name == SETS[1][0]       # nhelice = 2 -> linha 4
    name, p00, p10, p20 = SETS[1]
    assert u.thrust_poly.thrust(10.0) == pytest.approx(p00 + 10 * p10 + 100 * p20)
    assert u.thrust_poly.T0 == p00 and u.thrust_poly.n == 0.8


def test_roundtrip_same_cells(desempenho_xlsx, mapping_path, tmp_path):
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    ac.propulsion[0].thrust_poly.coefs[0] = 40.0
    out = str(tmp_path / "out.xlsx")
    src.save(ac, out)
    back = src.load(out)
    assert back.propulsion[0].thrust_poly.coefs[0] == 40.0
    assert compile_aircraft(back)["Sref"] == compile_aircraft(ac)["Sref"]


def test_gain_t0(desempenho_xlsx, mapping_path):
    import json
    m = json.load(open(mapping_path))
    m["thrust_sets"]["gain"] = "T0"
    src = CellMapAircraftSource(m)
    ac = src.load(desempenho_xlsx)
    assert ac.propulsion[0].thrust_poly.gain == ac.propulsion[0].thrust_poly.T0


def test_missing_cells_are_warnings(tmp_path, mapping_path):
    from openpyxl import Workbook
    p = str(tmp_path / "vazia.xlsx")
    wb = Workbook()
    wb.active.title = "Geral"
    wb.save(p)
    src = CellMapAircraftSource(mapping_path)
    src.load(p)
    assert any("Superficies" in w for w in src.warnings)

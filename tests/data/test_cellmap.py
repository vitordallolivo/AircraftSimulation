"""Planilha Dados_Desempenho.xlsx por mapa de células, incluindo os conjuntos de tração (aba Tracao)."""
import math

import pytest

from aerosim.data.cellmap import CellMapAircraftSource
from aerosim.backend.zig.translator import native_spec


def test_reads_fields(desempenho_xlsx, mapping_path):
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    assert not src.warnings
    assert ac.wing.area == pytest.approx(0.9) and ac.wing.span == pytest.approx(2.4)
    assert ac.wing.CLa == pytest.approx(0.08 * 180 / math.pi)
    assert ac.surface("htail").eps0 == 1.5 and ac.tanks == []
    assert ac.mass.base_mass == 7.5 and ac.mass.Ixz == 0.03


def test_reads_thrust_sets(desempenho_xlsx, mapping_path):
    """mesma tração do Envelope_main: g·(ρ/ρ0)·(T0 + p10·n + p01·V + ...), T0 no lugar de p00"""
    from sheet_fixtures import SETS, thrust
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    assert [t.name for t in src.catalog.thrust_sets] == [s[0] for s in SETS]
    u = ac.propulsion[0]
    assert u.thrust_model == "poly" and u.thrust_poly.name == "conjunto B"       # nhelice = 2 -> linha 4
    for V in (0.0, 8.0, 15.0):
        assert u.thrust_poly.thrust(V, 1.0, 0.0, 1.2) == pytest.approx(thrust("conjunto B", V, 1.2))
    assert u.thrust_poly.T0 == 2.2 and u.thrust_poly.n == 1.5 and u.thrust_poly.coefs[0] == 2.2


def test_thrust_in_core_matches_sheet_formula(backend, desempenho_xlsx, mapping_path):
    from sheet_fixtures import thrust
    ac = CellMapAircraftSource(mapping_path).load(desempenho_xlsx)
    with backend.open_session() as s:
        s.configure(native_spec(ac))
        for V in (0.0, 8.0, 15.0):
            assert s.prop_point(0, V, 1.0)["T"] == pytest.approx(thrust("conjunto B", V, ac.environment.rho), rel=1e-12)


def test_reads_envelope_data(desempenho_xlsx, mapping_path):
    ac = CellMapAircraftSource(mapping_path).load(desempenho_xlsx)
    p = ac.performance
    assert p.alpha_cruise == 3.0 and p.load_factor == 2.0 and p.K == 0.06
    assert p.cdp_wing == [0.0005, 0.02] and p.cdp_htail == [0.0004, 0.015]


def test_roundtrip_same_cells(desempenho_xlsx, mapping_path, tmp_path):
    src = CellMapAircraftSource(mapping_path)
    ac = src.load(desempenho_xlsx)
    ac.propulsion[0].thrust_poly.coefs[1] = 0.33
    out = str(tmp_path / "out.xlsx")
    src.save(ac, out)
    back = src.load(out)
    assert back.propulsion[0].thrust_poly.coefs[1] == 0.33
    assert native_spec(back)["Sref"] == native_spec(ac)["Sref"]


def test_gain_options(desempenho_xlsx, mapping_path):
    import json
    m = json.load(open(mapping_path))
    for g, want in (("g", 9.80665), ("1", 1.0), ("T0", 2.2), ("g*PT0", 9.80665)):
        m["thrust_sets"]["gain"] = g
        ac = CellMapAircraftSource(m).load(desempenho_xlsx)
        assert ac.propulsion[0].thrust_poly.gain == pytest.approx(want)


def test_missing_cells_are_warnings(tmp_path, mapping_path):
    from openpyxl import Workbook
    p = str(tmp_path / "vazia.xlsx")
    wb = Workbook()
    wb.active.title = "Geral"
    wb.save(p)
    src = CellMapAircraftSource(mapping_path)
    src.load(p)
    assert any("Superficies" in w for w in src.warnings)

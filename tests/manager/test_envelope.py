"""Envelope por altitude: o modo "reproduzir o original" bate com o Envelope_main transcrito."""
import numpy as np
import pytest

from aerosim.data.cellmap import CellMapAircraftSource
from aerosim.model import TEMPLATES


@pytest.fixture
def sheet_aircraft(desempenho_xlsx, mapping_path):
    return CellMapAircraftSource(mapping_path).load(desempenho_xlsx)


def test_faithful_matches_original(manager, sheet_aircraft):
    from envelope_reference import data_dict_from_fixture, envelope_main
    ref = envelope_main(data_dict_from_fixture(), velstep=0.0005, d_altitude=100)
    r = manager.run("envelope", sheet_aircraft, {"method": "planilha", "faithful": True, "h_step": 100.0,
                                                 "h_max": 20000.0, "dV": 0.05, "table": False})
    env = r.series["envelope_planilha"]
    n = min(len(ref["h"]), len(env["h"]))
    assert n > 5 and abs(len(ref["h"]) - len(env["h"])) <= 1
    assert np.allclose(env["h"][:n], ref["h"][:n])
    for k in ("Vmin", "Vmax"):          # o original acha os cruzamentos na grade (velstep)
        assert np.allclose(env[k][:n], ref[k][:n], atol=0.0006), k
    for k in ("Ve", "Vman", "Vcru"):
        assert np.allclose(env[k][:n], ref[k][:n], rtol=1e-9), k


def test_corrected_vs_faithful(manager, sheet_aircraft):
    """ao nível do mar (mesma ρ) o arrasto com ρ em vez de ρ/ρ0 é maior: faixa V_min..V_max menor.
    (o teto pode subir ou descer: a ISA tem ρ maior que a fórmula da planilha em altitude)"""
    a = manager.run("envelope", sheet_aircraft, {"method": "planilha", "faithful": True, "table": False})
    b = manager.run("envelope", sheet_aircraft, {"method": "planilha", "faithful": False, "table": False})
    ea, eb = a.series["envelope_planilha"], b.series["envelope_planilha"]
    assert eb["Vmax"][0] - eb["Vmin"][0] < ea["Vmax"][0] - ea["Vmin"][0]


@pytest.mark.parametrize("name", list(TEMPLATES))
def test_model_method(manager, name):
    r = manager.run("envelope", TEMPLATES[name](), {"method": "modelo completo", "table": False, "h_step": 200.0})
    env = r.series["envelope_modelo"]
    assert len(env["h"]) > 2
    assert np.all(env["Vmin"] < env["Vmax"])
    assert np.all(np.diff(env["rho"]) < 0)
    assert np.all(env["Vmin"] >= 0.97 * env["Ve"])          # não voa abaixo do estol


def test_curves_and_table(manager, sheet_aircraft):
    r = manager.run("envelope", sheet_aircraft, {"method": "os dois"})
    keys = list(r.series)
    assert any(k.startswith("potencia_h0") for k in keys) and "perf" in keys
    c = next(v for k, v in r.series.items() if k.startswith("potencia_h0 (planilha"))
    assert np.allclose(c["Pd"], c["Td"] * c["V"])


def test_handles_case_that_breaks_original(manager, sheet_aircraft):
    """sobra tração já em V_i: o original faz intersections[1] com um cruzamento só (IndexError);
    aqui V_min fica no começo da faixa e V_max é achado normalmente"""
    from envelope_reference import data_dict_from_fixture, envelope_main
    import sheet_fixtures as F
    old = list(F.SETS)
    F.SETS[1] = ("conjunto B", 3.2, 1.5, 0.10, -0.050, -0.0045)
    try:
        with pytest.raises(IndexError):
            envelope_main(data_dict_from_fixture(), velstep=0.001, Vi=4)
    finally:
        F.SETS[:] = old
    sheet_aircraft.propulsion[0].thrust_poly.coefs[0] = 3.2
    sheet_aircraft.propulsion[0].thrust_poly.coefs[2] = -0.05
    sheet_aircraft.propulsion[0].thrust_poly.coefs[5] = -0.0045
    r = manager.run("envelope", sheet_aircraft, {"method": "planilha", "faithful": True, "table": False,
                                                 "V_lo": 4.0, "h_max": 2000.0})
    env = r.series["envelope_planilha"]
    assert env["Vmin"][0] == 4.0 and 4.0 < env["Vmax"][0] < 30.0

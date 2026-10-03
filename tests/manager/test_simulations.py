"""Simulation Manager com o núcleo real: cada simulação."""
import numpy as np
import pytest

from aerosim.model import TEMPLATES


def test_registry(manager):
    names = {s.name for s in manager.simulations()}
    assert {"takeoff", "turn", "envelope", "mission", "climb", "polar", "thrust"} <= names
    for s in manager.simulations():
        assert s.parameters() and s.plots()


@pytest.mark.parametrize("name", list(TEMPLATES))
def test_full_mission_each_aircraft(manager, name):
    chunks = []
    r = manager.run("mission", TEMPLATES[name](), {"iters": 4}, on_chunk=chunks.append)
    assert r.status == "COMPLETED", r.summary
    assert sum(len(c) for c in chunks) > 1000 and "etapas" in r.series


def test_mission_hits_target(manager):
    r = manager.run("mission", TEMPLATES["conventional"](), {"iters": 10})
    assert abs(r.summary["impacto_carga_n"]) < 2.0


def test_takeoff_sweep(manager):
    r = manager.run("takeoff", TEMPLATES["conventional"](), {"sweep": True, "sR_list": "30, 40", "de1_list": "-6, -3"})
    assert r.summary["restricoes"] == "ok" and len(r.series["mapa"]["sR"]) == 4


def test_turn_min_radius(manager):
    r = manager.run("turn", TEMPLATES["conventional"](), {"V_list": "15", "R_list": "16, 30, 50"})
    assert 10 < r.series["rmin"]["R_min"][0] <= 50


def test_envelope_and_polar(manager):
    e = manager.run("envelope", TEMPLATES["conventional"](), {"dV": 1.0})
    assert e.summary["V_max_nivelado"] > e.summary["Vs"]
    p = manager.run("polar", TEMPLATES["conventional"]())
    assert 0.05 < p.summary["static_margin"] < 0.4


def test_climb_and_thrust(manager):
    c = manager.run("climb", TEMPLATES["twin_boom"](), {"V_list": "14", "grads": "0.05, 0.1", "window": 6})
    assert np.isfinite(c.summary["gama_max"])
    t = manager.run("thrust", TEMPLATES["twin_boom"]())
    assert len(t.series) == 2 * 3


def test_sheet_aircraft_with_poly_thrust(manager, desempenho_xlsx, mapping_path):
    """aeronave da planilha (tração polinomial) passa por decolagem, envelope e missão"""
    from aerosim.data.cellmap import CellMapAircraftSource
    ac = CellMapAircraftSource(mapping_path).load(desempenho_xlsx)
    assert manager.run("takeoff", ac).status == "COMPLETED"
    e = manager.run("envelope", ac, {"dV": 2.0})
    assert e.summary["V_max_nivelado"] > e.summary["Vs"]
    assert manager.run("mission", ac, {"iters": 2}).status == "COMPLETED"


def test_aero_and_stability_tabs_registered(manager):
    names = [s.name for s in manager.simulations()]
    assert "aerodynamics" in names and "stability" in names


def test_stability_simulation(manager):
    from aerosim.model.templates import conventional
    r = manager.run("stability", conventional(), {"size_tail": False, "Vs_list": "13, 17", "resp": True})
    assert any(c.group == "dinâmica" for c in r.checks)
    assert any("margem estática" in c.item for c in r.checks)
    assert all(c.status in ("ok", "atencao", "falha", "info") for c in r.checks)
    assert "resp_lon" in r.series and "me_margem estática" in r.series and any(k.startswith("ail_") for k in r.series)


def test_stability_adapts_to_configuration(manager):
    """sem EH não há área de EH; elevon é dimensionado para arfagem + rolagem; sem leme, sem leme"""
    from aerosim.model.templates import conventional, flying_wing
    sim = manager.get("stability")
    keys_fw = {p.key for p in sim.parameters_for(flying_wing())}
    keys_cv = {p.key for p in sim.parameters_for(conventional())}
    assert "size_tail" not in keys_fw and "Vw" not in keys_fw and "size_tail" in keys_cv and "Vw" in keys_cv
    assert "cg_var" in keys_fw and "cg_margin" in keys_cv          # sem carga/líquido o CG é informado
    plots_fw = {p.key for p in sim.plots_for(flying_wing())}
    assert "elv" in plots_fw and "eh" not in plots_fw and "ail" not in plots_fw
    r = manager.run("stability", flying_wing(), {"Vs_list": "14", "whatif": False})
    assert not any(k.startswith("eh_") for k in r.series)
    assert any("elevon" in c.item for c in r.checks)
    assert any("C_m0" in c.item for c in r.checks)


def test_aerodynamics_simulation(manager):
    from aerosim.model.templates import conventional, flying_wing
    sim = manager.get("aerodynamics")
    d = sim.defaults(conventional())
    assert d["use_lltdrek"] and not d["use_asb_vlm"] and not d["tips"]      # sem dispositivo: não estuda pontas
    assert sim.defaults(flying_wing())["tips"]                              # tem winglets: avalia
    p = {"use_lltdrek": False, "a0": -2.0, "a1": 8.0, "da": 2.0}
    r = manager.run("aerodynamics", conventional(), p)
    assert "polar_núcleo Zig" in r.series and not any(k.startswith("tip") for k in r.series)
    assert r.summary["[núcleo Zig] SM"] > 0
    r = manager.run("aerodynamics", flying_wing(), p)
    assert any(c.group == "dispositivos de asa" for c in r.checks)

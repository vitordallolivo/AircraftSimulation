"""Aba Missão: terreno (mesa/plataforma), x_warning/z_warning, modos, MTOW e desempenho simples."""
import math

import numpy as np
import pytest

from aerosim.manager.analysis import warnings
from aerosim.manager.runner import Runner, Stop
from aerosim.manager.simulations.mission import MODES
from aerosim.model.mission import takeoff_runway
from aerosim.model.templates import TEMPLATES


def _takeoff(backend, ac):
    with Runner(backend, ac, takeoff_runway(), dict(tmax=60)) as r:
        r.start_ground()
        return r.run(Stop(takeoff=True), live=False)


def test_table_takeoff_starts_on_top_and_leaves_at_edge(backend):
    ac = TEMPLATES["conventional"]()
    ac.airfield.takeoff_from, ac.airfield.table_height, ac.airfield.table_length = "mesa", 1.5, 15.0
    o = _takeoff(backend, ac)
    L, ev = o.log, o.events
    assert L["hgnd"][0] == pytest.approx(1.5) and L["hw"][0] == pytest.approx(0.0, abs=1e-6)
    assert ev["nLO"] == pytest.approx(15.0, abs=0.5)          # sai do chão (da mesa) na borda
    w = warnings(ev, ac.airfield, landing=False)
    assert w["z_warning_decolagem"] == pytest.approx(ev["sink"]) and w["z_warning"] > 0   # caiu abaixo da mesa


def test_ground_takeoff_has_no_z_warning_and_x_warning_on_short_runway(backend):
    ac = TEMPLATES["conventional"]()
    o = _takeoff(backend, ac)
    w = warnings(o.events, ac.airfield, landing=False)
    assert w["z_warning"] == 0.0 and w["x_warning"] == 0.0
    w2 = warnings(o.events, ac.airfield, runway_max=30.0, landing=False)
    assert w2["x_warning"] == pytest.approx(o.events["nLO"] - 30.0)


def test_platform_landing(backend):
    ac = TEMPLATES["conventional"]()
    ac.airfield.landing_on = "plataforma"
    with Runner(backend, ac, None, dict(tmax=300)) as r:
        r.start_ground()
        o = r.run(Stop(), live=False, log=False)
    assert o.status.name == "COMPLETED"
    assert o.events["hgnd_td"] == pytest.approx(ac.airfield.platform_height)
    assert warnings(o.events, ac.airfield)["z_warning_pouso"] == 0.0
    ac.airfield.platform_start, ac.airfield.platform_length = 160.0, 40.0     # plataforma longe do toque
    with Runner(backend, ac, None, dict(tmax=300)) as r:
        r.start_ground()
        o = r.run(Stop(), live=False, log=False)
    assert warnings(o.events, ac.airfield)["z_warning_pouso"] > 0


def test_mission_stop_at_stage_and_series(manager):
    ac = TEMPLATES["conventional"]()
    legs = ac.mission.names()
    r = manager.run("mission", ac, {"until": f"fim: {legs[2]}"})
    assert r.status == "STOPPED"
    assert {f"xz_{legs[0]}", f"t3_{legs[1]}", "vel_V_a (em relação ao ar)"} <= set(r.series)
    assert any(k.startswith("xz_★") for k in r.series)            # eventos com estrela
    assert any(k.startswith("dh_distância máxima") for k in r.series)


def test_takeoff_mode_map_has_best_star(manager):
    ac = TEMPLATES["conventional"]()
    r = manager.run("mission", ac, {"mode": MODES[1], "sweep": True, "sR_list": "30, 40", "de1_list": "-6, -2"})
    assert r.status == "COMPLETED" and "mapa_casos" in r.series
    assert any("★" in k for k in r.series if k.startswith("mapa_"))


def test_mtow_bisection(manager):
    ac = TEMPLATES["conventional"]()
    r = manager.run("mission", ac, {"mode": MODES[3], "dm_lo": -2.0, "dm_hi": 4.0, "tol": 0.5, "act_list": "25, 35",
                                    "de1_list": "-8, -4", "dx_list": "0, 2"})
    mt = r.summary["MTOW"]
    assert np.isfinite(mt) and r.summary["massa_atual"] - 2.0 <= mt <= r.summary["massa_atual"] + 4.0
    c = r.series["mtow_casos"]
    ok, m = c["ok"] > 0, c["m"]
    assert m[ok].max() == pytest.approx(mt) and (m[~ok] > mt).all()      # tudo acima do MTOW falha


def test_simple_performance_matches_formulas(backend):
    W, S, CD0, K, CLmax = 7.32 * 9.81, 0.44, 0.0254, 0.318, 2.22
    rows, sm = backend.simple_performance(dict(W=W, S=S, CD0=CD0, K=K, CLmax=CLmax, h=900, T0=308.15,
                                               thr_V=[0, 40], thr_T=[50.1, 50.1], bank=[math.radians(30)], V_lo=5,
                                               V_hi=25, dV=0.5))
    assert sm["rho"] == pytest.approx(1.12900, abs=1e-4)                 # planilha
    i = int(np.argmin(abs(rows["V"] - 12.0)))
    CL = 2 * W / (sm["rho"] * S * 12.0 ** 2)
    assert rows["CL"][i] == pytest.approx(CL) and rows["Tr"][i] == pytest.approx(W * (CD0 + K * CL ** 2) / CL)
    assert rows["R_bank_0"][i] == pytest.approx(144 / (9.80665 * math.tan(math.radians(30))))
    assert sm["Vs"] == pytest.approx(math.sqrt(2 * W / (sm["rho"] * S * CLmax)))


def test_performance_tab(manager):
    r = manager.run("performance", TEMPLATES["conventional"](), {"method": "planilha", "h_list": "0, 1000"})
    assert "spot_h = 0 m: disponível P_d" in r.series and "scur_limite de estol (C_Lmax)" in r.series
    assert any(k.startswith("scur_★") for k in r.series)


def test_example_aircraft_folder_lists_everything():
    import os
    from aerosim.data.projects import list_folder, load_file
    root = os.path.join(os.path.dirname(__file__), "..", "..", "data", "aircraft")
    items = list_folder(root)
    assert len(items) >= 7
    names = {i.name for i in items}
    assert "Convencional — decola da mesa, pousa na plataforma" in names
    for it in items:
        assert load_file(it.path).surfaces

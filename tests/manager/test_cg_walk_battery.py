"""Missão: passeio do CG e margem estática no tempo (T04) e corrente de pico × descarga da bateria (T07)."""
import numpy as np
import pytest

from aerosim.data import load_aircraft
from aerosim.manager import flightplots as FP
from aerosim.model.catalog import Battery
from aerosim.stability.probe import Probe

AC = "data/aircraft/Convencional_original.json"


@pytest.fixture(scope="module")
def mission(manager):
    ac = load_aircraft(AC)
    return ac, manager.run("mission", ac, {})


def test_cg_walk_starts_at_the_static_cg_and_me_is_np_minus_cg(backend, mission):
    ac, r = mission
    cg, me = r.series["cgp_x_CG"]["y"], r.series["mem_margem estática"]["y"]
    with Probe(backend, ac) as pr:
        assert cg[0] == pytest.approx(pr.frac(pr.cg[0]), abs=0.5)        # mesmo referencial (% CMA do bordo de ataque)
    np_pct = r.series["cgp_ponto neutro"]["_hline"]
    assert np.allclose(me, np_pct - cg)
    assert np.ptp(cg) > 1.0                                             # a carga sai e o líquido acaba: o CG anda
    assert {"cgp", "mem"} <= {p.key for p in manager_plots(ac)}


def manager_plots(ac):
    from aerosim.manager.simulations.mission import MissionSimulation
    return MissionSimulation().plots_for(ac, {})


def test_cg_series_ignores_logs_without_cg():
    from aerosim.interfaces.backend import LogChunk
    assert FP.cg_series(LogChunk({"t": np.arange(3.0)}), {}, [], 0.0, 0.3, 30.0) == {}


def test_battery_max_current_is_c_times_capacity():
    assert Battery(capacity_mAh=2200, C_rating=40).I_max_A == pytest.approx(88.0)
    assert Battery().I_max_A == 0.0                                    # sem C informado: não há limite


def test_peak_current_check_only_with_c_rating(manager):
    ac = load_aircraft(AC)
    assert not [c for c in manager.run("mission", ac, {}).checks if "corrente de pico" in c.item]
    for C, status in ((1.0, "falha"), (500.0, "ok")):
        a = load_aircraft(AC)
        for u in a.propulsion:
            u.battery.C_rating = C
        r = manager.run("mission", a, {})
        chk = [c for c in r.checks if "corrente de pico" in c.item]
        assert len(chk) == 1 and chk[0].status == status
        assert any(k.startswith("batp_$I$ máx.") for k in r.series)
        assert "corrente_pico_A" in r.series["consumo_por_etapa"]

"""Missão: passeio do CG e margem estática no tempo (T04)."""
import numpy as np
import pytest

from aerosim.data import load_aircraft
from aerosim.manager import flightplots as FP
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

"""Simulation Manager: cada simulação com o núcleo real, checkpoints, cancelamento e
troca do backend por um falso (prova de que a camada só depende da interface)."""
import threading

import numpy as np
import pytest

from aerosim.interfaces.backend import ISimBackend, ISimSession, LogChunk, RunStatus
from aerosim.interfaces.simulation import CancelledError
from aerosim.manager import SimulationManager
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
    assert sum(len(c) for c in chunks) > 1000
    assert "etapas" in r.series


def test_mission_hits_target(manager):
    r = manager.run("mission", TEMPLATES["conventional"](), {"iters": 10})
    assert abs(r.summary["impacto_carga_n"]) < 2.0


def test_mission_resume_from_checkpoint(manager):
    ac = TEMPLATES["conventional"]()
    r1 = manager.run("mission", ac, {"until": "B (início da perna 1)"})
    assert manager.checkpoints.has("missao_B")
    r2 = manager.run("mission", ac, {"start": "B", "target": False})
    assert r2.status == "COMPLETED"
    assert r2.log["t"][0] >= r1.log["t"][-1] - 1e-9


def test_takeoff_sweep(manager):
    r = manager.run("takeoff", TEMPLATES["conventional"](), {"sweep": True, "sR_list": "30, 40", "de1_list": "-6, -3"})
    assert r.summary["restricoes"] == "ok"
    assert len(r.series["mapa"]["sR"]) == 4


def test_turn_min_radius(manager):
    r = manager.run("turn", TEMPLATES["conventional"](), {"V_list": "15", "R_list": "16, 30, 50"})
    rm = r.series["rmin"]["R_min"][0]
    assert 10 < rm <= 50


def test_envelope_and_polar(manager):
    e = manager.run("envelope", TEMPLATES["conventional"](), {"dV": 1.0})
    assert e.summary["V_max_nivelado"] > e.summary["Vs"]
    p = manager.run("polar", TEMPLATES["conventional"]())
    assert 0.05 < p.summary["static_margin"] < 0.4


def test_climb_and_thrust(manager):
    c = manager.run("climb", TEMPLATES["twin_boom"](), {"V_list": "14", "grads": "0.05, 0.1", "window": 6})
    assert np.isfinite(c.summary["gama_max"])
    t = manager.run("thrust", TEMPLATES["twin_boom"]())
    assert len(t.series) == 2 * 3          # 2 motores x 3 aceleradores


def test_cancel(manager):
    ev = threading.Event()
    ev.set()
    with pytest.raises(CancelledError):
        manager.run("mission", TEMPLATES["conventional"](), cancel=ev)


# ---------------------------------------------------------------- backend falso
class FakeSession(ISimSession):
    """núcleo de mentira: só o suficiente para a simulação de tração"""
    def configure(self, spec): self.spec = spec
    def reset_ground(self): pass
    def reset_air(self, segment): pass
    def run(self, t_limit=float("inf"), max_rows=0): return RunStatus.COMPLETED, LogChunk()
    def events(self): return {}
    @property
    def time(self): return 0.0
    def snapshot(self): return b""
    def restore(self, snap): pass
    def aero_coeffs(self, *a, **k): return {}
    def prop_point(self, index, V, thr=1.0):
        return dict(V=V, rpm=0, J=0, T=10.0 * thr - 0.1 * V, Q=0, P_shaft=0, P_elec=0, I=0, eta_prop=0)
    def mass_props(self): return {"m": 1.0, "cg": [0, 0, 0], "I": np.eye(3), "m_liq": 0}
    def trim(self, kind, V, n=1.0): return {"ok": False}
    def performance(self, V_hi, V_lo, dV): return {}
    def derived(self): return {}
    def close(self): pass


class FakeBackend(ISimBackend):
    name = "fake"
    def open_session(self): return FakeSession()
    def limits(self): return {}
    def log_channels(self): return []


def test_backend_is_swappable():
    m = SimulationManager(FakeBackend())
    r = m.run("thrust", TEMPLATES["conventional"](), {"V_max": 10, "dV": 5, "thr": "1"})
    tab = next(iter(r.series.values()))
    assert list(tab["T"]) == [10.0, 9.5, 9.0]

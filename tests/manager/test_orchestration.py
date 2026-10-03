"""Orquestração: checkpoints, retomada, cancelamento e troca do backend por um falso."""
import threading

import numpy as np
import pytest

from aerosim.interfaces.backend import ISimBackend, ISimSession, LogChunk, RunStatus
from aerosim.interfaces.simulation import CancelledError
from aerosim.manager import CheckpointStore, Runner, SimulationManager, Stop
from aerosim.model import TEMPLATES


def test_mission_resume_from_checkpoint(manager):
    ac = TEMPLATES["conventional"]()
    legs = ac.mission.names()
    r1 = manager.run("mission", ac, {"until": f"fim: {legs[0]}"})
    assert r1.status == "STOPPED" and manager.checkpoints.has(f"missão: início de {legs[1]}")
    r2 = manager.run("mission", ac, {"start": f"início: {legs[1]}", "aim": False})
    assert r2.status == "COMPLETED" and r2.log["t"][0] >= r1.log["t"][-1] - 1e-9


def test_runner_checkpoint_to_disk(backend, tmp_path):
    store = CheckpointStore(str(tmp_path))
    with Runner(backend, TEMPLATES["conventional"]()) as r:
        r.start_ground()
        r.run(Stop(autopilot=True), live=False, log=False)
        ck = r.checkpoint("A", store)
    again = CheckpointStore(str(tmp_path)).get("A")
    assert again.data == ck.data and again.t == ck.t


def test_rerun_only_changed_leg(backend):
    """mudar a perna 1 não invalida o checkpoint no começo dela"""
    ac = TEMPLATES["conventional"]()
    with Runner(backend, ac) as r:
        r.start_ground()
        r.run(Stop(segment=1), live=False, log=False)
        ck = r.checkpoint("B", CheckpointStore())
    outs = []
    for R in (40.0, 60.0):
        with Runner(backend, ac, ac.mission.with_leg(1, radius=R)) as r:
            r.start_from(ck)
            outs.append(r.run(Stop(segment=2), live=False).log)
    assert outs[0]["t"][0] == outs[1]["t"][0]
    assert outs[0]["t"][-1] < outs[1]["t"][-1]          # curva maior leva mais tempo


def test_cancel(manager):
    ev = threading.Event()
    ev.set()
    with pytest.raises(CancelledError):
        manager.run("mission", TEMPLATES["conventional"](), cancel=ev)


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


class FakeTranslator:
    name = "fake"
    def to_native(self, model, **kw): return {"name": model.name}
    def from_native(self, raw, model=None, **kw): return dict(raw)


class FakeBackend(ISimBackend):
    name = "fake"
    translator = FakeTranslator()
    def open_session(self): return FakeSession()
    def limits(self): return {}
    def log_channels(self): return []


def test_backend_is_swappable():
    m = SimulationManager(FakeBackend())
    r = m.run("thrust", TEMPLATES["conventional"](), {"V_max": 10, "dV": 5, "thr": "1"})
    assert list(next(iter(r.series.values()))["T"]) == [10.0, 9.5, 9.0]

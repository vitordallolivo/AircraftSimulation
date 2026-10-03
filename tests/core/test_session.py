"""Sessão do núcleo: corrida, fatias de tempo, checkpoint, trimagem, começo em voo."""
import math

import numpy as np

from aerosim.interfaces.backend import LogChunk, RunStatus, TrimKind
from aerosim.model import TEMPLATES
from aerosim.backend.zig.translator import native_spec


def spec(name="conventional", **kw):
    return dict(native_spec(TEMPLATES[name]()), **kw)


def test_snapshot_resume_is_exact(backend):
    with backend.open_session() as a, backend.open_session() as b:
        a.configure(spec(stop_t=5.0))
        a.reset_ground()
        st, _ = a.run()
        assert st == RunStatus.STOPPED
        snap = a.snapshot()
        a.configure(spec(stop_t=12.0))
        a.run()
        b.configure(spec(stop_t=12.0))
        b.restore(snap)
        b.run()
        assert a.events()["nLO"] == b.events()["nLO"] and a.time == b.time


def test_chunks_equal_single_run(backend):
    with backend.open_session() as s:
        s.configure(spec(stop_t=6.0))
        s.reset_ground()
        _, full = s.run()
        s.reset_ground()
        parts, st = [], RunStatus.CHUNK
        while st.can_continue:
            st, c = s.run(s.time + 0.37)
            parts.append(c)
    joined = LogChunk.concat(parts)
    assert len(full) == len(joined) and np.allclose(full["n"], joined["n"])


def test_run_without_log(backend):
    with backend.open_session() as s:
        s.configure(spec(stop_takeoff=1))
        s.reset_ground()
        st, log = s.run(max_rows=0)
        assert st == RunStatus.COMPLETED and len(log) == 0 and s.events()["nLO"] > 0


def test_trim_level(backend):
    with backend.open_session() as s:
        s.configure(spec())
        tp = s.trim(TrimKind.LEVEL, 15.0)
        assert tp["ok"] and 0 < tp["thr"] < 1 and 0 < math.degrees(tp["alpha"]) < 12


def test_reset_air_holds_altitude(backend):
    from aerosim.model.mission import level_turn
    with backend.open_session() as s:
        s.configure(native_spec(TEMPLATES["conventional"](), level_turn(15, 40), dict(stop_seg=1, env=dict(Vw10=0))))
        s.reset_air(0)
        _, log = s.run()
        assert abs(log["h"][-1] - 30.0) < 1.0

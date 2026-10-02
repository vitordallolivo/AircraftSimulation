"""Camada Sim: testes do núcleo Zig (zig build test), ABI e comparação com o C original."""
import math
import os
import shutil
import subprocess
import sys

import numpy as np
import pytest

from aerosim.backend.zig.backend import CORE, _zig_cmd
from aerosim.interfaces.backend import RunStatus, TrimKind

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def test_zig_unit_tests():
    r = subprocess.run(_zig_cmd() + ["build", "test", "--summary", "all"], cwd=CORE, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]


def test_abi_schema(backend):
    sc = backend.schema
    assert sc.abi == 1
    for name in ("Params", "Surface", "PropUnit", "LogRow", "Events", "PerfRow"):
        assert name in sc.types
    assert sc.limits["props"] >= 4 and sc.limits["tanks"] >= 4
    assert "rpm" in backend.log_channels()


def test_unknown_field_is_error(backend):
    with backend.open_session() as s, pytest.raises(KeyError):
        s.configure({"m_dry": 1.0, "nao_existe": 3})


def test_limits_are_errors(backend):
    from aerosim.backend.zig import CoreError
    with backend.open_session() as s, pytest.raises((ValueError, CoreError)):
        s.configure({"m_dry": 1.0, "tank": [{}] * 100})


def test_snapshot_resume_is_exact(backend):
    from aerosim.model import compile_aircraft
    from aerosim.model.templates import conventional
    spec = compile_aircraft(conventional())
    with backend.open_session() as a, backend.open_session() as b:
        a.configure(dict(spec, stop_t=5.0))
        a.reset_ground()
        st, _ = a.run()
        assert st == RunStatus.STOPPED
        snap = a.snapshot()
        a.configure(dict(spec, stop_t=12.0))
        a.run()
        b.configure(dict(spec, stop_t=12.0))
        b.restore(snap)
        b.run()
        assert a.events()["nLO"] == b.events()["nLO"]
        assert a.time == b.time


def test_chunks_equal_single_run(backend):
    from aerosim.model import compile_aircraft
    from aerosim.model.templates import conventional
    spec = dict(compile_aircraft(conventional()), stop_t=6.0)
    with backend.open_session() as s:
        s.configure(spec)
        s.reset_ground()
        _, full = s.run()
        s.reset_ground()
        parts = []
        st = RunStatus.CHUNK
        while st.can_continue:
            st, c = s.run(s.time + 0.37)
            parts.append(c)
        from aerosim.interfaces.backend import LogChunk
        joined = LogChunk.concat(parts)
    assert len(full) == len(joined)
    assert np.allclose(full["n"], joined["n"])


def test_trim_level(backend):
    from aerosim.model import compile_aircraft
    from aerosim.model.templates import conventional
    with backend.open_session() as s:
        s.configure(compile_aircraft(conventional()))
        tp = s.trim(TrimKind.LEVEL, 15.0)
        assert tp["ok"] and 0 < tp["thr"] < 1 and 0 < math.degrees(tp["alpha"]) < 12


@pytest.mark.skipif(shutil.which("gcc") is None or shutil.which("make") is None, reason="sem gcc/make")
def test_matches_legacy_c(backend, tmp_path):
    """o núcleo Zig reproduz a decolagem do simulador C original"""
    from legacy_spec import legacy_modules, spec_from_legacy
    subprocess.run(["make", "-s", "-C", os.path.join(ROOT, "legacy")], check=True)
    aeronave, P, S = legacy_modules()
    av = aeronave.padrao()
    av["escalares"].update(sR=37.5, de1=-3.0, ap_CL0=0.3978553031358884, ap_CLa=4.74713820002484)
    cfg = str(tmp_path / "leg.cfg")
    S.escreve_cfg(av, P.circuito(), cfg)
    ref = S.decolagem(cfg)
    with backend.open_session() as s:
        s.configure(dict(spec_from_legacy(av, P.circuito()), stop_takeoff=1))
        s.reset_ground()
        s.run()
        ev = s.events()
    for k_new, k_old in (("tR", "tR"), ("tLO", "tLO"), ("nLO", "nLO"), ("VLO", "VLO"), ("tHt", "tHt"),
                         ("nHt", "nHt"), ("Ipeak", "Ipico")):
        assert ev[k_new] == pytest.approx(ref[k_old], rel=2e-4, abs=2e-3), k_new
    _ = sys

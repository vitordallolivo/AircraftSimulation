"""Testes unitários do núcleo Zig, um por grupo (zig build test-<grupo>)."""
import subprocess

import pytest

from aerosim.backend.zig.backend import CORE, _zig_cmd


def zig(step):
    r = subprocess.run(_zig_cmd() + ["build", step, "--summary", "all"], cwd=CORE, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]
    return r.stderr


@pytest.mark.lut
def test_math_luts_and_polynomials():
    """sin/cos, atan, exp, log por tabela/polinômio, vetores SIMD e o polinômio de tração em comptime"""
    zig("test-math")


def test_physics():
    zig("test-physics")


def test_control():
    zig("test-control")


def test_sim():
    zig("test-sim")

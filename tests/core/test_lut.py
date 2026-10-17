"""Só as LUTs: exatidão e tempo, isoladas do resto da simulação (via aerosim_bench_math)."""
import ctypes
import time

import pytest

KINDS = {"sin_lut256": 0, "sin_ref": 1, "sin_lut4096": 2, "sin_lut65536": 3, "atan2_lut": 4, "atan2_ref": 5,
         "exp_lut": 6, "exp_ref": 7, "log_lut": 8, "log_ref": 9, "sin_minimax": 10, "exp_estrin": 11}


@pytest.fixture(scope="module")
def bench(backend):
    f = backend._lib.dll.aerosim_bench_math
    f.restype = ctypes.c_double
    f.argtypes = [ctypes.c_int32, ctypes.c_uint64, ctypes.c_int32]
    return f


def timed(f, kind, n=2_000_000, random=1):
    f(KINDS[kind], 1000, random)            # aquece (tabelas no cache)
    best = 1e9
    for _ in range(3):
        t0 = time.perf_counter()
        f(KINDS[kind], n, random)
        best = min(best, time.perf_counter() - t0)
    return best / n * 1e9


@pytest.mark.lut
@pytest.mark.parametrize("lut,ref", [("sin_lut256", "sin_ref"), ("sin_lut4096", "sin_ref"),
                                     ("sin_lut65536", "sin_ref"), ("atan2_lut", "atan2_ref"),
                                     ("exp_lut", "exp_ref"), ("log_lut", "log_ref"),
                                     ("sin_minimax", "sin_ref"), ("exp_estrin", "exp_ref")])
@pytest.mark.parametrize("random", [0, 1])
def test_lut_same_result_as_std(bench, lut, ref, random):
    """somas de 100 mil chamadas iguais às da std (mesmas entradas)"""
    a, b = bench(KINDS[lut], 100_000, random), bench(KINDS[ref], 100_000, random)
    assert a == pytest.approx(b, rel=1e-9, abs=1e-6)


@pytest.mark.lut
def test_fast_math_flag(backend):
    backend._lib.dll.aerosim_fast_math.restype = ctypes.c_int32
    assert backend._lib.dll.aerosim_fast_math() in (0, 1)


@pytest.mark.bench
@pytest.mark.lut
def test_lut_timing(bench):
    """tabelas pequenas (2 KB) e grandes (512 KB) contra a std; imprime ns/chamada"""
    res = {k: timed(bench, k) for k in KINDS}
    for k, v in res.items():
        print(f"{k:14s} {v:6.2f} ns")
    assert res["sin_lut256"] < res["sin_ref"]
    assert res["exp_lut"] < res["exp_ref"]
    # tabela de 2 KB não deve perder para a de 512 KB (cache)
    assert res["sin_lut256"] <= 1.2 * res["sin_lut65536"]


@pytest.mark.bench
def test_dynamics_timing(backend):
    """custo de uma avaliação de f(t, x) no estado de voo"""
    from aerosim.model import TEMPLATES
    from aerosim.backend.zig.translator import native_spec
    f = backend._lib.dll.aerosim_bench_dynamics
    f.restype = ctypes.c_double
    f.argtypes = [ctypes.c_int32, ctypes.c_uint64]
    with backend.open_session() as s:
        s.configure(dict(native_spec(TEMPLATES["conventional"]()), stop_t=10))
        s.reset_ground()
        s.run(max_rows=0)
        n = 100_000
        t0 = time.perf_counter()
        f(s._slot, n)
        dt = (time.perf_counter() - t0) / n * 1e9
    print(f"f(t, x): {dt:.0f} ns")
    assert dt < 20_000

"""Esquema do ABI gerado em comptime e o mapeamento dicionário -> struct."""
import pytest

from aerosim.backend.zig import CoreError
from aerosim.model.catalog import POLY_TERMS


def test_schema(backend):
    sc = backend.schema
    assert sc.abi == 1
    for name in ("Params", "Surface", "PropUnit", "LogRow", "Events", "PerfRow"):
        assert name in sc.types
    assert sc.limits["props"] >= 4 and sc.limits["tanks"] >= 4
    assert "rpm" in backend.log_channels()


def test_poly_terms_match_python(backend):
    """a ordem p00, p10, p01, ... gerada em comptime é a que o Python usa"""
    assert backend.schema.poly_terms == POLY_TERMS
    assert backend.schema.limits["poly_coef"] == len(POLY_TERMS)


def test_unknown_field_is_error(backend):
    with backend.open_session() as s, pytest.raises(KeyError):
        s.configure({"m_dry": 1.0, "nao_existe": 3})


def test_limits_are_errors(backend):
    with backend.open_session() as s, pytest.raises((ValueError, CoreError)):
        s.configure({"m_dry": 1.0, "tank": [{}] * 100})


def test_bad_mass_is_error(backend):
    with backend.open_session() as s, pytest.raises(CoreError):
        s.configure({"m_dry": -1.0})


def test_slots_are_released(backend):
    lim = backend.limits()["instances"]
    for _ in range(3 * lim):
        backend.open_session().close()


def test_schema_hash_matches_the_core(backend):
    """o hash FNV-1a que o núcleo calcula em comptime é o do texto que o Python recebeu"""
    import ctypes
    from aerosim.backend.zig import abi as zabi
    from aerosim.backend.zig.backend import _Lib
    lib = _Lib.get()
    L = lib.dll
    L.aerosim_schema_hash.restype = ctypes.c_uint64
    assert int(L.aerosim_schema_hash()) == lib.schema.hash == zabi.fnv1a64(L.aerosim_schema())
    assert set(zabi.REQUIRED) <= set(lib.schema.structs)


def test_old_library_gives_a_clear_message():
    """biblioteca de outra versão (sem uma struct que o Python usa, ou com o texto truncado): AbiMismatch dizendo
    o que falta, não um KeyError lá na frente"""
    import pytest
    from aerosim.backend.zig import abi as zabi
    from aerosim.backend.zig.backend import _Lib
    text = _Lib.get().dll.aerosim_schema()
    old = text.replace(b"struct SizingOut ", b"struct SizingOutVelha ")
    with pytest.raises(zabi.AbiMismatch, match="SizingOut"):
        zabi.check(zabi.parse(old.decode()), old, None)
    with pytest.raises(zabi.AbiMismatch, match="corrompido"):
        zabi.check(zabi.parse(text.decode()), text[:-10], zabi.fnv1a64(text))
    assert zabi.fnv1a64(b"") == 0xcbf29ce484222325 and zabi.fnv1a64(b"a") == 0xaf63dc4c8601ec8c   # vetores do FNV

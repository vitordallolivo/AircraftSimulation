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

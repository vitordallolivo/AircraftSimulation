"""Formatos .json, .cfg, .xlsx da aeronave e do catálogo (ida e volta idêntica)."""
import numpy as np
import pytest

from aerosim.data import load_aircraft, load_catalog, save_aircraft, save_catalog
from aerosim.backend.zig.translator import native_spec
from aerosim.model import TEMPLATES, builtin_catalog
from aerosim.model.catalog import ThrustPoly


def _flat(d, p=""):
    if isinstance(d, dict):
        for k, v in d.items():
            yield from _flat(v, f"{p}.{k}")
    elif isinstance(d, list):
        for i, v in enumerate(d):
            yield from _flat(v, f"{p}[{i}]")
    else:
        yield p, d


def same_spec(a, b):
    A, B = dict(_flat(a)), dict(_flat(b))
    assert A.keys() == B.keys()
    for k in A:
        assert np.isclose(A[k], B[k], rtol=1e-12, atol=1e-14), k


@pytest.mark.parametrize("ext", ["json", "cfg", "xlsx"])
@pytest.mark.parametrize("name", list(TEMPLATES))
def test_aircraft_roundtrip(tmp_path, name, ext):
    ac = TEMPLATES[name]()
    p = str(tmp_path / f"a.{ext}")
    save_aircraft(ac, p)
    same_spec(native_spec(ac), native_spec(load_aircraft(p)))


@pytest.mark.parametrize("ext", ["json", "cfg", "xlsx"])
def test_catalog_roundtrip(tmp_path, ext):
    c = builtin_catalog()
    c.thrust_sets.append(ThrustPoly("conjunto X", [float(i) for i in range(21)], gain=0.9, T0=30.0))
    p = str(tmp_path / f"c.{ext}")
    save_catalog(c, p)
    d = load_catalog(p)
    assert [m.name for m in d.motors] == [m.name for m in c.motors]
    for a, b in zip(c.propellers, d.propellers):
        assert np.allclose(a.CT, b.CT) and np.allclose(a.J, b.J)
    assert d.thrust_sets[0].coefs == c.thrust_sets[0].coefs and d.thrust_sets[0].gain == 0.9


def test_unknown_format(tmp_path):
    with pytest.raises(ValueError):
        save_aircraft(TEMPLATES["conventional"](), str(tmp_path / "a.doc"))

"""Tração por polinômio (poly55) no núcleo: mesma conta do Python, acelerador, densidade."""
import pytest

from aerosim.model import TEMPLATES
from aerosim.backend.zig.translator import native_spec
from aerosim.model.catalog import ThrustPoly


def poly_aircraft(**kw):
    ac = TEMPLATES["conventional"]()
    c = [0.0] * 21
    c[0], c[1], c[2], c[3], c[4], c[5] = 30.0, -0.5, 1.0, -0.03, 0.02, -0.4   # p00 p10 p01 p20 p11 p02
    ac.propulsion[0].thrust_model = "poly"
    ac.propulsion[0].thrust_poly = ThrustPoly("teste", c, **kw)
    return ac


@pytest.mark.parametrize("x,y", [("V", "none"), ("V", "throttle"), ("V", "rho"), ("V", "h")])
@pytest.mark.parametrize("V", [0.0, 7.0, 15.0])
@pytest.mark.parametrize("thr", [0.3, 1.0])
def test_core_matches_python(backend, x, y, V, thr):
    ac = poly_aircraft(x_var=x, y_var=y)
    with backend.open_session() as s:
        s.configure(native_spec(ac))
        Tc = s.prop_point(0, V, thr)["T"]
    assert Tc == pytest.approx(ac.propulsion[0].thrust_poly.thrust(V, thr, 0.0, ac.environment.rho), rel=1e-12,
                               abs=1e-12)


def test_density_exponent(backend):
    ac = poly_aircraft(rho_exp=1.0)
    ac.environment.rho = 1.0
    with backend.open_session() as s:
        s.configure(native_spec(ac))
        T = s.prop_point(0, 5.0, 1.0)["T"]
    assert T == pytest.approx(ac.propulsion[0].thrust_poly.thrust(5.0, 1.0, 0, 1.0))
    assert T == pytest.approx((30 - 2.5 - 0.75) / 1.225)


def test_flies_with_poly(backend):
    ac = poly_aircraft()
    with backend.open_session() as s:
        s.configure(dict(native_spec(ac), stop_takeoff=1))
        s.reset_ground()
        s.run(max_rows=0)
        assert s.events()["completed"] == 1

"""Geometria: painéis (áreas, cortes nos comandos, sinais dos comandos), malhas, arraste."""
import pytest

from aerosim.model import TEMPLATES
from aerosim.backend.zig.translator import native_spec
from aerosim.backend.zig.translator import surface_panels
from aerosim.model.geometry import aircraft_meshes, component_position, move_component
from aerosim.model.universal import build_model


@pytest.mark.parametrize("name", list(TEMPLATES))
def test_panel_area_matches_surfaces(name):
    ac = TEMPLATES[name]()
    panels = native_spec(ac)["surf"]
    for g, role in ((0, "wing"), (1, "htail"), (2, "vtail")):
        S_p = sum(p["S"] for p in panels if p["group"] == g)
        S_s = sum(s.area for s in ac.surfaces if s.role == role and s.enabled)
        assert S_p == pytest.approx(S_s, rel=1e-9)


def test_panels_split_at_control_edges():
    w = build_model(TEMPLATES["conventional"]()).wing
    ps = [p for p in surface_panels(w) if p["side"] == 1]
    assert len(ps) == 2 and ps[0]["tau"] == 0 and ps[1]["tau"] == 0.5


@pytest.mark.parametrize("name", list(TEMPLATES))
def test_control_and_stability_signs(backend, name):
    """mesma convenção para leme, cauda em V, elevon; estável em guinada"""
    with backend.open_session() as s:
        s.configure(native_spec(TEMPLATES[name]()))
        c0 = s.aero_coeffs(14, 0.05)
        f = lambda **kw: s.aero_coeffs(14, 0.05, **kw)
        assert f(da=0.1)["Cl"] - c0["Cl"] > 0
        assert f(de=0.1)["Cm"] - c0["Cm"] < 0
        assert f(beta=0.1)["Cn"] - c0["Cn"] > 0
        if name != "flying_wing":
            assert f(dr=0.1)["Cn"] - c0["Cn"] < 0


@pytest.mark.parametrize("name", list(TEMPLATES))
def test_meshes_are_finite_and_bounded(name):
    import numpy as np
    for key, parts in aircraft_meshes(TEMPLATES[name]()).items():
        for (V, F), _ in parts:
            assert np.isfinite(V).all() and np.abs(V).max() < 5.0, key
            assert F.max() < len(V)


def test_move_component_and_tail_on_boom():
    ac = TEMPLATES["twin_boom"]()
    move_component(ac, "prop:1", [0.2, 0.7, -0.05])
    assert list(component_position(ac, "prop:1")) == pytest.approx([0.2, 0.7, -0.05])
    ac.boom.length += 0.2
    ac.apply_constraints()
    vt = ac.surface("htail")
    assert vt.x == pytest.approx(ac.boom.x_end + vt.sections[0].chord)

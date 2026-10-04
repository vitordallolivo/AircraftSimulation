"""mistura de comandos: o tipo é só nome; elevon, ruddervator e flaperon saem da mistura"""
import copy

import pytest

from aerosim.backend.zig.translator import surface_panels
from aerosim.model.aircraft import ControlSurface, panel_mix
from aerosim.model.features import features
from aerosim.model.templates import TEMPLATES
from aerosim.model.universal import build_model


def _panels(ac):
    return [p for s in build_model(ac).surfaces for p in surface_panels(s)]


def test_kind_and_explicit_mix_are_the_same():
    a = TEMPLATES["flying_wing"]()
    b = copy.deepcopy(a)
    for s in b.surfaces:
        for c in s.controls:
            if c.kind == "elevon":
                c.kind, c.mix = "meu comando", [1.0, 1.0, 0.0]
    assert [p["mix"] for p in _panels(a)] == [p["mix"] for p in _panels(b)]
    assert features(b).pitch_kind == "elevon" and features(b).roll_kind == "elevon"


def test_panel_mix_signs():
    assert panel_mix((0, 1, 0), 1) == [0, -1, 0] and panel_mix((0, 1, 0), -1) == [0, 1, 0]
    assert panel_mix((0, 0, 1), 0) == [0, 0, -1]                      # leme no plano de simetria
    assert panel_mix((1, 0, 1), 1) == [1, 0, -1]                      # ruddervator
    assert panel_mix((0.5, 1, 0), -1) == [0.5, 1, 0]                  # elevon com mais rolagem


def test_flaperon_rolls_and_holds_a_fixed_deflection():
    ac = TEMPLATES["conventional"]()
    w = ac.wing
    base = _panels(ac)
    for c in w.controls:
        if c.kind == "aileron":
            c.kind, c.deflection = "flaperon", 10.0
    fl = _panels(ac)
    changed = [(p, q) for p, q in zip(base, fl) if p["incidence"] != q["incidence"]]
    assert changed and all(q["incidence"] > p["incidence"] and q["mix"] == p["mix"] for p, q in changed)
    assert ControlSurface("flaperon").role == "aileron" and ControlSurface("flap").role == "flap"


def test_airfoil_per_section():
    """sem perfil nas seções: igual a antes; com perfil na ponta: as faixas mudam até ela e o 3D usa o perfil"""
    from aerosim.model.airfoil import Airfoil
    from aerosim.model.geometry import aircraft_meshes
    ac = TEMPLATES["conventional"]()
    before = _panels(ac)
    w = ac.wing
    tip = max(w.sections, key=lambda q: q.y)
    tip.airfoil = Airfoil("NACA 0012", cl_alpha=5.7, cl_max=1.2, cd0=0.009)
    after = _panels(ac)
    wing_p = [(p, q) for p, q in zip(before, after) if abs(p["r"][2] - q["r"][2]) < 1e-12 and p["CLa"] != q["CLa"]]
    assert wing_p                                                       # as faixas da asa mudam
    m = build_model(ac).surfaces[0]
    assert m.strip_airfoils and m.strip_airfoils[-1].name == "NACA 0012"
    assert len(aircraft_meshes(ac)["surface:0"]) > 2                     # uma malha por faixa
    tip.airfoil = None
    assert _panels(ac) == before


def test_tilt_range_reaches_the_core():
    """eixo móvel: a faixa chega ao núcleo (o giro pelo comando é testado no núcleo)"""
    import math
    from aerosim.backend.zig import ZigBackend
    ac = TEMPLATES["twin_boom"]()
    for u in ac.propulsion:
        u.tilt_range = 90.0
    be = ZigBackend()
    s = be.open_session()
    s.configure(be.translator.to_native(build_model(ac)))
    d = s.derived()
    assert d["prop"][0]["tilt_range"] == pytest.approx(math.pi / 2) and d["pilot"]["tilt"] == 0.0
    s.close()

"""Dimensionamento inicial: equações e a aba."""
import math

import numpy as np
import pytest

from aerosim.sizing import AeroModel, Requirements, design_point, required_tw
from aerosim.sizing.constraints import stall_ws


def test_cruise_minimum_drag_point():
    # T/W de cruzeiro é mínimo em W/S = q √(C_D0/k) e vale 2 √(C_D0 k)
    r, a = Requirements(V_cruise=20.0), AeroModel(CD0=0.03, k=0.05)
    q = 0.5 * r.rho * 400
    ws = np.linspace(20, 600, 20001)
    tw = required_tw("cruzeiro", ws, r, a)
    assert ws[np.argmin(tw)] == pytest.approx(q * math.sqrt(0.03 / 0.05), rel=1e-3)
    assert tw.min() == pytest.approx(2 * math.sqrt(0.03 * 0.05), rel=1e-4)


def test_design_point_feasible():
    r, a = Requirements(), AeroModel()
    dp = design_point(r, a)
    assert dp["ws"] <= stall_ws(r, a) + 1e-9
    for k in ("decolagem", "subida", "cruzeiro", "curva"):
        assert required_tw(k, [dp["ws"]], r, a)[0] <= dp["tw"] + 1e-9


def test_sizing_tab(manager):
    from aerosim.model.templates import flying_wing
    r = manager.run("sizing", flying_wing(), {})
    assert any(c.item == "ponto de projeto (menor motor que atende tudo)" for c in r.checks)
    assert any(k.startswith("c_") for k in r.series)
    keys = {p.key for p in manager.get("sizing").parameters_for(flying_wing(), {"polar": "manual"})}
    assert "CD0" in keys

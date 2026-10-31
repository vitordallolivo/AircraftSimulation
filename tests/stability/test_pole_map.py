"""O mapa dos polos da aba Estabilidade (`_pole_series`): um ponto por V para cada modo, a faixa instável e a reta
de ζ mínimo, que passa pela origem com Re/Im = −ζ/√(1 − ζ²)."""
import math

import pytest

from aerosim.manager.simulations.stability import SLOW_MODES, _pole_series
from aerosim.stability.criteria import Criteria


def _rows():
    rows = []
    for V, (re_sp, im_sp) in ((12.0, (-8.0, 9.0)), (16.0, (-10.0, 10.0))):
        row = {"V": V}
        for name in ("curto_periodo", "fugoide", "dutch_roll", "rolamento", "espiral"):
            row[f"re_{name}"], row[f"im_{name}"] = float("nan"), float("nan")
        row.update(re_curto_periodo=re_sp, im_curto_periodo=im_sp, re_espiral=0.1, im_espiral=0.0,
                   re_dutch_roll=-1.5, im_dutch_roll=5.0)
        rows.append(row)
    return rows


def test_pole_map_points_span_and_damping_line():
    crit = Criteria()
    series = _pole_series(_rows(), crit)
    assert list(series["p_curto período"]["re"]) == [-8.0, -10.0]
    assert "p_fugóide" not in series                          # sem polo: sem série
    assert series["p_instável (Re > 0)"]["_vspan"][0] == 0.0
    line = series[f"p_ζ = {crit.sp_zeta_min:g} (curto período)"]
    zeta = crit.sp_zeta_min
    assert line["re"][1] / line["im"][1] == pytest.approx(-zeta / math.sqrt(1 - zeta ** 2))
    slow = _pole_series(_rows(), crit, SLOW_MODES, "q_")
    assert "q_curto período" not in slow and list(slow["q_espiral"]["re"]) == [0.1, 0.1]


def test_release_moves_each_pole_from_with_to_without_payload():
    """ao soltar a carga: um par de pontos por V (com → sem) e o traço entre eles, cortado por NaN a cada par"""
    import numpy as np
    from aerosim.manager.simulations.stability import _release_check, _release_series
    before = _rows()
    after = [dict(row, re_curto_periodo=row["re_curto_periodo"] - 1.0) for row in before]
    series = _release_series(before, after)
    assert list(series["s_curto período: sem carga"]["re"]) == [-9.0, -11.0]
    moved = series["s_curto período: movimento"]["re"]
    assert list(moved[:2]) == [-8.0, -9.0] and np.isnan(moved[2])
    status, item, value, *_ = _release_check(before, after, 16.0)
    assert status == "info" and value.startswith("curto período: ζ 0.71 → 0.74")   # −10 + 10i → −11 + 10i

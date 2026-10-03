"""Estabilidade: estática, tesoura, modos/MIL-F-8785C e comandos."""
import math

import numpy as np
import pytest

from aerosim.model.templates import conventional
from aerosim.stability import (Probe, aileron_sizing, analytic_np, limits, mil_check, modes, scale_htail,
                               static_analysis, time_to_bank)


@pytest.fixture(scope="module")
def probe(backend):
    with Probe(backend, conventional()) as p:
        yield p


def test_neutral_point_numeric_vs_analytic(probe):
    st, _ = static_analysis(probe, 15.0)
    assert st["margem estática (% CMA)"] > 0
    assert st["x_np numérico (% CMA)"] == pytest.approx(st["x_np analítico (% CMA)"], abs=8.0)
    assert st["C_mα (1/rad)"] == pytest.approx(-st["C_Lα (1/rad)"] * st["margem estática (% CMA)"] / 100, rel=5e-3)


def test_bigger_tail_moves_aft_limit(backend):
    ac = conventional()
    lim = []
    for k in (0.6, 1.0, 1.6):
        with Probe(backend, scale_htail(ac, k)) as p:
            lim.append(limits(p, 15.0, 0.05, 0.9, math.radians(20), 12.0, 10.0))
    aft = [l["aft"] for l in lim]
    fwd = [l["fwd_ctrl"] for l in lim]
    assert aft[0] < aft[1] < aft[2]
    assert fwd[0] > fwd[2]


def test_scale_htail_area():
    ac = conventional()
    a0 = next(s for s in ac.surfaces if s.role == "htail").area
    a1 = next(s for s in scale_htail(ac, 1.5).surfaces if s.role == "htail").area
    assert a1 == pytest.approx(1.5 * a0)


def test_modes_classification_textbook():
    # matriz com modos conhecidos (blocos 2×2 de cada modo, desacoplados)
    A = np.zeros((8, 8))
    lon, lat = [0, 2, 4, 7], [1, 3, 5, 6]
    def pair(idx, wn, z):
        i, j = idx
        A[i, j] = 1.0
        A[j, i] = -wn * wn
        A[j, j] = -2 * z * wn
    pair((lon[0], lon[3]), 0.5, 0.08)      # fugóide
    pair((lon[1], lon[2]), 6.0, 0.6)       # curto período
    pair((lat[0], lat[2]), 3.0, 0.2)       # dutch roll
    A[lat[1], lat[1]] = -5.0               # rolamento τ = 0,2 s
    A[lat[3], lat[3]] = 0.02               # espiral instável
    m = modes(A)
    assert m["curto_periodo"]["wn"] == pytest.approx(6.0) and m["curto_periodo"]["zeta"] == pytest.approx(0.6)
    assert m["fugoide"]["wn"] == pytest.approx(0.5)
    assert m["dutch_roll"]["zeta"] == pytest.approx(0.2)
    assert m["rolamento"]["tau"] == pytest.approx(0.2)
    assert m["espiral"]["t_double"] == pytest.approx(math.log(2) / 0.02)
    rows = {r["criterio"]: r["nivel"] for r in mil_check(m, "I", "B")}
    assert rows["ζ curto período"] == 1 and rows["ζ fugóide"] == 1
    assert rows["espiral: tempo para dobrar (s)"] == 1          # 34,7 s ≥ 20 s


def test_time_to_bank():
    # sem atraso (τ → 0): t = φ / P
    assert time_to_bank(1.0, 1e-6, 0.5) == pytest.approx(0.5, abs=1e-4)
    # com τ: φ(t) = P (t − τ (1 − e^{−t/τ}))
    t = time_to_bank(2.0, 0.5, 1.0)
    assert 2.0 * (t - 0.5 * (1 - math.exp(-t / 0.5))) == pytest.approx(1.0, abs=1e-6)


def test_aileron_strip_theory_vs_core(probe):
    o, s = aileron_sizing(probe, 15.0)
    assert o["C_lδa atual (faixas)"] == pytest.approx(o["C_lδa atual (núcleo)"], rel=0.15)
    t = s["t_ca/c=0.25"]
    assert (np.diff(t) > 0).all()          # aileron menor (η_i maior) → mais lento


def test_analytic_np_exists():
    assert math.isfinite(analytic_np(conventional())["x_np"])


def test_criteria_from_norm_and_custom():
    from aerosim.stability.criteria import evaluate, mil_8785c
    c = mil_8785c("I", "A")
    assert c.sp_zeta_min == 0.35 and c.dr_zeta_min == 0.19 and c.roll_t == 1.3
    m = {"espiral": {"re": 0.05, "im": 0.0, "t_double": math.log(2) / 0.05}}
    c.spiral_t2_min = 10.0
    assert next(r for r in evaluate(m, c) if "espiral" in r["criterio"])["ok"]
    c.spiral_t2_min = 20.0
    assert not next(r for r in evaluate(m, c) if "espiral" in r["criterio"])["ok"]


def test_custom_criteria_change_verdict(manager):
    from aerosim.model.templates import conventional
    sim = manager.get("stability")
    keys = {p.key for p in sim.parameters_for(conventional(), {"norm": "personalizado"})}
    assert "crit_spiral_t2_min" in keys and "cls" not in keys
    r = manager.run("stability", conventional(), {"norm": "personalizado", "crit_spiral_t2_min": 3.0,
                                                  "Vs_list": "15", "size_tail": False})
    sp = next(c for c in r.checks if c.item.startswith("espiral: tempo"))
    assert sp.status == "ok" and sp.source == "definido na aba"


def test_tailless_sizing(manager):
    from aerosim.model.templates import flying_wing
    r = manager.run("stability", flying_wing(), {"Vs_list": "14", "whatif": False, "CL_frac": 0.5})
    items = {c.item: c for c in r.checks}
    assert "torção na ponta (washout) para C_m0 > 0" in items
    assert "menor elevon que equilibra o pouso" in items
    assert any(k.startswith("wo_") for k in r.series) and any(k.startswith("es_") for k in r.series)


def test_no_pitch_control_is_reported(manager):
    from aerosim.model.templates import flying_wing
    ac = flying_wing()
    for s in ac.surfaces:
        s.controls = [c for c in s.controls if c.kind != "elevon"]
    r = manager.run("stability", ac, {"Vs_list": "14", "whatif": False, "size_elevon": False, "washout": False})
    c = next(c for c in r.checks if c.item == "comando de arfagem")
    assert c.status == "falha" and "elevon" in c.fix

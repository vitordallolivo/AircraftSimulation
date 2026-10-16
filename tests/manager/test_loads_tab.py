"""T12: aba Cargas (simulação "loads"): distribuição ao longo de cada superfície e a vista 3D (LoadResult)."""
import numpy as np
import pytest

from aerosim.model import modifiers as mods
from aerosim.model.templates import TEMPLATES


@pytest.fixture(scope="module")
def result(manager):
    ac = TEMPLATES["conventional"]()
    ac.modifiers.append(mods.Modifier("esteira.disco"))
    return manager.run("loads", ac, {"V": 12.0, "helice": "comparar com e sem"})


def test_series_per_surface_and_case(result):
    S = result.series
    for f in ("L", "alpha_ef", "V_rel"):
        for lab in ("com hélice", "sem hélice"):
            assert any(k.startswith(f"{f}_wing_{lab}") for k in S), (f, lab)
    assert "_result" in S["v3d"] and S["v3d"]["superfícies"]


def test_trim_and_lift_close_to_weight(result):
    assert all(c.status != "falha" for c in result.checks)
    L, nW = result.summary["[com hélice] sustentação das superfícies (N); n·peso (N)"]
    assert abs(L - nW) / nW < 0.05            # linha sustentadora × trimagem do núcleo: poucos %


def test_slipstream_raises_wing_load_behind_prop(result):
    S = result.series
    k_on = next(k for k in S if k.startswith("L_wing_com hélice"))
    k_off = next(k for k in S if k.startswith("L_wing_sem hélice"))
    on, off = S[k_on], S[k_off]
    i = int(np.argmin(np.abs(on["s"])))       # raiz da asa, atrás da hélice
    assert on["y"][i] > 1.2 * off["y"][i]
    j = int(np.argmax(on["s"]))               # ponta: fora do tubo, a esteira quase não muda nada
    assert abs(on["y"][j] - off["y"][j]) <= 0.05 * abs(off["y"][j]) + 0.5


def test_imposed_alpha_and_plots_follow_aircraft(manager):
    sim = manager.get("loads")
    fw = TEMPLATES["flying_wing"]()
    keys = [p.key for p in sim.plots_for(fw, {})]
    assert "L_wing" in keys and "L_htail" not in keys
    r = manager.run("loads", TEMPLATES["conventional"](), {"alpha_mode": "imposto", "alpha": 4.0,
                                                           "helice": "sem hélice"})
    assert abs(r.summary["[sem hélice] α (°), profundor (°)"][0] - 4.0) < 1e-9

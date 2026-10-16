"""T06: fator de carga na Missão. O gráfico "Fator de carga" mostra, além de n_z, o n que a inclinação pede
(curva nivelada, n = 1/cos φ) e o n em que a asa estola na V do momento (n_estol = n_z C_Lmax/C_L = n_z/ratioCL).
Anderson, Introduction to Flight, §6.17 (número das equações a conferir no PDF).
"""
import numpy as np
import pytest

from aerosim.model.templates import TEMPLATES


@pytest.fixture(scope="module")
def result(manager):
    return manager.run("mission", TEMPLATES["conventional"](), {})


def test_load_factor_plot_has_turn_and_stall_lines(result):
    S = result.series
    for k in ("nz_n_z", "nz_n p/ curva nivelada (1/cos φ)", "nz_n no estol (na V do momento)"):
        assert k in S, k
    assert any(k.startswith("nz_n estrutural = ") for k in S)


def test_stall_line_is_nz_over_ratio_in_flight(result):
    T = result.log
    S = result.series
    ratio = np.asarray(T["ratioCL"], float)
    nz = np.asarray(T["nz"], float)
    phi = np.asarray(T["phi"], float)
    n_st = S["nz_n no estol (na V do momento)"]["y"]
    n_tu = S["nz_n p/ curva nivelada (1/cos φ)"]["y"]
    air = np.isfinite(n_st)
    assert air.sum() > 100                                   # há voo
    np.testing.assert_allclose(n_st[air], nz[air] / ratio[air], rtol=1e-12)
    np.testing.assert_allclose(n_tu[air], 1 / np.cos(phi[air]), rtol=1e-12)
    # sem estol na missão padrão: n_z fica abaixo do n de estol
    assert np.all(nz[air] <= n_st[air] * (1 + 1e-9))


def test_turn_mode_shows_load_factor_and_stall(manager):
    from aerosim.manager.simulations.mission import MODES
    r = manager.run("mission", TEMPLATES["conventional"](), {"mode": MODES[2], "V_list": "15"})
    S = r.series
    ct = [k for k in S if k.startswith("ct_R = ")]
    assert ct and any(k.endswith("(estol)") for k in ct)
    assert "cn_V = 15 m/s — n no estol" in S
    casos = S["casos"]
    ne, nz = casos["n_estol_perm"].astype(float), casos["nz_perm"].astype(float)
    ok = np.isfinite(ne) & np.isfinite(nz)
    assert ok.any()
    # quem estola chega perto do n de estol; o n em regime nunca passa muito dele
    assert np.all(nz[ok] <= 1.05 * ne[ok])

"""Perfis: NACA 4 dígitos, leitura/escrita de .dat, teoria de perfil fino, flape."""
import numpy as np
import pytest

from aerosim.model.airfoil import Airfoil, flap_effectiveness, helmbold, naca4, read_dat, thin_airfoil, write_dat


def test_thin_airfoil_naca2412():
    a0, cm = thin_airfoil(naca4("2412"))
    assert a0 == pytest.approx(-2.08, abs=0.15)
    assert cm == pytest.approx(-0.053, abs=0.01)


def test_symmetric_airfoil_has_no_camber_effects():
    a0, cm = thin_airfoil(naca4("0012"))
    assert abs(a0) < 1e-6 and abs(cm) < 1e-6


def test_dat_roundtrip(tmp_path):
    c = naca4("4412")
    p = str(tmp_path / "a.dat")
    write_dat(p, "NACA 4412", c)
    name, d = read_dat(p)
    assert name == "NACA 4412" and np.allclose(c, d, atol=1e-6)


def test_lednicer_format(tmp_path):
    p = tmp_path / "l.dat"
    p.write_text("LEDNICER\n3. 3.\n\n0 0\n0.5 0.05\n1 0\n\n0 0\n0.5 -0.03\n1 0\n")
    _, d = read_dat(str(p))
    assert d.shape == (5, 2) and d[0, 0] == 1.0


def test_airfoil_uses_dat_file(tmp_path):
    p = str(tmp_path / "x.dat")
    write_dat(p, "X", naca4("4412"))
    af = Airfoil("qualquer", path=p)
    assert af.zero_lift_angle() == pytest.approx(thin_airfoil(read_dat(p)[1])[0])
    assert af.zero_lift_angle() == pytest.approx(-4.15, abs=0.15)      # NACA 4412, perfil fino


def test_helmbold_and_flap():
    assert helmbold(2 * np.pi, 1e6) == pytest.approx(2 * np.pi, rel=1e-4)
    assert helmbold(5.9, 6.25) < 5.9
    assert 0 < flap_effectiveness(0.1) < flap_effectiveness(0.3) < flap_effectiveness(0.6) < 1

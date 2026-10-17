"""Métodos externos: AVL (programa do Drela) e polar de avião exportada pelo XFLR5. O AVL só roda se o
executável existir; o .avl gerado, os comandos e a leitura da saída são conferidos sempre."""
import math

import numpy as np
import pytest

from aerosim.aero import AvlSolver, Xflr5PolarFile, all_solvers
from aerosim.aero.avl_solver import AvlTranslator, avl_exe
from aerosim.interfaces.aero import AeroCase, FlightPoint
from aerosim.model.templates import conventional, flying_wing
from aerosim.model.universal import build_model

# o bloco de totais que o comando ST do AVL escreve (o formato; os números são quaisquer)
ST = """
  Alpha =   2.00000     pb/2V =  -0.00000     p'b/2V =  -0.00000
  CXtot =  -0.00440     Cltot =   0.01200     Cl'tot =   0.01100
  CYtot =   0.00300     Cmtot =  -0.07148
  CZtot =  -0.37064     Cntot =  -0.00500     Cn'tot =  -0.00480
  CLtot =   0.37056
  CDtot =   0.02854
  CDvis =   0.02000     CDind = 0.0085363
"""


def _blocks(text):
    """SURFACE -> lista de linhas até o próximo SURFACE"""
    out, cur = [], None
    for ln in text.splitlines():
        if ln == "SURFACE":
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln)
    return out


def test_avl_file_has_every_surface_and_station(tmp_path):
    m = build_model(conventional())
    case = AeroCase(V=15, ref=(0.1, 0.0, 0.02), n_span=10)
    txt = AvlTranslator().to_native(m, case=case, folder=str(tmp_path))
    head = txt.splitlines()
    S, c, b = map(float, head[3].split())
    assert (S, c, b) == pytest.approx((m.S, m.c, m.b), rel=1e-5)
    assert [float(x) for x in head[4].split()] == pytest.approx([-0.1, 0.0, -0.02])     # x para trás, z para cima
    assert float(head[5]) == pytest.approx(m.parasite_cd(), rel=1e-5)
    blocks = _blocks(txt)
    assert len(blocks) == len(m.surfaces)
    for s, blk in zip(m.surfaces, blocks):
        assert blk.count("SECTION") == len(s.stations) and ("YDUPLICATE" in blk) == s.mirror
        i = blk.index("SECTION")
        x, y, z, ch, inc = map(float, blk[i + 1].split())
        q = s.stations[0]
        assert (x, y, z, ch) == pytest.approx((-q.le[0], q.le[1], -q.le[2], q.chord), abs=1e-5)
    assert "pitch" in txt                                                   # o profundor do convencional


def test_avl_commands_and_output_back_to_universal():
    m = build_model(conventional())
    cmd = AvlTranslator.commands(m, [FlightPoint(math.radians(2.0), p=0.01, r=0.02, de=math.radians(5))], "a.avl", "st")
    assert "A A 2.000000" in cmd and "R R -0.010000" in cmd and "Y Y -0.020000" in cmd and "D1 D1 5.000000" in cmd
    assert cmd.splitlines()[0] == "LOAD a.avl" and "ST st0.st" in cmd and "QUIT" in cmd
    r = AvlTranslator().from_native(ST, m)
    assert r == pytest.approx(dict(CL=0.37056, CD=0.02854, CDi=0.0085363, CY=0.003, Cm=-0.07148, Cl=-0.012,
                                   Cn=0.005))


def test_avl_flying_wing_without_naca_writes_contour(tmp_path):
    ac = flying_wing()
    ac.wing.airfoil.name, ac.wing.airfoil.coords = "meu perfil", [[1, 0], [0.5, 0.06], [0, 0], [0.5, -0.02], [1, 0]]
    txt = AvlTranslator().to_native(build_model(ac), folder=str(tmp_path))
    assert "AFILE" in txt and (tmp_path / "af0.dat").read_text().startswith("meu perfil")


def test_avl_unavailable_says_why(monkeypatch):
    monkeypatch.delenv("AVL_PATH", raising=False)
    monkeypatch.setattr("shutil.which", lambda *_: None)
    monkeypatch.setattr("aerosim.aero.avl_solver.has_optvl", lambda: False)
    assert "AVL" in AvlSolver().available()
    assert any(s.name == "avl" for s in all_solvers(None))


def _optvl():
    from aerosim.aero.avl_solver import has_optvl
    return has_optvl()


@pytest.mark.skipif(not _optvl(), reason="OptVL não instalado (pip install optvl)")
def test_avl_through_optvl_signs_match_the_core(backend, monkeypatch):
    """AVL pelo OptVL (sem o executável): sinais físicos (C_lβ < 0 com diedro, C_nβ > 0, C_lp < 0, C_nr < 0) e os
    comandos com o mesmo sinal do núcleo (antes C_lβ, C_nβ, C_lδa e C_nδr saíam invertidos e o aileron que encosta
    no flape sumia)"""
    from aerosim.aero import solver_by_name
    monkeypatch.delenv("AVL_PATH", raising=False)
    monkeypatch.setattr("aerosim.aero.avl_solver.avl_exe", lambda: None)
    m = build_model(conventional())
    case = AeroCase(V=15, alphas=np.array([2.0]), alpha_d=2.0, n_span=10)
    avl = AvlSolver().solve(m, case).derivs
    core = solver_by_name(backend, "zig").solve(m, case).derivs
    assert avl["Clb"] < 0 and avl["Cnb"] > 0 and avl["Clp"] < 0 and avl["Cnr"] < 0
    for k in ("Clda", "Cndr", "Cmde", "CYdr"):
        assert avl[k] * core[k] > 0, (k, avl[k], core[k])


@pytest.mark.skipif(avl_exe() is None, reason="AVL não instalado")
def test_avl_runs(backend):
    m = build_model(conventional())
    p = AvlSolver().solve(m, AeroCase(V=15, alphas=np.array([0.0, 4.0]), n_span=8))
    assert p.CL[1] > p.CL[0] and p.deriv("CLa") > 3 and p.deriv("Cma") < 0 and p.deriv("Cmde") < 0


XFLR5 = """xflr5 v6.61

Plane name :  Avião
Polar name :  T1-15.0 m/s-VLM2
Freestream speed : 15.000 m/s

   alpha      Beta        CL          CDi         CDv         CD          CY          Cl          Cm          Cn
"""


def _xflr5_file(tmp_path, sep=" "):
    rows = []
    for a in np.arange(-2.0, 8.01, 1.0):
        CL = 0.3 + 0.08 * a
        rows.append(sep.join(f"{v:.5f}" for v in (a, 0, CL, CL ** 2 / 25, 0.012, CL ** 2 / 25 + 0.012, 0, 0,
                                                     -0.01 - 0.02 * a, 0)))
    f = tmp_path / "T1-15_0 m_s-VLM2.txt"
    f.write_text(XFLR5 + "\n".join(rows) + "\n", encoding="utf-8")
    return f


def test_xflr5_plane_polar(tmp_path):
    f = _xflr5_file(tmp_path)
    so = Xflr5PolarFile(str(f))
    assert so.available() is None and Xflr5PolarFile("").available()
    p = so.solve(build_model(conventional()), AeroCase(alpha_d=2.0))
    assert p.fidelity == "vlm" and p.source == "arquivo T1-15_0 m_s-VLM2.txt" and "15 m/s" in p.notes
    assert p.alpha[0] == -2.0 and p.CL[2] == pytest.approx(0.3)
    assert p.deriv("CLa") == pytest.approx(0.08 * 180 / math.pi, rel=1e-3)
    assert p.deriv("Cma") == pytest.approx(-0.02 * 180 / math.pi, rel=1e-3) and math.isnan(p.deriv("Cnb"))


def test_xflr5_in_the_aerodynamics_tab(manager, tmp_path):
    f = _xflr5_file(tmp_path, ",")
    r = manager.run("aerodynamics", conventional(), dict(use_lltdrek=False, use_zig=True, use_xflr5=True,
                                                         xflr5_file=str(f), full=False, tips=False))
    assert "polar_XFLR5 (arquivo)" in r.series and r.summary["[XFLR5 (arquivo)] de onde"].startswith("arquivo")
    r = manager.run("aerodynamics", conventional(), dict(use_lltdrek=False, use_zig=True, use_xflr5=True,
                                                         xflr5_file="", full=False, tips=False))
    assert any(c.item == "XFLR5 (arquivo) indisponível" for c in r.checks)

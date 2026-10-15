"""Polar 2D dos perfis (aerosim/aero/sections.py): as fontes por ISectionPolar, o cache em memória e em
disco, e o perfil por seção chegando ao lltdrek."""
import copy
import os

import numpy as np
import pytest

from aerosim.aero import sections as sx
from aerosim.aero.lltdrek_solver import LltdrekSolver, LltdrekTranslator
from aerosim.design import airfoils as afm
from aerosim.design import wing as wg
from aerosim.interfaces.aero import AeroCase, ISectionPolar
from aerosim.model.airfoil import Airfoil
from aerosim.model.templates import conventional
from aerosim.model.universal import build_model

A = np.arange(-4.0, 10.01, 1.0)


def test_sources_follow_the_interface():
    assert set(sx.SOURCES) == {"modelo", "neuralfoil", "arquivo"}
    assert all(isinstance(s, ISectionPolar) for s in sx.SOURCES.values())
    assert sx.SOURCES["arquivo"].available(Airfoil()) and sx.SOURCES["modelo"].available(Airfoil()) is None
    assert sx.SOURCES["neuralfoil"].available(Airfoil(name="meu perfil")) is not None   # sem contorno


def test_without_outline_falls_back_to_model():
    af = Airfoil(name="só parâmetros", cl_max=1.3)
    p = sx.section_polar(af, A, 2e5, "neuralfoil")
    assert np.allclose(p["cl"], sx.model_polar(af, A)["cl"])


def test_memory_cache_returns_copies():
    sx.clear_cache()
    af = Airfoil(name="NACA 2412")
    p = sx.section_polar(af, A, 2e5)
    p["cl"][:] = 0.0                                   # quem recebe pode mexer: o guardado não muda
    assert np.ptp(sx.section_polar(af, A, 2e5)["cl"]) > 0.5


def test_changed_airfoil_is_another_entry():
    af = Airfoil(name="NACA 2412", cl_max=1.2)
    b = copy.deepcopy(af)
    b.cl_max = 1.6
    assert sx.airfoil_key(af) != sx.airfoil_key(b)
    assert np.nanmax(sx.section_polar(b, np.arange(0, 20.1, 0.5), 2e5)["cl"]) > \
        np.nanmax(sx.section_polar(af, np.arange(0, 20.1, 0.5), 2e5)["cl"]) + 0.3


def test_expensive_source_goes_to_disk(monkeypatch, tmp_path):
    """NeuralFoil é caro: a segunda vez (outra sessão, memória vazia) lê do disco sem chamar a rede"""
    pytest.importorskip("neuralfoil")
    monkeypatch.setenv("AEROSIM_CACHE", str(tmp_path))
    sx.clear_cache()
    af = Airfoil(name="NACA 4412")
    p1 = sx.section_polar(af, A, 2.5e5, "neuralfoil")
    assert list((tmp_path / "polar2d").rglob("*.npz"))
    sx.clear_cache()
    monkeypatch.setattr(sx.NeuralFoilSection, "polar", lambda *a, **k: (_ for _ in ()).throw(AssertionError("rodou")))
    p2 = sx.section_polar(af, A, 2.5e5, "neuralfoil")
    assert np.allclose(p1["cl"], p2["cl"]) and np.allclose(p1["cd"], p2["cd"])
    sx.clear_cache(disk=True)
    assert not (tmp_path / "polar2d").exists()


def test_file_source_and_design_entry(tmp_path):
    f = tmp_path / "polar.txt"
    rows = "\n".join(f"{a:.1f} {0.1 * a + 0.3:.4f} {0.02:.4f} 0.0 -0.05" for a in np.arange(-5, 11.0))
    f.write_text("Re = 0.300 e 6\n alpha CL CD CDp Cm\n" + rows + "\n")
    e = afm.AirfoilEntry(Airfoil(name="X"), "arquivo", str(f))
    p = afm.polar(e, 1e5, alphas=np.array([0.0, 2.0, 20.0]))
    assert p["source"] == "arquivo" and p["Re"] == pytest.approx(3e5)
    assert p["cl"][:2] == pytest.approx([0.3, 0.5]) and np.isnan(p["cl"][2])


def _two_airfoil_model():
    """asa convencional trocada pela trapezoidal da sprint: NACA 4412 na raiz, NACA 0012 na ponta"""
    ac = conventional()
    p = wg.WingParams(planform="tabela de seções", airfoil="NACA 4412", dihedral=0.0,
                      partitions=[wg.WingPartition(1.0, 0.32, 1.0, "NACA 4412"),
                                  wg.WingPartition(1.2, 0.32, 0.5, "NACA 0012", 0.04, -2.0)])
    w = wg.build_wing(p, afm.from_naca("NACA 4412"), af_map={"NACA 0012": afm.from_naca("NACA 0012")})
    old = ac.wing
    w.name, w.role, w.x, w.z = old.name, "wing", old.x, old.z
    ac.surfaces[ac.surfaces.index(old)] = w
    return ac


def test_stations_carry_their_airfoil():
    m = build_model(_two_airfoil_model())
    names = [q.airfoil.name for q in m.wing.stations]
    assert names[0] == "NACA 4412" and names[-1] == "NACA 0012"
    assert build_model(conventional()).wing.stations[0].airfoil is None       # perfil único: o da superfície


def test_lltdrek_writes_one_polar_per_airfoil(tmp_path):
    pytest.importorskip("lltdrek")
    m = build_model(_two_airfoil_model())
    case = AeroCase(V=15, alphas=np.array([0.0, 4.0]), n_span=8)
    wings = LltdrekTranslator().to_native(m, case=case, folder=str(tmp_path))
    w = next(x for x in wings if x.surface_name == m.wing.name)
    assert len(set(w.airfoils)) == 2 and len(os.listdir(tmp_path)) == 3     # 2 da asa + 1 da EH
    one = build_model(conventional())
    pol2 = LltdrekSolver().solve(m, case)
    pol1 = LltdrekSolver().solve(one, case)
    assert np.all(np.isfinite(pol2.CL)) and not np.allclose(pol1.CL, pol2.CL)

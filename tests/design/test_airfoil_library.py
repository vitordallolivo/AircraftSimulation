"""Perfis de data/airfoils disponíveis desde o início (Asa e Empenagem), sem passar pela etapa Perfil."""
from aerosim.design import airfoils as afm
from aerosim.design import tail as tl
from aerosim.design.project import DesignProject

MH = next(n for n in afm.library() if n.startswith("MH 113"))     # o nome é o da 1ª linha do .dat


def test_library_has_the_dat_files_except_naca():
    lib = afm.library()
    assert "HT 14" in lib and not any(n.startswith("NACA") for n in lib)
    assert all(e.airfoil.coords for e in lib.values())
    lib[MH].airfoil.cl_max = 9.0                              # devolve cópias
    assert afm.library()[MH].airfoil.cl_max != 9.0


def test_project_finds_library_airfoils():
    p = DesignProject()
    assert p.airfoil(MH) is not None and MH in p.airfoil_names()
    assert p.airfoil_names()[:len(p.airfoils)] == tuple(a.name for a in p.airfoils)   # os da etapa Perfil primeiro
    assert MH in p.airfoil_map()


def test_tail_uses_library_contour_not_a_naca_guess():
    """antes um nome fora da etapa Perfil virava NACA 0012; agora vem o contorno do .dat"""
    p = DesignProject()
    af, _ = tl.tail_entry(MH, p.airfoil_map(), 1.5e5)
    assert af.name == MH and af.coords


def test_project_airfoil_wins_over_library():
    p = DesignProject()
    e = afm.library()["HT 14"]
    e.airfoil.cl_max = 1.11
    e.source = "modelo"
    p.airfoils.append(e)
    assert p.airfoil_map()["HT 14"].airfoil.cl_max == 1.11

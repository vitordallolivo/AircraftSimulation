"""Regras de camada: o modelo da aeronave é construído uma vez (aerosim.model.universal) e cada
solver/núcleo só o recebe pelo seu tradutor; os resultados voltam no formato universal."""
import ast
import pathlib
import types

import numpy as np
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "aerosim"


def _sources():
    return [p for p in ROOT.rglob("*.py") if "__pycache__" not in p.parts]


def test_no_geometry_derivation_outside_universal_model():
    """ninguém fora do modelo universal deriva painéis/estações da configuração"""
    banned = ("compile_aircraft", "all_panels", "surface_stations", "aero_coefficients(", "wing_downwash(")
    allowed = {ROOT / "model" / "universal.py"}
    bad = [f"{p.relative_to(ROOT)}: {b}" for p in _sources() if p not in allowed
           for b in banned if b in p.read_text(encoding="utf-8")]
    assert not bad, bad


def test_native_formats_only_in_translators():
    """SimSpec do núcleo, Wing do lltdrek e Airplane do ASB só aparecem nos tradutores/adaptadores"""
    rules = {"asb.Airplane(": {"aero/asb_solver.py"}, "Wing(spans": {"aero/lltdrek_solver.py"},
             "surf=surf": {"backend/zig/translator.py"}}
    for pat, ok in rules.items():
        where = {str(p.relative_to(ROOT)) for p in _sources() if pat in p.read_text(encoding="utf-8")}
        assert where <= ok, (pat, where - ok)


def test_backends_and_solvers_take_the_universal_model(backend):
    from aerosim.aero import all_solvers
    from aerosim.interfaces.translator import IModelTranslator
    assert isinstance(backend.translator, IModelTranslator)
    for so in all_solvers(backend):
        args = list(so.solve.__code__.co_varnames[:3])
        assert args[1] == "model", (so.name, args)


def test_load_methods_take_the_universal_model(backend):
    """os métodos de carga (ILoadMethod) recebem o modelo universal e o ponto resolvido, nunca a configuração"""
    from aerosim.aero import all_load_methods
    from aerosim.interfaces.loads import ILoadMethod
    for m in all_load_methods(backend):
        assert isinstance(m, ILoadMethod)
        assert list(m.compute.__code__.co_varnames[:3]) == ["self", "model", "point"], m.name


def test_translators_return_universal_coefficients():
    from aerosim.aero.lltdrek_solver import LltdrekTranslator
    from aerosim.model.templates import conventional
    from aerosim.model.universal import build_model
    m = build_model(conventional())
    ns = types.SimpleNamespace
    gc = ns(forces=ns(CL=0.5, CD=0.02, CY=0.0), moments=ns(Cl=0.1, Cm=-0.05, Cn=0.2))
    r = LltdrekTranslator().from_native(gc, m)
    # lltdrek: momentos por S c e eixos x, z invertidos
    assert r["Cl"] == pytest.approx(-0.1 * m.c / m.b) and r["Cn"] == pytest.approx(-0.2 * m.c / m.b)
    assert r["Cm"] == -0.05 and r["CD"] == pytest.approx(0.02 + m.parasite_cd()) and r["CDi"] == 0.02
    assert set(r) >= {"CL", "CD", "CDi", "CY", "Cl", "Cm", "Cn"}

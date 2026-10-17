"""Validação contra o Navion (NASA TN D-6643, Suit 1972): geometria da Tabela I e derivadas do núcleo contra as
tiradas do voo (Tabelas VII e XI, condição I: 73,2 m/s, flape 0). Ferramenta: tools/validacao/navion.py.

O que o núcleo acerta hoje fica travado aqui (número do voo escrito). O que está longe é lacuna conhecida, sem teste
de faixa (de 16/10/2026, núcleo por faixas):
    C_mα  −1,31 contra −0,77: estável demais; falta a fuselagem (o programa não estima C_mα, C_nβ, C_Yβ dela)
    C_Yβ  −0,22 contra −0,60: idem (fuselagem)
    C_lβ  −0,14 contra −0,07: erro do núcleo (o AVL, também sem fuselagem, dá −0,079)
    C_Lq  4,8 contra 15,9 (AVL 9,5): o núcleo parece contar só a cauda; C_lδa 0,23 contra 0,15 (AVL 0,185)
"""
import math
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools", "validacao"))

import navion  # noqa: E402


def test_geometry_matches_table_I():
    from aerosim.model.universal import build_model
    m = build_model(navion.aircraft())
    assert m.S == pytest.approx(17.112, rel=0.005)            # área da asa [T1]
    assert m.b == pytest.approx(10.17, rel=0.005)             # √(A S), A = 6,04 [T1]; a Figura 2 diz 10,20
    assert m.c == pytest.approx(1.74, rel=0.01)               # CMA [T1]
    assert navion.isa_rho(1525.0) == pytest.approx(1.0556, rel=1e-3)


@pytest.fixture(scope="module")
def core(backend):
    from aerosim.aero import solver_by_name
    rows = navion.compare(backend, "I", [solver_by_name(backend, "zig")])
    return rows[0]["derivs"]


@pytest.mark.parametrize("key,tol", [("CLa", 0.15), ("CLde", 0.10), ("Cmde", 0.10), ("Cnb", 0.30), ("Cnr", 0.20),
                                     ("Clr", 0.20), ("Clp", 0.30), ("Cmq", 0.35), ("Cndr", 0.25)])
def test_core_derivatives_close_to_flight(core, key, tol):
    flight = navion.FLIGHT["I"][key]
    assert math.isfinite(core[key])
    assert abs(core[key] - flight) <= tol * abs(flight), (key, core[key], flight)

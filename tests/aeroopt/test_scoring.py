"""aeroopt: arquivos de pontuação (O01). As notas calculadas à mão ficam no teste do núcleo (O03)."""
import glob
import os

import pytest

from aeroopt.scoring import (
    LOAD,
    MAX_OPS,
    PONTUACAO,
    STORE,
    TIER,
    Objective,
    ScoringError,
    ScoringFile,
    listing,
    scoring_for,
)


def _write(tmp_path, body):
    f = tmp_path / "t.toml"
    f.write_text('entradas = ["a", "b"]\n' + body, encoding="utf-8")
    return str(f)


def test_every_file_in_the_folder_compiles_with_a_source():
    files = glob.glob(os.path.join(PONTUACAO, "*.toml"))
    assert files
    for f in files:
        sc = ScoringFile(f)
        assert sc.source and len(sc.program()["ops"]) <= MAX_OPS


def test_micro_2026_program_shape():
    sc = scoring_for("sae_br_2026_micro")
    assert sc.quantities() == ["c_lapes", "c_liq", "pv", "m_bat", "s_to", "b"]
    p = sc.program()
    assert list(p["parts"]) == ["cp_m", "ee", "f_bat", "p_m", "pd"]
    assert p["tiers"] == [dict(limits=[1.0, 4.0, 8.0], values=[250.0, 170.0, 110.0], outside=0.0)]
    assert p["slots"][p["score"]] == "nota" and len(p["valid"]) == 4
    assert TIER in p["ops"] and "LOAD s_to\nTIER 0\nSTORE f_dec" in listing(p)
    # cada vaga é escrita uma vez e só lida depois de escrita
    written = set(range(p["n_inputs"]))
    for op, a in zip(p["ops"], p["args"]):
        if op == LOAD:
            assert a in written
        if op == STORE:
            assert a not in written
            written.add(a)


@pytest.mark.parametrize("body, msg", [
    ('[termos]\nx = "a + c"\n[nota]\nexpressao = "x"\n', "não definido"),
    ('[termos]\nx = "y"\ny = "a"\n[nota]\nexpressao = "x"\n', "não definido"),
    ('[termos]\nx = "sin(a)"\n[nota]\nexpressao = "x"\n', "só números"),
    ('[termos]\nx = "a if b else 1"\n[nota]\nexpressao = "x"\n', "só números"),
    ('[termos]\na = "b"\n[nota]\nexpressao = "a"\n', "repetido"),
    ('[termos]\nx = "a"\n', "nota"),
    ('[faixas.f]\ngrandeza = "a"\nlimites = [2, 1]\nvalores = [1, 2]\n[nota]\nexpressao = "f"\n', "crescentes"),
    ('[nota]\nexpressao = "a"\n[[validade]]\nexpressao = "a"\nop = "<"\nvalor = 1\n', "operador"),
])
def test_bad_files_are_refused(tmp_path, body, msg):
    with pytest.raises(ScoringError, match=msg):
        ScoringFile(_write(tmp_path, body))


def test_simple_objective():
    o = scoring_for("MTOW")
    assert isinstance(o, Objective) and o.quantities() == ["mtow"] and o.program()["score"] == 1


def _micro(m):
    """a nota da Micro 2026 escrita à mão a partir do regulamento (seção 9.8, eqs. 9.1 a 9.4), sem o compilador"""
    import math
    cp_m = 2 * min(m["c_lapes"], m["c_liq"])
    ee = cp_m / m["pv"]
    f_bat = max(0.2, 0.85 / (0.85 + math.exp((1000 * m["m_bat"] - 298) / 37.7 - 4.8)))
    f_dec = 250 if m["s_to"] <= 1 else 170 if m["s_to"] <= 4 else 110 if m["s_to"] <= 8 else 0
    pd = 0.4 * max(1000 * m["b"] - 1800, 0)
    return 1.05 * f_bat * 1.0 * f_dec * cp_m ** 0.08 * (0.095 / (0.1 + math.exp(-ee)) + 0.4) - pd


CASES = [
    # EE = 4, decolagem em 3,5 m, bateria de 300 g, envergadura no limite: 224,67 pontos
    (dict(c_lapes=1.0, c_liq=1.2, pv=0.5, m_bat=0.300, s_to=3.5, b=1.8), 224.6736, True),
    # decolagem em 0,9 m, bateria de 420 g, 30 mm acima do limite (−12 pontos)
    (dict(c_lapes=0.8, c_liq=0.8, pv=0.6, m_bat=0.420, s_to=0.9, b=1.83), 198.0695, True),
    # decolagem além de 8 m: F_Dec = 0 e o voo não vale; carga abaixo de 0,3 PV
    (dict(c_lapes=0.1, c_liq=0.5, pv=0.5, m_bat=0.250, s_to=8.5, b=1.7), 0.0, False),
]


@pytest.mark.parametrize("q, expected, valid", CASES)
def test_micro_2026_score_in_the_core_matches_hand(backend, q, expected, valid):
    from aeroopt.scoring import evaluate
    r = evaluate(scoring_for("sae_br_2026_micro"), q, backend)[0]
    assert r["nota"] == pytest.approx(_micro(q), rel=1e-12)
    assert r["nota"] == pytest.approx(expected, abs=1e-3)
    assert r["valido"] is valid


REGULAR = [
    # monoplano com cauda (N = 2), EE = 2, 3 m de envergadura: 110 × 1,15^−3 = 72,3268 pontos
    (dict(cp=10.0, pv=5.0, s_to=50.0, b=3.0, n_sup=2), 72.3268, True),
    # asa voadora (N = 1, ×1,22), 30 mm acima dos 4 m (−3 pontos): 1,1 × 50 × 1,5 × 1,22 × 1,15^−4,03 − 3 = 54,3062
    (dict(cp=6.0, pv=4.0, s_to=40.0, b=4.03, n_sup=1), 54.3062, True),
    # biplano (N = 3, ×1,15) que passa de 20 kg (conta só 20 − PV) e de 4,05 m (+20); corrida além do obstáculo
    (dict(cp=18.0, pv=6.0, s_to=60.0, b=4.1, n_sup=3), 1.1 * 50 * (14 / 6) * 1.15 * 1.15 ** -4.1 - 30.0, False),
]


@pytest.mark.parametrize("q, expected, valid", REGULAR)
def test_regular_2026_score_in_the_core_matches_hand(backend, q, expected, valid):
    """a nota da Regular 2026 à mão (seção 7.7, eqs. 7.2 e 7.5; P_D de NC[7.2.0.1])"""
    from aeroopt.scoring import evaluate
    r = evaluate(scoring_for("sae_br_2026_regular"), q, backend)[0]
    assert r["nota"] == pytest.approx(expected, abs=1e-3)
    assert r["valido"] is valid


def test_core_refuses_a_broken_program(backend):
    p = scoring_for("MTOW").program()
    bad = dict(p, ops=[LOAD, LOAD, STORE], args=[0, 0, 1])          # sobra um valor na pilha
    with pytest.raises(ValueError, match="pilha"):
        backend.expr_eval(bad, [[1.0]])

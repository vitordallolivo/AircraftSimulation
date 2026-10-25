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

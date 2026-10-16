"""tools/opt_matrix.py: a tabela binária, os nomes dos bits, a leitura do Callgrind e a comparação dos resultados."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))

import opt_matrix as om  # noqa: E402

ANN = """\
--------------------------------------------------------------------------------
Ir
--------------------------------------------------------------------------------
1,000,000 (100.0%)  PROGRAM TOTALS

--------------------------------------------------------------------------------
Ir                   file:function
--------------------------------------------------------------------------------
400,000 (40.00%)  core/src/physics/aero.zig:0x00000000000041e0
250,000 (25.00%)  /usr/local/lib/python3.13/dist-packages/ziglang/lib/std/math.zig:0x00000000000041e0
200,000 (20.00%)  ???:_PyEval_EvalFrameDefault [/usr/bin/python3.13]
"""


def test_combos_is_the_binary_table():
    assert om.combos([8, 16]) == [0, 8, 16, 24]
    assert len(om.combos([1, 2, 4, 8, 16, 32, 64])) == 128


def test_parse_bits_by_name_or_number():
    assert om.parse_bits("peak,cse") == [8, 16]
    assert om.parse_bits("8,16") == [8, 16]
    assert om.parse_bits("minimax+estrin") == [32, 64]


def test_names_match_core_build_zig():
    """os nomes e bits daqui são os mesmos do core/build.zig (opt_names)"""
    with open(os.path.join(om.CORE, "build.zig"), encoding="utf-8") as f:
        src = f.read()
    for name, bit in om.KEYS.items():
        assert f'.{{ "{name}", {bit} }}' in src
    assert set(om.KEYS.values()) == set(om.NAMES)


def test_core_instructions_sums_zig_files_only():
    assert om.core_instructions(ANN) == (650_000, 1_000_000)


def test_max_rel_diff_ignores_near_zero():
    a = {"x": {"v": [1.0, 1e-12, 2.0]}}
    b = {"x": {"v": [1.0, 2e-12, 2.002]}}
    d, where = om.max_rel_diff(a, b)
    assert abs(d - 0.002 / 2.002) < 1e-12 and where == "x: v"
    assert om.max_rel_diff(b, b) == (0.0, "")


def test_label():
    assert om.label(0).startswith("nenhuma")
    assert om.label(24) == "peakCL áureo + σ e sincos uma vez"

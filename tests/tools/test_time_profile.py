"""tools/time_profile.py: leitura das pilhas amostradas, a tabela (tempo próprio e total) e o flame graph."""
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))

import time_profile as tp  # noqa: E402

RAW = """\
<module> (alvo.py:3);run (a.py:10);f (a.py:20) 6
<module> (alvo.py:3);run (a.py:10);g (a.py:30);0x7f00aa (libc.so.6) 3
<module> (alvo.py:3);run (a.py:11) 1
<module> (alvo.py:3);_find_and_load (<frozen importlib._bootstrap>:1) 10
<module> (alvo.py:3);rec (b.py:1);rec (b.py:1);rec (b.py:1) 2
"""


def test_frame_name_drops_line_number():
    assert tp.frame_name("f (a.py:20)") == "f (a.py)"
    assert tp.frame_name("sim.envelope.excess (envelope.zig:131)") == "sim.envelope.excess (envelope.zig)"
    assert tp.frame_name("0x7f00aa (libc.so.6)") == "0x7f00aa (libc.so.6)"


def test_clean_drops_unnamed_frames_and_separates_imports():
    stacks, imp = tp.clean(tp.read_collapsed(RAW))
    assert imp == 10
    assert sum(n for _, n in stacks) == 12
    assert not any(f.startswith("0x") for fr, _ in stacks for f in fr)
    with_imp, imp2 = tp.clean(tp.read_collapsed(RAW), keep_imports=True)
    assert imp2 == 0 and sum(n for _, n in with_imp) == 22


def test_table_own_and_total():
    stacks, _ = tp.clean(tp.read_collapsed(RAW))
    rows = {r["funcao"]: r for r in tp.table(stacks)}
    assert rows["<module> (alvo.py)"]["total"] == 12 and rows["<module> (alvo.py)"]["proprio"] == 0
    assert rows["run (a.py)"]["total"] == 10 and rows["run (a.py)"]["proprio"] == 1
    assert rows["f (a.py)"]["proprio"] == 6
    # o quadro sem nome sumiu: o tempo dele ficou com quem chamou
    assert rows["g (a.py)"]["proprio"] == 3
    # recursão: a função conta uma vez por pilha no total
    assert rows["rec (b.py)"]["total"] == 2 and rows["rec (b.py)"]["proprio"] == 2
    assert abs(rows["run (a.py)"]["total_pct"] - 100 * 10 / 12) < 1e-12


def test_flame_svg_is_valid_and_widths_follow_samples():
    stacks, _ = tp.clean(tp.read_collapsed(RAW))
    svg = tp.flame_svg(stacks, title="teste", width=1200)
    root = ET.fromstring(svg)
    ns = "{http://www.w3.org/2000/svg}"
    bars = {g.find(f"{ns}title").text.split(" — ")[0]: float(g.find(f"{ns}rect").get("width"))
            for g in root.iter(f"{ns}g")}
    # largura = fração das amostras (menos 0,5 px de borda)
    assert abs(bars["<module> (alvo.py)"] - (1200 - 0.5)) < 1e-6
    assert abs(bars["f (a.py)"] - (1200 * 6 / 12 - 0.5)) < 1e-6


def test_module_of_zig_python_and_native():
    assert tp.module_of("physics.aero.clPanel (aero.zig)") == "physics/aero.zig"
    assert tp.module_of("math.fmath.SinLut(8).sincos (fmath.zig)") == "math/fmath.zig"
    assert tp.module_of("root.aerosim_run (root.zig)") == "root.zig"
    assert tp.module_of("f (aerosim/model/universal.py)") == "aerosim/model/universal.py"
    assert tp.module_of("ffi_call (libffi.so.8.1.4)") == "libffi.so.8.1.4"


def test_module_stacks_merge_consecutive_frames():
    st = [(["run (a.py)", "x.aero.f (aero.zig)", "x.aero.g (aero.zig)", "x.vec.dot (vec.zig)"], 4),
          (["run (a.py)", "x.aero.f (aero.zig)"], 1)]
    ms = tp.module_stacks(st)
    assert ms[0] == (["a.py", "x/aero.zig", "x/vec.zig"], 4)
    rows = {r["funcao"]: r for r in tp.table(ms)}
    assert rows["x/aero.zig"]["total"] == 5 and rows["x/aero.zig"]["proprio"] == 1
    assert rows["x/vec.zig"]["proprio"] == 4

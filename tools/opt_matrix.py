"""Mapa das otimizações em avaliação do núcleo (`-Dopt`): compila cada combinação, mede e compara os resultados
com a combinação 0 (o núcleo de sempre).

    python tools/opt_matrix.py                         # todas as combinações dos bits, 3 rodadas por análise
    python tools/opt_matrix.py --bits peak,cse --rodadas 5
    python tools/opt_matrix.py --analises envelope,loads
    python tools/opt_matrix.py --instrucoes            # contagem exata de instruções (Callgrind), sem ruído

Bits (nomes do core/build.zig): 1 noinline = sincos da tabela sem inline forçado; 2 floatmode = float mode
"optimized" nas funções quentes; 4 logstd = log da std com as tabelas; 8 peak = peakCL por seção áurea; 16 cse = o
painel calcula σ e sincos(α) uma vez só; 32 minimax = sin/cos por polinômio minimax, sem tabela; 64 estrin = o
polinômio do exp por Estrin. `--std` acrescenta uma linha com a std no lugar das tabelas (-Dfast_math=false).

Dois modos de medir:
- tempo de parede (padrão): as análises do manager, a menor de N rodadas. Neste container o ruído é de uns ±10 %.
- `--instrucoes`: uma carga fixa do núcleo (configurar o avião, que roda o peakCL; 10 s de simulação; N avaliações
  da dinâmica) sob o Callgrind, e soma as instruções executadas nos arquivos .zig. É determinística (a mesma conta
  dá o mesmo número), mas instrução não é tempo: não vê cache nem paralelismo (o Estrin ganha em paralelismo).

Saída em `perfis/opt_matrix_<data>.md` (fora do git): uma linha por combinação com a medida, o ganho sobre a 0 e a
maior diferença relativa nos resultados. No fim o núcleo volta a ser compilado com -Dopt=0.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import itertools
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CORE = os.path.join(ROOT, "core")
NAMES = {1: "sem inline", 2: "float optimized", 4: "log da std", 8: "peakCL áureo", 16: "σ e sincos uma vez",
         32: "sin/cos minimax", 64: "exp por Estrin"}
KEYS = {"noinline": 1, "floatmode": 2, "logstd": 4, "peak": 8, "cse": 16, "minimax": 32, "estrin": 64}
STD = -1                                    # linha extra: o núcleo com a std (-Dfast_math=false), -Dopt=0

CHILD = r'''
import ctypes, json, sys, time
sys.path.insert(0, ROOT)
import numpy as np
from aerosim.backend.zig import ZigBackend
from aerosim.manager import SimulationManager
from aerosim.model.templates import TEMPLATES
m = SimulationManager(ZigBackend())
out = {"tempo": {}, "resumo": {}}
for name in ANALISES:
    m.run(name, TEMPLATES[AVIAO](), {})                      # aquece (caches de perfis e polar)
    ts = []
    for _ in range(RODADAS):
        t0 = time.perf_counter(); r = m.run(name, TEMPLATES[AVIAO](), {}); ts.append(time.perf_counter() - t0)
    out["tempo"][name] = min(ts)
    num = {}
    for k, v in r.summary.items():
        vv = v if isinstance(v, (list, tuple)) else [v]
        if all(isinstance(x, (int, float, np.floating)) and not isinstance(x, bool) for x in vv):
            num[k] = [float(x) for x in vv]
    out["resumo"][name] = num
json.dump(out, open(SAIDA, "w"))
'''

# carga fixa do núcleo para o Callgrind (sem rodadas: a contagem não tem ruído)
CORE_CHILD = r'''
import ctypes, json, sys
sys.path.insert(0, ROOT)
from aerosim.backend.zig import ZigBackend
from aerosim.backend.zig.translator import native_spec
from aerosim.model.templates import TEMPLATES
b = ZigBackend()
fd = b._lib.dll.aerosim_bench_dynamics
fd.restype, fd.argtypes = ctypes.c_double, [ctypes.c_int32, ctypes.c_uint64]
with b.open_session() as s:
    s.configure(dict(native_spec(TEMPLATES[AVIAO]()), stop_t=10))
    s.reset_ground()
    _, log = s.run()
    acc = fd(s._slot, AVALIACOES)
fim = {f"{k} em t = 10 s": [float(v[-1])] for k, v in log.columns.items() if len(v)}
json.dump({"resumo": {"nucleo": {"soma de f(t, x)": [acc], **fim}}}, open(SAIDA, "w"))
'''


def combos(bits: list[int]) -> list[int]:
    """todas as somas dos subconjuntos de `bits` (a tabela binária), da 0 para cima"""
    out = {0}
    for r in range(1, len(bits) + 1):
        for c in itertools.combinations(bits, r):
            out.add(sum(c))
    return sorted(out)


def label(k: int) -> str:
    if k == STD:
        return "std no lugar das tabelas (-Dfast_math=false)"
    return " + ".join(NAMES[b] for b in sorted(NAMES) if k & b) or "nenhuma (o núcleo de sempre)"


def max_rel_diff(a: dict, b: dict) -> tuple[float, str]:
    """maior diferença relativa entre os números dos resumos (ignora valores perto de zero: |ref| < 1e-9)"""
    worst, where = 0.0, ""
    for name, na in a.items():
        for k, va in na.items():
            vb = b.get(name, {}).get(k)
            if not vb or len(va) != len(vb):
                continue
            for x, y in zip(va, vb):
                if not (math.isfinite(x) and math.isfinite(y)) or abs(y) < 1e-9:
                    continue
                d = abs(x - y) / abs(y)
                if d > worst:
                    worst, where = d, f"{name}: {k}"
    return worst, where


def build(k: int, symbols: bool = False) -> None:
    """compila a combinação k; `symbols` (-Dstrip=false) só guarda a informação de depuração: o código é o
    mesmo"""
    fast = "false" if k == STD else "true"
    subprocess.run([sys.executable, "-m", "ziglang", "build", "--release=fast", f"-Dfast_math={fast}",
                    f"-Dopt={max(k, 0)}", f"-Dstrip={'false' if symbols else 'true'}"], cwd=CORE, check=True)


def parse_bits(text: str) -> list[int]:
    """"peak,cse" ou "8,16" -> [8, 16]"""
    return [KEYS[t] if t in KEYS else int(t) for t in text.replace("+", ",").split(",") if t]


def core_instructions(annotated: str) -> tuple[int, int]:
    """(instruções nos arquivos .zig, total do programa) da saída do callgrind_annotate --threshold=100.
    O valgrind 3.22 não lê os nomes de função do Zig 0.16, só o arquivo: soma-se o custo próprio por arquivo."""
    total, core = 0, 0
    for ln in annotated.splitlines():
        m = re.match(r"\s*([\d,]+)\s+(?:\([^)]*\)\s+)?(.*)", ln)
        if not m:
            continue
        n = int(m.group(1).replace(",", ""))
        if "PROGRAM TOTALS" in m.group(2):
            total = n
        elif ".zig:" in m.group(2):
            core += n
    return core, total


def measure_instructions(k: int, aircraft: str, evaluations: int) -> dict:
    build(k, symbols=True)                      # sem símbolos o Callgrind não sabe de que arquivo é a instrução
    with tempfile.TemporaryDirectory() as d:
        res, cg = os.path.join(d, "r.json"), os.path.join(d, "cg.out")
        code = (CORE_CHILD.replace("ROOT", repr(ROOT)).replace("AVIAO", repr(aircraft))
                .replace("AVALIACOES", str(evaluations)).replace("SAIDA", repr(res)))
        script = os.path.join(d, "carga.py")
        with open(script, "w") as f:
            f.write(code)
        subprocess.run(["valgrind", "--tool=callgrind", f"--callgrind-out-file={cg}", sys.executable, script],
                       cwd=ROOT, check=True, stderr=subprocess.DEVNULL)
        ann = subprocess.run(["callgrind_annotate", "--threshold=100", cg], capture_output=True, text=True,
                             check=True).stdout
        with open(res) as f:
            out = json.load(f)
    core, total = core_instructions(ann)
    out["instrucoes"] = {"nucleo": core, "programa": total}
    return out


def measure(k: int, analyses: list[str], runs: int, aircraft: str) -> dict:
    build(k)
    with tempfile.TemporaryDirectory() as d:
        res = os.path.join(d, "r.json")
        code = (CHILD.replace("ROOT", repr(ROOT)).replace("ANALISES", repr(analyses))
                .replace("RODADAS", str(runs)).replace("AVIAO", repr(aircraft)).replace("SAIDA", repr(res)))
        subprocess.run([sys.executable, "-c", code], cwd=ROOT, check=True)
        with open(res) as f:
            return json.load(f)


def _diff_text(r: dict, base: dict) -> str:
    d, where = max_rel_diff(r["resumo"], base["resumo"])
    return f"{d:.1e} ({where})" if d > 0 else "idêntico"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="mapa das combinações de -Dopt: medida e diferença nos resultados")
    ap.add_argument("--bits", default="1,2,4,8,16,32,64", help="bits ou nomes a combinar (padrão: todos)")
    ap.add_argument("--analises", default="envelope,mission,loads,performance")
    ap.add_argument("--rodadas", type=int, default=3, help="rodadas por análise (vale a menor)")
    ap.add_argument("--aviao", default="conventional")
    ap.add_argument("--std", action="store_true", help="acrescenta a linha com a std (-Dfast_math=false)")
    ap.add_argument("--instrucoes", action="store_true", help="conta instruções no Callgrind (carga fixa do núcleo)")
    ap.add_argument("--avaliacoes", type=int, default=20000, help="--instrucoes: avaliações da dinâmica")
    args = ap.parse_args(argv)
    if args.instrucoes and shutil.which("valgrind") is None:
        print("valgrind não encontrado (apt-get install -y valgrind)", file=sys.stderr)
        return 2
    bits = parse_bits(args.bits)
    analyses = args.analises.split(",")
    rows = {}
    try:
        for k in combos(bits) + ([STD] if args.std else []):
            print(f"-Dopt={k:3d}: {label(k)}…", flush=True)
            rows[k] = (measure_instructions(k, args.aviao, args.avaliacoes) if args.instrucoes
                       else measure(k, analyses, args.rodadas, args.aviao))
    finally:
        build(0)
    base = rows[0]
    when = f"{_dt.datetime.now():%Y-%m-%d %H:%M}"
    if args.instrucoes:
        i0 = base["instrucoes"]["nucleo"]
        lines = [f"# Mapa de -Dopt por instruções ({args.aviao}; configurar + 10 s + {args.avaliacoes} "
                 f"avaliações de f(t, x); Callgrind; {when})", "",
                 "| opt | otimizações | instruções no núcleo | ganho sobre a 0 "
                 "| maior diferença nos resultados |",
                 "|---|---|---|---|---|"]
        for k in sorted(rows, key=lambda k: rows[k]["instrucoes"]["nucleo"]):
            n = rows[k]["instrucoes"]["nucleo"]
            gain = 100 * (i0 - n) / i0
            lines.append(f"| {k} | {label(k)} | {n:,} | {gain:+.1f} % | {_diff_text(rows[k], base)} |")
    else:
        t0 = sum(base["tempo"].values())
        lines = [f"# Mapa de -Dopt ({args.aviao}, {args.rodadas} rodadas, vale a menor; {when})", "",
                 "| opt | otimizações | " + " | ".join(f"{a} (s)" for a in analyses)
                 + " | total (s) | ganho sobre a 0 | maior diferença nos resultados |",
                 "|---|---|" + "---|" * len(analyses) + "---|---|---|"]
        for k in sorted(rows, key=lambda k: sum(rows[k]["tempo"].values())):
            r = rows[k]
            tot = sum(r["tempo"].values())
            lines.append(f"| {k} | {label(k)} | " + " | ".join(f"{r['tempo'][a]:.2f}" for a in analyses)
                         + f" | {tot:.2f} | {100 * (t0 - tot) / t0:+.1f} % | {_diff_text(r, base)} |")
    txt = "\n".join(lines)
    os.makedirs(os.path.join(ROOT, "perfis"), exist_ok=True)
    out = os.path.join(ROOT, "perfis", f"opt_matrix_{_dt.datetime.now():%Y%m%d_%H%M%S}.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write(txt + "\n")
    print("\n" + txt + f"\n\nsaída em {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

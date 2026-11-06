"""Testes de otimização (G27): mede cada técnica candidata contra o código de hoje do núcleo, no mesmo caso e em
release, e diz se a conta continua a mesma. Só a técnica que ganhar entra no núcleo; o resultado vai para o
core/OTIMIZACOES.md.

    python tools/tecnicas.py                       # todas as técnicas, tempo (melhor de 7 rodadas, 3 vezes alternando)
    python tools/tecnicas.py --tecnicas log,faixas
    python tools/tecnicas.py --instrucoes          # também as instruções por chamada no Callgrind (sem ruído)
    python tools/tecnicas.py --rodadas 11 --vezes 5

Quem mede é a bancada em Zig (core/src/tecnicas.zig, `zig build tecnicas`): cada técnica tem a variante de hoje (a
função do núcleo) e a candidata, e cada chamada devolve uma soma do resultado para conferir que as duas fazem a
mesma conta. Uma técnica que é um bit de `-Dopt` (a dica dos ramos, `hint`) roda a mesma variante num núcleo
compilado com o bit.

Três medidas:
- tempo: a bancada repete a chamada até a rodada passar de 20 ms e fica com a melhor de N rodadas; este script roda
  a de hoje e a candidata alternadas, várias vezes, e fica com a menor de cada;
- instruções (`--instrucoes`, precisa do valgrind): o Callgrind conta as instruções de R e de 2R chamadas, e a
  diferença dividida por R é o custo de uma chamada, sem a preparação. Não oscila, mas não vê cache nem paralelismo;
- vetorização (sempre, precisa do objdump): conta as instruções de ponto flutuante empacotadas (ymm/xmm `pd`) e as
  escalares (`sd`) nas funções das faixas, para ver se o laço vetorizou.

Saída: a tabela no terminal e em perfis/tecnicas_<data>.md (fora do git).
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CORE = os.path.join(ROOT, "core")

# técnica: (o que mede, variante de hoje, candidata, bits de -Dopt da candidata)
TECHNIQUES = {
    "log": ("log em colunas (SoA) no `gust.settled`", "aos", "soa", 0),
    "faixas": ("faixas em colunas, 4 por vez (`@Vector`)", "hoje", "vetor", 0),
    "voo": ("`@branchHint(.unlikely)` nos caminhos raros do `runner.run`", "hoje", "hoje", 128),
    "alocacao": ("`FixedBufferAllocator` no lugar do `page_allocator` no `sizing.eval`", "pagina", "fixo", 0),
}
# funções cujo disassembly diz se as faixas vetorizaram (nomes como o Zig gera)
VECTOR_SYMBOLS = ("tecnicas.stripsOnly", "aero.computeImpl", "tecnicas.stripsVector")


def zig() -> list[str]:
    try:
        import ziglang  # noqa: F401
        return [sys.executable, "-m", "ziglang"]
    except ImportError:
        return ["zig"]


def build(opt_bits: int, prefix: str) -> str:
    """compila a bancada com `-Dopt=<bits>` em `prefix`; devolve o executável"""
    subprocess.run(zig() + ["build", "tecnicas", f"-Dopt={opt_bits}", "--prefix", prefix, "--", "log", "aos", "1", "1"],
                   cwd=CORE, check=True, capture_output=True)
    return os.path.join(prefix, "bin", "tecnicas")


def run(exe: str, technique: str, variant: str, rounds: int, fixed: int = 0) -> dict:
    args = [exe, technique, variant, str(rounds)] + ([str(fixed)] if fixed else [])
    out = subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip().splitlines()[-1]
    return json.loads(out)


def instructions(exe: str, technique: str, variant: str, repeats: int) -> float | None:
    """instruções de uma chamada: (custo com 2R − custo com R) / R, no Callgrind"""
    if not shutil.which("valgrind"):
        return None
    counts = []
    for fixed in (repeats, 2 * repeats):
        with tempfile.TemporaryDirectory() as folder:
            out_file = os.path.join(folder, "cg.out")
            subprocess.run(["valgrind", "--tool=callgrind", f"--callgrind-out-file={out_file}", exe, technique, variant,
                            "1", str(fixed)], check=True, capture_output=True)
            with open(out_file) as f:
                summary = [line for line in f if line.startswith("summary:") or line.startswith("totals:")]
            counts.append(int(summary[-1].split()[1]))
    return (counts[1] - counts[0]) / repeats


def vectorization(exe: str) -> dict[str, tuple[int, int]]:
    """para cada função das faixas: (instruções empacotadas `pd`, escalares `sd`)"""
    if not shutil.which("objdump"):
        return {}
    listing = subprocess.run(["objdump", "-d", "--no-show-raw-insn", exe], check=True, capture_output=True,
                             text=True).stdout
    result: dict[str, tuple[int, int]] = {}
    current = None
    for line in listing.splitlines():
        header = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if header:
            current = next((name for name in VECTOR_SYMBOLS if name in header.group(1)), None)
            continue
        if current is None:
            continue
        op = line.split("\t")[1].split()[0] if "\t" in line else ""
        if not op.startswith("v") and not op.endswith(("pd", "sd")):
            continue
        packed, scalar = result.get(current, (0, 0))
        if re.search(r"pd$", op) and "ymm" in line:
            packed += 1
        elif re.search(r"(sd|pd)$", op) and "ymm" not in line:
            scalar += 1           # sd, e pd em xmm (2 números) contam como quase escalares
        result[current] = (packed, scalar)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--tecnicas", default=",".join(TECHNIQUES), help="lista separada por vírgula: " + ", ".join(TECHNIQUES))
    parser.add_argument("--rodadas", type=int, default=7, help="rodadas da bancada (fica a melhor)")
    parser.add_argument("--vezes", type=int, default=3, help="vezes que hoje e candidata rodam alternadas")
    parser.add_argument("--instrucoes", action="store_true", help="também as instruções por chamada (Callgrind)")
    parser.add_argument("--repeticoes", type=int, default=4, help="R do Callgrind (instruções de 2R − de R)")
    args = parser.parse_args()
    chosen = [name.strip() for name in args.tecnicas.split(",") if name.strip()]
    unknown = [name for name in chosen if name not in TECHNIQUES]
    if unknown:
        sys.exit(f"técnica desconhecida: {', '.join(unknown)} (há: {', '.join(TECHNIQUES)})")

    work = tempfile.mkdtemp(prefix="tecnicas-")
    executables: dict[int, str] = {}
    for bits in sorted({0} | {TECHNIQUES[name][3] for name in chosen}):
        print(f"compilando a bancada com -Dopt={bits}…", flush=True)
        executables[bits] = build(bits, os.path.join(work, f"opt{bits}"))

    rows = []
    for name in chosen:
        title, today, candidate, bits = TECHNIQUES[name]
        print(f"{name}: {title}", flush=True)
        best = {"hoje": float("inf"), "candidata": float("inf")}
        sums = {}
        for _ in range(args.vezes):
            for role, exe, variant in (("hoje", executables[0], today), ("candidata", executables[bits], candidate)):
                result = run(exe, name, variant, args.rodadas)
                best[role] = min(best[role], result["ns"])
                sums[role] = result["soma"]
        same = abs(sums["hoje"] - sums["candidata"]) <= 1e-9 * max(1.0, abs(sums["hoje"]))
        row = {"tecnica": name, "titulo": title, "hoje": best["hoje"], "candidata": best["candidata"],
               "ganho": best["hoje"] / best["candidata"], "mesma": same, "bit": sums["hoje"] == sums["candidata"]}
        if args.instrucoes:
            row["inst_hoje"] = instructions(executables[0], name, today, args.repeticoes)
            row["inst_candidata"] = instructions(executables[bits], name, candidate, args.repeticoes)
        rows.append(row)
        print(f"   hoje {fmt_ns(row['hoje'])}  candidata {fmt_ns(row['candidata'])}  ganho {row['ganho']:.2f}x", flush=True)

    vector = vectorization(executables[0]) if "faixas" in chosen else {}
    report = markdown(rows, vector, args)
    print("\n" + report)
    folder = os.path.join(ROOT, "perfis")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"tecnicas_{_dt.datetime.now():%Y-%m-%d_%H%M}.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"salvo em {os.path.relpath(path, ROOT)}")
    shutil.rmtree(work, ignore_errors=True)
    return 0


def fmt_ns(value: float) -> str:
    if value >= 1e6:
        return f"{value / 1e6:.2f} ms"
    if value >= 1e3:
        return f"{value / 1e3:.2f} µs"
    return f"{value:.1f} ns"


def markdown(rows: list[dict], vector: dict, args) -> str:
    lines = [f"# Técnicas de otimização ({_dt.date.today()})", "",
             f"Melhor de {args.rodadas} rodadas, {args.vezes} vezes alternando hoje e candidata; ReleaseFast.", ""]
    head = "| Técnica | Hoje | Candidata | Ganho | Mesma conta |"
    sep = "|---|---|---|---|---|"
    if args.instrucoes:
        head += " Instruções hoje | Instruções candidata |"
        sep += "---|---|"
    lines += [head, sep]
    for row in rows:
        same = "bit a bit" if row["bit"] else ("sim (1e-9)" if row["mesma"] else "**não**")
        line = f"| {row['titulo']} | {fmt_ns(row['hoje'])} | {fmt_ns(row['candidata'])} | {row['ganho']:.2f}x | {same} |"
        if args.instrucoes:
            line += f" {fmt_count(row.get('inst_hoje'))} | {fmt_count(row.get('inst_candidata'))} |"
        lines.append(line)
    if vector:
        lines += ["", "Vetorização (instruções de ponto flutuante no disassembly):", "",
                  "| Função | Empacotadas (ymm, 4 números) | Escalares ou xmm |", "|---|---|---|"]
        for symbol, (packed, scalar) in vector.items():
            lines.append(f"| `{symbol}` | {packed} | {scalar} |")
    return "\n".join(lines) + "\n"


def fmt_count(value: float | None) -> str:
    return "—" if value is None else f"{value:,.0f}".replace(",", ".")


if __name__ == "__main__":
    sys.exit(main())

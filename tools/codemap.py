"""Mapa do código: gera docs/MAP.md a partir do próprio código (nunca editar o MAP.md à mão).

    python tools/codemap.py            # reescreve docs/MAP.md
    python tools/codemap.py --check    # sai com 1 se o docs/MAP.md estiver desatualizado

Para cada arquivo:
    Python   primeira linha da docstring do módulo, classes e funções públicas (nível de módulo) com a linha
    Zig      primeira linha do comentário `//!`, `pub fn`/`pub const` de tipos e os `export fn` (a ABI)
Mais: as pastas de testes (quantos `test_*` em cada), as ferramentas de `tools/` e os README.md.
Só lê o código; não importa nada (roda sem o núcleo compilado).
"""
from __future__ import annotations

import argparse
import ast
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "docs", "MAP.md")
SKIP = {"__pycache__", ".git", "zig-out", ".zig-cache", "zig-pkg", "legacy", "node_modules", ".venv"}   # zig-pkg: pacotes do Zig 0.16


def _walk(base: str, ext: str):
    for d, dirs, files in os.walk(base):
        dirs[:] = sorted(x for x in dirs if x not in SKIP and not x.startswith("."))
        for f in sorted(files):
            if f.endswith(ext):
                yield os.path.join(d, f)


def _rel(p: str) -> str:
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def _first(text: str | None) -> str:
    if not text:
        return ""
    line = text.strip().splitlines()[0].strip()
    return line[:140]


def py_entry(path: str) -> str:
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except SyntaxError as e:
        return f"- `{_rel(path)}` — (erro de sintaxe: {e.msg})"
    doc = _first(ast.get_docstring(tree))
    names = []
    for n in tree.body:
        if isinstance(n, ast.ClassDef) and not n.name.startswith("_"):
            names.append(f"class {n.name}:{n.lineno}")
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and not n.name.startswith("_"):
            names.append(f"{n.name}:{n.lineno}")
    line = f"- `{_rel(path)}`" + (f" — {doc}" if doc else "")
    if names:
        line += "\n  " + ", ".join(f"`{x}`" for x in names)
    return line


ZIG_PUB = re.compile(r"^pub (?:inline )?fn (\w+)", re.M)
ZIG_TYPE = re.compile(r"^pub const (\w+) = (?:extern |packed )?(?:struct|enum|union)", re.M)
ZIG_EXPORT = re.compile(r"^export fn (\w+)", re.M)


def zig_entry(path: str) -> str:
    src = open(path, encoding="utf-8").read()
    doc = next((ln[3:].strip() for ln in src.splitlines() if ln.startswith("//!")), "")
    line = f"- `{_rel(path)}`" + (f" — {doc[:140]}" if doc else "")
    parts = []
    tys = [f"{m.group(1)}:{src[:m.start()].count(chr(10)) + 1}" for m in ZIG_TYPE.finditer(src)]
    fns = [f"{m.group(1)}:{src[:m.start()].count(chr(10)) + 1}" for m in ZIG_PUB.finditer(src)]
    exs = [m.group(1) for m in ZIG_EXPORT.finditer(src)]
    if tys:
        parts.append("tipos " + ", ".join(f"`{x}`" for x in tys))
    if fns:
        parts.append("fn " + ", ".join(f"`{x}`" for x in fns))
    if exs:
        parts.append(f"**ABI ({len(exs)} exports)** " + ", ".join(f"`{x}`" for x in exs))
    for p in parts:
        line += "\n  " + p
    return line


def section(title: str, entries: list[str]) -> list[str]:
    return [f"## {title}", ""] + entries + [""]


def build() -> str:
    out = ["# Mapa do código",
           "",
           "Gerado por `python tools/codemap.py` — **não editar à mão** (`--check` acusa quando está desatualizado).",
           "Formato: `arquivo` — primeira linha da documentação; depois os nomes públicos com a linha (`nome:linha`).",
           "Regras e decisões do projeto: `.claude/CLAUDE.md`. O que falta e a ordem: `docs/TRACKING.md`.",
           ""]
    # Python, por pacote de primeiro nível de aerosim
    pkgs: dict[str, list[str]] = {}
    for p in _walk(os.path.join(ROOT, "aerosim"), ".py"):
        r = _rel(p).split("/")
        key = "/".join(r[:2]) if len(r) > 2 else "aerosim"
        pkgs.setdefault(key, []).append(py_entry(p))
    for k in sorted(pkgs):
        out += section(f"Python · `{k}`", pkgs[k])
    # Zig
    for base, title in (("core/src", "Zig · núcleo (`core/src`)"), ("aerodrive/src", "Zig · AeroDrive (`aerodrive/src`)")):
        groups: dict[str, list[str]] = {}
        for p in _walk(os.path.join(ROOT, base), ".zig"):
            r = _rel(p)[len(base) + 1:].split("/")
            groups.setdefault(r[0] if len(r) > 1 else ".", []).append(zig_entry(p))
        ent = []
        for g in sorted(groups):
            ent += [f"**{base}/{'' if g == '.' else g + '/'}**", ""] + groups[g] + [""]
        out += section(title, ent)
    # ferramentas
    tools = []
    for p in _walk(os.path.join(ROOT, "tools"), ".py"):
        try:
            doc = _first(ast.get_docstring(ast.parse(open(p, encoding="utf-8").read())))
        except SyntaxError:
            doc = ""
        tools.append(f"- `{_rel(p)}`" + (f" — {doc}" if doc else ""))
    out += section("Ferramentas (`tools/`)", tools)
    # testes
    tests = []
    tdir = os.path.join(ROOT, "tests")
    for name in sorted(os.listdir(tdir)):
        p = os.path.join(tdir, name)
        files = list(_walk(p, ".py")) if os.path.isdir(p) else ([p] if name.endswith(".py") else [])
        n = sum(len(re.findall(r"^def test_", open(f, encoding="utf-8").read(), re.M)) for f in files)
        if n:
            tests.append(f"- `tests/{name}` — {n} testes em {len(files)} arquivo(s)")
    out += section("Testes (`tests/`)", tests)
    # READMEs
    readmes = []
    for d, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(x for x in dirs if x not in SKIP and not x.startswith("."))
        if "README.md" in files:
            readmes.append(f"- `{_rel(os.path.join(d, 'README.md'))}`")
    out += section("README por pasta", sorted(readmes))
    return "\n".join(out).rstrip() + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="só confere se o docs/MAP.md está em dia")
    a = ap.parse_args(argv)
    text = build()
    old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
    if a.check:
        if old != text:
            print("docs/MAP.md desatualizado: rode python tools/codemap.py")
            return 1
        print("docs/MAP.md em dia")
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"{_rel(OUT)}: {text.count(chr(10))} linhas")
    return 0


if __name__ == "__main__":
    sys.exit(main())

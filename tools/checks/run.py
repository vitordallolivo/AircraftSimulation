"""Checks de regressão: confere que nada quebrou antes de um PR.

    python tools/checks/run.py                  # o padrão: fundação, AeroDrive, regressão bit a bit, testes rápidos
    python tools/checks/run.py --tudo           # inclui os testes lentos (GUI, design, manager)
    python tools/checks/run.py --grupos aerodrive,fundação
    python tools/checks/run.py --so "tests/aero"
    python tools/checks/run.py --ref feature/aero --rapido     # outra referência; sem a decolagem
    python tools/checks/run.py --lista          # o que existe

Grupos:
    fundação     testes do núcleo Zig; mapa do código (docs/MAP.md) em dia
    aerodrive    compila e testa o AeroDrive
    regressão    exemplos de data/aircraft bit a bit contra a referência (padrão: origin/main)
    testes       uma pasta de tests/ por check

Sai com 1 se algum check falhar (os pulados não contam). `--relatorio arquivo.md` grava o resultado em Markdown.
"""
from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import zig_checks  # noqa: E402,F401  (registram os checks, nesta ordem)
import doc_checks  # noqa: E402,F401
import golden  # noqa: E402,F401
import pytest_checks  # noqa: E402,F401
from registry import CHECKS, Result  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--grupos", help="só estes grupos, separados por vírgula")
    ap.add_argument("--so", help="só os checks cujo nome contém este texto")
    ap.add_argument("--tudo", action="store_true", help="inclui os checks lentos")
    ap.add_argument("--ref", default="origin/main", help="referência da regressão bit a bit (commit ou branch)")
    ap.add_argument("--rapido", action="store_true", help="regressão sem a decolagem (só coeficientes e trimagem)")
    ap.add_argument("--lista", action="store_true")
    ap.add_argument("--relatorio", help="grava o resultado em Markdown neste arquivo")
    a = ap.parse_args(argv)
    golden.OPTS.update(ref=a.ref, rapido=a.rapido)
    groups = set(a.grupos.split(",")) if a.grupos else None
    sel = [c for c in CHECKS if (groups is None or c.grupo in groups) and (a.so is None or a.so in c.nome)
           and (a.tudo or not c.lento or a.so)]
    if a.lista:
        for c in CHECKS:
            print(f"{c.grupo:10s} {c.nome}{'  (lento)' if c.lento else ''}")
        return 0
    rows = []
    t0 = time.time()
    for c in sel:
        print(f"▶ {c.grupo} · {c.nome} …", flush=True)
        try:
            r: Result = c.fn()
        except Exception as e:                          # um check com bug não derruba os outros
            r = Result(False, f"o check quebrou: {e!r}")
        mark = "⏭" if r.pulado else ("✅" if r.ok else "❌")
        print(f"  {mark} {r.resumo}")
        for ln in r.detalhes:
            print(f"     {ln}")
        rows.append((c, r, mark))
    bad = [c for c, r, _ in rows if not r.ok and not r.pulado]
    print(f"\n{len(rows) - len(bad)}/{len(rows)} ok em {time.time() - t0:.0f} s" + (f"; falharam: {len(bad)}" if bad else ""))
    if a.relatorio:
        with open(a.relatorio, "w", encoding="utf-8") as fh:
            fh.write("| | grupo | check | resultado |\n|---|---|---|---|\n")
            for c, r, mark in rows:
                fh.write(f"| {mark} | {c.grupo} | {c.nome} | {r.resumo} |\n")
            for c, r, _ in rows:
                if r.detalhes:
                    fh.write(f"\n**{c.nome}**\n\n```\n" + "\n".join(r.detalhes) + "\n```\n")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())

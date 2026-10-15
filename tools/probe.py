"""Sonda dos modificadores pela linha de comando: chama o módulo do núcleo (core/src/modifiers/) direto, sem
simulação e sem GUI, e escreve um CSV (e, se pedir, um gráfico). Nenhuma conta é feita aqui.

    python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02                 # CSV na tela
    python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02 --csv solo.csv --png solo.png
    python tools/probe.py solo --metodo desligado --b 2.2 --h 0.1
"""
from __future__ import annotations

import argparse
import csv
import os
import sys

import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

GROUND = {"desligado": 0, "mccormick": 1}        # core/src/modifiers/types.zig


def span(text: str) -> np.ndarray:
    """'a' ou 'a:b:passo' (b incluído)"""
    p = [float(x) for x in text.split(":")]
    if len(p) == 1:
        return np.array(p)
    a, b, d = p
    return np.arange(a, b + 0.5 * d, d)


def solo(args) -> tuple[list[str], list[list[float]]]:
    from aerosim.backend.zig import ZigBackend
    h = span(args.h)
    phi = ZigBackend().probe_ground(GROUND[args.metodo], h, args.b)
    return ["h_m", "h_sobre_b", "fator_CDi"], [[x, x / args.b, f] for x, f in zip(h, phi)]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("solo", help="fator do arrasto induzido no efeito solo × altura")
    s.add_argument("--metodo", choices=sorted(GROUND), default="mccormick")
    s.add_argument("--b", type=float, required=True, help="envergadura (m)")
    s.add_argument("--h", required=True, help="altura (m): valor ou início:fim:passo")
    for p in (s,):
        p.add_argument("--csv", help="grava o CSV aqui (senão, na tela)")
        p.add_argument("--png", help="desenha o gráfico aqui")
    args = ap.parse_args(argv)
    head, rows = {"solo": solo}[args.cmd](args)
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(head)
            w.writerows(rows)
    else:
        print(",".join(head))
        for r in rows:
            print(",".join(f"{x:.6g}" for x in r))
    if args.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        a = np.array(rows)
        fig, ax = plt.subplots(figsize=(6, 4), dpi=110)
        ax.plot(a[:, 1], a[:, 2], lw=2)
        ax.set_xlabel("h / b")
        ax.set_ylabel("fator do C_Di")
        ax.set_title(f"efeito solo: {args.metodo}")
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(args.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

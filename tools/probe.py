"""Sonda dos modificadores pela linha de comando: chama o módulo do núcleo (core/src/modifiers/) direto, sem
simulação e sem GUI, e escreve um CSV (e, se pedir, um gráfico). Nenhuma conta é feita aqui.

    python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02                 # CSV na tela
    python tools/probe.py solo --b 2.2 --h 0.02:1.0:0.02 --csv solo.csv --png solo.png
    python tools/probe.py solo --metodo desligado --b 2.2 --h 0.1
    python tools/probe.py esteira --T 30 --Q 1.2 --D 0.38 --V 10 --x=-0.3:1.5:0.02 --png esteira.png
    python tools/probe.py esteira --T 30 --Q 1.2 --D 0.38 --V 10 --x 0.5 --r 0:0.25:0.01     # corte radial
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


def esteira(args) -> tuple[list[str], list[list[float]]]:
    """esteira de um motor (eixo +x do corpo); x a partir do disco, positivo para trás; r: distância do eixo"""
    from aerosim.backend.zig import ZigBackend
    xs, rs = span(args.x), span(args.r)
    pts = [(-x, r, 0.0) for x in xs for r in rs]
    o = ZigBackend().probe_slipstream(args.T, args.Q, args.D, args.V, args.rho, args.sentido, np.array(pts))
    rows = [[x, r, a[0], abs(a[2]), a[3], a[4]] for (x, r), a in zip([(x, r) for x in xs for r in rs], o)]
    return ["x_m", "r_m", "axial_m_s", "giro_m_s", "raio_tubo_m", "dentro"], rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("solo", help="fator do arrasto induzido no efeito solo × altura")
    s.add_argument("--metodo", choices=sorted(GROUND), default="mccormick")
    s.add_argument("--b", type=float, required=True, help="envergadura (m)")
    s.add_argument("--h", required=True, help="altura (m): valor ou início:fim:passo")
    e = sub.add_parser("esteira", help="esteira de um motor por disco atuador: axial, giro e raio do tubo")
    e.add_argument("--T", type=float, required=True, help="tração (N)")
    e.add_argument("--Q", type=float, default=0.0, help="torque (N·m)")
    e.add_argument("--D", type=float, required=True, help="diâmetro da hélice (m)")
    e.add_argument("--V", type=float, default=0.0, help="velocidade do ar ao longo do eixo (m/s)")
    e.add_argument("--rho", type=float, default=1.225)
    e.add_argument("--sentido", type=float, default=1.0, help="+1 horário visto de trás, −1 anti-horário")
    e.add_argument("--x", default="-0.3:1.5:0.02", help="distância atrás do disco (m): valor ou início:fim:passo")
    e.add_argument("--r", default="0.05", help="distância do eixo (m): valor ou início:fim:passo")
    for p in (s, e):
        p.add_argument("--csv", help="grava o CSV aqui (senão, na tela)")
        p.add_argument("--png", help="desenha o gráfico aqui")
    args = ap.parse_args(argv)
    head, rows = {"solo": solo, "esteira": esteira}[args.cmd](args)
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
        if args.cmd == "solo":
            fig, ax = plt.subplots(figsize=(6, 4), dpi=110)
            ax.plot(a[:, 1], a[:, 2], lw=2)
            ax.set_xlabel("h / b")
            ax.set_ylabel("fator do C_Di")
            ax.set_title(f"efeito solo: {args.metodo}")
            ax.grid(alpha=0.3)
        else:
            radial = len(np.unique(a[:, 1])) > 1
            k = 1 if radial else 0
            fig, axs = plt.subplots(1, 3, figsize=(13, 3.8), dpi=110)
            for ax_, col, lab in zip(axs, (2, 3, 4), ("velocidade axial a mais (m/s)", "giro (m/s)", "raio do tubo (m)")):
                ax_.plot(a[:, k], a[:, col], lw=2)
                ax_.set_xlabel("r (m), distância do eixo" if radial else "x (m) atrás do disco")
                ax_.set_title(lab)
                ax_.grid(alpha=0.3)
            fig.suptitle(f"esteira: T = {args.T:g} N, Q = {args.Q:g} N·m, D = {args.D:g} m, V = {args.V:g} m/s")
        fig.tight_layout()
        fig.savefig(args.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Carga ao longo da envergadura (y em metros) da asa e da EH, com e sem um modificador (ex.: a esteira), direto do
núcleo (`aerosim_panel_states`). As faixas da superfície são refinadas (mesma geometria) até o limite de painéis do
núcleo, só para ver a distribuição. Nenhuma conta aerodinâmica é feita aqui.

    python tools/span_load.py data/aircraft/Convencional_original.json --com esteira.disco --png carga.png
    python tools/span_load.py meu_aviao.json --V 10 --alpha 4 --acelerador 0.8 --com esteira.disco --csv carga.csv
"""
from __future__ import annotations

import argparse
import copy
import csv
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

GROUPS = ((0, "asa", "wing"), (1, "EH", "htail"))


def refine(ac, role: str, max_panels: int):
    """a superfície `role` com o máximo de faixas (por lado) que cabe no núcleo; a geometria não muda"""
    from aerosim.backend.zig.translator import native_spec
    from aerosim.model.aircraft import WingSection
    for n in range(24, 1, -1):
        a = copy.deepcopy(ac)
        for s in a.surfaces:
            if s.role != role or s.vertical or len(s.sections) < 2 or any(q.airfoil is not None for q in s.sections):
                continue
            ss = sorted(s.sections, key=lambda q: q.y)
            ys = sorted(set(np.round(np.r_[np.linspace(0, ss[-1].y, n + 1), [q.y for q in ss]], 6)))
            f = lambda k: np.interp(ys, [q.y for q in ss], [getattr(q, k) for q in ss])
            s.sections = [WingSection(y, c, x, t) for y, c, x, t in zip(ys, f("chord"), f("x_offset"), f("twist"))]
        if len(native_spec(a)["surf"]) <= max_panels:
            return a
    return ac


def states(backend, ac, V, alpha, thr):
    from aerosim.model.universal import build_model
    with backend.session_for(build_model(ac)) as s:
        n = len([u for u in ac.propulsion if u.enabled])
        pts = [s.prop_point(i, V, thr) for i in range(n)]
        T, Q = [p["T"] for p in pts], [p["Q"] for p in pts]
        return s.panel_states(V, math.radians(alpha), 0.0, T, Q), T


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("aviao")
    ap.add_argument("--com", action="append", default=[], help="modificador comparado (tipo, ex.: esteira.disco)")
    ap.add_argument("--V", type=float, default=8.0, help="velocidade (m/s)")
    ap.add_argument("--alpha", type=float, default=2.0, help="α do corpo (°)")
    ap.add_argument("--acelerador", type=float, default=1.0)
    ap.add_argument("--csv")
    ap.add_argument("--png")
    args = ap.parse_args(argv)
    from aerosim.backend.zig import ZigBackend
    from aerosim.data import load_aircraft
    from aerosim.model import modifiers as mods
    be = ZigBackend()
    base = load_aircraft(args.aviao)
    limit = be.schema.limits["surfaces"]
    rows, curves, T = [], {}, []
    for g, gname, role in GROUPS:
        a0 = refine(base, role, limit)
        a1 = copy.deepcopy(a0)
        for k in args.com:
            a1.modifiers.append(mods.Modifier(k))
        for lab, a in (("sem", a0), ("com " + "+".join(args.com) if args.com else "com", a1)):
            P, T = states(be, a, args.V, args.alpha, args.acelerador)
            k = P["group"] == g
            if not k.any():
                continue
            o = np.argsort(P["r"][k][:, 1])
            y = P["r"][k][:, 1][o]
            span = (P["S"][k] / P["c"][k])[o]
            c = dict(y=y, V=P["V"][k][o] / args.V, alpha=np.degrees(P["alpha"][k][o]), Lm=P["L"][k][o] / span,
                     L=P["L"][k].sum())
            curves[(gname, lab)] = c
            rows += [[gname, lab, yy, vv, aa, ll] for yy, vv, aa, ll in zip(c["y"], c["V"], c["alpha"], c["Lm"])]
    head = ["superficie", "caso", "y_m", "V_local_sobre_V", "alpha_local_graus", "sustentacao_N_por_m"]
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(head)
            w.writerows(rows)
    for (gname, lab), c in curves.items():
        print(f"{gname:4s} {lab:24s} sustentação total = {c['L']:.2f} N")
    if args.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(3, 2, figsize=(14, 9.5), dpi=100, sharex="col")
        for col, (_, gname, _) in enumerate(GROUPS):
            mine = [(lab, c) for (gn, lab), c in curves.items() if gn == gname]
            if not mine:
                for r in range(3):
                    ax[r, col].set_visible(False)
                continue
            for (lab, c), (color, ls) in zip(mine, (("#1f4e8c", "-"), ("#d95f02", "--"))):
                for r, (k, t) in enumerate((("V", "velocidade local / V∞"), ("alpha", "α local (°)"),
                                            ("Lm", "sustentação por metro de envergadura (N/m)"))):
                    ax[r, col].plot(c["y"], c[k], color=color, ls=ls, lw=2, label=lab)
                    ax[r, col].set_title(f"{gname}: {t}")
                    ax[r, col].grid(alpha=0.3)
            for u in base.propulsion:
                if u.enabled:
                    for a_ in ax[:, col]:
                        a_.axvspan(u.y - u.propeller.D / 2, u.y + u.propeller.D / 2, color="#999999", alpha=0.15)
            ax[2, col].set_xlabel("y (m) — envergadura (+ direita)")
            ax[0, col].legend(fontsize=9)
        fig.suptitle(f"{os.path.basename(args.aviao)} — V = {args.V:g} m/s, α = {args.alpha:g}°, acelerador "
                     f"{args.acelerador:g} (T = {', '.join(f'{t:.1f}' for t in T)} N); cinza = disco da hélice", fontsize=10)
        fig.tight_layout(rect=(0, 0, 1, 0.95))
        fig.savefig(args.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

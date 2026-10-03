"""Figuras das abas Aerodinâmica e Estabilidade (PNG), iguais ao que a GUI mostra.

    python tools/plot_comparativo.py [saida/] [conventional|flying_wing|twin_boom|arquivo.cfg ...]

Para cada aeronave: <nome>_aero_diagnostico.png, <nome>_aero_graficos.png,
<nome>_estab_diagnostico.png, <nome>_estab_graficos.png. Os gráficos vêm das PlotSpec da
própria simulação (`plots_for(aeronave)`): só aparece o que existe nessa configuração.
"""
from __future__ import annotations

import math
import os
import sys
import textwrap

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from aerosim.manager import SimulationManager  # noqa: E402
from aerosim.model import templates  # noqa: E402

# paleta categórica validada (ordem fixa)
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
MK = ["o", "s", "^", "D", "v", "P", "X", "*"]
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
STATUS = {"falha": ("✖ FALHA", "#fbdada"), "atencao": ("⚠ ATENÇÃO", "#fff1cc"), "ok": ("✔ OK", "#d9f2e6"),
          "info": ("ℹ INFO", "#e8eef8")}

plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF, "axes.edgecolor": GRID,
    "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True, "grid.color": GRID,
    "axes.spines.top": False, "axes.spines.right": False, "axes.titlesize": 10, "axes.titleweight": "bold",
    "axes.titlecolor": INK, "axes.titlelocation": "left", "font.size": 8.5, "legend.frameon": False,
    "lines.linewidth": 2, "lines.markersize": 4.5, "axes.axisbelow": True, "figure.dpi": 110,
})


def _tables(spec, res):
    name = spec.source.split(":", 1)[1]
    if name.endswith("*"):
        return [(k[len(name) - 1:], v) for k, v in res.series.items() if k.startswith(name[:-1])]
    t = res.series.get(name)
    return [(name, t)] if t else []


def _has(spec, res):
    return spec.source != "log" and any(t and spec.x in t and any(y in t for y in spec.ys) for _, t in _tables(spec, res))


def draw(ax, spec, res):
    tabs = [(n, t) for n, t in _tables(spec, res) if t and spec.x in t]
    many = len(tabs) > 1
    k = 0
    for tname, t in tabs:
        for y in spec.ys:
            if y not in t:
                continue
            xs, ys = np.asarray(t[spec.x], float), np.asarray(t[y], float)
            if spec.swap:
                xs, ys = ys, xs
            lab = (f"{tname}: {y}" if len(spec.ys) > 1 else tname) if many else y
            if t.get("_marker"):
                ax.plot(xs, ys, ls="none", marker="o", ms=9, color=C[k % 8], markeredgecolor=SURF, label=lab)
                k += 1
            elif t.get("_dash"):
                ax.plot(xs, ys, color=INK2 if len(xs) == 2 else C[k % 8], ls="--", lw=1.2, label=lab)
                if len(xs) != 2:
                    k += 1
            else:
                ax.plot(xs, ys, color=C[k % 8], marker=MK[k % 8], markevery=max(1, len(xs) // 8),
                        markeredgecolor=SURF, markeredgewidth=0.6, label=lab)
                k += 1
    xl, yl = (spec.ylabel, spec.xlabel) if spec.swap else (spec.xlabel, spec.ylabel)
    ax.set_xlabel(xl)
    ax.set_ylabel(yl)
    ax.set_title("\n".join(textwrap.wrap(spec.title, 62)))
    ax.legend(fontsize=7, loc="best")


def plots_figure(sim, ac, res, path, title):
    specs = [s for s in sim.plots_for(ac) if _has(s, res)]
    n = len(specs)
    cols = 3 if n > 4 else 2
    rows = math.ceil(n / cols)
    f, axs = plt.subplots(rows, cols, figsize=(6.2 * cols, 4.3 * rows), squeeze=False)
    for ax, s in zip(axs.flat, specs):
        draw(ax, s, res)
    for ax in list(axs.flat)[n:]:
        ax.axis("off")
    f.suptitle(title, x=0.01, ha="left", fontsize=13, fontweight="bold", color=INK)
    f.tight_layout()
    f.savefig(path, bbox_inches="tight")
    plt.close(f)


def checks_figure(res, path, title):
    order = {"falha": 0, "atencao": 1, "ok": 2, "info": 3}
    rows = sorted(res.checks, key=lambda c: order.get(c.status, 9))
    widths = [(0.07, 12), (0.18, 34), (0.17, 32), (0.16, 30), (0.21, 40), (0.21, 40)]
    head = ["estado", "verificação", "valor", "critério", "por quê", "o que fazer"]
    cells, heights = [], []
    for c in rows:
        vals = [STATUS[c.status][0], (f"[{c.group}] " if c.group else "") + c.item, c.value, c.criterion, c.why, c.fix]
        wrapped = ["\n".join(textwrap.wrap(v or "", w)) for v, (_, w) in zip(vals, widths)]
        cells.append(wrapped)
        heights.append(max(v.count("\n") + 1 for v in wrapped))
    H = 0.6 + sum(0.17 * h + 0.12 for h in heights)
    f = plt.figure(figsize=(17, H))
    ax = f.add_axes([0, 0, 1, 1])
    ax.axis("off")
    ax.set_xlim(0, 1)
    ax.set_ylim(H, 0)
    ax.text(0.005, 0.25, title, fontsize=13, fontweight="bold", color=INK, va="center")
    y = 0.5
    x0 = 0.005
    for (w, _), h in zip(widths, head):
        ax.text(x0, y, h, fontsize=9, fontweight="bold", color=INK2, va="top")
        x0 += w
    y += 0.22
    for c, cell, h in zip(rows, cells, heights):
        hh = 0.17 * h + 0.12
        ax.add_patch(plt.Rectangle((0.002, y - 0.04), widths[0][0] - 0.006, hh - 0.02, color=STATUS[c.status][1], lw=0))
        x0 = 0.005
        for (w, _), v in zip(widths, cell):
            ax.text(x0, y, v, fontsize=8, color=INK, va="top", linespacing=1.25)
            x0 += w
        ax.plot([0, 1], [y + hh - 0.06] * 2, color=GRID, lw=0.8)
        y += hh
    f.savefig(path, bbox_inches="tight")
    plt.close(f)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "comparativo"
    which = sys.argv[2:] or ["conventional", "flying_wing"]
    os.makedirs(out, exist_ok=True)
    m = SimulationManager()
    for w in which:
        if os.path.exists(w):
            from aerosim.data import load_aircraft
            ac = load_aircraft(w)
            tag = os.path.splitext(os.path.basename(w))[0]
        else:
            ac = getattr(templates, w)()
            tag = w
        for sim_name, short, nice in (("aerodynamics", "aero", "Aerodinâmica"), ("stability", "estab", "Estabilidade")):
            sim = m.get(sim_name)
            print(f"{tag}: {nice}…")
            r = m.run(sim_name, ac, {})
            checks_figure(r, os.path.join(out, f"{tag}_{short}_diagnostico.png"),
                          f"{nice} — {ac.name}: diagnóstico")
            plots_figure(sim, ac, r, os.path.join(out, f"{tag}_{short}_graficos.png"), f"{nice} — {ac.name}")
    print("figuras em", out)


if __name__ == "__main__":
    main()

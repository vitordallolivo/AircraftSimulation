"""Banco de comparação dos otimizadores do aeroopt: qual busca acha o melhor avião, com quantos pontos, em que tipo de
problema. É a linha de base para escolher o otimizador padrão (o plano "aeroopt: otimizador padrão e mapa das
etapas") e para medir um método novo contra os de hoje.

    python tools/banco_otimizadores.py --sementes 5 --avaliacoes 48 --variaveis 6 --png banco.png
    python tools/banco_otimizadores.py --formas acoplada --metodos coordenadas,cma-es --sementes 10
    python tools/banco_otimizadores.py --voa --png banco.png        # também a etapa voa (o caso com remédio)

São duas partes, as duas no avaliador sintético (`aeroopt/synthetic.py`), que roda em segundos e tem o ótimo
sabido. A primeira é a busca das superfícies (`SURFACE_METHODS`): para cada forma do problema (a tigela, a acoplada
e a multimodal), cada método e cada semente, ela roda a busca de verdade (`SyntheticSurfaces`) na melhor
configuração, com `--variaveis` contínuas livres, e guarda o histórico. A medida é a fração do ótimo: o maior MTOW
que fecha até ali sobre o MTOW do ótimo (4 f). Por rodada saem a fração no fim e os pontos até chegar a 99 %; por
método, a mediana. A busca por coordenadas não usa semente (parte sempre do mesmo ponto e anda igual), então roda
uma vez só.

A segunda (`--voa`) é a etapa voa no caso sintético com remédio de `tools/metodos_voa.py`: a taxa de sucesso e as
avaliações por sucesso de cada método de `FLY_METHODS`.

O avião de verdade é a medida que importa, mas é lenta; esta é a de todo dia. Com `--png`, as curvas de
convergência (a mediana e a faixa entre o quartil de baixo e o de cima) por forma e, com `--voa`, as barras da
etapa voa.
"""
from __future__ import annotations

import argparse
import math
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

TARGET = 0.99                  # a fração do ótimo que conta como "chegou"


def problem(n_vars: int):
    """(projeto, problema, item da melhor configuração) do exemplo com `n_vars` contínuas livres"""
    from aeroopt import stages as sg
    from aeroopt import synthetic as sy
    from aeroopt.gui import example_project
    p, pr = example_project()
    pr.params["categorias"] = ["asa alta", "asa baixa", "biplano", "asa voadora", "cauda em V"]
    cont = [v for v in pr.variables if v.kind == "contínua" and v.hi > v.lo]
    if len(cont) < n_vars:
        raise ValueError(f"o exemplo só tem {len(cont)} contínuas")
    first = ("wing.span", "wing.area")                  # as do exemplo primeiro, as outras na ordem do problema
    pick = sorted(cont, key=lambda v: (v.key not in first, cont.index(v)))[:n_vars]
    keys = {v.key for v in pick}
    for v in pr.variables:
        if v.kind == "contínua":
            v.free = v.key in keys
    name = sy.best(p, pr)
    item = next(i for i in sg.configurations(p, pr) if i.name == name)
    return p, pr, item


def run_surfaces(shapes: list, methods: list, seeds: int, evals: int, n_vars: int) -> list[dict]:
    """uma linha por (forma, método, semente): a curva da fração do ótimo, a fração no fim e os pontos até 99 %"""
    from aeroopt import synthetic as sy
    from aerosim.interfaces.optim import StageItem
    p, pr, item0 = problem(n_vars)
    opt = 4 * sy.factor(item0.name)
    rows = []
    for shape in shapes:
        for m in methods:
            for s in range(1 if m == "coordenadas" else seeds):
                st = sy.SyntheticSurfaces(p, pr, evals, m, shape=shape)
                st.seed = s
                item = StageItem(name=item0.name, values=dict(item0.values), data={})
                t0 = time.time()
                st.one(item)
                curve, top = [], 0.0
                for h in item.data["history"]:
                    if h["ok"] and math.isfinite(h["mtow"]):
                        top = max(top, h["mtow"] / opt)
                    curve.append(top)
                reach = next((i + 1 for i, c in enumerate(curve) if c >= TARGET), math.inf)
                rows.append(dict(shape=shape, method=m, seed=s, curve=curve, final=curve[-1] if curve else 0.0,
                                 reach=reach, evals=len(curve), t=time.time() - t0))
                line(rows[-1])
    return rows


def line(r: dict) -> None:
    reach = f"{r['reach']:4d}" if math.isfinite(r["reach"]) else "  --"
    print(f"{r['shape']:10s} {r['method']:12s} semente {r['seed']}  fração do ótimo {100 * r['final']:6.2f} %  "
          f"pontos até {100 * TARGET:.0f} %: {reach}  ({r['evals']} pontos, {r['t']:.2f} s)", flush=True)


def summary(rows: list) -> list[dict]:
    """por (forma, método): a mediana da fração no fim, quantas rodadas chegaram a 99 % e a mediana dos pontos"""
    out = []
    for key in dict.fromkeys((r["shape"], r["method"]) for r in rows):
        g = [r for r in rows if (r["shape"], r["method"]) == key]
        reach = [r["reach"] for r in g if math.isfinite(r["reach"])]
        out.append(dict(shape=key[0], method=key[1], runs=len(g), final=statistics.median(r["final"] for r in g),
                        rate=len(reach) / len(g), reach=statistics.median(reach) if reach else math.inf))
    return out


def _band(curves: list) -> tuple[list, list, list]:
    """(quartil de baixo, mediana, quartil de cima) ponto a ponto; uma curva mais curta segue no último valor"""
    n = max(len(c) for c in curves)
    full = [c + [c[-1]] * (n - len(c)) if c else [0.0] * n for c in curves]
    lo, med, hi = [], [], []
    for i in range(n):
        col = sorted(c[i] for c in full)
        q = statistics.quantiles(col, n=4) if len(col) > 1 else [col[0]] * 3
        lo.append(q[0])
        med.append(statistics.median(col))
        hi.append(q[2])
    return lo, med, hi


def plot(rows: list, voa: list | None, path: str, n_vars: int) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    shapes = list(dict.fromkeys(r["shape"] for r in rows))
    methods = list(dict.fromkeys(r["method"] for r in rows))
    n = len(shapes) + (1 if voa else 0)
    fig, axs = plt.subplots(1, n, figsize=(4.6 * n, 4.2), squeeze=False)
    colors = dict(zip(methods, ("#2a6fdb", "#e0782d", "#2f9e44", "#c2255c", "#7048e8", "#868e96")))
    for ax, shape in zip(axs[0], shapes):
        for m in methods:
            g = [r["curve"] for r in rows if r["shape"] == shape and r["method"] == m]
            if not g:
                continue
            lo, med, hi = _band(g)
            x = range(1, len(med) + 1)
            ax.plot(x, [100 * v for v in med], color=colors[m], label=m)
            if len(g) > 1:
                ax.fill_between(x, [100 * v for v in lo], [100 * v for v in hi], color=colors[m], alpha=0.15)
        ax.axhline(100 * TARGET, color="#868e96", lw=0.8, ls="--")
        ends = [r["curve"][min(1, len(r["curve"]) - 1)] for r in rows if r["shape"] == shape and r["curve"]]
        ax.set_ylim(max(0.0, 100 * min(ends, default=0.8) - 5), 100.5)   # do segundo ponto da pior rodada ao ótimo
        ax.set_title(f"{shape}, {n_vars} contínuas")
        ax.set_xlabel("pontos avaliados")
        ax.set_ylabel("melhor MTOW que fecha / ótimo (%)")
        ax.legend(fontsize=8, loc="lower right")
    if voa:
        ax = axs[0][-1]
        names = [s["method"] for s in voa]
        per = [s["per_success"] if math.isfinite(s["per_success"]) else 0 for s in voa]
        ax.bar(names, per, color="#2a6fdb")
        for i, s in enumerate(voa):
            label = f"{100 * s['rate']:.0f} %" if math.isfinite(s["per_success"]) else "nenhuma\nvoou"
            ax.text(i, per[i], label, ha="center", va="bottom", fontsize=8)
        ax.set_title("etapa voa: avaliações por sucesso\n(no topo, a taxa de sucesso)")
        ax.tick_params(axis="x", rotation=35)
    fig.tight_layout()
    fig.savefig(path, dpi=110)


def main(argv=None) -> int:
    from aeroopt import synthetic as sy
    from aeroopt.stages import FLY_METHODS, SURFACE_METHODS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--formas", default=",".join(sy.SHAPES), help="formas do problema (as de synthetic.SHAPES)")
    ap.add_argument("--metodos", default=",".join(SURFACE_METHODS), help="métodos das superfícies (SURFACE_METHODS)")
    ap.add_argument("--sementes", type=int, default=5)
    ap.add_argument("--avaliacoes", type=int, default=48, help="pontos por busca")
    ap.add_argument("--variaveis", type=int, default=6, help="contínuas livres")
    ap.add_argument("--voa", action="store_true", help="também a etapa voa, no caso com remédio")
    ap.add_argument("--png", help="grava as curvas de convergência (e as barras da etapa voa)")
    a = ap.parse_args(argv)
    shapes, methods = a.formas.split(","), a.metodos.split(",")
    bad = [s for s in shapes if s not in sy.SHAPES] + [m for m in methods if m not in SURFACE_METHODS]
    if bad:
        ap.error(f"desconhecido: {', '.join(bad)}")
    rows = run_surfaces(shapes, methods, a.sementes, a.avaliacoes, a.variaveis)
    print()
    for s in summary(rows):
        reach = f"{s['reach']:5.0f}" if math.isfinite(s["reach"]) else "   --"
        print(f"{s['shape']:10s} {s['method']:12s} fração no fim (mediana) {100 * s['final']:6.2f} %  "
              f"chegaram a {100 * TARGET:.0f} %: {100 * s['rate']:5.1f} %  pontos (mediana) {reach}  "
              f"({s['runs']} rodadas)")
    voa = None
    if a.voa:
        sys.path.append(os.path.dirname(os.path.abspath(__file__)))     # depois do pacote aeroopt (tools/aeroopt.py)
        import metodos_voa as mv
        print()
        voa = mv.summary(mv.run_synthetic([m for m in FLY_METHODS if m != "conferir"], a.sementes, 60))
        print()
        for s in voa:
            print(f"voa {s['method']:12s} voa {100 * s['rate']:5.1f} %  por sucesso {s['per_success']:7.1f}")
    if a.png:
        plot(rows, voa, a.png, a.variaveis)
        print("gravado:", a.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

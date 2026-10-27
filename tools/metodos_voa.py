"""Qual busca da etapa voa (E&C) do aeroopt acha mais rápido um avião que voa? Compara os métodos de FLY_METHODS.

    python tools/metodos_voa.py --sintetico --sementes 10 --png metodos.png
    python tools/metodos_voa.py data/sprint/projeto_s1223.json --categoria tandem --pista 55 --obstaculo 0.9 \\
        --desligar V_S,RC --sem-liquido --sementes 3 --avaliacoes 48 --png tandem.png

Cada método roda com `--sementes` sementes na mesma configuração, e sai uma linha por rodada: voou ou não, as
avaliações gastas até o primeiro ponto que voa, o tempo e, quando não voa, o motivo do melhor ponto. No fim, por
método: a taxa de sucesso, a média e a mediana das avaliações das rodadas que voaram, e as avaliações por sucesso
(o total gasto, voando ou não, dividido pelo número de sucessos; é a medida que junta as duas coisas). Com `--png`,
as duas em barras.

`--sintetico` troca o avião pelo caso com remédio de tests/aeroopt/test_stages.py: doze contínuas, e só duas
consertam as duas falhas (a deriva no C_nβ, a carga paga no lastro). Roda em segundos e mostra o que o diagnóstico
ganha quando a tabela acerta. O avião de verdade é a medida que importa: lá a tabela pode errar e a violação tem
saltos. `--sem-liquido` tira a água (a Regular 2026 não tem).
"""
from __future__ import annotations

import argparse
import math
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


def synthetic_case():
    """(contínuas, ponto) do caso com remédio: o "cnb" só depende da deriva, o "lastro" só da posição da carga"""
    free = [("tail.tip_fin", 0.0, 0.5), ("power.x_payload", -0.3, 0.3)] + [(f"v{i}", 0.0, 1.0) for i in range(10)]

    def point(y):
        t = {}
        if y["tail.tip_fin"] < 0.35:
            t["cnb"] = (0.35 - y["tail.tip_fin"]) / 0.1 + 0.1
        if abs(y["power.x_payload"] - 0.12) > 0.03:
            t["lastro"] = abs(y["power.x_payload"] - 0.12) / 0.05
        return dict(values=dict(y), ok=not t, why="; ".join(t), mtow=math.nan, viol=sum(t.values()), terms=t)
    return free, point


def run_synthetic(methods: list, seeds: int, evals: int) -> list[dict]:
    from aeroopt import stages as sg
    from aeroopt.guided import GUIDED, guided_search
    plain = {"buscar": sg._real_search, "cma-es": sg._cma_search, "de": sg._de_search}
    free, point = synthetic_case()
    x0 = {k: lo for k, lo, _ in free}
    rows = []
    for m in methods:
        for s in range(seeds):
            h, t0 = [], time.time()
            if m in GUIDED:
                _, b = guided_search(free, dict(x0), point(x0), point, evals, h, seed=s, stop_ok=True, mode=m)
            else:
                _, b = plain[m](free, dict(x0), point(x0), point, evals, h, seed=s, stop_ok=True)
            rows.append(dict(method=m, seed=s, ok=b["ok"], evals=len(h), t=time.time() - t0, why=b["why"]))
            line(rows[-1])
    return rows


def run_aircraft(project, categoria: str | None, methods: list, seeds: int, evals: int) -> list[dict]:
    import aeroopt
    from aeroopt import stages as sg
    pr = aeroopt.from_project(project, "métodos da E&C")
    if categoria:
        pr.params["categorias"] = [categoria]
    item0 = sg.configurations(project, pr)[0]
    rows = []
    for m in methods:
        for s in range(seeds):
            st = sg.FlightCheck(project, pr, evals=evals, method=m, controls=True, seed=s, tails=list(sg.TAILS))
            item = sg.StageItem(name=item0.name, values=dict(item0.values), data={})
            t0 = time.time()
            try:
                st.one(item)
                ok, why = True, ""
            except ValueError as e:
                ok, why = False, str(e)
            hist = item.data.get("voa", {}).get("history", [])
            rows.append(dict(method=m, seed=s, ok=ok, evals=len(hist), t=time.time() - t0, why=why))
            line(rows[-1])
    return rows


def line(r: dict) -> None:
    print(f"{r['method']:12s} semente {r['seed']}  {'voa    ' if r['ok'] else 'não voa'}  avaliações {r['evals']:4d}  "
          f"{r['t']:6.1f} s  {r['why'][:90]}", flush=True)


def summary(rows: list) -> list[dict]:
    out = []
    for m in dict.fromkeys(r["method"] for r in rows):
        g = [r for r in rows if r["method"] == m]
        ok = [r["evals"] for r in g if r["ok"]]
        total = sum(r["evals"] for r in g)
        out.append(dict(method=m, rate=len(ok) / len(g), mean=statistics.mean(ok) if ok else math.nan,
                        median=statistics.median(ok) if ok else math.nan,
                        per_success=total / len(ok) if ok else math.inf, t=sum(r["t"] for r in g) / len(g)))
    return out


def plot(summ: list, title: str, path: str) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    names = [s["method"] for s in summ]
    fig, (a, b) = plt.subplots(1, 2, figsize=(12, 4.5))
    a.bar(names, [100 * s["rate"] for s in summ], color="#2a6fdb")
    a.set_ylabel("rodadas que voaram (%)")
    a.set_ylim(0, 105)
    a.set_title("taxa de sucesso")
    per = [s["per_success"] if math.isfinite(s["per_success"]) else 0 for s in summ]
    b.bar(names, per, color="#e0782d")
    for i, s in enumerate(summ):
        if not math.isfinite(s["per_success"]):
            b.text(i, 0, "nenhuma\nvoou", ha="center", va="bottom", fontsize=8)
    b.set_ylabel("avaliações gastas por sucesso")
    b.set_title("custo (menor é melhor)")
    for ax in (a, b):
        ax.tick_params(axis="x", rotation=30)
    fig.suptitle(title)
    fig.tight_layout()
    fig.savefig(path, dpi=110)


def main(argv=None) -> int:
    from aeroopt.stages import FLY_METHODS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("projeto", nargs="?", help="projeto da sprint (.json); sem ele, use --sintetico")
    ap.add_argument("--sintetico", action="store_true", help="o caso com remédio, sem avião (segundos)")
    ap.add_argument("--metodos", default=",".join(m for m in FLY_METHODS if m != "conferir"),
                    help="métodos separados por vírgula (os de FLY_METHODS)")
    ap.add_argument("--categoria", help="tipo de avião (asa alta, biplano, tandem, asa voadora...)")
    ap.add_argument("--sementes", type=int, default=3)
    ap.add_argument("--avaliacoes", type=int, default=48, help="pontos por busca")
    ap.add_argument("--pista", type=float, help="corrida de decolagem (m); a Regular 2026 pede 55")
    ap.add_argument("--obstaculo", type=float, help="altura do obstáculo no fim da pista (m); a Regular 2026, 0,9")
    ap.add_argument("--desligar", help="restrições desligadas, separadas por vírgula (ex.: V_S,RC na Regular)")
    ap.add_argument("--sem-liquido", action="store_true", help="sem a água (a Regular 2026 não tem)")
    ap.add_argument("--png", help="grava a taxa de sucesso e o custo de cada método")
    a = ap.parse_args(argv)
    methods = a.metodos.split(",")
    unknown = [m for m in methods if m not in FLY_METHODS or m == "conferir"]
    if unknown:
        ap.error(f"método desconhecido: {', '.join(unknown)}")
    if a.sintetico:
        rows = run_synthetic(methods, a.sementes, a.avaliacoes)
        title = "caso sintético com remédio"
    else:
        if not a.projeto:
            ap.error("falta o projeto (ou --sintetico)")
        from aerosim.design.project import DesignProject
        p = DesignProject.load(a.projeto)
        if a.pista is not None:
            p.requirements.takeoff_run = a.pista
        if a.obstaculo is not None:
            p.requirements.obstacle_h = a.obstaculo
        for c in p.requirements.constraints:
            if c.key in (a.desligar or "").split(","):
                c.active = False
        if a.sem_liquido:
            p.power_draft.liquid = False
        rows = run_aircraft(p, a.categoria, methods, a.sementes, a.avaliacoes)
        title = f"{a.categoria or 'configuração do projeto'}, {a.avaliacoes} avaliações por busca"
    summ = summary(rows)
    print()
    for s in summ:
        print(f"{s['method']:12s} voa {100 * s['rate']:5.1f} %  avaliações (média {s['mean']:6.1f}, mediana "
              f"{s['median']:6.1f})  por sucesso {s['per_success']:7.1f}  {s['t']:6.1f} s por rodada")
    if a.png:
        plot(summ, title, a.png)
        print("gravado:", a.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

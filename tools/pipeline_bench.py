"""Compara as estratégias de paralelismo do processo em etapas do aeroopt: o mesmo lote de configurações roda em série,
em linhas de execução (threads) e em processos (fork, spawn, forkserver), e sai o tempo de cada etapa, o ganho sobre
a série e quanto de cada etapa fica preso ao GIL.

    python tools/pipeline_bench.py --exemplo                         # projeto de exemplo, 8 configurações
    python tools/pipeline_bench.py --projeto p.json --problema q.opt.json --configs 12 --processos 2,4
    python tools/pipeline_bench.py --exemplo --estrategias serie,threads,spawn --png bench.png
    python tools/pipeline_bench.py --exemplo --geracoes 4 --estrategias serie,spawn,spawn-novo   # o pool que dura
    python tools/pipeline_bench.py --exemplo --sintetico 0.01          # dados de teste: só o custo do paralelismo

O Python só deixa uma linha de execução rodar código Python por vez (o GIL, *global interpreter lock*). As chamadas
ao núcleo em Zig (ctypes) soltam o GIL, então uma etapa que passa quase todo o tempo no núcleo ganha com threads, e
uma que passa o tempo em Python (montar o avião, traduzir, as buscas) não ganha nada. Processos não dividem o GIL,
mas pagam para nascer (spawn importa tudo de novo) e para mandar cada candidato de um lado para o outro (pickle).

O tempo de abrir os processos (com o núcleo já carregado em cada um) aparece numa coluna "nascer": ele acontece uma
vez por rodada, e sem separar parecia que a primeira etapa em paralelo (a "voa") não ganhava nada.

A parte presa ao GIL sai da lei de Amdahl: com $n$ threads e ganho $S = T_1 / T_n$, a fração serial é
$f = (n/S - 1)/(n - 1)$ (Amdahl, "Validity of the single processor approach...", AFIPS 1967; a forma invertida é a
de Karp e Flatt, CACM 33(5), 1990). Com threads, $f$ é quase toda o GIL; com processos, é o custo de nascer, de
mandar os dados e o desequilíbrio entre os candidatos. Cada estratégia também confere se o resultado saiu igual ao
da série (mesmos vivos, mesma nota): uma estratégia rápida e errada aparece como "difere".

Com `--geracoes N` o lote passa N vezes, como nas gerações do otimizador. As estratégias de processos guardam os
trabalhadores a rodada inteira (`aerosim.parallel.Executors`); as com "-novo" no nome fazem como antes, um pool novo
a cada etapa de cada geração, e a diferença entre as duas é o custo de nascer.
"""
from __future__ import annotations

import argparse
import copy
import math
import os
import random
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

STRATEGIES = {"serie": ("não", None), "threads": ("threads", None), "fork": ("processos", "fork"),
              "spawn": ("processos", "spawn"), "forkserver": ("processos", "forkserver"),
              "spawn-novo": ("processos", "spawn"), "forkserver-novo": ("processos", "forkserver")}


def karp_flatt(speedup: float, n: int) -> float:
    """a fração serial pela lei de Amdahl invertida (Karp e Flatt, 1990): f = (n/S − 1)/(n − 1)"""
    if n <= 1 or not speedup > 0:
        return math.nan
    return (n / speedup - 1) / (n - 1)


def sample(project, problem, n: int, seed: int = 1) -> list:
    """`n` configurações sorteadas entre as combinações dos eixos discretos (todas, se couberem)"""
    from aeroopt import stages as sg
    ax = sg.axes(project, problem)
    total = math.prod(len(o) for _, o in ax) if ax else 1
    rnd = random.Random(seed)
    picks = range(total) if total <= n else sorted(rnd.sample(range(total), n))
    items = []
    for k, flat in enumerate(picks):
        values = {}
        for name, opts in reversed(ax):
            flat, j = divmod(flat, len(opts))
            values[name] = opts[j]
        items.append(sg.config_item(dict(reversed(list(values.items()))), k + 1))
    return items


def run_one(project, problem, evaluator, items, strategy: str, workers: int, generations: int = 1):
    """o lote `generations` vezes numa estratégia: (tempo total, [(etapa, tempo somado)], assinatura do resultado)"""
    from aeroopt.pipeline import Pipeline
    from aerosim.parallel import Executors
    parallel, method = STRATEGIES[strategy]
    n = 1 if strategy == "serie" else workers
    warm = getattr(evaluator, "warm", None)
    shared = None if strategy.endswith("-novo") else Executors(n, method, warm)   # None: um pool por etapa, como antes
    times: dict[str, float] = {}
    t0 = time.perf_counter()
    if shared is not None and parallel == "processos" and n > 1:
        shared.get("processos").start()           # nascer fica numa coluna dele: acontece uma vez por rodada
        times["nascer"] = time.perf_counter() - t0
    try:
        for _ in range(generations):
            stages = evaluator.stages(project, problem)
            for st in stages:
                if st.parallel != "não":          # a etapa que é sempre em série (lote no núcleo) fica assim
                    st.parallel = parallel
            pipe = Pipeline(stages, method, shared)
            if shared is None:
                pipe._map = _fresh_pool_map(n, method)
            out = pipe.run(copy.deepcopy(items), n)
            for k, v in pipe.times:
                times[k] = times.get(k, 0.0) + v
    finally:
        if shared is not None:
            shared.close()
    total = time.perf_counter() - t0
    nota = (lambda v: round(v, 6) if math.isfinite(v) else None)     # NaN ≠ NaN: sem nota vira None
    sig = [(i.name, i.alive, nota(float(i.data.get("nota", math.nan))), i.why) for i in out]
    return total, list(times.items()), sig


def _fresh_pool_map(n: int, method):
    """o `_map` do Pipeline com um pool novo a cada etapa (o jeito de antes, para comparar com o que dura)"""
    from aeroopt.pipeline import Pipeline
    from aerosim.parallel import make_executor

    def run(st, runner, alive, tick, cancel):
        if runner.kind != "processos":
            return Pipeline._map(st, runner, alive, tick, cancel)
        with make_executor("processos", n, method) as ex:
            return Pipeline._map(st, ex, alive, tick, cancel)
    return run


def bench(project, problem, evaluator, items, strategies, workers_list, log=print, generations: int = 1) -> list[dict]:
    """cada estratégia com cada número de trabalhadores; a série roda uma vez e é a referência"""
    from aeroopt.problem import apply_to_project, fold_bounds
    project, problem = copy.deepcopy(project), copy.deepcopy(problem)
    fold_bounds(problem, project)
    apply_to_project(problem, project)
    t1, st1, ref = run_one(project, problem, evaluator, items, "serie", 1, generations)
    rows = [dict(strategy="serie", n=1, total=t1, stages=dict(st1), same=True)]
    log(f"série: {t1:.2f} s  " + "  ".join(f"{k} {v:.2f}" for k, v in st1))
    for s in strategies:
        if s == "serie":
            continue
        for n in workers_list:
            try:
                tn, stn, sig = run_one(project, problem, evaluator, items, s, n, generations)
            except Exception as e:  # noqa: BLE001 — uma estratégia que quebra não derruba a comparação
                rows.append(dict(strategy=s, n=n, total=math.nan, stages={}, same=False, error=str(e)))
                log(f"{s} × {n}: falhou ({e})")
                continue
            rows.append(dict(strategy=s, n=n, total=tn, stages=dict(stn), same=sig == ref))
            log(f"{s} × {n}: {tn:.2f} s, ganho {t1 / tn:.2f}" + ("" if sig == ref else "  (resultado difere da série)"))
    for r in rows:
        r["speedup"] = t1 / r["total"] if r["total"] > 0 else math.nan
        r["serial_frac"] = karp_flatt(r["speedup"], r["n"])
        r["stage_speedup"] = {k: dict(st1)[k] / v for k, v in r["stages"].items() if v > 0 and k in dict(st1)}
    return rows


def table(rows: list[dict]) -> str:
    stages = (["nascer"] if any("nascer" in r["stages"] for r in rows) else []) + list(rows[0]["stages"])
    head = f"{'estratégia':<16}{'n':>3}{'total (s)':>11}{'ganho':>8}{'serial':>8}  " + "".join(f"{s[:12]:>14}" for s in stages)
    lines = [head, "-" * len(head)]
    for r in rows:
        cells = "".join(f"{r['stages'].get(s, 0.0):>9.2f}      " if s == "nascer" else
                        f"{r['stages'].get(s, math.nan):>9.2f} ×{r['stage_speedup'].get(s, 1.0 if r['strategy'] == 'serie' else math.nan):<4.1f}"
                        for s in stages)
        flag = "" if r["same"] else ("  falhou" if r.get("error") else "  difere")
        lines.append(f"{r['strategy']:<16}{r['n']:>3}{r['total']:>11.2f}{r['speedup']:>8.2f}"
                     f"{r['serial_frac']:>8.2f}  {cells}{flag}")
    return "\n".join(lines)


def plot(rows: list[dict], path: str) -> None:
    """ganho de cada etapa por estratégia (barras), com a linha do ganho ideal"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    stages = list(rows[0]["stages"])
    par = [r for r in rows if r["strategy"] != "serie" and r["stages"]]
    fig, ax = plt.subplots(figsize=(1.6 + 1.4 * len(stages), 4.2))
    w = 0.8 / max(len(par), 1)
    for k, r in enumerate(par):
        xs = [i + (k - (len(par) - 1) / 2) * w for i in range(len(stages))]
        ax.bar(xs, [r["stage_speedup"].get(s, 0) for s in stages], w, label=f"{r['strategy']} × {r['n']}")
    for n in sorted({r["n"] for r in par}):
        ax.axhline(n, color="#999", lw=0.8, ls="--")
    ax.axhline(1, color="#000", lw=0.8)
    ax.set_xticks(range(len(stages)), stages)
    ax.set_ylabel("ganho sobre a série")
    ax.set_title("Ganho por etapa (tracejado: o ideal com n trabalhadores)")
    ax.legend(fontsize=8, ncols=2)
    fig.tight_layout()
    fig.savefig(path, dpi=120)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exemplo", action="store_true", help="o projeto e o problema de exemplo da janela")
    ap.add_argument("--projeto", help="projeto da sprint (.json)")
    ap.add_argument("--problema", help="problema (.opt.json)")
    ap.add_argument("--configs", type=int, default=8, help="quantas configurações no lote (sorteadas)")
    ap.add_argument("--geracoes", type=int, default=1, help="quantas vezes o lote passa (o pool dura a rodada)")
    ap.add_argument("--avaliacoes", type=int, default=6, help="pontos de projeto por configuração nas superfícies")
    ap.add_argument("--processos", default="2,4", help="números de trabalhadores, separados por vírgula")
    ap.add_argument("--estrategias", default="serie,threads,fork,spawn", help=", ".join(STRATEGIES))
    ap.add_argument("--superficies", default="coordenadas", help="método das superfícies")
    ap.add_argument("--seis-gdl", action="store_true", help="inclui a decolagem 6GDL (bem mais lenta)")
    ap.add_argument("--sintetico", type=float, metavar="S", help="os dados de teste (aeroopt/synthetic.py) no lugar "
                    "das contas, com S segundos por ponto: mede só o paralelismo")
    ap.add_argument("--png", help="grava o ganho por etapa")
    a = ap.parse_args(argv)
    import aeroopt
    from aeroopt.stages import StagedEvaluator
    if a.exemplo or not a.projeto:
        from aeroopt.gui import example_project
        project, problem = example_project()
    else:
        from aerosim.design.project import DesignProject
        project = DesignProject.load(a.projeto)
        problem = aeroopt.load(a.problema) if a.problema else aeroopt.from_project(project)
    strategies = [s.strip() for s in a.estrategias.split(",") if s.strip()]
    bad = [s for s in strategies if s not in STRATEGIES]
    if bad:
        ap.error(f"estratégia desconhecida: {', '.join(bad)}")
    workers = [int(x) for x in a.processos.split(",") if x.strip()]
    if a.sintetico is not None:
        from aeroopt.synthetic import SyntheticEvaluator
        ev = SyntheticEvaluator(project, evals=a.avaliacoes, surfaces=a.superficies, delay=a.sintetico)
    else:
        ev = StagedEvaluator(project, six_dof=a.seis_gdl, evals=a.avaliacoes, surfaces=a.superficies)
    items = sample(project, problem, a.configs)
    gil = getattr(sys, "_is_gil_enabled", lambda: True)()
    print(f"{len(items)} configurações × {a.geracoes} gerações, {a.avaliacoes} avaliações cada · "
          f"{os.cpu_count()} núcleos · "
          f"Python {sys.version.split()[0]} com GIL {'ligado' if gil else 'desligado (free-threaded)'}")
    rows = bench(project, problem, ev, items, strategies, workers, generations=a.geracoes)
    print()
    print(table(rows))
    print("\nganho = série / estratégia; serial = fração que não paraleliza (Karp e Flatt): nas threads, quase toda é "
          "o GIL")
    if a.png:
        plot(rows, a.png)
        print(f"gravado: {a.png}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

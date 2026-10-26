"""A etapa voa (E&C) do aeroopt com sementes, inícios e partidas diferentes: todos caem no mesmo avião?

    python tools/sementes.py data/sprint/projeto_s1223.json --categoria "asa voadora" --sementes 4
    python tools/sementes.py projeto.json --inicio uniforme,lhs --partidas 1,3 --png sementes.png
    python tools/sementes.py projeto.json --categoria tandem --pista 55 --obstaculo 0.9 --desligar V_S,RC

A busca nas contínuas parte de x0 e de uma população pequena. Se ela cai numa bacia ruim de f(x, u), cada semente
acha um avião diferente, e a carga paga na pista muda junto. Aqui a mesma configuração roda com `--sementes`
sementes para cada início (`uniforme`: o de sempre; `lhs`: hipercubo latino) e cada número de partidas, e sai uma
linha por rodada: as avaliações gastas, a carga paga na pista e a distância (na faixa normalizada) até o ponto da
primeira semente. No fim, a dispersão de cada combinação: se a maior distância entre dois pontos passa de
START_DIST, as sementes não concordam e a rodada depende de onde nasceu. Com `--png`, as coordenadas paralelas dos
pontos (uma linha por rodada) e a carga paga.
"""
from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


def rms(a: list, b: list) -> float:
    return math.sqrt(sum((p - q) ** 2 for p, q in zip(a, b)) / max(len(a), 1))


def run(project, categoria: str | None, seeds: int, evals: int, inits: list, starts: list, controls: bool):
    """uma linha por (início, partidas, semente): dict com os valores, a faixa normalizada, a carga paga e o motivo"""
    import aeroopt
    from aeroopt import stages as sg
    pr = aeroopt.from_project(project, "sementes")
    if categoria:
        pr.params["categorias"] = [categoria]
    item0 = sg.configurations(project, pr)[0]
    rows = []
    for init in inits:
        for k in starts:
            for s in range(seeds):
                st = sg.FlightCheck(project, pr, evals=evals, controls=controls, init=init, starts=k, seed=s,
                                    tails=list(sg.TAILS))
                item = sg.StageItem(name=item0.name, values=dict(item0.values), data={})
                try:
                    st.one(item)
                    ok, why = True, ""
                except ValueError as e:
                    ok, why = False, str(e)
                free = st.free_for(item.values)
                u = [(item.values.get(key, math.nan) - lo) / max(hi - lo, 1e-12) for key, lo, hi in free]
                cp = st._runway(item.values) if ok else math.nan
                rows.append(dict(init=init, starts=k, seed=s, ok=ok, why=why, keys=[key for key, _, _ in free], u=u,
                                 cp=cp, evals=len(item.data.get("voa", {}).get("history", [])),
                                 values={key: item.values.get(key) for key, _, _ in free}))
                print(f"{init:9s} partidas {k}  semente {s}  {'voa' if ok else 'não voa'}  avaliações "
                      f"{rows[-1]['evals']:3d}  carga paga {cp:7.3f} kg  {why[:80]}", flush=True)
    return rows


def summary(rows: list, dist: float) -> list[str]:
    out = []
    for init, k in dict.fromkeys((r["init"], r["starts"]) for r in rows):
        g = [r for r in rows if (r["init"], r["starts"]) == (init, k) and r["ok"]]
        if not g:
            out.append(f"{init} partidas {k}: nenhuma semente voa")
            continue
        far = max((rms(a["u"], b["u"]) for a in g for b in g), default=0.0)
        cps = [r["cp"] for r in g if math.isfinite(r["cp"])]
        cp = f"carga paga {min(cps):.3f} a {max(cps):.3f} kg" if cps else "nenhuma decola na pista"
        verdict = "as sementes concordam" if far < dist else "as sementes não concordam: depende de onde nasce"
        out.append(f"{init} partidas {k}: {len(g)} voam, maior distância {far:.2f} da faixa, {cp}; {verdict}")
    return out


def plot(rows: list, path: str) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ok = [r for r in rows if r["ok"]]
    if not ok:
        return
    combos = list(dict.fromkeys((r["init"], r["starts"]) for r in rows))
    colors = dict(zip(combos, ("#2a6fdb", "#e0782d", "#2f9e6e", "#b0398f", "#7a6a3a", "#555555")))
    fig, (a, b) = plt.subplots(1, 2, figsize=(13, 5), gridspec_kw=dict(width_ratios=[3, 1]))
    keys = ok[0]["keys"]
    for r in ok:
        a.plot(range(len(r["u"])), r["u"], "-o", ms=3, lw=1.2, alpha=0.8, color=colors[(r["init"], r["starts"])])
    a.set_xticks(range(len(keys)), [k.split(".")[-1] for k in keys], rotation=60, ha="right", fontsize=8)
    a.set_ylabel("posição na faixa (0 = mínimo, 1 = máximo)")
    a.set_title("ponto que voa de cada semente")
    for i, c in enumerate(combos):
        cps = [r["cp"] for r in ok if (r["init"], r["starts"]) == c and math.isfinite(r["cp"])]
        b.scatter([i] * len(cps), cps, color=colors[c], s=30)
    b.set_xticks(range(len(combos)), [f"{i}\n{k} partida(s)" for i, k in combos], fontsize=8)
    b.set_ylabel("carga paga na pista (kg)")
    b.set_title("carga paga")
    for c in combos:
        a.plot([], [], color=colors[c], label=f"{c[0]}, {c[1]} partida(s)")
    a.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(path, dpi=110)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("projeto", help="projeto da sprint (.json)")
    ap.add_argument("--categoria", help="tipo de avião (asa alta, biplano, tandem, asa voadora...)")
    ap.add_argument("--sementes", type=int, default=4)
    ap.add_argument("--avaliacoes", type=int, default=24, help="pontos por busca")
    ap.add_argument("--inicio", default="uniforme,lhs", help="inícios, separados por vírgula (uniforme, lhs)")
    ap.add_argument("--partidas", default="1", help="partidas, separadas por vírgula (1 = o primeiro que voa)")
    ap.add_argument("--sem-comandos", action="store_true", help="sem os comandos na busca (E&C sem rotação)")
    ap.add_argument("--pista", type=float, help="corrida de decolagem (m); a Regular 2026 pede 55")
    ap.add_argument("--obstaculo", type=float, help="altura do obstáculo no fim da pista (m); a Regular 2026, 0,9")
    ap.add_argument("--desligar", help="restrições desligadas, separadas por vírgula (ex.: V_S,RC na Regular)")
    ap.add_argument("--png", help="grava as coordenadas paralelas e a carga paga")
    a = ap.parse_args(argv)
    from aeroopt.stages import START_DIST
    from aerosim.design.project import DesignProject
    p = DesignProject.load(a.projeto)
    if a.pista is not None:
        p.requirements.takeoff_run = a.pista
    if a.obstaculo is not None:
        p.requirements.obstacle_h = a.obstaculo
    for c in p.requirements.constraints:
        if c.key in (a.desligar or "").split(","):
            c.active = False
    rows = run(p, a.categoria, a.sementes, a.avaliacoes, a.inicio.split(","),
               [int(k) for k in a.partidas.split(",")], not a.sem_comandos)
    print()
    for line in summary(rows, START_DIST):
        print(line)
    if a.png:
        plot(rows, a.png)
        print("gravado:", a.png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

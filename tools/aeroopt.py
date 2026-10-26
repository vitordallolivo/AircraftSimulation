"""Roda um problema do aeroopt (.opt.json) e mostra o resultado: o melhor ponto, as restrições e a convergência.

    python tools/aeroopt.py problema.opt.json                  # imprime
    python tools/aeroopt.py problema.opt.json --png conv.png   # e grava a convergência
    python tools/aeroopt.py --exemplo micro.opt.json           # grava um problema de exemplo (projeto novo da sprint)
    python tools/aeroopt.py problema.opt.json --isolar asa     # só a asa livre (chaves ou grupos, separados por vírgula)

    python tools/aeroopt.py problema.opt.json --etapas --projeto avião.json   # o processo em etapas

Dois avaliadores. O processo em etapas (`aeroopt/stages.py`, `--etapas` ou "evaluator": "etapas" no arquivo)
parte dos rascunhos de um projeto da sprint (`--projeto`): configurações → superfícies pela decolagem → MTOW no
6GDL → nota, com todos esperando entre uma etapa e outra. As configurações saem das gerações
(`aeroopt/generations.py`, `--populacao`, `--geracoes`); com poucas combinações, todas rodam numa geração só. O mini-MDO do núcleo (`aeroopt/mini_mdo.py`) é o
outro; uma pontuação em .toml cujas entradas ele não calcula é avisada, e a busca usa o MTOW.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import aeroopt
from aeroopt.mini_mdo import MiniMdoEvaluator, MiniMdoSolver
from aeroopt.scoring import scoring_for


def _fmt(v) -> str:
    return f"{v:.4g}" if isinstance(v, float) else str(v)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("problema", nargs="?")
    ap.add_argument("--exemplo", metavar="ARQ", help="grava um problema de exemplo e sai")
    ap.add_argument("--isolar", help="só estas variáveis ou grupos ficam livres (vírgula)")
    ap.add_argument("--png", help="grava a convergência (melhor nota viável por iteração)")
    ap.add_argument("--etapas", action="store_true", help="avaliador em etapas (o padrão do arquivo é o mini-MDO)")
    ap.add_argument("--projeto", help="projeto da sprint (.json) de onde saem os rascunhos")
    ap.add_argument("--csv", help="etapas: pasta dos CSV da rodada (padrão: rodadas_aeroopt/<data_hora>)")
    ap.add_argument("--categorias", help="etapas: tipos de avião, separados por vírgula (asa alta, biplano, tandem, "
                    "asa voadora...; ver aeroopt/categories.py)")
    ap.add_argument("--processos", type=int, help="processos por etapa (padrão: um por núcleo)")
    ap.add_argument("--avaliacoes", type=int, default=24, help="pontos de projeto por configuração (superfícies)")
    ap.add_argument("--sem-6gdl", action="store_true", help="pula a etapa da decolagem no 6GDL")
    ap.add_argument("--populacao", type=int, default=16, help="etapas: configurações por geração")
    ap.add_argument("--geracoes", type=int, default=8, help="etapas: gerações (com poucas combinações, uma só)")
    ap.add_argument("--sensibilidade", nargs="?", const="local", choices=["local", "eixos", "morris"],
                    help="etapas: no fim, a sensibilidade do melhor (local: pelo histórico da busca; eixos: um por "
                         "vez; morris: efeitos elementares)")
    ap.add_argument("--tolerancia", type=float, default=1.0, help="sensibilidade: tolerância, %% do valor")
    ap.add_argument("--limites", action="store_true", help="sensibilidade: também a nota com cada limite mudado")
    a = ap.parse_args(argv)
    from aerosim.design.project import DesignProject
    if a.exemplo:
        pr = aeroopt.from_project(DesignProject(), "exemplo: asa e motorização")
        pr.isolate("wing.span", "wing.area", "power.tilt")
        pr.solver.update(particles=12, iterations=8)
        aeroopt.save(pr, a.exemplo)
        print(f"gravado: {a.exemplo}")
        return 0
    if not a.problema:
        ap.error("falta o arquivo do problema")
    pr = aeroopt.load(a.problema)
    if a.isolar:
        pr.isolate(*[s.strip() for s in a.isolar.split(",") if s.strip()])
    if a.categorias:
        pr.params["categorias"] = [s.strip() for s in a.categorias.split(",") if s.strip()]
    project = DesignProject.load(a.projeto) if a.projeto else DesignProject()
    if a.etapas or pr.evaluator == "etapas":
        return staged(pr, project, a)
    ev = MiniMdoEvaluator(project)
    sc = scoring_for(pr.scoring)
    missing = [q for q in sc.quantities() if q not in ev.quantities()]
    print(f"problema: {pr.name or a.problema}")
    print(f"livres: {', '.join(v.key for v in pr.free_variables()) or '(nenhuma)'}")
    print(f"nota: {sc.name}" + (f"  [{sc.source}]" if sc.source else ""))
    if missing:
        print(f"  aviso: o avaliador {ev.name} ainda não calcula {', '.join(missing)}; a busca usa o MTOW")
        pr.scoring = "MTOW"

    def progress(it, rows):
        ok = [r for r in rows if r["feasible"]]
        best = max((r["score"] for r in ok), default=float("nan"))
        print(f"  iteração {it + 1}: {len(rows)} avaliações, melhor viável {best:.4g}", flush=True)
    res = MiniMdoSolver().run(pr, ev, progress)
    b = max(res.rows, key=lambda r: (r["feasible"], r["fitness"]))
    print("\nmelhor ponto" + ("" if b["feasible"] else " (NÃO cumpre as restrições)"))
    for k in ("span", "area", "taper", "airfoil", "airfoil_tip", "motor", "propeller", "motors", "tilt", "layout"):
        print(f"  {k:12s} {_fmt(b[k])}")
    q = dict(zip(res.names["quantities"], res.best["q"]))
    print("grandezas")
    for k in ("mtow", "pv", "cp", "ee", "s_to", "V_S", "b", "S"):
        print(f"  {k:12s} {_fmt(float(q[k]))}")
    print("restrições")
    from aerosim.design import registry as rg
    for c in pr.constraints:
        if c.active and c.key in q:
            ok, txt = rg.Constraint(c.key, c.op, c.value).check(float(q[c.key]))
            print(f"  {'ok ' if ok else 'NÃO'} {rg.QUANTITIES.get(c.key, rg.Quantity(c.key)).label}: {txt}")
    if a.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        from aerosim.design import mdo
        h = mdo.history(res.rows)
        fig, ax = plt.subplots(figsize=(7, 4))
        ax.scatter([r["iter"] + 1 for r in res.rows], [r["score"] for r in res.rows], s=10, alpha=.35,
                   c=["#2c7fb8" if r["feasible"] else "#d95f0e" for r in res.rows], label="avaliações (laranja: inviável)")
        ax.plot([r["iter"] + 1 for r in h], [r["score"] for r in h], color="k", lw=2, label="melhor até a iteração")
        ax.set(xlabel="iteração", ylabel=pr.scoring, title=pr.name or os.path.basename(a.problema))
        ax.grid(alpha=.3)
        ax.legend(fontsize=9)
        fig.tight_layout()
        fig.savefig(a.png, dpi=120)
        print(f"gravado: {a.png}")
    return 0


def staged(pr, project, a) -> int:
    """o processo em etapas: imprime o andamento, cada configuração e a melhor"""
    from aeroopt.generations import GenerationsSolver
    from aeroopt.stages import StagedEvaluator
    sc = scoring_for(pr.scoring)
    print(f"problema: {pr.name or a.problema}")
    print(f"livres: {', '.join(v.key for v in pr.free_variables()) or '(nenhuma)'}")
    print(f"nota: {sc.name}" + (f"  [{sc.source}]" if sc.source else ""))
    ev = StagedEvaluator(project, workers=a.processos, six_dof=not a.sem_6gdl, evals=a.avaliacoes)
    res = GenerationsSolver(a.populacao, a.geracoes).run(pr, ev, progress=lambda f, t: print(f"  {f:4.0%} {t}", flush=True))
    from aeroopt import export
    folder = export.write(res.rows, a.csv or export.run_folder())
    print(f"\nCSV: {folder}/avaliacoes.csv ({sum(len(r['history']) for r in res.rows)} pontos de projeto) e "
          f"configuracoes.csv ({len(res.rows)} configurações)")
    print(f"\n{res.names['combinações']} combinações; gerações (configurações novas, melhor nota até ali)")
    for g, n_new, best in res.names["gerações"]:
        print(f"  {g:3d}: {n_new:3d} novas, melhor {_fmt(best)}")
    print("\netapas (entraram → seguiram)")
    for name, n_in, n_out in res.names["etapas"]:
        print(f"  {name:16s} {n_in} → {n_out}")
    print("configurações")
    for r in sorted(res.rows, key=lambda r: (r["alive"], r["valido"], r["nota"]), reverse=True):
        st = f"nota {_fmt(r['nota'])}" + ("" if r["valido"] else " (inválida)") if r["alive"] else f"parou: {r['why']}"
        print(f"  {r['name']}: MTOW {_fmt(r['mtow'])}, 6GDL {_fmt(r['mtow6'])}, {st}")
    if not res.best:
        print("nenhuma configuração chegou ao fim")
        return 1
    b = res.best
    print("\nmelhor: " + b["name"])
    for k, v in b["values"].items():
        print(f"  {k:16s} {_fmt(v)}")
    for k, v in b["inputs"].items():
        print(f"  {k:16s} {_fmt(v)}")
    for txt, ok, _ in b["validade"]:
        print(f"  {'ok ' if ok else 'NÃO'} {txt}")
    if a.sensibilidade:
        from aeroopt.sensitivity import METHODS, SensParams, sensitivity
        from aerosim.parallel import make_executor
        sp = SensParams(method=a.sensibilidade, tol=a.tolerancia / 100, limits=a.limites)
        with make_executor("processos", a.processos) as ex:
            s = sensitivity(project, pr, b, ev, sp, executor=ex)
        print(f"\nsensibilidade, {METHODS[sp.method]} (nota na pista {_fmt(s['base']['nota'])}; {s['used']} pontos "
              f"que fecham, {s['new']} novos; ±{100 * s['h']:g} % da faixa; com {a.tolerancia:g} % de tolerância a "
              f"nota varia ± {_fmt(s['sigma'])})")
        for r in s["rows"]:
            stop = "".join(f"; em {_fmt(x)} não fecha: {why}" for _, x, why in r["blocked"])
            extra = (f", μ* ≈ {_fmt(r['mustar'])}, σ ≈ {_fmt(r['sigma'])}" if "mustar" in r
                     else f", ∂²nota/∂x² ≈ {_fmt(r['curv'])}")
            print(f"  {r['label']} = {_fmt(r['x0'])}: ∂nota/∂x ≈ {_fmt(r['slope'])}{extra}; elasticidade "
                  f"{_fmt(r['elast'])}\n      {_fmt(r['x_minus'])} → {_fmt(r['minus'])}, {_fmt(r['x_plus'])} → "
                  f"{_fmt(r['plus'])}{stop}")
        for lm in s["limits"]:
            pts = ", ".join(f"{_fmt(lv)} → " + (_fmt(n) if n == n else f"não fecha ({why})")
                            for lv, n, why in lm["points"])
            print(f"  limite {lm['label']} {lm['op']} {_fmt(lm['value'])}: ∂nota/∂L ≈ {_fmt(lm['dNdL'])}; {pts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

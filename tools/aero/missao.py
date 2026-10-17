"""Voar a missão inteira (ou só a decolagem) com cada modelo aerodinâmico e comparar os voos (T65, fase B).

A mesma análise da GUI (`manager.run("mission")` ou `"takeoff"`) roda uma vez por modelo; só muda `ac.sim.aero_model`
(core/src/physics/aeromodel.zig). O padrão do programa e do AeroDrive continua "faixas".

    faixas          o de sempre (malha da simulação)
    faixas_fino     as faixas com as superfícies refinadas (separa o efeito da malha)
    llt, llt_gh     linha sustentadora do núcleo (Phillips e Snyder; Goates e Hunsaker), superfícies refinadas
    tabela:<método> tabela de voo de qualquer método (aerosim/aero/flight_table.py): zig, lltdrek, asb_vlm,
                    asb_buildup, avl. As derivadas que o método não dá vêm do núcleo (a ferramenta diz quais).
                    A tabela não tem efeito solo nem esteira; a fuselagem entra pelo núcleo

    python tools/aero/missao.py                                         # missão do conventional, modelos padrão
    python tools/aero/missao.py --analise decolagem --modelos faixas,llt_gh,tabela:avl --pasta perfis/missao
    python tools/aero/missao.py --puro --modelos faixas,tabela:zig,tabela:avl,tabela:asb_vlm,tabela:lltdrek
    python tools/aero/missao.py --carregar perfis/missao --ref faixas --ref llt_gh   # a tabela de erros, sem voar

Tabela de erros (`--ref`, padrão faixas): para cada voo, o desvio do percurso (a distância de cada ponto x, y, h à
trajetória da referência: média, RMS e máximo, em m; independe do tempo) e o RMS de h, V, θ, α, δe e acelerador numa
grade de tempo comum, mais a diferença de energia e de distâncias do resumo. O mapa de proximidade (`matriz.png`):
o desvio médio do percurso entre cada par de voos.
"""
from __future__ import annotations

import argparse
import copy
import csv
import math
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

PADRAO = ("faixas", "faixas_fino", "llt_gh", "tabela:zig", "tabela:avl", "tabela:asb_vlm", "tabela:lltdrek")
ANALISES = {"missao": "mission", "decolagem": "takeoff"}
COLUNAS = ("t", "n", "e", "h", "Va", "Vg", "alpha", "beta", "theta", "phi", "gamma", "de", "da", "dr", "thr", "CL",
           "N_main", "N_steer", "N_skid", "T", "Ibat")


def preparar(backend, ac, modelo: str, V: float):
    """cópia do avião voando com `modelo`; devolve (avião, observação)"""
    from tools.aero.coeficientes import refinar
    a = copy.deepcopy(ac)
    nota = ""
    if modelo == "faixas":
        return a, nota
    if modelo == "faixas_fino":
        return refinar(backend, a), "superfícies refinadas"
    if modelo in ("llt", "llt_gh"):
        a = refinar(backend, a, tip=True)
        a.sim.aero_model = modelo
        return a, "superfícies refinadas (faixas mais estreitas na ponta)"
    if modelo.startswith("tabela:"):
        from aerosim.aero import solver_by_name
        from aerosim.aero.flight_table import table
        from aerosim.model.universal import build_model
        nome = modelo.split(":", 1)[1]
        so = solver_by_name(backend, nome)
        if so.available():
            raise RuntimeError(f"{nome} não roda: {so.available()}")
        m = build_model(a)
        t = table(so, m, V=V, rho=a.environment.rho, ref=list(m.mass["cg"]), fill=solver_by_name(backend, "zig"))
        a.sim.aero_model, a.sim.aero_table = "tabela", t
        partes = []
        if t["completadas"]:
            partes.append("do núcleo: " + ", ".join(t["completadas"]))
        if t["zeradas"]:
            partes.append("zeradas: " + ", ".join(t["zeradas"]))
        return a, f"tabela a {V:g} m/s" + (f" ({'; '.join(partes)})" if partes else "")
    raise ValueError(f"modelo desconhecido: {modelo!r}")


def voar(backend, ac, modelos, analise: str = "missao", V: float | None = None) -> dict:
    """{modelo: {"res", "log", "nota", "tempo"}} ou {modelo: {"erro"}}"""
    from aerosim.manager.manager import SimulationManager
    mgr = SimulationManager(backend)
    V = V or float(ac.mission.V0)
    out = {}
    for mo in modelos:
        t0 = time.perf_counter()
        try:
            a, nota = preparar(backend, ac, mo, V)
            res = mgr.run(ANALISES[analise], a)
        except Exception as e:                       # noqa: BLE001 — um modelo que falha não para os outros
            out[mo] = dict(erro=f"{type(e).__name__}: {e}")
            print(f"  {mo}: falhou ({out[mo]['erro'][:120]})")
            continue
        log = {k: np.asarray(res.log[k], float) for k in COLUNAS}
        out[mo] = dict(res=res, log=log, nota=nota, tempo=time.perf_counter() - t0)
        print(f"  {mo}: {res.status}, t até {log['t'][-1]:.1f} s ({out[mo]['tempo']:.0f} s de conta){' — ' + nota if nota else ''}")
    return out


def _num(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def tabela(voos: dict, base: str = "faixas") -> str:
    """o resumo de cada modelo lado a lado (os números do resumo da GUI) e, para os numéricos, a diferença ao `base`"""
    ok = {m: v for m, v in voos.items() if "res" in v}
    if not ok:
        return "nenhum modelo rodou"
    chaves = []
    for v in ok.values():
        for k, x in v["res"].summary.items():
            if k not in chaves and _num(x) is not None:
                chaves.append(k)
    nomes = list(ok)
    w = max(12, max(len(n) for n in nomes) + 1)
    lines = ["== resumo de cada voo (Δ ao " + base + " entre parênteses)",
             f"{'':24s}" + "".join(f"{n:>{w + 10}s}" for n in nomes)]
    lines.append(f"{'status':24s}" + "".join(f"{ok[n]['res'].status:>{w + 10}s}" for n in nomes))
    b = ok.get(base)
    for k in chaves:
        cells = []
        for n in nomes:
            x = _num(ok[n]["res"].summary.get(k))
            if x is None:
                cells.append(f"{'—':>{w + 10}s}")
                continue
            y = _num(b["res"].summary.get(k)) if b else None
            d = f" ({x - y:+.3g})" if (y is not None and n != base) else ""
            cells.append(f"{x:.4g}{d}".rjust(w + 10))
        lines.append(f"{k[:24]:24s}" + "".join(cells))
    return "\n".join(lines)


def grafico(voos: dict, png: str, titulo: str, analise: str):
    """as curvas principais de cada voo sobrepostas"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    g = math.degrees(1.0)
    if analise == "decolagem":
        quadros = [("Perfil (h × distância)", "n", "h", 1, "distância (m)", "h (m)"),
                   ("Velocidade do ar", "t", "Va", 1, "t (s)", "m/s"), ("θ", "t", "theta", g, "t (s)", "°"),
                   ("α", "t", "alpha", g, "t (s)", "°"), ("δe", "t", "de", g, "t (s)", "°"),
                   ("Reação no trem principal", "t", "N_main", 1, "t (s)", "N"),
                   ("Tração", "t", "T", 1, "t (s)", "N"), ("C_L", "t", "CL", 1, "t (s)", "—")]
    else:
        quadros = [("Plano XZ", "n", "h", 1, "x (m)", "h (m)"), ("Plano XY", "e", "n", 1, "y (m) — leste", "x (m)"),
                   ("Altura", "t", "h", 1, "t (s)", "m"), ("Velocidade do ar", "t", "Va", 1, "t (s)", "m/s"),
                   ("θ", "t", "theta", g, "t (s)", "°"), ("α", "t", "alpha", g, "t (s)", "°"),
                   ("φ", "t", "phi", g, "t (s)", "°"), ("δe", "t", "de", g, "t (s)", "°"),
                   ("Acelerador", "t", "thr", 1, "t (s)", "—"), ("C_L", "t", "CL", 1, "t (s)", "—")]
    nc = 5 if len(quadros) > 8 else 4
    nl = (len(quadros) + nc - 1) // nc
    fig, axs = plt.subplots(nl, nc, figsize=(4.6 * nc, 3.4 * nl + 0.6), squeeze=False)
    cores = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    for ax, (tit, x, y, k, xl, yl) in zip(axs.flat, quadros):
        for j, (m, v) in enumerate(voos.items()):
            if "log" not in v:
                continue
            kw = dict(color="k", lw=1.8) if m == "faixas" else dict(color=cores[j % len(cores)], lw=1.1)
            ax.plot(v["log"][x], v["log"][y] * k, label=m, **kw)
        ax.set_title(tit, fontsize=10)
        ax.set_xlabel(xl)
        ax.set_ylabel(yl)
        ax.grid(alpha=0.3)
    for ax in list(axs.flat)[len(quadros):]:
        ax.set_visible(False)
    axs.flat[0].legend(fontsize=7)
    fig.suptitle(titulo)
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    fig.savefig(png, dpi=110)
    plt.close(fig)


def gravar_csv(path: str, voos: dict):
    """o resumo de cada voo: modelo, chave, valor"""
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["modelo", "chave", "valor"])
        for m, v in voos.items():
            if "res" not in v:
                w.writerow([m, "erro", v["erro"]])
                continue
            w.writerow([m, "status", v["res"].status])
            for k, x in v["res"].summary.items():
                w.writerow([m, k, x])


# ---------------------------------------------------------------------- erro ao longo do percurso
ESTADOS = (("h", 1.0, "m"), ("Va", 1.0, "m/s"), ("theta", math.degrees(1.0), "°"), ("alpha", math.degrees(1.0), "°"),
           ("de", math.degrees(1.0), "°"), ("thr", 1.0, "—"))


def desvio_percurso(a: dict, b: dict) -> np.ndarray:
    """o desvio entre duas trajetórias (x = n, y = e, h): para cada ponto de uma, a distância (m) até o ponto mais
    próximo da outra, nos dois sentidos (simétrico: trocar a referência não muda o número). Independe do tempo: um voo
    que só atrasa não desvia do caminho"""
    from scipy.spatial import cKDTree
    pa = np.column_stack([a["n"], a["e"], a["h"]])
    pb = np.column_stack([b["n"], b["e"], b["h"]])
    return np.concatenate([cKDTree(pb).query(pa)[0], cKDTree(pa).query(pb)[0]])


def erros(voos: dict, ref: str, dt: float = 0.1) -> dict[str, dict[str, float]]:
    """{modelo: métricas} contra o voo `ref`: desvio do percurso (média, RMS, máximo, m) e o RMS de cada estado de
    ESTADOS numa grade de tempo comum (de 0 até o fim do voo mais curto dos dois, passo `dt`)"""
    R = voos[ref]["log"]
    out = {}
    for m, v in voos.items():
        if m == ref or "log" not in v:
            continue
        L = v["log"]
        d = desvio_percurso(L, R)
        e = dict(perc_med=float(d.mean()), perc_rms=float(np.sqrt(np.mean(d * d))), perc_max=float(d.max()))
        t = np.arange(0.0, min(L["t"][-1], R["t"][-1]), dt)
        for k, f, _ in ESTADOS:
            x = (np.interp(t, L["t"], L[k]) - np.interp(t, R["t"], R[k])) * f
            e[k] = float(np.sqrt(np.mean(x * x)))
        sa, sr = v["res"].summary, voos[ref]["res"].summary
        for k in ("energia_Wh", "t_fim", "n_saiu_do_chao", "n_LO", "n_ht"):
            if _num(sa.get(k)) is not None and _num(sr.get(k)) is not None:
                e[k] = _num(sa[k]) - _num(sr[k])
        out[m] = e
    return out


def tabela_erros(err: dict, ref: str) -> str:
    """a tabela de erros em Markdown (vai para o terminal e para erros_<ref>.md)"""
    cols = [("perc_med", "percurso médio (m)"), ("perc_rms", "percurso RMS (m)"), ("perc_max", "percurso máx. (m)")]
    cols += [(k, f"{k} RMS ({u})") for k, _, u in ESTADOS]
    extras = [k for k in ("energia_Wh", "t_fim", "n_saiu_do_chao", "n_LO", "n_ht") if any(k in e for e in err.values())]
    nomes = {"energia_Wh": "Δ energia (Wh)", "t_fim": "Δ t_fim (s)", "n_saiu_do_chao": "Δ saiu do chão (m)",
             "n_LO": "Δ n_LO (m)", "n_ht": "Δ n_ht (m)"}
    cols += [(k, nomes[k]) for k in extras]
    lines = [f"Erro de cada voo contra **{ref}** (percurso: distância de cada ponto à trajetória de {ref}; estados: RMS "
             f"numa grade de tempo comum)", "",
             "| modelo | " + " | ".join(c for _, c in cols) + " |", "|---|" + "---|" * len(cols)]
    for m, e in err.items():
        lines.append(f"| {m} | " + " | ".join(f"{e[k]:.3g}" if k in e else "—" for k, _ in cols) + " |")
    return "\n".join(lines)


def matriz(voos: dict) -> tuple[list[str], np.ndarray]:
    """o mapa de proximidade dos voos: M[i, j] = desvio médio do percurso (m) entre o voo i e o j (simétrico)"""
    nomes = [m for m, v in voos.items() if "log" in v]
    M = np.zeros((len(nomes), len(nomes)))
    for i, a in enumerate(nomes):
        for j in range(i + 1, len(nomes)):
            M[i, j] = M[j, i] = float(desvio_percurso(voos[a]["log"], voos[nomes[j]]["log"]).mean())
    return nomes, M


def grafico_matriz(nomes: list[str], M: np.ndarray, png: str, titulo: str):
    """o mapa de calor do desvio médio do percurso entre cada par de voos"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(1.0 * len(nomes) + 3, 0.8 * len(nomes) + 2))
    vmax = max(float(np.percentile(M[M > 0], 90)) if (M > 0).any() else 1.0, 1e-6)
    im = ax.imshow(M, cmap="viridis_r", vmin=0, vmax=vmax)
    for i in range(len(nomes)):
        for j in range(len(nomes)):
            if i != j:
                ax.text(j, i, f"{M[i, j]:.2g}", ha="center", va="center", fontsize=8,
                        color="white" if M[i, j] > 0.5 * vmax else "black")
    ax.set_xticks(range(len(nomes)), nomes, rotation=35, ha="right")
    ax.set_yticks(range(len(nomes)), nomes)
    fig.colorbar(im, ax=ax, label="desvio médio do percurso (m)")
    ax.set_title(titulo, fontsize=10)
    fig.tight_layout()
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    fig.savefig(png, dpi=110)
    plt.close(fig)


def grafico_tempo(voos: dict, png: str, titulo: str):
    """o tempo de conta de cada modelo (barras, escala log). O das tabelas inclui montar a tabela antes do voo"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    nomes = [m for m, v in voos.items() if "tempo" in v]
    t = [voos[m]["tempo"] for m in nomes]
    fig, ax = plt.subplots(figsize=(8, 0.45 * len(nomes) + 1.5))
    bars = ax.barh(nomes, t, color=["k" if m == "faixas" else "C0" for m in nomes])
    ax.set_xscale("log")
    for b, x in zip(bars, t):
        ax.text(x * 1.08, b.get_y() + b.get_height() / 2, f"{x:.0f} s" if x >= 1 else f"{x:.1f} s", va="center",
                fontsize=8)
    ax.invert_yaxis()
    ax.set_xlabel("tempo de conta (s, escala log; as tabelas incluem montá-las)")
    ax.set_title(titulo, fontsize=10)
    ax.grid(axis="x", alpha=0.3, which="both")
    fig.tight_layout()
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    fig.savefig(png, dpi=110)
    plt.close(fig)


def tabela_matriz(nomes: list[str], M: np.ndarray) -> str:
    w = max(12, max(len(n) for n in nomes) + 1)
    lines = ["== proximidade dos voos: desvio médio do percurso entre cada par (m)",
             f"{'':{w}s}" + "".join(f"{n[:w - 1]:>{w}s}" for n in nomes)]
    for i, n in enumerate(nomes):
        lines.append(f"{n:{w}s}" + "".join(f"{x:{w}.3g}" for x in M[i]))
    return "\n".join(lines)


def gravar_voos(pasta: str, voos: dict, meta: dict):
    """os registros (voos.npz) e os resumos (voos.json) de cada voo, para refazer a tabela sem voar de novo"""
    import json
    arr, resumo = {}, {}
    for m, v in voos.items():
        if "log" in v:
            for k, x in v["log"].items():
                arr[f"{m}|{k}"] = x
            resumo[m] = dict(status=v["res"].status, nota=v["nota"], tempo=v["tempo"],
                             summary={k: (_num(x) if _num(x) is not None else str(x)) for k, x in v["res"].summary.items()})
        else:
            resumo[m] = dict(erro=v["erro"])
    np.savez_compressed(os.path.join(pasta, "voos.npz"), **arr)
    with open(os.path.join(pasta, "voos.json"), "w", encoding="utf-8") as f:
        json.dump(dict(meta=meta, voos=resumo), f, ensure_ascii=False, indent=1)


def ler_voos(pasta: str) -> tuple[dict, dict]:
    """o que `gravar_voos` gravou: (voos, meta)"""
    import json
    from types import SimpleNamespace
    with open(os.path.join(pasta, "voos.json"), encoding="utf-8") as f:
        d = json.load(f)
    z = np.load(os.path.join(pasta, "voos.npz"))
    voos = {}
    for m, r in d["voos"].items():
        if "erro" in r:
            voos[m] = dict(erro=r["erro"])
            continue
        log = {k.split("|", 1)[1]: z[k] for k in z.files if k.split("|", 1)[0] == m}
        voos[m] = dict(res=SimpleNamespace(status=r["status"], summary=r["summary"]), log=log, nota=r["nota"],
                       tempo=r["tempo"])
    return voos, d["meta"]


def main(argv=None) -> int:
    from tools.aero.decolagem import carregar, puro
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aviao", help="arquivo do avião ou modelo de aerosim.model.templates (padrão: conventional)")
    ap.add_argument("--modelos", help=f"separados por vírgula (padrão: {','.join(PADRAO)})")
    ap.add_argument("--analise", default="missao", choices=tuple(ANALISES), help="missão inteira ou só a decolagem")
    ap.add_argument("--V", type=float, help="velocidade das tabelas (padrão: a V0 da missão)")
    ap.add_argument("--puro", action="store_true", help="sem as sobrescritas das superfícies e sem os coeficientes da "
                    "fuselagem (o mesmo avião para todos os métodos)")
    ap.add_argument("--ref", action="append", help="referência da tabela de erros (um modelo; pode repetir; "
                    "padrão: faixas)")
    ap.add_argument("--pasta", help="grava voos.png, matriz.png, tempo.png, resumo.csv, erros_<ref>.md e os voos "
                    "(voos.npz, voos.json)")
    ap.add_argument("--carregar", help="pasta de um `--pasta` anterior: refaz a tabela e os gráficos sem voar de novo")
    args = ap.parse_args(argv)
    if args.carregar:
        voos, meta = ler_voos(args.carregar)
        nome, analise = meta["aviao"], meta["analise"]
    else:
        from aerosim.backend.zig import ZigBackend
        backend = ZigBackend()
        ac = carregar(args.aviao)
        if args.puro:
            ac = puro(ac)
        modelos = [m.strip() for m in (args.modelos or ",".join(PADRAO)).split(",") if m.strip()]
        nome, analise = ac.name, args.analise
        print(f"{nome}: {analise} com {len(modelos)} modelos")
        voos = voar(backend, ac, modelos, analise, args.V)
    print(tabela(voos))
    pasta = args.pasta or args.carregar
    for ref in args.ref or ["faixas"]:
        if ref not in voos or "log" not in voos[ref]:
            print(f"referência {ref!r} não voou: sem tabela de erros")
            continue
        txt = tabela_erros(erros(voos, ref), ref)
        print("\n" + txt)
        if pasta:
            os.makedirs(pasta, exist_ok=True)
            with open(os.path.join(pasta, f"erros_{ref}.md"), "w", encoding="utf-8") as f:
                f.write(f"# {nome}: {analise}\n\n{txt}\n")
    nm, M = matriz(voos)
    print("\n" + tabela_matriz(nm, M))
    if pasta:
        os.makedirs(pasta, exist_ok=True)
        grafico_matriz(nm, M, os.path.join(pasta, "matriz.png"), f"{nome}: {analise} — proximidade dos voos")
        grafico_tempo(voos, os.path.join(pasta, "tempo.png"), f"{nome}: {analise} — tempo de conta por modelo")
        grafico(voos, os.path.join(pasta, "voos.png"), f"{nome}: {analise} com cada modelo aerodinâmico", analise)
        gravar_csv(os.path.join(pasta, "resumo.csv"), voos)
        if not args.carregar:
            gravar_voos(pasta, voos, dict(aviao=nome, analise=analise, puro=bool(args.puro)))
        print(f"gráficos, tabelas e voos em {pasta}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

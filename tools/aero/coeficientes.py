"""Coeficientes de cada perfil de teste (tools/aero/casos.py) a uma velocidade (padrão 12 m/s), por método, e a
distância de cada método até uma referência (qualquer método ou um CSV de fora). Comandos e exemplos: README.md.

    nucleo          núcleo, faixas da simulação (core/src/physics/aero.zig), longe do chão, com a malha da simulação
                    (uma faixa por trecho entre seções: a asa trapezoidal é UM painel por lado)
    nucleo_fino     o mesmo com as superfícies divididas no máximo de faixas que o núcleo aceita (48 painéis)
    nucleo_solo25   o núcleo com o efeito solo de McCormick (modifier padrão) a h/b = 0,25
    nucleo_solo10   idem a h/b = 0,10 (o McCormick só mexe no arrasto induzido: C_L e C_m iguais)
    nucleo_llt      núcleo, linha sustentadora de Phillips e Snyder (core/src/loads/llt.zig, `coeffs`), superfícies
                    refinadas: a conta da simulação com as forças dos painéis da linha sustentadora (taxas, c_m das
                    seções, fuselagem e modificadores como na simulação)
    nucleo_gh       o mesmo com as correções de Goates e Hunsaker 2021 (junta e linha efetiva): converge com a malha
                    em derrapagem e com enflechamento
    lltdrek, asb_vlm, asb_buildup, avl   os outros métodos do programa (aerosim.aero.all_solvers)
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

from aerosim.aero.zig_solver import ZigPanelSolver  # noqa: E402
from aerosim.aero.llt_solver import CoreLLTSolver  # noqa: E402
from aerosim.interfaces.aero import AeroCase  # noqa: E402

V_PADRAO = 12.0
ALPHAS = np.arange(-4.0, 12.01, 1.0)

# coeficiente -> (rótulo, modo). "rel": diferença relativa (%); "pn": o C_mα vira o deslocamento do ponto neutro,
# −ΔC_mα / C_Lα da referência, em % da CMA (no 1/4 da CMA o C_mα é quase zero: o relativo não diz nada)
METRICAS = {
    "CL0": ("C_L0", "rel"), "CLa": ("C_Lα", "rel"), "Cma": ("ponto neutro (% CMA)", "pn"), "Cm0": ("C_m0", "rel"),
    "CD0": ("C_D0", "rel"), "k": ("k", "rel"),
    "CYb": ("C_Yβ", "rel"), "Clb": ("C_lβ", "rel"), "Cnb": ("C_nβ", "rel"),
    "Clp": ("C_lp", "rel"), "Cnp": ("C_np", "rel"), "CLq": ("C_Lq", "rel"), "Cmq": ("C_mq", "rel"),
    "Clr": ("C_lr", "rel"), "Cnr": ("C_nr", "rel"),
    "CLde": ("C_Lδe", "rel"), "Cmde": ("C_mδe", "rel"), "Clda": ("C_lδa", "rel"), "Cnda": ("C_nδa", "rel"),
    "CYdr": ("C_Yδr", "rel"), "Cldr": ("C_lδr", "rel"), "Cndr": ("C_nδr", "rel"),
}
PADRAO = ("CL0", "CLa", "Cma", "k", "CYb", "Clb", "Cnb", "Clp", "Cmq", "Cnr", "CLde", "Cmde", "Clda", "Cndr")
MIN_REF = 0.02             # |referência| menor que isso (ex.: C_Yβ e C_nr da asa plana, quase 0): fica de fora


# ---------------------------------------------------------------------- variantes do núcleo (mesma interface)
def refinar(backend, ac, tip: bool = False, per_side: int | None = None):
    """todas as superfícies em `per_side` faixas por lado: `span_loads.refine_all` (o refino da aba Cargas)"""
    from aerosim.aero.span_loads import refine_all
    return refine_all(backend, ac, tip, per_side)


class NucleoFino(ZigPanelSolver):
    """o núcleo (faixas) com as superfícies refinadas: separa o efeito da malha da simulação (uma faixa por trecho entre seções)
    do efeito do método"""
    name, title = "nucleo_fino", "núcleo, faixas refinadas"

    def __init__(self, backend, per_side: int | None = None):
        super().__init__(backend)
        self.per_side = per_side

    def evaluate(self, model, case, points):
        from aerosim.model.universal import build_model
        return super().evaluate(build_model(refinar(self.backend, model.aircraft, per_side=self.per_side)), case,
                                points)


class NucleoSolo(ZigPanelSolver):
    """o núcleo com o avião a h = h/b · b do chão (efeito solo do modifier ligado; o padrão é o de McCormick)"""

    def __init__(self, backend, h_b: float):
        super().__init__(backend)
        self.h_b = h_b
        self.name, self.title = f"nucleo_solo{round(100 * h_b)}", f"núcleo, solo h/b={h_b:g}"

    def evaluate(self, model, case, points):
        V, ref, b, c = case.V, list(case.ref), model.b, model.c
        out = []
        with self.backend.session_for(model, overrides={"env": {"rho": case.rho}}) as s:
            for pt in points:
                raw = s.aero_coeffs_at(V, pt.alpha, pt.beta, pt.p * 2 * V / b, pt.q * 2 * V / c, pt.r * 2 * V / b,
                                       pt.de, pt.da, pt.dr, h=self.h_b * b, ref=ref)
                out.append(self.backend.translator.from_native(raw, model))
        return out


class NucleoLLT(CoreLLTSolver):
    """a linha sustentadora do núcleo (`aerosim/aero/llt_solver.py`, a mesma da aba Aerodinâmica) com o máximo de
    faixas que cabe (ou `per_side`), para não depender do `n_span` do caso"""
    gh = False

    def __init__(self, backend, per_side: int | None = None):
        from aerosim.aero.span_loads import MAX_PER_SIDE
        super().__init__(backend, gh=self.gh, per_side=per_side or MAX_PER_SIDE)
        self.name = "nucleo_gh" if self.gh else "nucleo_llt"
        self.title = f"núcleo, linha sustentadora ({'Goates e Hunsaker' if self.gh else 'Phillips e Snyder'})"


class NucleoGH(NucleoLLT):
    """o mesmo com as correções de Goates e Hunsaker (`span_loads.GOATES_HUNSAKER`)"""
    gh = True


def metodos(backend, paineis: int | None = None) -> list:
    """paineis: faixas por lado da asa no `nucleo_fino` e no `nucleo_llt` (None: o máximo que cabe); os outros
    recebem o mesmo número como `AeroCase.n_span` (em `rodar`). O `nucleo` fica sempre com a malha da simulação"""
    from aerosim.aero import all_solvers
    outros = [s for s in all_solvers(backend) if s.name not in ("zig", "asb_ll", "zig_llt", "zig_llt_gh")]   # asb_ll: sem taxas; zig_llt*: os nucleo_*
    return [ZigPanelSolver(backend), NucleoFino(backend, paineis), NucleoSolo(backend, 0.25),
            NucleoSolo(backend, 0.10), NucleoLLT(backend, paineis), NucleoGH(backend, paineis), *outros]


def _nome(s) -> str:
    return "nucleo" if s.name == "zig" else s.name


# ---------------------------------------------------------------------- cálculo
def resumo(pol) -> dict:
    """C_L0, C_Lα (/rad), C_m0, C_mα (/rad) por reta em −2..6°; C_D0, k por C_D = C_D0 + k C_L²"""
    a, CL, CD, Cm = pol.alpha, pol.CL, pol.CD, pol.Cm
    sel = (a >= -2.0) & (a <= 6.0) & np.isfinite(CL)
    out = dict(CL0=np.nan, CLa=np.nan, Cm0=np.nan, Cma=np.nan, CD0=np.nan, k=np.nan)
    if sel.sum() >= 2:
        out["CLa"], out["CL0"] = np.polyfit(np.radians(a[sel]), CL[sel], 1)
        if np.isfinite(Cm[sel]).all():
            out["Cma"], out["Cm0"] = np.polyfit(np.radians(a[sel]), Cm[sel], 1)
    ok = sel & np.isfinite(CD)
    if ok.sum() >= 3 and np.ptp(CL[ok]) > 1e-6:
        out["k"], out["CD0"] = np.polyfit(CL[ok] ** 2, CD[ok], 1)
    return {k: float(v) for k, v in out.items()}


def rodar(backend, ac, V: float = V_PADRAO, nomes=None, paineis: int | None = None) -> list[dict]:
    """cada método no caso: {"metodo", "titulo", "polar", "resumo"} ou {"metodo", "erro"}. paineis: painéis por
    semiasa (None: o padrão de cada método; veja `metodos`)"""
    from aerosim.model.universal import build_model
    model = build_model(ac)
    case = AeroCase(V=V, rho=ac.environment.rho, alphas=ALPHAS, alpha_d=2.0, ref=(0.0, 0.0, 0.0))
    if paineis:
        case.n_span = int(paineis)
    out = []
    for so in metodos(backend, paineis):
        n = _nome(so)
        if nomes and n not in nomes:
            continue
        why = so.available()
        if why:
            out.append(dict(metodo=n, titulo=so.title, erro=why))
            continue
        try:
            pol = so.solve(model, case)
        except Exception as e:                                   # noqa: BLE001 — um método que falha não para os outros
            out.append(dict(metodo=n, titulo=so.title, erro=f"{type(e).__name__}: {e}"))
            continue
        out.append(dict(metodo=n, titulo=so.title, polar=pol, resumo=resumo(pol)))
    return out


def valores(r: dict) -> dict:
    return {**r["resumo"], **r["polar"].derivs} if "resumo" in r else {}


def ler_referencia(path: str) -> dict[str, np.ndarray]:
    """CSV com cabeçalho (separador vírgula ou ponto e vírgula): alpha, CL, CD, Cm"""
    with open(path, encoding="utf-8") as f:
        txt = f.read()
    sep = ";" if txt.count(";") > txt.count(",") else ","
    head, *body = [ln for ln in txt.splitlines() if ln.strip() and not ln.startswith("#")]
    keys = [k.strip() for k in head.split(sep)]
    data = np.array([[float(x) for x in ln.split(sep)] for ln in body])
    return {k: data[:, i] for i, k in enumerate(keys) if k in ("alpha", "CL", "CD", "Cm")}


def referencia_csv(path: str) -> dict:
    """a curva de fora como uma linha de `rodar` (o resumo sai das colunas que houver)"""
    from types import SimpleNamespace
    d = ler_referencia(path)
    nan = np.full(len(d["alpha"]), np.nan)
    pol = SimpleNamespace(alpha=d["alpha"], CL=d.get("CL", nan), CD=d.get("CD", nan), Cm=d.get("Cm", nan), derivs={})
    return dict(metodo="csv", titulo=path, polar=pol, resumo=resumo(pol))


def distancia(rows: list[dict], ref: dict, coefs=PADRAO, min_ref: float = MIN_REF) -> dict[str, dict[str, float]]:
    """{método: {coeficiente: distância}} contra `ref` (veja METRICAS); fica de fora o que um dos dois não tem e os
    métodos com efeito solo (outro escoamento: perto do chão)"""
    R = valores(ref)
    out = {}
    for r in rows:
        v, d = valores(r), {}
        if not v or r["metodo"] == ref["metodo"] or "solo" in r["metodo"]:
            continue
        for k in coefs:
            a, b = v.get(k, np.nan), R.get(k, np.nan)
            if not (math.isfinite(a) and math.isfinite(b)):
                continue
            if METRICAS[k][1] == "pn":
                if math.isfinite(R.get("CLa", np.nan)) and abs(R["CLa"]) > min_ref:
                    d[k] = -100.0 * (a - b) / R["CLa"]
            elif abs(b) >= min_ref:
                d[k] = 100.0 * (a - b) / abs(b)
        out[r["metodo"]] = d
    return out


def mediana(dist_por_caso: dict, metodo: str, coefs) -> float:
    """mediana de |distância| de um método, em todos os casos e coeficientes"""
    xs = [abs(v) for d in dist_por_caso.values() for k, v in d.get(metodo, {}).items() if k in coefs]
    return float(np.median(xs)) if xs else float("nan")


def matriz(rows_por_caso: dict, coefs=PADRAO, min_ref: float = MIN_REF) -> tuple[list[str], np.ndarray]:
    """o quanto cada método ficou perto de cada outro: M[i, j] = mediana de |distância| do método i tomando o j como
    referência, em todos os casos e coeficientes (não é simétrica: o erro relativo divide pelo valor da referência)"""
    nomes = list(dict.fromkeys(r["metodo"] for rows in rows_por_caso.values() for r in rows
                               if "resumo" in r and "solo" not in r["metodo"]))
    M = np.full((len(nomes), len(nomes)), np.nan)
    for j, ref in enumerate(nomes):
        dist = {}
        for c, rows in rows_por_caso.items():
            R = next((r for r in rows if r["metodo"] == ref and "resumo" in r), None)
            if R is not None:
                dist[c] = distancia(rows, R, coefs, min_ref)
        for i, m in enumerate(nomes):
            M[i, j] = 0.0 if i == j else mediana(dist, m, coefs)
    return nomes, M


# ---------------------------------------------------------------------- saída em texto
def tabela(nome: str, rows: list[dict], V: float, coefs=None) -> str:
    cols = ["CL0", "CLa", "Cm0", "Cma", "CD0", "k", *[k for k in PADRAO if k not in ("CL0", "CLa", "Cma", "k")]] \
        if coefs is None else list(coefs)
    head = f"{'método':14s} " + " ".join(f"{k:>8s}" for k in cols)
    lines = [f"== {nome}  (V = {V:g} m/s; derivadas por rad, momentos no 1/4 da CMA)", head]
    for r in rows:
        if "erro" in r:
            lines.append(f"{r['metodo']:14s} (não rodou: {r['erro'][:90]})")
            continue
        v = valores(r)
        cells = [f"{v.get(k, np.nan):8.4f}" if math.isfinite(v.get(k, np.nan)) else f"{'—':>8s}" for k in cols]
        lines.append(f"{r['metodo']:14s} " + " ".join(cells))
    return "\n".join(lines)


def tabela_distancia(dist_por_caso: dict, ref_nome: str, coefs=PADRAO) -> str:
    """mediana do |erro| de cada método em cada coeficiente, sobre os casos"""
    metodos_ = list(dict.fromkeys(m for d in dist_por_caso.values() for m in d))
    lines = [f"== distância até {ref_nome}: mediana de |erro| nos casos (%; ponto neutro em % da CMA)",
             f"{'método':14s} " + " ".join(f"{METRICAS[k][0][:9]:>9s}" for k in coefs) + f" {'geral':>7s}"]
    for m in metodos_:
        cells = []
        for k in coefs:
            xs = [abs(d[m][k]) for d in dist_por_caso.values() if m in d and k in d[m]]
            cells.append(f"{np.median(xs):9.1f}" if xs else f"{'—':>9s}")
        lines.append(f"{m:14s} " + " ".join(cells) + f" {mediana(dist_por_caso, m, coefs):7.1f}")
    return "\n".join(lines)


def tabela_matriz(nomes: list[str], M: np.ndarray) -> str:
    lines = ["== proximidade entre os métodos: mediana de |erro| (%) da linha tomando a coluna como referência",
             f"{'':14s} " + " ".join(f"{n[:11]:>11s}" for n in nomes)]
    for i, n in enumerate(nomes):
        lines.append(f"{n:14s} " + " ".join(f"{x:11.1f}" if math.isfinite(x) else f"{'—':>11s}" for x in M[i]))
    return "\n".join(lines)


def gravar_csv(path: str, rows_por_caso: dict):
    """um valor por linha: caso, método, coeficiente, valor"""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["caso", "metodo", "coeficiente", "valor"])
        for c, rows in rows_por_caso.items():
            for r in rows:
                for k, v in valores(r).items():
                    if math.isfinite(v):
                        w.writerow([c, r["metodo"], k, f"{v:.6g}"])


# ---------------------------------------------------------------------- gráficos
def _plt():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def _salvar(fig, png: str):
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    fig.savefig(png, dpi=110)
    _plt().close(fig)


def grafico(nome: str, rows: list[dict], png: str, ref: dict | None = None):
    """C_L×α, C_m×α e C_D×C_L de cada método; a referência de fora (CSV), se houver, em preto tracejado"""
    plt = _plt()
    fig, ax = plt.subplots(1, 3, figsize=(15, 4.6))
    cores = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    for j, r in enumerate(rows):
        if "erro" in r:
            continue
        p, kw = r["polar"], dict(color=cores[j % len(cores)], label=r["metodo"])
        ax[0].plot(p.alpha, p.CL, ".-", **kw)
        ax[1].plot(p.alpha, p.Cm, ".-", **kw)
        if np.isfinite(p.CD).any():
            ax[2].plot(p.CD, p.CL, ".-", **kw)
    if ref:
        p, kw = ref["polar"], dict(color="k", lw=2, ls="--", label=os.path.basename(ref["titulo"]))
        ax[0].plot(p.alpha, p.CL, **kw)
        ax[1].plot(p.alpha, p.Cm, **kw)
        ax[2].plot(p.CD, p.CL, **kw)
    for a, (x, y) in zip(ax, (("α (°)", "C_L"), ("α (°)", "C_m (1/4 da CMA)"), ("C_D", "C_L"))):
        a.set_xlabel(x)
        a.set_ylabel(y)
        a.grid(alpha=0.3)
    ax[0].legend(fontsize=8)
    fig.suptitle(nome)
    fig.tight_layout()
    _salvar(fig, png)


def grafico_distancia(dist_por_caso: dict, ref_nome: str, png: str, V: float, coefs=PADRAO):
    """uma barra por caso e método em cada coeficiente: quão longe da referência; faixa verde de ±10 %"""
    plt = _plt()
    casos = list(dist_por_caso)
    metodos_ = list(dict.fromkeys(m for d in dist_por_caso.values() for m in d))
    mets = [k for k in coefs if any(k in d[m] for d in dist_por_caso.values() for m in d)]
    if not mets:
        return
    nc = 2 if len(mets) > 1 else 1
    nl = (len(mets) + nc - 1) // nc
    fig, axs = plt.subplots(nl, nc, figsize=(15 if nc == 2 else 8, 2.9 * nl + 0.6), squeeze=False)
    w = 0.8 / max(len(metodos_), 1)
    cores = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    for ax, k in zip(axs.flat, mets):
        for j, m in enumerate(metodos_):
            y = [dist_por_caso[c].get(m, {}).get(k, np.nan) for c in casos]
            ax.bar(np.arange(len(casos)) + (j - (len(metodos_) - 1) / 2) * w, np.clip(y, -100, 100), w,
                   label=m, color=cores[j % len(cores)])
        ax.axhline(0, color="k", lw=0.8)
        ax.axhspan(-10, 10, color="#2ca02c", alpha=0.10)
        ax.set_title(METRICAS[k][0], fontsize=10)
        ax.set_ylabel("% CMA" if METRICAS[k][1] == "pn" else "erro (%)")
        ax.set_xticks(np.arange(len(casos)), casos, fontsize=8)
        ax.grid(axis="y", alpha=0.3)
    for ax in list(axs.flat)[len(mets):]:
        ax.set_visible(False)
    axs.flat[0].legend(fontsize=7, ncol=3)
    fig.suptitle(f"distância até {ref_nome} (V = {V:g} m/s; barras cortadas em ±100 %; verde: ±10 %)")
    fig.tight_layout(rect=(0, 0, 1, 0.98))
    _salvar(fig, png)


def grafico_matriz(nomes: list[str], M: np.ndarray, png: str, V: float):
    """o mapa de calor da proximidade entre os métodos"""
    plt = _plt()
    fig, ax = plt.subplots(figsize=(1.0 * len(nomes) + 3, 0.8 * len(nomes) + 2))
    im = ax.imshow(np.clip(M, 0, 100), cmap="viridis_r", vmin=0, vmax=60)
    for i in range(len(nomes)):
        for j in range(len(nomes)):
            if math.isfinite(M[i, j]) and i != j:
                ax.text(j, i, f"{M[i, j]:.0f}", ha="center", va="center", fontsize=9,
                        color="white" if M[i, j] > 30 else "black")
    ax.set_xticks(range(len(nomes)), nomes, rotation=35, ha="right")
    ax.set_yticks(range(len(nomes)), nomes)
    ax.set_xlabel("referência")
    ax.set_ylabel("método")
    fig.colorbar(im, ax=ax, label="mediana de |erro| (%)")
    ax.set_title(f"proximidade entre os métodos (V = {V:g} m/s)")
    fig.tight_layout()
    _salvar(fig, png)


# ---------------------------------------------------------------------- varredura
VARIAVEIS = {"paineis": "painéis por semiasa", "V": "V (m/s)"}


def varrer(backend, acs: dict, var: str, xs: list[float], nomes=None, V: float = V_PADRAO,
           paineis: int | None = None) -> dict[tuple[str, str], list[dict]]:
    """roda os casos `acs` ({nome: Aircraft}) em cada valor de `var` (VARIAVEIS): {(caso, método): [valores por x]}"""
    out: dict[tuple[str, str], list[dict]] = {}
    for x in xs:
        kw = dict(V=V, paineis=paineis)
        kw["V" if var == "V" else "paineis"] = float(x) if var == "V" else int(x)
        for c, ac in acs.items():
            for r in rodar(backend, ac, kw["V"], nomes, kw["paineis"]):
                out.setdefault((c, r["metodo"]), []).append(valores(r))
    return out


def tabela_varredura(res: dict, var: str, xs: list, coefs) -> str:
    lines = []
    for (c, m), vs in res.items():
        if not any(vs):
            continue
        lines.append(f"== {c} / {m}: varrendo {VARIAVEIS[var]}")
        lines.append(f"{var:>8s} " + " ".join(f"{k:>9s}" for k in coefs))
        for x, v in zip(xs, vs):
            lines.append(f"{x:8g} " + " ".join(f"{v.get(k, np.nan):9.4f}" if math.isfinite(v.get(k, np.nan))
                                               else f"{'—':>9s}" for k in coefs))
    return "\n".join(lines)


def grafico_varredura(res: dict, var: str, xs: list, coefs, png: str):
    """um quadro por coeficiente: o valor contra a variável, uma linha por caso e método (convergência da malha)"""
    plt = _plt()
    mets = [k for k in coefs if any(math.isfinite(v.get(k, np.nan)) for vs in res.values() for v in vs)]
    if not mets:
        return
    nc = min(3, len(mets))
    nl = (len(mets) + nc - 1) // nc
    fig, axs = plt.subplots(nl, nc, figsize=(5 * nc, 3.2 * nl + 0.6), squeeze=False)
    casos = {c for c, _ in res}
    cores = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    for ax, k in zip(axs.flat, mets):
        for j, ((c, m), vs) in enumerate(res.items()):        # cor fixa por série: igual em todos os quadros
            y = [v.get(k, np.nan) for v in vs]
            if np.isfinite(y).any():
                ax.plot(xs, y, "o-", color=cores[j % len(cores)], label=m if len(casos) == 1 else f"{c}/{m}")
        ax.set_title(METRICAS[k][0] if k != "Cma" else "C_mα", fontsize=10)
        ax.set_xlabel(VARIAVEIS[var])
        ax.grid(alpha=0.3)
    for ax in list(axs.flat)[len(mets):]:
        ax.set_visible(False)
    axs.flat[0].legend(fontsize=7)
    fig.suptitle(f"varredura: {VARIAVEIS[var]}" + (f" — {next(iter(casos))}" if len(casos) == 1 else ""))
    fig.tight_layout()
    _salvar(fig, png)


# ---------------------------------------------------------------------- linha de comando
def _lista(txt: str | None) -> list[str] | None:
    return [x.strip() for x in txt.split(",") if x.strip()] if txt else None


def main(argv=None) -> int:
    from tools.aero.casos import CASOS, PAPEIS, com_perfil, so
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--caso", help=f"casos separados por vírgula: {', '.join(CASOS)} (padrão: todos)")
    ap.add_argument("--metodos", help="métodos separados por vírgula (padrão: todos)")
    ap.add_argument("--coef", help=f"coeficientes separados por vírgula: {', '.join(METRICAS)} "
                    f"(padrão: {','.join(PADRAO)})")
    ap.add_argument("--so", help=f"só estas superfícies de cada caso: {', '.join(PAPEIS)} (ex.: --so eh,ev); a "
                    "referência S, c, b fica a do avião inteiro")
    ap.add_argument("--V", type=float, default=V_PADRAO, help="velocidade (m/s)")
    ap.add_argument("--ref", default="avl", help="referência da distância: qualquer método (padrão: avl) ou 'csv' "
                    "(com --referencia)")
    ap.add_argument("--referencia", help="CSV de fora (ex.: a asa do lltdrek): alpha, CL, CD, Cm")
    ap.add_argument("--paineis", type=int, help="painéis por semiasa: nucleo_fino e nucleo_llt (faixas da asa) e "
                    "n_span dos outros (padrão: o de cada método; o nucleo fica com a malha da simulação)")
    ap.add_argument("--varrer", help="varredura de uma variável, ex.: paineis=2,4,8,16,24 ou V=8,12,16 (gráfico "
                    "varredura_<var>.png com --pasta)")
    ap.add_argument("--perfil", help="arquivo .dat (Selig ou Lednicer) no lugar do perfil da asa de cada caso")
    ap.add_argument("--perfil-em", default="asa", help=f"onde pôr o --perfil: {', '.join(PAPEIS)} (padrão: asa)")
    ap.add_argument("--min-ref", type=float, default=MIN_REF, help="coeficiente com |referência| menor que isso fica "
                    f"fora da distância (padrão: {MIN_REF:g})")
    ap.add_argument("--matriz", action="store_true", help="proximidade de cada método com cada outro")
    ap.add_argument("--pasta", help="grava os gráficos (<caso>.png, distancia_<ref>.png, matriz.png) e valores.csv")
    ap.add_argument("--lista", action="store_true", help="lista os casos, os métodos e os coeficientes")
    args = ap.parse_args(argv)
    if args.lista:
        print("casos:")
        for k, f in CASOS.items():
            print(f"  {k:13s} {f.__doc__.strip().splitlines()[0]}")
        print("métodos: nucleo, nucleo_fino, nucleo_solo25, nucleo_solo10, nucleo_llt, nucleo_gh, lltdrek, asb_vlm, asb_buildup, avl")
        print("coeficientes: " + ", ".join(f"{k} ({v[0]})" for k, v in METRICAS.items()))
        return 0
    casos = _lista(args.caso) or list(CASOS)
    coefs = tuple(_lista(args.coef) or PADRAO)
    for x in [c for c in casos if c not in CASOS] + [k for k in coefs if k not in METRICAS]:
        ap.error(f"desconhecido: {x} (veja --lista)")
    partes = _lista(args.so)
    if partes and any(p not in PAPEIS for p in partes):
        ap.error(f"--so aceita {', '.join(PAPEIS)}")
    if args.ref == "csv" and not args.referencia:
        ap.error("--ref csv pede --referencia arquivo.csv")
    nomes = set(_lista(args.metodos) or []) or None
    if nomes and args.ref != "csv":
        nomes.add(args.ref)

    from aerosim.backend.zig import ZigBackend
    backend = ZigBackend()
    externo = referencia_csv(args.referencia) if args.referencia else None
    sufixo = f" (só {'+'.join(partes)})" if partes else ""
    acs = {}
    for c in casos:
        ac = CASOS[c]()
        if args.perfil:
            ac = com_perfil(ac, args.perfil, _lista(args.perfil_em))
        if partes:
            ac = so(ac, partes)
            if ac is None:
                print(f"== {c}: sem {'+'.join(partes)}: pulado\n")
                continue
        acs[c] = ac
    if args.varrer:
        var, _, txt = args.varrer.partition("=")
        if var not in VARIAVEIS or not txt:
            ap.error(f"--varrer: {', '.join(VARIAVEIS)}, ex.: paineis=2,4,8")
        xs = [float(x) for x in _lista(txt)]
        res = varrer(backend, acs, var, xs, nomes, args.V, args.paineis)
        print(tabela_varredura(res, var, xs, coefs))
        if args.pasta:
            grafico_varredura(res, var, xs, coefs, os.path.join(args.pasta, f"varredura_{var}.png"))
            print(f"gráfico em {os.path.join(args.pasta, f'varredura_{var}.png')}")
        return 0
    rows_por_caso, dist = {}, {}
    for c, ac in acs.items():
        rows = rodar(backend, ac, args.V, nomes, args.paineis)
        rows_por_caso[c] = rows
        print(tabela(f"{c}: {ac.name}{sufixo}", rows, args.V, coefs if args.coef else None), end="\n\n")
        R = externo if args.ref == "csv" else next((r for r in rows if r["metodo"] == args.ref and "resumo" in r), None)
        if R is not None:
            dist[c] = distancia(rows, R, coefs, args.min_ref)
        if args.pasta:
            grafico(f"{ac.name}{sufixo} — V = {args.V:g} m/s", rows, os.path.join(args.pasta, f"{c}.png"), externo)
    if dist:
        print(tabela_distancia(dist, args.ref, coefs), end="\n\n")
    if args.matriz:
        print(tabela_matriz(*matriz(rows_por_caso, coefs, args.min_ref)), end="\n\n")
    if args.pasta:
        if dist:
            grafico_distancia(dist, args.ref, os.path.join(args.pasta, f"distancia_{args.ref}.png"), args.V, coefs)
        if args.matriz:
            grafico_matriz(*matriz(rows_por_caso, coefs, args.min_ref), os.path.join(args.pasta, "matriz.png"), args.V)
        gravar_csv(os.path.join(args.pasta, "valores.csv"), rows_por_caso)
        print(f"gráficos e valores.csv em {args.pasta}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

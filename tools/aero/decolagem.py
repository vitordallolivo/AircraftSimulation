"""O erro de cada modelo aerodinâmico ao longo de uma decolagem (fase A: sem mudar a simulação nem o AeroDrive).

1. Roda a decolagem da GUI (a análise "takeoff" do manager, com os parâmetros padrão dela) com o modelo de sempre
   (faixas do núcleo): o resumo e os checks saem iguais aos da GUI, e os gráficos dela vão para `decolagem_voo.png`.
2. Em pontos do registro (estado de cada instante: V, α, β, p, q, r, comandos, altura, tração, CG), calcula os
   coeficientes com cada método no MESMO estado e compara com os do núcleo como voou.

Métodos (`--metodos`): os de `tools/aero/coeficientes.py`. Os do núcleo (`nucleo`, `nucleo_llt`, `nucleo_gh`) veem a
altura (efeito solo do modifier) e a tração (esteira, se ligada) do instante. O lltdrek, o ASB e o AVL não veem chão
nem hélice: perto do chão, parte da diferença é isso. A referência (`simulacao`) é o núcleo com as mesmas contas da
corrida; ela tem de bater com o C_L do registro (a ferramenta confere). As sobrescritas das superfícies (ex.: C_L0
do `conventional`) e os coeficientes da fuselagem só entram no núcleo: `--puro` tira os dois e voa esse avião.

    python tools/aero/decolagem.py                                  # avião `conventional` (templates), métodos do núcleo
    python tools/aero/decolagem.py --aviao data/aircraft/Convencional_original.json --metodos nucleo_gh,lltdrek,avl
    python tools/aero/decolagem.py --puro --metodos nucleo_gh,lltdrek,asb_vlm,avl   # o mesmo avião para todos
    python tools/aero/decolagem.py --pontos 40 --pasta perfis/decolagem   # gráficos e erros.csv
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
from aerosim.interfaces.aero import AeroCase, FlightPoint  # noqa: E402

COEFS = ("CL", "CD", "Cm", "CY", "Cl", "Cn")
PADRAO = ("nucleo_llt", "nucleo_gh")


class Simulacao(ZigPanelSolver):
    """o núcleo com as contas da corrida: altura sobre o chão (`case.h`) e tração e torque de cada motor (`case.T`,
    `case.Q`) do instante (`aerosim_aero_coeffs_at`)"""
    name, title = "simulacao", "núcleo como voou (faixas)"

    def evaluate(self, model, case, points):
        V, ref, b, c = case.V, list(case.ref), model.b, model.c
        out = []
        with self.backend.session_for(model, overrides={"env": {"rho": case.rho}}) as s:
            for pt in points:
                raw = s.aero_coeffs_at(V, pt.alpha, pt.beta, pt.p * 2 * V / b, pt.q * 2 * V / c, pt.r * 2 * V / b,
                                       pt.de, pt.da, pt.dr, h=case.h, T=case.T, Q=case.Q, ref=ref)
                out.append(self.backend.translator.from_native(raw, model))
        return out


def carregar(caminho: str | None):
    """o avião: um arquivo (.json, .cfg) ou o nome de um modelo de `aerosim.model.templates` (padrão: conventional)"""
    from aerosim.model import templates
    if caminho and os.path.exists(caminho):
        from aerosim.data import load_aircraft
        return load_aircraft(caminho)
    nome = caminho or "conventional"
    f = getattr(templates, nome, None)
    if f is None:
        raise SystemExit(f"avião desconhecido: {nome!r} (um arquivo ou um modelo de aerosim.model.templates)")
    return f()


def puro(ac):
    """cópia do avião que todos os métodos veem igual: sem as sobrescritas das superfícies (C_Lα, C_L0, C_Lmáx,
    C_D0, c_m e downwash saem do perfil e da geometria) e sem os coeficientes da fuselagem (só o núcleo os soma)"""
    import copy
    a = copy.deepcopy(ac)
    for s in a.surfaces:
        s.CLa = s.CL0 = s.CLmax = s.CD0 = s.Cmac = s.eps0 = s.depsda = None
    f = a.fuselage
    f.Cma = f.Cnb = f.CYb = 0.0
    a.name += " (puro)"
    return a


COLUNAS = ("t", "n", "h", "Va", "Vg", "alpha", "beta", "p", "q", "r", "theta", "de", "da", "dr", "T", "Q", "Ibat",
           "xcg", "ycg", "zcg", "CL", "N_main", "N_steer", "N_skid")


def decolar(backend, ac, params: dict | None = None):
    """a decolagem da GUI: a análise "takeoff" do manager (`aerosim/manager/simulations/takeoff.py`), com os parâmetros
    padrão dela (ou `params`). Devolve a `SimResult` (resumo e checks como a GUI mostra) e o registro (dict)"""
    from aerosim.manager.manager import SimulationManager
    res = SimulationManager(backend).run("takeoff", ac, params or {})
    a = res.log
    return res, {k: np.asarray(a[k], float) for k in COLUNAS}


# unidades das chaves do resumo da análise "takeoff" (aerosim/manager/simulations/takeoff.py)
UNIDADES = dict(n_rot="m (distância ao puxar)", n_LO="m (saída do chão)", t_LO="s", V_LO="m/s", n_ht="m (até h_end)",
                V_ht="m/s", gamma_ht="° (subida em h_end)", cauda_min="m (folga da cauda)", CL_CLmax_max="—",
                q_pico="°/s", I_pico="A", Vs="m/s (estol)")


def resumo(res) -> str:
    """o resumo e os checks da análise, como o painel da GUI (`checks_panel`): chave e valor"""
    lines = ["== resumo da decolagem (o que a GUI mostra)"]
    for k, v in res.summary.items():
        txt = f"{v:.4g}" if isinstance(v, float) else str(v)
        lines.append(f"  {k:14s} {txt:>10s}  {UNIDADES.get(k, '')}")
    for c in getattr(res, "checks", None) or []:
        lines.append(f"  [{getattr(c, 'level', '')}] {getattr(c, 'item', c)}: {getattr(c, 'value', '')} "
                     f"({getattr(c, 'criterion', '')})")
    return "\n".join(lines)


def grafico_voo(log: dict, idx, png: str, titulo: str):
    """os gráficos da decolagem da GUI (perfil, velocidade, atitude, trem, motor), com os pontos avaliados marcados"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1, 5, figsize=(22, 4.2))
    t = log["t"]
    quadros = [("Perfil da decolagem", "n", ("h",), "distância (m)", "h (m)", 1.0),
               ("Velocidade", "t", ("Va", "Vg"), "t (s)", "m/s", 1.0),
               ("Atitude", "t", ("theta", "alpha", "de"), "t (s)", "graus", math.degrees(1.0)),
               ("Reações no trem", "t", ("N_steer", "N_main", "N_skid"), "t (s)", "N", 1.0),
               ("Tração e corrente", "t", ("T", "Ibat"), "t (s)", "N / A", 1.0)]
    for ax, (tit, x, ys, xl, yl, k) in zip(axs, quadros):
        for y in ys:
            ax.plot(log[x], log[y] * k, label=y)
            ax.plot(log[x][idx], log[y][idx] * k, "k.", ms=4)
        ax.set_title(tit, fontsize=10)
        ax.set_xlabel(xl)
        ax.set_ylabel(yl)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7)
    fig.suptitle(titulo + f"  (pontos: os {len(idx)} instantes avaliados; t até {t[-1]:.1f} s)")
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    fig.savefig(png, dpi=110)
    plt.close(fig)


def pontos(log: dict, n: int, v_min: float) -> np.ndarray:
    """n índices do registro igualmente espaçados no tempo, com V ≥ v_min (abaixo disso os coeficientes não dizem nada)"""
    ok = np.flatnonzero(log["Va"] >= v_min)
    if len(ok) == 0:
        return ok
    return np.unique(ok[np.linspace(0, len(ok) - 1, min(n, len(ok))).round().astype(int)])


def avaliar(backend, ac, log: dict, idx: np.ndarray, nomes, paineis=None) -> dict[str, dict[str, np.ndarray]]:
    """{método: {coeficiente: valores nos pontos idx}}; um método que falha num ponto fica NaN ali"""
    from aerosim.model.universal import build_model
    from tools.aero.coeficientes import _nome, metodos
    model = build_model(ac)
    n_mot = max(len([u for u in ac.propulsion if u.enabled]), 1)
    solvers = [Simulacao(backend)] + [s for s in metodos(backend, paineis)
                                      if "solo" not in s.name and _nome(s) in nomes]
    out = {}
    for so in solvers:
        nome = _nome(so)
        if so.available():
            print(f"  {nome}: não roda ({so.available()})")
            continue
        vals = {k: np.full(len(idx), np.nan) for k in COEFS}
        for j, i in enumerate(idx):
            V = log["Va"][i]
            b, c = model.b, model.c
            case = AeroCase(V=V, rho=ac.environment.rho, alphas=np.array([0.0]),
                            ref=(log["xcg"][i], log["ycg"][i], log["zcg"][i]))
            case.h = float(log["h"][i])
            n = len([u for u in ac.propulsion if u.enabled])
            case.T = tuple([log["T"][i] / n_mot] * n)       # o registro tem a soma: dividida igual entre os motores
            case.Q = tuple([log["Q"][i] / n_mot] * n)
            pt = FlightPoint(log["alpha"][i], log["beta"][i], log["p"][i] * b / (2 * V), log["q"][i] * c / (2 * V),
                             log["r"][i] * b / (2 * V), log["de"][i], log["da"][i], log["dr"][i])
            try:
                r = so.evaluate(model, case, [pt])[0]
            except Exception as e:                       # noqa: BLE001 — um ponto que falha não para o resto
                print(f"  {nome}, t = {log['t'][i]:.2f} s: {type(e).__name__}: {e}")
                continue
            for k in COEFS:
                vals[k][j] = r.get(k, np.nan)
        out[nome] = vals
        print(f"  {nome}: {len(idx)} pontos")
    return out


def erros(res: dict, ref: str = "simulacao") -> dict[str, dict[str, tuple[float, float]]]:
    """{método: {coeficiente: (RMS, máximo |Δ|)}} contra a referência"""
    R = res[ref]
    out = {}
    for m, v in res.items():
        if m == ref:
            continue
        d = {}
        for k in COEFS:
            x = v[k] - R[k]
            x = x[np.isfinite(x)]
            if len(x):
                d[k] = (float(np.sqrt(np.mean(x * x))), float(np.max(np.abs(x))))
        out[m] = d
    return out


def tabela(err: dict, ref: str, forca: dict) -> str:
    """RMS e máximo de cada Δ coeficiente, mais o máximo de ΔL em % do peso e de ΔM (arfagem) em N·m"""
    head = f"{'método':12s} " + " ".join(f"{'Δ' + k + ' rms/máx':>18s}" for k in COEFS) + f" {'ΔL/W máx':>9s} {'ΔM máx':>8s}"
    lines = [f"== erro contra {ref} ao longo da decolagem", head]
    for m, d in err.items():
        cells = [f"{d[k][0]:8.4f}/{d[k][1]:<8.4f}"[:18].rjust(18) if k in d else f"{'—':>18s}" for k in COEFS]
        lines.append(f"{m:12s} " + " ".join(cells) + f" {forca[m]['L']:8.1f}% {forca[m]['M']:7.2f}")
    return "\n".join(lines)


def forcas(res: dict, log: dict, idx, ac, ref: str = "simulacao") -> dict[str, dict[str, float]]:
    """o erro em força: máximo de |ΔC_L| q S / peso (%) e de |ΔC_m| q S c (N·m)"""
    from aerosim.model.universal import build_model
    model = build_model(ac)
    q = 0.5 * ac.environment.rho * log["Va"][idx] ** 2
    W = model.mass["m"] * 9.80665
    out = {}
    for m, v in res.items():
        if m == ref:
            continue
        dL = np.abs(v["CL"] - res[ref]["CL"]) * q * model.S
        dM = np.abs(v["Cm"] - res[ref]["Cm"]) * q * model.S * model.c
        out[m] = dict(L=float(np.nanmax(dL) / W * 100) if np.isfinite(dL).any() else float("nan"),
                      M=float(np.nanmax(dM)) if np.isfinite(dM).any() else float("nan"))
    return out


def grafico(res: dict, log: dict, idx, png: str, titulo: str, ref: str = "simulacao"):
    """os seis coeficientes no tempo (linha cheia) e o Δ contra a referência (embaixo), com a saída do chão marcada"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    t = log["t"][idx]
    chao = (log["N_main"] > 0) | (log["N_steer"] > 0)
    t_lo = float(log["t"][np.flatnonzero(~chao)[0]]) if (~chao).any() else None
    cores = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    fig, axs = plt.subplots(2, len(COEFS), figsize=(4 * len(COEFS), 7), sharex=True)
    for j, (m, v) in enumerate(res.items()):
        kw = dict(color="k", lw=2) if m == ref else dict(color=cores[j % len(cores)])
        for c, k in enumerate(COEFS):
            axs[0, c].plot(t, v[k], ".-", label=m, ms=3, **kw)
            if m != ref:
                axs[1, c].plot(t, v[k] - res[ref][k], ".-", ms=3, **kw)
    axs[0, len(COEFS) - 1].plot(log["t"], log["CL"] * np.nan, alpha=0)   # mantém a escala
    for c, k in enumerate(COEFS):
        axs[0, c].set_title(k)
        axs[1, c].set_title(f"Δ{k} (− {ref})")
        axs[1, c].set_xlabel("t (s)")
        for a in axs[:, c]:
            a.grid(alpha=0.3)
            if t_lo is not None:
                a.axvline(t_lo, color="gray", ls="--", lw=1)
        axs[1, c].axhline(0, color="k", lw=0.8)
    axs[0, 0].plot(log["t"], log["CL"], color="gray", lw=1, alpha=0.6, label="C_L do registro")
    axs[0, 0].legend(fontsize=7)
    fig.suptitle(titulo + ("  (tracejado: saída do chão)" if t_lo is not None else ""))
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    fig.savefig(png, dpi=110)
    plt.close(fig)


def gravar_csv(path: str, res: dict, log: dict, idx):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["t", "metodo", *COEFS])
        for m, v in res.items():
            for j, i in enumerate(idx):
                w.writerow([f"{log['t'][i]:.3f}", m, *[f"{v[k][j]:.6g}" for k in COEFS]])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aviao", help="arquivo do avião ou modelo de aerosim.model.templates (padrão: conventional)")
    ap.add_argument("--metodos", help=f"separados por vírgula (padrão: {','.join(PADRAO)}); ex.: "
                    "nucleo_gh,lltdrek,asb_vlm,avl")
    ap.add_argument("--pontos", type=int, default=30, help="pontos do registro avaliados (padrão: 30)")
    ap.add_argument("--v-min", type=float, default=4.0, help="só pontos com V ≥ isso (m/s; padrão: 4)")
    ap.add_argument("--paineis", type=int, help="painéis por semiasa nos métodos do núcleo refinados")
    ap.add_argument("--puro", action="store_true", help="sem as sobrescritas das superfícies e sem os coeficientes da "
                    "fuselagem: o mesmo avião para todos os métodos (o lltdrek, o ASB e o AVL usam o perfil)")
    ap.add_argument("--pasta", help="grava decolagem.png (coeficientes), decolagem_voo.png (os gráficos da GUI) e "
                    "erros.csv")
    args = ap.parse_args(argv)
    from aerosim.backend.zig import ZigBackend
    backend = ZigBackend()
    ac = carregar(args.aviao)
    if args.puro:
        ac = puro(ac)
    res_voo, log = decolar(backend, ac)
    print(f"decolagem de {ac.name}: {len(log['t'])} linhas, até t = {log['t'][-1]:.2f} s ({res_voo.status})")
    print(resumo(res_voo))
    idx = pontos(log, args.pontos, args.v_min)
    nomes = set(x.strip() for x in (args.metodos or ",".join(PADRAO)).split(",") if x.strip())
    res = avaliar(backend, ac, log, idx, nomes, args.paineis)
    dif = np.nanmax(np.abs(res["simulacao"]["CL"] - log["CL"][idx]))
    print(f"conferência: o núcleo reavaliado bate com o C_L do registro até {dif:.1e}")
    print(tabela(erros(res), "simulacao", forcas(res, log, idx, ac)))
    if args.pasta:
        os.makedirs(args.pasta, exist_ok=True)
        grafico(res, log, idx, os.path.join(args.pasta, "decolagem.png"), f"{ac.name}: coeficientes na decolagem")
        grafico_voo(log, idx, os.path.join(args.pasta, "decolagem_voo.png"), f"{ac.name}: a decolagem (modelo de sempre)")
        gravar_csv(os.path.join(args.pasta, "erros.csv"), res, log, idx)
        print(f"gráfico e erros.csv em {args.pasta}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

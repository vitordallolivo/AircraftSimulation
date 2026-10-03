"""Figuras de comparação das abas Aerodinâmica e Estabilidade (PNG).

    python tools/plot_comparativo.py [saida/] [aeronave.cfg|conventional|flying_wing|twin_boom]

Roda as simulações "aerodynamics" e "stability" pelo Simulation Manager e desenha:
  1_polares.png        C_L(α), polar de arrasto, C_m(α) no CG, L/D — um traço por método
  2_derivadas.png      derivadas de estabilidade por método (um painel por derivada)
  3_metricas.png       C_Lα, C_Lmax, e, (L/D)máx., ponto neutro e margem por método
  4_pontas.png         e ótimo e ΔD total × h/b; traços no plano de Trefftz com Γ ótimo
  5_estabilidade.png   tesoura, raízes × V, ζ × V com faixas da MIL-F-8785C, respostas
  6_comandos.png       aileron, profundor e leme
  7_aeronaves.png      as três aeronaves-modelo lado a lado (margem, modos)
"""
from __future__ import annotations

import math
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from aerosim.aero import tipdevices as td  # noqa: E402
from aerosim.manager import SimulationManager  # noqa: E402
from aerosim.model import templates  # noqa: E402

# paleta categórica validada (ordem fixa: a cor segue o método, nunca a posição)
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
MK = ["o", "s", "^", "D", "v", "P", "X", "*"]
METHODS = ["Zig", "lltdrek", "ASB VLM", "ASB AeroBuildup", "ASB LiftingLine"]
STYLE = {m: dict(color=C[i], marker=MK[i]) for i, m in enumerate(METHODS)}
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8, "axes.spines.top": False,
    "axes.spines.right": False, "axes.titlesize": 11, "axes.titleweight": "bold", "axes.titlecolor": INK,
    "axes.titlelocation": "left", "font.size": 9, "legend.frameon": False, "lines.linewidth": 2,
    "lines.markersize": 5, "figure.dpi": 110, "axes.axisbelow": True,
})


def _line(ax, x, y, m, every=2, **kw):
    st = STYLE.get(m, {})
    ax.plot(x, y, label=m, markevery=every, markeredgecolor=SURF, markeredgewidth=0.8, **st, **kw)


def fig_polares(r, out):
    pol = {k[6:]: v for k, v in r.series.items() if k.startswith("polar_")}
    f, ax = plt.subplots(2, 2, figsize=(12, 8.5))
    for m, p in pol.items():
        _line(ax[0, 0], p["alpha"], p["CL"], m)
        _line(ax[0, 1], p["CD"], p["CL"], m)
        _line(ax[1, 0], p["alpha"], p["Cm"], m)
        _line(ax[1, 1], p["CL"], p["LD"], m)
    ax[0, 0].set(title="C_L × α", xlabel="α (°)", ylabel="C_L")
    ax[0, 1].set(title="Polar de arrasto", xlabel="C_D", ylabel="C_L")
    ax[1, 0].set(title="C_m × α (momentos no CG)", xlabel="α (°)", ylabel="C_m")
    ax[1, 0].axhline(0, color=INK2, lw=0.8)
    ax[1, 1].set(title="Eficiência L/D", xlabel="C_L", ylabel="L/D")
    ax[1, 1].set_ylim(bottom=0)
    h, l = ax[0, 0].get_legend_handles_labels()
    f.legend(h, l, loc="upper center", ncol=len(l), bbox_to_anchor=(0.5, 1.0))
    f.suptitle("Comparativo de métodos aerodinâmicos — mesma geometria, mesmo x_CG", y=1.04, fontsize=13,
               fontweight="bold", color=INK, x=0.02, ha="left")
    f.text(0.02, 0.995, "lltdrek: asa + EH (sem EV/fuselagem) · VLM: sem fuselagem · AeroBuildup/LiftingLine: "
           "perfil pelo NeuralFoil · C_D0 do modelo somado no Zig, lltdrek e VLM", color=INK2, fontsize=8.5)
    f.tight_layout(rect=(0, 0, 1, 0.96))
    f.savefig(os.path.join(out, "1_polares.png"), bbox_inches="tight")
    plt.close(f)


DER_LAB = {"CLa": "C_Lα", "Cma": "C_mα", "CYb": "C_Yβ", "Clb": "C_lβ", "Cnb": "C_nβ", "CLq": "C_Lq",
           "Cmq": "C_mq", "CYp": "C_Yp", "Clp": "C_lp", "Cnp": "C_np", "CYr": "C_Yr", "Clr": "C_lr", "Cnr": "C_nr"}


def fig_derivadas(r, out):
    t = r.series["derivadas"]
    ms = [m for m in METHODS if m in t]
    keys = [k for k in DER_LAB if k in t["derivada"]]
    f, axs = plt.subplots(3, 5, figsize=(15, 8.5))
    for ax, k in zip(axs.flat, keys):
        i = t["derivada"].index(k)
        vals = [t[m][i] for m in ms]
        y = np.arange(len(ms))
        for j, (m, v) in enumerate(zip(ms, vals)):
            if np.isfinite(v):
                ax.barh(j, v, color=STYLE[m]["color"], height=0.62, edgecolor=SURF, linewidth=2)
                ax.text(v, j, f" {v:.3g} ", va="center", ha="left" if v >= 0 else "right", color=INK, fontsize=8)
            else:
                ax.text(0, j, " n/d", va="center", ha="left", color=INK2, fontsize=8)
        ax.axvline(0, color=INK2, lw=0.8)
        ax.set_yticks(y, ms if ax in axs[:, 0] else [""] * len(ms))
        ax.invert_yaxis()
        ax.set_title(DER_LAB[k] + " (1/rad)")
        ax.grid(axis="y", visible=False)
        lo, hi = ax.get_xlim()
        pad = 0.35 * (hi - lo)
        ax.set_xlim(lo - (pad if lo < 0 else 0), hi + (pad if hi > 0 else 0))
    for ax in list(axs.flat)[len(keys):]:
        ax.axis("off")
    f.suptitle("Derivadas de estabilidade por método (α = 2°, momentos no CG; n/d: o método não calcula)",
               x=0.02, ha="left", fontsize=13, fontweight="bold", color=INK)
    f.tight_layout()
    f.savefig(os.path.join(out, "2_derivadas.png"), bbox_inches="tight")
    plt.close(f)


def fig_metricas(r, out):
    s = r.summary
    ms = [m for m in METHODS if f"[{m}] CLa_fit" in s]
    items = [("CLa_fit", "C_Lα (1/rad)"), ("CLmax", "C_Lmax"), ("e", "e (ajuste de C_Di)"),
             ("LDmax", "(L/D) máx."), ("x_np_mac", "ponto neutro (% CMA)"), ("SM", "margem estática (% CMA)")]
    f, axs = plt.subplots(2, 3, figsize=(13, 6.5))
    for ax, (k, lab) in zip(axs.flat, items):
        vals = [s.get(f"[{m}] {k}", np.nan) for m in ms]
        for j, (m, v) in enumerate(zip(ms, vals)):
            if np.isfinite(v):
                ax.bar(j, v, color=STYLE[m]["color"], width=0.62, edgecolor=SURF, linewidth=2)
                ax.text(j, v, f"{v:.3g}", ha="center", va="bottom", color=INK, fontsize=8.5)
        ax.set_xticks(range(len(ms)), [m.replace("ASB ", "ASB\n") for m in ms], fontsize=8)
        ax.set_title(lab)
        ax.grid(axis="x", visible=False)
        if k == "SM":
            ax.axhspan(5, 15, color=C[2], alpha=0.12, lw=0, zorder=0)
            ax.text(len(ms) - 0.5, 15, "faixa usual 5–15 %", ha="right", va="bottom", color=INK2, fontsize=8)
        if k == "x_np_mac":
            cg = s["x_CG usado (% CMA)"]
            ax.axhline(cg, color=INK2, lw=1, ls="--")
            ax.text(-0.4, cg, f"CG {cg:.1f} %", va="bottom", color=INK2, fontsize=8)
    f.suptitle("Métricas da polar por método", x=0.02, ha="left", fontsize=13, fontweight="bold", color=INK)
    f.tight_layout()
    f.savefig(os.path.join(out, "3_metricas.png"), bbox_inches="tight")
    plt.close(f)


DEV = [("winglet", "winglet"), ("placa", "placa de ponta"), ("caixa", "asa em caixa"), ("asa_c", "asa em C")]


def fig_pontas(r, out):
    t = r.series["tips"]
    f = plt.figure(figsize=(14, 9))
    gs = f.add_gridspec(2, 4, height_ratios=[1.25, 1])
    a1, a2 = f.add_subplot(gs[0, :2]), f.add_subplot(gs[0, 2:])
    for i, (k, lab) in enumerate(DEV):
        a1.plot(t["h_b"], t[f"e_{k}"], color=C[i], marker=MK[i], label=lab, markevery=2)
        a2.plot(t["h_b"], t[f"dD_{k}"], color=C[i], marker=MK[i], label=lab, markevery=2)
    a1.plot(t["h_b"], t["e_raymer_placa"], color=INK2, ls="--", lw=1.4, label="Raymer: 1 + 1,9 h/b")
    a1.scatter([0.2], [1.46], s=70, facecolor="none", edgecolor=INK, lw=1.5, zorder=5, label="Kroo (2001): caixa 0,2")
    a1.set(title="Fator de eficiência ótimo (plano de Trefftz)", xlabel="h/b", ylabel="e")
    a1.legend(loc="upper left")
    a2.plot(t["h_b"], t["dD_extensao"], color=C[4], marker=MK[4], markevery=2, label="extensão (mesma área molhada)")
    a2.plot(t["h_b"], t["dD_extensao_mesmo_M"], color=C[5], marker=MK[5], markevery=2,
            label="extensão (mesmo M na raiz)")
    a2.axhline(0, color=INK2, lw=0.8)
    cl = r.summary.get("CL_tip", None)
    a2.set(title="Arrasto total vs. asa sem dispositivo (induzido + atrito)", xlabel="h/b",
           ylabel="ΔD / D_i da asa base (%)")
    a2.legend(loc="upper right", fontsize=8)
    for i, (k, lab) in enumerate(DEV):
        ax = f.add_subplot(gs[1, i])
        ol = td.optimal_loading(td.trace(k, 0.2, 60))
        mid, g = ol["mid"], ol["gamma"]
        gn = g / np.abs(g).max() * 0.12
        # Γ desenhado na normal do próprio painel
        segs = td.trace(k, 0.2, 60)
        for sg in segs:
            ax.plot(sg[:, 0], sg[:, 1], color=INK, lw=2.4, solid_capstyle="round")
        A = np.vstack([s[:-1] for s in segs])
        B = np.vstack([s[1:] for s in segs])
        d = B - A
        ln = np.hypot(d[:, 0], d[:, 1])
        n = np.column_stack([-d[:, 1], d[:, 0]]) / ln[:, None]
        p = mid + n * gn[:, None]
        ax.scatter(p[:, 0], p[:, 1], s=6, color=C[i])
        ax.set_aspect("equal")
        ax.set_title(f"{lab}: e = {td.span_efficiency(k, 0.2, 60):.3f}", fontsize=10)
        ax.set_xlim(-0.65, 0.65)
        ax.set_ylim(-0.3, 0.42)
        ax.set_xlabel("y/b")
        ax.grid(False)
        ax.set_yticks([])
    f.text(0.02, 0.935, "embaixo: traço da esteira com h/b = 0,2 (preto) e circulação ótima Γ desenhada na normal "
           "(pontos); ΔD com C_f = 0,006 na área molhada do dispositivo", color=INK2, fontsize=9)
    f.suptitle("Dispositivos de ponta de asa — Munk/Kroo (Trefftz), Raymer, Whitcomb/Jones",
               x=0.02, ha="left", fontsize=13, fontweight="bold", color=INK)
    f.tight_layout(rect=(0, 0, 1, 0.93))
    f.savefig(os.path.join(out, "4_pontas.png"), bbox_inches="tight")
    plt.close(f)


MODE_LAB = {"curto_periodo": "curto período", "fugoide": "fugóide", "dutch_roll": "dutch roll",
            "rolamento": "rolamento", "espiral": "espiral"}


def fig_estabilidade(r, out):
    S = r.series
    f, axs = plt.subplots(2, 3, figsize=(16, 9.5))
    ax = axs[0, 0]
    sc = S.get("tesoura")
    if sc is not None:
        ax.plot(sc["fwd_ctrl"], sc["Sh_S"], color=C[0], marker=MK[0], markevery=3, label="dianteiro: controle (pouso)")
        ax.plot(sc["fwd_rot"], sc["Sh_S"], color=C[1], marker=MK[1], markevery=3, label="dianteiro: rotação")
        ax.plot(sc["aft"], sc["Sh_S"], color=C[2], marker=MK[2], markevery=3, label="traseiro: MS mínima")
        ax.plot(sc["np"], sc["Sh_S"], color=INK2, ls="--", lw=1.3, label="ponto neutro")
        lo, hi = sc["cg_fwd"][0], sc["cg_aft"][0]
        ax.axvspan(lo, hi, color=C[3], alpha=0.15, lw=0, label="faixa de CG pedida")
        sh = r.summary.get("[tesoura] S_h/S atual")
        smin = r.summary.get("[tesoura] S_h/S mínimo para a faixa de CG")
        ax.axhline(sh, color=INK, lw=1, ls=":")
        ax.text(ax.get_xlim()[0] if False else min(sc["fwd"]), sh, " S_h/S atual", va="bottom", color=INK, fontsize=8)
        if smin is not None and np.isfinite(smin):
            ax.axhline(smin, color=C[7], lw=1.2)
            ax.text(min(sc["fwd"]), smin, f" mínimo {smin:.3f}", va="top", color=INK, fontsize=8)
        ax.set_xlim(min(np.nanmin(sc["fwd"]), lo) - 5, max(np.nanmax(sc["np"]), hi) + 5)
        ax.legend(fontsize=7.5, loc="upper right")
    ax.set(title="Gráfico tesoura", xlabel="x_CG (% CMA)", ylabel="S_h / S")
    ax = axs[0, 1]
    for i, m in enumerate(MODE_LAB):
        d = S.get(f"raiz_{m}")
        if d is not None:
            ax.scatter(d["re"], d["im"], s=28, color=C[i], marker=MK[i], label=MODE_LAB[m], edgecolor=SURF, lw=0.6,
                       zorder=3)
    ax.axvline(0, color=INK2, lw=1)
    ax.set(title="Raízes × V (plano s)", xlabel="Re (1/s)", ylabel="Im (rad/s)")
    ax.set_xscale("symlog", linthresh=1)
    ax.legend(fontsize=8)
    mv = S.get("modos_V")
    ax = axs[0, 2]
    if mv is not None:
        for i, (m, lo1, hi1) in enumerate((("curto_periodo", 0.30, 2.0), ("fugoide", 0.04, None),
                                           ("dutch_roll", 0.08, None))):
            ax.plot(mv["V"], mv[f"zeta_{m}"], color=C[i], marker=MK[i], label=MODE_LAB[m])
        ax.axhline(0.30, color=C[0], lw=1, ls="--")
        ax.text(mv["V"][0], 0.30, " mín. curto período (B)", va="bottom", color=INK2, fontsize=7.5)
        ax.axhline(0.08, color=C[2], lw=1, ls="--")
        ax.text(mv["V"][0], 0.08, " mín. dutch roll (B)", va="bottom", color=INK2, fontsize=7.5)
        ax.axhline(0.04, color=C[1], lw=1, ls="--")
        ax.text(mv["V"][-1], 0.04, "mín. fugóide ", va="top", ha="right", color=INK2, fontsize=7.5)
        ax.legend(fontsize=8, loc="upper right")
    ax.set(title="Amortecimento × V (MIL-F-8785C nível 1, cat. B)", xlabel="V (m/s)", ylabel="ζ")
    ax.set_ylim(bottom=0)
    ax = axs[1, 0]
    rl = S.get("resp_lon")
    if rl is not None:
        for i, (k, lab) in enumerate((("q", "q (°/s)"), ("theta", "θ (°)"), ("u", "u (m/s)"), ("w", "w (m/s)"))):
            ax.plot(rl["t"], rl[k], color=C[i], label=lab, lw=1.8)
        ax.legend(fontsize=8)
    ax.set(title="Resposta a doublet de profundor (±2°)", xlabel="t (s)")
    ax = axs[1, 1]
    rt = S.get("resp_lat")
    if rt is not None:
        for i, (k, lab) in enumerate((("p", "p (°/s)"), ("r", "r (°/s)"), ("phi", "φ (°)"), ("v", "v (m/s)"))):
            ax.plot(rt["t"], rt[k], color=C[i], label=lab, lw=1.8)
        ax.legend(fontsize=8)
    ax.set(title="Resposta a pulso de aileron (5°, 1 s)", xlabel="t (s)")
    ax = axs[1, 2]
    cm = S.get("cm_alpha")
    if cm is not None:
        for i, (k, lab) in enumerate((("Cm_de_up", "δe cabrado máx."), ("Cm_de0", "δe = 0"),
                                      ("Cm_de_down", "δe picado máx."))):
            ax.plot(cm["alpha"], cm[k], color=C[i], label=lab, marker=MK[i], markevery=6)
        ax.axhline(0, color=INK2, lw=0.8)
        ax.legend(fontsize=8)
    ax.set(title="C_m × α no CG (faixa de equilíbrio)", xlabel="α (°)", ylabel="C_m")
    f.suptitle("Estabilidade — estática, tesoura e dinâmica", x=0.02, ha="left", fontsize=13, fontweight="bold",
               color=INK)
    f.tight_layout()
    f.savefig(os.path.join(out, "5_estabilidade.png"), bbox_inches="tight")
    plt.close(f)


def fig_comandos(r, out):
    S = r.series
    f, axs = plt.subplots(1, 3, figsize=(16, 5))
    a = S.get("aileron")
    ax = axs[0]
    if a is not None:
        ks = [k for k in a if k.startswith("t_")]
        for i, k in enumerate(ks):
            ax.plot(a["eta_i"], a[k], color=C[i], marker=MK[i], label=k[2:], markevery=2)
        ax.plot(a["eta_i"], a["requisito"], color=INK, ls="--", lw=1.2, label="requisito MIL")
        ax.legend(fontsize=8)
        ax.set_ylim(0, max(4.0, a["requisito"][0] * 2))
    ax.set(title="Aileron: tempo até o ângulo pedido", xlabel="início do aileron η_i (fração de b/2)", ylabel="t (s)")
    p = S.get("profundor")
    ax = axs[1]
    if p is not None:
        ax.plot(p["ce_c"], p["de_pouso"], color=C[0], marker=MK[0], label="equilíbrio no C_L de pouso", markevery=2)
        ax.plot(p["ce_c"], p["de_rotacao"], color=C[1], marker=MK[1], label="rotação na decolagem", markevery=2)
        ax.axhline(p["de_max"][0], color=INK, ls="--", lw=1.2, label="δe máximo")
        ax.legend(fontsize=8)
    ax.set(title="Profundor: deflexão necessária (CG dianteiro)", xlabel="c_e / c", ylabel="δe (°)")
    l = S.get("leme")
    ax = axs[2]
    if l is not None:
        ax.plot(l["cr_c"], l["dr_vento"], color=C[0], marker=MK[0], label="vento cruzado 0,2 V_S", markevery=2)
        if "dr_motor_parado" in l:
            ax.plot(l["cr_c"], l["dr_motor_parado"], color=C[1], marker=MK[1], label="motor crítico parado", markevery=2)
        ax.axhline(l["dr_max"][0], color=INK, ls="--", lw=1.2, label="δr máximo")
        ax.legend(fontsize=8)
        ax.set_ylim(bottom=0)
    ax.set(title="Leme: deflexão necessária", xlabel="c_r / c", ylabel="δr (°)")
    f.suptitle("Dimensionamento das superfícies de comando", x=0.02, ha="left", fontsize=13, fontweight="bold",
               color=INK)
    f.tight_layout()
    f.savefig(os.path.join(out, "6_comandos.png"), bbox_inches="tight")
    plt.close(f)


def fig_aeronaves(m, out):
    names = [("conventional", "convencional"), ("twin_boom", "bimotor cauda em V"), ("flying_wing", "asa voadora")]
    rs = {lab: m.run("stability", getattr(templates, n)(), {"scissor": False}) for n, lab in names}
    f, axs = plt.subplots(1, 3, figsize=(16, 5))
    labs = list(rs)
    ax = axs[0]
    sm = [rs[l].summary["[estática] margem estática (% CMA)"] for l in labs]
    sma = [rs[l].summary["[estática] margem estática analítica (% CMA)"] for l in labs]
    x = np.arange(len(labs))
    ax.bar(x - 0.18, sm, 0.34, color=C[0], label="núcleo (numérico)", edgecolor=SURF, lw=2)
    ax.bar(x + 0.18, sma, 0.34, color=C[1], label="analítico (Etkin/Nelson)", edgecolor=SURF, lw=2)
    for xi, a, b in zip(x, sm, sma):
        ax.text(xi - 0.18, a, f"{a:.1f}", ha="center", va="bottom", fontsize=8, color=INK)
        ax.text(xi + 0.18, b, f"{b:.1f}", ha="center", va="bottom", fontsize=8, color=INK)
    ax.axhspan(5, 15, color=C[2], alpha=0.12, lw=0, zorder=0)
    ax.set_xticks(x, labs)
    ax.set(title="Margem estática (% CMA)")
    ax.grid(axis="x", visible=False)
    ax.legend(fontsize=8)
    for j, (m_, ylab) in enumerate((("curto_periodo", "curto período"), ("dutch_roll", "dutch roll"))):
        ax = axs[1 + j]
        for i, l in enumerate(labs):
            mv = rs[l].series.get("modos_V")
            if mv is not None:
                ax.plot(mv["V"], mv[f"zeta_{m_}"], color=C[i], marker=MK[i], label=l)
        lim = 0.30 if m_ == "curto_periodo" else 0.08
        ax.axhline(lim, color=INK, ls="--", lw=1)
        ax.text(ax.get_xlim()[0], lim, " nível 1 (cat. B)", va="bottom", fontsize=7.5, color=INK2)
        ax.set(title=f"ζ do {ylab} × V", xlabel="V (m/s)", ylabel="ζ")
        ax.set_ylim(bottom=0)
        ax.legend(fontsize=8)
    f.suptitle("Aeronaves-modelo lado a lado", x=0.02, ha="left", fontsize=13, fontweight="bold", color=INK)
    f.tight_layout()
    f.savefig(os.path.join(out, "7_aeronaves.png"), bbox_inches="tight")
    plt.close(f)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "comparativo"
    which = sys.argv[2] if len(sys.argv) > 2 else "conventional"
    os.makedirs(out, exist_ok=True)
    if os.path.exists(which):
        from aerosim.data import load_aircraft
        ac = load_aircraft(which)
    else:
        ac = getattr(templates, which)()
    m = SimulationManager()
    print("aerodinâmica…")
    ra = m.run("aerodynamics", ac, {"use_asb_ll": True})
    fig_polares(ra, out)
    fig_derivadas(ra, out)
    fig_metricas(ra, out)
    fig_pontas(ra, out)
    print("estabilidade…")
    rs = m.run("stability", ac, {})
    fig_estabilidade(rs, out)
    fig_comandos(rs, out)
    print("aeronaves-modelo…")
    fig_aeronaves(m, out)
    print("figuras em", out)


if __name__ == "__main__":
    main()

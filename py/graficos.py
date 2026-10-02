"""Graficos: um grafico por grandeza, cores por etapa, rotulos em todos os eixos."""
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

import analises as A

plt.rcParams.update({"figure.dpi": 130, "axes.grid": True, "grid.alpha": 0.3, "font.size": 9,
                     "legend.fontsize": 7.5, "axes.titlesize": 10})
CORES = ["#7f7f7f", "#d62728", "#ff7f0e", "#1f77b4", "#2ca02c", "#9467bd", "#8c564b",
         "#17becf", "#bcbd22", "#e377c2", "#000000", "#aec7e8", "#ffbb78"]
PAC = "#6a0dad"
COMP = [("asa", "asa", "#1f77b4"), ("eh", "EH", "#2ca02c"), ("ev", "EV", "#9467bd"), ("fus", "fuselagem", "#8c564b"),
        ("hel", "hélice (tração + torque)", "#d62728"), ("gir", "giroscópico", "#e377c2"), ("tr", "trem", "#7f7f7f"),
        ("liq", "líquido (sloshing)", "#17becf"), ("car", "carga LAPES", PAC)]


def salva(fig, pasta, nome):
    fig.tight_layout()
    fig.savefig(os.path.join(pasta, nome), dpi=130)
    plt.close(fig)


def por_etapa(ax, x, y, et, z=None, lw=1.6):
    for k in range(len(CORES)):
        idx = np.where(et == k)[0]
        if not len(idx):
            continue
        j = np.r_[idx, min(idx[-1] + 1, len(x) - 1)]
        if z is None:
            ax.plot(x[j], y[j], color=CORES[k], lw=lw)
        else:
            ax.plot(x[j], y[j], z[j], color=CORES[k], lw=lw)


def leg_etapas(ax, et, nomes, loc="best", ncol=1, extra=()):
    h = [Line2D([0], [0], color=CORES[k], lw=2) for k in range(len(nomes)) if (et == k).any()]
    l = [nomes[k] for k in range(len(nomes)) if (et == k).any()]
    for cor, rot, kw in extra:
        h.append(Line2D([0], [0], color=cor, **kw)); l.append(rot)
    return ax.legend(h, l, loc=loc, ncol=ncol, fontsize=7)


def fundo(ax, t, et):
    for k in range(len(CORES)):
        s = np.where(et == k)[0]
        if len(s):
            ax.axvspan(t[s[0]], t[s[-1]], color=CORES[k], alpha=0.08, lw=0)


def _artigo(D):
    """fases do artigo: corrida (eq. 5) ate TDN = 0; rotacao (eq. 6: TDN = 0, TDP = R_N) ate R_N = 0"""
    Rn, Rm, RN = D["TDN_art"].copy(), D["TDP_art"].copy(), D["RN_art"].copy()
    i1 = np.argmax(Rn <= 0) if (Rn <= 0).any() else len(Rn)
    Rn[i1:] = 0; Rm[i1:] = RN[i1:]
    i2 = i1 + (np.argmax(RN[i1:] <= 0) if (RN[i1:] <= 0).any() else len(RN) - i1)
    Rn[i2:] = 0; Rm[i2:] = 0
    return Rn, Rm, min(i2, len(Rn) - 1)


# ====================================================================== missao
def missao(png, M, nomes_pernas, av, resumo, semsl=None, raj=None):
    T, SO, PK, ev = M["traj"], M["solo"], M["pacote"], M["eventos"]
    nomes = A.nomes_etapas(nomes_pernas)
    et = A.etapas(T, ev)
    t = T["t"]
    tem_pk = len(PK.get("t", [])) > 1
    Wv = np.array([T["We"][0], T["Wn"][0], -T["Wd"][0]]); Wv /= np.linalg.norm(Wv)

    # 3D
    fig = plt.figure(figsize=(11, 7.5))
    ax = fig.add_subplot(projection="3d")
    por_etapa(ax, T["e"], T["n"], et, z=T["h"])
    ax.plot(T["e"], T["n"], 0 * T["h"], color="0.6", lw=0.5)
    if tem_pk:
        ax.plot(PK["e"], PK["n"], PK["h"], color=PAC, lw=2.5)
    ax.quiver(100, 50, 22, *(Wv * 60), color="k", lw=1.5, arrow_length_ratio=0.2)
    ax.set_xlabel("e (m) — leste"); ax.set_ylabel("n (m) — eixo da pista"); ax.set_zlabel("h (m)")
    ax.set_box_aspect((1.7, 3.0, 0.6)); ax.view_init(elev=28, azim=-60)
    leg_etapas(ax, et, nomes, loc="upper left", ncol=2,
               extra=[(PAC, "carga LAPES (paraquedas)", dict(lw=2.5)), ("0.6", "sombra no solo", dict(lw=0.8)),
                      ("k", "direção do vento", dict(lw=1.5))])
    salva(fig, png, "01_trajetoria_3d.png")

    # planos
    i4 = np.argmax(T["seg"] >= 4)
    t_v2 = t[i4] if i4 > 0 else t[-1]
    todos = np.ones_like(t, bool)
    for nome, s, tit, eixo in [("02a_plano_xy_volta1.png", t < t_v2, "Plano xy — volta 1 (vista de cima)", "xy"),
                               ("02b_plano_xy_volta2.png", t >= t_v2, "Plano xy — volta 2 (vista de cima)", "xy"),
                               ("03_plano_xz_decolagem.png", t < t_v2, "Plano xz — volta 1: decolagem até a curva para o LAPES", "xz"),
                               ("04_plano_xz_pouso.png", t >= t_v2, "Plano xz — volta 2: passagem LAPES até o pouso", "xz"),
                               ("05_plano_yz.png", todos, "Plano yz (de frente)", "yz")]:
        fig, ax = plt.subplots(figsize=(12, 5.0 if eixo == "xy" else 4.2))
        X = {"xy": T["n"], "xz": T["n"], "yz": T["e"]}[eixo]
        Y = {"xy": T["e"], "xz": T["h"], "yz": T["h"]}[eixo]
        por_etapa(ax, X[s], Y[s], et[s])
        mostra_pk = tem_pk and (eixo == "yz" or t[s][-1] >= PK["t"][0] >= t[s][0])
        if mostra_pk:
            ax.plot({"xy": PK["n"], "xz": PK["n"], "yz": PK["e"]}[eixo], {"xy": PK["e"], "xz": PK["h"], "yz": PK["h"]}[eixo],
                    color=PAC, lw=2.5)
        if eixo == "xy":
            ax.set_aspect("equal"); ax.invert_yaxis()
        ax.set_xlabel({"xy": "n (m) — eixo da pista", "xz": "n (m) — eixo da pista", "yz": "e (m) — leste"}[eixo])
        ax.set_ylabel({"xy": "e (m) — para baixo = leste", "xz": "h (m)", "yz": "h (m)"}[eixo])
        ax.set_title(tit)
        leg_etapas(ax, et[s], nomes, ncol=3, extra=[(PAC, "carga LAPES", dict(lw=2.5))] if mostra_pk else [])
        salva(fig, png, nome)

    def serie(nome, curvas, ylab, tit, linhas=(), ylim=None):
        fig, ax = plt.subplots(figsize=(12, 4.3))
        fundo(ax, t, et)
        for y, r, cor, lw in curvas:
            ax.plot(t, y, color=cor, lw=lw, label=r)
        for v, r, cor, ls in linhas:
            ax.axhline(v, color=cor, ls=ls, lw=1, label=r)
        ax.set_xlabel("t (s)"); ax.set_ylabel(ylab); ax.set_title(tit)
        if ylim: ax.set_ylim(*ylim)
        l1 = ax.legend(loc="upper right", fontsize=7.5); ax.add_artist(l1)
        leg_etapas(ax, et, nomes, loc="lower left", ncol=4)
        salva(fig, png, nome)

    sv = T["Va"] > 6
    nan = lambda c: np.where(sv, T[c], np.nan)
    serie("06_angulos.png", [(T["theta"], "θ arfagem", "#1f77b4", 1.2), (T["alfa"], "α ataque", "#d62728", 1.2),
                             (T["gama"], "γ trajetória", "#2ca02c", 1.2), (T["phi"], "φ rolagem", "#ff7f0e", 1.0),
                             (T["beta"], "β derrapagem", "#9467bd", 1.0)],
          "ângulo (°)", "Ângulos de atitude e aerodinâmicos", linhas=[(resumo["alfa_estol"], "α de estol", "k", ":")], ylim=(-25, 35))
    serie("07_rumo.png", [(np.degrees(np.unwrap(np.radians(T["psi"]))), "ψ proa", "#1f77b4", 1.4),
                          (np.degrees(np.unwrap(np.radians(T["chi"]))), "χ curso", "#2ca02c", 1.0)],
          "ângulo (°)", "Proa e curso (a diferença é o caranguejo contra o vento)")
    serie("08_velocidades.png", [(T["Va"], "V_a em relação ao ar", "#d62728", 1.4), (T["Vg"], "V_g em relação ao solo", "#1f77b4", 1.0),
                                 (T["Vref"], "V pedida", "k", 0.8)],
          "velocidade (m/s)", "Velocidades", linhas=[(resumo["Vs"], "V_s", "#7f7f7f", ":"), (1.2 * resumo["Vs"], "1,2 V_s", "#7f7f7f", "--")])
    serie("09_altura.png", [(T["h"], "h", "#d62728", 1.4), (np.where(t >= ev["tHt"], T["href"], np.nan), "h de referência", "k", 0.8)],
          "altura do CG (m)", "Altura")
    serie("10_CL.png", [(nan("CL"), "C_L total", "#000000", 1.5), (nan("CLasa"), "C_L da asa", "#1f77b4", 1.0),
                        (nan("CLeh"), "C_L da EH", "#2ca02c", 1.0), (nan("razaoCL"), "C_L/C_Lmax da meia asa mais carregada", "#d62728", 0.8)],
          "C_L (—)", "Coeficiente de sustentação", linhas=[(av["restricoes"]["kCL"], "limite (asa)", "#d62728", "--")])
    serie("11_CD.png", [(nan("CD"), "C_D total", "#000000", 1.5), (nan("CDi"), "C_Di induzido (com efeito solo)", "#1f77b4", 1.0),
                        (np.where(sv, T["CD"] - T["CDi"], np.nan), "C_D parasita (+ pós-estol)", "#7f7f7f", 1.0)],
          "C_D (—)", "Coeficiente de arrasto")
    for i, (ex, nm, lm) in enumerate([("L", "rolamento L", 8), ("M", "arfagem M", 15), ("N", "guinada N", 5)]):
        cur = [(T[ex + k], r, c, 0.8) for k, r, c in COMP] + [(T[ex + "t"], "total", "k", 1.4)]
        serie(f"{12 + i}_momento_{ex}.png", cur, f"{nm} no CG (N·m)", f"Momento de {nm}, parcela por parcela", ylim=(-lm, lm))
    serie("15_razao_subida.png", [(T["hdot"], "dh/dt", "#2ca02c", 1.2)], "razão de subida (m/s)", "Razão de subida e descida")
    serie("16_fator_carga.png", [(T["nz"], "n_z", "#d62728", 1.0)], "fator de carga (g)", "Fator de carga", ylim=(-0.5, 3))

    # entradas do sistema
    fig, ax = plt.subplots(figsize=(12, 4.5))
    fundo(ax, t, et)
    for k, r, c in [("de", "profundor δe", "#2ca02c"), ("da", "aileron δa", "#1f77b4"), ("dr", "leme δr", "#ff7f0e"),
                    ("dw", "bequilha δw", "#7f7f7f")]:
        ax.plot(t, T[k], color=c, lw=1.0, label=r)
    ax.set_xlabel("t (s)"); ax.set_ylabel("deflexão das superfícies (°)"); ax.set_ylim(-22, 22)
    ax2 = ax.twinx(); ax2.grid(False); ax2.plot(t, T["thr"], color="#d62728", lw=0.9, label="acelerador")
    ax2.set_ylabel("acelerador (0–1)"); ax2.set_ylim(-0.05, 1.6)
    ax.legend(loc="upper left", ncol=4); ax2.legend(loc="upper right"); ax.set_title("Entradas do sistema: superfícies e acelerador")
    salva(fig, png, "17_entradas.png")

    # decolagem: grafico unico (pista + inicio da subida), eixo comum = posicao na pista
    s = (SO["t"] <= ev["tHt"] + 4.0) if ev["tHt"] > 0 else np.ones_like(SO["t"], bool)
    D = {k: v[s] for k, v in SO.items()}
    x = D["n"]
    Rn, Rm, i2 = _artigo(D)
    fig, axs = plt.subplots(5, 1, figsize=(11, 13), sharex=True)
    a = axs[0]
    a.plot(x, D["h"] - D["h"][0], color="#d62728", lw=1.5, label="subida do CG")
    a.plot(x, D["htail"], color="#7f7f7f", lw=1.2, label="folga da cauda")
    a.axhline(av["escalares"]["ht"], color="k", ls=":", lw=0.8, label="h_t")
    a.set_ylabel("altura (m)"); a.legend(loc="upper left"); a.set_title("Decolagem: pista e início da subida")
    a = axs[1]
    a.plot(x, D["Va"], color="#d62728", label="V_a"); a.plot(x, D["Vg"], color="#1f77b4", label="V_g")
    a.axhline(resumo["Vs"], color="k", ls=":", lw=0.8, label="V_s"); a.axhline(1.2 * resumo["Vs"], color="k", ls="--", lw=0.8, label="1,2 V_s")
    a.set_ylabel("velocidade (m/s)"); a.legend(loc="upper left", ncol=4)
    a = axs[2]
    for k, r, c in [("theta", "θ", "#1f77b4"), ("alfa", "α", "#d62728"), ("gama", "γ", "#2ca02c")]:
        a.plot(x, D[k], color=c, label=r)
    a.axhline(resumo["alfa_estol"], color="#d62728", ls=":", lw=0.8, label="α de estol")
    a.axhline(resumo["theta_cauda"], color="#7f7f7f", ls="--", lw=0.8, label="θ que encosta a cauda")
    a.set_ylabel("ângulo (°)"); a.legend(loc="upper left", ncol=5)
    a = axs[3]
    a.plot(x, D["de"], color="#2ca02c", label="profundor δe"); a.plot(x, D["dw"], color="#7f7f7f", label="bequilha δw")
    a.plot(x, D["dr"], color="#ff7f0e", label="leme δr"); a.plot(x, D["da"], color="#1f77b4", label="aileron δa")
    a.set_ylabel("deflexão (°)")
    a2 = a.twinx(); a2.grid(False); a2.plot(x, D["thr"], color="#d62728", lw=0.9, label="acelerador"); a2.set_ylabel("acelerador (0–1)")
    a2.set_ylim(-0.05, 1.3)
    a.legend(loc="lower left", ncol=4); a2.legend(loc="lower right")
    a = axs[4]
    a.plot(x, D["TDN"], color="#ff7f0e", lw=2, label="TDN — molas")
    a.plot(x, D["TDP"], color="#1f77b4", lw=2, label="TDP — molas")
    a.plot(x, D["cauda"], color="#7f7f7f", lw=1.2, label="cauda — molas")
    a.plot(x[:i2 + 1], Rn[:i2 + 1], "--", color="#ff7f0e", label="TDN — artigo, eqs. (5)–(6)")
    a.plot(x[:i2 + 1], Rm[:i2 + 1], "--", color="#1f77b4", label="TDP — artigo, eqs. (5)–(6)")
    a.set_ylabel("reação normal (N)"); a.set_xlabel("n (m) — posição na pista"); a.legend(loc="upper right", ncol=2)
    marcas = [(resumo.get("sR", 0), "#2ca02c", "-.", "s_R: profundor aciona"), (ev["nRot"], "#ff7f0e", ":", "TDN sai do chão"),
              (ev["nLO"], "#1f77b4", ":", "TDP sai do chão (decolou)"), (ev["nHt"], "k", ":", "h_t: piloto automático")]
    for a in axs:
        for xx, cor, ls, _ in marcas:
            if xx > 0:
                a.axvline(xx, color=cor, ls=ls, lw=0.9)
    ymax = axs[0].get_ylim()[1]
    for xx, cor, ls, rot in marcas:
        if xx > 0:
            axs[0].text(xx, ymax, " " + rot, rotation=90, va="top", ha="right", fontsize=7, color=cor)
    salva(fig, png, "18_decolagem.png")

    # reacoes no pouso
    if ev.get("tTD", -1) > 0:
        s = t >= ev["tTD"] - 1.0
        D = {k: v[s] for k, v in T.items()}
        fig, ax = plt.subplots(figsize=(10, 4.5))
        ax.plot(D["n"], D["TDN"], color="#ff7f0e", lw=2, label="TDN — molas")
        ax.plot(D["n"], D["TDP"], color="#1f77b4", lw=2, label="TDP — molas")
        noch = (D["TDN"] > 0) | (D["TDP"] > 0)
        ax.plot(D["n"][noch], D["TDN_art"][noch], "--", color="#ff7f0e", label="TDN — artigo, eq. (5)")
        ax.plot(D["n"][noch], D["TDP_art"][noch], "--", color="#1f77b4", label="TDP — artigo, eq. (5)")
        ax.set_xlabel("n (m) — posição na pista"); ax.set_ylabel("reação normal (N)"); ax.legend()
        ax.set_title("Reações no TDN e no TDP no pouso (o artigo ignora a frenagem com o CG acima do chão)")
        salva(fig, png, "19_reacoes_pouso.png")

    # motor e energia
    fig, ax = plt.subplots(figsize=(12, 4.3)); fundo(ax, t, et)
    ax.plot(t, T["rpm"], color="#d62728", label="rotação"); ax.set_xlabel("t (s)"); ax.set_ylabel("rotação (rpm)")
    ax2 = ax.twinx(); ax2.grid(False); ax2.plot(t, T["Ibat"], color="#1f77b4", label="corrente"); ax2.set_ylabel("corrente da bateria (A)")
    ax.legend(loc="upper left"); ax2.legend(loc="upper right"); ax.set_title("Motor")
    salva(fig, png, "20_motor.png")
    serie("21_energia.png", [(T["E"], "energia", "#2ca02c", 1.4)], "energia da bateria (Wh)", "Energia gasta")
    serie("22_sloshing_angulos.png", [(T["ex"], "η_x (frente/trás)", "#1f77b4", 0.9), (T["ey"], "η_y (lados)", "#d62728", 0.9)],
          "ângulo do pêndulo (°)", "Sloshing: pêndulo equivalente do 1º modo")
    if semsl is not None:
        S2 = semsl["traj"]
        serie("23_sloshing_efeito.png", [(T["theta"] - np.interp(t, S2["t"], S2["theta"]), "Δθ", "#1f77b4", 0.9),
                                         (T["phi"] - np.interp(t, S2["t"], S2["phi"]), "Δφ", "#d62728", 0.9)],
              "diferença com − sem sloshing (°)", "Efeito do sloshing na atitude")

    # LAPES
    if ev.get("tdrop", -1) > 0:
        s = (t >= ev["tdrop"] - 1) & (t <= ev["tdrop"] + 5)
        tt = t[s] - ev["tdrop"]
        fig, ax = plt.subplots(figsize=(10, 4.2))
        ax.axvspan(0, ev["tsolto"] - ev["tdrop"], color=PAC, alpha=0.12)
        ax.plot(tt, T["xcg"][s], color="#1f77b4", label="x do CG"); ax.plot(tt, T["sL"][s] * 100, color=PAC, label="carga na baia")
        ax.set_xlabel("t − t_LAPES (s)"); ax.set_ylabel("posição (cm)")
        ax2 = ax.twinx(); ax2.grid(False); ax2.plot(tt, T["m"][s], color="#d62728", label="massa"); ax2.set_ylabel("massa (kg)")
        ax.legend(loc="upper left"); ax2.legend(loc="center right"); ax.set_title("LAPES: o CG anda para trás e depois a massa cai")
        salva(fig, png, "24_lapes_cg_massa.png")
        fig, ax = plt.subplots(figsize=(10, 4.2))
        ax.axvspan(0, ev["tsolto"] - ev["tdrop"], color=PAC, alpha=0.12)
        for k, r, c in [("theta", "θ (°)", "#1f77b4"), ("alfa", "α (°)", "#d62728"), ("q", "q (°/s)", "#ff7f0e"), ("de", "δe (°)", "#2ca02c")]:
            ax.plot(tt, T[k][s], color=c, label=r)
        ax.set_xlabel("t − t_LAPES (s)"); ax.set_ylabel("ângulo (°) / taxa (°/s)"); ax.legend(); ax.set_title("LAPES: resposta em arfagem")
        salva(fig, png, "25_lapes_arfagem.png")

    # rajada (trecho com rajada comparado com a missao)
    if raj is not None and raj["eventos"].get("tg", -1) > 0:
        G = raj["traj"]; tg = raj["eventos"]["tg"]
        s = (G["t"] >= tg - 0.5) & (G["t"] <= tg + 6)
        tt = G["t"][s] - tg
        d = lambda k: G[k][s] - np.interp(G["t"][s], t, T[k])
        fig, ax = plt.subplots(figsize=(10, 4.2))
        ax.axvspan(0, av["escalares"]["Tg"], color="#1f77b4", alpha=0.08)
        for k, r, c in [("alfa", "Δα", "#d62728"), ("beta", "Δβ", "#9467bd"), ("phi", "Δφ", "#ff7f0e"), ("theta", "Δθ", "#1f77b4")]:
            ax.plot(tt, d(k), color=c, label=r)
        ax.set_xlabel("t − t_rajada (s)"); ax.set_ylabel("diferença com − sem rajada (°)"); ax.legend(); ax.set_title("Rajada 3D: ângulos")
        salva(fig, png, "26_rajada_angulos.png")
        for ex, nm in [("L", "rolamento"), ("M", "arfagem"), ("N", "guinada")]:
            fig, ax = plt.subplots(figsize=(10, 4.2))
            ax.axvspan(0, av["escalares"]["Tg"], color="#1f77b4", alpha=0.08)
            for k, r, c in COMP[:5] + [("liq", "líquido", "#17becf"), ("t", "total", "k")]:
                ax.plot(tt, d(ex + k), color=c, lw=1.4 if k == "t" else 0.9, label=r)
            ax.set_xlabel("t − t_rajada (s)"); ax.set_ylabel(f"Δ{ex} com − sem rajada (N·m)"); ax.legend(ncol=2, fontsize=7)
            ax.set_title(f"Rajada 3D: momento de {nm}")
            salva(fig, png, f"27_rajada_momento_{ex}.png")


# ====================================================================== etapas
def etapas(png, linhas, Vs, kCL):
    nomes = [L["etapa"] for L in linhas]
    y = np.arange(len(nomes))

    def barras(nome, lo, me, hi, xlab, tit, linhas_v=()):
        fig, ax = plt.subplots(figsize=(10, 0.45 * len(nomes) + 1.6))
        for i in range(len(nomes)):
            ax.plot([lo[i], hi[i]], [i, i], color=CORES[i % len(CORES)], lw=7, solid_capstyle="butt", alpha=0.85)
            if me is not None:
                ax.plot(me[i], i, "k|", ms=13, mew=2)
        for v, r, c in linhas_v:
            ax.axvline(v, color=c, ls="--", lw=1, label=r)
        ax.set_yticks(y); ax.set_yticklabels(nomes); ax.invert_yaxis()
        ax.set_xlabel(xlab); ax.set_ylabel("etapa"); ax.set_title(tit)
        if linhas_v: ax.legend(fontsize=7)
        salva(fig, png, nome)
    g = lambda c: np.array([L[c] for L in linhas])
    z = np.zeros(len(nomes))
    barras("40_etapas_velocidade.png", g("Va_min"), g("Va_med"), g("Va_max"), "V_a (m/s): faixa e média (traço)",
           "Velocidade em cada etapa", [(Vs, "V_s", "k"), (1.2 * Vs, "1,2 V_s", "#7f7f7f")])
    barras("41_etapas_subida.png", -g("descida_max"), None, g("subida_max"), "dh/dt (m/s): da maior descida à maior subida",
           "Razões de subida e descida em cada etapa")
    barras("42_etapas_trajetoria.png", g("gama_min"), None, g("gama_max"), "γ (°): faixa", "Ângulo de trajetória em cada etapa")
    barras("43_etapas_inclinacao.png", z, None, g("phi_max"), "|φ| máximo (°)", "Inclinação em cada etapa")
    barras("44_etapas_fator_carga.png", g("nz_min"), None, g("nz_max"), "n_z (g): faixa", "Fator de carga em cada etapa")
    barras("45_etapas_CL.png", z, None, g("CL_CLmax_max"), "C_L/C_Lmax máximo da meia asa (—)", "Margem de estol em cada etapa",
           [(kCL, "limite", "#d62728")])
    barras("46_etapas_distancia.png", z, None, g("distancia"), "distância sobre o solo (m)", "Comprimento de cada etapa")


# ====================================================================== desempenho
def desempenho(png, D, resumo, curvas_sim=None):
    V = D["V"]
    okn = D["ok_n"] > 0
    okc = D["ok_c"] > 0
    okg = D["ok_g"] > 0
    W = resumo["massa"] * 9.80665
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(V[okn], D["D_n"][okn] * V[okn], color="#1f77b4", label="potência requerida D·V")
    Pdisp = (D["D_n"] + W * np.sin(np.radians(D["gam_max"]))) * V
    ax.plot(V[okc & okn], Pdisp[okc & okn], color="#d62728", label="potência disponível T·V (motor cheio)")
    ax.axvline(resumo["Vs"], color="k", ls=":", lw=0.8, label="V_s")
    ax.set_xlabel("V (m/s)"); ax.set_ylabel("potência útil (W)"); ax.legend(); ax.set_title("Potência requerida e disponível (voo nivelado)")
    salva(fig, png, "50_potencia.png")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(V[okc], D["gam_max"][okc], color="#d62728", label="γ máximo (motor cheio)")
    ax.plot(V[okg], D["gam_idle"][okg], color="#1f77b4", label="γ com motor cortado (planeio)")
    ax.axhline(0, color="k", lw=0.5); ax.axvline(resumo["Vs"], color="k", ls=":", lw=0.8, label="V_s")
    ax.set_xlabel("V (m/s)"); ax.set_ylabel("ângulo de trajetória γ (°)"); ax.legend(); ax.set_title("Ângulo de subida máximo e de descida")
    salva(fig, png, "51_gama_max.png")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(V[okc], D["roc_max"][okc], color="#d62728", label="razão de subida máxima")
    ax.plot(V[okg], D["roc_idle"][okg], color="#1f77b4", label="razão de descida em planeio")
    ax.axhline(0, color="k", lw=0.5)
    ax.set_xlabel("V (m/s)"); ax.set_ylabel("dh/dt (m/s)"); ax.legend(); ax.set_title("Razões de subida e descida")
    salva(fig, png, "52_razao_subida.png")
    fig, ax = plt.subplots(figsize=(9, 5))
    m1 = D["R_estol"] < 1e8; m2 = D["R_sust"] < 1e8
    ax.plot(V[m1], D["R_estol"][m1], color="#d62728", label="equilíbrio: asa em k·C_Lmax (estol)")
    ax.plot(V[m2], D["R_sust"][m2], color="#1f77b4", label="equilíbrio: motor cheio (curva sustentada)")
    if "R_op" in resumo:
        ax.plot(*resumo["R_op"], color="#ff7f0e", ls="--", label=f"equilíbrio: α do piloto = {resumo['alfa_op']:.0f}°")
    estilos = {"calmo_op": ("o", "#2ca02c"), "calmo_estol": ("s", "#d62728"), "vento_op": ("^", "#9467bd")}
    for chave, pts in (curvas_sim or {}).items():
        pts = [(v, r) for v, r, _ in pts if np.isfinite(r)]
        if pts:
            mk, c = estilos.get(chave, ("o", "k"))
            ax.plot(*zip(*pts), mk, color=c, ms=7, mfc="none" if "estol" in chave else c,
                    label="6GDL: " + {"calmo_op": "sem vento, α do piloto", "calmo_estol": "sem vento, α até k·C_Lmax",
                                      "vento_op": "com vento (raio no chão), α do piloto"}.get(chave, chave))
    ax.set_xlabel("V (m/s)"); ax.set_ylabel("raio de curva mínimo (m)"); ax.set_ylim(0, 80); ax.legend(fontsize=7)
    ax.set_title("Raio de curva mínimo: equilíbrio x simulação 6GDL (entrada na curva incluída)")
    salva(fig, png, "53_raio_minimo_V.png")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(V[okn], D["al_n"][okn], color="#d62728", label="α de equilíbrio")
    ax.plot(V[okn], D["de_n"][okn], color="#2ca02c", label="δe de equilíbrio")
    ax.set_xlabel("V (m/s)"); ax.set_ylabel("ângulo (°)")
    ax2 = ax.twinx(); ax2.grid(False); ax2.plot(V[okn], D["thr_n"][okn], color="#1f77b4", label="acelerador")
    ax2.axhline(1.0, color="#1f77b4", ls=":", lw=0.8); ax2.set_ylabel("acelerador para voo nivelado (0–1)")
    ax.legend(loc="upper left"); ax2.legend(loc="upper right"); ax.set_title("Equilíbrio em voo nivelado")
    salva(fig, png, "54_equilibrio.png")


# ====================================================================== decolagem
def decolagem(png, mapa, otim, resumo):
    fig, ax = plt.subplots(figsize=(9, 5.5))
    ok = mapa[:, 8] == 0
    sc = ax.scatter(mapa[ok, 0], mapa[ok, 1], c=mapa[ok, 2], cmap="viridis", marker="s", s=30)
    fig.colorbar(sc, ax=ax, label="corrida até sair do chão (m)")
    for b, mk, c, r in [(A.V_CAUDA, "x", "#d62728", "cauda a menos de 3 cm do chão"), (A.V_ESTOL, "o", "k", "C_L acima do limite (asa)"),
                        (A.V_Q, "^", "#ff7f0e", "|q| > 50 °/s"), (A.V_VSEG, "v", "#9467bd", "V < 1,2 V_s ou γ > 20° em h_t"),
                        (A.V_ANTES, "s", "#bcbd22", "sai do chão antes do comando"),
                        (A.V_NAOSOBE, ".", "#7f7f7f", "não chega a h_t"), (A.V_QUICA, "+", "#8c564b", "toca o chão de novo")]:
        s = (mapa[:, 8].astype(int) & b) > 0
        if s.any():
            ax.scatter(mapa[s, 0], mapa[s, 1], marker=mk, color=c, s=14, facecolors="none" if mk in "os" else None, lw=0.8, label=r)
    ax.plot(resumo["sR"], resumo["de1"], "*", ms=16, color="gold", mec="k", label="escolhida")
    ax.set_xlabel("distância de acionamento do profundor s_R (m)"); ax.set_ylabel("deflexão do profundor δe1 (°)")
    ax.set_title("Mapa de decolagem (massa e CG nominais)"); ax.legend(fontsize=7, loc="lower left")
    salva(fig, png, "60_mapa_decolagem.png")
    massas = np.unique(otim[:, 0])
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for i, m in enumerate(massas):
        s = otim[:, 0] == m
        ax.plot(otim[s, 1] * 100, otim[s, 4], "o-", color=CORES[1 + i], label=f"{m:.2f} kg: corrida")
        ax.plot(otim[s, 1] * 100, otim[s, 5], "s--", color=CORES[1 + i], alpha=0.6, label=f"{m:.2f} kg: até h_t")
    ax.set_xlabel("deslocamento do CG da aeronave seca x (cm, + para a frente)"); ax.set_ylabel("distância mínima (m)")
    ax.legend(fontsize=7, ncol=2); ax.set_title("Pista mínima (s_R e δe1 otimizados para cada CG e massa seca)")
    salva(fig, png, "61_pista_minima.png")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for i, m in enumerate(massas):
        s = otim[:, 0] == m
        ax.plot(otim[s, 1] * 100, otim[s, 2], "o-", color=CORES[1 + i], label=f"s_R — {m:.2f} kg")
    ax.set_xlabel("deslocamento do CG da aeronave seca x (cm)"); ax.set_ylabel("s_R ótimo (m)")
    ax2 = ax.twinx(); ax2.grid(False)
    for i, m in enumerate(massas):
        s = otim[:, 0] == m
        ax2.plot(otim[s, 1] * 100, otim[s, 3], "s--", color=CORES[1 + i], alpha=0.6, label=f"δe1 — {m:.2f} kg")
    ax2.set_ylabel("δe1 ótimo (°)")
    ax.legend(loc="upper left", fontsize=7); ax2.legend(loc="upper right", fontsize=7); ax.set_title("Comando ótimo de decolagem")
    salva(fig, png, "62_comando_otimo.png")


# ====================================================================== subida
def subida(png, sub, D, resumo):
    """sub: lista de analises.subida (varias V e gradientes pedidos)"""
    Vs_ = sorted(set(o["V"] for o in sub))
    cm = plt.cm.viridis
    fig, ax = plt.subplots(figsize=(9, 4.8))
    gmax = 0.0
    for i, V in enumerate(Vs_):
        os_ = sorted([o for o in sub if o["V"] == V], key=lambda o: o["gama_pedido"])
        gp = np.array([o["gama_pedido"] for o in os_]); gm = np.array([o["gama_med"] for o in os_])
        ok = np.array([o["viavel"] for o in os_]); c = cm(i / max(1, len(Vs_) - 1))
        ax.plot(gp, gm, "-", color=c, lw=1.2, label=f"V = {V:.1f} m/s")
        ax.plot(gp[ok], gm[ok], "o", color=c, ms=4)
        ax.plot(gp[~ok], gm[~ok], "x", color=c, ms=6)
        gmax = max(gmax, gp.max())
    ax.plot([0, gmax], [0, gmax], "k:", lw=0.8, label="seguiria exatamente")
    topo = max(4.0, 1.4 * max(o["gama_med"] for o in sub))
    gmin = resumo["gama_min_geo"]
    if gmin < topo:
        ax.axhline(gmin, color="#ff7f0e", ls="-.", lw=1, label=f"γ mínimo para chegar a h_c no fim da reta ({gmin:.0f}°)")
    else:
        ax.text(0.02, 0.95, f"γ mínimo para chegar a h_c no fim da reta de decolagem: {gmin:.0f}° (fora da escala —\n"
                f"o motor só sustenta ~{max(o['gama_med'] for o in sub if o['viavel']):.1f}°: a aeronave chega a h_c já na manobra 1)",
                transform=ax.transAxes, va="top", fontsize=7.5, color="#ff7f0e",
                bbox=dict(boxstyle="round", fc="white", ec="#ff7f0e"))
    ax.set_ylim(0, topo)
    ax.set_xlabel("γ pedido ao piloto (°)"); ax.set_ylabel("γ obtido em regime, no ar (°)")
    ax.legend(fontsize=7, ncol=2); ax.set_title("Subida: o γ obtido satura no máximo do motor (o = segura V, x = perde V)")
    salva(fig, png, "63_subida_gama.png")

    R = A.resumo_subida(sub)
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.3))
    okc = D["ok_c"] > 0; okg = D["ok_g"] > 0
    ax[0].plot(D["V"][okc], D["gam_max"][okc], color="#d62728", label="γ máximo (equilíbrio, motor cheio)")
    ax[0].plot(D["V"][okg], D["gam_idle"][okg], color="#1f77b4", label="γ mínimo: planeio com motor cortado")
    ax[0].plot([r["V"] for r in R], [r["gama_max"] for r in R], "ko", label="γ máximo na simulação 6GDL")
    ax[0].axhline(0, color="k", lw=0.5); ax[0].axvline(resumo["Vs"], color="k", ls=":", lw=0.8, label="V_s")
    ax[0].set_xlabel("V (m/s)"); ax[0].set_ylabel("γ (°)"); ax[0].legend(fontsize=7); ax[0].set_title("Ângulo de subida máximo e mínimo")
    ax[1].plot(D["V"][okc], D["roc_max"][okc], color="#d62728", label="razão de subida máxima (equilíbrio)")
    ax[1].plot(D["V"][okg], D["roc_idle"][okg], color="#1f77b4", label="razão de descida em planeio")
    ax[1].plot([r["V"] for r in R], [r["hdot_max"] for r in R], "ko", label="simulação 6GDL")
    ax[1].axhline(0, color="k", lw=0.5)
    ax[1].set_xlabel("V (m/s)"); ax[1].set_ylabel("dh/dt (m/s)"); ax[1].legend(fontsize=7); ax[1].set_title("Razão de subida")
    salva(fig, png, "64_subida_limites.png")

    fig, ax = plt.subplots(2, 1, figsize=(9, 6), sharex=True)
    V0 = Vs_[len(Vs_) // 2]
    os_ = sorted([o for o in sub if o["V"] == V0], key=lambda o: o["gama_pedido"])
    for i, o in enumerate(os_):
        T = o["traj"]; t = T["t"] - o["t0"]; c = plt.cm.plasma(i / max(1, len(os_) - 1))
        ax[0].plot(t, T["h"] - T["h"][0], color=c, lw=1, label=f"γ pedido {o['gama_pedido']:.1f}°")
        ax[1].plot(t, T["Va"], color=c, lw=1)
    ax[0].set_ylabel("altura ganha (m)"); ax[0].legend(fontsize=6.5, ncol=3)
    ax[1].axhline(V0, color="k", ls=":", lw=0.8)
    ax[1].set_xlabel("t desde o início da subida (s)"); ax[1].set_ylabel("V_a (m/s)")
    ax[0].set_title(f"Subida a V = {V0:.1f} m/s: pedir mais não sobe mais, só perde velocidade")
    salva(fig, png, "65_subida_tempo.png")


# ====================================================================== curvas
def curvas(png, casos, kCL, nome="66", titulo="", analitico=None, xy=None):
    """casos: {rotulo: (lista de analises.raio_minimo, R_min)}; uma figura agrupada:
    trajetorias xy (do caso `xy`), C_L/C_Lmax, inclinacao, fator de carga e altura perdida x R"""
    estilo = [("#2ca02c", "o"), ("#d62728", "s"), ("#9467bd", "^"), ("#1f77b4", "D")]
    xy = xy or list(casos)[0]
    fig = plt.figure(figsize=(13, 8.5))
    gsp = fig.add_gridspec(3, 2, width_ratios=[1.0, 1.25])
    ax0 = fig.add_subplot(gsp[:, 0])
    cur = sorted([o for o in casos[xy][0] if "razao_max" in o], key=lambda o: o["R"])
    for i, o in enumerate(cur):
        T = o["traj"]; c = plt.cm.plasma(i / max(1, len(cur) - 1))
        ax0.plot(T["e"], T["n"], color=c, lw=1.4 if o["ok"] else 0.9, ls="-" if o["ok"] else "--",
                 label=f"R = {o['R']:.0f} m — {o['motivo']}")
    ax0.set_aspect("equal", adjustable="datalim")
    ax0.set_xlabel("e (m)"); ax0.set_ylabel("n (m)"); ax0.legend(fontsize=6.3, loc="best")
    ax0.set_title(f"trajetórias — {xy} (tracejado = falha)", fontsize=9)
    paineis = [("razao_max", "C_L/C_Lmax máx. da meia asa", kCL, "CL"),
               ("phi_perm", "|φ| em regime (°)", None, "phi"),
               ("perda_h", "altura perdida (m)", 3.0, None)]
    axs = [fig.add_subplot(gsp[i, 1]) for i in range(3)]
    for ax, (chave, ylab, lim_, an) in zip(axs, paineis):
        for j, (rot, (lst, Rm)) in enumerate(casos.items()):
            c, mk = estilo[j % len(estilo)]
            L = sorted([o for o in lst if "razao_max" in o], key=lambda o: o["R"])
            R = np.array([o["R"] for o in L]); y = np.array([o[chave] for o in L], dtype=float)
            ok = np.array([o["ok"] for o in L])
            if chave == "phi_perm":
                y = np.minimum(y, 89.0)
            ax.plot(R, y, "-", color=c, lw=0.8, alpha=0.6)
            ax.plot(R[ok], y[ok], mk, color=c, ms=5, label=f"{rot} — passa (R_mín = {Rm:.0f} m)" if np.isfinite(Rm) else f"{rot} — passa")
            ax.plot(R[~ok], y[~ok], "x", color=c, ms=7)
            if np.isfinite(Rm):
                ax.axvline(Rm, color=c, ls=":", lw=1)
        if analitico is not None and an in analitico:
            ax.plot(analitico["R"], analitico[an], "k--", lw=0.9, label="equilíbrio (curva nivelada sem vento)")
        if lim_ is not None:
            ax.axhline(lim_, color="#d62728", ls="--", lw=0.9, label="limite")
        ax.set_ylabel(ylab)
        if chave == "razao_max":
            ax.set_ylim(0.4, 1.1)
        if chave == "phi_perm":
            ax.set_ylim(0, 90)
    axs[0].legend(fontsize=6.5, ncol=1, loc="upper right")
    axs[-1].set_xlabel("raio pedido R (m)   (x = falha)")
    fig.suptitle(titulo, fontsize=11)
    salva(fig, png, f"{nome}_curva.png")


# ====================================================================== LAPES
def lapes(png, hist, s_ot, alvo_n, M):
    fig, ax = plt.subplots(figsize=(9, 4.2))
    ax.plot(hist[:, 0], hist[:, 1], "o-", color=PAC, label="n do impacto da carga")
    ax.axhline(alvo_n, color="k", ls=":", lw=1, label="alvo")
    ax.axvline(s_ot, color="#2ca02c", ls="--", lw=1, label=f"lançamento escolhido: s = {s_ot:.1f} m")
    ax.set_xlabel("ponto de lançamento na passagem s (m)"); ax.set_ylabel("posição do impacto n (m)"); ax.legend()
    ax.set_title("LAPES controlado pelo Python: onde soltar para acertar o alvo")
    salva(fig, png, "70_lapes_alvo.png")
    T, PK, ev = M["traj"], M["pacote"], M["eventos"]
    if len(PK.get("t", [])) > 1:
        s = (T["t"] >= ev["tdrop"] - 2) & (T["t"] <= ev["tdrop"] + 4)
        fig, ax = plt.subplots(figsize=(9, 4.2))
        ax.plot(T["n"][s], T["h"][s], color="#9467bd", lw=1.6, label="aeronave (CG)")
        ax.plot(PK["n"], PK["h"], color=PAC, lw=2.5, label="carga com paraquedas")
        ax.plot(alvo_n, 0, "kv", ms=10, label="alvo")
        ax.set_xlabel("n (m)"); ax.set_ylabel("h (m)"); ax.legend(); ax.set_title("LAPES: aeronave e carga (plano xz)")
        salva(fig, png, "71_lapes_xz.png")


# ====================================================================== polar
def polar(png, pol, polb, T):
    sv = T["Va"] > 6
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(pol["alfa"], pol["CL"], color="k", lw=2, label="C_L estático (δe = 0)")
    ax.plot(pol["alfa"], pol["CLasa"], color="#1f77b4", label="asa"); ax.plot(pol["alfa"], pol["CLeh"], color="#2ca02c", label="EH")
    ax.plot(T["alfa"][sv], T["CL"][sv], ".", ms=1.5, color="#d62728", label="pontos da missão")
    ax.set_xlabel("α (°)"); ax.set_ylabel("C_L (—)"); ax.legend(); ax.set_title("Curva de sustentação da aeronave")
    salva(fig, png, "80_polar_CL.png")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for k, r, c in [("Cm_dem10", "δe = −10°", "#2ca02c"), ("Cm", "δe = 0", "k"), ("Cm_dep10", "δe = +10°", "#d62728")]:
        ax.plot(pol["alfa"], pol[k], color=c, label=r)
    ax.axhline(0, color="k", lw=0.5)
    ax.set_xlabel("α (°)"); ax.set_ylabel("C_m no CG (—)"); ax.legend(); ax.set_title("Momento de arfagem: estabilidade e controle")
    salva(fig, png, "81_polar_Cm.png")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for k, r, c in [("CY", "C_Y", "#9467bd"), ("Cl", "C_l", "#1f77b4"), ("Cn", "C_n", "#d62728")]:
        ax.plot(polb["beta"], polb[k], color=c, label=r)
    ax.set_xlabel("β (°)"); ax.set_ylabel("coeficiente (—)"); ax.legend(); ax.set_title("Látero-direcional estático (α = 4°)")
    salva(fig, png, "82_polar_beta.png")

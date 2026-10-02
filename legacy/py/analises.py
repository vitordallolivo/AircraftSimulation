"""Analises por etapa de voo, usando checkpoints do simulador em C.

    etapas(T, ev, nomes)                       indice de etapa por amostra
    tabela_etapas(T, ev, nomes, Vs)            desempenho de cada etapa (velocidades, razoes, pista...)
    varre_decolagem(...) / otimiza_decolagem(...)
    subida(...)                                angulo de subida maximo e minimo
    raio_minimo(...)                           raio de curva minimo (estol da asa)
    lapes_alvo(...)                            ponto de lancamento para a carga cair no alvo
"""
import csv
import math
import os
from concurrent.futures import ThreadPoolExecutor

import numpy as np

import percurso as P
import simulador as S

NW = os.cpu_count() or 2

# bits de violacao da decolagem
V_CAUDA, V_ESTOL, V_Q, V_VSEG, V_ANTES, V_NAOSOBE, V_QUICA = 1, 2, 4, 8, 16, 32, 64


def _pool(f, itens):
    with ThreadPoolExecutor(max_workers=NW) as ex:
        return list(ex.map(f, itens))


# ---------------------------------------------------------------- etapas
def etapas(T, ev):
    """0 = corrida no chao, 1..N = pernas, N+1 = rolagem depois do toque"""
    e = T["seg"].astype(int) + 1
    if ev.get("tLO", -1) > 0:
        e[T["t"] < ev["tLO"]] = 0
    if ev.get("tTD", -1) > 0:
        e[T["t"] >= ev["tTD"]] = int(T["seg"].max()) + 2
    return e


def nomes_etapas(nomes):
    return ["corrida no chão"] + list(nomes) + ["rolagem"]


def tabela_etapas(T, ev, nomes, Vs):
    et = etapas(T, ev)
    nm = nomes_etapas(nomes)
    t = T["t"]
    dt = np.gradient(t)
    chi = np.unwrap(np.radians(T["chi"]))
    chid = np.gradient(chi, t)
    linhas = []
    for k in range(len(nm)):
        s = et == k
        if s.sum() < 2:
            continue
        g = lambda c: T[c][s]
        dist = float(np.sum(g("Vg") * dt[s]))
        Rinst = np.abs(g("Vg") / np.where(np.abs(chid[s]) > 1e-3, chid[s], np.nan))
        voo = g("Va") > 4
        L = dict(
            etapa=nm[k], t_ini=t[s][0], t_fim=t[s][-1], duracao=t[s][-1] - t[s][0], distancia=dist,
            n_ini=g("n")[0], n_fim=g("n")[-1], h_min=g("h").min(), h_max=g("h").max(),
            Va_min=g("Va").min(), Va_med=g("Va").mean(), Va_max=g("Va").max(), Vg_med=g("Vg").mean(),
            Va_min_sobre_Vs=g("Va").min() / Vs,
            subida_max=g("hdot").max(), descida_max=-g("hdot").min(),
            gama_max=g("gama").max(), gama_min=g("gama").min(),
            phi_max=np.abs(g("phi")).max(), nz_max=g("nz").max(), nz_min=g("nz").min(),
            alfa_max=g("alfa")[voo].max() if voo.any() else 0.0,
            CL_CLmax_max=g("razaoCL")[voo].max() if voo.any() else 0.0,
            R_curva_mediano=float(np.nanmedian(Rinst)) if np.isfinite(Rinst).any() else float("nan"),
            acelerador_med=g("thr").mean(), energia_Wh=g("E")[-1] - g("E")[0],
        )
        linhas.append(L)
    return linhas


def salva_csv(linhas, caminho):
    if not linhas:
        return
    with open(caminho, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(linhas[0].keys()), delimiter=";")
        w.writeheader()
        for L in linhas:
            w.writerow({k: (f"{v:.4g}".replace(".", ",") if isinstance(v, float) else v) for k, v in L.items()})


# ---------------------------------------------------------------- decolagem
def viol_decolagem(e, Vs, r):
    v = 0
    if not e["completou"]: v |= V_NAOSOBE
    if e["hcmin"] < r["dmin"]: v |= V_CAUDA
    if e["razao_dec"] > r["kCL"]: v |= V_ESTOL
    if e["qpico_dec"] > r["qmax"]: v |= V_Q
    if e["VHt"] < 1.2 * Vs or e["gHt"] > r["gmax"]: v |= V_VSEG
    if e["tR"] < 0 or (e["tLO"] >= 0 and e["tLO"] < e["tR"]): v |= V_ANTES
    if e["quicou"]: v |= V_QUICA
    return v


def varre_decolagem(cfg, sRs, de1s, Vs, r, sobre=None):
    """grade de distancia de acionamento do profundor (sR) x deflexao (de1)"""
    casos = [(sr, de) for sr in sRs for de in de1s]

    def um(c):
        so = dict(sobre or {}); so.update(sR=c[0], de1=c[1])
        e = S.decolagem(cfg, so)
        return [c[0], c[1], e["nLO"] if e["tLO"] > 0 else -1, e["nHt"] if e["completou"] else -1,
                e["hcmin"], e["razao_dec"], e["qpico_dec"], e["VHt"], viol_decolagem(e, Vs, r)]
    return np.array(_pool(um, casos))


def otimiza_decolagem(cfg, xcgs, massas, sRs, de1s, Vs_de_m, r, objetivo=2):
    """para cada (x_CG da aeronave seca, massa seca) acha (sR, de1) de menor pista.
    objetivo: coluna do mapa (2 = distancia ate sair do chao, 3 = ate h_t)."""
    res = []
    for m in massas:
        for x in xcgs:
            M = varre_decolagem(cfg, sRs, de1s, Vs_de_m(m), r, sobre={"m_seca": m, "r_seca": (x, 0.0, 0.0)})
            ok = (M[:, 8] == 0) & (M[:, objetivo] > 0)
            if ok.any():
                i = np.argmin(np.where(ok, M[:, objetivo], 1e9))
                res.append([m, x, M[i, 0], M[i, 1], M[i, 2], M[i, 3], ok.sum()])
            else:
                res.append([m, x, np.nan, np.nan, np.nan, np.nan, 0])
    return np.array(res)          # m, x, sR, de1, nLO, DTO, n_viaveis


# ---------------------------------------------------------------- checkpoints
def trecho(cfg, pasta, nome, sobre=None, carrega=None, salva=None):
    pref = os.path.join(pasta, nome)
    return S.roda("missao", cfg, pref, sobre, carrega=carrega, salva=salva)


# ---------------------------------------------------------------- subida
def subida(av, pasta, Vs, r, Vlist, gradientes, h0=15.0, janela=(5.0, 20.0), vento=False):
    """subida em regime: para cada V, voa nivelado ate estabilizar (checkpoint) e
    depois pede gradientes de subida cada vez maiores na mesma velocidade.
    O piloto da prioridade a velocidade (Kvs), entao o gama obtido satura no
    maximo que o motor sustenta. Medido no ar (sem vento, por padrao)."""
    sob = {} if vento else {"Vw10": 0.0}
    res = []
    for V in Vlist:
        pernas = [P.reta(600.0, h=h0, V=V, nome="nivelado", decolagem=1),
                  P.reta(2000.0, h=h0 + 300.0, V=V, nome="subida")]
        pc = P.monta(pernas, h0=h0, V0=V)
        cfg = os.path.join(pasta, f"subida_V{V:.1f}.cfg")
        S.escreve_cfg(av, pc, cfg)
        ck = os.path.join(pasta, f"subida_V{V:.1f}.ckpt")
        tck = trecho(cfg, pasta, f"subida_V{V:.1f}_niv", dict(sob, para_seg=1), salva=ck)["eventos"]["tfim"]

        def um(g, V=V, cfg=cfg, ck=ck, tck=tck):
            T = trecho(cfg, pasta, f"subida_V{V:.1f}_g{g:.3f}", dict(sob, g_sobe=g, para_t=tck + janela[1]),
                       carrega=ck)["traj"]
            m = (T["t"] >= tck + janela[0]) & (T["t"] <= tck + janela[1])
            gam = np.degrees(np.arcsin(np.clip(T["hdot"][m] / T["Va"][m], -1, 1)))     # gama no ar
            return dict(V=V, g_pedido=g, gama_pedido=math.degrees(math.atan(g)), gama_med=float(np.mean(gam)),
                        hdot_med=float(np.mean(T["hdot"][m])), Va_med=float(np.mean(T["Va"][m])),
                        Va_min=float(T["Va"][m].min()), razao_max=float(T["razaoCL"][m].max()),
                        thr_med=float(np.mean(T["thr"][m])), alfa_med=float(np.mean(T["alfa"][m])),
                        theta_med=float(np.mean(T["theta"][m])), t0=tck, traj=T)
        out = _pool(um, list(gradientes))
        for o in out:
            # consegue: segura a velocidade (ate 0,7 m/s abaixo), longe do estol e faz >= 90 % do pedido
            o["segue"] = o["gama_med"] >= 0.9 * o["gama_pedido"]
            o["viavel"] = (o["Va_med"] >= V - 0.7) and (o["Va_min"] >= 1.1 * Vs) and (o["razao_max"] <= r["kCL"])
        res += out
    return res


def resumo_subida(sub):
    """por velocidade: gama maximo obtido (saturacao) e o maior pedido que ainda e seguido"""
    out = []
    for V in sorted(set(o["V"] for o in sub)):
        os_ = [o for o in sub if o["V"] == V]
        via = [o for o in os_ if o["viavel"]]
        seg = [o for o in via if o["segue"]]
        out.append(dict(V=V, gama_max=max((o["gama_med"] for o in via), default=float("nan")),
                        hdot_max=max((o["hdot_med"] for o in via), default=float("nan")),
                        gama_seguido=max((o["gama_pedido"] for o in seg), default=float("nan"))))
    return out


# ---------------------------------------------------------------- curvas
def _avalia_curva(T, sg, k, R, Vref, Vs, r, phimax, alfa_prot):
    """metricas de uma curva: transitorio inteiro e parte permanente (depois de 90 graus)"""
    s = T["seg"] == k
    if s.sum() < 5:
        return dict(R=R, V=Vref, ok=False, motivo="não chegou à curva")
    dts = np.gradient(T["t"])
    perm = s & (T["s"] >= R * math.pi / 2)                  # depois do primeiro quarto de volta
    if perm.sum() < 5:
        perm = s
    d = np.hypot(T["n"] - sg["cn"], T["e"] - sg["ce"])
    o = dict(R=R, V=Vref,
             razao_max=float(T["razaoCL"][s].max()), phi_max=float(np.abs(T["phi"][s]).max()),
             phi_perm=float(np.median(np.abs(T["phi"][perm]))), nz_max=float(T["nz"][s].max()),
             nz_perm=float(np.median(T["nz"][perm])), Va_min=float(T["Va"][s].min()),
             alfa_max=float(T["alfa"][s].max()), alfa_perm=float(np.median(T["alfa"][perm])),
             razao_perm=float(np.median(T["razaoCL"][perm])),
             perda_h=float(T["h"][s][0] - T["h"][s].min()),
             hdot_perm=float(np.mean(T["hdot"][perm])),
             erro_max=float(np.abs(T["ect"][s]).max()),
             erro_p90=float(np.percentile(np.abs(T["ect"][perm]), 90)),
             R_real=float(np.median(d[perm])),
             t_estol=float(np.sum(dts[s & (T["razaoCL"] > r["kCL"])])),
             t_alim=float(np.sum(dts[s & (T["alim"] > 0.5)])))
    tol = max(3.0, 0.15 * R)
    o["estol"] = o["t_estol"] > 0.3
    o["segue"] = (o["erro_p90"] <= tol) and (abs(o["R_real"] - R) <= tol)
    o["altura"] = (o["perda_h"] <= 3.0) and (o["hdot_perm"] > -0.5)
    o["controle"] = (o["phi_max"] <= phimax + 15.0) and (T["h"][s].min() > 0.5) and (o["Va_min"] > 0.9 * Vs)
    o["limite"] = o["t_alim"] > 0.3          # protecao de alfa do piloto segurou o profundor
    o["ok"] = o["controle"] and (not o["estol"]) and o["segue"] and o["altura"]
    if o["ok"]:
        o["motivo"] = "ok"
    elif not o["controle"]:
        o["motivo"] = "perda de controle"
    elif o["estol"]:
        o["motivo"] = "estol da asa"
    elif o["limite"]:
        o["motivo"] = "asa no limite de α"
    else:
        o["motivo"] = "não segue o raio" if not o["segue"] else "perde altura"
    return o


def _rmin(out):
    """o raio minimo e o menor raio a partir do qual TODOS os maiores tambem passam"""
    ordem = sorted(out, key=lambda o: o["R"])
    for i, o in enumerate(ordem):
        if all(p["ok"] for p in ordem[i:]):
            return o["R"]
    return float("nan")


def raio_minimo(av, perc, pasta, k, Rs, ckpt, t_ck, Vs, r, V=None, phimax=75.0, rotulo="R",
                alfa_lim=None, sobre=None, ang=None):
    """roda so a curva k a partir de um checkpoint no inicio dela, para cada raio.
    Inclinacao liberada ate phimax (o piloto ainda limita por n_max da asa).
    alfa_lim: alfa (graus) da protecao do piloto -- com o alfa de k*CLmax a asa
    pode chegar ao estol; sem ele vale o alfa_max da aeronave (operacional).
    ang: angulo da curva (360 para ter regime permanente); sobre: outras sobrescritas."""
    def um(R):
        mud = dict(R=R)
        if ang is not None:
            mud["ang"] = ang
        if V is not None:
            mud["V"] = V
        p2 = P.altera(perc, k, **mud)
        tag = f"{rotulo}_{R:.1f}" + (f"_V{V:.1f}" if V is not None else "")
        cfg = os.path.join(pasta, f"curva_{tag}.cfg")
        S.escreve_cfg(av, p2, cfg)
        sg = p2["segmentos"][k]
        Vref = sg["V1"]
        sob = {"para_seg": k + 1, "phimax": phimax, "tmax": t_ck + 30.0 + 3.0 * sg["L"] / Vref}
        if alfa_lim is not None:
            sob["alfa_max"] = alfa_lim
        sob.update(sobre or {})
        T = trecho(cfg, pasta, f"curva_{tag}", sob, carrega=ckpt)["traj"]
        o = _avalia_curva(T, sg, k, R, Vref, Vs, r, phimax, alfa_lim)
        o["traj"] = T; o["sg"] = sg
        return o
    out = _pool(um, list(Rs))
    return out, _rmin(out)


def checkpoint_nivelado(av, perc, pasta, V, nome, ckA=None, reta=600.0, sobre=None):
    """voa a perna 0 esticada (reta longa na velocidade V) ate estabilizar e guarda
    o estado no inicio da perna 1. Com ckA continua do checkpoint de h_t."""
    p2 = P.altera(perc, 0, L=reta, V=V)
    p2 = P.altera(p2, 1, V=V)
    cfg = os.path.join(pasta, f"{nome}.cfg")
    S.escreve_cfg(av, p2, cfg)
    ck = os.path.join(pasta, f"{nome}.ckpt")
    R = trecho(cfg, pasta, nome, dict({"para_seg": 1}, **(sobre or {})), carrega=ckA, salva=ck)
    return p2, ck, R["eventos"]["tfim"]


def curva_nivelada(av, perc, pasta, V, Rs, Vs, r, ckA=None, vento=True, alfa_lim=None, rotulo="N"):
    """raio minimo em regime permanente: reta longa em V, depois 240 graus de curva
    (o primeiro quarto e o transitorio de entrada, o resto e avaliado como permanente)"""
    sob = None if vento else {"Vw10": 0.0}
    nome = f"nivel_{rotulo}_V{V:.1f}" + ("" if vento else "_calmo")
    p2, ck, tck = checkpoint_nivelado(av, perc, pasta, V, nome, ckA=ckA if vento else None, sobre=sob)
    return raio_minimo(av, p2, pasta, 1, Rs, ck, tck, Vs, r, rotulo=nome, alfa_lim=alfa_lim, sobre=sob, ang=240.0)


# ---------------------------------------------------------------- LAPES
def lapes_alvo(av, perc, pasta, ckpt, k, alvo_n=0.0, s_lo=None, s_hi=None, iters=12):
    """acha a distancia s (dentro da perna k) de lancamento para a carga cair em n = alvo_n"""
    sg = perc["segmentos"][k]
    s_lo = 0.0 if s_lo is None else s_lo
    s_hi = sg["L"] if s_hi is None else s_hi
    ev_base = [e for e in perc["eventos"] if e["tipo"] != "lapes"]
    hist = []

    def roda(sx):
        p2 = P.com_eventos(perc, ev_base + [P.evento("lapes", k, sx)])
        cfg = os.path.join(pasta, f"lapes_{sx:.2f}.cfg")
        S.escreve_cfg(av, p2, cfg)
        R = trecho(cfg, pasta, f"lapes_{sx:.2f}", {"para_seg": k + 1}, carrega=ckpt)
        e = R["eventos"]
        hist.append((sx, e["pk_n"], e["pk_e"], e["hdrop"], e["ndrop"]))
        return e["pk_n"] - alvo_n, R
    # varredura grossa para mostrar a relacao s -> ponto de impacto
    _pool(lambda sx: roda(sx), list(np.linspace(s_lo, s_hi, 7)))
    a, b = s_lo, s_hi
    fa = roda(a)[0]
    for _ in range(iters):
        m = 0.5 * (a + b)
        fm = roda(m)[0]
        if (fm > 0) == (fa > 0):
            a, fa = m, fm
        else:
            b = m
    s_ot = 0.5 * (a + b)
    hist.sort()
    return s_ot, np.array(hist)

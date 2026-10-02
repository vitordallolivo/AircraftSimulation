#!/usr/bin/env python3
"""Roda tudo: aeronave + percurso -> simulador em C (com checkpoints) -> analises -> graficos.

    python3 rodar.py [pasta_saida] [--rapido]

Etapas:
  1. polar estatica e pontos de desempenho (C)
  2. decolagem: mapa s_R x de1 e pista minima variando x_CG e massa
  3. missao em trechos, guardando checkpoints:
       A = piloto automatico liga (h_t), B = inicio da manobra 1, C = inicio da passagem LAPES
  4. LAPES (a partir de C): o Python escolhe onde soltar para acertar o alvo e termina a missao
  5. variantes: sem sloshing e com rajada (a partir de B)
  6. subida em regime (checkpoint nivelado em cada V): angulo maximo; minimo geometrico
  7. curva: raio minimo em curva nivelada (varias V, com/sem vento, alfa do piloto ou ate
     k*CLmax) e na manobra 1 da missao (a partir de B)
  8. tabela por etapa (CSV) e graficos
"""
import argparse
import json
import math
import os
import warnings

import numpy as np

import aeronave
import analises as A
import graficos as G
import percurso as P
import simulador as S

warnings.filterwarnings("ignore")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("saida", nargs="?", default="saida")
    ap.add_argument("--rapido", action="store_true", help="grades menores")
    arg = ap.parse_args()
    pasta = os.path.abspath(arg.saida)
    tmp = os.path.join(pasta, "trechos"); png = os.path.join(pasta, "png")
    for d in (pasta, tmp, png):
        os.makedirs(d, exist_ok=True)
    S.compila()

    av = aeronave.padrao()
    pc = P.circuito()
    r = av["restricoes"]
    cfg = os.path.join(pasta, "aeronave.cfg")
    S.escreve_cfg(av, pc, cfg)

    # ---------------- 1) polar e desempenho ----------------
    pol, polb, info = S.roda("polar", cfg, os.path.join(tmp, "pol"))
    s = (pol["alfa"] >= -2) & (pol["alfa"] <= 8)
    CLa, CL0 = np.polyfit(np.radians(pol["alfa"][s]), pol["CL"][s], 1)
    dCm = np.polyfit(pol["CL"][s], pol["Cm"][s], 1)[0]
    CLmax = float(pol["CL"].max())
    av["escalares"].update(ap_CL0=float(CL0), ap_CLa=float(CLa))
    S.escreve_cfg(av, pc, cfg)
    g, rho, Sref = 9.80665, av["escalares"]["rho"], av["escalares"]["Sref"]
    m_carga = info["massa"] - av["escalares"]["m_seca"]
    Vs_de = lambda ms: math.sqrt(2 * (ms + m_carga) * g / (rho * Sref * CLmax))
    Vs = Vs_de(av["escalares"]["m_seca"])
    ct = av["contatos"]; tdp = [c for c in ct if c["tipo"] == 1][0]; cda = [c for c in ct if c["tipo"] == 2][0]
    resumo = dict(CL0=CL0, CLa=CLa, margem=-dCm, CLmax=CLmax, Vs=Vs, massa=info["massa"],
                  alfa_estol=float(pol["alfa"][np.argmax(pol["CL"])]),
                  theta_cauda=math.degrees(math.atan2(tdp["z"] - cda["z"], tdp["x"] - cda["x"])),
                  Vc=pc["segmentos"][2]["V1"], kCL=r["kCL"])
    print(f"C_L0 = {CL0:.3f}, C_La = {CLa:.3f}/rad, margem estatica = {-dCm * 100:.1f} %, "
          f"C_Lmax = {CLmax:.3f}, Vs = {Vs:.2f} m/s, massa = {info['massa']:.2f} kg")
    D, _ = S.roda("desempenho", cfg, os.path.join(tmp, "des"))

    # ---------------- 2) decolagem ----------------
    passo = 2 if arg.rapido else 1
    sRs = np.arange(20.0, 55.1, 2.5 * passo)
    de1s = np.arange(-12.0, 0.1, 1.0 * passo)
    mapa = A.varre_decolagem(cfg, sRs, de1s, Vs, r)
    ok = (mapa[:, 8] == 0) & (mapa[:, 2] > 0)
    i = int(np.argmin(np.where(ok, mapa[:, 2], 1e9)))
    sR, de1 = float(mapa[i, 0]), float(mapa[i, 1])
    print(f"decolagem: s_R = {sR} m, de1 = {de1} graus -> sai do chao em {mapa[i, 2]:.1f} m, h_t em {mapa[i, 3]:.1f} m")
    m0 = av["escalares"]["m_seca"]
    otim = A.otimiza_decolagem(cfg, xcgs=[-0.04, -0.02, 0.0, 0.02, 0.04], massas=[m0 - 0.6, m0, m0 + 0.6],
                               sRs=np.arange(20.0, 55.1, 5.0), de1s=np.arange(-12.0, 0.1, 2.0), Vs_de_m=Vs_de, r=r)
    np.savetxt(os.path.join(pasta, "decolagem_mapa.dat"), mapa, header="sR de1 nLO DTO hcmin razaoCL qpico VHt viol",
               comments="", fmt="%.5g")
    np.savetxt(os.path.join(pasta, "decolagem_otima.dat"), otim, header="m_seca x_cg sR de1 nLO DTO n_viaveis",
               comments="", fmt="%.5g")
    av["escalares"].update(sR=sR, de1=de1)
    resumo.update(sR=sR, de1=de1)
    S.escreve_cfg(av, pc, cfg)

    # ---------------- 3) missao em trechos com checkpoints ----------------
    ckA, ckB, ckC = (os.path.join(tmp, n) for n in ("A_ht.ckpt", "B_manobra1.ckpt", "C_lapes.ckpt"))
    m1 = A.trecho(cfg, tmp, "m1", {"para_autop": 1}, salva=ckA)
    m2 = A.trecho(cfg, tmp, "m2", {"para_seg": 1}, carrega=ckA, salva=ckB)
    m3 = A.trecho(cfg, tmp, "m3", {"para_seg": 4}, carrega=ckB, salva=ckC)
    tA, tB = m1["eventos"]["tfim"], m2["eventos"]["tfim"]

    # ---------------- 4) LAPES controlado pelo Python ----------------
    alvo_n = 0.0
    s_ot, hist = A.lapes_alvo(av, pc, tmp, ckC, 4, alvo_n=alvo_n, s_lo=120.0, s_hi=200.0, iters=8 if arg.rapido else 12)
    eventos = [e for e in pc["eventos"] if e["tipo"] != "lapes"] + [P.evento("lapes", 4, s_ot)]
    pcF = P.com_eventos(pc, eventos)
    cfgF = os.path.join(pasta, "missao_final.cfg")
    S.escreve_cfg(av, pcF, cfgF)
    m4 = A.trecho(cfgF, tmp, "m4", carrega=ckC)
    M = S.junta(S.junta(S.junta(m1, m2), m3), m4)
    print(f"LAPES: soltar em s = {s_ot:.1f} m -> carga cai em n = {M['eventos']['pk_n']:.2f} m (alvo {alvo_n})")

    # ---------------- 5) variantes ----------------
    semsl = A.trecho(cfgF, tmp, "semslosh", {"slosh": 0})
    raj = A.trecho(cfgF, tmp, "rajada", {"rajada": 1, "para_seg": 4}, carrega=ckB)

    # ---------------- 6) subida ----------------
    # regime: nivelado em V (checkpoint), depois pede gradientes crescentes
    Vsub = [12.0, 14.0, 16.0] if arg.rapido else [12.0, 13.0, 14.0, 15.0, 16.0, 17.0]
    grads = np.arange(0.01, 0.161, 0.02 if arg.rapido else 0.01)
    sub = A.subida(av, tmp, Vs, r, Vsub, grads)
    Rsub = A.resumo_subida(sub)
    sg0 = pc["segmentos"][0]
    hA = float(m1["traj"]["h"][-1])
    resumo["gama_min_geo"] = math.degrees(math.atan2(sg0["h1"] - hA, sg0["L"] - m1["eventos"]["nHt"]))
    best = max(Rsub, key=lambda o: o["gama_max"] if np.isfinite(o["gama_max"]) else -1)
    resumo.update(gama_max_sim=best["gama_max"], V_gama_max=best["V"], subida_V=Rsub)
    T = M["traj"]; acima = np.where((T["h"] >= sg0["h1"] - 0.5) & (T["t"] > M["eventos"]["tHt"]))[0]
    resumo["n_chega_hc"] = float(np.hypot(T["n"][acima[0]], T["e"][acima[0]])) if len(acima) else float("nan")
    print(f"subida: gama maximo {best['gama_max']:.1f} graus a {best['V']:.0f} m/s; "
          f"para chegar a {sg0['h1']:.0f} m no fim da reta seria preciso {resumo['gama_min_geo']:.0f} graus")

    # ---------------- 7) curvas: raio minimo ----------------
    al_op = av["escalares"]["alfa_max"]
    al_k = math.degrees((r["kCL"] * CLmax - CL0) / CLa)          # alfa em que a asa chega a k*CLmax
    Vv = np.linspace(9.0, 22.0, 131)
    n_op = 0.5 * rho * Vv ** 2 * Sref * (CL0 + CLa * math.radians(al_op)) / (info["massa"] * g)
    R_op = np.where(n_op > 1.0, Vv ** 2 / (g * np.sqrt(np.maximum(n_op ** 2 - 1.0, 1e-9))), np.nan)
    resumo.update(alfa_op=al_op, alfa_kCL=al_k, R_op=(Vv.tolist(), R_op.tolist()))
    base = [12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 33, 36, 40, 45, 50, 60, 70] if not arg.rapido else [12, 16, 20, 24, 28, 33, 40, 50, 60]
    Vc_l = [13.0, 15.0, 17.0] if arg.rapido else [12.5, 13.5, 15.0, 16.5, 18.0]
    casos = {"calmo_op": dict(vento=False, alfa_lim=None), "calmo_estol": dict(vento=False, alfa_lim=al_k),
             "vento_op": dict(vento=True, alfa_lim=None)}
    curvas_V = {k: [] for k in casos}
    cur15 = {}
    for V in Vc_l:
        Rs_V = sorted(set(int(round(R * (V / 15.0) ** 2)) for R in base))
        for chave, kw in casos.items():
            cur, Rm = A.curva_nivelada(av, pc, tmp, V, Rs_V, Vs, r, ckA=ckA, rotulo=chave, **kw)
            curvas_V[chave].append((V, Rm, [{k: v for k, v in o.items() if k not in ("traj", "sg")} for o in cur]))
            if abs(V - resumo["Vc"]) < 0.01:
                cur15[chave] = (cur, Rm)
            print(f"   curva nivelada V = {V:5.1f} m/s  {chave:12s} -> R minimo {Rm} m")
    # a curva da missao (manobra 1) como ela acontece: a partir do checkpoint B, com vento
    curM, RminM = A.raio_minimo(av, pc, tmp, 1, base, ckB, tB, Vs, r)
    print(f"curva da missao (manobra 1, a partir de B): raio minimo = {RminM} m")
    resumo.update(Rmin=RminM, Rmin_V={k: [(v, rm) for v, rm, _ in l] for k, l in curvas_V.items()}, s_lapes=s_ot)
    linhas_c = []
    for chave, l in curvas_V.items():
        for V, Rm, cur in l:
            for o in cur:
                if "razao_max" in o:
                    linhas_c.append(dict(caso=chave, V=V, R=o["R"], R_min=Rm, motivo=o["motivo"], phi_perm=o["phi_perm"],
                                         nz_perm=o["nz_perm"], alfa_perm=o["alfa_perm"], razao_max=o["razao_max"],
                                         razao_perm=o["razao_perm"], perda_h=o["perda_h"], R_real=o["R_real"]))
    A.salva_csv(linhas_c, os.path.join(pasta, "curvas_raio_minimo.csv"))
    A.salva_csv([{k: v for k, v in o.items() if k != "traj"} for o in sub], os.path.join(pasta, "subida.csv"))
    # equilibrio da curva nivelada (sem vento) para comparar com a varredura em 15 m/s
    Rr = np.linspace(8, 60, 200); Vc = resumo["Vc"]
    phi_eq = np.degrees(np.arctan(Vc ** 2 / (g * Rr))); nz_eq = 1 / np.cos(np.radians(phi_eq))
    CL_eq = nz_eq * info["massa"] * g / (0.5 * rho * Vc ** 2 * Sref)
    analit = dict(R=Rr, phi=phi_eq, nz=nz_eq, CL=CL_eq / CLmax)

    # ---------------- 8) tabela por etapa e graficos ----------------
    T, ev = M["traj"], M["eventos"]
    linhas = A.tabela_etapas(T, ev, pc["nomes"], Vs)
    A.salva_csv(linhas, os.path.join(pasta, "desempenho_por_etapa.csv"))
    print(f"\n{'etapa':22s} {'dist':>7s} {'Va min':>7s} {'Va max':>7s} {'sobe':>6s} {'desce':>6s} {'phi':>5s} {'nz':>5s} {'CL/max':>6s}")
    for L in linhas:
        print(f"{L['etapa']:22s} {L['distancia']:7.1f} {L['Va_min']:7.2f} {L['Va_max']:7.2f} {L['subida_max']:6.2f} "
              f"{L['descida_max']:6.2f} {L['phi_max']:5.1f} {L['nz_max']:5.2f} {L['CL_CLmax_max']:6.2f}")
    G.missao(png, M, pc["nomes"], av, resumo, semsl=semsl, raj=raj)
    G.etapas(png, linhas, Vs, r["kCL"])
    G.desempenho(png, D, resumo, curvas_sim=curvas_V)
    G.decolagem(png, mapa, otim, resumo)
    G.subida(png, sub, D, resumo)
    nomes_c = {"calmo_op": f"sem vento, α ≤ {al_op:.0f}° (piloto)", "calmo_estol": f"sem vento, α ≤ {al_k:.1f}° (k·C_Lmax)",
               "vento_op": f"com vento, α ≤ {al_op:.0f}°"}
    if cur15:
        G.curvas(png, {nomes_c[k]: v for k, v in cur15.items()}, r["kCL"], nome="66",
                 titulo=f"Curva nivelada de 240° a {resumo['Vc']:.0f} m/s: raio mínimo antes do estol da asa",
                 analitico=analit, xy=nomes_c["calmo_estol"])
    G.curvas(png, {"manobra 1 (com vento)": (curM, RminM)}, r["kCL"], nome="67",
             titulo="Manobra 1 da missão (180°, subindo, a partir do checkpoint B): raio mínimo")
    G.lapes(png, hist, s_ot, alvo_n, M)
    G.polar(png, pol, polb, T)
    resumo["eventos"] = ev
    resumo["curvas_V"] = curvas_V
    resumo["etapas"] = linhas
    json.dump(resumo, open(os.path.join(pasta, "resumo.json"), "w"), indent=1, default=float)
    print("\nok:", png)


if __name__ == "__main__":
    main()

"""Cada etapa como um `SimResult` (séries, resumo, diagnóstico) e os gráficos dela (`PlotSpec`): a GUI
desenha igual às outras abas, sem conhecer as contas.

    airfoil_stage(projeto)                 → (gráficos, resultado)
    wing_stage(asa, requisitos, regras)
    set_stage(conjunto, requisitos, regras, perfis)
    aircraft_stage(avião, requisitos, regras, catálogo, backend)   → também devolve o Aircraft montado
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import Check, PlotSpec, SimResult

from . import airfoils as afm
from . import power as pw
from . import registry as rg
from . import tail as tl
from . import wing as wg

OK, ATT, FAIL, INFO = "ok", "atencao", "falha", "info"


def _chk(status, item, value, crit, why="", fix="", group="", source=""):
    return Check(status, item, value, crit, why, fix, group, source=source)


def constraint_checks(req, values: dict, stage: str, group: str, fixes: dict | None = None) -> list[Check]:
    """uma linha por restrição ativa que esta etapa responde (o resto fica para a etapa que calcula)"""
    out = []
    for c, ok, txt in rg.checks(req.constraints, values, stage):
        q = c.quantity
        out.append(_chk(OK if ok else FAIL, f"restrição: {q.label}", txt.split(f" {c.op} ")[0] + f" {q.unit}".rstrip(),
                        f"{c.op} {rg.fmt(c.value)} {q.unit}".strip(), "" if ok else "não cumpre a restrição ativa",
                        "" if ok else (fixes or {}).get(c.key, q.fix), group, source="restrições (Condições e restrições…)"))
    return out


# ------------------------------------------------------------------ Perfil
AIRFOIL_PLOTS = [
    PlotSpec("cl", "c_l × α", "alpha", ("cl",), "α (°)", "c_l", live=False, source="series:pol_*"),
    PlotSpec("polar", "Polar c_l × c_d", "cd", ("cl",), "c_d", "c_l", live=False, source="series:pol_*"),
    PlotSpec("ld", "Eficiência c_l/c_d × α", "alpha", ("ld",), "α (°)", "c_l/c_d", live=False, source="series:pol_*"),
    PlotSpec("cm", "c_m × α", "alpha", ("cm",), "α (°)", "c_m", live=False, source="series:pol_*"),
]
CONTOUR_PLOT = PlotSpec("shape", "Contorno", "x", ("y",), "x/c", "y/c", live=False, source="series:shape_*",
                        aspect=True, height=220)


def airfoil_stage(entries: list[afm.AirfoilEntry], Re: float) -> tuple[list[PlotSpec], SimResult]:
    S, summ, checks = {}, {}, []
    summ["Re (cruzeiro, corda de referência)"] = Re
    for e in entries:
        try:
            p = afm.polar(e, Re)
        except Exception as ex:
            checks.append(_chk(FAIL, f"{e.name}: polar", type(ex).__name__, "", str(ex)[:160], "", "perfis"))
            continue
        with np.errstate(divide="ignore", invalid="ignore"):
            ld = np.where(p["cd"] > 0, p["cl"] / p["cd"], np.nan)
        S[f"pol_{e.name}"] = dict(alpha=p["alpha"], cl=p["cl"], cd=p["cd"], cm=p["cm"], ld=ld)
        m = afm.metrics(p)
        if afm.kind(e.airfoil) != "parâmetros":
            xy = e.airfoil.outline()
            S[f"shape_{e.name}"] = dict(x=xy[:, 0], y=xy[:, 1])
        if not m:
            continue
        summ[f"[{e.name}] polar por"] = p["source"] + (f" (Re {p['Re']:.3g})" if p["source"] == "arquivo" else "")
        summ[f"[{e.name}] c_l,max; α de estol (°)"] = [m["cl_max"], m["alpha_stall"]]
        summ[f"[{e.name}] (c_l/c_d) máx.; c_l nele"] = [m["ld_max"], m["cl_ld"]]
        summ[f"[{e.name}] a1 (1/rad); α_L0 (°); c_m"] = [m["cl_alpha"], m["alpha0"], m["cm"]]
        summ[f"[{e.name}] c_d mín."] = m["cd_min"]
        if m["cd_const"]:
            checks.append(_chk(INFO, f"{e.name}: c_d constante", "polar 'modelo'", "—",
                               "o modelo do simulador não tem balde de arrasto: c_l/c_d não serve para comparar perfis",
                               "use neuralfoil (se tiver contorno) ou importe a polar do XFLR5", "perfis"))
        if p["source"] == "arquivo" and math.isfinite(p["Re"]) and abs(p["Re"] / Re - 1) > 0.3:
            checks.append(_chk(ATT, f"{e.name}: Re da polar importada", f"{p['Re']:.3g}", f"≈ {Re:.3g}",
                               "a polar foi calculada noutro Re: c_l,max e c_d mudam com o Re",
                               "exporte do XFLR5 no Re de cruzeiro", "perfis"))
    if Re < 1e5:
        checks.append(_chk(ATT, "Reynolds baixo", f"{Re:.3g}", "≥ 100 000",
                           "abaixo de ~10⁵ as bolhas de separação mudam muito a polar; o modelo e a rede erram mais",
                           "polar experimental ou XFLR5 com N_crit adequado", "perfis"))
    plots = AIRFOIL_PLOTS + ([CONTOUR_PLOT] if any(k.startswith("shape_") for k in S) else [])
    return plots, SimResult(series=S, summary=summ, checks=checks)


# ------------------------------------------------------------------ Asa
WING_PLOTS = [
    PlotSpec("CL", "C_L × α da asa (até o estol)", "alpha", ("CL",), "α da raiz (°)", "C_L", live=False,
             source="series:wCL_*"),
    PlotSpec("pol", "Polar da asa: induzido, perfil e total", "CD", ("CL",), "C_D", "C_L", live=False,
             source="series:wpol_*"),
    PlotSpec("LD", "L/D × C_L (tracejado: cruzeiro)", "CL", ("LD",), "C_L", "L/D", live=False, source="series:wLD_*"),
    PlotSpec("span", "c_l na envergadura: onde o estol começa", "eta", ("cl",), "posição na semiasa (2y/b)",
             "c_l", live=False, source="series:wspan_*"),
]


def wing_stage(cand: wg.WingCandidate, req, rules, others: list | None = None) -> tuple[list[PlotSpec], SimResult, dict]:
    r = wg.analyze(cand, req, rules)
    S, summ, checks = {}, {}, []
    lab = cand.name
    S[f"wCL_{lab}"] = dict(alpha=r["alpha"], CL=r["CL"], _width=2.4)
    S[f"wpol_{lab}: total"] = dict(CD=r["CD"], CL=r["CL"], _width=2.4, _color="#000000")
    S[f"wpol_{lab}: induzido"] = dict(CD=r["CDi"], CL=r["CL"], _color="#1f77b4", _dash="dash")
    S[f"wpol_{lab}: perfil"] = dict(CD=r["CDp"], CL=r["CL"], _color="#2ca02c", _dash="dash")
    S[f"wLD_{lab}"] = dict(CL=r["CL"], LD=r["LD"], _width=2.4)
    S["wLD_C_L de cruzeiro"] = dict(_vline=r["CL_cruise"], _color="#7f7f7f")
    S["wspan_c_l no cruzeiro"] = dict(eta=r["span_eta"], cl=r["cl_cruise"], _color="#1f77b4")
    S["wspan_c_l no estol"] = dict(eta=r["span_eta"], cl=r["cl_stall"], _color="#d62728", _width=2.2)
    S["wspan_c_l,max do perfil"] = dict(_hline=r["airfoil"].cl_max, _color="#d62728", _dash="dot")
    S["wspan_onde começa"] = dict(_vline=r["eta_stall"], _color="#ff7f0e")
    for o in others or []:          # as asas guardadas, para comparar (finas)
        try:
            ro = wg.analyze(o, req, rules)
        except Exception:
            continue
        S[f"wCL_{o.name}"] = dict(alpha=ro["alpha"], CL=ro["CL"], _width=1.2, _dash="dot")
        S[f"wLD_{o.name}"] = dict(CL=ro["CL"], LD=ro["LD"], _width=1.2, _dash="dot")
    s, yb, cr, ct = wg.chords(cand.params)
    pf = r["planform"]
    summ["b, S, AR"] = [r["b"], r["S"], r["AR"]]
    summ["corda da raiz, da ponta, CMA (m)"] = [cr, ct, pf["mac"]]
    summ["perfil (polar por)"] = f"{cand.airfoil.name} ({r['polar2d']['source']}, Re {r['Re']:.3g})"
    summ["C_Lα (1/rad), C_L0, α_L0 (°)"] = [r["CLa"], r["CL0"], r["alpha0"]]
    summ["C_L,max, α de estol (°)"] = [r["CLmax"], r["alpha_stall"]]
    summ["estol começa em (2y/b)"] = r["eta_stall"]
    summ["Oswald e (no cruzeiro)"] = r["e"]
    summ["(L/D) máx., C_L nele"] = [r["LD_max"], r["CL_LD"]]
    summ["cruzeiro: C_L, α da asa (°), L/D"] = [r["CL_cruise"], r["alpha_cruise_w"], r["LD_cruise"]]
    summ["incidência da asa (°)"] = r["incidence"]
    summ["V de estol (massa estimada)"] = r["V_stall"]
    summ["carga alar (kg/m²)"] = r["wing_loading"]
    summ["massa estimada da asa (kg)"] = r["mass"]
    summ["Re na raiz, na ponta"] = [r["Re_root"], r["Re_tip"]]
    G = "asa"
    vs = rg.active(req.constraints, "V_S", "≤")
    checks += constraint_checks(req, rg.wing_values(r), "asa", G, {"V_S": (
        f"área ≥ {r['S'] * (r['V_stall'] / vs.value) ** 2:.2f} m² ou perfil de c_l,max maior") if vs else ""})
    e_st = r["eta_stall"]
    st = OK if e_st <= 0.5 else (ATT if e_st <= 0.8 else FAIL)
    checks.append(_chk(st, "onde o estol começa", f"2y/b = {e_st:.2f}", "≤ 0,5 (perto da raiz)",
                       "" if st == OK else "estol na ponta: o aileron perde efeito e a asa tende a cair para um lado",
                       "" if st == OK else "mais washout (torção negativa na ponta) ou menos afilamento", G))
    if math.isfinite(r["LD_cruise"]) and r["LD_max"] > 0:
        rel = r["LD_cruise"] / r["LD_max"]
        st = OK if rel >= 0.9 else ATT
        checks.append(_chk(st, "cruzeiro perto do L/D máx. da asa", f"{100 * rel:.0f} %", "≥ 90 %",
                           "" if st == OK else f"o C_L de cruzeiro ({r['CL_cruise']:.2f}) longe do de L/D máx. "
                           f"({r['CL_LD']:.2f})", "" if st == OK else "mude a área ou a velocidade de cruzeiro", G))
    if r["CL_cruise"] > 0.85 * r["CLmax"]:
        checks.append(_chk(FAIL, "cruzeiro abaixo do estol", f"C_L {r['CL_cruise']:.2f} de {r['CLmax']:.2f}", "≤ 85 %",
                           "a asa cruza quase estolada", "mais área ou mais velocidade", G))
    if r["Re_tip"] < 8e4:
        checks.append(_chk(ATT, "Re na ponta", f"{r['Re_tip']:.3g}", "≥ 80 000", "a ponta voa num Re em que o perfil "
                           "perde c_l,max", "afilamento menor ou corda maior", G))
    checks.append(_chk(INFO, "método", "linha sustentadora (Glauert)", "—",
                       "seção crítica para o estol; c_d da polar 2D no c_l local; sem fuselagem", "", G))
    return WING_PLOTS, SimResult(series=S, summary=summ, checks=checks), r


# ------------------------------------------------------------------ Empenagem
SET_PLOTS = [
    PlotSpec("cm", "C_m no CG × α (tem de descer)", "alpha", ("Cm",), "α da raiz da asa (°)", "C_m",
             live=False, source="series:cm_*"),
    PlotSpec("de", "Profundor de equilíbrio × V", "V", ("de",), "V (m/s)", "δe (°, − cabra)",
             live=False, source="series:de_*"),
    PlotSpec("cg", "Faixa do CG (% CMA)", "x", ("y",), "% CMA", "", live=False,
             source="series:cg_*", height=200),
]


def set_stage(cand: tl.SetCandidate, req, rules, airfoils=None) -> tuple[list[PlotSpec], SimResult, dict]:
    r = tl.analyze(cand, req, rules, airfoils)
    cv = r["curves"]
    S, summ, checks = {}, {}, []
    colors = {"CG à frente (limite)": "#2ca02c", "CG no alvo": "#000000", "CG atrás (limite)": "#d62728"}
    for k, v in cv.items():
        if k.startswith("Cm:"):
            lab = k[3:]
            S[f"cm_{lab}"] = dict(alpha=cv["alpha"], Cm=v, _color=colors.get(lab), _width=2.4 if "alvo" in lab else 1.6)
        elif k.startswith("de:"):
            lab = k[3:]
            S[f"de_{lab}"] = dict(V=cv["V"], de=v, _color=colors.get(lab), _width=2.4 if "alvo" in lab else 1.6)
    S["cm_C_m = 0"] = dict(_hline=0.0, _color="#7f7f7f", _dash="dot")
    S["de_curso"] = dict(_hline=-rules.de_max, _color="#d62728", _dash="dot")
    S["de_curso "] = dict(_hline=rules.de_down, _color="#d62728", _dash="dot", _nolegend=1)
    S["de_cruzeiro"] = dict(_vline=req.V_cruise, _color="#7f7f7f")
    pct = lambda h: 100 * h
    if "h_fwd" in r:
        S["cg_faixa possível"] = dict(_vspan=[pct(r["h_fwd"]), pct(r["h_aft"])], _color="#2ca02c", _alpha=50)
    S["cg_ponto neutro"] = dict(_vline=pct(r["h_n"]), _color="#d62728")
    S["cg_CG no alvo"] = dict(_vline=pct(r["h_cg"]), _color="#000000", _width=2.4)
    S["cg__lim"] = dict(_xlim=[min(pct(r.get("h_fwd", r["h_cg"])), 0) - 5, max(pct(r["h_n"]), 50) + 5], _ylim=[0, 1])
    info = r["info"]
    tp = cand.params
    summ["cauda"] = tp.layout
    if tp.layout != "sem cauda":
        summ["S_h, S_v (m²)"] = [info["Sh"], info["Sv"]]
        summ["envergadura da EH, altura da EV (m)"] = [info["bh"], info["hv"]]
        summ["braço da cauda, tubo (m)"] = [info["arm"], info.get("boom", 0.0)]
        summ["V_H, V_V"] = [r["VH"], r["VV"]]
        summ["incidência da EH (°)"] = r["i_h"]
        summ["dε/dα"] = r["deda"]
        summ["C_nβ da cauda (1/rad)"] = r["Cnb"]
        summ["massa da empenagem + tubo (kg)"] = info.get("mass_tail", 0) + info.get("mass_boom", 0)
    summ["ponto neutro (% CMA)"] = pct(r["h_n"])
    summ["CG no alvo (% CMA; x em m)"] = [pct(r["h_cg"]), r["x_cg"]]
    if "h_fwd" in r:
        summ["faixa do CG (% CMA)"] = [pct(r["h_fwd"]), pct(r["h_aft"])]
    summ["δe no cruzeiro, no C_L,max (°)"] = [r["de_cruise"], r["de_CLmax"]]
    summ["rolagem: p b/2V com o aileron todo"] = r["pb2V"]
    summ["rotação: V com profundor todo, V com δe = 0, V de sair do chão (m/s)"] = [r["V_rot"], r["V_rot0"], r["V_lof"]]
    G = "empenagem e comandos"
    if cand.wing2 is not None:
        w2 = tl.second_wing(r["set"])
        checks.append(_chk(INFO, "segunda asa ligada", f"{w2.name}: recuo {tp.wing2_dx:g} m, desnível "
                           f"{tp.wing2_dz:g} m", "—", "a estática desta etapa é a da asa 1 com a cauda; com o par, a "
                           "margem é a do avião inteiro no núcleo", "veja Aerodinâmica → Asas (linha "
                           "sustentadora ou VLM, que ligam as asas) depois de mandar para a Montagem", G))
    if tp.layout != "sem cauda":
        width = pct(r["h_aft"] - r["h_fwd"])
        st = OK if width >= 15 else (ATT if width > 0 else FAIL)
        checks.append(_chk(st, "faixa de CG", f"{width:.0f} % CMA", "≥ 15 % CMA",
                           "" if st == OK else "pouca folga para pôr bateria e carga",
                           "" if st == OK else "mais V_H (área ou braço) ou mais profundor", G))
        inside = r["h_fwd"] <= r["h_cg"] <= r["h_aft"]
        checks.append(_chk(OK if inside else FAIL, "CG pedido dentro da faixa", f"{pct(r['h_cg']):.0f} % CMA",
                           f"{pct(r['h_fwd']):.0f} a {pct(r['h_aft']):.0f} %", "" if inside else
                           "com a margem pedida o profundor não equilibra o C_L,max", "" if inside else
                           "margem menor ou empenagem maior", G))
        ok = 0.3 <= r["VH"] <= 0.7
        checks.append(_chk(OK if ok else ATT, "volume de cauda horizontal", f"{r['VH']:.2f}", "0,3 a 0,7", "" if ok else
                           "fora do usual em aeromodelos", "", G))
        ok = r["Cnb"] >= 0.05
        checks.append(_chk(OK if ok else ATT, "estabilidade direcional (cauda)", f"C_nβ = {r['Cnb']:.3f} /rad", "≥ 0,05",
                           "" if ok else "a cauda volta pouco o nariz para o vento (a fuselagem tira mais)",
                           "" if ok else "mais V_V", G))
    else:
        ok = abs(r["de_cruise"]) <= 0.5 * rules.de_max
        checks.append(_chk(OK if ok else FAIL, "elevon equilibra o cruzeiro", f"δ = {r['de_cruise']:.1f}°",
                           f"|δ| ≤ {0.5 * rules.de_max:g}°", "" if ok else "a asa sozinha tem C_m,ac negativo demais "
                           "para a margem pedida", "" if ok else "perfil reflexo (c_m ≈ 0), enflechamento com washout ou "
                           "margem menor", G))
        checks.append(_chk(ATT, "direcional", "sem deriva", "—", "asa voadora precisa de outra fonte de C_nβ",
                           "winglets / derivas nas pontas (na Montagem: dispositivos da asa)", G))
    if "CLh_lim" in r:
        lo3, hi3 = r["CLh_lim"]
        ok = lo3 <= r["CLh_CLmax"] <= hi3
        checks.append(_chk(OK if ok else FAIL, "EH sem estolar no C_L,max", f"C_L da EH = {r['CLh_CLmax']:+.2f}",
                           f"entre {lo3:+.2f} e {hi3:+.2f} (polar do perfil)", "" if ok else
                           "a EH precisaria de mais sustentação (para baixo) do que o perfil dá",
                           "" if ok else "perfil invertido na EH, mais área (V_H) ou CG mais para trás", G))
    ok = abs(r["de_CLmax"]) <= rules.de_max
    checks.append(_chk(OK if ok else FAIL, "profundor equilibra o C_L,max", f"δe = {r['de_CLmax']:.1f}°",
                       f"|δe| ≤ {rules.de_max:g}°", "" if ok else "não dá para pousar devagar com o CG no alvo",
                       "" if ok else "mais profundor/área de EH ou CG mais para trás", G))
    ok = r["V_rot"] <= 0.9 * r["V_lof"]
    vr = "não roda" if not math.isfinite(r["V_rot"]) else f"{r['V_rot']:.1f} m/s"
    checks.append(_chk(OK if ok else (ATT if math.isfinite(r["V_rot"]) and r["V_rot"] <= r["V_lof"] else FAIL),
                       "rotação na decolagem", f"roda a partir de {vr}", f"≤ 0,9 × V de sair do chão ({r['V_lof']:.1f})",
                       "" if ok else "o profundor só levanta o nariz perto (ou depois) da velocidade de sair do chão: "
                       "a corrida cresce e a rotação fica brusca",
                       "" if ok else "EH com perfil invertido (momento cabrador já com δe = 0), mais área de profundor, "
                       "trem principal mais perto do CG ou CG mais para trás", G,
                       source="momentos no trem principal"))
    ok = r["pb2V"] >= 0.07
    checks.append(_chk(OK if ok else ATT, "efetividade do aileron", f"p b/2V = {r['pb2V']:.3f}", "≥ 0,07",
                       "" if ok else "rola devagar", "" if ok else "aileron mais longo ou de corda maior", G))
    checks.append(_chk(INFO, "método", "estática clássica (volume de cauda)", "—",
                       "sem fuselagem (entra na etapa Motores); dε/dα = 2a/(π AR); a_h de Helmbold", "", G))
    return SET_PLOTS, SimResult(series=S, summary=summ, checks=checks), r


# ------------------------------------------------------------------ Motores e montagem
AIRCRAFT_PLOTS = [
    PlotSpec("T", "Tração disponível × arrasto", "V", ("N",), "V (m/s)", "N", live=False,
             source="series:t_*"),
    PlotSpec("RC", "Razão de subida × V", "V", ("RC",), "V (m/s)", "m/s", live=False, source="series:rc_*"),
    PlotSpec("to", "Corrida × massa (corta a pista: MTOW)", "m", ("s",), "massa (kg)", "m",
             live=False, source="series:to_*"),
]


def aircraft_stage(cand: pw.AircraftCandidate, req, rules, catalog=None, backend=None, airfoils=None):
    ac, asm = pw.assemble(cand, req, rules, catalog, airfoils)
    pf = pw.performance(ac, asm, req, backend)
    S, summ, checks = {}, {}, []
    S["t_tração disponível"] = dict(V=pf["V"], N=pf["T"], _color="#1f77b4", _width=2.4)
    S["t_arrasto"] = dict(V=pf["V"], N=pf["D"], _color="#d62728", _width=2.4)
    S["t_estol"] = dict(_vline=pf["Vs"], _color="#7f7f7f")
    S["t_cruzeiro"] = dict(_vline=req.V_cruise, _color="#2ca02c")
    S["rc_razão de subida"] = dict(V=pf["V"], RC=pf["RC"], _width=2.4)
    S["rc_0"] = dict(_hline=0.0, _color="#7f7f7f", _dash="dot", _nolegend=1)
    s = np.where(np.isfinite(pf["s_curve"]), pf["s_curve"], np.nan)
    S["to_corrida"] = dict(m=pf["masses"], s=s, _width=2.4)
    if rg.active(req.constraints, "s_to", "≤"):
        S["to_corrida restrita"] = dict(_hline=req.takeoff_run, _color="#d62728")
    S["to_massa do avião montado"] = dict(_vline=asm["mass"], _color="#000000")
    if math.isfinite(pf["mtow_runway"]):
        S["to_MTOW pela pista"] = dict(_vline=pf["mtow_runway"], _color="#2ca02c")
    summ["PV (vazio), CP (carga paga), total (kg)"] = [asm["empty"], asm["payload"], asm["mass"]]
    summ["fração de carga paga CP/total"] = asm["payload"] / asm["mass"]
    if asm["ballast"] > 0:
        summ["lastro de equilíbrio (kg, entra no PV)"] = asm["ballast"]
    summ["CG (x m), margem estática com a fuselagem (% CMA)"] = [asm["x_cg_target"], asm["sm"]]
    summ["comprimento total (m)"] = asm["length"]
    summ["V de estol, V máx. (m/s)"] = [pf["Vs"], pf["Vmax"]]
    summ["subida máx. (m/s) em V"] = [pf["RC_max"], pf["V_y"]]
    summ["C_D0, (L/D) máx., V de L/D máx."] = [pf["CD0"], pf["LD_max"], pf["V_LDmax"]]
    summ["tração estática (N), T/W"] = [pf["T0"], pf["TW"]]
    summ["corrida de decolagem (m)"] = pf["s_to"]
    summ["MTOW pela pista (kg); CP possível = MTOW − PV (kg)"] = [pf["mtow_runway"], pf["payload_runway"]]
    G = "montagem"
    if asm["battery_fits"] and asm.get("payload_moved"):
        checks.append(_chk(OK, "CG no alvo pela bateria e pela carga paga", f"bateria em x = {asm['x_bat_used']:.2f} m, "
                           f"carga em x = {asm['x_payload']:.2f} m", "dentro da fuselagem", "a carga fora do CG "
                           f"(escolha do otimizador); sem ela, margem estática de {asm['sm_empty']:.1f} %", "", G))
    elif asm["battery_fits"]:
        checks.append(_chk(OK, "CG no alvo pela bateria", f"bateria em x = {asm['x_bat_used']:.2f} m", "dentro da fuselagem",
                           "", "", G))
    else:
        checks.append(_chk(ATT, "CG no alvo pela bateria", f"precisa de {asm['ballast']:.2f} kg de lastro de equilíbrio",
                           "sem lastro", "a bateria não alcança o ponto que põe o CG no alvo (ficaria em x = "
                           f"{asm['x_bat']:.2f} m)", "nariz mais longo/curto, motores noutro lugar ou outra margem", G))
    tr = asm.get("trim") or {}
    if tr:
        if abs(tr["dih"]) > 0.05:
            checks.append(_chk(INFO, "EH trimada com a tração", f"Δi_h = {tr['dih']:+.2f}° (C_m da tração {tr['Cm_T']:+.3f})",
                               "—", "o eixo do motor (inclinação e altura em relação ao CG) dá momento no cruzeiro; a "
                               "incidência da EH já o compensa: voa com o profundor neutro", "", G))
        if tr["hold"] > 0:
            st_ = OK if tr["hold_ok"] else FAIL
            checks.append(_chk(st_, "trim de decolagem (motor inclinado)", f"profundor {tr['hold']:+.1f}° picando na "
                               "corrida", f"≤ curso de picar {rules.de_down:g}°",
                               "com o profundor neutro o nariz sobe e o avião sai do chão antes da velocidade de voo",
                               "" if tr["hold_ok"] else "menos inclinação, EH com menos momento cabrador ou curso de picar "
                               "maior", G, source="momentos no trem principal"))
        if "V_rot" in tr:
            vr, vl = tr["V_rot"], tr["V_lof"]
            st_ = OK if vr <= vl else (ATT if vr <= 1.3 * vl else FAIL)
            checks.append(_chk(st_, "rotação com a tração (trem principal)", "não roda" if not math.isfinite(vr) else
                               f"a partir de {vr:.1f} m/s", f"≤ V de sair do chão ({vl:.1f} m/s)",
                               "" if st_ == OK else "a tração passa acima do apoio do trem e pica o nariz: a rotação "
                               "fica para depois da velocidade de sair do chão (a corrida cresce)", "" if st_ == OK else
                               "EH invertida/maior, trem principal mais perto do CG, motor mais baixo ou inclinado", G,
                               source="momentos no trem principal"))
        summ["tração no cruzeiro (N), C_m dela, Δi_h (°), profundor na corrida (°)"] = [
            tr["T_cruise"], tr["Cm_T"], tr["dih"], tr["hold"]]
    dm = asm["mass"] - req.mass
    st = OK if abs(dm) <= 0.1 * req.mass else ATT
    checks.append(_chk(st, "massa montada × massa estimada", f"{asm['mass']:.2f} kg", f"{req.mass:g} kg ± 10 %",
                       "" if st == OK else "a asa foi dimensionada para outra massa (o ponto de partida)",
                       "" if st == OK else "o Estudo e ponto de projeto acerta a massa sozinho; ou mude a massa estimada "
                       "em Condições e restrições", G))
    if asm["boom_hits_prop"]:
        checks.append(_chk(FAIL, "hélice propulsora × tubo de cauda", "atravessa", "livre",
                           "a hélice gira onde passa o tubo", "tratora, dois motores na asa, ou cauda sem tubo", G))
    vals = rg.aircraft_values(ac, asm, pf, cand.params)
    checks += constraint_checks(req, vals, "montagem", "restrições", {"s_to": (
        f"MTOW pela corrida restrita = {pf['mtow_runway']:.2f} kg" if math.isfinite(pf["mtow_runway"]) else
        "tração/área não bastam para essa massa")})
    summ["saídas: MTOW (kg), PV (kg), CP (kg), EE = CP/PV"] = [vals["mtow"], vals["pv"], vals["cp"], vals["ee"]]
    G = "desempenho"
    ok = math.isfinite(pf["Vmax"]) and pf["Vmax"] >= 1.15 * req.V_cruise
    checks.append(_chk(OK if ok else ATT, "folga de tração no cruzeiro", f"V máx. = {pf['Vmax']:.1f} m/s",
                       f"≥ 1,15 × {req.V_cruise:g} m/s", "" if ok else "pouca tração sobrando em cruzeiro",
                       "" if ok else "hélice/motor maior ou menos arrasto", G))
    ok = pf["RC_max"] >= 1.0
    checks.append(_chk(OK if ok else ATT, "subida", f"{pf['RC_max']:.2f} m/s", "≥ 1 m/s", "" if ok else "sobe devagar",
                       "", G))
    checks.append(_chk(INFO, "método", "pontos de desempenho", "—",
                       "C_D0 das superfícies, fuselagem e tubo + C_Di da linha sustentadora; tração do núcleo "
                       "(equilíbrio do motor) com acelerador cheio; corrida até 1,1 V_S", "", G))
    return AIRCRAFT_PLOTS, SimResult(series=S, summary=summ, checks=checks), ac, asm, pf

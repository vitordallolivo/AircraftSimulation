"""Aba Aerodinâmica — polares e derivadas a partir da geometria, com o lltdrek (linha
sustentadora não linear) como método principal; o modelo interno e o AeroSandbox entram para
comparar. O diagnóstico diz se os métodos concordam (e por que não), onde fica o cruzeiro em
relação ao L/D máximo e, se a aeronave TEM dispositivos de ponta, se eles valem o atrito que
custam. Sem dispositivo na configuração, o estudo de pontas só roda se for pedido.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero import AeroCase, all_solvers, polar_metrics
from aerosim.aero import service as aero_service
from aerosim.aero import tipdevices as td
from aerosim.aero.geometry import _trapz
from aerosim.aero.tipdevices import raymer_oswald
from aerosim.interfaces.aero import DERIVATIVES
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model
from aerosim.model.features import features

from .base import SimulationBase

LABEL = {"zig": "modelo interno", "lltdrek": "lltdrek", "asb_vlm": "ASB VLM", "asb_buildup": "ASB AeroBuildup",
         "asb_ll": "ASB LiftingLine", "avl": "AVL", "zig_llt": "LLT do núcleo (P-S)",
         "zig_llt_gh": "LLT do núcleo (G-H)", "xflr5": "XFLR5 (arquivo)"}
G0 = 9.80665


def resolve_cg(backend, model, xcg_mac: float) -> tuple[tuple[float, float, float], float]:
    """(ponto dos momentos, massa): x_CG em % da CMA (< 0: CG da aeronave pelo modelo de massa)"""
    with backend.session_for(model) as s:
        mp = s.mass_props()
    cg = mp["cg"]
    x = model.x_at_mac(xcg_mac / 100) if xcg_mac >= 0 else cg[0]
    return (x, 0.0, cg[2]), mp["m"]


def compare_solvers(ctx: RunContext, model, case: AeroCase, chosen: list, S_: dict, summ: dict, add,
                    progress: tuple[float, float] = (0.0, 1.0)) -> tuple[dict, dict, dict, dict | None]:
    """roda cada solver de `chosen` (`IAeroSolver`) no modelo universal: as polares em `S_` (polar_<método>,
    ld_<método>), as métricas no resumo e um método que falha vira uma linha do diagnóstico. Devolve as polares, as
    métricas, a tabela de derivadas e a distribuição do lltdrek (se rodou). `progress`: a faixa da barra (início, fim)"""
    res, metrics = {}, {}
    deriv_table = {"derivada": list(DERIVATIVES)}
    span = None
    lo, hi = progress
    for k, so in enumerate(chosen):
        ctx.check()
        ctx.on_progress(lo + (hi - lo) * k / (len(chosen) + 1), f"rodando {so.title}")
        why = so.available()
        lab = LABEL[so.name]
        if why:
            add("info", f"{lab} indisponível", "—", "", why, "", "métodos")
            continue
        try:
            # o arquivo do XFLR5 é lido toda vez (o cache não sabe se ele mudou)
            pol = so.solve(model, case) if so.name == "xflr5" else aero_service.solve(so, model, case)
        except Exception as e:      # um método que falha não derruba a comparação
            add("atencao", f"{lab} falhou", f"{type(e).__name__}", "", str(e)[:200], "", "métodos")
            continue
        res[so.name] = pol
        with np.errstate(divide="ignore", invalid="ignore"):
            LD = np.where(pol.CD > 0, pol.CL / pol.CD, np.nan)
        S_[f"polar_{lab}"] = dict(alpha=pol.alpha, CL=pol.CL, CD=pol.CD, Cm=pol.Cm, CDi=pol.CDi, LD=LD)
        S_[f"ld_{lab}"] = dict(CL=pol.CL, LD=LD)
        metrics[so.name] = polar_metrics(pol, model, case)
        for key, v in metrics[so.name].items():
            summ[f"[{lab}] {key}"] = v
        summ[f"[{lab}] tempo (s)"] = pol.elapsed
        summ[f"[{lab}] de onde"] = pol.source
        deriv_table[lab] = [pol.deriv(d) for d in DERIVATIVES]
        if pol.span is not None and so.name == "lltdrek":
            span = pol.span
    return res, metrics, deriv_table, span


class AerodynamicsSimulation(SimulationBase):
    # sem aba: a subaba Asas (wings.py) roda esta análise na parte "avião completo"; scripts e testes chamam pelo nome
    tab = False
    name = "aerodynamics"
    title = "Aerodinâmica"
    area = "aerodinamica"
    show_aircraft = True
    # comparações entre métodos, aeronave inteira e pontas de asa: estudo detalhado
    detailed = ("use_zig", "use_zig_llt_gh", "use_zig_llt", "use_asb_vlm", "use_asb_buildup", "use_asb_ll", "use_avl", "use_xflr5", "xflr5_file", "full", "de", "alpha_beta", "tips", "hb_max",
                "Cf", "dev_gain")
    description = ("Polares e derivadas a partir da geometria pelo lltdrek (linha sustentadora não linear), "
                   "comparadas com o modelo interno e, se quiser, com o AeroSandbox. Diz se os métodos concordam e "
                   "por quê, onde o cruzeiro fica em relação ao L/D máximo e se os dispositivos de ponta "
                   "(quando existem) compensam.")

    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac, values=None):
        f = features(ac) if ac is not None else None
        from .stability import _cruise_speed
        Vc = _cruise_speed(ac) if ac is not None else 15.0
        ps = [ParamSpec("V", "velocidade de cruzeiro", round(Vc, 1), minimum=3, maximum=80, unit="m/s"),
              ParamSpec("a0", "α inicial", -6.0, minimum=-20, maximum=0, unit="°"),
              ParamSpec("a1", "α final", 18.0, minimum=2, maximum=30, unit="°"),
              ParamSpec("da", "passo de α", 1.0, minimum=0.25, maximum=5, unit="°"),
              ParamSpec("alpha_d", "α das derivadas", 2.0, minimum=-5, maximum=12, unit="°"),
              ParamSpec("xcg", "CG dos momentos", -1.0, minimum=-1, maximum=100,
                        unit="% CMA", help="−1: o da aeronave; em % da CMA a partir do bordo de ataque; em % da CMA a partir do bordo de ataque"),
              ParamSpec("section", "polar 2D dos perfis no lltdrek", "modelo", kind="choice",
                        choices=("modelo", "neuralfoil"),
                        help="modelo: a mesma polar do simulador; neuralfoil: a rede neural sobre o contorno .dat"),
              ParamSpec("n_span", "painéis por semiasa", 12, kind="int", minimum=4, maximum=40),
              ParamSpec("use_lltdrek", "lltdrek (método principal)", True, kind="bool"),
              ParamSpec("use_zig", "comparar: modelo interno", True, kind="bool", help="o modelo que a simulação usa"),
              ParamSpec("use_zig_llt_gh", "comparar: linha sustentadora do núcleo (Goates e Hunsaker)", False,
                        kind="bool", help="as faixas trocadas pela linha sustentadora (core/src/loads/llt.zig); converge "
                        "em derrapagem e com enflechamento; usa os painéis por semiasa"),
              ParamSpec("use_zig_llt", "comparar: linha sustentadora do núcleo (Phillips e Snyder)", False,
                        kind="bool", help="a versão clássica; não converge com a malha em asa enflechada nem em β"),
              ParamSpec("use_asb_vlm", "comparar: AeroSandbox VLM", False, kind="bool"),
              ParamSpec("use_asb_buildup", "comparar: AeroSandbox AeroBuildup", False, kind="bool"),
              ParamSpec("use_asb_ll", "comparar: AeroSandbox LiftingLine", False, kind="bool"),
              ParamSpec("use_avl", "comparar: AVL", False, kind="bool",
                        help="malha de vórtices do Drela, com comandos; precisa do programa 'avl' no PATH"),
              ParamSpec("use_xflr5", "comparar: polar do XFLR5 (arquivo)", False, kind="bool",
                        help="a polar de avião exportada pelo XFLR5 (Polars → Export); C_m no CG de lá"),
              ParamSpec("xflr5_file", "arquivo da polar do XFLR5", "", kind="file",
                        help="texto ou CSV exportado pelo XFLR5")]
        for p_ in ps:
            p_.group = "Caso" if p_.key in ("V", "a0", "a1", "da", "alpha_d", "xcg") else "Métodos"
        A = "Polar da aeronave completa (núcleo 6GDL)"
        ps += [ParamSpec("full", "aeronave inteira (δe e β)", True,
                         kind="bool", group=A, help="curvas da aeronave inteira com profundor e derrapagem, como a simulação usa"),
               ParamSpec("de", "δe para comparar", 10.0, minimum=0, maximum=30, unit="°", group=A),
               ParamSpec("alpha_beta", "α da varredura em β", 4.0, minimum=-5, maximum=15, unit="°", group=A)]
        D = "Dispositivos de asa"
        if f is not None and f.has_tip_devices:
            ps.append(ParamSpec("tips", "avaliar os dispositivos da asa", True, kind="bool", group=D))
        else:
            ps.append(ParamSpec("tips", "explorar pontas de asa", False, kind="bool", group=D,
                                help="winglet, placa, caixa e asa em C pelo plano de Trefftz, com o atrito descontado"))
        ps += [ParamSpec("hb_max", "altura máxima estudada (h/b)", 0.25, minimum=0.05, maximum=1.0, group=D),
               ParamSpec("Cf", "coeficiente de atrito do dispositivo", 0.006, minimum=0.0, maximum=0.05, step=0.001,
                         group=D)]
        C = "Critérios de aprovação"
        ps += [ParamSpec("tol_CLa", "tolerância C_Lα e C_Lmax", 12.0, minimum=1, maximum=100, unit="%",
                         group=C, help="diferença aceita entre os métodos"),
               ParamSpec("tol_np", "tolerância ponto neutro", 5.0, minimum=0.5, maximum=50,
                         unit="% CMA", group=C, help="diferença aceita entre os métodos"),
               ParamSpec("Vs_ratio", "V de cruzeiro / V de estol mínima", 1.3, minimum=1.0, maximum=3.0, group=C),
               ParamSpec("LD_frac", "L/D mín. no cruzeiro", 90.0, minimum=10, maximum=100,
                         unit="%", group=C, help="fração do L/D máximo"),
               ParamSpec("dev_gain", "ganho mín. do dispositivo", 0.5, minimum=0, maximum=20,
                         unit="%", group=C, help="o dispositivo de ponta compensa se reduzir o arrasto ao menos isto")]
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac, values=None):
        return [PlotSpec("CL", "Sustentação × ângulo de ataque", "alpha", ("CL",), "α (°)", "C_L", live=False,
                         source="series:polar_*"),
                PlotSpec("CD", "Polar de arrasto (arrasto total)", "CD", ("CL",), "C_D", "C_L", live=False,
                         source="series:polar_*"),
                PlotSpec("Cm", "Momento de arfagem no CG × α — tem de descer (estável)", "alpha", ("Cm",), "α (°)", "C_m",
                         live=False, source="series:polar_*"),
                PlotSpec("LD", "Eficiência L/D × C_L (vertical tracejada: C_L de cruzeiro)", "CL", ("LD",), "C_L", "L/D",
                         live=False, source="series:ld_*"),
                PlotSpec("span", "Sustentação ao longo da envergadura (no α das derivadas)", "eta",
                         ("lltdrek", "elíptica (ideal)", "Schrenk (estimativa clássica)"), "posição na semiasa (2y/b)",
                         "c·c_l / c_ref", live=False, source="series:span"),
                PlotSpec("pa_CL", "Aeronave completa (núcleo 6GDL): C_L × α com o profundor", "alpha", ("y",), "α (°)",
                         "C_L", live=False, source="series:paL_*"),
                PlotSpec("pa_Cm", "Aeronave completa: C_m no CG × α com o profundor (controle e estabilidade)", "alpha",
                         ("y",), "α (°)", "C_m", live=False, source="series:paM_*"),
                PlotSpec("pa_CD", "Aeronave completa: polar de arrasto", "CD", ("CL",), "C_D", "C_L", live=False,
                         source="series:paD_*"),
                PlotSpec("pa_b", "Aeronave completa: látero-direcional estático × β", "beta", ("y",), "β (°)",
                         "coeficiente (—)", live=False, source="series:paB_*"),
                PlotSpec("tip_e", "Dispositivos de asa: ganho de eficiência de envergadura × altura", "h_b", ("e",),
                         "altura do dispositivo / envergadura (h/b)", "e / e sem dispositivo", live=False,
                         source="series:tipe_*"),
                PlotSpec("tip_d", "Dispositivo de ponta: variação do arrasto total no cruzeiro × altura (com atrito)",
                         "h_b", ("ΔD",), "altura do dispositivo / envergadura (h/b)", "ΔD (% do arrasto total)",
                         live=False, source="series:tipd_*")]

    # ------------------------------------------------------------------ análise
    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        model = build_model(ac)          # o modelo universal: todos os solvers recebem este
        ac = model.aircraft
        P = lambda k: self.param(ctx, k)
        f = model.features
        S, c, b = model.S, model.c, model.b
        AR = b * b / S
        ref, mass = resolve_cg(ctx.backend, model, P("xcg"))
        V = P("V")
        rho = ac.environment.rho
        CL_cru = mass * G0 / (0.5 * rho * V * V * S)
        alphas = np.arange(P("a0"), P("a1") + 1e-9, P("da"))
        case = AeroCase(V=V, alphas=alphas, alpha_d=P("alpha_d"), ref=ref, rho=rho, section=P("section"),
                        n_span=int(P("n_span")))
        S_, summ, checks = {}, {}, []
        add = lambda *a, **k: checks.append(Check(*a, **k))
        summ["configuração"] = f.summary()
        summ["CG dos momentos (m, % CMA)"] = [ref[0], 100 * model.mac_frac(ref[0])]
        summ["S, c, b de referência; AR"] = [S, c, b, AR]
        summ["C_L de cruzeiro (W/qS)"] = CL_cru
        chosen = [s for s in all_solvers(ctx.backend) if P("use_" + s.name)]
        if P("use_xflr5"):
            from aerosim.aero import Xflr5PolarFile
            chosen.append(Xflr5PolarFile(str(P("xflr5_file") or "")))
        res, metrics, deriv_table, span = compare_solvers(ctx, model, case, chosen, S_, summ, add)
        if any(f"ld_{x}" in S_ for x in LABEL.values()):
            hi = max(np.nanmax(t["LD"]) for k, t in S_.items() if k.startswith("ld_"))
            S_["ld_C_L de cruzeiro"] = {"CL": np.array([CL_cru, CL_cru]), "LD": np.array([0.0, hi]), "_dash": 1}
        S_["derivadas"] = deriv_table
        S_["span"] = self._span(model, span)
        main = "lltdrek" if "lltdrek" in res else ("zig" if "zig" in res else next(iter(res), None))
        if main is not None:          # a polar fica disponível para as outras abas (dimensionamento...)
            aero_service.remember(ctx.shared, model, res[main], LABEL[main], V)
        if main is None:
            add("falha", "nenhum método rodou", "—", "", "", "marque o lltdrek ou o modelo interno", "métodos")
            return SimResult(series=S_, summary=summ, checks=checks)
        if main != "lltdrek" and P("use_lltdrek"):
            add("info", "método principal", LABEL[main], "lltdrek indisponível", "usando o próximo disponível", "",
                "métodos")
        self._diagnose(ac, f, res, metrics, main, CL_cru, V, rho, mass, S, AR, add, P)
        if P("full"):
            ctx.on_progress(0.85, "curvas da aeronave completa (núcleo)")
            self._full(ctx, ac, V, S_, summ, add, P)
        if P("tips"):
            ctx.on_progress(0.9, "dispositivos de ponta (Trefftz)")
            self._tips(model, f, S_, summ, add, P, CL_cru, metrics[main].get("e", raymer_oswald(AR)), res, main)
        return SimResult(series=S_, summary=summ, checks=checks)

    def _full(self, ctx, ac, V, S_, summ, add, P):
        from .polar import aircraft_curves
        A, B = aircraft_curves(ctx.backend, ac, V, P("a0") - 4, P("a1") + 10, 0.5, P("de"), P("alpha_beta"))
        de = P("de")
        S_["paL_C_L total (δe = 0)"] = dict(alpha=A["alpha"], y=A["CL"], _color="#000000", _width=2.4)
        S_["paL_C_L da asa"] = dict(alpha=A["alpha"], y=A["CL_wing"], _color="#1f77b4")
        if np.nanmax(np.abs(A["CL_ht"])) > 1e-6:
            S_["paL_C_L da EH"] = dict(alpha=A["alpha"], y=A["CL_ht"], _color="#2ca02c")
        S_[f"paL_δe = −{de:g}°"] = dict(alpha=A["alpha"], y=A["CL_de_m"], _color="#2ca02c", _dash="dash")
        S_[f"paL_δe = +{de:g}°"] = dict(alpha=A["alpha"], y=A["CL_de_p"], _color="#d62728", _dash="dash")
        S_[f"paM_δe = −{de:g}° (cabra)"] = dict(alpha=A["alpha"], y=A["Cm_de_m"], _color="#2ca02c")
        S_["paM_δe = 0"] = dict(alpha=A["alpha"], y=A["Cm"], _color="#000000", _width=2.4)
        S_[f"paM_δe = +{de:g}° (pica)"] = dict(alpha=A["alpha"], y=A["Cm_de_p"], _color="#d62728")
        S_["paM_C_m = 0 (equilíbrio)"] = dict(_hline=0.0, _color="#7f7f7f", _dash="dot")
        S_["paD_aeronave completa"] = dict(CD=A["CD"], CL=A["CL"], _color="#000000", _width=2.2)
        for k, lab, c in (("CY", "C_Y", "#9467bd"), ("Cl", "C_l (rolamento)", "#1f77b4"), ("Cn", "C_n (guinada)", "#d62728")):
            S_[f"paB_{lab}"] = dict(beta=B["beta"], y=B[k], _color=c, _width=2)
        S_["polar_aeronave_completa"] = A
        S_["polar_beta"] = B
        sb = np.abs(B["beta"]) <= 5
        Cnb = float(np.polyfit(np.radians(B["beta"][sb]), B["Cn"][sb], 1)[0])
        Clb = float(np.polyfit(np.radians(B["beta"][sb]), B["Cl"][sb], 1)[0])
        summ["aeronave completa: C_nβ, C_lβ (1/rad)"] = [Cnb, Clb]
        G = "aeronave completa (núcleo)"
        add("ok" if Cnb > 0 else "falha", "estabilidade direcional C_nβ", f"{Cnb:.4f} /rad", "> 0",
            "" if Cnb > 0 else "a aeronave não volta o nariz para o vento", "" if Cnb > 0 else
            "aumente a EV ou o braço dela", G)
        add("ok" if Clb < 0 else "atencao", "efeito diedro C_lβ", f"{Clb:.4f} /rad", "< 0",
            "" if Clb < 0 else "sem efeito diedro estabilizante", "" if Clb < 0 else "aumente o diedro", G)
        # o profundor consegue equilibrar no C_L máximo?
        i = int(np.nanargmax(A["CL"]))
        cm_up = A["Cm_de_m"][i]
        add("ok" if cm_up >= 0 else "atencao", f"profundor equilibra no C_L máximo com δe = −{de:g}°",
            f"C_m = {cm_up:+.3f}", "≥ 0 (consegue cabrar até o estol)",
            "" if cm_up >= 0 else "com esse δe o nariz não sobe até o C_L máximo", "" if cm_up >= 0 else
            "mais área/braço de profundor ou CG mais para trás", G)

    # ------------------------------------------------------------------ diagnóstico
    def _diagnose(self, ac, f, res, metrics, main, CL_cru, V, rho, mass, S, AR, add, P):
        mlab = LABEL[main]
        M = metrics[main]
        G = "desempenho aerodinâmico"
        # estol
        if "CLmax" in M:
            Vs = math.sqrt(2 * mass * G0 / (rho * S * M["CLmax"]))
            kv = P("Vs_ratio")
            st = "ok" if V >= kv * Vs else "falha"
            add(st, "cruzeiro acima do estol", f"V_S = {Vs:.1f} m/s; cruzeiro {V:g} m/s", f"V ≥ {kv:g} V_S",
                "" if st == "ok" else "o cruzeiro está perto do estol: pouca margem para rajada e curva",
                "" if st == "ok" else f"cruzar a ≥ {kv * Vs:.1f} m/s ou aumentar a área/C_Lmax da asa", G)
        # cruzeiro × L/D máx.
        p = res[main]
        ok = np.isfinite(p.CL) & (p.CD > 0)
        if ok.sum() > 3:
            LD = p.CL[ok] / p.CD[ok]
            i = int(np.argmax(LD))
            CLs = float(p.CL[ok][i])
            LD_cru = float(np.interp(CL_cru, p.CL[ok], LD)) if p.CL[ok].min() <= CL_cru <= p.CL[ok].max() else float("nan")
            V_ld = math.sqrt(2 * mass * G0 / (rho * S * CLs))
            rel = LD_cru / LD[i] if np.isfinite(LD_cru) else float("nan")
            fr = P("LD_frac") / 100
            st = "ok" if rel >= fr else "atencao"
            add(st, "cruzeiro perto do L/D máximo", f"{LD_cru:.1f} de {LD[i]:.1f} ({100 * rel:.0f} %)",
                f"≥ {100 * fr:.0f} % do L/D máx.",
                "" if st == "ok" else (f"o C_L de cruzeiro ({CL_cru:.2f}) está longe do C_L de L/D máx. ({CLs:.2f})"),
                "" if st == "ok" else (f"V de L/D máx. = {V_ld:.1f} m/s; para cruzar a {V:g} m/s com L/D máx. a área da "
                                       f"asa seria ≈ {S * CL_cru / CLs:.2f} m²"), G)
        if "e" in M:
            e_r = raymer_oswald(AR)
            add("info", "fator de Oswald", f"{M['e']:.3f} ({mlab}); Raymer {e_r:.3f}", "—", "e > 1 sai quando o ajuste pega a interação asa-EH ou o C_Di inclui torção; "
                "e baixo indica carregamento longe do elíptico (afilamento/torção)", "", G)
        # concordância entre métodos
        G = "métodos"
        others = [k for k in res if k != main]
        for o in others:
            Mo = metrics[o]
            olab = LABEL[o]
            tc = P("tol_CLa") / 100
            for key, lab, tol, unit in (("CLa_fit", "C_Lα", tc, ""), ("x_np_mac", "ponto neutro", P("tol_np"), " % CMA"),
                                        ("CLmax", "C_Lmax", tc, "")):
                if key not in M or key not in Mo:
                    continue
                a, b_ = M[key], Mo[key]
                bad = abs(a - b_) > tol if unit else abs(a - b_) > tol * abs(a)
                why = _why_differ(main, o, key)
                add("atencao" if bad else "ok", f"{lab}: {LABEL[main]} × {olab}", f"{a:.3g} × {b_:.3g}{unit}",
                    f"diferença ≤ {tol:g}{unit}" if unit else f"diferença ≤ {100 * tol:.0f} %",
                    why if bad else "", ("o modelo interno é o que a simulação usa: se a diferença importa, ajuste "
                                         "C_Lα/dε/dα/C_mα da fuselagem no modelo") if bad and o == "zig" else "", G)

    @staticmethod
    def _tips(model, f, S_, summ, add, P, CL_cru, e_pl, res, main):
        """dispositivos da asa pela geometria real (plano de Trefftz): e com e sem, atrito da área molhada,
        e a altura que daria o menor arrasto; mais os tipos genéricos para comparar"""
        S, c, b = model.S, model.c, model.b
        w = model.wing
        G = "dispositivos de asa"
        e_pl = min(e_pl, 1.0)
        CD0 = float(np.nanmin(res[main].CD)) if main in res else 0.03
        AR = b * b / S
        CDi0 = CL_cru ** 2 / (math.pi * AR * e_pl)
        CD_tot = CD0 + CDi0
        Cf = P("Cf")
        gain = P("dev_gain")
        ctip = w.tip.chord if w is not None else c
        if f.has_tip_devices:
            e_base = td.model_efficiency(model, False)
            ks = np.linspace(0.0, 2.0, 11)
            hb_now = f.tip_h_over_b
            dD = []
            for kh in ks:
                e_k = td.model_efficiency(model, True, height_scale=max(kh, 1e-6)) if kh > 0 else e_base
                wet = td.devices_wetted_area(model, kh)
                CDi = CL_cru ** 2 / (math.pi * AR * e_pl * e_k / e_base)
                dD.append(100 * (CDi - CDi0 + Cf * wet / S) / CD_tot)
            dD = np.array(dD)
            S_["tipd_dispositivos atuais (altura escalada)"] = {"h_b": ks * hb_now, "ΔD": dD}
            e_now = td.model_efficiency(model, True)
            S_["tipe_dispositivos atuais (altura escalada)"] = {
                "h_b": ks * hb_now, "e": np.array([td.model_efficiency(model, True, height_scale=max(k_, 1e-6))
                                                   / e_base if k_ > 0 else 1.0 for k_ in ks])}
            d_now = float(np.interp(1.0, ks, dD))
            iopt = int(np.argmin(dD))
            summ["dispositivos atuais: e/e_sem, ΔD total (%)"] = [e_now / e_base, d_now]
            fins = f.tailless and not f.vtail and f.tip_devices
            note = " Também fazem o papel de deriva: tirar exige outra fonte de C_nβ." if fins else ""
            opt = (f"altura × {ks[iopt]:.1f} dá {dD[iopt]:.1f} %." if dD[iopt] < d_now - 0.3 else "")
            if d_now <= -gain:
                add("ok", "os dispositivos da asa compensam?", f"ΔD = {d_now:.1f} % (e × {e_now / e_base:.3f})",
                    f"ΔD ≤ −{gain:g} %", "", (opt + note).strip(), G, source="Trefftz (Munk; Kroo 2001)")
            else:
                add("atencao", "os dispositivos da asa compensam?", f"ΔD = {d_now:+.1f} % (e × {e_now / e_base:.3f})",
                    f"ΔD ≤ −{gain:g} %",
                    f"no C_L de cruzeiro ({CL_cru:.2f}) o induzido é {100 * CDi0 / CD_tot:.0f} % do arrasto: "
                    "o atrito da área molhada pesa mais que o ganho",
                    ((opt or "sem ganho em nenhuma altura: retirar ou reduzir") + note).strip(), G,
                    source="Trefftz (Munk; Kroo 2001)")
            add("info", "limite do modelo", "carregamento ótimo", "—",
                "o plano de Trefftz dá o melhor caso; o modelo interno trata o dispositivo por faixas e o lltdrek não o "
                "inclui (só superfícies horizontais)", "", G)
        hb = np.linspace(0.0, P("hb_max"), 11)
        t = td.device_study(b, S, CL_cru, ctip, e_planform=e_pl, Cf=Cf, hb=hb)
        k = CDi0 / CD_tot
        for key, lab in (("winglet", "winglet"), ("placa", "placa de ponta"), ("caixa", "asa em caixa"),
                         ("asa_c", "asa em C")):
            S_[f"tipe_{lab} (genérico)"] = {"h_b": t["h_b"], "e": t[f"e_{key}"]}
            S_[f"tipd_{lab} (genérico)"] = {"h_b": t["h_b"], "ΔD": t[f"dD_{key}"] * k}
        S_["tipd_extensão de ponta (mesmo momento na raiz)"] = {"h_b": t["h_b"], "ΔD": t["dD_extensao_mesmo_M"] * k,
                                                                "_dash": 1}
        S_["tipd_sem dispositivo"] = {"h_b": t["h_b"][[0, -1]], "ΔD": np.zeros(2), "_dash": 1}
        if not f.has_tip_devices:
            i = int(np.argmin(t["dD_winglet"]))
            best_hb, best_d = float(t["h_b"][i]), float(t["dD_winglet"][i] * k)
            add("info", "vale a pena pôr winglet?",
                f"melhor h/b ≈ {best_hb:.2f} → ΔD = {best_d:.1f} %" if best_d < -gain else "não neste C_L de cruzeiro",
                f"ΔD ≤ −{gain:g} %", f"induzido = {100 * k:.0f} % do arrasto de cruzeiro",
                "para testar: Configuração → asa → dispositivos → + adicionar", G)

    @staticmethod
    def _span(model, span) -> dict:
        """c c_l / c_ref: lltdrek, elíptico e Schrenk (média da corda real e da elíptica)"""
        w = model.wing
        S, c, b = model.S, model.c, model.b
        eta = np.linspace(0, 0.995, 60)
        out = {"eta": eta}
        if w is None:
            return out
        s = w.length
        CL = None
        if span is not None:
            yy = np.asarray(span["y"]) / s
            ccl = np.asarray(span["ccl"])
            out["lltdrek"] = np.interp(eta, yy, ccl, right=0.0)
            CL = 2 * _trapz(np.r_[ccl[0], ccl, 0.0] * c, np.r_[0.0, span["y"], s]) / S
        if CL is None:
            return out
        ell = 4 * S * CL / (math.pi * 2 * s) * np.sqrt(1 - eta ** 2) / c
        chord = np.array([w.chord_at(e * s) for e in eta])
        out["elíptica (ideal)"] = ell
        out["Schrenk (estimativa clássica)"] = 0.5 * (ell + chord * CL / c)
        return out


def _why_differ(a: str, b: str, key: str) -> str:
    notes = {
        "lltdrek": "lltdrek: só asa e EH (sem deriva e fuselagem), interação asa-EH calculada",
        "zig": "núcleo: faixas com C_Lα de Helmbold, downwash ε0 + dε/dα α, fuselagem por coeficientes",
        "zig_llt": "linha sustentadora do núcleo (Phillips e Snyder): sem estol; não converge em β nem com enflechamento",
        "zig_llt_gh": "linha sustentadora do núcleo (Goates e Hunsaker): sem estol; fuselagem como na simulação",
        "asb_vlm": "VLM: superfícies finas sem fuselagem e sem estol",
        "asb_buildup": "AeroBuildup: soma por componentes com NeuralFoil e fuselagem",
        "asb_ll": "LiftingLine do ASB: polar do NeuralFoil (perfil real)",
        "avl": "AVL: malha de vórtices sem fuselagem e sem estol",
        "xflr5": "XFLR5: a polar 2D e o CG de lá (podem não ser os daqui)",
    }
    extra = {"x_np_mac": " — o ponto neutro depende de dε/dα na cauda e do C_mα da fuselagem",
             "CLmax": " — o C_Lmax depende da polar 2D usada (modelo × NeuralFoil) e do estol na ponta",
             "CLa_fit": ""}[key]
    return f"{notes.get(a, a)}; {notes.get(b, b)}{extra}"

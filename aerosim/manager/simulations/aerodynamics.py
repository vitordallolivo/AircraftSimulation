"""Aba Aerodinâmica — polares e derivadas a partir da geometria, com o lltdrek (linha
sustentadora não linear) como método principal; o núcleo Zig e o AeroSandbox entram para
comparar. O diagnóstico diz se os métodos concordam (e por que não), onde fica o cruzeiro em
relação ao L/D máximo e, se a aeronave TEM dispositivos de ponta, se eles valem o atrito que
custam. Sem dispositivo na configuração, o estudo de pontas só roda se for pedido.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero import AeroCase, all_solvers, mac_frac, polar_metrics, x_at_mac
from aerosim.aero import tipdevices as td
from aerosim.aero.geometry import _trapz
from aerosim.aero.tipdevices import raymer_oswald
from aerosim.interfaces.aero import DERIVATIVES
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.compile import compile_aircraft
from aerosim.model.features import features

from .base import SimulationBase

LABEL = {"zig": "núcleo Zig", "lltdrek": "lltdrek", "asb_vlm": "ASB VLM", "asb_buildup": "ASB AeroBuildup",
         "asb_ll": "ASB LiftingLine"}
G0 = 9.80665


def resolve_cg(backend, ac, xcg_mac: float) -> tuple[tuple[float, float, float], float]:
    """(ponto dos momentos, massa): x_CG em % da CMA (< 0: CG da aeronave pelo modelo de massa)"""
    with backend.open_session() as s:
        s.configure(compile_aircraft(ac))
        mp = s.mass_props()
    cg = mp["cg"]
    x = x_at_mac(ac, xcg_mac / 100) if xcg_mac >= 0 else cg[0]
    return (x, 0.0, cg[2]), mp["m"]


class AerodynamicsSimulation(SimulationBase):
    name = "aerodynamics"
    title = "Aerodinâmica"
    description = ("Polares e derivadas a partir da geometria pelo lltdrek (linha sustentadora não linear), "
                   "comparadas com o núcleo Zig e, se quiser, com o AeroSandbox. Diz se os métodos concordam e "
                   "por quê, onde o cruzeiro fica em relação ao L/D máximo e se os dispositivos de ponta "
                   "(quando existem) compensam.")

    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac):
        f = features(ac) if ac is not None else None
        from .stability import _cruise_speed
        Vc = _cruise_speed(ac) if ac is not None else 15.0
        ps = [ParamSpec("V", "velocidade de cruzeiro", round(Vc, 1), minimum=3, maximum=80, unit="m/s"),
              ParamSpec("a0", "α inicial", -6.0, minimum=-20, maximum=0, unit="°"),
              ParamSpec("a1", "α final", 18.0, minimum=2, maximum=30, unit="°"),
              ParamSpec("da", "passo de α", 1.0, minimum=0.25, maximum=5, unit="°"),
              ParamSpec("alpha_d", "α das derivadas", 2.0, minimum=-5, maximum=12, unit="°"),
              ParamSpec("xcg", "posição do CG para os momentos (−1: a da aeronave)", -1.0, minimum=-1, maximum=100,
                        unit="% CMA", help="em % da CMA a partir do bordo de ataque"),
              ParamSpec("section", "polar 2D dos perfis no lltdrek", "modelo", kind="choice",
                        choices=("modelo", "neuralfoil"),
                        help="modelo: a mesma polar do simulador; neuralfoil: a rede neural sobre o contorno .dat"),
              ParamSpec("n_span", "painéis por semiasa", 12, kind="int", minimum=4, maximum=40),
              ParamSpec("use_lltdrek", "lltdrek (método principal)", True, kind="bool"),
              ParamSpec("use_zig", "comparar: núcleo Zig (o que a simulação usa)", True, kind="bool"),
              ParamSpec("use_asb_vlm", "comparar: AeroSandbox VLM", False, kind="bool"),
              ParamSpec("use_asb_buildup", "comparar: AeroSandbox AeroBuildup", False, kind="bool"),
              ParamSpec("use_asb_ll", "comparar: AeroSandbox LiftingLine", False, kind="bool")]
        if f is not None and f.tip_devices:
            ps.append(ParamSpec("tips", f"avaliar os {len(f.tip_devices)} dispositivos de ponta da aeronave", True,
                                kind="bool"))
        else:
            ps.append(ParamSpec("tips", "explorar dispositivos de ponta (a aeronave não tem)", False, kind="bool",
                                help="winglet, placa, caixa e asa em C pelo plano de Trefftz, com o atrito descontado"))
        ps += [ParamSpec("hb_max", "pontas: altura máxima estudada (h/b)", 0.25, minimum=0.05, maximum=1.0),
               ParamSpec("Cf", "pontas: coeficiente de atrito do dispositivo", 0.006, minimum=0.0, maximum=0.05,
                         step=0.001)]
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac):
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
                PlotSpec("tip_e", "Dispositivo de ponta: eficiência de envergadura ideal × altura", "h_b", ("e",),
                         "altura do dispositivo / envergadura (h/b)", "e (1 = asa plana elíptica)", live=False,
                         source="series:tipe_*"),
                PlotSpec("tip_d", "Dispositivo de ponta: variação do arrasto total no cruzeiro × altura (com atrito)",
                         "h_b", ("ΔD",), "altura do dispositivo / envergadura (h/b)", "ΔD (% do arrasto total)",
                         live=False, source="series:tipd_*")]

    # ------------------------------------------------------------------ análise
    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        ac.apply_constraints()
        P = lambda k: self.param(ctx, k)
        f = features(ac)
        S, c, b = ac.references()
        AR = b * b / S
        ref, mass = resolve_cg(ctx.backend, ac, P("xcg"))
        V = P("V")
        rho = ac.environment.rho
        CL_cru = mass * G0 / (0.5 * rho * V * V * S)
        alphas = np.arange(P("a0"), P("a1") + 1e-9, P("da"))
        case = AeroCase(V=V, alphas=alphas, alpha_d=P("alpha_d"), ref=ref, rho=rho, section=P("section"),
                        n_span=int(P("n_span")))
        S_, summ, checks = {}, {}, []
        add = lambda *a, **k: checks.append(Check(*a, **k))
        summ["configuração"] = f.summary()
        summ["CG dos momentos (m, % CMA)"] = [ref[0], 100 * mac_frac(ac, ref[0])]
        summ["S, c, b de referência; AR"] = [S, c, b, AR]
        summ["C_L de cruzeiro (W/qS)"] = CL_cru
        chosen = [s for s in all_solvers(ctx.backend) if P("use_" + s.name)]
        res, metrics = {}, {}
        deriv_table = {"derivada": list(DERIVATIVES)}
        span = None
        for k, so in enumerate(chosen):
            ctx.check()
            ctx.on_progress(k / (len(chosen) + 1), f"rodando {so.title}")
            why = so.available()
            lab = LABEL[so.name]
            if why:
                add("info", f"{lab} indisponível", "—", "", why, "", "métodos")
                continue
            try:
                pol = so.solve(ac, case)
            except Exception as e:      # um método que falha não derruba a comparação
                add("atencao", f"{lab} falhou", f"{type(e).__name__}", "", str(e)[:200], "", "métodos")
                continue
            res[so.name] = pol
            with np.errstate(divide="ignore", invalid="ignore"):
                LD = np.where(pol.CD > 0, pol.CL / pol.CD, np.nan)
            S_[f"polar_{lab}"] = dict(alpha=pol.alpha, CL=pol.CL, CD=pol.CD, Cm=pol.Cm, CDi=pol.CDi, LD=LD)
            S_[f"ld_{lab}"] = dict(CL=pol.CL, LD=LD)
            metrics[so.name] = polar_metrics(pol, ac, case)
            for key, v in metrics[so.name].items():
                summ[f"[{lab}] {key}"] = v
            summ[f"[{lab}] tempo (s)"] = pol.elapsed
            deriv_table[lab] = [pol.deriv(d) for d in DERIVATIVES]
            if pol.span is not None and so.name == "lltdrek":
                span = pol.span
        if any(f"ld_{x}" in S_ for x in LABEL.values()):
            hi = max(np.nanmax(t["LD"]) for k, t in S_.items() if k.startswith("ld_"))
            S_["ld_C_L de cruzeiro"] = {"CL": np.array([CL_cru, CL_cru]), "LD": np.array([0.0, hi]), "_dash": 1}
        S_["derivadas"] = deriv_table
        S_["span"] = self._span(ac, span)
        main = "lltdrek" if "lltdrek" in res else ("zig" if "zig" in res else next(iter(res), None))
        if main is None:
            add("falha", "nenhum método rodou", "—", "", "", "marque o lltdrek ou o núcleo Zig", "métodos")
            return SimResult(series=S_, summary=summ, checks=checks)
        if main != "lltdrek" and P("use_lltdrek"):
            add("info", "método principal", LABEL[main], "lltdrek indisponível", "usando o próximo disponível", "",
                "métodos")
        self._diagnose(ac, f, res, metrics, main, CL_cru, V, rho, mass, S, AR, add)
        if P("tips"):
            ctx.on_progress(0.9, "dispositivos de ponta (Trefftz)")
            self._tips(ac, f, S_, summ, add, P, CL_cru, metrics[main].get("e", raymer_oswald(AR)), res, main)
        return SimResult(series=S_, summary=summ, checks=checks)

    # ------------------------------------------------------------------ diagnóstico
    def _diagnose(self, ac, f, res, metrics, main, CL_cru, V, rho, mass, S, AR, add):
        mlab = LABEL[main]
        M = metrics[main]
        G = "desempenho aerodinâmico"
        # estol
        if "CLmax" in M:
            Vs = math.sqrt(2 * mass * G0 / (rho * S * M["CLmax"]))
            st = "ok" if V >= 1.3 * Vs else "falha"
            add(st, "velocidade de estol × cruzeiro", f"V_S = {Vs:.1f} m/s (C_Lmax {M['CLmax']:.2f}, {mlab}); "
                f"cruzeiro {V:g} m/s", "V_cruzeiro ≥ 1,3 V_S",
                "" if st == "ok" else "o cruzeiro está perto do estol: pouca margem para rajada e curva",
                "" if st == "ok" else f"cruzar a ≥ {1.3 * Vs:.1f} m/s ou aumentar a área/C_Lmax da asa", G)
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
            st = "ok" if rel >= 0.9 else "atencao"
            add(st, "cruzeiro perto do L/D máximo", f"L/D no cruzeiro {LD_cru:.1f} de {LD[i]:.1f} ({100 * rel:.0f} %)",
                "≥ 90 % do (L/D) máx. (alcance/autonomia)",
                "" if st == "ok" else (f"o C_L de cruzeiro ({CL_cru:.2f}) está longe do C_L de L/D máx. ({CLs:.2f})"),
                "" if st == "ok" else (f"V de L/D máx. = {V_ld:.1f} m/s; para cruzar a {V:g} m/s com L/D máx. a área da "
                                       f"asa seria ≈ {S * CL_cru / CLs:.2f} m²"), G)
        if "e" in M:
            e_r = raymer_oswald(AR)
            add("info", "fator de Oswald (ajuste de C_Di)", f"{M['e']:.3f} ({mlab}); estimativa de Raymer {e_r:.3f}",
                "e ≤ 1 numa asa plana", "e > 1 sai quando o ajuste pega a interação asa-EH ou o C_Di inclui torção; "
                "e baixo indica carregamento longe do elíptico (afilamento/torção)", "", G)
        # concordância entre métodos
        G = "métodos"
        others = [k for k in res if k != main]
        for o in others:
            Mo = metrics[o]
            olab = LABEL[o]
            for key, lab, tol, unit in (("CLa_fit", "C_Lα", 0.12, ""), ("x_np_mac", "ponto neutro", 5.0, " % CMA"),
                                        ("CLmax", "C_Lmax", 0.12, "")):
                if key not in M or key not in Mo:
                    continue
                a, b_ = M[key], Mo[key]
                bad = abs(a - b_) > tol if unit else abs(a - b_) > tol * abs(a)
                why = _why_differ(main, o, key)
                add("atencao" if bad else "ok", f"{lab}: {LABEL[main]} × {olab}", f"{a:.3g} × {b_:.3g}{unit}",
                    f"diferença ≤ {tol:g}{unit}" if unit else f"diferença ≤ {100 * tol:.0f} %",
                    why if bad else "", ("o núcleo Zig é o que a simulação usa: se a diferença importa, ajuste "
                                         "C_Lα/dε/dα/C_mα da fuselagem no modelo") if bad and o == "zig" else "", G)

    @staticmethod
    def _tips(ac, f, S_, summ, add, P, CL_cru, e_pl, res, main):
        S, c, b = ac.references()
        w = ac.wing
        G = "dispositivos de ponta"
        ctip = w.chord_at(w.semispan) if w is not None else c
        hb = np.linspace(0.0, P("hb_max"), 11)
        if f.tip_devices:
            hb_now = f.tip_h_over_b
            hb = np.unique(np.r_[hb, hb_now])
            dev_area = sum(s.area for s in f.tip_devices)
            ctip = dev_area / max(sum(s.semispan for s in f.tip_devices), 1e-9)   # corda média do dispositivo
        t = td.device_study(b, S, CL_cru, ctip, e_planform=min(e_pl, 1.0), Cf=P("Cf"), hb=hb)
        # ΔD em % do arrasto TOTAL de cruzeiro (o estudo dá em % do induzido)
        CD0 = float(np.nanmin(res[main].CD)) if main in res else 0.03
        CDi0 = CL_cru ** 2 / (math.pi * (b * b / S) * min(e_pl, 1.0))
        k = CDi0 / (CD0 + CDi0)
        kinds = (("winglet", "winglet"), ("placa", "placa de ponta"), ("caixa", "asa em caixa"), ("asa_c", "asa em C"))
        for key, lab in kinds:
            S_[f"tipe_{lab}"] = {"h_b": t["h_b"], "e": t[f"e_{key}"]}
            S_[f"tipd_{lab}"] = {"h_b": t["h_b"], "ΔD": t[f"dD_{key}"] * k}
        S_["tipe_Raymer: placa 1 + 1,9 h/b"] = {"h_b": t["h_b"], "e": t["e_raymer_placa"], "_dash": 1}
        S_["tipd_extensão de ponta (mesmo momento na raiz)"] = {"h_b": t["h_b"], "ΔD": t["dD_extensao_mesmo_M"] * k,
                                                                "_dash": 1}
        S_["tipd_sem dispositivo"] = {"h_b": t["h_b"][[0, -1]], "ΔD": np.zeros(2), "_dash": 1}
        i = int(np.argmin(t["dD_winglet"]))
        best_hb, best_d = float(t["h_b"][i]), float(t["dD_winglet"][i] * k)
        if f.tip_devices:
            j = int(np.argmin(np.abs(t["h_b"] - f.tip_h_over_b)))
            d_now = float(t["dD_winglet"][j] * k)
            e_now = float(t["e_winglet"][j])
            summ["dispositivo atual: h/b, e ideal, ΔD total (%)"] = [f.tip_h_over_b, e_now, d_now]
            fins = f.tailless and not f.vtail
            note = (" Eles também são a deriva desta aeronave: tirar exige outra fonte de C_nβ." if fins else "")
            if d_now < -0.5:
                add("ok", "os dispositivos de ponta atuais compensam?", f"ΔD = {d_now:.1f} % no cruzeiro (h/b = "
                    f"{f.tip_h_over_b:.3f}, e ideal {e_now:.3f})", "ganho no induzido > atrito da área molhada",
                    "", ((f"o ótimo está em h/b ≈ {best_hb:.2f} ({best_d:.1f} %)." if best_d < d_now - 0.5 else "")
                         + note).strip(), G)
            else:
                add("atencao", "os dispositivos de ponta atuais compensam?", f"ΔD = {d_now:+.1f} % no cruzeiro",
                    "ganho no induzido > atrito da área molhada",
                    f"no C_L de cruzeiro ({CL_cru:.2f}) o induzido é só {100 * k:.0f} % do arrasto: o atrito do dispositivo "
                    "pesa mais que o ganho",
                    (f"altura h/b ≈ {best_hb:.2f} dá {best_d:.1f} %" if best_d < -0.5 else
                     "sem ganho em nenhuma altura neste C_L: retirar ou reduzir") + note, G)
            add("info", "limite do modelo", "carregamento ótimo (Trefftz)", "Munk; Kroo 2001",
                "o plano de Trefftz dá o melhor caso; o núcleo Zig trata o dispositivo como uma superfície vertical "
                "por faixas e não reproduz o ganho no induzido", "", G)
        else:
            if best_d < -0.5:
                add("info", "vale a pena pôr winglet?", f"melhor: h/b ≈ {best_hb:.2f} → ΔD = {best_d:.1f} % no cruzeiro",
                    "ganho no induzido > atrito", f"induzido = {100 * k:.0f} % do arrasto de cruzeiro",
                    "se a envergadura não é limitada, uma extensão de ponta com o mesmo momento fletor ganha mais "
                    f"({float(np.min(t['dD_extensao_mesmo_M'])) * k:.1f} %)", G)
            else:
                add("info", "vale a pena pôr winglet?", "não neste C_L de cruzeiro",
                    "ganho no induzido > atrito", f"induzido = {100 * k:.0f} % do arrasto de cruzeiro", "", G)

    @staticmethod
    def _span(ac, span) -> dict:
        """c c_l / c_ref: lltdrek, elíptico e Schrenk (média da corda real e da elíptica)"""
        w = ac.wing
        S, c, b = ac.references()
        eta = np.linspace(0, 0.995, 60)
        out = {"eta": eta}
        if w is None:
            return out
        s = w.semispan
        CL = None
        if span is not None:
            yy = np.asarray(span["y"]) / s
            ccl = np.asarray(span["ccl"])
            out["lltdrek"] = np.interp(eta, yy, ccl, right=0.0)
            CL = 2 * _trapz(np.r_[ccl[0], ccl, 0.0] * c, np.r_[0.0, span["y"], s]) / S
        if CL is None:
            return out
        ell = 4 * S * CL / (math.pi * w.span) * np.sqrt(1 - eta ** 2) / c
        chord = np.array([w.chord_at(e * s) for e in eta])
        out["elíptica (ideal)"] = ell
        out["Schrenk (estimativa clássica)"] = 0.5 * (ell + chord * CL / c)
        return out


def _why_differ(a: str, b: str, key: str) -> str:
    notes = {
        "lltdrek": "lltdrek: só asa e EH (sem deriva e fuselagem), interação asa-EH calculada",
        "zig": "núcleo: faixas com C_Lα de Helmbold, downwash ε0 + dε/dα α, fuselagem por coeficientes",
        "asb_vlm": "VLM: superfícies finas sem fuselagem e sem estol",
        "asb_buildup": "AeroBuildup: soma por componentes com NeuralFoil e fuselagem",
        "asb_ll": "LiftingLine do ASB: polar do NeuralFoil (perfil real)",
    }
    extra = {"x_np_mac": " — o ponto neutro depende de dε/dα na cauda e do C_mα da fuselagem",
             "CLmax": " — o C_Lmax depende da polar 2D usada (modelo × NeuralFoil) e do estol na ponta",
             "CLa_fit": ""}[key]
    return f"{notes[a]}; {notes[b]}{extra}"

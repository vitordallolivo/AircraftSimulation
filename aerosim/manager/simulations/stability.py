"""Aba Estabilidade: estática (ponto neutro, margem, volumes de cauda, manche fixo), tesoura
(dimensionamento da EH pela margem estática e pelo controle), dinâmica (modos e MIL-F-8785C
em função de V, respostas) e dimensionamento de aileron, profundor e leme."""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero.geometry import RAYMER_TAIL_VOLUME
from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.stability import (Probe, aileron_sizing, elevator_sizing, lanchester, mil_check, min_tail, modes,
                               response, rudder_sizing, scissor, static_analysis)
from aerosim.stability.dynamic import doublet, pulse

from .base import SimulationBase, floats

MODES = ("curto_periodo", "fugoide", "dutch_roll", "rolamento", "espiral")
NIVEL = {1: "nível 1", 2: "nível 2", 3: "nível 3", 4: "pior que nível 3"}


class StabilitySimulation(SimulationBase):
    name = "stability"
    title = "Estabilidade"
    description = ("Estática (ponto neutro numérico e analítico, margem, V_H/V_V × Raymer), gráfico tesoura "
                   "(Torenbeek/Sadraey) para dimensionar a EH e a faixa de CG, dinâmica pelo modelo linear do "
                   "núcleo com MIL-F-8785C, e dimensionamento de aileron, profundor e leme.")

    def parameters(self):
        return [ParamSpec("V", "V de referência", 15.0, minimum=3, maximum=80, unit="m/s"),
                ParamSpec("Vs_list", "V da varredura dinâmica", "11, 13, 15, 17, 19, 21, 23", kind="floats", unit="m/s"),
                ParamSpec("cls", "classe (MIL-F-8785C)", "I", kind="choice", choices=("I", "II", "III", "IV")),
                ParamSpec("cat", "categoria de fase", "B", kind="choice", choices=("A", "B", "C")),
                ParamSpec("raymer", "tipo (volumes do Raymer)", "experimental (homebuilt)", kind="choice",
                          choices=tuple(RAYMER_TAIL_VOLUME)),
                ParamSpec("SM_min", "margem estática mínima", 5.0, minimum=0, maximum=40, unit="% CMA"),
                ParamSpec("SM_target", "margem estática desejada", 10.0, minimum=0, maximum=40, unit="% CMA"),
                ParamSpec("cg_fwd", "CG dianteiro desejado (−1: auto)", -1.0, minimum=-1, maximum=100, unit="% CMA"),
                ParamSpec("cg_aft", "CG traseiro desejado (−1: auto)", -1.0, minimum=-1, maximum=100, unit="% CMA"),
                ParamSpec("CL_frac", "C_L de pouso / C_Lmax", 0.9, minimum=0.3, maximum=1.0),
                ParamSpec("theta_dd", "aceleração de rotação", 10.0, minimum=1, maximum=40, unit="°/s²"),
                ParamSpec("eta_o", "aileron: fim (fração de b/2)", 0.95, minimum=0.5, maximum=1.0),
                ParamSpec("Vw", "vento cruzado (−1: 0,2 V_S)", -1.0, minimum=-1, maximum=20, unit="m/s"),
                ParamSpec("scissor", "calcular a tesoura", True, kind="bool"),
                ParamSpec("T_resp", "duração das respostas", 12.0, minimum=2, maximum=120, unit="s")]

    def plots(self):
        return [PlotSpec("cm", "C_m(α) no CG", "alpha", ("Cm_de_up", "Cm_de0", "Cm_de_down"), "α (°)", "C_m",
                         live=False, source="series:cm_alpha"),
                PlotSpec("trim", "Profundor de equilíbrio (manche fixo)", "V", ("de",), "V (m/s)", "δe (°)", live=False,
                         source="series:trim"),
                PlotSpec("tes", "Gráfico tesoura", "Sh_S", ("fwd_ctrl", "fwd_rot", "aft", "np", "cg_fwd", "cg_aft"),
                         "x_CG (% CMA)", "S_h/S", live=False, source="series:tesoura", swap=True),
                PlotSpec("roots", "Raízes × V (plano s)", "re", ("im",), "Re (1/s)", "Im (rad/s)", live=False,
                         source="series:raiz_*", scatter=True),
                PlotSpec("zeta", "Amortecimento × V", "V", tuple(f"zeta_{m}" for m in ("curto_periodo", "fugoide", "dutch_roll")),
                         "V (m/s)", "ζ", live=False, source="series:modos_V"),
                PlotSpec("tau", "Rolamento τ_R e espiral T2 × V", "V", ("tau_rolamento", "t2_espiral"), "V (m/s)", "s",
                         live=False, source="series:modos_V"),
                PlotSpec("rlon", "Resposta a doublet de profundor", "t", ("q", "theta", "u", "w"), "t (s)",
                         "°/s, °, m/s", live=False, source="series:resp_lon"),
                PlotSpec("rlat", "Resposta a pulso de aileron", "t", ("p", "r", "phi", "v"), "t (s)", "°/s, °, m/s",
                         live=False, source="series:resp_lat"),
                PlotSpec("ail", "Aileron: tempo até o ângulo pedido", "eta_i", tuple(f"t_ca/c={r:.2f}" for r in (0.15, 0.20, 0.25, 0.30)) + ("requisito",), "início η_i (b/2)",
                         "t (s)", live=False, source="series:aileron"),
                PlotSpec("ele", "Profundor: δe pedido", "ce_c", ("de_pouso", "de_rotacao", "de_max"), "c_e/c",
                         "δe (°)", live=False, source="series:profundor"),
                PlotSpec("rud", "Leme: δr pedido", "cr_c", ("dr_vento", "dr_motor_parado", "dr_max"), "c_r/c", "δr (°)",
                         live=False, source="series:leme")]

    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        ac.apply_constraints()
        P = lambda k: self.param(ctx, k)
        V = P("V")
        series, summ = {}, {}
        de_max = math.radians(ac.autopilot.de_max)
        da_max = math.radians(ac.autopilot.da_max)
        dr_max = math.radians(ac.autopilot.dr_max)
        Vlist = floats(P("Vs_list"))
        ctx.on_progress(0.02, "estática")
        with Probe(ctx.backend, ac) as pr:
            CLmax = pr.CLmax(V)
            Vs = pr.Vs(CLmax)
            st, ss = static_analysis(pr, V, de_max_deg=ac.autopilot.de_max, V_trim=np.arange(max(Vs * 1.05, 3), max(Vlist + [V]) + 0.01, 0.5))
            series.update(ss)
            summ.update({f"[estática] {k}": v for k, v in st.items()})
            vh, vv = RAYMER_TAIL_VOLUME[P("raymer")]
            summ["[estática] V_H, V_V típicos (Raymer)"] = [vh, vv]
            summ["[estática] C_Lmax, V_S (m/s)"] = [CLmax, Vs]
            cg_pct = pr.frac(pr.cg[0])
            xnp = st["x_np numérico (% CMA)"]
            summ["[estática] CG para a margem desejada (% CMA)"] = xnp - P("SM_target")
            # faixa de CG: com/sem carga e líquido
            cgs = [cg_pct]
            for mod in ("sem carga", "sem líquido"):
                a2 = ac.copy()
                if mod == "sem carga":
                    a2.payload.enabled = False
                else:
                    a2.tanks = []
                with Probe(ctx.backend, a2) as p2:
                    cgs.append(p2.frac(p2.cg[0]))
            summ["[estática] CG: atual, sem carga, sem líquido (% CMA)"] = cgs
            cg_fwd = P("cg_fwd") if P("cg_fwd") >= 0 else min(cgs) - 3.0
            cg_aft = P("cg_aft") if P("cg_aft") >= 0 else max(cgs) + 3.0
            summ["[tesoura] faixa de CG pedida (% CMA)"] = [cg_fwd, cg_aft]
            VR = ac.takeoff.VR if ac.takeoff.VR > 0 else 1.1 * Vs
            V_land = 1.3 * Vs
            # ---------------- comandos
            ctx.on_progress(0.15, "comandos")
            Vroll = V if P("cat") != "C" else V_land
            o, s_ = aileron_sizing(pr, Vroll, P("cls"), P("cat"), da_max, P("eta_o"))
            series["aileron"] = s_
            summ.update({f"[aileron] {k}": v for k, v in o.items()})
            o, s_ = elevator_sizing(pr, V_land, VR, cg_fwd, P("CL_frac") * pr.CLmax(V_land, de=-de_max), de_max,
                                    P("theta_dd"))
            if s_:
                series["profundor"] = s_
            summ.update({f"[profundor] {k}": v for k, v in o.items()})
            Vw = P("Vw") if P("Vw") >= 0 else 0.2 * Vs
            o, s_ = rudder_sizing(pr, V_land, Vw, 1.2 * Vs, dr_max)
            if s_:
                series["leme"] = s_
            summ.update({f"[leme] {k}": v for k, v in o.items()})
        # ---------------- tesoura
        has_ht = any(s.role == "htail" and s.enabled and len(s.sections) > 1 for s in ac.surfaces)
        if P("scissor") and not has_ht:
            summ["[tesoura]"] = "sem EH: a tesoura não se aplica (asa voadora: a margem vem do enflechamento/torção e do CG)"
        if P("scissor") and has_ht:
            ctx.on_progress(0.3, "gráfico tesoura")
            sc = scissor(ctx.backend, ac, V, P("SM_min") / 100, P("CL_frac"), de_max, VR, P("theta_dd"))
            sc["cg_fwd"] = np.full(len(sc["k"]), cg_fwd)
            sc["cg_aft"] = np.full(len(sc["k"]), cg_aft)
            series["tesoura"] = sc
            i1 = int(np.argmin(np.abs(sc["k"] - 1.0)))
            summ["[tesoura] S_h/S atual"] = float(sc["Sh_S"][i1])
            summ["[tesoura] limites atuais: dianteiro, traseiro (% CMA)"] = [float(np.interp(1.0, sc["k"], sc["fwd"])),
                                                                         float(np.interp(1.0, sc["k"], sc["aft"]))]
            summ["[tesoura] S_h/S mínimo para a faixa de CG"] = min_tail(sc, cg_fwd, cg_aft)
        # ---------------- dinâmica
        rows, roots = [], {}
        lin_ref = None
        for k, v in enumerate(Vlist + [V]):
            ctx.check()
            ctx.on_progress(0.6 + 0.35 * k / (len(Vlist) + 1), f"modelo linear em V = {v:.1f} m/s")
            with ctx.backend.open_session() as s:
                from aerosim.model.compile import compile_aircraft
                s.configure(compile_aircraft(ac))
                lm = s.linearize(v)
            if k == len(Vlist):
                lin_ref = lm
                break
            if not lm["ok"]:
                continue
            md = modes(lm["A"])
            r = {"V": v}
            for name in MODES:
                m = md.get(name) or {}
                r[f"zeta_{name}"] = m.get("zeta", np.nan)
                r[f"wn_{name}"] = m.get("wn", np.nan)
                if m:
                    roots.setdefault(name, {"re": [], "im": []})
                    roots[name]["re"] += [m["re"], m["re"]]
                    roots[name]["im"] += [m["im"], -m["im"]]
            r["tau_rolamento"] = (md.get("rolamento") or {}).get("tau", np.nan)
            es = md.get("espiral") or {}
            r["t2_espiral"] = es.get("t_double", np.nan) if es.get("re", -1) > 0 else -es.get("t_half", np.nan)
            rows.append(r)
        if rows:
            series["modos_V"] = {k: np.array([r[k] for r in rows]) for k in rows[0]}
        for name, d in roots.items():
            series[f"raiz_{name}"] = {"re": np.array(d["re"]), "im": np.array(d["im"])}
        if lin_ref is not None and lin_ref["ok"]:
            md = modes(lin_ref["A"])
            for name in MODES:
                m = md.get(name) or {}
                if not m:
                    continue
                if m["im"] > 1e-9:
                    summ[f"[dinâmica V={V:g}] {name}: ω_n (rad/s), ζ, período (s)"] = [m["wn"], m["zeta"], m["period"]]
                elif m["re"] < 0:
                    summ[f"[dinâmica V={V:g}] {name}: τ (s), tempo p/ metade (s)"] = [m["tau"], m["t_half"]]
                else:
                    summ[f"[dinâmica V={V:g}] {name}: INSTÁVEL, tempo p/ dobrar (s)"] = m["t_double"]
            for row in mil_check(md, P("cls"), P("cat")):
                summ[f"[MIL-F-8785C {P('cls')}/{P('cat')}] {row['criterio']}"] = (
                    f"{_fmt(row['valor'])} (nível 1: {row['exigido']}) → {NIVEL[row['nivel']]}")
            with Probe(ctx.backend, ac) as pr:
                c = pr.C(V, lin_ref["alpha"])
            la = lanchester(V, c["CL"] / c["CD"] if c["CD"] > 0 else 0)
            summ["[dinâmica] fugóide por Lanchester: ω_n, ζ"] = [la["wn"], la["zeta"]]
            summ["[dinâmica] equilíbrio: α, δe (°), acelerador"] = [math.degrees(lin_ref["alpha"]),
                                                                   math.degrees(lin_ref["de"]), lin_ref["thr"]]
            T = P("T_resp")
            series["resp_lon"] = response(lin_ref["A"], lin_ref["B"], doublet(math.radians(2), channel=0), T)
            series["resp_lat"] = response(lin_ref["A"], lin_ref["B"], pulse(math.radians(5), channel=1), T)
            series["A"] = {"estado": ["u", "v", "w", "p", "q", "r", "phi", "theta"],
                           **{n: lin_ref["A"][:, i] for i, n in enumerate(("u", "v", "w", "p", "q", "r", "phi", "theta"))}}
        else:
            summ["[dinâmica] equilíbrio"] = f"trimagem não convergiu em V = {V}"
        return SimResult(series=series, summary=summ)


def _fmt(v):
    if isinstance(v, (list, tuple)):
        return ", ".join(_fmt(x) for x in v)
    return f"{v:.3g}" if isinstance(v, float) else str(v)

"""Desempenho por cálculo (sem simulação no tempo): envelope de voo por altitude, potências,
subida, descida (planeio), curva × velocidade e descarga da bateria — os métodos da planilha
de desempenho, calculados no núcleo Zig (`core/src/sim/simple_perf.zig` e `envelope.zig`).

A polar vem do módulo de aerodinâmica (a mesma da aba Aerodinâmica, ajustada como
C_D = C_D0 + K C_L²) ou é digitada (como na planilha). A tração disponível vem do modelo de
propulsão da aeronave (motor + hélice ou polinômio), ao nível do mar, corrigida por (ρ/ρ0)^m.
A análise de curva SIMULADA (raio mínimo com piloto, vento e transitório) fica na aba Missão;
esta aqui é o complemento de equilíbrio.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero import parabolic_polar
from aerosim.aero.service import aircraft_polar
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model

from .base import floats
from .envelope import EnvelopeSimulation
from .thrust import thrust_curves

POLARS = ("aba Aerodinâmica (da aeronave)", "manual (como na planilha)")
ALT_COLORS = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b"]
BANK_COLORS = ["#9ecae1", "#6baed6", "#4292c6", "#2171b5", "#08519c", "#08306b", "#252525", "#636363"]
G0 = 9.80665
GE, GS, GB = "Envelope de voo (por altitude)", "Cálculo simples (planilha)", "Bateria (Peukert)"


class PerformanceSimulation(EnvelopeSimulation):
    tab = True
    name = "performance"
    title = "Desempenho"
    description = ("Sem simulação no tempo: envelope de voo por altitude, potências disponível × requerida, subida, "
                   "descida (planeio), raio de curva × velocidade e autonomia da bateria. A curva simulada (com piloto e "
                   "vento) está na aba Missão.")

    def parameters(self):
        return self.parameters_for(None, {})

    def parameters_for(self, ac, values=None):
        values = values or {}
        env = []
        for p in EnvelopeSimulation.parameters(self):
            p.group = GE
            env.append(p)
        P = [ParamSpec("polar", "Polar", POLARS[0], kind="choice", choices=POLARS, rebuild=True, group=GS,
                       help="a polar é do módulo de aerodinâmica; 'manual' para reproduzir a planilha")]
        if values.get("polar", POLARS[0]) == POLARS[1]:
            P += [ParamSpec("CD0", "C_D0", 0.0254, minimum=0.001, maximum=0.5, group=GS),
                  ParamSpec("K", "K (C_Di = K C_L²)", 0.0596, minimum=0.001, maximum=1, group=GS),
                  ParamSpec("CLmax", "C_Lmax", 1.6, minimum=0.3, maximum=4, group=GS)]
        P += [ParamSpec("mass", "Massa (0 = da aeronave)", 0.0, minimum=0, maximum=1000, unit="kg", group=GS),
              ParamSpec("h_list", "Altitudes", "0, 900", kind="floats", unit="m", group=GS),
              ParamSpec("T0", "Temperatura no nível de referência", 15.0, minimum=-60, maximum=60, unit="°C", group=GS),
              ParamSpec("rho_exp", "Tração ∝ (ρ/ρ0)^m: m", 1.0, minimum=0, maximum=2, group=GS),
              ParamSpec("banks", "Inclinações para R × V", "5, 10, 15, 20, 25, 30, 35, 40", kind="floats", unit="°",
                        group=GS),
              ParamSpec("bat_Rt", "Tempo de descarga nominal R_t", 1.0, minimum=0.01, maximum=100, unit="h", group=GB),
              ParamSpec("bat_n", "Expoente de Peukert n", 1.05, minimum=1.0, maximum=1.6, group=GB),
              ParamSpec("bat_eta", "Rendimento total (motor, ESC, hélice)", 0.6, minimum=0.05, maximum=1, group=GB)]
        return env + P

    def plots(self):
        return self.plots_for(None, {})

    def plots_for(self, ac, values=None):
        env = EnvelopeSimulation.plots(self)
        s = lambda key, title, xl, yl: PlotSpec(key, title, "V", ("y",), xl, yl, live=False, source=f"series:{key}_*")
        return env[:2] + [
            s("spot", "Potência disponível × requerida (cálculo simples)", "V (m/s)", "potência (W)"),
            s("stra", "Tração disponível × requerida", "V (m/s)", "tração (N)"),
            s("ssub", "Razão de subida (★ máxima)", "V (m/s)", "RC (m/s)"),
            s("sgam", "Ângulo de subida (★ máximo)", "V (m/s)", "γ (°)"),
            s("sdes", "Descida em planeio: razão de descida × V de planeio (★ mínima)", "V de planeio (m/s)",
              "razão de descida (m/s)"),
            s("sgpl", "Ângulo de planeio × V (★ menor ângulo = E máx.)", "V de planeio (m/s)", "ângulo de planeio (°)"),
            s("scur", "Raio de curva × V por inclinação φ (limites de estol e de tração; ★ R mínimo)", "V (m/s)", "R (m)"),
            s("snv", "Fator de carga × V: limite de estol e de tração", "V (m/s)", "n (g)"),
            s("sbat", "Autonomia da bateria na potência requerida (★ máxima)", "V (m/s)", "autonomia (min)"),
            s("sran", "Alcance com a bateria (★ máximo)", "V (m/s)", "alcance (km)")] + env[2:]

    def run(self, ctx: RunContext) -> SimResult:
        res = EnvelopeSimulation.run(self, ctx)
        ac, info = self.prepare(ctx)
        P = lambda k: self.param(ctx, k)
        model = build_model(ac)
        if P("polar") == POLARS[1]:
            CD0, K, CLmax, src = P("CD0"), P("K"), P("CLmax"), "manual"
        else:
            ap, src = aircraft_polar(ctx.backend, model, 12.0, ctx.shared)
            fit = parabolic_polar(ap)
            CD0, K, CLmax = fit["CD0"], fit["k"], fit["CLmax"]
        m = P("mass") or info["mass"]
        V_lo, V_hi = max(P("V_lo"), 0.5), P("V_hi")
        tc = thrust_curves(ctx.backend, ac, V_max=V_hi + 1.0, dV=0.5)
        Vt = next(iter(next(iter(tc.values())).values()))["V"] if tc else np.array([0.0, V_hi])
        Tt = sum(d[1.0]["T"] for d in tc.values()) if tc else np.zeros_like(Vt)
        units = [u for u in ac.propulsion if u.enabled]
        tilt = math.radians(np.mean([u.tilt for u in units])) if units else 0.0
        bat = units[0].battery if units else None
        banks = floats(P("banks"))[:8]
        n_load = P("n_load") or ac.performance.load_factor
        base = dict(W=m * G0, S=model.S, CD0=CD0, K=K, CLmax=CLmax, rho0=ac.performance.rho0, T0=273.15 + P("T0"),
                    phi_T=tilt, rho_exp=P("rho_exp"), V_lo=V_lo, V_hi=V_hi, dV=0.1, n_load=n_load,
                    bat_Rt=P("bat_Rt"), bat_n=P("bat_n"), bat_eta=P("bat_eta"),
                    bat_C=(bat.capacity_mAh / 1000.0 * (len(units) if not ac.shared_battery else 1)) if bat else 1.0,
                    bat_V=bat.Voc if bat else 1.0, thr_V=list(Vt[:128]), thr_T=list(Tt[:128]),
                    bank=[math.radians(b) for b in banks])
        S, checks = res.series, list(res.checks)
        summ = res.summary
        summ["polar (cálculo simples)"] = f"{src}: C_D0 = {CD0:.4f}, K = {K:.4f}, C_Lmax = {CLmax:.2f}"
        hs = floats(P("h_list"))
        for j, h in enumerate(hs):
            ctx.check()
            rows, sm = ctx.backend.simple_performance(dict(base, h=h))
            c = ALT_COLORS[j % len(ALT_COLORS)]
            lab = f"h = {h:g} m"
            ok = rows["ok"] > 0
            V = rows["V"]
            nan = lambda a: np.where(ok, a, np.nan)
            S[f"spot_{lab}: disponível P_d"] = dict(V=V, y=rows["Pd"], _color=c, _width=2)
            S[f"spot_{lab}: requerida P_r"] = dict(V=V, y=nan(rows["Pr"]), _color=c, _dash="dash")
            S[f"stra_{lab}: disponível T_d"] = dict(V=V, y=rows["Td"], _color=c, _width=2)
            S[f"stra_{lab}: requerida T_r"] = dict(V=V, y=nan(rows["Tr"]), _color=c, _dash="dash")
            S[f"ssub_{lab}"] = dict(V=V, y=nan(rows["RC"]), _color=c, _width=2)
            S[f"sgam_{lab}"] = dict(V=V, y=nan(np.degrees(rows["gam"])), _color=c, _width=2)
            S[f"sdes_{lab}"] = dict(V=nan(rows["V_glide"]), y=nan(rows["sink"]), _color=c, _width=2)
            S[f"sgpl_{lab}"] = dict(V=nan(rows["V_glide"]), y=nan(np.degrees(rows["gam_glide"])), _color=c, _width=2)
            S[f"sbat_{lab}"] = dict(V=V, y=nan(60 * rows["t_bat"]), _color=c, _width=2)
            S[f"sran_{lab}"] = dict(V=V, y=nan(rows["range_bat"] / 1000), _color=c, _width=2)
            for pre in ("spot_", "stra_", "ssub_", "sgam_", "sbat_", "sran_", "scur_", "snv_"):
                S[f"{pre}V_e a {h:g} m"] = dict(_vline=sm["Vs"], _color=c, _dash="dot", _nolegend=1)
            star = lambda x, y: dict(V=np.array([x]), y=np.array([y]), _symbol="star", _color=c)
            S[f"ssub_★ RC máx. {sm['RCmax']:.2f} m/s a {sm['V_RCmax']:.1f} m/s ({lab})"] = star(sm["V_RCmax"], sm["RCmax"])
            S[f"sgam_★ γ máx. {math.degrees(sm['gmax']):.1f}° ({lab})"] = star(sm["V_gmax"], math.degrees(sm["gmax"]))
            S[f"sdes_★ descida mín. {sm['sink_min']:.2f} m/s ({lab})"] = star(sm["V_sink_min"], sm["sink_min"])
            S[f"sgpl_★ E máx. {sm['Emax']:.1f} ({lab})"] = star(sm["V_glide_min"], math.degrees(sm["glide_min"]))
            S[f"sbat_★ {60 * sm['t_max']:.1f} min a {sm['V_tmax']:.1f} m/s ({lab})"] = star(sm["V_tmax"], 60 * sm["t_max"])
            S[f"sran_★ {sm['range_max'] / 1000:.2f} km ({lab})"] = star(sm["V_range_max"], sm["range_max"] / 1000)
            if j == 0:                                   # curva: na primeira altitude
                for k, b in enumerate(banks):
                    R = rows[f"R_bank_{k}"]
                    n = 1 / math.cos(math.radians(b))
                    possible = ok & (rows["n_stall"] >= n)
                    S[f"scur_φ = {b:g}° (n = {n:.2f})"] = dict(V=V, y=np.where(possible, R, np.nan),
                                                               _color=BANK_COLORS[k % len(BANK_COLORS)], _width=1.4)
                S["scur_limite de estol (C_Lmax)"] = dict(V=V, y=np.where(np.isfinite(rows["R_stall"]), rows["R_stall"],
                                                                          np.nan), _color="#d62728", _width=2.5)
                S["scur_limite de tração (curva sustentada)"] = dict(
                    V=V, y=np.where(np.isfinite(rows["R_sust"]), rows["R_sust"], np.nan), _color="#ff7f0e", _width=2.5)
                if sm["R_min"] > 0:
                    S[f"scur_★ R mín. = {sm['R_min']:.1f} m a {sm['V_Rmin']:.1f} m/s (n = {sm['n_Rmin']:.2f})"] = dict(
                        V=np.array([sm["V_Rmin"]]), y=np.array([sm["R_min"]]), _symbol="star", _color="#ffcc00",
                        _size=22)
                S["snv_limite de estol n = q S C_Lmax / W"] = dict(V=V, y=rows["n_stall"], _color="#d62728", _width=2)
                S["snv_limite de tração (sustentada)"] = dict(V=V, y=rows["n_sust"], _color="#ff7f0e", _width=2)
                S[f"snv_n de projeto = {n_load:g}"] = dict(_hline=n_load, _color="#000000", _dash="dash")
                S[f"snv_V* = V_e √n = {sm['Vman']:.1f} m/s"] = dict(_vline=sm["Vman"], _color="#000000", _dash="dot")
                rmax_plot = 4 * max(sm["R_min"], 10.0)
                for k in [k for k in S if k.startswith("scur_") and "y" in S[k]]:
                    S[k]["y"] = np.where(S[k]["y"] <= rmax_plot, S[k]["y"], np.nan)
            S[f"simples_{lab}"] = rows
            pre = f"[{lab}] "
            summ.update({pre + "ρ (kg/m³)": sm["rho"], pre + "V_e (m/s)": sm["Vs"], pre + "V* manobra (m/s)": sm["Vman"],
                         pre + "V_min, V_max (P_d = P_r)": [sm["Vmin"], sm["Vmax"]],
                         pre + "RC máx. (m/s) @ V": [sm["RCmax"], sm["V_RCmax"]],
                         pre + "γ máx. (°) @ V": [math.degrees(sm["gmax"]), sm["V_gmax"]],
                         pre + "E máx., menor ângulo de planeio (°)": [sm["Emax"], math.degrees(sm["glide_min"])],
                         pre + "menor razão de descida (m/s) @ V": [sm["sink_min"], sm["V_sink_min"]],
                         pre + "R mín. (m), V, n, φ (°)": [sm["R_min"], sm["V_Rmin"], sm["n_Rmin"],
                                                           math.degrees(sm["phi_Rmin"])],
                         pre + "autonomia máx. (min) @ V; fórmula de Traub": [60 * sm["t_max"], sm["V_tmax"],
                                                                              60 * sm["t_max_formula"]],
                         pre + "alcance máx. (km) @ V": [sm["range_max"] / 1000, sm["V_range_max"]]})
            G = f"Desempenho a {h:g} m"
            if not sm["ceiling_ok"]:
                checks.append(Check("falha", f"voo nivelado a {h:g} m", "P_d < P_r em todas as V", "P_d ≥ P_r",
                                    "a potência disponível não cobre a requerida em nenhuma velocidade",
                                    "mais tração/potência, menos massa ou menos arrasto (C_D0)", G))
            else:
                checks.append(Check("ok" if sm["RCmax"] > 0.5 else "atencao", f"razão de subida máxima a {h:g} m",
                                    f"{sm['RCmax']:.2f} m/s a {sm['V_RCmax']:.1f} m/s", "> 0,5 m/s",
                                    "sobra de potência (P_d − P_r)/W" if sm["RCmax"] <= 0.5 else "",
                                    "mais potência ou menos arrasto" if sm["RCmax"] <= 0.5 else "", G))
                checks.append(Check("info", f"faixa de velocidades a {h:g} m", f"{sm['Vmin']:.1f} a {sm['Vmax']:.1f} m/s",
                                    "P_d ≥ P_r e V ≥ V_e", "", "", G))
            checks.append(Check("info", f"raio mínimo (curva sustentada) a {h:g} m", f"{sm['R_min']:.1f} m",
                                f"φ = {math.degrees(sm['phi_Rmin']):.0f}°, n = {sm['n_Rmin']:.2f}",
                                "fórmula fechada com o T/W máximo (a curva simulada está na aba Missão)", "", G))
        return SimResult(log=res.log, series=S, summary=summ, events=res.events, status=res.status, checks=checks)

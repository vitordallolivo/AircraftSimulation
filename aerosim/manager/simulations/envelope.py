"""Envelope de voo por altitude (adaptado do Envelope_main original) + tabela de desempenho.

Para cada altitude: ρ(h), V_min e V_max onde a potência disponível cruza a requerida, V_e (estol),
V* = V_e √n (manobra), V_cru, e o teto absoluto (V_min = V_max). Nada é integrado no tempo.

Métodos (o cálculo fica no núcleo interno, `core/src/sim/envelope.zig`):
  planilha        as fórmulas do original: polar parabólica C_D = C_Dpw + C_Dph S_h/S_w + K C_L², tração
                  do polinômio, ângulo de cruzeiro fixo. "Reproduzir o original" mantém ρ/ρ0 no arrasto e
                  a expressão de densidade do código; desligado usa ρ e a ISA.
  modelo completo trimagem da aeronave inteira (painéis, momentos, profundor) em cada (h, V).

É a subaba "Voo nivelado e envelopes" de Desempenho: os envelopes dos dois métodos, sobrepostos e separados. O V-n é
de Cargas (T13), não aparece aqui.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.aircraft import Aircraft
from aerosim.model.universal import build_model

from .base import SimulationBase

METHODS = ("planilha", "modelo completo", "os dois")
CURVES = (("Vmin", "#1f77b4"), ("Vmax", "#d62728"), ("Ve", "#2ca02c"), ("Vman", "#ff7f0e"), ("Vcru", "#9467bd"))
ATMOS = ("ISA", "fórmula da planilha")
BELOW = ("continua (polar sem estol)", "corta no estol")
METHOD_HELP = ("planilha: as fórmulas do Envelope_main original — polar parabólica C_D = C_Dpw + C_Dph·S_h/S_w + "
               "K·C_L² com os C_Dp e o K da planilha, ângulo de cruzeiro fixo, sem equilibrar o momento (a EH não "
               "trima). Modelo completo: o avião inteiro trimado em cada (h, V) — painéis, momentos, profundor e o "
               "estol de cada seção —, então cobra o arrasto de trimagem e costuma dar teto menor e V_min maior. "
               "A tração disponível é a mesma nos dois (as unidades propulsoras do avião com ρ(h)). "
               "Escolha um dos dois ou 'os dois' para comparar.")


def sheet_config(ac: Aircraft) -> dict:
    """dados do método da planilha a partir do modelo universal (asa, EH) e de ac.performance"""
    model = build_model(ac)
    perf = model.aircraft.performance
    w, h = model.wing, model.htail
    wa, ha = model.aircraft.surfaces[w.index], (model.aircraft.surfaces[h.index] if h is not None else None)
    e0, de = model.downwash
    if h is not None and h.downwash:
        e0, de = h.eps0, h.depsda
    elif ha is not None:
        e0 = math.radians(ha.eps0) if ha.eps0 is not None else e0
        de = ha.depsda if ha.depsda is not None else de
    K = perf.K if perf.K is not None else 1.0 / (math.pi * w.oswald * w.AR)
    return dict(
        Sw=w.total_area, CLa_w=w.CLa, CL0_w=w.CL0, CLmax_w=w.CLmax, iw=math.radians(wa.incidence),
        Sh=h.total_area if h is not None else 0.0, CLa_h=h.CLa if h else 0.0, CL0_h=h.CL0 if h else 0.0,
        CLmax_h=h.CLmax if h else 0.0, ih=math.radians(ha.incidence) if ha is not None else 0.0, depsda=de, eps0=e0,
        cdp_x=perf.cdp_x, cdpw_c1=perf.cdp_wing[0], cdpw_c2=perf.cdp_wing[1],
        cdph_c1=perf.cdp_htail[0], cdph_c2=perf.cdp_htail[1], K=K,
        rho0=perf.rho0, n_load=perf.load_factor, alpha_cruise=math.radians(perf.alpha_cruise))


class EnvelopeSimulation(SimulationBase):
    tab = True
    name = "envelope"
    title = "Voo nivelado e envelopes"
    area = "desempenho"
    description = ("Por altitude: V_min e V_max (P_d = P_r), V_e, V* = V_e√n, V_cru e o teto absoluto. "
                   "Método da planilha (Envelope_main) ou trimagem da aeronave completa.")

    def parameters(self):
        return [ParamSpec("method", "Método", "os dois", kind="choice", choices=METHODS, help=METHOD_HELP,
                          rebuild=True),
                ParamSpec("below", "Abaixo do estol (modelo completo)", BELOW[0], kind="choice", choices=BELOW,
                          help="continua: abaixo do V_e a trimagem usa a polar sem estol, só para achar onde a "
                               "potência disponível cruza a requerida e mostrar a curva inteira (como a planilha). "
                               "Esse trecho não é voável: o mínimo voável é max(V_min, V_e). Corta: como antes, o "
                               "modelo para no estol e o V_min fica colado no V_e."),
                ParamSpec("atmos", "Atmosfera", "ISA", kind="choice", choices=ATMOS),
                ParamSpec("faithful", "igual ao original", False, kind="bool",
                          help="liga: mesmas contas do Envelope_main, para comparar com resultados antigos"),
                ParamSpec("h_step", "Passo de altitude", 50.0, minimum=1, maximum=1000, unit="m"),
                ParamSpec("h_max", "Altitude máxima", 6000.0, minimum=50, maximum=20000, unit="m"),
                ParamSpec("V_lo", "V inicial", 4.0, minimum=0.5, maximum=100, unit="m/s"),
                ParamSpec("V_hi", "V final", 30.0, minimum=1, maximum=200, unit="m/s"),
                ParamSpec("dV", "Grade de V (depois bisseção)", 0.05, minimum=0.001, maximum=2, unit="m/s"),
                ParamSpec("tol", "Tolerância de V", 1e-5, minimum=1e-8, maximum=0.1, unit="m/s"),
                ParamSpec("n_load", "Fator de carga n (0 = da aeronave)", 0.0, minimum=0, maximum=10),
                ParamSpec("alpha_cruise", "ângulo de cruzeiro", "", kind="floats", unit="°", help="vazio = o da aeronave"),
                ParamSpec("table", "Tabela de desempenho ao nível do mar", True, kind="bool")]

    def parameters_for(self, aircraft, values=None):
        """com só a planilha, o campo "abaixo do estol" (do modelo completo) some; o ângulo de cruzeiro vem do avião"""
        ps = self.parameters()
        if aircraft is not None:
            ps = [ParamSpec("alpha_cruise", "ângulo de cruzeiro", f"{aircraft.performance.alpha_cruise:g}",
                            kind="floats", unit="°", help="começa com o do avião (Montagem → desempenho); mudar aqui "
                            "vale só para esta análise. Planilha: V em que a sustentação nesse α iguala o peso. "
                            "Modelo completo: V em que o α de equilíbrio é esse")
                  if p.key == "alpha_cruise" else p for p in ps]
        if (values or {}).get("method") == "planilha":
            ps = [p for p in ps if p.key != "below"]
        return ps

    def plots_for(self, aircraft, values=None):
        """a comparação só aparece com os dois métodos"""
        ps = self.plots()
        if (values or {}).get("method", "os dois") != "os dois":
            ps = [p for p in ps if p.key != "env_c"]
        return ps

    def plots(self):
        s = "series:perf"
        return [PlotSpec("env_c", "Envelopes: planilha (—) × modelo completo (- -)", "V", ("h",), "velocidade (m/s)",
                         "altitude (m)", live=False, source="series:envcmp_*"),
                PlotSpec("env_p", "Envelope — planilha", "h", ("Vmin", "Vmax", "Ve", "Vman", "Vcru"),
                         "velocidade (m/s)", "altitude (m)", live=False, source="series:envelope_planilha", swap=True),
                PlotSpec("env_m", "Envelope — modelo completo", "h", ("Vmin", "Vmax", "Ve", "Vman", "Vcru"),
                         "velocidade (m/s)", "altitude (m)", live=False, source="series:envelope_modelo", swap=True),
                PlotSpec("pot0", "Potência disponível × requerida (h = 0)", "V", ("Pd", "Pr"), "V (m/s)", "W",
                         live=False, source="series:potencia_h0*"),
                PlotSpec("potT", "Potência perto do teto", "V", ("Pd", "Pr"), "V (m/s)", "W", live=False,
                         source="series:potencia_teto*"),
                PlotSpec("thr", "Acelerador e α nivelado (h = 0, modelo)", "V", ("thr_level", "alpha_level"),
                         "V (m/s)", "— / graus", live=False, source=s),
                PlotSpec("roc", "Razão de subida máx. e de planeio", "V", ("roc_max", "roc_idle"), "V (m/s)", "m/s",
                         live=False, source=s),
                PlotSpec("acr", "α de equilíbrio × V (h = 0) e o ângulo de cruzeiro", "V", ("y",), "V (m/s)", "α (°)",
                         live=False, source="series:acr_*"),
                PlotSpec("raio", "Raio mínimo: estol e sustentada", "V", ("R_stall", "R_sust"), "V (m/s)", "m",
                         live=False, source=s)]

    def _cfg(self, ctx, ac, method: str) -> dict:
        cfg = sheet_config(ac)
        faithful = bool(self.param(ctx, "faithful"))
        atmos = self.param(ctx, "atmos")
        if faithful and method == "planilha":
            atmos = "fórmula da planilha"
        cfg.update(method=0 if method == "planilha" else 1, atmos=ATMOS.index(atmos), faithful=int(faithful),
                   below_stall=int(method != "planilha" and ctx.params.get("below", BELOW[0]) == BELOW[0]),
                   h_step=self.param(ctx, "h_step"), h_max=self.param(ctx, "h_max"), V_lo=self.param(ctx, "V_lo"),
                   V_hi=self.param(ctx, "V_hi"), tol=self.param(ctx, "tol"),
                   dV=self.param(ctx, "dV") if method == "planilha" else max(self.param(ctx, "dV"), 0.5))
        if self.param(ctx, "n_load") > 0:
            cfg["n_load"] = self.param(ctx, "n_load")
        ac_str = str(self.param(ctx, "alpha_cruise")).strip()
        if ac_str:
            cfg["alpha_cruise"] = math.radians(float(ac_str.replace(",", ".")))
        return cfg

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        method = self.param(ctx, "method")
        todo = ["planilha", "modelo completo"] if method == "os dois" else [method]
        series: dict = {}
        summary: dict = {}
        checks: list = []
        h0: dict = {}                                   # método → (V_min, V_max, V_cru) em h = 0
        model = build_model(ac)
        for i, m in enumerate(todo):
            ctx.check()
            ctx.on_progress(i / (len(todo) + 1), f"envelope: {m}")
            key = "planilha" if m == "planilha" else "modelo"
            cfg = self._cfg(ctx, ac, m)
            with ctx.backend.session_for(model) as s:
                rows, ceiling = s.envelope(cfg)
                c0 = s.envelope_curve(cfg, 0.0, 300)
                cT = s.envelope_curve(cfg, max(ceiling - cfg["h_step"], 0.0), 300)
            series[f"envelope_{key}"] = {k: rows[k] for k in ("h", "rho", "Vmin", "Vmax", "Ve", "Vman", "Vcru", "Td_max")}
            for k, color in CURVES:                     # os dois métodos no mesmo gráfico
                series[f"envcmp_{k} ({m})"] = dict(V=np.asarray(rows[k], float), h=np.asarray(rows["h"], float),
                                                   _color=color, _width=2.0, _dash=None if key == "planilha" else "dash")
            series[f"potencia_h0 ({key})"] = c0
            series[f"potencia_teto ({key}, h = {max(ceiling - cfg['h_step'], 0):.0f} m)"] = cT
            pre = f"[{key}] "
            summary[pre + "teto absoluto (m)"] = ceiling
            summary[pre + f"teto ≥ {ac.performance.ceiling_min:.0f} m"] = "sim" if ceiling >= ac.performance.ceiling_min else "não"
            if len(rows["h"]):
                for k in ("Vmin", "Vmax", "Ve", "Vman", "Vcru"):
                    summary[pre + f"{k} em h = 0 (m/s)"] = float(rows[k][0])
                summary[pre + "V mínimo voável em h = 0 = max(V_min, V_e) (m/s)"] = float(max(rows["Vmin"][0],
                                                                                            rows["Ve"][0]))
                h0[m] = (float(rows["Vmin"][0]), float(rows["Vmax"][0]), float(rows["Vcru"][0]))
            if m == "planilha" and cfg["faithful"]:
                summary[pre + "observação"] = ("reproduz o original: arrasto com ρ/ρ0 (subestima P_r por ~ρ0) e "
                                               "densidade (1 + λh/T0)^(−g/λR − 1)")
        if self.param(ctx, "table"):
            ctx.on_progress(len(todo) / (len(todo) + 1), "tabela de desempenho (h = 0)")
            with ctx.backend.session_for(model) as s:
                P = s.performance(self.param(ctx, "V_hi"), max(self.param(ctx, "V_lo"), 2.0), 0.5)
            for k in ("alpha_level", "de_level", "gamma_max", "gamma_idle", "phi_stall", "phi_sust"):
                P[k] = np.degrees(P[k])
            for k in ("R_stall", "R_sust"):
                P[k] = np.where(P[k] > 1e6, np.nan, P[k])
            n_lim = self.param(ctx, "n_load") or ac.performance.load_factor
            P["n_lim"] = np.minimum(P["n_stall"], n_lim)
            series["perf"] = P
            ok = (P["ok_level"] > 0) & (P["thr_level"] > 0.05) & (P["thr_level"] <= 1.0)
            if ok.any():
                summary.update(V_max_nivelado=float(P["V"][ok].max()), V_min_nivelado=float(P["V"][ok].min()))
            okc = P["ok_climb"] > 0
            if okc.any():
                j = int(np.argmax(np.where(okc, P["roc_max"], -np.inf)))
                summary.update(roc_max=float(P["roc_max"][j]), V_roc_max=float(P["V"][j]))
        ac_deg = math.degrees(self._cfg(ctx, ac, todo[0])["alpha_cruise"])
        self._cruise(series, summary, checks, h0, series.get("perf"), ac_deg)
        summary.update(Vs=info["Vs"], massa=info["mass"], margem_estatica=info["static_margin"])
        return SimResult(series=series, summary=summary, checks=checks)

    @staticmethod
    def _cruise(series, summary, checks, h0, P, ac_deg):
        """V_cru de cada método em h = 0 contra o ângulo de cruzeiro pedido: gráfico α × V e diagnóstico. Todo
        número do texto sai das entradas ou do que o núcleo calculou"""
        G = "cruzeiro (h = 0)"
        rng = None                                       # faixa do α de equilíbrio dentro do envelope do modelo
        if P is not None:
            okl = np.asarray(P["ok_level"]) > 0
            V, a = np.asarray(P["V"], float), np.asarray(P["alpha_level"], float)
            series["acr_α de equilíbrio (modelo completo)"] = dict(V=V[okl], y=a[okl], _color="#000000", _width=2.0)
            if "modelo completo" in h0:
                lo, hi, _ = h0["modelo completo"]
                inside = okl & (V >= lo) & (V <= hi)
                if inside.any():
                    rng = (float(a[inside].min()), float(a[inside].max()))
        series[f"acr_ângulo de cruzeiro = {ac_deg:g}°"] = dict(_hline=ac_deg, _color="#9467bd", _dash="dash", _width=2)
        for m, (lo, hi, vc) in h0.items():
            color = "#1f77b4" if m == "planilha" else "#d62728"
            series[f"acr_envelope ({m}): {lo:.1f} a {hi:.1f} m/s"] = dict(_vspan=[lo, hi], _color=color, _alpha=20)
            if np.isfinite(vc):
                series[f"acr_V_cru ({m}) = {vc:.2f} m/s"] = dict(_vline=vc, _color=color, _width=2)
            inside = bool(np.isfinite(vc) and lo <= vc <= hi)
            if inside:
                checks.append(Check("ok", f"velocidade de cruzeiro ({m})", f"{vc:.2f} m/s",
                                    f"dentro do envelope ({lo:.1f} a {hi:.1f} m/s) com α de cruzeiro = {ac_deg:g}°",
                                    group=G))
                continue
            if m == "planilha":
                why = (f"com α = {ac_deg:g}°, a sustentação iguala o peso a {vc:.2f} m/s, fora de {lo:.1f} a {hi:.1f} "
                       f"m/s (onde a tração cobre o arrasto)")
                fix = "outro ângulo de cruzeiro, mais tração ou menos arrasto"
            else:
                why = (f"o α de equilíbrio não passa por {ac_deg:g}° entre {lo:.1f} e {hi:.1f} m/s: o avião não voa "
                       f"nivelado nesse ângulo de cruzeiro")
                if rng is not None:
                    why += f" (dentro do envelope ele vai de {rng[0]:.1f}° a {rng[1]:.1f}°)"
                fix = (f"ângulo de cruzeiro entre {rng[0]:.1f}° e {rng[1]:.1f}°" if rng is not None
                       else "ligue a tabela de desempenho para ver a faixa de α do envelope")
            value = f"{vc:.2f} m/s" if np.isfinite(vc) else "não existe"
            checks.append(Check("atencao", f"velocidade de cruzeiro ({m})", value,
                                f"dentro do envelope com α de cruzeiro = {ac_deg:g}°", why, fix, G))
            summary[f"[{'planilha' if m == 'planilha' else 'modelo'}] V_cru"] = f"{value}: {why}"

"""Envelope de voo por altitude (adaptado do Envelope_main original) + tabela de desempenho.

Para cada altitude: ρ(h), V_min e V_max onde a potência disponível cruza a requerida, V_e (estol),
V* = V_e √n (manobra), V_cru, e o teto absoluto (V_min = V_max). Nada é integrado no tempo.

Métodos (o cálculo fica no núcleo Zig, `core/src/sim/envelope.zig`):
  planilha        as fórmulas do original: polar parabólica C_D = C_Dpw + C_Dph S_h/S_w + K C_L², tração
                  do polinômio, ângulo de cruzeiro fixo. "Reproduzir o original" mantém ρ/ρ0 no arrasto e
                  a expressão de densidade do código; desligado usa ρ e a ISA.
  modelo completo trimagem da aeronave inteira (painéis, momentos, profundor) em cada (h, V).
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.aircraft import Aircraft
from aerosim.model.universal import build_model

from .base import SimulationBase

METHODS = ("planilha", "modelo completo", "os dois")
ATMOS = ("ISA", "fórmula da planilha")


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
    name = "envelope"
    title = "Envelope de voo"
    description = ("Por altitude: V_min e V_max (P_d = P_r), V_e, V* = V_e√n, V_cru e o teto absoluto. "
                   "Método da planilha (Envelope_main) ou trimagem da aeronave completa.")

    def parameters(self):
        return [ParamSpec("method", "Método", "os dois", kind="choice", choices=METHODS),
                ParamSpec("atmos", "Atmosfera", "ISA", kind="choice", choices=ATMOS),
                ParamSpec("faithful", "Reproduzir o original (ρ/ρ0 no arrasto)", False, kind="bool",
                          help="liga: mesmas contas do Envelope_main, para comparar com resultados antigos"),
                ParamSpec("h_step", "Passo de altitude", 50.0, minimum=1, maximum=1000, unit="m"),
                ParamSpec("h_max", "Altitude máxima", 6000.0, minimum=50, maximum=20000, unit="m"),
                ParamSpec("V_lo", "V inicial", 4.0, minimum=0.5, maximum=100, unit="m/s"),
                ParamSpec("V_hi", "V final", 30.0, minimum=1, maximum=200, unit="m/s"),
                ParamSpec("dV", "Grade de V (depois bisseção)", 0.05, minimum=0.001, maximum=2, unit="m/s"),
                ParamSpec("tol", "Tolerância de V", 1e-5, minimum=1e-8, maximum=0.1, unit="m/s"),
                ParamSpec("n_load", "Fator de carga n (0 = da aeronave)", 0.0, minimum=0, maximum=10),
                ParamSpec("alpha_cruise", "Ângulo de cruzeiro (vazio = da aeronave)", "", kind="floats", unit="°"),
                ParamSpec("table", "Tabela de desempenho ao nível do mar", True, kind="bool")]

    def plots(self):
        s = "series:perf"
        return [PlotSpec("env_p", "Envelope — planilha", "h", ("Vmin", "Vmax", "Ve", "Vman", "Vcru"),
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
                PlotSpec("raio", "Raio mínimo: estol e sustentada", "V", ("R_stall", "R_sust"), "V (m/s)", "m",
                         live=False, source=s),
                PlotSpec("vn", "Diagrama V-n", "V", ("n_stall", "n_sust", "n_lim"), "V (m/s)", "n", live=False,
                         source=s)]

    def _cfg(self, ctx, ac, method: str) -> dict:
        cfg = sheet_config(ac)
        faithful = bool(self.param(ctx, "faithful"))
        atmos = self.param(ctx, "atmos")
        if faithful and method == "planilha":
            atmos = "fórmula da planilha"
        cfg.update(method=0 if method == "planilha" else 1, atmos=ATMOS.index(atmos), faithful=int(faithful),
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
            series[f"potencia_h0 ({key})"] = c0
            series[f"potencia_teto ({key}, h = {max(ceiling - cfg['h_step'], 0):.0f} m)"] = cT
            pre = f"[{key}] "
            summary[pre + "teto absoluto (m)"] = ceiling
            summary[pre + f"teto ≥ {ac.performance.ceiling_min:.0f} m"] = "sim" if ceiling >= ac.performance.ceiling_min else "não"
            if len(rows["h"]):
                for k in ("Vmin", "Vmax", "Ve", "Vman", "Vcru"):
                    summary[pre + f"{k} em h = 0 (m/s)"] = float(rows[k][0])
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
        summary.update(Vs=info["Vs"], massa=info["mass"], margem_estatica=info["static_margin"])
        return SimResult(series=series, summary=summary)

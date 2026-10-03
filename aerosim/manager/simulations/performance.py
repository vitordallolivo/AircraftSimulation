"""Desempenho por cálculo (como na planilha de desempenho): nada é simulado e não há piloto.

Tudo vem de `ISimBackend.simple_performance` (núcleo Zig, `core/src/sim/simple_perf.zig`) com a polar
parabólica C_D = C_D0 + K C_L² e a tração disponível T(V) da propulsão, por altitude (ISA). As curvas
saem inteiras, como na planilha (também onde não dá para voar), e a área segura fica sombreada:
  envelope de voo     altitude × V: V_min e V_max (P_d = P_r) fechando no teto, V_e, V* = V_e √n e V de
                      cruzeiro (L/D máx.); área segura entre max(V_min, V_e) e min(V*, V_max)
  potências/trações   disponível × requerida
  subida              razão e ângulo
  planeio             razão de descida × V (negativa), com a tangente pela origem (alcance máximo) e a
                      menor razão de descida (autonomia máxima)
  envelope de curvas  V × raio para cada inclinação φ, com V_min, V_e e V*; área segura entre V_e e V* e
                      entre R(V*, φ máx. do piloto) e R(V*, 10°)
  V-n e bateria (Peukert)

A polar é a da aba Aerodinâmica, se ela já rodou para esta configuração; senão, a do núcleo (rápida).
A curva SIMULADA (com piloto e vento) está na aba Missão.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero.service import KEY, signature
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model

from .base import SimulationBase, floats
from .thrust import thrust_curves

G0 = 9.80665
ALT_COLORS = ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b"]
BANKS = (5, 10, 15, 20, 25, 30, 35, 40)
BANK_COLORS = ["#4472c4", "#ed7d31", "#a5a5a5", "#ffc000", "#5b9bd5", "#70ad47", "#264478", "#9e480e"]
SAFE = "#2ca02c"


def core_polar(backend, model, V: float = 12.0) -> tuple[float, float, float]:
    """C_D0, K e C_Lmax da aeronave inteira pelo núcleo (sem calibrar piloto nem trimar)"""
    al = np.radians(np.arange(-4.0, 24.01, 0.5))
    with backend.session_for(model) as s:
        rows = [s.aero_coeffs(V, a) for a in al]
    CL = np.array([r["CL"] for r in rows])
    CD = np.array([r["CD"] for r in rows])
    sel = (al >= math.radians(-2)) & (al <= math.radians(8))
    K, CD0 = np.polyfit(CL[sel] ** 2, CD[sel], 1)
    return float(CD0), float(K), float(CL.max())


class PerformanceSimulation(SimulationBase):
    tab = True
    name = "performance"
    title = "Desempenho"
    description = ("Cálculos da planilha (sem simulação, sem piloto): envelope de voo, potências, subida, planeio, "
                   "envelope de curvas, V-n e bateria — curvas inteiras e a área segura sombreada.")

    def parameters(self):
        return [ParamSpec("h_list", "Altitudes dos gráficos", "0, 900", kind="floats", unit="m"),
                ParamSpec("mass", "Massa (0 = da aeronave)", 0.0, minimum=0, maximum=1000, unit="kg"),
                ParamSpec("bat_n", "Bateria: expoente de Peukert", 1.05, minimum=1.0, maximum=1.6, group="Bateria"),
                ParamSpec("bat_eta", "Bateria: rendimento total (motor, ESC, hélice)", 0.6, minimum=0.05, maximum=1,
                          group="Bateria")]

    def plots(self):
        s = lambda key, title, xl, yl, x="V": PlotSpec(key, title, x, ("y",), xl, yl, live=False,
                                                       source=f"series:{key}_*")
        return [PlotSpec("env", "Envelope de voo (área segura em verde)", "V", ("h",), "velocidade (m/s)",
                         "altitude (m)", live=False, source="series:env_*"),
                s("spot", "Potência disponível × requerida (verde: sobra de potência)", "V (m/s)", "potência (W)"),
                s("stra", "Tração disponível × requerida", "V (m/s)", "tração (N)"),
                s("ssub", "Razão de subida (negativa: não sustenta o voo nivelado; ★ máxima)", "V (m/s)", "RC (m/s)"),
                s("sgam", "Ângulo de subida (★ máximo)", "V (m/s)", "γ (°)"),
                s("sdes", "Planeio: razão de descida × V (tangente: alcance máximo; tracejado: autonomia máxima)",
                  "V de planeio (m/s)", "razão de descida (m/s)"),
                PlotSpec("scur", "Envelope de curvas: velocidade × raio por inclinação (área segura em verde)", "R",
                         ("V",), "raio de curvatura (m)", "velocidade (m/s)", live=False, source="series:scur_*"),
                s("snv", "Diagrama V-n (verde: dentro dos limites)", "V (m/s)", "n (g)"),
                s("sbat", "Autonomia da bateria na potência requerida (verde: V de voo nivelado)", "V (m/s)",
                  "autonomia (min)"),
                s("sran", "Alcance com a bateria (★ máximo)", "V (m/s)", "alcance (km)")]

    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        model = build_model(ac)
        P = lambda k: self.param(ctx, k)
        sh = ctx.shared or {}
        if KEY in sh and sh[KEY]["sig"] == signature(model):
            from aerosim.aero import parabolic_polar
            fit = parabolic_polar(sh[KEY]["polar"])
            CD0, K, CLmax, src = fit["CD0"], fit["k"], fit["CLmax"], f"aba Aerodinâmica ({sh[KEY]['method']})"
        else:
            ctx.on_progress(0.1, "polar do núcleo")
            CD0, K, CLmax = core_polar(ctx.backend, model)
            src = "núcleo (rode a aba Aerodinâmica para usar a polar dela)"
        with ctx.backend.session_for(model) as s:
            m = P("mass") or s.mass_props()["m"]
        V_hi = 35.0
        tc = thrust_curves(ctx.backend, ac, V_max=V_hi + 1.0, dV=0.5)
        Vt = next(iter(next(iter(tc.values())).values()))["V"] if tc else np.array([0.0, V_hi])
        Tt = sum(d[1.0]["T"] for d in tc.values()) if tc else np.zeros_like(Vt)
        units = [u for u in ac.propulsion if u.enabled]
        bat = units[0].battery if units else None
        n_load = ac.performance.load_factor
        base = dict(W=m * G0, S=model.S, CD0=CD0, K=K, CLmax=CLmax, rho0=ac.performance.rho0, T0=288.15,
                    phi_T=math.radians(np.mean([u.tilt for u in units])) if units else 0.0, V_lo=0.5, V_hi=V_hi,
                    dV=0.1, n_load=n_load, bat_Rt=1.0, bat_n=P("bat_n"), bat_eta=P("bat_eta"),
                    bat_C=(bat.capacity_mAh / 1000.0 * (1 if ac.shared_battery else len(units))) if bat else 1.0,
                    bat_V=bat.Voc if bat else 1.0, thr_V=list(Vt[:128]), thr_T=list(Tt[:128]),
                    bank=[math.radians(b) for b in BANKS])
        S, checks = {}, []
        summ = {"polar": f"{src}: C_D0 = {CD0:.4f}, K = {K:.4f}, C_Lmax = {CLmax:.2f}", "massa (kg)": m,
                "S (m²)": model.S}
        ctx.on_progress(0.2, "envelope")
        ceiling = self._envelope(ctx, base, S, summ)
        hs = floats(P("h_list"))
        for j, h in enumerate(hs):
            ctx.check()
            rows, sm = ctx.backend.simple_performance(dict(base, h=h))
            self._by_altitude(S, rows, sm, j, h)
            if j == 0:
                self._turn_envelope(S, sm, ac.autopilot.phimax)
                self._vn(S, rows, sm, n_load)
            pre = f"[h = {h:g} m] "
            summ.update({pre + "ρ (kg/m³)": sm["rho"], pre + "V_e, V*, V_cru (L/D máx.) (m/s)": [sm["Vs"], sm["Vman"],
                                                                                              sm["V_LDmax"]],
                         pre + "V_min, V_max (P_d = P_r) (m/s)": [sm["Vmin"], sm["Vmax"]],
                         pre + "RC máx. (m/s) @ V": [sm["RCmax"], sm["V_RCmax"]],
                         pre + "γ máx. (°)": math.degrees(sm["gmax"]),
                         pre + "E máx.; menor ângulo de planeio (°)": [sm["Emax"], math.degrees(sm["glide_min"])],
                         pre + "menor razão de descida (m/s) @ V": [sm["sink_min"], sm["V_sink_min"]],
                         pre + "R mín. pela fórmula da planilha (m) @ V": [sm["R_min"], sm["V_Rmin"]],
                         pre + "autonomia máx. (min) @ V": [60 * sm["t_max"], sm["V_tmax"]],
                         pre + "alcance máx. (km) @ V": [sm["range_max"] / 1000, sm["V_range_max"]]})
            G = f"a {h:g} m"
            if not sm["ceiling_ok"]:
                checks.append(Check("falha", f"voo nivelado {G}", "P_d < P_r em todas as V", "P_d ≥ P_r",
                                    "a potência disponível não cobre a requerida em nenhuma velocidade",
                                    "mais tração, menos massa ou menos arrasto (C_D0)", G))
            else:
                lo, hi = max(sm["Vmin"], sm["Vs"]), min(sm["Vmax"], sm["Vman"])
                checks.append(Check("ok" if hi > lo else "falha", f"faixa segura de velocidades {G}",
                                    f"{lo:.1f} a {hi:.1f} m/s", "max(V_min, V_e) < min(V_max, V*)",
                                    "" if hi > lo else "não sobra faixa entre o estol e a velocidade máxima/de manobra",
                                    "" if hi > lo else "mais tração ou menos carga alar", G))
                checks.append(Check("ok" if sm["RCmax"] > 0.5 else "atencao", f"razão de subida máxima {G}",
                                    f"{sm['RCmax']:.2f} m/s", "> 0,5 m/s", "", "" if sm["RCmax"] > 0.5 else
                                    "mais potência ou menos arrasto", G))
        if ceiling is not None:
            checks.append(Check("info", "teto absoluto", f"≈ {ceiling:.0f} m", "V_min = V_max", "", "", "envelope"))
        return SimResult(series=S, summary=summ, checks=checks)

    # ------------------------------------------------------------------ envelope de voo (como a Figura 4.4)
    def _envelope(self, ctx, base, S, summ):
        H, Vmin, Vmax, Ve, Vman, Vcru = [], [], [], [], [], []
        ceiling = None
        for h in np.arange(0.0, 9000.01, 50.0):
            _, sm = ctx.backend.simple_performance(dict(base, h=float(h)))
            if not sm["ceiling_ok"] or sm["Vmax"] <= sm["Vmin"]:
                ceiling = float(h)
                break
            H.append(h); Vmin.append(sm["Vmin"]); Vmax.append(sm["Vmax"]); Ve.append(sm["Vs"])
            Vman.append(sm["Vman"]); Vcru.append(sm["V_LDmax"])
        if not H:
            return ceiling
        H, Vmin, Vmax, Ve, Vman, Vcru = map(np.array, (H, Vmin, Vmax, Ve, Vman, Vcru))
        lo, hi = np.maximum(Vmin, Ve), np.minimum(Vmax, Vman)
        ok = hi > lo
        if ok.any():
            S["env_área segura"] = dict(V=lo[ok], h=H[ok], _fillx="Vhi", Vhi=hi[ok], _color=SAFE)
        # V_min e V_max fecham no teto (o "domo" da planilha)
        S["env_V_min"] = dict(V=np.r_[Vmin, 0.5 * (Vmin[-1] + Vmax[-1])], h=np.r_[H, H[-1] + 25], _color="#4472c4",
                              _width=2.2)
        S["env_V_max"] = dict(V=np.r_[Vmax, 0.5 * (Vmin[-1] + Vmax[-1])], h=np.r_[H, H[-1] + 25], _color="#c0504d",
                              _width=2.2)
        S["env_V_e (estol)"] = dict(V=Ve, h=H, _color="#9bbb59", _width=2)
        S["env_V* = V_e √n (manobra)"] = dict(V=Vman, h=H, _color="#8064a2", _width=2)
        S["env_V_cru (L/D máximo)"] = dict(V=Vcru, h=H, _color="#4bacc6", _width=2)
        if ceiling is not None:
            S[f"env_teto absoluto ≈ {ceiling:.0f} m"] = dict(_hline=ceiling, _color="#000000", _dash="dash")
        summ["teto absoluto (m)"] = ceiling if ceiling is not None else "> 9000"
        return ceiling

    # ------------------------------------------------------------------ por altitude
    @staticmethod
    def _by_altitude(S, rows, sm, j, h):
        c = ALT_COLORS[j % len(ALT_COLORS)]
        lab = f"h = {h:g} m"
        V = rows["V"]
        ok = rows["ok"] > 0                       # C_L ≤ C_Lmax
        fly = ok & (rows["Pd"] >= rows["Pr"])
        idx = np.where(fly)[0]
        show = V >= 0.3 * sm["Vs"]                # só some o começo em que C_L → ∞ (V ≈ 0)
        Pr = np.where(show, rows["Pr"], np.nan)
        if len(idx):
            band = slice(idx[0], idx[-1] + 1)
            Vf = V[band]
            S[f"spot_{lab}: sobra de potência"] = dict(V=Vf, y=rows["Pr"][band], _fill="y2", y2=rows["Pd"][band],
                                                      _color=SAFE, _nolegend=j > 0)
            S[f"ssub_{lab}: sobe"] = dict(V=Vf, y=np.zeros(len(Vf)), _fill="y2", y2=rows["RC"][band], _color=SAFE,
                                         _nolegend=j > 0)
            S[f"sbat_{lab}: V de voo nivelado"] = dict(_vspan=[float(Vf[0]), float(Vf[-1])], _color=c, _alpha=25)
        S[f"spot_{lab}: disponível P_d"] = dict(V=V, y=rows["Pd"], _color=c, _width=2)
        S[f"spot_{lab}: requerida P_r"] = dict(V=V, y=Pr, _color=c, _dash="dash")
        S[f"stra_{lab}: disponível T_d"] = dict(V=V, y=rows["Td"], _color=c, _width=2)
        S[f"stra_{lab}: requerida T_r"] = dict(V=V, y=np.where(show, rows["Tr"], np.nan), _color=c, _dash="dash")
        rc = np.where(show, rows["RC"], np.nan)
        if j == 0:                                 # janela dos gráficos (as curvas ficam inteiras, fora dela também)
            S["spot__escala"] = dict(_ylim=[0.0, 1.8 * float(rows["Pd"].max())], _xlim=[0.0, float(V[-1])])
            S["stra__escala"] = dict(_ylim=[0.0, 1.5 * float(rows["Td"].max())], _xlim=[0.0, float(V[-1])])
            top = max(sm["RCmax"], 0.5)
            S["ssub__escala"] = dict(_ylim=[-3 * top, 1.6 * top], _xlim=[0.0, float(V[-1])])
            S["sgam__escala"] = dict(_ylim=[-3 * max(math.degrees(sm["gmax"]), 2), 1.6 * max(math.degrees(sm["gmax"]), 2)],
                                     _xlim=[0.0, float(V[-1])])
            S["sdes__escala"] = dict(_ylim=[-4 * (sm["sink_min"] + 0.5), 0.3], _xlim=[0.0, float(V[-1])])
            S["sbat__escala"] = dict(_ylim=[0.0, 1.5 * 60 * sm["t_max"]], _xlim=[0.0, float(V[-1])])
            S["sran__escala"] = dict(_ylim=[0.0, 1.5 * sm["range_max"] / 1000], _xlim=[0.0, float(V[-1])])
        S[f"ssub_{lab}"] = dict(V=V, y=rc, _color=c, _width=2)
        S[f"sgam_{lab}"] = dict(V=V, y=np.where(np.isfinite(rc), np.degrees(rows["gam"]), np.nan), _color=c, _width=2)
        S["ssub_zero"] = dict(_hline=0.0, _color="#000000", _dash="dot", _nolegend=1)
        for k in ("ssub", "sgam", "spot", "stra"):
            S[f"{k}_V_e ({lab})"] = dict(_vline=sm["Vs"], _color=c, _dash="dot", _nolegend=1)
        star = lambda x, y: dict(V=np.array([x]), y=np.array([y]), _symbol="star", _color=c)
        S[f"ssub_★ {sm['RCmax']:.2f} m/s a {sm['V_RCmax']:.1f} m/s ({lab})"] = star(sm["V_RCmax"], sm["RCmax"])
        S[f"sgam_★ {math.degrees(sm['gmax']):.1f}° ({lab})"] = star(sm["V_gmax"], math.degrees(sm["gmax"]))
        # planeio (Figura 4.8): razão de descida negativa × V de planeio, curva inteira
        Vg, sink = rows["V_glide"], -rows["sink"]
        gl = show & (Vg > 0)
        S[f"sdes_Rs ({lab})"] = dict(V=np.where(gl, Vg, np.nan), y=np.where(gl, sink, np.nan), _color=c, _width=2)
        S[f"sdes_máxima autonomia ({lab}): {sm['sink_min']:.2f} m/s"] = dict(_hline=-sm["sink_min"], _color=c,
                                                                            _dash="dash")
        g = sm["glide_min"]
        Vt = np.array([0.0, 1.3 * sm["V_glide_min"]])
        S[f"sdes_máximo alcance ({lab}): E = {sm['Emax']:.1f}"] = dict(V=Vt, y=-np.tan(g) * Vt, _color="#000000",
                                                                       _width=1.4)
        S[f"sdes_★ V de maior alcance {sm['V_glide_min']:.1f} m/s ({lab})"] = dict(
            V=np.array([sm["V_glide_min"]]), y=np.array([-sm["V_glide_min"] * math.tan(g)]), _symbol="star", _color=c)
        S[f"sbat_{lab}"] = dict(V=V, y=np.where(show, 60 * rows["t_bat"], np.nan), _color=c, _width=2)
        S[f"sran_{lab}"] = dict(V=V, y=np.where(show, rows["range_bat"] / 1000, np.nan), _color=c, _width=2)
        S[f"sbat_★ {60 * sm['t_max']:.1f} min a {sm['V_tmax']:.1f} m/s ({lab})"] = star(sm["V_tmax"], 60 * sm["t_max"])
        S[f"sran_★ {sm['range_max'] / 1000:.2f} km ({lab})"] = star(sm["V_range_max"], sm["range_max"] / 1000)
        S[f"simples_{lab}"] = rows

    # ------------------------------------------------------------------ envelope de curvas (Figura 4.7)
    @staticmethod
    def _turn_envelope(S, sm, phimax_deg):
        Ve, Vman, Vmin = sm["Vs"], sm["Vman"], sm["Vmin"]
        Vtop = 1.15 * Vman
        V = np.linspace(0.5, Vtop, 120)
        Rmax_plot = 1.1 * Vman ** 2 / (G0 * math.tan(math.radians(BANKS[0] + 5)))
        for k, b in enumerate(BANKS):
            R = V ** 2 / (G0 * math.tan(math.radians(b)))
            sel = R <= Rmax_plot
            S[f"scur_{b:g}°"] = dict(R=R[sel], V=V[sel], _color=BANK_COLORS[k % len(BANK_COLORS)], _width=1.6)
        r_lo = Vman ** 2 / (G0 * math.tan(math.radians(phimax_deg)))     # φ máx. do piloto em V*
        r_hi = Vman ** 2 / (G0 * math.tan(math.radians(10.0)))           # φ = 10° em V*
        S["scur_área segura"] = dict(R=np.array([r_lo, r_hi]), V=np.array([Ve, Ve]), _fill="Vtop",
                                     Vtop=np.array([Vman, Vman]), _color=SAFE)
        S["scur_V_min"] = dict(_hline=Vmin, _color="#7f7f7f", _width=2)
        S["scur_V_e"] = dict(_hline=Ve, _color="#9c8b00", _width=2)
        S["scur_V*"] = dict(_hline=Vman, _color="#2f5597", _width=2)
        S[f"scur_limite inferior: R(V*, φ = {phimax_deg:g}°) = {r_lo:.0f} m"] = dict(_vline=r_lo, _color=SAFE, _width=2.5)
        S[f"scur_limite superior: R(V*, φ = 10°) = {r_hi:.0f} m"] = dict(_vline=r_hi, _color=SAFE, _width=2.5)

    @staticmethod
    def _vn(S, rows, sm, n_load):
        V = rows["V"]
        vmax = sm["Vmax"] if sm["Vmax"] > 0 else V[-1]
        sel = V <= 1.15 * vmax
        nlim = np.minimum(rows["n_stall"], n_load)
        inside = V <= vmax
        S["snv_dentro dos limites (estol e n de projeto, até V_max)"] = dict(V=V[inside], y=np.zeros(inside.sum()),
                                                                          _fill="y2", y2=nlim[inside], _color=SAFE)
        S["snv_limite de estol n = q S C_Lmax / W"] = dict(V=V[sel], y=rows["n_stall"][sel], _color="#d62728", _width=2)
        S["snv_limite de tração (curva sustentada)"] = dict(V=V[sel], y=rows["n_sust"][sel], _color="#ff7f0e", _width=2)
        S[f"snv_n de projeto = {n_load:g}"] = dict(_hline=n_load, _color="#000000", _dash="dash")
        S[f"snv_V* = {sm['Vman']:.1f} m/s"] = dict(_vline=sm["Vman"], _color="#000000", _dash="dot")
        S[f"snv_V_max = {vmax:.1f} m/s"] = dict(_vline=vmax, _color="#d62728", _dash="dot")

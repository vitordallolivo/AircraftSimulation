"""Desempenho por cálculo (como na planilha de desempenho): nada é simulado e não há piloto.

Tudo vem de `ISimBackend.simple_performance` (núcleo Zig, `core/src/sim/simple_perf.zig`) com a polar
parabólica C_D = C_D0 + K C_L² e a tração disponível T(V) da propulsão, por altitude (ISA):
  envelope de voo     por altitude, V_min e V_max onde P_d = P_r, V_e, V* e o teto
  potências e trações disponível × requerida
  subida              razão e ângulo
  descida             planeio: razão de descida e ângulo × V
  curva               R = V²/(g tan φ), limites de estol e de tração, raio mínimo
  V-n                 limites de estol, de tração e o fator de carga de projeto
  bateria             autonomia e alcance (Peukert)
Cada gráfico tem a área segura de operação sombreada.

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
BANK_COLORS = ["#9ecae1", "#6baed6", "#4292c6", "#2171b5", "#08519c", "#08306b", "#252525", "#636363"]
BANKS = (10, 20, 30, 40, 50, 60)
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
                   "raio de curva × V, V-n e bateria, com a área segura de operação sombreada.")

    def parameters(self):
        return [ParamSpec("h_list", "Altitudes dos gráficos", "0, 900", kind="floats", unit="m"),
                ParamSpec("mass", "Massa (0 = da aeronave)", 0.0, minimum=0, maximum=1000, unit="kg"),
                ParamSpec("bat_n", "Bateria: expoente de Peukert", 1.05, minimum=1.0, maximum=1.6, group="Bateria"),
                ParamSpec("bat_eta", "Bateria: rendimento total (motor, ESC, hélice)", 0.6, minimum=0.05, maximum=1,
                          group="Bateria")]

    def plots(self):
        s = lambda key, title, xl, yl, x="V": PlotSpec(key, title, x, ("y",), xl, yl, live=False,
                                                       source=f"series:{key}_*")
        return [PlotSpec("env", "Envelope de voo: altitude × velocidade (verde: voo nivelado possível)", "V", ("h",),
                         "V (m/s)", "altitude (m)", live=False, source="series:env_*"),
                s("spot", "Potência disponível × requerida (verde: sobra de potência)", "V (m/s)", "potência (W)"),
                s("stra", "Tração disponível × requerida", "V (m/s)", "tração (N)"),
                s("ssub", "Razão de subida (verde: sobe; ★ máxima)", "V (m/s)", "RC (m/s)"),
                s("sgam", "Ângulo de subida (★ máximo)", "V (m/s)", "γ (°)"),
                s("sdes", "Planeio: razão de descida × V (★ mínima)", "V de planeio (m/s)", "razão de descida (m/s)"),
                s("sgpl", "Planeio: ângulo × V (★ menor ângulo = E máx.)", "V de planeio (m/s)", "ângulo (°)"),
                s("scur", "Raio de curva × V (verde: raios possíveis; ★ R mínimo)", "V (m/s)", "R (m)"),
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
                    phi_T=math.radians(np.mean([u.tilt for u in units])) if units else 0.0, V_lo=1.0, V_hi=V_hi,
                    dV=0.1, n_load=n_load, bat_Rt=1.0, bat_n=P("bat_n"), bat_eta=P("bat_eta"),
                    bat_C=(bat.capacity_mAh / 1000.0 * (1 if ac.shared_battery else len(units))) if bat else 1.0,
                    bat_V=bat.Voc if bat else 1.0, thr_V=list(Vt[:128]), thr_T=list(Tt[:128]),
                    bank=[math.radians(b) for b in BANKS])
        S, checks = {}, []
        summ = {"polar": f"{src}: C_D0 = {CD0:.4f}, K = {K:.4f}, C_Lmax = {CLmax:.2f}", "massa (kg)": m,
                "S (m²)": model.S}
        # ---------------- envelope por altitude
        ctx.on_progress(0.2, "envelope")
        H, Vmin, Vmax, Ve, Vman, Vrc = [], [], [], [], [], []
        ceiling = None
        for h in np.arange(0.0, 8000.01, 100.0):
            _, sm = ctx.backend.simple_performance(dict(base, h=float(h)))
            if not sm["ceiling_ok"] or sm["Vmax"] <= sm["Vmin"]:
                ceiling = float(h)
                break
            H.append(h); Vmin.append(sm["Vmin"]); Vmax.append(sm["Vmax"]); Ve.append(sm["Vs"])
            Vman.append(sm["Vman"]); Vrc.append(sm["V_RCmax"])
        H = np.array(H)
        if len(H):
            S["env_região de voo nivelado (P_d ≥ P_r e V ≥ V_e)"] = dict(V=np.array(Vmin), h=H, _fillx="Vmax",
                                                                        Vmax=np.array(Vmax), _color=SAFE)
            S["env_V_min"] = dict(V=np.array(Vmin), h=H, _color="#1f77b4", _width=2)
            S["env_V_max"] = dict(V=np.array(Vmax), h=H, _color="#d62728", _width=2)
            S["env_V_e (estol)"] = dict(V=np.array(Ve), h=H, _color="#000000", _dash="dot")
            S["env_V* = V_e √n (manobra)"] = dict(V=np.array(Vman), h=H, _color="#9467bd", _dash="dash")
            S["env_V de razão de subida máxima"] = dict(V=np.array(Vrc), h=H, _color="#ff7f0e", _dash="dash")
        if ceiling is not None:
            S[f"env_teto absoluto ≈ {ceiling:.0f} m"] = dict(_hline=ceiling, _color="#000000", _width=2)
        summ["teto absoluto (m)"] = ceiling if ceiling is not None else "> 8000"
        # ---------------- por altitude
        hs = floats(P("h_list"))
        for j, h in enumerate(hs):
            ctx.check()
            rows, sm = ctx.backend.simple_performance(dict(base, h=h))
            c = ALT_COLORS[j % len(ALT_COLORS)]
            lab = f"h = {h:g} m"
            ok = rows["ok"] > 0
            V = rows["V"]
            nan = lambda a: np.where(ok, a, np.nan)
            fly = ok & (rows["Pd"] >= rows["Pr"])
            idx = np.where(fly)[0]
            Vf = V[idx[0]:idx[-1] + 1] if len(idx) else V[:0]
            band = slice(idx[0], idx[-1] + 1) if len(idx) else slice(0, 0)
            if len(idx):
                S[f"spot_{lab}: sobra de potência"] = dict(V=Vf, y=rows["Pr"][band], _fill="y2", y2=rows["Pd"][band],
                                                          _color=SAFE, _nolegend=j > 0)
                S[f"ssub_{lab}: sobe"] = dict(V=Vf, y=np.zeros(len(Vf)), _fill="y2", y2=rows["RC"][band], _color=SAFE,
                                             _nolegend=j > 0)
                S[f"sbat_{lab}: V de voo nivelado"] = dict(_vspan=[float(Vf[0]), float(Vf[-1])], _color=c, _alpha=25)
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
            S[f"ssub_zero"] = dict(_hline=0.0, _color="#000000", _dash="dot", _nolegend=1)
            star = lambda x, y: dict(V=np.array([x]), y=np.array([y]), _symbol="star", _color=c)
            S[f"ssub_★ {sm['RCmax']:.2f} m/s a {sm['V_RCmax']:.1f} m/s ({lab})"] = star(sm["V_RCmax"], sm["RCmax"])
            S[f"sgam_★ {math.degrees(sm['gmax']):.1f}° ({lab})"] = star(sm["V_gmax"], math.degrees(sm["gmax"]))
            S[f"sdes_★ {sm['sink_min']:.2f} m/s ({lab})"] = star(sm["V_sink_min"], sm["sink_min"])
            S[f"sgpl_★ E máx. {sm['Emax']:.1f} ({lab})"] = star(sm["V_glide_min"], math.degrees(sm["glide_min"]))
            S[f"sran_★ {sm['range_max'] / 1000:.2f} km ({lab})"] = star(sm["V_range_max"], sm["range_max"] / 1000)
            S[f"sbat_★ {60 * sm['t_max']:.1f} min a {sm['V_tmax']:.1f} m/s ({lab})"] = star(sm["V_tmax"], 60 * sm["t_max"])
            if j == 0:
                self._turn_and_vn(S, rows, sm, V, ok, n_load)
            pre = f"[{lab}] "
            if "R_min_curva" in sm:
                summ[pre + "R mín. (m) @ V (pelas curvas)"] = [sm["R_min_curva"], sm["V_Rmin_curva"]]
            summ.update({pre + "ρ (kg/m³)": sm["rho"], pre + "V_e, V* (m/s)": [sm["Vs"], sm["Vman"]],
                         pre + "V_min, V_max (m/s)": [sm["Vmin"], sm["Vmax"]],
                         pre + "RC máx. (m/s) @ V": [sm["RCmax"], sm["V_RCmax"]],
                         pre + "γ máx. (°)": math.degrees(sm["gmax"]),
                         pre + "E máx.; menor ângulo de planeio (°)": [sm["Emax"], math.degrees(sm["glide_min"])],
                         pre + "menor razão de descida (m/s) @ V": [sm["sink_min"], sm["V_sink_min"]],
                         pre + "R mín. pela fórmula da planilha (T/W estático) @ V": [sm["R_min"], sm["V_Rmin"]],
                         pre + "autonomia máx. (min) @ V": [60 * sm["t_max"], sm["V_tmax"]],
                         pre + "alcance máx. (km) @ V": [sm["range_max"] / 1000, sm["V_range_max"]]})
            G = f"a {h:g} m"
            if not sm["ceiling_ok"]:
                checks.append(Check("falha", f"voo nivelado {G}", "P_d < P_r em todas as V", "P_d ≥ P_r",
                                    "a potência disponível não cobre a requerida em nenhuma velocidade",
                                    "mais tração, menos massa ou menos arrasto (C_D0)", G))
            else:
                checks.append(Check("info", f"faixa de velocidades {G}", f"{sm['Vmin']:.1f} a {sm['Vmax']:.1f} m/s",
                                    "P_d ≥ P_r e V ≥ V_e", "", "", G))
                checks.append(Check("ok" if sm["RCmax"] > 0.5 else "atencao", f"razão de subida máxima {G}",
                                    f"{sm['RCmax']:.2f} m/s", "> 0,5 m/s", "", "" if sm["RCmax"] > 0.5 else
                                    "mais potência ou menos arrasto", G))
        return SimResult(series=S, summary=summ, checks=checks)

    @staticmethod
    def _turn_and_vn(S, rows, sm, V, ok, n_load):
        Rs = np.where(np.isfinite(rows["R_stall"]), rows["R_stall"], np.nan)
        Rt = np.where(np.isfinite(rows["R_sust"]), rows["R_sust"], np.nan)
        # curva nivelada possível só onde os dois limites existem: o raio mínimo é o maior dos dois
        Rlim = np.where(np.isfinite(Rs) & np.isfinite(Rt), np.maximum(Rs, Rt), np.nan)
        fin = np.isfinite(Rlim)
        if fin.any():
            i = int(np.nanargmin(Rlim))
            Rmin, Vr = float(Rlim[i]), float(V[i])
        else:
            Rmin, Vr = float("nan"), float("nan")
        top = 4 * (Rmin if np.isfinite(Rmin) else max(sm["R_min"], 10.0))
        idx = np.where(fin & (Rlim < top))[0]
        if len(idx):
            # só o trecho contínuo em volta do mínimo (sem atravessar buracos)
            i0 = i1 = int(np.nanargmin(Rlim))
            while i0 - 1 >= 0 and fin[i0 - 1] and Rlim[i0 - 1] < top:
                i0 -= 1
            while i1 + 1 < len(V) and fin[i1 + 1] and Rlim[i1 + 1] < top:
                i1 += 1
            sl = slice(i0, i1 + 1)
            S["scur_raios possíveis em curva nivelada (acima dos dois limites)"] = dict(
                V=V[sl], y=Rlim[sl], _fill="y2", y2=np.full(i1 - i0 + 1, top), _color=SAFE)
        for k, b in enumerate(BANKS):
            R = rows[f"R_bank_{k}"]
            n = 1 / math.cos(math.radians(b))
            S[f"scur_φ = {b:g}° (n = {n:.2f})"] = dict(V=V, y=np.where(ok & (rows["n_stall"] >= n) & (R < top), R, np.nan),
                                                       _color=BANK_COLORS[k % len(BANK_COLORS)], _width=1.2)
        S["scur_limite de estol"] = dict(V=V, y=np.where(Rs < top, Rs, np.nan), _color="#d62728", _width=2.5)
        S["scur_limite de tração (curva sustentada)"] = dict(V=V, y=np.where(Rt < top, Rt, np.nan), _color="#ff7f0e",
                                                              _width=2.5)
        if np.isfinite(Rmin):
            S[f"scur_★ R mín. = {Rmin:.1f} m a {Vr:.1f} m/s"] = dict(V=np.array([Vr]), y=np.array([Rmin]),
                                                                      _symbol="star", _color="#ffcc00", _size=22)
        sm["R_min_curva"], sm["V_Rmin_curva"] = Rmin, Vr
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

"""Aba Dimensionamento inicial — diagrama de restrições T/W × W/S (e P/m × W/S para hélice).

Os requisitos são entradas. A polar NÃO é calculada aqui: vem de uma estimativa estatística (quando
ainda não há geometria) ou da aba Aerodinâmica (o módulo de aerodinâmica, pelo modelo universal).
Saídas: a região viável (sombreada), a faixa ótima (T/W até `tol` acima do mínimo), o ponto de
projeto (área de asa e tração/potência para a massa atual), o ponto da aeronave atual e, no
diagnóstico, cada requisito comparado com a tração do motor na velocidade dele.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.aero import parabolic_polar
from aerosim.aero.service import aircraft_polar
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.universal import build_model
from aerosim.sizing import ParabolicPolar, Requirements, design_point, required_tw
from aerosim.sizing.constraints import KINDS, LIMITS, active_kinds, condition_speed, estimate_polar, isa_rho, \
    ws_limits

from .base import SimulationBase

G0 = 9.80665
LAB = dict(KINDS + LIMITS)
# cor fixa por requisito (a mesma em todos os gráficos)
COLOR = {"decolagem": "#2a78d6", "subida": "#eb6834", "gradiente": "#e87ba4", "cruzeiro": "#1baf7a",
         "vmax": "#4a3aa7", "curva": "#8c564b", "teto": "#17becf", "estol": "#e34948", "pouso": "#7f7f7f",
         "regiao": "#9ec5ee", "otima": "#eda100", "projeto": "#0b0b0b", "aeronave": "#d62728"}
SOURCES = ("estimativa (sem geometria)", "aba Aerodinâmica (da aeronave)")


class SizingSimulation(SimulationBase):
    name = "sizing"
    title = "Dimensionamento inicial"
    description = ("Diagrama de restrições: tração (e potência) por peso exigida por cada requisito em função da carga "
                   "alar. Mostra a região viável, a faixa ótima e o ponto de projeto (área de asa e motor), e onde a "
                   "aeronave atual está. A polar vem de uma estimativa ou da aba Aerodinâmica.")

    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac, values=None):
        values = values or {}
        from .stability import _cruise_speed
        Vc = _cruise_speed(ac) if ac is not None else 15.0
        R, A, D = "Requisitos (0 desliga)", "Polar", "Projeto"
        ps = [ParamSpec("V_stall", "velocidade de estol máxima", round(0.7 * Vc, 1), minimum=2, maximum=60, unit="m/s",
                        group=R),
              ParamSpec("S_G", "corrida de decolagem máxima", 50.0, minimum=1, maximum=2000, unit="m", group=R),
              ParamSpec("S_L", "corrida de pouso máxima", 0.0, minimum=0, maximum=2000, unit="m", group=R),
              ParamSpec("V_cruise", "velocidade de cruzeiro", round(Vc, 1), minimum=3, maximum=100, unit="m/s", group=R),
              ParamSpec("V_max", "velocidade máxima", 0.0, minimum=0, maximum=150, unit="m/s", group=R),
              ParamSpec("roc", "razão de subida", 2.0, minimum=0, maximum=30, unit="m/s", group=R),
              ParamSpec("climb_grad", "gradiente de subida", 0.0, minimum=0, maximum=60, unit="%", group=R),
              ParamSpec("V_climb", "velocidade de subida", round(0.85 * Vc, 1), minimum=3, maximum=80, unit="m/s",
                        group=R),
              ParamSpec("n_turn", "fator de carga em curva sustentada", 2.0, minimum=1.0, maximum=6, group=R),
              ParamSpec("V_turn", "velocidade da curva", round(Vc, 1), minimum=3, maximum=80, unit="m/s", group=R),
              ParamSpec("h_ceiling", "teto", 0.0, minimum=0, maximum=10000, unit="m", group=R),
              ParamSpec("rho", "densidade no campo", ac.environment.rho if ac is not None else 1.225, minimum=0.3,
                        maximum=1.4, unit="kg/m³", group=R),
              ParamSpec("source", "de onde vem a polar", SOURCES[0], kind="choice", choices=SOURCES, group=A,
                        rebuild=True, help="estimativa: dimensionamento antes da geometria; aba Aerodinâmica: a polar "
                                           "calculada para a configuração atual")]
        if values.get("source", SOURCES[0]) == SOURCES[0]:
            AR0 = round(ac.wing.aspect_ratio, 2) if ac is not None and ac.wing is not None else 7.0
            ps += [ParamSpec("Swet_S", "área molhada / área de asa", 4.0, minimum=2, maximum=10, group=A,
                             help="Raymer fig. 12.4: ~4 para monomotor leve, ~3 para asa voadora"),
                   ParamSpec("Cfe", "atrito equivalente C_fe", 0.0055, minimum=0.001, maximum=0.02, step=0.0005, group=A,
                             help="Raymer tab. 12.3: 0,0055 monomotor leve; 0,0045 bimotor leve; 0,0030 planador"),
                   ParamSpec("AR", "alongamento", AR0, minimum=1, maximum=40, group=A),
                   ParamSpec("e", "Oswald (0: Raymer pelo alongamento)", 0.0, minimum=0, maximum=1.2, group=A),
                   ParamSpec("CLmax", "C_Lmax", 1.4, minimum=0.5, maximum=4, group=A),
                   ParamSpec("CL_TO", "C_L na corrida", 0.5, minimum=0, maximum=2, group=A)]
        ps += [ParamSpec("mu", "atrito de rolamento", ac.gear.mu_roll if ac is not None else 0.04, minimum=0, maximum=0.3,
                         group=A),
               ParamSpec("mu_brake", "atrito na frenagem", ac.gear.mu_brake if ac is not None else 0.3, minimum=0.05,
                         maximum=1.0, group=A),
               ParamSpec("dCD_TO", "C_D extra na corrida (trem, flape)", 0.01, minimum=0, maximum=0.3, group=A),
               ParamSpec("tol", "faixa ótima: T/W até o mínimo +", 5.0, minimum=0.5, maximum=50, unit="%", group=D),
               ParamSpec("eta_p", "eficiência da hélice (para P/m)", 0.6, minimum=0.2, maximum=0.9, group=D)]
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac, values=None):
        ws = "carga alar W/S (N/m²)"
        return [PlotSpec("c", "Tração/peso exigida × carga alar — azul: região viável; laranja: faixa ótima",
                         "ws", ("tw",), ws, "T/W", live=False, source="series:c_*"),
                PlotSpec("p", "Potência por massa exigida × carga alar (hélice, η_p)", "ws", ("pw",), ws, "P/m (W/kg)",
                         live=False, source="series:p_*"),
                PlotSpec("t", "Tração do motor × velocidade (pontos: o que cada requisito pede na W/S atual)", "V",
                         ("tw",), "V (m/s)", "T/W", live=False, source="series:t_*")]

    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        P = lambda k: self.param(ctx, k)
        S_, summ, checks = {}, {}, []
        add = lambda *a, **k: checks.append(Check(*a, **k))
        model = build_model(ac)
        req = Requirements(P("rho"), P("V_stall"), P("S_G"), P("S_L"), P("mu_brake"), P("V_cruise"), P("V_max"),
                           P("V_climb"), P("roc"), P("climb_grad"), P("n_turn"), P("V_turn"), P("h_ceiling"))
        # ------------- polar (de fora: estimativa ou módulo de aerodinâmica)
        ctx.on_progress(0.1, "polar")
        if P("source") == SOURCES[0]:
            pol = estimate_polar(P("Swet_S"), P("Cfe"), P("AR"), P("e") or None, P("CLmax"), P("CL_TO"), P("dCD_TO"),
                                 P("mu"))
            src = f"estimativa: C_D0 = C_fe·S_molhada/S, AR {P('AR'):g}"
        else:
            ap, src = aircraft_polar(ctx.backend, model, P("V_cruise"), ctx.shared)
            fit = parabolic_polar(ap)
            pol = ParabolicPolar(fit["CD0"], fit["k"], fit["CLmax"], fit["CL_a0"],
                                 fit["CD0"] + fit["k"] * fit["CL_a0"] ** 2 + P("dCD_TO"), P("mu"))
        summ["polar"] = src
        summ["C_D0, k, C_Lmax"] = [pol.CD0, pol.k, pol.CLmax]
        # ------------- aeronave atual (massa, área, tração disponível)
        with ctx.backend.session_for(model) as s:
            m = s.mass_props()["m"]
            n = sum(1 for u in ac.propulsion if u.enabled)
            Vg = np.linspace(0, 1.3 * max(P("V_max"), P("V_cruise"), 20.0), 50)
            T = np.array([sum(s.prop_point(i, v, 1.0)["T"] for i in range(n)) for v in Vg])
        W = m * G0
        ws_ac = W / model.S
        summ["aeronave: massa (kg), S (m²), W/S (N/m²)"] = [m, model.S, ws_ac]
        # ------------- diagrama
        tol = P("tol") / 100
        dp = design_point(req, pol, tol=tol)
        lims = ws_limits(req, pol)
        top_ws = max(1.3 * dp["ws_max"], 1.15 * ws_ac)
        ws = np.linspace(0.05 * top_ws, top_ws, 400)
        kinds = active_kinds(req)
        curves = {k: required_tw(k, ws, req, pol) for k in kinds}
        env_all = np.max(np.vstack(list(curves.values())), axis=0)
        tw_top = float(min(max(2.5 * dp["tw"], 1.5 * T[0] / W if n else 0.0, 0.3), 3.0))
        feas = ws <= dp["ws_max"]
        S_["c_região viável"] = {"ws": ws[feas], "tw": np.minimum(env_all[feas], tw_top),
                                 "tw2": np.full(feas.sum(), tw_top), "_fill": "tw2", "_color": COLOR["regiao"]}
        b0, b1 = dp["band"]
        band = feas & (ws >= b0) & (ws <= b1)
        S_[f"c_faixa ótima (até +{P('tol'):g} %)"] = {"ws": ws[band], "tw": np.minimum(env_all[band], tw_top),
                                                     "tw2": np.full(band.sum(), tw_top), "_fill": "tw2",
                                                     "_strong": 1, "_color": COLOR["otima"]}
        for lab_, x_ in (("início", b0), ("fim", b1)):
            S_[f"c_faixa ótima: {lab_} ({x_:.0f} N/m²)"] = {"ws": np.array([x_, x_]), "tw": np.array([0.0, tw_top]),
                                                          "_dash": 1, "_color": COLOR["otima"]}
        for k in kinds:
            S_[f"c_{LAB[k]}"] = {"ws": ws, "tw": np.minimum(curves[k], tw_top * 1.05), "_color": COLOR[k]}
        for k, v in lims.items():
            S_[f"c_{LAB[k]} (limite)"] = {"ws": np.array([v, v]), "tw": np.array([0.0, tw_top]), "_dash": 1,
                                          "_color": COLOR[k]}
        S_["c_ponto de projeto"] = {"ws": np.array([dp["ws"]]), "tw": np.array([dp["tw"]]), "_marker": 1,
                                    "_color": COLOR["projeto"]}
        if n:
            S_["c_aeronave atual (tração estática)"] = {"ws": np.array([ws_ac]), "tw": np.array([T[0] / W]),
                                                        "_marker": 1, "_color": COLOR["aeronave"]}
        # potência por massa
        eta = P("eta_p")
        for k in kinds:
            Vk = np.array([condition_speed(k, w_, req, pol) for w_ in ws])
            S_[f"p_{LAB[k]}"] = {"ws": ws, "pw": np.minimum(curves[k] * Vk / eta * G0, 1e4), "_color": COLOR[k]}
        Vd = condition_speed(dp["active"], dp["ws"], req, pol)
        S_["p_ponto de projeto"] = {"ws": np.array([dp["ws"]]), "pw": np.array([dp["tw"] * Vd / eta * G0]),
                                    "_marker": 1, "_color": COLOR["projeto"]}
        for k, v in lims.items():
            S_[f"p_{LAB[k]} (limite)"] = {"ws": np.array([v, v]),
                                          "pw": np.array([0.0, float(np.nanmax([S_[f'p_{LAB[q]}']['pw'] for q in kinds]))]),
                                          "_dash": 1, "_color": COLOR[k]}
        # tração do motor e pedidos
        if n:
            S_["t_disponível (acelerador total)"] = {"V": Vg, "tw": T / W}
        Tat = lambda V: float(np.interp(V, Vg, T)) / W
        G = "requisitos"
        for k in kinds:
            V = condition_speed(k, ws_ac, req, pol)
            need = float(required_tw(k, [ws_ac], req, pol)[0])
            S_[f"t_pedido: {LAB[k]}"] = {"V": np.array([V]), "tw": np.array([need]), "_marker": 1, "_color": COLOR[k]}
            if not n:
                continue
            have = Tat(V) * ((isa_rho(req.h_ceiling) / 1.225) ** req.thrust_rho_exp if k == "teto" else 1.0)
            ok = have >= need
            add("ok" if ok else "falha", LAB[k], f"disponível {have:.3f} × exigido {need:.3f} a {V:.1f} m/s",
                "T/W disponível ≥ exigido",
                "" if ok else f"com W/S = {ws_ac:.0f} N/m² o motor entrega T/W {have:.3f} nessa velocidade",
                "" if ok else f"tração +{100 * (need / max(have, 1e-9) - 1):.0f} % a {V:.1f} m/s, ou levar a W/S para "
                              f"a faixa ótima", G, source="Gudmundsson cap. 3; Raymer cap. 5")
        for k, v in lims.items():
            ok = ws_ac <= v
            add("ok" if ok else "falha", LAB[k], f"W/S {ws_ac:.0f} × limite {v:.0f} N/m²", "W/S ≤ limite",
                "" if ok else ("carga alar alta demais para o C_Lmax" if k == "estol" else
                               "a velocidade de toque fica alta para frear na distância pedida"),
                "" if ok else f"área de asa ≥ {W / v:.3f} m² (hoje {model.S:.3f} m²) ou C_Lmax maior (flape)", G,
                source="Raymer cap. 5" if k == "estol" else "Raymer cap. 5 (pouso simplificado)")
        # ------------- projeto
        Sd = W / dp["ws"]
        S0, S1 = W / b1, W / b0
        summ["ponto de projeto: W/S (N/m²), T/W, quem manda"] = [dp["ws"], dp["tw"], LAB[dp["active"]]]
        summ["faixa ótima: W/S (N/m²) e área de asa (m²)"] = [b0, b1, S0, S1]
        summ["limite de W/S"] = f"{LAB[dp['ws_limiter']]} ({dp['ws_max']:.0f} N/m²)"
        P_d = dp["tw"] * Vd / eta * W
        add("info", "ponto de projeto (menor motor que atende tudo)",
            f"W/S = {dp['ws']:.0f} N/m² → S = {Sd:.3f} m²; T/W = {dp['tw']:.3f} (T = {dp['tw'] * W:.1f} N, "
            f"P ≈ {P_d:.0f} W)", "acima de todas as curvas, à esquerda dos limites",
            f"quem manda: {LAB[dp['active']]}" + (f"; encostado no limite de {LAB[dp['ws_limiter']]}" if dp["at_limit"] else ""),
            f"com a massa atual ({m:.2f} kg): asa entre {S0:.3f} e {S1:.3f} m² fica a até +{P('tol'):g} % do T/W mínimo",
            "projeto", source="Gudmundsson cap. 3")
        inside = n and ws_ac <= dp["ws_max"] and all(
            Tat(condition_speed(k, ws_ac, req, pol)) >= float(required_tw(k, [ws_ac], req, pol)[0]) for k in kinds)
        add("ok" if inside else "falha", "aeronave atual dentro da região viável",
            f"W/S = {ws_ac:.0f} N/m², S = {model.S:.3f} m²", "todos os requisitos ao mesmo tempo",
            "" if inside else "ver os requisitos que falham acima", "" if inside else
            f"ponto de projeto: S ≈ {Sd:.3f} m² e T/W ≈ {dp['tw']:.3f} na condição de {LAB[dp['active']]}", "projeto")
        return SimResult(series=S_, summary=summ, checks=checks)

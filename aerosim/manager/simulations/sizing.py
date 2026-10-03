"""Aba Dimensionamento inicial — diagrama de restrições (T/W × W/S) com os requisitos que o
usuário digita, o ponto da aeronave atual e o diagnóstico de cada requisito usando a tração
disponível do motor naquela velocidade. Sugere a área de asa e a tração para o ponto de projeto.
Equações em `aerosim.sizing.constraints` (Gudmundsson cap. 3; Raymer cap. 5)."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.compile import compile_aircraft
from aerosim.sizing import AeroModel, Requirements, constraint_curves, design_point, required_tw
from aerosim.sizing.constraints import KINDS, isa_rho, stall_ws

from .base import SimulationBase

G0 = 9.80665
LAB = dict(KINDS)


def _aircraft_aero(backend, ac):
    """C_D0, k, C_Lmax, massa e tração disponível T(V) pela polar e pelos motores do núcleo"""
    S, c, b = ac.references()
    with backend.open_session() as s:
        s.configure(compile_aircraft(ac))
        al = np.radians(np.arange(-4, 25.01, 0.5))
        rows = [s.aero_coeffs(15.0, a) for a in al]
        CL = np.array([r["CL"] for r in rows])
        CD = np.array([r["CD"] for r in rows])
        m = s.mass_props()["m"]
        n = sum(1 for u in ac.propulsion if u.enabled)
        Vs = np.linspace(0, 40, 41)
        T = np.array([sum(s.prop_point(i, v, 1.0)["T"] for i in range(n)) for v in Vs])
    sel = (al > math.radians(-2)) & (al < math.radians(8))
    k, CD0 = np.polyfit(CL[sel] ** 2, CD[sel], 1)
    return dict(CD0=float(CD0), k=float(k), CLmax=float(CL.max()), CL_TO=float(np.interp(0.0, al, CL)),
                m=m, S=S, AR=b * b / S, V=Vs, T=T)


class SizingSimulation(SimulationBase):
    name = "sizing"
    title = "Dimensionamento inicial"
    description = ("Diagrama de restrições: quanto de tração por peso (T/W) cada requisito exige em função da carga "
                   "alar (W/S). Mostra onde a aeronave atual está, quais requisitos ela cumpre com o motor que tem, e "
                   "o ponto de projeto (área de asa e tração) que atende todos com o menor motor.")

    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac, values=None):
        values = values or {}
        from .stability import _cruise_speed
        Vc = _cruise_speed(ac) if ac is not None else 15.0
        R, A = "Requisitos", "Polar"
        ps = [ParamSpec("V_stall", "velocidade de estol máxima", round(0.7 * Vc, 1), minimum=2, maximum=60, unit="m/s",
                        group=R),
              ParamSpec("S_G", "corrida de decolagem máxima", 50.0, minimum=1, maximum=2000, unit="m", group=R),
              ParamSpec("V_cruise", "velocidade de cruzeiro", round(Vc, 1), minimum=3, maximum=100, unit="m/s", group=R),
              ParamSpec("roc", "razão de subida", 2.0, minimum=0, maximum=30, unit="m/s", group=R),
              ParamSpec("V_climb", "velocidade de subida", round(0.85 * Vc, 1), minimum=3, maximum=80, unit="m/s",
                        group=R),
              ParamSpec("n_turn", "fator de carga em curva sustentada", 2.0, minimum=1.0, maximum=6, group=R),
              ParamSpec("V_turn", "velocidade da curva", round(Vc, 1), minimum=3, maximum=80, unit="m/s", group=R),
              ParamSpec("h_ceiling", "teto (0: não verifica)", 0.0, minimum=0, maximum=10000, unit="m", group=R),
              ParamSpec("rho", "densidade no campo", ac.environment.rho if ac is not None else 1.225, minimum=0.3,
                        maximum=1.4, unit="kg/m³", group=R),
              ParamSpec("polar", "polar e C_Lmax", "da aeronave", kind="choice", choices=("da aeronave", "manual"),
                        group=A, rebuild=True, help="da aeronave: núcleo Zig; manual: valores de partida (sem geometria)")]
        if values.get("polar") == "manual":
            ps += [ParamSpec("CD0", "C_D0", 0.03, minimum=0.001, maximum=0.5, group=A),
                   ParamSpec("AR", "alongamento", 7.0, minimum=1, maximum=40, group=A),
                   ParamSpec("e", "fator de Oswald", 0.8, minimum=0.3, maximum=1.2, group=A),
                   ParamSpec("CLmax", "C_Lmax", 1.4, minimum=0.5, maximum=4, group=A),
                   ParamSpec("CL_TO", "C_L na corrida", 0.5, minimum=0, maximum=2, group=A)]
        ps += [ParamSpec("mu", "atrito de rolamento", ac.gear.mu_roll if ac is not None else 0.04, minimum=0, maximum=0.3,
                         group=A),
               ParamSpec("CD_TO_extra", "C_D extra na corrida (trem, flape)", 0.01, minimum=0, maximum=0.3, group=A)]
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac, values=None):
        return [PlotSpec("c", "T/W exigido × carga alar — a região viável fica acima de todas as curvas e à "
                              "esquerda do estol", "ws", ("tw",), "carga alar W/S (N/m²)", "T/W exigido",
                         live=False, source="series:c_*"),
                PlotSpec("t", "Tração disponível do motor × velocidade (pontos: o que cada requisito pede na W/S atual)",
                         "V", ("tw",), "V (m/s)", "T/W", live=False, source="series:t_*")]

    def run(self, ctx: RunContext) -> SimResult:
        ac = ctx.aircraft.copy()
        ac.apply_constraints()
        P = lambda k: self.param(ctx, k)
        S_, summ, checks = {}, {}, []
        add = lambda *a, **k: checks.append(Check(*a, **k))
        ctx.on_progress(0.1, "polar e motores da aeronave")
        aa = _aircraft_aero(ctx.backend, ac)
        if P("polar") == "manual":
            k = 1 / (math.pi * P("AR") * P("e"))
            aero = AeroModel(P("CD0"), k, P("CLmax"), P("CL_TO"), P("CD0") + k * P("CL_TO") ** 2 + P("CD_TO_extra"),
                             P("mu"))
        else:
            aero = AeroModel(aa["CD0"], aa["k"], aa["CLmax"], aa["CL_TO"],
                             aa["CD0"] + aa["k"] * aa["CL_TO"] ** 2 + P("CD_TO_extra"), P("mu"))
        req = Requirements(P("rho"), P("V_stall"), P("S_G"), P("V_cruise"), P("V_climb"), P("roc"), P("n_turn"),
                           P("V_turn"), P("h_ceiling"))
        W = aa["m"] * G0
        ws_ac = W / aa["S"]
        summ["polar usada: C_D0, k, C_Lmax"] = [aero.CD0, aero.k, aero.CLmax]
        summ["aeronave: W (N), S (m²), W/S (N/m²)"] = [W, aa["S"], ws_ac]
        ws_st = stall_ws(req, aero)
        top = max(1.4 * ws_st, 1.2 * ws_ac)
        ws = np.linspace(0.05 * top, top, 300)
        cur = constraint_curves(req, aero, ws)
        for k_ in cur:
            if k_ != "ws":
                S_[f"c_{LAB[k_]}"] = {"ws": ws, "tw": cur[k_]}
        hi = float(np.nanmax(np.vstack([cur[k_] for k_ in cur if k_ != "ws"])))
        hi = min(hi, 3.0)
        S_[f"c_estol (V_S = {req.V_stall:g} m/s)"] = {"ws": np.array([ws_st, ws_st]), "tw": np.array([0, hi]),
                                                      "_dash": 1}
        dp = design_point(req, aero)
        S_["c_ponto de projeto"] = {"ws": np.array([dp["ws"]]), "tw": np.array([dp["tw"]]), "_marker": 1}
        T0 = float(aa["T"][0])
        S_["c_aeronave atual (T estática)"] = {"ws": np.array([ws_ac]), "tw": np.array([T0 / W]), "_marker": 1}
        # tração disponível × V e pedidos
        Vg = aa["V"]
        S_["t_disponível (acelerador total)"] = {"V": Vg, "tw": aa["T"] / W}
        G = "requisitos"
        Tat = lambda V: float(np.interp(V, Vg, aa["T"])) / W
        Vlof = 1.1 * math.sqrt(2 * ws_ac / (req.rho * aero.CLmax))
        speeds = {"decolagem": Vlof / math.sqrt(2), "subida": req.V_climb, "cruzeiro": req.V_cruise,
                  "curva": req.V_turn}
        if req.h_ceiling > 0:
            speeds["teto"] = math.sqrt(2 * ws_ac / (isa_rho(req.h_ceiling) * math.sqrt(3 * aero.CD0 / aero.k)))
        for k_, V in speeds.items():
            need = float(required_tw(k_, [ws_ac], req, aero)[0])
            have = Tat(V) * ((isa_rho(req.h_ceiling) / 1.225) ** req.thrust_rho_exp if k_ == "teto" else 1.0)
            S_[f"t_pedido: {LAB[k_]}"] = {"V": np.array([V]), "tw": np.array([need]), "_marker": 1}
            ok = have >= need
            add("ok" if ok else "falha", LAB[k_], f"disponível {have:.3f} × exigido {need:.3f} (V = {V:.1f} m/s)",
                "T/W disponível ≥ exigido", "" if ok else
                f"na W/S atual ({ws_ac:.0f} N/m²) o motor entrega T/W {have:.3f} a {V:.1f} m/s",
                "" if ok else f"tração +{100 * (need / max(have, 1e-9) - 1):.0f} % nessa velocidade ou mudar W/S "
                              f"(ver o ponto de projeto)", G, source="Gudmundsson cap. 3; Raymer cap. 5")
        ok = ws_ac <= ws_st
        Vs_ac = math.sqrt(2 * ws_ac / (req.rho * aero.CLmax))
        add("ok" if ok else "falha", "velocidade de estol", f"{Vs_ac:.1f} m/s (W/S {ws_ac:.0f} N/m²)",
            f"V_S ≤ {req.V_stall:g} m/s", "" if ok else "carga alar alta demais para o C_Lmax",
            "" if ok else f"área de asa ≥ {W / ws_st:.3f} m² (hoje {aa['S']:.3f}) ou C_Lmax maior (flape)", G)
        S_dp = W / dp["ws"]
        summ["ponto de projeto: W/S, T/W, requisito que manda"] = [dp["ws"], dp["tw"], LAB[dp["active"]]]
        add("info", "ponto de projeto (menor motor que atende tudo)",
            f"W/S = {dp['ws']:.0f} N/m² → S = {S_dp:.3f} m²; T/W = {dp['tw']:.3f} → T = {dp['tw'] * W:.1f} N",
            "acima de todas as curvas e à esquerda do estol", f"quem manda: {LAB[dp['active']]}",
            f"com a massa atual ({aa['m']:.2f} kg): asa de {S_dp:.3f} m² e tração de {dp['tw'] * W:.1f} N "
            "na condição do requisito ativo", "projeto", source="Gudmundsson cap. 3")
        return SimResult(series=S_, summary=summ, checks=checks)

"""Missão (simulação 6GDL): todas as análises de voo simulado numa aba só, separadas por etapa
do voo (corrida no chão, cada perna do percurso, rolagem), como no código original.

Modos (o formulário e os gráficos mudam com o modo):
  missão por etapas     o circuito inteiro ou até o fim de uma etapa; cada etapa começa num
                        checkpoint salvo, então dá para mudar a configuração e rodar de novo só
                        dali para frente ("começar de: início de <etapa>")
  só decolagem          até h_end acima da pista/mesa; opcional: mapa s_R × δe1 com o melhor ponto
  curvas: raio mínimo   para cada V, raio mínimo em curva nivelada (estol, α, seguimento, altura);
                        complementa o cálculo de curva sem simulação da aba Desempenho
  MTOW                  bisseção na massa: a maior que ainda decola com x_warning = 0 e z_warning = 0,
                        iterando o acionamento do profundor (s_R ou V_R, δe1) junto com o xCG
  subida simulada       γ obtido × pedido a partir de um checkpoint nivelado

Avisos de pista (manager/analysis.py, `warnings`):
  x_warning  saiu do chão (ou da mesa) depois da distância de decolagem exigida
  z_warning  mesa: o CG afundou abaixo da altura de repouso depois de sair dela (só na decolagem);
             plataforma: tocou fora dela (só no pouso). Decolando do chão, só o pouso conta.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import LogChunk
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.mission import MissionEvent, level_turn, takeoff_runway
from aerosim.model.universal import build_model

from .. import flightplots as FP
from ..analysis import (V_BOUNCE, V_EARLY, V_NOCLIMB, V_Q, V_STALL, V_TAIL, V_VSAFE, columns, evaluate_turn,
                        min_radius, stage_table, takeoff_violations, violation_text, warnings)
from ..runner import Runner, Stop
from .base import SimulationBase, floats

MODES = ("missão por etapas", "só decolagem", "curvas: raio mínimo", "MTOW (bisseção: x_warning e z_warning)",
         "subida simulada (γ máximo)")
M_MIS, M_TO, M_TURN, M_MTOW, M_CLIMB = MODES
END = "fim da missão (parada na pista)"
AUTOP = "piloto automático liga (h_t)"
ELEV = ("da aeronave", "distância s_R", "velocidade V_R")
G_TO, G_CMD, G_RUN = "Decolagem", "Comando do profundor", "Execução"


def _refs(ac, info) -> dict:
    r = dict(Vs=info["Vs"], alpha_stall=info["alpha_stall"], kCL=ac.autopilot.kCL, ht=ac.takeoff.ht,
             runway_max=ac.airfield.runway_max, landing_max=ac.airfield.landing_max)
    legs = ac.gear.legs()
    mains = [g for g in legs if g.kind == "main"]
    skids = [g for g in legs if g.kind == "skid"]
    if mains and skids:
        m, s = mains[0], skids[0]
        if m.x > s.x:
            r["theta_tail"] = math.degrees(math.atan2(m.z - s.z, m.x - s.x))
    return r


class MissionSimulation(SimulationBase):
    name = "mission"
    title = "Missão"
    description = ("Voo simulado (6GDL) por etapa: missão inteira ou até uma etapa, só a decolagem, curvas "
                   "(raio mínimo), MTOW por bisseção (x_warning e z_warning) e subida simulada.")

    # ------------------------------------------------------------------ formulário
    def parameters(self):
        return self.parameters_for(None, {})

    def parameters_for(self, ac, values=None):
        values = values or {}
        mode = values.get("mode", M_MIS)
        P = [ParamSpec("mode", "Análise", M_MIS, kind="choice", choices=MODES, rebuild=True,
                       help="o formulário e os gráficos mudam com a análise")]
        legs = ac.mission.names() if ac is not None else []
        has_pay = ac is not None and ac.payload.enabled
        if mode == M_MIS:
            P += [ParamSpec("start", "Começar de", "chão", kind="choice",
                            choices=("chão",) + tuple(f"início: {n}" for n in legs[1:]),
                            help="usa o checkpoint salvo no início da etapa (se não houver, roda do chão e salva)",
                            group="Etapas"),
                  ParamSpec("until", "Parar em", END, kind="choice",
                            choices=(END, AUTOP) + tuple(f"fim: {n}" for n in legs[:-1]), group="Etapas")]
            if has_pay:
                P += [ParamSpec("aim", "Procurar onde soltar a carga para acertar o alvo", ac.payload.aim, kind="bool",
                                group="LAPES (configurado na aba Configuração)"),
                      ParamSpec("iters", "Iterações da bisseção da soltura", 8, kind="int", minimum=2, maximum=20,
                                group="LAPES (configurado na aba Configuração)")]
            P += self._env_params()
        elif mode == M_TO:
            P += self._elevator_params(ac) + [
                ParamSpec("h_end", "Altura final", 6.0, minimum=1, maximum=50, unit="m", group=G_TO),
                ParamSpec("runway", "Distância máxima de decolagem (0 = da configuração)", 0.0, minimum=0,
                          maximum=2000, unit="m", group=G_TO),
                ParamSpec("dtlog", "Registro a cada", 0.005, minimum=0.001, maximum=0.1, unit="s", group=G_RUN),
                ParamSpec("sweep", "Mapa s_R × δe1 (com o melhor ponto)", False, kind="bool", group="Mapa"),
                ParamSpec("sR_list", "s_R do mapa", "20, 25, 30, 35, 40, 45, 50", kind="floats", unit="m", group="Mapa"),
                ParamSpec("de1_list", "δe1 do mapa", "-12, -9, -6, -3, 0", kind="floats", unit="°", group="Mapa")]
            P += self._env_params(wind=True, slosh=False)
        elif mode == M_TURN:
            P += [ParamSpec("V_list", "Velocidades", "13, 15, 17", kind="floats", unit="m/s", group="Curvas"),
                  ParamSpec("R_list", "Raios (a 15 m/s; escalam com V²)", "12, 16, 20, 25, 30, 40, 50, 70",
                            kind="floats", unit="m", group="Curvas"),
                  ParamSpec("angle", "Ângulo da curva", 240.0, minimum=90, maximum=720, unit="°", group="Curvas"),
                  ParamSpec("side", "Lado", "direita", kind="choice", choices=("direita", "esquerda"), group="Curvas"),
                  ParamSpec("h", "Altura", 30.0, minimum=5, maximum=500, unit="m", group="Curvas"),
                  ParamSpec("alpha_lim", "α máx. do piloto (0 = da aeronave)", 0.0, minimum=0, maximum=30, unit="°",
                            group="Critérios"),
                  ParamSpec("phimax", "Inclinação máx. liberada", 75.0, minimum=10, maximum=85, unit="°",
                            group="Critérios"),
                  ParamSpec("hloss", "Perda de altura máxima", 3.0, minimum=0.2, maximum=50, unit="m",
                            group="Critérios")]
            P += self._env_params(wind=True, slosh=False)
        elif mode == M_MTOW:
            P += [ParamSpec("dm_lo", "Massa extra mínima (pode ser negativa)", -3.0, minimum=-50, maximum=50,
                            unit="kg", group="MTOW"),
                  ParamSpec("dm_hi", "Massa extra máxima", 8.0, minimum=-50, maximum=200, unit="kg", group="MTOW"),
                  ParamSpec("tol", "Precisão da bisseção", 0.1, minimum=0.005, maximum=5, unit="kg", group="MTOW"),
                  ParamSpec("runway", "Distância máxima de decolagem (0 = da configuração)", 0.0, minimum=0,
                            maximum=2000, unit="m", group="MTOW"),
                  ParamSpec("h_end", "Altura final da decolagem", 6.0, minimum=1, maximum=50, unit="m", group="MTOW"),
                  ParamSpec("dx_list", "xCG de decolagem: deslocamentos a testar (+ para a frente)", "-2, 0, 2",
                            kind="floats", unit="cm", group="Iterado junto em cada massa"),
                  ParamSpec("by", "Acionamento do profundor por", "distância s_R", kind="choice",
                            choices=("distância s_R", "velocidade V_R"), group="Iterado junto em cada massa"),
                  ParamSpec("act_list", "s_R ou V_R a testar", "15, 25, 35", kind="floats", unit="m ou m/s",
                            group="Iterado junto em cada massa"),
                  ParamSpec("de1_list", "δe1 a testar", "-12, -8, -4", kind="floats", unit="°",
                            group="Iterado junto em cada massa"),
                  ParamSpec("criteria", "Exigir também (além de x e z)", "estol, cauda e V em h_t", kind="choice",
                            choices=("estol, cauda e V em h_t", "só x_warning e z_warning"), group="MTOW")]
            if ac is not None and ac.airfield.landing_on == "plataforma":
                P.append(ParamSpec("landing", "z_warning do pouso: rodar a missão até pousar na plataforma", True,
                                   kind="bool", group="MTOW"))
            P += self._env_params(wind=True, slosh=False)
        else:
            P += [ParamSpec("V_list", "Velocidades", "12, 14, 16", kind="floats", unit="m/s", group="Subida"),
                  ParamSpec("grads", "Gradientes pedidos (tan γ)", "0.02, 0.05, 0.08, 0.11, 0.14, 0.17", kind="floats",
                            group="Subida"),
                  ParamSpec("window", "Janela de medida", 15.0, minimum=3, maximum=120, unit="s", group="Subida"),
                  ParamSpec("h0", "Altura inicial", 30.0, unit="m", group="Subida")]
        return P

    @staticmethod
    def _elevator_params(ac):
        to = ac.takeoff if ac is not None else None
        return [ParamSpec("elev", "Comando do profundor", "da aeronave", kind="choice", choices=ELEV, group=G_CMD,
                          help="'da aeronave' usa s_R/V_R/δe1 da aba Configuração"),
                ParamSpec("sR", "s_R (distância para puxar)", to.sR if to and to.sR > 0 else 37.5, minimum=0,
                          maximum=500, unit="m", group=G_CMD),
                ParamSpec("VR", "V_R (velocidade para puxar)", to.VR if to else 12.5, minimum=0, maximum=60, unit="m/s",
                          group=G_CMD),
                ParamSpec("de1", "δe1 (profundor depois)", to.de1 if to else -6.0, minimum=-30, maximum=30, unit="°",
                          group=G_CMD)]

    @staticmethod
    def _env_params(wind=False, slosh=True):
        out = []
        if slosh:
            out += [ParamSpec("slosh", "Sloshing", True, kind="bool", group=G_RUN),
                    ParamSpec("gust", "Rajada", False, kind="bool", group=G_RUN)]
        if wind:
            out.append(ParamSpec("wind", "Com vento", True, kind="bool", group=G_RUN))
        out.append(ParamSpec("chunk", "Fatia de tempo real", 0.5, minimum=0.05, maximum=10, unit="s", group=G_RUN))
        return out

    # ------------------------------------------------------------------ gráficos
    def plots(self):
        return self.plots_for(None, {})

    def plots_for(self, ac, values=None):
        mode = (values or {}).get("mode", M_MIS)
        traj = [PlotSpec("t3", "Trajetória 3D (cores: etapas do voo; ★ eventos)", "e", ("n",), "e (m) — leste",
                         "n (m) — eixo da pista", source="series:t3_*", kind="3d", z="h", height=720),
                PlotSpec("xz", "Plano XZ — perfil: posição na pista × altura", "n", ("h",), "n (m) — eixo da pista",
                         "h (m)", source="series:xz_*", live_ys=("h",)),
                PlotSpec("xy", "Plano XY — vista de cima", "n", ("e",), "n (m) — eixo da pista", "e (m) — leste",
                         source="series:xy_*", live_ys=("e",), aspect=True, invert_y=True),
                PlotSpec("zy", "Plano ZY — vista de frente", "e", ("h",), "e (m) — leste", "h (m)", source="series:zy_*",
                         live_ys=("h",))]
        takeoff = [
            PlotSpec("dh", "Decolagem: subida do CG e folga da cauda × posição na pista", "n", ("y",),
                     "n (m) — posição na pista", "altura (m)", source="series:dh_*"),
            PlotSpec("dv", "Decolagem: velocidades × posição na pista", "n", ("y",), "n (m)", "V (m/s)",
                     source="series:dv_*", live_ys=("Va", "Vg")),
            PlotSpec("da", "Decolagem: θ, α, γ × posição na pista", "n", ("y",), "n (m)", "ângulo (°)",
                     source="series:da_*"),
            PlotSpec("dc", "Decolagem: comandos (superfícies em °, acelerador × 10)", "n", ("y",), "n (m)", "°",
                     source="series:dc_*"),
            PlotSpec("dr", "Decolagem: reações normais no trem (molas e artigo)", "n", ("y",), "n (m)", "N",
                     source="series:dr_*", live_ys=("N_steer", "N_main")),
            PlotSpec("dm", "Decolagem: momentos do trem no CG", "n", ("y",), "n (m)", "N·m", source="series:dm_*")]
        if mode == M_TO:
            return takeoff + traj[:2] + [
                PlotSpec("mapa", "Mapa de decolagem: corrida até sair do chão (★ melhor ponto)", "sR", ("de1",),
                         "s_R: distância de acionamento do profundor (m)", "δe1 (°)", live=False, source="series:mapa_*")]
        if mode == M_TURN:
            return [PlotSpec("cv", "Curvas: trajetórias (vista de cima; tracejado = falha)", "e", ("n",), "e (m)", "n (m)",
                             source="series:cv_*", live_ys=("n",), aspect=True),
                    PlotSpec("cr", "C_L/C_Lmax máximo da meia asa × raio pedido (x = falha)", "R", ("y",), "R (m)", "—",
                             live=False, source="series:cr_*"),
                    PlotSpec("cp", "Inclinação em regime × raio pedido", "R", ("y",), "R (m)", "|φ| (°)", live=False,
                             source="series:cp_*"),
                    PlotSpec("ch", "Altura perdida na curva × raio pedido", "R", ("y",), "R (m)", "m", live=False,
                             source="series:ch_*"),
                    PlotSpec("cn", "Fator de carga em regime × raio pedido", "R", ("y",), "R (m)", "g", live=False,
                             source="series:cnz_*"),
                    PlotSpec("rmin", "Raio mínimo por velocidade (★)", "V", ("R",), "V (m/s)", "R mínimo (m)", live=False,
                             source="series:rm_*")]
        if mode == M_MTOW:
            return [PlotSpec("mt", "MTOW: distância até sair do chão × massa de decolagem (★ MTOW)", "m", ("y",),
                             "massa de decolagem (kg)", "n_LO (m)", live=False, source="series:mt_*"),
                    PlotSpec("mz", "MTOW: x_warning e z_warning × massa", "m", ("y",), "massa (kg)", "m", live=False,
                             source="series:mz_*"),
                    PlotSpec("mc", "Comando e xCG que passaram em cada massa", "m", ("y",), "massa (kg)",
                             "s_R (m) ou V_R (m/s) / δe1 (°) / ΔxCG (cm)", live=False, source="series:mc_*")] \
                + takeoff + traj[:2]
        if mode == M_CLIMB:
            from .climb import ClimbSimulation
            return ClimbSimulation().plots()
        has_pay = ac is None or ac.payload.enabled
        has_tank = ac is None or bool(ac.tanks)
        t = lambda key, title, ylab, live=(): PlotSpec(key, title, "t", ("y",), "t (s)", ylab,
                                                       source=f"series:{key}_*", live_ys=live)
        out = traj + [
            t("vel", "Velocidades (fundo: etapa do voo)", "V (m/s)", ("Va", "Vg")),
            t("alt", "Altura", "h (m)", ("h",)),
            t("ang", "Ângulos de atitude e aerodinâmicos", "ângulo (°)", ("theta", "alpha", "phi")),
            t("rumo", "Proa e curso (a diferença é o caranguejo contra o vento)", "ângulo (°)"),
            t("momL", "Momento de rolamento L no CG, parcela por parcela", "N·m"),
            t("momM", "Momento de arfagem M no CG, parcela por parcela", "N·m"),
            t("momN", "Momento de guinada N no CG, parcela por parcela", "N·m"),
            t("cmd", "Comandos das superfícies", "deflexão (°)", ("de", "da", "dr")),
            t("thr", "Acelerador", "0–1", ("thr",)),
            t("cl", "Coeficiente de sustentação", "C_L (—)"),
            t("cd", "Coeficiente de arrasto", "C_D (—)"),
            t("roc", "Razão de subida e descida", "dh/dt (m/s)"),
            t("nz", "Fator de carga", "n_z (g)", ("nz",)),
            t("motor", "Motor: rotação, corrente e tração", "rpm/100, A, N"),
            t("ene", "Energia gasta", "Wh")]
        if has_tank:
            out.append(t("slosh", "Sloshing: pêndulo equivalente do 1º modo", "ângulo (°)"))
        out += takeoff
        out += [PlotSpec("pr", "Pouso: reações normais no trem (molas e artigo)", "n", ("y",), "n (m) — posição na pista",
                         "N", live=False, source="series:pr_*"),
                PlotSpec("pm", "Pouso: momentos do trem no CG", "n", ("y",), "n (m)", "N·m", live=False,
                         source="series:pm_*")]
        if has_pay:
            out += [PlotSpec("lx", "LAPES (zoom): aeronave e carga no plano XZ", "n", ("h",), "n (m)", "h (m)",
                             live=False, source="series:lx_*"),
                    PlotSpec("lc", "LAPES (zoom): o CG anda para trás com a carga", "t", ("y",), "t − t_soltura (s)",
                             "cm", live=False, source="series:lc_*"),
                    PlotSpec("lm", "LAPES (zoom): massa da aeronave", "t", ("y",), "t − t_soltura (s)", "kg", live=False,
                             source="series:lm_*"),
                    PlotSpec("lp", "LAPES (zoom): resposta em arfagem", "t", ("y",), "t − t_soltura (s)",
                             "° , °/s , N·m", live=False, source="series:lp_*"),
                    PlotSpec("lapes", "LAPES: ponto de soltura × impacto da carga (★ escolhido)", "s", ("y",),
                             "s de soltura na perna (m)", "impacto n (m)", live=False, source="series:ls_*")]
        return out

    # ------------------------------------------------------------------ execução
    def run(self, ctx: RunContext) -> SimResult:
        mode = self.param(ctx, "mode")
        if mode == M_CLIMB:
            from .climb import ClimbSimulation
            return ClimbSimulation().run(ctx)
        ac, info = self.prepare(ctx)
        refs = _refs(ac, info)
        if mode == M_TO:
            return self._takeoff(ctx, ac, info, refs)
        if mode == M_TURN:
            return self._turns(ctx, ac, info, refs)
        if mode == M_MTOW:
            return self._mtow(ctx, ac, info, refs)
        return self._mission(ctx, ac, info, refs)

    def _env_over(self, ctx, ac) -> dict:
        p = ctx.params
        if "slosh" in p:
            ac.sim.slosh = bool(p["slosh"])
        if "gust" in p:
            ac.environment.gust = bool(p["gust"])
        return {} if p.get("wind", True) else dict(env=dict(Vw10=0.0))

    # ------------------------------------------------------------------ missão por etapas
    def _mission(self, ctx, ac, info, refs) -> SimResult:
        self._env_over(ctx, ac)
        mission = ac.mission
        legs = mission.names()
        nseg = len(legs)
        drop = next((e for e in mission.events if e.kind == "drop"), None)
        k_drop = drop.leg if drop is not None and ac.payload.enabled else None
        chunk = self.param(ctx, "chunk")
        start, until = self.param(ctx, "start"), self.param(ctx, "until")
        stop_at = nseg if until == END else (-1 if until == AUTOP else legs.index(until[5:]) + 1)
        store = ctx.checkpoints
        key = lambda k: f"missão: início de {legs[k]}"
        parts: list[LogChunk] = []
        series, notes = {}, []
        aim = bool(ctx.params.get("aim", ac.payload.aim)) and k_drop is not None
        with Runner(ctx.backend, ac, mission, None, ctx) as r:
            k0 = 0
            if start != "chão":
                k0 = legs.index(start[8:])
                ck = store.get(key(k0))
                if ck is None:
                    notes.append(f"sem checkpoint no início de '{legs[k0]}': rodou do chão e salvou os checkpoints")
                    k0 = 0
                else:
                    r.start_from(ck)
            if k0 == 0:
                r.start_ground()
            out = None
            if stop_at == -1:
                out = r.run(Stop(autopilot=True), chunk=chunk)
                parts.append(out.log)
            else:
                k = k0
                while k + 1 <= min(stop_at, nseg - 1):      # para ao entrar na etapa k + 1 e salva o checkpoint
                    ctx.on_progress(k / max(nseg, 1), f"etapa: {legs[k]}")
                    if aim and k == k_drop and store.get(key(k)) is not None:
                        mission, hist = self._aim(ctx, ac, mission, store.get(key(k)), k)
                        series.update(hist)
                        r.reconfigure(mission)
                        r.start_from(store.get(key(k)))
                        aim = False
                    out = r.run(Stop(segment=k + 1), chunk=chunk)
                    parts.append(out.log)
                    if out.status.name != "STOPPED":
                        break
                    r.checkpoint(key(k + 1), store)
                    k += 1
                if stop_at == nseg and (out is None or out.status.name == "STOPPED"):
                    if aim and k == k_drop and store.get(key(k)) is not None:
                        mission, hist = self._aim(ctx, ac, mission, store.get(key(k)), k)
                        series.update(hist)
                        r.reconfigure(mission)
                        r.start_from(store.get(key(k)))
                    ctx.on_progress(0.95, f"etapa: {legs[-1]}")
                    out = r.run(Stop(), chunk=chunk)
                    parts.append(out.log)
            ev = r.session.events()
        log = LogChunk.concat([p for p in parts if len(p)])
        target = (ac.payload.target_n, ac.payload.target_e) if k_drop is not None else None
        pl = ac.airfield.pads(mission)
        pads = [dict(q, landing=i == len(pl) - 1 and ac.airfield.landing_on == "plataforma") for i, q in enumerate(pl)]
        if len(log):
            series.update(FP.trajectory(log, ev, legs, target))
            series.update(FP.time_series(log, ev, legs, refs))
            series.update(FP.takeoff_window(log, ev, refs, ac.airfield))
            series.update(FP.landing_window(log, ev, refs, ac.airfield, pads))
            series.update(FP.lapes_window(log, ev, target[0] if target else None))
            table = stage_table(log, ev, legs, info["Vs"])
            if table:
                series["etapas"] = columns(table)
        else:
            table = []
        st = out.status.name if out else "—"
        W = warnings(ev, ac.airfield, landing=stop_at == nseg)
        checks = self._mission_checks(ac, info, refs, ev, W, table, st, stop_at == nseg, target)
        summary = dict(status=st, t_fim=ev["tend"], energia_Wh=ev["E"], n_decolou=ev["nLO"], x_warning=W["x_warning"],
                       z_warning=W["z_warning"], n_toque=ev["nTD"], n_parada=ev["nStop"],
                       impacto_carga_n=ev["pk_n"], impacto_carga_e=ev["pk_e"], CL_CLmax_max=ev["ratio_mission"],
                       I_pico=ev["Ipeak"], checkpoints=", ".join(store.names()))
        if notes:
            summary["observação"] = "; ".join(notes)
        return SimResult(log=log, series=series, summary=summary, events=ev, status=st, checks=checks)

    def _aim(self, ctx, ac, mission, ck, k):
        """bisseção no ponto de soltura s (perna k) para a carga cair no alvo (n)"""
        seg = mission.segments()[k]
        alvo = ac.payload.target_n
        others = [e for e in mission.events if e.kind != "drop"]
        hist = []

        def impact(sx):
            m = mission.with_events(others + [MissionEvent("drop", k, sx)])
            with Runner(ctx.backend, ac, m, dict(tmax=ck.t + 300)) as rr:
                rr.start_from(ck)
                o = rr.run(Stop(segment=k + 1), live=False, log=False)
                if o.events["trel"] > 0 and o.events["pk_t"] <= 0:      # carga ainda no ar
                    o = rr.run(Stop(t=rr.session.time + 30.0), live=False, log=False)
            hist.append((sx, o.events["pk_n"]))
            return o.events["pk_n"] - alvo
        a, b = 0.05 * seg["L"], 0.95 * seg["L"]
        fa, fb = impact(a), impact(b)
        if (fa > 0) == (fb > 0):
            s_best = a if abs(fa) < abs(fb) else b
        else:
            n_it = int(ctx.params.get("iters", 8))
            for it in range(n_it):
                ctx.check()
                ctx.on_progress(it / n_it, "LAPES: procurando o ponto de soltura")
                m = 0.5 * (a + b)
                fm = impact(m)
                if (fm > 0) == (fa > 0):
                    a, fa = m, fm
                else:
                    b = m
            s_best = 0.5 * (a + b)
        H = np.array(sorted(hist))
        S = {"ls_impacto da carga": dict(s=H[:, 0], y=H[:, 1], _color=FP.PAYLOAD, _symbol="o", _line=1, _size=9),
             "ls_alvo": dict(_hline=alvo, _color="#000000", _dash="dot"),
             "ls_★ soltura escolhida": dict(s=np.array([s_best]), y=np.array([np.interp(s_best, H[:, 0], H[:, 1])]),
                                           _symbol="star", _color="#ffcc00")}
        return mission.with_events(others + [MissionEvent("drop", k, s_best)]), S

    def _mission_checks(self, ac, info, refs, ev, W, table, status, full, target) -> list[Check]:
        C = []
        Vs, kCL = info["Vs"], ac.autopilot.kCL
        if status == "CRASHED":
            C.append(Check("falha", "a aeronave caiu ou divergiu", f"t = {ev['tend']:.1f} s", "terminar o voo",
                           "a simulação parou abaixo do terreno, capotada ou com estado não finito",
                           "veja a etapa em que o voo terminou nos gráficos (fundo colorido) e o C_L/C_Lmax dela",
                           "Voo"))
        C += self._runway_checks(ac, W, ev, refs)
        for row in table:
            nm = row["etapa"]
            if row["CL_CLmax_max"] > kCL:
                C.append(Check("falha", f"margem de estol — {nm}", f"C_L/C_Lmax = {row['CL_CLmax_max']:.2f}",
                               f"≤ {kCL:.2f}", "a meia asa mais carregada passou do limite de sustentação nessa etapa",
                               "aumente a velocidade da etapa, o raio da curva ou a área de asa", "Etapas"))
            if nm not in ("corrida no chão", "rolagem") and row["Va_min_Vs"] < 1.1:
                C.append(Check("atencao", f"velocidade mínima — {nm}", f"V/V_s = {row['Va_min_Vs']:.2f}", "≥ 1,1",
                               "a velocidade chegou perto da de estol", "peça mais velocidade nessa perna", "Etapas"))
        if ev.get("bounced"):
            C.append(Check("atencao", "tocou o chão de novo depois de decolar", "sim", "não tocar",
                           "o avião voltou ao chão antes do piloto automático assumir", "aumente δe1 ou V_R", "Decolagem"))
        if target is not None and ev.get("pk_t", 0) > 0:
            err = math.hypot(ev["pk_n"] - target[0], ev["pk_e"] - target[1])
            C.append(Check("ok" if err <= 5 else "atencao", "carga LAPES no alvo", f"erro = {err:.1f} m", "≤ 5 m",
                           "distância entre o impacto da carga e o alvo configurado",
                           "ligue 'procurar onde soltar' ou ajuste o evento de soltura", "LAPES"))
        if full and ev.get("tTD", -1) > 0 and ev.get("completed") and ac.airfield.landing_max > 0:
            d = ev["nStop"] - ev["nTD"]
            C.append(Check("ok" if d <= ac.airfield.landing_max else "falha", "distância de pouso (toque até parar)",
                           f"{d:.1f} m", f"≤ {ac.airfield.landing_max:g} m", "rolagem depois do toque",
                           "aproxime mais devagar ou aumente o atrito de frenagem", "Pouso"))
        C.append(Check("info", "energia gasta na missão", f"{ev['E']:.2f} Wh", "—", "", "", "Voo"))
        return C

    def _runway_checks(self, ac, W, ev, refs, landing=True) -> list[Check]:
        C = []
        L = refs["runway_max"]
        x = W["x_warning"]
        C.append(Check("ok" if x == 0 else "falha", "x_warning: saiu do chão dentro da distância exigida",
                       "não saiu do chão" if math.isinf(x) else f"n_LO = {ev['nLO']:.1f} m (x_warning = {x:.1f} m)",
                       f"n_LO ≤ {L:g} m", "distância percorrida até as rodas principais saírem do chão (ou da mesa)",
                       "puxe o profundor antes (s_R/V_R menor) ou com mais δe1, reduza a massa ou aumente a tração",
                       "Pista"))
        if ac.airfield.takeoff_from == "mesa":
            z = W["z_warning_decolagem"]
            C.append(Check("ok" if z == 0 else "falha", "z_warning (decolagem da mesa): não afundou abaixo da mesa",
                           f"afundou {z:.2f} m" if np.isfinite(z) else "não saiu da mesa", "0 m",
                           "depois da borda, o CG desceu abaixo da altura de repouso sobre a mesa",
                           "saia da mesa mais rápido (mesa mais longa), puxe antes ou reduza a massa", "Pista"))
        if landing and ac.airfield.landing_on == "plataforma":
            z = W["z_warning_pouso"]
            C.append(Check("ok" if z == 0 else "falha", "z_warning (pouso na plataforma): tocou em cima dela",
                           f"terreno no toque {ev.get('hgnd_td', 0):.2f} m (z_warning = {z:.2f} m)" if np.isfinite(z)
                           else "não pousou", f"= {ac.airfield.platform_height:g} m",
                           "altura do terreno no ponto do toque comparada com o topo da plataforma",
                           "mude o início/comprimento da plataforma ou a folga do pouso na missão", "Pista"))
        return C

    # ------------------------------------------------------------------ só decolagem
    def _to_over(self, ctx, ac, sR=None, de1=None, h_end=None) -> dict:
        mode = ctx.params.get("elev", "da aeronave")
        to = dict(h_end=h_end or self.param(ctx, "h_end"))
        if mode == "da aeronave":
            if sR is not None:
                to.update(sR=sR, de1=math.radians(de1))
        else:
            by_dist = mode.startswith("dist")
            to.update(sR=(sR if sR is not None else self.param(ctx, "sR")) if by_dist else 0.0,
                      VR=self.param(ctx, "VR"),
                      de1=math.radians(de1 if de1 is not None else self.param(ctx, "de1")))
        return dict(takeoff=to, tmax=60.0, **self._env_over(ctx, ac))

    def _takeoff(self, ctx, ac, info, refs) -> SimResult:
        if self.param(ctx, "runway") > 0:
            ac.airfield.runway_max = refs["runway_max"] = self.param(ctx, "runway")
        runway = takeoff_runway(h=max(15.0, self.param(ctx, "h_end") + 5), V=ac.mission.V0)
        own = ctx.params.get("elev", "da aeronave") == "da aeronave"
        over = self._to_over(ctx, ac, None if own else self.param(ctx, "sR"), None if own else self.param(ctx, "de1"))
        over["dtlog"] = self.param(ctx, "dtlog")
        with Runner(ctx.backend, ac, runway, over, ctx) as r:
            r.start_ground()
            out = r.run(Stop(takeoff=True), chunk=0.25)
        ev, log = out.events, out.log
        lim = dict(dmin=0.03, kCL=ac.autopilot.kCL, qmax=50.0, gmax=20.0)
        viol = takeoff_violations(ev, info["Vs"], lim)
        W = warnings(ev, ac.airfield, landing=False)
        series = {}
        legs = runway.names()
        if len(log):
            series.update(FP.takeoff_window(log, ev, refs, ac.airfield))
            series.update({k: v for k, v in FP.trajectory(log, ev, legs).items() if k.startswith(("t3_", "xz_"))})
            series.update(FP.terrain_profile(log, "xz_"))
        summary = dict(status=out.status.name, n_rot=ev["nRot"], n_LO=ev["nLO"], x_warning=W["x_warning"],
                       z_warning=W["z_warning"], t_LO=ev["tLO"], V_LO=ev["VLO"], n_ht=ev["nHt"], V_ht=ev["VHt"],
                       gamma_ht=math.degrees(ev["gHt"]), cauda_min=ev["hcmin"] if ev["hcmin"] < 1e8 else float("nan"),
                       CL_CLmax_max=ev["ratio_to"], q_pico=math.degrees(ev["qpeak_to"]), I_pico=ev["Ipeak"],
                       restricoes=violation_text(viol), Vs=info["Vs"])
        checks = self._runway_checks(ac, W, ev, refs, landing=False) + self._violation_checks(ev, viol, info, lim)
        if self.param(ctx, "sweep"):
            cases = [(a, b) for a in floats(self.param(ctx, "sR_list")) for b in floats(self.param(ctx, "de1_list"))]

            def one(c):
                with Runner(ctx.backend, ac, runway, dict(self._to_over(ctx, ac, *c), dtlog=1.0)) as rr:
                    rr.start_ground()
                    o = rr.run(Stop(takeoff=True), live=False, log=False)
                e = o.events
                w = warnings(e, ac.airfield, landing=False)
                v = takeoff_violations(e, info["Vs"], lim)
                return [c[0], c[1], e["nLO"] if e["tLO"] > 0 else np.nan, v, w["x_warning"], w["z_warning"]]
            M = np.array(self.parallel(ctx, one, cases, "decolagens"), dtype=float)
            ok = (M[:, 3] == 0) & np.isfinite(M[:, 2]) & (M[:, 4] == 0) & (M[:, 5] == 0)
            series["mapa_passa (cor: n_LO)"] = dict(sR=M[ok, 0], de1=M[ok, 1], _symbol="s", _color="#2ca02c", _size=12)
            styles = [(V_TAIL, "x", "#d62728", "cauda a menos de 3 cm do chão"), (V_STALL, "o", "#000000", "C_L acima do limite"),
                      (V_Q, "t", "#ff7f0e", "|q| > 50 °/s"), (V_VSAFE, "v", "#9467bd", "V < 1,2 V_s ou γ > 20° em h_t"),
                      (V_EARLY, "s", "#bcbd22", "saiu do chão antes do comando"), (V_NOCLIMB, "d", "#7f7f7f", "não chega a h_end"),
                      (V_BOUNCE, "+", "#8c564b", "toca o chão de novo")]
            for b, sym, c, lab in styles:
                s = (M[:, 3].astype(int) & b) > 0
                if s.any():
                    series[f"mapa_{lab}"] = dict(sR=M[s, 0], de1=M[s, 1], _symbol=sym, _color=c, _size=9)
            s = (M[:, 4] > 0) & (M[:, 3] == 0)
            if s.any():
                series["mapa_x_warning > 0 (passou da pista)"] = dict(sR=M[s, 0], de1=M[s, 1], _symbol="x", _color="#e377c2", _size=11)
            series["mapa_casos"] = dict(sR=M[:, 0], de1=M[:, 1], n_LO=M[:, 2], violacoes=M[:, 3], x_warning=M[:, 4],
                                        z_warning=M[:, 5], _nolegend=1, _symbol="o", _size=1, _color="#ffffff")
            if ok.any():
                i = int(np.nanargmin(np.where(ok, M[:, 2], np.inf)))
                series["mapa_★ melhor (menor n_LO que passa)"] = dict(sR=np.array([M[i, 0]]), de1=np.array([M[i, 1]]),
                                                                    _symbol="star", _color="#ffcc00", _size=22)
                summary.update(melhor_sR=M[i, 0], melhor_de1=M[i, 1], melhor_nLO=M[i, 2])
                checks.append(Check("info", "melhor comando do mapa", f"s_R = {M[i, 0]:g} m, δe1 = {M[i, 1]:g}°",
                                    "menor n_LO sem violar", f"n_LO = {M[i, 2]:.1f} m", "use na aba Configuração",
                                    "Mapa"))
            else:
                checks.append(Check("falha", "mapa s_R × δe1", "nenhum ponto passa", "algum ponto sem violação",
                                    "todas as combinações violam algum critério ou passam da pista",
                                    "amplie as listas, reduza a massa ou aumente a tração", "Mapa"))
        return SimResult(log=log, series=series, summary=summary, events=ev, status=out.status.name, checks=checks)

    @staticmethod
    def _violation_checks(ev, viol, info, lim) -> list[Check]:
        out = []
        items = [(V_TAIL, "folga da cauda na rotação", f"{100 * ev['hcmin']:.1f} cm" if ev["hcmin"] < 1e8 else "—",
                  f"≥ {100 * lim['dmin']:.0f} cm", "a cauda chegou perto do chão (ou tocou) ao girar",
                  "puxe com menos δe1 ou mais tarde (s_R/V_R maior)"),
                 (V_STALL, "margem de estol na decolagem", f"C_L/C_Lmax = {ev['ratio_to']:.2f}", f"≤ {lim['kCL']:.2f}",
                  "a asa passou do limite ao sair do chão", "puxe mais tarde (mais velocidade) ou com menos δe1"),
                 (V_Q, "taxa de arfagem na rotação", f"{math.degrees(ev['qpeak_to']):.0f} °/s", f"≤ {lim['qmax']:g} °/s",
                  "rotação brusca", "reduza a taxa do profundor ou δe1"),
                 (V_VSAFE, "velocidade e ângulo em h_t", f"V = {ev['VHt']:.1f} m/s, γ = {math.degrees(ev['gHt']):.1f}°",
                  f"V ≥ 1,2 V_s = {1.2 * info['Vs']:.1f}, γ ≤ {lim['gmax']:g}°", "subida íngreme demais ou lenta",
                  "puxe com menos δe1"),
                 (V_EARLY, "saiu do chão antes do comando", "sim" if viol & V_EARLY else "não", "depois do comando",
                  "a aeronave decolou sozinha antes de puxar", "aumente a incidência da asa ou puxe antes"),
                 (V_NOCLIMB, "chegou à altura final", "sim" if ev.get("completed") else "não", "chegar",
                  "não completou a decolagem", "veja x_warning, estol e tração")]
        for bit, item, val, crit, why, fix in items:
            out.append(Check("falha" if viol & bit else "ok", item, val, crit, why if viol & bit else "", fix if viol & bit
                             else "", "Decolagem", "Riboldi et al. (2022)"))
        return out

    # ------------------------------------------------------------------ curvas
    def _turns(self, ctx, ac, info, refs) -> SimResult:
        side = 1 if self.param(ctx, "side") == "direita" else -1
        h, ang = self.param(ctx, "h"), self.param(ctx, "angle")
        phimax, hloss = self.param(ctx, "phimax"), self.param(ctx, "hloss")
        over = dict(tmax=1e6, ap=dict(phimax=math.radians(phimax)), **self._env_over(ctx, ac))
        if self.param(ctx, "alpha_lim") > 0:
            over["ap"]["alpha_max"] = math.radians(self.param(ctx, "alpha_lim"))
        Vs_list = floats(self.param(ctx, "V_list"))
        R_base = floats(self.param(ctx, "R_list"))
        series, checks, rmin_rows, all_cases = {}, [], [], []
        styles = [("#2ca02c", "o"), ("#d62728", "s"), ("#9467bd", "t"), ("#1f77b4", "d"), ("#ff7f0e", "o")]
        for iv, V in enumerate(Vs_list):
            ctx.check()
            Rs = sorted({round(R * (V / 15.0) ** 2, 1) for R in R_base})
            m0 = level_turn(V, Rs[-1], ang, h, side=side)
            with Runner(ctx.backend, ac, m0, over, ctx) as r:
                r.start_air(0)
                r.run(Stop(segment=1), live=False, log=False)
                ck = r.checkpoint(f"curva V = {V:g} m/s")

            def one(R, V=V, ck=ck):
                m = level_turn(V, R, ang, h, side=side)
                with Runner(ctx.backend, ac, m, over) as rr:
                    rr.start_from(ck)
                    o = rr.run(Stop(segment=2, t=ck.t + 30 + 3 * R * math.radians(ang) / V), live=False)
                res = evaluate_turn(o.log, m.segments()[1], 1, R, info["Vs"], ac.autopilot.kCL, phimax)
                if res.get("perda_h", 0) > hloss and res["ok"]:
                    res["ok"], res["motivo"] = False, "perde altura"
                return res, o.log
            outs = self.parallel(ctx, one, Rs, f"V = {V:g} m/s: raios")
            c, sym = styles[iv % len(styles)]
            L = [o for o, _ in outs]
            Rm = min_radius(L)
            for o, log in outs:
                o["V"] = V
                all_cases.append(o)
                ctx.on_chunk(log)
                if iv == len(Vs_list) // 2 and len(log):           # trajetórias da V do meio
                    cmap = FP.STAGE_COLORS[1 + (len(series) % 9)]
                    series[f"cv_V = {V:g} m/s, R = {o['R']:g} m — {o['motivo']}"] = dict(
                        e=np.asarray(log["e"], float), n=np.asarray(log["n"], float), _color=cmap,
                        _width=1.8 if o["ok"] else 1.0, _dash=None if o["ok"] else "dash")
            Rarr = np.array([o["R"] for o in L])
            okm = np.array([o["ok"] for o in L])
            for pre, k in (("cr_", "razao_max"), ("cp_", "phi_perm"), ("ch_", "perda_h"), ("cnz_", "nz_perm")):
                y = np.array([o.get(k, np.nan) for o in L], float)
                if k == "phi_perm":
                    y = np.minimum(y, 89.0)
                series[f"{pre}V = {V:g} m/s — passa"] = dict(R=Rarr[okm], y=y[okm], _symbol=sym, _color=c, _size=10)
                series[f"{pre}V = {V:g} m/s — falha"] = dict(R=Rarr[~okm], y=y[~okm], _symbol="x", _color=c, _size=12)
                series[f"{pre}V = {V:g} m/s"] = dict(R=Rarr, y=y, _color=c, _width=0.8, _nolegend=1)
                if np.isfinite(Rm):
                    series[f"{pre}R_mín a {V:g} m/s"] = dict(_vline=Rm, _color=c, _dash="dot", _nolegend=1)
            rmin_rows.append(dict(V=V, R=Rm))
            fails = sorted([o for o in L if not o["ok"] and (not np.isfinite(Rm) or o["R"] < Rm)], key=lambda o: -o["R"])
            why = fails[0]["motivo"] if fails else ""
            checks.append(Check("info" if np.isfinite(Rm) else "falha", f"raio mínimo a {V:g} m/s",
                                f"{Rm:.1f} m" if np.isfinite(Rm) else "nenhum raio passa", "menor R que passa",
                                f"o raio menor seguinte falha por: {why}" if why else "",
                                "mais velocidade, mais área de asa ou mais tração deixam a curva mais fechada"
                                if why else "", "Curvas"))
        series["cr_limite C_L/C_Lmax"] = dict(_hline=ac.autopilot.kCL, _color="#d62728", _dash="dash")
        series["ch_limite"] = dict(_hline=hloss, _color="#d62728", _dash="dash")
        V = np.array([r["V"] for r in rmin_rows])
        R = np.array([r["R"] for r in rmin_rows])
        series["rm_R mínimo simulado"] = dict(V=V, R=R, _symbol="o", _line=1, _color="#1f77b4")
        g = 9.80665
        Vf = np.linspace(max(info["Vs"], 1.0) * 1.05, max(V.max(), info["Vs"] * 1.5) * 1.1, 60)
        n = np.minimum(1 / np.cos(np.radians(phimax)), (Vf / info["Vs"]) ** 2 * ac.autopilot.kCL)
        series["rm_equilíbrio: R = V²/(g √(n²−1)) com n de estol e φ máx."] = dict(
            V=Vf, R=Vf ** 2 / (g * np.sqrt(np.maximum(n ** 2 - 1, 1e-9))), _color="#7f7f7f", _dash="dash")
        if np.isfinite(R).any():
            i = int(np.nanargmin(R))
            series["rm_★ menor raio"] = dict(V=V[i:i + 1], R=R[i:i + 1], _symbol="star", _color="#ffcc00")
        cols = {k: np.array([c.get(k, np.nan) for c in all_cases], dtype=object if k == "motivo" else float)
                for k in ("V", "R", "ok", "phi_perm", "nz_perm", "razao_max", "perda_h", "R_real", "motivo")}
        series["casos"] = cols
        summary = {f"R_min @ {r['V']:g} m/s": r["R"] for r in rmin_rows}
        summary["Vs"] = info["Vs"]
        return SimResult(series=series, summary=summary, checks=checks)

    # ------------------------------------------------------------------ MTOW
    @staticmethod
    def _why_above(rows, mtow) -> str:
        above = [r for r in rows if r["m"] > mtow + 1e-9 and not r["ok"]]
        if not above:
            return "aumente a faixa de massa para ver o que limita"
        r = min(above, key=lambda r: r["m"])
        parts = []
        if r["x"] > 0:
            parts.append("saiu do chão depois da pista (x_warning = " +
                         ("não decolou" if not np.isfinite(r["x"]) else f"{r['x']:.1f} m") + ")")
        if r["z"] > 0:
            parts.append(f"z_warning = {r['z']:.2f} m")
        if r.get("zl", 0) > 0:
            parts.append(f"z_warning do pouso = {r['zl']:.2f} m")
        if r["viol"]:
            parts.append("violou: " + violation_text(int(r["viol"])))
        return (f"com {r['m']:.2f} kg o melhor caso " + "; ".join(parts or ["não passa"]) +
                " — para subir o MTOW: mais pista, mais tração, mais área de asa ou C_Lmax")

    def _mtow(self, ctx, ac, info, refs) -> SimResult:
        if self.param(ctx, "runway") > 0:
            ac.airfield.runway_max = refs["runway_max"] = self.param(ctx, "runway")
        env = self._env_over(ctx, ac)
        model = build_model(ac)
        m0, cg0 = float(model.mass["m"]), np.asarray(model.mass["cg"], float)
        m_tot0 = info["mass"]
        h_end = self.param(ctx, "h_end")
        runway = takeoff_runway(h=max(15.0, h_end + 5), V=ac.mission.V0)
        by_dist = self.param(ctx, "by").startswith("dist")
        acts, de1s = floats(self.param(ctx, "act_list")), floats(self.param(ctx, "de1_list"))
        dxs = floats(self.param(ctx, "dx_list"))
        strict = self.param(ctx, "criteria").startswith("estol")
        check_land = bool(ctx.params.get("landing", True)) and ac.airfield.landing_on == "plataforma"
        lim = dict(dmin=0.03, kCL=ac.autopilot.kCL, qmax=50.0, gmax=20.0)
        combos = [(a, d, x) for a in acts for d in de1s for x in dxs]
        rows = []

        def over(dm, a, d, dx):
            to = dict(sR=a if by_dist else 0.0, VR=a if not by_dist else ac.takeoff.VR, de1=math.radians(d), h_end=h_end)
            return dict(takeoff=to, tmax=60.0, m_dry=m0 + dm, r_dry=[float(cg0[0] + dx / 100.0), float(cg0[1]),
                                                                       float(cg0[2])], dtlog=1.0, **env)

        def one(args):
            dm, (a, d, dx) = args
            with Runner(ctx.backend, ac, runway, over(dm, a, d, dx)) as rr:
                rr.start_ground()
                o = rr.run(Stop(takeoff=True), live=False, log=False)
            e = o.events
            w = warnings(e, ac.airfield, landing=False)
            v = takeoff_violations(e, info["Vs"], lim)
            passed = w["x_warning"] == 0 and w["z_warning"] == 0 and e.get("completed") and (v == 0 or not strict)
            return dict(dm=dm, a=a, de1=d, dx=dx, nLO=e["nLO"] if e["tLO"] > 0 else np.nan, x=w["x_warning"],
                        z=w["z_warning"], viol=v, ok=bool(passed))

        def landing_ok(dm, c) -> tuple[bool, float]:
            o2 = over(dm, c["a"], c["de1"], c["dx"])
            o2.pop("tmax")
            with Runner(ctx.backend, ac, ac.mission, o2) as rr:
                rr.start_ground()
                o = rr.run(Stop(), live=False, log=False)
            w = warnings(o.events, ac.airfield, landing=True)
            return w["z_warning_pouso"] == 0, w["z_warning_pouso"]

        def evaluate(dm):
            ctx.check()
            res = self.parallel(ctx, one, [(dm, c) for c in combos], f"Δm = {dm:+.2f} kg")
            good = sorted([r for r in res if r["ok"]], key=lambda r: r["nLO"])
            zl = 0.0
            if good and check_land:
                for c in good[:3]:
                    okl, zl = landing_ok(dm, c)
                    if okl:
                        good = [c] + [g for g in good if g is not c]
                        break
                else:
                    good = []
            best = good[0] if good else min(res, key=lambda r: (r["x"] + r["z"], r["nLO"] if np.isfinite(r["nLO"])
                                                                else 1e9))
            rows.append(dict(m=m_tot0 + dm, dm=dm, ok=bool(good), nLO=best["nLO"], x=best["x"], z=best["z"], zl=zl,
                             a=best["a"], de1=best["de1"], dx=best["dx"], viol=best["viol"]))
            return bool(good), best

        lo, hi = self.param(ctx, "dm_lo"), self.param(ctx, "dm_hi")
        ok_hi, best_hi = evaluate(hi)
        ok_lo, best_lo = evaluate(lo) if not ok_hi else (True, best_hi)
        checks = []
        if ok_hi:
            mt, best = hi, best_hi
            checks.append(Check("atencao", "MTOW acima da faixa pesquisada", f"> {m_tot0 + hi:.2f} kg",
                                "dentro da faixa", "a maior massa testada ainda passa",
                                "aumente a massa extra máxima", "MTOW"))
        elif not ok_lo:
            mt, best = float("nan"), best_lo
            checks.append(Check("falha", "nenhuma massa da faixa decola", f"≤ {m_tot0 + lo:.2f} kg não passa",
                                "x_warning = 0 e z_warning = 0", "nem a menor massa decola dentro da pista com algum "
                                "comando/xCG testado", "aumente a pista, a tração, ou amplie s_R/V_R, δe1 e xCG", "MTOW"))
        else:
            tol = self.param(ctx, "tol")
            best = best_lo
            it = 0
            while hi - lo > tol and it < 40:
                it += 1
                mid = 0.5 * (lo + hi)
                ctx.on_progress(min(it / 12, 0.99), f"bisseção: Δm entre {lo:+.2f} e {hi:+.2f} kg")
                ok, b = evaluate(mid)
                if ok:
                    lo, best = mid, b
                else:
                    hi = mid
            mt = lo
        rows.sort(key=lambda r: r["m"])
        M = {k: np.array([r[k] for r in rows], float) for k in rows[0]}
        ok = M["ok"] > 0
        S = {}
        S["mt_passa (x = z = 0)"] = dict(m=M["m"][ok], y=M["nLO"][ok], _symbol="o", _color="#2ca02c", _size=10)
        S["mt_não passa"] = dict(m=M["m"][~ok], y=M["nLO"][~ok], _symbol="x", _color="#d62728", _size=12)
        S["mt_distância máxima de decolagem"] = dict(_hline=refs["runway_max"], _color="#d62728", _width=3)
        S["mz_x_warning"] = dict(m=M["m"], y=np.where(np.isfinite(M["x"]), M["x"], np.nan), _symbol="o", _line=1,
                                 _color="#1f77b4")
        S["mz_z_warning"] = dict(m=M["m"], y=np.where(np.isfinite(M["z"]), M["z"], np.nan), _symbol="s", _line=1,
                                 _color="#5b3a1a")
        if check_land:
            S["mz_z_warning do pouso"] = dict(m=M["m"], y=M["zl"], _symbol="t", _line=1, _color="#9467bd")
        S["mc_" + ("s_R (m)" if by_dist else "V_R (m/s)")] = dict(m=M["m"][ok], y=M["a"][ok], _symbol="o", _line=1,
                                                                 _color="#2ca02c")
        S["mc_δe1 (°)"] = dict(m=M["m"][ok], y=M["de1"][ok], _symbol="s", _line=1, _color="#1f77b4")
        S["mc_ΔxCG (cm)"] = dict(m=M["m"][ok], y=M["dx"][ok], _symbol="d", _line=1, _color="#9467bd")
        S["mtow_casos"] = {k: v for k, v in M.items()}
        summary = dict(massa_atual=m_tot0, MTOW=m_tot0 + mt if np.isfinite(mt) else float("nan"),
                       carga_extra_max=mt, pista=refs["runway_max"])
        log = None
        if np.isfinite(mt):
            for pre in ("mt_", "mz_", "mc_"):
                S[f"{pre}MTOW = {m_tot0 + mt:.2f} kg"] = dict(_vline=m_tot0 + mt, _color="#ffcc00", _width=3)
            S["mt_★ MTOW"] = dict(m=np.array([m_tot0 + mt]), y=np.array([best["nLO"]]), _symbol="star",
                                  _color="#ffcc00", _size=24)
            summary.update(melhor_acionamento=best["a"], melhor_de1=best["de1"], melhor_dxCG_cm=best["dx"],
                           n_LO_no_MTOW=best["nLO"])
            checks.append(Check("info", "MTOW", f"{m_tot0 + mt:.2f} kg (+{mt:.2f} kg)", "x_warning = 0 e z_warning = 0",
                                f"com {'s_R' if by_dist else 'V_R'} = {best['a']:g}, δe1 = {best['de1']:g}°, "
                                f"ΔxCG = {best['dx']:+g} cm: n_LO = {best['nLO']:.1f} m",
                                self._why_above(rows, m_tot0 + mt), "MTOW"))
            o2 = over(mt, best["a"], best["de1"], best["dx"])
            o2["dtlog"] = 0.005
            with Runner(ctx.backend, ac, runway, o2, ctx) as rr:
                rr.start_ground()
                out = rr.run(Stop(takeoff=True), chunk=0.25)
            log = out.log
            if len(log):
                S.update(FP.takeoff_window(log, out.events, refs, ac.airfield))
                S.update({k: v for k, v in FP.trajectory(log, out.events, runway.names()).items()
                          if k.startswith(("t3_", "xz_"))})
                W = warnings(out.events, ac.airfield, landing=False)
                checks += self._runway_checks(ac, W, out.events, refs, landing=False)
        return SimResult(log=log, series=S, summary=summary, checks=checks)

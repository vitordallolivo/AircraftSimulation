"""Missão (simulação 6GDL) por etapa do voo (corrida no chão, cada perna do percurso, rolagem).

Modos:
  missão                decolagem (otimizada para o x_warning e o z_warning, ou a da Configuração) e
                        depois o resto, etapa por etapa. Cada etapa salva um checkpoint no início dela:
                        dá para parar no fim de qualquer etapa, mudar o percurso dali para frente na
                        Configuração e continuar do início daquela etapa
  só decolagem          otimiza o ponto de acionamento do profundor (ou elevon) e mostra a decolagem
  curvas: raio mínimo   para cada V, o menor raio em curva nivelada (complementa a aba Desempenho)
  MTOW                  bisseção na massa: a maior que decola com x_warning e z_warning, otimizando o
                        acionamento do profundor (e o xCG, se pedido) em cada massa

Critérios da decolagem: só os da pista (manager/takeoff_opt.py).
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.backend import LogChunk
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.mission import MissionEvent, level_turn, takeoff_runway
from aerosim.model.universal import build_model

from .. import flightplots as FP
from .. import takeoff_opt as TO
from ..analysis import columns, evaluate_turn, min_radius, stage_table
from ..runner import Runner, Stop
from .base import SimulationBase, floats

MODES = ("missão", "só decolagem", "curvas: raio mínimo", "MTOW (x_warning e z_warning)")
M_MIS, M_TO, M_TURN, M_MTOW = MODES
END = "fim da missão (parada na pista)"
TO_MODES = ("otimizar o acionamento (x_warning e z_warning)", "como está na Configuração")
GP = "Pista (padrão: Configuração → Pista)"
CHUNK = 0.5


def _refs(ac, info, xw, zw) -> dict:
    r = dict(Vs=info["Vs"], alpha_stall=info["alpha_stall"], kCL=ac.autopilot.kCL, ht=ac.takeoff.ht,
             x_warning=xw, z_warning=zw, landing_max=ac.airfield.landing_max)
    legs = ac.gear.legs()
    mains = [g for g in legs if g.kind == "main"]
    skids = [g for g in legs if g.kind == "skid"]
    if mains and skids and mains[0].x > skids[0].x:
        r["theta_tail"] = math.degrees(math.atan2(mains[0].z - skids[0].z, mains[0].x - skids[0].x))
    return r


class MissionSimulation(SimulationBase):
    name = "mission"
    title = "Missão"
    description = ("Voo simulado (6GDL) por etapa. A decolagem é otimizada para a pista (x_warning: comprimento, "
                   "z_warning: altura que conta como decolado) e o resto do voo continua dali, etapa por etapa.")

    # ------------------------------------------------------------------ formulário
    def parameters(self):
        return self.parameters_for(None, {})

    def parameters_for(self, ac, values=None):
        values = values or {}
        mode = values.get("mode", M_MIS)
        P = [ParamSpec("mode", "Análise", M_MIS, kind="choice", choices=MODES, rebuild=True)]
        legs = ac.mission.names() if ac is not None else []
        af = ac.airfield if ac is not None else None
        pista = [ParamSpec("x_warning", "x_warning (pista)", af.x_warning if af else 60.0, minimum=1,
                           maximum=2000, unit="m", group=GP,
                           help="comprimento de pista: tem de 'decolar' (passar do z_warning) antes desta distância"),
                 ParamSpec("z_warning", "z_warning (altura)", af.z_warning if af else 1.0,
                           minimum=-20, maximum=50, unit="m", group=GP,
                           help="altura sobre a superfície de partida que conta como decolado; ≤ 0 na mesa: quanto pode "
                                "afundar abaixo dela")]
        if mode == M_MIS:
            P += [ParamSpec("takeoff", "Decolagem", TO_MODES[0], kind="choice", choices=TO_MODES, group="Decolagem")]
            P += pista
            P += [ParamSpec("start", "Começar de", "chão", kind="choice",
                            choices=("chão",) + tuple(f"início: {n}" for n in legs[1:]), group="Etapas",
                            help="do checkpoint salvo no início da etapa; se ainda não houver, voa até lá e salva"),
                  ParamSpec("until", "Parar em", END, kind="choice", choices=(END,) + tuple(f"fim: {n}" for n in legs[:-1]),
                            group="Etapas")]
            if ac is not None and ac.payload.enabled:
                P.append(ParamSpec("aim", "LAPES: procurar onde soltar para acertar o alvo", ac.payload.aim,
                                   kind="bool", group="Etapas"))
            P += [ParamSpec("slosh", "Sloshing", True, kind="bool", group="Ambiente"),
                  ParamSpec("gust", "Rajada", False, kind="bool", group="Ambiente")]
        elif mode == M_TO:
            P += pista + [ParamSpec("wind", "Com vento", True, kind="bool", group="Ambiente")]
        elif mode == M_TURN:
            P += [ParamSpec("V_list", "Velocidades", "13, 15, 17", kind="floats", unit="m/s", group="Curvas"),
                  ParamSpec("R_list", "Raios a testar (a 15 m/s; escalam com V²)", "12, 16, 20, 25, 30, 40, 50, 70",
                            kind="floats", unit="m", group="Curvas"),
                  ParamSpec("h", "Altura", 30.0, minimum=5, maximum=500, unit="m", group="Curvas"),
                  ParamSpec("hloss", "Perda de altura máxima", 3.0, minimum=0.2, maximum=50, unit="m", group="Curvas"),
                  ParamSpec("wind", "Com vento", True, kind="bool", group="Ambiente")]
        else:
            P += pista + [
                ParamSpec("dm_hi", "Massa extra máxima a testar", 8.0, minimum=0.1, maximum=200, unit="kg", group="MTOW"),
                ParamSpec("dx", "Variar o xCG de decolagem em ± (0 = só o atual)", 2.0, minimum=0, maximum=30, unit="cm",
                          group="MTOW"),
                ParamSpec("wind", "Com vento", True, kind="bool", group="Ambiente")]
        return P

    # ------------------------------------------------------------------ gráficos
    def plots(self):
        return self.plots_for(None, {})

    def plots_for(self, ac, values=None):
        mode = (values or {}).get("mode", M_MIS)
        traj = [PlotSpec("t3", "Trajetória 3D (cores: etapas do voo; ● eventos)", "e", ("n",), "e (m) — leste",
                         "n (m) — eixo da pista", source="series:t3_*", kind="3d", z="h", height=720),
                PlotSpec("xz", "Plano XZ — perfil: posição na pista × altura", "n", ("h",), "n (m) — eixo da pista",
                         "h (m)", source="series:xz_*", live_ys=("h",)),
                PlotSpec("xy", "Plano XY — vista de cima", "n", ("e",), "n (m) — eixo da pista", "e (m) — leste",
                         source="series:xy_*", live_ys=("e",), aspect=True, invert_y=True),
                PlotSpec("zy", "Plano ZY — vista de frente", "e", ("h",), "e (m) — leste", "h (m)", source="series:zy_*",
                         live_ys=("h",))]
        takeoff = [
            PlotSpec("dh", "Decolagem: altura sobre a pista × posição (z_warning e x_warning em vermelho)", "n", ("y",),
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
        opt = PlotSpec("op", "Otimização: onde decolou (n_dec) × ponto de acionamento do profundor (★ escolhido)", "s",
                       ("y",), "ponto de acionamento do profundor na pista (m)", "n_dec (m)", live=False,
                       source="series:op_*")
        if mode == M_TO:
            return [opt] + takeoff + traj[:2]
        if mode == M_TURN:
            return [PlotSpec("cv", "Curvas: trajetórias (vista de cima; tracejado = falha)", "e", ("n",), "e (m)", "n (m)",
                             source="series:cv_*", live_ys=("n",), aspect=True),
                    PlotSpec("cr", "C_L/C_Lmax máximo da meia asa × raio pedido (x = falha)", "R", ("y",), "R (m)", "—",
                             live=False, source="series:cr_*"),
                    PlotSpec("cp", "Inclinação em regime × raio pedido", "R", ("y",), "R (m)", "|φ| (°)", live=False,
                             source="series:cp_*"),
                    PlotSpec("ch", "Altura perdida na curva × raio pedido", "R", ("y",), "R (m)", "m", live=False,
                             source="series:ch_*"),
                    PlotSpec("rmin", "Raio mínimo por velocidade (★)", "V", ("R",), "V (m/s)", "R mínimo (m)", live=False,
                             source="series:rm_*")]
        if mode == M_MTOW:
            return [PlotSpec("mt", "MTOW: onde decolou (n_dec) × massa de decolagem (★ MTOW)", "m", ("y",),
                             "massa de decolagem (kg)", "n_dec (m)", live=False, source="series:mt_*"),
                    PlotSpec("mc", "Melhor acionamento do profundor em cada massa", "m", ("y",), "massa (kg)",
                             "acionamento (m) / deflexão (°) / ΔxCG (cm)", live=False, source="series:mc_*"),
                    opt] + takeoff + traj[:2]
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
        out += [opt] + takeoff
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
        ac, info = self.prepare(ctx)
        p = ctx.params
        if "slosh" in p:
            ac.sim.slosh = bool(p["slosh"])
        if "gust" in p:
            ac.environment.gust = bool(p["gust"])
        if not p.get("wind", True):
            ac.environment.wind_speed = 0.0
        xw = float(p.get("x_warning", ac.airfield.x_warning))
        zw = float(p.get("z_warning", ac.airfield.z_warning))
        refs = _refs(ac, info, xw, zw)
        if mode == M_TO:
            return self._takeoff(ctx, ac, info, refs)
        if mode == M_TURN:
            return self._turns(ctx, ac, info, refs)
        if mode == M_MTOW:
            return self._mtow(ctx, ac, info, refs)
        return self._mission(ctx, ac, info, refs)

    # ------------------------------------------------------------------ decolagem
    def _optimize(self, ctx, ac, refs, overrides=None):
        ctx.on_progress(0.0, "otimizando o acionamento do profundor")
        par = lambda fn, items: self.parallel(ctx, fn, items, "decolagens")
        return TO.optimize(ctx.backend, ac, refs["x_warning"], refs["z_warning"], par, overrides)

    @staticmethod
    def _opt_series(tried, best, refs, prefix="op_") -> dict:
        S = {}
        levels = sorted({r.de for r in tried})
        colors = ["#1f77b4", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf"]
        for i, de in enumerate(sorted(levels)):
            rs = sorted([r for r in tried if r.de == de and np.isfinite(r.s)], key=lambda r: r.s)
            if not rs:
                continue
            s = np.array([r.s for r in rs])
            fin = [r.n_dec for r in tried if np.isfinite(r.n_dec)]
            ceil = 1.15 * max(fin + [refs["x_warning"]])        # "não decolou": desenhado no alto do gráfico
            y = np.array([r.n_dec if np.isfinite(r.n_dec) else ceil for r in rs])
            ok = np.array([r.ok for r in rs])
            c = colors[i % len(colors)]
            S[f"{prefix}δe = {de:g}°" + ("" if ok.any() else " (nenhum ponto passa; no alto: não decolou)")] = dict(
                s=s, y=y, _color=c, _width=1.0)
            S[f"{prefix}δe = {de:g}°: passa"] = dict(s=s[ok], y=y[ok], _symbol="o", _color=c, _size=9, _nolegend=1)
            S[f"{prefix}δe = {de:g}°: não passa"] = dict(s=s[~ok], y=y[~ok], _symbol="x", _color=c, _size=11, _nolegend=1)
        S[f"{prefix}x_warning ({refs['x_warning']:g} m)"] = dict(_hline=refs["x_warning"], _color="#d62728", _width=3)
        if best is not None and np.isfinite(best.s) and np.isfinite(best.n_dec):
            S[f"{prefix}★ escolhido: {best.s:.1f} m, δe = {best.de:g}°"] = dict(
                s=np.array([best.s]), y=np.array([best.n_dec]), _symbol="star", _color="#ffcc00", _size=24)
        return S

    def _takeoff_checks(self, ac, best, refs, ctrl) -> list[Check]:
        G = "Pista"
        xw, zw = refs["x_warning"], refs["z_warning"]
        C = [Check("ok" if best.x_excess == 0 else "falha", "x_warning: decolou dentro da pista",
                   "não decolou" if not np.isfinite(best.n_dec) else f"n_dec = {best.n_dec:.1f} m", f"≤ {xw:g} m",
                   "" if best.x_excess == 0 else f"passou {best.x_excess:.1f} m do comprimento de pista",
                   "" if best.x_excess == 0 else "menos massa, mais tração, mais C_Lmax ou mais área de asa", G),
             Check("ok" if best.z_short == 0 else "falha", "z_warning: altura que conta como decolado",
                   f"menor altura depois de sair do chão: {best.h_min:+.2f} m", f"z_warning = {zw:g} m",
                   "" if best.z_short == 0 else f"faltaram {best.z_short:.2f} m", "" if best.z_short == 0 else
                   "aciona o profundor antes ou com mais deflexão; mesa mais longa", G)]
        if ctrl:
            C.append(Check("info", f"acionamento do {ctrl}", f"em {best.s:.1f} m, deflexão {best.de:g}°",
                           f"máx. {ac.autopilot.de_max:g}°",
                           "a maior deflexão que funciona; ponto com a maior folga até o x_warning" if best.ok else
                           "nenhum ponto passou: este é o menos ruim",
                           "copie para Configuração → Decolagem (sR, de1)" if best.ok else "", G))
        else:
            C.append(Check("info", "sem comando de arfagem", "decola sozinha", "—",
                           "a aeronave não tem profundor/elevon: não há acionamento a otimizar", "", G))
        return C

    def _takeoff(self, ctx, ac, info, refs) -> SimResult:
        best, tried = self._optimize(ctx, ac, refs)
        ctrl = TO.pitch_control(ac)
        ctx.on_progress(0.9, "decolagem escolhida")
        res, log = TO.evaluate(ctx.backend, ac, best.s if ctrl else None, best.de, refs["x_warning"],
                               refs["z_warning"], dtlog=0.005, log=True)
        ctx.on_chunk(log)
        ev = res.events
        S = self._opt_series(tried, best, refs)
        if len(log):
            S.update(FP.takeoff_window(log, ev, refs, ac.airfield))
            S.update({k: v for k, v in FP.trajectory(log, ev, ["decolagem", "cruzeiro"]).items()
                      if k.startswith(("t3_", "xz_"))})
            S.update(FP.terrain_profile(log, "xz_"))
        summary = dict(status=res.status, x_warning=refs["x_warning"], z_warning=refs["z_warning"],
                       n_dec=res.n_dec, folga_de_pista=refs["x_warning"] - res.n_dec,
                       acionamento_m=best.s, deflexao_graus=best.de, V_ao_sair_do_chao=ev["VLO"],
                       n_saiu_do_chao=ev["nLO"], massa=info["mass"])
        return SimResult(log=log, series=S, summary=summary, events=ev, status=res.status,
                         checks=self._takeoff_checks(ac, best, refs, ctrl))

    # ------------------------------------------------------------------ missão
    def _mission(self, ctx, ac, info, refs) -> SimResult:
        mission = ac.mission
        legs = mission.names()
        nseg = len(legs)
        drop = next((e for e in mission.events if e.kind == "drop"), None)
        k_drop = drop.leg if drop is not None and ac.payload.enabled else None
        start, until = self.param(ctx, "start"), self.param(ctx, "until")
        k0 = legs.index(start[len("início: "):]) if start != "chão" and start[len("início: "):] in legs else 0
        stop_at = nseg if until == END or until[len("fim: "):] not in legs else legs.index(until[len("fim: "):]) + 1
        if stop_at <= k0:
            stop_at = nseg
        store = ctx.checkpoints
        key = lambda k: f"missão: início de {legs[k]}"
        series, notes, checks = {}, [], []
        aim = bool(ctx.params.get("aim", ac.payload.aim)) and k_drop is not None
        best = None
        need_takeoff = k0 == 0 or not store.has(key(k0))
        if need_takeoff and self.param(ctx, "takeoff") == TO_MODES[0]:
            best, tried = self._optimize(ctx, ac, refs)
            series.update(self._opt_series(tried, best, refs))
            if TO.pitch_control(ac) and np.isfinite(best.s):
                ac.takeoff.sR, ac.takeoff.de1 = best.s, best.de
            checks += self._takeoff_checks(ac, best, refs, TO.pitch_control(ac))
        parts: list[LogChunk] = []
        out = None
        with Runner(ctx.backend, ac, mission, None, ctx) as r:
            if k0 > 0 and store.has(key(k0)):
                r.start_from(store.get(key(k0)))
            else:
                r.start_ground()
                if k0 > 0:                      # sem checkpoint: voa até lá (sem desenhar) e salva os do caminho
                    notes.append(f"não havia checkpoint no início de '{legs[k0]}': voou do chão até lá e salvou")
                    for k in range(k0):
                        ctx.on_progress(k / max(nseg, 1), f"chegando em '{legs[k0]}': {legs[k]}")
                        o = r.run(Stop(segment=k + 1), live=False, log=False)
                        if o.status.name != "STOPPED":
                            raise RuntimeError(f"o voo terminou ({o.status.name}) em '{legs[k]}', antes de "
                                               f"chegar em '{legs[k0]}'")
                        r.checkpoint(key(k + 1), store)
            k = k0
            while k + 1 <= min(stop_at, nseg - 1):
                ctx.on_progress(k / max(nseg, 1), f"etapa: {legs[k]}")
                if aim and k == k_drop and store.has(key(k)):
                    mission, hist = self._aim(ctx, ac, mission, store.get(key(k)), k)
                    series.update(hist)
                    r.reconfigure(mission)
                    r.start_from(store.get(key(k)))
                    aim = False
                out = r.run(Stop(segment=k + 1), chunk=CHUNK)
                parts.append(out.log)
                if out.status.name != "STOPPED":
                    break
                r.checkpoint(key(k + 1), store)
                k += 1
            if stop_at == nseg and (out is None or out.status.name == "STOPPED"):
                if aim and k == k_drop and store.has(key(k)):
                    mission, hist = self._aim(ctx, ac, mission, store.get(key(k)), k)
                    series.update(hist)
                    r.reconfigure(mission)
                    r.start_from(store.get(key(k)))
                ctx.on_progress(0.95, f"etapa: {legs[-1]}")
                out = r.run(Stop(), chunk=CHUNK)
                parts.append(out.log)
            ev = r.session.events()
        log = LogChunk.concat([q for q in parts if len(q)])
        target = (ac.payload.target_n, ac.payload.target_e) if k_drop is not None else None
        pl = ac.airfield.pads(mission)
        pads = [dict(q, landing=i == len(pl) - 1 and ac.airfield.landing_on == "plataforma") for i, q in enumerate(pl)]
        table = []
        if len(log):
            series.update(FP.trajectory(log, ev, legs, target))
            series.update(FP.time_series(log, ev, legs, refs))
            if k0 == 0:
                series.update(FP.takeoff_window(log, ev, refs, ac.airfield))
                if best is None:                  # decolagem da Configuração: julga pelo registro
                    n_dec, h_min, xe, zs, ok = TO.judge(log, ev, refs["x_warning"], refs["z_warning"])
                    r_ = TO.TakeoffResult(ac.takeoff.sR, ac.takeoff.de1, n_dec, h_min, xe, zs, ok, "")
                    checks += self._takeoff_checks(ac, r_, refs, TO.pitch_control(ac))
            series.update(FP.landing_window(log, ev, refs, ac.airfield, pads))
            series.update(FP.lapes_window(log, ev, target[0] if target else None))
            table = stage_table(log, ev, legs, info["Vs"])
            if table:
                series["etapas"] = columns(table)
        st = out.status.name if out else "—"
        checks += self._mission_checks(ac, info, ev, table, st, stop_at == nseg, target)
        summary = dict(status=st, começou_de=start, parou_em=until, t_fim=ev["tend"], energia_Wh=ev["E"],
                       n_saiu_do_chao=ev["nLO"], n_toque=ev["nTD"], n_parada=ev["nStop"],
                       impacto_carga_n=ev["pk_n"], impacto_carga_e=ev["pk_e"], CL_CLmax_max=ev["ratio_mission"],
                       I_pico=ev["Ipeak"], checkpoints=", ".join(store.names()))
        if best is not None:
            summary.update(acionamento_profundor_m=best.s, deflexao_graus=best.de, n_dec=best.n_dec)
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
            for it in range(8):
                ctx.check()
                ctx.on_progress(it / 8, "LAPES: procurando o ponto de soltura")
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

    def _mission_checks(self, ac, info, ev, table, status, full, target) -> list[Check]:
        C = []
        kCL = ac.autopilot.kCL
        if status == "CRASHED":
            C.append(Check("falha", "a aeronave caiu ou divergiu", f"t = {ev['tend']:.1f} s", "terminar o voo",
                           "a simulação parou abaixo do terreno, capotada ou com estado não finito",
                           "veja a etapa em que o voo terminou nos gráficos (fundo colorido) e o C_L/C_Lmax dela",
                           "Voo"))
        for row in table:
            nm = row["etapa"]
            if row["CL_CLmax_max"] > kCL:
                C.append(Check("falha", f"margem de estol — {nm}", f"C_L/C_Lmax = {row['CL_CLmax_max']:.2f}",
                               f"≤ {kCL:.2f}", "a meia asa mais carregada passou do limite de sustentação nessa etapa",
                               "aumente a velocidade da etapa, o raio da curva ou a área de asa", "Etapas"))
            if nm not in ("corrida no chão", "rolagem") and row["Va_min_Vs"] < 1.1:
                C.append(Check("atencao", f"velocidade mínima — {nm}", f"V/V_s = {row['Va_min_Vs']:.2f}", "≥ 1,1",
                               "a velocidade chegou perto da de estol", "peça mais velocidade nessa perna", "Etapas"))
        if full and ac.airfield.landing_on == "plataforma" and ev.get("tTD", -1) > 0:
            dz = ac.airfield.platform_height - ev.get("hgnd_td", 0.0)
            C.append(Check("ok" if dz <= 1e-6 else "falha", "pouso em cima da plataforma",
                           f"terreno no toque: {ev.get('hgnd_td', 0):.2f} m", f"= {ac.airfield.platform_height:g} m",
                           "" if dz <= 1e-6 else "tocou fora da plataforma",
                           "" if dz <= 1e-6 else "mude o início/comprimento da plataforma ou a folga do pouso", "Pouso"))
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
        C.append(Check("info", "energia gasta", f"{ev['E']:.2f} Wh", "—", "", "", "Voo"))
        return C

    # ------------------------------------------------------------------ curvas
    def _turns(self, ctx, ac, info, refs) -> SimResult:
        side, ang, phimax = 1, 240.0, 75.0
        h, hloss = self.param(ctx, "h"), self.param(ctx, "hloss")
        over = dict(tmax=1e6, ap=dict(phimax=math.radians(phimax)))
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
                if iv == len(Vs_list) // 2 and len(log):
                    series[f"cv_V = {V:g} m/s, R = {o['R']:g} m — {o['motivo']}"] = dict(
                        e=np.asarray(log["e"], float), n=np.asarray(log["n"], float),
                        _color=FP.STAGE_COLORS[1 + (len(series) % 9)], _width=1.8 if o["ok"] else 1.0,
                        _dash=None if o["ok"] else "dash")
            Rarr = np.array([o["R"] for o in L])
            okm = np.array([o["ok"] for o in L])
            for pre, k in (("cr_", "razao_max"), ("cp_", "phi_perm"), ("ch_", "perda_h")):
                y = np.array([o.get(k, np.nan) for o in L], float)
                if k == "phi_perm":
                    y = np.minimum(y, 89.0)
                series[f"{pre}V = {V:g} m/s — passa"] = dict(R=Rarr[okm], y=y[okm], _symbol=sym, _color=c, _size=10)
                series[f"{pre}V = {V:g} m/s — falha"] = dict(R=Rarr[~okm], y=y[~okm], _symbol="x", _color=c, _size=12)
                series[f"{pre}V = {V:g} m/s"] = dict(R=Rarr, y=y, _color=c, _width=0.8, _nolegend=1)
            rmin_rows.append(dict(V=V, R=Rm))
            fails = sorted([o for o in L if not o["ok"] and (not np.isfinite(Rm) or o["R"] < Rm)], key=lambda o: -o["R"])
            why = fails[0]["motivo"] if fails else ""
            checks.append(Check("info" if np.isfinite(Rm) else "falha", f"raio mínimo a {V:g} m/s",
                                f"{Rm:.1f} m" if np.isfinite(Rm) else "nenhum raio passa", "menor R que passa",
                                f"o raio menor seguinte falha por: {why}" if why else "",
                                "mais velocidade, mais área de asa ou mais tração" if why else "", "Curvas"))
        series["cr_limite C_L/C_Lmax"] = dict(_hline=ac.autopilot.kCL, _color="#d62728", _dash="dash")
        series["ch_limite"] = dict(_hline=hloss, _color="#d62728", _dash="dash")
        V = np.array([r["V"] for r in rmin_rows])
        R = np.array([r["R"] for r in rmin_rows])
        series["rm_R mínimo simulado"] = dict(V=V, R=R, _symbol="o", _line=1, _color="#1f77b4")
        if np.isfinite(R).any():
            i = int(np.nanargmin(R))
            series["rm_★ menor raio"] = dict(V=V[i:i + 1], R=R[i:i + 1], _symbol="star", _color="#ffcc00")
        series["casos"] = {k: np.array([c.get(k, np.nan) for c in all_cases], dtype=object if k == "motivo" else float)
                           for k in ("V", "R", "ok", "phi_perm", "nz_perm", "razao_max", "perda_h", "R_real", "motivo")}
        summary = {f"R_min @ {r['V']:g} m/s": r["R"] for r in rmin_rows}
        summary["Vs"] = info["Vs"]
        return SimResult(series=series, summary=summary, checks=checks)

    # ------------------------------------------------------------------ MTOW
    def _mtow(self, ctx, ac, info, refs) -> SimResult:
        model = build_model(ac)
        m0, cg0 = float(model.mass["m"]), np.asarray(model.mass["cg"], float)
        m_tot0 = info["mass"]
        dx = self.param(ctx, "dx")
        dxs = [0.0] if dx <= 0 else [0.0, -dx, dx]
        rows, saved = [], {}
        ctrl = TO.pitch_control(ac)

        def over(dm, x):
            return dict(m_dry=m0 + dm, r_dry=[float(cg0[0] + x / 100.0), float(cg0[1]), float(cg0[2])])

        def evaluate(dm):
            ctx.check()
            best_all = None
            for x in dxs:
                b, tried = self._optimize(ctx, ac, refs, over(dm, x))
                b.dx = x
                if best_all is None or (b.ok, b.x_warning_margin if b.ok else -(b.x_excess + b.z_short)) > \
                        (best_all.ok, best_all.x_warning_margin if best_all.ok else -(best_all.x_excess + best_all.z_short)):
                    best_all, saved[dm] = b, tried
            rows.append(dict(m=m_tot0 + dm, dm=dm, ok=float(best_all.ok), n_dec=best_all.n_dec, s=best_all.s,
                             de=best_all.de, dx=best_all.dx, x=best_all.x_excess, z=best_all.z_short))
            return best_all

        hi = self.param(ctx, "dm_hi")
        lo = 0.0
        ctx.on_progress(0.0, "MTOW: massa atual")
        b_lo = evaluate(lo)
        checks = []
        if not b_lo.ok:                               # nem a atual decola: procura para baixo
            lo2 = -0.5 * m0
            b2 = evaluate(lo2)
            if not b2.ok:
                mt, best = float("nan"), b_lo
            else:
                lo, hi, b_lo = lo2, lo, b2
        b_hi = evaluate(hi) if b_lo.ok else None
        if b_lo.ok and b_hi is not None and b_hi.ok:
            mt, best = hi, b_hi
            checks.append(Check("atencao", "MTOW acima da faixa testada", f"> {m_tot0 + hi:.2f} kg", "dentro",
                                "a maior massa testada ainda decola", "aumente a massa extra máxima", "MTOW"))
        elif b_lo.ok:
            best, it = b_lo, 0
            while hi - lo > 0.1 * max(1.0, m0 / 10) and it < 30:
                it += 1
                mid = 0.5 * (lo + hi)
                ctx.on_progress(min(it / 8, 0.95), f"MTOW: entre {m_tot0 + lo:.2f} e {m_tot0 + hi:.2f} kg")
                b = evaluate(mid)
                if b.ok:
                    lo, best = mid, b
                else:
                    hi = mid
            mt = lo
        else:
            mt, best = float("nan"), b_lo
            checks.append(Check("falha", "nenhuma massa decola", "x_warning ou z_warning não atendidos",
                                f"x ≤ {refs['x_warning']:g} m, z = {refs['z_warning']:g} m",
                                "nem com metade da massa a aeronave decola dentro da pista",
                                "mais tração, mais área de asa ou mais pista", "MTOW"))
        rows.sort(key=lambda r: r["m"])
        M = {k: np.array([r[k] for r in rows], float) for k in rows[0]}
        ok = M["ok"] > 0
        S = {"mt_decola (x e z atendidos)": dict(m=M["m"][ok], y=M["n_dec"][ok], _symbol="o", _color="#2ca02c", _size=10),
             "mt_não decola": dict(m=M["m"][~ok], y=np.where(np.isfinite(M["n_dec"][~ok]), M["n_dec"][~ok], np.nan),
                                   _symbol="x", _color="#d62728", _size=12),
             f"mt_x_warning ({refs['x_warning']:g} m)": dict(_hline=refs["x_warning"], _color="#d62728", _width=3),
             "mc_acionamento (m)": dict(m=M["m"][ok], y=M["s"][ok], _symbol="o", _line=1, _color="#2ca02c"),
             "mc_deflexão (°)": dict(m=M["m"][ok], y=M["de"][ok], _symbol="s", _line=1, _color="#1f77b4"),
             "mtow_casos": M}
        if len(dxs) > 1:
            S["mc_ΔxCG (cm)"] = dict(m=M["m"][ok], y=M["dx"][ok], _symbol="d", _line=1, _color="#9467bd")
        summary = dict(massa_atual=m_tot0, MTOW=m_tot0 + mt if np.isfinite(mt) else float("nan"),
                       carga_extra_max=mt, x_warning=refs["x_warning"], z_warning=refs["z_warning"])
        log = None
        if np.isfinite(mt):
            for pre in ("mt_", "mc_"):
                S[f"{pre}MTOW = {m_tot0 + mt:.2f} kg"] = dict(_vline=m_tot0 + mt, _color="#ffcc00", _width=3)
            S["mt_★ MTOW"] = dict(m=np.array([m_tot0 + mt]), y=np.array([best.n_dec]), _symbol="star",
                                  _color="#ffcc00", _size=24)
            summary.update(acionamento_m=best.s, deflexao_graus=best.de, dxCG_cm=getattr(best, "dx", 0.0),
                           n_dec_no_MTOW=best.n_dec)
            above = [r for r in rows if r["m"] > m_tot0 + mt + 1e-9 and not r["ok"]]
            why = ""
            if above:
                r = min(above, key=lambda r: r["m"])
                why = f"com {r['m']:.2f} kg: " + ("não decolou" if not np.isfinite(r["n_dec"]) else
                                                   f"passou {r['x']:.1f} m do x_warning") + \
                      (f", faltaram {r['z']:.2f} m de altura" if r["z"] > 0 else "")
            checks.append(Check("info", "MTOW", f"{m_tot0 + mt:.2f} kg (+{mt:.2f} kg)", "x e z atendidos",
                                f"acionamento em {best.s:.1f} m, δe = {best.de:g}°"
                                + (f", ΔxCG = {getattr(best, 'dx', 0):+g} cm" if len(dxs) > 1 else "")
                                + (f"; acima disso, {why}" if why else ""),
                                "para subir o MTOW: mais tração, mais área de asa ou mais C_Lmax", "MTOW"))
            S.update(self._opt_series(saved.get(mt, []), best, refs))
            x = getattr(best, "dx", 0.0)
            ac2 = ac
            res, log = TO.evaluate(ctx.backend, ac2, best.s if ctrl else None, best.de, refs["x_warning"],
                                   refs["z_warning"], over(mt, x), dtlog=0.005, log=True)
            if len(log):
                S.update(FP.takeoff_window(log, res.events, refs, ac.airfield))
                S.update({k: v for k, v in FP.trajectory(log, res.events, ["decolagem", "cruzeiro"]).items()
                          if k.startswith(("t3_", "xz_"))})
            checks += self._takeoff_checks(ac, best, refs, ctrl)
        return SimResult(log=log, series=S, summary=summary, checks=checks)

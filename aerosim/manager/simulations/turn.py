"""Curvas niveladas: raio mínimo por velocidade.

Orientação: para cada V, começa em voo equilibrado, voa a reta de estabilização e salva
um checkpoint no início da curva. Para cada raio, troca SÓ a perna da curva e retoma do
checkpoint (a reta não é refeita). Avalia o regime depois do primeiro quarto de volta.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import ParamSpec, PlotSpec, RunContext, SimResult
from aerosim.model.mission import level_turn

from ..analysis import evaluate_turn, min_radius
from ..runner import Runner, Stop
from .base import SimulationBase, floats


class TurnSimulation(SimulationBase):
    name = "turn"
    title = "Curvas"
    description = "Raio mínimo em curva nivelada (estol da asa, limite de α, seguimento e altura)."

    def parameters(self):
        return [ParamSpec("V_list", "Velocidades", "13, 15, 17", kind="floats", unit="m/s"),
                ParamSpec("R_list", "Raios (a 15 m/s; escalam com V²)", "12, 16, 20, 25, 30, 40, 50, 70",
                          kind="floats", unit="m"),
                ParamSpec("angle", "Ângulo da curva", 240.0, minimum=90, maximum=720, unit="°"),
                ParamSpec("side", "Lado", "direita", kind="choice", choices=("direita", "esquerda")),
                ParamSpec("h", "Altura", 30.0, minimum=5, maximum=500, unit="m"),
                ParamSpec("wind", "Com vento", True, kind="bool"),
                ParamSpec("alpha_lim", "α máx. do piloto (0 = da aeronave)", 0.0, minimum=0, maximum=30, unit="°"),
                ParamSpec("phimax", "Inclinação máx. liberada", 75.0, minimum=10, maximum=85, unit="°")]

    def plots(self):
        return [PlotSpec("traj", "Trajetórias (vista de cima)", "e", ("n",), "leste (m)", "norte (m)"),
                PlotSpec("phi", "Inclinação", "t", ("phi", "phic"), "t (s)", "graus"),
                PlotSpec("CL", "C_L/C_Lmax da asa", "t", ("ratioCL",), "t (s)", "—"),
                PlotSpec("nz", "Fator de carga", "t", ("nz",), "t (s)", "g"),
                PlotSpec("Rmin", "Raio mínimo por velocidade", "V", ("R_min",), "V (m/s)", "R (m)", live=False,
                         source="series:rmin", scatter=True),
                PlotSpec("casos", "Inclinação em regime por raio", "R", ("phi_perm",), "R (m)", "graus", live=False,
                         source="series:casos", scatter=True)]

    def run(self, ctx: RunContext) -> SimResult:
        ac, info = self.prepare(ctx)
        side = 1 if self.param(ctx, "side") == "direita" else -1
        h = self.param(ctx, "h")
        ang = self.param(ctx, "angle")
        over = dict(tmax=1e6, ap=dict(phimax=math.radians(self.param(ctx, "phimax"))))
        if self.param(ctx, "alpha_lim") > 0:
            over["ap"]["alpha_max"] = math.radians(self.param(ctx, "alpha_lim"))
        if not self.param(ctx, "wind"):
            over["env"] = dict(Vw10=0.0)
        Vs_list = floats(self.param(ctx, "V_list"))
        R_base = floats(self.param(ctx, "R_list"))
        all_cases, rmin_rows = [], []
        for V in Vs_list:
            ctx.check()
            Rs = sorted({round(R * (V / 15.0) ** 2, 1) for R in R_base})
            m0 = level_turn(V, Rs[-1], ang, h, side=side)
            with Runner(ctx.backend, ac, m0, over, ctx) as r:      # reta até o início da curva -> checkpoint
                r.start_air(0)
                r.run(Stop(segment=1), live=False, log=False)
                ck = r.checkpoint(f"curva_V{V:.1f}")

            def one(R, V=V, ck=ck):
                m = level_turn(V, R, ang, h, side=side)
                with Runner(ctx.backend, ac, m, over) as rr:
                    rr.start_from(ck)
                    o = rr.run(Stop(segment=2, t=ck.t + 30 + 3 * R * math.radians(ang) / V), live=False)
                res = evaluate_turn(o.log, m.segments()[1], 1, R, info["Vs"], ac.autopilot.kCL,
                                    self.param(ctx, "phimax"))
                return res, o.log
            outs = self.parallel(ctx, one, Rs, f"V = {V:g} m/s: raios")
            for res, log in outs:
                res["V"] = V
                all_cases.append(res)
                ctx.on_chunk(log)
            rmin_rows.append(dict(V=V, R_min=min_radius([o for o, _ in outs])))
        cols = {k: np.array([c.get(k, np.nan) for c in all_cases], dtype=object if k == "motivo" else float)
                for k in ("V", "R", "ok", "phi_perm", "nz_perm", "razao_max", "perda_h", "R_real", "motivo")}
        summary = {f"R_min @ {r['V']:g} m/s": r["R_min"] for r in rmin_rows}
        summary["Vs"] = info["Vs"]
        return SimResult(series={"rmin": dict(V=np.array([r["V"] for r in rmin_rows]),
                                              R_min=np.array([r["R_min"] for r in rmin_rows])),
                                 "casos": cols}, summary=summary)

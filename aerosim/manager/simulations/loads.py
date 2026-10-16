"""Cargas: a carga aerodinâmica ao longo de cada superfície num ponto de operação (velocidade, fator de carga, α),
com e sem a influência das hélices, em gráficos ao longo da envergadura e na vista 3D.

Quem calcula é o núcleo: `aerosim.aero.span_loads` monta o caso e chama a linha sustentadora (`core/src/loads/llt.zig`,
Phillips e Snyder 2000) ou as faixas da simulação; a hélice é a do conjunto motopropulsor do avião (rotação de
equilíbrio na trimagem, ou o acelerador). A saída é a entrada padrão `LoadResult` (aerosim/interfaces/loads.py), que
os gráficos e a vista 3D leem.

É análise tardia: precisa do avião montado (superfícies e massa) e de um ponto de voo que trime. Sem trimagem, os
gráficos saem com o α que ela achou e o diagnóstico avisa.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult

from .base import SimulationBase

ROLES = (("wing", "asa"), ("htail", "EH"), ("vtail", "EV"))
FIELDS = (("L", "sustentação por metro", "$L'$ (N/m)"), ("alpha_ef", "α efetivo", "α (°)"),
          ("V_rel", "velocidade local / V", "$V/V_\\infty$"))
HELICE = ("com hélice", "sem hélice", "comparar com e sem")
METODOS = {"linha sustentadora (Phillips e Snyder)": "llt", "faixas (o C_Lα da simulação)": "faixas"}
COLORS = {"com hélice": "#1f4e8c", "sem hélice": "#d95f02"}


class LoadsSimulation(SimulationBase):
    tab = True
    name = "loads"
    title = "Cargas"
    area = "cargas"
    description = ("Carga aerodinâmica ao longo de cada superfície num ponto de voo (V, n, α), com e sem a hélice do "
                   "conjunto motopropulsor do avião: sustentação por metro, α e velocidade locais e a vista 3D.")

    def parameters(self):
        return [ParamSpec("V", "Velocidade", 12.0, minimum=2, maximum=80, unit="m/s"),
                ParamSpec("n", "Fator de carga da trimagem", 1.0, minimum=0.2, maximum=10,
                          help="1: voo nivelado; > 1: curva coordenada com esse n"),
                ParamSpec("alpha_mode", "α", "da trimagem", kind="choice", choices=("da trimagem", "imposto")),
                ParamSpec("alpha", "α imposto", 4.0, minimum=-15, maximum=25, unit="°",
                          help="só vale com α = imposto (profundor 0)"),
                ParamSpec("helice", "Hélice", HELICE[2], kind="choice", choices=HELICE,
                          help="com: a esteira e a tração das hélices entram nas superfícies (modificador de "
                               "esteira do avião); sem: as superfícies não veem a hélice"),
                ParamSpec("method", "Método", next(iter(METODOS)), kind="choice", choices=tuple(METODOS))]

    def plots(self):
        return self.plots_for(None, {})

    def plots_for(self, aircraft, values=None):
        roles = [(r, n) for r, n in ROLES
                 if aircraft is None or any(s.enabled and s.role == r for s in aircraft.surfaces)]
        out = [PlotSpec("v3d", "Vista 3D da carga", "superfícies", ("superfícies",), live=False, source="series:v3d",
                        kind="loads3d", height=760)]
        for r, nm in roles:
            ylab = "y (m)" if r != "vtail" else "altura (m)"
            for f, title, unit in FIELDS:
                out.append(PlotSpec(f"{f}_{r}", f"{nm}: {title}", "s", ("y",), ylab, unit, live=False,
                                    source=f"series:{f}_{r}_*"))
        return out

    def run(self, ctx: RunContext) -> SimResult:
        from aerosim.aero.span_loads import LoadCase, compute, to_result
        ac = ctx.aircraft.copy()
        P = lambda k: self.param(ctx, k)
        alpha = P("alpha") if P("alpha_mode") == "imposto" else None
        method = METODOS[P("method")]
        cases = {"com hélice": [True], "sem hélice": [False], HELICE[2]: [True, False]}[P("helice")]
        has_prop = any(u.enabled for u in ac.propulsion)
        series, checks, summ = {}, [], {}
        results = []
        for k, props in enumerate(cases):
            ctx.check()
            lab = "com hélice" if props else "sem hélice"
            ctx.on_progress(0.1 + 0.8 * k / len(cases), f"carga {lab}")
            r = compute(ctx.backend, ac, LoadCase(V=P("V"), n=P("n"), alpha=alpha, props=props and has_prop,
                                                  method=method))
            res = to_result(r, ctx.backend)
            results.append((lab, r, res))
            for d in res.distributions:
                if d.role not in dict(ROLES):
                    continue
                o = np.argsort(d.s)
                for f, _, _ in FIELDS:
                    if f in d.fields:
                        series[f"{f}_{d.role}_{lab}: {d.surface}"] = dict(
                            s=np.asarray(d.s)[o], y=np.asarray(d.fields[f])[o], _color=COLORS[lab], _width=2.0,
                            _dash=None if props else "dash")
        lab, r, res = results[0]
        series["v3d"] = {"superfícies": [d.surface for d in res.distributions], "_result": res, "_aircraft": ac,
                         "_label": lab}
        G = "ponto de voo"
        for lab, r, res in results:
            pre = f"[{lab}] "
            nW = r.weight * (P("n") if alpha is None else 1.0)
            summ[pre + "α (°), profundor (°)"] = [r.alpha, r.de]
            summ[pre + "sustentação das superfícies (N); n·peso (N)"] = [r.lift, nW]
            for s in r.surfaces:
                summ[pre + f"{s.name}: sustentação (N), arrasto (N)"] = [s.lift, s.drag]
            for p in r.props:
                summ[pre + f"{p.name}: rpm, T (N), J"] = [p.rpm, p.T, p.J]
            if r.trim is not None:
                ok = bool(r.trim.get("ok"))
                checks.append(Check("ok" if ok else "falha", f"trimagem {lab}",
                                    f"α = {r.alpha:.2f}°, δe = {r.de:.2f}°", "converge",
                                    "" if ok else "o ponto pedido está fora do envelope (V baixa demais para o n?)",
                                    "" if ok else "suba a velocidade ou baixe o fator de carga", G))
            if alpha is None and nW > 0:
                err = (r.lift - nW) / nW
                checks.append(Check("info", f"soma das cargas × n·peso {lab}", f"{100 * err:+.1f} %", "",
                                    "α e profundor vêm da trimagem do núcleo; a linha sustentadora redistribui a carga, "
                                    "então a soma difere um pouco" if method == "llt" else "", "", G))
        if not has_prop:
            checks.append(Check("info", "hélice", "o avião não tem motor ligado", "",
                                "as cargas saem sem hélice", "", G))
        elif not any("esteira" in m for m in results[0][1].modifiers):
            checks.append(Check("info", "esteira da hélice nas superfícies", "modificador de esteira desligado", "",
                                "com hélice, só a tração e o torque mudam a trimagem; as superfícies não veem a esteira",
                                "ligue 'esteira.disco' em Configuração → Modificadores", G))
        summ["método"] = P("method")
        summ["notas"] = "; ".join(dict.fromkeys(n for _, r, _ in results for n in r.notes))
        return SimResult(series=series, summary=summ, checks=checks)

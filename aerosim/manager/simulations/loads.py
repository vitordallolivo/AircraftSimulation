"""Cargas: a carga aerodinâmica ao longo de cada superfície num ponto de operação (velocidade, fator de carga, α),
com e sem a influência das hélices, em gráficos ao longo da envergadura e na vista 3D.

O ponto de voo (trimagem e hélices) sai do núcleo uma vez (`aerosim.aero.span_loads.prepare`); cada método de carga
(`aerosim.aero.all_load_methods`, interface `ILoadMethod`) calcula nesse mesmo ponto e devolve a entrada padrão
`LoadResult` (aerosim/interfaces/loads.py), que os gráficos e a vista 3D leem. Métodos: a linha sustentadora do núcleo
(`core/src/loads/llt.zig`), as faixas da simulação e o VLM do AeroSandbox; dá para comparar dois. A hélice é a do
conjunto motopropulsor do avião (rotação de equilíbrio na trimagem, ou o acelerador).

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
NENHUM = "nenhum"
COLORS = ("#1f4e8c", "#d95f02", "#2ca02c", "#9467bd")   # um por (método, hélice), na ordem em que rodam


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
                ParamSpec("method", "Método", _titles()[0], kind="choice", choices=_titles()),
                ParamSpec("compare", "Comparar com", NENHUM, kind="choice", choices=(NENHUM,) + _titles(),
                          help="outro método no mesmo ponto de voo (mesmo α e profundor), sobreposto nos gráficos")]

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
        from aerosim.aero import load_method
        from aerosim.aero.span_loads import LoadCase, prepare
        from aerosim.model.universal import build_model
        ac = ctx.aircraft.copy()
        model = build_model(ac)
        P = lambda k: self.param(ctx, k)
        alpha = P("alpha") if P("alpha_mode") == "imposto" else None
        names = [P("method")] + ([P("compare")] if P("compare") not in (NENHUM, P("method")) else [])
        methods = [load_method(ctx.backend, n) for n in names]
        cases = {"com hélice": [True], "sem hélice": [False], HELICE[2]: [True, False]}[P("helice")]
        has_prop = any(u.enabled for u in ac.propulsion)
        slip_on = any("esteira" in m.kind for m in ac.modifiers if getattr(m, "enabled", True))
        series, checks, summ, G = {}, [], {}, "ponto de voo"
        runs = []                                      # (rótulo, ponto, método, LoadResult)
        jobs = [(props, m) for props in cases for m in methods]
        for k, (props, m) in enumerate(jobs):
            ctx.check()
            lab = ("com hélice" if props else "sem hélice") + (f" · {m.title}" if len(methods) > 1 else "")
            ctx.on_progress(0.1 + 0.8 * k / len(jobs), f"carga {lab}")
            why = m.available()
            if why:
                checks.append(Check("falha", f"método {m.title}", why, "", "o método não pode rodar", "", G))
                continue
            if not runs or runs[-1][1].props_on != props:
                point = prepare(ctx.backend, ac, LoadCase(V=P("V"), n=P("n"), alpha=alpha, props=props and has_prop))
            res = m.compute(model, point)
            runs.append((lab, point, m, res))
            color = COLORS[(len(runs) - 1) % len(COLORS)]
            for d in res.distributions:
                if d.role not in dict(ROLES):
                    continue
                o = np.argsort(d.s)
                for f, _, _ in FIELDS:
                    if f in d.fields:
                        series[f"{f}_{d.role}_{lab}: {d.surface}"] = dict(
                            s=np.asarray(d.s)[o], y=np.asarray(d.fields[f])[o], _color=color, _width=2.0,
                            _dash=None if props else "dash")
        if not runs:
            return SimResult(series=series, summary=summ, checks=checks)
        lab, point, m, res = runs[0]
        series["v3d"] = {"superfícies": [d.surface for d in res.distributions], "_result": res, "_aircraft": ac,
                         "_label": lab}
        for lab, point, m, res in runs:
            pre = f"[{lab}] "
            nW = point.weight * (P("n") if alpha is None else 1.0)
            lift = sum(d.integral("L") for d in res.distributions)
            summ[pre + "α (°), profundor (°)"] = [point.alpha, point.de]
            summ[pre + "sustentação das superfícies (N); n·peso (N)"] = [lift, nW]
            for d in res.distributions:
                summ[pre + f"{d.surface}: sustentação (N), arrasto (N)"] = [d.integral("L"), d.integral("D")]
            for p in point.props:
                summ[pre + f"{p.name}: rpm, T (N), J"] = [p.rpm, p.T, p.J]
            if point.trim is not None and m is methods[0]:
                ok = bool(point.trim.get("ok"))
                checks.append(Check("ok" if ok else "falha", f"trimagem {lab}",
                                    f"α = {point.alpha:.2f}°, δe = {point.de:.2f}°", "converge",
                                    "" if ok else "o ponto pedido está fora do envelope (V baixa demais para o n?)",
                                    "" if ok else "suba a velocidade ou baixe o fator de carga", G))
            if alpha is None and nW > 0:
                err = (lift - nW) / nW
                checks.append(Check("info", f"soma das cargas × n·peso {lab}", f"{100 * err:+.1f} %", "",
                                    "α e profundor vêm da trimagem do núcleo; cada método redistribui a carga do seu "
                                    "jeito, então a soma difere um pouco do peso", "", G))
            if point.props_on and slip_on:
                for what in m.missing(["esteira"]):
                    checks.append(Check("atencao", f"{m.title}: {what}", "não modela", "",
                                        "a esteira está ligada no avião, mas este método não a vê", "", G))
        if not has_prop:
            checks.append(Check("info", "hélice", "o avião não tem motor ligado", "",
                                "as cargas saem sem hélice", "", G))
        elif not slip_on:
            checks.append(Check("info", "esteira da hélice nas superfícies", "modificador de esteira desligado", "",
                                "com hélice, só a tração e o torque mudam a trimagem; as superfícies não veem a esteira",
                                "ligue 'esteira.disco' em Configuração → Modificadores", G))
        summ["métodos"] = "; ".join(f"{m.title} ({m.source})" for m in methods)
        summ["notas"] = "; ".join(dict.fromkeys(n for _, _, _, res in runs for n in res.meta.get("avisos", [])))
        return SimResult(series=series, summary=summ, checks=checks)


def _titles() -> tuple[str, ...]:
    """títulos dos métodos de carga do registro (o backend não importa para listar)"""
    from aerosim.aero import all_load_methods
    return tuple(m.title for m in all_load_methods(None))

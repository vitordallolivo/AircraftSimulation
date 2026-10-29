"""Asas: a polar e a carga só das superfícies escolhidas (uma asa, um biplano, um tandem, asa e canard), sem trimar,
sem fuselagem e sem hélice, como num túnel de vento.

Cada α da varredura vira um ponto de voo (`LoadPoint`, α imposto, comandos em 0) e cada método de carga
(`aerosim.aero.all_load_methods`, interface `ILoadMethod`) devolve a carga ao longo de cada superfície (`LoadResult`).
Daí saem o C_L do conjunto e de cada superfície em α, o C_L máximo e onde o estol começa (na linha sustentadora não
linear, a primeira faixa que perde c_l depois do pico). As chapas nas pontas (opcional) entram como o dispositivo
"placa" de cada asa, como as que se põem no túnel para diminuir o efeito de ponta.

O Reynolds de cada superfície (corda média aerodinâmica) entra no diagnóstico: abaixo do Reynolds crítico dos perfis
de aeromodelo, a bolha laminar pode não recolar e o perfil perde sustentação, o que a polar única de cada perfil não
mostra.
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.loads import LoadPoint
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult

from .base import SimulationBase

NENHUM = "nenhum"
MU_AIR = 1.81e-5          # viscosidade dinâmica do ar (Pa·s), atmosfera padrão ao nível do mar (ISA, 15 °C)
# Reynolds crítico dos perfis de aeromodelo: abaixo dele a bolha laminar tende a não recolar (Lissaman, "Low-Reynolds-
# number airfoils", Annual Review of Fluid Mechanics 15, 1983 — valor a conferir no PDF)
RE_CRITICAL = 7e4
COLORS = ("#1f4e8c", "#d95f02", "#2ca02c", "#9467bd")


def _titles() -> tuple[str, ...]:
    from aerosim.aero import all_load_methods
    return tuple(m.title for m in all_load_methods(None))


def _default_method() -> str:
    """a linha sustentadora não linear (com estol), se existir no registro"""
    from aerosim.aero import all_load_methods
    names = {m.name: m.title for m in all_load_methods(None)}
    return names.get("llt_nl", _titles()[0])


def lifting_surfaces(aircraft) -> list:
    """(índice, superfície) das superfícies ligadas do avião"""
    return [(i, s) for i, s in enumerate(aircraft.surfaces) if s.enabled] if aircraft is not None else []


def wings_only(aircraft, chosen: list[int], endplate: float = 0.0):
    """cópia do avião só com as superfícies `chosen`, sem motores; com `endplate` > 0, uma placa de ponta (altura =
    `endplate` × corda da ponta) em cada superfície horizontal escolhida"""
    from aerosim.model.aircraft import WingDevice
    ac = aircraft.copy()
    for i, s in enumerate(ac.surfaces):
        s.enabled = s.enabled and i in chosen
        if s.enabled and endplate > 0 and not s.vertical:
            tip = max(s.sections, key=lambda q: q.y).chord if s.sections else 0.0
            s.devices.append(WingDevice(kind="placa", eta=1.0, height=endplate * tip, root_chord=0.0, taper=1.0,
                                        sweep=0.0, cant=0.0))
    for u in ac.propulsion:
        u.enabled = False
    return ac


class WingsSimulation(SimulationBase):
    tab = True
    name = "wings"
    title = "Asas"
    area = "aerodinamica"
    description = ("Polar e carga só das superfícies escolhidas (uma asa, biplano, tandem, canard), sem trimar, sem "
                   "fuselagem e sem hélice, como no túnel: C_L em α, C_L máximo, onde o estol começa e o Reynolds "
                   "de cada superfície.")

    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac, values=None):
        C = "Caso"
        ps = [ParamSpec("V", "velocidade", 12.0, minimum=2, maximum=80, unit="m/s", group=C),
              ParamSpec("a0", "α inicial", -4.0, minimum=-20, maximum=10, unit="°", group=C),
              ParamSpec("a1", "α final", 22.0, minimum=2, maximum=40, unit="°", group=C),
              ParamSpec("da", "passo de α", 1.0, minimum=0.25, maximum=5, unit="°", group=C),
              ParamSpec("alpha_load", "α da carga ao longo da envergadura", 10.0, minimum=-10, maximum=40, unit="°",
                        group=C),
              ParamSpec("endplate", "chapas nas pontas (altura / corda da ponta)", 0.0, minimum=0, maximum=5,
                        group=C, help="0: sem chapas; > 0: uma placa em cada ponta, como as do túnel"),
              ParamSpec("method", "método", _default_method(), kind="choice", choices=_titles(), group=C),
              ParamSpec("compare", "comparar com", NENHUM, kind="choice", choices=(NENHUM,) + _titles(), group=C)]
        S = "Superfícies"
        for i, s in lifting_surfaces(ac):
            ps.append(ParamSpec(f"surf_{i}", f"incluir: {s.name}", s.role == "wing", kind="bool", group=S))
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac, values=None):
        return [PlotSpec("CL", "C_L do conjunto × α", "alpha", ("CL",), "α (°)", "C_L (na soma das áreas)",
                         live=False, source="series:conjunto_*"),
                PlotSpec("CL_surf", "C_L de cada superfície × α", "alpha", ("CL",), "α (°)", "C_L (na área dela)",
                         live=False, source="series:superficie_*"),
                PlotSpec("cl_span", "c_l ao longo da envergadura (α da carga)", "s", ("cl",), "y (m)", "c_l",
                         live=False, source="series:cl_*"),
                PlotSpec("L_span", "Carga ao longo da envergadura (α da carga)", "s", ("L",), "y (m)", "L' (N/m)",
                         live=False, source="series:L_*")]

    def run(self, ctx: RunContext) -> SimResult:
        from aerosim.aero import load_method
        from aerosim.model.universal import build_model
        P = lambda k: self.param(ctx, k)
        chosen = [i for i, _ in lifting_surfaces(ctx.aircraft) if P(f"surf_{i}")]
        series, checks, summ, G = {}, [], {}, "asas"
        if not chosen:
            checks.append(Check("falha", "superfícies", "nenhuma escolhida", "", "marque ao menos uma superfície",
                                "", G))
            return SimResult(series=series, summary=summ, checks=checks)
        ac = wings_only(ctx.aircraft, chosen, float(P("endplate")))
        model = build_model(ac)
        names = [P("method")] + ([P("compare")] if P("compare") not in (NENHUM, P("method")) else [])
        methods = [load_method(ctx.backend, n) for n in names]
        V, rho = float(P("V")), ac.environment.rho
        q = 0.5 * rho * V * V
        surfaces = [s for s in ac.surfaces if s.enabled]
        S_total = sum(s.area for s in surfaces if not s.vertical)
        alphas = np.arange(P("a0"), P("a1") + 1e-9, P("da"))
        a_load = float(P("alpha_load"))
        if not np.any(np.isclose(alphas, a_load)):
            alphas = np.sort(np.append(alphas, a_load))
        jobs = len(alphas) * len(methods)
        for k_m, m in enumerate(methods):
            why = m.available()
            if why:
                checks.append(Check("falha", f"método {m.title}", why, "", "o método não pode rodar", "", G))
                continue
            color = COLORS[k_m % len(COLORS)]
            total, per_surface, results = [], {}, []
            for k_a, a in enumerate(alphas):
                ctx.check()
                ctx.on_progress((k_m * len(alphas) + k_a) / jobs, f"{m.title}: α = {a:g}°")
                res = m.compute(model, LoadPoint(V=V, alpha=float(a), rho=rho, props=[], props_on=False))
                results.append(res)
                lift = 0.0
                for d in res.distributions:
                    if d.role == "device" or d.vertical:      # as placas e a EV não sustentam
                        continue
                    L = d.integral("L")
                    lift += L
                    per_surface.setdefault(d.surface, []).append(L)
                total.append(lift / (q * S_total) if S_total > 0 else float("nan"))
            CL = np.array(total)
            series[f"conjunto_{m.title}"] = dict(alpha=alphas, CL=CL, _color=color, _width=2.0)
            for name, Ls in per_surface.items():
                Sa = _surface_area(surfaces, name)
                if Sa > 0 and len(Ls) == len(alphas):
                    series[f"superficie_{name} · {m.title}"] = dict(alpha=alphas, CL=np.array(Ls) / (q * Sa))
            k_load = int(np.argmin(np.abs(alphas - a_load)))
            for d in results[k_load].distributions:
                if d.role == "device" or d.vertical:
                    continue
                o = np.argsort(d.s)
                for f in ("cl", "L"):
                    if f in d.fields:
                        series[f"{f}_{d.surface} · {m.title}"] = dict(s=np.asarray(d.s)[o],
                                                                      **{f: np.asarray(d.fields[f])[o]})
            pre = f"[{m.title}] "
            k_max = int(np.nanargmax(CL))
            summ[pre + "C_L máximo, α dele (°)"] = [float(CL[k_max]), float(alphas[k_max])]
            if k_max == len(alphas) - 1:
                checks.append(Check("info", f"C_L máximo {m.title}", f"no fim da varredura ({alphas[-1]:g}°)", "",
                                    "o C_L ainda sobe no último α (o método não tem estol, ou falta varrer mais)",
                                    "aumente o α final ou use a linha sustentadora não linear", G))
            else:
                where = _stall_onset(results[k_max], results[k_max + 1])
                if where:
                    summ[pre + "onde o estol começa"] = where
                    tip = "ponta" in where
                    checks.append(Check("atencao" if tip else "ok", f"início do estol {m.title}", where,
                                        "da raiz para fora",
                                        "o estol na ponta tira o aileron e derruba a asa" if tip else "",
                                        "torção negativa na ponta, menos afilamento ou um perfil de c_l,max maior "
                                        "na ponta" if tip else "", G))
        for s in surfaces:
            if s.vertical:
                continue
            Re = rho * V * s.mac / MU_AIR
            summ[f"{s.name}: Reynolds (corda média) a {V:g} m/s"] = Re
            if Re < RE_CRITICAL:
                checks.append(Check("atencao", f"Reynolds {s.name}", f"{Re:.3g}", f"≥ {RE_CRITICAL:.0e}",
                                    "abaixo do Reynolds crítico dos perfis de aeromodelo a bolha laminar pode não "
                                    "recolar: o perfil perde sustentação, e a polar do perfil não mostra isso",
                                    "confira a polar do perfil nesse Reynolds", G))
        summ["área de referência (soma das horizontais, m²)"] = S_total
        summ["métodos"] = "; ".join(f"{m.title} ({m.source})" for m in methods)
        return SimResult(series=series, summary=summ, checks=checks)


def _surface_area(surfaces, name: str) -> float:
    """área da superfície de nome `name` (ou, se o método dividir a superfície, a de nome mais longo que começa
    `name`, para "asa de cima" não pegar a área de "asa")"""
    exact = [s.area for s in surfaces if s.name == name]
    if exact:
        return exact[0]
    prefix = sorted((s for s in surfaces if name.startswith(s.name)), key=lambda s: len(s.name), reverse=True)
    return prefix[0].area if prefix else 0.0


def _stall_onset(at_peak, after) -> str:
    """onde o estol começa: a faixa (das superfícies horizontais) cujo c_l mais cai do α do pico para o seguinte,
    como fração da semienvergadura dela ("raiz", "meio", "ponta")"""
    best, where = 0.0, ""
    for d0 in at_peak.distributions:
        if d0.vertical or d0.role == "device" or "cl" not in d0.fields:
            continue
        d1 = next((d for d in after.distributions if d.surface == d0.surface), None)
        if d1 is None or len(d1.fields.get("cl", [])) != len(d0.fields["cl"]):
            continue
        drop = np.asarray(d0.fields["cl"]) - np.asarray(d1.fields["cl"])
        k = int(np.argmax(drop))
        if drop[k] > best:
            half = max(np.max(np.abs(d0.s)), 1e-9)
            eta = abs(float(d0.s[k])) / half
            part = "raiz" if eta < 1 / 3 else ("meio" if eta < 2 / 3 else "ponta")
            best, where = float(drop[k]), f"{d0.surface}: {part} (y/b/2 = {eta:.2f})"
    return where

"""Asas: a simulação de aerodinâmica da aba Aerodinâmica. Analisa as superfícies escolhidas (uma asa, um biplano, um
tandem, asa e canard) sem trimar, sem fuselagem e sem hélice, como num túnel de vento, e, com o avião aberto pronto
(com massa), também o avião completo, como a antiga subaba Avião montado. Roda com o avião da Montagem ou com as asas
guardadas na sprint (etapa Asa), mesmo sem fuselagem e sem massa.

Quatro partes:

    varredura     cada α imposto e cada método de carga (`ILoadMethod.sweep`; no núcleo, `core/src/loads/sweep.zig`,
                  todos os α numa chamada) dão a sustentação de cada superfície; o resumo do núcleo
                  (`ISimBackend.wing_sweep_summary`) tira o C_L do conjunto e de cada uma, o C_L máximo e onde o estol
                  começa
    carga e 3D    no α da carga, a distribuição ao longo da envergadura e a vista 3D e de cima do que se simula
                  (`LoadResult`, a mesma vista da aba Cargas)
    métodos       as polares de cada solver marcado (`IAeroSolver`: lltdrek, modelo interno, linhas sustentadoras do
                  núcleo, AeroSandbox, AVL) só nas superfícies escolhidas, na soma das áreas
    avião completo  o avião aberto inteiro (`AerodynamicsSimulation`, sem aba própria): polares no CG, profundor e
                  derrapagem (núcleo 6GDL), estol × cruzeiro, L/D, pontas de asa; a polar fica para as outras abas

O Reynolds de cada superfície (corda média aerodinâmica, viscosidade de Sutherland no núcleo) entra no diagnóstico:
abaixo do Reynolds crítico dos perfis de aeromodelo, a bolha laminar pode não recolar e o perfil perde sustentação, o
que a polar única de cada perfil não mostra.
"""
from __future__ import annotations

import copy

import numpy as np

from aerosim.interfaces.loads import LoadPoint
from aerosim.interfaces.simulation import Check, ParamSpec, PlotSpec, RunContext, SimResult

from .base import SimulationBase

NENHUM = "nenhum"
OPEN, SPRINT = "avião aberto (Montagem)", "asas guardadas na sprint"
# Reynolds crítico dos perfis de aeromodelo: abaixo dele a bolha laminar tende a não recolar (Lissaman, "Low-Reynolds-
# number airfoils", Annual Review of Fluid Mechanics 15, 1983 — valor a conferir no PDF)
RE_CRITICAL = 7e4
COLORS = ("#1f4e8c", "#d95f02", "#2ca02c", "#9467bd")
# os solvers da comparação (os mesmos da subaba Avião montado) e se entram marcados
SOLVERS = (("lltdrek", "lltdrek (linha sustentadora não linear)", True),
           ("zig", "modelo interno (faixas da simulação)", True),
           ("zig_llt_gh", "linha sustentadora do núcleo (Goates e Hunsaker)", False),
           ("zig_llt", "linha sustentadora do núcleo (Phillips e Snyder)", False),
           ("asb_vlm", "AeroSandbox VLM", False),
           ("asb_buildup", "AeroSandbox AeroBuildup", False),
           ("asb_ll", "AeroSandbox LiftingLine", False),
           ("avl", "AVL", False))
WHOLE = "Avião completo (fuselagem, massa e CG)"
# campos da análise do avião completo (AerodynamicsSimulation) que vêm da própria aba Asas
SHARED_KEYS = {"V", "a0", "a1", "da", "section", "n_span"} | {f"use_{k}" for k, _, _ in SOLVERS}
# séries do avião completo que mudam de nome para não se misturar com as das superfícies escolhidas
RENAMED = (("polar_", "full_polar_"), ("ld_", "full_ld_"), ("span", "full_span"))


def _aero():
    """a análise do avião completo (a antiga subaba Avião montado), sem aba própria"""
    from .aerodynamics import AerodynamicsSimulation
    return AerodynamicsSimulation()


def _whole_default(ac) -> bool:
    """o avião completo entra por padrão quando o avião aberto está pronto (tem superfície e massa)"""
    from aerosim.model.templates import not_ready
    return ac is not None and not_ready(ac) is None


def _titles() -> tuple[str, ...]:
    from aerosim.aero import all_load_methods
    return tuple(m.title for m in all_load_methods(None))


def _default_method() -> str:
    """a linha sustentadora não linear (com estol), se existir no registro"""
    from aerosim.aero import all_load_methods
    names = {m.name: m.title for m in all_load_methods(None)}
    return names.get("llt_nl", _titles()[0])


def sprint_wings(shared) -> list[str]:
    """os nomes das asas guardadas na sprint (`shared["sprint"]`, o projeto da sprint)"""
    project = (shared or {}).get("sprint")
    return [w.name for w in getattr(project, "wings", [])]


def lifting_surfaces(aircraft) -> list:
    """(índice, superfície) das superfícies ligadas do avião"""
    return [(i, s) for i, s in enumerate(aircraft.surfaces) if s.enabled] if aircraft is not None else []


def strip_aircraft(ac):
    """sem fuselagem, sem motores, sem tanques e sem carga: só as superfícies (e os tubos onde elas se prendem)"""
    ac.fuselage.enabled = False
    for u in ac.propulsion:
        u.enabled = False
    ac.tanks = []
    ac.payload.enabled = False
    ac.gear.layout = "custom"
    return ac


def wings_only(aircraft, chosen: list[int], endplate: float = 0.0):
    """cópia do avião só com as superfícies `chosen`, sem fuselagem e sem motores; com `endplate` > 0, uma placa de
    ponta (altura = `endplate` × corda da ponta) em cada superfície horizontal escolhida"""
    from aerosim.model.aircraft import WingDevice
    ac = strip_aircraft(aircraft.copy())
    for i, s in enumerate(ac.surfaces):
        s.enabled = s.enabled and i in chosen
        if s.enabled and endplate > 0 and not s.vertical:
            tip = max(s.sections, key=lambda q: q.y).chord if s.sections else 0.0
            s.devices.append(WingDevice(kind="placa", eta=1.0, height=endplate * tip, root_chord=0.0, taper=1.0,
                                        sweep=0.0, cant=0.0))
    return ac


def sprint_aircraft(project, placed: list[tuple[str, float, float]]):
    """um avião só com as asas da sprint `placed` = [(nome, x do bordo de ataque da raiz, altura)], em m"""
    from aerosim.model.aircraft import Aircraft
    surfaces = []
    for name, x, height in placed:
        s = project.wing_surface(name)
        if s is None:
            continue
        s.x, s.z = x, -height                 # z do corpo para baixo
        s.incidence = 0.0                     # α da varredura = α da corda da raiz (a etapa Asa cala no cruzeiro)
        surfaces.append(s)
    ac = Aircraft(name="asas da sprint", surfaces=copy.deepcopy(surfaces))
    ac.propulsion = []
    return strip_aircraft(ac)


class WingsSimulation(SimulationBase):
    tab = True
    name = "wings"
    title = "Asas"
    area = "aerodinamica"
    needs_aircraft = False
    show_aircraft = True             # o avião aberto em 3D no topo (com a troca entre aviões abertos)
    detailed = tuple(f"use_{k}" for k, _, _ in SOLVERS) + ("section", "n_span", "compare")
    description = ("Aerodinâmica só das superfícies escolhidas (uma asa, biplano, tandem, canard), sem trimar, sem "
                   "fuselagem e sem hélice, como no túnel: C_L em α de cada superfície e do conjunto, C_L máximo, "
                   "onde o estol começa, a carga em 3D e a comparação dos métodos. Roda com o avião da Montagem ou "
                   "com as asas guardadas na sprint.")

    def parameters(self):
        return self.parameters_for(None)

    def parameters_for(self, ac, values=None):
        values = values or {}
        sprint = sprint_wings(self.shared)
        source = values.get("source", OPEN if (ac is not None and lifting_surfaces(ac)) or not sprint else SPRINT)
        F = "De onde vêm as asas"
        ps = [ParamSpec("source", "asas de", source, kind="choice", choices=(OPEN, SPRINT), group=F, rebuild=True,
                        help="o avião aberto na Montagem, ou as asas guardadas na etapa Asa da sprint (sem fuselagem)")]
        S = "Superfícies"
        if source == SPRINT:
            for i, name in enumerate(sprint):
                ps += [ParamSpec(f"sprint_{i}", f"incluir: {name}", i == 0, kind="bool", group=S),
                       ParamSpec(f"x_{i}", f"{name}: x do bordo de ataque da raiz", 0.0, minimum=-5, maximum=5,
                                 unit="m", group=S, help="tandem e canard: uma asa à frente da outra"),
                       ParamSpec(f"h_{i}", f"{name}: altura", 0.0, minimum=-3, maximum=3, unit="m", group=S,
                                 help="biplano: a asa de cima mais alta")]
        else:
            for i, s in lifting_surfaces(ac):
                ps.append(ParamSpec(f"surf_{i}", f"incluir: {s.name}", s.role == "wing", kind="bool", group=S))
        C = "Caso"
        ps += [ParamSpec("V", "velocidade", 12.0, minimum=2, maximum=80, unit="m/s", group=C),
               ParamSpec("a0", "α inicial", -4.0, minimum=-20, maximum=10, unit="°", group=C),
               ParamSpec("a1", "α final", 22.0, minimum=2, maximum=40, unit="°", group=C),
               ParamSpec("da", "passo de α", 1.0, minimum=0.25, maximum=5, unit="°", group=C),
               ParamSpec("alpha_load", "α da carga e da vista 3D", 10.0, minimum=-10, maximum=40, unit="°", group=C),
               ParamSpec("endplate", "chapas nas pontas (altura / corda da ponta)", 0.0, minimum=0, maximum=5,
                         group=C, help="0: sem chapas; > 0: uma placa em cada ponta, como as do túnel"),
               ParamSpec("xref", "ponto dos momentos", 25.0, minimum=0, maximum=100, unit="% CMA", group=C,
                         help="em % da corda média da asa principal, a partir do bordo de ataque dela")]
        L = "Carga ao longo da envergadura"
        ps += [ParamSpec("method", "método", _default_method(), kind="choice", choices=_titles(), group=L),
               ParamSpec("compare", "comparar com", NENHUM, kind="choice", choices=(NENHUM,) + _titles(), group=L)]
        if source == OPEN:
            whole = values.get("whole", _whole_default(ac))
            ps.append(ParamSpec("whole", "analisar também o avião completo", _whole_default(ac), kind="bool",
                                group=WHOLE, rebuild=True,
                                help="o avião aberto inteiro, como voa: polares no CG, profundor e derrapagem, estol × "
                                     "cruzeiro, L/D, pontas de asa; a polar fica para as outras abas (Desempenho...)"))
            if whole:
                aero_specs = _aero().parameters_for(ac, values)
                cruise = next((s for s in aero_specs if s.key == "V"), None)
                if cruise is not None:
                    ps.append(ParamSpec("V_cruise", "velocidade de cruzeiro", cruise.default, minimum=3, maximum=80,
                                        unit="m/s", group=WHOLE))
                for spec in aero_specs:
                    if spec.key in SHARED_KEYS:
                        continue
                    spec = copy.copy(spec)
                    spec.group = WHOLE if spec.group in ("Caso", "Métodos", "", None) else f"{WHOLE}: {spec.group}"
                    ps.append(spec)
        M = "Comparação dos métodos (polares)"
        ps += [ParamSpec(f"use_{k}", label, on, kind="bool", group=M) for k, label, on in SOLVERS]
        ps += [ParamSpec("section", "polar 2D dos perfis no lltdrek", "modelo", kind="choice",
                         choices=("modelo", "neuralfoil"), group=M,
                         help="modelo: a mesma polar do simulador; neuralfoil: a rede neural sobre o contorno .dat"),
               ParamSpec("n_span", "painéis por semiasa", 12, kind="int", minimum=4, maximum=40, group=M)]
        return ps

    def plots(self):
        return self.plots_for(None)

    def plots_for(self, ac, values=None):
        values = values or {}
        out = self._wing_plots()
        if values.get("source", OPEN) == OPEN and values.get("whole", _whole_default(ac)):
            for spec in _aero().plots_for(ac, values):
                spec = copy.copy(spec)
                for old, new in RENAMED:
                    if spec.source.startswith(f"series:{old}"):
                        spec.source = f"series:{new}" + spec.source[len(f"series:{old}"):]
                        break
                spec.key = f"ac_{spec.key}"
                if not spec.title.startswith("Aeronave completa"):
                    spec.title = f"Avião completo: {spec.title}"
                out.append(spec)
        return out

    def _wing_plots(self):
        return [PlotSpec("v3d", "Vista 3D do que se simula (α da carga)", "superfícies", ("superfícies",), live=False,
                         source="series:v3d", kind="loads3d", height=620),
                PlotSpec("top", "Vista de cima (α da carga)", "superfícies", ("superfícies",), live=False,
                         source="series:top", kind="loads3d", height=520),
                PlotSpec("CL", "C_L do conjunto × α", "alpha", ("CL",), "α (°)", "C_L (na soma das áreas)",
                         live=False, source="series:conjunto_*"),
                PlotSpec("CL_surf", "C_L de cada superfície × α", "alpha", ("CL",), "α (°)", "C_L (na área dela)",
                         live=False, source="series:superficie_*"),
                PlotSpec("cl_span", "c_l ao longo da envergadura (α da carga)", "s", ("cl",), "y (m)", "c_l",
                         live=False, source="series:cl_*"),
                PlotSpec("L_span", "Carga ao longo da envergadura (α da carga)", "s", ("L",), "y (m)", "L' (N/m)",
                         live=False, source="series:L_*"),
                PlotSpec("pol_CL", "Métodos: C_L × α", "alpha", ("CL",), "α (°)", "C_L (na soma das áreas)",
                         live=False, source="series:polar_*"),
                PlotSpec("pol_CD", "Métodos: polar de arrasto", "CD", ("CL",), "C_D", "C_L (na soma das áreas)",
                         live=False, source="series:polar_*"),
                PlotSpec("pol_Cm", "Métodos: C_m no ponto dos momentos × α", "alpha", ("Cm",), "α (°)",
                         "C_m (na soma das áreas e na CMA da asa principal)",
                         live=False, source="series:polar_*"),
                PlotSpec("pol_LD", "Métodos: L/D × C_L", "CL", ("LD",), "C_L", "L/D", live=False,
                         source="series:ld_*")]

    # ------------------------------------------------------------------ o avião que se analisa
    def _aircraft(self, ctx: RunContext):
        """(avião só com as superfícies escolhidas, motivo se não deu)"""
        P = lambda k: self.param(ctx, k)
        if P("source") == SPRINT:
            project = (self.shared or ctx.shared or {}).get("sprint")
            names = sprint_wings(self.shared or ctx.shared)
            placed = [(n, float(P(f"x_{i}")), float(P(f"h_{i}"))) for i, n in enumerate(names) if P(f"sprint_{i}")]
            if project is None or not placed:
                return None, "nenhuma asa da sprint marcada (guarde uma asa na etapa Asa)"
            ac = sprint_aircraft(project, placed)
            return wings_only(ac, list(range(len(ac.surfaces))), float(P("endplate"))), ""
        chosen = [i for i, _ in lifting_surfaces(ctx.aircraft) if P(f"surf_{i}")]
        if not chosen:
            return None, "nenhuma superfície marcada"
        return wings_only(ctx.aircraft, chosen, float(P("endplate"))), ""

    # ------------------------------------------------------------------ análise
    def run(self, ctx: RunContext) -> SimResult:
        from aerosim.aero import AeroCase, all_solvers, load_method
        from aerosim.model.universal import build_model
        from .aerodynamics import compare_solvers
        P = lambda k: self.param(ctx, k)
        series, checks, summ, G = {}, [], {}, "asas"
        add = lambda *a, **k: checks.append(Check(*a, **k))
        ac, why = self._aircraft(ctx)
        if ac is None:
            add("falha", "superfícies", why, "", "marque ao menos uma superfície", "", G)
            return SimResult(series=series, summary=summ, checks=checks)
        model = build_model(ac)
        V, rho = float(P("V")), ac.environment.rho
        q = 0.5 * rho * V * V
        surfaces = [s for s in ac.surfaces if s.enabled]
        owners = [s.name for s in surfaces if not s.vertical]
        S_total = sum(s.area for s in surfaces if not s.vertical)
        alphas = np.arange(P("a0"), P("a1") + 1e-9, P("da"))
        a_load = float(P("alpha_load"))
        names = [P("method")] + ([P("compare")] if P("compare") not in (NENHUM, P("method")) else [])
        methods = [load_method(ctx.backend, n) for n in names]
        first = None                                   # a varredura do método principal (Reynolds)
        for k_m, m in enumerate(methods):
            ctx.check()
            ctx.on_progress(0.05 + 0.45 * k_m / len(methods), f"varredura em α: {m.title}")
            why = m.available()
            if why:
                add("falha", f"método {m.title}", why, "", "o método não pode rodar", "", G)
                continue
            color = COLORS[k_m % len(COLORS)]
            sw = m.sweep(model, V, alphas, rho, owners)
            r = ctx.backend.wing_sweep_summary(sw.owner_lift, sw.owner_area, q, sw.section_cl, sw.panel_owner,
                                               sw.panel_span)
            first = first or sw
            series[f"conjunto_{m.title}"] = dict(alpha=alphas, CL=r["total_cl"], _color=color, _width=2.0)
            for k, name in enumerate(owners):
                if sw.owner_area[k] > 0:
                    series[f"superficie_{name} · {m.title}"] = dict(alpha=alphas, CL=r["owner_cl"][:, k])
            pre = f"[{m.title}] "
            summ[pre + "C_L máximo, α dele (°)"] = [r["lift_max"], float(alphas[r["peak"]])]
            if r["peak"] == len(alphas) - 1:
                add("info", f"C_L máximo {m.title}", f"no fim da varredura ({alphas[-1]:g}°)", "",
                    "o C_L ainda sobe no último α (o método não tem estol, ou falta varrer mais)",
                    "aumente o α final ou use a linha sustentadora não linear", G)
            elif r["onset_panel"] >= 0:
                frac = r["onset_fraction"]
                part = "raiz" if frac < 1 / 3 else ("meio" if frac < 2 / 3 else "ponta")
                where = f"{owners[sw.panel_owner[r['onset_panel']]]}: {part} (y/b/2 = {frac:.2f})"
                summ[pre + "onde o estol começa"] = where
                tip = part == "ponta"
                add("atencao" if tip else "ok", f"início do estol {m.title}", where, "da raiz para fora",
                    "o estol na ponta tira o aileron e derruba a asa" if tip else "",
                    "torção negativa na ponta, menos afilamento ou um perfil de c_l,max maior na ponta" if tip else "",
                    G)
            # a carga ao longo da envergadura e a vista 3D, no α da carga
            res = m.compute(model, LoadPoint(V=V, alpha=a_load, rho=rho, props=[], props_on=False))
            for d in res.distributions:
                if d.role == "device" or d.vertical:
                    continue
                o = np.argsort(d.s)
                for f in ("cl", "L"):
                    if f in d.fields:
                        series[f"{f}_{d.surface} · {m.title}"] = dict(s=np.asarray(d.s)[o],
                                                                      **{f: np.asarray(d.fields[f])[o]})
            if "v3d" not in series:
                view = {"superfícies": [d.surface for d in res.distributions], "_result": res, "_aircraft": ac,
                        "_label": f"{m.title}, α = {a_load:g}°"}
                far = 2.6 * max(model.b, 0.5)        # a câmera longe o bastante para caber a envergadura
                series["v3d"] = dict(view, _camera={"distance": far, "elevation": 24, "azimuth": -125})
                series["top"] = dict(view, _camera={"distance": far, "elevation": 90, "azimuth": 180})   # nariz para cima
        if first is not None:
            for k, name in enumerate(owners):
                Re = ctx.backend.reynolds(rho, V, float(first.owner_chord[k]), ac.environment.density_altitude)
                summ[f"{name}: Reynolds (corda média) a {V:g} m/s"] = Re
                if Re < RE_CRITICAL:
                    add("atencao", f"Reynolds {name}", f"{Re:.3g}", f"≥ {RE_CRITICAL:.0e}",
                        "abaixo do Reynolds crítico dos perfis de aeromodelo a bolha laminar pode não recolar: o "
                        "perfil perde sustentação, e a polar do perfil não mostra isso",
                        "confira a polar do perfil nesse Reynolds", G)
            summ["área de referência (soma das horizontais, m²)"] = float(np.sum(first.owner_area))
        summ["métodos de carga"] = "; ".join(f"{m.title} ({m.source})" for m in methods)
        # comparação dos métodos (polares), só nas superfícies escolhidas
        chosen = [s for s in all_solvers(ctx.backend) if P(f"use_{s.name}")]
        if chosen and model.wing is not None:
            case = AeroCase(V=V, alphas=alphas, alpha_d=a_load, ref=(model.x_at_mac(float(P("xref")) / 100), 0.0, 0.0),
                            rho=rho, section=P("section"), n_span=int(P("n_span")))
            summ["métricas dos métodos ([...] C_L0, C_Lmax...): na área da asa principal (m²)"] = model.S
            before = set(series)
            whole = P("source") == OPEN and bool(P("whole"))
            _, _, _, span = compare_solvers(ctx, model, case, chosen, series, summ, add,
                                            progress=(0.5, 0.65 if whole else 0.98))
            # todo método marcado em todo gráfico que ele preenche, na mesma referência (a soma das áreas)
            scale = model.S / S_total if S_total > 0 else 1.0
            for key in [k for k in series if k.startswith("polar_") and k not in before]:
                pol, lab = series[key], key[len("polar_"):]
                for f in ("CL", "CD", "CDi", "Cm"):
                    pol[f] = np.asarray(pol[f], float) * scale
                series[f"conjunto_{lab}"] = dict(alpha=pol["alpha"], CL=pol["CL"], _dash="dash")
                if len(owners) == 1:
                    series[f"superficie_{owners[0]} · {lab}"] = dict(alpha=pol["alpha"], CL=pol["CL"], _dash="dash")
            if span is not None:                       # lltdrek: a carga da asa principal no α da carga
                o = np.argsort(span["y"])
                y, cl = np.asarray(span["y"], float)[o], np.asarray(span["cl"], float)[o]
                series[f"cl_{model.wing.name} · lltdrek"] = dict(s=y, cl=cl, _dash="dash")
                series[f"L_{model.wing.name} · lltdrek"] = dict(s=y, L=q * np.asarray(span["ccl"], float)[o] * model.c,
                                                                _dash="dash")
        elif chosen:
            add("info", "comparação dos métodos", "sem asa principal", "",
                "os solvers tomam a referência (S, c, b) da asa principal: marque uma superfície do tipo asa", "",
                "métodos")
        if P("source") == OPEN and P("whole"):
            self._whole(ctx, P, series, summ, checks)
        return SimResult(series=series, summary=summ, checks=checks)

    def _whole(self, ctx: RunContext, P, series: dict, summ: dict, checks: list) -> None:
        """o avião aberto inteiro, como a antiga subaba Avião montado (AerodynamicsSimulation): as séries dele com
        nome próprio (`RENAMED`), o resumo com "avião completo ·" na frente e os diagnósticos dele"""
        from aerosim.model.templates import not_ready
        why = not_ready(ctx.aircraft)
        if why:
            checks.append(Check("info", "avião completo", "não analisado", "", why, "", "avião completo"))
            return
        aero = _aero()
        aero.shared = self.shared
        keys = {p.key for p in aero.parameters_for(ctx.aircraft, ctx.params)}
        params = {k: P(k) for k in keys if k != "V" and (k in SHARED_KEYS or k in ctx.params)}
        params["V"] = P("V_cruise")
        sub = RunContext(backend=ctx.backend, aircraft=ctx.aircraft, params=params, checkpoints=ctx.checkpoints,
                         on_progress=lambda f, m: ctx.on_progress(0.65 + 0.35 * f, f"avião completo: {m}"),
                         cancel=ctx.cancel, shared=ctx.shared)
        r = aero.run(sub)
        for key, value in r.series.items():
            for old, new in RENAMED:
                if key.startswith(old):
                    key = new + key[len(old):]
                    break
            series[key] = value
        for key, value in r.summary.items():
            summ[f"avião completo · {key}"] = value
        checks.extend(r.checks)

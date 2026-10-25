"""Estudo e ponto de projeto: as áreas se retroalimentam (não em ordem) e o estudo mostra onde estabilidade e
desempenho fecham juntos.

Cada ponto é um `power.design_point` (massa de projeto → asa e EH recalibradas, com o momento da tração →
desempenho → MTOW → massa de projeto ... até convergir) em cada altitude-densidade pedida. Dois modos:

    varrer uma variável     inclinação do motor, margem estática, V_H, braço da cauda, área, envergadura,
                            ângulo de cruzeiro — de um avião (guardado ou o rascunho da etapa Motores)
    comparar guardados      todos os aviões guardados na etapa Motores, lado a lado

Viável = converge e a estabilidade fecha nessa massa: o profundor consegue rodar o avião (com a tração), o trim
de decolagem cabe no curso de picar, a EH não estola no C_L,max e o CG fica onde a bateria alcança. O que limita
o MTOW sai junto: a pista ou a rotação (se o avião só roda depois de poder sair do chão, a corrida espera). O estudo
marca o maior MTOW viável de cada altitude — indica, não escolhe: "usar este ponto" leva o valor para o
rascunho da etapa certa.
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.interfaces.simulation import Check, PlotSpec, SimResult

from . import power as pw
from .fields import F

MODES = ("varrer uma variável", "comparar aviões guardados")
DRAFT = "(rascunho da etapa Motores)"
# rótulo → (etapa, campo)
VARIABLES = {
    "inclinação do motor (°)": ("power", "tilt"),
    "margem estática (% CMA)": ("tail", "sm_target"),
    "volume de cauda V_H": ("tail", "VH"),
    "braço da cauda (m)": ("tail", "arm"),
    "área da asa (m²)": ("wing", "area"),
    "envergadura (m)": ("wing", "span"),
    "ângulo de cruzeiro (°)": ("wing", "alpha_cruise"),
}


@dataclass
class StudyParams:
    mode: str = F(MODES[0], "estudo", "", "", choices=MODES)
    aircraft: str = F(DRAFT, "avião", "", "um dos guardados na etapa Motores ou o rascunho dela")
    variable: str = F("inclinação do motor (°)", "variável", "", "", choices=tuple(VARIABLES))
    start: float = F(0.0, "de", "", "", -100, 100, 0.5)
    stop: float = F(12.0, "até", "", "", -100, 100, 0.5)
    n: int = F(7, "pontos", "", "")
    places: str = F("", "altitudes-densidade", "", "lugar=AD em metros, separados por vírgula (ex.: Joinville=655, "
                    "São José dos Campos=1320); vazio: a dos requisitos")


@dataclass
class StudyRun:
    """um estudo rodado, guardado no projeto (os dados de simulação): os parâmetros e uma linha por ponto
    (sem os objetos — o avião de cada linha se refaz quando precisa)"""
    mode: str = MODES[0]
    aircraft: str = DRAFT
    variable: str = "inclinação do motor (°)"
    places: str = ""
    rows: list[dict] = field(default_factory=list)

    def key(self) -> tuple:
        return (self.mode, self.aircraft, self.variable if self.mode == MODES[0] else "", self.places)


ROW_KEYS = ("place", "ad", "x", "name", "mtow", "mtow6", "converged", "ok", "why", "limit", "pv", "v_rot", "v_lof",
            "hold", "dih", "cd_trim", "incidence", "i_h")


def to_run(sp: StudyParams, rows: list[dict]) -> StudyRun:
    clean = []
    for r in rows:
        c = {}
        for k in ROW_KEYS:
            v = r.get(k)
            c[k] = bool(v) if isinstance(v, (bool, np.bool_)) else (float(v) if isinstance(v, (int, float, np.floating))
                                                                    and not isinstance(v, bool) else v)
        clean.append(c)
    return StudyRun(sp.mode, sp.aircraft, sp.variable, sp.places, clean)


def from_run(run: StudyRun) -> tuple[StudyParams, list[dict]]:
    sp = StudyParams(mode=run.mode, aircraft=run.aircraft, variable=run.variable, places=run.places)
    return sp, [dict(r) for r in run.rows]


def ensure(row: dict, project, sp: StudyParams, catalog=None, backend=None) -> dict:
    """refaz o ponto de projeto de uma linha guardada (para o 3D, o 6GDL e mandar para a Montagem)"""
    if "_cand" in row:
        return row
    if sp.mode == MODES[1]:
        base = next((a for a in project.aircraft if a.name == row["name"]), None)
    else:
        b0 = next((a for a in project.aircraft if a.name == sp.aircraft), None) or project.draft_aircraft()
        base = with_value(b0, sp.variable, row["x"]) if b0 is not None else None
    if base is None:
        raise ValueError(f"o avião '{row['name']}' não está mais no projeto")
    rq = copy.deepcopy(project.requirements)
    rq.density_altitude = row["ad"]
    d = pw.design_point(base, rq, project.rules, catalog, project.airfoil_map(), backend)
    row["_cand"], row["_req"] = d["cand"], d["req"]
    return row


def table(rows: list[dict]) -> dict:
    """as linhas como tabela (para exportar xlsx/csv)"""
    return {k: [r.get(k) for r in rows] for k in ROW_KEYS}


def parse_places(text: str, ad_default: float) -> list[tuple[str, float]]:
    out = []
    for part in (text or "").split(","):
        part = part.strip()
        if not part:
            continue
        name, _, val = part.rpartition("=")
        try:
            ad = float(val)
        except ValueError:
            continue
        out.append(((name or f"AD {ad:.0f} m").strip(), ad))
    return out or [(f"AD {ad_default:.0f} m", ad_default)]


def with_value(cand: pw.AircraftCandidate, var: str, x: float) -> pw.AircraftCandidate:
    """cópia do avião com a variável mudada na etapa dela (asa e conjunto vão dentro do avião)"""
    c = copy.deepcopy(cand)
    stage, field = VARIABLES[var]
    target = {"power": c.params, "tail": c.set.params, "wing": c.set.wing.params}[stage]
    setattr(target, field, float(x))
    return c


def feasibility(d: dict) -> tuple[bool, str]:
    asm = d["asm"]
    tr = asm.get("trim") or {}
    st = asm["set"]
    why = []
    if not math.isfinite(d["mtow"]):
        why.append("não decola na pista")
    elif not d["converged"]:
        why.append("massa de projeto não converge")
    v_rot = tr.get("V_rot", 0.0)
    if not math.isfinite(v_rot):
        why.append("o profundor não consegue rodar o avião")
    if not tr.get("hold_ok", True):
        why.append("trim de decolagem passa do curso de picar")
    if "CLh_lim" in st and not (st["CLh_lim"][0] <= st["CLh_CLmax"] <= st["CLh_lim"][1]):
        why.append("EH estola no C_L,max")
    if not asm["battery_fits"]:
        why.append(f"precisa de {asm['ballast']:.2f} kg de lastro de equilíbrio")
    req = d.get("req")
    if req is not None and "ac" in d:                 # as restrições ativas (a corrida já define o MTOW)
        from . import registry as rg
        vals = rg.aircraft_values(d["ac"], asm, d["pf"], d["cand"].params)
        for c, ok, txt in rg.checks(req.constraints, vals):
            if not ok and c.key not in ("s_to", "mtow"):
                why.append(f"{c.quantity.label}: {txt}")
    return not why, "; ".join(why)


def point_row(d: dict, label: str, ad: float, x) -> dict:
    ok, why = feasibility(d)
    asm, pf = d["asm"], d["pf"]
    tr = asm.get("trim") or {}
    late = tr.get("V_rot", 0.0) > tr.get("V_lof", math.inf)
    return dict(place=label, ad=ad, x=x, mtow=d["mtow"], converged=d["converged"], ok=ok, why=why,
                limit="rotação" if late else "pista",
                pv=asm["empty"], v_rot=tr.get("V_rot", float("nan")), v_lof=tr.get("V_lof", float("nan")),
                hold=tr.get("hold", 0.0), dih=tr.get("dih", 0.0), cd_trim=pf.get("CD_trim_cruise", 0.0),
                incidence=asm["set"]["wing"]["incidence"], i_h=asm["set"].get("i_h", 0.0), mtow6=float("nan"))


def run(project, sp: StudyParams, catalog=None, backend=None, progress=None, cancel=None) -> list[dict]:
    """as linhas do estudo (um ponto de projeto acoplado por valor × altitude, ou por avião × altitude)"""
    req0, rules = project.requirements, project.rules
    places = parse_places(sp.places, req0.density_altitude)
    if sp.mode == MODES[1]:
        items = [(i, a.name, a) for i, a in enumerate(project.aircraft)]
    else:
        base = next((a for a in project.aircraft if a.name == sp.aircraft), None) or project.draft_aircraft()
        if base is None:
            return []
        xs = np.linspace(sp.start, sp.stop, max(int(sp.n), 1))
        items = [(float(x), f"{x:g}", with_value(base, sp.variable, x)) for x in xs]
    rows = []
    total = len(items) * len(places)
    k = 0
    for label, ad in places:
        rq = copy.deepcopy(req0)
        rq.density_altitude = ad
        for x, name, cand in items:
            if cancel is not None and cancel():
                return rows
            if progress:
                progress(k / max(total, 1), f"{label}: {name}")
            d = pw.design_point(cand, rq, rules, catalog, project.airfoil_map(), backend)
            r = point_row(d, label, ad, x)
            r["name"] = name
            r["_cand"] = d["cand"]
            r["_req"] = d["req"]
            rows.append(r)
            k += 1
    return rows


def best_rows(rows: list[dict]) -> dict:
    """maior MTOW viável de cada altitude — pelo 6GDL quando os pontos daquela altitude foram conferidos nele"""
    out = {}
    for pl in dict.fromkeys(r["place"] for r in rows):
        rr = [r for r in rows if r["place"] == pl and r["ok"]]
        six = [r for r in rr if math.isfinite(r["mtow6"])]
        pool, key = (six, "mtow6") if six else ([r for r in rr if math.isfinite(r["mtow"])], "mtow")
        if pool:
            out[pl] = max(pool, key=lambda r: r[key])
    return out


def mtow_of(r: dict) -> float:
    return r["mtow6"] if math.isfinite(r["mtow6"]) else r["mtow"]


def check_6dof(row: dict, project, manager, catalog=None) -> float:
    """MTOW 6GDL (aba Missão, modo MTOW) do avião daquele ponto: bisseção na massa total, profundor otimizado"""
    return _mtow6(row["_cand"], row["_req"], project.rules, catalog, project.airfoil_map(), manager)


def _mtow6(cand, req, rules, catalog, airfoils, manager, m_max: float | None = None) -> float:
    """`m_max`: o topo da bisseção na massa total (padrão: PV + 15 kg); um topo perto do MTOW esperado gasta menos
    voos"""
    ac, asm = pw.assemble(cand, req, rules, catalog, airfoils)
    x = asm["x_cg_target"]
    from aerosim.manager.simulations.mission import total_mass
    m0 = total_mass(ac)                       # o PV (a carga ainda sem kg): a massa total varre daí para cima
    masses = [dict(item="Massa total (kg)", min=m0, nom=max(asm["mass"], m0), max=m0 + 15.0),
              dict(item="xCG (m)", min=x, nom=x, max=x)]
    if m_max is not None:
        masses[0]["max"] = max(float(m_max), m0 + 0.1)
    r = manager.run("mission", ac, {"mode": "MTOW (x_warning e z_warning)", "masses": masses})
    return float(r.summary.get("MTOW (kg)", float("nan")))


def _mtow6_job(args):
    cand, req, rules, catalog, airfoils, backend_cls = args
    from aerosim.manager import SimulationManager
    return _mtow6(cand, req, rules, catalog, airfoils, SimulationManager(backend_cls()))


def check_many(rows: list[dict], project, manager, catalog=None, progress=None, cancel=None, workers=None) -> None:
    """confere vários pontos no 6GDL, em paralelo (um processo por núcleo); preenche r['mtow6']"""
    import os
    from concurrent.futures import ProcessPoolExecutor, as_completed
    if not rows:
        return
    n = workers or max(1, min(len(rows), (os.cpu_count() or 2)))
    if n == 1:
        for i, r in enumerate(rows):
            if cancel is not None and cancel():
                return
            if progress:
                progress(i / len(rows), f"6GDL: {r['place']} — {r['name']}")
            r["mtow6"] = check_6dof(r, project, manager, catalog)
        return
    args = [(r["_cand"], r["_req"], project.rules, catalog, project.airfoil_map(), type(manager.backend)) for r in rows]
    with ProcessPoolExecutor(max_workers=n) as ex:
        futs = {ex.submit(_mtow6_job, a): r for a, r in zip(args, rows)}
        for k, f in enumerate(as_completed(futs)):
            r = futs[f]
            try:
                r["mtow6"] = f.result()
            except Exception:
                r["mtow6"] = float("nan")
            if progress:
                progress((k + 1) / len(rows), f"6GDL: {r['place']} — {r['name']} ({k + 1}/{len(rows)})")
            if cancel is not None and cancel():
                for g in futs:
                    g.cancel()
                return


COLORS = ("#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e")


def result(rows: list[dict], sp: StudyParams) -> tuple[list[PlotSpec], SimResult]:
    var = sp.variable if sp.mode == MODES[0] else "avião (nº na tabela)"
    plots = [PlotSpec("mtow", "MTOW (● rápido, ★ 6GDL, × não fecha)", "x", ("y",),
                      var, "kg", live=False, source="series:m_*"),
             PlotSpec("rot", "Roda (—) × sai do chão (- -)", "x", ("y",), var, "m/s", live=False,
                      source="series:r_*"),
             PlotSpec("trim", "Δi_h (—) e trim de decolagem (- -)", "x", ("y",), var, "°",
                      live=False, source="series:t_*"),
             PlotSpec("cdt", "Arrasto de trim da EH (cruzeiro)", "x", ("y",), var, "C_D,trim", live=False,
                      source="series:c_*")]
    S, summ, checks = {}, {}, []
    places = list(dict.fromkeys(r["place"] for r in rows))
    for j, pl in enumerate(places):
        col = COLORS[j % len(COLORS)]
        rr = [r for r in rows if r["place"] == pl]
        x = np.array([r["x"] if sp.mode == MODES[0] else i + 1 for i, r in enumerate(rr)], float)
        m = np.array([r["mtow"] for r in rr], float)
        ok = np.array([r["ok"] for r in rr])
        S[f"m_{pl}"] = dict(x=x, y=np.where(ok, m, np.nan), _color=col, _width=2.4, _symbol="o", _line=1)
        if (~ok).any():
            S[f"m_{pl}: não fecha"] = dict(x=x[~ok], y=np.where(np.isfinite(m[~ok]), m[~ok], np.nan), _color=col,
                                          _symbol="x", _size=13)
        m6 = np.array([r["mtow6"] for r in rr], float)
        if np.isfinite(m6).any():
            S[f"m_{pl}: 6GDL"] = dict(x=x, y=m6, _color=col, _symbol="star", _size=18)
        S[f"r_{pl}: roda"] = dict(x=x, y=np.array([r["v_rot"] for r in rr], float), _color=col, _width=2.2)
        S[f"r_{pl}: sai do chão"] = dict(x=x, y=np.array([r["v_lof"] for r in rr], float), _color=col, _dash="dash")
        S[f"t_{pl}: Δi_h"] = dict(x=x, y=np.array([r["dih"] for r in rr], float), _color=col, _width=2.2)
        S[f"t_{pl}: decolagem"] = dict(x=x, y=np.array([r["hold"] for r in rr], float), _color=col, _dash="dash")
        S[f"c_{pl}"] = dict(x=x, y=np.array([r["cd_trim"] for r in rr], float), _color=col, _width=2.2)
    best = best_rows(rows)
    for pl in places:
        b = best.get(pl)
        if b is None:
            checks.append(Check("falha", f"{pl}: nenhum ponto fecha", "—", "estabilidade e desempenho juntos",
                                "; ".join(sorted({r['why'] for r in rows if r['place'] == pl and r['why']}))[:300],
                                "mude a faixa da variável ou outra etapa (EH invertida, área, braço)", "ponto de projeto"))
            continue
        lab = b["name"] if sp.mode == MODES[1] else f"{sp.variable.split(' (')[0]} = {b['x']:g}"
        src = "6GDL" if math.isfinite(b["mtow6"]) else "conta rápida"
        checks.append(Check("info", f"{pl}: maior MTOW viável ({src})", f"{mtow_of(b):.2f} kg ({lab})",
                            "converge, roda, trim no curso, EH sem estolar",
                            f"limitado por {b['limit']}; PV {b['pv']:.2f} kg → CP possível {mtow_of(b) - b['pv']:.2f} kg; "
                            f"roda a {b['v_rot']:.1f} "
                            f"m/s (sai do chão a {b['v_lof']:.1f}); Δi_h {b['dih']:+.2f}°, trim de decolagem "
                            f"{b['hold']:.1f}°", "‘Usar o ponto marcado’ leva o valor para o rascunho", "ponto de projeto"))
        summ[f"{pl}: maior MTOW viável (kg, {src}), em"] = [mtow_of(b), lab]
    nbad = sum(not r["ok"] for r in rows)
    if nbad:
        checks.append(Check("atencao", "pontos em que a estabilidade não fecha", f"{nbad} de {len(rows)}", "—",
                            "veja a coluna 'por quê' na tabela", "", "ponto de projeto"))
    checks.append(Check("info", "método", "ponto de projeto acoplado", "—",
                        "massa de projeto → asa e EH recalibradas (com o momento da tração) → desempenho → MTOW → "
                        "massa de projeto, até convergir; arrasto de trim da EH no desempenho", "", "ponto de projeto"))
    return plots, SimResult(series=S, summary=summ, checks=checks)

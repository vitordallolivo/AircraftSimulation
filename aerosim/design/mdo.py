"""Dimensionamento inicial como mini-MDO: monta a configuração do núcleo (`core/src/sizing`) a partir do
projeto e lê os resultados. As contas e o otimizador estão em Zig; aqui só se traduz.

    geometria (envergadura, área, afilamento, perfil da raiz e da ponta)
      → motorização (motor × hélice × bateria das listas, n motores, inclinação)
      → envelope de voo (as velocidades saem dele) → decolagem → MTOW, PV, CP, EE

A empenagem não é dimensionada aqui: entra como fração da área da asa (massa e arrasto). As variáveis
(`registry.Variable`: fixo / variável / lista) e as restrições ativas são as do projeto
(Condições e restrições…); o tipo de aeronave, o objetivo e o otimizador ficam em `MdoParams`.

    cfg, names = build(projeto, catálogo, backend)
    rows, best = run(projeto, catálogo, backend, progress=lambda it, rows: ...)
    apply(projeto, rows[k])          # leva o indivíduo para os rascunhos das etapas
"""
from __future__ import annotations

import copy
import itertools
import math
from dataclasses import dataclass, field

import numpy as np

from aerosim.model.aircraft import PropulsionUnit
from aerosim.model.catalog import builtin_catalog

from . import airfoils as afm
from . import registry as rg
from .fields import F
from .power import LAYOUTS

KINDS = ("monoplano", "biplano", "asa voadora", "tailsitter", "VTOL")     # a ordem de core/src/sizing/kinds.zig
OBJECTIVES = ("MTOW", "EE")
METHODS = ("PSO (enxame de partículas)", "busca aleatória")              # a ordem de optimize.zig


@dataclass
class MdoParams:
    kind: str = F("monoplano", "tipo de aeronave", "", "biplano: duas asas de mesma envergadura dividindo a área "
                  "(interferência de Prandtl); asa voadora/tailsitter: sem EH, C_L,max de equilíbrio menor; "
                  "tailsitter decola na vertical; VTOL paira se a tração deixar", choices=KINDS)
    objective: str = F("MTOW", "maximizar", "", "MTOW ou EE = CP/PV (a pontuação de competição fica de fora: "
                       "as duas saem guardadas para recalcular)", choices=OBJECTIVES)
    method: str = F("PSO (enxame de partículas)", "otimizador", "", "a busca aleatória serve de referência",
                    choices=METHODS)
    particles: int = F(24, "população", "", "PSO: partículas por iteração", 2, 256, 1)
    iterations: int = F(40, "iterações", "", "", 1, 2000, 1)
    seed: int = F(1, "semente", "", "a mesma semente repete o resultado", 0, 10 ** 6, 1)
    airfoil_dir: str = F("data/airfoils", "pasta de perfis", "", "os .dat desta pasta entram na lista de perfis "
                         "(polar do NeuralFoil no Re da asa); caminho relativo: à raiz do programa")
    m_max: float = F(30.0, "massa máxima na busca", "kg", "teto da busca do MTOW", 1, 200, 1)
    penalty: float = F(10.0, "penalidade", "", "pontuação perdida por violação relativa das restrições", 0, 1000, 0.5)
    tail_area_frac: float = F(0.25, "empenagem / asa (área)", "", "fração usada na massa e no arrasto", 0, 1, 0.01)
    fuselage_CDS: float = F(0.012, "C_D·S da fuselagem e trem", "m²", "", 0, 0.2, 0.001)


@dataclass
class MdoRun:
    """um resultado guardado no projeto (dados de simulação): os indivíduos e o melhor"""
    params: MdoParams = field(default_factory=MdoParams)
    names: dict = field(default_factory=dict)        # listas usadas: airfoils, sets (motor | hélice)
    rows: list = field(default_factory=list)


# o que cada arranjo muda nas contas do núcleo (LayoutData): motores aceitos, instalação, naceles, suporte
LAYOUT_DATA = {
    LAYOUTS[0]: dict(n_min=1, n_max=1, n_step=1, thrust_factor=1.0, nacelle_CDS=0.0, mass_per_motor=0.0),
    LAYOUTS[1]: dict(n_min=2, n_max=8, n_step=2, thrust_factor=1.0, nacelle_CDS=0.004, mass_per_motor=0.12),
    LAYOUTS[2]: dict(n_min=1, n_max=1, n_step=1, thrust_factor=0.9, nacelle_CDS=0.0, mass_per_motor=0.05),
}
MAX_LIST = 64          # limite do núcleo (max_airfoils, max_sets)


def _root_dir() -> str:
    import os
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def airfoil_catalog(project, mp: MdoParams | None = None) -> dict:
    """nome → AirfoilEntry: os perfis do projeto e os .dat da pasta de perfis (estes com polar do NeuralFoil)"""
    import os
    mp = mp or project.mdo
    out = dict(project.airfoil_map())
    d = mp.airfoil_dir if os.path.isabs(mp.airfoil_dir) else os.path.join(_root_dir(), mp.airfoil_dir)
    if os.path.isdir(d):
        try:
            import neuralfoil  # noqa: F401
            src = "neuralfoil"
        except ImportError:
            src = "modelo"
        for f in sorted(os.listdir(d)):
            if f.lower().endswith(".dat"):
                try:
                    e = afm.entry(afm.from_dat(os.path.join(d, f)))
                except Exception:
                    continue
                e.source = src
                out.setdefault(e.name, e)
    return out


def available(project, key: str, catalog=None) -> list[str]:
    """tudo o que uma variável de lista pode escolher (o seletor da planilha)"""
    cat = catalog or builtin_catalog()
    if key in ("wing.airfoil", "wing.airfoil_tip"):
        return list(airfoil_catalog(project))
    if key == "power.motor":
        return [m.name for m in cat.motors]
    if key == "power.propeller":
        return [p.name for p in cat.propellers]
    if key == "power.layout":
        return list(LAYOUTS)
    return []


def _options(project, key: str, current, catalog=None) -> list:
    """opções de uma variável de lista: as marcadas; variável sem nada marcado = todas; fixa = só a atual"""
    v = next((v for v in project.variables if v.key == key), None)
    if v is not None and v.mode == "variável":
        return list(dict.fromkeys(v.options)) or available(project, key, catalog)
    return [current]


def _range(project, key: str) -> tuple[float, float]:
    v = next((v for v in project.variables if v.key == key), None)
    cur = float(rg.get_input(project, key))
    if v is not None and v.mode == "variável":
        return min(v.lo, v.hi), max(v.lo, v.hi)
    return cur, cur


def airfoil_data(entry: afm.AirfoilEntry, Re: float) -> dict:
    """os números 2D do perfil (ajustados na polar, como a etapa Asa usa)"""
    try:
        m = afm.metrics(afm.polar(entry, Re))
    except Exception:
        m = {}
    a = afm.fitted(entry.airfoil, afm.polar(entry, Re)) if m else entry.airfoil
    return dict(cla=a.cl_alpha, a0_deg=a.zero_lift_angle(), clmax=a.cl_max, cd0=a.cd0, cm=a.moment_ac())


def build(project, mp: MdoParams | None = None, catalog=None, backend=None) -> tuple[dict, dict]:
    """(configuração do núcleo, nomes das listas)"""
    from aerosim.backend.zig.translator import prop_native
    mp = mp or project.mdo
    cat = catalog or builtin_catalog()
    req, wd, pd = project.requirements, project.wing_draft, project.power_draft
    # perfis (raiz e ponta escolhem na mesma lista: primeiro os da raiz)
    skipped = []
    amap = airfoil_catalog(project, mp)
    root = [n for n in _options(project, "wing.airfoil", wd.airfoil, cat) if n in amap] or \
        [wd.airfoil if wd.airfoil in amap else next(iter(amap))]
    names = list(root)
    tip_var = tip_varies(project)
    if tip_var:
        names += [n for n in _options(project, "wing.airfoil_tip", wd.airfoil_tip or wd.airfoil, cat)
                  if n in amap and n not in names]
    if len(names) > MAX_LIST:
        skipped.append(f"perfis além dos {MAX_LIST} primeiros")
        names, root = names[:MAX_LIST], root[:MAX_LIST]
    Re = req.reynolds(max(wd.area / max(wd.span, 0.1), 0.05))
    afs = [airfoil_data(amap[n], Re) for n in names]
    # conjuntos de tração: motor × hélice (a bateria do rascunho)
    find = lambda lst, n: next((x for x in lst if x.name == n), None)
    motors = [m for m in _options(project, "power.motor", pd.motor, cat) if find(cat.motors, m)] or [cat.motors[0].name]
    props = [p for p in _options(project, "power.propeller", pd.propeller, cat) if find(cat.propellers, p)] or \
        [cat.propellers[0].name]
    bat = find(cat.batteries, pd.battery) or cat.batteries[0]
    sets, set_names = [], []
    for mo, pr in itertools.product(motors, props):
        m, p = find(cat.motors, mo), find(cat.propellers, pr)
        if m is None or p is None:
            continue
        u = PropulsionUnit(motor=copy.deepcopy(m), propeller=copy.deepcopy(p), battery=copy.deepcopy(bat), tilt=0.0)
        sets.append(dict(unit=prop_native(u), mass=m.mass + p.mass + bat.mass, P_max=m.Imax * bat.Voc))
        set_names.append(f"{mo} | {pr}")
    if len(sets) > MAX_LIST:
        skipped.append(f"conjuntos motor × hélice além dos {MAX_LIST} primeiros")
    sets, set_names = sets[:MAX_LIST], set_names[:MAX_LIST]
    # arranjos dos motores
    lays = [l for l in _options(project, "power.layout", pd.layout, cat) if l in LAYOUT_DATA] or [LAYOUTS[0]]
    # variáveis
    def cont(key):
        lo, hi = _range(project, key)
        return dict(lo=lo, hi=hi, kind=0)
    if not tip_var and wd.airfoil_tip and wd.airfoil_tip in amap and wd.airfoil_tip not in names:
        names.append(wd.airfoil_tip)                       # ponta fixa com outro perfil
    tip_fixed = bool(wd.airfoil_tip) and wd.airfoil_tip in names and wd.airfoil_tip != wd.airfoil
    tip_idx = names.index(wd.airfoil_tip) if wd.airfoil_tip in names else 0
    mlo, mhi = _range(project, "power.motors")
    vars_ = [cont("wing.span"), cont("wing.area"), cont("wing.taper"),
             dict(lo=0, hi=len(root) - 1, kind=2),
             dict(lo=0, hi=len(sets) - 1, kind=2),
             dict(lo=mlo, hi=mhi, kind=1),
             cont("power.tilt"),
             dict(lo=0, hi=len(names) - 1, kind=2) if tip_var else dict(lo=tip_idx, hi=tip_idx, kind=2),
             dict(lo=0, hi=len(lays) - 1, kind=2)]
    # restrições ativas que o dimensionamento inicial calcula
    qn = (backend.sizing_names()["quantities"] if backend is not None else
          ["S", "b", "AR", "V_S", "n_surf", "P_motor", "n_motor", "s_to", "V_max", "RC", "TW", "mass", "pv", "cp",
           "ee", "mtow", "V_LD", "LD", "c_root"])
    cons = []
    for c in req.constraints:
        if not c.active:
            continue
        if c.key in qn:
            cons.append(dict(q=qn.index(c.key), op=rg.OPS.index(c.op), value=c.value, tol=c.tol))
        else:
            skipped.append(c.text())
    cfg = dict(kind=KINDS.index(mp.kind), objective=OBJECTIVES.index(mp.objective), rho=req.rho, mu=req.mu_roll,
               m_max=mp.m_max, tail_area_frac=mp.tail_area_frac, fuselage_CDS=mp.fuselage_CDS,
               wing_density=project.rules.wing_density, tail_density=project.rules.tail_density,
               fuselage_mass=project.rules.fuselage_density * 0.8, systems_mass=project.rules.systems_mass,
               gear_mass=project.rules.gear_mass, vars=vars_, airfoils=afs, n_airfoils=len(afs), sets=sets,
               n_sets=len(sets), cons=cons[:24], n_cons=min(len(cons), 24), tip_same=0 if (tip_var or tip_fixed) else 1,
               layouts=[LAYOUT_DATA[l] for l in lays], n_layouts=len(lays))
    bounds = {k: (v["lo"], v["hi"]) for k, v in zip(("span", "area", "taper"), vars_[:3])}
    bounds.update(tilt=(vars_[6]["lo"], vars_[6]["hi"]), motors=(mlo, mhi))
    return cfg, dict(airfoils=names, sets=set_names, layouts=lays, quantities=qn, skipped=skipped, bounds=bounds)


def tip_varies(project) -> bool:
    """o perfil da ponta entra na busca (variável 'perfil da ponta' marcada como variável)"""
    v = next((v for v in project.variables if v.key == "wing.airfoil_tip"), None)
    return v is not None and v.mode == "variável"


BOUND_LABELS = {"span": "envergadura", "area": "área", "taper": "afilamento", "tilt": "inclinação do motor",
                "motors": "nº de motores"}


def at_bounds(row: dict, bounds: dict, tol: float = 1e-3) -> list[str]:
    """as variáveis contínuas encostadas no limite (por que a asa parou de mudar)"""
    out = []
    for k, (lo, hi) in bounds.items():
        if hi - lo <= 1e-12 or k not in row:
            continue
        span = hi - lo
        if row[k] >= hi - tol * span:
            out.append(f"{BOUND_LABELS.get(k, k)} (máx. {hi:g})")
        elif row[k] <= lo + tol * span:
            out.append(f"{BOUND_LABELS.get(k, k)} (mín. {lo:g})")
    return out


def opts_of(mp: MdoParams) -> dict:
    return dict(method=METHODS.index(mp.method), particles=mp.particles, iterations=mp.iterations, seed=mp.seed,
                penalty=mp.penalty)


def decode(row, names: dict) -> dict:
    """um indivíduo do núcleo (linha do array) como dicionário legível"""
    x = [float(v) for v in row["x"]]
    sets = names["sets"]
    s = sets[int(round(x[4]))] if sets else " | "
    mo, _, pr = s.partition(" | ")
    af = names["airfoils"]
    return dict(iter=int(row["iter"]), particle=int(row["particle"]), feasible=bool(row["feasible"]),
                score=float(row["score"]), fitness=float(row["fitness"]), violation=float(row["violation"]),
                mtow=float(row["mtow"]), ee=float(row["ee"]), pv=float(row["pv"]), span=x[0], area=x[1], taper=x[2],
                airfoil=af[int(round(x[3]))], airfoil_tip=af[int(round(x[7]))], motor=mo, propeller=pr,
                motors=int(round(x[5])), tilt=x[6], layout=names.get("layouts", [LAYOUTS[0]])[int(round(x[8]))]
                if len(x) > 8 else LAYOUTS[0], x=x)


def history(rows: list[dict]) -> list[dict]:
    """o melhor até cada iteração (o slider do histórico): viável vence inviável; depois a aptidão"""
    out, best = [], None
    for it in sorted({r["iter"] for r in rows}):
        for r in (r for r in rows if r["iter"] == it):
            if best is None or (r["feasible"], r["fitness"]) > (best["feasible"], best["fitness"]):
                best = r
        out.append(dict(best, iter=it))
    return out


def run(project, catalog=None, backend=None, progress=None, cancel=None) -> tuple[list[dict], dict, dict]:
    """(indivíduos, melhor avaliação completa, nomes). `progress(iteração, indivíduos)` a cada iteração"""
    from aerosim.backend.zig import ZigBackend
    backend = backend or ZigBackend()
    cfg, names = build(project, project.mdo, catalog, backend)

    def prog(it, arr):
        if progress is not None:
            progress(it, [decode(r, names) for r in arr])
    arr, best = backend.sizing_optimize(cfg, opts_of(project.mdo), prog, cancel)
    return [decode(r, names) for r in arr], best, names


def evaluate(project, row: dict, catalog=None, backend=None) -> dict:
    """refaz um indivíduo inteiro (grandezas, curva de tração e arrasto no MTOW) — o clique no gráfico"""
    from aerosim.backend.zig import ZigBackend
    backend = backend or ZigBackend()
    cfg, names = build(project, project.mdo, catalog, backend)
    out = backend.sizing_eval(cfg, row["x"])
    q = dict(zip(names["quantities"], out["q"]))
    return dict(q=q, V=np.array(out["V"]), T=np.array(out["T"]), D=np.array(out["D"]), hover=bool(out["hover"]),
                feasible=bool(out["feasible"]), violation=out["violation"], skipped=names["skipped"],
                CD0=out["CD0"], K=out["K"], CLmax=out["CLmax"], CLg=out["CLg"], bounds=names["bounds"])


def apply(project, row: dict) -> None:
    """leva o indivíduo para os rascunhos das etapas (Asa, Motores e montagem)"""
    wd, pd = project.wing_draft, project.power_draft
    cat = airfoil_catalog(project)
    for n in {row["airfoil"], row["airfoil_tip"]}:          # perfil da pasta: entra nos perfis do projeto
        if project.airfoil(n) is None and n in cat:
            project.airfoils.append(copy.deepcopy(cat[n]))
    wd.span, wd.area, wd.taper = round(row["span"], 3), round(row["area"], 3), round(row["taper"], 3)
    wd.airfoil = row["airfoil"]
    wd.airfoil_tip = row["airfoil_tip"] if row["airfoil_tip"] != row["airfoil"] else ""
    pd.motor, pd.propeller, pd.tilt = row["motor"], row["propeller"], round(row["tilt"], 2)
    pd.layout = row.get("layout", LAYOUTS[0])
    if pd.layout == LAYOUTS[1]:
        pd.wing_motors = max(2, int(row["motors"]) // 2 * 2)


def planform(row: dict, wings: int = 1) -> dict:
    """contorno da asa do indivíduo (para o histórico): meia asa trapezoidal, raiz e ponta"""
    b, S, lam = row["span"], row["area"] / max(wings, 1), max(row["taper"], 0.05)
    cr = 2 * S / (b * (1 + lam))
    ct = lam * cr
    s = b / 2
    x = [0.0, s, s, 0.0, -s, -s, 0.0]
    y = [0.0, -(cr - ct) / 4, -(cr - ct) / 4 - ct, -cr, -(cr - ct) / 4 - ct, -(cr - ct) / 4, 0.0]
    return dict(x=np.array(x), y=np.array(y), cr=cr, ct=ct)


def sketch(project, row: dict, catalog=None):
    """o indivíduo como avião para ver em 3D (asa(s) com os perfis dele, empenagem pela fração, motores)"""
    from aerosim.model.aircraft import Fuselage, LiftingSurface, rect_sections
    from aerosim.model.templates import empty
    from . import wing as wg
    mp = project.mdo
    amap = airfoil_catalog(project)
    cat = catalog or builtin_catalog()
    ac = empty()
    ac.name = f"MDO it {row['iter']}"
    wp = wg.WingParams(span=row["span"], area=row["area"] / (2 if mp.kind == "biplano" else 1), taper=row["taper"],
                       rect_frac=0.0)
    af = amap[row["airfoil"]].airfoil if row["airfoil"] in amap else project.airfoils[0].airfoil
    tip = amap[row["airfoil_tip"]].airfoil if row["airfoil_tip"] in amap and \
        row["airfoil_tip"] != row["airfoil"] else None
    zs = (-0.15, 0.15) if mp.kind == "biplano" else (0.0,)
    for k, z in enumerate(zs):
        w = wg.build_wing(wp, af, af_tip=tip)
        w.name, w.z, w.x = f"asa {k + 1}", z - 0.05, 0.1 + 0.05 * k
        ac.surfaces.append(w)
    c = row["area"] / row["span"]
    tail = mp.kind in ("monoplano", "biplano", "VTOL")
    if tail:
        Sh = mp.tail_area_frac * row["area"] * 0.7
        bh = math.sqrt(Sh * 4)
        ac.surfaces.append(LiftingSurface(name="EH", role="htail", x=-2.5 * c - 0.3, sections=rect_sections(bh / 2, Sh / bh)))
        Sv = mp.tail_area_frac * row["area"] * 0.3
        hv = math.sqrt(Sv * 1.5)
        ac.surfaces.append(LiftingSurface(name="EV", role="vtail", x=-2.5 * c - 0.3, vertical=True, symmetric=False,
                                          sections=rect_sections(hv, Sv / hv)))
    ac.fuselage = Fuselage(enabled=True, x_nose=0.45, length=0.9 if tail else 0.5, width=0.12, height=0.14)
    find = lambda lst, n: next((x for x in lst if x.name == n), None)
    n = row["motors"]
    lay = row.get("layout", LAYOUTS[0])
    for i in range(n):
        if lay == LAYOUTS[1]:                              # na asa, aos pares de dentro para fora
            k, side = i // 2, (1 if i % 2 else -1)
            x, y = 0.3, side * (0.25 + k * 0.45)
        elif lay == LAYOUTS[2]:                            # propulsora atrás da asa
            x, y = -c - 0.05, 0.0
        else:
            x, y = 0.55, 0.0
        ac.propulsion.append(PropulsionUnit(name=f"motor {i + 1}", x=x, y=y, z=0.0,
                                            tilt=90.0 if mp.kind == "tailsitter" else row["tilt"],
                                            motor=copy.deepcopy(find(cat.motors, row["motor"]) or cat.motors[0]),
                                            propeller=copy.deepcopy(find(cat.propellers, row["propeller"]) or
                                                                    cat.propellers[0])))
    ac.apply_constraints()
    return ac


def check_6dof(project, row: dict, catalog=None, manager=None, backend=None) -> dict:
    """leva o indivíduo para as etapas (guarda asa, conjunto e avião), fecha o ponto de projeto e confere o
    MTOW no 6GDL — o que o dimensionamento inicial promete, medido no simulador"""
    from . import power as pw
    from . import study as sd
    apply(project, row)
    w = project.keep_wing()
    project.tail_draft.wing = w.name
    s = project.keep_set()
    project.power_draft.set = s.name
    a = project.keep_aircraft()
    d = pw.design_point(a, project.requirements, project.rules, catalog, project.airfoil_map(), backend)
    out = dict(aircraft=a.name, mtow_point=float(d["mtow"]), mtow6=float("nan"))
    if manager is not None:
        out["mtow6"] = sd._mtow6(d["cand"], d["req"], project.rules, catalog, project.airfoil_map(), manager)
    return out


# ------------------------------------------------------------------ o indivíduo por inteiro
G0 = 9.80665

# velocidades do envelope completo: (chave do resumo do núcleo, rótulo)
SPEEDS = (("Vs", "V_S (estol)"), ("Vmin", "V mín. (tração = arrasto)"), ("Vmax", "V máx."),
          ("V_RCmax", "V de subida máxima (V_y)"), ("V_gmax", "V de maior ângulo de subida (V_x)"),
          ("V_LDmax", "V de L/D máx. (maior alcance)"), ("V_sink_min", "V de menor afundamento (mín. potência)"),
          ("Vman", "V de manobra (V*)"), ("V_Rmin", "V de menor raio de curva"))


def full_envelope(project, row: dict, ev: dict | None = None, catalog=None, backend=None) -> dict:
    """o envelope completo do indivíduo no MTOW (o desempenho do núcleo, o mesmo da aba Desempenho): por V,
    tração disponível × requerida, potências, subida, planeio, curva e bateria; e todas as velocidades"""
    from aerosim.backend.zig import ZigBackend
    backend = backend or ZigBackend()
    ev = ev or evaluate(project, row, catalog, backend)
    q, req = ev["q"], project.requirements
    cat = catalog or builtin_catalog()
    bat = next((b for b in cat.batteries if b.name == project.power_draft.battery), cat.batteries[0])
    V, T = np.asarray(ev["V"], float), np.asarray(ev["T"], float)
    cfg = dict(W=q["mtow"] * G0, S=q["S"], CD0=ev["CD0"], K=ev["K"], CLmax=ev["CLmax"], rho0=req.rho, h=0.0,
               phi_T=math.radians(row.get("tilt", 0.0)), rho_exp=0.0, V_lo=1.0, V_hi=float(V[-1]), dV=0.5,
               n_load=2.0, bat_C=bat.capacity_mAh / 1000 * max(row.get("motors", 1), 1), bat_V=bat.Voc,
               thr_V=list(V), thr_T=list(T))
    rows, summ = backend.simple_performance(cfg)
    return dict(rows=rows, summary=summ, polar=dict(CD0=ev["CD0"], K=ev["K"], CLmax=ev["CLmax"], CLg=ev["CLg"]))


DIAGRAM_KINDS = ("estol", "decolagem", "subida", "cruzeiro", "vmax", "curva", "teto")


def constraint_diagram(project, row: dict, ev: dict, env: dict, kinds=DIAGRAM_KINDS, n: int = 120) -> dict:
    """diagrama de restrições (T/W × W/S) com a polar e as velocidades do indivíduo e as restrições do projeto.
    Hélice: cada curva vira T/W estático equivalente, pela queda da tração do indivíduo até a velocidade da
    condição (T(V)/T0 da curva dele)"""
    from aerosim.sizing import constraints as sc
    from . import registry as rg
    q, req, s = ev["q"], project.requirements, env["summary"]
    cs = req.constraints
    lim = lambda key, op, d: (rg.active(cs, key, op).value if rg.active(cs, key, op) else d)
    r = sc.Requirements(rho=req.rho, V_stall=lim("V_S", "≤", q["V_S"]), S_G=lim("s_to", "≤", max(q["s_to"], 1.0)),
                        V_cruise=req.V_cruise, V_max=lim("V_max", "≥", 0.0), V_climb=s.get("V_RCmax") or req.V_cruise,
                        roc=lim("RC", "≥", 1.0), n_turn=2.0, V_turn=s.get("Vman") or 1.4 * q["V_S"],
                        h_ceiling=0.0)
    p = env["polar"]
    a = sc.ParabolicPolar(CD0=p["CD0"], k=p["K"], CLmax=p["CLmax"], CL_TO=p["CLg"],
                          CD_TO=p["CD0"] + p["K"] * p["CLg"] ** 2, mu=req.mu_roll)
    ws_pt = q["mtow"] * G0 / q["S"]
    ws = np.linspace(max(0.2 * ws_pt, 5.0), 2.5 * ws_pt, n)
    V, T = np.asarray(ev["V"], float), np.asarray(ev["T"], float)
    T0 = max(float(T[0]), 1e-9)
    lapse = lambda Vc: np.maximum(np.interp(Vc, V, T), 1e-6 * T0) / T0     # T(V)/T0 da hélice do indivíduo
    curves = {"ws": ws}
    for k in kinds:
        if k == "estol":
            continue
        if k == "vmax" and r.V_max <= 0:
            continue
        if k == "teto" and r.h_ceiling <= 0:
            continue
        tw = sc.required_tw(k, ws, r, a)
        Vc = np.array([sc.condition_speed(k, w, r, a) for w in ws])
        curves[k] = tw / lapse(Vc)
    limits = {}
    if "estol" in kinds:
        limits["estol"] = sc.stall_ws(r, a)
    return dict(curves=curves, limits=limits, point=(ws_pt, T0 / (q["mtow"] * G0)), labels=dict(sc.KINDS + sc.LIMITS))

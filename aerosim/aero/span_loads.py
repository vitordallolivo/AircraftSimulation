"""Carga aerodinâmica ao longo de cada superfície num ponto de operação: velocidade, α, β, comandos e a rotação de
cada motor (ou o acelerador). É a "análise de cargas" da aerodinâmica: sustentação e arrasto por metro de envergadura,
α e velocidade locais e, para ver em 3D, os vetores de força e de velocidade de cada faixa.

Quem calcula é o núcleo (o mesmo laço da simulação, `aero.computeTrace`, com os modificadores do avião: efeito
solo, esteira da hélice...); aqui só se monta o caso, refina a geometria para ter resolução e organiza a saída.

    from aerosim.aero.span_loads import LoadCase, compute
    r = compute(backend, ac, LoadCase(V=12))              # voo nivelado a 12 m/s: α, profundor e acelerador da trimagem
    r = compute(backend, ac, LoadCase(V=12, n=2))         # curva com fator de carga 2 (o avião inteiro "pesa" 2×)
    r = compute(backend, ac, LoadCase(V=8, alpha=2, rpm=6000))   # α e rotação impostos
    w = r.surface("asa")          # SurfaceLoad: w.s (m), w.L (N/m), w.alpha (°), w.V (m/s), w.points, w.force...
    r.props                       # PropState de cada motor: rpm, T, Q, J, eixo e cubo
    r.tubes(backend)              # contorno da esteira de cada motor (para desenhar em 3D), pela sonda do núcleo

Resolução: cada superfície é refinada (mais seções na mesma geometria: corda, recuo e torção interpolados) até o
limite de painéis do núcleo, uma superfície por vez. Superfícies com perfil próprio por seção e dispositivos de ponta
não são refinados (saem com as faixas que já têm).

Coordenada ao longo da superfície (`s`): y (m, + direita) nas horizontais, altura −z (m, + para cima) nas verticais.
"""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field

import numpy as np

MAX_PER_SIDE = 40


@dataclass
class LoadCase:
    V: float = 12.0                    # velocidade do ar (m/s)
    alpha: float | None = None         # α do corpo (°); None: o do voo nivelado (ou curva com `n`) nessa velocidade
    n: float = 1.0                     # fator de carga da trimagem (1: nivelado; > 1: curva coordenada)
    beta: float = 0.0                  # β (°)
    rpm: float | list[float] | None = None   # rotação de cada motor (um valor para todos ou um por motor); None: equilíbrio
    throttle: float = 1.0              # acelerador, quando a rotação não é imposta
    de: float | None = None            # profundor (°); None: o da trimagem (com α imposto: 0)
    da: float = 0.0
    dr: float = 0.0
    refine: bool = True


@dataclass
class SurfaceLoad:
    name: str
    role: str
    vertical: bool
    s: np.ndarray                      # posição ao longo da superfície (m)
    width: np.ndarray                  # largura de cada faixa ao longo da superfície (m)
    chord: np.ndarray                  # m
    alpha: np.ndarray                  # α local (°), com downwash, comando e modificadores
    V: np.ndarray                      # velocidade local no plano do perfil (m/s)
    q: np.ndarray                      # pressão dinâmica local (Pa)
    cl: np.ndarray
    cd: np.ndarray
    L: np.ndarray                      # sustentação por metro (N/m)
    D: np.ndarray                      # arrasto por metro (N/m)
    points: np.ndarray                 # (n, 3) centro de cada faixa (corpo, m)
    force: np.ndarray                  # (n, 3) força da faixa (corpo, N)
    velocity: np.ndarray               # (n, 3) velocidade da faixa em relação ao ar (corpo, m/s)
    induced: np.ndarray                # (n, 3) parte dos modificadores em `velocity`
    span_dir: np.ndarray               # (n, 3) direção da envergadura de cada faixa

    @property
    def lift(self) -> float:
        return float(np.sum(self.L * self.width))

    @property
    def drag(self) -> float:
        return float(np.sum(self.D * self.width))


@dataclass
class PropState:
    name: str
    index: int
    hub: np.ndarray                    # cubo (corpo, m)
    axis: np.ndarray                   # eixo de tração (corpo)
    D: float
    sense: int
    rpm: float
    J: float
    T: float
    Q: float
    P_shaft: float
    V_axis: float


@dataclass
class SpanLoads:
    case: LoadCase
    surfaces: list[SurfaceLoad] = field(default_factory=list)
    props: list[PropState] = field(default_factory=list)
    modifiers: list[str] = field(default_factory=list)
    rho: float = 1.225
    alpha: float = 0.0                 # α usado (°)
    de: float = 0.0                    # profundor usado (°)
    weight: float = 0.0                # peso do avião (N)
    trim: dict | None = None           # a trimagem do núcleo, se o α veio dela (ok, alpha, de, thr, n...)
    notes: list[str] = field(default_factory=list)

    def surface(self, name: str) -> SurfaceLoad:
        return next(s for s in self.surfaces if s.name == name)

    def by_role(self, role: str) -> list[SurfaceLoad]:
        return [s for s in self.surfaces if s.role == role]

    @property
    def lift(self) -> float:
        return sum(s.lift for s in self.surfaces)

    def tubes(self, backend, x_max: float = 1.5, n: int = 40) -> list[dict]:
        """contorno da esteira de cada motor para desenhar (pela sonda do núcleo): pontos do eixo (corpo) e o raio do
        tubo em cada um. Só faz sentido com o modificador de esteira ligado; sem tração, raio = o da hélice"""
        out = []
        xs = np.linspace(0.0, x_max, n)
        for p in self.props:
            o = backend.probe_slipstream(p.T, p.Q, p.D, max(p.V_axis, 0.0), self.rho, p.sense,
                                         np.column_stack([-xs, np.zeros(n), np.zeros(n)]))
            out.append(dict(name=p.name, centers=p.hub[None, :] - xs[:, None] * p.axis[None, :], radius=o[:, 3],
                            axial=o[:, 0]))
        return out


def _rpm_list(case: LoadCase, n: int) -> list[float | None]:
    if case.rpm is None:
        return [None] * n
    if np.ndim(case.rpm) == 0:
        return [float(case.rpm)] * n
    r = list(case.rpm)
    if len(r) != n:
        raise ValueError(f"rpm: {len(r)} valores para {n} motores")
    return [float(x) if x else None for x in r]


def refine_surface(ac, index: int, per_side: int):
    """cópia do avião com a superfície `index` em `per_side` faixas (mesma geometria)"""
    from aerosim.model.aircraft import WingSection
    a = copy.deepcopy(ac)
    s = a.surfaces[index]
    if len(s.sections) < 2 or any(q.airfoil is not None for q in s.sections):
        return a
    ss = sorted(s.sections, key=lambda q: q.y)
    ys = []
    for y in sorted(np.r_[np.linspace(ss[0].y, ss[-1].y, per_side + 1), [q.y for q in ss]]):
        if not ys or y - ys[-1] > 1e-9:                     # as seções originais ficam exatas
            ys.append(float(y))
        elif any(abs(y - q.y) < 1e-12 for q in ss):
            ys[-1] = float(y)
    f = lambda k: np.interp(ys, [q.y for q in ss], [getattr(q, k) for q in ss])
    s.sections = [WingSection(y, c, x, t) for y, c, x, t in zip(ys, f("chord"), f("x_offset"), f("twist"))]
    return a


def _fit(ac, index: int, limit: int):
    """a maior divisão da superfície que cabe no limite de painéis do núcleo"""
    from aerosim.backend.zig.translator import native_spec
    lo, hi, best = 1, MAX_PER_SIDE, ac
    while lo <= hi:                                   # busca binária no número de faixas por lado
        mid = (lo + hi) // 2
        a = refine_surface(ac, index, mid)
        if len(native_spec(a)["surf"]) <= limit:
            best, lo = a, mid + 1
        else:
            hi = mid - 1
    return best


def _props(session, ac, model, case: LoadCase) -> list[PropState]:
    units = [u for u in ac.propulsion if u.enabled]
    out = []
    a, b = math.radians(case.alpha), math.radians(case.beta)
    for i, (u, rpm) in enumerate(zip(units, _rpm_list(case, len(units)))):
        st = session.prop_state(i, case.V, a, b, rpm=rpm, thr=case.throttle)
        tilt, toe = math.radians(u.tilt), math.radians(u.toe)
        axis = np.array([math.cos(tilt) * math.cos(toe), math.cos(tilt) * math.sin(toe), -math.sin(tilt)])
        out.append(PropState(u.name, i, np.array([u.x, u.y, u.z], float), axis, u.propeller.D, int(u.sense),
                             st["rpm"], st["J"], st["T"], st["Q"], st["P_shaft"], st["V"]))
    return out


def _collect(P: np.ndarray, rows: list[int], sm, rho: float) -> SurfaceLoad:
    """as faixas `rows` (da mesma superfície) em ordem ao longo da envergadura"""
    Q = P[rows]
    pts = np.asarray(Q["r"], float)
    vertical = bool(sm.vertical)
    s = -pts[:, 2] if vertical else pts[:, 1]
    o = np.argsort(s)
    Q, pts, s = Q[o], pts[o], s[o]
    width = np.asarray(Q["S"], float) / np.maximum(np.asarray(Q["c"], float), 1e-12)
    V = np.asarray(Q["V"], float)
    return SurfaceLoad(name=sm.name, role=sm.role, vertical=vertical, s=s, width=width, chord=np.asarray(Q["c"], float),
                       alpha=np.degrees(np.asarray(Q["alpha"], float)), V=V, q=0.5 * rho * V * V,
                       cl=np.asarray(Q["CL"], float), cd=np.asarray(Q["CD"], float),
                       L=np.asarray(Q["L"], float) / width, D=np.asarray(Q["D"], float) / width, points=pts,
                       force=np.asarray(Q["F"], float), velocity=np.asarray(Q["v"], float),
                       induced=np.asarray(Q["vind"], float), span_dir=np.asarray(Q["ey"], float))


def compute(backend, ac, case: LoadCase | None = None) -> SpanLoads:
    """a carga de cada superfície do avião `ac` no caso `case` (com os modificadores do avião)"""
    from aerosim.backend.zig.translator import panel_owners
    from aerosim.model import modifiers as mods
    from aerosim.model.universal import build_model
    from aerosim.interfaces.backend import TrimKind
    case = case or LoadCase()
    limit = backend.schema.limits["surfaces"]
    rho = ac.environment.rho
    base = build_model(ac)
    notes, trim = [], None
    with backend.session_for(base) as s:
        weight = float(s.mass_props()["m"]) * 9.80665
        run = copy.copy(case)
        if case.alpha is None:
            trim = s.trim(TrimKind.LEVEL if abs(case.n - 1.0) < 1e-9 else TrimKind.TURN, case.V, case.n)
            if not trim["ok"]:
                notes.append(f"a trimagem a {case.V:g} m/s não convergiu (fora do envelope?): usando o que ela achou")
            run.alpha = math.degrees(trim["alpha"])
            run.de = math.degrees(trim["de"]) if case.de is None else case.de
            if case.rpm is None:
                run.throttle = float(trim["thr"])
        elif case.de is None:
            run.de = 0.0
        props = _props(s, ac, base, run)
    a, b = math.radians(run.alpha), math.radians(run.beta)
    d = [math.radians(run.de), math.radians(run.da), math.radians(run.dr)]
    T, Q = [p.T for p in props], [p.Q for p in props]
    res = SpanLoads(case=case, props=props, modifiers=mods.describe(ac), rho=rho, alpha=run.alpha, de=run.de,
                    weight=weight, trim=trim, notes=notes)
    done = set()
    # cada superfície do avião refinada sozinha (os dispositivos de ponta saem com o avião sem refino)
    targets = [i for i, x in enumerate(ac.surfaces) if x.enabled] if case.refine else []
    jobs = [(i, _fit(ac, i, limit)) for i in targets] + [(None, ac)]
    for idx, a_ac in jobs:
        model = build_model(a_ac)
        owners = panel_owners(model)
        with backend.session_for(model) as s:
            P = s.panel_states(run.V, a, b, T, Q, *d)
        for k, sm in enumerate(model.surfaces):
            if sm.name in done:
                continue
            if idx is not None and sm.index != idx:      # desta rodada só vale a superfície refinada (e os dispositivos dela não)
                continue
            if idx is not None and sm.role == "device":
                continue
            rows = [j for j, (_, kk) in enumerate(owners) if kk == k and j < len(P) and P["group"][j] >= 0]
            if rows:
                res.surfaces.append(_collect(P, rows, sm, rho))
                done.add(sm.name)
    return res

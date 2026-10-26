"""Sensibilidade do melhor avião: o quanto a nota muda quando uma variável contínua livre sai do lugar.

O otimizador entrega um ponto, mas não diz se ele está no alto de um morro largo ou na beira de um precipício. Um
avião cuja nota cai pela metade com um centímetro a menos de envergadura é arriscado de construir, e uma variável que
quase não mexe na nota pode ser escolhida pelo que for mais fácil na oficina.

A análise é de um indivíduo só, o melhor, e fica dentro do problema: só as contínuas livres dele se mexem (a
configuração, as listas e as inteiras ficam como estão), cada uma dentro dos seus limites e no passo do campo, e um
ponto só conta se fecha com as restrições do problema e tem o mesmo voo válido (ou inválido) do melhor. Um ponto que
não fecha marca o lado em que a restrição está ativa. A nota de cada ponto é a da etapa da nota com a corrida na
pista, como na busca das superfícies.

Há três métodos (`METHODS`), escolhidos em `SensParams.method`:

- **modelo local** (o padrão): quase não roda nada. A busca das superfícies já avaliou vários pontos em volta do
  melhor e eles estão no histórico dele, com o MTOW, o PV e a bateria, então pontuá-los não custa ponto de projeto.
  Com as contínuas normalizadas $u_k = (x_k - x_{min})/(x_{max} - x_{min})$, um modelo passa por esses pontos com
  peso maior para os de perto e nenhum para os de longe (`ISimBackend.local_fit`, `core/src/optim/localfit.zig`):

  $$N(u) \\approx N_0 + g^T (u - u_0) + \\tfrac12 \\sum_k c_k (u_k - u_{0k})^2$$

  A inclinação $g_k$ diz para onde a nota sobe; a curvatura $c_k$ diz quanto se perde ao sair do ponto, o que a
  inclinação sozinha não conta no alto do morro, onde ela é zero. Só uma direção que o histórico não determina (menos
  de dois valores diferentes perto do melhor) ganha pontos novos, em $u_0 \\pm h$ (h = 10 % da faixa), e em
  $u_0 \\pm h/2$ se um lado não fecha.
- **um por vez**: o mesmo modelo só com pontos novos nos eixos ($u_0 \\pm h$), sem o histórico. Custa 2k pontos (k
  contínuas) e serve para conferir o modelo local.
- **Morris**: os efeitos elementares (`core/src/optim/sensmethods.zig`) em r trajetórias na caixa $u_0 \\pm h$, o
  que acusa curvatura e interação entre as variáveis numa região, e não só no ponto. Custa r(k + 1) pontos.

Os três terminam igual. Com a inclinação e a curvatura, a tolerância de fabricação (`tol`, uma fração do valor) vira
a nota perdida de cada lado e a dispersão da nota (`ISimBackend.sens_tolerance`), e a elasticidade
$(x/N)\\,\\partial N/\\partial x$ deixa comparar variáveis de unidades diferentes. Com `limits`, o melhor avião é
refeito com cada limite do problema (a pista e cada restrição ligada) um pouco mais apertado e mais folgado, e sai
$\\partial N/\\partial L$: quanto vale, em nota, meio metro a mais de pista.

    res = sensitivity(project, problem, best_row, evaluator, SensParams(method="morris", limits=True))
    for r in res["rows"]:                     # da que mais mexe na nota para a que menos mexe
        print(r["label"], r["slope"], r["minus"], r["plus"])
"""
from __future__ import annotations

import copy
import math
from dataclasses import asdict, dataclass

import numpy as np

from aerosim.interfaces.optim import OptProblem, StageItem

from . import inputs as inp
from . import stages as sg
from .problem import apply_to_project, fold_bounds

METHODS = {"local": "modelo local", "eixos": "um por vez", "morris": "Morris"}
R = 0.40                 # o raio do peso do modelo, em fração da faixa: mais longe que isso o ponto não conta
NEAR = R
EPS = 1e-4               # dois valores de u mais perto que isso são o mesmo


@dataclass
class SensParams:
    """o que a sensibilidade roda (o menu Configuração; vai no .opt.json em params["sensibilidade"])"""
    on: bool = True               # roda depois de cada melhor avião
    method: str = "local"         # uma chave de METHODS
    h: float = 0.10               # o passo, em fração da faixa
    tol: float = 0.01             # a tolerância de fabricação, em fração do valor
    trajectories: int = 6         # Morris: r
    levels: int = 4               # Morris: níveis da grade (par)
    limits: bool = False          # também a nota com cada limite do problema mudado
    limit_step: float = 0.05      # quanto cada limite muda, em fração do valor
    seed: int = 1

    KEYS = {"on": "ligada", "method": "método", "h": "passo", "tol": "tolerância", "trajectories": "trajetórias",
            "levels": "níveis", "limits": "limites", "limit_step": "passo_limites", "seed": "semente"}

    def to_dict(self) -> dict:
        return {self.KEYS[k]: v for k, v in asdict(self).items()}

    @classmethod
    def from_dict(cls, d: dict | None) -> "SensParams":
        d = d or {}
        back = {v: k for k, v in cls.KEYS.items()}
        return cls(**{back[k]: v for k, v in d.items() if k in back})


def label(key: str) -> str:
    i = inp.get(key)
    return f"{i.label} ({i.unit})" if i is not None and i.unit else (i.label if i is not None else key)


def free(problem: OptProblem) -> list[tuple[str, float, float, float]]:
    """as contínuas livres: (chave, mínimo, máximo, passo do campo)"""
    out = []
    for v in problem.free_variables():
        if v.kind == "contínua" and v.hi != v.lo:
            out.append((v.key, min(v.lo, v.hi), max(v.lo, v.hi), getattr(inp.get(v.key), "step", 0.0) or 0.0))
    return out


def snap(x: float, lo: float, hi: float, step: float) -> float:
    """o valor dentro dos limites e no passo do campo"""
    x = min(max(x, lo), hi)
    return round(round(x / step) * step if step > 0 else x, 9)


def limits(project, problem: OptProblem) -> list[tuple[str, str, str, float]]:
    """os limites do problema que a sensibilidade muda: (chave, nome, operador, valor). A pista e cada restrição
    ligada (a corrida e o MTOW não: quem os define é a pista)"""
    from aerosim.design import registry as rg
    out = [("pista", "pista (m)", "≤", float(project.requirements.takeoff_run))]
    for c in problem.constraints:
        if c.active and c.key not in ("s_to", "mtow"):
            q = rg.QUANTITIES.get(c.key)
            name = (f"{q.label} ({q.unit})" if q.unit else q.label) if q is not None else c.key
            out.append((c.key, name, c.op, float(c.value)))
    return out


def _point(job):
    """um ponto (vai para outro processo): a etapa das superfícies e os valores"""
    stage, values = job
    return stage.point(values)


class _Points:
    """os pontos de projeto em volta do melhor: os do histórico e os novos, cada um com a nota da etapa da nota"""

    def __init__(self, vars_, x0, values, surf, score, fixed, executor, cancel):
        self.vars, self.values, self.surf, self.score, self.fixed = vars_, values, surf, score, fixed
        self.executor, self.cancel = executor, cancel
        self.span = np.array([hi - lo for _, lo, hi, _ in vars_])
        self.los = np.array([lo for _, lo, _, _ in vars_])
        self.x0 = x0
        self.u0 = (x0 - self.los) / self.span
        self.pts: list[dict] = []
        self.by: dict[tuple, dict] = {}

    def key(self, x) -> tuple:
        return tuple(np.round((x - self.los) / self.span / EPS).astype(int))

    def add(self, x, d: dict, new: bool) -> dict:
        k = self.key(x)
        if k not in self.by:
            q = dict(x=np.asarray(x, float), u=(x - self.los) / self.span, ok=bool(d.get("ok")), why=d.get("why", ""),
                     new=new, data={**self.fixed, **{c: d.get(c, math.nan) for c in ("mtow", "pv", "m_bat", "b")}})
            self.by[k] = q
            self.pts.append(q)
        return self.by[k]

    def run(self, todo) -> None:
        """avalia os pontos que ainda não existem (em paralelo, se há executor) e dá a nota de todos"""
        todo = [x for x in {self.key(x): x for x in todo}.values() if self.key(x) not in self.by]
        if todo:
            ex = self.executor
            if ex is None:
                from aerosim.parallel import SerialExecutor
                ex = SerialExecutor()
            jobs = [(self.surf, {**self.values, **{k: float(x[i]) for i, (k, *_) in enumerate(self.vars)}})
                    for x in todo]
            for x, o in zip(todo, ex.map(_point, jobs, self.cancel)):
                self.add(x, o.value if o.ok else {"ok": False, "why": "cancelado" if o.cancelled else str(o.error)},
                         True)
        _score(self.score, self.pts)

    def at0(self, q: dict) -> bool:
        return float(np.max(np.abs(q["u"] - self.u0))) < EPS

    def on_axis(self, q: dict, k: int) -> bool:
        return float(np.max(np.abs(np.delete(q["u"] - self.u0, k)), initial=0.0)) < EPS


def _score(score, qs: list[dict]) -> None:
    todo = [q for q in qs if q["ok"] and "nota" not in q and all(math.isfinite(q["data"][k])
                                                                 for k in ("mtow", "pv", "m_bat", "b"))]
    items = [StageItem(name=str(i), data=dict(q["data"])) for i, q in enumerate(todo)]
    if items:
        score.run(items)
    for q, it in zip(todo, items):
        q["nota"], q["valido"] = float(it.data["nota"]), bool(it.data["valido"])
        q["formula"] = float(it.data.get("nota_formula", it.data["nota"]))


def sensitivity(project, problem: OptProblem, best: dict, evaluator, params: SensParams | None = None,
                executor=None, cancel=None, backend=None) -> dict:
    """a nota do melhor (`base`) e uma linha por contínua livre (`rows`, da que mais mexe para a que menos): a
    inclinação ∂N/∂x (`slope`) e a curvatura ∂²N/∂x² (`curv`; Morris dá também μ* e σ), a nota prevista em
    x₀ ∓ h·faixa (`minus`, `plus`, no limite do problema se ele vem antes), os lados em que o avião deixa de fechar
    (`blocked`), a tolerância (`tol_minus`, `tol_plus`, `elast`) e quantos pontos perto havia e quantos foram
    avaliados de novo. Com `params.limits`, `limits` tem a nota do melhor com cada limite do problema mudado. `best`
    é a linha do melhor, com `values` e `history`"""
    sp = params or SensParams()
    if sp.method not in METHODS:
        raise ValueError(f"método da sensibilidade desconhecido: {sp.method}")
    h = sp.h
    p, problem = copy.deepcopy(project), copy.deepcopy(problem)
    fold_bounds(problem, p)
    apply_to_project(problem, p)
    stages = {s.name: s for s in evaluator.stages(p, problem)}
    surf, score = stages["superfícies"], stages["nota"]
    vars_ = free(problem)
    values = dict(best["values"])
    if backend is None:
        from aerosim.backend.zig import ZigBackend
        backend = ZigBackend()
    _, cand = sg.candidate(p, values)
    fixed = dict(s_to=float(p.requirements.takeoff_run), lapes=bool(cand.params.lapes),
                 liquid=bool(cand.params.liquid))
    x0 = np.array([float(values.get(k, sg.get_value(p, k))) for k, *_ in vars_])
    P = _Points(vars_, x0, values, surf, score, fixed, executor, cancel)
    hist = best.get("history", []) if vars_ else []
    for e in hist:
        x = np.array([float(e["values"].get(k, x0[i])) for i, (k, *_) in enumerate(vars_)])
        if sp.method == "local" or P.at0(dict(u=(x - P.los) / P.span)):   # os outros métodos: só o melhor ponto
            P.add(x, e, False)
    if not any(P.at0(q) for q in P.pts):              # o melhor ponto sem histórico (uma linha antiga)
        P.run([x0])
    _score(score, P.pts)
    base = next((q for q in P.pts if P.at0(q)), None)
    valid0 = bool(base and base.get("valido"))
    resp = "nota" if valid0 else "formula"             # o melhor voa inválido: a nota da fórmula, antes do zero
    n0 = base[resp] if base is not None and "nota" in base else math.nan

    def usable(q: dict) -> bool:
        return q["ok"] and "nota" in q and q["valido"] == valid0

    out = dict(base=dict(nota=float(n0), valido=valid0, ok=bool(base and base["ok"]), response=resp),
               method=sp.method, h=h, r=R, quad=False, rms=math.nan, sigma=math.nan, tol=sp.tol, rows=[],
               history=len(hist), limits=[])
    if vars_:
        rows = (_morris if sp.method == "morris" else _local)(P, sp, usable, resp, n0, backend, out)
        g = np.array([r["slope"] for r in rows])
        c = np.array([r["curv"] for r in rows])
        delta = np.array([sp.tol * abs(x) for x in x0])
        mi, pl, el, sig = backend.sens_tolerance(g, c, x0, n0, delta)
        for k, r in enumerate(rows):
            r.update(tol_delta=float(delta[k]), tol_minus=float(mi[k]), tol_plus=float(pl[k]), elast=float(el[k]))
            d = [abs(r[s] - n0) for s in ("minus", "plus") if math.isfinite(r[s])]
            r["swing"] = max(d) if d else math.nan
        out["sigma"] = sig
        out["rows"] = sorted(rows, key=lambda r: -r["swing"] if math.isfinite(r["swing"]) else math.inf)
    out["used"] = sum(1 for q in P.pts if usable(q))
    if sp.limits:
        out["limits"] = _limits(project, problem, evaluator, values, sp, n0, resp, valid0, executor, cancel)
    out["new"] = sum(1 for q in P.pts if q["new"]) + sum(lm["new"] for lm in out["limits"])
    return out


def _row(P: _Points, k: int, h: float, slope_u: float, curv_u: float, quad: bool, n0: float) -> dict:
    """a linha de uma variável a partir da inclinação e da curvatura em u"""
    key, lo, hi, _ = P.vars[k]
    t_lo, t_hi = min(h, P.u0[k]), min(h, 1 - P.u0[k])    # até onde dá para ir sem sair dos limites

    def model(t: float) -> float:
        return float(n0 + slope_u * t + (0.5 * curv_u * t * t if quad else 0.0))
    span = P.span[k]
    return dict(key=key, label=label(key), x0=float(P.x0[k]), lo=lo, hi=hi, slope=float(slope_u / span),
                curv=float(curv_u / span ** 2) if quad else math.nan, x_minus=float(P.x0[k] - t_lo * span),
                x_plus=float(P.x0[k] + t_hi * span), minus=model(-t_lo), plus=model(t_hi),
                at_bound=("mín" if t_lo < EPS else "") + ("máx" if t_hi < EPS else ""), blocked=[])


def _local(P: _Points, sp: SensParams, usable, resp, n0, backend, out) -> list[dict]:
    """o modelo local (com o histórico) ou um por vez (sem ele): só os eixos que faltam ganham pontos"""
    h, n = sp.h, len(P.vars)

    def support(k: int) -> int:
        """quantos valores diferentes de u_k fora de u₀ há nos pontos de perto"""
        return len({round((q["u"][k] - P.u0[k]) / EPS) for q in P.pts if usable(q)
                    and float(np.linalg.norm(q["u"] - P.u0)) <= NEAR and abs(q["u"][k] - P.u0[k]) >= EPS})

    asked = [False] * n
    for frac in (1.0, 0.5):
        todo = []
        for k, (_, lo, hi, step) in enumerate(P.vars):
            if support(k) >= 2:
                continue
            asked[k] = True
            for sgn in (-1.0, 1.0):
                x = P.x0.copy()
                x[k] = snap(P.x0[k] + sgn * frac * h * P.span[k], lo, hi, step)
                if abs(x[k] - P.x0[k]) > EPS * P.span[k]:
                    todo.append(x)
        P.run(todo)

    use = [q for q in P.pts if usable(q)]
    U = np.array([q["u"] for q in use]) if use else np.zeros((0, n))
    Y = np.array([q[resp] for q in use])
    fit = backend.local_fit(U, Y, P.u0, R, quad=True) if len(use) >= 2 * n + 1 else None
    quad = fit is not None
    if fit is None and len(use) >= n + 1:
        fit = backend.local_fit(U, Y, P.u0, R, quad=False)
    g, c = (fit[0], fit[1]) if fit is not None else (np.full(n, math.nan), np.full(n, math.nan))
    out.update(quad=quad, rms=float(fit[3]) if fit is not None else math.nan)
    rows = []
    for k, (_, lo, hi, step) in enumerate(P.vars):
        r = _row(P, k, h, g[k], c[k], quad, n0)
        for sgn, side in ((-1, "−"), (1, "+")):        # um ponto do eixo, a até h, que não fecha: a restrição ativa
            fail = [q for q in P.pts if not usable(q) and P.on_axis(q, k)
                    and 0 < sgn * (q["u"][k] - P.u0[k]) <= h + step / P.span[k] + EPS]
            if fail:
                q = min(fail, key=lambda q: abs(q["u"][k] - P.u0[k]))
                why = q["why"] if not q["ok"] else ("voo inválido" if out["base"]["valido"] else "voo válido")
                r["blocked"].append((side, float(q["x"][k]), why))
        r.update(near=sum(1 for q in use if float(np.linalg.norm(q["u"] - P.u0)) <= NEAR
                          and abs(q["u"][k] - P.u0[k]) >= EPS),
                 new=sum(1 for q in P.pts if q["new"] and abs(q["u"][k] - P.u0[k]) >= EPS and P.on_axis(q, k)),
                 asked=asked[k])
        rows.append(r)
    return rows


def _morris(P: _Points, sp: SensParams, usable, resp, n0, backend, out) -> list[dict]:
    """os efeitos elementares de Morris nas r trajetórias da caixa u₀ ± h (cortada nos limites, no passo do campo)"""
    n, h = len(P.vars), sp.h
    D = backend.morris_design(n, sp.trajectories, sp.levels, sp.seed)
    blo = np.maximum(P.los, P.x0 - h * P.span)
    bhi = np.minimum(P.los + P.span, P.x0 + h * P.span)
    X = blo + D * (bhi - blo)
    for k, (_, lo, hi, step) in enumerate(P.vars):
        X[..., k] = np.vectorize(lambda v, lo=lo, hi=hi, step=step: snap(v, lo, hi, step))(X[..., k])
    flat = X.reshape(-1, n)
    P.run(list(flat))
    qs = [P.by[P.key(x)] for x in flat]
    Y = np.array([q[resp] if usable(q) else math.nan for q in qs]).reshape(D.shape[:2])
    U = (X - P.los) / P.span
    mu, ms, sg_, cnt = backend.morris_effects(U, Y)
    rows = []
    for k, (_, lo, hi, step) in enumerate(P.vars):
        r = _row(P, k, h, mu[k], math.nan, False, n0)
        r.update(mustar=float(ms[k] / P.span[k]), sigma=float(sg_[k] / P.span[k]), steps=int(cnt[k]),
                 failed=sp.trajectories - int(cnt[k]), near=int(cnt[k]), asked=True,
                 new=sum(1 for q in P.pts if q["new"]))
        rows.append(r)
    fail = [q for q in qs if not usable(q)]
    out["failed"] = (len(fail), fail[0]["why"] or "voo inválido") if fail else (0, "")
    return rows


def _limits(project, problem, evaluator, values, sp, n0, resp, valid0, executor, cancel) -> list[dict]:
    """a nota do melhor avião, como está, com cada limite do problema mudado em ±`limit_step`: ∂N/∂L"""
    jobs, meta = [], []
    for key, name, op, v in limits(project, problem):
        for sgn in (-1.0, 1.0):
            lv = v * (1 + sgn * sp.limit_step) if v != 0 else sgn * sp.limit_step
            p, pr = copy.deepcopy(project), copy.deepcopy(problem)
            if key == "pista":
                p.requirements.takeoff_run = lv
            else:
                for c in pr.constraints:
                    if c.key == key and c.active:
                        c.value = lv
            apply_to_project(pr, p)
            st = {s.name: s for s in evaluator.stages(p, pr)}
            jobs.append((st["superfícies"], dict(values)))
            meta.append((key, name, op, v, lv, st["nota"], float(p.requirements.takeoff_run)))
    if not jobs:
        return []
    ex = executor
    if ex is None:
        from aerosim.parallel import SerialExecutor
        ex = SerialExecutor()
    got = ex.map(_point, jobs, cancel)
    out: dict[str, dict] = {}
    for (key, name, op, v, lv, score, s_to), o in zip(meta, got):
        d = o.value if o.ok else {"ok": False, "why": "cancelado" if o.cancelled else str(o.error)}
        q = dict(ok=bool(d.get("ok")), why=d.get("why", ""), data={k: d.get(k, math.nan) for k in
                                                                     ("mtow", "pv", "m_bat", "b", "lapes", "liquid")})
        q["data"]["s_to"] = s_to
        _score(score, [q])
        n = q[resp] if q["ok"] and "nota" in q and q["valido"] == valid0 else math.nan
        r = out.setdefault(key, dict(key=key, label=name, op=op, value=v, points=[], new=0))
        r["points"].append((lv, n, q["why"] if not q["ok"] else ("" if "nota" in q and q["valido"] == valid0
                                                                 else "voo inválido")))
        r["new"] += 1
    for r in out.values():
        ok = [(lv, n) for lv, n, _ in r["points"] if math.isfinite(n)]
        if len(ok) == 2:
            (l1, n1), (l2, n2) = ok
            r["dNdL"] = (n2 - n1) / (l2 - l1)
        elif len(ok) == 1 and math.isfinite(n0):        # um lado não fecha: a diferença do lado que fecha
            lv, n = ok[0]
            r["dNdL"] = (n - n0) / (lv - r["value"])
        else:
            r["dNdL"] = math.nan
        r["binding"] = any(not math.isfinite(n) for _, n, _ in r["points"])
    return sorted(out.values(), key=lambda r: -abs(r["dNdL"]) if math.isfinite(r["dNdL"]) else math.inf)

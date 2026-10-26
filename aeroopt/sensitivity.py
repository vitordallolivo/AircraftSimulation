"""Sensibilidade do melhor avião: o quanto a nota muda quando uma variável contínua livre sai do lugar.

O otimizador entrega um ponto, mas não diz se ele está no alto de um morro largo ou na beira de um precipício. Um
avião cuja nota cai pela metade com um centímetro a menos de envergadura é arriscado de construir, e uma variável que
quase não mexe na nota pode ser escolhida pelo que for mais fácil na oficina.

A análise é de um indivíduo só, o melhor, e fica dentro do problema: só as contínuas livres dele se mexem (a
configuração, as listas e as inteiras ficam como estão), cada uma dentro dos seus limites e no passo do campo, e um
ponto só conta se fecha com as restrições do problema e tem o mesmo voo válido (ou inválido) do melhor. Um ponto que
não fecha marca o lado em que a restrição está ativa.

Ela quase não roda nada. A busca das superfícies já avaliou vários pontos em volta do melhor e eles estão no
histórico dele; com as contínuas normalizadas $u_k = (x_k - x_{min})/(x_{max} - x_{min})$, um modelo local passa por
esses pontos com peso maior para os de perto e nenhum para os de longe (`ISimBackend.local_fit`, `core/src/optim/localfit.zig`):

$$N(u) \\approx N_0 + g^T (u - u_0) + \\tfrac12 \\sum_k c_k (u_k - u_{0k})^2$$

A inclinação $g_k$ diz para onde a nota sobe; a curvatura $c_k$ diz quanto se perde ao sair do ponto, o que a
inclinação sozinha não conta no alto do morro, onde ela é zero. Só uma direção que o histórico não determina (menos de
dois valores diferentes perto do melhor) ganha pontos novos, em $u_0 \\pm h$ (h = 10 % da faixa), e em
$u_0 \\pm h/2$ se um lado não fecha. A nota de cada ponto é a da etapa da nota com a corrida na pista, como na busca
das superfícies: os pontos do histórico já têm o MTOW, o PV e a bateria, então pontuá-los não custa nenhum ponto de
projeto.

    res = sensitivity(project, problem, best_row, evaluator)   # best_row: a linha do melhor (`stages.row`)
    for r in res["rows"]:                     # da que mais mexe na nota para a que menos mexe
        print(r["label"], r["slope"], r["minus"], r["plus"])
"""
from __future__ import annotations

import copy
import math

import numpy as np

from aerosim.interfaces.optim import OptProblem, StageItem

from . import inputs as inp
from . import stages as sg
from .problem import apply_to_project, fold_bounds

H = 0.10                 # o passo das contínuas, em fração da faixa
R = 0.40                 # o raio do peso do modelo, em fração da faixa: mais longe que isso o ponto não conta
NEAR = R
EPS = 1e-4               # dois valores de u mais perto que isso são o mesmo


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


def _point(job):
    """um ponto (vai para outro processo): a etapa das superfícies e os valores"""
    stage, values = job
    return stage.point(values)


def _data(d: dict) -> dict:
    """o que a etapa da nota lê de um ponto"""
    return {k: d[k] for k in ("mtow", "pv", "m_bat", "b", "s_to", "lapes", "liquid")}


def sensitivity(project, problem: OptProblem, best: dict, evaluator, h: float = H, r: float = R, executor=None,
                cancel=None, backend=None) -> dict:
    """a nota do melhor (`base`) e uma linha por contínua livre (`rows`, da que mais mexe para a que menos): a
    inclinação ∂N/∂x (`slope`) e a curvatura ∂²N/∂x² (`curv`), a nota prevista em x₀ ∓ h·faixa (`minus`, `plus`, no
    limite do problema se ele vem antes), os lados em que o avião deixa de fechar (`blocked`), quantos pontos perto
    havia e quantos foram avaliados de novo. `best` é a linha do melhor, com `values` e `history`"""
    p, problem = copy.deepcopy(project), copy.deepcopy(problem)
    fold_bounds(problem, p)
    apply_to_project(problem, p)
    stages = {s.name: s for s in evaluator.stages(p, problem)}
    surf, score = stages["superfícies"], stages["nota"]
    vars_ = free(problem)
    values = dict(best["values"])
    if not vars_:
        return dict(base=dict(nota=best.get("nota", math.nan), valido=bool(best.get("valido"))), rows=[], h=h,
                    r=r, new=0, used=0, rms=math.nan)
    _, cand = sg.candidate(p, values)
    fixed = dict(s_to=float(p.requirements.takeoff_run), lapes=bool(cand.params.lapes),
                 liquid=bool(cand.params.liquid))
    span = np.array([hi - lo for _, lo, hi, _ in vars_])
    los = np.array([lo for _, lo, _, _ in vars_])
    x0 = np.array([float(values.get(k, sg.get_value(p, k))) for k, *_ in vars_])
    u0 = (x0 - los) / span

    # os pontos: o histórico da busca do melhor (já avaliados), com a nota da etapa da nota
    pts: list[dict] = []
    seen: set[tuple] = set()

    def add(x: np.ndarray, d: dict, new: bool) -> None:
        key = tuple(np.round((x - los) / span / EPS).astype(int))
        if key in seen:
            return
        seen.add(key)
        pts.append(dict(x=x, u=(x - los) / span, ok=bool(d.get("ok")), why=d.get("why", ""), new=new,
                        data={**fixed, **{k: d.get(k, math.nan) for k in ("mtow", "pv", "m_bat", "b")}}))

    for e in best.get("history", []):
        x = np.array([float(e["values"].get(k, x0[i])) for i, (k, *_) in enumerate(vars_)])
        add(x, e, False)

    def run(todo: list[np.ndarray]) -> None:
        if not todo:
            return
        if executor is None:
            from aerosim.parallel import SerialExecutor
            ex = SerialExecutor()
        else:
            ex = executor
        jobs = [(surf, {**values, **{k: float(x[i]) for i, (k, *_) in enumerate(vars_)}}) for x in todo]
        for x, o in zip(todo, ex.map(_point, jobs, cancel)):
            d = o.value if o.ok else {"ok": False, "why": "cancelado" if o.cancelled else str(o.error)}
            add(x, d, True)

    def at0(q: dict) -> bool:
        return float(np.max(np.abs(q["u"] - u0))) < EPS

    if not any(at0(q) for q in pts):                  # o melhor ponto sem histórico (uma linha antiga)
        run([x0])

    def scored(qs: list[dict]) -> None:
        todo = [q for q in qs if q["ok"] and "nota" not in q and all(math.isfinite(q["data"][k])
                                                                     for k in ("mtow", "pv", "m_bat", "b"))]
        items = [StageItem(name=str(i), data=dict(q["data"])) for i, q in enumerate(todo)]
        if items:
            score.run(items)
        for q, it in zip(todo, items):
            q["nota"], q["valido"] = float(it.data["nota"]), bool(it.data["valido"])
            q["formula"] = float(it.data.get("nota_formula", it.data["nota"]))

    scored(pts)
    base = next((q for q in pts if at0(q)), None)
    valid0 = bool(base and base.get("valido"))
    resp = "nota" if valid0 else "formula"             # o melhor voa inválido: a nota da fórmula, antes do zero

    def usable(q: dict) -> bool:
        return q["ok"] and "nota" in q and q["valido"] == valid0

    def support(k: int) -> int:
        """quantos valores diferentes de u_k fora de u₀ há nos pontos de perto"""
        vals = {round((q["u"][k] - u0[k]) / EPS) for q in pts if usable(q)
                and float(np.linalg.norm(q["u"] - u0)) <= NEAR and abs(q["u"][k] - u0[k]) >= EPS}
        return len(vals)

    # só as direções que o histórico não determina ganham pontos, em u₀ ± h (no limite e no passo do campo); se um
    # lado não fecha e ainda falta um valor, em u₀ ± h/2
    asked = [False] * len(vars_)
    for frac in (1.0, 0.5):
        todo = []
        for k, (key, lo, hi, step) in enumerate(vars_):
            if support(k) >= 2:
                continue
            asked[k] = True
            for sgn in (-1.0, 1.0):
                x = x0.copy()
                x[k] = snap(x0[k] + sgn * frac * h * span[k], lo, hi, step)
                if abs(x[k] - x0[k]) > EPS * span[k]:
                    todo.append(x)
        run(todo)
        scored(pts)

    use = [q for q in pts if usable(q)]
    U = np.array([q["u"] for q in use]) if use else np.zeros((0, len(vars_)))
    Y = np.array([q[resp] for q in use])
    if backend is None:
        from aerosim.backend.zig import ZigBackend
        backend = ZigBackend()
    fit = backend.local_fit(U, Y, u0, r, quad=True) if len(use) >= 2 * len(vars_) + 1 else None
    quad = fit is not None
    if fit is None and len(use) >= len(vars_) + 1:
        fit = backend.local_fit(U, Y, u0, r, quad=False)
    g, c, a, rms = (fit[0], fit[1], fit[2], fit[3]) if fit is not None else \
        (np.full(len(vars_), math.nan), np.full(len(vars_), math.nan), math.nan, math.nan)
    n0 = base[resp] if base is not None and "nota" in base else a

    rows = []
    for k, (key, lo, hi, step) in enumerate(vars_):
        t_lo, t_hi = min(h, u0[k]), min(h, 1 - u0[k])  # até onde dá para ir sem sair dos limites

        def model(t: float) -> float:
            return float(n0 + g[k] * t + (0.5 * c[k] * t * t if quad else 0.0))
        blocked = []
        for sgn, side in ((-1, "−"), (1, "+")):        # um ponto do eixo, a até h, que não fecha: a restrição ativa
            fail = [q for q in pts if not usable(q) and 0 < sgn * (q["u"][k] - u0[k]) <= h + step / span[k] + EPS
                    and float(np.max(np.abs(np.delete(q["u"] - u0, k)), initial=0.0)) < EPS]
            if fail:
                q = min(fail, key=lambda q: abs(q["u"][k] - u0[k]))
                why = q["why"] if not q["ok"] else ("voo inválido" if valid0 else "voo válido")
                blocked.append((side, float(q["x"][k]), why))
        near = sum(1 for q in use if float(np.linalg.norm(q["u"] - u0)) <= NEAR and abs(q["u"][k] - u0[k]) >= EPS)
        rows.append(dict(key=key, label=label(key), x0=float(x0[k]), lo=lo, hi=hi,
                         slope=float(g[k] / span[k]), curv=float(c[k] / span[k] ** 2) if quad else math.nan,
                         x_minus=float(x0[k] - t_lo * span[k]), x_plus=float(x0[k] + t_hi * span[k]),
                         minus=model(-t_lo), plus=model(t_hi), at_bound=("mín" if t_lo < EPS else "")
                         + ("máx" if t_hi < EPS else ""), blocked=blocked, near=near,
                         new=sum(1 for q in pts if q["new"] and abs(q["u"][k] - u0[k]) >= EPS
                                 and float(np.max(np.abs(np.delete(q["u"] - u0, k)), initial=0.0)) < EPS),
                         asked=asked[k]))
    for row in rows:
        d = [abs(row[s] - n0) for s in ("minus", "plus") if math.isfinite(row[s])]
        row["swing"] = max(d) if d else math.nan
    rows.sort(key=lambda r: -r["swing"] if math.isfinite(r["swing"]) else math.inf)
    return dict(base=dict(nota=float(n0) if base is not None else math.nan, valido=valid0,
                          ok=bool(base and base["ok"]),
                          response=resp), rows=rows, h=h, r=r, quad=quad, rms=float(rms),
                used=len(use), history=len(best.get("history", [])), new=sum(1 for q in pts if q["new"]))

"""O problema como arquivo (.opt.json) e a ponte com o projeto da sprint (`DesignProject`).

`from_project` lê as variáveis (fixo / variável / lista), as restrições e as opções do mini-MDO de um projeto e
devolve um `OptProblem`; `apply_to_project` faz o caminho de volta. Assim o mesmo problema roda pela página MDO
do aerosim ou pelo aeroopt, com o mesmo resultado.

    pr = from_project(projeto)
    pr.isolate("asa")                    # só as variáveis da asa ficam livres
    save(pr, "micro.opt.json")
"""
from __future__ import annotations

import json

from aerosim.interfaces.optim import OptConstraint, OptProblem, OptVariable

# grupo de cada prefixo das entradas do registro (para isolar um grupo inteiro)
GROUPS = {"wing": "asa", "power": "propulsão", "req": "requisitos"}
# opções do mini-MDO que viram o solver e os parâmetros do problema
SOLVER_KEYS = ("method", "particles", "iterations", "seed", "penalty")
PARAM_KEYS = ("kind", "m_max", "tail_area_frac", "fuselage_CDS", "airfoil_dir")


def _kind(inp) -> str:
    if inp.unit == "lista":
        return "lista"
    return "inteira" if inp.integer else "contínua"


def from_project(project, name: str = "") -> OptProblem:
    """o problema que a página MDO do projeto resolveria (as entradas "calculado" são saídas e ficam de fora)"""
    variables = []
    for v in project.variables:
        if v.mode == "calculado":
            continue
        variables.append(OptVariable(key=v.key, kind=_kind(v.input), lo=float(v.lo), hi=float(v.hi),
                                     options=list(v.options), group=GROUPS.get(v.key.partition(".")[0], ""),
                                     free=v.mode == "variável"))
    cons = [OptConstraint(c.key, c.op, float(c.value), bool(c.active), float(c.tol))
            for c in project.requirements.constraints]
    mp = project.mdo
    return OptProblem(name=name, variables=variables, constraints=cons, scoring=mp.objective,
                      evaluator="mini-MDO", solver={k: getattr(mp, k) for k in SOLVER_KEYS},
                      params={k: getattr(mp, k) for k in PARAM_KEYS})


def apply_to_project(problem: OptProblem, project) -> None:
    """leva o problema para o projeto: modos e limites das variáveis, restrições e opções do mini-MDO"""
    from aerosim.design import registry as rg
    for ov in problem.variables:
        v = next((v for v in project.variables if v.key == ov.key), None)
        if v is None:
            v = rg.Variable(ov.key)
            project.variables.append(v)
        v.mode = "variável" if ov.free else "fixo"
        v.lo, v.hi, v.options = ov.lo, ov.hi, list(ov.options)
    project.requirements.constraints = [rg.Constraint(c.key, c.op, c.value, c.active, c.tol)
                                        for c in problem.constraints]
    mp = project.mdo
    for k, val in list(problem.solver.items()) + list(problem.params.items()):
        if hasattr(mp, k):
            setattr(mp, k, val)
    if problem.scoring in ("MTOW", "EE"):
        mp.objective = problem.scoring


def save(problem: OptProblem, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(problem.to_dict(), f, ensure_ascii=False, indent=2)


def load(path: str) -> OptProblem:
    with open(path, encoding="utf-8") as f:
        return OptProblem.from_dict(json.load(f))

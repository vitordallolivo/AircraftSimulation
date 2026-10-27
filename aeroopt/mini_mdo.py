"""O mini-MDO do núcleo (`core/src/sizing`) atrás dos contratos do aeroopt.

Avaliador e solver aqui são a mesma chamada do núcleo (`sizing_optimize`): a cadeia asa → envelope →
decolagem → MTOW avalia cada partícula do PSO dentro do Zig. O problema é levado para uma cópia do projeto e
roda pelo mesmo caminho da página MDO, então o resultado é o mesmo, bit a bit.

    ev = MiniMdoEvaluator(projeto)
    res = MiniMdoSolver().run(problema, ev)
"""
from __future__ import annotations

import copy

from aerosim.interfaces.optim import IEvaluator, ISolver, OptResult

from .problem import apply_to_project

QUANTITIES = ("S", "b", "AR", "V_S", "n_surf", "P_motor", "n_motor", "s_to", "V_max", "RC", "TW", "mass", "pv",
              "cp", "ee", "mtow", "V_LD", "LD", "c_root", "n_turn", "grad", "ceiling", "s_land")


class MiniMdoEvaluator(IEvaluator):
    name = "mini-MDO"

    def __init__(self, project, catalog=None, backend=None):
        self.project, self.catalog, self.backend = project, catalog, backend

    def quantities(self) -> list[str]:
        if self.backend is not None:
            return list(self.backend.sizing_names()["quantities"])
        return list(QUANTITIES)


class MiniMdoSolver(ISolver):
    name = "mini-MDO (PSO do núcleo)"

    def run(self, problem, evaluator, progress=None, cancel=None) -> OptResult:
        from aerosim.design import mdo
        p = copy.deepcopy(evaluator.project)          # o projeto do usuário não muda
        apply_to_project(problem, p)
        rows, best, names = mdo.run(p, evaluator.catalog, evaluator.backend, progress, cancel)
        return OptResult(rows=rows, best=best, names=names)

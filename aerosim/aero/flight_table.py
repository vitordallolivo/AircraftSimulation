"""Tabela aerodinâmica de voo a partir de qualquer método (`IAeroSolver`): o avião voa com ela no núcleo
(`ac.sim.aero_model = "tabela"`, `core/src/physics/aerotable.zig`).

A tabela é universal (o tradutor do núcleo converte): C_L, C_D, C_m em α (graus, β = 0, sem taxas nem comandos,
momentos em `ref`), mais as derivadas lineares de `aerosim.backend.zig.translator.TABLE_DERIVS` tomadas em `alpha_d`.
As derivadas que o método não dá (NaN: o lltdrek sem β, um método sem comandos) vêm de `fill` (em geral o núcleo), e
a tabela guarda quais foram completadas. Fora da faixa de α, o núcleo usa o valor da ponta.

    from aerosim.aero import solver_by_name
    from aerosim.aero.flight_table import table
    t = table(solver_by_name(backend, "avl"), model, V=12.0, rho=1.225, ref=cg, fill=solver_by_name(backend, "zig"))
    ac.sim.aero_model, ac.sim.aero_table = "tabela", t
"""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.aero import AeroCase, IAeroSolver

ALPHAS = np.arange(-10.0, 20.01, 1.0)        # graus; a decolagem e a missão ficam dentro disso
DERIVS = ("CYb", "Clb", "Cnb", "CYp", "Clp", "Cnp", "CLq", "Cmq", "CYr", "Clr", "Cnr", "CLde", "Cmde", "Clda",
          "Cnda", "CYdr", "Cldr", "Cndr")


def table(solver: IAeroSolver, model, V: float, rho: float, ref=(0.0, 0.0, 0.0), alphas=ALPHAS,
          alpha_d: float = 2.0, fill: IAeroSolver | None = None) -> dict:
    """a tabela universal do método `solver` no modelo universal `model` a V (m/s)"""
    case = AeroCase(V=V, rho=rho, alphas=np.asarray(alphas, float), alpha_d=alpha_d, ref=tuple(float(x) for x in ref))
    pol = solver.solve(model, case)
    derivs = {k: pol.deriv(k) for k in DERIVS}
    faltam = [k for k, v in derivs.items() if not math.isfinite(v)]
    completadas = []
    if faltam and fill is not None:
        base = fill.solve(model, AeroCase(V=V, rho=rho, alphas=np.array([alpha_d]), alpha_d=alpha_d, ref=case.ref))
        for k in faltam:
            v = base.deriv(k)
            if math.isfinite(v):
                derivs[k] = v
                completadas.append(k)
    derivs = {k: (v if math.isfinite(v) else 0.0) for k, v in derivs.items()}
    ok = np.isfinite(pol.CL) & np.isfinite(pol.CD) & np.isfinite(pol.Cm)
    return dict(fonte=solver.title, alpha=[float(x) for x in pol.alpha[ok]], CL=[float(x) for x in pol.CL[ok]],
                CD=[float(x) for x in pol.CD[ok]], Cm=[float(x) for x in pol.Cm[ok]], ref=list(case.ref),
                derivs=derivs, completadas=completadas, zeradas=[k for k in faltam if k not in completadas],
                fus=bool(getattr(solver, "includes_fuselage", False)), V=V, alpha_d=alpha_d)

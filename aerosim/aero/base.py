"""Polar e derivadas comuns a todos os solvers: cada um só implementa `evaluate` (pontos de voo
universais -> coeficientes universais); este código monta a varredura em α e as diferenças
centrais em α, β, p̂, q̂, r̂ e nos comandos, igual para todos."""
from __future__ import annotations

import math
import time

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar, FlightPoint, IAeroSolver

DA = math.radians(0.5)     # passo de α, β e comandos
DH = 0.01                  # passo das taxas adimensionais

# (variável, passo, saídas): derivada = d saída / d variável
_PLAN = [("alpha", DA, ("CL", "Cm"), "a", None), ("beta", DA, ("CY", "Cl", "Cn"), "b", "supports_beta"),
         ("p", DH, ("CY", "Cl", "Cn"), "p", "supports_rates"), ("q", DH, ("CL", "Cm"), "q", "supports_rates"),
         ("r", DH, ("CY", "Cl", "Cn"), "r", "supports_rates"), ("de", DA, ("CL", "Cm"), "de", "supports_controls"),
         ("da", DA, ("Cl", "Cn"), "da", "supports_controls"), ("dr", DA, ("CY", "Cl", "Cn"), "dr", "supports_controls")]


class AeroSolverBase(IAeroSolver):
    notes = ""

    def solve(self, model, case: AeroCase) -> AeroPolar:
        t0 = time.perf_counter()
        a0 = math.radians(case.alpha_d)
        pts = [FlightPoint(math.radians(a)) for a in case.alphas]
        der_pts = []
        for var, h, outs, suf, flag in _PLAN:
            if flag and not getattr(self, flag):
                continue
            base = dict(alpha=a0)
            p_ = dict(base)
            m_ = dict(base)
            p_[var] = (a0 if var == "alpha" else 0.0) + h
            m_[var] = (a0 if var == "alpha" else 0.0) - h
            der_pts.append((var, h, outs, suf, FlightPoint(**p_), FlightPoint(**m_)))
        allp = pts + [x for d in der_pts for x in d[4:6]]
        res = self.evaluate(model, case, allp)
        pol = res[:len(pts)]
        rest = res[len(pts):]
        derivs = {}
        for k, (var, h, outs, suf, _, _) in enumerate(der_pts):
            cp, cm = rest[2 * k], rest[2 * k + 1]
            for o in outs:
                derivs[o + suf] = (cp[o] - cm[o]) / (2 * h)
        col = lambda k: np.array([r.get(k, np.nan) for r in pol], float)
        return AeroPolar(self.name, np.asarray(case.alphas, float), col("CL"), col("CD"), col("Cm"), col("CDi"),
                         {k: float(v) for k, v in derivs.items()}, span=self.span_load(model, case),
                         notes=self.notes, elapsed=time.perf_counter() - t0)

    def span_load(self, model, case):
        return None

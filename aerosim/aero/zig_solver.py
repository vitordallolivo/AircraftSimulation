"""O método do núcleo (faixas com C_Lα de Helmbold, downwash da asa na cauda, estol de
Beard e McLain, fuselagem por coeficientes) visto como um solver da comparação.
Derivadas por diferenças centrais em α, β, p̂, q̂, r̂ e nos comandos."""
from __future__ import annotations

import math
import time

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar, IAeroSolver
from aerosim.interfaces.backend import ISimBackend
from aerosim.model.compile import compile_aircraft

D = math.radians(0.5)       # passo de α, β e dos comandos
H = 0.01                    # passo das taxas adimensionais


class ZigPanelSolver(IAeroSolver):
    name = "zig"
    title = "Núcleo Zig (faixas)"
    description = "faixas por seção/comando, C_Lα de Helmbold, downwash ε0 + dε/dα α, fuselagem por coeficientes"

    def __init__(self, backend: ISimBackend):
        self.backend = backend

    def solve(self, ac, case: AeroCase) -> AeroPolar:
        t0 = time.perf_counter()
        S, c, b = ac.references()
        V, ref = case.V, list(case.ref)
        with self.backend.open_session() as s:
            spec = compile_aircraft(ac)
            spec["env"]["rho"] = case.rho
            s.configure(spec)

            def C(al=0.0, be=0.0, p=0.0, q=0.0, r=0.0, de=0.0, da=0.0, dr=0.0):
                return s.aero_coeffs_ex(V, al, be, p, q, r, de, da, dr, ref=ref)
            rows = [C(math.radians(a)) for a in case.alphas]
            a = math.radians(case.alpha_d)
            d = {}

            def diff(key_x, kw_p, kw_m, step, outs):
                cp, cm = C(**kw_p), C(**kw_m)
                for o in outs:
                    d[o + key_x] = (cp[o] - cm[o]) / (2 * step)
            diff("a", dict(al=a + D), dict(al=a - D), D, ("CL", "Cm"))
            diff("b", dict(al=a, be=D), dict(al=a, be=-D), D, ("CY", "Cl", "Cn"))
            pr = H * 2 * V / b
            diff("p", dict(al=a, p=pr), dict(al=a, p=-pr), H, ("CY", "Cl", "Cn"))
            qr = H * 2 * V / c
            diff("q", dict(al=a, q=qr), dict(al=a, q=-qr), H, ("CL", "Cm"))
            diff("r", dict(al=a, r=pr), dict(al=a, r=-pr), H, ("CY", "Cl", "Cn"))
            diff("de", dict(al=a, de=D), dict(al=a, de=-D), D, ("CL", "Cm"))
            diff("da", dict(al=a, da=D), dict(al=a, da=-D), D, ("Cl", "Cn"))
            diff("dr", dict(al=a, dr=D), dict(al=a, dr=-D), D, ("CY", "Cl", "Cn"))
        keep = ("CLa", "Cma", "CYb", "Clb", "Cnb", "CYp", "Clp", "Cnp", "CLq", "Cmq", "CYr", "Clr", "Cnr",
                "CLde", "Cmde", "Clda", "Cnda", "CYdr", "Cldr", "Cndr")
        derivs = {k: float(d[k]) for k in keep if k in d}
        col = lambda k: np.array([r[k] for r in rows])
        return AeroPolar(self.name, np.asarray(case.alphas, float), col("CL"), col("CD"), col("Cm"), col("CDi"),
                         derivs, notes="aeronave completa (asa, EH, EV, fuselagem)",
                         elapsed=time.perf_counter() - t0)

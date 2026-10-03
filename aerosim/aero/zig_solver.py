"""O método do núcleo (faixas com C_Lα de Helmbold, downwash ε0 + dε/dα α na cauda, estol de
Beard e McLain, fuselagem por coeficientes) como solver da comparação. O modelo universal vai ao
núcleo pelo tradutor do backend; os coeficientes voltam pelo mesmo tradutor."""
from __future__ import annotations

from aerosim.interfaces.aero import AeroCase, FlightPoint
from aerosim.interfaces.backend import ISimBackend

from .base import AeroSolverBase


class ZigPanelSolver(AeroSolverBase):
    name = "zig"
    title = "Núcleo Zig (faixas)"
    description = "faixas por seção/comando, C_Lα de Helmbold, downwash ε0 + dε/dα α, fuselagem por coeficientes"
    supports_controls = True
    notes = "aeronave completa (asa, EH, EV, dispositivos, fuselagem)"

    def __init__(self, backend: ISimBackend):
        self.backend = backend

    def evaluate(self, model, case: AeroCase, points: list[FlightPoint]):
        V, ref = case.V, list(case.ref)
        b, c = model.b, model.c
        out = []
        with self.backend.session_for(model, overrides={"env": {"rho": case.rho}}) as s:
            for pt in points:
                raw = s.aero_coeffs_ex(V, pt.alpha, pt.beta, pt.p * 2 * V / b, pt.q * 2 * V / c, pt.r * 2 * V / b,
                                       pt.de, pt.da, pt.dr, ref=ref)
                out.append(self.backend.translator.from_native(raw, model))
        return out

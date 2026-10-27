"""A linha sustentadora do núcleo (`core/src/loads/llt.zig`) como método de polar e derivadas: a conta da simulação
com as forças dos painéis trocadas pelas da linha sustentadora (`aerosim_aero_coeffs_llt`). A fuselagem, o c_m das
seções e os modificadores ficam os da simulação.

Duas variantes:
- `zig_llt`: Phillips e Snyder (2000);
- `zig_llt_gh`: com as correções de Goates e Hunsaker (2021), que convergem com a malha em derrapagem e com
  enflechamento (C_Lα a 1,5 % e C_lβ a 3 % do MachUpX; `core/src/loads/README.md`).

As superfícies são refinadas (`span_loads.refine_all`, faixas mais estreitas na ponta), porque a linha sustentadora
só converge com muitas faixas. `per_side` fixa o número de faixas por lado; sem ele, vale o `AeroCase.n_span` do caso.
O refino é feito uma vez por avião. `case.h`, `case.T` e `case.Q` (opcionais) dão a altura sobre o chão e a tração e o
torque de cada motor, para os modificadores."""
from __future__ import annotations

from aerosim.interfaces.aero import AeroCase, FlightPoint

from .zig_solver import ZigPanelSolver


class CoreLLTSolver(ZigPanelSolver):
    fidelity = "llt"
    supports_controls = True
    includes_fuselage = True

    def __init__(self, backend, gh: bool = False, per_side: int | None = None):
        super().__init__(backend)
        self.gh, self.per_side = gh, per_side
        if gh:
            self.name, self.title = "zig_llt_gh", "Núcleo Zig (linha sustentadora, Goates e Hunsaker)"
            self.description = ("linha sustentadora do núcleo com junta, linha efetiva e seção normal à linha (Goates e "
                                "Hunsaker 2021): converge em derrapagem e com enflechamento")
        else:
            self.name, self.title = "zig_llt", "Núcleo Zig (linha sustentadora, Phillips e Snyder)"
            self.description = ("linha sustentadora do núcleo (Phillips e Snyder 2000); não converge com a malha em "
                                "superfície enflechada nem em derrapagem")
        self.notes = "aeronave completa; superfícies refinadas; fuselagem e c_m das seções como na simulação"
        self._fino = (None, None, None)

    @property
    def overrides(self) -> dict:
        from .span_loads import GOATES_HUNSAKER
        return dict(GOATES_HUNSAKER) if self.gh else {}

    def refined(self, model, case: AeroCase):
        """o modelo universal com as superfícies refinadas (guardado por avião e por número de faixas)"""
        from aerosim.model.universal import build_model

        from .span_loads import refine_all
        n = self.per_side or int(case.n_span)
        key = (id(model.aircraft), n)
        if self._fino[:2] != key:
            self._fino = (*key, build_model(refine_all(self.backend, model.aircraft, tip=True, per_side=n)))
        return self._fino[2]

    def evaluate(self, model, case: AeroCase, points: list[FlightPoint]):
        model = self.refined(model, case)
        V, ref, b, c = case.V, list(case.ref), model.b, model.c
        h = getattr(case, "h", 50.0)
        out = []
        with self.backend.session_for(model, overrides={"env": {"rho": case.rho}, **self.overrides}) as s:
            for pt in points:
                raw = s.aero_coeffs_llt(V, pt.alpha, pt.beta, pt.p * 2 * V / b, pt.q * 2 * V / c, pt.r * 2 * V / b,
                                        pt.de, pt.da, pt.dr, h=h, T=getattr(case, "T", ()), Q=getattr(case, "Q", ()),
                                        ref=ref)
                out.append(self.backend.translator.from_native(raw, model))
        return out

"""AeroSandbox (Sharpe, MIT): três métodos sobre o mesmo modelo universal.

`AsbTranslator`:
  ida   — cada superfície do modelo (asa, EH, EV e dispositivos, que já chegam como superfícies)
          vira um `asb.Wing` com as mesmas estações (x' = −x, z' = −z; perfil pelo contorno);
          a fuselagem entra no AeroBuildup; o ponto de voo universal vira OperatingPoint
          (α, β em graus; p, q, r dimensionais nos eixos do ASB)
  volta — o ASB já devolve C_L, C_D, C_Y, C_l, C_m, C_n na convenção aeronáutica usual (a mesma do
          simulador); no VLM o C_D é só induzido e o C_D0 do modelo é somado
Métodos: VLM (malha de vórtices), AeroBuildup (componentes com NeuralFoil + fuselagem),
LiftingLine (NeuralFoil; sem campo de rotação).
"""
from __future__ import annotations

import numpy as np

from aerosim.interfaces.aero import AeroCase, FlightPoint
from aerosim.interfaces.translator import IModelTranslator

from .base import AeroSolverBase
from .geometry import to_xz_up


def _atmosphere(rho: float):
    """atmosfera ISA na altitude que dá a densidade pedida"""
    import aerosandbox as asb
    h = 44330.8 * (1 - (rho / 1.225) ** (1 / 4.2559)) if rho < 1.225 else 0.0
    return asb.Atmosphere(altitude=h)


class AsbTranslator(IModelTranslator):
    name = "aerosandbox"

    def to_native(self, model, ref=(0.0, 0.0, 0.0), with_fuselage: bool = False, **_):
        import aerosandbox as asb
        wings = []
        for s in model.surfaces:
            af = asb.Airfoil(name=s.airfoil.name, coordinates=s.airfoil.outline())
            xs = [asb.WingXSec(xyz_le=to_xz_up(q.le), chord=q.chord, twist=0.0 if s.vertical else q.twist, airfoil=af)
                  for q in s.stations]
            wings.append(asb.Wing(name=s.name, symmetric=bool(s.mirror), xsecs=xs))
        fus = []
        f = model.aircraft.fuselage
        if with_fuselage and f.enabled:
            L = f.length
            st = [(0.0, 0.15), (0.12, 0.9), (0.3, 1.0), (0.65, 1.0), (1.0, 0.35)]
            fus.append(asb.Fuselage(name="fuselagem", xsecs=[
                asb.FuselageXSec(xyz_c=[-(f.x_nose - k * L), 0.0, -f.z], width=f.width * w, height=f.height * w)
                for k, w in st]))
        return asb.Airplane(name=model.name, wings=wings, fuselages=fus, xyz_ref=to_xz_up(ref), s_ref=model.S,
                            c_ref=model.c, b_ref=model.b)

    @staticmethod
    def op_point(model, case: AeroCase, pt: FlightPoint):
        """ponto universal -> OperatingPoint (α, β em graus; p, q, r dimensionais — o ASB usa a mesma
        convenção aeronáutica do simulador para as taxas e os momentos)"""
        import aerosandbox as asb
        V = case.V
        return asb.OperatingPoint(atmosphere=_atmosphere(case.rho), velocity=V, alpha=float(np.degrees(pt.alpha)),
                                  beta=float(np.degrees(pt.beta)), p=pt.p * 2 * V / model.b, q=pt.q * 2 * V / model.c,
                                  r=pt.r * 2 * V / model.b)

    def from_native(self, r: dict, model, induced_only: bool = False, **_) -> dict[str, float]:
        g = lambda k: float(np.ravel(r[k])[0]) if k in r else np.nan
        out = dict(CL=g("CL"), CY=g("CY"), Cl=g("Cl"), Cm=g("Cm"), Cn=g("Cn"))
        cd = g("CD")
        if induced_only:
            out["CDi"], out["CD"] = cd, cd + model.parasite_cd()
        else:
            out["CD"] = cd
            out["CDi"] = g("D_induced") / r["_qS"] if "D_induced" in r and "_qS" in r else np.nan
        return out


class _AsbBase(AeroSolverBase):
    method = "vlm"
    induced_only = True
    translator = AsbTranslator()

    def available(self):
        try:
            import aerosandbox  # noqa: F401
        except Exception:
            return "pacote aerosandbox não instalado (pip install aerosandbox)"
        return None

    def _analysis(self, ap, op, case):
        import aerosandbox as asb
        if self.method == "vlm":
            return asb.VortexLatticeMethod(airplane=ap, op_point=op, spanwise_resolution=max(4, case.n_span // 2),
                                           chordwise_resolution=6)
        if self.method == "buildup":
            return asb.AeroBuildup(airplane=ap, op_point=op)
        return asb.LiftingLine(airplane=ap, op_point=op, spanwise_resolution=max(4, case.n_span // 2))

    def evaluate(self, model, case: AeroCase, points: list[FlightPoint]):
        ap = self.translator.to_native(model, ref=case.ref, with_fuselage=self.method == "buildup")
        out = []
        for pt in points:
            op = self.translator.op_point(model, case, pt)
            r = dict(self._analysis(ap, op, case).run())
            r["_qS"] = 0.5 * float(op.atmosphere.density()) * case.V ** 2 * model.S
            out.append(self.translator.from_native(r, model, induced_only=self.induced_only))
        return out


class AsbVLMSolver(_AsbBase):
    name = "asb_vlm"
    title = "AeroSandbox VLM"
    description = "malha de vórtices (asa, EH, EV, dispositivos); C_D = induzido + C_D0 do modelo"
    method = "vlm"
    induced_only = True
    notes = "VLM: superfícies do modelo (sem fuselagem); C_D = induzido + C_D0 do modelo"


class AsbBuildupSolver(_AsbBase):
    name = "asb_buildup"
    title = "AeroSandbox AeroBuildup"
    description = "soma por componentes com NeuralFoil + fuselagem"
    method = "buildup"
    induced_only = False
    notes = "AeroBuildup: superfícies com NeuralFoil + fuselagem (arrasto completo)"


class AsbLiftingLineSolver(_AsbBase):
    name = "asb_ll"
    title = "AeroSandbox LiftingLine"
    description = "linha sustentadora com polar do NeuralFoil"
    method = "ll"
    induced_only = False
    supports_rates = False      # o LiftingLine do ASB não modela o campo de rotação
    notes = "LiftingLine (NeuralFoil): superfícies do modelo, sem fuselagem"

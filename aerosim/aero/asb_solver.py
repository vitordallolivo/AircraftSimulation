"""AeroSandbox (Sharpe, MIT): três métodos sobre a mesma geometria convertida
(x' = −x, z' = −z; perfis pelo contorno .dat/NACA):
  - VLM: malha de vórtices em ferradura (só sustentação e arrasto induzido; o C_D0 do modelo
    é somado como nos outros);
  - AeroBuildup: soma por componentes com NeuralFoil nas seções e fuselagem (arrasto completo);
  - LiftingLine: linha sustentadora com polar do NeuralFoil.
As derivadas vêm de `run_with_stability_derivatives` (diferenças finitas do próprio ASB)."""
from __future__ import annotations

import time

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar, IAeroSolver

from .geometry import parasite_cd, surface_stations, to_xz_up

DERIV_KEYS = ("CLa", "Cma", "CYb", "Clb", "Cnb", "CLq", "Cmq", "CYp", "Clp", "Cnp", "CYr", "Clr", "Cnr")


def build_airplane(ac, ref, with_fuselage: bool = False):
    import aerosandbox as asb
    S, c, b = ac.references()
    wings = []
    for s in ac.surfaces:
        if not s.enabled or len(s.sections) < 2:
            continue
        af = asb.Airfoil(name=s.airfoil.name, coordinates=s.airfoil.outline())
        xs = [asb.WingXSec(xyz_le=to_xz_up(q["le"]), chord=q["chord"], twist=q["twist"], airfoil=af)
              for q in surface_stations(s)]
        wings.append(asb.Wing(name=s.name, symmetric=bool(s.symmetric and not s.vertical), xsecs=xs))
        # dispositivos (winglet, placa, cerca): uma asa por perna do lado direito, espelhada
        from aerosim.model.devices import legs
        for k, d in enumerate(s.devices):
            from aerosim.model.airfoil import naca4
            daf = asb.Airfoil(name=d.profile, coordinates=naca4(d.profile))
            for j, l in enumerate(x for x in legs(s, d) if x.side >= 0):
                xs = []
                for h in (0.0, l.height):
                    le, c_ = l.station(h)
                    xs.append(asb.WingXSec(xyz_le=to_xz_up(le), chord=c_, twist=0.0, airfoil=daf))
                wings.append(asb.Wing(name=f"{s.name} {d.kind} {k}.{j}", symmetric=bool(s.symmetric), xsecs=xs))
    fus = []
    f = ac.fuselage
    if with_fuselage and f.enabled:
        L = f.length
        st = [(0.0, 0.15), (0.12, 0.9), (0.3, 1.0), (0.65, 1.0), (1.0, 0.35)]
        fus.append(asb.Fuselage(name="fuselagem", xsecs=[
            asb.FuselageXSec(xyz_c=[-(f.x_nose - k * L), 0.0, -f.z], width=f.width * w, height=f.height * w)
            for k, w in st]))
    return asb.Airplane(name=ac.name, wings=wings, fuselages=fus, xyz_ref=to_xz_up(ref), s_ref=S, c_ref=c, b_ref=b)


class _AsbBase(IAeroSolver):
    method = "vlm"
    induced_only = True

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

    def solve(self, ac, case: AeroCase) -> AeroPolar:
        import aerosandbox as asb
        t0 = time.perf_counter()
        ap = build_airplane(ac, case.ref, with_fuselage=self.method == "buildup")
        atm_op = dict(velocity=case.V, beta=0.0)
        CL, CD, Cm, CDi = [], [], [], []
        for a in case.alphas:
            op = asb.OperatingPoint(atmosphere=_atmosphere(case.rho), alpha=float(a), **atm_op)
            r = self._analysis(ap, op, case).run()
            CL.append(float(np.ravel(r["CL"])[0]))
            Cm.append(float(np.ravel(r["Cm"])[0]))
            cd = float(np.ravel(r["CD"])[0])
            if self.induced_only:
                CDi.append(cd)
                cd += parasite_cd(ac)
            else:
                q = 0.5 * case.rho * case.V ** 2 * ap.s_ref
                CDi.append(float(np.ravel(r.get("D_induced", np.nan))[0]) / q if "D_induced" in r else np.nan)
            CD.append(cd)
        op = asb.OperatingPoint(atmosphere=_atmosphere(case.rho), alpha=float(case.alpha_d), **atm_op)
        rd = self._analysis(ap, op, case).run_with_stability_derivatives()
        derivs = {k: float(np.ravel(rd[k])[0]) for k in DERIV_KEYS if k in rd}
        if self.method == "ll":     # o LiftingLine do ASB não modela o campo de rotação: só α e β
            derivs = {k: v for k, v in derivs.items() if k[-1] in "ab"}
        return AeroPolar(self.name, np.asarray(case.alphas, float), np.array(CL), np.array(CD), np.array(Cm),
                         np.array(CDi), derivs, notes=self.note, elapsed=time.perf_counter() - t0)


def _atmosphere(rho: float):
    """atmosfera ISA na altitude que dá a densidade pedida"""
    import aerosandbox as asb
    h = 44330.8 * (1 - (rho / 1.225) ** (1 / 4.2559)) if rho < 1.225 else 0.0
    return asb.Atmosphere(altitude=h)


class AsbVLMSolver(_AsbBase):
    name = "asb_vlm"
    title = "AeroSandbox VLM"
    description = "malha de vórtices (asa, EH, EV); C_D = induzido + C_D0 do modelo"
    method = "vlm"
    induced_only = True
    note = "VLM: asa, EH e EV (sem fuselagem); C_D = induzido + C_D0 do modelo"


class AsbBuildupSolver(_AsbBase):
    name = "asb_buildup"
    title = "AeroSandbox AeroBuildup"
    description = "soma por componentes com NeuralFoil + fuselagem"
    method = "buildup"
    induced_only = False
    note = "AeroBuildup: superfícies com NeuralFoil + fuselagem (arrasto completo)"


class AsbLiftingLineSolver(_AsbBase):
    name = "asb_ll"
    title = "AeroSandbox LiftingLine"
    description = "linha sustentadora com polar do NeuralFoil"
    method = "ll"
    induced_only = False
    note = "LiftingLine (NeuralFoil): asa, EH e EV; C_D com perfil do NeuralFoil, sem fuselagem"

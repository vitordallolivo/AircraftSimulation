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
from .span_loads import StripLoadMethod, SurfaceLoad


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
    level = "detalhado"          # comparação com outro método (VLM, AeroBuildup, linha sustentadora)
    cost = "caro"
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
    fidelity = "vlm"
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


# ---------------------------------------------------------------------- cargas por faixa (aba Cargas)
def _strip_delta(ctl, side: int, d_deg) -> float:
    """quanto a faixa gira (graus) pelos comandos: a deflexão fixa (flape) e τ·(mistura · [δe, δa, δr]), o mesmo que
    o tradutor do núcleo soma no α do painel (backend/zig/translator.surface_panels)"""
    from aerosim.model.aircraft import panel_mix
    if ctl is None:
        return 0.0
    fixed = ctl.tau * ctl.deflection
    if ctl.kind == "flap":
        return fixed
    return fixed + ctl.tau * float(np.dot(panel_mix(ctl.gains, side), d_deg))


def _side_groups(s, side: int, d_deg, af) -> list[list]:
    """as estações de um lado da superfície como WingXSec, em grupos de faixas que giram igual pelos comandos (cada
    grupo vira uma asa do ASB; os grupos se encostam na borda do comando, como uma superfície de comando de verdade).
    O VLM do ASB não deflete superfícies: o comando entra como torção das faixas dele. O lado esquerdo vai da ponta
    para a raiz (y crescente)"""
    import aerosandbox as asb
    sg = -1.0 if side < 0 else 1.0

    def xs(q, dl):
        return asb.WingXSec(xyz_le=to_xz_up([q.le[0], sg * q.le[1], q.le[2]]), chord=q.chord,
                            twist=0.0 if s.vertical else q.twist + dl, airfoil=af)
    groups, last = [], None
    for a, b, ctl in s.strips():
        dl = 0.0 if s.vertical else _strip_delta(ctl, side, d_deg)
        if last is None or abs(dl - last) > 1e-9:
            groups.append([xs(a, dl)])
        groups[-1].append(xs(b, dl))
        last = dl
    if side < 0:
        groups = [g[::-1] for g in groups[::-1]]
    return groups


class AsbVLMLoads(StripLoadMethod):
    """carga por faixa pelo VLM do AeroSandbox (malha de vórtices na corda e na envergadura; Sharpe, MIT). Cada lado
    de cada superfície vira um `asb.Wing` sem simetria (comandos assimétricos); os comandos entram como torção das
    faixas, porque o VLM do ASB não deflete superfícies. Sem esteira de hélice e sem efeito solo; arrasto só o
    induzido; α efetivo = α0 + c_l/a do perfil"""
    name = "vlm_asb"
    title = "VLM do AeroSandbox"
    source = "AeroSandbox: VLM (Sharpe, MIT; aerosim/aero/asb_solver.py)"
    supports = frozenset({"comandos", "corda"})
    backend = None
    n_span, n_chord = 40, 6

    def available(self):
        try:
            import aerosandbox  # noqa: F401
        except Exception:
            return "pacote aerosandbox não instalado (pip install aerosandbox)"
        return None

    def strips(self, model, point):
        import aerosandbox as asb
        d_deg = np.array([point.de, point.da, point.dr], float)
        wings, owners = [], []
        for s in model.surfaces:
            af = asb.Airfoil(name=s.airfoil.name, coordinates=s.airfoil.outline())
            sides = (1, -1) if s.mirror else ((s.side if s.role == "device" else 0) or 1,)
            for side in sides:
                for k, xsecs in enumerate(_side_groups(s, side, d_deg, af)):
                    wings.append(asb.Wing(name=f"{s.name}/{side}/{k}", symmetric=False, xsecs=xsecs))
                    owners.append(s)
        ap = asb.Airplane(name=model.name, wings=wings, s_ref=model.S, c_ref=model.c, b_ref=model.b)
        # faixas do VLM por trecho entre estações: ~n_span por lado da superfície maior
        per_side = max(sum(len(w.xsecs) - 1 for w, o in zip(wings, owners) if o is s0 and w.name.split("/")[1] == "1")
                       for s0 in model.surfaces)
        ratio = max(2, int(round(self.n_span / max(per_side, 1))))
        op = asb.OperatingPoint(atmosphere=_atmosphere(point.rho), velocity=point.V, alpha=point.alpha,
                                beta=point.beta)
        vlm = asb.VortexLatticeMethod(airplane=ap, op_point=op, spanwise_resolution=ratio,
                                      chordwise_resolution=self.n_chord, spanwise_spacing_function=np.linspace)
        vlm.run()
        # painéis de cada asa: a mesma malha que o VLM faz (subdivide e malha fina; a corda varia mais rápido)
        counts = [len(w.subdivide_sections(ratio=ratio, spacing_function=np.linspace).mesh_thin_surface(
            method="quad", chordwise_resolution=self.n_chord, add_camber=True)[1]) for w in wings]
        body = lambda p: np.asarray(p, float) * np.array([-1.0, 1.0, -1.0])   # eixos do ASB (x trás, z cima) -> corpo
        F, FL, FR = body(vlm.forces_geometry), body(vlm.front_left_vertices), body(vlm.front_right_vertices)
        BL, BR = body(vlm.back_left_vertices), body(vlm.back_right_vertices)
        a, b = np.radians(point.alpha), np.radians(point.beta)
        Vr = point.V * np.array([np.cos(a) * np.cos(b), np.sin(b), np.sin(a) * np.cos(b)])  # avião em relação ao ar
        vh = Vr / np.linalg.norm(Vr)
        q = 0.5 * point.rho * point.V ** 2
        rows: dict[str, list] = {}
        k0, nc = 0, self.n_chord
        for s, n in zip(owners, counts):
            for j in range(n // nc):
                i0, i1 = k0 + j * nc, k0 + (j + 1) * nc
                le = 0.5 * (FL[i0] + FR[i0])
                te = 0.5 * (BL[i1 - 1] + BR[i1 - 1])
                chord = float(np.linalg.norm(le - te))
                ex = (le - te) / max(chord, 1e-12)
                sp = FR[i0] - FL[i0]
                sp = sp - np.dot(sp, ex) * ex
                width = float(np.linalg.norm(sp))
                if width < 1e-9:
                    continue
                ey = sp / width
                # sentido do núcleo: da esquerda para a direita; nas verticais, de baixo para cima
                if (s.vertical and ey[2] > 0) or (not s.vertical and ey[1] < 0):
                    ey = -ey
                pt = 0.75 * le + 0.25 * te
                rows.setdefault(s.name, []).append((-pt[2] if s.vertical else pt[1], width, chord, pt,
                                                    F[i0:i1].sum(axis=0), ey, ex))
            k0 += n
        out = []
        for s in model.surfaces:
            if s.name not in rows:
                continue
            R = sorted(rows[s.name], key=lambda r: r[0])
            col = lambda k: np.array([r[k] for r in R], float)
            sv, w, c, pts, Fs, ey, ex = (col(k) for k in range(7))
            lift_dir = np.cross(-vh, ey)                # Kutta–Joukowski: Γ > 0 sustenta (como no núcleo)
            lift_dir /= np.maximum(np.linalg.norm(lift_dir, axis=1), 1e-12)[:, None]
            L = np.sum(Fs * lift_dir, axis=1) / w
            D = (Fs @ -vh) / w
            cl, cd = L / (q * c), D / (q * c)
            a2d = s.airfoil.cl_alpha or 2 * np.pi
            a0 = 0.0 if s.vertical else s.airfoil.zero_lift_angle()
            n = len(sv)
            out.append(SurfaceLoad(name=s.name, role=s.role, vertical=bool(s.vertical), s=sv, width=w, chord=c,
                                   alpha=a0 + np.degrees(cl / a2d), V=np.full(n, point.V), q=np.full(n, q), cl=cl,
                                   cd=cd, L=L, D=D, points=pts, force=Fs, velocity=np.tile(Vr, (n, 1)),
                                   induced=np.zeros((n, 3)), span_dir=ey, chord_dir=ex, wash=np.zeros(n)))
        notes = ["carga pelo VLM do AeroSandbox: malha na corda e na envergadura; sem esteira de hélice e sem efeito "
                 "solo; comandos como torção das faixas; arrasto só o induzido; α efetivo = α0 + c_l/a do perfil"]
        return out, notes

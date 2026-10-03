"""Linha sustentadora não linear (Weissinger/Phillips-Snyder) do lltdrek
(https://github.com/kuodrek/lltdrek, licença MIT), com a polar 2D dos perfis gerada por
`sections.py`. Entram as superfícies horizontais simétricas (asa e EH, com a interação entre
elas); o lltdrek não tem derrapagem, então as derivadas em β ficam NaN, e EV e fuselagem não
entram (a fuselagem soma só o arrasto parasita, como nos outros)."""
from __future__ import annotations

import contextlib
import io
import math
import os
import tempfile
import time

import numpy as np

from aerosim.interfaces.aero import AeroCase, AeroPolar, IAeroSolver

from .geometry import nu_air, parasite_cd, reynolds, surface_stations, to_xz_up
from .sections import write_lltdrek_polar

H = 0.01
_patched = False


class _FastNumpy:
    """numpy com `cross` rápido para vetores de 3 componentes: o lltdrek chama np.cross
    ~10⁵ vezes por α em vetores soltos, e o np.cross genérico gasta ~15 µs em cada"""

    def __init__(self, np_mod):
        self._np = np_mod

    def __getattr__(self, k):
        return getattr(self._np, k)

    def cross(self, a, b, *args, **kw):
        if not args and not kw and np.ndim(a) == 1 and np.ndim(b) == 1 and len(a) == 3 and len(b) == 3:
            a0, a1, a2 = float(a[0]), float(a[1]), float(a[2])
            b0, b1, b2 = float(b[0]), float(b[1]), float(b[2])
            return np.array((a1 * b2 - a2 * b1, a2 * b0 - a0 * b2, a0 * b1 - a1 * b0))
        return self._np.cross(a, b, *args, **kw)


def _speedup() -> None:
    global _patched
    if _patched:
        return
    import importlib
    for m in ("lltdrek.simulation.main_equations", "lltdrek.models.post_processing", "lltdrek.models.wingpool",
              "lltdrek.utils.velocity"):
        try:
            mod = importlib.import_module(m)
        except Exception:
            continue
        if getattr(mod, "np", None) is np:
            mod.np = _FastNumpy(np)
    _patched = True


class LltdrekSolver(IAeroSolver):
    name = "lltdrek"
    title = "LLT não linear (lltdrek)"
    description = "linha sustentadora não linear com polar 2D por seção; asa + EH"

    def available(self):
        try:
            import lltdrek  # noqa: F401
        except Exception:
            return "pacote lltdrek não instalado (pip install git+https://github.com/kuodrek/lltdrek.git)"
        return None

    def _wings(self, ac, case: AeroCase, folder: str):
        from lltdrek import Wing
        wings = []
        for i, s in enumerate(ac.surfaces):
            if not s.enabled or s.vertical or not s.symmetric or len(s.sections) < 2:
                continue
            st = surface_stations(s)
            name = f"af{i}"
            cmin = min(q["chord"] for q in st)
            cmax = max(q["chord"] for q in st)
            Res = sorted({reynolds(case.V * k, cc, case.rho) for k in (0.5, 1.0, 2.0) for cc in (cmin, cmax)})
            write_lltdrek_polar(os.path.join(folder, name + ".txt"), s.airfoil, [Res[0], Res[len(Res) // 2], Res[-1]],
                                case.section)
            spans = [q1["y"] - q0["y"] for q0, q1 in zip(st, st[1:])]
            # mesmo número de painéis em todas: o corretor de Newton do lltdrek 1.2 indexa o bloco
            # espelhado com o N da superfície da linha (só funciona se todas tiverem o mesmo N)
            n = max(4, int(case.n_span))
            le = to_xz_up([s.x, 0.0, s.z])
            wings.append(Wing(spans=spans, chords=[q["chord"] for q in st], offsets=[q["x_offset"] for q in st],
                              twist_angles=[q["twist"] for q in st],
                              dihedral_angles=[s.dihedral] * len(spans), airfoils=[name] * len(st),
                              surface_name=s.name, N_panels=n, x_pos=le[0], z_pos=le[2],
                              distribution_type="cosine"))
        return wings

    def _run(self, ac, case, alphas, omega=(0.0, 0.0, 0.0)):
        from lltdrek import FlightCondition, PostProcessing, Simulation, WingPool, load_folder
        _speedup()
        S, c, b = ac.references()
        with tempfile.TemporaryDirectory() as folder:
            wings = self._wings(ac, case, folder)
            data, _ = load_folder(folder)
        fc = FlightCondition(V_inf=case.V, nu=nu_air(case.rho), rho=case.rho, angles_of_attack=list(alphas), h=0,
                             ground_effect_check=False, angular_velocity=list(omega))
        with contextlib.redirect_stdout(io.StringIO()):
            for w in wings:
                w.generate_mesh()
                w.setup_airfoil_data(fc, data)
            pool = WingPool(wings, fc, S_ref=S, c_ref=c, moment_ref=to_xz_up(case.ref))
            sim = Simulation(damping_factor=0.5, max_iter=200, max_residual=1e-4, show_logs=False,
                             simulation_mode="linear_first")
            res = sim.run(pool)
            co = PostProcessing.get_coefficients(pool, res, S, c)
        return wings, co

    def solve(self, ac, case: AeroCase) -> AeroPolar:
        t0 = time.perf_counter()
        S, c, b = ac.references()
        # a incidência de cada superfície entra como torção (o lltdrek não tem calagem separada)
        wings, co = self._run(ac, case, [float(a) for a in case.alphas])
        g = lambda k: np.array([getattr(r.global_coefficients.forces, k) for r in co])
        CL, CDi = g("CL"), g("CD")
        Cm = np.array([r.global_coefficients.moments.Cm for r in co])
        CD = CDi + parasite_cd(ac)
        # derivadas: α por diferenças, taxas pelo campo de rotação ω × r
        a = case.alpha_d
        da = 0.5
        _, cA = self._run(ac, case, [a - da, a + da])
        d = {}
        d["CLa"] = (cA[1].global_coefficients.forces.CL - cA[0].global_coefficients.forces.CL) / math.radians(2 * da)
        d["Cma"] = (cA[1].global_coefficients.moments.Cm - cA[0].global_coefficients.moments.Cm) / math.radians(2 * da)
        # ω no referencial do lltdrek (x trás, z cima): p' = −p, q' = q, r' = −r; o lltdrek usa a
        # velocidade livre unitária, então ω entra dividido por V
        for key, k, ref_len in (("p", 0, b), ("q", 1, c), ("r", 2, b)):
            w = H * 2 / ref_len
            om_p, om_m = [0.0] * 3, [0.0] * 3
            sgn = -1.0 if k != 1 else 1.0
            om_p[k], om_m[k] = sgn * w, -sgn * w
            _, cp = self._run(ac, case, [a], om_p)
            _, cm = self._run(ac, case, [a], om_m)
            fp, fm = cp[0].global_coefficients, cm[0].global_coefficients
            if key == "q":
                d["CLq"] = (fp.forces.CL - fm.forces.CL) / (2 * H)
                d["Cmq"] = (fp.moments.Cm - fm.moments.Cm) / (2 * H)
            else:
                # C_l, C_n do lltdrek: por S c e com eixos x, z invertidos
                d["Cl" + key] = -(fp.moments.Cl - fm.moments.Cl) / (2 * H) * c / b
                d["Cn" + key] = -(fp.moments.Cn - fm.moments.Cn) / (2 * H) * c / b
        span = None
        k0 = int(np.argmin(np.abs(np.asarray(case.alphas) - a)))
        wname = ac.wing.name if ac.wing is not None else None
        for w in wings:
            if w.surface_name == wname and co[k0].surface_coefficients:
                cl = np.asarray(co[k0].surface_coefficients[w.surface_name].cl_distribution, float)
                y = w.collocation_points[:, 1]
                span = dict(y=y, cl=cl, ccl=cl * w.cp_chords / c)
        return AeroPolar(self.name, np.asarray(case.alphas, float), CL, CD, Cm, CDi,
                         {k: float(v) for k, v in d.items()}, span=span,
                         notes="asa + EH (sem EV, sem fuselagem; C_D = induzido + C_D0 do modelo)",
                         elapsed=time.perf_counter() - t0)

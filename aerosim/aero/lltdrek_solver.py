"""lltdrek (https://github.com/kuodrek/lltdrek, MIT): linha sustentadora não linear
(Phillips-Snyder) com a polar 2D de cada perfil.

`LltdrekTranslator` é a ponte com o modelo universal:
  ida   — superfícies horizontais espelhadas do modelo (asa, EH) viram `Wing`s do lltdrek
          (eixos x para trás e z para cima, incidência como torção, polar 2D escrita em arquivo);
          o ponto de voo universal vira FlightCondition (velocidade unitária: ω entra dividido por V,
          e p' = −p, q' = q, r' = −r)
  volta — C_l e C_n do lltdrek são por S c e nos eixos invertidos: C_l = −C_l' c/b, C_n = −C_n' c/b;
          o C_D dele é só induzido: o C_D universal soma o C_D0 do modelo (o mesmo que o núcleo usa)
Não tem derrapagem nem superfícies verticais e fuselagem (o modelo é avisado nas notas).
"""
from __future__ import annotations

import contextlib
import io
import os
import tempfile
from collections import defaultdict

import numpy as np

from aerosim.interfaces.aero import AeroCase, FlightPoint
from aerosim.interfaces.translator import IModelTranslator

from .base import AeroSolverBase
from .geometry import nu_air, reynolds, to_xz_up
from .sections import airfoil_key, write_lltdrek_polar

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



def _kinks(st):
    """só as estações onde a geometria muda de inclinação ou o perfil muda (as outras são interpolação
    linear das vizinhas): o lltdrek 1.2 divide os painéis por partição e quebra com partições demais"""
    keep = [st[0]]
    for a, b, c in zip(st, st[1:], st[2:]):
        f = (b.s - a.s) / (c.s - a.s) if c.s > a.s else 0.0
        lin = lambda va, vc: va + f * (vc - va)
        same = (abs(lin(a.chord, c.chord) - b.chord) < 1e-9 and abs(lin(a.twist, c.twist) - b.twist) < 1e-9
                and np.allclose(lin(a.le, c.le), b.le, atol=1e-9)
                and _af_id(a.airfoil) == _af_id(b.airfoil) == _af_id(c.airfoil))
        if not same:
            keep.append(b)
    keep.append(st[-1])
    return keep


def _af_id(af) -> str:
    return "" if af is None else airfoil_key(af)


class LltdrekTranslator(IModelTranslator):
    name = "lltdrek"
    fidelity, cost = "llt", "caro"

    @staticmethod
    def surfaces(model):
        return [s for s in model.surfaces if s.role in ("wing", "htail") and s.mirror and not s.vertical]

    def to_native(self, model, case: AeroCase = None, folder: str = "", **_):
        """modelo universal -> lista de Wing (escreve a polar 2D de cada perfil em `folder`)"""
        from lltdrek import Wing
        wings = []
        n = max(4, int(case.n_span))      # o mesmo N em todas: o Newton do lltdrek 1.2 exige
        files: dict[tuple, str] = {}     # (perfil, faixa de Re) -> nome do arquivo de polar
        for i, s in enumerate(self.surfaces(model)):
            st = _kinks(s.stations)
            cs = [q.chord for q in st]
            Res = sorted({reynolds(case.V * k, cc, case.rho) for k in (0.5, 1.0, 2.0) for cc in (min(cs), max(cs))})
            Res = [Res[0], Res[len(Res) // 2], Res[-1]]
            names = []
            for q in st:                     # um arquivo por perfil diferente (perfil por seção)
                af = q.airfoil or s.airfoil
                k = (airfoil_key(af), tuple(round(r, -3) for r in Res))
                if k not in files:
                    files[k] = f"af{len(files)}"
                    write_lltdrek_polar(os.path.join(folder, files[k] + ".txt"), af, Res, case.section)
                names.append(files[k])
            root = st[0].le
            spans = [b.s - a.s for a, b in zip(st, st[1:])]
            le = to_xz_up(root)
            wings.append(Wing(spans=spans, chords=cs, offsets=[float(root[0] - q.le[0]) for q in st],
                              twist_angles=[q.twist for q in st], dihedral_angles=[s.dihedral] * len(spans),
                              airfoils=names, surface_name=s.name, N_panels=n, x_pos=le[0], z_pos=le[2],
                              distribution_type="cosine"))
        return wings

    @staticmethod
    def omega(model, pt: FlightPoint) -> list[float]:
        """taxas universais adimensionais -> ω do lltdrek (eixos x trás, z cima; V unitário)"""
        return [-pt.p * 2 / model.b, pt.q * 2 / model.c, -pt.r * 2 / model.b]

    def from_native(self, gc, model, **_) -> dict[str, float]:
        f, m = gc.forces, gc.moments
        k = model.c / model.b
        CDi = float(f.CD)
        return dict(CL=float(f.CL), CDi=CDi, CD=CDi + model.parasite_cd(), CY=float(f.CY), Cm=float(m.Cm),
                    Cl=-float(m.Cl) * k, Cn=-float(m.Cn) * k)


class LltdrekSolver(AeroSolverBase):
    name = "lltdrek"
    title = "LLT não linear (lltdrek)"
    description = "linha sustentadora não linear com polar 2D por seção; asa + EH"
    supports_beta = False
    fidelity, cost = "llt", "caro"        # caro: a polar vai para o cache em disco (aerosim/aero/service.py)
    notes = "asa + EH (sem EV, sem fuselagem; C_D = induzido + C_D0 do modelo)"
    translator = LltdrekTranslator()

    def available(self):
        try:
            import lltdrek  # noqa: F401
        except Exception:
            return "pacote lltdrek não instalado (pip install git+https://github.com/kuodrek/lltdrek.git)"
        return None

    def _run(self, model, case, alphas_deg, omega):
        from lltdrek import FlightCondition, PostProcessing, Simulation, WingPool, load_folder
        _speedup()
        with tempfile.TemporaryDirectory() as folder:
            wings = self.translator.to_native(model, case=case, folder=folder)
            data, _ = load_folder(folder)
        fc = FlightCondition(V_inf=case.V, nu=nu_air(case.rho), rho=case.rho, angles_of_attack=list(alphas_deg), h=0,
                             ground_effect_check=False, angular_velocity=list(omega))
        with contextlib.redirect_stdout(io.StringIO()):
            for w in wings:
                w.generate_mesh()
                w.setup_airfoil_data(fc, data)
            pool = WingPool(wings, fc, S_ref=model.S, c_ref=model.c, moment_ref=to_xz_up(case.ref))
            sim = Simulation(damping_factor=0.5, max_iter=200, max_residual=1e-4, show_logs=False,
                             simulation_mode="linear_first")
            res = sim.run(pool)
            co = PostProcessing.get_coefficients(pool, res, model.S, model.c)
        return wings, fc.angles_of_attack, co

    def evaluate(self, model, case: AeroCase, points: list[FlightPoint]):
        """os pontos com as mesmas taxas rodam juntos (uma FlightCondition por conjunto de taxas)"""
        groups = defaultdict(list)
        for i, pt in enumerate(points):
            groups[(pt.p, pt.q, pt.r)].append(i)
        out = [None] * len(points)
        nan = dict(CL=np.nan, CD=np.nan, CDi=np.nan, CY=np.nan, Cl=np.nan, Cm=np.nan, Cn=np.nan)
        for (p, q, r), idx in groups.items():
            om = self.translator.omega(model, points[idx[0]])
            alphas = [round(float(np.degrees(points[i].alpha)), 9) for i in idx]
            _, used, co = self._run(model, case, sorted(set(alphas)), om)
            by = {round(float(a), 9): c for a, c in zip(used, co)}
            for i, a in zip(idx, alphas):
                c = by.get(a)
                out[i] = self.translator.from_native(c.global_coefficients, model) if c is not None else dict(nan)
                for k, v in out[i].items():
                    if not np.isfinite(v):
                        out[i][k] = np.nan
        return out

    def span_load(self, model, case):
        """carregamento da asa no α das derivadas: y (m), c_l e c·c_l / c_ref"""
        w = model.wing
        if w is None:
            return None
        wings, used, co = self._run(model, case, [float(case.alpha_d)], [0.0, 0.0, 0.0])
        for wg in wings:
            if wg.surface_name == w.name and co and co[0].surface_coefficients:
                cl = np.asarray(co[0].surface_coefficients[wg.surface_name].cl_distribution, float)
                return dict(y=wg.collocation_points[:, 1], cl=cl, ccl=cl * wg.cp_chords / model.c)
        return None

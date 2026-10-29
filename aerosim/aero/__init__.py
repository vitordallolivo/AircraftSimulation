"""Aerodinâmica a partir da geometria: comparação de métodos (modelo interno, lltdrek,
AeroSandbox, AVL, polar importada do XFLR5), métricas da polar e dispositivos de ponta de asa (plano de
Trefftz). Polar 2D dos perfis em `sections`; cache das polares 3D em `service`."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.aero import DERIVATIVES, AeroCase, AeroPolar, IAeroSolver

from .asb_solver import AsbBuildupSolver, AsbLiftingLineSolver, AsbVLMLoads, AsbVLMSolver
from .avl_solver import AvlSolver
from .llt_solver import CoreLLTSolver
from .lltdrek_solver import LltdrekSolver
from .xflr5_import import Xflr5PolarFile
from .zig_solver import ZigPanelSolver


def all_solvers(backend) -> list[IAeroSolver]:
    return [ZigPanelSolver(backend), LltdrekSolver(), AsbVLMSolver(), AsbBuildupSolver(), AsbLiftingLineSolver(),
            AvlSolver(), CoreLLTSolver(backend), CoreLLTSolver(backend, gh=True)]


def all_load_methods(backend, refine: bool = True) -> list:
    """os métodos de carga ao longo das superfícies (interfaces/loads.py: ILoadMethod), na ordem da aba Cargas"""
    from .span_loads import CoreLoadMethod
    return [CoreLoadMethod(backend, llt=True, refine=refine), CoreLoadMethod(backend, llt=True, refine=refine, gh=True),
            CoreLoadMethod(backend, llt=True, refine=refine, nonlinear=True),
            CoreLoadMethod(backend, llt=False, refine=refine), AsbVLMLoads()]


def load_method(backend, name: str, refine: bool = True):
    """o método de carga pelo nome ou pelo título"""
    ms = all_load_methods(backend, refine)
    m = next((m for m in ms if name in (m.name, m.title)), None)
    if m is None:
        raise ValueError(f"método de carga desconhecido: {name!r} ({' | '.join(x.name for x in ms)})")
    return m


def parabolic_polar(pol: AeroPolar, a_lo: float = -2.0, a_hi: float = 8.0) -> dict[str, float]:
    """ajuste C_D = C_D0 + k C_L² no trecho linear de qualquer polar universal; C_Lmax; C_L em α = 0"""
    ok = np.isfinite(pol.CL) & np.isfinite(pol.CD)
    sel = ok & (pol.alpha >= a_lo) & (pol.alpha <= a_hi)
    k, CD0 = np.polyfit(pol.CL[sel] ** 2, pol.CD[sel], 1)
    return dict(CD0=float(CD0), k=float(k), CLmax=float(np.nanmax(pol.CL[ok])),
                CL_a0=float(np.interp(0.0, pol.alpha[ok], pol.CL[ok])))


def solver_by_name(backend, name: str) -> IAeroSolver:
    return next(s for s in all_solvers(backend) if s.name == name or s.title == name)


def polar_metrics(pol: AeroPolar, model, case: AeroCase) -> dict[str, float]:
    """C_L0, C_Lα, C_Lmax, α_estol, C_D mín., (L/D)máx., e (ajuste C_Di = C_L²/(π AR e)),
    ponto neutro x_np = x_ref + c C_mα / C_Lα e margem estática (x_ref − x_np)/c"""
    S, c, b = model.S, model.c, model.b
    AR = b * b / S
    a, CL, CD, CDi = pol.alpha, pol.CL, pol.CD, pol.CDi
    ok = np.isfinite(CL)
    lin = ok & (a >= -2.0) & (a <= 6.0)
    out: dict[str, float] = {}
    if lin.sum() >= 2:
        k, c0 = np.polyfit(np.radians(a[lin]), CL[lin], 1)
        out["CL0"], out["CLa_fit"] = float(c0), float(k)
    if ok.any():
        i = int(np.nanargmax(np.where(ok, CL, -np.inf)))
        out["CLmax"] = float(CL[i])
        out["alpha_stall"] = float(a[i])
        out["CDmin"] = float(np.nanmin(CD[ok]))
        LD = np.where(ok & (CD > 0), CL / CD, np.nan)
        if np.isfinite(LD).any():
            out["LDmax"] = float(np.nanmax(LD))
    sel = lin & np.isfinite(CDi) & (np.abs(CL) > 0.15)
    if sel.sum() >= 2:
        K = float(np.polyfit(CL[sel] ** 2, CDi[sel], 1)[0])
        if K > 0:
            out["e"] = 1.0 / (math.pi * AR * K)
    CLa, Cma = pol.deriv("CLa"), pol.deriv("Cma")
    if math.isfinite(CLa) and math.isfinite(Cma) and abs(CLa) > 1e-9:
        x_np = case.ref[0] + c * Cma / CLa
        out["x_np"] = x_np
        out["x_np_mac"] = 100 * model.mac_frac(x_np)
        out["SM"] = 100 * (case.ref[0] - x_np) / c
    return out


__all__ = ["DERIVATIVES", "AeroCase", "AeroPolar", "AsbBuildupSolver", "AsbLiftingLineSolver", "AsbVLMSolver", "AvlSolver",
           "CoreLLTSolver",
           "IAeroSolver", "LltdrekSolver", "ZigPanelSolver", "all_solvers", "parabolic_polar", "polar_metrics",
           "solver_by_name", "Xflr5PolarFile"]

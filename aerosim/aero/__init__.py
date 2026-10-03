"""Aerodinâmica a partir da geometria: comparação de métodos (núcleo Zig, lltdrek,
AeroSandbox), métricas da polar e dispositivos de ponta de asa (plano de Trefftz)."""
from __future__ import annotations

import math

import numpy as np

from aerosim.interfaces.aero import DERIVATIVES, AeroCase, AeroPolar, IAeroSolver

from .asb_solver import AsbBuildupSolver, AsbLiftingLineSolver, AsbVLMSolver
from .geometry import mac_frac, mac_info, mac_ref, parasite_cd, tail_volumes, x_at_mac
from .lltdrek_solver import LltdrekSolver
from .zig_solver import ZigPanelSolver


def all_solvers(backend) -> list[IAeroSolver]:
    return [ZigPanelSolver(backend), LltdrekSolver(), AsbVLMSolver(), AsbBuildupSolver(), AsbLiftingLineSolver()]


def polar_metrics(pol: AeroPolar, ac, case: AeroCase) -> dict[str, float]:
    """C_L0, C_Lα, C_Lmax, α_estol, C_D mín., (L/D)máx., e (ajuste C_Di = C_L²/(π AR e)),
    ponto neutro x_np = x_ref + c C_mα / C_Lα e margem estática (x_ref − x_np)/c"""
    S, c, b = ac.references()
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
        out["x_np_mac"] = 100 * mac_frac(ac, x_np)
        out["SM"] = 100 * (case.ref[0] - x_np) / c
    return out


__all__ = ["DERIVATIVES", "AeroCase", "AeroPolar", "AsbBuildupSolver", "AsbLiftingLineSolver", "AsbVLMSolver",
           "IAeroSolver", "LltdrekSolver", "ZigPanelSolver", "all_solvers", "mac_frac", "mac_info", "mac_ref",
           "parasite_cd", "polar_metrics", "tail_volumes", "x_at_mac"]

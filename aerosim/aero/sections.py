"""Polar 2D dos perfis para os solvers de linha sustentadora.

"modelo": a mesma hipótese do núcleo, em 2D — c_l = a0 (α − α_L0) até perto do estol,
misturado com a placa plana 2 sen²α cos α pela função sigmoide de Beard e McLain
(Small Unmanned Aircraft, 2012, eq. 4.10), com α de transição ajustado para que o pico
seja o c_l,max do perfil.
"neuralfoil": c_l, c_d, c_m do contorno real (.dat) pela rede do NeuralFoil
(Sharpe, 2023), que vem com o AeroSandbox.
"""
from __future__ import annotations

import math
from functools import lru_cache

import numpy as np

from aerosim.model.airfoil import Airfoil

M_BLEND = 50.0


def _sigma(al, a0, M=M_BLEND):
    e1 = np.exp(np.clip(-M * (al - a0), -50, 50))
    e2 = np.exp(np.clip(M * (al + a0), -50, 50))
    return (1 + e1 + e2) / ((1 + e1) * (1 + e2))


def _cl_model(al, a_lin, cl0, a0):
    sg = _sigma(al, a0)
    return (1 - sg) * (cl0 + a_lin * al) + sg * 2 * np.sign(al) * np.sin(al) ** 2 * np.cos(al)


@lru_cache(maxsize=64)
def _stall_angle(a_lin: float, cl0: float, clmax: float) -> float:
    al = np.linspace(0, 0.9, 3000)
    lo, hi = 0.02, 0.8
    for _ in range(50):
        a0 = 0.5 * (lo + hi)
        if _cl_model(al, a_lin, cl0, a0).max() > clmax:
            hi = a0
        else:
            lo = a0
    return 0.5 * (lo + hi)


def model_polar(af: Airfoil, alphas_deg) -> dict[str, np.ndarray]:
    a_lin = af.cl_alpha
    cl0 = -a_lin * math.radians(af.zero_lift_angle())
    a0 = _stall_angle(round(a_lin, 6), round(cl0, 6), round(af.cl_max, 6))
    al = np.radians(np.asarray(alphas_deg, float))
    cl = _cl_model(al, a_lin, cl0, a0)
    sg = _sigma(al, a0)
    cd = af.cd0 + sg * 1.2 * np.sin(al) ** 2
    return dict(alpha=np.asarray(alphas_deg, float), cl=cl, cd=cd, cm=np.full_like(cl, af.moment_ac()))


def neuralfoil_polar(af: Airfoil, alphas_deg, Re: float) -> dict[str, np.ndarray]:
    import neuralfoil as nf
    a = np.asarray(alphas_deg, float)
    r = nf.get_aero_from_coordinates(coordinates=af.outline(), alpha=a, Re=Re, model_size="large")
    return dict(alpha=a, cl=np.asarray(r["CL"], float), cd=np.asarray(r["CD"], float),
                cm=np.asarray(r["CM"], float))


def section_polar(af: Airfoil, alphas_deg, Re: float, source: str = "modelo") -> dict[str, np.ndarray]:
    if source == "neuralfoil":
        return neuralfoil_polar(af, alphas_deg, Re)
    return model_polar(af, alphas_deg)


def write_lltdrek_polar(path: str, af: Airfoil, Res: list[float], source: str = "modelo") -> None:
    """arquivo de polar no formato do lltdrek: blocos  RE,<Re> / cm0,<cm0> / α,c_l ... / linha vazia"""
    al = np.arange(-20.0, 25.01, 0.5)
    with open(path, "w") as f:
        for Re in Res:
            p = section_polar(af, al, Re, source)
            cm0 = float(np.interp(0.0, p["alpha"], p["cm"]))
            f.write(f"RE,{Re:.6g}\ncm0,{cm0:.6f}\n")
            for a, cl in zip(p["alpha"], p["cl"]):
                f.write(f"{a:.3f},{cl:.6f}\n")
            f.write("\n")

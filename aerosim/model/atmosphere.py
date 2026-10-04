"""Atmosfera padrão (ISA, troposfera) para a altitude-densidade (AD).

A AD é a altitude da atmosfera padrão que tem a mesma densidade do ar do dia; é como a
competição e as equipes descrevem o ar. ρ = ρ0 (1 − 2,25577·10⁻⁵ h)^4,25588.
"""
from __future__ import annotations

import math

RHO0 = 1.225                 # kg/m³ ao nível do mar
_K = 2.25577e-5              # 1/m
_N = 4.25588


def isa_density(h: float) -> float:
    """densidade (kg/m³) na altitude h (m) da atmosfera padrão (troposfera; h até ~11 km)"""
    h = min(max(float(h), -2000.0), 11000.0)
    return RHO0 * (1.0 - _K * h) ** _N


def density_altitude(rho: float) -> float:
    """altitude-densidade (m) do ar com densidade rho (kg/m³)"""
    if not (rho > 0 and math.isfinite(rho)):
        return 0.0
    return (1.0 - (rho / RHO0) ** (1.0 / _N)) / _K

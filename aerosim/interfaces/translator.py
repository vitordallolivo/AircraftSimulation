"""Tradutores: modelo universal (`aerosim.model.universal.AircraftModel`) <-> formato de cada solver.

Todo solver/núcleo tem um. `to_native` leva o modelo para o que o solver entende (spec do núcleo
Zig, asas do lltdrek, Airplane do AeroSandbox...); `from_native` traz o que ele devolveu para o
formato universal — coeficientes nos eixos do corpo do simulador (x à frente, y à direita, z para
baixo), C_l e C_n por S b, C_m por S c, derivadas por p̂ = p b/2V, q̂ = q c/2V, r̂ = r b/2V, ângulos em
rad, chaves CL, CD, CY, Cl, Cm, Cn, CDi, CN (e as de `aerosim.interfaces.aero.DERIVATIVES`).
Assim nenhuma camada acima conhece o formato de nenhum solver.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from aerosim.model.universal import AircraftModel

COEFFS = ("CL", "CD", "CY", "Cl", "Cm", "Cn", "CDi", "CN")


class IModelTranslator(ABC):
    name: str = ""

    @abstractmethod
    def to_native(self, model: "AircraftModel", **options) -> Any: ...

    @abstractmethod
    def from_native(self, raw: Any, model: "AircraftModel", **context) -> dict[str, float]:
        """um resultado nativo -> coeficientes universais"""

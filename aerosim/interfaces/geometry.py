"""Contrato da checagem de geometria do avião montado: se as peças cabem juntas, antes da aerodinâmica.

Quem implementa `IGeometryCheck` recebe o modelo universal (`aerosim.model.universal.AircraftModel`) e os
`GeometryParams` e devolve um `GeometryReport`: as hélices que acertam alguma peça, as massas concentradas fora de
toda a geometria, os pedaços soltos (peças sem nada que as ligue ao resto) e a folga ao chão parado e girado no trem
principal até o ângulo de rotação. Hoje a implementação é a do núcleo (`aerosim/backend/zig/geometry.py`,
`core/src/geometry`); a lista de motivos (`reasons`) é o que o aeroopt escreve na coluna "motivo".
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass
class GeometryParams:
    rotation: float = 12.0          # atitude do corpo (°, nariz para cima) na rotação da decolagem; o MDO antigo da
                                    # equipe usava 20° menos a incidência da asa
    clearance: float = 0.0          # folga mínima de qualquer peça ao chão (m)
    prop_clearance: float = 0.02    # folga mínima da ponta da hélice ao chão (m)
    contact_tol: float = 0.005      # duas peças a menos disso se encostam (m)
    hub: float = 0.035              # a hélice está presa à peça que tem o centro dela a menos disso (m): não a acerta
    masses: bool = True             # confere se cada massa concentrada está dentro de alguma peça
    connected: bool = True          # False: os pedaços soltos aparecem no relatório, mas não reprovam


@dataclass
class GeometryReport:
    ok: bool
    reasons: list[str] = field(default_factory=list)
    prop_hits: list[tuple[str, str]] = field(default_factory=list)     # (hélice, peça)
    outside: list[str] = field(default_factory=list)                   # massas fora da geometria
    groups: list[list[str]] = field(default_factory=list)              # pedaços (1 = o avião é uma peça só)
    ground: list[tuple[str, float, str]] = field(default_factory=list)  # (atitude, folga em m, peça mais baixa)

    def why(self) -> str:
        return "; ".join(self.reasons)


class IGeometryCheck(ABC):
    name: str = ""

    @abstractmethod
    def check(self, model, params: GeometryParams | None = None) -> GeometryReport: ...

    def check_many(self, models, params: GeometryParams | None = None) -> list[GeometryReport]:
        return [self.check(m, params) for m in models]

"""Entrada padrão das análises de carga aerodinâmica: o que os gráficos de carga e a vista 3D aceitam.

Qualquer método que produza um `LoadResult` alimenta os mesmos gráficos e a mesma vista 3D, sem mudar nada neles:
hoje o núcleo por faixas (`aerosim/aero/span_loads.py`, `to_result`); amanhã um VLM, um método de painéis ou um CFD
(lendo o arquivo de saída e montando a malha com os valores).

Duas partes:

    SpanDistribution   uma por superfície: valores ao longo da envergadura (s em metros) — para os gráficos.
                       Um método com malha na corda (painéis, CFD) integra na corda para chegar aqui.
    SurfaceField       a malha 3D (vértices + faces) com valores por face, camadas de vetores e tubos — para a
                       vista 3D. Faixas do núcleo viram uma face cada; uma malha de CFD entra como está.

Eixos do corpo do simulador (x à frente, y à direita, z para baixo), SI. Campos com nome e unidade:

    CAMPOS["carga"]     sustentação por área (N/m²) — a carga alar local
    CAMPOS["L"]         sustentação por metro de envergadura (N/m)
    CAMPOS["alpha_ef"]  ângulo de ataque efetivo (°), com downwash, comandos e modificadores
    CAMPOS["V_rel"]     velocidade local / V∞
    CAMPOS["cl"], CAMPOS["cd"], CAMPOS["q"] (Pa), CAMPOS["D"] (N/m)

Um método pode pôr campos a mais (ex.: "cp" de um CFD); quem desenha mostra o que existir.
"""
from __future__ import annotations

from dataclasses import dataclass
from dataclasses import field as _field

import numpy as np

CAMPOS: dict[str, tuple[str, str, bool]] = {
    # nome -> (rótulo, unidade, com sinal: mapa divergente centrado em zero)
    "carga": ("carga alar local (sustentação por área)", "N/m²", True),
    "L": ("sustentação por metro de envergadura", "N/m", True),
    "alpha_ef": ("ângulo de ataque efetivo", "°", True),
    "V_rel": ("velocidade local / V∞", "—", False),
    "cl": ("c_l local", "—", True),
    "cd": ("c_d local", "—", False),
    "q": ("pressão dinâmica local", "Pa", False),
    "D": ("arrasto por metro de envergadura", "N/m", False),
}


def label(name: str) -> str:
    lab, unit, _ = CAMPOS.get(name, (name, "", True))
    return f"{lab} ({unit})" if unit and unit != "—" else lab


@dataclass
class SpanDistribution:
    surface: str
    role: str                                  # wing | htail | vtail | device
    vertical: bool
    s: np.ndarray                              # posição ao longo da envergadura (m): y nas horizontais, altura nas verticais
    width: np.ndarray                          # largura de cada ponto (m), para integrar
    fields: dict[str, np.ndarray] = _field(default_factory=dict)

    def integral(self, name: str) -> float:
        """∫ campo ds (ex.: "L" dá a sustentação da superfície em N)"""
        return float(np.sum(np.asarray(self.fields[name]) * self.width))


@dataclass
class VectorLayer:
    name: str                                  # "força", "velocidade induzida", ...
    origins: np.ndarray                        # (n, 3) corpo, m
    vectors: np.ndarray                        # (n, 3) corpo, na unidade de `unit`
    unit: str = ""
    color: tuple = (0.1, 0.1, 0.1, 1.0)


@dataclass
class SurfaceField:
    vertices: np.ndarray                       # (N, 3) corpo, m
    faces: np.ndarray                          # (M, 3) ou (M, 4) índices em `vertices`
    fields: dict[str, np.ndarray] = _field(default_factory=dict)   # nome -> (M,) um valor por face
    face_surface: np.ndarray | None = None     # (M,) nome da superfície de cada face
    vectors: list[VectorLayer] = _field(default_factory=list)
    tubes: list[dict] = _field(default_factory=list)   # {"name", "centers" (k, 3), "radius" (k,)} — esteiras

    def triangles(self) -> tuple[np.ndarray, np.ndarray]:
        """faces em triângulos e, para cada triângulo, a face de origem (para repetir os valores)"""
        F = np.asarray(self.faces, int)
        if F.shape[1] == 3:
            return F, np.arange(len(F))
        tri = np.vstack([F[:, [0, 1, 2]], F[:, [0, 2, 3]]])
        return tri, np.r_[np.arange(len(F)), np.arange(len(F))]


@dataclass
class LoadResult:
    distributions: list[SpanDistribution] = _field(default_factory=list)
    field: SurfaceField | None = None
    meta: dict = _field(default_factory=dict)   # "fonte", "fidelidade", "caso" (texto), "V", "peso"...

    def distribution(self, surface: str) -> SpanDistribution:
        return next(d for d in self.distributions if d.surface == surface)

    def by_role(self, role: str) -> list[SpanDistribution]:
        return [d for d in self.distributions if d.role == role]

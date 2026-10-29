"""Entrada padrão das análises de carga aerodinâmica: o que os gráficos de carga e a vista 3D aceitam.

Qualquer método que produza um `LoadResult` alimenta os mesmos gráficos e a mesma vista 3D, sem mudar nada neles.
Um método implementa `ILoadMethod`: recebe o modelo universal e um `LoadPoint` (o ponto de voo já resolvido:
trimagem e hélices, o mesmo para todos os métodos) e devolve o `LoadResult`. Hoje: o núcleo (linha sustentadora e
faixas, `aerosim/aero/span_loads.py`) e o VLM do AeroSandbox (`aerosim/aero/asb_solver.py`); a lista fica em
`aerosim.aero.all_load_methods`. Um método de painéis ou um CFD (lendo o arquivo de saída) entra do mesmo jeito.

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

from abc import ABC, abstractmethod
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
    "imersao": ("fração dentro do tubo de alguma hélice", "—", False),
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


# ---------------------------------------------------------------------- métodos de carga
# o que um método pode modelar; o que ele não modela vira aviso na aba (ex.: "VLM: sem esteira da hélice")
SUPPORTS: dict[str, str] = {
    "esteira": "esteira da hélice nas superfícies",
    "solo": "efeito solo",
    "comandos": "deflexão dos comandos",
    "corda": "distribuição na corda (malha na corda)",
    "estol": "estol da seção",
}


@dataclass
class LoadPoint:
    """o ponto de voo já resolvido, igual para todos os métodos (quem resolve: `aerosim.aero.span_loads.prepare`).
    Ângulos em graus, SI"""
    V: float
    alpha: float
    beta: float = 0.0
    de: float = 0.0
    da: float = 0.0
    dr: float = 0.0
    rho: float = 1.225
    n: float = 1.0
    weight: float = 0.0                        # N
    props: list = _field(default_factory=list)  # estado de cada motor (rotação, tração, torque, eixo, cubo)
    props_on: bool = True                      # as superfícies veem a hélice (tração e esteira)
    trim: dict | None = None                   # a trimagem do núcleo, se α veio dela
    notes: list[str] = _field(default_factory=list)


@dataclass
class WingSweep:
    """a varredura das asas em α (subaba Asas): o que cada método entrega para o resumo do núcleo
    (`ISimBackend.wing_sweep_summary`). Um "dono" é uma superfície horizontal escolhida; os painéis são as faixas de
    todos os donos, na ordem do método"""
    alpha: np.ndarray                          # graus
    owners: list[str]                          # nome de cada dono
    owner_lift: np.ndarray                     # (α, dono): sustentação (N)
    owner_area: np.ndarray                     # (dono): área (m²)
    owner_chord: np.ndarray                    # (dono): corda média aerodinâmica (m)
    section_cl: np.ndarray                     # (α, painel): c_l local
    panel_owner: np.ndarray                    # (painel): índice do dono
    panel_span: np.ndarray                     # (painel): posição ao longo da envergadura (m)


def owner_of(name: str, owners: list[str]) -> int:
    """índice do dono de uma distribuição pelo nome (igual, senão o nome mais longo que começa o dela, para "asa de
    cima" não cair em "asa"); −1 se nenhum"""
    if name in owners:
        return owners.index(name)
    best = max((o for o in owners if name.startswith(o)), key=len, default=None)
    return owners.index(best) if best is not None else -1


class ILoadMethod(ABC):
    """um método de carga aerodinâmica ao longo das superfícies"""
    name: str = ""
    title: str = ""
    source: str = ""                           # de onde vem o método (obra ou programa)
    supports: frozenset = frozenset()          # chaves de SUPPORTS

    def available(self) -> str | None:
        """None se pode rodar; senão o motivo (ex.: pacote não instalado)"""
        return None

    def missing(self, wanted) -> list[str]:
        """o que, de `wanted` (chaves de SUPPORTS), este método não modela, em texto"""
        return [SUPPORTS[k] for k in wanted if k not in self.supports]

    @abstractmethod
    def compute(self, model, point: LoadPoint) -> LoadResult:
        """a carga do modelo universal `model` no ponto `point`"""

    def sweep(self, model, V: float, alphas, rho: float, owners: list[str]) -> WingSweep:
        """a varredura das asas: cada α (graus) imposto, sem hélice, só as superfícies `owners`. Padrão: um
        `compute` por α; o núcleo faz a varredura inteira numa chamada"""
        alphas = np.asarray(alphas, float)
        surf = {s.name: s for s in model.aircraft.surfaces}
        lift = np.zeros((len(alphas), len(owners)))
        rows, panel_owner, panel_span = [], None, None
        for a_i, a in enumerate(alphas):
            res = self.compute(model, LoadPoint(V=V, alpha=float(a), rho=rho, props=[], props_on=False))
            cl, own, span = [], [], []
            for d in res.distributions:
                k = owner_of(d.surface, owners)
                if k < 0 or d.role == "device" or d.vertical:
                    continue
                lift[a_i, k] += d.integral("L")
                cl.append(np.asarray(d.fields.get("cl", np.full(len(d.s), np.nan)), float))
                own.append(np.full(len(d.s), k))
                span.append(np.asarray(d.s, float))
            rows.append(np.concatenate(cl) if cl else np.zeros(0))
            if panel_owner is None:
                panel_owner = np.concatenate(own).astype(np.int32) if own else np.zeros(0, np.int32)
                panel_span = np.concatenate(span) if span else np.zeros(0)
        n = min((len(r) for r in rows), default=0)
        return WingSweep(alphas, list(owners), lift, np.array([surf[o].area for o in owners]),
                         np.array([surf[o].mac for o in owners]), np.array([r[:n] for r in rows]).reshape(len(rows), n),
                         panel_owner[:n], panel_span[:n])

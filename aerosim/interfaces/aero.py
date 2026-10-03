"""Interface dos solvers aerodinâmicos (comparativo da aba Aerodinâmica).

Um solver recebe a aeronave (modelo de dados, independente do núcleo) e um caso
(V, varredura de α, ponto de referência dos momentos) e devolve a polar e as
derivadas de estabilidade, sempre nos eixos do corpo do simulador (x à frente,
y à direita, z para baixo) e com as adimensionalizações usuais:
  p̂ = p b / 2V,  q̂ = q c / 2V,  r̂ = r b / 2V;  C_l, C_n por S b;  C_m por S c.
Quem não calcula alguma derivada devolve NaN nela.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import numpy as np

# derivadas (1/rad) que os solvers tentam preencher
DERIVATIVES = ("CLa", "Cma", "CYb", "Clb", "Cnb", "CLq", "Cmq", "CYp", "Clp", "Cnp", "CYr", "Clr", "Cnr",
               "CLde", "Cmde", "Clda", "Cnda", "CYdr", "Cldr", "Cndr")


@dataclass
class AeroCase:
    V: float = 15.0
    alphas: np.ndarray = field(default_factory=lambda: np.arange(-6.0, 16.01, 1.0))   # graus
    alpha_d: float = 2.0                  # α onde as derivadas são tomadas (graus)
    ref: tuple[float, float, float] = (0.0, 0.0, 0.0)   # ponto dos momentos (corpo, m) — em geral o CG
    rho: float = 1.225
    section: str = "modelo"               # polar 2D dos perfis: "modelo" (linear + estol) | "neuralfoil"
    n_span: int = 20                      # painéis por semiasa (LLT/VLM)


@dataclass
class AeroPolar:
    solver: str
    alpha: np.ndarray                     # graus
    CL: np.ndarray
    CD: np.ndarray
    Cm: np.ndarray
    CDi: np.ndarray                       # parte induzida (NaN se o solver não separa)
    derivs: dict[str, float] = field(default_factory=dict)
    span: dict[str, np.ndarray] | None = None    # carregamento da asa: y (m), cl, ccl (c·cl / c_ref)
    notes: str = ""
    elapsed: float = 0.0

    def deriv(self, k: str) -> float:
        return float(self.derivs.get(k, float("nan")))


class IAeroSolver(ABC):
    name: str = ""
    title: str = ""
    description: str = ""

    def available(self) -> str | None:
        """None se pode rodar; senão o motivo (ex.: pacote não instalado)"""
        return None

    @abstractmethod
    def solve(self, ac, case: AeroCase) -> AeroPolar: ...

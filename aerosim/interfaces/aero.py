"""Interface dos solvers aerodinâmicos (comparativo da aba Aerodinâmica).

Um solver recebe a aeronave (modelo de dados, independente do núcleo) e um caso
(V, varredura de α, ponto de referência dos momentos) e devolve a polar e as
derivadas de estabilidade, sempre nos eixos do corpo do simulador (x à frente,
y à direita, z para baixo) e com as adimensionalizações usuais:
  p̂ = p b / 2V,  q̂ = q c / 2V,  r̂ = r b / 2V;  C_l, C_n por S b;  C_m por S c.
Quem não calcula alguma derivada devolve NaN nela.

Abaixo do 3D fica a polar 2D dos perfis (`ISectionPolar`): os métodos de linha sustentadora e a etapa Perfil
pedem c_l, c_d, c_m de um perfil num Re, e quem responde é uma fonte (modelo, NeuralFoil, arquivo...).
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import numpy as np

# derivadas (1/rad) que os solvers tentam preencher
DERIVATIVES = ("CLa", "Cma", "CYb", "Clb", "Cnb", "CLq", "Cmq", "CYp", "Clp", "Cnp", "CYr", "Clr", "Cnr",
               "CLde", "Cmde", "Clda", "Cnda", "CYdr", "Cldr", "Cndr")


@dataclass(frozen=True)
class FlightPoint:
    """ponto de voo universal: α, β (rad); p̂ = p b/2V, q̂ = q c/2V, r̂ = r b/2V; δe, δa, δr (rad)"""
    alpha: float
    beta: float = 0.0
    p: float = 0.0
    q: float = 0.0
    r: float = 0.0
    de: float = 0.0
    da: float = 0.0
    dr: float = 0.0


@dataclass
class AeroCase:
    V: float = 15.0
    alphas: np.ndarray = field(default_factory=lambda: np.arange(-6.0, 16.01, 1.0))   # graus
    alpha_d: float = 2.0                  # α onde as derivadas são tomadas (graus)
    ref: tuple[float, float, float] = (0.0, 0.0, 0.0)   # ponto dos momentos (corpo, m) — em geral o CG
    rho: float = 1.225
    section: str = "modelo"               # polar 2D dos perfis: "modelo" (linear + estol) | "neuralfoil"
    n_span: int = 20                      # painéis por semiasa (LLT/VLM)


FIDELITY = {"modelo": 0, "llt": 1, "vlm": 2, "painel": 3, "cfd": 4, "ensaio": 5}


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
    source: str = ""                      # de onde veio: "calculado", "cache", "arquivo <nome>"...
    fidelity: str = ""                    # uma chave de FIDELITY (para calibrar o barato pelo caro)

    def deriv(self, k: str) -> float:
        return float(self.derivs.get(k, float("nan")))


class IAeroSolver(ABC):
    """um método aerodinâmico. Recebe o modelo universal (`AircraftModel`), nunca a configuração;
    o tradutor do solver faz a ida e a volta"""
    name: str = ""
    title: str = ""
    description: str = ""
    # o que o método sabe calcular (o resto sai NaN nas derivadas)
    supports_beta: bool = True
    supports_rates: bool = True
    supports_controls: bool = False
    # "sprint": método rápido do ciclo; "detalhado": comparação/estudo (ex.: AeroSandbox)
    level: str = "sprint"
    fidelity: str = "llt"                 # chave de FIDELITY
    cost: str = "barato"                  # "caro": o resultado vale ir para o disco (aerosim.aero.service)
    version: int = 1                      # mude quando o método mudar o que calcula (invalida o cache)
    includes_fuselage: bool = False       # os coeficientes já têm a fuselagem (o núcleo); os de fora, não

    def available(self) -> str | None:
        """None se pode rodar; senão o motivo (ex.: pacote não instalado)"""
        return None

    @abstractmethod
    def evaluate(self, model, case: AeroCase, points: list[FlightPoint]) -> list[dict[str, float]]:
        """coeficientes universais (CL, CD, CY, Cl, Cm, Cn, CDi) em cada ponto"""

    @abstractmethod
    def solve(self, model, case: AeroCase) -> AeroPolar: ...


class ISectionPolar(ABC):
    """uma fonte de polar 2D de perfil. `polar` devolve {'alpha' (graus), 'cl', 'cd', 'cm'} nos α pedidos
    (NaN fora do que a fonte cobre)"""
    name: str = ""
    title: str = ""
    fidelity: str = "modelo"
    cost: str = "barato"                  # "caro": vale guardar em disco (aerosim.aero.sections)

    def available(self, af, polar_file: str = "") -> str | None:
        """None se a fonte serve para este perfil; senão o motivo"""
        return None

    @abstractmethod
    def polar(self, af, alphas_deg, Re: float, polar_file: str = "") -> dict[str, np.ndarray]: ...

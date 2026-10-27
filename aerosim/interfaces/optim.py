"""Contratos do aeroopt (o otimizador): o problema, a pontuação, o avaliador e o solver.

Um problema de otimização é sempre a mesma frase: escolher valores para as variáveis livres, dentro dos limites,
de modo que a pontuação seja a maior possível sem violar as restrições. `OptProblem` guarda essa frase; o resto
são peças trocáveis atrás de uma interface:

    IScoring    a nota (um arquivo de pontuação por regulamento, ou um objetivo simples como MTOW)
    IEvaluator  o avião candidato → as grandezas (massas, desempenho...), no núcleo
    ISolver     quem propõe os candidatos (PSO, busca aleatória, métodos locais)
    IStage      uma etapa de um processo em etapas: todos os candidatos passam por ela, e a próxima só começa
                quando o último chega (a barreira); dentro da etapa cada candidato roda em paralelo

Isolar: uma variável só entra na busca quando está livre (`free`). As outras ficam no valor do avião, então dá
para otimizar uma variável só, um grupo (`group`: asa, propulsão...) ou tudo.

    pr = OptProblem(variables=[OptVariable("wing.span", lo=1.2, hi=1.8, group="asa"),
                               OptVariable("power.tilt", lo=0, hi=8, group="propulsão")])
    pr.isolate("asa")                     # só a envergadura fica livre
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import asdict, dataclass, field

VAR_KINDS = ("contínua", "inteira", "lista")
OPS = ("≤", "≥", "=")
FORMAT = "aeroopt/1"          # versão do arquivo .opt.json


@dataclass
class OptVariable:
    key: str                                   # entrada do projeto (as chaves de `design.registry.INPUTS`)
    kind: str = "contínua"                     # VAR_KINDS
    lo: float = 0.0
    hi: float = 1.0
    options: list[str] = field(default_factory=list)   # "lista": os itens que a busca pode escolher (vazio = todos)
    group: str = ""                            # para isolar um grupo inteiro
    free: bool = False                         # False: fica no valor do avião


@dataclass
class OptConstraint:
    key: str                                   # grandeza (as chaves de `design.registry.QUANTITIES`)
    op: str = "≤"                              # OPS
    value: float = 0.0
    active: bool = True
    tol: float = 0.02                          # "=": tolerância relativa


@dataclass
class OptProblem:
    name: str = ""
    variables: list[OptVariable] = field(default_factory=list)
    constraints: list[OptConstraint] = field(default_factory=list)
    scoring: str = "MTOW"                      # objetivo simples (MTOW, EE) ou arquivo de pontuação (.toml)
    evaluator: str = "mini-MDO"
    solver: dict = field(default_factory=dict)     # método e opções (partículas, iterações, semente, penalidade)
    params: dict = field(default_factory=dict)     # parâmetros fixos do problema (tipo de aeronave, densidade...)

    def free_variables(self) -> list[OptVariable]:
        return [v for v in self.variables if v.free]

    def variable(self, key: str) -> OptVariable | None:
        return next((v for v in self.variables if v.key == key), None)

    def isolate(self, *names: str) -> list[str]:
        """só as variáveis com estas chaves ou destes grupos ficam livres; devolve as chaves livres"""
        unknown = [n for n in names if not any(n in (v.key, v.group) for v in self.variables)]
        if unknown:
            raise KeyError(f"variável ou grupo desconhecido: {', '.join(unknown)}")
        for v in self.variables:
            v.free = v.key in names or (bool(v.group) and v.group in names)
        return [v.key for v in self.free_variables()]

    def to_dict(self) -> dict:
        return dict(formato=FORMAT, **asdict(self))

    @classmethod
    def from_dict(cls, d: dict) -> OptProblem:
        fmt = d.get("formato", FORMAT)
        if fmt != FORMAT:
            raise ValueError(f"formato {fmt!r} não reconhecido (esperado {FORMAT!r})")
        return cls(name=d.get("name", ""),
                   variables=[OptVariable(**v) for v in d.get("variables", [])],
                   constraints=[OptConstraint(**c) for c in d.get("constraints", [])],
                   scoring=d.get("scoring", "MTOW"), evaluator=d.get("evaluator", "mini-MDO"),
                   solver=dict(d.get("solver", {})), params=dict(d.get("params", {})))


@dataclass
class OptResult:
    rows: list[dict]                           # cada avaliação: variáveis, grandezas, nota, viável
    best: dict                                 # a melhor, avaliada por inteiro
    names: dict = field(default_factory=dict)  # o que os índices das listas querem dizer


class IScoring(ABC):
    """a nota de um candidato a partir das grandezas que o avaliador calcula"""
    name: str = ""
    source: str = ""                           # obra, seção e página

    @abstractmethod
    def quantities(self) -> list[str]:
        """as grandezas que a nota usa"""

    @abstractmethod
    def program(self) -> dict:
        """a nota no formato que o núcleo executa"""


class IEvaluator(ABC):
    """o candidato (valores das variáveis livres) → as grandezas, calculadas no núcleo"""
    name: str = ""

    @abstractmethod
    def quantities(self) -> list[str]:
        """o que este avaliador sabe calcular"""


Progress = Callable[[int, list], None]


class ISolver(ABC):
    name: str = ""

    @abstractmethod
    def run(self, problem: OptProblem, evaluator: IEvaluator, progress: Progress | None = None,
            cancel: Callable[[], bool] | None = None) -> OptResult:
        """procura o melhor candidato; `progress(iteração, avaliações)` a cada iteração"""


@dataclass
class StageItem:
    """um candidato andando pelas etapas: o que já se sabe dele vai se acumulando em `data`"""
    name: str
    values: dict = field(default_factory=dict)    # as variáveis que definem este candidato
    data: dict = field(default_factory=dict)      # o que cada etapa deixou (avião, massas, nota...)
    alive: bool = True                            # False: parou numa etapa (o motivo em `why`)
    why: str = ""
    stage: str = ""                               # a última etapa por onde passou


class IStage(ABC):
    """uma etapa. Ou trata um candidato por vez (`one`, que o processo roda em paralelo), ou o lote inteiro de uma
    vez (`batch = True` e `run`, quando a conta é melhor em lote, como a nota no núcleo). `select` roda depois da
    barreira, com todos os candidatos da etapa prontos"""
    name: str = ""
    batch: bool = False
    parallel: str = "processos"                   # "processos", "threads" ou "não"

    def one(self, item: StageItem) -> StageItem:
        raise NotImplementedError

    def run(self, items: list[StageItem]) -> list[StageItem]:
        return [self.one(i) for i in items]

    def select(self, items: list[StageItem]) -> list[StageItem]:
        return items


class IFailureDiagnosis(ABC):
    """o diagnóstico da falha de um ponto: dos códigos dos termos violados (`aeroopt.stages.violation_terms`), as
    variáveis que os consertam. É o que a busca guiada (aeroopt/guided.py) usa para mutar e reparar só o que importa"""

    @abstractmethod
    def remedies(self, codes, free) -> list[str]:
        """as variáveis de `free` (chaves) que mexem nos termos `codes`, da que mais mexe para a que menos mexe"""

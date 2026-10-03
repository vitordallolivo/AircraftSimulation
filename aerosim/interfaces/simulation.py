"""Interface de uma simulação (plugin do Simulation Manager) e do próprio manager.

Cada simulação declara:
  - `parameters()`: o que a GUI deve mostrar para configurá-la (gera o formulário);
  - `plots()`: o que desenhar em tempo real e no fim;
  - `run(ctx)`: como roda (que etapas, de onde reroda, o que itera).
`parameters_for(aeronave)` e `plots_for(aeronave)` deixam o formulário e os gráficos dependerem
da configuração (ex.: sem EH não há dimensionamento de EH; com elevon, o elevon é dimensionado
para arfagem e rolagem juntos); a GUI refaz a aba quando a aeronave muda.
O resultado pode trazer um diagnóstico (`checks`): cada critério com estado, valor, critério,
causa e o que mudar — é isso que diz se a configuração serve e por quê.
A GUI cria uma aba por simulação registrada, sem conhecer nenhuma delas.
"""
from __future__ import annotations

import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Callable

if TYPE_CHECKING:
    from aerosim.interfaces.backend import ISimBackend, LogChunk
    from aerosim.manager.checkpoints import CheckpointStore
    from aerosim.model.aircraft import Aircraft


@dataclass
class ParamSpec:
    """um parâmetro de simulação (vira um campo na aba)"""
    key: str
    label: str
    default: Any
    kind: str = "float"            # float | int | bool | choice | floats (lista "a, b, c")
    minimum: float | None = None
    maximum: float | None = None
    step: float | None = None
    unit: str = ""
    choices: tuple = ()
    help: str = ""


@dataclass
class PlotSpec:
    """um gráfico: eixo x e curvas y (nomes de canais do registro ou de séries do resultado)"""
    key: str
    title: str
    x: str
    ys: tuple[str, ...]
    xlabel: str = ""
    ylabel: str = ""
    live: bool = True              # atualiza enquanto roda (canais do registro)
    source: str = "log"            # log | series:<nome> | series:<prefixo>* | series:* (séries do resultado)
    scatter: bool = False
    swap: bool = False             # desenha as ys na horizontal e x na vertical (ex.: V × altitude)


@dataclass
class Check:
    """um item do diagnóstico"""
    status: str                     # "ok" | "atencao" | "falha" | "info"
    item: str                       # o que foi verificado
    value: str                      # valor obtido (texto já formatado)
    criterion: str                  # o critério usado e a fonte
    why: str = ""                   # por que deu esse resultado (causa física)
    fix: str = ""                   # o que mudar, com números quando possível
    group: str = ""                 # seção (ex.: "estática longitudinal")


@dataclass
class SimResult:
    """saída de uma simulação"""
    log: "LogChunk | None" = None                         # registro no tempo (se houver)
    series: dict[str, dict[str, Any]] = field(default_factory=dict)   # tabelas extras (nome -> colunas)
    summary: dict[str, Any] = field(default_factory=dict)            # números para mostrar
    events: dict[str, float] = field(default_factory=dict)
    status: str = "ok"
    checks: list[Check] = field(default_factory=list)                 # diagnóstico


class CancelledError(Exception):
    pass


@dataclass
class RunContext:
    """o que uma simulação recebe para rodar"""
    backend: "ISimBackend"
    aircraft: "Aircraft"
    params: dict[str, Any]
    checkpoints: "CheckpointStore"
    on_chunk: Callable[["LogChunk"], None] = lambda c: None       # pedaço novo do registro (tempo real)
    on_progress: Callable[[float, str], None] = lambda f, msg: None
    cancel: threading.Event = field(default_factory=threading.Event)

    def check(self) -> None:
        if self.cancel.is_set():
            raise CancelledError()


class ISimulation(ABC):
    name: str = ""          # identificador (chave no registro)
    title: str = ""         # nome na aba
    description: str = ""

    @abstractmethod
    def parameters(self) -> list[ParamSpec]: ...

    @abstractmethod
    def plots(self) -> list[PlotSpec]: ...

    @abstractmethod
    def run(self, ctx: RunContext) -> SimResult: ...

    def parameters_for(self, aircraft: "Aircraft | None") -> list[ParamSpec]:
        """campos que fazem sentido para esta aeronave (padrão: os mesmos sempre)"""
        return self.parameters()

    def plots_for(self, aircraft: "Aircraft | None") -> list[PlotSpec]:
        return self.plots()

    def defaults(self, aircraft: "Aircraft | None" = None) -> dict[str, Any]:
        ps = self.parameters_for(aircraft) if aircraft is not None else self.parameters()
        return {p.key: p.default for p in ps}


class ISimulationManager(ABC):
    """o que a GUI chama"""

    @abstractmethod
    def simulations(self) -> list[ISimulation]: ...

    @abstractmethod
    def get(self, name: str) -> ISimulation: ...

    @abstractmethod
    def run(self, name: str, aircraft: "Aircraft", params: dict[str, Any] | None = None,
            on_chunk: Callable | None = None, on_progress: Callable | None = None,
            cancel: threading.Event | None = None) -> SimResult: ...

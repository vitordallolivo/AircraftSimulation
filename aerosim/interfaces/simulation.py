"""Interface de uma simulação (plugin do Simulation Manager) e do próprio manager.

Cada simulação declara:
  - `parameters()`: o que a GUI deve mostrar para configurá-la (gera o formulário);
  - `plots()`: o que desenhar em tempo real e no fim;
  - `run(ctx)`: como roda (que etapas, de onde reroda, o que itera).
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
class SimResult:
    """saída de uma simulação"""
    log: "LogChunk | None" = None                         # registro no tempo (se houver)
    series: dict[str, dict[str, Any]] = field(default_factory=dict)   # tabelas extras (nome -> colunas)
    summary: dict[str, Any] = field(default_factory=dict)            # números para mostrar
    events: dict[str, float] = field(default_factory=dict)
    status: str = "ok"


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

    def defaults(self) -> dict[str, Any]:
        return {p.key: p.default for p in self.parameters()}


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

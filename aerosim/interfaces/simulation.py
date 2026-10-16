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

Estilo das séries (chaves opcionais começando com "_" em cada tabela): `_color`, `_width`, `_dash`,
`_fill` (coluna do outro lado da faixa) e `_strong`, `_marker`/`_symbol` ("o", "star", "s", "t", "d",
"+", "x") e `_size`, `_label` (texto da legenda), `_nolegend`; linhas e faixas de referência sem
colunas: `_vline` (x), `_hline` (y), `_vspan` ([x0, x1], ex.: fundo de cada etapa do voo); escala:
`_xlim`, `_ylim` ([mín, máx]: as curvas ficam inteiras, só a janela do gráfico é limitada).
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
    kind: str = "float"            # float | int | bool | choice | floats (lista "a, b, c") | file (caminho) | table
    minimum: float | None = None
    maximum: float | None = None
    step: float | None = None
    unit: str = ""
    choices: tuple = ()
    help: str = ""
    group: str = ""                # seção do formulário (ex.: "Critérios")
    rebuild: bool = False          # mudar este campo refaz o formulário (ex.: escolher a norma)
    columns: tuple = ()            # table: ((chave, rótulo, "float" | "str" | "label" | (opções...)[, dica]), ...); valor: lista de dicts
    bound: bool = False            # table: espelha a aeronave (muda quando ela muda; edição volta por `commit`)
    level: str = ""                # "sprint" (análise rápida do ciclo) ou "detalhado"; "" = o da simulação (`level_of`)


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
    kind: str = "2d"               # 2d | 3d (trajetória: x, ys[0], z) | loads3d (LoadResult em "_result" da série)
    z: str = ""                    # 3d: canal/coluna vertical
    live_ys: tuple[str, ...] = ()  # gráfico de séries: canais do registro desenhados enquanto roda
    live_x: str = ""               # eixo x desses canais (padrão: x)
    aspect: bool = False           # escalas iguais nos dois eixos (planos da trajetória)
    invert_y: bool = False
    height: int = 0                # altura do gráfico (px); 0: padrão da aba


@dataclass
class Check:
    """um item do diagnóstico"""
    status: str                     # "ok" | "atencao" | "falha" | "info"
    item: str                       # o que foi verificado
    value: str                      # valor obtido (texto já formatado)
    criterion: str                  # o limite usado (curto)
    why: str = ""                   # por que deu esse resultado (causa física)
    fix: str = ""                   # o que mudar, com números quando possível
    group: str = ""                 # seção (ex.: "estática longitudinal")
    source: str = ""                # de onde vem o critério (norma, livro) ou "definido na aba"


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
    shared: dict = field(default_factory=dict)     # resultados que uma aba deixa para outra (ex.: a polar)

    def check(self) -> None:
        if self.cancel.is_set():
            raise CancelledError()


# áreas do ciclo de projeto (quem é dono de cada análise) e os dois níveis de análise
AREAS = ("dimensionamento", "aerodinamica", "estabilidade", "propulsao", "desempenho", "cargas", "estruturas", "massas",
         "pontuacao", "missao")
LEVELS = ("sprint", "detalhado")


class ISimulation(ABC):
    name: str = ""          # identificador (chave no registro)
    tab: bool = True        # False: registrada (scripts, testes, outras abas a usam) mas sem aba própria
    title: str = ""         # nome na aba
    description: str = ""
    area: str = ""          # uma de AREAS: a área dona da análise
    level: str = "sprint"   # "sprint": entra no ciclo rápido; "detalhado": estudo mais fundo (fica para depois)
    detailed: tuple[str, ...] = ()   # campos do formulário que são do nível detalhado (o resto é sprint)
    show_aircraft: bool = False      # a aba mostra o avião em 3D (com a troca entre aviões abertos)

    def level_of(self, p: "ParamSpec") -> str:
        """nível de um campo: o dele, se marcado; senão detalhado se estiver em `detailed`, senão o da simulação"""
        if p.level:
            return p.level
        return "detalhado" if p.key in self.detailed else self.level

    @abstractmethod
    def parameters(self) -> list[ParamSpec]: ...

    @abstractmethod
    def plots(self) -> list[PlotSpec]: ...

    @abstractmethod
    def run(self, ctx: RunContext) -> SimResult: ...

    def parameters_for(self, aircraft: "Aircraft | None", values: dict | None = None) -> list[ParamSpec]:
        """campos que fazem sentido para esta aeronave e para as escolhas já feitas no formulário
        (`values`, ex.: norma escolhida); padrão: os mesmos sempre"""
        return self.parameters()

    def plots_for(self, aircraft: "Aircraft | None", values: dict | None = None) -> list[PlotSpec]:
        """gráficos para esta aeronave e para as escolhas do formulário (ex.: o modo da análise)"""
        return self.plots()

    def commit(self, aircraft: "Aircraft", values: dict) -> bool:
        """grava na aeronave o que do formulário pertence a ela (ex.: a trajetória editada na aba Missão);
        True se mudou algo"""
        return False

    def defaults(self, aircraft: "Aircraft | None" = None, values: dict | None = None) -> dict[str, Any]:
        ps = self.parameters_for(aircraft, values) if aircraft is not None else self.parameters()
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

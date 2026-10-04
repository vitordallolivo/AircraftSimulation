# aerosim/interfaces — contratos entre as camadas

Só classes abstratas e tipos de dados; nenhuma implementação. Quem usa uma camada depende daqui, nunca
do módulo concreto.

## Como chamar

Ninguém instancia estas classes: elas dizem o que cada camada precisa ter. Trocar uma camada é
passar outro objeto que cumpra a interface — por exemplo um núcleo falso nos testes:

```python
from aerosim.interfaces import ISimBackend
from aerosim.manager import SimulationManager

class MeuNucleo(ISimBackend):
    ...                                        # open_session, limits, log_channels, translator
m = SimulationManager(MeuNucleo())             # o manager e a GUI funcionam iguais
```

`tests/manager/test_orchestration.py` faz isso com um `FakeBackend`.

## Como funciona

```mermaid
flowchart LR
    subgraph IF["interfaces"]
        direction TB
        SM["simulation.py<br/>ISimulationManager · ISimulation<br/>ParamSpec · PlotSpec · SimResult · RunContext"]
        BE["backend.py<br/>ISimBackend · ISimSession<br/>LogChunk · RunStatus · TrimKind · SimSpec"]
        AS["aircraft_source.py<br/>IAircraftSource · ICatalogSource"]
    end
    GUI["gui"] -->|usa| SM
    GUI -->|usa| AS
    MAN["manager"] -->|implementa| SM
    MAN -->|usa| BE
    ZIG["backend/zig"] -->|implementa| BE
    FAKE["tests: FakeBackend"] -->|implementa| BE
    DATA["data"] -->|implementa| AS
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class SM,BE,AS iface
    style IF fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

| interface | métodos principais |
|---|---|
| `ISimBackend` | `open_session()`, `limits()`, `log_channels()` |
| `ISimSession` | `configure(spec)`, `reset_ground()`, `reset_air(seg)`, `run(t_limit, max_rows)`, `events()`, `snapshot()`/`restore()`, `trim()`, `performance()`, `aero_coeffs()`, `aero_coeffs_ex()` (rotação e ponto de referência), `linearize(V)` (A, B), `prop_point()`, `mass_props()` |
| `IModelTranslator` (`translator.py`) | `to_native(modelo universal)` → formato do solver; `from_native(resultado)` → coeficientes universais (eixos do corpo, C_l/C_n por S b, C_m por S c, taxas p̂ q̂ r̂) |
| `ISimBackend.translator`, `session_for(modelo)` | todo núcleo tem um tradutor; a sessão já vem configurada a partir do modelo universal |
| `IAeroSolver` (`aero.py`) | `available()`, `evaluate(modelo, caso, [FlightPoint])` → coeficientes universais; `solve(modelo, caso)` → `AeroPolar` (polar e derivadas pelo código comum `aero/base.py`) |
| `ISimulation` | `parameters_for(aeronave)` → campos da aba, `plots_for(aeronave)` → gráficos (dependem da configuração; a GUI refaz a aba quando ela muda), `run(ctx)` → `SimResult` (registro, tabelas, resumo e `checks`: diagnóstico com estado, valor, critério, causa e correção) |
| `ISimulationManager` | `simulations()`, `get(nome)`, `run(nome, aeronave, params, on_chunk, on_progress, cancel)` |

Cada análise diz a área do projeto (`ISimulation.area`, uma de `AREAS`) e o nível: `level = "sprint"`
(conta rápida, para comparar muitas variantes) ou `"detalhado"`; dentro de uma análise sprint,
`detailed` lista os parâmetros que só valem no detalhado (`level_of(p)` responde; `ParamSpec.level`
força um parâmetro). `IAeroSolver.level` faz o mesmo para os métodos de aerodinâmica (AeroSandbox é
detalhado). É só para o código (filtros, otimização, testes) — a GUI não escreve isso.
| `IAircraftSource` / `ICatalogSource` | `load(path)` / `save(obj, path)` |

`SimSpec` é um dicionário aninhado em SI/radianos com os nomes dos campos do núcleo; quem o monta é
`aerosim/backend/zig/translator.py` (o tradutor do núcleo Zig, a partir do modelo universal).

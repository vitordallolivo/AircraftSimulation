# aerosim/interfaces — contratos entre as camadas

Só classes abstratas e tipos de dados; nenhuma implementação. Quem usa uma camada depende daqui, nunca
do módulo concreto.

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
| `ISimSession` | `configure(spec)`, `reset_ground()`, `reset_air(seg)`, `run(t_limit, max_rows)`, `events()`, `snapshot()`/`restore()`, `trim()`, `performance()`, `aero_coeffs()`, `prop_point()`, `mass_props()` |
| `ISimulation` | `parameters()` → campos da aba, `plots()` → gráficos, `run(ctx)` → `SimResult` |
| `ISimulationManager` | `simulations()`, `get(nome)`, `run(nome, aeronave, params, on_chunk, on_progress, cancel)` |
| `IAircraftSource` / `ICatalogSource` | `load(path)` / `save(obj, path)` |

`SimSpec` é um dicionário aninhado em SI/radianos com os nomes dos campos do núcleo; quem o monta é
`aerosim/model/compile.py`.

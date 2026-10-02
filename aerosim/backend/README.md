# aerosim/backend — ponte para o núcleo (camada Sim)

`ZigBackend` implementa `ISimBackend`/`ISimSession` sobre `libaerosim` via ctypes. Nenhuma struct é
copiada à mão: `abi.py` lê o esquema que o núcleo gera em comptime, monta as classes ctypes e confere
tamanho e offset de cada campo.

```mermaid
flowchart LR
    subgraph API["interface (aerosim/interfaces/backend.py)"]
        direction TB
        IB["ISimBackend"]
        IS["ISimSession"]
    end
    ZB["zig/backend.py<br/>ZigBackend · ZigSession<br/>build() compila se preciso"]
    ABI["zig/abi.py<br/>esquema → ctypes / numpy dtype<br/>write(dict → struct), read()"]
    LIB[("core/zig-out/lib/libaerosim")]
    IB --> ZB
    IS --> ZB
    ZB --> ABI
    ZB --> LIB
    ABI --> LIB
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class IB,IS iface
    style API fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

- `configure(spec)`: zera os parâmetros, escreve o dicionário (chave desconhecida é erro) e chama
  `aerosim_configure`. Erros do núcleo viram `CoreError` com a mensagem.
- `run(t_limit, max_rows)`: devolve `RunStatus` e um `LogChunk` (uma coluna numpy por canal; vetores
  como `rpm` viram `rpm_0`, `rpm_1`…). `max_rows=0` roda sem registro (mais rápido).
- As chamadas ctypes soltam o GIL: sessões diferentes rodam em paralelo em threads (as simulações de
  varredura usam isso).
- Para outro núcleo (outra linguagem, um modelo de teste), implemente `ISimBackend` e passe para
  `SimulationManager(backend)`.

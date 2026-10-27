# tests — uma pasta por camada

```mermaid
flowchart LR
    subgraph FIX["comum"]
        direction TB
        CF["conftest.py<br/>backend, manager, planilha"]
        HL["helpers/<br/>legacy_spec · sheet_fixtures"]
    end
    CORE["core/<br/>grupos do Zig · LUT · ABI<br/>sessão · polinômio · C original"]
    MODEL["model/<br/>perfis · geometria · massa"]
    DATA["data/<br/>formatos · mapa de células"]
    MAN["manager/<br/>simulações · checkpoints<br/>backend falso"]
    GUI["gui/<br/>offscreen"]
    CF --> CORE & MODEL & DATA & MAN & GUI
    HL --> CORE & DATA & MAN
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class CF,HL iface
    style FIX fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

```sh
python -m pytest                       # tudo menos medições de tempo
python -m pytest tests/core            # uma camada
python -m pytest -m lut                # só LUTs e aproximações
python -m pytest -m bench -s           # medições (LUT x std, custo de f(t,x)); imprime os tempos
python -m pytest -m legacy             # comparação com o simulador C original (gcc + make)
```

| arquivo | o que testa |
|---|---|
| `core/test_zig_groups.py` | `zig build test -Dgrupo=math`, `physics`, `control`, `sim` |
| `core/test_lut.py` | LUTs isoladas: mesmo resultado que a std (sequencial e aleatório), tempos (`bench`) |
| `core/test_abi.py` | esquema, ordem dos termos do polinômio, erros de configuração, slots |
| `core/test_session.py` | checkpoint exato, fatias = corrida inteira, trimagem, começo em voo |
| `core/test_poly_thrust.py` | tração polinomial no núcleo = conta do Python; densidade; decola |
| `core/test_legacy.py` | decolagem igual à do simulador C original |
| `model/*` | perfil fino, `.dat`, painéis, sinais dos comandos, malhas, massa, tanque quadrado |
| `data/*` | ida e volta `.json/.cfg/.xlsx`, catálogo, planilha Dados_Desempenho (campos e aba Tracao) |
| `manager/*` | todas as simulações, missão das três aeronaves, retomar de checkpoint, cancelar, backend falso |
| `manager/test_envelope.py` | envelope "como na planilha" = `Envelope_main` original transcrito (`helpers/envelope_reference.py`), altitude por altitude; caso que quebra o original; modelo completo |
| `core/test_linearize.py` | coeficientes com rotação e transporte de momento; modelo linear (cinemática, estabilidade, trimagem) |
| `aero/test_tipdevices.py` | plano de Trefftz: elíptica e = 1, caixa h/b = 0,2 (Kroo), placa de ponta = Raymer, momento na raiz |
| `aero/test_solvers.py` | sinais das derivadas do núcleo; lltdrek e VLM concordam com o núcleo em C_Lα e C_mq (pulados se não instalados) |
| `stability/test_stability.py` | ponto neutro numérico × analítico, tesoura (EH maior → limite traseiro para trás), classificação de modos e MIL-F-8785C numa matriz conhecida, tempo de inclinação, aileron por faixas × núcleo |
| `gui/*` | janela, edição, abas de simulação (incl. Aerodinâmica e Estabilidade), editor de tração polinomial |

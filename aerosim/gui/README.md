# aerosim/gui — interface gráfica (PyQt6 + pyqtgraph)

Só conhece `ISimulationManager` (para rodar) e as fontes de dados (para abrir/salvar). Cada aba de
simulação é gerada pelo que a simulação declara em `parameters()` e `plots()`.

## Como chamar

```sh
python -m aerosim.gui                          # aeronave convencional
python -m aerosim.gui data/aircraft/twin_boom.cfg
QT_QPA_PLATFORM=offscreen python -m pytest tests/gui   # sem tela
xvfb-run -a python tools/capturas.py capturas/         # foto de cada aba
```

Por código (ex.: num script de teste):

```python
from aerosim.gui.state import AppState
from aerosim.gui.main_window import MainWindow
st = AppState(manager, aeronave)
w = MainWindow(st); w.show()
st.notify("geometry"); st.undo(); st.redo()    # toda mudança passa por AppState (Ctrl+Z)
```

## Como funciona

```mermaid
flowchart LR
    subgraph API["interfaces usadas"]
        direction TB
        ISM["ISimulationManager"]
        SRC["load_aircraft / save_aircraft<br/>CellMapAircraftSource"]
    end
    APP["app.py<br/>python -m aerosim.gui"]
    MW["main_window.py<br/>menus, abas"]
    ST["state.py<br/>AppState: aeronave, catálogo, sinais"]
    CT["tabs/config_tab.py<br/>componentes | 3D | editor"]
    STAB["tabs/simulation_tab.py<br/>formulário, QThread, tempo real"]
    V3D["widgets/view3d.py<br/>malhas, seleção, arraste"]
    PS["widgets/param_slider.py<br/>campos numéricos, DataclassForm, dicas ⓘ"]
    PL["widgets/plots.py<br/>LivePlots"]
    APP --> MW --> ST
    MW --> CT & STAB
    CT --> V3D & PS
    STAB --> PL
    STAB --> ISM
    CT --> ISM
    MW --> SRC
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class ISM,SRC iface
    style API fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

- **Configuração (três colunas):** à esquerda a lista de componentes e as informações (massa, CG,
  inércias, aerodinâmica, pista...); no meio `AircraftView`, que desenha as malhas de
  `model/geometry.py` (eixos do corpo → tela: `(x, −y, −z)`), escolhe o componente mais perto do clique
  e move no plano da câmera (ou travado em x, y, z); à direita o editor do componente, um `DataclassForm`
  (um campo por número da dataclass; rótulos curtos com a explicação no ⓘ). As informações são
  recalculadas 300 ms depois da última edição.
- **Desfazer:** `AppState` guarda o estado de antes de cada mudança (`notify`/`touch`) — a aeronave e os
  valores das abas registradas (`register`); Ctrl+Z/Ctrl+Y em `main_window.py`.
- **Tração:** em cada motor, "motor + hélice" (catálogo) ou "polinômio de tração" (conjuntos do
  catálogo, vindos da aba `Tracao`); os 21 coeficientes são editáveis numa tabela.
- **Simulações:** `SimulationTab` roda `manager.run` numa `QThread`; cada fatia do registro chega por
  sinal e é desenhada a ~15 Hz; ao terminar mostra o resumo e as séries; "Exportar CSV" grava tudo.
- Sem tela (servidor, CI): `QT_QPA_PLATFORM=offscreen` (o 3D não desenha, o resto funciona).

# aerosim/model — configuração e modelo universal da aeronave

Duas coisas, nesta ordem:

1. **`Aircraft`** (`aircraft.py`): a configuração que o usuário edita (dataclasses em SI, ângulos em graus) —
   superfícies por seções, comandos, dispositivos, motores, trem, tanques...
2. **`AircraftModel`** (`universal.py`, `build_model(ac)`): o **modelo universal**, construído uma única vez
   a partir da configuração. É o que todo núcleo e todo solver recebe. Superfícies viram estações 3D
   (bordo de ataque, corda, torção total, coordenada de envergadura), com espelho, comandos por faixa e
   coeficientes do perfil já resolvidos; dispositivos (winglet, placa, cerca) já chegam como superfícies;
   referências S, c, b e a CMA; massa seca, CG e inércia; downwash.

Ninguém fora de `universal.py` deriva geometria da configuração: o núcleo Zig, o lltdrek e o AeroSandbox
recebem o `AircraftModel` pelos **tradutores** (`IModelTranslator`), que levam ao formato de cada um e
trazem o resultado de volta em formato universal. Um teste (`tests/test_architecture.py`) garante isso.

## Como chamar

```python
from aerosim.model import TEMPLATES, Aircraft, LiftingSurface, ControlSurface
from aerosim.model.aircraft import rect_sections
from aerosim.model.universal import build_model

ac = TEMPLATES["conventional"]()               # ou "flying_wing", "twin_boom"; ou load_aircraft(arquivo)
ac.surfaces.append(LiftingSurface(name="canard", role="htail", x=0.8, sections=rect_sections(0.3, 0.15),
                                  controls=[ControlSurface("elevator", 0.0, 1.0, 0.3)]))
model = build_model(ac)                        # modelo universal: o que todo solver recebe
model.S, model.c, model.b, model.mass["m"], model.mass["cg"]
[ (s.name, len(s.stations)) for s in model.surfaces ]
ac.mission.segments()                          # percurso → segmentos do núcleo
```

## Como funciona

```mermaid
flowchart LR
    subgraph API["interface do módulo"]
        direction TB
        AC["aircraft.py<br/>Aircraft (configuração)"]
        UM["universal.py<br/>build_model → AircraftModel"]
    end
    AF["airfoil.py<br/>.dat, NACA, perfil fino"]
    CAT["catalog.py<br/>Motor, Propeller, Battery,<br/>ThrustPoly (poly55), Catalog"]
    MIS["mission.py<br/>pernas → segmentos"]
    DEV["devices.py<br/>pernas de winglet/placa/cerca"]
    FT["features.py<br/>o que a aeronave tem"]
    GEO["geometry.py<br/>malhas 3D (do modelo), arraste"]
    MP["massprops.py<br/>massa seca, Steiner"]
    TPL["templates.py<br/>convencional, asa voadora, bimotor"]
    SER["serialize.py<br/>dataclass ⇄ dict"]
    AC --> AF & CAT & MIS
    UM --> AC & DEV & MP & FT
    GEO --> UM
    TPL --> AC
    UM --> T["tradutores<br/>(backend/zig, aero/*)"]
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class AC,UM iface
    style API fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

### Aeronave

| componente | campos principais |
|---|---|
| `LiftingSurface` | papel (`wing`, `htail`, `vtail`), posição do bordo de ataque da raiz, `sections` (y, corda, recuo, torção), diedro, incidência, `airfoil`, `controls`, sobrescritas `CLa`, `CL0`, `CLmax`, `CD0`, `Cmac`, `eps0`, `depsda` |
| `ControlSurface` | `aileron`, `elevator`, `rudder`, `elevon`, `ruddervator`, `flap`; início/fim (fração da semi-envergadura), fração da corda |
| `PropulsionUnit` | posição, inclinação do eixo, sentido; `thrust_model = "motor"` (motor + hélice + bateria) ou `"poly"` (`ThrustPoly`) |
| `LandingGear` | `tricycle`, `conventional` ou `custom` (pontos livres) |
| `SloshTank` | base quadrada (lado) ou cilíndrica, altura do líquido |
| `MassModel` | massa base + inércia própria + massas pontuais (+ motores/baterias/estrutura, se ligado) |
| `Fuselage`, `TailBoom`, `Payload`, `Environment`, `Takeoff`, `Autopilot`, `SimSettings`, `Mission` | — |

### Geometria → núcleo

`geometry.surface_panels` corta cada superfície nas seções e nas bordas dos comandos; cada faixa de
cada lado vira um painel com centro aerodinâmico a 25 % da corda média (com enflechamento e diedro).
C_Lα vem de Helmbold com o alongamento da superfície; α_L0 e C_m,ac do perfil (teoria de perfil fino
sobre o `.dat`); τ do comando pela fração de corda. A deflexão de cada painel é
`τ · (mix · [δe, δa, δr])` — o mesmo esquema cobre elevon e ruddervator.

### Tração polinomial

`ThrustPoly` guarda os 21 coeficientes na ordem do `poly55` (`POLY_TERMS`), as variáveis `x_var`,
`y_var` (`none`, `V`, `throttle`, `h`, `rho`), `gain`, `rho_exp`, `xmax`, `ymax` e, informativos,
`T0` e `n` da planilha. `ThrustPoly.thrust(V, thr, h, rho)` faz a mesma conta do núcleo (testado
contra ele em `tests/core/test_poly_thrust.py`).

# aerosim/aero — aerodinâmica a partir da geometria

Na aba **Aerodinâmica** o método principal é o **lltdrek**; o núcleo Zig entra para comparar (é o que
a simulação usa) e o AeroSandbox é opcional. O diagnóstico diz se os métodos concordam (e por que não),
se o cruzeiro está perto do L/D máximo, a margem até o estol e — **só se a aeronave tiver dispositivos
de ponta** (superfícies verticais na ponta da asa) — se eles compensam o atrito. Sem dispositivo, o estudo
de pontas só roda se marcado.

Calcula polares e derivadas de estabilidade da aeronave por **vários métodos** sobre a mesma
geometria (o modelo de `aerosim/model`) e estuda **dispositivos de ponta de asa**. É usado pela aba
**Aerodinâmica** (`manager/simulations/aerodynamics.py`) e pode ser chamado direto do Python.

## Como chamar

```python
import numpy as np
from aerosim.aero import AeroCase, ZigPanelSolver, LltdrekSolver, AsbVLMSolver, polar_metrics
from aerosim.backend.zig import ZigBackend
from aerosim.model.universal import build_model

model = build_model(ac)
case = AeroCase(V=15, alphas=np.arange(-4, 14, 1.0), ref=(0.02, 0, 0.0))   # ref: ponto dos momentos
pol = ZigPanelSolver(ZigBackend()).solve(model, case)      # ou LltdrekSolver(), AsbVLMSolver() se instalados
pol.CL, pol.CD, pol.derivs                                  # polar e derivadas (C_mα, C_nβ, C_lp, ...)
polar_metrics(pol, model, case)                             # C_Lmax, α de estol, (L/D)máx, ponto neutro...
```

`lltdrek` e `aerosandbox` são opcionais (`pip install -r requirements-aero.txt`).

## Asa por partições (etapa Asa da sprint)

Na etapa **Aerodinâmica → Asa** a asa pode ser um trapézio ou uma **tabela de partições**, como na planilha:
cada linha é uma partição com **envergadura** (o quanto ela soma na envergadura total, metade de cada lado),
**corda** (no começo dela), **afilamento**, **perfil** (no fim dela; ao longo da partição ele passa do da
anterior para este), **recuo** (o bordo de ataque andando para trás: enflechamento) e **θ** (torção no fim, em
relação à raiz; − = washout). A envergadura total é a soma das partições; asa reta é uma linha só. A linha
sustentadora (`aerosim/design/wing.py`) usa o perfil de cada seção no Re da corda dela.

Dois exemplos com perfis NACA gerados (polar pelo NeuralFoil), V = 15 m/s, altitude-densidade 600 m,
massa 6 kg:

![Asa reta: uma partição](../../docs/img/asa_reta.png)

![Asa trapezoidal: reta + afilada, outro perfil na ponta](../../docs/img/asa_trapezio.png)

| | reta | trapezoidal |
|---|---|---|
| partições | 2,2 m · c 0,30 · λ 1 · NACA 4412 | 1,0 m · c 0,32 · λ 1 · NACA 4412 + 1,2 m · λ 0,5 · NACA 0012 · recuo 4 cm · θ −2° |
| envergadura, área, alongamento | 2,20 m · 0,660 m² · 7,33 | 2,20 m · 0,608 m² · 7,96 |
| C_Lα | 4,63 /rad (0,0809 /°) | 4,73 /rad (0,0826 /°) |
| C_L0, α de sustentação nula | 0,369 · −4,6° | 0,275 · −3,3° |
| C_L,máx, α de estol | 1,211 · 10,4° | 1,194 · 11,1° |
| onde o estol começa (2y/b) | 0 (raiz) | 0 (raiz) |
| e (Oswald, no cruzeiro) | 0,940 | 0,949 |
| (L/D) máx., C_L nele | 24,4 · 0,45 | 23,6 · 0,52 |
| C_m,ac | −0,103 | −0,086 |
| cruzeiro: C_L, C_D, L/D | 0,686 · 0,0311 · 22,0 | 0,744 · 0,0343 · 21,7 |
| V de estol | 11,3 m/s | 11,8 m/s |
| Re na raiz | 2,87·10⁵ | 2,74·10⁵ |

A trapezoidal tem mais alongamento com a mesma envergadura (menos área), e o perfil simétrico na ponta
(com washout) tira arqueamento de onde o estol seria perigoso: C_L0 e C_m,ac menores, estol mais tarde.

## Como funciona

```mermaid
flowchart LR
    subgraph IF["aerosim/interfaces/aero.py"]
        direction TB
        I1["IAeroSolver<br/>solve(aeronave, caso) → AeroPolar"]
        I2["AeroCase / AeroPolar<br/>DERIVATIVES"]
    end
    TAB["aba Aerodinâmica"] --> IF
    UM["modelo universal<br/>AircraftModel"] --> IF
    IF --> BASE["base.py<br/>polar e derivadas comuns"]
    BASE --> Z["zig_solver.py<br/>tradutor do backend"]
    BASE --> LL["lltdrek_solver.py<br/>LltdrekTranslator"]
    BASE --> ASB["asb_solver.py<br/>AsbTranslator"]
    Z --> CORE["ISimBackend.session_for"]
    LL --> SEC["sections.py<br/>polar 2D: modelo ou NeuralFoil"]
    TAB --> TD["tipdevices.py<br/>plano de Trefftz"]
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class I1,I2 iface
    style IF fill:#eaf2ff,stroke:#1f4e8c,stroke-width:3px
```

### Métodos comparados

| solver | o que entra | como |
|---|---|---|
| `zig` — núcleo Zig | asa, EH, EV, fuselagem | o mesmo modelo da simulação: faixas por seção/comando, C_Lα de Helmbold, ε = ε0 + dε/dα α, estol de Beard e McLain. Derivadas por diferenças centrais em α, β, p̂, q̂, r̂ e nos comandos (`aerosim_aero_coeffs_ex`) |
| `lltdrek` — [kuodrek/lltdrek](https://github.com/kuodrek/lltdrek) | asa + EH (com interação) | linha sustentadora não linear (Phillips–Snyder) com a polar 2D de cada perfil; sem derrapagem (derivadas em β = NaN), sem EV e sem fuselagem |
| `asb_vlm` — AeroSandbox VLM | asa, EH, EV | malha de vórtices em ferradura; arrasto só induzido (+ C_D0 do modelo) |
| `asb_buildup` — AeroSandbox AeroBuildup | asa, EH, EV, fuselagem | soma por componentes com NeuralFoil; arrasto completo |
| `asb_ll` — AeroSandbox LiftingLine | asa, EH, EV | linha sustentadora com NeuralFoil; só derivadas em α e β |

Cada solver só implementa `evaluate(modelo, caso, pontos)` — pontos de voo universais (α, β, p̂, q̂, r̂,
comandos) → coeficientes universais —, com o seu tradutor fazendo a ida (modelo universal → formato
dele) e a volta (resultado → eixos e adimensionalização universais). A varredura em α e as diferenças
centrais das derivadas são o mesmo código para todos (`base.py`). Todos devolvem nos eixos do simulador (x à frente, z para baixo) com momentos no ponto `ref` do caso
(o x_CG escolhido na aba, em % da CMA, ou o CG do modelo de massa): p̂ = p b/2V, q̂ = q c/2V,
r̂ = r b/2V. Os externos usam x para trás e z para cima (`geometry.to_xz_up`); o lltdrek usa
velocidade livre unitária (ω entra dividido por V) e normaliza C_l e C_n por S c — o adaptador converte.

`polar_metrics` tira de cada polar: C_L0, C_Lα, C_Lmax, α de estol, C_D mín., (L/D) máx., e (ajuste de
C_Di = C_L²/(π AR e)), ponto neutro x_np = x_ref + c C_mα/C_Lα e margem estática.

**Polar 2D (`sections.py`)** — `modelo`: c_l = a0 (α − α_L0) misturado à placa plana pela sigmoide de
Beard e McLain com o pico no c_l,max do perfil (a mesma hipótese do núcleo, em 2D); `neuralfoil`: o
contorno `.dat` real pela rede do NeuralFoil.

Notas sobre o lltdrek 1.2: (1) o corretor de Newton só monta a matriz certa quando todas as
superfícies têm o mesmo número de painéis — o adaptador sempre usa o mesmo N; (2) `np.cross` em
vetores soltos domina o tempo — o adaptador troca por uma versão de 3 componentes (~4× mais rápido).

![Polares por método](../../docs/img/comparativo/conventional_aero_graficos.png)
![Derivadas por método](../../docs/img/comparativo/conventional_aero_diagnostico.png)
![Métricas por método](../../docs/img/comparativo/flying_wing_aero_diagnostico.png)

### Dispositivos de ponta de asa (`tipdevices.py`)

Arrasto induzido mínimo no plano de Trefftz (Munk; Kroo, *Drag due to lift*, Annu. Rev. Fluid Mech.
2001; Kroo, McMasters e Smith, *Highly nonplanar lifting systems*, 1995):

```
L = ρ V ∮ Γ dy        D_i = (ρ/2) ∮ Γ w_n ds        e = L² / (π q b² D_i)
```

O traço é dividido em painéis de Γ constante com vórtices livres nas pontas de cada painel
(espaçamento uniforme — o cosseno não converge nas junções) e o Γ ótimo sai de min D_i com L fixo.
Extrapolação de Richardson em n e 2n. Validação (testes em `tests/aero/test_tipdevices.py`):

| configuração | aqui | referência |
|---|---|---|
| asa plana | 1,000 | 1 (elíptica) |
| caixa h/b = 0,2 | 1,47 | 1,46 (Kroo 2001) |
| placa de ponta h/b = 0,1 / 0,2 | 1,19 / 1,38 | 1 + 1,9 h/b = 1,19 / 1,38 (Raymer) |
| winglet h/b = 0,2 | 1,42 | — |
| momento na raiz, plana | (L/2)(4s/3π) | elíptica |

`device_study` varre h/b e dá, para winglet, placa, caixa e asa em C: o e ótimo e a variação do arrasto
total (D_i + atrito C_f S_molhada do dispositivo) em relação à asa sem nada; e duas referências de
extensão de ponta: com a mesma área molhada e com o mesmo momento fletor na raiz (comparação de
Whitcomb/Jones). Com carregamento ótimo a extensão ganha; o winglet compensa quando o vão é limitado
(regulamento, hangar).

![Pontas de asa](../../docs/img/comparativo/flying_wing_aero_graficos.png)

`lltdrek` e `aerosandbox` são opcionais: sem eles o solver aparece como indisponível na aba.

Figuras: `python tools/plot_comparativo.py docs/img/comparativo [conventional|twin_boom|flying_wing|arquivo.cfg]`.

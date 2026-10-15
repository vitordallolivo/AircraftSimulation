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

Os gráficos da etapa Asa para cada uma (C_L × α, polar com arrasto induzido e de perfil, L/D e c_l ao
longo da semienvergadura no cruzeiro e no estol):

![Gráficos da asa reta](../../docs/img/asa_reta_graficos.png)

![Gráficos da asa trapezoidal](../../docs/img/asa_trapezio_graficos.png)

A trapezoidal tem mais alongamento com a mesma envergadura (menos área), e o perfil simétrico na ponta
(com washout) tira arqueamento de onde o estol seria perigoso: C_L0 e C_m,ac menores, estol mais tarde.

## Carga ao longo das superfícies (`span_loads.py`)

É a "análise de cargas" da aerodinâmica num ponto de operação.

- **Padrão: voo nivelado a 12 m/s.** α, profundor e acelerador saem da trimagem do núcleo, então a distribuição é a
  da carga real do avião (as superfícies sustentam o peso).
- **Mudar a velocidade:** `V`.
- **Curva:** `n` > 1 (fator de carga). Se o avião não segura aquele n naquela velocidade, a trimagem avisa em
  `notes`.
- **Impor tudo:** `alpha`, `de` e a **rotação de cada motor** (`rpm`). Para cada superfície (asa, EH, EV, cauda em V,
dispositivos) devolve, ao longo da envergadura em metros:
- sustentação e arrasto por metro (N/m);
- α local, velocidade e pressão dinâmica locais;
- C_l e C_d;
- os **vetores** de cada faixa: centro, força, velocidade relativa e a parte dos modificadores. São o que a vista
  3D vai desenhar.

`tubes()` dá o contorno da esteira de cada motor, também para o 3D.

```python
from aerosim.aero.span_loads import LoadCase, compute
r = compute(backend, ac)                                      # nivelado a 12 m/s (trimagem)
r = compute(backend, ac, LoadCase(V=16, n=2))                 # curva com n = 2 a 16 m/s
r = compute(backend, ac, LoadCase(V=8, alpha=2, rpm=6000))     # α e rotação impostos (rpm: um valor ou um por motor)
r.alpha, r.de, r.weight, r.trim                               # o que foi usado
asa = r.by_role("wing")[0]
asa.s, asa.L, asa.alpha, asa.V                                # y (m), N/m, °, m/s
asa.points, asa.force, asa.velocity, asa.induced              # (n, 3), corpo
r.props[0].T, r.props[0].Q, r.props[0].J                      # motor naquela rotação
```

A conta é do núcleo, no mesmo laço da simulação (`aero.computeTrace` via `aerosim_panel_states`), e entra com os
modificadores do avião (efeito solo, esteira). O estado do motor vem de `aerosim_prop_state`: hélice C_T(J), C_P(J)
na rotação pedida, com o ar no eixo do motor.

O módulo só refina a geometria para dar resolução: põe mais seções na mesma superfície (corda, recuo e torção
interpolados, com as seções originais exatas), uma superfície por vez, até o limite de painéis do núcleo. Sem motor,
a sustentação total refinada é a mesma da sem refino (teste). Superfícies com perfil próprio por seção e dispositivos
de ponta saem com as faixas que já têm.

**Entrada padrão, gráficos e 3D.** `to_result(r, backend)` leva o resultado para a entrada padrão
`aerosim.interfaces.loads.LoadResult`:
- distribuições ao longo da envergadura;
- a malha 3D: uma face por faixa, do bordo de ataque ao de fuga, na largura da faixa;
- os campos: carga alar local (N/m²), sustentação por metro, α efetivo, V local / V∞, c_l, c_d, q;
- os vetores (força e velocidade induzida) e os tubos da esteira.

Quem desenha só lê esse formato:
- `load_plots.span_figure` faz os gráficos;
- `gui/widgets/load_view.LoadView` faz o 3D, com mapa de cores do campo escolhido, setas, esteira e o avião em
  transparência.

Por isso outro método (VLM, painéis, CFD) entra montando um `LoadResult`, sem mexer nos gráficos nem no 3D. O teste
`tests/aero/test_load_result.py` faz isso com um "CFD" de mentira em triângulos e com um campo próprio.

A vista 3D pinta o **próprio modelo da GUI** (`aircraft_meshes`): cada vértice de superfície pega o valor da faixa
mais próxima. As setas têm ponta. Camadas de setas:
- **força total** da faixa;
- **sustentação (⟂ ao vento local)**;
- **força normal à superfície**;
- **velocidade induzida**.

A força total não é perpendicular à superfície. A sustentação é perpendicular ao vento local, e com α de uns 12° ela
fica inclinada para a frente em relação à normal da asa. Por isso há as duas camadas separadas.

Escalas do mapa:
- mín–máx (padrão);
- simétrica em 0;
- por superfície: cada superfície com a sua faixa, para ver a variação na EH mesmo com a asa carregando muito mais.

O campo `imersao` mostra quanto de cada faixa está dentro do tubo de alguma hélice.

**Sem hélice:** `LoadCase(props=False)` (ou `--sem-helice`) zera tração e torque. A distribuição sai a do avião
limpo, para comparar ou para cargas sem motor.

**Página interativa:** `load_export.scene(res, ac)` monta a cena (malhas, campos, setas, tubos, vento) em JSON.
`load_export.page([(nome, cena), ...])` põe as cenas em `load_page.html` (plotly, girar e trocar campo no navegador).

```
python tools/load_view.py data/aircraft/Convencional_original.json --com esteira.disco                 # janela 3D
python tools/load_view.py data/aircraft/Convencional_original.json --campo alpha_ef --png vista.png
python tools/load_view.py data/aircraft/Convencional_original.json --com esteira.disco --sem-helice --png limpo.png
python tools/load_view.py data/aircraft/Convencional_original.json --com esteira.disco --html carga.html
```

### Colisão com o tubo da hélice (`collision.py`)

`tube_hits(backend, ac, V=0, thrust=None)` traça, a partir de cada hélice, um tubo ao longo do eixo de tração:
- com `thrust` nulo, um cilindro do raio da hélice;
- com tração, o tubo que contrai.

O que o tubo pega vem como `Hit(prop, component, kind, fraction)`:
- superfícies: fração da área (`aerosim_tube_panel_hits`);
- objetos (fuselagem, trem, carga): fração dos vértices do modelo da GUI (`aerosim_tube_point_hits`).

A geometria é do núcleo (`core/src/collision/`), e é a mesma que a esteira usa.

```python
from aerosim.aero.collision import tube_hits
for h in tube_hits(backend, ac):
    print(h.prop, h.component, h.kind, h.fraction)
```

A trimagem ainda não vê a esteira (ela chama a aerodinâmica sem motores). Com a esteira ligada, α e profundor são
os do avião sem esteira e a sobra de sustentação aparece no resultado.

Os testes estão em `tests/aero/test_span_loads.py`. Pela linha de comando:

```
python tools/span_load.py data/aircraft/Convencional_original.json --com esteira.disco --png carga.png   # 12 m/s
python tools/span_load.py data/aircraft/Convencional_original.json --V 15 --n 2 --png curva.png
python tools/span_load.py data/aircraft/Convencional_original.json --V 8 --alpha 2 --rpm 6000 --com esteira.disco
```

## Como funciona

```mermaid
flowchart LR
    subgraph IF["aerosim/interfaces/aero.py"]
        direction TB
        I1["IAeroSolver<br/>solve(aeronave, caso) → AeroPolar"]
        I2["AeroCase / AeroPolar<br/>DERIVATIVES"]
        I3["ISectionPolar<br/>polar 2D de perfil"]
    end
    TAB["aba Aerodinâmica"] --> IF
    UM["modelo universal<br/>AircraftModel"] --> IF
    IF --> BASE["base.py<br/>polar e derivadas comuns"]
    TAB --> SV["service.py<br/>cache 3D: modelo + método + caso"]
    SV --> BASE
    BASE --> Z["zig_solver.py<br/>tradutor do backend"]
    BASE --> LL["lltdrek_solver.py<br/>LltdrekTranslator"]
    BASE --> ASB["asb_solver.py<br/>AsbTranslator"]
    BASE --> AVL["avl_solver.py<br/>AvlTranslator (programa avl)"]
    TAB --> XF["xflr5_import.py<br/>polar do XFLR5 (arquivo)"]
    Z --> CORE["ISimBackend.session_for"]
    LL --> SEC["sections.py — ISectionPolar<br/>modelo · NeuralFoil · arquivo<br/>cache 2D"]
    DS["design/airfoils.py<br/>etapa Perfil"] --> SEC
    TAB --> TD["tipdevices.py<br/>plano de Trefftz"]
    classDef iface fill:#cfe3ff,stroke:#1f4e8c,stroke-width:2px,color:#0b2545
    class I1,I2,I3 iface
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
| `avl` — [AVL](https://web.mit.edu/drela/Public/web/avl/) (Drela e Youngren) | asa, EH, EV, dispositivos, comandos | malha de vórtices; o programa `avl` é externo (PATH ou `AVL_PATH`). O tradutor escreve o `.avl` (NACA pelo código, os outros perfis por AFILE, C_D0 do modelo como CDp, comandos `pitch`/`roll`/`yaw` pelos ganhos da mistura), roda a varredura numa sessão e lê o `ST` de cada ponto |
| `xflr5` — polar importada | o que estava no XFLR5 | lê a polar de avião exportada (Polars → Export, texto ou CSV): α, C_L, C_D, C_Di, C_m (no CG de lá); C_Lα e C_mα pelo ajuste em α; não roda nada |

Cada solver só implementa `evaluate(modelo, caso, pontos)` — pontos de voo universais (α, β, p̂, q̂, r̂,
comandos) → coeficientes universais —, com o seu tradutor fazendo a ida (modelo universal → formato
dele) e a volta (resultado → eixos e adimensionalização universais). A varredura em α e as diferenças
centrais das derivadas são o mesmo código para todos (`base.py`). Todos devolvem nos eixos do simulador (x à frente, z para baixo) com momentos no ponto `ref` do caso
(o x_CG escolhido na aba, em % da CMA, ou o CG do modelo de massa): p̂ = p b/2V, q̂ = q c/2V,
r̂ = r b/2V. Os externos usam x para trás e z para cima (`geometry.to_xz_up`); o lltdrek usa
velocidade livre unitária (ω entra dividido por V) e normaliza C_l e C_n por S c — o adaptador converte.

`polar_metrics` tira de cada polar: C_L0, C_Lα, C_Lmax, α de estol, C_D mín., (L/D) máx., e (ajuste de
C_Di = C_L²/(π AR e)), ponto neutro x_np = x_ref + c C_mα/C_Lα e margem estática.

**Polar 2D (`sections.py`)** — cada fonte é um `ISectionPolar` (`aerosim/interfaces/aero.py`) e a etapa
Perfil da sprint e o lltdrek pedem pelo mesmo `section_polar(perfil, α, Re, fonte)`:

| fonte | o que é |
|---|---|
| `modelo` | c_l = a0 (α − α_L0) misturado à placa plana pela sigmoide de Beard e McLain, pico no c_l,max do perfil (a hipótese do núcleo, em 2D) |
| `neuralfoil` | o contorno real (.dat ou NACA) pela rede do NeuralFoil; sem contorno, cai no modelo |
| `arquivo` | a polar exportada pelo XFLR5/XFOIL |

**Perfil por seção no lltdrek** — cada estação do modelo universal carrega o perfil dela (asa por
partições com outro perfil na ponta); o tradutor escreve uma polar por perfil diferente e o lltdrek
mistura linearmente entre as estações, como a etapa Asa.

**Cache** — a mesma pergunta não roda de novo:

| | chave | onde |
|---|---|---|
| 2D (`sections.py`) | perfil (nome, contorno, números, invertido) + fonte + arquivo e data + Re (em mil) + α | memória; NeuralFoil também em disco |
| 3D (`service.py`) | configuração inteira + método + versão dele + caso (V, α, ref, ρ, polar 2D, painéis) | memória; métodos caros (lltdrek, AeroSandbox, AVL) também em disco |

O disco é `~/.cache/aerosim` (ou a pasta da variável `AEROSIM_CACHE`), nunca o repositório nem `data/`.
Na aba, o resumo mostra `[método] de onde`: `calculado`, `cache` ou `arquivo …`. Cada `AeroPolar` sai
também com `fidelity` (`modelo` < `llt` < `vlm` < `painel` < `cfd` < `ensaio`), para depois calibrar o
método barato pelo caro.

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

`lltdrek`, `aerosandbox` e o programa `avl` são opcionais: sem eles o solver aparece como indisponível
na aba, com o motivo.

Figuras: `python tools/plot_comparativo.py docs/img/comparativo [conventional|twin_boom|flying_wing|arquivo.cfg]`.

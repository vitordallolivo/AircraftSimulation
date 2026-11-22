# Áreas e submódulos

O que cada área tem hoje (subaba na tela, módulo no código) e o que ainda vai ter. A ordem e o estado das tarefas ficam
em `docs/TRACKING.md`; aqui fica **onde cada coisa mora**, para não fazer a mesma análise em dois lugares. Os caminhos
sem pasta na frente são de `aerosim/`.

Estado: ✅ existe e aparece na tela · 🟡 existe só no código ou em parte · ⬜ previsto.

## 1. Dimensionamento inicial

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Mini-MDO (otimizador) | ✅ | `core/src/sizing`, `manager/simulations/mdo.zig` | — |
| Diagrama de restrições T/W × W/S | ✅ | `manager/simulations/sizing.zig` | — |
| Estudo e ponto de projeto | ✅ | `design/stage_study.zig` | — |

## 2. Aerodinâmica

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Perfis (polares 2D por Re) | ✅ | `design/stage_airfoils.zig`, `core/src/physics/section.zig` | — |
| Projetar a asa (forma em planta, partições, dispositivos de ponta) | ✅ | `design/stage_wing.zig` | G03 |
| Avião completo (núcleo, lltdrek, ASB, AVL) em Analisar | ✅ | `manager/simulations/aerodynamics.zig`; os de fora em `aero/*_solver.py`, pela ponte | G28 |
| Só as asas (uma, biplano, tandem, canard), como no túnel | ✅ | `manager/simulations/wings.zig`, `core/src/loads/sweep.zig` | — |
| Linha sustentadora das cargas (enflechamento, não linear) | ✅ | `core/src/loads/llt.zig` | T55 |
| Efeito solo (McCormick e imagem no VLM) | ✅ | Analisar → "Efeito do chão"; `core/src/modifiers/ground.zig`, `core/src/loads/vlm.zig` | T65 |
| Flape (ΔC_l, ΔC_l máx, ΔC_d, ΔC_m, comando) | 🟡 | só deflexão fixa na incidência | T54 |
| Arrasto por componente | 🟡 | o núcleo separa por grupo para o Exportar (`manager/aero_sheet.zig`) | T11 |
| Reynolds no voo | 🟡 | `core/src/physics/section.zig` (Perfis e estol por estação) | T10 |
| Modelo aerodinâmico do voo e tabela de voo | 🟡 | `core/src/physics/aeromodel.zig`, `aerotable.zig` | T66, T68 |
| Trimagem com esteira e tubo desviado | ⬜ | modifier `esteira.disco` | T08 |
| Distribuição ao longo da envergadura a um α | ✅ | Analisar ("Carga na envergadura") e Cargas; ver D2 | — |

## 3. Estabilidade

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Empenagem e comandos | ✅ | `design/stage_tail.zig`, `core/src/sizing/tail.zig` | G31 |
| Avião montado: estática, tesoura, comandos, dinâmica, qualidades de voo | ✅ | `manager/simulations/stability.zig`, `core/src/sim/static.zig`, `core/src/sim/modes.zig` | — |
| Estabilidade dinâmica: rajada, líquido, LAPES e polos no tempo | ✅ | `manager/simulations/stability.zig`, `core/src/sim/gust.zig` | G20 |
| Duas subabas (estática e dinâmica) da configuração inteira | 🟡 | hoje "Avião montado" junta a estática e os modos | G06 |
| Normas e critérios como preset do usuário | ⬜ | — | T37 |
| Estabilidade não linear (Lyapunov, região de atração) | ⬜ | — | T05 |
| Diedro elástico | ⬜ | depende de Aeroelasticidade | T27 |

## 4. Desempenho

Organizado **por etapa de voo**: cada etapa mostra a forma analítica e a simulada (6GDL do núcleo) juntas. A missão
completa encadeia as etapas. O V-n **não** é de Desempenho: é de Cargas.

| Subaba | Analítica | Simulada | Estado | Tarefa |
|---|---|---|---|---|
| Motores e montagem | — | — | ✅ (`design/stage_power.zig`) | G11 |
| Tração | equilíbrio de rotação | — | ✅ (`manager/simulations/thrust.zig`) | G45 |
| Decolagem | corrida analítica | 6GDL + otimizador do profundor (`manager/takeoff_opt.zig`) | 🟡 (Missão → Decolagem acha o MTOW em cada xCG) | T43 |
| Subida | RC e γ × V | subida simulada | 🟡 (a simulada está errada) | T44 |
| Voo nivelado e envelopes | potências e trações; envelopes × altitude | modelo completo | ✅ (`manager/simulations/envelope.zig`) | — |
| Avião montado | polar, potências, subida, planeio, curvas e bateria por altitude | — | ✅ (`manager/simulations/performance.zig`) | — |
| Curva | R × φ, limites de estol e tração | raio mínimo e fator de carga no tempo | 🟡 (na Missão "curvas") | T45 |
| Descida, planeio e pouso | planeio, corrida de pouso | etapa de pouso da Missão | 🟡 | T46 |
| Missão completa | — | a missão de hoje | ✅ (`manager/simulations/mission.zig`) | — |
| Vento cruzado, Dryden, Monte Carlo | | | ⬜ | T31, T30, T29 |

**MTOW (dentro da Decolagem):** uma caixa "achar o MTOW para o comprimento de pista", varrendo a massa total (mínimo,
máximo, inicial e passo) ou a massa por componente (peso vazio, carga paga, líquido, LAPES; cada um ligável, com os
seus limites e passo). Regras de passo são do usuário; o programa não traz nenhuma por padrão.

## 5. Cargas e aeroelasticidade

| Subaba | Estado | Saídas | Tarefa |
|---|---|---|---|
| Distribuição | ✅ | L', α efetivo, V/V∞ por superfície; vista 3D (`manager/simulations/loads.zig`) | — |
| Diagrama V-n e rajada | 🟡 | núcleo pronto (`core/src/loads/vn.zig`); falta a subaba | — |
| Casos de carga | 🟡 | tabela de casos (sustentação de asa, EH e EV por caso) | T16 |
| Esforços (cortante, fletor, torsor) | 🟡 | núcleo pronto (`core/src/loads/internal.zig`); falta a subaba | — |
| Momentos de dobradiça | ⬜ | momento por comando e caso, força no servo | T17 |
| Cargas no solo | 🟡 | impacto do pouso (`core/src/structures/gear.zig`); faltam os outros casos | T18 |
| Aeroelasticidade | 🟡 | divergência, reversão e flutter no núcleo (`core/src/loads/aeroelastic.zig`, `flutter.zig`); falta rigidez e diedro elástico | T24, T27 |
| Comparação com ensaio e voo | ⬜ | V-n com dados de voo, simulado × ensaio | T35, T40 |

**Para Estruturas:** esforços por superfície e caso, momentos de dobradiça, cargas no trem, forças de EH e EV no tubo
de cauda e na fuselagem, e a tabela de casos (de onde veio cada carga).

## 6. Estruturas (aba ainda não existe)

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Arquitetura e materiais (dados do usuário) | 🟡 | `core/src/structures` | T20 |
| Longarina | 🟡 | `core/src/structures/section.zig`, `buckling.zig` | T21 |
| Tubo de cauda | ⬜ | — | T22 |
| Trem (eixo, garfo) | 🟡 | `core/src/structures/gear.zig` (sem aba) | — |
| Fuselagem | ⬜ | — | sem tarefa (proposta) |
| Redistribuição das cargas para a malha | ⬜ | — | T39 |

## 7. Controle e integração

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Montagem, resumo, xCG em % CMA | ✅ | `gui/assembly.zig`, `gui/tabs/config_tab.zig`, `design/balance.zig` | — |
| Piloto automático (autotune) | ✅ | núcleo | — |
| Aba de controle | ⬜ | — | T33 |
| Caixa, montagem e desmontagem | ⬜ | — | O08 |
| Etapas desatualizadas | ⬜ | — | T41 |

## Duplicações encontradas

| # | O quê | Onde aparece | Proposta |
|---|---|---|---|
| D1 | Diagrama V-n e envelope de voo | `manager/simulations/performance.zig` e `envelope.zig` fazem a sua conta; o núcleo tem `core/src/loads/vn.zig` | um V-n só, no núcleo, dono Cargas; Desempenho lê |
| D2 | Distribuição ao longo da envergadura | Aerodinâmica → Analisar e Cargas → Distribuição | conferir se as duas usam a mesma conta do núcleo |

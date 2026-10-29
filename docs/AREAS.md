# Áreas e submódulos

O que cada área tem hoje (subaba na GUI, módulo no código) e o que ainda vai ter. A ordem e o estado das tarefas ficam
em `docs/TRACKING.md`; aqui fica **onde cada coisa mora**, para não fazer a mesma análise em dois lugares.

Estado: ✅ existe e aparece na GUI · 🟡 existe só no código ou em parte · ⬜ previsto (vai para o módulo "não
desenvolvido" até ser feito) · ⚠ cálculo em Python que, pela regra 2 do `.claude/CLAUDE.md`, deveria estar no núcleo.

## 1. Dimensionamento inicial

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Mini-MDO (otimizador) | ✅ | `core/src/sizing`, `design/mdo.py` | — |
| Diagrama de restrições T/W × W/S | ✅ ⚠ | `aerosim/sizing/constraints.py` (Python) | — |

## 2. Aerodinâmica

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Perfil (polares 2D por Re, cache) | ✅ | `design/airfoils.py`, `aero/sections.py` | — |
| Asa (forma em planta, partições) | ✅ ⚠ | `design/wing.py` (Helmbold em Python) | — |
| Avião montado (polar e derivadas; núcleo, lltdrek, ASB, AVL, XFLR5) | ✅ | `manager/simulations/aerodynamics.py`, `aero/*_solver.py` | — |
| Dispositivos de ponta | ✅ ⚠ | `aero/tipdevices.py` (Trefftz em Python) | — |
| Flape (ΔC_l, ΔC_l máx, ΔC_d, ΔC_m, comando) — prioridade | 🟡 | só deflexão fixa na incidência (`translator.py`) | T54 |
| Linha sustentadora das cargas (enflechamento, não linear) | ✅ | `core/src/loads/llt.zig` | T55 |
| Só as asas (uma, biplano, tandem, canard): polar, C_L máximo, início do estol, chapas de ponta, Reynolds | ✅ | `manager/simulations/wings.py` | T89 |
| Arrasto por componente | ⬜ | — | T11 |
| Reynolds no núcleo | ⬜ | — | T10 |
| Trimagem com esteira e tubo desviado | ⬜ | modifier `esteira.disco` | T08 |
| Efeito solo por imagem | ⬜ | modifier novo | AE-09 |
| Distribuição ao longo da envergadura a um α | → Cargas | ver duplicação D6 | T09 |

## 3. Estabilidade

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Empenagem e comandos | ✅ ⚠ | `design/tail.py`, `stability/controls.py` | — |
| Avião montado: estática, tesoura, comandos, dinâmica, qualidades de voo | ✅ ⚠ | `manager/simulations/stability.py`, `stability/*.py` | — |
| Normas e critérios como preset do usuário | ⬜ | `stability/criteria.py` | T37 |
| Estabilidade não linear (Lyapunov, região de atração, sloshing, vento) | ⬜ | — | T05 |
| Diedro elástico | ⬜ | depende de Aeroelasticidade | T27 |

## 4. Desempenho

Organizado **por etapa de voo**: cada etapa mostra a forma analítica (`simple_perf` do núcleo) e a numérica (6GDL do
núcleo) juntas. A missão completa continua, encadeando as etapas. O V-n **não** é de Desempenho: é de Cargas.

| Subaba | Analítica | Numérica | Estado | Substitui |
|---|---|---|---|---|
| Motores e montagem | — | — | ✅ | — |
| Estudo e ponto de projeto | — | — | ✅ | — |
| Tração | equilíbrio de rotação | — | ✅ | — |
| Decolagem | corrida analítica | 6GDL + otimizador do profundor (`takeoff_opt`) | 🟡 | `takeoff.py`, Missão "só decolagem" e "MTOW" |
| Subida | RC e γ × V | subida simulada | 🟡 (a simulada está errada: γ obtido não segue o pedido) | `climb.py` |
| Voo nivelado e envelopes | potências e trações; envelopes × altitude | modelo completo | 🟡 (`envelope.py` sem aba) | `envelope.py` e o envelope de `performance.py` |
| Curva | R × φ, limites de estol e tração | raio mínimo simulado, fator de carga no tempo | ✅ | `turn.py`, Missão "curvas" |
| Descida e planeio | planeio | ⬜ | 🟡 | — |
| Pouso | `landingRun` | etapa de pouso da Missão | 🟡 | — |
| Missão completa | — | a missão de hoje | ✅ | — |
| Vento cruzado, Dryden, Monte Carlo | | | ⬜ | T31, T30, T29 |

**MTOW (dentro da Decolagem, não é modo avulso):** uma caixa "achar o MTOW para o comprimento de pista". A massa
varre de dois jeitos, à escolha:
- **massa total:** mínimo, máximo, valor inicial e passo;
- **fragmentada por componente:** peso vazio, carga paga, líquido (sloshing), LAPES… Cada componente **pode** existir:
  tem chave para ligar e desligar e o seu próprio mínimo, máximo, valor inicial e passo.

Regras de passo (ex.: o líquido só em múltiplos de um volume) são do usuário: o programa não traz nenhuma por padrão.

## 5. Cargas e aeroelasticidade

| Subaba | Estado | Saídas | Tarefa |
|---|---|---|---|
| Distribuição | ✅ | L', α efetivo, V/V∞ por superfície; vista 3D | T12 |
| Diagrama V-n | ⬜ | velocidades estruturais, envelope de manobra, n por caso | T13 |
| Rajada | ⬜ | Δn em V_C e V_D, envelope de rajada, forças por rajada | T14 |
| Casos de carga | ⬜ | tabela de casos (sustentação de asa, EH e EV por caso) | T13, T16 |
| Esforços (cortante, fletor, torsor) | ⬜ | V(s), M(s), T(s) por superfície e o caso crítico | T15 |
| Momentos de dobradiça | ⬜ | momento por comando e caso, força no servo | T17 |
| Cargas no solo | ⬜ | forças no TDP e no TDN (com a lateral), fator de impacto | T18 |
| Aeroelasticidade | ⬜ | centro elástico, rigidez, divergência, reversão, flutter (V-g, V-f) | T24–T27, T32 |
| Comparação com ensaio e voo | ⬜ | V-n com dados de voo, simulado × ensaio | T35, T40 |

**Para Estruturas:** esforços por superfície e caso, momentos de dobradiça, cargas no trem, forças de EH e EV no tubo
de cauda e na fuselagem, e a tabela de casos (de onde veio cada carga).

## 6. Estruturas (aba ainda não existe)

| Submódulo | Estado | Tarefa |
|---|---|---|
| Arquitetura e materiais (dados do usuário) | ⬜ | T20 |
| Longarina | ⬜ | T21 |
| Tubo de cauda | ⬜ | T22 |
| Trem (eixo, garfo) | ⬜ | T23 |
| Fuselagem | ⬜ | sem tarefa (proposta) |
| Redistribuição das cargas para a malha | ⬜ | T39 |

## 7. Controle e integração

| Submódulo | Estado | Onde | Tarefa |
|---|---|---|---|
| Montagem, checklist, xCG em % CMA | ✅ | `ConfigTab`, `design/checklist.py` | — |
| Piloto automático (autotune) | ✅ | núcleo | — |
| Aba de controle | ⬜ | — | T33 |
| Caixa, montagem e desmontagem | ⬜ | — | T34 |
| Etapas desatualizadas | ⬜ | — | T41 |

## Duplicações encontradas

| # | O quê | Onde aparece | Proposta |
|---|---|---|---|
| D1 | Diagrama V-n | `performance.py` (`_vn`), `envelope.py` (sem aba), e a subaba de Cargas (T13) | um V-n só, no núcleo, dono Cargas; Desempenho lê |
| D2 | Curvas: raio mínimo | `turn.py` (sem aba) e a Missão "curvas: raio mínimo" (mesmo `evaluate_turn`, laço repetido) | subaba Curva única (analítica + numérica) |
| D3 | Decolagem | `takeoff.py` (sem aba), Missão "só decolagem" e "MTOW", e `design/flight.py` (todos usam `takeoff_opt`) | subaba Decolagem única, com o MTOW como caixa de marcar |
| D4 | Envelope de voo | `envelope.py` (sem aba, "Envelope_main original") e `performance.py` (`simple_perf`) | subaba Voo nivelado e envelopes, com todos os envelopes plotados |
| D5 | Polar estática | `polar.py` (sem aba) e Aerodinâmica → Avião montado | conferir quem usa `polar.py` |
| D6 | Distribuição ao longo da envergadura | T09 (Aerodinâmica) e Cargas → Distribuição (T12) | T09 fecha com a subaba de Cargas (ou a Aerodinâmica mostra o mesmo `LoadResult`) |
| D7 | Requisitos do projeto | `design/spec.py` e `sizing/constraints.py`: duas classes `Requirements`, campos repetidos com padrões diferentes (V de cruzeiro 15 × 16 m/s) | uma classe só; os limites viram preset do usuário (T37) |
| D8 | Helmbold (C_Lα 3D) | `model/airfoil.py` (Python) e o tradutor/núcleo | uma fórmula só, no núcleo |

As "sem aba" (`turn`, `envelope`, `climb`, `takeoff`, `polar`) ainda são chamadas por scripts e testes: antes de tirar
qualquer uma, conferir quem chama.

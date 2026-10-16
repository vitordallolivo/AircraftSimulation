# Tracking do projeto

Lista única do que o simulador cobre e do que falta. Junta as áreas de um projeto AeroDesign completo e as ideias de
`ideias.md`. É um juízo de valor, não uma análise: nada aqui foi calculado.

**Referência das áreas:** relatórios de projeto completos de uma equipe. Eles **não estão no git** e nenhum dado deles
entra aqui; servem só como lista do que um projeto cobre.

**Cuidado com estruturas:** os relatórios de referência têm valores inconsistentes nessa área. Servem como lista de
tópicos, nunca como fonte de números.

Como usar:
1. Olhe a coluna **Pronto** do quadro.
2. Pegue no máximo 2 tarefas.
3. Ao fechar uma tarefa, atualize os itens que ela mexe e o progresso.

---

## O castelo (mapa)

```
        [Torres]   pós-1.0: CFD 3D, VTOL/tailsitter, controle não linear, CAD
   ┌──────────────────────────────────────────────────────┐
 3 │ Andar 3: Estruturas · Aeroelasticidade · Elétrica      │ ← arquitetura nova (do zero)
 2 │ Andar 2: Cargas (casos, esforços, dobradiça, solo)     │ ← apoia-se no Andar 1
 1 │ Andar 1: Aero · Desempenho · E&C · Integração          │ ← já está de pé
   ├──────────────────────────────────────────────────────┤
 0 │ Fundação: núcleo Zig, ABI, modelo universal, testes    │
   └──────────────────────────────────────────────────────┘
              [Portão] = GUI: só conta quando passa por ele
```

- Uma tarefa nunca depende de um andar acima do dela.
- O Andar 3 só começa quando o Andar 2 entrega cargas por caso.

---

## Versões

- **`main` atual = `v0.1.0`** (`033bdc1`). A tag só será criada com o ok do dono do repositório.
- **Minor (`0.x.0`):** fecha um milestone.
- **Patch (`0.x.y`):** cada subversão do milestone (um bloco de tarefas mesclado na `main`) e correções.
- **`1.0.0`:** todo o escopo 1.0 com ✅ na coluna **GUI**.
  - Uma análise só conta quando roda e mostra o resultado na interface.
  - Não contam o que só existe no código, numa ferramenta de linha de comando ou num teste.
- As versões passam do 0.9 se precisar (0.10, 0.11…), o que é válido em semver.

## Milestones

| Versão | Milestone | Subversões | Fecha quando |
|---|---|---|---|
| **0.1** | Fundação firme | 0.1.1 testes de regressão em `tools/checks` (comparação bit a bit, núcleo, AeroDrive, testes por área) · 0.1.2 rodar e corrigir o que quebrou · 0.1.3 conferir os ❓ · 0.1.4 pilha de branches mesclada | pilha na `main` com os checks verdes |
| **0.2** | Análises simples (cálculos e plots) | 0.2.1 passeio do CG e ME no tempo · 0.2.2 curvas com fator de carga · 0.2.3 C-rate × corrente de pico | os itens na GUI |
| **0.3** | Aero completo na GUI | 0.3.1 trimagem com esteira, tubo desviado · 0.3.2 distribuição a α (início do estol) · 0.3.3 Reynolds no núcleo · 0.3.4 arrasto por componente | os itens na GUI |
| **0.4** | Cargas I | 0.4.1 aba Cargas (3D + gráficos) · 0.4.2 casos do V-n · 0.4.3 rajada · 0.4.4 cortante, fletor e torsor | esforços por caso na GUI |
| **0.5** | Cargas II + Elétrica | 0.5.1 manobras dinâmicas · 0.5.2 momentos de dobradiça · 0.5.3 cargas no solo · 0.5.4 servos e cabos | dobradiça → servo na GUI |
| **0.6** | Estruturas (do zero) | 0.6.1 arquitetura + materiais · 0.6.2 longarina · 0.6.3 tubo de cauda · 0.6.4 trem | longarina na GUI |
| **0.7** | Aeroelasticidade estática | 0.7.1 rigidez e centro elástico · 0.7.2 divergência · 0.7.3 reversão · 0.7.4 diedro elástico em E&C | os itens na GUI |
| **0.8** | Incerteza e atmosfera | 0.8.1 paralelismo no núcleo · 0.8.2 Monte Carlo e sensibilidade · 0.8.3 turbulência Dryden · 0.8.4 vento cruzado na decolagem · 0.8.5 polos com vento e sloshing | os itens na GUI |
| **0.9** | Fechamento | 0.9.1 modos e flutter · 0.9.2 aba de controle · 0.9.3 caixa, montagem e desmontagem · 0.9.4 comparação com ensaio e voo real | todo o escopo 1.0 ✅ |
| **1.0** | Castelo pronto | — | — |

**Torres (pós-1.0, menor prioridade):**
- VTOL/tailsitter;
- controle não linear;
- CFD 3D (inclui a perda de tração por corpos atrás da hélice);
- CAD;
- aeroelasticidade dinâmica;
- otimização estrutural e FEM;
- FMEA.

---

## Quadro

Uma tarefa só vai para **Pronto** quando as tarefas de que ela depende estão **Feito**. Máximo de 2 em **Fazendo**.

Tipos de tarefa:
- **[GUI]**: só ligar na interface.
- **[ext]**: estende um módulo existente.
- **[novo]**: módulo novo numa arquitetura existente.
- **[zero]**: arquitetura nova.

| ID | Tarefa | Tipo | Depende de | Milestone | Estado |
|---|---|---|---|---|---|
| T00 | Checks de regressão em `tools/checks` (comparação bit a bit contra uma ref, núcleo, AeroDrive, testes por área) | [novo] | — | 0.1.1 | Feito |
| T01 | Conferir os ❓ | leitura | — | 0.1.3 | Feito |
| T02 | Rodar os checks na pilha e corrigir | [ext] | T00 | 0.1.2 | Feito (tudo verde, nada a corrigir) |
| T03 | PRs da pilha para a `main` | git | T02 | 0.1.4 | Pronto (espera o ok do dono) |
| T04 | E&C: ME × xCG com ênfase, passeio do CG (o limite pela rotação já existe) | [ext] | — | 0.2.1 | Feito |
| T05 | E&C: polos com vento e com sloshing (estender a linearização no Zig: hoje o líquido é congelado; vento constante não muda os polos, o efeito é a turbulência) | [ext] | T30 | 0.8.5 | Bloqueado |
| T06 | Curvas com fator de carga (planeio e pouso já existem) | [ext] | — | 0.2.2 | Pronto |
| T07 | C-rate × corrente de pico (o consumo por etapa já existia) | [ext] | — | 0.2.3 | Feito |
| T08 | Esteira: trimagem com esteira e tubo desviado (ligar já existe na GUI) | [ext] | — | 0.3.1 | Pronto |
| T09 | Distribuição a α na aba Aerodinâmica | [GUI] | — | 0.3.2 | Pronto |
| T10 | Reynolds no núcleo (tabela por Re) | [ext] | — | 0.3.3 | Pronto |
| T11 | Arrasto por componente | [ext] | — | 0.3.4 | Pronto |
| T12 | Aba Cargas (distribuição + 3D) | [GUI] | — | 0.4.1 | Pronto |
| T13 | Casos de carga do V-n | [ext] | — | 0.4.2 | Pronto |
| T14 | Rajada por norma | [novo] | — | 0.4.3 | Pronto |
| T15 | Cortante, fletor e torsor | [novo] | T13, T14 | 0.4.4 | Bloqueado |
| T16 | Manobras dinâmicas (o 6GDL monta os casos) | [ext] | T13 | 0.5.1 | Bloqueado |
| T17 | Momento de dobradiça (distribuição na corda, método da literatura) | [novo] | — | 0.5.2 | Pronto |
| T18 | Cargas no solo | [novo] | — | 0.5.3 | Pronto |
| T19 | Torque de servos, bateria de servos, cabos | [novo] | T17 | 0.5.4 | Bloqueado |
| T20 | Arquitetura de estruturas + banco de materiais (os dados vêm do usuário ou da literatura) | [zero] | — | 0.6.1 | Pronto |
| T21 | Longarina | [zero] | T15, T20 | 0.6.2 | Bloqueado |
| T22 | Tubo de cauda | [zero] | T15, T20 | 0.6.3 | Bloqueado |
| T23 | Trem (eixo, garfo) | [zero] | T18, T20 | 0.6.4 | Bloqueado |
| T24 | Rigidez e centro elástico | [novo] | T21 | 0.7.1 | Bloqueado |
| T25 | Divergência | [novo] | T24 | 0.7.2 | Bloqueado |
| T26 | Reversão de comando | [novo] | T24 | 0.7.3 | Bloqueado |
| T27 | Diedro elástico em E&C | [ext] | T21 | 0.7.4 | Bloqueado |
| T28 | Paralelismo no núcleo | [ext] | — | 0.8.1 | Pronto |
| T29 | Monte Carlo e sensibilidade | [novo] | T28 | 0.8.2 | Bloqueado |
| T30 | Turbulência Dryden | [novo] | — | 0.8.3 | Pronto |
| T31 | Vento cruzado na decolagem | [ext] | — | 0.8.4 | Pronto |
| T32 | Modos de vibração e flutter | [novo] | T21 | 0.9.1 | Bloqueado |
| T33 | Aba de controle | [GUI] | — | 0.9.2 | Pronto |
| T34 | Caixa, montagem e desmontagem | [novo] | — | 0.9.3 | Pronto |
| T35 | Importador de dados medidos → comparação com ensaio e voo real | [novo] | — | 0.9.4 | Pronto |

**Caminho crítico:** T13 → T15 → T21 → T24 → T25/T26 → T32. Estruturas e aeroelasticidade esperam por ele.

---

## Itens por área

Legenda das colunas **Código** e **GUI**:
- ✅ coberto (na GUI: roda e mostra);
- 🟡 parcial;
- ❌ não existe;
- ❓ a conferir.

### 1. Aerodinâmica

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| AE-01 | Biblioteca de perfis, polares 2D por Reynolds, cache | ✅ | ✅ | — | `aero/sections.py`, `data/airfoils` |
| AE-02 | Asa finita: LLT, AVL, ASB, importar XFLR5 | ✅ | ✅ | — | comparação de métodos |
| AE-03 | Asa por partições, perfil por seção | ✅ | ✅ | — | sprint Asa |
| AE-04 | Polar do avião completo | ✅ | ✅ | — | aba Aerodinâmica → Polar |
| AE-05 | Dispositivos de ponta de asa | ✅ | ✅ | — | `aero/tipdevices.py` |
| AE-06 | Arrasto por componente | 🟡 | ❌ | T11 | só a área de arrasto da fuselagem |
| AE-07 | Downwash na cauda | 🟡 | 🟡 | T09 | empírico na simulação; ferraduras nas cargas |
| AE-08 | Efeito solo (McCormick) | ✅ | ✅ | — | modifier `solo.mccormick`; Configuração → Modificadores |
| AE-09 | Efeito solo por imagem (inclui a mesa) | ❌ | ❌ | — | modifier novo |
| AE-10 | Esteira da hélice nas superfícies | 🟡 | 🟡 | T08 | `esteira.disco` (Configuração → Modificadores); tubo reto, trimagem sem esteira |
| AE-11 | Reynolds no núcleo | ❌ | ❌ | T10 | |
| AE-12 | Distribuição ao longo da envergadura a um α | ✅ | ❌ | T09 | `core/src/loads/llt.zig` |
| AE-13 | Comparação com ensaio | ❌ | ❌ | T35 | |

### 2. Desempenho

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| DE-01 | Motor + hélice + bateria | ✅ | ✅ | — | Desempenho → Tração |
| DE-02 | Biblioteca de motores e hélices de saída | 🟡 | 🟡 | T01 | |
| DE-03 | Comparação de conjuntos motopropulsores | 🟡 | 🟡 | — | sprint Motores |
| DE-05 | Ajuste de ensaio dinâmico de hélice | ❌ | ❌ | T35 | |
| DE-06 | Decolagem com pista limitada / mesa | ✅ | ✅ | — | |
| DE-07 | Decolagem com vento cruzado | ❌ | ❌ | T31 | |
| DE-08 | MTOW × altitude-densidade | ✅ | ✅ | — | |
| DE-09 | Subida, nivelado, envelope | ✅ | ✅ | — | |
| DE-10 | Curvas com fator de carga | 🟡 | 🟡 | T06 | |
| DE-11 | Planeio | ✅ | ✅ | — | Desempenho → Planeio |
| DE-12 | Pouso | ✅ | ✅ | — | etapa "pouso" da Missão; `landingRun` no sizing |
| DE-13 | Consumo por fase de voo | ✅ | ✅ | — | Missão: consumo por etapa (com corrente de pico) |
| DE-15 | Monte Carlo e sensibilidade | ❌ | ❌ | T29 | |
| DE-16 | Turbulência contínua | ❌ | ❌ | T30 | |

DE-04 (perda de tração por corpos atrás da hélice) foi para as Torres, com o CFD 3D. DE-14 (massa total controlada na
pista) é ajuste de interface e está em "Fora da conta".

### 3. Estabilidade e Controle

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| EC-01 | Estática longitudinal (PN, ME) | ✅ | ✅ | — | |
| EC-02 | ME × xCG com ênfase | ✅ | ✅ | — | Estabilidade (ME × xCG) + Missão (ME no tempo) |
| EC-03 | Passeio do CG (LAPES, líquido) | ✅ | ✅ | — | Missão: passeio do CG e ME ao longo do voo |
| EC-04 | Limite dianteiro do CG pela rotação | ✅ | ✅ | — | Estabilidade: "decola rodando sobre o trem" |
| EC-05 | Diagrama tesoura | ✅ | ✅ | — | |
| EC-06 | Trimagem | ✅ | ✅ | — | |
| EC-07 | Dimensionamento de EH/EV e comandos | ✅ | ✅ | — | |
| EC-08 | Vento de través no pouso | ✅ | ✅ | — | Estabilidade: leme em vento cruzado (FAR 23.233) |
| EC-09 | Taxa de rolamento | ✅ | ✅ | — | Estabilidade: tempo para inclinar × aileron |
| EC-10 | Dinâmica: modos e respostas | ✅ | ✅ | — | |
| EC-11 | Qualidades de voo (MIL-F-8785C) | ✅ | ✅ | — | |
| EC-12 | Vento lateral/frontal nos polos | ❌ | ❌ | T05 | |
| EC-13 | Polos com sloshing | ❌ | ❌ | T05 | |
| EC-14 | Diedro elástico | ❌ | ❌ | T27 | |
| EC-15 | Comparação com voo real | ❌ | ❌ | T35 | |
| EC-16 | Inverter a rotação de qualquer motor | ✅ | ✅ | — | Configuração → motor: sentido de rotação |

### 4. Cargas

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| CA-01 | Distribuição por superfície (V, n, rpm, com/sem hélice) | ✅ | ❌ | T12 | `aero/span_loads.py` |
| CA-02 | Vista 3D e gráficos | ✅ | ❌ | T12 | `LoadView` |
| CA-03 | Casos do V-n | 🟡 | 🟡 | T13 | |
| CA-04 | Rajada por norma | ❌ | ❌ | T14 | |
| CA-05 | Manobras dinâmicas | ❌ | ❌ | T16 | |
| CA-06 | Cortante, fletor, torsor | ❌ | ❌ | T15 | |
| CA-07 | Momentos de dobradiça | ❌ | ❌ | T17 | |
| CA-08 | Cargas no solo | ❌ | ❌ | T18 | |

### 5. Aeroelasticidade

| ID | Tópico | Código | GUI | Tarefa |
|---|---|---|---|---|
| AL-01 | Rigidez e centro elástico | ❌ | ❌ | T24 |
| AL-02 | Divergência | ❌ | ❌ | T25 |
| AL-03 | Reversão de comando | ❌ | ❌ | T26 |
| AL-04 | Modos e flutter | ❌ | ❌ | T32 |

### 6. Estruturas

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| ES-01 | Massas e inércias | ✅ | ✅ | — | Montagem |
| ES-02 | Longarina | ❌ | ❌ | T21 | |
| ES-03 | Tubo de cauda | ❌ | ❌ | T22 | |
| ES-04 | Materiais | ❌ | ❌ | T20 | nunca dos relatórios de referência |
| ES-05 | Trem | ❌ | ❌ | T23 | |

### 7. Elétrica

| ID | Tópico | Código | GUI | Tarefa |
|---|---|---|---|---|
| EL-01 | C-rate × corrente de pico | ✅ | ✅ | — |
| EL-02 | Torque de servos | ❌ | ❌ | T19 |
| EL-03 | Bateria dos servos, cabos | ❌ | ❌ | T19 |

### 8. Integração / Projeto

| ID | Tópico | Código | GUI | Tarefa | Onde |
|---|---|---|---|---|---|
| IN-01 | MDO (PSO, pontuação) | ✅ | ✅ | — | página MDO |
| IN-02 | Projeto do zero em etapas (sprint em pasta) | ✅ | ✅ | — | `aerosim/design` |
| IN-03 | Montagem sem exigir decolagem | ✅ | ✅ | — | |
| IN-04 | Tração e Missão dentro de Desempenho | ✅ | ✅ | — | |
| IN-05 | xCG em % CMA | ✅ | ✅ | — | |
| IN-06 | Checklist do avião | ✅ | ✅ | — | |
| IN-08 | Volume e arranjo da caixa | ❌ | ❌ | T34 | |
| IN-09 | Tempo de montagem e desmontagem | ❌ | ❌ | T34 | |

### 9. Controle

| ID | Tópico | Código | GUI | Tarefa |
|---|---|---|---|---|
| CO-01 | Piloto automático genérico (autotune) | ✅ | ✅ | — |
| CO-02 | Aba de controle | ❌ | ❌ | T33 |

### Fora da conta da 1.0

**Opcionais** (dependem de dados de cada um):
- IN-07: banco histórico de pesos;
- IN-10: circuito real medido no mapa.

**Ajuste de interface:**
- DE-14: massa total controlada na pista.

**Torres:**
- AE-14: CFD 3D (inclui DE-04);
- AE-15: CAD;
- AL-05: aeroelasticidade dinâmica;
- ES-06 e ES-07: otimização estrutural e FEM;
- EL-04: FMEA;
- CO-03: SMC e NN-MPC;
- CO-04 e CO-05: VTOL/tailsitter e a pesquisa sobre helicóptero.

**Infraestrutura:**
- IF-01: hash da ABI ✅;
- IF-02: modifiers ✅;
- IF-03: colisão ✅;
- IF-04: integrador adaptativo;
- IF-05: números duais;
- IF-06: SIMD;
- IF-07: paralelismo (→ T28);
- IF-08: testes de propriedade 🟡;
- IF-09: checks de regressão no repositório (→ T00).

---

## Progresso para a 1.0

São os itens das seções 1 a 9 com ✅ na GUI. Os ❓ contam como não feitos.

**Onde foi medido:** na ponta da pilha de branches, não na `main`. Parte do que está ✅ só chega à `main` com a pilha.

| Seção | ✅ na GUI / itens |
|---|---|
| 1. Aerodinâmica | 6 / 13 |
| 2. Desempenho | 7 / 14 |
| 3. Estabilidade e Controle | 12 / 16 |
| 4. Cargas | 0 / 8 |
| 5. Aeroelasticidade | 0 / 4 |
| 6. Estruturas | 1 / 5 |
| 7. Elétrica | 1 / 3 |
| 8. Integração | 6 / 8 |
| 9. Controle | 1 / 2 |
| **Total** | **34 / 73 (47 %)** |

---

## Versionamento

**Regras**
- Nada direto na `main`. Cada trabalho tem a sua branch; a `main` só recebe por PR.
- Uma branch por tema: `feature/<tema>`, `fix/<tema>`, `docs/<tema>`, `test/<tema>`.
- Cada PR roda `python tools/checks/run.py`, atualiza este arquivo e o `CHANGELOG.md`.
- Tag `vX.Y.Z` só na `main`, depois do merge.
- Relatórios e dados de terceiros nunca entram no git.

**Situação atual das branches** (em relação à `main`)
- A pilha `feature/sprint` → `feature/gui` → `feature/aero` → `feature/modifiers` → `docs/tracking` →
  `test/checks` → `feature/analises-simples` ainda não foi para a `main`.
- `feature/aircraft-drive` e `claude/ecstatic-gates-u3lpoi` não têm nada a mais que a `main`.

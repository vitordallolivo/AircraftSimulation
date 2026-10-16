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
        [Torres]   fora da lista: CFD 3D, VTOL/tailsitter, controle não linear, CAD
   ┌──────────────────────────────────────────────────────┐
 3 │ Andar 3: Estruturas · Aeroelasticidade                 │ ← arquitetura nova (do zero)
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

- **A `main` está em `v0.2.0`** (milestone de fundação fechado, PRs #21–#25).
- **Cada tarefa concluída e mesclada sobe só o último número:** `0.2.1`, `0.2.2`, `0.2.3`…
- **Quando toda a lista de tarefas abaixo estiver feita, vira `0.3.0`.** Não há data nem promessa de 1.0: nada vira
  release sem o dono testar pessoalmente cada componente.
- O trabalho fica numa branch só, `0.2_dev`. Cada tarefa fechada vai por PR para a `main` e para no review.
- As tags só são criadas com o ok do dono do repositório.

## Blocos de trabalho (ordem)

Os blocos só ordenam a lista; não são versões.

| Bloco | O que | Tarefas |
|---|---|---|
| **B1** | Fundação (feito) | checks de regressão, conferir os ❓, pilha na `main` |
| **B2** | Análises simples | passeio do CG e ME no tempo · curvas com fator de carga |
| **B3** | Aero completo na GUI | trimagem com esteira e tubo desviado · distribuição a α · Reynolds no núcleo · arrasto por componente |
| **B4** | Cargas I | aba Cargas · casos do V-n · rajada · cortante, fletor e torsor |
| **B5** | Cargas II | manobras dinâmicas · momentos de dobradiça · cargas no solo |
| **B6** | Estruturas (do zero) | arquitetura + materiais · longarina · tubo de cauda · trem |
| **B7** | Aeroelasticidade estática | rigidez e centro elástico · divergência · reversão · diedro elástico |
| **B8** | Incerteza e atmosfera | paralelismo · Monte Carlo · Dryden · vento cruzado · estabilidade não linear (Lyapunov, mapa da região de atração) |
| **B9** | Fechamento | modos e flutter · aba de controle · caixa e montagem · comparação com ensaio e voo real |

**Fora desta lista (menor prioridade):**
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

| ID | Tarefa | Tipo | Depende de | Bloco | Estado |
|---|---|---|---|---|---|
| T00 | Checks de regressão em `tools/checks` (comparação bit a bit contra uma ref, núcleo, AeroDrive, testes por área) | [novo] | — | B1 | Feito |
| T01 | Conferir os ❓ | leitura | — | B1 | Feito |
| T02 | Rodar os checks na pilha e corrigir | [ext] | T00 | B1 | Feito (tudo verde, nada a corrigir) |
| T03 | PRs da pilha para a `main` | git | T02 | B1 | Feito (PRs #21–#25) |
| T04 | E&C: ME × xCG com ênfase, passeio do CG (o limite pela rotação já existe) | [ext] | — | B2 | Feito |
| T05 | E&C: estabilidade dinâmica não linear (funções de Lyapunov e de energia, região de atração vista em mapa de calor; inclui sloshing e vento). Primeiro o plano com as fontes, depois o código | [novo] | — | B8 | Pronto (plano) |
| T06 | Curvas com fator de carga (planeio e pouso já existem) | [ext] | — | B2 | Pronto |
| T08 | Esteira: trimagem com esteira e tubo desviado (ligar já existe na GUI) | [ext] | — | B3 | Pronto |
| T09 | Distribuição a α na aba Aerodinâmica | [GUI] | — | B3 | Pronto |
| T10 | Reynolds no núcleo (tabela por Re) | [ext] | — | B3 | Pronto |
| T11 | Arrasto por componente | [ext] | — | B3 | Pronto |
| T12 | Aba Cargas (distribuição + 3D) | [GUI] | — | B4 | Pronto |
| T13 | Casos de carga do V-n | [ext] | — | B4 | Pronto |
| T14 | Rajada por norma | [novo] | — | B4 | Pronto |
| T15 | Cortante, fletor e torsor | [novo] | T13, T14 | B4 | Bloqueado |
| T16 | Manobras dinâmicas (o 6GDL monta os casos) | [ext] | T13 | B5 | Bloqueado |
| T17 | Momento de dobradiça (distribuição na corda, método da literatura) | [novo] | — | B5 | Pronto |
| T18 | Cargas no solo | [novo] | — | B5 | Pronto |
| T20 | Arquitetura de estruturas + banco de materiais (os dados vêm do usuário ou da literatura) | [zero] | — | B6 | Pronto |
| T21 | Longarina | [zero] | T15, T20 | B6 | Bloqueado |
| T22 | Tubo de cauda | [zero] | T15, T20 | B6 | Bloqueado |
| T23 | Trem (eixo, garfo) | [zero] | T18, T20 | B6 | Bloqueado |
| T24 | Rigidez e centro elástico | [novo] | T21 | B7 | Bloqueado |
| T25 | Divergência | [novo] | T24 | B7 | Bloqueado |
| T26 | Reversão de comando | [novo] | T24 | B7 | Bloqueado |
| T27 | Diedro elástico em E&C | [ext] | T21 | B7 | Bloqueado |
| T28 | Paralelismo no núcleo | [ext] | — | B8 | Pronto |
| T29 | Monte Carlo e sensibilidade | [novo] | T28 | B8 | Bloqueado |
| T30 | Turbulência Dryden | [novo] | — | B8 | Pronto |
| T31 | Vento cruzado na decolagem | [ext] | — | B8 | Pronto |
| T32 | Modos de vibração e flutter | [novo] | T21 | B9 | Bloqueado |
| T33 | Aba de controle | [GUI] | — | B9 | Pronto |
| T34 | Caixa, montagem e desmontagem | [novo] | — | B9 | Pronto |
| T35 | Importador de dados medidos → comparação com ensaio e voo real | [novo] | — | B9 | Pronto |

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
| AE-08 | Efeito solo (McCormick) | ✅ | ❓ | T08 | modifier `solo.mccormick` |
| AE-09 | Efeito solo por imagem (inclui a mesa) | ❌ | ❌ | — | modifier novo |
| AE-10 | Esteira da hélice nas superfícies | 🟡 | ❌ | T08 | `esteira.disco`; tubo reto |
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
| EC-08 | Vento de través no pouso | ❓ | ❓ | T01 | |
| EC-09 | Taxa de rolamento (pb/2V) | ❓ | ❓ | T01 | |
| EC-10 | Dinâmica: modos e respostas | ✅ | ✅ | — | |
| EC-11 | Qualidades de voo (MIL-F-8785C) | ✅ | ✅ | — | |
| EC-12 | Vento lateral/frontal nos polos | ❌ | ❌ | T05 | |
| EC-13 | Polos com sloshing | ❌ | ❌ | T05 | |
| EC-14 | Diedro elástico | ❌ | ❌ | T27 | |
| EC-15 | Comparação com voo real | ❌ | ❌ | T35 | |
| EC-16 | Inverter a rotação de qualquer motor | ❓ | ❓ | T01 | |

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

### 7. Elétrica — fora do escopo

O simulador dimensiona a aeronave. Escolher bateria, servos e cabos é trabalho da área de elétrica e não entra aqui.
A Missão mostra só o que a simulação já calcula: a corrente média e a de pico por etapa e o consumo.

### 8. Integração / Projeto

| ID | Tópico | Código | GUI | Tarefa | Onde |
|---|---|---|---|---|---|
| IN-01 | MDO (PSO, pontuação) | ✅ | ✅ | — | página MDO |
| IN-02 | Projeto do zero em etapas (sprint em pasta) | ✅ | ✅ | — | `aerosim/design` |
| IN-03 | Montagem sem exigir decolagem | ✅ | ✅ | — | |
| IN-04 | Tração e Missão dentro de Desempenho | ✅ | ✅ | — | |
| IN-05 | xCG em % CMA | ✅ | ✅ | — | |
| IN-06 | Checklist do avião | ✅ | ✅ | — | |
| IN-08 | Volume e arranjo da caixa | ❓ | ❓ | T34 | |
| IN-09 | Tempo de montagem e desmontagem | ❌ | ❌ | T34 | |

### 9. Controle

| ID | Tópico | Código | GUI | Tarefa |
|---|---|---|---|---|
| CO-01 | Piloto automático genérico (autotune) | ✅ | ✅ | — |
| CO-02 | Aba de controle | ❌ | ❌ | T33 |

### Fora da lista

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

## Progresso da lista (0.3 quando chegar ao fim)

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
| 8. Integração | 6 / 8 |
| 9. Controle | 1 / 2 |
| **Total** | **33 / 70 (47 %)** |

---

## Versionamento

**Regras**
- Nada direto na `main`; a `main` só recebe por PR.
- **Uma branch de desenvolvimento só: `0.2_dev`.** Não se abre branch por tarefa.
- Ao fechar uma tarefa:
  1. a `main` é mesclada na `0.2_dev`, para não levar a `main` para trás;
  2. rodam os checks (`python tools/checks/run.py --tudo`);
  3. abre-se o PR `0.2_dev` → `main`, e o trabalho para até o review;
  4. o merge sobe o último número da versão (`0.2.1`, `0.2.2`…).
- Cada PR atualiza este arquivo e o `CHANGELOG.md`.
- Tag `vX.Y.Z` só na `main`, depois do merge.
- Relatórios e dados de terceiros nunca entram no git.

**Situação atual das branches**
- `main`: `v0.2.0` (PRs #21–#25).
- `0.2_dev`: T04 feito (vira `0.2.1` com o merge); T06 por fazer.
- As branches antigas foram apagadas aqui; no GitHub, o dono apaga (a sessão não tem permissão).

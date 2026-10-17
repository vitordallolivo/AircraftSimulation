# Tracking do projeto

Lista única do que o simulador cobre e do que falta. Junta as áreas de um projeto AeroDesign completo e as ideias de
`ideias.md`. É um juízo de valor, não uma análise: nada aqui foi calculado.

**Referência das áreas:** relatórios de projeto completos de uma equipe. Eles **não estão no git** e nenhum dado deles
entra aqui; servem só como lista do que um projeto cobre.

**Cuidado com estruturas:** os relatórios de referência têm valores inconsistentes nessa área. Servem como lista de
tópicos, nunca como fonte de números.

**Regras para toda tarefa:**
- **Restrição, norma e método nunca são padrão.** Regulamento de competição, norma (FAR, CS-VLA, MIL-F-8785C, STANAG)
  e método da literatura só valem quando o usuário escolhe e preenche (um preset dentro do módulo). Sem preset, a
  análise calcula e mostra, mas não aprova nem reprova nada.
- **Conta no núcleo.** Módulo que calcula é escrito em Zig, em `core/`, de preferência; o Python monta o caso e
  traduz.
- **Cargas é análise tardia.** Só roda com um modelo pronto (conjunto escolhido, MTOW, polares e envelope). Sem isso, a
  aba diz o que falta.

**Fluxo de projeto que o programa segue** (iterativo: qualquer etapa pode mandar voltar):
perfis → asas → E&C (estática, com o diâmetro da hélice vindo do Desempenho) → superfícies móveis → conjuntos
(asa + superfícies; vários por asa) → Desempenho analítico (não descarta nenhum) → decolagem e MTOW por conjunto →
envelopes (subida, descida, planeio, voo) → Cargas → Estruturas (fuselagem, longarina, tubo de cauda).

Como usar:
1. Olhe a coluna **Pronto** do quadro.
2. Pegue no máximo 2 tarefas.
3. Ao fechar uma tarefa, atualize os itens que ela mexe e o progresso.

---

## O castelo (mapa)

```
        [Torres]   fora da lista: CFD 3D, VTOL/tailsitter, controle não linear, CAD, hardware-in-the-loop
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

- **A `main` está em `v0.2.2`** (PR #27). O milestone de fundação fechou na `v0.2.0` (PRs #21–#25).
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
| **B1+** | Proteção e medição (local, sem CI pago) | perfil (flame graph) · snapshot das abas · smoke das abas · lint + hook de pre-push · tempo como regressão · propriedades · avisos de documentação |
| **B2** | Análises simples | passeio do CG e ME no tempo · curvas com fator de carga · restrições e normas como preset do usuário · Desempenho por etapa de voo (envelopes, decolagem com MTOW, subida, curva, descida e pouso) |
| **B3** | Aero completo na GUI | **flape (prioridade)** · linha sustentadora corrigida e não linear · esteira desviada · trimagem com esteira e tubo desviado · distribuição a α · Reynolds no núcleo · arrasto por componente |
| **B4** | Cargas I | aba Cargas · arquitetura de cargas e aeroelasticidade · casos do V-n · rajada · cortante, fletor e torsor |
| **B5** | Cargas II | manobras dinâmicas · momentos de dobradiça · cargas no solo |
| **B6** | Estruturas (do zero) | arquitetura + materiais · longarina · tubo de cauda · trem · redistribuição de cargas |
| **B7** | Aeroelasticidade estática | rigidez e centro elástico · divergência · reversão · diedro elástico |
| **B8** | Incerteza e atmosfera | paralelismo · Monte Carlo · Dryden · vento cruzado · estabilidade não linear (Lyapunov, mapa da região de atração) |
| **B9** | Fechamento | modos e flutter · aba de controle · caixa e montagem · comparação com ensaio e voo real · V-n com dados de voo · etapas desatualizadas |

**Fora desta lista (menor prioridade):**
- VTOL/tailsitter;
- controle não linear;
- CFD 3D (inclui a perda de tração por corpos atrás da hélice);
- CAD: exportar a geometria e a rugosidade (STEP, para SolidWorks);
- configurações genéricas: tandem, biplano;
- sloshing configurável (quanto líquido e onde);
- hardware-in-the-loop no AeroDrive: placa ligada ao PC, pilotando o avião real e a simulação ao mesmo tempo (gêmeo
  digital);
- dividir o aerosim em programas separados;
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
| T36 | Guia de desenvolvimento: `.claude/CLAUDE.md` (objetivo, conceitos, decisões, fluxo, métricas) e mapa do código gerado (`tools/codemap.py` → `docs/MAP.md`, com check) | [novo] | — | B1 | Feito |
| T47 | Ferramenta de perfil `tools/time_profile.py`: flame graph (py-spy `--native`, Python + Zig) e tabela por função (tempo próprio, total, chamadas, %); `--exato` pelo Callgrind; núcleo com símbolos (`-Dstrip=false`) | [novo] | — | B1+ | Pronto |
| T48 | Snapshot do resultado de cada aba (resumo + diagnóstico por template, valores padrão) em `tools/checks`, com `--aceitar` para mudança intencional | [ext] | — | B1+ | Pronto |
| T49 | Smoke test de todas as abas e subabas: abre sem tela, roda com os padrões, todo gráfico declarado tem dado | [ext] | — | B1+ | Pronto |
| T50 | Lint (`ruff`, `zig fmt --check`) em `tools/checks` e hook de `pre-push` com os checks rápidos (`tools/hooks/`, `core.hooksPath`) | [ext] | — | B1+ | Pronto |
| T51 | Tempo como regressão: benchmarks e abas contra a `main`, só aviso | [ext] | T47 | B1+ | Bloqueado |
| T52 | Testes de propriedade (simetria, soma das cargas, monotonicidade, R·ω = V…), cada lei com fonte | [novo] | — | B1+ | Pronto |
| T53 | Avisos de documentação (README em pasta nova, fonte de fórmula no Zig, CHANGELOG no PR) | [ext] | — | B1+ | Pronto |
| T02 | Rodar os checks na pilha e corrigir | [ext] | T00 | B1 | Feito (tudo verde, nada a corrigir) |
| T03 | PRs da pilha para a `main` | git | T02 | B1 | Feito (PRs #21–#25) |
| T04 | E&C: ME × xCG com ênfase, passeio do CG (o limite pela rotação já existe) | [ext] | — | B2 | Feito |
| T05 | E&C: estabilidade dinâmica não linear (funções de Lyapunov e de energia, região de atração vista em mapa de calor; inclui sloshing e vento). Primeiro o plano com as fontes, depois o código | [novo] | — | B8 | Pronto (plano) |
| T06 | Curvas com fator de carga na Missão e nas curvas (n_z, 1/cos φ, n no estol) | [ext] | — | B2 | Feito (vai no PR da T12) |
| T42 | Desempenho por etapa de voo, 1: subaba "Voo nivelado e envelopes" com todos os envelopes (planilha e modelo completo, `envelope.py` ganha aba) | [GUI] | — | B2 | Feito |
| T43 | Desempenho, 2: subaba Decolagem (analítica + 6GDL) com a caixa "MTOW para o comprimento de pista": varredura da massa total ou fragmentada (componentes ligáveis, cada um com mín., máx., inicial e passo do usuário); o modo MTOW avulso sai | [ext] | — | B2 | Pronto |
| T44 | Desempenho, 3: subida (a simulada está errada: γ obtido não segue o pedido) junto com a analítica | [ext] | — | B2 | Pronto |
| T45 | Desempenho, 4: subaba Curva única (`turn.py` + Missão "curvas"), analítica + numérica | [ext] | — | B2 | Pronto |
| T46 | Desempenho, 5: descida, planeio e pouso, analíticos e numéricos | [ext] | — | B2 | Pronto |
| T37 | Restrições, normas e métodos como preset do usuário: tirar os padrões (MIL-F-8785C, FAR 23.233, RC > 0,5 m/s, 3 m nas curvas, φ 75°...); sem preset, só mostra | [ext] | — | B2 | Pronto |
| T08 | Esteira: trimagem com esteira e tubo desviado (ligar já existe na GUI) | [ext] | — | B3 | Pronto |
| T09 | Distribuição a α na aba Aerodinâmica | [GUI] | — | B3 | Pronto |
| T10 | Reynolds no núcleo (tabela por Re) | [ext] | — | B3 | Pronto |
| T54 | **Prioridade da aerodinâmica.** Flape de verdade (no Navion com flape a 20°, o núcleo precisa de α = 10° para o C_L do voo; o VLM, 4,7°): hoje o flape é só uma deflexão fixa somada à incidência (`tau · deflexão`), sem ΔC_l máx, sem ΔC_d, sem ΔC_m, sem comando na simulação. Por tipo (simples, ventral, fendido, Fowler), com método da literatura escolhido pelo usuário; comandável na decolagem e no pouso; entra na linha sustentadora (corda e α0 por faixa) e na esteira. Primeiro o plano com as fontes | [ext] | — | B3 | Pronto |
| T55 | Linha sustentadora (cargas): ferraduras com os nós no 1/4 de corda das bordas de cada faixa (Phillips e Snyder 2000; Hunsaker e Snyder), corrige superfície enflechada e winglet (carga crescendo para a ponta); depois a versão não linear com C_l(α) de cada perfil (Newton) | [ext] | — | B3 | Fazendo |
| T56 | Hélice no chão: folga da ponta da pá a cada passo; folga < 0 encerra o voo ("hélice tocou o chão") com `ac.sim.prop_strike = True` (desligado por padrão: o exemplo `flying_wing` começa com a pá dentro do chão); folga mínima por norma só como preset do usuário | [ext] | — | B2 | Pronto |
| T59 | Otimização de perfis (futuro): forma do perfil por parâmetros (ex.: CST/Kulfan) com o polar do NeuralFoil (AeroSandbox, já instalado) ou do XFOIL (o motor do XFLR5), objetivo e restrições escolhidos pelo usuário (C_l máx, C_d no cruzeiro, C_m, espessura), atrás da interface de perfis; o perfil otimizado entra na biblioteca. Primeiro o plano com as fontes | [novo] | — | B3 | Pronto |
| T60 | Validação contra avião real: o Ryan Navion (NASA TN D-6643) montado com a Tabela I e a Figura 2 (`tools/validacao/navion.py`), derivadas de cada método × voo, teste em `tests/validation` | [novo] | — | B3 | Feito (a revisar) |
| T61 | Contribuição da fuselagem (C_mα, C_nβ, C_Yβ) e interferência asa–fuselagem no efeito diedro por método da literatura escolhido pelo usuário (hoje o usuário digita os números ou fica zero). No Navion, sem ela (todos os métodos, inclusive o AVL): C_mα −1,2 a −1,9 × −0,77 do voo, C_Yβ ~−0,2 × −0,60. Primeiro o plano com as fontes | [novo] | T60 | B3 | Pronto |
| T62 | Núcleo: efeito diedro (C_lβ −0,139 × AVL −0,079 × voo −0,070 no Navion) e C_Lq (4,8 × AVL 9,5 × voo 15,9). Achar a causa nas faixas do núcleo e corrigir com fonte | [ext] | T60 | B3 | Pronto |
| T63 | Perfis de teste dos coeficientes (`tools/aero`): aviões só de superfícies (sem fuselagem e sem motor) a 12 m/s, todos os métodos e variantes do núcleo (malha, efeito solo, linha sustentadora), distância até qualquer método ou CSV de fora, matriz entre os métodos, varredura de malha e de V, perfil por .dat; figuras em `docs/img/aero_*.png` | [novo] | — | B3 | Feito (a revisar) |
| T64 | Linha sustentadora de Goates e Hunsaker 2021 no núcleo (`Params.llt_joint`, `llt_blend`; desligada por padrão): junta das pernas, linha efetiva por ponto de controle e seção normal à linha. Converge em derrapagem e com enflechamento; C_Lα a 1,5 % e C_lβ a 3 % do MachUpX (teste em `tests/tools`, `zig build test`). Método novo na aba Cargas (`llt_gh`) e no `tools/aero` (`nucleo_gh`) | [ext] | T63 | B3 | Feito (a revisar) |
| T65 | Voar com outro modelo aerodinâmico. Fase A (feita): `tools/aero/decolagem.py` reavalia cada ponto da decolagem com todos os métodos; `aerosim_aero_coeffs_llt`. Fase B (feita, a revisar): `Params.aero_model` (`physics/aeromodel.zig`; 0 = faixas, padrão, bit a bit igual; o AeroDrive fica no de sempre), linha sustentadora (1) e tabela de qualquer método (2, `aerotable.zig`, `aerosim/aero/flight_table.py`), `ac.sim.aero_model`; `tools/aero/missao.py` voa a decolagem e a missão com cada modelo. Fase C: efeito solo por imagens na linha sustentadora e nas tabelas (Katz e Plotkin, a conferir); deixar a linha sustentadora de Goates e Hunsaker mais rápida (53 min na missão) | [ext] | T64 | B3 | Fazendo |
| T58 | Cargas pelo AeroSandbox: o VLM do ASB como mais um método da aba Cargas, atrás da interface (`ILoadMethod` → `LoadResult`): distribuição por faixa, vista 3D e comparação lado a lado com a linha sustentadora do núcleo, no mesmo ponto de voo. Serve de referência independente para winglet, enflechamento e diedro | [ext] | — | B4 | Feito (a revisar) |
| T57 | Esteira desviada pelo escoamento e com perfil radial (Duivenvoorden et al. 2026; correção de Rethorst, Exalto et al. 2024; Goates 2018), validada contra Stuper (NACA TM 874) | [ext] | T55 | B3 | Bloqueado |
| T11 | Arrasto por componente | [ext] | — | B3 | Pronto |
| T12 | Aba Cargas (distribuição + 3D; hélice do conjunto motopropulsor do avião; só com modelo pronto) | [GUI] | — | B4 | Feito |
| T38 | Arquitetura de cargas e aeroelasticidade: interfaces (conjunto de casos de carga, viga estrutural EI/GJ, laço aeroelástico), conta no núcleo. Primeiro o plano | [zero] | — | B4 | Pronto (plano) |
| T13 | Casos de carga do V-n (manobra; norma e n escolhidos pelo usuário), no núcleo; o V-n sai de Desempenho (`performance.py`, `envelope.py`) | [ext] | T38 | B4 | Bloqueado |
| T14 | Rajada (fórmula e norma escolhidas pelo usuário) | [novo] | T38 | B4 | Bloqueado |
| T15 | Cortante, fletor e torsor | [novo] | T13, T14 | B4 | Bloqueado |
| T16 | Manobras dinâmicas (o 6GDL monta os casos) | [ext] | T13 | B5 | Bloqueado |
| T17 | Momento de dobradiça (distribuição na corda, método da literatura) | [novo] | T38 | B5 | Bloqueado |
| T18 | Cargas no solo | [novo] | T38 | B5 | Bloqueado |
| T20 | Arquitetura de estruturas + banco de materiais (os dados vêm do usuário ou da literatura) | [zero] | — | B6 | Pronto |
| T21 | Longarina | [zero] | T15, T20 | B6 | Bloqueado |
| T22 | Tubo de cauda | [zero] | T15, T20 | B6 | Bloqueado |
| T23 | Trem (eixo, garfo) | [zero] | T18, T20 | B6 | Bloqueado |
| T39 | Redistribuição das cargas para a malha da estrutura | [novo] | T15, T20 | B6 | Bloqueado |
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
| T40 | V-n refinado com dados de voo (sensoriamento) | [ext] | T13, T35 | B9 | Bloqueado |
| T41 | Etapas desatualizadas: cada etapa guarda a assinatura do modelo; mudou antes, as seguintes ficam marcadas | [ext] | — | B9 | Pronto |

**Caminho crítico:** T38 → T13 → T15 → T21 → T24 → T25/T26 → T32. Estruturas e aeroelasticidade esperam por ele.

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
| AE-02 | Asa finita: LLT, AVL, ASB, importar XFLR5 | ✅ | ✅ | T55 | comparação de métodos; a linha sustentadora do núcleo erra em superfície enflechada (T55) |
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
| AE-17 | Flape (ΔC_l, ΔC_l máx, ΔC_d, ΔC_m; comando na decolagem e no pouso) | 🟡 | ❌ | T54 | hoje só deflexão fixa na incidência da faixa |
| AE-18 | Otimização de perfis (NeuralFoil ou XFOIL) | ❌ | ❌ | T59 | futuro |

### 2. Desempenho

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| DE-01 | Motor + hélice + bateria | ✅ | ✅ | — | Desempenho → Tração |
| DE-02 | Biblioteca de motores e hélices de saída | 🟡 | 🟡 | — | catálogo em `data/catalog` (cfg/xlsx) |
| DE-03 | Comparação de conjuntos motopropulsores | 🟡 | 🟡 | — | sprint Motores |
| DE-05 | Ajuste de ensaio dinâmico de hélice | ❌ | ❌ | T35 | |
| DE-06 | Decolagem com pista limitada / mesa | ✅ | ✅ | — | |
| DE-07 | Decolagem com vento cruzado | ❌ | ❌ | T31 | |
| DE-08 | MTOW × altitude-densidade | ✅ | ✅ | — | |
| DE-09 | Subida, nivelado, envelope | ✅ | ✅ | — | |
| DE-10 | Curvas com fator de carga | ✅ | ✅ | — | Missão → Fator de carga (n_z, 1/cos φ, n no estol); curvas: raio mínimo → fator de carga no tempo e × raio |
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
| EC-08 | Vento de través no pouso | ✅ | ✅ | — | Estabilidade: leme com 0,2 V_S de través (FAR 23.233) |
| EC-09 | Taxa de rolamento (pb/2V) | ✅ | ✅ | — | Estabilidade: aileron por φ em t (MIL-F-8785C); pb/2V não é mostrado |
| EC-10 | Dinâmica: modos e respostas | ✅ | ✅ | — | |
| EC-11 | Qualidades de voo (MIL-F-8785C) | ✅ | ✅ | — | |
| EC-12 | Vento lateral/frontal nos polos | ❌ | ❌ | T05 | |
| EC-13 | Polos com sloshing | ❌ | ❌ | T05 | |
| EC-14 | Diedro elástico | ❌ | ❌ | T27 | |
| EC-15 | Comparação com voo real | ❌ | ❌ | T35 | |
| EC-16 | Inverter a rotação de qualquer motor | ✅ | ✅ | — | Configuração: botão de sentido (±1) por motor |

### 4. Cargas

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| CA-01 | Distribuição por superfície (V, n, rpm, com/sem hélice) | ✅ | ✅ | — | aba Cargas; `aero/span_loads.py` |
| CA-02 | Vista 3D e gráficos | ✅ | ✅ | — | aba Cargas (`LoadView`, gráfico `loads3d`) |
| CA-03 | Casos do V-n | 🟡 | 🟡 | T13 | |
| CA-04 | Rajada (fórmula e norma escolhidas pelo usuário) | ❌ | ❌ | T14 | |
| CA-05 | Manobras dinâmicas | ❌ | ❌ | T16 | |
| CA-06 | Cortante, fletor, torsor | ❌ | ❌ | T15 | |
| CA-07 | Momentos de dobradiça | ❌ | ❌ | T17 | |
| CA-08 | Cargas no solo | ❌ | ❌ | T18 | |
| CA-09 | Redistribuição das cargas para a estrutura | ❌ | ❌ | T39 | |
| CA-10 | V-n com dados de voo | ❌ | ❌ | T40 | |
| CA-11 | Método das cargas pelo VLM do AeroSandbox (comparação com a linha sustentadora) | ✅ | ✅ | T58 | aba Cargas → Método / Comparar com; `aero/asb_solver.py` (`AsbVLMLoads`) |

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
| IN-08 | Volume e arranjo da caixa | ❌ | ❌ | T34 | |
| IN-09 | Tempo de montagem e desmontagem | ❌ | ❌ | T34 | |
| IN-11 | Etapas desatualizadas (assinatura do modelo) | ❌ | ❌ | T41 | |
| IN-12 | Restrições, normas e métodos só por preset do usuário | ❌ | ❌ | T37 | |

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
- IF-08: testes de propriedade 🟡 (→ T52);
- IF-09: checks de regressão no repositório (→ T00).

---

## Progresso da lista (0.3 quando chegar ao fim)

São os itens das seções 1 a 9 com ✅ na GUI. Os ❓ contam como não feitos.

**Onde foi medido:** na `main` (`v0.2.2`), com os ❓ do T01 já conferidos no código.

| Seção | ✅ na GUI / itens |
|---|---|
| 1. Aerodinâmica | 6 / 15 |
| 2. Desempenho | 8 / 14 |
| 3. Estabilidade e Controle | 12 / 16 |
| 4. Cargas | 3 / 11 |
| 5. Aeroelasticidade | 0 / 4 |
| 6. Estruturas | 1 / 5 |
| 8. Integração | 6 / 10 |
| 9. Controle | 1 / 2 |
| **Total** | **37 / 77 (48 %)** |

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
- `main`: `v0.2.2` (PR #27).
- `0.2_dev`: correção do tracking, T06, T12 e T42 (commits `4062360` e `bb06118`); vão juntos no mesmo PR (`0.2.3`).
- As branches antigas foram apagadas aqui; no GitHub, o dono apaga (a sessão não tem permissão).

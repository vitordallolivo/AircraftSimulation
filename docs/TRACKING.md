# Tracking do projeto

Lista única do que o projeto cobre e do que falta, separada pelos quatro segmentos do repositório: **aerosim** (o
programa de projeto), **core** (o núcleo em Zig), **aerodrive** (o simulador de voo) e **aeroopt** (o otimizador). Junta
as áreas de um projeto AeroDesign completo e as ideias de `ideias.md`. É um juízo de valor, não uma análise: nada aqui
foi calculado.

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
        [Torres]   fora da lista: CFD 3D, controle não linear, CAD, hardware-in-the-loop
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
| **B9** | Fechamento | modos e flutter · aba de controle · comparação com ensaio e voo real · V-n com dados de voo · etapas desatualizadas |
| **B10** | aeroopt | pontuação por ano · contratos e `.opt.json` · expressão e álgebra linear no núcleo · ferramenta · GUI · orquestração · caixa · solvers locais · SIMD/GPU · substituto |

**Fora desta lista (menor prioridade):**
- controle não linear;
- CFD 3D (inclui a perda de tração por corpos atrás da hélice);
- CAD: exportar a geometria e a rugosidade (STEP, para SolidWorks);
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

O quadro tem uma tabela por segmento; o segmento é onde fica o grosso do trabalho da tarefa (uma conta nova no núcleo
com uma aba que a mostra fica no **core**, e a aba vira outra tarefa no **aerosim**). As dependências cruzam os
segmentos. As tarefas do aeroopt usam o prefixo **O**.

Tipos de tarefa:
- **[GUI]**: só ligar na interface.
- **[ext]**: estende um módulo existente.
- **[novo]**: módulo novo numa arquitetura existente.
- **[zero]**: arquitetura nova.

### aerosim

O programa de projeto (PyQt6): abas, sprint, manager, ferramentas de comparação em `tools/aero` e validação.

| ID | Tarefa | Tipo | Depende de | Bloco | Estado |
|---|---|---|---|---|---|
| T86 | E&C: onde fica o líquido (sloshing) e o que isso faz com os modos. Hoje o tanque fica sempre no CG de projeto, dentro da fuselagem (`aerosim/design/power.py`: cubo de 12 cm, 8 cm de altura, n lado a lado). A análise varre a posição do tanque (distância ao CG, embaixo da asa a uma distância da fuselagem) e o ângulo dele, e mostra os polos e as qualidades de voo de cada caso (curto período, fugóide, dutch roll, espiral) e o passeio do CG. Depois, se fizer sentido, as regras de construção do regulamento (garrafas, posição, volume; Regulamento 2026, seção a conferir no PDF) entram como escolha. Não é do aeroopt. Primeiro o plano com as fontes | [novo] | T05 | B2 | Pronto |
| T04 | E&C: ME × xCG com ênfase, passeio do CG (o limite pela rotação já existe) | [ext] | — | B2 | Feito |
| T06 | Curvas com fator de carga na Missão e nas curvas (n_z, 1/cos φ, n no estol) | [ext] | — | B2 | Feito (vai no PR da T12) |
| T42 | Desempenho por etapa de voo, 1: subaba "Voo nivelado e envelopes" com todos os envelopes (planilha e modelo completo, `envelope.py` ganha aba) | [GUI] | — | B2 | Feito |
| T43 | Desempenho, 2: subaba Decolagem (analítica + 6GDL) com a caixa "MTOW para o comprimento de pista": varredura da massa total ou fragmentada (componentes ligáveis, cada um com mín., máx., inicial e passo do usuário); o modo MTOW avulso sai | [ext] | — | B2 | Pronto |
| T44 | Desempenho, 3: subida (a simulada está errada: γ obtido não segue o pedido) junto com a analítica | [ext] | — | B2 | Pronto |
| T45 | Desempenho, 4: subaba Curva única (`turn.py` + Missão "curvas"), analítica + numérica | [ext] | — | B2 | Pronto |
| T46 | Desempenho, 5: descida, planeio e pouso, analíticos e numéricos | [ext] | — | B2 | Pronto |
| T37 | Restrições, normas e métodos como preset do usuário: tirar os padrões (MIL-F-8785C, FAR 23.233, RC > 0,5 m/s, 3 m nas curvas, φ 75°...); sem preset, só mostra | [ext] | — | B2 | Pronto |
| T09 | Distribuição a α na aba Aerodinâmica | [GUI] | — | B3 | Pronto |
| T11 | Arrasto por componente | [ext] | — | B3 | Pronto |
| T60 | Validação contra avião real: o Ryan Navion (NASA TN D-6643) montado com a Tabela I e a Figura 2 (`tools/validacao/navion.py`), derivadas de cada método × voo, teste em `tests/validation` | [novo] | — | B3 | Feito (a revisar) |
| T63 | Perfis de teste dos coeficientes (`tools/aero`): aviões só de superfícies (sem fuselagem e sem motor) a 12 m/s, todos os métodos e variantes do núcleo (malha, efeito solo, linha sustentadora), distância até qualquer método ou CSV de fora, matriz entre os métodos, varredura de malha e de V, perfil por .dat; figuras em `docs/img/aero_*.png` | [novo] | — | B3 | Feito (a revisar) |
| T66 | GUI: escolher o modelo aerodinâmico do voo (`ac.sim.aero_model`: faixas, linha sustentadora de Phillips e Snyder ou de Goates e Hunsaker, tabela) em Configuração → Integração. Mostrar o custo esperado (a linha sustentadora é ~65× mais lenta que as faixas na missão: 258–261 s contra 4 s), refinar a malha sozinho quando for a linha sustentadora (`tools/aero/coeficientes.refinar`) e avisar que o `.cfg` e a planilha não guardam o modelo nem a tabela (`not_exported`) | [GUI] | T65 | B3 | Pronto |
| T67 | GUI: a linha sustentadora do núcleo (Phillips e Snyder e Goates e Hunsaker, com taxas pelo `aerosim_aero_coeffs_llt`) como métodos da aba Aerodinâmica: `CoreLLTSolver` (`aerosim/aero/llt_solver.py`, `zig_llt` e `zig_llt_gh`) em `all_solvers`, ligados em "comparar: linha sustentadora do núcleo"; `tools/aero` usa a mesma classe | [ext] | T64 | B3 | Feito (a revisar) |
| T68 | GUI: Aerodinâmica → "tabela de voo": montar a tabela de um método (lltdrek, ASB, AVL; `aerosim/aero/flight_table.py`), ver C_L, C_D, C_m em α e as derivadas (e quais vieram do núcleo), escolher a V e usar no voo (`aero_model = tabela`). O cache em disco das polares já evita montar de novo | [GUI] | T65 | B3 | Pronto |
| T69 | GUI: "comparar modelos aerodinâmicos" na Missão e na Decolagem: a mesma análise voada com cada modelo (`tools/aero/missao.py`): curvas sobrepostas, o resumo lado a lado, a tabela de erros ao longo do percurso contra a referência escolhida, o mapa de proximidade dos voos e o tempo de conta; voos em paralelo | [GUI] | T65 | B3 | Pronto |
| T70 | GUI: Cargas → "linha sustentadora (Goates e Hunsaker)" já está no registro (`llt_gh`): conferir na aba (rótulo, fonte) e avisar, no método de Phillips e Snyder, quando a superfície é enflechada ou há β (ele não converge com a malha ali; Goates e Hunsaker 2021, §II.A) | [GUI] | T64 | B4 | Pronto |
| T71 | GUI: a falha "hélice tocou o chão" (`ac.sim.prop_strike`, desligada por padrão desde a T56) como opção em Configuração → Integração, e a folga da pá (`hprop`) no gráfico de folgas da Missão | [GUI] | T56 | B2 | Pronto |
| T72 | GUI: coeficientes perto do chão (`aerosim_aero_coeffs_at`, com a altura) na aba Aerodinâmica: a polar a uma h/b escolhida, com o modifier de efeito solo do avião | [GUI] | — | B3 | Pronto |
| T74 | Dados: avisar quando uma sobrescrita da superfície diverge do perfil (o `conventional` impõe C_L0 = 0,3 na asa; o NACA 2412 dá ~0,17). Só o núcleo usa a sobrescrita, então os métodos de fora (lltdrek, ASB, AVL) ficam 0,12–0,15 abaixo no C_L (`tools/aero/decolagem.py --puro` mostra) | [ext] | — | B3 | Pronto |
| T58 | Cargas pelo AeroSandbox: o VLM do ASB como mais um método da aba Cargas, atrás da interface (`ILoadMethod` → `LoadResult`): distribuição por faixa, vista 3D e comparação lado a lado com a linha sustentadora do núcleo, no mesmo ponto de voo. Serve de referência independente para winglet, enflechamento e diedro | [ext] | — | B4 | Feito (a revisar) |
| T12 | Aba Cargas (distribuição + 3D; hélice do conjunto motopropulsor do avião; só com modelo pronto) | [GUI] | — | B4 | Feito |
| T33 | Aba de controle | [GUI] | — | B9 | Pronto |
| T35 | Importador de dados medidos → comparação com ensaio e voo real | [novo] | — | B9 | Pronto |
| T40 | V-n refinado com dados de voo (sensoriamento) | [ext] | T13, T35 | B9 | Bloqueado |
| T41 | Etapas desatualizadas: cada etapa guarda a assinatura do modelo; mudou antes, as seguintes ficam marcadas | [ext] | — | B9 | Pronto |
| T78 | Asas ligadas (tandem, biplano): grupo de asas no modelo, na Montagem (presa na ponta, cauda em H; x_CG/CMA e CA do conjunto) e na sprint (segunda asa) | [ext] | — | B3 | Feito (a revisar) |
| T79 | Motores livres: arranjo nariz + pares na asa + propulsora (`motor_counts`), com o par da asa fora do disco da hélice do nariz | [ext] | — | B2 | Feito (a revisar) |
| T85 | Ajuste da decolagem sem travar: sessões do núcleo emprestadas de um pool a cada decolagem | [ext] | — | B1+ | Feito (a revisar) |
| T84 | Profundor numa superfície à frente do CG (canard, asa dianteira do tandem): hoje age invertido com a mistura padrão. Proposta: derivar o sinal da posição em relação ao CG | [ext] | T78 | B3 | Pronto (proposta) |

### core

O núcleo físico em Zig (`core/`): dinâmica, aerodinâmica, cargas, estruturas, modifiers e a ABI. Serve o aerosim, o AeroDrive e o aeroopt.

| ID | Tarefa | Tipo | Depende de | Bloco | Estado |
|---|---|---|---|---|---|
| T54 | **Prioridade da aerodinâmica.** Flape de verdade (no Navion com flape a 20°, o núcleo precisa de α = 10° para o C_L do voo; o VLM, 4,7°): hoje o flape é só uma deflexão fixa somada à incidência (`tau · deflexão`), sem ΔC_l máx, sem ΔC_d, sem ΔC_m, sem comando na simulação. Por tipo (simples, ventral, fendido, Fowler), com método da literatura escolhido pelo usuário; comandável na decolagem e no pouso; entra na linha sustentadora (corda e α0 por faixa) e na esteira. Primeiro o plano com as fontes | [ext] | — | B3 | Pronto |
| T55 | Linha sustentadora (cargas): ferraduras com os nós no 1/4 de corda das bordas de cada faixa (Phillips e Snyder 2000; Hunsaker e Snyder), corrige superfície enflechada e winglet (carga crescendo para a ponta); depois a versão não linear com C_l(α) de cada perfil (Newton) | [ext] | — | B3 | Fazendo |
| T64 | Linha sustentadora de Goates e Hunsaker 2021 no núcleo (`Params.llt_joint`, `llt_blend`; desligada por padrão): junta das pernas, linha efetiva por ponto de controle e seção normal à linha. Converge em derrapagem e com enflechamento; C_Lα a 1,5 % e C_lβ a 3 % do MachUpX (teste em `tests/tools`, `zig build test`). Método novo na aba Cargas (`llt_gh`) e no `tools/aero` (`nucleo_gh`) | [ext] | T63 | B3 | Feito (a revisar) |
| T65 | Voar com outro modelo aerodinâmico. Fase A (feita): `tools/aero/decolagem.py` reavalia cada ponto da decolagem com todos os métodos; `aerosim_aero_coeffs_llt`. Fase B (feita, a revisar): `Params.aero_model` (`physics/aeromodel.zig`; 0 = faixas, padrão, bit a bit igual; o AeroDrive fica no de sempre), linha sustentadora (1) e tabela de qualquer método (2, `aerotable.zig`, `aerosim/aero/flight_table.py`), `ac.sim.aero_model`; `tools/aero/missao.py` voa a decolagem e a missão com cada modelo. Fase C: efeito solo por imagens na linha sustentadora e nas tabelas (Katz e Plotkin, a conferir). Velocidade (feita, a revisar): cache da geometria da linha sustentadora (`llt.prepare`, bit a bit igual; `llt_gh` 10,8× mais rápido na decolagem), voos em paralelo e cache das tabelas no `missao.py`; missão de 165 s em sequência: faixas 4 s, faixas refinadas 17 s, `llt` 261 s, `llt_gh` 258 s (antes, 10 min e 52 min), os 9 modelos 9 min 37 s (5 min 15 s em paralelo); correção: o lltdrek não ia para o cache em disco; ainda possível: perna semi-infinita fechada, uma perna por nó, SIMD | [ext] | T64 | B3 | Fazendo |
| T73 | Simulação: a malha da simulação (uma faixa por trecho entre seções) põe a força de uma asa trapezoidal no meio da semienvergadura: na asa enflechada de 25° de `tools/aero`, o ponto neutro fica 10 % da CMA atrás (com a malha refinada, 0,9 %), e a torção sai pela metade. Propor a correção (faixas por CMA ou refino mínimo) com a regressão nova; muda os números da simulação, então só com o ok do dono | [ext] | T63 | B3 | Pronto |
| T57 | Esteira desviada pelo escoamento e com perfil radial (Duivenvoorden et al. 2026; correção de Rethorst, Exalto et al. 2024; Goates 2018), validada contra Stuper (NACA TM 874) | [ext] | T55 | B3 | Bloqueado |
| T62 | Núcleo: efeito diedro (C_lβ −0,139 × AVL −0,079 × voo −0,070 no Navion) e C_Lq (4,8 × AVL 9,5 × voo 15,9). Achar a causa nas faixas do núcleo e corrigir com fonte | [ext] | T60 | B3 | Pronto |
| T61 | Contribuição da fuselagem (C_mα, C_nβ, C_Yβ) e interferência asa–fuselagem no efeito diedro por método da literatura escolhido pelo usuário (hoje o usuário digita os números ou fica zero). No Navion, sem ela (todos os métodos, inclusive o AVL): C_mα −1,2 a −1,9 × −0,77 do voo, C_Yβ ~−0,2 × −0,60. Primeiro o plano com as fontes | [novo] | T60 | B3 | Pronto |
| T10 | Reynolds no núcleo (tabela por Re) | [ext] | — | B3 | Pronto |
| T08 | Esteira: trimagem com esteira e tubo desviado (ligar já existe na GUI) | [ext] | — | B3 | Pronto |
| T56 | Hélice no chão: folga da ponta da pá a cada passo; folga < 0 encerra o voo ("hélice tocou o chão") com `ac.sim.prop_strike = True` (desligado por padrão: o exemplo `flying_wing` começa com a pá dentro do chão); folga mínima por norma só como preset do usuário | [ext] | — | B2 | Pronto |
| T05 | E&C: estabilidade dinâmica não linear (funções de Lyapunov e de energia, região de atração vista em mapa de calor; inclui sloshing e vento). Primeiro o plano com as fontes, depois o código | [novo] | — | B8 | Pronto (plano) |
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
| T76 | Modificador `interferencia.asas` (tandem, biplano): as faixas de uma asa sentem as ferraduras da outra asa do par (Biot–Savart); desligado por padrão | [ext] | T78 | B3 | Feito (a revisar) |
| T77 | Erros claros em vez de pane: `StateError` com texto (sem trem, inércia inválida, divergência; códigos −6 a −8 na ABI) e guardas de NaN e infinito no `fmath` (sincos, atan, exp, wrap) | [ext] | — | B1+ | Feito (a revisar) |
| T83 | VTOL, nesta ordem: quadplane, tilt-rotor, tailsitter. O regulamento da Micro 2026 permite decolar e pousar com sustentação vetorada (seções 9.4 e 9.5). Primeiro o plano com as fontes | [novo] | — | B3 | Pronto (plano) |

### aerodrive

O simulador de voo em tempo real (Zig + raylib) que pilota o avião projetado. Usa o núcleo com o modelo de faixas e tem o próprio modelo de massas (`aerodrive/src/sim/params.zig`).

| ID | Tarefa | Tipo | Depende de | Bloco | Estado |
|---|---|---|---|---|---|
| T80 | Abrir qualquer avião sem pane: campo faltando, avião sem trem, inércia inválida ou divergência viram mensagem na tela | [ext] | T77 | B1+ | Feito (a revisar) |
| T81 | Massa das superfícies simétricas em cada lado (meia massa no raio de giração da meia asa), igual ao `massprops` do aerosim; sem isso o Ixx de um tandem saía quase zero | [ext] | — | B1+ | Feito (a revisar) |
| T82 | Voar VTOL: transição e comandos de cada arranjo | [ext] | T83 | B3 | Bloqueado |

### aeroopt

O terceiro braço: otimizador genérico (MDO) que monta um problema a partir de peças trocáveis e avalia cada candidato no núcleo. Primeiro caso: SAE BRASIL AeroDesign 2026, classe Micro. Plano: Claude Doc "MDO genérico do AircraftSimulation: plano em camadas". Nada começa antes do ok do dono no plano.

| ID | Tarefa | Tipo | Depende de | Bloco | Estado |
|---|---|---|---|---|---|
| O01 | Pontuação da Micro 2026 com fonte: `aeroopt/pontuacao/sae_br_2026_micro.toml` com as eqs. 9.1 a 9.4 do Regulamento 2026 Rev03 e as regras de validade, traduzidos para um programa de pilha (`aeroopt/scoring.py`); as notas à mão ficam no teste da O03 | [novo] | — | B10 | Feito (a revisar) |
| O02 | Contratos (`aerosim/interfaces/optim.py`: `IProblem`, `IScoring`, `IEvaluator`, `ISolver`) e o arquivo `.opt.json`; o mini-MDO de hoje nesse formato dá o mesmo resultado, bit a bit; isolar uma variável ou um grupo (`isolate`) | [zero] | — | B10 | Feito (a revisar) |
| O03 | Núcleo: expressão de pontuação (`core/src/optim/expr.zig`) e álgebra linear de tamanho fixo (`core/src/math/linalg.zig`, LU e Cholesky), na ABI (`aerosim_expr_check`, `aerosim_expr_eval`); notas da Micro 2026 à mão no teste | [novo] | O01, O02 | B10 | Feito (a revisar) |
| O04 | Ferramenta `tools/aeroopt.py problema.opt.json`: melhor ponto, restrições, convergência (`--png`), `--isolar`; a nota fator por fator entra quando o avaliador calcular as entradas da pontuação (O06) | [novo] | O03 | B10 | Feito (a revisar) |
| O05 | GUI do aeroopt (`python -m aeroopt`, `aeroopt/gui.py`): o `.toml` da pontuação inteiro em campos editáveis, variáveis e categorias, rodada ao vivo (atualiza a cada candidato que termina uma etapa, como a página MDO; não precisa ser instantâneo), mapa dos aviões (PV × CP com EE constante, cor pela nota), tabela, 3D e nota fator por fator do avião clicado, gravar o avião num projeto, abrir o avião no aerosim (todas as análises), restrições editáveis, CSV de cada rodada (`aeroopt/export.py`), projeto vazio roda. Submenus por botão: variáveis com limites, restrições (sem as grandezas que são variáveis), perfis por região com `.dat` acrescentado, motores, hélices e baterias por marcação. Esquerda toda em submenus (pontuação, variáveis, restrições, configuração com os aviões e o método de cada etapa; geometria nas restrições), cada opção com "(?)", gravada no `.opt.json`. Variáveis: todo campo das etapas do aerosim (`aeroopt/inputs.py`), listas marcadas no mesmo submenu. Falta: gerações de aviões (algoritmo genético, ver O14), pausar e continuar, mandar para o AeroDrive | [GUI] | O04, O13 | B10 | Feito (a revisar) |
| O06 | Variáveis abertas (qualquer campo do `Aircraft`) e as duas cargas da Micro (líquido e LAPES, duas posições de CG) | [ext] | O04 | B10 | Pronto |
| O07 | Orquestração (pool de vagas fixas no núcleo, cascata, ilhas, pipeline, filtro por fidelidade) e reparo antes de avaliar | [novo] | O06, T28 | B10 | Bloqueado |
| O08 | Caixa, montagem e desmontagem (era a T34): o encaixe das peças como sub-problema | [novo] | O07 | B10 | Bloqueado |
| O09 | Efeitos desligados por padrão e reavaliação final do melhor ponto com todos ligados | [ext] | O07 | B10 | Bloqueado |
| O10 | Solvers locais (Gould e Leyffer) e Lagrangiano aumentado no lugar da penalidade fixa | [novo] | O03 | B10 | Bloqueado |
| O11 | SIMD e GPU, só depois de medir | [ext] | O07, T47 | B10 | Bloqueado |
| O12 | Substituto aprendido a partir do histórico de avaliações | [novo] | O07 | B10 | Bloqueado |
| O13 | Processo em etapas (o caminho principal no lugar do mini-MDO): configurações → superfícies pela decolagem (`power.design_point` com busca por coordenadas) → MTOW no 6GDL → nota no núcleo; barreira entre etapas e paralelo dentro (`aeroopt/pipeline.py`, `aeroopt/stages.py`, `--etapas` na ferramenta); categorias de configuração (monoplano, biplano, tandem, asa voadora; os nomes antigos asa alta, média, baixa, parasol e cauda em V continuam valendo); a cauda é escolhida na etapa voa (E&C) entre convencional, em H, em V e sem cauda como eixo das configurações (`aeroopt/categories.py`). A corrida da decolagem do `power.performance` foi para o núcleo (`core/src/sizing/ground.zig`), bit a bit igual | [novo] | O04 | B10 | Feito (a revisar) |
| O14 | Do MDO antigo da equipe (MDO-2024-REGULAR). Feito: gerações por algoritmo genético no núcleo (`core/src/optim/ga.zig`: elite, seleção por posição, cruzamento num ponto, mutação; `aeroopt/generations.py`, na janela e em `--populacao/--geracoes`), no lugar de varrer as combinações; toque da cauda na rotação (G1). CMA-ES no núcleo (`core/src/optim/cmaes.zig`, Hansen 2016) como método das superfícies e da etapa voa, conferido contra a `pycma`. Paralelismo como módulo (`aerosim/parallel`, `IExecutor`): processos que duram a rodada inteira; tração motor + hélice da sprint no núcleo (`core/src/sizing/motorprop.zig`), bit a bit igual. Sensibilidade do melhor (`aeroopt/sensitivity.py`: só o melhor e as contínuas livres dele, dentro do problema; modelo local no núcleo, `core/src/optim/localfit.zig`, sobre o histórico da busca, sem pontos novos quando ele basta; também um por vez e Morris, `core/src/optim/sensmethods.zig`, com a perda por tolerância e ∂nota/∂limite do problema; menu Configuração → sensibilidade, aba Sensibilidade nos gráficos do melhor, `--sensibilidade` na ferramenta). Falta: regra 80/20 do trem, variáveis por razão para as partições da asa, inércia da fuselagem como caixa, arrasto das fixações do biplano | [novo] | O13 | B10 | Em andamento |
| O15 | Topologias realistas (plano em https://claude.ai/artifact/CGbqUwPUpo4Y5BjrpjbVQW). G1 feito: geometria no núcleo (`core/src/geometry`: hélice × peças, massas fora, pedaços soltos, chão parado e na rotação), tradutor `aerosim/backend/zig/geometry.py`, etapa "geometria" do aeroopt e checagem em cada ponto de projeto; a geometria conserta o chão descendo o trem (`gear_raise`, `power_draft.gear_h`). Falta: G2 gramática e fuzzing de topologias, G3 peças novas no montador (EV entre asas, elevon, motores fora da asa, fuselagem entre asas, conectores entre asas com massa, 3+ asas, massa própria de cada asa), G4 lote no CPU, G5 GPU | [novo] | O13 | B10 | Em andamento |
| O16 | Suspeita: o C_mδ do elevon da asa voadora na sprint (`aerosim/design/tail.py`) é uns 4 a 5 vezes o do núcleo (−1,52 contra −0,34 /rad no avião da busca), e por isso a etapa voa dizia que ela roda e o 6GDL bate. A E&C com os comandos já usa o núcleo (`aeroopt.stages.core_rotation`). Conferir a conta da sprint contra a literatura (braço do elevon tratado como de cauda?) e corrigir como método novo, sem mudar os resultados de hoje. Ferramenta: `tools/rotacao.py "asa voadora"`. Feito: a sustentação do elevon no quarto de corda mais o momento próprio do flape (perfil fino), na sprint e no núcleo (modificador `comando.momento_flape`, desligado por padrão) | [ext] | O13 | B10 | Feito (a revisar) |
| O17 | Suspeita: no núcleo, o C_m da asa voadora não cresce com o curso do elevon além de 20° (cai de 0,059 a −20° para 0,021 a −27,5° e volta a subir até −40°). Achar a causa (fator de eficácia do flape pelo curso, estol da faixa ou C_L limitado) com a fonte de cada um. Ferramenta: `tools/rotacao.py "asa voadora" --png x.png` (o gráfico de C_m(δ)) | [ext] | — | B1 | Pronto (próximo) |
| O18 | Suspeita: o C_m,ac da asa voadora na sprint não tem o termo da torção com enflechamento (Nickel e Wohlfahrt, a conferir no PDF); torção e enflechamento não mudam a rotação. Comparar com o núcleo antes de acrescentar | [ext] | O16 | B10 | Pronto (próximo) |
| O19 | Tandem: a sprint analisa o tandem como asa voadora (a asa de trás é ignorada na estática e o resultado sai igual ao da asa voadora). A asa de trás tem de entrar como a cauda: profundor na asa 2, decalagem (`tail.wing2_di`) e distância (`tail.wing2_dx`) como comandos da E&C; testar se precisa de EV (aletas nas pontas da asa de trás) ou se o elevon basta; um projeto de exemplo de tandem | [ext] | O13 | B10 | Pronto (próximo) |
| O20 | Asa voadora na pista: a tração puxa o nariz para baixo (−2,3 N·m na saída do chão, a hélice tratora 0,22 m acima das rodas para livrar o chão) e o elevon dá só +0,5 N·m. Testar hélice propulsora, trem que já deixa a asa no ângulo de sair do chão (sem rotação) e winglet ou end-plate como EV nas pontas, cada um como opção desligada por padrão; usar `data/aircraft/Asa_voadora.json` de referência (sem editar). Ferramenta: `tools/rotacao.py` com `--varre`. Feito: atitude no chão (sprint, corrida do núcleo, 6GDL), hélice propulsora, perfil simétrico na ponta e C_L trimado na E&C; a asa voadora passa da voa, das superfícies e da pista. Falta: o 6GDL (O22) e o winglet | [ext] | O16 | B10 | Em andamento |
| O21 | Suspeita: na asa enflechada, a margem estática da sprint não bate com a do núcleo (12 % na sprint dá 18,8 % no núcleo com 30° de enflechamento e −6° de torção). O ponto neutro da sprint vem só do CA da planta. Comparar com o núcleo e com a literatura antes de corrigir. No tandem (ponto neutro das duas asas, downwash 2 C_Lα/(π AR) nas duas contas) o do núcleo fica uns 14 % da CMA atrás do da sprint. Ferramenta: `tools/rotacao.py` com `--varre wing.sweep=0:35:8`; o tandem, `tests/design/test_design.py::test_tandem_neutral_point...` | [ext] | O16 | B10 | Pronto (próximo) |
| O22 | Decolagem 6GDL da asa voadora: o piloto da decolagem segura o comando fixo até 2 m (z_warning + 1). A asa voadora leve e com muita tração sobe a 58° e estola. Testar um limite de α nesse trecho, ligado só por opção, para não mudar as decolagens de hoje | [ext] | O20 | B10 | Pronto (próximo) |
| O23 | Regular 2026: a penalidade de potência (P_P = 0,5 ΔP acima de 600 W, NC[7.2.0.1]) pede a potência elétrica de pico em voo, que o avaliador ainda não entrega. Os expoentes da eq. 7.5 (1,15^(−b)) e o B ≤ 4,0 m da eq. 7.1 vieram do texto extraído do PDF e estão a conferir | [ext] | O01 | B10 | Pronto (próximo) |
| O24 | Missão completa só no melhor: o aeroopt para na decolagem (a nota sai do MTOW do 6GDL que passa o obstáculo). Rodar a missão inteira (subida, volta, soltura, pouso) é caro, então é uma etapa final, fora da busca, só no melhor de cada geração, que já se sabe que decola (quem não decola não vale tentar): ela diz se o avião cumpre o voo e não entra na nota de cada candidato | [ext] | O20 | B10 | Pronto (próximo) |
| O25 | Busca local na E&C. Feito: hipercubo latino maximin no núcleo (`core/src/optim/sampling.zig`, `aerosim_lhs`), `init="lhs"` nas gerações e na evolução diferencial (`etapas.inicio`), multi-start (`etapas.partidas = k`: `Starts` junta k pontos que voam afastados de `START_DIST`, fica o de maior carga paga na pista, `item.data["partidas"]`), semente somada (`FlightCheck(seed=)`) e `tools/sementes.py` (mesma configuração, sementes × inícios × partidas, dispersão e PNG). Tudo desligado por padrão. Falta: rodar `tools/sementes.py` no tandem e na asa voadora da Regular 2026 e decidir se `lhs` e partidas viram padrão; o CMA-ES parte de uma média só (o equivalente seria o reinício IPOP, Auger e Hansen, CEC 2005); a busca das superfícies (`_generations`) ainda usa o sorteio uniforme. Ideias da pesquisa, para depois: Sobol/Halton no lugar do latino, otimização bayesiana com restrições (GP, para orçamento pequeno; ONERA SEGOMOE, Priem et al.), agrupamento multi-start (MLSL, Rinnooy Kan e Timmer, 1987) | [ext] | O20 | B10 | Em andamento |
| O26 | Tandem com deriva na ponta nunca voava na E&C: a estática da sprint tomava `surfaces[-1]` como asa de trás, e as derivas entram depois dela; o ponto neutro ia para a asa da frente, o comando não trimava e pedia perto de 1 kg de lastro. Agora `tail.second_wing` acha a asa de trás pelo papel; teste `test_tip_fins_do_not_move_the_tandem_neutral_point`. Com isso o tandem da Regular 2026 voa já no x0, e todas as sementes dão o mesmo avião (a busca nem roda) | [fix] | O25 | B10 | Feito |
| O27 | Onde fica a carga paga (vitor, 2026-10-26): é variável do otimizador, não regra da sprint. `power.x_payload` (m, do CG de projeto; 0 = no CG, a montagem de sempre) entra na busca dos comandos da E&C em todo tipo de avião; com a carga fora do CG a bateria equilibra junto, e se não alcança continua sendo lastro (a E&C rejeita). A margem sem a carga (`sm_empty`) entra na E&C e na viabilidade. Testes `test_payload_position_is_a_variable_and_zero_keeps_the_old_assembly` e `test_payload_position_is_searched_by_the_flight_check_for_every_kind` | [ext] | O26 | B10 | Feito |
| O28 | Tandem caía logo depois de decolar no 6GDL: a sprint dava C_nβ = +0,019 /rad só com as derivas da ponta, e o núcleo, com o pod e a asa, −0,008 (dutch roll nível 4). No ar ele guinava até β = 60° e caía. Agora a E&C com os comandos liga sempre a estabilidade dinâmica (`StabilityParams`: os modos do núcleo, arfagem e látero-direcional, contra a MIL-F-8785C), e a deriva da ponta pode ir até 0,5 m; com 0,3 m e corda inteira o tandem passa e voa estável. Teste `test_flight_check_with_controls_turns_on_the_dynamic_stability`. Falta: o período curto na lista da MIL e o C_nβ da sprint sem o pod | [fix] | O26 | B10 | Feito |
| O29 | Busca do ponto de acionamento na decolagem por bisseção (vitor, 2026-10-26): primeiro a corrida sem acionar (onde sai do chão sozinho limita o acionamento), depois bisseção em s até 0,25 m, para antes se passa do fim da pista, para depois se sai e afunda. Opção `busca` (grade, o de sempre; bisseção) na decolagem e no MTOW; o 6GDL do aeroopt usa a bisseção. Teste `test_bisection_finds_the_actuation_window_like_the_grid`. Ideia do vitor ainda não feita: usar a distância da corrida sem acionar para estimar a massa (menos distância, mais peso) e encurtar a bisseção na massa | [ext] | O20 | B10 | Em andamento |
| O30 | Busca da E&C guiada pela falha (vitor, 2026-10-26: "um módulo de diagnóstico de falha que direcione a mutação"). Núcleo `core/src/optim/guided.zig` (reparo por gradiente, Chootinan e Chen 2006; ε-restrito, Takahama e Sakai 2006; bandido D-MAB com Page–Hinkley, Da Costa et al. 2008; espaço normativo cultural, Reynolds 1994; regra do LEM, Michalski 2000), 10 exports. `violation_terms` dá um código por termo, `aeroopt/diagnosis.py` (`IFailureDiagnosis`) liga cada código às variáveis do remédio, `aeroopt/guided.py` roda a DE com cinco operadores (DE, remédio, reparo, cultural, LEM). Métodos novos da etapa voa: reparo, εde, cultural, lem, diagnóstico (o bandido escolhe). `tools/metodos_voa.py` compara todos. Regular 2026 sem água, 3 sementes, 48 pontos por busca: na asa voadora o reparo e o εDE voam nas 3 com 15 pontos, as gerações em 2 de 3 (32), o diagnóstico em 2 de 3 (25), a DE em nenhuma; no tandem todos voam quase sempre, entre 70 e 90 pontos (somadas as três arfagens). O reparo vai no ponto que viola menos: no pior (lastro de 100 kg) o passo linear não chegava. Falta: estol por superfície (a razão C_L/C_L,max de cada uma, do núcleo) como termo da E&C; `wing.dihedral` nos comandos (o remédio do C_lβ e da espiral); decidir o padrão depois da comparação no tandem e na asa voadora da Regular 2026; README completo e diagramas TikZ | [ext] | O25, O28 | B10 | Em andamento |
| T59 | Otimização de perfis (futuro): forma do perfil por parâmetros (ex.: CST/Kulfan) com o polar do NeuralFoil (AeroSandbox, já instalado) ou do XFOIL (o motor do XFLR5), objetivo e restrições escolhidos pelo usuário (C_l máx, C_d no cruzeiro, C_m, espessura), atrás da interface de perfis; o perfil otimizado entra na biblioteca. Primeiro o plano com as fontes | [novo] | — | B3 | Pronto |

### comum

Ferramentas, checks, documentação e git, que valem para os quatro segmentos.

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
| T75 | Documentação: README de cada pasta do `core` e do `aerosim` com as equações em LaTeX (um parágrafo por equação, com a fonte ou "a conferir no PDF"), como funciona e um exemplo em Python por arquivo, rodado; sem números de máquina ou de um caso só. Núcleo: enums no lugar dos números e bits (`core/src/opt.zig` para o `-Dopt`; `Ground`, `Kind` e `SlipstreamParam` em `core/src/modifiers/types.zig`), com a ABI igual | [ext] | — | B3 | Feito (a revisar) |

**Caminho crítico:** T38 → T13 → T15 → T21 → T24 → T25/T26 → T32. Estruturas e aeroelasticidade esperam por ele.

---

## Itens por área (aerosim)

Cobertura do que o aerosim calcula e mostra. O núcleo, o AeroDrive e o aeroopt entram aqui pelo que aparece na GUI.

Legenda das colunas **Código** e **GUI**:
- ✅ coberto (na GUI: roda e mostra);
- 🟡 parcial;
- ❌ não existe;
- ❓ a conferir.

### 1. Aerodinâmica

| ID | Tópico | Código | GUI | Tarefa | Onde / observação |
|---|---|---|---|---|---|
| AE-01 | Biblioteca de perfis, polares 2D por Reynolds, cache | ✅ | ✅ | — | `aero/sections.py`, `data/airfoils` |
| AE-02 | Asa finita: LLT, AVL, ASB, importar XFLR5 | ✅ | ✅ | T55, T67 | comparação de métodos; a linha sustentadora de Phillips e Snyder não converge em superfície enflechada nem em β, a de Goates e Hunsaker sim (T64); as duas na aba (T67) |
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
| AE-19 | Modelo aerodinâmico do voo selecionável (faixas, linha sustentadora, tabela) | ✅ | ❌ | T66 | `core/src/physics/aeromodel.zig`, `ac.sim.aero_model`; o padrão (faixas) e o AeroDrive não mudam |
| AE-20 | Linha sustentadora de Goates e Hunsaker (derrapagem, enflechamento) | ✅ | 🟡 | T67, T70 | `core/src/loads/llt.zig`; na aba Cargas (`llt_gh`) e na Aerodinâmica (`zig_llt_gh`, T67); falta o aviso da T70 |
| AE-21 | Tabela de voo de qualquer método (lltdrek, ASB, AVL) | ✅ | ❌ | T68 | `aerosim/aero/flight_table.py`, `core/src/physics/aerotable.zig` |
| AE-22 | Comparar modelos aerodinâmicos voando a missão | ✅ | ❌ | T69 | `tools/aero/missao.py` (erros ao longo do percurso, mapa de proximidade, tempo de conta, voos em paralelo com `--jobs`, cache das tabelas); mapas e tempos em `tools/README.md` |

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
| EC-17 | Posição e ângulo do tanque de líquido × modos | ❌ | ❌ | T86 | distância ao CG, embaixo da asa, inclinação |

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
| IN-01 | MDO (PSO, pontuação) | ✅ | ✅ | O02, O05 | página MDO; vira um problema do aeroopt |
| IN-02 | Projeto do zero em etapas (sprint em pasta) | ✅ | ✅ | — | `aerosim/design` |
| IN-03 | Montagem sem exigir decolagem | ✅ | ✅ | — | |
| IN-04 | Tração e Missão dentro de Desempenho | ✅ | ✅ | — | |
| IN-05 | xCG em % CMA | ✅ | ✅ | — | |
| IN-06 | Checklist do avião | ✅ | ✅ | — | |
| IN-08 | Volume e arranjo da caixa | ❌ | ❌ | O08 | sub-problema do aeroopt |
| IN-09 | Tempo de montagem e desmontagem | ❌ | ❌ | O08 | |
| IN-11 | Etapas desatualizadas (assinatura do modelo) | ❌ | ❌ | T41 | |
| IN-12 | Restrições, normas e métodos só por preset do usuário | ❌ | ❌ | T37 | |
| IN-13 | Asas ligadas (tandem, biplano) | ✅ | ✅ | T78, T76 | Montagem e sprint; interferência no modifier `interferencia.asas` |
| IN-14 | Motores livres (nariz + asa + propulsora) | ✅ | ✅ | T79 | Desempenho → Tração |

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
- CO-05: a pesquisa sobre helicóptero (o VTOL saiu das Torres: T83).

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

**Onde foi medido:** na `main` (`v0.2.2`), com os ❓ do T01 já conferidos no código. Na `0.2_dev` entraram os itens AE-19 a AE-22 (código feito, GUI não), que só aumentam o total.

| Seção | ✅ na GUI / itens |
|---|---|
| 1. Aerodinâmica | 6 / 19 |
| 2. Desempenho | 8 / 14 |
| 3. Estabilidade e Controle | 12 / 16 |
| 4. Cargas | 3 / 11 |
| 5. Aeroelasticidade | 0 / 4 |
| 6. Estruturas | 1 / 5 |
| 8. Integração | 8 / 12 |
| 9. Controle | 1 / 2 |
| **Total** | **39 / 83 (47 %)** |

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
  Desde então, direto na `0.2_dev` por pedido do dono: T75, T76 a T81, T85 e este tracking por segmento.
- As branches antigas foram apagadas aqui; no GitHub, o dono apaga (a sessão não tem permissão).

# Tracking do projeto

Lista única do que o projeto cobre e do que falta, separada pelos segmentos do repositório: **aerosim** (o programa de
projeto), **core** (o núcleo em Zig), **aerodrive** (o simulador de voo) e **aeroopt** (o otimizador). É um juízo de
valor, não uma análise: nada aqui foi calculado. Os relatórios de projeto de referência **não estão no git** e servem
só como lista do que um projeto cobre, nunca como fonte de números (em estruturas, eles têm valores inconsistentes).

**Regras para toda tarefa:**
- **Restrição, norma e método nunca são padrão.** Regulamento, norma (FAR, CS-VLA, MIL-F-8785C) e método da literatura
  só valem quando o usuário escolhe e preenche. Sem isso, a análise calcula e mostra, mas não aprova nem reprova.
- **Conta no núcleo**, em Zig, em `core/`.
- **Cargas é análise tardia:** só roda com um modelo pronto. Sem ele, a aba diz o que falta.

**Fluxo de projeto que o programa segue** (iterativo: qualquer etapa pode mandar voltar):
perfis → asas → E&C → superfícies móveis → conjuntos → Desempenho → decolagem e MTOW → envelopes → Cargas → Estruturas.

Como usar: olhe a aba **Próximos** da página do tracking, pegue no máximo 2 tarefas e, ao fechar uma, atualize os itens
que ela mexe e o progresso.

---

## Ordem de prioridade (2026-11-21)

1. **Suspeitas de erro primeiro:** o "Profundor de equilíbrio" de Empenagem e comandos numa asa sem cauda sai com δe na
   casa de −10¹⁰ ° (print do vitor, 2026-11-20: achar a divisão por quase zero; sem EH a curva não devia sair, ou usa o
   elevon); depois G31, G34, G35, T90 e T96.
2. **Planilhas da equipe:** G45, G46 e G47.
3. **Terminar o que está em andamento:** G28, G20, G30, G36, G06, G08, T55, T66 e O41.
4. **Desempenho:** T43 a T46 (a subida simulada está errada), depois T37.
5. **Aerodinâmica:** a T54 (flape) primeiro; depois T10, T11, T08, T61, T62, T66, T73 e T74.
6. **Cargas e estruturas:** T16 a T18, T20 a T22, T24, T27 e T39.
7. **Navegador:** G25, G09 e a sala P2P do aeroopt (O42 a O47); o PWA da W4. Três pendências soltas:
   - o Zig 0.16.0 não compila `std.Io.Threaded` para o emscripten; o AeroDrive contorna com
     `aerodrive/src/sys/browser_io.zig`. Conferir se o 0.16.1 ou o 0.17 corrige e, se corrigir, tirar o contorno;
   - o Decolar ainda leva ~0,5 s no navegador (`peakCL`; o `-Dopt=peak` resolve, mas muda os números: decisão do dono);
   - em Voos gravados, "Ver os dados" e "Apagar a gravação" só respondem ao mouse (as setas, o Enter e o controle não
     chegam aos botões).

## O castelo (mapa)

```
        [Torres]   fora da lista: CFD 3D, controle não linear, CAD, hardware-in-the-loop  
   ┌──────────────────────────────────────────────────────┐
 3 │ Andar 3: Estruturas · Aeroelasticidade                 │ ← o núcleo já tem peças; falta a aba
 2 │ Andar 2: Cargas (casos, esforços, dobradiça, solo)     │ ← apoia-se no Andar 1
 1 │ Andar 1: Aero · Desempenho · E&C · Integração          │ ← já está de pé
   ├──────────────────────────────────────────────────────┤
 0 │ Fundação: núcleo Zig, ABI, modelo universal, testes    │
   └──────────────────────────────────────────────────────┘
              [Portão] = GUI: só conta quando passa por ele
```

Uma tarefa nunca depende de um andar acima do dela.

---

## Versões

- A `main` está em `v0.3.0` (PR de 2026-11-19; antes, `v0.2.4` em 2026-10-30).
- A `0.3_dev` fechou a `0.3.1` em 2026-11-20 (ainda sem PR para a `main`); o que vier agora entra na **`0.3.2`**.
- Cada tarefa mesclada sobe só o último número (`0.3.1`, `0.3.2`…). A lista inteira feita vira `0.4.0`. A `1.0` tem
  meta própria (abaixo), sem data: nada vira release sem o dono testar cada componente.
- **Uma branch de desenvolvimento só: `0.3_dev`.** Nada direto na `main`, que só recebe por PR. Ao fechar uma tarefa: a
  `main` é mesclada na `0.3_dev`, rodam os checks (`python -m ziglang build check -- --tudo`) e o PR `0.3_dev` → `main`
  espera o review. Cada PR atualiza este arquivo e o `CHANGELOG.md`.
- Tag `vX.Y.Z` só na `main`, depois do merge e com o ok do dono.

## Meta da 1.0: tudo no navegador, sem instalar nada

Abrir um endereço no navegador, do PC ou do celular, e ter o projeto inteiro ali: uma tela de seleção (com cara de
BIOS) invoca o **aerosim** (projetar e analisar), o **aeroopt** (otimizar) e o **AeroDrive** (voar). As três leem e
gravam o mesmo avião, que fica guardado no navegador e sai pela pasta de downloads. Toda conta roda no aparelho, em
WebAssembly, e o mesmo código sai como executável para o PC. Os métodos de bibliotecas Python (lltdrek, ASB, AVL) ou
vão para o núcleo, ou ficam de fora da web com um aviso; na **1.1**, entram estáticos no WebAssembly (Pyodide, AVL em
wasm).

| Etapa | O que | Depende de |
|---|---|---|
| **W1** | AeroDrive na web (emscripten, toque). **Feito** | — |
| **W2** | Abrir e salvar o avião no navegador. **Feito** | W1 |
| **W3** | Tela de seleção que invoca as aplicações e passa o avião entre elas. **Feito** | W1 |
| **W4** | Publicar no GitHub Pages (feito); falta o PWA (instalar no celular e usar sem internet) | W3 |
| **W5** | As contas do aerosim no núcleo. **Feito** (G28) | — |
| **W6** | Métodos de fora: portar um VLM para o núcleo ou deixá-los opcionais (decisão do dono, G28) | W5 |
| **W7** | Telas em Zig (raylib + raygui). aerosim **feito**; falta o aeroopt (O41) | W5 |
| **W8** | Paralelismo na web (G25) | W7 |
| **W9** | As três aplicações na página e no executável único; o dono testa cada componente → `1.0` | W2, W4, W6, W7, W8 |
| **W10** | **1.1:** bibliotecas Python estáticas no WebAssembly | W9 |

## Níveis

Cada tarefa diz em que camada do projeto ela mexe. Uma de Fundação mexe em tudo; uma de Interface, só na tela.

| Nível | O que é |
|---|---|
| **Fundação** | Arquitetura e o que todo o resto usa: contratos entre as camadas, ABI, modelo universal, estrutura de pastas |
| **Cálculo** | Física ou método novo ou corrigido no núcleo (um modelo, um solver, uma correção de fórmula) |
| **Análise** | Uma análise ou aba que junta cálculos que já existem e mostra o resultado (gráficos, verificações) |
| **Interface** | Tela, menus, visual, navegador: nada muda nas contas |
| **Ferramenta** | Testes, checks, perfil, documentação, CI e git |

**Fora desta lista (menor prioridade):** controle não linear; CFD 3D (inclui a perda de tração por corpos atrás da
hélice); CAD (exportar STEP); hardware-in-the-loop no
AeroDrive; dividir o aerosim em programas separados; aeroelasticidade dinâmica; otimização estrutural e FEM; FMEA.

---

## Quadro

Uma tarefa tem três estados: **Não iniciado**, **Em andamento** e **Terminado**. Ela só começa quando as tarefas de que depende estão terminadas (a aba Próximos da página mostra essa ordem). Máximo de 2 em andamento. A **Prioridade** é alta, média ou baixa (— quando ainda não foi dada).

O quadro tem uma tabela por segmento; o segmento é onde fica o grosso do trabalho da tarefa (uma conta nova no núcleo
com uma aba que a mostra fica no **core**, e a aba vira outra tarefa no **aerosim**). As dependências cruzam os
segmentos. As tarefas do aeroopt usam o prefixo **O**, e as da GUI, o **G**. Cada tarefa diz em uma ou duas frases o
que falta; o que já foi feito está no `CHANGELOG.md` e no commit.

A página `tracking.html` do site sai destas tabelas (`zig build tracking`; o build do site roda sozinho): para acrescentar uma tarefa, basta uma linha nova na tabela do segmento. Uma tarefa resolvida fica `Terminado (commit abc1234)` (à mão ou com `zig build tracking -- --feito G26 abc1234`): a página risca o título, liga o commit no GitHub e a tira da aba Próximos, que mostra as abertas em ondas, na ordem em que dá para fazê-las. Na página, "Confirmar terminado" (em cada tarefa) e "+ Nova tarefa" abrem uma issue já preenchida, e a Action `tracking.yml` grava a mudança aqui na `0.3_dev` sozinha.

### aerosim

O programa de projeto: abas, etapas do projeto, análises e validação.

| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
|---|---|---|---|---|---|
| T86 | E&C: varrer a posição e o ângulo do tanque de líquido (distância ao CG, embaixo da asa) e mostrar os polos, as qualidades de voo e o passeio do CG de cada caso. Primeiro o plano com as fontes | Análise | G06 | — | Não iniciado |
| T04 | E&C: ME × xCG e passeio do CG | Análise | — | — | Terminado |
| T06 | Curvas com fator de carga na Missão | Análise | — | — | Terminado (na `main`) |
| T42 | Desempenho: subaba "Voo nivelado e envelopes" | Interface | — | — | Terminado |
| T43 | Desempenho → Decolagem: caixa "MTOW para o comprimento de pista", varrendo a massa total ou por componente (cada um ligável, com mín., máx., inicial e passo) | Análise | — | — | Não iniciado |
| T44 | Corrigir a subida simulada (o γ obtido não segue o pedido) e mostrá-la junto da analítica | Análise | — | — | Não iniciado |
| T45 | Desempenho → Curva: uma subaba só, analítica e simulada (hoje está na Missão "curvas") | Análise | — | — | Não iniciado |
| T46 | Desempenho: descida, planeio e pouso, analíticos e simulados | Análise | — | — | Não iniciado |
| T37 | Restrições e normas só como preset do usuário: tirar os limites padrão (MIL-F-8785C, FAR 23.233, RC > 0,5 m/s, φ 75°…); sem preset, a análise só mostra | Análise | — | — | Não iniciado |
| T09 | Distribuição ao longo da envergadura a um α na aba Aerodinâmica (Analisar → "Carga na envergadura", com o "α da carga") | Interface | — | — | Terminado |
| T11 | Arrasto por componente na aba Aerodinâmica (o núcleo já separa asa, EH, EV e fuselagem para o Exportar) | Análise | — | — | Não iniciado |
| T60 | Validação contra o Ryan Navion (NASA TN D-6643) | Análise | — | — | Terminado (na `main`) |
| T63 | Casos de teste dos coeficientes entre os métodos | Análise | — | — | Terminado (na `main`) |
| T66 | Modelo aerodinâmico do voo na tela. Feito: o campo "modelo aerodinâmico" (faixas, linha sustentadora, tabela) nos Métodos de toda análise que voa e o aviso de asa curta. Falta: mostrar o custo esperado e refinar a malha sozinho na linha sustentadora | Interface | — | — | Em andamento |
| T68 | Aerodinâmica → "tabela de voo": montar a tabela de um método de fora (lltdrek, ASB, AVL), ver C_L, C_D, C_m e as derivadas e usá-la no voo | Interface | T66 | — | Não iniciado |
| T67 | Linha sustentadora do núcleo como método da aba Aerodinâmica | Análise | T64 | — | Terminado (na `main`) |
| T69 | Comparar modelos aerodinâmicos voando a mesma Missão ou Decolagem: curvas sobrepostas e o erro contra a referência | Interface | T66 | — | Não iniciado |
| T70 | Avisar quando a linha sustentadora de Phillips e Snyder roda numa superfície enflechada ou com β (ela não converge ali; Goates e Hunsaker 2021, §II.A). Hoje só o nome do método no avião completo diz isso; falta o aviso por cima da janela | Interface | — | — | Não iniciado |
| T71 | "Hélice tocou o chão" como opção na tela (hoje nada liga o `prop_strike` do núcleo). A folga da pá já está no gráfico de folgas da Missão | Interface | T56 | — | Não iniciado |
| T72 | Efeito do chão na aba Aerodinâmica: C_L, induzido e C_m × h/b, pelo McCormick ou pelo VLM com imagem (Analisar → "Efeito do chão") | Interface | — | — | Terminado |
| T74 | Avisar quando o C_L0 sobrescrito numa superfície diverge do perfil (o `conventional` impõe 0,3; o NACA 2412 dá ~0,17) | Análise | — | — | Não iniciado |
| T58 | VLM do AeroSandbox como método da aba Cargas | Análise | — | — | Terminado (na `main`) |
| T12 | Aba Cargas (distribuição e 3D) | Interface | — | — | Terminado |
| T33 | Aba de controle (piloto automático) | Interface | — | — | Não iniciado |
| T35 | Importar dados medidos (ensaio, voo) e comparar com a simulação | Análise | — | — | Não iniciado |
| T40 | V-n refinado com dados de voo | Análise | T35 | — | Não iniciado |
| T41 | Etapas desatualizadas: cada etapa guarda a assinatura do modelo e, se algo antes dela mudou, fica marcada | Análise | — | — | Não iniciado |
| T78 | Asas ligadas (tandem, biplano) no modelo, na Montagem e nas etapas | Análise | — | — | Terminado (na `main`) |
| T79 | Motores livres: nariz, pares na asa e propulsora | Análise | — | — | Terminado (na `main`) |
| T85 | Ajuste da decolagem sem travar (pool de sessões do núcleo) | Análise | — | — | Terminado (na `main`) |

### GUI

A tela do aerosim. Regra (vitor, 2026-10-30): a GUI é genérica. Nenhum formulário compartilhado tem campo de uma configuração só (tandem, biplano, asa voadora); o que muda de uma configuração para outra ganha uma lista ou um menu por item.

| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
|---|---|---|---|---|---|
| G01 | GUI genérica: tirar o que ainda é de uma configuração só: o campo "deriva na ponta" da Empenagem (vira dispositivo da G03), a regra do tandem em `design/stage_tail.zig` (duas asas sem cauda → profundor na asa 2) e a estática da etapa feita só com a asa 1 e a cauda (G05) | Interface | — | — | Não iniciado |
| G02 | Configurações guardadas em Projetar (a tabela "Asas do avião" com nome), usadas pela Empenagem | Interface | — | — | Terminado |
| G03 | Dispositivos de ponta com menu próprio em Projetar. Falta: "pontas ligadas" virar um dispositivo que liga a outra asa, e os tipos e as contas (Whitcomb, Prandtl) combinados com o dono | Interface | G02 | — | Em andamento |
| G04 | Tabela "Comandos" da Empenagem, sem campos de uma configuração só | Interface | G02 | — | Terminado |
| G05 | Estabilidade estática do avião inteiro no núcleo (`core/src/sim/static.zig`): ponto neutro, ME × xCG, δe × CG, C_m × α, δe de equilíbrio × V e as derivadas, em Estabilidade → Avião montado | Cálculo | G02 | — | Terminado |
| G06 | Estabilidade em duas subabas, estática e dinâmica. Hoje "Avião montado" junta a estática e os modos, e a "Estabilidade dinâmica" (rajada, LAPES, líquido) entra no fim da área: falta separar e dar os nomes | Interface | G05 | — | Em andamento |
| G07 | Mini-MDO e Estudo e ponto de projeto em Zig | Interface | — | — | Terminado (acd014d) |
| G08 | Escolher as opções de uma variável de lista numa lista com busca: o seletor já existe (`ListPicker` em `ui/stage.zig`), mas nada o usa; hoje as opções se digitam separadas por vírgula | Interface | — | — | Em andamento |
| G09 | Navegador: lltdrek, ASB e AVL como pacotes do Pyodide (hoje ele já só carrega quando um método de fora é pedido, mas só com o numpy). O "Parar" já existe | Interface | — | — | Não iniciado |
| G10 | Montagem em Zig igual à antiga: editar, acrescentar e remover peças, vistas, arraste no 3D, variantes, Restaurar, Acertar o CG e vento | Interface | — | — | Terminado |
| G11 | Motores e montagem: tirar ou não o "lastro de equilíbrio" da etapa (o CG é só de projeto); espera a decisão do dono | Interface | — | — | Não iniciado |
| G12 | O `.dat` da hélice (J, C_T, C_P) como entrada: Biblioteca → Hélices, "+ .dat…", e a hélice entra no catálogo do avião | Interface | G45 | — | Terminado |
| G13 | Desempenho em Zig igual ao antigo | Interface | G08 | — | Terminado |
| G14 | Divisa arrastável e campo de número que troca o valor ao digitar | Interface | — | — | Terminado (commit ef88c93) |
| G15 | Gráficos com títulos curtos em TeX e exportar vários de uma vez | Interface | — | — | Terminado |
| G16 | Nenhum texto cortado nas tabelas e nos rótulos | Interface | — | — | Terminado (commit 6cef05e) |
| G17 | Abrir e salvar pela janela de arquivo do sistema | Interface | — | — | Terminado (commit f86cfd2) |
| G18 | `zig build` no Linux com o ligador do Zig | Interface | — | — | Terminado (commit af25095) |
| G19 | READMEs com as telas em Zig | Interface | — | — | Terminado (commit 489a40b) |
| G20 | Estabilidade dinâmica: polos, LAPES, sloshing e rajada (feitos). Falta: tanques inclinados e a varredura da posição, da inclinação e de quantos tanques, com os polos, as qualidades de voo e a margem de Lyapunov numa rajada | Interface | — | — | Em andamento |
| G21 | Menu Arquivo: "Salvar como…" (o importar catálogo já está na Biblioteca) | Interface | — | — | Não iniciado |
| G22 | Instalável: o dono testar o `.exe` no Windows | Ferramenta | — | — | Em andamento |
| G23 | Todas as análises com aba em Zig | Interface | G20 | — | Terminado |
| G24 | Contas longas numa thread, sem travar a janela. Falta: o raio automático das curvas em paralelo | Interface | G23 | — | Em andamento |
| G25 | Threads no navegador: pthreads do emscripten, com o `coi-serviceworker` no site (mexe no site publicado: a página recarrega uma vez na primeira visita) | Interface | G24 | — | Não iniciado |
| G26 | Página do tracking em HTML | Interface | — | — | Terminado (commit dc19cf2) |
| G27 | Bancada de técnicas de otimização do código | Interface | G26 | — | Terminado |
| G28 | O aerosim sem Python. Feito também: a polar de arquivo nas etapas e a coluna "calculado" das restrições. Falta: a polar do NeuralFoil nas etapas e a decisão do dono sobre os métodos de fora (um VLM no núcleo ou opcionais), e então tirar o Python do instalável | Interface | G23 | alta | Em andamento |
| G29 | L/D de cruzeiro do Analisar depois do estol | Análise | — | alta | Terminado (commit f6ba09c) |
| G30 | Usabilidade (Ctrl+Z, janela vazia, avisos). Falta: refazer (Ctrl+Y) e os outros avisos (T70) | Interface | — | — | Em andamento |
| G31 | Suspeita: a estática clássica da Empenagem não bate com o núcleo: dε/dα = 0,89 (o usual é 0,3 a 0,5), ponto neutro em 27 % da CMA contra 45 % no VLM, conferir a fórmula e o a usado (Etkin e Reid; Raymer) e usar o dε/dα do VLM quando ligado | Cálculo | — | alta | Não iniciado |
| G32 | Nenhum refino escondido | Interface | — | alta | Terminado (commit 10c2313) |
| G33 | Polares por Reynolds em Perfis | Interface | T10 | média | Terminado (commit 32e9afb) |
| G34 | Suspeita: o modificador de esteira não muda nada ligado com os ganhos padrão (começam em 0). Conferir na fonte o ganho padrão e criar o teste | Análise | — | alta | Não iniciado |
| G35 | Suspeita: no Analisar da asa em caixa, o Resumo dá C_Lmax 2,23 e C_Lα = −3,27/rad, mas a curva chega a 1,1. Conferir a escala por área em `compareSolvers` e o α das derivadas; criar o teste | Análise | — | alta | Não iniciado |
| G36 | Jeito celular da tela. Falta: o aeroopt no jeito celular, a tela nítida em alta densidade e as janelas por cima (refino, condições) | Interface | — | — | Em andamento |
| G37 | Um avião só (vitor, 2026-11-19): o projeto monta o avião da Montagem e das análises, sempre o mesmo do projeto à Montagem | Fundação | — | alta | Terminado (commit 4ec67f4) |
| G38 | Arquivo `.aero` (um zip com o manifesto e o avião em ZON, com as datas): Abrir e Salvar, o AeroDrive lendo, os exemplos convertidos | Fundação | G37 | alta | Terminado (commit f22f543) |
| G39 | AeroDrive: preferências em `.aerocfg` e voo gravado numa pasta com `dados.csv` e `video.mp4` | Ferramenta | G38 | média | Terminado (commit 6c03dda) |
| G40 | Modo escuro como opção (o claro é o padrão) e destaque azul vivo no claro | Interface | — | média | Terminado (commit f9944d3) |
| G41 | Planilha… em cada área: a `.xlsx` como no Excel, o bloco marcado ou achado sozinho, colunas sugeridas e guardar com nome; o polinômio de tração vai para o motor do avião | Interface | — | alta | Terminado (commit e25835f) |
| G42 | Exportar… do Desempenho: a planilha no formato da equipe, com prévia | Interface | G41 | alta | Terminado (commit 8149305) |
| G43 | Exportar dos gráficos e tabelas (botão direito): PNG, PDF e `.xlsx`, com prévia | Interface | G42 | alta | Terminado (commit 06bee7f) |
| G44 | Exportar a Aerodinâmica e a E&C no formato das planilhas da equipe, com prévia e escolha das superfícies | Interface | G42 | alta | Terminado (commit abf5dbd) |
| G45 | Planilha… de hélices: ler os coeficientes Q, T e P (falta saber se a variável é J ou a rotação) e converter C_T/C_P × J para o polinômio do MATLAB (ajuste por mínimos quadrados); avisar quando a hélice do motor não tem dados, em vez de tração zero | Cálculo | G41 | alta | Não iniciado |
| G46 | Exportar… do Desempenho: as altitudes viram campo na tela (hoje 0, 600 e 1000 m fixas) e gravar vários gráficos selecionados de uma vez também em `.xlsx` | Interface | G42 | média | Não iniciado |
| G47 | Planilha…: o que falta ler das planilhas da equipe: E&C da planilha de saídas, polares separadas por parte, as três altitudes de uma vez, a planilha de missão (células soltas), extras do motor (Kt, I0, indutância, inércia, amortecimento) e as combinações guardadas como curvas nos gráficos das análises | Interface | G41 | média | Não iniciado |

### core

O núcleo físico em Zig (`core/`): dinâmica, aerodinâmica, cargas, estruturas, modifiers e a ABI. Serve o aerosim, o AeroDrive e o aeroopt.

| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
|---|---|---|---|---|---|
| T54 | Flape de verdade, por tipo (simples, ventral, fendido, Fowler): ΔC_l máx, ΔC_d, ΔC_m e comando na decolagem e no pouso, com o método escolhido pelo usuário (hoje é só uma deflexão somada à incidência). Primeiro o plano com as fontes | Cálculo | — | alta | Não iniciado |
| T55 | Linha sustentadora das cargas: enflechamento, versão não linear e pós-estol (feitos). Falta: a revisão do dono | Cálculo | — | — | Em andamento |
| T64 | Linha sustentadora de Goates e Hunsaker 2021 no núcleo | Cálculo | T63 | — | Terminado (na `main`) |
| T65 | Voar com outro modelo aerodinâmico (faixas, linha sustentadora ou tabela; feitos). Falta a fase C: efeito solo por imagens na linha sustentadora e nas tabelas (Katz e Plotkin, a conferir) | Cálculo | T64 | — | Em andamento |
| T73 | A malha da simulação põe a força da asa trapezoidal no meio da semienvergadura (na asa enflechada de 25°, o ponto neutro fica 10 % da CMA atrás). Propor a correção; muda os números, então só com o ok do dono | Cálculo | T63 | — | Não iniciado |
| T89 | Aerodinâmica → Analisar: só as asas (uma, biplano, tandem, canard), como no túnel, com a varredura do núcleo, o estol, a carga na envergadura e a lista de métodos para rodar | Cálculo | T55 | — | Terminado |
| T90 | Suspeita: no biplano, a linha sustentadora dá ao par 0,89 da asa sozinha e o VLM 0,77 (folga 0,3 m, corda 0,4 m, α 6°). Conferir contra Munk (NACA Report 151) e, se for limite do método, avisar quando a folga for pequena | Cálculo | T89 | — | Não iniciado |
| T91 | Teste de desfazer da GUI antiga quebrado quando já existe o projeto de quem roda (o teste saiu junto com a GUI em Python) | Cálculo | — | — | Não iniciado |
| T93 | O tubo que liga as asas do tandem é da Montagem, não da Empenagem | Interface | — | — | Terminado |
| T94 | Sentido do x do bordo de ataque das asas dito na ajuda | Interface | — | — | Terminado |
| T96 | Suspeita: a asa em caixa não ganha nada nos métodos de carga do núcleo (o C_Di fica igual), mas a teoria diz menos induzido (Prandtl, NACA TN 182; Kroo 2001: e ≈ 1,46 com h/b = 0,2). Conferir com o VLM do ASB e o AVL | Cálculo | G03 | — | Não iniciado |
| T97 | Passar as outras interpolações lineares do núcleo (polares, Reynolds, tabelas) para `core/src/math/interpolation.zig`, com a regressão bit a bit | Fundação | — | baixa | Em andamento |
| T57 | Esteira desviada pelo escoamento e com perfil radial (Duivenvoorden et al. 2026; Rethorst), validada contra Stuper (NACA TM 874) | Cálculo | — | — | Não iniciado |
| T62 | Núcleo: efeito diedro (C_lβ −0,139 contra −0,070 do voo no Navion) e C_Lq (4,8 contra 15,9). Achar a causa nas faixas e corrigir com fonte | Cálculo | — | — | Não iniciado |
| T61 | Contribuição da fuselagem (C_mα, C_nβ, C_Yβ) e interferência asa–fuselagem por método da literatura escolhido pelo usuário (hoje o usuário digita ou fica zero). Primeiro o plano com as fontes | Cálculo | — | — | Não iniciado |
| T10 | Reynolds no voo: as faixas da simulação usam a polar do Re de cada faixa (a leitura e a interpolação em Re já existem) | Cálculo | — | — | Não iniciado |
| T08 | Esteira: trimagem com a esteira e o tubo desviado | Cálculo | — | — | Não iniciado |
| T56 | Hélice no chão no núcleo: folga da pá a cada passo e a opção que encerra o voo (`prop_strike`, desligada por padrão) | Cálculo | — | — | Terminado |
| T05 | E&C não linear: funções de Lyapunov e região de atração em mapa de calor, com sloshing e vento. Primeiro o plano com as fontes | Cálculo | — | — | Não iniciado |
| T38 | Arquitetura de cargas e aeroelasticidade: interfaces (casos de carga, viga EI/GJ, laço aeroelástico). Primeiro o plano | Fundação | — | — | Não iniciado |
| T13 | Casos de carga do V-n no núcleo | Cálculo | T38 | — | Terminado (commit 54012f4) |
| T14 | Rajada no núcleo | Cálculo | T38 | — | Terminado (commit 54012f4) |
| T15 | Cortante, fletor e torsor no núcleo | Cálculo | T13, T14 | — | Terminado (commit 54012f4) |
| T16 | Manobras dinâmicas: o 6GDL monta os casos de carga | Cálculo | T13 | — | Não iniciado |
| T17 | Momento de dobradiça (distribuição na corda, método da literatura) | Cálculo | T38 | — | Não iniciado |
| T18 | Cargas no solo: faltam os casos além do impacto do pouso | Cálculo | T38 | — | Em andamento |
| T20 | Estruturas: arquitetura e banco de materiais (dados do usuário ou da literatura) | Fundação | — | — | Em andamento |
| T21 | Longarina: falta juntar a seção e a flambagem (já no núcleo) aos esforços | Fundação | T15, T20 | — | Em andamento |
| T22 | Tubo de cauda | Fundação | T15, T20 | — | Não iniciado |
| T23 | Trem (eixo, garfo) e impacto do pouso no núcleo | Fundação | T20 | — | Terminado (commit 54012f4) |
| T39 | Redistribuir as cargas para a malha da estrutura | Cálculo | T15, T20 | — | Não iniciado |
| T24 | Rigidez e centro elástico | Cálculo | T21 | — | Não iniciado |
| T25 | Divergência no núcleo | Cálculo | T24 | — | Terminado (commit 54012f4) |
| T26 | Reversão de comando no núcleo | Cálculo | T24 | — | Terminado (commit 54012f4) |
| T27 | Diedro elástico em E&C | Cálculo | T21 | — | Não iniciado |
| T28 | Paralelismo no núcleo | Cálculo | — | — | Não iniciado |
| T29 | Monte Carlo e sensibilidade | Cálculo | T28 | — | Não iniciado |
| T30 | Turbulência Dryden | Cálculo | — | — | Não iniciado |
| T31 | Vento cruzado na decolagem | Cálculo | — | — | Não iniciado |
| T32 | Modos de vibração e flutter no núcleo | Cálculo | T21 | — | Terminado (commit 54012f4) |
| T76 | Modificador de interferência entre asas (tandem, biplano) | Cálculo | T78 | — | Terminado (na `main`) |
| T77 | Erros claros em vez de pane no núcleo | Cálculo | — | — | Terminado (na `main`) |
| T87 | Legibilidade do núcleo (erros, nomes, enums, `///`) | Cálculo | — | — | Terminado (na `main`) |
| T83 | VTOL, nesta ordem: quadplane, tilt-rotor, tailsitter (a Micro 2026 permite, seções 9.4 e 9.5). Primeiro o plano com as fontes | Cálculo | — | — | Não iniciado |

**Caminho das estruturas:** T20 → T21 → T24 → T27; T15 e T20 → T22 e T39.

### aerodrive

O simulador de voo em tempo real (Zig + raylib) que pilota o avião projetado. Usa o núcleo com o modelo de faixas e tem o próprio modelo de massas (`aerodrive/src/sim/params.zig`).

| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
|---|---|---|---|---|---|
| T80 | Abrir qualquer avião sem pane (erros viram mensagem na tela) | Cálculo | T77 | — | Terminado (na `main`) |
| T81 | Massa das superfícies simétricas em cada lado (Ixx do tandem) | Cálculo | — | — | Terminado (na `main`) |
| T82 | Voar VTOL: transição e comandos de cada arranjo | Cálculo | T83 | — | Não iniciado |
| T92 | Suspeita: o AeroDrive desenha errado o perfil de quem só aponta o `.dat` (sem `coords`): o "S1223" vira NACA 1223. Ler o `.dat` como a Montagem já lê, com teste do contorno | Cálculo | — | — | Não iniciado |

### aeroopt

O otimizador genérico (MDO) que monta um problema a partir de peças trocáveis e avalia cada candidato no núcleo. Primeiro caso: SAE BRASIL AeroDesign 2026. O aeroopt em Python saiu (67bcd62); as buscas do núcleo (`core/src/optim`: GA, CMA-ES, DE, guiada pela falha, RBF, amostragem, sensibilidade) ficaram, e as tarefas abaixo voltam a valer quando a O41 trouxer a rodada em etapas para o Zig.

| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
|---|---|---|---|---|---|
| O01 | Pontuação da Micro 2026 com fonte | Cálculo | — | — | Terminado (na `main`) |
| O02 | Contratos do otimizador e o arquivo `.opt.json` | Fundação | — | — | Terminado (na `main`) |
| O03 | Expressão de pontuação e álgebra linear no núcleo | Cálculo | O01, O02 | — | Terminado (na `main`) |
| O04 | Ferramenta de linha de comando do aeroopt | Cálculo | O03 | — | Terminado (na `main`) |
| O05 | Janela do aeroopt | Interface | O04, O13 | — | Terminado (na `main`) |
| O13 | Processo em etapas: configurações → superfícies → MTOW no 6GDL → nota | Cálculo | O04 | — | Terminado (na `main`) |
| O16 | Momento do elevon da asa voadora | Análise | O13 | — | Terminado (na `main`) |
| O26 | Tandem com deriva na ponta voando na E&C | Análise | — | — | Terminado |
| O27 | Posição da carga paga como variável | Análise | O26 | — | Terminado |
| O28 | Estabilidade dinâmica ligada na E&C do tandem | Análise | O26 | — | Terminado |
| O33 | Proteção de α obrigatória na decolagem | Análise | — | — | Terminado |
| O12 | Substituto aprendido do histórico (RBF no núcleo, `core/src/optim/rbf.zig`) | Cálculo | — | — | Terminado |
| O41 | O aeroopt inteiro em Zig. Feito: o problema, o projeto, as variáveis e um candidato avaliado. Falta: a rodada em etapas com as buscas do núcleo (mexendo nas linhas das configurações guardadas do projeto), o mapa dos aviões, a tabela, os gráficos do melhor, a sensibilidade e o CSV | Interface | — | alta | Em andamento |
| O06 | Variáveis abertas (qualquer campo do avião) e as duas cargas da Micro (líquido e LAPES, duas posições de CG) | Análise | O41 | — | Não iniciado |
| O07 | Orquestração das avaliações (vagas fixas no núcleo, cascata, filtro por fidelidade) e reparo antes de avaliar | Cálculo | O06, T28 | — | Não iniciado |
| O08 | Caixa, montagem e desmontagem como sub-problema | Cálculo | O07 | — | Não iniciado |
| O09 | Efeitos desligados na busca e o melhor reavaliado com todos ligados | Análise | O07 | — | Não iniciado |
| O10 | Busca local (Gould e Leyffer) e Lagrangiano aumentado no lugar da penalidade fixa | Cálculo | O41 | — | Não iniciado |
| O11 | SIMD e GPU no avaliador, só depois de medir | Análise | O07, T47 | — | Não iniciado |
| O14 | Do MDO antigo da equipe: regra 80/20 do trem, variáveis por razão nas partições da asa, inércia da fuselagem como caixa e arrasto das fixações do biplano | Cálculo | O41 | — | Não iniciado |
| O15 | Topologias: gramática e peças novas no montador (EV entre asas, elevon, motores fora da asa, fuselagem entre asas, conectores com massa, 3+ asas) | Cálculo | O41 | — | Não iniciado |
| O17 | Suspeita: no núcleo, o C_m da asa voadora não cresce com o elevon além de 20° (cai de 0,059 a −20° para 0,021 a −27,5°). Achar a causa: eficácia do flape, estol da faixa ou C_L limitado | Análise | — | — | Não iniciado |
| O18 | Suspeita: o C_m,ac da asa voadora na etapa não tem o termo da torção com enflechamento (Nickel e Wohlfahrt, a conferir no PDF). Comparar com o núcleo antes de acrescentar | Análise | O16 | — | Não iniciado |
| O19 | Tandem: a asa de trás tem de entrar como a cauda na estática (profundor na asa 2, decalagem e distância como comandos), com um exemplo de tandem | Análise | O13 | — | Não iniciado |
| O20 | Asa voadora na pista: falta a decolagem no 6GDL e o winglet como EV | Análise | O41 | — | Não iniciado |
| O21 | Suspeita: na asa enflechada, a ME da etapa não bate com a do núcleo (12 % vira 18,8 % com 30° de enflechamento e −6° de torção); no tandem, o ponto neutro do núcleo fica ~14 % da CMA atrás. Comparar com a literatura antes de corrigir | Análise | O16 | — | Não iniciado |
| O23 | Regular 2026: a penalidade de potência (acima de 600 W) pede a potência elétrica de pico em voo, que o avaliador não entrega; os expoentes da eq. 7.5 e o B ≤ 4,0 m estão a conferir no PDF | Análise | O41 | — | Não iniciado |
| O24 | Missão completa só no melhor de cada geração, fora da nota: diz se o avião cumpre o voo | Análise | O41 | — | Não iniciado |
| O25 | Busca local na E&C: decidir se o hipercubo latino e as partidas viram padrão (sementes no tandem e na asa voadora) e o reinício IPOP no CMA-ES | Análise | O41 | — | Não iniciado |
| O29 | Decolagem: estimar a massa pela corrida sem acionar para encurtar a bisseção | Análise | O41 | — | Não iniciado |
| O30 | Busca da E&C guiada pela falha: o estol por superfície como termo, o diedro nos comandos e a escolha do método padrão | Análise | O41 | — | Não iniciado |
| O31 | Tandem com asas diferentes (área e perfil de trás como variáveis): nenhum voa ainda na Regular 2026, e o MTOW no 6GDL leva 730 s | Análise | O41 | — | Não iniciado |
| O35 | Tandem: a opção "profundor na frente, aileron atrás" (como no Quickie, a conferir no PDF) | Análise | O31 | — | Não iniciado |
| O36 | Otimizador padrão, sem o usuário escolher: MAP-Elites por categoria e cauda (Mouret e Clune, 2015) e o "automático" (halving entre configurações, fase guiada pela falha, fase memética) | Análise | O41 | — | Não iniciado |
| O37 | Funil das etapas na janela: quantos passaram e caíram em cada etapa, e por quê | Análise | O41 | — | Não iniciado |
| O42 | Sala P2P (WebRTC), 1: a sala e o link. A sala nasce com 32 bytes aleatórios (`std.crypto.random`) e vira o link `…/aeroopt#sala=<base64url>` (o que vem depois do `#` não sai do navegador); deles saem o tópico no relay (um hash) e a chave que cifra a sinalização (ChaCha20-Poly1305). Sinalização por relays públicos Nostr, como a Trystero (plano B: um relay pequeno nosso; para teste, copiar e colar a oferta). Cada sessão tem um link novo e fechar a sala apaga a chave. No navegador, `RTCPeerConnection`; no PC, a `libdatachannel` (LGPL, ligada como `.so`/`.dll`) | Fundação | O41 | — | Não iniciado |
| O43 | Sala P2P, 2: quem é quem. Quem abre a sala é o mestre; cada participante assina a oferta com a chave Ed25519 dele, o mestre confere a impressão digital do DTLS que veio na oferta assinada (fecha a porta para um relay no meio), vê quem entrou e pode recusar | Fundação | O42 | — | Não iniciado |
| O44 | Sala P2P, 3: o que trafega. Só dados no formato binário do projeto, com tamanho máximo e verificados como o `.bin`: a pontuação, o problema, o projeto, os pedidos e os resultados; nada vira código. Antes de começar, cada um manda o hash da versão do núcleo, e versão diferente fica de fora (o resultado tem de sair bit a bit igual) | Fundação | O43 | — | Não iniciado |
| O45 | Sala P2P, 4: a divisão das contas. O mestre mantém a fila de candidatos de cada etapa; cada participante pede trabalho quando fica livre, e o item de quem demora volta para a fila. O mestre escolhe: tudo dividido, só a etapa cara (6GDL) ou ele sozinho | Cálculo | O44 | — | Não iniciado |
| O46 | Sala P2P, 5: confiar nos resultados. Uma parte dos itens (por exemplo 10 %, sorteados) vai para duas pessoas e é comparada bit a bit; quem diverge sai da sala e os itens dele são refeitos | Cálculo | O45 | — | Não iniciado |
| O47 | Sala P2P, 6: o mesmo canal para trocar aviões (`.aero`) no aerosim e arquivos em geral | Interface | O44 | — | Não iniciado |
| O38 | Tandem: conferir no Kryvokhatko (2025, pp. 201–211) a faixa de recuo de 3 a 5 cordas e passar a variável de metros para cordas | Análise | O31 | — | Não iniciado |
| T59 | Otimização de perfis (CST com o NeuralFoil ou o XFOIL), objetivo e restrições do usuário. Primeiro o plano com as fontes | Cálculo | — | — | Não iniciado |

### comum

Ferramentas, checks, documentação e git, que valem para os quatro segmentos.

| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
|---|---|---|---|---|---|
| T00 | Checks de regressão | Ferramenta | — | — | Terminado |
| T01 | Conferir os ❓ | Ferramenta | — | — | Terminado |
| T36 | Guia de desenvolvimento e mapa do código | Ferramenta | — | — | Terminado |
| T47 | Perfil de tempo do núcleo: flame graph e tabela por função (Callgrind para o exato) | Ferramenta | — | — | Não iniciado |
| T48 | Snapshot do resultado de cada aba nos checks, com `--aceitar` para mudança intencional | Ferramenta | — | — | Não iniciado |
| T49 | Smoke test de todas as abas: abre sem tela, roda com os padrões e todo gráfico tem dado | Ferramenta | — | — | Não iniciado |
| T50 | `zig fmt --check` nos checks e hook de `pre-push` com os checks rápidos | Ferramenta | — | — | Não iniciado |
| T88 | Checks no GitHub Actions a cada PR para a `main` | Ferramenta | — | — | Terminado |
| T51 | Tempo como regressão: benchmarks contra a `main`, só aviso | Ferramenta | T47 | — | Não iniciado |
| T52 | Testes de propriedade (simetria, soma das cargas, monotonicidade…), cada lei com fonte | Ferramenta | — | — | Não iniciado |
| T53 | Avisos de documentação nos checks (README em pasta nova, fonte de fórmula no Zig, CHANGELOG no PR) | Ferramenta | — | — | Não iniciado |
| T02 | Rodar os checks na pilha e corrigir | Ferramenta | T00 | — | Terminado |
| T03 | PRs da pilha para a `main` | Ferramenta | T02 | — | Terminado (PRs #21–#25) |
| T75 | READMEs de cada pasta com as equações e um exemplo | Ferramenta | — | — | Terminado (na `main`) |

---

## Itens por área (aerosim)

Cobertura do que o aerosim calcula e mostra. O núcleo, o AeroDrive e o aeroopt entram aqui pelo que aparece na GUI.
Onde cada coisa mora no código fica em `docs/AREAS.md`.

Legenda das colunas **Código** e **GUI**: ✅ coberto (na GUI: roda e mostra); 🟡 parcial; ❌ não existe.

### 1. Aerodinâmica

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| AE-01 | Biblioteca de perfis, polares 2D por Reynolds | ✅ | ✅ | — | Perfis |
| AE-02 | Asa finita: núcleo (VLM, linha sustentadora), lltdrek, ASB, AVL | ✅ | ✅ | T70 | a linha sustentadora de Phillips e Snyder não converge com enflechamento nem β; a de Goates e Hunsaker sim |
| AE-03 | Asa por partições, perfil por seção | ✅ | ✅ | — | Projetar |
| AE-04 | Polar do avião completo | ✅ | ✅ | — | Aerodinâmica → Analisar |
| AE-05 | Dispositivos de ponta de asa | ✅ | ✅ | G03 | Projetar → Dispositivos |
| AE-06 | Arrasto por componente | 🟡 | ❌ | T11 | o núcleo separa por grupo para o Exportar |
| AE-07 | Downwash na cauda | 🟡 | 🟡 | G31 | empírico na simulação; ferraduras nas cargas |
| AE-08 | Efeito solo (McCormick) | ✅ | ✅ | — | modifier `solo.mccormick` |
| AE-09 | Efeito solo por imagem (inclui a mesa) | 🟡 | ✅ | T65 | feito no VLM (modifier `solo.vlm_image`); falta a mesa e a imagem na linha sustentadora do voo |
| AE-10 | Esteira da hélice nas superfícies | 🟡 | 🟡 | T08 | `esteira.disco`; tubo reto, trimagem sem esteira |
| AE-11 | Reynolds no núcleo | 🟡 | 🟡 | T10 | polares por Re em Perfis; o voo ainda não usa |
| AE-12 | Distribuição ao longo da envergadura a um α | ✅ | ✅ | — | Analisar e Cargas → Distribuição |
| AE-13 | Comparação com ensaio | ❌ | ❌ | T35 | |
| AE-17 | Flape (ΔC_l, ΔC_l máx, ΔC_d, ΔC_m; comando na decolagem e no pouso) | 🟡 | ❌ | T54 | hoje só deflexão fixa na incidência da faixa |
| AE-18 | Otimização de perfis | ❌ | ❌ | T59 | futuro |
| AE-19 | Modelo aerodinâmico do voo selecionável (faixas, linha sustentadora, tabela) | ✅ | ❌ | T66 | `core/src/physics/aeromodel.zig`; o padrão e o AeroDrive não mudam |
| AE-20 | Linha sustentadora de Goates e Hunsaker (derrapagem, enflechamento) | ✅ | 🟡 | T70 | nas abas Cargas e Aerodinâmica; falta o aviso |
| AE-21 | Tabela de voo de qualquer método (lltdrek, ASB, AVL) | 🟡 | ❌ | T66 | `core/src/physics/aerotable.zig` |
| AE-22 | Comparar modelos aerodinâmicos voando a missão | ❌ | ❌ | T69 | |

### 2. Desempenho

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| DE-01 | Motor + hélice + bateria | ✅ | ✅ | — | Desempenho → Tração |
| DE-02 | Biblioteca de motores e hélices | 🟡 | 🟡 | G21 | Biblioteca |
| DE-03 | Comparação de conjuntos motopropulsores | 🟡 | 🟡 | — | etapa Motores |
| DE-05 | Ajuste de ensaio dinâmico de hélice | ❌ | ❌ | G45 | |
| DE-06 | Decolagem com pista limitada / mesa | ✅ | ✅ | — | |
| DE-07 | Decolagem com vento cruzado | ❌ | ❌ | T31 | |
| DE-08 | MTOW × altitude-densidade | ✅ | ✅ | — | |
| DE-09 | Subida, nivelado, envelope | ✅ | ✅ | T44 | a subida simulada está errada |
| DE-10 | Curvas com fator de carga | ✅ | ✅ | — | Missão → curvas |
| DE-11 | Planeio | ✅ | ✅ | — | |
| DE-12 | Pouso | ✅ | ✅ | — | etapa "pouso" da Missão |
| DE-13 | Consumo por fase de voo | ✅ | ✅ | — | Missão: consumo por etapa (com corrente de pico) |
| DE-15 | Monte Carlo e sensibilidade | ❌ | ❌ | T29 | |
| DE-16 | Turbulência contínua | ❌ | ❌ | T30 | |

DE-04 (perda de tração por corpos atrás da hélice) foi para as Torres, com o CFD 3D.

### 3. Estabilidade e Controle

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| EC-01 | Estática longitudinal (PN, ME) | ✅ | ✅ | G31 | |
| EC-02 | ME × xCG com ênfase | ✅ | ✅ | — | |
| EC-03 | Passeio do CG (LAPES, líquido) | ✅ | ✅ | — | Missão |
| EC-04 | Limite dianteiro do CG pela rotação | ✅ | ✅ | — | |
| EC-05 | Diagrama tesoura | ✅ | ✅ | — | |
| EC-06 | Trimagem | ✅ | ✅ | — | |
| EC-07 | Dimensionamento de EH/EV e comandos | ✅ | ✅ | — | |
| EC-08 | Vento de través no pouso | ✅ | ✅ | T37 | leme com 0,2 V_S de través (FAR 23.233) |
| EC-09 | Taxa de rolamento | ✅ | ✅ | — | aileron por φ em t (MIL-F-8785C) |
| EC-10 | Dinâmica: modos e respostas | ✅ | ✅ | — | |
| EC-11 | Qualidades de voo (MIL-F-8785C) | ✅ | ✅ | — | |
| EC-12 | Vento lateral/frontal nos polos | ❌ | ❌ | T05 | |
| EC-13 | Polos com sloshing | ✅ | ✅ | — | Estabilidade dinâmica |
| EC-14 | Diedro elástico | ❌ | ❌ | T27 | |
| EC-15 | Comparação com voo real | ❌ | ❌ | T35 | |
| EC-16 | Inverter a rotação de qualquer motor | ✅ | ✅ | — | |
| EC-17 | Posição e ângulo do tanque de líquido × modos | ❌ | ❌ | G20 | os tanques já vão em qualquer lugar; falta a inclinação e a varredura |
| EC-18 | Estabilidade em duas subabas, estática e dinâmica, da configuração inteira | ✅ | 🟡 | G06 | a estática do avião inteiro está no núcleo; falta separar as subabas |

### 4. Cargas

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| CA-01 | Distribuição por superfície (V, n, rpm, com/sem hélice) | ✅ | ✅ | — | aba Cargas |
| CA-02 | Vista 3D e gráficos | ✅ | ✅ | — | aba Cargas |
| CA-03 | Casos do V-n | ✅ | 🟡 | — | `core/src/loads/vn.zig` |
| CA-04 | Rajada (fórmula e norma escolhidas pelo usuário) | ✅ | ❌ | — | `core/src/loads/vn.zig` |
| CA-05 | Manobras dinâmicas | ❌ | ❌ | T16 | |
| CA-06 | Cortante, fletor, torsor | ✅ | ❌ | — | `core/src/loads/internal.zig` |
| CA-07 | Momentos de dobradiça | ❌ | ❌ | T17 | |
| CA-08 | Cargas no solo | 🟡 | ❌ | T18 | impacto do pouso em `core/src/structures/gear.zig` |
| CA-09 | Redistribuição das cargas para a estrutura | ❌ | ❌ | T39 | |
| CA-10 | V-n com dados de voo | ❌ | ❌ | T40 | |
| CA-11 | Cargas pelo VLM do AeroSandbox | ✅ | ✅ | — | aba Cargas → Método |

### 5. Aeroelasticidade

| ID | Tópico | Código | GUI | Tarefa |
|---|---|---|---|---|
| AL-01 | Rigidez e centro elástico | ❌ | ❌ | T24 |
| AL-02 | Divergência | ✅ | ❌ | — |
| AL-03 | Reversão de comando | ✅ | ❌ | — |
| AL-04 | Modos e flutter | ✅ | ❌ | — |

### 6. Estruturas

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| ES-01 | Massas e inércias | ✅ | ✅ | — | Montagem |
| ES-02 | Longarina | 🟡 | ❌ | T21 | seção e flambagem em `core/src/structures` |
| ES-03 | Tubo de cauda | ❌ | ❌ | T22 | |
| ES-04 | Materiais | 🟡 | ❌ | T20 | dados do usuário; nunca dos relatórios de referência |
| ES-05 | Trem | ✅ | ❌ | — | `core/src/structures/gear.zig` |

### 7. Elétrica — fora do escopo

Escolher bateria, servos e cabos é trabalho da área de elétrica. A Missão mostra só o que a simulação já calcula: a
corrente média e a de pico por etapa e o consumo.

### 8. Integração / Projeto

| ID | Tópico | Código | GUI | Tarefa | Observação |
|---|---|---|---|---|---|
| IN-01 | Mini-MDO (pontuação) | ✅ | ✅ | O41 | vira um problema do aeroopt |
| IN-02 | Projeto do zero em etapas | ✅ | ✅ | — | `aerosim/design` |
| IN-03 | Montagem sem exigir decolagem | ✅ | ✅ | — | |
| IN-04 | Tração e Missão dentro de Desempenho | ✅ | ✅ | — | |
| IN-05 | xCG em % CMA | ✅ | ✅ | — | |
| IN-06 | Checklist do avião | ✅ | ✅ | — | |
| IN-08 | Volume e arranjo da caixa | ❌ | ❌ | O08 | sub-problema do aeroopt |
| IN-09 | Tempo de montagem e desmontagem | ❌ | ❌ | O08 | |
| IN-11 | Etapas desatualizadas (assinatura do modelo) | ❌ | ❌ | T41 | |
| IN-12 | Restrições, normas e métodos só por preset do usuário | ❌ | ❌ | T37 | |
| IN-13 | Asas ligadas (tandem, biplano) | ✅ | ✅ | — | interferência no modifier `interferencia.asas` |
| IN-14 | Motores livres (nariz + asa + propulsora) | ✅ | ✅ | — | Desempenho → Tração |

### 9. Controle

| ID | Tópico | Código | GUI | Tarefa |
|---|---|---|---|---|
| CO-01 | Piloto automático genérico (autotune) | ✅ | ✅ | — |
| CO-02 | Aba de controle | ❌ | ❌ | T33 |

### Fora da lista

- **Opcionais** (dependem de dados de cada um): IN-07, banco histórico de pesos; IN-10, circuito real medido no mapa.
- **Ajuste de interface:** DE-14, massa total controlada na pista.
- **Torres:** AE-14, CFD 3D (inclui DE-04); AE-15, CAD; AL-05, aeroelasticidade dinâmica; ES-06 e ES-07, otimização
  estrutural e FEM; CO-03, SMC e NN-MPC; CO-05, helicóptero (o VTOL é a T83).
- **Infraestrutura:** hash da ABI ✅, modifiers ✅, colisão ✅, checks de regressão ✅; integrador adaptativo, números
  duais e SIMD em aberto; paralelismo (→ T28); testes de propriedade 🟡 (→ T52).

---

## Progresso da lista (0.4 quando chegar ao fim)

São os itens das seções 1 a 9 com ✅ na GUI. Recontado em 2026-11-21 na `0.3_dev`: o efeito solo por imagem (AE-09,
feito no VLM) e a distribuição a um α (AE-12, que a aba Cargas mostra) passaram a contar.

| Seção | ✅ na GUI / itens |
|---|---|
| 1. Aerodinâmica | 8 / 19 |
| 2. Desempenho | 8 / 14 |
| 3. Estabilidade e Controle | 13 / 18 |
| 4. Cargas | 3 / 11 |
| 5. Aeroelasticidade | 0 / 4 |
| 6. Estruturas | 1 / 5 |
| 8. Integração | 8 / 12 |
| 9. Controle | 1 / 2 |
| **Total** | **42 / 85 (49 %)** |

# Changelog

Versões da `main`. A regra de versão está em `docs/TRACKING.md` → Versões.

## Não lançado

### v0.2.3 (branch `0.2_dev`)

- aeroopt, dados de teste: `aeroopt/synthetic.py`, um avaliador com as mesmas etapas e colunas e o resultado sabido
  de antemão (onde cada configuração para, o ótimo em 70 % da faixa de cada contínua, a melhor configuração). As
  buscas das superfícies são as de verdade. `python -m aeroopt --exemplo --sintetico` roda a janela com ele, e
  `tools/pipeline_bench.py --sintetico S` mede só o paralelismo.
- paralelismo como módulo: contrato `IExecutor` (`aerosim/interfaces/executor.py`) e `aerosim/parallel` com as três
  formas de rodar (série, threads, processos) e o `Executors`, um de cada tipo para a rodada inteira. O `Pipeline` e
  as gerações do aeroopt rodam por ele, e os processos nascem uma vez por rodada, não a cada etapa de cada geração.
  O pool nasce com todos os trabalhadores de pé e o núcleo carregado em cada um (`initializer`, `stages.warm`).
  O Parar e um processo que morre no meio continuam tratados como antes. `tools/pipeline_bench.py --geracoes N`
  compara o pool que dura com o pool novo por etapa (`spawn-novo`, `forkserver-novo`), e o tempo de nascer sai numa
  coluna própria.
- núcleo, tração motor + hélice da sprint: a bisseção do equilíbrio motor × hélice de `power.thrust_of` foi para o
  núcleo (`core/src/sizing/motorprop.zig`, export `aerosim_motor_prop_thrust`, struct `MotorProp`,
  `ISimBackend.motor_prop_thrust`). Bit a bit igual à conta em Python de antes com todo o catálogo; era a maior parte
  do tempo do aeroopt e segurava o GIL.
- aeroopt, paralelismo: `tools/pipeline_bench.py` compara série, threads e processos (fork, spawn, forkserver) no
  processo em etapas, com o tempo e o ganho de cada etapa, a fração presa ao GIL e a conferência de que o resultado
  não muda; `Pipeline.times` guarda o tempo de cada etapa. Correção: o Otimizar ficava desligado depois de uma
  rodada com avião selecionado (a reconstrução dele contava como parte da rodada).
- aeroopt, README: só a descrição do braço, como a pasta se divide e a janela, com as imagens da GUI
  (`docs/img/aeroopt/`).
- aeroopt, gráficos do melhor avião: o melhor avião até aqui (voo válido antes, depois a nota) roda sozinho as
  análises rápidas do aerosim (decolagem da Missão com o profundor otimizado para a pista da restrição, polar do
  núcleo, estabilidade, desempenho) e os gráficos aparecem numa aba
  por análise, sem formulário e sem gravar nada (`BEST_ANALYSES`). A janela e os submenus cabem em 1366 × 768.
- aeroopt, mapa por variável: os eixos do mapa dos aviões são as variáveis do problema (as livres primeiro, depois as
  fixas) além das grandezas do resultado; a cor continua a nota. Uma lista (perfil, motor, sim/não) vira um eixo
  com o nome de cada opção. Abre nas duas primeiras variáveis livres.
- aeroopt, CMA-ES: terceiro método das superfícies e da etapa voa (`method="cma-es"`), o CMA-ES de Hansen (2016)
  no núcleo (`core/src/optim/cmaes.zig`, exports `aerosim_cma_init`, `aerosim_cma_ask`, `aerosim_cma_tell`, struct
  `CmaState`). Ele aprende a forma da região boa e anda ao longo das variáveis acopladas. Autovalores de matriz
  simétrica por Jacobi em `linalg.symEigen`; produtos em `@Vector` (AVX-512 com `-Dcpu=native`). Conferido contra a
  `pycma`. Os métodos antigos ficam iguais.
- aeroopt, voa antes do desempenho: etapa nova "voa" (`FlightCheck`) entre a geometria e as superfícies. Na massa
  estimada, sem MTOW, o avião tem que trimar, equilibrar sem lastro, ter a margem mínima e (com a restrição ligada)
  ser estável; se não voa como está, a etapa procura nas contínuas o ponto que viola menos. As buscas seguem as regras
  de viabilidade de Deb (2000): inválidos ordenados pela violação (`stages.violation`), e nas gerações das
  configurações pela etapa a que chegaram. Método na Configuração: buscar, conferir ou desligada.
- aeroopt, tabela e Parar: a tabela das configurações mostra o número (o nome fica na dica) e a área de projeto em que
  parou (`stages.area`). O Parar não espera a conta em andamento: o processo é encerrado (`Pipeline._map` espera
  0,2 s por vez).
- aeroopt, estabilidade e nota: restrição de estabilidade por ponto de projeto (`StabilityParams`, desligada por
  padrão; a análise da aba Estabilidade: $C_{n\beta}$, $C_{l\beta}$ e modos MIL-F-8785C), que faz diedro,
  enflechamento e deriva contarem. Voo inválido tem nota 0 (a conta fica em `nota_formula`). As gerações nas
  superfícies não repetem pontos e põem cada gene no passo do campo. Os arquivos gravados pela janela ganham a
  extensão quando o nome vem sem ela.
- aeroopt, a geometria conserta: quase toda configuração reprovava por bater no chão na rotação (o trem do montador
  só livra a hélice parado). O núcleo agora devolve quanto descer as rodas (`Report.gear_raise`, exato), a etapa
  grava a altura do trem na configuração e segue; cada ponto das superfícies faz o mesmo. Campo novo na sprint,
  `power_draft.gear_h` ("altura do trem", 0 = como antes, bit a bit).
- aeroopt, variáveis de tudo: o submenu das variáveis tem todo campo das etapas do aerosim com faixa ou escolha
  (`aeroopt/inputs.py`, lido da definição dos campos), uma aba por grupo. As listas (perfis, motor, hélice,
  bateria, cauda, trem, sim/não) ficam no mesmo submenu, marcadas por item; os submenus separados de perfis e
  peças saíram. Inteiros andam no passo do campo (motores na asa aos pares).
- aeroopt, esquerda em submenus: pontuação, variáveis, restrições, perfis, peças, categorias e configuração são
  botões com resumo, cada um abrindo o seu submenu. A geometria (ângulo de rotação, folgas, uma peça só) foi para
  as restrições. A configuração escolhe o método de cada etapa: configurações por gerações ou todas; superfícies
  por coordenadas ou por gerações nas contínuas (`SurfaceSizing(method=...)`, `StagedEvaluator(surfaces=...)`, o
  algoritmo genético do núcleo com genes reais); decolagem no 6GDL ou só na pista. Tudo vai no `.opt.json`
  (`params["geometria"]`, `params["etapas"]`).
- aeroopt, gerações: as configurações saem de um algoritmo genético no núcleo (`core/src/optim/ga.zig`, exports
  `aerosim_ga_init`, `aerosim_ga_next`; `aeroopt/generations.py`) no lugar de varrer todas as combinações, que
  passavam de um milhão com as listas marcadas. Configuração repetida não roda de novo. Na janela: configurações
  por geração e nº de gerações; na ferramenta: `--populacao`, `--geracoes`; coluna "geração" nos CSV.
- Geometria do avião montado no núcleo (`core/src/geometry`, export `aerosim_geometry_check`, interface
  `aerosim/interfaces/geometry.py`, tradutor `aerosim/backend/zig/geometry.py`): hélice que acerta peça, massa fora
  da geometria, pedaços soltos e folga ao chão parado e girado até o ângulo de rotação. No aeroopt vira a etapa
  "geometria", antes das superfícies, e cada ponto de projeto também passa por ela (desligável na janela).
- aeroopt, submenus do problema: variáveis (livre, valor do avião, limite inferior e superior), restrições, perfis
  por região (raiz e ponta da asa, EH, EV, com `.dat` acrescentado na hora) e motores, hélices, baterias e arranjo do
  catálogo, cada um num submenu aberto por botão, com o resumo ao lado; as listas se marcam, não se digitam, e cada
  lista marcada vira um eixo das configurações. Perfis da cauda e bateria entraram como variáveis de lista do aeroopt
  (`stages.EXTRA_INPUTS`). Uma restrição numa grandeza que é variável (envergadura, área, nº de motores) vira o limite
  dela (`problem.fold_bounds`). Os gráficos refazem os eixos a cada ponto. Nomes das configurações em português
  (`hélice=`, `perfil EH=`).
- aeroopt, registro e restrições: cada rodada grava `avaliacoes.csv` (cada ponto de projeto, em ordem, com as
  variáveis) e `configuracoes.csv` (nota fator por fator) em `rodadas_aeroopt/` (`aeroopt/export.py`; `--csv` na
  ferramenta). A janela roda sem conjunto guardado (o avião sai dos rascunhos), edita as restrições como Condições e
  restrições do aerosim e abre o avião escolhido no aerosim, com todas as análises.
- aeroopt, janela (O05): `python -m aeroopt [projeto] [problema]` (ou `--exemplo`). O `.toml` da pontuação inteiro em
  campos editáveis (conferir no núcleo, gravar), variáveis, categorias e opções das etapas; a rodada ao vivo, a cada
  candidato que termina uma etapa: andamento das etapas, MTOW de cada ponto avaliado, nota por configuração, mapa dos
  aviões (PV × carga paga com EE constante, cor pela nota) e o avião clicado em 3D com a nota fator por fator. O
  topo da bisseção do 6GDL fica perto do MTOW da pista (`study._mtow6(..., m_max)`, o padrão continua o de antes).
- aeroopt, categorias de configuração: asa alta, média, baixa, parasol, biplano, tandem, asa voadora e cauda em V
  (`aeroopt/categories.py`). As categorias escolhidas no problema viram um eixo das configurações do processo em
  etapas (`--categorias` na ferramenta).
- Corrida de decolagem da sprint no núcleo: a corrida do `power.performance` (o MTOW na pista e a curva corrida ×
  massa) roda em `core/src/sizing/ground.zig` (`aerosim_ground_runs`, `aerosim_ground_mtow`), bit a bit igual à
  conta em Python de antes. O ponto de projeto acoplado ficou umas cinco vezes mais rápido.
- aeroopt, processo em etapas (O13): configurações → superfícies acertadas pela decolagem → MTOW no 6GDL → nota no
  núcleo, com todos os candidatos esperando entre uma etapa e outra e cada etapa em paralelo (`aeroopt/pipeline.py`,
  `aeroopt/stages.py`, contrato `IStage` em `aerosim/interfaces/optim.py`). `tools/aeroopt.py --etapas --projeto`
  roda pela linha de comando. O mini-MDO continua como alternativa, igual.
- aeroopt, ferramenta (O04): `tools/aeroopt.py` roda um `.opt.json` pelo núcleo, imprime o melhor ponto, as grandezas e
  as restrições, grava a convergência (`--png`) e isola variáveis na hora (`--isolar asa`).
- aeroopt, nota no núcleo (O03): `core/src/optim` confere e executa o programa da pontuação, para um candidato ou
  muitos (`aerosim_expr_check`, `aerosim_expr_eval`; grupo de testes `test-optim`), e `core/src/math/linalg.zig` traz
  LU e Cholesky de tamanho fixo para os solvers. `aeroopt.scoring.evaluate` devolve nota, fatores e validade; as notas
  da Micro 2026 calculadas à mão batem com as do núcleo.
- aeroopt, pontuação por regulamento (O01): um `.toml` por ano em `aeroopt/pontuacao/`, traduzido para um programa de
  pilha que o núcleo vai executar (`aeroopt/scoring.py`). Primeiro arquivo: SAE BRASIL AeroDesign 2026, classe Micro
  (Regulamento Rev03, seção 9.8, eqs. 9.1 a 9.4, e as condições de voo válido como restrições).
- aeroopt, contratos e problema (O02): `aerosim/interfaces/optim.py` (`OptProblem`, `IScoring`, `IEvaluator`,
  `ISolver`), o arquivo `.opt.json` e a ponte com o projeto da sprint (`aeroopt/problem.py`). Uma variável só entra na
  busca quando está livre; `isolate` deixa livres só as variáveis ou os grupos citados. O mini-MDO do núcleo roda pelo
  contrato (`aeroopt/mini_mdo.py`) com o mesmo resultado da página MDO, bit a bit (`tests/aeroopt`).
- Tracking por segmento: o quadro de `docs/TRACKING.md` tem uma tabela para o aerosim, o core, o AeroDrive, o aeroopt
  (o otimizador, tarefas O01 a O12, à espera do ok do plano) e o que é comum. O VTOL saiu das Torres (T83).
- Asas ligadas, tandem e biplano (T78): grupo de asas no modelo, na Montagem e na sprint. O modificador
  `interferencia.asas` (T76, desligado por padrão) faz as faixas de uma asa sentirem a outra.
- Motores livres (T79): arranjo nariz + pares na asa + propulsora.
- Erros claros em vez de pane (T77, T80): o núcleo devolve sem trem, inércia inválida e divergência com texto (códigos
  −6 a −8), o `fmath` não entra em pane com NaN, e o AeroDrive mostra a mensagem na tela.
- Massa das superfícies simétricas em cada lado (T81), no aerosim e no AeroDrive.
- Ajuste da decolagem sem travar (T85): sessões emprestadas de um pool.

- READMEs com as equações (T75): cada pasta do `core` (`physics`, `sim`, `control`, `math`, `sizing`, `loads`,
  `modifiers`, `collision`) e do `aerosim` tem as equações em LaTeX, uma por parágrafo, com a fonte, e um exemplo em
  Python por arquivo, que roda. Os tempos de máquina e os números de um caso só saíram dos READMEs (ficam em
  `core/OTIMIZACOES.md` e nos testes).
- Núcleo: enums no lugar dos bits. `core/src/opt.zig` (`Opt`) dá nome a cada bit do `-Dopt`, e o `build.zig` recusa um
  nome que não existe. Nos modificadores, `Ground`, `Kind` e `SlipstreamParam` dizem o que cada número seleciona. Os
  campos da ABI continuam `i32`, então o esquema e os `.cfg` não mudam.
- Aba Aerodinâmica com a linha sustentadora do núcleo (T67): `CoreLLTSolver` (`aerosim/aero/llt_solver.py`) em
  `all_solvers`, com duas variantes, `zig_llt` (Phillips e Snyder) e `zig_llt_gh` (Goates e Hunsaker). Liga em
  "comparar: linha sustentadora do núcleo"; desligado por padrão. As superfícies são refinadas
  (`span_loads.refine_all`, com os painéis por semiasa da aba). Os `nucleo_llt` e `nucleo_gh` de `tools/aero` passam a
  ser essa classe, com o mesmo resultado (o teste contra o MachUpX continua passando).
- Linha sustentadora mais rápida: a geometria fixa (nós, juntas de Goates e Hunsaker, segmentos ligados) é montada uma
  vez por configuração (`llt.prepare`, `Params.llt_cache`), e a cada avaliação só as pernas livres são calculadas.
  O resultado é bit a bit igual (teste em Zig). A decolagem com o `llt_gh` caiu de 107 para 10 s e com o `llt`, de
  21 para 12 s, na mesma máquina. Na missão de 165 s, em sequência: faixas 4 s, faixas refinadas 17 s, `llt` 261 s,
  `llt_gh` 258 s; os 9 modelos, 9 min 37 s (5 min 15 s em paralelo), contra mais de 1 h antes.
- `tools/aero/missao.py`: os voos rodam em paralelo (`--jobs`), e as tabelas de voo passam pelo cache de polares
  (`aerosim/aero/service.py`). O gráfico de tempo separa preparar de voar.
- Documentação: `tools/README.md` (índice das ferramentas, os três mapas de proximidade com os comandos, tempo de conta
  por modelo) e `core/OTIMIZACOES.md` (o que deixou a linha sustentadora rápida e o que se mediu).
- Correção: o lltdrek não ia para o cache em disco, porque o `cost = "caro"` estava no tradutor e não no solver.
- Voar com outro modelo aerodinâmico, fase B (T65): `Params.aero_model` escolhe o modelo da dinâmica, da trimagem e da
  linearização (`core/src/physics/aeromodel.zig`): 0 = faixas (o padrão: bit a bit igual, o AeroDrive não muda),
  1 = linha sustentadora (Phillips e Snyder ou Goates e Hunsaker), 2 = tabela do avião inteiro de qualquer método
  (`physics/aerotable.zig`; montada por `aerosim/aero/flight_table.py` com AVL, VLM, lltdrek...). No Python,
  `ac.sim.aero_model` e `ac.sim.aero_table`. `tools/aero/missao.py` voa a decolagem ou a missão com cada modelo e
  sobrepõe as curvas e o resumo da GUI (figuras em `docs/img/aero_*_modelos.png`).
- Decolagem com outro modelo, fase A (T65): `tools/aero/decolagem.py` roda a decolagem com o modelo de sempre e
  reavalia cada ponto com todos os métodos (núcleo, linha sustentadora, lltdrek, ASB, AVL) no mesmo estado: erro de
  cada coeficiente no tempo, RMS e máximo, em força (% do peso) e momento. `--puro` tira as sobrescritas e a fuselagem
  para todos verem o mesmo avião. Núcleo: `aerosim_aero_coeffs_llt` (os coeficientes do avião com as forças dos
  painéis pela linha sustentadora, com taxas, altura e tração); a simulação e o AeroDrive não mudam.
- Linha sustentadora de Goates e Hunsaker (T64; Goates e Hunsaker, AIAA SciTech 2021): a de Phillips e Snyder não
  converge com a malha em derrapagem nem com enflechamento (o C_lβ da asa plana crescia com o log da malha; o C_Lα da
  enflechada não parava). Três correções no `core/src/loads/llt.zig`, ligadas por `Params.llt_joint` e `llt_blend`
  (0 por padrão: tudo igual): junta das pernas, linha efetiva por ponto de controle e seção normal à linha. Contra o
  MachUpX (a implementação dos autores): C_Lα a 1,5 % e C_lβ a 3 % em quatro asas. Método novo na aba Cargas
  ("linha sustentadora (Goates e Hunsaker)", `llt_gh`) e no `tools/aero` (`nucleo_gh`).
- `tools/aero`: todas as superfícies são refinadas (antes só a asa; a EV sozinha saía com 2× o C_Yβ); figuras e matriz
  refeitas com o método novo.
- `tools/aero` (T63): perfis de teste dos coeficientes, só superfícies, a 12 m/s. Métodos: núcleo (malha da simulação
  e refinada), núcleo com efeito solo (McCormick a h/b = 0,25 e 0,10), linha sustentadora do núcleo, lltdrek, VLM e
  buildup do ASB, AVL. Distância até qualquer método ou CSV de fora (`--ref`), matriz entre os métodos (`--matriz`),
  coeficientes e superfícies escolhidos (`--coef`, `--so asa,eh,ev`), malha e varredura (`--paineis`,
  `--varrer paineis=...` ou `V=...`), perfil por .dat (`--perfil`). Figuras em `docs/img/aero_*.png`, README com as
  causas das diferenças (malha da simulação, Helmbold, Oswald fixo, faixas nas taxas, C_mq da linha sustentadora).
- Núcleo: `aerosim_aero_coeffs_at` (coeficientes com a altura sobre o chão, para o efeito solo); o resto igual.
- Tracking: T63, T64 (linha sustentadora do núcleo com β).
- Hélice no chão (T56): a falha "hélice tocou o chão" fica desligada por padrão (`ac.sim.prop_strike = False`,
  `Params.prop_strike = 0`): ligada, o exemplo `flying_wing` (pá 5,5 cm dentro do chão parado) não voava. A folga
  (`hprop`, `hpmin`) continua no registro.
- Desempenho → "Voo nivelado e envelopes" (T42): o envelope ganha aba; planilha e modelo completo sobrepostos
  (só com "os dois") ou cada um sozinho; o V-n sai daqui (vai para Cargas). Modelo completo: opção "abaixo do
  estol" (núcleo, desligada por padrão no `EnvCfg`) que continua a curva com a polar sem estol para achar o V_min
  de potência; V mínimo voável = max(V_min, V_e). Ângulo de cruzeiro vem do avião e pode ser mudado na aba;
  gráfico α de equilíbrio × V com o ângulo e o V_cru de cada método; diagnóstico do V_cru com o motivo e a faixa
  de α do envelope. Exportar ignora séries só de estilo.
- `docs/AREAS.md`: mapa das áreas e submódulos, com as duplicações encontradas; Desempenho por etapa de voo.
- Aba Cargas (T12): a carga ao longo de cada superfície num ponto de voo (V, n, α da trimagem ou imposto), com e
  sem a hélice do conjunto motopropulsor do avião, pela linha sustentadora (`core/src/loads/llt.zig`) ou pelas
  faixas da simulação. Gráficos de L', α efetivo e V/V∞ por superfície e a vista 3D (`LoadView`) dentro da aba
  (tipo de gráfico `loads3d`). Diagnóstico: trimagem, soma das cargas × n·peso e esteira desligada.
- Tracking: regras (norma e restrição só por preset do usuário; conta no núcleo; cargas é análise tardia), o fluxo
  de projeto e as tarefas T37 a T41.
- `.claude/CLAUDE.md`: seção do ambiente (o que instalar e problemas conhecidos).
- Missão: fator de carga nas curvas (T06). O gráfico "Fator de carga" mostra, junto do n_z, o n que a inclinação
  pede (curva nivelada, 1/cos φ), o n em que a asa estola na V do momento (n_z C_Lmax/C_L) e o n estrutural; os
  instantes com C_L = C_Lmax ficam marcados. Só em voo (Anderson, Introduction to Flight, §6.17).
- Missão, análise "curvas: raio mínimo": gráfico novo "Curvas: fator de carga no tempo" (n_z e n no estol por raio)
  e o n no estol em regime no "Fator de carga × raio"; coluna `n_estol_perm` nos casos.
- `docs/TRACKING.md`: tira as linhas duplicadas AE-08 a AE-10; versão da `main` em dia (`v0.2.2`); os ❓ que
  sobraram conferidos no código (EC-08, EC-09 e EC-16 ✅; IN-08 ❌; DE-02 sem tarefa); progresso medido na `main`.

## v0.2.2 — PR #27

- `.claude/CLAUDE.md`: guia de desenvolvimento (objetivo, conceitos, decisões de projeto, fluxo de git e versões,
  métricas, comandos).
- `tools/codemap.py` → `docs/MAP.md`: mapa do código gerado; check "mapa do código em dia" em `tools/checks`.

## v0.2.1 — PR #26

- Missão: passeio do CG e margem estática ao longo do voo (T04).
- Tracking: versão por tarefa (`0.2.x`) até a lista inteira virar `0.3.0`; elétrica fora do escopo; branch única
  `0.2_dev`.

## v0.2.0 — fundação fechada (PRs #24–#25)

- `tools/checks`: checks de regressão (núcleo Zig, AeroDrive, exemplos bit a bit contra uma referência, testes por
  área).
- `docs/TRACKING.md`: castelo, milestones, quadro de tarefas com dependências; T01 conferido.

## v0.1.x — pilha de branches mesclada (PRs #21–#23)

**Projeto**
- Sprint por asa, em pasta.
- Montagem sem exigir decolagem.
- Tração e Missão dentro de Desempenho.
- xCG em % CMA.
- Biblioteca de perfis disponível de saída.

**Aerodinâmica**
- Camada 2D de polares com cache.
- Cache 3D.
- AVL e importação do XFLR5.

**Modifiers**
- Efeito solo (McCormick) e esteira da hélice por disco atuador, ligáveis por avião e desligados por padrão.

**Colisão**
- Tubo da hélice contra superfícies e objetos.

**Cargas**
- Distribuição ao longo da envergadura pela linha sustentadora (Phillips e Snyder 2000), com e sem hélice.
- Vista 3D no modelo da GUI.

**Núcleo**
- Hash da ABI conferido ao carregar.

## v0.1.0 — ponto de partida (`main` em `033bdc1`)

Primeira versão rastreada. É a `main` depois dos PRs 11, 12 e 13.
- Simulação 6GDL e GUI com Aerodinâmica, Desempenho, Estabilidade e Montagem.
- AeroDrive.
- Projeto do zero (sprint).

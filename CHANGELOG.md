# Changelog

Versões da `main`. A regra de versão está em `docs/TRACKING.md` → Versões.

## Não lançado

### v0.2.4 (`main`, fechada em 2026-10-30)

- interface do aerosim em Zig igual à GUI PyQt, com os managers em Python: as áreas e as subabas vêm do Python na
  mesma arrumação (`aerosim/bridge.py`, pedido "layout"), e cada subaba é uma página genérica (`aerosim/gui/page.zig`):
  as análises `ISimulation` (Analisar, Estabilidade, Desempenho, Tração, Missão, Cargas...) e as etapas da sprint
  (Perfis, Projetar, Empenagem e comandos, Motores e montagem, "Condições e restrições…"), com Guardar, os guardados,
  os botões da etapa e as tabelas de massa e dimensões. As etapas sem Qt ficam em `aerosim/manager/stages.py`, o
  formulário de dataclass em `aerosim/manager/forms.py` e os rótulos em `aerosim/manager/form_meta.py` (a GUI PyQt lê
  os mesmos). A ponte atende várias abas ao mesmo tempo (cada pedido na sua thread, respostas por número). Saem as
  abas reescritas à mão em Zig (Perfis, Projetar, Analisar e as contas delas) e a aba "Pelo Python". Falta: Mini-MDO,
  Estudo, tabelas editáveis, campos de arquivo, vistas 3D e a ponte no navegador.
- aerosim e aeroopt em Zig no navegador, para teste: os dois compilam para wasm (`-Dtarget=wasm32-emscripten`), com
  os aviões de exemplo, os perfis de `data/airfoils` e as fontes no pacote; "abrir do computador" ou arrastar o
  arquivo para a página, e salvar baixa o arquivo. `tools/web_build.py` e o workflow do site publicam os três
  programas, e a tela inicial abre cada um. No navegador as contas longas param a página até acabar.
- Montagem em Zig: o CG aparece no 3D (cruz e rótulo com x e massa; o vazio em cinza quando a carga o desloca).
- interface em Zig: as contas longas (a varredura de Analisar, abrir o `.json`) rodam numa thread e a tela segue
  respondendo; o build da raiz compila em ReleaseSafe. A barra lateral rola inteira (roda ou barra de arrastar) e o
  que rolou para fora não pega mais o clique; o menu "polar por" abre por cima do rodapé; caixas de marcar e setas
  desenhadas; Esc fecha a janela de cima, não o programa. Projetar mostra a asa em 3D primeiro, guarda asas e as
  compara nos gráficos. Todo gráfico liga e desliga curvas pela legenda e, no botão direito, exporta PNG, PDF ou o
  CSV das curvas marcadas; as tabelas de números exportam CSV com uma grandeza por linha.
- Projetar igual à etapa Asa da GUI em Python: barra de requisitos, título com ajuda, nome, planta trapézio ou
  tabela de seções (partições com perfil próprio, "+ partição", "− partição", "do trapézio"), diedro, campos
  desligados pelo modo, ponto neutro no 3D, diagnóstico com as restrições ativas e os resultados. A janela
  "Condições e restrições…" (Condições, Restrições, Variáveis, Regras de projeto) vale para Perfis e Projetar. No
  núcleo, `wing_line` aceita a tabela de partições (`planformOfPartitions`, `analyzePlanform`, `totals`,
  `partitionsFromTrapezoid`, `Planform.aeroCenter`), com teste contra o Python. Peças reutilizáveis: `ui/stage.zig`,
  `ui/table.zig`, `ui/checks.zig`, dica com o mouse parado (`Ui.tooltip`); a lista de escolha não fecha mais no
  clique que a abre e o cursor de edição começa no fim do texto.
- pacote para instalar: `launcher/` (a tela inicial do site, em Zig, que abre o aerosim, o aeroopt e o AeroDrive),
  `tools/package.py` (AppImage e instalador `.exe` com NSIS, com os exemplos, os perfis e a página do site) e o
  workflow `pacotes` (só quando alguém pede ou numa tag).

- compilar e rodar da raiz: `zig build aerosim`, `aeroopt`, `aerodrive`, `zig build` (os três) e `zig build test`
  (`build.zig` na raiz chama o build de cada pasta). O código Zig das interfaces passa para a pasta do módulo, junto
  do Python: `aerosim/gui/` (com `aerosim/build.zig`) e `aeroopt/` (com `aeroopt/build.zig`).
- interface em Zig (W7, começo): `aerosim/gui/` (com as peças comuns em `gui/ui`) e `aeroopt/`, com
  raylib e raygui, no visual do AeroDrive (fundo claro, cantos arredondados, azul nos títulos). A Montagem mostra o avião
  inteiro em 3D pelo modelo do AeroDrive. O formulário
  lateral sai de uma lista de campos, e o gráfico tem marcas redondas, legenda e a paleta de dez cores. No aerosim,
  Aerodinâmica → Analisar roda a varredura do núcleo no avião aberto (linha sustentadora não linear e
  faixas), com a escolha das superfícies e o refino da GUI em Python, e os mesmos números. Aerodinâmica → Perfis no formato
  da GUI em Python: a lista de candidatos do projeto (NACA 2412 e 4412 no começo) com "+ NACA", "+ .dat", "+ só
  parâmetros", "+ polar XFLR5" e "Remover", o menu "polar por" com um ou mais métodos (cada um uma curva) e o
  botão Rodar, o seletor de arquivo dentro da janela (abrir e salvar, com a pasta digitada e os atalhos Exemplos,
  pessoal, atual e raiz; o mesmo de
  "Abrir avião" e "Salvar .json" do cabeçalho), o editor do selecionado e "Usar
  na asa", com a polar 2D e os números no núcleo (`core/src/physics/section.zig`, novo, iguais à GUI em Python). Aerodinâmica → Projetar: a asa
  trapezoidal pela linha sustentadora de Glauert no núcleo (`core/src/sizing/wing_line.zig`, novo, igual à etapa
  Asa em Python), com perfil na ponta, polar, L/D, onde o estol começa e o cruzeiro. O aeroopt mostra uma rodada de exemplo. A vista da asa tem o 3D com um vetor de carga por painel e a vista de cima. O AeroDrive passa a
  preencher o quarto de corda dos painéis (`qa`/`qb`), que a linha sustentadora usa. O
  `tools/codemap.py` passa a mapear as duas pastas.
- tracking: meta da 1.0 (tudo no navegador, sem instalar nada; o Python em WebAssembly fica para a 1.1) e o quadro
  em dia com a `main` (os itens "a revisar" que já foram no PR #31 passam a "Feito (na `main`)").
- tracking: seção "Ordem de prioridade" com a fila atual.
- AeroDrive no navegador (W1 a W4 da meta da 1.0). `zig build -Dtarget=wasm32-emscripten` gera `aerodrive.html`,
  `.js`, `.wasm` e `.data` (aviões de exemplo e uma fonte livre embutidos) em `aerodrive/zig-out/web`. Os arquivos
  passam por uma interface de armazenamento (`app/storage.zig`): disco no programa instalado, IndexedDB no navegador.
  "Abrir arquivo do computador..." lê um `.json` pelo seletor ou arrastando para a página (no programa instalado,
  arrastando para a janela); o avião fica guardado no navegador e "Exportar" baixa o `.json`. No celular aparecem dois
  manches virtuais (motor e leme; arfagem e rolagem) e os botões de pausa e câmera. O nativo continua igual, e o
  núcleo só ganhou um índice em `usize` para compilar em 32 bits (regressão bit a bit igual).
- site: tela inicial estilo BIOS (`web/index.html`) que abre o AeroDrive (aerosim e aeroopt "em breve") e carrega um
  `.json`; `tools/web_build.py` monta `zig-out/site/`; o workflow `.github/workflows/site.yml` publica no GitHub
  Pages a cada push na `main`.
- AeroDrive no navegador sem os travamentos grandes: entrar em Aeronave caiu de ~4 s para ~40 ms (o
  `emscripten_return_address` passa a responder 0, em vez de montar um rastro da pilha do JS a cada alocação do Zig),
  e Decolar de ~3,7 s para ~0,5 s, com o quadro de voo de ~7,7 ms para ~2,2 ms (`fmath.mulAdd`: no WebAssembly, que
  não tem fma, a conta comum no lugar do fma em software). O nativo sai bit a bit igual.
- AeroDrive no navegador grava vídeo: o G (ou "Gravar" na pausa) liga o MediaRecorder da página junto com os dados.
  Sai .mp4 (Chrome, Edge e Safari recentes) ou .webm (Firefox). No Chrome e no Edge do PC a página pergunta onde
  salvar ao começar e grava direto no arquivo; nos outros, o vídeo é baixado ao parar.
- CI: `.github/workflows/testes.yml` roda os checks de `tools/checks` (`run.py --tudo`) a cada PR para a `main` (uma
  rodada por commit), em três partes paralelas (núcleo e AeroDrive, regressão bit a bit, testes Python), e deixa
  o relatório de cada parte como artefato na aba Actions.
- cargas (T55): linha sustentadora não linear (`Params.llt_nonlinear`; método "linha sustentadora não linear (estol
  por perfil)", `llt_nl`, na aba Cargas, no `tools/span_load.py` e como `ac.sim.aero_model`). Cada faixa segue a curva
  do seu perfil com estol, e o sistema de Phillips e Snyder é resolvido por Newton a partir da solução linear. Mostra
  onde o estol começa e para quanto a carga satura. Depois do estol, viscosidade artificial (Chattot) e continuação em
  pseudo-tempo deixam a carga suave e convergida. Desligada por padrão: o voo e o AeroDrive ficam iguais.
- aerodinâmica (T89): subaba Asas, a simulação de aerodinâmica completa de um conjunto de asas (uma asa, biplano,
  tandem, canard), sem trimar, sem fuselagem e sem hélice, como no túnel. Roda com o avião da Montagem ou com as asas
  guardadas na sprint, mesmo sem fuselagem e sem massa. Mostra o C_L do conjunto e de cada superfície em α, o C_L
  máximo, onde o estol começa, a carga ao longo da envergadura, a vista 3D e de cima do que se simula, o Reynolds de
  cada superfície e as polares de todos os métodos do Avião montado nas superfícies escolhidas. Chapas de ponta
  opcionais. A varredura em α é do núcleo (`core/src/loads/sweep.zig`), numa chamada, igual ao laço em Python e cerca
  de dez vezes mais rápida.
- aerodinâmica: a subaba Avião montado saiu. A Asas faz também a análise do avião completo (polares no CG, profundor e
  derrapagem, estol × cruzeiro, L/D, pontas de asa) quando o avião aberto está pronto, e a polar continua indo para o
  Desempenho.
- aerodinâmica: as subabas passam a se chamar Perfis, Projetar (a etapa da asa) e Analisar (a antiga Asas).
- celular: no primeiro toque a página vai para a tela cheia e trava deitada; em pé aparece "gire o celular"; o jogo
  acompanha o tamanho da página (tela cheia, barra do navegador, giro).
- celular, segunda rodada (testada pelo vitor num Galaxy): o jogo desenha numa área de no mínimo 640 px de altura e
  estica para a tela (antes os menus saíam cortados); tocar nos menus vale como clique; o rodapé das teclas dá lugar a
  um botão "← voltar"; no voo, painel de dados compacto, minimapa menor e os botões "modo" e "LAPES" ao lado de pausa
  e câmera; o link "◄ início" some depois do primeiro toque.

### v0.2.3 (`main`, PR #31)

- núcleo, legibilidade (T87, revisão do vitor). Os erros da ABI viram um `error{...}` (`AbiError`), e o número negativo
  só aparece na fronteira, em `abiCode`. Os arquivos `tests_*.zig` por grupo dão lugar a `zig build test -Dgrupo=math`
  (ou physics, sim...) e `-Dfiltro=<nome>`. Em todo `core/src`, os nomes de uma letra (imports `L`, `S`, `fm`;
  parâmetros e variáveis `c`, `n`, `e`, `V`...) viram nomes que dizem o que são. Os índices do vetor de estados viram
  o `enum` `state.Entry` (`state.index(.pitch)`), e toda `pub fn` e `export fn` ganha um `///`. A biblioteca sai igual
  bit a bit, e o AeroDrive compila e passa nos testes. A regra está no `.claude/CLAUDE.md` (decisão 11).

- aeroopt e core/optim, README com figuras: no aeroopt, "Como se divide" (o PNG dos módulos) vem antes de "Como
  funciona" (o fluxo dos blocos e uma figura por bloco, com dados reais: a rotação na pista, as regras de Deb e a
  violação até voar, onde caem os pontos de cada busca, a bisseção na massa, a nota e as gerações). No core/optim,
  cada busca ganhou o seu desenho (GA, CMA-ES, DE, hipercubo latino, busca guiada, substituto RBF e modelo local).

- aeroopt, GA com substituto (O36, passo 2): a busca "substituto" das superfícies. A cada geração o GA do núcleo
  sorteia 16 vezes mais filhos que a população, um substituto RBF cúbico com cauda linear (`core/src/optim/rbf.zig`,
  Gutmann 2001; Regis e Shoemaker 2007) do MTOW e outro da violação dão o palpite de cada um, e só os de melhor
  palpite (mais um sorteado) são avaliados. No banco, com 6 contínuas e 48 pontos, a mediana de 7 sementes foi 94 %
  do ótimo na tigela, 98 % na acoplada e 88 % na multimodal (o GA puro: 78, 91 e 71 %): a melhor busca nas duas
  formas difíceis. Os métodos de antes ficam iguais.

- aeroopt, banco dos otimizadores (`tools/banco_otimizadores.py`, O36): compara as buscas das superfícies e da
  etapa voa nos dados de teste, em três formas de problema (`synthetic.SHAPES`: tigela, acoplada e multimodal, com
  o mesmo ótimo). Linha de base com 6 contínuas e 48 pontos: ninguém chega a 99 % do ótimo; as coordenadas ganham
  na tigela e na multimodal, o CMA-ES na acoplada, e o GA puro perde nas três. A busca das superfícies ganhou
  `SurfaceSizing.seed` (0: a de sempre).

- decolagem, proteções obrigatórias (vitor: "se não faz sentido não pode acontecer"). A proteção de α na decolagem
  deixa de ser opção (sai `takeoff.alpha_guard` do avião e `power.alpha_guard` do dimensionamento; arquivos antigos
  carregam iguais), e o limite dela passa a ser o estol de cada avião: o α em que a superfície mais carregada chega a
  0,95 do C_Lmax, calculado pelo núcleo no `configure`, no lugar dos 11° fixos. A busca da decolagem reprova a que
  estola (C_L/C_Lmax ≥ 1 até h_end), que conta como "acionou cedo demais". O aeroopt deixa de rodar o 6GDL com e sem
  a proteção. **Muda o resultado das decolagens e dos exemplos**: sem isso, 5 de 6 tandens da grade estolavam e caíam
  logo depois de sair do chão; com isso, os 6 chegam ao fim da manobra 1.

- tandem: as duas asas deixam de ser iguais. A área da asa de trás sobre a da frente (`wing2_area`) e o perfil dela
  (`wing2_airfoil`) são campos novos (1 e vazio: o de sempre). A E&C do tandem confere a divisão da sustentação no
  cruzeiro (40 a 60 % na asa da frente, pelo núcleo), o recuo de 3 a 5 cordas e o desnível até 1 corda (O31).
- aeroopt, janela: "configurações por geração" passa a se chamar "indivíduos".
- decolagem 6GDL: tolerância da bisseção do acionamento (`tolerancia`, % do x_warning; 0 = a de sempre), na aba
  Missão e na Configuração do aeroopt. Com 1 %, o MTOW do monoplano da Regular 2026 cai de 730 s para 157 s
  (15,42 → 15,36 kg).
- tandem: a E&C confere a divisão da sustentação no cruzeiro e na velocidade de sair do chão (ela muda com a
  velocidade: o C_m do perfil pesa mais quanto maior o q).
- aeroopt, janela: sai o gráfico e a coluna do MTOW na pista (a conta da sprint não é o que pontua); ficam a nota e o
  MTOW do 6GDL.
- aeroopt, janela: os submenus rolam e o regulamento fica fixo no alto da Pontuação; numa tela de 1366 × 768 o
  combo e o OK ficavam fora da tela. A Configuração ganhou o início (uniforme ou hipercubo latino) e as partidas da
  E&C, que antes só se mudavam no `.opt.json`.
- aeroopt, E&C: busca guiada pela falha. Cada termo da violação tem um código, e o diagnóstico liga o código às
  variáveis que o consertam; métodos novos da etapa voa: reparo por gradiente, εDE, algoritmo cultural, LEM e
  diagnóstico (um bandido escolhe o operador de cada filho). As contas no núcleo (`core/src/optim/guided.zig`).
  `tools/metodos_voa.py` compara os métodos. O padrão continua "gerações" (O30).
- aeroopt: a E&C com os comandos liga a estabilidade dinâmica (modos do núcleo contra a MIL-F-8785C); o tandem da Regular 2026
  era instável em guinada e caía logo depois de decolar, e a sprint não via. A deriva da ponta vai até 0,5 m (O28).
- decolagem: busca do ponto de acionamento por bisseção a partir da corrida sem acionar (opção `busca`; o 6GDL do aeroopt
  usa) (O29).
- sprint e aeroopt: a posição da carga paga (`power.x_payload`, do CG de projeto) é variável, e a E&C a escolhe junto com
  os comandos; a bateria equilibra junto e a margem sem a carga é conferida (O27). Com 0, a montagem de sempre.
- sprint: o tandem com deriva na ponta achava a asa de trás pelo fim da lista e lia a deriva como asa (ponto neutro na asa
  da frente, lastro de ~1 kg, nunca voava na E&C). Agora a segunda asa se acha pelo papel (`tail.second_wing`).
- aeroopt, E&C: população inicial por hipercubo latino (`core/src/optim/sampling.zig`, maximin; `etapas.inicio =
  "lhs"`) e multi-start (`etapas.partidas = k`: k pontos que voam, afastados, e fica o de maior carga paga na pista).
  Os dois desligados por padrão. `tools/sementes.py` roda a mesma configuração com sementes diferentes e mostra se
  caem no mesmo avião.

- sprint, tandem: a asa de trás agora é tratada como a cauda. O ponto neutro sai das duas asas (a média dos CA
  ponderada por a S, com η e o downwash da da frente). Antes era o da asa da frente sozinha, o CG ia para perto dela
  e o tandem não trimava em α nenhum. O profundor fica na asa de trás e a da frente só tem aileron: um elevon na da
  frente, à frente do CG, cabrava quando descia. A asa de trás sente o downwash, um tubo a liga à fuselagem e o pod
  vai até o CG, onde ficam a carga e a bateria. Na E&C com os comandos, o tandem tem os comandos dele: decalagem e
  recuo da asa de trás, margem estática, trecho e corda do profundor, atitude no chão e trem. Muda só o tandem.
- sprint e E&C, saída do chão sem rodar (atitude no chão): no avião sem cauda só conta o C_L que o comando ainda
  trima. Antes a sprint usava o C_L da asa sem trimagem (1,7 no tandem, que trimado dá 0,77) e achava que o avião saía
  do chão sozinho; no 6GDL ele picava de volta para a bequilha e não decolava.
- E&C (etapa voa com os comandos) confere duas coisas que antes só apareciam no 6GDL: o peso mínimo na bequilha
  parado (8 %, Raymer §11.2; com menos o avião senta para trás na corrida) e a estabilidade direcional (C_nβ; um
  avião sem cauda e sem deriva não tem nenhuma).
- sprint, deriva na ponta da asa (`tail.tip_fin`, 0 por padrão): uma superfície vertical com leme em cada ponta da
  asa sem cauda, que também trabalha como placa de ponta. É ela que dá o C_nβ da asa voadora e do tandem. No tandem
  ela vai na asa de trás (`tail.tip_fin_where`), porque a ponta da da frente fica quase no CG, sem braço.
- aeroopt, arfagem do tandem (`tail.tandem_pitch`): o comando de arfagem na asa de trás (profundor), na da frente
  (elevon que desce para cabrar, como um canard) ou nas duas. A E&C escolhe entre as três, como escolhe a cauda.
- núcleo, proteção de α na decolagem (`takeoff.alpha_guard`, desligada por padrão; obrigatória desde a v0.2.3): enquanto o piloto automático não
  assume, o profundor não deixa α passar do limite dele. Sem ela, a asa voadora leve e com muita tração cabra até
  estolar com o comando fixo (de 32° para 11° de α no teste do núcleo). A etapa do 6GDL do aeroopt roda com e sem e
  fica com o maior MTOW. As decolagens de hoje ficam iguais.
- sprint, ponto de projeto: quando a média de sempre acaba as voltas sem convergir (o MTOW sobe quase tanto quanto a
  massa de projeto, como no tandem e na asa voadora), segue por secante. Quem já convergia fica igual.
- sprint, altura do obstáculo (`requirements.obstacle_h`, 1 m por padrão, que era o fixo de antes): é o z_warning da
  decolagem 6GDL. A Regular 2026 pede 0,90 m a 55 m (R[7.8.0.1]).

- aeroopt, pontuação da Regular 2026 (`pontuacao/sae_br_2026_regular.toml`): P_EE = 50 EE e a nota de voo da eq.
  7.5, com o fator do número de superfícies longitudinais N (`stages.n_surfaces`: asa voadora 1, monoplano e tandem
  2, biplano 3), o fator de envergadura 1,15^(−b), o MTOW de 20 kg e a penalidade de envergadura acima de 4 m. O
  voo vale se passar o obstáculo a 55 m. A penalidade de potência acima de 600 W fica de fora: o avaliador ainda
  não entrega a potência de pico.

- asa voadora na E&C: com "comandos (E&C)", a asa voadora parte de uma asa enflechada com torção para baixo. Ela
  ganha perfil simétrico na ponta (onde fica o elevon), hélice propulsora e o momento próprio dos comandos, e a busca
  mexe também em margem estática, enflechamento, torção, afilamento, atitude no chão e posição do trem. A E&C confere
  no núcleo: o maior C_L trimado contra a velocidade de estol pedida, o elevon picando segurando o nariz com o motor
  cheio e a asa correndo longe do estol. O exemplo usa o S1223 na asa (`example_project(airfoil)` troca).
- sprint, atitude no chão (`power.ground_pitch`, 0 por padrão): a bequilha mais comprida deixa a asa correndo num
  ângulo, e a corrida do núcleo (`GroundRun.lift_off`) sai do chão sem rodar quando a sustentação vence o peso. A
  pista da asa voadora usa o C_L trimado (`power.trimmed_clmax`). 6GDL: com a bequilha mais comprida, a decolagem
  começa parada na atitude do trem; antes começava nivelada, a bequilha entrava no chão e o avião capotava. Os
  trens nivelados ficam iguais.

- sprint, elevon da asa voadora (O16): a sustentação do elevon ia toda a 3/4 da corda e dava uns 4 vezes o C_mδ do
  núcleo. Agora vai no quarto de corda da faixa, mais o momento próprio do flape do perfil fino. Muda só a cauda
  "sem cauda". Núcleo: o modificador novo `comando.momento_flape` (`core/src/modifiers/flapmoment.zig`) soma esse
  momento em cada faixa com comando. Ele fica desligado por padrão, e o `tail.flap_moment` da Empenagem liga; a E&C
  com os comandos liga sozinha. Com ele, sprint e núcleo dão −0,69 e −0,73 /rad no mesmo avião.

- aeroopt, comandos em E&C: com "comandos (E&C)" marcado na Configuração (`params["etapas"]["comandos"]`), a etapa
  voa também mexe nos comandos do tipo de avião (profundor; ou trecho e corda do elevon; curso para cabrar e
  inclinação do motor), e o comando tem de rodar o avião antes de sair do chão. Essa conta usa o C_m e o C_L do
  núcleo (`stages.core_rotation`), porque a conta analítica da sprint dá ao elevon da asa voadora uns 4 a 5 vezes o
  C_mδ do núcleo e passava aviões que batem no 6GDL. Desligado por padrão. Ferramenta nova `tools/rotacao.py`:
  a rotação pelas duas contas, termo a termo. As suspeitas viraram os itens O16 a O20 do tracking.

- aeroopt, a cauda é escolhida em E&C: a etapa voa (estabilidade e controle) testa as caudas marcadas na
  Configuração (convencional, em H, em V, sem cauda) na asa de cada configuração e fica com a que voa; entre as que
  voam, a que decola na pista com a maior carga paga (um ponto de projeto por cauda). O indivíduo passa a ter essa cauda (`values["tail.layout"]`), e as etapas seguintes a usam.
  "cauda em V" saiu dos tipos de avião (continua valendo nos `.opt.json` gravados, que mostram os nomes antigos e
  rodam iguais). Desligada por padrão; o exemplo da janela liga as quatro. `params["etapas"]["caudas"]`.
- sprint, cauda em H: a EH da convencional com a EV repartida em duas iguais, uma em cada ponta da EH
  (`tail.LAYOUTS`, opção nova; as outras caudas não mudam).

- aeroopt, menus: cada opção da Configuração e das Restrições ganhou um "(?)" com a explicação (no mouse ou no
  clique), e os campos de número perderam o texto ("10.00 % da faixa" virou "10.00" no campo "passo (% da faixa)").
  Os tipos de avião saíram do submenu Categorias e foram para a Configuração ("aviões"). Asa alta, média, baixa e
  parasol viraram um "monoplano" só, com a asa alta; a altura sai da variável "altura da asa" quando ela está livre.
  Os nomes antigos continuam valendo nos `.opt.json` gravados e rodam iguais.

- aeroopt, evolução diferencial: mais um método das superfícies e da etapa voa, no núcleo (`core/src/optim/de.zig`,
  DE/rand/1/bin de Storn e Price, F = 0,5, CR = 0,9; `aerosim_de_init`, `aerosim_de_trials`, `aerosim_de_select`).
  O passo sai das diferenças entre os aviões da população, então encolhe sozinho perto do ótimo. Nos dados de
  teste, com 24 pontos, chega a 99,7 % da nota sabida, como as gerações; numa elipse girada (variáveis acopladas)
  fica mais perto do máximo que as gerações com o mesmo total.
- aeroopt, caminho da busca: coordenadas paralelas (`aeroopt/pcoords.py`), uma linha por avião passando por um eixo
  por variável livre e pelo MTOW, o PV e a nota, com a cor pela geração e o caminho do melhor até ali em preto. Fica
  na janela, embaixo do mapa, e o botão "Exportar HTML…" grava a mesma figura numa página que abre sem internet, com
  o controle "até a geração" e o avião embaixo do mouse.
- aeroopt, sensibilidade sozinha e curvas: o botão "Sensibilidade deste avião" roda só a sensibilidade do avião
  selecionado, com o método do menu, numa aba própria. A aba ganha um gráfico por variável (a nota pelo modelo, os
  pontos avaliados no eixo e a faixa da tolerância) e um por limite do problema. O menu Configuração perdeu a
  numeração das etapas e as caixas sem opção (geometria e nota).
- aeroopt, sensibilidade com menu e três métodos: no menu Configuração, "7. sensibilidade do melhor" liga a análise e
  escolhe o método (modelo local, um por vez ou Morris), o passo, a tolerância de fabricação, as trajetórias e os
  limites do problema; tudo vai no `.opt.json` (`params["sensibilidade"]`). No núcleo, `core/src/optim/sensmethods.zig`
  dá a perda por tolerância pelos dois primeiros momentos (`aerosim_sens_tolerance`) e as trajetórias e os efeitos
  elementares de Morris (`aerosim_morris_design`, `aerosim_morris_effects`). Com os limites ligados, o melhor é refeito
  com a pista e cada restrição ligada ±5 %, e sai ∂nota/∂L. Tudo aparece no mesmo tornado da aba Sensibilidade. Os
  menus mostram só o nome de cada método; a explicação passou para a dica do mouse. Na ferramenta,
  `--sensibilidade [local|eixos|morris] --tolerancia --limites`.
- aeroopt, sensibilidade do melhor (O14): `aeroopt/sensitivity.py` olha só o melhor indivíduo e só as contínuas
  livres dele, dentro dos limites e das restrições do problema. Um modelo local no núcleo
  (`core/src/optim/localfit.zig`, `aerosim_local_fit`: inclinação e curvatura por eixo, mínimos quadrados com o peso
  tricúbico da regressão local) passa pelos pontos que a busca das superfícies já avaliou em volta dele, então em
  geral não roda nenhum ponto novo; só a direção que o histórico não determina ganha pontos em ±10 % da faixa. Dá
  ∂nota/∂x, ∂²nota/∂x², a nota prevista a ±10 % e o lado em que o avião deixa de fechar. Na janela, a aba
  "Sensibilidade" dos gráficos do melhor mostra o tornado; na ferramenta, `--sensibilidade`. Conferida com os dados
  de teste, em que a inclinação e a curvatura são sabidas.
- paralelismo, o Parar sem matar e sem esperar nascer: o Parar é combinado (`check_cancel()` no começo de cada ponto
  de projeto; os processos continuam vivos, e só quem não para em 2 s é encerrado). A janela usa *forkserver* com
  `aeroopt.stages` pré-carregado e um pool da sessão (`aerosim.parallel.session`, `warm_session`) que nasce em
  segundo plano quando ela abre e serve todas as rodadas.
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

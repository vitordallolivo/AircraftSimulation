# Changelog

Versões da `main`. A regra de versão está em `docs/TRACKING.md` → Versões.

## Não lançado

### v0.2.6 (em andamento na `0.2_dev`)

- Antes, a escolha do método de cálculo e os efeitos extras se misturavam, e um número mágico decidia que linha
  sustentadora usar. Agora o método se escolhe pelo nome (faixas, Phillips e Snyder, Goates e Hunsaker ou a não
  linear), e os efeitos (efeito solo, esteira da hélice, interferência entre asas, momento do comando) ligam e
  desligam um a um, cada um com os seus ajustes.
- A interferência entre asas deixou de valer só para um par e passa a valer para todas as asas ligadas, quantas
  houver.
- Antes, o dimensionamento tinha um tipo para monoplano e outro para biplano. Agora há um tipo só, o convencional, com
  o número de asas como entrada. O arrasto induzido de N asas sai da soma de Prandtl (NACA TN 182) sobre os pares, e
  com uma ou duas asas o resultado é o de antes. Os projetos salvos como monoplano ou biplano abrem como convencional
  com 1 ou 2 asas.
- O refino da malha passou a ser uma escolha do usuário: as amostras da esteira, as estações da linha sustentadora
  e os painéis na corda e na envergadura do VLM e do AVL. Deixado em 0, cada método usa o padrão de sempre.
- O Python e o núcleo passaram a falar pelos nomes das opções, e não mais por números copiados à mão dos dois lados.
  Uma opção nova no núcleo aparece no Python sem que ninguém precise copiá-la.
- O AeroDrive passou a voar com a física do arquivo do avião (os efeitos ligados nele e as asas de cada grupo). O
  modelo do voo fica fixo nas faixas, por causa do tempo real. Um arquivo sem efeitos voa com o efeito solo de sempre.
- As análises de Desempenho rodam na interface em Zig sem passar pelo Python: Tração, Voo nivelado e envelopes,
  Avião montado e Missão. Os números são os mesmos do Python, e um teste confere cada uma. A Missão tem os quatro
  modos: só a decolagem, a missão etapa por etapa (com checkpoints, raio automático das curvas e a busca do ponto de
  soltura da carga LAPES), o raio mínimo de curva e o MTOW.
- A Estabilidade do avião montado também roda na interface em Zig sem passar pelo Python: a margem estática e os
  limites de CG, a área da empenagem horizontal, a estabilidade direcional e lateral, o tamanho dos comandos, a asa
  voadora e os modos dinâmicos contra a MIL-F-8785C, com a correção sugerida quando um modo não passa. O diagnóstico,
  o resumo e as curvas são os mesmos do Python.
- Antes, o CG da Montagem na interface em Zig deixava de fora a água dos tanques e saía com 2 kg a menos. Agora a
  massa e o CG são os mesmos da Montagem em Python.
- A Montagem na interface em Zig ganha, ao lado do 3D, o resumo do avião que a Montagem em Python mostra: massa e
  CG (com o líquido, a carga e depois da soltura), dimensões a partir do CG, aerodinâmica, cargas, propulsão, trem,
  pista, LAPES, percurso e os avisos.
- Antes, a Montagem na interface em Zig só mostrava o avião. Agora ela tem a lista de componentes do Python (asas,
  motores, tanques, fuselagem, tubos, LAPES, lastro, trem, modificadores e os dados de pista, massa, ambiente,
  envelope, decolagem, piloto automático, integração e percurso). Clicar numa peça abre o formulário dela, com os
  rótulos e as unidades do Python. Cada edição refaz o 3D e o resumo, e "Salvar" grava o avião editado sem perder
  o que o arquivo tinha. No ambiente se edita a altitude-densidade, e a densidade do ar sai dela.
- Os gráficos da interface em Zig ganham área sombreada, faixas, espessura de linha, janela dos eixos, retas de
  referência e a trajetória 3D do voo.
- A Estabilidade dinâmica em Zig ganha o grupo "Métodos" para escolher o modelo do voo (faixas por padrão).
- A carga LAPES ganha o alvo no chão, e a pista ganha a distância máxima de pouso.
- Os prints da interface em Zig (`--shot`) esperam a rodada acabar e as vistas 3D desenharem.
- Antes, as análises em Zig andavam em fatias dentro do quadro da tela, e um passo longo (a busca da decolagem)
  travava a janela por uns 3 s. Agora a conta roda numa thread própria e só manda mensagens para a tela, que as lê a
  cada quadro, sem trava entre as duas; a janela não trava mais. No navegador, por enquanto, continuam as fatias.
- A busca da decolagem voa os pontos da grade em todos os núcleos, cada um com a sua cópia do avião, com o mesmo
  resultado da busca em série. Com 4 núcleos, a grade sai umas quatro vezes mais rápida, e a Missão "só decolagem",
  de 4,3 s para 2,7 s.
- Sai o simulador antigo em C (`legacy/`).

### v0.2.5 (em andamento na `0.2_dev`)

- O aerosim passa a abrir no navegador com os menus atuais. O Python do aerosim e o núcleo rodam dentro da página,
  sem instalar nada. Por enquanto, no navegador não há lltdrek, ASB nem AVL, e uma rodada não se cancela.
- O instalador (AppImage e .exe) passa a levar um Python próprio com o aerosim e os métodos opcionais. Antes, sem o
  repositório, só a Montagem abria; agora todas as abas abrem.
- As páginas da interface em Zig ganham o que a GUI PyQt tinha na Aerodinâmica. Em Projetar aparecem a peça em 3D
  com o ponto neutro (e o CG na Empenagem e em Motores) e a tabela de partições editável. Em Analisar aparecem as
  vistas 3D da carga, com o mapa de cores, as setas e a escala. Os campos de arquivo e de lista de números também
  passam a funcionar.
- Antes, a segunda asa se definia na Empenagem, com campos próprios de tandem e biplano. Agora quem decide as asas é
  Projetar: a tabela "Asas do avião" lista as asas e a posição de cada uma em relação à primeira (Δx, Δy, Δz e
  decalagem), em qualquer quantidade. A Empenagem e Analisar usam essa tabela, e a coluna "pontas ligadas" faz a asa
  em caixa. O tubo entre as asas saiu da Empenagem, porque a ligação física é coisa da Montagem.
- A Aerodinâmica passa a entregar uma configuração com nome ("Guardar configuração"), e a Empenagem escolhe uma das
  guardadas. Uma sprint antiga com segunda asa abre já com a configuração de duas asas.
- Em Projetar entra a tabela "Dispositivos das asas" (winglet, winglet para baixo, placa e cerca), cada dispositivo
  preso a uma asa e com a sua geometria, que vai junto até o avião montado.
- Antes, a Empenagem tinha campos específicos de uma configuração (arfagem do tandem, onde fica a deriva). Agora os
  comandos são uma tabela genérica (superfície, trecho, corda e os ganhos de cada eixo). Com a tabela vazia, vale a
  regra de antes e o avião sai igual.
- A divisa entre o formulário e os resultados pode ser arrastada, com a mesma largura em todas as abas. Ao começar a
  editar um campo, o que se digita substitui o valor inteiro (−1 e digitar 0.2 dá 0.2, e não −10.2).
- Os gráficos ficam com menos texto: o título diz só o que se plota, em TeX, e a legenda explica o resto. A interface
  em Zig desenha o TeX (índices, expoentes, letras gregas) e as retas de referência com nome na legenda.
- As tabelas da interface em Zig deixam de cortar os títulos das colunas e, quando não cabem, rolam para o lado.
- Abrir e salvar usam a janela de arquivo do sistema (Linux, Windows e macOS). Sem ela, como no navegador, fica o
  seletor desenhado na tela.
- O rótulo de um campo que não cabe diminui a letra e, se ainda não couber, aparece inteiro na dica.
- Os READMEs passam a mostrar as telas da interface em Zig.
- "Condições e restrições…" na interface em Zig ganha as tabelas de Restrições e de Variáveis, como na GUI PyQt.
- O `zig build` no Linux deixa de falhar na ligação do raylib.
- O Desempenho na interface em Zig fica igual ao da GUI PyQt: área segura sombreada, uma cor por altitude, a estrela
  no máximo e a janela dos eixos. Motores ganha "Usar em Desempenho →", que leva o avião direto para o Avião montado.
- A Missão na interface em Zig ganha a trajetória 3D, com cada etapa na sua cor, os eventos, a sombra no chão e as
  silhuetas do avião. Arrastar gira a vista e a roda aproxima.
- A Missão ganha a tabela das etapas (decolagem, retas, curvas e pouso) editável na tela. No modo missão aparece a
  pista (x_warning e z_warning), e o diagnóstico acusa quando a decolagem não cabe nela.
- O modo MTOW da Missão guarda o MTOW achado para a pista, e a missão, a decolagem e as curvas podem voar com a massa
  do avião, com esse MTOW ou com uma massa digitada. O acionamento do profundor pode ser o otimizado ou um digitado.
- A Estabilidade ganha o mapa dos polos de cada modo no plano complexo, um ponto por velocidade, com a faixa instável
  sombreada e os limites de amortecimento do nível 1.
- Num avião com carga lançável, a Estabilidade mostra como os polos mudam quando a carga sai e quanto o amortecimento
  e a frequência de cada modo mudam.
- A Estabilidade pode incluir o líquido dos tanques no modelo linear (Abramson, NASA SP-106), desligado por padrão.
  Aparecem os modos do próprio líquido e quanto os modos do avião se deslocam com ele.
- A Estabilidade escolhe a massa do voo: a do avião, um MTOW achado pela Missão ou uma digitada.
- A Estabilidade dinâmica é a primeira aba feita toda em Zig, sem Python no caminho. O avião equilibrado recebe uma
  rajada vertical ou lateral, com manche fixo ou piloto automático, e a aba mostra a resposta no tempo (α, β, φ, n_z,
  o CG e o líquido de cada tanque). Com tanques, voa também com o líquido travado, para comparar. A conta anda em
  fatias, então a tela não trava, nem no navegador.
- A Estabilidade dinâmica mostra o avião em 3D com os tanques, o líquido e a carga, e a carga LAPES pode ser solta no
  voo. Os polos aparecem por modo em quatro gráficos: sem efeitos, com o líquido, com a carga e com tudo junto.
- Na interface em Zig, o botão direito seleciona gráficos, e "Salvar os selecionados" grava cada um em PNG, PDF ou
  CSV.
- A Missão ganha a rajada por etapa: a tabela diz onde a rajada chega em cada etapa, e o grupo "Rajada" dá o tamanho
  e a duração. Sem mexer, a missão fica igual.

### v0.2.4 (`main`, fechada em 2026-10-30)

- A interface do aerosim em Zig fica igual à GUI PyQt, com os managers em Python: as mesmas áreas e subabas, as
  análises e as etapas da sprint, Guardar, os guardados e as tabelas de massa e dimensões. As abas feitas à mão em
  Zig dão lugar a páginas genéricas, que servem a qualquer análise.
- O aerosim e o aeroopt passam a abrir no navegador, para teste, com os aviões e perfis de exemplo. Dá para abrir um
  arquivo do computador ou arrastá-lo para a página, e salvar baixa o arquivo.
- A Montagem em Zig mostra o CG no 3D, com o vazio em cinza quando a carga o desloca.
- As contas longas da interface em Zig deixam de travar a tela. A barra lateral rola inteira, todo gráfico liga e
  desliga curvas pela legenda e exporta PNG, PDF ou CSV.
- Projetar fica igual à etapa Asa da GUI em Python: planta trapézio ou tabela de partições com perfil próprio,
  diedro, ponto neutro no 3D e diagnóstico com as restrições ativas. A conta da asa com partições vai para o núcleo.
- Entram os pacotes para instalar (AppImage e .exe) e a tela inicial que abre o aerosim, o aeroopt e o AeroDrive.
- Tudo compila e roda da raiz do repositório (`zig build aerosim`, `aeroopt`, `aerodrive`, `test`), e o código Zig
  das interfaces fica na pasta do módulo, junto do Python.
- Começa a interface em Zig (raylib e raygui, no visual do AeroDrive). A Montagem mostra o avião em 3D, Perfis
  compara polares de vários métodos, Projetar faz a asa pela linha sustentadora de Glauert, e Analisar roda a
  varredura do núcleo no avião aberto, com os mesmos números da GUI em Python.
- O AeroDrive passa a rodar no navegador e no celular, com manches virtuais, tela cheia deitada e menus que aceitam o
  toque. No navegador ele grava vídeo (G ou "Gravar" na pausa).
- O AeroDrive no navegador deixa de travar: entrar em Aeronave e decolar passam a levar uma fração do tempo de antes,
  e o quadro de voo fica umas três vezes mais leve. O programa instalado sai igual.
- O site passa a ter uma tela inicial que abre o AeroDrive e é publicado a cada mudança na `main`.
- Os checks de regressão passam a rodar sozinhos em cada PR para a `main`.
- Cargas ganham a linha sustentadora não linear, em que cada faixa segue a curva do seu perfil até depois do estol.
  Ela mostra onde o estol começa e para quanto a carga satura. Fica desligada por padrão, então o voo e o AeroDrive
  não mudam.
- A Aerodinâmica ganha a análise de um conjunto de asas como no túnel (uma asa, biplano, tandem, canard), sem
  trimar, sem fuselagem e sem hélice, mesmo sem massa. Mostra o C_L do conjunto e de cada superfície, o C_L máximo,
  onde o estol começa, a carga na envergadura e as polares de todos os métodos. Com o avião pronto, ela faz também a
  análise do avião completo, que antes era uma subaba à parte. As subabas passam a se chamar Perfis, Projetar e
  Analisar.

### v0.2.3 (`main`, PR #31)

- O código do núcleo fica legível: os erros têm nome, os nomes de uma letra viram nomes que dizem o que são, os
  índices do estado viram um enum e toda função pública ganha um comentário. A biblioteca sai igual bit a bit.
- Os READMEs do aeroopt e do core/optim ganham uma figura por bloco e por busca, com dados reais.
- O aeroopt ganha a busca com substituto: a cada geração ele sorteia muitos filhos, um modelo rápido dá o palpite de
  cada um e só os melhores palpites são avaliados de verdade. Nas formas de problema difíceis, foi a melhor busca.
- Entra o banco dos otimizadores, que compara as buscas em três formas de problema com o mesmo ótimo.
- Antes, a proteção de α na decolagem era opcional e usava um limite fixo de 11°, e a busca da decolagem aceitava
  aviões que estolavam logo depois de sair do chão. Agora a proteção é obrigatória, o limite é o estol de cada avião,
  e a busca reprova a decolagem que estola. Isso muda o resultado das decolagens: antes, 5 de 6 tandens da grade
  caíam depois de sair do chão; agora os 6 chegam ao fim da primeira manobra.
- Antes, as duas asas do tandem eram iguais. Agora a asa de trás pode ter área e perfil próprios, e a verificação
  confere a divisão da sustentação entre as asas, o recuo e o desnível.
- A bisseção do acionamento do profundor ganha uma tolerância, que deixa o MTOW no 6GDL umas quatro vezes mais
  rápido com diferença pequena no resultado.
- A janela do aeroopt deixa de mostrar o MTOW na pista (que não pontua), cabe numa tela de 1366 × 768 e passa a
  mostrar as opções de início e de partidas que antes só se mudavam no arquivo.
- A estabilidade e controle do aeroopt ganha a busca guiada pela falha: cada violação aponta as variáveis que a
  consertam, e há métodos novos para escolher o próximo avião.
- Com os comandos ligados, o aeroopt confere também a estabilidade dinâmica. Antes, o tandem da Regular 2026 era
  instável em guinada e caía depois de decolar sem que a sprint visse.
- A busca do acionamento na decolagem pode ser por bisseção a partir da corrida sem acionar.
- A posição da carga paga vira variável, e a estabilidade e controle a escolhe junto com os comandos.
- Antes, no tandem com deriva na ponta, a sprint confundia a deriva com a segunda asa e o avião nunca voava. Agora a
  segunda asa se acha pelo papel dela.
- A população inicial pode sair por hipercubo latino, e a busca pode ter várias partidas. As duas ficam desligadas por
  padrão.
- Antes, a sprint calculava o ponto neutro do tandem só pela asa da frente, o CG ia parar perto dela e o avião não
  trimava. Agora a asa de trás é tratada como a cauda (com o downwash da da frente), o profundor fica nela e o tandem
  ganha os seus comandos.
- Antes, o avião sem cauda parecia sair do chão sozinho, porque a sprint usava o C_L da asa sem trimagem. Agora só
  conta o C_L que o comando ainda trima.
- A verificação dos comandos confere o peso mínimo na bequilha parado (Raymer §11.2) e a estabilidade direcional.
- A asa sem cauda e o tandem podem ter uma deriva com leme em cada ponta da asa, que dá a estabilidade direcional.
- O comando de arfagem do tandem pode ficar na asa de trás, na da frente ou nas duas, e a busca escolhe.
- A decolagem ganha a proteção de α: até o piloto automático assumir, o profundor não deixa α passar do limite.
- Quando o ponto de projeto da sprint não converge pela média de sempre, ele segue por secante.
- A altura do obstáculo da decolagem vira entrada (1 m por padrão).
- O aeroopt ganha a pontuação da Regular 2026, com o fator de superfícies, de envergadura e as penalidades.
- A asa voadora ganha uma partida própria na busca dos comandos (enflechada, com torção e elevon na ponta), e a
  verificação confere o C_L trimado contra o estol, o elevon segurando o nariz e a asa longe do estol.
- A atitude no chão vira entrada: com a bequilha mais comprida, a asa corre num ângulo e pode sair do chão sem rodar.
  Antes, a decolagem começava nivelada, a bequilha entrava no chão e o avião capotava.
- Antes, a sprint dava ao elevon da asa voadora uns quatro vezes o momento que o núcleo dava. Agora a conta põe a
  sustentação no lugar certo e soma o momento próprio do flape, e as duas contas batem.
- A busca do aeroopt passa a mexer também nos comandos e exige que o comando rode o avião antes de sair do chão.
- O aeroopt escolhe a cauda (convencional, em H, em V ou sem cauda) pela que voa e decola com mais carga paga.
- A sprint ganha a cauda em H.
- Os menus do aeroopt ganham ajuda em cada opção, e as asas alta, média, baixa e parasol viram um monoplano só.
- O aeroopt ganha a evolução diferencial, cujo passo encolhe sozinho perto do ótimo.
- O aeroopt mostra o caminho da busca em coordenadas paralelas, também exportável como página.
- O aeroopt ganha a sensibilidade do melhor avião: quanto a nota muda com cada variável, a perda pela tolerância de
  fabricação e o efeito de cada restrição, quase sem rodar pontos novos.
- O Parar do aeroopt para sem matar os processos, e eles passam a nascer uma vez por sessão.
- O aeroopt ganha os dados de teste, com o resultado sabido de antemão, para conferir as buscas e o paralelismo.
- O paralelismo vira um módulo com série, threads e processos, e os processos nascem uma vez por rodada.
- O equilíbrio motor × hélice da sprint vai para o núcleo e deixa o aeroopt bem mais rápido.
- O aeroopt passa a mostrar os gráficos do melhor avião até ali (decolagem, polar, estabilidade, desempenho).
- O mapa dos aviões passa a ter as variáveis do problema como eixos.
- O aeroopt ganha o CMA-ES, que aprende a forma da região boa e anda ao longo das variáveis acopladas.
- Antes de buscar desempenho, o aeroopt confere se o avião voa (trima, equilibra sem lastro, tem margem) e procura o
  ponto que viola menos quando não voa.
- O aeroopt ganha a restrição de estabilidade, e um voo inválido passa a ter nota 0.
- Antes, quase toda configuração reprovava por bater no chão na rotação. Agora o núcleo diz quanto descer as rodas, e
  a geometria se conserta sozinha.
- Todo campo das etapas do aerosim pode virar variável do aeroopt.
- O lado esquerdo do aeroopt vira botões com resumo, cada um com o seu submenu, e cada etapa ganha a escolha do método.
- As configurações do aeroopt passam a sair de um algoritmo genético, no lugar de varrer todas as combinações.
- A geometria do avião montado é conferida no núcleo: hélice que acerta peça, massa fora da geometria, pedaços soltos
  e folga ao chão.
- O aeroopt ganha os submenus do problema: variáveis, restrições, perfis por região e peças do catálogo.
- Cada rodada do aeroopt grava os pontos avaliados e as notas em CSV, e o avião escolhido abre no aerosim.
- O aeroopt ganha a janela, com a rodada ao vivo, o mapa dos aviões e o avião clicado em 3D.
- O aeroopt ganha as categorias de configuração (asa alta, biplano, tandem, asa voadora...).
- A corrida de decolagem da sprint vai para o núcleo, e o ponto de projeto fica umas cinco vezes mais rápido.
- O aeroopt passa a otimizar em etapas (configurações, superfícies, MTOW no 6GDL e nota), com cada etapa em paralelo.
- O aeroopt ganha a ferramenta de linha de comando.
- A nota do regulamento passa a ser calculada no núcleo.
- A pontuação passa a vir de um arquivo por regulamento, a começar pela Micro 2026.
- O aeroopt ganha o problema de otimização em arquivo e a ponte com o projeto da sprint.
- O avião pode ter asas ligadas (tandem e biplano) na Montagem e na sprint, e a interferência entre elas é um efeito
  que se liga.
- Os motores ficam livres: nariz, pares na asa e propulsora.
- Antes, um avião sem trem ou com inércia inválida derrubava o programa. Agora o núcleo devolve uma mensagem clara, e
  o AeroDrive a mostra na tela.
- A massa das superfícies simétricas passa a contar em cada lado.
- O ajuste da decolagem deixa de travar a tela.
- Os READMEs ganham as equações, cada uma com a fonte e um exemplo que roda.
- A Aerodinâmica ganha a linha sustentadora do núcleo como método de comparação.
- A linha sustentadora fica bem mais rápida, com o mesmo resultado bit a bit.
- Antes, a linha sustentadora de Phillips e Snyder não convergia com a malha em derrapagem nem com enflechamento.
  Agora há a de Goates e Hunsaker, que bate com a implementação dos autores.
- O voo pode usar outro modelo aerodinâmico: as faixas (o padrão), a linha sustentadora ou uma tabela de qualquer
  método. Uma ferramenta compara a decolagem e a missão com cada modelo.
- Antes, só a asa era refinada nas comparações, e a EV sozinha saía com o dobro do C_Yβ. Agora todas as superfícies
  são refinadas.
- Entra a ferramenta que compara os coeficientes de todos os métodos no mesmo estado do avião.
- A falha "hélice tocou o chão" fica desligada por padrão, porque o exemplo de asa voadora não voava com ela.
- O envelope de voo ganha subaba própria, com o método da planilha e o modelo completo sobrepostos.
- A aba Cargas mostra a carga ao longo de cada superfície num ponto de voo, com e sem a hélice, e a vista 3D.
- A Missão mostra o fator de carga nas curvas: o que a inclinação pede, o de estol e o estrutural (Anderson,
  Introduction to Flight, §6.17).

## v0.2.2 — PR #27

- Entra o mapa do código, gerado a partir dele.

## v0.2.1 — PR #26

- A Missão mostra o passeio do CG e a margem estática ao longo do voo.

## v0.2.0 — fundação fechada (PRs #24–#25)

- Entram os checks de regressão: núcleo, AeroDrive, exemplos bit a bit contra uma referência e testes por área.

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

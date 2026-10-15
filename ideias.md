# O que precisa ser feito:
- Não ter requeriments de rodar a decolagem para o avião ir para montagem, poder pegar o projeto de sprint em desempenho e usar lá direto, escolhendo um conjunto, um conjunto é algo como uma asa
e multiplas opções de superficies moveis, ou seja { asa = {elementos da asas}, superficies = { super1,super2,...}} algo desse tipo. Ai precisa criar numa pasta do usuario que ele decidir escolher
os documentos de sprint, acho que seria legal fazer por asa o sprint, tipo o nome da asa é o nome do projeto de sprint.

- Adicionar a aba de tração e missão na parte de desempenho ao inves de ficar avulsa.

- Massa que precisa ser controlada na pista de decolagem precisa ser a massa inteira da aeronave, ao inves de variar lapes e liquido, tem que ser o todo. O xCG acho que não era para estar em metro,
mas não me lembro ao certo

- Todos os perfis tem que estar disponiveis do get-go com base em data/airfoils, mesma coisa para os motores. Por exemplo hj para eu poder usar um perfil de EH eu preciso adicionar em aerodinamica,
meio ruim.

- Em E&C tem ME mas não uma enfase de xCG com ME e nem analises o suficiente. ainda em E&C é necessario adicionar as analises não lineares para casos como um vtol, por exemplo o que acontece quando
os motores precisam mudar suas inclinações? O que acontece com os polos por conta do slothing? o quanto que o vento lateral/ou de frente afeta nas estabilidades.
- Procurar as analises de estabilidade de helicoptero ( e como que eles dimensionam, seria interessante para decolagem com VTOL)


- Adicionar opção para reverter rotação de qualquer CMP.

- Dimensionar piloto automatico a partir de algo como SMC, ou uma NN-MPC.
- Adicionar opções de vtol, tailsitter, adicionar uma aba de controle para dimensionar o controlador do simulador e um real ( sub-abas). ( requer o controle nao linear)
- Melhorar analises de curvas dinamicamente, colocar o fator de carga lá.
  
- Adicionar analises de cargas e aeroelasticidade (dinamica)
- Dimensionamento de longarina, tubo de cauda.

# Coisas futuras
- Simulação 3D aerodinamica completa como no openVSP ou no ansys, se aproveitar de otimizações de shader para GPU/TPU existentes no zig (https://alichraghi.github.io/blog/zig-gpu/)
- Conseguir exportar um arquivo para o solid e do solid para ca, ai com isso colocar tipo a rugosidade ( segundo o que eu conversei com o chavinho) e conseguir simular como se fosse no openVSP
os arrastos parasitas.
- Calculos estruturais, da para pegar o TCC do gunther para esse tipo de otimização

# Coisas que o claudio achou importante:

## Análises que faltam
Esteira da hélice sobre asa e EH. Não há nada disso no código. É o efeito mais importante que está faltando:
- na decolagem, com velocidade baixa e tração alta, a EH fica dentro da esteira e o profundor ganha autoridade no tailsitter e no VTOL, a transição depende disso.
- Reynolds no núcleo. O Python usa Reynolds, mas o núcleo trabalha com CLα, CL,max e CD0 fixos por superfície. Num avião SAE, o Reynolds vai de cerca de 150 mil a 400 mil entre a corrida de decolagem e o cruzeiro, e o CL,max e o CD0 do perfil mudam bastante nessa faixa. Uma tabela por Reynolds resolve.
- Incerteza (Monte Carlo e sensibilidade). Não existe hoje. Sorteando tolerâncias de massa, CG, CL,max e tração, dá para responder “qual a chance de decolar em 6 m”. Para competição, isso vale mais que um número único.
- Turbulência contínua. Hoje só existe a rajada 1−cos. Um modelo Dryden ou von Kármán faria falta para testar o piloto automático e o vento que você citou.
- Passeio do CG. Ninguém calcula hoje a faixa que o CG percorre com a soltura da LAPES e o consumo do líquido. Isso entra junto com o gráfico ME × xCG.
- Limite dianteiro do CG pela rotação na pista. É o profundor conseguir levantar o nariz em torno do trem principal. Normalmente é esse limite que fecha a tesoura em avião SAE; se a tesoura ainda não usa, falta.
- Níveis de qualidade de voo. As normas MIL-F-8785C e MIL-STD-1797 classificam o período curto, a fugóide, o dutch roll, a espiral e o modo de rolamento em níveis 1, 2 ou 3. Os polos já existem, falta classificar.
Decolagem com vento cruzado. Controle direcional no chão e risco de tombar.

## Melhorias no Zig
- Integrador. Pelo que vi, é RK4 de passo fixo. O contato do trem é rígido e obriga a usar passo pequeno o tempo todo. Um passo adaptativo (Dormand–Prince) com detecção de eventos (sair do chão, tocar, soltar a carga) deixa a corrida de decolagem mais precisa e o código mais rápido.
- Derivadas exatas com números duais em comptime. O modelo seria escrito genérico no tipo numérico (f64 ou Dual). Isso dá Jacobianos exatos para a linearização e gradientes para o otimizador, sem diferenças finitas. É o tipo de coisa em que o Zig é muito bom.
- SIMD de verdade. Hoje V3 = @Vector(3, f64), então o ganho é pequeno: 3 posições preenchidas até 4. Organizar os painéis como estrutura de arrays e processar 4 ou 8 painéis por vez rende bem mais. Eu mediria antes com o bench.zig.
- Paralelismo. O PSO avalia a população e o Monte Carlo roda casos que são independentes entre si. Um std.Thread.Pool no núcleo divide o tempo pelo número de núcleos da máquina.
- Verificação da ABI. Um hash do esquema comptime conferido ao carregar a biblioteca no Python. O erro do LayoutData faltando apareceria na hora, com uma mensagem clara, em vez de um KeyError.

 Testes de propriedade. Por exemplo:
  sem aerodinâmica, a energia se conserva;
  na condição de trimagem, as derivadas dão zero;
  a linearização bate com diferenças finitas.
  Para o SAE, a esteira da hélice, o Reynolds no núcleo

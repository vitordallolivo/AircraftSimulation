# aerosim/manager/native — as análises feitas em Zig

Esta pasta guarda as análises que rodam inteiras em Zig, sem Python no caminho. A tela em Zig (`aerosim/gui`) pede os
campos e roda uma análise daqui do mesmo jeito que pede uma do Python, mas a conta acontece no próprio programa,
chamando o núcleo (`core`) direto. Com isso a aba funciona também no navegador sem carregar o Python (Pyodide). Esta
é a primeira peça da troca dos managers em Python por Zig. Uma análise nova pode nascer aqui, e as antigas vêm para
cá uma de cada vez.

A pasta tem duas partes. A primeira, `native.zig`, é o framework: o contrato que a tela conhece e o registro das
análises. A segunda são as análises, uma por arquivo, e por enquanto há só uma, a Estabilidade dinâmica
(`gust_liquid.zig`), a rajada com o líquido dos tanques.

## O framework (`native.zig`)

Aqui se registra uma análise nova. Ela é um tipo com declarações de nome conhecido: `name`, `title`, `area` e
`description` (os textos), `State` (o que a rodada guarda entre uma fatia e outra) e as funções `specs`, `start`,
`advance` e `result`, mais `edit` se a aba tem tabelas. O tipo entra na lista `analyses`, e `register` monta a tabela
que a tela usa. Antes, cada análise guardava o próprio estado num ponteiro sem tipo e o convertia em cada função, e
um erro de assinatura só aparecia rodando; agora o framework cria o `State` na memória da rodada e passa `*State` já
com o tipo, e uma declaração que falta ou uma assinatura errada não compila, com o nome da análise na mensagem. O
molde é o mesmo dos tipos de aeronave do dimensionamento (`core.interface`). Os erros também têm nome:
`native.Error` junta os da memória, da escrita, da montagem do avião e do voo do núcleo, e a mensagem para a tela vai
em `Run.fail`.

Os métodos de cálculo do voo (o modelo aerodinâmico, a variante da linha sustentadora e o refino da esteira) vêm
prontos em `method_params`, no grupo "Métodos" do formulário, e `Values.methods` lê o que o usuário escolheu como um
`core.methods.Methods`. As opções saem dos próprios `enum` do núcleo, com o nome em português, então um método novo
no núcleo aparece na tela sem mexer aqui. O AeroDrive usa os mesmos `Methods`, só que fixos
(`aerodrive/src/sim/methods.zig`), e o tradutor do avião é o mesmo para os dois (`params.setupWith`).

### O contrato com a tela

Aqui se define o que uma análise em Zig precisa ter para virar uma subaba. São quatro coisas: os campos e os
gráficos, o começo de uma rodada, um passo da rodada e o resultado. O formato é o mesmo JSON da ponte com o Python
(`aerosim/bridge.py`). Os campos saem como `{"params": [...], "plots": [...], "description": ...}` e o resultado
como `{"summary": {...}, "checks": [...], "plots": [...]}`, com os nomes da `ISimulation`
(`aerosim/interfaces/simulation.py`). Por isso a tela desenha uma aba daqui sem saber de onde ela veio.

Além do formulário, os campos podem trazer tabelas editáveis (`grids`, `native.Grid`) e o avião em 3D (`view`,
`native.View`, as peças do `skeleton` com o CG). Uma edição numa tabela chega em `edit` (`native.GridEdit`: a célula
mudada ou o botão apertado), e a própria análise guarda as linhas até a rodada, sem a ponte. A tela responde a essa
edição no começo do quadro seguinte, porque responder no meio do desenho soltaria a memória do formulário que ainda
está na tela.

A rodada anda em fatias. A tela chama `advance` uma vez por quadro e para depois de uns poucos milissegundos de
conta, então ela continua desenhando e respondendo enquanto a análise roda. No navegador não há thread: sem as
fatias, uma conta longa travaria a página. O botão "Parar" simplesmente joga fora a rodada.

A tela põe cada análise na aba de cima que ela pede (`area`), depois das subabas que vêm do Python.

## Estabilidade dinâmica (`gust_liquid.zig`)

Aqui se vê, no tempo, o que uma rajada faz com o avião equilibrado em voo nivelado: o ângulo de ataque, a derrapagem,
o rolamento, o fator de carga, o quanto o CG anda e o ângulo do líquido de cada tanque. A rajada pode ser vertical,
lateral ou as duas, com a duração e o instante escolhidos. Os comandos ficam no equilíbrio (manche fixo, a resposta
do avião sozinho) ou com o piloto automático. A massa pode ser a do avião ou outra maior, como o MTOW. O que passa da
massa do avião entra no CG dele.

A rajada aparece tracejada dentro dos gráficos que ela mexe, como o comando nos gráficos de resposta de um relatório
de estabilidade: no ângulo de ataque, o ângulo que a rajada vertical soma ao vento relativo, $`\operatorname{atan}(U/V)`$,
e na derrapagem o da lateral. Ela sobe de zero ao pico e volta a zero na duração escolhida.

Os polos, $`\lambda = \sigma \pm i\omega`$, saem em quatro gráficos: sem efeitos (o corpo rígido, com o líquido
travado e a LAPES a bordo), com o sloshing (o líquido balançando), com a LAPES (que sai no instante em que saiu no voo)
e todos juntos, cada efeito com a sua cor. Cada modo tem um símbolo (curto período, fugóide, dutch roll, rolamento,
espiral e o líquido), colocado no ponto do começo do voo. A curva fina que sai dele mostra para onde o polo anda
durante o voo, refeito em vários instantes com a velocidade daquele instante e com o que está a bordo. O modo de cada
polo vem do núcleo (`core/src/sim/gust.zig`, `poles`), com a mesma regra da Estabilidade em Python. O diagnóstico diz
qual é o menos estável. Um polo com $`\sigma > 0`$ cresce e dobra a cada $`\ln 2/\sigma`$ segundos, e é isso que
explica, por exemplo, o rolamento que cresce devagar no manche fixo (a espiral).

Os tanques ficam numa tabela da aba: o nome, onde cada um está (x, y, z), o lado, a altura, o volume, o formato e a
massa do líquido (densidade vezes volume), com a soma embaixo. A tabela começa com os tanques do arquivo e guarda o
que se mudou até abrir outro avião; o arquivo não muda. A LAPES tem um grupo no formulário, com a massa, onde ela está
e se ela sai durante o voo, e em que instante. Depois que ela sai, voa só o resto da massa, e o diagnóstico diz
quando ela saiu, a massa que ficou e para onde foi o CG. A vista 3D mostra o avião com os tanques, o líquido, a LAPES
e o CG, com os tanques e a carga desenhados por cima da fuselagem para se ver onde estão. Sem tanques ou sem LAPES, a
análise roda sem essa parte (sem o gráfico do líquido e sem os itens dela no diagnóstico).

Quando o avião tem tanques, ele voa duas vezes, com o líquido livre e com o líquido travado na mesma massa. Os gráficos
mostram as duas respostas juntas, a livre em traço cheio e a travada tracejada, e a diferença entre elas é o efeito
do líquido. A conta é a do núcleo (`core/src/sim/gust.zig`, que explica a rajada e o líquido em repouso). O
diagnóstico dá o pico do ângulo de ataque contra $`\operatorname{atan}(U/V)`$, se ele volta ao equilíbrio, quanto o CG
anda e o maior desvio do líquido.

## Como chamar

A tela faz isso sozinha. Para usar de fora, por exemplo num teste:

```zig
const native = @import("manager");
const simulation = native.find("estabilidade_dinamica").?;
var run = native.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
defer run.arena.deinit();
try simulation.start(&run, native.Values.fromRequest(run.memory(), "\"values\": {\"up\": 3}"));
while (!try simulation.advance(&run)) {}
try simulation.result(&run, &writer);   // o JSON da ponte
```

Os testes rodam com os da tela: `cd aerosim && python -m ziglang build test`.

## Nova análise

Escreva um arquivo com um tipo da análise e ponha o tipo em `native.analyses`:

```zig
pub const Analysis = struct {
    pub const name: []const u8 = "minha_analise";
    pub const title: [:0]const u8 = "Minha análise";
    pub const area: []const u8 = "Desempenho";
    pub const description: []const u8 = "o que ela mostra";
    pub const State = struct { instance: ?*core.runner.Instance = null };   // começa com os padrões
    pub const specs = writeFields;    // fn (*native.Writer, ?*const native.Aircraft, native.Values) native.Error!void
    pub const start = startRun;       // fn (*native.Run, *State, native.Values) native.Error!void
    pub const advance = advanceRun;   // fn (*native.Run, *State) native.Error!bool
    pub const result = writeResult;   // fn (*native.Run, *State, *native.Writer) native.Error!void
};
```

Os campos saem com `native.writeSpecs` (junte `native.method_params` se a análise voa o avião; as tabelas e o 3D vão
em `native.Extras`), o avião se monta com `params.setupWith(avião, instância, &diagnóstico, values.methods())`, e o
resultado sai com `native.beginResult`, `native.writePlot` e `native.endResult`. A conta em si vai no núcleo, com teste
em Zig. Aqui fica só a montagem do caso, as fatias e o texto do resultado.

# aerosim/manager/native — as análises feitas em Zig

Esta pasta guarda as análises que rodam inteiras em Zig, sem Python no caminho. A tela em Zig (`aerosim/gui`) pede os
campos e roda uma análise daqui do mesmo jeito que pede uma do Python, mas a conta acontece no próprio programa,
chamando o núcleo (`core`) direto. Com isso a aba funciona também no navegador sem carregar o Python (Pyodide). Esta
é a primeira peça da troca dos managers em Python por Zig. Uma análise nova pode nascer aqui, e as antigas vêm para
cá uma de cada vez.

A pasta tem duas partes. A primeira, `native.zig`, é o contrato que a tela conhece. A segunda são as análises, uma por
arquivo, e por enquanto há só uma, a da rajada com o líquido dos tanques (`gust_liquid.zig`).

## O contrato (`native.zig`)

Aqui se define o que uma análise em Zig precisa ter para virar uma subaba. São quatro coisas: os campos e os
gráficos, o começo de uma rodada, um passo da rodada e o resultado. O formato é o mesmo JSON da ponte com o Python
(`aerosim/bridge.py`). Os campos saem como `{"params": [...], "plots": [...], "description": ...}` e o resultado
como `{"summary": {...}, "checks": [...], "plots": [...]}`, com os nomes da `ISimulation`
(`aerosim/interfaces/simulation.py`). Por isso a tela desenha uma aba daqui sem saber de onde ela veio.

A rodada anda em fatias. A tela chama `advance` uma vez por quadro e para depois de uns poucos milissegundos de
conta, então ela continua desenhando e respondendo enquanto a análise roda. No navegador não há thread: sem as
fatias, uma conta longa travaria a página. O botão "Parar" simplesmente joga fora a rodada.

A tela põe cada análise na aba de cima que ela pede (`area`), depois das subabas que vêm do Python.

## Rajada e líquido (`gust_liquid.zig`)

Aqui se vê, no tempo, o que uma rajada faz com o avião equilibrado em voo nivelado: o ângulo de ataque, a derrapagem,
o rolamento, o fator de carga, o quanto o CG anda e o ângulo do líquido de cada tanque. A rajada pode ser vertical,
lateral ou as duas, com a duração e o instante escolhidos. Os comandos ficam no equilíbrio (manche fixo, a resposta
do avião sozinho) ou com o piloto automático. A massa pode ser a do avião ou outra maior, como o MTOW. O que passa da
massa do avião entra no CG.

Quando o avião tem tanques, ele voa duas vezes, com o líquido livre e com o líquido travado na mesma massa. Os gráficos
mostram as duas respostas juntas, a livre em traço cheio e a travada tracejada, e a diferença entre elas é o efeito
do líquido. A conta é a do núcleo (`core/src/sim/gust.zig`, que explica a rajada e o líquido em repouso). O
diagnóstico dá o pico do ângulo de ataque contra $`\operatorname{atan}(U/V)`$, se ele volta ao equilíbrio, quanto o CG
anda e o maior desvio do líquido.

## Como chamar

A tela faz isso sozinha. Para usar de fora, por exemplo num teste:

```zig
const native = @import("manager");
const simulation = native.find("rajada_liquido").?;
var run = native.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
defer run.arena.deinit();
try simulation.start(&run, native.Values.fromRequest(run.memory(), "\"values\": {\"up\": 3}"));
while (!try simulation.advance(&run)) {}
try simulation.result(&run, &writer);   // o JSON da ponte
```

Os testes rodam com os da tela: `cd aerosim && python -m ziglang build test`.

## Nova análise

Escreva um arquivo com uma `native.Simulation` (os campos com `native.writeSpecs`, o resultado com
`native.beginResult`, `native.writePlot` e `native.endResult`) e ponha-a em `native.all`. A conta em si vai no núcleo,
com teste em Zig. Aqui fica só a montagem do caso, as fatias e o texto do resultado.

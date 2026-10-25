# aerosim/parallel — rodar a mesma conta em muitos itens

Esta pasta é o paralelismo do projeto, separado de quem o usa. Quem tem uma lista de itens independentes (os
candidatos de uma etapa do aeroopt, as configurações de uma geração, os casos de uma ferramenta de medida) entrega
a função e a lista a um executor, e recebe de volta um resultado por item, na mesma ordem. Quem chama não sabe se a
conta rodou em série, em linhas de execução ou em processos; a escolha é feita fora e pode mudar sem mexer no resto.

A pasta tem duas partes. O contrato fica em `aerosim/interfaces/executor.py` (`IExecutor` e `Outcome`), como os
outros contratos entre camadas. Aqui ficam as três formas de rodar, o `Executors`, que guarda uma de cada para a
rodada inteira, e os executores da sessão, que duram até o Python fechar. As seções seguem essa ordem e depois
contam como o Parar funciona sem matar os processos.

## Por que três formas

O Python deixa uma linha de execução rodar código Python por vez: é o GIL (*global interpreter lock*). Uma chamada
ao núcleo em Zig por ctypes solta o GIL, então linhas de execução só ganham na parte que passa no núcleo; na parte
em Python (montar o avião, traduzir, as buscas) elas esperam umas pelas outras e ficam até mais lentas que a série.
Processos têm cada um o seu Python e o seu núcleo, então não dividem o GIL, mas pagam para nascer (o *spawn* importa
tudo de novo) e para mandar cada item de um lado para o outro (*pickle*).

`SerialExecutor` roda na linha de quem chama: é a referência e o que se usa com um trabalhador só. `ThreadExecutor`
serve para contas que vivem no núcleo. `ProcessExecutor` serve para contas com muito Python, e é o padrão do
aeroopt. A ferramenta `tools/pipeline_bench.py` mede as três no mesmo lote e diz quanto de cada etapa fica preso ao
GIL.

## O pool que dura a rodada

Antes, cada etapa de cada geração abria um pool de processos novo, e numa rodada com oito gerações de cinco etapas
os trabalhadores nasciam quarenta vezes. O `ProcessExecutor` guarda os processos entre um `map` e o próximo; eles só
morrem no `close`. O `Executors` guarda um executor de cada tipo, criado na primeira vez que alguém pede: as etapas
pedem o tipo que querem (`IStage.parallel`) e todas dividem os mesmos trabalhadores. Os trabalhadores também ficam
com o núcleo carregado, então a segunda geração já começa quente.

Com *spawn* os trabalhadores nasceriam um a um, quando o trabalho chega, e cada um pagaria os imports e o núcleo no
meio da primeira etapa pesada. Por isso o pool nasce com todos de pé: cada trabalhador roda o `initializer` (no
aeroopt, `stages.warm`, que carrega o núcleo) em paralelo, antes do primeiro item. `start()` abre o pool na hora,
para quem quer medir quanto custa nascer à parte, como faz a ferramenta de medida.

## Sem esperar nascer: forkserver e a sessão

Um processo novo por *spawn* começa vazio e importa o aerosim e carrega o núcleo, o que custa bem mais que uma
etapa curta. Havia quatro saídas. O *fork* copia o processo de quem chama já com tudo carregado e nasce quase de
graça, mas não é seguro num programa com linhas de execução (a janela do Qt tem várias): a cópia pode herdar uma
trava presa. O Python sem GIL (as versões *free-threaded*) deixaria as threads rodarem juntas, sem processos, mas
ainda depende de o numpy e o PyQt existirem nessa versão. Levar a etapa inteira para o núcleo em Zig, com as linhas
do próprio Zig, tira o Python do caminho, mas é um trabalho grande. As outras duas estão aqui.

A primeira é o *forkserver* com pré-carga (`preload`). Um servidor nasce uma vez por sessão do Python, num processo
limpo e sem linhas, e importa os módulos pedidos (no aeroopt, `aeroopt.stages`, que traz o aerosim junto). Cada
trabalhador depois é uma cópia desse servidor, já com tudo carregado: só o primeiro pool paga os imports, e os
seguintes abrem quase na hora. É seguro como o *spawn* e rápido como o *fork*.

A segunda é não fechar o pool entre as rodadas. `session(workers, start_method, initializer, preload)` devolve os
mesmos executores para todas as rodadas com esses parâmetros, até o Python fechar, e `warm_session` abre o pool numa
linha de fundo. A janela do aeroopt chama `warm_session` quando abre, então os processos nascem enquanto o usuário
ainda está montando o problema, e a primeira rodada já encontra todos de pé.

## O Parar sem matar

O Parar é visto a cada 0,2 s, não só quando o próximo item termina. Matar o processo que está contando funcionava,
mas jogava fora o trabalhador e obrigava o próximo `map` a abrir outros. Agora o Parar é combinado: cada pool de
processos tem um sinal compartilhado, e a conta olha esse sinal entre um passo e outro com `check_cancel()`, que sai
com `Cancelled`. No aeroopt isso fica no começo de cada ponto de projeto, então uma busca das superfícies para entre
um ponto e o seguinte. O item volta como cancelado (não como erro), o que ainda não tinha começado é descartado e os
processos continuam os mesmos. Em série e em threads o mesmo `check_cancel()` olha o `cancel` do `map`.

Só quem não para em `GRACE` segundos é encerrado: uma chamada longa ao núcleo (a decolagem 6GDL, por exemplo) não tem
como olhar o sinal no meio. Um processo que morre sozinho (o pool quebrado) é tratado do mesmo jeito: os itens dele
voltam com o erro e o pool nasce de novo.

Em processos, a função e os itens precisam ir por *pickle*: uma função de módulo, ou um método de um objeto que vai
por *pickle* (é o caso das etapas do aeroopt). O resultado não depende de quem terminou primeiro, porque a lista
volta na ordem dos itens.

## Como chamar

```python
from aerosim.parallel import Executors, check_cancel, make_executor, session, warm_session

def quadrado(x):
    return x * x

with make_executor("processos", workers=4, start_method="spawn", initializer=None) as ex:
    for lote in ([1, 2, 3], [4, 5, 6]):                      # os mesmos 4 processos nos dois lotes
        res = ex.map(quadrado, lote, on_done=lambda j, r: print(j, r.value))
        print([r.value if r.ok else r.error for r in res])

with Executors(workers=4, start_method="spawn") as todos:   # um de cada tipo, para uma rodada inteira
    todos.get("threads").map(quadrado, range(10))

def longa(x):
    for passo in range(1000):
        check_cancel()                                        # o Parar sai daqui, sem matar o processo
        ...
    return x

warm_session(4, "forkserver", None, ("meu_modulo",))         # os processos nascem já, em segundo plano
res = session(4, "forkserver", None, ("meu_modulo",)).get("processos").map(longa, itens, cancel=parar.is_set)
```

`map(fn, itens, cancel, on_done)` devolve um `Outcome` por item: `value`, ou `error` com a exceção que a conta
levantou, ou `cancelled`. `on_done(j, resultado)` é chamado na linha de quem chama, na ordem em que os itens
terminam (é por ele que a GUI mostra o andamento ao vivo).

Para acrescentar uma forma nova de rodar (um conjunto de máquinas, o Python sem GIL), basta uma classe que
implemente `IExecutor` e um nome novo em `KINDS` e em `make_executor`; o processo em etapas e as gerações não mudam.
Os testes ficam em `tests/parallel`.

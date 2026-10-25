# aeroopt/ — o otimizador do projeto

Este é o terceiro braço do AircraftSimulation. O `aerosim` é onde se projeta um avião e o `aerodrive` é onde se voa
nele. O aeroopt procura, entre muitos aviões possíveis, o que faz mais pontos numa competição. Você diz o que pode
mudar no avião (envergadura, área, perfis, motor, hélice, tipo de avião...), entre que limites e com que restrições, e
escolhe a pontuação do regulamento. Ele monta os aviões, confere se cada um cabe, voa e decola, dá a nota de cada um
e mostra qual ganhou e por quê.

O aeroopt não tem física própria. Cada avião é montado pelas mesmas etapas do aerosim e as contas rodam no núcleo em
Zig (`core/`). Aqui só se organiza a busca e se mostra o resultado.

## Como se divide

Tudo começa no problema (`problem.py`): o que é livre, os limites, as restrições e a pontuação, gravados num arquivo
`.opt.json`. As variáveis possíveis são os campos das etapas do aerosim (`inputs.py`), e os tipos de avião, como asa
alta, biplano ou asa voadora, ficam em `categories.py`. A pontuação de cada regulamento é um `.toml` em `pontuacao/`,
traduzido por `scoring.py` para o núcleo calcular. A busca anda em etapas (`stages.py`, com a fila em `pipeline.py`):
cada avião passa pela geometria, depois por "voa?", depois pelo desempenho e, por fim, pela nota. Quem escolhe quais
aviões experimentar são as gerações de um algoritmo genético (`generations.py`). A janela fica em `gui.py`, e os CSV
de cada rodada saem de `export.py`.

| arquivo | o que tem |
|---|---|
| `problem.py` | o problema e o arquivo `.opt.json` |
| `inputs.py` | as variáveis: todo campo das etapas do aerosim, com faixa ou lista |
| `categories.py` | os tipos de avião que a busca pode montar |
| `scoring.py`, `pontuacao/` | a pontuação de cada regulamento (Micro 2026), com a fonte |
| `stages.py`, `pipeline.py` | as etapas e a fila que as roda em paralelo |
| `generations.py` | as gerações de configurações (algoritmo genético no núcleo) |
| `gui.py` | a janela |
| `export.py` | os CSV de cada rodada |
| `mini_mdo.py` | o mini-MDO do núcleo, a primeira versão, que fica como alternativa |

As contas que rodam no núcleo para o aeroopt (a nota, o algoritmo genético e o CMA-ES) estão explicadas em
[`core/src/optim/README.md`](../core/src/optim/README.md).

## A janela

À esquerda fica o problema, com um botão para cada parte: pontuação, variáveis, restrições, categorias e
configuração. Cada botão abre um submenu, e ao lado dele aparece um resumo do que está escolhido. À direita fica a
rodada: quantos aviões passaram em cada etapa, o MTOW de cada ponto avaliado, a nota de cada configuração, o mapa dos
aviões, a tabela e o avião selecionado em 3D.

![A janela do aeroopt](../docs/img/aeroopt/janela.png)

Nas variáveis se marca o que é livre e entre que limites. Um campo de escolha, como o perfil ou o motor, abre a lista
para marcar as opções que entram na busca.

![As variáveis da asa](../docs/img/aeroopt/menu_variaveis.png)

Nas restrições ficam as condições que o avião tem de cumprir, a geometria (hélice, peças e chão na rotação) e a
estabilidade. Na configuração se escolhe o método de cada etapa.

![As restrições](../docs/img/aeroopt/menu_restricoes.png)

![A configuração das etapas](../docs/img/aeroopt/menu_configuracao.png)

No mapa, cada ponto é um avião. Os eixos podem ser qualquer variável do problema ou um resultado, e a cor é a nota.

![O mapa dos aviões](../docs/img/aeroopt/mapa.png)

Embaixo da tabela aparecem os gráficos do melhor avião até aqui: a decolagem, a aerodinâmica, a estabilidade e o
desempenho. Eles servem para conferir de relance se o avião que está ganhando faz sentido, e não ficam gravados.

![A tabela e o avião selecionado](../docs/img/aeroopt/tabela.png)

![A decolagem do melhor avião](../docs/img/aeroopt/melhor_decolagem.png)

![A aerodinâmica do melhor avião](../docs/img/aeroopt/melhor_aerodinamica.png)

## Como abrir

```sh
python -m aeroopt --exemplo                            # a janela com um projeto de exemplo
python -m aeroopt meu_projeto.json problema.opt.json   # partindo de um projeto da sprint
python tools/aeroopt.py problema.opt.json --etapas --projeto meu_projeto.json   # sem janela
python -m pytest -q tests/aeroopt                      # os testes
```

Um regulamento novo é um `.toml` novo em `pontuacao/`, com a fonte e um teste com uma nota calculada à mão.

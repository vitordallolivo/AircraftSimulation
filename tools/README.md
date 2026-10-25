# tools — ferramentas de linha de comando

Scripts que usam o programa (manager → núcleo) sem a GUI: imprimem, gravam tabelas e gráficos e servem de teste
rápido. Nenhum faz conta própria. O cálculo é do núcleo (`core/`) ou dos métodos de `aerosim/aero`; a ferramenta
orquestra e desenha. O que elas gravam (gráficos, tabelas, voos) fica fora do git, em `perfis/` ou na pasta que você
passar, e só as figuras escolhidas vão para `docs/img`.

## Otimizador (`tools/aeroopt.py`)

Roda um problema do aeroopt (`.opt.json`) pelo núcleo e imprime o melhor ponto, as grandezas e as restrições; com
`--png`, grava a convergência. `--isolar asa` (ou chaves e grupos separados por vírgula) deixa livres só essas
variáveis. Detalhes no [README do aeroopt](../aeroopt/README.md).

```sh
python tools/aeroopt.py --exemplo perfis/exemplo.opt.json
python tools/aeroopt.py perfis/exemplo.opt.json --isolar asa --png perfis/convergencia.png
```

## Paralelismo do otimizador (`tools/pipeline_bench.py`)

Compara as formas de rodar o processo em etapas do aeroopt em paralelo. O mesmo lote de configurações roda em série, em
threads e em processos (fork, spawn, forkserver), e a ferramenta imprime o tempo de cada etapa e o ganho sobre a série.
Ela também confere se cada estratégia deu o mesmo resultado da série. Da fração que não paraleliza (Karp e Flatt)
sai quanto de cada etapa fica preso ao GIL, a trava do Python que deixa só uma thread rodar código Python por vez.
`--png` grava o ganho por etapa.

```sh
python tools/pipeline_bench.py --exemplo
python tools/pipeline_bench.py --projeto p.json --problema q.opt.json --configs 12 --processos 2,4 --png perfis/bench.png
```

## Aerodinâmica e voo com cada modelo (`tools/aero/`)

Detalhes, comandos e resultados no [README da pasta](aero/README.md).

| ferramenta | o que faz |
|---|---|
| `aero/coeficientes.py` | os coeficientes de aviões simples, só superfícies, a 12 m/s, por todos os métodos: faixas, linha sustentadora (Phillips e Snyder; Goates e Hunsaker), lltdrek, ASB, AVL. Distância até qualquer referência, matriz entre os métodos, varredura de malha e de V, perfil por `.dat` |
| `aero/decolagem.py` | a decolagem da GUI reavaliada em cada instante com cada método, no mesmo estado: o erro de cada coeficiente no tempo |
| `aero/missao.py` | a decolagem ou a missão inteira **voada** com cada modelo (`ac.sim.aero_model`). Erro ao longo do percurso contra qualquer referência, mapa de proximidade dos voos, tempo de conta, voos em paralelo, `--carregar` sem voar de novo |
| `aero/casos.py` | os aviões de teste (retangulares, trapezoidal, enflechada, diedro, torcida, asa + EH, convencional) |

```sh
python tools/aero/coeficientes.py --matriz --pasta perfis/aero                       # coeficientes de todos os métodos
python tools/aero/decolagem.py --puro --metodos nucleo_gh,lltdrek,asb_vlm,avl --pasta perfis/decolagem
python tools/aero/missao.py --puro --ref faixas --ref llt_gh --pasta perfis/missao    # missão com cada modelo
python tools/aero/missao.py --carregar perfis/missao --ref tabela:avl                 # outra referência, sem voar
```

### Mapas de proximidade

Os três mapas medem o quanto cada método fica perto de cada outro, em três níveis.

```sh
python tools/aero/coeficientes.py --matriz --pasta perfis/aero                  # coeficientes (matriz.png)
python tools/aero/missao.py --puro --pasta perfis/missao                         # missão voada (matriz.png)
python tools/aero/missao.py --puro --analise decolagem --pasta perfis/decolagem  # decolagem voada
python tools/aero/missao.py --carregar perfis/missao                             # refaz o mapa sem voar de novo
```

**Coeficientes** (`coeficientes.py --matriz`): a mediana de |erro| (%) da linha tomando a coluna como referência, em
todos os casos e coeficientes. Não é simétrica, porque o erro relativo divide pelo valor da referência.

![proximidade dos métodos nos coeficientes](../docs/img/aero_matriz.png)

**Missão voada** (`missao.py`): o desvio médio do percurso (m) entre cada par de voos. É simétrico e independe do
tempo.

![proximidade dos voos na missão](../docs/img/aero_missao_matriz.png)

**Decolagem voada** (`missao.py --analise decolagem`):

![proximidade dos voos na decolagem](../docs/img/aero_decolagem_matriz.png)

**Leitura:**
- **Na missão, três grupos:**
  1. o núcleo (faixas, a tabela das faixas e as duas linhas sustentadoras), a menos de 1 m entre si;
  2. AVL, VLM e buildup do ASB, a ~1,5 m do núcleo;
  3. o lltdrek, sozinho, a ~3 m.
- **O lltdrek muda de lugar conforme o nível:** nos coeficientes da asa sozinha, ele fica a ~1 % da nossa linha
  sustentadora; no avião inteiro em voo, se afasta, porque o $`C_m`$ dele com a cauda é outro e ele não trata β.

### Tempo de conta

![tempo de conta por modelo na missão](../docs/img/aero_tempo.png)

Medido em sequência (`missao.py --jobs 1`), na missão de 165 s do `conventional`, cada modelo sozinho:

| modelo | tempo |
|---|---|
| faixas (`faixas`) | 4 s |
| faixas refinadas (`faixas_fino`) | 17 s |
| linha sustentadora de Phillips e Snyder (`llt`) | 261 s |
| linha sustentadora de Goates e Hunsaker (`llt_gh`) | 258 s |
| tabelas dos métodos de fora (`tabela:*`, com o cache em disco) | 3–9 s cada |
| **os 9 modelos** | **9 min 37 s** em sequência; 5 min 15 s em paralelo (`--jobs`, 4 núcleos) |

A linha sustentadora custa ~65× as faixas. Antes do cache da geometria, a missão levava 52 min com o `llt_gh` e
10 min com o `llt` (numa máquina anterior).

O que deixou a linha sustentadora rápida está em `core/OTIMIZACOES.md`.

## Validação

| ferramenta | o que faz |
|---|---|
| `validacao/navion.py` | o Ryan Navion montado com os números da NASA TN D-6643 e as derivadas de cada método contra as tiradas do voo |

## Cargas e modificadores

| ferramenta | o que faz |
|---|---|
| `span_load.py` | a carga ao longo das superfícies num ponto de operação, com e sem um modificador (ex.: a esteira) |
| `load_view.py` | a vista 3D da carga (superfícies pintadas, setas de força e de induzida, esteira); janela ou PNG (`xvfb-run`) |
| `modcheck.py` | a decolagem com os modificadores do avião e sem cada um, um de cada vez |
| `probe.py` | o módulo de modificadores do núcleo chamado direto, sem simulação: CSV e gráfico |

## Desempenho do programa

| ferramenta | o que faz |
|---|---|
| `time_profile.py` | onde uma análise gasta o tempo, no Python e no núcleo ao mesmo tempo (py-spy; `--exato` com o Callgrind): tabela por função e por módulo, flame graph |
| `opt_matrix.py` | as variantes do núcleo em avaliação (`-Dopt`), medidas por tempo ou por instruções e comparadas com o núcleo de sempre |

## Regressão, mapa do código e figuras

| ferramenta | o que faz |
|---|---|
| `checks/run.py` | os checks: núcleo, AeroDrive, mapa do código, regressão bit a bit dos exemplos contra a `main`, testes por área (`--tudo` inclui os lentos). Ver `checks/README.md` |
| `codemap.py` | refaz `docs/MAP.md` a partir do código (`--check` só confere) |
| `capturas.py` | fotos de todas as abas (roda cada simulação com os padrões) |
| `plot_comparativo.py` | as figuras das abas Aerodinâmica e Estabilidade, iguais às da GUI |

## Exemplos de projeto da sprint

| ferramenta | o que faz |
|---|---|
| `sprint_pasta.py` | converte um projeto antigo (um `.json` só) para a pasta nova, um arquivo por asa |
| `sprint_tres_caudas.py` | uma asa com três opções de superfícies, no formato de pasta |

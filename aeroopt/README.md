# aeroopt — o otimizador do projeto

Este é o otimizador do AircraftSimulation, o terceiro braço ao lado do `aerosim` (onde se projeta) e do `aerodrive`
(onde se voa). Aqui se descreve um problema de otimização (quais variáveis do avião podem mudar, entre que limites,
quais restrições valem e qual nota se quer maximizar), e dele sai o melhor avião encontrado, com todas as avaliações
guardadas para ver por que ele ganhou. As contas de cada candidato rodam no núcleo em Zig; esta pasta só lê o
problema, orquestra e mostra.

Um problema de otimização é sempre a mesma frase: escolher valores para as variáveis livres, dentro dos limites, de
modo que a nota seja a maior possível sem violar as restrições. Uma **variável de projeto** é o que se escolhe e se
constrói (envergadura, perfil, motor). Uma **consequência** é o que sai das contas (MTOW, PV, EE, corrida de
decolagem): ela entra na nota ou numa restrição, nunca como variável. Um **parâmetro** é o que o regulamento ou o
local impõem (densidade do ar, limite da bateria).

A pasta se divide em quatro partes, na ordem em que aparecem num uso: o problema e seu arquivo (`problem.py`), a
pontuação de cada regulamento (`scoring.py` e a pasta `pontuacao/`), os contratos que cada peça cumpre (em
`aerosim/interfaces/optim.py`) e as peças já ligadas a eles: o processo em etapas (`pipeline.py` e `stages.py`), que
é o caminho principal, e o mini-MDO do núcleo (`mini_mdo.py`), que fica como alternativa.

## O problema e o arquivo `.opt.json`

Aqui se define o problema inteiro num arquivo: as variáveis com tipo (contínua, inteira ou lista), limites e grupo;
as restrições (grandeza, operador, valor, ligada ou não); a nota; o avaliador; o solver e os parâmetros fixos. O
arquivo começa com `"formato": "aeroopt/1"`, e um formato desconhecido é recusado ao abrir.

`from_project` lê o problema que a página MDO de um projeto da sprint resolveria, e `apply_to_project` faz o caminho
de volta. Por isso o mesmo problema dá o mesmo resultado, bit a bit, pela GUI do aerosim ou pelo aeroopt.

### Isolar variáveis

Nem sempre se quer otimizar o avião inteiro. Às vezes a asa já está decidida e só se quer escolher a motorização, ou
o contrário. Cada variável tem um interruptor `free`: só as livres entram na busca, e as outras ficam no valor que o
avião já tem. `isolate` deixa livres só as variáveis ou os grupos citados (`asa`, `propulsão`, `requisitos`) e prende
o resto. É a mesma ideia de ligar e desligar partes no aerosim e no núcleo: o resto do avião não muda.

## A pontuação de cada regulamento

Aqui se escreve a nota de uma competição num arquivo de texto, um por regulamento e por ano, em `pontuacao/`. Trocar
de ano é trocar de arquivo, sem mexer em código. O arquivo declara as entradas (as grandezas que o avaliador entrega,
sempre em SI), as constantes, as faixas (degraus, como o fator de decolagem), os termos em ordem, a expressão da nota
e as condições de voo válido, que viram restrições do problema. Cada termo pode usar o que foi definido acima dele.
As expressões aceitam números, nomes, + − × / ^ e as funções min, max, exp e abs; qualquer outra coisa é recusada ao
abrir o arquivo, com a linha que falhou.

O `scoring.py` traduz o arquivo para um programa curto de pilha: as entradas ocupam as primeiras vagas, e cada
constante, faixa, termo, nota e condição ganha uma vaga, na ordem do arquivo. Quem executa o programa é o núcleo,
para que a mesma conta rode em lote, em paralelo e, no futuro, na GPU. Os termos ficam guardados, então a GUI pode
mostrar a nota de um avião fator por fator.

### SAE BRASIL AeroDesign 2026, classe Micro

O arquivo `pontuacao/sae_br_2026_micro.toml` segue o Regulamento SAE BRASIL AeroDesign 2026 Rev03, seção 9.8,
p. 86–87. A nota de missão de cada voo é a equação 9.1:

```math
P_M = F_{PV}\, F_{Bat}\, F_{PQ}\, F_{Dec}\, CP_M^{0{,}08} \left[\frac{0{,}095}{0{,}1 + e^{-EE}} + 0{,}4\right]
```

A carga conta pela pior das duas missões, porque o mesmo avião tem de fazer as duas (equação 9.2, com
$`EE = CP_M / PV`$):

```math
CP_M = 2 \min(C_{LAPES},\, C_{Liq})
```

O fator da bateria do motor (equação 9.4, $`P_{Bat}`$ em gramas) fica perto de 1 até uns 300 g e cai rápido depois:

```math
F_{Bat} = \max\left(0{,}2;\ \frac{0{,}85}{0{,}85 + \exp\left(\frac{P_{Bat} - 298}{37{,}7} - 4{,}8\right)}\right)
```

O fator de decolagem $`F_{Dec}`$ vale 250 até 1 m, 170 até 4 m e 110 até 8 m. A envergadura acima de 1800 mm perde
0,4 ponto por milímetro, até 50 mm (NC[9.6.0.1]). O $`F_{PV}`$ (acerto da previsão do PV) e o $`F_{PQ}`$ (abertura
do paraquedas) não dependem do projeto e ficam constantes; os bônus $`P_{AC}`$, $`B_{CF}`$ e $`B_{RC}`$ são pontos de
operação e ficam fora da nota otimizada.

## Os contratos

`aerosim/interfaces/optim.py` define as quatro peças. `OptProblem` é o problema. `IScoring` dá a nota a partir das
grandezas e diz a fonte da fórmula. `IEvaluator` transforma um candidato em grandezas, no núcleo. `ISolver` propõe
os candidatos e devolve um `OptResult` com todas as avaliações e a melhor. Uma peça nova (um regulamento de outro
ano, um avaliador de maior fidelidade, outro método) entra implementando o contrato, e quem usa não muda.

## O processo em etapas

Aqui se otimiza o avião seguindo o mesmo caminho da sprint, quebrado em etapas que todos os candidatos atravessam
juntos. Uma **etapa** trata cada candidato sem olhar os outros; a próxima só começa quando o último candidato chega
(a **barreira**). É essa espera que deixa paralelizar fácil: dentro de uma etapa cada candidato vai para um processo,
e depois da barreira a etapa já vê todos e escolhe quem segue. Sem a barreira, um candidato rápido chegaria à nota
antes de os outros serem dimensionados, e a escolha entre eles teria de esperar do mesmo jeito, só que espalhada
pelo código.

As etapas de hoje, em `stages.py`, são quatro. As **configurações** são as combinações das escolhas discretas livres
(motor, hélice, perfil, arranjo, número de motores): cada combinação vira um candidato, até 256. As **superfícies**
acertam, em cada configuração, as variáveis contínuas livres (envergadura, área, inclinação do motor) pela
decolagem. Cada ponto é o ponto de projeto acoplado do aerosim (`power.design_point`: a asa calada e a EH retrimada
com a tração, na massa que a pista deixa levar), e ganha o maior MTOW que fecha a estabilidade; a configuração que
não fecha para ali, com o motivo. A **decolagem 6GDL** refaz o MTOW de cada sobrevivente na simulação de seis graus
de liberdade (a aba Missão, modo MTOW), um processo por candidato. A **nota** calcula a pontuação de todos numa chamada
só ao núcleo.

As **categorias** (`categories.py`) dizem que tipo de avião a busca pode montar: asa alta, média ou baixa, parasol,
biplano, tandem, asa voadora e cauda em V. Cada categoria é um conjunto de campos da sprint que mudam juntos (a
altura da asa, a segunda asa com o recuo e o desnível dela, o tipo de cauda), e as que o problema escolhe
(`params["categorias"]`) viram mais um eixo das configurações: cada hélice, cada motor, uma vez em cada categoria. Sem
categoria escolhida, o avião fica como está no projeto. A altura da asa não muda o MTOW da corrida rápida (o efeito
solo é um modifier desligado por padrão); ela aparece no 6GDL, no trem e na vista 3D.

O otimizador das superfícies é a busca por coordenadas com passo que encolhe: tenta mais e menos um passo em cada
variável, aceita a primeira tentativa que melhora e, se nenhuma melhora, divide o passo por dois (Kolda, Lewis e
Torczon, *Optimization by direct search*, SIAM Review 45(3), 2003, seção 3, a conferir no PDF). Ela foi escolhida
porque o ponto de projeto tem saltos (viável ou não, decola ou não), então um método por derivada se perde, e porque
com duas ou três variáveis ela chega perto do melhor em poucas avaliações (24 por configuração, por padrão).

A nota da Micro precisa das duas cargas separadas. Com LAPES e líquido a bordo, a carga paga se divide igual entre as
duas, porque é o que dá o maior $CP_M = 2\min(C_{LAPES}, C_{Liq})$:

$$C_{LAPES} = C_{Liq} = \frac{MTOW - PV}{2}$$

O MTOW é o do 6GDL quando essa etapa roda, e o da pista quando não. A corrida $s_{TO}$ é a pista pedida no projeto e
$b$ é a envergadura.

Cada candidato que termina uma etapa chama `progress(fração, texto)`, então quem mostra o andamento (a linha de
comando hoje, a GUI depois) atualiza um candidato por vez. O `OptResult` traz uma linha por configuração (valores,
MTOW, MTOW 6GDL, nota, fatores, validade, os pontos que a busca visitou) e, em `names["etapas"]`, quantos entraram e
quantos seguiram em cada etapa.

## A janela

`python -m aeroopt [projeto.json] [problema.opt.json]` abre a janela do aeroopt (`gui.py`); `--exemplo` abre um
avião pequeno, perto da classe Micro, para ver tudo funcionando. Na esquerda se monta o problema. A pontuação mostra
tudo o que o `.toml` do regulamento tem (as entradas, as constantes, as faixas, os termos em ordem, a nota e as
condições de voo válido), em campos editáveis: o que se muda vale na próxima rodada, "Conferir no núcleo" traduz e
confere o programa, e "Gravar .toml…" grava um arquivo novo. Embaixo ficam as variáveis (livre ou fixa, limites,
opções das listas, botões para isolar um grupo), as categorias de avião e as opções das etapas: quantos pontos de
projeto a busca das superfícies gasta por configuração, quantos processos e se o MTOW passa pelo 6GDL.

Na direita se vê a rodada. A janela se atualiza a cada candidato que termina uma etapa, não a cada passo do
núcleo: é o bastante para ver a busca andar sem pesar a conta. A tabela das etapas conta quantos entraram, quantos
estão prontos e quantos seguiram. O gráfico da esquerda mostra o MTOW de cada ponto de projeto avaliado (cheio:
fecha a estabilidade; vazio: não fecha; no zero: não decola), e o da direita a nota de cada configuração na ordem
em que chegou, com a melhor até ali. O **mapa dos aviões** põe cada configuração no plano PV × carga paga, com as
linhas de eficiência estrutural constante (EE = CP/PV) e a cor pela nota; os eixos trocam para qualquer par (MTOW,
EE, nota, envergadura, bateria). Clicar num ponto do mapa ou numa linha da tabela mostra o avião em 3D, com as
entradas da nota, cada fator e cada condição de voo válido; "Gravar projeto com este avião…" leva os valores para os
rascunhos das etapas, num projeto novo.

A janela abre sem projeto nenhum: o avião sai dos rascunhos de um projeto novo da sprint (asa, empenagem e motores
como estão nas etapas), sem precisar guardar nada antes. As **restrições** ficam numa tabela como a de Condições e
restrições do aerosim (ligada, grandeza, operador, valor). A pista e o MTOW definem a busca, porque o MTOW é a maior
massa que corre na pista; as outras barram o ponto de projeto que não cumpre. Com o objetivo simples (MTOW ou EE)
no lugar do `.toml`, a rodada vira só "o maior MTOW que cumpre estas restrições".

Para ver o avião escolhido em tudo o que o aerosim já calcula (polar, estabilidade, desempenho, envelopes, missão
6GDL, cargas), "Abrir no aerosim" abre uma janela do aerosim com ele. O projeto dessa janela fica numa pasta própria
da rodada, então a sprint aberta no aerosim não é tocada.

Cada rodada grava o registro em `rodadas_aeroopt/<data_hora>/` (ao lado do projeto, fora do git), com dois CSV
(`export.py`). Em `avaliacoes.csv` vai um ponto de projeto por linha, na ordem de cada configuração: o número da
configuração e o da avaliação dentro dela, a categoria e as escolhas discretas, cada variável contínua, o MTOW na
pista, o PV, a envergadura, a bateria, se fecha e por que não. Em `configuracoes.csv` vai uma configuração por linha:
o melhor ponto dela, até que etapa chegou, o MTOW no 6GDL, as entradas da nota, cada fator, cada condição de voo
válido e a nota. O separador é `;` com vírgula decimal, que o Excel e o LibreOffice em português abrem direto; no
pandas, `pd.read_csv(arq, sep=";", decimal=",")`.

Os processos das etapas, quando a rodada sai da janela, nascem novos ("spawn"): não herdam as linhas de execução do
Qt. O 6GDL é a etapa mais lenta (dezenas de segundos por avião); o topo da bisseção na massa fica perto do MTOW da
pista (1,6 vez), o que corta voos sem mudar o resultado além da resolução da bisseção.

## O mini-MDO do núcleo

O primeiro avaliador e o primeiro solver são o mini-MDO que já existe em `core/src/sizing`: o PSO do núcleo propõe
cada candidato e a cadeia asa → envelope → decolagem → MTOW o avalia, tudo dentro do Zig. Aqui os dois são uma
chamada só (`sizing_optimize`). O problema é aplicado numa cópia do projeto, então o projeto do usuário não muda.

## Como chamar

```python
import aeroopt
from aerosim.design.project import DesignProject
from aeroopt.mini_mdo import MiniMdoEvaluator, MiniMdoSolver

projeto = DesignProject()
pr = aeroopt.from_project(projeto, "só a envergadura")
for v in pr.variables:
    if v.key == "wing.span":
        v.lo, v.hi = 1.2, 1.8
pr.isolate("wing.span")
pr.solver.update(particles=8, iterations=5)
res = MiniMdoSolver().run(pr, MiniMdoEvaluator(projeto))
print(res.best["score"], sorted({round(r["span"], 3) for r in res.rows})[:3])
aeroopt.save(pr, "envergadura.opt.json")
```

A pontuação de um regulamento, lida e traduzida:

```python
from aeroopt.scoring import scoring_for, listing

sc = scoring_for("sae_br_2026_micro")
print(sc.name, sc.quantities())
print(listing(sc.program()).splitlines()[:7])
```

O processo em etapas parte dos rascunhos de um projeto da sprint (com um conjunto guardado na etapa Empenagem):

```python
import aeroopt
from aerosim.design.project import DesignProject
from aeroopt.stages import StagedEvaluator, StagedSolver

projeto = DesignProject.load("meu_projeto.json")
pr = aeroopt.from_project(projeto, "Micro 2026")
pr.scoring = "sae_br_2026_micro"
pr.isolate("wing.span", "power.propeller")
res = StagedSolver().run(pr, StagedEvaluator(projeto), progress=lambda f, t: print(f"{f:4.0%} {t}"))
print(res.best["name"], res.best["nota"], res.names["etapas"])
```

Pela linha de comando, `tools/aeroopt.py` roda um `.opt.json`, imprime o melhor ponto e as restrições e grava a
convergência (`--png`); `--isolar` escolhe as variáveis livres na hora:

```sh
python tools/aeroopt.py --exemplo perfis/exemplo.opt.json
python tools/aeroopt.py perfis/exemplo.opt.json --isolar asa --png perfis/convergencia.png
python tools/aeroopt.py perfis/exemplo.opt.json --etapas --projeto meu_projeto.json --processos 4
python tools/aeroopt.py perfis/exemplo.opt.json --etapas --projeto meu_projeto.json --categorias "asa alta,biplano,asa voadora"
```

Uma etapa nova é uma classe que implementa `IStage` (`one` para um candidato, ou `batch = True` e `run` para o lote,
e `select` para escolher quem segue) e entra na lista de `StagedEvaluator.stages`.

Testes: `python -m pytest -q tests/aeroopt`. Um regulamento novo é um `.toml` novo em `pontuacao/`, com a fonte na
chave `fonte` e um teste com uma nota calculada à mão. Para acrescentar outra peça, escreva uma classe que implemente o contrato
de `aerosim/interfaces/optim.py` e um teste em `tests/aeroopt`.

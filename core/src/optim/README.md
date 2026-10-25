# core/src/optim — as contas do aeroopt no núcleo

Esta é a parte do núcleo que o otimizador (`aeroopt/`) usa. Aqui se executa a nota de um candidato: o arquivo de
pontuação de um regulamento vira, no Python, um programa curto, e este código o roda para um candidato ou para
milhares de uma vez, sem alocar memória. Dele sai a nota e cada termo dela (os fatores), para a GUI mostrar por que um
avião ganhou.

Aqui também nascem as gerações de aviões: o algoritmo genético que escolhe quais configurações o aeroopt avalia. E o
CMA-ES, a outra busca das variáveis contínuas (envergadura, área, diedro...).

A pasta tem quatro partes: os tipos do programa (`types.zig`), quem o confere e executa (`expr.zig`), as gerações
(`ga.zig`) e o CMA-ES (`cmaes.zig`). A álgebra linear que os solvers vão usar fica em `../math/linalg.zig`.

## O programa

Aqui se define uma nota com até 256 operações, 64 constantes, 64 vagas e 8 faixas de até 8 degraus. O programa é uma
lista de operações de pilha: empilhar uma constante ou uma vaga, guardar o topo numa vaga, as quatro operações, a
potência, o mínimo, o máximo, a exponencial, o valor absoluto e a faixa. As entradas do candidato ocupam as primeiras
vagas, e cada vaga é escrita uma vez só, na ordem do arquivo de pontuação.

Uma faixa é uma função em degraus, como o fator de decolagem da Micro 2026: o primeiro limite com x ≤ limite dá o
valor; acima de todos, ou com x inválido (NaN), vale o valor "fora".

`check` confere o programa uma vez: índices que existem, operação conhecida, pilha que não falta nem estoura, vaga
lida só depois de escrita e escrita uma vez. Depois, `run` e `runMany` só fazem contas. As funções são as da std
(`@exp`, `std.math.pow`), e não as tabelas do `fmath`, porque a nota tem de sair igual à conta à mão do regulamento.

## As gerações

Aqui se define um indivíduo com até 32 genes e uma geração de até 256 indivíduos. Um gene discreto é o índice de uma
opção (`card` > 0 opções) e um gene real é um valor em `[lo, hi]`. `init` sorteia a primeira geração; `next` recebe a
geração e a nota de cada indivíduo (NaN para quem morreu) e devolve a seguinte. Os `elite` melhores passam iguais. Os
pais são sorteados pela posição na fila: com $n$ indivíduos, o $i$-ésimo melhor ($i = 0$ é o melhor) sai com peso

$$w_i = n - i$$

e por isso a escala da nota não importa, só a ordem (Baker, 1985, descrito em Goldberg, *Genetic Algorithms in Search,
Optimization and Machine Learning*, 1989; capítulo e página a conferir no PDF). Com probabilidade `p_cross`, os genes até um
ponto de corte sorteado vêm de um pai e o resto do outro. Depois, cada gene muda com probabilidade `p_mut`: o
discreto vira outra opção qualquer, e o real anda um sorteio normal de desvio $\sigma (hi - lo)$, preso aos limites.
Os sorteios saem de uma semente (`seed` e `generation`), então a mesma entrada dá a mesma geração.

## O CMA-ES

Aqui se define uma busca em até 32 variáveis contínuas, com até 64 pontos por geração. O CMA-ES é a estratégia
evolutiva com adaptação da matriz de covariância. O algoritmo genético muda cada gene por conta própria, com um sorteio
do mesmo tamanho em toda direção. Quando duas variáveis só melhoram a nota juntas, ele quase nunca acerta as duas de
uma vez. Por exemplo, aumentar a envergadura só ajuda se a área cresce junto. Já o CMA-ES sorteia cada geração de uma
nuvem com forma de elipse e aprende essa forma com os melhores pontos. A elipse se alonga na direção em que a nota
melhora e encolhe onde ela piora, então a busca passa a andar pelo vale que acopla as variáveis. As contas são as do
tutorial de Hansen (*The CMA Evolution Strategy: A Tutorial*, arXiv:1604.00772, 2016, tabela 1 e equações da seção
4; números das equações a conferir no PDF). A fonte das constantes padrão é a mesma tabela.

As variáveis entram normalizadas em $[0, 1]$: o Python divide cada uma pela faixa dela. `init` recebe a média inicial
$m$ (o avião de partida), o passo $\sigma$ e o tamanho $\lambda$ da geração; com $\lambda \le 0$ vale o padrão
$4 + \lfloor 3 \ln n \rfloor$. `ask` sorteia a geração:

$$x_k = m + \sigma\, B D z_k, \qquad z_k \sim \mathcal{N}(0, I),$$

onde $C = B D^2 B^\top$ é a matriz de covariância, decomposta em autovetores $B$ e raízes dos autovalores $D$ (Jacobi
cíclico, `linalg.symEigen`). O ponto que cai fora da caixa é levado para a borda, e é ele que se avalia.

`tell` recebe a nota de cada ponto (maior é melhor; NaN é o pior) e ordena a geração. A nova média é a soma ponderada
dos $\mu = \lambda/2$ melhores, com pesos $w_i \propto \ln\frac{\lambda+1}{2} - \ln i$ que somam 1:

$$m' = \sum_{i=1}^{\mu} w_i\, x_{i:\lambda}.$$

O passo $\sigma$ cresce quando as gerações andam várias vezes na mesma direção e diminui quando elas andam e voltam. Quem
mede isso é o caminho de evolução $p_\sigma$, a soma com memória dos passos da média, medidos em unidades de $C$:

$$p_\sigma \leftarrow (1 - c_\sigma)\, p_\sigma + \sqrt{c_\sigma (2 - c_\sigma)\, \mu_{\mathrm{eff}}}\; C^{-1/2}\, \frac{m' - m}{\sigma},
\qquad \sigma \leftarrow \sigma \exp\!\left(\frac{c_\sigma}{d_\sigma}\left(\frac{\lVert p_\sigma\rVert}{E\lVert\mathcal{N}(0,I)\rVert} - 1\right)\right).$$

A forma da nuvem se aprende de dois jeitos. O caminho $p_c$ guarda a direção em que a média vem andando (atualização de
posto um). Os passos dos $\mu$ melhores desta geração dão a outra parte (atualização de posto $\mu$):

$$C \leftarrow (1 - c_1 - c_\mu)\, C + c_1\, p_c p_c^\top + c_\mu \sum_{i=1}^{\mu} w_i\, y_i y_i^\top, \qquad y_i = \frac{x_{i:\lambda} - m}{\sigma}.$$

O $h_\sigma$ do tutorial interrompe o $p_c$ quando $p_\sigma$ fica longo demais, e o termo que ele tira volta somado a
$C$. O passo fica preso em $[10^{-8}, 1]$. Os sorteios saem de `seed` e da geração, então a mesma entrada dá a mesma
busca. Os produtos escalares e as somas de linha usam vetores do Zig (`@Vector`, do tamanho que a máquina sugere):
com `-Dcpu=native` numa máquina com AVX-512 eles viram instruções de 512 bits.

O teste confere uma elipse de 8 variáveis com escala de 1 a 1000 entre os eixos, o vale de Rosenbrock, a semente, a
caixa e a simetria de $C$. A conta foi comparada à da `pycma`, que é a implementação de referência do mesmo autor,
na mesma elipse, com a mesma população e o mesmo número de avaliações: as duas chegam ao mesmo resultado.

## Como chamar

Pela ABI: `aerosim_expr_check(programa)` e `aerosim_expr_eval(programa, entradas, passo, linhas, saída, passo)`,
que confere antes e devolve um código negativo (`expr.Error`) se o programa for recusado. No Python:

```python
from aeroopt.scoring import evaluate, scoring_for

r = evaluate(scoring_for("sae_br_2026_micro"),
             dict(c_lapes=1.0, c_liq=1.2, pv=0.5, m_bat=0.30, s_to=3.5, b=1.8))[0]
print(round(r["nota"], 2), {k: round(v, 3) for k, v in r["termos"].items()}, r["valido"])
```

As gerações: `aerosim_ga_init(cfg, saída)` e `aerosim_ga_next(cfg, genes, notas, saída)`, com a `GaCfg`; no Python,
`ZigBackend().ga_init(cfg)` e `ga_next(cfg, genes, notas)`, que o `aeroopt/generations.py` usa.

O CMA-ES: `aerosim_cma_init(estado, n, x0, sigma0, lambda, seed)` (devolve λ ou um código negativo),
`aerosim_cma_ask(estado, saída)` e `aerosim_cma_tell(estado, pontos, notas)`, com a `CmaState`, que guarda tudo
entre uma geração e a outra. No Python:

```python
from aerosim.backend.zig import ZigBackend

be = ZigBackend()
st = be.cma_init([0.2, 0.2, 0.2], 0.3)
for _ in range(60):
    X = be.cma_ask(st)                                  # λ × n em [0, 1]
    be.cma_tell(st, X, -((X - 0.7) ** 2).sum(axis=1))   # maior é melhor
print(st.mean[:3], st.sigma)                            # ≈ 0,7 0,7 0,7, passo pequeno
```

Testes: `python -m ziglang build test-optim` (dentro de `core/`) e `python -m pytest -q tests/aeroopt`. Uma operação
nova entra no enum `Op`, em `check`, em `run` e no compilador `aeroopt/scoring.py`, com o mesmo código nos dois lados.

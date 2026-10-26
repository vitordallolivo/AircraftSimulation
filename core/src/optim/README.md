# core/src/optim — as contas do aeroopt no núcleo

Esta é a parte do núcleo que o otimizador (`aeroopt/`) usa. Aqui se executa a nota de um candidato: o arquivo de
pontuação de um regulamento vira, no Python, um programa curto, e este código o roda para um candidato ou para
milhares de uma vez, sem alocar memória. Dele sai a nota e cada termo dela (os fatores), para a GUI mostrar por que um
avião ganhou.

Aqui também nascem as gerações de aviões: o algoritmo genético que escolhe quais configurações o aeroopt avalia. E o
CMA-ES, a outra busca das variáveis contínuas (envergadura, área, diedro...). Depois da busca, o modelo local e os outros métodos da
sensibilidade dizem o quanto a nota do melhor avião muda em volta dele.

A pasta tem oito partes: os tipos do programa (`types.zig`), quem o confere e executa (`expr.zig`), as gerações
(`ga.zig`), o CMA-ES (`cmaes.zig`), a evolução diferencial (`de.zig`), o hipercubo latino de onde nascem as
populações (`sampling.zig`), o modelo local (`localfit.zig`) e os outros métodos da sensibilidade (`sensmethods.zig`). A álgebra linear que os solvers vão usar fica em `../math/linalg.zig`.

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

Aqui se define uma busca em até 32 variáveis contínuas (envergadura, área, diedro, VH...), com até 64 aviões por
geração. A busca recebe o avião de partida e devolve, geração a geração, aviões cada vez melhores. Quem avalia cada
avião é o Python (o ponto de projeto do aeroopt), e o núcleo só decide quais aviões experimentar em seguida.

### Por que outro método além das gerações

O algoritmo genético das gerações mexe em cada variável por conta própria. Cada gene muda com um sorteio do mesmo
tamanho, sem olhar para os outros. Isso funciona quando cada variável tem o seu melhor valor, independente das
outras. No avião não costuma ser assim. Aumentar a envergadura só ajuda se a área cresce junto (senão a corda fica
fina demais), e um VH maior só ajuda com o braço da cauda certo. Nesses casos a região boa é um vale estreito e
inclinado entre as variáveis. Um sorteio que mexe numa variável de cada vez cai fora do vale quase sempre, então o
genético gasta a maior parte das avaliações em aviões piores.

O CMA-ES (*Covariance Matrix Adaptation Evolution Strategy*, a estratégia evolutiva com adaptação da matriz de
covariância) resolve isso aprendendo a forma do vale. Ele sorteia cada geração de uma nuvem em forma de elipse e,
depois de ver quais aviões foram melhores, gira e estica a elipse ao longo da direção em que a nota sobe. Depois de
algumas gerações, os sorteios saem quase todos dentro do vale. As contas e as constantes são as do tutorial de
Hansen (*The CMA Evolution Strategy: A Tutorial*, arXiv:1604.00772, 2016, seção 4 e tabela 1; números das equações
a conferir no PDF), na versão com pesos positivos.

### O que o estado guarda

Tudo o que a busca sabe fica na `CmaState`, que o Python segura entre uma geração e a outra. O estado é uma struct
de tamanho fixo, sem alocação. Nele estão a média $m$ (o centro da nuvem, onde a busca acha que está o melhor
avião), o passo $\sigma$ (o tamanho da nuvem) e a matriz de covariância $C$ (a forma dela: quanto a nuvem se
estende em cada direção e como as variáveis andam juntas). Também guarda dois caminhos de evolução, $p_\sigma$ e
$p_c$, que são a memória de para onde a média andou nas últimas gerações. E guarda $B$ e $D$, a decomposição de
$C$ que o sorteio usa.

As variáveis entram normalizadas em $[0, 1]$: o Python divide cada uma pela faixa dela. Assim um passo de 0,1 vale o
mesmo para uma envergadura de metros e um diedro de graus, e um só $\sigma$ serve para todas.

### As constantes

`init` calcula as constantes a partir do número de variáveis $n$, todas da tabela 1 do tutorial. O tamanho da
geração é

$$\lambda = 4 + \lfloor 3 \ln n \rfloor,$$

a não ser que o Python peça outro (o aeroopt usa o mesmo tamanho das gerações, para comparar os dois métodos com o
mesmo total de avaliações). Dos $\lambda$ aviões, os $\mu = \lfloor \lambda / 2 \rfloor$ melhores entram nas contas. Eles
entram com pesos que caem com a posição: o melhor pesa mais, o $\mu$-ésimo pesa quase nada. Os pesos somam 1:

$$w_i = \frac{\ln\frac{\lambda + 1}{2} - \ln i}{\sum_{j=1}^{\mu} \left(\ln\frac{\lambda + 1}{2} - \ln j\right)}, \qquad i = 1 \ldots \mu.$$

Com pesos diferentes, a média não vale $\mu$ aviões. O número efetivo de aviões que a média representa é

$$\mu_{\mathrm{eff}} = \frac{1}{\sum_i w_i^2},$$

e as outras constantes dependem dele e de $n$. As taxas de aprendizado dizem quanto uma geração muda o que se sabe:
$c_\sigma$ para o passo, $c_c$ para o caminho $p_c$, $c_1$ e $c_\mu$ para a forma de $C$:

$$c_\sigma = \frac{\mu_{\mathrm{eff}} + 2}{n + \mu_{\mathrm{eff}} + 5}, \qquad c_c = \frac{4 + \mu_{\mathrm{eff}}/n}{n + 4 + 2\mu_{\mathrm{eff}}/n},$$

$$c_1 = \frac{2}{(n + 1{,}3)^2 + \mu_{\mathrm{eff}}}, \qquad c_\mu = \min\!\left(1 - c_1,\; \frac{2\,(\mu_{\mathrm{eff}} - 2 + 1/\mu_{\mathrm{eff}})}{(n + 2)^2 + \mu_{\mathrm{eff}}}\right).$$

Com mais variáveis, as taxas caem: há mais a aprender, e cada geração traz menos informação por direção. O
amortecimento do passo $d_\sigma$ freia a mudança de $\sigma$ para ela não oscilar. O $E\lVert\mathcal{N}(0, I)\rVert$
é o comprimento médio de um sorteio normal em $n$ dimensões, a régua que diz se a média andou muito ou pouco:

$$d_\sigma = 1 + 2 \max\!\left(0,\; \sqrt{\frac{\mu_{\mathrm{eff}} - 1}{n + 1}} - 1\right) + c_\sigma, \qquad E\lVert\mathcal{N}(0, I)\rVert \approx \sqrt{n}\left(1 - \frac{1}{4n} + \frac{1}{21 n^2}\right).$$

No começo, $C$ é a identidade (a nuvem é uma esfera), a média é o avião de partida e $\sigma$ é o passo que o Python
pede (o aeroopt usa 0,3, ou seja, 30 % da faixa de cada variável).

### Uma geração: sortear (`ask`)

Cada avião da geração sai de um sorteio normal $z_k$ de $n$ números independentes. O sorteio é esticado por $D$,
girado por $B$, escalado por $\sigma$ e somado à média:

$$x_k = m + \sigma\, B D z_k, \qquad z_k \sim \mathcal{N}(0, I), \qquad k = 1 \ldots \lambda.$$

$B$ e $D$ vêm de $C = B D^2 B^\top$. As colunas de $B$ são os eixos da elipse, e $D$ é o comprimento de cada eixo
(a raiz do autovalor). Por isso $B D z$ é um sorteio com a forma de $C$. O código faz isso em duas linhas: primeiro
`dz = D·z`, depois cada componente $x_i$ é o produto escalar da linha $i$ de $B$ com `dz`.

O avião que sai da caixa $[0, 1]$ é levado para a borda. É esse avião, já na borda, que se avalia e que volta para o
`tell`, para a média nunca aprender com um ponto que não existe. Os sorteios saem da semente e do número da
geração, então a mesma entrada dá sempre a mesma busca, e o `ask` pode ser chamado de novo sem mudar nada.

### Uma geração: aprender (`tell`)

O Python devolve a nota de cada avião (maior é melhor; NaN, que é o avião que não fecha, conta como o pior). O
`tell` ordena a geração do melhor para o pior e faz quatro coisas, nesta ordem.

**1. A média anda.** A nova média é a soma ponderada dos $\mu$ melhores, onde $x_{i:\lambda}$ é o $i$-ésimo melhor da
geração:

$$m' = \sum_{i=1}^{\mu} w_i\, x_{i:\lambda}.$$

O passo da média, medido em unidades de $\sigma$, é $y_w = (m' - m)/\sigma$. É dele que saem as outras três
atualizações.

**2. O passo se ajusta.** A ideia é olhar se as gerações recentes andaram para o mesmo lado. Se a média anda várias
vezes na mesma direção, a nuvem está pequena demais e a busca está perdendo tempo: o passo cresce. Se ela anda e
volta, os passos se cancelam, a nuvem está grande demais e pula por cima do melhor: o passo diminui. A soma com
memória desses passos é o caminho $p_\sigma$:

$$p_\sigma \leftarrow (1 - c_\sigma)\, p_\sigma + \sqrt{c_\sigma (2 - c_\sigma)\, \mu_{\mathrm{eff}}}\; C^{-1/2}\, y_w.$$

O $C^{-1/2}$ tira a forma da elipse do passo, para o comprimento de $p_\sigma$ só depender de quanto a média andou e
não da direção. O código calcula $C^{-1/2} y_w = B D^{-1} B^\top y_w$ em duas etapas: $t = D^{-1} B^\top y_w$ e depois
$B t$. Com $p_\sigma$ em mãos, o passo cresce ou diminui conforme o comprimento dele passa ou não da régua:

$$\sigma \leftarrow \sigma \exp\!\left(\frac{c_\sigma}{d_\sigma}\left(\frac{\lVert p_\sigma\rVert}{E\lVert\mathcal{N}(0, I)\rVert} - 1\right)\right).$$

No código, $\sigma$ fica preso em $[10^{-8}, 1]$. Um passo maior que a caixa inteira não faz sentido, e um passo
zerado travaria a busca.

**3. A direção recente entra na forma.** O caminho $p_c$ é como $p_\sigma$, mas sem tirar a forma: ele guarda a
direção em que a média vem andando.

$$p_c \leftarrow (1 - c_c)\, p_c + h_\sigma \sqrt{c_c (2 - c_c)\, \mu_{\mathrm{eff}}}\; y_w.$$

O $h_\sigma$ vale 1 normalmente e 0 quando $p_\sigma$ está longo demais, ou seja, quando o passo acabou de crescer
muito. Nessas gerações a média anda rápido porque $\sigma$ estava pequeno, e não porque a forma estava errada, e
deixar $p_c$ crescer esticaria $C$ à toa. O teste é

$$h_\sigma = 1 \iff \frac{\lVert p_\sigma\rVert}{\sqrt{1 - (1 - c_\sigma)^{2(g+1)}}} < \left(1{,}4 + \frac{2}{n + 1}\right) E\lVert\mathcal{N}(0, I)\rVert,$$

onde $g$ é o número da geração. A raiz no denominador corrige o começo, quando $p_\sigma$ ainda não teve tempo de
crescer.

**4. A forma se ajusta.** A matriz $C$ aprende de dois jeitos ao mesmo tempo. A atualização de posto um usa $p_c$, a
direção das últimas gerações. A atualização de posto $\mu$ usa os passos $y_i$ dos $\mu$ melhores desta geração, a
direção em que os bons aviões estão agora. O resto de $C$ é a memória do que já se sabia:

$$C \leftarrow \left(1 - c_1 - c_\mu + (1 - h_\sigma)\, c_1 c_c (2 - c_c)\right) C + c_1\, p_c p_c^\top + c_\mu \sum_{i=1}^{\mu} w_i\, y_i y_i^\top, \qquad y_i = \frac{x_{i:\lambda} - m}{\sigma}.$$

O termo com $(1 - h_\sigma)$ devolve para $C$ o que se perdeu quando $h_\sigma$ cortou $p_c$. Cada $p_c p_c^\top$ e
$y_i y_i^\top$ é uma matriz que estica a elipse na direção daquele vetor. Por isso, depois de algumas gerações, a
elipse fica alongada ao longo do vale.

Por último, $C$ volta a ser decomposta em $B$ e $D$ para o próximo `ask`. Antes da decomposição, o código usa a média
de $C$ com a transposta dela, para tirar o arredondamento que a deixaria levemente assimétrica. A decomposição é o
Jacobi cíclico de `../math/linalg.zig` (`symEigen`, descrito no README da `math`). Um autovalor que o arredondamento
deixa negativo vira $10^{-20}$ antes da raiz, para $D$ nunca ser zero.

### Vetores e AVX-512

As contas que se repetem são produtos escalares (no sorteio e em $C^{-1/2} y_w$) e somas de uma linha com um vetor
vezes um número (na média e nas atualizações de $C$). As duas usam `@Vector` do Zig, em blocos do tamanho que a
máquina sugere (`std.simd.suggestVectorLength`), e terminam as posições que sobram uma a uma. Com o build padrão
(x86-64-v3) os blocos são de 4 números (AVX2). Com `-Dcpu=native` numa máquina com AVX-512, são de 8 (512 bits). O
resultado é o mesmo nos dois casos, a menos da ordem das somas.

### O que os testes conferem

O primeiro teste maximiza uma elipse de 8 variáveis com escala de 1 a 1000 entre os eixos (o caso mal condicionado,
em que um passo do mesmo tamanho em toda direção não chega) e o vale curvo de Rosenbrock em 4 variáveis. Os dois
precisam chegar ao máximo com um total fixo de avaliações. O segundo confere que a mesma semente dá a mesma geração,
que todo ponto fica na caixa, que um NaN na nota não quebra a ordenação e que $C$ continua simétrica e com $D > 0$.
A conta também foi comparada à `pycma`, a implementação de referência do mesmo autor. Na mesma elipse, com a mesma
população e o mesmo total de avaliações, as duas chegam a resultados parecidos.

## A evolução diferencial

Aqui se define a terceira busca das variáveis contínuas, em até 32 variáveis e 64 aviões por geração. O genético muta
cada gene com um sorteio de tamanho fixo, e o CMA-ES aprende a forma da região boa com uma matriz. A evolução
diferencial fica no meio: ela tira o tamanho do passo da própria população, sem matriz nenhuma. Para cada avião
$x_i$, o avião de teste soma a um avião sorteado a diferença entre outros dois,

$$v = x_{r_1} + F\,(x_{r_2} - x_{r_3})$$

e cada gene do teste vem de $v$ com probabilidade CR (pelo menos um vem sempre), senão de $x_i$. O teste só entra no
lugar de $x_i$ se a nota dele não for pior. Com a população espalhada as diferenças são grandes e a busca explora;
com ela junta perto do ótimo, as diferenças encolhem e a busca refina, sem um passo para ajustar. É o DE/rand/1/bin
de Storn e Price (J. Global Optimization 11, 341–359, 1997, a conferir no PDF), com F = 0,5 e CR = 0,9, os valores
de partida do artigo. As variáveis entram em [0, 1], e o gene que sai da caixa vai para a borda. Os testes conferem a
esfera e o vale de Rosenbrock com um total fixo, que o teste fica na caixa, que a mesma semente dá os mesmos testes e
que a seleção não piora ninguém.

## O hipercubo latino

Aqui se sorteiam os primeiros indivíduos de uma busca de modo que cada variável seja varrida de ponta a ponta, até
32 variáveis e 256 pontos. O problema que isso resolve: as buscas contínuas do aeroopt começam com x0 e poucos
indivíduos (de 4 a 10) em 12 ou mais variáveis. Sorteados um a um, uniformes, eles se amontoam, e várias variáveis
ficam com todos os valores numa parte da faixa; se o ponto bom de f(x, u) está na parte que ninguém visitou, a busca
fica presa num mínimo local perto de x0, e a resposta depende da semente.

Com m pontos, a faixa de cada variável é cortada em m fatias iguais, e cada fatia recebe exatamente um ponto. A ordem
das fatias é uma permutação $\pi_j$ sorteada por variável, e dentro da fatia a posição é sorteada (McKay, Beckman e
Conover, Technometrics 21(2), 1979, a conferir no PDF):

$$x_{ij} = \frac{\pi_j(i) + U_{ij}}{m}, \qquad U_{ij} \sim \mathcal{U}(0, 1)$$

Um hipercubo latino ainda pode sair ruim no conjunto, com os pontos alinhados numa diagonal. Por isso se sorteiam
`tries` deles e fica o de maior distância mínima entre dois pontos, o critério maximin (Morris e Mitchell, J.
Statistical Planning and Inference 43, 1995, a conferir no PDF). Os testes conferem que cada fatia tem um ponto, que
a mesma semente dá os mesmos pontos, que o maximin não afasta menos que um sorteio só e que, em 12 variáveis com 8
pontos, o sorteio uniforme deixa fatias vazias e o latino não.

## O modelo local

Aqui se ajusta, em até 32 variáveis, um modelo da nota em volta de um ponto $x_0$ a partir de pontos já avaliados.
Ele é a sensibilidade do melhor avião (`aeroopt/sensitivity.py`). Sem ele, saber o quanto a nota muda com cada
variável pedia refazer o avião em dois pontos por variável, e cada ponto de projeto é caro. Só que a busca das
superfícies já passou por vários pontos perto do melhor, e eles carregam essa informação: o modelo que melhor passa
por eles dá a inclinação e a curvatura de graça.

O modelo tem a inclinação $g$ e uma curvatura $c_k$ por variável, sem os termos cruzados, para que os pontos de uma
busca por coordenadas, que anda um eixo por vez, bastem:

$$y \approx a + g^T (x - x_0) + \tfrac12 \sum_k c_k (x_k - x_{0k})^2$$

A curvatura importa porque no alto do morro a inclinação é zero e não diz quanto se perde ao sair dali. Os
coeficientes saem dos mínimos quadrados ponderados, pelas equações normais resolvidas por Cholesky (Björck,
*Numerical Methods for Least Squares Problems*, SIAM 1996, seções 1.1 e 4.1, a conferir no PDF), com cada coluna
escalada antes, porque pontos muito perto de $x_0$ deixam a matriz mal condicionada:

$$\min_{a, g, c} \sum_i w_i \left(y_i - \hat y_i\right)^2, \qquad w_i = \left(1 - (d_i / r)^3\right)^3 \ \text{se}\ d_i < r,\quad 0\ \text{fora}$$

O peso tricúbico, com $d_i$ a distância de $x_i$ a $x_0$ nas variáveis normalizadas, faz os pontos de perto mandarem
e os de fora do raio $r$ não contarem. É o peso da regressão local de Cleveland e Devlin (JASA 83(403), 1988, a
conferir no PDF). Uma nota NaN é ignorada. Quando os pontos não abrem todas as direções (uma variável que a busca não mexeu, ou
só dois valores dela para a curvatura), um pivô de Cholesky some e a conta devolve que não dá. Quem chama então
avalia só as direções que faltam. Os testes conferem um plano exato, uma parábola (inclinação zero no topo e
curvatura exata mesmo com pontos de um lado só), os pontos de uma busca por coordenadas e as direções que faltam.

## A tolerância e Morris

Aqui se tira, das mesmas inclinações e curvaturas, o que uma tolerância de fabricação faz com a nota, e se fazem as
trajetórias de Morris, em até 32 variáveis e 64 trajetórias.

A tolerância responde "posso construir com 1 cm de diferença na envergadura?". Com uma diferença $\delta_k$ em cada
medida, a nota muda de cada lado pela série de Taylor, e, tomando $\delta_k$ como o desvio padrão de uma medida
normal e independente das outras, a dispersão da nota sai dos dois primeiros momentos (Putko, Taylor, Newman e
Green, NASA/AIAA 2001-2528, a conferir no PDF):

$$\Delta N^\pm_k = \pm g_k \delta_k + \tfrac12 c_k \delta_k^2, \qquad \sigma_N^2 \approx \sum_k (g_k \delta_k)^2 + \tfrac12 \sum_k (c_k \delta_k^2)^2$$

A elasticidade $e_k = g_k x_k / N$ diz quantos por cento a nota muda com 1 % da medida, e deixa comparar a
envergadura (em metros) com a área (em metros quadrados).

O modelo local olha o ponto; Morris olha a região em volta dele. Ele resolve o caso em que uma variável muda de
efeito de um lugar para outro (uma curvatura forte ou uma interação com outra variável), que a inclinação no ponto
esconde. São r trajetórias de k + 1 pontos numa grade de p níveis, e cada passo mexe uma variável só, em
$\Delta = p / (2(p-1))$. O efeito de cada passo é

$$EE_k = \frac{y(x + \Delta e_k) - y(x)}{\Delta}$$

e de cada variável saem a média $\mu$, a média do módulo $\mu^*$, que não deixa efeitos de sinais opostos se
cancelarem, e o desvio $\sigma$, que acusa a curvatura ou a interação (Morris, Technometrics 33(2), 1991; o $\mu^*$
é de Campolongo, Cariboni e Saltelli, Environmental Modelling & Software 22, 2007; ambos a conferir no PDF). Um ponto
que não vale (NaN) tira os dois passos que o usam. Os testes conferem a perda de uma parábola e de uma reta, e, numa
função sabida, que cada passo mexe uma variável só e que $\mu$ e $\sigma$ saem certos.

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

A evolução diferencial: `aerosim_de_init(n, np, x0, semente, saída)`, `aerosim_de_trials(n, np, população, F, CR,
semente, geração, saída)` e `aerosim_de_select(n, np, população, notas, testes, notas dos testes)`. No Python,
`be.de_init(x0, np)`, `be.de_trials(pop, 0.5, 0.9, seed, gen)` e `be.de_select(pop, fit, trial, tfit)`, que o
`aeroopt/stages.py` (`_de_search`) usa.

O hipercubo latino: `aerosim_lhs(n, m, tries, semente, saída)`, m × n pontos em [0, 1], −1 se não cabe. No Python,
`be.lhs(n, m, tries, seed)`, que `_real_search` e `_de_search` usam com `init="lhs"`.

O modelo local: `aerosim_local_fit(n, m, pontos, valores, x0, r, quad, g, c, saída)`, com saída = (a, resíduo, soma
dos pesos) e −1 se as direções não ficam determinadas. No Python:

```python
import numpy as np
from aerosim.backend.zig import ZigBackend

X = np.array([[0.5, 0.5], [0.6, 0.5], [0.4, 0.5], [0.5, 0.6], [0.5, 0.45]])
y = 1 + 2 * (X[:, 0] - 0.5) - 3 * (X[:, 1] - 0.5) ** 2
g, c, a, rms, peso = ZigBackend().local_fit(X, y, [0.5, 0.5], 0.2)
print(g, c)                                             # ≈ [2 0] [0 −6]
```

A tolerância e Morris: `aerosim_sens_tolerance(n, g, c, x0, N, δ, menos, mais, elasticidade)` devolve σ_N;
`aerosim_morris_design(k, r, p, semente, saída)` e `aerosim_morris_effects(k, r, trajetórias, y, μ, μ*, σ, passos)`.
No Python:

```python
be = ZigBackend()
D = be.morris_design(3, 10)                             # (10, 4, 3) em [0, 1]
y = 3 * D[..., 0] - 2 * D[..., 1] + D[..., 2] ** 2
mu, mustar, sigma, n = be.morris_effects(D, y)          # μ ≈ 3, −2 e algo entre 0,7 e 1,3; σ = 0, 0 e > 0
```

Testes: `python -m ziglang build test-optim` (dentro de `core/`) e `python -m pytest -q tests/aeroopt`. Uma operação
nova entra no enum `Op`, em `check`, em `run` e no compilador `aeroopt/scoring.py`, com o mesmo código nos dois lados.

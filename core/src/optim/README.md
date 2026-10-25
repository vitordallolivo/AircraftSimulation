# core/src/optim — as contas do aeroopt no núcleo

Esta é a parte do núcleo que o otimizador (`aeroopt/`) usa. Aqui se executa a nota de um candidato: o arquivo de
pontuação de um regulamento vira, no Python, um programa curto, e este código o roda para um candidato ou para
milhares de uma vez, sem alocar memória. Dele sai a nota e cada termo dela (os fatores), para a GUI mostrar por que um
avião ganhou.

Aqui também nascem as gerações de aviões: o algoritmo genético que escolhe quais configurações o aeroopt avalia.

A pasta tem três partes: os tipos do programa (`types.zig`), quem o confere e executa (`expr.zig`) e as gerações
(`ga.zig`). A álgebra linear que os solvers vão usar fica em `../math/linalg.zig`.

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

Testes: `python -m ziglang build test-optim` (dentro de `core/`) e `python -m pytest -q tests/aeroopt`. Uma operação
nova entra no enum `Op`, em `check`, em `run` e no compilador `aeroopt/scoring.py`, com o mesmo código nos dois lados.

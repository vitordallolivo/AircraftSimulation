# core/src/optim — as contas do aeroopt no núcleo

Esta é a parte do núcleo que o otimizador (`aeroopt/`) usa. Aqui se executa a nota de um candidato: o arquivo de
pontuação de um regulamento vira, no Python, um programa curto, e este código o roda para um candidato ou para
milhares de uma vez, sem alocar memória. Dele sai a nota e cada termo dela (os fatores), para a GUI mostrar por que um
avião ganhou.

A pasta tem duas partes: os tipos do programa (`types.zig`) e quem o confere e executa (`expr.zig`). A álgebra linear
que os solvers vão usar fica em `../math/linalg.zig`.

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

## Como chamar

Pela ABI: `aerosim_expr_check(programa)` e `aerosim_expr_eval(programa, entradas, passo, linhas, saída, passo)`,
que confere antes e devolve um código negativo (`expr.Error`) se o programa for recusado. No Python:

```python
from aeroopt.scoring import evaluate, scoring_for

r = evaluate(scoring_for("sae_br_2026_micro"),
             dict(c_lapes=1.0, c_liq=1.2, pv=0.5, m_bat=0.30, s_to=3.5, b=1.8))[0]
print(round(r["nota"], 2), {k: round(v, 3) for k, v in r["termos"].items()}, r["valido"])
```

Testes: `python -m ziglang build test-optim` (dentro de `core/`) e `python -m pytest -q tests/aeroopt`. Uma operação
nova entra no enum `Op`, em `check`, em `run` e no compilador `aeroopt/scoring.py`, com o mesmo código nos dois lados.

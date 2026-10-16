# core/ — otimizações em avaliação (`-Dopt`)

Variantes do núcleo que **não** são o padrão: cada uma é um bit de `-Dopt`, desligado por padrão. Com `-Dopt=0` (ou
sem a opção) o núcleo é o de sempre, bit a bit: a regressão em `tools/checks` confere. Aqui fica o que cada uma faz,
de onde veio, como medir e o que se mediu. Nenhuma vira padrão sem o dono aprovar (ela muda os números da
regressão).

## Como ligar

Por nome ou pela soma dos bits; nome errado para o build com a lista dos que existem.

```sh
cd core
python -m ziglang build --release=fast -Dopt=peak,cse         # o mesmo que -Dopt=24
python -m ziglang build test -Dopt=minimax,estrin             # os testes com as variantes ligadas
python -m ziglang build --release=fast                        # volta ao núcleo de sempre (-Dopt=0)
```

O backend Python carrega a biblioteca que estiver em `zig-out/lib`: depois de medir, compilar de novo com `-Dopt=0`
(o `tools/opt_matrix.py` já faz isso no fim). O AeroDrive usa o núcleo como dependência sem `-Dopt`: fica sempre no
de sempre.

| bit | nome | o que muda | onde |
|---:|---|---|---|
| 1 | `noinline` | `SinLut.sincos` sem `inline` forçado: o compilador decide | `math/fmath.zig` |
| 2 | `floatmode` | `@setFloatMode(.optimized)` em `sigmaStall`, `clPanel`, `computeImpl` e na hélice (o LLVM pode reassociar somas) | `physics/aero.zig`, `physics/propulsion.zig` |
| 4 | `logstd` | `log` (e o `log` dentro de `pow`) da std, o resto das tabelas | `math/fmath.zig` |
| 8 | `peak` | `peakCL`: varredura grossa de 0,01 rad + 40 passos de seção áurea, no lugar da varredura fina | `physics/aero.zig` |
| 16 | `cse` | o painel calcula `sigmaStall` e `sincos(α)` uma vez só (hoje: duas, em `clPanel` e em `computeImpl`) | `physics/aero.zig` |
| 32 | `minimax` | `sin`/`cos` sem tabela: redução ao quadrante + polinômios minimax | `math/fmath.zig` (`minimax`) |
| 64 | `estrin` | o polinômio de grau 10 do `exp` avaliado por Estrin no lugar do Horner | `math/fmath.zig` (`estrin10`) |

### Fontes

- **Seção áurea** (bit 8): Press et al., *Numerical Recipes*, 3ª ed., §10.2. Converge para um máximo local: a
  varredura grossa antes escolhe o intervalo.
- **Minimax** (bit 32): L. Schlör, "Fast MiniMax Polynomial Approximations of Sine and Cosine",
  <https://gist.github.com/publik-void/067f7f2fef32dbe5c27d6e215f824c91>. Usados "Sin, rel. error minimized, degree
  15" (erro relativo máximo 1,42e-16) e "Cos, rel. error minimized, degree 16" (1,76e-17), válidos no primeiro quarto
  de período. Redução do argumento com π/2 em duas partes (Cody e Waite).
- **Estrin** (bit 64): Knuth, *The Art of Computer Programming*, v. 2, 3ª ed., §4.6.4. Mesmo polinômio, mesmo número
  de operações; a cadeia de dependência cai de 10 multiplicações-somas para 4.
- **Branchless, constantes em comptime, `@Vector`** (ideia geral, ainda não aplicada ao painel): o artigo do astroz
  sobre SGP4 em Zig que o dono passou.

### Por que FFT e Karatsuba não entram

Os dois **multiplicam** polinômios: dados os coeficientes de A(x) e B(x), acham os de A(x)·B(x). A FFT faz isso em
O(n log n) avaliando os dois em n raízes da unidade, multiplicando ponto a ponto e interpolando de volta (tutorial
CSC373 que o dono mandou); o Karatsuba em O(n^1,58) trocando quatro produtos de metades por três. Aqui o problema é
outro: **avaliar** um polinômio fixo, de grau 10 a 16, num x por vez. Para isso o Horner já é ótimo em número de
operações (n multiplicações-somas, Knuth §4.6.4), e o que ainda se ganha é paralelismo (Estrin) ou um polinômio
menor para o mesmo erro (minimax). FFT e Karatsuba só começam a pagar com centenas de coeficientes, e o núcleo
nunca multiplica polinômios em tempo de execução: a tração polinomial é montada em comptime.

## Como medir

```sh
python tools/opt_matrix.py --instrucoes                  # tabela binária inteira, contagem de instruções
python tools/opt_matrix.py --bits peak,cse,minimax,estrin --rodadas 5   # tempo de parede das análises
python tools/opt_matrix.py --std                         # acrescenta a linha com a std (-Dfast_math=false)
python -m pytest -m bench -s tests/core/test_lut.py      # cada função isolada, em ns
```

- **Tempo de parede**: as análises do manager (envelope, missão, cargas, desempenho), a menor de N rodadas. Neste
  container o ruído é de uns ±10 %: diferenças menores que isso não querem dizer nada.
- **Instruções** (`--instrucoes`): uma carga fixa do núcleo sob o Callgrind (configurar o avião, que roda o
  `peakCL`; 10 s de simulação; 20 000 avaliações de f(t, x)), somando as instruções dos arquivos `.zig`. É
  determinística (mesma conta, mesmo número), mas instrução não é tempo: não vê cache, nem quantas instruções o
  processador faz ao mesmo tempo. O Estrin, por exemplo, não diminui instruções; ele diminui a espera entre elas.
- A biblioteca é compilada com `-Dstrip=false` no modo de instruções: o valgrind 3.22 não lê os nomes de função do
  Zig 0.16, só o arquivo, e sem símbolos nem isso. O `-Dstrip` só tira a informação de depuração; o código é o mesmo.
- A coluna "maior diferença nos resultados" compara cada número dos resumos com o da combinação 0 (ignora valores
  com |ref| < 1e-9).

## Resultados

Medido em 16/10/2026 neste container (Xeon 2,1 GHz), avião `conventional`. As tabelas completas ficam em
`perfis/` (fora do git); aqui, o que interessa.

### Cada bit sozinho

| bit | instruções no núcleo (carga fixa) | tempo das 4 análises | resultados contra o 0 | veredito |
|---|---|---|---|---|
| — (0) | 2,020 bi | 11,60 s | — | o de sempre |
| 1 `noinline` | 0 % (mesmo número) | 0 % | idêntico | **descartar**: o compilador faz o inline do mesmo jeito |
| 2 `floatmode` | +1,2 % | +8,9 % (no ruído) | ~1e-11 | ganho pequeno; muda o arredondamento |
| 4 `logstd` | −0,7 % | −1,2 % | ~1e-12 | **descartar** |
| 8 `peak` | +7,8 % | +17,9 % (cargas 1,25 → 0,19 s) | 1,6e-6 (impacto da carga na missão) | **adotar** (pede a regressão nova) |
| 16 `cse` | +11,6 % | +6,5 % (no ruído) | **idêntico** | **adotar**: de graça |
| 32 `minimax` | −9,7 % | −1,9 % | ~1e-11 | **descartar** |
| 64 `estrin` | −2,2 % | +6,3 % (no ruído) | ~1e-12 | **descartar** |
| std (`-Dfast_math=false`) | — | −7,0 % (cargas 2× mais lentas) | 3,1e-6 | referência |

Ganho em instruções é de uma carga só do núcleo (configurar + 10 s + 20 000 f(t, x)); o tempo é a soma de
envelope, missão, cargas e desempenho, a menor de 5 rodadas. O ruído do tempo é de uns ±10 %.

### Combinações

- Melhor em instruções: **26** (`floatmode,peak,cse`), +21,6 %; **24** (`peak,cse`), +19,4 %.
- Melhor em tempo: as dez primeiras ficam entre 8,52 e 8,77 s (+25 %), todas com `peak` e quase todas com `cse`;
  entre elas a diferença é ruído. Sem `peak`, nenhuma passa de +16 %.
- Os bits se somam quase sem interferência: 8 + 16 dá +19,4 % em instruções (7,8 + 11,6).

### Cada função isolada (`pytest -m bench -s tests/core/test_lut.py`, ns por chamada, entradas aleatórias)

| função | tabela / Horner | minimax / Estrin | std |
|---|---|---|---|
| sin | 5,3 ns | 10–13 ns (17,9 ns com desvio na troca de quadrante) | 23,8 ns |
| exp | 4,4–5,5 ns | 4,7–6,0 ns | 15,8 ns |

### O que se aprendeu

- **O minimax perde para a tabela.** A tabela de 2 KB fica no L1 e só precisa de uma correção de 6ª ordem num
  |d| ≤ π/256; o minimax precisa de graus 15 e 16 para o mesmo erro em |r| ≤ π/4. O minimax só valeria onde não
  há cache para a tabela (microcontrolador) ou dentro de um laço vetorizado (`@Vector`), em que a tabela vira
  gather.
- **O Estrin não ganha num laço de chamadas independentes**: o processador já sobrepõe uma chamada com a
  seguinte, e a cadeia de dependências do Horner deixa de ser o gargalo. Ele ganharia numa conta em que o próximo
  passo espera o exp (não é o caso aqui).
- **Desvio com entrada imprevisível custa caro**: a troca de quadrante do minimax por `if` levava 17,9 ns; por
  máscara de bits, 10–13 ns, com o mesmo resultado.
- **Onde está o tempo** é no `peakCL` (`aero.init`, chamado a cada configuração: domina cargas e desempenho) e no
  laço dos painéis (`computeImpl`). As funções matemáticas já são baratas. O próximo passo, se for preciso, é o
  painel em `@Vector(4, f64)` (proposta, ainda não feita).

### Proposta (para o dono decidir)

1. Tornar `cse` o padrão: resultado idêntico, nada muda na regressão.
2. Tornar `peak` o padrão: muda resultados em até 1,6e-6 (relativo), então pede aceitar a regressão nova.
3. Tirar do código `noinline`, `logstd`, `minimax` e `estrin` (ficam aqui documentados), ou mantê-los como bits
   para medir de novo em outra máquina.

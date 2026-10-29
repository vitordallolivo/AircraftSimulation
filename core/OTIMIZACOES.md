# core/ — otimizações em avaliação (`-Dopt`)

Variantes do núcleo que **não** são o padrão: cada uma é um bit de `-Dopt`, desligado por padrão. Com `-Dopt=0` (ou
sem a opção) o núcleo é o de sempre, bit a bit: a regressão em `tools/checks` confere. Aqui fica o que cada uma faz,
de onde veio, como medir e o que se mediu. Nenhuma vira padrão sem o dono aprovar (ela muda os números da
regressão).

## Como ligar

Por nome ou pela soma dos bits; nome errado para o build com a lista dos que existem. Os nomes e os bits são o enum
`Opt` de [`src/opt.zig`](src/opt.zig) (o valor de cada campo é o bit dele): o `build.zig` traduz os nomes por ele, e o
código pergunta por nome, `fmath.optOn(.peak)`. Otimização nova = um campo novo com o próximo bit.

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

### Tabelas (LUT) contra a std, f(t, x) e missão (medidas que estavam no `core/README.md`)

`math/fmath.zig` tem as duas implementações lado a lado (`lut` e `ref`), e `SinLut(bits)` gera tabelas
de qualquer tamanho em comptime. `bench.zig` mede cada função isolada (entradas sequenciais ou
aleatórias) e a avaliação de f(t, x). Nesta máquina (Xeon 2,1 GHz, L1d 48 KB, L2 2 MB por núcleo):

| função (entradas aleatórias) | LUT / polinômio | std |
|---|---|---|
| sin (tabela 2 KB) | 6,2 ns | 28,1 ns |
| sin (tabela 32 KB / 512 KB) | 6,2 / 6,3 ns | — |
| atan2 | 9,3 ns | 15,3 ns |
| exp | 8,1 ns | 19,2 ns |
| log | 13,6 ns | 8,7 ns |

- **As tabelas estão no cache**: 2 KB, 32 KB e 512 KB dão o mesmo tempo. Por isso o seno usa 256
  pontos (2 KB) com correção de Taylor de 6ª ordem (erro ~1e-15).
- **O que deixava a simulação lenta não eram as LUTs:** com `-Dcpu=native` num Xeon com AVX-512 o
  LLVM gera código pior para elas (f(t, x): 1478 ns com LUT contra 987 ns com `x86_64_v3`), por isso
  o padrão em x86 é `x86_64_v3`. Além disso, um `memset` genérico (slice de tamanho em tempo de
  execução e uma struct de saída zerada a cada chamada) custava ~1 000 instruções por avaliação; foi
  trocado por stores de tamanho fixo.
- Hoje: f(t, x) ≈ 1 µs; missão completa (165 s) ≈ 1 s. Pelo callgrind a versão LUT executa ~2,5× menos
  instruções que a std, mas o tempo das duas fica parecido: o gargalo é a cadeia de dependências do
  laço dos painéis em `aero.zig`, não as funções matemáticas.

Para reproduzir: `python -m pytest -m bench -s`.

Rotação de equilíbrio do motor (trimagem, curva de tração, envelope): `dn/dt` cai com n, então a
raiz é única em [1, 600] rps; *regula falsi* com a modificação de Illinois em vez de bisseção (≈10
avaliações em vez de 60) — o envelope "modelo completo" ficou ~2× mais rápido.

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

## Linha sustentadora e voos com outro modelo (feito; não é bit de `-Dopt`)

Estas não mudam nenhum resultado, então não são variantes em avaliação: entraram direto. A física do padrão (faixas)
e o AeroDrive não passam por aqui.

### Onde estava o tempo

Perfil (`tools/time_profile.py`, py-spy) de uma decolagem voada com a linha sustentadora de Goates e Hunsaker
(`aero_model = 1`, 44 painéis), antes do cache:

| onde | % | depende do escoamento? |
|---|---|---|
| `llt.ghInfluence`: linha efetiva, tangentes e juntas refeitas para cada ponto de controle | 49 % | não |
| Biot–Savart dos 5 segmentos de cada ferradura (`segment`) | 37 % | só as 2 pernas livres |
| `reset_ground` (equilíbrio no chão antes de começar) | 13 % | — |
| eliminação de Gauss (`solve`) | 2 % | — |

### O que foi feito

1. **Cache da geometria (`llt.prepare`, `Params.llt_cache`).** Monta, uma vez por configuração (`runner.configure`),
   de onde saem as pernas livres e os segmentos fixos (as juntas e o segmento ligado) de cada par (i, j). A cada
   avaliação, só as 2 pernas livres são calculadas, somadas na mesma ordem de antes: o resultado é **bit a bit
   igual** (teste em Zig "cache da geometria", em derrapagem e com diedro, nos dois métodos). O MachUpX, dos autores,
   faz o mesmo: a linha efetiva e as juntas são montadas com o avião (`machupX/airplane.py`).
2. **Voos em paralelo** (`tools/aero/missao.py --jobs`, padrão: os núcleos). Cada voo tem a sua sessão no núcleo, e o
   ctypes solta o GIL enquanto o núcleo integra. Preparar (refino, tabelas) fica em sequência, porque os métodos em
   Python seguram o GIL e nem todos são seguros em threads.
3. **Cache das tabelas de voo:** `aerosim/aero/flight_table.py` usa o cache de polares de `aerosim/aero/service.py`
   (em disco para os métodos caros). Isso também corrigiu o lltdrek, que não ia para o disco: o `cost = "caro"` estava
   no tradutor, não no solver.

### Medido

Os itens 1 e 3 na mesma máquina (Xeon 2,1 GHz, 4 núcleos); decolagem do `conventional --puro`, com os voos idênticos:

| | antes | depois |
|---|---|---|
| decolagem com `llt_gh` | 106,7 s | 9,9 s (10,8×) |
| decolagem com `llt` | 21,0 s | 12,1 s (1,7×) |
| `panel_states` com 44 painéis, Phillips e Snyder | 500 µs | 322 µs |
| `panel_states` com 44 painéis, Goates e Hunsaker | 535 µs | 325 µs |
| decolagem com os 9 modelos, da segunda vez (cache das tabelas) | ~2 min | 24 s em sequência, 12,7 s em paralelo |
| missão com os 9 modelos | > 1 h (o `llt_gh` sozinho: 52 min, numa máquina anterior) | 9 min 37 s em sequência, 5 min 15 s em paralelo |

Na missão de 165 s, em sequência (`missao.py --jobs 1`), cada modelo sozinho: faixas 4 s, faixas refinadas
(`faixas_fino`) 17 s, `llt` 261 s, `llt_gh` 258 s, tabelas dos métodos de fora 3–9 s cada (com o cache em disco).
Antes do cache, `llt_gh` 52 min e `llt` 10 min (numa máquina anterior).

Os 9 voos da missão refeitos depois das mudanças ficaram idênticos aos gravados antes (desvio do percurso 0,0 m).

**Por que o paralelo não divide por 4:** são 9 voos em 4 núcleos, e a parte em Python de cada análise (manager,
calibrações, séries dos gráficos) roda um voo por vez, por causa do GIL. Os voos leves (as faixas: 4 s sozinhas,
13 s em paralelo) são os que mais esticam no relógio. Processos em vez de threads evitariam o GIL, ao custo de ~1 s
para subir cada um.

### Próximos (mudam o último dígito; para o dono decidir)

- **Perna livre como vórtice semi-infinito, por fórmula fechada** (o 1º termo da eq. 3 de Goates e Hunsaker 2021),
  no lugar de um segmento até 1 km: uma raiz e uma divisão a menos por perna, e mais precisa.
- **No Phillips e Snyder, uma perna por nó:** as ferraduras vizinhas dividem o nó, então são n + 1 pernas em vez de
  2n, a metade.
- **SIMD (`@Vector`) no Biot–Savart, com os nós em estrutura de vetores.** É portável: o compilador gera AVX no x86,
  NEON no ARM, SIMD128 no WebAssembly, e um laço escalar onde não há SIMD. O núcleo já compila para
  `aarch64-linux` sem mudança.
- **Esteira no eixo x do corpo, como o AVL** (o *AVL User Primer* diz que as pernas são paralelas ao eixo x). A
  matriz fica constante: fatora-se uma vez e cada avaliação vira uma substituição, O(n²). Muda o modelo (perde o
  efeito da esteira inclinada em β), então seria uma opção desligada.

**Não compensa agora:**
- **Threads dentro de uma avaliação:** com ~44 painéis, uma avaliação depois do cache é curta demais. Acordar e
  esperar as threads (5–20 µs, 4 vezes por passo) come o ganho, e os núcleos já estão ocupados com os voos em
  paralelo.
- **GPU:** um voo é uma sequência de avaliações pequenas e dependentes, e a GPU perderia no tempo de lançar o kernel e
  de transferir os dados. Ela compensa com lotes grandes (Monte Carlo de milhares de voos, um VLM de milhares de
  painéis), como um módulo do núcleo, "lote de voos", desligado por padrão.

## WebAssembly: fma em software (feito; só no alvo wasm, não é bit de `-Dopt`)

O WebAssembly não tem instrução de fma, e o `@mulAdd` vira a rotina exata do compiler-rt (`fma`, com `normalize` e
`scalbn`), dezenas de vezes mais lenta que a conta comum. No AeroDrive no navegador, "Decolar" (o `sim.runner.configure`,
que varre o C_L de cada painel com `expWith`) levava 3,7 s, dos quais ~3,1 s eram `fma`; um quadro de voo levava
~7,7 ms de wasm. Com `fmath.mulAdd` (no wasm, `a * b + c`; nos outros alvos, o `@mulAdd` de antes), o decolar caiu
para ~0,5 s e o quadro de voo para ~2,2 ms (Chromium com SwiftShader, no container da sessão, 2026-10-29). O nativo
segue bit a bit igual (regressão 9/9); no navegador os números diferem do PC no último bit de cada conta.

O resto do decolar no navegador é o `peakCL` (4500 avaliações de `clPanel` por superfície); o `-Dopt=peak` já reduz
isso, mas muda os números e fica para o dono decidir.

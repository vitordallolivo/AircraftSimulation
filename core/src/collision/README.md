# core/src/collision — o que fica dentro do tubo da hélice

A hélice empurra o ar para trás num tubo, a esteira, e as partes do avião dentro desse tubo sentem um vento mais
forte que o resto. Esta pasta responde a duas perguntas de geometria sobre isso: se um ponto está dentro do tubo e
quanto de uma faixa da asa ou da cauda está dentro dele. Quem diz o raio do tubo ao longo do eixo é quem chama
(`modifiers/slipstream.zig`); sem essa informação, o tubo é um cilindro do raio da hélice.

O README segue as três peças do modelo: o tubo, a faixa aerodinâmica e a fração imersa, que junta as duas.

## Modelo

O **tubo** (`Tube`) começa no disco da hélice (`origin`) e segue o eixo `axis`, unitário e apontando para onde o ar
vai, que é para trás tanto numa hélice tratora quanto numa propulsora. Em cada distância $`x`$ ao longo do eixo, até o
comprimento `length`, ele tem um raio `radius(x)`. À frente do disco não há tubo. Sem `radiusFn`, o tubo é um
cilindro de raio $`R`$; com ela, é o tubo que contrai da esteira, descrito abaixo.

A **faixa** (`Strip`) é um quadrilátero com centro a 25 % da corda, a direção da corda (`ex`, para a frente), a da
envergadura (`ey`), a corda e a largura. A **fração imersa** (`stripFraction`) é a parte da faixa dentro do tubo,
contada em pontos no meio de cada célula de uma grade sobre a faixa.

**Ponto dentro do tubo.** Para um ponto $`\vec p`$, a distância ao longo do eixo e a distância ao eixo são

```math
x = (\vec p - \vec o)\cdot\hat a
\qquad
d = \lVert(\vec p - \vec o) - x\,\hat a\rVert
```

com $`\vec o`$ o centro do disco e $`\hat a`$ o eixo. O ponto está dentro se $`0 \le x \le L`$ e $`d \le R(x)`$.

**Raio do tubo que contrai.** Pela conservação de massa no disco atuador, o produto da velocidade pela área se mantém
ao longo do tubo; com $`w_0`$ a velocidade induzida no disco e $`w(x)`$ a do ponto (`modifiers/slipstream.zig`):

```math
R(x) = R\,\sqrt{\frac{V + w_0}{V + w(x)}}
```

(Glauert, em Durand, *Aerodynamic Theory* vol. IV, div. L; McCormick, *Aerodynamics, Aeronautics and Flight
Mechanics*, cap. da teoria da quantidade de movimento; número da equação a conferir no PDF.)

**Fração imersa.** Com os pontos $`\vec p_{ij}`$ no meio de cada célula da grade $`n_c \times n_s`$ (da borda de ataque à de
fuga e ao longo da largura):

```math
f = \frac{1}{n_c\,n_s}\sum_{i, j}\mathbb 1\left[\vec p_{ij}\ \text{dentro do tubo}\right]
```

Uma superfície acima ou abaixo da linha de tração fica fora do tubo, ou só com parte dentro. Por isso a esteira não
pega numa asa alta de um avião com o motor baixo. A EH e a EV que ficam atrás, na linha do motor, ficam dentro.

## Quem usa

| onde | para quê |
|---|---|
| `modifiers/mod.zig` | `stripOf` faz a faixa de cada painel. A esteira é a média de uma grade `chord_samples × strip_samples` da faixa; os pontos fora do tubo não somam nada |
| `root.zig` → `aerosim_tube_panel_hits` | fração de cada painel dentro do tubo do motor `idx`; `T = 0` dá o cilindro, `T > 0` o tubo que contrai |
| `root.zig` → `aerosim_tube_point_hits` | se cada ponto dado está dentro do tubo (para objetos: fuselagem, trem, carga) |
| `aerosim/aero/collision.py` | `tube_hits(backend, ac)`: lista do que cada hélice pega, superfícies (fração de área) e objetos (fração de vértices do modelo da GUI) |

## Testes

`zig build test` (no `core/`) roda os testes do arquivo:
- ponto dentro, fora, à frente do disco e além do comprimento;
- faixa inteira dentro, inteira fora, metade dentro e acima da linha de tração;
- tubo que contrai, com o raio vindo de quem chama.

Em Python, os testes estão em `tests/aero/test_collision.py`:
- o cilindro do Convencional pega parte da asa, a EH, a EV e a fuselagem;
- uma superfície acima da linha de tração fica fora;
- numa pusher, só o que está atrás;
- o tubo que contrai pega menos;
- num bimotor, a colisão é simétrica.

## Como chamar

```python
from aerosim.aero.collision import tube_hits
from aerosim.backend.zig import ZigBackend
from aerosim.model.templates import conventional

ac = conventional()
for h in tube_hits(ZigBackend(), ac):          # o que cada hélice pega: superfícies (fração da área) e objetos
    print(h)
```

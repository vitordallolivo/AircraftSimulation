# core/src/collision — colisão com o tubo da hélice

Só geometria. Responde: **este ponto está dentro do tubo da hélice?** e **quanto desta faixa aerodinâmica está
dentro dele?** Quem diz o raio do tubo ao longo do eixo é quem chama (`modifiers/slipstream.zig`); sem isso, o tubo é
um cilindro do raio da hélice.

## Modelo

- **Tubo** (`Tube`): começa no disco (`origin`) e segue `axis` (unitário, para onde o ar vai: para trás numa
  tratora, para trás também numa pusher, saindo do disco). Raio `radius(x)` em cada distância `x` ao longo do eixo,
  até `length`. À frente do disco (`x < 0`) não há tubo.
  - `radiusFn = null`: cilindro de raio `R`;
  - com `radiusFn`: o tubo que contrai da esteira, `R(x) = R·√((V+w0)/(V+w(x)))` — conservação de massa no disco
    atuador (Glauert, em Durand, *Aerodynamic Theory* vol. IV, div. L; McCormick, *Aerodynamics, Aeronautics and
    Flight Mechanics*, cap. da teoria da quantidade de movimento — número da equação a conferir no PDF).
- **Faixa** (`Strip`): quadrilátero com centro a 25 % da corda, direção da corda (`ex`, para a frente), da envergadura
  (`ey`), corda e largura.
- **Fração imersa** (`stripFraction`): pontos no meio de cada célula de uma grade `nc × ns` na faixa; fração = pontos
  dentro / total.

Uma superfície acima ou abaixo da linha de tração fica fora do tubo, ou só com parte dentro. Por isso a esteira não
pega numa asa alta de um avião com o motor baixo. A EH e a EV que ficam atrás, na linha do motor, ficam dentro.

## Quem usa

| onde | para quê |
|---|---|
| `modifiers/mod.zig` | `stripOf` faz a faixa de cada painel. A esteira é a média de uma grade `chord_samples × strip_samples` (3 × 16) da faixa; os pontos fora do tubo não somam nada |
| `root.zig` → `aerosim_tube_panel_hits` | fração de cada painel dentro do tubo do motor `idx` (grade 4 × 16); `T = 0` dá o cilindro, `T > 0` o tubo que contrai |
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

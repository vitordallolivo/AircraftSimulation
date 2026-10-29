# gui_zig (aeroopt)

Esta é a interface do aeroopt escrita em Zig, com raylib e raygui. Aqui se monta o problema de otimização (a
pontuação, as variáveis, as restrições e a configuração da busca) e se veem os resultados da rodada. Ela usa as
mesmas peças da interface do aerosim (`aerosim/gui_zig/src/ui`), para os dois programas terem o mesmo visual e os
mesmos dois modos de cor, o claro (padrão) e o escuro. Por enquanto a rodada é de exemplo.

A pasta tem a tela (`src/screen.zig`), a rodada de exemplo (`src/opt_example.zig`) e o programa (`src/main.zig`),
que só abre a janela pelo laço comum das peças.

## A tela

O problema fica à esquerda, em quatro grupos: pontuação, variáveis, restrições e configuração, cada um abrindo e
fechando no clique. À direita ficam quantos aviões passaram em cada etapa, a convergência, o mapa dos aviões
colorido pela nota, o MTOW de cada ponto, a melhor nota de cada configuração e a tabela dos melhores. As barras são
retas, de uma cor e a partir do zero, com a escala embaixo; o mapa usa uma escala de cor contínua com a barra
numerada.

## A rodada de exemplo

A rodada de exemplo é inventada, com semente fixa. A nota é uma função suave da envergadura e da corda com o máximo
conhecido, no mesmo espírito do `aeroopt/synthetic.py`. Ela serve para desenhar a tela e não é resultado de avião
nenhum.

## Como chamar

Precisa do Zig 0.16 (`pip install ziglang`) e das mesmas bibliotecas de sistema do AeroDrive. Sem acesso ao
`zig fetch`, dá para copiar a pasta `aerodrive/zig-pkg` para cá.

```sh
cd aeroopt/gui_zig
python -m ziglang build test                                  # testes sem janela
python -m ziglang build run                                   # abre o aeroopt
xvfb-run -a python -m ziglang build shot -- aeroopt.png       # print sem tela
```

Quando a busca de verdade for para o Zig, a rodada de exemplo sai e a tela lê o `.opt.json` e o resultado.

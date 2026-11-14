# aeroopt

O aeroopt procura o avião de maior nota num regulamento (SAE AeroDesign Micro ou Regular, por exemplo). Ele parte do
projeto da sprint do aerosim. O problema diz o que pode mudar: a envergadura, a área, os perfis, o motor e a hélice,
cada um com limites ou com a lista do que a busca pode escolher. Também diz as restrições, a pontuação e o método de
cada etapa. Cada candidato passa pelas mesmas etapas que o aerosim usa para dimensionar: asa, conjunto, motores e o
ponto de projeto acoplado, que dá o MTOW na pista. O programa é todo em Zig, com a mesma interface do aerosim, e roda
igual no PC e no navegador.

```mermaid
flowchart LR
    projeto[projeto da sprint] --> problema[problema .opt.json]
    problema --> candidato[candidato: valores das variáveis]
    candidato --> rascunhos[rascunhos da asa, do conjunto e dos motores]
    rascunhos --> ponto[ponto de projeto acoplado]
    ponto --> resultado[MTOW, peso vazio, bateria, o que não fecha]
    resultado --> nota[nota do regulamento]
```

A tela tem o problema à esquerda: o projeto, abrir e gravar o `.opt.json` e um botão por parte (pontuação, variáveis,
restrições, categorias e configuração), com o resumo ao lado. Cada botão abre o submenu dele. À direita fica a rodada.
Por enquanto essa rodada é de exemplo; a busca de verdade está sendo trazida para o Zig, etapa por etapa. Os testes
avaliam um candidato do projeto de exemplo:

```sh
cd aeroopt
python -m ziglang build test                                   # testes sem janela
python -m ziglang build run                                    # abre o aeroopt
xvfb-run -a python -m ziglang build shot -- tela.png projeto.json acao=variaveis
```

```
projeto_s1223 com b = 2 m e S = 0,6 m²: MTOW 7,4156 kg, vazio 3,4553 kg, baterias 0,8 kg
não fecha: velocidade de estol 13,1 m/s acima dos 11 m/s pedidos
```

As pontuações dos regulamentos estão em `pontuacao/`. O avaliador usa as etapas de `aerosim/design`, e as buscas vêm
do núcleo (`core/src/optim`).

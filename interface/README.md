# interface

Esta é a interface do aerosim e do aeroopt escrita em Zig, com raylib e raygui, no mesmo visual escolhido para o
site: cantos cortados, abas e botões inclinados e a logo do albatroz em azul, em dois modos de cor. O claro, que é o
padrão, é cinza claro com bordas pretas, azul e a zebra amarela; o escuro é grafite, laranja e preto. Ela é o
começo da troca da GUI em PyQt por uma que não precisa de Python: as contas vêm do núcleo (`core/`), que entra aqui
como módulo, igual ao AeroDrive. Por enquanto é o desenho das telas. No aerosim, a aba Analisar já roda a
varredura das asas no núcleo; o aeroopt mostra uma rodada de exemplo.

A pasta se divide em três partes. Em `src/ui` ficam as peças de qualquer tela: as cores e as fontes, as formas do
visual, os widgets (cabeçalho, abas, botão, cartão), o formulário lateral e o gráfico. Em `src/screens` ficam as
telas do aerosim e do aeroopt, montadas com essas peças. Na raiz de `src` ficam os dados que as telas mostram
enquanto não leem o avião e o problema de verdade: a asa de exemplo e a rodada de exemplo.

## As peças (`src/ui`)

Aqui se define a aparência e o comportamento comum. `theme.zig` guarda as cores dos dois modos, cada uma com um
papel (fundo, cartão, faixa escura, destaque, texto e a paleta de dez cores das curvas, escolhida para cada fundo); o
botão no canto do cabeçalho troca o modo na hora. Lá também ficam as três fontes (texto, títulos e números,
procuradas no sistema) e a logo, carregada branca e pintada de azul na hora de desenhar. `shapes.zig` desenha o retângulo de dois cantos cortados, o paralelogramo das abas e do
botão e a faixa zebrada da barra de progresso.

O formulário (`form.zig`) recebe uma lista de campos, cada um com rótulo, unidade, grupo, tipo (número, marcador ou
escolha) e limites, que é o equivalente do `ParamSpec` do aerosim em Python. O mesmo código desenha o formulário de
qualquer tela, com os grupos que abrem e fecham no clique e a rolagem pela roda do mouse. A edição dos números e a
lista aberta das escolhas são do raygui, com o estilo ajustado às cores do tema.

O gráfico (`plot.zig`) faz curvas e nuvens de pontos dentro de um cartão, com marcas de eixo "redondas" (passos de
1, 2 ou 5 vezes uma potência de dez), grade, a legenda embaixo e a barra de cores na nuvem. As contas dos eixos e
dos números ficam em `numbers.zig`, que não abre janela e por isso tem teste.

## As telas (`src/screens`)

No aerosim, o cabeçalho tem os botões de abrir e salvar, e embaixo vêm as abas das áreas e as subabas da
Aerodinâmica (Perfis, Projetar, Analisar). Em Analisar, o formulário pede a asa, o perfil e o caso, e o botão Rodar
chama a varredura do núcleo pelos dois métodos, a linha sustentadora não linear e as faixas independentes. Os
gráficos mostram o C_L do conjunto em α, a asa e a carga (a vista de cima em escala, só o contorno e as faixas, e
embaixo a vista de frente com um vetor de sustentação por faixa, do tamanho de L' na escala do eixo), o c_l e a
carga ao longo da envergadura, o diagnóstico (C_L máximo, onde o estol começa, Reynolds) e um resumo. As outras abas mostram só o
lugar delas.

No aeroopt, o problema fica à esquerda, em quatro grupos: pontuação, variáveis, restrições e configuração. À
direita ficam quantos aviões passaram em cada etapa, a convergência, o mapa dos aviões colorido pela nota, o MTOW
de cada ponto, a melhor nota de cada configuração e a tabela dos melhores.

## Os dados de exemplo

A asa de exemplo (`wing_example.zig`) é trapezoidal, sem enflechamento, cortada em faixas iguais. O núcleo guarda
o C_Lα de cada faixa já em 3D, como o tradutor em Python faz, e por isso a montagem aplica a relação de Helmbold
sobre o C_Lα do perfil:

$$C_{L\alpha} = \frac{a}{\sqrt{1 + k^2} + k}, \qquad k = \frac{a}{\pi A}$$

onde $a$ é a inclinação do perfil e $A$ o alongamento da asa. É a mesma relação que `core/src/loads/llt.zig`
inverte para voltar à inclinação 2D. A carga por unidade de envergadura é $L' = q\,c\,c_l$, com $q$ a pressão
dinâmica e $c$ a corda da faixa. Essa montagem é provisória: quando o modelo universal estiver em Zig, as faixas
saem dele.

A rodada de exemplo do aeroopt (`opt_example.zig`) é inventada, com semente fixa. A nota é uma função suave da
envergadura e da corda com o máximo conhecido, no mesmo espírito do `aeroopt/synthetic.py`. Ela serve para
desenhar a tela e não é resultado de avião nenhum.

## Como chamar

Precisa do Zig 0.16 (`pip install ziglang`) e, no Linux, dos cabeçalhos do sistema de janelas listados no
`CLAUDE.md` para o AeroDrive. O raylib-zig é o mesmo do AeroDrive. Sem acesso ao `zig fetch`, dá para copiar a
pasta `aerodrive/zig-pkg` para cá.

```sh
cd interface
python -m ziglang build test                                  # testes sem janela
python -m ziglang build run -- aerosim                        # abre o aerosim
python -m ziglang build run -- aeroopt                        # abre o aeroopt
python -m ziglang build run -- aerosim escuro                 # já no modo escuro
xvfb-run -a python -m ziglang build shot -- aerosim.png aerosim   # print sem tela
```

Para uma tela nova, monte a lista de campos e de grupos dela (veja as listas no começo de `screens/aerosim.zig`),
desenhe o formulário com `Form.draw` e os gráficos com `plot.lines` ou `plot.cloud`, dentro do mesmo cabeçalho e
das mesmas abas.

# gui_zig (aerosim)

Esta é a interface do aerosim escrita em Zig, com raylib e raygui, no mesmo visual do AeroDrive: fundo
claro, cantos arredondados, azul nos títulos, pouco texto e a logo do albatroz. Ela é o
começo da troca da GUI em PyQt por uma que não precisa de Python: as contas vêm do núcleo (`core/`), que entra aqui
como módulo, igual ao AeroDrive. A aba Analisar já roda a varredura das asas do avião aberto no núcleo, com
os mesmos números da GUI em Python. A interface do aeroopt fica em `aeroopt/gui_zig` e usa as peças comuns daqui.

A pasta se divide em três partes. Em `src/ui` ficam as peças de qualquer tela, as mesmas para o aerosim e para o
aeroopt: as cores e as fontes, as formas do visual, os widgets (cabeçalho, abas, botão, cartão), o formulário
lateral, o gráfico, a vista 3D e o laço do programa. Em `src/screen.zig` fica a tela do aerosim, montada com essas peças, e cada aba
tem o seu arquivo: `src/airfoil_tab.zig` (Perfis) com a etapa em `src/airfoil_stage.zig`, `src/wing_tab.zig`
(Projetar), `src/analyze_tab.zig` (Analisar) com as contas em `src/wing_analysis.zig`, e `src/assembly.zig`
(Montagem). O projeto de dimensionamento que Perfis e Projetar dividem fica em `src/design.zig`.

## As peças (`src/ui`)

Aqui se define a aparência e o comportamento comum. `theme.zig` guarda as cores, cada uma com um papel (fundo,
painel, cartão, borda, texto, o azul dos títulos e a paleta de dez cores das curvas), as mesmas do AeroDrive. Lá
também ficam as três fontes (texto, títulos e números, procuradas no sistema) e a logo. Os widgets
(`widgets.zig`) são os do AeroDrive em versão de tela grande: a aba ativa em azul claro com um traço embaixo, o
botão azul, o cartão branco de cantos arredondados e a barra de progresso.

O formulário (`form.zig`) recebe uma lista de campos, cada um com rótulo, unidade, grupo, tipo (número, marcador ou
escolha) e limites, que é o equivalente do `ParamSpec` do aerosim em Python. O mesmo código desenha o formulário de
qualquer tela, com os grupos que abrem e fecham no clique e a rolagem pela roda do mouse. A edição dos números e a
lista aberta das escolhas são do raygui, com o estilo ajustado às cores do tema.

O gráfico (`plot.zig`) faz curvas e nuvens de pontos dentro de um cartão, com marcas de eixo "redondas" (passos de
1, 2 ou 5 vezes uma potência de dez), grade, a legenda embaixo e a barra de cores na nuvem. As contas dos eixos e
dos números ficam em `numbers.zig`, que não abre janela e por isso tem teste.

As janelas por cima da tela ficam em `dialogs.zig`: o seletor de arquivo, que navega pelas pastas e mostra só as
extensões pedidas, para abrir (um clique no arquivo) ou para salvar (com o nome digitado), e a pergunta de um texto
curto. Enquanto uma delas está aberta, a tela de baixo não recebe o clique nem a roda. "Abrir avião" e "Salvar
.json" do cabeçalho, os botões de Perfis e os menus que vierem usam as mesmas; salvar, por enquanto, grava o avião
como foi lido, porque a edição ainda não existe.

A vista 3D (`view3d.zig`) segue as ideias da vista do aerosim em Python, mas desenhada aqui, com o raylib: cada
peça na cor do tipo dela (asa azul, profundor verde, leme roxo, comando laranja), sombreada dos dois lados por uma
luz fixa, as arestas das faixas, o chão quadriculado, os eixos do corpo (frente em vermelho, direita em verde, cima
em azul) e os vetores de carga, com a maior seta valendo 18 % do tamanho do avião, como na vista de cargas em
Python. O 3D é desenhado numa textura do tamanho do cartão; arrastar gira e a roda aproxima.

## A tela (`src/screen.zig`)

O cabeçalho tem os botões de abrir e salvar, e embaixo vêm as abas das áreas e as subabas da
Aerodinâmica (Perfis, Projetar, Analisar). Em Analisar, o formulário pede quais superfícies entram (por padrão
só a asa), o caso (velocidade e a faixa de α) e os métodos, e o botão Rodar chama a varredura do núcleo no avião
aberto. Os gráficos mostram, em cima, o que se simula em 3D com um vetor de sustentação por painel e a vista de
cima; depois o C_L do conjunto e o de cada superfície em α, o c_l e a carga L' ao longo da envergadura, o
diagnóstico (C_L máximo, onde o estol começa, Reynolds) e um resumo. A aba Montagem mostra o avião inteiro em 3D: abre sozinha o
avião de exemplo de `data/aircraft`, e outro `.json` entra pela linha de comando ou arrastado para a janela. A
leitura e as peças são as do AeroDrive (`aerodrive/src/model`, pelo `aerodrive/src/aircraft_model.zig`), as
mesmas formas e cores da GUI em Python; o `src/assembly.zig` só completa os perfis que o arquivo aponta num `.dat`
e passa cada triângulo para a vista 3D. As outras abas mostram só o lugar delas.

## Os perfis (`src/airfoil_tab.zig`, `src/airfoil_stage.zig`, `src/design.zig`)

Aqui se comparam perfis candidatos antes de desenhar a asa, do mesmo jeito que a página Perfis da GUI em Python. Os
candidatos são do projeto de dimensionamento (`design.zig`, o `DesignProject` em Python), que começa com o NACA 2412
e o NACA 4412, e não do avião aberto. A lista fica à esquerda, todos os candidatos entram nos gráficos, e os botões
acrescentam um NACA pelo código ("+ NACA..."), um `.dat` ("+ .dat...", Selig ou Lednicer), um perfil só de números
("+ só parâmetros") ou ligam a polar exportada pelo XFLR5 ou pelo XFOIL ao perfil selecionado ("+ polar XFLR5...").
"Remover" tira o selecionado. Os arquivos se escolhem num seletor dentro da própria janela (`src/ui/dialogs.zig`),
que navega pelas pastas e mostra só as extensões pedidas; arrastar o arquivo para a janela também funciona. Embaixo
da lista vem o editor do selecionado: de onde vem a polar ("modelo" ou "arquivo") e os números do perfil (a1,
$\alpha_{L0}$, $c_{l,\max}$, $c_{d0}$, $c_m$). Um perfil sem $\alpha_{L0}$ ou $c_m$ ganha os dois pela teoria de perfil
fino sobre a linha média do contorno. "Usar na asa" leva o selecionado para a raiz da asa em Projetar.

A polar sai do núcleo (`core/src/physics/section.zig`): a do modelo, ou a medida lida de −16° a 20°. Os gráficos
mostram $c_l$, a polar, $c_l/c_d$ e $c_m$ em α e o contorno em escala; a tabela embaixo tem os números que seguem para a
asa. O Reynolds é o de cruzeiro na corda média da asa em desenho, $Re = \rho V c / \mu$, com as condições do projeto
(editadas em Projetar). O diagnóstico avisa Reynolds abaixo de $10^5$, polar medida noutro Reynolds e a polar do
modelo com $c_d$ constante.

## A asa (`src/wing_tab.zig`)

Aqui se desenha a asa a partir de um perfil da aba Perfis ou da biblioteca `data/airfoils`. A asa começa retangular,
como em Python. O formulário pede a planta trapezoidal (envergadura,
área ou corda da raiz, afilamento, trecho retangular, enflechamento de 1/4 da corda, torção na ponta e o ângulo
da fuselagem no cruzeiro), o perfil da raiz e o da ponta (por padrão, o mesmo) e as condições de projeto (massa
estimada, velocidade de cruzeiro, altitude-densidade e massa da asa por área). Cada perfil entra ajustado na polar
dele, e um perfil simétrico (flecha da linha média abaixo de 0,3 % da corda) fica com $\alpha_{L0} = c_m = 0$, como
na GUI em Python. A conta é a linha sustentadora de Glauert do núcleo (`core/src/sizing/wing_line.zig`); os
gráficos mostram C_L até o estol, a polar (induzido, perfil e total), L/D com o C_L de cruzeiro, o $c_l$ ao longo
da envergadura no cruzeiro e no estol (com o $c_{l,\max}$ do perfil e onde o estol começa) e a planta em escala.

## A análise das asas (`src/wing_analysis.zig`)

Aqui se escolhem as superfícies que sustentam e sai a polar de cada uma, a do conjunto e a carga ao longo da
envergadura. É a mesma conta da simulação Asas da GUI em Python: o avião vira só as superfícies (sem fuselagem,
motor, tanque nem carga, como o `wings_only`), e cada superfície é refinada até o maior número de faixas que cabe
no núcleo, com as faixas mais finas na ponta, onde a carga muda mais depressa. Sem esse refino, a linha
sustentadora com poucas faixas erra o C_L máximo e o lugar do estol. Os painéis passam pelo mesmo
`params.fill` do AeroDrive, a tradução do modelo universal para o núcleo.

O espaçamento das estações de cada lado segue

$$y(t) = y_0 + (y_1 - y_0)\,\sin\left(\frac{\pi t}{2}\right), \qquad t \in [0, 1]$$

como o `refine_surface` em Python. A carga por unidade de envergadura é $L' = q\,c\,c_l$, com $q$ a pressão
dinâmica e $c$ a corda do painel. O teste confere o C_L e o C_L máximo do avião de exemplo contra a GUI em Python
pelos dois métodos.

## Como chamar

Precisa do Zig 0.16 (`pip install ziglang`) e, no Linux, dos cabeçalhos do sistema de janelas listados no
`CLAUDE.md` para o AeroDrive. O raylib-zig é o mesmo do AeroDrive. Sem acesso ao `zig fetch`, dá para copiar a
pasta `aerodrive/zig-pkg` para cá.

```sh
cd aerosim/gui_zig
python -m ziglang build test                                  # testes sem janela
python -m ziglang build run                                   # abre o aerosim
xvfb-run -a python -m ziglang build shot -- aerosim.png       # print sem tela
xvfb-run -a python -m ziglang build shot -- montagem.png aba=5   # print de outra aba
python -m ziglang build run -- ../../data/aircraft/Asa_voadora.json   # abre um avião
```

Para uma tela nova, monte a lista de campos e de grupos dela (veja as listas no começo de `src/screen.zig`),
desenhe o formulário com `Form.draw` e os gráficos com `plot.lines` ou `plot.cloud`, dentro do mesmo cabeçalho e
das mesmas abas.

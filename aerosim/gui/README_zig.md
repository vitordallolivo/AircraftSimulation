# A interface do aerosim em Zig

Esta é a interface do aerosim escrita em Zig, com raylib e raygui, no mesmo visual do AeroDrive: fundo
claro, cantos arredondados, azul nos títulos, pouco texto e a logo do albatroz. Ela é o
começo da troca da GUI em PyQt por uma que não precisa de Python: as contas vêm do núcleo (`core/`), que entra aqui
como módulo, igual ao AeroDrive. A aba Analisar já roda a varredura das asas do avião aberto no núcleo, com
os mesmos números da GUI em Python. A interface do aeroopt fica em `aeroopt/` (junto do Python dele) e usa as peças comuns daqui.

A pasta se divide em três partes. Os arquivos Zig ficam aqui mesmo, junto dos arquivos Python da interface em PyQt, e o build é o `aerosim/build.zig`. Em `ui/` ficam as peças de qualquer tela, as mesmas para o aerosim e para o
aeroopt: as cores e as fontes, as formas do visual, os widgets (cabeçalho, abas, botão, cartão), o formulário
lateral, o gráfico, a vista 3D e o laço do programa. Em `screen.zig` fica a tela do aerosim, montada com essas peças, e cada aba
tem o seu arquivo: `airfoil_tab.zig` (Perfis) com a etapa em `airfoil_stage.zig`, `wing_tab.zig`
(Projetar), `analyze_tab.zig` (Analisar) com as contas em `wing_analysis.zig`, e `assembly.zig`
(Montagem). O projeto de dimensionamento que Perfis e Projetar dividem fica em `design.zig`.

## As peças (`ui/`)

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

Todo gráfico de linhas se comporta igual, em qualquer tela, sem que a aba precise fazer nada. Um clique num nome
da legenda liga ou desliga aquela curva: a desligada fica riscada na legenda e sai dos eixos. O botão direito no
cartão abre um menu com as curvas para marcar e três saídas: a imagem em PNG, a mesma imagem num PDF de uma página
(as duas desenhadas de novo em escala 2, para sair nítidas impressas) e os dados das curvas marcadas em CSV. O CSV
é o padrão, com vírgula entre colunas, ponto decimal, uma linha de cabeçalho com o nome da curva e do eixo e os
números com todas as casas, então abre direto numa planilha ou no pandas. As tabelas de números (`plot.table`)
têm o mesmo menu: o botão direito grava a tabela em CSV, com uma grandeza por linha e o número inteiro, não o
arredondado da tela. A gravação (CSV, PDF com a imagem comprimida) fica em `export.zig`, que tem teste.

As janelas por cima da tela ficam em `dialogs.zig`: o seletor de arquivo, que navega pelas pastas e mostra só as
extensões pedidas (a pasta se digita no campo de cima, com `~` para a pessoal, ou se escolhe pelos atalhos
Exemplos, Pasta pessoal, Pasta atual e Raiz), para abrir (um clique no arquivo) ou para salvar (com o nome digitado), e a pergunta de um texto
curto. Enquanto uma delas está aberta, a tela de baixo não recebe o clique nem a roda. "Abrir avião" e "Salvar
.json" do cabeçalho, os botões de Perfis e os menus que vierem usam as mesmas; salvar, por enquanto, grava o avião
como foi lido, porque a edição ainda não existe.

Tudo o que pode passar da altura da janela rola pela área de `scroll.zig`: a roda do mouse ou a barra fina da
direita, que dá para arrastar. Ela abre um recorte (`Ui.pushClip`), e o que ficou fora dele nem aparece nem recebe o
clique; sem isso, um campo que rolou para baixo das abas pegava o clique dela. Uma área dentro de outra (a lista de
candidatos dentro da barra lateral de Perfis) rola primeiro, e a de fora fica com a roda que sobrou. Em Perfis, a
barra lateral inteira rola junto e só o rodapé ("Rodar", "Usar na asa") fica parado. As caixas de marcar e as setas
são desenhadas com linhas e triângulos, sem depender de a fonte do sistema ter o "✓" ou o "▸", e o Esc fecha a
janela de cima (seletor, pergunta) em vez de fechar o programa.

A tela não faz conta: o que demora (a varredura da aba Analisar, a leitura do `.json` e a montagem das peças) roda
numa thread pela `Job` de `jobs.zig`, e a tela continua desenhando e respondendo ao mouse enquanto isso, com a
mensagem "rodando no núcleo..." no lugar do resultado. Quando a thread acaba, a tela pega o resultado no quadro
seguinte e troca de uma vez; a análise guarda dois resultados, o que está na tela e o que está sendo calculado,
para que um nunca seja lido enquanto o outro é escrito. No print (`--shot`) e na web as contas rodam na hora, sem
thread, para a foto já sair com o resultado.

As peças de escolha que as abas repetem ficam em `menus.zig`: a lista de itens com um selecionado (`ItemList`), a
grade de botões de ação embaixo dela (`buttonGrid`) e o menu de marcar (`CheckMenu`), um botão que abre caixas de
marcar para escolher um ou mais itens, como os métodos de polar de Perfis. O menu funciona em dois tempos porque
cobre o que está embaixo dele: `update` antes dos widgets de baixo fica com o clique, e `draw` depois deles desenha.

A vista 3D (`view3d.zig`) segue as ideias da vista do aerosim em Python, mas desenhada aqui, com o raylib: cada
peça na cor do tipo dela (asa azul, profundor verde, leme roxo, comando laranja), sombreada dos dois lados por uma
luz fixa, as arestas das faixas, o chão quadriculado, os eixos do corpo (frente em vermelho, direita em verde, cima
em azul) e os vetores de carga, com a maior seta valendo 18 % do tamanho do avião, como na vista de cargas em
Python. O 3D é desenhado numa textura do tamanho do cartão; arrastar gira e a roda aproxima.

## A tela (`screen.zig`)

O cabeçalho tem os botões de abrir e salvar, e embaixo vêm as abas das áreas e as subabas da
Aerodinâmica (Perfis, Projetar, Analisar). Em Analisar, o formulário pede quais superfícies entram (por padrão
só a asa), o caso (velocidade e a faixa de α) e os métodos, e o botão Rodar chama a varredura do núcleo no avião
aberto. Os gráficos mostram, em cima, o que se simula em 3D com um vetor de sustentação por painel e a vista de
cima; depois o C_L do conjunto e o de cada superfície em α, o c_l e a carga L' ao longo da envergadura, o
diagnóstico (C_L máximo, onde o estol começa, Reynolds) e um resumo. A aba Montagem mostra o avião inteiro em 3D: abre sozinha o
avião de exemplo de `data/aircraft`, e outro `.json` entra pela linha de comando ou arrastado para a janela. A
leitura e as peças são as do AeroDrive (`aerodrive/src/model`, pelo `aerodrive/src/aircraft_model.zig`), as
mesmas formas e cores da GUI em Python; o `assembly.zig` só completa os perfis que o arquivo aponta num `.dat`
e passa cada triângulo para a vista 3D. A Montagem marca também o CG, numa cruz vermelha com a posição em x e a
massa: é a soma das massas do arquivo pela mesma função do AeroDrive (`params.dryMass`), mais a carga como massa
pontual; quando a carga muda o CG, o CG vazio aparece em cinza. A posição das peças ainda não se edita aqui: ela vem
do arquivo (`x`, `y`, `z` de cada superfície, a partir da origem do avião). As outras abas mostram só o lugar delas.

## Os perfis (`airfoil_tab.zig`, `airfoil_stage.zig`, `design.zig`)

Aqui se comparam perfis candidatos antes de desenhar a asa, do mesmo jeito que a página Perfis da GUI em Python. Os
candidatos são do projeto de dimensionamento (`design.zig`, o `DesignProject` em Python), que começa com o NACA 2412
e o NACA 4412, e não do avião aberto. A lista fica à esquerda, todos os candidatos entram nos gráficos, e os botões
acrescentam um NACA pelo código ("+ NACA..."), um `.dat` ("+ .dat...", Selig ou Lednicer), um perfil só de números
("+ só parâmetros") ou ligam a polar exportada pelo XFLR5 ou pelo XFOIL ao perfil selecionado ("+ polar XFLR5...").
"Remover" tira o selecionado. Os arquivos se escolhem num seletor dentro da própria janela (`ui/dialogs.zig`),
que navega pelas pastas do computador e mostra só as extensões pedidas; arrastar o arquivo para a janela também funciona. Embaixo
da lista, "polar por" abre um menu de marcar com os métodos de polar do selecionado: o modelo do simulador e a polar
do arquivo (quando há uma lida); pode ser mais de um, e cada um vira uma curva. A asa usa a do arquivo se ela estiver
marcada. As mudanças só refazem os gráficos no "Rodar". Depois vem o editor dos números do perfil (a1,
$\alpha_{L0}$, $c_{l,\max}$, $c_{d0}$, $c_m$). Um perfil sem $\alpha_{L0}$ ou $c_m$ ganha os dois pela teoria de perfil
fino sobre a linha média do contorno. "Usar na asa" leva o selecionado para a raiz da asa em Projetar.

A polar sai do núcleo (`core/src/physics/section.zig`): a do modelo, ou a medida lida de −16° a 20°. Os gráficos
mostram $c_l$, a polar, $c_l/c_d$ e $c_m$ em α e o contorno em escala; a tabela embaixo tem os números que seguem para a
asa. O Reynolds é o de cruzeiro na corda média da asa em desenho, $Re = \rho V c / \mu$, com as condições do projeto
(editadas em Projetar). O diagnóstico avisa Reynolds abaixo de $10^5$, polar medida noutro Reynolds e a polar do
modelo com $c_d$ constante.

## As peças de toda etapa (`ui/stage.zig`, `ui/table.zig`, `ui/checks.zig`, `registry.zig`, `requirements_dialog.zig`)

As etapas do dimensionamento repetem as mesmas peças, como o `StagePage` da GUI em Python, e aqui elas existem uma
vez só. Em cima da barra lateral fica a barra de requisitos (`stage.reqBar`): o resumo das condições e das
restrições ativas, sempre à vista, e o botão "Condições e restrições…". Depois vem o título da etapa com o "?" de
ajuda (`stage.title`), cuja dica aparece com o mouse parado em cima, como toda dica da interface
(`Ui.tooltip`). No fim da barra fica a caixa "Guardados" (`stage.KeptBox`), com a lista do que a etapa guardou e
os botões "Carregar no rascunho" e "Apagar". À direita, o diagnóstico (`checks.ChecksPanel`) mostra uma linha por
verificação, as falhas primeiro, e embaixo o porquê e o que fazer da linha clicada.

A tabela que se edita no lugar (`table.EditTable`) faz as partições da asa, as restrições e as variáveis. Quem
chama monta as células a cada quadro (número, texto, escolha, marcar, botão ou só leitura) e recebe de volta a
edição feita, que aplica ele mesmo. Um campo do formulário pode estar desligado (aparece em cinza e não edita, como
a área quando se dimensiona pela corda), ser texto (o nome da asa) e ter dica.

A janela "Condições e restrições…" (`requirements_dialog.zig`) é a mesma para todas as etapas e tem quatro abas,
como em Python. Condições traz a massa de partida, a velocidade de cruzeiro, a altitude-densidade e a pista.
Restrições lista uma restrição por linha: ligada ou não, a grandeza, o operador (≤, ≥, =), o valor, a unidade, o
último valor calculado e se ele cumpre. Uma restrição desligada guarda o valor. Variáveis diz, para cada entrada de
projeto, se ela fica fixa, varia entre mínimo e máximo (numa lista, entre as opções marcadas, escolhidas num
seletor com busca) ou é calculada, e "Limites a partir das restrições" leva as restrições ativas para as faixas.
Regras de projeto traz as massas por área e por metro, a fuselagem, o trem e os cursos dos comandos. As grandezas,
as restrições e as variáveis moram em `registry.zig`, a mesma tabela de `aerosim/design/registry.py`, com teste.
Cada etapa grava o que calculou (`Design.values`) e confere as restrições ativas dela no diagnóstico.

## A asa (`wing_tab.zig`)

Aqui se desenha a asa a partir de um perfil da aba Perfis ou da biblioteca `data/airfoils`, campo por campo como a
etapa Asa da GUI em Python. A asa começa retangular. O formulário pede o nome, a planta (trapézio ou tabela de
seções), o perfil da raiz e o da ponta (por padrão, o mesmo), a envergadura, a área ou a corda da raiz (pelo
"dimensionar por"; a outra sai da conta e fica desligada), o afilamento, o trecho retangular, o enflechamento de
1/4 da corda, a torção na ponta, o diedro e o ângulo da fuselagem no cruzeiro. Na planta "tabela", a tabela de
partições aparece embaixo do formulário, começando pelo trapézio de agora, com "+ partição", "− partição" e "do
trapézio"; os campos que só valem no trapézio ficam desligados e mostram a envergadura, a área e a corda da tabela.
As condições de projeto se editam na janela "Condições e restrições…". Cada perfil entra ajustado na polar
dele, e um perfil simétrico (flecha da linha média abaixo de 0,3 % da corda) fica com $\alpha_{L0} = c_m = 0$, como
na GUI em Python. A conta é a linha sustentadora de Glauert do núcleo (`core/src/sizing/wing_line.zig`); os
gráficos mostram C_L até o estol, a polar (induzido, perfil e total), L/D com o C_L de cruzeiro, o $c_l$ ao longo
da envergadura no cruzeiro e no estol (com o $c_{l,\max}$ do perfil e onde o estol começa), o diagnóstico (as
restrições ativas da asa, onde o estol começa, cruzeiro perto do L/D máximo, cruzeiro longe do estol, Reynolds na
ponta) e os resultados com as mesmas linhas da GUI em Python.

A primeira coisa à direita é a asa em 3D, com o contorno de verdade dos perfis da raiz e da ponta, montada pelo
mesmo esqueleto da Montagem e do AeroDrive num avião que só tem a asa (sem trem, fuselagem nem motor, como a
prévia da GUI em Python), com o diedro, a incidência e o ponto neutro (PN) marcado. Ela muda a cada valor editado. Embaixo do formulário, "Guardar asa" guarda a asa em
desenho com o nome dela ("Asa 1", e o desenho passa a "Asa 2"); as guardadas ficam numa lista, de onde voltam para
o desenho ("Carregar no rascunho") ou saem ("Apagar"), e aparecem tracejadas nos gráficos de C_L e de L/D, para
comparar com a que se está desenhando.

## A análise das asas (`wing_analysis.zig`)

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

Da raiz do repositório, `python -m ziglang build aerosim` compila e abre (e `aeroopt`, `aerodrive` fazem o mesmo
com os outros programas; `build test` roda todos os testes). Dentro da pasta:

```sh
cd aerosim
python -m ziglang build test                                  # testes sem janela
python -m ziglang build run                                   # abre o aerosim
xvfb-run -a python -m ziglang build shot -- aerosim.png       # print sem tela
xvfb-run -a python -m ziglang build shot -- montagem.png aba=5   # print de outra aba
python -m ziglang build run -- ../data/aircraft/Asa_voadora.json   # abre um avião
```

### No navegador

O mesmo programa compila para a web com o emscripten, como o AeroDrive. `python -m ziglang build
-Dtarget=wasm32-emscripten --release=safe` (aqui ou em `aeroopt/`) gera `zig-out/web/<programa>.html`, `.js`,
`.wasm` e `.data`, e `python tools/web_build.py` junta os três programas com a tela inicial em `zig-out/site`
(`python -m http.server -d zig-out/site 8000` e abrir `http://localhost:8000`).

O que muda fica em `ui/system.zig`. No navegador não há pastas do disco nem threads. Os arquivos ficam na memória da
página: o `.data` leva as fontes e as pastas `data/aircraft` e `data/airfoils` (só lidas), o botão "abrir do
computador" (ou arrastar o arquivo para a página) põe o arquivo em `/entrada` e a tela abre como abriria pela linha
de comando, e o que se salva a página baixa. A `Io` dos arquivos é a de `ui/browser_io.zig`, porque a do Zig não
compila para emscripten. As contas longas rodam na hora, no mesmo quadro, e a tela fica parada até acabar. A página
é `web/shell.html`, a mesma para o aerosim e o aeroopt.

Para uma tela nova, monte a lista de campos e de grupos dela (veja as listas no começo de `screen.zig`),
desenhe o formulário com `Form.draw` e os gráficos com `plot.lines` ou `plot.cloud`, dentro do mesmo cabeçalho e
das mesmas abas.

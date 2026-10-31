# A tela inicial (`launcher/`)

Esta é a primeira tela do programa instalado, a mesma do site (`web/index.html`): o menu no estilo de uma BIOS, com
fundo azul e moldura dupla, que escolhe o que abrir. No site ela abre o AeroDrive no navegador; aqui ela abre os
programas do PC, o aerosim (projetar), o aeroopt (otimizar) e o AeroDrive (pilotar), cada um num processo próprio,
e "Carregar avião (.json)" abre o AeroDrive já com o avião escolhido.

A pasta tem duas partes. Em `places.zig` fica a procura de onde estão os programas e os dados, e em `screen.zig` a
tela. O laço do programa, as fontes e o seletor de arquivo vêm das peças comuns das telas (`aerosim/gui/ui`).

## Onde estão os programas (`places.zig`)

No pacote instalado tudo fica numa pasta só: a tela inicial, os três programas e `data/` com os aviões de exemplo e
os perfis. No repositório cada programa está em `<pasta>/zig-out/bin`. A tela inicial procura primeiro ao lado
dela e depois na pasta do programa no repositório, e a pasta dos dados subindo a partir dela até achar
`data/aircraft`. Os programas abrem com essa pasta como pasta de trabalho, que é onde eles procuram os exemplos.

## A tela (`screen.zig`)

Escolhe-se com as setas ou passando o mouse, e abre-se com Enter ou clique. Esc volta ao primeiro item e "Sair"
fecha a tela inicial (os programas abertos continuam). As cores são as do site.

## Como chamar

```sh
python -m ziglang build launcher       # da raiz: compila e abre
cd launcher && python -m ziglang build test
python tools/package.py                # o AppImage (Linux); --alvo windows faz o instalador .exe
```

O pacote (`tools/package.py`) compila os quatro programas em ReleaseSafe, junta numa pasta com `data/aircraft`,
`data/airfoils` e a página do site em `site/`, e daí faz o AppImage (com o `appimagetool`) ou o instalador do
Windows (com o `makensis`, do NSIS), que instala em Arquivos de Programas, com atalhos no menu Iniciar e na área de trabalho e o desinstalador. O
instalador não tem assinatura digital, então o Windows avisa na primeira vez.

O aerosim desenha a tela em Zig, mas as abas vêm dos managers em Python (`aerosim/bridge.py`). Sem um Python com o
numpy no PC, ele abriria só a Montagem. Por isso o pacote leva o Python junto, na pasta `app/`: um Python portátil
(`app/python`, do python-build-standalone) com o numpy, o openpyxl e os métodos opcionais da Aerodinâmica
(aerosandbox, lltdrek, optvl; o que o pip não achar para o alvo fica de fora e a aba usa só o núcleo), o pacote
`aerosim` sem a GUI PyQt, o núcleo já compilado (`app/core/zig-out`) e uma cópia de `data/`. A tela do aerosim procura
`app/` ao lado dela antes do Python do sistema (`aerosim/gui/python_bridge.zig`). Com tudo isso o pacote fica grande
(os métodos opcionais pesam mais que o resto); `--sem-python` monta sem ele. Um programa novo
entra na lista `PROGRAMS` do `tools/package.py`, num item de `screen.zig` e em `places.Program`.

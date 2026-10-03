# AeroDrive

Simulador de voo do avião que você monta no aerosim, para pilotar com controle de Xbox (ou rádio em
modo joystick) ou deixar o piloto automático voar o percurso. Abre o mesmo arquivo salvo pela GUI,
desenha a aeronave igual a ela e voa com o mesmo núcleo de física em Zig: decolagem do chão ou da mesa,
LAPES, sloshing nos tanques, vento. Grava vídeo e dados do voo e mostra os mesmos gráficos da aba
Missão. Feito em Zig com [raylib-zig](https://github.com/raylib-zig/raylib-zig).

![Menu inicial](docs/img/menu_inicial.png)

![Cruzeiro em perseguição: rastro em vermelho, percurso em azul, setas do vento, minimapa](docs/img/voo_cruzeiro.png)

![Decolagem de cima da mesa, vista do piloto no chão](docs/img/decolagem_mesa.png)

![Asa voadora](docs/img/voo_asa_voadora.png)

![Aeronave: arquivo, sloshing, LAPES e vento](docs/img/menu_aeronave.png)

![Controle: curva de cada canal com o ponto ao vivo e zoom na peça](docs/img/menu_controle.png)

![Câmera: distância e altura da perseguição com prévia](docs/img/menu_camera.png)

![Pausa](docs/img/pausa.png)

![Voo gravado: gráficos com os valores sob o mouse](docs/img/voo_gravado_dados.png)

![Painel F3](docs/img/painel_f3.png)

---

## Instalar

### 1. Zig 0.16

```sh
pip install ziglang==0.16.0     # vira `python -m ziglang`
```

ou baixe de <https://ziglang.org/download/> e ponha o `zig` no PATH. Abaixo, `zig` = `python -m ziglang`
se você instalou pelo pip.

### 2. Bibliotecas do sistema (só Linux)

| distribuição | comando |
|---|---|
| Ubuntu / Debian / Mint | `sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev libgl-dev` |
| Fedora | `sudo dnf install libX11-devel libXrandr-devel libXinerama-devel libXi-devel libXcursor-devel mesa-libGL-devel` |
| Arch / Manjaro | `sudo pacman -S libx11 libxrandr libxinerama libxi libxcursor mesa` |

Wayland sem XWayland: também `libwayland-dev libxkbcommon-dev` e compile com `-Ddisplay=Wayland`.
Windows e macOS: nada.

Para gravar **vídeo** dos voos: `ffmpeg` no PATH (`sudo apt install ffmpeg`, `winget install ffmpeg`,
`brew install ffmpeg`). Sem ele a gravação guarda só os dados.

### 3. Compilar

```sh
cd aerodrive
zig build
```

A primeira vez baixa e compila o raylib (1 a 2 min); depois usa o cache. Rede com proxy, erros de
compilação e como atualizar o raylib: [docs/raylib.md](docs/raylib.md).

---

## Jogar

```sh
zig build run                                                   # abre o último avião escolhido
zig build run -- ../data/aircraft/Asa_voadora.json              # ou um avião salvo pela GUI
```

No **menu inicial**: Voar, Aeronave (arquivo, sloshing, LAPES, vento), Controle (curvas), Câmera, Som
(teste), Voos gravados. Mouse, teclado ou controle: passar o mouse destaca, ↑↓ / direcional escolhe,
Enter / A abre, Esc / B volta. As escolhas ficam salvas (`~/.config/aerodrive/config.json`).

**Voo** — começa no **manual**; o botão Y passa para o piloto automático (e volta) a qualquer momento.

| | controle | teclado |
|---|---|---|
| profundor e leme | analógico esquerdo | setas ↑↓, A / D |
| aileron | LB / RB | setas ← → |
| motor | gatilho direito (RT) | W / S |
| manual ⇄ automático | Y | M |
| soltar o LAPES | X | L |
| gravar / parar (vídeo + dados) | Back (View) | G |
| trocar a câmera | B | C |
| girar a câmera livre | analógico direito | arrastar o mouse |
| pausa (continuar, controle, câmera, recomeçar, menu) | Start | Esc ou P |
| painel de desempenho (fps, RAM, CPU) | — | F3 |

As gravações vão para `~/aerodrive_voos/voo_<data>/` (`video.mp4`, `dados.csv`, `info.json`); a pasta
muda com a variável `AERODRIVE_VOOS`. "Meus aviões" vem de `~/aerosim_aeronaves` (ou
`AEROSIM_PROJETOS`), a mesma pasta da GUI.

### Foto sem abrir janela

```sh
xvfb-run -a zig build shot -- voo.png ../data/aircraft/Convencional_original.json tela=voo voo=40
xvfb-run -a zig build shot -- menu.png tela=controle
```

`tela=` inicio, aeronave, voar, controle, camera, som, voos, dados, voo, pausa · `voo=SEG` voa antes da
foto · `modo=manual|auto` · `cam=seguir|chao|livre` · `mesa` · `f3` · `gravar` · `dados=PASTA`.

### Testes

```sh
zig build test                          # testes + fuzzing de todos os módulos (sem janela)
zig build test -Dfuzz=200000 -Dseed=7   # fuzzing mais longo
```

---

Cada módulo e como chamar: [src/README.md](src/README.md). Camadas, interfaces e o que falta:
[docs/projeto.md](docs/projeto.md).

# Tutorial: raylib com Zig (aerodrive)

Usamos o [raylib-zig](https://github.com/raylib-zig/raylib-zig) (raylib 6.0 com API em Zig, para
Zig 0.16): `const rl = @import("raylib");`, `rl.initWindow(...)`, cores `.white` etc. Os exemplos
dele (`examples/` no repositório: áudio, raygui, gamepad, shaders, modelos) servem de referência.

Nada é instalado: o `zig build` baixa o código-fonte (pelo `build.zig.zon`) e compila junto.
No Linux só faltam os cabeçalhos do sistema de janelas e do OpenGL.

Como foi adicionado (já está feito no `build.zig.zon`):

```sh
zig fetch --save=raylib_zig git+https://github.com/raylib-zig/raylib-zig#devel
```

e no `build.zig`:

```zig
const rlz = b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast }) orelse return;
exe.root_module.addImport("raylib", rlz.module("raylib")); // rl.gl = rlgl, rl.math = raymath
exe.root_module.addImport("raygui", rlz.module("raygui"));
exe.root_module.linkLibrary(rlz.artifact("raylib"));
```

## 1. Zig 0.16

Qualquer um dos dois:

```sh
pip install ziglang==0.16.0          # vira `python -m ziglang`
# ou baixe de https://ziglang.org/download/ e ponha o `zig` no PATH
```

Nos comandos abaixo, `zig` = `python -m ziglang` se você instalou pelo pip.

## 2. Bibliotecas do sistema (só Linux)

| distribuição | comando |
|---|---|
| Ubuntu / Debian / Mint | `sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev libgl-dev` |
| Fedora | `sudo dnf install libX11-devel libXrandr-devel libXinerama-devel libXi-devel libXcursor-devel mesa-libGL-devel` |
| Arch / Manjaro | `sudo pacman -S libx11 libxrandr libxinerama libxi libxcursor mesa` |

Wayland puro (sem XWayland): instale também `libwayland-dev libxkbcommon-dev` e compile com
`-Ddisplay=Wayland` (ou `-Ddisplay=Both`). Com XWayland (o normal no GNOME/KDE) o padrão X11 funciona.

Windows e macOS: nada a instalar.

## 3. Compilar e abrir

```sh
cd aerodrive
zig build test                                        # testes + fuzzing (sem janela)
zig build run -- ../data/aircraft/Convencional_original.json
```

A primeira compilação baixa e compila o raylib (1 a 2 min); as seguintes usam o cache.

Os comandos de cada tela estão no [README](../README.md#jogar). `fps=30` ou `fps=60` (padrão) escolhe
a taxa de quadros; a física roda em tempo real.

## 4. Foto sem abrir janela (servidor, CI)

```sh
xvfb-run -a zig build shot -- menu.png ../data/aircraft/Asa_voadora.json tela=inicio
xvfb-run -a zig build shot -- voo.png ../data/aircraft/Convencional_original.json tela=voo voo=40 cam=seguir
# tela=inicio|aeronave|voar|controle|camera|som|voos|dados|voo|pausa · voo=SEG voa antes da foto
# modo=manual|auto · cam=chao|seguir|livre · mesa · f3 · gravar · dados=PASTA · 1280x720
```

## 5. Problemas comuns

| mensagem | o que fazer |
|---|---|
| `unable to find dynamic system library 'Xrandr'` (ou GL, Xi, Xcursor, Xinerama) | falta o pacote `-dev` da tabela do passo 2 |
| `'X11/extensions/Xrandr.h' file not found` | idem (são os cabeçalhos) |
| `bad HTTP response code: '405'` ou `ReadFailed` ao baixar | rede com proxy que o Zig não atravessa: baixe o raylib com git e registre no cache (abaixo) |
| janela preta / `GLFW: Failed to create window` | sem OpenGL 3.3: atualize o driver de vídeo (no Linux, `mesa`) |

Sem acesso direto à internet pelo Zig (proxy corporativo): baixe cada dependência com git e
registre no cache do Zig (o hash tem de sair igual ao do `build.zig.zon`):

```sh
git clone https://github.com/raylib-zig/raylib-zig && cd raylib-zig && git checkout 8758f4cd
git archive --format=tar.gz --prefix=raylib-zig/ -o ../rlz.tar.gz HEAD && cd .. && zig fetch rlz.tar.gz
# idem para o que o raylib-zig pede no build.zig.zon dele: raylib#6.0, raygui, emsdk 4.0.9, zemscripten
```

## 6. Atualizar o raylib

```sh
zig fetch --save=raylib_zig git+https://github.com/raylib-zig/raylib-zig#devel
```

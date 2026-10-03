# aerodrive — pilotar a aeronave do aerosim

Simulador pilotado (controle de Xbox ou rádio de aeromodelo em modo joystick USB) com o mesmo núcleo
físico do aerosim (`core/`, Zig). Visual simples, só para teste: a física é a do núcleo e o desenho é o
mesmo da GUI. Feito em Zig + raylib (compilado pelo próprio `zig build`, sem instalador).

> Estado: **projeto** (este documento). Ainda não há código; primeiro as camadas e as interfaces.

Princípios:

- **uma fonte só**: a aeronave é configurada na GUI do aerosim. O aerodrive não calcula geometria nem
  traduz modelo; ele recebe um arquivo já pronto.
- **física ≠ aparência**: a dinâmica acontece só no modelo do núcleo. O que se vê é um *esqueleto*
  (gerado da mesma geometria da GUI) e, por cima e opcional, uma *pele* (Blender, SolidWorks). A pele
  nunca entra na física.
- **tudo é trocável por interface**: fonte do estado (voo ao vivo ou gravação), dispositivo de entrada,
  câmera, instrumentos do HUD, e o próprio desenho (raylib fica atrás de uma camada fina).
- **menos é mais** na tela, como na GUI: rótulos curtos, explicação no ⓘ.

---

## 1. Camadas

```
 aerosim (Python, GUI)                               aerodrive (Zig)
 ─────────────────────                               ──────────────────────────────────────────────
 Configuração ─► build_model ─► tradutor ─► params ┐
             └─► geometry   ─► esqueleto ──────────┼─► modelo.aerodrive.json ─► [0] Contrato
 Mapa (editor futuro) ─────────────────────────────┘    mapa.json, pele.glb
                                                                                    │
            [1] Fonte do estado  (IStateSource)   VooAoVivo (núcleo) │ Replay (arquivo)
            [2] Entrada          (IInputDevice → Perfil → Controls)
            [3] Mundo            estado de render = LogRow + cena estática
            [4] Câmeras          (ICamera) piloto no chão, perseguição, cabine, órbita, de cima, zoom em peça
            [5] Desenho          (IGfx) esqueleto │ pele, mapa, mesa/plataforma, LAPES, sloshing
            [6] HUD              (IWidget) instrumentos configuráveis
            [7] Telas            Hangar │ Controle │ Voo │ Replay   (máquina de estados)
            [8] Gravação         opcional, fora do laço de quadro
```

Cada camada só conhece a de baixo pela interface. O desenho ([5]) não sabe se o estado vem do voo ao vivo
ou de uma gravação: o replay é o mesmo desenho alimentado por outra fonte.

---

## 2. [0] Contrato com o aerosim: `modelo.aerodrive.json`

Gerado pela GUI (botão "Exportar para o aerodrive" / "Voar"). Campos:

| campo | o que é | de onde vem |
|---|---|---|
| `abi_version` | versão das structs do núcleo | `aerosim_abi_version()` |
| `params` | o SimSpec: os campos de `T.Params` com os mesmos nomes | `backend/zig/translator.py` (já existe) |
| `skeleton` | peças para desenhar (abaixo) | `model/geometry.py` (o mesmo da GUI) |
| `info` | nome, V de estol, nomes das etapas, x/z_warning | modelo universal / Configuração |

O Zig lê `params` com `std.json` direto para `T.Params` (sem tradução). Versão diferente → "recompile o
modelo na GUI" (nunca voa errado).

### Esqueleto (a aparência obrigatória)

Lista de **peças**. Cada peça tem um sistema de coordenadas e um *driver* que diz como ela se move:

```
Peça {
  id        "asa", "aileron_E", "profundor", "helice_0", "roda_principal_D", "tanque_0", "lapes", ...
  pai       id da peça-mãe (o corpo é a raiz)
  tipo      superficie | comando | fuselagem | tubo | motor | helice | roda | perna | tanque | liquido |
            carga | lastro
  malha     vértices + faces (corpo, metros) — as mesmas de geometry.py
  cor       chave da paleta da GUI (wing, control, motor, liquid...)
  driver    fixo
          | dobradiça { eixo: p0→p1 (linha de articulação), canal: (de, da, dr) · mix, limites }
          | giro      { eixo, canal: rpm[i] }                 (hélice)
          | líquido   { tanque i, canal: slosh_x[i], slosh_y[i] } (inclina a superfície)
          | carga     { canal: pk_n, pk_e, pk_h }             (solta da aeronave após a soltura)
}
```

- O `mix` do comando é o mesmo do tradutor (`_mix`: profundor, aileron com sinal do lado, elevon,
  ruddervator, leme). Assim o aileron desenhado deflete exatamente como o núcleo aplica.
- Hoje `control_meshes` desenha uma placa por cima da superfície. No esqueleto o comando vira **peça
  separada com dobradiça** (e a superfície fica sem aquele pedaço), para poder girar.
- **A GUI passa a desenhar a partir do mesmo esqueleto** (`view3d.py` consome o esqueleto em vez de chamar
  `aircraft_meshes` direto). Garantia de que os dois mostram o mesmo avião, com as mesmas cores.

### Pele (opcional, "maquiagem")

- Arquivo **glTF 2.0 (.glb)**: o Blender exporta direto; do SolidWorks: STL/OBJ → Blender → .glb (ou OBJ,
  que o raylib também lê).
- `pele.json` liga a pele ao esqueleto:
  - alinhamento: escala (mm → m), eixos (glTF é Y para cima; o corpo é x à frente, y à direita, z para
    baixo), origem;
  - nós da pele → peças do esqueleto (`"Aileron.L" → "aileron_E"`). Nó ligado gira com a dobradiça da
    peça; nó sem ligação vai preso ao corpo.
- Tela "Aparência": pele semitransparente sobre o esqueleto para alinhar. Botão alterna esqueleto, pele
  ou os dois.

---

## 3. [1] Fonte do estado — `IStateSource`

```
IStateSource {
  avançar(dt_quadro, controls) -> LogRow     // estado no fim do quadro
  reiniciar(ponto)                           // pista, mesa, ar, checkpoint
  salvar_snapshot() / carregar_snapshot()    // já existe no núcleo
  tempo()
}
```

- **VooAoVivo**: o núcleo. A cada quadro roda até `t + dt_quadro` com o passo interno de sempre (1 ms).
- **Replay**: lê a gravação; `avançar` interpola entre linhas; permite pausar, voltar, ×0,5, ×2.

O que falta no núcleo (pequeno):
- `Controls` externos (δe, δa, δr, acelerador, flap, soltar LAPES) e modo: **manual**, **assistido**
  (estabiliza φ e θ como o modo "ângulo" dos rádios, com os laços do piloto automático) ou **automático**
  (como hoje).
- Atitude da carga depois da soltura (hoje o `LogRow` tem só `pk_n, pk_e, pk_h`).

### Tempo

- Quadro fixo escolhido: **30 ou 60 fps**. Física por acumulador: cada quadro executa `dt_quadro / 1 ms`
  passos (16 a 33). O núcleo faz o percurso inteiro em segundos, então sobra muito tempo.
- Se um quadro atrasar, limita a recuperação (não acumula atraso) e mostra "lento" no HUD.
- Entrada lida uma vez por quadro; comandos mantidos durante o quadro.

---

## 4. [2] Entrada — `IInputDevice` → `Perfil` → `Controls`

```
IInputDevice { eixos[]: -1..1 ou 0..1, botões[] }      gamepad (Xbox), rádio USB, teclado
Perfil (perfil.json) — um item por canal:
  canal     profundor | aileron | leme | motor | flap | soltar_LAPES | reiniciar | câmera | gravar ...
  fonte     eixo k | par de botões (− / +, com rampa) | gatilho | botão
  curva     inverter, zona morta, trim, dual rate, expo   — ou —   curva por pontos (5 a 9 pontos, como nos rádios)
```

- Padrão proposto: **gatilho direito = motor** (0 a 100 %), **botões de ombro (LB/RB) = aileron** (com
  rampa), analógico esquerdo = profundor e leme; o modo 2 dos rádios fica como outro perfil.
- Gravar o perfil é salvar o `perfil.json` (um por controle/piloto).

---

## 5. [3] Mundo e [5] Desenho

**Estado de render = `LogRow` + cena estática.** Tudo o que se move vem do `LogRow` que o núcleo já
gera: posição (n, e, h), atitude (φ, θ, ψ), comandos (de, da, dr), `rpm`, carga (`pk_*`), sloshing
(`slosh_x/y`), vento (`Wn, We, Wd`), altura do chão (`hgnd`).

Mapa (`mapa.json`), só primitivas:
- **chão legível**: grade de 1 m (fraca) e 10 m (forte), pista com eixo central e marcas a cada 10 m,
  **linha do x_warning** e números de distância; cores lisas e claras.
- **mesa e plataforma** saem dos *pads* do próprio `params` (`terrain.zig`): uma fonte só, a física e o
  desenho batem.
- objetos (caixas, cilindros, cones: hangar, árvores, navio, cais), água como plano, heightmap PNG
  opcional; ponto do piloto no chão; biruta pelo vento.
- os objetos também podem ter pele (.glb), com o mesmo mecanismo da aeronave.

Coordenadas: núcleo em NED (n, e, h para cima) e corpo (x à frente, y à direita, z para baixo). **Uma**
função converte para o raylib (Y para cima). Mais nenhuma conversão espalhada.

`IGfx` (camada fina sobre o raylib): enviar malha, desenhar malha com transformação e cor, linhas, texto,
viewport. Trocar o raylib depois = reescrever só ela.

---

## 6. [4] Câmeras — `ICamera`

```
ICamera { atualizar(estado, entrada, dt) -> Vista { posição, alvo, para_cima, fov } }
```

| câmera | uso |
|---|---|
| **piloto no chão** | parada no ponto do piloto; só os "olhos" seguem a aeronave; zoom automático (fov) para ela não sumir — como no SeligSIM/RealFlight |
| perseguição | atrás da aeronave a uma distância fixa, com atraso suave |
| cabine | no corpo, olhando à frente |
| órbita | hangar e telas de configuração (arrastar para girar) |
| de cima | mapa / janela pequena (vista de pássaro) |
| zoom em peça | aproxima uma peça do esqueleto (motor, aileron) na tela de controle |

Uma **viewport** = câmera + retângulo da tela. A tela de voo tem a principal e janelas pequenas opcionais
(de cima, perseguição).

---

## 7. [6] HUD — `IWidget`

```
IWidget { desenhar(retângulo, estado, perfil) }      lista e posições em hud.json
```

Instrumentos (a referência é o RealFlight): velocidade (radar), altura e razão de subida, α / β / G,
**C_L/C_Lmax** (aviso de estol), rpm e acelerador, **SOC**, distância de pouso, cronômetros, **rádio na
tela** (posição dos sticks e gatilhos), mapa com vento, bússola, controles do gravador (◀◀ ◀ ❚❚ ▶ ▶▶).
Cada um liga/desliga; poucos ligados por padrão.

---

## 8. [7] Telas

- **Hangar (menu inicial)**: estilo menu de jogo. À esquerda: Voar, Aeronave, Controle, Mapa, Câmera,
  Gravação, Voos gravados. À direita: a aeronave em órbita, **viva**: mexer no controle deflete as
  superfícies e o gatilho gira a hélice.
- **Controle**: lista de canais à esquerda. Escolher um canal faz a **câmera dar zoom na peça** (motor,
  aileron...) e mostra o editor da curva: o ponto anda na curva conforme o controle é pressionado e a
  peça se move junto. Editar arrastando os pontos ou com expo/rate/trim. Salvar = gravar o perfil.
- **Voo**: viewport principal + HUD. Pausa, reiniciar (pista, mesa, ar), voltar 5 s (snapshot a cada 1 s),
  soltar LAPES, trocar câmera, ligar/desligar gravação.
- **Replay**: a mesma tela de voo com `Replay` como fonte e a barra do gravador.

---

## 9. [8] Gravação (opcional)

Desligada por padrão; liga no Hangar ou durante o voo. Não roda no laço do quadro (buffer + gravação em
segundo plano).

Arquivo `.adr`:
1. cabeçalho: `abi_version`, cópia do `params` usado, snapshot inicial, taxa;
2. `Controls` de cada quadro — refaz o voo exatamente (núcleo determinístico);
3. linhas de `LogRow` na taxa escolhida — lidas pelo aerosim sem código novo (o `abi.py` já monta o dtype
   pelo schema) e mostradas com os gráficos da Missão em "Voos gravados".

---

## 10. Pastas (quando houver código)

```
aerodrive/
  build.zig, build.zig.zon     núcleo (../core) como módulo + raylib
  src/
    main.zig
    contract/   leitura do modelo.aerodrive.json, mapa.json, pele.json, perfil.json
    source/     IStateSource: live.zig (núcleo), replay.zig
    input/      IInputDevice, perfil, curvas
    world/      cena estática + estado de render (LogRow)
    gfx/        IGfx (raylib), esqueleto, pele, mapa
    camera/     ICamera e as câmeras
    hud/        IWidget e os instrumentos
    screens/    hangar, controle, voo, replay
    rec/        gravação .adr
  perfis/  mapas/  peles/
```

## 11. Ordem

1. Contrato: esqueleto em Python (comandos como peças com dobradiça), GUI desenhando pelo esqueleto,
   exportação do `modelo.aerodrive.json`.
2. Núcleo: `Controls` + modos manual/assistido; atitude da carga.
3. aerodrive: leitura do contrato, `IGfx`, esqueleto, chão e pads, câmera órbita → Hangar vivo.
4. Entrada + perfil + tela Controle (zoom na peça e curva).
5. Voo: `VooAoVivo`, piloto no chão, perseguição, HUD mínimo, 30/60 fps.
6. Gravação `.adr`, Replay e "Voos gravados" na GUI.
7. Pele (.glb + `pele.json`), mapa por arquivo, instrumentos extras.

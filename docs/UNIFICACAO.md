# Unificação dos managers e dos modifiers (0.2.6)

Este documento é a etapa 1 da 0.2.6: o levantamento, lado a lado, de tudo o que muda o avião ou a física dele
(quantas asas, quantos motores, qual conta se faz) e de todos os "managers" que orquestram as análises, em Python e
em Zig. Ele não muda código. Serve para decidir, com o dono, qual vai ser a fundação comum da etapa 2 (normalizar
refatorando) antes de extrair qualquer framework na etapa 3.

O texto segue em quatro partes. Primeiro, o que hoje decide a física (os modifiers e os outros seletores de método).
Depois, o que decide a configuração (asas, motores, dispositivos). Em seguida, os managers. Por fim, as confusões que
o levantamento achou e a proposta de fundação comum, que só vira código com o ok.

---

## 1. O que decide a física

Hoje existem três jeitos diferentes de "escolher uma conta", e só um deles se chama modifier. É daí que vem a
confusão.

### 1.1 Os modifiers de verdade (`core/src/modifiers/`, `aerosim/model/modifiers.py`)

No núcleo, um modifier é um item de `Params.mods` (até `limits.max_mods = 8`), com `kind`, `enabled`, as máscaras de
painéis e de motores e 16 números livres em `params`. O efeito solo não é um item: é um campo seletor à parte,
`Params.ground`. No Python, a lista `Aircraft.modifiers` guarda os dois tipos juntos e o tradutor separa pela
"categoria".

| Nome no Python | Categoria | No núcleo | O que faz | Onde age |
|---|---|---|---|---|
| `solo.mccormick` | "solo" | `Params.ground = Ground.mccormick` | φ(h/b) de McCormick no arrasto induzido | `ground.zig`, cada painel |
| (lista sem "solo") | "solo" | `Ground.off` | sem efeito solo | — |
| `esteira.disco` | "aditivo" | `Kind.slipstream_disk` | esteira da hélice por disco atuador, soma na velocidade do painel | `slipstream.zig`, `mod.induced` |
| `interferencia.asas` | "aditivo" | `Kind.wing_pair` | velocidade induzida entre duas asas ligadas, numa passada | `wingpair.zig`, `mod.induced` |
| `comando.momento_flape` | "aditivo" | `Kind.flap_moment` | Δc_m do comando no quarto de corda | `flapmoment.zig`, `mod.flapCm` |

Os três "aditivos" não são do mesmo tipo de coisa. A esteira e a interferência somam uma velocidade no painel
(`induced`); o momento do flape soma um Δc_m e tem uma função só dele (`flapCm`). A interferência também só vale com
o voo pelas faixas e lê as circulações que a aerodinâmica preenche em `Env.gamma`, ou seja, ela é um pedaço de método
aerodinâmico, não um efeito somado.

### 1.2 Os seletores de método que não se chamam modifier

| Seletor | Onde mora | Valores | Como se escolhe |
|---|---|---|---|
| Modelo aerodinâmico do voo | `Params.aero_model` (`i32`), `physics/aeromodel.zig` | `faixas = 0`, `linha = 1`, `tabela = 2` (constantes soltas) | Python: `ac.sim.aero_model` em texto, `AERO_MODELS` em `translator.py` copia os números à mão |
| Variante da linha sustentadora | `Params.llt_joint`, `llt_blend`, `llt_nonlinear`, `llt_viscosity` | Phillips e Snyder (0, 0), Goates e Hunsaker (0,15 e 1), não linear (1) | o método sai de **números mágicos** em `f64`: `GOATES_HUNSAKER` e `NONLINEAR` em `span_loads.py` |
| Tração de cada motor | `PropUnit.model` | `prop_motor = 0`, `prop_poly = 1` | texto `thrust_model` no Python e no AeroDrive |
| Variáveis do polinômio de tração | `PropUnit.poly_x`, `poly_y` | `pvar_none`…`pvar_const` (6 constantes) | texto `x_var`/`y_var` |
| Tipo de perna do trem | `Gear.kind` | `gear_steer`, `gear_main`, `gear_skid` | texto `kind` |
| Forma do tanque | `Tank.shape` | `tank_square`, `tank_cylinder` | texto `shape` |
| Evento da missão | `Event.kind` | `event_drop`, `event_gust` | texto `kind` |
| Tipo de trimagem | entrada da ABI | `trim_level`…`trim_turn` | número |
| Método do envelope e atmosfera | `sim/envelope.zig` | `method_sheet`, `method_model`, `atmos_isa`, `atmos_sheet` | número |
| Grupo aerodinâmico do painel | `Surface.group` | `limits.group_wing`…`group_fuselage` | o tradutor escolhe pelo papel (`role`) |
| Tipo de aeronave do dimensionamento | `sizing/kinds.zig` | `Monoplane`, `Biplane`, `FlyingWing`, `Tailsitter`, `Vtol` (tipos com interface conferida em comptime) | índice na ABI |
| Variáveis e grandezas do dimensionamento | `sizing/types.zig` | `v_*`, `var_*`, `q_*` (45 constantes) | índice |

Liga e desliga também são `i32` soltos: `slosh_on`, `prop_strike`, `no_payload`, `gust_on`, `Surface.vertical`,
`Surface.downwash`, `Modifier.enabled`, e dentro da esteira `axial_on`/`swirl_on` são `f64` valendo 1 ou 0.

### 1.3 Os métodos aerodinâmicos do Python (registros)

| Registro | Onde | O que lista |
|---|---|---|
| `all_solvers` | `aerosim/aero/__init__.py` | 8 `IAeroSolver`: faixas do núcleo, lltdrek, VLM, buildup e linha sustentadora do ASB, AVL, linha sustentadora do núcleo (PS e GH) |
| `all_load_methods` | idem | 5 `ILoadMethod`: núcleo LLT, LLT GH, LLT não linear, faixas, VLM do ASB |
| `KINDS` | `aerosim/model/modifiers.py` | os 4 modifiers |
| `AERO_MODELS` | `translator.py` | os 5 modelos do voo, que viram 3 números |

A mesma escolha aparece em vários nomes: a linha sustentadora de Goates e Hunsaker é `CoreLLTSolver(gh=True)` como
solver, `CoreLoadMethod(gh=True)` como método de carga, `"llt_gh"` no modelo do voo e o par de números
`llt_joint = 0,15`, `llt_blend = 1` no núcleo.

---

## 2. O que decide a configuração

### 2.1 As asas

O "conjunto de asas" existe hoje em três formas que não conversam:

1. **`LiftingSurface.group`** (`aerosim/model/aircraft.py`): um id opaco; `wing_group()` devolve as asas com o mesmo
   id, e `references()` soma as áreas para o S de referência.
2. **A tabela "Asas do avião" de Projetar e as configurações guardadas** (`aerosim/manager/stages.py`,
   `aerosim/design/store.py`, `wing.py`): Δx, Δy, Δz, decalagem e "pontas ligadas" de cada asa em relação à de
   referência.
3. **As máscaras do `wing_pair`** no núcleo: só **as duas primeiras** asas do grupo viram as máscaras A e B
   (`_pair_masks` em `modifiers.py`), guardadas como bits dentro de `f64` em `params[1..4]`.

Viés que contraria a regra "a GUI é genérica":

- `Features.arrangement` devolve `"tandem"` ou `"biplano"` pela geometria das duas primeiras asas, e o `summary`
  escreve isso;
- o `wing_pair` não serve para três asas ou mais (a terceira fica fora da interferência);
- `aerosim/design/tail.py` ainda tem `wing2_join` ("pontas ligadas à segunda asa") e 27 menções a tandem e biplano;
- `sizing/kinds.zig` tem `Biplane` como tipo, com `wings = 2` em comptime e o σ de Prandtl só para dois planos.

### 2.2 O que o avião "tem" (`Features`)

Há duas versões, uma em cada linguagem:

| | Python `aerosim/model/features.py` | Zig `aerodrive/src/model/features.zig` |
|---|---|---|
| para que | as abas decidem o que mostrar | as telas do AeroDrive se montam |
| comandos | `pitch`/`roll`/`yaw` como (superfície, comando) | `Channel` (`enum`: throttle, aileron, elevator, rudder) |
| dispositivos de ponta | `tip_devices` + `devices` | — |
| arranjo das asas | `"tandem"`/`"biplano"` | — |
| tanques, carga, trem | sim | sim (LAPES, tanques) |

### 2.3 Dois modelos do avião e dois tradutores

O avião em Python (`aerosim/model/aircraft.py` → `universal.build_model` → `ZigTranslator`) e o avião em Zig
(`aerodrive/src/model/aircraft.zig` → `aerodrive/src/sim/params.zig`) leem o mesmo `.json` e montam os mesmos
`Params`, cada um com o seu código. A interface em Zig do aerosim (`aerosim/build.zig`) também usa o modelo do
AeroDrive. O caminho em Zig **não lê** `modifiers` nem `sim.aero_model`: voa sempre nas faixas com McCormick, mesmo
quando o `.json` pede outra coisa. Os papéis e os tipos são texto nos dois (`role = "wing"`, `kind = "aileron"`,
`thrust_model = "motor"`, `layout = "tricycle"`, `shape = "square"`).

### 2.4 Motores

`PropUnit` (até `max_props = 8`) com `model` em `i32`; o arranjo dos motores no dimensionamento é `v_layout`, um
índice numa lista; `Features.multi_engine` decide pela posição em y. A máscara de motores dos modifiers é um `i32` de
bits (`hitsProp`).

---

## 3. Os managers

"Manager" aqui é tudo o que pega o avião, escolhe o que rodar e entrega o resultado à tela. São seis estilos:

| Manager | Linguagem | Contrato | Registro | Resultado |
|---|---|---|---|---|
| `SimulationManager` + 13 `ISimulation` (`aerosim/manager/simulations/`) | Python | classe abstrata: `parameters`, `plots`, `run(ctx)` | lista `BUILTIN` | `SimResult` com `checks` |
| Etapas da sprint (`aerosim/manager/stages.py`, `Stage` e filhas) | Python | classe base com ~20 ganchos (`draft`, `compute`, `keep`, `grids`, `edit_grid`, `act`…) | dicionário na ponte | `Outcome` |
| Contas da sprint (`aerosim/design/`, 4,5 mil linhas) | Python | funções e dataclasses por etapa (`wing.py`, `tail.py`, `power.py`…) | `registry.py` | dataclasses próprias |
| Análises nativas (`aerosim/manager/native/`) | Zig | `struct Simulation` com ponteiros de função (`specs`, `start`, `advance`), contrato em JSON igual ao da ponte | `pub const all = [_]Simulation{...}` (1 item: rajada e líquido) | JSON |
| Cadeia do dimensionamento (`core/src/sizing/`) | Zig | tipo de aeronave com interface conferida em comptime (`kinds.check`) | `pub const all = .{...}` | structs `extern` |
| `drive_manager` (AeroDrive) | Zig | dono do voo em tempo real | — | estado por quadro |

O aeroopt tem as suas etapas (`aeroopt/stages.py`) e fica de fora, como pedido, a não ser onde a unificação obrigar.

Comparando:

- **Calibração.** Sete das treze `ISimulation` chamam `SimulationBase.prepare` (calibra o piloto pela polar); a Asas,
  a Aerodinâmica, a Estabilidade, a Tração, o Dimensionamento e o Desempenho não. O AeroDrive refaz a mesma calibração em Zig
  (`params.zig`).
- **Configuração.** A Estabilidade e a Aerodinâmica olham `features()`; a Asas tem a sua própria leitura do conjunto
  de asas (12 usos de `shared`, 6 menções a tandem e biplano).
- **Dado de uma para outra.** O `shared` é um dicionário solto (a polar da Aerodinâmica vai para o Desempenho), sem
  tipo.
- **Erros.** O Python levanta `ValueError` com texto; `modifiers.problems` devolve uma lista de textos; o núcleo tem
  só cinco conjuntos de erro (`runner.ConfigError`, `StateError`, `sweep.SweepError`, `gust.Error`, `root.AbiError`)
  e as análises nativas devolvem `anyerror`.

---

## 4. As confusões que o levantamento achou

1. **"Modifier" quer dizer três coisas.** Um seletor exclusivo (`ground`), uma lista de efeitos somados (`mods`) e,
   sem o nome, os métodos do voo (`aero_model`, a variante da linha sustentadora). O `wing_pair` é na prática parte
   do método das faixas, e o `flap_moment` é um termo da seção, não uma velocidade somada.
2. **Método escolhido por número mágico.** Goates e Hunsaker é "`llt_joint = 0,15` e `llt_blend = 1`"; não há um
   `enum` que diga "linha sustentadora de Goates e Hunsaker".
3. **Bits crus.** `surf_mask: [2]i32`, `prop_mask: i32`, as máscaras do par dentro de `f64`, e duas funções iguais
   para ler um bit (`mod.hits` e `wingpair.has`).
4. **Números copiados à mão no Python.** `core_id` em `KINDS`, `GROUND_OFF`, `MAX_MODS`, `AERO_MODELS`: o esquema da
   ABI leva os campos, mas não os nomes dos `enum`.
5. **Constantes soltas onde deveria haver `enum`.** `prop_*`, `pvar_*`, `gear_*`, `tank_*`, `event_*`, `trim_*`,
   `group_*`, `method_*`/`atmos_*`, as 45 de `sizing/types.zig` e `aeromodel.faixas/linha/tabela`.
6. **Liga/desliga como `i32` ou `f64`** em vez de `bool` ou de flags num `packed struct`.
7. **Configuração presa a dois planos.** `wing_pair` com as duas primeiras asas, `Features.arrangement`,
   `wing2_join`, `Biplane` no dimensionamento.
8. **Dois avatares do avião.** O caminho em Zig (AeroDrive e interface em Zig) ignora os modifiers e o modelo do voo.
9. **Seis contratos de manager** para a mesma ideia (campos, rodar, gráficos, diagnóstico).
10. **Nomes fora da regra.** `aerodrive/src/sim/params.zig` importa `const T = core.types; const L = core.limits`;
    `inducedWith` e `slipstreamAt` usam `Vr`, `eT`, `Q` (os campos `extern` da ABI ficam, a regra 11 deixa para uma
    tarefa à parte).

---

## 5. Proposta de fundação comum (para a etapa 2, depende do ok)

A ideia é separar duas perguntas que hoje se misturam: **qual método calcula um efeito** (exclusivo, um por vez) e
**quais efeitos a mais estão ligados** (somam, liga e desliga). E dar à configuração uma descrição genérica, por
lista de asas e de motores, sem nenhum arranjo com nome.

**Métodos como `enum`.** Cada efeito que sempre existe ganha um `enum(u8)` com `_` (número de outra versão = o
padrão), e o `switch` decide por nome. O modelo do voo vira
`AeroMethod = enum { strips, lifting_line, lifting_line_gh, lifting_line_nonlinear, table, _ }`; os números de
`llt_joint` e `llt_blend` passam a ser **parâmetros** do método e não a forma de escolhê-lo. O efeito solo segue como
`GroundMethod`. A tração (`ThrustMethod`), o trem (`GearKind`), o tanque (`TankShape`), o evento (`EventKind`), a
trimagem (`TrimKind`) e o grupo (`Group`) entram no mesmo molde.

**Efeitos a mais como flags.** Um `packed struct(u32)` com um `bool` por efeito (esteira, momento do comando,
interferência entre asas…), que é o "enum mapeado em bits" da regra: cada efeito tem um nome, e a ABI vê um `u32`.
Os parâmetros de cada efeito ficam numa struct `extern` com nome, no lugar dos 16 `f64` sem nome.

**Conjuntos como bitset.** Painéis e motores afetados viram um `std.bit_set.IntegerBitSet(64)` (ou `u64`) com uma
função só para ler. As asas ficam numa lista de conjuntos de painéis, quantos houver: a interferência entre asas
passa a valer para N asas (cada asa sente todas as outras), e o `wing_pair` com A e B deixa de existir.

**Nomes dos `enum` no esquema da ABI.** `abi.zig` já gera o esquema dos campos em comptime; ele passa a levar também
os nomes e os números de cada `enum`, e o Python lê de lá (some o `core_id` escrito à mão).

**Erros por módulo.** Cada módulo com o seu `error{...}`, juntados em `root.AbiError`, e o número só em `abiCode`. As
análises nativas param de usar `anyerror`.

**Um registro só.** O molde do dimensionamento (`pub const all = .{...}` e uma interface conferida em comptime) passa
a ser o dos métodos e o das análises nativas.

**Um avião em Zig.** O tradutor do AeroDrive (`params.zig`) passa a ler os modifiers e o modelo do voo do `.json`, e
o aerosim em Zig usa o mesmo. O Python fica como está, mesmo que quebre, até a interface em Zig ter tudo.

Regras que continuam valendo durante a refatoração: as faixas com McCormick ficam bit a bit iguais (a regressão de
`tools/checks` confere), os `.json` antigos abrem iguais e o AeroDrive compila e roda a cada commit do núcleo.

## 6. Plano da etapa 2 (aprovado pelo dono em 2026-11-05)

O dono aprovou a análise e acrescentou quatro decisões. Primeiro, todo número que é refino de método (quantidade de
painéis, faixas, pontos de amostra) vira entrada do usuário, com o valor de hoje como padrão. Segundo, o AeroDrive pode
ter métodos fixos, mas eles ficam num arquivo só, escrito com o framework, que diz quais são. Terceiro, a prioridade é
unificar as frentes e apagar o código morto (como o simulador antigo em C de `legacy/`), sem apagar os testes. Quarto, o
biplano, o tandem e o canard são só um avião com N asas: se a conta é a mesma, ela é uma só, e nada tem nome de arranjo.

Nesta etapa a regressão não roda: as coisas podem quebrar, e consertar isso é outra tarefa. O núcleo e o AeroDrive
continuam compilando a cada passo. Um commit por passo:

1. **Código morto.** Sai `legacy/` (o simulador em C e os scripts em Python dele); os testes que o usam ficam.
2. **`enum` no lugar das constantes soltas** do núcleo (`types.zig`, `aeromodel.zig`, `envelope.zig`, `sizing/types.zig`).
3. **Conjuntos por bitset.** Painéis e motores afetados num tipo só, com uma função só para ler.
4. **Método e efeito separados.** `AeroMethod` com as variantes da linha sustentadora por nome (os números de junta e
   de mistura viram parâmetros dela); efeitos a mais como flags num `packed struct`; parâmetros de cada efeito com nome.
5. **N asas.** A interferência entre asas vale para todas as asas da configuração (cada uma sente as outras); no
   dimensionamento, `Monoplane` e `Biplane` viram um tipo só com N asas; sai `Features.arrangement` e o que for preso à
   "segunda asa".
6. **Refino como entrada.** Uma struct de refino no núcleo (amostras da esteira na corda e na envergadura, estações da
   linha de asa...) e no Python (faixas por lado, painéis na corda do VLM e do AVL), com os padrões de hoje.
7. **ABI.** Os nomes dos `enum` no esquema (o Python lê de lá) e conjuntos de erro por módulo, sem `anyerror`.
8. **Um avião em Zig.** O tradutor do AeroDrive lê os modifiers, o método e o refino do `.json`; os métodos fixos do
   AeroDrive ficam em `aerodrive/src/sim/methods.zig`.
9. **Nomes** fora da regra 11.

Os nove passos estão feitos na `0.2_dev` (um commit por passo). Duas coisas ficaram de fora de propósito. O AeroDrive
lê do arquivo só os modifiers: o modelo do voo e o refino ficam fixos em `methods.zig`, porque o voo tem de caber nos
120 Hz. E os nomes de uma letra que sobram nos arquivos que esta etapa não abriu (o resto de `params.zig`, a geometria
do AeroDrive) ficam para quando cada arquivo for mexido. A regressão não rodou nesta etapa: as quebras do Python
são esperadas e são outra tarefa.

Depois disso vem a etapa 3: juntar os seis contratos de manager num framework só.

## 7. Etapa 3: o framework em Zig (começou em 2026-11-05)

O alvo é o aerosim e o AeroDrive em Zig, para o app no navegador rodar sem Python. Das partes comuns que a etapa 2
deixou iguais, saíram três peças. `core.interface` é o molde de registro (uma lista de tipos com as mesmas
declarações, conferida em comptime), que o dimensionamento e as análises das telas usam. `core.methods.Methods` junta
as escolhas exclusivas de método do voo (modelo, linha sustentadora, refino), com os nomes em português para a tela; a
interface deixa o usuário escolher e o AeroDrive fixa os seus em `aerodrive/src/sim/methods.zig`. E o framework das
análises (`aerosim/manager/native/native.zig`) registra cada análise como um tipo, com o estado da rodada tipado e os
campos de métodos prontos.

O `drive_manager` do AeroDrive fica de fora do registro de análises: ele é o laço de tempo real (um passo por quadro,
sem formulário nem resultado), e o que ele divide com as análises é o tradutor do avião e os `Methods`. As contas em
Python (as treze `ISimulation`, as etapas da sprint e `aerosim/design`) entram no framework uma de cada vez, cada uma
portando a conta para o núcleo.


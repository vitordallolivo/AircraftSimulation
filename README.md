# aerosim — simulador 6GDL de aeronaves em camadas

```
GUI (PyQt6 + pyqtgraph)          aerosim/gui        aba de configuração 3D + uma aba por simulação
   │  ISimulationManager
Simulation Manager (Python)      aerosim/manager    o que roda, até onde, de onde retoma, o que itera
   │  ISimBackend / ISimSession
Sim (núcleo em Zig)              core/              dinâmica 6GDL, RK4, trimagem — memória estática
                                                    
Aircraft Data                    aerosim/data       .cfg, .json, .xlsx, planilha por mapa de células
   │  IAircraftSource / ICatalogSource
Modelo                           aerosim/model      aeronave, perfis .dat, catálogo, missão, geometria
```

Cada camada só conhece a **interface** da camada de baixo (`aerosim/interfaces`). Trocar o núcleo,
a origem dos dados ou a GUI é trocar o objeto passado; `tests/test_manager.py` roda o manager com um
backend falso para provar isso.

## Instalar e usar

```sh
pip install -r requirements.txt        # inclui o compilador Zig 0.16 (pacote ziglang)
python -m aerosim.gui                  # GUI (compila o núcleo na primeira vez)
python -m aerosim.gui data/aircraft/twin_boom.cfg
python -m pytest tests                 # 45 testes: núcleo, ABI, C original, dados, manager, GUI
```

O núcleo é compilado sozinho quando falta ou está desatualizado
(`cd core && python -m ziglang build --release=fast`). Testes do Zig: `python -m ziglang build test`.

## GUI

**Configuração** — a aeronave em 3D ocupa ~80 % da tela; o painel à direita tem:

- vento: velocidade (slider) e direção (dial + botões ⟲ 15° / 15° ⟳), seta azul no 3D;
- lista de componentes com **+ Asa, + EH, + EV, + Motor, + Tanque, Remover** e as opções tubo de cauda,
  fuselagem, carga e trem **triciclo / convencional / custom**;
- editor do componente selecionado: cada número é um **slider + campo digitável**
  (posições x, y, z do motor, diedro, incidência, massa…); seções da asa (y, corda, recuo do bordo de
  ataque, torção) em tabela; comandos (aileron, profundor, leme, **elevon**, **ruddervator**, flape) com
  início/fim na envergadura e fração de corda; perfil por nome NACA ou **arquivo .dat** (desenhado e
  usado na malha 3D, com α_L0 e C_m,ac pela teoria de perfil fino);
- motor, hélice e bateria escolhidos do catálogo e o botão **curva de tração × velocidade**;
- **clique e arraste** qualquer componente no 3D (motor, superfície, tanque, carga, trem…), no plano da
  tela ou travado em x, y ou z; os sliders acompanham;
- resumo ao vivo: massa, CG (ponto vermelho), ponto neutro (linha verde), margem estática, C_Lα, V_estol.

**Uma aba por simulação**, gerada pelo que a simulação declara (`parameters()` e `plots()`): formulário,
rodar/parar, progresso, gráficos em tempo real (o núcleo devolve fatias do registro) e exportar CSV.

| aba | o que faz |
|---|---|
| Decolagem | corrida até `h_end`; opcional: mapa s_R × δe1 com as restrições (cauda, estol, q, V em h_t) |
| Curvas | raio mínimo por V: nivela, salva checkpoint no início da curva e reroda só a curva para cada raio |
| Envelope de voo | só equilíbrios (Newton), sem integrar: potência, subida máx., planeio, raios, V-n |
| Missão | circuito completo com checkpoints A/B/C; escolhe de onde começar e até onde ir; bisseção do ponto de soltura da carga |
| Subida | γ máximo por V a partir de checkpoint nivelado, comparado com a trimagem |
| Polar | C_L, C_D, C_m (α) e C_Y, C_l, C_n (β), margem estática, C_nβ, C_lβ |
| Tração | T, P, I e η da hélice × V para cada motor e acelerador |

Nova simulação: uma classe `ISimulation` em `aerosim/manager/simulations/` adicionada a `BUILTIN` —
a aba aparece sozinha.

## Aeronave (modelo de dados)

`aerosim/model/aircraft.py` (ângulos em graus, SI, eixos do corpo x frente, y direita, z baixo):
superfícies sustentadoras com N seções e comandos, fuselagem, tubo de cauda (a cauda pode ficar presa na
ponta), **K unidades propulsoras** (cada uma com motor, hélice e bateria próprios, posição e eixo),
trem por tipo (triciclo, convencional ou pontos livres), **N tanques de base quadrada** (ou cilíndricos)
com sloshing, carga com soltura, modelo de massa (base + massas pontuais + opcionalmente motores,
baterias e estrutura), ambiente, decolagem, ganhos do piloto, missão.

Modelos prontos (`aerosim/model/templates.py`, `data/aircraft/*.cfg`): o convencional do código original,
uma **asa voadora** com elevons e winglets, e um **bimotor com trem convencional, tubo de cauda e cauda
em V**. As três decolam e completam a missão inteira (testado).

Geometria → núcleo (`geometry.py`): cada superfície é cortada nas seções e nas bordas dos comandos;
cada faixa de cada lado vira um painel com centro aerodinâmico a 25 % da corda, enflechamento, diedro,
torção; C_Lα por Helmbold com o alongamento da superfície; τ do comando pela teoria de perfil fino.
A deflexão de cada painel é `τ · (mix · [δe, δa, δr])`, o que cobre elevon e ruddervator.

## Dados (Aircraft Data)

| origem | leitura/gravação |
|---|---|
| `.json` | completo |
| `.cfg` | INI legível, uma seção por componente (`[surfaces.0]`, `[surfaces.0.sections.1]`, `[propulsion.0]`…) |
| `.xlsx` | aba `geral` (seção, chave, valor) + uma aba-tabela por lista (superfícies, seções, motores…) |
| planilha por células | `aerosim/data/cellmap.py` + um mapa `.json` (campo → `Aba!Célula`, escala, offset) |
| catálogo | `.cfg`, `.json`, `.xlsx` (motores, hélices, tabela J/C_T/C_P, baterias) ou tabela com cabeçalhos livres (`TableCatalogSource`) |

`data/mappings/dados_desempenho.json` mapeia o formato `Dados_Desempenho.xlsx` (abas Geral e Superficies,
com as conversões 1/grau → 1/rad etc.); `data/mappings/propellers_motors.json` o `Propellers&Motors.xlsx`.
O que não tem correspondência no modelo está listado no próprio mapa (`unmapped`): as derivadas de
estabilidade e os polinômios de arrasto (o núcleo calcula pelos painéis) e o polinômio de tração p00..p05
(o núcleo usa motor + hélice por tabela J, C_T, C_P). Conferir os eixos (x para frente, z para baixo).

## Núcleo em Zig (`core/`)

| arquivo | conteúdo |
|---|---|
| `limits.zig` | limites de compilação (painéis, motores, tanques, segmentos, instâncias) — tudo estático |
| `types.zig` | structs do C ABI (`Params`, `LogRow`, `Events`…) |
| `abi.zig` | **esquema gerado em comptime por reflexão**: o Python monta as structs ctypes sozinho |
| `root.zig` | funções exportadas; erros internos são error unions, viram códigos só na fronteira |
| `math/fmath.zig` | sin/cos por tabela (4096 pts) + correção de Taylor, atan por tabela + 2ª ordem, exp/log por polinômio, tabelas geradas em comptime |
| `math/vec.zig` | vetores em `@Vector` (SIMD) |
| `physics/` | aerodinâmica por painéis, propulsão (K unidades), trem, massa/sloshing/carga, vento |
| `control/` | guiamento e piloto automático |
| `sim/` | estado, dinâmica, RK4 vetorizado, executor (eventos, paradas, fatias, checkpoint), trimagem |

- Memória: um conjunto fixo de `max_instances` simulações (sem alocação); `aerosim_acquire` pega uma.
- Checkpoint = bytes do estado da corrida; os parâmetros vêm sempre da configuração nova.
- `-Dfast_math=false` troca as tabelas/polinômios pelas funções da std (referência).
- **Validação:** com a aeronave do código original, a decolagem do Zig bate com o simulador em C
  (`legacy/`) em todos os dígitos impressos (n_LO = 46,3922 m nos dois); `tests/test_core.py` compara.
- Desempenho medido (missão completa, 165 s simulados, dt = 1 ms): ≈ 1,1–1,2 s (~140× tempo real).
  Nesta máquina a versão com tabelas **não** ficou mais rápida que a da std (1,22 s × 1,07 s): o tempo
  está na montagem das forças, não nas funções trigonométricas. As duas dão o mesmo resultado.

## Código original

`legacy/` guarda o simulador anterior (C + Python) sem mudanças; serve de referência para os testes.

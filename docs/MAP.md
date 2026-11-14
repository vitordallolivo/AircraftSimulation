# Mapa do código

Gerado por `zig build mapa` — **não editar à mão** (`zig build mapa -- --check` acusa quando está desatualizado).
Formato: `arquivo` — primeira linha da documentação; depois os nomes públicos com a linha (`nome:linha`).
Regras e decisões do projeto: `.claude/CLAUDE.md`. O que falta e a ordem: `docs/TRACKING.md`.

## Python · `aerosim`

- `aerosim/__init__.py` — aerosim em Python: só o adaptador dos métodos de fora do núcleo (lltdrek, AeroSandbox e AVL, que são bibliotecas
- `aerosim/bridge.py` — O adaptador dos métodos de fora do núcleo: lltdrek, AeroSandbox (VLM, AeroBuildup, LiftingLine) e AVL, que são
  `solver:40`, `model_of:52`, `polar:60`, `loads:82`, `plain:99`, `answer:114`, `call_in_browser:130`, `main:138`

## Python · `aerosim/aero`

- `aerosim/aero/__init__.py` — Os métodos de fora do núcleo, sobre o modelo universal: lltdrek (linha sustentadora não linear), AeroSandbox (VLM,
- `aerosim/aero/asb_solver.py` — AeroSandbox (Sharpe, MIT): três métodos sobre o mesmo modelo universal.
  `class AsbTranslator:31`, `class AsbVLMSolver:110`, `class AsbBuildupSolver:120`, `class AsbLiftingLineSolver:129`, `class AsbVLMLoads:175`
- `aerosim/aero/avl_solver.py` — AVL (Drela e Youngren, MIT; GPL): malha de vórtices em ferradura com superfícies de comando.
  `avl_exe:44`, `has_optvl:51`, `class AvlTranslator:68`, `class AvlSolver:136`
- `aerosim/aero/base.py` — Polar e derivadas comuns a todos os solvers: cada um só implementa `evaluate` (pontos de voo
  `class AeroSolverBase:23`
- `aerosim/aero/geometry.py` — Utilidades dos tradutores: eixos dos solvers externos, viscosidade/Reynolds, tabela de volumes
  `nu_air:34`, `reynolds:38`, `to_xz_up:42`
- `aerosim/aero/lltdrek_solver.py` — lltdrek (https://github.com/kuodrek/lltdrek, MIT): linha sustentadora não linear
  `class LltdrekTranslator:89`, `class LltdrekSolver:138`
- `aerosim/aero/sections.py` — Polar 2D dos perfis (camada abaixo dos métodos 3D): uma fonte por `ISectionPolar` e um cache só.
  `model_polar:58`, `neuralfoil_polar:69`, `read_polar_file:77`, `class ModelSection:115`, `class NeuralFoilSection:122`, `class FileSection:138`, `cache_dir:165`, `airfoil_key:169`, `clear_cache:221`, `section_polar:232`, `write_lltdrek_polar:254`

## Python · `aerosim/interfaces`

- `aerosim/interfaces/__init__.py` — Os contratos dos métodos de fora: a polar (`aero.py`) e o tradutor de cada método (`translator.py`).
- `aerosim/interfaces/aero.py` — Interface dos solvers aerodinâmicos (comparativo da aba Aerodinâmica).
  `class FlightPoint:26`, `class AeroCase:39`, `class AeroPolar:54`, `class IAeroSolver:72`, `class ISectionPolar:101`
- `aerosim/interfaces/translator.py` — Tradutores: modelo universal (`aerosim.model.universal.AircraftModel`) <-> formato de cada solver.
  `class IModelTranslator:21`

## Python · `aerosim/model`

- `aerosim/model/__init__.py` — O modelo do avião que os métodos de fora recebem: a configuração (`aircraft.py`) e o modelo universal
- `aerosim/model/aircraft.py` — Modelo de dados da aeronave (a "Aircraft Data").
  `class WingSection:25`, `class ControlSurface:42`, `mix_role:64`, `panel_mix:70`, `class WingDevice:80`, `class LiftingSurface:101`, `new_group_id:182`, `rect_sections:204`, `class Fuselage:212`, `class TailBoom:228`, `class PropulsionUnit:264`, `class GearLeg:284`, `class LandingGear:294`, `class SloshTank:330`, `class Payload:358`, `class Ballast:375`, `class PointMass:385`, `class MassModel:394`, `class Airfield:410`, `class Environment:447`, `class Takeoff:474`, `class Autopilot:490`, `class PerformanceData:540`, `class SimSettings:553`, `class Aircraft:568`
- `aerosim/model/airfoil.py` — Perfis: leitura de .dat (Selig ou Lednicer), gerador NACA 4 dígitos e teoria de
  `class Airfoil:14`, `naca4:51`, `read_dat:73`, `write_dat:93`, `camber_line:100`, `thin_airfoil:114`, `flap_effectiveness:126`, `helmbold:133`
- `aerosim/model/atmosphere.py` — Atmosfera padrão (ISA, troposfera) para a altitude-densidade (AD).
  `isa_density:15`, `density_altitude:21`
- `aerosim/model/catalog.py` — Itens de catálogo: motores, hélices e baterias (vários por arquivo).
  `class Motor:8`, `class Propeller:21`, `class Battery:34`, `class ThrustPoly:54`, `class Catalog:94`, `generic_propeller:133`, `builtin_catalog:150`
- `aerosim/model/devices.py` — Geometria dos dispositivos de asa (winglet, winglet para baixo, placa de ponta, cerca).
  `class Leg:22`, `attach_point:44`, `legs:52`, `device_area:77`
- `aerosim/model/features.py` — O que a aeronave tem — as abas de análise usam isto para decidir o que mostrar.
  `class Features:14`, `features:89`
- `aerosim/model/massprops.py` — Massa seca da aeronave: base (com inércia própria) + massas pontuais (Steiner).
  `point_items:12`, `dry_mass:63`
- `aerosim/model/mission.py` — Percurso como uma corrente de pernas (retas e curvas).
  `auto_radius:20`, `class Leg:26`, `class MissionEvent:41`, `class Mission:48`, `circuit:121`, `short_circuit:145`, `takeoff_runway:156`, `level_turn:161`
- `aerosim/model/modifiers.py` — Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro (efeito solo, esteira
  `class ParamInfo:28`, `class KindInfo:37`, `class Modifier:87`, `default_modifiers:105`, `active:110`, `ground_method:114`, `additive:120`, `problems:124`, `describe:137`, `is_default:148`, `not_exported:154`, `native:178`
- `aerosim/model/serialize.py` — dataclass <-> dicionário (genérico, guiado pelas anotações de tipo).
  `to_dict:10`, `from_dict:52`
- `aerosim/model/universal.py` — Modelo universal da aeronave — construído UMA vez a partir da configuração (`Aircraft`) e
  `class Control:31`, `class Station:41`, `class SurfaceModel:50`, `class AircraftModel:129`, `strip_coeffs:246`, `wing_downwash:289`, `build_model:362`

## Zig · núcleo (`core/src`)

**core/src/**

- `core/src/abi.zig` — Esquema das estruturas exportadas, gerado em comptime por reflexão.
- `core/src/aerosim.zig` — Documentação do núcleo do aerosim (`zig build docs`): todas as pastas de `core/src`, uma por seção.
  tipos `math:14`, `physics:22`, `modifiers:35`, `collision:45`, `control:50`, `sim:57`, `loads:71`, `structures:83`, `sizing:90`, `optim:104`, `geometry:120`, `util:125`
- `core/src/bench.zig` — Benchmarks exportados (o Python cronometra): funções matemáticas isoladas com tabelas
  tipos `Kind:9`
  fn `math:80`, `dynamics:98`
- `core/src/exemplo.zig` — O exemplo do README do núcleo: os limites de tamanho e os canais que cada corrida grava.
  fn `main:6`
- `core/src/interface.zig` — A interface conferida em comptime: o molde dos registros do projeto.
  tipos `Declaration:11`
  fn `require:18`, `has:33`
- `core/src/lib.zig` — O núcleo como módulo Zig (para programas em Zig, como o aerodrive): os mesmos tipos e funções
  tipos `structures:57`, `optim:63`
- `core/src/limits.zig` — Limites de compilação. Toda a memória do núcleo é estática e dimensionada aqui:
  tipos `Group:18`
  fn `groupIndex:30`
- `core/src/methods.zig` — Os métodos de cálculo do voo, juntos: quem dá as forças, qual linha sustentadora e quanto refino.
  tipos `Methods:12`
  fn `label:34`, `choices:53`, `byName:64`
- `core/src/numerics.zig` — O refino numérico dos solvers do núcleo num lugar só: quantas iterações, que tolerância, que passo.
  tipos `Numerics:12`, `Solver:159`, `Info:180`
  fn `solverTitle:162`, `count:257`
- `core/src/opt.zig` — Otimizações em avaliação (`-Dopt`): cada uma é um bit, desligado por padrão (ver core/OTIMIZACOES.md).
  tipos `Opt:5`
- `core/src/root.zig` — Interface C ABI do núcleo (o que o Python chama via ctypes).
  fn `abiCode:51`
  **ABI (92 exports)** `aerosim_abi_version`, `aerosim_schema`, `aerosim_probe_ground`, `aerosim_probe_slipstream`, `aerosim_aero_coeffs_thrust`, `aerosim_aero_coeffs_at`, `aerosim_tube_panel_hits`, `aerosim_tube_point_hits`, `aerosim_prop_state`, `aerosim_panel_states`, `aerosim_panel_states_llt`, `aerosim_wing_sweep`, `aerosim_wing_sweep_summary`, `aerosim_reynolds`, `aerosim_aero_coeffs_llt`, `aerosim_schema_hash`, `aerosim_acquire`, `aerosim_release`, `aerosim_params`, `aerosim_params_reset`, `aerosim_configure`, `aerosim_reset_ground`, `aerosim_reset_air`, `aerosim_run`, `aerosim_events`, `aerosim_time`, `aerosim_snapshot_size`, `aerosim_snapshot_save`, `aerosim_snapshot_load`, `aerosim_mass_props`, `aerosim_aero_coeffs`, `aerosim_aero_coeffs_ex`, `aerosim_linearize`, `aerosim_linearize_slosh`, `aerosim_autotune`, `aerosim_prop_point`, `aerosim_trim`, `aerosim_performance`, `aerosim_envelope`, `aerosim_envelope_curve`, `aerosim_simple_perf`, `aerosim_bench_math`, `aerosim_bench_dynamics`, `aerosim_fast_math`, `aerosim_expr_check`, `aerosim_expr_eval`, `aerosim_ground_runs`, `aerosim_ground_mtow`, `aerosim_motor_prop_thrust`, `aerosim_motor_prop_points`, `aerosim_section_check`, `aerosim_section_torsion`, `aerosim_buckling`, `aerosim_gear_frame`, `aerosim_gear_landing`, `aerosim_vn_diagram`, `aerosim_vn_envelope`, `aerosim_span_internal`, `aerosim_aeroelastic`, `aerosim_beam_modes`, `aerosim_flutter`, `aerosim_sizing_eval`, `aerosim_sizing_optimize`, `aerosim_sizing_name`, `aerosim_sizing_defaults`, `aerosim_geometry_check`, `aerosim_ga_init`, `aerosim_ga_next`, `aerosim_cma_init`, `aerosim_cma_ask`, `aerosim_cma_tell`, `aerosim_de_init`, `aerosim_de_trials`, `aerosim_de_trials_with`, `aerosim_de_select`, `aerosim_local_fit`, `aerosim_rbf_fit`, `aerosim_rbf_eval`, `aerosim_lhs`, `aerosim_repair_step`, `aerosim_eps_level`, `aerosim_eps_worse`, `aerosim_bandit_state_len`, `aerosim_bandit_init`, `aerosim_bandit_pick`, `aerosim_bandit_update`, `aerosim_normative`, `aerosim_lem_box`, `aerosim_box_sample`, `aerosim_sens_tolerance`, `aerosim_morris_design`, `aerosim_morris_effects`
- `core/src/tecnicas.zig` — Bancada das técnicas de otimização (tarefa G27): cada técnica roda a conta de hoje do núcleo e a candidata no
  fn `main:433`
- `core/src/tests.zig` — Todos os testes do núcleo, por grupo. `zig build test` roda tudo; `-Dgrupo=math` roda só um grupo e
- `core/src/types.zig` — Estruturas trocadas com o Python (C ABI, `extern struct`).
  tipos `ThrustModel:20`, `PolyVariable:29`, `AeroModel:45`, `LiftingLineMethod:56`, `Refinement:68`, `Surface:78`, `GroundSettings:116`, `GroundTable:132`, `PropUnit:149`, `GearKind:191`, `Gear:201`, `TankShape:210`, `Tank:223`, `Segment:239`, `EventKind:260`, `Event:269`, `Pad:273`, `Payload:282`, `Environment:293`, `Takeoff:305`, `Pilot:323`, `Autopilot:333`, `AeroTable:382`, `LltCache:415`, `Params:429`, `PanelState:526`, `SweepSummary:546`, `Events:554`, `LogRow:596`, `AeroCoeffs:710`, `PropPoint:725`, `MassProps:737`, `TrimKind:745`, `TrimPoint:756`, `PerfRow:773`

**core/src/collision/**

- `core/src/collision/collision.zig` — Colisão geométrica: o que fica dentro do tubo de uma hélice (cilindro do raio dela ou o tubo que contrai da
  tipos `Tube:14`, `Strip:43`
  fn `stripFraction:60`

**core/src/control/**

- `core/src/control/autopilot.zig` — Piloto automático.
  tipos `Cmd:18`, `Input:33`
  fn `qTurn:56`, `commands:63`
- `core/src/control/autotune.zig` — Ajuste automático dos ganhos do piloto automático, igual para qualquer avião.
  tipos `Targets:21`, `Result:32`
  fn `fromLinear:56`, `tune:147`
- `core/src/control/exemplo.zig` — O exemplo do README de `control/`: os ganhos ajustados para 14 m/s e a missão do avião dos testes com eles.
  fn `main:9`
- `core/src/control/guidance.zig` — Percurso (corrente de segmentos) e guiamento lateral.
  tipos `Guide:15`
  fn `guide:38`, `rejoinSegment:102`

**core/src/geometry/**

- `core/src/geometry/exemplo.zig` — O exemplo do README de `geometry/`: um avião de cinco peças conferido parado e girado 12° na decolagem.
  fn `main:11`
- `core/src/geometry/geometry.zig` — Geometria do avião montado: se as peças cabem juntas antes de qualquer conta de aerodinâmica.
  tipos `PartKind:29`, `Part:39`, `Scene:47`, `Report:60`
  fn `boxesTouch:98`, `pointInBox:116`, `pointNearBox:121`, `discHitsBox:130`, `discsTouch:204`, `lowest:236`, `check:265`, `checkMany:361`

**core/src/loads/**

- `core/src/loads/aeroelastic.zig` — Aeroelasticidade estática de uma semiasa em faixas: divergência em torção e reversão do aileron.
  tipos `Station:25`, `Aeroelastic:37`
  fn `flapDerivatives:49`, `divergencePressure:74`, `rollEffectiveness:94`, `analyze:128`
- `core/src/loads/exemplo.zig` — O exemplo do README de `loads/`: o mesmo avião a 14 m/s e α = 4° pelas faixas e pela linha sustentadora.
  fn `main:8`
- `core/src/loads/flutter.zig` — Flutter de uma semiasa: viga de elementos finitos (flexão e torção acopladas pela massa), reduzida aos primeiros
  tipos `Element:42`, `ModePoint:55`, `FlutterResult:61`, `Modes:74`
  fn `modes:154`, `theodorsen:203`, `pk:270`, `flutter:312`
- `core/src/loads/internal.zig` — Esforços internos ao longo da envergadura de uma semiasa (ou de um tubo de cauda), da ponta para a raiz: cortante,
  fn `shareByArea:27`, `efforts:35`, `deflection:56`, `twist:70`
- `core/src/loads/llt.zig` — Linha sustentadora numérica (vórtices em ferradura) para a distribuição de carga ao longo da envergadura.
  tipos `Curve:79`, `Node:265`
  fn `sectionSlope:67`, `sectionLift:83`, `stallAngle:116`, `segment:128`, `horseshoe:145`, `surfaceNodes:176`, `prepare:347`, `apply:464`, `compute:604`, `coeffs:636`
- `core/src/loads/stall.zig` — Estol por estação: o VLM (`vlm.zig`) acoplado à polar 2D de cada estação no seu Reynolds, pela correção de α
  tipos `Family:34`, `Settings:40`, `Sections:48`, `Station:55`, `Work:68`, `Point:79`, `Sweep:87`
  fn `stationCount:99`, `point:330`, `next:342`, `sweep:366`
- `core/src/loads/sweep.zig` — Varredura das asas em α (subaba Asas da Aerodinâmica): só as superfícies escolhidas, sem trimar, sem fuselagem e
  tipos `Method:27`, `Output:33`, `Summary:84`
  fn `sweep:49`, `summarize:93`, `isaTemperature:135`, `airViscosity:141`, `reynolds:150`
- `core/src/loads/trefftz.zig` — Dispositivos de ponta de asa pelo arrasto induzido mínimo no plano de Trefftz (o par de
  tipos `Segment:24`, `Kind:27`, `Workspace:47`, `Loading:56`, `Study:211`, `StudyPoint:223`
  fn `trace:91`, `optimal:127`, `efficiency:196`, `raymerOswald:206`, `studyPoint:232`
- `core/src/loads/vlm.zig` — Método dos vórtices em malha (VLM) do avião: cada faixa sustentadora do núcleo (`Params.surf`) vira uma malha de
  tipos `Grid:41`, `Panel:44`, `Buffers:63`, `Loads:73`, `Coefficients:80`, `Derivatives:92`
  fn `panelCount:112`, `lattice:160`, `factor:231`, `solve:269`, `substitute:281`, `loads:296`, `velocityAt:319`, `coefficients:326`, `derivatives:347`, `groundCoefficients:387`, `groundCoefficientsWith:392`
- `core/src/loads/vn.zig` — Diagrama V-n: o envelope de manobra e o de rajada, e os casos de carga que saem dele.
  tipos `VnNorm:20`, `VnAircraft:31`, `LoadCase:41`, `CaseKind:50`, `VnResult:55`
  fn `gustAlleviation:76`, `gustIncrement:82`, `maneuverLimits:88`, `envelope:95`, `diagram:111`

**core/src/math/**

- `core/src/math/fmath.zig` — Funções matemáticas: tabelas (LUT) + aproximações polinomiais, e a referência da std.
  tipos `SinCos:39`, `lut:83`, `ref:180`, `minimax:238`
  fn `optOn:22`, `mulAdd:31`, `SinLut:42`, `sincos:283`, `sin:287`, `cos:291`, `tan:295`, `atan:300`, `atan2:304`, `asin:308`, `acos:313`, `exp:318`, `log:322`, `pow:327`, `tanh:332`, `sqrt:336`, `hypot:340`, `sat:346`, `lim:350`, `sgn:354`, `wrap:358`
- `core/src/math/fmath_test.zig` — Testes só das LUTs e aproximações (independentes de -Dfast_math: comparam `lut` com `ref`).
- `core/src/math/interpolation.zig` — Interpolação polinomial num trecho [0, 1]: as funções de forma que dizem quanto cada valor nos extremos pesa num
  fn `linear:13`, `linearSlope:18`, `hermite:23`, `hermiteCurvature:30`
- `core/src/math/linalg.zig` — Álgebra linear densa de tamanho fixo: fatoração LU com pivoteamento parcial e de Cholesky, e as
  fn `luFactor:16`, `luSolve:41`, `cholesky:60`, `cholSolve:78`, `symEigen:95`, `generalEigen:142`, `solve:366`
- `core/src/math/poly.zig` — Polinômio em duas variáveis de grau N gerado em comptime, na ordem dos ajustes do MATLAB
  fn `Poly2:11`
- `core/src/math/quadrature.zig` — Integral numérica por Gauss-Legendre: ∫ f ≈ Σ w_i f(x_i), com n pontos x_i e pesos w_i escolhidos para a soma
  fn `Rule:12`, `gaussLegendre:31`, `gaussLegendreUnit:39`
- `core/src/math/vec.zig` — Vetores 3D em registradores SIMD (@Vector) e matrizes 3x3 por linhas.
  fn `v3:11`, `arr:15`, `splat:19`, `dot:23`, `norm:27`, `cross:31`, `mul:40`, `mulT:44`, `rotation:49`, `solve3:67`

**core/src/modifiers/**

- `core/src/modifiers/exemplo.zig` — O exemplo do README de `modifiers/`: o fator do efeito solo em três alturas e a esteira da hélice ligada.
  fn `main:16`
- `core/src/modifiers/flapmoment.zig` — Momento próprio do comando (flape, profundor, elevon) no quarto de corda da faixa.
  fn `thetaOf:17`, `cmDelta:30`
- `core/src/modifiers/ground.zig` — Efeito solo: métodos para o fator do arrasto induzido perto do chão.
  tipos `Effect:120`
  fn `factor:25`, `mccormick:33`, `buildTable:65`, `lookup:129`
- `core/src/modifiers/interference.zig` — Interferência entre as asas da configuração no modelo de faixas, para quantas asas houver.
  fn `active:30`, `induced:40`
- `core/src/modifiers/mod.zig` — Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro sem mexer no resto
  tipos `Env:22`
  fn `envFrom:37`, `slipstreamGrid:57`, `stripOf:66`, `induced:73`, `inducedAlone:78`, `flapCm:98`
- `core/src/modifiers/slipstream.zig` — Esteira da hélice por disco atuador (modificador `esteira.disco`).
  tipos `TubeShape:32`, `Point:82`
  fn `shape:49`, `diskInduced:54`, `axialAt:62`, `radiusAt:67`, `swirlRate:75`, `at:90`
- `core/src/modifiers/types.zig` — Tipos dos modificadores trocados com o Python (C ABI, `extern struct`; o esquema sai de `abi.zig`).
  tipos `Ground:29`, `ModifierKind:42`, `Flags:57`, `SlipstreamSettings:68`, `InterferenceSettings:76`, `FlapMomentSettings:82`, `Modifier:91`
  fn `panelSet:19`

**core/src/optim/**

- `core/src/optim/cmaes.zig` — CMA-ES: a estratégia evolutiva com adaptação da matriz de covariância, para as variáveis contínuas do aeroopt
  tipos `CmaState:24`
  fn `init:48`, `ask:117`, `tell:133`
- `core/src/optim/de.zig` — Evolução diferencial (DE/rand/1/bin), para as variáveis contínuas do aeroopt (envergadura, área, diedro...).
  tipos `Strategy:46`, `Bound:54`, `Options:62`
  fn `initPop:36`, `trials:70`, `trialsWith:84`, `select:126`
- `core/src/optim/exemplo.zig` — O exemplo do README de `optim/`: o CMA-ES achando o ótimo de um problema de teste em três variáveis.
  fn `main:6`
- `core/src/optim/expr.zig` — Executa o programa de pilha da pontuação (`types.Program`): as entradas de um candidato entram nas
  tipos `Error:11`
  fn `check:22`, `run:71`, `runMany:115`
- `core/src/optim/ga.zig` — Gerações de aviões: o algoritmo genético que escolhe as configurações do aeroopt no lugar de varrer todas as
  tipos `GaCfg:21`
  fn `init:47`, `next:64`
- `core/src/optim/guided.zig` — Busca guiada pela falha: as peças que deixam o otimizador usar o MOTIVO de um avião não voar, e não só o quanto
  fn `repairStep:50`, `epsLevel:76`, `epsWorse:83`, `stagedViolation:96`, `banditInit:114`, `banditPick:131`, `banditUpdate:150`, `normative:193`, `lemBox:212`, `boxSample:253`
- `core/src/optim/localfit.zig` — Modelo local por mínimos quadrados ponderados: a partir de pontos já avaliados em volta de um ponto x₀, a
  tipos `Fit:24`
  fn `fit:54`
- `core/src/optim/rbf.zig` — Substituto por funções de base radial (RBF): a superfície que passa exatamente por todos os pontos já avaliados e
  fn `size:23`, `fit:73`, `eval:100`
- `core/src/optim/sampling.zig` — Amostragem do espaço de busca: de onde nascem os primeiros indivíduos das buscas contínuas do aeroopt.
  fn `minDist2:38`, `lhs:55`
- `core/src/optim/scalar.zig` — As buscas de uma variável só, para quem chama a avaliação por conta própria (uma simulação, uma montagem do
  tipos `Bisection:15`, `SignBisection:41`, `GoldenSection:66`
  fn `secant:96`
- `core/src/optim/sensmethods.zig` — Os métodos da sensibilidade do melhor avião do aeroopt (`aeroopt/sensitivity.py`), além do modelo local
  fn `tolerance:29`, `morrisDelta:44`, `morrisDesign:53`, `morrisEffects:78`
- `core/src/optim/topology.zig` — A árvore de topologias: uma busca só para várias configurações do avião (as da tabela de asas do projeto, de
  tipos `Layout:17`, `Archive:55`
- `core/src/optim/types.zig` — Tipos do aeroopt no núcleo: o programa de pilha que calcula a nota de um candidato. O Python traduz o
  tipos `Op:12`, `Tier:30`, `Program:37`

**core/src/physics/**

- `core/src/physics/aero.zig` — Aerodinâmica por componentes.
  tipos `Out:19`
  fn `sigmaStall:29`, `init:94`, `compute:127`, `computeEnv:132`, `computeTrace:137`, `fuselage:267`, `coeffs:282`, `coeffsEx:287`, `coeffsEnv:292`, `coeffsAt:297`
- `core/src/physics/aeromodel.zig` — O modelo aerodinâmico do voo, escolhido por `Params.aero_model` (`types.AeroModel`): quem a dinâmica, a trimagem e
  fn `compute:18`
- `core/src/physics/aerotable.zig` — Modelo aerodinâmico por tabela (Params.aero_model = 2): os coeficientes do avião inteiro vêm de `Params.aero_tab`,
  fn `coeffs:34`, `compute:50`
- `core/src/physics/atmosphere.zig` — Vento 3D numa direção (perfil 1/7 com a altura) e rajada 1-cos.
  fn `wind:8`
- `core/src/physics/exemplo.zig` — O exemplo do README de `physics/`: os coeficientes, o motor com o acelerador cheio e a massa do avião dos testes.
  fn `main:8`
- `core/src/physics/gear.zig` — Trem de pouso: N pontos de contato (triciclo, convencional, patins...).
  tipos `Out:16`
  fn `compute:23`, `touching:65`
- `core/src/physics/mass.zig` — Massa, CG e inércia variáveis; sloshing de N tanques; extração da carga (LAPES).
  tipos `Mass:49`, `Load:105`
  fn `initTanks:17`, `compute:58`, `slosh:109`, `payload:138`
- `core/src/physics/propulsion.zig` — K unidades propulsoras: hélice por tabela C_T(J), C_P(J) + motor BLDC + bateria.
  tipos `Unit:22`, `Out:34`
  fn `init:48`, `polyRaw:106`, `tiltNow:123`, `axis:130`, `unit:138`, `powerLimitedCurrent:170`, `compute:187`, `equilibriumRps:225`, `point:255`
- `core/src/physics/section.zig` — Polar 2D de um perfil e os números que saem dela, a etapa Perfis do dimensionamento.
  tipos `Airfoil:22`, `Polar:31`, `Metrics:231`, `DragBranch:350`
  fn `stallAngle:46`, `modelPolar:60`, `interpolate:75`, `atReynolds:96`, `parsePolar:212`, `metrics:253`, `reynolds:345`, `dragBranch:371`, `fitted:402`
- `core/src/physics/terrain.zig` — Terreno: chão plano (h = 0) com mesas/plataformas retangulares elevadas.
  fn `height:9`

**core/src/sim/**

- `core/src/sim/dynamics.zig` — Equação mestre f(t, x) (`derivatives`) e integração RK4.
  tipos `Out:26`
  fn `derivatives:87`, `rk4:248`
- `core/src/sim/envelope.zig` — Envelope de voo por altitude (sem integrar no tempo).
  tipos `EnvelopeMethod:32`, `Atmosphere:41`, `EnvCfg:50`, `EnvRow:88`
  fn `density:101`, `compute:314`, `curve:347`
- `core/src/sim/exemplo.zig` — O exemplo do README de `sim/`: vinte segundos de decolagem, o equilíbrio a 14 m/s e os modos de voo ali.
  fn `main:9`
- `core/src/sim/gust.zig` — Resposta no tempo a uma rajada, em voo nivelado reto: o avião sai equilibrado em `airspeed` e `height`, a rajada
  tipos `Case:24`, `Mode:180`, `Poles:185`
  fn `begin:41`, `advance:103`, `settled:129`, `respond:163`, `gustSpeed:172`, `poles:208`
- `core/src/sim/linear.zig` — Modelo linear em torno do voo nivelado equilibrado (estabilidade dinâmica).
  tipos `LinModel:29`, `LinSloshModel:231`
  fn `rigid:57`, `linearize:170`, `linearizeSlosh:291`, `residual:332`
- `core/src/sim/modes.zig` — Os modos dinâmicos do avião equilibrado e as qualidades de voo: o que a aba Estabilidade mostra depois da
  tipos `Mode:23`, `Pole:26`, `Class:167`, `Phase:169`, `Check:171`, `Criteria:185`, `Row:242`, `Input:347`
  fn `classify:67`, `liquidPoles:152`, `rollRequirement:174`, `mil8785c:208`, `noCriteria:236`, `evaluate:251`, `passes:338`, `respond:368`
- `core/src/sim/runner.zig` — Executor de uma corrida: eventos discretos, paradas, registro e checkpoints.
  tipos `Status:27`, `Instance:38`
  fn `stateText:68`, `configure:98`, `handover:166`, `resetGround:188`, `resetAir:242`, `run:398`
- `core/src/sim/simple_perf.zig` — Desempenho por cálculo simples (sem simulação no tempo), como na "planilha suprema":
  tipos `SimpleCfg:23`, `SimpleRow:52`, `SimpleSummary:76`
  fn `density:108`, `compute:132`
- `core/src/sim/state.zig` — Layout do vetor de estados (definido em comptime a partir dos limites)
  tipos `Entry:7`, `Flags:87`, `Run:103`, `Ctx:119`
  fn `index:57`, `rps:66`, `sx:70`, `sy:74`, `sxd:78`, `syd:82`
- `core/src/sim/static.zig` — Estabilidade estática do avião montado: o que a aba Estabilidade calcula antes da dinâmica. É a mesma conta de
  tipos `Inputs:32`, `Probe:35`, `Sweep:214`, `Variable:291`, `Limits:371`, `WingStrip:434`, `Aileron:437`, `RollSizing:450`, `ElevatorSizing:526`, `RudderSizing:572`
  fn `cgSweep:227`, `limitCrossing:254`, `gearForRotation:268`, `derivative:295`, `rollDamping:328`, `yawDamping:334`, `alphaForLift:342`, `scissorLimits:375`, `minTail:400`, `timeToBank:415`, `aileronSizing:462`, `interpolate:506`, `elevatorSizing:535`, `rudderSizing:585`
- `core/src/sim/tests.zig` — Testes de integração do núcleo: aeronave monomotora convencional (a do código
  fn `aircraft:18`
- `core/src/sim/trim.zig` — Equilíbrio (trimagem) e desempenho por velocidade, sem integração no tempo.
  tipos `Ctx:26`
  fn `solve:133`, `performance:147`

**core/src/sizing/**

- `core/src/sizing/chain.zig` — A cadeia do mini-MDO para um tipo de aeronave e um provedor de tração, gerada em comptime:
  tipos `CoreThrust:25`, `LinearThrust:48`
  fn `checkThrust:19`, `decode:59`, `motorsFor:81`, `Chain:97`
- `core/src/sizing/constraints.zig` — O diagrama de restrições do dimensionamento inicial (o par de `aerosim/sizing/constraints.py`): a razão
  tipos `ParabolicPolar:26`, `Requirements:45`, `Kind:64`, `Limit:98`, `DesignPoint:189`
  fn `estimatePolar:37`, `isaRho:116`, `conditionSpeed:121`, `requiredThrustWeight:133`, `limitLoading:166`, `envelope:174`, `designPoint:207`
- `core/src/sizing/exemplo.zig` — O exemplo do README de `sizing/`: a envergadura e a área livres, uma pista de 50 m e dez iterações do enxame.
  fn `main:10`
- `core/src/sizing/ground.zig` — Corrida de decolagem rápida da sprint (etapa Motores, `aerosim/design/power.py: performance`): a mesma
  tipos `GroundRun:24`
  fn `interp:51`, `rotSpeed:78`, `run:88`, `mtow:114`
- `core/src/sizing/kinds.zig` — Tipos de aeronave do dimensionamento: cada um é um tipo Zig com a mesma interface, conferida em
  tipos `Hover:20`, `Conventional:49`, `FlyingWing:76`, `Tailsitter:102`, `Vtol:128`
  fn `pairSigma:25`, `wingsInducedFactor:37`, `check:158`
- `core/src/sizing/motorprop.zig` — Tração em regime de um conjunto motor + hélice + bateria com acelerador cheio, para a curva T(V) da sprint
  tipos `MotorProp:39`, `Limit:64`, `Point:74`
  fn `point:98`, `thrust:138`, `curve:143`, `curvePoints:148`
- `core/src/sizing/optimize.zig` — Otimizadores do mini-MDO atrás de uma interface só.
  tipos `Eval:16`, `Problem:21`, `Recorder:50`, `Result:79`, `Pso:100`, `RandomSearch:156`
  fn `check:188`, `run:198`
- `core/src/sizing/sizing.zig` — Dimensionamento inicial (mini-MDO) no núcleo: avalia um vetor de projeto e otimiza.
  fn `eval:20`, `fitness:29`, `optimize:49`, `name:59`
- `core/src/sizing/stages.zig` — Estágios da cadeia de dimensionamento, cada um uma função pura com entradas e saídas pequenas:
  tipos `Curve:19`, `Geo:43`, `Polar:69`, `Env:84`, `Mass:213`
  fn `geometry:46`, `blendAirfoils:57`, `polar:72`, `stallSpeed:96`, `envelope:101`, `sustainedN:134`, `isaRho:143`, `isaAltitude:148`, `ceiling:153`, `landingRun:177`, `takeoffRun:183`, `canHover:208`, `emptyMass:216`, `linearCurve:230`
- `core/src/sizing/tail.zig` — A empenagem da etapa "Empenagem e comandos" (`aerosim/design/tail.py`): áreas por volume de cauda, estática
  tipos `Layout:21`, `Wing:47`, `OtherWing:66`, `PitchStrip:74`, `TailAirfoil:84`, `Input:92`, `Result:132`, `Statics:358`
  fn `helmbold:34`, `flapEffectiveness:40`, `analyze:201`
- `core/src/sizing/types.zig` — Tipos do dimensionamento inicial (mini-MDO): a configuração que vem do Python, o vetor de
  tipos `Variable:15`, `VarKind:49`, `VarSpec:57`, `Quantity:65`, `Comparison:136`, `Constraint:146`, `AirfoilData:164`, `LayoutData:175`, `PropSet:185`, `AircraftKind:193`, `Objective:206`, `SizingCfg:214`, `SizingOut:257`, `SearchMethod:274`, `OptOpts:283`, `Individual:295`
  fn `variable:44`, `quantity:116`, `massDependent:123`, `constrained:131`, `violation:154`
- `core/src/sizing/wing_line.zig` — A etapa Asa do dimensionamento: do perfil escolhido à asa trapezoidal, pela linha sustentadora de Prandtl
  tipos `Trapezoid:39`, `Partition:54`, `SectionAirfoil:64`, `Conditions:70`, `Station:91`, `Planform:97`, `Result:282`
  fn `isaDensity:80`, `reynolds:86`, `planformOf:188`, `planformOfPartitions:209`, `totals:238`, `partitionsFromTrapezoid:251`, `analyze:437`, `analyzePlanform:445`, `modelSection:546`

**core/src/structures/**

- `core/src/structures/buckling.zig` — Flambagem do chapeado e da alma, e quantas nervuras um vão precisa para o chapeado não flambar.
  tipos `Orthotropic:24`
  fn `flatPlate:44`, `curvedPanel:56`, `arcRadius:79`, `webShear:84`, `ribsNeeded:95`
- `core/src/structures/exemplo.zig` — O exemplo do README de `structures/`: uma longarina com alma de balsa e dois tubos de carbono sob 60 N·m.
  fn `main:6`
- `core/src/structures/gear.zig` — Trem de pouso: a treliça de tubos como pórtico 3D de elementos finitos (6 graus por nó), as margens de cada tubo e o
  tipos `Node:28`, `Member:37`, `MemberResult:48`, `Drop:243`, `DropResult:257`
  fn `solveFrame:143`, `landing:275`
- `core/src/structures/section.zig` — Seção composta de uma viga (longarina, tubo de cauda): a seção é uma soma de partes (alma, mesas, tubos, chapeado),
  tipos `Material:23`, `SectionPart:35`, `SectionProperties:63`, `PartStress:71`, `Wall:150`
  fn `properties:88`, `bendingStress:112`, `normalMargin:117`, `stresses:124`, `webShear:134`, `shearMargin:139`, `closedCellTorsion:158`, `openTorsion:171`, `tubeTorsion:181`

**core/src/util/**

- `core/src/util/fuzz.zig` — Fuzzing dos módulos.
  tipos `Src:15`
  fn `check:60`, `checkScaled:69`
- `core/src/util/plot.zig` — Gráficos de linha em SVG, sem nenhuma dependência: os testes do núcleo desenham o que calcularam, para o dono
  tipos `Series:11`, `Style:18`, `Figure:21`
  fn `writeSvg:63`, `save:156`, `fromTest:167`
- `core/src/util/xflr5.zig` — A polar de avião exportada pelo XFLR5 (análise de avião por LLT, VLM1, VLM2 ou painéis; Polars → Export), lida
  tipos `Method:14`, `Polar:30`
  fn `parse:67`
- `core/src/util/xlsx.zig` — Leitor de planilhas `.xlsx` sem dependência de fora: o arquivo é um `.zip` (APPNOTE da PKWARE) com uma folha de
  tipos `Value:18`, `Cell:34`, `Sheet:41`, `Workbook:71`
  fn `parseAddress:114`


## Zig · AeroDrive (`aerodrive/src`)

**aerodrive/src/**

- `aerodrive/src/aircraft_model.zig` — O modelo do avião do AeroDrive como módulo para quem só quer ler e desenhar o avião (a interface do aerosim
- `aerodrive/src/main.zig` — AeroDrive: abre o menu inicial com o avião (o último escolhido, ou o do argumento).
- `aerodrive/src/tests.zig` — Todos os testes do aerodrive que não precisam de janela (`zig build test`).

**aerodrive/src/app/**

- `aerodrive/src/app/app.zig` — O jogo inteiro: o que as telas dividem (fontes, widgets, configurações, o avião carregado, som,
  tipos `Id:51`, `Next:53`, `Plane:62`, `Screens:81`, `App:96`
- `aerodrive/src/app/library.zig` — Biblioteca de aviões: os `.json` das pastas de exemplos e de "meus aviões" (os salvos pela
  tipos `Group:8`, `Entry:20`, `Library:28`
  fn `scan:43`, `fingerprint:81`, `safeFileName:117`, `entryName:136`
- `aerodrive/src/app/paths.zig` — Onde ficam as coisas no disco, a partir das variáveis de ambiente:
  tipos `Paths:12`
  fn `resolve:31`
- `aerodrive/src/app/plane_settings.zig` — Configurações de cada avião, lembradas por arquivo: a sessão (chão/mesa, pouso, quem pilota,
  tipos `PlaneSettings:14`
- `aerodrive/src/app/settings.zig` — Configurações do jogador, guardadas entre uma vez e outra: avião escolhido, sessão (cenário,
  tipos `CameraKind:10`, `CameraSettings:12`, `Settings:27`
  fn `sanitizeProfile:112`
- `aerodrive/src/app/storage.zig` — Interface de armazenamento por caminho: ler, gravar, listar e apagar. Configurações, biblioteca
  tipos `Kind:28`, `Entry:30`, `Listing:36`, `Storage:52`, `DiskStorage:85`, `BrowserStorage:140`
  fn `parseListing:174`
- `aerodrive/src/app/store.zig` — Interface de armazenamento chave → bytes (e JSON por cima). Quem guarda configurações não sabe
  tipos `Store:14`, `FileStore:51`, `MemStore:80`
  fn `keyFor:126`

**aerodrive/src/audio/**

- `aerodrive/src/audio/engine_sound.zig` — Som do motor e do vento: acelerador → altura (pitch) e volume da hélice; velocidade do ar →
  tipos `Tuning:8`, `Engine:16`, `Out:31`, `WindTuning:42`
  fn `map:33`, `wind:50`
- `aerodrive/src/audio/player.zig` — Toca os sons (raylib). Os .mp3 vão dentro do programa (`assets/`):
  tipos `Player:56`

**aerodrive/src/camera/**

- `aerodrive/src/camera/camera.zig` — Câmeras: cada uma é um objeto com a mesma interface (`update` + `view`); a tela só pede a vista.
  tipos `View:11`, `Input:19`, `Orbit:26`, `Chase:63`, `Ground:91`, `Camera:115`

**aerodrive/src/gfx/**

- `aerodrive/src/gfx/pose.zig` — Onde cada peça está num instante: driver da peça + estado do voo -> transformação rígida.
  tipos `DriveState:18`, `Rigid:28`
  fn `about:48`, `piece:54`, `body:72`
- `aerodrive/src/gfx/render.zig` — Desenho com raylib (pelo raylib-zig) — a única parte que conhece a biblioteca gráfica, junto
  tipos `Scene:90`
  fn `toScreen:27`, `matrix:33`, `camera3d:44`, `color:48`, `hangarGrid:166`, `drawField:179`, `drawTrail:199`

**aerodrive/src/input/**

- `aerodrive/src/input/channels.zig` — Canais de comando: o que está apertado no controle (eixos −1..1, gatilhos 0..1, botões) ->
  tipos `Source:15`, `Pad:46`, `Action:66`, `Bindings:100`, `Scheme:126`, `Curve:152`, `Raw:175`, `Commands:191`, `Profile:193`, `Inputs:224`, `State:227`
- `aerodrive/src/input/gamepad.zig` — Leitura do controle e do teclado (raylib) → o que está apertado (`channels.Raw`) + botões de
  tipos `Actions:24`, `Reader:34`
  fn `toRaylib:119`, `pressedButton:141`
- `aerodrive/src/input/touch.zig` — Controles por toque (celular, tablet): dois manches virtuais e dois botões, desenhados sobre o
  tipos `Point:16`, `Stick:18`, `Button:23`, `ButtonArea:25`, `Layout:30`, `State:58`, `Controls:74`
  fn `layout:38`

**aerodrive/src/math/**

- `aerodrive/src/math/vec3.zig` — Vetores 3D (f64) e rotações usados pelo modelo, pelo esqueleto e pelas câmeras.
  fn `add:8`, `sub:11`, `scale:14`, `mul:17`, `dot:20`, `cross:23`, `norm:26`, `finite:29`, `unit:34`, `apply:43`, `matmul:47`, `axisAngle:56`, `bodyToNed:71`

**aerodrive/src/model/**

- `aerodrive/src/model/aircraft.zig` — Leitura do arquivo do avião salvo pela GUI (`data/aircraft/*.json`, "meus aviões").
  tipos `Section:12`, `Control:20`, `Device:59`, `Airfoil:76`, `Surface:87`, `Fuselage:119`, `Boom:136`, `Propeller:165`, `Motor:166`, `Battery:167`, `ThrustPoly:178`, `Propulsion:191`, `GearLeg:208`, `Gear:209`, `Tank:232`, `Payload:252`, `PointMass:266`, `Mass:267`, `Environment:278`, `Takeoff:306`, `SimSettings:307`, `Autopilot:309`, `Leg:354`, `MissionEvent:367`, `Mission:368`, `Ballast:378`, `Airfield:379`, `Modifier:397`, `Performance:412`, `Aircraft:423`, `limits:459`, `Diag:483`, `Loaded:497`
  fn `mixedAirfoils:15`, `kindGains:49`, `parse:507`, `validate:566`, `semispan:653`, `sortedSections:660`, `sectionAt:672`, `tailOnBoom:685`, `mountPoint:703`, `applyMounts:737`
- `aerodrive/src/model/airfoil.zig` — Perfil 2D (x/c, y/c): NACA de 4 dígitos pelo nome ou as coordenadas do arquivo do avião.
  tipos `Profile:13`
  fn `nacaDigits:23`, `naca4:39`, `forDrawing:79`, `invert:95`, `full:102`, `thinAirfoil:126`, `flapEffectiveness:176`, `helmbold:183`, `split:190`
- `aerodrive/src/model/features.zig` — O que a aeronave tem — para as telas se montarem sozinhas: quais canais de comando existem
  tipos `Channel:12`, `Features:28`, `Focus:128`
  fn `detect:64`, `stallLimit:103`, `focus:130`
- `aerodrive/src/model/skeleton.zig` — Esqueleto da aeronave: as peças que se desenham, cada uma com o seu *driver* (como se move).
  tipos `Color:27`, `Mesh:51`, `Driver:56`, `Piece:64`, `Skeleton:72`, `Station:138`, `Leg:386`
  fn `rgba:30`, `controlMix:94`, `build:124`, `stations:141`, `controlAt:171`, `frame:180`, `thrustAxis:380`, `gearLegs:389`

**aerodrive/src/record/**

- `aerodrive/src/record/datalog.zig` — Dados de um voo gravado: as linhas do núcleo (todas as grandezas escalares do `LogRow`, mais
  tipos `DataLog:19`, `Table:68`
- `aerodrive/src/record/pages.zig` — As páginas de gráficos de um voo gravado — as mesmas grandezas da aba Missão da GUI: planos
  tipos `Series:10`, `Page:12`, `Range:69`, `Ticks:89`
  fn `available:53`, `list:60`, `range:72`, `ticks:92`
- `aerodrive/src/record/recorder.zig` — Gravação de um voo, ligada e desligada no meio do voo: cada gravação é uma pasta
  tipos `Info:16`, `Recorder:24`, `Entry:116`, `Catalog:123`
  fn `stampOf:100`, `list:133`, `deleteVideo:167`, `deleteRecording:175`, `label:182`
- `aerodrive/src/record/video.zig` — Vídeo do voo em .mp4: os quadros da tela (RGBA) vão por um cano para o `ffmpeg` (H.264).
  tipos `Video:6`
  fn `accepts:56`
- `aerodrive/src/record/video_player.zig` — Assistir um .mp4 gravado dentro do jogo: o `ffprobe` diz o tamanho, a taxa e a duração; o
  tipos `Info:12`, `Decoder:62`
  fn `parseProbe:15`, `outSize:31`, `probe:38`

**aerodrive/src/screens/**

- `aerodrive/src/screens/aircraft_menu.zig` — Aeronave: escolher o arquivo (exemplos e "meus aviões" da GUI) — o modelo 3D troca na hora —,
  tipos `AircraftMenu:24`
  fn `compass:160`
- `aerodrive/src/screens/camera_menu.zig` — Câmera: distância e altura da perseguição (em envergaduras), campo de visão e a câmera
  tipos `CameraMenu:20`
- `aerodrive/src/screens/control_menu.zig` — Controle, em duas abas:
  tipos `ControlMenu:31`
- `aerodrive/src/screens/flight.zig` — Voo: o drive_manager avança a física em tempo real; no manual, o controle (com as curvas do
  tipos `Flight:40`
- `aerodrive/src/screens/fly_menu.zig` — Voar: onde começa (chão ou mesa), onde pousa (chão ou plataforma), quem pilota no começo
  tipos `FlyMenu:26`
- `aerodrive/src/screens/main_menu.zig` — Menu inicial: logo da Albatroz, "AeroDrive", o avião escolhido e os itens; à direita a aeronave
  tipos `MainMenu:25`
- `aerodrive/src/screens/options_menu.zig` — Opções (do menu inicial): Controle, Câmera, Som, Voos gravados e a tela (janela ou tela cheia,
  tipos `OptionsMenu:12`
- `aerodrive/src/screens/pause_menu.zig` — Pausa (Start / Esc no voo): o voo congelado por trás e o menu — continuar, ajustar controle e
  tipos `PauseMenu:13`
- `aerodrive/src/screens/recording_view.zig` — Dados de um voo gravado: a lista de gráficos disponíveis à esquerda (as grandezas da aba Missão)
  tipos `RecordingView:15`
- `aerodrive/src/screens/recordings_menu.zig` — Voos gravados: as gravações (mais novas primeiro); escolhida uma: assistir o vídeo aqui dentro
  tipos `RecordingsMenu:15`
- `aerodrive/src/screens/sound_menu.zig` — Som: volume geral e o teste — o acelerador de teste (ou o gatilho / W e S) muda a altura e o
  tipos `SoundMenu:12`
- `aerodrive/src/screens/video_view.zig` — Assistir o vídeo de um voo gravado dentro do jogo. A / Espaço: pausa e continua · ← →: volta e
  tipos `VideoView:13`

**aerodrive/src/sim/**

- `aerodrive/src/sim/drive_manager.zig` — drive_manager: dono da simulação durante o voo. A cada quadro avança o núcleo até o tempo do
  tipos `Commands:25`, `Phase:27`, `Frame:30`, `DriveManager:51`
- `aerodrive/src/sim/methods.zig` — Os métodos fixos do AeroDrive, num lugar só.
- `aerodrive/src/sim/mission.zig` — Percurso -> segmentos, eventos e mesas/plataformas do núcleo (`aerosim/model/mission.py` e
  fn `autoRadius:13`, `segments:20`, `events:76`, `pads:92`
- `aerodrive/src/sim/modifiers.zig` — Os modificadores do arquivo do avião -> os campos do núcleo (`Params.ground`, `Params.mods`), em Zig.
  fn `fill:39`, `groundSettings:66`
- `aerodrive/src/sim/params.zig` — Avião (arquivo da GUI) -> parâmetros do núcleo (`types.Params`), em Zig.
  tipos `Info:32`, `Coeffs:120`, `DryMass:356`
  fn `area:49`, `span:59`, `mac:63`, `macLeadingEdge:78`, `firstSurface:98`, `references:104`, `props2d:126`, `coeffs:182`, `wingDownwash:204`, `dryMass:383`, `fill:453`, `setup:606`, `setupWith:612`, `calibrate:625`, `staticCharacteristics:650`
- `aerodrive/src/sim/session.zig` — Sessão de voo: o que o jogador escolhe nos menus antes de voar (cenário, modo, vento, sloshing,
  tipos `Scenario:7`, `Landing:19`, `Mode:31`, `Session:43`
  fn `gearExtent:98`

**aerodrive/src/sys/**

- `aerodrive/src/sys/browser.zig` — A ponte com a página no navegador (só no alvo web). As funções `extern` estão em JS, em
  tipos `Size:65`, `TriggerSide:88`, `ImportedFile:121`
  fn `fileSize:32`, `fileRead:38`, `fileWrite:43`, `folderList:48`, `pathRemove:60`, `viewportSize:69`, `openFilePicker:74`, `download:79`, `touchSeen:84`, `gamepadTrigger:91`, `videoStart:99`, `videoStop:104`, `leave:109`, `setFrameRate:114`, `takeImport:141`, `queueImport:148`
- `aerodrive/src/sys/browser_io.zig` — O `std.Io` do navegador. No Zig 0.16 o `std.Io.Threaded` não compila para emscripten (o
- `aerodrive/src/sys/keep_awake.zig` — Não deixa a tela escurecer nem apagar com o jogo aberto. Jogar só com o controle não conta como
  tipos `KeepAwake:20`
- `aerodrive/src/sys/platform.zig` — Em que plataforma o programa foi compilado (decidido em comptime pelo alvo).
- `aerodrive/src/sys/stats.zig` — Números do painel de desenvolvedor (F3): memória (RAM residente) e uso de CPU do processo.
  tipos `Sample:33`, `Sampler:38`
  fn `parseStatm:9`, `parseStatTicks:18`

**aerodrive/src/ui/**

- `aerodrive/src/ui/dev_overlay.zig` — Painel de desenvolvedor (F3, como no Minecraft): quadros por segundo, tempo do quadro, memória
  fn `draw:8`
- `aerodrive/src/ui/glyphs.zig` — Símbolos dos botões nas dicas da tela: com controle ligado, o botão do Xbox (símbolo branco
  tipos `Btn:13`, `Hint:19`
  fn `fromPad:15`, `padShown:28`, `button:33`, `key:91`, `hints:102`, `hintsWidth:116`
- `aerodrive/src/ui/minimap_view.zig` — Desenha o minimapa (plano XY, norte para cima): pista, percurso planejado, rastro, carga solta,
  tipos `Input:10`
  fn `draw:20`
- `aerodrive/src/ui/plot.zig` — Gráfico de linhas (raylib) para os voos gravados: eixos com marcas redondas, grade fraca,
  fn `draw:17`
- `aerodrive/src/ui/preview.zig` — Janela 3D dentro de um menu (a aeronave girando, o zoom numa superfície, a vista da câmera de
  tipos `Preview:12`
- `aerodrive/src/ui/showcase.zig` — A aeronave em exposição num retângulo do menu: gira devagar sozinha, arrastar gira, a roda
  tipos `Showcase:14`
- `aerodrive/src/ui/theme.zig` — Aparência das telas (mesma linguagem da GUI: fundo claro, azul nos títulos, pouco texto), a
  tipos `Fonts:38`
  fn `commandBar:71`
- `aerodrive/src/ui/touch_view.zig` — Desenha os controles por toque (`input/touch.zig`) sobre o voo: os dois manches com a bolinha
  fn `draw:14`
- `aerodrive/src/ui/widgets.zig` — Widgets dos menus (modo imediato): cada quadro a tela chama `begin`, os widgets na ordem em que
  tipos `Nav:32`, `Ui:41`, `Row:280`, `ScrollList:283`, `Column:340`
  fn `touchMode:19`, `header:358`, `footer:364`

**aerodrive/src/util/**

- `aerodrive/src/util/fuzz.zig` — Fuzzing dos módulos.
  tipos `Src:15`
  fn `check:56`, `checkScaled:65`

**aerodrive/src/world/**

- `aerodrive/src/world/field.zig` — O campo de voo como formas simples (sem modelos 3D): chão com grade, pista com marcas a cada
  tipos `colors:13`, `Box:27`, `Line:28`, `Field:33`
  fn `build:66`, `windArrows:119`
- `aerodrive/src/world/minimap.zig` — Minimapa (vista de cima, plano XY): escolhe a escala para caber o percurso, o rastro e o avião
  tipos `Map:7`, `Bounds:31`


## Zig · interface do aerosim (`aerosim/gui`)

**aerosim/gui/**

- `aerosim/gui/assembly.zig` — O avião da Montagem: lê o `.json` pelo modelo do AeroDrive (`aerodrive/src/model`, o mesmo que o simulador
  tipos `Triangle:17`, `Mesh:26`, `Assembly:191`, `Balance:236`
  fn `buildMesh:150`, `balance:246`, `loadAircraft:258`, `readAircraftText:269`, `load:286`, `fromBytes:294`, `fillAirfoilFiles:312`, `parseDat:347`, `findExample:379`
- `aerosim/gui/main.zig` — A interface do aerosim em Zig (raylib e raygui), com as contas no núcleo.
- `aerosim/gui/page.zig` — Uma subaba da janela, desenhada a partir do que o Python descreve (`python_bridge.zig`): a tela não conhece
  tipos `Kind:39`, `shared:44`, `Page:406`
- `aerosim/gui/python_bridge.zig` — A ponte com os métodos de fora do núcleo (lltdrek, AeroSandbox, AVL), que são bibliotecas em Python: a tela abre
  tipos `Waiter:30`, `Bridge:46`
- `aerosim/gui/screen.zig` — A tela do aerosim: o cabeçalho, as abas das áreas e as subabas de cada uma, na mesma arrumação da antiga GUI PyQt.
  tipos `Screen:35`
- `aerosim/gui/tests.zig` — Os testes sem janela da interface do aerosim: escalas dos gráficos, exportar e a leitura do avião da Montagem.

**aerosim/gui/tabs/**

- `aerosim/gui/tabs/config_tab.zig` — O painel da Montagem, o par de `info_html` (`config_tab.py`): tudo o que dá para saber da configuração sem
  tipos `Row:20`, `Section:22`, `Panel:25`, `Part:321`, `Component:324`, `FieldKind:433`, `Spec:436`, `EditableList:716`, `Layout:719`, `NewPart:977`
  fn `panel:49`, `components:345`, `specs:535`, `placeMounted:698`, `layout:736`, `addItem:828`, `removeItem:843`, `apply:882`, `add:1028`, `remove:1087`, `importPart:1140`, `componentOf:1158`, `moveBy:1169`, `setWind:1194`, `rename:1201`, `serialize:1207`

**aerosim/gui/ui/**

- `aerosim/gui/ui/app.zig` — O que os dois programas têm igual em volta da tela: a linha de comando, a janela e o laço de desenho, com o
  tipos `Args:16`, `Click:30`
  fn `parseArgs:37`, `run:81`, `runBrowser:185`, `openFromPage:214`
- `aerosim/gui/ui/browser_io.zig` — O `std.Io` das telas no navegador. No Zig 0.16 o `std.Io.Threaded` não compila para emscripten (o mesmo motivo
- `aerosim/gui/ui/checks.zig` — O diagnóstico de uma etapa, como o `ChecksPanel` da GUI em Python: uma linha por verificação (estado, o que se
  tipos `Check:10`, `ChecksPanel:44`
  fn `statusText:25`
- `aerosim/gui/ui/dialogs.zig` — As janelas por cima da tela: o seletor de arquivo (navega pelas pastas e mostra só as extensões pedidas; para
  tipos `FilePicker:18`, `TextPrompt:259`
  fn `home:301`, `button:322`
- `aerosim/gui/ui/export.zig` — Gravar o que a tela mostra em arquivo: os dados de um gráfico em CSV, a imagem dele em PNG (pelo raylib) e a
  tipos `Column:8`
  fn `writeCsv:15`, `writeText:33`, `saveCsv:47`, `writePdf:56`, `savePdf:107`, `fileName:115`
- `aerosim/gui/ui/form.zig` — O formulário lateral: campos agrupados (cada grupo com o título em azul, abre e fecha no clique), número, marcador,
  tipos `Kind:14`, `Field:25`, `Group:53`, `Form:64`
- `aerosim/gui/ui/jobs.zig` — As contas longas fora do laço da tela: uma `Job` roda uma função numa thread própria, e a tela continua
  tipos `Job:14`
  fn `Mailbox:73`
- `aerosim/gui/ui/menus.zig` — As peças de escolha que as abas repetem: a lista de itens com um selecionado (a lista de candidatos de Perfis,
  tipos `ItemList:12`, `CheckItem:56`, `CheckMenu:65`
  fn `buttonGrid:41`, `checkedText:122`
- `aerosim/gui/ui/native_dialog.zig` — A janela de abrir e de salvar arquivo do próprio sistema (a do GNOME, do KDE, do Windows ou do macOS), no lugar
  tipos `State:11`, `Dialog:13`
- `aerosim/gui/ui/numbers.zig` — Números na tela sem janela (testáveis): o texto curto de um campo e as marcas "redondas" dos eixos.
  tipos `Range:45`
  fn `fieldText:7`, `numberText:12`, `niceStep:28`, `decimalsFor:38`, `significant:95`
- `aerosim/gui/ui/plot.zig` — Gráfico de linhas dentro de um cartão: eixos com marcas redondas, grade fraca, as curvas na paleta do tema
  tipos `Series:24`, `Marker:57`, `Cloud:79`, `Axes:87`, `Frame:97`, `Cell:214`, `ExportKind:291`
  fn `lines:118`, `table:222`, `tableHeight:257`, `pickGroup:338`, `clearPick:344`, `overlayActive:485`, `overlay:490`, `drawMarker:826`, `cloud:880`, `ramp:899`, `colorBar:915`, `drawFrame:935`
- `aerosim/gui/ui/scroll.zig` — A área rolável: tudo o que não cabe na altura (a barra lateral, a coluna dos gráficos) rola pela roda do mouse ou
  tipos `ScrollArea:13`
- `aerosim/gui/ui/stage.zig` — As peças que toda etapa do dimensionamento repete, como o `StagePage` da GUI em Python: a barra de requisitos
  tipos `KeptAction:44`, `KeptBox:47`, `TabbedDialog:75`, `ListPicker:113`
  fn `reqBarHeight:18`, `reqBar:25`, `title:37`
- `aerosim/gui/ui/system.zig` — O que muda entre o programa do PC e o do navegador, num lugar só: a `Io` dos arquivos (a do sistema ou a
  fn `io:17`, `offerDownload:23`
- `aerosim/gui/ui/table.zig` — A tabela que se edita no lugar, como o `QTableWidget` da GUI em Python: uma linha por item, colunas de número,
  tipos `Kind:12`, `Column:17`, `Cell:25`, `Edit:38`, `EditTable:60`
  fn `height:55`
- `aerosim/gui/ui/tex.zig` — Um pedaço de TeX nos textos dos gráficos: o que fica entre `$...$` vira matemática, com índice (`C_L`,
  fn `draw:54`, `drawRotated:65`, `width:75`, `plain:84`
- `aerosim/gui/ui/theme.zig` — O visual da interface, o mesmo do AeroDrive: fundo claro, cantos arredondados, azul nos títulos e pouco texto.
  tipos `Palette:17`, `Fonts:186`, `Logo:236`
  fn `hex:7`, `withAlpha:12`, `plotColor:63`, `spacing:219`, `text:224`, `textWidth:230`
- `aerosim/gui/ui/toast.zig` — Os avisos por cima da janela: uma caixa laranja no canto de cima à direita, que some sozinha depois de uns
  fn `show:26`, `count:44`, `takeClick:49`, `draw:60`
- `aerosim/gui/ui/ui.zig` — As peças comuns das telas do aerosim e do aeroopt em Zig: cores e fontes, formas, widgets, formulário, gráfico
- `aerosim/gui/ui/undo.zig` — O histórico do Ctrl+Z: cada mudança guarda antes uma cópia do estado em texto (o `.json` do avião, os valores
  tipos `History:13`
  fn `pressed:50`
- `aerosim/gui/ui/view3d.zig` — Vista 3D dentro de um cartão, com as mesmas ideias da vista do aerosim em Python (`aerosim/gui/widgets/view3d.py`
  tipos `Kind:17`, `View:100`
  fn `kindColor:20`, `colorByName:35`, `fieldColor:57`, `fraction:75`, `liftColor:80`, `toWorld:85`, `toBody:238`, `shaded:262`, `triangle:270`, `gradientTriangle:280`, `litTriangle:292`, `quad:298`, `segment:315`, `arrow:320`, `floor:332`, `bodyAxes:344`
- `aerosim/gui/ui/widgets.zig` — Os pedaços comuns das telas, no desenho do AeroDrive: o contexto de desenho (fontes, logo, mouse), o cabeçalho
  tipos `Ui:11`, `Splitter:206`, `HeightGrip:239`, `Status:475`
  fn `paragraph:143`, `paragraphHeight:148`, `caretToEnd:194`, `replaceOnType:286`, `helpMark:311`, `checkBox:320`, `disclosure:335`, `rounded:379`, `roundedLines:384`, `header:389`, `tabBar:410`, `primaryButton:434`, `progressBar:444`, `card:451`, `labeledCard:459`, `statusColor:465`, `tableRow:478`, `format:485`


## Zig · interface do aeroopt (`aeroopt`)

**aeroopt/**

- `aeroopt/build.zig` — Interface do aeroopt em Zig (raylib e raygui). As peças comuns das telas vêm da interface do aerosim
  fn `build:12`
- `aeroopt/evaluate.zig` — Um candidato do aeroopt avaliado em Zig (o `SurfaceSizing.point` do Python, sem a geometria e a estabilidade
  tipos `Assignment:15`, `Point:18`
  fn `assign:31`, `point:56`
- `aeroopt/inputs.zig` — O catálogo das entradas do aeroopt: tudo o que se escolhe nas etapas do projeto (a chave do `.opt.json`, o
  tipos `Group:8`, `Source:37`, `Input:40`
  fn `find:150`, `label:156`, `groupOf:161`
- `aeroopt/main.zig` — A interface do aeroopt em Zig (raylib e raygui), com as peças da interface do aerosim.
- `aeroopt/opt_example.zig` — Dados de exemplo da tela do aeroopt enquanto ela não roda a busca: uma rodada inventada, sempre a mesma (semente
  tipos `Run:16`
  fn `syntheticScore:31`, `generate:38`
- `aeroopt/problem.zig` — O problema do aeroopt como arquivo (`.opt.json`, formato "aeroopt/1"): o que pode variar no avião e entre que
  tipos `VariableKind:15`, `Comparison:40`, `Variable:65`, `Constraint:76`, `Problem:85`
  fn `parse:127`, `load:153`, `write:159`
- `aeroopt/problem_panel.zig` — A esquerda do aeroopt: o projeto da sprint, abrir e gravar o problema (`.opt.json`), um botão por parte do
  tipos `Request:44`, `Panel:49`
- `aeroopt/project_link.zig` — O problema e o projeto da sprint: o valor que o avião tem em cada entrada (a coluna "valor do avião"), o que
  fn `field:26`, `valueText:34`, `valueNumber:46`, `available:57`, `fromProject:117`, `foldBounds:157`
- `aeroopt/screen.zig` — A tela do aeroopt: à esquerda o problema (`problem_panel.zig`: o projeto, abrir e gravar o `.opt.json`, um botão
  tipos `Screen:18`
- `aeroopt/summary.zig` — O que a esquerda do aeroopt mostra do problema sem desenhar nada: os nomes dos métodos de cada etapa, as
  tipos `Part:13`, `Method:44`
  fn `isolate:70`, `categoryLabel:79`, `hasCategory:84`, `choiceList:92`, `methodIndex:100`, `methodLabel:105`, `section_of:110`, `text:115`, `number:120`, `boolean:129`, `writeSummary:152`
- `aeroopt/tests.zig` — Os testes sem janela da interface do aeroopt: a rodada de exemplo, o problema (`.opt.json`), o catálogo das


## Zig · tela inicial do pacote (`launcher`)

**launcher/**

- `launcher/build.zig` — A tela inicial do programa instalado (o menu do site, no PC), em Zig com raylib. Usa as peças comuns das telas
  fn `build:10`
- `launcher/main.zig` — A tela inicial do AircraftSimulation instalado (o mesmo menu do site): escolhe e abre o aerosim, o aeroopt ou
  fn `main:14`
- `launcher/places.zig` — Onde estão os programas e os dados, vistos da tela inicial. No pacote instalado (o .exe do Windows, o
  tipos `Program:9`
  fn `dataRoot:15`, `candidates:28`, `find:37`, `docsCandidates:43`, `findDocs:50`, `opener:72`
- `launcher/screen.zig` — A tela inicial do programa instalado: a mesma do site (`web/index.html`), no estilo de uma BIOS (fundo azul,
  tipos `Screen:39`
- `launcher/tests.zig` — Os testes sem janela da tela inicial: onde estão os programas e os dados.


## Ferramentas (`tools/`)

- `tools/check.zig` — Os checks de regressão: confere que nada quebrou antes de mesclar na `main`.
- `tools/codemap.zig` — Mapa do código: gera docs/MAP.md a partir do próprio código (nunca editar o MAP.md à mão).
- `tools/grafo.zig` — Grafo do código: lê o Zig do repositório e devolve quem é quem e quem chama quem, sem lista feita à mão.
- `tools/livro.zig` — Site da documentação: todos os .md do repositório num livro só, o mapa do código e o tracking, lado a lado.
- `tools/pacote.zig` — Monta o AircraftSimulation para distribuir: o programa instalável (a tela inicial, o aerosim, o aeroopt e o
- `tools/retrato.zig` — O retrato numérico dos aviões de exemplo, para a regressão bit a bit (`zig build check`): cada avião de
- `tools/tracking.zig` — Tracking em HTML: as tabelas do Quadro do docs/TRACKING.md viram uma página só (sem nada para baixar).

## README por pasta

- `README.md`
- `aerodrive/README.md`
- `aerodrive/src/README.md`
- `aeroopt/README.md`
- `aerosim/aero/README.md`
- `aerosim/data/README.md`
- `aerosim/design/README.md`
- `aerosim/gui/README.md`
- `aerosim/interfaces/README.md`
- `aerosim/manager/README.md`
- `aerosim/model/README.md`
- `core/README.md`
- `core/src/collision/README.md`
- `core/src/control/README.md`
- `core/src/geometry/README.md`
- `core/src/loads/README.md`
- `core/src/math/README.md`
- `core/src/modifiers/README.md`
- `core/src/optim/README.md`
- `core/src/physics/README.md`
- `core/src/sim/README.md`
- `core/src/sizing/README.md`
- `core/src/structures/README.md`
- `data/README.md`
- `dist/AircraftSimulation-linux/app/data/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/aerodynamics/aero_2D/airfoil_optimizer/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/aerodynamics/aero_3D/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/aerodynamics/aero_3D/test_aero_3D/test_aero_buildup/test_low_ar_wings_validation/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/dynamics/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/dynamics/utilities/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/dynamics/visualization/default_assets/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/library/datasets/turbine_engines/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/numpy/test_numpy/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/tools/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/tools/pretty_plots/README.md`
- `dist/AircraftSimulation-linux/app/python/lib/python3.12/site-packages/aerosandbox/tools/pretty_plots/labellines/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/data/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/aerodynamics/aero_2D/airfoil_optimizer/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/aerodynamics/aero_3D/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/aerodynamics/aero_3D/test_aero_3D/test_aero_buildup/test_low_ar_wings_validation/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/dynamics/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/dynamics/utilities/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/dynamics/visualization/default_assets/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/library/datasets/turbine_engines/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/numpy/test_numpy/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/tools/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/tools/pretty_plots/README.md`
- `dist/AircraftSimulation.AppDir/usr/lib/aircraftsimulation/app/python/lib/python3.12/site-packages/aerosandbox/tools/pretty_plots/labellines/README.md`
- `launcher/README.md`
- `tools/README.md`

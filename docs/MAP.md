# Mapa do código

Gerado por `python tools/codemap.py` — **não editar à mão** (`--check` acusa quando está desatualizado).
Formato: `arquivo` — primeira linha da documentação; depois os nomes públicos com a linha (`nome:linha`).
Regras e decisões do projeto: `.claude/CLAUDE.md`. O que falta e a ordem: `docs/TRACKING.md`.

## Python · `aerosim`

- `aerosim/__init__.py` — aerosim — simulador 6GDL de aeronaves em camadas:

## Python · `aerosim/aero`

- `aerosim/aero/__init__.py` — Aerodinâmica a partir da geometria: comparação de métodos (modelo interno, lltdrek,
  `all_solvers:20`, `all_load_methods:25`, `load_method:32`, `parabolic_polar:41`, `solver_by_name:50`, `polar_metrics:54`
- `aerosim/aero/asb_solver.py` — AeroSandbox (Sharpe, MIT): três métodos sobre o mesmo modelo universal.
  `class AsbTranslator:32`, `class AsbVLMSolver:110`, `class AsbBuildupSolver:120`, `class AsbLiftingLineSolver:129`, `class AsbVLMLoads:175`
- `aerosim/aero/avl_solver.py` — AVL (Drela e Youngren, MIT; GPL): malha de vórtices em ferradura com superfícies de comando.
  `avl_exe:42`, `has_optvl:49`, `class AvlTranslator:66`, `class AvlSolver:134`
- `aerosim/aero/base.py` — Polar e derivadas comuns a todos os solvers: cada um só implementa `evaluate` (pontos de voo
  `class AeroSolverBase:23`
- `aerosim/aero/collision.py` — Quem o tubo de cada hélice atinge: superfícies (fração da área de cada uma) e objetos (fuselagem, tubos de cauda,
  `class Hit:23`, `tube_hits:30`
- `aerosim/aero/flight_table.py` — Tabela aerodinâmica de voo a partir de qualquer método (`IAeroSolver`): o avião voa com ela no núcleo
  `table:29`
- `aerosim/aero/geometry.py` — Utilidades dos tradutores: eixos dos solvers externos, viscosidade/Reynolds, tabela de volumes
  `nu_air:34`, `reynolds:38`, `to_xz_up:42`
- `aerosim/aero/llt_solver.py` — A linha sustentadora do núcleo (`core/src/loads/llt.zig`) como método de polar e derivadas: a conta da simulação
  `class CoreLLTSolver:21`
- `aerosim/aero/lltdrek_solver.py` — lltdrek (https://github.com/kuodrek/lltdrek, MIT): linha sustentadora não linear
  `class LltdrekTranslator:89`, `class LltdrekSolver:138`
- `aerosim/aero/load_geometry.py` — Geometria das setas da vista de carga (sem Qt, sem conta aerodinâmica): setas com ponta (linhas + cones).
  `arrow_meshes:10`
- `aerosim/aero/load_plots.py` — Gráficos de carga ao longo da envergadura a partir da entrada padrão (`aerosim.interfaces.loads.LoadResult`):
  `span_figure:15`
- `aerosim/aero/sections.py` — Polar 2D dos perfis (camada abaixo dos métodos 3D): uma fonte por `ISectionPolar` e um cache só.
  `model_polar:58`, `neuralfoil_polar:69`, `read_polar_file:77`, `class ModelSection:115`, `class NeuralFoilSection:122`, `class FileSection:138`, `cache_dir:165`, `airfoil_key:169`, `clear_cache:221`, `section_polar:232`, `write_lltdrek_polar:254`
- `aerosim/aero/service.py` — Polar da aeronave para quem precisa dela, com cache (a mesma pergunta não roda de novo).
  `signature:34`, `polar_key:43`, `clear_cache:80`, `solve:87`, `remember:112`, `aircraft_polar:117`
- `aerosim/aero/span_loads.py` — Carga aerodinâmica ao longo de cada superfície num ponto de operação: velocidade, α, β, comandos e a rotação de
  `class LoadCase:37`, `class SurfaceLoad:54`, `class PropState:86`, `class SpanLoads:102`, `refine_surface:149`, `refine_all:173`, `prepare:235`, `class StripLoadMethod:263`, `class CoreLoadMethod:290`, `compute:354`, `to_result:367`
- `aerosim/aero/tipdevices.py` — Dispositivos de ponta de asa pelo arrasto induzido mínimo no plano de Trefftz.
  `trace:40`, `optimal_loading:68`, `span_efficiency:104`, `raymer_endplate:111`, `raymer_oswald:116`, `device_study:121`, `model_trace:167`, `model_efficiency:196`, `devices_wetted_area:207`
- `aerosim/aero/xflr5_import.py` — Polar 3D exportada pelo XFLR5 (análise de avião: LLT, VLM1/VLM2 ou painéis), lida como mais um método da
  `read_plane_polar:22`, `class Xflr5PolarFile:60`
- `aerosim/aero/zig_solver.py` — O método do núcleo (faixas com C_Lα de Helmbold, downwash ε0 + dε/dα α na cauda, estol de
  `class ZigPanelSolver:12`

## Python · `aerosim/backend`

- `aerosim/backend/__init__.py` — Implementações da camada Sim (ISimBackend).
  `default_backend:4`
- `aerosim/backend/zig/__init__.py` — Núcleo de simulação em Zig (core/) exposto como ISimBackend.
- `aerosim/backend/zig/abi.py` — Monta as estruturas ctypes a partir do esquema que o núcleo Zig exporta.
  `class AbiMismatch:22`, `fnv1a64:26`, `check:35`, `class FieldInfo:47`, `class StructInfo:55`, `class Schema:63`, `parse:74`, `write:130`, `read:154`
- `aerosim/backend/zig/backend.py` — Implementação de ISimBackend com o núcleo em Zig (libaerosim, via ctypes).
  `lib_path:24`, `build:47`, `class CoreError:74`, `class ZigSession:212`, `class ZigBackend:467`
- `aerosim/backend/zig/geometry.py` — Tradutor da checagem de geometria: o modelo universal vira as peças simples do núcleo (`core/src/geometry`),
  `scene:114`, `report:165`, `class ZigGeometry:191`
- `aerosim/backend/zig/translator.py` — Tradutor modelo universal -> núcleo Zig (SimSpec: dicionário com os campos das structs extern).
  `prop_native:26`, `surface_panels:42`, `panel_owners:75`, `class ZigTranslator:84`, `aero_native:150`, `native_spec:185`

## Python · `aerosim/data`

- `aerosim/data/__init__.py` — Aircraft Data: origens de dados (.json, .cfg, .xlsx) para aeronaves e catálogos, e a
- `aerosim/data/cellmap.py` — Planilhas "por endereço de célula" (ex.: Dados_Desempenho.xlsx), incluindo os conjuntos de
  `class CellMapAircraftSource:124`
- `aerosim/data/flat.py` — Aeronave <-> seções planas (usado pelos formatos .cfg e .xlsx).
  `flatten:38`, `unflatten:73`, `encode:86`, `decode:92`
- `aerosim/data/projects.py` — IProjectStore em JSON: uma pasta, um arquivo por aeronave (<nome>.json).
  `default_root:24`, `slug:28`, `summary:34`, `load_file:48`, `list_folder:58`, `class JsonProjectStore:83`
- `aerosim/data/sources.py` — Implementações de IAircraftSource e ICatalogSource: .json, .cfg (INI) e .xlsx (Excel).
  `class JsonAircraftSource:42`, `class CfgAircraftSource:57`, `class ExcelAircraftSource:87`, `class JsonCatalogSource:151`, `class CfgCatalogSource:163`, `class ExcelCatalogSource:196`, `aircraft_source:270`, `catalog_source:274`, `load_aircraft:278`, `save_aircraft:282`, `load_catalog:286`, `save_catalog:290`

## Python · `aerosim/design`

- `aerosim/design/__init__.py` — Projeto do zero, em etapas (a sprint): cada etapa cria uma peça e a seguinte parte dela.
- `aerosim/design/airfoils.py` — Etapa Perfil: a polar 2D de cada perfil candidato e os números que a asa vai usar.
  `class AirfoilEntry:33`, `kind:44`, `sources:56`, `entry:69`, `from_dat:76`, `library:86`, `from_naca:110`, `polar:116`, `metrics:127`, `fitted:161`, `symmetric:173`, `drag_at:183`
- `aerosim/design/balance.py` — CG do avião com a carga que a Montagem definiu, e acertar o CG de projeto.
  `full_cg:23`, `cg_after_drop:38`, `mac:42`, `rebalance:60`
- `aerosim/design/checklist.py` — Lista de verificação do avião antes de salvar: o que falta definir e o que o projeto pede.
  `values:43`, `define_checks:66`, `project_checks:134`, `aircraft_checklist:165`, `pending:170`
- `aerosim/design/dims.py` — Dimensões do avião medidas a partir do CG de projeto (como na planilha antiga: x_TDP, x_TDN, altura do CG,
  `design_cg:20`, `dimensions:37`
- `aerosim/design/fields.py` — Campo de dataclass com o que a GUI precisa para mostrá-lo (rótulo, unidade, dica, opções, faixa).
  `F:12`
- `aerosim/design/flight.py` — O avião só sai da sprint se voar: a decolagem do núcleo 6GDL (o mesmo otimizador da aba Missão) acha o
  `tune_takeoff:19`
- `aerosim/design/mdo.py` — Dimensionamento inicial como mini-MDO: monta a configuração do núcleo (`core/src/sizing`) a partir do
  `class MdoParams:40`, `class MdoRun:60`, `airfoil_catalog:81`, `available:104`, `airfoil_data:134`, `build:144`, `tip_varies:225`, `at_bounds:235`, `opts_of:249`, `decode:254`, `history:269`, `run:280`, `evaluate:293`, `apply:305`, `planform:327`, `sketch:338`, `check_6dof:389`, `full_envelope:417`, `constraint_diagram:438`
- `aerosim/design/power.py` — Etapa Motores e montagem: onde ficam os motores (e por consequência a bateria, a carga e o trem) e o
  `class PowerParams:35`, `class AircraftCandidate:78`, `motor_counts:88`, `assemble:123`, `ground_pitch:309`, `trimmed_clmax:317`, `thrust_trim:338`, `thrust_of:458`, `motor_prop_spec:486`, `performance:505`, `trim_drag:558`, `design_point:580`
- `aerosim/design/project.py` — O projeto da sprint: requisitos, regras e o que cada etapa guardou (perfis, asas, conjuntos, aviões).
  `rg_sae:31`, `class DesignProject:41`, `is_project_file:182`, `next_name:194`
- `aerosim/design/registry.py` — Registro de grandezas do projeto: o que dá para medir, restringir ou variar.
  `class Quantity:25`, `fmt:71`, `class Constraint:78`, `default_constraints:106`, `active:118`, `checks:122`, `class Input:138`, `class Variable:167`, `default_variables:179`, `get_input:187`, `set_input:192`, `wing_values:200`, `aircraft_values:206`, `sae_constraints:232`, `bounds_from_constraints:243`, `check_bounds:264`
- `aerosim/design/results.py` — Cada etapa como um `SimResult` (séries, resumo, diagnóstico) e os gráficos dela (`PlotSpec`): a GUI
  `constraint_checks:30`, `airfoil_stage:52`, `wing_stage:103`, `set_stage:177`, `aircraft_stage:289`
- `aerosim/design/spec.py` — Condições e restrições (o que o avião tem de cumprir) e regras de projeto (como as peças se montam).
  `class Requirements:28`, `class DesignRules:98`, `cruise_CL:123`, `stall_speed:127`
- `aerosim/design/store.py` — O projeto da sprint numa pasta escolhida pelo usuário, com um arquivo por asa.
  `file_name:49`, `split:98`, `run_file:135`, `wing_files:156`, `save:169`, `join:199`, `is_folder:263`, `load:269`, `is_sprint_path:287`, `folder_for:300`, `open_path:313`
- `aerosim/design/study.py` — Estudo e ponto de projeto: as áreas se retroalimentam (não em ordem) e o estudo mostra onde estabilidade e
  `class StudyParams:45`, `class StudyRun:57`, `to_run:74`, `from_run:86`, `ensure:91`, `table:109`, `parse_places:114`, `with_value:129`, `feasibility:138`, `point_row:169`, `run:181`, `best_rows:214`, `mtow_of:226`, `check_6dof:230`, `check_many:258`, `result:293`
- `aerosim/design/tail.py` — Etapa Empenagem e comandos: as superfícies que acompanham a asa escolhida, o tubo de cauda e os comandos.
  `class TailParams:51`, `class SetCandidate:121`, `tail_airfoil:146`, `tail_entry:151`, `build_set:175`, `wing2_candidate:314`, `second_wing:329`, `analyze:385`, `rotation:552`
- `aerosim/design/wing.py` — Etapa Asa: do perfil escolhido à asa — forma em planta, linha sustentadora e o que ela entrega.
  `class WingPartition:39`, `class WingStation:55`, `class WingParams:65`, `class WingCandidate:92`, `stations:110`, `chords:130`, `totals:145`, `sync:151`, `partitions_from_trapezoid:168`, `build_wing:187`, `planform:209`, `tip_weight:223`, `station_weights:231`, `section_props:240`, `lifting_line:253`, `analyze:289`

## Python · `aerosim/gui`

- `aerosim/gui/__init__.py` — GUI em PyQt6 + pyqtgraph: aba de configuração 3D e uma aba por simulação.
- `aerosim/gui/__main__.py`
- `aerosim/gui/app.py` — Ponto de entrada da GUI:  python -m aerosim.gui [aeronave.cfg|.json|.xlsx | projeto.json]
  `main:26`
- `aerosim/gui/main_window.py` — Janela principal: uma aba por área (na ordem do projeto: dimensionamento, aerodinâmica, estabilidade,
  `class MainWindow:28`, `class ProjectsDialog:365`
- `aerosim/gui/state.py` — Estado compartilhado da GUI: a aeronave em edição, o catálogo e o Simulation Manager.
  `class AppState:31`
- `aerosim/gui/design/__init__.py` — Etapas da sprint na GUI (projeto do zero): por área, as páginas que entram antes da análise do avião
- `aerosim/gui/design/mdo_page.py` — Página do dimensionamento inicial (mini-MDO): o otimizador do núcleo em tempo real.
  `class LegendPlot:29`, `class MdoPage:77`
- `aerosim/gui/design/pages.py` — As etapas da sprint na GUI: cada uma edita um rascunho, mostra na hora o que vai ser feito (3D da peça,
  `class ConstraintsTable:52`, `class VariablesTable:138`, `class ListPicker:246`, `class RequirementsDialog:310`, `class ReqBar:339`, `class StagePage:363`, `class AirfoilPage:582`, `class WingPage:743`, `class TailPage:918`, `class PowerPage:972`, `send_to_assembly:1111`, `class StudyPage:1171`
- `aerosim/gui/tabs/__init__.py`
- `aerosim/gui/tabs/config_tab.py` — Aba de configuração em três colunas:
  `mount_choices:56`, `class ConfigTab:68`, `info_html:1150`
- `aerosim/gui/tabs/simulation_tab.py` — Aba genérica de uma simulação: formulário gerado pelos ParamSpec, botões rodar/parar,
  `class SimulationTab:46`, `class TableInput:424`, `export_result:566`
- `aerosim/gui/widgets/__init__.py`
- `aerosim/gui/widgets/aircraft_panel.py` — O avião da sprint nas abas: barra para trocar entre os aviões abertos (◀ nome ▶, + variante,
  `class FleetBar:14`, `class AircraftPanel:73`, `summary_line:119`
- `aerosim/gui/widgets/checks_panel.py` — Diagnóstico (estado, verificação, valor, limite — clique numa linha para o porquê e o que mudar) e a
  `class ChecksPanel:27`
- `aerosim/gui/widgets/dims_table.py` — Tabela de dimensões a partir do CG de projeto (`aerosim.design.dims`): grupo, item, Δx, Δy, Δz e o valor "de
  `class DimsTable:14`
- `aerosim/gui/widgets/load_view.py` — Vista 3D de uma análise de carga aerodinâmica sobre o modelo do avião da GUI (o mesmo desenho da Montagem): as
  `colormap:61`, `normalize:65`, `face_colors:89`, `class Legend:95`, `class LoadView:134`
- `aerosim/gui/widgets/param_slider.py` — Slider + campo numérico sincronizados, e um formulário automático para dataclasses.
  `class ParamSlider:41`, `class NumberField:109`, `class DataclassForm:280`
- `aerosim/gui/widgets/plots.py` — Gráficos da aba (pyqtgraph) montados a partir das PlotSpec da simulação.
  `tex:39`, `is_angle:57`, `class LivePlots:341`, `format_value:443`
- `aerosim/gui/widgets/save_check.py` — Antes de salvar um avião: a lista de verificação (`aerosim.design.checklist`) como caixas de seleção só de
  `class SaveCheckDialog:19`, `confirm_save:80`
- `aerosim/gui/widgets/view3d.py` — Visualização 3D da aeronave (pyqtgraph.opengl) com seleção e arraste de componentes.
  `to_gl:58`, `class AircraftView:62`

## Python · `aerosim/interfaces`

- `aerosim/interfaces/__init__.py` — Interfaces entre as camadas:  GUI -> Simulation Manager -> Sim  (+ Aircraft Data).
- `aerosim/interfaces/aero.py` — Interface dos solvers aerodinâmicos (comparativo da aba Aerodinâmica).
  `class FlightPoint:26`, `class AeroCase:39`, `class AeroPolar:53`, `class IAeroSolver:71`, `class ISectionPolar:100`
- `aerosim/interfaces/aircraft_source.py` — Interface "Aircraft Data": de onde vem (e para onde vai) a aeronave.
  `class IAircraftSource:17`, `class ICatalogSource:29`
- `aerosim/interfaces/backend.py` — Interface da camada Sim (núcleo numérico).
  `class RunStatus:26`, `class TrimKind:40`, `class LogChunk:48`, `class ISimSession:73`, `class ISimBackend:160`
- `aerosim/interfaces/executor.py` — Contrato de quem roda uma função em muitos itens independentes: em série, em linhas de execução (threads) ou em
  `class Outcome:23`, `class IExecutor:33`
- `aerosim/interfaces/geometry.py` — Contrato da checagem de geometria do avião montado: se as peças cabem juntas, antes da aerodinâmica.
  `class GeometryParams:16`, `class GeometryReport:28`, `class IGeometryCheck:46`
- `aerosim/interfaces/loads.py` — Entrada padrão das análises de carga aerodinâmica: o que os gráficos de carga e a vista 3D aceitam.
  `label:48`, `class SpanDistribution:54`, `class VectorLayer:68`, `class SurfaceField:77`, `class LoadResult:95`, `class LoadPoint:119`, `class ILoadMethod:137`
- `aerosim/interfaces/optim.py` — Contratos do aeroopt (o otimizador): o problema, a pontuação, o avaliador e o solver.
  `class OptVariable:32`, `class OptConstraint:43`, `class OptProblem:52`, `class OptResult:92`, `class IScoring:98`, `class IEvaluator:112`, `class ISolver:124`, `class StageItem:134`, `class IStage:144`, `class IFailureDiagnosis:162`
- `aerosim/interfaces/project_store.py` — Interface da biblioteca de aeronaves do usuário ("meus aviões").
  `class ProjectInfo:18`, `class IProjectStore:25`
- `aerosim/interfaces/result_io.py` — SimResult ⇄ dicionário de JSON (para guardar no projeto o que já rodou e mostrar ao abrir sem rodar de novo).
  `result_to_dict:92`, `result_from_dict:101`
- `aerosim/interfaces/simulation.py` — Interface de uma simulação (plugin do Simulation Manager) e do próprio manager.
  `class ParamSpec:34`, `class PlotSpec:54`, `class Check:76`, `class SimResult:89`, `class CancelledError:99`, `class RunContext:104`, `class ISimulation:126`, `class ISimulationManager:170`
- `aerosim/interfaces/translator.py` — Tradutores: modelo universal (`aerosim.model.universal.AircraftModel`) <-> formato de cada solver.
  `class IModelTranslator:21`

## Python · `aerosim/manager`

- `aerosim/manager/__init__.py` — Simulation Manager: orienta as simulações (o que roda, até onde, de onde retoma, o que itera).
- `aerosim/manager/analysis.py` — Pós-processamento dos registros (independente do núcleo): etapas, curvas, decolagem.
  `takeoff_violations:16`, `violation_text:35`, `stages:39`, `stage_table:49`, `evaluate_turn:76`, `min_radius:111`, `columns:120`
- `aerosim/manager/calibration.py` — Características estáticas e calibração do piloto automático.
  `static_characteristics:22`, `calibrate:41`
- `aerosim/manager/checkpoints.py` — Checkpoints: o estado inteiro de uma corrida num ponto (bytes do núcleo + metadados).
  `class Checkpoint:16`, `class CheckpointStore:24`
- `aerosim/manager/flightplots.py` — Séries de gráfico de um voo simulado, no estilo dos gráficos do código original (legacy/py/graficos.py):
  `stage_names:32`, `stage_color:36`, `by_stage:50`, `stage_spans:71`, `events_points:86`, `event_stars:98`, `payload_path:112`, `terrain_profile:124`, `trajectory:133`, `time_series:155`, `cg_series:233`, `takeoff_window:254`, `ground_clearance:323`, `landing_window:354`, `lapes_window:391`, `aircraft_glyphs:448`, `battery_by_stage:479`, `takeoff_angles:522`, `takeoff_time:540`
- `aerosim/manager/manager.py` — Simulation Manager: escolhe qual simulação roda, com que parâmetros, e entrega o
  `class SimulationManager:19`
- `aerosim/manager/runner.py` — Corrida orientada: começa (no chão, em voo ou de um checkpoint), roda até uma parada
  `class Stop:21`, `class RunOutput:35`, `class Runner:42`
- `aerosim/manager/takeoff_opt.py` — Decolagem para a competição: os dois critérios da pista e um de voo.
  `class TakeoffResult:50`, `pitch_control:69`, `judge:76`, `evaluate:140`, `optimize:183`
- `aerosim/manager/simulations/__init__.py` — Simulações disponíveis (uma aba cada na GUI). Para adicionar outra: crie uma classe
- `aerosim/manager/simulations/aerodynamics.py` — Aba Aerodinâmica — polares e derivadas a partir da geometria, com o lltdrek (linha
  `resolve_cg:31`, `class AerodynamicsSimulation:40`
- `aerosim/manager/simulations/base.py` — Base comum das simulações: prepara a aeronave (calibração) e roda casos em paralelo.
  `floats:16`, `class SimulationBase:25`
- `aerosim/manager/simulations/climb.py` — Subida em regime: para cada V, nivela (checkpoint) e pede gradientes crescentes a
  `class ClimbSimulation:19`
- `aerosim/manager/simulations/envelope.py` — Envelope de voo por altitude (adaptado do Envelope_main original) + tabela de desempenho.
  `sheet_config:39`, `class EnvelopeSimulation:61`
- `aerosim/manager/simulations/loads.py` — Cargas: a carga aerodinâmica ao longo de cada superfície num ponto de operação (velocidade, fator de carga, α),
  `class LoadsSimulation:31`
- `aerosim/manager/simulations/mission.py` — Missão (simulação 6GDL) por etapa do voo (corrida no chão, cada perna do percurso, rolagem).
  `legs_to_rows:58`, `rows_to_legs:69`, `xcg_pct:89`, `total_mass:94`, `mtow_rows:101`, `mass_variant:120`, `class MissionSimulation:183`
- `aerosim/manager/simulations/performance.py` — Desempenho por cálculo (como na planilha de desempenho): nada é simulado e não há piloto.
  `core_polar:39`, `class PerformanceSimulation:51`
- `aerosim/manager/simulations/polar.py` — Polar estática: C_L, C_D, C_m em α e C_Y, C_l, C_n em β (sem integração no tempo).
  `aircraft_curves:14`, `class PolarSimulation:35`
- `aerosim/manager/simulations/sizing.py` — Aba Dimensionamento inicial — diagrama de restrições T/W × W/S (e P/m × W/S para hélice).
  `class SizingSimulation:34`
- `aerosim/manager/simulations/stability.py` — Aba Estabilidade — diz se a configuração serve, por quê, e o que mudar.
  `class StabilitySimulation:59`
- `aerosim/manager/simulations/takeoff.py` — Decolagem: uma corrida em tempo real e, opcionalmente, o mapa s_R × δe1 com as
  `class TakeoffSimulation:17`
- `aerosim/manager/simulations/thrust.py` — Tração × velocidade de cada unidade propulsora (equilíbrio de rotação do motor).
  `thrust_curves:12`, `class ThrustSimulation:25`
- `aerosim/manager/simulations/turn.py` — Curvas niveladas: raio mínimo por velocidade.
  `class TurnSimulation:21`

## Python · `aerosim/model`

- `aerosim/model/__init__.py` — Modelo de dados (independente do núcleo): aeronave, perfis, catálogo, missão, geometria.
- `aerosim/model/aircraft.py` — Modelo de dados da aeronave (a "Aircraft Data").
  `class WingSection:25`, `class ControlSurface:42`, `mix_role:64`, `panel_mix:70`, `class WingDevice:80`, `class LiftingSurface:101`, `new_group_id:182`, `rect_sections:204`, `class Fuselage:212`, `class TailBoom:228`, `class PropulsionUnit:264`, `class GearLeg:284`, `class LandingGear:294`, `class SloshTank:330`, `class Payload:358`, `class Ballast:375`, `class PointMass:385`, `class MassModel:394`, `class Airfield:410`, `class Environment:447`, `class Takeoff:474`, `class Autopilot:490`, `class PerformanceData:540`, `class SimSettings:553`, `class Aircraft:567`
- `aerosim/model/airfoil.py` — Perfis: leitura de .dat (Selig ou Lednicer), gerador NACA 4 dígitos e teoria de
  `class Airfoil:14`, `naca4:51`, `read_dat:73`, `write_dat:93`, `camber_line:100`, `thin_airfoil:114`, `flap_effectiveness:126`, `helmbold:133`
- `aerosim/model/atmosphere.py` — Atmosfera padrão (ISA, troposfera) para a altitude-densidade (AD).
  `isa_density:15`, `density_altitude:21`
- `aerosim/model/catalog.py` — Itens de catálogo: motores, hélices e baterias (vários por arquivo).
  `class Motor:8`, `class Propeller:21`, `class Battery:34`, `class ThrustPoly:54`, `class Catalog:94`, `generic_propeller:133`, `builtin_catalog:150`
- `aerosim/model/devices.py` — Geometria dos dispositivos de asa (winglet, winglet para baixo, placa de ponta, cerca).
  `class Leg:22`, `attach_point:44`, `legs:52`, `device_area:77`
- `aerosim/model/features.py` — O que a aeronave tem — as abas de análise usam isto para decidir o que mostrar.
  `class Features:14`, `features:97`
- `aerosim/model/geometry.py` — Malhas 3D para a GUI (a partir do modelo universal) e posição/arraste dos componentes na
  `surface_mesh:47`, `control_meshes:73`, `ellipsoid_body:94`, `cylinder:109`, `box:122`, `thrust_axis:131`, `aircraft_meshes:136`, `component_position:178`, `move_component:202`
- `aerosim/model/massprops.py` — Massa seca da aeronave: base (com inércia própria) + massas pontuais (Steiner).
  `point_items:12`, `dry_mass:63`
- `aerosim/model/mission.py` — Percurso como uma corrente de pernas (retas e curvas).
  `auto_radius:20`, `class Leg:26`, `class MissionEvent:41`, `class Mission:48`, `circuit:121`, `short_circuit:145`, `takeoff_runway:156`, `level_turn:161`
- `aerosim/model/modifiers.py` — Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro (efeito solo, esteira
  `class ParamInfo:28`, `class KindInfo:37`, `class Modifier:87`, `default_modifiers:105`, `active:110`, `ground_method:114`, `additive:120`, `problems:124`, `describe:137`, `is_default:148`, `not_exported:154`, `native:162`
- `aerosim/model/serialize.py` — dataclass <-> dicionário (genérico, guiado pelas anotações de tipo).
  `to_dict:10`, `from_dict:52`
- `aerosim/model/templates.py` — Aeronaves prontas para começar.
  `conventional:26`, `flying_wing:75`, `twin_boom:111`, `empty:149`, `is_empty:163`, `not_ready:168`
- `aerosim/model/universal.py` — Modelo universal da aeronave — construído UMA vez a partir da configuração (`Aircraft`) e
  `class Control:32`, `class Station:42`, `class SurfaceModel:51`, `class AircraftModel:130`, `strip_coeffs:247`, `wing_downwash:290`, `build_model:363`

## Python · `aerosim/parallel`

- `aerosim/parallel/__init__.py` — Paralelismo genérico: as formas de rodar uma função em muitos itens (`IExecutor`) e um conjunto delas que dura
- `aerosim/parallel/executors.py` — As três formas de rodar uma função em muitos itens (`aerosim.interfaces.executor.IExecutor`).
  `class Cancelled:29`, `cancelled:40`, `check_cancel:48`, `default_workers:70`, `class SerialExecutor:74`, `class ThreadExecutor:179`, `class ProcessExecutor:186`, `make_executor:229`, `class Executors:242`, `session:273`, `warm_session:284`, `close_session:292`

## Python · `aerosim/sizing`

- `aerosim/sizing/__init__.py` — Dimensionamento inicial (diagrama de restrições): sem núcleo e sem GUI, só as equações.
- `aerosim/sizing/constraints.py` — Diagrama de restrições do dimensionamento inicial: razão tração/peso (T/W) exigida por cada
  `class ParabolicPolar:35`, `estimate_polar:44`, `class Requirements:56`, `isa_rho:86`, `active_kinds:90`, `condition_speed:101`, `required_tw:118`, `stall_ws:146`, `landing_ws:150`, `ws_limits:154`, `constraint_curves:161`, `design_point:168`

## Python · `aerosim/stability`

- `aerosim/stability/__init__.py` — Estabilidade: estática (ponto neutro, margem, volumes de cauda), gráfico tesoura
- `aerosim/stability/controls.py` — Dimensionamento das superfícies de comando a partir da asa e das caudas.
  `time_to_bank:42`, `aileron_sizing:59`, `elevator_sizing:110`, `rudder_sizing:155`
- `aerosim/stability/criteria.py` — Critérios de aprovação da aba Estabilidade — vêm de uma norma ou do usuário.
  `class Criteria:17`, `mil_8785c:56`, `none:74`, `evaluate:79`
- `aerosim/stability/dynamic.py` — Estabilidade dinâmica pelo modelo linear do núcleo (aerosim_linearize: corpo rígido com
  `modes:41`, `mil_check:79`, `lanchester:127`, `response:131`, `doublet:153`, `pulse:164`
- `aerosim/stability/probe.py` — Acesso ao núcleo para as análises de estabilidade: uma sessão configurada com a aeronave,
  `class Probe:16`
- `aerosim/stability/scissor.py` — Gráfico tesoura (dimensionamento da EH e da faixa de CG).
  `scale_htail:24`, `limits:38`, `scissor:67`, `min_tail:83`
- `aerosim/stability/sizing.py` — Dimensionamento pela posição do CG e variações "e se" da geometria.
  `trim_at_CL:22`, `trimmed_CLmax:46`, `gear_x_for_rotation:66`, `rotation_de:87`, `cg_sweep:101`, `limit_crossing:128`, `scale_surfaces:141`, `with_dihedral:155`, `modes_at:163`, `search:171`, `stall_speed:180`, `with_washout:186`, `with_elevon:196`, `cm0:209`
- `aerosim/stability/static.py` — Estabilidade estática longitudinal e látero-direcional.
  `analytic_np:26`, `static_analysis:44`

## Zig · núcleo (`core/src`)

**core/src/**

- `core/src/abi.zig` — Esquema das estruturas exportadas, gerado em comptime por reflexão.
- `core/src/aerosim.zig` — Documentação do núcleo do aerosim (`zig build docs`): todas as pastas de `core/src`, uma por seção.
  tipos `math:10`, `physics:18`, `modifiers:30`, `collision:40`, `control:45`, `sim:52`, `loads:63`, `sizing:68`, `optim:80`, `geometry:94`, `util:99`
- `core/src/bench.zig` — Benchmarks exportados (o Python cronometra): funções matemáticas isoladas com tabelas
  tipos `Kind:9`
  fn `math:80`, `dynamics:98`
- `core/src/lib.zig` — O núcleo como módulo Zig (para programas em Zig, como o aerodrive): os mesmos tipos e funções
- `core/src/limits.zig` — Limites de compilação. Toda a memória do núcleo é estática e dimensionada aqui:
- `core/src/opt.zig` — Otimizações em avaliação (`-Dopt`): cada uma é um bit, desligado por padrão (ver core/OTIMIZACOES.md).
  tipos `Opt:5`
- `core/src/root.zig` — Interface C ABI do núcleo (o que o Python chama via ctypes).
  fn `abiCode:48`
  **ABI (75 exports)** `aerosim_abi_version`, `aerosim_schema`, `aerosim_probe_ground`, `aerosim_probe_slipstream`, `aerosim_aero_coeffs_thrust`, `aerosim_aero_coeffs_at`, `aerosim_tube_panel_hits`, `aerosim_tube_point_hits`, `aerosim_prop_state`, `aerosim_panel_states`, `aerosim_panel_states_llt`, `aerosim_aero_coeffs_llt`, `aerosim_schema_hash`, `aerosim_acquire`, `aerosim_release`, `aerosim_params`, `aerosim_params_reset`, `aerosim_configure`, `aerosim_reset_ground`, `aerosim_reset_air`, `aerosim_run`, `aerosim_events`, `aerosim_time`, `aerosim_snapshot_size`, `aerosim_snapshot_save`, `aerosim_snapshot_load`, `aerosim_mass_props`, `aerosim_aero_coeffs`, `aerosim_aero_coeffs_ex`, `aerosim_linearize`, `aerosim_autotune`, `aerosim_prop_point`, `aerosim_trim`, `aerosim_performance`, `aerosim_envelope`, `aerosim_envelope_curve`, `aerosim_simple_perf`, `aerosim_bench_math`, `aerosim_bench_dynamics`, `aerosim_fast_math`, `aerosim_expr_check`, `aerosim_expr_eval`, `aerosim_ground_runs`, `aerosim_ground_mtow`, `aerosim_motor_prop_thrust`, `aerosim_sizing_eval`, `aerosim_sizing_optimize`, `aerosim_sizing_name`, `aerosim_sizing_defaults`, `aerosim_geometry_check`, `aerosim_ga_init`, `aerosim_ga_next`, `aerosim_cma_init`, `aerosim_cma_ask`, `aerosim_cma_tell`, `aerosim_de_init`, `aerosim_de_trials`, `aerosim_de_select`, `aerosim_local_fit`, `aerosim_rbf_fit`, `aerosim_rbf_eval`, `aerosim_lhs`, `aerosim_repair_step`, `aerosim_eps_level`, `aerosim_eps_worse`, `aerosim_bandit_state_len`, `aerosim_bandit_init`, `aerosim_bandit_pick`, `aerosim_bandit_update`, `aerosim_normative`, `aerosim_lem_box`, `aerosim_box_sample`, `aerosim_sens_tolerance`, `aerosim_morris_design`, `aerosim_morris_effects`
- `core/src/tests.zig` — Todos os testes do núcleo, por grupo. `zig build test` roda tudo; `-Dgrupo=math` roda só um grupo e
- `core/src/types.zig` — Estruturas trocadas com o Python (C ABI, `extern struct`).
  tipos `Surface:29`, `PropUnit:64`, `Gear:108`, `Tank:124`, `Segment:140`, `Event:162`, `Pad:166`, `Payload:175`, `Environment:186`, `Takeoff:198`, `Pilot:216`, `Autopilot:226`, `AeroTable:275`, `LltCache:308`, `Params:320`, `PanelState:397`, `Events:417`, `LogRow:459`, `AeroCoeffs:573`, `PropPoint:588`, `MassProps:600`, `TrimPoint:612`, `PerfRow:629`

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
- `core/src/control/guidance.zig` — Percurso (corrente de segmentos) e guiamento lateral.
  tipos `Guide:15`
  fn `guide:38`, `rejoinSegment:102`

**core/src/geometry/**

- `core/src/geometry/geometry.zig` — Geometria do avião montado: se as peças cabem juntas antes de qualquer conta de aerodinâmica.
  tipos `Part:32`, `Scene:40`, `Report:53`
  fn `boxesTouch:91`, `pointInBox:109`, `pointNearBox:114`, `discHitsBox:123`, `discsTouch:197`, `lowest:229`, `check:258`, `checkMany:354`

**core/src/loads/**

- `core/src/loads/llt.zig` — Linha sustentadora numérica (vórtices em ferradura) para a distribuição de carga ao longo da envergadura.
  tipos `Node:192`
  fn `sectionSlope:48`, `segment:55`, `horseshoe:72`, `surfaceNodes:103`, `prepare:274`, `apply:368`, `compute:480`, `coeffs:512`

**core/src/math/**

- `core/src/math/fmath.zig` — Funções matemáticas: tabelas (LUT) + aproximações polinomiais, e a referência da std.
  tipos `SinCos:30`, `lut:73`, `ref:170`, `minimax:228`
  fn `optOn:21`, `SinLut:33`, `sincos:273`, `sin:277`, `cos:281`, `tan:285`, `atan:290`, `atan2:294`, `asin:298`, `acos:303`, `exp:308`, `log:312`, `pow:317`, `tanh:322`, `sqrt:326`, `hypot:330`, `sat:336`, `lim:340`, `sgn:344`, `wrap:348`
- `core/src/math/fmath_test.zig` — Testes só das LUTs e aproximações (independentes de -Dfast_math: comparam `lut` com `ref`).
- `core/src/math/linalg.zig` — Álgebra linear densa de tamanho fixo: fatoração LU com pivoteamento parcial e de Cholesky, e as
  fn `luFactor:14`, `luSolve:39`, `cholesky:58`, `cholSolve:76`, `symEigen:93`, `solve:139`
- `core/src/math/poly.zig` — Polinômio em duas variáveis de grau N gerado em comptime, na ordem dos ajustes do MATLAB
  fn `Poly2:10`
- `core/src/math/vec.zig` — Vetores 3D em registradores SIMD (@Vector) e matrizes 3x3 por linhas.
  fn `v3:11`, `arr:15`, `splat:19`, `dot:23`, `norm:27`, `cross:31`, `mul:40`, `mulT:44`, `rotation:49`, `solve3:67`

**core/src/modifiers/**

- `core/src/modifiers/flapmoment.zig` — Momento próprio do comando (flape, profundor, elevon) no quarto de corda da faixa.
  fn `thetaOf:16`, `cmDelta:29`
- `core/src/modifiers/ground.zig` — Efeito solo: métodos para o fator do arrasto induzido perto do chão.
  fn `factor:13`, `mccormick:21`
- `core/src/modifiers/mod.zig` — Modificadores: metodologias da literatura que mudam a aerodinâmica do avião inteiro sem mexer no resto
  tipos `Env:22`
  fn `envFrom:37`, `hits:51`, `hitsProp:58`, `stripOf:72`, `induced:79`, `inducedNoPair:84`, `flapCm:104`
- `core/src/modifiers/slipstream.zig` — Esteira da hélice por disco atuador (modificador `esteira.disco`).
  tipos `TubeShape:32`, `Point:82`
  fn `shape:49`, `diskInduced:54`, `axialAt:62`, `radiusAt:67`, `swirlRate:75`, `at:90`
- `core/src/modifiers/types.zig` — Tipos dos modificadores trocados com o Python (C ABI, `extern struct`; o esquema sai de `abi.zig`).
  tipos `Ground:14`, `Kind:21`, `SlipstreamParam:30`, `PairParam:39`, `Modifier:50`
- `core/src/modifiers/wingpair.zig` — Interferência entre duas asas ligadas (tandem, biplano) no modelo de faixas.
  fn `active:29`, `induced:45`

**core/src/optim/**

- `core/src/optim/cmaes.zig` — CMA-ES: a estratégia evolutiva com adaptação da matriz de covariância, para as variáveis contínuas do aeroopt
  tipos `CmaState:24`
  fn `init:48`, `ask:117`, `tell:133`
- `core/src/optim/de.zig` — Evolução diferencial (DE/rand/1/bin), para as variáveis contínuas do aeroopt (envergadura, área, diedro...).
  fn `initPop:25`, `trials:35`, `select:63`
- `core/src/optim/expr.zig` — Executa o programa de pilha da pontuação (`types.Program`): as entradas de um candidato entram nas
  tipos `Error:11`
  fn `check:22`, `run:71`, `runMany:115`
- `core/src/optim/ga.zig` — Gerações de aviões: o algoritmo genético que escolhe as configurações do aeroopt no lugar de varrer todas as
  tipos `GaCfg:21`
  fn `init:47`, `next:64`
- `core/src/optim/guided.zig` — Busca guiada pela falha: as peças que deixam o otimizador usar o MOTIVO de um avião não voar, e não só o quanto
  fn `repairStep:50`, `epsLevel:76`, `epsWorse:83`, `banditInit:102`, `banditPick:119`, `banditUpdate:138`, `normative:181`, `lemBox:200`, `boxSample:241`
- `core/src/optim/localfit.zig` — Modelo local por mínimos quadrados ponderados: a partir de pontos já avaliados em volta de um ponto x₀, a
  tipos `Fit:24`
  fn `fit:54`
- `core/src/optim/rbf.zig` — Substituto por funções de base radial (RBF): a superfície que passa exatamente por todos os pontos já avaliados e
  fn `size:23`, `fit:73`, `eval:100`
- `core/src/optim/sampling.zig` — Amostragem do espaço de busca: de onde nascem os primeiros indivíduos das buscas contínuas do aeroopt.
  fn `minDist2:38`, `lhs:55`
- `core/src/optim/sensmethods.zig` — Os métodos da sensibilidade do melhor avião do aeroopt (`aeroopt/sensitivity.py`), além do modelo local
  fn `tolerance:29`, `morrisDelta:44`, `morrisDesign:53`, `morrisEffects:78`
- `core/src/optim/types.zig` — Tipos do aeroopt no núcleo: o programa de pilha que calcula a nota de um candidato. O Python traduz o
  tipos `Op:12`, `Tier:30`, `Program:37`

**core/src/physics/**

- `core/src/physics/aero.zig` — Aerodinâmica por componentes.
  tipos `Out:18`
  fn `sigmaStall:28`, `init:93`, `compute:126`, `computeEnv:131`, `computeTrace:136`, `fuselage:247`, `coeffs:262`, `coeffsEx:267`, `coeffsEnv:272`, `coeffsAt:277`
- `core/src/physics/aeromodel.zig` — O modelo aerodinâmico do voo, escolhido por `Params.aero_model`: quem a dinâmica, a trimagem e a linearização
  fn `compute:20`
- `core/src/physics/aerotable.zig` — Modelo aerodinâmico por tabela (Params.aero_model = 2): os coeficientes do avião inteiro vêm de `Params.aero_tab`,
  fn `coeffs:34`, `compute:50`
- `core/src/physics/atmosphere.zig` — Vento 3D numa direção (perfil 1/7 com a altura) e rajada 1-cos.
  fn `wind:8`
- `core/src/physics/gear.zig` — Trem de pouso: N pontos de contato (triciclo, convencional, patins...).
  tipos `Out:16`
  fn `compute:23`, `touching:65`
- `core/src/physics/mass.zig` — Massa, CG e inércia variáveis; sloshing de N tanques; extração da carga (LAPES).
  tipos `Mass:49`, `Load:105`
  fn `initTanks:17`, `compute:58`, `slosh:109`, `payload:138`
- `core/src/physics/propulsion.zig` — K unidades propulsoras: hélice por tabela C_T(J), C_P(J) + motor BLDC + bateria.
  tipos `Unit:16`, `Out:28`
  fn `init:42`, `polyRaw:100`, `tiltNow:117`, `axis:124`, `unit:132`, `compute:156`, `equilibriumRps:194`, `point:224`
- `core/src/physics/terrain.zig` — Terreno: chão plano (h = 0) com mesas/plataformas retangulares elevadas.
  fn `height:9`

**core/src/sim/**

- `core/src/sim/dynamics.zig` — Equação mestre f(t, x) (`derivatives`) e integração RK4.
  tipos `Out:26`
  fn `derivatives:87`, `rk4:248`
- `core/src/sim/envelope.zig` — Envelope de voo por altitude (sem integrar no tempo).
  tipos `EnvCfg:36`, `EnvRow:74`
  fn `density:87`, `compute:300`, `curve:333`
- `core/src/sim/linear.zig` — Modelo linear em torno do voo nivelado equilibrado (estabilidade dinâmica).
  tipos `LinModel:28`
  fn `rigid:56`, `linearize:169`, `residual:224`
- `core/src/sim/runner.zig` — Executor de uma corrida: eventos discretos, paradas, registro e checkpoints.
  tipos `Status:26`, `Instance:37`
  fn `stateText:65`, `configure:95`, `handover:162`, `resetGround:184`, `resetAir:238`, `run:391`
- `core/src/sim/simple_perf.zig` — Desempenho por cálculo simples (sem simulação no tempo), como na "planilha suprema":
  tipos `SimpleCfg:23`, `SimpleRow:52`, `SimpleSummary:76`
  fn `density:108`, `compute:132`
- `core/src/sim/state.zig` — Layout do vetor de estados (definido em comptime a partir dos limites)
  tipos `Entry:7`, `Flags:87`, `Run:103`, `Ctx:119`
  fn `index:57`, `rps:66`, `sx:70`, `sy:74`, `sxd:78`, `syd:82`
- `core/src/sim/tests.zig` — Testes de integração do núcleo: aeronave monomotora convencional (a do código
- `core/src/sim/trim.zig` — Equilíbrio (trimagem) e desempenho por velocidade, sem integração no tempo.
  tipos `Ctx:25`
  fn `solve:131`, `performance:145`

**core/src/sizing/**

- `core/src/sizing/chain.zig` — A cadeia do mini-MDO para um tipo de aeronave e um provedor de tração, gerada em comptime:
  tipos `CoreThrust:24`, `LinearThrust:47`
  fn `checkThrust:18`, `decode:58`, `motorsFor:80`, `Chain:96`
- `core/src/sizing/ground.zig` — Corrida de decolagem rápida da sprint (etapa Motores, `aerosim/design/power.py: performance`): a mesma
  tipos `GroundRun:23`
  fn `interp:50`, `rotSpeed:77`, `run:87`, `mtow:112`
- `core/src/sizing/kinds.zig` — Tipos de aeronave do dimensionamento: cada um é um tipo Zig com a mesma interface, conferida em
  tipos `Hover:19`, `Monoplane:21`, `Biplane:50`, `FlyingWing:73`, `Tailsitter:96`, `Vtol:119`
  fn `biplaneSigma:45`, `check:146`
- `core/src/sizing/motorprop.zig` — Tração em regime de um conjunto motor + hélice + bateria com acelerador cheio, para a curva T(V) da sprint
  tipos `MotorProp:22`
  fn `thrust:46`, `curve:79`
- `core/src/sizing/optimize.zig` — Otimizadores do mini-MDO atrás de uma interface só.
  tipos `Eval:16`, `Problem:21`, `Recorder:50`, `Result:79`, `Pso:100`, `RandomSearch:156`
  fn `check:188`, `run:198`
- `core/src/sizing/sizing.zig` — Dimensionamento inicial (mini-MDO) no núcleo: avalia um vetor de projeto e otimiza.
  fn `eval:20`, `fitness:29`, `optimize:49`, `name:59`
- `core/src/sizing/stages.zig` — Estágios da cadeia de dimensionamento, cada um uma função pura com entradas e saídas pequenas:
  tipos `Curve:18`, `Geo:42`, `Polar:67`, `Env:82`, `Mass:211`
  fn `geometry:45`, `blendAirfoils:55`, `polar:70`, `stallSpeed:94`, `envelope:99`, `sustainedN:132`, `isaRho:141`, `isaAltitude:146`, `ceiling:151`, `landingRun:175`, `takeoffRun:181`, `canHover:206`, `emptyMass:214`, `linearCurve:228`
- `core/src/sizing/types.zig` — Tipos do dimensionamento inicial (mini-MDO): a configuração que vem do Python, o vetor de
  tipos `VarSpec:30`, `Constraint:76`, `AirfoilData:94`, `LayoutData:105`, `PropSet:115`, `SizingCfg:130`, `SizingOut:171`, `OptOpts:191`, `Individual:203`
  fn `massDependent:65`, `violation:84`

**core/src/util/**

- `core/src/util/fuzz.zig` — Fuzzing dos módulos.
  tipos `Src:15`
  fn `check:60`, `checkScaled:69`


## Zig · AeroDrive (`aerodrive/src`)

**aerodrive/src/**

- `aerodrive/src/main.zig` — AeroDrive: abre o menu inicial com o avião (o último escolhido, ou o do argumento).
  fn `main:85`
- `aerodrive/src/tests.zig` — Todos os testes do aerodrive que não precisam de janela (`zig build test`).

**aerodrive/src/app/**

- `aerodrive/src/app/app.zig` — O jogo inteiro: o que as telas dividem (fontes, widgets, configurações, o avião carregado, som,
  tipos `Id:46`, `Next:48`, `Plane:57`, `Screens:76`, `App:91`
- `aerodrive/src/app/library.zig` — Biblioteca de aviões: os `.json` das pastas de exemplos e de "meus aviões" (os salvos pela
  tipos `Group:7`, `Entry:19`, `Library:27`
  fn `scan:42`, `fingerprint:80`, `entryName:116`
- `aerodrive/src/app/paths.zig` — Onde ficam as coisas no disco, a partir das variáveis de ambiente:
  tipos `Paths:10`
  fn `resolve:19`
- `aerodrive/src/app/plane_settings.zig` — Configurações de cada avião, lembradas por arquivo: a sessão (chão/mesa, pouso, quem pilota,
  tipos `PlaneSettings:14`
- `aerodrive/src/app/settings.zig` — Configurações do jogador, guardadas entre uma vez e outra: avião escolhido, sessão (cenário,
  tipos `CameraKind:9`, `CameraSettings:11`, `Settings:26`
  fn `sanitizeProfile:111`
- `aerodrive/src/app/store.zig` — Interface de armazenamento chave → bytes (e JSON por cima). Quem guarda configurações não sabe
  tipos `Store:12`, `FileStore:49`, `MemStore:79`
  fn `keyFor:125`

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
  tipos `Scene:87`
  fn `toScreen:26`, `matrix:32`, `camera3d:43`, `color:47`, `hangarGrid:163`, `drawField:176`, `drawTrail:196`

**aerodrive/src/input/**

- `aerodrive/src/input/channels.zig` — Canais de comando: o que está apertado no controle (eixos −1..1, gatilhos 0..1, botões) ->
  tipos `Source:15`, `Pad:46`, `Action:66`, `Bindings:100`, `Scheme:126`, `Curve:152`, `Raw:175`, `Commands:191`, `Profile:193`, `Inputs:224`, `State:227`
- `aerodrive/src/input/gamepad.zig` — Leitura do controle e do teclado (raylib) → o que está apertado (`channels.Raw`) + botões de
  tipos `Actions:19`, `Reader:29`
  fn `toRaylib:77`, `pressedButton:99`

**aerodrive/src/math/**

- `aerodrive/src/math/vec3.zig` — Vetores 3D (f64) e rotações usados pelo modelo, pelo esqueleto e pelas câmeras.
  fn `add:8`, `sub:11`, `scale:14`, `mul:17`, `dot:20`, `cross:23`, `norm:26`, `finite:29`, `unit:34`, `apply:43`, `matmul:47`, `axisAngle:56`, `bodyToNed:71`

**aerodrive/src/model/**

- `aerodrive/src/model/aircraft.zig` — Leitura do arquivo do avião salvo pela GUI (`data/aircraft/*.json`, "meus aviões").
  tipos `Section:11`, `Control:19`, `Device:58`, `Airfoil:75`, `Surface:86`, `Fuselage:115`, `Boom:132`, `Propeller:161`, `Motor:162`, `Battery:163`, `ThrustPoly:174`, `Propulsion:186`, `GearLeg:203`, `Gear:204`, `Tank:227`, `Payload:247`, `PointMass:258`, `Mass:259`, `Environment:270`, `Takeoff:280`, `SimSettings:281`, `Autopilot:283`, `Leg:328`, `MissionEvent:341`, `Mission:342`, `Ballast:352`, `Airfield:353`, `Aircraft:368`, `limits:399`, `Diag:423`, `Loaded:437`
  fn `mixedAirfoils:14`, `kindGains:48`, `parse:447`, `validate:506`, `semispan:593`, `sortedSections:600`, `sectionAt:612`, `tailOnBoom:625`
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
  tipos `Info:13`, `Recorder:21`, `Entry:112`, `Catalog:119`
  fn `stampOf:96`, `list:129`, `deleteVideo:162`, `deleteRecording:170`, `label:184`
- `aerodrive/src/record/video.zig` — Vídeo do voo em .mp4: os quadros da tela (RGBA) vão por um cano para o `ffmpeg` (H.264).
  tipos `Video:6`
  fn `accepts:56`
- `aerodrive/src/record/video_player.zig` — Assistir um .mp4 gravado dentro do jogo: o `ffprobe` diz o tamanho, a taxa e a duração; o
  tipos `Info:12`, `Decoder:62`
  fn `parseProbe:15`, `outSize:31`, `probe:38`

**aerodrive/src/screens/**

- `aerodrive/src/screens/aircraft_menu.zig` — Aeronave: escolher o arquivo (exemplos e "meus aviões" da GUI) — o modelo 3D troca na hora —,
  tipos `AircraftMenu:17`
  fn `compass:120`
- `aerodrive/src/screens/camera_menu.zig` — Câmera: distância e altura da perseguição (em envergaduras), campo de visão e a câmera
  tipos `CameraMenu:20`
- `aerodrive/src/screens/control_menu.zig` — Controle, em duas abas:
  tipos `ControlMenu:31`
- `aerodrive/src/screens/flight.zig` — Voo: o drive_manager avança a física em tempo real; no manual, o controle (com as curvas do
  tipos `Flight:38`
- `aerodrive/src/screens/fly_menu.zig` — Voar: onde começa (chão ou mesa), onde pousa (chão ou plataforma), quem pilota no começo
  tipos `FlyMenu:24`
- `aerodrive/src/screens/main_menu.zig` — Menu inicial: logo da Albatroz, "AeroDrive", o avião escolhido e os itens; à direita a aeronave
  tipos `MainMenu:23`
- `aerodrive/src/screens/options_menu.zig` — Opções (do menu inicial): Controle, Câmera, Som, Voos gravados e a tela (janela ou tela cheia,
  tipos `OptionsMenu:12`
- `aerodrive/src/screens/pause_menu.zig` — Pausa (Start / Esc no voo): o voo congelado por trás e o menu — continuar, ajustar controle e
  tipos `PauseMenu:12`
- `aerodrive/src/screens/recording_view.zig` — Dados de um voo gravado: a lista de gráficos disponíveis à esquerda (as grandezas da aba Missão)
  tipos `RecordingView:15`
- `aerodrive/src/screens/recordings_menu.zig` — Voos gravados: as gravações (mais novas primeiro); escolhida uma: assistir o vídeo aqui dentro
  tipos `RecordingsMenu:14`
- `aerodrive/src/screens/sound_menu.zig` — Som: volume geral e o teste — o acelerador de teste (ou o gatilho / W e S) muda a altura e o
  tipos `SoundMenu:12`
- `aerodrive/src/screens/video_view.zig` — Assistir o vídeo de um voo gravado dentro do jogo. A / Espaço: pausa e continua · ← →: volta e
  tipos `VideoView:13`

**aerodrive/src/sim/**

- `aerodrive/src/sim/drive_manager.zig` — drive_manager: dono da simulação durante o voo. A cada quadro avança o núcleo até o tempo do
  tipos `Commands:25`, `Phase:27`, `Frame:30`, `DriveManager:51`
- `aerodrive/src/sim/mission.zig` — Percurso -> segmentos, eventos e mesas/plataformas do núcleo (`aerosim/model/mission.py` e
  fn `autoRadius:13`, `segments:20`, `events:76`, `pads:92`
- `aerodrive/src/sim/params.zig` — Avião (arquivo da GUI) -> parâmetros do núcleo (`types.Params`), em Zig.
  tipos `Info:28`, `DryMass:315`
  fn `area:43`, `span:53`, `mac:57`, `references:76`, `dryMass:342`, `fill:412`, `setup:560`, `staticCharacteristics:590`
- `aerodrive/src/sim/session.zig` — Sessão de voo: o que o jogador escolhe nos menus antes de voar (cenário, modo, vento, sloshing,
  tipos `Scenario:7`, `Landing:19`, `Mode:31`, `Session:43`
  fn `gearExtent:98`

**aerodrive/src/sys/**

- `aerodrive/src/sys/keep_awake.zig` — Não deixa a tela escurecer nem apagar com o jogo aberto. Jogar só com o controle não conta como
  tipos `KeepAwake:20`
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
  tipos `Fonts:36`
  fn `commandBar:69`
- `aerodrive/src/ui/widgets.zig` — Widgets dos menus (modo imediato): cada quadro a tela chama `begin`, os widgets na ordem em que
  tipos `Nav:14`, `Ui:23`, `Row:252`, `ScrollList:255`, `Column:312`
  fn `header:330`, `footer:336`

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


## Ferramentas (`tools/`)

- `tools/aeroopt.py` — Roda um problema do aeroopt (.opt.json) e mostra o resultado: o melhor ponto, as restrições e a convergência.
- `tools/banco_otimizadores.py` — Banco de comparação dos otimizadores do aeroopt: qual busca acha o melhor avião, com quantos pontos, em que tipo de
- `tools/capturas.py` — Fotos de todas as abas (roda cada simulação com os padrões).
- `tools/codemap.py` — Mapa do código: gera docs/MAP.md a partir do próprio código (nunca editar o MAP.md à mão).
- `tools/load_view.py` — Vista 3D da carga aerodinâmica de um avião num ponto de operação: as superfícies pintadas pela carga alar local
- `tools/metodos_voa.py` — Qual busca da etapa voa (E&C) do aeroopt acha mais rápido um avião que voa? Compara os métodos de FLY_METHODS.
- `tools/modcheck.py` — Roda um avião com os modificadores dele e sem cada um (um de cada vez) e mostra a diferença na decolagem.
- `tools/opt_matrix.py` — Mapa das otimizações em avaliação do núcleo (`-Dopt`): compila cada combinação, mede e compara os resultados
- `tools/pipeline_bench.py` — Compara as estratégias de paralelismo do processo em etapas do aeroopt: o mesmo lote de configurações roda em série,
- `tools/plot_comparativo.py` — Figuras das abas Aerodinâmica e Estabilidade (PNG), iguais ao que a GUI mostra.
- `tools/probe.py` — Sonda dos modificadores pela linha de comando: chama o módulo do núcleo (core/src/modifiers/) direto, sem
- `tools/rotacao.py` — O comando de arfagem roda o avião na pista? A conta da sprint contra a do núcleo, termo a termo.
- `tools/sementes.py` — A etapa voa (E&C) do aeroopt com sementes, inícios e partidas diferentes: todos caem no mesmo avião?
- `tools/span_load.py` — Carga ao longo das superfícies (asa, EH, EV) num ponto de operação — velocidade, α e rotação dos motores — com e
- `tools/sprint_pasta.py` — Exemplo: converte um projeto da sprint antigo (um .json só) para a pasta nova, um arquivo por asa.
- `tools/sprint_tres_caudas.py` — Exemplo: uma asa só com três opções de superfícies, no formato de pasta (um arquivo por asa).
- `tools/time_profile.py` — Perfil de tempo: onde uma análise gasta o tempo, no Python e no núcleo Zig ao mesmo tempo.
- `tools/aero/__init__.py`
- `tools/aero/casos.py` — Perfis de teste da aerodinâmica: aviões simples, só superfícies (sem fuselagem e sem motor), para comparar os
- `tools/aero/coeficientes.py` — Coeficientes de cada perfil de teste (tools/aero/casos.py) a uma velocidade (padrão 12 m/s), por método, e a
- `tools/aero/decolagem.py` — O erro de cada modelo aerodinâmico ao longo de uma decolagem (fase A: sem mudar a simulação nem o AeroDrive).
- `tools/aero/missao.py` — Voar a missão inteira (ou só a decolagem) com cada modelo aerodinâmico e comparar os voos (T65, fase B).
- `tools/checks/doc_checks.py` — Documentação: o mapa do código (docs/MAP.md) tem de estar em dia com o código.
- `tools/checks/golden.py` — Regressão bit a bit: retrata os aviões de exemplo no código atual e numa referência (um commit, padrão a `main`)
- `tools/checks/pytest_checks.py` — Os testes Python por área: uma pasta de `tests/` por check, para saber qual área quebrou e quanto cada uma demora.
- `tools/checks/registry.py` — Registro dos checks: cada check é uma função que devolve um `Result`, com nome e grupo.
- `tools/checks/run.py` — Checks de regressão: confere que nada quebrou antes de um PR.
- `tools/checks/snapshot.py` — Retrato numérico dos aviões de exemplo, para comparar duas versões do código bit a bit.
- `tools/checks/zig_checks.py` — Fundação e AeroDrive: os testes do núcleo Zig e a compilação + testes do AeroDrive (que importa o núcleo).
- `tools/validacao/navion.py` — Validação contra um avião real: o Ryan Navion (monomotor a pistão, anos 1940) montado com os números publicados e as

## Testes (`tests/`)

- `tests/aero` — 59 testes em 9 arquivo(s)
- `tests/aeroopt` — 78 testes em 8 arquivo(s)
- `tests/core` — 34 testes em 9 arquivo(s)
- `tests/data` — 12 testes em 4 arquivo(s)
- `tests/design` — 75 testes em 11 arquivo(s)
- `tests/gui` — 23 testes em 1 arquivo(s)
- `tests/manager` — 60 testes em 10 arquivo(s)
- `tests/model` — 51 testes em 9 arquivo(s)
- `tests/parallel` — 8 testes em 1 arquivo(s)
- `tests/stability` — 12 testes em 1 arquivo(s)
- `tests/test_architecture.py` — 5 testes em 1 arquivo(s)
- `tests/tools` — 29 testes em 6 arquivo(s)
- `tests/validation` — 2 testes em 1 arquivo(s)

## README por pasta

- `README.md`
- `aerodrive/README.md`
- `aerodrive/src/README.md`
- `aeroopt/README.md`
- `aerosim/aero/README.md`
- `aerosim/backend/README.md`
- `aerosim/data/README.md`
- `aerosim/design/README.md`
- `aerosim/gui/README.md`
- `aerosim/interfaces/README.md`
- `aerosim/manager/README.md`
- `aerosim/model/README.md`
- `aerosim/parallel/README.md`
- `aerosim/sizing/README.md`
- `aerosim/stability/README.md`
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
- `data/README.md`
- `tests/README.md`
- `tools/README.md`
- `tools/aero/README.md`
- `tools/checks/README.md`

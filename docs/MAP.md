# Mapa do código

Gerado por `python tools/codemap.py` — **não editar à mão** (`--check` acusa quando está desatualizado).
Formato: `arquivo` — primeira linha da documentação; depois os nomes públicos com a linha (`nome:linha`).
Regras e decisões do projeto: `.claude/CLAUDE.md`. O que falta e a ordem: `docs/TRACKING.md`.

## Python · `aerosim`

- `aerosim/__init__.py` — aerosim — simulador 6GDL de aeronaves em camadas:
- `aerosim/bridge.py` — Ponte entre a tela em Zig (raylib) e os managers em Python: uma mensagem JSON por linha, na entrada e na saída
  `class Bridge:51`, `start_in_browser:602`, `call_in_browser:610`, `main:625`

## Python · `aerosim/aero`

- `aerosim/aero/__init__.py` — Aerodinâmica a partir da geometria: comparação de métodos (modelo interno, lltdrek,
  `all_solvers:20`, `all_load_methods:25`, `load_method:33`, `parabolic_polar:42`, `solver_by_name:51`, `polar_metrics:55`
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
  `class LoadCase:37`, `class SurfaceLoad:54`, `class PropState:86`, `class SpanLoads:102`, `refine_surface:149`, `refine_all:173`, `prepare:235`, `class StripLoadMethod:263`, `class CoreLoadMethod:294`, `compute:411`, `to_result:424`
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
  `lib_path:24`, `build:47`, `class CoreError:74`, `class ZigSession:217`, `class ZigBackend:495`
- `aerosim/backend/zig/geometry.py` — Tradutor da checagem de geometria: o modelo universal vira as peças simples do núcleo (`core/src/geometry`),
  `scene:114`, `report:165`, `class ZigGeometry:191`
- `aerosim/backend/zig/translator.py` — Tradutor modelo universal -> núcleo Zig (SimSpec: dicionário com os campos das structs extern).
  `prop_native:26`, `surface_panels:42`, `panel_owners:75`, `class ZigTranslator:84`, `aero_native:150`, `native_spec:188`

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
  `rg_sae:31`, `class DesignProject:41`, `is_project_file:274`, `next_name:286`
- `aerosim/design/registry.py` — Registro de grandezas do projeto: o que dá para medir, restringir ou variar.
  `class Quantity:25`, `fmt:71`, `class Constraint:78`, `default_constraints:106`, `active:118`, `checks:122`, `class Input:138`, `class Variable:167`, `default_variables:179`, `get_input:187`, `set_input:192`, `wing_values:200`, `aircraft_values:206`, `sae_constraints:232`, `bounds_from_constraints:243`, `check_bounds:264`
- `aerosim/design/results.py` — Cada etapa como um `SimResult` (séries, resumo, diagnóstico) e os gráficos dela (`PlotSpec`): a GUI
  `constraint_checks:30`, `airfoil_stage:52`, `wing_stage:103`, `set_stage:177`, `aircraft_stage:289`
- `aerosim/design/spec.py` — Condições e restrições (o que o avião tem de cumprir) e regras de projeto (como as peças se montam).
  `class Requirements:28`, `class DesignRules:98`, `cruise_CL:123`, `stall_speed:127`
- `aerosim/design/store.py` — O projeto da sprint numa pasta escolhida pelo usuário, com um arquivo por asa.
  `file_name:50`, `split:99`, `run_file:143`, `wing_files:164`, `save:177`, `join:207`, `is_folder:272`, `load:278`, `is_sprint_path:296`, `folder_for:309`, `open_path:322`
- `aerosim/design/study.py` — Estudo e ponto de projeto: as áreas se retroalimentam (não em ordem) e o estudo mostra onde estabilidade e
  `class StudyParams:45`, `class StudyRun:57`, `to_run:74`, `from_run:86`, `ensure:91`, `table:109`, `parse_places:114`, `with_value:129`, `feasibility:138`, `point_row:169`, `run:181`, `best_rows:214`, `mtow_of:226`, `check_6dof:230`, `check_many:258`, `result:293`
- `aerosim/design/tail.py` — Etapa Empenagem e comandos: as superfícies que acompanham a asa escolhida, o tubo de cauda e os comandos.
  `class SurfaceControl:52`, `class TailParams:60`, `class SetCandidate:137`, `tail_airfoil:165`, `tail_entry:170`, `build_set:194`, `apply_controls:291`, `rule_controls:300`, `wing2_candidate:347`, `second_wing:362`, `join_tips:368`, `analyze:459`, `rotation:626`
- `aerosim/design/wing.py` — Etapa Asa: do perfil escolhido à asa — forma em planta, linha sustentadora e o que ela entrega.
  `class WingPartition:39`, `class WingPlacement:55`, `class WingConfig:69`, `class WingStation:77`, `class WingParams:87`, `class WingCandidate:114`, `stations:132`, `chords:152`, `totals:167`, `sync:173`, `partitions_from_trapezoid:190`, `build_wing:209`, `planform:231`, `tip_weight:245`, `station_weights:253`, `section_props:262`, `lifting_line:275`, `analyze:311`

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
  `class ConstraintsTable:52`, `class VariablesTable:138`, `class ListPicker:246`, `class RequirementsDialog:310`, `class ReqBar:339`, `class StagePage:363`, `class AirfoilPage:582`, `class WingPage:743`, `class TailPage:918`, `class PowerPage:973`, `send_to_assembly:1112`, `class StudyPage:1172`
- `aerosim/gui/tabs/__init__.py`
- `aerosim/gui/tabs/config_tab.py` — Aba de configuração em três colunas:
  `mount_choices:56`, `class ConfigTab:68`, `info_html:1150`
- `aerosim/gui/tabs/simulation_tab.py` — Aba genérica de uma simulação: formulário gerado pelos ParamSpec, botões rodar/parar,
  `class SimulationTab:46`, `class TableInput:426`, `export_result:568`
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
  `class ParamSlider:18`, `class NumberField:86`, `class DataclassForm:149`
- `aerosim/gui/widgets/plots.py` — Gráficos da aba (pyqtgraph) montados a partir das PlotSpec da simulação.
  `tex:39`, `is_angle:57`, `class LivePlots:342`, `format_value:444`
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
  `class RunStatus:26`, `class TrimKind:40`, `class LogChunk:48`, `class ISimSession:73`, `class ISimBackend:171`
- `aerosim/interfaces/executor.py` — Contrato de quem roda uma função em muitos itens independentes: em série, em linhas de execução (threads) ou em
  `class Outcome:23`, `class IExecutor:33`
- `aerosim/interfaces/geometry.py` — Contrato da checagem de geometria do avião montado: se as peças cabem juntas, antes da aerodinâmica.
  `class GeometryParams:16`, `class GeometryReport:28`, `class IGeometryCheck:46`
- `aerosim/interfaces/loads.py` — Entrada padrão das análises de carga aerodinâmica: o que os gráficos de carga e a vista 3D aceitam.
  `label:48`, `class SpanDistribution:54`, `class VectorLayer:68`, `class SurfaceField:77`, `class LoadResult:95`, `class LoadPoint:119`, `class WingSweep:138`, `owner_of:152`, `class ILoadMethod:161`
- `aerosim/interfaces/optim.py` — Contratos do aeroopt (o otimizador): o problema, a pontuação, o avaliador e o solver.
  `class OptVariable:32`, `class OptConstraint:43`, `class OptProblem:52`, `class OptResult:92`, `class IScoring:98`, `class IEvaluator:112`, `class ISolver:124`, `class StageItem:134`, `class IStage:144`, `class IFailureDiagnosis:162`
- `aerosim/interfaces/project_store.py` — Interface da biblioteca de aeronaves do usuário ("meus aviões").
  `class ProjectInfo:18`, `class IProjectStore:25`
- `aerosim/interfaces/result_io.py` — SimResult ⇄ dicionário de JSON (para guardar no projeto o que já rodou e mostrar ao abrir sem rodar de novo).
  `result_to_dict:92`, `result_from_dict:102`
- `aerosim/interfaces/simulation.py` — Interface de uma simulação (plugin do Simulation Manager) e do próprio manager.
  `class ParamSpec:34`, `class PlotSpec:54`, `class Check:76`, `class SimResult:89`, `class CancelledError:99`, `class RunContext:104`, `class ISimulation:126`, `class ISimulationManager:174`
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
- `aerosim/manager/form_meta.py` — Rótulo, unidade, faixa, opções e dica dos campos de dataclass que não trazem os metadados de
- `aerosim/manager/forms.py` — O formulário de uma dataclass em `ParamSpec`, sem Qt: a mesma leitura que `DataclassForm`
  `specs:22`, `apply:74`
- `aerosim/manager/manager.py` — Simulation Manager: escolhe qual simulação roda, com que parâmetros, e entrega o
  `class SimulationManager:19`
- `aerosim/manager/runner.py` — Corrida orientada: começa (no chão, em voo ou de um checkpoint), roda até uma parada
  `class Stop:21`, `class RunOutput:35`, `class Runner:42`
- `aerosim/manager/stages.py` — As etapas da sprint sem Qt, para a tela em Zig pela ponte (`aerosim/bridge.py`): o mesmo que as páginas de
  `class Action:35`, `class Table:45`, `class Outcome:53`, `class GridColumn:64`, `class Grid:74`, `class Context:86`, `only_surfaces:106`, `dims_table:119`, `class Stage:131`, `class AirfoilStage:233`, `class WingStage:330`, `class TailStage:597`, `class PowerStage:754`, `class RequirementsStage:841`
- `aerosim/manager/takeoff_opt.py` — Decolagem para a competição: os dois critérios da pista e um de voo.
  `class TakeoffResult:50`, `pitch_control:69`, `judge:76`, `evaluate:140`, `optimize:183`
- `aerosim/manager/simulations/__init__.py` — Simulações disponíveis (uma aba cada na GUI). Para adicionar outra: crie uma classe
- `aerosim/manager/simulations/aerodynamics.py` — Aba Aerodinâmica — polares e derivadas a partir da geometria, com o lltdrek (linha
  `resolve_cg:31`, `compare_solvers:40`, `class AerodynamicsSimulation:79`
- `aerosim/manager/simulations/base.py` — Base comum das simulações: prepara a aeronave (calibração) e roda casos em paralelo.
  `floats:16`, `class SimulationBase:25`
- `aerosim/manager/simulations/climb.py` — Subida em regime: para cada V, nivela (checkpoint) e pede gradientes crescentes a
  `class ClimbSimulation:19`
- `aerosim/manager/simulations/envelope.py` — Envelope de voo por altitude (adaptado do Envelope_main original) + tabela de desempenho.
  `sheet_config:39`, `class EnvelopeSimulation:61`
- `aerosim/manager/simulations/loads.py` — Cargas: a carga aerodinâmica ao longo de cada superfície num ponto de operação (velocidade, fator de carga, α),
  `class LoadsSimulation:31`
- `aerosim/manager/simulations/mission.py` — Missão (simulação 6GDL) por etapa do voo (corrida no chão, cada perna do percurso, rolagem).
  `legs_to_rows:74`, `rows_to_gusts:88`, `rows_to_legs:93`, `xcg_pct:113`, `total_mass:118`, `mtow_rows:125`, `saved_mtows:149`, `mass_variant:158`, `class MissionSimulation:221`
- `aerosim/manager/simulations/performance.py` — Desempenho por cálculo (como na planilha de desempenho): nada é simulado e não há piloto.
  `core_polar:39`, `class PerformanceSimulation:51`
- `aerosim/manager/simulations/polar.py` — Polar estática: C_L, C_D, C_m em α e C_Y, C_l, C_n em β (sem integração no tempo).
  `aircraft_curves:14`, `class PolarSimulation:35`
- `aerosim/manager/simulations/sizing.py` — Aba Dimensionamento inicial — diagrama de restrições T/W × W/S (e P/m × W/S para hélice).
  `class SizingSimulation:34`
- `aerosim/manager/simulations/stability.py` — Aba Estabilidade — diz se a configuração serve, por quê, e o que mudar.
  `class StabilitySimulation:200`
- `aerosim/manager/simulations/takeoff.py` — Decolagem: uma corrida em tempo real e, opcionalmente, o mapa s_R × δe1 com as
  `class TakeoffSimulation:17`
- `aerosim/manager/simulations/thrust.py` — Tração × velocidade de cada unidade propulsora (equilíbrio de rotação do motor).
  `thrust_curves:12`, `class ThrustSimulation:25`
- `aerosim/manager/simulations/turn.py` — Curvas niveladas: raio mínimo por velocidade.
  `class TurnSimulation:21`
- `aerosim/manager/simulations/wings.py` — Asas: a simulação de aerodinâmica da aba Aerodinâmica. Analisa as superfícies escolhidas (uma asa, um biplano, um
  `sprint_wings:81`, `layout_positions:87`, `lifting_surfaces:96`, `strip_aircraft:101`, `wings_only:112`, `sprint_aircraft:126`, `class WingsSimulation:142`

## Python · `aerosim/model`

- `aerosim/model/__init__.py` — Modelo de dados (independente do núcleo): aeronave, perfis, catálogo, missão, geometria.
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
  `trim_at_CL:22`, `trimmed_CLmax:46`, `gear_x_for_rotation:66`, `rotation_de:87`, `cg_sweep:101`, `limit_crossing:128`, `scale_surfaces:141`, `with_dihedral:155`, `modes_at:163`, `slosh_eigs_at:171`, `search:180`, `stall_speed:189`, `with_washout:195`, `with_elevon:205`, `cm0:218`
- `aerosim/stability/static.py` — Estabilidade estática longitudinal e látero-direcional.
  `analytic_np:26`, `static_analysis:44`

## Zig · núcleo (`core/src`)

**core/src/**

- `core/src/abi.zig` — Esquema das estruturas exportadas, gerado em comptime por reflexão.
- `core/src/aerosim.zig` — Documentação do núcleo do aerosim (`zig build docs`): todas as pastas de `core/src`, uma por seção.
  tipos `math:10`, `physics:18`, `modifiers:31`, `collision:41`, `control:46`, `sim:53`, `loads:65`, `sizing:71`, `optim:84`, `geometry:98`, `util:103`
- `core/src/bench.zig` — Benchmarks exportados (o Python cronometra): funções matemáticas isoladas com tabelas
  tipos `Kind:9`
  fn `math:80`, `dynamics:98`
- `core/src/lib.zig` — O núcleo como módulo Zig (para programas em Zig, como o aerodrive): os mesmos tipos e funções
- `core/src/limits.zig` — Limites de compilação. Toda a memória do núcleo é estática e dimensionada aqui:
- `core/src/opt.zig` — Otimizações em avaliação (`-Dopt`): cada uma é um bit, desligado por padrão (ver core/OTIMIZACOES.md).
  tipos `Opt:5`
- `core/src/root.zig` — Interface C ABI do núcleo (o que o Python chama via ctypes).
  fn `abiCode:49`
  **ABI (79 exports)** `aerosim_abi_version`, `aerosim_schema`, `aerosim_probe_ground`, `aerosim_probe_slipstream`, `aerosim_aero_coeffs_thrust`, `aerosim_aero_coeffs_at`, `aerosim_tube_panel_hits`, `aerosim_tube_point_hits`, `aerosim_prop_state`, `aerosim_panel_states`, `aerosim_panel_states_llt`, `aerosim_wing_sweep`, `aerosim_wing_sweep_summary`, `aerosim_reynolds`, `aerosim_aero_coeffs_llt`, `aerosim_schema_hash`, `aerosim_acquire`, `aerosim_release`, `aerosim_params`, `aerosim_params_reset`, `aerosim_configure`, `aerosim_reset_ground`, `aerosim_reset_air`, `aerosim_run`, `aerosim_events`, `aerosim_time`, `aerosim_snapshot_size`, `aerosim_snapshot_save`, `aerosim_snapshot_load`, `aerosim_mass_props`, `aerosim_aero_coeffs`, `aerosim_aero_coeffs_ex`, `aerosim_linearize`, `aerosim_linearize_slosh`, `aerosim_autotune`, `aerosim_prop_point`, `aerosim_trim`, `aerosim_performance`, `aerosim_envelope`, `aerosim_envelope_curve`, `aerosim_simple_perf`, `aerosim_bench_math`, `aerosim_bench_dynamics`, `aerosim_fast_math`, `aerosim_expr_check`, `aerosim_expr_eval`, `aerosim_ground_runs`, `aerosim_ground_mtow`, `aerosim_motor_prop_thrust`, `aerosim_sizing_eval`, `aerosim_sizing_optimize`, `aerosim_sizing_name`, `aerosim_sizing_defaults`, `aerosim_geometry_check`, `aerosim_ga_init`, `aerosim_ga_next`, `aerosim_cma_init`, `aerosim_cma_ask`, `aerosim_cma_tell`, `aerosim_de_init`, `aerosim_de_trials`, `aerosim_de_select`, `aerosim_local_fit`, `aerosim_rbf_fit`, `aerosim_rbf_eval`, `aerosim_lhs`, `aerosim_repair_step`, `aerosim_eps_level`, `aerosim_eps_worse`, `aerosim_bandit_state_len`, `aerosim_bandit_init`, `aerosim_bandit_pick`, `aerosim_bandit_update`, `aerosim_normative`, `aerosim_lem_box`, `aerosim_box_sample`, `aerosim_sens_tolerance`, `aerosim_morris_design`, `aerosim_morris_effects`
- `core/src/tests.zig` — Todos os testes do núcleo, por grupo. `zig build test` roda tudo; `-Dgrupo=math` roda só um grupo e
- `core/src/types.zig` — Estruturas trocadas com o Python (C ABI, `extern struct`).
  tipos `Surface:29`, `PropUnit:64`, `Gear:108`, `Tank:124`, `Segment:140`, `Event:162`, `Pad:166`, `Payload:175`, `Environment:186`, `Takeoff:198`, `Pilot:216`, `Autopilot:226`, `AeroTable:275`, `LltCache:308`, `Params:322`, `PanelState:401`, `SweepSummary:421`, `Events:429`, `LogRow:471`, `AeroCoeffs:585`, `PropPoint:600`, `MassProps:612`, `TrimPoint:624`, `PerfRow:641`

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
  tipos `Curve:79`, `Node:265`
  fn `sectionSlope:67`, `sectionLift:83`, `stallAngle:116`, `segment:128`, `horseshoe:145`, `surfaceNodes:176`, `prepare:347`, `apply:464`, `compute:604`, `coeffs:636`
- `core/src/loads/sweep.zig` — Varredura das asas em α (subaba Asas da Aerodinâmica): só as superfícies escolhidas, sem trimar, sem fuselagem e
  tipos `Method:27`, `Output:33`, `Summary:84`
  fn `sweep:49`, `summarize:93`, `isaTemperature:135`, `airViscosity:141`, `reynolds:150`

**core/src/math/**

- `core/src/math/fmath.zig` — Funções matemáticas: tabelas (LUT) + aproximações polinomiais, e a referência da std.
  tipos `SinCos:39`, `lut:83`, `ref:180`, `minimax:238`
  fn `optOn:22`, `mulAdd:31`, `SinLut:42`, `sincos:283`, `sin:287`, `cos:291`, `tan:295`, `atan:300`, `atan2:304`, `asin:308`, `acos:313`, `exp:318`, `log:322`, `pow:327`, `tanh:332`, `sqrt:336`, `hypot:340`, `sat:346`, `lim:350`, `sgn:354`, `wrap:358`
- `core/src/math/fmath_test.zig` — Testes só das LUTs e aproximações (independentes de -Dfast_math: comparam `lut` com `ref`).
- `core/src/math/linalg.zig` — Álgebra linear densa de tamanho fixo: fatoração LU com pivoteamento parcial e de Cholesky, e as
  fn `luFactor:14`, `luSolve:39`, `cholesky:58`, `cholSolve:76`, `symEigen:93`, `solve:139`
- `core/src/math/poly.zig` — Polinômio em duas variáveis de grau N gerado em comptime, na ordem dos ajustes do MATLAB
  fn `Poly2:11`
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
- `core/src/physics/section.zig` — Polar 2D de um perfil e os números que saem dela, a etapa Perfis do dimensionamento.
  tipos `Airfoil:21`, `Polar:30`, `Metrics:92`, `DragBranch:211`
  fn `stallAngle:45`, `modelPolar:58`, `interpolate:73`, `metrics:114`, `reynolds:206`, `dragBranch:232`, `fitted:263`
- `core/src/physics/terrain.zig` — Terreno: chão plano (h = 0) com mesas/plataformas retangulares elevadas.
  fn `height:9`

**core/src/sim/**

- `core/src/sim/dynamics.zig` — Equação mestre f(t, x) (`derivatives`) e integração RK4.
  tipos `Out:26`
  fn `derivatives:87`, `rk4:248`
- `core/src/sim/envelope.zig` — Envelope de voo por altitude (sem integrar no tempo).
  tipos `EnvCfg:36`, `EnvRow:74`
  fn `density:87`, `compute:300`, `curve:333`
- `core/src/sim/gust.zig` — Resposta no tempo a uma rajada, em voo nivelado reto: o avião sai equilibrado em `airspeed` e `height`, a rajada
  tipos `Case:18`
  fn `begin:34`, `advance:96`, `settled:119`, `respond:146`
- `core/src/sim/linear.zig` — Modelo linear em torno do voo nivelado equilibrado (estabilidade dinâmica).
  tipos `LinModel:28`, `LinSloshModel:230`
  fn `rigid:56`, `linearize:169`, `linearizeSlosh:290`, `residual:331`
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
- `core/src/sizing/wing_line.zig` — A etapa Asa do dimensionamento: do perfil escolhido à asa trapezoidal, pela linha sustentadora de Prandtl
  tipos `Trapezoid:37`, `Partition:52`, `SectionAirfoil:62`, `Conditions:68`, `Station:88`, `Planform:94`, `Result:274`
  fn `isaDensity:77`, `reynolds:83`, `planformOf:180`, `planformOfPartitions:201`, `totals:230`, `partitionsFromTrapezoid:243`, `analyze:426`, `analyzePlanform:434`, `modelSection:534`

**core/src/util/**

- `core/src/util/fuzz.zig` — Fuzzing dos módulos.
  tipos `Src:15`
  fn `check:60`, `checkScaled:69`


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
- `aerodrive/src/sim/mission.zig` — Percurso -> segmentos, eventos e mesas/plataformas do núcleo (`aerosim/model/mission.py` e
  fn `autoRadius:13`, `segments:20`, `events:76`, `pads:92`
- `aerodrive/src/sim/params.zig` — Avião (arquivo da GUI) -> parâmetros do núcleo (`types.Params`), em Zig.
  tipos `Info:28`, `DryMass:340`
  fn `area:43`, `span:53`, `mac:57`, `macLeadingEdge:72`, `references:93`, `dryMass:367`, `fill:437`, `setup:585`, `staticCharacteristics:615`
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
  tipos `Triangle:14`, `Mesh:22`, `Assembly:90`, `Balance:105`
  fn `buildMesh:55`, `balance:113`, `loadAircraft:131`, `load:144`, `fillAirfoilFiles:161`, `parseDat:196`, `findExample:228`
- `aerosim/gui/main.zig` — A interface do aerosim em Zig (raylib e raygui), com as contas no núcleo.
- `aerosim/gui/page.zig` — Uma subaba da janela, desenhada a partir do que o Python descreve (`python_bridge.zig`): a tela não conhece
  tipos `Kind:35`, `Page:227`
- `aerosim/gui/python_bridge.zig` — A ponte com os managers em Python (`aerosim/bridge.py`): a tela abre `python -m aerosim.bridge` como processo
  tipos `Waiter:23`, `Bridge:39`
- `aerosim/gui/screen.zig` — A tela do aerosim: o cabeçalho, as abas das áreas e as subabas de cada uma, na mesma arrumação da GUI PyQt
  tipos `Screen:59`
- `aerosim/gui/tests.zig` — Os testes sem janela da interface do aerosim: escalas dos gráficos, exportar e a leitura do avião da Montagem.

**aerosim/gui/ui/**

- `aerosim/gui/ui/app.zig` — O que os dois programas têm igual em volta da tela: a linha de comando, a janela e o laço de desenho, com o
  tipos `Args:14`
  fn `parseArgs:25`, `run:57`, `runBrowser:138`, `openFromPage:167`
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
- `aerosim/gui/ui/menus.zig` — As peças de escolha que as abas repetem: a lista de itens com um selecionado (a lista de candidatos de Perfis,
  tipos `ItemList:12`, `CheckItem:56`, `CheckMenu:65`
  fn `buttonGrid:41`, `checkedText:122`
- `aerosim/gui/ui/native_dialog.zig` — A janela de abrir e de salvar arquivo do próprio sistema (a do GNOME, do KDE, do Windows ou do macOS), no lugar
  tipos `State:11`, `Dialog:13`
- `aerosim/gui/ui/numbers.zig` — Números na tela sem janela (testáveis): o texto curto de um campo e as marcas "redondas" dos eixos.
  tipos `Range:38`
  fn `numberText:5`, `niceStep:21`, `decimalsFor:31`, `significant:88`
- `aerosim/gui/ui/plot.zig` — Gráfico de linhas dentro de um cartão: eixos com marcas redondas, grade fraca, as curvas na paleta do tema
  tipos `Series:20`, `Marker:47`, `Cloud:69`, `Axes:77`, `Frame:87`, `Cell:183`, `ExportKind:260`
  fn `lines:101`, `table:191`, `tableHeight:226`, `overlayActive:365`, `overlay:370`, `drawMarker:573`, `cloud:627`, `ramp:646`, `colorBar:662`, `drawFrame:682`
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
  fn `draw:37`, `drawRotated:48`, `width:58`, `plain:67`
- `aerosim/gui/ui/theme.zig` — O visual da interface, o mesmo do AeroDrive: fundo claro, cantos arredondados, azul nos títulos e pouco texto.
  tipos `Palette:17`, `Fonts:122`, `Logo:166`
  fn `hex:7`, `withAlpha:12`, `plotColor:63`, `spacing:151`, `text:156`, `textWidth:161`
- `aerosim/gui/ui/ui.zig` — As peças comuns das telas do aerosim e do aeroopt em Zig: cores e fontes, formas, widgets, formulário, gráfico
- `aerosim/gui/ui/view3d.zig` — Vista 3D dentro de um cartão, com as mesmas ideias da vista do aerosim em Python (`aerosim/gui/widgets/view3d.py`
  tipos `Kind:17`, `View:100`
  fn `kindColor:20`, `colorByName:35`, `fieldColor:57`, `fraction:75`, `liftColor:80`, `toWorld:85`, `shaded:215`, `triangle:223`, `quad:233`, `segment:250`, `arrow:255`, `floor:267`, `bodyAxes:279`
- `aerosim/gui/ui/widgets.zig` — Os pedaços comuns das telas, no desenho do AeroDrive: o contexto de desenho (fontes, logo, mouse), o cabeçalho
  tipos `Ui:11`, `Splitter:204`, `Status:427`
  fn `paragraph:141`, `paragraphHeight:146`, `caretToEnd:192`, `replaceOnType:238`, `helpMark:263`, `checkBox:272`, `disclosure:287`, `rounded:331`, `roundedLines:336`, `header:341`, `tabBar:362`, `primaryButton:386`, `progressBar:396`, `card:403`, `labeledCard:411`, `statusColor:417`, `tableRow:430`, `format:437`


## Zig · interface do aeroopt (`aeroopt`)

**aeroopt/**

- `aeroopt/build.zig` — Interface do aeroopt em Zig (raylib e raygui). As peças comuns das telas vêm da interface do aerosim
  fn `build:12`
- `aeroopt/main.zig` — A interface do aeroopt em Zig (raylib e raygui), com as peças da interface do aerosim.
- `aeroopt/opt_example.zig` — Dados de exemplo da tela do aeroopt enquanto ela não roda a busca: uma rodada inventada, sempre a mesma (semente
  tipos `Run:16`
  fn `syntheticScore:31`, `generate:38`
- `aeroopt/screen.zig` — A tela do aeroopt: à esquerda o problema (pontuação, variáveis, restrições e configuração, cada um num grupo
  tipos `Screen:45`
- `aeroopt/tests.zig` — Os testes sem janela da interface do aeroopt: a rodada de exemplo.


## Zig · tela inicial do pacote (`launcher`)

**launcher/**

- `launcher/build.zig` — A tela inicial do programa instalado (o menu do site, no PC), em Zig com raylib. Usa as peças comuns das telas
  fn `build:10`
- `launcher/main.zig` — A tela inicial do AircraftSimulation instalado (o mesmo menu do site): escolhe e abre o aerosim, o aeroopt ou
  fn `main:14`
- `launcher/places.zig` — Onde estão os programas e os dados, vistos da tela inicial. No pacote instalado (o .exe do Windows, o
  tipos `Program:8`
  fn `dataRoot:14`, `candidates:27`, `find:36`
- `launcher/screen.zig` — A tela inicial do programa instalado: a mesma do site (`web/index.html`), no estilo de uma BIOS (fundo azul,
  tipos `Screen:37`
- `launcher/tests.zig` — Os testes sem janela da tela inicial: onde estão os programas e os dados.


## Ferramentas (`tools/`)

- `tools/aeroopt.py` — Roda um problema do aeroopt (.opt.json) e mostra o resultado: o melhor ponto, as restrições e a convergência.
- `tools/banco_otimizadores.py` — Banco de comparação dos otimizadores do aeroopt: qual busca acha o melhor avião, com quantos pontos, em que tipo de
- `tools/capturas.py` — Fotos de todas as abas (roda cada simulação com os padrões).
- `tools/codemap.py` — Mapa do código: gera docs/MAP.md a partir do próprio código (nunca editar o MAP.md à mão).
- `tools/load_view.py` — Vista 3D da carga aerodinâmica de um avião num ponto de operação: as superfícies pintadas pela carga alar local
- `tools/metodos_voa.py` — Qual busca da etapa voa (E&C) do aeroopt acha mais rápido um avião que voa? Compara os métodos de FLY_METHODS.
- `tools/modcheck.py` — Roda um avião com os modificadores dele e sem cada um (um de cada vez) e mostra a diferença na decolagem.
- `tools/opt_matrix.py` — Mapa das otimizações em avaliação do núcleo (`-Dopt`): compila cada combinação, mede e compara os resultados
- `tools/package.py` — Monta o programa instalável: a tela inicial (o menu do site), o aerosim, o aeroopt e o AeroDrive numa pasta só,
- `tools/pipeline_bench.py` — Compara as estratégias de paralelismo do processo em etapas do aeroopt: o mesmo lote de configurações roda em série,
- `tools/plot_comparativo.py` — Figuras das abas Aerodinâmica e Estabilidade (PNG), iguais ao que a GUI mostra.
- `tools/probe.py` — Sonda dos modificadores pela linha de comando: chama o módulo do núcleo (core/src/modifiers/) direto, sem
- `tools/rotacao.py` — O comando de arfagem roda o avião na pista? A conta da sprint contra a do núcleo, termo a termo.
- `tools/sementes.py` — A etapa voa (E&C) do aeroopt com sementes, inícios e partidas diferentes: todos caem no mesmo avião?
- `tools/span_load.py` — Carga ao longo das superfícies (asa, EH, EV) num ponto de operação — velocidade, α e rotação dos motores — com e
- `tools/sprint_pasta.py` — Exemplo: converte um projeto da sprint antigo (um .json só) para a pasta nova, um arquivo por asa.
- `tools/sprint_tres_caudas.py` — Exemplo: uma asa só com três opções de superfícies, no formato de pasta (um arquivo por asa).
- `tools/time_profile.py` — Perfil de tempo: onde uma análise gasta o tempo, no Python e no núcleo Zig ao mesmo tempo.
- `tools/web_build.py` — Monta o site do AircraftSimulation em zig-out/site/: a tela inicial (web/index.html) e os três programas em
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

- `tests/aero` — 60 testes em 9 arquivo(s)
- `tests/aeroopt` — 78 testes em 8 arquivo(s)
- `tests/core` — 34 testes em 9 arquivo(s)
- `tests/data` — 12 testes em 4 arquivo(s)
- `tests/design` — 75 testes em 11 arquivo(s)
- `tests/gui` — 23 testes em 1 arquivo(s)
- `tests/manager` — 94 testes em 13 arquivo(s)
- `tests/model` — 51 testes em 9 arquivo(s)
- `tests/parallel` — 8 testes em 1 arquivo(s)
- `tests/stability` — 16 testes em 2 arquivo(s)
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
- `aerosim/manager/native/README.md`
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
- `launcher/README.md`
- `tests/README.md`
- `tools/README.md`
- `tools/aero/README.md`
- `tools/checks/README.md`

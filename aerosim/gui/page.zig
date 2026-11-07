//! Uma subaba da janela, desenhada a partir do que o Python descreve (`python_bridge.zig`): a tela não conhece
//! nenhuma análise nem etapa, como a `SimulationTab` e a `StagePage` da antiga GUI PyQt, das quais esta é a cópia.
//!
//!   análise (`simulation`)   uma `ISimulation` do manager: o formulário sai dos `ParamSpec`, Rodar manda os valores
//!                            e a resposta traz o resumo, o diagnóstico e as curvas
//!   etapa (`stage`)          uma etapa da sprint (`aerosim/manager/stages.py`): o rascunho em formulário, os botões
//!                            da etapa, Guardar e a lista dos guardados; cada mudança refaz a conta, como na GUI PyQt
//!   ainda sem ponte (`todo`) só o lugar da página
//!
//! A tela desenha campos de número, marcador, escolha e texto, gráficos 2D, tabelas, as tabelas que se editam no
//! lugar (as partições da asa) e a peça da etapa em 3D (as malhas vêm prontas do Python, `aerosim.model.geometry`).
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const checks_mod = ui_kit.checks;
const scroll = ui_kit.scroll;
const jobs = ui_kit.jobs;
const menus = ui_kit.menus;
const dialogs = ui_kit.dialogs;
const view3d = ui_kit.view3d;
const table_mod = ui_kit.table;
const numbers_mod = ui_kit.numbers;
const python_bridge = @import("python_bridge.zig");
const assembly = @import("assembly.zig");
const manager = @import("manager");
const design = @import("design");
const aircraft_model = @import("aircraft_model");

const Json = std.json.Value;
const Arena = std.heap.ArenaAllocator;

pub const Kind = enum { simulation, stage, todo };

/// como o valor de um campo vai de volta para o Python
const ValueKind = enum { real, integer, toggle, choice, text, file, list };

/// um campo do Python: a chave e o que a tela precisa para devolver o valor
const Param = struct {
    key: []const u8,
    kind: ValueKind,
    options: []const []const u8 = &.{}, // escolha: o texto de cada opção (o índice fica no campo)
    rebuild: bool = false, // mudar este campo pede os campos de novo (análise)
};

/// um botão de uma etapa: `arg` diz o que se pede antes ("" nada, "text" um texto, "file" um arquivo)
const Action = struct {
    key: []const u8,
    label: [:0]const u8,
    arg: []const u8,
    help: []const u8,
    default: []const u8,
};

/// um gráfico pronto para desenhar
const Chart = struct {
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
    series: []plot.Series,
    x_limits: ?numbers_mod.Range = null, // a escala que o resultado pediu (`_xlim`, `_ylim`)
    y_limits: ?numbers_mod.Range = null,
};

/// uma tabela de texto (massas, dimensões)
const Table = struct {
    title: [:0]const u8,
    headers: []const [:0]const u8,
    rows: []const []const plot.Cell,
    widths: []const f32,
};

const SummaryRow = [2]plot.Cell;

/// uma tabela que se edita no lugar (as partições da asa): as colunas, as células de agora e os botões dela
const Grid = struct {
    name: []const u8,
    title: [:0]const u8,
    help: [:0]const u8,
    note: [:0]const u8,
    columns: []table_mod.Column,
    keys: []const []const u8,
    options: []const []const []const u8, // por coluna, o texto de cada opção (escolha); vazio nas de número
    rows: []const []const table_mod.Cell,
    buttons: []const [:0]const u8,
    operations: []const []const u8, // o que cada botão pede ao Python ("add", "delete", "reset")
};

/// uma peça no 3D: os vértices (x, y, z no corpo) e os triângulos
const Mesh = struct {
    color: rl.Color,
    vertices: []const f32,
    faces: []const u32,
    inside: bool = false, // tanque, líquido ou LAPES: desenha por cima do resto
};

/// a peça da etapa em 3D, como a `AircraftView` da GUI PyQt: as malhas e os marcadores (ponto neutro, CG)
const Scene = struct {
    meshes: []const Mesh,
    low: view3d.Body,
    high: view3d.Body,
    neutral_x: ?f64 = null,
    gravity_center: ?view3d.Body = null,
    focus: ?[2]view3d.Body = null, // a caixa da peça que se está criando (o dispositivo de ponta): a câmera aproxima dela

    fn center(scene: *const Scene) view3d.Body {
        return .{ (scene.low[0] + scene.high[0]) / 2, (scene.low[1] + scene.high[1]) / 2, (scene.low[2] + scene.high[2]) / 2 };
    }

    fn size(scene: *const Scene) f64 {
        return @max(@max(scene.high[0] - scene.low[0], scene.high[1] - scene.low[1]), @max(scene.high[2] - scene.low[2], 0.2));
    }
};

/// um campo da vista de cargas: um valor por face da malha do método
const FieldLayer = struct {
    label: [:0]const u8,
    signed: bool,
    values: []const f32,
    /// o valor em cada vértice: a média das faces que tocam aquele ponto, para pintar em degradê
    at_vertices: []const f32,
};

/// uma camada de setas da vista de cargas (força, sustentação, velocidade induzida...)
const VectorLayer = struct {
    name: [:0]const u8,
    unit: []const u8,
    color: rl.Color,
    origins: []const f32,
    vectors: []const f32,
    largest: f64,
};

/// uma superfície do desenho do avião na vista de cargas, com a face do método mais perto de cada vértice
const SurfaceMesh = struct {
    vertices: []const f32,
    faces: []const u32,
    nearest: []const u32,
};

/// a vista 3D de uma análise de carga, como a `LoadView` da GUI PyQt: a malha do método pintada por um campo, as
/// setas de uma camada e o resto do avião em transparência
const LoadsScene = struct {
    title: [:0]const u8,
    info: [:0]const u8,
    vertices: []const f32,
    triangles: []const u32,
    face: []const u32, // a face de origem de cada triângulo (o valor do campo vem dela)
    fields: []const FieldLayer,
    vectors: []const VectorLayer,
    rest: []const Mesh,
    /// as superfícies do desenho do avião (com espessura) e, para cada vértice, a face do método que dá a cor
    surfaces: []const SurfaceMesh = &.{},
    wind: ?view3d.Body = null,
    wind_label: [:0]const u8 = "",
    low: view3d.Body,
    high: view3d.Body,
    elevation: ?f32 = null,
    azimuth: ?f32 = null,

    fn size(scene: *const LoadsScene) f64 {
        return @max(@max(scene.high[0] - scene.low[0], scene.high[1] - scene.low[1]), @max(scene.high[2] - scene.low[2], 0.2));
    }
};

/// uma linha da trajetória 3D: o trecho de uma etapa, os pontos de um evento ou as silhuetas do avião (pares de
/// pontos), com a cor que o Python pediu
const TrackLine = struct {
    name: [:0]const u8,
    kind: enum { line, points, segments },
    points: []const f32, // leste, norte, altura (já exagerada), em sequência
    color: rl.Color,
    width: f32,
    marker: plot.Marker = .none,
    size: f32 = 14,
    legend: bool = true,
};

/// a trajetória 3D de uma análise de voo (`kind="3d"`, `aerosim/bridge.py`, `_track`), como a `_Plot3D` da GUI PyQt:
/// cada etapa na cor dela, os eventos como pontos, o chão quadriculado e a legenda embaixo
const TrackScene = struct {
    title: [:0]const u8,
    axes: [:0]const u8, // "eixos: ..., altura exagerada ×k"
    lines: []const TrackLine,
    low: [3]f64, // leste, norte, altura
    high: [3]f64,

    /// o maior lado no chão (no mínimo 20 m, como na GUI PyQt)
    fn span(scene: *const TrackScene) f64 {
        return @max(@max(scene.high[0] - scene.low[0], scene.high[1] - scene.low[1]), 20);
    }
};

/// a câmera de cada trajetória e onde a imagem saiu no quadro anterior
const TrackState = struct {
    view: view3d.View = .{ .azimuth = -60, .elevation = 25 }, // a câmera inicial da GUI PyQt
    area: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

/// o que a tela guarda de cada vista de cargas entre os quadros: a câmera, o campo, a camada e a escala escolhidos
const LoadsState = struct {
    view: view3d.View = .{},
    field: usize = 0,
    vector: usize = 0,
    symmetric: bool = false, // escala "simétrica em 0" (senão, "mín–máx")
    area: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, // onde a imagem saiu no quadro anterior
    camera_title: [96]u8 = undefined, // a câmera foi posta para esta vista (a de cima começa de cima)
    camera_len: usize = 0,
};

const max_grids = 4;
const max_loads = 4;
const max_tracks = 2;
const track_view_height: f32 = 520;
const view_height: f32 = 300;
const loads_view_height: f32 = 520;

/// o que a thread faz
const Operation = enum { specs, run, stage };

/// uma rodada de análise em Zig: o avião lido e a rodada do manager
const AnalysisRun = struct {
    loaded: aircraft_model.aircraft.Loaded,
    run: manager.Run,
    // a rodada numa thread (onde há): a conta só manda notas pela caixa, a tela só lê
    thread: ?std.Thread = null,
    outbox: jobs.Mailbox(Note, 64) = .{},
    stop: std.atomic.Value(bool) = .init(false),
    // quem cuida da memória da rodada: a tela (`running`, `finished`) ou, depois do "Parar" de emergência, a própria
    // thread (`abandoned`), que libera tudo quando o passo em que está acabar
    owner: std.atomic.Value(Owner) = .init(.running),

    const Owner = enum(u8) { running, finished, abandoned };

    /// o que a thread da conta conta para a tela
    const Note = struct {
        kind: enum { progress, finished, failed, stopped },
        fraction: f32 = 0,
        text: [96:0]u8 = [_:0]u8{0} ** 96,
    };

    /// a rodada inteira, na thread da conta: avança até acabar, falhar ou a tela pedir para parar
    fn work(job: *AnalysisRun, simulation: *const manager.Simulation) void {
        while (true) {
            if (job.stop.load(.monotonic)) return job.finalNote(.stopped);
            const finished = simulation.advance(&job.run) catch return job.finalNote(.failed);
            if (finished) return job.finalNote(.finished);
            var note: Note = .{ .kind = .progress, .fraction = @floatCast(@min(job.run.progress, 1.0)) };
            const said = std.mem.sliceTo(&job.run.message, 0);
            const length = @min(said.len, note.text.len);
            @memcpy(note.text[0..length], said[0..length]);
            _ = job.outbox.push(note); // cheia: este progresso se perde, o próximo vai
        }
    }

    /// a última nota não se perde: espera a tela abrir espaço. Se a tela já largou a rodada ("Parar"), ninguém lê:
    /// a thread libera a memória dela e sai
    fn finalNote(job: *AnalysisRun, kind: @FieldType(Note, "kind")) void {
        if (job.owner.cmpxchgStrong(.running, .finished, .acq_rel, .acquire) != null) return job.release();
        while (!job.outbox.push(.{ .kind = kind })) std.Thread.yield() catch {};
    }

    /// a memória da rodada (o avião lido, a arena da conta e a própria rodada)
    fn release(job: *AnalysisRun) void {
        job.run.arena.deinit();
        job.loaded.deinit();
        std.heap.page_allocator.destroy(job);
    }

    /// o motivo da falha que a análise deixou (ou um texto geral)
    fn failureText(job: *const AnalysisRun) []const u8 {
        const said = std.mem.sliceTo(&job.run.failure, 0);
        return if (said.len > 0) said else "a análise em Zig parou com erro";
    }
};
const analysis_slice_ns: i96 = 6 * std.time.ns_per_ms; // de conta por quadro: a tela segue a 60 quadros por segundo

/// a pasta dos projetos da sprint (`projetos` dentro da raiz dos projetos), para a janela de arquivo
fn projectsFolder(buffer: []u8) []const u8 {
    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    const memory = fixed.allocator();
    const root = design.stages.projectsRoot(memory) catch return ".";
    const folder = std.fs.path.join(memory, &.{ root, "projetos" }) catch return root;
    std.Io.Dir.cwd().createDirPath(clockIo(), folder) catch {};
    return folder;
}

/// a largura do formulário à esquerda, a mesma em todas as abas; arrastar a divisa muda
var sidebar: widgets.Splitter = .{ .width = 390 };
// as alturas que se arrastam pela borda de baixo (valem para todas as páginas, como a largura da barra lateral)
var view_size: widgets.HeightGrip = .{ .height = view_height };
var chart_size: widgets.HeightGrip = .{ .height = chart_height };
var track_size: widgets.HeightGrip = .{ .height = track_view_height };
var loads_size: widgets.HeightGrip = .{ .height = loads_view_height };
const chart_height: f32 = 360;
const gap: f32 = 12;
const edit_delay_ns: i96 = 350 * std.time.ns_per_ms; // a conta da etapa espera a digitação parar (300 ms na GUI PyQt)

pub const Page = struct {
    kind: Kind = .todo,
    name: []const u8 = "", // a análise ou a etapa no Python
    title: [:0]const u8 = "",
    bridge: *python_bridge.Bridge = undefined,
    analysis: ?*const manager.Simulation = null, // análise em Zig (`manager/manager.zig`): sem Python no caminho
    analysis_run: ?*AnalysisRun = null, // a rodada em Zig que anda em fatias, um pouco a cada quadro
    analysis_specs: ?[]u8 = null, // o pedido de campos em Zig, feito no começo do quadro seguinte (a memória do formulário de agora ainda está na tela)
    process_io: ?std.Io = null, // a `Io` do processo (abre o Python); no navegador não há, e o Python é o da página
    job: jobs.Job = .{},
    waiter: python_bridge.Waiter = .{},
    operation: Operation = .specs,
    loaded: bool = false, // já pediu a página ao Python
    grids_beside: bool = false, // as tabelas editáveis na coluna larga, ao lado do formulário (a janela das condições)
    stale: bool = false, // algo mudou fora (o avião, outra etapa): pede de novo ao aparecer
    // o pedido (a tela escreve antes de começar a thread) e a resposta (a thread escreve)
    request_text: []const u8 = "",
    request_arena: ?*Arena = null,
    reply_arena: ?*Arena = null,
    reply: ?Json = null,
    aircraft_path: [1024]u8 = undefined,
    aircraft_len: usize = 0,
    // o formulário
    spec_arena: ?*Arena = null,
    groups: []form_mod.Group = &.{},
    fields: []form_mod.Field = &.{},
    params: []Param = &.{},
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    skipped: usize = 0, // campos que a tela ainda não desenha
    description: [:0]const u8 = "",
    // a etapa
    keep_label: [:0]const u8 = "",
    kept_title: []const u8 = "", // não vazio: a lista é de escolha (Perfis, Biblioteca), com este título
    kept: []const [:0]const u8 = &.{},
    kept_selected: usize = 0,
    kept_list: menus.ItemList = .{},
    actions: []Action = &.{},
    action_captions: []const [:0]const u8 = &.{},
    requirements: [:0]const u8 = "",
    project: [:0]const u8 = "", // a pasta do projeto da sprint
    project_named: bool = true, // falso: projeto novo sem pasta (pede antes de guardar)
    pending_project: enum { none, create, create_then_keep, open } = .none, // a janela de arquivo é para o projeto
    pending_keep: bool = false, // guardar assim que a pasta do projeto foi criada
    edit_due: ?i96 = null, // quando mandar o que se editou
    edited_while_busy: bool = false, // editou enquanto a conta corria: o formulário da resposta não vale
    opened: [1024]u8 = undefined, // "Mandar para a Montagem": o arquivo que a tela abre
    opened_len: usize = 0,
    go_to: [64]u8 = undefined, // "Usar em Desempenho": a análise que a tela mostra depois de abrir o arquivo
    go_to_len: usize = 0,
    wants_requirements: bool = false, // apertou "Condições e restrições…"
    user_stopped: bool = false, // apertou "Parar" numa conta do Python (a falha que volta é o próprio parar)
    prompt: dialogs.TextPrompt = .{},
    picker: dialogs.FilePicker = .{},
    pending_action: usize = 0,
    pending_file: ?usize = null, // o campo de arquivo que pediu a janela de escolher
    file_chosen: bool = false, // escolheu o arquivo de um campo (conta como edição no próximo quadro)
    // o resultado
    result_arena: ?*Arena = null,
    charts: []Chart = &.{},
    checks: []checks_mod.Check = &.{},
    summary: []SummaryRow = &.{},
    tables: []Table = &.{},
    grids: []const Grid = &.{},
    grid_tables: [max_grids]table_mod.EditTable = [_]table_mod.EditTable{.{}} ** max_grids,
    scene: ?Scene = null,
    view: view3d.View = .{},
    view_whole: bool = false, // "ver tudo": a vista ignora a peça em foco
    last_focus: ?[2]view3d.Body = null, // a peça em foco do quadro anterior (uma nova volta a aproximar)
    loads: []const LoadsScene = &.{},
    loads_states: [max_loads]LoadsState = [_]LoadsState{.{}} ** max_loads,
    tracks: []const TrackScene = &.{},
    track_states: [max_tracks]TrackState = [_]TrackState{.{}} ** max_tracks,
    skipped_charts: usize = 0,
    checks_panel: checks_mod.ChecksPanel = .{},
    side: scroll.ScrollArea = .{},
    page: scroll.ScrollArea = .{},
    seconds: f64 = 0,
    started_at: i96 = 0,
    message: [240:0]u8 = [_:0]u8{0} ** 240,
    run_when_ready: bool = false, // "rodar" da linha de comando (prints): roda assim que os campos chegam
    pending_act: [64]u8 = undefined, // "etapa:<botão>" da linha de comando: aperta o botão da etapa quando ela abrir
    pending_act_len: usize = 0,
    form_history: ui_kit.undo.History = .{}, // os valores do formulário de antes de cada edição (Ctrl+Z da análise)
    form_state: ?[]u8 = null, // os valores de agora, em JSON: o que entra no histórico na próxima edição
    last_form_edit: i96 = 0, // quando foi a última edição (a digitação seguida é um passo só)
    scroll_to: f32 = 0, // rolagem pedida na linha de comando (prints)
    scroll_frames: u8 = 0,

    /// o avião aberto na Montagem (o Python abre o mesmo arquivo antes do próximo pedido); a análise pede os
    /// campos de novo, porque eles dependem do avião
    pub fn setAircraftPath(page: *Page, path: ?[]const u8) void {
        const text = path orelse "";
        const length = @min(text.len, page.aircraft_path.len);
        @memcpy(page.aircraft_path[0..length], text[0..length]);
        page.aircraft_len = length;
        if (page.kind == .simulation) page.stale = true;
    }

    /// uma conta está andando (na thread do Python ou em fatias, em Zig)
    fn working(page: *const Page) bool {
        return page.job.running() or page.analysis_run != null;
    }

    /// a página ainda vai mudar sozinha: uma conta andando ou um "rodar" esperando os campos (os prints esperam)
    pub fn settling(page: *const Page) bool {
        return page.working() or page.run_when_ready;
    }

    /// a página precisa ser pedida de novo na próxima vez que aparecer
    pub fn markStale(page: *Page) void {
        page.stale = true;
    }

    /// o arquivo que a etapa mandou abrir ("Mandar para a Montagem"), uma vez
    pub fn takeOpened(page: *Page) ?[]const u8 {
        if (page.opened_len == 0) return null;
        const length = page.opened_len;
        page.opened_len = 0;
        return page.opened[0..length];
    }

    /// a análise para onde a tela vai depois de abrir o arquivo de `takeOpened` (vazio: a Montagem)
    pub fn goTo(page: *const Page) []const u8 {
        return page.go_to[0..page.go_to_len];
    }

    /// uma janela da página (pergunta, arquivo) está aberta
    pub fn modalOpen(page: *const Page) bool {
        return page.prompt.open or page.picker.open;
    }

    /// manda um botão da etapa pelo nome (abrir um .dat pela linha de comando ou arrastado)
    pub fn act(page: *Page, key: []const u8, arg: []const u8) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        text.writer.print("\"op\": \"stage\", \"name\": {f}, \"do\": \"act\", \"key\": {f}, \"arg\": {f}", .{ std.json.fmt(page.name, .{}), std.json.fmt(key, .{}), std.json.fmt(arg, .{}) }) catch return;
        page.begin(.stage, text.written());
    }

    /// Ctrl+Z: numa etapa, o projeto volta ao de antes do último pedido (a etapa guarda o histórico); numa análise,
    /// o formulário volta aos valores de antes da última edição
    pub fn undo(page: *Page) void {
        page.collect(); // uma resposta que chegou neste quadro entra antes (senão o pedido novo a jogaria fora)
        if (page.kind == .stage) {
            if (page.edit_due != null) { // a digitação ainda não foi mandada: só volta o formulário ao da etapa
                page.edit_due = null;
                if (!page.working()) page.stageRequest("show", "");
                return;
            }
            if (!page.working()) page.stageRequest("undo", "");
            return;
        }
        if (page.kind != .simulation or page.working()) return;
        const previous = page.form_history.pop() orelse return setText(&page.message, "nada para desfazer", .{});
        defer page.form_history.release(previous);
        const rebuild = page.applyValues(previous);
        page.rememberForm();
        setText(&page.message, "desfeito (Ctrl+Z) · {d} passo{s} para trás ainda", .{ page.form_history.count, if (page.form_history.count == 1) "" else "s" });
        if (rebuild) page.askSpecs();
    }

    /// os valores de agora passam a ser o estado do formulário (o que o próximo Ctrl+Z guarda)
    fn rememberForm(page: *Page) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        page.writeValues(&text.writer) catch {
            text.deinit();
            return;
        };
        if (page.form_state) |old| std.heap.page_allocator.free(old);
        page.form_state = text.toOwnedSlice() catch null;
    }

    /// uma edição no formulário da análise: o estado de antes vai para o histórico (a digitação seguida, em menos
    /// de um segundo, é um passo só)
    fn formEdited(page: *Page) void {
        const now = std.Io.Clock.awake.now(clockIo()).nanoseconds;
        if (page.form_state) |before| if (now - page.last_form_edit > std.time.ns_per_s) page.form_history.push(before);
        page.last_form_edit = now;
        page.rememberForm();
    }

    /// põe nos campos os valores de `text` (`{"chave": valor}`, como `writeValues` escreve); verdadeiro se mudou um
    /// campo que refaz o formulário
    fn applyValues(page: *Page, text: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(Json, arena.allocator(), text, .{}) catch return false;
        if (parsed != .object) return false;
        var rebuild = false;
        for (page.params, page.fields) |param, *field| {
            const value = parsed.object.get(param.key) orelse continue;
            const before = snapshot(field);
            switch (param.kind) {
                .real, .integer => field.number = number(value) orelse field.number,
                .toggle => if (value == .bool) {
                    field.checked = value.bool;
                },
                .choice => if (value == .string) for (param.options, 0..) |option, index| {
                    if (std.mem.eql(u8, option, value.string)) field.choice = @intCast(index);
                },
                .text, .file => if (value == .string) field.setText(value.string),
                .list => field.setText(valueText(arena.allocator(), value) catch continue),
            }
            if (param.rebuild and snapshot(field) != before) rebuild = true;
        }
        return rebuild;
    }

    /// "etapa:grade:<tabela>:<operação>" da linha de comando (prints): aperta o botão da tabela (o "+ dispositivo"
    /// de "dispositivos", por exemplo) na última linha
    fn gridCommand(page: *Page, text: []const u8) void {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return;
        for (page.grids, 0..) |grid, g| {
            if (!std.mem.eql(u8, grid.name, text[0..colon])) continue;
            for (grid.operations, 0..) |operation, button| if (std.mem.eql(u8, operation, text[colon + 1 ..])) {
                return page.sendGridEdit(.{ .grid = g, .button = button });
            };
        }
    }

    /// um comando pelo nome (`acao=` da linha de comando): "rodar" roda a análise assim que os campos chegarem
    pub fn command(page: *Page, name: []const u8) void {
        if (std.mem.eql(u8, name, "rodar")) page.run_when_ready = true;
        if (std.mem.startsWith(u8, name, "etapa:")) {
            page.pending_act_len = @min(name.len - 6, page.pending_act.len);
            @memcpy(page.pending_act[0..page.pending_act_len], name[6..][0..page.pending_act_len]);
            page.run_when_ready = true;
        }
    }

    /// desenha a página: a barra lateral à esquerda, o resultado à direita
    pub fn draw(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        page.collect();
        page.answerNativeSpecs();
        page.stepNative();
        if (page.kind == .todo) return page.drawTodo(ui, rect);
        if ((!page.loaded or page.stale) and !page.working()) {
            page.loaded = true;
            page.stale = false;
            if (page.kind == .simulation) page.askSpecs() else page.stageRequest("show", "");
        }
        if (page.kind == .stage) page.sendEdits();
        // a pasta do projeto acabou de ser criada pelo "Guardar": agora guarda
        if (page.pending_keep and page.kind == .stage and !page.working() and page.project_named) {
            page.pending_keep = false;
            page.stageRequest("keep", "");
        }
        if (page.run_when_ready and page.kind == .stage and page.loaded and !page.working() and page.fields.len > 0 and page.pending_act_len > 0) {
            page.run_when_ready = false;
            const key = page.pending_act[0..page.pending_act_len];
            page.pending_act_len = 0;
            if (std.mem.startsWith(u8, key, "grade:")) page.gridCommand(key[6..]) else page.act(key, "");
        }
        if (page.run_when_ready and page.kind == .simulation and !page.working() and page.fields.len > 0) {
            page.run_when_ready = false;
            page.run();
        }
        // a rolagem do print espera o resultado (antes dele a página é curta e a rolagem não chega lá)
        if (page.scroll_to > 0 and !page.run_when_ready and !page.working() and page.charts.len > 0) {
            page.scroll_frames += 1; // um quadro com o resultado desenhado, para a altura da página valer
            if (page.scroll_frames > 2) {
                page.page.offset = page.scroll_to;
                page.scroll_to = 0;
            }
        }
        sidebar.update(ui, rect.x, rect.y, rect.height, 280, rect.width - 360);
        const sidebar_width = sidebar.width;
        page.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
        page.drawResult(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
        sidebar.draw(rect.x, rect.y, rect.height);
    }

    /// as janelas da página por cima da tela inteira
    pub fn drawModal(page: *Page, ui: *widgets.Ui, whole: rl.Rectangle) void {
        if (page.prompt.draw(ui, whole)) |answer| page.act(page.actions[page.pending_action].key, answer);
        if (page.picker.draw(ui, whole)) |path| {
            const for_project = page.pending_project;
            page.pending_project = .none;
            if (for_project != .none) return page.projectChosen(for_project, path);
            if (page.pending_file) |index| {
                page.pending_file = null;
                if (index < page.fields.len) page.fields[index].setText(path);
                page.file_chosen = true;
            } else page.act(page.actions[page.pending_action].key, path);
        }
    }

    // ------------------------------------------------------------------ pedidos

    /// começa um pedido na thread (`fields`: o JSON do pedido sem o id, copiado aqui)
    fn begin(page: *Page, operation: Operation, fields: []const u8) void {
        if (page.job.active) return; // rodando, ou acabou e a resposta ainda não foi recolhida (`collect`)
        const request = newArena() orelse return;
        page.request_text = request.allocator().dupe(u8, fields) catch return;
        dropArena(&page.request_arena);
        page.request_arena = request;
        page.reply_arena = newArena() orelse return;
        page.reply = null;
        page.operation = operation;
        page.edited_while_busy = false;
        page.started_at = std.Io.Clock.awake.now(clockIo()).nanoseconds;
        _ = page.job.start(work, .{page});
    }

    /// roda na thread: abre o Python se preciso, abre o avião da Montagem se mudou, e faz o pedido
    fn work(page: *Page) void {
        const waiter = &page.waiter;
        waiter.memory = page.reply_arena.?.allocator();
        waiter.failure[0] = 0;
        // a etapa que já está em Zig responde aqui, sem o Python
        if (page.operation == .stage and design.stages.find(page.name) != null) {
            page.reply = design.stages.handle(waiter.memory, clockIo(), page.request_text) catch |err| {
                setText(&waiter.failure, "a etapa falhou: {s}", .{@errorName(err)});
                return;
            };
            return;
        }
        const bridge = page.bridge;
        bridge.start(page.process_io) catch |err| {
            setText(&waiter.failure, "não abriu o Python ({s}): rode da pasta do repositório, com as dependências instaladas", .{@errorName(err)});
            return;
        };
        bridge.openAircraft(waiter, page.aircraft_path[0..page.aircraft_len]) catch {
            if (waiter.failure[0] == 0) setText(&waiter.failure, "o Python não abriu o avião", .{});
            return;
        };
        page.reply = bridge.request(waiter, page.request_text) catch |err| {
            if (waiter.failure[0] == 0) setText(&waiter.failure, "a ponte com o Python falhou: {s}", .{@errorName(err)});
            return;
        };
    }

    /// no quadro em que a thread acabou: guarda a resposta no lugar dela
    fn collect(page: *Page) void {
        if (!page.job.finished()) return;
        const elapsed = std.Io.Clock.awake.now(clockIo()).nanoseconds - page.started_at;
        page.seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
        const reply = page.reply orelse {
            dropArena(&page.reply_arena);
            if (page.user_stopped) {
                page.user_stopped = false;
                setText(&page.message, "parado", .{});
            } else page.reportFailure(std.mem.sliceTo(&page.waiter.failure, 0));
            return;
        };
        const arena = page.reply_arena.?;
        page.reply_arena = null;
        switch (page.operation) {
            .specs => page.readSpecs(arena, reply) catch setText(&page.message, "resposta dos campos fora do esperado", .{}),
            .run => {
                dropArena(&page.result_arena);
                page.result_arena = arena;
                page.readOutcome(arena.allocator(), reply) catch setText(&page.message, "resposta da rodada fora do esperado", .{});
                setText(&page.message, "rodou em {d:.1} s", .{page.seconds});
            },
            .stage => page.readStage(arena, reply) catch setText(&page.message, "resposta da etapa fora do esperado", .{}),
        }
    }

    /// pede os campos e os gráficos da análise, com os valores atuais (eles podem mudar o formulário)
    fn askSpecs(page: *Page) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        page.writeRequest(&text.writer, "specs") catch return;
        if (page.analysis != null) return page.queueAnalysisSpecs(text.written());
        page.begin(.specs, text.written());
    }

    /// manda rodar a análise com os valores do formulário
    fn run(page: *Page) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        page.writeRequest(&text.writer, "run") catch return;
        setText(&page.message, "rodando...", .{});
        if (page.analysis) |analysis| if (!page.viaPython(analysis, text.written())) return page.analysisStart(text.written());
        page.begin(.run, text.written());
    }

    // ------------------------------------------------------------------ análises em Zig (sem Python)

    /// a análise em Zig manda esta rodada para o Python (um método de fora do núcleo marcado no formulário)
    fn viaPython(page: *Page, analysis: *const manager.Simulation, request: []const u8) bool {
        _ = page;
        const asks = analysis.python orelse return false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return asks(manager.Values.fromRequest(arena.allocator(), request));
    }

    /// guarda o pedido de campos em Zig para o começo do próximo quadro: responder agora soltaria a memória do
    /// formulário que a tela ainda desenha neste quadro (a dica de um botão, por exemplo)
    fn queueAnalysisSpecs(page: *Page, request: []const u8) void {
        const copy = std.heap.page_allocator.dupe(u8, request) catch return;
        if (page.analysis_specs) |old| std.heap.page_allocator.free(old);
        page.analysis_specs = copy;
    }

    fn answerNativeSpecs(page: *Page) void {
        const request = page.analysis_specs orelse return;
        page.analysis_specs = null;
        defer std.heap.page_allocator.free(request);
        page.analysisSpecs(request);
    }

    /// os campos de uma análise em Zig, na hora (só lê o avião, sem conta)
    fn analysisSpecs(page: *Page, request: []const u8) void {
        const simulation = page.analysis.?;
        const arena = newArena() orelse return;
        const memory = arena.allocator();
        var loaded = page.loadNativeAircraft();
        defer if (loaded) |*plane| plane.deinit();
        var text: std.Io.Writer.Allocating = .init(memory);
        const values = manager.Values.fromRequest(memory, request);
        var owned: ?*Arena = arena;
        if (simulation.edit) |edit| if (manager.GridEdit.fromRequest(memory, request)) |change| {
            edit(if (loaded) |*plane| &plane.ac else null, change) catch setText(&page.message, "a tabela não aceitou a edição", .{});
        };
        simulation.specs(&text.writer, if (loaded) |*plane| &plane.ac else null, values) catch {
            dropArena(&owned);
            return setText(&page.message, "os campos da análise em Zig não saíram", .{});
        };
        const reply = std.json.parseFromSliceLeaky(Json, memory, text.written(), .{}) catch {
            dropArena(&owned);
            return setText(&page.message, "campos da análise em Zig fora do esperado", .{});
        };
        page.readSpecs(arena, reply) catch setText(&page.message, "resposta dos campos fora do esperado", .{});
    }

    /// o avião aberto na Montagem, lido em Zig (nulo: nenhum aberto ou não abriu)
    fn loadNativeAircraft(page: *Page) ?aircraft_model.aircraft.Loaded {
        if (page.aircraft_len == 0) return null;
        var diagnosis: assembly.Diagnosis = .{};
        return assembly.loadAircraft(std.heap.page_allocator, clockIo(), page.aircraft_path[0..page.aircraft_len], &diagnosis) catch {
            setText(&page.message, "{s}", .{diagnosis.text()});
            return null;
        };
    }

    /// começa a rodada em Zig: numa thread, que só conversa com a tela pela caixa de notas (`AnalysisRun.work`); onde
    /// não há threads (o navegador), em fatias a cada quadro (`stepNative`)
    fn analysisStart(page: *Page, request: []const u8) void {
        if (page.working()) return;
        const simulation = page.analysis.?;
        const loaded = page.loadNativeAircraft() orelse empty: {
            // a análise que não precisa do avião aberto (o Mini-MDO procura o avião) roda com um avião vazio
            var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer probe.deinit();
            const standalone = if (simulation.standalone) |check| check(manager.Values.fromRequest(probe.allocator(), request)) else false;
            if (!standalone) {
                if (page.aircraft_len == 0) setText(&page.message, "abra um avião (Montagem) para rodar", .{});
                return;
            }
            break :empty aircraft_model.aircraft.Loaded{ .arena = .init(std.heap.page_allocator), .ac = .{ .name = "sem avião" } };
        };
        const job = std.heap.page_allocator.create(AnalysisRun) catch return;
        job.* = .{ .loaded = loaded, .run = undefined };
        job.run = .{ .arena = .init(std.heap.page_allocator), .aircraft = &job.loaded.ac, .stop = &job.stop };
        page.analysis_run = job;
        page.operation = .run;
        page.started_at = std.Io.Clock.awake.now(clockIo()).nanoseconds;
        page.waiter.progress.store(0, .release);
        page.waiter.progress_text[0] = 0;
        const values = manager.Values.fromRequest(job.run.memory(), request);
        // os avisos da rodada (a linha sustentadora numa asa curta) aparecem por cima da janela; a conta roda igual
        if (manager.alerts.forRun(job.run.memory(), simulation, &job.loaded.ac, values)) |said| {
            for (said) |text| ui_kit.toast.show(text);
        } else |_| {}
        simulation.start(&job.run, values) catch return page.stopAnalysis(job.failureText());
        if (jobs.threads_available) job.thread = std.Thread.spawn(.{}, AnalysisRun.work, .{ job, simulation }) catch null;
    }

    /// lê as notas da thread da conta; devolve verdadeiro quando a rodada acabou bem (o resultado sai em seguida)
    fn readNotes(page: *Page, job: *AnalysisRun) bool {
        while (job.outbox.pop()) |note| switch (note.kind) {
            .progress => {
                page.waiter.progress.store(@intFromFloat(@round(note.fraction * 1000)), .release);
                const length = std.mem.sliceTo(&note.text, 0).len;
                @memcpy(page.waiter.progress_text[0..length], note.text[0..length]);
                page.waiter.progress_text[length] = 0;
            },
            .finished => {
                job.thread.?.join();
                job.thread = null;
                return true;
            },
            .failed, .stopped => {
                job.thread.?.join();
                job.thread = null;
                page.stopAnalysis(if (note.kind == .failed) job.failureText() else "parado");
                return false;
            },
        };
        return false;
    }

    /// uma fatia da rodada em Zig: avança até uns milissegundos de conta e devolve a tela; no fim, mostra o resultado
    fn stepNative(page: *Page) void {
        const job = page.analysis_run orelse return;
        const simulation = page.analysis.?;
        if (job.thread != null) {
            if (!page.readNotes(job)) return;
            return page.showNative(job, simulation);
        }
        const clock_start = std.Io.Clock.awake.now(clockIo()).nanoseconds;
        var finished = false;
        while (!finished) {
            finished = simulation.advance(&job.run) catch return page.stopAnalysis(job.failureText());
            if (std.Io.Clock.awake.now(clockIo()).nanoseconds - clock_start > analysis_slice_ns) break;
        }
        page.waiter.progress.store(@intFromFloat(@round(@min(job.run.progress, 1.0) * 1000)), .release);
        const said = std.mem.sliceTo(&job.run.message, 0);
        const length = @min(said.len, page.waiter.progress_text.len - 1);
        @memcpy(page.waiter.progress_text[0..length], said[0..length]);
        page.waiter.progress_text[length] = 0;
        if (!finished) return;
        page.showNative(job, simulation);
    }

    /// a rodada acabou: o JSON do resultado vira a página
    fn showNative(page: *Page, job: *AnalysisRun, simulation: *const manager.Simulation) void {
        const arena = newArena() orelse return page.stopAnalysis("sem memória");
        var owned: ?*Arena = arena;
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        simulation.result(&job.run, &text.writer) catch {
            dropArena(&owned);
            return page.stopAnalysis("o resultado da análise em Zig não saiu");
        };
        const reply = std.json.parseFromSliceLeaky(Json, arena.allocator(), text.written(), .{}) catch {
            dropArena(&owned);
            return page.stopAnalysis("resultado da análise em Zig fora do esperado");
        };
        const elapsed = std.Io.Clock.awake.now(clockIo()).nanoseconds - page.started_at;
        page.seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
        page.dropNative();
        dropArena(&page.result_arena);
        page.result_arena = arena;
        page.readOutcome(arena.allocator(), reply) catch return setText(&page.message, "resposta da rodada fora do esperado", .{});
        setText(&page.message, "rodou em {d:.1} s", .{page.seconds});
    }

    /// uma falha: fica no rodapé e aparece por cima da janela, como os avisos (o que deu errado salta aos olhos)
    fn reportFailure(page: *Page, why: []const u8) void {
        const text = if (why.len > 0) why else "algo deu errado (sem detalhe)";
        setText(&page.message, "{s}", .{text});
        ui_kit.toast.show(text);
    }

    /// para a rodada em Zig com o motivo
    fn stopAnalysis(page: *Page, why: []const u8) void {
        if (page.analysis_run) |job| if (job.thread) |thread| {
            // o "Parar" de emergência: a conta recebe o pedido (as longas saem no meio) e a tela larga a rodada na
            // hora, sem esperar; a thread libera a memória quando o passo em que está acabar
            job.stop.store(true, .monotonic);
            if (job.owner.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null) {
                thread.detach();
                page.analysis_run = null;
                setText(&page.message, "{s}", .{why});
                return;
            }
            // a thread já tinha acabado: segue o caminho normal
            thread.join();
            job.thread = null;
        };
        if (std.mem.eql(u8, why, "parado")) setText(&page.message, "{s}", .{why}) else page.reportFailure(why);
        page.dropNative();
    }

    fn dropNative(page: *Page) void {
        const job = page.analysis_run orelse return;
        job.release();
        page.analysis_run = null;
    }

    /// um pedido da etapa: "show", "set" (com os valores), "keep", "load" e "delete" (com `extra`: "\"index\": n")
    fn stageRequest(page: *Page, do: []const u8, extra: []const u8) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        const writer = &text.writer;
        writer.print("\"op\": \"stage\", \"name\": {f}, \"do\": \"{s}\"", .{ std.json.fmt(page.name, .{}), do }) catch return;
        if (std.mem.eql(u8, do, "set")) {
            writer.writeAll(", \"values\": ") catch return;
            page.writeValues(writer) catch return;
        }
        if (extra.len > 0) writer.print(", {s}", .{extra}) catch return;
        page.begin(.stage, text.written());
    }

    /// manda o que se editou na etapa quando a digitação para (e a conta anterior acabou)
    fn sendEdits(page: *Page) void {
        const due = page.edit_due orelse return;
        if (page.working() or std.Io.Clock.awake.now(clockIo()).nanoseconds < due) return;
        page.edit_due = null;
        page.stageRequest("set", "");
    }

    /// `"op": ..., "name": ..., "values": {...}`
    fn writeRequest(page: *Page, writer: *std.Io.Writer, operation: []const u8) !void {
        try writer.print("\"op\": \"{s}\", \"name\": {f}, \"values\": ", .{ operation, std.json.fmt(page.name, .{}) });
        try page.writeValues(writer);
    }

    /// os valores do formulário em JSON: `{"chave": valor, ...}`
    fn writeValues(page: *Page, writer: *std.Io.Writer) !void {
        try writer.writeAll("{");
        for (page.params, 0..) |param, k| {
            const field = &page.fields[k];
            if (k > 0) try writer.writeAll(", ");
            try writer.print("{f}: ", .{std.json.fmt(param.key, .{})});
            switch (param.kind) {
                .real => try writer.print("{d}", .{field.number}),
                .integer => try writer.print("{d}", .{@as(i64, @intFromFloat(@round(field.number)))}),
                .toggle => try writer.writeAll(if (field.checked) "true" else "false"),
                .choice => try writer.print("{f}", .{std.json.fmt(if (param.options.len > 0) param.options[@intCast(field.choice)] else "", .{})}),
                .text, .file => try writer.print("{f}", .{std.json.fmt(field.textValue(), .{})}),
                .list => {
                    try writer.writeAll("[");
                    var items = std.mem.tokenizeAny(u8, field.textValue(), ", ;");
                    var first = true;
                    while (items.next()) |item| {
                        const value = std.fmt.parseFloat(f64, item) catch continue;
                        if (!first) try writer.writeAll(", ");
                        try writer.print("{d}", .{value});
                        first = false;
                    }
                    try writer.writeAll("]");
                },
            }
        }
        try writer.writeAll("}");
    }

    // ------------------------------------------------------------------ respostas

    /// monta o formulário com os campos da resposta, guardando o valor dos campos que já existiam (análise)
    fn readSpecs(page: *Page, arena: *Arena, reply: Json) !void {
        const memory = arena.allocator();
        try page.buildForm(memory, reply, true);
        page.grids = try readGrids(memory, reply);
        page.scene = try readScene(memory, reply); // as análises em Zig mandam o avião em 3D junto dos campos
        page.description = try memory.dupeZ(u8, stringField(reply, "description"));
        dropArena(&page.spec_arena);
        page.spec_arena = arena;
        page.rememberForm();
        if (page.charts.len == 0) setText(&page.message, "{d} campos ({d} sem editor nesta tela) · clique em Rodar", .{ page.params.len, page.skipped });
    }

    /// a página inteira da etapa: formulário, guardados, botões e a conta
    fn readStage(page: *Page, arena: *Arena, reply: Json) !void {
        const memory = arena.allocator();
        const keep_form = page.edited_while_busy and page.fields.len > 0;
        if (!keep_form) try page.buildForm(memory, reply, false);
        page.description = try memory.dupeZ(u8, stringField(reply, "help"));
        page.keep_label = try memory.dupeZ(u8, stringField(reply, "keep_label"));
        page.kept_title = try memory.dupe(u8, stringField(reply, "kept_title"));
        page.requirements = try memory.dupeZ(u8, stringField(reply, "requirements"));
        page.project = try memory.dupeZ(u8, stringField(reply, "project"));
        page.project_named = if (reply.object.get("project_named")) |named| named != .bool or named.bool else true;
        var kept: std.ArrayList([:0]const u8) = .empty;
        if (reply.object.get("kept")) |list| for (list.array.items) |item| {
            try kept.append(memory, try memory.dupeZ(u8, if (item == .string) item.string else ""));
        };
        page.kept = kept.items;
        if (page.kept_selected >= page.kept.len) page.kept_selected = if (page.kept.len > 0) page.kept.len - 1 else 0;
        var actions: std.ArrayList(Action) = .empty;
        var captions: std.ArrayList([:0]const u8) = .empty;
        if (reply.object.get("actions")) |list| for (list.array.items) |item| {
            const label = try memory.dupeZ(u8, stringField(item, "label"));
            try actions.append(memory, .{ .key = stringField(item, "key"), .label = label, .arg = stringField(item, "arg"), .help = stringField(item, "help"), .default = stringField(item, "default") });
            try captions.append(memory, label);
        };
        page.actions = actions.items;
        page.action_captions = captions.items;
        page.charts = &.{};
        page.checks = &.{};
        page.summary = &.{};
        page.tables = &.{};
        page.loads = &.{};
        page.tracks = &.{};
        page.grids = try readGrids(memory, reply);
        page.scene = try readScene(memory, reply);
        try page.readOutcome(memory, reply);
        const opened = stringField(reply, "open");
        if (opened.len > 0) {
            const length = @min(opened.len, page.opened.len);
            @memcpy(page.opened[0..length], opened[0..length]);
            page.opened_len = length;
            const target = stringField(reply, "go");
            page.go_to_len = @min(target.len, page.go_to.len);
            @memcpy(page.go_to[0..page.go_to_len], target[0..page.go_to_len]);
        }
        setText(&page.message, "{s}", .{stringField(reply, "message")});
        // os avisos da etapa (a linha sustentadora da asa com AR < 4): por cima da janela quando aparecem
        if (reply.object.get("alerts")) |list| if (list == .array) for (list.array.items) |item| {
            if (item == .string) ui_kit.toast.show(item.string);
        };
        // o formulário antigo (se ficou) ainda aponta para a memória dele: só se solta a que não está em uso
        if (keep_form) {
            dropArena(&page.result_arena);
            page.result_arena = arena;
        } else {
            dropArena(&page.result_arena);
            dropArena(&page.spec_arena);
            page.spec_arena = arena;
        }
    }

    /// o formulário a partir de "params"; `keep`: os campos que já existiam guardam o valor (a análise pede os
    /// campos de novo sem mandar o que se digitou)
    fn buildForm(page: *Page, memory: std.mem.Allocator, reply: Json, keep: bool) !void {
        const items = (reply.object.get("params") orelse return error.BadReply).array.items;
        var groups: std.ArrayList(form_mod.Group) = .empty;
        var fields: std.ArrayList(form_mod.Field) = .empty;
        var params: std.ArrayList(Param) = .empty;
        var skipped: usize = 0;
        for (items) |item| {
            const kind = stringField(item, "kind");
            const value_kind = std.meta.stringToEnum(enum { float, int, bool, choice, str, file, floats }, kind) orelse {
                if (!std.mem.eql(u8, kind, "table")) skipped += 1; // as tabelas vêm à parte, em "grids"
                continue;
            };
            const group_name = if (stringField(item, "group").len > 0) stringField(item, "group") else "Geral";
            var group_index: usize = groups.items.len;
            for (groups.items, 0..) |group, g| if (std.mem.eql(u8, group.title, group_name)) {
                group_index = g;
            };
            if (group_index == groups.items.len) {
                const was_open = page.groupOpen(group_name);
                try groups.append(memory, .{ .title = try memory.dupeZ(u8, group_name), .open = was_open });
            }
            var field: form_mod.Field = .{
                .label = try memory.dupeZ(u8, stringField(item, "label")),
                .unit = try memory.dupeZ(u8, stringField(item, "unit")),
                .help = try memory.dupeZ(u8, stringField(item, "help")),
                .group = group_index,
                .minimum = number(item.object.get("minimum")) orelse -std.math.inf(f64),
                .maximum = number(item.object.get("maximum")) orelse std.math.inf(f64),
                .enabled = if (item.object.get("enabled")) |on| on != .bool or on.bool else true,
            };
            var param: Param = .{ .key = stringField(item, "key"), .kind = .real, .rebuild = flag(item, "rebuild") };
            const default = item.object.get("default") orelse .null;
            switch (value_kind) {
                .float => field.number = number(default) orelse 0,
                .int => {
                    param.kind = .integer;
                    field.number = number(default) orelse 0;
                },
                .bool => {
                    param.kind = .toggle;
                    field.kind = .toggle;
                    field.checked = default == .bool and default.bool;
                },
                .str => {
                    param.kind = .text;
                    field.kind = .text;
                    field.setText(if (default == .string) default.string else "");
                },
                .file => {
                    param.kind = .file;
                    field.kind = .file;
                    field.setText(if (default == .string) default.string else "");
                },
                .floats => { // uma lista de números: "a, b, c" num campo de texto
                    param.kind = .list;
                    field.kind = .text;
                    field.setText(try valueText(memory, default));
                },
                .choice => {
                    param.kind = .choice;
                    field.kind = .choice;
                    const options_json = (item.object.get("choices") orelse return error.BadReply).array.items;
                    const options = try memory.alloc([]const u8, options_json.len);
                    var choices: std.ArrayList(u8) = .empty;
                    for (options_json, 0..) |option, k| {
                        options[k] = if (option == .string) option.string else "";
                        if (k > 0) try choices.append(memory, ';');
                        try appendChoice(memory, &choices, options[k]);
                        if (default == .string and std.mem.eql(u8, default.string, options[k])) field.choice = @intCast(k);
                    }
                    param.options = options;
                    field.choices = try choices.toOwnedSliceSentinel(memory, 0);
                },
            }
            if (keep) page.keepValue(param, &field);
            try fields.append(memory, field);
            try params.append(memory, param);
        }
        const same_shape = fields.items.len == page.fields.len;
        page.groups = groups.items;
        page.fields = fields.items;
        page.params = params.items;
        page.skipped = skipped;
        // o formulário guarda a rolagem e, se os campos são os mesmos, o que se está digitando
        const previous = page.form;
        page.form = .{ .groups = page.groups, .fields = page.fields, .area = previous.area };
        if (same_shape) {
            page.form.editing = previous.editing;
            page.form.edit_text = previous.edit_text;
            page.form.edit_fresh = previous.edit_fresh;
            page.form.edit_start = previous.edit_start;
        }
    }

    /// o grupo `name` estava aberto no formulário anterior (os novos começam abertos)
    fn groupOpen(page: *const Page, name: []const u8) bool {
        for (page.groups) |group| if (std.mem.eql(u8, group.title, name)) return group.open;
        return true;
    }

    /// o valor que o campo `param.key` tinha no formulário anterior, se havia; uma escolha volta pelo texto da
    /// opção, porque a lista de opções pode ter mudado
    fn keepValue(page: *const Page, param: Param, field: *form_mod.Field) void {
        for (page.params, 0..) |old, k| {
            if (!std.mem.eql(u8, old.key, param.key)) continue;
            const previous = page.fields[k];
            if (previous.kind != field.kind) return;
            field.number = previous.number;
            field.checked = previous.checked;
            field.text = previous.text;
            if (field.kind == .choice and old.options.len > 0) {
                const chosen = old.options[@intCast(previous.choice)];
                for (param.options, 0..) |option, index| {
                    if (std.mem.eql(u8, option, chosen)) field.choice = @intCast(index);
                }
            }
            return;
        }
    }

    /// o resumo, o diagnóstico, as tabelas e as curvas de uma resposta
    fn readOutcome(page: *Page, memory: std.mem.Allocator, reply: Json) !void {
        var rows: std.ArrayList(SummaryRow) = .empty;
        if (reply.object.get("summary")) |summary| if (summary == .object) {
            var entries = summary.object.iterator();
            while (entries.next()) |entry| {
                try rows.append(memory, .{ .{ .text = try memory.dupeZ(u8, entry.key_ptr.*) }, .{ .text = try valueText(memory, entry.value_ptr.*) } });
            }
        };
        var found: std.ArrayList(checks_mod.Check) = .empty;
        if (reply.object.get("checks")) |list| for (list.array.items) |item| {
            const status = std.meta.stringToEnum(widgets.Status, stringField(item, "status")) orelse .info;
            try found.append(memory, .{ .status = status, .item = stringField(item, "item"), .value = stringField(item, "value"), .criterion = stringField(item, "criterion"), .why = stringField(item, "why"), .fix = stringField(item, "fix"), .source = stringField(item, "source") });
        };
        var tables: std.ArrayList(Table) = .empty;
        if (reply.object.get("tables")) |list| for (list.array.items) |item| {
            const headers_json = (item.object.get("headers") orelse continue).array.items;
            const headers = try memory.alloc([:0]const u8, headers_json.len);
            for (headers_json, 0..) |header, k| headers[k] = try memory.dupeZ(u8, if (header == .string) header.string else "");
            const rows_json = (item.object.get("rows") orelse continue).array.items;
            const table_rows = try memory.alloc([]const plot.Cell, rows_json.len);
            for (rows_json, 0..) |row, r| {
                const cells = try memory.alloc(plot.Cell, row.array.items.len);
                for (row.array.items, 0..) |cell, c| cells[c] = .{ .text = try valueText(memory, cell) };
                table_rows[r] = cells;
            }
            // cada coluna na proporção do texto mais longo dela (cabeçalho ou célula), com um mínimo
            const widths = try memory.alloc(f32, headers.len);
            var total: f32 = 0;
            for (widths, 0..) |*width, k| {
                var longest = std.unicode.utf8CountCodepoints(headers[k]) catch headers[k].len;
                for (table_rows) |row| if (k < row.len) {
                    longest = @max(longest, std.unicode.utf8CountCodepoints(row[k].text) catch row[k].text.len);
                };
                width.* = @floatFromInt(@max(longest, 6));
                total += width.*;
            }
            for (widths) |*width| width.* /= total;
            try tables.append(memory, .{ .title = try memory.dupeZ(u8, stringField(item, "title")), .headers = headers, .rows = table_rows, .widths = widths });
        };
        var charts: std.ArrayList(Chart) = .empty;
        page.skipped_charts = 0;
        var loads: std.ArrayList(LoadsScene) = .empty;
        var tracks: std.ArrayList(TrackScene) = .empty;
        if (reply.object.get("plots")) |list| for (list.array.items) |item| {
            if (std.mem.eql(u8, stringField(item, "kind"), "loads3d")) {
                if (try readLoads(memory, item)) |scene| try loads.append(memory, scene);
                continue;
            }
            if (std.mem.eql(u8, stringField(item, "kind"), "3d")) {
                if (try readTrack(memory, item)) |scene| try tracks.append(memory, scene);
                continue;
            }
            if (!std.mem.eql(u8, stringField(item, "kind"), "2d")) {
                page.skipped_charts += 1;
                continue;
            }
            const curves = (item.object.get("curves") orelse continue).array.items;
            if (curves.len == 0) continue;
            const series = try memory.alloc(plot.Series, curves.len);
            for (curves, 0..) |curve, k| {
                const xs_json = (curve.object.get("x") orelse return error.BadReply).array.items;
                const ys_json = (curve.object.get("y") orelse return error.BadReply).array.items;
                // um valor que não é número fica NaN: corta a linha ali, como na GUI PyQt, e mantém os índices
                // alinhados com a outra borda da sombra
                const count = @min(xs_json.len, ys_json.len);
                const xs = try memory.alloc(f64, count);
                const ys = try memory.alloc(f64, count);
                for (0..count) |i| {
                    xs[i] = number(xs_json[i]) orelse std.math.nan(f64);
                    ys[i] = number(ys_json[i]) orelse std.math.nan(f64);
                }
                series[k] = .{
                    .name = try memory.dupeZ(u8, stringField(curve, "name")),
                    .xs = xs,
                    .ys = ys,
                    .dashed = flag(curve, "dashed"),
                    .in_legend = curve.object.get("legend") == null or flag(curve, "legend"),
                    .color = hexColor(stringField(curve, "color")),
                    .width = if (curve.object.get("width")) |w| @floatCast(number(w) orelse 2.2) else 2.2,
                    .fill_ys = try numberList(memory, curve.object.get("fill"), count),
                    .fill_xs = try numberList(memory, curve.object.get("fill_x"), count),
                    .strong = flag(curve, "strong"),
                    .marker = plot.Marker.named(stringField(curve, "marker")),
                    .marker_size = if (curve.object.get("size")) |size| @floatCast(number(size) orelse 0) else 0,
                    .marker_line = flag(curve, "line"),
                    .span = flag(curve, "vspan"),
                    .pick = plot.pickGroup(stringField(curve, "pick")),
                    .ids = try numberList(memory, curve.object.get("ids"), count),
                    .shows = if (curve.object.get("shows")) |id| number(id) else null,
                };
            }
            try charts.append(memory, .{ .title = try memory.dupeZ(u8, stringField(item, "title")), .x_label = try memory.dupeZ(u8, stringField(item, "xlabel")), .y_label = try memory.dupeZ(u8, stringField(item, "ylabel")), .series = series, .x_limits = limits(item.object.get("xlim")), .y_limits = limits(item.object.get("ylim")) });
        };
        page.summary = rows.items;
        page.checks = found.items;
        page.tables = tables.items;
        page.charts = charts.items;
        // um resultado novo com escolha ligada (os indivíduos do Mini-MDO): a escolha de antes não vale mais
        for (charts.items) |chart| for (chart.series) |s| if (s.pick != 0) {
            plot.clearPick();
            break;
        };
        page.loads = loads.items;
        page.tracks = tracks.items;
    }

    // ------------------------------------------------------------------ desenho

    fn drawTodo(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const box: rl.Rectangle = .{ .x = rect.x + 40, .y = rect.y + 40, .width = @min(rect.width - 80, 680), .height = 150 };
        const inner = widgets.labeledCard(ui, box, page.title);
        _ = widgets.paragraph(ui.fonts.regular, "esta página ainda não existe nesta tela", inner.x, inner.y + 10, inner.width, 15, theme.colors.label);
    }

    fn drawSidebar(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const footer_height: f32 = if (page.kind == .simulation) 112 else 64;
        const body: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height };
        const busy = page.working();
        // a parte que rola: (etapa) requisitos, título e botões; o formulário; (etapa) guardar e os guardados
        const top = page.side.begin(ui, body);
        var y = top + 6;
        const x = body.x + 12;
        const width = body.width - 24;
        if (page.kind == .stage) y = page.drawStageTop(ui, x, y, width);
        // o Mini-MDO usa as condições, as regras e as restrições do projeto: o mesmo botão das etapas
        if (page.kind == .simulation and std.mem.eql(u8, page.name, "mdo")) {
            if (dialogs.button(ui, .{ .x = x, .y = y, .width = width, .height = 30 }, "Condições e restrições…")) page.wants_requirements = true;
            y += 40;
        }
        var changed = false;
        var before: [128]i32 = undefined;
        for (page.params[0..@min(page.params.len, before.len)], 0..) |param, k| before[k] = if (param.rebuild) snapshot(&page.fields[k]) else 0;
        if (page.fields.len > 0) {
            changed = page.form.drawAt(ui, body.x, y, body.width - 10);
            y += page.form.contentHeight();
        }
        var grid_edit: ?GridEdit = null;
        if (!page.grids_beside) {
            for (page.grids[0..@min(page.grids.len, max_grids)], 0..) |*grid, g| y = page.drawGrid(ui, grid, g, x, y + 4, width, &grid_edit);
        }
        if (page.kind == .stage) y = page.drawKept(ui, x, y + 4, width);
        page.side.end(ui, body, y + 12);
        changed = page.form.drawOpen(ui) or changed;
        if (page.form.file_request) |index| {
            page.form.file_request = null;
            page.pending_file = index;
            page.picker.show(page.fields[index].label, "data", &.{ ".txt", ".csv", ".dat", ".pol", ".json" });
        }
        if (page.file_chosen) {
            page.file_chosen = false;
            changed = true;
        }
        if (!page.grids_beside) {
            for (page.grids[0..@min(page.grids.len, max_grids)], 0..) |grid, g| {
                if (page.grid_tables[g].drawOpen(ui, grid.columns)) |edit| grid_edit = .{ .grid = g, .edit = edit };
            }
        }
        if (grid_edit) |edit| page.sendGridEdit(edit);
        if (changed and page.kind == .simulation) page.formEdited();
        if (changed) {
            if (page.kind == .stage) {
                page.edit_due = std.Io.Clock.awake.now(clockIo()).nanoseconds + edit_delay_ns;
                if (busy) page.edited_while_busy = true;
            } else if (!busy) {
                var rebuild = false;
                for (page.params[0..@min(page.params.len, before.len)], 0..) |param, k| {
                    if (param.rebuild and snapshot(&page.fields[k]) != before[k]) rebuild = true;
                }
                if (rebuild) page.askSpecs();
            }
        }
        // o rodapé: Rodar e o progresso (análise) ou a mensagem (etapa)
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 1 }, theme.colors.line);
        if (page.kind == .simulation) {
            const button: rl.Rectangle = .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 };
            const running = busy and page.operation == .run;
            if (running) {
                if (widgets.primaryButton(ui, button, "Parar", true)) {
                    if (page.analysis_run != null) page.stopAnalysis("parado") else {
                        // a conta no Python: o processo morre na hora (o próximo pedido abre outro)
                        page.user_stopped = true;
                        page.bridge.kill();
                    }
                }
            } else if (widgets.primaryButton(ui, button, "Rodar", page.fields.len > 0 and !busy)) page.run();
            widgets.progressBar(.{ .x = footer.x + 12, .y = footer.y + 56, .width = footer.width - 24, .height = 6 }, if (running) page.waiter.fraction() else 0);
            const status: []const u8 = if (running) std.mem.sliceTo(&page.waiter.progress_text, 0) else std.mem.sliceTo(&page.message, 0);
            _ = widgets.paragraph(ui.fonts.regular, status, footer.x + 12, footer.y + 68, footer.width - 24, 13, theme.colors.muted);
        } else {
            const status: []const u8 = if (busy) "calculando..." else std.mem.sliceTo(&page.message, 0);
            _ = widgets.paragraph(ui.fonts.regular, status, footer.x + 12, footer.y + 10, footer.width - 24, 13, theme.colors.muted);
        }
    }

    /// o topo da etapa: a linha dos requisitos com o botão, o título com a ajuda e os botões da etapa
    fn drawStageTop(page: *Page, ui: *widgets.Ui, x: f32, top: f32, width: f32) f32 {
        var y = top;
        // a janela "Condições e restrições…" é ela mesma: sem a linha dos requisitos nem o botão
        if (std.mem.eql(u8, page.name, "requisitos")) return y + 4;
        // as etapas da biblioteca são do programa, não do projeto: sem a linha do projeto e dos requisitos
        if (page.project.len > 0) {
            y = page.drawProject(ui, x, y, width);
            const bar_height = widgets.paragraphHeight(ui.fonts.regular, page.requirements, width - 12, 12) + 10;
            widgets.rounded(.{ .x = x, .y = y, .width = width, .height = bar_height }, 4, theme.colors.hover);
            _ = widgets.paragraph(ui.fonts.regular, page.requirements, x + 6, y + 5, width - 12, 12, theme.colors.label);
            y += bar_height + 6;
            if (dialogs.button(ui, .{ .x = x, .y = y, .width = width, .height = 30 }, "Condições e restrições…")) page.wants_requirements = true;
            y += 40;
        }
        theme.text(ui.fonts.regular, page.title, x, y, 17, theme.colors.accent);
        if (page.description.len > 0) widgets.helpMark(ui, x + theme.textWidth(ui.fonts.regular, page.title, 17) + 8, y + 2, page.description);
        y += 30;
        if (page.action_captions.len > 0) {
            var used: f32 = 0;
            if (menus.buttonGrid(ui, x, y, width, page.action_captions, if (page.action_captions.len == 1) 1 else 2, &used)) |pressed| page.press(pressed);
            y += used + 4;
        }
        return y;
    }

    /// a linha do projeto no topo da etapa: a pasta (ou o aviso de que ainda não tem) e os botões de criar e abrir
    fn drawProject(page: *Page, ui: *widgets.Ui, x: f32, top: f32, width: f32) f32 {
        var y = top;
        var line: [600]u8 = undefined;
        const caption = if (page.project_named) widgets.format(&line, "Projeto: {s}", .{std.fs.path.basename(page.project)}) else "Projeto novo, ainda sem pasta: nada é gravado até escolher uma (o primeiro Guardar pede)";
        y += widgets.paragraph(ui.fonts.regular, caption, x, y, width, 12, if (page.project_named) theme.colors.label else theme.colors.failure) + 4;
        const half = (width - 8) / 2;
        if (dialogs.button(ui, .{ .x = x, .y = y, .width = half, .height = 28 }, "Novo projeto…")) page.askProject(.create);
        if (dialogs.button(ui, .{ .x = x + half + 8, .y = y, .width = half, .height = 28 }, "Abrir projeto…")) page.askProject(.open);
        return y + 36;
    }

    /// abre a janela de arquivo para criar a pasta de um projeto ou abrir um
    fn askProject(page: *Page, what: @FieldType(Page, "pending_project")) void {
        page.pending_project = what;
        var buffer: [512]u8 = undefined;
        const folder = projectsFolder(&buffer);
        if (what == .open) {
            page.picker.show("Abrir projeto: o sprint.json da pasta (ou um .json antigo)", folder, &.{".json"});
        } else page.picker.showSave("Pasta do novo projeto (o nome é a pasta)", folder, &.{}, "meu_projeto");
    }

    /// a pasta escolhida na janela do projeto
    fn projectChosen(page: *Page, what: @FieldType(Page, "pending_project"), path: []const u8) void {
        if (what == .open) {
            design.stages.openProject(clockIo(), path) catch |err| {
                var text: [160]u8 = undefined;
                return page.reportFailure(widgets.format(&text, "não abriu o projeto ({s})", .{@errorName(err)}));
            };
            return page.stageRequest("show", "");
        }
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        text.writer.print("\"key\": \"new\", \"arg\": {f}", .{std.json.fmt(path, .{})}) catch return;
        page.pending_keep = what == .create_then_keep;
        page.stageRequest("project", text.written());
    }

    /// um botão da etapa: pede o texto ou o arquivo antes, se for o caso
    fn press(page: *Page, index: usize) void {
        const action = page.actions[index];
        page.pending_action = index;
        if (std.mem.eql(u8, action.arg, "text")) {
            page.prompt.show(action.label, action.help, action.default);
        } else if (std.mem.eql(u8, action.arg, "file")) {
            var buffer: [512]u8 = undefined;
            const folder = std.fmt.bufPrint(&buffer, "data/airfoils", .{}) catch ".";
            page.picker.show(action.label, folder, &.{ ".dat", ".txt", ".csv", ".pol" });
        } else page.act(action.key, "");
    }

    /// uma tabela editável numa caixa com título, como o `QGroupBox` das partições na GUI PyQt: a tabela, a nota (os
    /// totais) e os botões; devolve onde a caixa acaba
    fn drawGrid(page: *Page, ui: *widgets.Ui, grid: *const Grid, index: usize, x: f32, top: f32, width: f32, edit: *?GridEdit) f32 {
        var y = top + 8;
        const note_height = if (grid.note.len > 0) widgets.paragraphHeight(ui.fonts.regular, grid.note, width - 16, 13) + 6 else 0;
        const buttons_height: f32 = if (grid.buttons.len > 0) 40 else 4;
        const table = &page.grid_tables[index];
        const box_height = 22 + table.fullHeight(grid.rows.len) + 6 + note_height + buttons_height;
        widgets.roundedLines(.{ .x = x, .y = y, .width = width, .height = box_height }, 5, theme.colors.line);
        const caption_width = theme.textWidth(ui.fonts.regular, grid.title, 14);
        rl.drawRectangleRec(.{ .x = x + 8, .y = y - 8, .width = caption_width + 30, .height = 16 }, theme.colors.panel);
        theme.text(ui.fonts.regular, grid.title, x + 12, y - 8, 14, theme.colors.ink);
        if (grid.help.len > 0) widgets.helpMark(ui, x + 16 + caption_width, y - 8, grid.help);
        y += 16;
        const before = table.selected;
        if (table.draw(ui, x + 6, y, width - 12, grid.columns, grid.rows)) |cell| edit.* = .{ .grid = index, .edit = cell };
        // clicar numa linha da tabela de uma etapa avisa a etapa (a vista 3D aproxima do item dela)
        if (edit.* == null and page.kind == .stage and table.selected != null and !std.meta.eql(before, table.selected)) edit.* = .{ .grid = index, .select = table.selected.? };
        y += table.fullHeight(grid.rows.len) + 6;
        if (grid.note.len > 0) y += widgets.paragraph(ui.fonts.regular, grid.note, x + 8, y, width - 16, 13, theme.colors.ink) + 6;
        if (grid.buttons.len > 0) {
            var used: f32 = 0;
            if (menus.buttonGrid(ui, x + 6, y, width - 12, grid.buttons, grid.buttons.len, &used)) |button| {
                edit.* = .{ .grid = index, .button = button };
            }
        }
        return top + 8 + box_height;
    }

    /// manda a edição de uma tabela (uma célula ou um botão, este na linha selecionada) e refaz a conta
    fn sendGridEdit(page: *Page, change: GridEdit) void {
        if (page.working() or change.grid >= page.grids.len) return;
        const grid = page.grids[change.grid];
        const selected = page.grid_tables[change.grid].selected orelse grid.rows.len -| 1;
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        const writer = &text.writer;
        writer.print("\"grid\": {f}", .{std.json.fmt(grid.name, .{})}) catch return;
        if (change.select) |row| {
            writer.print(", \"edit\": \"select\", \"row\": {d}", .{row}) catch return;
        } else if (change.button) |button| {
            writer.print(", \"edit\": {f}, \"row\": {d}", .{ std.json.fmt(grid.operations[button], .{}), selected }) catch return;
        } else if (change.edit) |cell| {
            writer.print(", \"edit\": \"set\", \"row\": {d}, \"key\": {f}, \"value\": ", .{ cell.row, std.json.fmt(grid.keys[cell.column], .{}) }) catch return;
            switch (cell.value) {
                .number => |value| writer.print("{d}", .{value}) catch return,
                .choice => |choice| {
                    const options = grid.options[cell.column];
                    const chosen = if (choice >= 0 and choice < options.len) options[@intCast(choice)] else "";
                    writer.print("{f}", .{std.json.fmt(chosen, .{})}) catch return;
                },
                .text => |value| writer.print("{f}", .{std.json.fmt(value, .{})}) catch return,
                .check => |on| writer.writeAll(if (on) "true" else "false") catch return,
                else => return,
            }
        } else return;
        if (page.kind == .simulation) page.tableRequest(text.written()) else page.stageRequest("grid", text.written());
    }

    /// uma edição numa tabela do formulário da análise (as etapas da Missão): a ponte guarda as linhas e devolve o
    /// formulário, como o pedido dos campos
    fn tableRequest(page: *Page, extra: []const u8) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        const writer = &text.writer;
        page.writeRequest(writer, "table") catch return;
        writer.print(", {s}", .{extra}) catch return;
        if (page.analysis != null) return page.queueAnalysisSpecs(text.written()); // a análise em Zig guarda as linhas ela mesma
        page.begin(.specs, text.written());
    }

    /// Guardar e a lista dos guardados (na etapa Perfis, a lista é a dos candidatos: clicar seleciona)
    fn drawKept(page: *Page, ui: *widgets.Ui, x: f32, top: f32, width: f32) f32 {
        var y = top;
        const busy = page.working();
        const candidates = page.kept_title.len > 0;
        if (page.keep_label.len > 0) {
            if (widgets.primaryButton(ui, .{ .x = x, .y = y, .width = width, .height = 32 }, page.keep_label, !busy)) {
                // projeto sem pasta: primeiro a pasta, depois guarda
                if (page.project_named) page.stageRequest("keep", "") else page.askProject(.create_then_keep);
            }
            y += 42;
        }
        if (!candidates and page.keep_label.len == 0) return y;
        var title: [64]u8 = undefined;
        theme.text(ui.fonts.regular, widgets.format(&title, "{s} ({d})", .{ if (candidates) page.kept_title else "Guardados", page.kept.len }), x, y, 15, theme.colors.accent);
        y += 24;
        const rows: f32 = @floatFromInt(@max(@min(page.kept.len, 5), 1));
        const list: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = rows * menus.ItemList.line_height + 6 };
        if (page.kept_list.draw(ui, list, page.kept, page.kept_selected)) |picked| {
            page.kept_selected = picked;
            if (candidates and !busy) page.indexRequest("load", picked);
        }
        y += list.height + 8;
        const half = (width - 8) / 2;
        if (!candidates and dialogs.button(ui, .{ .x = x, .y = y, .width = half, .height = 30 }, "Carregar no rascunho") and !busy and page.kept.len > 0) page.indexRequest("load", page.kept_selected);
        if (dialogs.button(ui, .{ .x = if (candidates) x else x + half + 8, .y = y, .width = half, .height = 30 }, if (candidates) "Remover" else "Apagar") and !busy and page.kept.len > 0) page.indexRequest("delete", page.kept_selected);
        return y + 40;
    }

    fn indexRequest(page: *Page, do: []const u8, index: usize) void {
        var extra: [32]u8 = undefined;
        page.stageRequest(do, std.fmt.bufPrint(&extra, "\"index\": {d}", .{index}) catch return);
    }

    fn drawResult(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        // a peça em 3D primeiro, como na `StagePage`; a imagem sai numa textura, feita antes do recorte da coluna
        const width = rect.width - 2 * gap - 10;
        const view_card: rl.Rectangle = .{ .x = rect.x + gap, .y = rect.y + gap - page.page.offset, .width = width, .height = view_size.height };
        const view_area: rl.Rectangle = .{ .x = view_card.x + 1, .y = view_card.y + 28, .width = view_card.width - 2, .height = view_card.height - 29 };
        if (page.scene) |*scene| page.renderScene(ui, scene, view_area);
        for (page.loads[0..@min(page.loads.len, max_loads)], 0..) |*scene, k| renderLoads(ui, scene, &page.loads_states[k]);
        for (page.tracks[0..@min(page.tracks.len, max_tracks)], 0..) |*scene, k| renderTrack(ui, scene, &page.track_states[k]);
        const top = page.page.begin(ui, rect);
        var y = top + gap;
        if (page.scene != null) {
            _ = widgets.card(ui, view_card, if (page.kind == .simulation) "O avião em 3D (arraste para girar, roda para aproximar)" else "A peça em 3D (arraste para girar, roda para aproximar)");
            page.view.blit(ui, view_area);
            // com uma peça em foco (o dispositivo que se está criando): trocar entre ela e o avião inteiro
            if (page.scene.?.focus != null) {
                const button: rl.Rectangle = .{ .x = view_card.x + view_card.width - 168, .y = view_card.y + 3, .width = 160, .height = 22 };
                if (dialogs.button(ui, button, if (page.view_whole) "ver o dispositivo" else "ver tudo")) {
                    page.view_whole = !page.view_whole;
                    page.view.zoom = 1;
                }
            }
            const active = view_size.update(ui, view_card.x, view_card.width, view_card.y + view_card.height + gap / 2, 0, 160, 1400);
            widgets.HeightGrip.draw(view_card.x, view_card.width, view_card.y + view_card.height + gap / 2, active);
            y += view_size.height + gap;
        }
        if (page.kind == .simulation and page.description.len > 0) {
            y += widgets.paragraph(ui.fonts.regular, page.description, rect.x + gap + 4, y, width - 8, 14, theme.colors.label) + gap;
        }
        const beside = page.grids_beside and page.grids.len > 0;
        if (!beside and page.charts.len == 0 and page.summary.len == 0 and page.tables.len == 0 and page.checks.len == 0 and page.scene == null and page.loads.len == 0 and page.tracks.len == 0) {
            const note: []const u8 = if (page.working()) (if (page.analysis != null) "calculando..." else "pedindo ao Python...") else if (page.kind == .simulation) "o resultado aparece aqui depois de Rodar" else std.mem.sliceTo(&page.message, 0);
            _ = widgets.paragraph(ui.fonts.regular, note, rect.x + gap + 4, y + 10, width, 16, theme.colors.muted);
            page.page.end(ui, rect, y + 40);
            return;
        }
        if (page.kind == .stage and page.message[0] != 0) {
            y += widgets.paragraph(ui.fonts.regular, std.mem.sliceTo(&page.message, 0), rect.x + gap + 4, y, width - 8, 14, theme.colors.label) + gap;
        }
        var grid_edit: ?GridEdit = null;
        if (beside) {
            for (page.grids[0..@min(page.grids.len, max_grids)], 0..) |*grid, g| y = page.drawGrid(ui, grid, g, rect.x + gap, y, width, &grid_edit) + gap;
        }
        defer if (beside) {
            for (page.grids[0..@min(page.grids.len, max_grids)], 0..) |grid, g| {
                if (page.grid_tables[g].drawOpen(ui, grid.columns)) |edit| grid_edit = .{ .grid = g, .edit = edit };
            }
            if (grid_edit) |edit| page.sendGridEdit(edit);
        };
        for (page.tables) |table| {
            const height = plot.tableHeight(table.rows.len);
            plot.table(ui, .{ .x = rect.x + gap, .y = y, .width = width, .height = height }, table.title, table.headers, table.rows, table.widths);
            y += height + gap;
        }
        // as trajetórias 3D na largura toda, como a GUI PyQt (vêm primeiro nos `PlotSpec` da Missão)
        for (page.tracks[0..@min(page.tracks.len, max_tracks)], 0..) |*scene, k| {
            y += drawTrack(ui, scene, &page.track_states[k], rect.x + gap, y, width) + gap;
            const active = track_size.update(ui, rect.x + gap, width, y - gap / 2, 0, 200, 1400);
            widgets.HeightGrip.draw(rect.x + gap, width, y - gap / 2, active);
        }
        // as vistas de carga e depois os gráficos, em duas colunas, na ordem dos `PlotSpec` (as vistas vêm primeiro)
        const column_width = (width - gap) / 2;
        var row_height: f32 = 0;
        for (page.loads[0..@min(page.loads.len, max_loads)], 0..) |*scene, k| {
            // uma vista só ocupa a largura toda, como a `LoadView` da GUI PyQt
            const alone = page.loads.len == 1;
            const x = rect.x + gap + @as(f32, @floatFromInt(k % 2)) * (column_width + gap);
            row_height = @max(row_height, drawLoads(ui, scene, &page.loads_states[k], x, y, if (alone) width else column_width));
            if (k % 2 == 1 or k + 1 == page.loads.len) {
                y += row_height + gap;
                row_height = 0;
                const active = loads_size.update(ui, rect.x + gap, width, y - gap / 2, 0, 200, 1400);
                widgets.HeightGrip.draw(rect.x + gap, width, y - gap / 2, active);
            }
        }
        // a borda de baixo de cada fileira de gráficos muda a altura de todos
        const chart_rows = (page.charts.len + 1) / 2;
        var chart_grip: ?usize = null;
        for (0..chart_rows) |row| {
            const edge = y + @as(f32, @floatFromInt(row + 1)) * (chart_size.height + gap) - gap / 2;
            if (chart_size.update(ui, rect.x + gap, width, edge, row, 200, 1400)) chart_grip = row;
        }
        for (page.charts, 0..) |chart, k| {
            const x = rect.x + gap + @as(f32, @floatFromInt(k % 2)) * (column_width + gap);
            const chart_y = y + @as(f32, @floatFromInt(k / 2)) * (chart_size.height + gap);
            plot.lines(ui, .{ .x = x, .y = chart_y, .width = column_width, .height = chart_size.height }, .{ .title = chart.title, .x_label = chart.x_label, .y_label = chart.y_label, .x_limits = chart.x_limits, .y_limits = chart.y_limits }, chart.series);
        }
        for (0..chart_rows) |row| {
            const edge = y + @as(f32, @floatFromInt(row + 1)) * (chart_size.height + gap) - gap / 2;
            widgets.HeightGrip.draw(rect.x + gap, width, edge, chart_grip == row);
        }
        y += @as(f32, @floatFromInt(chart_rows)) * (chart_size.height + gap);
        if (page.skipped_charts > 0) {
            var note: [96]u8 = undefined;
            theme.text(ui.fonts.regular, widgets.format(&note, "{d} vistas 3D sem desenho nesta tela", .{page.skipped_charts}), rect.x + gap + 4, y, 13, theme.colors.muted);
            y += 24;
        }
        if (page.checks.len > 0) {
            const height = checks_mod.ChecksPanel.height(@min(page.checks.len, checks_mod.max_checks));
            page.checks_panel.draw(ui, .{ .x = rect.x + gap, .y = y, .width = width, .height = height }, page.checks);
            y += height + gap;
        }
        if (page.summary.len > 0) {
            var rows: [96][]const plot.Cell = undefined;
            const count = @min(page.summary.len, rows.len);
            for (page.summary[0..count], 0..) |*row, k| rows[k] = row;
            const height = plot.tableHeight(count);
            plot.table(ui, .{ .x = rect.x + gap, .y = y, .width = width, .height = height }, "Resumo", &.{ "item", "valor" }, rows[0..count], &.{ 0.55, 0.45 });
            y += height + gap;
        }
        page.page.end(ui, rect, y);
    }

    /// desenha as malhas na textura da vista, com o chão, os eixos e os marcadores (PN em verde, como a GUI PyQt;
    /// CG em vermelho)
    fn renderScene(page: *Page, ui: *widgets.Ui, scene: *const Scene, area: rl.Rectangle) void {
        page.view.handleInput(ui, area);
        const size = scene.size();
        const middle = scene.center();
        // a peça em foco (um dispositivo novo ou editado): a câmera vai até ela, com o zoom de volta ao inicial
        const focus = if (page.view_whole) null else scene.focus;
        if (!std.meta.eql(scene.focus, page.last_focus)) {
            page.last_focus = scene.focus;
            page.view_whole = false;
            if (scene.focus != null) page.view.zoom = 1;
        }
        const camera_center: view3d.Body = if (focus) |box| .{ (box[0][0] + box[1][0]) / 2, (box[0][1] + box[1][1]) / 2, (box[0][2] + box[1][2]) / 2 } else middle;
        const camera_size = if (focus) |box| @max(3 * @max(@max(box[1][0] - box[0][0], box[1][1] - box[0][1]), box[1][2] - box[0][2]), 0.12) else 0.8 * size;
        if (!page.view.begin(area, camera_center, camera_size)) return;
        defer page.view.end();
        defer if (focus) |box| drawBox(box, view3d.fraction(0.95, 0.45, 0.05));
        view3d.floor(.{ middle[0], middle[1], 0 }, scene.high[2] + 0.05 * size, 1.4 * size, 0.25);
        // os tanques, o líquido e a LAPES por último e sem o teste de profundidade: dentro da fuselagem eles sumiriam,
        // e é onde eles estão que importa na vista
        for ([_]bool{ false, true }) |inside| {
            if (inside) {
                rl.gl.rlDrawRenderBatchActive();
                rl.gl.rlDisableDepthTest();
            }
            for (scene.meshes) |mesh| {
                if (mesh.inside != inside) continue;
                var k: usize = 0;
                while (k + 2 < mesh.faces.len) : (k += 3) {
                    const a = vertex(mesh.vertices, mesh.faces[k]) orelse continue;
                    const b = vertex(mesh.vertices, mesh.faces[k + 1]) orelse continue;
                    const c = vertex(mesh.vertices, mesh.faces[k + 2]) orelse continue;
                    view3d.triangle(a, b, c, view3d.shaded(a, b, c, mesh.color));
                }
            }
            if (inside) {
                rl.gl.rlDrawRenderBatchActive();
                rl.gl.rlEnableDepthTest();
            }
        }
        const low = scene.low[2] - 0.12 * size;
        const high = scene.high[2] + 0.04 * size;
        if (scene.neutral_x) |x| {
            const marker = view3d.fraction(0.1, 0.6, 0.1);
            view3d.segment(.{ x, 0, low }, .{ x, 0, high }, marker);
            page.view.label(.{ x, 0, low }, "PN", marker);
        }
        if (scene.gravity_center) |point| {
            const marker = view3d.fraction(0.9, 0.1, 0.1);
            view3d.segment(.{ point[0], point[1], point[2] - 0.25 }, .{ point[0], point[1], point[2] + 0.25 }, marker);
            view3d.segment(.{ point[0] - 0.03 * size, point[1], point[2] }, .{ point[0] + 0.03 * size, point[1], point[2] }, marker);
            page.view.label(.{ point[0], point[1], point[2] - 0.25 }, "CG", marker);
        }
        view3d.bodyAxes(&page.view, .{ scene.low[0] - 0.25 * size, scene.low[1], scene.high[2] }, 0.1 * size);
    }
};

/// as 12 arestas de uma caixa (low, high), por cima das peças
fn drawBox(box: [2]view3d.Body, color: rl.Color) void {
    rl.gl.rlDrawRenderBatchActive();
    rl.gl.rlDisableDepthTest();
    defer {
        rl.gl.rlDrawRenderBatchActive();
        rl.gl.rlEnableDepthTest();
    }
    const margin = 0.08 * @max(box[1][0] - box[0][0], @max(box[1][1] - box[0][1], box[1][2] - box[0][2]));
    const low: view3d.Body = .{ box[0][0] - margin, box[0][1] - margin, box[0][2] - margin };
    const high: view3d.Body = .{ box[1][0] + margin, box[1][1] + margin, box[1][2] + margin };
    for (0..8) |corner| for (0..3) |axis| {
        if (corner & (@as(usize, 1) << @intCast(axis)) != 0) continue; // cada aresta uma vez, a partir do canto de baixo
        var start: view3d.Body = undefined;
        for (0..3) |i| start[i] = if (corner & (@as(usize, 1) << @intCast(i)) != 0) high[i] else low[i];
        var end = start;
        end[axis] = high[axis];
        view3d.segment(start, end, color);
    };
}

/// a imagem de uma vista de cargas, na textura do tamanho em que ela saiu no quadro anterior: a malha do método com a
/// cor do campo, as setas da camada (a maior com 18 % do tamanho, como na GUI PyQt), o resto do avião em
/// transparência e os eixos
fn renderLoads(ui: *widgets.Ui, scene: *const LoadsScene, state: *LoadsState) void {
    if (state.area.width < 8) return;
    if (!std.mem.eql(u8, state.camera_title[0..state.camera_len], scene.title)) {
        state.camera_len = @min(scene.title.len, state.camera_title.len);
        @memcpy(state.camera_title[0..state.camera_len], scene.title[0..state.camera_len]);
        state.view.elevation = scene.elevation orelse 28;
        state.view.azimuth = scene.azimuth orelse -125;
        state.view.zoom = 1;
    }
    state.view.handleInput(ui, state.area);
    const size = scene.size();
    const middle: view3d.Body = .{ (scene.low[0] + scene.high[0]) / 2, (scene.low[1] + scene.high[1]) / 2, (scene.low[2] + scene.high[2]) / 2 };
    // o pyqtgraph da GUI PyQt mede o campo de visão (60°) na horizontal e o raylib (35°) na vertical; numa vista
    // larga como esta, 1,3 × a extensão enquadra o avião e as setas como na GUI PyQt
    if (!state.view.begin(state.area, middle, 1.3 * size)) return;
    defer state.view.end();
    for (scene.rest) |mesh| {
        var color = mesh.color;
        color.a = 56;
        var k: usize = 0;
        while (k + 2 < mesh.faces.len) : (k += 3) {
            const a = vertex(mesh.vertices, mesh.faces[k]) orelse continue;
            const b = vertex(mesh.vertices, mesh.faces[k + 1]) orelse continue;
            const c = vertex(mesh.vertices, mesh.faces[k + 2]) orelse continue;
            view3d.triangle(a, b, c, color);
        }
    }
    if (scene.fields.len > 0) {
        const field = scene.fields[@min(state.field, scene.fields.len - 1)];
        const range = fieldRange(field.values, state.symmetric);
        // com o desenho do avião, as superfícies com espessura (a cor de cada vértice vem da face mais perto); sem
        // ele (a vista vinda do Python), a malha do método
        for (scene.surfaces) |mesh| {
            var corner: usize = 0;
            while (corner + 2 < mesh.faces.len) : (corner += 3) {
                var points: [3]view3d.Body = undefined;
                var colors: [3]rl.Color = undefined;
                var complete = true;
                for (0..3) |j| {
                    const index = mesh.faces[corner + j];
                    points[j] = vertex(mesh.vertices, index) orelse {
                        complete = false;
                        break;
                    };
                    const source = if (index < mesh.nearest.len) mesh.nearest[index] else 0;
                    const value: f64 = if (source < field.values.len) field.values[source] else std.math.nan(f64);
                    const position = if (std.math.isFinite(value)) (value - range[0]) / (range[1] - range[0]) else 0;
                    colors[j] = view3d.fieldColor(position, state.symmetric);
                }
                if (complete) view3d.litTriangle(points[0], points[1], points[2], colors[0], colors[1], colors[2]);
            }
        }
        var k: usize = 0;
        var t: usize = 0;
        while (scene.surfaces.len == 0 and k + 2 < scene.triangles.len) : ({
            k += 3;
            t += 1;
        }) {
            const a = vertex(scene.vertices, scene.triangles[k]) orelse continue;
            const b = vertex(scene.vertices, scene.triangles[k + 1]) orelse continue;
            const c = vertex(scene.vertices, scene.triangles[k + 2]) orelse continue;
            const source = if (t < scene.face.len) scene.face[t] else 0;
            const flat: f64 = if (source < field.values.len) field.values[source] else std.math.nan(f64);
            // a cor de cada canto vem da média das faces vizinhas (degradê, como a GUI PyQt); sem ela, a da face
            var colors: [3]rl.Color = undefined;
            for (&colors, 0..) |*color, corner| {
                const index = scene.triangles[k + corner];
                const value: f64 = if (index < field.at_vertices.len and std.math.isFinite(field.at_vertices[index])) field.at_vertices[index] else flat;
                const position = if (std.math.isFinite(value)) (value - range[0]) / (range[1] - range[0]) else 0;
                color.* = view3d.fieldColor(position, state.symmetric);
            }
            view3d.gradientTriangle(a, b, c, colors[0], colors[1], colors[2]);
        }
    }
    if (state.vector < scene.vectors.len) {
        const layer = scene.vectors[state.vector];
        if (layer.largest > 1e-12) {
            const factor = 0.18 * size / layer.largest;
            var k: usize = 0;
            while (k + 2 < layer.origins.len and k + 2 < layer.vectors.len) : (k += 3) {
                const origin: view3d.Body = .{ layer.origins[k], layer.origins[k + 1], layer.origins[k + 2] };
                const arrow: view3d.Body = .{ layer.vectors[k] * factor, layer.vectors[k + 1] * factor, layer.vectors[k + 2] * factor };
                view3d.arrow(origin, arrow, 0.022 * size, layer.color);
            }
        }
    }
    if (scene.wind) |direction| {
        // a seta do vento relativo à frente e acima do avião, chegando na ponta (como a GUI PyQt)
        const length = 0.3 * size;
        const tip: view3d.Body = .{ scene.high[0] + 0.12 * size, 0, scene.low[2] - 0.12 * size };
        const start: view3d.Body = .{ tip[0] - length * direction[0], tip[1] - length * direction[1], tip[2] - length * direction[2] };
        const color = view3d.fraction(0.30, 0.30, 0.34);
        view3d.arrow(start, .{ length * direction[0], length * direction[1], length * direction[2] }, 0.05 * size, color);
        state.view.label(.{ start[0], start[1], start[2] - 0.04 * size }, scene.wind_label, color);
    }
    view3d.bodyAxes(&state.view, .{ scene.low[0] - 0.12 * size, scene.low[1] - 0.12 * size, scene.high[2] + 0.04 * size }, 0.14 * size);
}

/// o ponto `index` da trajetória no corpo da vista: (leste, norte, altura) do chão com a altura para cima vira
/// (leste, −norte, −altura), a mesma troca da câmera da GUI PyQt para o corpo; nulo se não é número
fn trackPoint(points: []const f32, index: usize) ?view3d.Body {
    const start = index * 3;
    if (start + 2 >= points.len) return null;
    const east = points[start];
    const north = points[start + 1];
    const height = points[start + 2];
    if (!std.math.isFinite(east) or !std.math.isFinite(north) or !std.math.isFinite(height)) return null;
    return .{ east, -north, -height };
}

/// a imagem da trajetória (só o chão quadriculado: as linhas e os pontos saem por cima em `drawTrack`, com a
/// espessura pedida), na textura do tamanho em que ela saiu no quadro anterior
fn renderTrack(ui: *widgets.Ui, scene: *const TrackScene, state: *TrackState) void {
    if (state.area.width < 8) return;
    state.view.handleInput(ui, state.area);
    const span = scene.span();
    const middle: view3d.Body = .{ (scene.low[0] + scene.high[0]) / 2, -(scene.low[1] + scene.high[1]) / 2, -(scene.low[2] + scene.high[2]) / 2 };
    // a distância da GUI PyQt (1,5 × o lado, no campo de 60° do pyqtgraph) no campo de 35° daqui
    if (!state.view.begin(state.area, middle, 1.4 * span)) return;
    defer state.view.end();
    // o passo da grade da GUI PyQt: um décimo do lado, arredondado na dezena, no mínimo 5 m
    const step = @max(5.0, @round(span / 100) * 10);
    view3d.floor(.{ middle[0], middle[1], 0 }, 0, 1.3 * span, step);
}

/// o cartão da trajetória: a imagem, as linhas e os pontos por cima, a legenda com a cor de cada etapa e os eixos;
/// devolve a altura
fn drawTrack(ui: *widgets.Ui, scene: *const TrackScene, state: *TrackState, x: f32, y: f32, width: f32) f32 {
    const legend_height = trackLegend(ui, scene, x + 12, 0, width - 24, false);
    const height = 28 + track_size.height + 8 + legend_height + 22;
    const inner = widgets.card(ui, .{ .x = x, .y = y, .width = width, .height = height }, scene.title);
    state.area = .{ .x = inner.x, .y = y + 28, .width = inner.width, .height = track_size.height };
    state.view.blit(ui, state.area);
    // as linhas antes dos pontos, para os eventos ficarem por cima
    for ([_]bool{ false, true }) |points_pass| for (scene.lines) |line| {
        if ((line.kind == .points) != points_pass) continue;
        const count = line.points.len / 3;
        switch (line.kind) {
            .line => {
                var k: usize = 0;
                while (k + 1 < count) : (k += 1) trackSegment(state, line.points, k, k + 1, line.width, line.color);
            },
            .segments => {
                var k: usize = 0;
                while (k + 1 < count) : (k += 2) trackSegment(state, line.points, k, k + 1, line.width, line.color);
            },
            .points => for (0..count) |k| {
                const at = state.view.project(trackPoint(line.points, k) orelse continue, state.area) orelse continue;
                if (at.x < state.area.x or at.y < state.area.y or at.x > state.area.x + state.area.width or at.y > state.area.y + state.area.height) continue;
                plot.drawMarker(line.marker, at, line.size, line.color);
            },
        }
    };
    const legend_y = y + 28 + track_size.height + 8;
    _ = trackLegend(ui, scene, x + 12, legend_y, width - 24, true);
    theme.text(ui.fonts.regular, scene.axes, x + 12, legend_y + legend_height + 2, 12, theme.colors.muted);
    return height;
}

/// um trecho da trajetória entre os pontos `first` e `second`, cortado na borda da imagem
fn trackSegment(state: *const TrackState, points: []const f32, first: usize, second: usize, width: f32, color: rl.Color) void {
    const a = state.view.project(trackPoint(points, first) orelse return, state.area) orelse return;
    const b = state.view.project(trackPoint(points, second) orelse return, state.area) orelse return;
    const inside = clipSegment(a, b, state.area) orelse return;
    rl.drawLineEx(inside[0], inside[1], width, color);
}

/// o pedaço do segmento `a`–`b` que fica dentro de `rect` (Liang e Barsky); nulo se fica todo fora
fn clipSegment(a: rl.Vector2, b: rl.Vector2, rect: rl.Rectangle) ?[2]rl.Vector2 {
    const delta_x = b.x - a.x;
    const delta_y = b.y - a.y;
    var enter: f32 = 0;
    var leave: f32 = 1;
    const sides = [_][2]f32{
        .{ -delta_x, a.x - rect.x },
        .{ delta_x, rect.x + rect.width - a.x },
        .{ -delta_y, a.y - rect.y },
        .{ delta_y, rect.y + rect.height - a.y },
    };
    for (sides) |side| {
        if (side[0] == 0) {
            if (side[1] < 0) return null;
            continue;
        }
        const at = side[1] / side[0];
        if (side[0] < 0) enter = @max(enter, at) else leave = @min(leave, at);
        if (enter > leave) return null;
    }
    return .{ .{ .x = a.x + enter * delta_x, .y = a.y + enter * delta_y }, .{ .x = a.x + leave * delta_x, .y = a.y + leave * delta_y } };
}

/// a legenda da trajetória em linhas corridas (um traço ou o símbolo e o nome); com `draw` falso só mede; devolve a
/// altura
fn trackLegend(ui: *widgets.Ui, scene: *const TrackScene, x: f32, y: f32, width: f32, draw: bool) f32 {
    const row_height: f32 = 20;
    var column: f32 = 0;
    var row: f32 = 0;
    var any = false;
    for (scene.lines) |line| {
        if (!line.legend) continue;
        const item_width = 26 + theme.textWidth(ui.fonts.regular, line.name, 13) + 16;
        if (column > 0 and column + item_width > width) {
            column = 0;
            row += 1;
        }
        if (draw) {
            const middle_y = y + row * row_height + 9;
            if (line.kind == .points) {
                plot.drawMarker(line.marker, .{ .x = x + column + 11, .y = middle_y }, 11, line.color);
            } else {
                rl.drawLineEx(.{ .x = x + column, .y = middle_y }, .{ .x = x + column + 22, .y = middle_y }, 3, line.color);
            }
            theme.text(ui.fonts.regular, line.name, x + column + 26, middle_y - 8, 13, theme.colors.ink);
        }
        column += item_width;
        any = true;
    }
    return if (any) (row + 1) * row_height else 0;
}

/// a trajetória de um gráfico "3d" (`aerosim/bridge.py`, `_track`)
fn readTrack(memory: std.mem.Allocator, item: Json) !?TrackScene {
    const track = item.object.get("track") orelse return null;
    if (track != .object) return null;
    const list = track.object.get("lines") orelse return null;
    if (list != .array) return null;
    var lines: std.ArrayList(TrackLine) = .empty;
    for (list.array.items) |entry| {
        const kind = stringField(entry, "kind");
        var line: TrackLine = .{
            .name = try memory.dupeZ(u8, stringField(entry, "name")),
            .kind = if (std.mem.eql(u8, kind, "points")) .points else if (std.mem.eql(u8, kind, "segments")) .segments else .line,
            .points = try floats(memory, entry.object.get("points")),
            .color = hexColor(stringField(entry, "color")) orelse theme.colors.ink,
            .width = if (number(entry.object.get("width"))) |value| @floatCast(value) else 2.5,
            .legend = if (entry.object.get("legend")) |value| value != .bool or value.bool else true,
        };
        if (line.kind == .points) {
            line.marker = plot.Marker.named(stringField(entry, "marker"));
            if (number(entry.object.get("size"))) |value| line.size = @floatCast(value);
        }
        try lines.append(memory, line);
    }
    const low = try numberList(memory, track.object.get("low"), 3);
    const high = try numberList(memory, track.object.get("high"), 3);
    if (low.len < 3 or high.len < 3) return null;
    return .{
        .title = try memory.dupeZ(u8, stringField(item, "title")),
        .axes = try memory.dupeZ(u8, stringField(track, "axes")),
        .lines = lines.items,
        .low = .{ low[0], low[1], low[2] },
        .high = .{ high[0], high[1], high[2] },
    };
}

/// o cartão de uma vista de cargas: o título, as escolhas (mapa, setas, escala), a imagem, a legenda e o caso;
/// devolve a altura
fn drawLoads(ui: *widgets.Ui, scene: *const LoadsScene, state: *LoadsState, x: f32, y: f32, width: f32) f32 {
    const info_height = widgets.paragraphHeight(ui.fonts.regular, scene.info, width - 24, 13);
    const height = 28 + 36 + loads_size.height + 46 + info_height + 12;
    const inner = widgets.card(ui, .{ .x = x, .y = y, .width = width, .height = height }, scene.title);
    var row_y = y + 34;
    var buffer: [160]u8 = undefined;
    // as três escolhas da `LoadView` (mapa, setas, escala), cada uma num botão que passa para a próxima
    const button_width = (width - 24 - 16) / 3;
    if (scene.fields.len > 0) {
        const field = scene.fields[@min(state.field, scene.fields.len - 1)];
        cycleButton(ui, .{ .x = x + 12, .y = row_y, .width = button_width, .height = 28 }, "mapa", field.label, &state.field, scene.fields.len);
    }
    var vector_name: [:0]const u8 = "nenhuma";
    if (state.vector < scene.vectors.len) vector_name = scene.vectors[state.vector].name;
    cycleButton(ui, .{ .x = x + 20 + button_width, .y = row_y, .width = button_width, .height = 28 }, "setas", vector_name, &state.vector, scene.vectors.len + 1);
    var scale: usize = @intFromBool(state.symmetric);
    cycleButton(ui, .{ .x = x + 28 + 2 * button_width, .y = row_y, .width = button_width, .height = 28 }, "escala", if (state.symmetric) "simétrica em 0" else "mín–máx", &scale, 2);
    state.symmetric = scale == 1;
    row_y += 36;
    state.area = .{ .x = inner.x, .y = row_y, .width = inner.width, .height = loads_size.height };
    state.view.blit(ui, state.area);
    row_y += loads_size.height + 6;
    // a legenda: a barra de cores com o mínimo e o máximo, e o tamanho da maior seta
    if (scene.fields.len > 0) {
        const field = scene.fields[@min(state.field, scene.fields.len - 1)];
        const range = fieldRange(field.values, state.symmetric);
        const bar: rl.Rectangle = .{ .x = x + 12, .y = row_y + 4, .width = @min(width * 0.45, 420), .height = 12 };
        const steps: usize = 60;
        for (0..steps) |k| {
            const step_width = bar.width / @as(f32, @floatFromInt(steps));
            rl.drawRectangleRec(.{ .x = bar.x + step_width * @as(f32, @floatFromInt(k)), .y = bar.y, .width = step_width + 1, .height = bar.height }, view3d.fieldColor(@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps - 1)), state.symmetric));
        }
        theme.text(ui.fonts.regular, widgets.format(&buffer, "{d:.3}", .{range[0]}), bar.x, bar.y + 15, 12, theme.colors.label);
        const high_text = widgets.format(&buffer, "{d:.3}", .{range[1]});
        theme.text(ui.fonts.regular, high_text, bar.x + bar.width - theme.textWidth(ui.fonts.regular, high_text, 12), bar.y + 15, 12, theme.colors.label);
        theme.text(ui.fonts.regular, field.label, bar.x + bar.width + 14, bar.y - 2, 13, theme.colors.ink);
        if (state.vector < scene.vectors.len) {
            const layer = scene.vectors[state.vector];
            theme.text(ui.fonts.regular, widgets.format(&buffer, "{s}: maior seta = {d:.3} {s}", .{ layer.name, layer.largest, layer.unit }), bar.x + bar.width + 14, bar.y + 15, 12, theme.colors.label);
        }
    }
    row_y += 40;
    _ = widgets.paragraph(ui.fonts.regular, scene.info, x + 12, row_y, width - 24, 13, theme.colors.label);
    return height;
}

/// "rótulo: valor ▸" em `box`: um clique passa para a próxima opção (`count` opções); o texto inteiro fica na dica
fn cycleButton(ui: *widgets.Ui, box: rl.Rectangle, caption: []const u8, value: []const u8, index: *usize, count: usize) void {
    var buffer: [200]u8 = undefined;
    var whole: [200]u8 = undefined;
    ui.tooltip(box, widgets.format(&whole, "{s}: {s}", .{ caption, value }));
    // o valor encurta (com "…") até caber no botão
    var length = value.len;
    var text = widgets.format(&buffer, "{s}: {s} ▸", .{ caption, value });
    while (length > 4 and theme.textWidth(ui.fonts.regular, text, 13) > box.width - 16) {
        length -= 1;
        while (length > 0 and value[length] & 0xC0 == 0x80) length -= 1; // não corta um caractere UTF-8 no meio
        text = widgets.format(&buffer, "{s}: {s}… ▸", .{ caption, value[0..length] });
    }
    if (dialogs.button(ui, box, text) and count > 0) index.* = (index.* + 1) % count;
}

/// o mínimo e o máximo de um campo (só os valores finitos); simétrica: de −máx|v| a +máx|v|
fn fieldRange(values: []const f32, symmetric: bool) [2]f64 {
    var low = std.math.inf(f64);
    var high = -std.math.inf(f64);
    for (values) |value| if (std.math.isFinite(value)) {
        low = @min(low, value);
        high = @max(high, value);
    };
    if (!std.math.isFinite(low)) return .{ 0, 1 };
    if (symmetric) {
        const largest = @max(@abs(low), @abs(high));
        return if (largest > 0) .{ -largest, largest } else .{ -1, 1 };
    }
    return if (high - low < 1e-12) .{ low, low + 1 } else .{ low, high };
}

/// uma lista de números do JSON em f32 (o que não é número vira NaN)
fn floats(memory: std.mem.Allocator, value: ?Json) ![]f32 {
    const list = value orelse return &.{};
    if (list != .array) return &.{};
    const out = try memory.alloc(f32, list.array.items.len);
    for (list.array.items, 0..) |item, k| out[k] = if (number(item)) |found| @floatCast(found) else std.math.nan(f32);
    return out;
}

/// uma lista de índices do JSON
fn indices(memory: std.mem.Allocator, value: ?Json) ![]u32 {
    const list = value orelse return &.{};
    if (list != .array) return &.{};
    const out = try memory.alloc(u32, list.array.items.len);
    for (list.array.items, 0..) |item, k| out[k] = @intFromFloat(@max(number(item) orelse 0, 0));
    return out;
}

/// a vista de cargas de um gráfico "loads3d" (`aerosim/bridge.py`, `_loads`)
fn readLoads(memory: std.mem.Allocator, item: Json) !?LoadsScene {
    const loads = item.object.get("loads") orelse return null;
    if (loads != .object) return null;
    const vertices = try floats(memory, loads.object.get("vertices"));
    var low: view3d.Body = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var high: view3d.Body = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (vertices, 0..) |coordinate, k| {
        low[k % 3] = @min(low[k % 3], coordinate);
        high[k % 3] = @max(high[k % 3], coordinate);
    }
    if (vertices.len < 3) return null;
    var fields: std.ArrayList(FieldLayer) = .empty;
    if (loads.object.get("fields")) |list| for (list.array.items) |field| {
        const values = try floats(memory, field.object.get("values"));
        try fields.append(memory, .{ .label = try memory.dupeZ(u8, stringField(field, "label")), .signed = flag(field, "signed"), .values = values, .at_vertices = &.{} });
    };
    var vectors: std.ArrayList(VectorLayer) = .empty;
    if (loads.object.get("vectors")) |list| for (list.array.items) |layer| {
        const values = try floats(memory, layer.object.get("vectors"));
        var largest: f64 = 0;
        var k: usize = 0;
        while (k + 2 < values.len) : (k += 3) largest = @max(largest, @sqrt(values[k] * values[k] + values[k + 1] * values[k + 1] + values[k + 2] * values[k + 2]));
        const rgba = try floats(memory, layer.object.get("color"));
        const color = if (rgba.len >= 3) view3d.fraction(rgba[0], rgba[1], rgba[2]) else theme.colors.ink;
        try vectors.append(memory, .{ .name = try memory.dupeZ(u8, stringField(layer, "name")), .unit = stringField(layer, "unit"), .color = color, .origins = try floats(memory, layer.object.get("origins")), .vectors = values, .largest = largest });
    };
    var rest: std.ArrayList(Mesh) = .empty;
    if (loads.object.get("rest")) |list| for (list.array.items) |mesh| {
        try rest.append(memory, .{ .color = view3d.colorByName(stringField(mesh, "kind")), .vertices = try floats(memory, mesh.object.get("vertices")), .faces = try indices(memory, mesh.object.get("faces")) });
    };
    var surfaces: std.ArrayList(SurfaceMesh) = .empty;
    if (loads.object.get("surfaces")) |list| if (list == .array) for (list.array.items) |mesh| {
        try surfaces.append(memory, .{ .vertices = try floats(memory, mesh.object.get("vertices")), .faces = try indices(memory, mesh.object.get("faces")), .nearest = try indices(memory, mesh.object.get("nearest")) });
    };
    const triangles = try indices(memory, loads.object.get("triangles"));
    const face = try indices(memory, loads.object.get("face"));
    const same = try samePoints(memory, vertices);
    for (fields.items) |*field| field.at_vertices = try vertexValues(memory, field.values, triangles, face, same);
    var scene: LoadsScene = .{
        .title = try memory.dupeZ(u8, stringField(item, "title")),
        .info = try memory.dupeZ(u8, stringField(loads, "info")),
        .vertices = vertices,
        .triangles = triangles,
        .face = face,
        .fields = fields.items,
        .vectors = vectors.items,
        .rest = rest.items,
        .low = low,
        .high = high,
    };
    scene.surfaces = surfaces.items;
    if (loads.object.get("wind")) |wind| if (wind == .object) {
        const direction = try floats(memory, wind.object.get("direction"));
        if (direction.len >= 3) scene.wind = .{ direction[0], direction[1], direction[2] };
        scene.wind_label = try memory.dupeZ(u8, stringField(wind, "label"));
    };
    if (loads.object.get("camera")) |camera| if (camera == .object) {
        if (number(camera.object.get("elevation"))) |value| scene.elevation = @floatCast(value);
        if (number(camera.object.get("azimuth"))) |value| scene.azimuth = @floatCast(value);
    };
    return scene;
}

/// para cada vértice, o primeiro vértice no mesmo ponto: a malha do método repete os cantos entre faixas vizinhas
fn samePoints(memory: std.mem.Allocator, vertices: []const f32) ![]u32 {
    const count = vertices.len / 3;
    const first = try memory.alloc(u32, count);
    for (0..count) |k| {
        first[k] = @intCast(k);
        for (0..k) |j| {
            if (first[j] != j) continue;
            const distance = @abs(vertices[3 * k] - vertices[3 * j]) + @abs(vertices[3 * k + 1] - vertices[3 * j + 1]) + @abs(vertices[3 * k + 2] - vertices[3 * j + 2]);
            if (distance < 1e-6) {
                first[k] = @intCast(j);
                break;
            }
        }
    }
    return first;
}

/// o valor de um campo em cada vértice: a média dos valores (finitos) das faces dos triângulos que tocam o ponto
fn vertexValues(memory: std.mem.Allocator, values: []const f32, triangles: []const u32, face: []const u32, same: []const u32) ![]f32 {
    const sums = try memory.alloc(f32, same.len);
    const counts = try memory.alloc(u32, same.len);
    defer memory.free(counts);
    @memset(sums, 0);
    @memset(counts, 0);
    for (triangles, 0..) |corner, k| {
        if (corner >= same.len or k / 3 >= face.len or face[k / 3] >= values.len) continue;
        const value = values[face[k / 3]];
        if (!std.math.isFinite(value)) continue;
        sums[same[corner]] += value;
        counts[same[corner]] += 1;
    }
    const averages = try memory.alloc(f32, same.len);
    for (averages, same) |*average, point| {
        average.* = if (counts[point] > 0) sums[point] / @as(f32, @floatFromInt(counts[point])) else std.math.nan(f32);
    }
    memory.free(sums);
    return averages;
}

/// o que se fez numa tabela editável neste quadro: uma célula ou um botão
const GridEdit = struct {
    grid: usize,
    edit: ?table_mod.Edit = null,
    button: ?usize = null,
    select: ?usize = null, // a linha que se clicou (a etapa aproxima a vista dela)
};

/// o vértice `index` de uma lista plana x, y, z
fn vertex(vertices: []const f32, index: u32) ?view3d.Body {
    const start = @as(usize, index) * 3;
    if (start + 2 >= vertices.len) return null;
    return .{ vertices[start], vertices[start + 1], vertices[start + 2] };
}

/// "#rrggbb" → cor; outro texto, nula (fica a da paleta)
fn hexColor(text: []const u8) ?rl.Color {
    if (text.len != 7 or text[0] != '#') return null;
    const value = std.fmt.parseInt(u32, text[1..], 16) catch return null;
    return .{ .r = @intCast(value >> 16), .g = @intCast((value >> 8) & 0xff), .b = @intCast(value & 0xff), .a = 255 };
}

/// uma lista de números do JSON com `count` itens (o que não é número vira NaN); vazia se não veio
fn numberList(memory: std.mem.Allocator, value: ?Json, count: usize) ![]const f64 {
    const list = value orelse return &.{};
    if (list != .array) return &.{};
    const out = try memory.alloc(f64, count);
    for (out, 0..) |*v, i| v.* = if (i < list.array.items.len) number(list.array.items[i]) orelse std.math.nan(f64) else std.math.nan(f64);
    return out;
}

/// [mín, máx] do JSON → faixa do eixo
fn limits(value: ?Json) ?numbers_mod.Range {
    const list = value orelse return null;
    if (list != .array or list.array.items.len < 2) return null;
    const low = number(list.array.items[0]) orelse return null;
    const high = number(list.array.items[1]) orelse return null;
    return if (high > low) .{ .low = low, .high = high } else null;
}

/// o tipo de uma coluna como o Python escreve: "choice", "check", "label" (só leitura), "text" ou número
fn columnKind(name: []const u8) table_mod.Kind {
    if (std.mem.eql(u8, name, "choice")) return .choice;
    if (std.mem.eql(u8, name, "check")) return .check;
    if (std.mem.eql(u8, name, "label")) return .label;
    if (std.mem.eql(u8, name, "text")) return .text;
    return .number;
}

/// as tabelas editáveis de uma resposta da etapa ("grids")
fn readGrids(memory: std.mem.Allocator, reply: Json) ![]const Grid {
    const list = reply.object.get("grids") orelse return &.{};
    if (list != .array) return &.{};
    var grids: std.ArrayList(Grid) = .empty;
    for (list.array.items) |item| {
        const columns_json = (item.object.get("columns") orelse continue).array.items;
        const columns = try memory.alloc(table_mod.Column, columns_json.len);
        const keys = try memory.alloc([]const u8, columns_json.len);
        const options = try memory.alloc([]const []const u8, columns_json.len);
        const choice_texts = try memory.alloc([:0]const u8, columns_json.len);
        // as colunas de número dividem no máximo 60 % da largura, para as de escolha não sumirem numa tabela larga
        var numbers: f32 = 0;
        for (columns_json) |column| {
            if (columnKind(stringField(column, "kind")) == .number) numbers += 1;
        }
        const number_width: f32 = if (numbers > 0) @min(0.13, 0.6 / numbers) else 0.13;
        for (columns_json, 0..) |column, c| {
            const kind = columnKind(stringField(column, "kind"));
            const is_choice = kind == .choice;
            columns[c] = .{ .title = try memory.dupeZ(u8, stringField(column, "label")), .kind = kind, .width = if (kind == .number) number_width else 0, .help = try memory.dupeZ(u8, stringField(column, "help")) };
            keys[c] = stringField(column, "key");
            options[c] = &.{};
            choice_texts[c] = "";
            if (is_choice) {
                const items = (column.object.get("choices") orelse continue).array.items;
                const texts = try memory.alloc([]const u8, items.len);
                var joined: std.ArrayList(u8) = .empty;
                for (items, 0..) |option, k| {
                    texts[k] = if (option == .string) option.string else "";
                    if (k > 0) try joined.append(memory, ';');
                    try appendChoice(memory, &joined, if (texts[k].len > 0) texts[k] else "(o da raiz)");
                }
                options[c] = texts;
                choice_texts[c] = try joined.toOwnedSliceSentinel(memory, 0);
            }
        }
        const rows_json = (item.object.get("rows") orelse continue).array.items;
        const rows = try memory.alloc([]const table_mod.Cell, rows_json.len);
        for (rows_json, 0..) |row, r| {
            const cells = try memory.alloc(table_mod.Cell, columns.len);
            for (cells, 0..) |*cell, c| {
                const value = if (c < row.array.items.len) row.array.items[c] else Json.null;
                cell.* = .{};
                switch (columns[c].kind) {
                    .choice => {
                        cell.choices = choice_texts[c];
                        const chosen = if (value == .string) value.string else "";
                        for (options[c], 0..) |option, k| {
                            if (std.mem.eql(u8, option, chosen)) cell.choice = @intCast(k);
                        }
                    },
                    .check => cell.checked = value == .bool and value.bool,
                    .label, .text => {
                        cell.enabled = value != .null; // sem valor: não vale nesta linha (as opções de uma variável de número)
                        cell.text = try memory.dupeZ(u8, if (value == .string) value.string else "");
                        // a situação de uma restrição que não se cumpre sai em vermelho, como na GUI PyQt
                        if (std.mem.startsWith(u8, cell.text, "✖")) cell.color = theme.colors.failure;
                    },
                    else => if (value == .null) {
                        cell.enabled = false; // não vale nesta linha (o mín. e o máx. de uma variável de lista)
                        cell.blank = true;
                    } else {
                        cell.number = number(value) orelse 0;
                    },
                }
            }
            rows[r] = cells;
        }
        var buttons: std.ArrayList([:0]const u8) = .empty;
        var operations: std.ArrayList([]const u8) = .empty;
        if (item.object.get("buttons")) |button_list| for (button_list.array.items) |button| {
            if (button != .array or button.array.items.len < 2) continue;
            try operations.append(memory, if (button.array.items[0] == .string) button.array.items[0].string else "");
            try buttons.append(memory, try memory.dupeZ(u8, if (button.array.items[1] == .string) button.array.items[1].string else ""));
        };
        try grids.append(memory, .{
            .name = stringField(item, "name"),
            .title = try memory.dupeZ(u8, stringField(item, "title")),
            .help = try memory.dupeZ(u8, stringField(item, "help")),
            .note = try memory.dupeZ(u8, stringField(item, "note")),
            .columns = columns,
            .keys = keys,
            .options = options,
            .rows = rows,
            .buttons = buttons.items,
            .operations = operations.items,
        });
    }
    return grids.items;
}

/// a vista 3D de uma resposta ("view": as malhas e os marcadores)
fn readScene(memory: std.mem.Allocator, reply: Json) !?Scene {
    const view = reply.object.get("view") orelse return null;
    if (view != .object) return null;
    const list = (view.object.get("meshes") orelse return null).array.items;
    const meshes = try memory.alloc(Mesh, list.len);
    var low: view3d.Body = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var high: view3d.Body = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (list, 0..) |item, m| {
        const vertices_json = (item.object.get("vertices") orelse return error.BadReply).array.items;
        const faces_json = (item.object.get("faces") orelse return error.BadReply).array.items;
        const vertices = try memory.alloc(f32, vertices_json.len);
        for (vertices_json, 0..) |value, k| {
            const coordinate = number(value) orelse 0;
            vertices[k] = @floatCast(coordinate);
            low[k % 3] = @min(low[k % 3], coordinate);
            high[k % 3] = @max(high[k % 3], coordinate);
        }
        const faces = try memory.alloc(u32, faces_json.len);
        for (faces_json, 0..) |value, k| faces[k] = @intFromFloat(@max(number(value) orelse 0, 0));
        const kind = stringField(item, "kind");
        const inside = for ([_][]const u8{ "tank", "liquid", "payload" }) |name| {
            if (std.mem.eql(u8, kind, name)) break true;
        } else false;
        meshes[m] = .{ .color = view3d.colorByName(kind), .vertices = vertices, .faces = faces, .inside = inside };
    }
    if (list.len == 0) low = .{ -0.5, -0.5, -0.1 };
    if (list.len == 0) high = .{ 0.5, 0.5, 0.1 };
    var scene: Scene = .{ .meshes = meshes, .low = low, .high = high };
    if (view.object.get("markers")) |markers| if (markers == .object) {
        scene.neutral_x = number(markers.object.get("np_x"));
        if (markers.object.get("cg")) |point| if (point == .array and point.array.items.len == 3) {
            scene.gravity_center = .{ number(point.array.items[0]) orelse 0, number(point.array.items[1]) orelse 0, number(point.array.items[2]) orelse 0 };
        };
        if (markers.object.get("focus")) |box| if (box == .array and box.array.items.len == 6) {
            var corners: [6]f64 = undefined;
            for (&corners, box.array.items) |*corner, item| corner.* = number(item) orelse 0;
            scene.focus = .{ corners[0..3].*, corners[3..6].* };
        };
    };
    return scene;
}

// ---------------------------------------------------------------------- ajudas

/// o relógio (a mesma `Io` dos arquivos serve)
fn clockIo() std.Io {
    return ui_kit.system.io();
}

fn newArena() ?*Arena {
    const arena = std.heap.page_allocator.create(Arena) catch return null;
    arena.* = Arena.init(std.heap.page_allocator);
    return arena;
}

fn dropArena(slot: *?*Arena) void {
    const arena = slot.* orelse return;
    arena.deinit();
    std.heap.page_allocator.destroy(arena);
    slot.* = null;
}

fn setText(buffer: *[240:0]u8, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(buffer[0 .. buffer.len - 1], fmt, args) catch buffer[0 .. buffer.len - 1];
    buffer[written.len] = 0;
}

/// o texto de `key` num objeto JSON ("" se não há)
fn stringField(value: Json, key: []const u8) []const u8 {
    if (value != .object) return "";
    const found = value.object.get(key) orelse return "";
    return if (found == .string) found.string else "";
}

fn flag(value: Json, key: []const u8) bool {
    if (value != .object) return false;
    const found = value.object.get(key) orelse return false;
    return found == .bool and found.bool;
}

fn number(maybe: ?Json) ?f64 {
    const value = maybe orelse return null;
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// uma opção na lista do raygui (separada por ";": um ";" no texto vira ",")
fn appendChoice(memory: std.mem.Allocator, list: *std.ArrayList(u8), option: []const u8) !void {
    for (option) |char| try list.append(memory, if (char == ';') ',' else char);
}

/// o estado de um campo que refaz o formulário (para saber se mudou)
fn snapshot(field: *const form_mod.Field) i32 {
    return switch (field.kind) {
        .toggle => @intFromBool(field.checked),
        .choice => field.choice,
        else => 0,
    };
}

/// um valor em texto: número com 4 algarismos, lista separada por vírgula
fn valueText(memory: std.mem.Allocator, value: Json) ![:0]const u8 {
    return switch (value) {
        .string => |s| memory.dupeZ(u8, s),
        .float => |f| std.fmt.allocPrintSentinel(memory, "{d:.4}", .{f}, 0),
        .integer => |i| std.fmt.allocPrintSentinel(memory, "{d}", .{i}, 0),
        .bool => |b| memory.dupeZ(u8, if (b) "sim" else "não"),
        .array => |list| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (list.items, 0..) |item, k| {
                if (k > 0) try out.appendSlice(memory, ", ");
                try out.appendSlice(memory, try valueText(memory, item));
            }
            break :blk out.toOwnedSliceSentinel(memory, 0);
        },
        else => memory.dupeZ(u8, "—"),
    };
}

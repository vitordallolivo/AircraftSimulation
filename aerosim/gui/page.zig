//! Uma subaba da janela, desenhada a partir do que o Python descreve (`python_bridge.zig`): a tela não conhece
//! nenhuma análise nem etapa, como a `SimulationTab` e a `StagePage` da GUI PyQt, das quais esta é a cópia.
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
};

/// a peça da etapa em 3D, como a `AircraftView` da GUI PyQt: as malhas e os marcadores (ponto neutro, CG)
const Scene = struct {
    meshes: []const Mesh,
    low: view3d.Body,
    high: view3d.Body,
    neutral_x: ?f64 = null,
    gravity_center: ?view3d.Body = null,

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
    low: view3d.Body,
    high: view3d.Body,
    elevation: ?f32 = null,
    azimuth: ?f32 = null,

    fn size(scene: *const LoadsScene) f64 {
        return @max(@max(scene.high[0] - scene.low[0], scene.high[1] - scene.low[1]), @max(scene.high[2] - scene.low[2], 0.2));
    }
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
const view_height: f32 = 300;
const loads_view_height: f32 = 440;

/// o que a thread faz
const Operation = enum { specs, run, stage };

/// a largura do formulário à esquerda, a mesma em todas as abas; arrastar a divisa muda
var sidebar: widgets.Splitter = .{ .width = 390 };
const chart_height: f32 = 360;
const gap: f32 = 12;
const edit_delay_ns: i96 = 350 * std.time.ns_per_ms; // a conta da etapa espera a digitação parar (300 ms na GUI PyQt)

pub const Page = struct {
    kind: Kind = .todo,
    name: []const u8 = "", // a análise ou a etapa no Python
    title: [:0]const u8 = "",
    bridge: *python_bridge.Bridge = undefined,
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
    kept: []const [:0]const u8 = &.{},
    kept_selected: usize = 0,
    kept_list: menus.ItemList = .{},
    actions: []Action = &.{},
    action_captions: []const [:0]const u8 = &.{},
    requirements: [:0]const u8 = "",
    edit_due: ?i96 = null, // quando mandar o que se editou
    edited_while_busy: bool = false, // editou enquanto a conta corria: o formulário da resposta não vale
    opened: [1024]u8 = undefined, // "Mandar para a Montagem": o arquivo que a tela abre
    opened_len: usize = 0,
    go_to: [64]u8 = undefined, // "Usar em Desempenho": a análise que a tela mostra depois de abrir o arquivo
    go_to_len: usize = 0,
    wants_requirements: bool = false, // apertou "Condições e restrições…"
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
    loads: []const LoadsScene = &.{},
    loads_states: [max_loads]LoadsState = [_]LoadsState{.{}} ** max_loads,
    skipped_charts: usize = 0,
    checks_panel: checks_mod.ChecksPanel = .{},
    side: scroll.ScrollArea = .{},
    page: scroll.ScrollArea = .{},
    seconds: f64 = 0,
    started_at: i96 = 0,
    message: [240:0]u8 = [_:0]u8{0} ** 240,
    run_when_ready: bool = false, // "rodar" da linha de comando (prints): roda assim que os campos chegam
    scroll_to: f32 = 0, // rolagem pedida na linha de comando (prints)

    /// o avião aberto na Montagem (o Python abre o mesmo arquivo antes do próximo pedido); a análise pede os
    /// campos de novo, porque eles dependem do avião
    pub fn setAircraftPath(page: *Page, path: ?[]const u8) void {
        const text = path orelse "";
        const length = @min(text.len, page.aircraft_path.len);
        @memcpy(page.aircraft_path[0..length], text[0..length]);
        page.aircraft_len = length;
        if (page.kind == .simulation) page.stale = true;
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

    /// um comando pelo nome (`acao=` da linha de comando): "rodar" roda a análise assim que os campos chegarem
    pub fn command(page: *Page, name: []const u8) void {
        if (std.mem.eql(u8, name, "rodar")) page.run_when_ready = true;
    }

    /// desenha a página: a barra lateral à esquerda, o resultado à direita
    pub fn draw(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        page.collect();
        if (page.kind == .todo) return page.drawTodo(ui, rect);
        if ((!page.loaded or page.stale) and !page.job.running()) {
            page.loaded = true;
            page.stale = false;
            if (page.kind == .simulation) page.askSpecs() else page.stageRequest("show", "");
        }
        if (page.kind == .stage) page.sendEdits();
        if (page.run_when_ready and page.kind == .simulation and !page.job.running() and page.fields.len > 0) {
            page.run_when_ready = false;
            page.run();
        }
        if (page.scroll_to > 0) {
            page.page.offset = page.scroll_to;
            page.scroll_to = 0;
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
        if (page.job.running()) return;
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
            setText(&page.message, "{s}", .{std.mem.sliceTo(&page.waiter.failure, 0)});
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
        page.begin(.specs, text.written());
    }

    /// manda rodar a análise com os valores do formulário
    fn run(page: *Page) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        page.writeRequest(&text.writer, "run") catch return;
        setText(&page.message, "rodando...", .{});
        page.begin(.run, text.written());
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
        if (page.job.running() or std.Io.Clock.awake.now(clockIo()).nanoseconds < due) return;
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
        page.description = try memory.dupeZ(u8, stringField(reply, "description"));
        dropArena(&page.spec_arena);
        page.spec_arena = arena;
        if (page.charts.len == 0) setText(&page.message, "{d} campos ({d} ainda só na GUI PyQt) · clique em Rodar", .{ page.params.len, page.skipped });
    }

    /// a página inteira da etapa: formulário, guardados, botões e a conta
    fn readStage(page: *Page, arena: *Arena, reply: Json) !void {
        const memory = arena.allocator();
        const keep_form = page.edited_while_busy and page.fields.len > 0;
        if (!keep_form) try page.buildForm(memory, reply, false);
        page.description = try memory.dupeZ(u8, stringField(reply, "help"));
        page.keep_label = try memory.dupeZ(u8, stringField(reply, "keep_label"));
        page.requirements = try memory.dupeZ(u8, stringField(reply, "requirements"));
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
                skipped += 1;
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
            // a coluna do nome (a segunda) fica com o que sobra
            const widths = try memory.alloc(f32, headers.len);
            for (widths, 0..) |*width, k| width.* = if (headers.len <= 1) 1 else if (k == 1) 0.4 else 0.6 / @as(f32, @floatFromInt(headers.len - 1));
            try tables.append(memory, .{ .title = try memory.dupeZ(u8, stringField(item, "title")), .headers = headers, .rows = table_rows, .widths = widths });
        };
        var charts: std.ArrayList(Chart) = .empty;
        page.skipped_charts = 0;
        var loads: std.ArrayList(LoadsScene) = .empty;
        if (reply.object.get("plots")) |list| for (list.array.items) |item| {
            if (std.mem.eql(u8, stringField(item, "kind"), "loads3d")) {
                if (try readLoads(memory, item)) |scene| try loads.append(memory, scene);
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
                };
            }
            try charts.append(memory, .{ .title = try memory.dupeZ(u8, stringField(item, "title")), .x_label = try memory.dupeZ(u8, stringField(item, "xlabel")), .y_label = try memory.dupeZ(u8, stringField(item, "ylabel")), .series = series, .x_limits = limits(item.object.get("xlim")), .y_limits = limits(item.object.get("ylim")) });
        };
        page.summary = rows.items;
        page.checks = found.items;
        page.tables = tables.items;
        page.charts = charts.items;
        page.loads = loads.items;
    }

    // ------------------------------------------------------------------ desenho

    fn drawTodo(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const box: rl.Rectangle = .{ .x = rect.x + 40, .y = rect.y + 40, .width = @min(rect.width - 80, 680), .height = 150 };
        const inner = widgets.labeledCard(ui, box, page.title);
        _ = widgets.paragraph(ui.fonts.regular, "esta página ainda não passou para a ponte com o Python; por enquanto ela está só na GUI PyQt (python -m aerosim.gui)", inner.x, inner.y + 10, inner.width, 15, theme.colors.label);
    }

    fn drawSidebar(page: *Page, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const footer_height: f32 = if (page.kind == .simulation) 112 else 64;
        const body: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height };
        const busy = page.job.running();
        // a parte que rola: (etapa) requisitos, título e botões; o formulário; (etapa) guardar e os guardados
        const top = page.side.begin(ui, body);
        var y = top + 6;
        const x = body.x + 12;
        const width = body.width - 24;
        if (page.kind == .stage) y = page.drawStageTop(ui, x, y, width);
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
                if (widgets.primaryButton(ui, button, "Parar", true)) page.bridge.cancel(&page.waiter);
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
        const bar_height = widgets.paragraphHeight(ui.fonts.regular, page.requirements, width - 12, 12) + 10;
        widgets.rounded(.{ .x = x, .y = y, .width = width, .height = bar_height }, 4, theme.colors.hover);
        _ = widgets.paragraph(ui.fonts.regular, page.requirements, x + 6, y + 5, width - 12, 12, theme.colors.label);
        y += bar_height + 6;
        if (dialogs.button(ui, .{ .x = x, .y = y, .width = width, .height = 30 }, "Condições e restrições…")) page.wants_requirements = true;
        y += 40;
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
        if (table.draw(ui, x + 6, y, width - 12, grid.columns, grid.rows)) |cell| edit.* = .{ .grid = index, .edit = cell };
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
        if (page.job.running() or change.grid >= page.grids.len) return;
        const grid = page.grids[change.grid];
        const selected = page.grid_tables[change.grid].selected orelse grid.rows.len -| 1;
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        const writer = &text.writer;
        writer.print("\"grid\": {f}", .{std.json.fmt(grid.name, .{})}) catch return;
        if (change.button) |button| {
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
        page.stageRequest("grid", text.written());
    }

    /// Guardar e a lista dos guardados (na etapa Perfis, a lista é a dos candidatos: clicar seleciona)
    fn drawKept(page: *Page, ui: *widgets.Ui, x: f32, top: f32, width: f32) f32 {
        var y = top;
        const busy = page.job.running();
        const candidates = std.mem.eql(u8, page.name, "perfis");
        if (page.keep_label.len > 0) {
            if (widgets.primaryButton(ui, .{ .x = x, .y = y, .width = width, .height = 32 }, page.keep_label, !busy)) page.stageRequest("keep", "");
            y += 42;
        }
        if (!candidates and page.keep_label.len == 0) return y;
        var title: [64]u8 = undefined;
        theme.text(ui.fonts.regular, widgets.format(&title, "{s} ({d})", .{ if (candidates) "Candidatos" else "Guardados", page.kept.len }), x, y, 15, theme.colors.accent);
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
        const view_card: rl.Rectangle = .{ .x = rect.x + gap, .y = rect.y + gap - page.page.offset, .width = width, .height = view_height };
        const view_area: rl.Rectangle = .{ .x = view_card.x + 1, .y = view_card.y + 28, .width = view_card.width - 2, .height = view_card.height - 29 };
        if (page.scene) |*scene| page.renderScene(ui, scene, view_area);
        for (page.loads[0..@min(page.loads.len, max_loads)], 0..) |*scene, k| renderLoads(ui, scene, &page.loads_states[k]);
        const top = page.page.begin(ui, rect);
        var y = top + gap;
        if (page.scene != null) {
            _ = widgets.card(ui, view_card, "A peça em 3D (arraste para girar, roda para aproximar)");
            page.view.blit(ui, view_area);
            y += view_height + gap;
        }
        if (page.kind == .simulation and page.description.len > 0) {
            y += widgets.paragraph(ui.fonts.regular, page.description, rect.x + gap + 4, y, width - 8, 14, theme.colors.label) + gap;
        }
        const beside = page.grids_beside and page.grids.len > 0;
        if (!beside and page.charts.len == 0 and page.summary.len == 0 and page.tables.len == 0 and page.checks.len == 0 and page.scene == null and page.loads.len == 0) {
            const note: []const u8 = if (page.job.running()) "pedindo ao Python..." else if (page.kind == .simulation) "o resultado aparece aqui depois de Rodar" else std.mem.sliceTo(&page.message, 0);
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
        // as vistas de carga e depois os gráficos, em duas colunas, na ordem dos `PlotSpec` (as vistas vêm primeiro)
        const column_width = (width - gap) / 2;
        var row_height: f32 = 0;
        for (page.loads[0..@min(page.loads.len, max_loads)], 0..) |*scene, k| {
            const x = rect.x + gap + @as(f32, @floatFromInt(k % 2)) * (column_width + gap);
            row_height = @max(row_height, drawLoads(ui, scene, &page.loads_states[k], x, y, column_width));
            if (k % 2 == 1 or k + 1 == page.loads.len) {
                y += row_height + gap;
                row_height = 0;
            }
        }
        for (page.charts, 0..) |chart, k| {
            const x = rect.x + gap + @as(f32, @floatFromInt(k % 2)) * (column_width + gap);
            const chart_y = y + @as(f32, @floatFromInt(k / 2)) * (chart_height + gap);
            plot.lines(ui, .{ .x = x, .y = chart_y, .width = column_width, .height = chart_height }, .{ .title = chart.title, .x_label = chart.x_label, .y_label = chart.y_label, .x_limits = chart.x_limits, .y_limits = chart.y_limits }, chart.series);
        }
        y += @as(f32, @floatFromInt((page.charts.len + 1) / 2)) * (chart_height + gap);
        if (page.skipped_charts > 0) {
            var note: [96]u8 = undefined;
            theme.text(ui.fonts.regular, widgets.format(&note, "{d} vistas 3D ainda só na GUI PyQt", .{page.skipped_charts}), rect.x + gap + 4, y, 13, theme.colors.muted);
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
        if (!page.view.begin(area, middle, 0.8 * size)) return;
        defer page.view.end();
        view3d.floor(.{ middle[0], middle[1], 0 }, scene.high[2] + 0.05 * size, 1.4 * size, 0.25);
        for (scene.meshes) |mesh| {
            var k: usize = 0;
            while (k + 2 < mesh.faces.len) : (k += 3) {
                const a = vertex(mesh.vertices, mesh.faces[k]) orelse continue;
                const b = vertex(mesh.vertices, mesh.faces[k + 1]) orelse continue;
                const c = vertex(mesh.vertices, mesh.faces[k + 2]) orelse continue;
                view3d.triangle(a, b, c, view3d.shaded(a, b, c, mesh.color));
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
    // a distância da GUI PyQt (2,9 × o maior |vértice|, com o campo de visão de 60° do pyqtgraph) no campo de 35° daqui
    if (!state.view.begin(state.area, middle, 1.15 * size)) return;
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
        var k: usize = 0;
        var t: usize = 0;
        while (k + 2 < scene.triangles.len) : ({
            k += 3;
            t += 1;
        }) {
            const a = vertex(scene.vertices, scene.triangles[k]) orelse continue;
            const b = vertex(scene.vertices, scene.triangles[k + 1]) orelse continue;
            const c = vertex(scene.vertices, scene.triangles[k + 2]) orelse continue;
            const source = if (t < scene.face.len) scene.face[t] else 0;
            const value: f64 = if (source < field.values.len) field.values[source] else std.math.nan(f64);
            const position = if (std.math.isFinite(value)) (value - range[0]) / (range[1] - range[0]) else 0;
            view3d.triangle(a, b, c, view3d.fieldColor(position, state.symmetric));
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
    view3d.bodyAxes(&state.view, .{ scene.low[0] - 0.12 * size, scene.low[1] - 0.12 * size, scene.high[2] + 0.04 * size }, 0.14 * size);
}

/// o cartão de uma vista de cargas: o título, as escolhas (mapa, setas, escala), a imagem, a legenda e o caso;
/// devolve a altura
fn drawLoads(ui: *widgets.Ui, scene: *const LoadsScene, state: *LoadsState, x: f32, y: f32, width: f32) f32 {
    const info_height = widgets.paragraphHeight(ui.fonts.regular, scene.info, width - 24, 13);
    const height = 28 + 36 + loads_view_height + 46 + info_height + 12;
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
    state.area = .{ .x = inner.x, .y = row_y, .width = inner.width, .height = loads_view_height };
    state.view.blit(ui, state.area);
    row_y += loads_view_height + 6;
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
        try fields.append(memory, .{ .label = try memory.dupeZ(u8, stringField(field, "label")), .signed = flag(field, "signed"), .values = try floats(memory, field.object.get("values")) });
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
    var scene: LoadsScene = .{
        .title = try memory.dupeZ(u8, stringField(item, "title")),
        .info = try memory.dupeZ(u8, stringField(loads, "info")),
        .vertices = vertices,
        .triangles = try indices(memory, loads.object.get("triangles")),
        .face = try indices(memory, loads.object.get("face")),
        .fields = fields.items,
        .vectors = vectors.items,
        .rest = rest.items,
        .low = low,
        .high = high,
    };
    if (loads.object.get("camera")) |camera| if (camera == .object) {
        if (number(camera.object.get("elevation"))) |value| scene.elevation = @floatCast(value);
        if (number(camera.object.get("azimuth"))) |value| scene.azimuth = @floatCast(value);
    };
    return scene;
}

/// o que se fez numa tabela editável neste quadro: uma célula ou um botão
const GridEdit = struct {
    grid: usize,
    edit: ?table_mod.Edit = null,
    button: ?usize = null,
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
        meshes[m] = .{ .color = view3d.colorByName(stringField(item, "kind")), .vertices = vertices, .faces = faces };
    }
    if (list.len == 0) low = .{ -0.5, -0.5, -0.1 };
    if (list.len == 0) high = .{ 0.5, 0.5, 0.1 };
    var scene: Scene = .{ .meshes = meshes, .low = low, .high = high };
    if (view.object.get("markers")) |markers| if (markers == .object) {
        scene.neutral_x = number(markers.object.get("np_x"));
        if (markers.object.get("cg")) |point| if (point == .array and point.array.items.len == 3) {
            scene.gravity_center = .{ number(point.array.items[0]) orelse 0, number(point.array.items[1]) orelse 0, number(point.array.items[2]) orelse 0 };
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

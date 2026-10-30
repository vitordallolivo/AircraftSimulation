//! Uma subaba da janela, desenhada a partir do que o Python descreve (`python_bridge.zig`): a tela não conhece
//! nenhuma análise nem etapa, como a `SimulationTab` e a `StagePage` da GUI PyQt, das quais esta é a cópia.
//!
//!   análise (`simulation`)   uma `ISimulation` do manager: o formulário sai dos `ParamSpec`, Rodar manda os valores
//!                            e a resposta traz o resumo, o diagnóstico e as curvas
//!   etapa (`stage`)          uma etapa da sprint (`aerosim/manager/stages.py`): o rascunho em formulário, os botões
//!                            da etapa, Guardar e a lista dos guardados; cada mudança refaz a conta, como na GUI PyQt
//!   ainda sem ponte (`todo`) só o lugar da página
//!
//! Por enquanto a tela desenha campos de número, marcador, escolha e texto, gráficos 2D e tabelas; as tabelas
//! editáveis, os arquivos e as vistas 3D ficam com o valor do Python e aparecem só como nota.
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
const python_bridge = @import("python_bridge.zig");

const Json = std.json.Value;
const Arena = std.heap.ArenaAllocator;

pub const Kind = enum { simulation, stage, todo };

/// como o valor de um campo vai de volta para o Python
const ValueKind = enum { real, integer, toggle, choice, text };

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
};

/// uma tabela de texto (massas, dimensões)
const Table = struct {
    title: [:0]const u8,
    headers: []const [:0]const u8,
    rows: []const []const plot.Cell,
    widths: []const f32,
};

const SummaryRow = [2]plot.Cell;

/// o que a thread faz
const Operation = enum { specs, run, stage };

const sidebar_width: f32 = 390;
const chart_height: f32 = 360;
const gap: f32 = 12;
const edit_delay_ns: i96 = 350 * std.time.ns_per_ms; // a conta da etapa espera a digitação parar (300 ms na GUI PyQt)

pub const Page = struct {
    kind: Kind = .todo,
    name: []const u8 = "", // a análise ou a etapa no Python
    title: [:0]const u8 = "",
    bridge: *python_bridge.Bridge = undefined,
    process_io: ?std.Io = null, // a `Io` do processo (abre o Python); no navegador não há
    job: jobs.Job = .{},
    waiter: python_bridge.Waiter = .{},
    operation: Operation = .specs,
    loaded: bool = false, // já pediu a página ao Python
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
    wants_requirements: bool = false, // apertou "Condições e restrições…"
    prompt: dialogs.TextPrompt = .{},
    picker: dialogs.FilePicker = .{},
    pending_action: usize = 0,
    // o resultado
    result_arena: ?*Arena = null,
    charts: []Chart = &.{},
    checks: []checks_mod.Check = &.{},
    summary: []SummaryRow = &.{},
    tables: []Table = &.{},
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
        page.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
        page.drawResult(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
    }

    /// as janelas da página por cima da tela inteira
    pub fn drawModal(page: *Page, ui: *widgets.Ui, whole: rl.Rectangle) void {
        if (page.prompt.draw(ui, whole)) |answer| page.act(page.actions[page.pending_action].key, answer);
        if (page.picker.draw(ui, whole)) |path| page.act(page.actions[page.pending_action].key, path);
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
        const process = page.process_io orelse {
            setText(&waiter.failure, "no navegador a ponte com o Python ainda não existe (vai ser o Pyodide num web worker)", .{});
            return;
        };
        const bridge = page.bridge;
        bridge.start(process) catch |err| {
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
                .text => try writer.print("{f}", .{std.json.fmt(field.textValue(), .{})}),
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
        try page.readOutcome(memory, reply);
        const opened = stringField(reply, "open");
        if (opened.len > 0) {
            const length = @min(opened.len, page.opened.len);
            @memcpy(page.opened[0..length], opened[0..length]);
            page.opened_len = length;
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
            const value_kind = std.meta.stringToEnum(enum { float, int, bool, choice, str }, kind) orelse {
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
        if (reply.object.get("plots")) |list| for (list.array.items) |item| {
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
                var xs: std.ArrayList(f64) = .empty;
                var ys: std.ArrayList(f64) = .empty;
                for (xs_json[0..@min(xs_json.len, ys_json.len)], 0..) |x_json, i| {
                    const x = number(x_json) orelse continue;
                    const y = number(ys_json[i]) orelse continue;
                    try xs.append(memory, x);
                    try ys.append(memory, y);
                }
                series[k] = .{ .name = try memory.dupeZ(u8, stringField(curve, "name")), .xs = xs.items, .ys = ys.items, .dashed = flag(curve, "dashed") };
            }
            try charts.append(memory, .{ .title = try memory.dupeZ(u8, stringField(item, "title")), .x_label = try memory.dupeZ(u8, stringField(item, "xlabel")), .y_label = try memory.dupeZ(u8, stringField(item, "ylabel")), .series = series });
        };
        page.summary = rows.items;
        page.checks = found.items;
        page.tables = tables.items;
        page.charts = charts.items;
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
        if (page.kind == .stage) y = page.drawKept(ui, x, y + 4, width);
        page.side.end(ui, body, y + 12);
        changed = page.form.drawOpen(ui) or changed;
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
        const top = page.page.begin(ui, rect);
        var y = top + gap;
        const width = rect.width - 2 * gap - 10;
        if (page.kind == .simulation and page.description.len > 0) {
            y += widgets.paragraph(ui.fonts.regular, page.description, rect.x + gap + 4, y, width - 8, 14, theme.colors.label) + gap;
        }
        if (page.charts.len == 0 and page.summary.len == 0 and page.tables.len == 0 and page.checks.len == 0) {
            const note: []const u8 = if (page.job.running()) "pedindo ao Python..." else if (page.kind == .simulation) "o resultado aparece aqui depois de Rodar" else std.mem.sliceTo(&page.message, 0);
            _ = widgets.paragraph(ui.fonts.regular, note, rect.x + gap + 4, y + 10, width, 16, theme.colors.muted);
            page.page.end(ui, rect, y + 40);
            return;
        }
        if (page.kind == .stage and page.message[0] != 0) {
            y += widgets.paragraph(ui.fonts.regular, std.mem.sliceTo(&page.message, 0), rect.x + gap + 4, y, width - 8, 14, theme.colors.label) + gap;
        }
        for (page.tables) |table| {
            const height = plot.tableHeight(table.rows.len);
            plot.table(ui, .{ .x = rect.x + gap, .y = y, .width = width, .height = height }, table.title, table.headers, table.rows, table.widths);
            y += height + gap;
        }
        // os gráficos em duas colunas
        const column_width = (width - gap) / 2;
        for (page.charts, 0..) |chart, k| {
            const x = rect.x + gap + @as(f32, @floatFromInt(k % 2)) * (column_width + gap);
            const chart_y = y + @as(f32, @floatFromInt(k / 2)) * (chart_height + gap);
            plot.lines(ui, .{ .x = x, .y = chart_y, .width = column_width, .height = chart_height }, .{ .title = chart.title, .x_label = chart.x_label, .y_label = chart.y_label }, chart.series);
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
};

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

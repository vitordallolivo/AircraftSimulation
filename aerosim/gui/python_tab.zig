//! A aba Aerodinâmica → Pelo Python (teste da arquitetura raylib → managers em Python → núcleo Zig). A tela não
//! conhece nenhuma análise: ela pede ao Python (`python_bridge.zig`) a lista das abas `ISimulation`, os campos
//! (`ParamSpec`) e os gráficos (`PlotSpec`) da escolhida, monta o formulário com eles e mostra o que a rodada devolve
//! (o resumo, o diagnóstico e as curvas). A conta é a mesma da GUI PyQt, porque é o mesmo código em Python.
//!
//! Por enquanto a tela desenha campos de número, marcador e escolha e gráficos 2D; os outros tipos (tabela, arquivo,
//! 3D) ficam com o valor padrão do Python e aparecem só como nota.
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
const python_bridge = @import("python_bridge.zig");

const Json = std.json.Value;
const Arena = std.heap.ArenaAllocator;

/// uma aba do Python: o nome (chave no manager) e o título
const Simulation = struct {
    name: []const u8,
    title: []const u8,
};

/// como o valor de um campo vai de volta para o Python
const ValueKind = enum { real, integer, toggle, choice };

/// um campo do Python: a chave e o que a tela precisa para devolver o valor
const Param = struct {
    key: []const u8,
    kind: ValueKind,
    options: []const []const u8 = &.{}, // escolha: o texto de cada opção (o índice fica no campo)
    rebuild: bool = false, // mudar este campo pede os campos de novo
};

/// um gráfico pronto para desenhar
const Chart = struct {
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
    series: []plot.Series,
};

const SummaryRow = [2]plot.Cell;

/// o que a thread faz
const Operation = enum { list, specs, run };

const sidebar_width: f32 = 380;
const chart_height: f32 = 360;
const gap: f32 = 12;

pub const PythonTab = struct {
    bridge: python_bridge.Bridge = .{},
    process_io: ?std.Io = null, // a `Io` do processo (abre o Python com o ambiente dele); no navegador não há
    job: jobs.Job = .{},
    operation: Operation = .list,
    started: bool = false,
    // o pedido (a tela escreve antes de começar a thread) e a resposta (a thread escreve)
    request_text: []const u8 = "",
    request_arena: ?*Arena = null,
    reply_arena: ?*Arena = null,
    reply: ?Json = null,
    failure: [240:0]u8 = [_:0]u8{0} ** 240,
    aircraft_path: [1024]u8 = undefined,
    aircraft_len: usize = 0,
    // as abas do Python
    list_arena: ?*Arena = null,
    simulations: []Simulation = &.{},
    choice_text: [:0]const u8 = "",
    selected: usize = 0,
    // o formulário da aba escolhida
    spec_arena: ?*Arena = null,
    spec_for: ?usize = null, // a aba de quem são os campos
    groups: []form_mod.Group = &.{},
    fields: []form_mod.Field = &.{},
    params: []Param = &.{}, // params[k] é o campo fields[k + 1] (o 0 é a escolha da aba)
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    skipped: usize = 0, // campos que a tela ainda não desenha
    description: [:0]const u8 = "",
    // o resultado da última rodada
    result_arena: ?*Arena = null,
    charts: []Chart = &.{},
    checks: []checks_mod.Check = &.{},
    summary: []SummaryRow = &.{},
    skipped_charts: usize = 0,
    checks_panel: checks_mod.ChecksPanel = .{},
    page: scroll.ScrollArea = .{},
    seconds: f64 = 0,
    started_at: i96 = 0,
    message: [240:0]u8 = [_:0]u8{0} ** 240,
    run_when_ready: bool = false, // "rodar" da linha de comando (prints): roda assim que os campos chegam

    /// um comando pelo nome (`acao=` da linha de comando): "rodar" roda a aba assim que os campos chegarem
    pub fn command(tab: *PythonTab, name: []const u8) void {
        if (std.mem.eql(u8, name, "rodar")) tab.run_when_ready = true;
    }

    /// o avião aberto na Montagem (o Python abre o mesmo arquivo antes do próximo pedido)
    pub fn setAircraftPath(tab: *PythonTab, path: ?[]const u8) void {
        const text = path orelse "";
        const length = @min(text.len, tab.aircraft_path.len);
        @memcpy(tab.aircraft_path[0..length], text[0..length]);
        tab.aircraft_len = length;
    }

    /// fecha o Python (ao sair)
    pub fn deinit(tab: *PythonTab) void {
        tab.job.cancel();
        if (tab.process_io) |process| tab.bridge.stop(process);
    }

    /// desenha a aba: o formulário à esquerda, o resultado à direita
    pub fn draw(tab: *PythonTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        if (!tab.started) {
            tab.started = true;
            setText(&tab.message, "abrindo o Python...", .{});
            tab.begin(.list, "\"op\": \"list\"");
        }
        tab.collect();
        if (tab.run_when_ready and !tab.job.running() and tab.spec_for != null and tab.spec_for == tab.selected) {
            tab.run_when_ready = false;
            tab.run();
        }
        tab.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
        tab.drawResult(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
    }

    // ------------------------------------------------------------------ pedidos

    /// começa um pedido na thread (`fields`: o JSON do pedido sem o id, copiado aqui)
    fn begin(tab: *PythonTab, operation: Operation, fields: []const u8) void {
        if (tab.job.running()) return;
        const request = newArena() orelse return;
        tab.request_text = request.allocator().dupe(u8, fields) catch return;
        dropArena(&tab.request_arena);
        tab.request_arena = request;
        tab.reply_arena = newArena() orelse return;
        tab.reply = null;
        tab.failure[0] = 0;
        tab.operation = operation;
        tab.started_at = std.Io.Clock.awake.now(io()).nanoseconds;
        _ = tab.job.start(work, .{tab});
    }

    /// roda na thread: abre o Python se preciso, abre o avião da Montagem se mudou, e faz o pedido
    fn work(tab: *PythonTab) void {
        const memory = tab.reply_arena.?.allocator();
        const bridge = &tab.bridge;
        const process = tab.process_io orelse {
            setText(&tab.failure, "no navegador a ponte ainda não existe (vai ser o Pyodide num web worker)", .{});
            return;
        };
        bridge.start(process, std.heap.page_allocator) catch |err| {
            setText(&tab.failure, "não abriu o Python ({s}): rode da pasta do repositório, com as dependências instaladas", .{@errorName(err)});
            return;
        };
        const path = tab.aircraft_path[0..tab.aircraft_len];
        if (path.len > 0 and !bridge.hasOpened(path)) {
            const open = std.fmt.allocPrint(memory, "\"op\": \"open\", \"path\": {f}", .{std.json.fmt(path, .{})}) catch return;
            _ = bridge.request(process, memory, open, &tab.failure) catch return;
            bridge.markOpened(path);
        }
        tab.reply = bridge.request(process, memory, tab.request_text, &tab.failure) catch |err| {
            if (tab.failure[0] == 0) setText(&tab.failure, "a ponte com o Python falhou: {s}", .{@errorName(err)});
            return;
        };
    }

    /// no quadro em que a thread acabou: guarda a resposta no lugar dela
    fn collect(tab: *PythonTab) void {
        if (!tab.job.finished()) return;
        const elapsed = std.Io.Clock.awake.now(io()).nanoseconds - tab.started_at;
        tab.seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
        const reply = tab.reply orelse {
            dropArena(&tab.reply_arena);
            setText(&tab.message, "{s}", .{std.mem.sliceTo(&tab.failure, 0)});
            return;
        };
        const arena = tab.reply_arena.?;
        tab.reply_arena = null;
        switch (tab.operation) {
            .list => {
                tab.readList(arena, reply) catch setText(&tab.message, "resposta da lista fora do esperado", .{});
                tab.askSpecs();
            },
            .specs => tab.readSpecs(arena, reply) catch setText(&tab.message, "resposta dos campos fora do esperado", .{}),
            .run => {
                tab.readResult(arena, reply) catch setText(&tab.message, "resposta da rodada fora do esperado", .{});
                setText(&tab.message, "rodou em {d:.1} s (Python + núcleo)", .{tab.seconds});
            },
        }
    }

    /// pede os campos e os gráficos da aba escolhida, com os valores atuais (eles podem mudar o formulário)
    fn askSpecs(tab: *PythonTab) void {
        if (tab.simulations.len == 0) return;
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        tab.writeRequest(&text.writer, "specs") catch return;
        tab.begin(.specs, text.written());
    }

    /// manda rodar a aba escolhida com os valores do formulário
    fn run(tab: *PythonTab) void {
        var text: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer text.deinit();
        tab.writeRequest(&text.writer, "run") catch return;
        setText(&tab.message, "rodando no Python...", .{});
        tab.begin(.run, text.written());
    }

    /// `"op": ..., "name": ..., "values": {...}` (os valores só se os campos são desta aba)
    fn writeRequest(tab: *PythonTab, writer: *std.Io.Writer, operation: []const u8) !void {
        const simulation = tab.simulations[tab.selected];
        try writer.print("\"op\": \"{s}\", \"name\": {f}, \"values\": {{", .{ operation, std.json.fmt(simulation.name, .{}) });
        if (tab.spec_for == tab.selected) {
            for (tab.params, 0..) |param, k| {
                const field = &tab.fields[k + 1];
                if (k > 0) try writer.writeAll(", ");
                try writer.print("{f}: ", .{std.json.fmt(param.key, .{})});
                switch (param.kind) {
                    .real => try writer.print("{d}", .{field.number}),
                    .integer => try writer.print("{d}", .{@as(i64, @intFromFloat(@round(field.number)))}),
                    .toggle => try writer.writeAll(if (field.checked) "true" else "false"),
                    .choice => try writer.print("{f}", .{std.json.fmt(param.options[@intCast(field.choice)], .{})}),
                }
            }
        }
        try writer.writeAll("}");
    }

    // ------------------------------------------------------------------ respostas

    /// a lista das abas (a escolhida começa em "wings", a aba Asas)
    fn readList(tab: *PythonTab, arena: *Arena, reply: Json) !void {
        dropArena(&tab.list_arena);
        tab.list_arena = arena;
        const memory = arena.allocator();
        const items = (reply.object.get("sims") orelse return error.BadReply).array.items;
        const simulations = try memory.alloc(Simulation, items.len);
        var choices: std.ArrayList(u8) = .empty;
        tab.selected = 0;
        for (items, 0..) |item, k| {
            simulations[k] = .{ .name = stringField(item, "name"), .title = stringField(item, "title") };
            if (std.mem.eql(u8, simulations[k].name, "wings")) tab.selected = k;
            if (k > 0) try choices.append(memory, ';');
            try appendChoice(memory, &choices, simulations[k].title);
        }
        tab.simulations = simulations;
        tab.choice_text = try choices.toOwnedSliceSentinel(memory, 0);
        tab.spec_for = null;
        setText(&tab.message, "{d} abas do Python", .{items.len});
    }

    /// monta o formulário com os campos da resposta, guardando o valor dos campos que já existiam
    fn readSpecs(tab: *PythonTab, arena: *Arena, reply: Json) !void {
        const memory = arena.allocator();
        const items = (reply.object.get("params") orelse return error.BadReply).array.items;
        var groups: std.ArrayList(form_mod.Group) = .empty;
        var fields: std.ArrayList(form_mod.Field) = .empty;
        var params: std.ArrayList(Param) = .empty;
        try groups.append(memory, .{ .title = "Análise" });
        try fields.append(memory, .{ .label = "aba do Python", .group = 0, .kind = .choice, .choices = tab.choice_text, .choice = @intCast(tab.selected) });
        tab.skipped = 0;
        for (items) |item| {
            const kind = stringField(item, "kind");
            const value_kind: ValueKind = if (std.mem.eql(u8, kind, "float")) .real else if (std.mem.eql(u8, kind, "int")) .integer else if (std.mem.eql(u8, kind, "bool")) .toggle else if (std.mem.eql(u8, kind, "choice")) .choice else {
                tab.skipped += 1;
                continue;
            };
            const group_name = if (stringField(item, "group").len > 0) stringField(item, "group") else "Geral";
            var group_index: usize = groups.items.len;
            for (groups.items, 0..) |group, g| if (std.mem.eql(u8, group.title, group_name)) {
                group_index = g;
            };
            if (group_index == groups.items.len) try groups.append(memory, .{ .title = try memory.dupeZ(u8, group_name) });
            var field: form_mod.Field = .{
                .label = try memory.dupeZ(u8, stringField(item, "label")),
                .unit = try memory.dupeZ(u8, stringField(item, "unit")),
                .help = try memory.dupeZ(u8, stringField(item, "help")),
                .group = group_index,
                .minimum = number(item.object.get("minimum")) orelse -std.math.inf(f64),
                .maximum = number(item.object.get("maximum")) orelse std.math.inf(f64),
            };
            var param: Param = .{ .key = stringField(item, "key"), .kind = value_kind, .rebuild = flag(item, "rebuild") };
            const default = item.object.get("default") orelse .null;
            switch (value_kind) {
                .real, .integer => field.number = number(default) orelse 0,
                .toggle => {
                    field.kind = .toggle;
                    field.checked = default == .bool and default.bool;
                },
                .choice => {
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
            if (tab.spec_for == tab.selected) tab.keepValue(param, &field);
            try fields.append(memory, field);
            try params.append(memory, param);
        }
        tab.description = try memory.dupeZ(u8, stringField(reply, "description"));
        dropArena(&tab.spec_arena);
        tab.spec_arena = arena;
        tab.groups = groups.items;
        tab.fields = fields.items;
        tab.params = params.items;
        tab.spec_for = tab.selected;
        const area = tab.form.area;
        tab.form = .{ .groups = tab.groups, .fields = tab.fields, .area = area };
        setText(&tab.message, "{d} campos ({d} ainda só na GUI PyQt) · clique em Rodar", .{ params.items.len, tab.skipped });
    }

    /// o valor que o campo `key` tinha no formulário anterior (a mesma aba), se havia; uma escolha volta pelo
    /// texto da opção, porque a lista de opções pode ter mudado
    fn keepValue(tab: *const PythonTab, param: Param, field: *form_mod.Field) void {
        for (tab.params, 0..) |old, k| {
            if (!std.mem.eql(u8, old.key, param.key)) continue;
            const previous = tab.fields[k + 1];
            if (previous.kind != field.kind) return;
            field.number = previous.number;
            field.checked = previous.checked;
            if (field.kind == .choice) {
                const chosen = old.options[@intCast(previous.choice)];
                for (param.options, 0..) |option, index| {
                    if (std.mem.eql(u8, option, chosen)) field.choice = @intCast(index);
                }
            }
            return;
        }
    }

    /// o resumo, o diagnóstico e as curvas da rodada
    fn readResult(tab: *PythonTab, arena: *Arena, reply: Json) !void {
        const memory = arena.allocator();
        // o resumo: chave e valor em texto
        var rows: std.ArrayList(SummaryRow) = .empty;
        if (reply.object.get("summary")) |summary| if (summary == .object) {
            var entries = summary.object.iterator();
            while (entries.next()) |entry| {
                try rows.append(memory, .{ .{ .text = try memory.dupeZ(u8, entry.key_ptr.*) }, .{ .text = try valueText(memory, entry.value_ptr.*) } });
            }
        };
        // o diagnóstico
        var found: std.ArrayList(checks_mod.Check) = .empty;
        if (reply.object.get("checks")) |list| for (list.array.items) |item| {
            const status = std.meta.stringToEnum(widgets.Status, stringField(item, "status")) orelse .info;
            try found.append(memory, .{ .status = status, .item = stringField(item, "item"), .value = stringField(item, "value"), .criterion = stringField(item, "criterion"), .why = stringField(item, "why"), .fix = stringField(item, "fix"), .source = stringField(item, "source") });
        };
        // os gráficos
        var charts: std.ArrayList(Chart) = .empty;
        tab.skipped_charts = 0;
        if (reply.object.get("plots")) |list| for (list.array.items) |item| {
            const curves = (item.object.get("curves") orelse continue).array.items;
            if (!std.mem.eql(u8, stringField(item, "kind"), "2d")) {
                tab.skipped_charts += 1;
                continue;
            }
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
            try charts.append(memory, .{
                .title = try memory.dupeZ(u8, stringField(item, "title")),
                .x_label = try memory.dupeZ(u8, stringField(item, "xlabel")),
                .y_label = try memory.dupeZ(u8, stringField(item, "ylabel")),
                .series = series,
            });
        };
        dropArena(&tab.result_arena);
        tab.result_arena = arena;
        tab.summary = rows.items;
        tab.checks = found.items;
        tab.charts = charts.items;
    }

    // ------------------------------------------------------------------ desenho

    fn drawSidebar(tab: *PythonTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const footer_height: f32 = 112;
        const form_rect: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height };
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 1 }, theme.colors.line);
        const busy = tab.job.running();
        const ready = tab.spec_for != null and tab.spec_for == tab.selected;
        if (busy and tab.operation == .run) {
            if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 }, "Parar", true)) if (tab.process_io) |process| tab.bridge.cancel(process);
        } else if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 }, "Rodar", ready and !busy)) tab.run();
        const fraction: f32 = if (busy and tab.operation == .run) @as(f32, @floatFromInt(tab.bridge.progress.load(.acquire))) / 1000 else 0;
        widgets.progressBar(.{ .x = footer.x + 12, .y = footer.y + 56, .width = footer.width - 24, .height = 6 }, fraction);
        const status: []const u8 = if (busy and tab.operation == .run) std.mem.sliceTo(&tab.bridge.progress_text, 0) else std.mem.sliceTo(&tab.message, 0);
        _ = widgets.paragraph(ui.fonts.regular, status, footer.x + 12, footer.y + 68, footer.width - 24, 13, theme.colors.muted);
        if (tab.form.fields.len == 0) return;
        // a escolha da aba e os campos que refazem o formulário: se mudarem, os campos são pedidos de novo
        var before: [64]i32 = undefined;
        for (tab.params[0..@min(tab.params.len, before.len)], 0..) |param, k| before[k] = if (param.rebuild) snapshot(&tab.fields[k + 1]) else 0;
        if (tab.form.draw(ui, form_rect) and !busy) {
            tab.selected = @intCast(tab.fields[0].choice);
            var rebuild = tab.selected != tab.spec_for;
            for (tab.params[0..@min(tab.params.len, before.len)], 0..) |param, k| {
                if (param.rebuild and snapshot(&tab.fields[k + 1]) != before[k]) rebuild = true;
            }
            if (rebuild) tab.askSpecs();
        }
    }

    fn drawResult(tab: *PythonTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const top = tab.page.begin(ui, rect);
        var y = top + gap;
        const width = rect.width - 2 * gap - 10;
        if (tab.description.len > 0) {
            y += widgets.paragraph(ui.fonts.regular, tab.description, rect.x + gap + 4, y, width - 8, 14, theme.colors.label) + gap;
        }
        if (tab.charts.len == 0 and tab.summary.len == 0) {
            theme.text(ui.fonts.regular, "o resultado aparece aqui depois de Rodar", rect.x + gap + 4, y + 10, 16, theme.colors.muted);
            tab.page.end(ui, rect, y + 40);
            return;
        }
        // os gráficos em duas colunas
        const column_width = (width - gap) / 2;
        for (tab.charts, 0..) |chart, k| {
            const x = rect.x + gap + @as(f32, @floatFromInt(k % 2)) * (column_width + gap);
            const chart_y = y + @as(f32, @floatFromInt(k / 2)) * (chart_height + gap);
            plot.lines(ui, .{ .x = x, .y = chart_y, .width = column_width, .height = chart_height }, .{ .title = chart.title, .x_label = chart.x_label, .y_label = chart.y_label }, chart.series);
        }
        y += @as(f32, @floatFromInt((tab.charts.len + 1) / 2)) * (chart_height + gap);
        if (tab.skipped_charts > 0) {
            var note: [96]u8 = undefined;
            theme.text(ui.fonts.regular, widgets.format(&note, "{d} gráficos 3D ainda só na GUI PyQt", .{tab.skipped_charts}), rect.x + gap + 4, y, 13, theme.colors.muted);
            y += 24;
        }
        if (tab.checks.len > 0) {
            const height = checks_mod.ChecksPanel.height(@min(tab.checks.len, checks_mod.max_checks));
            tab.checks_panel.draw(ui, .{ .x = rect.x + gap, .y = y, .width = width, .height = height }, tab.checks);
            y += height + gap;
        }
        if (tab.summary.len > 0) {
            var rows: [64][]const plot.Cell = undefined;
            const count = @min(tab.summary.len, rows.len);
            for (tab.summary[0..count], 0..) |*row, k| rows[k] = row;
            const height = plot.tableHeight(count);
            plot.table(ui, .{ .x = rect.x + gap, .y = y, .width = width, .height = height }, "Resumo", &.{ "item", "valor" }, rows[0..count], &.{ 0.5, 0.5 });
            y += height + gap;
        }
        tab.page.end(ui, rect, y);
    }
};

// ---------------------------------------------------------------------- ajudas

fn io() std.Io {
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

/// um valor do resumo em texto: número com 4 algarismos, lista de números separada por vírgula
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
                const piece = try valueText(memory, item);
                try out.appendSlice(memory, piece);
            }
            break :blk out.toOwnedSliceSentinel(memory, 0);
        },
        else => memory.dupeZ(u8, "—"),
    };
}

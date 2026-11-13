//! A esquerda do aeroopt: o projeto da sprint, abrir e gravar o problema (`.opt.json`), um botão por parte do
//! problema (pontuação, variáveis, restrições, categorias e configuração) com o resumo ao lado, e Otimizar/Parar.
//! Cada botão abre o submenu por cima da tela; OK fica com o que mudou, Cancelar volta ao que era.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const dialogs = ui_kit.dialogs;
const table = ui_kit.table;
const form_mod = ui_kit.form;
const registry = @import("registry");
const problem_mod = @import("problem.zig");
const inputs = @import("inputs.zig");
const summaries = @import("summary.zig");

const Problem = problem_mod.Problem;
const Value = std.json.Value;

pub const Part = summaries.Part;
const Method = summaries.Method;
const configuration_methods = summaries.configuration_methods;
const fly_methods = summaries.fly_methods;
const surface_methods = summaries.surface_methods;
const takeoff_methods = summaries.takeoff_methods;
const sensitivity_methods = summaries.sensitivity_methods;
const categories = summaries.categories;
const legacy_categories = summaries.legacy_categories;
const isolate = summaries.isolate;
const hasCategory = summaries.hasCategory;
const categoryLabel = summaries.categoryLabel;
const choiceList = summaries.choiceList;
const methodIndex = summaries.methodIndex;
const section_of = summaries.section_of;
const text = summaries.text;
const number = summaries.number;
const boolean = summaries.boolean;
const writeSummary = summaries.writeSummary;

/// o que o painel pede para a tela fazer
pub const Request = enum { none, optimize, stop };

pub const Panel = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    problem: ?Problem = null,
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    project: [std.fs.max_path_bytes]u8 = undefined,
    project_len: usize = 0,
    picker: dialogs.FilePicker = .{},
    pending: enum { none, open_problem, save_problem, open_project } = .none,
    menu: ?Part = null,
    before: []const u8 = "", // o problema ao abrir o submenu (Cancelar volta a ele)
    group_tab: usize = 0, // a aba de grupo do submenu Variáveis
    variable_table: table.EditTable = .{},
    constraint_table: table.EditTable = .{},
    menu_scroll: ui_kit.scroll.ScrollArea = .{},
    sidebar_scroll: ui_kit.scroll.ScrollArea = .{}, // a coluna inteira rola quando os resumos não cabem
    menu_groups: [6]form_mod.Group = undefined,
    menu_fields: [16]form_mod.Field = undefined,
    menu_form: form_mod.Form = undefined,
    menu_keys: [16][]const u8 = undefined, // a categoria de cada campo do submenu Categorias
    running: bool = false,
    progress: f32 = 0,
    message: [200:0]u8 = [_:0]u8{0} ** 200,

    fn memory(panel: *Panel) std.mem.Allocator {
        return panel.arena.allocator();
    }

    /// o nome do arquivo do problema aberto (vazio se nenhum)
    pub fn fileName(panel: *const Panel) []const u8 {
        return std.fs.path.basename(panel.path[0..panel.path_len]);
    }

    fn say(panel: *Panel, comptime fmt: []const u8, args: anytype) void {
        _ = widgets.format(&panel.message, fmt, args);
    }

    /// lê o problema de um arquivo (o anterior sai da memória)
    pub fn openFile(panel: *Panel, path: []const u8) void {
        var fresh = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const opened = problem_mod.load(fresh.allocator(), ui_kit.system.io(), path) catch |err| {
            fresh.deinit();
            panel.say("não deu para abrir {s}: {s}", .{ std.fs.path.basename(path), switch (err) {
                error.CannotRead => "o arquivo não abre",
                error.NotProblem => "não é um problema do aeroopt",
                error.OutOfMemory => "falta memória",
            } });
            return;
        };
        panel.arena.deinit();
        panel.arena = fresh;
        panel.problem = opened;
        panel.menu = null;
        const length = @min(path.len, panel.path.len);
        @memcpy(panel.path[0..length], path[0..length]);
        panel.path_len = length;
        panel.say("{s}: {d} variáveis livres de {d}", .{ std.fs.path.basename(path), opened.freeCount(), opened.variables.len });
    }

    /// grava o problema em `path`
    pub fn saveFile(panel: *Panel, path: []const u8) void {
        const opened = &(panel.problem orelse return);
        const bytes = problem_mod.write(panel.memory(), opened) catch {
            panel.say("falta memória para gravar", .{});
            return;
        };
        std.Io.Dir.cwd().writeFile(ui_kit.system.io(), .{ .sub_path = path, .data = bytes }) catch {
            panel.say("não deu para gravar {s}", .{std.fs.path.basename(path)});
            return;
        };
        const length = @min(path.len, panel.path.len);
        @memcpy(panel.path[0..length], path[0..length]);
        panel.path_len = length;
        panel.say("gravado em {s}", .{std.fs.path.basename(path)});
    }

    /// guarda o caminho do projeto da sprint (o avião de partida e os valores de cada entrada)
    pub fn openProject(panel: *Panel, path: []const u8) void {
        const length = @min(path.len, panel.project.len);
        @memcpy(panel.project[0..length], path[0..length]);
        panel.project_len = length;
        panel.say("projeto: {s}", .{std.fs.path.basename(path)});
    }

    /// verdadeiro com um submenu ou uma janela de arquivo aberta (a tela de baixo não recebe o clique)
    pub fn modal(panel: *const Panel) bool {
        return panel.menu != null or panel.picker.open;
    }

    /// a coluna da esquerda; devolve o que se pediu (otimizar, parar)
    pub fn drawSidebar(panel: *Panel, ui: *widgets.Ui, rect: rl.Rectangle) Request {
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const pad: f32 = 12;
        const x = rect.x + pad;
        const width = rect.width - 2 * pad - 14; // a barra de rolar fica à direita
        var y = panel.sidebar_scroll.begin(ui, rect) + 10;
        defer panel.sidebar_scroll.end(ui, rect, y + 12);
        var request: Request = .none;
        var buffer: [std.fs.max_path_bytes + 32]u8 = undefined;

        y = section(ui, "Projeto da sprint", x, y, width);
        const project_name = if (panel.project_len > 0) std.fs.path.basename(panel.project[0..panel.project_len]) else "nenhum (o avião de partida vem dele)";
        theme.text(ui.fonts.regular, widgets.format(&buffer, "{s}", .{project_name}), x, y, 14, if (panel.project_len > 0) theme.colors.ink else theme.colors.muted);
        y += 22;
        if (dialogs.button(ui, .{ .x = x, .y = y, .width = width, .height = 30 }, "Abrir projeto…")) {
            panel.pending = .open_project;
            panel.picker.show("Abrir projeto: o sprint.json da pasta", "data", &.{".json"});
        }
        y += 40;

        const half = (width - 8) / 2;
        if (dialogs.button(ui, .{ .x = x, .y = y, .width = half, .height = 30 }, "Abrir problema…")) {
            panel.pending = .open_problem;
            panel.picker.show("Abrir problema (.opt.json)", "data", &.{".json"});
        }
        if (dialogs.button(ui, .{ .x = x + half + 8, .y = y, .width = half, .height = 30 }, "Gravar problema…")) {
            if (panel.problem == null) panel.say("abra um problema antes de gravar", .{}) else {
                panel.pending = .save_problem;
                const name = if (panel.path_len > 0) panel.fileName() else "problema.opt.json";
                panel.picker.showSave("Gravar problema (.opt.json)", "data", &.{".json"}, name);
            }
        }
        y += 40;
        if (panel.problem) |opened| {
            theme.text(ui.fonts.regular, widgets.format(&buffer, "{s}", .{if (opened.name.len > 0) opened.name else panel.fileName()}), x, y, 15, theme.colors.ink);
            y += 18;
            theme.text(ui.fonts.regular, widgets.format(&buffer, "{s}", .{panel.fileName()}), x, y, 13, theme.colors.muted);
            y += 24;
        }

        y = section(ui, "O problema (cada botão abre o submenu)", x, y, width);
        const button_width: f32 = 128;
        var summary_buffer: [1600]u8 = undefined;
        inline for (std.meta.fields(Part)) |field| {
            const part: Part = @enumFromInt(field.value);
            if (dialogs.button(ui, .{ .x = x, .y = y, .width = button_width, .height = 30 }, part.caption())) {
                if (panel.problem == null) panel.say("abra um problema primeiro", .{}) else panel.openMenu(part);
            }
            const part_summary = panel.summary(part, &summary_buffer);
            const used = widgets.paragraph(ui.fonts.regular, part_summary, x + button_width + 10, y + 6, width - button_width - 10, 13, theme.colors.label);
            y += @max(40, used + 14);
        }
        y += 6;

        if (widgets.primaryButton(ui, .{ .x = x, .y = y, .width = half, .height = 34 }, "▶ Otimizar", !panel.running and panel.problem != null)) request = .optimize;
        if (dialogs.button(ui, .{ .x = x + half + 8, .y = y, .width = half, .height = 34 }, "Parar") and panel.running) request = .stop;
        y += 44;
        widgets.progressBar(.{ .x = x, .y = y, .width = width, .height = 7 }, panel.progress);
        y += 16;
        y += widgets.paragraph(ui.fonts.regular, std.mem.sliceTo(&panel.message, 0), x, y, width, 13, theme.colors.muted);
        return request;
    }

    /// as janelas por cima da tela inteira: o submenu aberto e a de arquivo
    pub fn drawModal(panel: *Panel, ui: *widgets.Ui, whole: rl.Rectangle) void {
        if (panel.menu) |part| panel.drawMenu(ui, whole, part);
        if (panel.picker.draw(ui, whole)) |path| {
            const what = panel.pending;
            panel.pending = .none;
            switch (what) {
                .open_problem => panel.openFile(path),
                .save_problem => panel.saveFile(path),
                .open_project => panel.openProject(path),
                .none => {},
            }
        }
    }

    // ------------------------------------------------------------------ resumos

    /// o resumo ao lado do botão de uma parte
    fn summary(panel: *Panel, part: Part, buffer: []u8) []const u8 {
        const opened = &(panel.problem orelse return "—");
        var out: std.Io.Writer = .fixed(buffer);
        writeSummary(&out, opened, part) catch {}; // o que não couber fica de fora
        const written = out.buffered();
        return if (written.len == 0) "—" else written;
    }

    // ------------------------------------------------------------------ submenus

    /// abre o submenu de uma parte (se houver problema aberto)
    pub fn openPart(panel: *Panel, part: Part) void {
        if (panel.problem != null) panel.openMenu(part);
    }

    fn openMenu(panel: *Panel, part: Part) void {
        const opened = &(panel.problem orelse return);
        panel.before = problem_mod.write(panel.memory(), opened) catch "";
        panel.menu = part;
        panel.menu_scroll = .{};
        switch (part) {
            .variables, .constraints => {},
            .score => panel.fillScore(opened),
            .categories => panel.fillCategories(opened),
            .settings => panel.fillSettings(opened),
        }
        if (part == .constraints) panel.fillConstraintForm(opened);
    }

    fn closeMenu(panel: *Panel, keep: bool) void {
        const part = panel.menu orelse return;
        panel.menu = null;
        const opened = &(panel.problem orelse return);
        if (!keep) {
            if (panel.before.len > 0) {
                if (problem_mod.parse(panel.memory(), panel.before)) |restored| panel.problem = restored else |_| {}
            }
            return;
        }
        switch (part) {
            .score => opened.scoring = panel.memory().dupe(u8, panel.menu_fields[0].textValue()) catch opened.scoring,
            .categories => panel.applyCategories(opened),
            .settings => panel.applySettings(opened),
            .constraints => panel.applyConstraintForm(opened),
            .variables => {},
        }
    }

    fn drawMenu(panel: *Panel, ui: *widgets.Ui, whole: rl.Rectangle, part: Part) void {
        if (rl.isKeyPressed(.escape)) return panel.closeMenu(false);
        rl.drawRectangleRec(whole, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const wide = part == .variables or part == .constraints;
        const box_width = @min(whole.width - 80, if (wide) @as(f32, 1100) else 640);
        const box_height = @min(whole.height - 80, if (wide) @as(f32, 760) else 560);
        const box: rl.Rectangle = .{ .x = whole.x + (whole.width - box_width) / 2, .y = whole.y + (whole.height - box_height) / 2, .width = box_width, .height = box_height };
        const inner = widgets.card(ui, box, part.title());
        const footer: f32 = 50;
        const body: rl.Rectangle = .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = inner.height - footer };
        const opened = &(panel.problem orelse return);
        switch (part) {
            .variables => panel.drawVariables(ui, body, opened),
            .constraints => panel.drawConstraints(ui, body, opened),
            .score, .categories, .settings => _ = panel.menu_form.draw(ui, body),
        }
        if (part != .variables and part != .constraints) _ = panel.menu_form.drawOpen(ui);
        if (dialogs.button(ui, .{ .x = box.x + box.width - 250, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "Cancelar")) return panel.closeMenu(false);
        if (widgets.primaryButton(ui, .{ .x = box.x + box.width - 130, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "OK", true)) return panel.closeMenu(true);
        ui.click_taken = true;
        ui.wheel = 0;
    }

    // ---- Variáveis

    fn drawVariables(panel: *Panel, ui: *widgets.Ui, body: rl.Rectangle, opened: *Problem) void {
        var x = body.x + 4;
        const y = body.y + 4;
        theme.text(ui.fonts.regular, "isolar (só as numéricas; as listas ficam como estão):", x, y + 7, 13, theme.colors.label);
        x += 340;
        inline for (std.meta.fields(inputs.Group)) |field| {
            const group: inputs.Group = @enumFromInt(field.value);
            var buffer: [48]u8 = undefined;
            const caption = widgets.format(&buffer, "{s}", .{group.label()});
            const width = theme.textWidth(ui.fonts.regular, caption, 14) + 20;
            if (dialogs.button(ui, .{ .x = x, .y = y, .width = width, .height = 28 }, caption)) isolate(opened, group);
            x += width + 6;
        }
        if (dialogs.button(ui, .{ .x = x, .y = y, .width = 80, .height = 28 }, "nenhuma")) isolate(opened, null);

        var labels: [std.meta.fields(inputs.Group).len][:0]const u8 = undefined;
        var label_buffers: [labels.len][48]u8 = undefined;
        inline for (std.meta.fields(inputs.Group), 0..) |field, i| {
            const group: inputs.Group = @enumFromInt(field.value);
            labels[i] = widgets.format(&label_buffers[i], "{s}", .{group.label()});
        }
        _ = widgets.tabBar(ui, .{ .x = body.x, .y = y + 38, .width = body.width, .height = 34 }, &labels, &panel.group_tab, 14);
        const group: inputs.Group = @enumFromInt(panel.group_tab);

        const columns = [_]table.Column{
            .{ .title = "livre", .kind = .check, .width = 0.06, .help = "marcada: a busca escolhe; desmarcada: fica no valor do avião" },
            .{ .title = "variável", .kind = .label, .width = 0.30 },
            .{ .title = "limite inferior", .kind = .number, .width = 0.13 },
            .{ .title = "limite superior", .kind = .number, .width = 0.13 },
            .{ .title = "lista (o que a busca pode escolher)", .kind = .label, .width = 0.26 },
            .{ .title = "valor do avião", .kind = .label, .help = "o valor no projeto da sprint" },
        };
        var rows: [inputs.all.len][columns.len]table.Cell = undefined;
        var row_slices: [inputs.all.len][]const table.Cell = undefined;
        var row_inputs: [inputs.all.len]*const inputs.Input = undefined;
        var texts: [inputs.all.len][2][160]u8 = undefined;
        var count: usize = 0;
        for (&inputs.all) |*item| {
            if (item.group != group) continue;
            const found = opened.variable(item.key);
            const is_list = item.kind == .list;
            rows[count] = .{
                .{ .checked = if (found) |v| v.free else false },
                .{ .text = if (item.unit.len > 0) widgets.format(&texts[count][0], "{s} ({s})", .{ item.label, item.unit }) else widgets.format(&texts[count][0], "{s}", .{item.label}) },
                .{ .number = if (found) |v| v.lower else item.lower, .enabled = !is_list, .blank = is_list },
                .{ .number = if (found) |v| v.upper else item.upper, .enabled = !is_list, .blank = is_list },
                .{ .text = if (is_list) listText(&texts[count][1], item, found) else "" },
                .{ .text = "—", .color = theme.colors.muted },
            };
            row_slices[count] = &rows[count];
            row_inputs[count] = item;
            count += 1;
        }
        const area: rl.Rectangle = .{ .x = body.x, .y = y + 80, .width = body.width, .height = body.y + body.height - (y + 80) };
        panel.menu_scroll.content_height = panel.variable_table.fullHeight(count) + 8;
        const top = panel.menu_scroll.begin(ui, area);
        const edit = panel.variable_table.draw(ui, area.x, top, area.width - 12, &columns, row_slices[0..count]);
        panel.menu_scroll.end(ui, area, top + panel.menu_scroll.content_height);
        if (panel.variable_table.drawOpen(ui, &columns)) |open_edit| panel.applyVariableEdit(opened, row_inputs[open_edit.row], open_edit);
        if (edit) |made| panel.applyVariableEdit(opened, row_inputs[made.row], made);
    }

    fn applyVariableEdit(panel: *Panel, opened: *Problem, item: *const inputs.Input, edit: table.Edit) void {
        const variable = opened.variable(item.key) orelse panel.addVariable(opened, item) orelse return;
        switch (edit.value) {
            .check => |checked| variable.free = checked,
            .number => |typed| switch (edit.column) {
                2 => variable.lower = typed,
                3 => variable.upper = typed,
                else => {},
            },
            else => {},
        }
    }

    /// uma entrada do catálogo que ainda não está no problema entra nele (presa, com a faixa de sempre)
    fn addVariable(panel: *Panel, opened: *Problem, item: *const inputs.Input) ?*problem_mod.Variable {
        const grown = panel.memory().alloc(problem_mod.Variable, opened.variables.len + 1) catch return null;
        @memcpy(grown[0..opened.variables.len], opened.variables);
        grown[opened.variables.len] = .{ .key = item.key, .kind = item.kind, .lower = item.lower, .upper = item.upper, .group = item.group.label(), .free = false };
        opened.variables = grown;
        return &grown[grown.len - 1];
    }

    // ---- Restrições

    fn fillConstraintForm(panel: *Panel, opened: *const Problem) void {
        const geometry = section_of(opened, "geometria");
        const stability = section_of(opened, "estabilidade");
        panel.menu_groups[0] = .{ .title = "Geometria (o avião cabe e gira na decolagem)" };
        panel.menu_groups[1] = .{ .title = "Estabilidade (modelo linear do núcleo)" };
        panel.menu_fields[0] = .{ .label = "conferir a geometria", .group = 0, .kind = .toggle, .checked = boolean(geometry, "ligada", true) };
        panel.menu_fields[1] = .{ .label = "rotação na decolagem", .unit = "°", .group = 0, .number = number(geometry, "rotação", 12), .minimum = 0, .maximum = 30 };
        panel.menu_fields[2] = .{ .label = "folga", .unit = "%", .group = 0, .number = 100 * number(geometry, "folga", 0), .minimum = 0, .maximum = 50 };
        panel.menu_fields[3] = .{ .label = "folga da hélice", .unit = "%", .group = 0, .number = 100 * number(geometry, "folga_hélice", 0.02), .minimum = 0, .maximum = 50 };
        panel.menu_fields[4] = .{ .label = "uma peça só", .group = 0, .kind = .toggle, .checked = boolean(geometry, "uma_peça", false) };
        panel.menu_fields[5] = .{ .label = "conferir a estabilidade", .group = 1, .kind = .toggle, .checked = boolean(stability, "ligada", false) };
        panel.menu_fields[6] = .{ .label = "até o nível", .group = 1, .number = number(stability, "nível", 2), .minimum = 1, .maximum = 3 };
        panel.menu_form = .{ .groups = panel.menu_groups[0..2], .fields = panel.menu_fields[0..7] };
    }

    fn applyConstraintForm(panel: *Panel, opened: *Problem) void {
        const fields = &panel.menu_fields;
        panel.put(opened, "geometria", "ligada", .{ .bool = fields[0].checked });
        panel.put(opened, "geometria", "rotação", .{ .float = fields[1].number });
        panel.put(opened, "geometria", "folga", .{ .float = fields[2].number / 100 });
        panel.put(opened, "geometria", "folga_hélice", .{ .float = fields[3].number / 100 });
        panel.put(opened, "geometria", "uma_peça", .{ .bool = fields[4].checked });
        panel.put(opened, "estabilidade", "ligada", .{ .bool = fields[5].checked });
        panel.put(opened, "estabilidade", "nível", .{ .integer = @intFromFloat(@round(fields[6].number)) });
    }

    fn drawConstraints(panel: *Panel, ui: *widgets.Ui, body: rl.Rectangle, opened: *Problem) void {
        const form_width = @min(380, body.width * 0.36);
        _ = panel.menu_form.draw(ui, .{ .x = body.x, .y = body.y, .width = form_width, .height = body.height });
        const columns = [_]table.Column{
            .{ .title = "ligada", .kind = .check, .width = 0.09 },
            .{ .title = "grandeza", .kind = .label, .width = 0.42 },
            .{ .title = "sinal", .kind = .choice, .width = 0.12 },
            .{ .title = "valor", .kind = .number, .width = 0.18 },
            .{ .title = "tolerância", .kind = .number, .help = "só no \"=\": a diferença relativa aceita" },
        };
        const max_rows = 64;
        var rows: [max_rows][columns.len]table.Cell = undefined;
        var row_slices: [max_rows][]const table.Cell = undefined;
        var texts: [max_rows][120]u8 = undefined;
        const count = @min(opened.constraints.len, max_rows);
        for (opened.constraints[0..count], 0..) |item, i| {
            const quantity = registry.quantity(item.key);
            rows[i] = .{
                .{ .checked = item.active },
                .{ .text = if (quantity.unit.len > 0) widgets.format(&texts[i], "{s} ({s})", .{ quantity.label, quantity.unit }) else widgets.format(&texts[i], "{s}", .{quantity.label}) },
                .{ .choices = "≤;≥;=", .choice = @intFromEnum(item.comparison) },
                .{ .number = item.value },
                .{ .number = item.tolerance, .enabled = item.comparison == .equal },
            };
            row_slices[i] = &rows[i];
        }
        const area: rl.Rectangle = .{ .x = body.x + form_width + 12, .y = body.y + 4, .width = body.width - form_width - 12, .height = body.height - 4 };
        panel.menu_scroll.content_height = panel.constraint_table.fullHeight(count) + 8;
        const top = panel.menu_scroll.begin(ui, area);
        const edit = panel.constraint_table.draw(ui, area.x, top, area.width - 12, &columns, row_slices[0..count]);
        panel.menu_scroll.end(ui, area, top + panel.menu_scroll.content_height);
        _ = panel.menu_form.drawOpen(ui);
        if (panel.constraint_table.drawOpen(ui, &columns)) |open_edit| applyConstraintEdit(&opened.constraints[open_edit.row], open_edit);
        if (edit) |made| applyConstraintEdit(&opened.constraints[made.row], made);
    }

    // ---- Pontuação, Categorias, Configuração (formulários)

    fn fillScore(panel: *Panel, opened: *const Problem) void {
        panel.menu_groups[0] = .{ .title = "Pontuação" };
        panel.menu_fields[0] = .{ .label = "arquivo do regulamento ou objetivo", .group = 0, .kind = .text, .help = "o nome do arquivo de pontuação, ou MTOW, EE" };
        panel.menu_fields[0].setText(opened.scoring);
        panel.menu_form = .{ .groups = panel.menu_groups[0..1], .fields = panel.menu_fields[0..1] };
    }

    fn fillCategories(panel: *Panel, opened: *const Problem) void {
        panel.menu_groups[0] = .{ .title = "Categorias" };
        var count: usize = 0;
        for (categories ++ legacy_categories, 0..) |name, i| {
            const marked = hasCategory(opened, name);
            if (i >= categories.len and !marked) continue; // nome antigo: só se o arquivo tiver
            panel.menu_keys[count] = name;
            panel.menu_fields[count] = .{ .label = "", .group = 0, .kind = .toggle, .checked = marked };
            panel.menu_fields[count].label = categoryLabel(name);
            count += 1;
        }
        panel.menu_form = .{ .groups = panel.menu_groups[0..1], .fields = panel.menu_fields[0..count] };
    }

    fn applyCategories(panel: *Panel, opened: *Problem) void {
        var list = std.json.Array.init(panel.memory());
        for (panel.menu_form.fields, 0..) |field, i| if (field.checked) list.append(.{ .string = panel.menu_keys[i] }) catch return;
        panel.putTop(opened, "categorias", .{ .array = list });
    }

    fn fillSettings(panel: *Panel, opened: *const Problem) void {
        const stages = section_of(opened, "etapas");
        const sensitivity = section_of(opened, "sensibilidade");
        panel.menu_groups[0] = .{ .title = "configurações" };
        panel.menu_groups[1] = .{ .title = "voa (eficiência e carga)" };
        panel.menu_groups[2] = .{ .title = "superfícies" };
        panel.menu_groups[3] = .{ .title = "decolagem" };
        panel.menu_groups[4] = .{ .title = "sensibilidade" };
        panel.menu_fields[0] = .{ .label = "método", .group = 0, .kind = .choice, .choices = comptime choiceList(&configuration_methods), .choice = methodIndex(&configuration_methods, text(stages, "configurações", "gerações")) };
        panel.menu_fields[1] = .{ .label = "população", .group = 0, .number = number(stages, "população", 16), .minimum = 2, .maximum = 400 };
        panel.menu_fields[2] = .{ .label = "gerações", .group = 0, .number = number(stages, "gerações", 8), .minimum = 1, .maximum = 500 };
        panel.menu_fields[3] = .{ .label = "método", .group = 1, .kind = .choice, .choices = comptime choiceList(&fly_methods), .choice = methodIndex(&fly_methods, text(stages, "voa", "buscar")) };
        panel.menu_fields[4] = .{ .label = "método", .group = 2, .kind = .choice, .choices = comptime choiceList(&surface_methods), .choice = methodIndex(&surface_methods, text(stages, "superfícies", "coordenadas")) };
        panel.menu_fields[5] = .{ .label = "avaliações", .group = 2, .number = number(stages, "avaliações", 12), .minimum = 1, .maximum = 1000 };
        panel.menu_fields[6] = .{ .label = "processos (0 = um por núcleo)", .group = 2, .number = number(stages, "processos", 0), .minimum = 0, .maximum = 64 };
        panel.menu_fields[7] = .{ .label = "método", .group = 3, .kind = .choice, .choices = comptime choiceList(&takeoff_methods), .choice = methodIndex(&takeoff_methods, text(stages, "decolagem", "6gdl")) };
        panel.menu_fields[8] = .{ .label = "ligada", .group = 4, .kind = .toggle, .checked = boolean(sensitivity, "ligada", true) };
        panel.menu_fields[9] = .{ .label = "método", .group = 4, .kind = .choice, .choices = comptime choiceList(&sensitivity_methods), .choice = methodIndex(&sensitivity_methods, text(sensitivity, "método", "local")) };
        panel.menu_form = .{ .groups = panel.menu_groups[0..5], .fields = panel.menu_fields[0..10] };
    }

    fn applySettings(panel: *Panel, opened: *Problem) void {
        const fields = &panel.menu_fields;
        panel.put(opened, "etapas", "configurações", .{ .string = configuration_methods[@intCast(fields[0].choice)].key });
        panel.put(opened, "etapas", "população", .{ .integer = @intFromFloat(@round(fields[1].number)) });
        panel.put(opened, "etapas", "gerações", .{ .integer = @intFromFloat(@round(fields[2].number)) });
        panel.put(opened, "etapas", "voa", .{ .string = fly_methods[@intCast(fields[3].choice)].key });
        panel.put(opened, "etapas", "superfícies", .{ .string = surface_methods[@intCast(fields[4].choice)].key });
        panel.put(opened, "etapas", "avaliações", .{ .integer = @intFromFloat(@round(fields[5].number)) });
        panel.put(opened, "etapas", "processos", .{ .integer = @intFromFloat(@round(fields[6].number)) });
        panel.put(opened, "etapas", "decolagem", .{ .string = takeoff_methods[@intCast(fields[7].choice)].key });
        panel.put(opened, "sensibilidade", "ligada", .{ .bool = fields[8].checked });
        panel.put(opened, "sensibilidade", "método", .{ .string = sensitivity_methods[@intCast(fields[9].choice)].key });
    }

    // ---- params do arquivo

    /// params[`top`] = value
    fn putTop(panel: *Panel, opened: *Problem, top: []const u8, value: Value) void {
        if (opened.params != .object) opened.params = .{ .object = .empty };
        opened.params.object.put(panel.memory(), top, value) catch {};
    }

    /// params[`top`][`key`] = value (cria o grupo se faltar)
    fn put(panel: *Panel, opened: *Problem, top: []const u8, key: []const u8, value: Value) void {
        if (opened.params != .object) opened.params = .{ .object = .empty };
        const entry = opened.params.object.getOrPut(panel.memory(), top) catch return;
        if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
        entry.value_ptr.object.put(panel.memory(), key, value) catch {};
    }
};

// ---------------------------------------------------------------------- ajudas

/// o título de uma seção da coluna, com a linha embaixo; devolve onde o conteúdo começa
fn section(ui: *widgets.Ui, title: [:0]const u8, x: f32, y: f32, width: f32) f32 {
    theme.text(ui.fonts.bold, title, x, y, 14, theme.colors.accent);
    rl.drawRectangleRec(.{ .x = x, .y = y + 20, .width = width, .height = 1 }, theme.colors.line);
    return y + 28;
}

fn applyConstraintEdit(constraint: *problem_mod.Constraint, edit: table.Edit) void {
    switch (edit.value) {
        .check => |checked| constraint.active = checked,
        .choice => |choice| constraint.comparison = @enumFromInt(@as(u2, @intCast(std.math.clamp(choice, 0, 2)))),
        .number => |value| switch (edit.column) {
            3 => constraint.value = value,
            4 => constraint.tolerance = value,
            else => {},
        },
        else => {},
    }
}
/// o texto da coluna "lista": as opções marcadas, ou "todos"
fn listText(buffer: []u8, item: *const inputs.Input, found: ?*problem_mod.Variable) [:0]const u8 {
    const variable = found orelse return widgets.format(buffer, "todos", .{});
    if (variable.options.len == 0) return widgets.format(buffer, "todos", .{});
    var out: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    out.print("{d}: ", .{variable.options.len}) catch {};
    for (variable.options, 0..) |option, i| out.print("{s}{s}", .{ if (i > 0) ", " else "", option }) catch break;
    _ = item;
    const length = out.buffered().len;
    buffer[length] = 0;
    return buffer[0..length :0];
}

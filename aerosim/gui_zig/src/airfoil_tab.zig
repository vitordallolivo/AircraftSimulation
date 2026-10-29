//! A aba Aerodinâmica → Perfis: os perfis candidatos e a polar 2D de cada um, como a página Perfis da GUI em
//! Python (`aerosim/gui/design/pages.py: AirfoilPage`). À esquerda, as condições de projeto numa linha, a lista de
//! candidatos (todos entram nos gráficos) com os botões "+ NACA", "+ .dat", "+ só parâmetros", "+ polar XFLR5" e
//! "Remover", o Reynolds e o editor do candidato selecionado; embaixo, "Usar na asa" leva o perfil para a etapa
//! Projetar. À direita, c_l, a polar, c_l/c_d e c_m em α, o contorno, o diagnóstico e a tabela dos números. A conta
//! é a de `airfoil_stage.zig` (e do núcleo, `physics/section.zig`); a lista é a do projeto (`design.zig`).
const std = @import("std");
const rl = @import("raylib");
const core = @import("aerosim");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const dialogs = ui_kit.dialogs;
const menus = ui_kit.menus;
const stage = @import("airfoil_stage.zig");
const design_mod = @import("design.zig");

const section = core.section;
const max_candidates = stage.max_candidates;

const FieldId = enum(usize) { cl_alpha, alpha0, cl_max, cd0, cm_ac };

const editor_fields = [_]form_mod.Field{
    .{ .label = "a1 (inclinação)", .unit = "1/rad", .group = 0, .minimum = 0.5, .maximum = 12 },
    .{ .label = "α_L0", .unit = "°", .group = 0, .minimum = -20, .maximum = 10 },
    .{ .label = "c_l,max", .group = 0, .minimum = 0.1, .maximum = 4 },
    .{ .label = "c_d0", .group = 0, .minimum = 0.001, .maximum = 0.2 },
    .{ .label = "c_m", .group = 0, .minimum = -0.6, .maximum = 0.3 },
};

/// os métodos de polar do menu, com o que cada um é
const method_list = [_]struct { method: stage.Source, caption: [:0]const u8 }{
    .{ .method = .modelo, .caption = "modelo (reta e estol)" },
    .{ .method = .arquivo, .caption = "arquivo (XFLR5/XFOIL)" },
};

/// uma curva por candidato e método
const max_shown = max_candidates * method_list.len;

/// os botões da lista
const Action = enum { naca, dat, parameters, polar, remove };

/// o que o seletor de arquivo está escolhendo
const Purpose = enum { dat, polar };

pub const AirfoilTab = struct {
    design: *design_mod.Design = undefined,
    selected: usize = 0,
    list: menus.ItemList = .{},
    groups: [1]form_mod.Group = .{.{ .title = "Perfil" }},
    methods: menus.CheckMenu = .{}, // o menu dos métodos de polar
    stale: bool = false, // algo mudou desde a última rodada
    fields: [editor_fields.len]form_mod.Field = editor_fields,
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    group_title: [120:0]u8 = [_:0]u8{0} ** 120,
    picker: dialogs.FilePicker = .{},
    purpose: Purpose = .dat,
    prompt: dialogs.TextPrompt = .{},
    seen_version: u32 = std.math.maxInt(u32),
    // o que se mostra (refeito a cada rodada; guardado por valor, a lista pode mudar depois)
    shown_names: [max_shown][80:0]u8 = undefined,
    shown_method: [max_shown]stage.Source = undefined,
    shown_reynolds: [max_shown]f64 = undefined, // o Re da polar medida
    outcomes: [max_shown]stage.Outcome = undefined,
    contour_x: [max_shown][]f64 = undefined,
    contour_y: [max_shown][]f64 = undefined,
    contour_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    shown_count: usize = 0,
    reynolds: f64 = 0,
    message: [200:0]u8 = [_:0]u8{0} ** 200,
    scroll: f32 = 0,

    /// liga a aba ao projeto
    pub fn attach(tab: *AirfoilTab, design: *design_mod.Design) void {
        tab.design = design;
        tab.refresh();
    }

    /// uma janela (seletor de arquivo, pergunta) está aberta: a tela de baixo não deve reagir
    pub fn modalOpen(tab: *const AirfoilTab) bool {
        return tab.picker.open or tab.prompt.open;
    }

    /// desenha as janelas por cima de tudo e trata a resposta
    pub fn drawModal(tab: *AirfoilTab, ui: *widgets.Ui, screen: rl.Rectangle) void {
        if (tab.picker.draw(ui, screen)) |path| {
            switch (tab.purpose) {
                .dat => tab.addDat(path),
                .polar => tab.addPolar(path),
            }
        }
        if (tab.prompt.draw(ui, screen)) |code| {
            var digits: [4]u8 = undefined;
            var count: usize = 0;
            for (code) |ch| if (std.ascii.isDigit(ch)) {
                if (count < 4) digits[count] = ch;
                count += 1;
            };
            if (count == 4) {
                var name: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&name, "NACA {s}", .{digits[0..4]}) catch return;
                tab.add(stage.fromOutline(tab.design.allocator(), text, &.{}, "naca") catch return);
            } else tab.setMessage("o código NACA tem 4 dígitos", .{});
        }
    }

    /// um arquivo arrastado para a janela: `.dat` vira candidato; polar (`.txt`, `.csv`, `.pol`) vai para o
    /// candidato selecionado. Devolve falso se não for um dos dois
    pub fn addFile(tab: *AirfoilTab, path: []const u8) bool {
        const extension = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(extension, ".dat")) {
            tab.addDat(path);
            return true;
        }
        for ([_][]const u8{ ".txt", ".csv", ".pol" }) |polar| if (std.ascii.eqlIgnoreCase(extension, polar)) {
            tab.addPolar(path);
            return true;
        };
        return false;
    }

    fn add(tab: *AirfoilTab, candidate: stage.Candidate) void {
        if (tab.design.find(candidate.name) != null) return tab.setMessage("'{s}' já está na lista", .{candidate.name});
        if (tab.design.airfoil_count == max_candidates) return tab.setMessage("lista cheia ({d} perfis)", .{max_candidates});
        tab.design.add(candidate);
        tab.selected = tab.design.airfoil_count - 1;
        tab.refresh();
    }

    fn addDat(tab: *AirfoilTab, path: []const u8) void {
        const candidate = design_mod.readDat(tab.design.allocator(), path) catch |err| return tab.setMessage("não li '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) });
        tab.add(candidate);
    }

    /// a polar vai para o perfil selecionado (sem nenhum, vira um perfil novo com o nome do arquivo)
    fn addPolar(tab: *AirfoilTab, path: []const u8) void {
        const memory = tab.design.allocator();
        if (tab.design.airfoil_count == 0) {
            tab.add(.{ .name = memory.dupe(u8, std.fs.path.stem(path)) catch return, .origin = "parâmetros", .numbers = parameterNumbers() });
        }
        const candidate = &tab.design.airfoils[@min(tab.selected, tab.design.airfoil_count - 1)];
        design_mod.readPolar(memory, path, candidate) catch |err| return tab.setMessage("não li a polar '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) });
        tab.design.touch();
        tab.refresh();
        tab.setMessage("polar lida: {d} pontos, Re {d:.3}", .{ candidate.measured.?.count, candidate.measured_reynolds });
    }

    /// o que cada botão faz, pelo nome (também para `acao=` dos prints): naca, dat, parameters, polar, remove,
    /// rodar e metodos (abre o menu dos métodos de polar)
    pub fn command(tab: *AirfoilTab, name: []const u8) void {
        if (std.mem.eql(u8, name, "rodar")) return tab.run();
        if (std.mem.eql(u8, name, "metodos")) {
            tab.methods.open = true;
            return;
        }
        const action = std.meta.stringToEnum(Action, name) orelse return;
        const design = tab.design;
        switch (action) {
            .naca => tab.prompt.show("Perfil NACA", "Código de 4 dígitos:", "4412"),
            .dat => {
                tab.purpose = .dat;
                var buffer: [256]u8 = undefined;
                var fixed = std.heap.FixedBufferAllocator.init(&buffer);
                tab.picker.show("Perfil (.dat)", design_mod.libraryFolder(fixed.allocator()) orelse ".", &.{ ".dat", ".txt" });
            },
            .parameters => {
                var name_buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&name_buffer, "perfil {d}", .{design.airfoil_count + 1}) catch "perfil";
                tab.add(.{ .name = design.allocator().dupe(u8, text) catch return, .origin = "parâmetros", .numbers = parameterNumbers() });
            },
            .polar => {
                tab.purpose = .polar;
                tab.picker.show("Polar do XFLR5/XFOIL", ".", &.{ ".txt", ".csv", ".dat", ".pol" });
            },
            .remove => if (design.airfoil_count > 0) {
                design.remove(tab.selected);
                tab.refresh();
            },
        }
    }

    fn setMessage(tab: *AirfoilTab, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&tab.message, fmt, args) catch {};
    }

    /// a lista mudou: o editor do selecionado volta a valer, e os gráficos esperam o Rodar (a primeira vez roda)
    fn refresh(tab: *AirfoilTab) void {
        const design = tab.design;
        const first = tab.seen_version == std.math.maxInt(u32);
        tab.seen_version = design.version;
        if (tab.selected >= design.airfoil_count and design.airfoil_count > 0) tab.selected = design.airfoil_count - 1;
        tab.loadEditor();
        if (first) tab.run() else {
            tab.stale = true;
            tab.setMessage("mudou: clique em Rodar para refazer as polares", .{});
        }
    }

    /// as polares de todos os candidatos, por cada método marcado
    pub fn run(tab: *AirfoilTab) void {
        const design = tab.design;
        _ = tab.contour_arena.reset(.retain_capacity);
        const memory = tab.contour_arena.allocator();
        tab.shown_count = 0;
        for (design.airfoils[0..design.airfoil_count]) |*candidate| {
            var first = true;
            for (method_list) |item| {
                if (!candidate.methods.contains(item.method)) continue;
                if (item.method == .arquivo and candidate.measured == null) continue;
                tab.show(memory, candidate, item.method, first);
                first = false;
            }
        }
        tab.reynolds = design.reynolds();
        tab.stale = false;
        tab.setMessage("rodou: {d} polares", .{tab.shown_count});
    }

    /// os campos do editor com os números do selecionado
    fn loadEditor(tab: *AirfoilTab) void {
        if (tab.design.airfoil_count == 0) {
            tab.form = .{ .groups = &.{}, .fields = &.{} };
            return;
        }
        const candidate = &tab.design.airfoils[tab.selected];
        const numbers = candidate.numbers;
        tab.fields[@intFromEnum(FieldId.cl_alpha)].number = numbers.cl_alpha;
        tab.fields[@intFromEnum(FieldId.alpha0)].number = numbers.alpha0;
        tab.fields[@intFromEnum(FieldId.cl_max)].number = numbers.cl_max;
        tab.fields[@intFromEnum(FieldId.cd0)].number = numbers.cd0;
        tab.fields[@intFromEnum(FieldId.cm_ac)].number = numbers.cm_ac;
        tab.groups[0].title = if (candidate.methods.contains(.arquivo) and !candidate.methods.contains(.modelo))
            widgets.format(&tab.group_title, "Perfil (só na polar 'modelo')", .{})
        else
            widgets.format(&tab.group_title, "Perfil: {s}", .{candidate.name});
        tab.form = .{ .groups = &tab.groups, .fields = &tab.fields };
    }

    /// o que se editou volta para o candidato
    fn saveEditor(tab: *AirfoilTab) void {
        if (tab.design.airfoil_count == 0) return;
        const candidate = &tab.design.airfoils[tab.selected];
        candidate.numbers = .{
            .cl_alpha = tab.fields[@intFromEnum(FieldId.cl_alpha)].number,
            .alpha0 = tab.fields[@intFromEnum(FieldId.alpha0)].number,
            .cl_max = tab.fields[@intFromEnum(FieldId.cl_max)].number,
            .cd0 = tab.fields[@intFromEnum(FieldId.cd0)].number,
            .cm_ac = tab.fields[@intFromEnum(FieldId.cm_ac)].number,
        };
        tab.design.touch();
        tab.refresh();
    }

    fn show(tab: *AirfoilTab, memory: std.mem.Allocator, candidate: *const stage.Candidate, method: stage.Source, with_contour: bool) void {
        const k = tab.shown_count;
        if (k == max_shown) return;
        if (candidate.methods.count() > 1)
            _ = widgets.format(&tab.shown_names[k], "{s} · {s}", .{ candidate.name, @tagName(method) })
        else
            _ = widgets.format(&tab.shown_names[k], "{s}", .{candidate.name});
        tab.shown_method[k] = method;
        tab.shown_reynolds[k] = candidate.measured_reynolds;
        stage.evaluateWith(candidate, method, &tab.outcomes[k]);
        const n = if (with_contour) candidate.outline.len else 0;
        tab.contour_x[k] = memory.alloc(f64, n) catch &.{};
        tab.contour_y[k] = memory.alloc(f64, n) catch &.{};
        if (tab.contour_x[k].len == n and tab.contour_y[k].len == n) {
            for (candidate.outline[0..n], 0..) |point, i| {
                tab.contour_x[k][i] = point[0];
                tab.contour_y[k][i] = point[1];
            }
        }
        tab.shown_count += 1;
    }

    /// desenha a aba em `rect` (a lista e o editor à esquerda, gráficos à direita); devolve verdadeiro quando se
    /// pede "Usar na asa" (o perfil selecionado já foi para a asa; quem chama abre Projetar)
    pub fn draw(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) bool {
        if (tab.design.version != tab.seen_version) tab.refresh();
        const sidebar_width: f32 = 360;
        tab.drawPlots(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
        return tab.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
    }

    fn drawSidebar(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) bool {
        const design = tab.design;
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const x = rect.x + 12;
        const width = rect.width - 24;
        var y = rect.y + 10;
        // as condições de projeto numa linha (editadas na etapa Projetar)
        const requirements = design.requirements;
        var bar: [160:0]u8 = undefined;
        const bar_rect: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = 40 };
        widgets.rounded(bar_rect, 5, theme.colors.selected);
        theme.text(ui.fonts.regular, widgets.format(&bar, "partida m = {d} kg · V = {d} m/s · AD {d:.0} m", .{ requirements.mass, requirements.airspeed, requirements.altitude }), x + 8, y + 4, 12, theme.colors.ink);
        theme.text(ui.fonts.regular, widgets.format(&bar, "(ρ = {d:.3}) · as condições se editam em Projetar", .{core.wing_line.isaDensity(requirements.altitude)}), x + 8, y + 21, 12, theme.colors.label);
        y += 50;
        theme.text(ui.fonts.regular, "Candidatos (todos entram nos gráficos):", x, y, 14, theme.colors.ink);
        y += 22;
        // a lista
        var labels: [max_candidates][:0]const u8 = undefined;
        var label_text: [max_candidates][128:0]u8 = undefined;
        for (design.airfoils[0..design.airfoil_count], 0..) |candidate, k| {
            var method_text: [48:0]u8 = undefined;
            labels[k] = widgets.format(&label_text[k], "{s}   ({s}, polar: {s})", .{ candidate.name, candidate.origin, methodsText(&method_text, candidate.methods) });
        }
        if (tab.list.draw(ui, .{ .x = x, .y = y, .width = width, .height = 128 }, labels[0..design.airfoil_count], tab.selected)) |picked| {
            tab.selected = picked;
            tab.loadEditor();
        }
        y += 128 + 8;
        // os botões de ação, dois por linha
        const captions = [_][:0]const u8{ "+ NACA...", "+ .dat...", "+ só parâmetros", "+ polar XFLR5...", "Remover" };
        const actions = [_]Action{ .naca, .dat, .parameters, .polar, .remove };
        var grid_height: f32 = 0;
        if (menus.buttonGrid(ui, x, y, width, &captions, 2, &grid_height)) |pressed| tab.command(@tagName(actions[pressed]));
        y += grid_height + 2;
        var re_text: [96:0]u8 = undefined;
        theme.text(ui.fonts.regular, widgets.format(&re_text, "Re = {d:.0} (cruzeiro, corda média da asa)", .{tab.reynolds}), x, y, 13, theme.colors.label);
        y += 22;
        // os métodos de polar do selecionado: um botão que abre o menu de marcar (fica com o clique antes do editor)
        const has_selection = design.airfoil_count > 0;
        const toggle: rl.Rectangle = .{ .x = x + 80, .y = y, .width = width - 80, .height = 30 };
        if (has_selection) {
            if (tab.methods.update(ui, toggle, method_list.len)) |row| tab.toggleMethod(method_list[row].method);
            theme.text(ui.fonts.regular, "polar por:", x, y + 7, 14, theme.colors.label);
            y += 40;
        }
        // o editor do selecionado
        const footer_height: f32 = 128;
        const editor: rl.Rectangle = .{ .x = rect.x, .y = y, .width = rect.width - 1, .height = rect.y + rect.height - footer_height - y };
        if (tab.form.fields.len > 0 and tab.form.draw(ui, editor)) tab.saveEditor();
        if (has_selection) {
            const candidate = &design.airfoils[tab.selected];
            var items: [method_list.len]menus.CheckItem = undefined;
            var label_buffers: [method_list.len][64:0]u8 = undefined;
            for (method_list, 0..) |item, k| {
                const available = item.method != .arquivo or candidate.measured != null;
                items[k] = .{ .label = if (available) item.caption else widgets.format(&label_buffers[k], "{s}: sem polar lida", .{@tagName(item.method)}), .checked = candidate.methods.contains(item.method), .enabled = available };
            }
            var caption: [48:0]u8 = undefined;
            tab.methods.draw(ui, toggle, methodsText(&caption, candidate.methods), &items);
        }
        // embaixo: usar na asa
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height };
        rl.drawRectangleRec(footer, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 1 }, theme.colors.line);
        var used = false;
        if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 12, .width = footer.width - 24, .height = 34 }, if (tab.stale) "Rodar  (mudou)" else "Rodar", design.airfoil_count > 0)) tab.run();
        if (has_selection and dialogs.button(ui, .{ .x = footer.x + 12, .y = footer.y + 54, .width = footer.width - 24, .height = 30 }, "Usar na asa →")) {
            design.setRoot(design.airfoils[tab.selected].name);
            used = true;
        }
        theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), footer.x + 12, footer.y + 96, 13, theme.colors.muted);
        return used;
    }

    /// marca ou desmarca um método de polar do selecionado (o arquivo só com a polar lida; ao menos um fica)
    fn toggleMethod(tab: *AirfoilTab, method: stage.Source) void {
        const candidate = &tab.design.airfoils[tab.selected];
        var methods = candidate.methods;
        if (methods.contains(method)) methods.remove(method) else methods.insert(method);
        if (method == .arquivo and candidate.measured == null) return tab.setMessage("este perfil não tem polar de arquivo: use + polar XFLR5", .{});
        if (methods.count() == 0) return tab.setMessage("marque ao menos um método", .{});
        stage.setMethods(candidate, methods);
        tab.design.touch();
    }

    fn drawPlots(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 400;
        const summary_height: f32 = 90 + 26 * @as(f32, @floatFromInt(tab.shown_count));
        const content_height = 3 * (row_height + gap) + summary_height + 2 * gap;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        if (ui.hovering(rect)) tab.scroll = std.math.clamp(tab.scroll - ui.wheel * 60, 0, @max(0, content_height - rect.height));
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        defer rl.endScissorMode();
        if (tab.shown_count == 0) {
            theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), rect.x + 40, rect.y + 40, 16, theme.colors.muted);
            return;
        }
        var y = rect.y + gap - tab.scroll;
        var lift: [max_shown]plot.Series = undefined;
        var drag: [max_shown]plot.Series = undefined;
        var efficiency: [max_shown]plot.Series = undefined;
        var moment: [max_shown]plot.Series = undefined;
        var outline: [max_shown]plot.Series = undefined;
        var outline_count: usize = 0;
        for (0..tab.shown_count) |k| {
            const polar = &tab.outcomes[k].polar;
            const n = polar.count;
            const name = std.mem.sliceTo(&tab.shown_names[k], 0);
            lift[k] = .{ .name = name, .xs = polar.alpha[0..n], .ys = polar.cl[0..n], .color_index = k };
            drag[k] = .{ .name = name, .xs = polar.cd[0..n], .ys = polar.cl[0..n], .color_index = k };
            efficiency[k] = .{ .name = name, .xs = polar.alpha[0..n], .ys = tab.outcomes[k].ld[0..n], .color_index = k };
            moment[k] = .{ .name = name, .xs = polar.alpha[0..n], .ys = polar.cm[0..n], .color_index = k };
            if (tab.contour_x[k].len > 0) {
                outline[outline_count] = .{ .name = name, .xs = tab.contour_x[k], .ys = tab.contour_y[k], .color_index = k };
                outline_count += 1;
            }
        }
        const count = tab.shown_count;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "c_l × α", .x_label = "α (°)", .y_label = "c_l" }, lift[0..count]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "Polar c_l × c_d", .x_label = "c_d", .y_label = "c_l" }, drag[0..count]);
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "Eficiência c_l/c_d × α", .x_label = "α (°)", .y_label = "c_l/c_d" }, efficiency[0..count]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "c_m × α", .x_label = "α (°)", .y_label = "c_m" }, moment[0..count]);
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "Contorno", .x_label = "x/c", .y_label = "y/c", .equal_axes = true }, outline[0..outline_count]);
        tab.drawDiagnosis(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height });
        y += row_height + gap;
        tab.drawSummary(ui, .{ .x = x0, .y = y, .width = rect.width - 2 * gap, .height = summary_height });
    }

    fn drawDiagnosis(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Diagnóstico");
        const columns = [_]f32{ inner.x, inner.x + 80, inner.x + 290 };
        var y = inner.y;
        var buffers: [2][160]u8 = undefined;
        const Row = struct { status: widgets.Status, item: [:0]const u8, value: [:0]const u8 };
        var rows: [max_shown + 2]Row = undefined;
        var row_count: usize = 0;
        var names: [max_shown][96]u8 = undefined;
        var values: [max_shown][96]u8 = undefined;
        rows[row_count] = .{ .status = if (tab.reynolds < 1e5) .atencao else .ok, .item = "Reynolds", .value = widgets.format(&buffers[0], "{d:.0} {s}", .{ tab.reynolds, if (tab.reynolds < 1e5) "(abaixo de 10⁵ as bolhas mudam muito a polar)" else "" }) };
        row_count += 1;
        for (0..tab.shown_count) |k| {
            const name = std.mem.sliceTo(&tab.shown_names[k], 0);
            const metrics = tab.outcomes[k].metrics orelse {
                rows[row_count] = .{ .status = .falha, .item = widgets.format(&names[k], "{s}: polar", .{name}), .value = "poucos pontos na faixa de α" };
                row_count += 1;
                continue;
            };
            const measured_reynolds = tab.shown_reynolds[k];
            if (tab.shown_method[k] == .arquivo and std.math.isFinite(measured_reynolds) and @abs(measured_reynolds / tab.reynolds - 1) > 0.3) {
                rows[row_count] = .{ .status = .atencao, .item = widgets.format(&names[k], "{s}: Re da polar", .{name}), .value = widgets.format(&values[k], "{d:.0} (≈ {d:.0}): exporte do XFLR5 no Re de cruzeiro", .{ measured_reynolds, tab.reynolds }) };
                row_count += 1;
            } else if (metrics.cd_constant) {
                rows[row_count] = .{ .status = .info, .item = widgets.format(&names[k], "{s}: c_d constante", .{name}), .value = "o modelo não tem balde de arrasto: use a polar do XFLR5" };
                row_count += 1;
            }
        }
        for (rows[0..row_count]) |row| {
            const labels = [_][:0]const u8{ @tagName(row.status), row.item, row.value };
            const colors = [_]rl.Color{ widgets.statusColor(row.status), theme.colors.ink, theme.colors.label };
            widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
        if (row_count == 1) theme.text(ui.fonts.regular, "nenhum aviso nos perfis marcados", inner.x, y + 4, 13, theme.colors.muted);
    }

    fn drawSummary(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Números de cada perfil (o que segue para a asa)");
        const headers = [_][:0]const u8{ "perfil", "polar por", "c_l,max", "α estol (°)", "(c_l/c_d) máx.", "c_l nele", "a1 (1/rad)", "α_L0 (°)", "c_m", "c_d mín." };
        var columns: [headers.len]f32 = undefined;
        const first: f32 = 220;
        const step = (inner.width - first) / @as(f32, @floatFromInt(headers.len - 1));
        for (&columns, 0..) |*x, i| x.* = if (i == 0) inner.x else inner.x + first + step * @as(f32, @floatFromInt(i - 1));
        const header_colors = [_]rl.Color{theme.colors.accent};
        widgets.tableRow(ui, inner.y, &columns, &headers, &header_colors, 13);
        var y = inner.y + 26;
        for (0..tab.shown_count) |k| {
            const metrics = tab.outcomes[k].metrics orelse continue;
            var buffers: [headers.len][48]u8 = undefined;
            _ = &buffers[0];
            const source: []const u8 = @tagName(tab.shown_method[k]);
            const cells = [_][:0]const u8{
                std.mem.sliceTo(&tab.shown_names[k], 0),
                widgets.format(&buffers[1], "{s}", .{source}),
                widgets.format(&buffers[2], "{d:.3}", .{metrics.cl_max}),
                widgets.format(&buffers[3], "{d:.1}", .{metrics.alpha_stall}),
                widgets.format(&buffers[4], "{d:.1}", .{metrics.ld_max}),
                widgets.format(&buffers[5], "{d:.3}", .{metrics.cl_at_ld}),
                widgets.format(&buffers[6], "{d:.3}", .{metrics.cl_alpha}),
                widgets.format(&buffers[7], "{d:.2}", .{metrics.alpha0}),
                widgets.format(&buffers[8], "{d:.3}", .{metrics.cm}),
                widgets.format(&buffers[9], "{d:.4}", .{metrics.cd_min}),
            };
            const colors = [_]rl.Color{ theme.plotColor(k), theme.colors.label, theme.colors.ink };
            widgets.tableRow(ui, y, &columns, &cells, &colors, 14);
            y += 26;
        }
    }
};


/// os números de um perfil "só parâmetros" novo (os do botão em Python)
fn parameterNumbers() section.Airfoil {
    return .{ .cl_alpha = stage.default_numbers.cl_alpha, .alpha0 = -3.0, .cl_max = 1.5, .cd0 = stage.default_numbers.cd0, .cm_ac = -0.08 };
}

/// "modelo", "arquivo" ou "modelo, arquivo"
fn methodsText(buffer: []u8, methods: stage.Sources) [:0]const u8 {
    var names: [method_list.len][]const u8 = undefined;
    var checked: [method_list.len]bool = undefined;
    for (method_list, 0..) |item, k| {
        names[k] = @tagName(item.method);
        checked[k] = methods.contains(item.method);
    }
    return menus.checkedText(buffer, &names, &checked);
}

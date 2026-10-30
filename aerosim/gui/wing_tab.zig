//! A aba Aerodinâmica → Projetar: a asa a partir do perfil escolhido em Perfis, como a etapa Asa da GUI em
//! Python. À esquerda, a planta (envergadura, área ou corda, afilamento, trecho retangular, enflechamento,
//! torção), os perfis da raiz e da ponta e as condições de projeto; à direita, C_L em α até o estol, a polar
//! (induzido, perfil e total), L/D, o c_l ao longo da envergadura (onde o estol começa), a planta em escala, o
//! diagnóstico e os números. Em cima de tudo, a asa em 3D, com o perfil de verdade, montada pelo mesmo esqueleto da
//! Montagem e do AeroDrive. A conta é a do núcleo, `core/src/sizing/wing_line.zig`.
const std = @import("std");
const rl = @import("raylib");
const core = @import("aerosim");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const view3d = ui_kit.view3d;
const aircraft_model = @import("aircraft_model");
const stage = @import("airfoil_stage.zig");
const design_mod = @import("design.zig");
const assembly = @import("assembly.zig");

const model = aircraft_model.aircraft;
const Name = design_mod.Name;

const wing_line = core.wing_line;

const Group = enum(usize) { planform, airfoils, conditions };

const FieldId = enum(usize) { span, size_by, area, root_chord, taper, rect_fraction, sweep, twist, alpha_cruise, root_airfoil, tip_airfoil, mass, airspeed, altitude, wing_density };

const planform_group = @intFromEnum(Group.planform);
const conditions_group = @intFromEnum(Group.conditions);
const default_fields = [_]form_mod.Field{
    .{ .label = "envergadura", .unit = "m", .group = planform_group, .number = 2.4, .minimum = 0.3, .maximum = 8 },
    .{ .label = "dimensionar por", .group = planform_group, .kind = .choice, .choices = "área;corda" },
    .{ .label = "área", .unit = "m²", .group = planform_group, .number = 0.85, .minimum = 0.05, .maximum = 5 },
    .{ .label = "corda da raiz", .unit = "m", .group = planform_group, .number = 0.35, .minimum = 0.03, .maximum = 3 },
    .{ .label = "afilamento", .group = planform_group, .number = 1, .minimum = 0.2, .maximum = 1 },
    .{ .label = "trecho retangular", .group = planform_group, .number = 1, .minimum = 0, .maximum = 1 },
    .{ .label = "enflechamento (c/4)", .unit = "°", .group = planform_group, .number = 0, .minimum = -10, .maximum = 45 },
    .{ .label = "torção na ponta", .unit = "°", .group = planform_group, .number = -1, .minimum = -8, .maximum = 4 },
    .{ .label = "α de cruzeiro (fuselagem)", .unit = "°", .group = planform_group, .number = 0, .minimum = -4, .maximum = 8 },
    .{ .label = "perfil da raiz", .group = @intFromEnum(Group.airfoils), .kind = .choice, .choices = "" },
    .{ .label = "perfil da ponta", .group = @intFromEnum(Group.airfoils), .kind = .choice, .choices = "" },
    .{ .label = "massa estimada", .unit = "kg", .group = conditions_group, .number = 10, .minimum = 0.2, .maximum = 60 },
    .{ .label = "velocidade de cruzeiro", .unit = "m/s", .group = conditions_group, .number = 15, .minimum = 3, .maximum = 60 },
    .{ .label = "altitude-densidade", .unit = "m", .group = conditions_group, .number = 600, .minimum = -500, .maximum = 4000 },
    .{ .label = "massa da asa por área", .unit = "kg/m²", .group = conditions_group, .number = 1.1, .minimum = 0.1, .maximum = 6 },
};

const max_choices = design_mod.max_airfoils * 2;

pub const WingTab = struct {
    groups: [3]form_mod.Group = .{ .{ .title = "Planta (trapézio)" }, .{ .title = "Perfis (de Perfis e da biblioteca)" }, .{ .title = "Condições de projeto" } },
    fields: [default_fields.len]form_mod.Field = default_fields,
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    root_choices: [max_choices * 64:0]u8 = [_:0]u8{0} ** (max_choices * 64),
    tip_choices: [max_choices * 64 + 32:0]u8 = [_:0]u8{0} ** (max_choices * 64 + 32),
    candidates: [max_choices]*const stage.Candidate = undefined, // na ordem das escolhas
    candidate_count: usize = 0,
    design: *design_mod.Design = undefined,
    seen_version: u32 = std.math.maxInt(u32),
    result: wing_line.Result = .{},
    has_result: bool = false,
    root_name: [64:0]u8 = [_:0]u8{0} ** 64,
    tip_name: [64:0]u8 = [_:0]u8{0} ** 64,
    tip_used: bool = false,
    message: [200:0]u8 = [_:0]u8{0} ** 200,
    scroll: f32 = 0,
    plots: ui_kit.scroll.ScrollArea = .{}, // a coluna dos gráficos
    view: view3d.View = .{}, // a asa em 3D
    mesh: ?assembly.Mesh = null,
    sections: [3]model.Section = undefined, // as seções da asa do 3D (raiz, quebra, ponta)
    side: ui_kit.scroll.ScrollArea = .{}, // a barra lateral
    kept: ui_kit.menus.ItemList = .{}, // as asas guardadas
    kept_selected: usize = 0,
    saved_results: [design_mod.max_wings]wing_line.Result = undefined, // as guardadas, para comparar nos gráficos
    saved_ok: [design_mod.max_wings]bool = [_]bool{false} ** design_mod.max_wings,
    // curvas montadas a cada rodada
    cruise_line: [2][2]f64 = undefined, // a reta vertical do C_L de cruzeiro no gráfico de L/D
    max_line: [2][wing_line.stations]f64 = undefined,
    outline_x: [12]f64 = undefined,
    outline_y: [12]f64 = undefined,
    outline_count: usize = 0,
    onset_x: [2]f64 = undefined,
    onset_y: [2]f64 = undefined,

    fn field(tab: *WingTab, id: FieldId) *form_mod.Field {
        return &tab.fields[@intFromEnum(id)];
    }

    fn setMessage(tab: *WingTab, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&tab.message, fmt, args) catch {};
    }

    /// liga a aba ao projeto (as escolhas de perfil, as condições e a asa em desenho)
    pub fn attach(tab: *WingTab, design: *design_mod.Design) void {
        tab.design = design;
        tab.syncDesign();
    }

    /// refaz as escolhas de perfil quando a lista de Perfis muda (os perfis do projeto e a biblioteca); a raiz é a
    /// que "Usar na asa" escolheu
    fn syncDesign(tab: *WingTab) void {
        const design = tab.design;
        if (design.version == tab.seen_version) return;
        tab.seen_version = design.version;
        const old_tip = if (tab.tip_used) std.mem.sliceTo(&tab.tip_name, 0) else "";
        var tip_keep: [64]u8 = undefined;
        @memcpy(tip_keep[0..old_tip.len], old_tip);
        tab.candidate_count = 0;
        var root_writer: std.Io.Writer = .fixed(&tab.root_choices);
        var tip_writer: std.Io.Writer = .fixed(&tab.tip_choices);
        tip_writer.writeAll("= raiz") catch {};
        for (design.airfoils[0..design.airfoil_count]) |*candidate| tab.addChoice(candidate, &root_writer, &tip_writer);
        for (design.library[0..design.library_count]) |*candidate| {
            if (design.find(candidate.name) == null) tab.addChoice(candidate, &root_writer, &tip_writer);
        }
        tab.root_choices[root_writer.end] = 0;
        tab.tip_choices[tip_writer.end] = 0;
        tab.field(.root_airfoil).choices = tab.root_choices[0..root_writer.end :0];
        tab.field(.tip_airfoil).choices = tab.tip_choices[0..tip_writer.end :0];
        tab.field(.root_airfoil).choice = @intCast(tab.indexOf(design.rootAirfoil()) orelse 0);
        tab.field(.tip_airfoil).choice = if (tab.indexOf(tip_keep[0..old_tip.len])) |k| @intCast(k + 1) else 0;
        const wing = design.wing;
        const requirements = design.requirements;
        tab.field(.span).number = wing.span;
        tab.field(.size_by).choice = @intFromBool(wing.size_by_chord);
        tab.field(.area).number = wing.area;
        tab.field(.root_chord).number = wing.root_chord;
        tab.field(.taper).number = wing.taper;
        tab.field(.rect_fraction).number = wing.rect_fraction;
        tab.field(.sweep).number = wing.sweep;
        tab.field(.twist).number = wing.twist;
        tab.field(.alpha_cruise).number = wing.alpha_cruise;
        tab.field(.mass).number = requirements.mass;
        tab.field(.airspeed).number = requirements.airspeed;
        tab.field(.altitude).number = requirements.altitude;
        tab.field(.wing_density).number = requirements.wing_density;
        const kept_scroll = tab.form.area;
        tab.form = .{ .groups = &tab.groups, .fields = &tab.fields, .area = kept_scroll };
        tab.analyzeSaved();
        tab.run();
    }

    /// refaz as contas das asas guardadas nas condições de agora (as curvas finas dos gráficos)
    fn analyzeSaved(tab: *WingTab) void {
        const design = tab.design;
        const conditions = design.requirements.conditions();
        for (design.wings[0..design.wing_count], 0..) |*saved, k| {
            tab.saved_ok[k] = false;
            const root_index = tab.indexOf(saved.root.text()) orelse continue;
            const root = stage.wingSection(tab.candidates[root_index]);
            var tip: wing_line.SectionAirfoil = undefined;
            const tip_index = if (saved.tip.len > 0) tab.indexOf(saved.tip.text()) else null;
            if (tip_index) |index| tip = stage.wingSection(tab.candidates[index]);
            wing_line.analyze(saved.wing, &root, if (tip_index != null) &tip else null, conditions, &tab.saved_results[k]);
            tab.saved_ok[k] = true;
        }
    }

    fn indexOf(tab: *const WingTab, name: []const u8) ?usize {
        for (tab.candidates[0..tab.candidate_count], 0..) |candidate, k| if (std.mem.eql(u8, candidate.name, name)) return k;
        return null;
    }

    fn addChoice(tab: *WingTab, candidate: *const stage.Candidate, root_writer: *std.Io.Writer, tip_writer: *std.Io.Writer) void {
        if (tab.candidate_count == max_choices) return;
        const separator = if (tab.candidate_count > 0) ";" else "";
        root_writer.print("{s}{s}", .{ separator, candidate.name }) catch return;
        tip_writer.print(";{s}", .{candidate.name}) catch return;
        tab.candidates[tab.candidate_count] = candidate;
        tab.candidate_count += 1;
    }

    /// roda a etapa Asa com o que está no formulário
    pub fn run(tab: *WingTab) void {
        tab.has_result = false;
        if (tab.candidate_count == 0) {
            tab.setMessage("nenhum perfil: acrescente um em Perfis", .{});
            return;
        }
        const root_index: usize = @intCast(std.math.clamp(tab.field(.root_airfoil).choice, 0, @as(i32, @intCast(tab.candidate_count - 1))));
        const tip_choice = tab.field(.tip_airfoil).choice;
        const root = stage.wingSection(tab.candidates[root_index]);
        if (!std.mem.eql(u8, tab.design.rootAirfoil(), tab.candidates[root_index].name)) {
            tab.design.setRoot(tab.candidates[root_index].name);
            tab.seen_version = tab.design.version;
        }
        _ = widgets.format(&tab.root_name, "{s}", .{tab.candidates[root_index].name});
        var tip: wing_line.SectionAirfoil = undefined;
        tab.tip_used = tip_choice > 0 and tip_choice <= tab.candidate_count and @as(usize, @intCast(tip_choice - 1)) != root_index;
        if (tab.tip_used) {
            const tip_candidate = tab.candidates[@intCast(tip_choice - 1)];
            tip = stage.wingSection(tip_candidate);
            _ = widgets.format(&tab.tip_name, "{s}", .{tip_candidate.name});
        }
        const trapezoid: wing_line.Trapezoid = .{
            .span = tab.field(.span).number,
            .area = tab.field(.area).number,
            .root_chord = tab.field(.root_chord).number,
            .size_by_chord = tab.field(.size_by).choice == 1,
            .taper = tab.field(.taper).number,
            .rect_fraction = tab.field(.rect_fraction).number,
            .sweep = tab.field(.sweep).number,
            .twist = tab.field(.twist).number,
            .alpha_cruise = tab.field(.alpha_cruise).number,
        };
        const requirements: design_mod.Requirements = .{
            .mass = tab.field(.mass).number,
            .airspeed = tab.field(.airspeed).number,
            .altitude = tab.field(.altitude).number,
            .wing_density = tab.field(.wing_density).number,
        };
        // a asa e as condições valem para o projeto inteiro (a etapa Perfis tira o Reynolds daqui)
        tab.design.wing = trapezoid;
        tab.design.requirements = requirements;
        tab.design.touch();
        tab.seen_version = tab.design.version;
        const conditions = requirements.conditions();
        wing_line.analyze(trapezoid, &root, if (tab.tip_used) &tip else null, conditions, &tab.result);
        tab.has_result = true;
        tab.buildShapes(trapezoid);
        tab.buildWing(trapezoid, tab.candidates[root_index], if (tab.tip_used) tab.candidates[@intCast(tip_choice - 1)] else null);
        tab.setMessage("C_L,max {d:.3} · V de estol {d:.2} m/s · L/D no cruzeiro {d:.1}", .{ tab.result.lift_max, tab.result.stall_speed, tab.result.ld_cruise });
    }

    /// a asa do 3D: um avião só com ela (sem trem, fuselagem nem motor, como o `_only_wing` da GUI em Python),
    /// com as seções da planta e o contorno dos perfis da raiz e da ponta
    fn buildWing(tab: *WingTab, trapezoid: wing_line.Trapezoid, root: *const stage.Candidate, tip: ?*const stage.Candidate) void {
        if (tab.mesh) |*old| old.deinit();
        tab.mesh = null;
        const planform = wing_line.planformOf(trapezoid, tip != null);
        for (planform.sections[0..planform.count], 0..) |station, k| {
            const at_tip = k == planform.count - 1;
            tab.sections[k] = .{ .y = station.y, .chord = station.chord, .x_offset = station.offset, .twist = station.twist, .airfoil = if (at_tip and tip != null) .{ .name = tip.?.name, .coords = tip.?.outline } else null };
        }
        const surfaces = [_]model.Surface{.{ .name = "asa", .sections = tab.sections[0..planform.count], .airfoil = .{ .name = root.name, .coords = root.outline } }};
        const plane: model.Aircraft = .{ .name = "prévia", .surfaces = &surfaces, .gear = .{ .layout = "custom" } };
        var diagnosis: assembly.Diagnosis = .{};
        tab.mesh = assembly.buildMesh(std.heap.page_allocator, &plane, &diagnosis) catch null;
    }

    /// a planta em escala (as duas semiasas: bordo de ataque e de fuga) e as retas de referência dos gráficos
    fn buildShapes(tab: *WingTab, trapezoid: wing_line.Trapezoid) void {
        const planform = wing_line.planformOf(trapezoid, false);
        const list = planform.sections[0..planform.count];
        var count: usize = 0;
        // bordo de ataque da ponta esquerda à direita, depois o de fuga de volta (x para trás = para baixo)
        var k: usize = list.len;
        while (k > 0) {
            k -= 1;
            tab.outline_x[count] = -list[k].y;
            tab.outline_y[count] = -list[k].offset;
            count += 1;
        }
        for (list[1..]) |station| {
            tab.outline_x[count] = station.y;
            tab.outline_y[count] = -station.offset;
            count += 1;
        }
        k = list.len;
        while (k > 0) {
            k -= 1;
            tab.outline_x[count] = list[k].y;
            tab.outline_y[count] = -(list[k].offset + list[k].chord);
            count += 1;
        }
        for (list[1..]) |station| {
            tab.outline_x[count] = -station.y;
            tab.outline_y[count] = -(station.offset + station.chord);
            count += 1;
        }
        tab.outline_x[count] = tab.outline_x[0];
        tab.outline_y[count] = tab.outline_y[0];
        tab.outline_count = count + 1;
        const r = &tab.result;
        tab.cruise_line = .{ .{ r.lift_cruise, r.lift_cruise }, .{ 0, r.ld_max } };
        tab.onset_x = .{ r.stall_fraction, r.stall_fraction };
        var low: f64 = 0;
        var high: f64 = 0;
        for (0..wing_line.stations) |i| {
            low = @min(low, @min(r.cl_cruise[i], r.cl_stall[i]));
            high = @max(high, @max(r.cl_stall[i], r.cl_max_local[i]));
        }
        tab.onset_y = .{ low, high };
    }

    /// desenha a aba em `rect`
    pub fn draw(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        tab.syncDesign();
        const sidebar_width: f32 = 360;
        tab.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
        tab.drawPlots(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
    }

    /// a barra lateral: o formulário, "Guardar asa" e as guardadas, tudo numa área que rola; embaixo, os números
    fn drawSidebar(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const design = tab.design;
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const footer_height: f32 = 48;
        const body: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - footer_height - 4 };
        const x = rect.x + 12;
        const width = rect.width - 24 - 10;
        const top = tab.side.begin(ui, body);
        var y = top;
        if (tab.form.fields.len > 0) {
            if (tab.form.drawAt(ui, rect.x, y, body.width - 10)) tab.run();
            y += tab.form.contentHeight();
        }
        // guardar a asa em desenho e as guardadas (a etapa Empenagem parte de uma delas)
        var caption: [96:0]u8 = undefined;
        if (widgets.primaryButton(ui, .{ .x = x, .y = y, .width = width, .height = 32 }, widgets.format(&caption, "Guardar asa  ({s})", .{design.wing_name.text()}), tab.has_result)) {
            const tip = if (tab.tip_used) std.mem.sliceTo(&tab.tip_name, 0) else "";
            const name = design.wing_name;
            if (design.keepWing(std.mem.sliceTo(&tab.root_name, 0), tip)) tab.setMessage("guardada: {s}", .{name.text()}) else tab.setMessage("a lista de asas está cheia", .{});
        }
        y += 44;
        theme.text(ui.fonts.regular, widgets.format(&caption, "Guardadas ({d}):", .{design.wing_count}), x, y, 14, theme.colors.ink);
        y += 22;
        var labels: [design_mod.max_wings][:0]const u8 = undefined;
        var label_text: [design_mod.max_wings][96:0]u8 = undefined;
        for (design.wings[0..design.wing_count], 0..) |*saved, k| {
            const planform = wing_line.planformOf(saved.wing, false);
            labels[k] = widgets.format(&label_text[k], "{s}   (b {d:.2} m · c {d:.3} m · {s})", .{ saved.name.text(), 2 * planform.semispan, planform.root_chord, saved.root.text() });
        }
        tab.kept_selected = @min(tab.kept_selected, design.wing_count -| 1);
        if (tab.kept.draw(ui, .{ .x = x, .y = y, .width = width, .height = 100 }, labels[0..design.wing_count], tab.kept_selected)) |picked| tab.kept_selected = picked;
        y += 108;
        var pressed: f32 = 0;
        const actions = [_][:0]const u8{ "Carregar no rascunho", "Apagar" };
        if (ui_kit.menus.buttonGrid(ui, x, y, width, &actions, 2, &pressed)) |button| {
            if (design.wing_count > 0) {
                if (button == 0) {
                    const saved = design.wings[tab.kept_selected];
                    // a ponta da guardada fica escolhida quando as escolhas se refazem
                    _ = widgets.format(&tab.tip_name, "{s}", .{saved.tip.text()});
                    tab.tip_used = saved.tip.len > 0;
                    design.loadWing(tab.kept_selected);
                    tab.setMessage("no rascunho: {s}", .{saved.name.text()});
                } else design.removeWing(tab.kept_selected);
            }
        }
        y += pressed + 8;
        tab.side.end(ui, body, y);
        if (tab.form.drawOpen(ui)) tab.run();
        rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height }, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = 1 }, theme.colors.line);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), rect.x + 12, rect.y + rect.height - footer_height + 16, 13, theme.colors.label);
    }

    fn drawPlots(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 300;
        const view_height: f32 = 320;
        const summary_height: f32 = 380;
        const content_height = view_height + gap + 3 * (row_height + gap) + summary_height + 2 * gap;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        tab.plots.content_height = content_height;
        if (tab.scroll > 0) { // a rolagem pedida na linha de comando (prints)
            tab.plots.offset = tab.scroll;
            tab.scroll = 0;
        }
        tab.plots.offset = std.math.clamp(tab.plots.offset, 0, @max(0, content_height - rect.height));
        // a asa em 3D primeiro; a imagem sai numa textura, feita antes do recorte da coluna
        const view_card: rl.Rectangle = .{ .x = x0, .y = rect.y + gap - tab.plots.offset, .width = rect.width - 2 * gap, .height = view_height };
        const view_area = cardInside(view_card);
        if (tab.mesh) |*wing| {
            tab.view.handleInput(ui, view_area);
            const size = wing.size();
            const middle = wing.center();
            if (tab.view.begin(view_area, middle, 0.8 * size)) {
                defer tab.view.end();
                view3d.floor(.{ middle[0], middle[1], 0 }, wing.high[2] + 0.05 * size, 1.4 * size, 0.25);
                wing.draw();
                view3d.bodyAxes(&tab.view, .{ wing.low[0] - 0.25 * size, wing.low[1], wing.high[2] }, 0.1 * size);
            }
        }
        const top = tab.plots.begin(ui, rect);
        defer tab.plots.end(ui, rect, top + content_height);
        if (!tab.has_result) {
            theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), rect.x + 40, rect.y + 40, 16, theme.colors.muted);
            return;
        }
        const r = &tab.result;
        const n = r.alpha_count;
        var title_buffer: [160]u8 = undefined;
        const area = if (tab.mesh != null) wing_line.planformOf(tab.design.wing, false) else null;
        _ = widgets.card(ui, view_card, if (area) |planform| widgets.format(&title_buffer, "A asa: envergadura {d:.2} m · corda da raiz {d:.3} m · ponta {d:.3} m (arraste para girar, roda para aproximar)", .{ 2 * planform.semispan, planform.root_chord, planform.tip_chord }) else "A asa");
        if (tab.mesh != null) tab.view.blit(ui, view_area);
        var y = top + gap + view_height + gap;
        // a asa em desenho, grossa, e as guardadas (menos a de mesmo nome), tracejadas, para comparar
        var name_buffer: [Name.capacity + 1:0]u8 = undefined;
        const name = widgets.format(&name_buffer, "{s}", .{tab.design.wing_name.text()});
        var lift_series: [1 + design_mod.max_wings]plot.Series = undefined;
        var ld_series: [2 + design_mod.max_wings]plot.Series = undefined;
        var saved_names: [design_mod.max_wings][Name.capacity + 1:0]u8 = undefined;
        lift_series[0] = .{ .name = name, .xs = r.alpha[0..n], .ys = r.lift[0..n], .color_index = 0 };
        ld_series[0] = .{ .name = name, .xs = r.lift[0..n], .ys = r.ld[0..n], .color_index = 0 };
        ld_series[1] = .{ .name = "C_L de cruzeiro", .xs = &tab.cruise_line[0], .ys = &tab.cruise_line[1], .color_index = 7, .dashed = true };
        var compared: usize = 0;
        for (tab.design.wings[0..tab.design.wing_count], 0..) |*saved, k| {
            if (!tab.saved_ok[k] or std.mem.eql(u8, saved.name.text(), tab.design.wing_name.text())) continue;
            const other = &tab.saved_results[k];
            const count = other.alpha_count;
            const label = widgets.format(&saved_names[compared], "{s}", .{saved.name.text()});
            lift_series[1 + compared] = .{ .name = label, .xs = other.alpha[0..count], .ys = other.lift[0..count], .color_index = 3 + compared, .dashed = true };
            ld_series[2 + compared] = .{ .name = label, .xs = other.lift[0..count], .ys = other.ld[0..count], .color_index = 3 + compared, .dashed = true };
            compared += 1;
        }
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "C_L × α da asa (até o estol)", .x_label = "α da raiz (°)", .y_label = "C_L" }, lift_series[0 .. 1 + compared]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "Polar da asa: induzido, perfil e total", .x_label = "C_D", .y_label = "C_L" }, &.{
            .{ .name = "total", .xs = r.drag[0..n], .ys = r.lift[0..n], .color_index = 0 },
            .{ .name = "induzido", .xs = r.induced[0..n], .ys = r.lift[0..n], .color_index = 1, .dashed = true },
            .{ .name = "perfil", .xs = r.profile[0..n], .ys = r.lift[0..n], .color_index = 2, .dashed = true },
        });
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "L/D × C_L (tracejado: cruzeiro)", .x_label = "C_L", .y_label = "L/D" }, ld_series[0 .. 2 + compared]);
        for (0..wing_line.stations) |i| {
            tab.max_line[0][i] = r.span_fraction[i];
            tab.max_line[1][i] = r.cl_max_local[i];
        }
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "c_l na envergadura: onde o estol começa", .x_label = "posição na semiasa (2y/b)", .y_label = "c_l" }, &.{
            .{ .name = "no cruzeiro", .xs = &r.span_fraction, .ys = &r.cl_cruise, .color_index = 0 },
            .{ .name = "no estol", .xs = &r.span_fraction, .ys = &r.cl_stall, .color_index = 1 },
            .{ .name = "c_l,max do perfil", .xs = &tab.max_line[0], .ys = &tab.max_line[1], .color_index = 1, .dashed = true },
            .{ .name = "onde começa", .xs = &tab.onset_x, .ys = &tab.onset_y, .color_index = 3, .dashed = true },
        });
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "Planta (vista de cima, em escala)", .x_label = "y (m)", .y_label = "x (m)", .equal_axes = true }, &.{
            .{ .name = "asa", .xs = tab.outline_x[0..tab.outline_count], .ys = tab.outline_y[0..tab.outline_count], .color_index = 0 },
        });
        tab.drawDiagnosis(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height });
        y += row_height + gap;
        tab.drawSummary(ui, .{ .x = x0, .y = y, .width = rect.width - 2 * gap, .height = summary_height });
    }

    fn drawDiagnosis(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Diagnóstico");
        const r = &tab.result;
        const columns = [_]f32{ inner.x, inner.x + 64, inner.x + 290 };
        var buffers: [5][96]u8 = undefined;
        const onset: widgets.Status = if (r.stall_fraction <= 0.5) .ok else if (r.stall_fraction <= 0.8) .atencao else .falha;
        const ratio = r.ld_cruise / r.ld_max;
        const Row = struct { status: widgets.Status, item: [:0]const u8, value: [:0]const u8 };
        var rows: [6]Row = undefined;
        var count: usize = 0;
        rows[count] = .{ .status = onset, .item = "onde o estol começa (≤ 0,5)", .value = widgets.format(&buffers[0], "2y/b = {d:.2}{s}", .{ r.stall_fraction, if (onset == .ok) "" else ": mais washout ou menos afilamento" }) };
        count += 1;
        if (std.math.isFinite(r.ld_cruise) and r.ld_max > 0) {
            rows[count] = .{ .status = if (ratio >= 0.9) .ok else .atencao, .item = "cruzeiro perto do L/D máx. (≥ 90 %)", .value = widgets.format(&buffers[1], "{d:.0} %{s}", .{ 100 * ratio, if (ratio >= 0.9) "" else ": mude a área ou a velocidade" }) };
            count += 1;
        }
        if (r.lift_cruise > 0.85 * r.lift_max) {
            rows[count] = .{ .status = .falha, .item = "cruzeiro abaixo do estol (≤ 85 %)", .value = widgets.format(&buffers[2], "C_L {d:.2} de {d:.2}: mais área ou velocidade", .{ r.lift_cruise, r.lift_max }) };
            count += 1;
        }
        if (r.reynolds_tip < 8e4) {
            rows[count] = .{ .status = .atencao, .item = "Re na ponta (≥ 80 000)", .value = widgets.format(&buffers[3], "{d:.0}: afilamento menor ou corda maior", .{r.reynolds_tip}) };
            count += 1;
        }
        rows[count] = .{ .status = .info, .item = "método", .value = "linha sustentadora de Glauert" };
        count += 1;
        var y = inner.y;
        for (rows[0..count]) |row| {
            const labels = [_][:0]const u8{ @tagName(row.status), row.item, row.value };
            const colors = [_]rl.Color{ widgets.statusColor(row.status), theme.colors.ink, theme.colors.label };
            widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
    }

    fn drawSummary(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Números da asa");
        const r = &tab.result;
        var values: [14][96]u8 = undefined;
        var airfoil_text: [160]u8 = undefined;
        const rows = [_][2][:0]const u8{
            .{ "b, S, AR", widgets.format(&values[0], "{d:.3} m · {d:.4} m² · {d:.3}", .{ r.span, r.area, r.aspect_ratio }) },
            .{ "corda da raiz, da ponta, CMA (m)", widgets.format(&values[1], "{d:.4} · {d:.4} · {d:.4}", .{ r.root_chord, r.tip_chord, r.mean_chord }) },
            .{ "perfil (polar por modelo ou arquivo)", if (tab.tip_used) widgets.format(&airfoil_text, "{s} → {s} (Re {d:.0})", .{ std.mem.sliceTo(&tab.root_name, 0), std.mem.sliceTo(&tab.tip_name, 0), r.reynolds }) else widgets.format(&airfoil_text, "{s} (Re {d:.0})", .{ std.mem.sliceTo(&tab.root_name, 0), r.reynolds }) },
            .{ "C_Lα (1/rad), C_L0, α_L0 (°)", widgets.format(&values[2], "{d:.4} · {d:.4} · {d:.3}", .{ r.lift_slope, r.lift_zero, r.alpha_zero }) },
            .{ "C_L,max, α de estol (°)", widgets.format(&values[3], "{d:.4} · {d:.3}", .{ r.lift_max, r.alpha_stall }) },
            .{ "estol começa em (2y/b)", widgets.format(&values[4], "{d:.3}", .{r.stall_fraction}) },
            .{ "Oswald e (no cruzeiro)", widgets.format(&values[5], "{d:.4}", .{r.oswald}) },
            .{ "(L/D) máx., C_L nele", widgets.format(&values[6], "{d:.3} · {d:.4}", .{ r.ld_max, r.lift_at_ld }) },
            .{ "cruzeiro: C_L, α da asa (°), L/D", widgets.format(&values[7], "{d:.4} · {d:.3} · {d:.3}", .{ r.lift_cruise, r.alpha_cruise, r.ld_cruise }) },
            .{ "incidência da asa (°)", widgets.format(&values[8], "{d:.3}", .{r.incidence}) },
            .{ "V de estol (massa estimada, m/s)", widgets.format(&values[9], "{d:.3}", .{r.stall_speed}) },
            .{ "carga alar (kg/m²), massa da asa (kg)", widgets.format(&values[10], "{d:.3} · {d:.3}", .{ r.wing_loading, r.wing_mass }) },
            .{ "Re na raiz, na ponta", widgets.format(&values[11], "{d:.0} · {d:.0}", .{ r.reynolds_root, r.reynolds_tip }) },
            .{ "C_m,ac da asa", widgets.format(&values[12], "{d:.4}", .{r.moment}) },
        };
        const columns = [_]f32{ inner.x, inner.x + 340 };
        const colors = [_]rl.Color{ theme.colors.label, theme.colors.ink };
        var y = inner.y;
        for (rows) |row| {
            widgets.tableRow(ui, y, &columns, &row, &colors, 14);
            y += 24;
        }
    }
};

/// a parte de dentro de um cartão onde vai a imagem 3D (abaixo do título)
fn cardInside(rect: rl.Rectangle) rl.Rectangle {
    return .{ .x = rect.x + 4, .y = rect.y + 34, .width = rect.width - 8, .height = rect.height - 40 };
}

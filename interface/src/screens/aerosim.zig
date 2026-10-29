//! A tela do aerosim: cabeçalho, abas das áreas, subabas da Aerodinâmica e, em Analisar, o formulário lateral, o
//! botão Rodar e os gráficos. A conta é a varredura do núcleo (`wing_example.zig`); as outras abas ainda são só o
//! lugar delas.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../ui/theme.zig");
const shapes = @import("../ui/shapes.zig");
const widgets = @import("../ui/widgets.zig");
const form_mod = @import("../ui/form.zig");
const plot = @import("../ui/plot.zig");
const wing = @import("../wing_example.zig");

const areas = [_][:0]const u8{ "DIMENSIONAMENTO", "AERODINÂMICA", "ESTABILIDADE", "DESEMPENHO", "CARGAS", "MONTAGEM" };
const aero_tabs = [_][:0]const u8{ "PERFIS", "PROJETAR", "ANALISAR" };

const Group = enum(usize) { wing, airfoil, case, methods };

/// os índices dos campos (a ordem da lista `initial_fields`)
const FieldId = enum(usize) { span, root_chord, tip_chord, panels, lift_max, lift_slope, airspeed, density, alpha_start, alpha_end, alpha_step, alpha_load, use_lifting_line, use_strips, compare };

const initial_groups = [_]form_mod.Group{ .{ .title = "ASA" }, .{ .title = "PERFIL" }, .{ .title = "CASO" }, .{ .title = "MÉTODOS" } };

fn g(group: Group) usize {
    return @intFromEnum(group);
}

const initial_fields = [_]form_mod.Field{
    .{ .label = "envergadura", .unit = "m", .group = g(.wing), .number = 2.4, .minimum = 0.2, .maximum = 10 },
    .{ .label = "corda na raiz", .unit = "m", .group = g(.wing), .number = 0.42, .minimum = 0.02, .maximum = 3 },
    .{ .label = "corda na ponta", .unit = "m", .group = g(.wing), .number = 0.3, .minimum = 0.02, .maximum = 3 },
    .{ .label = "faixas (par, até 48)", .group = g(.wing), .number = 24, .minimum = 2, .maximum = 48 },
    .{ .label = "C_L máximo", .group = g(.airfoil), .number = 1.6, .minimum = 0.2, .maximum = 3 },
    .{ .label = "C_Lα", .unit = "1/rad", .group = g(.airfoil), .number = 2 * std.math.pi, .minimum = 1, .maximum = 8 },
    .{ .label = "velocidade", .unit = "m/s", .group = g(.case), .number = 12, .minimum = 1, .maximum = 80 },
    .{ .label = "densidade", .unit = "kg/m³", .group = g(.case), .number = 1.225, .minimum = 0.3, .maximum = 1.5 },
    .{ .label = "α inicial", .unit = "°", .group = g(.case), .number = -4, .minimum = -20, .maximum = 10 },
    .{ .label = "α final", .unit = "°", .group = g(.case), .number = 22, .minimum = 0, .maximum = 40 },
    .{ .label = "passo de α", .unit = "°", .group = g(.case), .number = 1, .minimum = 0.25, .maximum = 5 },
    .{ .label = "α da carga", .unit = "°", .group = g(.case), .number = 10, .minimum = -10, .maximum = 40 },
    .{ .label = "linha sustentadora não linear", .group = g(.methods), .kind = .toggle, .checked = true },
    .{ .label = "faixas independentes", .group = g(.methods), .kind = .toggle, .checked = true },
    .{ .label = "comparar com", .group = g(.methods), .kind = .choice, .choices = "nenhum;lltdrek (Python);ASB VLM (Python)" },
};

pub const Screen = struct {
    groups: [initial_groups.len]form_mod.Group = initial_groups,
    fields: [initial_fields.len]form_mod.Field = initial_fields,
    form: form_mod.Form = undefined,
    area: usize = 1,
    aero_tab: usize = 2,
    result: wing.Result = .{},
    has_result: bool = false,
    message: [160:0]u8 = [_:0]u8{0} ** 160,
    progress: f32 = 0,
    scroll: f32 = 0,

    /// liga o formulário às listas da própria tela (chamar depois de pôr a tela no lugar final)
    pub fn init(screen: *Screen) void {
        screen.form = .{ .groups = &screen.groups, .fields = &screen.fields };
        screen.setMessage("pronto: ▶ RODAR roda a varredura no núcleo", .{});
    }

    fn field(screen: *Screen, id: FieldId) *form_mod.Field {
        return &screen.fields[@intFromEnum(id)];
    }

    fn setMessage(screen: *Screen, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&screen.message, fmt, args) catch {};
    }

    fn input(screen: *Screen) wing.Input {
        const panels: usize = @intFromFloat(@round(screen.field(.panels).number));
        return .{
            .span = screen.field(.span).number,
            .root_chord = screen.field(.root_chord).number,
            .tip_chord = screen.field(.tip_chord).number,
            .panel_count = panels - panels % 2,
            .lift_max = screen.field(.lift_max).number,
            .lift_slope = screen.field(.lift_slope).number,
            .airspeed = screen.field(.airspeed).number,
            .density = screen.field(.density).number,
            .alpha_start = screen.field(.alpha_start).number,
            .alpha_end = screen.field(.alpha_end).number,
            .alpha_step = screen.field(.alpha_step).number,
            .alpha_load = screen.field(.alpha_load).number,
        };
    }

    /// roda a varredura com os valores do formulário
    pub fn runAnalysis(screen: *Screen) void {
        const start = rl.getTime();
        wing.run(screen.input(), &screen.result) catch {
            screen.has_result = false;
            screen.progress = 0;
            screen.setMessage("não rodou: confira as faixas (par, até 48) e a faixa de α", .{});
            return;
        };
        screen.has_result = true;
        screen.progress = 1;
        const elapsed_ms = (rl.getTime() - start) * 1000;
        screen.setMessage("terminado: ok — {d:.1} ms no núcleo", .{elapsed_ms});
        if (screen.field(.compare).choice != 0)
            screen.setMessage("terminado: ok — {d:.1} ms; o método em Python ainda não está ligado", .{elapsed_ms});
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.background);
        // conteúdo primeiro, cabeçalho e abas por cima (a rolagem passa por baixo deles)
        const top = widgets.header_height + 38 + 32;
        const sidebar_width: f32 = 360;
        if (screen.area == 1 and screen.aero_tab == 2) {
            screen.drawSidebar(ui, .{ .x = 0, .y = top, .width = sidebar_width, .height = height - top });
            screen.drawPlots(ui, .{ .x = sidebar_width, .y = top, .width = width - sidebar_width, .height = height - top });
        } else {
            placeholder(ui, .{ .x = 0, .y = top, .width = width, .height = height - top }, if (screen.area == 1) aero_tabs[screen.aero_tab] else areas[screen.area]);
        }
        if (widgets.header(ui, width, "AEROSIM", &.{ "Abrir avião (.json)", "Salvar .json" }, "asa trapezoidal de exemplo · conta no núcleo em Zig")) |_|
            screen.setMessage("abrir e salvar o .json entram na próxima etapa", .{});
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, &areas, &screen.area, theme.black, 14);
        if (screen.area == 1) {
            _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, &aero_tabs, &screen.aero_tab, theme.sidebar, 13);
        } else {
            rl.drawRectangleRec(.{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, theme.sidebar);
        }
    }

    fn drawSidebar(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.sidebar);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 3, .y = rect.y, .width = 3, .height = rect.height }, theme.black);
        const footer_height: f32 = 92;
        const form_rect: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 3, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 3, .height = footer_height };
        rl.drawRectangleRec(footer, theme.black);
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 3 }, theme.orange);
        if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 }, "▶  RODAR", true)) screen.runAnalysis();
        shapes.hazard(.{ .x = footer.x + 12, .y = footer.y + 54, .width = footer.width - 24, .height = 7 }, screen.progress, theme.orange, theme.panel);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.message, 0), footer.x + 12, footer.y + 68, 13, theme.muted);
        // o formulário por último: a lista aberta de uma escolha fica por cima do rodapé
        if (screen.form.draw(ui, form_rect)) screen.runAnalysis();
    }

    fn drawPlots(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 420;
        const rows: f32 = 3;
        const content_height = rows * (row_height + gap) + gap;
        if (ui.hovering(rect)) screen.scroll = std.math.clamp(screen.scroll - ui.wheel * 60, 0, @max(0, content_height - rect.height));
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        defer rl.endScissorMode();
        if (!screen.has_result) {
            theme.text(ui.fonts.regular, "rode a análise para ver os gráficos", rect.x + 40, rect.y + 40, 16, theme.muted);
            return;
        }
        const r = &screen.result;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        var y = rect.y + gap - screen.scroll;
        const n = r.alpha_count;
        const k = r.panel_count;
        const use_ll = screen.field(.use_lifting_line).checked;
        const use_strips = screen.field(.use_strips).checked;

        var curves: [2]plot.Series = undefined;
        var count: usize = 0;
        if (use_ll) {
            curves[count] = .{ .name = "linha sustentadora não linear", .xs = r.alphas_deg[0..n], .ys = r.lifting_line.lift[0..n], .color_index = 0 };
            count += 1;
        }
        if (use_strips) {
            curves[count] = .{ .name = "faixas independentes", .xs = r.alphas_deg[0..n], .ys = r.strips.lift[0..n], .color_index = 1, .dashed = true };
            count += 1;
        }
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "C_L do conjunto × α", .x_label = "α (°)", .y_label = "C_L" }, curves[0..count]);
        screen.drawPlanform(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height });
        y += row_height + gap;

        count = 0;
        var loads: [2]plot.Series = undefined;
        if (use_ll) {
            curves[count] = .{ .name = "linha sustentadora não linear", .xs = r.panel_span[0..k], .ys = r.section_cl_lifting_line[0..k], .color_index = 0 };
            loads[count] = .{ .name = "linha sustentadora não linear", .xs = r.panel_span[0..k], .ys = r.load_lifting_line[0..k], .color_index = 0 };
            count += 1;
        }
        if (use_strips) {
            curves[count] = .{ .name = "faixas independentes", .xs = r.panel_span[0..k], .ys = r.section_cl_strips[0..k], .color_index = 1, .dashed = true };
            loads[count] = .{ .name = "faixas independentes", .xs = r.panel_span[0..k], .ys = r.load_strips[0..k], .color_index = 1, .dashed = true };
            count += 1;
        }
        var title_buffer: [96]u8 = undefined;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = widgets.format(&title_buffer, "c_l ao longo da envergadura (α = {d:.1}°)", .{screen.field(.alpha_load).number}), .x_label = "y (m)", .y_label = "c_l" }, curves[0..count]);
        var load_title: [96]u8 = undefined;
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = widgets.format(&load_title, "Carga ao longo da envergadura (α = {d:.1}°)", .{screen.field(.alpha_load).number}), .x_label = "y (m)", .y_label = "L' (N/m)" }, loads[0..count]);
        y += row_height + gap;

        screen.drawDiagnosis(ui, .{ .x = x0, .y = y, .width = column_width, .height = 300 });
        screen.drawSummary(ui, .{ .x = x1, .y = y, .width = column_width, .height = 300 });
    }

    /// vista de cima da asa: as faixas pintadas pelo c_l no α da carga (linha sustentadora)
    fn drawPlanform(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.card(ui, rect, "Vista de cima: c_l no α da carga (linha sustentadora)");
        const r = &screen.result;
        const in = screen.input();
        const scale = @min((inner.width - 40) / @as(f32, @floatCast(in.span)), (inner.height - 80) / @as(f32, @floatCast(in.root_chord * 1.6)));
        const center_x = inner.x + inner.width / 2;
        const leading_y = inner.y + 30;
        var low: f64 = std.math.inf(f64);
        var high: f64 = -std.math.inf(f64);
        for (r.section_cl_lifting_line[0..r.panel_count]) |v| {
            low = @min(low, v);
            high = @max(high, v);
        }
        const width = in.span / @as(f64, @floatFromInt(r.panel_count));
        for (0..r.panel_count) |i| {
            const y_mid = r.panel_span[i];
            const y_a = y_mid - width / 2;
            const y_b = y_mid + width / 2;
            const chord_a = wing.chordAt(in, y_a);
            const chord_b = wing.chordAt(in, y_b);
            // linha de 1/4 de corda reta: o bordo de ataque fica c/4 à frente dela
            const xa: f32 = center_x + @as(f32, @floatCast(y_a)) * scale;
            const xb: f32 = center_x + @as(f32, @floatCast(y_b)) * scale;
            const quarter = leading_y + @as(f32, @floatCast(in.root_chord * 0.25)) * scale;
            const top_a = quarter - @as(f32, @floatCast(chord_a * 0.25)) * scale;
            const top_b = quarter - @as(f32, @floatCast(chord_b * 0.25)) * scale;
            const bottom_a = quarter + @as(f32, @floatCast(chord_a * 0.75)) * scale;
            const bottom_b = quarter + @as(f32, @floatCast(chord_b * 0.75)) * scale;
            const t: f32 = if (high > low) @floatCast((r.section_cl_lifting_line[i] - low) / (high - low)) else 0.5;
            const color = blend(theme.hex(0x4dabf7), theme.orange, t);
            const quad = [_]rl.Vector2{ .{ .x = xa, .y = top_a }, .{ .x = xa, .y = bottom_a }, .{ .x = xb, .y = bottom_b }, .{ .x = xb, .y = top_b } };
            rl.drawTriangleFan(&quad, color);
            rl.drawLineEx(.{ .x = xb, .y = top_b }, .{ .x = xb, .y = bottom_b }, 1, theme.panel);
        }
        var buffer: [96]u8 = undefined;
        theme.text(ui.fonts.mono, widgets.format(&buffer, "c_l de {d:.2} (azul) a {d:.2} (laranja)", .{ low, high }), inner.x + 10, inner.y + inner.height - 40, 13, theme.muted);
        theme.text(ui.fonts.mono, widgets.format(&buffer, "S = {d:.3} m²   b = {d:.2} m   A = {d:.2}", .{ r.area, in.span, r.aspect_ratio }), inner.x + 10, inner.y + inner.height - 20, 13, theme.muted);
    }

    fn drawDiagnosis(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "DIAGNÓSTICO");
        const r = &screen.result;
        var buffers: [3][96]u8 = undefined;
        const ll = r.lifting_line.summary;
        const peak_alpha = r.alphas_deg[ll.peak];
        const at_end = ll.peak + 1 == r.alpha_count;
        const columns = [_]f32{ inner.x, inner.x + 80, inner.x + 330 };
        var y = inner.y;
        const rows = [_]struct { status: widgets.Status, item: [:0]const u8, value: [:0]const u8 }{
            .{ .status = if (at_end) .info else .ok, .item = "C_L máximo (linha sustentadora)", .value = widgets.format(&buffers[0], "{d:.3} a {d:.1}°{s}", .{ ll.lift_max, peak_alpha, if (at_end) " (fim da varredura)" else "" }) },
            .{ .status = if (ll.onset_panel != null and ll.onset_fraction < 0.5) .ok else if (ll.onset_panel == null) .info else .atencao, .item = "onde o estol começa", .value = if (ll.onset_panel != null) widgets.format(&buffers[1], "y/(b/2) = {d:.2} ({s})", .{ ll.onset_fraction, if (ll.onset_fraction < 0.5) "da raiz para fora" else "perto da ponta" }) else "não começou na varredura" },
            .{ .status = if (r.reynolds > 7e4) .ok else .atencao, .item = "Reynolds na corda média", .value = widgets.format(&buffers[2], "{d:.0}", .{r.reynolds}) },
        };
        for (rows) |row| {
            const labels = [_][:0]const u8{ @tagName(row.status), row.item, row.value };
            const colors = [_]rl.Color{ widgets.statusColor(row.status), theme.ink, theme.label };
            widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.grid);
        }
    }

    fn drawSummary(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "RESUMO");
        const r = &screen.result;
        var buffers: [6][64]u8 = undefined;
        const columns = [_]f32{ inner.x, inner.x + 300 };
        const colors = [_]rl.Color{ theme.label, theme.ink };
        const rows = [_][2][:0]const u8{
            .{ "área (m²)", widgets.format(&buffers[0], "{d:.4}", .{r.area}) },
            .{ "corda média aerodinâmica (m)", widgets.format(&buffers[1], "{d:.4}", .{r.mean_chord}) },
            .{ "alongamento", widgets.format(&buffers[2], "{d:.3}", .{r.aspect_ratio}) },
            .{ "C_L máximo, linha sustentadora", widgets.format(&buffers[3], "{d:.4}", .{r.lifting_line.summary.lift_max}) },
            .{ "C_L máximo, faixas independentes", widgets.format(&buffers[4], "{d:.4}", .{r.strips.summary.lift_max}) },
            .{ "ângulos na varredura", widgets.format(&buffers[5], "{d}", .{r.alpha_count}) },
        };
        var y = inner.y;
        for (rows) |row| {
            widgets.tableRow(ui, y, &columns, &row, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.grid);
        }
    }
};

fn blend(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const s = std.math.clamp(t, 0, 1);
    const mix = struct {
        fn f(x: u8, y: u8, k: f32) u8 {
            return @intFromFloat(@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(x))) * k);
        }
    };
    return .{ .r = mix.f(a.r, b.r, s), .g = mix.f(a.g, b.g, s), .b = mix.f(a.b, b.b, s), .a = 255 };
}

/// o lugar de uma aba que ainda não foi feita
fn placeholder(ui: *widgets.Ui, rect: rl.Rectangle, name: [:0]const u8) void {
    const box: rl.Rectangle = .{ .x = rect.x + 40, .y = rect.y + 40, .width = @min(rect.width - 80, 620), .height = 150 };
    const inner = widgets.labeledCard(ui, box, name);
    theme.text(ui.fonts.regular, "esta aba ainda não foi feita em Zig; o desenho segue o mesmo tema", inner.x, inner.y + 10, 15, theme.label);
}

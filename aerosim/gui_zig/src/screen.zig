//! A tela do aerosim: cabeçalho, abas das áreas, subabas da Aerodinâmica e, em Analisar, o formulário lateral, o
//! botão Rodar e os gráficos. A conta é a varredura do núcleo (`wing_example.zig`); as outras abas ainda são só o
//! lugar delas.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const shapes = ui_kit.shapes;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const numbers = ui_kit.numbers;
const view3d = ui_kit.view3d;
const wing = @import("wing_example.zig");

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
    load_view: view3d.View = .{}, // a vista 3D da asa e da carga (Analisar)
    assembly_view: view3d.View = .{}, // a vista 3D da Montagem

    /// abre a aba de área `index` (0 = Dimensionamento ... 5 = Montagem), para os prints
    pub fn selectTab(screen: *Screen, index: usize) void {
        screen.area = @min(index, areas.len - 1);
    }

    /// liga o formulário às listas da própria tela e roda a análise uma vez (chamar com a janela aberta e a tela
    /// já no lugar final)
    pub fn start(screen: *Screen) void {
        screen.form = .{ .groups = &screen.groups, .fields = &screen.fields };
        screen.runAnalysis();
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
        const started = rl.getTime();
        wing.run(screen.input(), &screen.result) catch {
            screen.has_result = false;
            screen.progress = 0;
            screen.setMessage("não rodou: confira as faixas (par, até 48) e a faixa de α", .{});
            return;
        };
        screen.has_result = true;
        screen.progress = 1;
        const elapsed_ms = (rl.getTime() - started) * 1000;
        screen.setMessage("terminado: ok — {d:.1} ms no núcleo", .{elapsed_ms});
        if (screen.field(.compare).choice != 0)
            screen.setMessage("terminado: ok — {d:.1} ms; o método em Python ainda não está ligado", .{elapsed_ms});
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.colors.background);
        // conteúdo primeiro, cabeçalho e abas por cima (a rolagem passa por baixo deles)
        const top = widgets.header_height + 38 + 32;
        const sidebar_width: f32 = 360;
        if (screen.area == 1 and screen.aero_tab == 2) {
            screen.drawSidebar(ui, .{ .x = 0, .y = top, .width = sidebar_width, .height = height - top });
            screen.drawPlots(ui, .{ .x = sidebar_width, .y = top, .width = width - sidebar_width, .height = height - top });
        } else if (screen.area == 5) {
            screen.drawAssembly(ui, .{ .x = 0, .y = top, .width = width, .height = height - top });
        } else {
            placeholder(ui, .{ .x = 0, .y = top, .width = width, .height = height - top }, if (screen.area == 1) aero_tabs[screen.aero_tab] else areas[screen.area]);
        }
        if (widgets.header(ui, width, "AEROSIM", &.{ "Abrir avião (.json)", "Salvar .json" }, "asa trapezoidal de exemplo · conta no núcleo em Zig")) |_|
            screen.setMessage("abrir e salvar o .json entram na próxima etapa", .{});
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, &areas, &screen.area, theme.colors.strip, 14);
        if (screen.area == 1) {
            _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, &aero_tabs, &screen.aero_tab, theme.colors.sidebar, 13);
        } else {
            rl.drawRectangleRec(.{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, theme.colors.sidebar);
        }
    }

    fn drawSidebar(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.colors.sidebar);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 3, .y = rect.y, .width = 3, .height = rect.height }, theme.colors.strip);
        const footer_height: f32 = 92;
        const form_rect: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 3, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 3, .height = footer_height };
        rl.drawRectangleRec(footer, theme.colors.strip);
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 3 }, theme.colors.accent);
        if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 }, "▶  RODAR", true)) screen.runAnalysis();
        shapes.hazard(.{ .x = footer.x + 12, .y = footer.y + 54, .width = footer.width - 24, .height = 7 }, screen.progress, theme.colors.hazard, theme.colors.panel);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.message, 0), footer.x + 12, footer.y + 68, 13, theme.colors.strip_label);
        // o formulário por último: a lista aberta de uma escolha fica por cima do rodapé
        if (screen.form.draw(ui, form_rect)) screen.runAnalysis();
    }

    fn drawPlots(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 420;
        const rows: f32 = 3;
        const content_height = rows * (row_height + gap) + gap;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        var y = rect.y + gap - screen.scroll;
        // a vista 3D usa a roda antes da rolagem da página, e a textura é desenhada fora do recorte
        const view_card: rl.Rectangle = .{ .x = x1, .y = y, .width = column_width, .height = row_height };
        if (screen.has_result) {
            const view_area = cardInside(view_card);
            screen.load_view.handleInput(ui, view_area);
            screen.renderWing(&screen.load_view, view_area, true);
        }
        if (ui.hovering(rect)) screen.scroll = std.math.clamp(screen.scroll - ui.wheel * 60, 0, @max(0, content_height - rect.height));
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        defer rl.endScissorMode();
        if (!screen.has_result) {
            theme.text(ui.fonts.regular, "rode a análise para ver os gráficos", rect.x + 40, rect.y + 40, 16, theme.colors.muted);
            return;
        }
        const r = &screen.result;
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
        screen.drawLoadView(ui, view_card);
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

        screen.drawPlanform(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height });
        screen.drawDiagnosis(ui, .{ .x = x1, .y = y, .width = column_width, .height = 160 });
        screen.drawSummary(ui, .{ .x = x1, .y = y + 172, .width = column_width, .height = row_height - 172 });
    }

    /// a asa de exemplo em 3D na cor da asa, com as arestas das faixas, o chão e os eixos do corpo; com
    /// `with_loads`, um vetor de sustentação por faixa no 1/4 de corda (a maior seta = 18 % da envergadura, como na
    /// vista de cargas em Python)
    fn renderWing(screen: *Screen, view: *view3d.View, area: rl.Rectangle, with_loads: bool) void {
        const in = screen.input();
        const size = in.span;
        if (!view.begin(area, .{ -0.25 * in.root_chord, 0, if (with_loads) -0.08 * size else 0 }, size)) return;
        defer view.end();
        const half = 0.5 * in.span;
        view3d.floor(.{ 0, 0, 0 }, 0.3, 1.5 * size, 0.25);
        const color = view3d.kindColor(.wing);
        const edge = theme.withAlpha(theme.hex(0x333333), 0.35);
        const count = in.panel_count;
        const width = in.span / @as(f64, @floatFromInt(count));
        for (0..count) |i| {
            const y_a = -half + @as(f64, @floatFromInt(i)) * width;
            const y_b = y_a + width;
            const chord_a = wing.chordAt(in, y_a);
            const chord_b = wing.chordAt(in, y_b);
            const leading_a: view3d.Body = .{ 0.25 * chord_a, y_a, 0 };
            const trailing_a: view3d.Body = .{ -0.75 * chord_a, y_a, 0 };
            const leading_b: view3d.Body = .{ 0.25 * chord_b, y_b, 0 };
            const trailing_b: view3d.Body = .{ -0.75 * chord_b, y_b, 0 };
            view3d.quad(leading_a, trailing_a, trailing_b, leading_b, color);
            // as arestas um pouco acima e abaixo da placa (no plano dela, a profundidade as esconde)
            const lift_off = 0.002 * size;
            view3d.segment(.{ leading_a[0], y_a, -lift_off }, .{ trailing_a[0], y_a, -lift_off }, edge);
            view3d.segment(.{ leading_a[0], y_a, lift_off }, .{ trailing_a[0], y_a, lift_off }, edge);
        }
        view3d.bodyAxes(view, .{ -0.75 * in.root_chord - 0.12 * size, -half - 0.12 * size, 0.04 * size }, 0.14 * size);
        if (!with_loads or !screen.has_result) return;
        const loads = screen.result.load_lifting_line[0..screen.result.panel_count];
        var largest: f64 = 0;
        for (loads) |value| largest = @max(largest, @abs(value));
        if (!(largest > 1e-12)) return;
        const scale = 0.18 * size / largest;
        for (loads, 0..) |value, i| {
            // sustentação para cima (−z no corpo), na linha de 1/4 de corda (x = 0)
            view3d.arrow(.{ 0, screen.result.panel_span[i], 0 }, .{ 0, 0, -value * scale }, 0.022 * size, view3d.liftColor());
        }
    }

    /// o cartão da vista 3D com a carga: o título, a imagem e a escala das setas
    fn drawLoadView(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        var title_buffer: [96]u8 = undefined;
        const title = widgets.format(&title_buffer, "Asa e sustentação em 3D (α = {d:.1}°, linha sustentadora)", .{screen.field(.alpha_load).number});
        _ = widgets.card(ui, rect, title);
        const area = cardInside(rect);
        screen.load_view.blit(ui, area);
        var largest: f64 = 0;
        for (screen.result.load_lifting_line[0..screen.result.panel_count]) |value| largest = @max(largest, @abs(value));
        var note_buffer: [96]u8 = undefined;
        const note = widgets.format(&note_buffer, "sustentação: maior seta = {d:.3} N/m · arraste para girar, roda para aproximar", .{largest});
        theme.text(ui.fonts.regular, note, area.x + 6, area.y + area.height - 18, 12, theme.colors.muted);
    }

    /// a Montagem: por enquanto só a asa de exemplo em 3D (o avião inteiro entra quando a tela ler o .json)
    fn drawAssembly(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const card_rect: rl.Rectangle = .{ .x = rect.x + 12, .y = rect.y + 12, .width = rect.width - 24, .height = rect.height - 24 };
        const area = cardInside(card_rect);
        screen.assembly_view.handleInput(ui, area);
        screen.renderWing(&screen.assembly_view, area, false);
        _ = widgets.card(ui, card_rect, "Montagem em 3D");
        screen.assembly_view.blit(ui, area);
        theme.text(ui.fonts.regular, "só a asa de exemplo; o avião inteiro (fuselagem, cauda, motor) entra quando a tela ler o .json · arraste para girar, roda para aproximar", area.x + 6, area.y + area.height - 18, 12, theme.colors.muted);
    }

    /// a asa e a carga no α da carga (linha sustentadora), em dois quadros com o mesmo eixo da envergadura: em cima, a
    /// vista de cima em escala (mesmo metro por pixel nos dois eixos), na cor da asa, com as faixas; embaixo, a vista de
    /// frente com um vetor por faixa, de comprimento L' (N/m), na escala do eixo
    fn drawPlanform(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const r = &screen.result;
        const in = screen.input();
        var title_buffer: [96]u8 = undefined;
        const title = widgets.format(&title_buffer, "Asa e carga no α = {d:.1}° (linha sustentadora)", .{in.alpha_load});
        const inner = widgets.card(ui, rect, title);
        const top_height = inner.height * 0.42;
        const half = 0.5 * in.span;
        const span_range: numbers.Range = .{ .low = -half * 1.06, .high = half * 1.06 };
        // vista de cima: x do corpo para trás; no gráfico, −x para cima (o bordo de ataque fica em cima)
        const top = plot.drawFrame(ui, .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = top_height }, .{ .title = title, .x_label = "", .y_label = "−x (m)" }, span_range, .{ .low = -in.root_chord * 0.85, .high = in.root_chord * 0.35 }, 0, true);
        const width = in.span / @as(f64, @floatFromInt(r.panel_count));
        const outline = theme.colors.ink;
        for (0..r.panel_count) |i| {
            const y_a = r.panel_span[i] - width / 2;
            const y_b = r.panel_span[i] + width / 2;
            const chord_a = wing.chordAt(in, y_a);
            const chord_b = wing.chordAt(in, y_b);
            // linha de 1/4 de corda reta em x = 0: bordo de ataque em −c/4, de fuga em 3c/4
            const leading_a = top.toScreen(y_a, chord_a * 0.25);
            const trailing_a = top.toScreen(y_a, -chord_a * 0.75);
            const leading_b = top.toScreen(y_b, chord_b * 0.25);
            const trailing_b = top.toScreen(y_b, -chord_b * 0.75);
            rl.drawTriangleFan(&[_]rl.Vector2{ leading_a, trailing_a, trailing_b, leading_b }, view3d.kindColor(.wing)); // a cor da asa da vista 3D
            rl.drawLineEx(leading_a, trailing_a, 1, theme.withAlpha(theme.hex(0x333333), 0.35));
            rl.drawLineEx(leading_a, leading_b, 2, outline);
            rl.drawLineEx(trailing_a, trailing_b, 2, outline);
        }
        rl.drawLineEx(top.toScreen(-half, wing.chordAt(in, half) * 0.25), top.toScreen(-half, -wing.chordAt(in, half) * 0.75), 2, outline);
        rl.drawLineEx(top.toScreen(half, wing.chordAt(in, half) * 0.25), top.toScreen(half, -wing.chordAt(in, half) * 0.75), 2, outline);
        // vista de frente: um vetor de sustentação por faixa, no centro dela
        const loads = r.load_lifting_line[0..r.panel_count];
        var load_range = numbers.Range.of(loads, 0.08);
        load_range.low = @min(load_range.low, 0);
        load_range.high = @max(load_range.high, 0);
        const front = plot.drawFrame(ui, .{ .x = inner.x, .y = inner.y + top_height, .width = inner.width, .height = inner.height - top_height }, .{ .title = title, .x_label = "y (m)", .y_label = "L' (N/m)" }, top.x_range, load_range, 0, false);
        rl.drawLineEx(front.toScreen(-half, 0), front.toScreen(half, 0), 3, outline);
        const color = view3d.liftColor(); // a cor da sustentação da vista 3D
        for (0..r.panel_count) |i| {
            const base = front.toScreen(r.panel_span[i], 0);
            const tip = front.toScreen(r.panel_span[i], loads[i]);
            arrow(base, tip, color);
        }
    }

    fn drawDiagnosis(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "DIAGNÓSTICO");
        const r = &screen.result;
        var buffers: [3][96]u8 = undefined;
        const ll = r.lifting_line.summary;
        const peak_alpha = r.alphas_deg[ll.peak];
        const at_end = ll.peak + 1 == r.alpha_count;
        const columns = [_]f32{ inner.x, inner.x + 56, inner.x + 290 };
        var y = inner.y;
        const rows = [_]struct { status: widgets.Status, item: [:0]const u8, value: [:0]const u8 }{
            .{ .status = if (at_end) .info else .ok, .item = "C_L máximo (linha sustentadora)", .value = widgets.format(&buffers[0], "{d:.3} a {d:.1}°{s}", .{ ll.lift_max, peak_alpha, if (at_end) " (fim da varredura)" else "" }) },
            .{ .status = if (ll.onset_panel != null and ll.onset_fraction < 0.5) .ok else if (ll.onset_panel == null) .info else .atencao, .item = "onde o estol começa", .value = if (ll.onset_panel != null) widgets.format(&buffers[1], "y/(b/2) = {d:.2} ({s})", .{ ll.onset_fraction, if (ll.onset_fraction < 0.5) "da raiz para fora" else "perto da ponta" }) else "não começou na varredura" },
            .{ .status = if (r.reynolds > 7e4) .ok else .atencao, .item = "Reynolds na corda média", .value = widgets.format(&buffers[2], "{d:.0}", .{r.reynolds}) },
        };
        for (rows) |row| {
            const labels = [_][:0]const u8{ @tagName(row.status), row.item, row.value };
            const colors = [_]rl.Color{ widgets.statusColor(row.status), theme.colors.ink, theme.colors.label };
            widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
    }

    fn drawSummary(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "RESUMO");
        const r = &screen.result;
        var buffers: [6][64]u8 = undefined;
        const columns = [_]f32{ inner.x, inner.x + 300 };
        const colors = [_]rl.Color{ theme.colors.label, theme.colors.ink };
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
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
    }
};

/// a parte de dentro de um cartão onde vai a imagem 3D (abaixo do título)
fn cardInside(rect: rl.Rectangle) rl.Rectangle {
    return .{ .x = rect.x + 4, .y = rect.y + 34, .width = rect.width - 8, .height = rect.height - 40 };
}

/// vetor de `base` até `tip`, com a ponta em triângulo (some quando é mais curto que a ponta)
fn arrow(base: rl.Vector2, tip: rl.Vector2, color: rl.Color) void {
    const dx = tip.x - base.x;
    const dy = tip.y - base.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 1) return;
    const head = @min(9, length);
    const ux = dx / length;
    const uy = dy / length;
    const neck: rl.Vector2 = .{ .x = tip.x - ux * head, .y = tip.y - uy * head };
    rl.drawLineEx(base, neck, 2, color);
    const side = head * 0.45;
    const left: rl.Vector2 = .{ .x = neck.x - uy * side, .y = neck.y + ux * side };
    const right: rl.Vector2 = .{ .x = neck.x + uy * side, .y = neck.y - ux * side };
    rl.drawTriangle(tip, left, right, color);
    rl.drawTriangle(tip, right, left, color); // um dos dois sai na ordem certa, qualquer que seja o sentido
}

/// o lugar de uma aba que ainda não foi feita
fn placeholder(ui: *widgets.Ui, rect: rl.Rectangle, name: [:0]const u8) void {
    const box: rl.Rectangle = .{ .x = rect.x + 40, .y = rect.y + 40, .width = @min(rect.width - 80, 620), .height = 150 };
    const inner = widgets.labeledCard(ui, box, name);
    theme.text(ui.fonts.regular, "esta aba ainda não foi feita em Zig; o desenho segue o mesmo tema", inner.x, inner.y + 10, 15, theme.colors.label);
}

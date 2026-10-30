//! A aba Aerodinâmica → Analisar: as asas do avião aberto, como a simulação "Asas" do aerosim em Python. À
//! esquerda, quais superfícies entram, o caso (velocidade e α) e os métodos do núcleo; à direita, a vista 3D do que
//! se simula com os vetores de sustentação, a vista de cima, o C_L do conjunto e de cada superfície, o c_l e a carga
//! ao longo da envergadura, o diagnóstico e o resumo. A conta é a de `wing_analysis.zig`.
const std = @import("std");
const rl = @import("raylib");
const aircraft_model = @import("aircraft_model");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const view3d = ui_kit.view3d;
const analysis = @import("wing_analysis.zig");
const assembly_mod = @import("assembly.zig");

const model = aircraft_model.aircraft;
const max_owners = analysis.max_owners;

const Group = enum(usize) { surfaces, case, methods };

/// os campos fixos (depois das superfícies)
const FieldId = enum(usize) { airspeed, alpha_start, alpha_end, alpha_step, alpha_load, use_lifting_line, use_strips };

const fixed_fields = [_]form_mod.Field{
    .{ .label = "velocidade", .unit = "m/s", .group = @intFromEnum(Group.case), .number = 12, .minimum = 2, .maximum = 80 },
    .{ .label = "α inicial", .unit = "°", .group = @intFromEnum(Group.case), .number = -4, .minimum = -20, .maximum = 10 },
    .{ .label = "α final", .unit = "°", .group = @intFromEnum(Group.case), .number = 22, .minimum = 2, .maximum = 40 },
    .{ .label = "passo de α", .unit = "°", .group = @intFromEnum(Group.case), .number = 1, .minimum = 0.25, .maximum = 5 },
    .{ .label = "α da carga e da vista 3D", .unit = "°", .group = @intFromEnum(Group.case), .number = 10, .minimum = -10, .maximum = 40 },
    .{ .label = "linha sustentadora não linear", .group = @intFromEnum(Group.methods), .kind = .toggle, .checked = true },
    .{ .label = "faixas (o C_Lα da simulação)", .group = @intFromEnum(Group.methods), .kind = .toggle, .checked = false },
};

const method_names = [_][]const u8{ "linha sustentadora não linear", "faixas" };
const max_series = max_owners * 2;
const max_series_points = aircraft_model.aircraft.limits.sections * 2 * 3 + 8;

pub const AnalyzeTab = struct {
    groups: [3]form_mod.Group = .{ .{ .title = "Superfícies" }, .{ .title = "Caso" }, .{ .title = "Métodos" } },
    fields: [max_owners + fixed_fields.len]form_mod.Field = undefined,
    labels: [max_owners][96:0]u8 = undefined,
    surface_count: usize = 0,
    form: form_mod.Form = undefined,
    results: [2]?*analysis.Result = .{ null, null }, // linha sustentadora, faixas
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    wings: ?assembly_mod.Mesh = null, // o que se simula, em 3D
    message: [200:0]u8 = [_:0]u8{0} ** 200,
    progress: f32 = 0,
    scroll: f32 = 0,
    view: view3d.View = .{},
    top_view: view3d.View = .{ .azimuth = 180, .elevation = 85, .orthographic = true },
    // as curvas desenhadas (montadas depois de cada rodada)
    series_names: [max_series * 3][96:0]u8 = undefined,
    span_x: [max_series][max_series_points]f64 = undefined,
    span_cl: [max_series][max_series_points]f64 = undefined,
    span_load: [max_series][max_series_points]f64 = undefined,
    span_count: [max_series]usize = undefined,
    span_series: usize = 0,
    owner_columns: [max_series][analysis.max_alphas]f64 = undefined,

    /// troca o avião (refaz a lista de superfícies com a escolha padrão: só as asas) e roda
    pub fn setAircraft(tab: *AnalyzeTab, ac: ?*const model.Aircraft) void {
        const keep = if (tab.surface_count > 0) tab.fields[tab.surface_count..][0..fixed_fields.len].* else fixed_fields;
        tab.surface_count = 0;
        if (ac) |plane| {
            var indices: [max_owners]usize = undefined;
            const surfaces = analysis.liftingSurfaces(plane, &indices);
            const chosen = analysis.defaultChoice(plane);
            for (surfaces, 0..) |index, k| {
                const name = widgets.format(&tab.labels[k], "incluir: {s}", .{plane.surfaces[index].name});
                tab.fields[k] = .{ .label = name, .group = @intFromEnum(Group.surfaces), .kind = .toggle, .checked = chosen[k] };
            }
            tab.surface_count = surfaces.len;
        }
        tab.fields[tab.surface_count..][0..fixed_fields.len].* = keep;
        tab.form = .{ .groups = &tab.groups, .fields = tab.fields[0 .. tab.surface_count + fixed_fields.len] };
        tab.run(ac);
    }

    fn field(tab: *AnalyzeTab, id: FieldId) *form_mod.Field {
        return &tab.fields[tab.surface_count + @intFromEnum(id)];
    }

    fn setMessage(tab: *AnalyzeTab, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&tab.message, fmt, args) catch {};
    }

    fn input(tab: *AnalyzeTab) analysis.Input {
        var chosen = [_]bool{false} ** max_owners;
        for (0..tab.surface_count) |k| chosen[k] = tab.fields[k].checked;
        return .{
            .chosen = chosen,
            .airspeed = tab.field(.airspeed).number,
            .alpha_start = tab.field(.alpha_start).number,
            .alpha_end = tab.field(.alpha_end).number,
            .alpha_step = tab.field(.alpha_step).number,
            .alpha_load = tab.field(.alpha_load).number,
        };
    }

    /// roda os métodos marcados no avião `ac`
    pub fn run(tab: *AnalyzeTab, ac: ?*const model.Aircraft) void {
        _ = tab.arena.reset(.retain_capacity);
        if (tab.wings) |*mesh| mesh.deinit();
        tab.wings = null;
        for (&tab.results) |*slot| slot.* = null;
        tab.progress = 0;
        const plane = ac orelse {
            tab.setMessage("abra um avião (arraste um .json para a janela)", .{});
            return;
        };
        const allocator = tab.arena.allocator();
        const started = rl.getTime();
        const toggles = [_]bool{ tab.field(.use_lifting_line).checked, tab.field(.use_strips).checked };
        if (!toggles[0] and !toggles[1]) {
            tab.setMessage("marque ao menos um método", .{});
            return;
        }
        var base = tab.input();
        for (toggles, 0..) |on, m| {
            if (!on) continue;
            const result = allocator.create(analysis.Result) catch return tab.setMessage("sem memória", .{});
            base.method = if (m == 0) .lifting_line else .strips;
            analysis.run(allocator, plane, base, result) catch |err| {
                tab.setMessage("não rodou ({s}): {s}", .{ method_names[m], switch (err) {
                    error.NoSurface => "marque ao menos uma superfície",
                    error.BadInput => "confira a velocidade e a faixa de α",
                    else => @errorName(err),
                } });
                return;
            };
            tab.results[m] = result;
        }
        // o que se simula, em 3D (as superfícies escolhidas, sem fuselagem e sem motores)
        var owners: [analysis.max_surfaces]i32 = undefined;
        if (analysis.wingsOnly(allocator, plane, base.chosen, &owners)) |wings| {
            var diagnosis: model.Diag = .{};
            tab.wings = assembly_mod.buildMesh(std.heap.page_allocator, &wings.aircraft, &diagnosis) catch null;
        } else |_| {}
        tab.buildSeries();
        tab.progress = 1;
        tab.setMessage("terminado: ok — {d:.0} ms no núcleo", .{(rl.getTime() - started) * 1000});
    }

    /// as curvas ao longo da envergadura: uma por superfície e método, em ordem de y
    fn buildSeries(tab: *AnalyzeTab) void {
        tab.span_series = 0;
        for (tab.results, 0..) |maybe, m| {
            const result = maybe orelse continue;
            for (0..result.owner_count) |owner| {
                const s = tab.span_series;
                var count: usize = 0;
                for (0..result.panel_count) |j| {
                    if (result.panel_owner[j] != @as(i32, @intCast(owner)) or count == max_series_points) continue;
                    tab.span_x[s][count] = result.panel_span[j];
                    tab.span_cl[s][count] = result.load_cl[j];
                    tab.span_load[s][count] = result.load[j];
                    count += 1;
                }
                // em ordem de y (os dois lados vêm alternados)
                for (1..count) |i| {
                    var k = i;
                    while (k > 0 and tab.span_x[s][k - 1] > tab.span_x[s][k]) : (k -= 1) {
                        std.mem.swap(f64, &tab.span_x[s][k - 1], &tab.span_x[s][k]);
                        std.mem.swap(f64, &tab.span_cl[s][k - 1], &tab.span_cl[s][k]);
                        std.mem.swap(f64, &tab.span_load[s][k - 1], &tab.span_load[s][k]);
                    }
                }
                tab.span_count[s] = count;
                _ = widgets.format(&tab.series_names[s], "{s} · {s}", .{ result.owner_names[owner], method_names[m] });
                tab.span_series += 1;
            }
        }
    }

    /// a primeira rodada que existe (a da linha sustentadora, se marcada)
    fn main(tab: *const AnalyzeTab) ?*analysis.Result {
        return tab.results[0] orelse tab.results[1];
    }

    /// desenha a aba em `rect` (formulário à esquerda, gráficos à direita)
    pub fn draw(tab: *AnalyzeTab, ui: *widgets.Ui, rect: rl.Rectangle, ac: ?*const model.Aircraft) void {
        const sidebar_width: f32 = 360;
        tab.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height }, ac);
        tab.drawPlots(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
    }

    fn drawSidebar(tab: *AnalyzeTab, ui: *widgets.Ui, rect: rl.Rectangle, ac: ?*const model.Aircraft) void {
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const footer_height: f32 = 92;
        const form_rect: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height };
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 1 }, theme.colors.line);
        if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 }, "Rodar", ac != null)) tab.run(ac);
        widgets.progressBar(.{ .x = footer.x + 12, .y = footer.y + 56, .width = footer.width - 24, .height = 6 }, tab.progress);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), footer.x + 12, footer.y + 68, 13, theme.colors.muted);
        if (tab.surface_count + fixed_fields.len == tab.form.fields.len) {
            if (tab.form.draw(ui, form_rect)) tab.run(ac);
        }
    }

    fn drawPlots(tab: *AnalyzeTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 420;
        const rows: f32 = 4;
        const content_height = rows * (row_height + gap) + gap;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        var y = rect.y + gap - tab.scroll;
        const view_card: rl.Rectangle = .{ .x = x0, .y = y, .width = column_width, .height = row_height };
        const top_card: rl.Rectangle = .{ .x = x1, .y = y, .width = column_width, .height = row_height };
        // as vistas 3D usam a roda antes da rolagem da página, e a textura é desenhada fora do recorte
        const main_result = tab.main();
        if (main_result != null and tab.wings != null) {
            tab.view.handleInput(ui, cardInside(view_card));
            tab.top_view.handleInput(ui, cardInside(top_card));
            tab.render(&tab.view, cardInside(view_card), true);
            tab.render(&tab.top_view, cardInside(top_card), false);
        }
        if (ui.hovering(rect)) tab.scroll = std.math.clamp(tab.scroll - ui.wheel * 60, 0, @max(0, content_height - rect.height));
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        defer rl.endScissorMode();
        const result = main_result orelse {
            theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), rect.x + 40, rect.y + 40, 16, theme.colors.muted);
            return;
        };
        var title_buffer: [128]u8 = undefined;
        const alpha_load = tab.field(.alpha_load).number;
        _ = widgets.card(ui, view_card, widgets.format(&title_buffer, "Vista 3D do que se simula (α = {d:.1}°)", .{alpha_load}));
        tab.view.blit(ui, cardInside(view_card));
        var note_buffer: [128]u8 = undefined;
        theme.text(ui.fonts.regular, widgets.format(&note_buffer, "sustentação ({s}): maior seta = {d:.3} N/m · arraste para girar", .{ method_names[@intFromEnum(result.method)], largestLoad(result) }), view_card.x + 14, view_card.y + view_card.height - 22, 12, theme.colors.muted);
        var top_title: [128]u8 = undefined;
        _ = widgets.card(ui, top_card, widgets.format(&top_title, "Vista de cima (α = {d:.1}°)", .{alpha_load}));
        tab.top_view.blit(ui, cardInside(top_card));
        y += row_height + gap;

        // C_L do conjunto e de cada superfície
        var total_series: [2]plot.Series = undefined;
        var total_count: usize = 0;
        var surface_series: [max_series]plot.Series = undefined;
        var surface_count: usize = 0;
        for (tab.results, 0..) |maybe, m| {
            const r = maybe orelse continue;
            const n = r.alpha_count;
            total_series[total_count] = .{ .name = @ptrCast(method_names[m]), .xs = r.alphas_deg[0..n], .ys = r.total_cl[0..n], .color_index = m, .dashed = m == 1 };
            total_count += 1;
            for (0..r.owner_count) |owner| {
                const name_index = max_series + surface_count;
                const name = widgets.format(&tab.series_names[name_index], "{s} · {s}", .{ r.owner_names[owner], method_names[m] });
                surface_series[surface_count] = .{ .name = name, .xs = r.alphas_deg[0..n], .ys = ownerColumn(tab, r, owner, surface_count), .color_index = owner, .dashed = m == 1 };
                surface_count += 1;
            }
        }
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "C_L do conjunto × α", .x_label = "α (°)", .y_label = "C_L (na soma das áreas)" }, total_series[0..total_count]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "C_L de cada superfície × α", .x_label = "α (°)", .y_label = "C_L (na área dela)" }, surface_series[0..surface_count]);
        y += row_height + gap;

        // ao longo da envergadura
        var cl_series: [max_series]plot.Series = undefined;
        var load_series: [max_series]plot.Series = undefined;
        for (0..tab.span_series) |s| {
            const count = tab.span_count[s];
            const dashed = std.mem.endsWith(u8, std.mem.sliceTo(&tab.series_names[s], 0), method_names[1]);
            cl_series[s] = .{ .name = std.mem.sliceTo(&tab.series_names[s], 0), .xs = tab.span_x[s][0..count], .ys = tab.span_cl[s][0..count], .color_index = s, .dashed = dashed };
            load_series[s] = .{ .name = std.mem.sliceTo(&tab.series_names[s], 0), .xs = tab.span_x[s][0..count], .ys = tab.span_load[s][0..count], .color_index = s, .dashed = dashed };
        }
        var cl_title: [96]u8 = undefined;
        var load_title: [96]u8 = undefined;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = widgets.format(&cl_title, "c_l ao longo da envergadura (α = {d:.1}°)", .{alpha_load}), .x_label = "y (m)", .y_label = "c_l" }, cl_series[0..tab.span_series]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = widgets.format(&load_title, "Carga ao longo da envergadura (α = {d:.1}°)", .{alpha_load}), .x_label = "y (m)", .y_label = "L' (N/m)" }, load_series[0..tab.span_series]);
        y += row_height + gap;

        tab.drawDiagnosis(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height });
        tab.drawSummary(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height });
    }

    /// a vista 3D das superfícies escolhidas; com `arrows`, um vetor de sustentação por painel no ponto dele, na
    /// direção perpendicular ao vento (no plano x-z do corpo) e do tamanho de L' (a maior seta = 18 % do avião,
    /// como na vista de cargas em Python)
    fn render(tab: *AnalyzeTab, view: *view3d.View, area: rl.Rectangle, arrows: bool) void {
        const mesh = &(tab.wings orelse return);
        const result = tab.main() orelse return;
        const size = mesh.size();
        const middle = mesh.center();
        if (!view.begin(area, middle, if (arrows) 1.35 * size else size)) return;
        defer view.end();
        if (arrows) view3d.floor(.{ middle[0], middle[1], 0 }, mesh.high[2] + 0.2 * size, 1.6 * size, 0.25);
        mesh.draw();
        if (!arrows) return;
        const largest = largestLoad(result);
        if (!(largest > 1e-12)) return;
        const scale = 0.18 * size / largest;
        const alpha = tab.field(.alpha_load).number * std.math.pi / 180;
        const direction: view3d.Body = .{ @sin(alpha), 0, -@cos(alpha) }; // sustentação ⟂ ao vento, para cima
        for (0..result.panel_count) |j| {
            const value = result.load[j] * scale;
            view3d.arrow(result.panel_point[j], .{ direction[0] * value, 0, direction[2] * value }, 0.022 * size, view3d.liftColor());
        }
        view3d.bodyAxes(view, .{ mesh.low[0] - 0.12 * size, mesh.low[1] - 0.12 * size, mesh.high[2] + 0.04 * size }, 0.14 * size);
    }

    fn drawDiagnosis(tab: *AnalyzeTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Diagnóstico");
        const columns = [_]f32{ inner.x, inner.x + 56, inner.x + 220 };
        var y = inner.y;
        for (tab.results, 0..) |maybe, m| {
            const r = maybe orelse continue;
            theme.text(ui.fonts.regular, @ptrCast(method_names[m]), inner.x, y, 14, theme.colors.accent);
            y += 24;
            var buffers: [2][128]u8 = undefined;
            const peak_alpha = r.alphas_deg[r.summary.peak];
            const at_end = r.summary.peak + 1 == r.alpha_count;
            const onset_owner: usize = if (r.summary.onset_panel) |p| @intCast(r.panel_owner[p]) else 0;
            const rows = [_]struct { status: widgets.Status, item: [:0]const u8, value: [:0]const u8 }{
                .{ .status = if (at_end) .info else .ok, .item = "C_L máximo", .value = widgets.format(&buffers[0], "{d:.3} a {d:.1}°{s}", .{ r.summary.lift_max, peak_alpha, if (at_end) " (fim da varredura)" else "" }) },
                .{ .status = if (r.summary.onset_panel != null and r.summary.onset_fraction < 0.5) .ok else if (r.summary.onset_panel == null) .info else .atencao, .item = "onde o estol começa", .value = if (r.summary.onset_panel != null) widgets.format(&buffers[1], "{s}, y/(b/2) = {d:.2} ({s})", .{ r.owner_names[onset_owner], r.summary.onset_fraction, if (r.summary.onset_fraction < 0.5) "da raiz para fora" else "perto da ponta" }) else "não começou na varredura" },
            };
            for (rows) |row| {
                const labels = [_][:0]const u8{ @tagName(row.status), row.item, row.value };
                const colors = [_]rl.Color{ widgets.statusColor(row.status), theme.colors.ink, theme.colors.label };
                widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
                y += 26;
                rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
            }
            y += 6;
        }
        const r = tab.main() orelse return;
        var buffer: [64]u8 = undefined;
        const labels = [_][:0]const u8{ if (r.reynolds > 7e4) "ok" else "atencao", "Reynolds (corda média)", widgets.format(&buffer, "{d:.0} ({s})", .{ r.reynolds, r.owner_names[0] }) };
        const colors = [_]rl.Color{ widgets.statusColor(if (r.reynolds > 7e4) .ok else .atencao), theme.colors.ink, theme.colors.label };
        widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
    }

    fn drawSummary(tab: *AnalyzeTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Resumo");
        const r = tab.main() orelse return;
        const columns = [_]f32{ inner.x, inner.x + 300 };
        const colors = [_]rl.Color{ theme.colors.label, theme.colors.ink };
        var y = inner.y;
        var buffers: [3][96]u8 = undefined;
        for (0..r.owner_count) |owner| {
            const rows = [_][2][:0]const u8{
                .{ widgets.format(&buffers[0], "{s}: área (m²)", .{r.owner_names[owner]}), widgets.format(&buffers[1], "{d:.4}", .{r.owner_area[owner]}) },
            };
            for (rows) |row| {
                widgets.tableRow(ui, y, &columns, &row, &colors, 14);
                y += 26;
            }
            var chord_label: [96]u8 = undefined;
            const row2 = [_][:0]const u8{ widgets.format(&chord_label, "{s}: corda média aerodinâmica (m)", .{r.owner_names[owner]}), widgets.format(&buffers[2], "{d:.4}", .{r.owner_chord[owner]}) };
            widgets.tableRow(ui, y, &columns, &row2, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
        for (tab.results, 0..) |maybe, m| {
            const result = maybe orelse continue;
            var label: [96]u8 = undefined;
            var value: [32]u8 = undefined;
            const row = [_][:0]const u8{ widgets.format(&label, "C_L máximo, {s}", .{method_names[m]}), widgets.format(&value, "{d:.4}", .{result.summary.lift_max}) };
            widgets.tableRow(ui, y, &columns, &row, &colors, 14);
            y += 26;
        }
        var count_value: [32]u8 = undefined;
        var panels_value: [32]u8 = undefined;
        const rows = [_][2][:0]const u8{
            .{ "ângulos na varredura", widgets.format(&count_value, "{d}", .{r.alpha_count}) },
            .{ "painéis contados (refinados)", widgets.format(&panels_value, "{d}", .{r.panel_count}) },
        };
        for (rows) |row| {
            widgets.tableRow(ui, y, &columns, &row, &colors, 14);
            y += 26;
        }
    }
};

/// a coluna `owner` do C_L de cada dono (α × dono), copiada para um vetor contínuo do gráfico
fn ownerColumn(tab: *AnalyzeTab, result: *const analysis.Result, owner: usize, slot: usize) []const f64 {
    const column = tab.owner_columns[slot][0..result.alpha_count];
    for (column, 0..) |*value, a| value.* = result.owner_cl[a * result.owner_count + owner];
    return column;
}

fn largestLoad(result: *const analysis.Result) f64 {
    var largest: f64 = 0;
    for (result.load[0..result.panel_count]) |value| largest = @max(largest, @abs(value));
    return largest;
}

/// a parte de dentro de um cartão onde vai a imagem 3D (abaixo do título)
fn cardInside(rect: rl.Rectangle) rl.Rectangle {
    return .{ .x = rect.x + 4, .y = rect.y + 34, .width = rect.width - 8, .height = rect.height - 40 };
}

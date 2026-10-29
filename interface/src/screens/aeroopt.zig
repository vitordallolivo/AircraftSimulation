//! A tela do aeroopt: à esquerda o problema (pontuação, variáveis, restrições e configuração, cada um num grupo
//! que abre e fecha) e o botão Otimizar; à direita a rodada: quantos aviões passaram em cada etapa, a
//! convergência, o mapa dos aviões colorido pela nota, o MTOW de cada ponto, a nota de cada configuração e a
//! tabela dos melhores. Por enquanto com uma rodada de exemplo (`opt_example.zig`).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../ui/theme.zig");
const shapes = @import("../ui/shapes.zig");
const widgets = @import("../ui/widgets.zig");
const form_mod = @import("../ui/form.zig");
const plot = @import("../ui/plot.zig");
const example = @import("../opt_example.zig");

const tabs = [_][:0]const u8{ "OTIMIZAR", "SENSIBILIDADE" };

const Group = enum(usize) { score, variables, constraints, settings };

fn g(group: Group) usize {
    return @intFromEnum(group);
}

const initial_groups = [_]form_mod.Group{ .{ .title = "PONTUAÇÃO", .open = false }, .{ .title = "VARIÁVEIS" }, .{ .title = "RESTRIÇÕES", .open = false }, .{ .title = "CONFIGURAÇÃO" } };

const initial_fields = [_]form_mod.Field{
    .{ .label = "regulamento", .group = g(.score), .kind = .choice, .choices = "Regular 2026;Micro 2026;Avançada 2026" },
    .{ .label = "pista", .unit = "m", .group = g(.score), .number = 50, .minimum = 10, .maximum = 200 },
    .{ .label = "envergadura, 1,6 a 2,8 m", .group = g(.variables), .kind = .toggle, .checked = true },
    .{ .label = "corda na raiz, 0,25 a 0,55 m", .group = g(.variables), .kind = .toggle, .checked = true },
    .{ .label = "afilamento", .group = g(.variables), .kind = .toggle },
    .{ .label = "área da EH", .group = g(.variables), .kind = .toggle },
    .{ .label = "braço da EH", .group = g(.variables), .kind = .toggle },
    .{ .label = "perfil da asa (lista)", .group = g(.variables), .kind = .toggle },
    .{ .label = "motor e hélice (lista)", .group = g(.variables), .kind = .toggle },
    .{ .label = "decola na pista", .group = g(.constraints), .kind = .toggle, .checked = true },
    .{ .label = "margem estática ≥ 5 %", .group = g(.constraints), .kind = .toggle, .checked = true },
    .{ .label = "voo válido no 6GDL", .group = g(.constraints), .kind = .toggle, .checked = true },
    .{ .label = "método das superfícies", .group = g(.settings), .kind = .choice, .choices = "GA;CMA-ES;DE;coordenadas" },
    .{ .label = "população", .group = g(.settings), .number = 20, .minimum = 4, .maximum = 400 },
    .{ .label = "gerações", .group = g(.settings), .number = 12, .minimum = 1, .maximum = 500 },
    .{ .label = "processos", .group = g(.settings), .number = 4, .minimum = 1, .maximum = 64 },
    .{ .label = "sensibilidade", .group = g(.settings), .kind = .choice, .choices = "modelo local;um por vez;Morris" },
};

pub const Screen = struct {
    groups: [initial_groups.len]form_mod.Group = initial_groups,
    fields: [initial_fields.len]form_mod.Field = initial_fields,
    form: form_mod.Form = undefined,
    tab: usize = 0,
    run: example.Run = .{},
    progress: f32 = 1,
    scroll: f32 = 0,
    message: [160:0]u8 = [_:0]u8{0} ** 160,

    /// liga o formulário e monta a rodada de exemplo
    pub fn init(screen: *Screen) void {
        screen.form = .{ .groups = &screen.groups, .fields = &screen.fields };
        example.generate(&screen.run);
        _ = std.fmt.bufPrintZ(&screen.message, "rodada de exemplo: {d} aviões, {d} gerações", .{ example.evaluation_count, example.generation_count }) catch {};
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.background);
        const top = widgets.header_height + 38;
        const sidebar_width: f32 = 360;
        if (screen.tab == 0) {
            screen.drawSidebar(ui, .{ .x = 0, .y = top, .width = sidebar_width, .height = height - top });
            screen.drawResults(ui, .{ .x = sidebar_width, .y = top, .width = width - sidebar_width, .height = height - top });
        } else {
            const box: rl.Rectangle = .{ .x = 40, .y = top + 40, .width = 620, .height = 150 };
            const inner = widgets.labeledCard(ui, box, "SENSIBILIDADE");
            theme.text(ui.fonts.regular, "esta aba ainda não foi feita em Zig; o desenho segue o mesmo tema", inner.x, inner.y + 10, 15, theme.label);
        }
        if (widgets.header(ui, width, "AEROOPT", &.{ "Abrir problema (.opt.json)", "Salvar" }, "dados de exemplo · desenho da interface em Zig")) |_|
            _ = std.fmt.bufPrintZ(&screen.message, "abrir e salvar o problema entram na próxima etapa", .{}) catch {};
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, &tabs, &screen.tab, theme.black, 14);
    }

    fn drawSidebar(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.sidebar);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 3, .y = rect.y, .width = 3, .height = rect.height }, theme.black);
        const footer_height: f32 = 92;
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 3, .height = footer_height };
        rl.drawRectangleRec(footer, theme.black);
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 3 }, theme.orange);
        if (widgets.primaryButton(ui, .{ .x = footer.x + 12, .y = footer.y + 14, .width = footer.width - 24, .height = 34 }, "▶  OTIMIZAR", true)) {
            example.generate(&screen.run);
            screen.progress = 1;
            _ = std.fmt.bufPrintZ(&screen.message, "a busca de verdade entra na próxima etapa (exemplo refeito)", .{}) catch {};
        }
        shapes.hazard(.{ .x = footer.x + 12, .y = footer.y + 54, .width = footer.width - 24, .height = 7 }, screen.progress, theme.orange, theme.panel);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.message, 0), footer.x + 12, footer.y + 68, 13, theme.muted);
        _ = screen.form.draw(ui, .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 3, .height = rect.height - footer_height - 4 });
    }

    fn drawResults(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 400;
        const content_height = 3 * (row_height + gap) + gap;
        if (ui.hovering(rect)) screen.scroll = std.math.clamp(screen.scroll - ui.wheel * 60, 0, @max(0, content_height - rect.height));
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        defer rl.endScissorMode();
        const run = &screen.run;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        var y = rect.y + gap - screen.scroll;

        bars(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, "Aviões que passaram em cada etapa", &example.stages, &run.stage_count, "{d:.0}");
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "Convergência", .x_label = "geração", .y_label = "nota" }, &.{
            .{ .name = "melhor até a geração", .xs = &run.generation_axis, .ys = &run.generation_best },
            .{ .name = "média da geração", .xs = &run.generation_axis, .ys = &run.generation_mean, .dashed = true },
        });
        y += row_height + gap;

        plot.cloud(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "Mapa dos aviões (cor = nota; anel = melhor)", .x_label = "envergadura (m)", .y_label = "corda na raiz (m)" }, .{ .xs = &run.span, .ys = &run.chord, .values = &run.score, .value_name = "nota", .highlight = run.best });
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "MTOW de cada ponto avaliado", .x_label = "avaliação", .y_label = "MTOW (kg)" }, &.{
            .{ .name = "MTOW", .xs = &run.index, .ys = &run.mtow, .points = true, .color_index = 1 },
        });
        y += row_height + gap;

        bars(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, "Melhor nota de cada configuração", &example.configurations, &run.configuration_score, "{d:.1}");
        screen.drawTable(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height });
    }

    /// os 10 melhores aviões
    fn drawTable(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "MELHORES AVIÕES");
        const run = &screen.run;
        var order: [example.evaluation_count]usize = undefined;
        for (&order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, &order, run, struct {
            fn better(r: *const example.Run, a: usize, b: usize) bool {
                return r.score[a] > r.score[b];
            }
        }.better);
        const columns = [_]f32{ inner.x, inner.x + 46, inner.x + 140, inner.x + 270, inner.x + 400 };
        const head = [_][:0]const u8{ "#", "nota", "envergadura", "corda raiz", "MTOW" };
        const head_colors = [_]rl.Color{theme.orange};
        widgets.tableRow(ui, inner.y, &columns, &head, &head_colors, 13);
        rl.drawRectangleRec(.{ .x = inner.x, .y = inner.y + 20, .width = inner.width, .height = 2 }, theme.orange);
        var y = inner.y + 28;
        var buffers: [5][24]u8 = undefined;
        for (order[0..10], 0..) |i, rank| {
            const cells = [_][:0]const u8{
                widgets.format(&buffers[0], "{d}", .{rank + 1}),
                widgets.format(&buffers[1], "{d:.2}", .{run.score[i]}),
                widgets.format(&buffers[2], "{d:.3} m", .{run.span[i]}),
                widgets.format(&buffers[3], "{d:.3} m", .{run.chord[i]}),
                widgets.format(&buffers[4], "{d:.2} kg", .{run.mtow[i]}),
            };
            const row_color = if (rank == 0) theme.orange else theme.ink;
            const colors = [_]rl.Color{ theme.muted, row_color, theme.label, theme.label, theme.label };
            widgets.tableRow(ui, y, &columns, &cells, &colors, 14);
            y += 28;
            if (y > inner.y + inner.height) break;
        }
    }
};

/// barras horizontais com o rótulo à esquerda e o valor no fim (cores da paleta, uma por barra)
fn bars(ui: *widgets.Ui, rect: rl.Rectangle, title: [:0]const u8, labels: []const [:0]const u8, values: []const f64, comptime value_format: []const u8) void {
    const inner = widgets.card(ui, rect, title);
    var high: f64 = 0;
    for (values) |v| high = @max(high, v);
    if (!(high > 0)) high = 1;
    const label_width: f32 = 190;
    const n: f32 = @floatFromInt(labels.len);
    const slot = (inner.height - 10) / n;
    const thickness = @min(slot * 0.62, 30);
    var buffer: [32]u8 = undefined;
    for (labels, values, 0..) |caption, value, i| {
        const y = inner.y + 6 + @as(f32, @floatFromInt(i)) * slot;
        theme.text(ui.fonts.regular, caption, inner.x + 6, y + (thickness - 14) / 2, 14, theme.label);
        const full = inner.width - label_width - 70;
        const length = full * @as(f32, @floatCast(value / high));
        shapes.slanted(.{ .x = inner.x + label_width, .y = y, .width = @max(length, 12), .height = thickness }, 6, theme.plotColor(i));
        theme.text(ui.fonts.mono, widgets.format(&buffer, value_format, .{value}), inner.x + label_width + length + 10, y + (thickness - 14) / 2, 14, theme.ink);
    }
}

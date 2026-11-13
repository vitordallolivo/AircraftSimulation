//! A tela do aeroopt: à esquerda o problema (`problem_panel.zig`: o projeto, abrir e gravar o `.opt.json`, um botão
//! por parte com o resumo ao lado e Otimizar/Parar); à direita a rodada: quantos aviões passaram em cada etapa, a
//! convergência, o mapa dos aviões colorido pela nota, o MTOW de cada ponto, a nota de cada configuração e a
//! tabela dos melhores. A rodada ainda é a de exemplo (`opt_example.zig`).
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const plot = ui_kit.plot;
const numbers = ui_kit.numbers;
const example = @import("opt_example.zig");

const panel_mod = @import("problem_panel.zig");

const tabs = [_][:0]const u8{ "Otimizar", "Sensibilidade" };

pub const Screen = struct {
    panel: panel_mod.Panel = .{},
    tab: usize = 0,
    sidebar: widgets.Splitter = .{ .width = 420 }, // a largura da esquerda (arrastar a divisa muda)
    run: example.Run = .{},
    scroll: f32 = 0,
    plots: ui_kit.scroll.ScrollArea = .{}, // a coluna dos gráficos

    /// monta a rodada de exemplo (chamar com a tela já no lugar final)
    pub fn start(screen: *Screen) void {
        example.generate(&screen.run);
        _ = widgets.format(&screen.panel.message, "abra um problema (.opt.json); os gráficos são de uma rodada de exemplo", .{});
    }

    /// abre um problema (`.opt.json`) ou um projeto da sprint pela linha de comando ou pela página
    pub fn openFile(screen: *Screen, path: []const u8) void {
        screen.panel.openAny(path);
    }

    /// os prints: `acao=pontuacao`, `variaveis`, `restricoes`, `categorias` ou `configuracao` abre o submenu
    pub fn command(screen: *Screen, action: []const u8) void {
        const names = [_][]const u8{ "pontuacao", "variaveis", "restricoes", "categorias", "configuracao" };
        for (names, 0..) |name, i| if (std.mem.eql(u8, name, action)) screen.panel.openPart(@enumFromInt(i));
        if (std.mem.startsWith(u8, action, "lista:")) screen.panel.openListByKey(action[6..]); // a lista marcável de uma variável
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.colors.background);
        // com um submenu ou a janela de arquivo aberta, a tela de baixo não recebe o clique nem a roda
        const modal = screen.panel.modal();
        const clicked = ui.clicked;
        const wheel = ui.wheel;
        if (modal) {
            ui.clicked = false;
            ui.wheel = 0;
        }
        const top = widgets.header_height + 38;
        if (screen.tab == 0) {
            screen.sidebar.update(ui, 0, top, height - top, 320, width - 360);
            const sidebar_width = screen.sidebar.width;
            switch (screen.panel.drawSidebar(ui, .{ .x = 0, .y = top, .width = sidebar_width, .height = height - top })) {
                .optimize => {
                    example.generate(&screen.run);
                    screen.panel.progress = 1;
                    _ = widgets.format(&screen.panel.message, "a busca de verdade entra na próxima etapa (exemplo refeito)", .{});
                },
                .stop, .none => {},
            }
            screen.drawResults(ui, .{ .x = sidebar_width, .y = top, .width = width - sidebar_width, .height = height - top });
            screen.sidebar.draw(0, top, height - top);
        } else {
            const box: rl.Rectangle = .{ .x = 40, .y = top + 40, .width = 620, .height = 150 };
            const inner = widgets.labeledCard(ui, box, "Sensibilidade");
            theme.text(ui.fonts.regular, "esta aba ainda não foi feita; o desenho segue o mesmo tema", inner.x, inner.y + 10, 15, theme.colors.label);
        }
        var subtitle_buffer: [160]u8 = undefined;
        const subtitle = if (screen.panel.path_len > 0)
            widgets.format(&subtitle_buffer, "{s} · gráficos de uma rodada de exemplo", .{screen.panel.fileName()})
        else if (screen.panel.problem != null)
            widgets.format(&subtitle_buffer, "problema do projeto (não gravado) · gráficos de uma rodada de exemplo", .{})
        else
            widgets.format(&subtitle_buffer, "nenhum problema aberto · gráficos de uma rodada de exemplo", .{});
        _ = widgets.header(ui, width, "AeroOpt", &.{}, subtitle);
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, &tabs, &screen.tab, 14);
        if (modal) {
            ui.clicked = clicked;
            ui.wheel = wheel;
        }
        screen.panel.drawModal(ui, .{ .x = 0, .y = 0, .width = width, .height = height });
    }

    fn drawResults(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 400;
        const content_height = 3 * (row_height + gap) + gap;
        screen.plots.content_height = content_height;
        if (screen.scroll > 0) { // a rolagem pedida na linha de comando (prints)
            screen.plots.offset = screen.scroll;
            screen.scroll = 0;
        }
        const top = screen.plots.begin(ui, rect);
        defer screen.plots.end(ui, rect, top + content_height);
        const run = &screen.run;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        var y = top + gap;

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
        const inner = widgets.labeledCard(ui, rect, "Melhores aviões");
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
        const head_colors = [_]rl.Color{theme.colors.accent};
        widgets.tableRow(ui, inner.y, &columns, &head, &head_colors, 13);
        rl.drawRectangleRec(.{ .x = inner.x, .y = inner.y + 20, .width = inner.width, .height = 2 }, theme.colors.accent);
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
            const row_color = if (rank == 0) theme.colors.accent else theme.colors.ink;
            const colors = [_]rl.Color{ theme.colors.muted, row_color, theme.colors.label, theme.colors.label, theme.colors.label };
            widgets.tableRow(ui, y, &columns, &cells, &colors, 14);
            y += 28;
            if (y > inner.y + inner.height) break;
        }
    }
};

/// barras horizontais retas, de uma cor só, todas a partir do zero (o comprimento é o valor), com a escala embaixo
/// e o valor no fim de cada barra
fn bars(ui: *widgets.Ui, rect: rl.Rectangle, title: [:0]const u8, labels: []const [:0]const u8, values: []const f64, comptime value_format: []const u8) void {
    const inner = widgets.card(ui, rect, title);
    var high: f64 = 0;
    for (values) |v| high = @max(high, v);
    if (!(high > 0)) high = 1;
    const step = numbers.niceStep(high, 5);
    const axis_high = @ceil(high / step) * step;
    const label_width: f32 = 190;
    const scale_height: f32 = 24;
    const area: rl.Rectangle = .{ .x = inner.x + label_width, .y = inner.y + 4, .width = inner.width - label_width - 60, .height = inner.height - scale_height - 8 };
    var buffer: [32]u8 = undefined;
    // escala: grade e marcas
    var tick: f64 = 0;
    while (tick <= axis_high + step * 1e-9) : (tick += step) {
        const x = area.x + @as(f32, @floatCast(tick / axis_high)) * area.width;
        rl.drawLineEx(.{ .x = x, .y = area.y }, .{ .x = x, .y = area.y + area.height }, 1, if (tick == 0) theme.colors.line else theme.colors.grid);
        const text = widgets.format(&buffer, "{d}", .{tick});
        theme.text(ui.fonts.mono, text, x - theme.textWidth(ui.fonts.mono, text, 12) / 2, area.y + area.height + 6, 12, theme.colors.muted);
    }
    const n: f32 = @floatFromInt(labels.len);
    const slot = area.height / n;
    const thickness = @min(slot * 0.6, 28);
    for (labels, values, 0..) |caption, value, i| {
        const y = area.y + (@as(f32, @floatFromInt(i)) + 0.5) * slot - thickness / 2;
        theme.text(ui.fonts.regular, caption, inner.x + 6, y + (thickness - 14) / 2, 14, theme.colors.label);
        const length = area.width * @as(f32, @floatCast(value / axis_high));
        rl.drawRectangleRec(.{ .x = area.x, .y = y, .width = length, .height = thickness }, theme.plotColor(1));
        theme.text(ui.fonts.mono, widgets.format(&buffer, value_format, .{value}), area.x + length + 8, y + (thickness - 14) / 2, 14, theme.colors.ink);
    }
}

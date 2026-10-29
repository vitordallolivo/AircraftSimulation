//! Gráfico de linhas dentro de um cartão: eixos com marcas redondas, grade fraca, as curvas na paleta do tema
//! (uma cor por curva, tracejada se pedido) e a legenda embaixo, quebrando em linhas. Também faz nuvem de pontos
//! colorida por um valor (o mapa do aeroopt).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const numbers = @import("numbers.zig");

/// uma curva: x e y do mesmo tamanho
pub const Series = struct {
    name: [:0]const u8,
    xs: []const f64,
    ys: []const f64,
    dashed: bool = false,
    points: bool = false, // só os pontos, sem ligar
    color_index: ?usize = null, // cor fixa da paleta (senão, a ordem da curva)
};

/// pontos coloridos por um valor (azul → laranja), sem legenda de curvas
pub const Cloud = struct {
    xs: []const f64,
    ys: []const f64,
    values: []const f64,
    value_name: [:0]const u8,
    highlight: ?usize = null, // um ponto marcado (o melhor)
};

pub const Axes = struct {
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
};

const Frame = struct {
    area: rl.Rectangle,
    x_range: numbers.Range,
    y_range: numbers.Range,

    fn toScreen(frame: Frame, x: f64, y: f64) rl.Vector2 {
        const fx = (x - frame.x_range.low) / (frame.x_range.high - frame.x_range.low);
        const fy = (y - frame.y_range.low) / (frame.y_range.high - frame.y_range.low);
        return .{ .x = frame.area.x + @as(f32, @floatCast(fx)) * frame.area.width, .y = frame.area.y + frame.area.height - @as(f32, @floatCast(fy)) * frame.area.height };
    }
};

/// cartão com o gráfico das curvas
pub fn lines(ui: *widgets.Ui, rect: rl.Rectangle, axes: Axes, series: []const Series) void {
    const inner = widgets.card(ui, rect, axes.title);
    var x_range: ?numbers.Range = null;
    var y_range: ?numbers.Range = null;
    for (series) |s| {
        const rx = numbers.Range.of(s.xs, 0);
        const ry = numbers.Range.of(s.ys, 0.06);
        x_range = if (x_range) |r| r.merge(rx) else rx;
        y_range = if (y_range) |r| r.merge(ry) else ry;
    }
    const legend_height = legendHeight(ui, inner.width, series);
    const frame = drawFrame(ui, inner, axes, x_range orelse .{ .low = 0, .high = 1 }, y_range orelse .{ .low = 0, .high = 1 }, legend_height);
    rl.beginScissorMode(@intFromFloat(frame.area.x), @intFromFloat(frame.area.y - 1), @intFromFloat(frame.area.width + 1), @intFromFloat(frame.area.height + 2));
    for (series, 0..) |s, i| {
        const color = theme.plotColor(s.color_index orelse i);
        const n = @min(s.xs.len, s.ys.len);
        if (s.points) {
            for (0..n) |k| if (std.math.isFinite(s.ys[k])) rl.drawCircleV(frame.toScreen(s.xs[k], s.ys[k]), 3, color);
            continue;
        }
        var k: usize = 1;
        while (k < n) : (k += 1) {
            if (!std.math.isFinite(s.ys[k - 1]) or !std.math.isFinite(s.ys[k])) continue;
            const a = frame.toScreen(s.xs[k - 1], s.ys[k - 1]);
            const b = frame.toScreen(s.xs[k], s.ys[k]);
            if (s.dashed) dashedLine(a, b, color) else rl.drawLineEx(a, b, 2.2, color);
        }
    }
    rl.endScissorMode();
    drawLegend(ui, .{ .x = inner.x + 10, .y = inner.y + inner.height - legend_height + 4, .width = inner.width - 20, .height = legend_height }, series);
}

/// cartão com a nuvem de pontos colorida pelo valor (com a barra de cores)
pub fn cloud(ui: *widgets.Ui, rect: rl.Rectangle, axes: Axes, points: Cloud) void {
    const inner = widgets.card(ui, rect, axes.title);
    const value_range = numbers.Range.of(points.values, 0);
    const frame = drawFrame(ui, .{ .x = inner.x, .y = inner.y, .width = inner.width - 54, .height = inner.height }, axes, numbers.Range.of(points.xs, 0.04), numbers.Range.of(points.ys, 0.06), 0);
    const n = @min(points.xs.len, @min(points.ys.len, points.values.len));
    for (0..n) |k| {
        const t = (points.values[k] - value_range.low) / (value_range.high - value_range.low);
        rl.drawCircleV(frame.toScreen(points.xs[k], points.ys[k]), 4, ramp(@floatCast(t)));
    }
    if (points.highlight) |best| if (best < n) {
        const center = frame.toScreen(points.xs[best], points.ys[best]);
        rl.drawCircleLinesV(center, 9, theme.ink);
        rl.drawCircleLinesV(center, 10, theme.ink);
    };
    // barra de cores
    const bar: rl.Rectangle = .{ .x = inner.x + inner.width - 34, .y = frame.area.y, .width = 12, .height = frame.area.height };
    const steps: usize = 40;
    for (0..steps) |s| {
        const f0 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        const h = bar.height / @as(f32, @floatFromInt(steps));
        rl.drawRectangleRec(.{ .x = bar.x, .y = bar.y + bar.height - (f0 + 1.0 / @as(f32, @floatFromInt(steps))) * bar.height, .width = bar.width, .height = h + 1 }, ramp(f0));
    }
    var buffer: [32]u8 = undefined;
    theme.text(ui.fonts.mono, numbers.numberText(&buffer, value_range.high), bar.x - 4, bar.y - 16, 11, theme.muted);
    theme.text(ui.fonts.mono, numbers.numberText(&buffer, value_range.low), bar.x - 4, bar.y + bar.height + 4, 11, theme.muted);
    theme.text(ui.fonts.regular, points.value_name, bar.x - 6, bar.y + bar.height + 18, 11, theme.muted);
}

/// azul (pior) → laranja (melhor)
fn ramp(fraction: f32) rl.Color {
    const t = std.math.clamp(fraction, 0, 1);
    const low = theme.hex(0x2f6fd6);
    const middle = theme.hex(0xced4da);
    const high = theme.orange;
    const mix = struct {
        fn f(a: rl.Color, b: rl.Color, s: f32) rl.Color {
            return .{ .r = lerp(a.r, b.r, s), .g = lerp(a.g, b.g, s), .b = lerp(a.b, b.b, s), .a = 255 };
        }
        fn lerp(a: u8, b: u8, s: f32) u8 {
            return @intFromFloat(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * s);
        }
    };
    return if (t < 0.5) mix.f(low, middle, t * 2) else mix.f(middle, high, (t - 0.5) * 2);
}

/// eixos, marcas, grade e rótulos; devolve onde desenhar
fn drawFrame(ui: *widgets.Ui, inner: rl.Rectangle, axes: Axes, x_range_data: numbers.Range, y_range_data: numbers.Range, legend_height: f32) Frame {
    const area: rl.Rectangle = .{ .x = inner.x + 58, .y = inner.y + 6, .width = inner.width - 70, .height = inner.height - 52 - legend_height };
    const x_step = numbers.niceStep(x_range_data.high - x_range_data.low, 6);
    const y_step = numbers.niceStep(y_range_data.high - y_range_data.low, 5);
    const frame: Frame = .{ .area = area, .x_range = x_range_data, .y_range = y_range_data };
    var buffer: [32]u8 = undefined;
    // grade e marcas de x
    var x = @ceil(x_range_data.low / x_step) * x_step;
    while (x <= x_range_data.high + x_step * 1e-9) : (x += x_step) {
        const p = frame.toScreen(x, y_range_data.low);
        const is_zero = @abs(x) < x_step * 1e-6;
        rl.drawLineEx(.{ .x = p.x, .y = area.y }, .{ .x = p.x, .y = area.y + area.height }, 1, if (is_zero) theme.line else theme.grid);
        const tick = tickText(&buffer, x, x_step);
        const w = theme.textWidth(ui.fonts.mono, tick, 12);
        theme.text(ui.fonts.mono, tick, p.x - w / 2, area.y + area.height + 6, 12, theme.muted);
    }
    // grade e marcas de y
    var y = @ceil(y_range_data.low / y_step) * y_step;
    while (y <= y_range_data.high + y_step * 1e-9) : (y += y_step) {
        const p = frame.toScreen(x_range_data.low, y);
        const is_zero = @abs(y) < y_step * 1e-6;
        rl.drawLineEx(.{ .x = area.x, .y = p.y }, .{ .x = area.x + area.width, .y = p.y }, 1, if (is_zero) theme.line else theme.grid);
        const tick = tickText(&buffer, y, y_step);
        const w = theme.textWidth(ui.fonts.mono, tick, 12);
        theme.text(ui.fonts.mono, tick, area.x - w - 8, p.y - 7, 12, theme.muted);
    }
    // rótulos dos eixos
    const xw = theme.textWidth(ui.fonts.regular, axes.x_label, 13);
    theme.text(ui.fonts.regular, axes.x_label, area.x + (area.width - xw) / 2, area.y + area.height + 24, 13, theme.label);
    const yw = theme.textWidth(ui.fonts.regular, axes.y_label, 13);
    rl.drawTextPro(ui.fonts.regular, axes.y_label, .{ .x = inner.x + 2, .y = area.y + (area.height + yw) / 2 }, .{ .x = 0, .y = 0 }, -90, 13, theme.spacing(13), theme.label);
    return frame;
}

fn tickText(buffer: []u8, value: f64, step: f64) [:0]const u8 {
    const decimals = numbers.decimalsFor(step);
    const v = if (@abs(value) < step * 1e-6) 0 else value;
    return switch (decimals) {
        0 => std.fmt.bufPrintZ(buffer, "{d:.0}", .{v}),
        1 => std.fmt.bufPrintZ(buffer, "{d:.1}", .{v}),
        2 => std.fmt.bufPrintZ(buffer, "{d:.2}", .{v}),
        3 => std.fmt.bufPrintZ(buffer, "{d:.3}", .{v}),
        else => std.fmt.bufPrintZ(buffer, "{e:.1}", .{v}),
    } catch "…";
}

fn dashedLine(a: rl.Vector2, b: rl.Vector2, color: rl.Color) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.5) return;
    const dash: f32 = 7;
    var s: f32 = 0;
    while (s < length) : (s += dash * 2) {
        const e = @min(s + dash, length);
        rl.drawLineEx(.{ .x = a.x + dx * s / length, .y = a.y + dy * s / length }, .{ .x = a.x + dx * e / length, .y = a.y + dy * e / length }, 2.2, color);
    }
}

const legend_row: f32 = 18;

fn legendItemWidth(ui: *widgets.Ui, name: [:0]const u8) f32 {
    return 28 + theme.textWidth(ui.fonts.regular, name, 12) + 18;
}

fn legendHeight(ui: *widgets.Ui, width: f32, series: []const Series) f32 {
    if (series.len == 0) return 0;
    var rows: f32 = 1;
    var x: f32 = 0;
    for (series) |s| {
        const w = legendItemWidth(ui, s.name);
        if (x > 0 and x + w > width - 20) {
            rows += 1;
            x = 0;
        }
        x += w;
    }
    return rows * legend_row + 6;
}

fn drawLegend(ui: *widgets.Ui, rect: rl.Rectangle, series: []const Series) void {
    var x = rect.x;
    var y = rect.y;
    for (series, 0..) |s, i| {
        const w = legendItemWidth(ui, s.name);
        if (x > rect.x and x + w > rect.x + rect.width) {
            x = rect.x;
            y += legend_row;
        }
        const color = theme.plotColor(s.color_index orelse i);
        if (s.points) rl.drawCircleV(.{ .x = x + 11, .y = y + 7 }, 3.5, color) else if (s.dashed) dashedLine(.{ .x = x, .y = y + 7 }, .{ .x = x + 22, .y = y + 7 }, color) else rl.drawLineEx(.{ .x = x, .y = y + 7 }, .{ .x = x + 22, .y = y + 7 }, 2.2, color);
        theme.text(ui.fonts.regular, s.name, x + 28, y, 12, theme.label);
        x += w;
    }
}

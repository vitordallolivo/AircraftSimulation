//! Gráficos de linha em SVG, sem nenhuma dependência: os testes do núcleo desenham o que calcularam, para o dono
//! conferir de olho. Um teste chama `fromTest("nome", figura)`. Isso só grava quando o teste roda com
//! `-Dgraficos=<pasta>` e não faz nada no resto do tempo. Exemplo:
//!
//!     zig build test -Darquivo=loads/vn.zig -Dgraficos=graficos
//!
//! roda só os testes de `src/loads/vn.zig` e deixa `graficos/<nome>.svg`, que abre em qualquer navegador.
const std = @import("std");

/// uma curva: nome na legenda, os pontos e o jeito de desenhar
pub const Series = struct {
    label: []const u8,
    x: []const f64,
    y: []const f64,
    style: Style = .line,
};

pub const Style = enum { line, dashed, points };

/// um gráfico: título curto, nomes dos eixos e as curvas
pub const Figure = struct {
    title: []const u8,
    x_label: []const u8,
    y_label: []const u8,
    series: []const Series,
};

const width = 760.0;
const height = 460.0;
const left = 78.0;
const right = 24.0;
const top = 44.0;
const bottom = 58.0;
const palette = [_][]const u8{ "#2b6cb0", "#c05621", "#2f855a", "#9b2c2c", "#6b46c1", "#b7791f", "#2c7a7b", "#4a5568" };

/// o intervalo de uma escala com marcas redondas (1, 2 ou 5 vezes uma potência de 10)
const Scale = struct {
    low: f64,
    high: f64,
    step: f64,

    fn of(data_low: f64, data_high: f64) Scale {
        var low = data_low;
        var high = data_high;
        if (!(high > low)) {
            const pad = if (low == 0) 1 else @abs(low) * 0.1;
            low -= pad;
            high += pad;
        }
        const rough = (high - low) / 6;
        const power = std.math.pow(f64, 10, @floor(std.math.log10(rough)));
        const fraction = rough / power;
        const step = power * @as(f64, if (fraction < 1.5) 1 else if (fraction < 3.5) 2 else if (fraction < 7.5) 5 else 10);
        return .{ .low = @floor(low / step) * step, .high = @ceil(high / step) * step, .step = step };
    }

    fn place(scale: Scale, value: f64, from: f64, to: f64) f64 {
        return from + (value - scale.low) / (scale.high - scale.low) * (to - from);
    }
};

/// escreve o gráfico em SVG
pub fn writeSvg(writer: *std.Io.Writer, figure: Figure) !void {
    var x_low = std.math.inf(f64);
    var x_high = -std.math.inf(f64);
    var y_low = std.math.inf(f64);
    var y_high = -std.math.inf(f64);
    for (figure.series) |series| {
        for (series.x, series.y) |x, y| {
            if (!std.math.isFinite(x) or !std.math.isFinite(y)) continue;
            x_low = @min(x_low, x);
            x_high = @max(x_high, x);
            y_low = @min(y_low, y);
            y_high = @max(y_high, y);
        }
    }
    if (!std.math.isFinite(x_low)) {
        x_low = 0;
        x_high = 1;
        y_low = 0;
        y_high = 1;
    }
    const x_scale = Scale.of(x_low, x_high);
    const y_scale = Scale.of(y_low, y_high);
    const plot_right = width - right;
    const plot_bottom = height - bottom;
    try writer.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" font-family=\"sans-serif\" font-size=\"13\">\n", .{ width, height, width, height });
    try writer.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n");
    try writer.writeAll("<text x=\"380\" y=\"26\" text-anchor=\"middle\" font-size=\"16\" font-weight=\"bold\">");
    try escaped(writer, figure.title);
    try writer.writeAll("</text>\n");
    // grade e marcas
    var tick = x_scale.low;
    while (tick <= x_scale.high + 0.5 * x_scale.step) : (tick += x_scale.step) {
        const at = x_scale.place(tick, left, plot_right);
        try writer.print("<line x1=\"{d:.1}\" y1=\"{d}\" x2=\"{d:.1}\" y2=\"{d}\" stroke=\"#e2e8f0\"/>\n", .{ at, top, at, plot_bottom });
        try writer.print("<text x=\"{d:.1}\" y=\"{d}\" text-anchor=\"middle\">{d}</text>\n", .{ at, plot_bottom + 18, rounded(tick, x_scale.step) });
    }
    tick = y_scale.low;
    while (tick <= y_scale.high + 0.5 * y_scale.step) : (tick += y_scale.step) {
        const at = y_scale.place(tick, plot_bottom, top);
        try writer.print("<line x1=\"{d}\" y1=\"{d:.1}\" x2=\"{d}\" y2=\"{d:.1}\" stroke=\"#e2e8f0\"/>\n", .{ left, at, plot_right, at });
        try writer.print("<text x=\"{d}\" y=\"{d:.1}\" text-anchor=\"end\">{d}</text>\n", .{ left - 6, at + 4, rounded(tick, y_scale.step) });
    }
    try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"none\" stroke=\"#4a5568\"/>\n", .{ left, top, plot_right - left, plot_bottom - top });
    try writer.print("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\">", .{ 0.5 * (left + plot_right), height - 14 });
    try escaped(writer, figure.x_label);
    try writer.print("</text>\n<text x=\"18\" y=\"{d}\" text-anchor=\"middle\" transform=\"rotate(-90 18 {d})\">", .{ 0.5 * (top + plot_bottom), 0.5 * (top + plot_bottom) });
    try escaped(writer, figure.y_label);
    try writer.writeAll("</text>\n");
    // curvas
    for (figure.series, 0..) |series, index| {
        const color = palette[index % palette.len];
        if (series.style == .points) {
            for (series.x, series.y) |x, y| {
                if (!std.math.isFinite(x) or !std.math.isFinite(y)) continue;
                try writer.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"3.5\" fill=\"{s}\"/>\n", .{ x_scale.place(x, left, plot_right), y_scale.place(y, plot_bottom, top), color });
            }
        } else {
            try writer.print("<polyline fill=\"none\" stroke=\"{s}\" stroke-width=\"2\"{s} points=\"", .{ color, if (series.style == .dashed) " stroke-dasharray=\"7 5\"" else "" });
            for (series.x, series.y) |x, y| {
                if (!std.math.isFinite(x) or !std.math.isFinite(y)) continue;
                try writer.print("{d:.1},{d:.1} ", .{ x_scale.place(x, left, plot_right), y_scale.place(y, plot_bottom, top) });
            }
            try writer.writeAll("\"/>\n");
        }
        // legenda no canto de cima à direita
        const row = top + 16 + 18 * @as(f64, @floatFromInt(index));
        try writer.print("<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"3\"/>\n", .{ plot_right - 170, row - 4, plot_right - 150, row - 4, color });
        try writer.print("<text x=\"{d}\" y=\"{d}\">", .{ plot_right - 144, row });
        try escaped(writer, series.label);
        try writer.writeAll("</text>\n");
    }
    try writer.writeAll("</svg>\n");
}

/// a marca sem o ruído de ponto flutuante (0.30000000000000004 → 0.3)
fn rounded(value: f64, step: f64) f64 {
    const digits = @max(0, -@floor(std.math.log10(step)) + 1);
    const factor = std.math.pow(f64, 10, digits);
    return @round(value * factor) / factor;
}

/// o texto com &, < e > escapados
fn escaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        else => try writer.writeByte(c),
    };
}

/// grava `directory/name.svg`, criando a pasta se faltar
pub fn save(gpa: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, figure: Figure) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeSvg(&out.writer, figure);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}.svg", .{ directory, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// dentro de um teste: grava o gráfico se o teste roda com `-Dgraficos=<pasta>`; sem a opção, não faz nada
pub fn fromTest(name: []const u8, figure: Figure) !void {
    const directory = @import("test_options").plot_dir;
    if (directory.len == 0) return;
    try save(std.testing.allocator, std.testing.io, directory, name, figure);
}

test "gráfico: o SVG tem uma polilinha por curva e a legenda" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const x = [_]f64{ 0, 1, 2, 3 };
    const y = [_]f64{ 0, 1, 4, 9 };
    try writeSvg(&out.writer, .{ .title = "y = x²", .x_label = "x", .y_label = "y", .series = &.{
        .{ .label = "x²", .x = &x, .y = &y },
        .{ .label = "pontos", .x = &x, .y = &y, .style = .points },
    } });
    const text = out.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "<polyline"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "<circle"));
    try std.testing.expect(std.mem.indexOf(u8, text, "pontos") != null);
    try fromTest("exemplo_parabola", .{ .title = "y = x²", .x_label = "x", .y_label = "y", .series = &.{.{ .label = "x²", .x = &x, .y = &y }} });
}

//! O campo de voo como formas simples (sem modelos 3D): chão com grade, pista com marcas a cada
//! 10 m, linha do x_warning, mesa/plataforma (os mesmos pads da física) e o percurso planejado.
//! Só dados (NED); o `gfx/render.zig` desenha. Testável sem janela.
const std = @import("std");
const core = @import("aerosim");
const v3 = @import("../math/vec3.zig");
const fz = @import("../util/fuzz.zig");

const T = core.types;
const V3 = v3.V3;

pub const Rgba = [4]u8;
pub const colors = struct {
    pub const ground: Rgba = .{ 86, 168, 62, 255 }; // grama
    pub const grid: Rgba = .{ 20, 70, 10, 40 };
    pub const grid_major: Rgba = .{ 20, 70, 10, 80 };
    pub const runway: Rgba = .{ 72, 76, 84, 255 };
    pub const wind: Rgba = .{ 255, 255, 255, 90 };
    pub const mark: Rgba = .{ 250, 250, 250, 255 };
    pub const warning: Rgba = .{ 214, 39, 40, 255 };
    pub const table: Rgba = .{ 150, 110, 70, 255 };
    pub const platform: Rgba = .{ 110, 140, 180, 255 };
    pub const path: Rgba = .{ 31, 119, 180, 150 };
};

/// caixa: centro da base no chão (n, e), rumo, comprimento, largura, altura
pub const Box = struct { n: f64, e: f64, chi: f64, L: f64, W: f64, h: f64, color: Rgba };
pub const Line = struct { a: V3, b: V3, color: Rgba };

pub const max_lines = 2048;
pub const max_boxes = 16;

pub const Field = struct {
    half: f64 = 300, // o chão vai de −half a +half (m) em n e e
    boxes: [max_boxes]Box = undefined,
    n_boxes: usize = 0,
    lines: [max_lines]Line = undefined,
    n_lines: usize = 0,
    runway: Box = undefined,

    fn line(f: *Field, a: V3, b: V3, c: Rgba) void {
        if (f.n_lines < max_lines and v3.finite(a) and v3.finite(b)) {
            f.lines[f.n_lines] = .{ .a = a, .b = b, .color = c };
            f.n_lines += 1;
        }
    }
    fn box(f: *Field, b: Box) void {
        if (f.n_boxes < max_boxes) {
            f.boxes[f.n_boxes] = b;
            f.n_boxes += 1;
        }
    }
    pub fn lineSlice(f: *const Field) []const Line {
        return f.lines[0..f.n_lines];
    }
    pub fn boxSlice(f: *const Field) []const Box {
        return f.boxes[0..f.n_boxes];
    }
};

fn sane(x: f64, lo: f64, hi: f64, d: f64) f64 {
    return if (std.math.isFinite(x)) std.math.clamp(x, lo, hi) else d;
}

/// monta o campo: x_warning (m), segmentos e pads do núcleo
pub fn build(x_warning: f64, segs: []const T.Segment, pads: []const T.Pad) Field {
    var f: Field = .{};
    const xw = sane(x_warning, 1, 2000, 60);
    // grade do chão: 10 m (fraca) e 50 m (forte), mais fina perto da pista
    var k: f64 = -f.half;
    while (k <= f.half) : (k += 10) {
        const c = if (@mod(k, 50) == 0) colors.grid_major else colors.grid;
        f.line(.{ k, -f.half, -0.02 }, .{ k, f.half, -0.02 }, c);
        f.line(.{ -f.half, k, -0.02 }, .{ f.half, k, -0.02 }, c);
    }
    // pista ao longo de n (a partida é n = 0, rumo norte)
    const len = @max(xw + 30, 120);
    f.runway = .{ .n = len / 2 - 10, .e = 0, .chi = 0, .L = len, .W = 8, .h = 0.03, .color = colors.runway };
    var s: f64 = 0;
    while (s <= len - 10) : (s += 10) { // eixo tracejado e marcas laterais a cada 10 m
        f.line(.{ s, 0, -0.05 }, .{ s + 5, 0, -0.05 }, colors.mark);
        f.line(.{ s, -3.6, -0.05 }, .{ s, -2.6, -0.05 }, colors.mark);
        f.line(.{ s, 2.6, -0.05 }, .{ s, 3.6, -0.05 }, colors.mark);
    }
    f.line(.{ xw, -5, -0.06 }, .{ xw, 5, -0.06 }, colors.warning); // x_warning
    f.line(.{ xw, -5, -0.06 }, .{ xw, -5, -1.5 }, colors.warning);
    f.line(.{ xw, 5, -0.06 }, .{ xw, 5, -1.5 }, colors.warning);
    // mesa e plataforma (os mesmos da física)
    for (pads, 0..) |p, i| {
        if (!(std.math.isFinite(p.n0) and std.math.isFinite(p.e0) and std.math.isFinite(p.chi) and p.L > 0 and p.W > 0 and p.h > 0)) continue;
        const L_ = sane(p.L, 0.1, 2000, 1);
        f.box(.{ .n = p.n0 + 0.5 * L_ * @cos(p.chi), .e = p.e0 + 0.5 * L_ * @sin(p.chi), .chi = p.chi, .L = L_, .W = sane(p.W, 0.1, 200, 1), .h = sane(p.h, 0.01, 100, 1), .color = if (i == 0 and p.n0 <= 0) colors.table else colors.platform });
    }
    // percurso planejado (altura de cada perna, a cada ~5 m)
    for (segs) |sg| {
        const L_ = sane(sg.L, 0, 1e4, 0);
        const nstep: usize = @intFromFloat(@min(@max(L_ / 5, 2), 200));
        var prev: ?V3 = null;
        for (0..nstep + 1) |i| {
            const fr = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nstep));
            const h = sg.h0 + (sg.h1 - sg.h0) * 0.5 * (1 - @cos(std.math.pi * fr));
            var p: V3 = undefined;
            if (sg.arc != 0 and sg.R > 0) {
                const fi0 = std.math.atan2(sg.e0 - sg.ce, sg.n0 - sg.cn);
                const fi = fi0 + sg.lam * fr * L_ / sg.R;
                p = .{ sg.cn + sg.R * @cos(fi), sg.ce + sg.R * @sin(fi), -h };
            } else {
                p = .{ sg.n0 + fr * L_ * @cos(sg.chi0), sg.e0 + fr * L_ * @sin(sg.chi0), -h };
            }
            if (prev) |q| f.line(q, p, colors.path);
            prev = p;
        }
    }
    return f;
}

/// setas fracas do vento em volta de (n, e): grade de `spacing` m em três alturas, andando com o
/// vento (`t` em s) para dar a ideia de fluxo. `from_deg`: de onde vem (0 = norte, 90 = leste).
pub fn windArrows(n: f64, e: f64, from_deg: f64, speed: f64, t: f64, out: []Line) []Line {
    var k: usize = 0;
    const v = if (std.math.isFinite(speed)) std.math.clamp(speed, 0, 30) else 0;
    if (v < 0.2 or !std.math.isFinite(n) or !std.math.isFinite(e) or @abs(n) > 1e6 or @abs(e) > 1e6) return out[0..0];
    const to = std.math.degreesToRadians(if (std.math.isFinite(from_deg)) from_deg else 0) + std.math.pi; // para onde sopra
    const dir: [2]f64 = .{ @cos(to), @sin(to) };
    const side: [2]f64 = .{ -dir[1], dir[0] };
    const spacing = 14.0;
    const len = 1.5 + 0.35 * v;
    const shift = @mod(if (std.math.isFinite(t)) t * v else 0, spacing);
    const n0 = @floor(n / spacing) * spacing;
    const e0 = @floor(e / spacing) * spacing;
    const heights = [_]f64{ 1.5, 7, 15 };
    var i: i32 = -3;
    while (i <= 3) : (i += 1) {
        var j: i32 = -3;
        while (j <= 3) : (j += 1) for (heights) |h| {
            if (k + 3 > out.len) return out[0..k];
            const pn = n0 + @as(f64, @floatFromInt(i)) * spacing + dir[0] * shift;
            const pe = e0 + @as(f64, @floatFromInt(j)) * spacing + dir[1] * shift;
            const a: V3 = .{ pn, pe, -h };
            const b: V3 = .{ pn + dir[0] * len, pe + dir[1] * len, -h };
            const hl = 0.3 * len;
            out[k] = .{ .a = a, .b = b, .color = colors.wind };
            out[k + 1] = .{ .a = b, .b = .{ b[0] - dir[0] * hl + side[0] * 0.5 * hl, b[1] - dir[1] * hl + side[1] * 0.5 * hl, -h }, .color = colors.wind };
            out[k + 2] = .{ .a = b, .b = .{ b[0] - dir[0] * hl - side[0] * 0.5 * hl, b[1] - dir[1] * hl - side[1] * 0.5 * hl, -h }, .color = colors.wind };
            k += 3;
        };
    }
    return out[0..k];
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "vento de norte sopra para o sul" {
    var buf: [600]Line = undefined;
    const l = windArrows(0, 0, 0, 5, 0, &buf);
    try testing.expect(l.len > 0);
    try testing.expect(l[0].b[0] < l[0].a[0]); // aponta para −n
    try testing.expectEqual(@as(usize, 0), windArrows(0, 0, 0, 0, 0, &buf).len);
}

fn fuzzWind(_: void, src: *fz.Src) anyerror!void {
    var buf: [700]Line = undefined;
    const l = windArrows(src.mostly(-500, 500), src.mostly(-500, 500), src.any(), src.any(), src.any(), buf[0..src.int(u16, 0, 700)]);
    for (l) |x| try testing.expect(v3.finite(x.a) and v3.finite(x.b));
}

test "fuzz: setas do vento" {
    try fz.check({}, fuzzWind, .{});
}

test "pista até depois do x_warning, com a linha vermelha nele; mesa vira caixa" {
    const pads = [_]T.Pad{.{ .n0 = -1, .e0 = 0, .chi = 0, .L = 16, .W = 2, .h = 1 }};
    const f = build(60, &.{}, &pads);
    try testing.expect(f.runway.n + f.runway.L / 2 > 60);
    var red = false;
    for (f.lineSlice()) |l| if (std.mem.eql(u8, &l.color, &colors.warning) and l.a[0] == 60) {
        red = true;
    };
    try testing.expect(red);
    try testing.expectEqual(@as(usize, 1), f.n_boxes);
    try testing.expectApproxEqAbs(@as(f64, 7), f.boxes[0].n, 1e-12);
}

fn fuzzField(_: void, src: *fz.Src) anyerror!void {
    var segs: [8]T.Segment = undefined;
    const ns = src.int(u8, 0, 8);
    for (segs[0..ns]) |*s| s.* = .{ .arc = @intFromBool(src.boolean()), .n0 = src.mostly(-300, 300), .e0 = src.mostly(-300, 300), .chi0 = src.mostly(-4, 4), .L = src.mostly(0, 600), .cn = src.mostly(-300, 300), .ce = src.mostly(-300, 300), .R = src.mostly(0, 200), .lam = if (src.boolean()) 1 else -1, .h0 = src.mostly(0, 50), .h1 = src.mostly(0, 50) };
    var pads: [4]T.Pad = undefined;
    const np_ = src.int(u8, 0, 4);
    for (pads[0..np_]) |*p| p.* = .{ .n0 = src.mostly(-10, 300), .e0 = src.mostly(-50, 50), .chi = src.mostly(-4, 4), .L = src.mostly(0, 100), .W = src.mostly(0, 10), .h = src.mostly(0, 3) };
    const f = build(src.mostly(1, 300), segs[0..ns], pads[0..np_]);
    for (f.lineSlice()) |l| try testing.expect(v3.finite(l.a) and v3.finite(l.b));
    for (f.boxSlice()) |b| try testing.expect(std.math.isFinite(b.n) and std.math.isFinite(b.e) and b.L > 0 and b.h > 0);
}

test "fuzz: campo" {
    try fz.check({}, fuzzField, .{});
}

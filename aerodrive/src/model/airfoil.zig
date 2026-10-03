//! Perfil 2D (x/c, y/c): NACA de 4 dígitos pelo nome ou as coordenadas do arquivo do avião.
//! Mesmas contas da GUI (`aerosim/model/airfoil.py: naca4` e o reamostrar para 80 pontos de
//! `geometry.surface_mesh`), para o desenho sair igual.
const std = @import("std");
const fz = @import("../util/fuzz.zig");

pub const max_points = 80; // pontos usados no desenho (como na GUI)
pub const max_input = 1024; // mais que isso no arquivo: erro (arquivo estragado)

pub const Error = error{ InvalidAirfoil, TooManyPoints };

/// contorno fechado: bordo de fuga -> extradorso -> bordo de ataque -> intradorso
pub const Profile = struct {
    pts: [max_input][2]f64 = undefined,
    n: usize = 0,

    pub fn slice(p: *const Profile) []const [2]f64 {
        return p.pts[0..p.n];
    }
};

/// "NACA 2412", "2412" -> m, p, t; qualquer outra coisa -> 0012 (igual à GUI)
pub fn nacaDigits(name: []const u8) [3]f64 {
    var d: [4]u8 = undefined;
    var k: usize = 0;
    var total: usize = 0;
    for (name) |ch| {
        if (ch >= '0' and ch <= '9') {
            if (k < 4) d[k] = ch - '0';
            k += 1;
            total += 1;
        }
    }
    if (total != 4) d = .{ 0, 0, 1, 2 };
    return .{ @as(f64, @floatFromInt(d[0])) / 100.0, @as(f64, @floatFromInt(d[1])) / 10.0, @as(f64, @floatFromInt(@as(u32, d[2]) * 10 + d[3])) / 100.0 };
}

/// NACA 4 dígitos, espaçamento cosseno, `n` pontos por lado (121 pontos com n = 61)
pub fn naca4(name: []const u8, out: *Profile) void {
    const n: usize = 61;
    const mpt = nacaDigits(name);
    const m = mpt[0];
    const p = mpt[1];
    const t = mpt[2];
    var up: [61][2]f64 = undefined;
    var lo: [61][2]f64 = undefined;
    for (0..n) |i| {
        const x = 0.5 * (1.0 - @cos(std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1))));
        const yt = 5.0 * t * (0.2969 * @sqrt(x) - 0.1260 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x);
        var yc: f64 = 0;
        var dyc: f64 = 0;
        if (m > 0 and p > 0) {
            if (x < p) {
                yc = m / (p * p) * (2 * p * x - x * x);
                dyc = 2 * m / (p * p) * (p - x);
            } else {
                yc = m / ((1 - p) * (1 - p)) * ((1 - 2 * p) + 2 * p * x - x * x);
                dyc = 2 * m / ((1 - p) * (1 - p)) * (p - x);
            }
        }
        const th = std.math.atan(dyc);
        up[i] = .{ x - yt * @sin(th), yc + yt * @cos(th) };
        lo[i] = .{ x + yt * @sin(th), yc - yt * @cos(th) };
    }
    out.n = 0;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        out.pts[out.n] = up[i];
        out.n += 1;
    }
    for (lo[1..]) |q| {
        out.pts[out.n] = q;
        out.n += 1;
    }
}

/// perfil para desenhar: coordenadas do arquivo (se houver) ou NACA pelo nome; no máximo 80 pontos
pub fn forDrawing(name: []const u8, coords: []const [2]f64, out: *Profile) Error!void {
    var full: Profile = .{};
    if (coords.len == 0) {
        naca4(name, &full);
    } else {
        if (coords.len < 3) return error.InvalidAirfoil;
        if (coords.len > max_input) return error.TooManyPoints;
        for (coords, 0..) |q, k| {
            if (!std.math.isFinite(q[0]) or !std.math.isFinite(q[1]) or @abs(q[0]) > 2 or @abs(q[1]) > 2)
                return error.InvalidAirfoil;
            full.pts[k] = q;
        }
        full.n = coords.len;
    }
    if (full.n > max_points) { // np.linspace(0, n − 1, 80).astype(int)
        for (0..max_points) |k| {
            const f = @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(full.n - 1)) / @as(f64, @floatFromInt(max_points - 1));
            out.pts[k] = full.pts[@min(@as(usize, @intFromFloat(@floor(f))), full.n - 1)];
        }
        out.n = max_points;
    } else {
        out.* = full;
    }
}

/// corta o contorno em x/c = xh: parte fixa (frente), parte móvel (comando) e o ponto médio da
/// articulação. Mesmo algoritmo de `skeleton._split_profile` na documentação.
pub fn split(af: []const [2]f64, xh: f64, main: *Profile, flap: *Profile) [2]f64 {
    var ile: usize = 0;
    for (af, 0..) |q, k| {
        if (q[0] < af[ile][0]) ile = k;
    }
    const yu = interpSide(af, ile, xh, true);
    const yl = interpSide(af, ile, xh, false);
    main.n = 0;
    flap.n = 0;
    push(main, .{ xh, yu });
    for (af[0 .. ile + 1]) |q| if (q[0] < xh) push(main, q);
    for (af[ile..]) |q| if (q[0] < xh) push(main, q);
    push(main, .{ xh, yl });
    for (af[0 .. ile + 1]) |q| if (q[0] > xh) push(flap, q);
    push(flap, .{ xh, yu });
    push(flap, .{ xh, yl });
    for (af[ile..]) |q| if (q[0] > xh) push(flap, q);
    return .{ xh, 0.5 * (yu + yl) };
}

fn push(p: *Profile, q: [2]f64) void {
    if (p.n < p.pts.len) {
        p.pts[p.n] = q;
        p.n += 1;
    }
}

/// y do extradorso (BF->BA, índices 0..ile) ou do intradorso (ile..fim) em x; fora: ponta mais perto
fn interpSide(af: []const [2]f64, ile: usize, x: f64, upper: bool) f64 {
    const s = if (upper) af[0 .. ile + 1] else af[ile..];
    var best = s[0][1];
    var bd: f64 = std.math.inf(f64);
    for (s[0 .. s.len - 1], s[1..]) |a, b| {
        const lo = @min(a[0], b[0]);
        const hi = @max(a[0], b[0]);
        if (x >= lo and x <= hi) {
            const f = if (hi - lo > 1e-12) (x - a[0]) / (b[0] - a[0]) else 0.0;
            return a[1] + f * (b[1] - a[1]);
        }
        const d = @min(@abs(x - a[0]), @abs(x - b[0]));
        if (d < bd) {
            bd = d;
            best = if (@abs(x - a[0]) < @abs(x - b[0])) a[1] else b[1];
        }
    }
    return best;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "NACA 2412: 121 pontos, BF em x = 1, BA em x = 0, espessura 12 %" {
    var p: Profile = .{};
    naca4("NACA 2412", &p);
    try testing.expectEqual(@as(usize, 121), p.n);
    try testing.expectApproxEqAbs(@as(f64, 1), p.pts[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), p.pts[60][0], 1e-9);
    var d: Profile = .{};
    try forDrawing("NACA 2412", &.{}, &d);
    try testing.expectEqual(@as(usize, 80), d.n);
}

test "nome sem 4 dígitos vira 0012; coordenadas ruins dão erro" {
    try testing.expectEqual(@as(f64, 0.12), nacaDigits("Eppler E")[2]);
    var d: Profile = .{};
    try testing.expectError(error.InvalidAirfoil, forDrawing("x", &.{ .{ 0, 0 }, .{ 1, 0 } }, &d));
    try testing.expectError(error.InvalidAirfoil, forDrawing("x", &.{ .{ 0, 0 }, .{ 1, std.math.nan(f64) }, .{ 0.5, 0.1 } }, &d));
}

test "corte do comando: as duas partes fecham na articulação" {
    var af: Profile = .{};
    try forDrawing("NACA 0012", &.{}, &af);
    var m: Profile = .{};
    var f: Profile = .{};
    const h = split(af.slice(), 0.75, &m, &f);
    try testing.expectApproxEqAbs(@as(f64, 0.75), h[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), h[1], 1e-4); // simétrico (a menos do reamostrar)
    for (m.slice()) |q| try testing.expect(q[0] <= 0.75 + 1e-12);
    for (f.slice()) |q| try testing.expect(q[0] >= 0.75 - 1e-12);
}

fn fuzzAirfoil(_: void, src: *fz.Src) anyerror!void {
    // nome qualquer e coordenadas quaisquer: ou dá erro, ou um perfil finito com ≤ 80 pontos
    var name_buf: [16]u8 = undefined;
    const nl = src.bytes(&name_buf);
    var coords: [300][2]f64 = undefined;
    const nc = src.int(u16, 0, 300);
    for (coords[0..nc]) |*q| q.* = .{ src.any(), src.any() };
    var out: Profile = .{};
    forDrawing(name_buf[0..nl], coords[0..nc], &out) catch return;
    try testing.expect(out.n >= 3 and out.n <= max_points);
    for (out.slice()) |q| try testing.expect(std.math.isFinite(q[0]) and std.math.isFinite(q[1]));
    var m: Profile = .{};
    var f: Profile = .{};
    const xh = src.range(0.05, 0.95);
    const h = split(out.slice(), xh, &m, &f);
    try testing.expect(std.math.isFinite(h[1]));
}

test "fuzz: perfil" {
    try fz.check({}, fuzzAirfoil, .{});
}

//! Minimapa (vista de cima, plano XY): escolhe a escala para caber o percurso, o rastro e o avião
//! num quadrado da tela, com o norte para cima. Só as contas; `ui/minimap_view.zig` desenha.
const std = @import("std");
const v3 = @import("../math/vec3.zig");
const fz = @import("../util/fuzz.zig");

pub const Map = struct {
    cn: f64 = 0, // centro (n, e) no mundo
    ce: f64 = 0,
    scale: f64 = 1, // px por metro
    x: f64 = 0, // centro na tela
    y: f64 = 0,

    /// cobre a caixa [n0..n1]×[e0..e1] num quadrado de lado `size` px centrado em (x, y)
    pub fn fit(n0: f64, n1: f64, e0: f64, e1: f64, x: f64, y: f64, size: f64) Map {
        const span = @max(@max(n1 - n0, e1 - e0), 20) * 1.15; // 15 % de folga, ao menos 20 m
        const ok = std.math.isFinite(span) and std.math.isFinite(n0 + n1 + e0 + e1) and span < 1e7 and size > 1;
        if (!ok) return .{ .x = x, .y = y, .scale = if (size > 1 and std.math.isFinite(size)) size / 200 else 1 };
        return .{ .cn = 0.5 * (n0 + n1), .ce = 0.5 * (e0 + e1), .scale = size / span, .x = x, .y = y };
    }

    /// mundo (n, e) → tela (x à direita = leste, y para baixo = sul)
    pub fn toScreen(m: Map, n: f64, e: f64) [2]f32 {
        const sx = m.x + (e - m.ce) * m.scale;
        const sy = m.y - (n - m.cn) * m.scale;
        return .{ clampPx(sx), clampPx(sy) };
    }
};

/// caixa que contém os pontos (só os finitos)
pub const Bounds = struct {
    n0: f64 = std.math.inf(f64),
    n1: f64 = -std.math.inf(f64),
    e0: f64 = std.math.inf(f64),
    e1: f64 = -std.math.inf(f64),

    pub fn add(b: *Bounds, p: v3.V3) void {
        if (!(std.math.isFinite(p[0]) and std.math.isFinite(p[1]))) return;
        if (@abs(p[0]) > 1e6 or @abs(p[1]) > 1e6) return;
        b.n0 = @min(b.n0, p[0]);
        b.n1 = @max(b.n1, p[0]);
        b.e0 = @min(b.e0, p[1]);
        b.e1 = @max(b.e1, p[1]);
    }

    pub fn map(b: Bounds, x: f64, y: f64, size: f64) Map {
        if (b.n0 > b.n1) return Map.fit(-50, 50, -50, 50, x, y, size);
        return Map.fit(b.n0, b.n1, b.e0, b.e1, x, y, size);
    }
};

fn clampPx(v: f64) f32 {
    return if (std.math.isFinite(v)) @floatCast(std.math.clamp(v, -1e5, 1e5)) else 0;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "norte para cima, leste para a direita, tudo dentro do quadrado" {
    var b: Bounds = .{};
    b.add(.{ 0, 0, 0 });
    b.add(.{ 200, 50, -15 });
    const m = b.map(100, 100, 160);
    const a = m.toScreen(0, 0);
    const c = m.toScreen(200, 50);
    try testing.expect(c[1] < a[1] and c[0] > a[0]);
    for ([_][2]f32{ a, c }) |p| try testing.expect(@abs(p[0] - 100) <= 80 and @abs(p[1] - 100) <= 80);
}

fn fuzzMap(_: void, src: *fz.Src) anyerror!void {
    var b: Bounds = .{};
    while (!src.chance(6)) b.add(.{ src.mostly(-500, 500), src.mostly(-500, 500), 0 });
    const m = b.map(src.mostly(0, 2000), src.mostly(0, 2000), src.mostly(10, 400));
    const p = m.toScreen(src.any(), src.any());
    try testing.expect(std.math.isFinite(p[0]) and std.math.isFinite(p[1]));
}

test "fuzz: minimapa" {
    try fz.check({}, fuzzMap, .{});
}

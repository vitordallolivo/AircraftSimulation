//! Percurso (corrente de segmentos) e guiamento lateral.
//!
//! Reta: campo vetorial  χd = χp − χ∞ (2/π) atan(k e)
//! Arco: órbita           χd = φ + λ (π/2 + atan(k_o (d − R) / max(R, L_orb)))
//! (Beard e McLain, cap. 10). Altura e velocidade de cada segmento vão de (h0, V0) a
//! (h1, V1) por uma curva cosseno; no segmento de pouso a altura cai em rampa.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("../sim/state.zig");
const fmath = @import("../math/fmath.zig");
const terrain = @import("../physics/terrain.zig");

/// o que o guiamento manda para o piloto automático
pub const Guide = struct {
    /// distância percorrida na perna (m)
    s: f64 = 0,
    /// erro lateral (m; + à direita na reta, + por fora no arco)
    ect: f64 = 0,
    /// rumo da perna no ponto (rad)
    chip: f64 = 0,
    /// rumo desejado pelo campo vetorial (rad)
    chid: f64 = 0,
    /// inclinação antecipada para a curva (rad)
    phiff: f64 = 0,
    /// altura pedida no ponto (m)
    hseg: f64 = 0,
    /// velocidade pedida no ponto (m/s)
    Vseg: f64 = 0,
};

/// rampa suave de 0 a 1 (meia volta de cosseno) para `fraction` em [0, 1]
fn smooth(fraction: f64) f64 {
    return 0.5 * (1.0 - fmath.cos(fmath.pi * fmath.lim(fraction, 0.0, 1.0)));
}

/// rumo, altura e velocidade pedidos na posição (north, east) com a velocidade em relação ao chão `ground_speed`
pub fn guide(ctx: state.Ctx, north: f64, east: f64, ground_speed: f64) Guide {
    const params = ctx.p;
    const gains = &params.ap;
    var out = Guide{};
    if (params.n_seg <= 0) return out;
    const seg_index: usize = @intCast(ctx.f.seg);
    const segment = &params.seg[seg_index];
    const has_next = ctx.f.seg + 1 < params.n_seg;
    if (segment.arc == 0) {
        const heading = fmath.sincos(segment.chi0);
        out.s = (north - segment.n0) * heading.c + (east - segment.e0) * heading.s;
        out.ect = -(north - segment.n0) * heading.s + (east - segment.e0) * heading.c; // + : à direita
        out.chip = segment.chi0;
        out.chid = segment.chi0 - gains.chi_inf * (2.0 / fmath.pi) * fmath.atan(gains.kvf * out.ect);
        // antecipação: se a próxima perna é curva, começa a inclinar t_lead s antes
        if (has_next and params.seg[seg_index + 1].arc != 0 and gains.tlead > 0.0) {
            const next_segment = &params.seg[seg_index + 1];
            const lead_fraction = 1.0 - (segment.L - out.s) / (ground_speed * gains.tlead + 1e-6);
            out.phiff = fmath.lim(lead_fraction, 0.0, 1.0) * next_segment.lam * fmath.atan(ground_speed * ground_speed / (limits.g0 * next_segment.R));
        }
    } else {
        const bearing = fmath.atan2(east - segment.ce, north - segment.cn);
        const bearing0 = fmath.atan2(segment.e0 - segment.ce, segment.n0 - segment.cn);
        const radius = fmath.hypot(north - segment.cn, east - segment.ce);
        var swept = segment.lam * (bearing - bearing0);
        while (swept < -0.5 * fmath.pi) swept += 2.0 * fmath.pi;
        while (swept >= 1.5 * fmath.pi) swept -= 2.0 * fmath.pi;
        out.s = segment.R * swept;
        out.ect = segment.lam * (radius - segment.R); // + : por fora
        out.chip = bearing + segment.lam * 0.5 * fmath.pi;
        // ganho da órbita em 1/m limitado: em raio pequeno k_o/R ficaria agressivo demais
        out.chid = bearing + segment.lam * (0.5 * fmath.pi + fmath.atan(gains.korb * (radius - segment.R) / @max(segment.R, gains.Lorb)));
        out.phiff = segment.lam * fmath.atan(ground_speed * ground_speed / (limits.g0 * segment.R));
        if (gains.tlead > 0.0 and has_next and params.seg[seg_index + 1].arc == 0)
            out.phiff *= fmath.lim((segment.L - out.s) / (ground_speed * gains.tlead + 1e-6), 0.0, 1.0);
    }
    const fraction = out.s / segment.L;
    out.hseg = segment.h0 + (segment.h1 - segment.h0) * smooth(fraction);
    out.Vseg = segment.V0 + (segment.V1 - segment.V0) * smooth(fraction);
    if (segment.landing != 0) {
        // mira o terreno no ponto de toque (chão ou plataforma) com as rodas a 10 cm
        const touch_distance = segment.L - segment.clearance;
        const heading = fmath.sincos(segment.chi0);
        const touch_height = if (segment.arc == 0) terrain.height(params, segment.n0 + touch_distance * heading.c, segment.e0 + touch_distance * heading.s) else 0.0;
        out.hseg = segment.h0 + (touch_height + ctx.h_rest + 0.1 - segment.h0) * fmath.lim(out.s / touch_distance, 0.0, 1.0);
    }
    return out;
}

/// ponto da perna na fração `fraction` (0..1): norte, leste, altura
fn segPoint(segment: *const types.Segment, fraction: f64) [3]f64 {
    const height = segment.h0 + (segment.h1 - segment.h0) * smooth(fraction);
    if (segment.arc != 0 and segment.R > 0.0) {
        const bearing0 = fmath.atan2(segment.e0 - segment.ce, segment.n0 - segment.cn);
        const bearing = bearing0 + segment.lam * fraction * segment.L / segment.R;
        return .{ segment.cn + segment.R * fmath.cos(bearing), segment.ce + segment.R * fmath.sin(bearing), height };
    }
    const heading = fmath.sincos(segment.chi0);
    return .{ segment.n0 + fraction * segment.L * heading.c, segment.e0 + fraction * segment.L * heading.s, height };
}

/// perna para retomar o percurso de onde a aeronave está (troca do manual para o automático):
/// a de cruzeiro mais perto (distância + 2 × diferença de altura). Cruzeiro = nem decolagem, nem
/// pouso, nem perna baixa (abaixo de 60 % da altura do circuito). null se não houver.
pub fn rejoinSegment(params: *const types.Params, north: f64, east: f64, height: f64) ?i32 {
    const n_segments: usize = @intCast(std.math.clamp(params.n_seg, 0, limits.max_segments));
    if (n_segments == 0 or !std.math.isFinite(north + east + height)) return null;
    var max_height: f64 = 0;
    for (params.seg[0..n_segments]) |segment| max_height = @max(max_height, @max(segment.h0, segment.h1));
    var best: ?i32 = null;
    var best_distance: f64 = std.math.inf(f64);
    for (params.seg[0..n_segments], 0..) |*segment, k| {
        if (segment.takeoff != 0 or segment.landing != 0 or !(segment.L > 0)) continue;
        if (@min(segment.h0, segment.h1) < 0.6 * max_height) continue;
        for (0..21) |i| {
            const point = segPoint(segment, @as(f64, @floatFromInt(i)) / 20.0);
            const distance = fmath.hypot(point[0] - north, point[1] - east) + 2.0 * @abs(point[2] - height);
            if (distance < best_distance) {
                best_distance = distance;
                best = @intCast(k);
            }
        }
    }
    return best;
}

test "retomada: perna de cruzeiro mais perto, nunca a baixa" {
    var params = types.Params{};
    params.n_seg = 4;
    params.seg[0] = .{ .takeoff = 1, .L = 60, .chi0 = 0, .h0 = 0, .h1 = 15 };
    params.seg[1] = .{ .L = 100, .n0 = 60, .chi0 = 0, .h0 = 15, .h1 = 15 };
    params.seg[2] = .{ .L = 100, .n0 = 160, .e0 = 100, .chi0 = std.math.pi, .h0 = 15, .h1 = 15 };
    params.seg[3] = .{ .L = 100, .n0 = 160, .e0 = 0, .chi0 = 0, .h0 = 2, .h1 = 2 }; // passagem baixa
    try std.testing.expectEqual(@as(?i32, 2), rejoinSegment(&params, 120, 95, 20));
    try std.testing.expectEqual(@as(?i32, 1), rejoinSegment(&params, 200, 0, 3)); // ao lado da baixa: não ela
    try std.testing.expectEqual(@as(?i32, null), rejoinSegment(&params, std.math.nan(f64), 0, 3));
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    for (0..3000) |_| { // percursos e posições quaisquer: índice válido ou null, sem travar
        params.n_seg = random.intRangeAtMost(i32, -2, 6);
        for (&params.seg) |*segment| segment.* = .{ .arc = @intFromBool(random.boolean()), .takeoff = @intFromBool(random.uintLessThan(u8, 5) == 0), .L = random.float(f64) * 300 - 10, .R = random.float(f64) * 80 - 5, .h0 = random.float(f64) * 30, .h1 = random.float(f64) * 30, .lam = 1 };
        const k = rejoinSegment(&params, random.float(f64) * 1e3, random.float(f64) * 1e3, @floatCast(@as(f32, @bitCast(random.int(u32)))));
        if (k) |i| try std.testing.expect(i >= 0 and i < params.n_seg);
    }
}

test "reta: erro lateral e distância" {
    var params = types.Params{};
    params.n_seg = 1;
    params.seg[0] = .{ .L = 100, .chi0 = 0, .h0 = 10, .h1 = 10, .V0 = 15, .V1 = 15 };
    const flags = state.Flags{};
    const ctx = state.Ctx{ .p = &params, .f = &flags, .tR = -1, .h_ground = 0, .tg = -1 };
    const out = guide(ctx, 30, 2, 15);
    try std.testing.expectApproxEqAbs(@as(f64, 30), out.s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), out.ect, 1e-9);
    try std.testing.expect(out.chid < 0);
}

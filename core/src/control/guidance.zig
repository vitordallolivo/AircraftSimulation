//! Percurso (corrente de segmentos) e guiamento lateral.
//!
//! Reta: campo vetorial  χd = χp − χ∞ (2/π) atan(k e)
//! Arco: órbita           χd = φ + λ (π/2 + atan(k_o (d − R) / max(R, L_orb)))
//! (Beard e McLain, cap. 10). Altura e velocidade de cada segmento vão de (h0, V0) a
//! (h1, V1) por uma curva cosseno; no segmento de pouso a altura cai em rampa.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("../sim/state.zig");
const fm = @import("../math/fmath.zig");
const terrain = @import("../physics/terrain.zig");

pub const Guide = struct {
    s: f64 = 0,
    ect: f64 = 0,
    chip: f64 = 0,
    chid: f64 = 0,
    phiff: f64 = 0,
    hseg: f64 = 0,
    Vseg: f64 = 0,
};

fn smooth(x: f64) f64 {
    return 0.5 * (1.0 - fm.cos(fm.pi * fm.lim(x, 0.0, 1.0)));
}

pub fn guide(c: S.Ctx, n: f64, e: f64, Vg: f64) Guide {
    const p = c.p;
    const ap = &p.ap;
    var g = Guide{};
    if (p.n_seg <= 0) return g;
    const k: usize = @intCast(c.f.seg);
    const sg = &p.seg[k];
    const has_next = c.f.seg + 1 < p.n_seg;
    if (sg.arc == 0) {
        const sc = fm.sincos(sg.chi0);
        g.s = (n - sg.n0) * sc.c + (e - sg.e0) * sc.s;
        g.ect = -(n - sg.n0) * sc.s + (e - sg.e0) * sc.c; // + : à direita
        g.chip = sg.chi0;
        g.chid = sg.chi0 - ap.chi_inf * (2.0 / fm.pi) * fm.atan(ap.kvf * g.ect);
        // antecipação: se a próxima perna é curva, começa a inclinar t_lead s antes
        if (has_next and p.seg[k + 1].arc != 0 and ap.tlead > 0.0) {
            const nx = &p.seg[k + 1];
            const w = 1.0 - (sg.L - g.s) / (Vg * ap.tlead + 1e-6);
            g.phiff = fm.lim(w, 0.0, 1.0) * nx.lam * fm.atan(Vg * Vg / (L.g0 * nx.R));
        }
    } else {
        const fi = fm.atan2(e - sg.ce, n - sg.cn);
        const fi0 = fm.atan2(sg.e0 - sg.ce, sg.n0 - sg.cn);
        const d = fm.hypot(n - sg.cn, e - sg.ce);
        var dl = sg.lam * (fi - fi0);
        while (dl < -0.5 * fm.pi) dl += 2.0 * fm.pi;
        while (dl >= 1.5 * fm.pi) dl -= 2.0 * fm.pi;
        g.s = sg.R * dl;
        g.ect = sg.lam * (d - sg.R); // + : por fora
        g.chip = fi + sg.lam * 0.5 * fm.pi;
        // ganho da órbita em 1/m limitado: em raio pequeno k_o/R ficaria agressivo demais
        g.chid = fi + sg.lam * (0.5 * fm.pi + fm.atan(ap.korb * (d - sg.R) / @max(sg.R, ap.Lorb)));
        g.phiff = sg.lam * fm.atan(Vg * Vg / (L.g0 * sg.R));
        if (ap.tlead > 0.0 and has_next and p.seg[k + 1].arc == 0)
            g.phiff *= fm.lim((sg.L - g.s) / (Vg * ap.tlead + 1e-6), 0.0, 1.0);
    }
    const xs = g.s / sg.L;
    g.hseg = sg.h0 + (sg.h1 - sg.h0) * smooth(xs);
    g.Vseg = sg.V0 + (sg.V1 - sg.V0) * smooth(xs);
    if (sg.landing != 0) {
        // mira o terreno no ponto de toque (chão ou plataforma) com as rodas a 10 cm
        const st = sg.L - sg.clearance;
        const sc = fm.sincos(sg.chi0);
        const htd = if (sg.arc == 0) terrain.height(p, sg.n0 + st * sc.c, sg.e0 + st * sc.s) else 0.0;
        g.hseg = sg.h0 + (htd + c.h_rest + 0.1 - sg.h0) * fm.lim(g.s / st, 0.0, 1.0);
    }
    return g;
}

/// ponto da perna na fração `fr` (0..1): n, e, h
fn segPoint(sg: *const T.Segment, fr: f64) [3]f64 {
    const h = sg.h0 + (sg.h1 - sg.h0) * smooth(fr);
    if (sg.arc != 0 and sg.R > 0.0) {
        const fi0 = fm.atan2(sg.e0 - sg.ce, sg.n0 - sg.cn);
        const fi = fi0 + sg.lam * fr * sg.L / sg.R;
        return .{ sg.cn + sg.R * fm.cos(fi), sg.ce + sg.R * fm.sin(fi), h };
    }
    const sc = fm.sincos(sg.chi0);
    return .{ sg.n0 + fr * sg.L * sc.c, sg.e0 + fr * sg.L * sc.s, h };
}

/// perna para retomar o percurso de onde a aeronave está (troca do manual para o automático):
/// a de cruzeiro mais perto (distância + 2 × diferença de altura). Cruzeiro = nem decolagem, nem
/// pouso, nem perna baixa (abaixo de 60 % da altura do circuito). null se não houver.
pub fn rejoinSegment(p: *const T.Params, n: f64, e: f64, h: f64) ?i32 {
    const ns: usize = @intCast(std.math.clamp(p.n_seg, 0, L.max_segments));
    if (ns == 0 or !std.math.isFinite(n + e + h)) return null;
    var hmax: f64 = 0;
    for (p.seg[0..ns]) |sg| hmax = @max(hmax, @max(sg.h0, sg.h1));
    var best: ?i32 = null;
    var bd: f64 = std.math.inf(f64);
    for (p.seg[0..ns], 0..) |*sg, k| {
        if (sg.takeoff != 0 or sg.landing != 0 or !(sg.L > 0)) continue;
        if (@min(sg.h0, sg.h1) < 0.6 * hmax) continue;
        for (0..21) |i| {
            const q = segPoint(sg, @as(f64, @floatFromInt(i)) / 20.0);
            const d = fm.hypot(q[0] - n, q[1] - e) + 2.0 * @abs(q[2] - h);
            if (d < bd) {
                bd = d;
                best = @intCast(k);
            }
        }
    }
    return best;
}

test "retomada: perna de cruzeiro mais perto, nunca a baixa" {
    var p = T.Params{};
    p.n_seg = 4;
    p.seg[0] = .{ .takeoff = 1, .L = 60, .chi0 = 0, .h0 = 0, .h1 = 15 };
    p.seg[1] = .{ .L = 100, .n0 = 60, .chi0 = 0, .h0 = 15, .h1 = 15 };
    p.seg[2] = .{ .L = 100, .n0 = 160, .e0 = 100, .chi0 = std.math.pi, .h0 = 15, .h1 = 15 };
    p.seg[3] = .{ .L = 100, .n0 = 160, .e0 = 0, .chi0 = 0, .h0 = 2, .h1 = 2 }; // passagem baixa
    try std.testing.expectEqual(@as(?i32, 2), rejoinSegment(&p, 120, 95, 20));
    try std.testing.expectEqual(@as(?i32, 1), rejoinSegment(&p, 200, 0, 3)); // ao lado da baixa: não ela
    try std.testing.expectEqual(@as(?i32, null), rejoinSegment(&p, std.math.nan(f64), 0, 3));
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    for (0..3000) |_| { // percursos e posições quaisquer: índice válido ou null, sem travar
        p.n_seg = r.intRangeAtMost(i32, -2, 6);
        for (&p.seg) |*sg| sg.* = .{ .arc = @intFromBool(r.boolean()), .takeoff = @intFromBool(r.uintLessThan(u8, 5) == 0), .L = r.float(f64) * 300 - 10, .R = r.float(f64) * 80 - 5, .h0 = r.float(f64) * 30, .h1 = r.float(f64) * 30, .lam = 1 };
        const k = rejoinSegment(&p, r.float(f64) * 1e3, r.float(f64) * 1e3, @floatCast(@as(f32, @bitCast(r.int(u32)))));
        if (k) |i| try std.testing.expect(i >= 0 and i < p.n_seg);
    }
}

test "reta: erro lateral e distância" {
    var p = T.Params{};
    p.n_seg = 1;
    p.seg[0] = .{ .L = 100, .chi0 = 0, .h0 = 10, .h1 = 10, .V0 = 15, .V1 = 15 };
    const f = S.Flags{};
    const ctx = S.Ctx{ .p = &p, .f = &f, .tR = -1, .h_ground = 0, .tg = -1 };
    const g = guide(ctx, 30, 2, 15);
    try std.testing.expectApproxEqAbs(@as(f64, 30), g.s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), g.ect, 1e-9);
    try std.testing.expect(g.chid < 0);
}

//! Trem de pouso: N pontos de contato (triciclo, convencional, patins...).
//!
//! Cada contato é mola-amortecedor vertical, N = max(0, k d + c d'), com atrito de
//! rolamento na direção da roda e lateral, regularizados por tanh(v / 5 cm/s).
//! O contato direcionável vira com o comando dw. Freio nas principais.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("../sim/state.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const Out = struct {
    F: V3 = vec.zero,
    M: V3 = vec.zero,
    N: [L.max_gear]f64 = [_]f64{0} ** L.max_gear,
};

pub fn compute(c: S.Ctx, x: []const f64, R: vec.M3, rcg: V3, dw: f64) Out {
    var o = Out{};
    const p = c.p;
    const VB = V3{ x[S.U], x[S.V], x[S.W] };
    const w = V3{ x[S.P], x[S.Q], x[S.R] };
    const n: usize = @intCast(p.n_gear);
    for (p.gear[0..n], 0..) |*g, i| {
        const r = vec.v3(g.r);
        const pc = vec.mul(R, r);
        const pen = x[S.D] + pc[2]; // > 0: comprimido
        if (pen <= 0.0) continue;
        const vn = vec.mul(R, VB + vec.cross(w, r));
        const Nn = @max(0.0, g.k * pen + g.c * vn[2]);
        const dir = if (g.kind == T.gear_steer) dw else 0.0;
        const sc = fm.sincos(dir);
        const fn_ = vec.mul(R, V3{ sc.c, sc.s, 0 });
        const fh = fm.hypot(fn_[0], fn_[1]);
        const fx = fn_[0] / fh;
        const fy = fn_[1] / fh;
        const lx = -fy;
        const ly = fx;
        const vl = vn[0] * fx + vn[1] * fy;
        const vt = vn[0] * lx + vn[1] * ly;
        var mu = p.mu_roll;
        var mul = p.mu_lat;
        if (g.kind == T.gear_main and c.f.brakes != 0) mu = p.mu_brake;
        if (g.kind == T.gear_main and c.f.landed != 0) mu = p.mu_landing;
        if (g.kind == T.gear_skid) {
            mu = p.mu_skid;
            mul = p.mu_skid;
        }
        const Fl = -mu * Nn * fm.tanh(vl / 0.05);
        const Ft = -mul * Nn * fm.tanh(vt / 0.05);
        const FB = vec.mulT(R, V3{ Fl * fx + Ft * lx, Fl * fy + Ft * ly, -Nn });
        o.F += FB;
        o.M += vec.cross(r - rcg, FB);
        o.N[i] = Nn;
    }
    return o;
}

/// algum ponto de contato tocando o chão
pub fn touching(p: *const T.Params, x: []const f64, R: vec.M3) bool {
    const n: usize = @intCast(p.n_gear);
    for (p.gear[0..n]) |*g| {
        if (x[S.D] + vec.mul(R, vec.v3(g.r))[2] > 0.0) return true;
    }
    return false;
}

test "apoiado: força vertical equilibra" {
    var p = T.Params{};
    p.n_gear = 1;
    p.gear[0] = .{ .r = .{ 0, 0, 0.2 }, .k = 1000, .c = 0 };
    const f = S.Flags{};
    const ctx = S.Ctx{ .p = &p, .f = &f, .tR = -1, .h_ground = 0, .tg = -1 };
    var x = [_]f64{0} ** S.nx;
    x[S.D] = -0.19; // 1 cm de compressão
    const o = compute(ctx, &x, vec.rotation(0, 0, 0), vec.zero, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -10), o.F[2], 1e-6);
}

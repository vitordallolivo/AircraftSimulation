//! Massa, CG e inércia variáveis; sloshing de N tanques; extração da carga (LAPES).
//!
//! Sloshing: cada tanque é um pêndulo de 2 eixos (ex, ey) com massa m1 e braço l1:
//!   l1 η'' = a_ap,x cos η − a_ap,z sin η − 2 ζ ω1 l1 η'
//! a_ap é a gravidade aparente no corpo (menos a força específica) no ponto do tanque.
//! Carga: o paraquedas puxa com Fext; ela desliza na baia com atrito μ_b; o avião
//! sente só o atrito e o CG que anda para trás.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("../sim/state.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub fn initTanks(p: *types.Params) void {
    const n: usize = @intCast(p.n_tank);
    for (p.tank[0..n]) |*t| {
        if (t.fill <= 0 or t.side <= 0) {
            t.m_liq = 0;
            t.m0 = 0;
            t.m1 = 0;
            t.l1 = 1;
            t.w1 = 1;
            continue;
        }
        if (t.shape == types.tank_cylinder) {
            const xi = 1.841;
            const R = 0.5 * t.side;
            const th = fmath.tanh(xi * t.fill / R);
            t.m_liq = t.rho * fmath.pi * R * R * t.fill;
            t.w1 = @sqrt(limits.g0 * xi / R * th);
            t.m1 = t.m_liq * 2.0 * th / (xi * (xi * xi - 1.0) * t.fill / R);
        } else {
            const k = fmath.pi / t.side;
            const th = fmath.tanh(k * t.fill);
            t.m_liq = t.rho * t.side * t.side * t.fill;
            t.w1 = @sqrt(limits.g0 * k * th);
            t.m1 = t.m_liq * 8.0 * th / (fmath.pi * fmath.pi * fmath.pi * t.fill / t.side);
        }
        t.m1 = @min(t.m1, t.m_liq);
        t.l1 = limits.g0 / (t.w1 * t.w1);
        t.m0 = t.m_liq - t.m1;
    }
}

pub const Mass = struct {
    m: f64,
    rcg: V3,
    I: vec.M3,
    r1: [limits.max_tanks]V3, // posição da massa que oscila de cada tanque
    rL: V3, // posição da carga
};

pub fn compute(c: state.Ctx, x: []const f64) Mass {
    const p = c.p;
    var o: Mass = undefined;
    // inércia seca dada no CG dela; as massas pontuais somam por Steiner
    var I = vec.M3{ .{ p.Ixx, 0, -p.Ixz }, .{ 0, p.Iyy, 0 }, .{ -p.Ixz, 0, p.Izz } };
    var m: f64 = 0;
    var mr = vec.zero;
    const Acc = struct {
        fn add(Ip: *vec.M3, mp: *f64, mrp: *V3, mk: f64, r: V3) void {
            if (mk == 0) return;
            mp.* += mk;
            mrp.* += r * vec.splat(mk);
            const r2 = vec.dot(r, r);
            inline for (0..3) |i| {
                var e = vec.zero;
                e[i] = r2;
                Ip[i] += (e - r * vec.splat(r[i])) * vec.splat(mk);
            }
        }
    };
    Acc.add(&I, &m, &mr, p.m_dry, vec.v3(p.r_dry));
    const n: usize = @intCast(p.n_tank);
    const slosh_on = p.slosh_on != 0;
    for (p.tank[0..n], 0..) |*t, i| {
        const ex = if (slosh_on) x[state.sx(i)] else 0.0;
        const ey = if (slosh_on) x[state.sy(i)] else 0.0;
        const a = fmath.sincos(ex);
        const b = fmath.sincos(ey);
        const rt = vec.v3(t.r);
        o.r1[i] = rt + V3{ t.l1 * a.s, t.l1 * b.s, -t.l1 + t.l1 * a.c * b.c };
        Acc.add(&I, &m, &mr, t.m0, rt);
        Acc.add(&I, &m, &mr, t.m1, o.r1[i]);
    }
    o.rL = V3{ p.payload.r[0] - x[state.SL], p.payload.r[1], p.payload.r[2] };
    if (p.payload.enabled != 0 and c.f.released == 0) Acc.add(&I, &m, &mr, p.payload.m, o.rL);
    o.m = m;
    o.rcg = mr / vec.splat(m);
    const c2 = vec.dot(o.rcg, o.rcg);
    inline for (0..3) |i| {
        var e = vec.zero;
        e[i] = c2;
        o.I[i] = I[i] - (e - o.rcg * vec.splat(o.rcg[i])) * vec.splat(m);
    }
    return o;
}

pub const Load = struct { F: V3 = vec.zero, M: V3 = vec.zero };

/// F_ext: forças externas (sem peso) no corpo; ω; escreve as derivadas dos tanques
pub fn slosh(p: *const types.Params, x: []const f64, F_ext: V3, w: V3, ms: *const Mass, dx: []f64) Load {
    var o = Load{};
    if (p.slosh_on == 0) return o;
    const n: usize = @intCast(p.n_tank);
    for (p.tank[0..n], 0..) |*t, i| {
        if (t.m1 <= 0) continue;
        const rt = vec.v3(t.r);
        const aap = -F_ext / vec.splat(ms.m) - vec.cross(w, vec.cross(w, rt));
        const ex = x[state.sx(i)];
        const ey = x[state.sy(i)];
        const exd = x[state.sxd(i)];
        const eyd = x[state.syd(i)];
        const a = fmath.sincos(ex);
        const b = fmath.sincos(ey);
        const exdd = (aap[0] * a.c - aap[2] * a.s) / t.l1 - 2.0 * t.zeta * t.w1 * exd;
        const eydd = (aap[1] * b.c - aap[2] * b.s) / t.l1 - 2.0 * t.zeta * t.w1 * eyd;
        dx[state.sx(i)] = exd;
        dx[state.sy(i)] = eyd;
        dx[state.sxd(i)] = exdd;
        dx[state.syd(i)] = eydd;
        const arel = V3{ t.l1 * (exdd * a.c - exd * exd * a.s), t.l1 * (eydd * b.c - eyd * eyd * b.s), 0 };
        const F = arel * vec.splat(-t.m1);
        o.F += F;
        o.M += vec.cross(ms.r1[i] - ms.rcg, F);
    }
    return o;
}

/// aap: gravidade aparente no tanque 0 (ou no CG) para o atrito da carga
pub fn payload(c: state.Ctx, x: []const f64, aap: V3, ms: *const Mass, dx: []f64) Load {
    var o = Load{};
    const p = c.p;
    if (c.f.extracting == 0 or c.f.released != 0 or p.payload.enabled == 0) return o;
    const nz = @max(aap[2], 0.0);
    const fr = p.payload.mu_b * p.payload.m * nz;
    dx[state.SL] = x[state.SLD];
    dx[state.SLD] = p.payload.Fext_g * limits.g0 - fr / p.payload.m;
    o.F = V3{ -fr, 0, 0 };
    o.M = vec.cross(ms.rL - ms.rcg, o.F);
    return o;
}

const testing = std.testing;

test "tanque quadrado: frequência e massas" {
    var p = types.Params{};
    p.n_tank = 1;
    p.tank[0] = .{ .side = 0.1, .fill = 0.05, .rho = 1000 };
    initTanks(&p);
    const t = p.tank[0];
    try testing.expectApproxEqAbs(@as(f64, 0.5), t.m_liq, 1e-12);
    const w = @sqrt(limits.g0 * std.math.pi / 0.1 * std.math.tanh(@as(f64, std.math.pi * 0.5)));
    try testing.expectApproxEqRel(w, t.w1, 1e-9);
    try testing.expect(t.m1 > 0 and t.m1 < t.m_liq);
}

test "CG e Steiner" {
    var p = types.Params{ .m_dry = 2, .Ixx = 0, .Iyy = 0, .Izz = 0, .r_dry = .{ 1, 0, 0 } };
    p.payload = .{ .enabled = 1, .m = 2, .r = .{ -1, 0, 0 } };
    const f = state.Flags{};
    const ctx = state.Ctx{ .p = &p, .f = &f, .tR = -1, .h_ground = 0, .tg = -1 };
    const x = [_]f64{0} ** state.nx;
    const ms = compute(ctx, &x);
    try testing.expectApproxEqAbs(@as(f64, 4), ms.m, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), ms.rcg[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), ms.I[1][1], 1e-12); // 2·1² + 2·1²
}

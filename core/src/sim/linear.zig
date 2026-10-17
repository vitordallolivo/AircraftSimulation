//! Modelo linear em torno do voo nivelado equilibrado (estabilidade dinâmica).
//!
//! Corpo rígido com comandos congelados (sem piloto automático, trem, sloshing nem carga
//! solta); o líquido entra parado na massa e na inércia e cada motor fica na rotação de
//! equilíbrio do acelerador. Jacobianos por diferenças centrais da mesma física de `f(t,x)`:
//!   δẋ = A δx + B δu,   x = (u, v, w, p, q, r, φ, θ),   u = (δe, δa, δr, acelerador)
//! ψ e a posição não entram (não mudam as forças com ρ constante).
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("state.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const aeromodel = @import("../physics/aeromodel.zig");
const mods = @import("../modifiers/mod.zig");
const prop = @import("../physics/propulsion.zig");
const mass = @import("../physics/mass.zig");
const trim = @import("trim.zig");
const V3 = vec.V3;

pub const nl = 8;
pub const nu = 4;

pub const LinModel = extern struct {
    ok: i32 = 0, // 1: a trimagem convergiu
    _pad: i32 = 0,
    V: f64 = 0,
    alpha: f64 = 0,
    de: f64 = 0,
    thr: f64 = 0,
    theta: f64 = 0,
    phi: f64 = 0,
    da: f64 = 0,
    dr: f64 = 0,
    m: f64 = 0,
    Ixx: f64 = 0,
    Iyy: f64 = 0,
    Izz: f64 = 0,
    Ixz: f64 = 0,
    cg: [3]f64 = .{ 0, 0, 0 },
    A: [nl * nl]f64 = [_]f64{0} ** (nl * nl), // por linhas
    B: [nl * nu]f64 = [_]f64{0} ** (nl * nu),
};

const Body = struct {
    c: trim.Ctx,
    I: vec.M3,
};

/// ẋ do corpo rígido com comandos fixos
pub fn rigid(b: *const Body, x: [nl]f64, u: [nu]f64) [nl]f64 {
    const p = b.c.p;
    const VB = V3{ x[0], x[1], x[2] };
    const w = V3{ x[3], x[4], x[5] };
    const ae = aeromodel.compute(p, VB, w, b.c.rcg, 100.0, .{ u[0], u[1], u[2] }, &mods.Env.none);
    var rps = [_]f64{1} ** L.max_props;
    for (p.prop[0..@intCast(p.n_prop)], 0..) |*pu, i| rps[i] = prop.equilibriumRps(p, pu, VB, u[3]);
    const pr = prop.compute(p, VB, w, b.c.rcg, &rps, u[3], u[2], x[7], 0.0); // h como na trimagem
    var F = ae.F + pr.F;
    const M = ae.M + pr.M + pr.Mgyro;
    const a = fm.sincos(x[6]);
    const t = fm.sincos(x[7]);
    F += V3{ -t.s, t.c * a.s, t.c * a.c } * vec.splat(b.c.m * L.g0);
    const acc = F / vec.splat(b.c.m) - vec.cross(w, VB);
    const wd = vec.solve3(b.I, M - vec.cross(w, vec.mul(b.I, w)));
    const qs_rc = w[1] * a.s + w[2] * a.c;
    return .{ acc[0], acc[1], acc[2], wd[0], wd[1], wd[2], w[0] + qs_rc * t.s / t.c, w[1] * a.c - w[2] * a.s };
}

fn state(V: f64, z: [6]f64) [nl]f64 {
    const sa = fm.sincos(z[0]);
    return .{ V * sa.c, 0, V * sa.s, 0, 0, 0, z[3], z[0] };
}

const w_lon: f64 = 1e3;

fn res6(b: *const Body, V: f64, z: [6]f64) [6]f64 {
    const d = rigid(b, state(V, z), .{ z[1], z[4], z[5], z[2] });
    const s = 1.0 / L.g0;
    // longitudinal pesa mais: sem como zerar o látero-direcional (sem leme), ele não pode
    // estragar o equilíbrio longitudinal nos mínimos quadrados
    const k = w_lon;
    return .{ d[0] * s * k, d[1] * s, d[2] * s * k, d[3], d[4] * k, d[5] };
}

/// Levenberg-Marquardt 6×6 (α, δe, acelerador, φ, δa, δr) zerando as acelerações do corpo rígido.
/// Mínimos quadrados: sem leme (asa voadora) ou com comando sem efeito o sistema fica singular,
/// e então o látero-direcional é equilibrado o melhor possível. Sucesso = longitudinal equilibrado.
fn full(b: *const Body, V: f64, z: *[6]f64) bool {
    var r = res6(b, V, z.*);
    for (0..60) |_| {
        var nr: f64 = 0;
        for (r) |v| nr += v * v;
        if (nr < 1e-22) break;
        var J: [6][6]f64 = undefined;
        for (0..6) |j| {
            var zp = z.*;
            zp[j] += 1e-6;
            const rp = res6(b, V, zp);
            for (0..6) |i| J[i][j] = (rp[i] - r[i]) / 1e-6;
        }
        var N: [6][7]f64 = undefined; // (JᵀJ + μ diag) dz = −Jᵀ r
        for (0..6) |i| {
            for (0..6) |j| {
                var acc: f64 = 0;
                for (0..6) |k| acc += J[k][i] * J[k][j];
                N[i][j] = acc;
            }
            var g: f64 = 0;
            for (0..6) |k| g += J[k][i] * r[k];
            N[i][6] = -g;
        }
        for (0..6) |i| N[i][i] += 1e-10 + 1e-8 * N[i][i];
        const dz = gauss6(&N) orelse return false;
        var fs: f64 = 1.0;
        var better = false;
        for (0..10) |_| { // passo amortecido
            var zt = z.*;
            for (0..6) |i| zt[i] += fs * fm.sat(dz[i], 0.1);
            const rt = res6(b, V, zt);
            var nt: f64 = 0;
            for (rt) |v| nt += v * v;
            if (nt < nr) {
                z.* = zt;
                r = rt;
                better = true;
                break;
            }
            fs *= 0.5;
        }
        if (!better) break;
    }
    return (@abs(r[0]) + @abs(r[2]) + @abs(r[4])) / w_lon < 1e-5;
}

fn gauss6(M: *[6][7]f64) ?[6]f64 {
    for (0..6) |k| {
        var piv = k;
        for (k + 1..6) |i| if (@abs(M[i][k]) > @abs(M[piv][k])) {
            piv = i;
        };
        if (@abs(M[piv][k]) < 1e-300) return null;
        if (piv != k) std.mem.swap([7]f64, &M[piv], &M[k]);
        for (k + 1..6) |i| {
            const f = M[i][k] / M[k][k];
            for (k..7) |j| M[i][j] -= f * M[k][j];
        }
    }
    var x: [6]f64 = undefined;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        var s = M[i][6];
        for (i + 1..6) |j| s -= M[i][j] * x[j];
        x[i] = s / M[i][i];
    }
    return x;
}

/// trima nivelado em V e deriva A e B
pub fn linearize(p: *const T.Params, f: *const S.Flags, V: f64) LinModel {
    const xz = [_]f64{0} ** S.nx;
    const ms = mass.compute(.{ .p = p, .f = f, .tR = -1, .h_ground = 0, .tg = -1 }, &xz);
    const b = Body{ .c = .{ .p = p, .m = ms.m, .rcg = ms.rcg }, .I = ms.I };
    const tp = trim.solve(b.c, T.trim_level, V, 1, null);
    var o = LinModel{
        .ok = tp.ok,
        .V = V,
        .alpha = tp.alpha,
        .de = tp.de,
        .thr = tp.thr,
        .theta = tp.alpha,
        .m = ms.m,
        .Ixx = ms.I[0][0],
        .Iyy = ms.I[1][1],
        .Izz = ms.I[2][2],
        .Ixz = -ms.I[0][2],
        .cg = vec.arr(ms.rcg),
    };
    // equilíbrio completo: o torque e o giroscópico dos motores pedem δa, δr e um φ pequeno
    var z = [6]f64{ tp.alpha, tp.de, tp.thr, 0, 0, 0 };
    if (tp.ok != 0 and !full(&b, V, &z)) o.ok = 0;
    o.alpha = z[0];
    o.de = z[1];
    o.thr = z[2];
    o.theta = z[0];
    o.phi = z[3];
    o.da = z[4];
    o.dr = z[5];
    const x0 = state(V, z);
    const uc = [nu]f64{ z[1], z[4], z[5], z[2] };
    for (0..nl) |j| {
        const h: f64 = if (j < 3) 1e-4 * @max(V, 1.0) else 1e-5;
        var xp = x0;
        var xm = x0;
        xp[j] += h;
        xm[j] -= h;
        const fp = rigid(&b, xp, uc);
        const fn_ = rigid(&b, xm, uc);
        for (0..nl) |i| o.A[i * nl + j] = (fp[i] - fn_[i]) / (2 * h);
    }
    for (0..nu) |j| {
        const h: f64 = 1e-5;
        var up = uc;
        var um = uc;
        up[j] += h;
        um[j] -= h;
        const fp = rigid(&b, x0, up);
        const fn_ = rigid(&b, x0, um);
        for (0..nl) |i| o.B[i * nu + j] = (fp[i] - fn_[i]) / (2 * h);
    }
    return o;
}

/// resíduo |ẋ| no ponto de equilíbrio (para testes)
pub fn residual(p: *const T.Params, f: *const S.Flags, lm: *const LinModel) f64 {
    const xz = [_]f64{0} ** S.nx;
    const ms = mass.compute(.{ .p = p, .f = f, .tR = -1, .h_ground = 0, .tg = -1 }, &xz);
    const b = Body{ .c = .{ .p = p, .m = ms.m, .rcg = ms.rcg }, .I = ms.I };
    const d = rigid(&b, state(lm.V, .{ lm.alpha, lm.de, lm.thr, lm.phi, lm.da, lm.dr }), .{ lm.de, lm.da, lm.dr, lm.thr });
    var s: f64 = 0;
    for (d) |v| s += @abs(v);
    return s;
}

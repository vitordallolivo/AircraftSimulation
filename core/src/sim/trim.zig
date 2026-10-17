//! Equilíbrio (trimagem) e desempenho por velocidade, sem integração no tempo.
//!
//! Para cada V resolve por Newton (jacobiano numérico, passo amortecido) o equilíbrio
//! longitudinal nos eixos do vento (forças de aero + motores, momento no CG):
//!   X_w − m g sin γ = 0,   Z_w + n m g cos γ = 0,   M = 0
//! com três incógnitas por caso:
//!   nivelado (α, δe, acelerador)   subida máx. (α, δe, γ; acel. 1)
//!   planeio  (α, δe, γ; acel. 0)   curva (α, δe, acelerador; n dado)
//! Fator de carga máximo em curva: estol da asa (C_L/C_Lmax = kCL) e, sustentada,
//! motor (acelerador = 1). Raio R = V² / (g √(n² − 1)).
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
const V3 = vec.V3;

pub const Ctx = struct {
    p: *const T.Params,
    m: f64,
    rcg: V3,

    pub fn init(p: *const T.Params, f: *const S.Flags) Ctx {
        const x = [_]f64{0} ** S.nx;
        const ms = mass.compute(.{ .p = p, .f = f, .tR = -1, .h_ground = 0, .tg = -1 }, &x);
        return .{ .p = p, .m = ms.m, .rcg = ms.rcg };
    }
};

const Case = struct { kind: i32, V: f64, thr: f64 = 1, gam: f64 = 0, n: f64 = 1 };

fn thrFree(k: i32) bool {
    return k == T.trim_level or k == T.trim_turn;
}

fn residual(c: Ctx, cs: Case, u: [3]f64, r: *[3]f64, e: ?*T.TrimPoint) void {
    const p = c.p;
    const al = u[0];
    const de = u[1];
    var thr = cs.thr;
    var gam = cs.gam;
    if (thrFree(cs.kind)) thr = u[2] else gam = u[2];
    const sa = fm.sincos(al);
    const Vr = V3{ cs.V * sa.c, 0, cs.V * sa.s };
    const ae = aeromodel.compute(p, Vr, vec.zero, c.rcg, 100.0, .{ de, 0, 0 }, &mods.Env.none);
    var rps = [_]f64{1} ** L.max_props;
    for (p.prop[0..@intCast(p.n_prop)], 0..) |*pu, i| rps[i] = prop.equilibriumRps(p, pu, Vr, thr);
    const pr = prop.compute(p, Vr, vec.zero, c.rcg, &rps, thr, 0, 0, 0);
    const W = c.m * L.g0;
    const g = fm.sincos(gam);
    const Fx = ae.F[0] + pr.F[0];
    const Fz = ae.F[2] + pr.F[2];
    r[0] = (Fx * sa.c + Fz * sa.s - W * g.s) / W;
    r[1] = (-Fx * sa.s + Fz * sa.c + cs.n * W * g.c) / W;
    r[2] = (ae.M[1] + pr.M[1]) / (W * p.cref);
    if (e) |o| {
        o.V = cs.V;
        o.alpha = al;
        o.de = de;
        o.thr = thr;
        o.gamma = gam;
        o.n = cs.n;
        o.ratioCL = ae.ratioCL;
        o.T = pr.T;
        o.P = pr.P;
        o.D = -(ae.F[0] * sa.c + ae.F[2] * sa.s);
        o.CL = (-ae.F[2] * sa.c + ae.F[0] * sa.s) / (0.5 * p.env.rho * cs.V * cs.V * p.Sref);
    }
}

fn nrm(r: [3]f64) f64 {
    return @abs(r[0]) + @abs(r[1]) + @abs(r[2]);
}

fn newton(c: Ctx, cs: Case, u: *[3]f64, e: ?*T.TrimPoint) bool {
    const free = thrFree(cs.kind);
    const lo = [3]f64{ -0.2, -0.35, if (free) 0.02 else -0.7 };
    const hi = [3]f64{ 0.45, 0.35, if (free) 3.0 else 0.7 };
    const step = [3]f64{ 0.08, 0.08, 0.25 };
    for (0..120) |_| {
        var r: [3]f64 = undefined;
        residual(c, cs, u.*, &r, null);
        const nr = nrm(r);
        if (nr < 1e-9) break;
        var J: vec.M3 = undefined;
        inline for (0..3) |j| {
            var up = u.*;
            up[j] += 1e-6;
            var rp: [3]f64 = undefined;
            residual(c, cs, up, &rp, null);
            inline for (0..3) |i| J[i][j] = (rp[i] - r[i]) / 1e-6;
        }
        var du = vec.arr(vec.solve3(J, .{ -r[0], -r[1], -r[2] }));
        for (0..3) |i| {
            if (!std.math.isFinite(du[i])) du[i] = if (i == 2) 0.1 else 0.0; // jacobiano singular
            du[i] = fm.sat(du[i], step[i]);
        }
        var fs: f64 = 1.0;
        for (0..12) |k| { // passo amortecido
            var ut: [3]f64 = undefined;
            for (0..3) |i| ut[i] = fm.lim(u[i] + fs * du[i], lo[i], hi[i]);
            var rt: [3]f64 = undefined;
            residual(c, cs, ut, &rt, null);
            if (nrm(rt) < nr or k == 11) {
                u.* = ut;
                break;
            }
            fs *= 0.5;
        }
    }
    var r: [3]f64 = undefined;
    residual(c, cs, u.*, &r, e);
    return nrm(r) < 1e-5;
}

/// um ponto de equilíbrio. guess: chute (α, δe, z) que é atualizado (continuação)
pub fn solve(c: Ctx, kind: i32, V: f64, n: f64, guess: ?*[3]f64) T.TrimPoint {
    var u_init: [3]f64 = switch (kind) {
        T.trim_climb => .{ 0.1, -0.05, 0.1 },
        T.trim_glide => .{ 0.1, -0.05, -0.1 },
        else => .{ 0.1, -0.05, 0.5 },
    };
    const u = guess orelse &u_init;
    const cs = Case{ .kind = kind, .V = V, .n = n, .thr = if (kind == T.trim_glide) 0.0 else 1.0 };
    var e = T.TrimPoint{};
    e.ok = if (newton(c, cs, u, &e)) 1 else 0;
    return e;
}

/// tabela de desempenho de V_hi até V_lo (de cima para baixo: o chute vem do anterior)
pub fn performance(c: Ctx, V_hi: f64, V_lo: f64, dV: f64, rows: []T.PerfRow) usize {
    var un = [3]f64{ 0.1, -0.05, 0.5 };
    var uc = [3]f64{ 0.1, -0.05, 0.1 };
    var ug = [3]f64{ 0.1, -0.05, -0.1 };
    const kCL = if (c.p.ap.kCL > 0) c.p.ap.kCL else 0.95;
    var k: usize = 0;
    var V = V_hi;
    while (V >= V_lo - 1e-9 and k < rows.len) : (V -= dV) {
        const en = solve(c, T.trim_level, V, 1, &un);
        const ec = solve(c, T.trim_climb, V, 1, &uc);
        const eg = solve(c, T.trim_glide, V, 1, &ug);
        // ponto que não convergiu não serve de chute para o próximo
        const un_used = un;
        const uc_used = uc;
        const ug_used = ug;
        defer {
            if (en.ok == 0) un = .{ 0.1, -0.05, 0.5 };
            if (ec.ok == 0) uc = .{ 0.1, -0.05, 0.1 };
            if (eg.ok == 0) ug = .{ 0.1, -0.05, -0.1 };
        }
        // curvas: bisseção no fator de carga
        var nlim = [2]f64{ 1, 1 };
        for (0..2) |tipo| {
            var lo: f64 = 1.0;
            var hi: f64 = 6.0;
            var u = un_used;
            for (0..40) |_| {
                const nm = 0.5 * (lo + hi);
                var ut = u;
                const et = solve(c, T.trim_turn, V, nm, &ut);
                const inside = et.ok != 0 and et.ratioCL <= kCL and (tipo == 0 or ut[2] <= 1.0);
                if (inside) {
                    lo = nm;
                    u = ut;
                } else hi = nm;
            }
            nlim[tipo] = lo;
        }
        const radius = struct {
            fn f(Vv: f64, n: f64) f64 {
                return if (n > 1.0001) Vv * Vv / (L.g0 * @sqrt(n * n - 1.0)) else 1e9;
            }
        }.f;
        rows[k] = .{
            .V = V,
            .ok_level = if (en.ok != 0 and en.ratioCL <= 1.0) 1 else 0,
            .alpha_level = un_used[0],
            .de_level = un_used[1],
            .thr_level = un_used[2],
            .ratio_level = en.ratioCL,
            .CL_level = en.CL,
            .D_level = en.D,
            .T_level = en.T,
            .P_level = en.P,
            .ok_climb = if (ec.ok != 0 and ec.ratioCL <= 1.0) 1 else 0,
            .gamma_max = uc_used[2],
            .roc_max = V * fm.sin(uc_used[2]),
            .ok_glide = @floatFromInt(eg.ok),
            .gamma_idle = ug_used[2],
            .roc_idle = V * fm.sin(ug_used[2]),
            .n_stall = nlim[0],
            .R_stall = radius(V, nlim[0]),
            .phi_stall = fm.acos(1.0 / nlim[0]),
            .n_sust = nlim[1],
            .R_sust = radius(V, nlim[1]),
            .phi_sust = fm.acos(1.0 / nlim[1]),
        };
        k += 1;
    }
    return k;
}

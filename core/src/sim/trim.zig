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
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const state = @import("state.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const aeromodel = @import("../physics/aeromodel.zig");
const mods = @import("../modifiers/mod.zig");
const prop = @import("../physics/propulsion.zig");
const mass = @import("../physics/mass.zig");
const V3 = vec.V3;

/// o que a trimagem usa: os parâmetros, a massa e o CG (com os tanques e a carga parados)
pub const Ctx = struct {
    p: *const types.Params,
    m: f64,
    rcg: V3,

    /// massa e CG pela configuração, com o estado zerado
    pub fn init(params: *const types.Params, flags: *const state.Flags) Ctx {
        const state_vector = [_]f64{0} ** state.nx;
        const mass_props = mass.compute(.{ .p = params, .f = flags, .tR = -1, .h_ground = 0, .tg = -1 }, &state_vector);
        return .{ .p = params, .m = mass_props.m, .rcg = mass_props.rcg };
    }
};

/// o caso de equilíbrio: tipo, V, e o que fica fixo (acelerador, γ ou fator de carga)
const Case = struct { kind: i32, V: f64, thr: f64 = 1, gam: f64 = 0, n: f64 = 1 };

/// verdadeiro se o acelerador é incógnita no caso (nivelado e curva); senão a incógnita é γ
fn thrFree(kind: i32) bool {
    return kind == types.trim_level or kind == types.trim_turn;
}

/// os três resíduos do equilíbrio (forças nos eixos do vento e momento) para as incógnitas; com `point_out`, o
/// ponto de equilíbrio completo
fn residual(ctx: Ctx, case: Case, unknowns: [3]f64, res: *[3]f64, point_out: ?*types.TrimPoint) void {
    const params = ctx.p;
    const al = unknowns[0];
    const de = unknowns[1];
    var thr = case.thr;
    var gam = case.gam;
    if (thrFree(case.kind)) thr = unknowns[2] else gam = unknowns[2];
    const sa = fmath.sincos(al);
    const Vr = V3{ case.V * sa.c, 0, case.V * sa.s };
    const ae = aeromodel.compute(params, Vr, vec.zero, ctx.rcg, 100.0, .{ de, 0, 0 }, &mods.Env.none);
    var rps = [_]f64{1} ** limits.max_props;
    for (params.prop[0..@intCast(params.n_prop)], 0..) |*pu, i| rps[i] = prop.equilibriumRps(params, pu, Vr, thr);
    const pr = prop.compute(params, Vr, vec.zero, ctx.rcg, &rps, thr, 0, 0, 0);
    const weight = ctx.m * limits.g0;
    const path = fmath.sincos(gam);
    const Fx = ae.F[0] + pr.F[0];
    const Fz = ae.F[2] + pr.F[2];
    res[0] = (Fx * sa.c + Fz * sa.s - weight * path.s) / weight;
    res[1] = (-Fx * sa.s + Fz * sa.c + case.n * weight * path.c) / weight;
    res[2] = (ae.M[1] + pr.M[1]) / (weight * params.cref);
    if (point_out) |point| {
        point.V = case.V;
        point.alpha = al;
        point.de = de;
        point.thr = thr;
        point.gamma = gam;
        point.n = case.n;
        point.ratioCL = ae.ratioCL;
        point.T = pr.T;
        point.P = pr.P;
        point.D = -(ae.F[0] * sa.c + ae.F[2] * sa.s);
        point.CL = (-ae.F[2] * sa.c + ae.F[0] * sa.s) / (0.5 * params.env.rho * case.V * case.V * params.Sref);
    }
}

/// soma dos módulos dos resíduos
fn nrm(res: [3]f64) f64 {
    return @abs(res[0]) + @abs(res[1]) + @abs(res[2]);
}

/// Newton amortecido sobre as incógnitas; verdadeiro se convergiu
fn newton(ctx: Ctx, case: Case, unknowns: *[3]f64, point_out: ?*types.TrimPoint) bool {
    const free = thrFree(case.kind);
    const lo = [3]f64{ -0.2, -0.35, if (free) 0.02 else -0.7 };
    const hi = [3]f64{ 0.45, 0.35, if (free) 3.0 else 0.7 };
    const step = [3]f64{ 0.08, 0.08, 0.25 };
    for (0..120) |_| {
        var res: [3]f64 = undefined;
        residual(ctx, case, unknowns.*, &res, null);
        const nr = nrm(res);
        if (nr < 1e-9) break;
        var jacobian: vec.M3 = undefined;
        inline for (0..3) |j| {
            var up = unknowns.*;
            up[j] += 1e-6;
            var rp: [3]f64 = undefined;
            residual(ctx, case, up, &rp, null);
            inline for (0..3) |i| jacobian[i][j] = (rp[i] - res[i]) / 1e-6;
        }
        var du = vec.arr(vec.solve3(jacobian, .{ -res[0], -res[1], -res[2] }));
        for (0..3) |i| {
            if (!std.math.isFinite(du[i])) du[i] = if (i == 2) 0.1 else 0.0; // jacobiano singular
            du[i] = fmath.sat(du[i], step[i]);
        }
        var fraction: f64 = 1.0;
        for (0..12) |k| { // passo amortecido
            var ut: [3]f64 = undefined;
            for (0..3) |i| ut[i] = fmath.lim(unknowns[i] + fraction * du[i], lo[i], hi[i]);
            var rt: [3]f64 = undefined;
            residual(ctx, case, ut, &rt, null);
            if (nrm(rt) < nr or k == 11) {
                unknowns.* = ut;
                break;
            }
            fraction *= 0.5;
        }
    }
    var res: [3]f64 = undefined;
    residual(ctx, case, unknowns.*, &res, point_out);
    return nrm(res) < 1e-5;
}

/// um ponto de equilíbrio. guess: chute (α, δe, z) que é atualizado (continuação)
pub fn solve(ctx: Ctx, kind: i32, airspeed: f64, load_factor: f64, guess: ?*[3]f64) types.TrimPoint {
    var u_init: [3]f64 = switch (kind) {
        types.trim_climb => .{ 0.1, -0.05, 0.1 },
        types.trim_glide => .{ 0.1, -0.05, -0.1 },
        else => .{ 0.1, -0.05, 0.5 },
    };
    const unknowns = guess orelse &u_init;
    const case = Case{ .kind = kind, .V = airspeed, .n = load_factor, .thr = if (kind == types.trim_glide) 0.0 else 1.0 };
    var point = types.TrimPoint{};
    point.ok = if (newton(ctx, case, unknowns, &point)) 1 else 0;
    return point;
}

/// tabela de desempenho de V_hi até V_lo (de cima para baixo: o chute vem do anterior)
pub fn performance(ctx: Ctx, V_hi: f64, V_lo: f64, dV: f64, rows: []types.PerfRow) usize {
    var un = [3]f64{ 0.1, -0.05, 0.5 };
    var uc = [3]f64{ 0.1, -0.05, 0.1 };
    var ug = [3]f64{ 0.1, -0.05, -0.1 };
    const kCL = if (ctx.p.ap.kCL > 0) ctx.p.ap.kCL else 0.95;
    var row: usize = 0;
    var airspeed = V_hi;
    while (airspeed >= V_lo - 1e-9 and row < rows.len) : (airspeed -= dV) {
        const en = solve(ctx, types.trim_level, airspeed, 1, &un);
        const ec = solve(ctx, types.trim_climb, airspeed, 1, &uc);
        const eg = solve(ctx, types.trim_glide, airspeed, 1, &ug);
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
            var unknowns = un_used;
            for (0..40) |_| {
                const nm = 0.5 * (lo + hi);
                var ut = unknowns;
                const et = solve(ctx, types.trim_turn, airspeed, nm, &ut);
                const inside = et.ok != 0 and et.ratioCL <= kCL and (tipo == 0 or ut[2] <= 1.0);
                if (inside) {
                    lo = nm;
                    unknowns = ut;
                } else hi = nm;
            }
            nlim[tipo] = lo;
        }
        const radius = struct {
            fn turnRadius(speed: f64, load_factor: f64) f64 {
                return if (load_factor > 1.0001) speed * speed / (limits.g0 * @sqrt(load_factor * load_factor - 1.0)) else 1e9;
            }
        }.turnRadius;
        rows[row] = .{
            .V = airspeed,
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
            .roc_max = airspeed * fmath.sin(uc_used[2]),
            .ok_glide = @floatFromInt(eg.ok),
            .gamma_idle = ug_used[2],
            .roc_idle = airspeed * fmath.sin(ug_used[2]),
            .n_stall = nlim[0],
            .R_stall = radius(airspeed, nlim[0]),
            .phi_stall = fmath.acos(1.0 / nlim[0]),
            .n_sust = nlim[1],
            .R_sust = radius(airspeed, nlim[1]),
            .phi_sust = fmath.acos(1.0 / nlim[1]),
        };
        row += 1;
    }
    return row;
}

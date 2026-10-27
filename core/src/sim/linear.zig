//! Modelo linear em torno do voo nivelado equilibrado (estabilidade dinâmica).
//!
//! Corpo rígido com comandos congelados (sem piloto automático, trem, sloshing nem carga
//! solta); o líquido entra parado na massa e na inércia e cada motor fica na rotação de
//! equilíbrio do acelerador. Jacobianos por diferenças centrais da mesma física de `f(t,x)`:
//!   δẋ = A δx + B δu,   x = (u, v, w, p, q, r, φ, θ),   u = (δe, δa, δr, acelerador)
//! ψ e a posição não entram (não mudam as forças com ρ constante).
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
const trim = @import("trim.zig");
const V3 = vec.V3;

/// estados do modelo linear (u, v, w, p, q, r, φ, θ)
pub const nl = 8;
/// entradas do modelo linear (δe, δa, δr, acelerador)
pub const nu = 4;

/// o modelo linear δẋ = A δx + B δu no equilíbrio e o próprio equilíbrio (V, α, comandos, massa, inércia)
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

/// o avião como corpo rígido: o contexto da trimagem (massa, CG) e a inércia
const Body = struct {
    ctx: trim.Ctx,
    inertia: vec.M3,
};

/// ẋ do corpo rígido com comandos fixos
pub fn rigid(body: *const Body, lin_state: [nl]f64, controls: [nu]f64) [nl]f64 {
    const params = body.ctx.p;
    const VB = V3{ lin_state[0], lin_state[1], lin_state[2] };
    const body_rates = V3{ lin_state[3], lin_state[4], lin_state[5] };
    const ae = aeromodel.compute(params, VB, body_rates, body.ctx.rcg, 100.0, .{ controls[0], controls[1], controls[2] }, &mods.Env.none);
    var rps = [_]f64{1} ** limits.max_props;
    for (params.prop[0..@intCast(params.n_prop)], 0..) |*pu, i| rps[i] = prop.equilibriumRps(params, pu, VB, controls[3]);
    const pr = prop.compute(params, VB, body_rates, body.ctx.rcg, &rps, controls[3], controls[2], lin_state[7], 0.0); // h como na trimagem
    var force = ae.F + pr.F;
    const moment = ae.M + pr.M + pr.Mgyro;
    const roll = fmath.sincos(lin_state[6]);
    const pitch = fmath.sincos(lin_state[7]);
    force += V3{ -pitch.s, pitch.c * roll.s, pitch.c * roll.c } * vec.splat(body.ctx.m * limits.g0);
    const acc = force / vec.splat(body.ctx.m) - vec.cross(body_rates, VB);
    const wd = vec.solve3(body.inertia, moment - vec.cross(body_rates, vec.mul(body.inertia, body_rates)));
    const qs_rc = body_rates[1] * roll.s + body_rates[2] * roll.c;
    return .{ acc[0], acc[1], acc[2], wd[0], wd[1], wd[2], body_rates[0] + qs_rc * pitch.s / pitch.c, body_rates[1] * roll.c - body_rates[2] * roll.s };
}

/// o vetor de estado do corpo rígido no voo nivelado de α = unknowns[0] e φ = unknowns[3]
fn stateVector(airspeed: f64, unknowns: [6]f64) [nl]f64 {
    const sa = fmath.sincos(unknowns[0]);
    return .{ airspeed * sa.c, 0, airspeed * sa.s, 0, 0, 0, unknowns[3], unknowns[0] };
}

const w_lon: f64 = 1e3;

/// as seis acelerações do corpo rígido (longitudinais com peso `w_lon`) para as incógnitas
fn res6(body: *const Body, airspeed: f64, unknowns: [6]f64) [6]f64 {
    const rates = rigid(body, stateVector(airspeed, unknowns), .{ unknowns[1], unknowns[4], unknowns[5], unknowns[2] });
    const inv_g = 1.0 / limits.g0;
    // longitudinal pesa mais: sem como zerar o látero-direcional (sem leme), ele não pode
    // estragar o equilíbrio longitudinal nos mínimos quadrados
    const weight = w_lon;
    return .{ rates[0] * inv_g * weight, rates[1] * inv_g, rates[2] * inv_g * weight, rates[3], rates[4] * weight, rates[5] };
}

/// Levenberg-Marquardt 6×6 (α, δe, acelerador, φ, δa, δr) zerando as acelerações do corpo rígido.
/// Mínimos quadrados: sem leme (asa voadora) ou com comando sem efeito o sistema fica singular,
/// e então o látero-direcional é equilibrado o melhor possível. Sucesso = longitudinal equilibrado.
fn full(body: *const Body, airspeed: f64, unknowns: *[6]f64) bool {
    var res = res6(body, airspeed, unknowns.*);
    for (0..60) |_| {
        var nr: f64 = 0;
        for (res) |value| nr += value * value;
        if (nr < 1e-22) break;
        var jacobian: [6][6]f64 = undefined;
        for (0..6) |j| {
            var zp = unknowns.*;
            zp[j] += 1e-6;
            const rp = res6(body, airspeed, zp);
            for (0..6) |i| jacobian[i][j] = (rp[i] - res[i]) / 1e-6;
        }
        var normal: [6][7]f64 = undefined; // (JᵀJ + μ diag) dz = −Jᵀ r
        for (0..6) |i| {
            for (0..6) |j| {
                var acc: f64 = 0;
                for (0..6) |k| acc += jacobian[k][i] * jacobian[k][j];
                normal[i][j] = acc;
            }
            var gradient: f64 = 0;
            for (0..6) |k| gradient += jacobian[k][i] * res[k];
            normal[i][6] = -gradient;
        }
        for (0..6) |i| normal[i][i] += 1e-10 + 1e-8 * normal[i][i];
        const dz = gauss6(&normal) orelse return false;
        var fraction: f64 = 1.0;
        var better = false;
        for (0..10) |_| { // passo amortecido
            var zt = unknowns.*;
            for (0..6) |i| zt[i] += fraction * fmath.sat(dz[i], 0.1);
            const rt = res6(body, airspeed, zt);
            var nt: f64 = 0;
            for (rt) |value| nt += value * value;
            if (nt < nr) {
                unknowns.* = zt;
                res = rt;
                better = true;
                break;
            }
            fraction *= 0.5;
        }
        if (!better) break;
    }
    return (@abs(res[0]) + @abs(res[2]) + @abs(res[4])) / w_lon < 1e-5;
}

/// resolve o sistema 6 × 6 aumentado por Gauss com pivô parcial; null se singular
fn gauss6(augmented: *[6][7]f64) ?[6]f64 {
    for (0..6) |k| {
        var piv = k;
        for (k + 1..6) |i| if (@abs(augmented[i][k]) > @abs(augmented[piv][k])) {
            piv = i;
        };
        if (@abs(augmented[piv][k]) < 1e-300) return null;
        if (piv != k) std.mem.swap([7]f64, &augmented[piv], &augmented[k]);
        for (k + 1..6) |i| {
            const factor = augmented[i][k] / augmented[k][k];
            for (k..7) |j| augmented[i][j] -= factor * augmented[k][j];
        }
    }
    var solution: [6]f64 = undefined;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        var sum = augmented[i][6];
        for (i + 1..6) |j| sum -= augmented[i][j] * solution[j];
        solution[i] = sum / augmented[i][i];
    }
    return solution;
}

/// trima nivelado na velocidade `airspeed` e deriva A e B
pub fn linearize(params: *const types.Params, flags: *const state.Flags, airspeed: f64) LinModel {
    const xz = [_]f64{0} ** state.nx;
    const mass_props = mass.compute(.{ .p = params, .f = flags, .tR = -1, .h_ground = 0, .tg = -1 }, &xz);
    const body = Body{ .ctx = .{ .p = params, .m = mass_props.m, .rcg = mass_props.rcg }, .inertia = mass_props.I };
    const tp = trim.solve(body.ctx, types.trim_level, airspeed, 1, null);
    var model = LinModel{
        .ok = tp.ok,
        .V = airspeed,
        .alpha = tp.alpha,
        .de = tp.de,
        .thr = tp.thr,
        .theta = tp.alpha,
        .m = mass_props.m,
        .Ixx = mass_props.I[0][0],
        .Iyy = mass_props.I[1][1],
        .Izz = mass_props.I[2][2],
        .Ixz = -mass_props.I[0][2],
        .cg = vec.arr(mass_props.rcg),
    };
    // equilíbrio completo: o torque e o giroscópico dos motores pedem δa, δr e um φ pequeno
    var unknowns = [6]f64{ tp.alpha, tp.de, tp.thr, 0, 0, 0 };
    if (tp.ok != 0 and !full(&body, airspeed, &unknowns)) model.ok = 0;
    model.alpha = unknowns[0];
    model.de = unknowns[1];
    model.thr = unknowns[2];
    model.theta = unknowns[0];
    model.phi = unknowns[3];
    model.da = unknowns[4];
    model.dr = unknowns[5];
    const x0 = stateVector(airspeed, unknowns);
    const uc = [nu]f64{ unknowns[1], unknowns[4], unknowns[5], unknowns[2] };
    for (0..nl) |j| {
        const step: f64 = if (j < 3) 1e-4 * @max(airspeed, 1.0) else 1e-5;
        var xp = x0;
        var xm = x0;
        xp[j] += step;
        xm[j] -= step;
        const fp = rigid(&body, xp, uc);
        const fn_ = rigid(&body, xm, uc);
        for (0..nl) |i| model.A[i * nl + j] = (fp[i] - fn_[i]) / (2 * step);
    }
    for (0..nu) |j| {
        const step: f64 = 1e-5;
        var up = uc;
        var um = uc;
        up[j] += step;
        um[j] -= step;
        const fp = rigid(&body, x0, up);
        const fn_ = rigid(&body, x0, um);
        for (0..nl) |i| model.B[i * nu + j] = (fp[i] - fn_[i]) / (2 * step);
    }
    return model;
}

/// resíduo |ẋ| no ponto de equilíbrio (para testes)
pub fn residual(params: *const types.Params, flags: *const state.Flags, lm: *const LinModel) f64 {
    const xz = [_]f64{0} ** state.nx;
    const mass_props = mass.compute(.{ .p = params, .f = flags, .tR = -1, .h_ground = 0, .tg = -1 }, &xz);
    const body = Body{ .ctx = .{ .p = params, .m = mass_props.m, .rcg = mass_props.rcg }, .inertia = mass_props.I };
    const rates = rigid(&body, stateVector(lm.V, .{ lm.alpha, lm.de, lm.thr, lm.phi, lm.da, lm.dr }), .{ lm.de, lm.da, lm.dr, lm.thr });
    var sum: f64 = 0;
    for (rates) |value| sum += @abs(value);
    return sum;
}

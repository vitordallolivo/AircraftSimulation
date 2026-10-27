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

/// massa de líquido, massa que oscila (m1), braço (l1) e frequência (w1) de cada tanque, pelo formato e pelo enchimento
pub fn initTanks(params: *types.Params) void {
    const n_tanks: usize = @intCast(params.n_tank);
    for (params.tank[0..n_tanks]) |*tank| {
        if (tank.fill <= 0 or tank.side <= 0) {
            tank.m_liq = 0;
            tank.m0 = 0;
            tank.m1 = 0;
            tank.l1 = 1;
            tank.w1 = 1;
            continue;
        }
        if (tank.shape == types.tank_cylinder) {
            const xi = 1.841;
            const radius = 0.5 * tank.side;
            const depth_factor = fmath.tanh(xi * tank.fill / radius);
            tank.m_liq = tank.rho * fmath.pi * radius * radius * tank.fill;
            tank.w1 = @sqrt(limits.g0 * xi / radius * depth_factor);
            tank.m1 = tank.m_liq * 2.0 * depth_factor / (xi * (xi * xi - 1.0) * tank.fill / radius);
        } else {
            const wavenumber = fmath.pi / tank.side;
            const depth_factor = fmath.tanh(wavenumber * tank.fill);
            tank.m_liq = tank.rho * tank.side * tank.side * tank.fill;
            tank.w1 = @sqrt(limits.g0 * wavenumber * depth_factor);
            tank.m1 = tank.m_liq * 8.0 * depth_factor / (fmath.pi * fmath.pi * fmath.pi * tank.fill / tank.side);
        }
        tank.m1 = @min(tank.m1, tank.m_liq);
        tank.l1 = limits.g0 / (tank.w1 * tank.w1);
        tank.m0 = tank.m_liq - tank.m1;
    }
}

/// massa, CG e inércia do avião num instante
pub const Mass = struct {
    m: f64,
    rcg: V3,
    I: vec.M3,
    r1: [limits.max_tanks]V3, // posição da massa que oscila de cada tanque
    rL: V3, // posição da carga
};

/// massa, CG e inércia com os tanques (pêndulos) e a carga na posição do estado
pub fn compute(ctx: state.Ctx, state_vector: []const f64) Mass {
    const params = ctx.p;
    var out: Mass = undefined;
    // inércia seca dada no CG dela; as massas pontuais somam por Steiner
    var inertia = vec.M3{ .{ params.Ixx, 0, -params.Ixz }, .{ 0, params.Iyy, 0 }, .{ -params.Ixz, 0, params.Izz } };
    var mass: f64 = 0;
    var moment = vec.zero;
    const Accumulate = struct {
        fn add(inertia_sum: *vec.M3, mass_sum: *f64, moment_sum: *V3, point_mass: f64, position: V3) void {
            if (point_mass == 0) return;
            mass_sum.* += point_mass;
            moment_sum.* += position * vec.splat(point_mass);
            const distance2 = vec.dot(position, position);
            inline for (0..3) |i| {
                var diagonal = vec.zero;
                diagonal[i] = distance2;
                inertia_sum[i] += (diagonal - position * vec.splat(position[i])) * vec.splat(point_mass);
            }
        }
    };
    Accumulate.add(&inertia, &mass, &moment, params.m_dry, vec.v3(params.r_dry));
    const n_tanks: usize = @intCast(params.n_tank);
    const slosh_on = params.slosh_on != 0;
    for (params.tank[0..n_tanks], 0..) |*tank, i| {
        const ex = if (slosh_on) state_vector[state.sx(i)] else 0.0;
        const ey = if (slosh_on) state_vector[state.sy(i)] else 0.0;
        const swing_x = fmath.sincos(ex);
        const swing_y = fmath.sincos(ey);
        const rt = vec.v3(tank.r);
        out.r1[i] = rt + V3{ tank.l1 * swing_x.s, tank.l1 * swing_y.s, -tank.l1 + tank.l1 * swing_x.c * swing_y.c };
        Accumulate.add(&inertia, &mass, &moment, tank.m0, rt);
        Accumulate.add(&inertia, &mass, &moment, tank.m1, out.r1[i]);
    }
    out.rL = V3{ params.payload.r[0] - state_vector[state.SL], params.payload.r[1], params.payload.r[2] };
    if (params.payload.enabled != 0 and ctx.f.released == 0) Accumulate.add(&inertia, &mass, &moment, params.payload.m, out.rL);
    out.m = mass;
    out.rcg = moment / vec.splat(mass);
    const cg_distance2 = vec.dot(out.rcg, out.rcg);
    inline for (0..3) |i| {
        var diagonal = vec.zero;
        diagonal[i] = cg_distance2;
        out.I[i] = inertia[i] - (diagonal - out.rcg * vec.splat(out.rcg[i])) * vec.splat(mass);
    }
    return out;
}

/// força e momento (corpo) de um efeito de massa
pub const Load = struct { F: V3 = vec.zero, M: V3 = vec.zero };

/// força e momento do líquido que oscila nos tanques, com as forças externas `F_ext` (sem peso) no corpo e as
/// taxas de rotação `body_rates`; escreve as derivadas dos tanques em `state_rates`
pub fn slosh(params: *const types.Params, state_vector: []const f64, F_ext: V3, body_rates: V3, mass: *const Mass, state_rates: []f64) Load {
    var out = Load{};
    if (params.slosh_on == 0) return out;
    const n_tanks: usize = @intCast(params.n_tank);
    for (params.tank[0..n_tanks], 0..) |*tank, i| {
        if (tank.m1 <= 0) continue;
        const rt = vec.v3(tank.r);
        const aap = -F_ext / vec.splat(mass.m) - vec.cross(body_rates, vec.cross(body_rates, rt));
        const ex = state_vector[state.sx(i)];
        const ey = state_vector[state.sy(i)];
        const exd = state_vector[state.sxd(i)];
        const eyd = state_vector[state.syd(i)];
        const swing_x = fmath.sincos(ex);
        const swing_y = fmath.sincos(ey);
        const exdd = (aap[0] * swing_x.c - aap[2] * swing_x.s) / tank.l1 - 2.0 * tank.zeta * tank.w1 * exd;
        const eydd = (aap[1] * swing_y.c - aap[2] * swing_y.s) / tank.l1 - 2.0 * tank.zeta * tank.w1 * eyd;
        state_rates[state.sx(i)] = exd;
        state_rates[state.sy(i)] = eyd;
        state_rates[state.sxd(i)] = exdd;
        state_rates[state.syd(i)] = eydd;
        const arel = V3{ tank.l1 * (exdd * swing_x.c - exd * exd * swing_x.s), tank.l1 * (eydd * swing_y.c - eyd * eyd * swing_y.s), 0 };
        const force = arel * vec.splat(-tank.m1);
        out.F += force;
        out.M += vec.cross(mass.r1[i] - mass.rcg, force);
    }
    return out;
}

/// força e momento do atrito da carga que desliza na baia; `aap` é a gravidade aparente no tanque 0 (ou no CG)
pub fn payload(ctx: state.Ctx, state_vector: []const f64, aap: V3, mass: *const Mass, state_rates: []f64) Load {
    var out = Load{};
    const params = ctx.p;
    if (ctx.f.extracting == 0 or ctx.f.released != 0 or params.payload.enabled == 0) return out;
    const nz = @max(aap[2], 0.0);
    const friction = params.payload.mu_b * params.payload.m * nz;
    state_rates[state.SL] = state_vector[state.SLD];
    state_rates[state.SLD] = params.payload.Fext_g * limits.g0 - friction / params.payload.m;
    out.F = V3{ -friction, 0, 0 };
    out.M = vec.cross(mass.rL - mass.rcg, out.F);
    return out;
}

const testing = std.testing;

test "tanque quadrado: frequência e massas" {
    var params = types.Params{};
    params.n_tank = 1;
    params.tank[0] = .{ .side = 0.1, .fill = 0.05, .rho = 1000 };
    initTanks(&params);
    const tank = params.tank[0];
    try testing.expectApproxEqAbs(@as(f64, 0.5), tank.m_liq, 1e-12);
    const omega = @sqrt(limits.g0 * std.math.pi / 0.1 * std.math.tanh(@as(f64, std.math.pi * 0.5)));
    try testing.expectApproxEqRel(omega, tank.w1, 1e-9);
    try testing.expect(tank.m1 > 0 and tank.m1 < tank.m_liq);
}

test "CG e Steiner" {
    var params = types.Params{ .m_dry = 2, .Ixx = 0, .Iyy = 0, .Izz = 0, .r_dry = .{ 1, 0, 0 } };
    params.payload = .{ .enabled = 1, .m = 2, .r = .{ -1, 0, 0 } };
    const flags = state.Flags{};
    const ctx = state.Ctx{ .p = &params, .f = &flags, .tR = -1, .h_ground = 0, .tg = -1 };
    const state_vector = [_]f64{0} ** state.nx;
    const mass = compute(ctx, &state_vector);
    try testing.expectApproxEqAbs(@as(f64, 4), mass.m, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), mass.rcg[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), mass.I[1][1], 1e-12); // 2·1² + 2·1²
}

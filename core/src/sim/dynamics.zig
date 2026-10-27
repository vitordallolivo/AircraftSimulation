//! Equação mestre f(t, x) (`derivatives`) e integração RK4.
//!
//! Newton e Euler no CG atual (que muda com a carga e o líquido):
//!   m (dV/dt + ω × V) = F_aero + F_prop + F_solo + F_líquido + F_carga + m g
//!   I_cg dω/dt + ω × (I_cg ω) = Σ momentos no CG (giroscópico incluído)
//! mais cinemática (Euler), navegação, motores, sloshing, carga e piloto.
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
const gear = @import("../physics/gear.zig");
const terrain = @import("../physics/terrain.zig");
const mass = @import("../physics/mass.zig");
const atmosphere = @import("../physics/atmosphere.zig");
const guidance = @import("../control/guidance.zig");
const autopilot = @import("../control/autopilot.zig");
const V3 = vec.V3;

/// tudo o que o registro e os eventos precisam de um passo
pub const Out = struct {
    guide: guidance.Guide = .{},
    cmd: autopilot.Cmd = .{},
    Va: f64 = 0,
    Vg: f64 = 0,
    alfa: f64 = 0,
    beta: f64 = 0,
    gama: f64 = 0,
    chi: f64 = 0,
    qbar: f64 = 0,
    CL: f64 = 0,
    CD: f64 = 0,
    CDi: f64 = 0,
    CY: f64 = 0,
    CLgr: [limits.n_groups]f64 = [_]f64{0} ** limits.n_groups,
    ratioCL: f64 = 0,
    Mgr: [limits.n_groups]V3 = [_]V3{vec.zero} ** limits.n_groups,
    Mprop: V3 = vec.zero,
    Mgyro: V3 = vec.zero,
    Mgear: V3 = vec.zero,
    Mliq: V3 = vec.zero,
    Mpay: V3 = vec.zero,
    Mt: V3 = vec.zero,
    pr: prop.Out = .{},
    N: [limits.max_gear]f64 = [_]f64{0} ** limits.max_gear,
    htail: f64 = 1e9,
    hprop: f64 = 1e9, // folga da ponta da pá mais baixa sobre o terreno (m)
    RN: f64 = 0,
    Rnw: f64 = 0,
    Rmw: f64 = 0,
    m: f64 = 0,
    rcg: V3 = vec.zero,
    I: vec.M3 = undefined,
    Fsl: V3 = vec.zero,
    W: V3 = vec.zero,
    hdot: f64 = 0,
    nz: f64 = 0,
};

/// comandos de fora no lugar dos do piloto; os integradores do piloto ficam parados (sem acumular
/// erro enquanto ele não manda) — ao voltar para o automático, `runner.handover` sincroniza
fn manual(params: *const types.Params, cmd: *autopilot.Cmd, state_rates: []f64) void {
    const gains = &params.ap;
    const pilot = &params.pilot;
    const ok = struct {
        fn finiteOrZero(value: f64, limit: f64) f64 {
            return if (std.math.isFinite(value)) fmath.sat(value, limit) else 0.0;
        }
    }.finiteOrZero;
    cmd.de = ok(pilot.de, gains.de_max);
    cmd.da = ok(pilot.da, gains.da_max);
    cmd.dr = ok(pilot.dr, gains.dr_max);
    cmd.thr = if (std.math.isFinite(pilot.thr)) fmath.lim(pilot.thr, 0.0, 1.0) else 0.0;
    cmd.dw = fmath.sat(-cmd.dr * params.steer_sign, 20.0 * std.math.rad_per_deg); // roda direcionável segue o leme
    state_rates[state.index(.int_height)] = 0.0;
    state_rates[state.index(.int_speed)] = 0.0;
    state_rates[state.index(.int_alpha)] = 0.0;
}

/// a equação mestre: as derivadas `state_rates` = f(time, state_vector); com `out`, também o que o registro e os
/// eventos precisam do instante
pub fn derivatives(ctx: state.Ctx, time: f64, state_vector: []const f64, state_rates: []f64, out: ?*Out) void {
    const params = ctx.p;
    var scratch: Out = undefined; // sem saída: só guide e cmd são escritos (evita zerar ~2 KB por chamada)
    const result: *Out = out orelse &scratch;
    state_rates[0..state.nx].* = @as([state.nx]f64, @splat(0.0)); // tamanho em comptime: stores vetoriais, sem chamar memset
    const body_to_ned = vec.rotation(state_vector[state.index(.roll)], state_vector[state.index(.pitch)], state_vector[state.index(.yaw)]);
    const VB = V3{ state_vector[state.index(.vel_x)], state_vector[state.index(.vel_y)], state_vector[state.index(.vel_z)] };
    const body_rates = V3{ state_vector[state.index(.rate_p)], state_vector[state.index(.rate_q)], state_vector[state.index(.rate_r)] };
    const altitude = -state_vector[state.index(.down)];

    const mass_props = mass.compute(ctx, state_vector);

    // vento e velocidade em relação ao ar
    const wind_ned = atmosphere.wind(&params.env, time, altitude, ctx.tg);
    const Vr = VB - vec.mulT(body_to_ned, wind_ned);
    const Va = vec.norm(Vr);
    const al = fmath.atan2(Vr[2], Vr[0]);
    const be = if (Va > 0.1) fmath.asin(Vr[1] / Va) else 0.0;
    const qb = 0.5 * params.env.rho * Va * Va;
    const vn = vec.mul(body_to_ned, VB);
    const Vg = fmath.hypot(vn[0], vn[1]);
    const chi = fmath.atan2(vn[1], vn[0]);
    const on_ground = gear.touching(params, state_vector, body_to_ned);

    // guiamento e piloto
    result.guide = guidance.guide(ctx, state_vector[state.index(.north)], state_vector[state.index(.east)], Vg);
    result.cmd = autopilot.commands(ctx, time, state_vector, .{ .Va = Va, .Vg = Vg, .al = al, .be = be, .chi = chi, .hdot = -vn[2], .qb = qb, .m = mass_props.m, .on_ground = on_ground }, &result.guide, state_rates);
    if (params.pilot.manual != 0) manual(params, &result.cmd, state_rates);
    const cmd = &result.cmd;

    // forças e momentos
    const hgnd = terrain.height(params, state_vector[state.index(.north)], state_vector[state.index(.east)]);
    // a propulsão antes da aerodinâmica: os modificadores (esteira da hélice) olham a tração do instante
    const pr = prop.compute(params, Vr, body_rates, mass_props.rcg, state_vector[state.index(.rps0) .. state.index(.rps0) + limits.max_props], cmd.thr, cmd.dr, state_vector[state.index(.pitch)], altitude);
    var env = mods.Env{};
    if (params.n_mod > 0) {
        var thrusts: [limits.max_props]f64 = undefined;
        var torques: [limits.max_props]f64 = undefined;
        for (0..@as(usize, @intCast(params.n_prop))) |i| {
            thrusts[i] = pr.u[i].T;
            torques[i] = pr.u[i].Q;
        }
        env = mods.envFrom(params, Vr, body_rates, &thrusts, &torques);
    }
    const ae = aeromodel.compute(params, Vr, body_rates, mass_props.rcg, altitude - hgnd, .{ cmd.de, cmd.da, cmd.dr }, &env);
    const gr = gear.compute(ctx, state_vector, body_to_ned, mass_props.rcg, cmd.dw);
    var force = ae.F + pr.F + gr.F;
    var moment = ae.M + pr.M + pr.Mgyro + gr.M;

    // gravidade aparente no corpo para o líquido e para a carga
    result.nz = -force[2] / (mass_props.m * limits.g0);
    result.hdot = -vn[2];
    const sl = mass.slosh(params, state_vector, force, body_rates, &mass_props, state_rates);
    const aap = -force / vec.splat(mass_props.m) - vec.cross(body_rates, vec.cross(body_rates, mass_props.rL));
    const pl = mass.payload(ctx, state_vector, aap, &mass_props, state_rates);
    force += sl.F + pl.F;
    moment += sl.M + pl.M;

    // peso
    const roll = fmath.sincos(state_vector[state.index(.roll)]);
    const pitch = fmath.sincos(state_vector[state.index(.pitch)]);
    force += V3{ -pitch.s, pitch.c * roll.s, pitch.c * roll.c } * vec.splat(mass_props.m * limits.g0);

    // corpo rígido
    const acc = force / vec.splat(mass_props.m) - vec.cross(body_rates, VB);
    state_rates[state.index(.vel_x)] = acc[0];
    state_rates[state.index(.vel_y)] = acc[1];
    state_rates[state.index(.vel_z)] = acc[2];
    const Iw = vec.mul(mass_props.I, body_rates);
    const wd = vec.solve3(mass_props.I, moment - vec.cross(body_rates, Iw));
    state_rates[state.index(.rate_p)] = wd[0];
    state_rates[state.index(.rate_q)] = wd[1];
    state_rates[state.index(.rate_r)] = wd[2];
    const qs_rc = body_rates[1] * roll.s + body_rates[2] * roll.c;
    state_rates[state.index(.roll)] = body_rates[0] + qs_rc * pitch.s / pitch.c;
    state_rates[state.index(.pitch)] = body_rates[1] * roll.c - body_rates[2] * roll.s;
    state_rates[state.index(.yaw)] = qs_rc / pitch.c;
    state_rates[state.index(.north)] = vn[0];
    state_rates[state.index(.east)] = vn[1];
    state_rates[state.index(.down)] = vn[2];
    const np: usize = @intCast(params.n_prop);
    for (0..np) |i| state_rates[state.rps(i)] = pr.u[i].drps;
    state_rates[state.index(.energy)] = pr.P;

    if (out == null) return;

    // ---------------- saídas ----------------
    result.Va = Va;
    result.Vg = Vg;
    result.alfa = al;
    result.beta = be;
    result.chi = chi;
    result.qbar = qb;
    const Vt = vec.norm(vn);
    result.gama = if (Vt > 0.5) fmath.asin(-vn[2] / Vt) else 0.0;
    const sa = fmath.sincos(al);
    const sb = fmath.sincos(be);
    const qS = qb * params.Sref;
    if (qS > 1e-3) {
        result.CL = (-ae.F[2] * sa.c + ae.F[0] * sa.s) / qS;
        result.CD = -(ae.F[0] * sa.c * sb.c + ae.F[1] * sb.s + ae.F[2] * sa.s * sb.c) / qS;
        result.CDi = -(ae.Fi[0] * sa.c * sb.c + ae.Fi[1] * sb.s + ae.Fi[2] * sa.s * sb.c) / qS;
        result.CY = ae.F[1] / qS;
        for (0..limits.n_groups) |k| result.CLgr[k] = (-ae.Fg[k][2] * sa.c + ae.Fg[k][0] * sa.s) / qS;
        result.CLgr[limits.group_vtail] = ae.Fg[limits.group_vtail][1] / qS; // EV: força lateral
    }
    result.ratioCL = ae.ratioCL;
    result.Mgr = ae.Mg;
    result.Mprop = pr.M;
    result.Mgyro = pr.Mgyro;
    result.Mgear = gr.M;
    result.Mliq = sl.M;
    result.Mpay = pl.M;
    result.Mt = moment;
    result.pr = pr;
    result.N = gr.N;
    result.m = mass_props.m;
    result.rcg = mass_props.rcg;
    result.I = mass_props.I;
    result.Fsl = sl.F;
    result.W = wind_ned;
    result.htail = 1e9;
    var xm: f64 = 0;
    var nm: f64 = 0;
    var xn: f64 = 0;
    const ng: usize = @intCast(params.n_gear);
    for (params.gear[0..ng]) |*gear_point| {
        if (gear_point.kind == types.gear_skid) {
            const pc = vec.mul(body_to_ned, vec.v3(gear_point.r));
            result.htail = @min(result.htail, -(state_vector[state.index(.down)] + pc[2]) - terrain.height(params, state_vector[state.index(.north)] + pc[0], state_vector[state.index(.east)] + pc[1]));
        }
        if (gear_point.kind == types.gear_main) {
            xm += gear_point.r[0];
            nm += 1;
        }
        if (gear_point.kind == types.gear_steer) xn = gear_point.r[0];
    }
    // folga da ponta da pá: o ponto mais baixo do disco de cada hélice. O disco (raio D/2) fica no plano normal ao
    // eixo; o ponto mais baixo está na direção da vertical projetada nesse plano (geometria, sem fórmula de fonte)
    result.hprop = 1e9;
    const npr: usize = @intCast(params.n_prop);
    for (params.prop[0..npr]) |*prop_unit| {
        const ax = vec.mul(body_to_ned, prop.axis(params, prop_unit));
        const hub = vec.mul(body_to_ned, vec.v3(prop_unit.r));
        const down = V3{ 0, 0, 1 };
        const kp = down - ax * vec.splat(vec.dot(down, ax));
        const nk = vec.norm(kp);
        const low = if (nk > 1e-9) hub + kp * vec.splat(0.5 * prop_unit.D / nk) else hub;
        result.hprop = @min(result.hprop, -(state_vector[state.index(.down)] + low[2]) - terrain.height(params, state_vector[state.index(.north)] + low[0], state_vector[state.index(.east)] + low[1]));
    }
    // reações no trem pelo artigo (Riboldi et al., eqs. 3-5): pista plana
    const Lift = result.CL * qS;
    result.RN = mass_props.m * limits.g0 - pr.T_sin - Lift;
    const chimw = mass_props.rcg[0] - (if (nm > 0) xm / nm else 0.0);
    const chinw = xn - mass_props.rcg[0];
    const den = chimw + chinw;
    result.Rnw = if (@abs(den) > 1e-9) (result.RN * chimw - (ae.M[1] + pr.M[1])) / den else 0.0;
    result.Rmw = result.RN - result.Rnw;
}

/// um passo RK4 de tamanho `step` sobre vetores SIMD do tamanho do estado
pub fn rk4(ctx: state.Ctx, time: f64, state_vector: *[state.nx]f64, step: f64) void {
    var k1: [state.nx]f64 = undefined;
    var k2: [state.nx]f64 = undefined;
    var k3: [state.nx]f64 = undefined;
    var k4: [state.nx]f64 = undefined;
    const x0: state.Vec = state_vector.*;
    const step_vec: state.Vec = @splat(step);
    const half_step: state.Vec = @splat(0.5 * step);
    derivatives(ctx, time, state_vector, &k1, null);
    var xt: [state.nx]f64 = x0 + half_step * @as(state.Vec, k1);
    derivatives(ctx, time + 0.5 * step, &xt, &k2, null);
    xt = x0 + half_step * @as(state.Vec, k2);
    derivatives(ctx, time + 0.5 * step, &xt, &k3, null);
    xt = x0 + step_vec * @as(state.Vec, k3);
    derivatives(ctx, time + step, &xt, &k4, null);
    const sum = @as(state.Vec, k1) + @as(state.Vec, @splat(2.0)) * (@as(state.Vec, k2) + @as(state.Vec, k3)) + @as(state.Vec, k4);
    state_vector.* = x0 + @as(state.Vec, @splat(step / 6.0)) * sum;
}

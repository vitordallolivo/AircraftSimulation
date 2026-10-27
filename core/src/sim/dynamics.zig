//! Equação mestre f(t, x) e integração RK4.
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
    g: guidance.Guide = .{},
    c: autopilot.Cmd = .{},
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
fn manual(p: *const types.Params, cmd: *autopilot.Cmd, dx: []f64) void {
    const a = &p.ap;
    const u = &p.pilot;
    const ok = struct {
        fn f(v: f64, lim: f64) f64 {
            return if (std.math.isFinite(v)) fmath.sat(v, lim) else 0.0;
        }
    }.f;
    cmd.de = ok(u.de, a.de_max);
    cmd.da = ok(u.da, a.da_max);
    cmd.dr = ok(u.dr, a.dr_max);
    cmd.thr = if (std.math.isFinite(u.thr)) fmath.lim(u.thr, 0.0, 1.0) else 0.0;
    cmd.dw = fmath.sat(-cmd.dr * p.steer_sign, 20.0 * std.math.rad_per_deg); // roda direcionável segue o leme
    dx[state.IH] = 0.0;
    dx[state.IV] = 0.0;
    dx[state.ITH] = 0.0;
}

pub fn f(c: state.Ctx, t: f64, x: []const f64, dx: []f64, out: ?*Out) void {
    const p = c.p;
    var oo: Out = undefined; // sem saída: só g e c são escritos (evita zerar ~2 KB por chamada)
    const o: *Out = out orelse &oo;
    dx[0..state.nx].* = @as([state.nx]f64, @splat(0.0)); // tamanho em comptime: stores vetoriais, sem chamar memset
    const R = vec.rotation(x[state.PHI], x[state.THE], x[state.PSI]);
    const VB = V3{ x[state.U], x[state.V], x[state.W] };
    const w = V3{ x[state.P], x[state.Q], x[state.R] };
    const h = -x[state.D];

    const ms = mass.compute(c, x);

    // vento e velocidade em relação ao ar
    const WN = atmosphere.wind(&p.env, t, h, c.tg);
    const Vr = VB - vec.mulT(R, WN);
    const Va = vec.norm(Vr);
    const al = fmath.atan2(Vr[2], Vr[0]);
    const be = if (Va > 0.1) fmath.asin(Vr[1] / Va) else 0.0;
    const qb = 0.5 * p.env.rho * Va * Va;
    const vn = vec.mul(R, VB);
    const Vg = fmath.hypot(vn[0], vn[1]);
    const chi = fmath.atan2(vn[1], vn[0]);
    const on_ground = gear.touching(p, x, R);

    // guiamento e piloto
    o.g = guidance.guide(c, x[state.N], x[state.E], Vg);
    o.c = autopilot.commands(c, t, x, .{ .Va = Va, .Vg = Vg, .al = al, .be = be, .chi = chi, .hdot = -vn[2], .qb = qb, .m = ms.m, .on_ground = on_ground }, &o.g, dx);
    if (p.pilot.manual != 0) manual(p, &o.c, dx);
    const cmd = &o.c;

    // forças e momentos
    const hgnd = terrain.height(p, x[state.N], x[state.E]);
    // a propulsão antes da aerodinâmica: os modificadores (esteira da hélice) olham a tração do instante
    const pr = prop.compute(p, Vr, w, ms.rcg, x[state.RPS0 .. state.RPS0 + limits.max_props], cmd.thr, cmd.dr, x[state.THE], h);
    var env = mods.Env{};
    if (p.n_mod > 0) {
        var Tn: [limits.max_props]f64 = undefined;
        var Qn: [limits.max_props]f64 = undefined;
        for (0..@as(usize, @intCast(p.n_prop))) |i| {
            Tn[i] = pr.u[i].T;
            Qn[i] = pr.u[i].Q;
        }
        env = mods.envFrom(p, Vr, w, &Tn, &Qn);
    }
    const ae = aeromodel.compute(p, Vr, w, ms.rcg, h - hgnd, .{ cmd.de, cmd.da, cmd.dr }, &env);
    const gr = gear.compute(c, x, R, ms.rcg, cmd.dw);
    var F = ae.F + pr.F + gr.F;
    var M = ae.M + pr.M + pr.Mgyro + gr.M;

    // gravidade aparente no corpo para o líquido e para a carga
    o.nz = -F[2] / (ms.m * limits.g0);
    o.hdot = -vn[2];
    const sl = mass.slosh(p, x, F, w, &ms, dx);
    const aap = -F / vec.splat(ms.m) - vec.cross(w, vec.cross(w, ms.rL));
    const pl = mass.payload(c, x, aap, &ms, dx);
    F += sl.F + pl.F;
    M += sl.M + pl.M;

    // peso
    const a = fmath.sincos(x[state.PHI]);
    const b = fmath.sincos(x[state.THE]);
    F += V3{ -b.s, b.c * a.s, b.c * a.c } * vec.splat(ms.m * limits.g0);

    // corpo rígido
    const acc = F / vec.splat(ms.m) - vec.cross(w, VB);
    dx[state.U] = acc[0];
    dx[state.V] = acc[1];
    dx[state.W] = acc[2];
    const Iw = vec.mul(ms.I, w);
    const wd = vec.solve3(ms.I, M - vec.cross(w, Iw));
    dx[state.P] = wd[0];
    dx[state.Q] = wd[1];
    dx[state.R] = wd[2];
    const qs_rc = w[1] * a.s + w[2] * a.c;
    dx[state.PHI] = w[0] + qs_rc * b.s / b.c;
    dx[state.THE] = w[1] * a.c - w[2] * a.s;
    dx[state.PSI] = qs_rc / b.c;
    dx[state.N] = vn[0];
    dx[state.E] = vn[1];
    dx[state.D] = vn[2];
    const np: usize = @intCast(p.n_prop);
    for (0..np) |i| dx[state.rps(i)] = pr.u[i].drps;
    dx[state.EN] = pr.P;

    if (out == null) return;

    // ---------------- saídas ----------------
    o.Va = Va;
    o.Vg = Vg;
    o.alfa = al;
    o.beta = be;
    o.chi = chi;
    o.qbar = qb;
    const Vt = vec.norm(vn);
    o.gama = if (Vt > 0.5) fmath.asin(-vn[2] / Vt) else 0.0;
    const sa = fmath.sincos(al);
    const sb = fmath.sincos(be);
    const qS = qb * p.Sref;
    if (qS > 1e-3) {
        o.CL = (-ae.F[2] * sa.c + ae.F[0] * sa.s) / qS;
        o.CD = -(ae.F[0] * sa.c * sb.c + ae.F[1] * sb.s + ae.F[2] * sa.s * sb.c) / qS;
        o.CDi = -(ae.Fi[0] * sa.c * sb.c + ae.Fi[1] * sb.s + ae.Fi[2] * sa.s * sb.c) / qS;
        o.CY = ae.F[1] / qS;
        for (0..limits.n_groups) |k| o.CLgr[k] = (-ae.Fg[k][2] * sa.c + ae.Fg[k][0] * sa.s) / qS;
        o.CLgr[limits.group_vtail] = ae.Fg[limits.group_vtail][1] / qS; // EV: força lateral
    }
    o.ratioCL = ae.ratioCL;
    o.Mgr = ae.Mg;
    o.Mprop = pr.M;
    o.Mgyro = pr.Mgyro;
    o.Mgear = gr.M;
    o.Mliq = sl.M;
    o.Mpay = pl.M;
    o.Mt = M;
    o.pr = pr;
    o.N = gr.N;
    o.m = ms.m;
    o.rcg = ms.rcg;
    o.I = ms.I;
    o.Fsl = sl.F;
    o.W = WN;
    o.htail = 1e9;
    var xm: f64 = 0;
    var nm: f64 = 0;
    var xn: f64 = 0;
    const ng: usize = @intCast(p.n_gear);
    for (p.gear[0..ng]) |*g| {
        if (g.kind == types.gear_skid) {
            const pc = vec.mul(R, vec.v3(g.r));
            o.htail = @min(o.htail, -(x[state.D] + pc[2]) - terrain.height(p, x[state.N] + pc[0], x[state.E] + pc[1]));
        }
        if (g.kind == types.gear_main) {
            xm += g.r[0];
            nm += 1;
        }
        if (g.kind == types.gear_steer) xn = g.r[0];
    }
    // folga da ponta da pá: o ponto mais baixo do disco de cada hélice. O disco (raio D/2) fica no plano normal ao
    // eixo; o ponto mais baixo está na direção da vertical projetada nesse plano (geometria, sem fórmula de fonte)
    o.hprop = 1e9;
    const npr: usize = @intCast(p.n_prop);
    for (p.prop[0..npr]) |*u| {
        const ax = vec.mul(R, prop.axis(p, u));
        const hub = vec.mul(R, vec.v3(u.r));
        const down = V3{ 0, 0, 1 };
        const kp = down - ax * vec.splat(vec.dot(down, ax));
        const nk = vec.norm(kp);
        const low = if (nk > 1e-9) hub + kp * vec.splat(0.5 * u.D / nk) else hub;
        o.hprop = @min(o.hprop, -(x[state.D] + low[2]) - terrain.height(p, x[state.N] + low[0], x[state.E] + low[1]));
    }
    // reações no trem pelo artigo (Riboldi et al., eqs. 3-5): pista plana
    const Lift = o.CL * qS;
    o.RN = ms.m * limits.g0 - pr.T_sin - Lift;
    const chimw = ms.rcg[0] - (if (nm > 0) xm / nm else 0.0);
    const chinw = xn - ms.rcg[0];
    const den = chimw + chinw;
    o.Rnw = if (@abs(den) > 1e-9) (o.RN * chimw - (ae.M[1] + pr.M[1])) / den else 0.0;
    o.Rmw = o.RN - o.Rnw;
}

/// RK4 sobre vetores SIMD do tamanho do estado
pub fn rk4(c: state.Ctx, t: f64, x: *[state.nx]f64, h: f64) void {
    var k1: [state.nx]f64 = undefined;
    var k2: [state.nx]f64 = undefined;
    var k3: [state.nx]f64 = undefined;
    var k4: [state.nx]f64 = undefined;
    const x0: state.Vec = x.*;
    const hv: state.Vec = @splat(h);
    const h2: state.Vec = @splat(0.5 * h);
    f(c, t, x, &k1, null);
    var xt: [state.nx]f64 = x0 + h2 * @as(state.Vec, k1);
    f(c, t + 0.5 * h, &xt, &k2, null);
    xt = x0 + h2 * @as(state.Vec, k2);
    f(c, t + 0.5 * h, &xt, &k3, null);
    xt = x0 + hv * @as(state.Vec, k3);
    f(c, t + h, &xt, &k4, null);
    const sum = @as(state.Vec, k1) + @as(state.Vec, @splat(2.0)) * (@as(state.Vec, k2) + @as(state.Vec, k3)) + @as(state.Vec, k4);
    x.* = x0 + @as(state.Vec, @splat(h / 6.0)) * sum;
}

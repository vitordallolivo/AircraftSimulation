//! Equação mestre f(t, x) e integração RK4.
//!
//! Newton e Euler no CG atual (que muda com a carga e o líquido):
//!   m (dV/dt + ω × V) = F_aero + F_prop + F_solo + F_líquido + F_carga + m g
//!   I_cg dω/dt + ω × (I_cg ω) = Σ momentos no CG (giroscópico incluído)
//! mais cinemática (Euler), navegação, motores, sloshing, carga e piloto.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const S = @import("state.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const prop = @import("../physics/propulsion.zig");
const gear = @import("../physics/gear.zig");
const terrain = @import("../physics/terrain.zig");
const mass = @import("../physics/mass.zig");
const atm = @import("../physics/atmosphere.zig");
const G = @import("../control/guidance.zig");
const AP = @import("../control/autopilot.zig");
const V3 = vec.V3;

/// tudo o que o registro e os eventos precisam de um passo
pub const Out = struct {
    g: G.Guide = .{},
    c: AP.Cmd = .{},
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
    CLgr: [L.n_groups]f64 = [_]f64{0} ** L.n_groups,
    ratioCL: f64 = 0,
    Mgr: [L.n_groups]V3 = [_]V3{vec.zero} ** L.n_groups,
    Mprop: V3 = vec.zero,
    Mgyro: V3 = vec.zero,
    Mgear: V3 = vec.zero,
    Mliq: V3 = vec.zero,
    Mpay: V3 = vec.zero,
    Mt: V3 = vec.zero,
    pr: prop.Out = .{},
    N: [L.max_gear]f64 = [_]f64{0} ** L.max_gear,
    htail: f64 = 1e9,
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

pub fn f(c: S.Ctx, t: f64, x: []const f64, dx: []f64, out: ?*Out) void {
    const p = c.p;
    var oo: Out = undefined; // sem saída: só g e c são escritos (evita zerar ~2 KB por chamada)
    const o: *Out = out orelse &oo;
    dx[0..S.nx].* = @as([S.nx]f64, @splat(0.0)); // tamanho em comptime: stores vetoriais, sem chamar memset
    const R = vec.rotation(x[S.PHI], x[S.THE], x[S.PSI]);
    const VB = V3{ x[S.U], x[S.V], x[S.W] };
    const w = V3{ x[S.P], x[S.Q], x[S.R] };
    const h = -x[S.D];

    const ms = mass.compute(c, x);

    // vento e velocidade em relação ao ar
    const WN = atm.wind(&p.env, t, h, c.tg);
    const Vr = VB - vec.mulT(R, WN);
    const Va = vec.norm(Vr);
    const al = fm.atan2(Vr[2], Vr[0]);
    const be = if (Va > 0.1) fm.asin(Vr[1] / Va) else 0.0;
    const qb = 0.5 * p.env.rho * Va * Va;
    const vn = vec.mul(R, VB);
    const Vg = fm.hypot(vn[0], vn[1]);
    const chi = fm.atan2(vn[1], vn[0]);
    const on_ground = gear.touching(p, x, R);

    // guiamento e piloto
    o.g = G.guide(c, x[S.N], x[S.E], Vg);
    o.c = AP.commands(c, t, x, .{ .Va = Va, .Vg = Vg, .al = al, .be = be, .chi = chi, .hdot = -vn[2], .qb = qb, .m = ms.m, .on_ground = on_ground }, &o.g, dx);
    const cmd = &o.c;

    // forças e momentos
    const hgnd = terrain.height(p, x[S.N], x[S.E]);
    const ae = aero.compute(p, Vr, w, ms.rcg, h - hgnd, .{ cmd.de, cmd.da, cmd.dr });
    const pr = prop.compute(p, Vr, w, ms.rcg, x[S.RPS0 .. S.RPS0 + L.max_props], cmd.thr, cmd.dr, x[S.THE], h);
    const gr = gear.compute(c, x, R, ms.rcg, cmd.dw);
    var F = ae.F + pr.F + gr.F;
    var M = ae.M + pr.M + pr.Mgyro + gr.M;

    // gravidade aparente no corpo para o líquido e para a carga
    o.nz = -F[2] / (ms.m * L.g0);
    o.hdot = -vn[2];
    const sl = mass.slosh(p, x, F, w, &ms, dx);
    const aap = -F / vec.splat(ms.m) - vec.cross(w, vec.cross(w, ms.rL));
    const pl = mass.payload(c, x, aap, &ms, dx);
    F += sl.F + pl.F;
    M += sl.M + pl.M;

    // peso
    const a = fm.sincos(x[S.PHI]);
    const b = fm.sincos(x[S.THE]);
    F += V3{ -b.s, b.c * a.s, b.c * a.c } * vec.splat(ms.m * L.g0);

    // corpo rígido
    const acc = F / vec.splat(ms.m) - vec.cross(w, VB);
    dx[S.U] = acc[0];
    dx[S.V] = acc[1];
    dx[S.W] = acc[2];
    const Iw = vec.mul(ms.I, w);
    const wd = vec.solve3(ms.I, M - vec.cross(w, Iw));
    dx[S.P] = wd[0];
    dx[S.Q] = wd[1];
    dx[S.R] = wd[2];
    const qs_rc = w[1] * a.s + w[2] * a.c;
    dx[S.PHI] = w[0] + qs_rc * b.s / b.c;
    dx[S.THE] = w[1] * a.c - w[2] * a.s;
    dx[S.PSI] = qs_rc / b.c;
    dx[S.N] = vn[0];
    dx[S.E] = vn[1];
    dx[S.D] = vn[2];
    const np: usize = @intCast(p.n_prop);
    for (0..np) |i| dx[S.rps(i)] = pr.u[i].drps;
    dx[S.EN] = pr.P;

    if (out == null) return;

    // ---------------- saídas ----------------
    o.Va = Va;
    o.Vg = Vg;
    o.alfa = al;
    o.beta = be;
    o.chi = chi;
    o.qbar = qb;
    const Vt = vec.norm(vn);
    o.gama = if (Vt > 0.5) fm.asin(-vn[2] / Vt) else 0.0;
    const sa = fm.sincos(al);
    const sb = fm.sincos(be);
    const qS = qb * p.Sref;
    if (qS > 1e-3) {
        o.CL = (-ae.F[2] * sa.c + ae.F[0] * sa.s) / qS;
        o.CD = -(ae.F[0] * sa.c * sb.c + ae.F[1] * sb.s + ae.F[2] * sa.s * sb.c) / qS;
        o.CDi = -(ae.Fi[0] * sa.c * sb.c + ae.Fi[1] * sb.s + ae.Fi[2] * sa.s * sb.c) / qS;
        o.CY = ae.F[1] / qS;
        for (0..L.n_groups) |k| o.CLgr[k] = (-ae.Fg[k][2] * sa.c + ae.Fg[k][0] * sa.s) / qS;
        o.CLgr[L.group_vtail] = ae.Fg[L.group_vtail][1] / qS; // EV: força lateral
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
        if (g.kind == T.gear_skid) {
            const pc = vec.mul(R, vec.v3(g.r));
            o.htail = @min(o.htail, -(x[S.D] + pc[2]) - terrain.height(p, x[S.N] + pc[0], x[S.E] + pc[1]));
        }
        if (g.kind == T.gear_main) {
            xm += g.r[0];
            nm += 1;
        }
        if (g.kind == T.gear_steer) xn = g.r[0];
    }
    // reações no trem pelo artigo (Riboldi et al., eqs. 3-5): pista plana
    const Lift = o.CL * qS;
    o.RN = ms.m * L.g0 - pr.T_sin - Lift;
    const chimw = ms.rcg[0] - (if (nm > 0) xm / nm else 0.0);
    const chinw = xn - ms.rcg[0];
    const den = chimw + chinw;
    o.Rnw = if (@abs(den) > 1e-9) (o.RN * chimw - (ae.M[1] + pr.M[1])) / den else 0.0;
    o.Rmw = o.RN - o.Rnw;
}

/// RK4 sobre vetores SIMD do tamanho do estado
pub fn rk4(c: S.Ctx, t: f64, x: *[S.nx]f64, h: f64) void {
    var k1: [S.nx]f64 = undefined;
    var k2: [S.nx]f64 = undefined;
    var k3: [S.nx]f64 = undefined;
    var k4: [S.nx]f64 = undefined;
    const x0: S.Vec = x.*;
    const hv: S.Vec = @splat(h);
    const h2: S.Vec = @splat(0.5 * h);
    f(c, t, x, &k1, null);
    var xt: [S.nx]f64 = x0 + h2 * @as(S.Vec, k1);
    f(c, t + 0.5 * h, &xt, &k2, null);
    xt = x0 + h2 * @as(S.Vec, k2);
    f(c, t + 0.5 * h, &xt, &k3, null);
    xt = x0 + hv * @as(S.Vec, k3);
    f(c, t + h, &xt, &k4, null);
    const sum = @as(S.Vec, k1) + @as(S.Vec, @splat(2.0)) * (@as(S.Vec, k2) + @as(S.Vec, k3)) + @as(S.Vec, k4);
    x.* = x0 + @as(S.Vec, @splat(h / 6.0)) * sum;
}

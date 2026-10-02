//! Aerodinâmica por componentes.
//!
//! Cada painel tem centro aerodinâmico, corda e normal próprios. A velocidade local é
//! V_ar + ω × r, então amortecimentos (C_mq, C_lp, C_nr...) e efeitos de diedro e cauda
//! (C_lβ, C_nβ) aparecem sozinhos, sem derivadas de estabilidade prontas.
//!   α_local = atan2(v·ez, v·ex) − downwash + tau (mix · δ)
//!   L = q S CL(α) ⟂ v;  D = q S (CD0 + CL²/(π e AR) φ(h))
//! A fuselagem entra com área de arrasto e C_mα, C_nβ, C_Yβ próprios.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const fm = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const Out = struct {
    F: V3 = vec.zero,
    M: V3 = vec.zero,
    Fg: [L.n_groups]V3 = [_]V3{vec.zero} ** L.n_groups,
    Mg: [L.n_groups]V3 = [_]V3{vec.zero} ** L.n_groups,
    Fi: V3 = vec.zero, // parte induzida do arrasto
    ratioCL: f64 = 0, // max CL/CLmax nos painéis da asa
};

/// mistura linear / placa plana (Beard e McLain): 0 antes do estol, 1 depois
pub fn sigmaStall(al: f64, a0: f64, M: f64) f64 {
    const e1 = fm.exp(-M * (al - a0));
    const e2 = fm.exp(M * (al + a0));
    return (1.0 + e1 + e2) / ((1.0 + e1) * (1.0 + e2));
}

fn clPanel(s: *const T.Surface, al: f64, M: f64) f64 {
    const sg = sigmaStall(al, s.a0, M);
    const sc = fm.sincos(al);
    return (1.0 - sg) * (s.CL0 + s.CLa * al) + sg * 2.0 * fm.sgn(al) * sc.s * sc.s * sc.c;
}

fn peakCL(s: *const T.Surface, M: f64) f64 {
    var pk: f64 = -1e9;
    var al: f64 = 0.0;
    while (al < 0.9) : (al += 2e-4) pk = @max(pk, clPanel(s, al, M));
    return pk;
}

/// eixos de cada painel e ângulo de estol a0 que dá o CLmax pedido
pub fn init(p: *T.Params) void {
    const n: usize = @intCast(p.n_surf);
    for (p.surf[0..n]) |*s| {
        const i = s.incidence;
        const si = fm.sincos(i);
        var ex = V3{ si.c, 0, -si.s };
        var ez = V3{ si.s, 0, si.c };
        if (s.vertical != 0) { // normal para +y; incidência = calagem em guinada
            ex = .{ si.c, -si.s, 0 };
            ez = .{ si.s, si.c, 0 };
        } else { // diedro: gira em x, a normal inclina para dentro
            const ang = -@as(f64, @floatFromInt(s.side)) * s.dihedral;
            const r = fm.sincos(ang);
            // temporários: `ez = .{..ez..}` escreveria no destino enquanto ainda lê dele
            const ez_r = V3{ ez[0], ez[1] * r.c - ez[2] * r.s, ez[1] * r.s + ez[2] * r.c };
            const ex_r = V3{ ex[0], ex[1] * r.c - ex[2] * r.s, ex[1] * r.s + ex[2] * r.c };
            ez = ez_r;
            ex = ex_r;
        }
        s.ex = ex;
        s.ez = ez;
        s.ey = vec.cross(ez, ex);
        var lo: f64 = 0.02;
        var hi: f64 = 0.8;
        for (0..50) |_| {
            s.a0 = 0.5 * (lo + hi);
            if (peakCL(s, p.Mst) > s.CLmax) hi = s.a0 else lo = s.a0;
        }
    }
}

/// Vr: velocidade do ponto O em relação ao ar (corpo); w: (p,q,r); rcg: CG atual;
/// h: altura de O; δ = (δe, δa, δr). Momentos no CG.
pub fn compute(p: *const T.Params, Vr: V3, w: V3, rcg: V3, h: f64, d: V3) Out {
    var o = Out{};
    const Va = vec.norm(Vr);
    const alfa = fm.atan2(Vr[2], Vr[0]);
    const n: usize = @intCast(p.n_surf);
    for (p.surf[0..n]) |*s| {
        const r = vec.v3(s.r);
        const ex = vec.v3(s.ex);
        const ez = vec.v3(s.ez);
        const v = Vr + vec.cross(w, r);
        const u = vec.dot(v, ex);
        const ww = vec.dot(v, ez);
        const V2 = u * u + ww * ww;
        if (V2 < 1e-6) continue;
        const Vp = @sqrt(V2);
        var al = fm.atan2(ww, u);
        if (s.downwash != 0) al -= s.eps0 + s.depsda * alfa;
        al += s.tau * vec.dot(vec.v3(s.mix), d);
        const CL = clPanel(s, al, p.Mst);
        const sg = sigmaStall(al, s.a0, p.Mst);
        var fge: f64 = 1.0;
        if (s.vertical == 0) { // efeito solo (McCormick)
            const hp = h - s.r[2];
            const r16 = 16.0 * @max(hp, 0.01) / p.bref;
            fge = r16 * r16 / (1.0 + r16 * r16);
        }
        const CDi = (1.0 - sg) * CL * CL / (fm.pi * s.e * s.AR) * fge;
        const sa = fm.sin(al);
        const CD = s.CD0 + CDi + sg * 1.2 * sa * sa;
        const qS = 0.5 * p.env.rho * V2 * s.eta * s.S;
        const lift_dir = (ex * vec.splat(ww) - ez * vec.splat(u)) / vec.splat(Vp);
        const drag_dir = -(ex * vec.splat(u) + ez * vec.splat(ww)) / vec.splat(Vp);
        const F = lift_dir * vec.splat(qS * CL) + drag_dir * vec.splat(qS * CD);
        const Fi = drag_dir * vec.splat(qS * CDi);
        const M = vec.cross(r - rcg, F) + vec.v3(s.ey) * vec.splat(qS * s.c * s.Cmac);
        const g: usize = @intCast(s.group);
        o.Fg[g] += F;
        o.Mg[g] += M;
        o.F += F;
        o.M += M;
        o.Fi += Fi;
        if (s.group == L.group_wing and s.CLmax > 0) o.ratioCL = @max(o.ratioCL, CL / s.CLmax);
    }
    // fuselagem
    if (Va > 0.1) {
        const qS = 0.5 * p.env.rho * Va * Va * p.Sref;
        const be = fm.asin(Vr[1] / Va);
        var F = Vr * vec.splat(-0.5 * p.env.rho * Va * p.fus_CDS);
        F[1] += qS * p.fus_CYb * be;
        var M = vec.cross(vec.v3(p.fus_r) - rcg, F);
        M[1] += qS * p.cref * p.fus_Cma * alfa;
        M[2] += qS * p.bref * p.fus_Cnb * be;
        o.Fg[L.group_fuselage] += F;
        o.Mg[L.group_fuselage] += M;
        o.F += F;
        o.M += M;
    }
    return o;
}

/// coeficientes estáticos a α, β (sem rotação), momentos no CG dado
pub fn coeffs(p: *const T.Params, V: f64, alpha: f64, beta: f64, rcg: V3, d: V3) T.AeroCoeffs {
    const a = fm.sincos(alpha);
    const b = fm.sincos(beta);
    const Vr = V3{ V * a.c * b.c, V * b.s, V * a.s * b.c };
    const o = compute(p, Vr, vec.zero, rcg, 50.0, d);
    const qS = 0.5 * p.env.rho * V * V * p.Sref;
    return .{
        .CL = (-o.F[2] * a.c + o.F[0] * a.s) / qS,
        .CD = -(o.F[0] * a.c * b.c + o.F[1] * b.s + o.F[2] * a.s * b.c) / qS,
        .CY = o.F[1] / qS,
        .Cl = o.M[0] / (qS * p.bref),
        .Cm = o.M[1] / (qS * p.cref),
        .Cn = o.M[2] / (qS * p.bref),
        .CL_wing = (-o.Fg[L.group_wing][2] * a.c + o.Fg[L.group_wing][0] * a.s) / qS,
        .CL_ht = (-o.Fg[L.group_htail][2] * a.c + o.Fg[L.group_htail][0] * a.s) / qS,
        .ratioCL = o.ratioCL,
    };
}

const testing = std.testing;

test "painel isolado: CL linear e CLmax" {
    var p = T.Params{};
    p.n_surf = 1;
    p.surf[0] = .{ .S = 1, .c = 0.4, .AR = 6, .CLa = 4.5, .CL0 = 0.3, .CLmax = 1.4, .CD0 = 0.01 };
    init(&p);
    try testing.expectApproxEqAbs(@as(f64, 1.4), peakCL(&p.surf[0], p.Mst), 2e-3);
    const c = coeffs(&p, 15, 0.05, 0, vec.zero, vec.zero);
    try testing.expectApproxEqAbs(@as(f64, 0.3 + 4.5 * 0.05), c.CL, 1e-3);
    try testing.expect(c.CD > 0.01);
}

test "deflexão por mix: elevon" {
    var p = T.Params{};
    p.n_surf = 2;
    p.surf[0] = .{ .r = .{ 0, 0.5, 0 }, .S = 0.5, .c = 0.3, .side = 1, .tau = 0.5, .mix = .{ 1, -1, 0 } };
    p.surf[1] = .{ .r = .{ 0, -0.5, 0 }, .S = 0.5, .c = 0.3, .side = -1, .tau = 0.5, .mix = .{ 1, 1, 0 } };
    init(&p);
    // só aileron: momento de rolamento, sem força líquida extra
    const c = coeffs(&p, 15, 0.0, 0, vec.zero, .{ 0, 0.1, 0 });
    try testing.expect(@abs(c.Cl) > 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0), c.CL, 1e-9);
}

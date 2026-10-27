//! Aerodinâmica por componentes.
//!
//! Cada painel tem centro aerodinâmico, corda e normal próprios. A velocidade local é
//! V_ar + ω × r, então amortecimentos (C_mq, C_lp, C_nr...) e efeitos de diedro e cauda
//! (C_lβ, C_nβ) aparecem sozinhos, sem derivadas de estabilidade prontas.
//!   α_local = atan2(v·ez, v·ex) − downwash + tau (mix · δ)
//!   L = q S CL(α) ⟂ v;  D = q S (CD0 + CL²/(π e AR) φ(h))
//! A fuselagem entra com área de arrasto e C_mα, C_nβ, C_Yβ próprios.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const mods = @import("../modifiers/mod.zig");
const V3 = vec.V3;

/// forças e momentos (corpo): totais, por grupo (asa, EH, EV, fuselagem) e a parte induzida do arrasto
pub const Out = struct {
    F: V3 = vec.zero,
    M: V3 = vec.zero,
    Fg: [limits.n_groups]V3 = [_]V3{vec.zero} ** limits.n_groups,
    Mg: [limits.n_groups]V3 = [_]V3{vec.zero} ** limits.n_groups,
    Fi: V3 = vec.zero, // parte induzida do arrasto
    ratioCL: f64 = 0, // max CL/CLmax nos painéis da asa
};

/// mistura linear / placa plana (Beard e McLain): 0 antes do estol, 1 depois
pub fn sigmaStall(al: f64, a0: f64, steepness: f64) f64 {
    @setFloatMode(fmath.float_mode);
    const e1 = fmath.exp(-steepness * (al - a0));
    const e2 = fmath.exp(steepness * (al + a0));
    return (1.0 + e1 + e2) / ((1.0 + e1) * (1.0 + e2));
}

/// C_L do painel no ângulo `al` com a mistura linear/placa plana
fn clPanel(surface: *const types.Surface, al: f64, steepness: f64) f64 {
    @setFloatMode(fmath.float_mode);
    return clPanelWith(surface, al, sigmaStall(al, surface.a0, steepness), fmath.sincos(al));
}

/// o C_L do painel com a mistura σ e o sincos(α) já calculados (quem chama reaproveita os dois)
inline fn clPanelWith(surface: *const types.Surface, al: f64, sigma: f64, sin_cos: fmath.SinCos) f64 {
    return (1.0 - sigma) * (surface.CL0 + surface.CLa * al) + sigma * 2.0 * fmath.sgn(al) * sin_cos.s * sin_cos.s * sin_cos.c;
}

/// o maior C_L do painel (o C_Lmáx que o a0 dá), por varredura fina em α
fn peakCL(surface: *const types.Surface, steepness: f64) f64 {
    if (fmath.optOn(.peak)) return peakGolden(surface, steepness);
    var pk: f64 = -1e9;
    var al: f64 = 0.0;
    while (al < 0.9) : (al += 2e-4) pk = @max(pk, clPanel(surface, al, steepness));
    return pk;
}

/// o mesmo pico por varredura grossa (passo 0,01) e seção áurea em volta do melhor ponto (só com `-Dopt=peak`)
fn peakGolden(surface: *const types.Surface, steepness: f64) f64 {
    var best: f64 = 0;
    var pk: f64 = -1e9;
    var al: f64 = 0.0;
    while (al < 0.9) : (al += 0.01) {
        const cl = clPanel(surface, al, steepness);
        if (cl > pk) {
            pk = cl;
            best = al;
        }
    }
    const gr = 0.6180339887498949;
    var low = @max(best - 0.01, 0.0);
    var high = @min(best + 0.01, 0.9);
    var x1 = high - gr * (high - low);
    var x2 = low + gr * (high - low);
    var f1 = clPanel(surface, x1, steepness);
    var f2 = clPanel(surface, x2, steepness);
    for (0..40) |_| {
        if (f1 < f2) {
            low = x1;
            x1 = x2;
            f1 = f2;
            x2 = low + gr * (high - low);
            f2 = clPanel(surface, x2, steepness);
        } else {
            high = x2;
            x2 = x1;
            f2 = f1;
            x1 = high - gr * (high - low);
            f1 = clPanel(surface, x1, steepness);
        }
    }
    return @max(pk, @max(f1, f2));
}

/// eixos de cada painel e ângulo de estol a0 que dá o CLmax pedido
pub fn init(params: *types.Params) void {
    const n_surf: usize = @intCast(params.n_surf);
    for (params.surf[0..n_surf]) |*surface| {
        const i = surface.incidence;
        const si = fmath.sincos(i);
        var ex = V3{ si.c, 0, -si.s };
        var ez = V3{ si.s, 0, si.c };
        if (surface.vertical != 0) { // normal para +y; incidência = calagem em guinada
            ex = .{ si.c, -si.s, 0 };
            ez = .{ si.s, si.c, 0 };
        } else { // diedro: gira em x, a normal inclina para dentro
            const ang = -@as(f64, @floatFromInt(surface.side)) * surface.dihedral;
            const roll = fmath.sincos(ang);
            // temporários: `ez = .{..ez..}` escreveria no destino enquanto ainda lê dele
            const ez_r = V3{ ez[0], ez[1] * roll.c - ez[2] * roll.s, ez[1] * roll.s + ez[2] * roll.c };
            const ex_r = V3{ ex[0], ex[1] * roll.c - ex[2] * roll.s, ex[1] * roll.s + ex[2] * roll.c };
            ez = ez_r;
            ex = ex_r;
        }
        surface.ex = ex;
        surface.ez = ez;
        surface.ey = vec.cross(ez, ex);
        var lo: f64 = 0.02;
        var hi: f64 = 0.8;
        for (0..50) |_| {
            surface.a0 = 0.5 * (lo + hi);
            if (peakCL(surface, params.Mst) > surface.CLmax) hi = surface.a0 else lo = surface.a0;
        }
    }
}

/// forças e momentos de todas as faixas e da fuselagem. Vr: velocidade do ponto O em relação ao ar (corpo);
/// body_rates: (p, q, r); rcg: CG atual; height: altura de O; deflections: (δe, δa, δr). Momentos no CG.
pub fn compute(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3) Out {
    return computeEnv(params, Vr, body_rates, rcg, height, deflections, &mods.Env.none);
}

/// `compute` com o que os modificadores precisam do instante (tração e torque de cada motor...)
pub fn computeEnv(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3, env: *const mods.Env) Out {
    return computeImpl(false, params, Vr, body_rates, rcg, height, deflections, env, {});
}

/// `computeEnv` que também devolve o estado de cada painel em `out` (α e velocidade locais, C_L, sustentação)
pub fn computeTrace(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3, env: *const mods.Env, out: []types.PanelState) Out {
    for (out) |*panel| panel.* = .{};
    return computeImpl(true, params, Vr, body_rates, rcg, height, deflections, env, out);
}

/// Γ = ½ V c η C_L de cada painel (Kutta–Joukowski com a carga da faixa, como o k_i de loads/llt.zig), com o α
/// que o laço dos painéis daria sem o par de asas; e a direção para onde o ar vai
fn pairGamma(params: *const types.Params, Vr: V3, body_rates: V3, deflections: V3, env: *mods.Env) void {
    const Va = vec.norm(Vr);
    env.u = if (Va > 1e-6) -Vr / vec.splat(Va) else vec.zero;
    const alfa = fmath.atan2(Vr[2], Vr[0]);
    const n_surf: usize = @intCast(params.n_surf);
    for (params.surf[0..n_surf], 0..) |*surface, i| {
        env.gamma[i] = 0;
        const local = Vr + vec.cross(body_rates, vec.v3(surface.r)) + mods.inducedNoPair(params, env, i, surface);
        const u_local = vec.dot(local, vec.v3(surface.ex));
        const ww = vec.dot(local, vec.v3(surface.ez));
        const V2 = u_local * u_local + ww * ww;
        if (V2 < 1e-6) continue;
        var al = fmath.atan2(ww, u_local);
        if (surface.downwash != 0) al -= surface.eps0 + surface.depsda * alfa;
        al += surface.tau * vec.dot(vec.v3(surface.mix), deflections);
        env.gamma[i] = 0.5 * @sqrt(V2) * surface.c * surface.eta * clPanel(surface, al, params.Mst);
    }
}

/// o laço dos painéis e a fuselagem; com `trace`, escreve o estado de cada painel em `out`
fn computeImpl(comptime trace: bool, params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, height: f64, deflections: V3, env: *const mods.Env, out: if (trace) []types.PanelState else void) Out {
    @setFloatMode(fmath.float_mode);
    var result = Out{};
    const Va = vec.norm(Vr);
    const alfa = fmath.atan2(Vr[2], Vr[0]);
    const n_surf: usize = @intCast(params.n_surf);
    const with_mods = params.n_mod > 0;
    // par de asas ligadas (modifiers/wingpair.zig): as circulações de antes da interferência, numa cópia do Env
    var env_pair: mods.Env = undefined;
    var envp = env;
    if (with_mods and !env.no_pair and mods.wingpair.active(params)) {
        env_pair = env.*;
        pairGamma(params, Vr, body_rates, deflections, &env_pair);
        envp = &env_pair;
    }
    for (params.surf[0..n_surf], 0..) |*surface, i| {
        const position = vec.v3(surface.r);
        const ex = vec.v3(surface.ex);
        const ez = vec.v3(surface.ez);
        var local = Vr + vec.cross(body_rates, position);
        var vind = vec.zero;
        if (with_mods) {
            vind = mods.induced(params, envp, i, surface); // esteira, par de asas, tabela... (modifiers/)
            local += vind;
        }
        const u_local = vec.dot(local, ex);
        const ww = vec.dot(local, ez);
        const V2 = u_local * u_local + ww * ww;
        if (V2 < 1e-6) continue;
        const Vp = @sqrt(V2);
        var al = fmath.atan2(ww, u_local);
        if (surface.downwash != 0) al -= surface.eps0 + surface.depsda * alfa;
        al += surface.tau * vec.dot(vec.v3(surface.mix), deflections);
        // -Dopt=cse: σ e sincos(α) uma vez só (o mesmo valor; sem ele, o compilador não reaproveita as funções do fmath)
        const sg = sigmaStall(al, surface.a0, params.Mst);
        const scl = if (fmath.optOn(.cse)) fmath.sincos(al) else undefined;
        const CL = if (fmath.optOn(.cse)) clPanelWith(surface, al, sg, scl) else clPanel(surface, al, params.Mst);
        var fge: f64 = 1.0;
        if (surface.vertical == 0) fge = mods.ground.factor(params.ground, height - surface.r[2], params.bref); // efeito solo (modifiers/ground.zig)
        const CDi = (1.0 - sg) * CL * CL / (fmath.pi * surface.e * surface.AR) * fge;
        const sa = if (fmath.optOn(.cse)) scl.s else fmath.sin(al);
        const CD = surface.CD0 + CDi + sg * 1.2 * sa * sa;
        const qS = 0.5 * params.env.rho * V2 * surface.eta * surface.S;
        const lift_dir = (ex * vec.splat(ww) - ez * vec.splat(u_local)) / vec.splat(Vp);
        const drag_dir = -(ex * vec.splat(u_local) + ez * vec.splat(ww)) / vec.splat(Vp);
        const force = lift_dir * vec.splat(qS * CL) + drag_dir * vec.splat(qS * CD);
        const Fi = drag_dir * vec.splat(qS * CDi);
        var moment = vec.cross(position - rcg, force) + vec.v3(surface.ey) * vec.splat(qS * surface.c * surface.Cmac);
        if (with_mods) {
            const dcm = mods.flapCm(params, i, surface, deflections); // momento próprio do comando (modifiers/flapmoment.zig)
            if (dcm != 0) moment += vec.v3(surface.ey) * vec.splat(qS * surface.c * dcm);
        }
        if (trace) {
            if (i < out.len) out[i] = .{ .r = surface.r, .S = surface.S, .c = surface.c, .group = surface.group, .side = surface.side, .alpha = al,
                .V = Vp, .CL = CL, .CD = CD, .L = qS * CL, .D = qS * CD, .F = force, .v = local, .vind = vind, .ey = surface.ey, .ex = surface.ex };
        }
        const group: usize = @intCast(surface.group);
        result.Fg[group] += force;
        result.Mg[group] += moment;
        result.F += force;
        result.M += moment;
        result.Fi += Fi;
        if (surface.group == limits.group_wing and surface.CLmax > 0) result.ratioCL = @max(result.ratioCL, CL / surface.CLmax);
    }
    // fuselagem (a mesma conta de `fuselage`, escrita aqui para as faixas ficarem bit a bit iguais: fora da função
    // o compilador reordena as somas no modo de ponto flutuante otimizado)
    if (Va > 0.1) {
        const qS = 0.5 * params.env.rho * Va * Va * params.Sref;
        const be = fmath.asin(Vr[1] / Va);
        var force = Vr * vec.splat(-0.5 * params.env.rho * Va * params.fus_CDS);
        force[1] += qS * params.fus_CYb * be;
        var moment = vec.cross(vec.v3(params.fus_r) - rcg, force);
        moment[1] += qS * params.cref * params.fus_Cma * alfa;
        moment[2] += qS * params.bref * params.fus_Cnb * be;
        result.Fg[limits.group_fuselage] += force;
        result.Mg[limits.group_fuselage] += moment;
        result.F += force;
        result.M += moment;
    }
    return result;
}

/// a fuselagem por coeficientes (área de arrasto, C_Yβ, C_mα, C_nβ), momentos em `rcg`; para Va > 0,1 m/s. Para os
/// modelos que não a têm (a tabela de um método de fora; physics/aeromodel.zig)
pub fn fuselage(params: *const types.Params, Vr: V3, rcg: V3) struct { F: V3, M: V3 } {
    @setFloatMode(fmath.float_mode);
    const Va = vec.norm(Vr);
    const alfa = fmath.atan2(Vr[2], Vr[0]);
    const qS = 0.5 * params.env.rho * Va * Va * params.Sref;
    const be = fmath.asin(Vr[1] / Va);
    var force = Vr * vec.splat(-0.5 * params.env.rho * Va * params.fus_CDS);
    force[1] += qS * params.fus_CYb * be;
    var moment = vec.cross(vec.v3(params.fus_r) - rcg, force);
    moment[1] += qS * params.cref * params.fus_Cma * alfa;
    moment[2] += qS * params.bref * params.fus_Cnb * be;
    return .{ .F = force, .M = moment };
}

/// coeficientes estáticos a α, β (sem rotação), momentos no CG dado
pub fn coeffs(params: *const types.Params, airspeed: f64, alpha: f64, beta: f64, rcg: V3, deflections: V3) types.AeroCoeffs {
    return coeffsEx(params, airspeed, alpha, beta, vec.zero, rcg, deflections);
}

/// coeficientes com rotação body_rates = (p, q, r) em rad/s e momentos no ponto `ref` (eixos do corpo)
pub fn coeffsEx(params: *const types.Params, airspeed: f64, alpha: f64, beta: f64, body_rates: V3, ref: V3, deflections: V3) types.AeroCoeffs {
    return coeffsEnv(params, airspeed, alpha, beta, body_rates, ref, deflections, null);
}

/// `coeffsEx` com a tração e o torque de cada motor (para os modificadores, ex.: esteira); null: sem motores
pub fn coeffsEnv(params: *const types.Params, airspeed: f64, alpha: f64, beta: f64, body_rates: V3, ref: V3, deflections: V3, thrust: ?[2][]const f64) types.AeroCoeffs {
    return coeffsAt(params, airspeed, alpha, beta, body_rates, ref, deflections, 50.0, thrust);
}

/// `coeffsEnv` com a altura `height` do avião sobre o chão (m) para o efeito solo (`coeffsEnv`: 50 m, longe do chão)
pub fn coeffsAt(params: *const types.Params, airspeed: f64, alpha: f64, beta: f64, body_rates: V3, ref: V3, deflections: V3, height: f64, thrust: ?[2][]const f64) types.AeroCoeffs {
    const sc_alpha = fmath.sincos(alpha);
    const sc_beta = fmath.sincos(beta);
    const Vr = V3{ airspeed * sc_alpha.c * sc_beta.c, airspeed * sc_beta.s, airspeed * sc_alpha.s * sc_beta.c };
    const env = if (thrust) |tq| mods.envFrom(params, Vr, body_rates, tq[0], tq[1]) else mods.Env.none;
    const out = computeEnv(params, Vr, body_rates, ref, height, deflections, &env);
    const qS = 0.5 * params.env.rho * airspeed * airspeed * params.Sref;
    return .{
        .CL = (-out.F[2] * sc_alpha.c + out.F[0] * sc_alpha.s) / qS,
        .CD = -(out.F[0] * sc_alpha.c * sc_beta.c + out.F[1] * sc_beta.s + out.F[2] * sc_alpha.s * sc_beta.c) / qS,
        .CY = out.F[1] / qS,
        .Cl = out.M[0] / (qS * params.bref),
        .Cm = out.M[1] / (qS * params.cref),
        .Cn = out.M[2] / (qS * params.bref),
        .CL_wing = (-out.Fg[limits.group_wing][2] * sc_alpha.c + out.Fg[limits.group_wing][0] * sc_alpha.s) / qS,
        .CL_ht = (-out.Fg[limits.group_htail][2] * sc_alpha.c + out.Fg[limits.group_htail][0] * sc_alpha.s) / qS,
        .ratioCL = out.ratioCL,
        .CDi = -(out.Fi[0] * sc_alpha.c * sc_beta.c + out.Fi[1] * sc_beta.s + out.Fi[2] * sc_alpha.s * sc_beta.c) / qS,
        .CN = -out.F[2] / qS,
    };
}

const testing = std.testing;

test "painel isolado: CL linear e CLmax" {
    var params = types.Params{};
    params.n_surf = 1;
    params.surf[0] = .{ .S = 1, .c = 0.4, .AR = 6, .CLa = 4.5, .CL0 = 0.3, .CLmax = 1.4, .CD0 = 0.01 };
    init(&params);
    try testing.expectApproxEqAbs(@as(f64, 1.4), peakCL(&params.surf[0], params.Mst), 2e-3);
    const coefs = coeffs(&params, 15, 0.05, 0, vec.zero, vec.zero);
    try testing.expectApproxEqAbs(@as(f64, 0.3 + 4.5 * 0.05), coefs.CL, 1e-3);
    try testing.expect(coefs.CD > 0.01);
}

test "deflexão por mix: elevon" {
    var params = types.Params{};
    params.n_surf = 2;
    params.surf[0] = .{ .r = .{ 0, 0.5, 0 }, .S = 0.5, .c = 0.3, .side = 1, .tau = 0.5, .mix = .{ 1, -1, 0 } };
    params.surf[1] = .{ .r = .{ 0, -0.5, 0 }, .S = 0.5, .c = 0.3, .side = -1, .tau = 0.5, .mix = .{ 1, 1, 0 } };
    init(&params);
    // só aileron: momento de rolamento, sem força líquida extra
    const coefs = coeffs(&params, 15, 0.0, 0, vec.zero, .{ 0, 0.1, 0 });
    try testing.expect(@abs(coefs.Cl) > 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0), coefs.CL, 1e-9);
}

test "rolamento amortecido e transporte de momento" {
    var params = types.Params{};
    params.n_surf = 2;
    params.surf[0] = .{ .r = .{ 0, 0.5, 0 }, .S = 0.5, .c = 0.3, .side = 1, .CLa = 4.5, .CLmax = 1.4 };
    params.surf[1] = .{ .r = .{ 0, -0.5, 0 }, .S = 0.5, .c = 0.3, .side = -1, .CLa = 4.5, .CLmax = 1.4 };
    init(&params);
    const c0 = coeffsEx(&params, 15, 0.05, 0, vec.zero, vec.zero, vec.zero);
    const cp = coeffsEx(&params, 15, 0.05, 0, .{ 0.5, 0, 0 }, vec.zero, vec.zero);
    try testing.expect(cp.Cl < c0.Cl - 1e-3); // C_lp < 0
    // momento num ponto 0,1 m atrás: Cm' = Cm + CN · 0,1 / c
    const cr = coeffsEx(&params, 15, 0.05, 0, vec.zero, .{ -0.1, 0, 0 }, vec.zero);
    try testing.expectApproxEqAbs(c0.Cm + c0.CN * (-0.1 - 0.0) / params.cref * -1.0, cr.Cm, 1e-9);
}

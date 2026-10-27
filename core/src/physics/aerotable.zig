//! Modelo aerodinâmico por tabela (Params.aero_model = 2): os coeficientes do avião inteiro vêm de `Params.aero_tab`,
//! montada por qualquer método (VLM, AVL, lltdrek, o próprio núcleo...; `aerosim/aero/flight_table.py`).
//!
//! Por instante, com α = atan2(w, u), β = asin(v / V) e as taxas adimensionais p̂ = p b/2V, q̂ = q c/2V, r̂ = r b/2V:
//!     C_L = C_L(α) + C_Lq q̂ + C_Lδe δe              C_D = C_D(α)              C_m = C_m(α) + C_mq q̂ + C_mδe δe
//!     C_Y = C_Yβ β + C_Yp p̂ + C_Yr r̂ + C_Yδr δr
//!     C_l = C_lβ β + C_lp p̂ + C_lr r̂ + C_lδa δa + C_lδr δr
//!     C_n = C_nβ β + C_np p̂ + C_nr r̂ + C_nδa δa + C_nδr δr
//! C_L(α), C_D(α), C_m(α): interpolação linear na tabela (fora dela, o valor da ponta). É o modelo linear de derivadas
//! de estabilidade (Etkin e Reid, "Dynamics of Flight", cap. 5 — a conferir no PDF) com a parte longitudinal estática
//! tabelada em α. Não tem efeito solo nem esteira (a tabela é de voo livre); a fuselagem entra pelo núcleo se a tabela
//! não a tem (`fus` = 0).
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const aero = @import("aero.zig");
const V3 = vec.V3;

/// `ys` interpolado linearmente em `value` sobre `xs` (crescente); fora da faixa, o valor da ponta
fn interp(xs: []const f64, ys: []const f64, value: f64) f64 {
    const count = xs.len;
    if (count == 0) return 0;
    if (value <= xs[0]) return ys[0];
    if (value >= xs[count - 1]) return ys[count - 1];
    var i: usize = 1;
    while (i < count - 1 and xs[i] < value) : (i += 1) {}
    const fraction = (value - xs[i - 1]) / (xs[i] - xs[i - 1]);
    return ys[i - 1] + fraction * (ys[i] - ys[i - 1]);
}

/// os coeficientes da tabela num estado (os mesmos eixos de `aero.coeffsAt`)
pub fn coeffs(table: *const types.AeroTable, params: *const types.Params, airspeed: f64, alpha: f64, beta: f64, body_rates: V3, deflections: V3) [6]f64 {
    const count: usize = @intCast(@max(@min(table.n, @as(i32, limits.max_tab)), 0));
    const ph = body_rates[0] * params.bref / (2 * airspeed);
    const qh = body_rates[1] * params.cref / (2 * airspeed);
    const rh = body_rates[2] * params.bref / (2 * airspeed);
    const CL = interp(table.alpha[0..count], table.CL[0..count], alpha) + table.CLq * qh + table.CLde * deflections[0];
    const CD = interp(table.alpha[0..count], table.CD[0..count], alpha);
    const Cm = interp(table.alpha[0..count], table.Cm[0..count], alpha) + table.Cmq * qh + table.Cmde * deflections[0];
    const CY = table.CYb * beta + table.CYp * ph + table.CYr * rh + table.CYdr * deflections[2];
    const Cl = table.Clb * beta + table.Clp * ph + table.Clr * rh + table.Clda * deflections[1] + table.Cldr * deflections[2];
    const Cn = table.Cnb * beta + table.Cnp * ph + table.Cnr * rh + table.Cnda * deflections[1] + table.Cndr * deflections[2];
    return .{ CL, CD, CY, Cl, Cm, Cn };
}

/// forças e momentos do avião pela tabela (`aero.Out`, momentos em `rcg`; comandos `deflections` = δe, δa, δr em rad). A força sai dos coeficientes pelas mesmas
/// definições de `aero.coeffsAt`: C_L = (−F_z cos α + F_x sen α)/qS, C_D = −F·V̂/qS, C_Y = F_y/qS
pub fn compute(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, deflections: V3) aero.Out {
    const airspeed = vec.norm(Vr);
    if (airspeed < 0.1) return aero.Out{};
    return computeCmd(params, Vr, body_rates, rcg, fmath.atan2(Vr[2], Vr[0]), fmath.asin(Vr[1] / airspeed), airspeed, &params.aero_tab, deflections);
}

/// `compute` com α, β e V já calculados
fn computeCmd(params: *const types.Params, Vr: V3, body_rates: V3, rcg: V3, alpha: f64, beta: f64, airspeed: f64, table: *const types.AeroTable, deflections: V3) aero.Out {
    _ = Vr;
    var out = aero.Out{};
    const coefs = coeffs(table, params, airspeed, alpha, beta, body_rates, deflections);
    const qS = 0.5 * params.env.rho * airspeed * airspeed * params.Sref;
    const sc_alpha = fmath.sincos(alpha);
    const sc_beta = fmath.sincos(beta);
    const Fy = coefs[2] * qS;
    // −F_z cos α + F_x sen α = C_L qS;  −(F_x cos α cos β + F_y sen β + F_z sen α cos β) = C_D qS
    const lift = coefs[0] * qS;
    const drag_part = -coefs[1] * qS - Fy * sc_beta.s;
    // F_x = A sen α + (B / cos β) cos α;  F_z = −A cos α + (B / cos β) sen α
    const Bc = drag_part / @max(sc_beta.c, 1e-9);
    const force = V3{ lift * sc_alpha.s + Bc * sc_alpha.c, Fy, -lift * sc_alpha.c + Bc * sc_alpha.s };
    const Mref = V3{ coefs[3] * qS * params.bref, coefs[4] * qS * params.cref, coefs[5] * qS * params.bref };
    const moment = Mref + vec.cross(vec.v3(table.ref) - rcg, force);
    out.F = force;
    out.M = moment;
    // C_L / C_Lmáx: o maior C_L da própria tabela faz o papel do C_Lmáx (a tabela não tem o das faixas)
    const count: usize = @intCast(@max(@min(table.n, @as(i32, limits.max_tab)), 0));
    var CLmax: f64 = 0;
    for (table.CL[0..count]) |value| CLmax = @max(CLmax, value);
    if (CLmax > 0) out.ratioCL = coefs[0] / CLmax;
    out.Fg[limits.group_wing] = force; // a tabela não separa as superfícies
    out.Mg[limits.group_wing] = moment;
    return out;
}

const testing = std.testing;

test "tabela: os coeficientes voltam pelas definições de aero.coeffsAt" {
    var params = types.Params{};
    params.Sref = 0.5;
    params.cref = 0.25;
    params.bref = 2.0;
    params.aero_tab.n = 3;
    params.aero_tab.alpha[0..3].* = .{ -0.1, 0.0, 0.2 };
    params.aero_tab.CL[0..3].* = .{ -0.3, 0.2, 1.2 };
    params.aero_tab.CD[0..3].* = .{ 0.03, 0.02, 0.08 };
    params.aero_tab.Cm[0..3].* = .{ 0.05, 0.0, -0.1 };
    params.aero_tab.CYb = -0.3;
    params.aero_tab.Clb = -0.05;
    const airspeed = 12.0;
    const al = 0.1;
    const be = 0.05;
    const Vr = V3{ airspeed * @cos(al) * @cos(be), airspeed * @sin(be), airspeed * @sin(al) * @cos(be) };
    const out = computeCmd(&params, Vr, vec.zero, vec.zero, al, be, airspeed, &params.aero_tab, vec.zero);
    const qS = 0.5 * params.env.rho * airspeed * airspeed * params.Sref;
    const sc_alpha = fmath.sincos(al);
    const sc_beta = fmath.sincos(be);
    try testing.expectApproxEqAbs(@as(f64, 0.7), (-out.F[2] * sc_alpha.c + out.F[0] * sc_alpha.s) / qS, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.05), -(out.F[0] * sc_alpha.c * sc_beta.c + out.F[1] * sc_beta.s + out.F[2] * sc_alpha.s * sc_beta.c) / qS, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.015), out.F[1] / qS, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.05), out.M[1] / (qS * params.cref), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.0025), out.M[0] / (qS * params.bref), 1e-12);
}

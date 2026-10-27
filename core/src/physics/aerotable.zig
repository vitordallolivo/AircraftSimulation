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

/// interpolação linear em `xs` (crescente, n pontos); fora, o valor da ponta
fn interp(xs: []const f64, ys: []const f64, x: f64) f64 {
    const n = xs.len;
    if (n == 0) return 0;
    if (x <= xs[0]) return ys[0];
    if (x >= xs[n - 1]) return ys[n - 1];
    var i: usize = 1;
    while (i < n - 1 and xs[i] < x) : (i += 1) {}
    const t = (x - xs[i - 1]) / (xs[i] - xs[i - 1]);
    return ys[i - 1] + t * (ys[i] - ys[i - 1]);
}

/// os coeficientes da tabela num estado (os mesmos eixos de `aero.coeffsAt`)
pub fn coeffs(tb: *const types.AeroTable, p: *const types.Params, V: f64, alpha: f64, beta: f64, w: V3, d: V3) [6]f64 {
    const n: usize = @intCast(@max(@min(tb.n, @as(i32, limits.max_tab)), 0));
    const ph = w[0] * p.bref / (2 * V);
    const qh = w[1] * p.cref / (2 * V);
    const rh = w[2] * p.bref / (2 * V);
    const CL = interp(tb.alpha[0..n], tb.CL[0..n], alpha) + tb.CLq * qh + tb.CLde * d[0];
    const CD = interp(tb.alpha[0..n], tb.CD[0..n], alpha);
    const Cm = interp(tb.alpha[0..n], tb.Cm[0..n], alpha) + tb.Cmq * qh + tb.Cmde * d[0];
    const CY = tb.CYb * beta + tb.CYp * ph + tb.CYr * rh + tb.CYdr * d[2];
    const Cl = tb.Clb * beta + tb.Clp * ph + tb.Clr * rh + tb.Clda * d[1] + tb.Cldr * d[2];
    const Cn = tb.Cnb * beta + tb.Cnp * ph + tb.Cnr * rh + tb.Cnda * d[1] + tb.Cndr * d[2];
    return .{ CL, CD, CY, Cl, Cm, Cn };
}

/// forças e momentos do avião pela tabela (`aero.Out`, momentos em `rcg`; comandos `d` = δe, δa, δr em rad). A força sai dos coeficientes pelas mesmas
/// definições de `aero.coeffsAt`: C_L = (−F_z cos α + F_x sen α)/qS, C_D = −F·V̂/qS, C_Y = F_y/qS
pub fn compute(p: *const types.Params, Vr: V3, w: V3, rcg: V3, d: V3) aero.Out {
    const V = vec.norm(Vr);
    if (V < 0.1) return aero.Out{};
    return computeCmd(p, Vr, w, rcg, fmath.atan2(Vr[2], Vr[0]), fmath.asin(Vr[1] / V), V, &p.aero_tab, d);
}

/// `compute` com α, β e V já calculados
fn computeCmd(p: *const types.Params, Vr: V3, w: V3, rcg: V3, alpha: f64, beta: f64, V: f64, tb: *const types.AeroTable, d: V3) aero.Out {
    _ = Vr;
    var o = aero.Out{};
    const c = coeffs(tb, p, V, alpha, beta, w, d);
    const qS = 0.5 * p.env.rho * V * V * p.Sref;
    const a = fmath.sincos(alpha);
    const b = fmath.sincos(beta);
    const Fy = c[2] * qS;
    // −F_z cos α + F_x sen α = C_L qS;  −(F_x cos α cos β + F_y sen β + F_z sen α cos β) = C_D qS
    const A = c[0] * qS;
    const B = -c[1] * qS - Fy * b.s;
    // F_x = A sen α + (B / cos β) cos α;  F_z = −A cos α + (B / cos β) sen α
    const Bc = B / @max(b.c, 1e-9);
    const F = V3{ A * a.s + Bc * a.c, Fy, -A * a.c + Bc * a.s };
    const Mref = V3{ c[3] * qS * p.bref, c[4] * qS * p.cref, c[5] * qS * p.bref };
    const M = Mref + vec.cross(vec.v3(tb.ref) - rcg, F);
    o.F = F;
    o.M = M;
    // C_L / C_Lmáx: o maior C_L da própria tabela faz o papel do C_Lmáx (a tabela não tem o das faixas)
    const n: usize = @intCast(@max(@min(tb.n, @as(i32, limits.max_tab)), 0));
    var CLmax: f64 = 0;
    for (tb.CL[0..n]) |x| CLmax = @max(CLmax, x);
    if (CLmax > 0) o.ratioCL = c[0] / CLmax;
    o.Fg[limits.group_wing] = F; // a tabela não separa as superfícies
    o.Mg[limits.group_wing] = M;
    return o;
}

const testing = std.testing;

test "tabela: os coeficientes voltam pelas definições de aero.coeffsAt" {
    var p = types.Params{};
    p.Sref = 0.5;
    p.cref = 0.25;
    p.bref = 2.0;
    p.aero_tab.n = 3;
    p.aero_tab.alpha[0..3].* = .{ -0.1, 0.0, 0.2 };
    p.aero_tab.CL[0..3].* = .{ -0.3, 0.2, 1.2 };
    p.aero_tab.CD[0..3].* = .{ 0.03, 0.02, 0.08 };
    p.aero_tab.Cm[0..3].* = .{ 0.05, 0.0, -0.1 };
    p.aero_tab.CYb = -0.3;
    p.aero_tab.Clb = -0.05;
    const V = 12.0;
    const al = 0.1;
    const be = 0.05;
    const Vr = V3{ V * @cos(al) * @cos(be), V * @sin(be), V * @sin(al) * @cos(be) };
    const o = computeCmd(&p, Vr, vec.zero, vec.zero, al, be, V, &p.aero_tab, vec.zero);
    const qS = 0.5 * p.env.rho * V * V * p.Sref;
    const a = fmath.sincos(al);
    const b = fmath.sincos(be);
    try testing.expectApproxEqAbs(@as(f64, 0.7), (-o.F[2] * a.c + o.F[0] * a.s) / qS, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.05), -(o.F[0] * a.c * b.c + o.F[1] * b.s + o.F[2] * a.s * b.c) / qS, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.015), o.F[1] / qS, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.05), o.M[1] / (qS * p.cref), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.0025), o.M[0] / (qS * p.bref), 1e-12);
}

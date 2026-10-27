//! K unidades propulsoras: hélice por tabela C_T(J), C_P(J) + motor BLDC + bateria.
//!
//!   J = V_p / (n D),  V_p = (V_ar + ω × r_p) · e_T
//!   T = C_T ρ n² D⁴,  Q = C_P/(2π) ρ n² D⁵
//!   I = (u V_oc − K_e ω) / (R_m + u² R_int)      (u: acelerador)
//!   (J_m + I_p) 2π dn/dt = K_e I − B ω − τ_c − Q
//! Força T e_T no cubo; momento r × F − sentido Q e_T; giroscópico −ω × H.
const std = @import("std");
const limits = @import("../limits.zig");
const types = @import("../types.zig");
const fmath = @import("../math/fmath.zig");
const vec = @import("../math/vec.zig");
const V3 = vec.V3;

pub const Unit = struct {
    T: f64 = 0,
    Q: f64 = 0,
    J: f64 = 0,
    I: f64 = 0,
    Ibat: f64 = 0,
    Vbus: f64 = 0,
    P: f64 = 0,
    drps: f64 = 0,
};

pub const Out = struct {
    F: V3 = vec.zero,
    M: V3 = vec.zero,
    Mgyro: V3 = vec.zero,
    T: f64 = 0,
    Q: f64 = 0,
    P: f64 = 0,
    Ibat: f64 = 0,
    Vbus: f64 = 0,
    T_sin: f64 = 0, // Σ T_i sin(θ + tilt_i), para as reações do artigo
    u: [limits.max_props]Unit = undefined, // só as n_prop primeiras são escritas e lidas
};

pub fn init(p: *types.Params) void {
    const n: usize = @intCast(p.n_prop);
    for (p.prop[0..n]) |*u| {
        const a = fmath.sincos(u.tilt);
        const b = fmath.sincos(u.toe);
        u.eT = .{ a.c * b.c, a.c * b.s, -a.s };
        u.D4 = u.D * u.D * u.D * u.D;
        u.D5 = u.D4 * u.D;
        u.Ke = 60.0 / (2.0 * fmath.pi * u.Kv);
    }
}

/// interpolação linear na tabela (busca binária: tabela monotônica em J)
fn coef(u: *const types.PropUnit, J: f64, CT: *f64, CP: *f64) void {
    @setFloatMode(fmath.float_mode);
    const n: usize = @intCast(u.n_pts);
    if (n < 2) {
        CT.* = 0;
        CP.* = 0.002;
        return;
    }
    if (J <= u.J[0]) {
        CT.* = u.CT[0];
        CP.* = u.CP[0];
        return;
    }
    var lo: usize = 0;
    var hi: usize = n - 1;
    if (J >= u.J[hi]) {
        lo = hi - 1;
    } else while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (u.J[mid] < J) lo = mid else hi = mid;
    }
    const i = lo + 1;
    const f = (J - u.J[i - 1]) / (u.J[i] - u.J[i - 1]);
    CT.* = u.CT[i - 1] + f * (u.CT[i] - u.CT[i - 1]);
    CP.* = @max(0.002, u.CP[i - 1] + f * (u.CP[i] - u.CP[i - 1]));
}

fn polyVar(code: i32, c: f64, V: f64, thr: f64, h: f64, rho: f64) f64 {
    return switch (code) {
        types.pvar_V => V,
        types.pvar_throttle => thr,
        types.pvar_h => h,
        types.pvar_rho => rho,
        types.pvar_const => c,
        else => 0.0,
    };
}

inline fn clampRange(v: f64, vmax: f64) f64 {
    return if (vmax > 0) fmath.lim(v, 0.0, vmax) else v;
}

/// valor do polinômio sem o corte em T ≥ 0 (o envelope "como na planilha" usa assim)
pub fn polyRaw(p: *const types.Params, u: *const types.PropUnit, V: f64, thr: f64, h: f64) f64 {
    const rho = p.env.rho;
    const x = clampRange(polyVar(u.poly_x, u.poly_xc, V, thr, h, rho), u.poly_xmax);
    const y = clampRange(polyVar(u.poly_y, u.poly_yc, V, thr, h, rho), u.poly_ymax);
    var Tp = u.poly_gain * types.ThrustPoly.eval(&u.poly, x, y);
    if (u.poly_rho_exp != 0) Tp *= fmath.pow(rho / u.poly_rho0, u.poly_rho_exp);
    if (u.poly_x != types.pvar_throttle and u.poly_y != types.pvar_throttle) Tp *= thr;
    return Tp;
}

/// tração polinomial (sem motor, bateria nem rotação)
fn polyUnit(p: *const types.Params, u: *const types.PropUnit, eT: V3, Vr: V3, w: V3, thr: f64, h: f64) Unit {
    const V = vec.dot(Vr + vec.cross(w, vec.v3(u.r)), eT);
    return .{ .T = @max(polyRaw(p, u, V, thr, h), 0.0) };
}

/// inclinação atual do eixo (rad): fixa, ou tilt + comando·tilt_range no eixo móvel
pub fn tiltNow(p: *const types.Params, u: *const types.PropUnit) f64 {
    if (u.tilt_range == 0) return u.tilt;
    const c = if (std.math.isFinite(p.pilot.tilt)) fmath.lim(p.pilot.tilt, 0.0, 1.0) else 0.0;
    return u.tilt + c * u.tilt_range;
}

/// eixo de tração atual (corpo)
pub fn axis(p: *const types.Params, u: *const types.PropUnit) V3 {
    if (u.tilt_range == 0) return vec.v3(u.eT);
    const a = fmath.sincos(tiltNow(p, u));
    const b = fmath.sincos(u.toe);
    return .{ a.c * b.c, a.c * b.s, -a.s };
}

pub fn unit(p: *const types.Params, u: *const types.PropUnit, eT: V3, Vr: V3, w: V3, rps: f64, thr: f64, h: f64) Unit {
    @setFloatMode(fmath.float_mode);
    if (u.model == types.prop_poly) return polyUnit(p, u, eT, Vr, w, thr, h);
    var o = Unit{};
    const n = if (rps > 1.0) rps else 1.0;
    const wm = 2.0 * fmath.pi * n;
    const v = Vr + vec.cross(w, vec.v3(u.r));
    o.J = vec.dot(v, eT) / (n * u.D);
    var CT: f64 = 0;
    var CP: f64 = 0;
    coef(u, o.J, &CT, &CP);
    const rn2 = p.env.rho * n * n;
    o.T = CT * rn2 * u.D4;
    o.Q = CP / (2.0 * fmath.pi) * rn2 * u.D5;
    o.I = fmath.lim((thr * u.Voc - u.Ke * wm) / (u.Rm + thr * thr * u.Rint), 0.0, u.Imax);
    o.Ibat = thr * o.I;
    o.Vbus = u.Voc - u.Rint * o.Ibat;
    o.P = o.Vbus * o.Ibat;
    o.drps = (u.Ke * o.I - u.B * wm - u.tauc - o.Q) / (2.0 * fmath.pi * (u.Jm + u.Ip));
    return o;
}

/// rps: rotação de cada unidade (vem do vetor de estados); dr: leme (acelerador diferencial)
pub fn compute(p: *const types.Params, Vr: V3, w: V3, rcg: V3, rps: []const f64, thr: f64, dr: f64, theta: f64, h: f64) Out {
    // campo a campo: `Out{}` zeraria as 8 unidades (~600 B) a cada chamada
    var o: Out = undefined;
    o.F = vec.zero;
    o.M = vec.zero;
    o.Mgyro = vec.zero;
    o.T = 0;
    o.Q = 0;
    o.P = 0;
    o.Ibat = 0;
    o.Vbus = 0;
    o.T_sin = 0;
    const n: usize = @intCast(p.n_prop);
    for (p.prop[0..n], 0..) |*u, i| {
        // o piloto já limita thr a [0, 1]; aqui só a mistura de guinada é limitada. A trimagem pode
        // pedir thr > 1 ("precisa de mais que o máximo"), como no simulador original.
        const th = fmath.lim(thr + u.yaw_mix * dr, 0.0, @max(1.0, thr));
        const eT = axis(p, u);
        const r = unit(p, u, eT, Vr, w, rps[i], th, h);
        o.u[i] = r;
        const F = eT * vec.splat(r.T);
        o.F += F;
        o.M += vec.cross(vec.v3(u.r) - rcg, F) - eT * vec.splat(u.sense * r.Q);
        const wm = 2.0 * fmath.pi * @max(rps[i], 1.0);
        const H = eT * vec.splat(u.sense * (u.Ip + u.Jm) * wm);
        o.Mgyro -= vec.cross(w, H);
        o.T += r.T;
        o.Q += r.Q;
        o.P += r.P;
        o.Ibat += r.Ibat;
        o.Vbus = if (i == 0) r.Vbus else @min(o.Vbus, r.Vbus);
        o.T_sin += r.T * fmath.sin(theta + tiltNow(p, u));
    }
    return o;
}

/// rotação de equilíbrio (dn/dt = 0), sem rotação do avião. dn/dt cai com n, então a raiz é
/// única em [1, 600] rps: regula falsi com a modificação de Illinois (converge em ~10 passos).
pub fn equilibriumRps(p: *const types.Params, u: *const types.PropUnit, Vr: V3, thr: f64) f64 {
    @setFloatMode(fmath.float_mode);
    if (u.model == types.prop_poly) return 1.0;
    var a: f64 = 1.0;
    var b: f64 = 600.0;
    var fa = unit(p, u, vec.v3(u.eT), Vr, vec.zero, a, thr, 0).drps;
    if (fa <= 0.0) return a;
    var fb = unit(p, u, vec.v3(u.eT), Vr, vec.zero, b, thr, 0).drps;
    if (fb >= 0.0) return b;
    var side: i32 = 0;
    for (0..80) |_| {
        const c = (a * fb - b * fa) / (fb - fa);
        const fc = unit(p, u, vec.v3(u.eT), Vr, vec.zero, c, thr, 0).drps;
        if (@abs(fc) < 1e-9 or b - a < 1e-10 * b) return c;
        if ((fc > 0) == (fa > 0)) {
            a = c;
            fa = fc;
            if (side == -1) fb *= 0.5;
            side = -1;
        } else {
            b = c;
            fb = fc;
            if (side == 1) fa *= 0.5;
            side = 1;
        }
    }
    return 0.5 * (a + b);
}

/// ponto de operação em voo axial a V (curva de tração)
pub fn point(p: *const types.Params, u: *const types.PropUnit, V: f64, thr: f64) types.PropPoint {
    const Vr = vec.v3(u.eT) * vec.splat(V);
    const n = equilibriumRps(p, u, Vr, thr);
    const r = unit(p, u, vec.v3(u.eT), Vr, vec.zero, n, thr, 0);
    const Ps = r.Q * 2.0 * fmath.pi * n;
    return .{
        .V = V,
        .rpm = n * 60.0,
        .J = r.J,
        .T = r.T,
        .Q = r.Q,
        .P_shaft = Ps,
        .P_elec = r.P,
        .I = r.I,
        .eta_prop = if (Ps > 1e-6) r.T * V / Ps else 0,
    };
}

const testing = std.testing;

test "rotação de equilíbrio: dn/dt ≈ 0" {
    var p = types.Params{};
    p.n_prop = 1;
    var u = &p.prop[0];
    u.* = .{ .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035, .n_pts = 2 };
    u.J[1] = 0.68;
    u.CT[0] = 0.09;
    u.CP[0] = 0.03;
    u.CP[1] = 0.006;
    init(&p);
    inline for (.{ 0.3, 0.7, 1.0 }) |thr| {
        const n = equilibriumRps(&p, &p.prop[0], .{ 12, 0, 0 }, thr);
        try testing.expect(@abs(unit(&p, &p.prop[0], vec.v3(p.prop[0].eT), .{ 12, 0, 0 }, vec.zero, n, thr, 0).drps) < 1e-6);
    }
}

test "eixo móvel: comando 0 = eixo fixo; comando 1 = tilt + faixa" {
    var p = types.Params{};
    p.n_prop = 1;
    p.prop[0] = .{ .tilt = 0.05, .tilt_range = std.math.pi / 2.0 - 0.05, .model = types.prop_poly, .poly_x = types.pvar_const, .poly_gain = 1 };
    p.prop[0].poly[0] = 10;
    init(&p);
    const fixed = axis(&p, &p.prop[0]);
    try testing.expectApproxEqAbs(fmath.cos(0.05), fixed[0], 1e-12);
    p.pilot.tilt = 1; // eixo na vertical: a tração vira sustentação (−z)
    const up = axis(&p, &p.prop[0]);
    try testing.expectApproxEqAbs(@as(f64, 0), up[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), up[2], 1e-12);
    var rps = [_]f64{0} ** limits.max_props;
    const o = compute(&p, .{ 0, 0, 0 }, vec.zero, vec.zero, &rps, 1.0, 0, 0, 0);
    try testing.expectApproxEqAbs(@as(f64, -10), o.F[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), o.F[0], 1e-9);
}

test "tração estática e queda com V" {
    var p = types.Params{};
    p.n_prop = 1;
    var u = &p.prop[0];
    u.* = .{ .D = 0.381, .Ip = 5.4e-4, .Jm = 1e-4, .Kv = 310, .Rm = 0.0204, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80, .Voc = 22.2, .Rint = 0.035, .n_pts = 3 };
    u.J[0] = 0;
    u.J[1] = 0.35;
    u.J[2] = 0.68;
    u.CT[0] = 0.09;
    u.CT[1] = 0.055;
    u.CT[2] = 0.0;
    u.CP[0] = 0.03;
    u.CP[1] = 0.03;
    u.CP[2] = 0.006;
    init(&p);
    const a = point(&p, &p.prop[0], 0.0, 1.0);
    const b = point(&p, &p.prop[0], 15.0, 1.0);
    try testing.expect(a.T > 20 and a.T < 80);
    try testing.expect(b.T < a.T);
}

test "tração polinomial: T(V) com acelerador e correção de densidade" {
    var p = types.Params{};
    p.n_prop = 1;
    var u = &p.prop[0];
    u.* = .{ .model = types.prop_poly, .poly_x = types.pvar_V, .poly_y = types.pvar_none };
    u.poly[0] = 30; // p00
    u.poly[1] = -1; // p10 · V
    u.poly[3] = -0.02; // p20 · V²
    init(&p);
    const a = point(&p, &p.prop[0], 10.0, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 30 - 10 - 2), a.T, 1e-9);
    const b = point(&p, &p.prop[0], 10.0, 0.5);
    try testing.expectApproxEqAbs(a.T * 0.5, b.T, 1e-9);
    u.poly_rho_exp = 1.0;
    p.env.rho = 0.6125;
    try testing.expectApproxEqAbs(a.T * 0.5, point(&p, &p.prop[0], 10.0, 1.0).T, 1e-9);
    // fora da faixa do ajuste não fica negativa
    try testing.expectEqual(@as(f64, 0), point(&p, &p.prop[0], 100.0, 1.0).T);
}

test "tração como na planilha: x = n constante, y = V, T0 no lugar de p00, g·ρ/ρ0" {
    var p = types.Params{};
    p.n_prop = 1;
    var u = &p.prop[0];
    u.* = .{ .model = types.prop_poly, .poly_x = types.pvar_const, .poly_xc = 2.0, .poly_y = types.pvar_V, .poly_gain = limits.g0, .poly_rho_exp = 1.0, .poly_rho0 = 1.225 };
    u.poly[0] = 3.0; // T0
    u.poly[1] = 0.1; // p10 · n
    u.poly[2] = -0.05; // p01 · V
    u.poly[4] = 0.01; // p11 · n V
    init(&p);
    p.env.rho = 1.1;
    const V = 8.0;
    const want = limits.g0 * (1.1 / 1.225) * (3.0 + 0.1 * 2.0 - 0.05 * V + 0.01 * 2.0 * V);
    try testing.expectApproxEqAbs(want, point(&p, &p.prop[0], V, 1.0).T, 1e-9);
}

test "tração polinomial com o acelerador como variável y" {
    var p = types.Params{};
    p.n_prop = 1;
    var u = &p.prop[0];
    u.* = .{ .model = types.prop_poly, .poly_x = types.pvar_V, .poly_y = types.pvar_throttle };
    u.poly[2] = 20; // p01 · thr
    init(&p);
    try testing.expectApproxEqAbs(@as(f64, 14), point(&p, &p.prop[0], 5.0, 0.7).T, 1e-9);
}

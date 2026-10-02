//! K unidades propulsoras: hélice por tabela C_T(J), C_P(J) + motor BLDC + bateria.
//!
//!   J = V_p / (n D),  V_p = (V_ar + ω × r_p) · e_T
//!   T = C_T ρ n² D⁴,  Q = C_P/(2π) ρ n² D⁵
//!   I = (u V_oc − K_e ω) / (R_m + u² R_int)      (u: acelerador)
//!   (J_m + I_p) 2π dn/dt = K_e I − B ω − τ_c − Q
//! Força T e_T no cubo; momento r × F − sentido Q e_T; giroscópico −ω × H.
const std = @import("std");
const L = @import("../limits.zig");
const T = @import("../types.zig");
const fm = @import("../math/fmath.zig");
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
    u: [L.max_props]Unit = [_]Unit{.{}} ** L.max_props,
};

pub fn init(p: *T.Params) void {
    const n: usize = @intCast(p.n_prop);
    for (p.prop[0..n]) |*u| {
        const a = fm.sincos(u.tilt);
        const b = fm.sincos(u.toe);
        u.eT = .{ a.c * b.c, a.c * b.s, -a.s };
        u.D4 = u.D * u.D * u.D * u.D;
        u.D5 = u.D4 * u.D;
        u.Ke = 60.0 / (2.0 * fm.pi * u.Kv);
    }
}

/// interpolação linear na tabela (busca binária: tabela monotônica em J)
fn coef(u: *const T.PropUnit, J: f64, CT: *f64, CP: *f64) void {
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

pub fn unit(p: *const T.Params, u: *const T.PropUnit, Vr: V3, w: V3, rps: f64, thr: f64) Unit {
    var o = Unit{};
    const eT = vec.v3(u.eT);
    const n = if (rps > 1.0) rps else 1.0;
    const wm = 2.0 * fm.pi * n;
    const v = Vr + vec.cross(w, vec.v3(u.r));
    o.J = vec.dot(v, eT) / (n * u.D);
    var CT: f64 = 0;
    var CP: f64 = 0;
    coef(u, o.J, &CT, &CP);
    const rn2 = p.env.rho * n * n;
    o.T = CT * rn2 * u.D4;
    o.Q = CP / (2.0 * fm.pi) * rn2 * u.D5;
    o.I = fm.lim((thr * u.Voc - u.Ke * wm) / (u.Rm + thr * thr * u.Rint), 0.0, u.Imax);
    o.Ibat = thr * o.I;
    o.Vbus = u.Voc - u.Rint * o.Ibat;
    o.P = o.Vbus * o.Ibat;
    o.drps = (u.Ke * o.I - u.B * wm - u.tauc - o.Q) / (2.0 * fm.pi * (u.Jm + u.Ip));
    return o;
}

/// rps: rotação de cada unidade (vem do vetor de estados); dr: leme (acelerador diferencial)
pub fn compute(p: *const T.Params, Vr: V3, w: V3, rcg: V3, rps: []const f64, thr: f64, dr: f64, theta: f64) Out {
    var o = Out{};
    const n: usize = @intCast(p.n_prop);
    for (p.prop[0..n], 0..) |*u, i| {
        const th = fm.lim(thr + u.yaw_mix * dr, 0.0, 1.0);
        const r = unit(p, u, Vr, w, rps[i], th);
        o.u[i] = r;
        const eT = vec.v3(u.eT);
        const F = eT * vec.splat(r.T);
        o.F += F;
        o.M += vec.cross(vec.v3(u.r) - rcg, F) - eT * vec.splat(u.sense * r.Q);
        const wm = 2.0 * fm.pi * @max(rps[i], 1.0);
        const H = eT * vec.splat(u.sense * (u.Ip + u.Jm) * wm);
        o.Mgyro -= vec.cross(w, H);
        o.T += r.T;
        o.Q += r.Q;
        o.P += r.P;
        o.Ibat += r.Ibat;
        o.Vbus = if (i == 0) r.Vbus else @min(o.Vbus, r.Vbus);
        o.T_sin += r.T * fm.sin(theta + u.tilt);
    }
    return o;
}

/// rotação de equilíbrio (dn/dt = 0) por bisseção, sem rotação do avião
pub fn equilibriumRps(p: *const T.Params, u: *const T.PropUnit, Vr: V3, thr: f64) f64 {
    var lo: f64 = 1.0;
    var hi: f64 = 600.0;
    if (unit(p, u, Vr, vec.zero, lo, thr).drps <= 0.0) return lo;
    for (0..60) |_| {
        const mid = 0.5 * (lo + hi);
        if (unit(p, u, Vr, vec.zero, mid, thr).drps > 0.0) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

/// ponto de operação em voo axial a V (curva de tração)
pub fn point(p: *const T.Params, u: *const T.PropUnit, V: f64, thr: f64) T.PropPoint {
    const Vr = vec.v3(u.eT) * vec.splat(V);
    const n = equilibriumRps(p, u, Vr, thr);
    const r = unit(p, u, Vr, vec.zero, n, thr);
    const Ps = r.Q * 2.0 * fm.pi * n;
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

test "tração estática e queda com V" {
    var p = T.Params{};
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

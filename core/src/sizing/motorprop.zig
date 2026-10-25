//! Tração em regime de um conjunto motor + hélice + bateria com acelerador cheio, para a curva T(V) da sprint
//! (`aerosim/design/power.py: thrust_of`). Era a conta mais cara do aeroopt: uma bisseção em Python para cada
//! velocidade, presa ao GIL, chamada dezenas de vezes por candidato.
//!
//! A rotação ω é a do equilíbrio entre o torque do motor e o da hélice. O motor de corrente contínua sem escovas
//! dá, com a bateria em série (Drela, "First-Order DC Electric Motor Model", MIT, 2007, a conferir no PDF):
//!
//!   I = min((V_oc − ω/k_v)/(R_m + R_int), I_max),   Q_m = I/k_v − τ_c − B ω
//!
//! e a hélice pede Q_p = C_P(J)/(2π) ρ n² D⁵, com n = ω/2π e J = V/(n D). A bisseção de 60 passos em
//! ω ∈ [1, V_oc k_v] acha Q_m = Q_p; a tração é T = max(C_T(J) ρ n² D⁴, 0), com C_T = 0 depois do fim da tabela.
//!
//! As contas seguem a mesma ordem das do Python de antes e a interpolação é a do `numpy.interp`, então a curva sai
//! bit a bit igual (o teste em `tests/design/test_motor_prop.py` confere). D⁴ e D⁵ vêm prontos do Python, como o
//! seno e o cosseno da corrida em `ground.zig`, porque a potência do Python e a do Zig podem diferir no último bit.
const std = @import("std");
const ground = @import("ground.zig");

pub const max_pts = 256;
pub const iterations = 60;

pub const MotorProp = extern struct {
    Kv: f64 = 1000, // rpm/V
    Rm: f64 = 0.1, // resistência do motor (Ω)
    B: f64 = 0, // atrito viscoso (N·m·s)
    tauc: f64 = 0, // atrito seco (N·m)
    Imax: f64 = 1e9, // corrente máxima (A)
    Voc: f64 = 11.1, // tensão em aberto da bateria (V)
    Rint: f64 = 0, // resistência interna da bateria (Ω)
    D: f64 = 0.25, // diâmetro da hélice (m)
    D4: f64 = 0, // D⁴ e D⁵ (do Python)
    D5: f64 = 0,
    J: [max_pts]f64 = @splat(0), // tabela da hélice: J crescente, C_T, C_P
    CT: [max_pts]f64 = @splat(0),
    CP: [max_pts]f64 = @splat(0),
    n: i32 = 0,
};

/// `numpy.interp(x, xp, fp, right=r)`: depois do último ponto, `r`
fn interpRight(x: f64, xp: []const f64, fp: []const f64, r: f64) f64 {
    if (xp.len > 0 and x > xp[xp.len - 1]) return r;
    return ground.interp(x, xp, fp);
}

/// a tração (N) na velocidade `V` (m/s) com densidade `rho`; 0 sem tabela
pub fn thrust(m: *const MotorProp, V: f64, rho: f64) f64 {
    const np: usize = @intCast(std.math.clamp(m.n, 0, max_pts));
    if (np == 0) return 0;
    const tJ = m.J[0..np];
    const two_pi = 2 * std.math.pi;
    const kv = m.Kv * 2 * std.math.pi / 60;
    const R = m.Rm + m.Rint;
    const Res = struct { r: f64, n: f64, J: f64 };
    const resid = struct {
        fn f(mp: *const MotorProp, tab: []const f64, cp: []const f64, k: f64, Rs: f64, v: f64, rh: f64, w: f64) Res {
            const a = (mp.Voc - w / k) / Rs;
            const I = if (mp.Imax < a) mp.Imax else a; // o min do Python
            const Qm = I / k - mp.tauc - mp.B * w;
            const n = w / two_pi;
            const J = if (n > 0) v / (n * mp.D) else 0.0;
            const CP = ground.interp(J, tab, cp);
            return .{ .r = Qm - CP * rh * n * n * mp.D5 / two_pi, .n = n, .J = J };
        }
    }.f;
    const cp = m.CP[0..np];
    var lo: f64 = 1.0;
    var hi: f64 = m.Voc * kv;
    for (0..iterations) |_| {
        const mid = 0.5 * (lo + hi);
        if (resid(m, tJ, cp, kv, R, V, rho, mid).r > 0) lo = mid else hi = mid;
    }
    const e = resid(m, tJ, cp, kv, R, V, rho, 0.5 * (lo + hi));
    const CT = interpRight(e.J, tJ, m.CT[0..np], 0.0);
    const t = CT * rho * e.n * e.n * m.D4;
    return if (0.0 > t) 0.0 else t; // o max do Python
}

/// a curva: `out[i]` = tração em `V[i]`
pub fn curve(m: *const MotorProp, V: []const f64, rho: f64, out: []f64) void {
    for (V, out) |v, *o| o.* = thrust(m, v, rho);
}

// ------------------------------------------------------------------ testes
fn sample() MotorProp {
    var m: MotorProp = .{ .Kv = 900, .Rm = 0.08, .B = 1e-6, .tauc = 0.02, .Imax = 40, .Voc = 11.1, .Rint = 0.02, .D = 0.33 };
    m.D4 = m.D * m.D * m.D * m.D;
    m.D5 = m.D4 * m.D;
    m.n = 4;
    m.J[0..4].* = .{ 0, 0.3, 0.6, 0.8 };
    m.CT[0..4].* = .{ 0.12, 0.10, 0.05, 0.0 };
    m.CP[0..4].* = .{ 0.06, 0.055, 0.04, 0.02 };
    return m;
}

test "motor × hélice: o torque fecha no equilíbrio e a tração cai com V" {
    const m = sample();
    const t0 = thrust(&m, 0, 1.2);
    const t10 = thrust(&m, 10, 1.2);
    try std.testing.expect(t0 > 5 and t0 < 60);
    try std.testing.expect(t10 < t0 and t10 > 0);
    // no equilíbrio, Q_m = Q_p: refaz a conta na rotação de T = C_T ρ n² D⁴ (V = 0, J = 0: C_T = 0,12)
    const n = @sqrt(t0 / (0.12 * 1.2 * m.D4));
    const w = n * 2 * std.math.pi;
    const kv = m.Kv * 2 * std.math.pi / 60;
    const I = @min((m.Voc - w / kv) / (m.Rm + m.Rint), m.Imax);
    const Qm = I / kv - m.tauc - m.B * w;
    const Qp = 0.06 * 1.2 * n * n * m.D5 / (2 * std.math.pi);
    try std.testing.expectApproxEqRel(Qp, Qm, 1e-9);
}

test "motor × hélice: depois do fim da tabela não há tração; sem tabela, zero" {
    var m = sample();
    try std.testing.expectEqual(@as(f64, 0), thrust(&m, 80, 1.2)); // J > 0,8
    m.n = 0;
    try std.testing.expectEqual(@as(f64, 0), thrust(&m, 5, 1.2));
    try std.testing.expectEqual(@as(f64, 0), interpRight(2, &.{ 0, 1 }, &.{ 3, 4 }, 0));
    try std.testing.expectEqual(@as(f64, 4), interpRight(1, &.{ 0, 1 }, &.{ 3, 4 }, 0));
}

test "motor × hélice: a corrente máxima limita a tração parada" {
    var m = sample();
    const free = thrust(&m, 0, 1.2);
    m.Imax = 5;
    try std.testing.expect(thrust(&m, 0, 1.2) < free);
}

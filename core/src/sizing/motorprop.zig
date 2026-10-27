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
fn interpRight(query: f64, xp: []const f64, fp: []const f64, right_value: f64) f64 {
    if (xp.len > 0 and query > xp[xp.len - 1]) return right_value;
    return ground.interp(query, xp, fp);
}

/// a tração (N) na velocidade `V` (m/s) com densidade `rho`; 0 sem tabela
pub fn thrust(motor_prop: *const MotorProp, airspeed: f64, rho: f64) f64 {
    const np: usize = @intCast(std.math.clamp(motor_prop.n, 0, max_pts));
    if (np == 0) return 0;
    const tJ = motor_prop.J[0..np];
    const two_pi = 2 * std.math.pi;
    const kv = motor_prop.Kv * 2 * std.math.pi / 60;
    const total_resistance = motor_prop.Rm + motor_prop.Rint;
    const Res = struct { residual: f64, rev_per_s: f64, advance: f64 };
    const resid = struct {
        fn evaluate(mp: *const MotorProp, tab: []const f64, cp: []const f64, kv_rad: f64, resistance: f64, speed: f64, rh: f64, omega: f64) Res {
            const free_current = (mp.Voc - omega / kv_rad) / resistance;
            const current = if (mp.Imax < free_current) mp.Imax else free_current; // o min do Python
            const Qm = current / kv_rad - mp.tauc - mp.B * omega;
            const rev_per_s = omega / two_pi;
            const advance = if (rev_per_s > 0) speed / (rev_per_s * mp.D) else 0.0;
            const CP = ground.interp(advance, tab, cp);
            return .{ .residual = Qm - CP * rh * rev_per_s * rev_per_s * mp.D5 / two_pi, .rev_per_s = rev_per_s, .advance = advance };
        }
    }.evaluate;
    const cp = motor_prop.CP[0..np];
    var lo: f64 = 1.0;
    var hi: f64 = motor_prop.Voc * kv;
    for (0..iterations) |_| {
        const mid = 0.5 * (lo + hi);
        if (resid(motor_prop, tJ, cp, kv, total_resistance, airspeed, rho, mid).residual > 0) lo = mid else hi = mid;
    }
    const solution = resid(motor_prop, tJ, cp, kv, total_resistance, airspeed, rho, 0.5 * (lo + hi));
    const CT = interpRight(solution.advance, tJ, motor_prop.CT[0..np], 0.0);
    const thrust_value = CT * rho * solution.rev_per_s * solution.rev_per_s * motor_prop.D4;
    return if (0.0 > thrust_value) 0.0 else thrust_value; // o max do Python
}

/// a curva: `out[i]` = tração em `airspeeds[i]`
pub fn curve(motor_prop: *const MotorProp, airspeeds: []const f64, rho: f64, out: []f64) void {
    for (airspeeds, out) |airspeed, *out_value| out_value.* = thrust(motor_prop, airspeed, rho);
}

// ------------------------------------------------------------------ testes
fn sample() MotorProp {
    var motor_prop: MotorProp = .{ .Kv = 900, .Rm = 0.08, .B = 1e-6, .tauc = 0.02, .Imax = 40, .Voc = 11.1, .Rint = 0.02, .D = 0.33 };
    motor_prop.D4 = motor_prop.D * motor_prop.D * motor_prop.D * motor_prop.D;
    motor_prop.D5 = motor_prop.D4 * motor_prop.D;
    motor_prop.n = 4;
    motor_prop.J[0..4].* = .{ 0, 0.3, 0.6, 0.8 };
    motor_prop.CT[0..4].* = .{ 0.12, 0.10, 0.05, 0.0 };
    motor_prop.CP[0..4].* = .{ 0.06, 0.055, 0.04, 0.02 };
    return motor_prop;
}

test "motor × hélice: o torque fecha no equilíbrio e a tração cai com V" {
    const motor_prop = sample();
    const t0 = thrust(&motor_prop, 0, 1.2);
    const t10 = thrust(&motor_prop, 10, 1.2);
    try std.testing.expect(t0 > 5 and t0 < 60);
    try std.testing.expect(t10 < t0 and t10 > 0);
    // no equilíbrio, Q_m = Q_p: refaz a conta na rotação de T = C_T ρ n² D⁴ (V = 0, J = 0: C_T = 0,12)
    const rev_per_s = @sqrt(t0 / (0.12 * 1.2 * motor_prop.D4));
    const omega = rev_per_s * 2 * std.math.pi;
    const kv = motor_prop.Kv * 2 * std.math.pi / 60;
    const current = @min((motor_prop.Voc - omega / kv) / (motor_prop.Rm + motor_prop.Rint), motor_prop.Imax);
    const Qm = current / kv - motor_prop.tauc - motor_prop.B * omega;
    const Qp = 0.06 * 1.2 * rev_per_s * rev_per_s * motor_prop.D5 / (2 * std.math.pi);
    try std.testing.expectApproxEqRel(Qp, Qm, 1e-9);
}

test "motor × hélice: depois do fim da tabela não há tração; sem tabela, zero" {
    var motor_prop = sample();
    try std.testing.expectEqual(@as(f64, 0), thrust(&motor_prop, 80, 1.2)); // J > 0,8
    motor_prop.n = 0;
    try std.testing.expectEqual(@as(f64, 0), thrust(&motor_prop, 5, 1.2));
    try std.testing.expectEqual(@as(f64, 0), interpRight(2, &.{ 0, 1 }, &.{ 3, 4 }, 0));
    try std.testing.expectEqual(@as(f64, 4), interpRight(1, &.{ 0, 1 }, &.{ 3, 4 }, 0));
}

test "motor × hélice: a corrente máxima limita a tração parada" {
    var motor_prop = sample();
    const free = thrust(&motor_prop, 0, 1.2);
    motor_prop.Imax = 5;
    try std.testing.expect(thrust(&motor_prop, 0, 1.2) < free);
}

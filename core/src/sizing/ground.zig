//! Corrida de decolagem rápida da sprint (etapa Motores, `aerosim/design/power.py: performance`): a mesma
//! conta que estava em Python, passo a passo, agora no núcleo. É o gargalo do ponto de projeto acoplado: cada
//! ponto refaz a corrida umas 70 vezes (a bisseção do MTOW na pista e a curva corrida × massa).
//!
//! O avião corre no chão com C_L de corrida fixo, a tração lida de uma curva T(V) e o atrito no que o peso
//! ainda apoia (Euler explícito, passo de 0,02 s):
//!
//!   a = (T cos θ − ½ρV²S (C_D0 + K C_Lg²) − μ max(mg − ½ρV²S C_Lg − T sen θ, 0)) / m
//!
//! e sai do chão quando passa da velocidade em que o profundor roda o avião e ½ρV²S C_L,max ≥ 1,21 (mg − T sen θ)
//! (1,1 V_S, com a parte vertical da tração do motor inclinado θ aliviando o peso). O modelo é o mesmo de
//! `stages.takeoffRun` (ver o README desta pasta; a fonte a conferir no PDF).
//!
//! As contas seguem a mesma ordem das do Python e a interpolação é a do `numpy.interp`, então a corrida sai bit a
//! bit igual à de antes (o teste em `tests/design` confere).
const std = @import("std");

pub const g0 = 9.80665; // o mesmo G0 de aerosim/design/spec.py
pub const max_grid = 256;
pub const dt = 0.02;
pub const max_steps = 20000;

pub const GroundRun = extern struct {
    rho: f64 = 1.225,
    S: f64 = 1,
    CLg: f64 = 0, // C_L na corrida (asa calada, avião no chão)
    CD0: f64 = 0.03,
    K: f64 = 0.05,
    CLmax: f64 = 1.5,
    mu: f64 = 0.03, // atrito de rolamento
    sin_tl: f64 = 0, // seno e cosseno da inclinação média dos motores (o Python manda, para ficar igual)
    cos_tl: f64 = 1,
    V: [max_grid]f64 = @splat(0), // curva de tração: V crescente, T total com acelerador cheio
    T: [max_grid]f64 = @splat(0),
    n: i32 = 0,
    // velocidade de rotação: a primeira rot_V[i] com rot_a[i] − m g0 · rot_arm > 0 (o momento do profundor todo
    // cabrando, mais o da tração, menos o do peso no trem principal). rot_on = 0: não espera rotação
    rot_V: [max_grid]f64 = @splat(0),
    rot_a: [max_grid]f64 = @splat(0),
    rot_arm: f64 = 0,
    n_rot: i32 = 0,
    rot_on: i32 = 0,
    // atitude no chão (`power.ground_pitch` > 0: o trem do nariz mais alto deixa a asa num ângulo): o avião também
    // sai do chão sem rodar, quando a sustentação da corrida (C_Lg, já nesse ângulo) mais a parte vertical da
    // tração vence o peso. 0: só pela rotação, como sempre
    lift_off: i32 = 0,
};

/// `numpy.interp(x, xp, fp)` para um x só (xp crescente): fora da faixa, o valor da ponta
pub fn interp(query: f64, xp: []const f64, fp: []const f64) f64 {
    const count = xp.len;
    if (count == 0) return 0;
    if (std.math.isNan(query)) return query;
    if (query < xp[0]) return fp[0];
    if (query >= xp[count - 1]) return fp[count - 1];
    var lo: usize = 0;
    var hi: usize = count - 1; // xp[lo] ≤ x < xp[hi]
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (xp[mid] <= query) lo = mid else hi = mid;
    }
    const slope = (fp[lo + 1] - fp[lo]) / (xp[lo + 1] - xp[lo]);
    var value = slope * (query - xp[lo]) + fp[lo];
    if (std.math.isNan(value)) {
        value = slope * (query - xp[lo + 1]) + fp[lo + 1];
        if (std.math.isNan(value) and fp[lo] == fp[lo + 1]) value = fp[lo];
    }
    return value;
}

fn curve(ground_run: *const GroundRun) struct { []const f64, []const f64 } {
    const count: usize = @intCast(std.math.clamp(ground_run.n, 0, max_grid));
    return .{ ground_run.V[0..count], ground_run.T[0..count] };
}

/// velocidade a partir da qual o profundor roda o avião de massa m (0 sem rotação; inf se nunca)
pub fn rotSpeed(ground_run: *const GroundRun, mass: f64) f64 {
    if (ground_run.rot_on == 0) return 0;
    const count: usize = @intCast(std.math.clamp(ground_run.n_rot, 0, max_grid));
    for (0..count) |i| {
        if (ground_run.rot_a[i] - mass * g0 * ground_run.rot_arm > 0) return ground_run.rot_V[i];
    }
    return std.math.inf(f64);
}

/// a corrida (m) com massa `mass`; inf se não decola
pub fn run(ground_run: *const GroundRun, mass: f64) f64 {
    const inf = std.math.inf(f64);
    const v_rot = rotSpeed(ground_run, mass);
    if (!std.math.isFinite(v_rot) and ground_run.lift_off == 0) return inf;
    const vg, const tg = curve(ground_run);
    var distance: f64 = 0;
    var speed: f64 = 0;
    for (0..max_steps) |_| {
        const dyn_pressure = 0.5 * ground_run.rho * speed * speed;
        const thrust = interp(speed, vg, tg);
        const lift = dyn_pressure * ground_run.S * ground_run.CLg + thrust * ground_run.sin_tl;
        const drag = dyn_pressure * ground_run.S * (ground_run.CD0 + ground_run.K * ground_run.CLg * ground_run.CLg);
        const accel = (thrust * ground_run.cos_tl - drag - ground_run.mu * @max(mass * g0 - lift, 0.0)) / mass;
        if (accel <= 0) return inf;
        speed += accel * dt;
        distance += speed * dt;
        if (speed >= v_rot and 0.5 * ground_run.rho * speed * speed * ground_run.S * ground_run.CLmax >= 1.21 * (mass * g0 - interp(speed, vg, tg) * ground_run.sin_tl))
            return distance;
        if (ground_run.lift_off != 0 and 0.5 * ground_run.rho * speed * speed * ground_run.S * ground_run.CLg + interp(speed, vg, tg) * ground_run.sin_tl >= mass * g0)
            return distance; // sai do chão na atitude da corrida, sem rodar
    }
    return inf;
}

/// o maior peso que corre até `runway`: bisseção de 40 passos em [lo, hi]; NaN se nem `lo` decola
pub fn mtow(ground_run: *const GroundRun, lo0: f64, hi0: f64, runway: f64) f64 {
    var lo = lo0;
    var hi = hi0;
    if (run(ground_run, lo) > runway) return std.math.nan(f64);
    for (0..40) |_| {
        const mid = 0.5 * (lo + hi);
        if (run(ground_run, mid) <= runway) lo = mid else hi = mid;
    }
    return lo;
}

// ------------------------------------------------------------------ testes
fn sample() GroundRun {
    var ground_run: GroundRun = .{ .rho = 1.2, .S = 0.8, .CLg = 0.6, .CD0 = 0.04, .K = 0.06, .CLmax = 1.6, .mu = 0.04 };
    ground_run.n = 3;
    ground_run.V[0..3].* = .{ 0, 10, 30 };
    ground_run.T[0..3].* = .{ 40, 34, 10 };
    return ground_run;
}

test "interp como o numpy: pontas, nós e meio" {
    const xp = [_]f64{ 0, 1, 3 };
    const fp = [_]f64{ 2, 4, 0 };
    try std.testing.expectEqual(@as(f64, 2), interp(-1, &xp, &fp));
    try std.testing.expectEqual(@as(f64, 0), interp(5, &xp, &fp));
    try std.testing.expectEqual(@as(f64, 0), interp(3, &xp, &fp));
    try std.testing.expectEqual(@as(f64, 4), interp(1, &xp, &fp));
    try std.testing.expectEqual(@as(f64, 3), interp(0.5, &xp, &fp));
    try std.testing.expectEqual(@as(f64, 2), interp(2, &xp, &fp));
}

test "corrida: mais pesado corre mais; a pista limita o MTOW" {
    const ground_run = sample();
    const s1 = run(&ground_run, 3.0);
    const s2 = run(&ground_run, 4.0);
    try std.testing.expect(std.math.isFinite(s1) and s2 > s1);
    const max_mass = mtow(&ground_run, 1.0, 12.0, 20.0);
    try std.testing.expect(run(&ground_run, max_mass) <= 20.0 and run(&ground_run, max_mass * 1.01) > 20.0);
    try std.testing.expect(std.math.isNan(mtow(&ground_run, 1.0, 12.0, 0.01)));
}

test "corrida: na atitude do chão sai sem rodar quando ½ρV²S C_Lg vence o peso" {
    var ground_run = GroundRun{ .S = 0.6, .CLg = 0.9, .CLmax = 1.2, .mu = 0.0, .CD0 = 0.0, .K = 0.0 };
    ground_run.n = 2;
    ground_run.V[0..2].* = .{ 0, 40 };
    ground_run.T[0..2].* = .{ 10, 10 };
    ground_run.rot_on = 1;
    ground_run.n_rot = 1;
    ground_run.rot_V[0] = 5;
    ground_run.rot_a[0] = -1; // o profundor nunca roda
    try std.testing.expect(std.math.isInf(run(&ground_run, 2.0)));
    ground_run.lift_off = 1;
    // sem arrasto nem atrito: a = T/m = 5 m/s², v = 0,1 n no passo n; sai no primeiro n com v² ≥ 2 m g0 / (ρ S C_Lg)
    // (7,70 m/s: n = 78), e o Euler explícito dá x = a dt² n (n + 1) / 2 (≈ V²/2a = 5,93 m com o passo de 0,02 s)
    const step_count: f64 = @ceil(@sqrt(2.0 * 2.0 * g0 / (1.225 * 0.6 * 0.9)) / 0.1);
    try std.testing.expectApproxEqRel(5.0 * dt * dt * step_count * (step_count + 1) / 2.0, run(&ground_run, 2.0), 1e-9);
}

test "corrida: sem tração não sai; a rotação espera o profundor" {
    var ground_run = sample();
    const free = run(&ground_run, 3.0);
    ground_run.rot_on = 1;
    ground_run.n_rot = 2;
    ground_run.rot_V[0..2].* = .{ 5, 15 };
    ground_run.rot_a[0..2].* = .{ -1, 1e6 };
    ground_run.rot_arm = 0.1;
    try std.testing.expectEqual(@as(f64, 15), rotSpeed(&ground_run, 3.0));
    try std.testing.expect(run(&ground_run, 3.0) >= free);
    ground_run.rot_a[1] = -1;
    try std.testing.expect(std.math.isInf(run(&ground_run, 3.0)));
    ground_run = sample();
    ground_run.T = @splat(0);
    try std.testing.expect(std.math.isInf(run(&ground_run, 3.0)));
}

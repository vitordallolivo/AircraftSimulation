//! Benchmarks exportados (o Python cronometra): funções matemáticas isoladas com tabelas
//! de tamanhos diferentes (para ver o efeito do cache) e a avaliação da dinâmica f(t, x).
const std = @import("std");
const fmath = @import("math/fmath.zig");
const state = @import("sim/state.zig");
const sim_dynamics = @import("sim/dynamics.zig");
const runner = @import("sim/runner.zig");

pub const Kind = enum(i32) {
    sin_lut256 = 0, // 2 KB: cabe no L1
    sin_ref = 1,
    sin_lut4096 = 2, // 32 KB: o L1 inteiro
    sin_lut65536 = 3, // 512 KB: não cabe no L1/L2, vai ao L3/RAM
    atan2_lut = 4,
    atan2_ref = 5,
    exp_lut = 6,
    exp_ref = 7,
    log_lut = 8,
    log_ref = 9,
    sin_minimax = 10, // sem tabela: redução ao quadrante + minimax (`-Dopt` bit 32)
    exp_estrin = 11, // o polinômio do exp por Estrin (`-Dopt` bit 64)
};

const Big = fmath.SinLut(16);
const Mid = fmath.SinLut(12);

/// entrada pseudoaleatória barata (LCG), em [-r, r]
inline fn next(rng_state: *u64, range: f64) f64 {
    rng_state.* = rng_state.* *% 6364136223846793005 +% 1442695040888963407;
    const draw: f64 = @floatFromInt(rng_state.* >> 11);
    return (draw * (1.0 / 9007199254740992.0) * 2.0 - 1.0) * range;
}

fn loop(comptime f: anytype, n: u64, random: bool, r: f64) f64 {
    var st: u64 = 12345;
    var acc: f64 = 0;
    var x: f64 = -r;
    const dx = 2.0 * r / @as(f64, @floatFromInt(n));
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const v = if (random) next(&st, r) else blk: {
            x += dx;
            break :blk x;
        };
        acc += f(v);
    }
    return acc;
}

fn sinOf(comptime T: type) fn (f64) f64 {
    return struct {
        fn f(x: f64) f64 {
            return T.sincos(x).s;
        }
    }.f;
}

// o exp da tabela com cada esquema, independente de -Dopt
fn expHorner(x: f64) f64 {
    return fmath.lut.expWith(false, x);
}
fn expEstrin(x: f64) f64 {
    return fmath.lut.expWith(true, x);
}

fn atan2L(x: f64) f64 {
    return fmath.lut.atan2(x, 0.7);
}
fn atan2R(x: f64) f64 {
    return fmath.ref.atan2(x, 0.7);
}
fn logL(x: f64) f64 {
    return fmath.lut.log(@abs(x) + 1e-3);
}
fn logR(x: f64) f64 {
    return fmath.ref.log(@abs(x) + 1e-3);
}

/// roda n chamadas; devolve a soma (para o compilador não apagar o laço)
pub fn math(kind: Kind, n: u64, random: bool) f64 {
    return switch (kind) {
        .sin_lut256 => loop(sinOf(fmath.lut.Sin), n, random, 10.0),
        .sin_ref => loop(sinOf(fmath.ref), n, random, 10.0),
        .sin_lut4096 => loop(sinOf(Mid), n, random, 10.0),
        .sin_lut65536 => loop(sinOf(Big), n, random, 10.0),
        .atan2_lut => loop(atan2L, n, random, 30.0),
        .atan2_ref => loop(atan2R, n, random, 30.0),
        .exp_lut => loop(expHorner, n, random, 50.0),
        .exp_estrin => loop(expEstrin, n, random, 50.0),
        .sin_minimax => loop(sinOf(fmath.minimax), n, random, 10.0),
        .exp_ref => loop(fmath.ref.exp, n, random, 50.0),
        .log_lut => loop(logL, n, random, 1e3),
        .log_ref => loop(logR, n, random, 1e3),
    };
}

/// n avaliações de f(t, x) no estado atual da simulação
pub fn dynamics(inst: *runner.Instance, n: u64) f64 {
    var dx: [state.nx]f64 = undefined;
    var acc: f64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        sim_dynamics.f(inst.ctx(), inst.r.t, &inst.r.x, &dx, null);
        acc += dx[state.U];
    }
    return acc;
}

test "bench roda e dá o mesmo resultado nas tabelas" {
    const a = math(.sin_lut256, 1000, true);
    const b = math(.sin_ref, 1000, true);
    const c = math(.sin_lut4096, 1000, true);
    try std.testing.expectApproxEqAbs(b, a, 1e-9);
    try std.testing.expectApproxEqAbs(b, c, 1e-9);
}

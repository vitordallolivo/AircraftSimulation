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

fn loop(comptime func: anytype, count: u64, random: bool, range: f64) f64 {
    var seed: u64 = 12345;
    var acc: f64 = 0;
    var sweep: f64 = -range;
    const step = 2.0 * range / @as(f64, @floatFromInt(count));
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const input = if (random) next(&seed, range) else blk: {
            sweep += step;
            break :blk sweep;
        };
        acc += func(input);
    }
    return acc;
}

fn sinOf(comptime Table: type) fn (f64) f64 {
    return struct {
        fn evaluate(angle: f64) f64 {
            return Table.sincos(angle).s;
        }
    }.evaluate;
}

// o exp da tabela com cada esquema, independente de -Dopt
fn expHorner(value: f64) f64 {
    return fmath.lut.expWith(false, value);
}
fn expEstrin(value: f64) f64 {
    return fmath.lut.expWith(true, value);
}

fn atan2L(value: f64) f64 {
    return fmath.lut.atan2(value, 0.7);
}
fn atan2R(value: f64) f64 {
    return fmath.ref.atan2(value, 0.7);
}
fn logL(value: f64) f64 {
    return fmath.lut.log(@abs(value) + 1e-3);
}
fn logR(value: f64) f64 {
    return fmath.ref.log(@abs(value) + 1e-3);
}

/// roda `count` chamadas; devolve a soma (para o compilador não apagar o laço)
pub fn math(kind: Kind, count: u64, random: bool) f64 {
    return switch (kind) {
        .sin_lut256 => loop(sinOf(fmath.lut.Sin), count, random, 10.0),
        .sin_ref => loop(sinOf(fmath.ref), count, random, 10.0),
        .sin_lut4096 => loop(sinOf(Mid), count, random, 10.0),
        .sin_lut65536 => loop(sinOf(Big), count, random, 10.0),
        .atan2_lut => loop(atan2L, count, random, 30.0),
        .atan2_ref => loop(atan2R, count, random, 30.0),
        .exp_lut => loop(expHorner, count, random, 50.0),
        .exp_estrin => loop(expEstrin, count, random, 50.0),
        .sin_minimax => loop(sinOf(fmath.minimax), count, random, 10.0),
        .exp_ref => loop(fmath.ref.exp, count, random, 50.0),
        .log_lut => loop(logL, count, random, 1e3),
        .log_ref => loop(logR, count, random, 1e3),
    };
}

/// `count` avaliações das derivadas no estado atual da simulação
pub fn dynamics(inst: *runner.Instance, count: u64) f64 {
    var state_rates: [state.nx]f64 = undefined;
    var acc: f64 = 0;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        sim_dynamics.derivatives(inst.ctx(), inst.r.t, &inst.r.x, &state_rates, null);
        acc += state_rates[state.index(.vel_x)];
    }
    return acc;
}

test "bench roda e dá o mesmo resultado nas tabelas" {
    const lut256 = math(.sin_lut256, 1000, true);
    const reference = math(.sin_ref, 1000, true);
    const lut4096 = math(.sin_lut4096, 1000, true);
    try std.testing.expectApproxEqAbs(reference, lut256, 1e-9);
    try std.testing.expectApproxEqAbs(reference, lut4096, 1e-9);
}

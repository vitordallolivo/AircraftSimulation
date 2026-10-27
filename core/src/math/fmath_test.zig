//! Testes só das LUTs e aproximações (independentes de -Dfast_math: comparam `lut` com `ref`).
const std = @import("std");
const fmath = @import("fmath.zig");
const testing = std.testing;

test "LUT seno 256 pontos: erro < 1e-14 em ±50 rad" {
    var angle: f64 = -50.0;
    while (angle < 50.0) : (angle += 0.00731) {
        const result = fmath.lut.sincos(angle);
        try testing.expectApproxEqAbs(@sin(angle), result.s, 1e-14);
        try testing.expectApproxEqAbs(@cos(angle), result.c, 1e-14);
    }
}

test "LUT seno: tamanhos diferentes dão o mesmo resultado" {
    inline for (.{ 6, 8, 10, 12 }) |bits| {
        const Table = fmath.SinLut(bits);
        var angle: f64 = -7.0;
        while (angle < 7.0) : (angle += 0.0137) {
            try testing.expectApproxEqAbs(@sin(angle), Table.sincos(angle).s, if (bits < 8) 1e-11 else 1e-14);
        }
    }
}

test "LUT seno: tabela gerada em comptime, alinhada e pequena" {
    try testing.expectEqual(@as(usize, 256), fmath.lut.Sin.points);
    try testing.expectEqual(@as(usize, 2048), fmath.lut.Sin.bytes);
    try testing.expect(@intFromPtr(&fmath.lut.Sin.table) % 64 == 0);
    try testing.expectEqual(@as(f64, 0), fmath.lut.Sin.table[0]);
}

test "LUT seno: pontos exatos e simetrias" {
    try testing.expectApproxEqAbs(@as(f64, 1), fmath.lut.sincos(std.math.pi / 2.0).s, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1), fmath.lut.sincos(std.math.pi).c, 1e-15);
    const angle = 0.3712;
    try testing.expectApproxEqAbs(-fmath.lut.sincos(angle).s, fmath.lut.sincos(-angle).s, 4e-16);
}

test "LUT atan e atan2: erro < 1e-8, todos os quadrantes" {
    var value: f64 = -30.0;
    while (value < 30.0) : (value += 0.0071) {
        try testing.expectApproxEqAbs(std.math.atan(value), fmath.lut.atan(value), 1e-8);
        inline for (.{ 1.3, -1.3 }) |other| {
            try testing.expectApproxEqAbs(std.math.atan2(value, other), fmath.lut.atan2(value, other), 1e-8);
            try testing.expectApproxEqAbs(std.math.atan2(other, value), fmath.lut.atan2(other, value), 1e-8);
        }
    }
    try testing.expectEqual(@as(f64, 0), fmath.lut.atan2(0, 0));
}

test "polinômio exp: erro relativo < 1e-12" {
    var value: f64 = -200.0;
    while (value < 200.0) : (value += 0.173) try testing.expectApproxEqRel(@exp(value), fmath.lut.exp(value), 1e-12);
}

test "série log e pow" {
    var value: f64 = 1e-6;
    while (value < 1e6) : (value *= 1.37) {
        try testing.expectApproxEqAbs(@log(value), fmath.lut.log(value), 1e-11);
        try testing.expectApproxEqRel(std.math.pow(f64, value, 1.0 / 7.0), fmath.lut.exp(fmath.lut.log(value) / 7.0), 1e-10);
    }
}

test "tanh" {
    var value: f64 = -25.0;
    while (value < 25.0) : (value += 0.0113) try testing.expectApproxEqAbs(std.math.tanh(value), fmath.lut.tanh(value), 1e-12);
}

test "minimax sin/cos (Schlör, graus 15 e 16): erro < 1e-15 em ±50 rad, quadrantes e simetria" {
    var angle: f64 = -50.0;
    while (angle < 50.0) : (angle += 0.00731) {
        const result = fmath.minimax.sincos(angle);
        try testing.expectApproxEqAbs(@sin(angle), result.s, 1e-15);
        try testing.expectApproxEqAbs(@cos(angle), result.c, 1e-15);
    }
    // nos múltiplos de π/2 o quadrante troca seno e cosseno e o sinal
    inline for (.{ 0.0, 1.0, 2.0, 3.0, 4.0, -1.0, -2.0, -3.0 }) |k| {
        const angle_k = k * std.math.pi / 2.0;
        try testing.expectApproxEqAbs(@sin(angle_k), fmath.minimax.sincos(angle_k).s, 1e-15);
        try testing.expectApproxEqAbs(@cos(angle_k), fmath.minimax.sincos(angle_k).c, 1e-15);
    }
    const mirror = 0.3712;
    try testing.expectEqual(-fmath.minimax.sincos(mirror).s, fmath.minimax.sincos(-mirror).s);
    try testing.expectEqual(fmath.minimax.sincos(mirror).c, fmath.minimax.sincos(-mirror).c);
}

test "minimax sin no primeiro quarto: erro relativo no limite do gist (1,42e-16, mais o arredondamento)" {
    var angle: f64 = 1e-6;
    while (angle < std.math.pi / 4.0) : (angle += 0.000917) try testing.expectApproxEqRel(@sin(angle), fmath.minimax.sincos(angle).s, 4e-16);
}

test "exp por Estrin: erro relativo < 1e-12 e perto do Horner (só o arredondamento muda)" {
    var value: f64 = -200.0;
    while (value < 200.0) : (value += 0.173) {
        const estrin = fmath.lut.expWith(true, value);
        try testing.expectApproxEqRel(@exp(value), estrin, 1e-12);
        try testing.expectApproxEqRel(fmath.lut.expWith(false, value), estrin, 1e-15);
    }
}

test "NaN e infinito: sincos devolve NaN e wrap devolve o próprio valor, sem pane nem laço sem fim" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try std.testing.expect(std.math.isNan(fmath.sincos(nan).s));
    try std.testing.expect(std.math.isNan(fmath.sincos(inf).c));
    try std.testing.expect(std.math.isNan(fmath.wrap(nan)));
    try std.testing.expectEqual(inf, fmath.wrap(inf));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fmath.wrap(1.0 + 1.0e6 * 2.0 * std.math.pi), 1e-6);
    try std.testing.expect(std.math.isNan(fmath.atan2(nan, 1.0)));
    try std.testing.expect(std.math.isNan(fmath.atan2(1.0, nan)));
    try std.testing.expect(std.math.isNan(fmath.atan(nan)));
    _ = fmath.exp(nan); // o clamp já tira o NaN da conta: só não pode entrar em pane
}

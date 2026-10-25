//! Testes só das LUTs e aproximações (independentes de -Dfast_math: comparam `lut` com `ref`).
const std = @import("std");
const fm = @import("fmath.zig");
const testing = std.testing;

test "LUT seno 256 pontos: erro < 1e-14 em ±50 rad" {
    var x: f64 = -50.0;
    while (x < 50.0) : (x += 0.00731) {
        const a = fm.lut.sincos(x);
        try testing.expectApproxEqAbs(@sin(x), a.s, 1e-14);
        try testing.expectApproxEqAbs(@cos(x), a.c, 1e-14);
    }
}

test "LUT seno: tamanhos diferentes dão o mesmo resultado" {
    inline for (.{ 6, 8, 10, 12 }) |bits| {
        const T = fm.SinLut(bits);
        var x: f64 = -7.0;
        while (x < 7.0) : (x += 0.0137) {
            try testing.expectApproxEqAbs(@sin(x), T.sincos(x).s, if (bits < 8) 1e-11 else 1e-14);
        }
    }
}

test "LUT seno: tabela gerada em comptime, alinhada e pequena" {
    try testing.expectEqual(@as(usize, 256), fm.lut.Sin.n);
    try testing.expectEqual(@as(usize, 2048), fm.lut.Sin.bytes);
    try testing.expect(@intFromPtr(&fm.lut.Sin.table) % 64 == 0);
    try testing.expectEqual(@as(f64, 0), fm.lut.Sin.table[0]);
}

test "LUT seno: pontos exatos e simetrias" {
    try testing.expectApproxEqAbs(@as(f64, 1), fm.lut.sincos(std.math.pi / 2.0).s, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1), fm.lut.sincos(std.math.pi).c, 1e-15);
    const x = 0.3712;
    try testing.expectApproxEqAbs(-fm.lut.sincos(x).s, fm.lut.sincos(-x).s, 4e-16);
}

test "LUT atan e atan2: erro < 1e-8, todos os quadrantes" {
    var x: f64 = -30.0;
    while (x < 30.0) : (x += 0.0071) {
        try testing.expectApproxEqAbs(std.math.atan(x), fm.lut.atan(x), 1e-8);
        inline for (.{ 1.3, -1.3 }) |y| {
            try testing.expectApproxEqAbs(std.math.atan2(x, y), fm.lut.atan2(x, y), 1e-8);
            try testing.expectApproxEqAbs(std.math.atan2(y, x), fm.lut.atan2(y, x), 1e-8);
        }
    }
    try testing.expectEqual(@as(f64, 0), fm.lut.atan2(0, 0));
}

test "polinômio exp: erro relativo < 1e-12" {
    var x: f64 = -200.0;
    while (x < 200.0) : (x += 0.173) try testing.expectApproxEqRel(@exp(x), fm.lut.exp(x), 1e-12);
}

test "série log e pow" {
    var y: f64 = 1e-6;
    while (y < 1e6) : (y *= 1.37) {
        try testing.expectApproxEqAbs(@log(y), fm.lut.log(y), 1e-11);
        try testing.expectApproxEqRel(std.math.pow(f64, y, 1.0 / 7.0), fm.lut.exp(fm.lut.log(y) / 7.0), 1e-10);
    }
}

test "tanh" {
    var x: f64 = -25.0;
    while (x < 25.0) : (x += 0.0113) try testing.expectApproxEqAbs(std.math.tanh(x), fm.lut.tanh(x), 1e-12);
}

test "minimax sin/cos (Schlör, graus 15 e 16): erro < 1e-15 em ±50 rad, quadrantes e simetria" {
    var x: f64 = -50.0;
    while (x < 50.0) : (x += 0.00731) {
        const a = fm.minimax.sincos(x);
        try testing.expectApproxEqAbs(@sin(x), a.s, 1e-15);
        try testing.expectApproxEqAbs(@cos(x), a.c, 1e-15);
    }
    // nos múltiplos de π/2 o quadrante troca seno e cosseno e o sinal
    inline for (.{ 0.0, 1.0, 2.0, 3.0, 4.0, -1.0, -2.0, -3.0 }) |k| {
        const v = k * std.math.pi / 2.0;
        try testing.expectApproxEqAbs(@sin(v), fm.minimax.sincos(v).s, 1e-15);
        try testing.expectApproxEqAbs(@cos(v), fm.minimax.sincos(v).c, 1e-15);
    }
    const y = 0.3712;
    try testing.expectEqual(-fm.minimax.sincos(y).s, fm.minimax.sincos(-y).s);
    try testing.expectEqual(fm.minimax.sincos(y).c, fm.minimax.sincos(-y).c);
}

test "minimax sin no primeiro quarto: erro relativo no limite do gist (1,42e-16, mais o arredondamento)" {
    var x: f64 = 1e-6;
    while (x < std.math.pi / 4.0) : (x += 0.000917) try testing.expectApproxEqRel(@sin(x), fm.minimax.sincos(x).s, 4e-16);
}

test "exp por Estrin: erro relativo < 1e-12 e perto do Horner (só o arredondamento muda)" {
    var x: f64 = -200.0;
    while (x < 200.0) : (x += 0.173) {
        const e = fm.lut.expWith(true, x);
        try testing.expectApproxEqRel(@exp(x), e, 1e-12);
        try testing.expectApproxEqRel(fm.lut.expWith(false, x), e, 1e-15);
    }
}

test "NaN e infinito: sincos devolve NaN e wrap devolve o próprio valor, sem pane nem laço sem fim" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try std.testing.expect(std.math.isNan(fm.sincos(nan).s));
    try std.testing.expect(std.math.isNan(fm.sincos(inf).c));
    try std.testing.expect(std.math.isNan(fm.wrap(nan)));
    try std.testing.expectEqual(inf, fm.wrap(inf));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fm.wrap(1.0 + 1.0e6 * 2.0 * std.math.pi), 1e-6);
    try std.testing.expect(std.math.isNan(fm.atan2(nan, 1.0)));
    try std.testing.expect(std.math.isNan(fm.atan2(1.0, nan)));
    try std.testing.expect(std.math.isNan(fm.atan(nan)));
    _ = fm.exp(nan); // o clamp já tira o NaN da conta: só não pode entrar em pane
}

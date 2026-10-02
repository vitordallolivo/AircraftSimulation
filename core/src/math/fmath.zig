//! Funções matemáticas rápidas.
//!
//! Com `fast_math` (padrão):
//!   sin/cos  tabela de 4096 pontos por volta + correção de Taylor (erro ~1e-14)
//!   atan     tabela de 256 pontos em [0,1] + correção de 2ª ordem (erro ~3e-9)
//!   exp      redução 2^k · e^r com polinômio de grau 10 (erro relativo ~1e-13)
//!   log      expoente + série de atanh (erro ~1e-11)
//!   sqrt     instrução de hardware (@sqrt), fma via @mulAdd
//! Sem `fast_math` cada função chama a da std (referência para comparar).
//! As tabelas são geradas em tempo de compilação (comptime) e ficam na seção de dados.
const std = @import("std");
const build_options = @import("build_options");

pub const fast = build_options.fast_math;
pub const pi = std.math.pi;
const two_pi = 2.0 * pi;
const half_pi = 0.5 * pi;

// ---------------------------------------------------------------- seno e cosseno
const sin_bits = 12;
const sin_n = 1 << sin_bits;
const sin_mask: u64 = sin_n - 1;
const sin_step = two_pi / @as(f64, sin_n);
const sin_inv_step = @as(f64, sin_n) / two_pi;

const sin_lut: [sin_n]f64 = blk: {
    @setEvalBranchQuota(200_000);
    var t: [sin_n]f64 = undefined;
    for (0..sin_n) |i| t[i] = @sin(@as(f64, @floatFromInt(i)) * sin_step);
    break :blk t;
};

pub const SinCos = struct { s: f64, c: f64 };

/// sin e cos de uma vez: x = i·h + d, |d| <= h/2
///   sin(x) = sin(ih) cos(d) + cos(ih) sin(d)
pub fn sincos(x: f64) SinCos {
    if (!fast) return .{ .s = @sin(x), .c = @cos(x) };
    const k = @round(x * sin_inv_step);
    const d = @mulAdd(f64, -k, sin_step, x);
    const ki: i64 = @intFromFloat(k);
    const idx: u64 = @as(u64, @bitCast(ki)) & sin_mask;
    const s0 = sin_lut[idx];
    const c0 = sin_lut[(idx + sin_n / 4) & sin_mask];
    const d2 = d * d;
    const cd = 1.0 - d2 * (0.5 - d2 * (1.0 / 24.0));
    const sd = d * (1.0 - d2 * (1.0 / 6.0) * (1.0 - d2 * (1.0 / 20.0)));
    return .{ .s = @mulAdd(f64, s0, cd, c0 * sd), .c = @mulAdd(f64, c0, cd, -s0 * sd) };
}

pub inline fn sin(x: f64) f64 {
    return sincos(x).s;
}
pub inline fn cos(x: f64) f64 {
    return sincos(x).c;
}
pub fn tan(x: f64) f64 {
    const sc = sincos(x);
    return sc.s / sc.c;
}

// ---------------------------------------------------------------- arco tangente
const atan_n = 256;
const atan_lut: [atan_n + 1]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [atan_n + 1]f64 = undefined;
    for (0..atan_n + 1) |i| t[i] = std.math.atan(@as(f64, @floatFromInt(i)) / atan_n);
    break :blk t;
};

/// atan em [0, 1]: atan(a + d) ≈ atan(a) + d g - a d² g²,  g = 1/(1 + a²)
inline fn atan01(z: f64) f64 {
    const k = @round(z * atan_n);
    const a = k * (1.0 / @as(f64, atan_n));
    const d = z - a;
    const g = 1.0 / @mulAdd(f64, a, a, 1.0);
    const i: usize = @intFromFloat(k);
    return atan_lut[i] + d * g * (1.0 - a * d * g);
}

pub fn atan(x: f64) f64 {
    if (!fast) return std.math.atan(x);
    const ax = @abs(x);
    const r = if (ax <= 1.0) atan01(ax) else half_pi - atan01(1.0 / ax);
    return if (x < 0) -r else r;
}

pub fn atan2(y: f64, x: f64) f64 {
    if (!fast) return std.math.atan2(y, x);
    const ax = @abs(x);
    const ay = @abs(y);
    if (ax == 0 and ay == 0) return 0.0;
    var r = if (ay <= ax) atan01(ay / ax) else half_pi - atan01(ax / ay);
    if (x < 0) r = pi - r;
    return if (y < 0) -r else r;
}

pub fn asin(x: f64) f64 {
    if (!fast) return std.math.asin(x);
    const c = std.math.clamp(x, -1.0, 1.0);
    return atan2(c, @sqrt(@max(0.0, 1.0 - c * c)));
}

pub fn acos(x: f64) f64 {
    if (!fast) return std.math.acos(x);
    const c = std.math.clamp(x, -1.0, 1.0);
    return atan2(@sqrt(@max(0.0, 1.0 - c * c)), c);
}

// ---------------------------------------------------------------- exponencial e logaritmo
const ln2 = std.math.ln2;
const inv_ln2 = 1.0 / ln2;

/// e^x = 2^k e^r, |r| <= ln2/2; e^r por Horner (grau 10)
pub fn exp(x: f64) f64 {
    if (!fast) return @exp(x);
    const xc = std.math.clamp(x, -700.0, 700.0);
    const k = @round(xc * inv_ln2);
    const r = @mulAdd(f64, -k, ln2, xc);
    var p: f64 = 1.0 / 3628800.0;
    p = @mulAdd(f64, p, r, 1.0 / 362880.0);
    p = @mulAdd(f64, p, r, 1.0 / 40320.0);
    p = @mulAdd(f64, p, r, 1.0 / 5040.0);
    p = @mulAdd(f64, p, r, 1.0 / 720.0);
    p = @mulAdd(f64, p, r, 1.0 / 120.0);
    p = @mulAdd(f64, p, r, 1.0 / 24.0);
    p = @mulAdd(f64, p, r, 1.0 / 6.0);
    p = @mulAdd(f64, p, r, 0.5);
    p = @mulAdd(f64, p, r, 1.0);
    p = @mulAdd(f64, p, r, 1.0);
    const ki: i64 = @intFromFloat(k);
    const bits: u64 = @bitCast(ki + 1023);
    return p * @as(f64, @bitCast(bits << 52));
}

/// ln x = e ln2 + 2 atanh((m-1)/(m+1)), m em [1/√2, √2]
pub fn log(x: f64) f64 {
    if (!fast) return @log(x);
    if (!(x > 0)) return -std.math.inf(f64);
    const bits: u64 = @bitCast(x);
    var e: i64 = @as(i64, @intCast((bits >> 52) & 0x7ff)) - 1023;
    var m: f64 = @bitCast((bits & 0x000f_ffff_ffff_ffff) | 0x3ff0_0000_0000_0000);
    if (m > std.math.sqrt2) {
        m *= 0.5;
        e += 1;
    }
    const s = (m - 1.0) / (m + 1.0);
    const s2 = s * s;
    var p: f64 = 1.0 / 13.0;
    p = @mulAdd(f64, p, s2, 1.0 / 11.0);
    p = @mulAdd(f64, p, s2, 1.0 / 9.0);
    p = @mulAdd(f64, p, s2, 1.0 / 7.0);
    p = @mulAdd(f64, p, s2, 1.0 / 5.0);
    p = @mulAdd(f64, p, s2, 1.0 / 3.0);
    p = @mulAdd(f64, p, s2, 1.0);
    return @mulAdd(f64, @as(f64, @floatFromInt(e)), ln2, 2.0 * s * p);
}

pub fn pow(x: f64, y: f64) f64 {
    if (!fast) return std.math.pow(f64, x, y);
    return exp(y * log(x));
}

pub fn tanh(x: f64) f64 {
    if (!fast) return std.math.tanh(x);
    if (x > 20.0) return 1.0;
    if (x < -20.0) return -1.0;
    if (@abs(x) < 1e-4) return x * (1.0 - x * x / 3.0);
    const e2 = exp(2.0 * x);
    return (e2 - 1.0) / (e2 + 1.0);
}

pub inline fn sqrt(x: f64) f64 {
    return @sqrt(x);
}

pub inline fn hypot(a: f64, b: f64) f64 {
    return @sqrt(@mulAdd(f64, a, a, b * b));
}

// ---------------------------------------------------------------- saturações
pub inline fn sat(x: f64, l: f64) f64 {
    return std.math.clamp(x, -l, l);
}
pub inline fn lim(x: f64, lo: f64, hi: f64) f64 {
    return if (x < lo) lo else if (x > hi) hi else x;
}
pub inline fn sgn(x: f64) f64 {
    return if (x >= 0.0) 1.0 else -1.0;
}
pub fn wrap(a: f64) f64 {
    var r = a;
    while (r > pi) r -= two_pi;
    while (r < -pi) r += two_pi;
    return r;
}

// ---------------------------------------------------------------- testes
const testing = std.testing;

test "sincos contra std" {
    var x: f64 = -50.0;
    while (x < 50.0) : (x += 0.0137) {
        const sc = sincos(x);
        try testing.expectApproxEqAbs(@sin(x), sc.s, 1e-12);
        try testing.expectApproxEqAbs(@cos(x), sc.c, 1e-12);
    }
}

test "atan e atan2 contra std" {
    var x: f64 = -30.0;
    while (x < 30.0) : (x += 0.0071) {
        try testing.expectApproxEqAbs(std.math.atan(x), atan(x), 1e-8);
        try testing.expectApproxEqAbs(std.math.atan2(x, 1.3), atan2(x, 1.3), 1e-8);
        try testing.expectApproxEqAbs(std.math.atan2(1.3, x), atan2(1.3, x), 1e-8);
        try testing.expectApproxEqAbs(std.math.atan2(-0.7, x), atan2(-0.7, x), 1e-8);
    }
}

test "asin e acos" {
    var x: f64 = -1.0;
    while (x <= 1.0) : (x += 0.001) {
        try testing.expectApproxEqAbs(std.math.asin(x), asin(x), 1e-7);
        try testing.expectApproxEqAbs(std.math.acos(x), acos(x), 1e-7);
    }
}

test "exp, log, pow, tanh" {
    var x: f64 = -200.0;
    while (x < 200.0) : (x += 0.173) {
        const e = @exp(x);
        try testing.expectApproxEqRel(e, exp(x), 1e-10);
        try testing.expectApproxEqAbs(std.math.tanh(x), tanh(x), 1e-12);
    }
    var y: f64 = 1e-6;
    while (y < 1e6) : (y *= 1.37) {
        try testing.expectApproxEqAbs(@log(y), log(y), 1e-11);
        try testing.expectApproxEqRel(std.math.pow(f64, y, 1.0 / 7.0), pow(y, 1.0 / 7.0), 1e-10);
    }
}

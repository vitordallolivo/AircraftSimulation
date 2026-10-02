//! Funções matemáticas: tabelas (LUT) + aproximações polinomiais, e a referência da std.
//!
//!   lut.sincos   tabela de 2^bits pontos por volta (gerada em comptime) + correção de Taylor
//!                de 5ª/6ª ordem: com 256 pontos (2 KB, cabe folgado no cache L1) o erro é ~1e-15
//!   lut.atan     tabela de 256 pontos em [0,1] (2 KB) + correção de 2ª ordem (erro ~3e-9)
//!   lut.exp      2^k · e^r, |r| <= ln2/2, Horner de grau 10 (erro relativo ~1e-13)
//!   lut.log      expoente + série de atanh (erro ~1e-11)
//!   ref.*        as funções da std (para comparar)
//! As funções públicas (`sin`, `atan2`, ...) usam `lut` ou `ref` conforme `-Dfast_math`.
//! `SinLut(bits)` é genérico em comptime: o benchmark compara tamanhos de tabela.
const std = @import("std");
const build_options = @import("build_options");

pub const fast = build_options.fast_math;
pub const pi = std.math.pi;
const two_pi = 2.0 * pi;
const half_pi = 0.5 * pi;

pub const SinCos = struct { s: f64, c: f64 };

/// seno e cosseno por tabela de 2^bits pontos por volta
pub fn SinLut(comptime bits: u5) type {
    return struct {
        pub const n: usize = 1 << bits;
        pub const bytes = n * @sizeOf(f64);
        const mask: u64 = n - 1;
        const step = two_pi / @as(f64, n);
        const inv_step = @as(f64, n) / two_pi;

        /// gerada pelo compilador; fica em .rodata (alinhada em linha de cache)
        pub const table: [n]f64 align(64) = blk: {
            @setEvalBranchQuota(400_000);
            var t: [n]f64 = undefined;
            for (0..n) |i| t[i] = @sin(@as(f64, @floatFromInt(i)) * step);
            break :blk t;
        };

        /// x = i·h + d, |d| <= h/2:  sin(x) = sin(ih) cos(d) + cos(ih) sin(d)
        pub inline fn sincos(x: f64) SinCos {
            const k = @round(x * inv_step);
            const d = @mulAdd(f64, -k, step, x);
            const ki: i64 = @intFromFloat(k);
            const idx: u64 = @as(u64, @bitCast(ki)) & mask;
            const s0 = table[idx];
            const c0 = table[(idx + n / 4) & mask];
            const d2 = d * d;
            // cos d = 1 − d²/2 + d⁴/24 − d⁶/720 ;  sin d = d (1 − d²/6 + d⁴/120)
            const cd = 1.0 - d2 * (0.5 - d2 * (1.0 / 24.0 - d2 * (1.0 / 720.0)));
            const sd = d * (1.0 - d2 * (1.0 / 6.0 - d2 * (1.0 / 120.0)));
            return .{ .s = @mulAdd(f64, s0, cd, c0 * sd), .c = @mulAdd(f64, c0, cd, -s0 * sd) };
        }
    };
}

/// implementação por tabelas e polinômios
pub const lut = struct {
    pub const Sin = SinLut(8); // 256 pontos = 2 KB (ver bench: tabelas maiores não ajudam)

    pub inline fn sincos(x: f64) SinCos {
        return Sin.sincos(x);
    }

    const atan_n = 256;
    pub const atan_table: [atan_n + 1]f64 align(64) = blk: {
        @setEvalBranchQuota(100_000);
        var t: [atan_n + 1]f64 = undefined;
        for (0..atan_n + 1) |i| t[i] = std.math.atan(@as(f64, @floatFromInt(i)) / atan_n);
        break :blk t;
    };

    /// atan em [0, 1]: atan(a + d) ≈ atan(a) + d g − a d² g²,  g = 1/(1 + a²)
    inline fn atan01(z: f64) f64 {
        const k = @round(z * atan_n);
        const a = k * (1.0 / @as(f64, atan_n));
        const d = z - a;
        const g = 1.0 / @mulAdd(f64, a, a, 1.0);
        const i: usize = @intFromFloat(k);
        return atan_table[i] + d * g * (1.0 - a * d * g);
    }

    pub fn atan(x: f64) f64 {
        const ax = @abs(x);
        const r = if (ax <= 1.0) atan01(ax) else half_pi - atan01(1.0 / ax);
        return if (x < 0) -r else r;
    }

    pub fn atan2(y: f64, x: f64) f64 {
        const ax = @abs(x);
        const ay = @abs(y);
        if (ax == 0 and ay == 0) return 0.0;
        var r = if (ay <= ax) atan01(ay / ax) else half_pi - atan01(ax / ay);
        if (x < 0) r = pi - r;
        return if (y < 0) -r else r;
    }

    pub fn exp(x: f64) f64 {
        const xc = std.math.clamp(x, -700.0, 700.0);
        const k = @round(xc * (1.0 / std.math.ln2));
        const r = @mulAdd(f64, -k, std.math.ln2, xc);
        // Horner com coeficientes 1/n! gerados em comptime
        const coef = comptime blk: {
            var c: [11]f64 = undefined;
            var f: f64 = 1;
            for (0..11) |i| {
                if (i > 0) f *= @floatFromInt(i);
                c[i] = 1.0 / f;
            }
            break :blk c;
        };
        var p: f64 = coef[10];
        inline for (1..11) |j| p = @mulAdd(f64, p, r, coef[10 - j]);
        const ki: i64 = @intFromFloat(k);
        const bits: u64 = @bitCast(ki + 1023);
        return p * @as(f64, @bitCast(bits << 52));
    }

    pub fn log(x: f64) f64 {
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
        inline for (.{ 11.0, 9.0, 7.0, 5.0, 3.0, 1.0 }) |q| p = @mulAdd(f64, p, s2, 1.0 / q);
        return @mulAdd(f64, @as(f64, @floatFromInt(e)), std.math.ln2, 2.0 * s * p);
    }

    pub fn tanh(x: f64) f64 {
        if (x > 20.0) return 1.0;
        if (x < -20.0) return -1.0;
        if (@abs(x) < 1e-4) return x * (1.0 - x * x / 3.0);
        const e2 = lut.exp(2.0 * x);
        return (e2 - 1.0) / (e2 + 1.0);
    }
};

/// referência: std
pub const ref = struct {
    pub inline fn sincos(x: f64) SinCos {
        return .{ .s = @sin(x), .c = @cos(x) };
    }
    pub fn atan(x: f64) f64 {
        return std.math.atan(x);
    }
    pub fn atan2(y: f64, x: f64) f64 {
        return std.math.atan2(y, x);
    }
    pub fn exp(x: f64) f64 {
        return @exp(x);
    }
    pub fn log(x: f64) f64 {
        return @log(x);
    }
    pub fn tanh(x: f64) f64 {
        return std.math.tanh(x);
    }
};

const impl = if (fast) lut else ref;

pub inline fn sincos(x: f64) SinCos {
    return impl.sincos(x);
}
pub inline fn sin(x: f64) f64 {
    return impl.sincos(x).s;
}
pub inline fn cos(x: f64) f64 {
    return impl.sincos(x).c;
}
pub fn tan(x: f64) f64 {
    const sc = impl.sincos(x);
    return sc.s / sc.c;
}
pub fn atan(x: f64) f64 {
    return impl.atan(x);
}
pub fn atan2(y: f64, x: f64) f64 {
    return impl.atan2(y, x);
}
pub fn asin(x: f64) f64 {
    const c = std.math.clamp(x, -1.0, 1.0);
    return impl.atan2(c, @sqrt(@max(0.0, 1.0 - c * c)));
}
pub fn acos(x: f64) f64 {
    const c = std.math.clamp(x, -1.0, 1.0);
    return impl.atan2(@sqrt(@max(0.0, 1.0 - c * c)), c);
}
pub fn exp(x: f64) f64 {
    return impl.exp(x);
}
pub fn log(x: f64) f64 {
    return impl.log(x);
}
pub fn pow(x: f64, y: f64) f64 {
    if (!fast) return std.math.pow(f64, x, y);
    return lut.exp(y * lut.log(x));
}
pub fn tanh(x: f64) f64 {
    return impl.tanh(x);
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

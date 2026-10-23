//! Funções matemáticas: tabelas (LUT) + aproximações polinomiais, e a referência da std.
//!
//!   lut.sincos   tabela de 2^bits pontos por volta (gerada em comptime) + correção de Taylor
//!                de 5ª/6ª ordem: com 256 pontos (2 KB, cabe folgado no cache L1) o erro é ~1e-15
//!   lut.atan     tabela de 256 pontos em [0,1] (2 KB) + correção de 2ª ordem (erro ~3e-9)
//!   lut.exp      2^k · e^r, |r| <= ln2/2, Horner de grau 10 (erro relativo ~1e-13)
//!   lut.log      expoente + série de atanh (erro ~1e-11)
//!   minimax      sin/cos sem tabela: redução ao quadrante + polinômios minimax (Schlör), erro ~2e-16
//!                (`-Dopt=minimax` põe no lugar da tabela)
//!   ref.*        as funções da std (para comparar)
//! As funções públicas (`sin`, `atan2`, ...) usam `lut` ou `ref` conforme `-Dfast_math`.
//! `SinLut(bits)` é genérico em comptime: o benchmark compara tamanhos de tabela.
const std = @import("std");
const build_options = @import("build_options");

pub const fast = build_options.fast_math;
/// otimizações em avaliação (`-Dopt`, soma dos bits; 0 = como sempre). Os nomes e os bits estão em `opt.zig`
pub const Opt = @import("../opt.zig").Opt;
pub const opt: u8 = build_options.opt;
/// a otimização `o` está ligada neste build? (comptime: o ramo desligado nem é compilado)
pub inline fn optOn(comptime o: Opt) bool {
    return comptime o.in(opt);
}
/// modo de ponto flutuante das funções quentes (`@setFloatMode(fm.float_mode)`): strict é o de sempre
pub const float_mode: std.builtin.FloatMode = if (optOn(.floatmode)) .optimized else .strict;
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
        /// (inline forçado, como sempre; com `-Dopt=noinline` o compilador decide)
        pub inline fn sincos(x: f64) SinCos {
            return @call(if (optOn(.@"noinline")) .auto else .always_inline, body, .{x});
        }

        fn body(x: f64) SinCos {
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
        return if (optOn(.minimax)) minimax.sincos(x) else Sin.sincos(x);
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
        return expWith(optOn(.estrin), x);
    }

    /// e^x = 2^k · e^r; o polinômio de e^r por Horner (o de sempre) ou por Estrin (`-Dopt=estrin`)
    pub fn expWith(comptime estrin: bool, x: f64) f64 {
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
        const p = if (estrin) estrin10(coef, r) else horner10(coef, r);
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

/// Horner: p = c0 + r(c1 + r(c2 + ...)), 10 multiplicações-somas em cadeia (cada uma espera a anterior)
inline fn horner10(c: [11]f64, r: f64) f64 {
    var p: f64 = c[10];
    inline for (1..11) |j| p = @mulAdd(f64, p, r, c[10 - j]);
    return p;
}

/// Estrin (Knuth, TAOCP v. 2, 3ª ed., §4.6.4): agrupa os termos em pares (c_2i + c_2i+1·r) e soma os pares com
/// r², r⁴, r⁸. Mesmo polinômio, mesmas contas em número, mas a cadeia de dependência cai de 10 para 4 passos: o
/// processador faz os pares ao mesmo tempo. Os arredondamentos mudam (resultado não é bit a bit o do Horner).
inline fn estrin10(c: [11]f64, r: f64) f64 {
    const r2 = r * r;
    const r4 = r2 * r2;
    const r8 = r4 * r4;
    const a0 = @mulAdd(f64, c[1], r, c[0]);
    const a1 = @mulAdd(f64, c[3], r, c[2]);
    const a2 = @mulAdd(f64, c[5], r, c[4]);
    const a3 = @mulAdd(f64, c[7], r, c[6]);
    const a4 = @mulAdd(f64, c[9], r, c[8]);
    const b0 = @mulAdd(f64, a1, r2, a0);
    const b1 = @mulAdd(f64, a3, r2, a2);
    const b2 = @mulAdd(f64, c[10], r2, a4);
    return @mulAdd(f64, b2, r8, @mulAdd(f64, b1, r4, b0));
}

/// seno e cosseno sem tabela. Fonte dos coeficientes: L. Schlör, "Fast MiniMax Polynomial Approximations of Sine
/// and Cosine", https://gist.github.com/publik-void/067f7f2fef32dbe5c27d6e215f824c91 — "Sin, rel. error minimized,
/// degree 15" (erro relativo máx. 1,42e-16) e "Cos, rel. error minimized, degree 16" (1,76e-17), válidos no
/// primeiro quarto de período [0, π/2]. Como os polinômios são ímpar (sin) e par (cos), valem em [−π/4, π/4].
/// Redução: x = k·π/2 + r, |r| <= π/4 (π/2 em duas partes, Cody e Waite, para não perder dígitos em r); o
/// quadrante k mod 4 troca seno com cosseno e o sinal: 0 (s, c), 1 (c, −s), 2 (−s, −c), 3 (−c, s).
pub const minimax = struct {
    const sin_c = [8]f64{
        0.99999999999999985783856947280351013,     -0.166666666666659653164780128859839316,
        0.00833333333327592139676057538106745659,  -0.000198412698232225093689107237380802637,
        2.75573164212929639596445204076151988e-6,  -2.5051870883490902518590017165648945e-8,
        1.6047844633018114428263064708844387e-10, -7.37066278281678179293546235379257048e-13,
    };
    const cos_c = [9]f64{
        0.99999999999999998243004448007448662,       -0.499999999999999105881272803474436268,
        0.041666666666658914344068844317924505,      -0.00138888888886231429175747130897185107,
        0.0000248015872549765577961155967511699095, -2.75573145508960795189972565635584642e-7,
        2.08764776731016710219609723288490596e-9,    -1.14608862231521440480830153964369191e-11,
        4.58927688754481747776178904291483144e-14,
    };
    // π/2 = hi + lo: hi é o f64 mais próximo, lo o resto (k·hi é exato para |k| < 2^20)
    const half_pi_hi: f64 = half_pi;
    const half_pi_lo: f64 = 6.123233995736766e-17;

    pub fn sincos(x: f64) SinCos {
        const k = @round(x * (2.0 / pi));
        const r = @mulAdd(f64, -k, half_pi_lo, @mulAdd(f64, -k, half_pi_hi, x));
        const r2 = r * r;
        var ps: f64 = sin_c[7];
        inline for (1..8) |j| ps = @mulAdd(f64, ps, r2, sin_c[7 - j]);
        var pc: f64 = cos_c[8];
        inline for (1..9) |j| pc = @mulAdd(f64, pc, r2, cos_c[8 - j]);
        const s = r * ps;
        // quadrante sem desvio (com entradas aleatórias o desvio erra a previsão): máscaras sobre os bits
        const ki: i64 = @intFromFloat(k);
        const q: u64 = @bitCast(ki);
        const swap: u64 = 0 -% (q & 1); // quadrantes 1 e 3: seno ↔ cosseno (tudo 1 ou tudo 0)
        const sb: u64 = @bitCast(s);
        const cb: u64 = @bitCast(pc);
        const a = (sb & ~swap) | (cb & swap);
        const b = (cb & ~swap) | (sb & swap);
        const neg_s = (q >> 1 & 1) << 63; // sinal do seno: negativo nos quadrantes 2 e 3
        const neg_c = ((q ^ (q >> 1)) & 1) << 63; // sinal do cosseno: negativo nos quadrantes 1 e 2
        return .{ .s = @bitCast(a ^ neg_s), .c = @bitCast(b ^ neg_c) };
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
    if (optOn(.logstd)) return ref.log(x); // no bench, o log da tabela é mais lento que o da std
    return impl.log(x);
}
pub fn pow(x: f64, y: f64) f64 {
    if (!fast) return std.math.pow(f64, x, y);
    return lut.exp(y * (if (optOn(.logstd)) ref.log(x) else lut.log(x)));
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

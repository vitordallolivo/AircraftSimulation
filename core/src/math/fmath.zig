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
/// a otimização `optimization` está ligada neste build? (comptime: o ramo desligado nem é compilado)
pub inline fn optOn(comptime optimization: Opt) bool {
    return comptime optimization.in(opt);
}
/// modo de ponto flutuante das funções quentes (`@setFloatMode(fmath.float_mode)`): strict é o de sempre
pub const float_mode: std.builtin.FloatMode = if (optOn(.floatmode)) .optimized else .strict;
pub const pi = std.math.pi;
const two_pi = 2.0 * pi;
const half_pi = 0.5 * pi;

pub const SinCos = struct { s: f64, c: f64 };

/// seno e cosseno por tabela de 2^bits pontos por volta
pub fn SinLut(comptime bits: u5) type {
    return struct {
        pub const points: usize = 1 << bits;
        pub const bytes = points * @sizeOf(f64);
        const mask: u64 = points - 1;
        const step = two_pi / @as(f64, points);
        const inv_step = @as(f64, points) / two_pi;

        /// gerada pelo compilador; fica em .rodata (alinhada em linha de cache)
        pub const table: [points]f64 align(64) = blk: {
            @setEvalBranchQuota(400_000);
            var values: [points]f64 = undefined;
            for (0..points) |i| values[i] = @sin(@as(f64, @floatFromInt(i)) * step);
            break :blk values;
        };

        /// sin e cos do ângulo x = i·h + d, |d| <= h/2:  sin(x) = sin(ih) cos(d) + cos(ih) sin(d)
        /// (inline forçado, como sempre; com `-Dopt=noinline` o compilador decide)
        pub inline fn sincos(angle: f64) SinCos {
            return @call(if (optOn(.@"noinline")) .auto else .always_inline, body, .{angle});
        }

        fn body(angle: f64) SinCos {
            const steps = @round(angle * inv_step);
            const offset = @mulAdd(f64, -steps, step, angle);
            // NaN ou infinito (estado que divergiu): sem isto o @intFromFloat entra em pane; o resultado sai NaN
            const steps_int: i64 = if (@abs(steps) < 9.0e18) @intFromFloat(steps) else 0;
            const index: u64 = @as(u64, @bitCast(steps_int)) & mask;
            const sin0 = table[index];
            const cos0 = table[(index + points / 4) & mask];
            const offset2 = offset * offset;
            // cos d = 1 − d²/2 + d⁴/24 − d⁶/720 ;  sin d = d (1 − d²/6 + d⁴/120)
            const cos_offset = 1.0 - offset2 * (0.5 - offset2 * (1.0 / 24.0 - offset2 * (1.0 / 720.0)));
            const sin_offset = offset * (1.0 - offset2 * (1.0 / 6.0 - offset2 * (1.0 / 120.0)));
            return .{ .s = @mulAdd(f64, sin0, cos_offset, cos0 * sin_offset), .c = @mulAdd(f64, cos0, cos_offset, -sin0 * sin_offset) };
        }
    };
}

/// implementação por tabelas e polinômios
pub const lut = struct {
    pub const Sin = SinLut(8); // 256 pontos = 2 KB (ver bench: tabelas maiores não ajudam)

    /// seno e cosseno do ângulo (rad): pela tabela ou, com `-Dopt=minimax`, pelos polinômios
    pub inline fn sincos(angle: f64) SinCos {
        return if (optOn(.minimax)) minimax.sincos(angle) else Sin.sincos(angle);
    }

    const atan_n = 256;
    pub const atan_table: [atan_n + 1]f64 align(64) = blk: {
        @setEvalBranchQuota(100_000);
        var values: [atan_n + 1]f64 = undefined;
        for (0..atan_n + 1) |i| values[i] = std.math.atan(@as(f64, @floatFromInt(i)) / atan_n);
        break :blk values;
    };

    /// atan de `ratio` em [0, 1]: atan(a + d) ≈ atan(a) + d g − a d² g²,  g = 1/(1 + a²), a = o nó da tabela
    inline fn atan01(ratio: f64) f64 {
        const node = @round(ratio * atan_n);
        const node_ratio = node * (1.0 / @as(f64, atan_n));
        const offset = ratio - node_ratio;
        const slope = 1.0 / @mulAdd(f64, node_ratio, node_ratio, 1.0);
        const index: usize = if (node >= 0 and node <= atan_n) @intFromFloat(node) else 0; // NaN: sem pane, o resultado sai NaN
        return atan_table[index] + offset * slope * (1.0 - node_ratio * offset * slope);
    }

    /// arco tangente (rad) pela tabela
    pub fn atan(value: f64) f64 {
        const magnitude = @abs(value);
        const result = if (magnitude <= 1.0) atan01(magnitude) else half_pi - atan01(1.0 / magnitude);
        return if (value < 0) -result else result;
    }

    /// ângulo (rad, em [−π, π]) do ponto (adjacent, opposite), pela tabela
    pub fn atan2(opposite: f64, adjacent: f64) f64 {
        const abs_adjacent = @abs(adjacent);
        const abs_opposite = @abs(opposite);
        if (abs_adjacent == 0 and abs_opposite == 0) return 0.0;
        var result = if (abs_opposite <= abs_adjacent) atan01(abs_opposite / abs_adjacent) else half_pi - atan01(abs_adjacent / abs_opposite);
        if (adjacent < 0) result = pi - result;
        return if (opposite < 0) -result else result;
    }

    /// e^value por redução a 2^k · e^r e polinômio
    pub fn exp(value: f64) f64 {
        return expWith(optOn(.estrin), value);
    }

    /// e^x = 2^k · e^r; o polinômio de e^r por Horner (o de sempre) ou por Estrin (`-Dopt=estrin`)
    pub fn expWith(comptime estrin: bool, value: f64) f64 {
        const clamped = std.math.clamp(value, -700.0, 700.0);
        const power_of_two = @round(clamped * (1.0 / std.math.ln2));
        const remainder = @mulAdd(f64, -power_of_two, std.math.ln2, clamped);
        // Horner com coeficientes 1/n! gerados em comptime
        const coef = comptime blk: {
            var values: [11]f64 = undefined;
            var factorial: f64 = 1;
            for (0..11) |i| {
                if (i > 0) factorial *= @floatFromInt(i);
                values[i] = 1.0 / factorial;
            }
            break :blk values;
        };
        const poly = if (estrin) estrin10(coef, remainder) else horner10(coef, remainder);
        const power_int: i64 = if (@abs(power_of_two) < 4096) @intFromFloat(power_of_two) else 0; // NaN: sem pane, o resultado sai NaN
        const bits: u64 = @bitCast(power_int + 1023);
        return poly * @as(f64, @bitCast(bits << 52));
    }

    /// logaritmo natural pelo expoente do f64 e a série de atanh; −inf para value ≤ 0
    pub fn log(value: f64) f64 {
        if (!(value > 0)) return -std.math.inf(f64);
        const bits: u64 = @bitCast(value);
        var exponent: i64 = @as(i64, @intCast((bits >> 52) & 0x7ff)) - 1023;
        var mantissa: f64 = @bitCast((bits & 0x000f_ffff_ffff_ffff) | 0x3ff0_0000_0000_0000);
        if (mantissa > std.math.sqrt2) {
            mantissa *= 0.5;
            exponent += 1;
        }
        const atanh_arg = (mantissa - 1.0) / (mantissa + 1.0);
        const atanh_arg2 = atanh_arg * atanh_arg;
        var series: f64 = 1.0 / 13.0;
        inline for (.{ 11.0, 9.0, 7.0, 5.0, 3.0, 1.0 }) |odd| series = @mulAdd(f64, series, atanh_arg2, 1.0 / odd);
        return @mulAdd(f64, @as(f64, @floatFromInt(exponent)), std.math.ln2, 2.0 * atanh_arg * series);
    }

    /// tangente hiperbólica pelo exp da tabela
    pub fn tanh(value: f64) f64 {
        if (value > 20.0) return 1.0;
        if (value < -20.0) return -1.0;
        if (@abs(value) < 1e-4) return value * (1.0 - value * value / 3.0);
        const exp2x = lut.exp(2.0 * value);
        return (exp2x - 1.0) / (exp2x + 1.0);
    }
};

/// referência: std
pub const ref = struct {
    /// seno e cosseno da std
    pub inline fn sincos(angle: f64) SinCos {
        return .{ .s = @sin(angle), .c = @cos(angle) };
    }
    /// arco tangente da std
    pub fn atan(value: f64) f64 {
        return std.math.atan(value);
    }
    /// atan2 da std
    pub fn atan2(opposite: f64, adjacent: f64) f64 {
        return std.math.atan2(opposite, adjacent);
    }
    /// exp da std
    pub fn exp(value: f64) f64 {
        return @exp(value);
    }
    /// log da std
    pub fn log(value: f64) f64 {
        return @log(value);
    }
    /// tanh da std
    pub fn tanh(value: f64) f64 {
        return std.math.tanh(value);
    }
};

/// Horner: p = c0 + r(c1 + r(c2 + ...)), 10 multiplicações-somas em cadeia (cada uma espera a anterior)
inline fn horner10(coefs: [11]f64, variable: f64) f64 {
    var result: f64 = coefs[10];
    inline for (1..11) |j| result = @mulAdd(f64, result, variable, coefs[10 - j]);
    return result;
}

/// Estrin (Knuth, TAOCP v. 2, 3ª ed., §4.6.4): agrupa os termos em pares (c_2i + c_2i+1·r) e soma os pares com
/// r², r⁴, r⁸. Mesmo polinômio, mesmas contas em número, mas a cadeia de dependência cai de 10 para 4 passos: o
/// processador faz os pares ao mesmo tempo. Os arredondamentos mudam (resultado não é bit a bit o do Horner).
inline fn estrin10(coefs: [11]f64, variable: f64) f64 {
    const variable2 = variable * variable;
    const variable4 = variable2 * variable2;
    const variable8 = variable4 * variable4;
    const pair0 = @mulAdd(f64, coefs[1], variable, coefs[0]);
    const pair1 = @mulAdd(f64, coefs[3], variable, coefs[2]);
    const pair2 = @mulAdd(f64, coefs[5], variable, coefs[4]);
    const pair3 = @mulAdd(f64, coefs[7], variable, coefs[6]);
    const pair4 = @mulAdd(f64, coefs[9], variable, coefs[8]);
    const quad0 = @mulAdd(f64, pair1, variable2, pair0);
    const quad1 = @mulAdd(f64, pair3, variable2, pair2);
    const quad2 = @mulAdd(f64, coefs[10], variable2, pair4);
    return @mulAdd(f64, quad2, variable8, @mulAdd(f64, quad1, variable4, quad0));
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

    /// seno e cosseno do ângulo (rad) por redução ao quadrante e polinômios minimax
    pub fn sincos(angle: f64) SinCos {
        const quadrant_f = @round(angle * (2.0 / pi));
        const reduced = @mulAdd(f64, -quadrant_f, half_pi_lo, @mulAdd(f64, -quadrant_f, half_pi_hi, angle));
        const reduced2 = reduced * reduced;
        var sin_poly: f64 = sin_c[7];
        inline for (1..8) |j| sin_poly = @mulAdd(f64, sin_poly, reduced2, sin_c[7 - j]);
        var cos_poly: f64 = cos_c[8];
        inline for (1..9) |j| cos_poly = @mulAdd(f64, cos_poly, reduced2, cos_c[8 - j]);
        const sin_reduced = reduced * sin_poly;
        // quadrante sem desvio (com entradas aleatórias o desvio erra a previsão): máscaras sobre os bits
        const quadrant_int: i64 = if (@abs(quadrant_f) < 9.0e18) @intFromFloat(quadrant_f) else 0; // NaN: sem pane, o resultado sai NaN
        const quadrant: u64 = @bitCast(quadrant_int);
        const swap: u64 = 0 -% (quadrant & 1); // quadrantes 1 e 3: seno ↔ cosseno (tudo 1 ou tudo 0)
        const sin_bits: u64 = @bitCast(sin_reduced);
        const cos_bits: u64 = @bitCast(cos_poly);
        const sin_out = (sin_bits & ~swap) | (cos_bits & swap);
        const cos_out = (cos_bits & ~swap) | (sin_bits & swap);
        const neg_s = (quadrant >> 1 & 1) << 63; // sinal do seno: negativo nos quadrantes 2 e 3
        const neg_c = ((quadrant ^ (quadrant >> 1)) & 1) << 63; // sinal do cosseno: negativo nos quadrantes 1 e 2
        return .{ .s = @bitCast(sin_out ^ neg_s), .c = @bitCast(cos_out ^ neg_c) };
    }
};

const impl = if (fast) lut else ref;

/// seno e cosseno do ângulo (rad)
pub inline fn sincos(angle: f64) SinCos {
    return impl.sincos(angle);
}
/// seno do ângulo (rad)
pub inline fn sin(angle: f64) f64 {
    return impl.sincos(angle).s;
}
/// cosseno do ângulo (rad)
pub inline fn cos(angle: f64) f64 {
    return impl.sincos(angle).c;
}
/// tangente do ângulo (rad)
pub fn tan(angle: f64) f64 {
    const sin_cos = impl.sincos(angle);
    return sin_cos.s / sin_cos.c;
}
/// arco tangente (rad)
pub fn atan(value: f64) f64 {
    return impl.atan(value);
}
/// ângulo (rad, em [−π, π]) do ponto (adjacent, opposite)
pub fn atan2(opposite: f64, adjacent: f64) f64 {
    return impl.atan2(opposite, adjacent);
}
/// arco seno (rad); a entrada é limitada a [−1, 1]
pub fn asin(value: f64) f64 {
    const clamped = std.math.clamp(value, -1.0, 1.0);
    return impl.atan2(clamped, @sqrt(@max(0.0, 1.0 - clamped * clamped)));
}
/// arco cosseno (rad); a entrada é limitada a [−1, 1]
pub fn acos(value: f64) f64 {
    const clamped = std.math.clamp(value, -1.0, 1.0);
    return impl.atan2(@sqrt(@max(0.0, 1.0 - clamped * clamped)), clamped);
}
/// e^value
pub fn exp(value: f64) f64 {
    return impl.exp(value);
}
/// logaritmo natural
pub fn log(value: f64) f64 {
    if (optOn(.logstd)) return ref.log(value); // no bench, o log da tabela é mais lento que o da std
    return impl.log(value);
}
/// base^exponent (por exp e log)
pub fn pow(base: f64, exponent: f64) f64 {
    if (!fast) return std.math.pow(f64, base, exponent);
    return lut.exp(exponent * (if (optOn(.logstd)) ref.log(base) else lut.log(base)));
}
/// tangente hiperbólica
pub fn tanh(value: f64) f64 {
    return impl.tanh(value);
}
/// raiz quadrada
pub inline fn sqrt(value: f64) f64 {
    return @sqrt(value);
}
/// √(first² + second²)
pub inline fn hypot(first: f64, second: f64) f64 {
    return @sqrt(@mulAdd(f64, first, first, second * second));
}

// ---------------------------------------------------------------- saturações
/// value limitado a [−limit, limit]
pub inline fn sat(value: f64, limit: f64) f64 {
    return std.math.clamp(value, -limit, limit);
}
/// value limitado a [low, high]
pub inline fn lim(value: f64, low: f64, high: f64) f64 {
    return if (value < low) low else if (value > high) high else value;
}
/// sinal: 1 para value ≥ 0, −1 para negativo
pub inline fn sgn(value: f64) f64 {
    return if (value >= 0.0) 1.0 else -1.0;
}
/// o ângulo levado para [−π, π] (NaN e infinito passam iguais)
pub fn wrap(angle: f64) f64 {
    if (!std.math.isFinite(angle)) return angle; // NaN ou infinito: os laços abaixo nunca terminariam
    var wrapped = angle;
    if (@abs(wrapped) > 64 * pi) wrapped -= two_pi * @round(wrapped / two_pi); // ângulo enorme: de uma vez, sem mil voltas
    while (wrapped > pi) wrapped -= two_pi;
    while (wrapped < -pi) wrapped += two_pi;
    return wrapped;
}

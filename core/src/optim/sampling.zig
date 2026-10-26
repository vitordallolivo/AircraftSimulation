//! Amostragem do espaço de busca: de onde nascem os primeiros indivíduos das buscas contínuas do aeroopt.
//!
//! Sorteados um a um, uniformes, poucos pontos num espaço de muitas variáveis se amontoam: em 12 variáveis com 8
//! indivíduos, é comum duas ou três variáveis ficarem com todos os valores numa metade da faixa, e a busca nunca olha
//! a outra. Se o mínimo bom de f(x, u) está lá, a rodada fica presa num mínimo local perto de x0.
//!
//! O hipercubo latino resolve isso variável por variável. Com m pontos, a faixa de cada variável é cortada em m fatias
//! iguais e cada fatia recebe exatamente um ponto; a ordem das fatias é uma permutação sorteada por variável e, dentro
//! da fatia, a posição é sorteada:
//!
//!   x_ij = (π_j(i) + U_ij) / m,   U_ij ~ U(0, 1)
//!
//! (McKay, Beckman e Conover, "A comparison of three methods for selecting values of input variables in the analysis
//! of output from a computer code", Technometrics 21(2), 239–245, 1979; a conferir no PDF). Assim toda variável é
//! varrida de ponta a ponta, com qualquer m.
//!
//! Um hipercubo latino ainda pode sair ruim no conjunto (os pontos todos numa diagonal, por exemplo). Por isso se
//! sorteiam `tries` hipercubos e fica o de maior distância mínima entre dois pontos (o critério maximin; Morris e
//! Mitchell, "Exploratory designs for computational experiments", J. Statistical Planning and Inference 43, 381–402,
//! 1995; a conferir no PDF). Os sorteios saem da semente: a mesma entrada dá os mesmos pontos.
const std = @import("std");

pub const max_n = 32;
pub const max_m = 256;

/// um hipercubo latino em [0, 1]ⁿ (`out`: m × n)
fn latin(r: std.Random, n: usize, m: usize, out: []f64) void {
    var perm: [max_m]usize = undefined;
    const mf: f64 = @floatFromInt(m);
    for (0..n) |j| {
        for (0..m) |i| perm[i] = i;
        r.shuffle(usize, perm[0..m]);
        for (0..m) |i| out[i * n + j] = (@as(f64, @floatFromInt(perm[i])) + r.float(f64)) / mf;
    }
}

/// a menor distância (ao quadrado) entre dois pontos de `pts` (m × n)
pub fn minDist2(n: usize, m: usize, pts: []const f64) f64 {
    var best = std.math.inf(f64);
    for (0..m) |a| {
        for (a + 1..m) |b| {
            var s: f64 = 0;
            for (0..n) |j| {
                const d = pts[a * n + j] - pts[b * n + j];
                s += d * d;
            }
            best = @min(best, s);
        }
    }
    return best;
}

/// m pontos em [0, 1]ⁿ por hipercubo latino; com `tries` > 1, o de maior distância mínima entre `tries` sorteados
/// (`out`: m × n). `false` se n, m ou tries não cabem
pub fn lhs(n: usize, m: usize, tries: usize, seed: u64, out: []f64) bool {
    if (n == 0 or n > max_n or m == 0 or m > max_m or tries == 0) return false;
    var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% 1);
    const r = prng.random();
    var cand: [max_n * max_m]f64 = undefined;
    latin(r, n, m, out[0 .. m * n]);
    var best = minDist2(n, m, out);
    for (1..tries) |_| {
        latin(r, n, m, cand[0 .. m * n]);
        const d = minDist2(n, m, cand[0 .. m * n]);
        if (d > best) {
            best = d;
            @memcpy(out[0 .. m * n], cand[0 .. m * n]);
        }
    }
    return true;
}

test "hipercubo latino: cada fatia de cada variável tem exatamente um ponto" {
    const n = 5;
    const m = 8;
    var x: [n * m]f64 = undefined;
    try std.testing.expect(lhs(n, m, 1, 3, &x));
    for (0..n) |j| {
        var hit: [m]bool = @splat(false);
        for (0..m) |i| {
            const v = x[i * n + j];
            try std.testing.expect(v >= 0 and v < 1);
            const k: usize = @intFromFloat(v * m);
            try std.testing.expect(!hit[k]);
            hit[k] = true;
        }
    }
}

test "hipercubo latino: mesma semente, mesmos pontos; o maximin não afasta menos que um sorteio só" {
    const n = 12;
    const m = 8;
    var a: [n * m]f64 = undefined;
    var b: [n * m]f64 = undefined;
    var one: [n * m]f64 = undefined;
    try std.testing.expect(lhs(n, m, 20, 7, &a));
    try std.testing.expect(lhs(n, m, 20, 7, &b));
    try std.testing.expectEqualSlices(f64, &a, &b);
    try std.testing.expect(lhs(n, m, 1, 7, &one));
    try std.testing.expect(minDist2(n, m, &a) >= minDist2(n, m, &one));
    try std.testing.expect(!lhs(0, m, 1, 7, &a));
    try std.testing.expect(!lhs(n, m, 0, 7, &a));
}

test "hipercubo latino cobre a faixa melhor que o sorteio uniforme (12 variáveis, 8 pontos)" {
    // a pior variável: a maior fatia de 1/8 vazia. No latino, nenhuma; no uniforme, em média várias
    const n = 12;
    const m = 8;
    var x: [n * m]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    var empty_u: usize = 0;
    var empty_l: usize = 0;
    for (0..20) |s| {
        for (&x) |*v| v.* = r.float(f64);
        empty_u += emptySlices(n, m, &x);
        try std.testing.expect(lhs(n, m, 1, s, &x));
        empty_l += emptySlices(n, m, &x);
    }
    try std.testing.expectEqual(@as(usize, 0), empty_l);
    try std.testing.expect(empty_u > 20 * n); // ~ (7/8)⁸ ≈ 34 % das fatias vazias: ~2,7 por variável
}

fn emptySlices(n: usize, m: usize, x: []const f64) usize {
    var e: usize = 0;
    for (0..n) |j| {
        var hit: [max_m]bool = @splat(false);
        for (0..m) |i| hit[@min(m - 1, @as(usize, @intFromFloat(x[i * n + j] * @as(f64, @floatFromInt(m)))))] = true;
        for (0..m) |k| e += @intFromBool(!hit[k]);
    }
    return e;
}

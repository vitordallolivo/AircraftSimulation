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

/// um hipercubo latino em [0, 1]^dims (`out`: points × dims)
fn latin(random: std.Random, dims: usize, points: usize, out: []f64) void {
    var perm: [max_m]usize = undefined;
    const points_f: f64 = @floatFromInt(points);
    for (0..dims) |j| {
        for (0..points) |i| perm[i] = i;
        random.shuffle(usize, perm[0..points]);
        for (0..points) |i| out[i * dims + j] = (@as(f64, @floatFromInt(perm[i])) + random.float(f64)) / points_f;
    }
}

/// a menor distância (ao quadrado) entre dois pontos de `pts` (points × dims)
pub fn minDist2(dims: usize, points: usize, pts: []const f64) f64 {
    var best = std.math.inf(f64);
    for (0..points) |point_a| {
        for (point_a + 1..points) |point_b| {
            var dist2: f64 = 0;
            for (0..dims) |j| {
                const delta = pts[point_a * dims + j] - pts[point_b * dims + j];
                dist2 += delta * delta;
            }
            best = @min(best, dist2);
        }
    }
    return best;
}

/// `points` pontos em [0, 1]^dims por hipercubo latino; com `tries` > 1, o de maior distância mínima entre `tries` sorteados
/// (`out`: points × dims). `false` se dims, points ou tries não cabem
pub fn lhs(dims: usize, points: usize, tries: usize, seed: u64, out: []f64) bool {
    if (dims == 0 or dims > max_n or points == 0 or points > max_m or tries == 0) return false;
    var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% 1);
    const random = prng.random();
    var cand: [max_n * max_m]f64 = undefined;
    latin(random, dims, points, out[0 .. points * dims]);
    var best = minDist2(dims, points, out);
    for (1..tries) |_| {
        latin(random, dims, points, cand[0 .. points * dims]);
        const dist2 = minDist2(dims, points, cand[0 .. points * dims]);
        if (dist2 > best) {
            best = dist2;
            @memcpy(out[0 .. points * dims], cand[0 .. points * dims]);
        }
    }
    return true;
}

test "hipercubo latino: cada fatia de cada variável tem exatamente um ponto" {
    const dims = 5;
    const points = 8;
    var samples: [dims * points]f64 = undefined;
    try std.testing.expect(lhs(dims, points, 1, 3, &samples));
    for (0..dims) |j| {
        var hit: [points]bool = @splat(false);
        for (0..points) |i| {
            const value = samples[i * dims + j];
            try std.testing.expect(value >= 0 and value < 1);
            const k: usize = @intFromFloat(value * points);
            try std.testing.expect(!hit[k]);
            hit[k] = true;
        }
    }
}

test "hipercubo latino: mesma semente, mesmos pontos; o maximin não afasta menos que um sorteio só" {
    const dims = 12;
    const points = 8;
    var first: [dims * points]f64 = undefined;
    var second: [dims * points]f64 = undefined;
    var one: [dims * points]f64 = undefined;
    try std.testing.expect(lhs(dims, points, 20, 7, &first));
    try std.testing.expect(lhs(dims, points, 20, 7, &second));
    try std.testing.expectEqualSlices(f64, &first, &second);
    try std.testing.expect(lhs(dims, points, 1, 7, &one));
    try std.testing.expect(minDist2(dims, points, &first) >= minDist2(dims, points, &one));
    try std.testing.expect(!lhs(0, points, 1, 7, &first));
    try std.testing.expect(!lhs(dims, points, 0, 7, &first));
}

test "hipercubo latino cobre a faixa melhor que o sorteio uniforme (12 variáveis, 8 pontos)" {
    // a pior variável: a maior fatia de 1/8 vazia. No latino, nenhuma; no uniforme, em média várias
    const dims = 12;
    const points = 8;
    var samples: [dims * points]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    var empty_u: usize = 0;
    var empty_l: usize = 0;
    for (0..20) |seed| {
        for (&samples) |*value| value.* = random.float(f64);
        empty_u += emptySlices(dims, points, &samples);
        try std.testing.expect(lhs(dims, points, 1, seed, &samples));
        empty_l += emptySlices(dims, points, &samples);
    }
    try std.testing.expectEqual(@as(usize, 0), empty_l);
    try std.testing.expect(empty_u > 20 * dims); // ~ (7/8)⁸ ≈ 34 % das fatias vazias: ~2,7 por variável
}

fn emptySlices(dims: usize, points: usize, samples: []const f64) usize {
    var empty: usize = 0;
    for (0..dims) |j| {
        var hit: [max_m]bool = @splat(false);
        for (0..points) |i| hit[@min(points - 1, @as(usize, @intFromFloat(samples[i * dims + j] * @as(f64, @floatFromInt(points)))))] = true;
        for (0..points) |k| empty += @intFromBool(!hit[k]);
    }
    return empty;
}

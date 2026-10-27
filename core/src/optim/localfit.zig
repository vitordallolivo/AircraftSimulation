//! Modelo local por mínimos quadrados ponderados: a partir de pontos já avaliados em volta de um ponto x₀, a
//! inclinação e a curvatura da resposta em cada direção, sem avaliar nada de novo. É a sensibilidade do melhor avião
//! do aeroopt (`aeroopt/sensitivity.py`): a busca das superfícies já passou por vários pontos perto do melhor, e a
//! superfície que melhor passa por eles dá ∂N/∂xₖ e ∂²N/∂xₖ².
//!
//!   y ≈ a + gᵀ (x − x₀) + ½ Σₖ cₖ (xₖ − x₀ₖ)²,   min Σᵢ wᵢ (yᵢ − ŷᵢ)²
//!
//! Sem a curvatura (`quad = false`) é o plano. No ótimo o plano diz inclinação zero e não conta quanto se perde ao
//! sair dele; a curvatura diz. Só os termos quadrados de cada direção entram (sem os cruzados xⱼxₖ), para que os
//! pontos de uma busca por coordenadas, que anda um eixo por vez, bastem. Com zᵢ = (1, Δxᵢ, ½Δxᵢ²), as equações
//! normais são (Σ wᵢ zᵢ zᵢᵀ) β = Σ wᵢ yᵢ zᵢ, β = (a, g, c), resolvidas por Cholesky (Björck, "Numerical Methods for
//! Least Squares Problems", SIAM 1996, seções 1.1 e 4.1, a conferir no PDF). O peso tricúbico
//! wᵢ = (1 − (dᵢ/r)³)³ para dᵢ < r (zero fora), com dᵢ a distância de xᵢ a x₀ nas variáveis já normalizadas, faz os
//! pontos de perto mandarem e os de fora do raio não contarem: é o peso da regressão local de Cleveland e Devlin
//! (JASA 83(403), 1988, a conferir no PDF). Sem pontos que abram todas as
//! direções a matriz não é positiva definida e a conta diz que não dá; quem chama então avalia só as direções que
//! faltam.
const std = @import("std");
const linalg = @import("../math/linalg.zig");

pub const max_n = 32;
const M = 2 * max_n + 1;

pub const Fit = struct {
    a: f64 = 0, // o valor do modelo em x₀
    rms: f64 = 0, // o resíduo ponderado (o quanto os pontos fogem do modelo)
    weight: f64 = 0, // a soma dos pesos (quantos pontos "contaram")
};

/// o peso tricúbico (1 − (d/r)³)³ dentro do raio r e zero fora, com d² dado
fn tricube(d2: f64, r: f64) f64 {
    const q = @sqrt(d2) / r;
    if (q >= 1) return 0;
    const t = 1 - q * q * q;
    return t * t * t;
}

fn basis(n: usize, quad: bool, x: []const f64, x0: []const f64, z: []f64) f64 {
    z[0] = 1;
    var d2: f64 = 0;
    for (0..n) |k| {
        const d = x[k] - x0[k];
        z[k + 1] = d;
        if (quad) z[n + 1 + k] = 0.5 * d * d;
        d2 += d * d;
    }
    return d2;
}

/// ajusta o modelo nos `m` pontos `xs` (m × n, linha a linha, já normalizados) com valores `ys`, em volta de `x0`,
/// com o raio `r` do peso; a inclinação vai para `g[0..n]` e, com `quad`, a curvatura para `c[0..n]`. null se as
/// direções não ficam todas determinadas
pub fn fit(n: usize, m: usize, xs: []const f64, ys: []const f64, x0: []const f64, r: f64, quad: bool, g: []f64,
    c: []f64) ?Fit {
    const nb = if (quad) 2 * n + 1 else n + 1;
    if (n == 0 or n > max_n or m < nb or !(r > 0)) return null;
    var A: [M][M]f64 = @splat(@splat(0));
    var b: [M]f64 = @splat(0);
    var z: [M]f64 = undefined;
    var wsum: f64 = 0;
    for (0..m) |i| {
        const y = ys[i];
        if (!std.math.isFinite(y)) continue;
        const w = tricube(basis(n, quad, xs[i * n ..][0..n], x0, &z), r);
        if (w == 0) continue;
        wsum += w;
        for (0..nb) |p| {
            b[p] += w * y * z[p];
            for (0..nb) |q| A[p][q] += w * z[p] * z[q];
        }
    }
    // escala de cada coluna (pontos muito perto de x₀ deixam a matriz mal condicionada): resolve com D A D (D⁻¹β)
    var s: [M]f64 = undefined;
    for (0..nb) |p| s[p] = if (A[p][p] > 0) 1 / @sqrt(A[p][p]) else 0;
    for (0..nb) |p| {
        if (s[p] == 0) return null;
        b[p] *= s[p];
        for (0..nb) |q| A[p][q] *= s[p] * s[q];
    }
    if (!linalg.cholesky(M, &A, nb)) return null;
    // uma direção quase sem pontos: o pivô de Cholesky some (a matriz é quase singular)
    for (0..nb) |p| if (A[p][p] < 1e-6) return null;
    linalg.cholSolve(M, &A, nb, &b);
    for (0..nb) |p| b[p] *= s[p];
    var res: f64 = 0;
    for (0..m) |i| {
        if (!std.math.isFinite(ys[i])) continue;
        const d2 = basis(n, quad, xs[i * n ..][0..n], x0, &z);
        var e = ys[i];
        for (0..nb) |p| e -= b[p] * z[p];
        res += tricube(d2, r) * e * e;
    }
    for (0..n) |k| {
        g[k] = b[k + 1];
        if (quad) c[k] = b[n + 1 + k];
    }
    return .{ .a = b[0], .rms = @sqrt(res / wsum), .weight = wsum };
}

// ------------------------------------------------------------------ testes
test "plano exato: a inclinação sai igual, com qualquer peso" {
    // y = 3 + 2 x₀ − 5 x₁ em 6 pontos espalhados
    const xs = [_]f64{ 0.1, 0.2, 0.5, 0.5, 0.9, 0.1, 0.3, 0.8, 0.6, 0.4, 0.45, 0.55 };
    var ys: [6]f64 = undefined;
    for (0..6) |i| ys[i] = 3 + 2 * xs[2 * i] - 5 * xs[2 * i + 1];
    var g: [2]f64 = undefined;
    var c: [2]f64 = undefined;
    const f = fit(2, 6, &xs, &ys, &.{ 0.5, 0.5 }, 0.8, false, &g, &c).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2), g[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -5), g[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3 + 1 - 2.5), f.a, 1e-9);
    try std.testing.expect(f.rms < 1e-9);
}

test "parábola: o plano dá zero no topo e a corda de um lado; com a curvatura sai exata dos dois jeitos" {
    // y = −(x − 0,5)²: g = 0 e c = −2 em x₀ = 0,5
    const xs = [_]f64{ 0.3, 0.4, 0.5, 0.6, 0.7 };
    var ys: [5]f64 = undefined;
    for (0..5) |i| ys[i] = -(xs[i] - 0.5) * (xs[i] - 0.5);
    var g: [1]f64 = undefined;
    var c: [1]f64 = undefined;
    _ = fit(1, 5, &xs, &ys, &.{0.5}, 0.2, false, &g, &c).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), g[0], 1e-12);
    const right = [_]f64{ 0.5, 0.55, 0.6 };
    var yr: [3]f64 = undefined;
    for (0..3) |i| yr[i] = -(right[i] - 0.5) * (right[i] - 0.5);
    _ = fit(1, 3, &right, &yr, &.{0.5}, 0.2, false, &g, &c).?;
    try std.testing.expect(g[0] < 0 and g[0] > -0.2); // a corda no lado direito, puxada para x₀
    const f = fit(1, 3, &right, &yr, &.{0.5}, 0.2, true, &g, &c).?; // três pontos de um lado só já bastam
    try std.testing.expectApproxEqAbs(@as(f64, 0), g[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -2), c[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), f.a, 1e-12);
}

test "curvatura por eixo com pontos de uma busca por coordenadas" {
    // y = 1 + x₀ − 3 x₀² + 2 x₁²/2 em volta de (0, 0): pontos só nos eixos, como a busca por coordenadas deixa
    const xs = [_]f64{ 0, 0, 0.1, 0, -0.1, 0, 0.2, 0, 0, 0.1, 0, -0.05 };
    var ys: [6]f64 = undefined;
    for (0..6) |i| {
        const a = xs[2 * i];
        const b = xs[2 * i + 1];
        ys[i] = 1 + a - 3 * a * a + b * b;
    }
    var g: [2]f64 = undefined;
    var c: [2]f64 = undefined;
    _ = fit(2, 6, &xs, &ys, &.{ 0, 0 }, 0.3, true, &g, &c).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1), g[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), g[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -6), c[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), c[1], 1e-9);
}

test "direção sem pontos: não dá, e NaN é ignorado" {
    // todos os pontos com x₁ = x₀: a inclinação em x₁ não fica determinada
    const xs = [_]f64{ 0.1, 0.5, 0.3, 0.5, 0.7, 0.5, 0.9, 0.5 };
    const ys = [_]f64{ 1, 2, 3, std.math.nan(f64) };
    var g: [2]f64 = undefined;
    var c: [2]f64 = undefined;
    try std.testing.expect(fit(2, 4, &xs, &ys, &.{ 0.5, 0.5 }, 0.3, false, &g, &c) == null);
    try std.testing.expect(fit(2, 2, &xs, &ys, &.{ 0.5, 0.5 }, 0.3, false, &g, &c) == null); // menos de n + 1
    // dois valores só em x₀ (x₀ e 0,6): a curvatura não fica determinada
    const two = [_]f64{ 0.5, 0.6, 0.5, 0.6 };
    const y2 = [_]f64{ 1, 2, 1, 2 };
    try std.testing.expect(fit(1, 4, &two, &y2, &.{0.5}, 0.3, true, &g, &c) == null);
}

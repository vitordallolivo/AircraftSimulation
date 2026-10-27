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
const max_basis = 2 * max_n + 1; // termos da base com a curvatura: 1, Δx e ½Δx²

pub const Fit = struct {
    intercept: f64 = 0, // o valor do modelo em x₀
    rms: f64 = 0, // o resíduo ponderado (o quanto os pontos fogem do modelo)
    weight: f64 = 0, // a soma dos pesos (quantos pontos "contaram")
};

/// o peso tricúbico (1 − (d/radius)³)³ dentro do raio e zero fora, com d² dado
fn tricube(d2: f64, radius: f64) f64 {
    const ratio = @sqrt(d2) / radius;
    if (ratio >= 1) return 0;
    const one_minus = 1 - ratio * ratio * ratio;
    return one_minus * one_minus * one_minus;
}

/// os termos da base em `point` (1, Δx e, com `quad`, ½Δx²) em `terms`; devolve |Δx|²
fn basis(dims: usize, quad: bool, point: []const f64, x0: []const f64, terms: []f64) f64 {
    terms[0] = 1;
    var d2: f64 = 0;
    for (0..dims) |k| {
        const delta = point[k] - x0[k];
        terms[k + 1] = delta;
        if (quad) terms[dims + 1 + k] = 0.5 * delta * delta;
        d2 += delta * delta;
    }
    return d2;
}

/// ajusta o modelo nos `points` pontos `xs` (points × dims, linha a linha, já normalizados) com valores `ys`, em volta de `x0`,
/// com o raio `radius` do peso; a inclinação vai para `gradient` e, com `quad`, a curvatura para `curvature`. null se as
/// direções não ficam todas determinadas
pub fn fit(dims: usize, points: usize, xs: []const f64, ys: []const f64, x0: []const f64, radius: f64, quad: bool, gradient: []f64,
    curvature: []f64) ?Fit {
    const basis_len = if (quad) 2 * dims + 1 else dims + 1;
    if (dims == 0 or dims > max_n or points < basis_len or !(radius > 0)) return null;
    var normal: [max_basis][max_basis]f64 = @splat(@splat(0));
    var rhs: [max_basis]f64 = @splat(0);
    var terms: [max_basis]f64 = undefined;
    var wsum: f64 = 0;
    for (0..points) |i| {
        const value = ys[i];
        if (!std.math.isFinite(value)) continue;
        const weight = tricube(basis(dims, quad, xs[i * dims ..][0..dims], x0, &terms), radius);
        if (weight == 0) continue;
        wsum += weight;
        for (0..basis_len) |row| {
            rhs[row] += weight * value * terms[row];
            for (0..basis_len) |col| normal[row][col] += weight * terms[row] * terms[col];
        }
    }
    // escala de cada coluna (pontos muito perto de x₀ deixam a matriz mal condicionada): resolve com D A D (D⁻¹β)
    var scale: [max_basis]f64 = undefined;
    for (0..basis_len) |row| scale[row] = if (normal[row][row] > 0) 1 / @sqrt(normal[row][row]) else 0;
    for (0..basis_len) |row| {
        if (scale[row] == 0) return null;
        rhs[row] *= scale[row];
        for (0..basis_len) |col| normal[row][col] *= scale[row] * scale[col];
    }
    if (!linalg.cholesky(max_basis, &normal, basis_len)) return null;
    // uma direção quase sem pontos: o pivô de Cholesky some (a matriz é quase singular)
    for (0..basis_len) |row| if (normal[row][row] < 1e-6) return null;
    linalg.cholSolve(max_basis, &normal, basis_len, &rhs);
    for (0..basis_len) |row| rhs[row] *= scale[row];
    var res_sum: f64 = 0;
    for (0..points) |i| {
        if (!std.math.isFinite(ys[i])) continue;
        const d2 = basis(dims, quad, xs[i * dims ..][0..dims], x0, &terms);
        var residual = ys[i];
        for (0..basis_len) |row| residual -= rhs[row] * terms[row];
        res_sum += tricube(d2, radius) * residual * residual;
    }
    for (0..dims) |k| {
        gradient[k] = rhs[k + 1];
        if (quad) curvature[k] = rhs[dims + 1 + k];
    }
    return .{ .intercept = rhs[0], .rms = @sqrt(res_sum / wsum), .weight = wsum };
}

// ------------------------------------------------------------------ testes
test "plano exato: a inclinação sai igual, com qualquer peso" {
    // y = 3 + 2 x₀ − 5 x₁ em 6 pontos espalhados
    const xs = [_]f64{ 0.1, 0.2, 0.5, 0.5, 0.9, 0.1, 0.3, 0.8, 0.6, 0.4, 0.45, 0.55 };
    var ys: [6]f64 = undefined;
    for (0..6) |i| ys[i] = 3 + 2 * xs[2 * i] - 5 * xs[2 * i + 1];
    var gradient: [2]f64 = undefined;
    var curvature: [2]f64 = undefined;
    const result = fit(2, 6, &xs, &ys, &.{ 0.5, 0.5 }, 0.8, false, &gradient, &curvature).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2), gradient[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -5), gradient[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3 + 1 - 2.5), result.intercept, 1e-9);
    try std.testing.expect(result.rms < 1e-9);
}

test "parábola: o plano dá zero no topo e a corda de um lado; com a curvatura sai exata dos dois jeitos" {
    // y = −(x − 0,5)²: g = 0 e c = −2 em x₀ = 0,5
    const xs = [_]f64{ 0.3, 0.4, 0.5, 0.6, 0.7 };
    var ys: [5]f64 = undefined;
    for (0..5) |i| ys[i] = -(xs[i] - 0.5) * (xs[i] - 0.5);
    var gradient: [1]f64 = undefined;
    var curvature: [1]f64 = undefined;
    _ = fit(1, 5, &xs, &ys, &.{0.5}, 0.2, false, &gradient, &curvature).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), gradient[0], 1e-12);
    const right = [_]f64{ 0.5, 0.55, 0.6 };
    var yr: [3]f64 = undefined;
    for (0..3) |i| yr[i] = -(right[i] - 0.5) * (right[i] - 0.5);
    _ = fit(1, 3, &right, &yr, &.{0.5}, 0.2, false, &gradient, &curvature).?;
    try std.testing.expect(gradient[0] < 0 and gradient[0] > -0.2); // a corda no lado direito, puxada para x₀
    const result = fit(1, 3, &right, &yr, &.{0.5}, 0.2, true, &gradient, &curvature).?; // três pontos de um lado só já bastam
    try std.testing.expectApproxEqAbs(@as(f64, 0), gradient[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -2), curvature[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.intercept, 1e-12);
}

test "curvatura por eixo com pontos de uma busca por coordenadas" {
    // y = 1 + x₀ − 3 x₀² + 2 x₁²/2 em volta de (0, 0): pontos só nos eixos, como a busca por coordenadas deixa
    const xs = [_]f64{ 0, 0, 0.1, 0, -0.1, 0, 0.2, 0, 0, 0.1, 0, -0.05 };
    var ys: [6]f64 = undefined;
    for (0..6) |i| {
        const coord_x = xs[2 * i];
        const coord_y = xs[2 * i + 1];
        ys[i] = 1 + coord_x - 3 * coord_x * coord_x + coord_y * coord_y;
    }
    var gradient: [2]f64 = undefined;
    var curvature: [2]f64 = undefined;
    _ = fit(2, 6, &xs, &ys, &.{ 0, 0 }, 0.3, true, &gradient, &curvature).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1), gradient[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), gradient[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -6), curvature[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), curvature[1], 1e-9);
}

test "direção sem pontos: não dá, e NaN é ignorado" {
    // todos os pontos com x₁ = x₀: a inclinação em x₁ não fica determinada
    const xs = [_]f64{ 0.1, 0.5, 0.3, 0.5, 0.7, 0.5, 0.9, 0.5 };
    const ys = [_]f64{ 1, 2, 3, std.math.nan(f64) };
    var gradient: [2]f64 = undefined;
    var curvature: [2]f64 = undefined;
    try std.testing.expect(fit(2, 4, &xs, &ys, &.{ 0.5, 0.5 }, 0.3, false, &gradient, &curvature) == null);
    try std.testing.expect(fit(2, 2, &xs, &ys, &.{ 0.5, 0.5 }, 0.3, false, &gradient, &curvature) == null); // menos de n + 1
    // dois valores só em x₀ (x₀ e 0,6): a curvatura não fica determinada
    const two = [_]f64{ 0.5, 0.6, 0.5, 0.6 };
    const y2 = [_]f64{ 1, 2, 1, 2 };
    try std.testing.expect(fit(1, 4, &two, &y2, &.{0.5}, 0.3, true, &gradient, &curvature) == null);
}

//! Integral numérica por Gauss-Legendre: ∫ f ≈ Σ w_i f(x_i), com n pontos x_i e pesos w_i escolhidos para a soma
//! dar a integral exata de todo polinômio até o grau 2n − 1.
//!
//! Os pontos são as raízes do polinômio de Legendre P_n em [−1, 1], e o peso de cada um é
//! w_i = 2 / ((1 − x_i²) P_n'(x_i)²) (Abramowitz e Stegun, Handbook of Mathematical Functions, eq. 25.4.29 e tabela
//! 25.4; a conferir no PDF). O compilador acha as raízes por Newton, partindo de cos(π (i − 1/4) / (n + 1/2))
//! (Press et al., Numerical Recipes, 3ª ed., seção 4.6, rotina `gauleg`; a conferir no PDF), e em tempo de execução
//! só sobram as duas tabelas.
const std = @import("std");

/// os pontos e os pesos de uma regra de `count` pontos
pub fn Rule(comptime count: usize) type {
    return struct { points: [count]f64, weights: [count]f64 };
}

/// P_n(x) e P_n'(x) pela recorrência de Bonnet: (k + 1) P_{k+1} = (2k + 1) x P_k − k P_{k−1}
fn legendre(comptime degree: usize, x: f64) struct { value: f64, slope: f64 } {
    var previous: f64 = 1;
    var current: f64 = x;
    for (1..degree) |k| {
        const order: f64 = @floatFromInt(k);
        const next = ((2 * order + 1) * x * current - order * previous) / (order + 1);
        previous = current;
        current = next;
    }
    const degree_float: f64 = @floatFromInt(degree);
    return .{ .value = current, .slope = degree_float * (x * current - previous) / (x * x - 1) };
}

/// a regra de Gauss-Legendre de `count` pontos em [−1, 1], em ordem crescente, calculada pelo compilador
pub fn gaussLegendre(comptime count: usize) Rule(count) {
    return struct {
        const value = symmetricRule(count);
    }.value;
}

/// a regra de [0, 1] (x = (1 + t) / 2): os pontos em [0, 1] e os pesos pela metade, somando 1; calculada pelo
/// compilador
pub fn gaussLegendreUnit(comptime count: usize) Rule(count) {
    return struct {
        const value = unitRule(count);
    }.value;
}

fn symmetricRule(comptime count: usize) Rule(count) {
    {
        if (count == 0) @compileError("a regra de Gauss precisa de pelo menos um ponto");
        @setEvalBranchQuota(20000 * count);
        var rule: Rule(count) = undefined;
        const count_float: f64 = @floatFromInt(count);
        for (0..count) |i| {
            const index_float: f64 = @floatFromInt(i);
            // a raiz i, contada do lado de x = 1; Newton até parar de mudar
            var root: f64 = @cos(std.math.pi * (index_float + 0.75) / (count_float + 0.5));
            var slope: f64 = 0;
            for (0..100) |_| {
                const at = legendre(count, root);
                slope = at.slope;
                const step = at.value / at.slope;
                root -= step;
                if (@abs(step) <= 1e-17) break;
            }
            slope = legendre(count, root).slope;
            rule.points[count - 1 - i] = root;
            rule.weights[count - 1 - i] = 2 / ((1 - root * root) * slope * slope);
        }
        return rule;
    }
}

fn unitRule(comptime count: usize) Rule(count) {
    {
        const symmetric = symmetricRule(count);
        var rule: Rule(count) = undefined;
        for (symmetric.points, symmetric.weights, &rule.points, &rule.weights) |point, weight, *unit_point, *unit_weight| {
            unit_point.* = 0.5 + 0.5 * point;
            unit_weight.* = 0.5 * weight;
        }
        return rule;
    }
}

const testing = std.testing;

test "Gauss-Legendre: os 4 pontos e pesos batem com a tabela 25.4 de Abramowitz e Stegun" {
    const rule = gaussLegendre(4);
    const points = [4]f64{ -0.8611363115940526, -0.3399810435848563, 0.3399810435848563, 0.8611363115940526 };
    const weights = [4]f64{ 0.3478548451374538, 0.6521451548625461, 0.6521451548625461, 0.3478548451374538 };
    for (rule.points, points) |found, expected| try testing.expectApproxEqAbs(expected, found, 1e-15);
    for (rule.weights, weights) |found, expected| try testing.expectApproxEqAbs(expected, found, 1e-15);
}

test "Gauss-Legendre: n pontos integram exato todo polinômio até o grau 2n − 1" {
    inline for (.{ 1, 2, 3, 4, 5, 8 }) |count| {
        const rule = gaussLegendreUnit(count);
        for (0..2 * count) |power| {
            var sum: f64 = 0;
            for (rule.points, rule.weights) |point, weight| sum += weight * std.math.pow(f64, point, @floatFromInt(power));
            // ∫₀¹ x^p dx = 1 / (p + 1)
            try testing.expectApproxEqAbs(1 / @as(f64, @floatFromInt(power + 1)), sum, 1e-14);
        }
    }
}

//! Interpolação polinomial num trecho [0, 1]: as funções de forma que dizem quanto cada valor nos extremos pesa num
//! ponto t de dentro. São as que os elementos finitos usam.
//!
//!   linear (Lagrange de grau 1)   u(t) = (1 − t) u₀ + t u₁: só os valores nos dois nós
//!   Hermite cúbica                u(t) = H₀ u₀ + H₁ L u₀' + H₂ u₁ + H₃ L u₁': os valores e as inclinações nos nós,
//!                                 com L o comprimento do trecho (a inclinação é por metro, t é por trecho)
//!
//! As de Hermite são as da viga de Euler-Bernoulli (Przemieniecki, Theory of Matrix Structural Analysis, cap. 5; a
//! conferir no PDF).
const std = @import("std");

/// os pesos de (u₀, u₁) em t ∈ [0, 1]
pub fn linear(t: f64) [2]f64 {
    return .{ 1 - t, t };
}

/// as derivadas desses pesos em relação à posição (por metro), num trecho de comprimento `length`
pub fn linearSlope(length: f64) [2]f64 {
    return .{ -1 / length, 1 / length };
}

/// os pesos de (u₀, u₀', u₁, u₁') em t ∈ [0, 1] num trecho de comprimento `length`
pub fn hermite(t: f64, length: f64) [4]f64 {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{ 1 - 3 * t2 + 2 * t3, length * (t - 2 * t2 + t3), 3 * t2 - 2 * t3, length * (t3 - t2) };
}

/// as segundas derivadas desses pesos em relação à posição (por metro²): a curvatura da viga
pub fn hermiteCurvature(t: f64, length: f64) [4]f64 {
    return .{ (-6 + 12 * t) / (length * length), (-4 + 6 * t) / length, (6 - 12 * t) / (length * length), (6 * t - 2) / length };
}

const testing = std.testing;

test "interpolação: os pesos somam 1 e recuperam os valores e as inclinações dos nós" {
    const length = 0.7;
    for ([_]f64{ 0, 0.3, 0.5, 1 }) |t| {
        const line = linear(t);
        try testing.expectApproxEqAbs(@as(f64, 1), line[0] + line[1], 1e-15);
        const cubic = hermite(t, length);
        try testing.expectApproxEqAbs(@as(f64, 1), cubic[0] + cubic[2], 1e-15);
    }
    // nos nós: H₀(0) = 1, H₂(1) = 1, e as de inclinação valem zero
    try testing.expectEqual([4]f64{ 1, 0, 0, 0 }, hermite(0, length));
    try testing.expectEqual([4]f64{ 0, 0, 1, 0 }, hermite(1, length));
    // uma cúbica qualquer é reproduzida exato: u(x) = 2 − x + 3x² − x³ em [0, L]
    const cubic_at = struct {
        fn value(x: f64) f64 {
            return 2 - x + 3 * x * x - x * x * x;
        }
        fn slope(x: f64) f64 {
            return -1 + 6 * x - 3 * x * x;
        }
        fn curvature(x: f64) f64 {
            return 6 - 6 * x;
        }
    };
    const nodes = [4]f64{ cubic_at.value(0), cubic_at.slope(0), cubic_at.value(length), cubic_at.slope(length) };
    for ([_]f64{ 0.1, 0.45, 0.9 }) |t| {
        const weights = hermite(t, length);
        const bends = hermiteCurvature(t, length);
        var value: f64 = 0;
        var curvature: f64 = 0;
        for (weights, bends, nodes) |weight, bend, node| {
            value += weight * node;
            curvature += bend * node;
        }
        try testing.expectApproxEqAbs(cubic_at.value(t * length), value, 1e-13);
        try testing.expectApproxEqAbs(cubic_at.curvature(t * length), curvature, 1e-12);
    }
}

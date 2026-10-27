//! Substituto por funções de base radial (RBF): a superfície que passa exatamente por todos os pontos já avaliados e
//! dá um palpite barato em qualquer outro. É o que o GA assistido por substituto (`aeroopt/stages.py`, "gerações com
//! substituto") usa para escolher, entre muitos filhos sorteados, os poucos que valem uma avaliação de verdade.
//!
//!   s(x) = Σᵢ λᵢ ‖x − xᵢ‖³ + c₀ + cᵀ x
//!
//! A cúbica φ(r) = r³ com a cauda linear é a do RBF de Gutmann ("A radial basis function method for global
//! optimization", J. Global Optim. 19, 2001, a conferir no PDF) e do Stochastic RBF de Regis e Shoemaker (INFORMS J.
//! Computing 19(4), 2007, a conferir no PDF). Ela não tem parâmetro de forma para ajustar, e a cauda deixa o sistema
//! com solução única sempre que os pontos não ficam todos num mesmo hiperplano. Com Φᵢⱼ = ‖xᵢ − xⱼ‖³ e
//! Pᵢ = (1, xᵢᵀ), os coeficientes saem de
//!
//!   [Φ  P] [λ]   [y]
//!   [Pᵀ 0] [c] = [0]
//!
//! resolvido por LU com pivoteamento parcial. O sistema cresce com os pontos, então a memória vem de quem chama
//! (`work`, (m + n + 1)² valores): o núcleo não aloca.
const std = @import("std");

pub const max_n = 32;

/// o tamanho do sistema com `points` pontos em `dims` variáveis
pub fn size(dims: usize, points: usize) usize {
    return points + dims + 1;
}

fn dist3(point_a: []const f64, point_b: []const f64) f64 {
    var d2: f64 = 0;
    for (point_a, point_b) |coord_a, coord_b| d2 += (coord_a - coord_b) * (coord_a - coord_b);
    return d2 * @sqrt(d2);
}

/// LU com pivoteamento parcial de `matrix` (order × order, linha a linha) no lugar, resolvendo `rhs` junto; false se singular
fn luSolveFlat(matrix: []f64, order: usize, rhs: []f64) bool {
    var scale: f64 = 0;
    for (matrix[0 .. order * order]) |value| scale = @max(scale, @abs(value));
    const tiny = 1e-13 * @max(scale, 1e-300);
    for (0..order) |col| {
        var pivot_row = col;
        var big = @abs(matrix[col * order + col]);
        for (col + 1..order) |row| {
            const value = @abs(matrix[row * order + col]);
            if (value > big) {
                big = value;
                pivot_row = row;
            }
        }
        if (!(big > tiny)) return false;
        if (pivot_row != col) {
            for (0..order) |j| std.mem.swap(f64, &matrix[col * order + j], &matrix[pivot_row * order + j]);
            std.mem.swap(f64, &rhs[col], &rhs[pivot_row]);
        }
        const piv = matrix[col * order + col];
        for (col + 1..order) |row| {
            const factor = matrix[row * order + col] / piv;
            if (factor == 0) continue;
            for (col..order) |j| matrix[row * order + j] -= factor * matrix[col * order + j];
            rhs[row] -= factor * rhs[col];
        }
    }
    var i = order;
    while (i > 0) {
        i -= 1;
        var sum = rhs[i];
        for (i + 1..order) |j| sum -= matrix[i * order + j] * rhs[j];
        rhs[i] = sum / matrix[i * order + i];
    }
    return true;
}

/// ajusta o substituto nos `points` pontos `xs` (points × dims, linha a linha) com valores `ys`; `coef` recebe
/// (λ₁..λₘ, c₀, c₁..cₙ) e `work` tem (points + dims + 1)² valores. false se os pontos não determinam a cauda (todos num hiperplano, ou repetidos)
pub fn fit(dims: usize, points: usize, xs: []const f64, ys: []const f64, work: []f64, coef: []f64) bool {
    if (dims == 0 or dims > max_n or points < dims + 1) return false;
    const order = size(dims, points);
    if (work.len < order * order or coef.len < order) return false;
    const matrix = work[0 .. order * order];
    @memset(matrix, 0);
    for (0..points) |i| {
        if (!std.math.isFinite(ys[i])) return false;
        const xi = xs[i * dims ..][0..dims];
        for (i + 1..points) |j| {
            const value = dist3(xi, xs[j * dims ..][0..dims]);
            matrix[i * order + j] = value;
            matrix[j * order + i] = value;
        }
        matrix[i * order + points] = 1;
        matrix[points * order + i] = 1;
        for (0..dims) |dim| {
            matrix[i * order + points + 1 + dim] = xi[dim];
            matrix[(points + 1 + dim) * order + i] = xi[dim];
        }
        coef[i] = ys[i];
    }
    @memset(coef[points..order], 0);
    return luSolveFlat(matrix, order, coef[0..order]);
}

/// o valor do substituto em `query` (dims valores)
pub fn eval(dims: usize, points: usize, xs: []const f64, coef: []const f64, query: []const f64) f64 {
    var sum = coef[points];
    for (0..dims) |dim| sum += coef[points + 1 + dim] * query[dim];
    for (0..points) |i| sum += coef[i] * dist3(query, xs[i * dims ..][0..dims]);
    return sum;
}

// ------------------------------------------------------------------ testes
test "passa pelos pontos e reproduz um plano exato (a cauda linear)" {
    const xs = [_]f64{ 0.1, 0.2, 0.5, 0.5, 0.9, 0.1, 0.3, 0.8, 0.6, 0.4, 0.45, 0.55 };
    var ys: [6]f64 = undefined;
    for (0..6) |i| ys[i] = 3 + 2 * xs[2 * i] - 5 * xs[2 * i + 1];
    var work: [81]f64 = undefined;
    var coef: [9]f64 = undefined;
    try std.testing.expect(fit(2, 6, &xs, &ys, &work, &coef));
    for (0..6) |i| try std.testing.expectApproxEqAbs(ys[i], eval(2, 6, &xs, &coef, xs[2 * i ..][0..2]), 1e-9);
    // num plano, os λ somem e a cauda é o plano: vale também fora dos pontos
    try std.testing.expectApproxEqAbs(@as(f64, 3 + 2 * 0.7 - 5 * 0.2), eval(2, 6, &xs, &coef, &.{ 0.7, 0.2 }), 1e-9);
}

test "interpola uma tigela: o palpite fica perto do valor de verdade entre os pontos" {
    // y = −Σ (x − 0,6)² numa grade 5 × 5 de [0, 1]²; conferido no meio das células
    var xs: [50]f64 = undefined;
    var ys: [25]f64 = undefined;
    for (0..5) |i| for (0..5) |j| {
        const coord_x = @as(f64, @floatFromInt(i)) / 4;
        const coord_y = @as(f64, @floatFromInt(j)) / 4;
        xs[2 * (5 * i + j)] = coord_x;
        xs[2 * (5 * i + j) + 1] = coord_y;
        ys[5 * i + j] = -((coord_x - 0.6) * (coord_x - 0.6) + (coord_y - 0.6) * (coord_y - 0.6));
    };
    var work: [28 * 28]f64 = undefined;
    var coef: [28]f64 = undefined;
    try std.testing.expect(fit(2, 25, &xs, &ys, &work, &coef));
    for (0..4) |i| for (0..4) |j| {
        const coord_x = (@as(f64, @floatFromInt(i)) + 0.5) / 4;
        const coord_y = (@as(f64, @floatFromInt(j)) + 0.5) / 4;
        const expected = -((coord_x - 0.6) * (coord_x - 0.6) + (coord_y - 0.6) * (coord_y - 0.6));
        try std.testing.expectApproxEqAbs(expected, eval(2, 25, &xs, &coef, &.{ coord_x, coord_y }), 0.01);
    };
}

test "pontos todos numa reta (2 variáveis) ou repetidos: não dá" {
    const line = [_]f64{ 0, 0, 0.5, 0.5, 1, 1, 0.25, 0.25 };
    const ys = [_]f64{ 1, 2, 3, 4 };
    var work: [49]f64 = undefined;
    var coef: [7]f64 = undefined;
    try std.testing.expect(!fit(2, 4, &line, &ys, &work, &coef));
    const rep = [_]f64{ 0, 0, 1, 0, 0, 1, 0, 1 };
    try std.testing.expect(!fit(2, 4, &rep, &ys, &work, &coef));
    try std.testing.expect(!fit(2, 2, &line, &ys, &work, &coef)); // menos de n + 1
}

//! Álgebra linear densa de tamanho fixo: fatoração LU com pivoteamento parcial e de Cholesky, e as
//! soluções de A x = b por elas. As matrizes são `[N][N]f64` com N conhecido em tempo de compilação e só
//! as primeiras `n` linhas e colunas usadas, então nada é alocado.
//!
//! LU: P A = L U por eliminação de Gauss com pivô parcial (Golub e Van Loan, Matrix Computations,
//! 4ª ed., alg. 3.4.1, a conferir no PDF). Cholesky: A = L Lᵀ para A simétrica positiva definida
//! (idem, alg. 4.2.1, a conferir no PDF). L e U ficam guardadas na própria A. Autovalores e autovetores de uma
//! simétrica: o método de Jacobi cíclico (idem, seção 8.5, a conferir no PDF), que gira a matriz até a parte fora
//! da diagonal sumir; para as matrizes pequenas do CMA-ES (até 32) é simples e preciso.
const std = @import("std");

/// fatora A (n × n) em P A = L U no lugar: abaixo da diagonal, L (diagonal unitária implícita); da
/// diagonal para cima, U. `pivots[k]` = a linha trocada com a k no passo k. false se A é singular
pub fn luFactor(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize, pivots: *[capacity]usize) bool {
    std.debug.assert(size <= capacity);
    for (0..size) |k| {
        var pivot_row = k;
        var largest = @abs(matrix[k][k]);
        for (k + 1..size) |i| {
            if (@abs(matrix[i][k]) > largest) {
                largest = @abs(matrix[i][k]);
                pivot_row = i;
            }
        }
        pivots[k] = pivot_row;
        if (!(largest > 0)) return false; // zero ou NaN
        if (pivot_row != k) std.mem.swap([capacity]f64, &matrix[k], &matrix[pivot_row]);
        const inv_pivot = 1.0 / matrix[k][k];
        for (k + 1..size) |i| {
            const factor = matrix[i][k] * inv_pivot;
            matrix[i][k] = factor;
            for (k + 1..size) |j| matrix[i][j] -= factor * matrix[k][j];
        }
    }
    return true;
}

/// resolve A x = b com a fatoração de `luFactor`; b vira x
pub fn luSolve(comptime capacity: usize, factors: *const [capacity][capacity]f64, size: usize, pivots: *const [capacity]usize, rhs: *[capacity]f64) void {
    for (0..size) |k| {
        if (pivots[k] != k) std.mem.swap(f64, &rhs[k], &rhs[pivots[k]]);
    }
    for (0..size) |i| { // L y = P b
        var sum = rhs[i];
        for (0..i) |j| sum -= factors[i][j] * rhs[j];
        rhs[i] = sum;
    }
    var i = size;
    while (i > 0) { // U x = y
        i -= 1;
        var sum = rhs[i];
        for (i + 1..size) |j| sum -= factors[i][j] * rhs[j];
        rhs[i] = sum / factors[i][i];
    }
}

/// A = L Lᵀ no lugar (L no triângulo de baixo; o de cima não é tocado). false se A não é positiva definida
pub fn cholesky(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize) bool {
    std.debug.assert(size <= capacity);
    for (0..size) |j| {
        var diagonal = matrix[j][j];
        for (0..j) |k| diagonal -= matrix[j][k] * matrix[j][k];
        if (!(diagonal > 0)) return false;
        const factor_diagonal = @sqrt(diagonal);
        matrix[j][j] = factor_diagonal;
        for (j + 1..size) |i| {
            var sum = matrix[i][j];
            for (0..j) |k| sum -= matrix[i][k] * matrix[j][k];
            matrix[i][j] = sum / factor_diagonal;
        }
    }
    return true;
}

/// resolve A x = b com a fatoração de `cholesky`; b vira x
pub fn cholSolve(comptime capacity: usize, factor: *const [capacity][capacity]f64, size: usize, rhs: *[capacity]f64) void {
    for (0..size) |i| { // L y = b
        var sum = rhs[i];
        for (0..i) |k| sum -= factor[i][k] * rhs[k];
        rhs[i] = sum / factor[i][i];
    }
    var i = size;
    while (i > 0) { // Lᵀ x = y
        i -= 1;
        var sum = rhs[i];
        for (i + 1..size) |k| sum -= factor[k][i] * rhs[k];
        rhs[i] = sum / factor[i][i];
    }
}

/// A (n × n, simétrica) = V diag(w) Vᵀ pelo Jacobi cíclico; A é destruída. As colunas de V são os autovetores.
/// Para quando a soma dos quadrados fora da diagonal cai abaixo de 1e-30 vezes a total, ou em 64 varreduras
pub fn symEigen(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize, eigenvalues: *[capacity]f64, eigenvectors: *[capacity][capacity]f64) void {
    for (0..size) |i| {
        for (0..size) |j| eigenvectors[i][j] = if (i == j) 1 else 0;
    }
    var total: f64 = 0;
    for (0..size) |i| for (0..size) |j| {
        total += matrix[i][j] * matrix[i][j];
    };
    var sweep: usize = 0;
    while (sweep < 64) : (sweep += 1) {
        var off_diagonal: f64 = 0;
        for (0..size) |i| for (i + 1..size) |j| {
            off_diagonal += 2 * matrix[i][j] * matrix[i][j];
        };
        if (off_diagonal <= 1e-30 * total or off_diagonal == 0) break;
        for (0..size) |row| for (row + 1..size) |col| {
            if (matrix[row][col] == 0) continue;
            // a rotação que zera A[p][q] (Golub e Van Loan, alg. 8.5.1)
            const tau = (matrix[col][col] - matrix[row][row]) / (2 * matrix[row][col]);
            const tangent = (if (tau >= 0) @as(f64, 1) else -1) / (@abs(tau) + @sqrt(1 + tau * tau));
            const cosine = 1 / @sqrt(1 + tangent * tangent);
            const sine = tangent * cosine;
            for (0..size) |k| { // A ← A J
                const a_kp = matrix[k][row];
                const a_kq = matrix[k][col];
                matrix[k][row] = cosine * a_kp - sine * a_kq;
                matrix[k][col] = sine * a_kp + cosine * a_kq;
            }
            for (0..size) |k| { // A ← Jᵀ A
                const a_pk = matrix[row][k];
                const a_qk = matrix[col][k];
                matrix[row][k] = cosine * a_pk - sine * a_qk;
                matrix[col][k] = sine * a_pk + cosine * a_qk;
            }
            for (0..size) |k| { // V ← V J
                const v_kp = eigenvectors[k][row];
                const v_kq = eigenvectors[k][col];
                eigenvectors[k][row] = cosine * v_kp - sine * v_kq;
                eigenvectors[k][col] = sine * v_kp + cosine * v_kq;
            }
        };
    }
    for (0..size) |i| eigenvalues[i] = matrix[i][i];
}

/// A x = b de uma vez (A e b são copiados); false se A é singular
pub fn solve(comptime capacity: usize, matrix: [capacity][capacity]f64, size: usize, rhs: [capacity]f64, solution: *[capacity]f64) bool {
    var factors = matrix;
    var pivots: [capacity]usize = undefined;
    if (!luFactor(capacity, &factors, size, &pivots)) return false;
    solution.* = rhs;
    luSolve(capacity, &factors, size, &pivots, solution);
    return true;
}

const testing = std.testing;

test "LU: sistema 3x3 de solução inteira, com troca de linha" {
    // x = (1, 2, 3); A[0][0] = 0 obriga o pivô
    const matrix = [3][3]f64{ .{ 0, 2, 1 }, .{ 1, 1, 1 }, .{ 2, 1, 3 } };
    const rhs = [3]f64{ 7, 6, 13 };
    var solution: [3]f64 = undefined;
    try testing.expect(solve(3, matrix, 3, rhs, &solution));
    for (solution, [3]f64{ 1, 2, 3 }) |got, expected| try testing.expectApproxEqAbs(expected, got, 1e-12);
}

test "LU: matriz de Hilbert 5x5, resíduo pequeno; singular é recusada" {
    const capacity = 8;
    var matrix: [capacity][capacity]f64 = @splat(@splat(0));
    var rhs: [capacity]f64 = @splat(0);
    const size = 5;
    for (0..size) |i| {
        for (0..size) |j| matrix[i][j] = 1.0 / @as(f64, @floatFromInt(i + j + 1));
        rhs[i] = 1;
    }
    var solution: [capacity]f64 = undefined;
    try testing.expect(solve(capacity, matrix, size, rhs, &solution));
    for (0..size) |i| {
        var residual = -rhs[i];
        for (0..size) |j| residual += matrix[i][j] * solution[j];
        try testing.expect(@abs(residual) < 1e-9);
    }
    var singular = [2][2]f64{ .{ 1, 2 }, .{ 2, 4 } };
    var pivots: [2]usize = undefined;
    try testing.expect(!luFactor(2, &singular, 2, &pivots));
}

test "Cholesky: fator conhecido e solução igual à da LU" {
    // A = L Lᵀ com L = [[2,0,0],[6,1,0],[-8,5,3]] (Golub e Van Loan usam este tipo de exemplo)
    var matrix = [3][3]f64{ .{ 4, 12, -16 }, .{ 12, 37, -43 }, .{ -16, -43, 98 } };
    const original = matrix;
    try testing.expect(cholesky(3, &matrix, 3));
    const expected_factor = [3][3]f64{ .{ 2, 0, 0 }, .{ 6, 1, 0 }, .{ -8, 5, 3 } };
    for (0..3) |i| for (0..i + 1) |j| try testing.expectApproxEqAbs(expected_factor[i][j], matrix[i][j], 1e-12);
    var chol_solution = [3]f64{ 1, 2, 3 };
    cholSolve(3, &matrix, 3, &chol_solution);
    var lu_solution: [3]f64 = undefined;
    try testing.expect(solve(3, original, 3, .{ 1, 2, 3 }, &lu_solution));
    for (chol_solution, lu_solution) |chol_value, lu_value| try testing.expectApproxEqAbs(lu_value, chol_value, 1e-9);
    var indefinite = [2][2]f64{ .{ 1, 2 }, .{ 2, 1 } }; // autovalores 3 e −1
    try testing.expect(!cholesky(2, &indefinite, 2));
}

test "Jacobi: A = V diag(w) Vᵀ e V ortogonal" {
    const size = 4;
    const original = [size][size]f64{ .{ 4, 1, -2, 2 }, .{ 1, 2, 0, 1 }, .{ -2, 0, 3, -2 }, .{ 2, 1, -2, -1 } };
    var matrix = original;
    var eigenvalues: [size]f64 = undefined;
    var eigenvectors: [size][size]f64 = undefined;
    symEigen(size, &matrix, size, &eigenvalues, &eigenvectors);
    for (0..size) |i| for (0..size) |j| {
        var rebuilt: f64 = 0;
        var orthogonality: f64 = 0;
        for (0..size) |k| {
            rebuilt += eigenvectors[i][k] * eigenvalues[k] * eigenvectors[j][k];
            orthogonality += eigenvectors[k][i] * eigenvectors[k][j];
        }
        try testing.expectApproxEqAbs(original[i][j], rebuilt, 1e-10);
        try testing.expectApproxEqAbs(@as(f64, if (i == j) 1 else 0), orthogonality, 1e-10);
    };
    try testing.expectApproxEqAbs(@as(f64, 8), eigenvalues[0] + eigenvalues[1] + eigenvalues[2] + eigenvalues[3], 1e-10); // traço
}

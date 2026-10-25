//! Álgebra linear densa de tamanho fixo: fatoração LU com pivoteamento parcial e de Cholesky, e as
//! soluções de A x = b por elas. As matrizes são `[N][N]f64` com N conhecido em tempo de compilação e só
//! as primeiras `n` linhas e colunas usadas, então nada é alocado.
//!
//! LU: P A = L U por eliminação de Gauss com pivô parcial (Golub e Van Loan, Matrix Computations,
//! 4ª ed., alg. 3.4.1, a conferir no PDF). Cholesky: A = L Lᵀ para A simétrica positiva definida
//! (idem, alg. 4.2.1, a conferir no PDF). L e U ficam guardadas na própria A.
const std = @import("std");

/// fatora A (n × n) em P A = L U no lugar: abaixo da diagonal, L (diagonal unitária implícita); da
/// diagonal para cima, U. `piv[k]` = a linha trocada com a k no passo k. false se A é singular
pub fn luFactor(comptime N: usize, A: *[N][N]f64, n: usize, piv: *[N]usize) bool {
    std.debug.assert(n <= N);
    for (0..n) |k| {
        var p = k;
        var big = @abs(A[k][k]);
        for (k + 1..n) |i| {
            if (@abs(A[i][k]) > big) {
                big = @abs(A[i][k]);
                p = i;
            }
        }
        piv[k] = p;
        if (!(big > 0)) return false; // zero ou NaN
        if (p != k) std.mem.swap([N]f64, &A[k], &A[p]);
        const inv = 1.0 / A[k][k];
        for (k + 1..n) |i| {
            const m = A[i][k] * inv;
            A[i][k] = m;
            for (k + 1..n) |j| A[i][j] -= m * A[k][j];
        }
    }
    return true;
}

/// resolve A x = b com a fatoração de `luFactor`; b vira x
pub fn luSolve(comptime N: usize, LU: *const [N][N]f64, n: usize, piv: *const [N]usize, b: *[N]f64) void {
    for (0..n) |k| {
        if (piv[k] != k) std.mem.swap(f64, &b[k], &b[piv[k]]);
    }
    for (0..n) |i| { // L y = P b
        var s = b[i];
        for (0..i) |j| s -= LU[i][j] * b[j];
        b[i] = s;
    }
    var i = n;
    while (i > 0) { // U x = y
        i -= 1;
        var s = b[i];
        for (i + 1..n) |j| s -= LU[i][j] * b[j];
        b[i] = s / LU[i][i];
    }
}

/// A = L Lᵀ no lugar (L no triângulo de baixo; o de cima não é tocado). false se A não é positiva definida
pub fn cholesky(comptime N: usize, A: *[N][N]f64, n: usize) bool {
    std.debug.assert(n <= N);
    for (0..n) |j| {
        var d = A[j][j];
        for (0..j) |k| d -= A[j][k] * A[j][k];
        if (!(d > 0)) return false;
        const ljj = @sqrt(d);
        A[j][j] = ljj;
        for (j + 1..n) |i| {
            var s = A[i][j];
            for (0..j) |k| s -= A[i][k] * A[j][k];
            A[i][j] = s / ljj;
        }
    }
    return true;
}

/// resolve A x = b com a fatoração de `cholesky`; b vira x
pub fn cholSolve(comptime N: usize, L: *const [N][N]f64, n: usize, b: *[N]f64) void {
    for (0..n) |i| { // L y = b
        var s = b[i];
        for (0..i) |k| s -= L[i][k] * b[k];
        b[i] = s / L[i][i];
    }
    var i = n;
    while (i > 0) { // Lᵀ x = y
        i -= 1;
        var s = b[i];
        for (i + 1..n) |k| s -= L[k][i] * b[k];
        b[i] = s / L[i][i];
    }
}

/// A x = b de uma vez (A e b são copiados); false se A é singular
pub fn solve(comptime N: usize, A: [N][N]f64, n: usize, b: [N]f64, x: *[N]f64) bool {
    var M = A;
    var piv: [N]usize = undefined;
    if (!luFactor(N, &M, n, &piv)) return false;
    x.* = b;
    luSolve(N, &M, n, &piv, x);
    return true;
}

const testing = std.testing;

test "LU: sistema 3x3 de solução inteira, com troca de linha" {
    // x = (1, 2, 3); A[0][0] = 0 obriga o pivô
    const A = [3][3]f64{ .{ 0, 2, 1 }, .{ 1, 1, 1 }, .{ 2, 1, 3 } };
    const b = [3]f64{ 7, 6, 13 };
    var x: [3]f64 = undefined;
    try testing.expect(solve(3, A, 3, b, &x));
    for (x, [3]f64{ 1, 2, 3 }) |v, e| try testing.expectApproxEqAbs(e, v, 1e-12);
}

test "LU: matriz de Hilbert 5x5, resíduo pequeno; singular é recusada" {
    const N = 8;
    var A: [N][N]f64 = @splat(@splat(0));
    var b: [N]f64 = @splat(0);
    const n = 5;
    for (0..n) |i| {
        for (0..n) |j| A[i][j] = 1.0 / @as(f64, @floatFromInt(i + j + 1));
        b[i] = 1;
    }
    var x: [N]f64 = undefined;
    try testing.expect(solve(N, A, n, b, &x));
    for (0..n) |i| {
        var r = -b[i];
        for (0..n) |j| r += A[i][j] * x[j];
        try testing.expect(@abs(r) < 1e-9);
    }
    var S = [2][2]f64{ .{ 1, 2 }, .{ 2, 4 } };
    var piv: [2]usize = undefined;
    try testing.expect(!luFactor(2, &S, 2, &piv));
}

test "Cholesky: fator conhecido e solução igual à da LU" {
    // A = L Lᵀ com L = [[2,0,0],[6,1,0],[-8,5,3]] (Golub e Van Loan usam este tipo de exemplo)
    var A = [3][3]f64{ .{ 4, 12, -16 }, .{ 12, 37, -43 }, .{ -16, -43, 98 } };
    const A0 = A;
    try testing.expect(cholesky(3, &A, 3));
    const L = [3][3]f64{ .{ 2, 0, 0 }, .{ 6, 1, 0 }, .{ -8, 5, 3 } };
    for (0..3) |i| for (0..i + 1) |j| try testing.expectApproxEqAbs(L[i][j], A[i][j], 1e-12);
    var x = [3]f64{ 1, 2, 3 };
    cholSolve(3, &A, 3, &x);
    var y: [3]f64 = undefined;
    try testing.expect(solve(3, A0, 3, .{ 1, 2, 3 }, &y));
    for (x, y) |a, b| try testing.expectApproxEqAbs(b, a, 1e-9);
    var N = [2][2]f64{ .{ 1, 2 }, .{ 2, 1 } }; // autovalores 3 e −1
    try testing.expect(!cholesky(2, &N, 2));
}

//! Álgebra linear densa de tamanho fixo: fatoração LU com pivoteamento parcial e de Cholesky, e as
//! soluções de A x = b por elas. As matrizes são `[N][N]f64` com N conhecido em tempo de compilação e só
//! as primeiras `n` linhas e colunas usadas, então nada é alocado.
//!
//! LU: P A = L U por eliminação de Gauss com pivô parcial (Golub e Van Loan, Matrix Computations,
//! 4ª ed., alg. 3.4.1, a conferir no PDF). Cholesky: A = L Lᵀ para A simétrica positiva definida
//! (idem, alg. 4.2.1, a conferir no PDF). L e U ficam guardadas na própria A. Autovalores e autovetores de uma
//! simétrica: o método de Jacobi cíclico (idem, seção 8.5, a conferir no PDF), que gira a matriz até a parte fora
//! da diagonal sumir; para as matrizes pequenas do CMA-ES (até 32) é simples e preciso. Autovalores de uma matriz
//! qualquer (os polos de um modelo linear): balanceamento, redução a Hessenberg e QR com duplo deslocamento de Francis
//! (Press et al., Numerical Recipes, 3ª ed., seção 11.6, `balance`, `elmhes` e `hqr`; a conferir no PDF).
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

/// os autovalores de uma matriz real qualquer (n × n no canto de `matrix`, que é destruída): `real[i] + i imag[i]`,
/// os pares complexos lado a lado. false se o QR não convergiu em 30 iterações num autovalor
pub fn generalEigen(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize, real: *[capacity]f64, imag: *[capacity]f64) bool {
    std.debug.assert(size <= capacity);
    balance(capacity, matrix, size);
    hessenberg(capacity, matrix, size);
    return hessenbergQr(capacity, matrix, size, real, imag);
}

/// troca A por D⁻¹ A D, com D diagonal de potências de 2, até as normas de cada linha e da coluna dela ficarem
/// parecidas: os autovalores não mudam e o QR perde menos precisão (Numerical Recipes, `balance`)
fn balance(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize) void {
    const radix: f64 = 2;
    var done = false;
    while (!done) {
        done = true;
        for (0..size) |i| {
            var column: f64 = 0;
            var row: f64 = 0;
            for (0..size) |j| if (j != i) {
                column += @abs(matrix[j][i]);
                row += @abs(matrix[i][j]);
            };
            if (column == 0 or row == 0) continue;
            const total = column + row;
            var factor: f64 = 1;
            var limit = row / radix;
            while (column < limit) {
                factor *= radix;
                column *= radix * radix;
            }
            limit = row * radix;
            while (column > limit) {
                factor /= radix;
                column /= radix * radix;
            }
            if ((column + row) / factor < 0.95 * total) {
                done = false;
                for (0..size) |j| matrix[i][j] /= factor;
                for (0..size) |j| matrix[j][i] *= factor;
            }
        }
    }
}

/// reduz A à forma de Hessenberg superior (zeros abaixo da subdiagonal) por eliminação de Gauss com pivô, como uma
/// semelhança: os autovalores não mudam (Numerical Recipes, `elmhes`)
fn hessenberg(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize) void {
    var column: usize = 1;
    while (column + 1 < size) : (column += 1) {
        var pivot: f64 = 0;
        var pivot_row = column;
        for (column..size) |j| if (@abs(matrix[j][column - 1]) > @abs(pivot)) {
            pivot = matrix[j][column - 1];
            pivot_row = j;
        };
        if (pivot_row != column) {
            for (column - 1..size) |j| std.mem.swap(f64, &matrix[pivot_row][j], &matrix[column][j]);
            for (0..size) |j| std.mem.swap(f64, &matrix[j][pivot_row], &matrix[j][column]);
        }
        if (pivot == 0) continue;
        for (column + 1..size) |i| {
            const factor = matrix[i][column - 1] / pivot;
            if (factor == 0) continue;
            matrix[i][column - 1] = factor;
            for (column..size) |j| matrix[i][j] -= factor * matrix[column][j];
            for (0..size) |j| matrix[j][column] += factor * matrix[j][i];
        }
    }
    for (2..@max(size, 2)) |i| for (0..i - 1) |j| {
        matrix[i][j] = 0; // os multiplicadores ficaram ali; o QR quer zeros
    };
}

/// os autovalores de uma Hessenberg superior pelo QR com duplo deslocamento de Francis (Numerical Recipes, `hqr`): a
/// matriz vai se partindo em blocos 1 × 1 (um autovalor real) e 2 × 2 (um par, real ou complexo) a partir de baixo
fn hessenbergQr(comptime capacity: usize, matrix: *[capacity][capacity]f64, size: usize, real: *[capacity]f64, imag: *[capacity]f64) bool {
    const Index = isize;
    const at = struct {
        fn cell(a: *[capacity][capacity]f64, i: Index, j: Index) *f64 {
            return &a[@intCast(i)][@intCast(j)];
        }
    }.cell;
    const epsilon = std.math.floatEps(f64);
    var norm: f64 = 0;
    for (0..size) |i| for (if (i > 0) i - 1 else 0..size) |j| {
        norm += @abs(matrix[i][j]);
    };
    var last: Index = @as(Index, @intCast(size)) - 1;
    var shift: f64 = 0;
    while (last >= 0) {
        var iterations: usize = 0;
        var low: Index = undefined;
        while (true) {
            // o começo do bloco que ainda não se partiu: o primeiro elemento da subdiagonal desprezível
            low = last;
            while (low > 0) : (low -= 1) {
                var scale = @abs(at(matrix, low - 1, low - 1).*) + @abs(at(matrix, low, low).*);
                if (scale == 0) scale = norm;
                if (@abs(at(matrix, low, low - 1).*) <= epsilon * scale) {
                    at(matrix, low, low - 1).* = 0;
                    break;
                }
            }
            var x = at(matrix, last, last).*;
            if (low == last) { // um autovalor real
                real[@intCast(last)] = x + shift;
                imag[@intCast(last)] = 0;
                last -= 1;
                break;
            }
            var y = at(matrix, last - 1, last - 1).*;
            var w = at(matrix, last, last - 1).* * at(matrix, last - 1, last).*;
            if (low == last - 1) { // um par: as raízes do bloco 2 × 2
                const p = 0.5 * (y - x);
                const q = p * p + w;
                const root = @sqrt(@abs(q));
                x += shift;
                const lower: usize = @intCast(last - 1);
                const upper: usize = @intCast(last);
                if (q >= 0) {
                    const z = p + std.math.copysign(root, p);
                    real[lower] = x + z;
                    real[upper] = if (z != 0) x - w / z else x + z;
                    imag[lower] = 0;
                    imag[upper] = 0;
                } else {
                    real[lower] = x + p;
                    real[upper] = x + p;
                    imag[lower] = root;
                    imag[upper] = -root;
                }
                last -= 2;
                break;
            }
            if (iterations == 30) return false;
            if (iterations == 10 or iterations == 20) { // deslocamento excepcional, para sair de um ciclo
                shift += x;
                var i: Index = 0;
                while (i <= last) : (i += 1) at(matrix, i, i).* -= x;
                const scale = @abs(at(matrix, last, last - 1).*) + @abs(at(matrix, last - 1, last - 2).*);
                x = 0.75 * scale;
                y = x;
                w = -0.4375 * scale * scale;
            }
            iterations += 1;
            // onde começar o passo duplo: dois elementos da subdiagonal pequenos seguidos
            var start: Index = last - 2;
            var p: f64 = 0;
            var q: f64 = 0;
            var r: f64 = 0;
            while (start >= low) : (start -= 1) {
                const z = at(matrix, start, start).*;
                const rx = x - z;
                const sy = y - z;
                p = (rx * sy - w) / at(matrix, start + 1, start).* + at(matrix, start, start + 1).*;
                q = at(matrix, start + 1, start + 1).* - z - rx - sy;
                r = at(matrix, start + 2, start + 1).*;
                const scale = @abs(p) + @abs(q) + @abs(r);
                p /= scale;
                q /= scale;
                r /= scale;
                if (start == low) break;
                const u = @abs(at(matrix, start, start - 1).*) * (@abs(q) + @abs(r));
                const v = @abs(p) * (@abs(at(matrix, start - 1, start - 1).*) + @abs(z) + @abs(at(matrix, start + 1, start + 1).*));
                if (u <= epsilon * v) break;
            }
            var i: Index = start;
            while (i < last - 1) : (i += 1) {
                at(matrix, i + 2, i).* = 0;
                if (i != start) at(matrix, i + 2, i - 1).* = 0;
            }
            // o passo QR duplo implícito, com refletores de Householder de 3 elementos
            var k: Index = start;
            while (k < last) : (k += 1) {
                if (k != start) {
                    p = at(matrix, k, k - 1).*;
                    q = at(matrix, k + 1, k - 1).*;
                    r = if (k + 1 != last) at(matrix, k + 2, k - 1).* else 0;
                    x = @abs(p) + @abs(q) + @abs(r);
                    if (x != 0) {
                        p /= x;
                        q /= x;
                        r /= x;
                    }
                }
                const s = std.math.copysign(@sqrt(p * p + q * q + r * r), p);
                if (s == 0) continue;
                if (k == start) {
                    if (low != start) at(matrix, k, k - 1).* = -at(matrix, k, k - 1).*;
                } else at(matrix, k, k - 1).* = -s * x;
                p += s;
                x = p / s;
                y = q / s;
                const z = r / s;
                q /= p;
                r /= p;
                var j: Index = k;
                while (j <= last) : (j += 1) {
                    var sum = at(matrix, k, j).* + q * at(matrix, k + 1, j).*;
                    if (k + 1 != last) {
                        sum += r * at(matrix, k + 2, j).*;
                        at(matrix, k + 2, j).* -= sum * z;
                    }
                    at(matrix, k + 1, j).* -= sum * y;
                    at(matrix, k, j).* -= sum * x;
                }
                const bottom = @min(last, k + 3);
                var row: Index = low;
                while (row <= bottom) : (row += 1) {
                    var sum = x * at(matrix, row, k).* + y * at(matrix, row, k + 1).*;
                    if (k + 1 != last) {
                        sum += z * at(matrix, row, k + 2).*;
                        at(matrix, row, k + 2).* -= sum * r;
                    }
                    at(matrix, row, k + 1).* -= sum * q;
                    at(matrix, row, k).* -= sum;
                }
            }
            if (!(low < last - 1)) break; // NR: o bloco ficou pequeno, recomeça a contagem
        }
    }
    return true;
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

/// os autovalores achados batem com os esperados, em qualquer ordem
fn expectEigenvalues(comptime size: usize, matrix: [size][size]f64, expected: []const [2]f64) !void {
    var work = matrix;
    var real: [size]f64 = undefined;
    var imag: [size]f64 = undefined;
    try testing.expect(generalEigen(size, &work, size, &real, &imag));
    for (expected) |value| {
        var closest: f64 = std.math.inf(f64);
        for (0..size) |i| closest = @min(closest, @abs(real[i] - value[0]) + @abs(imag[i] - value[1]));
        try testing.expect(closest < 1e-9);
    }
}

test "autovalores de uma matriz qualquer: companheira com par complexo, triangular e a simétrica do Jacobi" {
    // (λ + 1)(λ + 2)(λ² + 2λ + 5) = λ⁴ + 5λ³ + 13λ² + 19λ + 10: raízes −1, −2 e −1 ± 2i
    const companion = [4][4]f64{ .{ -5, -13, -19, -10 }, .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } };
    try expectEigenvalues(4, companion, &.{ .{ -1, 0 }, .{ -2, 0 }, .{ -1, 2 }, .{ -1, -2 } });
    // triangular: a própria diagonal
    const triangular = [3][3]f64{ .{ 3, 7, -1 }, .{ 0, -0.5, 4 }, .{ 0, 0, 2 } };
    try expectEigenvalues(3, triangular, &.{ .{ 3, 0 }, .{ -0.5, 0 }, .{ 2, 0 } });
    // uma rotação com amortecimento: −0,2 ± 3i, e um modo instável 0,5
    const oscillator = [3][3]f64{ .{ -0.2, 3, 0 }, .{ -3, -0.2, 1 }, .{ 0, 0, 0.5 } };
    try expectEigenvalues(3, oscillator, &.{ .{ -0.2, 3 }, .{ -0.2, -3 }, .{ 0.5, 0 } });
    // a mesma matriz do teste do Jacobi: os dois métodos dão os mesmos autovalores
    const symmetric = [4][4]f64{ .{ 4, 1, -2, 2 }, .{ 1, 2, 0, 1 }, .{ -2, 0, 3, -2 }, .{ 2, 1, -2, -1 } };
    var jacobi = symmetric;
    var values: [4]f64 = undefined;
    var vectors: [4][4]f64 = undefined;
    symEigen(4, &jacobi, 4, &values, &vectors);
    try expectEigenvalues(4, symmetric, &.{ .{ values[0], 0 }, .{ values[1], 0 }, .{ values[2], 0 }, .{ values[3], 0 } });
}

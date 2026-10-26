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

/// o tamanho do sistema com `m` pontos em `n` variáveis
pub fn size(n: usize, m: usize) usize {
    return m + n + 1;
}

fn dist3(a: []const f64, b: []const f64) f64 {
    var d2: f64 = 0;
    for (a, b) |p, q| d2 += (p - q) * (p - q);
    return d2 * @sqrt(d2);
}

/// LU com pivoteamento parcial de `A` (k × k, linha a linha) no lugar, resolvendo `b` junto; false se singular
fn luSolveFlat(A: []f64, k: usize, b: []f64) bool {
    var scale: f64 = 0;
    for (A[0 .. k * k]) |v| scale = @max(scale, @abs(v));
    const tiny = 1e-13 * @max(scale, 1e-300);
    for (0..k) |col| {
        var p = col;
        var big = @abs(A[col * k + col]);
        for (col + 1..k) |r| {
            const v = @abs(A[r * k + col]);
            if (v > big) {
                big = v;
                p = r;
            }
        }
        if (!(big > tiny)) return false;
        if (p != col) {
            for (0..k) |j| std.mem.swap(f64, &A[col * k + j], &A[p * k + j]);
            std.mem.swap(f64, &b[col], &b[p]);
        }
        const piv = A[col * k + col];
        for (col + 1..k) |r| {
            const f = A[r * k + col] / piv;
            if (f == 0) continue;
            for (col..k) |j| A[r * k + j] -= f * A[col * k + j];
            b[r] -= f * b[col];
        }
    }
    var i = k;
    while (i > 0) {
        i -= 1;
        var s = b[i];
        for (i + 1..k) |j| s -= A[i * k + j] * b[j];
        b[i] = s / A[i * k + i];
    }
    return true;
}

/// ajusta o substituto nos `m` pontos `xs` (m × n, linha a linha) com valores `ys`; `coef` recebe (λ₁..λₘ, c₀, c₁..cₙ)
/// e `work` tem (m + n + 1)² valores. false se os pontos não determinam a cauda (todos num hiperplano, ou repetidos)
pub fn fit(n: usize, m: usize, xs: []const f64, ys: []const f64, work: []f64, coef: []f64) bool {
    if (n == 0 or n > max_n or m < n + 1) return false;
    const k = size(n, m);
    if (work.len < k * k or coef.len < k) return false;
    const A = work[0 .. k * k];
    @memset(A, 0);
    for (0..m) |i| {
        if (!std.math.isFinite(ys[i])) return false;
        const xi = xs[i * n ..][0..n];
        for (i + 1..m) |j| {
            const v = dist3(xi, xs[j * n ..][0..n]);
            A[i * k + j] = v;
            A[j * k + i] = v;
        }
        A[i * k + m] = 1;
        A[m * k + i] = 1;
        for (0..n) |d| {
            A[i * k + m + 1 + d] = xi[d];
            A[(m + 1 + d) * k + i] = xi[d];
        }
        coef[i] = ys[i];
    }
    @memset(coef[m..k], 0);
    return luSolveFlat(A, k, coef[0..k]);
}

/// o valor do substituto em `x` (n valores)
pub fn eval(n: usize, m: usize, xs: []const f64, coef: []const f64, x: []const f64) f64 {
    var s = coef[m];
    for (0..n) |d| s += coef[m + 1 + d] * x[d];
    for (0..m) |i| s += coef[i] * dist3(x, xs[i * n ..][0..n]);
    return s;
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
        const a = @as(f64, @floatFromInt(i)) / 4;
        const b = @as(f64, @floatFromInt(j)) / 4;
        xs[2 * (5 * i + j)] = a;
        xs[2 * (5 * i + j) + 1] = b;
        ys[5 * i + j] = -((a - 0.6) * (a - 0.6) + (b - 0.6) * (b - 0.6));
    };
    var work: [28 * 28]f64 = undefined;
    var coef: [28]f64 = undefined;
    try std.testing.expect(fit(2, 25, &xs, &ys, &work, &coef));
    for (0..4) |i| for (0..4) |j| {
        const a = (@as(f64, @floatFromInt(i)) + 0.5) / 4;
        const b = (@as(f64, @floatFromInt(j)) + 0.5) / 4;
        const y = -((a - 0.6) * (a - 0.6) + (b - 0.6) * (b - 0.6));
        try std.testing.expectApproxEqAbs(y, eval(2, 25, &xs, &coef, &.{ a, b }), 0.01);
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

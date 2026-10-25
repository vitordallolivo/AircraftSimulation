//! CMA-ES: a estratégia evolutiva com adaptação da matriz de covariância, para as variáveis contínuas do aeroopt
//! (envergadura, área, diedro, VH...). O algoritmo genético anda gene por gene, com uma mutação do mesmo tamanho em
//! toda direção; o CMA-ES aprende, de geração em geração, a forma da região boa (uma elipse que se alonga onde a nota
//! melhora e encolhe onde piora) e sorteia os próximos aviões dentro dela. Com mais de três ou quatro variáveis ele
//! costuma achar o ótimo com bem menos avaliações.
//!
//! As contas e as constantes são as do tutorial de Hansen ("The CMA Evolution Strategy: A Tutorial",
//! arXiv:1604.00772, 2016, tabela 1 e equações 39 a 47; a conferir no PDF): (μ/μ_w, λ) com pesos positivos,
//! caminho de evolução p_c e p_σ, atualização de posto um e de posto μ, passo σ pelo comprimento de p_σ.
//! As variáveis entram normalizadas em [0, 1] (o Python divide pela faixa); o ponto sorteado fora da caixa é
//! levado para a borda, e é o ponto levado que se avalia e que entra na atualização.
//!
//! O Python pede uma geração (`ask`), avalia cada avião e devolve a nota (`tell`); maior é melhor, NaN é o pior.
//! Sorteios por semente e geração: a mesma entrada dá a mesma busca. As contas de matriz usam vetores do Zig
//! (`@Vector`): com `-Dcpu=native` numa máquina com AVX-512 elas viram instruções de 512 bits.
const std = @import("std");
const la = @import("../math/linalg.zig");

pub const max_n = 32;
pub const max_lambda = 64;
const VL = std.simd.suggestVectorLength(f64) orelse 4;
const Vec = @Vector(VL, f64);

pub const CmaState = extern struct {
    n: i32 = 0,
    lambda: i32 = 0,
    mu: i32 = 0,
    generation: i32 = 0,
    seed: i32 = 1,
    sigma: f64 = 0.3,
    mueff: f64 = 0,
    cc: f64 = 0,
    cs: f64 = 0,
    c1: f64 = 0,
    cmu: f64 = 0,
    damps: f64 = 0,
    chi_n: f64 = 0,
    weights: [max_lambda]f64 = @splat(0),
    mean: [max_n]f64 = @splat(0),
    pc: [max_n]f64 = @splat(0),
    ps: [max_n]f64 = @splat(0),
    D: [max_n]f64 = @splat(1), // raiz dos autovalores de C
    C: [max_n][max_n]f64 = @splat(@splat(0)),
    B: [max_n][max_n]f64 = @splat(@splat(0)), // autovetores de C (colunas)
};

/// prepara o estado: `x0` (normalizado) é a média inicial e `sigma0` o passo; `lambda` ≤ 0 usa 4 + ⌊3 ln n⌋
pub fn init(s: *CmaState, n: usize, x0: []const f64, sigma0: f64, lambda: i32, seed: i32) void {
    s.* = .{};
    const nf: f64 = @floatFromInt(n);
    const lam: usize = if (lambda > 0) @intCast(lambda) else 4 + @as(usize, @intFromFloat(@floor(3 * @log(nf))));
    const lam_c = @min(lam, max_lambda);
    const mu = lam_c / 2;
    s.n = @intCast(n);
    s.lambda = @intCast(lam_c);
    s.mu = @intCast(mu);
    s.seed = seed;
    s.sigma = sigma0;
    // pesos: ln((λ+1)/2) − ln i, normalizados (tabela 1)
    var sum: f64 = 0;
    for (0..mu) |i| {
        s.weights[i] = @log((@as(f64, @floatFromInt(lam_c)) + 1) / 2) - @log(@as(f64, @floatFromInt(i + 1)));
        sum += s.weights[i];
    }
    var sq: f64 = 0;
    for (0..mu) |i| {
        s.weights[i] /= sum;
        sq += s.weights[i] * s.weights[i];
    }
    s.mueff = 1 / sq;
    const me = s.mueff;
    s.cc = (4 + me / nf) / (nf + 4 + 2 * me / nf);
    s.cs = (me + 2) / (nf + me + 5);
    s.c1 = 2 / ((nf + 1.3) * (nf + 1.3) + me);
    s.cmu = @min(1 - s.c1, 2 * (me - 2 + 1 / me) / ((nf + 2) * (nf + 2) + me));
    s.damps = 1 + 2 * @max(0, @sqrt((me - 1) / (nf + 1)) - 1) + s.cs;
    s.chi_n = @sqrt(nf) * (1 - 1 / (4 * nf) + 1 / (21 * nf * nf));
    for (0..n) |i| {
        s.mean[i] = std.math.clamp(x0[i], 0, 1);
        s.C[i][i] = 1;
        s.B[i][i] = 1;
    }
}

fn rng(s: *const CmaState) std.Random.DefaultPrng {
    const k: u64 = @as(u64, @intCast(@max(s.seed, 0))) *% 2_654_435_761 +% @as(u64, @intCast(@max(s.generation, 0)));
    return std.Random.DefaultPrng.init(k);
}

/// produto escalar das n primeiras posições, em blocos de VL
fn dotN(a: []const f64, b: []const f64, n: usize) f64 {
    var acc: Vec = @splat(0);
    var i: usize = 0;
    while (i + VL <= n) : (i += VL) {
        const va: Vec = a[i..][0..VL].*;
        const vb: Vec = b[i..][0..VL].*;
        acc += va * vb;
    }
    var r = @reduce(.Add, acc);
    while (i < n) : (i += 1) r += a[i] * b[i];
    return r;
}

/// linha += k · v (as n primeiras posições), em blocos de VL
fn axpy(row: []f64, k: f64, v: []const f64, n: usize) void {
    const kv: Vec = @splat(k);
    var i: usize = 0;
    while (i + VL <= n) : (i += VL) {
        const vr: Vec = row[i..][0..VL].*;
        const vv: Vec = v[i..][0..VL].*;
        row[i..][0..VL].* = vr + kv * vv;
    }
    while (i < n) : (i += 1) row[i] += k * v[i];
}

/// a geração: λ pontos x = m + σ B D z, z ~ N(0, I), levados para dentro de [0, 1] (`out`: λ × n)
pub fn ask(s: *const CmaState, out: []f64) void {
    var p = rng(s);
    const r = p.random();
    const n: usize = @intCast(s.n);
    const lam: usize = @intCast(s.lambda);
    for (0..lam) |k| {
        var dz: [max_n]f64 = @splat(0);
        for (0..n) |j| dz[j] = s.D[j] * r.floatNorm(f64);
        for (0..n) |i| {
            const y = dotN(&s.B[i], &dz, n); // (B D z)_i
            out[k * n + i] = std.math.clamp(s.mean[i] + s.sigma * y, 0, 1);
        }
    }
}

/// atualiza a média, os caminhos, C e σ com a nota de cada ponto (maior é melhor; NaN é o pior)
pub fn tell(s: *CmaState, xs: []const f64, fit: []const f64) void {
    const n: usize = @intCast(s.n);
    const lam: usize = @intCast(s.lambda);
    const mu: usize = @intCast(s.mu);
    var order: [max_lambda]usize = undefined;
    for (0..lam) |i| order[i] = i;
    for (1..lam) |i| { // inserção, do melhor para o pior (empate: a ordem de antes)
        var j = i;
        while (j > 0 and better(fit, order[j], order[j - 1])) : (j -= 1) std.mem.swap(usize, &order[j], &order[j - 1]);
    }
    const old = s.mean;
    var mean: [max_n]f64 = @splat(0);
    for (0..mu) |i| axpy(&mean, s.weights[i], xs[order[i] * n ..][0..n], n);
    var yw: [max_n]f64 = @splat(0); // (m' − m) / σ
    for (0..n) |i| yw[i] = (mean[i] - old[i]) / s.sigma;
    // C^(−1/2) y_w = B D⁻¹ Bᵀ y_w
    var t: [max_n]f64 = @splat(0);
    for (0..n) |j| {
        var a: f64 = 0;
        for (0..n) |i| a += s.B[i][j] * yw[i];
        t[j] = a / s.D[j];
    }
    const kps = @sqrt(s.cs * (2 - s.cs) * s.mueff);
    for (0..n) |i| s.ps[i] = (1 - s.cs) * s.ps[i] + kps * dotN(&s.B[i], &t, n);
    const nf: f64 = @floatFromInt(n);
    const g: f64 = @floatFromInt(s.generation + 1);
    const ps_norm = @sqrt(dotN(&s.ps, &s.ps, n));
    const hsig: f64 = if (ps_norm / @sqrt(1 - std.math.pow(f64, 1 - s.cs, 2 * g)) / s.chi_n < 1.4 + 2 / (nf + 1)) 1 else 0;
    const kpc = hsig * @sqrt(s.cc * (2 - s.cc) * s.mueff);
    for (0..n) |i| s.pc[i] = (1 - s.cc) * s.pc[i] + kpc * yw[i];
    // C ← (1 − c1 − cμ) C + c1 (p_c p_cᵀ + (1 − h_σ) c_c (2 − c_c) C) + cμ Σ w_i y_i y_iᵀ
    const keep = 1 - s.c1 - s.cmu + (1 - hsig) * s.c1 * s.cc * (2 - s.cc);
    for (0..n) |i| {
        for (0..n) |j| s.C[i][j] *= keep;
        axpy(&s.C[i], s.c1 * s.pc[i], &s.pc, n);
    }
    for (0..mu) |k| {
        var y: [max_n]f64 = @splat(0);
        const x = xs[order[k] * n ..][0..n];
        for (0..n) |i| y[i] = (x[i] - old[i]) / s.sigma;
        for (0..n) |i| axpy(&s.C[i], s.cmu * s.weights[k] * y[i], &y, n);
    }
    s.sigma *= @exp((s.cs / s.damps) * (ps_norm / s.chi_n - 1));
    s.sigma = std.math.clamp(s.sigma, 1e-8, 1.0);
    s.mean = mean;
    s.generation += 1;
    // B e D novos: C = B diag(D²) Bᵀ (C simétrica por construção; a média das metades tira o arredondamento)
    var A: [max_n][max_n]f64 = undefined;
    for (0..n) |i| for (0..n) |j| {
        A[i][j] = 0.5 * (s.C[i][j] + s.C[j][i]);
    };
    var w: [max_n]f64 = undefined;
    la.symEigen(max_n, &A, n, &w, &s.B);
    for (0..n) |i| s.D[i] = @sqrt(@max(w[i], 1e-20));
}

fn better(fit: []const f64, a: usize, b: usize) bool {
    const fa = if (std.math.isNan(fit[a])) -std.math.inf(f64) else fit[a];
    const fb = if (std.math.isNan(fit[b])) -std.math.inf(f64) else fit[b];
    return fa > fb or (fa == fb and a < b);
}

// ------------------------------------------------------------------ testes
fn runOn(comptime f: fn ([]const f64) f64, n: usize, evals: usize, seed: i32) struct { best: f64, used: usize } {
    var s: CmaState = undefined;
    var x0: [max_n]f64 = @splat(0.2);
    init(&s, n, x0[0..n], 0.3, 0, seed);
    var xs: [max_lambda * max_n]f64 = undefined;
    var fit: [max_lambda]f64 = undefined;
    var best = -std.math.inf(f64);
    var used: usize = 0;
    const lam: usize = @intCast(s.lambda);
    while (used + lam <= evals) {
        ask(&s, xs[0 .. lam * n]);
        for (0..lam) |k| {
            fit[k] = f(xs[k * n ..][0..n]);
            best = @max(best, fit[k]);
        }
        used += lam;
        tell(&s, xs[0 .. lam * n], fit[0..lam]);
    }
    return .{ .best = best, .used = used };
}

fn ellipsoid(x: []const f64) f64 { // máximo 0 em x = 0,7; escala 1 a 1000 entre os eixos (mal condicionada)
    var r: f64 = 0;
    for (x, 0..) |v, i| {
        const k = std.math.pow(f64, 1000, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(x.len - 1)));
        r -= k * (v - 0.7) * (v - 0.7);
    }
    return r;
}

fn rosen(x: []const f64) f64 { // Rosenbrock em [0, 1]: máximo 0 em x = 0,5 (o vale curvo)
    var r: f64 = 0;
    for (0..x.len - 1) |i| {
        const a = 4 * x[i] - 1;
        const b = 4 * x[i + 1] - 1;
        r -= 100 * (b - a * a) * (b - a * a) + (1 - a) * (1 - a);
    }
    return r;
}

test "CMA-ES acha o máximo de uma elipse mal condicionada e do vale de Rosenbrock" {
    const e = runOn(ellipsoid, 8, 3200, 3);
    try std.testing.expect(e.best > -1e-6);
    const r = runOn(rosen, 4, 2400, 5);
    try std.testing.expect(r.best > -1e-4);
}

test "a mesma semente dá a mesma busca, os pontos ficam na caixa e C fica simétrica positiva" {
    var s: CmaState = undefined;
    const x0 = [3]f64{ 0.5, 0.1, 0.9 };
    init(&s, 3, &x0, 0.5, 6, 11);
    try std.testing.expectEqual(@as(i32, 6), s.lambda);
    var a: [18]f64 = undefined;
    var b: [18]f64 = undefined;
    ask(&s, &a);
    ask(&s, &b);
    try std.testing.expectEqualSlices(f64, &a, &b);
    for (a) |v| try std.testing.expect(v >= 0 and v <= 1);
    const fit = [6]f64{ 1, std.math.nan(f64), 3, 2, 0, 5 };
    tell(&s, &a, &fit);
    for (0..3) |i| {
        try std.testing.expect(s.D[i] > 0);
        for (0..3) |j| try std.testing.expectApproxEqAbs(s.C[i][j], s.C[j][i], 1e-14);
    }
}

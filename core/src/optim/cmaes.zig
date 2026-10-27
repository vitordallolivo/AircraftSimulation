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
const linalg = @import("../math/linalg.zig");

pub const max_n = 32;
pub const max_lambda = 64;
const simd_len = std.simd.suggestVectorLength(f64) orelse 4;
const Vec = @Vector(simd_len, f64);

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

/// prepara o estado: `x0` (normalizado) é a média inicial e `sigma0` o passo; `lambda` ≤ 0 usa 4 + ⌊3 ln dims⌋
pub fn init(cma: *CmaState, dims: usize, x0: []const f64, sigma0: f64, lambda: i32, seed: i32) void {
    cma.* = .{};
    const dims_f: f64 = @floatFromInt(dims);
    const lam: usize = if (lambda > 0) @intCast(lambda) else 4 + @as(usize, @intFromFloat(@floor(3 * @log(dims_f))));
    const lam_c = @min(lam, max_lambda);
    const mu = lam_c / 2;
    cma.n = @intCast(dims);
    cma.lambda = @intCast(lam_c);
    cma.mu = @intCast(mu);
    cma.seed = seed;
    cma.sigma = sigma0;
    // pesos: ln((λ+1)/2) − ln i, normalizados (tabela 1)
    var sum: f64 = 0;
    for (0..mu) |i| {
        cma.weights[i] = @log((@as(f64, @floatFromInt(lam_c)) + 1) / 2) - @log(@as(f64, @floatFromInt(i + 1)));
        sum += cma.weights[i];
    }
    var sum_sq: f64 = 0;
    for (0..mu) |i| {
        cma.weights[i] /= sum;
        sum_sq += cma.weights[i] * cma.weights[i];
    }
    cma.mueff = 1 / sum_sq;
    const mu_eff = cma.mueff;
    cma.cc = (4 + mu_eff / dims_f) / (dims_f + 4 + 2 * mu_eff / dims_f);
    cma.cs = (mu_eff + 2) / (dims_f + mu_eff + 5);
    cma.c1 = 2 / ((dims_f + 1.3) * (dims_f + 1.3) + mu_eff);
    cma.cmu = @min(1 - cma.c1, 2 * (mu_eff - 2 + 1 / mu_eff) / ((dims_f + 2) * (dims_f + 2) + mu_eff));
    cma.damps = 1 + 2 * @max(0, @sqrt((mu_eff - 1) / (dims_f + 1)) - 1) + cma.cs;
    cma.chi_n = @sqrt(dims_f) * (1 - 1 / (4 * dims_f) + 1 / (21 * dims_f * dims_f));
    for (0..dims) |i| {
        cma.mean[i] = std.math.clamp(x0[i], 0, 1);
        cma.C[i][i] = 1;
        cma.B[i][i] = 1;
    }
}

fn rng(cma: *const CmaState) std.Random.DefaultPrng {
    const seed_mix: u64 = @as(u64, @intCast(@max(cma.seed, 0))) *% 2_654_435_761 +% @as(u64, @intCast(@max(cma.generation, 0)));
    return std.Random.DefaultPrng.init(seed_mix);
}

/// produto escalar das `len` primeiras posições, em blocos de simd_len
fn dotN(lhs: []const f64, rhs: []const f64, len: usize) f64 {
    var acc: Vec = @splat(0);
    var i: usize = 0;
    while (i + simd_len <= len) : (i += simd_len) {
        const lhs_v: Vec = lhs[i..][0..simd_len].*;
        const rhs_v: Vec = rhs[i..][0..simd_len].*;
        acc += lhs_v * rhs_v;
    }
    var total = @reduce(.Add, acc);
    while (i < len) : (i += 1) total += lhs[i] * rhs[i];
    return total;
}

/// linha += scale · vec_in (as `len` primeiras posições), em blocos de simd_len
fn axpy(row: []f64, scale: f64, vec_in: []const f64, len: usize) void {
    const scale_v: Vec = @splat(scale);
    var i: usize = 0;
    while (i + simd_len <= len) : (i += simd_len) {
        const row_v: Vec = row[i..][0..simd_len].*;
        const in_v: Vec = vec_in[i..][0..simd_len].*;
        row[i..][0..simd_len].* = row_v + scale_v * in_v;
    }
    while (i < len) : (i += 1) row[i] += scale * vec_in[i];
}

/// a geração: λ pontos x = m + σ B D z, z ~ N(0, I), levados para dentro de [0, 1] (`out`: λ × dims)
pub fn ask(cma: *const CmaState, out: []f64) void {
    var prng = rng(cma);
    const random = prng.random();
    const dims: usize = @intCast(cma.n);
    const lam: usize = @intCast(cma.lambda);
    for (0..lam) |k| {
        var dz: [max_n]f64 = @splat(0);
        for (0..dims) |j| dz[j] = cma.D[j] * random.floatNorm(f64);
        for (0..dims) |i| {
            const offset = dotN(&cma.B[i], &dz, dims); // (B D z)_i
            out[k * dims + i] = std.math.clamp(cma.mean[i] + cma.sigma * offset, 0, 1);
        }
    }
}

/// atualiza a média, os caminhos, C e σ com a nota de cada ponto (maior é melhor; NaN é o pior)
pub fn tell(cma: *CmaState, xs: []const f64, fit: []const f64) void {
    const dims: usize = @intCast(cma.n);
    const lam: usize = @intCast(cma.lambda);
    const mu: usize = @intCast(cma.mu);
    var order: [max_lambda]usize = undefined;
    for (0..lam) |i| order[i] = i;
    for (1..lam) |i| { // inserção, do melhor para o pior (empate: a ordem de antes)
        var j = i;
        while (j > 0 and better(fit, order[j], order[j - 1])) : (j -= 1) std.mem.swap(usize, &order[j], &order[j - 1]);
    }
    const old = cma.mean;
    var mean: [max_n]f64 = @splat(0);
    for (0..mu) |i| axpy(&mean, cma.weights[i], xs[order[i] * dims ..][0..dims], dims);
    var yw: [max_n]f64 = @splat(0); // (m' − m) / σ
    for (0..dims) |i| yw[i] = (mean[i] - old[i]) / cma.sigma;
    // C^(−1/2) y_w = B D⁻¹ Bᵀ y_w
    var whitened: [max_n]f64 = @splat(0);
    for (0..dims) |j| {
        var acc: f64 = 0;
        for (0..dims) |i| acc += cma.B[i][j] * yw[i];
        whitened[j] = acc / cma.D[j];
    }
    const kps = @sqrt(cma.cs * (2 - cma.cs) * cma.mueff);
    for (0..dims) |i| cma.ps[i] = (1 - cma.cs) * cma.ps[i] + kps * dotN(&cma.B[i], &whitened, dims);
    const dims_f: f64 = @floatFromInt(dims);
    const gen_f: f64 = @floatFromInt(cma.generation + 1);
    const ps_norm = @sqrt(dotN(&cma.ps, &cma.ps, dims));
    const hsig: f64 = if (ps_norm / @sqrt(1 - std.math.pow(f64, 1 - cma.cs, 2 * gen_f)) / cma.chi_n < 1.4 + 2 / (dims_f + 1)) 1 else 0;
    const kpc = hsig * @sqrt(cma.cc * (2 - cma.cc) * cma.mueff);
    for (0..dims) |i| cma.pc[i] = (1 - cma.cc) * cma.pc[i] + kpc * yw[i];
    // C ← (1 − c1 − cμ) C + c1 (p_c p_cᵀ + (1 − h_σ) c_c (2 − c_c) C) + cμ Σ w_i y_i y_iᵀ
    const keep = 1 - cma.c1 - cma.cmu + (1 - hsig) * cma.c1 * cma.cc * (2 - cma.cc);
    for (0..dims) |i| {
        for (0..dims) |j| cma.C[i][j] *= keep;
        axpy(&cma.C[i], cma.c1 * cma.pc[i], &cma.pc, dims);
    }
    for (0..mu) |k| {
        var step_vec: [max_n]f64 = @splat(0);
        const point = xs[order[k] * dims ..][0..dims];
        for (0..dims) |i| step_vec[i] = (point[i] - old[i]) / cma.sigma;
        for (0..dims) |i| axpy(&cma.C[i], cma.cmu * cma.weights[k] * step_vec[i], &step_vec, dims);
    }
    cma.sigma *= @exp((cma.cs / cma.damps) * (ps_norm / cma.chi_n - 1));
    cma.sigma = std.math.clamp(cma.sigma, 1e-8, 1.0);
    cma.mean = mean;
    cma.generation += 1;
    // B e D novos: C = B diag(D²) Bᵀ (C simétrica por construção; a média das metades tira o arredondamento)
    var sym: [max_n][max_n]f64 = undefined;
    for (0..dims) |i| for (0..dims) |j| {
        sym[i][j] = 0.5 * (cma.C[i][j] + cma.C[j][i]);
    };
    var eigvals: [max_n]f64 = undefined;
    linalg.symEigen(max_n, &sym, dims, &eigvals, &cma.B);
    for (0..dims) |i| cma.D[i] = @sqrt(@max(eigvals[i], 1e-20));
}

fn better(fit: []const f64, first: usize, second: usize) bool {
    const fit_first = if (std.math.isNan(fit[first])) -std.math.inf(f64) else fit[first];
    const fit_second = if (std.math.isNan(fit[second])) -std.math.inf(f64) else fit[second];
    return fit_first > fit_second or (fit_first == fit_second and first < second);
}

// ------------------------------------------------------------------ testes
fn runOn(comptime objective: fn ([]const f64) f64, dims: usize, evals: usize, seed: i32) struct { best: f64, used: usize } {
    var cma: CmaState = undefined;
    var x0: [max_n]f64 = @splat(0.2);
    init(&cma, dims, x0[0..dims], 0.3, 0, seed);
    var xs: [max_lambda * max_n]f64 = undefined;
    var fit: [max_lambda]f64 = undefined;
    var best = -std.math.inf(f64);
    var used: usize = 0;
    const lam: usize = @intCast(cma.lambda);
    while (used + lam <= evals) {
        ask(&cma, xs[0 .. lam * dims]);
        for (0..lam) |k| {
            fit[k] = objective(xs[k * dims ..][0..dims]);
            best = @max(best, fit[k]);
        }
        used += lam;
        tell(&cma, xs[0 .. lam * dims], fit[0..lam]);
    }
    return .{ .best = best, .used = used };
}

fn ellipsoid(point: []const f64) f64 { // máximo 0 em x = 0,7; escala 1 a 1000 entre os eixos (mal condicionada)
    var total: f64 = 0;
    for (point, 0..) |value, i| {
        const axis_scale = std.math.pow(f64, 1000, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(point.len - 1)));
        total -= axis_scale * (value - 0.7) * (value - 0.7);
    }
    return total;
}

fn rosen(point: []const f64) f64 { // Rosenbrock em [0, 1]: máximo 0 em x = 0,5 (o vale curvo)
    var total: f64 = 0;
    for (0..point.len - 1) |i| {
        const x_now = 4 * point[i] - 1;
        const x_next = 4 * point[i + 1] - 1;
        total -= 100 * (x_next - x_now * x_now) * (x_next - x_now * x_now) + (1 - x_now) * (1 - x_now);
    }
    return total;
}

test "CMA-ES acha o máximo de uma elipse mal condicionada e do vale de Rosenbrock" {
    const ellipse = runOn(ellipsoid, 8, 3200, 3);
    try std.testing.expect(ellipse.best > -1e-6);
    const valley = runOn(rosen, 4, 2400, 5);
    try std.testing.expect(valley.best > -1e-4);
}

test "a mesma semente dá a mesma busca, os pontos ficam na caixa e C fica simétrica positiva" {
    var cma: CmaState = undefined;
    const x0 = [3]f64{ 0.5, 0.1, 0.9 };
    init(&cma, 3, &x0, 0.5, 6, 11);
    try std.testing.expectEqual(@as(i32, 6), cma.lambda);
    var first: [18]f64 = undefined;
    var second: [18]f64 = undefined;
    ask(&cma, &first);
    ask(&cma, &second);
    try std.testing.expectEqualSlices(f64, &first, &second);
    for (first) |value| try std.testing.expect(value >= 0 and value <= 1);
    const fit = [6]f64{ 1, std.math.nan(f64), 3, 2, 0, 5 };
    tell(&cma, &first, &fit);
    for (0..3) |i| {
        try std.testing.expect(cma.D[i] > 0);
        for (0..3) |j| try std.testing.expectApproxEqAbs(cma.C[i][j], cma.C[j][i], 1e-14);
    }
}

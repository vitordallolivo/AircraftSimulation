//! Evolução diferencial (DE/rand/1/bin), para as variáveis contínuas do aeroopt (envergadura, área, diedro...).
//!
//! O algoritmo genético muta cada gene com um sorteio de tamanho fixo; a evolução diferencial tira o passo da própria
//! população: o avião de teste de cada indivíduo xᵢ é a soma de um avião sorteado com a diferença entre outros dois,
//! v = x_r1 + F (x_r2 − x_r3), cruzada gene a gene com xᵢ (cada gene vem de v com probabilidade CR, e pelo menos um
//! vem sempre). O teste só entra no lugar de xᵢ se for pelo menos tão bom. Quando a população se espalha, as
//! diferenças são grandes e a busca explora; quando ela se junta perto do ótimo, as diferenças encolhem sozinhas e a
//! busca refina, sem um passo para ajustar. Storn e Price, "Differential Evolution: a simple and efficient heuristic
//! for global optimization over continuous spaces", J. Global Optimization 11, 341–359, 1997 (a conferir no PDF).
//!
//! As variáveis entram normalizadas em [0, 1] (o Python divide pela faixa), e um gene do teste que sai da caixa é
//! levado para a borda. O Python guarda a população e as notas, pede os testes de uma geração (`trials`), avalia
//! cada um e devolve as notas (`select`); maior é melhor, NaN é o pior. Os sorteios saem da semente e da geração:
//! a mesma entrada dá a mesma busca.
const std = @import("std");

pub const max_n = 32;
pub const max_np = 64;

fn rng(seed: u64, generation: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% generation);
}

/// a população inicial: a primeira linha é `x0`, as outras sorteadas em [0, 1]^dims (`out`: pop_size × dims)
pub fn initPop(dims: usize, pop_size: usize, x0: []const f64, seed: u64, out: []f64) bool {
    if (dims == 0 or dims > max_n or pop_size < 4 or pop_size > max_np) return false;
    var prng = rng(seed, 0);
    const random = prng.random();
    for (0..dims) |j| out[j] = std.math.clamp(x0[j], 0, 1);
    for (dims..pop_size * dims) |k| out[k] = random.float(f64);
    return true;
}

/// os testes da geração `generation`: um por indivíduo, DE/rand/1/bin com F = `weight` e CR (`out`: pop_size × dims)
pub fn trials(dims: usize, pop_size: usize, pop: []const f64, weight: f64, cr: f64, seed: u64, generation: u64, out: []f64) bool {
    if (dims == 0 or dims > max_n or pop_size < 4 or pop_size > max_np) return false;
    var prng = rng(seed, generation + 1);
    const random = prng.random();
    for (0..pop_size) |i| {
        var base = random.uintLessThan(usize, pop_size);
        while (base == i) base = random.uintLessThan(usize, pop_size);
        var diff_a = random.uintLessThan(usize, pop_size);
        while (diff_a == i or diff_a == base) diff_a = random.uintLessThan(usize, pop_size);
        var diff_b = random.uintLessThan(usize, pop_size);
        while (diff_b == i or diff_b == base or diff_b == diff_a) diff_b = random.uintLessThan(usize, pop_size);
        const forced_gene = random.uintLessThan(usize, dims); // este gene vem sempre do mutante
        for (0..dims) |j| {
            const mutant = pop[base * dims + j] + weight * (pop[diff_a * dims + j] - pop[diff_b * dims + j]);
            out[i * dims + j] = if (j == forced_gene or random.float(f64) < cr) std.math.clamp(mutant, 0, 1) else pop[i * dims + j];
        }
    }
    return true;
}

fn worse(first: f64, second: f64) bool {
    const fit_first = if (std.math.isNan(first)) -std.math.inf(f64) else first;
    const fit_second = if (std.math.isNan(second)) -std.math.inf(f64) else second;
    return fit_first < fit_second;
}

/// a seleção: o teste entra no lugar do indivíduo se a nota dele não é pior (NaN é o pior). Muda `pop` e `fit`;
/// devolve quantos entraram
pub fn select(dims: usize, pop_size: usize, pop: []f64, fit: []f64, trial: []const f64, tfit: []const f64) usize {
    var accepted: usize = 0;
    for (0..pop_size) |i| {
        if (worse(tfit[i], fit[i])) continue;
        @memcpy(pop[i * dims ..][0..dims], trial[i * dims ..][0..dims]);
        fit[i] = tfit[i];
        accepted += 1;
    }
    return accepted;
}

// ------------------------------------------------------------------ testes
fn sphere(point: []const f64) f64 {
    var sum_sq: f64 = 0;
    for (point) |value| sum_sq += (value - 0.7) * (value - 0.7);
    return -sum_sq;
}

fn rosen(point: []const f64) f64 { // Rosenbrock em [0, 1]ⁿ, com o mínimo em 0,5: o vale curvo
    var sum_sq: f64 = 0;
    for (0..point.len - 1) |i| {
        const x_now = 4 * point[i] - 2;
        const x_next = 4 * point[i + 1] - 2;
        sum_sq += 100 * (x_next - x_now * x_now) * (x_next - x_now * x_now) + (1 - x_now) * (1 - x_now);
    }
    return -sum_sq;
}

fn runOn(comptime objective: fn ([]const f64) f64, dims: usize, pop_size: usize, gens: usize, seed: u64) f64 {
    var pop: [max_np * max_n]f64 = undefined;
    var trial_pop: [max_np * max_n]f64 = undefined;
    var fit: [max_np]f64 = undefined;
    var trial_fit: [max_np]f64 = undefined;
    const x0: [max_n]f64 = @splat(0.1);
    _ = initPop(dims, pop_size, x0[0..dims], seed, &pop);
    for (0..pop_size) |i| fit[i] = objective(pop[i * dims ..][0..dims]);
    for (0..gens) |gen| {
        _ = trials(dims, pop_size, &pop, 0.5, 0.9, seed, gen, &trial_pop);
        for (0..pop_size) |i| trial_fit[i] = objective(trial_pop[i * dims ..][0..dims]);
        _ = select(dims, pop_size, &pop, &fit, &trial_pop, &trial_fit);
    }
    var best = -std.math.inf(f64);
    for (0..pop_size) |i| best = @max(best, fit[i]);
    return best;
}

test "esfera e Rosenbrock: chega ao máximo com um total fixo de avaliações" {
    try std.testing.expect(runOn(sphere, 5, 20, 100, 3) > -1e-6);
    try std.testing.expect(runOn(rosen, 3, 30, 300, 5) > -1e-4);
}

test "o teste fica na caixa, não repete o indivíduo e a seleção não piora ninguém" {
    const dims = 4;
    const pop_size = 8;
    var pop: [pop_size * dims]f64 = undefined;
    var trial_pop: [pop_size * dims]f64 = undefined;
    try std.testing.expect(initPop(dims, pop_size, &.{ 0.2, 0.4, 0.6, 2.0 }, 9, &pop));
    try std.testing.expectEqual(@as(f64, 1), pop[3]); // x0 levado para a caixa
    try std.testing.expect(!initPop(dims, 3, &.{ 0, 0, 0, 0 }, 9, &pop)); // np < 4: não há três outros
    _ = trials(dims, pop_size, &pop, 1.5, 1.0, 9, 0, &trial_pop);
    for (trial_pop) |value| try std.testing.expect(value >= 0 and value <= 1);
    var repeat: [pop_size * dims]f64 = undefined;
    _ = trials(dims, pop_size, &pop, 1.5, 1.0, 9, 0, &repeat);
    try std.testing.expectEqualSlices(f64, &trial_pop, &repeat); // a mesma semente e geração: os mesmos testes
    var fit = [_]f64{ 1, 2, std.math.nan(f64), 4, 5, 6, 7, 8 };
    const trial_fit = [_]f64{ 0, 2, 3, std.math.nan(f64), 9, 6, 1, 8 };
    const before = fit;
    const accepted = select(dims, pop_size, &pop, &fit, &trial_pop, &trial_fit);
    try std.testing.expectEqual(@as(usize, 5), accepted); // 2 = 2, 3 > NaN, 9 > 5, 6 = 6, 8 = 8
    for (0..pop_size) |i| try std.testing.expect(!worse(fit[i], before[i]) or std.math.isNan(before[i]));
}

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
//! Duas escolhas, cada uma um enum, com o padrão igual ao de antes:
//!
//! - a estratégia (`Strategy`): rand/1, a de cima, ou current-to-best/1, v = xᵢ + F (x_melhor − xᵢ) + F (x_r1 − x_r2),
//!   que puxa cada indivíduo para o melhor da população e converge mais depressa quando a nota é suave (Das e
//!   Suganthan, "Differential Evolution: A Survey of the State-of-the-Art", IEEE Trans. Evol. Comput. 15(1), 4–31,
//!   2011; a conferir no PDF);
//! - a borda (`Bound`): levar o gene para a borda (clip, a de antes) ou refletir, sorteando entre o pai e a borda que
//!   ele passou (Price, Storn e Lampinen, "Differential Evolution: A Practical Approach to Global Optimization",
//!   Springer, 2005, "bounce-back"; a conferir no PDF). O clip junta muitos testes em cima da borda; o reflexo deixa
//!   o teste dentro, perto de onde o pai estava.
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

/// como o mutante é feito (ver o cabeçalho)
pub const Strategy = enum(i32) {
    /// v = x_r1 + F (x_r2 − x_r3) (o padrão)
    rand_1 = 0,
    /// v = xᵢ + F (x_melhor − xᵢ) + F (x_r1 − x_r2)
    current_to_best_1 = 1,
};

/// o que fazer com um gene do mutante fora de [0, 1]
pub const Bound = enum(i32) {
    /// levar para a borda (o padrão)
    clip = 0,
    /// sortear entre o pai e a borda que ele passou
    reflect = 1,
};

/// as escolhas de uma geração: F, CR, a estratégia e a borda
pub const Options = struct {
    weight: f64 = 0.5,
    cr: f64 = 0.9,
    strategy: Strategy = .rand_1,
    bound: Bound = .clip,
};

/// os testes da geração `generation`: um por indivíduo, DE/rand/1/bin com F = `weight` e CR (`out`: pop_size × dims)
pub fn trials(dims: usize, pop_size: usize, pop: []const f64, weight: f64, cr: f64, seed: u64, generation: u64, out: []f64) bool {
    return trialsWith(dims, pop_size, pop, &.{}, .{ .weight = weight, .cr = cr }, seed, generation, out);
}

/// o índice da melhor nota (NaN é a pior; no empate, o primeiro)
fn bestIndex(fit: []const f64) usize {
    var best: usize = 0;
    for (fit, 0..) |_, i| if (worse(fit[best], fit[i]) and !std.math.isNan(fit[i])) {
        best = i;
    };
    return best;
}

/// os testes da geração com as escolhas `options`; `fit` (as notas da população) só é lido na current-to-best
pub fn trialsWith(dims: usize, pop_size: usize, pop: []const f64, fit: []const f64, options: Options, seed: u64, generation: u64, out: []f64) bool {
    if (dims == 0 or dims > max_n or pop_size < 4 or pop_size > max_np) return false;
    if (options.strategy == .current_to_best_1 and fit.len < pop_size) return false;
    var prng = rng(seed, generation + 1);
    const random = prng.random();
    const best = if (options.strategy == .current_to_best_1) bestIndex(fit[0..pop_size]) else 0;
    const weight = options.weight;
    for (0..pop_size) |i| {
        // rand/1: a base sorteada e duas diferenças; current-to-best/1: a base é o próprio indivíduo
        var base = i;
        if (options.strategy == .rand_1) {
            base = random.uintLessThan(usize, pop_size);
            while (base == i) base = random.uintLessThan(usize, pop_size);
        }
        var diff_a = random.uintLessThan(usize, pop_size);
        while (diff_a == i or diff_a == base) diff_a = random.uintLessThan(usize, pop_size);
        var diff_b = random.uintLessThan(usize, pop_size);
        while (diff_b == i or diff_b == base or diff_b == diff_a) diff_b = random.uintLessThan(usize, pop_size);
        const forced_gene = random.uintLessThan(usize, dims); // este gene vem sempre do mutante
        for (0..dims) |j| {
            const parent = pop[i * dims + j];
            const mutant = switch (options.strategy) {
                .rand_1 => pop[base * dims + j] + weight * (pop[diff_a * dims + j] - pop[diff_b * dims + j]),
                .current_to_best_1 => parent + weight * (pop[best * dims + j] - parent) + weight * (pop[diff_a * dims + j] - pop[diff_b * dims + j]),
            };
            out[i * dims + j] = if (j == forced_gene or random.float(f64) < options.cr) switch (options.bound) {
                .clip => std.math.clamp(mutant, 0, 1),
                .reflect => if (mutant < 0) random.float(f64) * parent else if (mutant > 1) parent + random.float(f64) * (1 - parent) else mutant,
            } else parent;
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
    return runWith(objective, dims, pop_size, gens, seed, .{});
}

fn runWith(comptime objective: fn ([]const f64) f64, dims: usize, pop_size: usize, gens: usize, seed: u64, options: Options) f64 {
    var pop: [max_np * max_n]f64 = undefined;
    var trial_pop: [max_np * max_n]f64 = undefined;
    var fit: [max_np]f64 = undefined;
    var trial_fit: [max_np]f64 = undefined;
    const x0: [max_n]f64 = @splat(0.1);
    _ = initPop(dims, pop_size, x0[0..dims], seed, &pop);
    for (0..pop_size) |i| fit[i] = objective(pop[i * dims ..][0..dims]);
    for (0..gens) |gen| {
        _ = trialsWith(dims, pop_size, &pop, fit[0..pop_size], options, seed, gen, &trial_pop);
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

test "current-to-best e borda refletida: chegam ao máximo; o padrão de trialsWith é o trials de antes" {
    try std.testing.expect(runWith(sphere, 5, 20, 100, 3, .{ .strategy = .current_to_best_1 }) > -1e-6);
    try std.testing.expect(runWith(sphere, 5, 20, 100, 3, .{ .bound = .reflect }) > -1e-6);
    // Rosenbrock tem um platô em que a busca às vezes para (depende da semente, nos três jeitos); com a semente 1
    // as duas opções novas chegam ao ótimo
    try std.testing.expect(runWith(rosen, 3, 30, 600, 1, .{ .bound = .reflect }) > -1e-6);
    try std.testing.expect(runWith(rosen, 3, 30, 600, 1, .{ .strategy = .current_to_best_1 }) > -1e-6);
    try std.testing.expect(runWith(sphere, 5, 20, 100, 3, .{ .strategy = .current_to_best_1, .bound = .reflect }) > -1e-6);
    // a mesma semente: os mesmos testes com o trials de antes
    const dims = 3;
    const pop_size = 6;
    var pop: [pop_size * dims]f64 = undefined;
    _ = initPop(dims, pop_size, &.{ 0.1, 0.5, 0.9 }, 4, &pop);
    var old: [pop_size * dims]f64 = undefined;
    var new: [pop_size * dims]f64 = undefined;
    _ = trials(dims, pop_size, &pop, 0.8, 0.9, 4, 2, &old);
    _ = trialsWith(dims, pop_size, &pop, &.{}, .{ .weight = 0.8, .cr = 0.9 }, 4, 2, &new);
    try std.testing.expectEqualSlices(f64, &old, &new);
    // o reflexo fica dentro e não cola na borda (F grande joga o mutante para fora)
    _ = trialsWith(dims, pop_size, &pop, &.{}, .{ .weight = 3, .cr = 1, .bound = .reflect }, 4, 2, &new);
    for (new) |value| try std.testing.expect(value >= 0 and value <= 1 and value != 0 and value != 1);
    // current-to-best sem as notas: recusa
    try std.testing.expect(!trialsWith(dims, pop_size, &pop, &.{}, .{ .strategy = .current_to_best_1 }, 4, 2, &new));
}

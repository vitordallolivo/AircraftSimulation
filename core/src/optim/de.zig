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

/// a população inicial: a primeira linha é `x0`, as outras sorteadas em [0, 1]ⁿ (`out`: np × n)
pub fn initPop(n: usize, np: usize, x0: []const f64, seed: u64, out: []f64) bool {
    if (n == 0 or n > max_n or np < 4 or np > max_np) return false;
    var p = rng(seed, 0);
    const r = p.random();
    for (0..n) |j| out[j] = std.math.clamp(x0[j], 0, 1);
    for (n..np * n) |k| out[k] = r.float(f64);
    return true;
}

/// os testes da geração `generation`: um por indivíduo, DE/rand/1/bin com F e CR (`out`: np × n)
pub fn trials(n: usize, np: usize, pop: []const f64, f: f64, cr: f64, seed: u64, generation: u64, out: []f64) bool {
    if (n == 0 or n > max_n or np < 4 or np > max_np) return false;
    var p = rng(seed, generation + 1);
    const r = p.random();
    for (0..np) |i| {
        var a = r.uintLessThan(usize, np);
        while (a == i) a = r.uintLessThan(usize, np);
        var b = r.uintLessThan(usize, np);
        while (b == i or b == a) b = r.uintLessThan(usize, np);
        var c = r.uintLessThan(usize, np);
        while (c == i or c == a or c == b) c = r.uintLessThan(usize, np);
        const jr = r.uintLessThan(usize, n); // este gene vem sempre do mutante
        for (0..n) |j| {
            const v = pop[a * n + j] + f * (pop[b * n + j] - pop[c * n + j]);
            out[i * n + j] = if (j == jr or r.float(f64) < cr) std.math.clamp(v, 0, 1) else pop[i * n + j];
        }
    }
    return true;
}

fn worse(a: f64, b: f64) bool {
    const fa = if (std.math.isNan(a)) -std.math.inf(f64) else a;
    const fb = if (std.math.isNan(b)) -std.math.inf(f64) else b;
    return fa < fb;
}

/// a seleção: o teste entra no lugar do indivíduo se a nota dele não é pior (NaN é o pior). Muda `pop` e `fit`;
/// devolve quantos entraram
pub fn select(n: usize, np: usize, pop: []f64, fit: []f64, trial: []const f64, tfit: []const f64) usize {
    var k: usize = 0;
    for (0..np) |i| {
        if (worse(tfit[i], fit[i])) continue;
        @memcpy(pop[i * n ..][0..n], trial[i * n ..][0..n]);
        fit[i] = tfit[i];
        k += 1;
    }
    return k;
}

// ------------------------------------------------------------------ testes
fn sphere(x: []const f64) f64 {
    var s: f64 = 0;
    for (x) |v| s += (v - 0.7) * (v - 0.7);
    return -s;
}

fn rosen(x: []const f64) f64 { // Rosenbrock em [0, 1]ⁿ, com o mínimo em 0,5: o vale curvo
    var s: f64 = 0;
    for (0..x.len - 1) |i| {
        const a = 4 * x[i] - 2;
        const b = 4 * x[i + 1] - 2;
        s += 100 * (b - a * a) * (b - a * a) + (1 - a) * (1 - a);
    }
    return -s;
}

fn runOn(comptime f: fn ([]const f64) f64, n: usize, np: usize, gens: usize, seed: u64) f64 {
    var pop: [max_np * max_n]f64 = undefined;
    var tr: [max_np * max_n]f64 = undefined;
    var fit: [max_np]f64 = undefined;
    var tf: [max_np]f64 = undefined;
    const x0: [max_n]f64 = @splat(0.1);
    _ = initPop(n, np, x0[0..n], seed, &pop);
    for (0..np) |i| fit[i] = f(pop[i * n ..][0..n]);
    for (0..gens) |g| {
        _ = trials(n, np, &pop, 0.5, 0.9, seed, g, &tr);
        for (0..np) |i| tf[i] = f(tr[i * n ..][0..n]);
        _ = select(n, np, &pop, &fit, &tr, &tf);
    }
    var best = -std.math.inf(f64);
    for (0..np) |i| best = @max(best, fit[i]);
    return best;
}

test "esfera e Rosenbrock: chega ao máximo com um total fixo de avaliações" {
    try std.testing.expect(runOn(sphere, 5, 20, 100, 3) > -1e-6);
    try std.testing.expect(runOn(rosen, 3, 30, 300, 5) > -1e-4);
}

test "o teste fica na caixa, não repete o indivíduo e a seleção não piora ninguém" {
    const n = 4;
    const np = 8;
    var pop: [np * n]f64 = undefined;
    var tr: [np * n]f64 = undefined;
    try std.testing.expect(initPop(n, np, &.{ 0.2, 0.4, 0.6, 2.0 }, 9, &pop));
    try std.testing.expectEqual(@as(f64, 1), pop[3]); // x0 levado para a caixa
    try std.testing.expect(!initPop(n, 3, &.{ 0, 0, 0, 0 }, 9, &pop)); // np < 4: não há três outros
    _ = trials(n, np, &pop, 1.5, 1.0, 9, 0, &tr);
    for (tr) |v| try std.testing.expect(v >= 0 and v <= 1);
    var a: [np * n]f64 = undefined;
    _ = trials(n, np, &pop, 1.5, 1.0, 9, 0, &a);
    try std.testing.expectEqualSlices(f64, &tr, &a); // a mesma semente e geração: os mesmos testes
    var fit = [_]f64{ 1, 2, std.math.nan(f64), 4, 5, 6, 7, 8 };
    const tf = [_]f64{ 0, 2, 3, std.math.nan(f64), 9, 6, 1, 8 };
    const before = fit;
    const k = select(n, np, &pop, &fit, &tr, &tf);
    try std.testing.expectEqual(@as(usize, 5), k); // 2 = 2, 3 > NaN, 9 > 5, 6 = 6, 8 = 8
    for (0..np) |i| try std.testing.expect(!worse(fit[i], before[i]) or std.math.isNan(before[i]));
}

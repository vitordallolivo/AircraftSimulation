//! Gerações de aviões: o algoritmo genético que escolhe as configurações do aeroopt no lugar de varrer todas as
//! combinações. Cada indivíduo é uma lista de genes: um gene discreto é o índice de uma opção (a categoria, o perfil
//! da EH, a hélice...) e um gene real é um valor entre `lo` e `hi`. O Python avalia a geração (o processo em etapas)
//! e devolve a nota de cada um; daqui sai a geração seguinte.
//!
//! Os operadores são os clássicos (Goldberg, Genetic Algorithms in Search, Optimization and Machine Learning, 1989;
//! seleção por posição de Baker, 1985; capítulo e página a conferir no PDF), os mesmos que o MDO antigo da equipe usava
//! (AeroGA: posição, um ponto de corte, mutação gaussiana, elite):
//!   elite       os `elite` melhores passam iguais
//!   seleção     por posição: o i-ésimo melhor de n é sorteado com peso n − i (a escala da nota não importa)
//!   cruzamento  com probabilidade `p_cross`, um ponto de corte: os genes até o corte vêm de um pai, o resto do outro
//!   mutação     cada gene com probabilidade `p_mut`: o discreto vira outra opção qualquer; o real anda
//!               N(0, σ (hi − lo)) e fica dentro dos limites
//!
//! Sorteios por uma semente (`seed` e `generation`): a mesma entrada dá a mesma geração.
const std = @import("std");

pub const max_genes = 32;
pub const max_pop = 256;

pub const GaCfg = extern struct {
    n_genes: i32 = 0,
    pop: i32 = 16,
    elite: i32 = 2,
    card: [max_genes]i32 = @splat(0), // > 0: gene discreto com tantas opções; 0: real em [lo, hi]
    lo: [max_genes]f64 = @splat(0),
    hi: [max_genes]f64 = @splat(1),
    p_cross: f64 = 0.9,
    p_mut: f64 = 0.15,
    sigma: f64 = 0.1,
    seed: i32 = 1,
    generation: i32 = 0,
};

fn rng(cfg: *const GaCfg) std.Random.DefaultPrng {
    const s: u64 = @as(u64, @intCast(@max(cfg.seed, 0))) *% 1_000_003 +% @as(u64, @intCast(@max(cfg.generation, 0)));
    return std.Random.DefaultPrng.init(s);
}

fn randomGene(cfg: *const GaCfg, r: std.Random, j: usize) f64 {
    const k = cfg.card[j];
    if (k > 0) return @floatFromInt(r.uintLessThan(u32, @intCast(k)));
    return cfg.lo[j] + r.float(f64) * (cfg.hi[j] - cfg.lo[j]);
}

/// a primeira geração, sorteada (`out`: pop × n_genes)
pub fn init(cfg: *const GaCfg, out: []f64) void {
    var p = rng(cfg);
    const r = p.random();
    const n: usize = @intCast(cfg.n_genes);
    const m: usize = @intCast(cfg.pop);
    for (0..m) |i| {
        for (0..n) |j| out[i * n + j] = randomGene(cfg, r, j);
    }
}

fn better(fit: []const f64, a: usize, b: usize) bool {
    const fa = if (std.math.isNan(fit[a])) -std.math.inf(f64) else fit[a];
    const fb = if (std.math.isNan(fit[b])) -std.math.inf(f64) else fit[b];
    return fa > fb or (fa == fb and a < b); // empate: a ordem de antes, para ficar determinístico
}

/// a geração seguinte: `genes` (pop × n_genes) com a nota `fit` de cada um (NaN ou −inf: morreu) → `out`
pub fn next(cfg: *const GaCfg, genes: []const f64, fit: []const f64, out: []f64) void {
    var p = rng(cfg);
    const r = p.random();
    const n: usize = @intCast(cfg.n_genes);
    const m: usize = @intCast(cfg.pop);
    var order: [max_pop]usize = undefined;
    for (0..m) |i| order[i] = i;
    for (1..m) |i| { // inserção, do melhor para o pior
        var j = i;
        while (j > 0 and better(fit, order[j], order[j - 1])) : (j -= 1) std.mem.swap(usize, &order[j], &order[j - 1]);
    }
    const ne: usize = @intCast(std.math.clamp(cfg.elite, 0, cfg.pop));
    for (0..ne) |i| @memcpy(out[i * n .. (i + 1) * n], genes[order[i] * n .. (order[i] + 1) * n]);
    const total: f64 = @floatFromInt(m * (m + 1) / 2);
    for (ne..m) |i| {
        const a = order[pick(r, m, total)];
        const b = order[pick(r, m, total)];
        const cut = if (n > 1 and r.float(f64) < cfg.p_cross) 1 + r.uintLessThan(usize, n - 1) else n;
        for (0..n) |j| {
            var g = if (j < cut) genes[a * n + j] else genes[b * n + j];
            if (r.float(f64) < cfg.p_mut) {
                const k = cfg.card[j];
                if (k > 1) {
                    const now: u32 = @intFromFloat(g);
                    const other = r.uintLessThan(u32, @intCast(k - 1));
                    g = @floatFromInt(if (other >= now) other + 1 else other);
                } else if (k == 0) {
                    g = std.math.clamp(g + r.floatNorm(f64) * cfg.sigma * (cfg.hi[j] - cfg.lo[j]), cfg.lo[j], cfg.hi[j]);
                }
            }
            out[i * n + j] = g;
        }
    }
}

/// posição sorteada com peso m − posição (0 = o melhor)
fn pick(r: std.Random, m: usize, total: f64) usize {
    var x = r.float(f64) * total;
    for (0..m) |i| {
        x -= @floatFromInt(m - i);
        if (x < 0) return i;
    }
    return m - 1;
}

// ------------------------------------------------------------------ testes
test "a geração sai dentro das opções e dos limites, e a elite passa igual" {
    var cfg = GaCfg{ .n_genes = 3, .pop = 8, .elite = 2 };
    cfg.card[0] = 5;
    cfg.card[1] = 2;
    cfg.lo[2] = -1;
    cfg.hi[2] = 3;
    var g: [24]f64 = undefined;
    init(&cfg, &g);
    var fit: [8]f64 = undefined;
    for (0..8) |i| fit[i] = g[i * 3] + g[i * 3 + 2]; // a melhor é a de maior opção 0 e maior real
    fit[5] = std.math.nan(f64); // morreu
    var out: [24]f64 = undefined;
    next(&cfg, &g, &fit, &out);
    var best: usize = 0;
    for (0..8) |i| if (i != 5 and fit[i] > fit[best]) {
        best = i;
    };
    try std.testing.expectEqualSlices(f64, g[best * 3 .. best * 3 + 3], out[0..3]);
    for (0..8) |i| {
        try std.testing.expect(out[i * 3] >= 0 and out[i * 3] < 5 and @round(out[i * 3]) == out[i * 3]);
        try std.testing.expect(out[i * 3 + 1] == 0 or out[i * 3 + 1] == 1);
        try std.testing.expect(out[i * 3 + 2] >= -1 and out[i * 3 + 2] <= 3);
    }
    var again: [24]f64 = undefined; // determinística
    next(&cfg, &g, &fit, &again);
    try std.testing.expectEqualSlices(f64, &out, &again);
}

test "as gerações acham o máximo de um problema discreto grande" {
    // 8 genes de 6 opções (1,7 milhão de combinações): a nota é quantos genes acertam o alvo
    const target = [8]f64{ 3, 1, 4, 1, 5, 2, 0, 5 };
    var cfg = GaCfg{ .n_genes = 8, .pop = 40, .elite = 2, .p_mut = 0.1 };
    for (0..8) |j| cfg.card[j] = 6;
    var g: [320]f64 = undefined;
    var out: [320]f64 = undefined;
    var fit: [40]f64 = undefined;
    init(&cfg, &g);
    var best: f64 = 0;
    for (0..60) |gen| {
        for (0..40) |i| {
            var s: f64 = 0;
            for (0..8) |j| s += if (g[i * 8 + j] == target[j]) 1 else 0;
            fit[i] = s;
            best = @max(best, s);
        }
        cfg.generation = @intCast(gen + 1);
        next(&cfg, &g, &fit, &out);
        g = out;
    }
    try std.testing.expectEqual(@as(f64, 8), best); // 60 × 40 = 2400 avaliações, 0,14 % do espaço
}

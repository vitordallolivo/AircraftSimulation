//! Os métodos da sensibilidade do melhor avião do aeroopt (`aeroopt/sensitivity.py`), além do modelo local
//! (`localfit.zig`): a perda de nota por tolerância de fabricação e os efeitos elementares de Morris.
//!
//! A tolerância usa a inclinação gₖ e a curvatura cₖ que o modelo local já deu. Com uma tolerância δₖ em cada variável,
//! a nota muda ΔN±ₖ = ±gₖδₖ + ½cₖδₖ² de cada lado, e, tomando δₖ como o desvio padrão de uma variável normal,
//! independente das outras, a dispersão da nota pelos dois primeiros momentos da série de Taylor é
//!
//!   σ_N² ≈ Σₖ (gₖ δₖ)² + ½ Σₖ (cₖ δₖ²)²
//!
//! (o método dos momentos de segunda ordem; Putko, Taylor, Newman e Green, "Approach for uncertainty propagation and
//! robust design in CFD using sensitivity derivatives", NASA/AIAA 2001-2528, a conferir no PDF). A elasticidade
//! eₖ = gₖ xₖ / N diz quantos por cento a nota muda com 1 % da variável, e deixa comparar variáveis de unidades
//! diferentes.
//!
//! Os efeitos elementares de Morris olham uma região, não um ponto: r trajetórias de k + 1 pontos numa grade de p
//! níveis em [0, 1]ᵏ, cada passo mexendo uma variável só em Δ = p / (2(p − 1)). O efeito de cada passo é
//! EEₖ = (y⁺ − y⁻)/Δ, e de cada variável saem a média μ, a média do módulo μ* (que não deixa efeitos de sinais
//! opostos se cancelarem) e o desvio σ, que acusa curvatura ou interação com as outras (Morris, "Factorial sampling
//! plans for preliminary computational experiments", Technometrics 33(2), 1991; μ* de Campolongo, Cariboni e
//! Saltelli, Environmental Modelling & Software 22, 2007; ambos a conferir no PDF). O aeroopt usa a região em volta
//! do melhor, e não a faixa inteira: a pergunta continua sendo a de um indivíduo.
const std = @import("std");

pub const max_k = 32;
pub const max_r = 64;

/// a perda por tolerância: `minus`/`plus` = ΔN de cada lado em ±δₖ, `elast` = gₖxₖ/N; devolve σ_N. Sem curvatura
/// (`curvature` com NaN) só a parte linear entra
pub fn tolerance(dims: usize, gradient: []const f64, curvature: []const f64, x0: []const f64, n0: f64, delta: []const f64,
    minus: []f64, plus: []f64, elast: []f64) f64 {
    var variance: f64 = 0;
    for (0..dims) |k| {
        const lin = gradient[k] * delta[k];
        const quad_term = if (std.math.isFinite(curvature[k])) 0.5 * curvature[k] * delta[k] * delta[k] else 0;
        minus[k] = -lin + quad_term;
        plus[k] = lin + quad_term;
        elast[k] = if (n0 != 0) gradient[k] * x0[k] / n0 else std.math.nan(f64);
        variance += lin * lin + 2 * quad_term * quad_term; // ½ (cδ²)² = 2 (½ c δ²)²
    }
    return @sqrt(variance);
}

/// o passo de Morris numa grade de `levels` níveis
pub fn morrisDelta(levels: usize) f64 {
    const levels_f: f64 = @floatFromInt(levels);
    return levels_f / (2 * (levels_f - 1));
}

/// as `trajectories` trajetórias de Morris em [0, 1]^dims: `out` com trajectories·(dims + 1) pontos de dims coordenadas, trajetória por trajetória.
/// Cada uma começa num nível sorteado da grade e mexe as variáveis numa ordem sorteada, para cima quando o nível
/// está na metade de baixo e para baixo na de cima (assim todo ponto fica na grade). `false` se dims,
/// trajectories ou levels não cabem
pub fn morrisDesign(dims: usize, trajectories: usize, levels: usize, seed: u64, out: []f64) bool {
    if (dims == 0 or dims > max_k or trajectories == 0 or trajectories > max_r or levels < 2 or levels % 2 != 0) return false;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const delta_step = morrisDelta(levels);
    const step = 1 / @as(f64, @floatFromInt(levels - 1));
    var order: [max_k]usize = undefined;
    for (0..trajectories) |traj| {
        const base = out[traj * (dims + 1) * dims ..];
        for (0..dims) |var_index| base[var_index] = @as(f64, @floatFromInt(rnd.uintLessThan(usize, levels))) * step;
        for (0..dims) |var_index| order[var_index] = var_index;
        rnd.shuffle(usize, order[0..dims]);
        for (0..dims) |move| {
            const prev = base[move * dims ..][0..dims];
            const next = base[(move + 1) * dims ..][0..dims];
            @memcpy(next, prev);
            const var_index = order[move];
            next[var_index] = if (prev[var_index] < 0.5) prev[var_index] + delta_step else prev[var_index] - delta_step;
        }
    }
    return true;
}

/// os efeitos elementares das `trajectories` trajetórias de `design` com as respostas `responses` (NaN = o ponto não vale; o passo que o
/// usa não conta): μ, μ*, σ e quantos passos contaram, por variável
pub fn morrisEffects(dims: usize, trajectories: usize, design: []const f64, responses: []const f64, mu: []f64, mustar: []f64, sigma: []f64,
    count: []usize) void {
    var sum_ee: [max_k]f64 = @splat(0);
    var sum_abs: [max_k]f64 = @splat(0);
    var sum_sq: [max_k]f64 = @splat(0);
    for (0..dims) |var_index| count[var_index] = 0;
    for (0..trajectories) |traj| {
        const offset = traj * (dims + 1);
        for (0..dims) |j| {
            const point_a = design[(offset + j) * dims ..][0..dims];
            const point_b = design[(offset + j + 1) * dims ..][0..dims];
            const resp_a = responses[offset + j];
            const resp_b = responses[offset + j + 1];
            var var_index: usize = 0;
            while (var_index < dims and point_a[var_index] == point_b[var_index]) var_index += 1;
            if (var_index == dims or !std.math.isFinite(resp_a) or !std.math.isFinite(resp_b)) continue;
            const ee = (resp_b - resp_a) / (point_b[var_index] - point_a[var_index]);
            sum_ee[var_index] += ee;
            sum_abs[var_index] += @abs(ee);
            sum_sq[var_index] += ee * ee;
            count[var_index] += 1;
        }
    }
    for (0..dims) |var_index| {
        const count_f: f64 = @floatFromInt(count[var_index]);
        if (count[var_index] == 0) {
            mu[var_index] = std.math.nan(f64);
            mustar[var_index] = std.math.nan(f64);
            sigma[var_index] = std.math.nan(f64);
            continue;
        }
        mu[var_index] = sum_ee[var_index] / count_f;
        mustar[var_index] = sum_abs[var_index] / count_f;
        sigma[var_index] = if (count[var_index] > 1) @sqrt(@max(sum_sq[var_index] - count_f * mu[var_index] * mu[var_index], 0) / (count_f - 1)) else 0;
    }
}

// ------------------------------------------------------------------ testes
test "tolerância: a parábola perde dos dois lados igual, e a reta só muda de sinal" {
    const gradient = [_]f64{ 0, 2 };
    const curvature = [_]f64{ -4, std.math.nan(f64) };
    const x0 = [_]f64{ 1, 5 };
    const delta = [_]f64{ 0.1, 0.5 };
    var minus: [2]f64 = undefined;
    var plus: [2]f64 = undefined;
    var elast: [2]f64 = undefined;
    const sigma_n = tolerance(2, &gradient, &curvature, &x0, 10, &delta, &minus, &plus, &elast);
    try std.testing.expectApproxEqAbs(@as(f64, -0.02), minus[0], 1e-15); // ½·(−4)·0,1²
    try std.testing.expectApproxEqAbs(@as(f64, -0.02), plus[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1), minus[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), plus[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), elast[1], 1e-15); // 2·5/10
    // σ² = (2·0,5)² + ½(−4·0,1²)² = 1 + 0,0008
    try std.testing.expectApproxEqAbs(@sqrt(1.0008), sigma_n, 1e-15);
}

test "Morris: a grade, um passo por variável, e os efeitos de uma função sabida" {
    const dims = 3;
    const trajectories = 10;
    var design: [trajectories * (dims + 1) * dims]f64 = undefined;
    try std.testing.expect(morrisDesign(dims, trajectories, 4, 7, &design));
    try std.testing.expect(!morrisDesign(dims, trajectories, 3, 7, &design)); // p ímpar não fecha a grade
    const delta_step = morrisDelta(4);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), delta_step, 1e-15);
    var responses: [trajectories * (dims + 1)]f64 = undefined;
    for (0..trajectories * (dims + 1)) |i| {
        const point = design[i * dims ..][0..dims];
        for (point) |value| try std.testing.expect(value >= -1e-12 and value <= 1 + 1e-12);
        // y = 3 x₀ − 2 x₁ + x₂²: μ₀ = 3 e σ₀ = 0; μ₁ = −2, μ₁* = 2; x₂ tem efeito que varia com o nível (σ > 0)
        responses[i] = 3 * point[0] - 2 * point[1] + point[2] * point[2];
    }
    for (0..trajectories) |traj| { // cada passo mexe uma variável só, em ±Δ
        for (0..dims) |step| {
            var moved: usize = 0;
            for (0..dims) |var_index| {
                const before = design[(traj * (dims + 1) + step) * dims + var_index];
                const after = design[(traj * (dims + 1) + step + 1) * dims + var_index];
                if (before != after) {
                    moved += 1;
                    try std.testing.expectApproxEqAbs(delta_step, @abs(after - before), 1e-12);
                }
            }
            try std.testing.expectEqual(@as(usize, 1), moved);
        }
    }
    var mu: [dims]f64 = undefined;
    var mustar: [dims]f64 = undefined;
    var sigma: [dims]f64 = undefined;
    var counts: [dims]usize = undefined;
    responses[1] = std.math.nan(f64); // um ponto que não vale tira os dois passos que o usam
    morrisEffects(dims, trajectories, &design, &responses, &mu, &mustar, &sigma, &counts);
    try std.testing.expectApproxEqAbs(@as(f64, 3), mu[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sigma[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -2), mu[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), mustar[1], 1e-9);
    try std.testing.expect(sigma[2] > 0.1);
    try std.testing.expectEqual(@as(usize, 3 * trajectories - 2), counts[0] + counts[1] + counts[2]);
}

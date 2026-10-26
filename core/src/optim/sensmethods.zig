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
/// (`c` com NaN) só a parte linear entra
pub fn tolerance(n: usize, g: []const f64, c: []const f64, x0: []const f64, n0: f64, delta: []const f64,
    minus: []f64, plus: []f64, elast: []f64) f64 {
    var s2: f64 = 0;
    for (0..n) |k| {
        const lin = g[k] * delta[k];
        const q = if (std.math.isFinite(c[k])) 0.5 * c[k] * delta[k] * delta[k] else 0;
        minus[k] = -lin + q;
        plus[k] = lin + q;
        elast[k] = if (n0 != 0) g[k] * x0[k] / n0 else std.math.nan(f64);
        s2 += lin * lin + 2 * q * q; // ½ (cδ²)² = 2 (½ c δ²)²
    }
    return @sqrt(s2);
}

/// o passo de Morris numa grade de p níveis
pub fn morrisDelta(p: usize) f64 {
    const pf: f64 = @floatFromInt(p);
    return pf / (2 * (pf - 1));
}

/// as r trajetórias de Morris em [0, 1]ᵏ: `out` com r·(k + 1) pontos de k coordenadas, trajetória por trajetória.
/// Cada uma começa num nível sorteado da grade e mexe as variáveis numa ordem sorteada, para cima quando o nível
/// está na metade de baixo e para baixo na de cima (assim todo ponto fica na grade). `false` se k, r ou p não cabem
pub fn morrisDesign(k: usize, r: usize, p: usize, seed: u64, out: []f64) bool {
    if (k == 0 or k > max_k or r == 0 or r > max_r or p < 2 or p % 2 != 0) return false;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const d = morrisDelta(p);
    const step = 1 / @as(f64, @floatFromInt(p - 1));
    var order: [max_k]usize = undefined;
    for (0..r) |t| {
        const base = out[t * (k + 1) * k ..];
        for (0..k) |m| base[m] = @as(f64, @floatFromInt(rnd.uintLessThan(usize, p))) * step;
        for (0..k) |m| order[m] = m;
        rnd.shuffle(usize, order[0..k]);
        for (0..k) |j| {
            const prev = base[j * k ..][0..k];
            const next = base[(j + 1) * k ..][0..k];
            @memcpy(next, prev);
            const m = order[j];
            next[m] = if (prev[m] < 0.5) prev[m] + d else prev[m] - d;
        }
    }
    return true;
}

/// os efeitos elementares das r trajetórias de `design` com as respostas `y` (NaN = o ponto não vale; o passo que o
/// usa não conta): μ, μ*, σ e quantos passos contaram, por variável
pub fn morrisEffects(k: usize, r: usize, design: []const f64, y: []const f64, mu: []f64, mustar: []f64, sigma: []f64,
    count: []usize) void {
    var s1: [max_k]f64 = @splat(0);
    var sa: [max_k]f64 = @splat(0);
    var s2: [max_k]f64 = @splat(0);
    for (0..k) |m| count[m] = 0;
    for (0..r) |t| {
        const o = t * (k + 1);
        for (0..k) |j| {
            const a = design[(o + j) * k ..][0..k];
            const b = design[(o + j + 1) * k ..][0..k];
            const ya = y[o + j];
            const yb = y[o + j + 1];
            var m: usize = 0;
            while (m < k and a[m] == b[m]) m += 1;
            if (m == k or !std.math.isFinite(ya) or !std.math.isFinite(yb)) continue;
            const ee = (yb - ya) / (b[m] - a[m]);
            s1[m] += ee;
            sa[m] += @abs(ee);
            s2[m] += ee * ee;
            count[m] += 1;
        }
    }
    for (0..k) |m| {
        const nf: f64 = @floatFromInt(count[m]);
        if (count[m] == 0) {
            mu[m] = std.math.nan(f64);
            mustar[m] = std.math.nan(f64);
            sigma[m] = std.math.nan(f64);
            continue;
        }
        mu[m] = s1[m] / nf;
        mustar[m] = sa[m] / nf;
        sigma[m] = if (count[m] > 1) @sqrt(@max(s2[m] - nf * mu[m] * mu[m], 0) / (nf - 1)) else 0;
    }
}

// ------------------------------------------------------------------ testes
test "tolerância: a parábola perde dos dois lados igual, e a reta só muda de sinal" {
    const g = [_]f64{ 0, 2 };
    const c = [_]f64{ -4, std.math.nan(f64) };
    const x0 = [_]f64{ 1, 5 };
    const delta = [_]f64{ 0.1, 0.5 };
    var mi: [2]f64 = undefined;
    var pl: [2]f64 = undefined;
    var el: [2]f64 = undefined;
    const s = tolerance(2, &g, &c, &x0, 10, &delta, &mi, &pl, &el);
    try std.testing.expectApproxEqAbs(@as(f64, -0.02), mi[0], 1e-15); // ½·(−4)·0,1²
    try std.testing.expectApproxEqAbs(@as(f64, -0.02), pl[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1), mi[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), pl[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), el[1], 1e-15); // 2·5/10
    // σ² = (2·0,5)² + ½(−4·0,1²)² = 1 + 0,0008
    try std.testing.expectApproxEqAbs(@sqrt(1.0008), s, 1e-15);
}

test "Morris: a grade, um passo por variável, e os efeitos de uma função sabida" {
    const k = 3;
    const r = 10;
    var design: [r * (k + 1) * k]f64 = undefined;
    try std.testing.expect(morrisDesign(k, r, 4, 7, &design));
    try std.testing.expect(!morrisDesign(k, r, 3, 7, &design)); // p ímpar não fecha a grade
    const d = morrisDelta(4);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), d, 1e-15);
    var y: [r * (k + 1)]f64 = undefined;
    for (0..r * (k + 1)) |i| {
        const x = design[i * k ..][0..k];
        for (x) |v| try std.testing.expect(v >= -1e-12 and v <= 1 + 1e-12);
        // y = 3 x₀ − 2 x₁ + x₂²: μ₀ = 3 e σ₀ = 0; μ₁ = −2, μ₁* = 2; x₂ tem efeito que varia com o nível (σ > 0)
        y[i] = 3 * x[0] - 2 * x[1] + x[2] * x[2];
    }
    for (0..r) |t| { // cada passo mexe uma variável só, em ±Δ
        for (0..k) |j| {
            var moved: usize = 0;
            for (0..k) |m| {
                const a = design[(t * (k + 1) + j) * k + m];
                const b = design[(t * (k + 1) + j + 1) * k + m];
                if (a != b) {
                    moved += 1;
                    try std.testing.expectApproxEqAbs(d, @abs(b - a), 1e-12);
                }
            }
            try std.testing.expectEqual(@as(usize, 1), moved);
        }
    }
    var mu: [k]f64 = undefined;
    var ms: [k]f64 = undefined;
    var sg: [k]f64 = undefined;
    var n: [k]usize = undefined;
    y[1] = std.math.nan(f64); // um ponto que não vale tira os dois passos que o usam
    morrisEffects(k, r, &design, &y, &mu, &ms, &sg, &n);
    try std.testing.expectApproxEqAbs(@as(f64, 3), mu[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sg[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -2), mu[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), ms[1], 1e-9);
    try std.testing.expect(sg[2] > 0.1);
    try std.testing.expectEqual(@as(usize, 3 * r - 2), n[0] + n[1] + n[2]);
}

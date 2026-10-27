//! Busca guiada pela falha: as peças que deixam o otimizador usar o MOTIVO de um avião não voar, e não só o quanto
//! ele viola. A etapa voa (E&C) do aeroopt sabe por que cada ponto falha (C_nβ negativo, asa da frente estolando,
//! comando que não trima...) e, para cada motivo, quais variáveis o consertam. Aqui ficam as contas; o Python
//! (aeroopt/diagnosis.py) diz qual falha é qual e escolhe as variáveis.
//!
//! Cinco métodos da literatura, cada um uma função pura (a mesma entrada dá a mesma saída):
//!
//!   reparo      um passo de Newton nas restrições violadas, só nas variáveis do remédio. Com J (m × n) o jacobiano
//!               das violações g (m) nas variáveis escolhidas, o passo de menor norma que zera g na aproximação
//!               linear é Δx = −J⁺ g, com J⁺ a pseudoinversa de Moore–Penrose (Chootinan e Chen, "Constraint
//!               handling in genetic algorithms using a gradient-based repair method", Computers & Operations
//!               Research 33(8), 2263–2281, 2006; a conferir no PDF). Aqui J⁺ = Jᵀ (J Jᵀ + λ I)⁻¹: o λ (nosso, de
//!               Levenberg) segura o passo quando duas restrições puxam quase na mesma direção.
//!
//!   ε-restrito  dois pontos se comparam pela nota quando os dois violam até ε, e pela violação senão; ε começa na
//!               violação de um ponto da população inicial e cai até 0 em Tc gerações, ε(t) = ε₀ (1 − t/Tc)^cp
//!               (Takahama e Sakai, "Constrained optimization by the ε constrained differential evolution with
//!               gradient-based mutation and feasible elites", IEEE CEC 2006; a conferir no PDF). No começo a busca
//!               atravessa regiões que quase voam; no fim só aceita o que voa.
//!
//!   bandido     escolher o operador (o remédio) de cada filho como um caça-níquel de vários braços: o braço k tem a
//!               média p̂ₖ do quanto já melhorou quem ele mutou e é jogado nₖ vezes; joga-se o de maior
//!               p̂ₖ + C √(2 ln Σn / nₖ) (UCB1). Quando o problema muda (o avião sai de uma falha e cai noutra), o
//!               teste de Page–Hinkley nas recompensas zera tudo e o bandido reaprende: o D-MAB de Da Costa,
//!               Fialho, Schoenauer e Sebag, "Adaptive operator selection with dynamic multi-armed bandits", GECCO
//!               2008 (a conferir no PDF).
//!
//!   cultural    o espaço de crenças normativo guarda, por variável, a faixa dos melhores da população (os `frac`
//!               melhores); os filhos nascem dentro dela (Reynolds, "An introduction to cultural algorithms", 1994;
//!               Landa Becerra e Coello, GECCO 2005; a conferir no PDF).
//!
//!   LEM         Learnable Evolution Model: separa os melhores (H) dos piores (L) e aprende uma regra, uma conjunção
//!               de condições xⱼ ≥ t ou xⱼ ≤ t, uma por variável, que cobre H e deixa L de fora; os filhos nascem
//!               dentro da regra (Michalski, "Learnable Evolution Model: evolutionary processes guided by machine
//!               learning", Machine Learning 38, 9–40, 2000; a conferir no PDF). O AQ do artigo aprende várias regras;
//!               aqui é uma só, com o melhor corte por variável.
//!
//! As variáveis entram normalizadas em [0, 1]; o que sai também.
const std = @import("std");
const linalg = @import("../math/linalg.zig");

pub const max_n = 32;
pub const max_m = 16;
pub const max_pop = 256;
pub const max_arms = 16;

// ------------------------------------------------------------------ reparo por gradiente

/// Δx = −Jᵀ (J Jᵀ + λ I)⁻¹ g (`J`: m × n por linhas, `g`: m, `out`: n). false se não cabe ou J Jᵀ + λ I é singular
pub fn repairStep(n: usize, m: usize, J: []const f64, g: []const f64, lambda: f64, out: []f64) bool {
    if (n == 0 or n > max_n or m == 0 or m > max_m) return false;
    var A: [max_m][max_m]f64 = @splat(@splat(0));
    var b: [max_m]f64 = @splat(0);
    for (0..m) |i| {
        for (0..m) |k| {
            var s: f64 = 0;
            for (0..n) |j| s += J[i * n + j] * J[k * n + j];
            A[i][k] = s;
        }
        A[i][i] += lambda;
        b[i] = g[i];
    }
    var y: [max_m]f64 = undefined;
    if (!linalg.solve(max_m, A, m, b, &y)) return false;
    for (0..n) |j| {
        var s: f64 = 0;
        for (0..m) |i| s += J[i * n + j] * y[i];
        out[j] = -s;
    }
    return true;
}

// ------------------------------------------------------------------ ε-restrito

/// ε(t) = ε₀ (1 − t/Tc)^cp para t < Tc, 0 depois
pub fn epsLevel(eps0: f64, t: f64, tc: f64, cp: f64) f64 {
    if (!(tc > 0) or t >= tc) return 0;
    return eps0 * std.math.pow(f64, 1 - @max(t, 0) / tc, cp);
}

/// a < b na ordem ε (maior nota é melhor; NaN é a pior): pela nota se as duas violações estão até ε (ou são
/// iguais), senão pela violação
pub fn epsWorse(fa: f64, va: f64, fb: f64, vb: f64, eps: f64) bool {
    const na = if (std.math.isNan(fa)) -std.math.inf(f64) else fa;
    const nb = if (std.math.isNan(fb)) -std.math.inf(f64) else fb;
    if ((va <= eps and vb <= eps) or va == vb) return na < nb;
    return va > vb;
}

// ------------------------------------------------------------------ bandido (D-MAB)

/// o estado do bandido num vetor de f64 (o Python guarda): [k, total, n[max_arms], média[max_arms], média PH,
/// contagem PH, m PH, M PH, reinícios]
pub const state_len = 2 + 2 * max_arms + 5;
const I_K = 0;
const I_TOT = 1;
const I_N = 2;
const I_MEAN = 2 + max_arms;
const I_PH = 2 + 2 * max_arms;

pub fn banditInit(s: []f64, k: usize) bool {
    if (k == 0 or k > max_arms or s.len < state_len) return false;
    @memset(s[0..state_len], 0);
    s[I_K] = @floatFromInt(k);
    return true;
}

fn banditReset(s: []f64) void {
    const k = s[I_K];
    const r = s[I_PH + 4];
    @memset(s[0..state_len], 0);
    s[I_K] = k;
    s[I_PH + 4] = r + 1;
}

/// o braço a jogar entre os permitidos (`allowed`: bit k = braço k): o primeiro ainda não jogado, senão o de maior
/// p̂ₖ + C √(2 ln Σn / nₖ). −1 se nenhum é permitido
pub fn banditPick(s: []const f64, c: f64, allowed: u32) i32 {
    const k: usize = @intFromFloat(s[I_K]);
    var best: i32 = -1;
    var bv = -std.math.inf(f64);
    for (0..k) |a| {
        if (allowed & (@as(u32, 1) << @intCast(a)) == 0) continue;
        const na = s[I_N + a];
        if (na == 0) return @intCast(a);
        const v = s[I_MEAN + a] + c * @sqrt(2 * @log(@max(s[I_TOT], 1)) / na);
        if (v > bv) {
            bv = v;
            best = @intCast(a);
        }
    }
    return best;
}

/// registra a recompensa do braço `a`; o Page–Hinkley (tolerância `delta`, limiar `gamma`) nas recompensas
/// reinicia o bandido quando elas caem de vez. true se reiniciou
pub fn banditUpdate(s: []f64, a: usize, reward: f64, delta: f64, gamma: f64) bool {
    const k: usize = @intFromFloat(s[I_K]);
    if (a >= k) return false;
    s[I_N + a] += 1;
    s[I_TOT] += 1;
    s[I_MEAN + a] += (reward - s[I_MEAN + a]) / s[I_N + a];
    // Page–Hinkley (Da Costa et al. 2008, seção 3.2, a conferir no PDF): m_t = Σ (r − r̄ + δ), M_t = max m;
    // quando as recompensas caem, m desce e dispara em M − m > γ
    s[I_PH + 1] += 1;
    s[I_PH] += (reward - s[I_PH]) / s[I_PH + 1];
    s[I_PH + 2] += reward - s[I_PH] + delta;
    s[I_PH + 3] = @max(s[I_PH + 3], s[I_PH + 2]);
    if (s[I_PH + 3] - s[I_PH + 2] > gamma) {
        banditReset(s);
        return true;
    }
    return false;
}

// ------------------------------------------------------------------ crenças (cultural) e regra (LEM)

fn better(a: f64, b: f64) bool {
    const na = if (std.math.isNan(a)) -std.math.inf(f64) else a;
    const nb = if (std.math.isNan(b)) -std.math.inf(f64) else b;
    return na > nb;
}

/// os índices de `fit` do melhor para o pior (NaN no fim)
fn order(m: usize, fit: []const f64, idx: *[max_pop]usize) void {
    for (0..m) |i| idx[i] = i;
    std.sort.insertion(usize, idx[0..m], fit, struct {
        fn lt(f: []const f64, a: usize, b: usize) bool {
            return better(f[a], f[b]);
        }
    }.lt);
}

fn top(m: usize, frac: f64) usize {
    const k: usize = @intFromFloat(@ceil(frac * @as(f64, @floatFromInt(m))));
    return std.math.clamp(k, 1, m);
}

/// o espaço normativo: a faixa [lo, hi] de cada variável entre os `frac` melhores de `pop` (m × n)
pub fn normative(n: usize, m: usize, pop: []const f64, fit: []const f64, frac: f64, lo: []f64, hi: []f64) bool {
    if (n == 0 or n > max_n or m == 0 or m > max_pop) return false;
    var idx: [max_pop]usize = undefined;
    order(m, fit, &idx);
    const h = top(m, frac);
    for (0..n) |j| {
        lo[j] = 1;
        hi[j] = 0;
        for (idx[0..h]) |i| {
            lo[j] = @min(lo[j], pop[i * n + j]);
            hi[j] = @max(hi[j], pop[i * n + j]);
        }
    }
    return true;
}

/// a regra do LEM: H = os `frac` melhores, L = os `frac` piores. Por variável, o corte t (entre dois valores
/// vizinhos de H ∪ L) e o lado (≥ ou ≤) que deixam mais H dentro menos L dentro; a faixa sai da faixa de H cortada
/// por ele. Uma variável em que nenhum corte separa fica com a faixa de H
pub fn lemBox(n: usize, m: usize, pop: []const f64, fit: []const f64, frac: f64, lo: []f64, hi: []f64) bool {
    if (n == 0 or n > max_n or m < 2 or m > max_pop) return false;
    var idx: [max_pop]usize = undefined;
    order(m, fit, &idx);
    const h = @min(top(m, frac), m / 2);
    const H = idx[0..h];
    const L = idx[m - h .. m];
    for (0..n) |j| {
        var hl: f64 = 1;
        var hh: f64 = 0;
        for (H) |i| {
            hl = @min(hl, pop[i * n + j]);
            hh = @max(hh, pop[i * n + j]);
        }
        lo[j] = hl;
        hi[j] = hh;
        var best: i64 = 0;
        // candidatos: os pontos médios entre cada valor de L e o de H mais perto (basta testar os valores de L)
        for (L) |l| {
            const t = pop[l * n + j];
            for ([_]bool{ true, false }) |up| { // up: x ≥ t (exclusivo), senão x ≤ t
                var score: i64 = 0;
                for (H) |i| score += if ((pop[i * n + j] > t) == up) 1 else 0;
                for (L) |q| score -= if ((pop[q * n + j] > t) == up and pop[q * n + j] != t) 1 else 0;
                if (score > best) {
                    best = score;
                    if (up) {
                        lo[j] = @max(hl, t);
                        hi[j] = hh;
                    } else {
                        lo[j] = hl;
                        hi[j] = @min(hh, t);
                    }
                }
            }
        }
    }
    return true;
}

/// `count` pontos uniformes na caixa [lo, hi] (por variável), de uma semente e geração (`out`: count × n)
pub fn boxSample(n: usize, lo: []const f64, hi: []const f64, count: usize, seed: u64, generation: u64, out: []f64) bool {
    if (n == 0 or n > max_n or count > max_pop) return false;
    var p = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% generation +% 7);
    const r = p.random();
    for (0..count) |i| {
        for (0..n) |j| {
            const a = std.math.clamp(@min(lo[j], hi[j]), 0, 1);
            const b = std.math.clamp(@max(lo[j], hi[j]), 0, 1);
            out[i * n + j] = a + r.float(f64) * (b - a);
        }
    }
    return true;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "reparo: uma restrição linear fecha num passo, na menor norma; duas também" {
    // g(x) = 2 x0 + x1 − 1 = 0,5 em x = (0,5, 0,5): J = (2, 1), Δ = −J g / |J|² = −(0,2, 0,1)
    var d: [2]f64 = undefined;
    try testing.expect(repairStep(2, 1, &.{ 2, 1 }, &.{0.5}, 0, &d));
    try testing.expectApproxEqAbs(@as(f64, -0.2), d[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.1), d[1], 1e-12);
    // duas restrições em três variáveis: J Δ = −g exatamente
    const J = [_]f64{ 1, 0, 1, 0, 1, -1 };
    const g = [_]f64{ 0.3, -0.2 };
    var e: [3]f64 = undefined;
    try testing.expect(repairStep(3, 2, &J, &g, 0, &e));
    for (0..2) |i| try testing.expectApproxEqAbs(-g[i], J[i * 3] * e[0] + J[i * 3 + 1] * e[1] + J[i * 3 + 2] * e[2], 1e-12);
    // duas linhas iguais: singular sem λ, resolve com λ
    try testing.expect(!repairStep(2, 2, &.{ 1, 1, 1, 1 }, &.{ 1, 1 }, 0, &d));
    try testing.expect(repairStep(2, 2, &.{ 1, 1, 1, 1 }, &.{ 1, 1 }, 1e-6, &d));
}

test "ε: o nível cai até 0 em Tc; dentro de ε vale a nota, fora vale a violação" {
    try testing.expectEqual(@as(f64, 2), epsLevel(2, 0, 10, 3));
    try testing.expectApproxEqAbs(@as(f64, 2 * 0.125), epsLevel(2, 5, 10, 3), 1e-12);
    try testing.expectEqual(@as(f64, 0), epsLevel(2, 10, 10, 3));
    try testing.expect(epsWorse(1, 0.1, 5, 0.2, 0.3)); // as duas até ε: a nota decide
    try testing.expect(epsWorse(9, 0.5, 1, 0.2, 0.3)); // uma fora: a violação decide
    try testing.expect(!epsWorse(9, 0.2, 1, 0.5, 0)); // ε = 0: a regra de Deb
    try testing.expect(epsWorse(std.math.nan(f64), 0, 1, 0, 0)); // NaN é a pior
}

test "bandido: joga cada braço uma vez, depois prefere o que paga; reinicia quando o pagamento some" {
    var s: [state_len]f64 = undefined;
    try testing.expect(banditInit(&s, 3));
    try testing.expectEqual(@as(i32, 0), banditPick(&s, 0.5, 0b111));
    try testing.expectEqual(@as(i32, 2), banditPick(&s, 0.5, 0b100)); // só o 2 é permitido
    try testing.expectEqual(@as(i32, -1), banditPick(&s, 0.5, 0));
    var restarted = false;
    for (0..60) |t| {
        const a: usize = @intCast(banditPick(&s, 0.2, 0b111));
        const r: f64 = if (a == 1) 1.0 else 0.0;
        restarted = restarted or banditUpdate(&s, a, r, 0.05, 50);
        _ = t;
    }
    try testing.expect(!restarted);
    try testing.expect(s[I_N + 1] > s[I_N + 0] + s[I_N + 2]); // o braço 1 é o mais jogado
    // agora ninguém paga: o Page–Hinkley dispara e zera as contagens
    var hit = false;
    for (0..200) |_| {
        const a: usize = @intCast(banditPick(&s, 0.2, 0b111));
        if (banditUpdate(&s, a, 0.0, 0.05, 3)) {
            hit = true;
            break;
        }
    }
    try testing.expect(hit);
    try testing.expectEqual(@as(f64, 0), s[I_N + 1]);
    try testing.expectEqual(@as(f64, 1), s[I_PH + 4]);
}

test "cultural e LEM: a faixa dos melhores; a regra corta onde os piores estão" {
    // 8 pontos em 2 variáveis: a nota cresce com x0; x1 não importa
    const pop = [_]f64{ 0.1, 0.5, 0.2, 0.9, 0.3, 0.1, 0.4, 0.6, 0.6, 0.2, 0.7, 0.8, 0.8, 0.3, 0.9, 0.7 };
    const fit = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.6, 0.7, 0.8, std.math.nan(f64) };
    var lo: [2]f64 = undefined;
    var hi: [2]f64 = undefined;
    try testing.expect(normative(2, 8, &pop, &fit, 0.25, &lo, &hi));
    try testing.expectEqual(@as(f64, 0.7), lo[0]); // os 2 melhores: x0 = 0,8 e 0,7 (o NaN é o pior)
    try testing.expectEqual(@as(f64, 0.8), hi[0]);
    try testing.expect(lemBox(2, 8, &pop, &fit, 0.5, &lo, &hi));
    // H = x0 ∈ {0,8; 0,7; 0,6; 0,4}, L = {0,1; 0,2; 0,3; 0,9 (NaN)}: o corte em x0 > 0,3 deixa L de fora (menos o 0,9)
    try testing.expect(lo[0] >= 0.3 and hi[0] <= 0.8);
    var out: [10 * 2]f64 = undefined;
    try testing.expect(boxSample(2, &lo, &hi, 10, 4, 0, &out));
    for (0..10) |i| try testing.expect(out[i * 2] >= lo[0] and out[i * 2] <= hi[0]);
    var again: [10 * 2]f64 = undefined;
    _ = boxSample(2, &lo, &hi, 10, 4, 0, &again);
    try testing.expectEqualSlices(f64, &out, &again);
}

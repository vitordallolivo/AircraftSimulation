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

/// Δx = −Jᵀ (J Jᵀ + λ I)⁻¹ g (`jacobian` J: constraints × dims por linhas, `violations` g, `out`: dims). false se não cabe ou J Jᵀ + λ I é singular
pub fn repairStep(dims: usize, constraints: usize, jacobian: []const f64, violations: []const f64, lambda: f64, out: []f64) bool {
    if (dims == 0 or dims > max_n or constraints == 0 or constraints > max_m) return false;
    var gram: [max_m][max_m]f64 = @splat(@splat(0));
    var rhs: [max_m]f64 = @splat(0);
    for (0..constraints) |i| {
        for (0..constraints) |k| {
            var sum: f64 = 0;
            for (0..dims) |j| sum += jacobian[i * dims + j] * jacobian[k * dims + j];
            gram[i][k] = sum;
        }
        gram[i][i] += lambda;
        rhs[i] = violations[i];
    }
    var multipliers: [max_m]f64 = undefined;
    if (!linalg.solve(max_m, gram, constraints, rhs, &multipliers)) return false;
    for (0..dims) |j| {
        var sum: f64 = 0;
        for (0..constraints) |i| sum += jacobian[i * dims + j] * multipliers[i];
        out[j] = -sum;
    }
    return true;
}

// ------------------------------------------------------------------ ε-restrito

/// ε(t) = ε₀ (1 − t/Tc)^cp para t = `generation` < Tc = `cutoff`, 0 depois
pub fn epsLevel(eps0: f64, generation: f64, cutoff: f64, cp: f64) f64 {
    if (!(cutoff > 0) or generation >= cutoff) return 0;
    return eps0 * std.math.pow(f64, 1 - @max(generation, 0) / cutoff, cp);
}

/// a < b na ordem ε (maior nota é melhor; NaN é a pior): pela nota se as duas violações estão até ε (ou são
/// iguais), senão pela violação
pub fn epsWorse(fa: f64, va: f64, fb: f64, vb: f64, eps: f64) bool {
    const score_a = if (std.math.isNan(fa)) -std.math.inf(f64) else fa;
    const score_b = if (std.math.isNan(fb)) -std.math.inf(f64) else fb;
    if ((va <= eps and vb <= eps) or va == vb) return score_a < score_b;
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

/// zera o bandido de `arms` braços em `bandit` (state_len f64); false se não cabe
pub fn banditInit(bandit: []f64, arms: usize) bool {
    if (arms == 0 or arms > max_arms or bandit.len < state_len) return false;
    @memset(bandit[0..state_len], 0);
    bandit[I_K] = @floatFromInt(arms);
    return true;
}

fn banditReset(bandit: []f64) void {
    const arms = bandit[I_K];
    const restarts = bandit[I_PH + 4];
    @memset(bandit[0..state_len], 0);
    bandit[I_K] = arms;
    bandit[I_PH + 4] = restarts + 1;
}

/// o braço a jogar entre os permitidos (`allowed`: bit k = braço k): o primeiro ainda não jogado, senão o de maior
/// p̂ₖ + C √(2 ln Σn / nₖ). −1 se nenhum é permitido
pub fn banditPick(bandit: []const f64, explore_weight: f64, allowed: u32) i32 {
    const arms: usize = @intFromFloat(bandit[I_K]);
    var best: i32 = -1;
    var best_ucb = -std.math.inf(f64);
    for (0..arms) |arm| {
        if (allowed & (@as(u32, 1) << @intCast(arm)) == 0) continue;
        const plays = bandit[I_N + arm];
        if (plays == 0) return @intCast(arm);
        const ucb = bandit[I_MEAN + arm] + explore_weight * @sqrt(2 * @log(@max(bandit[I_TOT], 1)) / plays);
        if (ucb > best_ucb) {
            best_ucb = ucb;
            best = @intCast(arm);
        }
    }
    return best;
}

/// registra a recompensa do braço `arm`; o Page–Hinkley (tolerância `delta`, limiar `gamma`) nas recompensas
/// reinicia o bandido quando elas caem de vez. true se reiniciou
pub fn banditUpdate(bandit: []f64, arm: usize, reward: f64, delta: f64, gamma: f64) bool {
    const arms: usize = @intFromFloat(bandit[I_K]);
    if (arm >= arms) return false;
    bandit[I_N + arm] += 1;
    bandit[I_TOT] += 1;
    bandit[I_MEAN + arm] += (reward - bandit[I_MEAN + arm]) / bandit[I_N + arm];
    // Page–Hinkley (Da Costa et al. 2008, seção 3.2, a conferir no PDF): m_t = Σ (r − r̄ + δ), M_t = max m;
    // quando as recompensas caem, m desce e dispara em M − m > γ
    bandit[I_PH + 1] += 1;
    bandit[I_PH] += (reward - bandit[I_PH]) / bandit[I_PH + 1];
    bandit[I_PH + 2] += reward - bandit[I_PH] + delta;
    bandit[I_PH + 3] = @max(bandit[I_PH + 3], bandit[I_PH + 2]);
    if (bandit[I_PH + 3] - bandit[I_PH + 2] > gamma) {
        banditReset(bandit);
        return true;
    }
    return false;
}

// ------------------------------------------------------------------ crenças (cultural) e regra (LEM)

fn better(first: f64, second: f64) bool {
    const score_a = if (std.math.isNan(first)) -std.math.inf(f64) else first;
    const score_b = if (std.math.isNan(second)) -std.math.inf(f64) else second;
    return score_a > score_b;
}

/// os índices de `fit` do melhor para o pior (NaN no fim)
fn order(pop_count: usize, fit: []const f64, idx: *[max_pop]usize) void {
    for (0..pop_count) |i| idx[i] = i;
    std.sort.insertion(usize, idx[0..pop_count], fit, struct {
        fn lessThan(scores: []const f64, first: usize, second: usize) bool {
            return better(scores[first], scores[second]);
        }
    }.lessThan);
}

fn top(pop_count: usize, frac: f64) usize {
    const count: usize = @intFromFloat(@ceil(frac * @as(f64, @floatFromInt(pop_count))));
    return std.math.clamp(count, 1, pop_count);
}

/// o espaço normativo: a faixa [lo, hi] de cada variável entre os `frac` melhores de `pop` (pop_count × dims)
pub fn normative(dims: usize, pop_count: usize, pop: []const f64, fit: []const f64, frac: f64, lo: []f64, hi: []f64) bool {
    if (dims == 0 or dims > max_n or pop_count == 0 or pop_count > max_pop) return false;
    var idx: [max_pop]usize = undefined;
    order(pop_count, fit, &idx);
    const best_count = top(pop_count, frac);
    for (0..dims) |j| {
        lo[j] = 1;
        hi[j] = 0;
        for (idx[0..best_count]) |i| {
            lo[j] = @min(lo[j], pop[i * dims + j]);
            hi[j] = @max(hi[j], pop[i * dims + j]);
        }
    }
    return true;
}

/// a regra do LEM: H = os `frac` melhores, L = os `frac` piores. Por variável, o corte t (entre dois valores
/// vizinhos de H ∪ L) e o lado (≥ ou ≤) que deixam mais H dentro menos L dentro; a faixa sai da faixa de H cortada
/// por ele. Uma variável em que nenhum corte separa fica com a faixa de H
pub fn lemBox(dims: usize, pop_count: usize, pop: []const f64, fit: []const f64, frac: f64, lo: []f64, hi: []f64) bool {
    if (dims == 0 or dims > max_n or pop_count < 2 or pop_count > max_pop) return false;
    var idx: [max_pop]usize = undefined;
    order(pop_count, fit, &idx);
    const group_size = @min(top(pop_count, frac), pop_count / 2);
    const best = idx[0..group_size];
    const worst = idx[pop_count - group_size .. pop_count];
    for (0..dims) |j| {
        var best_lo: f64 = 1;
        var best_hi: f64 = 0;
        for (best) |i| {
            best_lo = @min(best_lo, pop[i * dims + j]);
            best_hi = @max(best_hi, pop[i * dims + j]);
        }
        lo[j] = best_lo;
        hi[j] = best_hi;
        var best_score: i64 = 0;
        // candidatos: os pontos médios entre cada valor de L e o de H mais perto (basta testar os valores de L)
        for (worst) |worst_i| {
            const cut = pop[worst_i * dims + j];
            for ([_]bool{ true, false }) |up| { // up: x ≥ t (exclusivo), senão x ≤ t
                var score: i64 = 0;
                for (best) |i| score += if ((pop[i * dims + j] > cut) == up) 1 else 0;
                for (worst) |other| score -= if ((pop[other * dims + j] > cut) == up and pop[other * dims + j] != cut) 1 else 0;
                if (score > best_score) {
                    best_score = score;
                    if (up) {
                        lo[j] = @max(best_lo, cut);
                        hi[j] = best_hi;
                    } else {
                        lo[j] = best_lo;
                        hi[j] = @min(best_hi, cut);
                    }
                }
            }
        }
    }
    return true;
}

/// `count` pontos uniformes na caixa [lo, hi] (por variável), de uma semente e geração (`out`: count × dims)
pub fn boxSample(dims: usize, lo: []const f64, hi: []const f64, count: usize, seed: u64, generation: u64, out: []f64) bool {
    if (dims == 0 or dims > max_n or count > max_pop) return false;
    var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% generation +% 7);
    const random = prng.random();
    for (0..count) |i| {
        for (0..dims) |j| {
            const low = std.math.clamp(@min(lo[j], hi[j]), 0, 1);
            const high = std.math.clamp(@max(lo[j], hi[j]), 0, 1);
            out[i * dims + j] = low + random.float(f64) * (high - low);
        }
    }
    return true;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "reparo: uma restrição linear fecha num passo, na menor norma; duas também" {
    // g(x) = 2 x0 + x1 − 1 = 0,5 em x = (0,5, 0,5): J = (2, 1), Δ = −J g / |J|² = −(0,2, 0,1)
    var step: [2]f64 = undefined;
    try testing.expect(repairStep(2, 1, &.{ 2, 1 }, &.{0.5}, 0, &step));
    try testing.expectApproxEqAbs(@as(f64, -0.2), step[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.1), step[1], 1e-12);
    // duas restrições em três variáveis: J Δ = −g exatamente
    const jacobian = [_]f64{ 1, 0, 1, 0, 1, -1 };
    const violations = [_]f64{ 0.3, -0.2 };
    var step3: [3]f64 = undefined;
    try testing.expect(repairStep(3, 2, &jacobian, &violations, 0, &step3));
    for (0..2) |i| try testing.expectApproxEqAbs(-violations[i], jacobian[i * 3] * step3[0] + jacobian[i * 3 + 1] * step3[1] + jacobian[i * 3 + 2] * step3[2], 1e-12);
    // duas linhas iguais: singular sem λ, resolve com λ
    try testing.expect(!repairStep(2, 2, &.{ 1, 1, 1, 1 }, &.{ 1, 1 }, 0, &step));
    try testing.expect(repairStep(2, 2, &.{ 1, 1, 1, 1 }, &.{ 1, 1 }, 1e-6, &step));
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
    var bandit: [state_len]f64 = undefined;
    try testing.expect(banditInit(&bandit, 3));
    try testing.expectEqual(@as(i32, 0), banditPick(&bandit, 0.5, 0b111));
    try testing.expectEqual(@as(i32, 2), banditPick(&bandit, 0.5, 0b100)); // só o 2 é permitido
    try testing.expectEqual(@as(i32, -1), banditPick(&bandit, 0.5, 0));
    var restarted = false;
    for (0..60) |round| {
        const arm: usize = @intCast(banditPick(&bandit, 0.2, 0b111));
        const reward: f64 = if (arm == 1) 1.0 else 0.0;
        restarted = restarted or banditUpdate(&bandit, arm, reward, 0.05, 50);
        _ = round;
    }
    try testing.expect(!restarted);
    try testing.expect(bandit[I_N + 1] > bandit[I_N + 0] + bandit[I_N + 2]); // o braço 1 é o mais jogado
    // agora ninguém paga: o Page–Hinkley dispara e zera as contagens
    var hit = false;
    for (0..200) |_| {
        const arm: usize = @intCast(banditPick(&bandit, 0.2, 0b111));
        if (banditUpdate(&bandit, arm, 0.0, 0.05, 3)) {
            hit = true;
            break;
        }
    }
    try testing.expect(hit);
    try testing.expectEqual(@as(f64, 0), bandit[I_N + 1]);
    try testing.expectEqual(@as(f64, 1), bandit[I_PH + 4]);
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

//! Polar 2D de um perfil e os números que saem dela, a etapa Perfis do dimensionamento.
//!
//! A polar "modelo" é a mesma hipótese das faixas do núcleo, em 2D: a reta c_l = a (α − α_L0) até perto do
//! estol, misturada com a placa plana 2 sen²α cos α pela sigmoide de Beard e McLain (Small Unmanned Aircraft,
//! 2012, eq. 4.10, `aero.sigmaStall`), com o α de transição ajustado para o pico ser o c_l,max do perfil. O
//! arrasto é c_d0 mais a parte da placa plana, σ 1,2 sen²α. Igual a `model_polar` de `aerosim/aero/sections.py`.
//!
//! `metrics` tira de qualquer polar (do modelo ou de um arquivo do XFLR5) o c_l,max e o α de estol, o
//! (c_l/c_d) máximo, o c_d mínimo e, no trecho colado, a1 e α_L0 pela reta de Theil-Sen (mediana das
//! inclinações de todos os pares), que não se deixa levar pelos saltos de bolha de Re baixo. Igual a `metrics`
//! de `aerosim/design/airfoils.py`.
const std = @import("std");
const aero = @import("aero.zig");

/// a inclinação da sigmoide de estol (o `M_BLEND` da GUI)
pub const steepness = 50.0;
/// o máximo de ângulos numa polar
pub const max_points = 128;

/// o que o modelo precisa do perfil
pub const Airfoil = struct {
    cl_alpha: f64, // 1/rad (2D)
    alpha0: f64, // graus
    cl_max: f64,
    cd0: f64,
    cm_ac: f64,
};

/// uma polar: α (graus), c_l, c_d e c_m, com `count` pontos
pub const Polar = struct {
    alpha: [max_points]f64 = undefined,
    cl: [max_points]f64 = undefined,
    cd: [max_points]f64 = undefined,
    cm: [max_points]f64 = undefined,
    count: usize = 0,
};

/// o c_l do modelo em `angle` (rad), com a mistura no α de transição `stall`
fn modelCl(angle: f64, slope: f64, cl_zero: f64, stall: f64) f64 {
    const sigma = aero.sigmaStall(angle, stall, steepness);
    return (1 - sigma) * (cl_zero + slope * angle) + sigma * 2 * std.math.sign(angle) * std.math.pow(f64, @sin(angle), 2) * @cos(angle);
}

/// o α de transição (rad) que faz o pico do c_l ser `cl_max` (bisseção, pico numa malha de 3000 pontos em [0; 0,9])
pub fn stallAngle(slope: f64, cl_zero: f64, cl_max: f64) f64 {
    var low: f64 = 0.02;
    var high: f64 = 0.8;
    for (0..50) |_| {
        const middle = 0.5 * (low + high);
        var peak: f64 = -std.math.inf(f64);
        for (0..3000) |i| peak = @max(peak, modelCl(0.9 * @as(f64, @floatFromInt(i)) / 2999.0, slope, cl_zero, middle));
        if (peak > cl_max) high = middle else low = middle;
    }
    return 0.5 * (low + high);
}

/// a polar do modelo nos ângulos `alphas` (graus)
pub fn modelPolar(airfoil: Airfoil, alphas: []const f64, out: *Polar) void {
    const cl_zero = -airfoil.cl_alpha * std.math.degreesToRadians(airfoil.alpha0);
    const stall = stallAngle(airfoil.cl_alpha, cl_zero, airfoil.cl_max);
    out.count = @min(alphas.len, max_points);
    for (alphas[0..out.count], 0..) |alpha, i| {
        const angle = std.math.degreesToRadians(alpha);
        const sigma = aero.sigmaStall(angle, stall, steepness);
        out.alpha[i] = alpha;
        out.cl[i] = modelCl(angle, airfoil.cl_alpha, cl_zero, stall);
        out.cd[i] = airfoil.cd0 + sigma * 1.2 * std.math.pow(f64, @sin(angle), 2);
        out.cm[i] = airfoil.cm_ac;
    }
}

/// uma polar medida (`source`, em ordem de α) lida nos ângulos `alphas`; fora da faixa dela fica NaN
pub fn interpolate(source: *const Polar, alphas: []const f64, out: *Polar) void {
    out.count = @min(alphas.len, max_points);
    for (alphas[0..out.count], 0..) |alpha, i| {
        out.alpha[i] = alpha;
        out.cl[i] = std.math.nan(f64);
        out.cd[i] = std.math.nan(f64);
        out.cm[i] = std.math.nan(f64);
        if (source.count == 0 or alpha < source.alpha[0] or alpha > source.alpha[source.count - 1]) continue;
        var k: usize = 1;
        while (k < source.count - 1 and source.alpha[k] < alpha) k += 1;
        const span = source.alpha[k] - source.alpha[k - 1];
        const t = if (span > 0) (alpha - source.alpha[k - 1]) / span else 0;
        out.cl[i] = source.cl[k - 1] + t * (source.cl[k] - source.cl[k - 1]);
        out.cd[i] = source.cd[k - 1] + t * (source.cd[k] - source.cd[k - 1]);
        out.cm[i] = source.cm[k - 1] + t * (source.cm[k] - source.cm[k - 1]);
    }
}

/// os números de uma polar (o lado útil é o do c_l negativo quando o perfil está invertido)
pub const Metrics = struct {
    cl_max: f64,
    alpha_stall: f64, // graus
    ld_max: f64,
    cl_at_ld: f64,
    alpha_at_ld: f64,
    cd_min: f64,
    cl_alpha: f64, // 1/rad
    alpha0: f64, // graus
    cm: f64,
    cd_constant: bool, // c_d igual em toda a parte colada: a polar do modelo, que não compara L/D
    inverted: bool,
};

/// a mediana de `values` (reordena; média dos dois do meio quando a contagem é par, como o numpy)
fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const half = values.len / 2;
    return if (values.len % 2 == 1) values[half] else 0.5 * (values[half - 1] + values[half]);
}

/// c_l,max e α de estol, (c_l/c_d) máx. e onde, c_d mín., a1 e α_L0 (trecho colado), c_m; null com menos de 4 pontos
pub fn metrics(polar: *const Polar) ?Metrics {
    var alpha: [max_points]f64 = undefined;
    var cl: [max_points]f64 = undefined;
    var cd: [max_points]f64 = undefined;
    var cm: [max_points]f64 = undefined;
    var count: usize = 0;
    for (0..polar.count) |i| {
        if (!std.math.isFinite(polar.cl[i]) or !std.math.isFinite(polar.cd[i])) continue;
        alpha[count] = polar.alpha[i];
        cl[count] = polar.cl[i];
        cd[count] = polar.cd[i];
        cm[count] = polar.cm[i];
        count += 1;
    }
    if (count < 4) return null;
    const top = std.mem.indexOfMax(f64, cl[0..count]);
    const bottom = if (top > 0) std.mem.indexOfMin(f64, cl[0 .. top + 1]) else 0;
    const low = cl[bottom];
    const high = cl[top];
    const inverted = -low > high;
    // trecho colado: c_l entre 15 % e 70 % do máximo do lado útil
    var linear: [max_points]bool = undefined;
    var linear_count: usize = 0;
    for (0..count) |i| {
        const middle = i >= bottom and i <= top;
        linear[i] = middle and (if (inverted) cl[i] <= 0.15 * low and cl[i] >= 0.7 * low else cl[i] >= 0.15 * high and cl[i] <= 0.7 * high);
        if (linear[i]) linear_count += 1;
    }
    if (linear_count < 3) {
        linear_count = 0;
        const middle_count = top + 1 - bottom;
        for (0..count) |i| {
            linear[i] = if (middle_count >= 3) i >= bottom and i <= top else true;
            if (linear[i]) linear_count += 1;
        }
    }
    var angles: [max_points]f64 = undefined;
    var lifts: [max_points]f64 = undefined;
    var moment_sum: f64 = 0;
    var n: usize = 0;
    for (0..count) |i| {
        if (!linear[i]) continue;
        angles[n] = std.math.degreesToRadians(alpha[i]);
        lifts[n] = cl[i];
        moment_sum += cm[i];
        n += 1;
    }
    var slopes: [max_points * (max_points - 1) / 2]f64 = undefined;
    var pairs: usize = 0;
    for (0..n) |i| {
        for (i + 1..n) |j| {
            slopes[pairs] = (lifts[j] - lifts[i]) / (angles[j] - angles[i]);
            pairs += 1;
        }
    }
    const slope = median(slopes[0..pairs]);
    var intercepts: [max_points]f64 = undefined;
    for (0..n) |i| intercepts[i] = lifts[i] - slope * angles[i];
    const intercept = median(intercepts[0..n]);
    var best: usize = 0;
    var best_ratio = -std.math.inf(f64);
    for (0..count) |i| {
        if (!(cd[i] > 0)) continue;
        const ratio = (if (inverted) -cl[i] else cl[i]) / cd[i];
        if (ratio > best_ratio) {
            best_ratio = ratio;
            best = i;
        }
    }
    var cd_low = std.math.inf(f64);
    var cd_high = -std.math.inf(f64);
    for (bottom..top + 1) |i| {
        cd_low = @min(cd_low, cd[i]);
        cd_high = @max(cd_high, cd[i]);
    }
    const stall_index = if (inverted) bottom else top;
    return .{
        .cl_max = if (inverted) -low else high,
        .alpha_stall = alpha[stall_index],
        .ld_max = best_ratio,
        .cl_at_ld = cl[best],
        .alpha_at_ld = alpha[best],
        .cd_min = cd_low,
        .cl_alpha = slope,
        .alpha0 = if (slope != 0) -std.math.radiansToDegrees(intercept / slope) else 0,
        .cm = moment_sum / @as(f64, @floatFromInt(n)),
        .cd_constant = cd_high - cd_low < 1e-6,
        .inverted = inverted,
    };
}

/// o número de Reynolds de uma corda: ρ V c / μ, com μ = 1,81e-5 Pa s (ar a 15 °C, como a GUI)
pub fn reynolds(density: f64, airspeed: f64, chord: f64) f64 {
    return density * airspeed * chord / 1.81e-5;
}

/// o ramo colado de uma polar (do menor c_l antes do pico até o pico), em ordem de c_l: dá o c_d num c_l pedido
pub const DragBranch = struct {
    cl: [max_points]f64 = undefined,
    cd: [max_points]f64 = undefined,
    count: usize = 0,
    fallback: f64 = 0.01, // menos de 2 pontos: o menor c_d da polar

    /// o c_d no c_l pedido (interpolado; fora do ramo, o da ponta, como `np.interp`)
    pub fn at(branch: *const DragBranch, cl: f64) f64 {
        if (branch.count < 2) return branch.fallback;
        if (cl <= branch.cl[0]) return branch.cd[0];
        for (1..branch.count) |k| {
            if (cl <= branch.cl[k]) {
                const span = branch.cl[k] - branch.cl[k - 1];
                return if (span > 0) branch.cd[k - 1] + (cl - branch.cl[k - 1]) / span * (branch.cd[k] - branch.cd[k - 1]) else branch.cd[k];
            }
        }
        return branch.cd[branch.count - 1];
    }
};

/// o ramo colado de `polar` (o `drag_at` de `aerosim/design/airfoils.py`)
pub fn dragBranch(polar: *const Polar) DragBranch {
    var cl: [max_points]f64 = undefined;
    var cd: [max_points]f64 = undefined;
    var count: usize = 0;
    for (0..polar.count) |i| {
        if (!std.math.isFinite(polar.cl[i]) or !std.math.isFinite(polar.cd[i])) continue;
        cl[count] = polar.cl[i];
        cd[count] = polar.cd[i];
        count += 1;
    }
    var branch: DragBranch = .{};
    if (count == 0) return branch;
    const top = std.mem.indexOfMax(f64, cl[0..count]);
    const bottom = if (top > 0) std.mem.indexOfMin(f64, cl[0 .. top + 1]) else 0;
    branch.fallback = std.mem.min(f64, cd[0..count]);
    branch.count = top + 1 - bottom;
    @memcpy(branch.cl[0..branch.count], cl[bottom .. top + 1]);
    @memcpy(branch.cd[0..branch.count], cd[bottom .. top + 1]);
    // em ordem de c_l (ordenação estável, como o argsort do numpy nos empates não importa: c_l iguais têm a mesma posição)
    for (1..branch.count) |i| {
        var k = i;
        while (k > 0 and branch.cl[k - 1] > branch.cl[k]) : (k -= 1) {
            std.mem.swap(f64, &branch.cl[k - 1], &branch.cl[k]);
            std.mem.swap(f64, &branch.cd[k - 1], &branch.cd[k]);
        }
    }
    return branch;
}

/// o perfil com os números ajustados na polar (o que a asa usa); simétrico: α_L0 = c_m = 0, porque em Re baixo
/// a bolha desloca o ajuste (o `fitted` de `aerosim/design/airfoils.py`)
pub fn fitted(airfoil: Airfoil, found: ?Metrics, symmetric: bool) Airfoil {
    const numbers = found orelse return airfoil;
    return .{
        .cl_alpha = numbers.cl_alpha,
        .alpha0 = if (symmetric) 0 else numbers.alpha0,
        .cl_max = numbers.cl_max,
        .cd0 = numbers.cd_min,
        .cm_ac = if (symmetric) 0 else numbers.cm,
    };
}

test "polar do modelo e números: iguais à GUI em Python" {
    // referência: model_polar e metrics de aerosim (NACA 2412 padrão: a = 5,9, α_L0 = −2, c_l,max 1,4, c_d0 0,012)
    var alphas: [73]f64 = undefined;
    for (&alphas, 0..) |*alpha, i| alpha.* = -16 + 0.5 * @as(f64, @floatFromInt(i));
    var polar: Polar = .{};
    modelPolar(.{ .cl_alpha = 5.9, .alpha0 = -2.0, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.05 }, &alphas, &polar);
    const found = metrics(&polar).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.39748), found.cl_max, 1e-5);
    try std.testing.expectEqual(@as(f64, 12.5), found.alpha_stall);
    try std.testing.expectApproxEqAbs(@as(f64, 102.283914), found.ld_max, 1e-4);
    try std.testing.expectEqual(@as(f64, 11.0), found.alpha_at_ld);
    try std.testing.expectApproxEqAbs(@as(f64, 5.897278), found.cl_alpha, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, -2.001815), found.alpha0, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), found.cm, 1e-12);
    try std.testing.expect(!found.cd_constant and !found.inverted);
    // uma polar medida lida noutros ângulos
    var measured: Polar = .{ .count = 3 };
    measured.alpha[0..3].* = .{ 0, 2, 4 };
    measured.cl[0..3].* = .{ 0.2, 0.4, 0.6 };
    measured.cd[0..3].* = .{ 0.01, 0.012, 0.016 };
    measured.cm[0..3].* = .{ -0.1, -0.1, -0.1 };
    var read: Polar = .{};
    interpolate(&measured, &.{ -1, 1, 3 }, &read);
    try std.testing.expect(std.math.isNan(read.cl[0]));
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), read.cl[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.014), read.cd[2], 1e-12);
}

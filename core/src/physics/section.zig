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
const numerics = @import("../numerics.zig");
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
    const peak_points = @max(numerics.count(numerics.active.section_peak_points), 2);
    for (0..numerics.count(numerics.active.stall_angle_bisections)) |_| {
        const middle = 0.5 * (low + high);
        var peak: f64 = -std.math.inf(f64);
        for (0..peak_points) |i| peak = @max(peak, modelCl(0.9 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(peak_points - 1)), slope, cl_zero, middle));
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

/// a polar de uma família (as polares de um perfil em Reynolds crescente) no Reynolds `reynolds_value`, lida nos
/// ângulos `alphas`: linear em Re entre as duas vizinhas. Fora da faixa de Re da família usa a mais próxima e
/// devolve `true`: nada é extrapolado
pub fn atReynolds(family_reynolds: []const f64, family: []const Polar, reynolds_value: f64, alphas: []const f64, out: *Polar) bool {
    const count = @min(family_reynolds.len, family.len);
    if (count == 0) {
        out.count = 0;
        return true;
    }
    if (count == 1 or reynolds_value <= family_reynolds[0] or reynolds_value >= family_reynolds[count - 1]) {
        const nearest: usize = if (count == 1 or reynolds_value <= family_reynolds[0]) 0 else count - 1;
        interpolate(&family[nearest], alphas, out);
        return reynolds_value != family_reynolds[nearest];
    }
    var upper: usize = 1;
    while (family_reynolds[upper] < reynolds_value) upper += 1;
    const share = (reynolds_value - family_reynolds[upper - 1]) / (family_reynolds[upper] - family_reynolds[upper - 1]);
    var above: Polar = .{};
    interpolate(&family[upper - 1], alphas, out);
    interpolate(&family[upper], alphas, &above);
    for (0..out.count) |i| {
        out.cl[i] += share * (above.cl[i] - out.cl[i]);
        out.cd[i] += share * (above.cd[i] - out.cd[i]);
        out.cm[i] += share * (above.cm[i] - out.cm[i]);
    }
    return false;
}

/// o Reynolds escrito numa linha de cabeçalho ("Re = 0.200 e 6" do XFLR5 e do XFOIL, ou "Re = 200000")
fn lineReynolds(line: []const u8) ?f64 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, "Re")) |found| : (start = found + 2) {
        if (found > 0 and std.ascii.isAlphabetic(line[found - 1])) continue;
        var cursor = found + 2;
        while (cursor < line.len and line[cursor] == ' ') cursor += 1;
        if (cursor >= line.len or line[cursor] != '=') continue;
        cursor += 1;
        while (cursor < line.len and line[cursor] == ' ') cursor += 1;
        const mantissa_start = cursor;
        while (cursor < line.len and (std.ascii.isDigit(line[cursor]) or line[cursor] == '.')) cursor += 1;
        const mantissa = std.fmt.parseFloat(f64, line[mantissa_start..cursor]) catch continue;
        while (cursor < line.len and line[cursor] == ' ') cursor += 1;
        if (cursor >= line.len or (line[cursor] != 'e' and line[cursor] != 'E')) return mantissa;
        cursor += 1;
        while (cursor < line.len and line[cursor] == ' ') cursor += 1;
        const exponent_start = cursor;
        if (cursor < line.len and (line[cursor] == '+' or line[cursor] == '-')) cursor += 1;
        while (cursor < line.len and std.ascii.isDigit(line[cursor])) cursor += 1;
        const exponent = std.fmt.parseInt(i32, line[exponent_start..cursor], 10) catch return mantissa;
        return mantissa * std.math.pow(f64, 10, @floatFromInt(exponent));
    }
    return null;
}

/// as colunas da tabela de uma polar em texto (null: o arquivo não tem a coluna)
const PolarColumns = struct { alpha: usize, cl: usize, cd: ?usize = null, cm: ?usize = null };

/// as colunas pelo cabeçalho "alpha CL CD ... Cm" (maiúsculas ou não), ou null se a linha não é o cabeçalho
fn polarHeader(line: []const u8) ?PolarColumns {
    var alpha: ?usize = null;
    var cl: ?usize = null;
    var columns: PolarColumns = .{ .alpha = 0, .cl = 0 };
    var names = std.mem.tokenizeAny(u8, line, ", \t;");
    var index: usize = 0;
    while (names.next()) |name| : (index += 1) {
        if (std.ascii.eqlIgnoreCase(name, "alpha")) alpha = index;
        if (std.ascii.eqlIgnoreCase(name, "cl")) cl = index;
        if (std.ascii.eqlIgnoreCase(name, "cd")) columns.cd = index;
        if (std.ascii.eqlIgnoreCase(name, "cm")) columns.cm = index;
    }
    columns.alpha = alpha orelse return null;
    columns.cl = cl orelse return null;
    return columns;
}

/// uma passada pelo texto da polar: conta as linhas de números depois do cabeçalho e, com `out`, guarda uma a cada
/// `stride`. Devolve o total de linhas e o Reynolds do cabeçalho (NaN: o arquivo não diz)
fn scanPolar(text: []const u8, out: ?*Polar, stride: usize) struct { rows: usize, reynolds: f64 } {
    var reynolds_found = std.math.nan(f64);
    var columns: ?PolarColumns = null;
    var rows: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (columns == null) {
            if (lineReynolds(line)) |found| reynolds_found = found;
            columns = polarHeader(line);
            continue;
        }
        const known = columns.?;
        var row = [4]f64{ std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), 0 };
        var numbers = std.mem.tokenizeAny(u8, line, ", \t;");
        var index: usize = 0;
        var valid = true;
        while (numbers.next()) |number| : (index += 1) {
            const value = std.fmt.parseFloat(f64, number) catch {
                valid = false;
                break;
            };
            if (index == known.alpha) row[0] = value;
            if (index == known.cl) row[1] = value;
            if (known.cd != null and index == known.cd.?) row[2] = value;
            if (known.cm != null and index == known.cm.?) row[3] = value;
        }
        if (!valid or std.math.isNan(row[0]) or std.math.isNan(row[1])) continue;
        if (out) |polar| if (rows % stride == 0 and polar.count < max_points) {
            polar.alpha[polar.count] = row[0];
            polar.cl[polar.count] = row[1];
            polar.cd[polar.count] = row[2];
            polar.cm[polar.count] = row[3];
            polar.count += 1;
        };
        rows += 1;
    }
    return .{ .rows = rows, .reynolds = reynolds_found };
}

/// lê uma polar 2D exportada em texto (XFLR5, XFOIL, ou CSV com o cabeçalho "alpha, CL, CD, Cm"), em ordem de α;
/// devolve o Reynolds do cabeçalho (NaN: o arquivo não diz). Com mais linhas do que `max_points`, guarda uma a
/// cada n. Igual a `read_polar_file` de `aerosim/aero/sections.py`
pub fn parsePolar(text: []const u8, out: *Polar) error{NoTable}!f64 {
    out.count = 0;
    const counted = scanPolar(text, null, 1);
    if (counted.rows == 0) return error.NoTable;
    const stride = (counted.rows + max_points - 1) / max_points;
    _ = scanPolar(text, out, stride);
    for (1..out.count) |i| { // ordena por α (inserção: os arquivos já vêm quase em ordem)
        var j = i;
        while (j > 0 and out.alpha[j - 1] > out.alpha[j]) : (j -= 1) {
            std.mem.swap(f64, &out.alpha[j - 1], &out.alpha[j]);
            std.mem.swap(f64, &out.cl[j - 1], &out.cl[j]);
            std.mem.swap(f64, &out.cd[j - 1], &out.cd[j]);
            std.mem.swap(f64, &out.cm[j - 1], &out.cm[j]);
        }
    }
    return counted.reynolds;
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

test "polar em texto do XFLR5: o Reynolds, as colunas e a ordem em α" {
    const text =
        \\XFLR5 v6.47
        \\ Calculated polar for: NACA 4412
        \\ Mach =   0.000     Re =     0.200 e 6     Ncrit =   9.000
        \\
        \\  alpha     CL        CD       CDp       Cm    Top Xtr Bot Xtr
        \\ ------- -------- --------- --------- -------- ------- -------
        \\   2.000   0.6900   0.01020   0.00410  -0.1020  0.6200  1.0000
        \\  -2.000   0.2500   0.00980   0.00350  -0.1050  0.8100  0.4000
        \\   0.000   0.4700   0.00950   0.00330  -0.1040  0.7200  1.0000
    ;
    var polar: Polar = .{};
    const found = try parsePolar(text, &polar);
    try std.testing.expectApproxEqAbs(@as(f64, 2e5), found, 1e-6);
    try std.testing.expectEqual(@as(usize, 3), polar.count);
    try std.testing.expectEqual(@as(f64, -2), polar.alpha[0]);
    try std.testing.expectEqual(@as(f64, 0.25), polar.cl[0]);
    try std.testing.expectEqual(@as(f64, 0.0102), polar.cd[2]);
    try std.testing.expectEqual(@as(f64, -0.104), polar.cm[1]);
    try std.testing.expectError(error.NoTable, parsePolar("sem tabela aqui", &polar));
}

test "polar entre dois Reynolds: linear em Re, e a mais próxima fora da faixa" {
    var family: [2]Polar = .{ .{}, .{} };
    for (&family, [2]f64{ 1.0, 1.4 }) |*polar, lift| {
        polar.count = 2;
        polar.alpha[0..2].* = .{ 0, 10 };
        polar.cl[0..2].* = .{ 0, lift };
        polar.cd[0..2].* = .{ 0.02, 0.02 };
        polar.cm[0..2].* = .{ 0, 0 };
    }
    var out: Polar = .{};
    try std.testing.expect(!atReynolds(&.{ 1e5, 3e5 }, &family, 2e5, &.{ 5, 10 }, &out));
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), out.cl[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), out.cl[1], 1e-12);
    try std.testing.expect(atReynolds(&.{ 1e5, 3e5 }, &family, 5e5, &.{10}, &out));
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), out.cl[0], 1e-12);
}

//! A etapa Asa do dimensionamento: do perfil escolhido à asa trapezoidal, pela linha sustentadora de Prandtl
//! (série de Glauert, simétrica), como `aerosim/design/wing.py: analyze`.
//!
//!   Σ A_n sen(nθ) (sen θ + n μ) = μ (α + ε(y) − α_L0) sen θ,   μ = a1 c / (4 b)
//!   C_L = π AR A_1      C_Di = π AR Σ n A_n²      c_l(y) = (4 b / c) Σ A_n sen(nθ)
//!
//! (a solução geral de Glauert para a linha sustentadora de Prandtl: Anderson, Fundamentals of Aerodynamics, seção
//! 5.3; número da equação a conferir no PDF). Como o sistema é
//! linear em α, ele se resolve duas vezes (a parte em α e a parte da torção) e c_l(y) = α g(y) + h(y). O C_L,max
//! sai da seção crítica: o primeiro ponto da envergadura que chega ao c_l,max do perfil diz também onde o estol
//! começa. O arrasto de perfil integra o c_d da polar 2D no c_l local. Com perfil na ponta, do fim do trecho
//! retangular até a ponta os números do perfil (a1, α_L0, c_l,max, c_m e o c_d) são interpolados.
const std = @import("std");
const linalg = @import("../math/linalg.zig");
const section = @import("../physics/section.zig");

/// estações da linha sustentadora (o `n` de `lifting_line`)
pub const stations = 24;
/// o máximo de ângulos na curva da asa
pub const max_alphas = 256;
const g0 = 9.80665;
const air_viscosity = 1.81e-5; // Pa s, o MU_AIR da GUI

/// a asa trapezoidal como se decide no dimensionamento (o `WingParams` da GUI, planta "trapézio")
pub const Trapezoid = struct {
    span: f64 = 2.4, // m, de ponta a ponta
    area: f64 = 0.85, // m²
    root_chord: f64 = 0.35, // m (vale com `size_by_chord`)
    size_by_chord: bool = false, // falso: a corda sai da área
    taper: f64 = 0.6, // corda da ponta / corda da raiz
    rect_fraction: f64 = 0.4, // fração da semienvergadura com corda constante
    sweep: f64 = 0, // graus, da linha de 1/4 da corda no trecho trapezoidal
    twist: f64 = -1, // graus, na ponta
    alpha_cruise: f64 = 0, // graus, da fuselagem no cruzeiro
};

/// o perfil de uma seção já ajustado na polar, e o ramo colado da polar para o c_d
pub const SectionAirfoil = struct {
    numbers: section.Airfoil,
    drag: section.DragBranch,
};

/// as condições de projeto (o `Requirements` da GUI) e a massa por área da asa (das regras)
pub const Conditions = struct {
    mass: f64 = 10, // kg
    airspeed: f64 = 15, // m/s, cruzeiro
    density: f64 = 1.225, // kg/m³
    wing_density: f64 = 1.1, // kg/m²
};

/// densidade da atmosfera padrão na altitude-densidade `altitude` (m): ρ0 (1 − 2,25577·10⁻⁵ h)^4,25588, a
/// `isa_density` da GUI
pub fn isaDensity(altitude: f64) f64 {
    const height = std.math.clamp(altitude, -2000, 11000);
    return 1.225 * std.math.pow(f64, 1.0 - 2.25577e-5 * height, 4.25588);
}

/// o número de Reynolds de uma corda nas condições de projeto
pub fn reynolds(conditions: Conditions, chord: f64) f64 {
    return conditions.density * conditions.airspeed * chord / air_viscosity;
}

/// uma seção da asa (da raiz para a ponta)
const Station = struct { y: f64, chord: f64, offset: f64, twist: f64, tip: f64 };

/// a planta: semienvergadura, cordas e as seções (raiz, quebra se houver, ponta)
pub const Planform = struct {
    semispan: f64,
    break_y: f64,
    root_chord: f64,
    tip_chord: f64,
    sections: [3]Station = undefined,
    count: usize = 0,

    /// a grandeza `field` interpolada em y (entre seções vizinhas; fora delas, a da ponta)
    fn at(planform: *const Planform, y: f64, comptime field: []const u8) f64 {
        const list = planform.sections[0..planform.count];
        if (y <= list[0].y) return @field(list[0], field);
        for (1..list.len) |k| {
            if (y <= list[k].y) {
                const span = list[k].y - list[k - 1].y;
                const t = if (span > 0) (y - list[k - 1].y) / span else 1;
                return @field(list[k - 1], field) + t * (@field(list[k], field) - @field(list[k - 1], field));
            }
        }
        return @field(list[list.len - 1], field);
    }

    /// a corda em y (m)
    pub fn chordAt(planform: *const Planform, y: f64) f64 {
        return planform.at(y, "chord");
    }

    /// a área das duas semiasas (m²)
    pub fn area(planform: *const Planform) f64 {
        var half: f64 = 0;
        for (1..planform.count) |k| half += 0.5 * (planform.sections[k - 1].chord + planform.sections[k].chord) * (planform.sections[k].y - planform.sections[k - 1].y);
        return 2 * half;
    }

    /// a corda média aerodinâmica (m), pela integral de c² em 201 pontos como a GUI
    pub fn meanChord(planform: *const Planform) f64 {
        var half: f64 = 0;
        var square: f64 = 0;
        const step = planform.semispan / 200.0;
        var previous = planform.chordAt(0);
        for (1..201) |i| {
            const chord = planform.chordAt(step * @as(f64, @floatFromInt(i)));
            half += 0.5 * step * (previous + chord);
            square += 0.5 * step * (previous * previous + chord * chord);
            previous = chord;
        }
        return square / half;
    }

    /// o enflechamento da linha de 1/4 da corda no último trecho (rad)
    fn quarterChordSweep(planform: *const Planform) f64 {
        const tip = planform.sections[planform.count - 1];
        const inner = planform.sections[if (planform.count > 1) planform.count - 2 else 0];
        const dy = tip.y - inner.y;
        if (dy <= 0) return 0;
        return std.math.atan(((tip.offset + 0.25 * tip.chord) - (inner.offset + 0.25 * inner.chord)) / dy);
    }
};

/// a planta do trapézio (`chords` e `build_wing` da GUI); `with_tip`: a seção da ponta leva o perfil da ponta
pub fn planformOf(trapezoid: Trapezoid, with_tip: bool) Planform {
    const semispan = trapezoid.span / 2;
    const break_y = std.math.clamp(trapezoid.rect_fraction, 0, 1) * semispan;
    const ratio = if (break_y >= semispan) 1.0 else trapezoid.taper;
    const root = if (trapezoid.size_by_chord) trapezoid.root_chord else trapezoid.area / (2 * (break_y + 0.5 * (1 + ratio) * (semispan - break_y)));
    const tip = root * ratio;
    var out: Planform = .{ .semispan = semispan, .break_y = break_y, .root_chord = root, .tip_chord = tip };
    out.sections[0] = .{ .y = 0, .chord = root, .offset = 0, .twist = 0, .tip = 0 };
    out.count = 1;
    if (1e-6 < break_y and break_y < semispan - 1e-6) {
        out.sections[1] = .{ .y = break_y, .chord = root, .offset = 0, .twist = trapezoid.twist * break_y / semispan, .tip = 0 };
        out.count = 2;
    }
    const tip_offset = (root - tip) / 4 + @tan(std.math.degreesToRadians(trapezoid.sweep)) * (semispan - break_y);
    out.sections[out.count] = .{ .y = semispan, .chord = tip, .offset = tip_offset, .twist = trapezoid.twist, .tip = if (with_tip) 1 else 0 };
    out.count += 1;
    return out;
}

/// o que a etapa Asa mostra
pub const Result = struct {
    reynolds: f64 = 0, // na corda média
    mean_chord: f64 = 0,
    root_chord: f64 = 0,
    tip_chord: f64 = 0,
    area: f64 = 0,
    span: f64 = 0,
    aspect_ratio: f64 = 0,
    lift_slope: f64 = 0, // C_Lα (1/rad)
    lift_zero: f64 = 0, // C_L0
    alpha_zero: f64 = 0, // graus
    lift_max: f64 = 0,
    alpha_stall: f64 = 0, // graus
    stall_fraction: f64 = 0, // 2y/b onde o estol começa
    oswald: f64 = 0, // no cruzeiro
    ld_max: f64 = 0,
    lift_at_ld: f64 = 0,
    lift_cruise: f64 = 0,
    alpha_cruise: f64 = 0, // graus, da asa
    drag_cruise: f64 = 0,
    ld_cruise: f64 = 0,
    stall_speed: f64 = 0,
    incidence: f64 = 0, // graus
    wing_loading: f64 = 0, // kg/m²
    wing_mass: f64 = 0, // kg
    moment: f64 = 0, // C_m,ac
    reynolds_root: f64 = 0,
    reynolds_tip: f64 = 0,
    // curvas
    alpha_count: usize = 0,
    alpha: [max_alphas]f64 = undefined, // graus
    lift: [max_alphas]f64 = undefined,
    induced: [max_alphas]f64 = undefined,
    profile: [max_alphas]f64 = undefined,
    drag: [max_alphas]f64 = undefined,
    ld: [max_alphas]f64 = undefined,
    // ao longo da envergadura (da raiz para a ponta)
    span_fraction: [stations]f64 = undefined,
    cl_cruise: [stations]f64 = undefined,
    cl_stall: [stations]f64 = undefined,
    cl_max_local: [stations]f64 = undefined,
    chord: [stations]f64 = undefined,
};

/// a linha sustentadora: a parte em α e a da torção, c_l(y) = α g + h, e os números locais do perfil
const Line = struct {
    y: [stations]f64,
    chord: [stations]f64,
    slope_part: [stations]f64, // A_α
    twist_part: [stations]f64, // A_t
    lift_rate: [stations]f64, // g
    lift_base: [stations]f64, // h
    cl_max: [stations]f64,
    moment: [stations]f64,
    tip_weight: [stations]f64,
    aspect_ratio: f64,
    area: f64,
    span: f64,
};

fn odd(j: usize) f64 {
    return @floatFromInt(2 * j + 1);
}

/// a linha sustentadora de Glauert na planta `planform` (estações da ponta para a raiz)
fn liftingLine(planform: *const Planform, root: section.Airfoil, tip: section.Airfoil) Line {
    var line: Line = undefined;
    const semispan = planform.semispan;
    line.span = 2 * semispan;
    line.area = planform.area();
    line.aspect_ratio = line.span * line.span / line.area;
    const sweep_cos = @cos(planform.quarterChordSweep());
    var matrix: [stations][stations]f64 = undefined;
    var rhs_slope: [stations]f64 = undefined;
    var rhs_twist: [stations]f64 = undefined;
    var theta: [stations]f64 = undefined;
    for (0..stations) |i| {
        theta[i] = @as(f64, @floatFromInt(i + 1)) * std.math.pi / (2 * @as(f64, stations));
        const y = semispan * @cos(theta[i]);
        const weight = planform.at(y, "tip");
        const slope = (root.cl_alpha + weight * (tip.cl_alpha - root.cl_alpha)) * sweep_cos;
        const zero_lift = std.math.degreesToRadians(root.alpha0 + weight * (tip.alpha0 - root.alpha0));
        line.y[i] = y;
        line.chord[i] = planform.chordAt(y);
        line.tip_weight[i] = weight;
        line.cl_max[i] = root.cl_max + weight * (tip.cl_max - root.cl_max);
        line.moment[i] = root.cm_ac + weight * (tip.cm_ac - root.cm_ac);
        const twist = std.math.degreesToRadians(planform.at(y, "twist"));
        const mu = slope * line.chord[i] / (4 * line.span);
        for (0..stations) |j| matrix[i][j] = @sin(theta[i] * odd(j)) * (@sin(theta[i]) + odd(j) * mu);
        rhs_slope[i] = mu * @sin(theta[i]);
        rhs_twist[i] = mu * (twist - zero_lift) * @sin(theta[i]);
    }
    _ = linalg.solve(stations, matrix, stations, rhs_slope, &line.slope_part);
    _ = linalg.solve(stations, matrix, stations, rhs_twist, &line.twist_part);
    for (0..stations) |i| {
        var rate: f64 = 0;
        var base: f64 = 0;
        for (0..stations) |j| {
            rate += @sin(theta[i] * odd(j)) * line.slope_part[j];
            base += @sin(theta[i] * odd(j)) * line.twist_part[j];
        }
        line.lift_rate[i] = 4 * line.span / line.chord[i] * rate;
        line.lift_base[i] = 4 * line.span / line.chord[i] * base;
    }
    return line;
}

/// C_Di/(π AR) num ângulo: Σ n A_n²
fn inducedSum(line: *const Line, alpha: f64) f64 {
    var sum: f64 = 0;
    for (0..stations) |j| {
        const coefficient = alpha * line.slope_part[j] + line.twist_part[j];
        sum += odd(j) * coefficient * coefficient;
    }
    return sum;
}

/// C_Dp = (2/S) ∫ c c_d(c_l local) dy, da raiz à ponta (a ponta com o c_d da última estação)
fn profileDrag(planform: *const Planform, line: *const Line, alpha: f64, root: *const section.DragBranch, tip: ?*const section.DragBranch) f64 {
    var integral: f64 = 0;
    var previous_y: f64 = 0;
    var previous_value: f64 = 0;
    var last_cd: f64 = 0;
    var i: usize = stations;
    var first = true;
    while (i > 0) {
        i -= 1;
        const cl = alpha * line.lift_rate[i] + line.lift_base[i];
        var cd = root.at(cl);
        if (tip) |branch| cd += (branch.at(cl) - cd) * line.tip_weight[i];
        const value = line.chord[i] * cd;
        if (!first) integral += 0.5 * (line.y[i] - previous_y) * (value + previous_value);
        first = false;
        previous_y = line.y[i];
        previous_value = value;
        last_cd = cd;
    }
    const tip_value = planform.chordAt(planform.semispan) * last_cd;
    integral += 0.5 * (planform.semispan - previous_y) * (tip_value + previous_value);
    return 2 * integral / line.area;
}

/// tudo o que a etapa Asa mostra: curvas, estol (quanto e onde), polar, L/D, cruzeiro e massa
pub fn analyze(trapezoid: Trapezoid, root: *const SectionAirfoil, tip: ?*const SectionAirfoil, conditions: Conditions, out: *Result) void {
    const planform = planformOf(trapezoid, tip != null);
    const tip_numbers = if (tip) |t| t.numbers else root.numbers;
    const line = liftingLine(&planform, root.numbers, tip_numbers);
    const tip_drag = if (tip) |t| &t.drag else null;
    const aspect = line.aspect_ratio;
    // a seção crítica: o menor α em que alguma estação chega ao c_l,max dela
    var critical: usize = 0;
    var stall = std.math.inf(f64);
    for (0..stations) |i| {
        const angle = if (line.lift_rate[i] > 0) (line.cl_max[i] - line.lift_base[i]) / line.lift_rate[i] else std.math.inf(f64);
        if (angle < stall) {
            stall = angle;
            critical = i;
        }
    }
    out.mean_chord = planform.meanChord();
    out.reynolds = reynolds(conditions, out.mean_chord);
    out.root_chord = planform.root_chord;
    out.tip_chord = planform.tip_chord;
    out.area = line.area;
    out.span = line.span;
    out.aspect_ratio = aspect;
    out.lift_slope = std.math.pi * aspect * line.slope_part[0];
    out.lift_zero = std.math.pi * aspect * line.twist_part[0];
    const alpha_zero = -out.lift_zero / out.lift_slope;
    out.alpha_zero = std.math.radiansToDegrees(alpha_zero);
    out.lift_max = std.math.pi * aspect * (stall * line.slope_part[0] + line.twist_part[0]);
    out.alpha_stall = std.math.radiansToDegrees(stall);
    out.stall_fraction = line.y[critical] / planform.semispan;
    // a curva: de α_L0 − 2° (para baixo, inteiro) até o estol, de 0,25° em 0,25° (np.arange), e o próprio estol
    const start = @floor(out.alpha_zero) - 2;
    const stop = out.alpha_stall + 1e-9;
    const steps: usize = @intFromFloat(@max(0, @ceil((stop - start) / 0.25)));
    out.alpha_count = 0;
    for (0..@min(steps, max_alphas - 1)) |k| {
        out.alpha[out.alpha_count] = start + 0.25 * @as(f64, @floatFromInt(k));
        out.alpha_count += 1;
    }
    if (out.alpha_count == 0 or out.alpha[out.alpha_count - 1] < out.alpha_stall - 1e-9) {
        out.alpha[out.alpha_count] = out.alpha_stall;
        out.alpha_count += 1;
    }
    var best: usize = 0;
    out.ld_max = -std.math.inf(f64);
    for (0..out.alpha_count) |k| {
        const angle = std.math.degreesToRadians(out.alpha[k]);
        out.lift[k] = std.math.pi * aspect * (angle * line.slope_part[0] + line.twist_part[0]);
        out.induced[k] = std.math.pi * aspect * inducedSum(&line, angle);
        out.profile[k] = profileDrag(&planform, &line, angle, &root.drag, tip_drag);
        out.drag[k] = out.induced[k] + out.profile[k];
        out.ld[k] = if (out.drag[k] > 0) out.lift[k] / out.drag[k] else std.math.nan(f64);
        if (out.ld[k] > out.ld_max) {
            out.ld_max = out.ld[k];
            best = k;
        }
    }
    out.lift_at_ld = out.lift[best];
    // cruzeiro: o C_L que sustenta a massa na velocidade de cruzeiro
    const dynamic_pressure = 0.5 * conditions.density * conditions.airspeed * conditions.airspeed;
    out.lift_cruise = conditions.mass * g0 / (dynamic_pressure * line.area);
    const alpha_cruise = (out.lift_cruise - out.lift_zero) / out.lift_slope;
    out.alpha_cruise = std.math.radiansToDegrees(alpha_cruise);
    const first_cruise = alpha_cruise * line.slope_part[0] + line.twist_part[0];
    const cruise_sum = inducedSum(&line, alpha_cruise);
    out.oswald = if (@abs(first_cruise) > 1e-12) first_cruise * first_cruise / cruise_sum else std.math.nan(f64);
    out.drag_cruise = std.math.pi * aspect * cruise_sum + profileDrag(&planform, &line, alpha_cruise, &root.drag, tip_drag);
    out.ld_cruise = if (out.drag_cruise > 0) out.lift_cruise / out.drag_cruise else std.math.nan(f64);
    out.stall_speed = if (out.lift_max > 0) @sqrt(2 * conditions.mass * g0 / (conditions.density * line.area * out.lift_max)) else std.math.nan(f64);
    out.incidence = out.alpha_cruise - trapezoid.alpha_cruise;
    out.wing_loading = conditions.mass / line.area;
    out.wing_mass = line.area * conditions.wing_density;
    out.reynolds_root = reynolds(conditions, planform.chordAt(0));
    out.reynolds_tip = reynolds(conditions, planform.chordAt(planform.semispan));
    // ao longo da envergadura, da raiz para a ponta
    for (0..stations) |k| {
        const i = stations - 1 - k;
        out.span_fraction[k] = line.y[i] / planform.semispan;
        out.cl_cruise[k] = alpha_cruise * line.lift_rate[i] + line.lift_base[i];
        out.cl_stall[k] = stall * line.lift_rate[i] + line.lift_base[i];
        out.cl_max_local[k] = line.cl_max[i];
        out.chord[k] = line.chord[i];
    }
    // C_m,ac: um perfil só, o dele; dois perfis, a média em c² ao longo da envergadura
    if (tip == null) {
        out.moment = root.numbers.cm_ac;
    } else {
        var weighted: f64 = 0;
        var total: f64 = 0;
        for (1..stations) |k| {
            const i = stations - 1 - k;
            const step = out.span_fraction[k] - out.span_fraction[k - 1];
            const a = line.chord[i + 1] * line.chord[i + 1];
            const b = line.chord[i] * line.chord[i];
            weighted += 0.5 * step * (line.moment[i + 1] * a + line.moment[i] * b);
            total += 0.5 * step * (a + b);
        }
        out.moment = weighted / total;
    }
}

/// o perfil ajustado na polar do modelo e o ramo do c_d, de um perfil com os números dados
pub fn modelSection(numbers: section.Airfoil, symmetric: bool) SectionAirfoil {
    var alphas: [73]f64 = undefined;
    for (&alphas, 0..) |*alpha, i| alpha.* = -16 + 0.5 * @as(f64, @floatFromInt(i));
    var polar: section.Polar = .{};
    section.modelPolar(numbers, &alphas, &polar);
    return .{ .numbers = section.fitted(numbers, section.metrics(&polar), symmetric), .drag = section.dragBranch(&polar) };
}

test "asa trapezoidal: os números da etapa Asa da GUI em Python" {
    // referência: wing.analyze(WingCandidate(WingParams(), AirfoilEntry(Airfoil(), "modelo")), Requirements(),
    // DesignRules()); o NACA 2412 padrão tem α_L0 e c_m da linha média (−2,114661°, −0,052817)
    const root = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -2.114661308661674, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.05281661064824909 }, false);
    const conditions: Conditions = .{ .density = isaDensity(600) };
    var result: Result = .{};
    analyze(.{}, &root, null, conditions, &result);
    const expected = [_][2]f64{
        .{ 347000.387654, result.reynolds },  .{ 4.556875, result.lift_slope },  .{ 0.133356, result.lift_zero },
        .{ -1.676747, result.alpha_zero },    .{ 1.297586, result.lift_max },    .{ 14.638423, result.alpha_stall },
        .{ 0.988337, result.oswald },         .{ 20.967098, result.ld_max },     .{ 0.511135, result.lift_at_ld },
        .{ 0.887156, result.lift_cruise },    .{ 9.477894, result.alpha_cruise }, .{ 0.049412, result.drag_cruise },
        .{ 17.95426, result.ld_cruise },      .{ 12.4029, result.stall_speed },  .{ 0.935, result.wing_mass },
        .{ 6.776471, result.aspect_ratio },   .{ 0.362216, result.mean_chord },  .{ -0.052817, result.moment },
        .{ 231333.267228, result.reynolds_tip },
    };
    for (expected) |pair| try std.testing.expectApproxEqRel(pair[0], pair[1], 2e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.stall_fraction, 1e-12);
    try std.testing.expectEqual(@as(usize, 76), result.alpha_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.011997), result.profile[0], 2e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.093638), result.drag[result.alpha_count - 1], 2e-6);
}

test "asa com perfil na ponta, enflechada e dimensionada pela corda: igual à GUI em Python" {
    // referência: WingParams(sweep=10, twist=-2, size_by="corda", chord=0.4), raiz NACA 2412 e ponta
    // from_dat("data/airfoils/s1223.dat") (α_L0 e c_m da linha média: −14,341063°, −0,394150), os dois "modelo"
    const root = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -2.114661308661674, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.05281661064824909 }, false);
    const tip = modelSection(.{ .cl_alpha = 5.9, .alpha0 = -14.341063304048808, .cl_max = 1.4, .cd0 = 0.012, .cm_ac = -0.39415016947412235 }, false);
    var result: Result = .{};
    analyze(.{ .sweep = 10, .twist = -2, .size_by_chord = true, .root_chord = 0.4 }, &root, &tip, .{ .density = isaDensity(600) }, &result);
    const expected = [_][2]f64{
        .{ 344877.561753, result.reynolds },  .{ 5.474257, result.lift_slope },  .{ 0.196327, result.lift_zero },
        .{ -2.054841, result.alpha_zero },    .{ 1.121016, result.lift_max },    .{ 9.67817, result.alpha_stall },
        .{ 0.793353, result.stall_fraction }, .{ 0.85064, result.oswald },       .{ 18.6105, result.ld_max },
        .{ 0.506845, result.lift_at_ld },     .{ 0.892617, result.lift_cruise }, .{ 7.287648, result.alpha_cruise },
        .{ 0.055879, result.drag_cruise },    .{ 15.974163, result.ld_cruise },  .{ 13.384983, result.stall_speed },
        .{ 0.92928, result.wing_mass },       .{ 6.818182, result.aspect_ratio }, .{ 0.360001, result.mean_chord },
        .{ -0.123373, result.moment },        .{ 229918.051946, result.reynolds_tip },
    };
    for (expected) |pair| try std.testing.expectApproxEqRel(pair[0], pair[1], 2e-5);
    try std.testing.expectEqual(@as(usize, 60), result.alpha_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.034208), result.profile[0], 2e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.080624), result.drag[result.alpha_count - 1], 2e-6);
}

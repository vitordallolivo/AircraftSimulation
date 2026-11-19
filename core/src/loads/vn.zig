//! Diagrama V-n: o envelope de manobra e o de rajada, e os casos de carga que saem dele.
//!
//! Manobra: em cada V, o fator de carga que a asa consegue é n = q C_L,max/(W/S), limitado pelo n_max da norma. Ele bate
//! no n_max na velocidade de manobra:
//!
//!     V_S = √(2 (W/S)/(ρ C_L,max)),    V_A = V_S √n_max
//!
//! Rajada de Pratt, com o fator de alívio da rajada (FAR 23.341; a conferir no PDF):
//!
//!     μ_g = 2 (W/S)/(ρ c̄ C_Lα g),    K_g = 0,88 μ_g/(5,3 + μ_g),    Δn = ρ K_g U V C_Lα/(2 W/S)
//!
//! O n_max, o n_min, as rajadas U_c e U_d, as velocidades V_C e V_D e o fator de segurança vêm sempre do usuário (a
//! norma ou o regulamento que ele escolhe). O núcleo não tem valor padrão.
const std = @import("std");

const gravity = 9.80665;

/// o que a norma escolhida pelo usuário pede: fatores de carga, velocidades de projeto (m/s), rajadas (m/s) e o fator de
/// segurança que multiplica os casos (carga limite → carga última)
pub const VnNorm = extern struct {
    n_max: f64 = 0,
    n_min: f64 = 0,
    cruise_speed: f64 = 0, // V_C
    dive_speed: f64 = 0, // V_D
    cruise_gust: f64 = 0, // U_c em V_C
    dive_gust: f64 = 0, // U_d em V_D
    safety_factor: f64 = 1,
};

/// o avião: carga alar (N/m²), C_L máximo e mínimo (negativo), C_Lα (/rad), corda média (m) e a densidade do ar (kg/m³)
pub const VnAircraft = extern struct {
    wing_loading: f64 = 0,
    lift_max: f64 = 0,
    lift_min: f64 = 0,
    lift_slope: f64 = 0,
    mean_chord: f64 = 0,
    density: f64 = 0,
};

/// um caso de carga: velocidade (m/s) e o fator de carga limite; `ultimate` já com o fator de segurança
pub const LoadCase = extern struct {
    speed: f64 = 0,
    load_factor: f64 = 0,
    ultimate: f64 = 0,
    kind: CaseKind = .maneuver,
    _pad: i32 = 0,
};

/// de onde o caso veio
pub const CaseKind = enum(i32) { maneuver, gust };

pub const max_cases = 8;

/// as velocidades de referência, o fator de alívio e os casos de carga do envelope
pub const VnResult = extern struct {
    stall_speed: f64 = 0, // V_S, com C_L,max
    stall_speed_negative: f64 = 0, // com C_L,min (0 se não houver C_L,min)
    maneuver_speed: f64 = 0, // V_A
    gust_alleviation: f64 = 0, // K_g
    mass_ratio: f64 = 0, // μ_g
    cruise_gust_increment: f64 = 0, // Δn em V_C
    dive_gust_increment: f64 = 0, // Δn em V_D
    case_count: i32 = 0,
    _pad: i32 = 0,
    cases: [max_cases]LoadCase = [_]LoadCase{.{}} ** max_cases,
};

pub const Error = error{ NoNorm, NoAircraft };

/// V em que q C_L = n W/S, com `lift` > 0
fn speedFor(aircraft: VnAircraft, lift: f64, load_factor: f64) f64 {
    return @sqrt(2 * aircraft.wing_loading * load_factor / (aircraft.density * lift));
}

/// μ_g e K_g de Pratt
pub fn gustAlleviation(aircraft: VnAircraft) struct { mass_ratio: f64, factor: f64 } {
    const mass_ratio = 2 * aircraft.wing_loading / (aircraft.density * aircraft.mean_chord * aircraft.lift_slope * gravity);
    return .{ .mass_ratio = mass_ratio, .factor = 0.88 * mass_ratio / (5.3 + mass_ratio) };
}

/// Δn da rajada `gust` (m/s) em `speed` (m/s)
pub fn gustIncrement(aircraft: VnAircraft, gust: f64, speed: f64) f64 {
    const alleviation = gustAlleviation(aircraft).factor;
    return aircraft.density * alleviation * gust * speed * aircraft.lift_slope / (2 * aircraft.wing_loading);
}

/// o maior e o menor fator de carga da manobra em `speed`: q C_L limitado por n_max e n_min
pub fn maneuverLimits(norm: VnNorm, aircraft: VnAircraft, speed: f64) struct { upper: f64, lower: f64 } {
    const ratio = 0.5 * aircraft.density * speed * speed / aircraft.wing_loading;
    return .{ .upper = @min(ratio * aircraft.lift_max, norm.n_max), .lower = @max(ratio * aircraft.lift_min, norm.n_min) };
}

/// o envelope em cada `speeds[i]`: o maior e o menor n entre a manobra e a rajada (a linha da rajada cresce de 1 em
/// V = 0 até V_C com U_c, e daí vai reta até V_D com U_d)
pub fn envelope(norm: VnNorm, aircraft: VnAircraft, speeds: []const f64, upper: []f64, lower: []f64) void {
    const cruise_increment = gustIncrement(aircraft, norm.cruise_gust, norm.cruise_speed);
    const dive_increment = gustIncrement(aircraft, norm.dive_gust, norm.dive_speed);
    for (speeds, upper[0..speeds.len], lower[0..speeds.len]) |speed, *high, *low| {
        const maneuver = maneuverLimits(norm, aircraft, speed);
        const gust = if (speed <= norm.cruise_speed or norm.dive_speed <= norm.cruise_speed)
            gustIncrement(aircraft, norm.cruise_gust, speed)
        else
            cruise_increment + (dive_increment - cruise_increment) * (speed - norm.cruise_speed) / (norm.dive_speed - norm.cruise_speed);
        high.* = @max(maneuver.upper, 1 + gust);
        low.* = @min(maneuver.lower, 1 - gust);
    }
}

/// as velocidades de referência e os casos de carga: manobra em V_A e V_D (positiva e negativa), rajada em V_C e V_D
/// (para cima e para baixo)
pub fn diagram(norm: VnNorm, aircraft: VnAircraft) Error!VnResult {
    if (!(norm.n_max > 0) or !(norm.cruise_speed > 0) or !(norm.dive_speed >= norm.cruise_speed)) return error.NoNorm;
    if (!(aircraft.wing_loading > 0) or !(aircraft.lift_max > 0) or !(aircraft.density > 0) or !(aircraft.lift_slope > 0) or !(aircraft.mean_chord > 0)) return error.NoAircraft;
    const alleviation = gustAlleviation(aircraft);
    var result: VnResult = .{
        .stall_speed = speedFor(aircraft, aircraft.lift_max, 1),
        .stall_speed_negative = if (aircraft.lift_min < 0) speedFor(aircraft, -aircraft.lift_min, 1) else 0,
        .maneuver_speed = speedFor(aircraft, aircraft.lift_max, norm.n_max),
        .gust_alleviation = alleviation.factor,
        .mass_ratio = alleviation.mass_ratio,
        .cruise_gust_increment = gustIncrement(aircraft, norm.cruise_gust, norm.cruise_speed),
        .dive_gust_increment = gustIncrement(aircraft, norm.dive_gust, norm.dive_speed),
    };
    const candidates = [_]LoadCase{
        .{ .speed = result.maneuver_speed, .load_factor = norm.n_max, .kind = .maneuver },
        .{ .speed = norm.dive_speed, .load_factor = norm.n_max, .kind = .maneuver },
        .{ .speed = norm.cruise_speed, .load_factor = maneuverLimits(norm, aircraft, norm.cruise_speed).lower, .kind = .maneuver },
        .{ .speed = norm.dive_speed, .load_factor = norm.n_min, .kind = .maneuver },
        .{ .speed = norm.cruise_speed, .load_factor = 1 + result.cruise_gust_increment, .kind = .gust },
        .{ .speed = norm.cruise_speed, .load_factor = 1 - result.cruise_gust_increment, .kind = .gust },
        .{ .speed = norm.dive_speed, .load_factor = 1 + result.dive_gust_increment, .kind = .gust },
        .{ .speed = norm.dive_speed, .load_factor = 1 - result.dive_gust_increment, .kind = .gust },
    };
    for (candidates) |candidate| {
        if (candidate.kind == .gust and candidate.load_factor == 1) continue; // sem rajada pedida
        var case = candidate;
        case.ultimate = case.load_factor * norm.safety_factor;
        result.cases[@intCast(result.case_count)] = case;
        result.case_count += 1;
    }
    return result;
}


// ------------------------------------------------------------------ testes
const testing = std.testing;
const plot = @import("../util/plot.zig");

/// um avião de AeroDesign (W/S = 60 N/m², C_L,max = 1,8, C_L,min = −0,8, C_Lα = 4,8, c̄ = 0,4 m, ρ = 1,1) e uma norma de
/// teste (n de 2,5 a −1, V_C = 15 com 5 m/s, V_D = 20 com 2,5 m/s, segurança 1,5): números só para conferir a conta
const test_aircraft: VnAircraft = .{ .wing_loading = 60, .lift_max = 1.8, .lift_min = -0.8, .lift_slope = 4.8, .mean_chord = 0.4, .density = 1.1 };
const test_norm: VnNorm = .{ .n_max = 2.5, .n_min = -1, .cruise_speed = 15, .dive_speed = 20, .cruise_gust = 5, .dive_gust = 2.5, .safety_factor = 1.5 };

test "V-n: velocidades de referência e rajada de Pratt contra a conta à mão" {
    const found = try diagram(test_norm, test_aircraft);
    // V_S = √(2·60/(1,1·1,8)) = 7,785 m/s; V_A = V_S √2,5 = 12,309 m/s
    try testing.expectApproxEqRel(@as(f64, 7.7850), found.stall_speed, 1e-4);
    try testing.expectApproxEqRel(@as(f64, 12.3091), found.maneuver_speed, 1e-4);
    // μ_g = 2·60/(1,1·0,4·4,8·9,80665) = 5,7938; K_g = 0,88 μ/(5,3 + μ) = 0,45959
    try testing.expectApproxEqRel(@as(f64, 5.7938), found.mass_ratio, 1e-4);
    try testing.expectApproxEqRel(@as(f64, 0.45959), found.gust_alleviation, 1e-4);
    // Δn = ρ K_g U V C_Lα/(2 W/S): 1,5166 em V_C e 1,0111 em V_D
    try testing.expectApproxEqRel(@as(f64, 1.5166), found.cruise_gust_increment, 1e-4);
    try testing.expectApproxEqRel(@as(f64, 1.0111), found.dive_gust_increment, 1e-4);
    // 4 casos de manobra e 4 de rajada, cada um com o fator de segurança
    try testing.expectEqual(@as(i32, 8), found.case_count);
    for (found.cases[0..8]) |case| try testing.expectApproxEqRel(1.5 * case.load_factor, case.ultimate, 1e-12);
    // em V_C a manobra negativa é o n_min (q C_L,min = −2,48 passa do −1)
    try testing.expectApproxEqRel(@as(f64, -1), found.cases[2].load_factor, 1e-12);
}

test "V-n: sem norma ou sem avião a conta é recusada" {
    try testing.expectError(error.NoNorm, diagram(.{}, test_aircraft));
    try testing.expectError(error.NoAircraft, diagram(test_norm, .{}));
}

test "V-n: o envelope segue q C_L até o n_max e a rajada passa por cima em V_C" {
    var speeds: [81]f64 = undefined;
    var upper: [81]f64 = undefined;
    var lower: [81]f64 = undefined;
    for (&speeds, 0..) |*speed, i| speed.* = 0.25 * @as(f64, @floatFromInt(i));
    envelope(test_norm, test_aircraft, &speeds, &upper, &lower);
    // em 10 m/s: manobra q C_L/(W/S) = 0,5·1,1·100·1,8/60 = 1,65; rajada 1 + Δn(10) = 1 + 1,5166·10/15 = 2,011
    try testing.expectApproxEqRel(@as(f64, 1 + 1.5166 * 10.0 / 15.0), upper[40], 1e-4);
    // em V_D: max(n_max, 1 + 1,0111) = 2,5
    try testing.expectApproxEqRel(@as(f64, 2.5), upper[80], 1e-12);
    // e em baixo: min(n_min, 1 − 1,0111) = −1
    try testing.expectApproxEqRel(@as(f64, -1), lower[80], 1e-12);
    const found = try diagram(test_norm, test_aircraft);
    var case_speed: [max_cases]f64 = undefined;
    var case_factor: [max_cases]f64 = undefined;
    for (found.cases[0..8], 0..) |case, i| {
        case_speed[i] = case.speed;
        case_factor[i] = case.load_factor;
    }
    try plot.fromTest("vn_envelope", .{ .title = "Diagrama V-n", .x_label = "V (m/s)", .y_label = "n", .series = &.{
        .{ .label = "n máximo", .x = &speeds, .y = &upper },
        .{ .label = "n mínimo", .x = &speeds, .y = &lower },
        .{ .label = "casos de carga", .x = case_speed[0..8], .y = case_factor[0..8], .style = .points },
    } });
}

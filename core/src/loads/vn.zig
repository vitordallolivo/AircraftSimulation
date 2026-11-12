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


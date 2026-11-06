//! O diagrama de restrições do dimensionamento inicial (o par de `aerosim/sizing/constraints.py`): a razão
//! tração/peso T/W que cada requisito pede em função da carga alar W/S (N/m²) e os limites verticais de W/S (estol e
//! pouso). A região viável fica acima de todas as curvas e à esquerda dos limites; o ponto de projeto é o de menor T/W
//! dentro dela (o menor motor), e a faixa ótima é onde o T/W fica até `tol` acima desse mínimo.
//!
//! Equações: Gudmundsson, General Aviation Aircraft Design (2014), cap. 3; Raymer, Aircraft Design, cap. 5 e 12.
//! Polar parabólica C_D = C_D0 + k C_L², k = 1/(π AR e), q = ½ ρ V²:
//!   curva sustentada n a V:   T/W = q [C_D0/(W/S) + k (n/q)² (W/S)]
//!   razão de subida V_V a V:  T/W = V_V/V + q C_D0/(W/S) + k (W/S)/q
//!   gradiente de subida G:    T/W = G + q C_D0/(W/S) + k (W/S)/q
//!   cruzeiro e V máxima a V:  T/W = q C_D0/(W/S) + k (W/S)/q
//!   corrida de decolagem S_G: T/W = V_LOF²/(2 g S_G) + q C_D,TO/(W/S) + μ (1 − q C_L,TO/(W/S)), V_LOF = 1,1 V_S,
//!                             q a V_LOF/√2
//!   teto (V_V residual a ρ_h): como a subida, levado ao nível do mar por (ρ_h/ρ0)^m
//!   estol:                    W/S ≤ ½ ρ V_S² C_Lmax
//!   corrida de pouso S_L:     W/S ≤ ρ C_Lmax g μ_f S_L / 1,15² (toque a 1,15 V_S, sem arrasto na frenagem)
const std = @import("std");

pub const g0 = 9.80665;

/// a interpolação linear com as pontas presas (a mesma do `np.interp`)
pub const interp = @import("ground.zig").interp;

/// a polar parabólica e o que a corrida usa
pub const ParabolicPolar = struct {
    CD0: f64 = 0.03,
    k: f64 = 0.06, // 1/(π AR e)
    CLmax: f64 = 1.4,
    CL_TO: f64 = 0.5, // C_L na corrida
    CD_TO: f64 = 0.05, // C_D na corrida
    mu: f64 = 0.04, // atrito de rolamento
};

/// sem geometria: C_D0 = C_fe S_molhada/S (Raymer, eq. 12.23 e tab. 12.3) e o Oswald pela eq. 12.49 do Raymer quando
/// `oswald` é 0
pub fn estimatePolar(wetted_ratio: f64, skin_friction: f64, aspect_ratio: f64, oswald: f64, lift_max: f64, takeoff_lift: f64, takeoff_extra_drag: f64, rolling_friction: f64) ParabolicPolar {
    const efficiency = if (oswald > 0) oswald else 1.78 * (1 - 0.045 * std.math.pow(f64, aspect_ratio, 0.68)) - 0.64;
    const zero_drag = skin_friction * wetted_ratio;
    const induced = 1 / (std.math.pi * aspect_ratio * efficiency);
    return .{ .CD0 = zero_drag, .k = induced, .CLmax = lift_max, .CL_TO = takeoff_lift, .CD_TO = zero_drag + induced * takeoff_lift * takeoff_lift + takeoff_extra_drag, .mu = rolling_friction };
}

/// os requisitos; um 0 desliga o que é opcional
pub const Requirements = struct {
    rho: f64 = 1.225,
    V_stall: f64 = 11.0, // V_S máxima (m/s)
    S_G: f64 = 50.0, // corrida de decolagem máxima (m)
    S_L: f64 = 0.0, // corrida de pouso máxima (m); 0: não confere
    mu_brake: f64 = 0.3,
    V_cruise: f64 = 16.0,
    V_max: f64 = 0.0, // 0: não confere
    V_climb: f64 = 13.0,
    roc: f64 = 2.0, // razão de subida (m/s)
    climb_grad: f64 = 0.0, // gradiente de subida (%); 0: não confere
    n_turn: f64 = 2.0, // fator de carga em curva sustentada...
    V_turn: f64 = 14.0, // ...a esta velocidade
    h_ceiling: f64 = 0.0, // teto pedido (m); 0: não confere
    roc_ceiling: f64 = 0.5,
    thrust_rho_exp: f64 = 1.0, // T ∝ (ρ/ρ0)^m
};

/// as curvas de T/W, na ordem do diagrama
pub const Kind = enum {
    decolagem,
    subida,
    gradiente,
    cruzeiro,
    vmax,
    curva,
    teto,

    /// o rótulo no gráfico
    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .decolagem => "corrida de decolagem",
            .subida => "razão de subida",
            .gradiente => "gradiente de subida",
            .cruzeiro => "velocidade de cruzeiro",
            .vmax => "velocidade máxima",
            .curva => "curva sustentada",
            .teto => "teto",
        };
    }

    /// o requisito está ligado
    pub fn active(kind: Kind, requirements: Requirements) bool {
        return switch (kind) {
            .gradiente => requirements.climb_grad > 0,
            .vmax => requirements.V_max > 0,
            .teto => requirements.h_ceiling > 0,
            else => true,
        };
    }
};

/// os limites verticais de W/S
pub const Limit = enum {
    estol,
    pouso,

    /// o rótulo no gráfico
    pub fn label(limit: Limit) []const u8 {
        return switch (limit) {
            .estol => "velocidade de estol",
            .pouso => "corrida de pouso",
        };
    }
};

fn dynamicPressure(rho: f64, speed: f64) f64 {
    return 0.5 * rho * speed * speed;
}

/// a densidade da atmosfera padrão na altitude `height` (m)
pub fn isaRho(height: f64) f64 {
    return 1.225 * std.math.pow(f64, 1 - 2.25577e-5 * height, 4.2559);
}

/// a velocidade em que o requisito acontece (para a tração da hélice e para P/W)
pub fn conditionSpeed(kind: Kind, wing_loading: f64, requirements: Requirements, polar: ParabolicPolar) f64 {
    return switch (kind) {
        .decolagem => 1.1 * @sqrt(2 * wing_loading / (requirements.rho * polar.CLmax)) / @sqrt(2.0),
        .subida, .gradiente => requirements.V_climb,
        .cruzeiro => requirements.V_cruise,
        .vmax => requirements.V_max,
        .curva => requirements.V_turn,
        .teto => @sqrt(2 * wing_loading / (isaRho(requirements.h_ceiling) * @sqrt(3 * polar.CD0 / polar.k))),
    };
}

/// o T/W que o requisito pede nesta carga alar
pub fn requiredThrustWeight(kind: Kind, wing_loading: f64, requirements: Requirements, polar: ParabolicPolar) f64 {
    const r = requirements;
    switch (kind) {
        .curva => {
            const q = dynamicPressure(r.rho, r.V_turn);
            return q * (polar.CD0 / wing_loading + polar.k * (r.n_turn / q) * (r.n_turn / q) * wing_loading);
        },
        .subida, .gradiente => {
            const q = dynamicPressure(r.rho, r.V_climb);
            const climb = if (kind == .subida) r.roc / r.V_climb else r.climb_grad / 100;
            return climb + q * polar.CD0 / wing_loading + polar.k * wing_loading / q;
        },
        .cruzeiro, .vmax => {
            const q = dynamicPressure(r.rho, if (kind == .cruzeiro) r.V_cruise else r.V_max);
            return q * polar.CD0 / wing_loading + polar.k * wing_loading / q;
        },
        .decolagem => {
            const stall = @sqrt(2 * wing_loading / (r.rho * polar.CLmax));
            const liftoff = 1.1 * stall;
            const q = dynamicPressure(r.rho, liftoff / @sqrt(2.0));
            return liftoff * liftoff / (2 * g0 * r.S_G) + q * polar.CD_TO / wing_loading + polar.mu * (1 - q * polar.CL_TO / wing_loading);
        },
        .teto => {
            const rho_h = isaRho(r.h_ceiling);
            const speed = @sqrt(2 * wing_loading / (rho_h * @sqrt(3 * polar.CD0 / polar.k))); // V da subida máxima (aprox.)
            const q = dynamicPressure(rho_h, speed);
            const at_height = r.roc_ceiling / speed + q * polar.CD0 / wing_loading + polar.k * wing_loading / q;
            return at_height / std.math.pow(f64, rho_h / 1.225, r.thrust_rho_exp);
        },
    }
}

/// o limite de W/S (∞ se o requisito está desligado)
pub fn limitLoading(limit: Limit, requirements: Requirements, polar: ParabolicPolar) f64 {
    return switch (limit) {
        .estol => 0.5 * requirements.rho * requirements.V_stall * requirements.V_stall * polar.CLmax,
        .pouso => if (requirements.S_L > 0) requirements.rho * polar.CLmax * g0 * requirements.mu_brake * requirements.S_L / (1.15 * 1.15) else std.math.inf(f64),
    };
}

/// a maior curva ligada nesta W/S e quem é ela (a primeira na ordem de `Kind`, se empatam)
pub fn envelope(wing_loading: f64, requirements: Requirements, polar: ParabolicPolar) struct { thrust_weight: f64, kind: Kind } {
    var best: f64 = -std.math.inf(f64);
    var who: Kind = .decolagem;
    for (std.enums.values(Kind)) |kind| {
        if (!kind.active(requirements)) continue;
        const value = requiredThrustWeight(kind, wing_loading, requirements, polar);
        if (value > best) {
            best = value;
            who = kind;
        }
    }
    return .{ .thrust_weight = best, .kind = who };
}

/// o ponto de projeto: o menor T/W viável e a W/S dele, quem manda, o limite de W/S e a faixa ótima
pub const DesignPoint = struct {
    wing_loading: f64,
    thrust_weight: f64,
    active: Kind,
    max_loading: f64,
    limiter: Limit,
    band: [2]f64,
    at_limit: bool,
};

const grid_points = 600;

/// o ponto de projeto numa grade de 600 W/S de 3 % do limite até o limite (como `design_point` do Python)
pub fn designPoint(requirements: Requirements, polar: ParabolicPolar, tolerance: f64) DesignPoint {
    const stall = limitLoading(.estol, requirements, polar);
    const landing = limitLoading(.pouso, requirements, polar);
    const max_loading = @min(stall, landing);
    const limiter: Limit = if (landing < stall) .pouso else .estol;
    var lowest: f64 = std.math.inf(f64);
    var lowest_index: usize = 0;
    var curve: [grid_points]f64 = undefined;
    for (&curve, 0..) |*value, i| {
        value.* = envelope(gridLoading(max_loading, i), requirements, polar).thrust_weight;
        if (value.* < lowest) {
            lowest = value.*;
            lowest_index = i;
        }
    }
    var band = [2]f64{ std.math.inf(f64), -std.math.inf(f64) };
    for (curve, 0..) |value, i| if (value <= (1 + tolerance) * lowest) {
        band[0] = @min(band[0], gridLoading(max_loading, i));
        band[1] = @max(band[1], gridLoading(max_loading, i));
    };
    const best_loading = gridLoading(max_loading, lowest_index);
    return .{
        .wing_loading = best_loading,
        .thrust_weight = lowest,
        .active = envelope(best_loading, requirements, polar).kind,
        .max_loading = max_loading,
        .limiter = limiter,
        .band = band,
        .at_limit = lowest_index == grid_points - 1,
    };
}

/// o ponto `i` da grade de `designPoint` (o `np.linspace(0,03 ws_max, ws_max, 600)`)
fn gridLoading(max_loading: f64, i: usize) f64 {
    const start = 0.03 * max_loading;
    if (i == grid_points - 1) return max_loading;
    return start + (max_loading - start) * @as(f64, @floatFromInt(i)) / @as(f64, grid_points - 1);
}

const testing = std.testing;

test "constraints: a polar estimada, as curvas e o ponto de projeto batem com o Python" {
    const polar = estimatePolar(4, 0.0055, 7, 0, 1.4, 0.5, 0.01, 0.04);
    try testing.expectApproxEqAbs(@as(f64, 0.054186894944221596), polar.k, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0455467237360554), polar.CD_TO, 1e-15);
    // os números de `required_tw` e `condition_speed` do Python a W/S = 200 N/m², com teto 1000 m, gradiente 5 % e
    // V máxima 25 m/s
    const requirements: Requirements = .{ .h_ceiling = 1000, .climb_grad = 5, .V_max = 25 };
    const expected = [_][2]f64{
        .{ 0.33881980332956346, 11.878883437432856 }, .{ 0.26992886009932926, 13 }, .{ 0.1660827062531754, 13 },
        .{ 0.08636393742885408, 16 },                 .{ 0.07041926297085863, 25 }, .{ 0.37430100983238035, 14 },
        .{ 0.1183821327570421, 18.056564114950415 },
    };
    for (std.enums.values(Kind), expected) |kind, numbers| {
        try testing.expectApproxEqAbs(numbers[0], requiredThrustWeight(kind, 200, requirements, polar), 1e-12);
        try testing.expectApproxEqAbs(numbers[1], conditionSpeed(kind, 200, requirements, polar), 1e-12);
    }
    // `design_point(Requirements(), estimate_polar(), tol=0.05)` do Python
    const point = designPoint(.{}, polar, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 65.9527013772955), point.wing_loading, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.22290009486449008), point.thrust_weight, 1e-12);
    try testing.expectEqual(Kind.subida, point.active);
    try testing.expectEqual(Limit.estol, point.limiter);
    try testing.expectApproxEqAbs(@as(f64, 103.75750000000001), point.max_loading, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 37.72511840567613), point.band[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 103.75750000000001), point.band[1], 1e-9);
    try testing.expect(!point.at_limit);
}

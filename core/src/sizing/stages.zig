//! Estágios da cadeia de dimensionamento, cada um uma função pura com entradas e saídas pequenas:
//!
//!   geometry  envergadura, área            → S, b, alongamento
//!   polar     geometria, perfil, tipo      → C_D0, K, C_L,max, C_L na corrida
//!   envelope  polar, curva de tração, W    → V_S, V_max, subida, L/D
//!   takeoff   polar, curva, massa          → corrida (ou pairado)
//!   mass      geometria, conjuntos, tipo   → PV
//!
//! A tração entra como uma curva T(V) já calculada (`Curve`): quem a calcula é um `Thrust`
//! (o do núcleo, `CoreThrust`, ou um mock nos testes) — ver chain.zig.
const std = @import("std");
const sizing_types = @import("types.zig");
const kinds = @import("kinds.zig");

pub const g0 = 9.80665;
pub const V_top = 50.0; // a curva vai de 0 a V_top (m/s)

pub const Curve = struct {
    V: [sizing_types.n_curve]f64,
    T: [sizing_types.n_curve]f64, // tração total (N), ≥ 0

    /// a grade de velocidades da curva, de 0 a V_top
    pub fn grid() [sizing_types.n_curve]f64 {
        var points: [sizing_types.n_curve]f64 = undefined;
        for (&points, 0..) |*point, i| point.* = V_top * @as(f64, @floatFromInt(i)) / @as(f64, sizing_types.n_curve - 1);
        return points;
    }
    /// tração interpolada na velocidade `airspeed`
    pub fn at(self: *const Curve, airspeed: f64) f64 {
        if (airspeed <= self.V[0]) return self.T[0];
        for (0..sizing_types.n_curve - 1) |i| {
            if (airspeed <= self.V[i + 1]) {
                const fraction = (airspeed - self.V[i]) / (self.V[i + 1] - self.V[i]);
                return self.T[i] + fraction * (self.T[i + 1] - self.T[i]);
            }
        }
        return self.T[sizing_types.n_curve - 1];
    }
};

// ------------------------------------------------------------------ geometria
pub const Geo = struct { S: f64, b: f64, AR: f64, AR_eq: f64, c: f64 };

/// `area` é a área total das asas (o biplano a divide em duas de mesma envergadura)
pub fn geometry(comptime AircraftKind: type, span: f64, area: f64) Geo {
    const wing_span = @max(span, 1e-3);
    const Sw = @max(area, 1e-4);
    const AR_eq = wing_span * wing_span / Sw; // monoplano equivalente (mesma envergadura e área total)
    return .{ .S = Sw, .b = wing_span, .AR = AR_eq * @as(f64, AircraftKind.wings), .AR_eq = AR_eq, .c = Sw / (wing_span * @as(f64, AircraftKind.wings)) };
}

// ------------------------------------------------------------------ perfil da asa (raiz → ponta)
/// propriedades 2D médias da asa trapezoidal com perfil da raiz e da ponta: interpolação linear ao longo
/// da envergadura pesada pela corda, ∫p c dη / ∫c dη = p_r + (p_t − p_r)(1 + 2λ)/(3(1 + λ))
pub fn blendAirfoils(root: sizing_types.AirfoilData, tip: sizing_types.AirfoilData, taper: f64) sizing_types.AirfoilData {
    const taper_ratio = std.math.clamp(taper, 0.05, 1.0);
    const weight_frac = (1.0 + 2.0 * taper_ratio) / (3.0 * (1.0 + taper_ratio));
    const mix = struct {
        fn lerp(from: f64, to: f64, share: f64) f64 {
            return from + (to - from) * share;
        }
    }.lerp;
    return .{ .cla = mix(root.cla, tip.cla, weight_frac), .a0_deg = mix(root.a0_deg, tip.a0_deg, weight_frac), .clmax = mix(root.clmax, tip.clmax, weight_frac), .cd0 = mix(root.cd0, tip.cd0, weight_frac), .cm = mix(root.cm, tip.cm, weight_frac) };
}

// ------------------------------------------------------------------ polar
pub const Polar = struct { CD0: f64, K: f64, CLmax: f64, CLg: f64 };

/// `extra_CDS`: C_D·S que o arranjo acrescenta (naceles)
pub fn polar(comptime AircraftKind: type, cfg: *const sizing_types.SizingCfg, geo: Geo, af: sizing_types.AirfoilData, extra_CDS: f64) Polar {
    const tail = if (AircraftKind.tail) cfg.tail_area_frac * cfg.tail_drag_frac else 0.0;
    const CLmax = @max(AircraftKind.clmaxFactor(cfg) * af.clmax, 0.1);
    return .{
        .CD0 = @max(af.cd0, 0.0) * (1.0 + tail) + (@max(cfg.fuselage_CDS, 0.0) + @max(extra_CDS, 0.0)) / geo.S,
        .K = AircraftKind.inducedFactor(cfg) / (std.math.pi * geo.AR_eq * std.math.clamp(cfg.oswald, 0.3, 1.0)),
        .CLmax = CLmax,
        .CLg = std.math.clamp(cfg.cl_ground, 0.0, 1.0) * CLmax,
    };
}

// ------------------------------------------------------------------ envelope
pub const Env = struct {
    Vs: f64,
    Vmax: f64, // NaN: a tração não vence o arrasto em nenhuma V
    RC: f64, // subida máxima (m/s)
    TW: f64,
    V_LD: f64,
    LD: f64,
    grad: f64, // gradiente de subida máximo, sen γ (adimensional)
    D: [sizing_types.n_curve]f64, // arrasto de voo nivelado (tração requerida, N) na grade inteira; V = 0: infinito
};

/// velocidade de estol: √(2W/(ρ S C_L,max))
pub fn stallSpeed(aero_polar: Polar, weight: f64, Sw: f64, rho: f64) f64 {
    return @sqrt(2.0 * weight / (rho * Sw * aero_polar.CLmax));
}

/// envelope de voo nivelado: V_S, V_max, subida e gradiente máximos, L/D e o arrasto na grade
pub fn envelope(aero_polar: Polar, curve: *const Curve, weight: f64, Sw: f64, rho: f64) Env {
    var env_out: Env = .{ .Vs = stallSpeed(aero_polar, weight, Sw, rho), .Vmax = std.math.nan(f64), .RC = -std.math.inf(f64), .TW = curve.T[0] / weight, .V_LD = @sqrt(2.0 * weight / (rho * Sw) * @sqrt(aero_polar.K / @max(aero_polar.CD0, 1e-6))), .LD = 0.5 / @sqrt(aero_polar.K * @max(aero_polar.CD0, 1e-6)), .grad = -std.math.inf(f64), .D = undefined };
    var prev_ok = false;
    var prev_V: f64 = 0;
    var prev_excess: f64 = 0;
    for (0..sizing_types.n_curve) |i| {
        const airspeed = curve.V[i];
        const dyn_pressure = 0.5 * rho * airspeed * airspeed;
        const CL = if (dyn_pressure > 0) weight / (dyn_pressure * Sw) else std.math.inf(f64);
        const drag = if (dyn_pressure > 0) dyn_pressure * Sw * (aero_polar.CD0 + aero_polar.K * CL * CL) else std.math.inf(f64);
        env_out.D[i] = drag; // a curva inteira (o C_L de voo nivelado, sem limite); V_S marca onde o voo existe
        if (airspeed < env_out.Vs) continue;
        const excess = curve.T[i] - drag;
        env_out.RC = @max(env_out.RC, excess * airspeed / weight);
        env_out.grad = @max(env_out.grad, excess / weight);
        const ok = excess >= 0;
        if (ok) {
            env_out.Vmax = airspeed;
        } else if (prev_ok) { // cruzou entre o ponto anterior e este: interpola
            env_out.Vmax = prev_V + (airspeed - prev_V) * prev_excess / (prev_excess - excess);
        }
        prev_ok = ok;
        prev_V = airspeed;
        prev_excess = excess;
    }
    if (!std.math.isFinite(env_out.RC)) env_out.RC = std.math.nan(f64);
    if (!std.math.isFinite(env_out.grad)) env_out.grad = std.math.nan(f64);
    return env_out;
}

// ------------------------------------------------------------------ curva, teto, pouso
/// fator de carga sustentado na velocidade V: o que a tração mantém, n = √(q/(K W/S) (T/W − q C_D0/(W/S))),
/// limitado pelo estol, n = q C_L,max/(W/S) (Gudmundsson, cap. 3; como no diagrama de restrições)
pub fn sustainedN(aero_polar: Polar, curve: *const Curve, weight: f64, Sw: f64, rho: f64, airspeed: f64) f64 {
    const dyn_pressure = 0.5 * rho * airspeed * airspeed;
    const ws = weight / Sw;
    const tw = curve.at(airspeed) / weight;
    const n_thr = @sqrt(@max(dyn_pressure / (aero_polar.K * ws) * (tw - dyn_pressure * aero_polar.CD0 / ws), 0.0));
    return @min(n_thr, dyn_pressure * aero_polar.CLmax / ws);
}

/// densidade ISA pela altitude-densidade (a mesma de `isa_density` do aerosim)
pub fn isaRho(altitude: f64) f64 {
    return 1.225 * std.math.pow(f64, @max(1.0 - 2.25577e-5 * altitude, 1e-6), 4.2559);
}

/// altitude-densidade de uma densidade (inversa de `isaRho`)
pub fn isaAltitude(rho: f64) f64 {
    return (1.0 - std.math.pow(f64, @max(rho, 1e-6) / 1.225, 1.0 / 4.2559)) / 2.25577e-5;
}

/// teto: a altitude-densidade em que a subida máxima cai a `roc` (tração ∝ ρ); NaN se não sobe nem no campo
pub fn ceiling(aero_polar: Polar, curve: *const Curve, weight: f64, Sw: f64, rho: f64, roc: f64) f64 {
    const h0 = isaAltitude(rho);
    const rcAt = struct {
        fn evaluate(pol: Polar, base_curve: *const Curve, wt: f64, wing_area: f64, r0: f64, altitude: f64) f64 {
            const rh = isaRho(altitude);
            var scaled = base_curve.*;
            for (&scaled.T) |*thrust_value| thrust_value.* *= rh / r0;
            const env_out = envelope(pol, &scaled, wt, wing_area, rh);
            return if (std.math.isFinite(env_out.RC)) env_out.RC else -1e9;
        }
    }.evaluate;
    if (rcAt(aero_polar, curve, weight, Sw, rho, h0) < roc) return std.math.nan(f64);
    var lo = h0;
    var hi = h0 + 9000.0;
    if (rcAt(aero_polar, curve, weight, Sw, rho, hi) >= roc) return hi;
    for (0..30) |_| {
        const mid = 0.5 * (lo + hi);
        if (rcAt(aero_polar, curve, weight, Sw, rho, mid) >= roc) lo = mid else hi = mid;
    }
    return lo;
}

/// corrida de pouso: toque a 1,15 V_S, frenagem μ_f, sem arrasto nem sustentação (conservador; a mesma
/// conta do limite de pouso do diagrama de restrições)
pub fn landingRun(aero_polar: Polar, weight: f64, Sw: f64, rho: f64, mu_brake: f64) f64 {
    return 1.15 * 1.15 * (weight / Sw) / (rho * aero_polar.CLmax * g0 * @max(mu_brake, 1e-3));
}

// ------------------------------------------------------------------ decolagem
/// corrida até 1,1 V_S (m); inf se não acelera. tilt: inclinação do motor (rad)
pub fn takeoffRun(aero_polar: Polar, curve: *const Curve, mass: f64, Sw: f64, rho: f64, mu: f64, tilt: f64) f64 {
    const weight = mass * g0;
    const v_lof = 1.1 * stallSpeed(aero_polar, weight, Sw, rho);
    const ct = @cos(tilt);
    const st = @sin(tilt);
    var speed: f64 = 0;
    var distance: f64 = 0;
    const dt = 0.01;
    var k: usize = 0;
    while (k < 12000) : (k += 1) {
        const dyn_pressure = 0.5 * rho * speed * speed;
        const thrust = curve.at(speed);
        const lift = dyn_pressure * Sw * aero_polar.CLg + thrust * st;
        const drag = dyn_pressure * Sw * (aero_polar.CD0 + aero_polar.K * aero_polar.CLg * aero_polar.CLg);
        const accel = (thrust * ct - drag - mu * @max(weight - lift, 0.0)) / mass;
        if (accel <= 0) return std.math.inf(f64);
        // passo semi-implícito na posição: exato para aceleração constante
        distance += speed * dt + 0.5 * accel * dt * dt;
        speed += accel * dt;
        if (speed >= v_lof) return distance - (speed * speed - v_lof * v_lof) / (2.0 * accel); // volta ao instante exato
    }
    return std.math.inf(f64);
}

/// decola na vertical: tração estática ≥ margem × peso
pub fn canHover(curve: *const Curve, mass: f64, margin: f64) bool {
    return curve.T[0] >= margin * mass * g0;
}

// ------------------------------------------------------------------ massa
pub const Mass = struct { pv: f64, wing: f64, tail: f64, propulsion: f64, fixed: f64 };

/// massa vazia pelas densidades de asa e empenagem, conjuntos de tração e massas fixas
pub fn emptyMass(comptime AircraftKind: type, cfg: *const sizing_types.SizingCfg, geo: Geo, set_mass: f64, n_motor: f64) Mass {
    const wing = cfg.wing_density * geo.S;
    const tail = if (AircraftKind.tail) cfg.tail_density * cfg.tail_area_frac * geo.S else 0.0;
    const prop = n_motor * set_mass;
    const gear = if (AircraftKind.hover == kinds.Hover.required) 0.0 else cfg.gear_mass;
    const fixed = cfg.fuselage_mass + cfg.systems_mass + gear + AircraftKind.extraMass(cfg, prop);
    return .{ .pv = wing + tail + prop + fixed, .wing = wing, .tail = tail, .propulsion = prop, .fixed = fixed };
}

// ------------------------------------------------------------------ testes (mocks no lugar da tração)
const testing = std.testing;
const fuzz = @import("../util/fuzz.zig");

/// mock de tração: T = T0 (1 − V/Vz), ≥ 0
pub fn linearCurve(T0: f64, Vz: f64) Curve {
    var curve: Curve = .{ .V = Curve.grid(), .T = undefined };
    for (curve.V, 0..) |airspeed, i| curve.T[i] = @max(T0 * (1.0 - airspeed / Vz), 0.0);
    return curve;
}

test "dois perfis: retangular pesa meio a meio; perfil igual não muda nada" {
    const root: sizing_types.AirfoilData = .{ .clmax = 2.0, .cd0 = 0.02 };
    const tip: sizing_types.AirfoilData = .{ .clmax = 1.2, .cd0 = 0.01 };
    const blend = blendAirfoils(root, tip, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 1.6), blend.clmax, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.015), blend.cd0, 1e-12);
    try testing.expect(blendAirfoils(root, tip, 0.3).clmax > blend.clmax); // afilada: a raiz pesa mais
    try testing.expectEqual(root, blendAirfoils(root, root, 0.4));
}

test "curva sustentada e teto: contas fechadas" {
    const aero_polar: Polar = .{ .CD0 = 0.04, .K = 0.05, .CLmax = 1.4, .CLg = 0.5 };
    const T0 = 30.0;
    const curve = linearCurve(T0, 1e9); // tração constante
    const weight = 100.0;
    const Sw = 1.0;
    const rho = 1.2;
    const airspeed = 14.0;
    const dyn_pressure = 0.5 * rho * airspeed * airspeed;
    const load_factor = @sqrt(dyn_pressure / (aero_polar.K * weight) * (T0 / weight - dyn_pressure * aero_polar.CD0 / weight));
    try testing.expectApproxEqRel(@min(load_factor, dyn_pressure * aero_polar.CLmax / weight), sustainedN(aero_polar, &curve, weight, Sw, rho, airspeed), 1e-12);
    // teto: com tração ∝ ρ, a subida cai com a altitude e o teto passa da altitude do campo
    const altitude = ceiling(aero_polar, &curve, weight, Sw, rho, 0.5);
    try testing.expect(altitude > isaAltitude(rho));
    try testing.expectApproxEqAbs(@as(f64, 600), isaAltitude(isaRho(600)), 1e-6);
    try testing.expectApproxEqRel(1.15 * 1.15 * weight / (rho * aero_polar.CLmax * g0 * 0.3), landingRun(aero_polar, weight, Sw, rho, 0.3), 1e-12);
}

test "decolagem sem arrasto nem atrito: x = v²·m/(2T)" {
    const aero_polar: Polar = .{ .CD0 = 0, .K = 0, .CLmax = 1.5, .CLg = 0 };
    const curve = linearCurve(20, 1e9); // tração constante
    const mass = 5.0;
    const v_lof = 1.1 * stallSpeed(aero_polar, mass * g0, 0.8, 1.2);
    const distance = takeoffRun(aero_polar, &curve, mass, 0.8, 1.2, 0, 0);
    try testing.expectApproxEqRel(v_lof * v_lof * mass / (2 * 20.0), distance, 1e-6);
}

test "envelope com tração constante: V_max analítica" {
    const aero_polar: Polar = .{ .CD0 = 0.04, .K = 0.05, .CLmax = 1.4, .CLg = 0.5 };
    const T0 = 15.0;
    const curve = linearCurve(T0, 1e9);
    const weight = 80.0;
    const Sw = 0.8;
    const rho = 1.2;
    const env_out = envelope(aero_polar, &curve, weight, Sw, rho);
    // T = q S CD0 + K W²/(q S)  →  q = (T + √(T² − 4 CD0 K W²)) / (2 S CD0)
    const dyn_pressure = (T0 + @sqrt(T0 * T0 - 4 * aero_polar.CD0 * aero_polar.K * weight * weight)) / (2 * Sw * aero_polar.CD0);
    try testing.expectApproxEqRel(@sqrt(2 * dyn_pressure / rho), env_out.Vmax, 0.02); // interpolação linear na grade
}

fn fuzzStages(_: void, src: *fuzz.Src) !void {
    const cfg: sizing_types.SizingCfg = .{ .oswald = src.range(0.3, 1), .clmax_factor = src.range(0.5, 1), .cl_ground = src.range(0, 1), .fuselage_CDS = src.range(0, 0.05) };
    const af: sizing_types.AirfoilData = .{ .clmax = src.range(0.8, 2.4), .cd0 = src.range(0.005, 0.03) };
    inline for (kinds.all) |AircraftKind| {
        const geo = geometry(AircraftKind, src.range(0.3, 5), src.range(0.05, 3));
        const aero_polar = polar(AircraftKind, &cfg, geo, af, src.range(0, 0.02));
        try testing.expect(aero_polar.CD0 > 0 and aero_polar.K > 0 and aero_polar.CLmax > 0 and aero_polar.CLg <= aero_polar.CLmax);
        const curve = linearCurve(src.range(0, 200), src.range(5, 80));
        const mass = src.range(0.2, 40);
        const rho = src.range(0.7, 1.3);
        const env_out = envelope(aero_polar, &curve, mass * g0, geo.S, rho);
        errdefer std.debug.print("K={s} Vs={d} Vmax={d} CD0={d} K={d}\n", .{ AircraftKind.name, env_out.Vs, env_out.Vmax, aero_polar.CD0, aero_polar.K });
        try testing.expect(env_out.Vs > 0 and std.math.isFinite(env_out.Vs));
        if (std.math.isFinite(env_out.Vmax)) try testing.expect(env_out.Vmax >= env_out.Vs - 1e-9);
        // corrida: não negativa e não diminui com a massa
        // curva e teto: finitos ou NaN, nunca negativos; o pouso cresce com a massa
        const nt = sustainedN(aero_polar, &curve, mass * g0, geo.S, rho, 1.4 * env_out.Vs);
        try testing.expect(!(nt < 0));
        const hc = ceiling(aero_polar, &curve, mass * g0, geo.S, rho, 0.5);
        try testing.expect(std.math.isNan(hc) or hc >= isaAltitude(rho) - 1e-6);
        try testing.expect(landingRun(aero_polar, 1.2 * mass * g0, geo.S, rho, 0.3) > landingRun(aero_polar, mass * g0, geo.S, rho, 0.3));
        const s1 = takeoffRun(aero_polar, &curve, mass, geo.S, rho, cfg.mu, 0);
        const s2 = takeoffRun(aero_polar, &curve, mass * 1.2, geo.S, rho, cfg.mu, 0);
        errdefer std.debug.print("s1={d} s2={d} m={d}\n", .{ s1, s2, mass });
        try testing.expect(!(s1 < 0) and !(s2 < s1 - 1e-6));
        const ms = emptyMass(AircraftKind, &cfg, geo, src.range(0, 2), @floor(src.range(1, 4)));
        try testing.expect(ms.pv > 0 and std.math.isFinite(ms.pv));
    }
}

test "fuzz: estágios com tração mock (todas as formas de aeronave)" {
    try fuzz.check({}, fuzzStages, .{});
}

//! Estabilidade estática do avião montado: o que a aba Estabilidade calcula antes da dinâmica. É a mesma conta de
//! `aerosim/stability/probe.py` e `sizing.py` (a sonda, o estol, o ponto neutro, a trimagem num C_L, o profundor de
//! rotação, a varredura do CG e o C_L máximo equilibrado), aqui no núcleo para a aba em Zig rodar sem Python.
//!
//! Tudo parte dos coeficientes do núcleo (`aero.coeffsEx`), com o momento em qualquer ponto de referência. O ponto
//! neutro com o manche fixo é onde o C_m não muda com α. Com a referência em x = 0,
//!
//!   x_np = c · (∂C_m/∂α) / (∂C_L/∂α)
//!
//! por derivada central de meio grau (Etkin e Reid, Dynamics of Flight, cap. 2; número da equação a conferir no
//! PDF). A margem estática é a distância do CG até ele, em % da corda média aerodinâmica (CMA). O limite traseiro do
//! CG é a margem mínima; o dianteiro é onde o comando de arfagem chega ao fim do curso para equilibrar no pouso, no
//! cruzeiro ou para rodar na decolagem.
const std = @import("std");
const types = @import("../types.zig");
const vec = @import("../math/vec.zig");
const aero = @import("../physics/aero.zig");
const mass = @import("../physics/mass.zig");
const propulsion = @import("../physics/propulsion.zig");
const runner = @import("runner.zig");
const state = @import("state.zig");

const V3 = vec.V3;
/// a gravidade padrão (m/s²), a mesma de `probe.py`
pub const g0 = 9.80665;
/// o passo das derivadas centrais (rad), o `D` de `probe.py`
pub const step = 0.5 * std.math.pi / 180.0;
const rad: f64 = std.math.pi / 180.0;

/// os comandos e as taxas de um ponto (rad, rad/s)
pub const Inputs = struct { beta: f64 = 0, roll_rate: f64 = 0, pitch_rate: f64 = 0, yaw_rate: f64 = 0, elevator: f64 = 0, aileron: f64 = 0, rudder: f64 = 0 };

/// o avião montado para as perguntas da estabilidade: coeficientes, massa, CG, inércia e a CMA
pub const Probe = struct {
    params: *const types.Params,
    mass: f64,
    cg: V3,
    inertia: vec.M3,
    weight: f64,
    area: f64,
    chord: f64,
    span: f64,
    density: f64,
    mac_leading_edge: f64, // x do bordo de ataque da CMA da asa (corpo, x para a frente)

    /// a sonda de uma instância já configurada: a massa, o CG e a inércia do avião parado, como `mass_props`
    pub fn init(instance: *const runner.Instance, mac_leading_edge: f64) Probe {
        const zero_state = [_]f64{0} ** state.nx;
        const props = mass.compute(instance.ctx(), &zero_state);
        const params = &instance.p;
        return .{
            .params = params,
            .mass = props.m,
            .cg = props.rcg,
            .inertia = props.I,
            .weight = props.m * g0,
            .area = params.Sref,
            .chord = params.cref,
            .span = params.bref,
            .density = params.env.rho,
            .mac_leading_edge = mac_leading_edge,
        };
    }

    /// os coeficientes em V e α, com o momento em `ref` (null: o CG)
    pub fn coeffs(probe: *const Probe, airspeed: f64, alpha: f64, ref: ?V3, inputs: Inputs) types.AeroCoeffs {
        return aero.coeffsEx(probe.params, airspeed, alpha, inputs.beta, .{ inputs.roll_rate, inputs.pitch_rate, inputs.yaw_rate }, ref orelse probe.cg, .{ inputs.elevator, inputs.aileron, inputs.rudder });
    }

    /// a posição x em % da CMA (0 = bordo de ataque, para trás positivo)
    pub fn fraction(probe: *const Probe, x: f64) f64 {
        return 100 * (probe.mac_leading_edge - x) / probe.chord;
    }

    /// o x de uma posição em % da CMA
    pub fn xAt(probe: *const Probe, percent: f64) f64 {
        return probe.mac_leading_edge - percent / 100 * probe.chord;
    }

    /// o x do ponto neutro (manche fixo) a V, com α = 2°
    pub fn neutralPoint(probe: *const Probe, airspeed: f64) f64 {
        const alpha = 2.0 * rad;
        const ref: V3 = .{ 0, 0, probe.cg[2] };
        const plus = probe.coeffs(airspeed, alpha + step, ref, .{});
        const minus = probe.coeffs(airspeed, alpha - step, ref, .{});
        return probe.chord * ((plus.Cm - minus.Cm) / (2 * step)) / ((plus.CL - minus.CL) / (2 * step));
    }

    /// o maior C_L de −5° a 30°, de 0,25° em 0,25° (`Probe.CLmax`)
    pub fn liftMax(probe: *const Probe, airspeed: f64, elevator: f64) f64 {
        var best = -std.math.inf(f64);
        var k: usize = 0;
        while (k <= 140) : (k += 1) {
            const alpha = (-5.0 + 0.25 * @as(f64, @floatFromInt(k))) * rad;
            best = @max(best, probe.coeffs(airspeed, alpha, null, .{ .elevator = elevator }).CL);
        }
        return best;
    }

    /// a velocidade de estol com o C_L máximo dado
    pub fn stallSpeed(probe: *const Probe, lift_max: f64) f64 {
        return @sqrt(2 * probe.weight / (probe.density * probe.area * lift_max));
    }

    /// (α, δe) com C_L = `lift` e C_m = 0 em torno de (x, 0, z do CG), por Newton 2 × 2 a partir de `guess`; null
    /// se não converge (`trim_at_CL`)
    pub fn trimAtLift(probe: *const Probe, airspeed: f64, lift: f64, x: f64, guess: [2]f64) ?[2]f64 {
        const ref: V3 = .{ x, 0, probe.cg[2] };
        var alpha = guess[0];
        var elevator = guess[1];
        for (0..30) |_| {
            const base = probe.trimResidual(airspeed, lift, ref, alpha, elevator);
            if (@abs(base[0]) + @abs(base[1]) < 1e-8) return .{ alpha, elevator };
            const h = 1e-5;
            const by_alpha = probe.trimResidual(airspeed, lift, ref, alpha + h, elevator);
            const by_elevator = probe.trimResidual(airspeed, lift, ref, alpha, elevator + h);
            const lift_alpha = (by_alpha[0] - base[0]) / h;
            const moment_alpha = (by_alpha[1] - base[1]) / h;
            const lift_elevator = (by_elevator[0] - base[0]) / h;
            const moment_elevator = (by_elevator[1] - base[1]) / h;
            const determinant = lift_alpha * moment_elevator - lift_elevator * moment_alpha;
            if (determinant == 0 or !std.math.isFinite(determinant)) break;
            const d_alpha = (-base[0] * moment_elevator + base[1] * lift_elevator) / determinant;
            const d_elevator = (-lift_alpha * base[1] + moment_alpha * base[0]) / determinant;
            alpha += std.math.clamp(d_alpha, -0.1, 0.1);
            elevator = std.math.clamp(elevator + std.math.clamp(d_elevator, -0.2, 0.2), -1.2, 1.2);
        }
        const last = probe.trimResidual(airspeed, lift, ref, alpha, elevator);
        return if (@abs(last[0]) + @abs(last[1]) < 1e-5) .{ alpha, elevator } else null;
    }

    fn trimResidual(probe: *const Probe, airspeed: f64, lift: f64, ref: V3, alpha: f64, elevator: f64) [2]f64 {
        const point = probe.coeffs(airspeed, alpha, ref, .{ .elevator = elevator });
        return .{ point.CL - lift, point.Cm };
    }

    /// o maior C_L que o comando de arfagem equilibra com o CG em x (|δe| ≤ `elevator_max`), por bisseção no C_L
    /// (`trimmed_CLmax`); NaN se nem C_L = 0,05 equilibra
    pub fn trimmedLiftMax(probe: *const Probe, airspeed: f64, x: f64, elevator_max: f64) f64 {
        var low: f64 = 0.05;
        var high = probe.liftMax(airspeed, 0) * 1.05;
        const guess: [2]f64 = .{ 0.05, 0 };
        if (!probe.trimWithin(airspeed, low, x, elevator_max, guess)) return std.math.nan(f64);
        for (0..30) |_| {
            const middle = 0.5 * (low + high);
            if (probe.trimWithin(airspeed, middle, x, elevator_max, guess)) low = middle else high = middle;
        }
        return low;
    }

    fn trimWithin(probe: *const Probe, airspeed: f64, lift: f64, x: f64, elevator_max: f64, guess: [2]f64) bool {
        const trim = probe.trimAtLift(airspeed, lift, x, guess) orelse return false;
        return @abs(trim[1]) <= elevator_max + 1e-9;
    }

    /// o ponto médio do trem principal (sem trem: um pouco atrás e abaixo do CG), como `Probe.main_gear`
    pub fn mainGear(probe: *const Probe) V3 {
        var sum: V3 = vec.zero;
        var count: f64 = 0;
        for (probe.params.gear[0..@intCast(probe.params.n_gear)]) |leg| {
            if (leg.kind != .main) continue;
            sum += V3{ leg.r[0], 0, leg.r[2] };
            count += 1;
        }
        if (count == 0) return .{ probe.cg[0] - 0.05, 0, probe.cg[2] + 0.2 };
        return sum / vec.splat(count);
    }

    /// a tração total a V com o acelerador `throttle` e o z médio da linha de tração (ponderado pela tração)
    pub fn thrust(probe: *const Probe, airspeed: f64, throttle: f64) [2]f64 {
        var total: f64 = 0;
        var moment: f64 = 0;
        for (probe.params.prop[0..@intCast(probe.params.n_prop)]) |*unit| {
            const force = propulsion.point(probe.params, unit, airspeed, throttle).T;
            total += force;
            moment += force * unit.r[2];
        }
        return .{ total, if (total > 0) moment / total else 0 };
    }

    /// δe que dá a aceleração de arfagem `pitch_acceleration` (°/s²) em torno do trem principal em V_R, com o CG em x
    /// (`rotation_de`): I θ̈ = q S c (C_m + C_mδe δe) − W (x − x_tp) + T (z_T − z_tp), momentos no trem
    pub fn rotationElevator(probe: *const Probe, rotation_speed: f64, x: f64, pitch_acceleration: f64, gear_point: ?V3) f64 {
        const gear = gear_point orelse probe.mainGear();
        const dynamic_pressure = 0.5 * probe.density * rotation_speed * rotation_speed;
        const base = probe.coeffs(rotation_speed, 0, gear, .{});
        const plus = probe.coeffs(rotation_speed, 0, gear, .{ .elevator = step });
        const minus = probe.coeffs(rotation_speed, 0, gear, .{ .elevator = -step });
        const moment_slope = (plus.Cm - minus.Cm) / (2 * step);
        const pushing = probe.thrust(rotation_speed, 1);
        const dx = x - gear[0];
        const dz = probe.cg[2] - gear[2];
        const inertia = probe.inertia[1][1] + probe.mass * (dx * dx + dz * dz);
        const reference = dynamic_pressure * probe.area * probe.chord;
        const moment = reference * base.Cm - probe.weight * (x - gear[0]) + pushing[0] * (pushing[1] - gear[2]);
        return (inertia * pitch_acceleration * rad - moment) / (reference * moment_slope);
    }

    /// o C_m no CG com C_L = 0 e o comando neutro (`cm0`)
    pub fn momentAtZeroLift(probe: *const Probe, airspeed: f64) f64 {
        var low: f64 = -15.0 * rad;
        var high: f64 = 10.0 * rad;
        for (0..50) |_| {
            const middle = 0.5 * (low + high);
            if (probe.coeffs(airspeed, middle, null, .{}).CL < 0) low = middle else high = middle;
        }
        return probe.coeffs(airspeed, 0.5 * (low + high), null, .{}).Cm;
    }
};

/// a varredura do CG: margem estática e δe de equilíbrio no pouso, no cruzeiro e na rotação (graus; NaN onde não
/// equilibra)
pub const Sweep = struct {
    pub const max_points = 64;
    count: usize = 0,
    cg: [max_points]f64 = undefined, // % CMA
    margin: [max_points]f64 = undefined, // % CMA
    landing: [max_points]f64 = undefined,
    cruise: [max_points]f64 = undefined,
    rotation: [max_points]f64 = undefined,
    neutral: f64 = 0, // % CMA
    lift_cruise: f64 = 0,
};

/// a varredura de `cg_percents` (% CMA), como `cg_sweep`; `rotation_speed` 0 = sem rotação
pub fn cgSweep(probe: *const Probe, cg_percents: []const f64, cruise_speed: f64, landing_speed: f64, landing_lift: f64, rotation_speed: f64, pitch_acceleration: f64, out: *Sweep) void {
    out.neutral = probe.fraction(probe.neutralPoint(cruise_speed));
    out.lift_cruise = probe.weight / (0.5 * probe.density * cruise_speed * cruise_speed * probe.area);
    out.count = @min(cg_percents.len, Sweep.max_points);
    var landing_guess: [2]f64 = .{ 0.1, 0 };
    var cruise_guess: [2]f64 = .{ 0.05, 0 };
    for (cg_percents[0..out.count], 0..) |percent, k| {
        const x = probe.xAt(percent);
        out.cg[k] = percent;
        out.margin[k] = out.neutral - percent;
        out.landing[k] = std.math.nan(f64);
        out.cruise[k] = std.math.nan(f64);
        out.rotation[k] = std.math.nan(f64);
        if (probe.trimAtLift(landing_speed, landing_lift, x, landing_guess)) |trim| {
            out.landing[k] = trim[1] / rad;
            landing_guess = trim;
        }
        if (probe.trimAtLift(cruise_speed, out.lift_cruise, x, cruise_guess)) |trim| {
            out.cruise[k] = trim[1] / rad;
            cruise_guess = trim;
        }
        if (rotation_speed > 0) out.rotation[k] = probe.rotationElevator(rotation_speed, x, pitch_acceleration, null) / rad;
    }
}

/// o primeiro x (da esquerda) em que y passa a respeitar |y| ≤ `limit`, por interpolação; null se nunca
/// (`limit_crossing`)
pub fn limitCrossing(xs: []const f64, ys: []const f64, limit: f64) ?f64 {
    for (xs, ys, 0..) |x, y, i| {
        if (!std.math.isFinite(y) or @abs(y) > limit) continue;
        if (i == 0) return x;
        const before = if (std.math.isFinite(ys[i - 1])) @abs(ys[i - 1]) else 1e9;
        const now = @abs(y);
        return if (now != before) xs[i - 1] + (limit - before) * (x - xs[i - 1]) / (now - before) else x;
    }
    return null;
}

/// o x do trem principal que deixa rodar com |δe| ≤ `elevator_max` e o x máximo pelo ângulo de tombamento para trás
/// (Raymer cap. 11: trem atrás do CG por 15° ou mais), como `gear_x_for_rotation`; o primeiro é null se nem no limite
/// de tombamento roda
pub fn gearForRotation(probe: *const Probe, rotation_speed: f64, x: f64, pitch_acceleration: f64, elevator_max: f64) struct { gear_x: ?f64, tip_x: f64 } {
    const tipback = 15.0 * rad;
    const gear = probe.mainGear();
    const tip_x = x - (gear[2] - probe.cg[2]) * @tan(tipback);
    var low = x - 0.6 * probe.chord;
    var high = tip_x;
    const excess = struct {
        fn at(sonda: *const Probe, speed: f64, cg_x: f64, acceleration: f64, gear_z: f64, limit: f64, gear_x: f64) f64 {
            return sonda.rotationElevator(speed, cg_x, acceleration, .{ gear_x, 0, gear_z }) + limit;
        }
    };
    if (excess.at(probe, rotation_speed, x, pitch_acceleration, gear[2], elevator_max, high) < 0) return .{ .gear_x = null, .tip_x = tip_x };
    if (excess.at(probe, rotation_speed, x, pitch_acceleration, gear[2], elevator_max, low) > 0) return .{ .gear_x = low, .tip_x = tip_x };
    for (0..40) |_| {
        const middle = 0.5 * (low + high);
        if (excess.at(probe, rotation_speed, x, pitch_acceleration, gear[2], elevator_max, middle) > 0) high = middle else low = middle;
    }
    return .{ .gear_x = high, .tip_x = tip_x };
}

test "limitCrossing interpola onde |y| entra no limite" {
    const xs = [_]f64{ 0, 1, 2, 3 };
    const ys = [_]f64{ 30, 25, 15, 5 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), limitCrossing(&xs, &ys, 20).?, 1e-12);
    try std.testing.expect(limitCrossing(&xs, &ys, 1) == null);
}

test "tudo compila" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Probe);
}

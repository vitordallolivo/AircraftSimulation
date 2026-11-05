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

// ------------------------------------------------------------------ derivadas e equilíbrio

/// a variável de uma derivada central
pub const Variable = enum { alpha, beta, roll_rate, pitch_rate, yaw_rate, elevator, aileron, rudder };

/// as derivadas centrais dos coeficientes em relação a `variable` (passo `size`, rad ou rad/s), com o resto zerado e
/// o momento em `ref` (null: o CG), como `Probe.deriv`; só CL, CD, CY, Cl, Cm, Cn e CN
pub fn derivative(probe: *const Probe, airspeed: f64, alpha: f64, variable: Variable, ref: ?V3, size: f64) types.AeroCoeffs {
    var plus_alpha = alpha;
    var minus_alpha = alpha;
    var plus: Inputs = .{};
    var minus: Inputs = .{};
    switch (variable) {
        .alpha => {
            plus_alpha += size;
            minus_alpha -= size;
        },
        inline else => |which| {
            const field = switch (which) {
                .beta => "beta",
                .roll_rate => "roll_rate",
                .pitch_rate => "pitch_rate",
                .yaw_rate => "yaw_rate",
                .elevator => "elevator",
                .aileron => "aileron",
                .rudder => "rudder",
                .alpha => unreachable,
            };
            @field(plus, field) = size;
            @field(minus, field) = -size;
        },
    }
    const high = probe.coeffs(airspeed, plus_alpha, ref, plus);
    const low = probe.coeffs(airspeed, minus_alpha, ref, minus);
    var out: types.AeroCoeffs = .{};
    inline for (.{ "CL", "CD", "CY", "Cl", "Cm", "Cn", "CN" }) |field| @field(out, field) = (@field(high, field) - @field(low, field)) / (2 * size);
    return out;
}

/// C_lp (1/rad) a V e α = 2°, com o passo de 0,01 em p b / 2V, como em `aileron_sizing`
pub fn rollDamping(probe: *const Probe, airspeed: f64) f64 {
    const scale = 2 * airspeed / probe.span;
    return derivative(probe, airspeed, 2 * rad, .roll_rate, null, 0.01 * scale).Cl * scale;
}

/// C_nr e C_lr (1/rad) a V e α = 2° (passo de 0,01 em r b / 2V)
pub fn yawDamping(probe: *const Probe, airspeed: f64) [2]f64 {
    const scale = 2 * airspeed / probe.span;
    const slope = derivative(probe, airspeed, 2 * rad, .yaw_rate, null, 0.01 * scale);
    return .{ slope.Cn * scale, slope.Cl * scale };
}

/// α com o C_L pedido e o comando `elevator`: bisseção no ramo linear, de −10° até o pico (de 0,5° em 0,5°); null
/// se o C_L passa do pico (`alpha_for_CL`)
pub fn alphaForLift(probe: *const Probe, airspeed: f64, lift: f64, elevator: f64) ?f64 {
    var peak_alpha: f64 = -10 * rad;
    var peak = -std.math.inf(f64);
    var k: usize = 0;
    while (k <= 80) : (k += 1) {
        const alpha = (-10.0 + 0.5 * @as(f64, @floatFromInt(k))) * rad;
        const value = probe.coeffs(airspeed, alpha, null, .{ .elevator = elevator }).CL;
        if (value > peak) {
            peak = value;
            peak_alpha = alpha;
        }
    }
    if (lift > peak) return null;
    var low: f64 = -10 * rad;
    var high = peak_alpha;
    for (0..50) |_| {
        const middle = 0.5 * (low + high);
        if (probe.coeffs(airspeed, middle, null, .{ .elevator = elevator }).CL < lift) low = middle else high = middle;
    }
    return 0.5 * (low + high);
}

// ------------------------------------------------------------------ tesoura (área do EH × faixa de CG)

/// os limites do CG (% CMA) de uma área de EH: o ponto neutro, o traseiro pela margem mínima e os dianteiros por
/// controle no pouso e pela rotação (`scissor.limits`). Dianteiro no pouso: o equilíbrio em C_L = k C_Lmax com o
/// comando todo cabrado, x_CG = x_P + c C_m,P / C_N; na rotação, com o comando cabrado em V_R e θ = 0,
/// x_CG ≤ x_tp + (q S c C_m,tp + T (z_T − z_tp) − I_tp θ̈) / W (Torenbeek, Synthesis of Subsonic Airplane Design,
/// cap. 9; Sadraey, Aircraft Design, cap. 6; a conferir no PDF)
pub const Limits = struct { neutral: f64, aft: f64, forward_control: f64, forward_rotation: f64, forward: f64 };

/// os limites com a margem mínima `margin_min` (fração da CMA), o C_L de pouso `lift_fraction` C_Lmax e o curso
/// `elevator_max` (rad)
pub fn scissorLimits(probe: *const Probe, airspeed: f64, margin_min: f64, lift_fraction: f64, elevator_max: f64, rotation_speed: f64, pitch_acceleration: f64) Limits {
    const neutral = probe.fraction(probe.neutralPoint(airspeed));
    var out: Limits = .{ .neutral = neutral, .aft = neutral - 100 * margin_min, .forward_control = std.math.nan(f64), .forward_rotation = 0, .forward = 0 };
    const lift_max = probe.liftMax(airspeed, -elevator_max);
    if (alphaForLift(probe, airspeed, lift_fraction * lift_max, -elevator_max)) |alpha| {
        const point: V3 = .{ 0, 0, probe.cg[2] };
        const at = probe.coeffs(airspeed, alpha, point, .{ .elevator = -elevator_max });
        out.forward_control = probe.fraction(point[0] + probe.chord * at.Cm / at.CN);
    }
    const gear = probe.mainGear();
    const dynamic_pressure = 0.5 * probe.density * rotation_speed * rotation_speed;
    const at_gear = probe.coeffs(rotation_speed, 0, gear, .{ .elevator = -elevator_max });
    const pushing = probe.thrust(rotation_speed, 1);
    const dx = probe.cg[0] - gear[0];
    const dz = probe.cg[2] - gear[2];
    const inertia = probe.inertia[1][1] + probe.mass * (dx * dx + dz * dz);
    const cg_limit = gear[0] + (dynamic_pressure * probe.area * probe.chord * at_gear.Cm + pushing[0] * (pushing[1] - gear[2]) - inertia * pitch_acceleration * rad) / probe.weight;
    out.forward_rotation = probe.fraction(cg_limit);
    // `np.nanmax`: o maior dos dois que existe
    out.forward = if (std.math.isNan(out.forward_control)) out.forward_rotation else @max(out.forward_control, out.forward_rotation);
    return out;
}

/// o menor S_h/S com o dianteiro ≤ `cg_forward` e o traseiro ≥ `cg_aft` (interpolado); NaN se nenhum serve
/// (`min_tail`)
pub fn minTail(ratios: []const f64, forward: []const f64, aft: []const f64, cg_forward: f64, cg_aft: f64) f64 {
    for (ratios, 0..) |ratio, i| {
        if (!(forward[i] <= cg_forward and aft[i] >= cg_aft)) continue;
        if (i == 0) return ratio;
        const before = @min(cg_forward - forward[i - 1], aft[i - 1] - cg_aft);
        const now = @min(cg_forward - forward[i], aft[i] - cg_aft);
        return if (now != before) ratios[i - 1] + (0 - before) * (ratio - ratios[i - 1]) / (now - before) else ratio;
    }
    return std.math.nan(f64);
}

// ------------------------------------------------------------------ comandos

/// o tempo para inclinar até `angle` (rad) com a resposta de 1ª ordem φ(t) = P_ss [t − τ_R (1 − e^{−t/τ_R})]
/// (Sadraey, Aircraft Design, cap. 12; a conferir no PDF), por bisseção até 100 s; ∞ se não chega (`time_to_bank`)
pub fn timeToBank(rate: f64, time_constant: f64, angle: f64) f64 {
    const inf = std.math.inf(f64);
    if (rate <= 0) return inf;
    const bank = struct {
        fn at(steady: f64, tau: f64, target: f64, time: f64) f64 {
            return steady * (time - tau * (1 - @exp(-time / tau))) - target;
        }
    };
    var low: f64 = 0;
    var high: f64 = 100;
    if (bank.at(rate, time_constant, angle, high) < 0) return inf;
    for (0..80) |_| {
        const middle = 0.5 * (low + high);
        if (bank.at(rate, time_constant, angle, middle) < 0) low = middle else high = middle;
    }
    return 0.5 * (low + high);
}

/// a asa para o aileron: C_Lα (1/rad, 3D), o comprimento da semiasa e as seções (y, corda) em ordem
pub const WingStrip = struct { lift_slope: f64, length: f64, y: []const f64, chord: []const f64 };

/// o aileron atual: o começo e o fim (fração da semiasa) e o τ
pub const Aileron = struct { start: f64, end: f64, effectiveness: f64 };

/// as cordas do aileron testadas e onde ele começa
pub const aileron_chords = [_]f64{ 0.15, 0.20, 0.25, 0.30 };
pub const aileron_starts = blk: { // `np.linspace(0.30, 0.90, 13)`, com os mesmos arredondamentos
    var starts: [13]f64 = undefined;
    for (&starts, 0..) |*start, i| start.* = 0.30 + @as(f64, @floatFromInt(i)) * ((0.90 - 0.30) / 12.0);
    break :blk starts;
};

/// o dimensionamento do aileron pela teoria das faixas: C_lδa = (2 C_Lα τ / (S b)) ∫ c(y) y dy, P_ss = −(C_lδa /
/// C_lp) δa (2V / b), τ_R = −2V I_xx / (q S b² C_lp) (Sadraey, Aircraft Design, cap. 12; Roskam, Airplane Design VI;
/// a conferir no PDF), como `aileron_sizing`
pub const RollSizing = struct {
    damping: f64, // C_lp (1/rad)
    time_constant: f64, // τ_R (s)
    times: [aileron_chords.len][aileron_starts.len]f64, // tempo para inclinar (s)
    rates: [aileron_chords.len][aileron_starts.len]f64, // P_ss (°/s)
    best_start: [aileron_chords.len]f64, // o começo mais externo que cumpre (NaN: nenhum)
    current_rate: f64 = std.math.nan(f64), // °/s, do aileron atual pelo núcleo
    current_time: f64 = std.math.nan(f64),
};

/// o aileron a V com o curso `aileron_max` (rad) e o fim em `end` (fração da semiasa); `chord_effectiveness`: o τ
/// de cada corda de `aileron_chords`; `requirement`: (φ °, t s)
pub fn aileronSizing(probe: *const Probe, airspeed: f64, wing: WingStrip, aileron_max: f64, end: f64, chord_effectiveness: [aileron_chords.len]f64, requirement: [2]f64, current: ?Aileron) RollSizing {
    const scale = 2 * airspeed / probe.span;
    const damping = rollDamping(probe, airspeed);
    const dynamic_pressure = 0.5 * probe.density * airspeed * airspeed;
    const roll_inertia = probe.inertia[0][0];
    const time_constant = if (damping < 0) -2 * airspeed * roll_inertia / (dynamic_pressure * probe.area * probe.span * probe.span * damping) else std.math.inf(f64);
    var out: RollSizing = .{ .damping = damping, .time_constant = time_constant, .times = undefined, .rates = undefined, .best_start = undefined };
    const samples = 400;
    for (aileron_chords, 0..) |_, k| {
        out.best_start[k] = std.math.nan(f64);
        for (aileron_starts, 0..) |start, j| {
            const moment = chordMoment(wing, samples, start * wing.length, end * wing.length, 0);
            const control_slope = 2 * wing.lift_slope * chord_effectiveness[k] / (probe.area * probe.span) * moment;
            const rate = -(control_slope / damping) * aileron_max * scale;
            out.rates[k][j] = rate / rad;
            out.times[k][j] = timeToBank(rate, time_constant, requirement[0] * rad);
            if (out.times[k][j] <= requirement[1]) out.best_start[k] = start;
        }
    }
    if (current != null) {
        const control_slope = derivative(probe, airspeed, 2 * rad, .aileron, null, step).Cl;
        const rate = -(control_slope / damping) * aileron_max * scale;
        out.current_rate = rate / rad;
        out.current_time = timeToBank(rate, time_constant, requirement[0] * rad);
    }
    return out;
}

/// ∫ c(y) y dy de `from` a `to` pelos trapézios em `samples` pontos de 0 ao comprimento (os que caem na faixa,
/// com a folga `slack`), como o `_trapz` com a máscara de `aileron_sizing`
fn chordMoment(wing: WingStrip, comptime samples: usize, from: f64, to: f64, slack: f64) f64 {
    var sum: f64 = 0;
    var previous: ?[2]f64 = null;
    for (0..samples) |i| {
        const station = wing.length * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples - 1));
        if (station < from - slack or station > to + slack) continue;
        const value = interpolate(wing.y, wing.chord, station) * station;
        if (previous) |last| sum += 0.5 * (last[1] + value) * (station - last[0]);
        previous = .{ station, value };
    }
    return sum;
}

/// interpolação linear com as pontas presas (`np.interp`)
pub fn interpolate(xs: []const f64, ys: []const f64, x: f64) f64 {
    if (x <= xs[0]) return ys[0];
    for (xs[1..], ys[1..], 1..) |high_x, high_y, i| {
        if (x <= high_x) {
            const low_x = xs[i - 1];
            return if (high_x > low_x) ys[i - 1] + (x - low_x) / (high_x - low_x) * (high_y - ys[i - 1]) else high_y;
        }
    }
    return ys[ys.len - 1];
}

/// as cordas móveis testadas no profundor e no leme (fração da corda da superfície)
pub const control_ratios = blk: {
    var ratios: [15]f64 = undefined;
    for (&ratios, 0..) |*ratio, i| ratio.* = 0.15 + (0.5 - 0.15) * @as(f64, @floatFromInt(i)) / 14.0;
    break :blk ratios;
};

/// o profundor: δe (°) para equilibrar o C_L de pouso com o CG mais dianteiro e para rodar em V_R, por corda móvel
/// (C_mδe ∝ τ_e), como `elevator_sizing`; `scale`: τ(corda) / τ atual de cada `control_ratios`
pub const ElevatorSizing = struct {
    landing: [control_ratios.len]f64, // NaN sem α para o C_L de pouso
    rotation: [control_ratios.len]f64,
    landing_now: f64, // com a corda atual
    rotation_now: f64,
    smallest: f64, // a menor corda que cumpre os dois (NaN: nenhuma)
};

/// o profundor com o CG em `cg_forward` (% CMA)
pub fn elevatorSizing(probe: *const Probe, landing_speed: f64, rotation_speed: f64, cg_forward: f64, landing_lift: f64, elevator_max: f64, pitch_acceleration: f64, scale: [control_ratios.len]f64) ElevatorSizing {
    const nan = std.math.nan(f64);
    var out: ElevatorSizing = .{ .landing = @splat(nan), .rotation = undefined, .landing_now = nan, .rotation_now = 0, .smallest = nan };
    const x_forward = probe.xAt(cg_forward);
    const ref: V3 = .{ x_forward, 0, probe.cg[2] };
    if (alphaForLift(probe, landing_speed, landing_lift, 0)) |alpha| {
        const at = probe.coeffs(landing_speed, alpha, ref, .{});
        const slope = derivative(probe, landing_speed, alpha, .elevator, ref, step).Cm;
        for (scale, 0..) |factor, i| out.landing[i] = -at.Cm / (slope * factor) / rad;
        out.landing_now = -at.Cm / slope / rad;
    }
    const gear = probe.mainGear();
    const dynamic_pressure = 0.5 * probe.density * rotation_speed * rotation_speed;
    const at_gear = probe.coeffs(rotation_speed, 0, gear, .{});
    const slope_gear = derivative(probe, rotation_speed, 0, .elevator, gear, step).Cm;
    const pushing = probe.thrust(rotation_speed, 1);
    const dx = x_forward - gear[0];
    const dz = probe.cg[2] - gear[2];
    const inertia = probe.inertia[1][1] + probe.mass * (dx * dx + dz * dz);
    const reference = dynamic_pressure * probe.area * probe.chord;
    const moment = reference * at_gear.Cm - probe.weight * (x_forward - gear[0]) + pushing[0] * (pushing[1] - gear[2]);
    const need = inertia * pitch_acceleration * rad - moment;
    for (scale, 0..) |factor, i| out.rotation[i] = need / (reference * slope_gear * factor) / rad;
    out.rotation_now = need / (reference * slope_gear) / rad;
    const limit = elevator_max / rad;
    for (control_ratios, 0..) |ratio, i| {
        const landing_ok = std.math.isNan(out.landing_now) or @abs(out.landing[i]) <= limit;
        if (landing_ok and @abs(out.rotation[i]) <= limit) {
            out.smallest = ratio;
            break;
        }
    }
    return out;
}

/// o leme: δr (°) para o vento cruzado, δr = C_nβ β / C_nδr com β = atan(V_w / V) (FAR 23.233), e com o motor mais
/// afastado parado, δr = T y_T / (q S b C_nδr) em V_MC, como `rudder_sizing`
pub const RudderSizing = struct {
    yaw_stability: f64, // C_nβ
    control_slope: f64, // C_nδr
    sideslip: f64, // β do vento (°)
    crosswind: [control_ratios.len]f64,
    crosswind_now: f64,
    engine_out: ?[control_ratios.len]f64 = null,
    engine_out_now: f64 = std.math.nan(f64),
    smallest: f64,
};

/// o leme na aproximação a `approach_speed` com o vento `crosswind`; `engine`: (tração em V_MC, y) do motor mais
/// afastado quando há mais de um
pub fn rudderSizing(probe: *const Probe, approach_speed: f64, crosswind: f64, minimum_control_speed: f64, rudder_max: f64, scale: [control_ratios.len]f64, engine: ?[2]f64) RudderSizing {
    const alpha = 2 * rad;
    const yaw_stability = derivative(probe, approach_speed, alpha, .beta, null, step).Cn;
    const control_slope = derivative(probe, approach_speed, alpha, .rudder, null, step).Cn;
    const sideslip = std.math.atan2(crosswind, approach_speed);
    var out: RudderSizing = .{
        .yaw_stability = yaw_stability,
        .control_slope = control_slope,
        .sideslip = sideslip / rad,
        .crosswind = undefined,
        .crosswind_now = @abs(yaw_stability * sideslip / control_slope) / rad,
        .smallest = std.math.nan(f64),
    };
    for (scale, 0..) |factor, i| out.crosswind[i] = @abs(yaw_stability * sideslip / (control_slope * factor)) / rad;
    if (engine) |unit| {
        const dynamic_pressure = 0.5 * probe.density * minimum_control_speed * minimum_control_speed;
        var stopped: [control_ratios.len]f64 = undefined;
        var nearest: usize = 0;
        for (scale, 0..) |factor, i| {
            stopped[i] = @abs(unit[0] * unit[1] / (dynamic_pressure * probe.area * probe.span * control_slope * factor)) / rad;
            if (@abs(factor - 1) < @abs(scale[nearest] - 1)) nearest = i;
        }
        out.engine_out = stopped;
        out.engine_out_now = stopped[nearest];
    }
    const limit = rudder_max / rad;
    for (control_ratios, 0..) |ratio, i| {
        const engine_ok = if (out.engine_out) |stopped| stopped[i] <= limit else true;
        if (out.crosswind[i] <= limit and engine_ok) {
            out.smallest = ratio;
            break;
        }
    }
    return out;
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

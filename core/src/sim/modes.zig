//! Os modos dinâmicos do avião equilibrado e as qualidades de voo: o que a aba Estabilidade mostra depois da
//! estática. É a conta de `aerosim/stability/dynamic.py` e `criteria.py`, aqui no núcleo para a aba em Zig rodar sem
//! Python.
//!
//! O modelo linear do núcleo (`linear.linearize`, corpo rígido com os comandos congelados) separa em dois blocos de
//! quatro estados. O longitudinal (u, w, q, θ) dá o curto período (o par de ω_n maior) e a fugóide; o
//! látero-direcional (v, p, r, φ) dá o dutch roll (o par complexo), o rolamento (a raiz real mais rápida) e a espiral
//! (a mais lenta) (Etkin e Reid, Dynamics of Flight, cap. 6; Nelson, Flight Stability and Automatic Control, cap. 5).
//! Um polo λ = σ ± iω tem
//!
//!   ω_n = |λ|,   ζ = −σ / ω_n,   período = 2π / ω,   t_½ = ln 2 / (−σ),   t_2 = ln 2 / σ,   τ = −1 / σ (real)
//!
//! Os limites de nível 1, 2 e 3 são os da MIL-F-8785C (1980) por classe de avião (I pequeno e leve, II médio, III
//! grande, IV alta manobrabilidade) e fase de voo (A manobras e precisão, B subida, cruzeiro e descida, C decolagem,
//! aproximação e pouso); os números das tabelas estão em `dynamic.py` e `criteria.py`, a conferir no PDF da norma.
const std = @import("std");
const linalg = @import("../math/linalg.zig");
const linear = @import("linear.zig");
const types = @import("../types.zig");
const state = @import("state.zig");

/// os cinco modos do avião rígido
pub const Mode = enum { short_period, phugoid, dutch_roll, roll, spiral };

/// um polo e o que se lê dele (a metade de cima do plano: `imag` ≥ 0)
pub const Pole = struct {
    real: f64,
    imag: f64,
    natural: f64, // ω_n (rad/s)
    damping: f64, // ζ
    period: f64, // s; NaN se real
    half_time: f64, // tempo para a metade (s); NaN se cresce
    double_time: f64, // tempo para o dobro (s); NaN se amortece
    time_constant: f64, // τ = −1/σ das raízes reais (s); NaN se complexo

    /// o polo λ = real + i·imag, como `_mode` de `dynamic.py`
    pub fn of(real: f64, imag: f64) Pole {
        const natural = std.math.hypot(real, imag);
        const nan = std.math.nan(f64);
        const inf = std.math.inf(f64);
        return .{
            .real = real,
            .imag = @abs(imag),
            .natural = natural,
            .damping = if (natural > 0) -real / natural else nan,
            .period = if (@abs(imag) > 1e-9) 2 * std.math.pi / @abs(imag) else nan,
            .half_time = if (real < 0) @log(2.0) / -real else if (real > 0) nan else inf,
            .double_time = if (real > 0) @log(2.0) / real else if (real < 0) nan else inf,
            .time_constant = if (@abs(imag) < 1e-9 and real != 0) -1 / real else nan,
        };
    }

    /// é um par complexo (oscila)
    pub fn oscillates(pole: Pole) bool {
        return pole.imag > 0;
    }
};

/// os modos achados (null: o bloco não tinha esse modo)
pub const Modes = std.EnumArray(Mode, ?Pole);

const longitudinal = [4]usize{ 0, 2, 4, 7 }; // u, w, q, θ
const lateral = [4]usize{ 1, 3, 5, 6 }; // v, p, r, φ

/// os modos da matriz A do modelo linear (por linhas, `linear.nl` estados), como `modes` de `dynamic.py`; null se o
/// autovalor não converge
pub fn classify(matrix: *const [linear.nl * linear.nl]f64) ?Modes {
    var found = Modes.initFill(null);
    var lon_real: [4]f64 = undefined;
    var lon_imag: [4]f64 = undefined;
    var lat_real: [4]f64 = undefined;
    var lat_imag: [4]f64 = undefined;
    if (!blockEigen(matrix, longitudinal, &lon_real, &lon_imag)) return null;
    if (!blockEigen(matrix, lateral, &lat_real, &lat_imag)) return null;

    // longitudinal: os pares (só a metade de cima) por |λ|, as raízes reais por |λ|
    var pairs: [4]usize = undefined;
    var pair_count: usize = 0;
    var reals: [4]usize = undefined;
    var real_count: usize = 0;
    for (0..4) |i| {
        if (lon_imag[i] > 1e-9) {
            pairs[pair_count] = i;
            pair_count += 1;
        } else if (@abs(lon_imag[i]) <= 1e-9) {
            reals[real_count] = i;
            real_count += 1;
        }
    }
    var size: [4]f64 = undefined;
    for (0..4) |i| size[i] = std.math.hypot(lon_real[i], lon_imag[i]);
    std.mem.sort(usize, pairs[0..pair_count], &size, bySize);
    std.mem.sort(usize, reals[0..real_count], &size, bySize);
    const lon = struct {
        fn pole(real: *const [4]f64, imag: *const [4]f64, i: usize) Pole {
            return Pole.of(real[i], imag[i]);
        }
    };
    if (pair_count == 2) {
        found.set(.phugoid, lon.pole(&lon_real, &lon_imag, pairs[0]));
        found.set(.short_period, lon.pole(&lon_real, &lon_imag, pairs[1]));
    } else if (pair_count == 1) {
        // um par: o de ω_n maior entre ele e as raízes reais decide
        var largest_real: f64 = 0;
        for (reals[0..real_count]) |i| largest_real = @max(largest_real, size[i]);
        if (size[pairs[0]] > largest_real) {
            found.set(.short_period, lon.pole(&lon_real, &lon_imag, pairs[0]));
            if (real_count > 0) found.set(.phugoid, lon.pole(&lon_real, &lon_imag, reals[0]));
        } else {
            found.set(.phugoid, lon.pole(&lon_real, &lon_imag, pairs[0]));
            if (real_count > 0) found.set(.short_period, lon.pole(&lon_real, &lon_imag, reals[real_count - 1]));
        }
    } else if (real_count > 0) {
        found.set(.phugoid, lon.pole(&lon_real, &lon_imag, reals[0]));
        found.set(.short_period, lon.pole(&lon_real, &lon_imag, reals[real_count - 1]));
    }

    // látero-direcional: o primeiro par é o dutch roll; das reais (por σ), a mais negativa é o rolamento
    real_count = 0;
    var dutch: ?usize = null;
    for (0..4) |i| {
        if (lat_imag[i] > 1e-9) {
            if (dutch == null) dutch = i;
        } else if (@abs(lat_imag[i]) <= 1e-9) {
            reals[real_count] = i;
            real_count += 1;
        }
    }
    std.mem.sort(usize, reals[0..real_count], &lat_real, bySize);
    if (dutch) |i| found.set(.dutch_roll, Pole.of(lat_real[i], lat_imag[i]));
    if (real_count > 0) {
        found.set(.roll, Pole.of(lat_real[reals[0]], lat_imag[reals[0]]));
        if (real_count > 1) found.set(.spiral, Pole.of(lat_real[reals[real_count - 1]], lat_imag[reals[real_count - 1]]));
    }
    return found;
}

fn blockEigen(matrix: *const [linear.nl * linear.nl]f64, block: [4]usize, real: *[4]f64, imag: *[4]f64) bool {
    var part: [4][4]f64 = undefined;
    for (block, 0..) |row, i| for (block, 0..) |col, j| {
        part[i][j] = matrix[row * linear.nl + col];
    };
    return linalg.generalEigen(4, &part, 4, real, imag);
}

fn bySize(values: *const [4]f64, a: usize, b: usize) bool {
    return values[a] < values[b];
}

/// os autovalores do modelo linear com o líquido dos tanques oscilando (`linear.linearizeSlosh`, como
/// `slosh_eigs_at`); devolve quantos, ou null se a trimagem ou o autovalor falham
pub fn liquidPoles(params: *const types.Params, flags: *const state.Flags, airspeed: f64, real: *[linear.nl_slosh]f64, imag: *[linear.nl_slosh]f64) ?usize {
    const model = linear.linearizeSlosh(params, flags, airspeed);
    if (model.ok == 0) return null;
    const size: usize = @intCast(model.n);
    var matrix: [linear.nl_slosh][linear.nl_slosh]f64 = undefined;
    for (0..size) |i| for (0..size) |j| {
        matrix[i][j] = model.A[i * linear.nl_slosh + j];
    };
    if (!linalg.generalEigen(linear.nl_slosh, &matrix, size, real, imag)) return null;
    return size;
}

// ------------------------------------------------------------------ critérios

/// classe do avião na MIL-F-8785C
pub const Class = enum { I, II, III, IV };
/// fase de voo na MIL-F-8785C
pub const Phase = enum { A, B, C };
/// os critérios que se ligam e desligam (os grupos de `criteria.py`)
pub const Check = enum { short_period, phugoid, dutch_roll, roll_time_constant, spiral, roll };

/// o ângulo (°) e o tempo (s) da rolagem pedida, por classe e fase (`ROLL_REQ` de `controls.py`)
pub fn rollRequirement(class: Class, phase: Phase) [2]f64 {
    const table = [4][3][2]f64{
        .{ .{ 60, 1.3 }, .{ 60, 1.7 }, .{ 30, 1.3 } },
        .{ .{ 45, 1.4 }, .{ 45, 1.9 }, .{ 30, 1.8 } },
        .{ .{ 30, 1.5 }, .{ 30, 2.0 }, .{ 30, 2.5 } },
        .{ .{ 90, 1.3 }, .{ 90, 1.7 }, .{ 30, 1.0 } },
    };
    return table[@intFromEnum(class)][@intFromEnum(phase)];
}

/// os limites de aprovação (nível 1), de uma norma ou do usuário (`Criteria` de `criteria.py`)
pub const Criteria = struct {
    short_period_min: f64 = 0.30,
    short_period_max: f64 = 2.00,
    phugoid_min: f64 = 0.04,
    dutch_damping_min: f64 = 0.08,
    dutch_product_min: f64 = 0.15, // ζ ω_n
    dutch_natural_min: f64 = 0.4,
    roll_tau_max: f64 = 1.4, // s
    spiral_double_min: f64 = 20.0, // s
    roll_angle: f64 = 60.0, // °
    roll_time: f64 = 1.7, // s
    from_norm: bool = false, // MIL-F-8785C: com os níveis 2 e 3
    class: Class = .I,
    phase: Phase = .B,
    used: std.EnumSet(Check) = .initFull(),

    /// o critério está ligado
    pub fn on(criteria: *const Criteria, check: Check) bool {
        return criteria.used.contains(check);
    }
};

/// o nível 1 da MIL-F-8785C para a classe e a fase (`mil_8785c`)
pub fn mil8785c(class: Class, phase: Phase) Criteria {
    const approach_or_maneuver = phase != .B;
    const light = class == .I or class == .IV;
    const dutch: [3]f64 = switch (phase) {
        .A => if (light) .{ 0.19, 0.35, 1.0 } else .{ 0.19, 0.35, 0.5 },
        .B => .{ 0.08, 0.15, 0.4 },
        .C => if (light) .{ 0.08, 0.15, 1.0 } else .{ 0.08, 0.10, 0.4 },
    };
    const slow_roll = phase == .B or (phase == .A and (class == .II or class == .III)) or (phase == .C and class == .III);
    const roll = rollRequirement(class, phase);
    return .{
        .short_period_min = if (approach_or_maneuver) 0.35 else 0.30,
        .short_period_max = if (approach_or_maneuver) 1.30 else 2.00,
        .phugoid_min = 0.04,
        .dutch_damping_min = dutch[0],
        .dutch_product_min = dutch[1],
        .dutch_natural_min = dutch[2],
        .roll_tau_max = if (slow_roll) 1.4 else 1.0,
        .spiral_double_min = if (approach_or_maneuver) 12.0 else 20.0,
        .roll_angle = roll[0],
        .roll_time = roll[1],
        .from_norm = true,
        .class = class,
        .phase = phase,
    };
}

/// sem norma: todos os critérios desligados (só os valores)
pub fn noCriteria() Criteria {
    return .{ .used = .initEmpty() };
}

/// uma linha da avaliação: o valor (três no dutch roll: ζ, ζ ω_n, ω_n), se passa (null: desligado) e o nível da
/// norma (null sem norma; 4 = pior que o 3)
pub const Row = struct {
    check: Check,
    values: [3]f64 = .{ 0, 0, 0 },
    value_count: usize = 1,
    ok: ?bool = null,
    level: ?u8 = null,
};

/// as linhas de cada modo achado contra os critérios, como `evaluate` de `criteria.py`
pub fn evaluate(found: *const Modes, criteria: *const Criteria, out: *[5]Row) []Row {
    var count: usize = 0;
    const inf = std.math.inf(f64);
    const phase = criteria.phase;
    if (found.get(.short_period)) |pole| if (pole.imag > 0) {
        const damping = pole.damping;
        var row: Row = .{ .check = .short_period, .values = .{ damping, 0, 0 }, .ok = criteria.short_period_min <= damping and damping <= criteria.short_period_max };
        if (criteria.from_norm and std.math.isFinite(damping)) {
            const bands: [3][2]f64 = if (phase != .B) .{ .{ 0.35, 1.30 }, .{ 0.25, 2.00 }, .{ 0.15, 1e9 } } else .{ .{ 0.30, 2.00 }, .{ 0.20, 2.00 }, .{ 0.15, 1e9 } };
            row.level = 4;
            for (bands, 1..) |band, level| if (band[0] <= damping and damping <= band[1]) {
                row.level = @intCast(level);
                break;
            };
        }
        out[count] = row;
        count += 1;
    };
    if (found.get(.phugoid)) |pole| {
        const damping = pole.damping;
        var row: Row = .{ .check = .phugoid, .values = .{ damping, 0, 0 }, .ok = damping >= criteria.phugoid_min };
        if (criteria.from_norm) row.level = if (damping >= 0.04) 1 else if (damping >= 0) 2 else if (pole.double_time >= 55) 3 else 4;
        out[count] = row;
        count += 1;
    }
    if (found.get(.dutch_roll)) |pole| {
        const damping = pole.damping;
        const natural = pole.natural;
        var row: Row = .{
            .check = .dutch_roll,
            .values = .{ damping, damping * natural, natural },
            .value_count = 3,
            .ok = damping >= criteria.dutch_damping_min and damping * natural >= criteria.dutch_product_min and natural >= criteria.dutch_natural_min,
        };
        if (criteria.from_norm) {
            const light = criteria.class == .I or criteria.class == .IV;
            const required: [3]f64 = switch (phase) {
                .A => if (light) .{ 0.19, 0.35, 1.0 } else .{ 0.19, 0.35, 0.5 },
                .B => .{ 0.08, 0.15, 0.4 },
                .C => if (light) .{ 0.08, 0.15, 1.0 } else .{ 0.08, 0.10, 0.4 },
            };
            const level_1 = damping >= required[0] and damping * natural >= required[1] and natural >= required[2];
            const level_2 = damping >= 0.02 and damping * natural >= 0.05 and natural >= 0.4;
            const level_3 = damping >= 0.0 and natural >= 0.4;
            row.level = if (level_1) 1 else if (level_2) 2 else if (level_3) 3 else 4;
        }
        out[count] = row;
        count += 1;
    }
    if (found.get(.roll)) |pole| if (std.math.isFinite(pole.time_constant)) {
        const tau = if (pole.time_constant > 0) pole.time_constant else inf;
        var row: Row = .{ .check = .roll_time_constant, .values = .{ tau, 0, 0 }, .ok = tau <= criteria.roll_tau_max };
        if (criteria.from_norm) {
            const class = criteria.class;
            const slow = phase == .B or (phase == .A and (class == .II or class == .III)) or (phase == .C and class == .III);
            const limit: [3]f64 = if (slow) .{ 1.4, 3.0, 10.0 } else .{ 1.0, 1.4, 10.0 };
            row.level = 4;
            for (limit, 1..) |bound, level| if (tau <= bound) {
                row.level = @intCast(level);
                break;
            };
        }
        out[count] = row;
        count += 1;
    };
    if (found.get(.spiral)) |pole| {
        const doubling = if (std.math.isFinite(pole.double_time)) pole.double_time else inf; // estável: passa
        var row: Row = .{ .check = .spiral, .values = .{ doubling, 0, 0 }, .ok = doubling >= criteria.spiral_double_min };
        if (criteria.from_norm) {
            const limit: [3]f64 = if (phase != .B) .{ 12.0, 8.0, 4.0 } else .{ 20.0, 8.0, 4.0 };
            row.level = 4;
            for (limit, 1..) |bound, level| if (doubling >= bound) {
                row.level = @intCast(level);
                break;
            };
        }
        out[count] = row;
        count += 1;
    }
    for (out[0..count]) |*row| if (!criteria.on(row.check)) {
        row.ok = null;
        row.level = null;
    };
    return out[0..count];
}

/// a linha de um critério na avaliação, se o modo existe
pub fn passes(found: *const Modes, criteria: *const Criteria, check: Check) bool {
    var rows: [5]Row = undefined;
    for (evaluate(found, criteria, &rows)) |row| if (row.check == check) return row.ok orelse false;
    return false;
}

// ------------------------------------------------------------------ resposta no tempo

/// a entrada de um canal: um doublet (+a e −a, cada um por `width`) ou um pulso, a partir de `start`
pub const Input = struct {
    amplitude: f64,
    channel: usize, // 0 δe, 1 δa, 2 δr, 3 acelerador
    start: f64 = 0.5,
    width: f64,
    doublet: bool,

    /// o vetor dos comandos em t
    pub fn at(input: Input, time: f64) [linear.nu]f64 {
        var command = [_]f64{0} ** linear.nu;
        if (input.start <= time and time < input.start + input.width) {
            command[input.channel] = input.amplitude;
        } else if (input.doublet and input.start + input.width <= time and time < input.start + 2 * input.width) {
            command[input.channel] = -input.amplitude;
        }
        return command;
    }
};

/// a resposta linear δẋ = A δx + B δu a partir do repouso, por RK4 com passo `time_step`, como `response` de
/// `dynamic.py`; escreve um estado por passo em `out` (o primeiro é zero) e devolve quantos
pub fn respond(model: *const linear.LinModel, input: Input, duration: f64, time_step: f64, out: [][linear.nl]f64) usize {
    const steps = @min(@as(usize, @intFromFloat(duration / time_step)) + 1, out.len);
    var now = [_]f64{0} ** linear.nl;
    if (steps == 0) return 0;
    out[0] = now;
    const derivative = struct {
        fn at(lin: *const linear.LinModel, entry: Input, time: f64, x: [linear.nl]f64) [linear.nl]f64 {
            const command = entry.at(time);
            var rate: [linear.nl]f64 = undefined;
            for (0..linear.nl) |i| {
                var sum: f64 = 0;
                for (0..linear.nl) |j| sum += lin.A[i * linear.nl + j] * x[j];
                for (0..linear.nu) |j| sum += lin.B[i * linear.nu + j] * command[j];
                rate[i] = sum;
            }
            return rate;
        }
    };
    for (1..steps) |k| {
        const time = @as(f64, @floatFromInt(k - 1)) * time_step;
        const k1 = derivative.at(model, input, time, now);
        const k2 = derivative.at(model, input, time + time_step / 2, axpy(now, time_step / 2, k1));
        const k3 = derivative.at(model, input, time + time_step / 2, axpy(now, time_step / 2, k2));
        const k4 = derivative.at(model, input, time + time_step, axpy(now, time_step, k3));
        for (0..linear.nl) |i| now[i] += time_step / 6 * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]);
        out[k] = now;
    }
    return steps;
}

fn axpy(base: [linear.nl]f64, scale: f64, direction: [linear.nl]f64) [linear.nl]f64 {
    var sum: [linear.nl]f64 = undefined;
    for (0..linear.nl) |i| sum[i] = base[i] + scale * direction[i];
    return sum;
}

test "o polo dá ω_n, ζ, período e os tempos" {
    const pole = Pole.of(-1, 2);
    try std.testing.expectApproxEqAbs(@as(f64, @sqrt(5.0)), pole.natural, 1e-12);
    try std.testing.expectApproxEqAbs(1.0 / @sqrt(5.0), pole.damping, 1e-12);
    try std.testing.expectApproxEqAbs(std.math.pi, pole.period, 1e-12);
    try std.testing.expectApproxEqAbs(@log(2.0), pole.half_time, 1e-12);
    try std.testing.expect(std.math.isNan(pole.time_constant));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), Pole.of(-2, 0).time_constant, 1e-12);
}

test "a MIL-F-8785C: classe I, fase B, e os níveis" {
    const criteria = mil8785c(.I, .B);
    try std.testing.expectEqual(@as(f64, 0.30), criteria.short_period_min);
    try std.testing.expectEqual(@as(f64, 60), criteria.roll_angle);
    var found = Modes.initFill(null);
    found.set(.short_period, Pole.of(-3, 4)); // ζ = 0,6: nível 1
    found.set(.spiral, Pole.of(0.05, 0)); // dobra em 13,9 s: nível 2
    var rows: [5]Row = undefined;
    const evaluated = evaluate(&found, &criteria, &rows);
    try std.testing.expectEqual(@as(usize, 2), evaluated.len);
    try std.testing.expectEqual(@as(?u8, 1), evaluated[0].level);
    try std.testing.expectEqual(@as(?bool, false), evaluated[1].ok);
    try std.testing.expectEqual(@as(?u8, 2), evaluated[1].level);
    std.testing.refAllDecls(@This());
}

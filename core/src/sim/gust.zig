//! Resposta no tempo a uma rajada, em voo nivelado reto: o avião sai equilibrado em `airspeed` e `height`, a rajada
//! "1 − cos" (`physics/atmosphere.zig`) chega em `start` segundos com a parte vertical e a lateral pedidas, e o voo
//! segue por `span` segundos. Os comandos ficam no equilíbrio (manche fixo, como nos modos de Etkin e Reid, cap. 6) ou
//! com o piloto automático. O líquido dos tanques pode estar livre (pêndulo de Abramson, NASA SP-106) ou travado.
//!
//! Com a carga LAPES no avião (`params.payload`), `release` pede a soltura num instante: a carga desliza pela rampa
//! (`physics/mass.zig`, `payload`) e sai, e o voo segue só com o resto da massa e a dinâmica dela.
//!
//! O registro sai em `log` (as mesmas linhas do `runner.run`): ângulo de ataque, arfagem, rolamento, o xCG
//! (`xcg`, que anda quando o líquido balança) e o ângulo de cada pêndulo (`slosh_x`, `slosh_y`).
const std = @import("std");
const types = @import("../types.zig");
const runner = @import("runner.zig");
const trim = @import("trim.zig");
const state = @import("state.zig");
const linear = @import("linear.zig");
const vec = @import("../math/vec.zig");
const propulsion = @import("../physics/propulsion.zig");
const atmosphere = @import("../physics/atmosphere.zig");
const linalg = @import("../math/linalg.zig");

/// o caso: o voo, a rajada e o que fica livre
pub const Case = struct {
    airspeed: f64 = 15, // m/s
    height: f64 = 50, // m
    vertical: f64 = 2, // m/s, para cima
    lateral: f64 = 0, // m/s, da esquerda para a direita (para +y do corpo)
    duration: f64 = 1, // s, o tempo da rajada 1 − cos
    start: f64 = 1, // s, quando a rajada chega
    span: f64 = 10, // s, o tempo máximo de voo registrado
    settle: bool = true, // para antes, quando a resposta estabiliza depois da rajada (`settled`)
    liquid_free: bool = true,
    autopilot: bool = false, // falso: manche fixo no equilíbrio
    release: ?f64 = null, // s, quando se pede a soltura da LAPES (nulo: ela fica no avião, se houver)
};

pub const Error = runner.StateError || runner.ConfigError || error{BufferFull};

/// prepara o voo do caso no avião de `inst`: o trecho reto, a rajada, o líquido e o equilíbrio de partida
pub fn begin(inst: *runner.Instance, case: Case) Error!void {
    const params = &inst.p;
    const length = case.airspeed * (case.span + 5.0) * 2.0;
    params.n_seg = 1;
    params.seg[0] = .{ .L = length, .h0 = case.height, .h1 = case.height, .V0 = case.airspeed, .V1 = case.airspeed };
    params.n_event = 1;
    params.event[0] = .{ .kind = types.event_gust, .seg = 0, .s = case.airspeed * case.start };
    params.n_pad = 0;
    params.env.Vw10 = 0; // ar parado: só a rajada mexe
    params.env.gust_on = 1;
    params.env.gust_T = case.duration;
    params.env.gust_U = .{ 0, case.lateral, -case.vertical }; // NED: para cima é −z; lateral no rumo norte é +leste
    params.slosh_on = @intFromBool(case.liquid_free);
    params.stop_t = case.span;
    params.stop_takeoff = 0;
    params.pilot = .{};
    try runner.configure(inst);
    try runner.resetAir(inst, 0);
    if (!case.autopilot) holdFullTrim(inst, case.airspeed);
    restLiquid(inst);
}

/// manche fixo no equilíbrio completo (`linear.linearize`: α, δe, acelerador e também φ, δa e δr, que o torque e o
/// giroscópico dos motores pedem). Sem o látero-direcional equilibrado, o avião rolaria sozinho desde o começo, antes
/// da rajada
fn holdFullTrim(inst: *runner.Instance, airspeed: f64) void {
    const params = &inst.p;
    const full = linear.linearize(params, &inst.r.f, airspeed);
    if (full.ok == 0) {
        const point = trim.solve(trim.Ctx.init(params, &inst.r.f), types.trim_level, airspeed, 1.0, null);
        params.pilot = .{ .manual = 1, .de = point.de, .thr = point.thr };
        return;
    }
    params.pilot = .{ .manual = 1, .de = full.de, .da = full.da, .dr = full.dr, .thr = full.thr };
    const state_vector = &inst.r.x;
    state_vector[state.index(.roll)] = full.phi;
    state_vector[state.index(.pitch)] = full.theta;
    state_vector[state.index(.vel_x)] = airspeed * @cos(full.alpha);
    state_vector[state.index(.vel_y)] = 0;
    state_vector[state.index(.vel_z)] = airspeed * @sin(full.alpha);
    const relative = vec.V3{ airspeed * @cos(full.alpha), 0, airspeed * @sin(full.alpha) };
    for (params.prop[0..@intCast(params.n_prop)], 0..) |*prop_unit, i| state_vector[state.rps(i)] = propulsion.equilibriumRps(params, prop_unit, relative, full.thr);
}

/// o líquido começa parado no equilíbrio: o pêndulo pendurado na gravidade aparente, que no voo equilibrado é o próprio
/// peso visto do corpo, g (−sen θ, sen φ cos θ, cos φ cos θ) (a mesma conta de `linear.linearizeSlosh`). Sem isto o
/// pêndulo sai de 0° e balança antes da rajada chegar.
fn restLiquid(inst: *runner.Instance) void {
    const state_vector = &inst.r.x;
    const pitch = state_vector[state.index(.pitch)];
    const roll = state_vector[state.index(.roll)];
    const down = @cos(roll) * @cos(pitch);
    for (0..@intCast(inst.p.n_tank)) |i| {
        state_vector[state.sx(i)] = std.math.atan2(-@sin(pitch), down);
        state_vector[state.sy(i)] = std.math.atan2(@sin(roll) * @cos(pitch), down);
        state_vector[state.sxd(i)] = 0;
        state_vector[state.syd(i)] = 0;
    }
}

/// avança até `seconds` segundos de voo (uma fatia, para a tela não parar), somando as linhas em `rows`; verdadeiro
/// quando o caso acabou
pub fn advance(inst: *runner.Instance, case: Case, log: []types.LogRow, rows: *usize, seconds: f64) Error!bool {
    var until = @min(inst.r.t + seconds, case.span) + 1e-9;
    const pending = if (case.release) |moment| inst.p.pilot.drop == 0 and inst.r.f.released == 0 and moment < case.span else false;
    if (pending) until = @min(until, case.release.? + 1e-9); // a fatia para no instante da soltura
    var count: usize = 0;
    const status = runner.run(inst, until, log[rows.*..], &count);
    rows.* += count;
    if (pending and inst.r.t >= case.release.?) inst.p.pilot.drop = 1; // o runner solta no passo seguinte
    const dropped = case.release == null or inst.r.f.released != 0 or inst.p.payload.enabled == 0;
    return switch (status) {
        .buffer_full => error.BufferFull,
        .chunk => inst.r.t >= case.span or (case.settle and dropped and inst.r.t > case.start + case.duration and
            settled(log[0..rows.*], @intCast(inst.p.n_tank), inst.p.dtlog)),
        else => true,
    };
}

/// a janela olhada para dizer que estabilizou e o quanto cada grandeza ainda pode variar nela
pub const settle_window = 1.0; // s
const settle_alpha = 0.05 * std.math.pi / 180.0; // rad
const settle_rate = 0.5 * std.math.pi / 180.0; // rad/s, de p, q e r
const settle_liquid = 0.1 * std.math.pi / 180.0; // rad, de cada pêndulo
const settle_cg = 0.05e-3; // m, do xCG

/// a resposta estabilizou: no último `settle_window` o ângulo de ataque, o líquido e o xCG quase não mudam e as taxas
/// de rotação são pequenas. A fugóide e a espiral, lentas, seguem depois disso; o que acabou foi a resposta rápida
/// (curto período, dutch roll, rolamento e o balanço do líquido)
pub fn settled(log: []const types.LogRow, n_tanks: usize, log_step: f64) bool {
    const window: usize = @intFromFloat(@ceil(settle_window / log_step));
    if (log.len < window + 1) return false;
    const recent = log[log.len - window ..];
    var low = recent[0];
    var high = recent[0];
    for (recent) |row| {
        if (@abs(row.p) > settle_rate or @abs(row.q) > settle_rate or @abs(row.r) > settle_rate) return false;
        low.alpha = @min(low.alpha, row.alpha);
        high.alpha = @max(high.alpha, row.alpha);
        low.xcg = @min(low.xcg, row.xcg);
        high.xcg = @max(high.xcg, row.xcg);
        for (0..n_tanks) |i| {
            low.slosh_x[i] = @min(low.slosh_x[i], row.slosh_x[i]);
            high.slosh_x[i] = @max(high.slosh_x[i], row.slosh_x[i]);
            low.slosh_y[i] = @min(low.slosh_y[i], row.slosh_y[i]);
            high.slosh_y[i] = @max(high.slosh_y[i], row.slosh_y[i]);
        }
    }
    if (high.alpha - low.alpha > settle_alpha or high.xcg - low.xcg > settle_cg) return false;
    for (0..n_tanks) |i| {
        if (high.slosh_x[i] - low.slosh_x[i] > settle_liquid or high.slosh_y[i] - low.slosh_y[i] > settle_liquid) return false;
    }
    return true;
}

/// o caso inteiro de uma vez (os testes e quem já está numa thread); devolve quantas linhas escreveu em `log`
pub fn respond(inst: *runner.Instance, case: Case, log: []types.LogRow) Error!usize {
    try begin(inst, case);
    var rows: usize = 0;
    while (!try advance(inst, case, log, &rows, case.span)) {}
    return rows;
}

/// a rajada no instante `time`, para o gráfico: (para cima, para a direita) em m/s, a mesma 1 − cos que o voo sente
/// (`atmosphere.wind`, com o ar parado em volta); `start` é quando ela chegou (`inst.r.tg`, ou o pedido)
pub fn gustSpeed(params: *const types.Params, time: f64, start: f64) [2]f64 {
    var calm = params.env;
    calm.Vw10 = 0;
    const wind = atmosphere.wind(&calm, time, 0, start);
    return .{ -wind[2], wind[1] };
}

/// os modos de um avião rígido (Etkin e Reid, cap. 6) e o do líquido, que é o que sobra com os pêndulos soltos
pub const Mode = enum { short_period, phugoid, dutch_roll, roll, spiral, liquid };

/// os polos do avião equilibrado em voo nivelado: os autovalores do modelo linear (`linear.linearize`, o corpo
/// rígido, com o líquido travado onde está) ou, com `liquid_free` e tanques, do modelo com os pêndulos do líquido
/// (`linear.linearizeSlosh`). λ = σ ± iω: σ < 0 amortece, σ > 0 cresce. Cada polo leva o modo dele
pub const Poles = struct {
    ok: bool = false,
    count: usize = 0,
    real: [linear.nl_slosh]f64 = undefined,
    imag: [linear.nl_slosh]f64 = undefined,
    mode: [linear.nl_slosh]Mode = undefined,

    /// o polo de maior parte real (o modo menos estável)
    pub fn leastStable(set: *const Poles) usize {
        var worst: usize = 0;
        for (0..set.count) |i| if (set.real[i] > set.real[worst]) {
            worst = i;
        };
        return worst;
    }

    /// a maior parte real
    pub fn largestReal(set: *const Poles) f64 {
        return set.real[set.leastStable()];
    }
};

/// os polos com a configuração e os estados de `flags` (com `released` ligado, sem a LAPES)
pub fn poles(params: *const types.Params, flags: *const state.Flags, airspeed: f64, liquid_free: bool) Poles {
    var out: Poles = .{};
    const rigid = linear.linearize(params, flags, airspeed);
    if (rigid.ok == 0) return out;
    var matrix: [linear.nl_slosh][linear.nl_slosh]f64 = undefined;
    if (liquid_free and params.n_tank > 0 and params.slosh_on != 0) {
        const model = linear.linearizeSlosh(params, flags, airspeed);
        if (model.ok == 0) return out;
        out.count = @intCast(model.n);
        for (0..out.count) |i| for (0..out.count) |j| {
            matrix[i][j] = model.A[i * linear.nl_slosh + j];
        };
    } else {
        out.count = linear.nl;
        for (0..out.count) |i| for (0..out.count) |j| {
            matrix[i][j] = rigid.A[i * linear.nl + j];
        };
    }
    out.ok = linalg.generalEigen(linear.nl_slosh, &matrix, out.count, &out.real, &out.imag);
    if (out.ok) nameModes(&rigid.A, &out);
    return out;
}

/// dá o modo de cada polo: os oito do corpo rígido saem dos blocos longitudinal (u, w, q, θ) e látero-direcional
/// (v, p, r, φ) desacoplados, com a regra da Estabilidade em Python (`aerosim/stability/dynamic.py`, `modes`); cada um
/// fica com o polo mais perto dele no modelo inteiro, e o que sobra é o líquido
fn nameModes(rigid: *const [linear.nl * linear.nl]f64, out: *Poles) void {
    var reference_real: [linear.nl]f64 = undefined;
    var reference_imag: [linear.nl]f64 = undefined;
    var reference_mode: [linear.nl]Mode = undefined;
    const longitudinal = [4]usize{ 0, 2, 4, 7 };
    const lateral = [4]usize{ 1, 3, 5, 6 };
    for ([_][4]usize{ longitudinal, lateral }, 0..) |block, b| {
        var matrix: [4][4]f64 = undefined;
        for (block, 0..) |row, i| for (block, 0..) |col, j| {
            matrix[i][j] = rigid[row * linear.nl + col];
        };
        var real: [4]f64 = undefined;
        var imag: [4]f64 = undefined;
        if (!linalg.generalEigen(4, &matrix, 4, &real, &imag)) {
            for (0..out.count) |i| out.mode[i] = .liquid;
            return;
        }
        var modes: [4]Mode = undefined;
        if (b == 0) longitudinalModes(&real, &imag, &modes) else lateralModes(&real, &imag, &modes);
        for (0..4) |i| {
            reference_real[4 * b + i] = real[i];
            reference_imag[4 * b + i] = imag[i];
            reference_mode[4 * b + i] = modes[i];
        }
    }
    var taken = [_]bool{false} ** linear.nl_slosh;
    for (0..out.count) |i| out.mode[i] = .liquid;
    for (0..linear.nl) |r| {
        var nearest: ?usize = null;
        var distance = std.math.inf(f64);
        for (0..out.count) |i| {
            if (taken[i]) continue;
            const gap = std.math.hypot(out.real[i] - reference_real[r], out.imag[i] - reference_imag[r]);
            if (gap < distance) {
                distance = gap;
                nearest = i;
            }
        }
        if (nearest) |i| {
            taken[i] = true;
            out.mode[i] = reference_mode[r];
        }
    }
}

/// u, w, q, θ: os dois de |λ| maior são o curto período e os dois menores, a fugóide (com dois pares, o par de ω
/// maior é o curto período; com um par e duas raízes reais, o par vai para o lado do |λ| dele)
fn longitudinalModes(real: *const [4]f64, imag: *const [4]f64, modes: *[4]Mode) void {
    var size: [4]f64 = undefined;
    for (0..4) |i| size[i] = std.math.hypot(real[i], imag[i]);
    var order = [4]usize{ 0, 1, 2, 3 };
    std.mem.sort(usize, &order, &size, ascending);
    modes[order[0]] = .phugoid;
    modes[order[1]] = .phugoid;
    modes[order[2]] = .short_period;
    modes[order[3]] = .short_period;
}

/// v, p, r, φ: o par complexo é o dutch roll; das raízes reais, a mais negativa é o rolamento e a mais perto de zero,
/// a espiral (sem par, as duas do meio ficam com o dutch roll)
fn lateralModes(real: *const [4]f64, imag: *const [4]f64, modes: *[4]Mode) void {
    var order = [4]usize{ 0, 1, 2, 3 };
    std.mem.sort(usize, &order, real, ascending);
    var complex_count: usize = 0;
    for (0..4) |i| {
        if (@abs(imag[i]) > 1e-9) {
            modes[i] = .dutch_roll;
            complex_count += 1;
        }
    }
    if (complex_count == 0) {
        modes[order[0]] = .roll;
        modes[order[1]] = .dutch_roll;
        modes[order[2]] = .dutch_roll;
        modes[order[3]] = .spiral;
        return;
    }
    var first = true;
    for (order) |i| {
        if (@abs(imag[i]) > 1e-9) continue;
        modes[i] = if (first) .roll else .spiral;
        first = false;
    }
}

/// ordena índices pelo valor que cada um aponta
fn ascending(values: *const [4]f64, a: usize, b: usize) bool {
    return values[a] < values[b];
}

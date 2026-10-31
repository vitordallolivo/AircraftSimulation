//! Resposta no tempo a uma rajada, em voo nivelado reto: o avião sai equilibrado em `airspeed` e `height`, a rajada
//! "1 − cos" (`physics/atmosphere.zig`) chega em `start` segundos com a parte vertical e a lateral pedidas, e o voo
//! segue por `span` segundos. Os comandos ficam no equilíbrio (manche fixo, como nos modos de Etkin e Reid, cap. 6) ou
//! com o piloto automático. O líquido dos tanques pode estar livre (pêndulo de Abramson, NASA SP-106) ou travado.
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
    const until = @min(inst.r.t + seconds, case.span) + 1e-9;
    var count: usize = 0;
    const status = runner.run(inst, until, log[rows.*..], &count);
    rows.* += count;
    return switch (status) {
        .buffer_full => error.BufferFull,
        .chunk => inst.r.t >= case.span or (case.settle and inst.r.t > case.start + case.duration and
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

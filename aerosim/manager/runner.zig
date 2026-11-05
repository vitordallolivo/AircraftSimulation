//! Corrida orientada em Zig (o par de `runner.py`): o avião voa no núcleo (`core/src/sim/runner.zig`) até uma
//! condição de parada, com o registro guardado numa lista que cresce. É a ferramenta que as análises em Zig usam para
//! voar: a decolagem, a missão e as curvas.
const std = @import("std");
const core = @import("aerosim");

const types = core.types;

/// a condição de parada: a primeira que acontecer
pub const Stop = struct {
    time: ?f64 = null, // tempo absoluto (s)
    segment: ?i32 = null, // ao entrar no segmento k
    autopilot: bool = false, // quando o piloto automático liga
    takeoff: bool = false, // no fim da decolagem (takeoff.h_end acima do chão)

    /// escreve a parada nos parâmetros (o configure do núcleo não lê estes campos)
    pub fn apply(stop: Stop, params: *types.Params) void {
        params.stop_t = stop.time orelse -1;
        params.stop_seg = stop.segment orelse -1;
        params.stop_autop = @intFromBool(stop.autopilot);
        params.stop_takeoff = @intFromBool(stop.takeoff);
    }
};

/// como uma corrida acabou
pub const Flight = struct {
    status: core.runner.Status,
    events: types.Events,
    time: f64,
};

const rows_per_call = 2048;

/// voa até a parada; com `log`, junta as linhas do registro no fim dela (na memória `memory`)
pub fn fly(instance: *core.runner.Instance, stop: Stop, memory: std.mem.Allocator, log: ?*std.ArrayList(types.LogRow)) !Flight {
    stop.apply(&instance.p);
    var status: core.runner.Status = undefined;
    while (true) {
        var written: usize = 0;
        if (log) |rows| {
            try rows.ensureUnusedCapacity(memory, rows_per_call);
            status = core.runner.run(instance, std.math.inf(f64), rows.unusedCapacitySlice(), &written);
            rows.items.len += written;
        } else status = core.runner.run(instance, std.math.inf(f64), &.{}, &written);
        if (status != .buffer_full and status != .chunk) break;
    }
    return .{ .status = status, .events = instance.r.ev, .time = instance.r.t };
}

/// o nome da situação, como o Python escreve (`RunStatus`)
pub fn statusName(status: core.runner.Status) []const u8 {
    return switch (status) {
        .not_ready => "NOT_READY",
        .chunk => "CHUNK",
        .stopped => "STOPPED",
        .completed => "COMPLETED",
        .timeout => "TIMEOUT",
        .crashed => "CRASHED",
        .buffer_full => "BUFFER_FULL",
    };
}

//! O manager das análises em Zig (o par de `manager.py`): a lista das análises, na ordem das subabas, e a busca pelo
//! nome. O contrato que cada análise segue está em `aerosim/interfaces/simulation.zig`; cada análise mora em
//! `manager/simulations/`, ao lado do `.py` da mesma área (a Estabilidade em `stability.zig`).
const std = @import("std");
const simulation = @import("simulation");
const stability = @import("simulations/stability.zig");
const thrust = @import("simulations/thrust.zig");
const envelope = @import("simulations/envelope.zig");
const performance = @import("simulations/performance.zig");

pub const Simulation = simulation.Simulation;
pub const Run = simulation.Run;
pub const Values = simulation.Values;
pub const GridEdit = simulation.GridEdit;

/// as análises em Zig, na ordem das subabas: um tipo por análise, com a interface de `simulation.check`
pub const analyses = .{ stability.DynamicStability, thrust.Thrust, envelope.Envelope, performance.Performance };

/// a tabela que a tela usa, montada das `analyses`
pub const all = blk: {
    var table: [analyses.len]Simulation = undefined;
    for (analyses, 0..) |Analysis, i| table[i] = simulation.register(Analysis);
    break :blk table;
};

/// a análise em Zig com este nome
pub fn find(name: []const u8) ?*const Simulation {
    for (&all) |*registered| if (std.mem.eql(u8, registered.name, name)) return registered;
    return null;
}

test "a tabela vem das análises" {
    try std.testing.expectEqual(analyses.len, all.len);
    try std.testing.expect(find("estabilidade_dinamica") != null);
    _ = stability;
    _ = thrust;
    _ = envelope;
    _ = performance;
    _ = @import("takeoff_opt.zig");
    _ = @import("analysis.zig");
    _ = @import("flightplots.zig");
}

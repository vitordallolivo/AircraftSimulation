//! O exemplo do README de `interfaces/`: quem implementa o contrato das análises hoje, e em que aba cada uma entra.
//! `cd aerosim && python -m ziglang build exemplo -Dexemplo=interfaces`
const std = @import("std");
const manager = @import("manager");

pub fn main() !void {
    for (&manager.all) |*analysis| { // cada uma é um `simulation.Simulation`, montado por `simulation.register`
        std.debug.print("{s}: {s} → {s}\n", .{ analysis.name, analysis.area, analysis.title });
    }
}

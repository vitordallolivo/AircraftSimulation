//! O exemplo do README do núcleo: os limites de tamanho e os canais que cada corrida grava.
//! `cd core && python -m ziglang build exemplo -Dexemplo=.`
const std = @import("std");
const core = @import("aerosim");

pub fn main() !void {
    const limits = core.limits;
    std.debug.print("superfícies {d}, motores {d}, trens {d}, tanques {d}, pernas {d}, instâncias {d}, estados {d}\n", .{
        limits.max_surfaces, limits.max_props, limits.max_gear, limits.max_tanks, limits.max_segments, limits.max_instances, core.state.nx,
    });
    const channels = @typeInfo(core.types.LogRow).@"struct".fields;
    std.debug.print("{d} canais:", .{channels.len});
    inline for (channels[0..8]) |channel| std.debug.print(" {s}", .{channel.name});
    std.debug.print(" ...\n", .{});
}

//! O exemplo do README de `modifiers/`: o fator do efeito solo em três alturas e a esteira da hélice ligada.
//! `cd core && python -m ziglang build exemplo -Dexemplo=modifiers`
const std = @import("std");
const core = @import("aerosim");

var instance: core.runner.Instance = .{};

/// o C_L do avião a 10 m/s e α = 4°, com a hélice dando 25 N e 0,4 N·m
fn liftWithThrust() f64 {
    const thrusts = [_]f64{25.0};
    const torques = [_]f64{0.4};
    const coefficients = core.aero.coeffsEnv(&instance.p, 10.0, 4.0 * std.math.rad_per_deg, 0, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ &thrusts, &torques });
    return coefficients.CL;
}

pub fn main() !void {
    core.test_aircraft(&instance.p);
    std.debug.print("efeito solo: {s}; φ a 0,1, 0,5 e 2 m (b = 2,2 m):", .{@tagName(instance.p.ground)});
    for ([_]f64{ 0.1, 0.5, 2.0 }) |height| std.debug.print(" {d:.3}", .{core.modifiers.ground.mccormick(height, 2.2)});
    std.debug.print("\n", .{});

    try core.runner.configure(&instance);
    const without = liftWithThrust();
    instance.p.n_mod = 1;
    instance.p.mods[0] = .{ .kind = .slipstream_disk }; // liga a esteira da hélice
    instance.p.mods[0].params[0] = 1; // ganho da velocidade axial (1 = a teoria; `SlipstreamSettings`)
    instance.p.mods[0].params[1] = 1; // ganho do giro
    try core.runner.configure(&instance);
    std.debug.print("C_L com a hélice puxando: sem a esteira {d:.3}, com a esteira {d:.3}\n", .{ without, liftWithThrust() });
}

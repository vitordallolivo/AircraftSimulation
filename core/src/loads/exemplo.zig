//! O exemplo do README de `loads/`: o mesmo avião a 14 m/s e α = 4° pelas faixas e pela linha sustentadora.
//! `cd core && python -m ziglang build exemplo -Dexemplo=loads`
const std = @import("std");
const core = @import("aerosim");

var instance: core.runner.Instance = .{};

pub fn main() !void {
    core.test_aircraft(&instance.p); // o monomotor dos testes
    try core.runner.configure(&instance); // monta também a geometria da linha sustentadora
    const alpha = 4.0 * std.math.rad_per_deg;
    const strips = core.aero.coeffs(&instance.p, 14.0, alpha, 0, .{ 0, 0, 0 }, .{ 0, 0, 0 });
    const line = core.llt.coeffs(&instance.p, 14.0, alpha, 0, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, 100, null);
    std.debug.print("C_L do avião: faixas {d:.3}, linha sustentadora {d:.3}\n", .{ strips.CL, line.CL });
    std.debug.print("C_L da asa:   faixas {d:.3}, linha sustentadora {d:.3}\n", .{ strips.CL_wing, line.CL_wing });
}

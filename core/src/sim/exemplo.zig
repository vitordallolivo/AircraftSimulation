//! O exemplo do README de `sim/`: vinte segundos de decolagem, o equilíbrio a 14 m/s e os modos de voo ali.
//! `cd core && python -m ziglang build exemplo -Dexemplo=sim`
const std = @import("std");
const core = @import("aerosim");

var instance: core.runner.Instance = .{}; // grande: fica fora da pilha
var log: [4096]core.types.LogRow = undefined;

pub fn main() !void {
    const deg = std.math.rad_per_deg;
    core.test_aircraft(&instance.p); // o monomotor dos testes, com a missão que começa na cabeceira
    try core.runner.configure(&instance);
    try core.runner.resetGround(&instance);
    var rows: usize = 0;
    _ = core.runner.run(&instance, 20.0, &log, &rows);
    std.debug.print("20 s depois: V = {d:.1} m/s  h = {d:.1} m\n", .{ log[rows - 1].Va, log[rows - 1].h });

    const point = core.trim.solve(core.trim.Ctx.init(&instance.p, &instance.r.f), .level, 14, 1, null);
    std.debug.print("trimado a 14 m/s: α = {d:.2}°  δe = {d:.2}°  acelerador = {d:.2}\n", .{ point.alpha / deg, point.de / deg, point.thr });

    const model = core.linear.linearize(&instance.p, &instance.r.f, 14);
    var real: [core.linear.nl]f64 = undefined;
    var imaginary: [core.linear.nl]f64 = undefined;
    var matrix: [core.linear.nl][core.linear.nl]f64 = @bitCast(model.A);
    _ = core.linalg.generalEigen(core.linear.nl, &matrix, core.linear.nl, &real, &imaginary);
    std.debug.print("autovalores de A:", .{});
    for (real, imaginary) |re, im| std.debug.print(" {d:.2}{s}{d:.2}j", .{ re, if (im < 0) "-" else "+", @abs(im) });
    std.debug.print("\n", .{});
}

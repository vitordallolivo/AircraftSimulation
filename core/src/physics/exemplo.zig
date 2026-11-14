//! O exemplo do README de `physics/`: os coeficientes, o motor com o acelerador cheio e a massa do avião dos testes.
//! `cd core && python -m ziglang build exemplo -Dexemplo=physics`
const std = @import("std");
const core = @import("aerosim");

var instance: core.runner.Instance = .{};

pub fn main() !void {
    core.test_aircraft(&instance.p);
    try core.runner.configure(&instance); // aero.init, propulsion.init e as massas, uma vez
    const center = core.trim.Ctx.init(&instance.p, &instance.r.f).rcg; // os momentos no CG
    const coefficients = core.aero.coeffs(&instance.p, 12.0, 0.05, 0, center, .{ 0, 0, 0 }); // V, α (rad), β
    std.debug.print("C_L {d:.3}  C_D {d:.3}  C_m {d:.3}  C_Di {d:.3}\n", .{ coefficients.CL, coefficients.CD, coefficients.Cm, coefficients.CDi });

    const motor = core.propulsion.point(&instance.p, &instance.p.prop[0], 12.0, 1.0); // motor 0 a 12 m/s, acelerador cheio
    const zero_state = [_]f64{0} ** core.state.nx;
    const body = core.mass.compute(instance.ctx(), &zero_state);
    std.debug.print("{d:.0} rpm  T {d:.1} N  P no eixo {d:.0} W | massa {d:.2} kg\n", .{ motor.rpm, motor.T, motor.P_shaft, body.m });
}

//! O exemplo do README de `control/`: os ganhos ajustados para 14 m/s e a missão do avião dos testes com eles.
//! `cd core && python -m ziglang build exemplo -Dexemplo=control`
const std = @import("std");
const core = @import("aerosim");

var instance: core.runner.Instance = .{};
var log: [8192]core.types.LogRow = undefined;

pub fn main() !void {
    core.test_aircraft(&instance.p);
    try core.runner.configure(&instance);
    const tuned = core.autotune.tune(&instance.p, &instance.r.f, 14.0); // os ganhos de instance.p.ap para 14 m/s
    std.debug.print("arfagem {d}, rolagem {d}, guinada {d}, velocidade {d}; período curto {d:.1} → {d:.1} rad/s\n", .{
        tuned.pitch, tuned.roll, tuned.yaw, tuned.speed, tuned.w_sp_open, tuned.w_sp,
    });
    try core.runner.configure(&instance);
    try core.runner.resetGround(&instance);
    var rows: usize = 0;
    const status = core.runner.run(&instance, 30.0, &log, &rows);
    var highest: f64 = 0;
    for (log[0..rows]) |row| highest = @max(highest, row.h);
    std.debug.print("{s}; altura máxima {d:.1} m em {d:.0} s\n", .{ @tagName(status), highest, log[rows - 1].t });
}

//! O exemplo do README de `geometry/`: um avião de cinco peças conferido parado e girado 12° na decolagem.
//! `cd core && python -m ziglang build exemplo -Dexemplo=geometry`
const std = @import("std");
const geometry = @import("aerosim").geometry;

/// uma caixa alinhada aos eixos do corpo: centro, meias medidas e o componente de onde vem
fn box(center: [3]f64, half: [3]f64, owner: i32) geometry.Part {
    return .{ .kind = .box, .owner = owner, .c = center, .h = half };
}

pub fn main() !void {
    var scene: geometry.Scene = .{ .n = 5, .pivot = .{ 0, 0, 0.2 }, .n_att = 2, .att = .{ 0, 12.0 * std.math.rad_per_deg } };
    scene.parts[0] = box(.{ 0, 0, 0 }, .{ 0.4, 0.06, 0.06 }, 0); // fuselagem, nariz em x = 0,4
    scene.parts[1] = .{ .kind = .disc, .owner = 1, .c = .{ 0.42, 0, 0 }, .h = .{ 0.15, 0, 0 } }; // hélice no nariz
    scene.parts[2] = box(.{ 0, 0, -0.07 }, .{ 0.1, 0.8, 0.01 }, 2); // asa em cima da fuselagem
    scene.parts[3] = box(.{ -1.0, 0, 0 }, .{ 0.1, 0.25, 0.05 }, 3); // cauda sem tubo até a fuselagem
    scene.parts[4] = box(.{ 0.41, 0, 0 }, .{ 0.02, 0.02, 0.02 }, 1); // o motor, preso ao nariz
    const report = geometry.check(&scene);
    std.debug.print("passou: {}, hélice acertando peças: {d}, pedaços soltos: {d}\n", .{ report.ok == 1, report.n_hits, report.n_groups });
    std.debug.print("folga ao chão parado {d:.3} m, girado 12° {d:.3} m (peça {d})\n", .{ report.low[0], report.low[1], report.low_part[1] });
}

//! O exemplo do README de `structures/`: uma longarina com alma de balsa e dois tubos de carbono sob 60 N·m.
//! `cd core && python -m ziglang build exemplo -Dexemplo=structures`
const std = @import("std");
const section = @import("aerosim").structures.section;

pub fn main() !void {
    const materials = [_]section.Material{
        .{ .modulus = 3e9, .density = 160, .tension = 12e6, .compression = 10e6 }, // 0: alma (balsa)
        .{ .modulus = 110e9, .density = 1550, .tension = 1200e6, .compression = 1000e6 }, // 1: tubos (carbono)
    };
    const parts = [_]section.SectionPart{
        section.SectionPart.rectangle(0, 0.003, 0.04, 0), // alma de 3 × 40 mm
        section.SectionPart.tube(1, 0.008, 0.006, 0.017), // tubo de 8/6 mm em cima
        section.SectionPart.tube(1, 0.008, 0.006, -0.017), // e embaixo
    };
    const properties = try section.properties(&materials, &parts);
    var stresses: [parts.len]section.PartStress = undefined;
    try section.stresses(&materials, &parts, properties, 60.0, &stresses);
    std.debug.print("EI = {d:.0} N·m², {d:.0} g/m\n", .{ properties.bending, properties.mass_per_length * 1e3 });
    for ([_][]const u8{ "alma", "tubo de cima", "tubo de baixo" }, stresses) |name, stress| {
        std.debug.print("{s}: {d:.1} / {d:.1} MPa, margem {d:.2}\n", .{ name, stress.top / 1e6, stress.bottom / 1e6, stress.margin });
    }
}

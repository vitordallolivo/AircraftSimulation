//! O exemplo do README de `data/`: o mesmo caminho da tela para abrir um avião em .cfg ou .xlsx.
//! `cd aerosim && python -m ziglang build exemplo -Dexemplo=data`
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const data_sources = @import("data_sources");

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const memory = arena.allocator();
    for ([_][]const u8{ "../data/aircraft/flying_wing.cfg", "../data/aircraft/conventional.xlsx" }) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, memory, .limited(1 << 24));
        const json = try data_sources.aircraftJson(memory, path, bytes); // o formato sai da extensão
        var diagnosis: aircraft_model.aircraft.Diag = .{};
        var loaded = try aircraft_model.aircraft.parse(init.gpa, json, &diagnosis); // o mesmo .json de sempre
        defer loaded.deinit();
        const plane = &loaded.ac;
        std.debug.print("{s}: \"{s}\", {d} superfícies, {d} motor(es), massa base {d:.2} kg\n", .{
            std.fs.path.basename(path), plane.name, plane.surfaces.len, plane.propulsion.len, plane.mass.base_mass,
        });
    }
}

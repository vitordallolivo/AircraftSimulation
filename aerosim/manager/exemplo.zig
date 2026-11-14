//! O exemplo do README de `manager/`: o envelope de voo do avião de exemplo, pedido pelo nome da análise.
//! `cd aerosim && python -m ziglang build exemplo -Dexemplo=manager`
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const manager = @import("manager");
const simulation = @import("simulation");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();

    const envelope = manager.find("envelope").?; // a análise "Voo nivelado e envelopes"
    var run: simulation.Run = .{ .arena = .init(gpa), .aircraft = &loaded.ac, .io = init.io };
    defer run.arena.deinit();
    try envelope.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"h_step\": 500}"));
    while (!try envelope.advance(&run)) {} // a tela chama advance fora do laço do desenho, um pedaço por vez
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try envelope.result(&run, &written.writer); // o resultado em JSON: resumo, verificações e gráficos

    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
    defer outcome.deinit();
    const summary = outcome.value.object.get("summary").?.object;
    for ([_][]const u8{ "V_min_nivelado", "V_max_nivelado", "roc_max", "massa", "margem_estatica" }) |key| {
        std.debug.print("{s} = {s}\n", .{ key, summary.get(key).?.string });
    }
    std.debug.print("{d} gráficos, {d} verificações\n", .{ outcome.value.object.get("plots").?.array.items.len, outcome.value.object.get("checks").?.array.items.len });
}

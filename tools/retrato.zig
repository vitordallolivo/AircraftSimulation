//! O retrato numérico dos aviões de exemplo, para a regressão bit a bit (`zig build check`): cada avião de
//! `data/aircraft` (.json, .cfg, .xlsx) passa pelas análises do aerosim com os valores padrão, e o resultado de cada
//! uma sai numa linha `avião<TAB>análise<TAB>json`. O `check` roda isto na árvore atual e numa cópia da referência
//! (`git worktree`) e compara os números das duas. Compilado pelo `aerosim/build.zig` (`zig build retrato`), que
//! liga o núcleo e o manager daquela árvore.
//!
//!     zig build retrato -- <pasta dos aviões> <saída.txt> [--rapido]
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const manager = @import("manager");
const simulation = @import("simulation");
const data_sources = @import("data_sources");

/// as análises do retrato (da Missão, só o resumo e as verificações); `--rapido` fica só com as rápidas
const all_analyses = [_][]const u8{ "stability", "estabilidade_dinamica", "thrust", "envelope", "wings", "mission" };
const quick_analyses = [_][]const u8{ "stability", "thrust", "envelope" };

/// lê os argumentos, retrata cada avião e grava a saída
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("uso: zig build retrato -- <pasta dos aviões> <saída.txt> [--rapido]\n", .{});
        return error.MissingArgument;
    }
    const quick = args.len > 3 and std.mem.eql(u8, args[3], "--rapido");
    const analyses: []const []const u8 = if (quick) &quick_analyses else &all_analyses;

    var folder = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer folder.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var walker = folder.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const extension = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, extension, ".json") and !std.mem.eql(u8, extension, ".cfg") and !std.mem.eql(u8, extension, ".xlsx")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (names.items) |name| {
        try portrait(gpa, io, folder, name, analyses, &output.writer);
        std.debug.print("{s}\n", .{name});
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = output.written() });
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// as linhas de um avião: uma por análise (ou uma linha de erro, se o avião não abre ou a análise falha)
fn portrait(gpa: std.mem.Allocator, io: std.Io, folder: std.Io.Dir, name: []const u8, analyses: []const []const u8, out: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try folder.readFileAlloc(io, name, memory, .limited(1 << 26));
    const json = data_sources.aircraftJson(memory, name, bytes) catch |err| {
        try out.print("{s}\tabrir\t{{\"erro\": \"{s}\"}}\n", .{ name, @errorName(err) });
        return;
    };
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = aircraft_model.aircraft.parse(gpa, json, &diagnosis) catch |err| {
        try out.print("{s}\tabrir\t{{\"erro\": \"{s}\"}}\n", .{ name, @errorName(err) });
        return;
    };
    defer loaded.deinit();
    for (analyses) |analysis_name| {
        const registered = manager.find(analysis_name) orelse {
            try out.print("{s}\t{s}\t{{\"erro\": \"análise não existe nesta versão\"}}\n", .{ name, analysis_name });
            continue;
        };
        var run: simulation.Run = .{ .arena = .init(gpa), .aircraft = &loaded.ac, .io = io };
        defer run.arena.deinit();
        const result = runOne(registered, &run) catch |err| {
            try out.print("{s}\t{s}\t{{\"erro\": \"{s}: {s}\"}}\n", .{ name, analysis_name, @errorName(err), std.mem.sliceTo(&run.failure, 0) });
            continue;
        };
        // a Missão desenha o voo inteiro (dezenas de MB por avião): dela ficam só o resumo e as verificações
        var parsed = try std.json.parseFromSlice(std.json.Value, run.memory(), result, .{});
        if (std.mem.eql(u8, analysis_name, "mission")) _ = parsed.value.object.orderedRemove("plots");
        try out.print("{s}\t{s}\t{f}\n", .{ name, analysis_name, std.json.fmt(parsed.value, .{}) });
    }
}

/// roda uma análise até o fim, com os valores padrão, e devolve o resultado em JSON
fn runOne(registered: *const manager.Simulation, run: *simulation.Run) ![]const u8 {
    try registered.start(run, simulation.Values.fromRequest(run.memory(), "\"values\": {}"));
    while (!try registered.advance(run)) {}
    var written: std.Io.Writer.Allocating = .init(run.memory());
    try registered.result(run, &written.writer);
    return written.written();
}

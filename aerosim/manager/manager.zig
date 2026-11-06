//! O manager das análises em Zig (o par de `manager.py`): a lista das análises, na ordem das subabas, e a busca pelo
//! nome. O contrato que cada análise segue está em `aerosim/interfaces/simulation.zig`; cada análise mora em
//! `manager/simulations/`, ao lado do `.py` da mesma área (a Estabilidade em `stability.zig`).
const std = @import("std");
const simulation = @import("simulation");
/// a Estabilidade: a Montagem usa dela o que a aeronave tem (`Configuration`) e a geometria das caudas
pub const stability = @import("simulations/stability.zig");
/// rótulo, unidade, dica e opções dos campos do avião (o par de `form_meta.py`), para os formulários da tela
pub const form_meta = @import("form_meta.zig");
/// os avisos que a tela mostra na hora de rodar (a linha sustentadora numa asa curta)
pub const alerts = @import("alerts.zig");
const thrust = @import("simulations/thrust.zig");
const envelope = @import("simulations/envelope.zig");
const performance = @import("simulations/performance.zig");
const mission = @import("simulations/mission.zig");
const sizing = @import("simulations/sizing.zig");
const mdo = @import("simulations/mdo.zig");
const wings = @import("simulations/wings.zig");
const loads = @import("simulations/loads.zig");
const combined = @import("combined.zig");

/// "Voo nivelado e envelopes" com o desempenho da planilha (subida, planeio, curvas, V-n, bateria), que antes era a
/// subaba "Avião montado" e repetia o envelope, a potência e a subida
const Flight = combined.Combined(envelope.Envelope, performance.Performance, .{
    .name = "envelope",
    .title = "Voo nivelado e envelopes",
    .area = "Desempenho",
    .description = envelope.Envelope.description ++ " Junto, o desempenho da planilha: tração, ângulo de subida, planeio, envelope de curvas, V-n e bateria.",
    .second_group = "Desempenho da planilha",
    .skip_second = &.{ "env", "spot", "ssub" },
});

pub const Simulation = simulation.Simulation;
pub const Run = simulation.Run;
pub const Values = simulation.Values;
pub const GridEdit = simulation.GridEdit;

/// as análises em Zig, na ordem das subabas: um tipo por análise, com a interface de `simulation.check`
pub const analyses = .{ mdo.Mdo, sizing.Sizing, wings.Wings, loads.Loads, stability.Stability, stability.DynamicStability, thrust.Thrust, Flight, mission.Mission };

/// a tabela que a tela usa, montada das `analyses`
pub const all = blk: {
    var table: [analyses.len]Simulation = undefined;
    for (analyses, 0..) |Analysis, i| table[i] = simulation.register(Analysis);
    break :blk table;
};

/// o tipo de uma subaba: análise (do Python ou em Zig), etapa da sprint, ainda por fazer ou a Montagem
pub const TabKind = enum { simulation, stage, todo, assembly };

/// uma subaba da janela: o título, o tipo e o nome da análise ou da etapa ("" na Montagem e nas por fazer)
pub const Tab = struct { title: [:0]const u8, kind: TabKind, name: []const u8 = "" };

/// uma área da barra de cima e as subabas dela; `single` = uma página só, sem a barra de subabas
pub const Area = struct { title: [:0]const u8, single: bool = false, tabs: []const Tab };

/// as áreas e as subabas na ordem da GUI PyQt (`MainWindow.__init__`, o pedido "layout" de `aerosim/bridge.py`):
/// a janela abre sem o Python. As análises em Zig de uma área que não estão aqui (`analyses`) entram no fim dela
pub const layout = [_]Area{
    .{ .title = "Biblioteca", .tabs = &.{
        .{ .title = "Perfis", .kind = .stage, .name = "perfis" },
        .{ .title = "Motores", .kind = .stage, .name = "biblioteca_motores" },
        .{ .title = "Hélices", .kind = .stage, .name = "biblioteca_helices" },
    } },
    .{ .title = "Dimensionamento inicial", .tabs = &.{
        .{ .title = "Mini-MDO (otimizador)", .kind = .simulation, .name = "mdo" },
        .{ .title = "Diagrama de restrições", .kind = .simulation, .name = "sizing" },
    } },
    .{ .title = "Aerodinâmica", .tabs = &.{
        .{ .title = "Projetar", .kind = .stage, .name = "asa" },
        .{ .title = "Analisar", .kind = .simulation, .name = "wings" },
    } },
    .{ .title = "Estabilidade", .tabs = &.{
        .{ .title = "Empenagem e comandos", .kind = .stage, .name = "empenagem" },
        .{ .title = "Avião montado", .kind = .simulation, .name = "stability" },
    } },
    .{ .title = "Desempenho", .tabs = &.{
        .{ .title = "Motores e montagem", .kind = .stage, .name = "motores" },
        .{ .title = "Voo nivelado e envelopes", .kind = .simulation, .name = "envelope" },
        .{ .title = "Tração", .kind = .simulation, .name = "thrust" },
        .{ .title = "Missão", .kind = .simulation, .name = "mission" },
        // o estudo rápido da sprint (o ponto acoplado, sem 6GDL); o estudo no voo simulado é o modo da Missão
        .{ .title = "Estudo rápido (sprint)", .kind = .stage, .name = "estudo" },
    } },
    .{ .title = "Cargas", .single = true, .tabs = &.{.{ .title = "Cargas", .kind = .simulation, .name = "loads" }} },
    .{ .title = "Montagem", .single = true, .tabs = &.{.{ .title = "Montagem", .kind = .assembly }} },
};

/// a análise em Zig com este nome
pub fn find(name: []const u8) ?*const Simulation {
    for (&all) |*registered| if (std.mem.eql(u8, registered.name, name)) return registered;
    return null;
}

test "a tabela vem das análises" {
    try std.testing.expectEqual(analyses.len, all.len);
    try std.testing.expect(find("estabilidade_dinamica") != null);
    _ = alerts;
}

test "toda análise em Zig tem a área dela nas abas" {
    for (&all) |*registered| {
        var found = false;
        for (layout) |area| found = found or std.mem.eql(u8, area.title, registered.area);
        try std.testing.expect(found);
    }
}

// os testes de cada análise entram mesmo com -Dfiltro (um teste filtrado não analisa o que ele importa)
comptime {
    if (@import("builtin").is_test) {
        _ = stability;
        _ = thrust;
        _ = envelope;
        _ = performance;
        _ = mission;
        _ = sizing;
        _ = wings;
        _ = loads;
        _ = form_meta;
        _ = @import("takeoff_opt.zig");
        _ = @import("analysis.zig");
        _ = @import("flightplots.zig");
        _ = @import("simulations/aerodynamics.zig");
    }
}

test "Voo nivelado e envelopes junta o desempenho da planilha sem os gráficos repetidos" {
    const gpa = std.testing.allocator;
    const aircraft_model = @import("aircraft_model");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = find("envelope").?;
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, Values.fromRequest(run.memory(), "\"values\": {\"method\": \"planilha\"}"));
    var steps: usize = 0;
    while (!try registered.advance(&run)) steps += 1;
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
    defer parsed.deinit();
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    for (parsed.value.object.get("plots").?.array.items) |plot| try keys.append(gpa, plot.object.get("key").?.string);
    var has_vn = false;
    for (keys.items) |key| {
        try std.testing.expect(!std.mem.eql(u8, key, "env") and !std.mem.eql(u8, key, "spot") and !std.mem.eql(u8, key, "ssub"));
        has_vn = has_vn or std.mem.eql(u8, key, "snv");
    }
    try std.testing.expect(has_vn);
}

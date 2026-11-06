//! O manager das análises em Zig (o par de `manager.py`): a lista das análises, na ordem das subabas, e a busca pelo
//! nome. O contrato que cada análise segue está em `aerosim/interfaces/simulation.zig`; cada análise mora em
//! `manager/simulations/`, ao lado do `.py` da mesma área (a Estabilidade em `stability.zig`).
const std = @import("std");
const simulation = @import("simulation");
/// a Estabilidade: a Montagem usa dela o que a aeronave tem (`Configuration`) e a geometria das caudas
pub const stability = @import("simulations/stability.zig");
/// rótulo, unidade, dica e opções dos campos do avião (o par de `form_meta.py`), para os formulários da tela
pub const form_meta = @import("form_meta.zig");
const thrust = @import("simulations/thrust.zig");
const envelope = @import("simulations/envelope.zig");
const performance = @import("simulations/performance.zig");
const mission = @import("simulations/mission.zig");
const sizing = @import("simulations/sizing.zig");
const wings = @import("simulations/wings.zig");
const loads = @import("simulations/loads.zig");

pub const Simulation = simulation.Simulation;
pub const Run = simulation.Run;
pub const Values = simulation.Values;
pub const GridEdit = simulation.GridEdit;

/// as análises em Zig, na ordem das subabas: um tipo por análise, com a interface de `simulation.check`
pub const analyses = .{ sizing.Sizing, wings.Wings, loads.Loads, stability.Stability, stability.DynamicStability, thrust.Thrust, envelope.Envelope, performance.Performance, mission.Mission };

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
    .{ .title = "Dimensionamento inicial", .tabs = &.{
        .{ .title = "Mini-MDO (otimizador)", .kind = .todo },
        .{ .title = "Diagrama de restrições", .kind = .simulation, .name = "sizing" },
    } },
    .{ .title = "Aerodinâmica", .tabs = &.{
        .{ .title = "Perfis", .kind = .stage, .name = "perfis" },
        .{ .title = "Projetar", .kind = .stage, .name = "asa" },
        .{ .title = "Analisar", .kind = .simulation, .name = "wings" },
    } },
    .{ .title = "Estabilidade", .tabs = &.{
        .{ .title = "Empenagem e comandos", .kind = .stage, .name = "empenagem" },
        .{ .title = "Avião montado", .kind = .simulation, .name = "stability" },
    } },
    .{ .title = "Desempenho", .tabs = &.{
        .{ .title = "Motores e montagem", .kind = .stage, .name = "motores" },
        .{ .title = "Estudo e ponto de projeto", .kind = .todo },
        .{ .title = "Avião montado", .kind = .simulation, .name = "performance" },
        .{ .title = "Voo nivelado e envelopes", .kind = .simulation, .name = "envelope" },
        .{ .title = "Tração", .kind = .simulation, .name = "thrust" },
        .{ .title = "Missão", .kind = .simulation, .name = "mission" },
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
    }
}

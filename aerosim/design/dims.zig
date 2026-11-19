//! As dimensões do avião medidas a partir do CG de projeto, o par de `dims.py`: altura do CG, x_TDP, x_TDN, braço
//! da EH... Fica mais simples dimensionar assim, porque tudo vira "quanto à frente ou atrás, ao lado, acima ou abaixo
//! do CG". Cada linha tem o grupo, o item, a posição em relação ao CG nos eixos do corpo (x + à frente, y + à
//! direita, z + para baixo, em metros; nenhuma quando não se aplica), o valor "de planilha" com o sinal que ela usa
//! (x_TDP > 0 = trem atrás do CG, por exemplo) e uma nota. O chão é o das rodas principais com o avião nivelado.
const std = @import("std");
/// o CG com a carga e o "Acertar o CG" (`balance.py`)
pub const balance = @import("balance.zig");
/// o projeto da sprint: abrir e gravar a pasta (`store.py`)
pub const store = @import("store.zig");
/// o registro do projeto: grandezas, restrições, variáveis e os campos das condições e das regras
pub const registry = @import("registry.zig");
/// as etapas da sprint que já estão em Zig (a tela chama `stages.handle`)
pub const stages = @import("stages.zig");
/// o ponto de projeto acoplado e a viabilidade dele (o estudo de Motores; o aeroopt avalia cada candidato por aqui)
pub const study = @import("stage_study.zig");
/// a montagem do avião a partir do conjunto e dos motores
pub const power = @import("stage_power.zig");
const aircraft_model = @import("aircraft_model");
const manager = @import("manager");

const model = aircraft_model.aircraft;
const params = aircraft_model.params;
const Aircraft = model.Aircraft;
const geometry = manager.stability;

/// uma linha da tabela: (grupo, item, Δx Δy Δz, valor, nota)
pub const Row = struct {
    group: []const u8,
    item: []const u8,
    delta: ?[3]f64 = null,
    value: ?f64 = null,
    note: []const u8 = "",
};

/// o CG de onde se mede: o de projeto que a sprint grava ou, sem ele, o da massa seca (`design_cg`)
pub fn designCg(aircraft: *const Aircraft) [3]f64 {
    if (aircraft.design_cg) |center| return center;
    return params.dryMass(aircraft).cg;
}

/// a CMA pela integral em 201 pontos, como `planform` (`design/wing.py`): o tamanho, o x do bordo de ataque dela e
/// o do centro aerodinâmico (1/4 da CMA atrás do bordo de ataque; x à frente). Os pontos e a soma seguem os do
/// numpy (`linspace`, `trapezoid` com a soma aos pares), para os números saírem iguais até o último algarismo e o
/// texto arredondar igual ao do Python
pub const Planform = struct { chord: f64, x_leading: f64, x_center: f64 };

const samples = 201;

pub fn planform(surface: *const model.Surface) Planform {
    var buffer: [model.limits.sections]model.Section = undefined;
    const sections = model.sortedSections(surface, &buffer);
    const half = model.semispan(surface);
    var stations: [samples]f64 = undefined;
    var chords: [samples]f64 = undefined;
    var squares: [samples]f64 = undefined;
    var leading: [samples]f64 = undefined;
    const spacing = half / @as(f64, @floatFromInt(samples - 1));
    for (0..samples) |i| {
        stations[i] = if (i == samples - 1) half else @as(f64, @floatFromInt(i)) * spacing;
        chords[i] = model.sectionAt(sections, stations[i], "chord");
        squares[i] = chords[i] * chords[i];
        leading[i] = chords[i] * (surface.x - model.sectionAt(sections, stations[i], "x_offset"));
    }
    const area = trapezoid(&chords, &stations);
    const mean = trapezoid(&squares, &stations) / area;
    const x_leading = trapezoid(&leading, &stations) / area;
    return .{ .chord = mean, .x_leading = x_leading, .x_center = x_leading - 0.25 * mean };
}

/// a integral pelos trapézios, (Δy (f_i + f_i+1) / 2) somado aos pares como o `np.trapezoid`
fn trapezoid(values: *const [samples]f64, stations: *const [samples]f64) f64 {
    var terms: [samples - 1]f64 = undefined;
    for (&terms, 0..) |*term, i| term.* = (stations[i + 1] - stations[i]) * (values[i + 1] + values[i]) / 2.0;
    return pairwiseSum(&terms);
}

/// a soma aos pares do numpy (`pairwise_sum`): até 8 termos em sequência, até 128 em oito somas paralelas, acima
/// disso em duas metades
fn pairwiseSum(terms: []const f64) f64 {
    if (terms.len < 8) {
        var sum: f64 = 0;
        for (terms) |term| sum += term;
        return sum;
    }
    if (terms.len <= 128) {
        var partial: [8]f64 = terms[0..8].*;
        var i: usize = 8;
        while (i < terms.len - terms.len % 8) : (i += 8) {
            for (0..8) |j| partial[j] += terms[i + j];
        }
        var sum = ((partial[0] + partial[1]) + (partial[2] + partial[3])) + ((partial[4] + partial[5]) + (partial[6] + partial[7]));
        while (i < terms.len) : (i += 1) sum += terms[i];
        return sum;
    }
    var split = terms.len / 2;
    split -= split % 8;
    return pairwiseSum(terms[0..split]) + pairwiseSum(terms[split..]);
}

fn relative(point: [3]f64, center: [3]f64) [3]f64 {
    return .{ point[0] - center[0], point[1] - center[1], point[2] - center[2] };
}

/// as linhas de `dimensions(ac, cg)`, na mesma ordem
pub fn dimensions(memory: std.mem.Allocator, aircraft: *const Aircraft, center: [3]f64) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    const gear = aircraft.gear;
    const custom = std.mem.eql(u8, gear.layout, "custom");
    const tricycle = std.mem.eql(u8, gear.layout, "tricycle");
    // sem trem não há chão
    var ground: ?f64 = null;
    if (!custom) {
        ground = gear.main_z;
    } else for (gear.custom) |leg| {
        ground = if (ground) |lowest| @max(lowest, leg.z) else leg.z;
    }
    const cg_height: ?f64 = if (ground) |floor| floor - center[2] else null;
    try rows.append(memory, .{ .group = "CG", .item = "CG de projeto (x, y, z absolutos)", .delta = center, .note = "a origem das outras linhas" });
    if (ground != null) try rows.append(memory, .{ .group = "CG", .item = "altura do CG ao chão", .value = cg_height, .note = "z_CG (origem: chão)" });

    const configuration = geometry.detectConfiguration(aircraft);
    var group_wings: [geometry.Configuration.max_list]usize = undefined;
    var group_count: usize = 0;
    if (configuration.wing) |main| {
        const main_wing = &aircraft.surfaces[main];
        for (aircraft.surfaces, 0..) |*surface, i| {
            const joined = if (main_wing.group.len == 0) i == main else (surface.enabled and std.mem.eql(u8, surface.role, "wing") and std.mem.eql(u8, surface.group, main_wing.group));
            if (joined and surface.enabled and surface.sections.len > 0 and group_count < group_wings.len) {
                group_wings[group_count] = i;
                group_count += 1;
            }
        }
    }
    if (group_count > 1) { // tandem, biplano: a CMA de referência do conjunto
        const chord = params.references(aircraft)[1];
        const leading = params.macLeadingEdge(aircraft);
        const center_x = leading - 0.25 * chord;
        var area_sum: f64 = 0;
        var height_sum: f64 = 0;
        for (group_wings[0..group_count]) |index| {
            const surface_area = params.area(&aircraft.surfaces[index]);
            area_sum += surface_area;
            height_sum += surface_area * aircraft.surfaces[index].z;
        }
        try rows.append(memory, .{ .group = "CG", .item = "x_CG / CMA do conjunto de asas", .value = (leading - center[0]) / chord, .note = "adimensional" });
        try rows.append(memory, .{ .group = "asa", .item = "CA do conjunto de asas (1/4 da CMA)", .delta = .{ center_x - center[0], 0, height_sum / area_sum - center[2] }, .value = (center_x - center[0]) / chord, .note = "valor: (x_CA − x_CG)/CMA; + = CA à frente do CG; média dos CA pela área" });
        for (group_wings[0..group_count]) |index| {
            const wing = &aircraft.surfaces[index];
            try rows.append(memory, .{ .group = "asa", .item = try std.fmt.allocPrint(memory, "{s}: bordo de ataque da raiz", .{wing.name}), .delta = relative(.{ wing.x, wing.y, wing.z }, center), .value = heightOf(ground, wing.z), .note = "valor: altura ao chão" });
        }
    } else if (configuration.wing) |main| {
        const wing = &aircraft.surfaces[main];
        const mean = planform(wing);
        try rows.append(memory, .{ .group = "CG", .item = "x_CG / CMA (do bordo de ataque da CMA)", .value = (mean.x_leading - center[0]) / mean.chord, .note = "adimensional" });
        try rows.append(memory, .{ .group = "asa", .item = "CA da asa (1/4 da CMA)", .delta = .{ mean.x_center - center[0], 0, wing.z - center[2] }, .value = (mean.x_center - center[0]) / mean.chord, .note = "valor: (x_CA − x_CG)/CMA; + = CA à frente do CG" });
        try rows.append(memory, .{ .group = "asa", .item = "bordo de ataque da raiz", .delta = relative(.{ wing.x, wing.y, wing.z }, center), .value = heightOf(ground, wing.z), .note = "valor: altura ao chão" });
    }

    if (!custom) {
        try rows.append(memory, .{ .group = "trem", .item = "TDP (trem principal)", .delta = .{ gear.main_x - center[0], gear.main_track / 2, gear.main_z - center[2] }, .value = center[0] - gear.main_x, .note = "x_TDP: do CG ao trem principal, + = atrás do CG" });
        try rows.append(memory, .{
            .group = "trem",
            .item = if (tricycle) "TDN (bequilha)" else "roda de cauda",
            .delta = .{ gear.steer_x - center[0], 0, gear.steer_z - center[2] },
            .value = if (tricycle) gear.steer_x - center[0] else center[0] - gear.steer_x,
            .note = if (tricycle) "x_TDN: do CG à bequilha, + = à frente" else "do CG à roda de cauda, + = atrás",
        });
        try rows.append(memory, .{ .group = "trem", .item = "bitola", .value = gear.main_track, .note = "entre as rodas principais" });
        if (cg_height) |height| if (height > 0) {
            try rows.append(memory, .{ .group = "trem", .item = "ângulo de tombamento", .value = std.math.radiansToDegrees(std.math.atan2(center[0] - gear.main_x, height)), .note = "atan(x_TDP / altura do CG), °: ~15° é o usual" });
        };
        if (tricycle and gear.tail_skid) try rows.append(memory, .{ .group = "trem", .item = "sapata de cauda", .delta = .{ gear.skid_x - center[0], 0, gear.skid_z - center[2] }, .value = heightOf(ground, gear.skid_z), .note = "valor: altura ao chão" });
    } else for (gear.custom, 0..) |leg, k| {
        try rows.append(memory, .{ .group = "trem", .item = try std.fmt.allocPrint(memory, "perna {d} ({s})", .{ k + 1, leg.kind }), .delta = relative(.{ leg.x, leg.y, leg.z }, center) });
    }

    for (aircraft.propulsion) |unit| if (unit.enabled) {
        const diameter = unit.propeller.D;
        try rows.append(memory, .{ .group = "motores", .item = try std.fmt.allocPrint(memory, "{s}: cubo da hélice", .{unit.name}), .delta = relative(.{ unit.x, unit.y, unit.z }, center), .value = heightOf(ground, unit.z + diameter / 2), .note = try std.fmt.allocPrint(memory, "valor: folga da hélice ao chão (D = {d:.3} m); inclinação {d}°", .{ diameter, unit.tilt }) });
    };
    if (aircraft.surfaces.len > 1) for (aircraft.surfaces[1..], 1..) |*surface, index| {
        if (!surface.enabled or surface.sections.len == 0) continue;
        if (std.mem.indexOfScalar(usize, group_wings[0..group_count], index) != null) continue;
        const mean = planform(surface);
        try rows.append(memory, .{ .group = "empenagem", .item = try std.fmt.allocPrint(memory, "{s}: CA", .{surface.name}), .delta = .{ mean.x_center - center[0], surface.y - center[1], surface.z - center[2] }, .value = center[0] - mean.x_center, .note = "valor: braço do CG ao CA (l_h, l_v), + = atrás do CG" });
        if (ground != null) try rows.append(memory, .{ .group = "empenagem", .item = try std.fmt.allocPrint(memory, "{s}: altura ao chão", .{surface.name}), .value = heightOf(ground, surface.z), .note = "da raiz" });
    };
    for (aircraft.allBooms()) |boom| if (boom.enabled) {
        const tail_end = boom.end();
        try rows.append(memory, .{ .group = "tubos", .item = try std.fmt.allocPrint(memory, "{s}: ponta de trás", .{boom.name}), .delta = relative(tail_end, center), .value = center[0] - tail_end[0], .note = try std.fmt.allocPrint(memory, "valor: atrás do CG; inclinação {d}°", .{boom.pitch}) });
    };
    for (aircraft.tanks) |tank| try rows.append(memory, .{ .group = "carga", .item = tank.name, .delta = relative(.{ tank.x, tank.y, tank.z }, center), .value = tank.volume, .note = "valor: litros" });
    const payload = aircraft.payload;
    if (payload.enabled) try rows.append(memory, .{ .group = "carga", .item = "LAPES", .delta = relative(.{ payload.x, payload.y, payload.z }, center), .value = payload.mass, .note = "valor: kg" });
    const ballast = aircraft.ballast;
    if (ballast.enabled) try rows.append(memory, .{ .group = "carga", .item = "lastro", .delta = relative(.{ ballast.x, ballast.y, ballast.z }, center), .value = ballast.mass, .note = "valor: kg" });
    for (aircraft.mass.items) |item| if (std.mem.indexOf(u8, item.name, "bateria") != null or std.mem.indexOf(u8, item.name, "lastro") != null) {
        try rows.append(memory, .{ .group = "massas", .item = item.name, .delta = relative(.{ item.x, item.y, item.z }, center), .value = item.mass, .note = "valor: kg" });
    };
    return rows.items;
}

/// a altura ao chão de um ponto em z (nenhuma sem chão)
fn heightOf(ground: ?f64, z: f64) ?f64 {
    return if (ground) |floor| floor - z else null;
}

test {
    _ = balance;
    _ = store;
    _ = stages;
}

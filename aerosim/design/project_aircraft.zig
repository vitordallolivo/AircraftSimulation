//! O avião do projeto: um avião só, do Dimensionamento à Montagem e às análises. As etapas não mandam mais um avião
//! pronto para a Montagem; a cada mudança do projeto o avião é montado de novo com o que as etapas já têm e gravado
//! na pasta do projeto, e a tela o abre (a Montagem mostra a construção e as análises rodam com ele):
//!
//!   só Projetar (uma configuração guardada)   as asas, cada uma no lugar dela, sem cauda e sem motor
//!   com um conjunto da Empenagem               asas, cauda, fuselagem e os motores do rascunho de Motores e montagem
//!
//! Uma peça mexida na Montagem vale até a etapa dona dela rodar de novo (a etapa refaz o avião).
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const templates = @import("templates");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");
const wing_stage = @import("stage_wing.zig");
const power_stage = @import("stage_power.zig");

const model = aircraft_model.aircraft;
const aero_file = aircraft_model.aero_file;
const zon_json = @import("aerosim").zon_json;

/// o nome do arquivo do avião dentro da pasta do projeto
pub const file_name = "aviao" ++ aero_file.extension;

/// o avião montado com o que as etapas já têm; nulo: o projeto ainda não tem nem uma configuração guardada
pub fn build(context: *stages.Context, memory: std.mem.Allocator) !?model.Aircraft {
    const project = &context.project;
    if (project.list("sets").items.len > 0) {
        if (power_stage.assemble(context, memory, project.section("power_draft")) catch null) |assembled| return assembled.plane;
    }
    const configs = project.list("configs").items;
    if (configs.len == 0) return null;
    const last = configs[configs.len - 1];
    if (last != .object) return null;
    const name = store.text(&last.object, "name", "");
    const wings = try wing_stage.configSurfaces(context, memory, name);
    if (wings.len == 0) return null;
    var plane = try std.json.parseFromSliceLeaky(model.Aircraft, memory, templates.all[0].json, .{ .ignore_unknown_fields = true });
    plane.name = try memory.dupe(u8, name);
    const surfaces = try memory.alloc(model.Surface, wings.len);
    for (wings, surfaces) |wing, *surface| {
        surface.* = wing;
        surface.role = "wing";
    }
    plane.surfaces = surfaces;
    // só as asas pesam (a densidade de asa das regras de massa), no centro de área delas
    const wing_density = registry.fieldNumber(project.section("rules"), &registry.rule_fields, "wing_density");
    var mass: f64 = 0;
    var moment = [3]f64{ 0, 0, 0 };
    for (surfaces) |surface| {
        const part = power_stage.surfaceArea(surface) * wing_density;
        const chord = if (surface.sections.len > 0) surface.sections[0].chord else 0;
        mass += part;
        moment[0] += part * (surface.x - 0.4 * chord);
        moment[2] += part * surface.z;
    }
    const center: [3]f64 = if (mass > 0) .{ moment[0] / mass, 0, moment[2] / mass } else .{ 0, 0, 0 };
    plane.mass = .{ .base_mass = @max(mass, 1e-3), .base_cg = center, .Ixx = 0.1, .Iyy = 0.1, .Izz = 0.2, .Ixz = 0 };
    plane.propulsion = &.{};
    plane.booms = &.{};
    plane.boom = .{};
    plane.tanks = &.{};
    plane.payload.enabled = false;
    plane.fuselage.enabled = false;
    plane.Sref = null;
    plane.cref = null;
    plane.bref = null;
    return plane;
}

/// o caminho do avião do projeto (na pasta dele)
pub fn path(context: *stages.Context, memory: std.mem.Allocator) ![]const u8 {
    if (context.project.document.len > 0) return memory.dupe(u8, context.project.document);
    return std.fs.path.join(memory, &.{ context.project.folder, file_name });
}

/// monta o avião de novo e grava se mudou; devolve o caminho quando gravou (a tela abre de novo), nulo se nada mudou
/// ou se ainda não há avião
pub fn sync(context: *stages.Context, memory: std.mem.Allocator) !?[]const u8 {
    // sem projeto (um avião aberto direto), as etapas não tocam no avião
    if (!context.has_project) return null;
    const plane = (try build(context, memory)) orelse return null;
    const target = try path(context, memory);
    var out: std.Io.Writer.Allocating = .init(memory);
    try std.json.Stringify.value(plane, .{ .emit_null_optional_fields = false }, &out.writer);
    const json = out.written();
    var created: []const u8 = "";
    if (std.Io.Dir.cwd().readFileAlloc(context.io, target, memory, .limited(1 << 24))) |bytes| {
        // o mesmo avião: nada a gravar (compara o avião, não as datas do manifesto)
        var diagnosis: model.Diag = .{};
        if (aero_file.readDocument(memory, bytes, &diagnosis)) |document| {
            if (std.mem.eql(u8, document.json, try aero_file.canonicalJson(memory, json))) return null;
            created = document.manifest.criado_em;
        } else |_| {}
    } else |_| {}
    // o `.aero` que leva o projeto: o avião remontado entra no lugar do de lá, com o projeto junto
    if (context.project.document.len > 0) {
        const part: aero_file.Part = .{ .name = aero_file.project_part, .data = try zon_json.toZon(memory, context.project.root) };
        return if (stages.writeIntoDocument(context, memory, json, part)) target else null;
    }
    const bytes = try aero_file.writeDocument(memory, json, .{ .program = "aerosim", .now = try aero_file.isoNow(memory, context.io), .created = created }, &.{});
    std.Io.Dir.cwd().createDirPath(context.io, context.project.folder) catch {};
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = target, .data = bytes });
    return target;
}

//! Um candidato do aeroopt avaliado em Zig (o `SurfaceSizing.point` do Python, sem a geometria e a estabilidade
//! ainda): os valores vão para os rascunhos de uma cópia do projeto da sprint, a asa e o conjunto dos rascunhos são
//! guardados nessa cópia, e o ponto de projeto acoplado da etapa Motores (`study.designPoint`) dá o MTOW na pista,
//! o peso vazio e a bateria; `study.feasibility` diz o que não fecha. Cada candidato tem a própria memória, então a
//! função é pura: o mesmo candidato dá o mesmo resultado em qualquer máquina (o que a sala P2P vai precisar).
const std = @import("std");
const design = @import("design");
const inputs = @import("inputs.zig");

const store = design.store;
const stages = design.stages;
const Value = std.json.Value;

/// um valor de uma variável do candidato
pub const Assignment = struct { key: []const u8, value: Value };

/// o resultado de um candidato
pub const Point = struct {
    mtow: f64 = std.math.nan(f64), // a massa máxima de decolagem na pista (kg)
    ok: bool = false, // fecha: converge, decola e cumpre as restrições
    why: []const u8 = "", // o que não fecha ("; " entre os motivos)
    empty: f64 = std.math.nan(f64), // o peso vazio (kg)
    battery: f64 = 0, // a massa das baterias (kg)
    span: f64 = std.math.nan(f64), // a envergadura (m)
    violation: f64 = 0, // 0 quando fecha; senão quanto viola (por enquanto 1)
};

pub const Error = error{ UnknownInput, NotProject, OutOfMemory };

/// escreve os valores do candidato nos rascunhos do projeto
pub fn assign(project: *store.Project, values: []const Assignment) Error!void {
    for (values) |item| {
        const input = inputs.find(item.key) orelse return error.UnknownInput;
        const dot = std.mem.indexOfScalar(u8, input.path, '.') orelse return error.UnknownInput;
        const section = project.section(input.path[0..dot]);
        const field = input.path[dot + 1 ..];
        const value: Value = switch (input.kind) {
            .continuous => .{ .float = numberOf(item.value) },
            .integer => .{ .integer = @intFromFloat(@round(numberOf(item.value))) },
            .list => if (input.source == .yes_no) .{ .bool = item.value == .bool and item.value.bool or item.value == .string and std.mem.eql(u8, item.value.string, "sim") } else .{ .string = try project.memory().dupe(u8, if (item.value == .string) item.value.string else "") },
        };
        try section.put(project.memory(), try project.memory().dupe(u8, field), value);
    }
}

fn numberOf(value: Value) f64 {
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .number_string => |digits| std.fmt.parseFloat(f64, digits) catch std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

/// avalia um candidato sobre uma cópia de `base` (a raiz do projeto, que não muda); `memory` guarda o resultado
pub fn point(gpa: std.mem.Allocator, io: std.Io, base: Value, values: []const Assignment, memory: std.mem.Allocator) !Point {
    var project = try store.empty(gpa, "");
    defer project.deinit();
    project.root = try stages.clone(project.memory(), base);
    if (project.root != .object) return error.NotProject;
    try project.reserve();
    try assign(&project, values);
    var context: stages.Context = .{ .project = project, .io = io, .named = false };
    const scratch = project.memory();
    // a asa e o conjunto dos rascunhos viram os guardados que a montagem lê (o `candidate` do Python)
    _ = try stages.find("asa").?.apply(&context, scratch, .{ .do = "keep" });
    _ = try stages.find("empenagem").?.apply(&context, scratch, .{ .do = "keep" });
    const power = context.project.section("power_draft");
    const found = try design.study.designPoint(&context, scratch, power) orelse return .{ .why = try memory.dupe(u8, "o avião não se monta"), .violation = 1 };
    const assembled = found.assembled;
    const set_params = design.power.chosenSet(&context.project, power) orelse return .{ .why = try memory.dupe(u8, "sem conjunto"), .violation = 1 };
    const why = try design.study.feasibility(&context, scratch, assembled, found.converged, set_params);
    var battery: f64 = 0;
    for (assembled.plane.propulsion) |unit| battery += unit.battery.mass;
    return .{
        .mtow = assembled.runway_mtow,
        .ok = why.len == 0,
        .why = try memory.dupe(u8, why),
        .empty = assembled.empty,
        .battery = battery,
        .span = assembled.built.wing.span,
        .violation = if (why.len == 0) 0 else 1,
    };
}

test "um candidato do projeto de exemplo" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var project = store.open(std.heap.page_allocator, io, "../data/sprint/projeto_s1223.json") catch return error.SkipZigTest;
    defer project.deinit();
    const values = [_]Assignment{ .{ .key = "wing.span", .value = .{ .float = 2.0 } }, .{ .key = "wing.area", .value = .{ .float = 0.6 } } };
    const result = try point(std.heap.page_allocator, io, project.root, &values, arena.allocator());
    // o projeto de exemplo com b = 2 m e S = 0,6 m²: MTOW 7,4156 kg, vazio 3,4553 kg, duas baterias de 0,4 kg;
    // não fecha porque a restrição de estol do projeto (≤ 11 m/s) pede mais área
    try std.testing.expectApproxEqAbs(@as(f64, 7.4156), result.mtow, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 3.4553), result.empty, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), result.battery, 1e-9);
    try std.testing.expect(!result.ok and std.mem.indexOf(u8, result.why, "velocidade de estol") != null);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.span, 1e-9);
}

//! As análises feitas só em Zig, sem Python no caminho: a página da tela (`aerosim/gui/page.zig`) pede os campos e
//! roda pelo mesmo contrato da ponte com o Python (`aerosim/bridge.py`), só que aqui mesmo. É a primeira peça da troca
//! dos managers em Python por Zig: uma análise nova implementa `Simulation` e entra em `all`, e a tela não muda.
//!
//! O contrato é o JSON da ponte. Os campos saem como `{"params": [...], "plots": [...], "description": ...}` e o
//! resultado como `{"summary": {...}, "checks": [...], "plots": [...]}`, com os mesmos nomes da `ISimulation`
//! (`aerosim/interfaces/simulation.py`). A rodada anda em fatias (`advance`), para a tela seguir desenhando, também no
//! navegador, onde não há thread.
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const gust_liquid = @import("gust_liquid.zig");

pub const Aircraft = aircraft_model.aircraft.Aircraft;
pub const Json = std.json.Value;
pub const Writer = std.Io.Writer;

/// uma análise em Zig: o que a tela mostra e como roda
pub const Simulation = struct {
    name: []const u8, // o nome que a página guarda (como `ISimulation.name`)
    title: [:0]const u8, // o rótulo da subaba
    area: []const u8, // a aba de cima onde a subaba entra ("Estabilidade")
    description: []const u8,
    /// escreve os campos e os gráficos para o avião e os valores de agora (o avião pode faltar)
    specs: *const fn (out: *Writer, aircraft: ?*const Aircraft, values: Values) anyerror!void,
    /// uma edição numa tabela da aba (`grids`), guardada pela própria análise até a próxima rodada; nulo: sem tabelas
    edit: ?*const fn (aircraft: ?*const Aircraft, change: GridEdit) anyerror!void = null,
    /// prepara a rodada em `run` (o avião já foi lido)
    start: *const fn (run: *Run, values: Values) anyerror!void,
    /// avança uma fatia da rodada; verdadeiro quando acabou
    advance: *const fn (run: *Run) anyerror!bool,
    /// escreve o resultado da rodada que acabou
    result: *const fn (run: *Run, out: *Writer) anyerror!void,
};

/// as análises em Zig, na ordem das subabas
pub const all = [_]Simulation{gust_liquid.simulation};

/// a análise em Zig com este nome
pub fn find(name: []const u8) ?*const Simulation {
    for (&all) |*simulation| if (std.mem.eql(u8, simulation.name, name)) return simulation;
    return null;
}

/// os valores do formulário, como a tela manda (`{"chave": valor}`)
pub const Values = struct {
    object: ?std.json.ObjectMap = null,

    /// os valores dentro de um pedido da tela (`"op": ..., "name": ..., "values": {...}`, sem as chaves de fora)
    pub fn fromRequest(memory: std.mem.Allocator, request: []const u8) Values {
        const whole = std.fmt.allocPrint(memory, "{{{s}}}", .{request}) catch return .{};
        const root = std.json.parseFromSliceLeaky(Json, memory, whole, .{}) catch return .{};
        if (root != .object) return .{};
        const values = root.object.get("values") orelse return .{};
        return if (values == .object) .{ .object = values.object } else .{};
    }

    /// um número (ou `fallback` se não veio)
    pub fn number(values: Values, key: []const u8, fallback: f64) f64 {
        const object = values.object orelse return fallback;
        return switch (object.get(key) orelse return fallback) {
            .float => |value| value,
            .integer => |value| @floatFromInt(value),
            else => fallback,
        };
    }

    /// um marcador
    pub fn toggle(values: Values, key: []const u8, fallback: bool) bool {
        const object = values.object orelse return fallback;
        const value = object.get(key) orelse return fallback;
        return if (value == .bool) value.bool else fallback;
    }

    /// o texto de uma escolha
    pub fn text(values: Values, key: []const u8, fallback: []const u8) []const u8 {
        const object = values.object orelse return fallback;
        const value = object.get(key) orelse return fallback;
        return if (value == .string) value.string else fallback;
    }
};

/// uma edição numa tabela, como a tela manda (`"grid": ..., "edit": "set", "row": n, "key": ..., "value": ...`; os
/// botões mandam o `operation` deles no lugar de "set")
pub const GridEdit = struct {
    grid: []const u8,
    operation: []const u8,
    row: ?usize = null, // a linha editada ou a selecionada (nula: nenhuma)
    key: []const u8 = "",
    value: Json = .null,

    /// a edição dentro de um pedido da tela (nula se o pedido não é de tabela)
    pub fn fromRequest(memory: std.mem.Allocator, request: []const u8) ?GridEdit {
        const whole = std.fmt.allocPrint(memory, "{{{s}}}", .{request}) catch return null;
        const root = std.json.parseFromSliceLeaky(Json, memory, whole, .{}) catch return null;
        if (root != .object) return null;
        const grid = root.object.get("grid") orelse return null;
        const operation = root.object.get("edit") orelse return null;
        if (grid != .string or operation != .string) return null;
        var change: GridEdit = .{ .grid = grid.string, .operation = operation.string };
        if (root.object.get("row")) |row| if (row == .integer and row.integer >= 0) {
            change.row = @intCast(row.integer);
        };
        if (root.object.get("key")) |key| if (key == .string) {
            change.key = key.string;
        };
        change.value = root.object.get("value") orelse .null;
        return change;
    }

    /// o valor editado como número (o texto com vírgula também vale)
    pub fn number(change: GridEdit) ?f64 {
        return switch (change.value) {
            .float => |value| value,
            .integer => |value| @floatFromInt(value),
            .string => |value| std.fmt.parseFloat(f64, std.mem.trim(u8, value, " ")) catch blk: {
                var buffer: [64]u8 = undefined;
                if (value.len > buffer.len) break :blk null;
                const dotted = buffer[0..value.len];
                @memcpy(dotted, value);
                std.mem.replaceScalar(u8, dotted, ',', '.');
                break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, dotted, " ")) catch null;
            },
            else => null,
        };
    }

    /// o valor editado como texto (escolha ou nome)
    pub fn text(change: GridEdit) []const u8 {
        return if (change.value == .string) change.value.string else "";
    }
};

/// uma rodada: o avião lido, a memória dela, o progresso e o estado da análise
pub const Run = struct {
    arena: std.heap.ArenaAllocator,
    aircraft: *const Aircraft,
    state: ?*anyopaque = null,
    progress: f32 = 0, // de 0 a 1
    message: [160:0]u8 = [_:0]u8{0} ** 160,
    failure: [240:0]u8 = [_:0]u8{0} ** 240,

    pub fn memory(run: *Run) std.mem.Allocator {
        return run.arena.allocator();
    }

    /// o texto do progresso
    pub fn say(run: *Run, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(run.message[0 .. run.message.len - 1], fmt, args) catch run.message[0 .. run.message.len - 1];
        run.message[written.len] = 0;
    }

    /// o motivo de a rodada não ter saído (a tela mostra)
    pub fn fail(run: *Run, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(run.failure[0 .. run.failure.len - 1], fmt, args) catch run.failure[0 .. run.failure.len - 1];
        run.failure[written.len] = 0;
    }
};

// ------------------------------------------------------------------ o JSON da ponte

/// um campo do formulário (`ParamSpec`)
pub const Param = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { float, int, bool, choice } = .float,
    default: union(enum) { number: f64, toggle: bool, text: []const u8 } = .{ .number = 0 },
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    unit: []const u8 = "",
    choices: []const []const u8 = &.{},
    group: []const u8 = "",
    help: []const u8 = "",
    rebuild: bool = false,
};

/// um gráfico (`PlotSpec`): só o título e os eixos; as curvas vêm no resultado
pub const Plot = struct {
    key: []const u8,
    title: []const u8,
    xlabel: []const u8,
    ylabel: []const u8,
};

/// uma curva de um gráfico do resultado
pub const Curve = struct {
    name: []const u8,
    x: []const f64,
    y: []const f64,
    color: []const u8,
    dashed: bool = false,
    marker: []const u8 = "", // um símbolo em cada ponto, sem a linha ("x", "o", "+"); vazio: só a linha
    size: f64 = 0, // o tamanho do símbolo (0: o padrão)
    legend: bool = true, // falso: a curva não entra na legenda
};

/// um item do diagnóstico (`Check`)
pub const Check = struct {
    status: enum { ok, atencao, falha, info },
    item: []const u8,
    value: []const u8,
    criterion: []const u8 = "",
    why: []const u8 = "",
    fix: []const u8 = "",
    group: []const u8 = "",
};

/// uma coluna de uma tabela editável: número, texto, escolha ou só leitura ("label")
pub const Column = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { float, text, choice, label } = .float,
    choices: []const []const u8 = &.{},
    help: []const u8 = "",
};

/// uma célula: número ou texto (o texto também vale para as escolhas e as de leitura)
pub const Cell = union(enum) { number: f64, text: []const u8 };

/// um botão abaixo da tabela: o que ele pede (`GridEdit.operation`) e o rótulo
pub const Button = struct { operation: []const u8, label: []const u8, help: []const u8 = "" };

/// uma tabela editável da aba (como as `stages.Grid` do Python)
pub const Grid = struct {
    name: []const u8,
    title: []const u8,
    help: []const u8 = "",
    note: []const u8 = "",
    columns: []const Column,
    rows: []const []const Cell,
    buttons: []const Button = &.{},
};

/// uma peça da vista 3D: o tipo (a cor da tela: "wing", "tank", "payload"...) e os triângulos, no corpo
pub const Mesh = struct {
    kind: []const u8,
    vertices: []const [3]f64,
    faces: []const [3]u32,
};

/// a vista 3D da aba: as peças e o CG
pub const View = struct {
    meshes: []const Mesh,
    cg: ?[3]f64 = null,
};

/// o que vem nos campos além do formulário: as tabelas e a vista 3D
pub const Extras = struct {
    grids: []const Grid = &.{},
    view: ?View = null,
};

/// `{"params": [...], "plots": [...], "description": ..., "grids": [...], "view": {...}}`
pub fn writeSpecs(out: *Writer, params: []const Param, plots: []const Plot, description: []const u8, extras: Extras) !void {
    try out.writeAll("{\"params\": [");
    for (params, 0..) |param, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"key\": {f}, \"label\": {f}, \"kind\": \"{s}\", \"default\": ", .{ str(param.key), str(param.label), @tagName(param.kind) });
        switch (param.default) {
            .number => |value| try out.print("{d}", .{value}),
            .toggle => |value| try out.writeAll(if (value) "true" else "false"),
            .text => |value| try out.print("{f}", .{str(value)}),
        }
        try out.writeAll(", \"minimum\": ");
        try optionalNumber(out, param.minimum);
        try out.writeAll(", \"maximum\": ");
        try optionalNumber(out, param.maximum);
        try out.print(", \"unit\": {f}, \"choices\": [", .{str(param.unit)});
        for (param.choices, 0..) |choice, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{f}", .{str(choice)});
        }
        try out.print("], \"group\": {f}, \"help\": {f}, \"rebuild\": {}, \"enabled\": true}}", .{ str(param.group), str(param.help), param.rebuild });
    }
    try out.writeAll("], \"plots\": [");
    for (plots, 0..) |plot, k| {
        if (k > 0) try out.writeAll(", ");
        try writePlotHead(out, plot);
        try out.writeAll("}");
    }
    try out.print("], \"description\": {f}, \"grids\": [", .{str(description)});
    for (extras.grids, 0..) |grid, k| {
        if (k > 0) try out.writeAll(", ");
        try writeGrid(out, grid);
    }
    try out.writeAll("]");
    if (extras.view) |view| try writeView(out, view);
    try out.writeAll("}");
}

fn writeGrid(out: *Writer, grid: Grid) !void {
    try out.print("{{\"name\": {f}, \"title\": {f}, \"help\": {f}, \"note\": {f}, \"columns\": [", .{ str(grid.name), str(grid.title), str(grid.help), str(grid.note) });
    for (grid.columns, 0..) |column, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"key\": {f}, \"label\": {f}, \"kind\": \"{s}\", \"help\": {f}, \"choices\": [", .{ str(column.key), str(column.label), @tagName(column.kind), str(column.help) });
        for (column.choices, 0..) |choice, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{f}", .{str(choice)});
        }
        try out.writeAll("]}");
    }
    try out.writeAll("], \"rows\": [");
    for (grid.rows, 0..) |row, r| {
        if (r > 0) try out.writeAll(", ");
        try out.writeAll("[");
        for (row, 0..) |cell, c| {
            if (c > 0) try out.writeAll(", ");
            switch (cell) {
                .number => |value| if (std.math.isFinite(value)) try out.print("{d}", .{value}) else try out.writeAll("null"),
                .text => |value| try out.print("{f}", .{str(value)}),
            }
        }
        try out.writeAll("]");
    }
    try out.writeAll("], \"buttons\": [");
    for (grid.buttons, 0..) |button, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("[{f}, {f}, {f}]", .{ str(button.operation), str(button.label), str(button.help) });
    }
    try out.writeAll("]}");
}

/// `, "view": {"meshes": [{"kind", "vertices": [x, y, z, ...], "faces": [a, b, c, ...]}], "markers": {"cg": [...]}}`
fn writeView(out: *Writer, view: View) !void {
    try out.writeAll(", \"view\": {\"meshes\": [");
    for (view.meshes, 0..) |mesh, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"kind\": {f}, \"vertices\": [", .{str(mesh.kind)});
        for (mesh.vertices, 0..) |point, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{d:.4}, {d:.4}, {d:.4}", .{ point[0], point[1], point[2] });
        }
        try out.writeAll("], \"faces\": [");
        for (mesh.faces, 0..) |face, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{d}, {d}, {d}", .{ face[0], face[1], face[2] });
        }
        try out.writeAll("]}");
    }
    try out.writeAll("], \"markers\": {");
    if (view.cg) |point| try out.print("\"cg\": [{d}, {d}, {d}]", .{ point[0], point[1], point[2] });
    try out.writeAll("}}");
}

/// o começo do resultado: `{"status": ..., "summary": {...}, "checks": [...], "plots": [` (as curvas vêm depois, com
/// `writePlot`, e `endResult` fecha)
pub fn beginResult(out: *Writer, summary: []const [2][]const u8, checks: []const Check) !void {
    try out.writeAll("{\"status\": \"ok\", \"summary\": {");
    for (summary, 0..) |row, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{f}: {f}", .{ str(row[0]), str(row[1]) });
    }
    try out.writeAll("}, \"checks\": [");
    for (checks, 0..) |check, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"status\": \"{s}\", \"item\": {f}, \"value\": {f}, \"criterion\": {f}, \"why\": {f}, \"fix\": {f}, \"group\": {f}}}", .{
            @tagName(check.status), str(check.item), str(check.value), str(check.criterion), str(check.why), str(check.fix), str(check.group),
        });
    }
    try out.writeAll("], \"plots\": [");
}

/// um gráfico do resultado com as curvas (`first`: é o primeiro da lista)
pub fn writePlot(out: *Writer, plot: Plot, curves: []const Curve, first: bool) !void {
    if (!first) try out.writeAll(", ");
    try writePlotHead(out, plot);
    try out.writeAll(", \"curves\": [");
    for (curves, 0..) |curve, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"name\": {f}, \"color\": {f}, \"dashed\": {}, \"marker\": {f}, \"size\": {d}, \"legend\": {}, \"x\": ", .{ str(curve.name), str(curve.color), curve.dashed, str(curve.marker), curve.size, curve.legend });
        try numbers(out, curve.x);
        try out.writeAll(", \"y\": ");
        try numbers(out, curve.y);
        try out.writeAll("}");
    }
    try out.writeAll("]}");
}

/// fecha o resultado
pub fn endResult(out: *Writer) !void {
    try out.writeAll("]}");
}

fn writePlotHead(out: *Writer, plot: Plot) !void {
    try out.print("{{\"key\": {f}, \"title\": {f}, \"xlabel\": {f}, \"ylabel\": {f}, \"kind\": \"2d\"", .{ str(plot.key), str(plot.title), str(plot.xlabel), str(plot.ylabel) });
}

fn numbers(out: *Writer, values: []const f64) !void {
    try out.writeAll("[");
    for (values, 0..) |value, k| {
        if (k > 0) try out.writeAll(", ");
        if (std.math.isFinite(value)) try out.print("{d}", .{value}) else try out.writeAll("null");
    }
    try out.writeAll("]");
}

fn optionalNumber(out: *Writer, value: ?f64) !void {
    if (value) |number| try out.print("{d}", .{number}) else try out.writeAll("null");
}

fn str(text: []const u8) std.json.Formatter([]const u8) {
    return std.json.fmt(text, .{});
}

test {
    _ = gust_liquid;
}

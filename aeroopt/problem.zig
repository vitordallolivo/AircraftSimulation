//! O problema do aeroopt como arquivo (`.opt.json`, formato "aeroopt/1"): o que pode variar no avião e entre que
//! limites, as restrições, a pontuação e as opções das etapas. É o mesmo arquivo que a janela em Python lê e grava
//! (`aeroopt/problem.py`), então um problema montado numa abre na outra.
//!
//! Os parâmetros das etapas (`params`: categorias, geometria, estabilidade, métodos) ficam como a árvore do JSON,
//! porque cada etapa lê só o pedaço dela; o resto vira tipos.
const std = @import("std");

const Value = std.json.Value;

/// o formato que o arquivo declara (o mesmo de `aerosim/interfaces/optim.py`, `FORMAT`)
pub const format = "aeroopt/1";

/// o tipo de uma variável: número livre, número inteiro (com o passo do campo) ou lista de escolhas
pub const VariableKind = enum {
    continuous,
    integer,
    list,

    /// o nome no arquivo
    pub fn label(kind: VariableKind) []const u8 {
        return switch (kind) {
            .continuous => "contínua",
            .integer => "inteira",
            .list => "lista",
        };
    }

    /// o tipo pelo nome do arquivo (um nome desconhecido vira contínua, como no Python)
    pub fn fromLabel(name: []const u8) VariableKind {
        inline for (std.meta.fields(VariableKind)) |field| {
            const kind: VariableKind = @enumFromInt(field.value);
            if (std.mem.eql(u8, name, kind.label())) return kind;
        }
        return .continuous;
    }
};

/// a comparação de uma restrição
pub const Comparison = enum {
    at_most,
    at_least,
    equal,

    /// o símbolo no arquivo
    pub fn symbol(comparison: Comparison) []const u8 {
        return switch (comparison) {
            .at_most => "≤",
            .at_least => "≥",
            .equal => "=",
        };
    }

    /// a comparação pelo símbolo do arquivo (um símbolo desconhecido vira ≤, o padrão do Python)
    pub fn fromSymbol(sign: []const u8) Comparison {
        inline for (std.meta.fields(Comparison)) |field| {
            const comparison: Comparison = @enumFromInt(field.value);
            if (std.mem.eql(u8, sign, comparison.symbol())) return comparison;
        }
        return .at_most;
    }
};

/// uma entrada do projeto que a busca pode mudar
pub const Variable = struct {
    key: []const u8, // a entrada do projeto (`wing.span`, `power.motor`...)
    kind: VariableKind = .continuous,
    lower: f64 = 0,
    upper: f64 = 1,
    options: []const []const u8 = &.{}, // lista: os itens que a busca pode escolher (vazio = todos)
    group: []const u8 = "", // para isolar um grupo inteiro (asa, propulsão, requisitos)
    free: bool = false, // falso: fica no valor do avião
};

/// uma grandeza do avião que tem de cumprir um limite
pub const Constraint = struct {
    key: []const u8,
    comparison: Comparison = .at_most,
    value: f64 = 0,
    active: bool = true,
    tolerance: f64 = 0.02, // "=": tolerância relativa
};

/// o problema inteiro; a memória é da arena de quem leu
pub const Problem = struct {
    name: []const u8 = "",
    variables: []Variable = &.{},
    constraints: []Constraint = &.{},
    scoring: []const u8 = "MTOW", // objetivo simples (MTOW, EE) ou o nome do arquivo de pontuação (.toml)
    evaluator: []const u8 = "etapas",
    solver: Value = .null, // método e opções do mini-MDO (o arquivo guarda; as etapas não usam)
    params: Value = .null, // parâmetros das etapas, como no arquivo

    /// quantas variáveis estão livres
    pub fn freeCount(problem: *const Problem) usize {
        var count: usize = 0;
        for (problem.variables) |item| count += @intFromBool(item.free);
        return count;
    }

    /// a variável desta entrada, se o problema tem
    pub fn variable(problem: *const Problem, key: []const u8) ?*Variable {
        for (problem.variables) |*candidate| if (std.mem.eql(u8, candidate.key, key)) return candidate;
        return null;
    }

    /// deixa livres só as numéricas dos grupos dados (as listas ficam como estão), como `OptProblem.isolate`
    pub fn isolate(problem: *Problem, groups: []const []const u8) void {
        for (problem.variables) |*candidate| {
            if (candidate.kind == .list) continue;
            candidate.free = for (groups) |group| {
                if (std.mem.eql(u8, candidate.group, group) or std.mem.eql(u8, candidate.key, group)) break true;
            } else false;
        }
    }

    /// um parâmetro das etapas pelo nome (`categorias`, `geometria`, `etapas`...)
    pub fn param(problem: *const Problem, name: []const u8) ?Value {
        if (problem.params != .object) return null;
        return problem.params.object.get(name);
    }
};

pub const ReadError = error{ NotProblem, OutOfMemory };

/// lê o problema do texto do arquivo; tudo fica na `memory` (uma arena)
pub fn parse(memory: std.mem.Allocator, bytes: []const u8) ReadError!Problem {
    const root = std.json.parseFromSliceLeaky(Value, memory, bytes, .{}) catch return error.NotProblem;
    if (root != .object) return error.NotProblem;
    const object = root.object;
    if (object.get("formato")) |declared| {
        if (declared != .string or !std.mem.eql(u8, declared.string, format)) return error.NotProblem;
    }
    var problem: Problem = .{
        .name = text(object.get("name"), ""),
        .scoring = text(object.get("scoring"), "MTOW"),
        .evaluator = text(object.get("evaluator"), "etapas"),
        .solver = object.get("solver") orelse .null,
        .params = object.get("params") orelse .null,
    };
    if (object.get("variables")) |list| if (list == .array) {
        problem.variables = try memory.alloc(Variable, list.array.items.len);
        for (list.array.items, problem.variables) |item, *out| out.* = try readVariable(memory, item);
    };
    if (object.get("constraints")) |list| if (list == .array) {
        problem.constraints = try memory.alloc(Constraint, list.array.items.len);
        for (list.array.items, problem.constraints) |item, *out| out.* = readConstraint(item);
    };
    return problem;
}

/// lê o problema de um arquivo
pub fn load(memory: std.mem.Allocator, io: std.Io, path: []const u8) (ReadError || error{CannotRead})!Problem {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 24)) catch return error.CannotRead;
    return parse(memory, bytes);
}

/// o problema como o texto do arquivo, na mesma ordem de campos do Python
pub fn write(memory: std.mem.Allocator, problem: *const Problem) error{OutOfMemory}![]u8 {
    var root: std.json.ObjectMap = .empty;
    try root.put(memory, "formato", .{ .string = format });
    try root.put(memory, "name", .{ .string = problem.name });
    var variables = try std.json.Array.initCapacity(memory, problem.variables.len);
    for (problem.variables) |item| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(memory, "key", .{ .string = item.key });
        try entry.put(memory, "kind", .{ .string = item.kind.label() });
        try entry.put(memory, "lo", .{ .float = item.lower });
        try entry.put(memory, "hi", .{ .float = item.upper });
        var options = try std.json.Array.initCapacity(memory, item.options.len);
        for (item.options) |option| options.appendAssumeCapacity(.{ .string = option });
        try entry.put(memory, "options", .{ .array = options });
        try entry.put(memory, "group", .{ .string = item.group });
        try entry.put(memory, "free", .{ .bool = item.free });
        variables.appendAssumeCapacity(.{ .object = entry });
    }
    try root.put(memory, "variables", .{ .array = variables });
    var constraints = try std.json.Array.initCapacity(memory, problem.constraints.len);
    for (problem.constraints) |item| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(memory, "key", .{ .string = item.key });
        try entry.put(memory, "op", .{ .string = item.comparison.symbol() });
        try entry.put(memory, "value", .{ .float = item.value });
        try entry.put(memory, "active", .{ .bool = item.active });
        try entry.put(memory, "tol", .{ .float = item.tolerance });
        constraints.appendAssumeCapacity(.{ .object = entry });
    }
    try root.put(memory, "constraints", .{ .array = constraints });
    try root.put(memory, "scoring", .{ .string = problem.scoring });
    try root.put(memory, "evaluator", .{ .string = problem.evaluator });
    try root.put(memory, "solver", if (problem.solver == .null) .{ .object = .empty } else problem.solver);
    try root.put(memory, "params", if (problem.params == .null) .{ .object = .empty } else problem.params);
    var out: std.Io.Writer.Allocating = .init(memory);
    std.json.Stringify.value(Value{ .object = root }, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn readVariable(memory: std.mem.Allocator, item: Value) error{OutOfMemory}!Variable {
    if (item != .object) return .{ .key = "" };
    const object = item.object;
    var options: []const []const u8 = &.{};
    if (object.get("options")) |list| if (list == .array) {
        const names = try memory.alloc([]const u8, list.array.items.len);
        var count: usize = 0;
        for (list.array.items) |option| if (option == .string) {
            names[count] = option.string;
            count += 1;
        };
        options = names[0..count];
    };
    return .{
        .key = text(object.get("key"), ""),
        .kind = VariableKind.fromLabel(text(object.get("kind"), "")),
        .lower = number(object.get("lo"), 0),
        .upper = number(object.get("hi"), 1),
        .options = options,
        .group = text(object.get("group"), ""),
        .free = flag(object.get("free"), false),
    };
}

fn readConstraint(item: Value) Constraint {
    if (item != .object) return .{ .key = "" };
    const object = item.object;
    return .{
        .key = text(object.get("key"), ""),
        .comparison = Comparison.fromSymbol(text(object.get("op"), "")),
        .value = number(object.get("value"), 0),
        .active = flag(object.get("active"), true),
        .tolerance = number(object.get("tol"), 0.02),
    };
}

fn text(value: ?Value, fallback: []const u8) []const u8 {
    const found = value orelse return fallback;
    return if (found == .string) found.string else fallback;
}

fn number(value: ?Value, fallback: f64) f64 {
    const found = value orelse return fallback;
    return switch (found) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => fallback,
    };
}

fn flag(value: ?Value, fallback: bool) bool {
    const found = value orelse return fallback;
    return if (found == .bool) found.bool else fallback;
}

const sample =
    \\{"formato": "aeroopt/1", "name": "Micro de teste",
    \\ "variables": [
    \\  {"key": "wing.span", "kind": "contínua", "lo": 1.4, "hi": 1.85, "options": [], "group": "asa", "free": true},
    \\  {"key": "wing.airfoil", "kind": "lista", "lo": 0, "hi": 1, "options": ["S1223HiRes", "NACA 4412"], "group": "asa", "free": true},
    \\  {"key": "power.n_motors", "kind": "inteira", "lo": 1, "hi": 2, "options": [], "group": "propulsão", "free": false}],
    \\ "constraints": [{"key": "V_S", "op": "≤", "value": 13.0, "active": true, "tol": 0.02},
    \\                 {"key": "c_root", "op": "≥", "value": 0.2, "active": false, "tol": 0.02}],
    \\ "scoring": "sae_br_2026_micro", "evaluator": "etapas",
    \\ "solver": {"seed": 1},
    \\ "params": {"categorias": ["asa alta", "cauda em V"], "etapas": {"população": 16}}}
;

test "lê o problema como a janela em Python grava" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const problem = try parse(arena.allocator(), sample);
    try std.testing.expectEqualStrings("Micro de teste", problem.name);
    try std.testing.expectEqual(@as(usize, 3), problem.variables.len);
    try std.testing.expectEqual(VariableKind.list, problem.variables[1].kind);
    try std.testing.expectEqualStrings("NACA 4412", problem.variables[1].options[1]);
    try std.testing.expectEqual(VariableKind.integer, problem.variables[2].kind);
    try std.testing.expectEqual(@as(usize, 2), problem.freeCount());
    try std.testing.expectEqual(Comparison.at_least, problem.constraints[1].comparison);
    try std.testing.expect(!problem.constraints[1].active);
    try std.testing.expectEqualStrings("sae_br_2026_micro", problem.scoring);
    try std.testing.expectEqual(@as(usize, 2), problem.param("categorias").?.array.items.len);
}

test "gravar e ler de novo dá o mesmo problema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const first = try parse(memory, sample);
    const again = try parse(memory, try write(memory, &first));
    try std.testing.expectEqual(first.variables.len, again.variables.len);
    for (first.variables, again.variables) |a, b| {
        try std.testing.expectEqualStrings(a.key, b.key);
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.lower, b.lower);
        try std.testing.expectEqual(a.upper, b.upper);
        try std.testing.expectEqual(a.free, b.free);
        try std.testing.expectEqual(a.options.len, b.options.len);
    }
    try std.testing.expectEqual(first.constraints[0].comparison, again.constraints[0].comparison);
    try std.testing.expectEqual(@as(i64, 16), again.param("etapas").?.object.get("população").?.integer);
}

test "isolar solta só as numéricas do grupo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem = try parse(arena.allocator(), sample);
    problem.isolate(&.{"propulsão"});
    try std.testing.expect(!problem.variables[0].free); // a envergadura (asa) fica presa
    try std.testing.expect(problem.variables[1].free); // a lista fica como estava
    try std.testing.expect(problem.variables[2].free);
}

test "um arquivo de outro formato não abre" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotProblem, parse(arena.allocator(), "{\"formato\": \"outro/2\"}"));
    try std.testing.expectError(error.NotProblem, parse(arena.allocator(), "[1, 2]"));
}

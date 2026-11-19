//! O problema e o projeto da sprint: o valor que o avião tem em cada entrada (a coluna "valor do avião"), o que
//! uma variável de lista pode escolher (perfis, motores, hélices, baterias, escolhas), o problema montado a partir
//! das variáveis do projeto e a restrição que vira limite de uma variável (como `from_project`, `available` e
//! `fold_bounds` do aeroopt em Python).
const std = @import("std");
const design = @import("design");
const registry = design.registry;
const catalog = @import("catalog");
const problem_mod = @import("problem.zig");
const inputs = @import("inputs.zig");

const store = design.store;
const Problem = problem_mod.Problem;
const Value = std.json.Value;

/// o grupo antigo das variáveis do projeto (o `GROUPS` do Python), guardado no arquivo
fn projectGroup(key: []const u8) []const u8 {
    const prefix = key[0 .. std.mem.indexOfScalar(u8, key, '.') orelse key.len];
    if (std.mem.eql(u8, prefix, "wing")) return "asa";
    if (std.mem.eql(u8, prefix, "power")) return "propulsão";
    if (std.mem.eql(u8, prefix, "req")) return "requisitos";
    return "";
}

/// o campo do projeto de uma entrada (`null` se a parte ou o campo não existe no arquivo)
pub fn field(project: *store.Project, item: *const inputs.Input) ?Value {
    const dot = std.mem.indexOfScalar(u8, item.path, '.') orelse return null;
    const part = project.root.object.get(item.path[0..dot]) orelse return null;
    if (part != .object) return null;
    return part.object.get(item.path[dot + 1 ..]);
}

/// o valor do avião numa entrada, como texto ("1.75", "NACA 2412", "sim"); "—" se o projeto não tem o campo
pub fn valueText(buffer: []u8, project: *store.Project, item: *const inputs.Input) []const u8 {
    const value = field(project, item) orelse return "—";
    return switch (value) {
        .float => |x| std.fmt.bufPrint(buffer, "{d}", .{x}) catch "—",
        .integer => |x| std.fmt.bufPrint(buffer, "{d}", .{x}) catch "—",
        .string => |text| if (text.len == 0) "(vazio)" else text,
        .bool => |yes| if (yes) "sim" else "não",
        else => "—",
    };
}

/// o valor numérico do avião numa entrada (`null` se não é número)
pub fn valueNumber(project: *store.Project, item: *const inputs.Input) ?f64 {
    const value = field(project, item) orelse return null;
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => null,
    };
}

/// tudo o que uma variável de lista pode escolher: os perfis do projeto e da biblioteca, os itens do catálogo, ou as
/// escolhas fixas do campo
pub fn available(memory: std.mem.Allocator, io: std.Io, project: ?*store.Project, item: *const inputs.Input) ![]const []const u8 {
    return switch (item.source) {
        .choices, .yes_no, .none => item.choices,
        .motors => try catalog.motorNames(memory),
        .propellers => try catalog.propellerNames(memory),
        .batteries => blk: {
            const names = try memory.alloc([]const u8, catalog.batteries.len);
            for (catalog.batteries, names) |battery, *name| name.* = battery.name;
            break :blk names;
        },
        .airfoils => try airfoilNames(memory, io, project),
    };
}

/// os perfis: os do projeto (etapa Perfil) e os .dat de `data/airfoils` (o nome é a primeira linha do arquivo)
fn airfoilNames(memory: std.mem.Allocator, io: std.Io, project: ?*store.Project) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (project) |opened| if (opened.root.object.get("airfoils")) |list| if (list == .array) for (list.array.items) |entry| {
        const name = airfoilEntryName(entry);
        if (name.len > 0 and !contains(out.items, name)) try out.append(memory, name);
    };
    for ([_][]const u8{ "data/airfoils", "../data/airfoils" }) |folder| {
        var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var walker = dir.iterate();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".dat")) continue;
            const bytes = dir.readFileAlloc(io, entry.name, memory, .limited(1 << 20)) catch continue;
            const line_end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
            const name = std.mem.trim(u8, bytes[0..line_end], " \t");
            if (name.len > 0 and !contains(out.items, name) and !contains(names.items, name)) try names.append(memory, name);
        }
        std.mem.sort([]const u8, names.items, {}, lessText);
        try out.appendSlice(memory, names.items);
        break;
    }
    return out.items;
}

fn airfoilEntryName(entry: Value) []const u8 {
    if (entry != .object) return "";
    if (entry.object.get("name")) |name| if (name == .string) return name.string;
    const inner = entry.object.get("airfoil") orelse return "";
    if (inner != .object) return "";
    const name = inner.object.get("name") orelse return "";
    return if (name == .string) name.string else "";
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// o problema que as variáveis do projeto descrevem (as "calculado" são saídas e ficam de fora); a pontuação começa
/// na do Micro, como na tela antiga
pub fn fromProject(memory: std.mem.Allocator, project: *store.Project, name: []const u8) !Problem {
    var variables: std.ArrayList(problem_mod.Variable) = .empty;
    if (project.root.object.get("variables")) |list| if (list == .array) for (list.array.items) |entry| {
        if (entry != .object) continue;
        const object = &entry.object;
        const mode = store.text(object, "mode", "fixo");
        if (std.mem.eql(u8, mode, "calculado")) continue;
        const key = store.text(object, "key", "");
        if (key.len == 0) continue;
        var options: std.ArrayList([]const u8) = .empty;
        if (object.get("options")) |items| if (items == .array) for (items.array.items) |option| if (option == .string) try options.append(memory, option.string);
        const known = registry.input(key);
        const kind: problem_mod.VariableKind = if (known) |input| (if (std.mem.eql(u8, input.unit, "lista")) .list else if (input.integer) .integer else .continuous) else if (inputs.find(key)) |item| item.kind else .continuous;
        try variables.append(memory, .{ .key = key, .kind = kind, .lower = store.number(object, "lo", 0), .upper = store.number(object, "hi", 1), .options = options.items, .group = projectGroup(key), .free = std.mem.eql(u8, mode, "variável") });
    };
    var constraints: std.ArrayList(problem_mod.Constraint) = .empty;
    if (project.root.object.get("requirements")) |requirements| if (requirements == .object) if (requirements.object.get("constraints")) |list| if (list == .array) for (list.array.items) |entry| {
        const read = registry.readConstraint(entry);
        try constraints.append(memory, .{ .key = read.key, .comparison = problem_mod.Comparison.fromSymbol(read.op), .value = read.value, .active = read.active, .tolerance = read.tol });
    };
    var solver: std.json.ObjectMap = .empty;
    var params: std.json.ObjectMap = .empty;
    if (project.root.object.get("mdo")) |mdo| if (mdo == .object) {
        for ([_][]const u8{ "method", "particles", "iterations", "seed", "penalty" }) |key| if (mdo.object.get(key)) |value| try solver.put(memory, key, value);
        for ([_][]const u8{ "kind", "m_max", "tail_area_frac", "fuselage_CDS", "airfoil_dir" }) |key| if (mdo.object.get(key)) |value| try params.put(memory, key, value);
    };
    return .{
        .name = try memory.dupe(u8, name),
        .variables = variables.items,
        .constraints = constraints.items,
        .scoring = "sae_br_2026_micro",
        .evaluator = "mini-MDO",
        .solver = .{ .object = solver },
        .params = .{ .object = params },
    };
}

/// uma grandeza que é também variável do problema (envergadura, área, nº de motores) não fica como restrição: a
/// restrição ligada vira o limite da variável (≤ → superior, ≥ → inferior, = → os dois) e sai da lista. Devolve
/// quantas viraram limite
pub fn foldBounds(opened: *Problem) usize {
    var kept: usize = 0;
    var folded: usize = 0;
    for (opened.constraints) |constraint| {
        const key = registry.constraintInput(constraint.key) orelse {
            opened.constraints[kept] = constraint;
            kept += 1;
            continue;
        };
        const variable = opened.variable(key) orelse {
            opened.constraints[kept] = constraint;
            kept += 1;
            continue;
        };
        if (!constraint.active) continue;
        switch (constraint.comparison) {
            .at_most => variable.upper = @min(variable.upper, constraint.value),
            .at_least => variable.lower = @max(variable.lower, constraint.value),
            .equal => {
                variable.lower = constraint.value;
                variable.upper = constraint.value;
            },
        }
        variable.lower = @min(variable.lower, variable.upper);
        folded += 1;
    }
    opened.constraints = opened.constraints[0..kept];
    return folded;
}

test "problema a partir do projeto, limites das restrições e valor do avião" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const text =
        \\{"wing_draft":{"span":1.75,"airfoil":"NACA 2412"},"tail_draft":{"wing2_join":false},
        \\ "requirements":{"constraints":[{"key":"V_S","op":"≤","value":14,"active":true,"tol":0.02},
        \\   {"key":"b","op":"≤","value":2.5,"active":true,"tol":0.02}]},
        \\ "variables":[{"key":"wing.span","mode":"variável","lo":1.0,"hi":3.0,"options":[]},
        \\   {"key":"wing.area","mode":"calculado","lo":0.3,"hi":1.5,"options":[]},
        \\   {"key":"wing.airfoil","mode":"fixo","lo":0,"hi":1,"options":["S1223"]}],
        \\ "mdo":{"objective":"MTOW","method":"PSO","particles":24,"kind":"monoplano","m_max":30.0}}
    ;
    var project: store.Project = .{ .arena = &arena, .root = try std.json.parseFromSliceLeaky(Value, memory, text, .{}), .folder = "" };
    var opened = try fromProject(memory, &project, "teste");
    try std.testing.expectEqual(@as(usize, 2), opened.variables.len); // a "calculado" fica de fora
    try std.testing.expect(opened.variables[0].free and !opened.variables[1].free);
    try std.testing.expectEqual(problem_mod.VariableKind.list, opened.variables[1].kind);
    try std.testing.expectEqual(@as(usize, 2), opened.constraints.len);
    try std.testing.expectEqual(@as(usize, 1), foldBounds(&opened));
    try std.testing.expectEqual(@as(usize, 1), opened.constraints.len); // a envergadura virou limite
    try std.testing.expectEqual(@as(f64, 2.5), opened.variables[0].upper);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.75", valueText(&buffer, &project, inputs.find("wing.span").?));
    try std.testing.expectEqualStrings("NACA 2412", valueText(&buffer, &project, inputs.find("wing.airfoil").?));
    try std.testing.expectEqualStrings("não", valueText(&buffer, &project, inputs.find("tail.wing2_join").?));
    try std.testing.expectEqualStrings("—", valueText(&buffer, &project, inputs.find("wing.taper").?));
    const motors = try available(memory, std.testing.io, null, inputs.find("power.motor").?);
    try std.testing.expect(motors.len >= 2);
}

//! A etapa "Condições e restrições" em Zig (`RequirementsStage` de `stages.py`): as condições e as regras de projeto
//! em formulário e duas tabelas editáveis, a das restrições (liga, grandeza, operador, valor) e a das variáveis
//! (fixo, variável entre mín. e máx., calculado; opções das listas).
const std = @import("std");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");

const Value = std.json.Value;

const requirements_prefix = "req.";
const rules_prefix = "rules.";

const constraint_columns = [_]simulation.Column{
    .{ .key = "active", .label = "ativa", .kind = .check, .help = "ligue ou desligue sem perder o valor" },
    .{ .key = "key", .label = "grandeza", .kind = .choice, .choices = &registry.quantity_labels, .help = "o que se limita" },
    .{ .key = "op", .label = "op.", .kind = .choice, .choices = &registry.operators, .help = "≤, ≥ ou = (com a tolerância de 2 %)" },
    .{ .key = "value", .label = "valor", .help = "o limite" },
    .{ .key = "unit", .label = "unid.", .kind = .label },
    .{ .key = "calc", .label = "calculado", .kind = .label, .help = "o valor da última etapa que rodou" },
    .{ .key = "status", .label = "situação", .kind = .label, .help = "desligada, ✔ cumpre ou ✖ não cumpre" },
};

const variable_columns = [_]simulation.Column{
    .{ .key = "label", .label = "entrada", .kind = .label },
    .{ .key = "mode", .label = "modo", .kind = .choice, .choices = &registry.modes, .help = "fixo: o valor do rascunho; variável: o otimizador procura entre mín. e máx. (listas: entre as opções); calculado: sai das contas" },
    .{ .key = "value", .label = "valor (fixo)", .kind = .text, .help = "o valor do rascunho da etapa" },
    .{ .key = "lo", .label = "mín." },
    .{ .key = "hi", .label = "máx." },
    .{ .key = "options", .label = "opções (listas)", .kind = .text, .help = "os nomes separados por vírgula; vazio = todos" },
};

/// muda o projeto conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    _ = memory;
    const project = &context.project;
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        var changed = try stages.applyFields(project, project.section("requirements"), &registry.requirement_fields, requirements_prefix, values);
        changed += try stages.applyFields(project, project.section("rules"), &registry.rule_fields, rules_prefix, values);
        if (changed > 0 and !context.save()) return "não deu para gravar o projeto";
        return "";
    }
    if (std.mem.eql(u8, request.do, "grid")) {
        if (std.mem.eql(u8, request.grid, "restricoes")) try editConstraint(project, request) else if (std.mem.eql(u8, request.grid, "variaveis")) try editVariable(project, request) else return error.UnknownGrid;
        if (!context.save()) return "não deu para gravar o projeto";
    }
    return "";
}

fn numberOf(value: Value) ?f64 {
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .string => |digits| blk: {
            var buffer: [64]u8 = undefined;
            const length = @min(digits.len, buffer.len);
            @memcpy(buffer[0..length], digits[0..length]);
            std.mem.replaceScalar(u8, buffer[0..length], ',', '.');
            break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, buffer[0..length], " ")) catch null;
        },
        else => null,
    };
}

fn editConstraint(project: *store.Project, request: stages.Request) !void {
    const rows = try registry.constraintList(project);
    if (std.mem.eql(u8, request.edit, "add")) return rows.append(try registry.constraintValue(project.memory(), .{ .key = "S", .op = "≤", .value = 1.0 }));
    if (rows.items.len == 0) return;
    const index = stages.within(request.row, rows.items.len) orelse rows.items.len - 1;
    if (std.mem.eql(u8, request.edit, "delete")) {
        _ = rows.orderedRemove(index);
        return;
    }
    if (!std.mem.eql(u8, request.edit, "set")) return error.UnknownEdit;
    const item = &rows.items[index];
    if (item.* != .object) return;
    const object = &item.object;
    if (std.mem.eql(u8, request.key, "active")) {
        try object.put(project.memory(), "active", .{ .bool = request.value == .bool and request.value.bool });
    } else if (std.mem.eql(u8, request.key, "key")) {
        if (request.value == .string) if (registry.quantityKey(request.value.string)) |key| try object.put(project.memory(), "key", .{ .string = key });
    } else if (std.mem.eql(u8, request.key, "op")) {
        if (request.value == .string) try store.setText(project, object, "op", request.value.string);
    } else if (std.mem.eql(u8, request.key, "value")) {
        if (numberOf(request.value)) |number| try store.setNumber(project, object, "value", number);
    }
}

fn editVariable(project: *store.Project, request: stages.Request) !void {
    const rows = try registry.variableList(project);
    if (std.mem.eql(u8, request.edit, "bounds")) return registry.boundsFromConstraints(project);
    if (!std.mem.eql(u8, request.edit, "set")) return error.UnknownEdit;
    const index = stages.within(request.row, rows.items.len) orelse return;
    const item = &rows.items[index];
    if (item.* != .object) return;
    const object = &item.object;
    if (std.mem.eql(u8, request.key, "mode")) {
        if (request.value == .string) try store.setText(project, object, "mode", request.value.string);
    } else if (std.mem.eql(u8, request.key, "lo") or std.mem.eql(u8, request.key, "hi")) {
        if (numberOf(request.value)) |number| try store.setNumber(project, object, request.key, number);
    } else if (std.mem.eql(u8, request.key, "value")) {
        const input = registry.input(store.text(object, "key", "")) orelse return;
        const place = registry.inputPlace(input);
        const section = project.section(place[0]);
        if (std.mem.eql(u8, input.unit, "lista")) {
            if (request.value == .string) try store.setText(project, section, place[1], request.value.string);
        } else if (numberOf(request.value)) |number| try store.setNumber(project, section, place[1], number);
    } else if (std.mem.eql(u8, request.key, "options")) {
        if (request.value != .string) return;
        var options = std.json.Array.init(project.memory());
        var parts = std.mem.splitScalar(u8, request.value.string, ',');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part, " ");
            if (name.len > 0) try options.append(.{ .string = try project.memory().dupe(u8, name) });
        }
        // escolheu opções: a busca varia entre elas (como na PyQt)
        if (options.items.len > 0 and std.mem.eql(u8, store.text(object, "mode", "fixo"), "fixo")) try object.put(project.memory(), "mode", .{ .string = "variável" });
        try object.put(project.memory(), "options", .{ .array = options });
    }
}

/// a página: o formulário das condições e das regras e as duas tabelas
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const project = &context.project;
    var params: std.ArrayList(simulation.Param) = .empty;
    for (registry.requirement_fields) |field| try params.append(memory, try stages.fieldParam(project.section("requirements"), field, requirements_prefix, "Condições", memory));
    for (registry.rule_fields) |field| try params.append(memory, try stages.fieldParam(project.section("rules"), field, rules_prefix, "Regras de projeto", memory));

    // as restrições
    const constraints = try registry.constraintList(project);
    const constraint_rows = try memory.alloc([]const simulation.Cell, constraints.items.len);
    for (constraints.items, constraint_rows) |item, *row| {
        const constraint = registry.readConstraint(item);
        const info = registry.quantity(constraint.key);
        // o valor da última etapa que calculou a grandeza (a asa ou o avião montado) e se ele cumpre
        const last = context.lastComputed(constraint.key);
        var buffer: [32]u8 = undefined;
        const computed: []const u8 = if (last) |value| try memory.dupe(u8, registry.format(&buffer, value)) else "—";
        const situation: []const u8 = if (!constraint.active) "desligada" else if (last) |value| (if (constraint.holds(value)) "✔ cumpre" else "✖ não cumpre") else "—";
        row.* = try memory.dupe(simulation.Cell, &.{ .{ .flag = constraint.active }, .{ .text = info.label }, .{ .text = constraint.op }, .{ .number = constraint.value }, .{ .text = info.unit }, .{ .text = computed }, .{ .text = situation } });
    }
    // as variáveis
    const variables = try registry.variableList(project);
    const variable_rows = try memory.alloc([]const simulation.Cell, variables.items.len);
    for (variables.items, variable_rows) |item, *row| {
        const object = &item.object;
        const key = store.text(object, "key", "");
        const input = registry.input(key) orelse registry.Input{ .key = key, .path = "x.x", .label = key };
        const listed = std.mem.eql(u8, input.unit, "lista");
        const place = registry.inputPlace(input);
        const section = project.section(place[0]);
        const label = if (listed or input.unit.len == 0) input.label else try std.fmt.allocPrint(memory, "{s} ({s})", .{ input.label, input.unit });
        const shown = if (listed) store.text(section, place[1], "") else try std.fmt.allocPrint(memory, "{d}", .{store.number(section, place[1], 0)});
        var options: std.ArrayList(u8) = .empty;
        if (object.get("options")) |list| if (list == .array) for (list.array.items, 0..) |option, k| {
            if (k > 0) try options.appendSlice(memory, ", ");
            if (option == .string) try options.appendSlice(memory, option.string);
        };
        row.* = try memory.dupe(simulation.Cell, &.{
            .{ .text = label },
            .{ .text = store.text(object, "mode", "fixo") },
            .{ .text = shown },
            if (listed) .empty else .{ .number = store.number(object, "lo", input.lo) },
            if (listed) .empty else .{ .number = store.number(object, "hi", input.hi) },
            if (listed) .{ .text = options.items } else .empty,
        });
    }
    const grids = try memory.dupe(simulation.Grid, &.{
        .{ .name = "restricoes", .title = "Restrições", .columns = &constraint_columns, .rows = constraint_rows, .note = "as etapas conferem as ativas no diagnóstico; o estudo marca como inviável o ponto que não cumpre", .help = "restrições de projeto; 'calculado' é o valor da última etapa que rodou", .buttons = &.{ .{ .operation = "add", .label = "+ restrição" }, .{ .operation = "delete", .label = "− restrição" } } },
        .{ .name = "variaveis", .title = "Variáveis", .columns = &variable_columns, .rows = variable_rows, .note = "PV e MTOW são saídas. 'Limites das restrições' leva as restrições ativas para o mín. e o máx. (envergadura, área, nº de motores)", .help = "entradas de projeto: o que fica fixo, o que o otimizador varia e o que sai das contas", .buttons = &.{.{ .operation = "bounds", .label = "Limites das restrições" }} },
    });
    return .{ .title = "Condições e restrições", .keep_label = "", .params = params.items, .grids = grids, .message = try registry.requirementsSummary(memory, project) };
}

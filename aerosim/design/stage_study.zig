//! A etapa "Estudo e ponto de projeto" em Zig (`aerosim/design/study.py`): as áreas se retroalimentam e o estudo
//! mostra onde estabilidade e desempenho fecham juntos. Cada ponto é um ponto de projeto acoplado (massa de projeto
//! → asa e EH recalibradas, com o momento da tração → desempenho → MTOW pela pista → massa de projeto ... até
//! convergir) em cada altitude-densidade pedida. Dois modos: varrer uma variável de um avião, ou comparar os aviões
//! guardados na etapa Motores. O estudo marca o maior MTOW viável de cada altitude; "Usar o ponto marcado" leva o
//! valor para o rascunho da etapa certa. (A conferência no 6GDL fica para a aba Missão.)
const std = @import("std");
const core = @import("aerosim");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");
const tail_stage = @import("stage_tail.zig");
const power_stage = @import("stage_power.zig");
const wing_stage = @import("stage_wing.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

const modes = [_][]const u8{ "varrer uma variável", "comparar aviões guardados" };
const draft_name = "(rascunho da etapa Motores)";

/// o que se varre: o rótulo, a etapa (power, tail, wing) e o campo
const Variable = struct { label: []const u8, stage: enum { power, tail, wing }, key: []const u8 };
const variables = [_]Variable{
    .{ .label = "inclinação do motor (°)", .stage = .power, .key = "tilt" },
    .{ .label = "margem estática (% CMA)", .stage = .tail, .key = "sm_target" },
    .{ .label = "volume de cauda V_H", .stage = .tail, .key = "VH" },
    .{ .label = "braço da cauda (m)", .stage = .tail, .key = "arm" },
    .{ .label = "área da asa (m²)", .stage = .wing, .key = "area" },
    .{ .label = "envergadura (m)", .stage = .wing, .key = "span" },
    .{ .label = "ângulo de cruzeiro (°)", .stage = .wing, .key = "alpha_cruise" },
};
const variable_labels = blk: {
    var labels: [variables.len][]const u8 = undefined;
    for (variables, 0..) |item, k| labels[k] = item.label;
    break :blk labels;
};

const study_fields = [_]registry.Field{
    .{ .key = "mode", .label = "estudo", .default = .{ .text = modes[0] }, .choices = &modes },
    .{ .key = "aircraft", .label = "avião", .help = "um dos guardados na etapa Motores ou o rascunho dela", .default = .{ .text = draft_name } },
    .{ .key = "variable", .label = "variável", .default = .{ .text = variables[0].label }, .choices = &variable_labels },
    .{ .key = "start", .label = "de", .default = .{ .number = 0 }, .minimum = -100, .maximum = 100 },
    .{ .key = "stop", .label = "até", .default = .{ .number = 12 }, .minimum = -100, .maximum = 100 },
    .{ .key = "n", .label = "pontos", .default = .{ .number = 7 }, .minimum = 1, .maximum = 60, .integer = true },
    .{ .key = "places", .label = "altitudes-densidade", .help = "lugar=AD em metros, separados por vírgula (ex.: Joinville=655, São José dos Campos=1320); vazio: a dos requisitos", .default = .{ .text = "" } },
};

const plots = [_]simulation.Plot{
    .{ .key = "mtow", .title = "MTOW", .xlabel = "", .ylabel = "kg" },
    .{ .key = "rot", .title = "Rotação e saída", .xlabel = "", .ylabel = "m/s" },
    .{ .key = "trim", .title = "Trimagem da EH", .xlabel = "", .ylabel = "°" },
    .{ .key = "cdt", .title = "Arrasto de trimagem", .xlabel = "", .ylabel = "$C_{D,trim}$" },
};
const colors = [_][]const u8{ "#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e" };

fn params(project: *store.Project) *ObjectMap {
    return project.section("study");
}

fn variableOf(label: []const u8) Variable {
    for (variables) |item| if (std.mem.eql(u8, item.label, label)) return item;
    return variables[0];
}

/// uma linha do estudo (`point_row`)
const Row = struct {
    place: []const u8,
    ad: f64,
    x: f64,
    name: []const u8,
    mtow: f64,
    converged: bool,
    ok: bool,
    why: []const u8,
    limit: []const u8,
    pv: f64,
    v_rot: f64,
    v_lof: f64,
    hold: f64,
    dih: f64,
    cd_trim: f64,
    incidence: f64,
    i_h: f64,
};

/// os lugares: "nome=AD, ..." (vazio: a altitude dos requisitos)
fn parsePlaces(memory: std.mem.Allocator, text: []const u8, fallback: f64) ![]const struct { []const u8, f64 } {
    var out: std.ArrayList(struct { []const u8, f64 }) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        const equal = std.mem.lastIndexOfScalar(u8, part, '=');
        const digits = std.mem.trim(u8, if (equal) |at| part[at + 1 ..] else part, " ");
        const ad = std.fmt.parseFloat(f64, digits) catch continue;
        const name = if (equal) |at| std.mem.trim(u8, part[0..at], " ") else "";
        try out.append(memory, .{ if (name.len > 0) name else try std.fmt.allocPrint(memory, "AD {d:.0} m", .{ad}), ad });
    }
    if (out.items.len == 0) try out.append(memory, .{ try std.fmt.allocPrint(memory, "AD {d:.0} m", .{fallback}), fallback });
    return out.items;
}

/// um número de uma seção do projeto, trocado por um tempo (devolve o valor antigo para pôr de volta)
const Swap = struct {
    object: *ObjectMap,
    key: []const u8,
    old: ?Value,

    fn set(project: *store.Project, object: *ObjectMap, key: []const u8, value: f64) !Swap {
        const swap: Swap = .{ .object = object, .key = key, .old = object.get(key) };
        try object.put(project.memory(), key, .{ .float = value });
        return swap;
    }
    fn restore(swap: Swap, project: *store.Project) void {
        if (swap.old) |old| swap.object.put(project.memory(), swap.key, old) catch {} else _ = swap.object.orderedRemove(swap.key);
    }
};

/// o ponto de projeto acoplado (`design_point`): a massa de projeto anda até o MTOW pela pista
pub fn designPoint(context: *stages.Context, memory: std.mem.Allocator, power: *const ObjectMap) !?struct { assembled: *power_stage.Assembled, mass: f64, converged: bool } {
    const project = &context.project;
    const requirements = project.section("requirements");
    const tolerance = registry.fieldNumber(project.section("rules"), &registry.rule_fields, "ref_massa_tol");
    const rounds: usize = @intFromFloat(@max(@round(registry.fieldNumber(project.section("rules"), &registry.rule_fields, "ref_massa_voltas")), 1));
    var mass = registry.fieldNumber(requirements, &registry.requirement_fields, "mass");
    var history: std.ArrayList([2]f64) = .empty;
    var last: ?*power_stage.Assembled = null;
    var floor: f64 = 0;
    const At = struct {
        fn run(ctx: *stages.Context, mem: std.mem.Allocator, power_params: *const ObjectMap, value: f64) !?*power_stage.Assembled {
            const swap = try Swap.set(&ctx.project, ctx.project.section("requirements"), "mass", value);
            defer swap.restore(&ctx.project);
            return power_stage.assemble(ctx, mem, power_params);
        }
    };
    for (0..rounds) |_| {
        const assembled = try At.run(context, memory, power, mass) orelse return null;
        last = assembled;
        floor = assembled.empty;
        try history.append(memory, .{ mass, assembled.runway_mtow });
        if (!std.math.isFinite(assembled.runway_mtow) or @abs(assembled.runway_mtow - mass) < tolerance) break;
        mass = @max(0.5 * (mass + assembled.runway_mtow), floor);
    }
    // quando o MTOW anda quase junto com a massa, a média demora: secante em g(m) = MTOW(m) − m
    if (history.items.len >= 2 and std.math.isFinite(history.items[history.items.len - 1][1]) and @abs(history.items[history.items.len - 1][1] - history.items[history.items.len - 1][0]) >= tolerance) {
        for (0..rounds) |_| {
            const previous = history.items[history.items.len - 2];
            const current = history.items[history.items.len - 1];
            const next = core.optim.scalar.secant(.{ previous[0], previous[1] - previous[0] }, .{ current[0], current[1] - current[0] }) orelse break;
            mass = @max(next, floor);
            const assembled = try At.run(context, memory, power, mass) orelse break;
            last = assembled;
            floor = assembled.empty;
            try history.append(memory, .{ mass, assembled.runway_mtow });
            if (!std.math.isFinite(assembled.runway_mtow) or @abs(assembled.runway_mtow - mass) < tolerance) break;
        }
    }
    const final = history.items[history.items.len - 1];
    return .{ .assembled = last.?, .mass = final[0], .converged = history.items.len > 1 and std.math.isFinite(final[1]) and @abs(final[1] - final[0]) < tolerance };
}

/// viável: converge e a estabilidade fecha nessa massa (`feasibility`); devolve os motivos (vazio: viável)
pub fn feasibility(context: *stages.Context, memory: std.mem.Allocator, assembled: *const power_stage.Assembled, converged: bool, set_params: *const ObjectMap) ![]const u8 {
    var why: std.ArrayList(u8) = .empty;
    const Add = struct {
        fn add(list: *std.ArrayList(u8), mem: std.mem.Allocator, text: []const u8) !void {
            if (list.items.len > 0) try list.appendSlice(mem, "; ");
            try list.appendSlice(mem, text);
        }
    };
    if (!std.math.isFinite(assembled.runway_mtow)) try Add.add(&why, memory, "não decola na pista") else if (!converged) try Add.add(&why, memory, "massa de projeto não converge");
    if (assembled.liftoff_speed > 0 and !std.math.isFinite(assembled.rotation_speed)) try Add.add(&why, memory, "o profundor não consegue rodar o avião");
    if (!assembled.hold_ok) try Add.add(&why, memory, "trim de decolagem passa do curso de picar");
    const result = assembled.built.result;
    if (result.statics != null and !(result.tail_lift_low <= result.tail_lift_needed and result.tail_lift_needed <= result.tail_lift_high)) try Add.add(&why, memory, "EH estola no C_L,max");
    if (!assembled.battery_fits) try Add.add(&why, memory, try std.fmt.allocPrint(memory, "precisa de {d:.2} kg de lastro de equilíbrio", .{assembled.ballast}));
    const margin_min = store.number(set_params, "sm_min", 5);
    if (assembled.payload_moved and assembled.margin_empty < margin_min) try Add.add(&why, memory, try std.fmt.allocPrint(memory, "sem a carga paga a margem estática cai para {d:.1} %", .{assembled.margin_empty}));
    const values = [_]struct { key: []const u8, value: f64 }{
        .{ .key = "length", .value = assembled.length },  .{ .key = "n_motor", .value = @floatFromInt(assembled.plane.propulsion.len) },
        .{ .key = "sm", .value = assembled.margin },      .{ .key = "pv", .value = assembled.empty },
        .{ .key = "S", .value = assembled.built.wing.area }, .{ .key = "b", .value = assembled.built.wing.span },
        .{ .key = "V_S", .value = assembled.stall_speed }, .{ .key = "V_max", .value = assembled.max_speed },
        .{ .key = "RC", .value = assembled.climb_max },    .{ .key = "TW", .value = assembled.thrust_weight },
    };
    for ((try registry.constraintList(&context.project)).items) |item| {
        const constraint = registry.readConstraint(item);
        if (!constraint.active) continue;
        const value = for (values) |pair| {
            if (std.mem.eql(u8, pair.key, constraint.key)) break pair.value;
        } else continue;
        if (constraint.holds(value)) continue;
        var buffer: [32]u8 = undefined;
        var limit: [32]u8 = undefined;
        const info = registry.quantity(constraint.key);
        try Add.add(&why, memory, try std.fmt.allocPrint(memory, "{s}: {s} {s} {s}", .{ info.label, registry.format(&buffer, value), constraint.op, registry.format(&limit, constraint.value) }));
    }
    return why.items;
}

/// o objeto da variável no projeto (o rascunho de Motores, o conjunto dele ou a primeira asa dele)
fn targetOf(context: *stages.Context, memory: std.mem.Allocator, power: *ObjectMap, variable: Variable) !?*ObjectMap {
    const project = &context.project;
    return switch (variable.stage) {
        .power => power,
        .tail => power_stage.chosenSet(project, power),
        .wing => blk: {
            const set = power_stage.chosenSet(project, power) orelse break :blk null;
            _ = set;
            const wings = try tail_stage.placedWings(project, memory);
            if (wings.len == 0) break :blk null;
            break :blk wing_stage.wingOrDraft(project, wings[0].name);
        },
    };
}

/// o avião do estudo: um guardado (os parâmetros dele) ou o rascunho de Motores
fn powerParams(project: *store.Project, name: []const u8) *ObjectMap {
    for (project.list("aircraft").items) |item| if (item == .object and std.mem.eql(u8, store.nameOf(item), name)) {
        if (store.child(&item.object, "params")) |found| return found;
    };
    return project.section("power_draft");
}

fn point(context: *stages.Context, memory: std.mem.Allocator, power: *ObjectMap, place: []const u8, ad: f64, x: f64, name: []const u8) !?Row {
    const project = &context.project;
    const swap = try Swap.set(project, project.section("requirements"), "density_altitude", ad);
    defer swap.restore(project);
    const found = try designPoint(context, memory, power) orelse return null;
    const assembled = found.assembled;
    const set_params = power_stage.chosenSet(project, power) orelse return null;
    const why = try feasibility(context, memory, assembled, found.converged, set_params);
    return .{
        .place = place,
        .ad = ad,
        .x = x,
        .name = name,
        .mtow = assembled.runway_mtow,
        .converged = found.converged,
        .ok = why.len == 0,
        .why = why,
        .limit = if (assembled.rotation_speed > assembled.liftoff_speed and assembled.liftoff_speed > 0) "rotação" else "pista",
        .pv = assembled.empty,
        .v_rot = assembled.rotation_speed,
        .v_lof = assembled.liftoff_speed,
        .hold = assembled.hold,
        .dih = assembled.incidence_change,
        .cd_trim = assembled.cruise_trim_drag,
        .incidence = assembled.built.wing.incidence,
        .i_h = assembled.built.result.incidence_h,
    };
}

/// roda o estudo e guarda as linhas no projeto (`run` + `to_run`)
fn runStudy(context: *stages.Context, memory: std.mem.Allocator) ![]const u8 {
    const project = &context.project;
    const study = params(project);
    const places = try parsePlaces(memory, store.text(study, "places", ""), registry.fieldNumber(project.section("requirements"), &registry.requirement_fields, "density_altitude"));
    var rows: std.ArrayList(Row) = .empty;
    const comparing = std.mem.eql(u8, store.text(study, "mode", modes[0]), modes[1]);
    for (places) |place| {
        if (comparing) {
            for (project.list("aircraft").items, 0..) |item, k| {
                const found = if (item == .object) store.child(&item.object, "params") else null;
                const power = found orelse continue;
                if (try point(context, memory, power, place[0], place[1], @floatFromInt(k + 1), store.nameOf(item))) |row| try rows.append(memory, row);
            }
            continue;
        }
        const power = powerParams(project, store.text(study, "aircraft", draft_name));
        const variable = variableOf(store.text(study, "variable", variables[0].label));
        const target = try targetOf(context, memory, power, variable) orelse return "Guarde um avião (ou um conjunto) primeiro.";
        const count: usize = @intFromFloat(@max(registry.fieldNumber(study, &study_fields, "n"), 1));
        const start = registry.fieldNumber(study, &study_fields, "start");
        const stop = registry.fieldNumber(study, &study_fields, "stop");
        for (0..count) |i| {
            const x = if (count == 1) start else start + (stop - start) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count - 1));
            const swap = try Swap.set(project, target, variable.key, x);
            defer swap.restore(project);
            if (try point(context, memory, power, place[0], place[1], x, try std.fmt.allocPrint(memory, "{d}", .{x}))) |row| try rows.append(memory, row);
        }
    }
    // guarda (os dados de simulação ficam no projeto)
    const owned = project.memory();
    var list = std.json.Array.init(owned);
    for (rows.items) |row| {
        var object: ObjectMap = .empty;
        inline for (@typeInfo(Row).@"struct".fields) |item| {
            const value = @field(row, item.name);
            const json: Value = switch (@TypeOf(value)) {
                []const u8 => .{ .string = try owned.dupe(u8, value) },
                bool => .{ .bool = value },
                else => if (std.math.isFinite(value)) .{ .float = value } else .null,
            };
            try object.put(owned, item.name, json);
        }
        try list.append(.{ .object = object });
    }
    try study.put(owned, "rows", .{ .array = list });
    _ = context.save();
    return std.fmt.allocPrint(memory, "estudo rodado: {d} pontos", .{rows.items.len});
}

fn number(object: *const ObjectMap, key: []const u8) f64 {
    const value = object.get(key) orelse return std.math.nan(f64);
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => std.math.nan(f64),
    };
}

fn storedRows(project: *store.Project) []const Value {
    const list = params(project).get("rows") orelse return &.{};
    return if (list == .array) list.array.items else &.{};
}

/// o maior MTOW viável de cada lugar
fn best(rows: []const Value, place: []const u8) ?*const ObjectMap {
    var chosen: ?*const ObjectMap = null;
    for (rows) |*row| {
        if (row.* != .object) continue;
        const object = &row.object;
        if (!std.mem.eql(u8, store.text(object, "place", ""), place) or !store.flag(object, "ok", false)) continue;
        const mtow = number(object, "mtow");
        if (!std.math.isFinite(mtow)) continue;
        if (chosen == null or mtow > number(chosen.?, "mtow")) chosen = object;
    }
    return chosen;
}

/// leva o x do ponto marcado (o primeiro lugar) para o rascunho da etapa da variável
fn useBest(context: *stages.Context, memory: std.mem.Allocator) ![]const u8 {
    const project = &context.project;
    const study = params(project);
    if (std.mem.eql(u8, store.text(study, "mode", modes[0]), modes[1])) {
        const rows = storedRows(project);
        if (rows.len == 0 or rows[0] != .object) return "Rode o estudo primeiro.";
        const marked = best(rows, store.text(&rows[0].object, "place", "")) orelse return "Nenhum ponto fecha.";
        try store.setText(project, project.section("study"), "aircraft", store.text(marked, "name", draft_name));
        _ = context.save();
        return std.fmt.allocPrint(memory, "o melhor é {s}", .{store.text(marked, "name", "")});
    }
    const rows = storedRows(project);
    if (rows.len == 0 or rows[0] != .object) return "Rode o estudo primeiro.";
    const marked = best(rows, store.text(&rows[0].object, "place", "")) orelse return "Nenhum ponto fecha.";
    const variable = variableOf(store.text(study, "variable", variables[0].label));
    const x = number(marked, "x");
    const target: *ObjectMap = switch (variable.stage) {
        .power => project.section("power_draft"),
        .tail => project.section("tail_draft"),
        .wing => project.section("wing_draft"),
    };
    try store.setNumber(project, target, variable.key, x);
    _ = context.save();
    return std.fmt.allocPrint(memory, "{s} = {d} no rascunho da etapa", .{ variable.label, x });
}

/// muda o projeto conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const project = &context.project;
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        if (try stages.applyFields(project, params(project), &study_fields, "", values) > 0) _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "act")) {
        if (std.mem.eql(u8, request.key, "run")) return runStudy(context, memory);
        if (std.mem.eql(u8, request.key, "use")) return useBest(context, memory);
        return error.UnknownAction;
    }
    return "";
}

/// a página: o formulário, os gráficos, a tabela das linhas e o diagnóstico do último estudo
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const project = &context.project;
    const study = params(project);
    var aircraft: std.ArrayList([]const u8) = .empty;
    try aircraft.append(memory, draft_name);
    for (project.list("aircraft").items) |item| try aircraft.append(memory, store.nameOf(item));
    var form: std.ArrayList(simulation.Param) = .empty;
    for (study_fields) |item| {
        var param = try stages.fieldParam(study, item, "", "", memory);
        if (std.mem.eql(u8, item.key, "aircraft")) {
            param.kind = .choice;
            param.choices = aircraft.items;
        }
        try form.append(memory, param);
    }
    const comparing = std.mem.eql(u8, store.text(study, "mode", modes[0]), modes[1]);
    const disabled: []const []const u8 = if (comparing) &.{ "aircraft", "variable", "start", "stop", "n" } else &.{};
    const actions = try memory.dupe(simulation.StageAction, &.{ .{ .key = "run", .label = "Rodar o estudo", .help = "um ponto de projeto acoplado por valor (ou por avião) em cada altitude" }, .{ .key = "use", .label = "Usar o ponto marcado", .help = "leva o valor do maior MTOW viável para o rascunho da etapa da variável" } });
    var out: simulation.StagePage = .{
        .title = "Estudo e ponto de projeto",
        .help = "As áreas se retroalimentam: cada ponto acerta a massa de projeto até o MTOW pela pista, com a asa e a EH recalibradas e o momento da tração. Viável = converge, roda, o trim cabe no curso, a EH não estola e o CG fica onde a bateria alcança. O estudo marca o maior MTOW viável de cada altitude.",
        .keep_label = "",
        .params = form.items,
        .disabled = disabled,
        .actions = actions,
    };
    const rows = storedRows(project);
    if (rows.len == 0) {
        out.message = "Escolha o avião e a variável e clique em 'Rodar o estudo'.";
        return out;
    }
    const variable_label = if (comparing) "avião (nº na tabela)" else store.text(study, "variable", variables[0].label);
    var figure_plots: [plots.len]simulation.Plot = plots;
    for (&figure_plots) |*plot| plot.xlabel = variable_label;
    const figures = try simulation.Figures.init(memory, try memory.dupe(simulation.Plot, &figure_plots));
    var places: std.ArrayList([]const u8) = .empty;
    for (rows) |row| if (row == .object) {
        const place = store.text(&row.object, "place", "");
        var known = false;
        for (places.items) |other| known = known or std.mem.eql(u8, other, place);
        if (!known) try places.append(memory, place);
    };
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    var failing: usize = 0;
    for (places.items, 0..) |place, j| {
        const color = colors[j % colors.len];
        var xs: std.ArrayList(f64) = .empty;
        var good: std.ArrayList(f64) = .empty;
        var bad_x: std.ArrayList(f64) = .empty;
        var bad_y: std.ArrayList(f64) = .empty;
        const Series = struct { rot: std.ArrayList(f64) = .empty, lof: std.ArrayList(f64) = .empty, dih: std.ArrayList(f64) = .empty, hold: std.ArrayList(f64) = .empty, cdt: std.ArrayList(f64) = .empty };
        var series: Series = .{};
        for (rows) |row| {
            if (row != .object) continue;
            const object = &row.object;
            if (!std.mem.eql(u8, store.text(object, "place", ""), place)) continue;
            const x = number(object, "x");
            const ok = store.flag(object, "ok", false);
            if (!ok) failing += 1;
            try xs.append(memory, x);
            try good.append(memory, if (ok) number(object, "mtow") else std.math.nan(f64));
            if (!ok) {
                try bad_x.append(memory, x);
                try bad_y.append(memory, number(object, "mtow"));
            }
            try series.rot.append(memory, number(object, "v_rot"));
            try series.lof.append(memory, number(object, "v_lof"));
            try series.dih.append(memory, number(object, "dih"));
            try series.hold.append(memory, number(object, "hold"));
            try series.cdt.append(memory, number(object, "cd_trim"));
        }
        try figures.curve("mtow", .{ .name = place, .x = xs.items, .y = good.items, .color = color, .width = 2.4 });
        try figures.curve("mtow", .{ .name = try std.fmt.allocPrint(memory, "{s}: pontos", .{place}), .x = xs.items, .y = good.items, .color = color, .marker = "o", .legend = false });
        if (bad_x.items.len > 0) try figures.curve("mtow", .{ .name = try std.fmt.allocPrint(memory, "{s}: não fecha", .{place}), .x = bad_x.items, .y = bad_y.items, .color = color, .marker = "x", .size = 13 });
        try figures.curve("rot", .{ .name = try std.fmt.allocPrint(memory, "{s}: roda", .{place}), .x = xs.items, .y = series.rot.items, .color = color, .width = 2.2 });
        try figures.curve("rot", .{ .name = try std.fmt.allocPrint(memory, "{s}: sai do chão", .{place}), .x = xs.items, .y = series.lof.items, .color = color, .dashed = true });
        try figures.curve("trim", .{ .name = try std.fmt.allocPrint(memory, "{s}: Δi_h", .{place}), .x = xs.items, .y = series.dih.items, .color = color, .width = 2.2 });
        try figures.curve("trim", .{ .name = try std.fmt.allocPrint(memory, "{s}: decolagem", .{place}), .x = xs.items, .y = series.hold.items, .color = color, .dashed = true });
        try figures.curve("cdt", .{ .name = place, .x = xs.items, .y = series.cdt.items, .color = color, .width = 2.2 });

        const marked = best(rows, place) orelse {
            try checks.append(memory, .{ .status = .falha, .item = try std.fmt.allocPrint(memory, "{s}: nenhum ponto fecha", .{place}), .value = "—", .criterion = "estabilidade e desempenho juntos", .fix = "mude a faixa da variável ou outra etapa (EH invertida, área, braço)", .group = "ponto de projeto" });
            continue;
        };
        const label = if (comparing) store.text(marked, "name", "") else try std.fmt.allocPrint(memory, "{s} = {d}", .{ variable_label, number(marked, "x") });
        const mtow = number(marked, "mtow");
        try checks.append(memory, .{ .status = .info, .item = try std.fmt.allocPrint(memory, "{s}: maior MTOW viável (conta rápida)", .{place}), .value = try std.fmt.allocPrint(memory, "{d:.2} kg ({s})", .{ mtow, label }), .criterion = "converge, roda, trim no curso, EH sem estolar", .why = try std.fmt.allocPrint(memory, "limitado por {s}; PV {d:.2} kg → CP possível {d:.2} kg; roda a {d:.1} m/s (sai do chão a {d:.1}); Δi_h {d:.2}°, trim de decolagem {d:.1}°", .{ store.text(marked, "limit", ""), number(marked, "pv"), mtow - number(marked, "pv"), number(marked, "v_rot"), number(marked, "v_lof"), number(marked, "dih"), number(marked, "hold") }), .fix = "'Usar o ponto marcado' leva o valor para o rascunho", .group = "ponto de projeto" });
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "{s}: maior MTOW viável (kg), em", .{place}), try std.fmt.allocPrint(memory, "{d:.3}, {s}", .{ mtow, label }) });
    }
    if (failing > 0) try checks.append(memory, .{ .status = .atencao, .item = "pontos em que a estabilidade não fecha", .value = try std.fmt.allocPrint(memory, "{d} de {d}", .{ failing, rows.len }), .criterion = "—", .why = "veja a coluna 'por quê' na tabela", .group = "ponto de projeto" });
    try checks.append(memory, .{ .status = .info, .item = "método", .value = "ponto de projeto acoplado", .criterion = "—", .why = "massa de projeto → asa e EH recalibradas (com o momento da tração) → desempenho → MTOW → massa de projeto, até convergir; arrasto de trim da EH no desempenho. O 6GDL fica para a aba Missão", .group = "ponto de projeto" });

    // a tabela das linhas
    var table_rows: std.ArrayList([]const []const u8) = .empty;
    for (rows) |row| {
        if (row != .object) continue;
        const object = &row.object;
        try table_rows.append(memory, try memory.dupe([]const u8, &.{
            store.text(object, "place", ""),
            store.text(object, "name", ""),
            try std.fmt.allocPrint(memory, "{d:.3}", .{number(object, "mtow")}),
            try std.fmt.allocPrint(memory, "{d:.3}", .{number(object, "pv")}),
            if (store.flag(object, "ok", false)) "sim" else "não",
            store.text(object, "limit", ""),
            try std.fmt.allocPrint(memory, "{d:.1} / {d:.1}", .{ number(object, "v_rot"), number(object, "v_lof") }),
            try std.fmt.allocPrint(memory, "{d:.2}", .{number(object, "dih")}),
            try std.fmt.allocPrint(memory, "{d:.1}", .{number(object, "hold")}),
            store.text(object, "why", ""),
        }));
    }
    out.tables = try memory.dupe(simulation.Table, &.{.{ .title = "Pontos do estudo", .headers = &.{ "lugar", "valor", "MTOW (kg)", "PV (kg)", "fecha", "limita", "roda / sai (m/s)", "Δi_h (°)", "trim (°)", "por quê" }, .rows = table_rows.items }});
    out.summary = summary.items;
    out.checks = checks.items;
    out.figures = figures;
    return out;
}

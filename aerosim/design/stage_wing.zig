//! A etapa Projetar em Zig (`WingStage` de `stages.py`): a asa a partir do perfil escolhido, pela linha
//! sustentadora do núcleo (`core.wing_line`, a mesma conta de `wing.analyze`), com a planta em trapézio ou em
//! tabela de partições. As tabelas "Asas do avião" (quantas asas e onde cada uma fica) e "Dispositivos das asas"
//! montam a configuração que a Empenagem usa. Os perfis usam a polar do modelo.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");
const airfoils = @import("stage_airfoils.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const wing_line = core.wing_line;
const model = aircraft_model.aircraft;

const planforms = [_][]const u8{ "trapézio", "tabela de seções" };
const size_by = [_][]const u8{ "área", "corda" };
const join_choices = [_][]const u8{ "não", "sim" };
const device_kinds = [_][]const u8{ "winglet", "winglet_baixo", "placa", "cerca" };
const tail_airfoils = [_][]const u8{ "NACA 0012", "NACA 0010", "NACA 0009", "NACA 0008" };
const trapezoid_only = [_][]const u8{ "span", "area", "chord", "size_by", "taper", "rect_frac", "sweep", "twist", "airfoil", "airfoil_tip" };

/// os campos do rascunho da asa (`WingParams`), na ordem da dataclass
const wing_fields = [_]registry.Field{
    .{ .key = "name", .label = "nome", .default = .{ .text = "asa 1" } },
    .{ .key = "planform", .label = "planta", .help = "trapézio: envergadura, área ou corda, afilamento e trecho retangular; tabela de seções: uma linha por seção (y, corda, perfil, recuo, torção), quantas quiser", .default = .{ .text = "trapézio" }, .choices = &planforms },
    .{ .key = "size_by", .label = "dimensionar por", .help = "área: digite a área e a corda sai dela; corda: digite a corda da raiz e a área sai (trapézio)", .default = .{ .text = "área" }, .choices = &size_by },
    .{ .key = "chord", .label = "corda da raiz", .unit = "m", .help = "vale com 'dimensionar por' = corda", .default = .{ .number = 0.35 }, .minimum = 0.03, .maximum = 3.0 },
    .{ .key = "airfoil", .label = "perfil (raiz)", .help = "um dos perfis da etapa Perfil", .default = .{ .text = "NACA 2412" } },
    .{ .key = "airfoil_tip", .label = "perfil da ponta", .help = "vazio = o mesmo da raiz; outro perfil: a asa vai do perfil da raiz (e do trecho retangular) ao da ponta, interpolando", .default = .{ .text = "" } },
    .{ .key = "span", .label = "envergadura", .unit = "m", .help = "de ponta a ponta", .default = .{ .number = 2.4 }, .minimum = 0.3, .maximum = 8.0 },
    .{ .key = "area", .label = "área", .unit = "m²", .help = "área em planta (as duas semiasas)", .default = .{ .number = 0.85 }, .minimum = 0.05, .maximum = 5.0 },
    .{ .key = "taper", .label = "afilamento", .help = "corda da ponta / corda da raiz (no trecho trapezoidal)", .default = .{ .number = 0.6 }, .minimum = 0.2, .maximum = 1.0 },
    .{ .key = "rect_frac", .label = "trecho retangular", .help = "fração da semienvergadura com corda constante", .default = .{ .number = 0.4 }, .minimum = 0.0, .maximum = 1.0 },
    .{ .key = "sweep", .label = "enflechamento (c/4)", .unit = "°", .help = "da linha de 1/4 da corda no trecho trapezoidal", .default = .{ .number = 0.0 }, .minimum = -10, .maximum = 45 },
    .{ .key = "twist", .label = "torção na ponta", .unit = "°", .help = "− = washout (a ponta estola depois)", .default = .{ .number = -1.0 }, .minimum = -8, .maximum = 4 },
    .{ .key = "dihedral", .label = "diedro", .unit = "°", .default = .{ .number = 2.0 }, .minimum = -5, .maximum = 15 },
    .{ .key = "alpha_cruise", .label = "ângulo de cruzeiro (fuselagem)", .unit = "°", .help = "a asa é calada para a fuselagem voar neste ângulo no cruzeiro", .default = .{ .number = 0.0 }, .minimum = -4, .maximum = 8 },
};

const partition_columns = [_]simulation.Column{
    .{ .key = "span", .label = "envergadura (m)", .help = "quanto a partição soma na envergadura total (metade de cada lado)" },
    .{ .key = "chord", .label = "corda (m)", .help = "corda no começo da partição (do lado do centro)" },
    .{ .key = "taper", .label = "afilamento", .help = "corda no fim / corda no começo (1 = reta)" },
    .{ .key = "airfoil", .label = "perfil", .kind = .choice, .help = "perfil no fim da partição (vazio = o da raiz); ao longo dela ele passa do da anterior para este" },
    .{ .key = "offset", .label = "recuo (m)", .help = "quanto o bordo de ataque anda para trás ao longo da partição (enflechamento): move o centro aerodinâmico, e com ele o CG de projeto. 0 = bordo de ataque reto" },
    .{ .key = "twist", .label = "θ (°)", .help = "torção no fim da partição, em relação à raiz: − = washout, a ponta estola depois (o aileron continua mandando no estol), custa um pouco de sustentação" },
};
const layout_keys = [_][]const u8{ "wing", "dx", "dy", "dz", "di", "join" };
const device_keys = [_][]const u8{ "wing", "kind", "eta", "dx", "height", "root_chord", "taper", "sweep", "cant", "toe", "profile" };

const plots = [_]simulation.Plot{
    .{ .key = "CL", .title = "C_L × α", .xlabel = "α_raiz (°)", .ylabel = "C_L" },
    .{ .key = "pol", .title = "C_L × C_D", .xlabel = "C_D", .ylabel = "C_L" },
    .{ .key = "LD", .title = "L/D × C_L", .xlabel = "C_L", .ylabel = "L/D" },
    .{ .key = "span", .title = "c_l × 2y/b", .xlabel = "2y/b", .ylabel = "c_l" },
};
const palette = [_][]const u8{ "#1f77b4", "#eb6834", "#1baf7a", "#d62728", "#4a3aa7", "#8c564b" };

// ------------------------------------------------------------------ o rascunho
fn draft(project: *store.Project) *ObjectMap {
    return project.section("wing_draft");
}

fn isTable(params: *const ObjectMap) bool {
    if (!std.mem.eql(u8, store.text(params, "planform", planforms[0]), planforms[1])) return false;
    const list = params.get("partitions") orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| if (item == .object and store.number(&item.object, "span", 0) > 0) return true;
    return false;
}

fn trapezoidOf(params: *const ObjectMap) wing_line.Trapezoid {
    return .{
        .span = store.number(params, "span", 2.4),
        .area = store.number(params, "area", 0.85),
        .root_chord = store.number(params, "chord", 0.35),
        .size_by_chord = std.mem.eql(u8, store.text(params, "size_by", size_by[0]), size_by[1]),
        .taper = store.number(params, "taper", 0.6),
        .rect_fraction = store.number(params, "rect_frac", 0.4),
        .sweep = store.number(params, "sweep", 0),
        .twist = store.number(params, "twist", -1),
        .alpha_cruise = store.number(params, "alpha_cruise", 0),
    };
}

/// as partições da tabela; `names` recebe o perfil de cada índice (0 = o da raiz)
fn partitionsOf(memory: std.mem.Allocator, params: *const ObjectMap, out: *[wing_line.max_partitions]wing_line.Partition, names: *std.ArrayList([]const u8)) !usize {
    const root = store.text(params, "airfoil", "NACA 2412");
    if (names.items.len == 0) try names.append(memory, root);
    const list = params.get("partitions") orelse return 0;
    if (list != .array) return 0;
    var count: usize = 0;
    for (list.array.items) |item| {
        if (item != .object or count >= wing_line.max_partitions) continue;
        const object = &item.object;
        const name = store.text(object, "airfoil", "");
        var index: usize = 0;
        if (name.len > 0 and !std.mem.eql(u8, name, root)) {
            index = for (names.items, 0..) |known, k| {
                if (std.mem.eql(u8, known, name)) break k;
            } else blk: {
                try names.append(memory, name);
                break :blk names.items.len - 1;
            };
        }
        out[count] = .{ .span = store.number(object, "span", 1), .chord = store.number(object, "chord", 0.3), .taper = store.number(object, "taper", 1), .airfoil = index, .offset = store.number(object, "offset", 0), .twist = store.number(object, "twist", 0) };
        count += 1;
    }
    return count;
}

/// a planta e os nomes dos perfis das seções (0 = o da raiz) dos parâmetros de uma asa
const Shape = struct { planform: wing_line.Planform, names: []const []const u8 };

fn shapeOf(memory: std.mem.Allocator, params: *const ObjectMap) !Shape {
    var names: std.ArrayList([]const u8) = .empty;
    const root = store.text(params, "airfoil", "NACA 2412");
    try names.append(memory, root);
    if (isTable(params)) {
        var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
        const count = try partitionsOf(memory, params, &partitions, &names);
        return .{ .planform = wing_line.planformOfPartitions(partitions[0..count]), .names = names.items };
    }
    const tip = store.text(params, "airfoil_tip", "");
    const with_tip = tip.len > 0 and !std.mem.eql(u8, tip, root);
    if (with_tip) try names.append(memory, tip);
    return .{ .planform = wing_line.planformOf(trapezoidOf(params), with_tip), .names = names.items };
}

/// acerta os campos que saem dos outros (`sync`): área (por corda ou pela tabela), corda da raiz e envergadura
fn sync(project: *store.Project, params: *ObjectMap) !void {
    if (isTable(params)) {
        var names: std.ArrayList([]const u8) = .empty;
        var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
        const count = try partitionsOf(project.memory(), params, &partitions, &names);
        const sums = wing_line.totals(partitions[0..count]);
        try store.setNumber(project, params, "span", round6(sums.span));
        try store.setNumber(project, params, "area", round6(sums.area));
        for (partitions[0..count]) |partition| if (partition.span > 0) {
            try store.setNumber(project, params, "chord", partition.chord);
            break;
        };
        return;
    }
    const planform = wing_line.planformOf(trapezoidOf(params), false);
    if (std.mem.eql(u8, store.text(params, "size_by", size_by[0]), size_by[1])) {
        const semispan = planform.semispan;
        const break_y = planform.break_y;
        try store.setNumber(project, params, "area", round6(2 * (planform.root_chord * break_y + 0.5 * (planform.root_chord + planform.tip_chord) * (semispan - break_y))));
    } else try store.setNumber(project, params, "chord", round6(planform.root_chord));
}

fn round6(value: f64) f64 {
    return @round(value * 1e6) / 1e6;
}

/// refaz a tabela a partir do trapézio atual (`partitions_from_trapezoid`)
fn resetPartitions(project: *store.Project, params: *ObjectMap) !void {
    const memory = project.memory();
    const root = store.text(params, "airfoil", "NACA 2412");
    const tip = store.text(params, "airfoil_tip", "");
    var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
    const count = wing_line.partitionsFromTrapezoid(trapezoidOf(params), @intFromBool(tip.len > 0 and !std.mem.eql(u8, tip, root)), &partitions);
    var list = std.json.Array.init(memory);
    for (partitions[0..count]) |partition| {
        var object: ObjectMap = .empty;
        try object.put(memory, "span", .{ .float = partition.span });
        try object.put(memory, "chord", .{ .float = partition.chord });
        try object.put(memory, "taper", .{ .float = partition.taper });
        try object.put(memory, "airfoil", .{ .string = if (partition.airfoil == 0) root else tip });
        try object.put(memory, "offset", .{ .float = partition.offset });
        try object.put(memory, "twist", .{ .float = partition.twist });
        try list.append(.{ .object = object });
    }
    try params.put(memory, "partitions", .{ .array = list });
}

// ------------------------------------------------------------------ a conta
/// a análise de uma asa (os parâmetros dela) com os perfis do projeto
fn analyze(context: *stages.Context, memory: std.mem.Allocator, params: *const ObjectMap, result: *wing_line.Result) !Shape {
    const project = &context.project;
    const shape = try shapeOf(memory, params);
    const sections = try memory.alloc(wing_line.SectionAirfoil, shape.names.len);
    const pointers = try memory.alloc(*const wing_line.SectionAirfoil, shape.names.len);
    for (shape.names, sections, pointers) |name, *section, *pointer| {
        section.* = try airfoils.sectionOf(memory, airfoils.lookup(context, name));
        pointer.* = section;
    }
    const requirements = project.section("requirements");
    const conditions: wing_line.Conditions = .{
        .mass = registry.fieldNumber(requirements, &registry.requirement_fields, "mass"),
        .airspeed = registry.fieldNumber(requirements, &registry.requirement_fields, "V_cruise"),
        .density = registry.rho(project),
        .wing_density = registry.fieldNumber(project.section("rules"), &registry.rule_fields, "wing_density"),
    };
    wing_line.analyzePlanform(&shape.planform, pointers, store.number(params, "alpha_cruise", 0), conditions, result);
    return shape;
}

/// a superfície do modelo do avião para a vista 3D (bordo de ataque da raiz em x = 0)
fn surfaceOf(context: *stages.Context, memory: std.mem.Allocator, params: *const ObjectMap, name: []const u8, incidence: f64) !model.Surface {
    const shape = try shapeOf(memory, params);
    const planform = shape.planform;
    const sections = try memory.alloc(model.Section, planform.count);
    for (planform.sections[0..planform.count], sections) |station, *section| {
        var own: ?model.Airfoil = null;
        if (station.airfoil != 0) if (airfoils.lookup(context, shape.names[station.airfoil])) |entry| {
            own = try airfoils.airfoilOf(memory, entry);
        };
        section.* = .{ .y = station.y, .chord = station.chord, .x_offset = station.offset, .twist = station.twist, .airfoil = own };
    }
    const root = if (airfoils.lookup(context, shape.names[0])) |entry| try airfoils.airfoilOf(memory, entry) else model.Airfoil{ .name = shape.names[0] };
    return .{ .name = name, .role = "wing", .sections = sections, .dihedral = store.number(params, "dihedral", 2), .incidence = incidence, .airfoil = root };
}

/// as meshes das superfícies (a vista 3D da etapa)
fn viewOf(memory: std.mem.Allocator, surfaces: []const model.Surface) !?simulation.View {
    const plane: model.Aircraft = .{ .name = "prévia", .surfaces = surfaces };
    var diagnosis: model.Diag = .{};
    const built = aircraft_model.skeleton.build(memory, &plane, &diagnosis) catch return null;
    var meshes: std.ArrayList(simulation.Mesh) = .empty;
    for (built.pieces) |piece| switch (piece.color) {
        .wing, .htail, .vtail, .control, .device => try meshes.append(memory, .{ .kind = @tagName(piece.color), .vertices = piece.mesh.v, .faces = piece.mesh.f }),
        else => {},
    };
    return .{ .meshes = meshes.items };
}

/// a asa guardada com este nome
fn keptWing(project: *store.Project, name: []const u8) ?*ObjectMap {
    for (project.list("wings").items) |*item| {
        if (item.* != .object) continue;
        if (std.mem.eql(u8, store.nameOf(item.*), name)) return store.child(&item.object, "params");
    }
    return null;
}

/// as asas da tabela "Asas do avião" como superfícies, cada uma no lugar dela (`layout_surfaces`)
fn layoutSurfaces(context: *stages.Context, memory: std.mem.Allocator) ![]const model.Surface {
    const project = &context.project;
    var out: std.ArrayList(model.Surface) = .empty;
    for (project.list("wing_layout").items, 0..) |row, k| {
        if (row != .object) continue;
        const object = &row.object;
        const name = store.text(object, "wing", "");
        const params = keptWing(project, name) orelse continue;
        var surface = try surfaceOf(context, memory, params, if (k > 0) try std.fmt.allocPrint(memory, "{s} ({d})", .{ name, k + 1 }) else name, store.number(object, "di", 0));
        surface.x = -store.number(object, "dx", 0);
        surface.y = store.number(object, "dy", 0);
        surface.z = -store.number(object, "dz", 0);
        if (object.get("devices")) |devices| if (devices == .array and devices.array.items.len > 0) {
            surface.devices = try std.json.parseFromValueLeaky([]const model.Device, memory, devices, .{ .ignore_unknown_fields = true });
        };
        try out.append(memory, surface);
    }
    return out.items;
}

// ------------------------------------------------------------------ pedidos
fn numberOf(value: Value) ?f64 {
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .string => |digits| std.fmt.parseFloat(f64, std.mem.trim(u8, digits, " ")) catch null,
        .bool => |on| if (on) 1 else 0,
        else => null,
    };
}

/// muda o projeto conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const project = &context.project;
    const params = draft(project);
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        const before_planform = store.text(params, "planform", planforms[0]);
        const before_size = store.text(params, "size_by", size_by[0]);
        const changed = try stages.applyFields(project, params, &wing_fields, "", values);
        if (changed == 0) return "";
        const table = std.mem.eql(u8, store.text(params, "planform", planforms[0]), planforms[1]);
        const has_partitions = if (params.get("partitions")) |list| list == .array and list.array.items.len > 0 else false;
        if (table and !has_partitions) try resetPartitions(project, params);
        if (table or !std.mem.eql(u8, before_planform, store.text(params, "planform", planforms[0])) or !std.mem.eql(u8, before_size, store.text(params, "size_by", size_by[0])) or true) try sync(project, params);
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "load")) {
        const list = project.list("wings");
        const index = stages.within(request.index, list.items.len) orelse return "";
        const kept = store.child(&list.items[index].object, "params") orelse return "";
        try project.root.object.put(project.memory(), "wing_draft", try stages.clone(project.memory(), .{ .object = kept.* }));
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        const list = project.list("wings");
        const index = stages.within(request.index, list.items.len) orelse return "";
        _ = list.orderedRemove(index);
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "keep")) {
        const name = try keepWing(context);
        _ = context.save();
        return std.fmt.allocPrint(memory, "guardado: {s}", .{name});
    }
    if (std.mem.eql(u8, request.do, "act")) {
        if (!std.mem.eql(u8, request.key, "config")) return error.UnknownAction;
        return keepConfig(context, memory, request.arg);
    }
    if (std.mem.eql(u8, request.do, "grid")) {
        if (std.mem.eql(u8, request.grid, "asas")) try editLayout(project, request) else if (std.mem.eql(u8, request.grid, "dispositivos")) try editDevices(project, request) else try editPartitions(project, params, request);
        _ = context.save();
    }
    return "";
}

/// guarda o rascunho como asa (`keep_wing`): a cópia dos parâmetros e dos perfis; o rascunho ganha o próximo nome
fn keepWing(context: *stages.Context) ![]const u8 {
    const project = &context.project;
    const memory = project.memory();
    const params = draft(project);
    try sync(project, params);
    var candidate: ObjectMap = .empty;
    try candidate.put(memory, "params", try stages.clone(memory, .{ .object = params.* }));
    const root = store.text(params, "airfoil", "NACA 2412");
    try candidate.put(memory, "airfoil", if (airfoils.lookup(context, root)) |entry| try stages.clone(memory, entry) else .null);
    const tip = store.text(params, "airfoil_tip", "");
    const tip_entry: Value = if (!isTable(params) and tip.len > 0 and !std.mem.eql(u8, tip, root)) (if (airfoils.lookup(context, tip)) |entry| try stages.clone(memory, entry) else .null) else .null;
    try candidate.put(memory, "airfoil_tip", tip_entry);
    var section_airfoils = std.json.Array.init(memory);
    if (isTable(params)) {
        const shape = try shapeOf(memory, params);
        for (shape.names[1..]) |name| if (airfoils.lookup(context, name)) |entry| try section_airfoils.append(try stages.clone(memory, entry));
    }
    try candidate.put(memory, "section_airfoils", .{ .array = section_airfoils });
    try candidate.put(memory, "note", .{ .string = "" });
    const name = try memory.dupe(u8, store.text(params, "name", "asa 1"));
    const list = project.list("wings");
    try stages.put(list, .{ .object = candidate });
    var taken: std.ArrayList([]const u8) = .empty;
    for (list.items) |item| try taken.append(memory, store.nameOf(item));
    try store.setText(project, params, "name", try stages.nextName(memory, name, taken.items));
    try store.setText(project, project.section("tail_draft"), "wing", name);
    return name;
}

/// guarda a tabela "Asas do avião" como configuração (`keep_config`); a Empenagem passa a usá-la
fn keepConfig(context: *stages.Context, memory: std.mem.Allocator, given: []const u8) ![]const u8 {
    const project = &context.project;
    const layout = project.list("wing_layout");
    if (layout.items.len == 0) return "A tabela 'Asas do avião' está vazia: ponha pelo menos uma asa (+ asa).";
    const configs = project.list("configs");
    var taken: std.ArrayList([]const u8) = .empty;
    for (configs.items) |item| if (item == .object) try taken.append(memory, store.text(&item.object, "name", ""));
    const trimmed = std.mem.trim(u8, given, " ");
    const name = if (trimmed.len > 0) try project.memory().dupe(u8, trimmed) else try stages.nextName(project.memory(), "configuração 1", taken.items);
    var config: ObjectMap = .empty;
    try config.put(project.memory(), "name", .{ .string = name });
    try config.put(project.memory(), "wings", try stages.clone(project.memory(), .{ .array = layout.* }));
    var replaced = false;
    for (configs.items) |*item| if (item.* == .object and std.mem.eql(u8, store.text(&item.object, "name", ""), name)) {
        item.* = .{ .object = config };
        replaced = true;
    };
    if (!replaced) try configs.append(.{ .object = config });
    try store.setText(project, project.section("tail_draft"), "config", name);
    _ = context.save();
    const count = layout.items.len;
    return std.fmt.allocPrint(memory, "configuração guardada: {s} ({d} asa{s}); a Empenagem usa esta", .{ name, count, if (count > 1) "s" else "" });
}

fn editLayout(project: *store.Project, request: stages.Request) !void {
    const memory = project.memory();
    const rows = project.list("wing_layout");
    const wings = project.list("wings");
    if (std.mem.eql(u8, request.edit, "add")) {
        var row: ObjectMap = .empty;
        const index = stages.within(request.row, rows.items.len);
        const name = if (index) |k| store.text(&rows.items[k].object, "wing", "") else if (wings.items.len > 0) store.text(project.section("tail_draft"), "wing", store.nameOf(wings.items[0])) else "";
        try row.put(memory, "wing", .{ .string = name });
        for ([_][]const u8{ "dx", "dy", "dz", "di" }) |key| try row.put(memory, key, .{ .float = 0 });
        try row.put(memory, "join", .{ .bool = false });
        try row.put(memory, "devices", .{ .array = .init(memory) });
        if (index) |k| try rows.insert(k + 1, .{ .object = row }) else try rows.append(.{ .object = row });
        return;
    }
    if (rows.items.len == 0) return;
    const index = stages.within(request.row, rows.items.len) orelse rows.items.len - 1;
    if (std.mem.eql(u8, request.edit, "delete")) {
        _ = rows.orderedRemove(index);
        return;
    }
    const object = &rows.items[index].object;
    if (std.mem.eql(u8, request.key, "wing")) {
        if (request.value == .string) try store.setText(project, object, "wing", request.value.string);
    } else if (std.mem.eql(u8, request.key, "join")) {
        try object.put(memory, "join", .{ .bool = index > 0 and request.value == .string and std.mem.eql(u8, request.value.string, join_choices[1]) });
    } else if (index > 0) { // a referência fica em Δ = 0
        if (numberOf(request.value)) |number| try store.setNumber(project, object, request.key, number);
    }
}

/// (linha da tabela de asas, índice do dispositivo nela), na ordem da tabela
fn deviceRows(memory: std.mem.Allocator, project: *store.Project) ![][2]usize {
    var out: std.ArrayList([2]usize) = .empty;
    for (project.list("wing_layout").items, 0..) |row, k| {
        if (row != .object) continue;
        const devices = row.object.get("devices") orelse continue;
        if (devices != .array) continue;
        for (0..devices.array.items.len) |i| try out.append(memory, .{ k, i });
    }
    return out.items;
}

fn devicesOf(project: *store.Project, row: usize) !*std.json.Array {
    const object = &project.list("wing_layout").items[row].object;
    const gop = try object.getOrPut(project.memory(), "devices");
    if (!gop.found_existing or gop.value_ptr.* != .array) gop.value_ptr.* = .{ .array = .init(project.memory()) };
    return &gop.value_ptr.array;
}

fn editDevices(project: *store.Project, request: stages.Request) !void {
    const memory = project.memory();
    const layout = project.list("wing_layout");
    const rows = try deviceRows(memory, project);
    if (std.mem.eql(u8, request.edit, "add")) {
        if (layout.items.len == 0) return;
        const row = if (stages.within(request.row, rows.len)) |k| rows[k][0] else 0;
        var device: ObjectMap = .empty;
        const defaults: model.Device = .{};
        try device.put(memory, "kind", .{ .string = defaults.kind });
        inline for (.{ "eta", "dx", "height", "root_chord", "taper", "sweep", "cant", "toe", "cl_alpha", "cd0", "oswald" }) |key| try device.put(memory, key, .{ .float = @field(defaults, key) });
        try device.put(memory, "profile", .{ .string = defaults.profile });
        try (try devicesOf(project, row)).append(.{ .object = device });
        return;
    }
    if (rows.len == 0) return;
    const at = rows[stages.within(request.row, rows.len) orelse rows.len - 1];
    const list = try devicesOf(project, at[0]);
    if (std.mem.eql(u8, request.edit, "delete")) {
        _ = list.orderedRemove(at[1]);
        return;
    }
    const object = &list.items[at[1]].object;
    if (std.mem.eql(u8, request.key, "wing")) {
        if (request.value != .string) return;
        const colon = std.mem.indexOfScalar(u8, request.value.string, ':') orelse return;
        const target = (std.fmt.parseInt(usize, request.value.string[0..colon], 10) catch return) -% 1;
        if (target >= layout.items.len or target == at[0]) return;
        const moved = list.orderedRemove(at[1]);
        try (try devicesOf(project, target)).append(moved);
    } else if (std.mem.eql(u8, request.key, "kind") or std.mem.eql(u8, request.key, "profile")) {
        if (request.value == .string) try store.setText(project, object, request.key, request.value.string);
    } else if (numberOf(request.value)) |number| try store.setNumber(project, object, request.key, number);
}

fn editPartitions(project: *store.Project, params: *ObjectMap, request: stages.Request) !void {
    const memory = project.memory();
    if (std.mem.eql(u8, request.edit, "reset")) {
        try resetPartitions(project, params);
        return sync(project, params);
    }
    const gop = try params.getOrPut(memory, "partitions");
    if (!gop.found_existing or gop.value_ptr.* != .array) gop.value_ptr.* = .{ .array = .init(memory) };
    const parts = &gop.value_ptr.array;
    if (parts.items.len == 0) return;
    const index = stages.within(request.row, parts.items.len) orelse parts.items.len - 1;
    const object = &parts.items[index].object;
    if (std.mem.eql(u8, request.edit, "set")) {
        if (std.mem.eql(u8, request.key, "airfoil")) {
            try store.setText(project, object, "airfoil", if (request.value == .string) request.value.string else "");
        } else if (numberOf(request.value)) |number| {
            const positive = std.mem.eql(u8, request.key, "span") or std.mem.eql(u8, request.key, "chord") or std.mem.eql(u8, request.key, "taper");
            try store.setNumber(project, object, request.key, if (positive) @max(number, 0) else number);
        }
    } else if (std.mem.eql(u8, request.edit, "add")) {
        var next: ObjectMap = .empty;
        try next.put(memory, "span", .{ .float = 0.2 });
        try next.put(memory, "chord", .{ .float = @round(store.number(object, "chord", 0.3) * store.number(object, "taper", 1) * 1e4) / 1e4 });
        try next.put(memory, "taper", .{ .float = 1.0 });
        try next.put(memory, "airfoil", .{ .string = store.text(object, "airfoil", "") });
        try next.put(memory, "offset", .{ .float = 0 });
        try next.put(memory, "twist", .{ .float = store.number(object, "twist", 0) });
        try parts.insert(index + 1, .{ .object = next });
    } else if (std.mem.eql(u8, request.edit, "delete")) {
        if (parts.items.len > 1) _ = parts.orderedRemove(index);
    } else return error.UnknownEdit;
    try sync(project, params);
}

// ------------------------------------------------------------------ a página
fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn curveSlice(memory: std.mem.Allocator, values: []const f64) ![]const f64 {
    return memory.dupe(f64, values);
}

/// a página: o rascunho em formulário, as tabelas, a conta e a vista 3D
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const project = &context.project;
    const params = draft(project);
    const names = try airfoils.names(context, memory);
    const root_name = store.text(params, "airfoil", "NACA 2412");
    if (names.len > 0 and root_name.len > 0) {
        var known = false;
        for (names) |name| known = known or std.mem.eql(u8, name, root_name);
        if (!known) try store.setText(project, params, "airfoil", names[0]);
    }

    // o formulário
    var form: std.ArrayList(simulation.Param) = .empty;
    const tip_choices = try memory.alloc([]const u8, names.len + 1);
    tip_choices[0] = "";
    @memcpy(tip_choices[1..], names);
    for (wing_fields) |field| {
        var param = try stages.fieldParam(params, field, "", "", memory);
        if (std.mem.eql(u8, field.key, "airfoil")) {
            param.kind = .choice;
            param.choices = names;
        } else if (std.mem.eql(u8, field.key, "airfoil_tip")) {
            param.kind = .choice;
            param.choices = tip_choices;
        }
        try form.append(memory, param);
    }
    const table = std.mem.eql(u8, store.text(params, "planform", planforms[0]), planforms[1]);
    const disabled: []const []const u8 = if (table) &trapezoid_only else if (std.mem.eql(u8, store.text(params, "size_by", size_by[0]), size_by[1])) &.{"area"} else &.{"chord"};

    // a conta do rascunho
    const result = try memory.create(wing_line.Result);
    result.* = .{};
    const shape = try analyze(context, memory, params, result);
    const draft_name = store.text(params, "name", "asa 1");
    const figures = try simulation.Figures.init(memory, &plots);
    const count = result.alpha_count;
    try figures.curve("CL", .{ .name = draft_name, .x = try curveSlice(memory, result.alpha[0..count]), .y = try curveSlice(memory, result.lift[0..count]), .width = 2.4, .color = palette[0] });
    try figures.curve("pol", .{ .name = try text(memory, "{s}: total", .{draft_name}), .x = try curveSlice(memory, result.drag[0..count]), .y = try curveSlice(memory, result.lift[0..count]), .width = 2.4, .color = "#000000" });
    try figures.curve("pol", .{ .name = "induzido C_D,i", .x = try curveSlice(memory, result.induced[0..count]), .y = try curveSlice(memory, result.lift[0..count]), .dashed = true, .color = "#1f77b4" });
    try figures.curve("pol", .{ .name = "perfil C_D,p", .x = try curveSlice(memory, result.profile[0..count]), .y = try curveSlice(memory, result.lift[0..count]), .dashed = true, .color = "#2ca02c" });
    try figures.curve("LD", .{ .name = draft_name, .x = try curveSlice(memory, result.lift[0..count]), .y = try curveSlice(memory, result.ld[0..count]), .width = 2.4, .color = palette[0] });
    try figures.guide("LD", .{ .name = "cruzeiro C_L,cr", .value = result.lift_cruise, .vertical = true, .color = "#7f7f7f" });
    const stations = result.station_count;
    try figures.curve("span", .{ .name = "cruzeiro", .x = try curveSlice(memory, result.span_fraction[0..stations]), .y = try curveSlice(memory, result.cl_cruise[0..stations]), .color = "#1f77b4" });
    try figures.curve("span", .{ .name = "estol", .x = try curveSlice(memory, result.span_fraction[0..stations]), .y = try curveSlice(memory, result.cl_stall[0..stations]), .width = 2.2, .color = "#d62728" });
    try figures.curve("span", .{ .name = "c_l,max local", .x = try curveSlice(memory, result.span_fraction[0..stations]), .y = try curveSlice(memory, result.cl_max_local[0..stations]), .dashed = true, .color = "#d62728" });
    try figures.guide("span", .{ .name = "início do estol", .value = result.stall_fraction, .vertical = true, .color = "#ff7f0e" });
    // as asas guardadas, para comparar (finas)
    for (project.list("wings").items, 0..) |item, k| {
        const name = store.nameOf(item);
        if (std.mem.eql(u8, name, draft_name) or item != .object) continue;
        const kept = store.child(&item.object, "params") orelse continue;
        const other = try memory.create(wing_line.Result);
        other.* = .{};
        _ = analyze(context, memory, kept, other) catch continue;
        const n = other.alpha_count;
        const color = palette[(k + 1) % palette.len];
        try figures.curve("CL", .{ .name = name, .x = try curveSlice(memory, other.alpha[0..n]), .y = try curveSlice(memory, other.lift[0..n]), .width = 1.2, .dashed = true, .color = color });
        try figures.curve("LD", .{ .name = name, .x = try curveSlice(memory, other.lift[0..n]), .y = try curveSlice(memory, other.ld[0..n]), .width = 1.2, .dashed = true, .color = color });
    }

    // o resumo e o diagnóstico (`wing_stage` de results.py)
    var summary: std.ArrayList([2][]const u8) = .empty;
    try summary.append(memory, .{ "b, S, AR", try text(memory, "{d:.3}, {d:.4}, {d:.2}", .{ result.span, result.area, result.aspect_ratio }) });
    try summary.append(memory, .{ "corda da raiz, da ponta, CMA (m)", try text(memory, "{d:.4}, {d:.4}, {d:.4}", .{ result.root_chord, result.tip_chord, result.mean_chord }) });
    try summary.append(memory, .{ "perfil (polar por)", try text(memory, "{s} (modelo, Re {d:.0})", .{ shape.names[0], result.reynolds }) });
    try summary.append(memory, .{ "C_Lα (1/rad), C_L0, α_L0 (°)", try text(memory, "{d:.4}, {d:.4}, {d:.3}", .{ result.lift_slope, result.lift_zero, result.alpha_zero }) });
    try summary.append(memory, .{ "C_L,max, α de estol (°)", try text(memory, "{d:.4}, {d:.2}", .{ result.lift_max, result.alpha_stall }) });
    try summary.append(memory, .{ "estol começa em (2y/b)", try text(memory, "{d:.3}", .{result.stall_fraction}) });
    try summary.append(memory, .{ "Oswald e (no cruzeiro)", try text(memory, "{d:.4}", .{result.oswald}) });
    try summary.append(memory, .{ "(L/D) máx., C_L nele", try text(memory, "{d:.2}, {d:.3}", .{ result.ld_max, result.lift_at_ld }) });
    try summary.append(memory, .{ "cruzeiro: C_L, α da asa (°), L/D", try text(memory, "{d:.3}, {d:.2}, {d:.2}", .{ result.lift_cruise, result.alpha_cruise, result.ld_cruise }) });
    try summary.append(memory, .{ "incidência da asa (°)", try text(memory, "{d:.3}", .{result.incidence}) });
    try summary.append(memory, .{ "V de estol (massa estimada)", try text(memory, "{d:.3}", .{result.stall_speed}) });
    try summary.append(memory, .{ "carga alar (kg/m²)", try text(memory, "{d:.3}", .{result.wing_loading}) });
    try summary.append(memory, .{ "massa estimada da asa (kg)", try text(memory, "{d:.3}", .{result.wing_mass}) });
    try summary.append(memory, .{ "Re na raiz, na ponta", try text(memory, "{d:.0}, {d:.0}", .{ result.reynolds_root, result.reynolds_tip }) });

    var checks: std.ArrayList(simulation.Check) = .empty;
    const group = "asa";
    const values = [_]struct { key: []const u8, value: f64 }{ .{ .key = "S", .value = result.area }, .{ .key = "b", .value = result.span }, .{ .key = "AR", .value = result.aspect_ratio }, .{ .key = "V_S", .value = result.stall_speed }, .{ .key = "c_root", .value = result.root_chord } };
    for ((try registry.constraintList(project)).items) |item| {
        const constraint = registry.readConstraint(item);
        if (!constraint.active) continue;
        const value = for (values) |pair| {
            if (std.mem.eql(u8, pair.key, constraint.key)) break pair.value;
        } else continue;
        const info = registry.quantity(constraint.key);
        const ok = constraint.holds(value);
        var buffer: [32]u8 = undefined;
        var limit_buffer: [32]u8 = undefined;
        const fix = if (std.mem.eql(u8, constraint.key, "V_S") and std.mem.eql(u8, constraint.op, "≤")) try text(memory, "área ≥ {d:.2} m² ou perfil de c_l,max maior", .{result.area * std.math.pow(f64, result.stall_speed / constraint.value, 2)}) else info.fix;
        try checks.append(memory, .{ .status = if (ok) .ok else .falha, .item = try text(memory, "restrição: {s}", .{info.label}), .value = try text(memory, "{s} {s}", .{ registry.format(&buffer, value), info.unit }), .criterion = try text(memory, "{s} {s} {s}", .{ constraint.op, registry.format(&limit_buffer, constraint.value), info.unit }), .why = if (ok) "" else "não cumpre a restrição ativa", .fix = if (ok) "" else fix, .group = group, .source = "restrições (Condições e restrições…)" });
    }
    const stall_at = result.stall_fraction;
    const stall_status: @TypeOf(checks.items[0].status) = if (stall_at <= 0.5) .ok else if (stall_at <= 0.8) .atencao else .falha;
    try checks.append(memory, .{ .status = stall_status, .item = "onde o estol começa", .value = try text(memory, "2y/b = {d:.2}", .{stall_at}), .criterion = "≤ 0,5 (perto da raiz)", .why = if (stall_status == .ok) "" else "estol na ponta: o aileron perde efeito e a asa tende a cair para um lado", .fix = if (stall_status == .ok) "" else "mais washout (torção negativa na ponta) ou menos afilamento", .group = group });
    if (std.math.isFinite(result.ld_cruise) and result.ld_max > 0) {
        const share = result.ld_cruise / result.ld_max;
        const ok = share >= 0.9;
        try checks.append(memory, .{ .status = if (ok) .ok else .atencao, .item = "cruzeiro perto do L/D máx. da asa", .value = try text(memory, "{d:.0} %", .{100 * share}), .criterion = "≥ 90 %", .why = if (ok) "" else try text(memory, "o C_L de cruzeiro ({d:.2}) longe do de L/D máx. ({d:.2})", .{ result.lift_cruise, result.lift_at_ld }), .fix = if (ok) "" else "mude a área ou a velocidade de cruzeiro", .group = group });
    }
    if (result.lift_cruise > 0.85 * result.lift_max) try checks.append(memory, .{ .status = .falha, .item = "cruzeiro abaixo do estol", .value = try text(memory, "C_L {d:.2} de {d:.2}", .{ result.lift_cruise, result.lift_max }), .criterion = "≤ 85 %", .why = "a asa cruza quase estolada", .fix = "mais área ou mais velocidade", .group = group });
    if (result.reynolds_tip < 8e4) try checks.append(memory, .{ .status = .atencao, .item = "Re na ponta", .value = try text(memory, "{d:.0}", .{result.reynolds_tip}), .criterion = "≥ 80 000", .why = "a ponta voa num Re em que o perfil perde c_l,max", .fix = "afilamento menor ou corda maior", .group = group });
    try checks.append(memory, .{ .status = .info, .item = "método", .value = "linha sustentadora (Glauert)", .criterion = "—", .why = "seção crítica para o estol; c_d da polar 2D no c_l local; sem fuselagem", .group = group });

    // a vista 3D: as asas da tabela (se houver mais de uma), senão o rascunho
    const layout = try layoutSurfaces(context, memory);
    const shown: []const model.Surface = if (layout.len > 1) layout else &.{try surfaceOf(context, memory, params, draft_name, result.incidence)};

    // os guardados e as tabelas
    var kept: std.ArrayList([]const u8) = .empty;
    var wing_names: std.ArrayList([]const u8) = .empty;
    for (project.list("wings").items) |item| {
        try kept.append(memory, store.nameOf(item));
        try wing_names.append(memory, store.nameOf(item));
    }
    var grids: std.ArrayList(simulation.Grid) = .empty;
    if (wing_names.items.len > 0) {
        const layout_rows = project.list("wing_layout").items;
        for (layout_rows) |row| if (row == .object) {
            const name = store.text(&row.object, "wing", "");
            var known = false;
            for (wing_names.items) |other| known = known or std.mem.eql(u8, other, name);
            if (!known) try wing_names.append(memory, name);
        };
        const columns = try memory.dupe(simulation.Column, &.{
            .{ .key = "wing", .label = "asa", .kind = .choice, .choices = wing_names.items, .help = "uma das asas guardadas (a primeira linha é a referência)" },
            .{ .key = "dx", .label = "Δx (m)", .help = "bordo de ataque da raiz em relação ao da referência: + para trás" },
            .{ .key = "dy", .label = "Δy (m)", .help = "+ para a direita" },
            .{ .key = "dz", .label = "Δz (m)", .help = "+ para cima (biplano: o vão entre as asas)" },
            .{ .key = "di", .label = "decalagem (°)", .help = "incidência dela menos a da referência" },
            .{ .key = "join", .label = "pontas ligadas", .kind = .choice, .choices = &join_choices, .help = "uma placa liga a ponta dela à da referência (asa em caixa)" },
        });
        const rows = try memory.alloc([]const simulation.Cell, layout_rows.len);
        for (layout_rows, rows) |row, *cells| {
            const object = &row.object;
            cells.* = try memory.dupe(simulation.Cell, &.{ .{ .text = store.text(object, "wing", "") }, .{ .number = store.number(object, "dx", 0) }, .{ .number = store.number(object, "dy", 0) }, .{ .number = store.number(object, "dz", 0) }, .{ .number = store.number(object, "di", 0) }, .{ .text = join_choices[@intFromBool(store.flag(object, "join", false))] } });
        }
        try grids.append(memory, .{ .name = "asas", .title = "Asas do avião", .columns = columns, .rows = rows, .note = "a primeira linha é a referência (Δ = 0); 'Guardar configuração' leva estas asas para a Empenagem.", .help = "quantas asas o avião tem e onde fica cada uma, com base na primeira: uma linha é monoplano, duas lado a lado em Δz são um biplano, uma atrás da outra em Δx um tandem.", .buttons = &.{ .{ .operation = "add", .label = "+ asa", .help = "mais uma asa guardada, depois da selecionada (ou no fim)" }, .{ .operation = "delete", .label = "− asa", .help = "tira a selecionada da lista" } } });

        if (layout_rows.len > 0) {
            const wing_labels = try memory.alloc([]const u8, layout_rows.len);
            for (layout_rows, wing_labels, 0..) |row, *label, k| label.* = try text(memory, "{d}: {s}", .{ k + 1, store.text(&row.object, "wing", "") });
            var profiles: std.ArrayList([]const u8) = .empty;
            for (tail_airfoils) |name| try profiles.append(memory, name);
            for (names) |name| try appendNew(memory, &profiles, name);
            const device_rows = try deviceRows(memory, project);
            const cells_rows = try memory.alloc([]const simulation.Cell, device_rows.len);
            for (device_rows, cells_rows) |at, *cells| {
                const device = &(try devicesOf(project, at[0])).items[at[1]].object;
                try appendNew(memory, &profiles, store.text(device, "profile", "NACA 0010"));
                const defaults: model.Device = .{};
                var row: [device_keys.len]simulation.Cell = undefined;
                row[0] = .{ .text = wing_labels[at[0]] };
                row[1] = .{ .text = store.text(device, "kind", defaults.kind) };
                inline for (device_keys[2..10], 2..) |key, i| row[i] = .{ .number = store.number(device, key, @field(defaults, key)) };
                row[10] = .{ .text = store.text(device, "profile", defaults.profile) };
                cells.* = try memory.dupe(simulation.Cell, &row);
            }
            const device_columns = try memory.dupe(simulation.Column, &.{
                .{ .key = "wing", .label = "asa", .kind = .choice, .choices = wing_labels, .help = "em qual linha da tabela 'Asas do avião' ele fica" },
                .{ .key = "kind", .label = "tipo", .kind = .choice, .choices = &device_kinds, .help = "winglet: para cima; winglet_baixo: para baixo; placa: metade para cima e metade para baixo; cerca: placa fina sobre o extradorso" },
                .{ .key = "eta", .label = "posição", .help = "onde, na semienvergadura: 0 = raiz, 1 = ponta" },
                .{ .key = "dx", .label = "recuo (m)", .help = "do bordo de ataque dele em relação ao da asa ali: + para trás" },
                .{ .key = "height", .label = "altura (m)", .help = "na placa, a soma das duas metades" },
                .{ .key = "root_chord", .label = "corda (m)", .help = "na raiz dele; 0 = a corda da asa ali" },
                .{ .key = "taper", .label = "afilamento", .help = "corda da ponta / corda da raiz" },
                .{ .key = "sweep", .label = "enflechamento (°)", .help = "do bordo de ataque" },
                .{ .key = "cant", .label = "inclinação (°)", .help = "a partir da vertical: 0 = vertical, 90 = no plano da asa" },
                .{ .key = "toe", .label = "calagem (°)", .help = "+ bordo de ataque para fora" },
                .{ .key = "profile", .label = "perfil", .kind = .choice, .choices = profiles.items, .help = "o perfil dele" },
            });
            try grids.append(memory, .{ .name = "dispositivos", .title = "Dispositivos das asas", .columns = device_columns, .rows = cells_rows, .note = "vão com a configuração guardada; a Empenagem e o avião montado levam cada um na asa dele.", .help = "winglets, placas de ponta e cercas, cada um preso a uma asa da tabela acima, com a geometria dele. O 3D mostra cada um no lugar.", .buttons = &.{ .{ .operation = "add", .label = "+ dispositivo", .help = "um winglet na ponta da asa do selecionado (ou da primeira)" }, .{ .operation = "delete", .label = "− dispositivo", .help = "tira o selecionado" } } });
        }
    }
    if (table) {
        const choices = try memory.alloc([]const u8, names.len + 1);
        choices[0] = "";
        @memcpy(choices[1..], names);
        var columns = partition_columns;
        columns[3].choices = choices;
        const list = params.get("partitions").?.array.items;
        const rows = try memory.alloc([]const simulation.Cell, list.len);
        for (list, rows) |item, *cells| {
            const object = &item.object;
            cells.* = try memory.dupe(simulation.Cell, &.{ .{ .number = store.number(object, "span", 1) }, .{ .number = store.number(object, "chord", 0.3) }, .{ .number = store.number(object, "taper", 1) }, .{ .text = store.text(object, "airfoil", "") }, .{ .number = store.number(object, "offset", 0) }, .{ .number = store.number(object, "twist", 0) } });
        }
        const span = store.number(params, "span", 0);
        const area = store.number(params, "area", 0);
        try grids.append(memory, .{ .name = "partições", .title = "Partições (do centro para a ponta)", .columns = try memory.dupe(simulation.Column, &columns), .rows = rows, .note = try text(memory, "envergadura total: {d:.3} m · área: {d:.4} m² · alongamento: {d:.2}", .{ span, area, if (area > 0) span * span / area else std.math.nan(f64) }), .help = "uma linha por partição, como na planilha: envergadura, corda, afilamento, perfil, recuo e torção. A envergadura total é a soma das partições. Uma asa reta é uma linha só (afilamento 1).", .buttons = &.{ .{ .operation = "add", .label = "+ partição", .help = "nova partição depois da selecionada (ou no fim), começando com a corda em que a anterior termina" }, .{ .operation = "delete", .label = "− partição", .help = "apaga a selecionada (fica pelo menos uma)" }, .{ .operation = "reset", .label = "do trapézio", .help = "refaz a tabela a partir do trapézio atual" } } });
    }
    var config_names: std.ArrayList([]const u8) = .empty;
    for (project.list("configs").items) |item| if (item == .object) try config_names.append(memory, store.text(&item.object, "name", ""));
    const actions = try memory.dupe(simulation.StageAction, &.{.{ .key = "config", .label = "Guardar configuração", .arg = "text", .help = "guarda as asas da tabela 'Asas do avião' (quais e onde) com um nome; a Empenagem passa a usar esta configuração", .default = try stages.nextName(memory, "configuração 1", config_names.items) }});

    return .{
        .title = "Asa",
        .help = "A asa a partir do perfil escolhido: forma em planta, linha sustentadora, onde o estol começa, polar e L/D. A incidência sai do ângulo de cruzeiro. Guarde as asas que quiser comparar: a etapa Empenagem parte de uma delas.",
        .keep_label = "Guardar asa",
        .params = form.items,
        .disabled = disabled,
        .kept = kept.items,
        .actions = actions,
        .grids = grids.items,
        .summary = summary.items,
        .checks = checks.items,
        .figures = figures,
        .view = try viewOf(memory, shown),
    };
}

fn appendNew(memory: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |known| if (std.mem.eql(u8, known, name)) return;
    try list.append(memory, name);
}

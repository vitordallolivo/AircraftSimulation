//! Planilhas "por endereço de célula" (como a Dados_Desempenho.xlsx das equipes; o par de `cellmap.py`): em vez de
//! uma planilha no formato do programa, um arquivo de mapa (`.json`, em `data/mappings`) diz de qual célula sai cada
//! campo do avião, com escala e deslocamento. Trocar a planilha é trocar o mapa. O mapa:
//!
//!     {
//!       "base": "conventional",                        avião de partida (modelo padrão ou arquivo); sem ele, o aberto
//!       "set": {"tanks": [], "payload.enabled": false}, valores fixos, antes das células
//!       "fields": {
//!         "mass.base_mass": "Geral!C8",
//!         "surfaces[wing].CLa": {"cell": "Superficies!C4", "scale": 57.29577951308232},
//!         "@wing.area": "Superficies!C3"               geometria: area, span, chord, xac, K (refaz as seções)
//!       },
//!       "thrust_sets": {"sheet": "Tracao", "first_row": 3, ...}   conjuntos de tração por polinômio (poly55)
//!     }
//!
//! Caminhos: `a.b.c`, listas por índice (`propulsion[0]`) ou por papel ou nome (`surfaces[wing]`), vetores
//! (`mass.base_cg[0]`). O resultado é o texto `.json` do avião, mais os avisos (célula vazia, aba que falta).
const std = @import("std");
const core = @import("aerosim");
const templates = @import("templates");

const xlsx = core.xlsx;
const Value = std.json.Value;

/// as chaves dos modelos padrão no mapa, na ordem de `templates.all` (`TEMPLATES` de `templates.py`)
const template_keys = [_][]const u8{ "conventional", "flying_wing", "twin_boom" };

/// g padrão (m/s²), para o ganho "g" dos conjuntos de tração (o polinômio em kgf)
const standard_gravity = 9.80665;

pub const Error = error{ BadMap, BadPath, UnknownBase };

/// o avião lido e o que não deu certo no caminho
pub const Result = struct {
    json: []const u8,
    warnings: []const []const u8,
};

/// o modelo de partida pedido pelo mapa: o texto de um modelo padrão, ou null se o mapa aponta um arquivo (`base`)
/// ou não pede nenhum
pub fn baseTemplate(map_bytes: []const u8) ?[]const u8 {
    const key = baseName(map_bytes) orelse return null;
    for (template_keys, 0..) |name, i| if (std.mem.eql(u8, name, key)) return templates.all[i].json;
    return null;
}

/// o `base` do mapa (o nome do modelo ou o caminho do arquivo), ou null
pub fn baseName(map_bytes: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const map = std.json.parseFromSliceLeaky(Value, arena.allocator(), map_bytes, .{}) catch return null;
    if (map != .object) return null;
    const base = map.object.get("base") orelse return null;
    if (base != .string) return null;
    // a fatia aponta para dentro de `map_bytes` só quando o texto não tem escapes; o nome do modelo nunca tem
    const at = std.mem.indexOf(u8, map_bytes, base.string) orelse return null;
    return map_bytes[at..][0..base.string.len];
}

/// é um arquivo de mapa de células (tem "fields")?
pub fn isMap(bytes: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const map = std.json.parseFromSliceLeaky(Value, arena.allocator(), bytes, .{}) catch return false;
    return map == .object and map.object.get("fields") != null;
}

/// lê a planilha `workbook_bytes` pelo mapa, partindo do avião `base_json` (o modelo do mapa ou o avião aberto)
pub fn read(memory: std.mem.Allocator, map_bytes: []const u8, workbook_bytes: []const u8, base_json: []const u8) !Result {
    const map = try std.json.parseFromSliceLeaky(Value, memory, map_bytes, .{});
    if (map != .object) return Error.BadMap;
    const book = try xlsx.Workbook.parse(memory, workbook_bytes);
    var aircraft = try std.json.parseFromSliceLeaky(Value, memory, base_json, .{});
    var warnings: std.ArrayList([]const u8) = .empty;

    if (map.object.get("set")) |fixed| if (fixed == .object) {
        var it = fixed.object.iterator();
        while (it.next()) |item| set(memory, &aircraft, item.key_ptr.*, item.value_ptr.*) catch |err|
            try warnings.append(memory, try std.fmt.allocPrint(memory, "set {s}: {s}", .{ item.key_ptr.*, @errorName(err) }));
    };

    // a geometria (@papel.area...) vem depois dos campos, uma superfície de cada vez
    var geometry: std.StringArrayHashMapUnmanaged(Shape) = .empty;
    if (map.object.get("fields")) |fields| if (fields == .object) {
        var it = fields.object.iterator();
        while (it.next()) |item| {
            const target = item.key_ptr.*;
            const spec = Spec.of(item.value_ptr.*) orelse {
                try warnings.append(memory, try std.fmt.allocPrint(memory, "{s}: mapa sem célula", .{target}));
                continue;
            };
            const bang = std.mem.lastIndexOfScalar(u8, spec.cell, '!') orelse 0;
            const sheet_name = spec.cell[0..bang];
            if (book.sheet(sheet_name) == null) {
                try warnings.append(memory, try std.fmt.allocPrint(memory, "{s}: aba '{s}' não existe", .{ target, sheet_name }));
                continue;
            }
            const cell = book.reference(spec.cell) orelse {
                try warnings.append(memory, try std.fmt.allocPrint(memory, "{s}: {s} vazia", .{ target, spec.cell }));
                continue;
            };
            const value: Value = switch (cell) {
                .number => |number| .{ .float = number * spec.scale + spec.offset },
                .boolean => |flag| .{ .bool = flag },
                .text => |text| blk: {
                    if (std.mem.trim(u8, text, " \t").len == 0) {
                        try warnings.append(memory, try std.fmt.allocPrint(memory, "{s}: {s} vazia", .{ target, spec.cell }));
                        continue;
                    }
                    break :blk .{ .string = text };
                },
            };
            if (target.len > 0 and target[0] == '@') {
                const dot = std.mem.indexOfScalar(u8, target, '.') orelse continue;
                const entry = try geometry.getOrPut(memory, target[1..dot]);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                const number = switch (value) {
                    .float => |x| x,
                    else => continue,
                };
                entry.value_ptr.set(target[dot + 1 ..], number);
                continue;
            }
            set(memory, &aircraft, target, value) catch |err| {
                try warnings.append(memory, try std.fmt.allocPrint(memory, "{s}: {s}", .{ target, @errorName(err) }));
                continue;
            };
            // a densidade da planilha manda: sem a altitude-densidade gravada, quem lê o avião a tira do ρ
            if (std.mem.eql(u8, target, "environment.rho")) if (aircraft.object.getPtr("environment")) |environment| {
                if (environment.* == .object) _ = environment.object.orderedRemove("density_altitude");
            };
        }
    };
    var shapes = geometry.iterator();
    while (shapes.next()) |item| {
        const surface = findSurface(&aircraft, item.key_ptr.*) orelse {
            try warnings.append(memory, try std.fmt.allocPrint(memory, "superfície '{s}' não existe no avião de partida", .{item.key_ptr.*}));
            continue;
        };
        try item.value_ptr.apply(memory, surface);
    }
    if (map.object.get("thrust_sets")) |sets| if (sets == .object)
        try readThrustSets(memory, book, sets.object, &aircraft, &warnings);

    return .{ .json = try std.json.Stringify.valueAlloc(memory, aircraft, .{ .whitespace = .indent_1 }), .warnings = warnings.items };
}

/// o que o mapa diz de um campo: a célula, a escala e o deslocamento (valor = célula · escala + deslocamento)
const Spec = struct {
    cell: []const u8,
    scale: f64 = 1,
    offset: f64 = 0,

    fn of(raw: Value) ?Spec {
        switch (raw) {
            .string => |cell| return .{ .cell = cell },
            .object => |object| {
                const cell = object.get("cell") orelse return null;
                if (cell != .string) return null;
                return .{ .cell = cell.string, .scale = numberOf(object.get("scale")) orelse 1, .offset = numberOf(object.get("offset")) orelse 0 };
            },
            else => return null,
        }
    }
};

fn numberOf(value: ?Value) ?f64 {
    return switch (value orelse return null) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        .string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

// ------------------------------------------------------------------ caminhos

/// muda o campo `path` do avião para `value`; um campo inteiro ou booleano do avião continua do mesmo tipo
fn set(memory: std.mem.Allocator, root: *Value, path: []const u8, value: Value) !void {
    var node = root;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        const last = parts.peek() == null;
        const open = std.mem.indexOfScalar(u8, part, '[');
        const name = if (open) |at| part[0..at] else part;
        if (node.* != .object) return Error.BadPath;
        if (open == null) {
            // um campo que o avião não tem não é criado (o `getattr` de `cellmap.py` acusa)
            if (last) return node.object.put(memory, name, coerce(node.object.get(name) orelse return Error.BadPath, value));
            node = node.object.getPtr(name) orelse return Error.BadPath;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, part, open.?, ']') orelse return Error.BadPath;
        const selector = part[open.? + 1 .. close];
        const list = node.object.getPtr(name) orelse return Error.BadPath;
        if (list.* != .array) return Error.BadPath;
        const index = try pick(list.array.items, selector);
        if (last) {
            list.array.items[index] = coerce(list.array.items[index], value);
            return;
        }
        node = &list.array.items[index];
    }
}

/// o item da lista pelo índice ("0", "-1") ou pelo papel ou nome ("wing")
fn pick(items: []const Value, selector: []const u8) !usize {
    if (std.fmt.parseInt(i64, selector, 10)) |index| {
        const position = if (index < 0) @as(i64, @intCast(items.len)) + index else index;
        if (position < 0 or position >= items.len) return Error.BadPath;
        return @intCast(position);
    } else |_| {}
    for (items, 0..) |item, i| {
        if (item != .object) continue;
        for ([_][]const u8{ "role", "name" }) |key| if (item.object.get(key)) |text| {
            if (text == .string and std.mem.eql(u8, text.string, selector)) return i;
        };
    }
    return Error.BadPath;
}

/// o valor novo no tipo do valor de antes (`_set` de `cellmap.py`: bool fica bool, inteiro fica inteiro)
fn coerce(current: Value, value: Value) Value {
    const number = numberOf(value);
    return switch (current) {
        .bool => if (number) |x| .{ .bool = x != 0 } else value,
        .integer => if (number) |x| .{ .integer = @intFromFloat(@trunc(x)) } else value,
        else => value,
    };
}

fn findSurface(root: *Value, role: []const u8) ?*Value {
    if (root.* != .object) return null;
    const surfaces = root.object.getPtr("surfaces") orelse return null;
    if (surfaces.* != .array) return null;
    const index = pick(surfaces.array.items, role) catch return null;
    return &surfaces.array.items[index];
}

// ------------------------------------------------------------------ geometria

/// o que o mapa pede da geometria de uma superfície
const Shape = struct {
    area: ?f64 = null,
    span: ?f64 = null,
    chord: ?f64 = null,
    xac: ?f64 = null,
    induced_factor: ?f64 = null,

    fn set(shape: *Shape, what: []const u8, number: f64) void {
        if (std.mem.eql(u8, what, "area")) shape.area = number;
        if (std.mem.eql(u8, what, "span")) shape.span = number;
        if (std.mem.eql(u8, what, "chord")) shape.chord = number;
        if (std.mem.eql(u8, what, "xac")) shape.xac = number;
        if (std.mem.eql(u8, what, "K")) shape.induced_factor = number;
    }

    /// refaz as seções (`_reshape`), põe o centro aerodinâmico e o Oswald
    fn apply(shape: Shape, memory: std.mem.Allocator, surface: *Value) !void {
        if (shape.area != null or shape.span != null or shape.chord != null) try reshape(memory, surface, shape);
        const plan = Planform.of(surface.*);
        if (shape.xac) |xac| try surface.object.put(memory, "x", .{ .float = xac + 0.25 * plan.mac });
        // C_Di = K C_L², então e = 1 / (π AR K) (definição do fator de Oswald; Raymer, Aircraft Design, eq. 12.48,
        // a conferir no PDF)
        if (shape.induced_factor) |factor| if (factor > 0 and plan.aspect_ratio > 0)
            try surface.object.put(memory, "oswald", .{ .float = 1.0 / (std.math.pi * plan.aspect_ratio * factor) });
    }
};

const Section = struct { y: f64, chord: f64, x_offset: f64, twist: f64 };

/// as seções da superfície em ordem de y, e o que sai delas (`area`, `span`, `mac` de `aircraft.py`)
const Planform = struct {
    root: Section = .{ .y = 0, .chord = 0, .x_offset = 0, .twist = 0 },
    tip: Section = .{ .y = 0, .chord = 0, .x_offset = 0, .twist = 0 },
    sides: f64 = 2,
    area: f64 = 0,
    span: f64 = 0,
    mac: f64 = 0,
    aspect_ratio: f64 = 0,

    fn of(surface: Value) Planform {
        var plan: Planform = .{};
        if (surface != .object) return plan;
        const symmetric = if (surface.object.get("symmetric")) |flag| flag != .bool or flag.bool else true;
        const vertical = if (surface.object.get("vertical")) |flag| flag == .bool and flag.bool else false;
        plan.sides = if (symmetric and !vertical) 2 else 1;
        const list = surface.object.get("sections") orelse return plan;
        if (list != .array or list.array.items.len == 0) return plan;
        var sections: [64]Section = undefined;
        var count: usize = 0;
        for (list.array.items) |item| {
            if (count == sections.len or item != .object) continue;
            sections[count] = .{
                .y = numberOf(item.object.get("y")) orelse 0,
                .chord = numberOf(item.object.get("chord")) orelse 0,
                .x_offset = numberOf(item.object.get("x_offset")) orelse 0,
                .twist = numberOf(item.object.get("twist")) orelse 0,
            };
            count += 1;
        }
        std.mem.sort(Section, sections[0..count], {}, struct {
            fn less(_: void, left: Section, right: Section) bool {
                return left.y < right.y;
            }
        }.less);
        plan.root = sections[0];
        plan.tip = sections[count - 1];
        var area: f64 = 0;
        var mac_top: f64 = 0;
        for (sections[0 .. count - 1], sections[1..count]) |inner, outer| {
            const width = outer.y - inner.y;
            area += 0.5 * (inner.chord + outer.chord) * width;
            mac_top += width * (inner.chord * inner.chord + inner.chord * outer.chord + outer.chord * outer.chord) / 3;
        }
        plan.mac = if (area > 0) mac_top / area else 0;
        plan.area = area * plan.sides;
        plan.span = (plan.tip.y - plan.root.y) * plan.sides;
        plan.aspect_ratio = if (plan.area > 0) plan.span * plan.span / plan.area else 0;
        return plan;
    }
};

/// refaz as seções com a área, a envergadura ou a corda pedidas, mantendo o afilamento, o enflechamento e a
/// torção (duas seções, raiz e ponta, como `_reshape` de `cellmap.py`)
fn reshape(memory: std.mem.Allocator, surface: *Value, shape: Shape) !void {
    const plan = Planform.of(surface.*);
    const taper = if (plan.root.chord > 0) plan.tip.chord / plan.root.chord else 1.0;
    const span = shape.span orelse plan.span;
    const half = span / plan.sides;
    const mean_chord = if (shape.area) |area|
        area / span
    else if (shape.chord) |chord|
        chord * (1 + taper) / 2
    else if (span > 0) plan.area / span else plan.root.chord;
    const root_chord = 2 * mean_chord / (1 + taper);
    const sweep_per_y = if (plan.tip.y > 0) (plan.tip.x_offset - plan.root.x_offset) / plan.tip.y else 0;
    var list = std.json.Array.init(memory);
    for ([_]f64{ 0, 1 }) |fraction| {
        var section: std.json.ObjectMap = .empty;
        try section.put(memory, "y", .{ .float = fraction * half });
        try section.put(memory, "chord", .{ .float = root_chord * (1 + (taper - 1) * fraction) });
        try section.put(memory, "x_offset", .{ .float = fraction * half * sweep_per_y });
        try section.put(memory, "twist", .{ .float = plan.root.twist + (plan.tip.twist - plan.root.twist) * fraction });
        try list.append(.{ .object = section });
    }
    try surface.object.put(memory, "sections", .{ .array = list });
}

// ------------------------------------------------------------------ conjuntos de tração

/// os conjuntos de tração (uma linha por conjunto motor + hélice, os 21 coeficientes do poly55); o da linha
/// escolhida na planilha (`select_cell` + `row_offset`) vai para todos os motores do avião
fn readThrustSets(memory: std.mem.Allocator, book: xlsx.Workbook, spec: std.json.ObjectMap, aircraft: *Value, warnings: *std.ArrayList([]const u8)) !void {
    const sheet_name = if (spec.get("sheet")) |name| if (name == .string) name.string else "" else "";
    const sheet = book.sheet(sheet_name) orelse {
        try warnings.append(memory, try std.fmt.allocPrint(memory, "thrust_sets: aba '{s}' não existe", .{sheet_name}));
        return;
    };
    const coefficient_count = 21;
    const first_column: u32 = @intFromFloat(numberOf(spec.get("coef_first_col")) orelse 2);
    const name_column: u32 = @intFromFloat(numberOf(spec.get("name_col")) orelse 1);
    const row_offset: i64 = @intFromFloat(numberOf(spec.get("row_offset")) orelse 0);
    const selected: ?i64 = if (spec.get("select_cell")) |cell| if (cell == .string) blk: {
        const value = book.reference(cell.string) orelse break :blk null;
        const number = value.asNumber() orelse break :blk null;
        break :blk @as(i64, @intFromFloat(number)) + row_offset;
    } else null else null;
    const wanted = selected orelse return;
    if (wanted < 1) return;
    const row: u32 = @intCast(wanted);
    var coefficients: [coefficient_count]f64 = undefined;
    var any = false;
    for (&coefficients, 0..) |*coefficient, k| {
        const value = sheet.at(row, first_column + @as(u32, @intCast(k)));
        coefficient.* = if (value) |cell| cell.asNumber() orelse 0 else 0;
        any = any or value != null;
    }
    if (!any) {
        try warnings.append(memory, try std.fmt.allocPrint(memory, "thrust_sets: linha {d} (nhelice) não tem coeficientes", .{row}));
        return;
    }
    const static_thrust = if (spec.get("T0_col")) |column| (sheet.at(row, @intFromFloat(numberOf(column) orelse 0)) orelse xlsx.Value{ .number = 0 }).asNumber() orelse 0 else 0;
    const rotation = if (spec.get("n_col")) |column| (sheet.at(row, @intFromFloat(numberOf(column) orelse 0)) orelse xlsx.Value{ .number = 0 }).asNumber() orelse 0 else 0;
    if (spec.get("p00_from_T0")) |flag| if (flag == .bool and flag.bool) {
        coefficients[0] = static_thrust; // o original soma T0 no lugar de p00
    };
    const name: []const u8 = if (sheet.at(row, name_column)) |cell| switch (cell) {
        .text => |text| text,
        .number => |number| try std.fmt.allocPrint(memory, "{d}", .{number}),
        .boolean => "conjunto",
    } else try std.fmt.allocPrint(memory, "conjunto {d}", .{wanted - row_offset});
    const reference_density = if (spec.get("rho0_cell")) |cell| if (cell == .string) ((book.reference(cell.string) orelse xlsx.Value{ .number = 1.225 }).asNumber() orelse 1.225) else 1.225 else 1.225;

    var poly: std.json.ObjectMap = .empty;
    try poly.put(memory, "name", .{ .string = name });
    var list = std.json.Array.init(memory);
    for (coefficients) |coefficient| try list.append(.{ .float = coefficient });
    try poly.put(memory, "coefs", .{ .array = list });
    try poly.put(memory, "x_var", .{ .string = textOf(spec.get("x"), "V") });
    try poly.put(memory, "y_var", .{ .string = textOf(spec.get("y"), "none") });
    try poly.put(memory, "gain", .{ .float = try gain(book, spec, static_thrust) });
    try poly.put(memory, "rho_exp", .{ .float = numberOf(spec.get("rho_exp")) orelse 0 });
    try poly.put(memory, "rho0", .{ .float = reference_density });
    try poly.put(memory, "xmax", .{ .float = numberOf(spec.get("xmax")) orelse 0 });
    try poly.put(memory, "ymax", .{ .float = numberOf(spec.get("ymax")) orelse 0 });
    try poly.put(memory, "x_const", .{ .float = constant(textOf(spec.get("x_const"), ""), rotation, static_thrust) });
    try poly.put(memory, "y_const", .{ .float = constant(textOf(spec.get("y_const"), ""), rotation, static_thrust) });
    try poly.put(memory, "T0", .{ .float = static_thrust });
    try poly.put(memory, "n", .{ .float = rotation });
    try poly.put(memory, "source", .{ .string = try std.fmt.allocPrint(memory, "{s}!linha {d}", .{ sheet_name, row }) });

    const units = if (aircraft.* == .object) aircraft.object.getPtr("propulsion") else null;
    if (units == null or units.?.* != .array or units.?.array.items.len == 0) {
        try warnings.append(memory, "thrust_sets: o avião de partida não tem motor para receber o conjunto");
        return;
    }
    for (units.?.array.items) |*unit| if (unit.* == .object) {
        try unit.object.put(memory, "thrust_model", .{ .string = "poly" });
        try unit.object.put(memory, "thrust_poly", .{ .object = poly });
    };
}

fn textOf(value: ?Value, fallback: []const u8) []const u8 {
    const found = value orelse return fallback;
    return if (found == .string) found.string else fallback;
}

fn constant(name: []const u8, rotation: f64, static_thrust: f64) f64 {
    if (std.mem.eql(u8, name, "n")) return rotation;
    if (std.mem.eql(u8, name, "T0")) return static_thrust;
    return 0;
}

/// o ganho do polinômio: "1", "g" (polinômio em kgf), "T0", "T0*PT0", "g*PT0" ou um número
fn gain(book: xlsx.Workbook, spec: std.json.ObjectMap, static_thrust: f64) !f64 {
    const cell = textOf(spec.get("pt0_cell"), "Geral!C29");
    const thrust_fraction = if (book.reference(cell)) |value| value.asNumber() orelse 1 else 1;
    var buffer: [32]u8 = undefined;
    var length: usize = 0;
    const raw = if (spec.get("gain")) |value| switch (value) {
        .string => |text| text,
        else => std.fmt.bufPrint(&buffer, "{d}", .{numberOf(value) orelse 1}) catch "1",
    } else "1";
    var compact: [32]u8 = undefined;
    for (raw) |char| if (char != ' ' and length < compact.len) {
        compact[length] = char;
        length += 1;
    };
    const text = compact[0..length];
    if (std.mem.eql(u8, text, "1")) return 1;
    if (std.mem.eql(u8, text, "g")) return standard_gravity;
    if (std.mem.eql(u8, text, "T0")) return static_thrust;
    if (std.mem.eql(u8, text, "T0*PT0")) return static_thrust * thrust_fraction;
    if (std.mem.eql(u8, text, "g*PT0")) return standard_gravity * thrust_fraction;
    return std.fmt.parseFloat(f64, text) catch Error.BadMap;
}

// ------------------------------------------------------------------ testes

test "caminhos do mapa" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var aircraft = try std.json.parseFromSliceLeaky(Value, memory,
        \\{"mass":{"base_cg":[0.0,0.0,0.0],"count":1},"surfaces":[{"role":"wing","x":0.1},{"role":"htail","z":0.0}],"payload":{"enabled":true}}
    , .{});
    try set(memory, &aircraft, "mass.base_cg[2]", .{ .float = -0.05 });
    try set(memory, &aircraft, "surfaces[htail].z", .{ .float = 0.2 });
    try set(memory, &aircraft, "payload.enabled", .{ .float = 0 });
    try set(memory, &aircraft, "mass.count", .{ .float = 3.7 });
    try std.testing.expectEqual(@as(f64, -0.05), aircraft.object.get("mass").?.object.get("base_cg").?.array.items[2].float);
    try std.testing.expectEqual(@as(f64, 0.2), aircraft.object.get("surfaces").?.array.items[1].object.get("z").?.float);
    try std.testing.expectEqual(false, aircraft.object.get("payload").?.object.get("enabled").?.bool);
    try std.testing.expectEqual(@as(i64, 3), aircraft.object.get("mass").?.object.get("count").?.integer);
    try std.testing.expectError(Error.BadPath, set(memory, &aircraft, "surfaces[vtail].z", .{ .float = 0 }));
}

test "refazer a asa pela área e pela envergadura" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var surface = try std.json.parseFromSliceLeaky(Value, memory,
        \\{"symmetric":true,"vertical":false,"sections":[{"y":0.0,"chord":0.4,"x_offset":0.0,"twist":0.0},{"y":1.0,"chord":0.2,"x_offset":0.1,"twist":-2.0}]}
    , .{});
    try (Shape{ .area = 0.9, .span = 3.0 }).apply(memory, &surface);
    const plan = Planform.of(surface);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), plan.area, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), plan.span, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), plan.tip.chord / plan.root.chord, 1e-12); // o afilamento fica
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), plan.tip.x_offset, 1e-12); // o enflechamento fica
}

//! Os formatos antigos do avião e do catálogo (o par de `sources.py` e `flat.py`): o `.cfg` (INI legível, uma seção
//! por peça) e a planilha `.xlsx` (aba "geral" com seção, chave e valor, mais uma aba-tabela por lista de peças).
//! Os dois guardam o avião "achatado" em seções; aqui as seções voltam a ser a árvore do `.json`, e quem lê o avião
//! (a Montagem, as análises) continua lendo só o `.json`. Exemplo:
//!
//!     const texto = try sources.aircraftJson(arena, "avião.cfg", bytes);   // o mesmo .json que o Python gravaria
//!
//! Seções (as mesmas de `flat.py`):
//!
//!     [aircraft]                 escalares da raiz
//!     [fuselage], [gear], ...    cada peça filha da raiz
//!     [surfaces.0]               item 0 de uma lista
//!     [surfaces.0.sections.1]    lista dentro de um item
//!     airfoil.name = ...         peça aninhada dentro de um item, em linha
//!
//! Cada valor é lido como JSON (número, lista, texto entre aspas, true/false); o que não é JSON vira texto.
const std = @import("std");
const core = @import("aerosim");
const catalog = @import("catalog");

const xlsx = core.xlsx;

pub const Error = error{ UnknownFormat, BadSection, MissingGeneralSheet };

/// o formato pelo nome do arquivo
pub const Format = enum {
    json,
    ini,
    xlsx,

    /// o formato pela extensão (`.json`, `.cfg` ou `.ini`, `.xlsx`), ou null
    pub fn fromPath(path: []const u8) ?Format {
        const extension = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(extension, ".json")) return .json;
        if (std.ascii.eqlIgnoreCase(extension, ".cfg") or std.ascii.eqlIgnoreCase(extension, ".ini")) return .ini;
        if (std.ascii.eqlIgnoreCase(extension, ".xlsx")) return .xlsx;
        return null;
    }
};

/// as extensões de avião que se abrem
pub const aircraft_extensions = [_][]const u8{ ".json", ".cfg", ".ini", ".xlsx" };

/// o texto `.json` do avião guardado em `bytes`, qualquer que seja o formato de `path`. O `.json` da biblioteca
/// "meus aviões" (`"formato": "aerosim-aeronave"`) devolve só o avião de dentro
pub fn aircraftJson(memory: std.mem.Allocator, path: []const u8, bytes: []const u8) ![]const u8 {
    return switch (Format.fromPath(path) orelse return Error.UnknownFormat) {
        .json => unwrapLibrary(memory, bytes),
        .ini => try write(memory, try fromSections(memory, try iniSections(memory, bytes))),
        .xlsx => try write(memory, try fromSections(memory, try sheetSections(memory, try xlsx.Workbook.parse(memory, bytes)))),
    };
}

fn unwrapLibrary(memory: std.mem.Allocator, bytes: []const u8) []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{}) catch return bytes;
    if (root != .object) return bytes;
    const format = root.object.get("formato") orelse return bytes;
    if (format != .string or !std.mem.eql(u8, format.string, "aerosim-aeronave")) return bytes;
    const inner = root.object.get("aeronave") orelse return bytes;
    return std.json.Stringify.valueAlloc(memory, inner, .{ .whitespace = .indent_1 }) catch bytes;
}

// ------------------------------------------------------------------ seções

/// um valor de uma seção: o texto como veio do arquivo (lido como JSON na hora de escrever) ou um número da planilha
const Leaf = union(enum) {
    text: []const u8,
    number: f64,
    boolean: bool,
};

const Entry = struct { key: []const u8, value: Leaf };
const Section = struct { name: []const u8, entries: std.ArrayList(Entry) = .empty };

/// as seções de um `.cfg`/`.ini` (como o `configparser` do Python: `chave = valor` ou `chave: valor`, comentários
/// com `#` ou `;`, linha recuada continua o valor de cima)
fn iniSections(memory: std.mem.Allocator, text: []const u8) ![]Section {
    var sections: std.ArrayList(Section) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var last_entry: ?*Entry = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed.len < line.len and last_entry != null) { // continuação
            const entry = last_entry.?;
            entry.value = .{ .text = try std.fmt.allocPrint(memory, "{s}\n{s}", .{ entry.value.text, trimmed }) };
            continue;
        }
        if (trimmed[0] == '[') {
            const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return Error.BadSection;
            try sections.append(memory, .{ .name = trimmed[1..close] });
            last_entry = null;
            continue;
        }
        if (sections.items.len == 0) return Error.BadSection;
        const split = std.mem.indexOfAny(u8, trimmed, "=:") orelse continue;
        const section = &sections.items[sections.items.len - 1];
        try section.entries.append(memory, .{
            .key = std.mem.trim(u8, trimmed[0..split], " \t"),
            .value = .{ .text = std.mem.trim(u8, trimmed[split + 1 ..], " \t") },
        });
        last_entry = &section.entries.items[section.entries.items.len - 1];
    }
    return sections.items;
}

fn leafOf(value: xlsx.Value) Leaf {
    return switch (value) {
        .number => |number| .{ .number = number },
        .boolean => |flag| .{ .boolean = flag },
        .text => |text| .{ .text = text },
    };
}

fn cellText(memory: std.mem.Allocator, value: xlsx.Value) ![]const u8 {
    return switch (value) {
        .text => |text| text,
        .number => |number| if (number == @round(number)) std.fmt.allocPrint(memory, "{d}", .{@as(i64, @intFromFloat(number))}) else std.fmt.allocPrint(memory, "{d}", .{number}),
        .boolean => |flag| if (flag) "true" else "false",
    };
}

fn sectionNamed(memory: std.mem.Allocator, sections: *std.ArrayList(Section), name: []const u8) !*Section {
    for (sections.items) |*section| if (std.mem.eql(u8, section.name, name)) return section;
    try sections.append(memory, .{ .name = name });
    return &sections.items[sections.items.len - 1];
}

/// as seções da planilha: a aba "geral" (seção, chave, valor) e as abas-tabela ("surfaces.#.sections.#", com as
/// colunas idx0, idx1... e uma coluna por chave)
fn sheetSections(memory: std.mem.Allocator, book: xlsx.Workbook) ![]Section {
    var sections: std.ArrayList(Section) = .empty;
    const general = book.sheet("geral") orelse return Error.MissingGeneralSheet;
    var row: u32 = 2;
    while (row <= general.lastRow()) : (row += 1) {
        const name = general.at(row, 1) orelse continue;
        const key = general.at(row, 2) orelse continue;
        const section = try sectionNamed(memory, &sections, try cellText(memory, name));
        const value: Leaf = if (general.at(row, 3)) |cell| leafOf(cell) else .{ .text = "\"\"" };
        try section.entries.append(memory, .{ .key = try cellText(memory, key), .value = value });
    }
    for (book.sheets) |sheet| {
        if (std.mem.eql(u8, sheet.name, "geral") or sheet.cells.len == 0) continue;
        var depth: u32 = 0;
        var heads: std.ArrayList([]const u8) = .empty;
        var column: u32 = 1;
        while (sheet.at(1, column)) |head| : (column += 1) {
            const text = try cellText(memory, head);
            if (std.mem.startsWith(u8, text, "idx")) depth += 1;
            try heads.append(memory, text);
        }
        row = 2;
        while (row <= sheet.lastRow()) : (row += 1) {
            if (sheet.at(row, 1) == null) continue;
            var name: std.ArrayList(u8) = .empty;
            var rest = sheet.name;
            for (0..depth) |level| {
                const index = (sheet.at(row, @intCast(level + 1)) orelse break).asNumber() orelse break;
                const mark = std.mem.indexOfScalar(u8, rest, '#') orelse break;
                try name.appendSlice(memory, rest[0..mark]);
                try name.print(memory, "{d}", .{@as(i64, @intFromFloat(index))});
                rest = rest[mark + 1 ..];
            }
            try name.appendSlice(memory, rest);
            const section = try sectionNamed(memory, &sections, name.items);
            for (heads.items[depth..], depth..) |head, index| {
                const cell = sheet.at(row, @intCast(index + 1)) orelse continue;
                try section.entries.append(memory, .{ .key = head, .value = leafOf(cell) });
            }
        }
    }
    return sections.items;
}

// ------------------------------------------------------------------ a árvore

/// um nó da árvore do avião: folha ou objeto com as chaves na ordem em que aparecem
const Node = union(enum) {
    leaf: Leaf,
    object: std.ArrayList(Child),

    const Child = struct { key: []const u8, node: *Node };

    fn child(node: *Node, memory: std.mem.Allocator, key: []const u8) !*Node {
        if (node.* != .object) node.* = .{ .object = .empty };
        for (node.object.items) |item| if (std.mem.eql(u8, item.key, key)) return item.node;
        const created = try memory.create(Node);
        created.* = .{ .object = .empty };
        try node.object.append(memory, .{ .key = key, .node = created });
        return created;
    }

    /// um objeto cujas chaves são todas números vira lista (em ordem do número)
    fn isList(node: Node) bool {
        if (node != .object or node.object.items.len == 0) return false;
        for (node.object.items) |item| _ = std.fmt.parseInt(u32, item.key, 10) catch return false;
        return true;
    }
};

/// as seções viram a árvore (`unflatten` de `flat.py`)
fn fromSections(memory: std.mem.Allocator, sections: []const Section) !*Node {
    const root = try memory.create(Node);
    root.* = .{ .object = .empty };
    for (sections) |section| {
        var base = root;
        if (!std.mem.eql(u8, section.name, "aircraft")) {
            var parts = std.mem.splitScalar(u8, section.name, '.');
            while (parts.next()) |part| base = try base.child(memory, part);
        }
        for (section.entries.items) |entry| {
            var node = base;
            var parts = std.mem.splitScalar(u8, entry.key, '.');
            while (parts.next()) |part| node = try node.child(memory, part);
            node.* = .{ .leaf = entry.value };
        }
    }
    return root;
}

fn write(memory: std.mem.Allocator, root: *const Node) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(memory);
    try writeNode(memory, &out.writer, root);
    return out.written();
}

fn writeNode(memory: std.mem.Allocator, out: *std.Io.Writer, node: *const Node) !void {
    switch (node.*) {
        .leaf => |leaf| try writeLeaf(memory, out, leaf),
        .object => |children| {
            if (node.isList()) {
                const sorted = try memory.dupe(Node.Child, children.items);
                std.mem.sort(Node.Child, sorted, {}, struct {
                    fn less(_: void, left: Node.Child, right: Node.Child) bool {
                        return (std.fmt.parseInt(u32, left.key, 10) catch 0) < (std.fmt.parseInt(u32, right.key, 10) catch 0);
                    }
                }.less);
                try out.writeByte('[');
                for (sorted, 0..) |item, i| {
                    if (i > 0) try out.writeByte(',');
                    try writeNode(memory, out, item.node);
                }
                return out.writeByte(']');
            }
            try out.writeByte('{');
            for (children.items, 0..) |item, i| {
                if (i > 0) try out.writeByte(',');
                try std.json.Stringify.value(item.key, .{}, out);
                try out.writeByte(':');
                try writeNode(memory, out, item.node);
            }
            try out.writeByte('}');
        },
    }
}

/// o valor como JSON: o texto que já é JSON vai como está; o resto, entre aspas (`decode` de `flat.py`)
fn writeLeaf(memory: std.mem.Allocator, out: *std.Io.Writer, leaf: Leaf) !void {
    switch (leaf) {
        .number => |number| try out.print("{d}", .{number}),
        .boolean => |flag| try out.writeAll(if (flag) "true" else "false"),
        .text => |raw| {
            const text = std.mem.trim(u8, raw, " \t\r\n");
            if (std.json.parseFromSliceLeaky(std.json.Value, memory, text, .{})) |_| {
                try out.writeAll(text);
            } else |_| try std.json.Stringify.value(text, .{}, out);
        },
    }
}

// ------------------------------------------------------------------ o catálogo

/// os motores e as hélices de um arquivo de catálogo (`.json`, `.cfg` ou `.xlsx`, como os de `data/catalog`). As
/// baterias e os conjuntos de tração do arquivo não entram: a biblioteca do programa só guarda motores e hélices
pub fn catalogItems(memory: std.mem.Allocator, path: []const u8, bytes: []const u8) !catalog.UserItems {
    var motors: std.ArrayList(catalog.Motor) = .empty;
    var propellers: std.ArrayList(catalog.Propeller) = .empty;
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    switch (Format.fromPath(path) orelse return Error.UnknownFormat) {
        .json => {
            const Lists = struct { motors: []const catalog.Motor = &.{}, propellers: []const catalog.Propeller = &.{} };
            const lists = try std.json.parseFromSliceLeaky(Lists, memory, bytes, options);
            try motors.appendSlice(memory, lists.motors);
            try propellers.appendSlice(memory, lists.propellers);
        },
        .ini => for (try iniSections(memory, bytes)) |section| {
            const colon = std.mem.indexOfScalar(u8, section.name, ':') orelse continue;
            const kind = std.mem.trim(u8, section.name[0..colon], " ");
            const item = try itemJson(memory, std.mem.trim(u8, section.name[colon + 1 ..], " "), section.entries.items);
            if (std.mem.eql(u8, kind, "motor")) try motors.append(memory, try std.json.parseFromSliceLeaky(catalog.Motor, memory, item, options));
            if (std.mem.eql(u8, kind, "helice")) try propellers.append(memory, try std.json.parseFromSliceLeaky(catalog.Propeller, memory, item, options));
        },
        .xlsx => {
            const book = try xlsx.Workbook.parse(memory, bytes);
            for (try tableItems(memory, book, "motores")) |item| try motors.append(memory, try std.json.parseFromSliceLeaky(catalog.Motor, memory, item, options));
            const points = book.sheet("helices_tabela");
            for (try tableItems(memory, book, "helices")) |item| {
                // a aba "helices" não tem a tabela: ela vem da "helices_tabela"
                const Row = struct { name: []const u8, D: f64, pitch: f64 = 0, Ip: f64 = 0, mass: f64 = 0, source: []const u8 = "" };
                const read = try std.json.parseFromSliceLeaky(Row, memory, item, options);
                var propeller: catalog.Propeller = .{ .name = read.name, .D = read.D, .pitch = read.pitch, .Ip = read.Ip, .mass = read.mass, .J = &.{}, .CT = &.{}, .CP = &.{}, .source = read.source };
                if (points) |sheet| try propellerTable(memory, sheet, &propeller);
                try propellers.append(memory, propeller);
            }
        },
    }
    return .{ .motors = motors.items, .propellers = propellers.items };
}

/// um item do catálogo como objeto JSON (o nome mais as chaves da seção)
fn itemJson(memory: std.mem.Allocator, name: []const u8, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(memory);
    try out.writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, &out.writer);
    for (entries) |entry| {
        try out.writer.writeByte(',');
        try std.json.Stringify.value(entry.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try writeLeaf(memory, &out.writer, entry.value);
    }
    try out.writer.writeByte('}');
    return out.written();
}

/// cada linha de uma aba (cabeçalho na linha 1) como objeto JSON
fn tableItems(memory: std.mem.Allocator, book: xlsx.Workbook, title: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const sheet = book.sheet(title) orelse return out.items;
    var heads: std.ArrayList([]const u8) = .empty;
    var column: u32 = 1;
    while (sheet.at(1, column)) |head| : (column += 1) try heads.append(memory, try cellText(memory, head));
    var row: u32 = 2;
    while (row <= sheet.lastRow()) : (row += 1) {
        const name = sheet.at(row, 1) orelse continue;
        var entries: std.ArrayList(Entry) = .empty;
        for (heads.items[1..], 2..) |head, index| {
            const cell = sheet.at(row, @intCast(index)) orelse continue;
            try entries.append(memory, .{ .key = head, .value = leafOf(cell) });
        }
        try out.append(memory, try itemJson(memory, try cellText(memory, name), entries.items));
    }
    return out.items;
}

/// a tabela J, C_T, C_P da hélice (aba "helices_tabela": helice, J, CT, CP), em ordem de J
fn propellerTable(memory: std.mem.Allocator, sheet: xlsx.Sheet, propeller: *catalog.Propeller) !void {
    const Point = struct { advance: f64, thrust: f64, power: f64 };
    var points: std.ArrayList(Point) = .empty;
    var row: u32 = 2;
    while (row <= sheet.lastRow()) : (row += 1) {
        const owner = sheet.at(row, 1) orelse continue;
        if (!std.mem.eql(u8, try cellText(memory, owner), propeller.name)) continue;
        try points.append(memory, .{
            .advance = (sheet.at(row, 2) orelse continue).asNumber() orelse continue,
            .thrust = (sheet.at(row, 3) orelse continue).asNumber() orelse continue,
            .power = (sheet.at(row, 4) orelse continue).asNumber() orelse continue,
        });
    }
    std.mem.sort(Point, points.items, {}, struct {
        fn less(_: void, left: Point, right: Point) bool {
            return left.advance < right.advance;
        }
    }.less);
    const advance = try memory.alloc(f64, points.items.len);
    const thrust = try memory.alloc(f64, points.items.len);
    const power = try memory.alloc(f64, points.items.len);
    for (points.items, 0..) |point, i| {
        advance[i] = point.advance;
        thrust[i] = point.thrust;
        power[i] = point.power;
    }
    propeller.J = advance;
    propeller.CT = thrust;
    propeller.CP = power;
}

// ------------------------------------------------------------------ testes

test "o .cfg vira a árvore do .json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const text =
        \\# aeronave (aerosim)
        \\[aircraft]
        \\name = Teste
        \\[fuselage]
        \\length = 1.2
        \\[surfaces.1]
        \\name = EH
        \\airfoil.name = "0012"
        \\[surfaces.0]
        \\name = Asa
        \\[surfaces.0.sections.0]
        \\y = 0.0
        \\chord = [0.3, 0.2]
    ;
    const json = try aircraftJson(memory, "x.cfg", text);
    try std.testing.expectEqualStrings(
        \\{"name":"Teste","fuselage":{"length":1.2},"surfaces":[{"name":"Asa","sections":[{"y":0.0,"chord":[0.3, 0.2]}]},{"name":"EH","airfoil":{"name":"0012"}}]}
    , json);
}

test "catálogo .cfg do repositório" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/catalog/catalog.cfg", memory, .limited(1 << 22));
    const items = try catalogItems(memory, "catalog.cfg", bytes);
    try std.testing.expectEqualStrings("Scorpion A-5025-310Kv", items.motors[0].name);
    try std.testing.expectEqual(@as(f64, 310), items.motors[0].Kv);
    try std.testing.expectEqualStrings("APC 15x8E", items.propellers[0].name);
    try std.testing.expectEqual(@as(usize, 30), items.propellers[0].J.len);
}

test "catálogo .xlsx do repositório" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/catalog/catalog.xlsx", memory, .limited(1 << 24));
    const items = try catalogItems(memory, "catalog.xlsx", bytes);
    try std.testing.expect(items.motors.len >= 3);
    try std.testing.expectEqualStrings("Scorpion A-5025-310Kv", items.motors[0].name);
    try std.testing.expect(items.propellers.len >= 1);
    try std.testing.expect(items.propellers[0].J.len > 5);
}

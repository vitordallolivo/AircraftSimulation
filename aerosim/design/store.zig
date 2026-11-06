//! O projeto da sprint em Zig, o par de `store.py` e `project.py`: abre a pasta do projeto (o `sprint.json` e um
//! arquivo por asa) ou o `.json` antigo de um arquivo só, e grava de volta no formato da pasta, o mesmo que o Python
//! lê. Em memória o projeto fica como o `DesignProject` do Python escrito em JSON (`to_dict`): requisitos, regras,
//! perfis, rascunhos e as listas `wings`, `sets` e `aircraft`, em que cada conjunto leva a cópia da asa e cada avião
//! a do conjunto. As etapas leem e mudam essa árvore; o que o Zig não conhece passa intacto de uma gravação a outra.
//!
//!     var project = try store.open(gpa, io, "~/sprint");
//!     store.number(project.section("requirements"), "V_cruise", 15)
//!     try project.save(io);
const std = @import("std");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

pub const main_name = "sprint.json";
pub const legacy_name = "projeto.json";
const kind_main = "aerosim-sprint";
const kind_wing = "aerosim-sprint-asa";
const version = 2;
const split_keys = [_][]const u8{ "wings", "sets", "aircraft" };

pub const Error = error{ NotProject, OutOfMemory } || std.Io.Dir.WriteFileError || std.Io.Dir.DeleteFileError || std.Io.Dir.CreateDirPathError;

/// o projeto aberto: a árvore (como o `DesignProject` em JSON) e a pasta onde ele grava
pub const Project = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,
    folder: []const u8,

    pub fn deinit(project: *Project) void {
        project.arena.deinit();
    }

    /// a memória das mudanças (vive até `deinit`)
    pub fn memory(project: *Project) std.mem.Allocator {
        return project.arena.allocator();
    }

    /// uma parte do projeto ("requirements", "rules", "wing_draft"...), criada vazia se não existe (o Python
    /// completa com os padrões)
    pub fn section(project: *Project, key: []const u8) *ObjectMap {
        const gop = project.root.object.getOrPut(project.memory(), key) catch unreachable;
        if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
        return &gop.value_ptr.object;
    }

    /// uma lista do projeto ("wings", "sets", "aircraft", "airfoils", "variables"...), criada vazia se não existe
    pub fn list(project: *Project, key: []const u8) *Array {
        const gop = project.root.object.getOrPut(project.memory(), key) catch unreachable;
        if (!gop.found_existing or gop.value_ptr.* != .array) gop.value_ptr.* = .{ .array = .init(project.memory()) };
        return &gop.value_ptr.array;
    }

    /// grava o projeto na pasta, no formato novo (`save` de `store.py`): o `sprint.json` e um arquivo por asa; apaga
    /// os arquivos de asa da pasta que o projeto não usa mais
    pub fn save(project: *Project, io: std.Io) !void {
        var scratch = std.heap.ArenaAllocator.init(project.arena.child_allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const parts = try split(temporary, project.root);
        const dir = std.Io.Dir.cwd();
        try dir.createDirPath(io, project.folder);
        for (parts.files) |file| try writeJson(temporary, io, try std.fs.path.join(temporary, &.{ project.folder, file.name }), file.value);
        const existing = try wingFiles(temporary, io, project.folder);
        for (existing) |file| {
            var used = false;
            for (parts.files) |written| used = used or std.mem.eql(u8, written.name, file.name);
            if (!used) dir.deleteFile(io, try std.fs.path.join(temporary, &.{ project.folder, file.name })) catch {};
        }
        try writeJson(temporary, io, try std.fs.path.join(temporary, &.{ project.folder, main_name }), parts.main);
    }
};

// ------------------------------------------------------------------ leitura dos campos

/// o número de um campo (inteiro ou não), ou o padrão
pub fn number(object: *const ObjectMap, key: []const u8, fallback: f64) f64 {
    const value = object.get(key) orelse return fallback;
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .number_string => |digits| std.fmt.parseFloat(f64, digits) catch fallback,
        else => fallback,
    };
}

/// o texto de um campo, ou o padrão
pub fn text(object: *const ObjectMap, key: []const u8, fallback: []const u8) []const u8 {
    const value = object.get(key) orelse return fallback;
    return if (value == .string) value.string else fallback;
}

/// o sim/não de um campo, ou o padrão
pub fn flag(object: *const ObjectMap, key: []const u8, fallback: bool) bool {
    const value = object.get(key) orelse return fallback;
    return if (value == .bool) value.bool else fallback;
}

/// um campo objeto, se existe
pub fn child(object: *const ObjectMap, key: []const u8) ?*ObjectMap {
    const value = object.getPtr(key) orelse return null;
    return if (value.* == .object) &value.object else null;
}

/// escreve um número num campo
pub fn setNumber(project: *Project, object: *ObjectMap, key: []const u8, value: f64) !void {
    try object.put(project.memory(), key, .{ .float = value });
}

/// escreve um texto num campo (copiado para a memória do projeto)
pub fn setText(project: *Project, object: *ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(project.memory(), key, .{ .string = try project.memory().dupe(u8, value) });
}

/// o nome de um candidato guardado (asa, conjunto, avião): `params.name`
pub fn nameOf(candidate: Value) []const u8 {
    if (candidate != .object) return "";
    const params = candidate.object.get("params") orelse return "";
    return if (params == .object) text(&params.object, "name", "") else "";
}

// ------------------------------------------------------------------ abrir

/// abre a pasta (formato novo; senão o `projeto.json` antigo dela) ou um `.json` antigo (`load` de `store.py`). A
/// pasta onde o projeto grava é a própria pasta ou, para um `.json` solto, uma pasta com o nome dele ao lado
pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Project {
    var project: Project = .{ .arena = .init(gpa), .root = undefined, .folder = "" };
    errdefer project.deinit();
    const memory = project.arena.allocator();
    const dir = std.Io.Dir.cwd();
    const is_folder = if (dir.openDir(io, path, .{})) |opened| blk: {
        var folder = opened;
        folder.close(io);
        break :blk true;
    } else |_| false;
    if (is_folder) {
        project.folder = try memory.dupe(u8, path);
        if (try readJson(memory, io, try std.fs.path.join(memory, &.{ path, main_name }))) |main| {
            project.root = try join(memory, main, try wingFiles(memory, io, path));
        } else if (try readJson(memory, io, try std.fs.path.join(memory, &.{ path, legacy_name }))) |legacy| {
            project.root = legacy;
        } else {
            project.root = try join(memory, .{ .object = .empty }, try wingFiles(memory, io, path));
        }
    } else {
        const read = (try readJson(memory, io, path)) orelse return error.NotProject;
        const name = std.fs.path.basename(path);
        const folder = std.fs.path.dirname(path) orelse ".";
        if (read == .object and std.mem.eql(u8, text(&read.object, "format", ""), kind_wing) or std.mem.eql(u8, name, main_name)) {
            return open(gpa, io, folder);
        }
        project.root = read;
        const stem = name[0 .. name.len - std.fs.path.extension(name).len];
        project.folder = try std.fs.path.join(memory, &.{ folder, stem });
    }
    if (project.root != .object) return error.NotProject;
    return project;
}

/// um projeto vazio que grava em `folder` (o Python completa os padrões ao abrir)
pub fn empty(gpa: std.mem.Allocator, folder: []const u8) !Project {
    var project: Project = .{ .arena = .init(gpa), .root = undefined, .folder = "" };
    project.root = .{ .object = .empty };
    project.folder = try project.arena.allocator().dupe(u8, folder);
    return project;
}

fn readJson(memory: std.mem.Allocator, io: std.Io, path: []const u8) !?Value {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 28)) catch return null;
    return std.json.parseFromSliceLeaky(Value, memory, bytes, .{}) catch null;
}

fn writeJson(memory: std.mem.Allocator, io: std.Io, path: []const u8, value: Value) !void {
    var out: std.Io.Writer.Allocating = .init(memory);
    std.json.Stringify.value(value, .{ .whitespace = .indent_1 }, &out.writer) catch return error.OutOfMemory;
    const temporary = try std.fmt.allocPrint(memory, "{s}.tmp", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = out.written() });
    std.Io.Dir.rename(std.Io.Dir.cwd(), temporary, std.Io.Dir.cwd(), path, io) catch try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// um arquivo de asa da pasta
const File = struct { name: []const u8, value: Value };

/// os arquivos de asa da pasta, em ordem de nome (`wing_files` de `store.py`)
fn wingFiles(memory: std.mem.Allocator, io: std.Io, folder: []const u8) ![]File {
    var out: std.ArrayList(File) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind == .directory or !std.ascii.endsWithIgnoreCase(entry.name, ".json")) continue;
        if (std.mem.eql(u8, entry.name, main_name) or std.mem.eql(u8, entry.name, legacy_name)) continue;
        const value = (try readJson(memory, io, try std.fs.path.join(memory, &.{ folder, entry.name }))) orelse continue;
        if (value != .object or !std.mem.eql(u8, text(&value.object, "format", ""), kind_wing)) continue;
        try out.append(memory, .{ .name = try memory.dupe(u8, entry.name), .value = value });
    }
    std.mem.sort(File, out.items, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return out.items;
}

// ------------------------------------------------------------------ juntar e repartir

/// um conjunto do arquivo da asa → o conjunto do projeto (`_set_from`): a cópia da asa do arquivo e os nomes do Python
fn setFrom(memory: std.mem.Allocator, stored: Value, wing: Value) !Value {
    var out: ObjectMap = .empty;
    const source = if (stored == .object) stored.object else ObjectMap.empty;
    try out.put(memory, "params", source.get("params") orelse .{ .object = .empty });
    try out.put(memory, "wing", wing);
    try out.put(memory, "note", source.get("note") orelse .{ .string = "" });
    try out.put(memory, "wing2", source.get("asa2") orelse .null);
    try out.put(memory, "group", source.get("grupo") orelse .{ .string = "" });
    try out.put(memory, "more_wings", source.get("mais_asas") orelse .{ .array = .init(memory) });
    try out.put(memory, "more_places", source.get("lugares") orelse .{ .array = .init(memory) });
    try out.put(memory, "devices", source.get("dispositivos") orelse .{ .array = .init(memory) });
    return .{ .object = out };
}

/// o conjunto do projeto → o do arquivo da asa (`_set_dict`)
fn setDict(memory: std.mem.Allocator, set: Value) !Value {
    var out: ObjectMap = .empty;
    const source = set.object;
    try out.put(memory, "params", source.get("params") orelse .{ .object = .empty });
    try out.put(memory, "note", source.get("note") orelse .{ .string = "" });
    if (source.get("wing2")) |second| if (second != .null) {
        try out.put(memory, "asa2", second);
        try out.put(memory, "grupo", source.get("group") orelse .{ .string = "" });
    };
    if (source.get("more_wings")) |more| if (more == .array and more.array.items.len > 0) {
        try out.put(memory, "mais_asas", more);
        try out.put(memory, "lugares", source.get("more_places") orelse .{ .array = .init(memory) });
    };
    if (source.get("devices")) |devices| if (devices == .array and devices.array.items.len > 0) try out.put(memory, "dispositivos", devices);
    return .{ .object = out };
}

/// (sprint.json, arquivos das asas) → o projeto (`join` de `store.py`): as asas guardadas, os conjuntos e os aviões
/// na ordem gravada e, depois, os dos arquivos copiados para a pasta
fn join(memory: std.mem.Allocator, main: Value, files: []const File) !Value {
    var root: ObjectMap = .empty;
    if (main == .object) {
        var iterator = main.object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "format") or std.mem.eql(u8, key, "version") or std.mem.eql(u8, key, "order")) continue;
            var skip = false;
            for (split_keys) |split_key| skip = skip or std.mem.eql(u8, key, split_key);
            if (!skip) try root.put(memory, key, entry.value_ptr.*);
        }
    }
    // por arquivo: a asa, os conjuntos e os aviões
    const Lists = struct { wing: ?Value, kept: bool, sets: []Value, planes: []Value };
    const lists = try memory.alloc(Lists, files.len);
    for (files, lists) |file, *entry| {
        const object = file.value.object;
        const wing = object.get("asa");
        entry.* = .{ .wing = wing, .kept = flag(&object, "guardada", true), .sets = &.{}, .planes = &.{} };
        if (wing == null) continue;
        var sets: std.ArrayList(Value) = .empty;
        if (object.get("superficies")) |stored| if (stored == .array) for (stored.array.items) |set| try sets.append(memory, try setFrom(memory, set, wing.?));
        var planes: std.ArrayList(Value) = .empty;
        if (object.get("avioes")) |stored| if (stored == .array) for (stored.array.items) |plane| {
            if (plane != .object) continue;
            const set = if (plane.object.get("superficie_copia")) |copy| try setFrom(memory, copy, wing.?) else found: {
                const wanted = text(&plane.object, "superficie", "");
                for (sets.items) |set| if (std.mem.eql(u8, nameOf(set), wanted)) break :found set;
                var params: ObjectMap = .empty;
                try params.put(memory, "name", .{ .string = wanted });
                var bare: ObjectMap = .empty;
                try bare.put(memory, "params", .{ .object = params });
                break :found try setFrom(memory, .{ .object = bare }, wing.?);
            };
            var candidate: ObjectMap = .empty;
            try candidate.put(memory, "params", plane.object.get("params") orelse .{ .object = .empty });
            try candidate.put(memory, "set", set);
            try candidate.put(memory, "note", plane.object.get("note") orelse .{ .string = "" });
            try planes.append(memory, .{ .object = candidate });
        };
        entry.sets = sets.items;
        entry.planes = planes.items;
    }
    const order = if (main == .object) child(&main.object, "order") else null;
    const picks = [_]struct { key: []const u8, kind: enum { wings, sets, planes } }{ .{ .key = "wings", .kind = .wings }, .{ .key = "sets", .kind = .sets }, .{ .key = "aircraft", .kind = .planes } };
    for (picks) |pick| {
        const used = try memory.alloc([]bool, files.len);
        for (lists, used) |entry, *flags| {
            const count = switch (pick.kind) {
                .wings => @as(usize, if (entry.wing != null and entry.kept) 1 else 0),
                .sets => entry.sets.len,
                .planes => entry.planes.len,
            };
            flags.* = try memory.alloc(bool, count);
            @memset(flags.*, false);
        }
        const item = struct {
            fn of(entry: Lists, kind: @TypeOf(pick.kind), index: usize) Value {
                return switch (kind) {
                    .wings => entry.wing.?,
                    .sets => entry.sets[index],
                    .planes => entry.planes[index],
                };
            }
        }.of;
        var out: Array = .init(memory);
        if (order) |saved| if (saved.get(pick.key)) |refs| if (refs == .array) for (refs.array.items) |ref| {
            const file_name, const wanted: ?[]const u8 = switch (ref) {
                .string => |name| .{ name, null },
                .array => |pair| if (pair.items.len == 2 and pair.items[0] == .string and pair.items[1] == .string) .{ pair.items[0].string, pair.items[1].string } else continue,
                else => continue,
            };
            for (files, lists, used) |file, entry, flags| {
                if (!std.mem.eql(u8, file.name, file_name)) continue;
                for (flags, 0..) |*taken, index| {
                    const value = item(entry, pick.kind, index);
                    if (taken.* or (wanted != null and !std.mem.eql(u8, nameOf(value), wanted.?))) continue;
                    taken.* = true;
                    try out.append(value);
                    break;
                }
            }
        };
        for (lists, used) |entry, flags| for (flags, 0..) |*taken, index| if (!taken.*) {
            taken.* = true;
            try out.append(item(entry, pick.kind, index));
        };
        try root.put(memory, pick.key, .{ .array = out });
    }
    return .{ .object = root };
}

/// duas árvores iguais (a ordem das chaves não importa), como `to_dict(a) == to_dict(b)`
fn same(a: Value, b: Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |x| return b == .bool and b.bool == x,
        .integer, .float, .number_string => {
            const left: f64 = switch (a) {
                .integer => |x| @floatFromInt(x),
                .float => |x| x,
                else => std.fmt.parseFloat(f64, a.number_string) catch return false,
            };
            const right: f64 = switch (b) {
                .integer => |x| @floatFromInt(x),
                .float => |x| x,
                .number_string => |x| std.fmt.parseFloat(f64, x) catch return false,
                else => return false,
            };
            return left == right;
        },
        .string => |x| return b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) return false;
            for (x.items, b.array.items) |left, right| if (!same(left, right)) return false;
            return true;
        },
        .object => |x| {
            if (b != .object or b.object.count() != x.count()) return false;
            var iterator = x.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!same(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

/// o nome de arquivo de uma asa, sem os caracteres que o Windows não aceita (`file_name` de `store.py`)
fn fileName(memory: std.mem.Allocator, name: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (name) |byte| try cleaned.append(memory, if (byte < 0x20 or std.mem.indexOfScalar(u8, "\\/:*?\"<>|", byte) != null) '_' else byte);
    var stem = std.mem.trim(u8, cleaned.items, " \t\r\n");
    stem = std.mem.trimEnd(u8, stem, ".");
    if (stem.len == 0) stem = "asa";
    const reserved = std.ascii.eqlIgnoreCase(stem, "sprint") or std.ascii.eqlIgnoreCase(stem, "projeto");
    return std.fmt.allocPrint(memory, "{s}{s}.json", .{ stem, if (reserved) " (asa)" else "" });
}

const Parts = struct { main: Value, files: []File };

/// o projeto → (sprint.json, arquivos das asas) (`split` de `store.py`): um arquivo por asa diferente, com os
/// conjuntos feitos para ela e os aviões desses conjuntos
fn split(memory: std.mem.Allocator, root: Value) !Parts {
    const Group = struct { wing: Value, file: []const u8, kept: bool = false, sets: std.ArrayList(Value) = .empty, planes: std.ArrayList(Value) = .empty };
    var groups: std.ArrayList(Group) = .empty;
    const groupFor = struct {
        fn find(scratch: std.mem.Allocator, list: *std.ArrayList(Group), wing: Value) !*Group {
            for (list.items) |*group| if (std.mem.eql(u8, nameOf(group.wing), nameOf(wing)) and same(group.wing, wing)) return group;
            var file = try fileName(scratch, nameOf(wing));
            var suffix: usize = 2;
            while (taken(list.items, file)) : (suffix += 1) file = try fileName(scratch, try std.fmt.allocPrint(scratch, "{s} ({d})", .{ nameOf(wing), suffix }));
            try list.append(scratch, .{ .wing = wing, .file = file });
            return &list.items[list.items.len - 1];
        }
        fn taken(items: []const Group, file: []const u8) bool {
            for (items) |group| if (std.ascii.eqlIgnoreCase(group.file, file)) return true;
            return false;
        }
    }.find;
    const object = root.object;
    var order_wings: Array = .init(memory);
    var order_sets: Array = .init(memory);
    var order_planes: Array = .init(memory);
    const pair = struct {
        fn of(scratch: std.mem.Allocator, file: []const u8, name: []const u8) !Value {
            var items: Array = .init(scratch);
            try items.append(.{ .string = file });
            try items.append(.{ .string = name });
            return .{ .array = items };
        }
    }.of;
    if (object.get("wings")) |wings| if (wings == .array) for (wings.array.items) |wing| {
        const group = try groupFor(memory, &groups, wing);
        group.kept = true;
        try order_wings.append(.{ .string = group.file });
    };
    if (object.get("sets")) |sets| if (sets == .array) for (sets.array.items) |set| {
        if (set != .object) continue;
        const group = try groupFor(memory, &groups, set.object.get("wing") orelse continue);
        try group.sets.append(memory, set);
        try order_sets.append(try pair(memory, group.file, nameOf(set)));
    };
    if (object.get("aircraft")) |planes| if (planes == .array) for (planes.array.items) |plane| {
        if (plane != .object) continue;
        const set = plane.object.get("set") orelse continue;
        if (set != .object) continue;
        const group = try groupFor(memory, &groups, set.object.get("wing") orelse continue);
        try group.planes.append(memory, plane);
        try order_planes.append(try pair(memory, group.file, nameOf(plane)));
    };
    var main: ObjectMap = .empty;
    try main.put(memory, "format", .{ .string = kind_main });
    try main.put(memory, "version", .{ .integer = version });
    var order: ObjectMap = .empty;
    try order.put(memory, "wings", .{ .array = order_wings });
    try order.put(memory, "sets", .{ .array = order_sets });
    try order.put(memory, "aircraft", .{ .array = order_planes });
    try main.put(memory, "order", .{ .object = order });
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var skip = false;
        for (split_keys) |key| skip = skip or std.mem.eql(u8, entry.key_ptr.*, key);
        if (!skip) try main.put(memory, entry.key_ptr.*, entry.value_ptr.*);
    }
    var files: std.ArrayList(File) = .empty;
    for (groups.items) |group| {
        var planes: Array = .init(memory);
        for (group.planes.items) |plane| {
            var stored: ObjectMap = .empty;
            try stored.put(memory, "params", plane.object.get("params") orelse .{ .object = .empty });
            try stored.put(memory, "note", plane.object.get("note") orelse .{ .string = "" });
            const set = plane.object.get("set").?;
            try stored.put(memory, "superficie", .{ .string = nameOf(set) });
            var own: ?Value = null;
            for (group.sets.items) |candidate| if (std.mem.eql(u8, nameOf(candidate), nameOf(set))) {
                own = candidate;
                break;
            };
            if (own == null or !same(own.?, set)) try stored.put(memory, "superficie_copia", try setDict(memory, set));
            try planes.append(.{ .object = stored });
        }
        var sets: Array = .init(memory);
        for (group.sets.items) |set| try sets.append(try setDict(memory, set));
        var file: ObjectMap = .empty;
        try file.put(memory, "format", .{ .string = kind_wing });
        try file.put(memory, "version", .{ .integer = version });
        try file.put(memory, "nome", .{ .string = nameOf(group.wing) });
        try file.put(memory, "guardada", .{ .bool = group.kept });
        try file.put(memory, "asa", group.wing);
        try file.put(memory, "superficies", .{ .array = sets });
        try file.put(memory, "avioes", .{ .array = planes });
        try files.append(memory, .{ .name = group.file, .value = .{ .object = file } });
    }
    return .{ .main = .{ .object = main }, .files = files.items };
}

test "projeto: o .json antigo abre e grava na pasta nova" {
    const io = std.testing.io;
    var project = try open(std.testing.allocator, io, "../data/sprint/projeto_s1223.json");
    defer project.deinit();
    try std.testing.expect(project.list("aircraft").items.len > 0);
    _ = number(project.section("requirements"), "V_cruise", 15);
    _ = try split(project.memory(), project.root);
}

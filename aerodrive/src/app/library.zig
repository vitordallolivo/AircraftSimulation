//! Biblioteca de aviões: os `.json` das pastas de exemplos e de "meus aviões" (os salvos pela
//! GUI), em ordem de nome. Pasta que não existe é pulada. Arquivos que são o MESMO avião e só
//! mudam o campo (decola da mesa, pousa na plataforma — escolhas do menu Voar) aparecem uma vez.
const std = @import("std");
const storage = @import("storage.zig");
const fz = @import("../util/fuzz.zig");

pub const Group = enum {
    examples,
    mine,

    pub fn label(g: Group) [:0]const u8 {
        return switch (g) {
            .examples => "Exemplos",
            .mine => "Meus aviões",
        };
    }
};

pub const Entry = struct {
    name: [:0]const u8, // nome do arquivo sem .json, com _ virando espaço
    path: []const u8,
    group: Group,
};

pub const max_entries = 256;

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},

    pub fn deinit(l: *Library) void {
        l.arena.deinit();
    }

    pub fn find(l: *const Library, path: []const u8) ?usize {
        for (l.entries, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) return i;
        return null;
    }
};

/// procura nas pastas (a primeira pasta de exemplos que existir e a de "meus aviões")
pub fn scan(files: storage.Storage, gpa: std.mem.Allocator, examples: []const []const u8, mine: []const u8) !Library {
    var lib: Library = .{ .arena = .init(gpa) };
    errdefer lib.deinit();
    const a = lib.arena.allocator();
    var list: std.ArrayList(Entry) = .empty;
    for (examples) |dir| {
        const before = list.items.len;
        try addDir(files, a, &list, dir, .examples);
        if (list.items.len > before) break; // a mesma pasta vista de dois lugares: só uma vez
    }
    try addDir(files, a, &list, mine, .mine);
    // o mesmo avião em dois arquivos (só o campo muda): fica o de nome mais curto
    var keep: std.ArrayList(Entry) = .empty;
    var prints: std.ArrayList(u64) = .empty;
    for (list.items) |e| {
        const bytes = files.read(gpa, e.path, 16 << 20) catch {
            try keep.append(a, e);
            try prints.append(a, 0);
            continue;
        };
        defer gpa.free(bytes);
        const fp = fingerprint(gpa, bytes) orelse 0;
        var dup = false;
        if (fp != 0) for (prints.items, 0..) |q, i| if (q == fp) {
            if (e.name.len < keep.items[i].name.len) keep.items[i] = e;
            dup = true;
            break;
        };
        if (!dup) {
            try keep.append(a, e);
            try prints.append(a, fp);
        }
    }
    lib.entries = keep.items;
    return lib;
}

/// impressão digital do avião: o JSON sem o nome e sem o campo (airfield); null se não for JSON
pub fn fingerprint(gpa: std.mem.Allocator, bytes: []const u8) ?u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var v = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch return null;
    if (v != .object) return null;
    _ = v.object.orderedRemove("nome");
    if (v.object.getPtr("aeronave")) |ac| if (ac.* == .object) {
        _ = ac.object.orderedRemove("name");
        _ = ac.object.orderedRemove("airfield");
    };
    _ = v.object.orderedRemove("name");
    _ = v.object.orderedRemove("airfield");
    const txt = std.json.Stringify.valueAlloc(aa, v, .{}) catch return null;
    return std.hash.Wyhash.hash(1, txt) | 1;
}

fn addDir(files: storage.Storage, a: std.mem.Allocator, list: *std.ArrayList(Entry), dir_path: []const u8, g: Group) !void {
    var listing = files.list(a, dir_path) catch |err| return if (err == error.OutOfMemory) err else {};
    defer listing.deinit();
    const start = list.items.len;
    for (listing.entries) |e| {
        if (list.items.len >= max_entries) break;
        if (e.kind != .file) continue;
        const name = entryName(a, e.name) catch continue orelse continue;
        try list.append(a, .{ .name = name, .path = try std.fs.path.join(a, &.{ dir_path, e.name }), .group = g });
    }
    std.mem.sort(Entry, list.items[start..], {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
}

/// nome de arquivo para guardar um .json que veio de fora: só o nome (sem pastas), letras,
/// números, espaço, ponto, _ e -; sempre termina em ".json" ("../x/Meu avião!.JSON" → "Meu avi_o_.json")
pub fn safeFileName(buf: *[96]u8, file_name: []const u8) []const u8 {
    const base = std.fs.path.basename(file_name);
    const stem = if (std.ascii.endsWithIgnoreCase(base, ".json")) base[0 .. base.len - 5] else base;
    var len: usize = 0;
    for (stem) |char| {
        if (len >= buf.len - 5) break;
        const keep = std.ascii.isAlphanumeric(char) or char == ' ' or char == '_' or char == '-' or (char == '.' and len > 0);
        buf[len] = if (keep) char else '_';
        len += 1;
    }
    if (len == 0) {
        @memcpy(buf[0..5], "aviao");
        len = 5;
    }
    @memcpy(buf[len .. len + 5], ".json");
    return buf[0 .. len + 5];
}

/// "Asa_voadora.json" → "Asa voadora"; outro tipo de arquivo → null
pub fn entryName(a: std.mem.Allocator, file: []const u8) !?[:0]u8 {
    if (file.len <= 5 or !std.ascii.endsWithIgnoreCase(file, ".json") or file[0] == '.') return null;
    const stem = file[0 .. file.len - 5];
    const out = try a.allocSentinel(u8, stem.len, 0);
    for (stem, 0..) |c, i| out[i] = if (c == '_' or c == 0) ' ' else c;
    return out;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "acha os exemplos do repositório em ordem" {
    var disk: storage.DiskStorage = .{ .io = testing.io };
    var lib = try scan(disk.storage(), testing.allocator, &.{ "../data/aircraft", "data/aircraft" }, "/nao/existe");
    defer lib.deinit();
    try testing.expect(lib.entries.len >= 3);
    for (lib.entries[1..], lib.entries[0 .. lib.entries.len - 1]) |b, a| try testing.expect(!std.ascii.lessThanIgnoreCase(b.name, a.name));
    try testing.expect(lib.find("../data/aircraft/Asa_voadora.json") != null);
    // "decola da mesa, pousa na plataforma" é o Convencional: aparece uma vez só
    try testing.expect(lib.find("../data/aircraft/Convencional_original.json") != null);
    try testing.expect(lib.find("../data/aircraft/Convencional_decola_da_mesa_pousa_na_plataforma.json") == null);
}

test "impressão digital ignora nome e campo" {
    const a = "{\"nome\":\"A\",\"aeronave\":{\"name\":\"A\",\"x\":1,\"airfield\":{\"takeoff_from\":\"chão\"}}}";
    const b = "{\"nome\":\"B\",\"aeronave\":{\"name\":\"B\",\"x\":1,\"airfield\":{\"takeoff_from\":\"mesa\"}}}";
    const c = "{\"aeronave\":{\"x\":2}}";
    try testing.expectEqual(fingerprint(testing.allocator, a).?, fingerprint(testing.allocator, b).?);
    try testing.expect(fingerprint(testing.allocator, a).? != fingerprint(testing.allocator, c).?);
    try testing.expect(fingerprint(testing.allocator, "não é json") == null);
}

test "nome seguro para o .json que veio de fora" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("Asa voadora.json", safeFileName(&buf, "Asa voadora.json"));
    try testing.expectEqualStrings("Meu avi__o_.json", safeFileName(&buf, "../x/Meu avião!.JSON"));
    try testing.expectEqualStrings("aviao.json", safeFileName(&buf, ""));
    try testing.expectEqualStrings("_x.json", safeFileName(&buf, ".x"));
}

fn fuzzSafeName(_: void, source: *fz.Src) anyerror!void {
    var input: [200]u8 = undefined;
    var buf: [96]u8 = undefined;
    const name = safeFileName(&buf, input[0..source.bytes(&input)]);
    try testing.expect(std.mem.endsWith(u8, name, ".json") and name.len > 5 and name[0] != '.');
    for (name) |char| try testing.expect(char != '/' and char != '\\' and char != 0);
}

test "fuzz: nome seguro" {
    try fz.check({}, fuzzSafeName, .{});
}

fn fuzzName(_: void, src: *fz.Src) anyerror!void {
    var buf: [64]u8 = undefined;
    const n = src.bytes(&buf);
    if (src.boolean() and n + 5 <= buf.len) @memcpy(buf[n .. n + 5], ".json");
    const name = buf[0 .. if (n + 5 <= buf.len) n + 5 else n];
    const r = try entryName(testing.allocator, name);
    if (r) |s| {
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOfScalar(u8, s, 0) == null and s.len + 5 == name.len);
    }
}

test "fuzz: nomes de arquivo" {
    try fz.check({}, fuzzName, .{});
}

fn fuzzPrint(_: void, src: *fz.Src) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = src.bytes(&buf);
    if (src.boolean()) for (buf[0..n]) |*c| {
        c.* = "{}[]:,\"aeronvm 01"[c.* % 17];
    };
    _ = fingerprint(testing.allocator, buf[0..n]);
}

test "fuzz: impressão digital" {
    try fz.check({}, fuzzPrint, .{});
}

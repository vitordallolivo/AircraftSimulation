//! Biblioteca de aviões: os `.json` das pastas de exemplos e de "meus aviões" (os salvos pela
//! GUI), em ordem de nome. Pasta que não existe é pulada; nada aqui abre os arquivos.
const std = @import("std");
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
pub fn scan(io: std.Io, gpa: std.mem.Allocator, examples: []const []const u8, mine: []const u8) !Library {
    var lib: Library = .{ .arena = .init(gpa) };
    errdefer lib.deinit();
    const a = lib.arena.allocator();
    var list: std.ArrayList(Entry) = .empty;
    for (examples) |dir| {
        const before = list.items.len;
        try addDir(io, a, &list, dir, .examples);
        if (list.items.len > before) break; // a mesma pasta vista de dois lugares: só uma vez
    }
    try addDir(io, a, &list, mine, .mine);
    lib.entries = list.items;
    return lib;
}

fn addDir(io: std.Io, a: std.mem.Allocator, list: *std.ArrayList(Entry), dir_path: []const u8, g: Group) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const start = list.items.len;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (list.items.len >= max_entries) break;
        if (e.kind != .file and e.kind != .sym_link) continue;
        const name = entryName(a, e.name) catch continue orelse continue;
        try list.append(a, .{ .name = name, .path = try std.fs.path.join(a, &.{ dir_path, e.name }), .group = g });
    }
    std.mem.sort(Entry, list.items[start..], {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
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
    var lib = try scan(testing.io, testing.allocator, &.{ "../data/aircraft", "data/aircraft" }, "/nao/existe");
    defer lib.deinit();
    try testing.expect(lib.entries.len >= 3);
    for (lib.entries[1..], lib.entries[0 .. lib.entries.len - 1]) |b, a| try testing.expect(!std.ascii.lessThanIgnoreCase(b.name, a.name));
    try testing.expect(lib.find("../data/aircraft/Asa_voadora.json") != null);
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

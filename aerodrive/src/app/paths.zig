//! Onde ficam as coisas no disco, a partir das variáveis de ambiente:
//!   config      $XDG_CONFIG_HOME/aerodrive/config.json (ou ~/.config/…, ou %APPDATA%\aerodrive\…)
//!   aviões      …/aerodrive/avioes/<avião>-<hash>.json (o que cada avião lembra)
//!   voos        $AERODRIVE_VOOS, ou ~/aerodrive_voos (gravações: vídeo + dados)
//!   meus aviões $AEROSIM_PROJETOS, ou ~/aerosim_aeronaves (os da GUI)
//!   exemplos    ../data/aircraft e data/aircraft (rodando de aerodrive/ ou da raiz)
//! No navegador os caminhos são fixos (`browser`): o que o jogo grava fica em /aerodrive (guardado no
//! IndexedDB) e os exemplos vêm no pacote, em /data/aircraft.
const std = @import("std");
const fz = @import("../util/fuzz.zig");

pub const Paths = struct {
    config: []const u8,
    planes: []const u8, // configurações por avião (ao lado do config: …/aerodrive/avioes)
    recordings: []const u8,
    mine: []const u8,
    examples: [2][]const u8 = .{ "../data/aircraft", "data/aircraft" },
};

/// no navegador: /aerodrive persiste (IndexedDB); os aviões abertos do computador vão para
/// /aerodrive/meus_avioes
pub const browser: Paths = .{
    .config = "/aerodrive/config.json",
    .planes = "/aerodrive/avioes",
    .recordings = "/aerodrive/voos",
    .mine = "/aerodrive/meus_avioes",
    .examples = .{ "/data/aircraft", "/data/aircraft" },
};

/// `get(nome)` lê uma variável de ambiente (null = não existe); `a` guarda os textos
pub fn resolve(a: std.mem.Allocator, env: anytype) !Paths {
    const home = nonEmpty(env.get("HOME")) orelse nonEmpty(env.get("USERPROFILE")) orelse ".";
    const config = if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |x|
        try std.fs.path.join(a, &.{ x, "aerodrive", "config.json" })
    else if (nonEmpty(env.get("APPDATA"))) |x|
        try std.fs.path.join(a, &.{ x, "aerodrive", "config.json" })
    else
        try std.fs.path.join(a, &.{ home, ".config", "aerodrive", "config.json" });
    const rec = if (nonEmpty(env.get("AERODRIVE_VOOS"))) |x| try a.dupe(u8, x) else try std.fs.path.join(a, &.{ home, "aerodrive_voos" });
    const mine = if (nonEmpty(env.get("AEROSIM_PROJETOS"))) |x| try a.dupe(u8, x) else try std.fs.path.join(a, &.{ home, "aerosim_aeronaves" });
    const planes = try std.fs.path.join(a, &.{ std.fs.path.dirname(config) orelse ".", "avioes" });
    return .{ .config = config, .planes = planes, .recordings = rec, .mine = mine };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

const FakeEnv = struct {
    kv: []const [2][]const u8,
    pub fn get(e: FakeEnv, k: []const u8) ?[]const u8 {
        for (e.kv) |p| if (std.mem.eql(u8, p[0], k)) return p[1];
        return null;
    }
};

test "HOME, XDG e variáveis do projeto" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try resolve(arena.allocator(), FakeEnv{ .kv = &.{ .{ "HOME", "/h" }, .{ "AEROSIM_PROJETOS", "/proj" } } });
    try testing.expectEqualStrings("/h/.config/aerodrive/config.json", p.config);
    try testing.expectEqualStrings("/h/.config/aerodrive/avioes", p.planes);
    try testing.expectEqualStrings("/h/aerodrive_voos", p.recordings);
    try testing.expectEqualStrings("/proj", p.mine);
    const q = try resolve(arena.allocator(), FakeEnv{ .kv = &.{.{ "XDG_CONFIG_HOME", "/x" }} });
    try testing.expectEqualStrings("/x/aerodrive/config.json", q.config);
    try testing.expectEqualStrings("./aerodrive_voos", q.recordings);
}

fn fuzzResolve(_: void, src: *fz.Src) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = [_][]const u8{ "HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA", "AERODRIVE_VOOS", "AEROSIM_PROJETOS" };
    var vals: [6][64]u8 = undefined;
    var kv: [6][2][]const u8 = undefined;
    var n: usize = 0;
    for (names, 0..) |k, i| if (src.boolean()) {
        kv[n] = .{ k, vals[i][0..src.bytes(&vals[i])] };
        n += 1;
    };
    const p = try resolve(arena.allocator(), FakeEnv{ .kv = kv[0..n] });
    try testing.expect(p.config.len > 0 and p.recordings.len > 0 and p.mine.len > 0);
}

test "fuzz: caminhos" {
    try fz.check({}, fuzzResolve, .{});
}

//! Configurações de cada avião, lembradas por arquivo: a sessão (chão/mesa, pouso, quem pilota,
//! vento, sloshing, LAPES, mesa) sempre; o controle (curvas, entradas, botões) e a câmera só se o
//! jogador quiser que aquele avião tenha os seus (senão valem os gerais).
//!
//!   var cfg = PlaneSettings.load(store, gpa, caminho, padrão);   // avião novo: começa do padrão
//!   cfg.save(store, gpa, caminho);
const std = @import("std");
const session = @import("../sim/session.zig");
const ch = @import("../input/channels.zig");
const settings = @import("settings.zig");
const store_mod = @import("store.zig");
const fz = @import("../util/fuzz.zig");

pub const PlaneSettings = struct {
    session: session.Session = .{},
    own_controls: bool = false, // este avião tem curvas/entradas/botões próprios
    profile: ch.Profile = .{},
    own_camera: bool = false,
    camera: settings.CameraSettings = .{},

    pub fn sanitize(p: *PlaneSettings) void {
        p.session.sanitize();
        p.camera.sanitize();
        settings.sanitizeProfile(&p.profile);
    }

    /// o que está guardado para o avião em `path`; sem nada guardado, `fallback` (o último usado)
    pub fn load(st: store_mod.Store, gpa: std.mem.Allocator, path: []const u8, fallback: PlaneSettings) PlaneSettings {
        var kb: [64]u8 = undefined;
        var p = st.loadJson(PlaneSettings, gpa, store_mod.keyFor(&kb, path)) orelse fallback;
        p.sanitize();
        return p;
    }

    pub fn save(p: *const PlaneSettings, st: store_mod.Store, gpa: std.mem.Allocator, path: []const u8) bool {
        var kb: [64]u8 = undefined;
        return st.saveJson(gpa, store_mod.keyFor(&kb, path), p.*);
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "cada avião lembra a sua sessão; avião novo começa do padrão" {
    var m: store_mod.MemStore = .{ .gpa = testing.allocator };
    defer m.deinit();
    const st = m.store();
    var a: PlaneSettings = .{};
    a.session.scenario = .table;
    a.session.wind_speed = 7;
    a.own_controls = true;
    a.profile.applyScheme(.radio2);
    try testing.expect(a.save(st, testing.allocator, "../data/aircraft/Asa_voadora.json"));
    const r = PlaneSettings.load(st, testing.allocator, "../data/aircraft/Asa_voadora.json", .{});
    try testing.expect(r.session.scenario == .table and r.session.wind_speed == 7);
    try testing.expect(r.own_controls and r.profile.scheme == .radio2 and r.profile.src_thr == .ly);
    var dflt: PlaneSettings = .{};
    dflt.session.wind_speed = 2;
    const n = PlaneSettings.load(st, testing.allocator, "../data/aircraft/Outro.json", dflt);
    try testing.expectEqual(@as(f64, 2), n.session.wind_speed);
}

fn fuzzPlane(_: void, src: *fz.Src) anyerror!void {
    var m: store_mod.MemStore = .{ .gpa = testing.allocator };
    defer m.deinit();
    const st = m.store();
    var kb: [64]u8 = undefined;
    var buf: [400]u8 = undefined;
    const path = "x/aviao.json";
    var tb: [400]u8 = undefined;
    const text = if (src.boolean()) buf[0..src.bytes(&buf)] else std.fmt.bufPrint(&tb, "{{\"session\":{{\"wind_speed\":{d},\"table_height\":{d}}},\"camera\":{{\"fov\":{d}}},\"profile\":{{\"de_max\":{d}}}}}", .{ src.range(-1e6, 1e6), src.range(-1e3, 1e3), src.range(-1e3, 1e3), src.range(-50, 50) }) catch unreachable;
    _ = st.save(store_mod.keyFor(&kb, path), text);
    const p = PlaneSettings.load(st, testing.allocator, path, .{});
    try testing.expect(p.session.wind_speed >= 0 and p.session.wind_speed <= 20);
    try testing.expect(p.camera.fov >= 25 and p.camera.fov <= 100);
    try testing.expect(p.profile.de_max > 0 and p.profile.de_max < 1);
}

test "fuzz: configurações por avião" {
    try fz.check({}, fuzzPlane, .{});
}

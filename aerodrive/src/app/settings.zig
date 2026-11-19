//! Configurações do jogador, guardadas entre uma vez e outra: avião escolhido, sessão (cenário,
//! modo, vento, sloshing, LAPES), curvas do controle, câmera, som e quadros por segundo.
//! Arquivo `.aerocfg` em ZON (`paths.config`; o `config.json` antigo ainda é lido); arquivo ausente, quebrado ou
//! com valores absurdos = padrões.
const std = @import("std");
const session = @import("../sim/session.zig");
const ch = @import("../input/channels.zig");
const storage = @import("storage.zig");
const store_mod = @import("store.zig");
const fz = @import("../util/fuzz.zig");

pub const CameraKind = enum { chase, ground, orbit };

pub const CameraSettings = struct {
    start: CameraKind = .chase,
    chase_distance: f64 = 3.5, // × envergadura, atrás
    chase_height: f64 = 0.8, // × envergadura, acima
    fov: f64 = 55, // graus

    pub fn sanitize(c: *CameraSettings) void {
        c.chase_distance = fix(c.chase_distance, 0.8, 15, 3.5);
        c.chase_height = fix(c.chase_height, -0.5, 5, 0.8);
        c.fov = fix(c.fov, 25, 100, 55);
    }
};

pub const max_path = 1024;

pub const Settings = struct {
    aircraft_buf: [max_path]u8 = undefined,
    aircraft_len: usize = 0,
    session: session.Session = .{},
    profile: ch.Profile = .{},
    camera: CameraSettings = .{},
    volume: f64 = 0.7, // 0..1
    fps: u32 = 60,
    dev_overlay: bool = false,
    fullscreen: bool = false,

    pub fn aircraft(s: *const Settings) []const u8 {
        return s.aircraft_buf[0..s.aircraft_len];
    }

    pub fn setAircraft(s: *Settings, path: []const u8) void {
        const n = @min(path.len, max_path);
        // `path` pode ser o próprio `aircraft()` (reabrir o último avião): cópia que aceita sobreposição
        std.mem.copyForwards(u8, s.aircraft_buf[0..n], path[0..n]);
        s.aircraft_len = n;
    }

    pub fn sanitize(s: *Settings) void {
        s.session.sanitize();
        s.camera.sanitize();
        s.volume = fix(s.volume, 0, 1, 0.7);
        if (s.fps != 30 and s.fps != 60) s.fps = 60;
        sanitizeProfile(&s.profile);
    }

    /// o texto do arquivo (ZON, ou o JSON antigo) → configurações (o que faltar fica no padrão; texto quebrado = erro)
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Settings {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const d = store_mod.decode(Disk, arena.allocator(), bytes) catch return error.BadSettings;
        var s: Settings = .{ .session = d.session, .profile = d.profile, .camera = d.camera, .volume = d.volume, .fps = d.fps, .dev_overlay = d.dev_overlay, .fullscreen = d.fullscreen };
        s.setAircraft(d.aircraft);
        s.sanitize();
        return s;
    }

    /// configurações → o texto do arquivo, em ZON (o chamador libera)
    pub fn toText(s: *const Settings, gpa: std.mem.Allocator) ![]u8 {
        const d: Disk = .{ .aircraft = s.aircraft(), .session = s.session, .profile = s.profile, .camera = s.camera, .volume = s.volume, .fps = s.fps, .dev_overlay = s.dev_overlay, .fullscreen = s.fullscreen };
        return store_mod.encode(gpa, d);
    }

    /// lê de `files` (ausente ou quebrado = padrões); sem o `.aerocfg`, lê o `config.json` antigo da mesma pasta
    pub fn load(files: storage.Storage, gpa: std.mem.Allocator, path: []const u8) Settings {
        var legacy_buf: [1200]u8 = undefined;
        const legacy = std.fmt.bufPrint(&legacy_buf, "{s}/config.json", .{std.fs.path.dirname(path) orelse "."}) catch path;
        const bytes = files.read(gpa, path, 1 << 20) catch files.read(gpa, legacy, 1 << 20) catch return .{};
        defer gpa.free(bytes);
        return parse(gpa, bytes) catch .{};
    }

    /// grava (cria a pasta); falha calada — perder a configuração não pode parar o jogo
    pub fn save(s: *const Settings, files: storage.Storage, gpa: std.mem.Allocator, path: []const u8) void {
        const text = s.toText(gpa) catch return;
        defer gpa.free(text);
        files.write(path, text) catch {};
    }
};

/// o formato do arquivo (o caminho do avião como texto)
const Disk = struct {
    aircraft: []const u8 = "",
    session: session.Session = .{},
    profile: ch.Profile = .{},
    camera: CameraSettings = .{},
    volume: f64 = 0.7,
    fps: u32 = 60,
    dev_overlay: bool = false,
    fullscreen: bool = false,
};

fn fix(v: f64, lo: f64, hi: f64, d: f64) f64 {
    return if (std.math.isFinite(v)) std.math.clamp(v, lo, hi) else d;
}

fn sanitizeCurve(k: *ch.Curve) void {
    k.deadzone = fix(k.deadzone, 0, 0.5, 0.05);
    k.expo = fix(k.expo, 0, 1, 0.3);
    k.rate = fix(k.rate, 0.05, 1, 1);
    k.trim = fix(k.trim, -0.25, 0.25, 0);
}

pub fn sanitizeProfile(p: *ch.Profile) void {
    inline for (.{ "elevator", "aileron", "rudder", "throttle" }) |f| sanitizeCurve(&@field(p, f));
    const lim = std.math.degreesToRadians(45.0);
    p.de_max = fix(p.de_max, 0.01, lim, std.math.degreesToRadians(20.0));
    p.da_max = fix(p.da_max, 0.01, lim, std.math.degreesToRadians(20.0));
    p.dr_max = fix(p.dr_max, 0.01, lim, std.math.degreesToRadians(25.0));
    p.button_rate = fix(p.button_rate, 0.2, 20, 4);
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "reabrir o último avião: o caminho vem do próprio buffer" {
    var s: Settings = .{};
    s.setAircraft("../data/aircraft/Asa_voadora.aero");
    s.setAircraft(s.aircraft());
    try testing.expectEqualStrings("../data/aircraft/Asa_voadora.aero", s.aircraft());
    s.setAircraft(s.aircraft()[3..]);
    try testing.expectEqualStrings("data/aircraft/Asa_voadora.aero", s.aircraft());
}

test "ida e volta pelo .aerocfg; o JSON antigo ainda lê; campos faltando ficam no padrão" {
    var s: Settings = .{ .volume = 0.3, .fps = 30 };
    s.setAircraft("../data/aircraft/Asa_voadora.aero");
    s.session.scenario = .table;
    s.profile.elevator.expo = 0.6;
    s.camera.chase_distance = 5;
    const j = try s.toText(testing.allocator);
    defer testing.allocator.free(j);
    const r = try Settings.parse(testing.allocator, j);
    try testing.expectEqualStrings("../data/aircraft/Asa_voadora.aero", r.aircraft());
    try testing.expectEqual(session.Scenario.table, r.session.scenario);
    try testing.expectEqual(@as(f64, 0.6), r.profile.elevator.expo);
    try testing.expectEqual(@as(f64, 5), r.camera.chase_distance);
    try testing.expectEqual(@as(u32, 30), r.fps);
    const p = try Settings.parse(testing.allocator, "{\"volume\": 7, \"fps\": 144, \"outra\": 1}");
    try testing.expectEqual(@as(f64, 1), p.volume);
    try testing.expectEqual(@as(u32, 60), p.fps);
    try testing.expectError(error.BadSettings, Settings.parse(testing.allocator, "{volume"));
    const zon = try Settings.parse(testing.allocator, ".{ .volume = 7, .fps = 30, .outra = 1 }");
    try testing.expectEqual(@as(f64, 1), zon.volume);
    try testing.expectEqual(@as(u32, 30), zon.fps);
}

test "sem o .aerocfg, lê o config.json antigo da mesma pasta; gravar cria o .aerocfg" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var disk: storage.DiskStorage = .{ .io = testing.io };
    const files = disk.storage();
    var path_buf: [600]u8 = undefined;
    try files.write(try std.fmt.bufPrint(&path_buf, "{s}/config.json", .{root}), "{\"volume\": 0.2, \"fps\": 30}");
    const path = try std.fmt.bufPrint(&path_buf, "{s}/aerodrive.aerocfg", .{root});
    const old = Settings.load(files, testing.allocator, path);
    try testing.expectEqual(@as(f64, 0.2), old.volume);
    old.save(files, testing.allocator, path);
    const again = Settings.load(files, testing.allocator, path);
    try testing.expectEqual(@as(u32, 30), again.fps);
}

fn fuzzParse(_: void, src: *fz.Src) anyerror!void {
    // bytes quaisquer, ou JSON válido com números quaisquer: nunca trava, sempre dentro das faixas
    var buf: [512]u8 = undefined;
    var text: []const u8 = undefined;
    var tbuf: [512]u8 = undefined;
    if (src.boolean()) {
        text = buf[0..src.bytes(&buf)];
    } else {
        text = std.fmt.bufPrint(&tbuf, "{{\"volume\":{d},\"camera\":{{\"fov\":{d},\"chase_distance\":{d}}},\"profile\":{{\"elevator\":{{\"expo\":{d}}}}},\"session\":{{\"wind_from\":{d}}}}}", .{ src.range(-1e9, 1e9), src.range(-1e3, 1e3), src.range(-50, 50), src.range(-5, 5), src.range(-1e6, 1e6) }) catch unreachable;
    }
    const s = Settings.parse(testing.allocator, text) catch |e| {
        try testing.expect(e == error.BadSettings);
        return;
    };
    try testing.expect(s.volume >= 0 and s.volume <= 1);
    try testing.expect(s.camera.fov >= 25 and s.camera.fov <= 100);
    try testing.expect(s.profile.elevator.expo >= 0 and s.profile.elevator.expo <= 1);
    try testing.expect(s.session.wind_from >= 0 and s.session.wind_from < 360);
}

test "fuzz: configurações" {
    try fz.check({}, fuzzParse, .{});
}

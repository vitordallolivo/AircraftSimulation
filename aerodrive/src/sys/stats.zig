//! Números do painel de desenvolvedor (F3): memória (RAM residente) e uso de CPU do processo.
//! Linux: lê /proc/self/statm e /proc/self/stat; outros sistemas: "—". As leituras de texto são
//! funções puras (testadas com lixo); `Sampler` mede a cada meio segundo.
const std = @import("std");
const builtin = @import("builtin");
const fz = @import("../util/fuzz.zig");

/// /proc/self/statm: "tamanho residente compartilhado ..." (em páginas) → bytes residentes
pub fn parseStatm(text: []const u8, page: u64) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " \n\t");
    _ = it.next() orelse return null;
    const res = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return std.math.mul(u64, res, page) catch null;
}

/// /proc/self/stat → utime + stime (tiques). O nome do processo vem entre parênteses e pode ter
/// espaços: conta os campos depois do último ')'. utime e stime são os campos 14 e 15.
pub fn parseStatTicks(text: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, text[close + 1 ..], " \n\t");
    var i: usize = 3; // o primeiro campo depois do ')' é o 3 (estado)
    var ut: ?u64 = null;
    while (it.next()) |tok| : (i += 1) {
        if (i == 14) ut = std.fmt.parseInt(u64, tok, 10) catch return null;
        if (i == 15) {
            const st = std.fmt.parseInt(u64, tok, 10) catch return null;
            return std.math.add(u64, ut orelse return null, st) catch null;
        }
    }
    return null;
}

pub const Sample = struct {
    ram_bytes: ?u64 = null,
    cpu_percent: ?f64 = null, // de um núcleo (100 % = um núcleo inteiro)
};

pub const Sampler = struct {
    last_ticks: ?u64 = null,
    since: f64 = 0,
    sample: Sample = .{},
    ticks_per_s: f64 = 100, // USER_HZ (100 no Linux)

    /// chame todo quadro com o tempo real do quadro
    pub fn update(s: *Sampler, io: std.Io, dt: f64) void {
        if (builtin.os.tag != .linux) return;
        s.since += if (std.math.isFinite(dt) and dt > 0) dt else 0;
        if (s.since < 0.5 and s.last_ticks != null) return;
        var buf: [1024]u8 = undefined;
        if (readSmall(io, "/proc/self/statm", &buf)) |t| s.sample.ram_bytes = parseStatm(t, 4096);
        if (readSmall(io, "/proc/self/stat", &buf)) |t| if (parseStatTicks(t)) |ticks| {
            if (s.last_ticks) |prev| if (s.since > 0 and ticks >= prev) {
                s.sample.cpu_percent = 100 * @as(f64, @floatFromInt(ticks - prev)) / s.ticks_per_s / s.since;
            };
            s.last_ticks = ticks;
        };
        s.since = 0;
    }
};

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "statm e stat (nome com espaço e parênteses)" {
    try testing.expectEqual(@as(?u64, 2 * 4096), parseStatm("10 2 1 0 0 0 0\n", 4096));
    const stat = "1234 (meu (prog) x) S 1 1234 1234 0 -1 4194560 100 0 0 0 37 5 0 0 20 0 1 0";
    try testing.expectEqual(@as(?u64, 42), parseStatTicks(stat));
    try testing.expectEqual(@as(?u64, null), parseStatTicks("1 (x) S 1 2"));
}

fn fuzzParse(_: void, src: *fz.Src) anyerror!void {
    var buf: [256]u8 = undefined;
    const t = buf[0..src.bytes(&buf)];
    _ = parseStatm(t, src.int(u64, 0, std.math.maxInt(u64)));
    _ = parseStatTicks(t);
}

test "fuzz: leitura do /proc" {
    try fz.check({}, fuzzParse, .{});
}

//! Assistir um .mp4 gravado dentro do jogo: o `ffprobe` diz o tamanho, a taxa e a duração; o
//! `ffmpeg` decodifica e manda os quadros (RGBA, já no tamanho pedido) por um cano. Pular para um
//! instante = abrir o ffmpeg de novo a partir dali (`-ss`). Quem desenha é a tela (textura).
//!
//!   const info = try video_player.probe(io, gpa, "voo/video.mp4");
//!   var d = try Decoder.start(io, gpa, "voo/video.mp4", info, 0, 960);
//!   while (try d.next(io)) { usar d.frame (d.w × d.h × 4) }
//!   d.stop(io);
const std = @import("std");
const fz = @import("../util/fuzz.zig");

pub const Info = struct { w: u32, h: u32, fps: f64, duration: f64 };

/// saída do ffprobe "largura,altura,num/den,duração" (uma linha) → Info
pub fn parseProbe(text: []const u8) ?Info {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \r\n\t"), ',');
    const w = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const rate = it.next() orelse return null;
    var r = std.mem.splitScalar(u8, rate, '/');
    const num = std.fmt.parseFloat(f64, r.next() orelse return null) catch return null;
    const den = std.fmt.parseFloat(f64, r.next() orelse "1") catch return null;
    const dur = std.fmt.parseFloat(f64, std.mem.trim(u8, it.next() orelse "0", " \r\n")) catch 0;
    if (w < 2 or h < 2 or w > 8192 or h > 8192 or !(den > 0)) return null;
    const fps = num / den;
    if (!(fps > 0.5 and fps <= 240)) return null;
    return .{ .w = w, .h = h, .fps = fps, .duration = if (std.math.isFinite(dur) and dur > 0) dur else 0 };
}

/// tamanho de saída: largura `max_w` (par), altura na mesma proporção (par)
pub fn outSize(info: Info, max_w: u32) [2]u32 {
    const w0 = @max(@min(info.w, @max(max_w, 2)), 2) & ~@as(u32, 1);
    const hf = @as(f64, @floatFromInt(info.h)) * @as(f64, @floatFromInt(w0)) / @as(f64, @floatFromInt(@max(info.w, 1)));
    const h0: u32 = @intFromFloat(std.math.clamp(@round(hf / 2) * 2, 2, 8192));
    return .{ w0, h0 };
}

pub fn probe(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Info {
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate:format=duration", "-of", "csv=p=0:s=,", path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |e| return if (e == error.FileNotFound) error.NoFfmpeg else e;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    // ffprobe põe o stream numa linha e a duração (format) na outra: junta
    var joined: [256]u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.tokenizeAny(u8, r.stdout, "\r\n");
    while (lines.next()) |l| {
        if (n > 0 and n < joined.len) {
            joined[n] = ',';
            n += 1;
        }
        const k = @min(l.len, joined.len - n);
        @memcpy(joined[n .. n + k], l[0..k]);
        n += k;
    }
    return parseProbe(joined[0..n]) orelse error.BadVideo;
}

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    child: std.process.Child,
    w: u32,
    h: u32,
    frame: []u8,
    rbuf: []u8,
    reader: std.Io.File.Reader,
    t: f64, // instante do quadro em `frame` (s)
    dt: f64, // 1 / fps
    ended: bool = false,

    /// abre o ffmpeg a partir de `start_s` segundos, saída com largura `max_w`
    pub fn start(io: std.Io, gpa: std.mem.Allocator, path: []const u8, info: Info, start_s: f64, max_w: u32) !Decoder {
        const sz = outSize(info, max_w);
        var ss: [32]u8 = undefined;
        var vf: [48]u8 = undefined;
        const t0 = if (std.math.isFinite(start_s)) std.math.clamp(start_s, 0, @max(info.duration, 0)) else 0;
        const argv = [_][]const u8{
            "ffmpeg",                                                 "-loglevel", "error",
            "-ss",                                                    try std.fmt.bufPrint(&ss, "{d:.3}", .{t0}),
            "-i",                                                     path,
            "-vf",                                                    try std.fmt.bufPrint(&vf, "scale={d}:{d}", .{ sz[0], sz[1] }),
            "-f",                                                     "rawvideo",
            "-pix_fmt",                                               "rgba",
            "-",
        };
        var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch |e| return if (e == error.FileNotFound) error.NoFfmpeg else e;
        errdefer child.kill(io);
        const frame = try gpa.alloc(u8, @as(usize, sz[0]) * sz[1] * 4);
        errdefer gpa.free(frame);
        const rbuf = try gpa.alloc(u8, 1 << 16);
        return .{ .gpa = gpa, .child = child, .w = sz[0], .h = sz[1], .frame = frame, .rbuf = rbuf, .reader = child.stdout.?.readerStreaming(io, rbuf), .t = t0 - 1 / info.fps, .dt = 1 / info.fps };
    }

    /// lê o próximo quadro; false no fim do vídeo
    pub fn next(d: *Decoder) bool {
        if (d.ended) return false;
        d.reader.interface.readSliceAll(d.frame) catch {
            d.ended = true;
            return false;
        };
        d.t += d.dt;
        return true;
    }

    pub fn stop(d: *Decoder, io: std.Io) void {
        // fecha o cano antes: o ffmpeg parado escrevendo num cano cheio sai na hora (sem trava)
        if (d.child.stdout) |f| f.close(io);
        d.child.stdout = null;
        d.child.kill(io);
        d.gpa.free(d.frame);
        d.gpa.free(d.rbuf);
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "lê o ffprobe e escolhe o tamanho" {
    const i = parseProbe("1280,720,30/1,2.000000\n").?;
    try testing.expectEqual(@as(u32, 1280), i.w);
    try testing.expectApproxEqAbs(@as(f64, 30), i.fps, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2), i.duration, 1e-9);
    const s = outSize(i, 960);
    try testing.expectEqual(@as(u32, 960), s[0]);
    try testing.expectEqual(@as(u32, 540), s[1]);
    try testing.expect(parseProbe("lixo") == null);
    try testing.expect(parseProbe("10,10,0/0,1") == null);
}

test "grava um mp4 curto e assiste (se houver ffmpeg)" {
    const video = @import("video.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var pb: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/v.mp4", .{root});
    var v = video.Video.start(testing.io, path, 64, 48, 30) catch |e| {
        if (e == error.NoFfmpeg) return error.SkipZigTest;
        return e;
    };
    var px: [64 * 48 * 4]u8 = undefined;
    for (0..30) |k| {
        @memset(&px, @truncate(k * 8));
        try v.frame(testing.io, &px, 64, 48);
    }
    try testing.expect(v.finish(testing.io));
    const info = probe(testing.io, testing.allocator, path) catch |e| {
        if (e == error.NoFfmpeg) return error.SkipZigTest;
        return e;
    };
    try testing.expectEqual(@as(u32, 64), info.w);
    var d = try Decoder.start(testing.io, testing.allocator, path, info, 0.5, 32);
    defer d.stop(testing.io);
    var n: usize = 0;
    while (d.next()) n += 1;
    try testing.expect(n >= 10 and n <= 20); // ~0,5 s de 1 s a 30 quadros por segundo
    try testing.expectEqual(@as(u32, 32), d.w);
    // parar no meio (ffmpeg ainda escrevendo) não trava
    var d2 = try Decoder.start(testing.io, testing.allocator, path, info, 0, 64);
    _ = d2.next();
    d2.stop(testing.io);
}

fn fuzzProbe(_: void, src: *fz.Src) anyerror!void {
    var b: [64]u8 = undefined;
    const n = src.bytes(&b);
    if (src.boolean()) for (b[0..n]) |*c| {
        c.* = "0123456789,/.\n-e"[c.* % 16];
    };
    if (parseProbe(b[0..n])) |i| {
        const s = outSize(i, src.int(u32, 0, 9000));
        try testing.expect(s[0] >= 2 and s[1] >= 2 and s[0] % 2 == 0 and s[1] % 2 == 0);
    }
}

test "fuzz: leitura do ffprobe" {
    try fz.check({}, fuzzProbe, .{});
}

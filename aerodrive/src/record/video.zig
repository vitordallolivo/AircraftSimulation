//! Vídeo do voo em .mp4: os quadros da tela (RGBA) vão por um cano para o `ffmpeg` (H.264).
//! Sem ffmpeg instalado, `start` devolve `error.NoFfmpeg` e a gravação fica só com os dados.
//! Quadro com tamanho diferente do início (janela redimensionada) é pulado.
const std = @import("std");

pub const Video = struct {
    child: std.process.Child,
    w: u32,
    h: u32,
    frames: u64 = 0,

    /// abre o ffmpeg gravando em `path` (w×h RGBA, `fps` quadros por segundo)
    pub fn start(io: std.Io, path: []const u8, w: u32, h: u32, fps: u32) !Video {
        if (w < 16 or h < 16 or w > 8192 or h > 8192 or fps == 0 or fps > 240) return error.BadSize;
        var size: [32]u8 = undefined;
        var rate: [16]u8 = undefined;
        const argv = [_][]const u8{
            "ffmpeg",                                                      "-y", "-loglevel", "error",
            "-f",                                                          "rawvideo",
            "-pixel_format",                                               "rgba",
            "-video_size",                                                 try std.fmt.bufPrint(&size, "{d}x{d}", .{ w, h }),
            "-framerate",                                                  try std.fmt.bufPrint(&rate, "{d}", .{fps}),
            "-i",                                                          "-",
            "-vf",                                                         "crop=trunc(iw/2)*2:trunc(ih/2)*2", // H.264 quer lados pares
            "-c:v",                                                        "libx264",
            "-preset",                                                     "veryfast",
            "-pix_fmt",                                                    "yuv420p",
            "-crf",                                                        "23",
            path,
        };
        const child = std.process.spawn(io, .{ .argv = &argv, .stdin = .pipe, .stdout = .ignore, .stderr = .inherit }) catch |e| switch (e) {
            error.FileNotFound => return error.NoFfmpeg,
            else => return e,
        };
        return .{ .child = child, .w = w, .h = h };
    }

    /// um quadro (w·h·4 bytes, de cima para baixo); tamanho errado = pulado
    pub fn frame(v: *Video, io: std.Io, rgba: []const u8, w: u32, h: u32) !void {
        if (!accepts(v.w, v.h, rgba.len, w, h)) return;
        const in = v.child.stdin orelse return error.Closed;
        try in.writeStreamingAll(io, rgba);
        v.frames += 1;
    }

    /// fecha o cano e espera o ffmpeg terminar o arquivo
    pub fn finish(v: *Video, io: std.Io) bool {
        if (v.child.stdin) |in| in.close(io);
        v.child.stdin = null;
        const term = v.child.wait(io) catch return false;
        return term == .exited and term.exited == 0;
    }
};

/// o quadro tem o tamanho do vídeo?
pub fn accepts(vw: u32, vh: u32, len: usize, w: u32, h: u32) bool {
    const need = std.math.mul(usize, @as(usize, w) * h, 4) catch return false;
    return w == vw and h == vh and len == need;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;
const fz = @import("../util/fuzz.zig");

fn fuzzAccepts(_: void, src: *fz.Src) anyerror!void {
    const w = src.int(u32, 0, 9000);
    const h = src.int(u32, 0, 9000);
    const len = if (src.boolean()) @as(usize, w) * h * 4 else @as(usize, src.int(u32, 0, std.math.maxInt(u32)));
    const ok = accepts(w, h, len, w, h);
    try testing.expectEqual(len == @as(usize, w) * h * 4, ok);
    try testing.expect(!accepts(w +% 1, h, len, w, h));
}

test "fuzz: tamanho do quadro" {
    try fz.check({}, fuzzAccepts, .{});
}

test "grava um mp4 curto (se houver ffmpeg)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var pbuf: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/v.mp4", .{buf[0..n]});
    var v = Video.start(testing.io, path, 65, 49, 30) catch |e| {
        if (e == error.NoFfmpeg) return error.SkipZigTest;
        return e;
    };
    var px: [65 * 49 * 4]u8 = undefined;
    for (0..15) |k| {
        for (&px, 0..) |*b, i| b.* = @truncate(i + k * 7);
        try v.frame(testing.io, &px, 65, 49);
    }
    try v.frame(testing.io, px[0..100], 5, 5); // tamanho errado: pulado
    try testing.expectEqual(@as(u64, 15), v.frames);
    try testing.expect(v.finish(testing.io));
    const st = try tmp.dir.statFile(testing.io, "v.mp4", .{});
    try testing.expect(st.size > 200);
    try testing.expectError(error.BadSize, Video.start(testing.io, path, 0, 10, 30));
}

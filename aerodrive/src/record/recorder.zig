//! Gravação de um voo, ligada e desligada no meio do voo: cada gravação é uma pasta
//! `voo_AAAA-MM-DD_HH-MM-SS/` dentro de `paths.recordings`, com
//!   dados.csv   as grandezas do núcleo a 20 Hz (record/datalog.zig)
//!   video.mp4   a tela, se houver ffmpeg (record/video.zig)
//!   info.json   avião, data, duração
//! `list` lê as pastas de volta (para o menu "Voos gravados"), as mais novas primeiro.
const std = @import("std");
const core = @import("aerosim");
const datalog = @import("datalog.zig");
const video_mod = @import("video.zig");
const fz = @import("../util/fuzz.zig");

pub const Info = struct {
    aircraft: []const u8 = "",
    started: []const u8 = "", // "AAAA-MM-DD HH:MM:SS" (UTC)
    duration_s: f64 = 0,
    rows: usize = 0,
    video: bool = false,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    dir_buf: [1024]u8 = undefined,
    dir_len: usize = 0,
    data: datalog.DataLog = .{},
    video: ?video_mod.Video = null,
    video_error: ?anyerror = null,
    t0: ?f64 = null,
    t_last: f64 = 0,
    stamp: [19]u8 = undefined,

    pub fn dir(r: *const Recorder) []const u8 {
        return r.dir_buf[0..r.dir_len];
    }

    /// cria a pasta e (se `w`·`h` > 0) liga o vídeo
    pub fn start(io: std.Io, gpa: std.mem.Allocator, root: []const u8, epoch_s: i64, w: u32, h: u32, fps: u32) !Recorder {
        var r: Recorder = .{ .gpa = gpa };
        r.stamp = stampOf(epoch_s);
        var name: [32]u8 = undefined;
        const folder = try folderName(&name, r.stamp);
        const p = try std.fmt.bufPrint(&r.dir_buf, "{s}/{s}", .{ root, folder });
        r.dir_len = p.len;
        try std.Io.Dir.cwd().createDirPath(io, p);
        if (w > 0 and h > 0) {
            var vb: [1100]u8 = undefined;
            const vp = try std.fmt.bufPrint(&vb, "{s}/video.mp4", .{p});
            r.video = video_mod.Video.start(io, vp, w, h, fps) catch |e| blk: {
                r.video_error = e;
                break :blk null;
            };
        }
        return r;
    }

    pub fn addRow(r: *Recorder, row: *const core.types.LogRow) void {
        if (r.t0 == null) r.t0 = row.t;
        r.t_last = row.t;
        r.data.add(r.gpa, row) catch {};
    }

    pub fn addFrame(r: *Recorder, io: std.Io, rgba: []const u8, w: u32, h: u32) void {
        if (r.video) |*v| v.frame(io, rgba, w, h) catch {
            _ = v.finish(io);
            r.video = null;
            r.video_error = error.VideoBroke;
        };
    }

    /// fecha tudo e grava os arquivos; devolve se o vídeo ficou bom
    pub fn finish(r: *Recorder, io: std.Io, aircraft: []const u8) !void {
        defer r.data.deinit(r.gpa);
        var ok_video = false;
        var pb: [1100]u8 = undefined;
        if (r.video) |*v| {
            ok_video = v.finish(io) and v.frames > 0;
            if (!ok_video) std.Io.Dir.cwd().deleteFile(io, try std.fmt.bufPrint(&pb, "{s}/video.mp4", .{r.dir()})) catch {};
        }
        r.video = null;
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();
        try r.data.writeCsv(&out.writer);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&pb, "{s}/dados.csv", .{r.dir()}), .data = out.written() });
        var started: [19]u8 = r.stamp;
        started[10] = ' ';
        started[13] = ':';
        started[16] = ':';
        const info: Info = .{ .aircraft = aircraft, .started = &started, .duration_s = r.t_last - (r.t0 orelse r.t_last), .rows = r.data.count(), .video = ok_video };
        const j = try std.json.Stringify.valueAlloc(r.gpa, info, .{ .whitespace = .indent_2 });
        defer r.gpa.free(j);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&pb, "{s}/info.json", .{r.dir()}), .data = j });
    }
};

/// "AAAA-MM-DD_HH-MM-SS" (UTC) do instante em segundos desde 1970
pub fn stampOf(epoch_s: i64) [19]u8 {
    const s: u64 = @intCast(std.math.clamp(epoch_s, 0, 253402300799)); // até 9999-12-31
    const es: std.time.epoch.EpochSeconds = .{ .secs = s };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    var out: [19]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch unreachable;
    return out;
}

fn folderName(buf: []u8, stamp: [19]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "voo_{s}", .{&stamp});
}

// ------------------------------------------------------------------ catálogo
pub const Entry = struct {
    dir: []const u8,
    name: [:0]const u8, // "2026-10-03 14:22:05 · Convencional · 48 s"
    has_video: bool,
    has_data: bool,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},

    pub fn deinit(c: *Catalog) void {
        c.arena.deinit();
    }
};

/// as gravações em `root`, mais novas primeiro (pasta sem dados nem vídeo é pulada)
pub fn list(io: std.Io, gpa: std.mem.Allocator, root: []const u8) !Catalog {
    var c: Catalog = .{ .arena = .init(gpa) };
    errdefer c.deinit();
    const a = c.arena.allocator();
    var out: std.ArrayList(Entry) = .empty;
    var d = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return c;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or !std.mem.startsWith(u8, e.name, "voo_") or out.items.len >= 1000) continue;
        const full = try std.fs.path.join(a, &.{ root, e.name });
        const has_data = exists(io, d, e.name, "dados.csv");
        const has_video = exists(io, d, e.name, "video.mp4");
        if (!has_data and !has_video) continue;
        var info: Info = .{};
        var pb: [512]u8 = undefined;
        if (std.fmt.bufPrint(&pb, "{s}/info.json", .{e.name})) |ip| {
            if (d.readFileAlloc(io, ip, a, .limited(1 << 16))) |bytes| {
                info = std.json.parseFromSliceLeaky(Info, a, bytes, .{ .ignore_unknown_fields = true }) catch .{};
            } else |_| {}
        } else |_| {}
        try out.append(a, .{ .dir = full, .name = try label(a, e.name, info), .has_video = has_video, .has_data = has_data });
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn gt(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.dir, y.dir) == .gt;
        }
    }.gt);
    c.entries = out.items;
    return c;
}

fn exists(io: std.Io, d: std.Io.Dir, sub: []const u8, file: []const u8) bool {
    var pb: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ sub, file }) catch return false;
    _ = d.statFile(io, p, .{}) catch return false;
    return true;
}

/// texto da linha do menu: data (do nome da pasta), avião e duração
pub fn label(a: std.mem.Allocator, folder: []const u8, info: Info) ![:0]u8 {
    var when: []const u8 = folder;
    var buf: [19]u8 = undefined;
    if (folder.len == 23 and std.mem.startsWith(u8, folder, "voo_")) {
        @memcpy(&buf, folder[4..23]);
        buf[10] = ' ';
        buf[13] = ':';
        buf[16] = ':';
        when = &buf;
    }
    const dur = if (std.math.isFinite(info.duration_s)) std.math.clamp(info.duration_s, 0, 1e7) else 0;
    if (info.aircraft.len > 0) return std.fmt.allocPrintSentinel(a, "{s} · {s} · {d:.0} s", .{ when, info.aircraft[0..@min(info.aircraft.len, 60)], dur }, 0);
    return std.fmt.allocPrintSentinel(a, "{s}", .{when}, 0);
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "data no nome da pasta" {
    try testing.expectEqualStrings("2026-10-03_14-22-05", &stampOf(1791037325));
    try testing.expectEqualStrings("1970-01-01_00-00-00", &stampOf(-5));
}

test "grava só dados e acha de volta no catálogo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var r = try Recorder.start(testing.io, testing.allocator, root, 1791037325, 0, 0, 30);
    var row: core.types.LogRow = std.mem.zeroes(core.types.LogRow);
    for (0..40) |i| {
        row.t = 2 + @as(f64, @floatFromInt(i)) * 0.1;
        r.addRow(&row);
    }
    try r.finish(testing.io, "Convencional");
    var cat = try list(testing.io, testing.allocator, root);
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 1), cat.entries.len);
    try testing.expect(cat.entries[0].has_data and !cat.entries[0].has_video);
    try testing.expectEqualStrings("2026-10-03 14:22:05 · Convencional · 4 s", cat.entries[0].name);
}

fn fuzzLabel(_: void, src: *fz.Src) anyerror!void {
    var b1: [40]u8 = undefined;
    var b2: [80]u8 = undefined;
    const folder = b1[0..src.bytes(&b1)];
    const s = try label(testing.allocator, folder, .{ .aircraft = b2[0..src.bytes(&b2)], .duration_s = src.any() });
    defer testing.allocator.free(s);
    _ = stampOf(@bitCast(src.int(u64, 0, std.math.maxInt(u64))));
}

test "fuzz: nomes das gravações" {
    try fz.check({}, fuzzLabel, .{});
}

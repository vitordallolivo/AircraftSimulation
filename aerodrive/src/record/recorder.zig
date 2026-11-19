//! Gravação de um voo, ligada e desligada no meio do voo: cada gravação é uma pasta
//! `voo_AAAA-MM-DD_HH-MM-SS_<avião>/` dentro de `paths.recordings`, com
//!   dados.csv   as grandezas do núcleo a 20 Hz (record/datalog.zig)
//!   video.mp4   a tela, se houver ffmpeg (record/video.zig)
//! Nada mais: a data e o avião estão no nome da pasta, a duração sai do `t` do CSV e o vídeo é o arquivo existir.
//! `list` lê as pastas de volta (para o menu "Voos gravados"), as mais novas primeiro.
//! Os dados passam pelo `storage.Storage` (disco, ou o IndexedDB no navegador); o vídeo é do
//! ffmpeg e só existe no disco.
const std = @import("std");
const core = @import("aerosim");
const datalog = @import("datalog.zig");
const video_mod = @import("video.zig");
const storage = @import("../app/storage.zig");
const fz = @import("../util/fuzz.zig");

/// o que a lista mostra de uma gravação (o avião e a duração)
pub const Info = struct {
    aircraft: []const u8 = "",
    duration_s: f64 = 0,
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

    /// guarda o nome da pasta (a data e o avião `aircraft`) e (se `w`·`h` > 0) cria a pasta no disco e liga o
    /// vídeo; a pasta dos dados nasce no `finish`
    pub fn start(io: std.Io, gpa: std.mem.Allocator, root: []const u8, epoch_s: i64, aircraft: []const u8, w: u32, h: u32, fps: u32) !Recorder {
        var r: Recorder = .{ .gpa = gpa };
        r.stamp = stampOf(epoch_s);
        var name: [128]u8 = undefined;
        const folder = try folderName(&name, r.stamp, aircraft);
        const p = try std.fmt.bufPrint(&r.dir_buf, "{s}/{s}", .{ root, folder });
        r.dir_len = p.len;
        if (w > 0 and h > 0) {
            try std.Io.Dir.cwd().createDirPath(io, p);
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

    /// fecha o vídeo e grava o dados.csv em `files`
    pub fn finish(r: *Recorder, io: std.Io, files: storage.Storage) !void {
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
        try files.write(try std.fmt.bufPrint(&pb, "{s}/dados.csv", .{r.dir()}), out.written());
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

/// `voo_<data>_<avião>`: o nome do avião só com o que vale em nome de pasta (letras, inclusive acentuadas, números
/// e -; cada trecho do resto, espaço inclusive, vira um _), até 60 bytes; sem avião, só `voo_<data>`
fn folderName(buf: []u8, stamp: [19]u8, aircraft: []const u8) ![]const u8 {
    const head = try std.fmt.bufPrint(buf, "voo_{s}", .{&stamp});
    if (aircraft.len == 0) return head;
    var len = head.len;
    buf[len] = '_';
    len += 1;
    for (aircraft[0..@min(aircraft.len, 60)]) |char| {
        if (len >= buf.len) break;
        const keep = std.ascii.isAlphanumeric(char) or char == '-' or char >= 0x80;
        if (!keep and buf[len - 1] == '_') continue; // "Convencional (original)" → "Convencional_original"
        buf[len] = if (keep) char else '_';
        len += 1;
    }
    while (buf[len - 1] == '_') len -= 1;
    return buf[0..len];
}

/// o avião no nome da pasta (`voo_<data>_<avião>`, com _ virando espaço), ou "" numa pasta sem ele
fn aircraftOf(memory: std.mem.Allocator, folder: []const u8) ![]const u8 {
    const prefix = "voo_AAAA-MM-DD_HH-MM-SS_".len;
    if (folder.len <= prefix) return "";
    const name = try memory.dupe(u8, folder[prefix..]);
    for (name) |*char| if (char.* == '_') {
        char.* = ' ';
    };
    return name;
}

/// a duração do voo pelo `dados.csv`: o `t` da última linha menos o da primeira (0 se não der para ler)
fn durationOf(csv: []const u8) f64 {
    var lines = std.mem.tokenizeScalar(u8, csv, '\n');
    const header = lines.next() orelse return 0;
    var columns = std.mem.splitScalar(u8, header, ',');
    var time_column: usize = 0;
    while (columns.next()) |name| : (time_column += 1) {
        if (std.mem.eql(u8, std.mem.trim(u8, name, " \r"), "t")) break;
    } else return 0;
    var first: ?f64 = null;
    var last: f64 = 0;
    while (lines.next()) |line| {
        var cells = std.mem.splitScalar(u8, line, ',');
        var k: usize = 0;
        while (cells.next()) |cell| : (k += 1) if (k == time_column) {
            const value = std.fmt.parseFloat(f64, std.mem.trim(u8, cell, " \r")) catch break;
            if (first == null) first = value;
            last = value;
            break;
        };
    }
    return if (first) |start| last - start else 0;
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
pub fn list(files: storage.Storage, gpa: std.mem.Allocator, root: []const u8) !Catalog {
    var c: Catalog = .{ .arena = .init(gpa) };
    errdefer c.deinit();
    const a = c.arena.allocator();
    var out: std.ArrayList(Entry) = .empty;
    var folders = files.list(a, root) catch |err| return if (err == error.OutOfMemory) err else c;
    defer folders.deinit();
    for (folders.entries) |e| {
        if (e.kind != .folder or !std.mem.startsWith(u8, e.name, "voo_") or out.items.len >= 1000) continue;
        const full = try std.fs.path.join(a, &.{ root, e.name });
        var contents = files.list(a, full) catch continue;
        defer contents.deinit();
        const has_data = contents.find("dados.csv") != null;
        const has_video = contents.find("video.mp4") != null;
        if (!has_data and !has_video) continue;
        var info: Info = .{ .aircraft = try aircraftOf(a, e.name) };
        var pb: [1100]u8 = undefined;
        if (has_data) if (std.fmt.bufPrint(&pb, "{s}/dados.csv", .{full})) |data_path| {
            if (files.read(a, data_path, 256 << 20)) |bytes| info.duration_s = durationOf(bytes) else |_| {}
        } else |_| {};
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

/// apaga só o vídeo da gravação (os dados ficam)
pub fn deleteVideo(files: storage.Storage, dir: []const u8) bool {
    var pb: [1100]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/video.mp4", .{dir}) catch return false;
    files.remove(p) catch return false;
    return true;
}

/// apaga a gravação inteira — só pastas de gravação (`voo_…`), por segurança
pub fn deleteRecording(files: storage.Storage, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, std.fs.path.basename(dir), "voo_")) return false;
    files.remove(dir) catch return false;
    return true;
}

/// texto da linha do menu: data (do nome da pasta), avião e duração
pub fn label(a: std.mem.Allocator, folder: []const u8, info: Info) ![:0]u8 {
    var when: []const u8 = folder;
    var buf: [19]u8 = undefined;
    if (folder.len >= 23 and std.mem.startsWith(u8, folder, "voo_")) {
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
    var r = try Recorder.start(testing.io, testing.allocator, root, 1791037325, "Convencional (original)", 0, 0, 30);
    var row: core.types.LogRow = std.mem.zeroes(core.types.LogRow);
    for (0..40) |i| {
        row.t = 2 + @as(f64, @floatFromInt(i)) * 0.1;
        r.addRow(&row);
    }
    var disk: storage.DiskStorage = .{ .io = testing.io };
    try r.finish(testing.io, disk.storage());
    var cat = try list(disk.storage(), testing.allocator, root);
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 1), cat.entries.len);
    try testing.expect(cat.entries[0].has_data and !cat.entries[0].has_video);
    // a pasta tem só o dados.csv: a data e o avião vêm do nome dela, a duração do t do CSV
    try testing.expectEqualStrings("voo_2026-10-03_14-22-05_Convencional_original", std.fs.path.basename(r.dir()));
    try testing.expectEqualStrings("2026-10-03 14:22:05 · Convencional original · 4 s", cat.entries[0].name);
}

test "apagar o vídeo deixa os dados; apagar a gravação some com ela; pasta estranha não apaga" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var r = try Recorder.start(testing.io, testing.allocator, root, 1791037325, "X", 0, 0, 30);
    var row: core.types.LogRow = std.mem.zeroes(core.types.LogRow);
    r.addRow(&row);
    var disk: storage.DiskStorage = .{ .io = testing.io };
    const files = disk.storage();
    try r.finish(testing.io, files);
    var vb: [1100]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&vb, "{s}/video.mp4", .{r.dir()}), .data = "x" });
    try testing.expect(deleteVideo(files, r.dir()));
    var cat = try list(files, testing.allocator, root);
    try testing.expect(cat.entries.len == 1 and !cat.entries[0].has_video and cat.entries[0].has_data);
    cat.deinit();
    try testing.expect(!deleteRecording(files, root)); // não é voo_…
    try testing.expect(deleteRecording(files, r.dir()));
    var cat2 = try list(files, testing.allocator, root);
    defer cat2.deinit();
    try testing.expectEqual(@as(usize, 0), cat2.entries.len);
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

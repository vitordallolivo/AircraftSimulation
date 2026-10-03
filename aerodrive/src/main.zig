//! aerodrive: abre o avião salvo pela GUI e mostra o hangar.
//!
//!   aerodrive <avião.json>
//!   aerodrive --shot <avião.json> <saída.png> [LxA] [demo] [vista=az,el,zoom]
//!
//! Erros no arquivo do avião aparecem na tela (ou no terminal, no modo --shot), com o componente.
const std = @import("std");
const c = @import("c");
const model = @import("model/aircraft.zig");
const sk = @import("model/skeleton.zig");
const theme = @import("ui/theme.zig");
const Hangar = @import("screens/hangar.zig").Hangar;
const HangarOptions = @import("screens/hangar.zig").Options;

const Args = struct {
    shot: ?[:0]const u8 = null,
    path: ?[]const u8 = null,
    w: c_int = 1280,
    h: c_int = 720,
    opts: HangarOptions = .{},
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    var shot = false;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (std.mem.eql(u8, s, "--shot")) {
            shot = true;
        } else if (std.mem.eql(u8, s, "demo")) {
            a.opts.demo = true;
        } else if (std.mem.startsWith(u8, s, "vista=")) {
            var it = std.mem.splitScalar(u8, s[6..], ',');
            var v: [3]f64 = .{ 130, 22, 1 };
            for (&v) |*x| x.* = std.fmt.parseFloat(f64, it.next() orelse break) catch return error.BadArgs;
            a.opts.view = v;
        } else if (std.mem.indexOfScalar(u8, s, 'x') != null and s.len > 0 and std.ascii.isDigit(s[0])) {
            var it = std.mem.splitScalar(u8, s, 'x');
            a.w = std.fmt.parseInt(c_int, it.next().?, 10) catch return error.BadArgs;
            a.h = std.fmt.parseInt(c_int, it.next() orelse return error.BadArgs, 10) catch return error.BadArgs;
            if (a.w < 320 or a.h < 240 or a.w > 8192 or a.h > 8192) return error.BadArgs;
        } else if (a.path == null) {
            a.path = s;
        } else if (shot and a.shot == null) {
            a.shot = s;
        } else return error.BadArgs;
    }
    if (shot and a.shot == null) return error.BadArgs;
    return a;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = parseArgs(argv) catch {
        std.debug.print("uso: aerodrive <avião.json>\n     aerodrive --shot <avião.json> <saída.png> [LxA] [demo] [vista=az,el,zoom]\n", .{});
        std.process.exit(2);
    };
    const path = args.path orelse "../data/aircraft/Convencional_original.json";

    // ---- avião: ler, validar e montar o esqueleto (erros com mensagem, sem travar)
    var diag: model.Diag = .{};
    var loaded: ?model.Loaded = null;
    var skel: ?sk.Skeleton = null;
    defer if (skel) |*s| s.deinit();
    defer if (loaded) |*l| l.deinit();
    load: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 << 20)) catch |e| {
            diag.set("não consegui abrir '{s}' ({s})", .{ path, @errorName(e) });
            break :load;
        };
        defer gpa.free(bytes);
        loaded = model.parse(gpa, bytes, &diag) catch break :load;
        skel = sk.build(gpa, &loaded.?.ac, &diag) catch break :load;
    }
    if (skel == null and args.shot != null) {
        std.debug.print("erro: {s}\n", .{diag.text()});
        std.process.exit(1);
    }

    // ---- janela
    c.SetTraceLogLevel(c.LOG_WARNING);
    c.SetConfigFlags(c.FLAG_MSAA_4X_HINT | c.FLAG_WINDOW_RESIZABLE | c.FLAG_VSYNC_HINT);
    c.InitWindow(args.w, args.h, "aerodrive");
    defer c.CloseWindow();
    c.SetTargetFPS(60);
    var fonts = theme.Fonts.load();
    defer fonts.deinit();

    if (skel == null) { // mostra o erro até fechar
        var msg: [200]u8 = undefined;
        const text = std.fmt.bufPrintZ(&msg, "{s}", .{diag.text()}) catch "erro";
        while (!c.WindowShouldClose()) {
            c.BeginDrawing();
            c.ClearBackground(theme.panel);
            fonts.draw("aerodrive: o avião não abriu", 28, 28, 30, theme.title);
            fonts.draw(text, 28, 80, 20, theme.text);
            c.EndDrawing();
        }
        return;
    }

    const name = try init.arena.allocator().dupeZ(u8, loaded.?.ac.name);
    var hangar = try Hangar.init(gpa, name, &skel.?, args.opts);
    defer hangar.deinit();

    if (args.shot) |out| { // foto: alguns quadros e salva
        for (0..4) |_| hangar.frame(&fonts, if (args.opts.demo) 0.4 else 1.0 / 60.0);
        const img = c.LoadImageFromScreen();
        defer c.UnloadImage(img);
        if (!c.ExportImage(img, out.ptr)) {
            std.debug.print("erro: não consegui gravar '{s}'\n", .{out});
            std.process.exit(1);
        }
        return;
    }
    while (!c.WindowShouldClose()) hangar.frame(&fonts, @floatCast(c.GetFrameTime()));
}

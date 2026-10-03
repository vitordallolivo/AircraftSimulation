//! aerodrive: abre o avião salvo pela GUI; hangar -> voo (piloto automático).
//!
//!   aerodrive <avião.json> [fps=30|60]
//!   aerodrive --shot <avião.json> <saída.png> [LxA] [demo] [vista=az,el,zoom] [voo=SEG] [cam=chao|seguir|livre]
//!
//! Erros no arquivo do avião aparecem na tela (ou no terminal, no modo --shot), com o componente.
const std = @import("std");
const rl = @import("raylib");
const model = @import("model/aircraft.zig");
const sk = @import("model/skeleton.zig");
const render = @import("gfx/render.zig");
const theme = @import("ui/theme.zig");
const hangar_mod = @import("screens/hangar.zig");
const flight_mod = @import("screens/flight.zig");
const DriveManager = @import("sim/drive_manager.zig").DriveManager;

const Screen = enum { hangar, flight };

const Args = struct {
    shot: ?[:0]const u8 = null,
    path: ?[]const u8 = null,
    w: i32 = 1280,
    h: i32 = 720,
    fps: u32 = 60,
    fly_s: ?f64 = null, // --shot: voa estes segundos antes da foto
    cam: flight_mod.CameraKind = .ground,
    opts: hangar_mod.Options = .{},
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var a: Args = .{};
    var shot = false;
    for (argv[1..]) |s| {
        if (std.mem.eql(u8, s, "--shot")) {
            shot = true;
        } else if (std.mem.eql(u8, s, "demo")) {
            a.opts.demo = true;
        } else if (std.mem.startsWith(u8, s, "vista=")) {
            var it = std.mem.splitScalar(u8, s[6..], ',');
            var v: [3]f64 = .{ 130, 22, 1 };
            for (&v) |*x| x.* = std.fmt.parseFloat(f64, it.next() orelse break) catch return error.BadArgs;
            a.opts.view = v;
        } else if (std.mem.startsWith(u8, s, "voo=")) {
            a.fly_s = std.fmt.parseFloat(f64, s[4..]) catch return error.BadArgs;
            if (!(a.fly_s.? >= 0 and a.fly_s.? < 3600)) return error.BadArgs;
        } else if (std.mem.startsWith(u8, s, "cam=")) {
            const c = s[4..];
            a.cam = if (std.mem.eql(u8, c, "chao")) .ground else if (std.mem.eql(u8, c, "seguir")) .chase else if (std.mem.eql(u8, c, "livre")) .orbit else return error.BadArgs;
        } else if (std.mem.startsWith(u8, s, "fps=")) {
            a.fps = std.fmt.parseInt(u32, s[4..], 10) catch return error.BadArgs;
            if (a.fps != 30 and a.fps != 60) return error.BadArgs;
        } else if (s.len > 0 and std.ascii.isDigit(s[0]) and std.mem.indexOfScalar(u8, s, 'x') != null) {
            var it = std.mem.splitScalar(u8, s, 'x');
            a.w = std.fmt.parseInt(i32, it.next().?, 10) catch return error.BadArgs;
            a.h = std.fmt.parseInt(i32, it.next() orelse return error.BadArgs, 10) catch return error.BadArgs;
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
        std.debug.print("uso: aerodrive <avião.json> [fps=30|60]\n     aerodrive --shot <avião.json> <saída.png> [LxA] [demo] [vista=az,el,zoom] [voo=SEG] [cam=chao|seguir|livre]\n", .{});
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
    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_resizable = true, .vsync_hint = true });
    rl.initWindow(args.w, args.h, "aerodrive");
    defer rl.closeWindow();
    rl.setExitKey(.null); // Esc volta ao hangar; fechar a janela sai
    rl.setTargetFPS(@intCast(args.fps));
    var fonts = theme.Fonts.load();
    defer fonts.deinit();

    if (skel == null) { // mostra o erro até fechar
        var msg: [200]u8 = undefined;
        const text = std.fmt.bufPrintZ(&msg, "{s}", .{diag.text()}) catch "erro";
        while (!rl.windowShouldClose()) {
            rl.beginDrawing();
            rl.clearBackground(theme.panel);
            fonts.draw("aerodrive: o avião não abriu", 28, 28, 30, theme.title);
            fonts.draw(text, 28, 80, 20, theme.text);
            rl.endDrawing();
        }
        return;
    }
    const ac = &loaded.?.ac;
    const name = try init.arena.allocator().dupeZ(u8, ac.name);
    var scene = try render.Scene.init(gpa, &skel.?);
    defer scene.deinit();
    var hangar = hangar_mod.Hangar.init(name, &skel.?, &scene, args.opts);
    defer hangar.deinit();
    const span = 2 * skel.?.radius();

    var dm: ?DriveManager = null;
    defer if (dm) |*d| d.deinit();
    var flight: ?flight_mod.Flight = null;
    var screen: Screen = .hangar;
    const sim_dt = 1.0 / @as(f64, @floatFromInt(args.fps)); // tempo real: um quadro = 1/fps de simulação

    if (args.shot) |out| { // foto: hangar, ou voa `voo=` segundos e fotografa
        if (args.fly_s) |secs| {
            dm = DriveManager.init(gpa, ac, &diag) catch {
                std.debug.print("erro: {s}\n", .{diag.text()});
                std.process.exit(1);
            };
            flight = flight_mod.Flight.init(&dm.?, &scene, ac, args.fps, args.cam, span);
            var t: f64 = 0;
            while (t + sim_dt < secs) : (t += sim_dt) flight.?.advance(sim_dt); // sem desenhar (rápido)
            for (0..3) |_| _ = flight.?.frame(&fonts, sim_dt);
        } else {
            for (0..4) |_| _ = hangar.frame(&fonts, if (args.opts.demo) 0.4 else sim_dt);
        }
        const img = try rl.loadImageFromScreen();
        defer rl.unloadImage(img);
        if (!rl.exportImage(img, out)) {
            std.debug.print("erro: não consegui gravar '{s}'\n", .{out});
            std.process.exit(1);
        }
        return;
    }

    while (!rl.windowShouldClose()) {
        switch (screen) {
            .hangar => if (hangar.frame(&fonts, @floatCast(rl.getFrameTime())) == .fly) {
                if (dm == null) dm = DriveManager.init(gpa, ac, &diag) catch null;
                if (dm) |*d| {
                    d.restart() catch {};
                    flight = flight_mod.Flight.init(d, &scene, ac, args.fps, args.cam, span);
                    screen = .flight;
                }
            },
            .flight => if (flight.?.frame(&fonts, sim_dt) == .back) {
                screen = .hangar;
            },
        }
    }
}

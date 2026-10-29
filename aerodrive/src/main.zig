//! AeroDrive: abre o menu inicial com o avião (o último escolhido, ou o do argumento).
//!
//!   aerodrive [avião.json] [fps=30|60]
//!   aerodrive --shot <saída.png> [avião.json] [LxA] [tela=NOME] [voo=SEG] [modo=manual|auto]
//!             [cam=seguir|chao|livre] [mesa] [dados=PASTA] [gravar] [f3] [controle]
//!     tela: inicio, aeronave, voar, opcoes, controle, camera, som, voos, dados, video, voo, pausa
//!
//! No modo --shot nada é lido nem gravado nas configurações (fotos sempre iguais).
//!
//! No navegador (`zig build -Dtarget=wasm32-emscripten`) o `main` é outro: não há argumentos nem
//! laço bloqueante; o jogo monta e entrega cada quadro ao navegador (`emscripten_set_main_loop`).
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("app/app.zig");
const paths_mod = @import("app/paths.zig");
const settings = @import("app/settings.zig");
const storage = @import("app/storage.zig");
const platform = @import("sys/platform.zig");
const browser = @import("sys/browser.zig");
const browser_io = @import("sys/browser_io.zig");

pub const main = if (platform.in_browser) browserMain else nativeMain;

// a `Io` do std.debug (print, panes): no navegador a nossa (o `std.Io.Threaded` do Zig 0.16 não
// compila para emscripten, ver sys/browser_io.zig); no nativo o mesmo padrão de sempre do std
pub const std_options_debug_io: std.Io = if (platform.in_browser) browser_io.io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (platform.in_browser) null else std.Io.Threaded.global_single_threaded;

const Args = struct {
    shot: ?[:0]const u8 = null,
    path: ?[]const u8 = null,
    w: i32 = 1280,
    h: i32 = 720,
    fps: ?u32 = null,
    screen: app_mod.Id = .main,
    fly_s: ?f64 = null,
    mode_auto: bool = true,
    cam: ?settings.CameraKind = null,
    table: bool = false,
    data_dir: ?[]const u8 = null,
    record: bool = false,
    dev: bool = false,
    channel: usize = 0, // tela=controle: qual canal mostrar
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (std.mem.eql(u8, s, "--shot")) {
            i += 1;
            if (i >= argv.len) return error.BadArgs;
            a.shot = argv[i];
        } else if (std.mem.startsWith(u8, s, "tela=")) {
            const names = .{ .{ "inicio", .main }, .{ "aeronave", .aircraft }, .{ "voar", .fly }, .{ "controle", .control }, .{ "camera", .camera }, .{ "som", .sound }, .{ "voos", .recordings }, .{ "dados", .viewer }, .{ "video", .video }, .{ "opcoes", .options }, .{ "voo", .flight }, .{ "pausa", .pause } };
            var ok = false;
            inline for (names) |n| if (std.mem.eql(u8, s[5..], n[0])) {
                a.screen = n[1];
                ok = true;
            };
            if (!ok) return error.BadArgs;
        } else if (std.mem.startsWith(u8, s, "voo=")) {
            a.fly_s = std.fmt.parseFloat(f64, s[4..]) catch return error.BadArgs;
            if (!(a.fly_s.? >= 0 and a.fly_s.? < 3600)) return error.BadArgs;
        } else if (std.mem.startsWith(u8, s, "modo=")) {
            a.mode_auto = std.mem.eql(u8, s[5..], "auto");
        } else if (std.mem.startsWith(u8, s, "cam=")) {
            const c = s[4..];
            a.cam = if (std.mem.eql(u8, c, "chao")) .ground else if (std.mem.eql(u8, c, "seguir")) .chase else if (std.mem.eql(u8, c, "livre")) .orbit else return error.BadArgs;
        } else if (std.mem.startsWith(u8, s, "canal=")) {
            a.channel = std.fmt.parseInt(usize, s[6..], 10) catch return error.BadArgs;
        } else if (std.mem.eql(u8, s, "controle")) {
            @import("ui/glyphs.zig").force_pad = true;
        } else if (std.mem.eql(u8, s, "f3")) {
            a.dev = true;
        } else if (std.mem.eql(u8, s, "gravar")) {
            a.record = true;
        } else if (std.mem.eql(u8, s, "mesa")) {
            a.table = true;
        } else if (std.mem.startsWith(u8, s, "dados=")) {
            a.data_dir = s[6..];
        } else if (std.mem.startsWith(u8, s, "fps=")) {
            const f = std.fmt.parseInt(u32, s[4..], 10) catch return error.BadArgs;
            if (f != 30 and f != 60) return error.BadArgs;
            a.fps = f;
        } else if (s.len > 0 and std.ascii.isDigit(s[0]) and std.mem.indexOfScalar(u8, s, 'x') != null) {
            var it = std.mem.splitScalar(u8, s, 'x');
            a.w = std.fmt.parseInt(i32, it.next().?, 10) catch return error.BadArgs;
            a.h = std.fmt.parseInt(i32, it.next() orelse return error.BadArgs, 10) catch return error.BadArgs;
            if (a.w < 320 or a.h < 240 or a.w > 8192 or a.h > 8192) return error.BadArgs;
        } else if (a.path == null) {
            a.path = s;
        } else return error.BadArgs;
    }
    return a;
}

/// programa nativo: argumentos, janela e laço até fechar (ou uma foto, com --shot)
fn nativeMain(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv) catch {
        std.debug.print("uso: aerodrive [avião.json] [fps=30|60]\n     aerodrive --shot <saída.png> [avião.json] [LxA] [tela=inicio|aeronave|voar|opcoes|controle|camera|som|voos|dados|video|voo|pausa] [voo=SEG] [modo=manual|auto] [cam=seguir|chao|livre] [mesa] [dados=PASTA] [gravar] [f3] [controle]\n", .{});
        std.process.exit(2);
    };
    var paths = try paths_mod.resolve(arena, init.environ_map);
    const shot = args.shot != null;
    if (shot) { // não lê nem grava configurações
        paths.config = "/dev/null/aerodrive-sem-config";
        paths.planes = "/dev/null/aerodrive-sem-avioes";
    }

    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_resizable = true, .vsync_hint = !shot });
    rl.initWindow(args.w, args.h, "AeroDrive");
    defer rl.closeWindow();
    rl.setExitKey(.null); // Esc é "voltar"/pausa; fechar a janela sai

    var disk: storage.DiskStorage = .{ .io = init.io };
    const app = try app_mod.App.init(init.io, gpa, paths, disk.storage());
    defer app.deinit();
    if (args.fps) |f| app.settings.fps = f;
    rl.setTargetFPS(@intCast(app.settings.fps));
    if (args.path) |p| _ = app.loadPlane(p);

    if (!shot) {
        app.run();
        return;
    }

    // ---- foto: monta a tela pedida, desenha alguns quadros e grava a imagem
    if (app.plane == null) {
        if (args.path == null) app.run() else {
            std.debug.print("erro: {s}\n", .{app.planeError() orelse "avião não abriu"});
            std.process.exit(1);
        }
        return;
    }
    if (args.table) app.session().scenario = .table;
    app.settings.dev_overlay = args.dev;
    app.screens.control.channel = args.channel;
    app.session().start_mode = if (args.mode_auto) .autopilot else .manual;
    if (args.cam) |c| app.camera().start = c;
    if (args.data_dir) |d| {
        const n = @min(d.len, app.viewer_dir.len);
        @memcpy(app.viewer_dir[0..n], d[0..n]);
        app.viewer_dir_len = n;
    }
    if (args.screen == .flight or args.screen == .pause or args.fly_s != null) {
        if (!app.startFlight()) {
            std.debug.print("erro: {s}\n", .{app.planeError() orelse "voo não montou"});
            std.process.exit(1);
        }
        const dt = 1.0 / 60.0;
        var t: f64 = 0;
        const live = args.record and args.screen == .flight; // grava 2 s desenhando (vídeo + dados)
        if (args.record and !live) app.startRecording();
        while (t + dt < (args.fly_s orelse 0)) : (t += dt) app.screens.flight.advance(app, dt);
        if (args.record and !live) app.stopRecording();
        app.go(.{ .open = .flight });
        for (0..3) |_| app.step(0); // câmeras chegam no avião
        if (live) {
            app.startRecording();
            for (0..120) |_| app.step(dt);
            app.stopRecording();
            std.debug.print("{s}\n", .{app.message() orelse ""});
        }
        if (args.screen == .pause) app.go(.{ .open = .pause });
    } else if (args.screen != .main) app.go(.{ .open = args.screen });
    for (0..6) |_| app.step(if (args.screen == .flight) 0 else 1.0 / 60.0);
    const img = try rl.loadImageFromScreen();
    defer rl.unloadImage(img);
    if (!rl.exportImage(img, args.shot.?)) {
        std.debug.print("erro: não consegui gravar '{s}'\n", .{args.shot.?});
        std.process.exit(1);
    }
}

// ------------------------------------------------------------------ navegador
/// o jogo do navegador; fica aqui (e não na pilha do `main`) porque o `main` termina e o
/// navegador continua chamando `browserFrame`
var browser_app: ?*app_mod.App = null;
var browser_storage: storage.BrowserStorage = .{};

/// navegador: janela do tamanho da página, configurações e aviões do IndexedDB (a página já
/// carregou /aerodrive antes do `main`), e o laço entregue ao navegador
fn browserMain() !void {
    const gpa = std.heap.c_allocator;
    rl.setTraceLogLevel(.warning);
    // sem window_resizable: o raylib poria o canvas no tamanho da página; quem acompanha a página é
    // `followViewport`, com a área lógica de `browser.viewportSize`
    rl.setConfigFlags(.{ .msaa_4x_hint = true });
    const size = browser.viewportSize();
    rl.initWindow(size.width, size.height, "AeroDrive");
    rl.setExitKey(.null); // Esc é "voltar"/pausa
    const app = try app_mod.App.init(browser_io.io, gpa, paths_mod.browser, browser_storage.storage());
    browser_app = app;
    app.begin();
    browser.setFrameRate(app.settings.fps);
    // 0 = no ritmo da tela (requestAnimationFrame); 1 = não volta daqui (o main "fica rodando")
    std.os.emscripten.emscripten_set_main_loop(browserFrame, 0, 1);
}

/// a janela do jogo acompanha a página: celular girado, tela cheia ligada ou desligada, barra do
/// navegador aparecendo
fn followViewport() void {
    const size = browser.viewportSize();
    if (size.width != rl.getScreenWidth() or size.height != rl.getScreenHeight()) rl.setWindowSize(size.width, size.height);
}

/// um quadro no navegador: o .json que chegou da página (se houver) e o jogo
fn browserFrame() callconv(.c) void {
    const app = browser_app orelse return;
    if (browser.takeImport()) |file| {
        defer file.deinit();
        if (app.importFile(file.name, file.bytes)) app.saveSettings(); // a página pode fechar sem aviso: já fica lembrado
    }
    followViewport();
    app.step(@floatCast(rl.getFrameTime()));
    if (app.quit) { // "Sair" no navegador: grava e volta à tela inicial do site
        app.quit = false;
        app.saveSettings();
        browser.leave();
    }
}

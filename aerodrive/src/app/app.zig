//! O jogo inteiro: o que as telas dividem (fontes, widgets, configurações, o avião carregado, som,
//! voo em andamento, gravação) e o gerenciador de telas (uma pilha: abrir, voltar, ir ao início).
//!
//! Cada tela é um arquivo em `screens/` com o mesmo contrato:
//!   pub fn frame(s: *Tela, app: *App, dt: f64) Next     // desenha um quadro e diz o próximo passo
//!   pub fn enter(s: *Tela, app: *App) void              // (opcional) ao abrir a tela
//! Nenhuma tela conhece as outras: elas pedem `.{ .open = .aircraft }`, `.back`, `.home`, `.quit`.
const std = @import("std");
const rl = @import("raylib");
const model = @import("../model/aircraft.zig");
const sk = @import("../model/skeleton.zig");
const features = @import("../model/features.zig");
const render = @import("../gfx/render.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const settings_mod = @import("settings.zig");
const store_mod = @import("store.zig");
const storage = @import("storage.zig");
const PlaneSettings = @import("plane_settings.zig").PlaneSettings;
const paths_mod = @import("paths.zig");
const library = @import("library.zig");
const Player = @import("../audio/player.zig").Player;
const stats = @import("../sys/stats.zig");
const gamepad = @import("../input/gamepad.zig");
const ch = @import("../input/channels.zig");
const dm_mod = @import("../sim/drive_manager.zig");
const recorder = @import("../record/recorder.zig");

const main_menu = @import("../screens/main_menu.zig");
const aircraft_menu = @import("../screens/aircraft_menu.zig");
const fly_menu = @import("../screens/fly_menu.zig");
const control_menu = @import("../screens/control_menu.zig");
const camera_menu = @import("../screens/camera_menu.zig");
const sound_menu = @import("../screens/sound_menu.zig");
const recordings_menu = @import("../screens/recordings_menu.zig");
const recording_view = @import("../screens/recording_view.zig");
const flight_screen = @import("../screens/flight.zig");
const pause_menu = @import("../screens/pause_menu.zig");
const options_menu = @import("../screens/options_menu.zig");
const video_view = @import("../screens/video_view.zig");
const KeepAwake = @import("../sys/keep_awake.zig").KeepAwake;
const dev_overlay = @import("../ui/dev_overlay.zig");
const platform = @import("../sys/platform.zig");

const logo_png = @embedFile("../assets/albatroz.png");
/// o maior .json de avião que se lê (disco, navegador ou arquivo arrastado)
pub const max_plane_bytes = 64 << 20;
const video_fps = 30;

pub const Id = enum { main, aircraft, fly, options, control, camera, sound, recordings, viewer, video, flight, pause };

pub const Next = union(enum) {
    stay,
    open: Id, // empilha
    back, // volta à anterior
    home, // menu inicial (encerra o voo)
    quit,
};

/// o avião carregado: arquivo lido, esqueleto, malhas na GPU e o que ele tem
pub const Plane = struct {
    loaded: model.Loaded,
    skel: sk.Skeleton,
    scene: render.Scene,
    feats: features.Features,
    name: [:0]u8,
    path: []u8,
    span: f64,
    stall: [4]?f64 = .{ null, null, null, null }, // deflexão de estol de cada canal (features.Channel)

    pub fn deinit(p: *Plane, gpa: std.mem.Allocator) void {
        p.scene.deinit();
        p.skel.deinit();
        p.loaded.deinit();
        gpa.free(p.name);
        gpa.free(p.path);
    }
};

pub const Screens = struct {
    main: main_menu.MainMenu = .{},
    aircraft: aircraft_menu.AircraftMenu = .{},
    fly: fly_menu.FlyMenu = .{},
    options: options_menu.OptionsMenu = .{},
    control: control_menu.ControlMenu = .{},
    camera: camera_menu.CameraMenu = .{},
    sound: sound_menu.SoundMenu = .{},
    recordings: recordings_menu.RecordingsMenu = .{},
    viewer: recording_view.RecordingView = .{},
    video: video_view.VideoView = .{},
    flight: flight_screen.Flight = .{},
    pause: pause_menu.PauseMenu = .{},
};

pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    fonts: theme.Fonts,
    ui: widgets.Ui,
    settings: settings_mod.Settings, // gerais (último avião, controle e câmera gerais, som, fps)
    paths: paths_mod.Paths,
    files: storage.Storage, // disco no nativo, IndexedDB no navegador
    plane_files: store_mod.FileStore, // configurações por avião (uma por arquivo)
    plane_cfg: PlaneSettings = .{}, // as do avião aberto
    lib: library.Library,
    plane: ?Plane = null,
    plane_error: [256]u8 = undefined,
    plane_error_len: usize = 0,
    audio: Player,
    logo: ?rl.Texture2D = null,
    sampler: stats.Sampler = .{},
    keep_awake: KeepAwake = .{}, // a tela não escurece com o jogo aberto
    reader: gamepad.Reader = .{},
    channel_state: ch.State = .{},
    // voo em andamento
    dm: ?dm_mod.DriveManager = null,
    flight_ac: model.Aircraft = .{},
    rec: ?recorder.Recorder = null,
    rec_message: [160]u8 = undefined,
    rec_message_len: usize = 0,
    rec_message_t: f64 = 0,
    video_acc: f64 = 0, // tempo acumulado para o vídeo (30 quadros por segundo de tempo real)
    // recurso escolhido em "Voos gravados"
    viewer_dir: [1024]u8 = undefined,
    viewer_dir_len: usize = 0,
    // telas
    stack: [8]Id = .{.main} ** 8,
    focus: [8]usize = .{0} ** 8, // item em destaque de cada tela da pilha (volta igual)
    depth: usize = 1,
    screens: Screens = .{},
    quit: bool = false,
    time: f64 = 0,

    /// fontes, configurações (lidas de `files`), biblioteca, som e logo
    pub fn init(io: std.Io, gpa: std.mem.Allocator, paths: paths_mod.Paths, files: storage.Storage) !*App {
        const app = try gpa.create(App);
        app.* = .{
            .io = io,
            .gpa = gpa,
            .fonts = theme.Fonts.load(),
            .ui = undefined,
            .settings = settings_mod.Settings.load(files, gpa, paths.config),
            .paths = paths,
            .files = files,
            .plane_files = .{ .files = files, .root = paths.planes },
            .lib = library.scan(files, gpa, &paths.examples, paths.mine) catch .{ .arena = .init(gpa) },
            .audio = Player.init(),
        };
        app.ui = .{ .fonts = &app.fonts };
        app.keep_awake = KeepAwake.start(io);
        if (app.settings.fullscreen) {
            app.settings.fullscreen = false;
            app.setFullscreen(true);
        }
        if (rl.loadImageFromMemory(".png", logo_png)) |img| {
            defer rl.unloadImage(img);
            app.logo = rl.loadTextureFromImage(img) catch null;
            if (app.logo) |t| rl.setTextureFilter(t, .bilinear);
        } else |_| {}
        return app;
    }

    pub fn deinit(app: *App) void {
        app.stopRecording();
        app.endFlight();
        app.saveSettings();
        inline for (@typeInfo(Screens).@"struct".fields) |f| {
            if (@hasDecl(f.type, "deinit")) @field(app.screens, f.name).deinit(app);
        }
        if (app.plane) |*p| p.deinit(app.gpa);
        if (app.logo) |t| rl.unloadTexture(t);
        app.audio.deinit();
        app.keep_awake.stop(app.io);
        app.lib.deinit();
        app.fonts.deinit();
        app.gpa.destroy(app);
    }

    /// grava as gerais e as do avião aberto (a sessão do avião vira o ponto de partida do próximo)
    pub fn saveSettings(app: *App) void {
        if (app.plane) |p| {
            app.settings.session = app.plane_cfg.session;
            _ = app.plane_cfg.save(app.plane_files.store(), app.gpa, p.path);
        }
        app.settings.save(app.files, app.gpa, app.paths.config);
    }

    // ---------------------------------------------------------------- o que vale agora
    /// sessão (cenário, pouso, modo, vento...) do avião aberto
    pub fn session(app: *App) *@import("../sim/session.zig").Session {
        return &app.plane_cfg.session;
    }

    /// controle: o próprio do avião, se ele tiver; senão o geral
    pub fn profile(app: *App) *ch.Profile {
        return if (app.plane_cfg.own_controls) &app.plane_cfg.profile else &app.settings.profile;
    }

    /// tela cheia na resolução do monitor (o sistema reconhece como jogo em tela cheia) ou janela
    pub fn setFullscreen(app: *App, on: bool) void {
        if (on == rl.isWindowFullscreen()) {
            app.settings.fullscreen = on;
            return;
        }
        if (on) {
            const m = rl.getCurrentMonitor();
            rl.setWindowSize(rl.getMonitorWidth(m), rl.getMonitorHeight(m));
            rl.toggleFullscreen();
        } else {
            rl.toggleFullscreen();
            rl.setWindowSize(1280, 720);
        }
        app.settings.fullscreen = on;
    }

    /// deflexão de estol do canal no avião aberto (rad), se tiver
    pub fn stallLimit(app: *const App, c: features.Channel) ?f64 {
        const p = app.plane orelse return null;
        return p.stall[@intFromEnum(c)];
    }

    /// o controle como vai para as superfícies: a deflexão máxima escolhida, nunca além do estol
    pub fn effectiveProfile(app: *App) ch.Profile {
        var p = app.profile().*;
        if (app.stallLimit(.elevator)) |l| p.de_max = @min(p.de_max, l);
        if (app.stallLimit(.aileron)) |l| p.da_max = @min(p.da_max, l);
        if (app.stallLimit(.rudder)) |l| p.dr_max = @min(p.dr_max, l);
        return p;
    }

    pub fn camera(app: *App) *settings_mod.CameraSettings {
        return if (app.plane_cfg.own_camera) &app.plane_cfg.camera else &app.settings.camera;
    }

    /// liga/desliga controle próprio do avião (ao ligar, começa igual ao geral)
    pub fn setOwnControls(app: *App, on: bool) void {
        if (on and !app.plane_cfg.own_controls) app.plane_cfg.profile = app.settings.profile;
        app.plane_cfg.own_controls = on;
    }

    pub fn setOwnCamera(app: *App, on: bool) void {
        if (on and !app.plane_cfg.own_camera) app.plane_cfg.camera = app.settings.camera;
        app.plane_cfg.own_camera = on;
    }

    // ---------------------------------------------------------------- avião
    pub fn planeError(app: *const App) ?[]const u8 {
        return if (app.plane_error_len > 0) app.plane_error[0..app.plane_error_len] else null;
    }

    /// lê e monta o avião; se falhar, o anterior continua e o erro fica em `planeError`
    pub fn loadPlane(app: *App, path: []const u8) bool {
        var diag: model.Diag = .{};
        const p = app.readPlane(path, &diag) catch return app.failPlane(&diag);
        app.usePlane(p);
        return true;
    }

    /// avião vindo de fora (arrastado para a janela, ou escolhido na página do navegador): monta
    /// a partir dos bytes e, se der certo, grava em `path` (o .json passa a ser da biblioteca)
    pub fn importPlane(app: *App, path: []const u8, bytes: []const u8) bool {
        var diag: model.Diag = .{};
        const p = app.buildPlane(path, bytes, &diag) catch return app.failPlane(&diag);
        app.files.write(path, bytes) catch |err| {
            var plane = p;
            plane.deinit(app.gpa);
            diag.set("não consegui guardar '{s}' ({s})", .{ path, @errorName(err) });
            return app.failPlane(&diag);
        };
        app.usePlane(p);
        return true;
    }

    /// .json escolhido pelo jogador no navegador: vai para "meus aviões" (`paths.mine`, guardado no
    /// IndexedDB) com um nome de arquivo seguro, abre e aparece na biblioteca
    pub fn importFile(app: *App, file_name: []const u8, bytes: []const u8) bool {
        var name_buf: [96]u8 = undefined;
        var path_buf: [1200]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ app.paths.mine, library.safeFileName(&name_buf, file_name) }) catch return false;
        if (!app.importPlane(path, bytes)) return false;
        app.rescanLibrary();
        return true;
    }

    /// lê as pastas de aviões de novo e avisa as telas (`libraryChanged`)
    pub fn rescanLibrary(app: *App) void {
        const lib = library.scan(app.files, app.gpa, &app.paths.examples, app.paths.mine) catch return;
        app.lib.deinit();
        app.lib = lib;
        inline for (@typeInfo(Screens).@"struct".fields) |f| {
            if (@hasDecl(f.type, "libraryChanged")) @field(app.screens, f.name).libraryChanged(app);
        }
    }

    /// o .json do avião aberto, como está guardado (o chamador libera com `gpa`)
    pub fn planeBytes(app: *App) ?[]u8 {
        const p = app.plane orelse return null;
        return app.files.read(app.gpa, p.path, max_plane_bytes) catch null;
    }

    fn failPlane(app: *App, diag: *const model.Diag) bool {
        const msg = std.fmt.bufPrint(&app.plane_error, "{s}", .{diag.text()}) catch app.plane_error[0..0];
        app.plane_error_len = msg.len;
        return false;
    }

    /// troca o avião aberto pelo `p` (já montado)
    fn usePlane(app: *App, p: Plane) void {
        const path = p.path;
        app.endFlight();
        app.saveSettings(); // guarda as do avião que sai
        if (app.plane) |*old| old.deinit(app.gpa);
        app.plane = p;
        app.plane_error_len = 0;
        app.settings.setAircraft(path);
        // as do avião que entra; nunca aberto antes: começa da última sessão usada e do controle geral
        app.plane_cfg = PlaneSettings.load(app.plane_files.store(), app.gpa, path, .{ .session = app.settings.session });
        inline for (@typeInfo(Screens).@"struct".fields) |f| {
            if (@hasDecl(f.type, "planeChanged")) @field(app.screens, f.name).planeChanged(app);
        }
    }

    fn readPlane(app: *App, path: []const u8, diag: *model.Diag) !Plane {
        const bytes = app.files.read(app.gpa, path, max_plane_bytes) catch |e| {
            diag.set("não consegui abrir '{s}' ({s})", .{ path, @errorName(e) });
            return error.Open;
        };
        defer app.gpa.free(bytes);
        return app.buildPlane(path, bytes, diag);
    }

    fn buildPlane(app: *App, path: []const u8, bytes: []const u8, diag: *model.Diag) !Plane {
        var loaded = try model.parse(app.gpa, bytes, diag);
        errdefer loaded.deinit();
        var skel = try sk.build(app.gpa, &loaded.ac, diag);
        errdefer skel.deinit();
        var scene = try render.Scene.init(app.gpa, &skel);
        errdefer scene.deinit();
        const name = try app.gpa.dupeZ(u8, loaded.ac.name);
        errdefer app.gpa.free(name);
        var pl: Plane = .{ .loaded = loaded, .skel = skel, .scene = scene, .feats = features.detect(&loaded.ac), .name = name, .path = try app.gpa.dupe(u8, path), .span = 2 * skel.radius() };
        inline for (@typeInfo(features.Channel).@"enum".fields) |f| pl.stall[f.value] = features.stallLimit(&pl.loaded.ac, @enumFromInt(f.value));
        return pl;
    }

    // ---------------------------------------------------------------- voo
    /// monta a simulação com as escolhas da sessão e abre a tela de voo
    pub fn startFlight(app: *App) bool {
        const p = &(app.plane orelse return false);
        app.endFlight();
        app.flight_ac = app.session().apply(p.loaded.ac);
        var diag: model.Diag = .{};
        app.dm = dm_mod.DriveManager.init(app.gpa, &app.flight_ac, &diag, app.session().start_mode) catch {
            const msg = std.fmt.bufPrint(&app.plane_error, "{s}", .{diag.text()}) catch app.plane_error[0..0];
            app.plane_error_len = msg.len;
            return false;
        };
        app.channel_state = .{};
        app.reader.resetTouch();
        app.screens.flight.begin(app);
        return true;
    }

    pub fn endFlight(app: *App) void {
        app.stopRecording();
        if (app.dm) |*d| d.deinit();
        app.dm = null;
        app.audio.silence();
    }

    // ---------------------------------------------------------------- gravação
    pub fn recording(app: *const App) bool {
        return app.rec != null;
    }

    pub fn startRecording(app: *App) void {
        if (app.rec != null) return;
        const now = std.Io.Clock.real.now(app.io);
        const secs: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
        // no navegador não há ffmpeg: grava só os dados (w = h = 0 desliga o vídeo)
        const w: u32 = if (platform.in_browser) 0 else @intCast(@max(rl.getRenderWidth(), 0));
        const h: u32 = if (platform.in_browser) 0 else @intCast(@max(rl.getRenderHeight(), 0));
        app.video_acc = 0;
        app.rec = recorder.Recorder.start(app.io, app.gpa, app.paths.recordings, secs, w, h, video_fps) catch |e| {
            app.note("não consegui gravar: {s}", .{@errorName(e)});
            return;
        };
        if (app.rec.?.video_error) |e| {
            app.note("gravando só os dados (vídeo: {s})", .{if (e == error.NoFfmpeg) "instale o ffmpeg" else @errorName(e)});
        } else if (platform.in_browser) {
            app.note("gravando os dados (vídeo só no programa instalado)", .{});
        } else app.note("gravando vídeo e dados", .{});
    }

    pub fn stopRecording(app: *App) void {
        var r = app.rec orelse return;
        app.rec = null;
        const name = if (app.plane) |p| p.loaded.ac.name else "";
        r.finish(app.io, app.files, name) catch |e| {
            app.note("erro ao salvar: {s}", .{@errorName(e)});
            return;
        };
        app.note("salvo em {s}", .{r.dir()});
    }

    /// recado curto no canto da tela (some depois de alguns segundos)
    pub fn note(app: *App, comptime fmt: []const u8, args: anytype) void {
        const m = std.fmt.bufPrint(&app.rec_message, fmt, args) catch app.rec_message[0..0];
        app.rec_message_len = m.len;
        app.rec_message_t = app.time;
    }

    pub fn message(app: *const App) ?[]const u8 {
        if (app.rec_message_len == 0 or app.time - app.rec_message_t > 5) return null;
        return app.rec_message[0..app.rec_message_len];
    }

    /// quadro da tela para o vídeo (depois de desenhar o voo, antes de trocar o buffer). O vídeo
    /// tem 30 quadros por segundo de tempo real: a 60 fps vai um quadro sim, outro não; se o jogo
    /// engasgar, o quadro se repete para o vídeo não acelerar.
    pub fn captureFrame(app: *App, dt: f64) void {
        const r = &(app.rec orelse return);
        if (r.video == null) return;
        app.video_acc += if (std.math.isFinite(dt)) std.math.clamp(dt, 0, 0.5) else 0;
        const period = 1.0 / @as(f64, video_fps);
        if (app.video_acc < period) return;
        var copies: usize = 0;
        while (app.video_acc >= period and copies < 15) : (copies += 1) app.video_acc -= period;
        const img = rl.loadImageFromScreen() catch return;
        defer rl.unloadImage(img);
        const w: u32 = @intCast(@max(img.width, 0));
        const h: u32 = @intCast(@max(img.height, 0));
        if (img.format != .uncompressed_r8g8b8a8) return;
        const bytes: [*]const u8 = @ptrCast(img.data);
        for (0..copies) |_| r.addFrame(app.io, bytes[0 .. @as(usize, w) * h * 4], w, h);
    }

    // ---------------------------------------------------------------- telas
    pub fn top(app: *const App) Id {
        return app.stack[app.depth - 1];
    }

    /// a tela de baixo (a pausa desenha o voo congelado por trás)
    pub fn below(app: *const App) ?Id {
        return if (app.depth >= 2) app.stack[app.depth - 2] else null;
    }

    pub fn go(app: *App, next: Next) void {
        switch (next) {
            .stay => return,
            .open => |id| {
                if (app.depth < app.stack.len) {
                    app.focus[app.depth - 1] = app.ui.focus;
                    app.stack[app.depth] = id;
                    app.depth += 1;
                }
                app.ui.reset();
            },
            .back => if (app.depth > 1) {
                app.depth -= 1;
                app.ui.reset();
                app.ui.focus = app.focus[app.depth - 1];
            },
            .home => {
                app.endFlight();
                app.depth = 1;
                app.stack[0] = .main;
                app.ui.reset();
            },
            .quit => app.quit = true,
        }
        app.saveSettings();
        app.enter(app.top());
    }

    fn enter(app: *App, id: Id) void {
        switch (id) {
            inline else => |t| {
                const S = @TypeOf(@field(app.screens, @tagName(t)));
                if (@hasDecl(S, "enter")) @field(app.screens, @tagName(t)).enter(app);
            },
        }
    }

    pub fn frameOf(app: *App, id: Id, dt: f64) Next {
        return switch (id) {
            inline else => |t| @field(app.screens, @tagName(t)).frame(app, dt),
        };
    }

    /// um quadro do jogo inteiro
    pub fn step(app: *App, dt: f64) void {
        app.time += dt;
        app.sampler.update(app.io, dt);
        if (rl.isKeyPressed(.f3)) app.settings.dev_overlay = !app.settings.dev_overlay;
        if (rl.isKeyPressed(.f11)) app.setFullscreen(!app.settings.fullscreen);
        app.keep_awake.tick(app.io, dt);
        app.ui.stick_nav = app.top() != .control; // no menu de controle o analógico mexe o ponto
        app.reader.touch_enabled = app.top() == .flight; // manches por toque só no voo (nos menus, toque = clique)
        app.ui.begin(dt);
        rl.beginDrawing();
        const next = app.frameOf(app.top(), dt);
        if (app.top() == .flight) app.captureFrame(dt);
        if (app.settings.dev_overlay) dev_overlay.draw(app);
        if (app.ui.feedback) app.audio.click(app.settings.volume);
        app.ui.end();
        rl.endDrawing();
        app.go(next);
    }

    /// o laço do programa nativo, até fechar a janela (no navegador quem chama `step` é a página)
    pub fn run(app: *App) void {
        app.begin();
        while (!rl.windowShouldClose() and !app.quit) app.step(@floatCast(rl.getFrameTime()));
    }

    /// abre o último avião (ou o Convencional) e o menu inicial: o que vem antes do laço
    pub fn begin(app: *App) void {
        if (app.settings.aircraft().len > 0) _ = app.loadPlane(app.settings.aircraft());
        if (app.plane == null and app.lib.entries.len > 0) {
            // o Convencional, se existir; senão o primeiro da lista
            var pick: usize = 0;
            for (app.lib.entries, 0..) |e, i| if (std.mem.indexOf(u8, e.path, "Convencional") != null) {
                pick = i;
                break;
            };
            _ = app.loadPlane(app.lib.entries[pick].path);
        }
        app.enter(.main);
    }
};

//! Toca os sons (raylib). Os .mp3 vão dentro do programa (`assets/`):
//!   helice.mp3  em laço; altura e volume pelo motor (`engine_sound.Engine`)
//!   vento.mp3   em laço; altura e volume pela velocidade do ar (`engine_sound.wind`)
//!   clique.mp3  ao apertar algo nos menus
//! Sem placa de som, tudo vira silêncio sem erro.
//!
//!   var som = Player.init();               // uma vez, depois da janela
//!   som.update(acelerador, volume, dt);    // motor, todo quadro em que deve tocar
//!   som.updateWind(V_ar, volume);          // vento
//!   som.click(volume);                     // menu
//!   som.silence();                         // para os laços (menus, pausa)
const std = @import("std");
const rl = @import("raylib");
const es = @import("engine_sound.zig");

const mp3_engine = @embedFile("../assets/helice.mp3");
const mp3_wind = @embedFile("../assets/vento.mp3");
const mp3_click = @embedFile("../assets/clique.mp3");

/// um som em laço que pausa e volta de onde parou
const Loop = struct {
    music: ?rl.Music = null,
    playing: bool = false,
    started: bool = false,

    fn load(data: []const u8) Loop {
        var m = rl.loadMusicStreamFromMemory(".mp3", data) catch return .{};
        m.looping = true;
        return .{ .music = m };
    }

    fn set(l: *Loop, o: es.Out) void {
        const m = l.music orelse return;
        if (!l.playing) {
            if (l.started) rl.resumeMusicStream(m) else rl.playMusicStream(m);
            l.started = true;
            l.playing = true;
        }
        rl.setMusicPitch(m, o.pitch);
        rl.setMusicVolume(m, o.volume);
        rl.updateMusicStream(m);
    }

    fn pause(l: *Loop) void {
        const m = l.music orelse return;
        if (l.playing) rl.pauseMusicStream(m);
        l.playing = false;
    }

    fn unload(l: *Loop) void {
        if (l.music) |m| rl.unloadMusicStream(m);
        l.music = null;
    }
};

pub const Player = struct {
    engine_loop: Loop = .{},
    wind_loop: Loop = .{},
    click_sound: ?rl.Sound = null,
    engine: es.Engine = .{},
    tuning: es.Tuning = .{},
    wind_tuning: es.WindTuning = .{},
    last: es.Out = .{ .pitch = 1, .volume = 0 },
    last_wind: es.Out = .{ .pitch = 1, .volume = 0 },

    pub fn init() Player {
        rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return .{};
        var p: Player = .{ .engine_loop = Loop.load(mp3_engine), .wind_loop = Loop.load(mp3_wind) };
        if (rl.loadWaveFromMemory(".mp3", mp3_click)) |w| {
            defer rl.unloadWave(w);
            p.click_sound = rl.loadSoundFromWave(w);
        } else |_| {}
        return p;
    }

    pub fn deinit(p: *Player) void {
        p.engine_loop.unload();
        p.wind_loop.unload();
        if (p.click_sound) |s| rl.unloadSound(s);
        p.click_sound = null;
        if (rl.isAudioDeviceReady()) rl.closeAudioDevice();
    }

    pub fn available(p: *const Player) bool {
        return p.engine_loop.music != null;
    }

    /// motor: `level` 0..1 (acelerador ou rpm relativo); `master` 0..1
    pub fn update(p: *Player, level: f64, master: f64, dt: f64) void {
        p.last = p.engine.step(p.tuning, level, master, dt);
        p.engine_loop.set(p.last);
    }

    /// vento pela velocidade do ar (m/s)
    pub fn updateWind(p: *Player, Va: f64, master: f64) void {
        p.last_wind = es.wind(p.wind_tuning, Va, master);
        p.wind_loop.set(p.last_wind);
    }

    pub fn click(p: *Player, master: f64) void {
        const s = p.click_sound orelse return;
        rl.setSoundVolume(s, @floatCast(0.6 * std.math.clamp(if (std.math.isFinite(master)) master else 0, 0, 1)));
        rl.playSound(s);
    }

    pub fn silence(p: *Player) void {
        p.engine.level = 0;
        p.engine_loop.pause();
        p.wind_loop.pause();
    }
};

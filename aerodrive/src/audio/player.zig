//! Toca o som da hélice (raylib): o .mp3 vai dentro do programa (`assets/helice.mp3`), em laço.
//! A altura e o volume vêm de `engine_sound.zig`. Sem placa de som, tudo vira silêncio sem erro.
//!
//!   var som = Player.init();          // uma vez, depois da janela
//!   som.update(acelerador, volume, dt);   // todo quadro em que deve tocar
//!   som.silence();                    // nos menus
const std = @import("std");
const rl = @import("raylib");
const es = @import("engine_sound.zig");

const mp3 = @embedFile("../assets/helice.mp3");

pub const Player = struct {
    music: ?rl.Music = null,
    engine: es.Engine = .{},
    tuning: es.Tuning = .{},
    playing: bool = false,
    started: bool = false,
    last: es.Out = .{ .pitch = 1, .volume = 0 },

    pub fn init() Player {
        rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return .{};
        var m = rl.loadMusicStreamFromMemory(".mp3", mp3) catch return .{};
        m.looping = true;
        return .{ .music = m };
    }

    pub fn deinit(p: *Player) void {
        if (p.music) |m| rl.unloadMusicStream(m);
        p.music = null;
        if (rl.isAudioDeviceReady()) rl.closeAudioDevice();
    }

    pub fn available(p: *const Player) bool {
        return p.music != null;
    }

    /// `level` 0..1 (acelerador ou rpm relativo); `master` 0..1
    pub fn update(p: *Player, level: f64, master: f64, dt: f64) void {
        p.last = p.engine.step(p.tuning, level, master, dt);
        const m = p.music orelse return;
        if (!p.playing) {
            if (p.started) rl.resumeMusicStream(m) else rl.playMusicStream(m);
            p.started = true;
            p.playing = true;
        }
        rl.setMusicPitch(m, p.last.pitch);
        rl.setMusicVolume(m, p.last.volume);
        rl.updateMusicStream(m);
    }

    pub fn silence(p: *Player) void {
        p.engine.level = 0;
        const m = p.music orelse return;
        if (p.playing) rl.pauseMusicStream(m);
        p.playing = false;
    }
};

//! Não deixa a tela escurecer nem apagar com o jogo aberto. Jogar só com o controle não conta como
//! "atividade" para o sistema (só mouse e teclado), então ele escurece no meio do voo.
//!
//! Linux: segura um bloqueio de ociosidade com um processo que fica rodando até o jogo fechar
//! (o primeiro que existir: `gnome-session-inhibit`, `systemd-inhibit`) e, a cada 30 s, avisa o
//! protetor de tela (`xdg-screensaver reset`). Sem nenhum deles, nada acontece (sem erro).
//!
//!   var acordado = KeepAwake.start(io);
//!   acordado.tick(io, dt);   // todo quadro
//!   acordado.stop(io);
const std = @import("std");
const builtin = @import("builtin");

/// os segurões, em ordem de preferência (cada um roda `sleep infinity` com o bloqueio)
pub const holders = [_][]const []const u8{
    &.{ "gnome-session-inhibit", "--inhibit", "idle", "--app-id", "aerodrive", "--reason", "jogando", "sleep", "infinity" },
    &.{ "systemd-inhibit", "--what=idle", "--who=AeroDrive", "--why=jogando", "--mode=block", "sleep", "infinity" },
};

pub const KeepAwake = struct {
    holder: ?std.process.Child = null,
    since_reset: f64 = 0,
    reset_ok: bool = true, // `xdg-screensaver` existe?

    pub fn start(io: std.Io) KeepAwake {
        var k: KeepAwake = .{};
        if (builtin.os.tag != .linux) return k;
        for (holders) |argv| {
            k.holder = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch continue;
            break;
        }
        return k;
    }

    /// passou a hora de avisar o protetor de tela? (a cada 30 s)
    pub fn due(k: *KeepAwake, dt: f64) bool {
        k.since_reset += if (std.math.isFinite(dt) and dt > 0) @min(dt, 3600) else 0;
        if (k.since_reset < 30) return false;
        k.since_reset = 0;
        return true;
    }

    pub fn tick(k: *KeepAwake, io: std.Io, dt: f64) void {
        if (builtin.os.tag != .linux or !k.reset_ok or !k.due(dt)) return;
        var c = std.process.spawn(io, .{ .argv = &.{ "xdg-screensaver", "reset" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {
            k.reset_ok = false;
            return;
        };
        _ = c.wait(io) catch {};
    }

    pub fn active(k: *const KeepAwake) bool {
        return k.holder != null;
    }

    pub fn stop(k: *KeepAwake, io: std.Io) void {
        if (k.holder) |*h| {
            h.kill(io);
        }
        k.holder = null;
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;
const fz = @import("../util/fuzz.zig");

fn fuzzTick(_: void, src: *fz.Src) anyerror!void {
    var k: KeepAwake = .{}; // só as contas do relógio (sem chamar processos)
    while (!src.chance(8)) {
        _ = k.due(src.any());
        try testing.expect(std.math.isFinite(k.since_reset) and k.since_reset >= 0 and k.since_reset < 30);
    }
}

test "fuzz: relógio do protetor de tela" {
    try fz.check({}, fuzzTick, .{});
}

test "liga e desliga sem travar, com ou sem os programas no sistema" {
    var k = KeepAwake.start(testing.io);
    k.tick(testing.io, 31); // tenta o xdg-screensaver (se não existir, desiste calado)
    k.tick(testing.io, std.math.nan(f64));
    k.stop(testing.io);
    try testing.expect(!k.active());
}

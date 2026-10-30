//! A interface do aerosim em Zig (raylib e raygui), com as contas no núcleo.
//!
//!   aerosim [avião.json] [LxA] [aba=N]
//!   aerosim --shot <saída.png> [avião.json] [LxA] [aba=N] [rolar=PIXELS]
//!
//! No modo --shot a tela é desenhada alguns quadros e salva numa imagem (para os prints sem interação).
const std = @import("std");
const ui = @import("ui");
const screen_mod = @import("screen.zig");

pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = std.Io.Threaded.global_single_threaded;

/// abre a janela do aerosim
pub fn main(init: std.process.Init) !void {
    var screen: screen_mod.Screen = .{};
    try ui.app.run(init, "aerosim", &screen);
}

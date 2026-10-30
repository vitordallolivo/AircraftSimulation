//! A interface do aeroopt em Zig (raylib e raygui), com as peças da interface do aerosim.
//!
//!   aeroopt [LxA]
//!   aeroopt --shot <saída.png> [LxA] [rolar=PIXELS]
//!
//! No modo --shot a tela é desenhada alguns quadros e salva numa imagem (para os prints sem interação).
const std = @import("std");
const ui = @import("ui");
const screen_mod = @import("screen.zig");

pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = std.Io.Threaded.global_single_threaded;

/// abre a janela do aeroopt
pub fn main(init: std.process.Init) !void {
    var screen: screen_mod.Screen = .{};
    try ui.app.run(init, "aeroopt", &screen);
}

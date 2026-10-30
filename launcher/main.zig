//! A tela inicial do AircraftSimulation instalado (o mesmo menu do site): escolhe e abre o aerosim, o aeroopt ou
//! o AeroDrive.
//!
//!   aircraftsimulation [LxA]
//!   aircraftsimulation --shot <saída.png> [LxA]
const std = @import("std");
const ui = @import("ui");
const screen_mod = @import("screen.zig");

pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = std.Io.Threaded.global_single_threaded;

/// abre a tela inicial
pub fn main(init: std.process.Init) !void {
    var screen: screen_mod.Screen = .{};
    try ui.app.run(init, "AircraftSimulation", &screen);
}

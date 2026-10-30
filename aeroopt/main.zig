//! A interface do aeroopt em Zig (raylib e raygui), com as peças da interface do aerosim.
//!
//!   aeroopt [LxA]
//!   aeroopt --shot <saída.png> [LxA] [rolar=PIXELS]
//!
//! No modo --shot a tela é desenhada alguns quadros e salva numa imagem (para os prints sem interação).
const std = @import("std");
const ui = @import("ui");
const screen_mod = @import("screen.zig");

// a `Io` padrão (a do `std.debug.print`): no navegador a de `ui/browser_io.zig`, porque a `Threaded` não compila
// para emscripten
pub const std_options_debug_io: std.Io = ui.system.io();
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (ui.system.in_browser) null else std.Io.Threaded.global_single_threaded;

/// no navegador a memória do `std.heap.page_allocator` vem do `malloc` do emscripten: o alocador de wasm do Zig
/// cresce a memória sem avisar o JS, e o WebGL segue lendo a visão antiga dela (a tela sai em branco)
pub const os = if (ui.system.in_browser) struct {
    pub const heap = struct {
        pub const page_allocator = std.heap.c_allocator;
    };
} else struct {};

/// no navegador o `main` é outro: sem linha de comando, e o navegador chama cada quadro
pub const main = if (ui.system.in_browser) browserMain else nativeMain;

/// abre a janela do aeroopt
fn nativeMain(init: std.process.Init) !void {
    var screen: screen_mod.Screen = .{};
    try ui.app.run(init, "aeroopt", &screen);
}

var browser_screen: screen_mod.Screen = .{};

/// o aeroopt na página (o estado fica fora da pilha: o `main` volta antes do primeiro quadro)
fn browserMain() !void {
    try ui.app.runBrowser("aeroopt", &browser_screen);
}

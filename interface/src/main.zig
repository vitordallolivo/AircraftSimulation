//! A interface do aerosim e do aeroopt em Zig: abre a janela e desenha a tela pedida.
//!
//!   aircraftsimulation [aerosim|aeroopt] [claro|escuro] [LxA]
//!   aircraftsimulation --shot <saída.png> [aerosim|aeroopt] [claro|escuro] [LxA] [rolar=PIXELS]
//!
//! No modo --shot a tela é desenhada alguns quadros e salva numa imagem (para os prints sem interação).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("ui/theme.zig");
const widgets = @import("ui/widgets.zig");
const aerosim_screen = @import("screens/aerosim.zig");
const aeroopt_screen = @import("screens/aeroopt.zig");

pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = std.Io.Threaded.global_single_threaded;

const Program = enum { aerosim, aeroopt };

const Args = struct {
    program: Program = .aerosim,
    mode: theme.Mode = .claro,
    shot: ?[:0]const u8 = null,
    width: i32 = 1500,
    height: i32 = 950,
    scroll: f32 = 0, // rolagem da área dos gráficos no print
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const value = argv[i];
        if (std.mem.eql(u8, value, "--shot")) {
            i += 1;
            if (i >= argv.len) return error.BadArgs;
            args.shot = argv[i];
        } else if (std.meta.stringToEnum(Program, value)) |program| {
            args.program = program;
        } else if (std.meta.stringToEnum(theme.Mode, value)) |mode| {
            args.mode = mode;
        } else if (std.mem.startsWith(u8, value, "rolar=")) {
            args.scroll = std.fmt.parseFloat(f32, value[6..]) catch return error.BadArgs;
        } else if (std.mem.indexOfScalar(u8, value, 'x')) |cut| {
            args.width = std.fmt.parseInt(i32, value[0..cut], 10) catch return error.BadArgs;
            args.height = std.fmt.parseInt(i32, value[cut + 1 ..], 10) catch return error.BadArgs;
        } else return error.BadArgs;
    }
    return args;
}

/// abre a janela e desenha até fechar (ou uma foto, com --shot)
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv) catch {
        std.debug.print("uso: aircraftsimulation [aerosim|aeroopt] [claro|escuro] [LxA]\n     aircraftsimulation --shot <saída.png> [aerosim|aeroopt] [claro|escuro] [LxA] [rolar=PIXELS]\n", .{});
        std.process.exit(2);
    };
    const shot = args.shot != null;
    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_resizable = true, .vsync_hint = !shot });
    rl.initWindow(args.width, args.height, if (args.program == .aerosim) "aerosim" else "aeroopt");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    theme.use(args.mode);
    var ui = try widgets.Ui.init();
    defer ui.deinit();
    var aerosim: aerosim_screen.Screen = .{};
    aerosim.init();
    aerosim.runAnalysis();
    aerosim.scroll = args.scroll;
    var aeroopt: aeroopt_screen.Screen = .{};
    aeroopt.init();
    aeroopt.scroll = args.scroll;

    var frames: usize = 0;
    while (!rl.windowShouldClose()) : (frames += 1) {
        const width: f32 = @floatFromInt(rl.getScreenWidth());
        const height: f32 = @floatFromInt(rl.getScreenHeight());
        ui.beginFrame();
        if (shot) ui.wheel = 0; // o print não rola sozinho
        rl.beginDrawing();
        switch (args.program) {
            .aerosim => aerosim.draw(&ui, width, height),
            .aeroopt => aeroopt.draw(&ui, width, height),
        }
        rl.endDrawing();
        if (shot and frames == 3) {
            const image = try rl.loadImageFromScreen();
            defer rl.unloadImage(image);
            if (!rl.exportImage(image, args.shot.?)) {
                std.debug.print("erro: não consegui gravar '{s}'\n", .{args.shot.?});
                std.process.exit(1);
            }
            return;
        }
    }
}

//! O que os dois programas têm igual em volta da tela: a linha de comando, a janela e o laço de desenho, com o
//! print sem interação do `--shot`.
//!
//!   <programa> [LxA]
//!   <programa> --shot <saída.png> [arquivo] [LxA] [aba=N] [rolar=PIXELS] [acao=NOME]
//!
//! `arquivo` vai para o `openFile` da tela (.json, .dat ou uma polar); `acao=NOME` (ou `acao=A,B`) chama `command` da tela para cada nome,
//! se ela tiver (abre um diálogo para o print, por exemplo).
const std = @import("std");
const rl = @import("raylib");
const widgets = @import("widgets.zig");

pub const Args = struct {
    shot: ?[:0]const u8 = null,
    width: i32 = 1500,
    height: i32 = 950,
    scroll: f32 = 0, // rolagem da área dos gráficos no print
    tab: ?usize = null, // aba aberta no começo (aba=N), se a tela tiver `selectTab`
    file: ?[:0]const u8 = null, // um arquivo para abrir, se a tela tiver `openFile`
    action: ?[:0]const u8 = null, // acao=NOME, se a tela tiver `command`
};

/// lê a linha de comando (o primeiro item é o nome do programa)
pub fn parseArgs(argv: []const [:0]const u8) !Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const value = argv[i];
        if (std.mem.eql(u8, value, "--shot")) {
            i += 1;
            if (i >= argv.len) return error.BadArgs;
            args.shot = argv[i];
        } else if (std.mem.startsWith(u8, value, "acao=")) {
            args.action = value[5..];
        } else if (isFile(value)) {
            args.file = value;
        } else if (std.mem.startsWith(u8, value, "aba=")) {
            args.tab = std.fmt.parseInt(usize, value[4..], 10) catch return error.BadArgs;
        } else if (std.mem.startsWith(u8, value, "rolar=")) {
            args.scroll = std.fmt.parseFloat(f32, value[6..]) catch return error.BadArgs;
        } else if (std.mem.indexOfScalar(u8, value, 'x')) |cut| {
            args.width = std.fmt.parseInt(i32, value[0..cut], 10) catch return error.BadArgs;
            args.height = std.fmt.parseInt(i32, value[cut + 1 ..], 10) catch return error.BadArgs;
        } else return error.BadArgs;
    }
    return args;
}

fn isFile(value: []const u8) bool {
    for ([_][]const u8{ ".json", ".dat", ".txt", ".csv", ".pol" }) |extension| if (std.ascii.endsWithIgnoreCase(value, extension)) return true;
    return false;
}

/// abre a janela `title` e desenha `screen` até fechar (ou uma foto, com --shot); `screen` é um ponteiro para uma
/// tela com `start()` (chamado com a janela aberta), `draw(ui, largura, altura)` e o campo `scroll`
pub fn run(init: std.process.Init, title: [:0]const u8, screen: anytype) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv) catch {
        std.debug.print("uso: {s} [LxA]\n     {s} --shot <saída.png> [arquivo] [LxA] [aba=N] [rolar=PIXELS] [acao=NOME]\n", .{ title, title });
        std.process.exit(2);
    };
    const shot = args.shot != null;
    if (shot) @import("jobs.zig").synchronous = true; // o print sai com as contas prontas
    rl.setTraceLogLevel(.err);
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_resizable = true, .vsync_hint = !shot });
    rl.initWindow(args.width, args.height, title);
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var ui = try widgets.Ui.init();
    defer ui.deinit();
    screen.start();
    screen.scroll = args.scroll;
    if (args.file) |path| {
        if (@hasDecl(@TypeOf(screen.*), "openFile")) screen.openFile(path);
    }
    if (args.tab) |tab| {
        if (@hasDecl(@TypeOf(screen.*), "selectTab")) screen.selectTab(tab);
    }
    if (args.action) |actions| { // acao=a,b: um comando depois do outro
        var list = std.mem.splitScalar(u8, actions, ',');
        while (list.next()) |action| {
            if (@hasDecl(@TypeOf(screen.*), "command")) screen.command(action);
        }
    }

    var frames: usize = 0;
    while (!rl.windowShouldClose()) : (frames += 1) {
        const width: f32 = @floatFromInt(rl.getScreenWidth());
        const height: f32 = @floatFromInt(rl.getScreenHeight());
        ui.beginFrame();
        if (shot) ui.wheel = 0; // o print não rola sozinho
        rl.beginDrawing();
        screen.draw(&ui, width, height);
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

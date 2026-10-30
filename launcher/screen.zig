//! A tela inicial do programa instalado: a mesma do site (`web/index.html`), no estilo de uma BIOS (fundo azul,
//! moldura dupla, letra de máquina de escrever), agora abrindo os programas do PC. Escolhe-se com as setas ou o
//! mouse e abre-se com Enter ou clique: o aerosim, o aeroopt, o AeroDrive, ou o AeroDrive já com um avião (.json).
//! Os programas abrem em processos próprios, com a pasta dos dados (`data/`) como pasta de trabalho.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const widgets = ui_kit.widgets;
const theme = ui_kit.theme;
const places = @import("places.zig");

// as cores do site (web/index.html)
const blue = theme.hex(0x0000aa);
const gray = theme.hex(0xc0c0c0);
const white = theme.hex(0xffffff);
const faded = theme.hex(0x7f7fd4);

const Action = enum { aerosim, aeroopt, aerodrive, load, quit };

const Item = struct {
    caption: [:0]const u8,
    help: [:0]const u8,
    action: Action,
};

const items = [_]Item{
    .{ .caption = "aerosim — projetar", .help = "Projetar o avião: dimensionamento, aerodinâmica, estabilidade, desempenho e cargas.", .action = .aerosim },
    .{ .caption = "aeroopt — otimizar", .help = "Otimização do projeto para a competição.", .action = .aeroopt },
    .{ .caption = "AeroDrive — pilotar o avião", .help = "Simulação em tempo real: escolha um avião e pilote com teclado ou controle.", .action = .aerodrive },
    .{ .caption = "Carregar avião (.json)", .help = "Escolha o .json de um avião feito no aerosim; o AeroDrive abre já com ele.", .action = .load },
    .{ .caption = "Sair", .help = "Fecha a tela inicial (os programas abertos continuam).", .action = .quit },
};

const row_height: f32 = 34;
const font_size: f32 = 20;

pub const Screen = struct {
    selected: usize = 0,
    scroll: f32 = 0, // pedido pelo laço comum; a tela inicial não rola
    exe_dir: []const u8 = ".",
    root: ?[]const u8 = null, // a pasta com data/
    message: [300:0]u8 = [_:0]u8{0} ** 300,
    files: ui_kit.dialogs.FilePicker = .{},
    io: ?std.Io = null, // o Io do processo (abrir outro programa precisa dele); o laço comum preenche

    /// acha a pasta do executável e a dos dados
    pub fn start(screen: *Screen) void {
        const gpa = std.heap.page_allocator;
        if (screen.io == null) screen.io = io();
        screen.exe_dir = std.process.executableDirPathAlloc(io(), gpa) catch ".";
        screen.root = places.dataRoot(gpa, io(), screen.exe_dir);
        if (screen.root == null) screen.setMessage("não achei a pasta data/ (os exemplos de avião)", .{});
    }

    fn setMessage(screen: *Screen, comptime format: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&screen.message, format, args) catch {};
    }

    /// abre o programa `program` (com o avião `file`, se houver) num processo próprio
    fn launch(screen: *Screen, program: places.Program, file: ?[]const u8) void {
        const gpa = std.heap.page_allocator;
        const path = places.find(gpa, io(), screen.exe_dir, screen.root, program) orelse
            return screen.setMessage("não achei o {s} ao lado da tela inicial", .{@tagName(program)});
        var argv: [2][]const u8 = .{ path, "" };
        var count: usize = 1;
        if (file) |chosen| {
            argv[1] = chosen;
            count = 2;
        }
        _ = std.process.spawn(screen.io orelse io(), .{ .argv = argv[0..count], .cwd = if (screen.root) |folder| .{ .path = folder } else .inherit }) catch |err|
            return screen.setMessage("não abriu o {s}: {s}", .{ @tagName(program), @errorName(err) });
        screen.setMessage("abrindo o {s}...", .{@tagName(program)});
    }

    fn activate(screen: *Screen, index: usize) void {
        switch (items[index].action) {
            .aerosim => screen.launch(.aerosim, null),
            .aeroopt => screen.launch(.aeroopt, null),
            .aerodrive => screen.launch(.aerodrive, null),
            .load => {
                var buffer: [1024]u8 = undefined;
                const folder = if (screen.root) |root| std.fmt.bufPrint(&buffer, "{s}/data/aircraft", .{root}) catch "." else ".";
                screen.files.show("Carregar avião (.json)", folder, &.{".json"});
            },
            .quit => std.process.exit(0),
        }
    }

    /// desenha a tela inicial e trata o teclado e o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(blue);
        const font = ui.fonts.mono;
        if (!screen.files.open) {
            if (rl.isKeyPressed(.down) or rl.isKeyPressedRepeat(.down)) screen.selected = (screen.selected + 1) % items.len;
            if (rl.isKeyPressed(.up) or rl.isKeyPressedRepeat(.up)) screen.selected = (screen.selected + items.len - 1) % items.len;
            if (rl.isKeyPressed(.escape)) screen.selected = 0;
            if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) screen.activate(screen.selected);
        }
        // a moldura dupla, no meio da janela
        const box_width = @min(width - 32, 760);
        const box_height: f32 = 150 + row_height * @as(f32, @floatFromInt(items.len)) + 70;
        const box: rl.Rectangle = .{ .x = (width - box_width) / 2, .y = @max(16, (height - box_height) / 2 - 16), .width = box_width, .height = box_height };
        rl.drawRectangleLinesEx(box, 2, white);
        rl.drawRectangleLinesEx(.{ .x = box.x + 6, .y = box.y + 6, .width = box.width - 12, .height = box.height - 12 }, 2, white);
        centered(font, "AircraftSimulation", box, box.y + 34, 26, white);
        centered(font, "dimensionar uma aeronave e voar o resultado", box, box.y + 70, 17, gray);
        var y = box.y + 118;
        for (items, 0..) |item, k| {
            const row: rl.Rectangle = .{ .x = box.x + 36, .y = y, .width = box.width - 72, .height = row_height };
            if (!screen.files.open and ui.hovering(row) and (rl.getMouseDelta().x != 0 or rl.getMouseDelta().y != 0)) screen.selected = k;
            const active = k == screen.selected;
            if (active) rl.drawRectangleRec(row, gray);
            var line: [96:0]u8 = undefined;
            const text = widgets.format(&line, "{s}{s}", .{ if (active) "> " else "  ", item.caption });
            theme.text(font, text, row.x + 10, row.y + (row_height - font_size) / 2, font_size, if (active) blue else gray);
            if (!screen.files.open and ui.clickedIn(row)) {
                screen.selected = k;
                screen.activate(k);
            }
            y += row_height;
        }
        theme.text(font, items[screen.selected].help, box.x + 36, y + 22, 14, gray);
        theme.text(font, std.mem.sliceTo(&screen.message, 0), box.x + 36, y + 46, 14, faded);
        // o rodapé com as teclas
        const footer = "setas: escolher    Enter: abrir    Esc: voltar ao começo";
        centered(font, footer, .{ .x = 0, .y = 0, .width = width, .height = height }, box.y + box.height + 14, 15, gray);
        if (screen.files.draw(ui, .{ .x = 0, .y = 0, .width = width, .height = height })) |path| screen.launch(.aerodrive, path);
    }
};

/// texto centrado na largura de `area`, na altura `y`
fn centered(font: rl.Font, text: [:0]const u8, area: rl.Rectangle, y: f32, size: f32, color: rl.Color) void {
    const w = theme.textWidth(font, text, size);
    theme.text(font, text, area.x + (area.width - w) / 2, y, size, color);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

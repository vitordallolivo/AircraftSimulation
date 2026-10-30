//! As janelas por cima da tela: o seletor de arquivo (navega pelas pastas e mostra só as extensões pedidas; para
//! abrir, o equivalente do `QFileDialog.getOpenFileName`, e para salvar, do `getSaveFileName`, com o nome digitado) e a pergunta de um texto curto (o `QInputDialog.getText`). Cada
//! uma é uma struct com `show` para abrir e `draw` a cada quadro, que devolve a resposta uma vez, quando ela chega.
//! Enquanto uma janela está aberta, ela fica com o clique e a roda: a tela de baixo não reage.
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

const max_entries = 512;
const row_height: f32 = 26;

/// o seletor de arquivo
pub const FilePicker = struct {
    open: bool = false,
    title: [96:0]u8 = [_:0]u8{0} ** 96,
    folder: [std.fs.max_path_bytes]u8 = undefined,
    folder_len: usize = 0,
    extensions: []const []const u8 = &.{},
    names: [max_entries][]const u8 = undefined,
    is_folder: [max_entries]bool = undefined,
    count: usize = 0,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    scroll: f32 = 0,
    chosen: [std.fs.max_path_bytes]u8 = undefined,
    examples: [std.fs.max_path_bytes]u8 = undefined, // a pasta de começo (o atalho "Exemplos")
    examples_len: usize = 0,
    path_text: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes, // a pasta digitada
    editing_path: bool = false,
    saving: bool = false, // salvar: o nome se digita (um arquivo da lista preenche o nome)
    file_name: [128:0]u8 = [_:0]u8{0} ** 128,
    editing_name: bool = false,

    /// abre o seletor na pasta `start` (ou na atual, se ela não existir), mostrando as pastas e os arquivos com uma
    /// das `extensions` (".dat", ...)
    pub fn show(picker: *FilePicker, title: []const u8, start: []const u8, extensions: []const []const u8) void {
        _ = widgets.format(&picker.title, "{s}", .{title});
        picker.extensions = extensions;
        if (!picker.enter(start)) _ = picker.enter(".");
        @memcpy(picker.examples[0..picker.folder_len], picker.folder[0..picker.folder_len]);
        picker.examples_len = picker.folder_len;
        picker.saving = false;
        picker.open = true;
    }

    /// abre o seletor para salvar, na pasta `start`, com o nome sugerido `name`; a extensão `extensions[0]` entra
    /// no nome se faltar
    pub fn showSave(picker: *FilePicker, title: []const u8, start: []const u8, extensions: []const []const u8, name: []const u8) void {
        picker.show(title, start, extensions);
        picker.saving = true;
        picker.editing_name = true;
        picker.file_name = [_:0]u8{0} ** 128;
        const length = @min(name.len, 127);
        @memcpy(picker.file_name[0..length], name[0..length]);
    }

    /// entra na pasta `path` (relativa à atual do programa ou absoluta) e lê o que há nela
    fn enter(picker: *FilePicker, path: []const u8) bool {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = std.Io.Dir.cwd().realPathFile(io(), path, &buffer) catch return false;
        var dir = std.Io.Dir.cwd().openDir(io(), buffer[0..length], .{ .iterate = true }) catch return false;
        defer dir.close(io());
        @memcpy(picker.folder[0..length], buffer[0..length]);
        picker.folder_len = length;
        picker.path_text = [_:0]u8{0} ** std.fs.max_path_bytes;
        @memcpy(picker.path_text[0..length], buffer[0..length]);
        picker.editing_path = false;
        _ = picker.arena.reset(.retain_capacity);
        const allocator = picker.arena.allocator();
        picker.count = 0;
        picker.scroll = 0;
        var iterator = dir.iterate();
        while (iterator.next(io()) catch null) |entry| {
            if (picker.count == max_entries or entry.name.len == 0 or entry.name[0] == '.') continue;
            const folder = entry.kind == .directory;
            if (!folder and !picker.accepts(entry.name)) continue;
            picker.names[picker.count] = allocator.dupe(u8, entry.name) catch continue;
            picker.is_folder[picker.count] = folder;
            picker.count += 1;
        }
        picker.sort();
        return true;
    }

    fn accepts(picker: *const FilePicker, name: []const u8) bool {
        for (picker.extensions) |extension| if (std.ascii.endsWithIgnoreCase(name, extension)) return true;
        return picker.extensions.len == 0;
    }

    /// pastas primeiro, depois os arquivos, cada grupo em ordem alfabética
    fn sort(picker: *FilePicker) void {
        if (picker.count < 2) return; // pasta vazia (ou com um item só): nada a ordenar
        for (1..picker.count) |i| {
            var k = i;
            while (k > 0 and before(picker.is_folder[k], picker.names[k], picker.is_folder[k - 1], picker.names[k - 1])) : (k -= 1) {
                std.mem.swap([]const u8, &picker.names[k - 1], &picker.names[k]);
                std.mem.swap(bool, &picker.is_folder[k - 1], &picker.is_folder[k]);
            }
        }
    }

    fn before(folder_a: bool, name_a: []const u8, folder_b: bool, name_b: []const u8) bool {
        if (folder_a != folder_b) return folder_a;
        return std.ascii.lessThanIgnoreCase(name_a, name_b);
    }

    /// desenha o seletor por cima de `screen`; devolve o caminho escolhido (vale até a próxima escolha)
    pub fn draw(picker: *FilePicker, ui: *widgets.Ui, screen: rl.Rectangle) ?[]const u8 {
        if (!picker.open) return null;
        if (rl.isKeyPressed(.escape)) { // Esc cancela
            picker.open = false;
            return null;
        }
        rl.drawRectangleRec(screen, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const box: rl.Rectangle = .{ .x = screen.x + (screen.width - 640) / 2, .y = screen.y + 60, .width = 640, .height = @min(screen.height - 120, 620) };
        const inner = widgets.card(ui, box, std.mem.sliceTo(&picker.title, 0));
        // a pasta: dá para digitar outra (Enter entra nela) ou ir por um atalho
        const folder = picker.folder[0..picker.folder_len];
        const path_box: rl.Rectangle = .{ .x = inner.x + 6, .y = inner.y + 2, .width = inner.width - 12, .height = 28 };
        if (rg.textBox(path_box, &picker.path_text, picker.editing_path)) {
            if (picker.editing_path) {
                var typed: [std.fs.max_path_bytes]u8 = undefined;
                const text = std.mem.sliceTo(&picker.path_text, 0);
                @memcpy(typed[0..text.len], text);
                if (!picker.enter(expandHome(&typed, text.len))) picker.editing_path = false;
            } else picker.editing_path = true;
        }
        const shortcuts = [_][:0]const u8{ "Exemplos", "Pasta pessoal", "Pasta atual", "Raiz /" };
        var shortcut_x = inner.x + 6;
        for (shortcuts, 0..) |caption, k| {
            const shortcut_width = theme.textWidth(ui.fonts.regular, caption, 14) + 24;
            if (button(ui, .{ .x = shortcut_x, .y = inner.y + 36, .width = shortcut_width, .height = 26 }, caption)) {
                var target: [std.fs.max_path_bytes]u8 = undefined;
                const path: []const u8 = switch (k) {
                    0 => picker.examples[0..picker.examples_len],
                    1 => home(&target),
                    2 => ".",
                    else => "/",
                };
                _ = picker.enter(path);
            }
            shortcut_x += shortcut_width + 8;
        }
        const footer: f32 = if (picker.saving) 96 else 52;
        const list: rl.Rectangle = .{ .x = inner.x + 6, .y = inner.y + 70, .width = inner.width - 12, .height = inner.height - 70 - footer };
        widgets.rounded(list, 6, theme.colors.background);
        // a primeira linha sobe uma pasta
        const total = @as(f32, @floatFromInt(picker.count + 1)) * row_height;
        if (ui.hovering(list)) picker.scroll = std.math.clamp(picker.scroll - ui.wheel * 3 * row_height, 0, @max(0, total - list.height));
        var picked: ?[]const u8 = null;
        var go_to: ?usize = null; // índice + 1; 0 = subir
        ui.pushClip(list);
        var y = list.y + 2 - picker.scroll;
        for (0..picker.count + 1) |row| {
            const line: rl.Rectangle = .{ .x = list.x + 2, .y = y, .width = list.width - 4, .height = row_height };
            const visible = line.y + line.height > list.y and line.y < list.y + list.height;
            if (visible) {
                if (ui.hovering(line)) widgets.rounded(line, 5, theme.colors.hover);
                var label: [300:0]u8 = undefined;
                const text = if (row == 0) widgets.format(&label, "..  (pasta de cima)", .{}) else if (picker.is_folder[row - 1]) widgets.format(&label, "    {s}/", .{picker.names[row - 1]}) else widgets.format(&label, "    {s}", .{picker.names[row - 1]});
                theme.text(ui.fonts.regular, text, line.x + 8, line.y + 5, 14, if (row == 0 or picker.is_folder[row - 1]) theme.colors.accent else theme.colors.ink);
                if (row > 0 and picker.is_folder[row - 1]) widgets.disclosure(line.x + 14, line.y + line.height / 2, 8, false, theme.colors.accent);
                if (ui.clickedIn(line)) go_to = row;
            }
            y += row_height;
        }
        ui.popClip();
        if (go_to) |row| {
            if (row == 0) {
                const parent = std.fs.path.dirname(folder) orelse folder;
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                @memcpy(buffer[0..parent.len], parent);
                _ = picker.enter(buffer[0..parent.len]);
            } else if (picker.is_folder[row - 1]) {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const next = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ folder, picker.names[row - 1] }) catch folder;
                _ = picker.enter(next);
            } else if (picker.saving) {
                picker.file_name = [_:0]u8{0} ** 128;
                const name = picker.names[row - 1];
                @memcpy(picker.file_name[0..@min(name.len, 127)], name[0..@min(name.len, 127)]);
            } else {
                const path = std.fmt.bufPrint(&picker.chosen, "{s}/{s}", .{ folder, picker.names[row - 1] }) catch null;
                if (path) |chosen| {
                    picker.open = false;
                    picked = chosen;
                }
            }
        }
        if (picker.saving) {
            theme.text(ui.fonts.regular, "nome:", inner.x + 10, box.y + box.height - 84, 14, theme.colors.label);
            const name_box: rl.Rectangle = .{ .x = inner.x + 60, .y = box.y + box.height - 90, .width = inner.width - 70, .height = 30 };
            if (rg.textBox(name_box, &picker.file_name, picker.editing_name)) picker.editing_name = !picker.editing_name;
            if (widgets.primaryButton(ui, .{ .x = box.x + box.width - 250, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "Salvar", std.mem.sliceTo(&picker.file_name, 0).len > 0)) {
                const name = std.mem.sliceTo(&picker.file_name, 0);
                const extension = if (picker.extensions.len > 0 and std.fs.path.extension(name).len == 0) picker.extensions[0] else "";
                if (std.fmt.bufPrint(&picker.chosen, "{s}/{s}{s}", .{ folder, name, extension })) |chosen| {
                    picker.open = false;
                    picked = chosen;
                } else |_| {}
            }
        }
        var extension_text: [96:0]u8 = undefined;
        var writer: std.Io.Writer = .fixed(extension_text[0..95]);
        writer.writeAll("mostra: ") catch {};
        for (picker.extensions, 0..) |extension, k| writer.print("{s}*{s}", .{ if (k > 0) " " else "", extension }) catch {};
        extension_text[writer.end] = 0;
        theme.text(ui.fonts.regular, extension_text[0..writer.end :0], inner.x + 10, box.y + box.height - 38, 13, theme.colors.muted);
        if (button(ui, .{ .x = box.x + box.width - 130, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "Cancelar")) picker.open = false;
        // o resto da tela não recebe este clique nem a roda
        ui.click_taken = true;
        ui.wheel = 0;
        return picked;
    }
};

/// a pergunta de um texto curto (um código, um nome)
pub const TextPrompt = struct {
    open: bool = false,
    title: [96:0]u8 = [_:0]u8{0} ** 96,
    question: [96:0]u8 = [_:0]u8{0} ** 96,
    text: [64:0]u8 = [_:0]u8{0} ** 64,

    /// abre a pergunta com o texto inicial `initial`
    pub fn show(prompt: *TextPrompt, title: []const u8, question: []const u8, initial: []const u8) void {
        _ = widgets.format(&prompt.title, "{s}", .{title});
        _ = widgets.format(&prompt.question, "{s}", .{question});
        prompt.text = [_:0]u8{0} ** 64;
        const length = @min(initial.len, 63);
        @memcpy(prompt.text[0..length], initial[0..length]);
        prompt.open = true;
    }

    /// desenha a pergunta por cima de `screen`; devolve o texto quando se confirma (OK ou Enter)
    pub fn draw(prompt: *TextPrompt, ui: *widgets.Ui, screen: rl.Rectangle) ?[]const u8 {
        if (!prompt.open) return null;
        if (rl.isKeyPressed(.escape)) { // Esc cancela
            prompt.open = false;
            return null;
        }
        rl.drawRectangleRec(screen, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const box: rl.Rectangle = .{ .x = screen.x + (screen.width - 420) / 2, .y = screen.y + 160, .width = 420, .height = 170 };
        const inner = widgets.card(ui, box, std.mem.sliceTo(&prompt.title, 0));
        theme.text(ui.fonts.regular, std.mem.sliceTo(&prompt.question, 0), inner.x + 10, inner.y + 6, 14, theme.colors.label);
        const field: rl.Rectangle = .{ .x = inner.x + 10, .y = inner.y + 30, .width = inner.width - 20, .height = 30 };
        const entered = rg.textBox(field, &prompt.text, true);
        var answer: ?[]const u8 = null;
        if (button(ui, .{ .x = box.x + box.width - 250, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "Cancelar")) prompt.open = false;
        if (entered or widgets.primaryButton(ui, .{ .x = box.x + box.width - 130, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "OK", true)) {
            prompt.open = false;
            answer = std.mem.sliceTo(&prompt.text, 0);
        }
        ui.click_taken = true;
        ui.wheel = 0;
        return answer;
    }
};

/// a pasta pessoal ($HOME; no Windows, %USERPROFILE%), ou a atual se não houver
fn home(buffer: []u8) []const u8 {
    const value = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return ".";
    const text = std.mem.sliceTo(value, 0);
    const length = @min(text.len, buffer.len);
    @memcpy(buffer[0..length], text[0..length]);
    return buffer[0..length];
}

/// "~" no começo do caminho digitado vira a pasta pessoal
fn expandHome(typed: []u8, length: usize) []const u8 {
    if (length == 0 or typed[0] != '~') return typed[0..length];
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = home(&home_buffer);
    const rest_length = length - 1;
    if (base.len + rest_length > typed.len) return typed[0..length];
    std.mem.copyBackwards(u8, typed[base.len .. base.len + rest_length], typed[1..length]);
    @memcpy(typed[0..base.len], base);
    return typed[0 .. base.len + rest_length];
}

/// um botão secundário: branco, borda fina, texto azul
pub fn button(ui: *widgets.Ui, rect: rl.Rectangle, caption: [:0]const u8) bool {
    const hover = ui.hovering(rect);
    widgets.rounded(rect, 6, if (hover) theme.colors.hover else theme.colors.field);
    widgets.roundedLines(rect, 6, theme.colors.line);
    const width = theme.textWidth(ui.fonts.regular, caption, 14);
    theme.text(ui.fonts.regular, caption, rect.x + (rect.width - width) / 2, rect.y + (rect.height - 15) / 2, 14, theme.colors.accent);
    return ui.clickedIn(rect);
}

/// a leitura das pastas (sem threads)
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

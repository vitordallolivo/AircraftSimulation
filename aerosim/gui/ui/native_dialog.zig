//! A janela de abrir e de salvar arquivo do próprio sistema (a do GNOME, do KDE, do Windows ou do macOS), no lugar
//! do seletor desenhado na tela. Ela já sabe dos favoritos, das pastas recentes, dos discos e das permissões do
//! sistema, e o seletor de dentro não. O programa não liga em nenhuma biblioteca a mais: chama o que o sistema já
//! tem (`zenity` ou `kdialog` no Linux, o PowerShell no Windows, o `osascript` no macOS), numa thread, e a tela
//! continua desenhando enquanto a pessoa escolhe. Sem nenhum deles (ou no navegador, ou no print), `begin` devolve
//! falso e quem chama abre o seletor de dentro (`dialogs.FilePicker`).
const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");

pub const State = enum(u8) { idle, running, chosen, cancelled, failed };

pub const Dialog = struct {
    state: std.atomic.Value(State) = .init(.idle),
    thread: ?std.Thread = null,
    // o pedido (copiado: quem chamou pode mudar os dele enquanto a thread roda)
    saving: bool = false,
    title: [96]u8 = undefined,
    title_len: usize = 0,
    start: [std.fs.max_path_bytes]u8 = undefined, // a pasta (abrir) ou a pasta/nome sugerido (salvar)
    start_len: usize = 0,
    patterns: [128]u8 = undefined, // "*.json *.csv"
    patterns_len: usize = 0,
    // a resposta
    chosen: [std.fs.max_path_bytes]u8 = undefined,
    chosen_len: usize = 0,

    /// abre a janela do sistema numa thread; falso se não dá (navegador, print, sem threads), e aí quem chama usa o
    /// seletor de dentro. `name` vazio é abrir; com nome, salvar
    pub fn begin(dialog: *Dialog, title: []const u8, folder: []const u8, extensions: []const []const u8, name: []const u8, saving: bool) bool {
        if (system.in_browser or builtin.single_threaded) return false;
        const io = system.process_io orelse return false;
        if (dialog.state.load(.acquire) == .running) return true;
        dialog.collect();
        dialog.saving = saving;
        dialog.title_len = copy(&dialog.title, title);
        var absolute: [std.fs.max_path_bytes]u8 = undefined;
        const base_len = std.Io.Dir.cwd().realPathFile(io, folder, &absolute) catch copy(&absolute, folder);
        const joined = std.fmt.bufPrint(&dialog.start, "{s}{c}{s}", .{ absolute[0..base_len], std.fs.path.sep, if (saving) name else "" });
        dialog.start_len = if (joined) |text| text.len else |_| copy(&dialog.start, absolute[0..base_len]);
        var writer: std.Io.Writer = .fixed(&dialog.patterns);
        for (extensions, 0..) |extension, k| writer.print("{s}*{s}", .{ if (k > 0) " " else "", extension }) catch {};
        dialog.patterns_len = writer.end;
        dialog.state.store(.running, .release);
        dialog.thread = std.Thread.spawn(.{}, run, .{ dialog, io }) catch {
            dialog.state.store(.idle, .release);
            return false;
        };
        return true;
    }

    /// verdadeiro enquanto a janela do sistema está aberta
    pub fn running(dialog: *const Dialog) bool {
        return dialog.state.load(.acquire) == .running;
    }

    /// o que a pessoa fez, uma vez, no primeiro quadro depois que a janela fechou (a thread já foi recolhida):
    /// `.chosen` (o caminho em `path()`), `.cancelled` ou `.failed` (nenhum programa de janela no sistema)
    pub fn finished(dialog: *Dialog) ?State {
        const state = dialog.state.load(.acquire);
        if (state == .idle or state == .running) return null;
        dialog.collect();
        dialog.state.store(.idle, .release);
        return state;
    }

    /// o caminho escolhido (vale até a próxima janela)
    pub fn path(dialog: *const Dialog) []const u8 {
        return dialog.chosen[0..dialog.chosen_len];
    }

    fn collect(dialog: *Dialog) void {
        if (dialog.thread) |thread| thread.join();
        dialog.thread = null;
    }

    /// a thread: tenta cada programa de janela até um abrir; o primeiro que abre decide (escolheu ou cancelou)
    fn run(dialog: *Dialog, io: std.Io) void {
        var arguments: [12][]const u8 = undefined;
        var scratch: [4][std.fs.max_path_bytes + 256]u8 = undefined;
        var tried: usize = 0;
        while (commandLine(dialog, tried, &arguments, &scratch)) |argv| : (tried += 1) {
            const outcome = dialog.ask(io, argv) orelse continue; // o programa não existe: o próximo
            dialog.state.store(outcome, .release);
            return;
        }
        dialog.state.store(.failed, .release);
    }

    /// roda um programa e lê o caminho que ele escreve; nulo se ele não abriu
    fn ask(dialog: *Dialog, io: std.Io, argv: []const []const u8) ?State {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch return null;
        var buffer: [512]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buffer);
        var length: usize = 0;
        while (length < dialog.chosen.len) {
            const count = reader.interface.readSliceShort(dialog.chosen[length..]) catch break;
            if (count == 0) break;
            length += count;
        }
        const term = child.wait(io) catch return .failed;
        const status: u8 = switch (term) {
            .exited => |code| code,
            else => 255,
        };
        const text = std.mem.trim(u8, dialog.chosen[0..length], " \r\n\t");
        if (status == 0 and text.len > 0) {
            std.mem.copyForwards(u8, dialog.chosen[0..text.len], text);
            dialog.chosen_len = text.len;
            dialog.addExtension();
            return .chosen;
        }
        // 1 é "cancelou" no zenity, no kdialog e no osascript; outro código é erro do programa (opção que a versão
        // instalada não conhece, sem tela...): vale tentar o próximo
        return if (status == 1) .cancelled else null;
    }

    /// salvar sem extensão no nome: põe a primeira pedida (como o seletor de dentro)
    fn addExtension(dialog: *Dialog) void {
        if (!dialog.saving or dialog.patterns_len < 2) return;
        const name = dialog.chosen[0..dialog.chosen_len];
        if (std.fs.path.extension(std.fs.path.basename(name)).len > 0) return;
        const first = std.mem.sliceTo(dialog.patterns[1..dialog.patterns_len], ' ');
        if (dialog.chosen_len + first.len > dialog.chosen.len) return;
        @memcpy(dialog.chosen[dialog.chosen_len..][0..first.len], first);
        dialog.chosen_len += first.len;
    }
};

/// a linha de comando do programa número `which` deste sistema, ou nulo quando acabaram
fn commandLine(dialog: *const Dialog, which: usize, arguments: *[12][]const u8, scratch: *[4][std.fs.max_path_bytes + 256]u8) ?[]const []const u8 {
    const title = dialog.title[0..dialog.title_len];
    const start = dialog.start[0..dialog.start_len];
    const patterns = dialog.patterns[0..dialog.patterns_len];
    var count: usize = 0;
    switch (builtin.os.tag) {
        .windows => {
            if (which > 0) return null;
            const kind = if (dialog.saving) "SaveFileDialog" else "OpenFileDialog";
            const folder = if (dialog.saving) std.fs.path.dirname(start) orelse start else start;
            const name = if (dialog.saving) std.fs.path.basename(start) else "";
            const filter = if (patterns.len > 0) patterns else "*.*";
            // o filtro do Windows separa as extensões com ";"
            const listed = scratch[1][0..filter.len];
            for (filter, listed) |char, *out| out.* = if (char == ' ') ';' else char;
            const script = std.fmt.bufPrint(&scratch[0], "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.{s}; " ++
                "$d.Title = '{s}'; $d.InitialDirectory = '{s}'; $d.FileName = '{s}'; $d.Filter = '{s}|{s}'; " ++
                "if ($d.ShowDialog() -eq 'OK') {{ [Console]::Out.Write($d.FileName) }} else {{ exit 1 }}", .{
                kind, quoteless(title), quoteless(folder), quoteless(name), filter, listed,
            }) catch return null;
            for ([_][]const u8{ "powershell", "-NoProfile", "-STA", "-Command", script }) |argument| {
                arguments[count] = argument;
                count += 1;
            }
        },
        .macos => {
            if (which > 0) return null;
            const script = if (dialog.saving)
                std.fmt.bufPrint(&scratch[0], "POSIX path of (choose file name with prompt \"{s}\" default location (POSIX file \"{s}\") default name \"{s}\")", .{ quoteless(title), std.fs.path.dirname(start) orelse "/", std.fs.path.basename(start) }) catch return null
            else
                std.fmt.bufPrint(&scratch[0], "POSIX path of (choose file with prompt \"{s}\" default location (POSIX file \"{s}\"))", .{ quoteless(title), start }) catch return null;
            for ([_][]const u8{ "osascript", "-e", script }) |argument| {
                arguments[count] = argument;
                count += 1;
            }
        },
        else => switch (which) {
            0 => { // zenity (GNOME e a maioria)
                arguments[0] = "zenity";
                arguments[1] = "--file-selection";
                arguments[2] = std.fmt.bufPrint(&scratch[1], "--filename={s}", .{start}) catch return null;
                count = 3;
                // fora de um idioma UTF-8 (LANG=C) o GTK recusa um título com acento, e a janela nem abre
                if (utf8Locale() or isAscii(title)) {
                    arguments[count] = std.fmt.bufPrint(&scratch[0], "--title={s}", .{title}) catch return null;
                    count += 1;
                }
                if (patterns.len > 0) {
                    arguments[count] = std.fmt.bufPrint(&scratch[2], "--file-filter={s} | {s}", .{ patterns, patterns }) catch return null;
                    count += 1;
                }
                if (dialog.saving) {
                    arguments[count] = "--save";
                    count += 1;
                }
            },
            1 => { // kdialog (KDE)
                arguments[0] = "kdialog";
                arguments[1] = if (dialog.saving) "--getsavefilename" else "--getopenfilename";
                arguments[2] = start;
                count = 3;
                if (patterns.len > 0) {
                    arguments[count] = patterns;
                    count += 1;
                }
                if (utf8Locale() or isAscii(title)) {
                    arguments[count] = std.fmt.bufPrint(&scratch[0], "--title={s}", .{title}) catch return null;
                    count += 1;
                }
            },
            else => return null,
        },
    }
    return arguments[0..count];
}

/// o idioma do sistema escreve em UTF-8 (LC_ALL, LC_CTYPE ou LANG, o primeiro que existir)
fn utf8Locale() bool {
    const names = [_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (names) |name| {
        const value = std.mem.sliceTo(std.c.getenv(name) orelse continue, 0);
        if (value.len == 0) continue;
        return std.ascii.indexOfIgnoreCase(value, "utf-8") != null or std.ascii.indexOfIgnoreCase(value, "utf8") != null;
    }
    return false;
}

fn isAscii(text: []const u8) bool {
    for (text) |char| if (char >= 0x80) return false;
    return true;
}

/// o texto sem aspas simples nem duplas (vai dentro de um script do PowerShell ou do AppleScript)
fn quoteless(text: []const u8) []const u8 {
    for (text, 0..) |char, k| if (char == '\'' or char == '"') return text[0..k];
    return text;
}

fn copy(target: []u8, source: []const u8) usize {
    const length = @min(target.len, source.len);
    @memcpy(target[0..length], source[0..length]);
    return length;
}

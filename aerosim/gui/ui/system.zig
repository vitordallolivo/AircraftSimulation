//! O que muda entre o programa do PC e o do navegador, num lugar só: a `Io` dos arquivos (a do sistema ou a
//! `browser_io.zig`, que guarda tudo na memória da página) e o que se faz depois de gravar um arquivo (no navegador,
//! a página baixa ele, porque a pasta da memória some ao fechar a aba).
const std = @import("std");
const builtin = @import("builtin");

/// verdadeiro no alvo `wasm32-emscripten` (a página web)
pub const in_browser = builtin.os.tag == .emscripten;

const browser_io = if (in_browser) @import("browser_io.zig") else struct {};

/// a `Io` do processo (a do `main`), para abrir outros programas, como a janela de arquivo do sistema; nula no
/// navegador e no print (`--shot`), que ficam com o seletor de dentro
pub var process_io: ?std.Io = null;

/// a `Io` dos arquivos (sem threads)
pub fn io() std.Io {
    return if (in_browser) browser_io.io else std.Io.Threaded.global_single_threaded.io();
}

/// depois de gravar `path`: no navegador a página baixa o arquivo (`downloadFile` da página, em `web/shell.html`);
/// no PC não faz nada, o arquivo já está na pasta
pub fn offerDownload(path: []const u8) void {
    if (!in_browser) return;
    var script: [std.fs.max_path_bytes + 64]u8 = undefined;
    // o caminho vai entre aspas no JS: só os caminhos que a própria tela escolheu, sem aspas nem barra invertida
    for (path) |char| if (char == '\'' or char == '\\') return;
    const text = std.fmt.bufPrintZ(&script, "Module.downloadFile && Module.downloadFile('{s}')", .{path}) catch return;
    std.os.emscripten.emscripten_run_script(text.ptr);
}

/// pergunta um texto pela janela do navegador (`prompt`, que abre o teclado do celular), começando com `current`;
/// devolve o que se digitou em `answer`, ou nulo se cancelou ou fora do navegador
pub fn askText(question: []const u8, current: []const u8, answer: []u8) ?[]const u8 {
    if (!in_browser) return null;
    var script: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&script);
    writer.writeAll("(function(){var v=prompt('") catch return null;
    writeQuoted(&writer, question) catch return null;
    writer.writeAll("','") catch return null;
    writeQuoted(&writer, current) catch return null;
    writer.writeAll("');return v===null?'\\u0001':v;})()") catch return null;
    writer.writeByte(0) catch return null;
    const reply = std.os.emscripten.emscripten_run_script_string(@ptrCast(writer.buffered().ptr)) orelse return null;
    const typed = std.mem.sliceTo(reply, 0);
    if (typed.len == 1 and typed[0] == 1) return null;
    const length = @min(typed.len, answer.len);
    @memcpy(answer[0..length], typed[0..length]);
    return answer[0..length];
}

/// `text` dentro de aspas simples do JS: escapa a barra invertida e as aspas; quebras de linha viram espaço
fn writeQuoted(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |char| switch (char) {
        '\\', '\'' => {
            try writer.writeByte('\\');
            try writer.writeByte(char);
        },
        '\n', '\r', '\t' => try writer.writeByte(' '),
        else => if (char >= 0x20) try writer.writeByte(char),
    };
}

/// no navegador, abre o seletor de arquivos do aparelho (`pickFile` da página, em `web/shell.html`); o arquivo
/// escolhido chega pelo `app_open_file`. Devolve falso fora do navegador
pub fn pickFromDevice() bool {
    if (!in_browser) return false;
    std.os.emscripten.emscripten_run_script("Module.pickFile && Module.pickFile()");
    return true;
}

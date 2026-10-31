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

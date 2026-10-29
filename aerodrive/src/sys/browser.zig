//! A ponte com a página no navegador (só no alvo web). As funções `extern` estão em JS, em
//! `web/aerodrive_library.js` (o emcc liga pelo `--js-library`); a página chama de volta
//! `aerodrive_load_aircraft` quando o jogador escolhe ou arrasta um .json.
//!
//!   const size = browser.viewportSize();          // a janela do navegador, para o initWindow
//!   _ = browser.fileWrite("/aerodrive/x.json", bytes);   // FS do emscripten; /aerodrive vai ao IndexedDB
//!   browser.openFilePicker();                      // o seletor de arquivo da página
//!   if (browser.takeImport()) |file| { ...; file.deinit(); }   // o .json que chegou da página
//!
//! Nada aqui roda no nativo: as `extern` só são analisadas se alguém chamar (e só o alvo web chama).
const std = @import("std");
const platform = @import("platform.zig");

extern fn aerodrive_file_size(path: [*]const u8, path_len: usize) i32;
extern fn aerodrive_file_read(path: [*]const u8, path_len: usize, out: [*]u8, out_len: usize) i32;
extern fn aerodrive_file_write(path: [*]const u8, path_len: usize, data: [*]const u8, data_len: usize) i32;
extern fn aerodrive_folder_list(path: [*]const u8, path_len: usize, out: [*]u8, out_capacity: usize) i32;
extern fn aerodrive_path_remove(path: [*]const u8, path_len: usize) i32;
extern fn aerodrive_viewport_width() i32;
extern fn aerodrive_viewport_height() i32;
extern fn aerodrive_open_file_picker() void;
extern fn aerodrive_download(name: [*]const u8, name_len: usize, data: [*]const u8, data_len: usize) void;
extern fn aerodrive_touch_seen() i32;
extern fn aerodrive_leave() void;
extern fn aerodrive_gamepad_trigger(side: c_int) f64;
extern fn aerodrive_video_start(name: [*]const u8, name_len: usize, fps: c_int) i32;
extern fn aerodrive_video_stop() void;
extern fn emscripten_set_main_loop_timing(mode: c_int, value: c_int) c_int;

// ------------------------------------------------------------------ arquivos (FS do emscripten)
/// tamanho do arquivo em bytes; null se não existe (ou é uma pasta)
pub fn fileSize(path: []const u8) ?usize {
    const size = aerodrive_file_size(path.ptr, path.len);
    return if (size < 0) null else @intCast(size);
}

/// copia o arquivo inteiro para `out` (do tamanho de `fileSize`); false se não deu
pub fn fileRead(path: []const u8, out: []u8) bool {
    return aerodrive_file_read(path.ptr, path.len, out.ptr, out.len) == 1;
}

/// grava o arquivo (cria as pastas); o que está em /aerodrive vai ao IndexedDB logo depois
pub fn fileWrite(path: []const u8, data: []const u8) bool {
    return aerodrive_file_write(path.ptr, path.len, data.ptr, data.len) == 1;
}

/// os nomes da pasta, um por linha, pastas com "/" no fim (texto em `arena`); null se não existe
pub fn folderList(arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
    var capacity: usize = 4096;
    while (true) {
        const out = try arena.alloc(u8, capacity);
        const needed = aerodrive_folder_list(path.ptr, path.len, out.ptr, out.len);
        if (needed < 0) return null;
        if (@as(usize, @intCast(needed)) <= capacity) return out[0..@intCast(needed)];
        capacity = @intCast(needed); // não coube: de novo com o tamanho certo
    }
}

/// apaga o arquivo ou a pasta com tudo dentro
pub fn pathRemove(path: []const u8) bool {
    return aerodrive_path_remove(path.ptr, path.len) == 1;
}

// ------------------------------------------------------------------ página
pub const Size = struct { width: i32, height: i32 };

/// o tamanho da área da página (em pixels CSS), no mínimo 320×240
pub fn viewportSize() Size {
    return .{ .width = @max(320, aerodrive_viewport_width()), .height = @max(240, aerodrive_viewport_height()) };
}

/// abre o seletor de arquivo (.json) da página; o arquivo escolhido chega por `takeImport`
pub fn openFilePicker() void {
    aerodrive_open_file_picker();
}

/// baixa `data` como um arquivo chamado `name` (Blob + link de download)
pub fn download(name: []const u8, data: []const u8) void {
    aerodrive_download(name.ptr, name.len, data.ptr, data.len);
}

/// verdadeiro depois do primeiro toque na tela (celular, tablet): liga os controles por toque
pub fn touchSeen() bool {
    return aerodrive_touch_seen() == 1;
}

pub const TriggerSide = enum(c_int) { left = 0, right = 1 };

/// quanto o gatilho (LT/RT) do primeiro controle está apertado, 0..1 (Gamepad API do navegador)
pub fn gamepadTrigger(side: TriggerSide) f64 {
    const value = aerodrive_gamepad_trigger(@intFromEnum(side));
    return if (std.math.isFinite(value)) std.math.clamp(value, 0, 1) else 0;
}

/// começa a gravar o canvas em vídeo (MediaRecorder do navegador: .mp4, ou .webm onde não houver
/// .mp4). No Chrome e no Edge do PC a página pergunta onde salvar; nos outros, o vídeo é baixado ao
/// parar. `name` é o nome sugerido, sem a extensão. false se o navegador não grava vídeo.
pub fn videoStart(name: []const u8, fps: u32) bool {
    return aerodrive_video_start(name.ptr, name.len, @intCast(fps)) == 1;
}

/// para o vídeo começado por `videoStart` e fecha o arquivo (ou baixa); nada se não havia vídeo
pub fn videoStop() void {
    aerodrive_video_stop();
}

/// volta à tela inicial do site (o "Sair" do navegador)
pub fn leave() void {
    aerodrive_leave();
}

/// quadros por segundo no navegador: 60 = um quadro por atualização da tela, 30 = um a cada duas
pub fn setFrameRate(fps: u32) void {
    const timing_raf = 1; // EM_TIMING_RAF (emscripten.h)
    _ = emscripten_set_main_loop_timing(timing_raf, if (fps <= 30) 2 else 1);
}

// ------------------------------------------------------------------ avião vindo da página
/// o .json que a página entregou (nome do arquivo e bytes), à espera do próximo quadro
pub const ImportedFile = struct {
    name: []u8,
    bytes: []u8,

    /// libera nome e bytes
    pub fn deinit(file: ImportedFile) void {
        gpa.free(file.name);
        gpa.free(file.bytes);
    }
};

pub const ImportError = error{ TooBig, OutOfMemory };

/// o mesmo limite do avião lido do disco (app.zig)
pub const max_import_bytes = 64 << 20;

const gpa = std.heap.c_allocator;
var pending_import: ?ImportedFile = null;

/// o arquivo que chegou desde o último quadro (o chamador libera com `deinit`)
pub fn takeImport() ?ImportedFile {
    const file = pending_import orelse return null;
    pending_import = null;
    return file;
}

/// guarda uma cópia do arquivo para o próximo quadro (um segundo arquivo substitui o primeiro)
pub fn queueImport(name: []const u8, bytes: []const u8) ImportError!void {
    if (bytes.len > max_import_bytes) return error.TooBig;
    const name_copy = try gpa.dupe(u8, name);
    errdefer gpa.free(name_copy);
    const bytes_copy = try gpa.dupe(u8, bytes);
    if (pending_import) |old| old.deinit();
    pending_import = .{ .name = name_copy, .bytes = bytes_copy };
}

/// código numérico do erro para o JS (0 = ok); só existe na fronteira
fn importCode(err: ImportError) c_int {
    return switch (err) {
        error.TooBig => 1,
        error.OutOfMemory => 2,
    };
}

/// chamada pelo JS: o jogador escolheu ou arrastou um .json (o JS copiou nome e bytes para a
/// memória do wasm). O avião é lido e validado no próximo quadro; o erro aparece na tela do jogo.
fn loadAircraft(name: [*]const u8, name_len: usize, bytes: [*]const u8, bytes_len: usize) callconv(.c) c_int {
    queueImport(name[0..name_len], bytes[0..bytes_len]) catch |err| return importCode(err);
    return 0;
}

comptime {
    if (platform.in_browser) @export(&loadAircraft, .{ .name = "aerodrive_load_aircraft" });
}

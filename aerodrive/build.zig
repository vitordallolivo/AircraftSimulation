//! AeroDrive — simulador pilotado com o núcleo do aerosim.
//!
//!   zig build run -- ../data/aircraft/Convencional_original.json      abre o menu inicial com o avião
//!   zig build shot -- <saída.png> [avião.json] [WxH] [tela=...]        só tira uma foto (sem interação)
//!   zig build test                                                     testes (sem janela)
//!   zig build test -Dfuzz=200000 -Dseed=7                             fuzzing mais longo (padrão: 2000 por teste)
//!   zig build -Dtarget=wasm32-emscripten                               versão para o navegador em zig-out/web/
//!                                                                      (aerodrive.html, .js, .wasm, .data)
//!
//! O raylib vem pelo raylib-zig (build.zig.zon), compilado junto: nada a instalar além dos
//! cabeçalhos do sistema de janelas no Linux (ver docs/raylib.md).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- o núcleo de física (core/) como módulo Zig
    const core = b.dependency("aerosim", .{ .target = target, .release = true }).module("aerosim"); // física sempre otimizada

    // ---- testes: só os módulos sem janela (modelo, esqueleto, poses, câmeras)
    const fopts = b.addOptions();
    fopts.addOption(usize, "fuzz_iterations", b.option(usize, "fuzz", "entradas aleatórias por teste de fuzzing (padrão 2000)") orelse 2000);
    fopts.addOption(u64, "fuzz_seed", b.option(u64, "seed", "semente do fuzzing (padrão 1)") orelse 1);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aerosim", .module = core }},
    }) });
    tests.root_module.addOptions("build_options", fopts);
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(".")); // os testes leem ../data/aircraft
    b.step("test", "Testes e fuzzing (sem janela)").dependOn(&run_tests.step);

    // ---- o programa (com raylib, pelo raylib-zig)
    const display = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11;
    const rlz = if (target.result.os.tag == .emscripten)
        b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .opengl_version = .gles_3 }) // WebGL 2
    else
        b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .linux_display_backend = display });
    const raylib_zig = rlz orelse return;

    const program = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib_zig.module("raylib") },
            .{ .name = "raygui", .module = raylib_zig.module("raygui") },
            .{ .name = "aerosim", .module = core },
        },
    });
    if (target.result.os.tag == .emscripten) return buildWeb(b, raylib_zig, program);

    const exe = b.addExecutable(.{
        .name = "aerodrive",
        .root_module = program,
        // o LLD acusa como erro as .so que o Zig 0.16 põe dentro do libraylib.a; o ligador do próprio Zig não
        // (é o que os exemplos do raylib fazem fora do Windows)
        .use_lld = target.result.os.tag == .windows,
    });
    exe.root_module.linkLibrary(raylib_zig.artifact("raylib"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Abre o AeroDrive").dependOn(&run.step);

    const shot = b.addRunArtifact(exe);
    shot.addArg("--shot");
    if (b.args) |args| shot.addArgs(args);
    b.step("shot", "Desenha uma tela e salva uma imagem").dependOn(&shot.step);
}

/// Navegador: o programa vira uma biblioteca estática em wasm e o emcc (do emsdk que vem com o
/// raylib-zig) liga tudo em zig-out/web/aerodrive.{html,js,wasm,data}, com a página
/// `web/shell.html` e a ponte JS `web/aerodrive_library.js`. Os aviões de exemplo (os .json de
/// ../data/aircraft, só lidos) vão no .data, em /data/aircraft.
fn buildWeb(b: *std.Build, raylib_zig: *std.Build.Dependency, program: *std.Build.Module) void {
    const raylib_zig_build = b.lazyImport(@This(), "raylib_zig") orelse return;
    const emsdk = raylib_zig_build.emsdk;
    const wasm = b.addLibrary(.{ .name = "aerodrive", .root_module = program });
    const js_library = b.path("web/aerodrive_library.js");

    // ReleaseFast no emcc: o ReleaseSafe dele liga SAFE_HEAP e ASSERTIONS (lento demais para voar);
    // as verificações do Zig seguem o `-Doptimize` do programa
    var flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = .ReleaseFast, .asyncify = false });
    flags.put("-lidbfs.js", {}) catch @panic("sem memória");
    flags.put(b.fmt("--js-library={s}", .{js_library.getPath(b)}), {}) catch @panic("sem memória");
    var settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = .ReleaseFast, .es3 = true, .memory_growth = true });
    settings.put("EXPORTED_RUNTIME_METHODS", "['FS','IDBFS','HEAPU8','addRunDependency','removeRunDependency']") catch @panic("sem memória");
    settings.put("EXPORTED_FUNCTIONS", "['_main','_malloc','_free','_aerodrive_load_aircraft']") catch @panic("sem memória");
    settings.put("ENVIRONMENT", "web") catch @panic("sem memória");
    // a pilha do emscripten é de 64 KB; o programa nativo conta com os 8 MB do sistema (o núcleo e a
    // montagem do avião guardam estruturas grandes na pilha)
    settings.put("STACK_SIZE", "8388608") catch @panic("sem memória");

    // o emcc e o emsdk são dependências do raylib-zig: o passo é montado pelo builder dele
    const install = emsdk.emccStep(raylib_zig.builder, raylib_zig.artifact("raylib"), wasm, .{
        .optimize = .ReleaseFast,
        .flags = flags,
        .settings = settings,
        .shell_file_path = b.path("web/shell.html"),
        .install_dir = .{ .custom = "web" },
        .preload_paths = packageFiles(b, EmccFilePath(emsdk)),
    });
    // o passo do zemscripten instala na pasta do builder do raylib-zig (dentro do cache): a saída
    // do emcc é copiada daqui para zig-out/web
    const emcc_output: *std.Build.Step.InstallDir = @fieldParentPtr("step", install);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = emcc_output.options.source_dir, .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
    // a ponte JS e os aviões entram por caminho no comando: avisar o build para refazer quando mudarem
    const emcc: *std.Build.Step.Run = @fieldParentPtr("step", install.dependencies.items[0]);
    emcc.addFileInput(js_library);
    for (packageFiles(b, EmccFilePath(emsdk))) |file| emcc.addFileInput(.{ .cwd_relative = file.src_path });
}

/// fontes livres (podem ir no site) que o nativo também procura; a primeira que existir na máquina
/// do build vai no pacote web como /fonts/aerodrive.ttf (ui/theme.zig). Nenhuma: a fonte do raylib.
const web_font_candidates = [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
};

/// o que vai no .data: os .json de ../data/aircraft em /data/aircraft (só lidos; nada é gravado
/// na pasta) e a fonte
fn packageFiles(b: *std.Build, comptime FilePath: type) []const FilePath {
    const io = b.graph.io;
    var files: std.ArrayList(FilePath) = .empty;
    for (web_font_candidates) |font| {
        std.Io.Dir.cwd().access(io, font, .{}) catch continue;
        files.append(b.allocator, .{ .src_path = font, .virtual_path = "/fonts/aerodrive.ttf" }) catch @panic("sem memória");
        break;
    }
    var folder = b.build_root.handle.openDir(io, "../data/aircraft", .{ .iterate = true }) catch return files.items;
    defer folder.close(io);
    var entries = folder.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        files.append(b.allocator, .{
            .src_path = b.pathFromRoot(b.fmt("../data/aircraft/{s}", .{entry.name})),
            .virtual_path = b.fmt("/data/aircraft/{s}", .{entry.name}),
        }) catch @panic("sem memória");
    }
    return files.items;
}

/// o tipo de um arquivo do pacote no zemscripten (só alcançável pela assinatura do `emccStep`)
fn EmccFilePath(comptime emsdk: type) type {
    const Options = @typeInfo(@TypeOf(emsdk.emccStep)).@"fn".params[3].type.?;
    return @typeInfo(@typeInfo(@FieldType(Options, "preload_paths")).optional.child).pointer.child;
}

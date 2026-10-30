//! Interface do aeroopt em Zig (raylib e raygui). As peças comuns das telas vêm da interface do aerosim
//! (`aerosim/gui/ui`), para os dois programas terem o mesmo visual.
//!
//!   zig build run                                abre o aeroopt
//!   zig build shot -- <saída.png> [LxA]          desenha a tela e salva uma imagem (sem interação)
//!   zig build test                               testes (sem janela)
//!   zig build -Dtarget=wasm32-emscripten         versão para o navegador em zig-out/web/ (aeroopt.html, .js, .wasm, .data)
//!
//! O raylib vem pelo raylib-zig (build.zig.zon), compilado junto, como no AeroDrive.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- testes: só o que não abre janela (a rodada de exemplo)
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Testes (sem janela)").dependOn(&b.addRunArtifact(tests).step);

    // ---- o programa
    const display = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11;
    const rlz = if (target.result.os.tag == .emscripten)
        b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .opengl_version = .gles_3 }) // WebGL 2
    else
        b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .linux_display_backend = display });
    const raylib_zig = rlz orelse return;
    const raylib = raylib_zig.module("raylib");
    const raygui = raylib_zig.module("raygui");
    // as peças comuns das telas (../../aerosim/gui/ui/ui.zig)
    const ui = b.createModule(.{
        .root_source_file = b.path("../aerosim/gui/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "raygui", .module = raygui },
        },
    });
    const program = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "ui", .module = ui },
        },
    });
    if (target.result.os.tag == .emscripten) return buildWeb(b, raylib_zig, program);

    const exe = b.addExecutable(.{ .name = "aeroopt", .root_module = program });
    exe.root_module.linkLibrary(raylib_zig.artifact("raylib"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Abre o aeroopt").dependOn(&run.step);

    const shot = b.addRunArtifact(exe);
    shot.addArg("--shot");
    if (b.args) |args| shot.addArgs(args);
    b.step("shot", "Desenha a tela e salva uma imagem").dependOn(&shot.step);
}

/// Navegador: o programa vira uma biblioteca estática em wasm e o emcc (do emsdk que vem com o raylib-zig) liga tudo
/// em zig-out/web/aeroopt.{html,js,wasm,data}, com a página `aerosim/gui/web/shell.html`. O .data leva as fontes
/// (/fonts).
fn buildWeb(b: *std.Build, raylib_zig: *std.Build.Dependency, program: *std.Build.Module) void {
    const raylib_zig_build = b.lazyImport(@This(), "raylib_zig") orelse return;
    const emsdk = raylib_zig_build.emsdk;
    const wasm = b.addLibrary(.{ .name = "aeroopt", .root_module = program });
    // ReleaseFast no emcc: o ReleaseSafe dele liga SAFE_HEAP e ASSERTIONS (lento demais); as verificações do Zig
    // seguem o `-Doptimize` do programa
    const flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = .ReleaseFast, .asyncify = false });
    var settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = .ReleaseFast, .es3 = true, .memory_growth = true });
    settings.put("EXPORTED_RUNTIME_METHODS", "['FS','HEAPU8','stringToNewUTF8']") catch @panic("sem memória");
    settings.put("EXPORTED_FUNCTIONS", "['_main','_malloc','_free','_app_open_file']") catch @panic("sem memória");
    settings.put("ENVIRONMENT", "web") catch @panic("sem memória");
    // a pilha do emscripten é de 64 KB; o programa nativo conta com os 8 MB do sistema (o núcleo guarda estruturas
    // grandes na pilha)
    settings.put("STACK_SIZE", "8388608") catch @panic("sem memória");
    const files = webFiles(b, EmccFilePath(emsdk));
    const install = emsdk.emccStep(raylib_zig.builder, raylib_zig.artifact("raylib"), wasm, .{
        .optimize = .ReleaseFast,
        .flags = flags,
        .settings = settings,
        .shell_file_path = b.path("../aerosim/gui/web/shell.html"),
        .install_dir = .{ .custom = "web" },
        .preload_paths = files,
    });
    // o passo do zemscripten instala na pasta do builder do raylib-zig (dentro do cache): a saída do emcc é copiada
    // daqui para zig-out/web
    const emcc_output: *std.Build.Step.InstallDir = @fieldParentPtr("step", install);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = emcc_output.options.source_dir, .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
    const emcc: *std.Build.Step.Run = @fieldParentPtr("step", install.dependencies.items[0]);
    for (files) |file| emcc.addFileInput(.{ .cwd_relative = file.src_path });
}

/// as fontes livres que vão no pacote (as mesmas que o nativo procura no sistema; `ui/theme.zig`)
const web_fonts = [_][]const u8{ "DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSansMono.ttf" };
const web_font_folders = [_][]const u8{ "/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/TTF", "/usr/share/fonts/dejavu" };

/// o que vai no .data: as fontes em /fonts
fn webFiles(b: *std.Build, comptime FilePath: type) []const FilePath {
    const io = b.graph.io;
    var files: std.ArrayList(FilePath) = .empty;
    for (web_fonts) |font| for (web_font_folders) |folder| {
        const path = b.fmt("{s}/{s}", .{ folder, font });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        files.append(b.allocator, .{ .src_path = path, .virtual_path = b.fmt("/fonts/{s}", .{font}) }) catch @panic("sem memória");
        break;
    };
    for (web_data_folders) |folder| {
        var dir = b.build_root.handle.openDir(io, b.fmt("../{s}", .{folder}), .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var entries = dir.iterate();
        while (entries.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            files.append(b.allocator, .{
                .src_path = b.pathFromRoot(b.fmt("../{s}/{s}", .{ folder, entry.name })),
                .virtual_path = b.fmt("/{s}/{s}", .{ folder, entry.name }),
            }) catch @panic("sem memória");
        }
    }
    return files.items;
}

/// o tipo de um arquivo do pacote no zemscripten (só alcançável pela assinatura do `emccStep`)
fn EmccFilePath(comptime emsdk: type) type {
    const Options = @typeInfo(@TypeOf(emsdk.emccStep)).@"fn".params[3].type.?;
    return @typeInfo(@typeInfo(@FieldType(Options, "preload_paths")).optional.child).pointer.child;
}

/// o aeroopt não lê nada de `data/`
const web_data_folders = [_][]const u8{};

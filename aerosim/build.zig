//! Interface do aerosim em Zig (raylib e raygui), com o núcleo como módulo. O código Zig fica junto do Python, na
//! pasta da interface (`gui/`); as peças comuns das telas ficam em `gui/ui` e servem também ao aeroopt. Da raiz do
//! repositório, `zig build aerosim` faz o mesmo que `zig build run` aqui.
//!
//!   zig build run                                abre o aerosim
//!   zig build run -- <avião.json>                abre um avião na Montagem
//!   zig build shot -- <saída.png> [LxA]          desenha a tela e salva uma imagem (sem interação)
//!   zig build test                               testes (sem janela)
//!
//! O raylib vem pelo raylib-zig (build.zig.zon), compilado junto, como no AeroDrive.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- o núcleo de física (core/) como módulo Zig, sempre otimizado
    const core = b.dependency("aerosim", .{ .target = target, .release = true }).module("aerosim");

    // ---- o modelo do avião do AeroDrive (leitura do .json e as malhas das peças), para a Montagem
    const fuzz_options = b.addOptions(); // o módulo de fuzzing do AeroDrive pede estas opções
    fuzz_options.addOption(usize, "fuzz_iterations", 2000);
    fuzz_options.addOption(u64, "fuzz_seed", 1);
    const aircraft_model = b.createModule(.{
        .root_source_file = b.path("../aerodrive/src/aircraft_model.zig"),
        .target = target,
        .optimize = optimize,
    });
    aircraft_model.addOptions("build_options", fuzz_options);
    aircraft_model.addImport("aerosim", core);

    // ---- testes: só o que não abre janela (escalas dos gráficos, a asa de exemplo)
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("gui/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aerosim", .module = core },
            .{ .name = "aircraft_model", .module = aircraft_model },
        },
    }) });
    b.step("test", "Testes (sem janela)").dependOn(&b.addRunArtifact(tests).step);

    // ---- o programa (gui/main.zig)
    const display = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11;
    const raylib_zig = b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .linux_display_backend = display }) orelse return;
    const raylib = raylib_zig.module("raylib");
    const raygui = raylib_zig.module("raygui");
    // as peças comuns das telas (gui/ui/ui.zig)
    const ui = b.createModule(.{
        .root_source_file = b.path("gui/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "raygui", .module = raygui },
        },
    });
    const program = b.createModule(.{
        .root_source_file = b.path("gui/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "ui", .module = ui },
            .{ .name = "aerosim", .module = core },
            .{ .name = "aircraft_model", .module = aircraft_model },
        },
    });
    const exe = b.addExecutable(.{ .name = "aerosim", .root_module = program });
    exe.root_module.linkLibrary(raylib_zig.artifact("raylib"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Abre o aerosim").dependOn(&run.step);

    const shot = b.addRunArtifact(exe);
    shot.addArg("--shot");
    if (b.args) |args| shot.addArgs(args);
    b.step("shot", "Desenha a tela e salva uma imagem").dependOn(&shot.step);
}

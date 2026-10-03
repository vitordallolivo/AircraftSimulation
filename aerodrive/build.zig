//! aerodrive — simulador pilotado com o núcleo do aerosim.
//!
//!   zig build run -- ../data/aircraft/Convencional_original.json      abre o hangar com o avião
//!   zig build shot -- <avião.json> <saída.png> [WxH] [demo]            só tira uma foto (sem interação)
//!   zig build test                                                     testes (sem janela)
//!   zig build test -Dfuzz=200000 -Dseed=7                             fuzzing mais longo (padrão: 2000 por teste)
//!
//! O raylib vem pelo gerenciador de pacotes do Zig (build.zig.zon) e é compilado junto: nada a
//! instalar além dos cabeçalhos do sistema de janelas no Linux (ver docs/raylib.md).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- testes: só os módulos sem janela (modelo, esqueleto, poses, câmeras)
    const fopts = b.addOptions();
    fopts.addOption(usize, "fuzz_iterations", b.option(usize, "fuzz", "entradas aleatórias por teste de fuzzing (padrão 2000)") orelse 2000);
    fopts.addOption(u64, "fuzz_seed", b.option(u64, "seed", "semente do fuzzing (padrão 1)") orelse 1);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.addOptions("build_options", fopts);
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(".")); // os testes leem ../data/aircraft
    b.step("test", "Testes e fuzzing (sem janela)").dependOn(&run_tests.step);

    // ---- o programa (com raylib)
    const rl = b.lazyDependency("raylib", .{
        .target = target,
        .optimize = .ReleaseFast,
        .linux_display_backend = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11,
    }) orelse return;
    const raylib = rl.artifact("raylib");
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/gfx/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(rl.path("src"));
    const c_mod = c.createModule();

    const exe = b.addExecutable(.{ .name = "aerodrive", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    }) });
    exe.root_module.linkLibrary(raylib);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Abre o aerodrive").dependOn(&run.step);

    const shot = b.addRunArtifact(exe);
    shot.addArg("--shot");
    if (b.args) |args| shot.addArgs(args);
    b.step("shot", "Desenha o avião e salva uma imagem").dependOn(&shot.step);
}

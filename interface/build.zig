//! Interface do aerosim e do aeroopt em Zig (raylib e raygui), com o núcleo como módulo.
//!
//!   zig build run -- aerosim                      abre o aerosim
//!   zig build run -- aeroopt                      abre o aeroopt
//!   zig build shot -- <saída.png> aerosim [LxA]   desenha a tela e salva uma imagem (sem interação)
//!   zig build test                                testes (sem janela)
//!
//! O raylib vem pelo raylib-zig (build.zig.zon), compilado junto, como no AeroDrive.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- o núcleo de física (core/) como módulo Zig, sempre otimizado
    const core = b.dependency("aerosim", .{ .target = target, .release = true }).module("aerosim");

    // ---- testes: só o que não abre janela (escalas dos gráficos, a asa de exemplo, o formulário)
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aerosim", .module = core }},
    }) });
    b.step("test", "Testes (sem janela)").dependOn(&b.addRunArtifact(tests).step);

    // ---- o programa
    const display = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11;
    const raylib_zig = b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .linux_display_backend = display }) orelse return;
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
    const exe = b.addExecutable(.{ .name = "aircraftsimulation", .root_module = program });
    exe.root_module.linkLibrary(raylib_zig.artifact("raylib"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Abre a interface").dependOn(&run.step);

    const shot = b.addRunArtifact(exe);
    shot.addArg("--shot");
    if (b.args) |args| shot.addArgs(args);
    b.step("shot", "Desenha uma tela e salva uma imagem").dependOn(&shot.step);
}

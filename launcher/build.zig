//! A tela inicial do programa instalado (o menu do site, no PC), em Zig com raylib. Usa as peças comuns das telas
//! (`aerosim/gui/ui`), como o aeroopt.
//!
//!   zig build run                                abre a tela inicial
//!   zig build test                               testes (sem janela)
//!
//! O executável se chama `aircraftsimulation`: é ele que o pacote (o .exe do Windows, o AppImage) abre primeiro.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- testes: só o que não abre janela (onde estão os programas e os dados)
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Testes (sem janela)").dependOn(&b.addRunArtifact(tests).step);

    // ---- o programa
    const display = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11;
    const raylib_zig = b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .linux_display_backend = display }) orelse return;
    const raylib = raylib_zig.module("raylib");
    const raygui = raylib_zig.module("raygui");
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
    const exe = b.addExecutable(.{ .name = "aircraftsimulation", .root_module = program });
    exe.root_module.linkLibrary(raylib_zig.artifact("raylib"));
    // no Windows, sem a janela preta do console atrás da tela inicial
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Abre a tela inicial").dependOn(&run.step);
}

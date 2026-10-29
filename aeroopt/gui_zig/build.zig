//! Interface do aeroopt em Zig (raylib e raygui). As peças comuns das telas vêm da interface do aerosim
//! (`aerosim/gui_zig/src/ui`), para os dois programas terem o mesmo visual.
//!
//!   zig build run                                abre o aeroopt
//!   zig build shot -- <saída.png> [LxA]          desenha a tela e salva uma imagem (sem interação)
//!   zig build test                               testes (sem janela)
//!
//! O raylib vem pelo raylib-zig (build.zig.zon), compilado junto, como no AeroDrive.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- testes: só o que não abre janela (a rodada de exemplo)
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Testes (sem janela)").dependOn(&b.addRunArtifact(tests).step);

    // ---- o programa
    const display = b.option(enum { X11, Wayland, Both }, "display", "Linux: X11 (padrão), Wayland ou Both") orelse .X11;
    const raylib_zig = b.lazyDependency("raylib_zig", .{ .target = target, .optimize = .ReleaseFast, .linux_display_backend = display }) orelse return;
    const raylib = raylib_zig.module("raylib");
    const raygui = raylib_zig.module("raygui");
    // as peças comuns das telas (../../aerosim/gui_zig/src/ui/ui.zig)
    const ui = b.createModule(.{
        .root_source_file = b.path("../../aerosim/gui_zig/src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "raygui", .module = raygui },
        },
    });
    const program = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "ui", .module = ui },
        },
    });
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

//! Núcleo de simulação (camada "Sim").
//!
//!   zig build --release=fast       -> zig-out/lib/libaerosim.so (C ABI, usada pelo Python)
//!   zig build test                 -> testes de cada módulo
//!   zig build -Dfast_math=false    -> troca LUT/polinômios por std.math (referência)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const fast_math = b.option(bool, "fast_math", "LUT e aproximações polinomiais (padrão: true)") orelse true;

    const opts = b.addOptions();
    opts.addOption(bool, "fast_math", fast_math);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .strip = optimize != .Debug,
    });
    mod.addOptions("build_options", opts);

    const lib = b.addLibrary(.{ .linkage = .dynamic, .name = "aerosim", .root_module = mod });
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    test_mod.addOptions("build_options", opts);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Roda os testes do núcleo").dependOn(&run_tests.step);
}

//! Núcleo de simulação (camada "Sim").
//!
//!   zig build --release=fast       -> zig-out/lib/libaerosim.so (C ABI, usada pelo Python)
//!   zig build test                 -> todos os testes
//!   zig build test-math            -> só LUTs/polinômios e vetores (também test-physics, test-control, test-sim,
//!                                     test-sizing)
//!   zig build test -Dfuzz=N -Dseed=S -> fuzzing mais longo das interfaces (padrão 2000 entradas por teste)
//!   zig build -Dfast_math=false    -> troca LUT/polinômios por std.math (referência)
const std = @import("std");

pub fn build(b: *std.Build) void {
    // x86: padrão x86-64-v3 (AVX2 + FMA). Com AVX-512 (`-Dcpu=native` em Xeon) o LLVM gera
    // código mais lento para as LUTs (medido: 987 ns -> 1478 ns por avaliação da dinâmica).
    const host = b.graph.host.result;
    const target = b.standardTargetOptions(.{ .default_target = if (host.cpu.arch == .x86_64)
        .{ .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 } }
    else
        .{} });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const fast_math = b.option(bool, "fast_math", "LUT e aproximações polinomiais (padrão: true)") orelse true;
    const strip = b.option(bool, "strip", "remove símbolos (padrão: sim fora do Debug)") orelse (optimize != .Debug);

    const opts = b.addOptions();
    opts.addOption(bool, "fast_math", fast_math);
    opts.addOption(usize, "fuzz_iterations", b.option(usize, "fuzz", "entradas aleatórias por teste de fuzzing (padrão 2000)") orelse 2000);
    opts.addOption(u64, "fuzz_seed", b.option(u64, "seed", "semente do fuzzing (padrão 1)") orelse 1);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .strip = strip,
    });
    mod.addOptions("build_options", opts);

    const lib = b.addLibrary(.{ .linkage = .dynamic, .name = "aerosim", .root_module = mod });

    // o mesmo núcleo como módulo Zig (`@import("aerosim")`): usado pelo aerodrive
    const zmod = b.addModule("aerosim", .{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    zmod.addOptions("build_options", opts);
    b.installArtifact(lib);

    // testes: tudo (`zig build test`) ou por grupo (`zig build test-math`, ...)
    const all = b.step("test", "Roda todos os testes do núcleo");
    inline for (.{ "math", "physics", "control", "sim", "sizing" }) |group| {
        const m = b.createModule(.{
            .root_source_file = b.path("src/tests_" ++ group ++ ".zig"),
            .target = target,
            .optimize = .Debug,
        });
        m.addOptions("build_options", opts);
        const t = b.addTest(.{ .root_module = m, .name = "test-" ++ group });
        const run = b.addRunArtifact(t);
        b.step("test-" ++ group, "Testes do grupo " ++ group).dependOn(&run.step);
        all.dependOn(&run.step);
    }
}

//! Compilar e rodar qualquer programa do projeto a partir da raiz. Cada um continua com o build dele, na pasta dele
//! (`aerosim/build.zig`, `aeroopt/build.zig`, `aerodrive/build.zig`, `core/build.zig`); aqui só se chama o de cada
//! pasta, com o mesmo Zig.
//!
//!   zig build aerosim [-- <avião.json>]     abre o aerosim
//!   zig build aeroopt                        abre o aeroopt
//!   zig build aerodrive                      abre o AeroDrive
//!   zig build                                compila os três (cada um em <pasta>/zig-out/bin)
//!   zig build test                           testes do núcleo, das duas interfaces e do AeroDrive
//!
//! Com o Zig do pip: `python -m ziglang build aerosim`.
const std = @import("std");

const programs = [_][]const u8{ "aerosim", "aeroopt", "aerodrive" };

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Debug, ReleaseSafe, ReleaseFast ou ReleaseSmall (passa para cada programa)");
    const compile_all = b.getInstallStep();
    const test_all = b.step("test", "Testes do núcleo, das interfaces e do AeroDrive");
    for (programs) |name| {
        // abrir
        const run = child(b, name, &.{ "build", "run" }, optimize);
        if (b.args) |args| {
            run.addArg("--");
            run.addArgs(args);
        }
        b.step(name, b.fmt("Compila e abre o {s}", .{name})).dependOn(&run.step);
        // compilar e testar
        compile_all.dependOn(&child(b, name, &.{"build"}, optimize).step);
        test_all.dependOn(&child(b, name, &.{ "build", "test" }, null).step);
    }
    test_all.dependOn(&child(b, "core", &.{ "build", "test" }, null).step);
}

/// `zig <arguments>` na pasta `folder`
fn child(b: *std.Build, folder: []const u8, arguments: []const []const u8, optimize: ?std.builtin.OptimizeMode) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{b.graph.zig_exe});
    run.addArgs(arguments);
    if (optimize) |mode| run.addArg(b.fmt("-Doptimize={s}", .{@tagName(mode)}));
    run.setCwd(b.path(folder));
    run.has_side_effects = true;
    run.stdio = .inherit;
    return run;
}

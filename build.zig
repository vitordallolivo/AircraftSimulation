//! Compilar e rodar qualquer programa do projeto a partir da raiz. Cada um continua com o build dele, na pasta dele
//! (`aerosim/build.zig`, `aeroopt/build.zig`, `aerodrive/build.zig`, `core/build.zig`); aqui só se chama o de cada
//! pasta, com o mesmo Zig.
//!
//!   zig build aerosim [-- <avião.json>]     abre o aerosim
//!   zig build aeroopt                        abre o aeroopt
//!   zig build aerodrive                      abre o AeroDrive
//!   zig build launcher                       monta a documentação e abre a tela inicial do pacote (o menu do site,
//!                                            que abre os três e a documentação)
//!   zig build docs                           monta o site da documentação em zig-out/site (livro, mapa, tracking);
//!                                            `zig build site` é o mesmo
//!   zig build                                compila os quatro (cada um em <pasta>/zig-out/bin) e monta a documentação
//!   zig build test                           testes do núcleo, das duas interfaces e do AeroDrive
//!
//! Os programas saem em ReleaseSafe (as contas com as verificações do Zig, mas otimizadas; em Debug a análise da
//! asa fica lenta demais para usar); `-Doptimize=Debug` volta ao modo de depuração.
//!
//! A documentação é o `tools/livro.zig` (que usa o `grafo.zig` e o `tracking.zig`); `-Ddocs=false` a deixa de fora.
//! As outras ferramentas de `tools/` também são passos: `zig build mapa`, `zig build tracking`, `zig build site`.
//!
//! Com o Zig do pip: `python -m ziglang build aerosim`.
const std = @import("std");

const programs = [_][]const u8{ "aerosim", "aeroopt", "aerodrive", "launcher" };

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Debug, ReleaseSafe (padrão), ReleaseFast ou ReleaseSmall (passa para cada programa)") orelse .ReleaseSafe;
    const compile_all = b.getInstallStep();
    const test_all = b.step("test", "Testes do núcleo, das interfaces, da tela inicial e do AeroDrive");
    const with_docs = b.option(bool, "docs", "Monta a documentação junto do build e do launcher (padrão: sim)") orelse true;
    // o site sem argumentos, para ser montado junto do build e antes do launcher (os argumentos são do programa)
    const docs = toolRun(b, tool(b, "site", "livro.zig", "Monta o site da documentação em zig-out/site (livro, mapa do código e tracking); -- --saida <pasta> grava em outra pasta"));
    b.step("docs", "Monta o site da documentação em zig-out/site (livro, mapa do código e tracking)").dependOn(&docs.step);
    if (with_docs) compile_all.dependOn(&docs.step);
    for (programs) |name| {
        // abrir
        const run = child(b, name, &.{ "build", "run" }, optimize);
        if (b.args) |args| {
            run.addArg("--");
            run.addArgs(args);
        }
        // a tela inicial abre a documentação, então ela é montada antes
        if (with_docs and std.mem.eql(u8, name, "launcher")) run.step.dependOn(&docs.step);
        b.step(name, b.fmt("Compila e abre o {s}", .{name})).dependOn(&run.step);
        // compilar e testar
        compile_all.dependOn(&child(b, name, &.{"build"}, optimize).step);
        test_all.dependOn(&child(b, name, &.{ "build", "test" }, null).step);
    }
    test_all.dependOn(&child(b, "core", &.{ "build", "test" }, null).step);
    // os testes das ferramentas, ao lado do código delas
    for ([_][]const u8{ "codemap.zig", "tracking.zig", "grafo.zig", "livro.zig" }) |file| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("tools/{s}", .{file})), .target = b.graph.host }) });
        test_all.dependOn(&b.addRunArtifact(tests).step);
    }

    // as ferramentas de tools/ (programas em Zig que rodam da raiz)
    _ = tool(b, "mapa", "codemap.zig", "Refaz docs/MAP.md (o mapa do código); -- --check só confere");
    _ = tool(b, "tracking", "tracking.zig", "Página do tracking (zig-out/site/tracking.html); -- --check, --feito, --estado, --issue mudam ou conferem o TRACKING.md");
}

/// uma ferramenta de `tools/` como passo `zig build <step_name>`: compila `tools/<file>` e roda da raiz, com os
/// argumentos depois do `--`; devolve o executável
fn tool(b: *std.Build, step_name: []const u8, file: []const u8, description: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = step_name, .root_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/{s}", .{file})),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = toolRun(b, exe);
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, description).dependOn(&run.step);
    return exe;
}

/// roda a ferramenta da raiz do repositório, sem argumentos
fn toolRun(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.stdio = .inherit;
    return run;
}

/// `zig <arguments>` na pasta `folder`; o modo vai como `--release=...`, porque os builds das pastas têm um modo
/// preferido (e aí o Zig não aceita `-Doptimize`)
fn child(b: *std.Build, folder: []const u8, arguments: []const []const u8, optimize: ?std.builtin.OptimizeMode) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{b.graph.zig_exe});
    run.addArgs(arguments);
    if (optimize) |mode| switch (mode) {
        .Debug => {},
        .ReleaseSafe => run.addArg("--release=safe"),
        .ReleaseFast => run.addArg("--release=fast"),
        .ReleaseSmall => run.addArg("--release=small"),
    };
    run.setCwd(b.path(folder));
    run.has_side_effects = true;
    run.stdio = .inherit;
    return run;
}

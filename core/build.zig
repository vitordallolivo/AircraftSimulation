//! Núcleo de simulação (camada "Sim").
//!
//!   zig build --release=fast       -> zig-out/lib/libaerosim.so (C ABI, usada pelo Python)
//!   zig build test                 -> todos os testes (src/tests.zig)
//!   zig build test -Dgrupo=math    -> só um grupo: math, physics, control, sim, sizing, optim, geometry, structures
//!   zig build test -Dfiltro=trim   -> só os testes cujo nome contém o texto (junta com -Dgrupo)
//!   zig build test -Darquivo=loads/vn.zig      -> só os testes desse arquivo (compila só ele e o que ele importa)
//!   zig build test -Dgraficos=graficos         -> os testes que desenham gravam os SVG nessa pasta
//!   zig build test -Dfuzz=N -Dseed=S -> fuzzing mais longo das interfaces (padrão 2000 entradas por teste)
//!   zig build -Dfast_math=false    -> troca LUT/polinômios por std.math (referência)
//!   zig build -Dopt=peak,cse       -> otimizações em avaliação (ver core/OTIMIZACOES.md)
//!   zig build docs                 -> zig-out/docs: a documentação do Zig gerada dos `///` (abrir por um servidor)
const std = @import("std");

/// as otimizações de `-Dopt`: o enum (nome = bit) fica em `src/opt.zig`, o mesmo que o código consulta
const Opt = @import("src/opt.zig").Opt;
/// "noinline, floatmode, ..." (os nomes do enum, para a ajuda e a mensagem de erro)
const opt_list = blk: {
    var s: []const u8 = "";
    for (@typeInfo(Opt).@"enum".fields, 0..) |f, i| s = s ++ (if (i == 0) "" else ", ") ++ f.name;
    break :blk s;
};

/// "peak,cse" -> 24; "24" -> 24; nome desconhecido para o build com a lista
fn optBits(text: []const u8) u8 {
    if (std.fmt.parseInt(u8, text, 10)) |n| return n else |_| {}
    var bits: u8 = 0;
    var it = std.mem.tokenizeAny(u8, text, ", +");
    while (it.next()) |name| {
        const o = std.meta.stringToEnum(Opt, name) orelse
            std.debug.panic("-Dopt: '{s}' não existe; use {s} (ou a soma dos bits)", .{ name, opt_list });
        bits |= o.bit();
    }
    return bits;
}

/// os grupos de `-Dgrupo` (cada um é um bloco `test` em src/tests.zig)
const test_groups = .{ "tudo", "math", "physics", "control", "sim", "sizing", "optim", "geometry", "structures" };
const test_group_list = "tudo, math, physics, control, sim, sizing, optim, geometry, structures";

/// verdadeiro se `name` é um dos `test_groups`
fn isTestGroup(name: []const u8) bool {
    inline for (test_groups) |group| if (std.mem.eql(u8, name, group)) return true;
    return false;
}

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
    // otimizações em avaliação (0 = o núcleo de sempre). Por nome ou por número (a soma dos bits):
    //   -Dopt=peak,cse   ou   -Dopt=24          (tabela e resultados: core/OTIMIZACOES.md)
    opts.addOption(u8, "opt", optBits(b.option([]const u8, "opt", "otimizações em avaliação: nomes separados por " ++
        "vírgula (" ++ opt_list ++ ") ou a soma dos bits (padrão: nenhuma)") orelse "0"));
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

    // no navegador (`-Dtarget=wasm32-emscripten`) sai uma biblioteca estática com código relocável: o emcc a liga como
    // side module, que o Pyodide carrega e o mesmo `ctypes` do PC chama (tools/web_build.py faz isso)
    const in_browser = target.result.os.tag == .emscripten;
    if (in_browser) mod.pic = true;
    const lib = b.addLibrary(.{ .linkage = if (in_browser) .static else .dynamic, .name = "aerosim", .root_module = mod });

    // o mesmo núcleo como módulo Zig (`@import("aerosim")`): usado pelo aerodrive
    const zmod = b.addModule("aerosim", .{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    zmod.addOptions("build_options", opts);
    b.installArtifact(lib);

    // documentação (o autodoc do Zig): src/aerosim.zig reexporta todas as pastas (o autodoc toma como raiz o arquivo com o nome do módulo)
    const docs_mod = b.createModule(.{ .root_source_file = b.path("src/aerosim.zig"), .target = target, .optimize = .Debug });
    docs_mod.addOptions("build_options", opts);
    const docs_obj = b.addObject(.{ .name = "aerosim", .root_module = docs_mod });
    const install_docs = b.addInstallDirectory(.{ .source_dir = docs_obj.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Gera a documentação HTML em zig-out/docs (servir com `python -m http.server`)").dependOn(&install_docs.step);

    // bancada das técnicas de otimização: em release e com símbolos, para o objdump achar as funções
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/tecnicas.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize, // medir em Debug não diz nada
        .strip = false,
    });
    bench_module.addOptions("build_options", opts);
    const bench_exe = b.addExecutable(.{ .name = "tecnicas", .root_module = bench_module });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("tecnicas", "Mede uma técnica de otimização: zig build tecnicas -- <técnica> <variante> [rodadas]");
    bench_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
    bench_step.dependOn(&bench_run.step);

    // testes: um binário só (src/tests.zig); o grupo e o filtro vêm do CLI
    const test_group = b.option([]const u8, "grupo", "grupo de testes: " ++ test_group_list ++ " (padrão: tudo)") orelse "tudo";
    if (!isTestGroup(test_group)) std.debug.panic("-Dgrupo: '{s}' não existe; use {s}", .{ test_group, test_group_list });
    const test_filter = b.option([]const u8, "filtro", "só os testes cujo nome contém este texto");
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "test_group", test_group);
    // -Dgraficos=<pasta>: os testes que desenham (`util/plot.zig`, `fromTest`) gravam os SVG ali
    test_opts.addOption([]const u8, "plot_dir", b.option([]const u8, "graficos", "pasta onde os testes gravam os gráficos em SVG (padrão: nenhum gráfico)") orelse "");
    // -Darquivo=loads/vn.zig: compila e roda só os testes desse arquivo. O Zig não deixa um módulo importar acima da
    // pasta dele, então a raiz é uma cópia de src/ com um arquivo que importa o pedido
    const test_file = b.option([]const u8, "arquivo", "só os testes deste arquivo, relativo a src/ (ex.: loads/vn.zig)");
    const test_root = if (test_file) |file| blk: {
        const files = b.addWriteFiles();
        _ = files.addCopyDirectory(b.path("src"), "src", .{});
        break :blk files.add("teste_arquivo.zig", b.fmt("test {{\n    _ = @import(\"src/{s}\");\n}}\n", .{file}));
    } else b.path("src/tests.zig");
    const test_module = b.createModule(.{
        .root_source_file = test_root,
        .target = target,
        .optimize = .Debug,
    });
    test_module.addOptions("build_options", opts);
    test_module.addOptions("test_options", test_opts);
    const tests = b.addTest(.{
        .root_module = test_module,
        .name = "test",
        .filters = if (test_filter) |text| b.dupeStrings(&.{text}) else &.{},
    });
    b.step("test", "Roda os testes do núcleo (-Dgrupo=..., -Dfiltro=...)").dependOn(&b.addRunArtifact(tests).step);
}

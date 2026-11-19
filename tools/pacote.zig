//! Monta o AircraftSimulation para distribuir: o programa instalável (a tela inicial, o aerosim, o aeroopt e o
//! AeroDrive numa pasta só, com os aviões de exemplo e os perfis, e daí o AppImage do Linux ou o instalador do
//! Windows) ou o site, com os três programas em WebAssembly.
//!
//!     zig build pacote                          Linux: dist/AircraftSimulation-linux/ e, com o appimagetool, o .AppImage
//!     zig build pacote -- --alvo windows        Windows (compilado daqui): dist/AircraftSimulation-windows/ e, com o
//!                                               makensis (NSIS), o instalador .exe
//!     zig build pacote -- --alvo web            o site em zig-out/site (servir com `python -m http.server -d zig-out/site`)
//!     zig build pacote -- --sem-compilar        só monta, com o que já está compilado
//!     zig build pacote -- --sem-python          sem os métodos de fora do núcleo (lltdrek, AeroSandbox, AVL)
//!
//! Tudo o que o aerosim calcula roda no próprio programa. Só os métodos de fora do núcleo são bibliotecas em Python,
//! chamadas pelo adaptador `aerosim/bridge.py`, e por isso vão junto, quando não é `--sem-python`:
//!   - no instalável, na pasta `app/`: um Python portátil (`app/python`, python-build-standalone,
//!     https://github.com/astral-sh/python-build-standalone) com o numpy e as bibliotecas que o pip achar para o alvo
//!     (aerosandbox, lltdrek, optvl), mais o adaptador e uma cópia de `data/`. A tela acha esse Python sozinha
//!     (`aerosim/gui/python_bridge.zig`);
//!   - no site: o Pyodide com o numpy (pasta `pyodide/`), o adaptador e a pasta data (`aerosim-python.tar`) e a página
//!     que carrega isso num iframe (`aerosim-python.html`), que a tela só abre quando um desses métodos é pedido.
//! Os downloads (o Python portátil, o Pyodide) ficam em cache (`dist/cache`) e saem pelo `curl`; o `tar` extrai.
//!
//! O appimagetool vem de https://github.com/AppImage/appimagetool (variável APPIMAGETOOL ou no PATH); o makensis, do
//! pacote `nsis` (apt) ou de https://nsis.sourceforge.io. Sem eles, fica só a pasta. Os caminhos dentro do site são
//! relativos, então a mesma pasta serve na raiz de um servidor ou numa subpasta (o GitHub Pages). O GitHub Actions
//! roda este programa sem chave nenhuma: `.github/workflows/pacotes.yml` (instaláveis) e `site.yml` (site).
const std = @import("std");
const Allocator = std.mem.Allocator;

const Target = enum { linux, windows, web };

/// cada programa: a pasta do build.zig e o nome do executável; a tela inicial primeiro, porque é ela que o pacote abre
const programs = [_]struct { folder: []const u8, name: []const u8 }{
    .{ .folder = "launcher", .name = "aircraftsimulation" },
    .{ .folder = "aerosim", .name = "aerosim" },
    .{ .folder = "aeroopt", .name = "aeroopt" },
    .{ .folder = "aerodrive", .name = "aerodrive" },
};
/// os que vão para o navegador (a tela inicial do site é `web/index.html`)
const web_programs = [_][]const u8{ "aerodrive", "aerosim", "aeroopt" };
const web_extensions = [_][]const u8{ ".html", ".js", ".wasm", ".data" };
const data_parts = [_][]const u8{ "aircraft", "airfoils" };

const python_version = "3.12.7";
const python_release = "20241016";
const python_needed = [_][]const u8{"numpy"}; // o que o adaptador importa sempre
const python_optional = [_][]const u8{ "aerosandbox", "optvl", "git+https://github.com/kuodrek/lltdrek.git" }; // requirements-aero.txt

const pyodide_version = "314.0.7";
const pyodide_files = [_][]const u8{ "pyodide.mjs", "pyodide.asm.mjs", "pyodide.asm.wasm", "python_stdlib.zip", "pyodide-lock.json" };
const pyodide_packages = [_][]const u8{"numpy"};

const Context = struct {
    memory: Allocator,
    io: std.Io,
    zig: []const u8,
    python: []const u8,
    environ: *std.process.Environ.Map,
};

/// lê as opções e monta o alvo
pub fn main(init: std.process.Init) !void {
    const memory = init.arena.allocator();
    const args = try init.minimal.args.toSlice(memory);
    var context: Context = .{
        .memory = memory,
        .io = init.io,
        .zig = init.environ_map.get("ZIG") orelse "zig",
        .python = init.environ_map.get("PYTHON") orelse "python3",
        .environ = init.environ_map,
    };
    var target: Target = if (@import("builtin").os.tag == .windows) .windows else .linux;
    var compile = true;
    var with_python = true;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--sem-compilar")) compile = false else if (std.mem.eql(u8, arg, "--sem-python")) with_python = false else if (std.mem.eql(u8, arg, "--alvo") and index + 1 < args.len) {
            index += 1;
            target = std.meta.stringToEnum(Target, args[index]) orelse return fail("alvo desconhecido: {s} (linux, windows ou web)", .{args[index]});
        } else return fail("opção desconhecida: {s} (veja tools/pacote.zig)", .{arg});
    }
    switch (target) {
        .web => {
            if (compile) for (web_programs) |folder| {
                // o aerosim e o aeroopt em ReleaseSafe, como no PC (em Debug a análise da asa fica lenta demais)
                const release: []const []const u8 = if (std.mem.eql(u8, folder, "aerodrive")) &.{} else &.{"--release=safe"};
                std.debug.print("compilando o {s} para o navegador\n", .{folder});
                try zigBuild(&context, folder, release, &.{"-Dtarget=wasm32-emscripten"});
            };
            const site = "zig-out/site";
            try assembleSite(&context, site);
            if (with_python) try sitePython(&context, site);
            try report(&context, site);
        },
        .linux, .windows => {
            if (compile) for (programs) |program| {
                std.debug.print("compilando {s} ({s})\n", .{ program.folder, @tagName(target) });
                // no Linux, o alvo nativo (com -Dtarget o Zig não procura as bibliotecas do sistema, como a do OpenGL),
                // mas com a CPU de base, para o programa rodar em qualquer x86_64
                const where = if (target == .linux) "-Dcpu=baseline" else "-Dtarget=x86_64-windows-gnu";
                try zigBuild(&context, program.folder, &.{"--release=safe"}, &.{ where, "--prefix", try std.fmt.allocPrint(memory, "zig-out/{s}", .{@tagName(target)}) });
            };
            const folder = try assembleInstallable(&context, target);
            if (with_python) try installablePython(&context, target, folder);
            if (target == .linux) try appImage(&context, folder) else try installer(&context, folder);
        },
    }
}

fn fail(comptime format: []const u8, args: anytype) error{Failed} {
    std.debug.print(format ++ "\n", args);
    return error.Failed;
}

// ------------------------------------------------------------------ comandos e arquivos

/// roda `argv` (na pasta `folder`, se dada) com a saída na tela; erro se não sai com 0
fn shell(context: *Context, folder: ?[]const u8, argv: []const []const u8, environ: ?*const std.process.Environ.Map) !void {
    var child = try std.process.spawn(context.io, .{
        .argv = argv,
        .cwd = if (folder) |path| .{ .path = path } else .inherit,
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(context.io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return fail("falhou: {s}", .{argv[0]});
}

/// `zig build` numa pasta do repositório
fn zigBuild(context: *Context, folder: []const u8, release: []const []const u8, extra: []const []const u8) !void {
    const argv = try std.mem.concat(context.memory, []const u8, &.{ &.{ context.zig, "build" }, release, extra });
    try shell(context, folder, argv, null);
}

/// o primeiro programa achado no PATH com este nome (ou nulo)
fn which(context: *Context, name: []const u8) ?[]const u8 {
    const path = context.environ.get("PATH") orelse return null;
    var folders = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (folders.next()) |folder| {
        const candidate = std.fs.path.join(context.memory, &.{ folder, name }) catch return null;
        std.Io.Dir.cwd().access(context.io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

fn exists(context: *Context, path: []const u8) bool {
    std.Io.Dir.cwd().access(context.io, path, .{}) catch return false;
    return true;
}

fn copy(context: *Context, from: []const u8, to: []const u8) !void {
    std.Io.Dir.copyFile(std.Io.Dir.cwd(), from, std.Io.Dir.cwd(), to, context.io, .{ .make_path = true, .replace = true }) catch |err|
        return fail("não copiou {s}: {s}", .{ from, @errorName(err) });
}

/// copia a pasta `from` inteira para `to`
fn copyTree(context: *Context, from: []const u8, to: []const u8) !void {
    var source = try std.Io.Dir.cwd().openDir(context.io, from, .{ .iterate = true });
    defer source.close(context.io);
    var walker = try source.walk(context.memory);
    defer walker.deinit();
    while (try walker.next(context.io)) |entry| {
        const destination = try std.fs.path.join(context.memory, &.{ to, entry.path });
        switch (entry.kind) {
            .file => try copy(context, try std.fs.path.join(context.memory, &.{ from, entry.path }), destination),
            .sym_link => { // os atalhos do Python portátil (python3 → python3.12) continuam atalhos
                var target: [std.fs.max_path_bytes]u8 = undefined;
                const length = try entry.dir.readLink(context.io, entry.basename, &target);
                try std.Io.Dir.cwd().createDirPath(context.io, std.fs.path.dirname(destination).?);
                try std.Io.Dir.cwd().symLink(context.io, target[0..length], destination, .{});
            },
            else => {},
        }
    }
}

/// baixa `url` para `path` uma vez (o `curl` passa pelo proxy do sistema; um download pela metade não fica)
fn download(context: *Context, url: []const u8, path: []const u8) !void {
    if (exists(context, path)) return;
    std.debug.print("baixando {s}\n", .{url});
    try std.Io.Dir.cwd().createDirPath(context.io, std.fs.path.dirname(path).?);
    const partial = try std.fmt.allocPrint(context.memory, "{s}.parte", .{path});
    try shell(context, null, &.{ "curl", "-fsSL", "-o", partial, url }, null);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), partial, std.Io.Dir.cwd(), path, context.io);
}

/// os arquivos do adaptador dos métodos de fora como estão no git: os .py do aerosim (fora da tela) e a pasta data
fn adapterFiles(context: *Context) ![]const []const u8 {
    const result = try std.process.run(context.memory, context.io, .{ .argv = &.{ "git", "ls-files", "aerosim", "data" } });
    var files: std.ArrayList([]const u8) = .empty;
    var names = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
    while (names.next()) |name| {
        const python_file = std.mem.endsWith(u8, name, ".py") and !std.mem.startsWith(u8, name, "aerosim/gui/");
        if (std.mem.startsWith(u8, name, "data/") or python_file) try files.append(context.memory, name);
    }
    return files.items;
}

// ------------------------------------------------------------------ o site

/// a tela inicial e os programas do navegador em `site` (apaga a montagem anterior), mais o livro e o tracking
fn assembleSite(context: *Context, site: []const u8) !void {
    for (web_programs) |folder| for (web_extensions) |extension| {
        const built = try std.fmt.allocPrint(context.memory, "{s}/zig-out/web/{s}{s}", .{ folder, folder, extension });
        if (!exists(context, built)) return fail("falta {s} (rode sem --sem-compilar)", .{built});
    };
    std.Io.Dir.cwd().deleteTree(context.io, site) catch {};
    try std.Io.Dir.cwd().createDirPath(context.io, site);
    try copy(context, "web/index.html", try std.fmt.allocPrint(context.memory, "{s}/index.html", .{site}));
    for (web_programs) |folder| for (web_extensions) |extension| {
        try copy(context, try std.fmt.allocPrint(context.memory, "{s}/zig-out/web/{s}{s}", .{ folder, folder, extension }), try std.fmt.allocPrint(context.memory, "{s}/{s}{s}", .{ site, folder, extension }));
    };
    // o livro do projeto (todos os .md), o mapa do código e o tracking
    try shell(context, null, &.{ context.zig, "build", "site", "--", "--saida", site }, null);
    // o GitHub Pages não passa a pasta pelo Jekyll (que esconderia arquivos e atrasaria a publicação)
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = try std.fmt.allocPrint(context.memory, "{s}/.nojekyll", .{site}), .data = "" });
}

/// o Pyodide, o adaptador e a página dele no site (ver o começo deste arquivo)
fn sitePython(context: *Context, site: []const u8) !void {
    const memory = context.memory;
    const cache = try std.fmt.allocPrint(memory, "dist/cache/pyodide-{s}", .{pyodide_version});
    const lock_path = try std.fmt.allocPrint(memory, "{s}/pyodide-lock.json", .{cache});
    if (!exists(context, lock_path)) {
        const archive = try std.fmt.allocPrint(memory, "dist/cache/pyodide-{s}.tar.bz2", .{pyodide_version});
        try download(context, try std.fmt.allocPrint(memory, "https://github.com/pyodide/pyodide/releases/download/{s}/pyodide-{s}.tar.bz2", .{ pyodide_version, pyodide_version }), archive);
        try std.Io.Dir.cwd().createDirPath(context.io, cache);
        std.debug.print("extraindo o Pyodide\n", .{});
        try shell(context, null, &.{ "tar", "-xjf", archive, "-C", cache, "--strip-components=1" }, null);
        std.Io.Dir.cwd().deleteFile(context.io, archive) catch {};
    }
    // os arquivos do núcleo do Pyodide, os pacotes e as dependências deles (do pyodide-lock.json)
    const lock_text = try std.Io.Dir.cwd().readFileAlloc(context.io, lock_path, memory, .unlimited);
    const lock = try std.json.parseFromSliceLeaky(std.json.Value, memory, lock_text, .{});
    const packages = lock.object.get("packages").?.object;
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(memory, &pyodide_files);
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.appendSlice(memory, &pyodide_packages);
    while (pending.pop()) |name| {
        const package = (packages.get(name) orelse return fail("o Pyodide não tem o pacote {s}", .{name})).object;
        const file = package.get("file_name").?.string;
        for (names.items) |known| {
            if (std.mem.eql(u8, known, file)) break;
        } else {
            try names.append(memory, file);
            for (package.get("depends").?.array.items) |dependency| try pending.append(memory, dependency.string);
        }
    }
    for (names.items) |name| try copy(context, try std.fmt.allocPrint(memory, "{s}/{s}", .{ cache, name }), try std.fmt.allocPrint(memory, "{s}/pyodide/{s}", .{ site, name }));

    // o adaptador e a pasta data num .tar, que a página extrai no Pyodide
    var archive: std.Io.Writer.Allocating = .init(memory);
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    for (try adapterFiles(context)) |name| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(context.io, name, memory, .unlimited);
        try tar.writeFileBytes(name, bytes, .{ .mode = 0o644 });
    }
    try tar.finishPedantically();
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = try std.fmt.allocPrint(memory, "{s}/aerosim-python.tar", .{site}), .data = archive.written() });
    try copy(context, "aerosim/gui/web/python.html", try std.fmt.allocPrint(memory, "{s}/aerosim-python.html", .{site}));
}

/// o tamanho do site e o que ele tem
fn report(context: *Context, site: []const u8) !void {
    var folder = try std.Io.Dir.cwd().openDir(context.io, site, .{ .iterate = true });
    defer folder.close(context.io);
    var walker = try folder.walk(context.memory);
    var total: u64 = 0;
    while (try walker.next(context.io)) |entry| {
        if (entry.kind == .file) total += (try entry.dir.statFile(context.io, entry.basename, .{})).size;
    }
    std.debug.print("site montado em {s} ({d:.1} MiB)\n", .{ site, @as(f64, @floatFromInt(total)) / (1 << 20) });
}

// ------------------------------------------------------------------ o instalável

/// copia os programas, os dados e a página do site para dist/AircraftSimulation-<alvo>; devolve a pasta
fn assembleInstallable(context: *Context, target: Target) ![]const u8 {
    const memory = context.memory;
    const suffix = if (target == .windows) ".exe" else "";
    const out = try std.fmt.allocPrint(memory, "dist/AircraftSimulation-{s}", .{@tagName(target)});
    std.Io.Dir.cwd().deleteTree(context.io, out) catch {};
    try std.Io.Dir.cwd().createDirPath(context.io, out);
    for (programs) |program| {
        const built = try std.fmt.allocPrint(memory, "{s}/zig-out/{s}/bin/{s}{s}", .{ program.folder, @tagName(target), program.name, suffix });
        if (!exists(context, built)) return fail("falta {s} (rode sem --sem-compilar)", .{built});
        try copy(context, built, try std.fmt.allocPrint(memory, "{s}/{s}{s}", .{ out, program.name, suffix }));
    }
    for (data_parts) |part| { // só copia: nada dentro de data/ é gerado nem editado
        try copyTree(context, try std.fmt.allocPrint(memory, "data/{s}", .{part}), try std.fmt.allocPrint(memory, "{s}/data/{s}", .{ out, part }));
    }
    try copy(context, "web/index.html", try std.fmt.allocPrint(memory, "{s}/site/index.html", .{out}));
    for (web_extensions) |extension| { // o AeroDrive do navegador, se já foi compilado
        const built = try std.fmt.allocPrint(memory, "aerodrive/zig-out/web/aerodrive{s}", .{extension});
        if (exists(context, built)) try copy(context, built, try std.fmt.allocPrint(memory, "{s}/site/aerodrive{s}", .{ out, extension }));
    }
    // a documentação (livro, mapa do código e tracking), que a tela inicial abre no navegador
    try shell(context, null, &.{ context.zig, "build", "site", "--", "--saida", try std.fmt.allocPrint(memory, "{s}/site", .{out}) }, null);
    std.debug.print("pasta montada: {s}\n", .{out});
    return out;
}

/// instala `packages` no Python do pacote (`app` é a pasta `app/`): no Linux, pelo próprio Python portátil; no
/// Windows (compilado daqui), pelo pip de quem roda, só com wheels do Windows, direto no site-packages
fn pipInstall(context: *Context, target: Target, app: []const u8, packages: []const []const u8) bool {
    const memory = context.memory;
    const base: []const []const u8 = if (target == .linux)
        &.{ std.fmt.allocPrint(memory, "{s}/python/bin/python3", .{app}) catch return false, "-m", "pip", "install", "--no-warn-script-location" }
    else
        &.{ context.python, "-m", "pip", "install", "--target", std.fmt.allocPrint(memory, "{s}/python/Lib/site-packages", .{app}) catch return false, "--platform", "win_amd64", "--python-version", "312", "--implementation", "cp", "--only-binary=:all:", "--upgrade" };
    const argv = std.mem.concat(memory, []const u8, &.{ base, &.{ "--disable-pip-version-check", "-q" }, packages }) catch return false;
    shell(context, null, argv, null) catch return false;
    return true;
}

/// o Python portátil com as bibliotecas, o adaptador e o `data/` inteiro na pasta `app/` (à parte porque no Linux o
/// programa `aerosim` e a pasta `aerosim/` do Python teriam o mesmo nome)
fn installablePython(context: *Context, target: Target, folder: []const u8) !void {
    const memory = context.memory;
    const app = try std.fmt.allocPrint(memory, "{s}/app", .{folder});
    try std.Io.Dir.cwd().createDirPath(context.io, app);
    const triple = if (target == .linux) "x86_64-unknown-linux-gnu" else "x86_64-pc-windows-msvc";
    const name = try std.fmt.allocPrint(memory, "cpython-{s}+{s}-{s}-install_only.tar.gz", .{ python_version, python_release, triple });
    const archive = try std.fmt.allocPrint(memory, "dist/cache/{s}", .{name});
    try download(context, try std.fmt.allocPrint(memory, "https://github.com/astral-sh/python-build-standalone/releases/download/{s}/{s}", .{ python_release, name }), archive);
    try shell(context, null, &.{ "tar", "-xzf", archive, "-C", app }, null); // o arquivo traz a pasta python/
    if (!pipInstall(context, target, app, &python_needed)) return fail("o pip não instalou o numpy", .{});
    for (python_optional) |package| { // opcionais: sem eles, a tela diz que o método não está disponível
        var ok: bool = undefined;
        if (std.mem.startsWith(u8, package, "git+") and target == .windows) { // do git: a wheel pura primeiro
            const wheels = "dist/cache/wheels";
            ok = blk: {
                shell(context, null, &.{ context.python, "-m", "pip", "wheel", "--no-deps", "-q", "-w", wheels, package }, null) catch break :blk false;
                var found: std.ArrayList([]const u8) = .empty;
                var dir = std.Io.Dir.cwd().openDir(context.io, wheels, .{ .iterate = true }) catch break :blk false;
                defer dir.close(context.io);
                var entries = dir.iterate();
                while (entries.next(context.io) catch null) |entry| {
                    if (std.mem.endsWith(u8, entry.name, ".whl")) found.append(memory, std.fs.path.join(memory, &.{ wheels, entry.name }) catch break :blk false) catch break :blk false;
                }
                break :blk found.items.len > 0 and pipInstall(context, target, app, found.items);
            };
        } else ok = pipInstall(context, target, app, &.{package});
        std.debug.print("{s}{s}\n", .{ if (ok) "instalado: " else "pulado (o pip não achou para este alvo): ", package });
    }
    for (try adapterFiles(context)) |file| try copy(context, file, try std.fmt.allocPrint(memory, "{s}/{s}", .{ app, file }));
    std.debug.print("Python dos métodos de fora: {s}/python\n", .{app});
}

/// o AppImage: a pasta vai em usr/lib/aircraftsimulation e o AppRun abre a tela inicial
fn appImage(context: *Context, folder: []const u8) !void {
    const memory = context.memory;
    const app_dir = "dist/AircraftSimulation.AppDir";
    std.Io.Dir.cwd().deleteTree(context.io, app_dir) catch {};
    try copyTree(context, folder, app_dir ++ "/usr/lib/aircraftsimulation");
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = app_dir ++ "/AppRun", .data = "#!/bin/sh\nexec \"$APPDIR/usr/lib/aircraftsimulation/aircraftsimulation\" \"$@\"\n" });
    try std.Io.Dir.cwd().setFilePermissions(context.io, app_dir ++ "/AppRun", .executable_file, .{});
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = app_dir ++ "/aircraftsimulation.desktop", .data = "[Desktop Entry]\nType=Application\nName=AircraftSimulation\n" ++
        "Comment=Dimensionar uma aeronave e voar o resultado\nExec=aircraftsimulation\nIcon=aircraftsimulation\nCategories=Science;Education;\nTerminal=false\n" });
    try copy(context, "aerosim/gui/ui/albatroz.png", app_dir ++ "/aircraftsimulation.png");
    // os executáveis copiados (os programas e o Python portátil) mantêm o modo de origem pelo copyFile
    const tool = context.environ.get("APPIMAGETOOL") orelse which(context, "appimagetool") orelse {
        std.debug.print("sem o appimagetool: ficou só a pasta {s}\n", .{app_dir});
        return;
    };
    const image = "dist/AircraftSimulation-x86_64.AppImage";
    var environ = try context.environ.clone(memory);
    try environ.put("ARCH", "x86_64");
    try shell(context, null, &.{ tool, app_dir, image }, &environ);
    std.debug.print("AppImage: {s}\n", .{image});
}

const nsis_script =
    \\; instalador do AircraftSimulation (gerado por tools/pacote.zig)
    \\Unicode true
    \\Name "AircraftSimulation"
    \\OutFile "{s}"
    \\InstallDir "$PROGRAMFILES64\AircraftSimulation"
    \\RequestExecutionLevel admin
    \\SetCompressor /SOLID lzma
    \\Page directory
    \\Page instfiles
    \\UninstPage uninstConfirm
    \\UninstPage instfiles
    \\
    \\Section "AircraftSimulation"
    \\  SetShellVarContext all
    \\  SetOutPath "$INSTDIR"
    \\  File /r "{s}/*"
    \\  WriteUninstaller "$INSTDIR\desinstalar.exe"
    \\  ; aparece em "Adicionar ou remover programas"
    \\  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation" "DisplayName" "AircraftSimulation"
    \\  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation" "UninstallString" "$INSTDIR\desinstalar.exe"
    \\  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation" "DisplayIcon" "$INSTDIR\aircraftsimulation.exe"
    \\  CreateDirectory "$SMPROGRAMS\AircraftSimulation"
    \\  CreateShortcut "$SMPROGRAMS\AircraftSimulation\AircraftSimulation.lnk" "$INSTDIR\aircraftsimulation.exe" "" "" 0 SW_SHOWNORMAL "" "Dimensionar uma aeronave e voar o resultado"
    \\  CreateShortcut "$SMPROGRAMS\AircraftSimulation\Desinstalar.lnk" "$INSTDIR\desinstalar.exe"
    \\  CreateShortcut "$DESKTOP\AircraftSimulation.lnk" "$INSTDIR\aircraftsimulation.exe"
    \\SectionEnd
    \\
    \\Section "Uninstall"
    \\  SetShellVarContext all
    \\  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\AircraftSimulation"
    \\  RMDir /r "$SMPROGRAMS\AircraftSimulation"
    \\  Delete "$DESKTOP\AircraftSimulation.lnk"
    \\  RMDir /r "$INSTDIR"
    \\SectionEnd
    \\
;

/// o instalador .exe (NSIS), em Arquivos de Programas, com atalhos e desinstalador (sem assinatura: o Windows avisa
/// na primeira vez); sem o makensis, fica só a pasta
fn installer(context: *Context, folder: []const u8) !void {
    const memory = context.memory;
    const tool = which(context, "makensis") orelse {
        std.debug.print("sem o makensis: ficou só a pasta {s}\n", .{folder});
        return;
    };
    const root = try std.Io.Dir.cwd().realPathFileAlloc(context.io, ".", memory);
    const out_file = try std.fs.path.join(memory, &.{ root, "dist", "AircraftSimulation-instalador.exe" });
    const source = try std.fs.path.join(memory, &.{ root, folder });
    const script = try std.fmt.allocPrint(memory, nsis_script, .{ out_file, source });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = "dist/instalador.nsi", .data = script });
    try shell(context, null, &.{ tool, "-V2", "dist/instalador.nsi" }, null);
    std.debug.print("instalador: {s}\n", .{out_file});
}

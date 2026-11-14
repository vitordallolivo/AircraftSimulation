//! Mapa do código: gera docs/MAP.md a partir do próprio código (nunca editar o MAP.md à mão).
//!
//!     zig build mapa                 reescreve docs/MAP.md
//!     zig build mapa -- --check      sai com 1 se o docs/MAP.md estiver desatualizado
//!
//! Para cada arquivo: no Python, a primeira linha da docstring do módulo e as classes e funções públicas (do nível do
//! módulo) com a linha; no Zig, a primeira linha do comentário `//!`, os `pub fn`, os `pub const` de tipos e os
//! `export fn` (a ABI). Mais as ferramentas de `tools/` e os README.md. Só lê o texto dos arquivos.
const std = @import("std");

const output_path = "docs/MAP.md";
/// pastas que o mapa nunca entra (zig-pkg: os pacotes do Zig 0.16)
const skipped = [_][]const u8{ "__pycache__", ".git", "zig-out", ".zig-cache", "zig-pkg", "node_modules", ".venv" };
/// o tamanho máximo da primeira linha da documentação, em caracteres
const max_doc_chars = 140;

const zig_groups = [_][2][]const u8{
    .{ "core/src", "Zig · núcleo (`core/src`)" },
    .{ "aerodrive/src", "Zig · AeroDrive (`aerodrive/src`)" },
    .{ "aerosim/gui", "Zig · interface do aerosim (`aerosim/gui`)" },
    .{ "aeroopt", "Zig · interface do aeroopt (`aeroopt`)" },
    .{ "launcher", "Zig · tela inicial do pacote (`launcher`)" },
};

/// ponto de entrada: monta o mapa e grava (ou confere, com --check)
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const memory = init.arena.allocator();
    const args = try init.minimal.args.toSlice(memory);
    var check = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check = true;
    }
    const text = try build(memory, io);
    const old = std.Io.Dir.cwd().readFileAlloc(io, output_path, memory, .limited(1 << 26)) catch "";
    if (check) {
        if (!std.mem.eql(u8, old, text)) {
            std.debug.print("docs/MAP.md desatualizado: rode zig build mapa\n", .{});
            std.process.exit(1);
        }
        std.debug.print("docs/MAP.md em dia\n", .{});
        return;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = text });
    std.debug.print("{s}: {d} linhas\n", .{ output_path, std.mem.count(u8, text, "\n") });
}

/// o texto inteiro do MAP.md
pub fn build(memory: std.mem.Allocator, io: std.Io) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(memory);
    const writer = &out.writer;
    try writer.writeAll(
        \\# Mapa do código
        \\
        \\Gerado por `zig build mapa` — **não editar à mão** (`zig build mapa -- --check` acusa quando está desatualizado).
        \\Formato: `arquivo` — primeira linha da documentação; depois os nomes públicos com a linha (`nome:linha`).
        \\Regras e decisões do projeto: `.claude/CLAUDE.md`. O que falta e a ordem: `docs/TRACKING.md`.
        \\
        \\
    );

    // Python, por pacote de primeiro nível do aerosim (o que ainda resta: os métodos de fora)
    const python_files = try walk(memory, io, "aerosim", ".py");
    var packages: std.ArrayList([]const u8) = .empty;
    for (python_files) |path| {
        const key = packageKey(path);
        for (packages.items) |known| {
            if (std.mem.eql(u8, known, key)) break;
        } else try packages.append(memory, key);
    }
    std.mem.sort([]const u8, packages.items, {}, lessText);
    for (packages.items) |key| {
        try writer.print("## Python · `{s}`\n\n", .{key});
        for (python_files) |path| if (std.mem.eql(u8, packageKey(path), key)) try pythonEntry(memory, io, writer, path);
        try writer.writeAll("\n");
    }

    // Zig, por pasta
    for (zig_groups) |group| {
        const base = group[0];
        try writer.print("## {s}\n\n", .{group[1]});
        const files = try walk(memory, io, base, ".zig");
        var names: std.ArrayList([]const u8) = .empty;
        for (files) |path| {
            const name = zigGroup(path, base);
            for (names.items) |known| {
                if (std.mem.eql(u8, known, name)) break;
            } else try names.append(memory, name);
        }
        std.mem.sort([]const u8, names.items, {}, lessText);
        for (names.items) |name| {
            if (std.mem.eql(u8, name, ".")) try writer.print("**{s}/**\n\n", .{base}) else try writer.print("**{s}/{s}/**\n\n", .{ base, name });
            for (files) |path| if (std.mem.eql(u8, zigGroup(path, base), name)) try zigEntry(memory, io, writer, path);
            try writer.writeAll("\n");
        }
        try writer.writeAll("\n");
    }

    // as ferramentas
    try writer.writeAll("## Ferramentas (`tools/`)\n\n");
    for (try walk(memory, io, "tools", ".zig")) |path| {
        const source = try readFile(memory, io, path);
        const doc = zigDoc(source);
        try writer.print("- `{s}`", .{path});
        if (doc.len > 0) try writer.print(" — {s}", .{truncate(doc)});
        try writer.writeAll("\n");
    }
    for (try walk(memory, io, "tools", ".py")) |path| {
        const doc = pythonDoc(try readFile(memory, io, path));
        try writer.print("- `{s}`", .{path});
        if (doc.len > 0) try writer.print(" — {s}", .{doc});
        try writer.writeAll("\n");
    }
    try writer.writeAll("\n");

    // os README
    try writer.writeAll("## README por pasta\n\n");
    const readmes = try walk(memory, io, ".", "README.md");
    for (readmes) |path| if (std.mem.eql(u8, std.fs.path.basename(path), "README.md")) try writer.print("- `{s}`\n", .{path});
    return trimEndNewline(memory, out.written());
}

fn trimEndNewline(memory: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(memory, "{s}\n", .{std.mem.trimEnd(u8, text, "\n ")});
}

fn lessText(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// "aerosim/aero/x.py" → "aerosim/aero"; "aerosim/x.py" → "aerosim"
fn packageKey(path: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, path, '/') orelse return "aerosim";
    const second = std.mem.indexOfScalarPos(u8, path, first + 1, '/') orelse return "aerosim";
    return path[0..second];
}

/// a subpasta do arquivo dentro de `base` ("." para os arquivos da própria base)
fn zigGroup(path: []const u8, base: []const u8) []const u8 {
    const rest = path[base.len + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return ".";
    return rest[0..slash];
}

/// os arquivos de `base` (relativo à raiz) que terminam em `suffix`, na ordem do `os.walk` ordenado do Python:
/// primeiro os arquivos da pasta, em ordem de nome, depois cada subpasta em ordem
fn walk(memory: std.mem.Allocator, io: std.Io, base: []const u8, suffix: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try walkInto(memory, io, base, suffix, &out);
    return out.items;
}

fn walkInto(memory: std.mem.Allocator, io: std.Io, folder: []const u8, suffix: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var folders: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        const name = try memory.dupe(u8, item.name);
        switch (item.kind) {
            .directory => {
                if (name[0] == '.') continue;
                for (skipped) |skip| {
                    if (std.mem.eql(u8, skip, name)) break;
                } else try folders.append(memory, name);
            },
            .file => if (std.mem.endsWith(u8, name, suffix)) try files.append(memory, name),
            else => {},
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessText);
    std.mem.sort([]const u8, folders.items, {}, lessText);
    for (files.items) |name| try out.append(memory, try join(memory, folder, name));
    for (folders.items) |name| try walkInto(memory, io, try join(memory, folder, name), suffix, out);
}

fn join(memory: std.mem.Allocator, folder: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, folder, ".")) return name;
    return std.fmt.allocPrint(memory, "{s}/{s}", .{ folder, name });
}

fn readFile(memory: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 24));
}

/// no máximo `max_doc_chars` caracteres (não bytes: o texto é UTF-8, como o fatiamento do Python)
fn truncate(text: []const u8) []const u8 {
    var count: usize = 0;
    var position: usize = 0;
    while (position < text.len and count < max_doc_chars) : (count += 1) {
        position += std.unicode.utf8ByteSequenceLength(text[position]) catch 1;
    }
    return text[0..@min(position, text.len)];
}

// ------------------------------------------------------------------ Python

/// a primeira linha da docstring do módulo (o primeiro comando do arquivo, se for um texto), já cortada
fn pythonDoc(source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var body = line;
        if (body.len > 0 and (body[0] == 'r' or body[0] == 'R' or body[0] == 'u' or body[0] == 'U')) body = body[1..];
        const quote: []const u8 = if (std.mem.startsWith(u8, body, "\"\"\"")) "\"\"\"" else if (std.mem.startsWith(u8, body, "'''")) "'''" else return "";
        var rest = body[3..];
        // a docstring pode começar na linha de baixo: a primeira linha não vazia
        while (true) {
            const end = std.mem.indexOf(u8, rest, quote);
            const piece = std.mem.trim(u8, if (end) |at| rest[0..at] else rest, " \t\r");
            if (piece.len > 0) return truncate(piece);
            if (end != null) return "";
            rest = lines.next() orelse return "";
        }
    }
    return "";
}

fn pythonEntry(memory: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8) !void {
    const source = try readFile(memory, io, path);
    const doc = pythonDoc(source);
    try writer.print("- `{s}`", .{path});
    if (doc.len > 0) try writer.print(" — {s}", .{doc});
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    var in_string: ?[]const u8 = null;
    while (lines.next()) |line| {
        number += 1;
        // pula o que está dentro de um texto de várias linhas (docstrings)
        if (in_string) |quote| {
            if (std.mem.indexOf(u8, line, quote) != null) in_string = null;
            continue;
        }
        if (multilineStart(line)) |quote| {
            in_string = quote;
            continue;
        }
        for ([_]struct { prefix: []const u8, label: []const u8 }{ .{ .prefix = "class ", .label = "class " }, .{ .prefix = "def ", .label = "" }, .{ .prefix = "async def ", .label = "" } }) |kind| {
            if (!std.mem.startsWith(u8, line, kind.prefix)) continue;
            const rest = line[kind.prefix.len..];
            var end: usize = 0;
            while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
            const name = rest[0..end];
            if (name.len == 0 or name[0] == '_') continue;
            try names.append(memory, try std.fmt.allocPrint(memory, "{s}{s}:{d}", .{ kind.label, name, number }));
        }
    }
    if (names.items.len > 0) {
        try writer.writeAll("\n  ");
        for (names.items, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("`{s}`", .{name});
        }
    }
    try writer.writeAll("\n");
}

/// a linha abre um texto de três aspas que não fecha nela? devolve as aspas
fn multilineStart(line: []const u8) ?[]const u8 {
    for ([_][]const u8{ "\"\"\"", "'''" }) |quote| {
        const open = std.mem.indexOf(u8, line, quote) orelse continue;
        if (std.mem.indexOfPos(u8, line, open + 3, quote) == null) return quote;
        return null;
    }
    return null;
}

// ------------------------------------------------------------------ Zig

/// a primeira linha `//!` do arquivo
fn zigDoc(source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "//!")) return std.mem.trim(u8, line[3..], " \t\r");
    }
    return "";
}

fn zigEntry(memory: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8) !void {
    const source = try readFile(memory, io, path);
    const doc = zigDoc(source);
    try writer.print("- `{s}`", .{path});
    if (doc.len > 0) try writer.print(" — {s}", .{truncate(doc)});
    var types: std.ArrayList([]const u8) = .empty;
    var functions: std.ArrayList([]const u8) = .empty;
    var exports: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.startsWith(u8, line, "pub const ")) {
            const rest = line["pub const ".len..];
            const name = identifier(rest);
            var after = std.mem.trimStart(u8, rest[name.len..], " ");
            if (name.len == 0 or !std.mem.startsWith(u8, after, "= ")) continue;
            after = after[2..];
            for ([_][]const u8{ "extern ", "packed " }) |prefix| if (std.mem.startsWith(u8, after, prefix)) {
                after = after[prefix.len..];
            };
            for ([_][]const u8{ "struct", "enum", "union" }) |kind| if (std.mem.startsWith(u8, after, kind)) {
                try types.append(memory, try std.fmt.allocPrint(memory, "{s}:{d}", .{ name, number }));
                break;
            };
        } else if (std.mem.startsWith(u8, line, "pub fn ") or std.mem.startsWith(u8, line, "pub inline fn ")) {
            const rest = line[(if (line[4] == 'i') "pub inline fn ".len else "pub fn ".len)..];
            const name = identifier(rest);
            if (name.len > 0) try functions.append(memory, try std.fmt.allocPrint(memory, "{s}:{d}", .{ name, number }));
        } else if (std.mem.startsWith(u8, line, "export fn ")) {
            const name = identifier(line["export fn ".len..]);
            if (name.len > 0) try exports.append(memory, name);
        }
    }
    if (types.items.len > 0) try namesLine(writer, "tipos ", types.items);
    if (functions.items.len > 0) try namesLine(writer, "fn ", functions.items);
    if (exports.items.len > 0) {
        const label = try std.fmt.allocPrint(memory, "**ABI ({d} exports)** ", .{exports.items.len});
        try namesLine(writer, label, exports.items);
    }
    try writer.writeAll("\n");
}

fn identifier(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    return text[0..end];
}

fn namesLine(writer: *std.Io.Writer, label: []const u8, names: []const []const u8) !void {
    try writer.print("\n  {s}", .{label});
    for (names, 0..) |name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("`{s}`", .{name});
    }
}

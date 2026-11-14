//! Site da documentação: todos os .md do repositório num livro só, o mapa do código e o tracking, lado a lado.
//!
//!     zig build site                              grava zig-out/site/livro.html, as imagens, mapa.html e tracking.html
//!     zig build site -- --saida pasta             em outra pasta
//!     python -m http.server -d zig-out/site 8000  e abrir http://localhost:8000/livro.html
//!
//! Os capítulos se acham sozinhos: todo .md que está no git (fora de `data/` e do próprio TRACKING.md, que é a aba
//! Tracking) entra, agrupado pela pasta de cima (Projeto, aerosim, Núcleo, AeroDrive, aeroopt, Ferramentas e testes).
//! Dentro de cada grupo, o README da pasta vem antes do que está dentro dela. O título de cada página é o primeiro
//! "# título" do arquivo. Um .md novo aparece no livro sem mexer em nada aqui.
//!
//! A página é uma só (livro.html), com o texto dos .md embutido; quem desenha é o navegador, com o marked (Markdown),
//! o KaTeX (as equações em ```math e $...$) e o mermaid (os diagramas). As imagens que os .md citam são copiadas para
//! livro/<caminho no repositório>, e os links entre .md viram links dentro do livro. A aba Mapa é o `grafo.zig`
//! (grafo.json e o mapa.html, com o grafo embutido para abrir direto do disco); a aba Tracking é o `tracking.zig`.
const std = @import("std");
const grafo = @import("grafo.zig");
const tracking = @import("tracking.zig");

const Allocator = std.mem.Allocator;
const github = "https://github.com/vitordallolivo/AircraftSimulation/blob/main/";

/// os grupos do livro, na ordem, com os prefixos de caminho; o primeiro que casa leva o arquivo
const groups = [_]struct { name: []const u8, prefixes: []const []const u8 }{
    .{ .name = "Projeto", .prefixes = &.{ "README.md", "ideias.md", "CHANGELOG.md", ".claude/", "docs/" } },
    .{ .name = "aerosim", .prefixes = &.{"aerosim/"} },
    .{ .name = "Núcleo (core)", .prefixes = &.{"core/"} },
    .{ .name = "AeroDrive", .prefixes = &.{"aerodrive/"} },
    .{ .name = "aeroopt", .prefixes = &.{"aeroopt/"} },
    .{ .name = "Ferramentas e testes", .prefixes = &.{ "tools/", "launcher/" } },
};
const other_group = "Outros";
/// o tracking tem a aba própria
const left_out = [_][]const u8{"docs/TRACKING.md"};

const Page = struct { caminho: []const u8, titulo: []const u8, md: []const u8 };

/// ponto de entrada: monta o site inteiro
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const memory = init.arena.allocator();
    const args = try init.minimal.args.toSlice(memory);
    var target: []const u8 = "zig-out/site";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--saida") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        }
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, target);

    // o livro
    const paths = try markdownFiles(memory, io);
    var chapters: [groups.len + 1]std.ArrayList(Page) = @splat(.empty);
    for (paths) |path| {
        const text = try cwd.readFileAlloc(io, path, memory, .limited(1 << 24));
        const title = try titleOf(memory, text, path);
        try chapters[groupIndex(path)].append(memory, .{ .caminho = path, .titulo = title, .md = try retitle(memory, text, title) });
    }
    // o README da raiz abre o livro
    std.mem.sort(Page, chapters[0].items, {}, struct {
        fn less(_: void, left: Page, right: Page) bool {
            const left_root = std.mem.eql(u8, left.caminho, "README.md");
            const right_root = std.mem.eql(u8, right.caminho, "README.md");
            if (left_root != right_root) return left_root;
            return orderLess({}, left.caminho, right.caminho);
        }
    }.less);
    var out: std.Io.Writer.Allocating = .init(memory);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("grupos");
    try json.beginArray();
    var page_count: usize = 0;
    var group_count: usize = 0;
    var images: usize = 0;
    for (chapters, 0..) |chapter, index| {
        if (chapter.items.len == 0) continue;
        try json.write(.{ .nome = if (index < groups.len) groups[index].name else other_group, .paginas = chapter.items });
        page_count += chapter.items.len;
        group_count += 1;
        for (chapter.items) |page| images += try copyImages(memory, io, page, target);
    }
    try json.endArray();
    try json.objectField("github");
    try json.write(github);
    try json.endObject();
    try writeWithData(memory, io, "tools/livro_page.html", "/*LIVRO*/null", out.written(), target, "livro.html");

    // a aba Mapa: o grafo do código, extraído agora do Zig
    var graph = try grafo.build(memory, io);
    var graph_out: std.Io.Writer.Allocating = .init(memory);
    try graph.writeJson(&graph_out.writer);
    try cwd.writeFile(io, .{ .sub_path = try join(memory, target, "grafo.json"), .data = graph_out.written() });
    try writeWithData(memory, io, "tools/grafo_page.html", "/*GRAFO*/null", graph_out.written(), target, "mapa.html");
    var summary: std.Io.Writer.Allocating = .init(memory);
    try graph.summary(&summary.writer);
    std.debug.print("{s}", .{summary.written()});

    // a aba Tracking
    const tracking_text = try cwd.readFileAlloc(io, "docs/TRACKING.md", memory, .limited(1 << 24));
    try tracking.writePage(memory, io, tracking_text, try tracking.board(memory, tracking_text), try join(memory, target, "tracking.html"));

    std.debug.print("{s}/livro.html: {d} páginas em {d} grupos, {d} imagens\n", .{ target, page_count, group_count, images });
}

fn join(memory: Allocator, folder: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(memory, "{s}/{s}", .{ folder, name });
}

/// grava `template` com `marker` trocado pelos dados (com `</` escapado, para não fechar o <script>)
fn writeWithData(memory: Allocator, io: std.Io, template_path: []const u8, marker: []const u8, data: []const u8, target: []const u8, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const template = try cwd.readFileAlloc(io, template_path, memory, .limited(1 << 24));
    const blob = try std.mem.replaceOwned(u8, memory, data, "</", "<\\/");
    const at = std.mem.indexOf(u8, template, marker) orelse return error.SemMarcador;
    const page = try std.mem.concat(memory, u8, &.{ template[0..at], blob, template[at + marker.len ..] });
    try cwd.writeFile(io, .{ .sub_path = try join(memory, target, name), .data = page });
}

/// os .md que estão no git, fora de data/, na ordem do livro
fn markdownFiles(memory: Allocator, io: std.Io) ![]const []const u8 {
    const result = try std.process.run(memory, io, .{ .argv = &.{ "git", "ls-files", "*.md" } });
    var paths: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    while (tokens.next()) |path| {
        if (std.mem.startsWith(u8, path, "data/")) continue;
        for (left_out) |skip| {
            if (std.mem.eql(u8, skip, path)) break;
        } else try paths.append(memory, path);
    }
    std.mem.sort([]const u8, paths.items, {}, orderLess);
    return paths.items;
}

fn groupIndex(path: []const u8) usize {
    for (groups, 0..) |group, index| {
        for (group.prefixes) |prefix| if (std.mem.startsWith(u8, path, prefix)) return index;
    }
    return groups.len;
}

/// o README da pasta antes do resto dela; as pastas em ordem alfabética (parte a parte do caminho)
fn orderLess(_: void, left: []const u8, right: []const u8) bool {
    const left_folder = std.fs.path.dirnamePosix(left) orelse "";
    const right_folder = std.fs.path.dirnamePosix(right) orelse "";
    var left_parts = std.mem.splitScalar(u8, left_folder, '/');
    var right_parts = std.mem.splitScalar(u8, right_folder, '/');
    while (true) {
        const left_part = left_parts.next();
        const right_part = right_parts.next();
        if (left_part == null and right_part == null) break;
        if (left_part == null) return true;
        if (right_part == null) return false;
        switch (std.mem.order(u8, left_part.?, right_part.?)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    const left_name = std.fs.path.basenamePosix(left);
    const right_name = std.fs.path.basenamePosix(right);
    const left_readme = std.ascii.startsWithIgnoreCase(left_name, "README");
    const right_readme = std.ascii.startsWithIgnoreCase(right_name, "README");
    if (left_readme != right_readme) return left_readme;
    return std.mem.order(u8, left_name, right_name) == .lt;
}

fn isPathChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.' or char == '/' or char == '-' or char >= 0x80;
}

/// o primeiro "# título", sem a pasta na frente ("aerosim/aero — aerodinâmica" vira "Aerodinâmica"): onde o
/// arquivo está é assunto do docs/MAP.md
fn titleOf(memory: Allocator, text: []const u8, path: []const u8) ![]const u8 {
    var title = firstHeading(text) orelse return path;
    title = std.mem.trim(u8, title, " \t\r");
    // "`pasta/x` — " na frente
    var i: usize = 0;
    if (i < title.len and title[i] == '`') i += 1;
    const run_start = i;
    while (i < title.len and isPathChar(title[i])) i += 1;
    const run = title[run_start..i];
    if (std.mem.lastIndexOfScalar(u8, run, '/')) |slash| if (slash >= 1) {
        if (i < title.len and title[i] == '`') i += 1;
        const after_space = skipSpaces(title, i);
        if (after_space > i) {
            for ([_][]const u8{ "—", "–", "-" }) |dash| {
                if (std.mem.startsWith(u8, title[after_space..], dash)) {
                    const rest = skipSpaces(title, after_space + dash.len);
                    if (rest > after_space + dash.len) title = title[rest..];
                    break;
                }
            }
        }
    };
    // " (`pasta/`)" no fim
    if (std.mem.endsWith(u8, title, "/`)")) {
        if (std.mem.lastIndexOf(u8, title, "(`")) |open| {
            const inside = title[open + 2 .. title.len - 3];
            var ok = inside.len > 0;
            for (inside) |char| ok = ok and isPathChar(char);
            if (ok) title = std.mem.trimEnd(u8, title[0..open], " \t");
        }
    }
    if (title.len > 0 and std.ascii.isLower(title[0])) {
        const copy = try memory.dupe(u8, title);
        copy[0] = std.ascii.toUpper(copy[0]);
        return copy;
    }
    return title;
}

fn skipSpaces(text: []const u8, at: usize) usize {
    var i = at;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

/// o texto do primeiro "# título" (só o título, sem o "# ")
fn firstHeading(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# ") and line.len > 2) return line[2..];
    }
    return null;
}

/// o texto com o primeiro "# título" trocado pelo título simples
fn retitle(memory: Allocator, text: []const u8, title: []const u8) ![]const u8 {
    const heading = firstHeading(text) orelse return text;
    const start = @intFromPtr(heading.ptr) - @intFromPtr(text.ptr);
    return std.mem.concat(memory, u8, &.{ text[0..start], title, text[start + heading.len ..] });
}

/// copia as imagens citadas (`![...](caminho)`) para livro/<caminho no repositório>; devolve quantas
fn copyImages(memory: Allocator, io: std.Io, page: Page, target: []const u8) !usize {
    const cwd = std.Io.Dir.cwd();
    const folder = std.fs.path.dirnamePosix(page.caminho) orelse "";
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, page.md, offset, "![")) |at| {
        offset = at + 2;
        const close = std.mem.indexOfAnyPos(u8, page.md, offset, "]") orelse break;
        if (close + 1 >= page.md.len or page.md[close + 1] != '(') continue;
        const ref_start = close + 2;
        var ref_end = ref_start;
        while (ref_end < page.md.len and page.md[ref_end] != ')' and !std.ascii.isWhitespace(page.md[ref_end])) ref_end += 1;
        if (ref_end == ref_start) continue;
        const reference = page.md[ref_start..ref_end];
        // um link com esquema (https:, data:) fica como está
        var letters: usize = 0;
        while (letters < reference.len and std.ascii.isLower(reference[letters])) letters += 1;
        if (letters > 0 and letters < reference.len and reference[letters] == ':') continue;
        const file = reference[0 .. std.mem.indexOfScalar(u8, reference, '#') orelse reference.len];
        const source = try std.fs.path.resolvePosix(memory, &.{ if (folder.len > 0) folder else ".", file });
        if (std.mem.startsWith(u8, source, "..") or std.fs.path.isAbsolutePosix(source)) continue;
        const stat = cwd.statFile(io, source, .{}) catch continue;
        if (stat.kind != .file) continue;
        const destination = try std.fmt.allocPrint(memory, "{s}/livro/{s}", .{ target, source });
        if (std.fs.path.dirnamePosix(destination)) |parent| try cwd.createDirPath(io, parent);
        try std.Io.Dir.copyFile(cwd, source, cwd, destination, io, .{});
        count += 1;
    }
    return count;
}

test "título sem a pasta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    try std.testing.expectEqualStrings("Aerodinâmica", try titleOf(memory, "# `aerosim/aero` — aerodinâmica\n", "x.md"));
    try std.testing.expectEqualStrings("Núcleo", try titleOf(memory, "texto\n# Núcleo (`core/`)\n", "x.md"));
    try std.testing.expectEqualStrings("x.md", try titleOf(memory, "sem título\n", "x.md"));
    try std.testing.expect(orderLess({}, "core/README.md", "core/a.md"));
    try std.testing.expect(orderLess({}, "core/z.md", "core/src/README.md"));
}

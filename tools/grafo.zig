//! Grafo do código: lê o Zig do repositório e devolve quem é quem e quem chama quem, sem lista feita à mão.
//!
//!     zig build site                  grava zig-out/site/grafo.json e o mapa.html (o livro.zig chama este)
//!
//! Cada arquivo vira um módulo (no Zig o arquivo já é uma struct); dentro dele ficam as structs, enums e unions, e as
//! funções com a assinatura, o `///` e as linhas onde estão. As chamadas saem do corpo de cada função, por leitura do
//! texto, seguindo os `@import` (pelo caminho ou pelo nome dado nos build.zig) e os apelidos
//! (`const runner = core.runner`). Uma chamada que não dá para resolver sem ambiguidade (um `x.step()` com dois `step`
//! possíveis) fica de fora, em vez de virar uma ligação errada. Os .py que restam (o adaptador dos métodos de fora)
//! entram como módulos, com as classes e funções, mas sem as chamadas.
const std = @import("std");

const folders = [_][]const u8{ "core/src", "aerosim", "aeroopt", "aerodrive/src", "tools" };
const skipped_dirs = [_][]const u8{ "zig-pkg", ".zig-cache", "zig-cache", "zig-out", "__pycache__", "tests", "node_modules" };
const build_files = [_][]const u8{ "core/build.zig", "build.zig", "aerosim/build.zig", "aeroopt/build.zig", "aerodrive/build.zig" };
const keywords = [_][]const u8{ "if", "while", "for", "switch", "return", "fn", "catch", "orelse", "try", "and", "or", "struct", "enum", "union", "error", "comptime", "inline", "test", "defer", "errdefer", "suspend", "resume", "nosuspend" };

const Allocator = std.mem.Allocator;

pub const Symbol = struct {
    id: []const u8,
    modulo: []const u8,
    nome: []const u8,
    tipo: []const u8,
    dono: ?[]const u8,
    assinatura: []const u8,
    doc: []const u8,
    inicio: usize,
    fim: usize,
};

const Module = struct {
    id: []const u8,
    nome: []const u8,
    grupo: []const u8,
    lang: []const u8,
    linhas: usize,
    simbolos: std.ArrayList([]const u8) = .empty,
};

const Call = struct { from: []const u8, to: []const u8 };

/// o que um nome leva, dentro de um escopo (o módulo ou uma struct)
const Entry = union(enum) {
    /// uma struct, enum ou union (ou um módulo inteiro)
    scope: []const u8,
    /// `@import(...)`: o caminho do arquivo, se for do projeto
    import: ?[]const u8,
    /// `const a = b.c`: o caminho e o escopo onde ele foi escrito
    alias: struct { value: []const u8, scope: []const u8 },
    function: []const u8,
};

const Names = std.StringArrayHashMapUnmanaged(Entry);

const Body = struct { function: []const u8, scope: []const u8, code: []const u8 };

/// os módulos, os símbolos e as ligações de chamada
pub const Graph = struct {
    memory: Allocator,
    modules: std.StringArrayHashMapUnmanaged(Module) = .empty,
    symbols: std.StringArrayHashMapUnmanaged(Symbol) = .empty,
    calls: std.ArrayList(Call) = .empty,
    call_set: std.StringHashMapUnmanaged(void) = .empty,
    sources: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    scopes: std.StringHashMapUnmanaged(Names) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    named: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn addSymbol(graph: *Graph, symbol: Symbol) !void {
        try graph.symbols.put(graph.memory, symbol.id, symbol);
        try graph.modules.getPtr(symbol.modulo).?.simbolos.append(graph.memory, symbol.id);
    }

    fn addCall(graph: *Graph, from: []const u8, to: []const u8) !void {
        const key = try std.mem.concat(graph.memory, u8, &.{ from, "\x00", to });
        const found = try graph.call_set.getOrPut(graph.memory, key);
        if (!found.found_existing) try graph.calls.append(graph.memory, .{ .from = from, .to = to });
    }

    fn names(graph: *Graph, scope: []const u8) !*Names {
        const found = try graph.scopes.getOrPut(graph.memory, scope);
        if (!found.found_existing) found.value_ptr.* = .empty;
        return found.value_ptr;
    }

    /// o JSON que a página do mapa lê: módulos, símbolos (com quem chama e quem é chamado), ligações e fontes
    pub fn writeJson(graph: *Graph, writer: *std.Io.Writer) !void {
        const memory = graph.memory;
        std.mem.sort(Call, graph.calls.items, {}, lessCall);
        var callers: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        var callees: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        var links: std.StringArrayHashMapUnmanaged(usize) = .empty;
        for (graph.calls.items) |call| {
            try appendTo(memory, &callees, call.from, call.to);
            try appendTo(memory, &callers, call.to, call.from);
            const from_module = graph.symbols.get(call.from).?.modulo;
            const to_module = graph.symbols.get(call.to).?.modulo;
            if (!std.mem.eql(u8, from_module, to_module)) {
                const key = try std.mem.concat(memory, u8, &.{ from_module, "\x00", to_module });
                (try links.getOrPutValue(memory, key, 0)).value_ptr.* += 1;
            }
        }
        var json: std.json.Stringify = .{ .writer = writer };
        try json.beginObject();
        try json.objectField("modulos");
        try json.beginArray();
        for (graph.modules.values()) |module| {
            try json.write(.{ .id = module.id, .nome = module.nome, .grupo = module.grupo, .lang = module.lang, .linhas = module.linhas, .simbolos = module.simbolos.items });
        }
        try json.endArray();
        try json.objectField("simbolos");
        try json.beginObject();
        const empty: []const []const u8 = &.{};
        for (graph.symbols.values()) |symbol| {
            try json.objectField(symbol.id);
            try json.write(.{
                .id = symbol.id,
                .modulo = symbol.modulo,
                .nome = symbol.nome,
                .tipo = symbol.tipo,
                .dono = symbol.dono,
                .assinatura = symbol.assinatura,
                .doc = symbol.doc,
                .inicio = symbol.inicio,
                .fim = symbol.fim,
                .chama = if (callees.get(symbol.id)) |list| list.items else empty,
                .chamado_por = if (callers.get(symbol.id)) |list| list.items else empty,
            });
        }
        try json.endObject();
        try json.objectField("ligacoes");
        const keys = try memory.dupe([]const u8, links.keys());
        std.mem.sort([]const u8, keys, {}, lessText);
        try json.beginArray();
        for (keys) |key| {
            const cut = std.mem.indexOfScalar(u8, key, 0).?;
            try json.write(.{ .de = key[0..cut], .para = key[cut + 1 ..], .n = links.get(key).? });
        }
        try json.endArray();
        try json.objectField("fontes");
        try json.beginObject();
        var sources = graph.sources.iterator();
        while (sources.next()) |source| {
            try json.objectField(source.key_ptr.*);
            try json.write(source.value_ptr.*);
        }
        try json.endObject();
        try json.endObject();
    }

    /// quantos módulos, símbolos, funções, chamadas e ligações entre módulos
    pub fn summary(graph: *Graph, writer: *std.Io.Writer) !void {
        var functions: usize = 0;
        for (graph.symbols.values()) |symbol| {
            if (isFunction(symbol.tipo)) functions += 1;
        }
        var modules_linked: std.StringHashMapUnmanaged(void) = .empty;
        for (graph.calls.items) |call| {
            const from_module = graph.symbols.get(call.from).?.modulo;
            const to_module = graph.symbols.get(call.to).?.modulo;
            if (!std.mem.eql(u8, from_module, to_module)) try modules_linked.put(graph.memory, try std.mem.concat(graph.memory, u8, &.{ from_module, "\x00", to_module }), {});
        }
        try writer.print("{d} módulos, {d} símbolos ({d} funções), {d} chamadas, {d} ligações entre módulos\n", .{
            graph.modules.count(), graph.symbols.count(), functions, graph.calls.items.len, modules_linked.count(),
        });
    }
};

fn appendTo(memory: Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)), key: []const u8, value: []const u8) !void {
    const found = try map.getOrPut(memory, key);
    if (!found.found_existing) found.value_ptr.* = .empty;
    try found.value_ptr.append(memory, value);
}

fn lessText(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn lessCall(_: void, left: Call, right: Call) bool {
    return switch (std.mem.order(u8, left.from, right.from)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, left.to, right.to) == .lt,
    };
}

fn isFunction(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "função") or std.mem.eql(u8, kind, "método");
}

/// lê todos os arquivos e liga as chamadas
pub fn build(memory: Allocator, io: std.Io) !Graph {
    var graph: Graph = .{ .memory = memory };
    try namedModules(&graph, io);
    var files: std.ArrayList([]const u8) = .empty;
    for (folders) |folder| try walk(memory, io, folder, &files);
    for (files.items) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 24));
        const zig = std.mem.endsWith(u8, path, ".zig");
        try graph.sources.put(memory, path, text);
        const name = try moduleName(memory, path);
        try graph.modules.put(memory, path, .{
            .id = path,
            .nome = name,
            .grupo = groupOf(name),
            .lang = if (zig) "zig" else "py",
            .linhas = std.mem.count(u8, text, "\n") + 1,
        });
        if (zig) try readZig(&graph, path, text) else try readPython(&graph, path, text);
    }
    try linkCalls(&graph);
    return graph;
}

fn isTest(name: []const u8) bool {
    return std.mem.eql(u8, name, "tests.zig") or std.mem.eql(u8, name, "build.zig") or std.mem.eql(u8, name, "conftest.py") or
        std.mem.startsWith(u8, name, "test_") or std.mem.endsWith(u8, name, "_test.zig");
}

/// os .zig e .py da pasta, em ordem (os arquivos da pasta antes das subpastas, como o os.walk)
fn walk(memory: Allocator, io: std.Io, folder: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const name = try memory.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => {
                if (name[0] == '.') continue;
                for (skipped_dirs) |skip| {
                    if (std.mem.eql(u8, skip, name)) break;
                } else try dirs.append(memory, name);
            },
            .file => if ((std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".py")) and !isTest(name)) try files.append(memory, name),
            else => {},
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessText);
    std.mem.sort([]const u8, dirs.items, {}, lessText);
    for (files.items) |name| try out.append(memory, try std.fmt.allocPrint(memory, "{s}/{s}", .{ folder, name }));
    for (dirs.items) |name| try walk(memory, io, try std.fmt.allocPrint(memory, "{s}/{s}", .{ folder, name }), out);
}

/// `core/src/sim/runner.zig` → `core.sim.runner`: o nome do módulo, sem pasta nem extensão
fn moduleName(memory: Allocator, path: []const u8) ![]const u8 {
    var stem = path[0 .. std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len];
    stem = try std.mem.replaceOwned(u8, memory, stem, "core/src/", "core/");
    stem = try std.mem.replaceOwned(u8, memory, stem, "aerodrive/src/", "aerodrive/");
    if (std.mem.endsWith(u8, stem, "/__init__")) stem = stem[0 .. stem.len - "/__init__".len];
    const name = try memory.dupe(u8, stem);
    std.mem.replaceScalar(u8, name, '/', '.');
    return name;
}

/// as duas primeiras partes do nome (`core.sim`), ou o nome todo se ele é curto
fn groupOf(name: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    const second = std.mem.indexOfScalarPos(u8, name, first + 1, '.') orelse return name[0..first];
    return name[0..second];
}

// ---------------------------------------------------------------- leitura do texto

fn isWord(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char >= 0x80;
}

fn isIdentStart(char: u8) bool {
    return std.ascii.isAlphabetic(char) or char == '_';
}

fn isSpace(char: u8) bool {
    return std.ascii.isWhitespace(char);
}

fn skipSpace(code: []const u8, at: usize) usize {
    var i = at;
    while (i < code.len and isSpace(code[i])) i += 1;
    return i;
}

fn wordEnd(code: []const u8, at: usize) usize {
    var i = at;
    while (i < code.len and isWord(code[i])) i += 1;
    return i;
}

/// `keyword` em `at`, começando numa fronteira de palavra
fn keywordAt(code: []const u8, at: usize, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, code[at..], keyword)) return false;
    return at == 0 or !isWord(code[at - 1]);
}

/// troca comentários e textos entre aspas por espaços, sem mudar as posições, para ler só o código
fn stripZig(memory: Allocator, text: []const u8) ![]u8 {
    const out = try memory.dupe(u8, text);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "//") or std.mem.startsWith(u8, text[i..], "\\\\")) {
            const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            @memset(out[i..end], ' ');
            i = end;
        } else if (text[i] == '"' or text[i] == '\'') {
            const quote = text[i];
            var j = i + 1;
            while (j < text.len and text[j] != quote and text[j] != '\n') j += if (text[j] == '\\') 2 else 1;
            @memset(out[i + 1 .. @min(j, text.len)], ' ');
            i = j + 1;
        } else i += 1;
    }
    return out;
}

/// a posição da `}` que fecha a `{` em `open_at`
fn matching(code: []const u8, open_at: usize) usize {
    var depth: isize = 0;
    for (code[open_at..], open_at..) |char, i| {
        if (char == '{') depth += 1 else if (char == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return code.len - 1;
}

fn lineOf(code: []const u8, offset: usize) usize {
    return std.mem.count(u8, code[0..offset], "\n") + 1;
}

/// as linhas `///` logo acima da linha `line`, juntas
fn docBefore(memory: Allocator, lines: []const []const u8, line: usize) ![]const u8 {
    var docs: std.ArrayList([]const u8) = .empty;
    var i: isize = @as(isize, @intCast(line)) - 2;
    while (i >= 0) : (i -= 1) {
        const trimmed = std.mem.trim(u8, lines[@intCast(i)], " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "///")) break;
        try docs.append(memory, std.mem.trim(u8, trimmed[3..], " \t\r"));
    }
    std.mem.reverse([]const u8, docs.items);
    return std.mem.join(memory, " ", docs.items);
}

/// `const Nome = [extern|packed] struct|enum|union ... {`
const Container = struct { start: usize, end: usize, name: []const u8, kind: []const u8, open_at: usize };

fn containerAt(code: []const u8, at: usize) ?Container {
    if (!keywordAt(code, at, "const")) return null;
    var i = at + "const".len;
    if (i >= code.len or !isSpace(code[i])) return null;
    i = skipSpace(code, i);
    const name_end = wordEnd(code, i);
    if (name_end == i) return null;
    const name = code[i..name_end];
    i = skipSpace(code, name_end);
    if (i < code.len and code[i] == ':') {
        while (i < code.len and code[i] != '=') i += 1;
    }
    if (i >= code.len or code[i] != '=') return null;
    i = skipSpace(code, i + 1);
    for ([_][]const u8{ "extern", "packed" }) |prefix| {
        if (std.mem.startsWith(u8, code[i..], prefix) and i + prefix.len < code.len and isSpace(code[i + prefix.len])) {
            i = skipSpace(code, i + prefix.len);
            break;
        }
    }
    const kind_end = wordEnd(code, i);
    const kind = code[i..kind_end];
    if (!(std.mem.eql(u8, kind, "struct") or std.mem.eql(u8, kind, "enum") or std.mem.eql(u8, kind, "union"))) return null;
    i = kind_end;
    while (i < code.len and code[i] != '{' and code[i] != ';') i += 1;
    if (i >= code.len or code[i] != '{') return null;
    var start = at;
    if (start >= 4) {
        var back = start;
        while (back > 0 and isSpace(code[back - 1])) back -= 1;
        if (back < start and back >= 3 and std.mem.eql(u8, code[back - 3 .. back], "pub") and (back == 3 or !isWord(code[back - 4]))) start = back - 3;
    }
    return .{ .start = start, .end = matching(code, i), .name = name, .kind = kind, .open_at = i };
}

/// o escopo que contém `offset`: a struct mais de dentro, ou o próprio módulo
fn ownerAt(memory: Allocator, path: []const u8, spans: []const Container, offset: usize) ![]const u8 {
    var best: ?Container = null;
    for (spans) |span| {
        if (span.open_at < offset and offset <= span.end and (best == null or span.start > best.?.start)) best = span;
    }
    const span = best orelse return path;
    return std.fmt.allocPrint(memory, "{s}#{s}", .{ path, try qualified(memory, spans, span) });
}

/// `Fora.Dentro`: o nome com as structs de fora
fn qualified(memory: Allocator, spans: []const Container, span: Container) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (spans) |outer| {
        if (outer.open_at < span.start and span.start <= outer.end) try parts.append(memory, outer.name);
    }
    try parts.append(memory, span.name);
    return std.mem.join(memory, ".", parts.items);
}

fn readZig(graph: *Graph, path: []const u8, text: []const u8) !void {
    const memory = graph.memory;
    const code = try stripZig(memory, text);
    var line_list: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try line_list.append(memory, line);
    const lines = line_list.items;
    _ = try graph.names(path);

    // structs, enums e unions (a busca segue depois da `{`, então as de dentro também aparecem)
    var spans: std.ArrayList(Container) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        if (containerAt(code, i)) |span| {
            try spans.append(memory, span);
            i = span.open_at + 1;
        } else i += 1;
    }
    for (spans.items) |span| {
        const name = try qualified(memory, spans.items, span);
        const container_id = try std.fmt.allocPrint(memory, "{s}#{s}", .{ path, name });
        const parent = try ownerAt(memory, path, spans.items, span.start);
        _ = try graph.names(container_id);
        try (try graph.names(parent)).put(memory, span.name, .{ .scope = container_id });
        const line = lineOf(code, span.start);
        try graph.addSymbol(.{ .id = container_id, .modulo = path, .nome = name, .tipo = span.kind, .dono = null, .assinatura = std.mem.trim(u8, lines[line - 1], " \t\r"), .doc = try docBefore(memory, lines, line), .inicio = line, .fim = lineOf(code, span.end) });
    }

    // `const nome = valor;`: os @import e os apelidos
    i = 0;
    while (i < code.len) {
        const declaration = declarationAt(code, text, i) orelse {
            i += 1;
            continue;
        };
        i = declaration.end;
        const scope = try ownerAt(memory, path, spans.items, declaration.start);
        const scope_names = try graph.names(scope);
        if (scope_names.contains(declaration.name)) continue;
        const value = declaration.value;
        if (std.mem.startsWith(u8, value, "@import(\"") and std.mem.endsWith(u8, value, "\")") and std.mem.indexOfScalar(u8, value["@import(\"".len .. value.len - 2], '"') == null) {
            try scope_names.put(memory, declaration.name, .{ .import = try importTarget(graph, path, value["@import(\"".len .. value.len - 2]) });
        } else if (isDottedName(value)) {
            try scope_names.put(memory, declaration.name, .{ .alias = .{ .value = value, .scope = scope } });
        }
    }

    // as funções com corpo
    i = 0;
    while (i < code.len) {
        const function = functionAt(code, i) orelse {
            i += 1;
            continue;
        };
        i = function.paren + 1;
        var depth: usize = 0;
        var close = function.paren;
        while (close < code.len) : (close += 1) {
            if (code[close] == '(') depth += 1 else if (code[close] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        var j = close + 1;
        while (j < code.len and code[j] != '{' and code[j] != ';') {
            if (std.mem.startsWith(u8, code[j..], "error{") or std.mem.startsWith(u8, code[j..], "struct{")) {
                j = matching(code, std.mem.indexOfScalarPos(u8, code, j, '{').?) + 1;
                continue;
            }
            j += 1;
        }
        if (j >= code.len or code[j] == ';') continue; // declaração sem corpo (extern)
        const body_end = matching(code, j);
        const scope = try ownerAt(memory, path, spans.items, function.start);
        const in_module = std.mem.eql(u8, scope, path);
        const function_id = if (in_module) try std.fmt.allocPrint(memory, "{s}#{s}", .{ path, function.name }) else try std.fmt.allocPrint(memory, "{s}.{s}", .{ scope, function.name });
        const line = lineOf(code, function.start);
        const owner: ?[]const u8 = if (std.mem.indexOfScalar(u8, scope, '#')) |at| scope[at + 1 ..] else null;
        try graph.addSymbol(.{ .id = function_id, .modulo = path, .nome = function.name, .tipo = if (owner != null) "método" else "função", .dono = owner, .assinatura = try collapseSpace(memory, text[function.start..j]), .doc = try docBefore(memory, lines, line), .inicio = line, .fim = lineOf(code, body_end) });
        const scope_names = try graph.names(scope);
        if (!scope_names.contains(function.name)) try scope_names.put(memory, function.name, .{ .function = function_id });
        try graph.bodies.append(memory, .{ .function = function_id, .scope = scope, .code = code[function.start..body_end] });
    }
}

fn collapseSpace(memory: Allocator, text: []const u8) ![]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    while (tokens.next()) |word| try words.append(memory, word);
    return std.mem.join(memory, " ", words.items);
}

fn isDottedName(value: []const u8) bool {
    if (value.len == 0 or !isIdentStart(value[0])) return false;
    for (value) |char| if (!(isWord(char) or char == '.')) return false;
    return true;
}

const Declaration = struct { start: usize, end: usize, name: []const u8, value: []const u8 };

/// `[pub] const nome = valor;` sem `{` no valor
fn declarationAt(code: []const u8, text: []const u8, at: usize) ?Declaration {
    var start = at;
    var i = at;
    if (keywordAt(code, at, "pub")) {
        i = at + 3;
        if (i >= code.len or !isSpace(code[i])) return null;
        i = skipSpace(code, i);
    } else start = at;
    if (!std.mem.startsWith(u8, code[i..], "const") or (i == at and !keywordAt(code, i, "const"))) return null;
    i += "const".len;
    if (i >= code.len or !isSpace(code[i])) return null;
    i = skipSpace(code, i);
    const name_end = wordEnd(code, i);
    if (name_end == i) return null;
    const name = code[i..name_end];
    i = skipSpace(code, name_end);
    if (i >= code.len or code[i] != '=') return null;
    i = skipSpace(code, i + 1);
    const value_start = i;
    while (i < code.len and code[i] != ';' and code[i] != '{') i += 1;
    if (i >= code.len or code[i] != ';' or i == value_start) return null;
    return .{ .start = start, .end = i + 1, .name = name, .value = std.mem.trim(u8, text[value_start..i], " \t\r\n") };
}

const Function = struct { start: usize, name: []const u8, paren: usize };

/// `[pub] [export|inline|extern]* fn nome(`
fn functionAt(code: []const u8, at: usize) ?Function {
    if (!keywordAt(code, at, "fn")) return null;
    var i = at + 2;
    if (i >= code.len or !isSpace(code[i])) return null;
    i = skipSpace(code, i);
    const name_end = wordEnd(code, i);
    if (name_end == i) return null;
    const name = code[i..name_end];
    i = skipSpace(code, name_end);
    if (i >= code.len or code[i] != '(') return null;
    // volta pelos modificadores e pelo `pub`
    var start = at;
    while (true) {
        var back = start;
        while (back > 0 and isSpace(code[back - 1])) back -= 1;
        if (back == start) break;
        var word_start = back;
        while (word_start > 0 and isWord(code[word_start - 1])) word_start -= 1;
        const word = code[word_start..back];
        if ((std.mem.eql(u8, word, "export") or std.mem.eql(u8, word, "inline") or std.mem.eql(u8, word, "extern"))) {
            start = word_start;
        } else if (std.mem.eql(u8, word, "pub")) {
            start = word_start;
            break;
        } else break;
    }
    return .{ .start = start, .name = name, .paren = i };
}

fn importTarget(graph: *Graph, path: []const u8, spec: []const u8) !?[]const u8 {
    if (std.mem.endsWith(u8, spec, ".zig")) {
        const folder = std.fs.path.dirname(path) orelse "";
        return try std.fs.path.resolvePosix(graph.memory, &.{ folder, spec });
    }
    return graph.named.get(spec);
}

/// os módulos com nome (`@import("aerosim")`), lidos dos build.zig: createModule/addModule e addImport
fn namedModules(graph: *Graph, io: std.Io) !void {
    const memory = graph.memory;
    for (build_files) |build_path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, build_path, memory, .limited(1 << 22)) catch continue;
        const base = std.fs.path.dirname(build_path) orelse "";
        var variables: std.StringHashMapUnmanaged([]const u8) = .empty;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, "const ")) |at| {
            i = at + 6;
            const name_end = wordEnd(text, i);
            if (name_end == i) continue;
            const after = text[name_end..];
            const call = for ([_][]const u8{ " = b.createModule(", " = b.addModule(" }) |prefix| {
                if (std.mem.startsWith(u8, after, prefix)) break prefix;
            } else continue;
            var cursor = name_end + call.len;
            var public: ?[]const u8 = null;
            if (cursor < text.len and text[cursor] == '"') {
                const close = std.mem.indexOfScalarPos(u8, text, cursor + 1, '"') orelse continue;
                const quoted = text[cursor + 1 .. close];
                if (quoted.len > 0 and wordEnd(quoted, 0) == quoted.len and close + 1 < text.len and text[close + 1] == ',') {
                    public = quoted;
                    cursor = skipSpace(text, close + 2);
                }
            }
            const semicolon = std.mem.indexOfScalarPos(u8, text, cursor, ';') orelse text.len;
            const path_at = std.mem.indexOf(u8, text[cursor..semicolon], "b.path(\"") orelse continue;
            const value_start = cursor + path_at + "b.path(\"".len;
            const value_end = std.mem.indexOfScalarPos(u8, text, value_start, '"') orelse continue;
            if (value_end + 1 >= text.len or text[value_end + 1] != ')') continue;
            const target = try std.fs.path.resolvePosix(memory, &.{ if (base.len > 0) base else ".", text[value_start..value_end] });
            try variables.put(memory, text[at + 6 .. name_end], target);
            if (public) |module_name| try graph.named.put(memory, module_name, target);
        }
        // addImport("nome", variavel) e .{ .name = "nome", .module = variavel }
        i = 0;
        while (i < text.len) : (i += 1) {
            var name: []const u8 = undefined;
            var variable: []const u8 = undefined;
            if (std.mem.startsWith(u8, text[i..], "addImport(\"")) {
                const name_start = i + "addImport(\"".len;
                const name_end = wordEnd(text, name_start);
                if (name_end == name_start or !std.mem.startsWith(u8, text[name_end..], "\",")) continue;
                name = text[name_start..name_end];
                const var_start = skipSpace(text, name_end + 2);
                const var_end = wordEnd(text, var_start);
                if (var_end == var_start or var_end >= text.len or text[var_end] != ')') continue;
                variable = text[var_start..var_end];
            } else if (std.mem.startsWith(u8, text[i..], ".name = \"")) {
                const name_start = i + ".name = \"".len;
                const name_end = wordEnd(text, name_start);
                if (name_end == name_start or !std.mem.startsWith(u8, text[name_end..], "\",")) continue;
                name = text[name_start..name_end];
                const module_at = skipSpace(text, name_end + 2);
                if (!std.mem.startsWith(u8, text[module_at..], ".module = ")) continue;
                const var_start = module_at + ".module = ".len;
                const var_end = wordEnd(text, var_start);
                if (var_end == var_start) continue;
                variable = text[var_start..var_end];
            } else continue;
            if (variables.get(variable)) |target| {
                if (!graph.named.contains(name)) try graph.named.put(memory, name, target);
            }
        }
    }
}

// ---------------------------------------------------------------- nomes e chamadas

const max_depth = 12;

/// acha `name` no escopo (e nos de fora, até o módulo) e devolve o escopo ou a função a que ele leva
fn lookup(graph: *Graph, scope: []const u8, name: []const u8, depth: usize) ?Entry {
    if (depth > max_depth) return null;
    var current = scope;
    while (true) {
        if (graph.scopes.get(current)) |scope_names| {
            if (scope_names.get(name)) |entry| return follow(graph, entry, depth);
        }
        const hash = std.mem.indexOfScalar(u8, current, '#') orelse return null;
        const tail = current[hash + 1 ..];
        current = if (std.mem.lastIndexOfScalar(u8, tail, '.')) |dot| current[0 .. hash + 1 + dot] else current[0..hash];
    }
}

fn follow(graph: *Graph, entry: Entry, depth: usize) ?Entry {
    return switch (entry) {
        .import => |target| if (target) |path| (if (graph.scopes.contains(path)) Entry{ .scope = path } else null) else null,
        .alias => |alias| chain(graph, alias.scope, alias.value, depth + 1),
        else => entry,
    };
}

/// segue `a.b.c` a partir do escopo
fn chain(graph: *Graph, scope: []const u8, dotted: []const u8, depth: usize) ?Entry {
    var parts = std.mem.splitScalar(u8, dotted, '.');
    var found = lookup(graph, scope, parts.first(), depth);
    while (parts.next()) |part| {
        const current = found orelse return null;
        if (current != .scope) return null;
        const scope_names = graph.scopes.get(current.scope) orelse return null;
        found = if (scope_names.get(part)) |entry| follow(graph, entry, depth) else null;
    }
    return found;
}

/// uma variável com o tipo escrito, e onde a leitura parou
const TypedName = struct { name: []const u8, type_name: []const u8, end: usize };

/// `x: *Tipo` (variável ou parâmetro)
fn variableAt(code: []const u8, at: usize) ?TypedName {
    var i: usize = undefined;
    if (code[at] == '(' or code[at] == ',') {
        i = at + 1;
    } else if (keywordAt(code, at, "var")) {
        i = at + 3;
    } else if (keywordAt(code, at, "const")) {
        i = at + 5;
    } else return null;
    i = skipSpace(code, i);
    const name_start = i;
    const name_end = wordEnd(code, i);
    if (name_end == i) return null;
    i = skipSpace(code, name_end);
    if (i >= code.len or code[i] != ':') return null;
    i = skipSpace(code, i + 1);
    while (i < code.len) {
        if (code[i] == '*' or code[i] == '?') {
            i += 1;
        } else if (std.mem.startsWith(u8, code[i..], "[]")) {
            i += 2;
        } else if (std.mem.startsWith(u8, code[i..], "const") and i + 5 < code.len and isSpace(code[i + 5])) {
            i = skipSpace(code, i + 5);
        } else break;
    }
    if (i >= code.len or !isIdentStart(code[i])) return null;
    var end = i;
    while (end < code.len and (isWord(code[end]) or code[end] == '.')) end += 1;
    return .{ .name = code[name_start..name_end], .type_name = code[i..end], .end = end };
}

/// `var x = [try] Tipo.init(` ou `var x = Tipo{`
fn constructedAt(code: []const u8, at: usize) ?TypedName {
    var i: usize = undefined;
    if (keywordAt(code, at, "var")) {
        i = at + 3;
    } else if (keywordAt(code, at, "const")) {
        i = at + 5;
    } else return null;
    if (i >= code.len or !isSpace(code[i])) return null;
    i = skipSpace(code, i);
    const name_start = i;
    const name_end = wordEnd(code, i);
    if (name_end == i) return null;
    i = skipSpace(code, name_end);
    if (i >= code.len or code[i] != '=') return null;
    i = skipSpace(code, i + 1);
    if (std.mem.startsWith(u8, code[i..], "try") and i + 3 < code.len and isSpace(code[i + 3])) i = skipSpace(code, i + 3);
    if (i >= code.len or !isIdentStart(code[i])) return null;
    var limit = i;
    while (limit < code.len and (isWord(code[limit]) or code[limit] == '.')) limit += 1;
    var end = i + 1;
    while (end <= limit) : (end += 1) {
        if (end < code.len and code[end] == '{') return .{ .name = code[name_start..name_end], .type_name = code[i..end], .end = end + 1 };
        if (end < code.len and code[end] == '.') {
            const method_end = wordEnd(code, end + 1);
            if (method_end > end + 1) {
                const paren = skipSpace(code, method_end);
                if (paren < code.len and code[paren] == '(') return .{ .name = code[name_start..name_end], .type_name = code[i..end], .end = paren + 1 };
            }
        }
    }
    return null;
}

fn variableTypes(graph: *Graph, scope: []const u8, body: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var typed: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (0..2) |pass| {
        var i: usize = 0;
        while (i < body.len) {
            const found = if (pass == 0) variableAt(body, i) else constructedAt(body, i);
            const match = found orelse {
                i += 1;
                continue;
            };
            i = match.end;
            const resolved = chain(graph, scope, match.type_name, 0) orelse continue;
            if (resolved == .scope and !typed.contains(match.name)) try typed.put(graph.memory, match.name, resolved.scope);
        }
    }
    return typed;
}

fn isKeyword(word: []const u8) bool {
    for (keywords) |keyword| if (std.mem.eql(u8, keyword, word)) return true;
    return false;
}

fn linkCalls(graph: *Graph) !void {
    const memory = graph.memory;
    var by_name: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (graph.symbols.values()) |symbol| {
        if (std.mem.endsWith(u8, symbol.modulo, ".zig") and isFunction(symbol.tipo)) try appendTo(memory, &by_name, symbol.nome, symbol.id);
    }
    for (graph.bodies.items) |body| {
        var typed = try variableTypes(graph, body.scope, body.code);
        const code = body.code;
        var i: usize = 0;
        while (i < code.len) {
            if (!isIdentStart(code[i]) or (i > 0 and (isWord(code[i - 1]) or code[i - 1] == '.' or code[i - 1] == '@'))) {
                i += 1;
                continue;
            }
            // a cadeia `a.b.c` mais longa, e o `(` depois dela
            var end = wordEnd(code, i);
            while (end + 1 < code.len and code[end] == '.' and isIdentStart(code[end + 1])) end = wordEnd(code, end + 1);
            const paren = skipSpace(code, end);
            if (paren >= code.len or code[paren] != '(') {
                i = end;
                continue;
            }
            const path = code[i..end];
            i = paren + 1;
            var parts: std.ArrayList([]const u8) = .empty;
            var split = std.mem.splitScalar(u8, path, '.');
            while (split.next()) |part| try parts.append(memory, part);
            const first = parts.items[0];
            const last = parts.items[parts.items.len - 1];
            if (isKeyword(first) or isKeyword(last)) continue;
            if (parts.items.len == 2) {
                if (typed.get(first)) |type_scope| {
                    if (graph.scopes.get(type_scope)) |scope_names| {
                        if (scope_names.get(last)) |entry| if (entry == .function) {
                            try graph.addCall(body.function, entry.function);
                            continue;
                        };
                    }
                }
            }
            const found = chain(graph, body.scope, path, 0);
            var target: ?[]const u8 = if (found) |entry| (if (entry == .function) entry.function else null) else null;
            if (target == null and parts.items.len >= 2) {
                // x.metodo(): o tipo de x não é lido; vale só se o nome for único no projeto
                if (by_name.get(last)) |options| if (options.items.len == 1) {
                    target = options.items[0];
                };
            }
            if (target == null) if (found) |entry| if (entry == .scope) {
                target = entry.scope; // Tipo(...) ou Tipo{...}: usa o tipo
            };
            if (target) |to| if (!std.mem.eql(u8, to, body.function) and graph.symbols.contains(to)) try graph.addCall(body.function, to);
        }
        typed.deinit(memory);
    }
}

// ---------------------------------------------------------------- Python (só as declarações)

/// as classes e funções de um .py (do nível do módulo e os métodos), pela indentação; sem as chamadas
fn readPython(graph: *Graph, path: []const u8, text: []const u8) !void {
    const memory = graph.memory;
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try lines.append(memory, line);
    var class_name: ?[]const u8 = null;
    var class_indent: usize = 0;
    for (lines.items, 0..) |raw, index| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const content = std.mem.trimStart(u8, line, " \t");
        if (content.len == 0 or content[0] == '#') continue;
        const indent = line.len - content.len;
        if (class_name != null and indent <= class_indent) class_name = null;
        const is_class = std.mem.startsWith(u8, content, "class ");
        const is_def = std.mem.startsWith(u8, content, "def ") or std.mem.startsWith(u8, content, "async def ");
        if (!is_class and !is_def) continue;
        const keyword_end = std.mem.indexOf(u8, content, if (is_class) "class " else "def ").? + (if (is_class) "class ".len else "def ".len);
        const name_end = wordEnd(content, keyword_end);
        if (name_end == keyword_end) continue;
        const name = content[keyword_end..name_end];
        const inside_class = class_name != null and indent > class_indent;
        if (indent > 0 and !inside_class) continue;
        // o fim: a última linha com texto antes da próxima no mesmo nível (ou mais para fora)
        var last = index;
        for (lines.items[index + 1 ..], index + 1..) |next_raw, k| {
            const next = std.mem.trimEnd(u8, next_raw, " \t\r");
            const next_content = std.mem.trimStart(u8, next, " \t");
            if (next_content.len == 0) continue;
            if (next.len - next_content.len <= indent) break;
            last = k;
        }
        const signature = std.mem.trimEnd(u8, content, ":");
        if (is_class) {
            const id = try std.fmt.allocPrint(memory, "{s}#{s}", .{ path, name });
            try graph.addSymbol(.{ .id = id, .modulo = path, .nome = name, .tipo = "classe", .dono = null, .assinatura = signature, .doc = "", .inicio = index + 1, .fim = last + 1 });
            class_name = name;
            class_indent = indent;
        } else {
            const id = if (inside_class) try std.fmt.allocPrint(memory, "{s}#{s}.{s}", .{ path, class_name.?, name }) else try std.fmt.allocPrint(memory, "{s}#{s}", .{ path, name });
            try graph.addSymbol(.{ .id = id, .modulo = path, .nome = name, .tipo = if (inside_class) "método" else "função", .dono = if (inside_class) class_name else null, .assinatura = signature, .doc = "", .inicio = index + 1, .fim = last + 1 });
        }
    }
}

test "chamadas no Zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph: Graph = .{ .memory = arena.allocator() };
    const source =
        \\const std = @import("std");
        \\/// um ponto
        \\pub const Point = struct {
        \\    x: f64,
        \\    /// a norma
        \\    pub fn norm(point: Point) f64 {
        \\        return @sqrt(point.x * point.x);
        \\    }
        \\};
        \\fn twice(point: Point) f64 {
        \\    const other = Point{ .x = 1 };
        \\    return point.norm() + other.norm(); // "texto"
        \\}
    ;
    try graph.modules.put(graph.memory, "a.zig", .{ .id = "a.zig", .nome = "a", .grupo = "a", .lang = "zig", .linhas = 13 });
    try readZig(&graph, "a.zig", source);
    try linkCalls(&graph);
    try std.testing.expectEqual(@as(usize, 3), graph.symbols.count());
    try std.testing.expectEqualStrings("a norma", graph.symbols.get("a.zig#Point.norm").?.doc);
    try std.testing.expectEqualStrings("pub fn norm(point: Point) f64", graph.symbols.get("a.zig#Point.norm").?.assinatura);
    // as duas chamadas de `norm` (pelo tipo do parâmetro e pelo `Point{...}`) viram uma ligação só
    try std.testing.expectEqual(@as(usize, 1), graph.calls.items.len);
    try std.testing.expectEqualStrings("a.zig#twice", graph.calls.items[0].from);
    try std.testing.expectEqualStrings("a.zig#Point.norm", graph.calls.items[0].to);
}

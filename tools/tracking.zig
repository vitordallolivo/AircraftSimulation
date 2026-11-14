//! Tracking em HTML: as tabelas do Quadro do docs/TRACKING.md viram uma página só (sem nada para baixar).
//!
//!     zig build tracking                              grava a página em zig-out/site/tracking.html
//!     zig build tracking -- --html x.html             em outro lugar
//!     zig build tracking -- --check                   só confere se toda linha das tabelas tem as 6 colunas
//!     zig build tracking -- --feito G26 dc19cf2       marca a tarefa como Terminado, com o commit (sem ele, o HEAD)
//!     zig build tracking -- --estado G27 "Em andamento"
//!     zig build tracking -- --issue corpo.txt         aplica uma issue "[tracking] ..." (o que a Action faz)
//!
//! O TRACKING.md continua sendo a fonte: cada "### segmento" do Quadro, com o parágrafo que o descreve e a tabela
//! (ID, Tarefa, Nível, Depende de, Prioridade, Estado). Uma tarefa nova é uma linha nova na tabela. Uma tarefa
//! resolvida fica "Terminado (commit abc1234)": a página risca o título, põe o link do commit e tira a tarefa da
//! sequência dos próximos.
//!
//! A página também muda o .md sem colar nada: "Confirmar terminado" e "+ Nova tarefa" abrem uma issue "[tracking] ..."
//! já preenchida, e a Action .github/workflows/tracking.yml (só para issues do dono do repositório) roda `--issue` com
//! o corpo dela, faz o commit na 0.2_dev e fecha a issue. O corpo é "chave: valor" por linha (acao feito|nova, id,
//! commit, segmento, nivel, depende, prioridade, estado), depois "---" e o texto livre. A página mostra também a
//! "Ordem de prioridade" e o "Progresso" do TRACKING.md e as tabelas do docs/AREAS.md. O `zig build site` usa a
//! mesma página, então o site publicado sai sempre do .md da `main`.
const std = @import("std");

const tracking_path = "docs/TRACKING.md";
const areas_path = "docs/AREAS.md";
const template_path = "tools/tracking_page.html";
const default_page = "zig-out/site/tracking.html";
const states = [_][]const u8{ "Não iniciado", "Em andamento", "Terminado" };

pub const Item = struct {
    id: []const u8,
    tarefa: []const u8,
    nivel: []const u8,
    prioridade: []const u8,
    depende: []const []const u8,
    estado: []const u8,
    obs: []const u8,
};

pub const Segment = struct {
    nome: []const u8,
    descricao: []const u8,
    itens: []const Item,
};

/// os segmentos do Quadro, o que vem depois da última tabela e as linhas com problema
pub const Board = struct {
    segmentos: []const Segment,
    notas: []const []const u8,
    problems: []const []const u8,
};

/// ponto de entrada: muda o TRACKING.md (--feito, --estado, --issue), confere (--check) ou grava a página
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const memory = init.arena.allocator();
    const args = try init.minimal.args.toSlice(memory);
    var html: []const u8 = default_page;
    var check = false;
    var done: ?[2]?[]const u8 = null;
    var state_change: ?[2][]const u8 = null;
    var issue: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--html") and i + 1 < args.len) {
            i += 1;
            html = args[i];
        } else if (std.mem.eql(u8, arg, "--issue") and i + 1 < args.len) {
            i += 1;
            issue = args[i];
        } else if (std.mem.eql(u8, arg, "--estado") and i + 2 < args.len) {
            state_change = .{ args[i + 1], args[i + 2] };
            i += 2;
        } else if (std.mem.eql(u8, arg, "--feito") and i + 1 < args.len) {
            i += 1;
            var pair: [2]?[]const u8 = .{ args[i], null };
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                pair[1] = args[i];
            }
            done = pair;
        } else fail("argumento desconhecido: {s}", .{arg});
    }

    const cwd = std.Io.Dir.cwd();
    var text: []const u8 = try cwd.readFileAlloc(io, tracking_path, memory, .limited(1 << 24));
    if (done != null or state_change != null) {
        var ident: []const u8 = undefined;
        var state: []const u8 = undefined;
        if (done) |pair| {
            ident = pair[0].?;
            const commit = pair[1] orelse try headCommit(memory, io);
            state = try std.fmt.allocPrint(memory, "Terminado (commit {s})", .{commit});
        } else {
            ident = state_change.?[0];
            state = state_change.?[1];
        }
        text = try setState(memory, text, ident, state);
        try cwd.writeFile(io, .{ .sub_path = tracking_path, .data = text });
        std.debug.print("docs/TRACKING.md: {s} → {s}\n", .{ ident, state });
    }
    if (issue) |issue_path| {
        const body = try cwd.readFileAlloc(io, issue_path, memory, .limited(1 << 20));
        const changed = try applyIssue(memory, text, try readIssue(memory, body));
        text = changed.text;
        try cwd.writeFile(io, .{ .sub_path = tracking_path, .data = text });
        std.debug.print("docs/TRACKING.md: {s}\n", .{changed.summary});
    }
    const data = try board(memory, text);
    for (data.problems) |problem| std.debug.print("docs/TRACKING.md: {s}\n", .{problem});
    if (check) {
        std.debug.print("{s}\n", .{if (data.problems.len == 0) "Quadro do TRACKING.md legível" else "corrija as linhas acima"});
        if (data.problems.len > 0) std.process.exit(1);
        return;
    }
    try writePage(memory, io, text, data, html);
    var total: usize = 0;
    for (data.segmentos) |segment| total += segment.itens.len;
    std.debug.print("{s}: {d} tarefas em {d} segmentos\n", .{ html, total, data.segmentos.len });
}

/// grava a página do tracking em `path` (cria a pasta)
pub fn writePage(memory: std.mem.Allocator, io: std.Io, text: []const u8, data: Board, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |folder| try cwd.createDirPath(io, folder);
    try cwd.writeFile(io, .{ .sub_path = path, .data = try page(memory, io, text, data) });
}

fn fail(comptime format: []const u8, values: anytype) noreturn {
    std.debug.print(format ++ "\n", values);
    std.process.exit(1);
}

/// as células de uma linha de tabela (o texto da tarefa não tem `|`)
fn cells(memory: std.mem.Allocator, line: []const u8) ![][]const u8 {
    const inner = std.mem.trim(u8, std.mem.trim(u8, line, " \t\r\n"), "|");
    var parts: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitSequence(u8, inner, " | ");
    while (split.next()) |cell| try parts.append(memory, std.mem.trim(u8, cell, " \t\r\n"));
    return parts.items;
}

/// "ABC12": letras maiúsculas e depois algarismos
fn isIdent(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len and std.ascii.isUpper(text[i])) i += 1;
    if (i == 0 or i == text.len) return false;
    for (text[i..]) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

/// a linha começa com "| ID |"
fn rowIdent(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "| ")) return null;
    const end = std.mem.indexOfPos(u8, line, 2, " |") orelse return null;
    const ident = line[2..end];
    return if (isIdent(ident)) ident else null;
}

/// os segmentos do Quadro (nome, descrição, itens) e as linhas com problema
pub fn board(memory: std.mem.Allocator, text: []const u8) !Board {
    const begin = std.mem.indexOf(u8, text, "\n## Quadro") orelse return error.SemQuadro;
    const end = std.mem.indexOfPos(u8, text, begin + 1, "\n## ") orelse text.len;
    var segments: std.ArrayList(Segment) = .empty;
    var items: std.ArrayList(Item) = .empty;
    var description: std.ArrayList(u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var current: ?[]const u8 = null;
    var in_table = false;
    var lines = std.mem.splitScalar(u8, text[begin..end], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "### ")) {
            if (current) |name| try segments.append(memory, .{ .nome = name, .descricao = description.items, .itens = items.items });
            current = std.mem.trim(u8, line[4..], " \t\r");
            items = .empty;
            description = .empty;
            in_table = false;
            continue;
        }
        if (current == null) continue;
        if (std.mem.startsWith(u8, line, "| ID |") or std.mem.startsWith(u8, line, "|---")) {
            in_table = true;
            continue;
        }
        if (rowIdent(line) != null) {
            const parts = try cells(memory, line);
            if (parts.len != 6) {
                try problems.append(memory, try std.fmt.allocPrint(memory, "{s}: {d} colunas em vez de 6", .{ parts[0], parts.len }));
                continue;
            }
            const state_cell = parts[5];
            var state = state_cell;
            var note: []const u8 = "";
            if (state_cell.len > 0 and state_cell[state_cell.len - 1] == ')') {
                if (std.mem.indexOf(u8, state_cell, " (")) |at| {
                    state = state_cell[0..at];
                    note = state_cell[at + 2 .. state_cell.len - 1];
                }
            }
            const head = if (std.mem.indexOf(u8, state_cell, " (")) |at| state_cell[0..at] else state_cell;
            for (states) |known| {
                if (std.mem.eql(u8, known, head)) break;
            } else try problems.append(memory, try std.fmt.allocPrint(memory, "{s}: estado '{s}' (use Não iniciado, Em andamento, Terminado)", .{ parts[0], state_cell }));
            var depends: std.ArrayList([]const u8) = .empty;
            var tokens = std.mem.tokenizeAny(u8, parts[3], ",;");
            while (tokens.next()) |token| {
                const trimmed = std.mem.trim(u8, token, " \t");
                if (isIdent(trimmed)) try depends.append(memory, trimmed);
            }
            try items.append(memory, .{ .id = parts[0], .tarefa = parts[1], .nivel = parts[2], .prioridade = parts[4], .depende = depends.items, .estado = state, .obs = note });
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "---")) continue;
        if (in_table) {
            try notes.append(memory, line); // o que vem depois da última tabela (o caminho crítico)
        } else {
            if (description.items.len > 0) try description.append(memory, ' ');
            try description.appendSlice(memory, trimmed);
        }
    }
    if (current) |name| try segments.append(memory, .{ .nome = name, .descricao = description.items, .itens = items.items });
    return .{ .segmentos = segments.items, .notas = notes.items, .problems = problems.items };
}

fn joinRow(memory: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    const inner = try std.mem.join(memory, " | ", parts);
    return std.fmt.allocPrint(memory, "| {s} |", .{inner});
}

fn rowStart(memory: std.mem.Allocator, ident: []const u8) ![]const u8 {
    return std.fmt.allocPrint(memory, "| {s} |", .{ident});
}

/// o TRACKING.md com a coluna Estado da tarefa `ident` trocada por `state`
pub fn setState(memory: std.mem.Allocator, text: []const u8, ident: []const u8, state: []const u8) ![]const u8 {
    const lines = try splitLines(memory, text);
    const start = try rowStart(memory, ident);
    for (lines, 0..) |line, i| if (std.mem.startsWith(u8, line, start)) {
        const parts = try cells(memory, line);
        if (parts.len != 6) fail("{s}: a linha não tem as 6 colunas", .{ident});
        parts[5] = state;
        lines[i] = try joinRow(memory, parts);
        return std.mem.join(memory, "\n", lines);
    };
    fail("{s}: não está no Quadro", .{ident});
}

fn splitLines(memory: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try lines.append(memory, line);
    return lines.items;
}

/// os campos de uma issue do tracking: "chave: valor" por linha e, depois do "---", o texto livre
pub const Issue = struct {
    fields: std.StringHashMapUnmanaged([]const u8) = .empty,
    texto: []const u8 = "",

    fn get(issue: Issue, key: []const u8) []const u8 {
        return issue.fields.get(key) orelse "";
    }
};

/// os campos do corpo de uma issue do tracking (o mesmo formato que a página escreve)
pub fn readIssue(memory: std.mem.Allocator, raw: []const u8) !Issue {
    const body = try std.mem.replaceOwned(u8, memory, raw, "\r", "");
    const cut = std.mem.indexOf(u8, body, "\n---\n");
    const head = if (cut) |at| body[0..at] else body;
    const rest = if (cut) |at| body[at + 5 ..] else "";
    var issue: Issue = .{};
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        if (key.len == 0) continue;
        for (key) |char| if (!(std.ascii.isAlphanumeric(char) or char == '_')) break else {
            try issue.fields.put(memory, key, std.mem.trim(u8, line[colon + 1 ..], " \t"));
        };
    }
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, rest, " \t\n\r\x0b\x0c");
    while (tokens.next()) |word| try words.append(memory, word);
    const joined = try std.mem.join(memory, " ", words.items);
    issue.texto = try std.mem.replaceOwned(u8, memory, joined, "|", "/");
    return issue;
}

/// o próximo número livre: O no aeroopt, G na GUI, T no resto (um contador só para os outros segmentos)
fn nextId(memory: std.mem.Allocator, text: []const u8, segment: []const u8) ![]const u8 {
    const prefix: u8 = if (std.mem.eql(u8, segment, "aeroopt")) 'O' else if (std.mem.eql(u8, segment, "GUI")) 'G' else 'T';
    var highest: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const ident = rowIdent(line) orelse continue;
        if (ident.len < 2 or ident[0] != prefix or !std.ascii.isDigit(ident[1])) continue;
        highest = @max(highest, std.fmt.parseInt(u32, ident[1..], 10) catch continue);
    }
    return std.fmt.allocPrint(memory, "{c}{d:0>2}", .{ prefix, highest + 1 });
}

/// o TRACKING.md com a mudança da issue e uma linha dizendo o que mudou
pub fn applyIssue(memory: std.mem.Allocator, text: []const u8, issue: Issue) !struct { text: []const u8, summary: []const u8 } {
    const action = issue.get("acao");
    if (std.mem.eql(u8, action, "feito")) {
        const ident = issue.get("id");
        const lines = try splitLines(memory, text);
        const start = try rowStart(memory, ident);
        for (lines, 0..) |line, i| if (std.mem.startsWith(u8, line, start)) {
            const parts = try cells(memory, line);
            if (issue.texto.len > 0) parts[1] = try std.fmt.allocPrint(memory, "{s} Feito: {s}", .{ parts[1], issue.texto });
            const commit = issue.get("commit");
            parts[5] = if (commit.len > 0) try std.fmt.allocPrint(memory, "Terminado (commit {s})", .{commit}) else "Terminado";
            lines[i] = try joinRow(memory, parts);
            return .{ .text = try std.mem.join(memory, "\n", lines), .summary = try std.fmt.allocPrint(memory, "{s} terminado", .{ident}) };
        };
        fail("{s}: não está no Quadro", .{ident});
    }
    if (std.mem.eql(u8, action, "nova")) {
        const segment = issue.get("segmento");
        const board_at = std.mem.indexOf(u8, text, "\n## Quadro") orelse fail("sem Quadro", .{});
        const marker = try std.fmt.allocPrint(memory, "\n### {s}\n", .{segment});
        const heading = std.mem.indexOfPos(u8, text, board_at, marker) orelse fail("segmento '{s}' não existe no Quadro", .{segment});
        var lines: std.ArrayList([]const u8) = .fromOwnedSlice(try splitLines(memory, text[heading + 1 ..]));
        var limit = lines.items.len;
        for (lines.items[1..], 1..) |line, k| if (std.mem.startsWith(u8, line, "#")) {
            limit = k;
            break;
        };
        var last: ?usize = null;
        for (lines.items[0..limit], 0..) |line, k| if (rowIdent(line) != null) {
            last = k;
        };
        const after = last orelse fail("segmento '{s}' sem tabela", .{segment});
        const ident = try nextId(memory, text, segment);
        var depends: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, try std.ascii.allocUpperString(memory, issue.get("depende")), ",; \t\n\r");
        while (tokens.next()) |token| if (isIdent(token)) try depends.append(memory, token);
        const row = try std.fmt.allocPrint(memory, "| {s} | {s} | {s} | {s} | {s} | {s} |", .{
            ident,
            if (issue.texto.len > 0) issue.texto else "(sem texto)",
            orDefault(issue.get("nivel"), "Análise"),
            if (depends.items.len > 0) try std.mem.join(memory, ", ", depends.items) else "—",
            orDefault(issue.get("prioridade"), "—"),
            orDefault(issue.get("estado"), "Não iniciado"),
        });
        try lines.insert(memory, after + 1, row);
        const joined = try std.mem.join(memory, "\n", lines.items);
        return .{
            .text = try std.mem.concat(memory, u8, &.{ text[0 .. heading + 1], joined }),
            .summary = try std.fmt.allocPrint(memory, "{s} nova em {s}", .{ ident, segment }),
        };
    }
    fail("ação desconhecida: '{s}' (feito ou nova)", .{action});
}

fn orDefault(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len > 0) value else fallback;
}

fn headCommit(memory: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try std.process.run(memory, io, .{ .argv = &.{ "git", "rev-parse", "--short", "HEAD" } });
    return std.mem.trim(u8, result.stdout, " \n\r");
}

/// o corpo de uma seção "## título" do Markdown, até a próxima "## " ou "---"
pub fn section(text: []const u8, title: []const u8) []const u8 {
    var offset: usize = 0;
    while (offset <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = text[offset..line_end];
        if (std.mem.startsWith(u8, line, "## ") and std.mem.startsWith(u8, line[3..], title)) {
            const body_start = line_end;
            var cursor = @min(line_end + 1, text.len);
            while (cursor < text.len) {
                const next_end = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
                const next = text[cursor..next_end];
                if (std.mem.startsWith(u8, next, "## ") or std.mem.eql(u8, next, "---")) break;
                cursor = next_end + 1;
            }
            return std.mem.trim(u8, text[body_start..@min(cursor, text.len)], " \t\r\n");
        }
        offset = line_end + 1;
    }
    return "";
}

/// a tabela "Níveis": nível → o que ele é (para o (?) da página)
fn writeLevels(json: *std.json.Stringify, text: []const u8) !void {
    try json.beginObject();
    var lines = std.mem.splitScalar(u8, section(text, "Níveis"), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| **") or !std.mem.endsWith(u8, line, " |")) continue;
        const name_end = std.mem.indexOfPos(u8, line, 4, "** | ") orelse continue;
        if (name_end == 4) continue;
        try json.objectField(line[4..name_end]);
        try json.write(line[name_end + 5 .. line.len - 2]);
    }
    try json.endObject();
}

/// a página HTML com os dados embutidos; quem desenha é o JavaScript dela
pub fn page(memory: std.mem.Allocator, io: std.Io, text: []const u8, data: Board) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const areas = try cwd.readFileAlloc(io, areas_path, memory, .limited(1 << 24));
    const template = try cwd.readFileAlloc(io, template_path, memory, .limited(1 << 24));
    var out: std.Io.Writer.Allocating = .init(memory);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("segmentos");
    try json.write(data.segmentos);
    try json.objectField("notas");
    try json.write(data.notas);
    try json.objectField("prioridade");
    try json.write(section(text, "Ordem de prioridade"));
    try json.objectField("progresso");
    try json.write(section(text, "Progresso da lista"));
    try json.objectField("areas"); // sem o título "# Áreas e submódulos"
    try json.write(std.mem.trim(u8, if (std.mem.indexOfScalar(u8, areas, '\n')) |at| areas[at + 1 ..] else "", " \t\r\n"));
    try json.objectField("niveis");
    try writeLevels(&json, text);
    try json.objectField("gerado");
    try json.write(try isoNow(memory, io));
    try json.endObject();
    const blob = try std.mem.replaceOwned(u8, memory, out.written(), "</", "<\\/");
    return std.mem.replaceOwned(u8, memory, template, "/*DADOS*/null", blob);
}

/// a hora de agora em UTC, como "2026-11-14T00:35:02Z"
fn isoNow(memory: std.mem.Allocator, io: std.Io) ![]const u8 {
    const seconds: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(memory, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,                    month_day.month.numeric(),     month_day.day_index + 1,
        time.getHoursIntoDay(),      time.getMinutesIntoHour(),     time.getSecondsIntoMinute(),
    });
}

test "tabela do Quadro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const text =
        \\# Tracking
        \\
        \\## Quadro
        \\
        \\### GUI
        \\
        \\Telas.
        \\
        \\| ID | Tarefa | Nível | Depende de | Prioridade | Estado |
        \\|---|---|---|---|---|---|
        \\| G01 | Abrir | Análise | — | 1 | Terminado (commit abc1234) |
        \\| G02 | Salvar | Análise | G01, T03 | 2 | Em andamento |
        \\| G03 | Fora | Análise | — | 2 |
        \\
        \\## Fim
    ;
    const data = try board(memory, text);
    try std.testing.expectEqual(@as(usize, 1), data.segmentos.len);
    try std.testing.expectEqualStrings("Telas.", data.segmentos[0].descricao);
    try std.testing.expectEqual(@as(usize, 2), data.segmentos[0].itens.len);
    try std.testing.expectEqualStrings("commit abc1234", data.segmentos[0].itens[0].obs);
    try std.testing.expectEqualStrings("T03", data.segmentos[0].itens[1].depende[1]);
    try std.testing.expectEqual(@as(usize, 1), data.problems.len);

    const issue = try readIssue(memory, "acao: nova\r\nsegmento: GUI\r\ndepende: g02\n---\nNova  tela | x\n");
    const changed = try applyIssue(memory, text, issue);
    try std.testing.expectEqualStrings("G04 nova em GUI", changed.summary);
    try std.testing.expect(std.mem.indexOf(u8, changed.text, "| G04 | Nova tela / x | Análise | G02 | — | Não iniciado |") != null);
    const done = try setState(memory, text, "G02", "Terminado");
    try std.testing.expect(std.mem.indexOf(u8, done, "| G02 | Salvar | Análise | G01, T03 | 2 | Terminado |") != null);
}

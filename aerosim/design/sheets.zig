//! Planilha…: trazer dados de uma planilha `.xlsx` qualquer (as das equipes) sem mapa de células. Cada área tem o
//! botão que abre a janela da planilha (`gui/sheet_window.zig`), que mostra a aba como o Excel e chama as funções
//! daqui. O usuário abre a planilha, vê as abas e as células, marca um bloco (o canto de cima, ou o intervalo inteiro: a
//! primeira linha do bloco são os títulos das colunas), diz o que o bloco é e qual coluna é qual (o programa sugere
//! pelos títulos) e guarda com o nome que quiser. Cada combinação guardada vira um `.csv` na pasta da biblioteca
//! (`<pasta dos projetos>/biblioteca/planilhas`), que vale para todos os projetos; os motores vão direto para a
//! biblioteca de motores.
//!
//!     polar            α, C_L, C_D, C_m             uma curva do avião ou de uma peça
//!     distribuição     y, c_l                        a sustentação ao longo da envergadura
//!     curva            x, y                          qualquer curva por velocidade (tração, subida, curva...)
//!     motores          nome, Kv, R, I máx., massa    uma linha por motor
const std = @import("std");
const core = @import("aerosim");
const catalog = @import("catalog");
const stages = @import("stages.zig");
const library = @import("stage_library.zig");

pub const xlsx = core.xlsx;

/// o que um bloco pode ser
pub const Kind = enum {
    polar,
    distribution,
    curve,
    motors,

    /// o nome na tela (e no `# tipo:` do .csv)
    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .polar => "polar",
            .distribution => "distribuição de sustentação",
            .curve => "curva (x, y)",
            .motors => "motores",
        };
    }

    /// as colunas que o bloco precisa (as obrigatórias primeiro)
    pub fn roles(kind: Kind) []const Role {
        return switch (kind) {
            .polar => &polar_roles,
            .distribution => &distribution_roles,
            .curve => &curve_roles,
            .motors => &motor_roles,
        };
    }
};

/// uma coluna que o tipo pede: a chave (o título no .csv), o nome na tela e os começos de título que a sugerem
pub const Role = struct { key: []const u8, label: []const u8, hints: []const []const u8, required: bool = true };

const polar_roles = [_]Role{
    .{ .key = "alpha", .label = "α (°)", .hints = &.{ "alpha", "alfa", "α", "aoa" } },
    .{ .key = "CL", .label = "C_L", .hints = &.{"cl"} },
    .{ .key = "CD", .label = "C_D", .hints = &.{"cd"}, .required = false },
    .{ .key = "Cm", .label = "C_m", .hints = &.{"cm"}, .required = false },
};
const distribution_roles = [_]Role{
    .{ .key = "y", .label = "y (posição na envergadura)", .hints = &.{ "y", "2y", "eta", "η", "envergadura", "span" } },
    .{ .key = "cl", .label = "c_l (sustentação local)", .hints = &.{ "cl", "c_l" } },
};
const curve_roles = [_]Role{
    .{ .key = "x", .label = "eixo x", .hints = &.{ "v", "velocidade", "x" } },
    .{ .key = "y", .label = "eixo y", .hints = &.{} },
};
const motor_roles = [_]Role{
    .{ .key = "name", .label = "nome", .hints = &.{ "modelo", "nome", "motor", "model" } },
    .{ .key = "Kv", .label = "Kv (rpm/V)", .hints = &.{"kv"} },
    .{ .key = "Rm", .label = "resistência (Ω)", .hints = &.{ "rm", "r ", "resist" } },
    .{ .key = "Imax", .label = "corrente máxima (A)", .hints = &.{ "imax", "i max", "i_max", "corrente" }, .required = false },
    .{ .key = "mass", .label = "massa (kg)", .hints = &.{ "massa", "mass", "peso" }, .required = false },
};

const none = "—";
const kinds = [_]Kind{ .polar, .distribution, .curve, .motors };

/// a planilha aberta e o que está marcado nela (fica entre um pedido e outro)
const Draft = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    path: []const u8 = "",
    book: ?xlsx.Workbook = null,
    sheet: usize = 0,
    range: []const u8 = "",
    kind: Kind = .polar,
    name: []const u8 = "",
    /// a coluna do bloco de cada papel (`null`: nenhuma)
    columns: [8]?usize = @splat(null),
    /// as colunas foram escolhidas à mão (não sugerir de novo)
    columns_chosen: bool = false,
    /// motores: o que vale quando a planilha não tem a coluna
    default_imax: f64 = 40,
    default_mass: f64 = 0.2,
    /// a área que abriu a janela
    area_buffer: [48]u8 = undefined,
    area_len: usize = 0,
};
var draft: Draft = .{};
/// a memória dos textos do rascunho (nome, intervalo), trocada a cada pedido
var text_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// a pasta das combinações guardadas
pub fn folder(memory: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(memory, &.{ try stages.projectsRoot(memory), "biblioteca", "planilhas" });
}

// ------------------------------------------------------------------ o bloco

/// um bloco da planilha: os títulos das colunas e os números (NaN onde a célula não tem número; o texto fica em
/// `texts`, para os nomes dos motores)
pub const Block = struct {
    first_row: u32,
    first_column: u32,
    last_row: u32,
    headers: []const []const u8,
    numbers: []const []const f64, // [coluna][linha]
    texts: []const []const []const u8, // [coluna][linha]

    pub fn rowCount(block: Block) usize {
        return if (block.numbers.len > 0) block.numbers[0].len else 0;
    }
};

/// o endereço de uma coluna ("A", "AB") a partir do número (de 1)
pub fn columnName(buffer: *[4]u8, column: u32) []const u8 {
    var number = column;
    var length: usize = 0;
    var reversed: [4]u8 = undefined;
    while (number > 0 and length < 4) : (length += 1) {
        number -= 1;
        reversed[length] = @intCast('A' + number % 26);
        number /= 26;
    }
    for (0..length) |i| buffer[i] = reversed[length - 1 - i];
    return buffer[0..length];
}

/// o texto de uma célula para a tela (o número curto, o texto como está)
fn cellText(memory: std.mem.Allocator, value: ?xlsx.Value) ![]const u8 {
    const cell = value orelse return "";
    return switch (cell) {
        .number => |number| try std.fmt.allocPrint(memory, "{d:.4}", .{number}),
        .text => |text| text,
        .boolean => |flag| if (flag) "verdadeiro" else "falso",
    };
}

/// o bloco marcado por `range`: "B6:R40", ou só o canto de cima ("B6"), e então o bloco vai para a direita enquanto
/// houver título e para baixo enquanto alguma coluna tiver número
pub fn readBlock(memory: std.mem.Allocator, sheet: xlsx.Sheet, range: []const u8) !Block {
    const trimmed = std.mem.trim(u8, range, " ");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':');
    const top = try xlsx.parseAddress(if (colon) |at| trimmed[0..at] else trimmed);
    var last_column: u32 = top.column;
    var last_row: u32 = top.row;
    if (colon) |at| {
        const bottom = try xlsx.parseAddress(trimmed[at + 1 ..]);
        last_column = @max(bottom.column, top.column);
        last_row = @max(bottom.row, top.row);
    } else {
        while (last_column < top.column + 200 and sheet.at(top.row, last_column + 1) != null) last_column += 1;
        const end = sheet.lastRow();
        last_row = top.row;
        var row = top.row + 1;
        while (row <= end) : (row += 1) {
            var any = false;
            var column = top.column;
            while (column <= last_column) : (column += 1) {
                if (sheet.at(row, column)) |value| if (value.asNumber() != null) {
                    any = true;
                    break;
                };
            }
            if (!any) break;
            last_row = row;
        }
    }
    const width = last_column - top.column + 1;
    const height = last_row - top.row;
    const headers = try memory.alloc([]const u8, width);
    const numbers = try memory.alloc([]const f64, width);
    const texts = try memory.alloc([]const []const u8, width);
    for (0..width) |k| {
        const column: u32 = top.column + @as(u32, @intCast(k));
        var letters: [4]u8 = undefined;
        const header = try cellText(memory, sheet.at(top.row, column));
        headers[k] = if (header.len > 0) header else try memory.dupe(u8, columnName(&letters, column));
        const column_numbers = try memory.alloc(f64, height);
        const column_texts = try memory.alloc([]const u8, height);
        for (0..height) |j| {
            const value = sheet.at(top.row + 1 + @as(u32, @intCast(j)), column);
            column_numbers[j] = if (value) |cell| cell.asNumber() orelse std.math.nan(f64) else std.math.nan(f64);
            column_texts[j] = try cellText(memory, value);
        }
        numbers[k] = column_numbers;
        texts[k] = column_texts;
    }
    return .{ .first_row = top.row, .first_column = top.column, .last_row = last_row, .headers = headers, .numbers = numbers, .texts = texts };
}

/// o canto de cima do maior bloco da aba ("AN8"), ou null: um bloco é uma fila de títulos (textos) lado a lado com
/// números logo embaixo de cada um; ganha o de mais colunas (no empate, o primeiro)
pub fn detectBlock(memory: std.mem.Allocator, sheet: xlsx.Sheet) !?[]const u8 {
    var best_width: u32 = 1;
    var best: ?xlsx.Cell = null;
    for (sheet.cells) |cell| {
        if (!isTitle(sheet, cell.row, cell.column)) continue;
        if (cell.column > 1 and isTitle(sheet, cell.row, cell.column - 1)) continue; // não é o começo da fila
        var width: u32 = 0;
        while (isTitle(sheet, cell.row, cell.column + width)) width += 1;
        if (width > best_width) {
            best_width = width;
            best = cell;
        }
    }
    const corner = best orelse return null;
    var letters: [4]u8 = undefined;
    return try std.fmt.allocPrint(memory, "{s}{d}", .{ columnName(&letters, corner.column), corner.row });
}

/// a célula é um título de coluna: um texto com um número logo embaixo
fn isTitle(sheet: xlsx.Sheet, row: u32, column: u32) bool {
    const value = sheet.at(row, column) orelse return false;
    if (value != .text) return false;
    const below = sheet.at(row + 1, column) orelse return false;
    return below.asNumber() != null;
}

/// a coluna sugerida para cada papel: a primeira cujo título começa por uma das pistas (sem repetir coluna); a curva
/// sem pista pega as colunas na ordem
pub fn suggest(kind: Kind, headers: []const []const u8) [8]?usize {
    var chosen: [8]?usize = @splat(null);
    var used = [_]bool{false} ** 256;
    for (kind.roles(), 0..) |role, r| {
        for (headers, 0..) |header, k| {
            if (k >= used.len or used[k]) continue;
            const text = std.mem.trimStart(u8, header, " ");
            for (role.hints) |hint| if (text.len >= hint.len and std.ascii.eqlIgnoreCase(text[0..hint.len], hint)) {
                chosen[r] = k;
                break;
            };
            if (chosen[r] != null) {
                used[k] = true;
                break;
            }
        }
        if (chosen[r] == null and role.required) for (0..@min(headers.len, used.len)) |k| if (!used[k]) {
            chosen[r] = k;
            used[k] = true;
            break;
        };
    }
    return chosen;
}

// ------------------------------------------------------------------ o .csv de uma combinação

/// uma combinação guardada: o tipo, de onde veio e as colunas (os papéis do tipo)
pub const Saved = struct {
    name: []const u8,
    kind: Kind,
    source: []const u8,
    /// a área em que foi guardada ("" nas antigas)
    area: []const u8 = "",
    headers: []const []const u8,
    columns: []const []const f64,
};

/// a combinação em .csv: `# tipo:`, `# fonte:`, os títulos (as chaves dos papéis) e uma linha por ponto
pub fn writeCsv(out: *std.Io.Writer, kind: Kind, source: []const u8, area: []const u8, block: Block, columns: [8]?usize) !void {
    try out.print("# tipo: {s}\n# fonte: {s}\n", .{ @tagName(kind), source });
    if (area.len > 0) try out.print("# área: {s}\n", .{area});
    var first = true;
    for (kind.roles(), 0..) |role, r| if (columns[r] != null) {
        if (!first) try out.writeByte(',');
        try out.writeAll(role.key);
        first = false;
    };
    try out.writeByte('\n');
    for (0..block.rowCount()) |j| {
        // um ponto sem as colunas obrigatórias não entra
        var complete = true;
        for (kind.roles(), 0..) |role, r| if (role.required) if (columns[r]) |k| {
            if (std.math.isNan(block.numbers[k][j])) complete = false;
        };
        if (!complete) continue;
        first = true;
        for (kind.roles(), 0..) |_, r| if (columns[r]) |k| {
            if (!first) try out.writeByte(',');
            const value = block.numbers[k][j];
            if (!std.math.isNan(value)) try out.print("{d}", .{value});
            first = false;
        };
        try out.writeByte('\n');
    }
}

/// lê de volta uma combinação guardada em .csv
pub fn readCsv(memory: std.mem.Allocator, name: []const u8, text: []const u8) !Saved {
    var kind: Kind = .curve;
    var source: []const u8 = "";
    var area: []const u8 = "";
    var headers: []const []const u8 = &.{};
    var columns: std.ArrayList(std.ArrayList(f64)) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            const body = std.mem.trim(u8, line[1..], " ");
            if (std.mem.startsWith(u8, body, "tipo:")) kind = std.meta.stringToEnum(Kind, std.mem.trim(u8, body[5..], " ")) orelse .curve;
            if (std.mem.startsWith(u8, body, "fonte:")) source = try memory.dupe(u8, std.mem.trim(u8, body[6..], " "));
            if (std.mem.startsWith(u8, body, "área:")) area = try memory.dupe(u8, std.mem.trim(u8, body["área:".len..], " "));
            continue;
        }
        var cells = std.mem.splitScalar(u8, line, ',');
        if (headers.len == 0) {
            var names: std.ArrayList([]const u8) = .empty;
            while (cells.next()) |cell| {
                try names.append(memory, try memory.dupe(u8, std.mem.trim(u8, cell, " ")));
                try columns.append(memory, .empty);
            }
            headers = names.items;
            continue;
        }
        var k: usize = 0;
        while (cells.next()) |cell| : (k += 1) if (k < columns.items.len) {
            const value = std.fmt.parseFloat(f64, std.mem.trim(u8, cell, " ")) catch std.math.nan(f64);
            try columns.items[k].append(memory, value);
        };
    }
    const out = try memory.alloc([]const f64, columns.items.len);
    for (columns.items, out) |list, *column| column.* = list.items;
    return .{ .name = name, .kind = kind, .source = source, .area = area, .headers = headers, .columns = out };
}

/// as combinações guardadas, em ordem de nome
fn savedFiles(memory: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const path = try folder(memory);
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var walker = dir.iterate();
    while (walker.next(io) catch null) |item| {
        if (item.kind != .file or !std.ascii.endsWithIgnoreCase(item.name, ".csv")) continue;
        try out.append(memory, try std.fs.path.join(memory, &.{ path, item.name }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.items;
}

// ------------------------------------------------------------------ a planilha aberta

/// os tipos de bloco que cada área usa (o primeiro é o padrão); as outras áreas usam todos
pub fn kindsFor(area: []const u8) []const Kind {
    const table = [_]struct { []const u8, []const Kind }{
        .{ "Aerodinâmica", &.{ .polar, .distribution, .curve } },
        .{ "Estabilidade", &.{ .polar, .curve } },
        .{ "Desempenho", &.{ .curve, .motors } },
        .{ "Dimensionamento inicial", &.{.curve} },
        .{ "Cargas", &.{ .distribution, .curve } },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], area)) return entry[1];
    return &kinds;
}

/// a área que abriu a janela: o tipo passa a ser um dos dela (e vai no `# área:` do .csv)
pub fn setArea(area: []const u8) void {
    const length = @min(area.len, draft.area_buffer.len);
    @memcpy(draft.area_buffer[0..length], area[0..length]);
    draft.area_len = length;
    const allowed = kindsFor(area);
    if (std.mem.indexOfScalar(Kind, allowed, draft.kind) == null) setKind(allowed[0]);
}

/// abre a planilha do arquivo; devolve "" ou o problema, para a tela
pub fn open(io: std.Io, path: []const u8) ![]const u8 {
    const area = draft.area_buffer;
    const area_len = draft.area_len;
    const kind_before = draft.kind;
    if (draft.arena) |old| {
        old.deinit();
        std.heap.page_allocator.destroy(old);
    }
    const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(std.heap.page_allocator);
    draft = .{ .arena = arena, .area_buffer = area, .area_len = area_len, .kind = kind_before };
    const memory = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(64 << 20)) catch return "não deu para ler a planilha";
    draft.book = xlsx.Workbook.parse(memory, bytes) catch return "o arquivo não abriu como planilha .xlsx";
    draft.path = try memory.dupe(u8, path);
    detectRange();
    return "";
}

/// a planilha aberta, ou null
pub fn workbook() ?xlsx.Workbook {
    return draft.book;
}

/// o caminho da planilha aberta ("" sem planilha)
pub fn openedPath() []const u8 {
    return draft.path;
}

/// a aba mostrada (o índice em `workbook().sheets`)
pub fn sheetIndex() usize {
    return draft.sheet;
}

/// troca a aba e marca o primeiro bloco dela
pub fn selectSheet(index: usize) void {
    const book = draft.book orelse return;
    if (index >= book.sheets.len or index == draft.sheet) return;
    draft.sheet = index;
    detectRange();
}

/// o bloco marcado ("B6" ou "B6:R40"; "" sem bloco)
pub fn markedRange() []const u8 {
    return draft.range;
}

/// marca o bloco e sugere as colunas pelos títulos dele
pub fn setRange(text: []const u8) void {
    if (std.mem.eql(u8, text, draft.range)) return;
    draft.range = text_arena.allocator().dupe(u8, text) catch return;
    suggestColumns();
}

/// o tipo do bloco
pub fn markedKind() Kind {
    return draft.kind;
}

/// muda o tipo do bloco e sugere as colunas de novo
pub fn setKind(chosen: Kind) void {
    if (chosen == draft.kind) return;
    draft.kind = chosen;
    suggestColumns();
}

/// a coluna do bloco (índice em `Block.headers`) escolhida para o papel, ou null
pub fn roleColumn(role: usize) ?usize {
    return if (role < draft.columns.len) draft.columns[role] else null;
}

/// escolhe a coluna do bloco para o papel (null: nenhuma)
pub fn setColumn(role: usize, chosen: ?usize) void {
    if (role < draft.columns.len) draft.columns[role] = chosen;
}

/// o nome que a combinação vai ter
pub fn comboName() []const u8 {
    return draft.name;
}

/// muda o nome da combinação
pub fn setName(text: []const u8) void {
    if (std.mem.eql(u8, text, draft.name)) return;
    draft.name = text_arena.allocator().dupe(u8, text) catch return;
}

/// motores: a corrente máxima e a massa que valem quando a planilha não tem a coluna
pub fn motorDefaults() struct { imax: f64, mass: f64 } {
    return .{ .imax = draft.default_imax, .mass = draft.default_mass };
}

/// muda a corrente máxima e a massa dos motores sem coluna
pub fn setMotorDefaults(imax: f64, mass: f64) void {
    if (imax > 0) draft.default_imax = imax;
    if (mass > 0) draft.default_mass = mass;
}

/// o bloco marcado lido da aba, ou null (sem planilha, sem bloco ou endereço inválido)
pub fn markedBlock(memory: std.mem.Allocator) ?Block {
    const book = draft.book orelse return null;
    if (draft.sheet >= book.sheets.len or draft.range.len == 0) return null;
    return readBlock(memory, book.sheets[draft.sheet], draft.range) catch null;
}

/// o texto da célula como o Excel mostra: o número com as casas do formato dela (ou até 4, sem zeros à direita)
pub fn displayText(memory: std.mem.Allocator, value: ?xlsx.Value, style: xlsx.Style) ![]const u8 {
    const cell = value orelse return "";
    switch (cell) {
        .number => |raw| {
            const number = if (style.percent) raw * 100 else raw;
            const suffix: []const u8 = if (style.percent) "%" else "";
            if (style.decimals) |decimals| return std.fmt.allocPrint(memory, "{[value]d:.[precision]}{[suffix]s}", .{ .value = number, .precision = @min(decimals, 10), .suffix = suffix });
            if (number == @round(number) and @abs(number) < 1e15) return std.fmt.allocPrint(memory, "{d:.0}{s}", .{ number, suffix });
            const text = try std.fmt.allocPrint(memory, "{d:.4}", .{number});
            return std.fmt.allocPrint(memory, "{s}{s}", .{ std.mem.trimEnd(u8, std.mem.trimEnd(u8, text, "0"), "."), suffix });
        },
        else => return cellText(memory, cell),
    }
}

/// marca o primeiro bloco da aba escolhida (o usuário muda se não for esse) e sugere as colunas
fn detectRange() void {
    const book = draft.book orelse return;
    if (draft.sheet >= book.sheets.len) return;
    draft.range = (detectBlock(text_arena.allocator(), book.sheets[draft.sheet]) catch null) orelse "";
    suggestColumns();
}

fn suggestColumns() void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    draft.columns = if (markedBlock(scratch.allocator())) |marked| suggest(draft.kind, marked.headers) else @splat(null);
}

/// guarda o bloco marcado com o nome dado: um .csv na pasta, ou os motores na biblioteca de motores
pub fn keep(io: std.Io, memory: std.mem.Allocator) ![]const u8 {
    const marked = markedBlock(memory) orelse return "abra uma planilha e marque o bloco (arraste sobre as células, ou escreva B6 ou B6:R40)";
    for (draft.kind.roles(), 0..) |role, r| if (role.required and draft.columns[r] == null) return std.fmt.allocPrint(memory, "falta dizer qual coluna é {s}", .{role.label});
    const book = draft.book.?;
    const source = try std.fmt.allocPrint(memory, "{s}, aba {s}, {s}", .{ std.fs.path.basename(draft.path), book.sheets[draft.sheet].name, draft.range });
    if (draft.kind == .motors) return keepMotors(io, memory, marked, source);
    const chosen_name = std.mem.trim(u8, draft.name, " ");
    if (chosen_name.len == 0) return "dê um nome à combinação";
    var text: std.Io.Writer.Allocating = .init(memory);
    try writeCsv(&text.writer, draft.kind, source, draft.area_buffer[0..draft.area_len], marked, draft.columns);
    const directory = try folder(memory);
    std.Io.Dir.cwd().createDirPath(io, directory) catch return "não deu para criar a pasta da biblioteca";
    const file_name = try library.fileName(memory, chosen_name);
    const file = try std.fs.path.join(memory, &.{ directory, try std.fmt.allocPrint(memory, "{s}.csv", .{std.fs.path.stem(file_name)}) });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text.written() }) catch return "não deu para gravar na pasta da biblioteca";
    return std.fmt.allocPrint(memory, "guardado na biblioteca: {s} ({s})", .{ chosen_name, draft.kind.label() });
}

/// uma linha por motor: os que já existem com o mesmo nome ficam de fora
fn keepMotors(io: std.Io, memory: std.mem.Allocator, marked: Block, source: []const u8) ![]const u8 {
    var count: usize = 0;
    var skipped: usize = 0;
    for (0..marked.rowCount()) |j| {
        const motor_name = std.mem.trim(u8, marked.texts[draft.columns[0].?][j], " ");
        const kv = marked.numbers[draft.columns[1].?][j];
        const resistance = marked.numbers[draft.columns[2].?][j];
        if (motor_name.len == 0 or !(kv > 0) or !(resistance > 0)) {
            skipped += 1;
            continue;
        }
        const imax = if (draft.columns[3]) |k| marked.numbers[k][j] else draft.default_imax;
        const mass = if (draft.columns[4]) |k| marked.numbers[k][j] else draft.default_mass;
        // dois motores da planilha com o mesmo nome (o mesmo modelo em Kv diferentes): o Kv entra no nome
        const full_name = try std.fmt.allocPrint(memory, "{s} {d:.0}kv", .{ motor_name, kv });
        if (catalog.find(catalog.Motor, &catalog.motors, full_name) != null) {
            skipped += 1;
            continue;
        }
        const motor: catalog.Motor = .{
            .name = full_name,
            .Kv = kv,
            .Rm = resistance,
            .B = 0,
            .tauc = 0,
            .Imax = if (imax > 0) imax else draft.default_imax,
            .Jm = 0,
            .mass = if (mass > 0) mass else draft.default_mass,
            .source = source,
        };
        library.storeMotor(io, memory, motor) catch return "não deu para gravar na pasta da biblioteca";
        count += 1;
    }
    library.reload(io);
    return std.fmt.allocPrint(memory, "entraram {d} motores na biblioteca (Biblioteca → Motores); {d} linhas sem nome, Kv ou resistência ficaram de fora", .{ count, skipped });
}

/// uma combinação guardada e o arquivo dela
pub const Kept = struct { file: []const u8, saved: Saved };

/// as combinações guardadas na biblioteca, em ordem de nome
pub fn keptList(memory: std.mem.Allocator, io: std.Io) ![]const Kept {
    var out: std.ArrayList(Kept) = .empty;
    for (try savedFiles(memory, io)) |file| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, file, memory, .limited(16 << 20)) catch continue;
        const saved = readCsv(memory, std.fs.path.stem(file), text) catch continue;
        try out.append(memory, .{ .file = file, .saved = saved });
    }
    return out.items;
}

/// tira uma combinação da biblioteca
pub fn deleteKept(io: std.Io, file: []const u8) bool {
    std.Io.Dir.cwd().deleteFile(io, file) catch return false;
    return true;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "o nome da coluna pelo número, como no Excel" {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("A", columnName(&buffer, 1));
    try testing.expectEqualStrings("Z", columnName(&buffer, 26));
    try testing.expectEqualStrings("AA", columnName(&buffer, 27));
    try testing.expectEqualStrings("AZ", columnName(&buffer, 52));
}

/// uma aba de teste: títulos na linha 2 (B2:E2) e três linhas de números, com uma linha vazia depois
fn testSheet(memory: std.mem.Allocator) !xlsx.Sheet {
    var cells: std.ArrayList(xlsx.Cell) = .empty;
    try cells.append(memory, .{ .row = 1, .column = 1, .value = .{ .text = "Polares do avião" } });
    const titles = [_][]const u8{ "Alpha avião", "CLw", "CDiw", "CDw" };
    for (titles, 0..) |title, k| try cells.append(memory, .{ .row = 2, .column = 2 + @as(u32, @intCast(k)), .value = .{ .text = title } });
    for (0..3) |j| for (0..4) |k| {
        const value: f64 = if (k == 0) @as(f64, @floatFromInt(j)) * 2 - 2 else 0.1 * @as(f64, @floatFromInt(j + k));
        try cells.append(memory, .{ .row = 3 + @as(u32, @intCast(j)), .column = 2 + @as(u32, @intCast(k)), .value = .{ .number = value } });
    };
    try cells.append(memory, .{ .row = 8, .column = 2, .value = .{ .text = "outra coisa" } });
    return .{ .name = "Polares", .cells = cells.items };
}

test "o bloco pelo canto de cima vai até o último título e a última linha com número" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const sheet = try testSheet(memory);
    const block = try readBlock(memory, sheet, "B2");
    try testing.expectEqual(@as(usize, 4), block.headers.len);
    try testing.expectEqual(@as(usize, 3), block.rowCount());
    try testing.expectEqualStrings("CLw", block.headers[1]);
    try testing.expectEqual(@as(f64, 2), block.numbers[0][2]);
    // o intervalo inteiro, menor que o bloco
    const part = try readBlock(memory, sheet, "B2:C3");
    try testing.expectEqual(@as(usize, 2), part.headers.len);
    try testing.expectEqual(@as(usize, 1), part.rowCount());
    try testing.expectError(error.BadCell, readBlock(memory, sheet, "linha 2"));
}

test "o primeiro bloco da aba: dois títulos lado a lado com números embaixo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    try testing.expectEqualStrings("B2", (try detectBlock(memory, try testSheet(memory))).?);
}

test "as colunas sugeridas pelos títulos; a polar vira .csv e volta igual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const block = try readBlock(memory, try testSheet(memory), "B2");
    const columns = suggest(.polar, block.headers);
    try testing.expectEqual(@as(?usize, 0), columns[0]); // "Alpha avião"
    try testing.expectEqual(@as(?usize, 1), columns[1]); // "CLw"
    try testing.expectEqual(@as(?usize, 2), columns[2]); // "CDiw", o primeiro C_D
    try testing.expectEqual(@as(?usize, null), columns[3]); // sem C_m
    var text: std.Io.Writer.Allocating = .init(memory);
    try writeCsv(&text.writer, .polar, "teste.xlsx, aba Polares, B2", "Aerodinâmica", block, columns);
    try testing.expect(std.mem.startsWith(u8, text.written(), "# tipo: polar\n# fonte: teste.xlsx, aba Polares, B2\n# área: Aerodinâmica\nalpha,CL,CD\n-2,0.1,0.2\n"));
    const saved = try readCsv(memory, "Aura", text.written());
    try testing.expectEqual(Kind.polar, saved.kind);
    try testing.expectEqualStrings("Aerodinâmica", saved.area);
    try testing.expectEqual(@as(usize, 3), saved.columns.len);
    try testing.expectEqual(@as(f64, 2), saved.columns[0][2]);
    try testing.expectEqual(@as(f64, 0.4), saved.columns[2][2]);
}


test "o número aparece com as casas do formato da célula" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    try testing.expectEqualStrings("0.123", try displayText(memory, .{ .number = 0.12345 }, .{ .decimals = 3 }));
    try testing.expectEqualStrings("12.5%", try displayText(memory, .{ .number = 0.125 }, .{ .decimals = 1, .percent = true }));
    try testing.expectEqualStrings("4", try displayText(memory, .{ .number = 4 }, .{}));
    try testing.expectEqualStrings("0.1235", try displayText(memory, .{ .number = 0.123456 }, .{}));
    try testing.expectEqualStrings("Alpha", try displayText(memory, .{ .text = "Alpha" }, .{}));
}

test "cada área oferece os tipos dela" {
    try testing.expectEqual(Kind.polar, kindsFor("Aerodinâmica")[0]);
    try testing.expectEqual(@as(usize, 4), kindsFor("Biblioteca").len);
}

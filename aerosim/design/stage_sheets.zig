//! Biblioteca → Planilhas: trazer dados de uma planilha `.xlsx` qualquer (as das equipes) sem mapa de células. O
//! usuário abre a planilha, vê as abas e as células, marca um bloco (o canto de cima, ou o intervalo inteiro: a
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
const simulation = @import("simulation");
const catalog = @import("catalog");
const stages = @import("stages.zig");
const library = @import("stage_library.zig");

const xlsx = core.xlsx;

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
};
var draft: Draft = .{};
/// a memória dos textos do rascunho (nome, intervalo), trocada a cada pedido
var text_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var selected_kept: usize = 0;

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
    headers: []const []const u8,
    columns: []const []const f64,
};

/// a combinação em .csv: `# tipo:`, `# fonte:`, os títulos (as chaves dos papéis) e uma linha por ponto
pub fn writeCsv(out: *std.Io.Writer, kind: Kind, source: []const u8, block: Block, columns: [8]?usize) !void {
    try out.print("# tipo: {s}\n# fonte: {s}\n", .{ @tagName(kind), source });
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
    return .{ .name = name, .kind = kind, .source = source, .headers = headers, .columns = out };
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

// ------------------------------------------------------------------ os pedidos

fn open(io: std.Io, path: []const u8) ![]const u8 {
    if (draft.arena) |old| {
        old.deinit();
        std.heap.page_allocator.destroy(old);
    }
    const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(std.heap.page_allocator);
    draft = .{ .arena = arena };
    const memory = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(64 << 20)) catch return "não deu para ler a planilha";
    draft.book = xlsx.Workbook.parse(memory, bytes) catch return "o arquivo não abriu como planilha .xlsx";
    draft.path = try memory.dupe(u8, path);
    detectRange();
    return "";
}

/// marca o primeiro bloco da aba escolhida (o usuário muda se não for esse) e sugere as colunas
fn detectRange() void {
    const book = draft.book orelse return;
    if (draft.sheet >= book.sheets.len) return;
    const keep = text_arena.allocator();
    draft.range = (detectBlock(keep, book.sheets[draft.sheet]) catch null) orelse "";
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    if (currentBlock(scratch.allocator())) |block| draft.columns = suggest(draft.kind, block.headers);
}

fn choiceIndex(choices: []const []const u8, text: []const u8) ?usize {
    for (choices, 0..) |choice, k| if (std.mem.eql(u8, choice, text)) return k;
    return null;
}

fn textOf(values: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = values.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn numberOf(values: *const std.json.ObjectMap, key: []const u8, current: f64) f64 {
    const value = values.get(key) orelse return current;
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => current,
    };
}

fn currentBlock(memory: std.mem.Allocator) ?Block {
    const book = draft.book orelse return null;
    if (draft.sheet >= book.sheets.len or draft.range.len == 0) return null;
    return readBlock(memory, book.sheets[draft.sheet], draft.range) catch null;
}

/// muda o rascunho ou a lista conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    if (std.mem.eql(u8, request.do, "act") and std.mem.eql(u8, request.key, "planilha")) {
        const problem = try open(context.io, request.arg);
        if (problem.len > 0) return problem;
        return std.fmt.allocPrint(memory, "aberta: {s} ({d} abas). Escolha a aba e marque o bloco pelo canto de cima (a linha dos títulos)", .{ std.fs.path.basename(request.arg), draft.book.?.sheets.len });
    }
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        const keep = text_arena.allocator();
        const book = draft.book;
        var block_changed = false;
        if (book) |opened| if (textOf(values, "sheet")) |name| {
            for (opened.sheets, 0..) |sheet, k| if (std.mem.eql(u8, sheet.name, name) and k != draft.sheet) {
                draft.sheet = k;
                detectRange();
                return "";
            };
        };
        if (textOf(values, "range")) |range| if (!std.mem.eql(u8, range, draft.range)) {
            draft.range = try keep.dupe(u8, range);
            block_changed = true;
        };
        if (textOf(values, "kind")) |label| for (kinds) |kind| if (std.mem.eql(u8, kind.label(), label) and kind != draft.kind) {
            draft.kind = kind;
            block_changed = true;
        };
        if (textOf(values, "name")) |name| draft.name = try keep.dupe(u8, name);
        draft.default_imax = numberOf(values, "default_imax", draft.default_imax);
        draft.default_mass = numberOf(values, "default_mass", draft.default_mass);
        if (currentBlock(memory)) |block| {
            if (block_changed) {
                draft.columns = suggest(draft.kind, block.headers);
            } else for (draft.kind.roles(), 0..) |role, r| if (textOf(values, role.key)) |header| {
                draft.columns[r] = choiceIndex(block.headers, header);
            };
        }
        return "";
    }
    if (std.mem.eql(u8, request.do, "keep")) return keepDraft(context, memory);
    const files = try savedFiles(memory, context.io);
    if (std.mem.eql(u8, request.do, "load")) {
        if (stages.within(request.index, files.len)) |index| selected_kept = index;
        return "";
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        const index = stages.within(request.index, files.len) orelse return "";
        std.Io.Dir.cwd().deleteFile(context.io, files[index]) catch return "não deu para apagar o arquivo";
        selected_kept = 0;
        return std.fmt.allocPrint(memory, "saiu da biblioteca: {s}", .{std.fs.path.stem(files[index])});
    }
    return "";
}

/// guarda o bloco marcado com o nome dado: um .csv na pasta, ou os motores na biblioteca de motores
fn keepDraft(context: *stages.Context, memory: std.mem.Allocator) ![]const u8 {
    const block = currentBlock(memory) orelse return "abra uma planilha e marque o bloco (o canto de cima, como B6, ou o intervalo, como B6:R40)";
    for (draft.kind.roles(), 0..) |role, r| if (role.required and draft.columns[r] == null) return std.fmt.allocPrint(memory, "falta dizer qual coluna é {s}", .{role.label});
    const book = draft.book.?;
    const source = try std.fmt.allocPrint(memory, "{s}, aba {s}, {s}", .{ std.fs.path.basename(draft.path), book.sheets[draft.sheet].name, draft.range });
    if (draft.kind == .motors) return keepMotors(context, memory, block, source);
    const name = std.mem.trim(u8, draft.name, " ");
    if (name.len == 0) return "dê um nome à combinação";
    var text: std.Io.Writer.Allocating = .init(memory);
    try writeCsv(&text.writer, draft.kind, source, block, draft.columns);
    const path = try folder(memory);
    std.Io.Dir.cwd().createDirPath(context.io, path) catch return "não deu para criar a pasta da biblioteca";
    const file_name = try library.fileName(memory, name);
    const file = try std.fs.path.join(memory, &.{ path, try std.fmt.allocPrint(memory, "{s}.csv", .{std.fs.path.stem(file_name)}) });
    std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = file, .data = text.written() }) catch return "não deu para gravar na pasta da biblioteca";
    const files = try savedFiles(memory, context.io);
    for (files, 0..) |item, k| if (std.mem.eql(u8, item, file)) {
        selected_kept = k;
    };
    return std.fmt.allocPrint(memory, "guardado na biblioteca: {s} ({s})", .{ name, draft.kind.label() });
}

/// uma linha por motor: os que já existem com o mesmo nome ficam de fora
fn keepMotors(context: *stages.Context, memory: std.mem.Allocator, block: Block, source: []const u8) ![]const u8 {
    const column = struct {
        fn of(role: usize) ?usize {
            return draft.columns[role];
        }
    }.of;
    var count: usize = 0;
    var skipped: usize = 0;
    for (0..block.rowCount()) |j| {
        const name = std.mem.trim(u8, block.texts[column(0).?][j], " ");
        const kv = block.numbers[column(1).?][j];
        const resistance = block.numbers[column(2).?][j];
        if (name.len == 0 or !(kv > 0) or !(resistance > 0)) {
            skipped += 1;
            continue;
        }
        const imax = if (column(3)) |k| block.numbers[k][j] else draft.default_imax;
        const mass = if (column(4)) |k| block.numbers[k][j] else draft.default_mass;
        // dois motores da planilha com o mesmo nome (o mesmo modelo em Kv diferentes): o Kv entra no nome
        const full_name = try std.fmt.allocPrint(memory, "{s} {d:.0}kv", .{ name, kv });
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
        library.storeMotor(context.io, memory, motor) catch return "não deu para gravar na pasta da biblioteca";
        count += 1;
    }
    library.reload(context.io);
    return std.fmt.allocPrint(memory, "entraram {d} motores na biblioteca (Biblioteca → Motores); {d} linhas sem nome, Kv ou resistência ficaram de fora", .{ count, skipped });
}

// ------------------------------------------------------------------ a página

/// os dois gráficos: o bloco marcado e a combinação escolhida na lista, com o eixo x do primeiro papel de cada tipo
fn plotsFor(memory: std.mem.Allocator, block_kind: Kind, saved_kind: Kind) ![]const simulation.Plot {
    return memory.dupe(simulation.Plot, &.{
        .{ .key = "block", .title = "Bloco marcado", .xlabel = block_kind.roles()[0].label, .ylabel = "" },
        .{ .key = "saved", .title = "Combinação guardada", .xlabel = saved_kind.roles()[0].label, .ylabel = "" },
    });
}
const palette = [_][]const u8{ "#0d5fd9", "#eb6834", "#1baf7a", "#d62728" };

/// os gráficos de um tipo: o eixo x é o primeiro papel; as outras colunas são as curvas
fn drawColumns(figures: simulation.Figures, key: []const u8, kind: Kind, headers: []const []const u8, x: []const f64, ys: []const []const f64, names: []const []const u8) !void {
    _ = headers;
    if (kind == .motors) return;
    for (ys, names, 0..) |y, name, k| try figures.curve(key, .{ .name = name, .x = x, .y = y, .color = palette[k % palette.len] });
}

/// a página: os campos do bloco, a prévia das células, o gráfico do bloco e as combinações guardadas
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    var params: std.ArrayList(simulation.Param) = .empty;
    var tables: std.ArrayList(simulation.Table) = .empty;
    // o tipo da combinação escolhida na lista (para o eixo x do gráfico dela)
    const files = try savedFiles(memory, context.io);
    var saved_kind: Kind = .curve;
    if (selected_kept < files.len) if (std.Io.Dir.cwd().readFileAlloc(context.io, files[selected_kept], memory, .limited(16 << 20))) |text| {
        if (readCsv(memory, "", text)) |saved| saved_kind = saved.kind else |_| {}
    } else |_| {};
    const figures = try simulation.Figures.init(memory, try plotsFor(memory, draft.kind, saved_kind));
    var message: []const u8 = "abra uma planilha (.xlsx) com \"Abrir planilha…\"";
    if (draft.book) |book| {
        const sheet_names = try memory.alloc([]const u8, book.sheets.len);
        for (book.sheets, sheet_names) |sheet, *name| name.* = sheet.name;
        const sheet = book.sheets[@min(draft.sheet, book.sheets.len - 1)];
        const kind_names = try memory.alloc([]const u8, kinds.len);
        for (kinds, kind_names) |kind, *name| name.* = kind.label();
        try params.appendSlice(memory, &.{
            .{ .key = "sheet", .label = "aba", .kind = .choice, .default = .{ .text = sheet.name }, .choices = sheet_names, .group = "Bloco", .rebuild = true },
            .{ .key = "range", .label = "bloco", .kind = .str, .default = .{ .text = draft.range }, .group = "Bloco", .help = "o canto de cima do bloco (B6: a linha 6 tem os títulos; o bloco desce enquanto houver números) ou o intervalo inteiro (B6:R40)" },
            .{ .key = "kind", .label = "o bloco é", .kind = .choice, .default = .{ .text = draft.kind.label() }, .choices = kind_names, .group = "Bloco", .rebuild = true },
        });
        const block = currentBlock(memory);
        if (block) |marked| {
            const header_choices = try memory.alloc([]const u8, marked.headers.len + 1);
            header_choices[0] = none;
            @memcpy(header_choices[1..], marked.headers);
            for (draft.kind.roles(), 0..) |role, r| {
                const current = if (draft.columns[r]) |k| marked.headers[k] else none;
                try params.append(memory, .{ .key = role.key, .label = role.label, .kind = .choice, .default = .{ .text = current }, .choices = header_choices, .group = "Colunas", .help = if (role.required) "obrigatória" else "opcional" });
            }
            if (draft.kind == .motors) {
                try params.append(memory, .{ .key = "default_imax", .label = "corrente máx. sem coluna", .unit = "A", .default = .{ .number = draft.default_imax }, .minimum = 0.1, .maximum = 500, .group = "Colunas", .help = "vale para os motores sem a coluna (ou com ela vazia)" });
                try params.append(memory, .{ .key = "default_mass", .label = "massa sem coluna", .unit = "kg", .default = .{ .number = draft.default_mass }, .minimum = 0.001, .maximum = 20, .group = "Colunas", .help = "vale para os motores sem a coluna (ou com ela vazia)" });
            } else try params.append(memory, .{ .key = "name", .label = "nome da combinação", .kind = .str, .default = .{ .text = draft.name }, .group = "Guardar", .help = "o nome que você quiser: é assim que ela aparece nas outras abas" });
            // o gráfico do bloco, com as colunas escolhidas
            if (draft.kind != .motors) if (draft.columns[0]) |x_column| {
                var ys: std.ArrayList([]const f64) = .empty;
                var names: std.ArrayList([]const u8) = .empty;
                for (draft.kind.roles()[1..], 1..) |role, r| if (draft.columns[r]) |k| {
                    try ys.append(memory, marked.numbers[k]);
                    try names.append(memory, role.label);
                };
                try drawColumns(figures, "block", draft.kind, marked.headers, marked.numbers[x_column], ys.items, names.items);
            };
            message = try std.fmt.allocPrint(memory, "bloco {s}: {d} colunas, {d} linhas", .{ draft.range, marked.headers.len, marked.rowCount() });
        } else if (draft.range.len > 0) message = "o bloco não vale: escreva o canto de cima (B6) ou o intervalo (B6:R40)";
        // a prévia das células: um pouco antes do canto do bloco (ou do A1), 16 colunas e 25 linhas
        const first_row: u32 = if (block) |marked| marked.first_row -| 2 + 1 else 1;
        const first_column: u32 = if (block) |marked| marked.first_column -| 2 + 1 else 1;
        const width: u32 = 16;
        const headers = try memory.alloc([]const u8, width + 1);
        headers[0] = "";
        for (0..width) |k| {
            var letters: [4]u8 = undefined;
            headers[k + 1] = try memory.dupe(u8, columnName(&letters, first_column + @as(u32, @intCast(k))));
        }
        var rows: std.ArrayList([]const []const u8) = .empty;
        var row = first_row;
        while (row < first_row + 25 and row <= @max(sheet.lastRow(), first_row)) : (row += 1) {
            const cells = try memory.alloc([]const u8, width + 1);
            cells[0] = try std.fmt.allocPrint(memory, "{d}", .{row});
            for (0..width) |k| cells[k + 1] = try cellText(memory, sheet.at(row, first_column + @as(u32, @intCast(k))));
            try rows.append(memory, cells);
        }
        try tables.append(memory, .{ .title = try std.fmt.allocPrint(memory, "{s}: {s}", .{ std.fs.path.basename(draft.path), sheet.name }), .headers = headers, .rows = rows.items });
    }
    // as combinações guardadas
    var kept: std.ArrayList([]const u8) = .empty;
    var summary: std.ArrayList([2][]const u8) = .empty;
    for (files, 0..) |file, k| {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, file, memory, .limited(16 << 20)) catch continue;
        const saved = readCsv(memory, std.fs.path.stem(file), text) catch continue;
        try kept.append(memory, try std.fmt.allocPrint(memory, "{s}   ({s})", .{ saved.name, saved.kind.label() }));
        if (k != selected_kept or saved.columns.len < 2) continue;
        try summary.append(memory, .{ "combinação", saved.name });
        try summary.append(memory, .{ "tipo", saved.kind.label() });
        try summary.append(memory, .{ "pontos", try std.fmt.allocPrint(memory, "{d}", .{saved.columns[0].len}) });
        try summary.append(memory, .{ "fonte", saved.source });
        try drawColumns(figures, "saved", saved.kind, saved.headers, saved.columns[0], saved.columns[1..], saved.headers[1..]);
    }
    return .{
        .title = "Planilha",
        .help = "Traga dados de qualquer planilha .xlsx. Abra a planilha, escolha a aba e marque o bloco pelo canto de cima (a linha com os títulos das colunas); diga o que ele é (uma polar, a distribuição de sustentação, uma curva qualquer ou uma lista de motores) e qual coluna é qual, e guarde com o nome que quiser. As combinações valem para todos os projetos; os motores vão para Biblioteca → Motores.",
        .keep_label = if (draft.kind == .motors) "Guardar os motores" else "Guardar a combinação",
        .kept_title = "Combinações",
        .params = params.items,
        .kept = kept.items,
        .actions = &actions,
        .tables = tables.items,
        .summary = summary.items,
        .figures = figures,
        .message = message,
    };
}

const actions = [_]simulation.StageAction{
    .{ .key = "planilha", .label = "Abrir planilha…", .arg = "file", .help = "uma planilha .xlsx" },
};

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
    try writeCsv(&text.writer, .polar, "teste.xlsx, aba Polares, B2", block, columns);
    try testing.expect(std.mem.startsWith(u8, text.written(), "# tipo: polar\n# fonte: teste.xlsx, aba Polares, B2\nalpha,CL,CD\n-2,0.1,0.2\n"));
    const saved = try readCsv(memory, "Aura", text.written());
    try testing.expectEqual(Kind.polar, saved.kind);
    try testing.expectEqual(@as(usize, 3), saved.columns.len);
    try testing.expectEqual(@as(f64, 2), saved.columns[0][2]);
    try testing.expectEqual(@as(f64, 0.4), saved.columns[2][2]);
}


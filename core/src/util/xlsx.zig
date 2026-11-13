//! Leitor de planilhas `.xlsx` sem dependência de fora: o arquivo é um `.zip` (APPNOTE da PKWARE) com uma folha de
//! XML por aba (Office Open XML, ECMA-376 parte 1, seção 18.3 "Worksheets" e 18.4 "Shared String Table"). Aqui se
//! abre o zip na memória, se descomprime cada parte com o deflate do `std.compress.flate` e se lê só o que uma
//! planilha de dados precisa: o nome das abas, o endereço de cada célula e o valor (número, texto ou booleano). A
//! fórmula não é recalculada; vale o último valor que o Excel gravou na célula (`<v>`), como o `data_only=True` do
//! openpyxl. Exemplo:
//!
//!     var book = try xlsx.Workbook.parse(arena, bytes);
//!     const massa = book.cell("Geral", "C8");          // ?xlsx.Value
//!     for (book.sheet("geral").?.cells) |celula| ...    // em ordem de linha e coluna
//!
//! Toda a memória vem do `allocator` de quem chama (uma arena); `parse` não guarda nada fora dela.
const std = @import("std");

pub const Error = error{ NotZip, MissingPart, BadXml, UnsupportedCompression, BadCell };

/// o valor de uma célula, como o Excel o guarda
pub const Value = union(enum) {
    number: f64,
    text: []const u8,
    boolean: bool,

    /// o número da célula, se ela tem um (um texto com número também serve)
    pub fn asNumber(value: Value) ?f64 {
        return switch (value) {
            .number => |number| number,
            .boolean => |flag| if (flag) 1 else 0,
            .text => |text| std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch null,
        };
    }
};

/// uma célula com valor: linha e coluna contadas de 1, como no Excel (A1 = linha 1, coluna 1)
pub const Cell = struct {
    row: u32,
    column: u32,
    value: Value,
};

/// uma aba: o nome e as células com valor, em ordem de linha e depois de coluna
pub const Sheet = struct {
    name: []const u8,
    cells: []const Cell,

    /// a célula na linha e coluna dadas (contadas de 1), ou null se está vazia
    pub fn at(sheet: Sheet, row: u32, column: u32) ?Value {
        var low: usize = 0;
        var high: usize = sheet.cells.len;
        while (low < high) {
            const middle = (low + high) / 2;
            const cell = sheet.cells[middle];
            if (cell.row == row and cell.column == column) return cell.value;
            if (cell.row < row or (cell.row == row and cell.column < column)) low = middle + 1 else high = middle;
        }
        return null;
    }

    /// a célula pelo endereço ("C4"), ou null se está vazia ou o endereço não vale
    pub fn byAddress(sheet: Sheet, address: []const u8) ?Value {
        const place = parseAddress(address) catch return null;
        return sheet.at(place.row, place.column);
    }

    /// a última linha com alguma célula preenchida (0 na aba vazia)
    pub fn lastRow(sheet: Sheet) u32 {
        return if (sheet.cells.len == 0) 0 else sheet.cells[sheet.cells.len - 1].row;
    }
};

/// a planilha inteira, na ordem das abas do arquivo
pub const Workbook = struct {
    sheets: []const Sheet,

    /// lê o `.xlsx` em `bytes`; as abas e os textos ficam no `allocator`
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Workbook {
        const archive = try Archive.open(allocator, bytes);
        const shared = if (archive.find("xl/sharedStrings.xml")) |entry| try readSharedStrings(allocator, try archive.extract(allocator, entry)) else &[_][]const u8{};
        const workbook_xml = try archive.extract(allocator, archive.find("xl/workbook.xml") orelse return Error.MissingPart);
        const relations_xml = if (archive.find("xl/_rels/workbook.xml.rels")) |entry| try archive.extract(allocator, entry) else "";

        var sheets: std.ArrayList(Sheet) = .empty;
        var tags = Tags{ .xml = workbook_xml };
        var index: usize = 0;
        while (tags.next("sheet")) |tag| : (index += 1) {
            const name = try unescape(allocator, attribute(tag, "name") orelse return Error.BadXml);
            const part = try sheetPart(allocator, relations_xml, attribute(tag, "r:id"), index);
            const entry = archive.find(part) orelse return Error.MissingPart;
            const cells = try readCells(allocator, try archive.extract(allocator, entry), shared);
            try sheets.append(allocator, .{ .name = name, .cells = cells });
        }
        return .{ .sheets = try sheets.toOwnedSlice(allocator) };
    }

    /// a aba com este nome, ou null
    pub fn sheet(book: Workbook, name: []const u8) ?Sheet {
        for (book.sheets) |item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }

    /// a célula pelo nome da aba e o endereço ("Geral", "C8"), ou null
    pub fn cell(book: Workbook, sheet_name: []const u8, address: []const u8) ?Value {
        const found = book.sheet(sheet_name) orelse return null;
        return found.byAddress(address);
    }

    /// a célula pela referência completa do Excel ("Geral!C8"), ou null
    pub fn reference(book: Workbook, full: []const u8) ?Value {
        const bang = std.mem.lastIndexOfScalar(u8, full, '!') orelse return null;
        return book.cell(full[0..bang], full[bang + 1 ..]);
    }
};

/// linha e coluna (de 1) de um endereço "C4"; aceita "$C$4"
pub fn parseAddress(address: []const u8) Error!struct { row: u32, column: u32 } {
    var column: u32 = 0;
    var row: u32 = 0;
    var digits = false;
    for (address) |char| switch (char) {
        '$' => {},
        'A'...'Z', 'a'...'z' => {
            if (digits) return Error.BadCell;
            column = column * 26 + (std.ascii.toUpper(char) - 'A' + 1);
        },
        '0'...'9' => {
            digits = true;
            row = row * 10 + (char - '0');
        },
        else => return Error.BadCell,
    };
    if (column == 0 or row == 0) return Error.BadCell;
    return .{ .row = row, .column = column };
}

// ------------------------------------------------------------------ o zip

/// o diretório central do zip, lido direto dos bytes (APPNOTE 4.3.12 e 4.3.16)
const Archive = struct {
    bytes: []const u8,
    entries: []const Entry,

    const Entry = struct { name: []const u8, method: u16, compressed: u32, size: u32, local_offset: u32 };

    fn open(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
        if (bytes.len < 22) return Error.NotZip;
        // o registro do fim fica nos últimos 22 + até 65535 bytes (o comentário do zip)
        var position: usize = bytes.len - 22;
        const lowest = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
        while (!std.mem.eql(u8, bytes[position..][0..4], "PK\x05\x06")) {
            if (position == lowest) return Error.NotZip;
            position -= 1;
        }
        const count = readInt(u16, bytes, position + 10);
        var cursor: usize = readInt(u32, bytes, position + 16);
        const entries = try allocator.alloc(Entry, count);
        for (entries) |*entry| {
            if (cursor + 46 > bytes.len or !std.mem.eql(u8, bytes[cursor..][0..4], "PK\x01\x02")) return Error.NotZip;
            const name_length = readInt(u16, bytes, cursor + 28);
            const extra_length = readInt(u16, bytes, cursor + 30);
            const comment_length = readInt(u16, bytes, cursor + 32);
            if (cursor + 46 + name_length > bytes.len) return Error.NotZip;
            entry.* = .{
                .method = readInt(u16, bytes, cursor + 10),
                .compressed = readInt(u32, bytes, cursor + 20),
                .size = readInt(u32, bytes, cursor + 24),
                .local_offset = readInt(u32, bytes, cursor + 42),
                .name = bytes[cursor + 46 ..][0..name_length],
            };
            cursor += 46 + name_length + extra_length + comment_length;
        }
        return .{ .bytes = bytes, .entries = entries };
    }

    fn find(archive: Archive, name: []const u8) ?Entry {
        for (archive.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        return null;
    }

    /// o conteúdo de uma parte: guardada (0) ou comprimida com deflate (8)
    fn extract(archive: Archive, allocator: std.mem.Allocator, entry: Entry) ![]const u8 {
        const local = entry.local_offset;
        if (local + 30 > archive.bytes.len or !std.mem.eql(u8, archive.bytes[local..][0..4], "PK\x03\x04")) return Error.NotZip;
        const start = local + 30 + readInt(u16, archive.bytes, local + 26) + readInt(u16, archive.bytes, local + 28);
        if (start + entry.compressed > archive.bytes.len) return Error.NotZip;
        const data = archive.bytes[start..][0..entry.compressed];
        switch (entry.method) {
            0 => return data,
            8 => {
                const out = try allocator.alloc(u8, entry.size);
                var input: std.Io.Reader = .fixed(data);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var inflate: std.compress.flate.Decompress = .init(&input, .raw, &window);
                inflate.reader.readSliceAll(out) catch return Error.NotZip;
                return out;
            },
            else => return Error.UnsupportedCompression,
        }
    }
};

fn readInt(comptime Int: type, bytes: []const u8, at: usize) Int {
    return std.mem.readInt(Int, bytes[at..][0..@sizeOf(Int)], .little);
}

// ------------------------------------------------------------------ o XML

/// percorre as marcas `<nome ...>` de um texto XML, sem montar árvore
const Tags = struct {
    xml: []const u8,
    position: usize = 0,

    /// a próxima marca de abertura com este nome: devolve o texto de dentro dos `< >` (com os atributos)
    fn next(tags: *Tags, name: []const u8) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, tags.xml, tags.position, '<')) |open| {
            const close = std.mem.indexOfScalarPos(u8, tags.xml, open, '>') orelse return null;
            tags.position = close + 1;
            const inside = tags.xml[open + 1 .. close];
            if (!std.mem.startsWith(u8, inside, name)) continue;
            if (inside.len == name.len or isSpace(inside[name.len]) or inside[name.len] == '/') return inside;
        }
        return null;
    }

    /// o texto até o fechamento `</nome>` a partir da posição atual (o corpo da última marca achada)
    fn body(tags: *Tags, name: []const u8) []const u8 {
        var closing: [16]u8 = undefined;
        const end_tag = std.fmt.bufPrint(&closing, "</{s}>", .{name}) catch return "";
        const end = std.mem.indexOfPos(u8, tags.xml, tags.position, end_tag) orelse return "";
        const inside = tags.xml[tags.position..end];
        tags.position = end + end_tag.len;
        return inside;
    }
};

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

/// o valor de um atributo dentro da marca (`name="..."`)
fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, tag, position, name)) |at| {
        position = at + name.len;
        if (at > 0 and !isSpace(tag[at - 1])) continue;
        if (position + 1 >= tag.len or tag[position] != '=') continue;
        const quote = tag[position + 1];
        if (quote != '"' and quote != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, tag, position + 2, quote) orelse return null;
        return tag[position + 2 .. end];
    }
    return null;
}

/// troca as entidades do XML (&amp; &lt; &gt; &quot; &apos; &#n; &#xh;) pelo caractere
fn unescape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var position: usize = 0;
    while (position < text.len) {
        const char = text[position];
        if (char != '&') {
            try out.append(allocator, char);
            position += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, position, ';') orelse {
            try out.appendSlice(allocator, text[position..]);
            break;
        };
        const entity = text[position + 1 .. end];
        const named = [_]struct { []const u8, u8 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' } };
        const replaced = for (named) |pair| {
            if (std.mem.eql(u8, entity, pair[0])) break pair[1];
        } else null;
        if (replaced) |single| {
            try out.append(allocator, single);
        } else if (entity.len > 1 and entity[0] == '#') {
            const code = if (entity[1] == 'x') std.fmt.parseInt(u21, entity[2..], 16) else std.fmt.parseInt(u21, entity[1..], 10);
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(code catch '?', &encoded) catch 0;
            try out.appendSlice(allocator, encoded[0..length]);
        } else {
            try out.appendSlice(allocator, text[position .. end + 1]);
        }
        position = end + 1;
    }
    return out.items;
}

/// o texto de um `<si>` ou `<is>`: junta todos os `<t>` (os trechos com formatação, `<r>`, vêm em pedaços)
fn joinTexts(allocator: std.mem.Allocator, xml: []const u8) ![]const u8 {
    var tags = Tags{ .xml = xml };
    var out: std.ArrayList(u8) = .empty;
    var pieces: usize = 0;
    var single: []const u8 = "";
    while (tags.next("t")) |tag| {
        if (tag[tag.len - 1] == '/') continue;
        const piece = tags.body("t");
        if (pieces == 0) single = piece;
        if (pieces == 1) try out.appendSlice(allocator, single);
        if (pieces >= 1) try out.appendSlice(allocator, piece);
        pieces += 1;
    }
    return unescape(allocator, if (pieces <= 1) single else out.items);
}

fn readSharedStrings(allocator: std.mem.Allocator, xml: []const u8) ![]const []const u8 {
    var tags = Tags{ .xml = xml };
    var strings: std.ArrayList([]const u8) = .empty;
    while (tags.next("si")) |tag| {
        if (tag[tag.len - 1] == '/') {
            try strings.append(allocator, "");
            continue;
        }
        try strings.append(allocator, try joinTexts(allocator, tags.body("si")));
    }
    return strings.items;
}

/// o caminho da folha da aba no zip: pela relação `r:id` do workbook; sem ela, `sheetN.xml` pela ordem
fn sheetPart(allocator: std.mem.Allocator, relations: []const u8, relation_id: ?[]const u8, index: usize) ![]const u8 {
    if (relation_id) |wanted| {
        var tags = Tags{ .xml = relations };
        while (tags.next("Relationship")) |tag| {
            const id = attribute(tag, "Id") orelse continue;
            if (!std.mem.eql(u8, id, wanted)) continue;
            const target = attribute(tag, "Target") orelse break;
            if (target.len > 0 and target[0] == '/') return target[1..];
            return std.fmt.allocPrint(allocator, "xl/{s}", .{target});
        }
    }
    return std.fmt.allocPrint(allocator, "xl/worksheets/sheet{d}.xml", .{index + 1});
}

fn readCells(allocator: std.mem.Allocator, xml: []const u8, shared: []const []const u8) ![]const Cell {
    var tags = Tags{ .xml = xml };
    var cells: std.ArrayList(Cell) = .empty;
    var row: u32 = 0;
    var column: u32 = 0;
    while (true) {
        // a próxima marca: <row> (para a linha sem endereço nas células) ou <c>
        const open = std.mem.indexOfScalarPos(u8, xml, tags.position, '<') orelse break;
        const is_row = std.mem.startsWith(u8, xml[open + 1 ..], "row") and (isSpace(xml[open + 4]) or xml[open + 4] == '>');
        const is_cell = xml[open + 1] == 'c' and (isSpace(xml[open + 2]) or xml[open + 2] == '>' or xml[open + 2] == '/');
        const close = std.mem.indexOfScalarPos(u8, xml, open, '>') orelse break;
        tags.position = close + 1;
        const tag = xml[open + 1 .. close];
        if (is_row) {
            row = if (attribute(tag, "r")) |text| std.fmt.parseInt(u32, text, 10) catch row + 1 else row + 1;
            column = 0;
            continue;
        }
        if (!is_cell) continue;
        if (attribute(tag, "r")) |address| {
            const place = try parseAddress(address);
            row = place.row;
            column = place.column;
        } else column += 1;
        if (tag[tag.len - 1] == '/') continue; // célula só com estilo
        const inside = tags.body("c");
        const kind = attribute(tag, "t") orelse "n";
        var inner = Tags{ .xml = inside };
        const raw = if (inner.next("v")) |_| inner.body("v") else "";
        const value: ?Value = if (std.mem.eql(u8, kind, "s")) blk: {
            const index = std.fmt.parseInt(usize, raw, 10) catch return Error.BadXml;
            if (index >= shared.len) return Error.BadXml;
            break :blk .{ .text = shared[index] };
        } else if (std.mem.eql(u8, kind, "inlineStr"))
            .{ .text = try joinTexts(allocator, inside) }
        else if (std.mem.eql(u8, kind, "str"))
            .{ .text = try unescape(allocator, raw) }
        else if (std.mem.eql(u8, kind, "b"))
            .{ .boolean = std.mem.eql(u8, raw, "1") }
        else if (std.mem.eql(u8, kind, "e") or raw.len == 0)
            null
        else
            .{ .number = std.fmt.parseFloat(f64, raw) catch return Error.BadXml };
        if (value) |found| try cells.append(allocator, .{ .row = row, .column = column, .value = found });
    }
    std.mem.sort(Cell, cells.items, {}, struct {
        fn before(_: void, left: Cell, right: Cell) bool {
            return left.row < right.row or (left.row == right.row and left.column < right.column);
        }
    }.before);
    return cells.items;
}

// ------------------------------------------------------------------ testes

test "endereço de célula" {
    const place = try parseAddress("$AB$12");
    try std.testing.expectEqual(@as(u32, 12), place.row);
    try std.testing.expectEqual(@as(u32, 28), place.column);
    try std.testing.expectError(Error.BadCell, parseAddress("12A"));
}

test "entidades do XML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a<b & \"c\" é", try unescape(arena.allocator(), "a&lt;b &amp; &quot;c&quot; &#233;"));
}

test "arquivo que não é zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.NotZip, Workbook.parse(arena.allocator(), "isto não é uma planilha, só texto qualquer"));
}

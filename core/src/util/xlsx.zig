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
//! Para mostrar a aba como o Excel mostra, `parse` também lê a aparência (ECMA-376 parte 1, 18.8 "Styles" e 20.1.6
//! "Theme"): a cor de fundo e da letra de cada célula (inclusive as vazias só pintadas), o negrito, o alinhamento, as
//! bordas, as casas decimais do formato, a largura das colunas, a altura das linhas e as células mescladas
//! (`Sheet.styleAt`, `columnWidth`, `rowHeight`, `mergeAt`). As cores do tema e o `tint` já saem resolvidos em RGB.
//!
//! Toda a memória vem do `allocator` de quem chama (uma arena); `parse` não guarda nada fora dela.
const std = @import("std");
const zip = @import("zip.zig");

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

/// alinhamento horizontal da célula; `general` é o do Excel: número à direita, texto à esquerda
pub const Alignment = enum { general, left, center, right };

/// os lados da célula com borda
pub const Borders = packed struct(u4) {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,
};

/// a aparência de uma célula, com as cores já em RGB (0xRRGGBB)
pub const Style = struct {
    fill: ?u32 = null,
    font_color: u32 = 0x000000,
    bold: bool = false,
    italic: bool = false,
    /// tamanho da letra, em pontos
    size: f32 = 11,
    alignment: Alignment = .general,
    borders: Borders = .{},
    /// casas decimais do formato do número (null = "Geral")
    decimals: ?u8 = null,
    percent: bool = false,
};

/// a célula com estilo (com ou sem valor): o índice em `Sheet.styles`
pub const Styled = struct {
    row: u32,
    column: u32,
    style: u16,
};

/// um retângulo de células, de 1 como no Excel ("AF2:BH5")
pub const Range = struct {
    first_row: u32,
    first_column: u32,
    last_row: u32,
    last_column: u32,

    /// se a célula está dentro do retângulo
    pub fn contains(range: Range, row: u32, column: u32) bool {
        return row >= range.first_row and row <= range.last_row and column >= range.first_column and column <= range.last_column;
    }
};

/// largura de um grupo de colunas, na unidade do Excel (caracteres da fonte padrão)
pub const ColumnWidth = struct {
    first: u32,
    last: u32,
    width: f32,
};

/// altura de uma linha, em pontos
pub const RowHeight = struct {
    row: u32,
    height: f32,
};

/// uma aba: o nome e as células com valor, em ordem de linha e depois de coluna, mais a aparência
pub const Sheet = struct {
    name: []const u8,
    cells: []const Cell,
    /// as células com estilo, em ordem de linha e coluna; o índice aponta para `styles`
    styled: []const Styled = &.{},
    /// a tabela de estilos do arquivo (a mesma em todas as abas)
    styles: []const Style = &.{},
    widths: []const ColumnWidth = &.{},
    heights: []const RowHeight = &.{},
    merges: []const Range = &.{},
    default_width: f32 = 8.43,
    default_height: f32 = 15,

    /// a aparência da célula (a padrão do arquivo quando ela não tem estilo próprio)
    pub fn styleAt(sheet: Sheet, row: u32, column: u32) Style {
        var low: usize = 0;
        var high: usize = sheet.styled.len;
        while (low < high) {
            const middle = (low + high) / 2;
            const item = sheet.styled[middle];
            if (item.row == row and item.column == column) return if (item.style < sheet.styles.len) sheet.styles[item.style] else .{};
            if (item.row < row or (item.row == row and item.column < column)) low = middle + 1 else high = middle;
        }
        return if (sheet.styles.len > 0) sheet.styles[0] else .{};
    }

    /// largura da coluna, na unidade do Excel (caracteres); `pixels` converte
    pub fn columnWidth(sheet: Sheet, column: u32) f32 {
        for (sheet.widths) |item| if (column >= item.first and column <= item.last) return item.width;
        return sheet.default_width;
    }

    /// altura da linha, em pontos
    pub fn rowHeight(sheet: Sheet, row: u32) f32 {
        for (sheet.heights) |item| if (item.row == row) return item.height;
        return sheet.default_height;
    }

    /// o grupo mesclado que contém a célula, ou null
    pub fn mergeAt(sheet: Sheet, row: u32, column: u32) ?Range {
        for (sheet.merges) |range| if (range.contains(row, column)) return range;
        return null;
    }

    /// a última coluna com valor ou estilo (0 na aba vazia)
    pub fn lastColumn(sheet: Sheet) u32 {
        var last: u32 = 0;
        for (sheet.cells) |item| last = @max(last, item.column);
        for (sheet.styled) |item| last = @max(last, item.column);
        return last;
    }

    /// a última linha com valor ou estilo
    pub fn lastStyledRow(sheet: Sheet) u32 {
        const styled_last: u32 = if (sheet.styled.len == 0) 0 else sheet.styled[sheet.styled.len - 1].row;
        return @max(sheet.lastRow(), styled_last);
    }

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
        const archive = zip.Archive.open(allocator, bytes) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else Error.NotZip;
        const shared = if (archive.find("xl/sharedStrings.xml")) |entry| try readSharedStrings(allocator, try archive.extract(allocator, entry)) else &[_][]const u8{};
        const workbook_xml = try archive.extract(allocator, archive.find("xl/workbook.xml") orelse return Error.MissingPart);
        const relations_xml = if (archive.find("xl/_rels/workbook.xml.rels")) |entry| try archive.extract(allocator, entry) else "";
        const theme = if (archive.find("xl/theme/theme1.xml")) |entry| readTheme(try archive.extract(allocator, entry)) else default_theme;
        const styles = if (archive.find("xl/styles.xml")) |entry| try readStyles(allocator, try archive.extract(allocator, entry), theme) else &[_]Style{};

        var sheets: std.ArrayList(Sheet) = .empty;
        var tags = Tags{ .xml = workbook_xml };
        var index: usize = 0;
        while (tags.next("sheet")) |tag| : (index += 1) {
            const name = try unescape(allocator, attribute(tag, "name") orelse return Error.BadXml);
            const part = try sheetPart(allocator, relations_xml, attribute(tag, "r:id"), index);
            const entry = archive.find(part) orelse return Error.MissingPart;
            var read = try readSheet(allocator, try archive.extract(allocator, entry), shared);
            read.name = name;
            read.styles = styles;
            try sheets.append(allocator, read);
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

    /// a próxima marca de abertura de qualquer nome (pula os fechamentos `</...>`)
    fn any(tags: *Tags) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, tags.xml, tags.position, '<')) |open| {
            const close = std.mem.indexOfScalarPos(u8, tags.xml, open, '>') orelse return null;
            tags.position = close + 1;
            const inside = tags.xml[open + 1 .. close];
            if (inside.len > 0 and inside[0] != '/' and inside[0] != '?') return inside;
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

/// lê uma folha: as células com valor, as com estilo, larguras, alturas e mesclas (o nome e os estilos vêm de fora)
fn readSheet(allocator: std.mem.Allocator, xml: []const u8, shared: []const []const u8) !Sheet {
    var tags = Tags{ .xml = xml };
    var cells: std.ArrayList(Cell) = .empty;
    var styled: std.ArrayList(Styled) = .empty;
    var heights: std.ArrayList(RowHeight) = .empty;
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
            if (attribute(tag, "ht")) |text| if (std.fmt.parseFloat(f32, text)) |height| try heights.append(allocator, .{ .row = row, .height = height }) else |_| {};
            continue;
        }
        if (!is_cell) continue;
        if (attribute(tag, "r")) |address| {
            const place = try parseAddress(address);
            row = place.row;
            column = place.column;
        } else column += 1;
        if (attribute(tag, "s")) |text| {
            const style = std.fmt.parseInt(u16, text, 10) catch 0;
            if (style != 0) try styled.append(allocator, .{ .row = row, .column = column, .style = style });
        }
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
    std.mem.sort(Styled, styled.items, {}, struct {
        fn before(_: void, left: Styled, right: Styled) bool {
            return left.row < right.row or (left.row == right.row and left.column < right.column);
        }
    }.before);

    var sheet = Sheet{ .name = "", .cells = cells.items, .styled = styled.items, .heights = heights.items };
    var format = Tags{ .xml = xml };
    if (format.next("sheetFormatPr")) |tag| {
        if (attribute(tag, "defaultColWidth")) |text| sheet.default_width = std.fmt.parseFloat(f32, text) catch sheet.default_width;
        if (attribute(tag, "defaultRowHeight")) |text| sheet.default_height = std.fmt.parseFloat(f32, text) catch sheet.default_height;
    }
    var widths: std.ArrayList(ColumnWidth) = .empty;
    var columns = Tags{ .xml = xml };
    while (columns.next("col")) |tag| {
        const first = std.fmt.parseInt(u32, attribute(tag, "min") orelse continue, 10) catch continue;
        const last = std.fmt.parseInt(u32, attribute(tag, "max") orelse continue, 10) catch continue;
        const width = std.fmt.parseFloat(f32, attribute(tag, "width") orelse continue) catch continue;
        try widths.append(allocator, .{ .first = first, .last = last, .width = if (attribute(tag, "hidden")) |hidden| (if (std.mem.eql(u8, hidden, "1")) 0 else width) else width });
    }
    sheet.widths = widths.items;
    var merges: std.ArrayList(Range) = .empty;
    var merged = Tags{ .xml = xml };
    while (merged.next("mergeCell")) |tag| {
        if (tag.len >= "mergeCells".len and std.mem.startsWith(u8, tag, "mergeCells")) continue;
        try merges.append(allocator, parseRange(attribute(tag, "ref") orelse continue) catch continue);
    }
    sheet.merges = merges.items;
    return sheet;
}

/// o retângulo de um endereço "B6:R40" (ou uma célula só, "B6")
pub fn parseRange(text: []const u8) Error!Range {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const first = try parseAddress(if (colon) |at| text[0..at] else text);
    const last = if (colon) |at| try parseAddress(text[at + 1 ..]) else first;
    return .{
        .first_row = @min(first.row, last.row),
        .first_column = @min(first.column, last.column),
        .last_row = @max(first.row, last.row),
        .last_column = @max(first.column, last.column),
    };
}

/// pixels da largura de coluna do Excel com a letra padrão (Calibri 11: 7 px por caractere e 5 px de margem;
/// ECMA-376 parte 1, 18.3.1.13 "col", atributo width; a conferir no PDF)
pub fn pixels(width: f32) f32 {
    if (width <= 0) return 0;
    return @floor(width * 7 + 5);
}

// ------------------------------------------------------------------ a aparência (styles.xml e theme1.xml)

/// as 12 cores do tema na ordem do índice `theme=` das células: lt1, dk1, lt2, dk2, accent1..6, hlink, folHlink
/// (o arquivo grava dk1 antes de lt1, mas o índice 0 é o claro; ECMA-376 parte 1, 20.1.6.2 "clrScheme")
const Theme = [12]u32;

/// o tema do Office quando o arquivo não traz um
const default_theme: Theme = .{ 0xFFFFFF, 0x000000, 0xE7E6E6, 0x44546A, 0x4472C4, 0xED7D31, 0xA5A5A5, 0xFFC000, 0x5B9BD5, 0x70AD47, 0x0563C1, 0x954F72 };

/// a paleta antiga das cores `indexed=` (ECMA-376 parte 1, 18.8.27 "indexedColors"; a conferir no PDF);
/// 64 é a cor do texto do sistema (preto) e 65 a do fundo (branco)
const indexed_colors = [_]u32{
    0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
    0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
    0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
    0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
    0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
    0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
    0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
    0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    0x000000, 0xFFFFFF,
};

fn readTheme(xml: []const u8) Theme {
    var theme = default_theme;
    const names = [_][]const u8{ "a:lt1", "a:dk1", "a:lt2", "a:dk2", "a:accent1", "a:accent2", "a:accent3", "a:accent4", "a:accent5", "a:accent6", "a:hlink", "a:folHlink" };
    for (names, 0..) |name, index| {
        var tags = Tags{ .xml = xml };
        if (tags.next(name) == null) continue;
        const inside = tags.body(name);
        var color = Tags{ .xml = inside };
        if (color.next("a:srgbClr")) |tag| {
            if (hex(attribute(tag, "val"))) |rgb| theme[index] = rgb;
            continue;
        }
        color = .{ .xml = inside };
        if (color.next("a:sysClr")) |tag| if (hex(attribute(tag, "lastClr"))) |rgb| {
            theme[index] = rgb;
        };
    }
    return theme;
}

/// "FFFFF2CC" (ARGB) ou "FFF2CC" em 0xRRGGBB
fn hex(text: ?[]const u8) ?u32 {
    const digits = text orelse return null;
    const rgb = if (digits.len == 8) digits[2..] else digits;
    if (rgb.len != 6) return null;
    return std.fmt.parseInt(u32, rgb, 16) catch null;
}

/// a cor de uma marca `<color>`/`<fgColor>` (rgb, theme ou indexed, com tint), ou null se é automática
fn colorOf(tag: []const u8, theme: Theme) ?u32 {
    const base: u32 = if (hex(attribute(tag, "rgb"))) |rgb|
        rgb
    else if (attribute(tag, "theme")) |text| blk: {
        const index = std.fmt.parseInt(usize, text, 10) catch return null;
        break :blk if (index < theme.len) theme[index] else return null;
    } else if (attribute(tag, "indexed")) |text| blk: {
        const index = std.fmt.parseInt(usize, text, 10) catch return null;
        break :blk if (index < indexed_colors.len) indexed_colors[index] else return null;
    } else return null;
    const tint = std.fmt.parseFloat(f64, attribute(tag, "tint") orelse return base) catch return base;
    return applyTint(base, tint);
}

/// clareia (tint > 0) ou escurece (tint < 0) pela luminância HSL: L' = L(1+tint) ou L(1-tint) + tint
/// (ECMA-376 parte 1, 18.8.19 "fgColor", atributo tint; a conferir no PDF)
pub fn applyTint(rgb: u32, tint: f64) u32 {
    const red: f64 = @as(f64, @floatFromInt((rgb >> 16) & 0xFF)) / 255;
    const green: f64 = @as(f64, @floatFromInt((rgb >> 8) & 0xFF)) / 255;
    const blue: f64 = @as(f64, @floatFromInt(rgb & 0xFF)) / 255;
    const high = @max(red, @max(green, blue));
    const low = @min(red, @min(green, blue));
    var lightness = (high + low) / 2;
    var saturation: f64 = 0;
    var hue: f64 = 0;
    const spread = high - low;
    if (spread > 0) {
        saturation = if (lightness < 0.5) spread / (high + low) else spread / (2 - high - low);
        hue = if (high == red) @mod((green - blue) / spread, 6) else if (high == green) (blue - red) / spread + 2 else (red - green) / spread + 4;
        hue /= 6;
    }
    lightness = if (tint < 0) lightness * (1 + tint) else lightness * (1 - tint) + tint;
    lightness = std.math.clamp(lightness, 0, 1);
    const q = if (lightness < 0.5) lightness * (1 + saturation) else lightness + saturation - lightness * saturation;
    const p = 2 * lightness - q;
    const channels = [3]f64{ hueChannel(p, q, hue + 1.0 / 3.0), hueChannel(p, q, hue), hueChannel(p, q, hue - 1.0 / 3.0) };
    var out: u32 = 0;
    for (channels) |channel| out = (out << 8) | @as(u32, @intFromFloat(@round(std.math.clamp(channel, 0, 1) * 255)));
    return out;
}

fn hueChannel(p: f64, q: f64, hue_in: f64) f64 {
    var hue = hue_in;
    if (hue < 0) hue += 1;
    if (hue > 1) hue -= 1;
    if (hue < 1.0 / 6.0) return p + (q - p) * 6 * hue;
    if (hue < 0.5) return q;
    if (hue < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - hue) * 6;
    return p;
}

const Font = struct { color: u32 = 0, bold: bool = false, italic: bool = false, size: f32 = 11 };

/// casas decimais e porcentagem de um código de formato ("0.000", "#,##0.0", "0.00%")
fn decimalsOf(code: []const u8) struct { decimals: ?u8, percent: bool } {
    if (std.ascii.eqlIgnoreCase(code, "General") or code.len == 0) return .{ .decimals = null, .percent = false };
    const percent = std.mem.indexOfScalar(u8, code, '%') != null;
    const section = code[0 .. std.mem.indexOfScalar(u8, code, ';') orelse code.len];
    if (std.mem.indexOfAny(u8, section, "EeyYdDhHsS") != null and std.mem.indexOfScalar(u8, section, '0') == null) return .{ .decimals = null, .percent = percent };
    const dot = std.mem.indexOfScalar(u8, section, '.') orelse return .{ .decimals = 0, .percent = percent };
    var count: u8 = 0;
    for (section[dot + 1 ..]) |char| {
        if (char != '0' and char != '#') break;
        count += 1;
    }
    return .{ .decimals = count, .percent = percent };
}

/// os formatos que vêm prontos no Excel e mudam as casas (ECMA-376 parte 1, 18.8.30 "numFmt"; a conferir no PDF)
fn builtinFormat(id: u32) []const u8 {
    return switch (id) {
        1, 3 => "0",
        2, 4 => "0.00",
        9 => "0%",
        10 => "0.00%",
        else => "General",
    };
}

fn readStyles(allocator: std.mem.Allocator, xml: []const u8, theme: Theme) ![]const Style {
    // formatos próprios
    var formats: std.ArrayList(struct { id: u32, code: []const u8 }) = .empty;
    var format_tags = Tags{ .xml = xml };
    while (format_tags.next("numFmt")) |tag| {
        if (std.mem.startsWith(u8, tag, "numFmts")) continue;
        const id = std.fmt.parseInt(u32, attribute(tag, "numFmtId") orelse continue, 10) catch continue;
        try formats.append(allocator, .{ .id = id, .code = try unescape(allocator, attribute(tag, "formatCode") orelse "") });
    }

    var fonts: std.ArrayList(Font) = .empty;
    var section = Tags{ .xml = xml };
    if (section.next("fonts")) |_| {
        var tags = Tags{ .xml = section.body("fonts") };
        while (tags.next("font")) |tag| {
            var font = Font{};
            if (tag[tag.len - 1] != '/') {
                var inner = Tags{ .xml = tags.body("font") };
                while (inner.any()) |item| {
                    const name = item[0 .. std.mem.indexOfAny(u8, item, " /") orelse item.len];
                    const on = if (attribute(item, "val")) |val| !std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "false") else true;
                    if (std.mem.eql(u8, name, "b")) font.bold = on;
                    if (std.mem.eql(u8, name, "i")) font.italic = on;
                    if (std.mem.eql(u8, name, "sz")) font.size = std.fmt.parseFloat(f32, attribute(item, "val") orelse "11") catch 11;
                    if (std.mem.eql(u8, name, "color")) font.color = colorOf(item, theme) orelse 0;
                }
            }
            try fonts.append(allocator, font);
        }
    }

    var fills: std.ArrayList(?u32) = .empty;
    section = .{ .xml = xml };
    if (section.next("fills")) |_| {
        var tags = Tags{ .xml = section.body("fills") };
        while (tags.next("fill")) |tag| {
            if (tag[tag.len - 1] == '/') {
                try fills.append(allocator, null);
                continue;
            }
            const inside = tags.body("fill");
            var inner = Tags{ .xml = inside };
            const pattern = inner.next("patternFill");
            const solid = if (pattern) |found| std.mem.eql(u8, attribute(found, "patternType") orelse "none", "solid") else false;
            inner = .{ .xml = inside };
            const color = if (solid) (if (inner.next("fgColor")) |found| colorOf(found, theme) else null) else null;
            try fills.append(allocator, color);
        }
    }

    var borders: std.ArrayList(Borders) = .empty;
    section = .{ .xml = xml };
    if (section.next("borders")) |_| {
        var tags = Tags{ .xml = section.body("borders") };
        while (tags.next("border")) |tag| {
            var sides = Borders{};
            if (tag[tag.len - 1] != '/') {
                var inner = Tags{ .xml = tags.body("border") };
                while (inner.any()) |item| {
                    if (attribute(item, "style") == null) continue;
                    if (std.mem.startsWith(u8, item, "left")) sides.left = true;
                    if (std.mem.startsWith(u8, item, "right")) sides.right = true;
                    if (std.mem.startsWith(u8, item, "top")) sides.top = true;
                    if (std.mem.startsWith(u8, item, "bottom")) sides.bottom = true;
                }
            }
            try borders.append(allocator, sides);
        }
    }

    var styles: std.ArrayList(Style) = .empty;
    section = .{ .xml = xml };
    if (section.next("cellXfs")) |_| {
        const inside = section.body("cellXfs");
        var tags = Tags{ .xml = inside };
        while (tags.next("xf")) |tag| {
            var style = Style{};
            const font_id = std.fmt.parseInt(usize, attribute(tag, "fontId") orelse "0", 10) catch 0;
            if (font_id < fonts.items.len) {
                const font = fonts.items[font_id];
                style.font_color = font.color;
                style.bold = font.bold;
                style.italic = font.italic;
                style.size = font.size;
            }
            const fill_id = std.fmt.parseInt(usize, attribute(tag, "fillId") orelse "0", 10) catch 0;
            if (fill_id < fills.items.len) style.fill = fills.items[fill_id];
            const border_id = std.fmt.parseInt(usize, attribute(tag, "borderId") orelse "0", 10) catch 0;
            if (border_id < borders.items.len) style.borders = borders.items[border_id];
            const format_id = std.fmt.parseInt(u32, attribute(tag, "numFmtId") orelse "0", 10) catch 0;
            var code = builtinFormat(format_id);
            for (formats.items) |item| if (item.id == format_id) {
                code = item.code;
            };
            const parsed = decimalsOf(code);
            style.decimals = parsed.decimals;
            style.percent = parsed.percent;
            if (tag[tag.len - 1] != '/') {
                // o corpo do <xf> vai até o próximo </xf>; nele pode vir <alignment horizontal=...>
                const end = std.mem.indexOfPos(u8, inside, tags.position, "</xf>") orelse inside.len;
                var inner = Tags{ .xml = inside[tags.position..end] };
                if (inner.next("alignment")) |found| if (attribute(found, "horizontal")) |horizontal| {
                    style.alignment = if (std.mem.eql(u8, horizontal, "center") or std.mem.eql(u8, horizontal, "centerContinuous"))
                        .center
                    else if (std.mem.eql(u8, horizontal, "right"))
                        .right
                    else if (std.mem.eql(u8, horizontal, "left"))
                        .left
                    else
                        .general;
                };
            }
            try styles.append(allocator, style);
        }
    }
    return styles.items;
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

test "tint clareia e escurece pela luminância" {
    // branco com tint -0,5 vira cinza médio; preto com tint 0,5 também (L = 0,5)
    try std.testing.expectEqual(@as(u32, 0x808080), applyTint(0xFFFFFF, -0.5));
    try std.testing.expectEqual(@as(u32, 0x808080), applyTint(0x000000, 0.5));
    // o acento 4472C4 com tint 0,4 ("40% mais claro"): o Excel mostra 8EA9DB; 1 de diferença por canal vem do HLS
    // inteiro (0..240) que ele usa, aqui a conta é em ponto flutuante
    try std.testing.expectEqual(@as(u32, 0x8FAADC), applyTint(0x4472C4, 0.39997558519241921));
}

test "casas decimais do formato" {
    try std.testing.expectEqual(@as(?u8, 3), decimalsOf("#,##0.000").decimals);
    try std.testing.expectEqual(@as(?u8, 1), decimalsOf("0.0\\°").decimals);
    try std.testing.expectEqual(@as(?u8, null), decimalsOf("General").decimals);
    try std.testing.expect(decimalsOf("0.00%").percent);
}

test "estilos, larguras e mesclas de uma folha" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const styles_xml =
        \\<styleSheet><numFmts count="1"><numFmt numFmtId="164" formatCode="0.000"/></numFmts>
        \\<fonts count="2"><font><sz val="11"/><color theme="1"/></font><font><b/><sz val="14"/><color rgb="FFFF0000"/></font></fonts>
        \\<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
        \\<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill></fills>
        \\<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>
        \\<border><left style="thin"><color indexed="64"/></left><right/><top/><bottom style="thin"/><diagonal/></border></borders>
        \\<cellStyleXfs count="1"><xf numFmtId="0" fontId="1" fillId="2"/></cellStyleXfs>
        \\<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        \\<xf numFmtId="164" fontId="1" fillId="2" borderId="1" xfId="0"><alignment horizontal="center"/></xf></cellXfs></styleSheet>
    ;
    const styles = try readStyles(memory, styles_xml, default_theme);
    try std.testing.expectEqual(@as(usize, 2), styles.len);
    try std.testing.expectEqual(@as(?u32, null), styles[0].fill);
    try std.testing.expectEqual(@as(?u32, 0xFFF2CC), styles[1].fill);
    try std.testing.expectEqual(@as(u32, 0xFF0000), styles[1].font_color);
    try std.testing.expect(styles[1].bold);
    try std.testing.expectEqual(Alignment.center, styles[1].alignment);
    try std.testing.expectEqual(@as(?u8, 3), styles[1].decimals);
    try std.testing.expect(styles[1].borders.left and styles[1].borders.bottom and !styles[1].borders.top);

    const sheet_xml =
        \\<worksheet><sheetFormatPr defaultRowHeight="14.45"/><cols><col min="2" max="3" width="25" customWidth="1"/></cols>
        \\<sheetData><row r="2" ht="30" customHeight="1"><c r="B2" s="1" t="inlineStr"><is><t>Título</t></is></c><c r="C2" s="1"/></row>
        \\<row r="3"><c r="B3"><v>1.5</v></c></row></sheetData>
        \\<mergeCells count="1"><mergeCell ref="B2:C2"/></mergeCells></worksheet>
    ;
    var sheet = try readSheet(memory, sheet_xml, &.{});
    sheet.styles = styles;
    try std.testing.expectEqual(@as(usize, 2), sheet.cells.len);
    try std.testing.expectEqual(@as(?u32, 0xFFF2CC), sheet.styleAt(2, 3).fill); // vazia, só pintada
    try std.testing.expectEqual(@as(?u32, null), sheet.styleAt(3, 2).fill);
    try std.testing.expectEqual(@as(f32, 25), sheet.columnWidth(3));
    try std.testing.expectEqual(@as(f32, 8.43), sheet.columnWidth(4));
    try std.testing.expectEqual(@as(f32, 30), sheet.rowHeight(2));
    try std.testing.expectEqual(@as(f32, 14.45), sheet.rowHeight(3));
    const merge = sheet.mergeAt(2, 3).?;
    try std.testing.expectEqual(@as(u32, 2), merge.first_column);
    try std.testing.expectEqual(@as(u32, 3), sheet.lastColumn());
}

//! Gravador de planilhas `.xlsx` sem dependência de fora, o par do `xlsx.zig`: monta as partes do Office Open XML
//! (ECMA-376 parte 1: 18.3 "Worksheets", 18.8 "Styles", 20.4 "DrawingML - SpreadsheetML Drawing" e 21.2 "DrawingML -
//! Charts") e guarda tudo num zip (`zip.Writer`). Serve para o programa entregar os resultados no jeito das planilhas
//! das equipes: um título numa faixa mesclada, cabeçalhos coloridos com borda, números com casas fixas e gráficos de
//! dispersão do próprio Excel, ligados às células (mudar a célula muda o gráfico).
//!
//!     var sheet = xlsx_writer.Sheet{ .name = "Missão" };
//!     try sheet.text(memory, 1, 1, "Missão", .title);
//!     try sheet.number(memory, 3, 2, 12.5, .number);
//!     try sheet.chart(memory, .{ .title = "Trajetória", ... });
//!     const bytes = try xlsx_writer.write(memory, &.{sheet});
//!
//! Os estilos são poucos e fixos (`Style`), com as cores das planilhas de desempenho e E&C das equipes.
const std = @import("std");
const zip = @import("zip.zig");

/// a aparência de uma célula (cada uma vira um `xf` da tabela de estilos, na mesma ordem)
pub const Style = enum(u8) {
    normal = 0,
    /// faixa do título: branco em negrito sobre azul-escuro
    title = 1,
    /// cabeçalho de tabela: negrito sobre azul-claro, com borda
    header = 2,
    /// número da tabela: 0,000 com borda
    number = 3,
    /// rótulo de um parâmetro: fundo rosado, com borda
    label = 4,
    /// valor de um parâmetro: fundo amarelo-claro, 0,000, com borda
    value = 5,
    /// texto comum com borda (a unidade, um nome)
    boxed = 6,
    /// cabeçalho escuro: amarelo em negrito sobre cinza-azulado escuro (T0 corrigida, rotação, os p_ij)
    dark_header = 7,
    /// cabeçalho preto: amarelo em negrito sobre preto
    black_header = 8,
    /// destaque laranja: o número que manda (a tração estática), 0,00
    orange_value = 9,
    /// destaque verde: a rotação, sem casas
    green_value = 10,
    /// destaque roxo: os coeficientes do polinômio
    purple_value = 11,
    /// número da tabela com duas casas e borda (as trações e potências)
    number_2 = 12,
};

const CellValue = union(enum) { number: f64, text: []const u8 };

const Cell = struct { row: u32, column: u32, value: CellValue, style: Style };

/// uma curva do gráfico: o nome e os intervalos das colunas x e y na própria aba (linhas e colunas de 1)
pub const ChartSeries = struct {
    name: []const u8,
    x_column: u32,
    y_column: u32,
    first_row: u32,
    last_row: u32,
};

/// um gráfico de dispersão com linhas, preso entre duas células (canto de cima à esquerda e de baixo à direita)
pub const Chart = struct {
    title: []const u8,
    x_label: []const u8,
    y_label: []const u8,
    series: []const ChartSeries,
    from_column: u32,
    from_row: u32,
    to_column: u32,
    to_row: u32,
};

/// uma aba a gravar
pub const Sheet = struct {
    name: []const u8,
    cells: std.ArrayList(Cell) = .empty,
    merges: std.ArrayList([4]u32) = .empty, // linha e coluna do começo, linha e coluna do fim
    widths: std.ArrayList([2]f32) = .empty, // coluna e largura (em caracteres)
    charts: std.ArrayList(Chart) = .empty,

    /// um texto na célula (linha e coluna de 1)
    pub fn text(sheet: *Sheet, memory: std.mem.Allocator, row: u32, column: u32, value: []const u8, style: Style) !void {
        try sheet.cells.append(memory, .{ .row = row, .column = column, .value = .{ .text = value }, .style = style });
    }

    /// um número na célula; NaN e infinito ficam de fora (a célula fica vazia, com o estilo)
    pub fn number(sheet: *Sheet, memory: std.mem.Allocator, row: u32, column: u32, value: f64, style: Style) !void {
        if (!std.math.isFinite(value)) return sheet.text(memory, row, column, "", style);
        try sheet.cells.append(memory, .{ .row = row, .column = column, .value = .{ .number = value }, .style = style });
    }

    /// mescla o retângulo (o valor fica na primeira célula); as outras células recebem o mesmo estilo
    pub fn merge(sheet: *Sheet, memory: std.mem.Allocator, first_row: u32, first_column: u32, last_row: u32, last_column: u32, style: Style) !void {
        try sheet.merges.append(memory, .{ first_row, first_column, last_row, last_column });
        var row = first_row;
        while (row <= last_row) : (row += 1) {
            var column = first_column;
            while (column <= last_column) : (column += 1) {
                if (row == first_row and column == first_column) continue;
                try sheet.text(memory, row, column, "", style);
            }
        }
    }

    /// a largura da coluna, em caracteres
    pub fn width(sheet: *Sheet, memory: std.mem.Allocator, column: u32, characters: f32) !void {
        try sheet.widths.append(memory, .{ @floatFromInt(column), characters });
    }

    /// um gráfico preso na aba
    pub fn chart(sheet: *Sheet, memory: std.mem.Allocator, item: Chart) !void {
        try sheet.charts.append(memory, item);
    }
};

/// o endereço "AB12"
pub fn address(buffer: []u8, row: u32, column: u32) []const u8 {
    var letters: [4]u8 = undefined;
    var length: usize = 0;
    var number = column;
    while (number > 0 and length < 4) : (length += 1) {
        number -= 1;
        letters[length] = @intCast('A' + number % 26);
        number /= 26;
    }
    var out = std.Io.Writer.fixed(buffer);
    for (0..length) |i| out.writeByte(letters[length - 1 - i]) catch {};
    out.print("{d}", .{row}) catch {};
    return buffer[0..out.end];
}

/// o nome válido de uma aba: até 31 caracteres, sem `[]:*?/\` (ECMA-376 parte 1, 18.2.19 "sheet"; a conferir no PDF)
pub fn sheetName(memory: std.mem.Allocator, wanted: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var view = std.unicode.Utf8View.init(wanted) catch return memory.dupe(u8, "Aba");
    var letters = view.iterator();
    while (letters.nextCodepointSlice()) |letter| {
        if (count >= 31) break;
        const bad = letter.len == 1 and std.mem.indexOfScalar(u8, "[]:*?/\\", letter[0]) != null;
        try out.appendSlice(memory, if (bad) "-" else letter);
        count += 1;
    }
    return if (out.items.len == 0) memory.dupe(u8, "Aba") else out.items;
}

/// grava a pasta de trabalho inteira e devolve os bytes do `.xlsx`
pub fn write(memory: std.mem.Allocator, sheets: []const Sheet) ![]const u8 {
    var archive: zip.Writer = .{};
    var chart_total: usize = 0;
    for (sheets) |sheet| chart_total += sheet.charts.items.len;

    // [Content_Types].xml
    var types: std.Io.Writer.Allocating = .init(memory);
    try types.writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    );
    for (sheets, 1..) |sheet, k| {
        try types.writer.print("<Override PartName=\"/xl/worksheets/sheet{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>", .{k});
        if (sheet.charts.items.len > 0) try types.writer.print("<Override PartName=\"/xl/drawings/drawing{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>", .{k});
    }
    for (1..chart_total + 1) |k| try types.writer.print("<Override PartName=\"/xl/charts/chart{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>", .{k});
    try types.writer.writeAll("</Types>");
    try archive.add(memory, "[Content_Types].xml", types.written());

    try archive.add(memory, "_rels/.rels",
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    );

    // workbook e as relações dele
    var book: std.Io.Writer.Allocating = .init(memory);
    try book.writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
    );
    var book_relations: std.Io.Writer.Allocating = .init(memory);
    try book_relations.writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    );
    for (sheets, 1..) |sheet, k| {
        try book.writer.print("<sheet name=\"{f}\" sheetId=\"{d}\" r:id=\"rId{d}\"/>", .{ escaped(sheet.name), k, k });
        try book_relations.writer.print("<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{d}.xml\"/>", .{ k, k });
    }
    try book.writer.writeAll("</sheets></workbook>");
    try book_relations.writer.print("<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>", .{sheets.len + 1});
    try archive.add(memory, "xl/workbook.xml", book.written());
    try archive.add(memory, "xl/_rels/workbook.xml.rels", book_relations.written());
    try archive.add(memory, "xl/styles.xml", styles_xml);

    var chart_index: usize = 0;
    for (sheets, 1..) |sheet, k| {
        try archive.add(memory, try std.fmt.allocPrint(memory, "xl/worksheets/sheet{d}.xml", .{k}), try sheetXml(memory, sheet));
        if (sheet.charts.items.len == 0) continue;
        try archive.add(memory, try std.fmt.allocPrint(memory, "xl/worksheets/_rels/sheet{d}.xml.rels", .{k}), try std.fmt.allocPrint(memory,
            \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing{d}.xml"/></Relationships>
        , .{k}));
        var drawing: std.Io.Writer.Allocating = .init(memory);
        var drawing_relations: std.Io.Writer.Allocating = .init(memory);
        try drawing.writer.writeAll(
            \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            \\<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
        );
        try drawing_relations.writer.writeAll(
            \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        );
        for (sheet.charts.items, 1..) |item, n| {
            chart_index += 1;
            // a âncora conta de 0 (ECMA-376 parte 1, 20.5.2.15 "from")
            try drawing.writer.print(
                \\<xdr:twoCellAnchor><xdr:from><xdr:col>{d}</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>{d}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>{d}</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>{d}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="{d}" name="Gráfico {d}"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart r:id="rId{d}"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>
            , .{ item.from_column - 1, item.from_row - 1, item.to_column - 1, item.to_row - 1, n + 1, n, n });
            try drawing_relations.writer.print("<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\" Target=\"../charts/chart{d}.xml\"/>", .{ n, chart_index });
            try archive.add(memory, try std.fmt.allocPrint(memory, "xl/charts/chart{d}.xml", .{chart_index}), try chartXml(memory, sheet.name, item));
        }
        try drawing.writer.writeAll("</xdr:wsDr>");
        try drawing_relations.writer.writeAll("</Relationships>");
        try archive.add(memory, try std.fmt.allocPrint(memory, "xl/drawings/drawing{d}.xml", .{k}), drawing.written());
        try archive.add(memory, try std.fmt.allocPrint(memory, "xl/drawings/_rels/drawing{d}.xml.rels", .{k}), drawing_relations.written());
    }
    return archive.finish(memory);
}

/// a tabela de estilos: fontes, fundos, bordas e um `xf` por `Style`, na ordem do enum
const styles_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="0.000"/><numFmt numFmtId="165" formatCode="0.00"/></numFmts><fonts count="4"><font><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/></font><font><b/><sz val="14"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/></font><font><b/><sz val="12"/><color rgb="FFFFFF00"/><name val="Calibri"/></font></fonts><fills count="11"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF9BC2E6"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF222B35"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF000000"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFF4411"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF0EEC38"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF7030A0"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color indexed="64"/></left><right style="thin"><color indexed="64"/></right><top style="thin"><color indexed="64"/></top><bottom style="thin"><color indexed="64"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="13"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="2" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center"/></xf><xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1"/><xf numFmtId="164" fontId="0" fillId="5" borderId="1" xfId="0" applyNumberFormat="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center"/></xf><xf numFmtId="0" fontId="3" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="3" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="165" fontId="2" fillId="8" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="1" fontId="2" fillId="9" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="2" fillId="10" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center"/></xf></cellXfs></styleSheet>
;

fn sheetXml(memory: std.mem.Allocator, sheet: Sheet) ![]const u8 {
    const cells = try memory.dupe(Cell, sheet.cells.items);
    std.mem.sort(Cell, cells, {}, struct {
        fn before(_: void, left: Cell, right: Cell) bool {
            return left.row < right.row or (left.row == right.row and left.column < right.column);
        }
    }.before);
    var out: std.Io.Writer.Allocating = .init(memory);
    const writer = &out.writer;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><sheetViews><sheetView workbookViewId="0" showGridLines="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/>
    );
    if (sheet.widths.items.len > 0) {
        try writer.writeAll("<cols>");
        for (sheet.widths.items) |item| try writer.print("<col min=\"{d}\" max=\"{d}\" width=\"{d}\" customWidth=\"1\"/>", .{ item[0], item[0], item[1] });
        try writer.writeAll("</cols>");
    }
    try writer.writeAll("<sheetData>");
    var row: u32 = 0;
    var previous_column: u32 = 0;
    for (cells) |cell| {
        // a mesma célula duas vezes: vale a última escrita (a de valor ganha da só pintada)
        if (cell.row == row and cell.column == previous_column) continue;
        if (cell.row != row) {
            if (row != 0) try writer.writeAll("</row>");
            row = cell.row;
            try writer.print("<row r=\"{d}\"{s}>", .{ row, if (rowHasTitle(cells, row)) " ht=\"24\" customHeight=\"1\"" else "" });
        }
        previous_column = cell.column;
        var buffer: [16]u8 = undefined;
        const where = address(&buffer, cell.row, cell.column);
        switch (cell.value) {
            .number => |value| try writer.print("<c r=\"{s}\" s=\"{d}\"><v>{d}</v></c>", .{ where, @intFromEnum(cell.style), value }),
            .text => |value| if (value.len == 0)
                try writer.print("<c r=\"{s}\" s=\"{d}\"/>", .{ where, @intFromEnum(cell.style) })
            else
                try writer.print("<c r=\"{s}\" s=\"{d}\" t=\"inlineStr\"><is><t>{f}</t></is></c>", .{ where, @intFromEnum(cell.style), escaped(value) }),
        }
    }
    if (row != 0) try writer.writeAll("</row>");
    try writer.writeAll("</sheetData>");
    if (sheet.merges.items.len > 0) {
        try writer.print("<mergeCells count=\"{d}\">", .{sheet.merges.items.len});
        for (sheet.merges.items) |item| {
            var first: [16]u8 = undefined;
            var last: [16]u8 = undefined;
            try writer.print("<mergeCell ref=\"{s}:{s}\"/>", .{ address(&first, item[0], item[1]), address(&last, item[2], item[3]) });
        }
        try writer.writeAll("</mergeCells>");
    }
    // impressão: a aba inteira numa folha deitada, tabela e gráfico juntos
    try writer.writeAll("<pageMargins left=\"0.4\" right=\"0.4\" top=\"0.5\" bottom=\"0.5\" header=\"0.3\" footer=\"0.3\"/><pageSetup orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"1\"/>");
    if (sheet.charts.items.len > 0) try writer.writeAll("<drawing r:id=\"rId1\"/>");
    try writer.writeAll("</worksheet>");
    return out.written();
}

fn rowHasTitle(cells: []const Cell, row: u32) bool {
    for (cells) |cell| if (cell.row == row and cell.style == .title) return true;
    return false;
}

/// as cores das curvas, na ordem (as do tema do aerosim)
const series_colors = [_][]const u8{ "0D5FD9", "EB6834", "1BAF7A", "D62728", "9467BD", "8C564B", "E377C2", "7F7F7F" };

fn chartXml(memory: std.mem.Allocator, sheet_name: []const u8, item: Chart) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(memory);
    const writer = &out.writer;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:roundedCorners val="0"/><c:chart>
    );
    try titleXml(writer, item.title, 1400);
    try writer.writeAll("<c:autoTitleDeleted val=\"0\"/><c:plotArea><c:layout/><c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>");
    for (item.series, 0..) |series, k| {
        var x_first: [16]u8 = undefined;
        var x_last: [16]u8 = undefined;
        var y_first: [16]u8 = undefined;
        var y_last: [16]u8 = undefined;
        try writer.print(
            \\<c:ser><c:idx val="{d}"/><c:order val="{d}"/><c:tx><c:v>{f}</c:v></c:tx><c:spPr><a:ln w="22225"><a:solidFill><a:srgbClr val="{s}"/></a:solidFill></a:ln></c:spPr><c:marker><c:symbol val="none"/></c:marker><c:xVal><c:numRef><c:f>'{f}'!${s}:${s}</c:f></c:numRef></c:xVal><c:yVal><c:numRef><c:f>'{f}'!${s}:${s}</c:f></c:numRef></c:yVal><c:smooth val="0"/></c:ser>
        , .{
            k,                                                              k,
            escaped(series.name),                                           series_colors[k % series_colors.len],
            sheetRef(sheet_name),                                           dollar(&x_first, series.first_row, series.x_column),
            dollar(&x_last, series.last_row, series.x_column),              sheetRef(sheet_name),
            dollar(&y_first, series.first_row, series.y_column),            dollar(&y_last, series.last_row, series.y_column),
        });
    }
    try writer.writeAll("<c:axId val=\"1001\"/><c:axId val=\"1002\"/></c:scatterChart>");
    try axisXml(writer, 1001, 1002, "b", item.x_label);
    try axisXml(writer, 1002, 1001, "l", item.y_label);
    try writer.writeAll("</c:plotArea><c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend><c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart></c:chartSpace>");
    return out.written();
}

fn titleXml(writer: *std.Io.Writer, text: []const u8, size: u32) !void {
    try writer.print("<c:title><c:tx><c:rich><a:bodyPr/><a:p><a:pPr><a:defRPr sz=\"{d}\" b=\"1\"/></a:pPr><a:r><a:rPr lang=\"pt-BR\" sz=\"{d}\" b=\"1\"/><a:t>{f}</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>", .{ size, size, escaped(text) });
}

fn axisXml(writer: *std.Io.Writer, id: u32, crossing: u32, position: []const u8, label: []const u8) !void {
    try writer.print("<c:valAx><c:axId val=\"{d}\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"{s}\"/><c:majorGridlines><c:spPr><a:ln><a:solidFill><a:srgbClr val=\"D9D9D9\"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>", .{ id, position });
    if (label.len > 0) try titleXml(writer, label, 1000);
    try writer.print("<c:numFmt formatCode=\"General\" sourceLinked=\"0\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"low\"/><c:crossAx val=\"{d}\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"midCat\"/></c:valAx>", .{crossing});
}

/// "$B$3" (sem o primeiro $, que vem no formato)
fn dollar(buffer: []u8, row: u32, column: u32) []const u8 {
    var plain: [16]u8 = undefined;
    const where = address(&plain, row, column);
    var split: usize = 0;
    while (split < where.len and std.ascii.isAlphabetic(where[split])) split += 1;
    return std.fmt.bufPrint(buffer, "{s}${s}", .{ where[0..split], where[split..] }) catch "";
}

/// o nome da aba dentro de uma referência entre aspas simples: a aspa simples dobra
const SheetRef = struct {
    name: []const u8,
    pub fn format(ref: SheetRef, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (ref.name) |char| {
            if (char == '\'') try writer.writeByte('\'');
            try writer.print("{f}", .{escaped(&.{char})});
        }
    }
};

fn sheetRef(name: []const u8) SheetRef {
    return .{ .name = name };
}

/// o texto com as entidades do XML (& < > ")
const Escaped = struct {
    text: []const u8,
    pub fn format(item: Escaped, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (item.text) |char| switch (char) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(char),
        };
    }
};

fn escaped(text: []const u8) Escaped {
    return .{ .text = text };
}

// ------------------------------------------------------------------ testes

const xlsx = @import("xlsx.zig");

test "o endereço e o nome da aba" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("AB12", address(&buffer, 12, 28));
    var dollars: [16]u8 = undefined;
    try std.testing.expectEqualStrings("B$3", dollar(&dollars, 3, 2));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Voo nivelado - envelopes", try sheetName(arena.allocator(), "Voo nivelado / envelopes"));
}

test "a planilha gravada volta igual pelo leitor, com as cores, as mesclas e o gráfico" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var sheet = Sheet{ .name = "Missão & decolagem" };
    try sheet.text(memory, 1, 1, "Missão", .title);
    try sheet.merge(memory, 1, 1, 1, 4, .title);
    try sheet.text(memory, 3, 1, "V (m/s)", .header);
    try sheet.text(memory, 3, 2, "T (N)", .header);
    for (0..5) |j| {
        try sheet.number(memory, 4 + @as(u32, @intCast(j)), 1, @floatFromInt(j), .number);
        try sheet.number(memory, 4 + @as(u32, @intCast(j)), 2, 30 - @as(f64, @floatFromInt(j)), .number);
    }
    try sheet.width(memory, 1, 14);
    try sheet.chart(memory, .{ .title = "Tração", .x_label = "V (m/s)", .y_label = "T (N)", .series = &.{.{ .name = "T", .x_column = 1, .y_column = 2, .first_row = 4, .last_row = 8 }}, .from_column = 4, .from_row = 3, .to_column = 10, .to_row = 18 });
    const bytes = try write(memory, &.{sheet});
    const book = try xlsx.Workbook.parse(memory, bytes);
    try std.testing.expectEqual(@as(usize, 1), book.sheets.len);
    const read = book.sheets[0];
    try std.testing.expectEqualStrings("Missão & decolagem", read.name);
    try std.testing.expectEqualStrings("Missão", read.at(1, 1).?.text);
    try std.testing.expectEqual(@as(f64, 28), read.at(6, 2).?.number);
    try std.testing.expectEqual(@as(?u32, 0x1F4E78), read.styleAt(1, 3).fill); // a faixa mesclada, pintada inteira
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), read.styleAt(1, 1).font_color);
    try std.testing.expectEqual(@as(?u8, 3), read.styleAt(5, 1).decimals);
    try std.testing.expectEqual(@as(usize, 1), read.merges.len);
    try std.testing.expectEqual(@as(f32, 14), read.columnWidth(1));
    const archive = try zip.Archive.open(memory, bytes);
    const chart_xml = try archive.extract(memory, archive.find("xl/charts/chart1.xml").?);
    try std.testing.expect(std.mem.indexOf(u8, chart_xml, "'Missão &amp; decolagem'!$A$4:$A$8") != null);
}

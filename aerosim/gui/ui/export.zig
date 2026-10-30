//! Gravar o que a tela mostra em arquivo: os dados de um gráfico em CSV, a imagem dele em PNG (pelo raylib) e a
//! mesma imagem dentro de um PDF de uma página. O CSV é o padrão (vírgula entre colunas, ponto decimal, nomes entre
//! aspas, uma linha de cabeçalho), para abrir direto numa planilha ou no pandas. O PDF leva a imagem comprimida
//! (FlateDecode, o zlib da biblioteca do Zig), no tamanho dela em pontos.
const std = @import("std");

/// uma coluna de números com o nome do cabeçalho
pub const Column = struct {
    name: []const u8,
    values: []const f64,
};

/// escreve `columns` em CSV em `writer`: cabeçalho e uma linha por índice (vazio onde a coluna acabou ou o valor
/// não é finito)
pub fn writeCsv(writer: *std.Io.Writer, columns: []const Column) !void {
    for (columns, 0..) |column, k| {
        if (k > 0) try writer.writeByte(',');
        try quoted(writer, column.name);
    }
    try writer.writeAll("\n");
    var rows: usize = 0;
    for (columns) |column| rows = @max(rows, column.values.len);
    for (0..rows) |row| {
        for (columns, 0..) |column, k| {
            if (k > 0) try writer.writeByte(',');
            if (row < column.values.len and std.math.isFinite(column.values[row])) try writer.print("{d}", .{column.values[row]});
        }
        try writer.writeAll("\n");
    }
}

/// um texto entre aspas, como o CSV pede (aspas de dentro dobradas)
pub fn writeText(writer: *std.Io.Writer, text: []const u8) !void {
    return quoted(writer, text);
}

fn quoted(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        if (c == '"') try writer.writeByte('"');
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

/// grava as colunas num arquivo CSV
pub fn saveCsv(gpa: std.mem.Allocator, io: std.Io, path: []const u8, columns: []const Column) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeCsv(&out.writer, columns);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// escreve um PDF de uma página com a imagem RGB `rgb` (`width` × `height` pixels, linha a linha de cima para
/// baixo) ocupando a página de `page_width` × `page_height` pontos
pub fn writePdf(gpa: std.mem.Allocator, writer: *std.Io.Writer, rgb: []const u8, width: usize, height: usize, page_width: f64, page_height: f64) !void {
    // a imagem comprimida em zlib
    var packed_image: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    defer packed_image.deinit();
    {
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var compress = try std.compress.flate.Compress.init(&packed_image.writer, window, .zlib, .default);
        try compress.writer.writeAll(rgb);
        try compress.finish();
    }
    const image = packed_image.written();
    var content_buffer: [128]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buffer, "q {d:.2} 0 0 {d:.2} 0 0 cm /Im0 Do Q\n", .{ page_width, page_height });
    // os objetos, guardando onde cada um começa (a tabela xref aponta para eles)
    var offsets: [6]usize = undefined;
    var position: usize = 0;
    const Counter = struct {
        fn put(w: *std.Io.Writer, at: *usize, comptime format: []const u8, args: anytype) !void {
            var buffer: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, format, args);
            try w.writeAll(text);
            at.* += text.len;
        }
        fn raw(w: *std.Io.Writer, at: *usize, bytes: []const u8) !void {
            try w.writeAll(bytes);
            at.* += bytes.len;
        }
    };
    try Counter.raw(writer, &position, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
    offsets[1] = position;
    try Counter.put(writer, &position, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n", .{});
    offsets[2] = position;
    try Counter.put(writer, &position, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n", .{});
    offsets[3] = position;
    try Counter.put(writer, &position, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.2} {d:.2}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n", .{ page_width, page_height });
    offsets[4] = position;
    try Counter.put(writer, &position, "4 0 obj\n<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length {d} >>\nstream\n", .{ width, height, image.len });
    try Counter.raw(writer, &position, image);
    try Counter.raw(writer, &position, "\nendstream\nendobj\n");
    offsets[5] = position;
    try Counter.put(writer, &position, "5 0 obj\n<< /Length {d} >>\nstream\n", .{content.len});
    try Counter.raw(writer, &position, content);
    try Counter.raw(writer, &position, "endstream\nendobj\n");
    const xref = position;
    try Counter.put(writer, &position, "xref\n0 6\n0000000000 65535 f \n", .{});
    for (offsets[1..]) |offset| try Counter.put(writer, &position, "{d:0>10} 00000 n \n", .{offset});
    try Counter.put(writer, &position, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
}

/// grava o PDF da imagem num arquivo
pub fn savePdf(gpa: std.mem.Allocator, io: std.Io, path: []const u8, rgb: []const u8, width: usize, height: usize, page_width: f64, page_height: f64) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writePdf(gpa, &out.writer, rgb, width, height, page_width, page_height);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// um nome de arquivo a partir do título ("C_L × α da asa" → "C_L_α_da_asa.png")
pub fn fileName(buffer: []u8, title: []const u8, extension: []const u8) []const u8 {
    var length: usize = 0;
    var last_was_gap = false;
    var view = std.unicode.Utf8View.init(title) catch std.unicode.Utf8View.initUnchecked("grafico");
    var letters = view.iterator();
    while (letters.nextCodepointSlice()) |letter| {
        if (length + letter.len + extension.len + 2 >= buffer.len) break;
        const codepoint = std.unicode.utf8Decode(letter) catch '_';
        // letras e números (ASCII, latinas acentuadas, gregas); o resto (espaço, ×, parênteses) vira "_"
        const keep = (codepoint < 0x80 and (std.ascii.isAlphanumeric(@intCast(codepoint)) or codepoint == '_' or codepoint == '-')) or
            (codepoint >= 0xC0 and codepoint <= 0x24F and codepoint != 0xD7 and codepoint != 0xF7) or
            (codepoint >= 0x370 and codepoint <= 0x3FF);
        if (keep) {
            @memcpy(buffer[length..][0..letter.len], letter);
            length += letter.len;
            last_was_gap = false;
        } else if (!last_was_gap and length > 0) {
            buffer[length] = '_';
            length += 1;
            last_was_gap = true;
        }
    }
    while (length > 0 and buffer[length - 1] == '_') length -= 1;
    if (length == 0) {
        @memcpy(buffer[0..7], "grafico");
        length = 7;
    }
    buffer[length] = '.';
    @memcpy(buffer[length + 1 ..][0..extension.len], extension);
    return buffer[0 .. length + 1 + extension.len];
}

test "nome de arquivo a partir do título" {
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings("C_L_α_da_asa_até_o_estol.png", fileName(&buffer, "C_L × α da asa (até o estol)", "png"));
    try std.testing.expectEqualStrings("grafico.csv", fileName(&buffer, " ()", "csv"));
}


test "CSV: cabeçalho entre aspas, colunas de tamanhos diferentes e valor não finito vazio" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCsv(&out.writer, &.{
        .{ .name = "asa \"A\" · α (°)", .values = &.{ 1, 2.5, 3 } },
        .{ .name = "C_L", .values = &.{ 0.1, std.math.nan(f64) } },
    });
    try std.testing.expectEqualStrings("\"asa \"\"A\"\" · α (°)\",\"C_L\"\n1,0.1\n2.5,\n3,\n", out.written());
}

test "PDF: começa e termina como PDF e a tabela aponta para os objetos" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const pixels = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    try writePdf(std.testing.allocator, &out.writer, &pixels, 2, 2, 100, 100);
    const pdf = out.written();
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
    // cada entrada da xref aponta para "N 0 obj"
    const table = std.mem.indexOf(u8, pdf, "xref\n0 6\n").? + "xref\n0 6\n".len + 20;
    for (1..6) |k| {
        const entry = pdf[table + (k - 1) * 20 ..][0..10];
        const offset = try std.fmt.parseInt(usize, entry, 10);
        var expected: [16]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, pdf[offset..], try std.fmt.bufPrint(&expected, "{d} 0 obj", .{k})));
    }
}

//! O zip (APPNOTE da PKWARE) sem dependência de fora: ler o índice e as partes (guardadas ou com deflate) e gravar um
//! zip novo com as partes guardadas, sem comprimir (método 0, com o CRC-32 de cada uma). É a caixa do `.xlsx` e dos
//! arquivos próprios do programa (`.aero`):
//!
//!     var zip_out: zip.Writer = .{};
//!     try zip_out.add(arena, "manifesto.zon", texto);
//!     const bytes = try zip_out.finish(arena);
//!     const lido = try zip.Archive.open(arena, bytes);
//!     const parte = try lido.extract(arena, lido.find("manifesto.zon").?);
const std = @import("std");

pub const ZipError = error{ NotZip, UnsupportedCompression };

/// o diretório central do zip, lido direto dos bytes (APPNOTE 4.3.12 e 4.3.16)
pub const Archive = struct {
    bytes: []const u8,
    entries: []const Entry,

    pub const Entry = struct { name: []const u8, method: u16, compressed: u32, size: u32, local_offset: u32 };

    /// lê o índice do zip em `bytes` (os bytes ficam com quem chama)
    pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
        if (bytes.len < 22) return ZipError.NotZip;
        // o registro do fim fica nos últimos 22 + até 65535 bytes (o comentário do zip)
        var position: usize = bytes.len - 22;
        const lowest = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
        while (!std.mem.eql(u8, bytes[position..][0..4], "PK\x05\x06")) {
            if (position == lowest) return ZipError.NotZip;
            position -= 1;
        }
        const count = readInt(u16, bytes, position + 10);
        var cursor: usize = readInt(u32, bytes, position + 16);
        const entries = try allocator.alloc(Entry, count);
        for (entries) |*entry| {
            if (cursor + 46 > bytes.len or !std.mem.eql(u8, bytes[cursor..][0..4], "PK\x01\x02")) return ZipError.NotZip;
            const name_length = readInt(u16, bytes, cursor + 28);
            const extra_length = readInt(u16, bytes, cursor + 30);
            const comment_length = readInt(u16, bytes, cursor + 32);
            if (cursor + 46 + name_length > bytes.len) return ZipError.NotZip;
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

    /// a parte com este nome (sem diferença de maiúsculas)
    pub fn find(archive: Archive, name: []const u8) ?Entry {
        for (archive.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        return null;
    }

    /// o conteúdo de uma parte: guardada (0) ou comprimida com deflate (8)
    pub fn extract(archive: Archive, allocator: std.mem.Allocator, entry: Entry) ![]const u8 {
        const local = entry.local_offset;
        if (local + 30 > archive.bytes.len or !std.mem.eql(u8, archive.bytes[local..][0..4], "PK\x03\x04")) return ZipError.NotZip;
        const start = local + 30 + readInt(u16, archive.bytes, local + 26) + readInt(u16, archive.bytes, local + 28);
        if (start + entry.compressed > archive.bytes.len) return ZipError.NotZip;
        const data = archive.bytes[start..][0..entry.compressed];
        switch (entry.method) {
            0 => return data,
            8 => {
                const out = try allocator.alloc(u8, entry.size);
                var input: std.Io.Reader = .fixed(data);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var inflate: std.compress.flate.Decompress = .init(&input, .raw, &window);
                inflate.reader.readSliceAll(out) catch return ZipError.NotZip;
                return out;
            },
            else => return ZipError.UnsupportedCompression,
        }
    }
};

fn readInt(comptime Int: type, bytes: []const u8, at: usize) Int {
    return std.mem.readInt(Int, bytes[at..][0..@sizeOf(Int)], .little);
}


/// um zip montado na memória, parte por parte (guardadas, sem comprimir)
pub const Writer = struct {
    out: std.ArrayList(u8) = .empty,
    central: std.ArrayList(u8) = .empty,
    count: u16 = 0,

    /// acrescenta a parte `name` com o conteúdo `data` (copiado)
    pub fn add(writer: *Writer, allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
        const crc = std.hash.Crc32.hash(data);
        const offset: u32 = @intCast(writer.out.items.len);
        const size: u32 = @intCast(data.len);
        // cabeçalho local (APPNOTE 4.3.7): versão 2.0, sem bandeiras, método 0, hora e data zeradas
        try writeLocal(&writer.out, allocator, name, crc, size);
        try writer.out.appendSlice(allocator, data);
        // a entrada do diretório central (4.3.12)
        const central = &writer.central;
        try central.appendSlice(allocator, "PK\x01\x02");
        try appendInt(central, allocator, u16, 20); // feito por
        try appendInt(central, allocator, u16, 20); // versão para ler
        try appendInt(central, allocator, u16, 0x0800); // nomes em UTF-8
        try appendInt(central, allocator, u16, 0); // guardado
        try appendInt(central, allocator, u32, 0); // hora e data
        try appendInt(central, allocator, u32, crc);
        try appendInt(central, allocator, u32, size);
        try appendInt(central, allocator, u32, size);
        try appendInt(central, allocator, u16, @intCast(name.len));
        try appendInt(central, allocator, u16, 0); // extra
        try appendInt(central, allocator, u16, 0); // comentário
        try appendInt(central, allocator, u16, 0); // disco
        try appendInt(central, allocator, u16, 0); // atributos internos
        try appendInt(central, allocator, u32, 0); // atributos externos
        try appendInt(central, allocator, u32, offset);
        try central.appendSlice(allocator, name);
        writer.count += 1;
    }

    /// o zip inteiro: as partes, o diretório central e o registro do fim (4.3.16)
    pub fn finish(writer: *Writer, allocator: std.mem.Allocator) ![]const u8 {
        const central_offset: u32 = @intCast(writer.out.items.len);
        try writer.out.appendSlice(allocator, writer.central.items);
        const out = &writer.out;
        try out.appendSlice(allocator, "PK\x05\x06");
        try appendInt(out, allocator, u16, 0);
        try appendInt(out, allocator, u16, 0);
        try appendInt(out, allocator, u16, writer.count);
        try appendInt(out, allocator, u16, writer.count);
        try appendInt(out, allocator, u32, @intCast(writer.central.items.len));
        try appendInt(out, allocator, u32, central_offset);
        try appendInt(out, allocator, u16, 0);
        return out.items;
    }
};

fn writeLocal(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, crc: u32, size: u32) !void {
    try out.appendSlice(allocator, "PK\x03\x04");
    try appendInt(out, allocator, u16, 20);
    try appendInt(out, allocator, u16, 0x0800);
    try appendInt(out, allocator, u16, 0);
    try appendInt(out, allocator, u32, 0);
    try appendInt(out, allocator, u32, crc);
    try appendInt(out, allocator, u32, size);
    try appendInt(out, allocator, u32, size);
    try appendInt(out, allocator, u16, @intCast(name.len));
    try appendInt(out, allocator, u16, 0);
    try out.appendSlice(allocator, name);
}

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime Int: type, value: Int) !void {
    var bytes: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

test "um zip gravado aqui volta igual, parte por parte, e o CRC confere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var zip_out: Writer = .{};
    try zip_out.add(memory, "manifesto.zon", ".{ .versao = 1 }");
    try zip_out.add(memory, "imagens/vista.png", "\x89PNG...");
    const bytes = try zip_out.finish(memory);
    const archive = try Archive.open(memory, bytes);
    try std.testing.expectEqual(@as(usize, 2), archive.entries.len);
    try std.testing.expectEqualStrings(".{ .versao = 1 }", try archive.extract(memory, archive.find("manifesto.zon").?));
    try std.testing.expectEqualStrings("\x89PNG...", try archive.extract(memory, archive.find("imagens/vista.png").?));
    try std.testing.expect(archive.find("nada") == null);
    // o CRC-32 de "123456789" é 0xCBF43926 (o valor de conferência do CRC-32 da ISO-HDLC)
    try std.testing.expectEqual(@as(u32, 0xCBF43926), std.hash.Crc32.hash("123456789"));
}

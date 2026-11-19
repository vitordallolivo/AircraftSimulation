//! A ponte entre os dados em JSON (a árvore `std.json.Value`, como a Montagem e as etapas guardam o avião) e o texto
//! em ZON (a notação de objetos do Zig) dos arquivos próprios do programa (`.aero`). A conversão vale para qualquer
//! árvore, sem saber a forma dela, então nada se perde no caminho: um campo que só a tela conhece volta igual.
//!
//!     {"nome": "asa", "secoes": [{"corda": 0.3}], "simetrica": true}
//!     .{ .nome = "asa", .secoes = .{ .{ .corda = 0.3 } }, .simetrica = true }
//!
//! O ZON não separa objeto vazio de lista vazia (os dois são `.{}`): o objeto vazio dentro de um objeto não é
//! escrito (quem lê usa o padrão), e `.{}` volta como lista vazia.
const std = @import("std");

const Value = std.json.Value;

/// escreve a árvore `value` em ZON, com recuo de quatro espaços
pub fn write(writer: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    try writeValue(writer, value, 0);
    try writer.writeByte('\n');
}

/// a árvore em ZON (memória de `memory`)
pub fn toZon(memory: std.mem.Allocator, value: Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(memory);
    try write(&out.writer, value);
    return out.written();
}

/// o texto JSON em ZON
pub fn jsonToZon(memory: std.mem.Allocator, json: []const u8) ![]const u8 {
    const value = try std.json.parseFromSliceLeaky(Value, memory, json, .{});
    return toZon(memory, value);
}

fn indent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("    ");
}

fn isEmptyObject(value: Value) bool {
    return value == .object and value.object.count() == 0;
}

fn writeValue(writer: *std.Io.Writer, value: Value, depth: usize) std.Io.Writer.Error!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try writeFloat(writer, number),
        .number_string => |text| try writer.writeAll(text),
        .string => |text| try writeString(writer, text),
        .array => |list| {
            if (list.items.len == 0) return writer.writeAll(".{}");
            // lista curta de números: numa linha só (pontos, vetores)
            const flat = list.items.len <= 4 and for (list.items) |item| {
                if (item != .integer and item != .float and item != .number_string) break false;
            } else true;
            if (flat) {
                try writer.writeAll(".{ ");
                for (list.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writeValue(writer, item, depth);
                }
                return writer.writeAll(" }");
            }
            try writer.writeAll(".{\n");
            for (list.items) |item| {
                try indent(writer, depth + 1);
                try writeValue(writer, item, depth + 1);
                try writer.writeAll(",\n");
            }
            try indent(writer, depth);
            try writer.writeAll("}");
        },
        .object => |object| {
            var shown: usize = 0;
            for (object.values()) |item| {
                if (!isEmptyObject(item)) shown += 1;
            }
            if (shown == 0) return writer.writeAll(".{}");
            try writer.writeAll(".{\n");
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (isEmptyObject(entry.value_ptr.*)) continue;
                try indent(writer, depth + 1);
                try writer.print(".{f} = ", .{std.zig.fmtIdPU(entry.key_ptr.*)});
                try writeValue(writer, entry.value_ptr.*, depth + 1);
                try writer.writeAll(",\n");
            }
            try indent(writer, depth);
            try writer.writeAll("}");
        },
    }
}

/// um número com ponto ou expoente (para voltar como número real) e com todos os dígitos que o `f64` precisa
fn writeFloat(writer: *std.Io.Writer, number: f64) !void {
    if (!std.math.isFinite(number)) return writer.writeAll("null");
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return writer.print("{e}", .{number});
    try writer.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try writer.writeAll(".0");
}

/// um texto entre aspas: as letras acentuadas ficam como estão (UTF-8), o resto como o Zig escreve
fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |char| switch (char) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...31, 127 => try writer.print("\\x{x:0>2}", .{char}),
        else => try writer.writeByte(char),
    };
    try writer.writeByte('"');
}

pub const ReadError = error{ BadZon, OutOfMemory };

/// lê um texto ZON de volta para a árvore (memória de `memory`, que fica com tudo)
pub fn read(memory: std.mem.Allocator, text: []const u8) ReadError!Value {
    const source = try memory.dupeZ(u8, text);
    const tree = std.zig.Ast.parse(memory, source, .zon) catch return error.OutOfMemory;
    if (tree.errors.len > 0) return error.BadZon;
    const zoir = std.zig.ZonGen.generate(memory, tree, .{}) catch return error.OutOfMemory;
    if (zoir.hasCompileErrors()) return error.BadZon;
    return node(memory, zoir, .root);
}

/// o texto ZON como JSON
pub fn zonToJson(memory: std.mem.Allocator, text: []const u8) ![]const u8 {
    const value = try read(memory, text);
    return std.json.Stringify.valueAlloc(memory, value, .{});
}

fn node(memory: std.mem.Allocator, zoir: std.zig.Zoir, index: std.zig.Zoir.Node.Index) ReadError!Value {
    return switch (index.get(zoir)) {
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .null => .null,
        .pos_inf, .neg_inf, .nan => .null,
        .int_literal => |literal| switch (literal) {
            .small => |small| .{ .integer = small },
            .big => |big| if (big.toInt(i64)) |whole| .{ .integer = whole } else |_| .{ .float = big.toFloat(f64, .nearest_even)[0] },
        },
        .float_literal => |number| .{ .float = @floatCast(number) },
        .char_literal => |char| .{ .integer = char },
        .enum_literal => |name| .{ .string = try memory.dupe(u8, name.get(zoir)) },
        .string_literal => |text| .{ .string = try memory.dupe(u8, text) },
        .empty_literal => .{ .array = .init(memory) },
        .array_literal => |range| blk: {
            var list: std.json.Array = .init(memory);
            for (0..range.len) |i| try list.append(try node(memory, zoir, range.at(@intCast(i))));
            break :blk .{ .array = list };
        },
        .struct_literal => |literal| blk: {
            var object: std.json.ObjectMap = .empty;
            for (literal.names, 0..) |name, i| try object.put(memory, try memory.dupe(u8, name.get(zoir)), try node(memory, zoir, literal.vals.at(@intCast(i))));
            break :blk .{ .object = object };
        },
    };
}

test "JSON → ZON → JSON volta igual, com acentos, listas, números reais e inteiros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const json =
        \\{"name":"hélice 12x6","x":-0.105,"n":3,"inteiro_real":2.0,"lista":[1,2.5,{"a":"b"}],"vazio":[],"liga":true,"nada":null,"chave com espaço":1e-7,"texto":"linha\nnova \"aspas\""}
    ;
    const zon = try jsonToZon(memory, json);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = \"hélice 12x6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".@\"chave com ") != null);
    const back = try zonToJson(memory, zon);
    const expected = try std.json.parseFromSliceLeaky(Value, memory, json, .{});
    const got = try std.json.parseFromSliceLeaky(Value, memory, back, .{});
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(memory, expected, .{}), try std.json.Stringify.valueAlloc(memory, got, .{}));
}

test "o objeto vazio não é escrito; a lista vazia volta como lista" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const back = try zonToJson(memory, try jsonToZon(memory, "{\"ajustes\":{},\"alvos\":[]}"));
    try std.testing.expectEqualStrings("{\"alvos\":[]}", back);
}

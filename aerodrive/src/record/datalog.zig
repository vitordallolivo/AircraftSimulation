//! Dados de um voo gravado: as linhas do núcleo (todas as grandezas escalares do `LogRow`, mais
//! rpm/tração/corrente do 1º motor), a 20 Hz, em CSV com cabeçalho. `Table.parse` lê de volta
//! (por coluna, para os gráficos) e aceita arquivo truncado ou estranho sem travar.
const std = @import("std");
const core = @import("aerosim");
const fz = @import("../util/fuzz.zig");

const Row = core.types.LogRow;

/// nomes das colunas, na ordem do arquivo (comptime, a partir do LogRow)
pub const columns = blk: {
    var names: []const []const u8 = &.{};
    for (@typeInfo(Row).@"struct".fields) |f| {
        if (f.type == f64) names = names ++ .{f.name};
    }
    break :blk names ++ .{ "rpm0", "thrust0", "current0" };
};

pub const DataLog = struct {
    rows: std.ArrayList(f64) = .empty,
    period: f64 = 0.05, // s (20 Hz)
    last_t: f64 = -1e9,

    pub fn deinit(d: *DataLog, gpa: std.mem.Allocator) void {
        d.rows.deinit(gpa);
    }

    pub fn count(d: *const DataLog) usize {
        return d.rows.items.len / columns.len;
    }

    /// guarda a linha se passou um período desde a última (até ~3 h de voo)
    pub fn add(d: *DataLog, gpa: std.mem.Allocator, r: *const Row) !void {
        if (!(r.t - d.last_t >= d.period - 1e-9) or d.count() >= 200_000) return;
        d.last_t = r.t;
        var line: [columns.len]f64 = undefined;
        var i: usize = 0;
        inline for (@typeInfo(Row).@"struct".fields) |f| {
            if (f.type == f64) {
                line[i] = @field(r, f.name);
                i += 1;
            }
        }
        line[i] = r.rpm[0];
        line[i + 1] = r.thrust[0];
        line[i + 2] = r.current[0];
        try d.rows.appendSlice(gpa, &line);
    }

    pub fn writeCsv(d: *const DataLog, w: *std.Io.Writer) !void {
        for (columns, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(c);
        }
        try w.writeByte('\n');
        var k: usize = 0;
        while (k < d.rows.items.len) : (k += columns.len) {
            for (d.rows.items[k .. k + columns.len], 0..) |v, i| {
                if (i > 0) try w.writeByte(',');
                if (std.math.isFinite(v)) try w.print("{d}", .{v}) else try w.writeAll("nan");
            }
            try w.writeByte('\n');
        }
    }
};

/// tabela lida de um CSV: colunas de mesmo tamanho
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    names: [][]const u8,
    cols: [][]f64,

    pub fn deinit(t: *Table) void {
        t.arena.deinit();
    }

    pub fn rows(t: *const Table) usize {
        return if (t.cols.len > 0) t.cols[0].len else 0;
    }

    pub fn col(t: *const Table, name: []const u8) ?[]const f64 {
        for (t.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return t.cols[i];
        return null;
    }

    /// CSV com cabeçalho; célula ilegível = NaN; linha com menos células completa com NaN
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Table {
        var t: Table = .{ .arena = .init(gpa), .names = &.{}, .cols = &.{} };
        errdefer t.deinit();
        const a = t.arena.allocator();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const head = std.mem.trimEnd(u8, lines.next() orelse return error.EmptyTable, "\r");
        if (head.len == 0) return error.EmptyTable;
        var names: std.ArrayList([]const u8) = .empty;
        var hit = std.mem.splitScalar(u8, head, ',');
        while (hit.next()) |n| {
            if (names.items.len >= 512) return error.TooManyColumns;
            try names.append(a, try a.dupe(u8, std.mem.trim(u8, n, " ")));
        }
        const nc = names.items.len;
        var data: std.ArrayList(f64) = .empty;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            var it = std.mem.splitScalar(u8, line, ',');
            for (0..nc) |_| {
                const cell = it.next() orelse "";
                try data.append(a, std.fmt.parseFloat(f64, std.mem.trim(u8, cell, " ")) catch std.math.nan(f64));
            }
        }
        const nr = data.items.len / nc;
        const cols = try a.alloc([]f64, nc);
        for (cols, 0..) |*c, j| {
            c.* = try a.alloc(f64, nr);
            for (c.*, 0..) |*v, i| v.* = data.items[i * nc + j];
        }
        t.names = names.items;
        t.cols = cols;
        return t;
    }
};

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "grava a 20 Hz e lê de volta pelo nome" {
    var d: DataLog = .{};
    defer d.deinit(testing.allocator);
    var r: Row = std.mem.zeroes(Row);
    for (0..100) |i| { // 1 s a 100 Hz → 20 linhas
        r.t = @as(f64, @floatFromInt(i)) * 0.01;
        r.h = 2 * r.t;
        r.rpm[0] = 5000;
        try d.add(testing.allocator, &r);
    }
    try testing.expectEqual(@as(usize, 20), d.count());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try d.writeCsv(&out.writer);
    var t = try Table.parse(testing.allocator, out.written());
    defer t.deinit();
    try testing.expectEqual(@as(usize, 20), t.rows());
    try testing.expectApproxEqAbs(@as(f64, 2 * 0.95), t.col("h").?[19], 1e-9);
    try testing.expectEqual(@as(f64, 5000), t.col("rpm0").?[3]);
    try testing.expect(t.col("nada") == null);
}

fn fuzzParse(_: void, src: *fz.Src) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = src.bytes(&buf);
    if (src.boolean()) for (buf[0..n]) |*c| {
        c.* = "0123456789.,-e\nnatx "[c.* % 20]; // parece CSV
    };
    var t = Table.parse(testing.allocator, buf[0..n]) catch |e| {
        try testing.expect(e == error.EmptyTable or e == error.TooManyColumns);
        return;
    };
    defer t.deinit();
    for (t.cols) |c| try testing.expectEqual(t.rows(), c.len);
}

test "fuzz: leitura do CSV" {
    try fz.check({}, fuzzParse, .{});
}

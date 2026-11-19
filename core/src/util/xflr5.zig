//! A polar de avião exportada pelo XFLR5 (análise de avião por LLT, VLM1, VLM2 ou painéis; Polars → Export), lida
//! como mais um método na comparação. Não roda nada: só lê o arquivo de texto ou CSV. Usa as colunas alpha, CL, CD
//! (ou CDi + CDv), CDi e Cm. O C_m é em torno do CG que estava no XFLR5, não o da análise. Exemplo:
//!
//!     var polar = try xflr5.parse(arena, texto);
//!     const slope = polar.slope(polar.lift, 2.0);   // C_Lα (1/rad) perto de α = 2°
//!
//! O par de `read_plane_polar` de `aerosim/aero/xflr5_import.py`.
const std = @import("std");

pub const Error = error{NoTable};

/// o método que o XFLR5 usou, tirado do nome da polar
pub const Method = enum {
    lifting_line,
    vortex_lattice,
    panels,

    /// o nome curto do método, como aparece na tela
    pub fn label(method: Method) []const u8 {
        return switch (method) {
            .lifting_line => "LLT",
            .vortex_lattice => "VLM",
            .panels => "painéis",
        };
    }
};

/// a polar lida, em ordem de α (graus); a coluna que o arquivo não tem fica NaN
pub const Polar = struct {
    name: []const u8 = "",
    method: Method = .vortex_lattice,
    /// velocidade do escoamento (m/s), NaN se o arquivo não diz
    airspeed: f64 = std.math.nan(f64),
    alpha: []f64,
    lift: []f64,
    drag: []f64,
    induced: []f64,
    moment: []f64,

    /// a inclinação de `column` em α (1/rad), pelos mínimos quadrados com os pontos a até 3° de `alpha_center`
    /// (`np.polyfit` de grau 1 no Python); null com menos de dois pontos
    pub fn slope(polar: Polar, column: []const f64, alpha_center: f64) ?f64 {
        var count: f64 = 0;
        var sum_x: f64 = 0;
        var sum_y: f64 = 0;
        var sum_xx: f64 = 0;
        var sum_xy: f64 = 0;
        for (polar.alpha, column) |alpha, value| {
            if (@abs(alpha - alpha_center) > 3.0 or !std.math.isFinite(value)) continue;
            const x = std.math.degreesToRadians(alpha);
            count += 1;
            sum_x += x;
            sum_y += value;
            sum_xx += x * x;
            sum_xy += x * value;
        }
        const denominator = count * sum_xx - sum_x * sum_x;
        if (count < 2 or denominator == 0) return null;
        return (count * sum_xy - sum_x * sum_y) / denominator;
    }
};

const columns = [_][]const u8{ "alpha", "cl", "cd", "cdi", "cdv", "cm" };

/// lê o texto do arquivo exportado; a memória fica no `allocator`
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Polar {
    var name: []const u8 = "";
    var airspeed = std.math.nan(f64);
    var where = [_]?usize{null} ** columns.len;
    var head_found = false;
    var rows: std.ArrayList([columns.len]f64) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (afterLabel(line, &.{"polar name"})) |value| name = try allocator.dupe(u8, value);
        if (afterLabel(line, &.{ "freestream speed", "qinf" })) |value| {
            var parts = std.mem.tokenizeAny(u8, value, " \t");
            if (parts.next()) |number| airspeed = std.fmt.parseFloat(f64, number) catch airspeed;
        }
        var tokens: [64][]const u8 = undefined;
        var count: usize = 0;
        var split = std.mem.tokenizeAny(u8, line, ", \t;");
        while (split.next()) |token| : (count += 1) {
            if (count == tokens.len) break;
            tokens[count] = token;
        }
        if (!head_found) {
            for (tokens[0..count], 0..) |token, position| for (columns, 0..) |column, k| {
                if (where[k] == null and std.ascii.eqlIgnoreCase(token, column)) where[k] = position;
            };
            head_found = where[0] != null and where[1] != null;
            if (!head_found) where = [_]?usize{null} ** columns.len;
            continue;
        }
        if (count < 3) continue;
        var numbers: [64]f64 = undefined;
        const all_numbers = for (tokens[0..count], 0..) |token, k| {
            numbers[k] = std.fmt.parseFloat(f64, token) catch break false;
        } else true;
        if (!all_numbers) continue;
        var row: [columns.len]f64 = undefined;
        for (&row, where) |*value, position| value.* = if (position) |at| (if (at < count) numbers[at] else std.math.nan(f64)) else std.math.nan(f64);
        try rows.append(allocator, row);
    }
    if (!head_found or rows.items.len == 0) return Error.NoTable;
    std.mem.sort([columns.len]f64, rows.items, {}, struct {
        fn less(_: void, left: [columns.len]f64, right: [columns.len]f64) bool {
            return left[0] < right[0];
        }
    }.less);
    var polar: Polar = .{ .name = name, .airspeed = airspeed, .alpha = undefined, .lift = undefined, .drag = undefined, .induced = undefined, .moment = undefined };
    const fields = [_]*[]f64{ &polar.alpha, &polar.lift, &polar.drag, &polar.induced, &polar.moment };
    for (fields) |field| field.* = try allocator.alloc(f64, rows.items.len);
    var has_drag = false;
    for (rows.items, 0..) |row, i| {
        polar.alpha[i] = row[0];
        polar.lift[i] = row[1];
        polar.drag[i] = row[2];
        polar.induced[i] = row[3];
        polar.moment[i] = row[5];
        has_drag = has_drag or std.math.isFinite(row[2]);
    }
    // sem a coluna CD, o arrasto é o induzido mais o viscoso
    if (!has_drag) for (rows.items, 0..) |row, i| {
        polar.drag[i] = row[3] + row[4];
    };
    polar.method = if (containsIgnoreCase(name, "panel")) .panels else if (containsIgnoreCase(name, "llt")) .lifting_line else .vortex_lattice;
    return polar;
}

/// o texto depois de "rótulo :" na linha, se ela começa (em qualquer caixa) por um dos rótulos
fn afterLabel(line: []const u8, labels: []const []const u8) ?[]const u8 {
    for (labels) |label| {
        const at = indexOfIgnoreCase(line, label) orelse continue;
        const rest = std.mem.trimStart(u8, line[at + label.len ..], " \t");
        if (rest.len == 0 or rest[0] != ':') continue;
        return std.mem.trim(u8, rest[1..], " \t");
    }
    return null;
}

fn indexOfIgnoreCase(text: []const u8, wanted: []const u8) ?usize {
    if (wanted.len > text.len) return null;
    for (0..text.len - wanted.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..wanted.len], wanted)) return i;
    return null;
}

fn containsIgnoreCase(text: []const u8, wanted: []const u8) bool {
    return indexOfIgnoreCase(text, wanted) != null;
}

test "polar do XFLR5 em texto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\xflr5 v6.61
        \\
        \\Plane name :  T1
        \\Polar name :  T1-15.0 m/s-VLM2
        \\Freestream speed : 15.000 m/s
        \\
        \\   alpha      Beta       CL          CDi        CDv        CD         CY         Cl         Cm         Cn
        \\ ---------  ---------  ---------  ---------  ---------  ---------  ---------  ---------  ---------  ---------
        \\   2.000      0.000     0.5500     0.0110     0.0150     0.0260     0.0000     0.0000    -0.0300     0.0000
        \\   0.000      0.000     0.3500     0.0050     0.0140     0.0190     0.0000     0.0000    -0.0100     0.0000
        \\   4.000      0.000     0.7500     0.0200     0.0160     0.0360     0.0000     0.0000    -0.0500     0.0000
    ;
    const polar = try parse(arena.allocator(), text);
    try std.testing.expectEqualStrings("T1-15.0 m/s-VLM2", polar.name);
    try std.testing.expectEqual(Method.vortex_lattice, polar.method);
    try std.testing.expectEqual(@as(f64, 15), polar.airspeed);
    try std.testing.expectEqualSlices(f64, &.{ 0, 2, 4 }, polar.alpha);
    try std.testing.expectEqual(@as(f64, 0.026), polar.drag[1]);
    // C_L sobe 0,1 por grau: C_Lα = 0,1 · 180/π
    try std.testing.expectApproxEqRel(@as(f64, 0.1 * 180.0 / std.math.pi), polar.slope(polar.lift, 2).?, 1e-12);
}

test "sem tabela" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.NoTable, parse(arena.allocator(), "nada aqui\n1 2 3\n"));
}

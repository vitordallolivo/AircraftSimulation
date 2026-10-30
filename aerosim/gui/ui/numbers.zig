//! Números na tela sem janela (testáveis): o texto curto de um campo e as marcas "redondas" dos eixos.
const std = @import("std");

/// um número curto para o campo: até 4 algarismos depois do ponto, sem zeros sobrando
pub fn numberText(buffer: []u8, value: f64) [:0]const u8 {
    const text = std.fmt.bufPrint(buffer[0 .. buffer.len - 1], "{d:.4}", .{value}) catch return "…";
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        while (end > 0 and text[end - 1] == '0') end -= 1;
        if (end > 0 and text[end - 1] == '.') end -= 1;
    }
    if (end == 2 and text[0] == '-' and text[1] == '0') end = 1; // "-0" vira "0"
    if (end == 1 and text[0] == '-') {
        buffer[0] = '0';
    }
    buffer[end] = 0;
    return buffer[0..end :0];
}

/// passo de marca "redondo" (1, 2 ou 5 × 10ⁿ) que dá umas `target` divisões em `span`
pub fn niceStep(span: f64, target: f64) f64 {
    if (!(span > 0) or !std.math.isFinite(span)) return 1;
    const raw = span / target;
    const magnitude = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const fraction = raw / magnitude;
    const nice: f64 = if (fraction < 1.5) 1 else if (fraction < 3.5) 2 else if (fraction < 7.5) 5 else 10;
    return nice * magnitude;
}

/// casas decimais para escrever as marcas de passo `step`
pub fn decimalsFor(step: f64) usize {
    if (!(step > 0)) return 0;
    const digits = -@floor(std.math.log10(step));
    return @intFromFloat(std.math.clamp(digits, 0, 6));
}

/// faixa de um eixo: os extremos dos dados com uma folga, ou (0, 1) se não houver dados
pub const Range = struct {
    low: f64,
    high: f64,

    /// a faixa de `values` (ignora NaN e infinitos) com `margin` (fração) de folga dos dois lados
    pub fn of(values: []const f64, margin: f64) Range {
        var low = std.math.inf(f64);
        var high = -std.math.inf(f64);
        for (values) |v| if (std.math.isFinite(v)) {
            low = @min(low, v);
            high = @max(high, v);
        };
        if (!(low <= high)) return .{ .low = 0, .high = 1 };
        if (low == high) return .{ .low = low - 0.5, .high = high + 0.5 };
        const pad = (high - low) * margin;
        return .{ .low = low - pad, .high = high + pad };
    }

    /// junta duas faixas
    pub fn merge(a: Range, b: Range) Range {
        return .{ .low = @min(a.low, b.low), .high = @max(a.high, b.high) };
    }
};

test "número do campo sem zeros sobrando" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12", numberText(&buffer, 12.0));
    try std.testing.expectEqualStrings("0.25", numberText(&buffer, 0.25));
    try std.testing.expectEqualStrings("-4", numberText(&buffer, -4.0));
    try std.testing.expectEqualStrings("1.2346", numberText(&buffer, 1.23456));
    try std.testing.expectEqualStrings("0", numberText(&buffer, -0.00001));
}

test "passo redondo das marcas" {
    try std.testing.expectEqual(@as(f64, 5), niceStep(26, 5)); // α de -4 a 22
    try std.testing.expectEqual(@as(f64, 0.5), niceStep(2.2, 5)); // C_L de 0 a 2,2
    try std.testing.expectApproxEqRel(@as(f64, 0.02), niceStep(0.1, 5), 1e-12);
    try std.testing.expectEqual(@as(usize, 2), decimalsFor(0.02));
    try std.testing.expectEqual(@as(usize, 0), decimalsFor(5));
}

test "faixa ignora NaN e dá folga" {
    const values = [_]f64{ 1, std.math.nan(f64), 3 };
    const range = Range.of(&values, 0.05);
    try std.testing.expectApproxEqRel(@as(f64, 0.9), range.low, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 3.1), range.high, 1e-12);
}

/// um número com `digits` algarismos significativos, como o `{:.4g}` do Python: em notação científica
/// ("3.47e+05") quando o expoente passa de `digits` − 1 ou fica abaixo de −4; "—" se não é finito
pub fn significant(buffer: []u8, value: f64, comptime digits: i32) []const u8 {
    if (!std.math.isFinite(value)) return "—";
    if (value == 0) return "0";
    const exponent: i32 = @intFromFloat(@floor(std.math.log10(@abs(value))));
    if (exponent < -4 or exponent >= digits) {
        const mantissa = value / std.math.pow(f64, 10, @floatFromInt(exponent));
        var head: [32]u8 = undefined;
        const text = trimZeros(std.fmt.bufPrint(&head, "{d:.[1]}", .{ mantissa, @as(usize, @intCast(digits - 1)) }) catch return "");
        return std.fmt.bufPrint(buffer, "{s}e{s}{d:0>2}", .{ text, if (exponent < 0) "-" else "+", @abs(exponent) }) catch "";
    }
    const decimals: usize = @intCast(@max(0, digits - 1 - exponent));
    var head: [64]u8 = undefined;
    const text = trimZeros(std.fmt.bufPrint(&head, "{d:.[1]}", .{ value, decimals }) catch return "");
    if (text.len > buffer.len) return "";
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

fn trimZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (text[end - 1] == '0') end -= 1;
    if (text[end - 1] == '.') end -= 1;
    return text[0..end];
}

test "algarismos significativos como o .4g do Python" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3.47e+05", significant(&buffer, 347000.39, 4));
    try std.testing.expectEqualStrings("12.4", significant(&buffer, 12.4, 4));
    try std.testing.expectEqualStrings("0.3622", significant(&buffer, 0.362216, 4));
    try std.testing.expectEqualStrings("-1.677", significant(&buffer, -1.676747, 4));
    try std.testing.expectEqualStrings("1.2e-05", significant(&buffer, 0.000012, 4));
    try std.testing.expectEqualStrings("2400", significant(&buffer, 2400, 4));
}

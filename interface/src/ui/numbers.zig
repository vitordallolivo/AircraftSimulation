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

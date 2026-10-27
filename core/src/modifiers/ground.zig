//! Efeito solo: métodos para o fator do arrasto induzido perto do chão.
//!
//! McCormick (padrão; o que o núcleo sempre usou):
//!   φ = (16 h/b)² / (1 + (16 h/b)²),   C_Di(solo) = φ · C_Di
//! B. W. McCormick, *Aerodynamics, Aeronautics, and Flight Mechanics* (Wiley); a mesma expressão é usada
//! por J. D. Anderson, *Aircraft Performance and Design* (McGraw-Hill), citando o McCormick.
//! h: altura do painel acima do chão; b: envergadura de referência.
const fmath = @import("../math/fmath.zig");
const modifier_types = @import("types.zig");

/// fator do arrasto induzido do método `method` (`Params.ground`, número de `modifier_types.Ground`) a uma altura `height` (m)
/// com envergadura `span` (m)
pub inline fn factor(method: i32, height: f64, span: f64) f64 {
    return switch (@as(modifier_types.Ground, @enumFromInt(method))) {
        .mccormick => mccormick(height, span),
        .off, _ => 1.0,
    };
}

/// φ de McCormick (ver o cabeçalho). height ≤ 0,01 m é tratado como 0,01 m (o painel não atravessa o chão)
pub inline fn mccormick(height: f64, span: f64) f64 {
    const r16 = 16.0 * @max(height, 0.01) / span;
    return r16 * r16 / (1.0 + r16 * r16);
}

const std = @import("std");
const testing = std.testing;

test "McCormick: valores da fórmula e limites" {
    // h/b = 0,1: (1,6)² / (1 + 1,6²) = 2,56 / 3,56
    try testing.expectApproxEqAbs(2.56 / 3.56, mccormick(0.22, 2.2), 1e-12);
    // longe do chão o fator tende a 1; perto, a 0
    try testing.expect(mccormick(100.0, 2.0) > 0.9999);
    try testing.expect(mccormick(0.0, 2.0) < 0.01);
    // desligado: 1
    try testing.expectEqual(@as(f64, 1.0), factor(@intFromEnum(modifier_types.Ground.off), 0.1, 2.0));
    try testing.expectEqual(mccormick(0.3, 2.0), factor(@intFromEnum(modifier_types.Ground.mccormick), 0.3, 2.0));
}

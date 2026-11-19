//! Os métodos fixos do AeroDrive, num lugar só.
//!
//! Na interface do aerosim o usuário escolhe os métodos de cada análise (`core.methods.Methods`: o modelo
//! aerodinâmico do voo, a variante da linha sustentadora e o refino). O AeroDrive voa em tempo real (a física a 120 Hz
//! é o piso para continuar jogável), então ele fixa os que cabem nesse tempo e não lê essas escolhas do arquivo. Os
//! efeitos a mais (efeito solo, esteira, interferência entre asas) vêm do arquivo, como na interface (`modifiers.zig`).
//! Trocar um método do AeroDrive é mudar `fixed` aqui; nada mais no tradutor muda.
const core = @import("aerosim");

/// os métodos do AeroDrive: faixas (a linha sustentadora resolve um sistema por passo) e o refino padrão do núcleo
pub const fixed: core.methods.Methods = .{ .aero_model = .strips };

test "os métodos fixos são os padrões do núcleo" {
    const std = @import("std");
    var params: core.types.Params = .{};
    fixed.apply(&params);
    try std.testing.expectEqual(core.types.AeroModel.strips, params.aero_model);
    try std.testing.expectEqual(core.methods.Methods{}, fixed);
}

//! Os métodos fixos do AeroDrive, num lugar só.
//!
//! Na GUI o usuário escolhe o modelo aerodinâmico do voo e o refino de cada análise. O AeroDrive voa em tempo real
//! (a física a 120 Hz é o piso para continuar jogável), então ele fixa os métodos que cabem nesse tempo e não lê
//! essas escolhas do arquivo. Os efeitos a mais (efeito solo, esteira, interferência entre asas) vêm do arquivo, como
//! na GUI (`modifiers.zig`). Trocar um método do AeroDrive é mudar `fixed` aqui; nada mais no tradutor muda.
const core = @import("aerosim");
const types = core.types;

/// as escolhas de método que o AeroDrive não deixa para o arquivo
pub const Methods = struct {
    /// quem dá as forças no voo: faixas (o modelo mais barato; a linha sustentadora resolve um sistema por passo)
    aero_model: types.AeroModel,
    /// o refino das contas do núcleo (amostras da esteira)
    refinement: types.Refinement,
};

/// os métodos do AeroDrive: faixas e o refino padrão do núcleo
pub const fixed: Methods = .{ .aero_model = .strips, .refinement = .{} };

/// escreve os métodos em `params`
pub fn apply(methods: Methods, params: *types.Params) void {
    params.aero_model = methods.aero_model;
    params.refinement = methods.refinement;
}

test "os métodos fixos são os padrões do núcleo" {
    const std = @import("std");
    var params: types.Params = .{};
    apply(fixed, &params);
    try std.testing.expectEqual(types.AeroModel.strips, params.aero_model);
    try std.testing.expectEqual(@as(i32, 3), params.refinement.slipstream_chord_samples);
}

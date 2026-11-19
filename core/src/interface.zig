//! A interface conferida em comptime: o molde dos registros do projeto.
//!
//! Um registro é uma lista de tipos (`pub const all = .{A, B, C}`), e cada tipo da lista tem as mesmas declarações
//! com as mesmas assinaturas. Quem consome percorre a lista com `inline for` e nunca pergunta "de que tipo é este?".
//! Faltar uma declaração ou errar uma assinatura é erro de compilação, com o nome do tipo e do que falta, em vez de
//! um erro na hora de rodar. Usam este molde os tipos de aeronave do dimensionamento (`sizing/kinds.zig`) e as
//! análises das telas (`aerosim/interfaces/simulation.zig`).
const std = @import("std");

/// uma declaração que o tipo tem de ter: o nome e o tipo exato (ou `null`, qualquer tipo)
pub const Declaration = struct {
    name: []const u8,
    type: ?type = null,
};

/// confere em comptime que `Implementation` tem cada declaração de `required`, com o tipo pedido; `what` diz o que o
/// tipo devia ser ("tipo de aeronave", "análise"), para a mensagem de erro
pub fn require(comptime Implementation: type, comptime what: []const u8, comptime required: []const Declaration) void {
    comptime {
        for (required) |declaration| {
            if (!@hasDecl(Implementation, declaration.name))
                @compileError(what ++ " " ++ @typeName(Implementation) ++ " sem `" ++ declaration.name ++ "`");
            const Expected = declaration.type orelse continue;
            const Actual = @TypeOf(@field(Implementation, declaration.name));
            if (Actual != Expected)
                @compileError(what ++ " " ++ @typeName(Implementation) ++ ": `" ++ declaration.name ++ "` é " ++
                    @typeName(Actual) ++ ", devia ser " ++ @typeName(Expected));
        }
    }
}

/// a declaração opcional existe? (para os ganchos que um tipo pode não ter)
pub fn has(comptime Implementation: type, comptime name: []const u8) bool {
    return @hasDecl(Implementation, name);
}

test "require aceita quem tem tudo" {
    const Good = struct {
        pub const name = "bom";
        pub fn twice(value: f64) f64 {
            return 2 * value;
        }
    };
    require(Good, "exemplo", &.{ .{ .name = "name" }, .{ .name = "twice", .type = fn (f64) f64 } });
    try std.testing.expect(has(Good, "twice") and !has(Good, "thrice"));
}

//! Os métodos de cálculo do voo, juntos: quem dá as forças, qual linha sustentadora e quanto refino.
//!
//! Cada um destes é uma escolha exclusiva (um por vez) que já existe solta em `types.Params`. Juntos numa struct,
//! viram uma coisa só para escolher e para gravar: a interface deixa o usuário escolher (os nomes saem dos próprios
//! `enum`, `choices`), e o AeroDrive fixa os seus num arquivo (`aerodrive/src/sim/methods.zig`), porque o voo em tempo
//! real precisa caber em 120 passos por segundo. O efeito solo não está aqui: ele vem da lista de modificadores do avião
//! (`modifiers/`), como na GUI.
const std = @import("std");
const types = @import("types.zig");

/// as escolhas de método de uma conta do voo; o padrão é o de sempre (faixas, Phillips e Snyder, refino padrão)
pub const Methods = struct {
    /// quem dá as forças na dinâmica, na trimagem e na linearização
    aero_model: types.AeroModel = .strips,
    /// a variante da linha sustentadora (só vale com `aero_model = .lifting_line`)
    llt_method: types.LiftingLineMethod = .phillips_snyder,
    /// o refino das contas (amostras da esteira)
    refinement: types.Refinement = .{},

    /// escreve os métodos em `params` (o resto de `params` não muda)
    pub fn apply(methods: Methods, params: *types.Params) void {
        params.aero_model = methods.aero_model;
        params.llt_method = methods.llt_method;
        params.refinement = methods.refinement;
    }

    /// os métodos que `params` usa agora
    pub fn of(params: *const types.Params) Methods {
        return .{ .aero_model = params.aero_model, .llt_method = params.llt_method, .refinement = params.refinement };
    }
};

/// o nome de um método na tela, em português (o do `enum` fica para o código e para a ABI)
pub fn label(method: anytype) []const u8 {
    return switch (@TypeOf(method)) {
        types.AeroModel => switch (method) {
            .strips => "faixas",
            .lifting_line => "linha sustentadora",
            .table => "tabela",
            _ => "faixas",
        },
        types.LiftingLineMethod => switch (method) {
            .phillips_snyder => "Phillips e Snyder",
            .goates_hunsaker => "Goates e Hunsaker",
            .nonlinear => "não linear",
            _ => "Phillips e Snyder",
        },
        else => @compileError("método sem nome na tela: " ++ @typeName(@TypeOf(method))),
    };
}

/// os nomes na tela de um `enum` de método, na ordem dos números (sem o `_` de outra versão): as opções de uma escolha
pub fn choices(comptime Method: type) []const []const u8 {
    return comptime blk: {
        const fields = @typeInfo(Method).@"enum".fields;
        var names: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| names[i] = label(@as(Method, @enumFromInt(field.value)));
        const frozen = names;
        break :blk &frozen;
    };
}

/// o método pelo nome na tela ou pelo nome do `enum` (null: não existe)
pub fn byName(comptime Method: type, name: []const u8) ?Method {
    inline for (@typeInfo(Method).@"enum".fields) |field| {
        const method: Method = @enumFromInt(field.value);
        if (std.mem.eql(u8, name, label(method))) return method;
    }
    return std.meta.stringToEnum(Method, name);
}

const testing = std.testing;

test "padrão: os métodos de sempre, e apply/of vão e voltam" {
    var params: types.Params = .{};
    const methods: Methods = .{ .aero_model = .lifting_line, .llt_method = .nonlinear };
    methods.apply(&params);
    try testing.expectEqual(methods, Methods.of(&params));
    try testing.expectEqual(types.AeroModel.strips, (Methods{}).aero_model);
}

test "as escolhas saem dos nomes do enum" {
    const names = choices(types.AeroModel);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("linha sustentadora", names[1]);
    try testing.expectEqual(types.AeroModel.table, byName(types.AeroModel, "table").?);
    try testing.expectEqual(types.AeroModel.table, byName(types.AeroModel, "tabela").?);
    try testing.expectEqual(types.LiftingLineMethod.goates_hunsaker, byName(types.LiftingLineMethod, "Goates e Hunsaker").?);
    try testing.expect(byName(types.AeroModel, "xyz") == null);
}

//! O que a esquerda do aeroopt mostra do problema sem desenhar nada: os nomes dos métodos de cada etapa, as
//! categorias, os resumos ao lado dos botões e o "isolar" de um grupo de variáveis (separado da tela para os testes
//! rodarem sem janela).
const std = @import("std");
const registry = @import("registry");
const problem_mod = @import("problem.zig");
const inputs = @import("inputs.zig");

const Problem = problem_mod.Problem;

/// uma parte do problema: um botão da esquerda e o submenu dele
pub const Part = enum {
    score,
    variables,
    constraints,
    categories,
    settings,

    /// o texto do botão
    pub fn caption(part: Part) [:0]const u8 {
        return switch (part) {
            .score => "Pontuação…",
            .variables => "Variáveis…",
            .constraints => "Restrições…",
            .categories => "Categorias…",
            .settings => "Configuração…",
        };
    }

    /// o título do submenu
    pub fn title(part: Part) [:0]const u8 {
        return switch (part) {
            .score => "Pontuação: o arquivo do regulamento ou um objetivo simples",
            .variables => "Variáveis: tudo o que se escolhe nas etapas (livre, limites ou a lista marcada)",
            .constraints => "Restrições, geometria e estabilidade",
            .categories => "Categorias: os tipos de avião que a busca experimenta",
            .settings => "Configuração: as etapas e o método de cada uma",
        };
    }
};

/// um método: a chave que o `.opt.json` guarda e o nome na tela
pub const Method = struct { key: []const u8, label: [:0]const u8 };

pub const configuration_methods = [_]Method{ .{ .key = "gerações", .label = "gerações" }, .{ .key = "todas", .label = "todas as combinações" } };
pub const fly_methods = [_]Method{
    .{ .key = "buscar", .label = "gerações" },                  .{ .key = "cma-es", .label = "CMA-ES" },
    .{ .key = "de", .label = "evolução diferencial" },          .{ .key = "reparo", .label = "reparo por gradiente" },
    .{ .key = "εde", .label = "ε-restrito (εDE)" },             .{ .key = "cultural", .label = "algoritmo cultural" },
    .{ .key = "lem", .label = "LEM (regra aprendida)" },        .{ .key = "diagnóstico", .label = "diagnóstico da falha (bandido)" },
    .{ .key = "conferir", .label = "só conferir" },             .{ .key = "desligada", .label = "desligada" },
};
pub const surface_methods = [_]Method{
    .{ .key = "coordenadas", .label = "coordenadas" }, .{ .key = "gerações", .label = "gerações" },
    .{ .key = "cma-es", .label = "CMA-ES" },           .{ .key = "de", .label = "evolução diferencial" },
    .{ .key = "substituto", .label = "substituto" },
};
pub const takeoff_methods = [_]Method{ .{ .key = "6gdl", .label = "6GDL" }, .{ .key = "pista", .label = "pista" } };
pub const sensitivity_methods = [_]Method{ .{ .key = "local", .label = "modelo local" }, .{ .key = "eixos", .label = "um por vez" }, .{ .key = "morris", .label = "Morris" } };

/// as categorias de avião que a busca conhece (os nomes antigos, de problemas gravados, aparecem só se o arquivo
/// tiver)
pub const categories = [_][]const u8{ "monoplano", "biplano", "tandem", "asa voadora" };
pub const legacy_categories = [_][]const u8{ "asa alta", "asa média", "asa baixa", "parasol", "cauda em V" };
pub const max_category_fields = categories.len + legacy_categories.len;

/// isola um grupo: as numéricas dele ficam livres e as dos outros presas (`null`: todas presas); as listas não
/// mudam
pub fn isolate(opened: *Problem, group: ?inputs.Group) void {
    for (opened.variables) |*variable| {
        if (variable.kind == .list) continue;
        variable.free = group != null and inputs.groupOf(variable) == group.?;
    }
}



pub fn categoryLabel(name: []const u8) [:0]const u8 {
    inline for (categories ++ legacy_categories) |known| if (std.mem.eql(u8, known, name)) return known ++ "";
    return "?";
}

pub fn hasCategory(opened: *const Problem, name: []const u8) bool {
    const list = opened.param("categorias") orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    return false;
}

/// as opções de um menu de métodos no formato do raygui ("a;b;c"), montadas na compilação
pub fn choiceList(comptime methods: []const Method) [:0]const u8 {
    comptime {
        var joined: [:0]const u8 = "";
        for (methods, 0..) |method, i| joined = joined ++ (if (i > 0) ";" else "") ++ method.label;
        return joined;
    }
}

pub fn methodIndex(methods: []const Method, key: []const u8) i32 {
    for (methods, 0..) |method, i| if (std.mem.eql(u8, method.key, key)) return @intCast(i);
    return 0;
}

pub fn methodLabel(methods: []const Method, key: []const u8) []const u8 {
    for (methods) |method| if (std.mem.eql(u8, method.key, key)) return method.label;
    return key;
}

pub fn section_of(opened: *const Problem, name: []const u8) ?std.json.ObjectMap {
    const value = opened.param(name) orelse return null;
    return if (value == .object) value.object else null;
}

pub fn text(object: ?std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const value = (object orelse return default).get(key) orelse return default;
    return if (value == .string) value.string else default;
}

pub fn number(object: ?std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const value = (object orelse return default).get(key) orelse return default;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => default,
    };
}

pub fn boolean(object: ?std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = (object orelse return default).get(key) orelse return default;
    return if (value == .bool) value.bool else default;
}

/// um número curto ("1.4", "13", "0.025")
fn short(value: f64) ShortNumber {
    return .{ .value = value };
}

const ShortNumber = struct {
    value: f64,
    pub fn format(self: ShortNumber, out: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.value == @round(self.value) and @abs(self.value) < 1e9) return out.print("{d:.0}", .{self.value});
        var buffer: [32]u8 = undefined;
        const written = std.fmt.bufPrint(&buffer, "{d:.4}", .{self.value}) catch return out.print("{d}", .{self.value});
        var end = written.len;
        while (end > 0 and written[end - 1] == '0') end -= 1;
        try out.writeAll(written[0..end]);
    }
};

/// o resumo de uma parte do problema (o texto ao lado do botão), como a tela antiga mostrava
pub fn writeSummary(out: *std.Io.Writer, opened: *const Problem, part: Part) !void {
    switch (part) {
        .score => try out.print("{s}", .{opened.scoring}),
        .variables => {
            var any = false;
            for (opened.variables) |variable| {
                if (!variable.free) continue;
                if (any) try out.writeAll("; ");
                any = true;
                const label = inputs.label(variable.key);
                if (variable.kind == .list) {
                    try out.print("{s}: ", .{label});
                    if (variable.options.len == 0) try out.writeAll("todos") else for (variable.options, 0..) |option, i| try out.print("{s}{s}", .{ if (i > 0) ", " else "", option });
                } else try out.print("{s} {f}…{f}", .{ label, short(variable.lower), short(variable.upper) });
            }
            if (!any) try out.writeAll("nenhuma livre: o avião como está");
        },
        .constraints => {
            var any = false;
            for (opened.constraints) |constraint| {
                if (!constraint.active) continue;
                if (any) try out.writeAll("; ");
                any = true;
                try out.print("{s} {s} {f}", .{ registry.quantity(constraint.key).label, constraint.comparison.symbol(), short(constraint.value) });
            }
            if (!any) try out.writeAll("nenhuma ligada");
            const geometry = section_of(opened, "geometria");
            if (boolean(geometry, "ligada", true)) {
                try out.print("; geometria com rotação de {f}°", .{short(number(geometry, "rotação", 12))});
                if (boolean(geometry, "uma_peça", false)) try out.writeAll("; uma peça só");
            }
            const stability = section_of(opened, "estabilidade");
            if (boolean(stability, "ligada", false)) try out.print("; estabilidade até o nível {f}", .{short(number(stability, "nível", 2))});
        },
        .categories => {
            const list = opened.param("categorias");
            var any = false;
            if (list) |value| if (value == .array) for (value.array.items) |item| if (item == .string) {
                if (any) try out.writeAll(", ");
                any = true;
                try out.writeAll(item.string);
            };
            if (!any) try out.writeAll("o avião dos rascunhos");
        },
        .settings => {
            const stages = section_of(opened, "etapas");
            if (std.mem.eql(u8, text(stages, "configurações", "gerações"), "gerações"))
                try out.print("gerações: {f} × {f}", .{ short(number(stages, "gerações", 8)), short(number(stages, "população", 16)) })
            else
                try out.writeAll("todas as combinações");
            try out.print("; voa: {s}", .{methodLabel(&fly_methods, text(stages, "voa", "buscar"))});
            try out.print("; superfícies por {s} ({f} pontos)", .{ methodLabel(&surface_methods, text(stages, "superfícies", "coordenadas")), short(number(stages, "avaliações", 12)) });
            try out.print("; decolagem {s}", .{if (std.mem.eql(u8, text(stages, "decolagem", "6gdl"), "6gdl")) "no 6GDL" else "só na pista"});
            const sensitivity = section_of(opened, "sensibilidade");
            if (boolean(sensitivity, "ligada", true))
                try out.print("; sensibilidade: {s}", .{methodLabel(&sensitivity_methods, text(sensitivity, "método", "local"))})
            else
                try out.writeAll("; sem sensibilidade");
        },
    }
}

test "resumos do problema Micro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sample =
        \\{"formato":"aeroopt/1","name":"teste","scoring":"sae","evaluator":"etapas",
        \\ "variables":[{"key":"wing.span","kind":"contínua","lo":1.4,"hi":1.85,"group":"asa","free":true},
        \\  {"key":"power.motor","kind":"lista","options":["A","B"],"group":"propulsão","free":true},
        \\  {"key":"tail.arm","kind":"contínua","lo":0.5,"hi":1.2,"group":"empenagem","free":true}],
        \\ "constraints":[{"key":"V_S","op":"≤","value":13,"active":true},{"key":"RC","op":"≥","value":1,"active":false}],
        \\ "params":{"categorias":["monoplano","tandem"],"geometria":{"ligada":true,"rotação":12},
        \\  "etapas":{"configurações":"gerações","população":16,"gerações":20,"voa":"buscar","superfícies":"de","avaliações":24,"decolagem":"6gdl"}}}
    ;
    var opened = try problem_mod.parse(arena.allocator(), sample);
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeSummary(&out, &opened, .variables);
    try std.testing.expectEqualStrings("envergadura 1.4…1.85; motor: A, B; braço da cauda 0.5…1.2", out.buffered());
    out = .fixed(&buffer);
    try writeSummary(&out, &opened, .constraints);
    try std.testing.expectEqualStrings("velocidade de estol ≤ 13; geometria com rotação de 12°", out.buffered());
    out = .fixed(&buffer);
    try writeSummary(&out, &opened, .settings);
    try std.testing.expectEqualStrings("gerações: 20 × 16; voa: gerações; superfícies por evolução diferencial (24 pontos); decolagem no 6GDL; sensibilidade: modelo local", out.buffered());
    isolate(&opened, .wing);
    try std.testing.expect(opened.variable("wing.span").?.free and !opened.variable("tail.arm").?.free and opened.variable("power.motor").?.free);
}

//! As grandezas do projeto e o que se faz com elas, como `aerosim/design/registry.py`: o que dá para medir
//! (`Quantity`: nome, unidade e a etapa que calcula), restringir (`Constraint`: grandeza, operador, valor, ligada
//! ou não) ou variar (`Variable`: uma entrada das etapas que fica fixa, variável entre mín. e máx. ou calculada).
//! As etapas devolvem os valores que calcularam (`Values`) e as restrições ativas são conferidas contra eles; a
//! restrição desligada guarda o valor para quando for ligada de novo. Aqui não há janela, então tudo tem teste.
//!
//!   Constraint{ .quantity = .span, .op = .at_most, .value = 2.5 }.holds(2.4)   // verdadeiro: "2,4 ≤ 2,5 m"
const std = @import("std");

/// uma grandeza que alguma etapa calcula: o nome, a unidade, a etapa, a explicação e o que mexer quando falha
pub const Info = struct {
    label: []const u8,
    unit: []const u8 = "",
    stage: Stage,
    help: []const u8 = "",
    fix: []const u8 = "",
};

/// a etapa que calcula a grandeza (a Montagem também confere as do Desempenho)
pub const Stage = enum { asa, montagem, desempenho };

/// as grandezas, na ordem do `QUANTITIES` da GUI em Python
pub const Quantity = enum {
    area,
    span,
    aspect_ratio,
    root_chord,
    stall_speed,
    surfaces,
    length,
    motor_power,
    motors,
    liquid_mass,
    lapes_mass,
    ballast_mass,
    static_margin,
    takeoff_run,
    top_speed,
    climb_rate,
    thrust_to_weight,
    turn_load,
    climb_gradient,
    ceiling,
    landing_run,
    mass,
    empty_mass,
    payload,
    structural_efficiency,
    mtow,

    /// o nome, a unidade e a etapa da grandeza
    pub fn info(quantity: Quantity) Info {
        return switch (quantity) {
            .area => .{ .label = "área da asa", .unit = "m²", .stage = .asa, .help = "área em planta das duas semiasas", .fix = "envergadura/corda" },
            .span => .{ .label = "envergadura", .unit = "m", .stage = .asa, .help = "de ponta a ponta", .fix = "menos envergadura (mais corda para manter a área)" },
            .aspect_ratio => .{ .label = "alongamento", .stage = .asa, .help = "b²/S" },
            .root_chord => .{ .label = "corda máxima (raiz)", .unit = "m", .stage = .asa, .help = "com a envergadura máxima: a asa cabe num retângulo b × c (regulamento)", .fix = "mais envergadura para a mesma área, ou menos área" },
            .stall_speed => .{ .label = "velocidade de estol", .unit = "m/s", .stage = .asa, .help = "com a massa estimada", .fix = "mais área ou perfil de C_l máximo maior" },
            .surfaces => .{ .label = "número de superfícies", .stage = .montagem, .help = "asa, empenagens e outras ligadas" },
            .length => .{ .label = "comprimento total", .unit = "m", .stage = .montagem, .help = "do nariz à ponta da cauda", .fix = "braço da cauda menor (V_H com mais área)" },
            .motor_power => .{ .label = "potência dos motores", .unit = "W", .stage = .montagem, .help = "elétrica máxima: corrente máx. × tensão da bateria, somada nos motores", .fix = "motor menor ou menos motores" },
            .motors => .{ .label = "número de motores", .stage = .montagem },
            .liquid_mass => .{ .label = "massa de líquido", .unit = "kg", .stage = .montagem, .help = "carga paga em água" },
            .lapes_mass => .{ .label = "massa de LAPES", .unit = "kg", .stage = .montagem, .help = "carga paga lançada" },
            .ballast_mass => .{ .label = "massa de lastro", .unit = "kg", .stage = .montagem, .help = "carga paga sólida" },
            .static_margin => .{ .label = "margem estática", .unit = "% CMA", .stage = .montagem },
            .takeoff_run => .{ .label = "corrida de decolagem", .unit = "m", .stage = .desempenho, .help = "com a massa montada", .fix = "mais tração, mais área ou menos massa" },
            .top_speed => .{ .label = "velocidade máxima", .unit = "m/s", .stage = .desempenho },
            .climb_rate => .{ .label = "razão de subida máxima", .unit = "m/s", .stage = .desempenho, .fix = "mais tração ou menos arrasto" },
            .thrust_to_weight => .{ .label = "tração/peso estática", .stage = .desempenho },
            .turn_load => .{ .label = "fator de carga sustentado", .stage = .desempenho, .help = "na V da curva (Condições): o que a tração mantém, limitado pelo estol", .fix = "mais tração ou menos arrasto induzido (mais alongamento)" },
            .climb_gradient => .{ .label = "gradiente de subida máx.", .unit = "%", .stage = .desempenho, .help = "maior (T − D)/W", .fix = "mais tração ou menos arrasto" },
            .ceiling => .{ .label = "teto", .unit = "m", .stage = .desempenho, .help = "altitude-densidade em que a subida máxima cai a 0,5 m/s (tração proporcional a ρ)", .fix = "mais tração/potência ou menos carga alar" },
            .landing_run => .{ .label = "corrida de pouso", .unit = "m", .stage = .desempenho, .help = "toque a 1,15 V_S, frenagem com o atrito das Condições, sem arrasto (conservador)", .fix = "mais área ou C_L,max maior" },
            .mass => .{ .label = "massa montada", .unit = "kg", .stage = .montagem, .help = "saída: PV + CP" },
            .empty_mass => .{ .label = "PV (peso vazio)", .unit = "kg", .stage = .montagem, .help = "saída: tudo menos a carga paga" },
            .payload => .{ .label = "CP (carga paga)", .unit = "kg", .stage = .montagem, .help = "saída: lastro + líquido + LAPES (na sprint: massa de projeto − PV)" },
            .structural_efficiency => .{ .label = "EE (eficiência estrutural)", .stage = .montagem, .help = "saída: CP / PV", .fix = "PV menor ou CP maior" },
            .mtow => .{ .label = "MTOW", .unit = "kg", .stage = .desempenho, .help = "saída: a maior massa que decola na corrida restrita" },
        };
    }
};

pub const quantity_count = @typeInfo(Quantity).@"enum".fields.len;

/// os valores calculados pela última etapa que rodou (null: ainda não calculado)
pub const Values = [quantity_count]?f64;

/// nenhum valor calculado
pub const no_values: Values = [_]?f64{null} ** quantity_count;

/// o operador da restrição
pub const Op = enum {
    at_most,
    at_least,
    equal,

    /// o símbolo (≤, ≥, =)
    pub fn symbol(op: Op) []const u8 {
        return switch (op) {
            .at_most => "≤",
            .at_least => "≥",
            .equal => "=",
        };
    }
};

/// uma restrição de projeto: liga e desliga sem perder o valor
pub const Constraint = struct {
    quantity: Quantity = .span,
    op: Op = .at_most,
    value: f64 = 0,
    active: bool = true,
    tolerance: f64 = 0.02, // "=": tolerância relativa

    /// verdadeiro se `x` cumpre a restrição (um valor não finito nunca cumpre)
    pub fn holds(constraint: Constraint, x: f64) bool {
        if (!std.math.isFinite(x)) return false;
        return switch (constraint.op) {
            .at_most => x <= constraint.value + 1e-9,
            .at_least => x >= constraint.value - 1e-9,
            .equal => @abs(x - constraint.value) <= constraint.tolerance * @max(@abs(constraint.value), 1e-9),
        };
    }

    /// "envergadura ≤ 2,5 m"
    pub fn text(constraint: Constraint, buffer: []u8) []const u8 {
        const info = constraint.quantity.info();
        var number: [32]u8 = undefined;
        const out = std.fmt.bufPrint(buffer, "{s} {s} {s} {s}", .{ info.label, constraint.op.symbol(), shortNumber(&number, constraint.value), info.unit }) catch return "";
        return std.mem.trimEnd(u8, out, " ");
    }

    /// "2,4 ≤ 2,5 m": o valor calculado diante do limite
    pub fn comparison(constraint: Constraint, buffer: []u8, x: f64) []const u8 {
        var left: [32]u8 = undefined;
        var right: [32]u8 = undefined;
        const out = std.fmt.bufPrint(buffer, "{s} {s} {s} {s}", .{ shortNumber(&left, x), constraint.op.symbol(), shortNumber(&right, constraint.value), constraint.quantity.info().unit }) catch return "";
        return std.mem.trimEnd(u8, out, " ");
    }
};

/// um número curto como o `fmt` da GUI: 3 algarismos significativos com vírgula; de 1000 para cima, inteiro; "—"
/// se não é finito
pub fn shortNumber(buffer: []u8, value: f64) []const u8 {
    if (!std.math.isFinite(value)) return "—";
    if (@abs(value) >= 1000) return std.fmt.bufPrint(buffer, "{d:.0}", .{value}) catch "";
    if (value == 0) return "0";
    // o formato "g" com 3 algarismos: as casas que sobram depois dos da parte inteira, sem zeros no fim
    const magnitude: i32 = @intFromFloat(@floor(std.math.log10(@abs(value))));
    const decimals: usize = @intCast(std.math.clamp(2 - magnitude, 0, 12));
    var text = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ value, decimals }) catch return "";
    if (std.mem.indexOfScalar(u8, text, '.')) |dot| {
        var end = text.len;
        while (end > dot + 1 and text[end - 1] == '0') end -= 1;
        if (end == dot + 1) end = dot;
        text = text[0..end];
        if (std.mem.indexOfScalar(u8, text, '.')) |comma| buffer[comma] = ',';
    }
    return text;
}

pub const max_constraints = 24;

/// as restrições de partida (as desligadas ficam à mão para ligar), `default_constraints` da GUI
pub const default_constraints = [_]Constraint{
    .{ .quantity = .stall_speed, .op = .at_most, .value = 11 },
    .{ .quantity = .span, .op = .at_most, .value = 2.5 },
    .{ .quantity = .takeoff_run, .op = .at_most, .value = 50 },
    .{ .quantity = .length, .op = .at_most, .value = 2, .active = false },
    .{ .quantity = .area, .op = .at_most, .value = 1, .active = false },
    .{ .quantity = .motor_power, .op = .at_most, .value = 700, .active = false },
    .{ .quantity = .surfaces, .op = .at_most, .value = 3, .active = false },
    .{ .quantity = .motors, .op = .at_most, .value = 1, .active = false },
    .{ .quantity = .structural_efficiency, .op = .at_least, .value = 1, .active = false },
    .{ .quantity = .liquid_mass, .op = .at_least, .value = 1, .active = false },
    .{ .quantity = .lapes_mass, .op = .at_least, .value = 1, .active = false },
    .{ .quantity = .climb_rate, .op = .at_least, .value = 1 },
    .{ .quantity = .turn_load, .op = .at_least, .value = 2, .active = false },
    .{ .quantity = .climb_gradient, .op = .at_least, .value = 5, .active = false },
    .{ .quantity = .ceiling, .op = .at_least, .value = 1500, .active = false },
    .{ .quantity = .landing_run, .op = .at_most, .value = 60, .active = false },
};

/// a lista de restrições do projeto
pub const Constraints = struct {
    items: [max_constraints]Constraint = default_constraints ++ [_]Constraint{.{}} ** (max_constraints - default_constraints.len),
    count: usize = default_constraints.len,

    /// as restrições da lista
    pub fn slice(list: *Constraints) []Constraint {
        return list.items[0..list.count];
    }

    /// a primeira restrição ativa da grandeza (com o operador, se dado)
    pub fn active(list: *const Constraints, quantity: Quantity, op: ?Op) ?Constraint {
        for (list.items[0..list.count]) |constraint| {
            if (constraint.active and constraint.quantity == quantity and (op == null or constraint.op == op.?)) return constraint;
        }
        return null;
    }

    /// acrescenta uma restrição nova (área ≤ 1 m², como o "+ restrição" da GUI); falso se a lista está cheia
    pub fn add(list: *Constraints) bool {
        if (list.count == max_constraints) return false;
        list.items[list.count] = .{ .quantity = .area, .op = .at_most, .value = 1 };
        list.count += 1;
        return true;
    }

    /// tira a restrição `index`
    pub fn remove(list: *Constraints, index: usize) void {
        if (index >= list.count) return;
        for (index..list.count - 1) |k| list.items[k] = list.items[k + 1];
        list.count -= 1;
    }

    /// o resumo da barra de requisitos: as ativas separadas por "; " (ou "nenhuma")
    pub fn summary(list: *const Constraints, buffer: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        var any = false;
        for (list.items[0..list.count]) |constraint| {
            if (!constraint.active) continue;
            var one: [96]u8 = undefined;
            writer.print("{s}{s}", .{ if (any) "; " else "", constraint.text(&one) }) catch break;
            any = true;
        }
        if (!any) writer.writeAll("nenhuma") catch {};
        return writer.buffered();
    }
};

/// o resultado de conferir uma restrição ativa
pub const Verdict = struct {
    constraint: Constraint,
    holds: bool,
    value: f64,
};

/// as restrições ativas que estes valores respondem, só as da etapa `stage` (a Montagem também confere as do
/// Desempenho), como `checks` da GUI; devolve quantas foram para `out`
pub fn verdicts(list: *const Constraints, values: *const Values, stage: ?Stage, out: []Verdict) usize {
    var count: usize = 0;
    for (list.items[0..list.count]) |constraint| {
        if (!constraint.active or count == out.len) continue;
        const value = values[@intFromEnum(constraint.quantity)] orelse continue;
        const own = constraint.quantity.info().stage;
        if (stage) |wanted| {
            if (own != wanted and !(wanted == .montagem and own == .desempenho)) continue;
        }
        out[count] = .{ .constraint = constraint, .holds = constraint.holds(value), .value = value };
        count += 1;
    }
    return count;
}

// ------------------------------------------------------------------ variáveis (entradas das etapas)

/// uma entrada de projeto que o otimizador pode variar, `INPUTS` da GUI
pub const Input = enum {
    wing_span,
    wing_area,
    wing_taper,
    wing_rect_fraction,
    wing_alpha_cruise,
    wing_airfoil,
    wing_airfoil_tip,
    power_motor,
    power_propeller,
    power_layout,
    power_tilt,
    power_motors,
    cruise_speed,
    mass,

    /// o nome, a unidade ("lista" para as escolhas) e a faixa sugerida
    pub fn info(input: Input) InputInfo {
        return switch (input) {
            .wing_span => .{ .label = "envergadura", .unit = "m", .low = 1, .high = 3 },
            .wing_area => .{ .label = "área da asa", .unit = "m²", .low = 0.3, .high = 1.5 },
            .wing_taper => .{ .label = "afilamento", .low = 0.3, .high = 1 },
            .wing_rect_fraction => .{ .label = "trecho retangular", .low = 0, .high = 1 },
            .wing_alpha_cruise => .{ .label = "ângulo de cruzeiro", .unit = "°", .low = -2, .high = 6 },
            .wing_airfoil => .{ .label = "perfil da asa (raiz)", .list = true },
            .wing_airfoil_tip => .{ .label = "perfil da ponta (vazio = o da raiz)", .list = true },
            .power_motor => .{ .label = "motor", .list = true },
            .power_propeller => .{ .label = "hélice", .list = true },
            .power_layout => .{ .label = "motores (arranjo)", .list = true },
            .power_tilt => .{ .label = "inclinação do motor", .unit = "°", .low = 0, .high = 12 },
            .power_motors => .{ .label = "nº de motores (o arranjo manda: nariz/propulsora 1, asa aos pares)", .low = 1, .high = 8, .integer = true },
            .cruise_speed => .{ .label = "velocidade de cruzeiro", .unit = "m/s", .low = 10, .high = 25 },
            .mass => .{ .label = "massa estimada (ponto de partida)", .unit = "kg", .low = 2, .high = 20 },
        };
    }
};

pub const InputInfo = struct {
    label: []const u8,
    unit: []const u8 = "",
    low: f64 = 0,
    high: f64 = 1,
    integer: bool = false,
    list: bool = false, // escolha numa lista (perfil, motor, hélice, arranjo)
};

pub const input_count = @typeInfo(Input).@"enum".fields.len;

/// fixo: vale o valor do rascunho; variável: o otimizador procura entre mín. e máx. (listas: entre as opções);
/// calculado: sai das contas
pub const Mode = enum { fixo, variavel, calculado };

/// os nomes dos modos, como aparecem
pub const mode_names = "fixo;variável;calculado";

pub const max_options = 16;
pub const option_capacity = 48;

/// uma variável de projeto: a entrada, o modo, a faixa e, numa lista, os itens que podem ser escolhidos
pub const Variable = struct {
    input: Input,
    mode: Mode = .fixo,
    low: f64 = 0,
    high: f64 = 1,
    options: [max_options][option_capacity]u8 = undefined,
    option_lengths: [max_options]usize = [_]usize{0} ** max_options,
    option_count: usize = 0, // nenhuma marcada = todas

    /// a opção `index`
    pub fn option(variable: *const Variable, index: usize) []const u8 {
        return variable.options[index][0..variable.option_lengths[index]];
    }

    /// troca as opções marcadas por `names` (todas marcadas = lista vazia, "todas"); escolher opções numa
    /// variável fixa passa ela a variável (a busca vai variar entre elas)
    pub fn setOptions(variable: *Variable, names: []const []const u8, total: usize) void {
        variable.option_count = 0;
        if (names.len == total) return;
        for (names) |name| {
            if (variable.option_count == max_options) break;
            const length = @min(name.len, option_capacity);
            @memcpy(variable.options[variable.option_count][0..length], name[0..length]);
            variable.option_lengths[variable.option_count] = length;
            variable.option_count += 1;
        }
        if (variable.mode == .fixo and variable.option_count > 0) variable.mode = .variavel;
    }

    /// a opção `name` está marcada? (nenhuma marcada = todas)
    pub fn hasOption(variable: *const Variable, name: []const u8) bool {
        if (variable.option_count == 0) return true;
        for (0..variable.option_count) |k| if (std.mem.eql(u8, variable.option(k), name)) return true;
        return false;
    }
};

/// as variáveis de partida: todas fixas na faixa sugerida, menos a massa, que o ponto de projeto acerta
pub fn defaultVariables() [input_count]Variable {
    var out: [input_count]Variable = undefined;
    for (&out, 0..) |*variable, k| {
        const input: Input = @enumFromInt(k);
        const info = input.info();
        variable.* = .{ .input = input, .low = info.low, .high = info.high, .mode = if (input == .mass) .calculado else .fixo };
    }
    return out;
}

/// a entrada que uma restrição limita (o otimizador não precisa procurar fora dela), `CONSTRAINT_INPUT` da GUI
pub fn limitedInput(quantity: Quantity) ?Input {
    return switch (quantity) {
        .span => .wing_span,
        .area => .wing_area,
        .motors => .power_motors,
        else => null,
    };
}

/// leva as restrições ativas para os limites das variáveis (≤ → máx., ≥ → mín., = → os dois); devolve quantas
/// variáveis mudaram e escreve em `changed` os índices delas
pub fn boundsFromConstraints(list: *const Constraints, variables: *[input_count]Variable, changed: *[input_count]bool) usize {
    changed.* = [_]bool{false} ** input_count;
    var count: usize = 0;
    for (list.items[0..list.count]) |constraint| {
        if (!constraint.active) continue;
        const input = limitedInput(constraint.quantity) orelse continue;
        const variable = &variables[@intFromEnum(input)];
        if (constraint.op != .at_least) variable.high = constraint.value;
        if (constraint.op != .at_most) variable.low = constraint.value;
        if (variable.low > variable.high) variable.low = variable.high;
        if (!changed[@intFromEnum(input)]) count += 1;
        changed[@intFromEnum(input)] = true;
    }
    return count;
}

/// os nomes do catálogo embutido (`builtin_catalog` de `aerosim/model/catalog.py`) e os arranjos de motor
/// (`LAYOUTS` de `aerosim/design/power.py`), para as variáveis de lista
pub const catalog_motors = [_][]const u8{ "Scorpion A-5025-310Kv", "Genérico 500Kv", "Genérico 900Kv" };
pub const catalog_propellers = [_][]const u8{ "APC 15x8E", "Genérica 13x6.5", "Genérica 11x7", "Genérica 16x10" };
pub const layouts = [_][]const u8{ "tratora no nariz", "dois motores na asa", "propulsora atrás da asa", "livre: nariz + asa + atrás" };

test "restrição: cumpre, texto e comparação como na GUI em Python" {
    const span: Constraint = .{ .quantity = .span, .op = .at_most, .value = 2.5 };
    try std.testing.expect(span.holds(2.4));
    try std.testing.expect(!span.holds(2.6));
    try std.testing.expect(!span.holds(std.math.nan(f64)));
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("envergadura ≤ 2,5 m", span.text(&buffer));
    try std.testing.expectEqualStrings("2,4 ≤ 2,5 m", span.comparison(&buffer, 2.4));
    const equal: Constraint = .{ .quantity = .area, .op = .equal, .value = 1 };
    try std.testing.expect(equal.holds(1.019));
    try std.testing.expect(!equal.holds(1.03));
    const count: Constraint = .{ .quantity = .surfaces, .op = .at_most, .value = 3 };
    try std.testing.expectEqualStrings("número de superfícies ≤ 3", count.text(&buffer));
}

test "número curto: 3 algarismos, vírgula, inteiro acima de mil" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12,4", shortNumber(&buffer, 12.4029));
    try std.testing.expectEqualStrings("0,0123", shortNumber(&buffer, 0.012345));
    try std.testing.expectEqualStrings("1500", shortNumber(&buffer, 1500));
    try std.testing.expectEqualStrings("11", shortNumber(&buffer, 11));
    try std.testing.expectEqualStrings("—", shortNumber(&buffer, std.math.inf(f64)));
}

test "conferir: só as ativas da etapa, e a Montagem confere as do Desempenho" {
    var list: Constraints = .{};
    var values = no_values;
    values[@intFromEnum(Quantity.span)] = 2.6;
    values[@intFromEnum(Quantity.stall_speed)] = 10;
    values[@intFromEnum(Quantity.takeoff_run)] = 40;
    var out: [8]Verdict = undefined;
    const wing = verdicts(&list, &values, .asa, &out);
    try std.testing.expectEqual(@as(usize, 2), wing);
    try std.testing.expect(out[0].holds); // V_S ≤ 11
    try std.testing.expect(!out[1].holds); // b ≤ 2,5
    try std.testing.expectEqual(@as(usize, 1), verdicts(&list, &values, .montagem, &out));
    var summary: [512]u8 = undefined;
    try std.testing.expectEqualStrings("velocidade de estol ≤ 11 m/s; envergadura ≤ 2,5 m; corrida de decolagem ≤ 50 m; razão de subida máxima ≥ 1 m/s", list.summary(&summary));
}

test "limites das variáveis a partir das restrições" {
    var list: Constraints = .{};
    list.items[4].active = true; // área ≤ 1
    var variables = defaultVariables();
    var changed: [input_count]bool = undefined;
    try std.testing.expectEqual(@as(usize, 2), boundsFromConstraints(&list, &variables, &changed));
    try std.testing.expectEqual(@as(f64, 2.5), variables[@intFromEnum(Input.wing_span)].high);
    try std.testing.expectEqual(@as(f64, 1), variables[@intFromEnum(Input.wing_area)].high);
    try std.testing.expectEqual(Mode.calculado, variables[@intFromEnum(Input.mass)].mode);
    var airfoil = &variables[@intFromEnum(Input.wing_airfoil)];
    airfoil.setOptions(&.{"NACA 4412"}, 3);
    try std.testing.expectEqual(Mode.variavel, airfoil.mode);
    try std.testing.expect(airfoil.hasOption("NACA 4412") and !airfoil.hasOption("NACA 2412"));
}

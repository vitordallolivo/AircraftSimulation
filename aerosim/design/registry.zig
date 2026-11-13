//! O registro do projeto em Zig (o par de `registry.py` e dos campos de `spec.py`): as grandezas que se medem e se
//! restringem, as entradas que o otimizador pode variar, as restrições e variáveis de partida e os campos das
//! condições e das regras de projeto. As etapas e o Mini-MDO leem o projeto (`store.Project`) por aqui.
const std = @import("std");
const store = @import("store.zig");
/// o projeto da sprint (para quem importa só o registro, como o aeroopt)
pub const project_store = store;

const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;

/// os operadores das restrições, na ordem do Python
pub const operators = [_][]const u8{ "≤", "≥", "=" };
/// os modos de uma variável
pub const modes = [_][]const u8{ "fixo", "variável", "calculado" };

/// uma grandeza do projeto: o rótulo, a unidade, a etapa que a calcula e o que mexer quando a restrição falha
pub const Quantity = struct { key: []const u8, label: []const u8, unit: []const u8 = "", stage: []const u8 = "", help: []const u8 = "", fix: []const u8 = "" };

pub const quantities = [_]Quantity{
    .{ .key = "S", .label = "área da asa", .unit = "m²", .stage = "asa", .help = "área em planta das duas semiasas", .fix = "envergadura/corda" },
    .{ .key = "b", .label = "envergadura", .unit = "m", .stage = "asa", .help = "de ponta a ponta", .fix = "menos envergadura (mais corda para manter a área)" },
    .{ .key = "AR", .label = "alongamento", .stage = "asa", .help = "b²/S" },
    .{ .key = "c_root", .label = "corda máxima (raiz)", .unit = "m", .stage = "asa", .help = "com a envergadura máxima: a asa cabe num retângulo b × c (regulamento)", .fix = "mais envergadura para a mesma área, ou menos área" },
    .{ .key = "V_S", .label = "velocidade de estol", .unit = "m/s", .stage = "asa", .help = "com a massa estimada", .fix = "mais área ou perfil de C_l máximo maior" },
    .{ .key = "n_surf", .label = "número de superfícies", .stage = "montagem", .help = "asa, empenagens e outras ligadas" },
    .{ .key = "length", .label = "comprimento total", .unit = "m", .stage = "montagem", .help = "do nariz à ponta da cauda", .fix = "braço da cauda menor (V_H com mais área)" },
    .{ .key = "P_motor", .label = "potência dos motores", .unit = "W", .stage = "montagem", .help = "elétrica máxima: corrente máx. × tensão da bateria, somada nos motores", .fix = "motor menor ou menos motores" },
    .{ .key = "n_motor", .label = "número de motores", .stage = "montagem" },
    .{ .key = "m_liquid", .label = "massa de líquido", .unit = "kg", .stage = "montagem", .help = "carga paga em água" },
    .{ .key = "m_lapes", .label = "massa de LAPES", .unit = "kg", .stage = "montagem", .help = "carga paga lançada" },
    .{ .key = "m_ballast", .label = "massa de lastro", .unit = "kg", .stage = "montagem", .help = "carga paga sólida" },
    .{ .key = "sm", .label = "margem estática", .unit = "% CMA", .stage = "montagem" },
    .{ .key = "s_to", .label = "corrida de decolagem", .unit = "m", .stage = "desempenho", .help = "com a massa montada", .fix = "mais tração, mais área ou menos massa" },
    .{ .key = "V_max", .label = "velocidade máxima", .unit = "m/s", .stage = "desempenho" },
    .{ .key = "RC", .label = "razão de subida máxima", .unit = "m/s", .stage = "desempenho", .fix = "mais tração ou menos arrasto" },
    .{ .key = "TW", .label = "tração/peso estática", .stage = "desempenho" },
    .{ .key = "n_turn", .label = "fator de carga sustentado", .stage = "desempenho", .help = "na V da curva (Condições): o que a tração mantém, limitado pelo estol", .fix = "mais tração ou menos arrasto induzido (mais alongamento)" },
    .{ .key = "grad", .label = "gradiente de subida máx.", .unit = "%", .stage = "desempenho", .help = "maior (T − D)/W", .fix = "mais tração ou menos arrasto" },
    .{ .key = "ceiling", .label = "teto", .unit = "m", .stage = "desempenho", .help = "altitude-densidade em que a subida máxima cai a 0,5 m/s (tração proporcional a ρ)", .fix = "mais tração/potência ou menos carga alar" },
    .{ .key = "s_land", .label = "corrida de pouso", .unit = "m", .stage = "desempenho", .help = "toque a 1,15 V_S, frenagem com o atrito das Condições, sem arrasto (conservador)", .fix = "mais área ou C_L,max maior" },
    .{ .key = "mass", .label = "massa montada", .unit = "kg", .stage = "montagem", .help = "saída: PV + CP" },
    .{ .key = "pv", .label = "PV (peso vazio)", .unit = "kg", .stage = "montagem", .help = "saída: tudo menos a carga paga" },
    .{ .key = "cp", .label = "CP (carga paga)", .unit = "kg", .stage = "montagem", .help = "saída: lastro + líquido + LAPES (na sprint: massa de projeto − PV)" },
    .{ .key = "ee", .label = "EE (eficiência estrutural)", .stage = "montagem", .help = "saída: CP / PV", .fix = "PV menor ou CP maior" },
    .{ .key = "mtow", .label = "MTOW", .unit = "kg", .stage = "desempenho", .help = "saída: a maior massa que decola na corrida restrita" },
};

/// os rótulos das grandezas, na ordem da tabela (as opções da coluna "grandeza")
pub const quantity_labels = blk: {
    var labels: [quantities.len][]const u8 = undefined;
    for (quantities, 0..) |item, i| labels[i] = item.label;
    break :blk labels;
};

/// a grandeza com esta chave (uma desconhecida volta com o rótulo igual à chave)
pub fn quantity(key: []const u8) Quantity {
    for (quantities) |item| if (std.mem.eql(u8, item.key, key)) return item;
    return .{ .key = key, .label = key };
}

/// a chave da grandeza com este rótulo
pub fn quantityKey(label: []const u8) ?[]const u8 {
    for (quantities) |item| if (std.mem.eql(u8, item.label, label)) return item.key;
    return null;
}

/// um número como o `fmt` do Python: três algarismos, vírgula decimal; "—" se não é finito
pub fn format(buffer: []u8, value: f64) []const u8 {
    if (!std.math.isFinite(value)) return "—";
    if (@abs(value) >= 1000) return std.fmt.bufPrint(buffer, "{d:.0}", .{value}) catch "—";
    const magnitude: i32 = if (value == 0) 0 else @intFromFloat(@floor(std.math.log10(@abs(value))));
    const decimals: usize = @intCast(std.math.clamp(2 - magnitude, 0, 8));
    const printed = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ value, decimals }) catch return "—";
    // tira os zeros do fim (o "g" do Python) e troca o ponto pela vírgula
    var end = printed.len;
    if (std.mem.indexOfScalar(u8, printed, '.') != null) {
        while (end > 0 and printed[end - 1] == '0') end -= 1;
        if (end > 0 and printed[end - 1] == '.') end -= 1;
    }
    for (buffer[0..end]) |*char| if (char.* == '.') {
        char.* = ',';
    };
    return buffer[0..end];
}

// ------------------------------------------------------------------ restrições
/// uma restrição do projeto (um item de `requirements.constraints`)
pub const Constraint = struct {
    key: []const u8 = "b",
    op: []const u8 = "≤",
    value: f64 = 0,
    active: bool = true,
    tol: f64 = 0.02,

    /// a restrição é cumprida por `x`
    pub fn holds(constraint: Constraint, x: f64) bool {
        if (!std.math.isFinite(x)) return false;
        if (std.mem.eql(u8, constraint.op, "≤")) return x <= constraint.value + 1e-9;
        if (std.mem.eql(u8, constraint.op, "≥")) return x >= constraint.value - 1e-9;
        return @abs(x - constraint.value) <= constraint.tol * @max(@abs(constraint.value), 1e-9);
    }

    /// "envergadura ≤ 2,5 m"
    pub fn text(constraint: Constraint, memory: std.mem.Allocator) ![]const u8 {
        const info = quantity(constraint.key);
        var buffer: [32]u8 = undefined;
        const printed = try std.fmt.allocPrint(memory, "{s} {s} {s} {s}", .{ info.label, constraint.op, format(&buffer, constraint.value), info.unit });
        return std.mem.trimEnd(u8, printed, " ");
    }
};

/// as restrições de partida (as desligadas ficam à mão para ligar)
pub const default_constraints = [_]Constraint{
    .{ .key = "V_S", .op = "≤", .value = 11.0 },          .{ .key = "b", .op = "≤", .value = 2.5 },
    .{ .key = "s_to", .op = "≤", .value = 50.0 },         .{ .key = "length", .op = "≤", .value = 2.0, .active = false },
    .{ .key = "S", .op = "≤", .value = 1.0, .active = false }, .{ .key = "P_motor", .op = "≤", .value = 700.0, .active = false },
    .{ .key = "n_surf", .op = "≤", .value = 3, .active = false }, .{ .key = "n_motor", .op = "≤", .value = 1, .active = false },
    .{ .key = "ee", .op = "≥", .value = 1.0, .active = false }, .{ .key = "m_liquid", .op = "≥", .value = 1.0, .active = false },
    .{ .key = "m_lapes", .op = "≥", .value = 1.0, .active = false }, .{ .key = "RC", .op = "≥", .value = 1.0 },
    .{ .key = "n_turn", .op = "≥", .value = 2.0, .active = false }, .{ .key = "grad", .op = "≥", .value = 5.0, .active = false },
    .{ .key = "ceiling", .op = "≥", .value = 1500.0, .active = false }, .{ .key = "s_land", .op = "≤", .value = 60.0, .active = false },
};

/// a lista de restrições do projeto (criada com as de partida se ainda não existe)
pub fn constraintList(project: *store.Project) !*std.json.Array {
    const requirements = project.section("requirements");
    const gop = try requirements.getOrPut(project.memory(), "constraints");
    if (!gop.found_existing or gop.value_ptr.* != .array) {
        var list = std.json.Array.init(project.memory());
        for (default_constraints) |constraint| try list.append(try constraintValue(project.memory(), constraint));
        gop.value_ptr.* = .{ .array = list };
    }
    return &gop.value_ptr.array;
}

/// a restrição escrita como no projeto
pub fn constraintValue(memory: std.mem.Allocator, constraint: Constraint) !Value {
    var object = ObjectMap.empty;
    try object.put(memory, "key", .{ .string = constraint.key });
    try object.put(memory, "op", .{ .string = constraint.op });
    try object.put(memory, "value", .{ .float = constraint.value });
    try object.put(memory, "active", .{ .bool = constraint.active });
    try object.put(memory, "tol", .{ .float = constraint.tol });
    return .{ .object = object };
}

/// a restrição lida de um item do projeto
pub fn readConstraint(item: Value) Constraint {
    if (item != .object) return .{};
    const object = &item.object;
    return .{ .key = store.text(object, "key", "b"), .op = store.text(object, "op", "≤"), .value = store.number(object, "value", 0), .active = store.flag(object, "active", true), .tol = store.number(object, "tol", 0.02) };
}

/// a restrição ligada desta grandeza e deste operador (null: nenhuma)
pub fn active(project: *store.Project, key: []const u8, op: ?[]const u8) !?Constraint {
    for ((try constraintList(project)).items) |item| {
        const constraint = readConstraint(item);
        if (!constraint.active or !std.mem.eql(u8, constraint.key, key)) continue;
        if (op) |wanted| if (!std.mem.eql(u8, wanted, constraint.op)) continue;
        return constraint;
    }
    return null;
}

// ------------------------------------------------------------------ entradas e variáveis
/// uma entrada de projeto: onde mora ("<rascunho>.<campo>"), o rótulo, a unidade ("lista" nas de escolha) e a faixa
/// sugerida para "variável"
pub const Input = struct { key: []const u8, path: []const u8, label: []const u8, unit: []const u8 = "", lo: f64 = 0, hi: f64 = 1, integer: bool = false };

pub const inputs = [_]Input{
    .{ .key = "wing.span", .path = "wing_draft.span", .label = "envergadura", .unit = "m", .lo = 1.0, .hi = 3.0 },
    .{ .key = "wing.area", .path = "wing_draft.area", .label = "área da asa", .unit = "m²", .lo = 0.3, .hi = 1.5 },
    .{ .key = "wing.taper", .path = "wing_draft.taper", .label = "afilamento", .lo = 0.3, .hi = 1.0 },
    .{ .key = "wing.rect_frac", .path = "wing_draft.rect_frac", .label = "trecho retangular", .lo = 0.0, .hi = 1.0 },
    .{ .key = "wing.alpha_cruise", .path = "wing_draft.alpha_cruise", .label = "ângulo de cruzeiro", .unit = "°", .lo = -2.0, .hi = 6.0 },
    .{ .key = "wing.airfoil", .path = "wing_draft.airfoil", .label = "perfil da asa (raiz)", .unit = "lista" },
    .{ .key = "wing.airfoil_tip", .path = "wing_draft.airfoil_tip", .label = "perfil da ponta (vazio = o da raiz)", .unit = "lista" },
    .{ .key = "power.motor", .path = "power_draft.motor", .label = "motor", .unit = "lista" },
    .{ .key = "power.propeller", .path = "power_draft.propeller", .label = "hélice", .unit = "lista" },
    .{ .key = "power.layout", .path = "power_draft.layout", .label = "motores (arranjo)", .unit = "lista" },
    .{ .key = "power.tilt", .path = "power_draft.tilt", .label = "inclinação do motor", .unit = "°", .lo = 0.0, .hi = 12.0 },
    .{ .key = "power.motors", .path = "power_draft.wing_motors", .label = "nº de motores (o arranjo manda: nariz/propulsora 1, asa aos pares)", .lo = 1.0, .hi = 8.0, .integer = true },
    .{ .key = "req.V_cruise", .path = "requirements.V_cruise", .label = "velocidade de cruzeiro", .unit = "m/s", .lo = 10.0, .hi = 25.0 },
    .{ .key = "req.mass", .path = "requirements.mass", .label = "massa estimada (ponto de partida)", .unit = "kg", .lo = 2.0, .hi = 20.0 },
};

/// a entrada com esta chave
pub fn input(key: []const u8) ?Input {
    for (inputs) |item| if (std.mem.eql(u8, item.key, key)) return item;
    return null;
}

/// a seção e o campo de uma entrada ("wing_draft", "span")
pub fn inputPlace(item: Input) [2][]const u8 {
    const dot = std.mem.indexOfScalar(u8, item.path, '.').?;
    return .{ item.path[0..dot], item.path[dot + 1 ..] };
}

/// a lista de variáveis do projeto, completada com as entradas que faltam (fixas; a massa, calculada)
pub fn variableList(project: *store.Project) !*std.json.Array {
    const list = project.list("variables");
    for (inputs) |item| {
        var known = false;
        for (list.items) |variable| known = known or (variable == .object and std.mem.eql(u8, store.text(&variable.object, "key", ""), item.key));
        if (known) continue;
        var object = ObjectMap.empty;
        try object.put(project.memory(), "key", .{ .string = item.key });
        try object.put(project.memory(), "mode", .{ .string = if (std.mem.eql(u8, item.key, "req.mass")) "calculado" else "fixo" });
        try object.put(project.memory(), "lo", .{ .float = item.lo });
        try object.put(project.memory(), "hi", .{ .float = item.hi });
        try object.put(project.memory(), "options", .{ .array = .init(project.memory()) });
        try list.append(.{ .object = object });
    }
    return list;
}

/// uma restrição → a entrada que ela limita ("Limites das restrições")
const constraint_input = [_][2][]const u8{ .{ "b", "wing.span" }, .{ "S", "wing.area" }, .{ "n_motor", "power.motors" } };

/// a entrada que uma restrição limita (`null` se ela não limita entrada nenhuma)
pub fn constraintInput(key: []const u8) ?[]const u8 {
    for (constraint_input) |pair| if (std.mem.eql(u8, pair[0], key)) return pair[1];
    return null;
}

/// leva as restrições ativas para os limites das variáveis (≤ → máx., ≥ → mín., = → os dois)
pub fn boundsFromConstraints(project: *store.Project) !void {
    const variables = try variableList(project);
    for ((try constraintList(project)).items) |item| {
        const constraint = readConstraint(item);
        if (!constraint.active) continue;
        const key = for (constraint_input) |pair| {
            if (std.mem.eql(u8, pair[0], constraint.key)) break pair[1];
        } else continue;
        for (variables.items) |*variable| {
            if (variable.* != .object or !std.mem.eql(u8, store.text(&variable.object, "key", ""), key)) continue;
            const object = &variable.object;
            if (!std.mem.eql(u8, constraint.op, "≥")) try store.setNumber(project, object, "hi", constraint.value);
            if (!std.mem.eql(u8, constraint.op, "≤")) try store.setNumber(project, object, "lo", constraint.value);
            if (store.number(object, "lo", 0) > store.number(object, "hi", 1)) try store.setNumber(project, object, "lo", store.number(object, "hi", 1));
        }
    }
}

// ------------------------------------------------------------------ campos das condições e das regras
/// um campo de uma seção do projeto (os metadados de `F` do Python)
pub const Field = struct {
    key: []const u8,
    label: []const u8,
    unit: []const u8 = "",
    help: []const u8 = "",
    default: union(enum) { number: f64, text: []const u8, toggle: bool } = .{ .number = 0 },
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    choices: []const []const u8 = &.{},
    integer: bool = false,
};

/// as condições (`Requirements`)
pub const requirement_fields = [_]Field{
    .{ .key = "mass", .label = "massa estimada (ponto de partida)", .unit = "kg", .help = "dá o C_L de cruzeiro e a carga alar das primeiras etapas; o ponto de projeto acerta a massa de verdade (o MTOW é saída, não requisito)", .default = .{ .number = 10.0 }, .minimum = 0.2, .maximum = 60 },
    .{ .key = "V_cruise", .label = "velocidade de cruzeiro", .unit = "m/s", .default = .{ .number = 15.0 }, .minimum = 3, .maximum = 60 },
    .{ .key = "density_altitude", .label = "altitude-densidade (AD)", .unit = "m", .help = "atmosfera padrão com a densidade do dia", .default = .{ .number = 600.0 }, .minimum = -500, .maximum = 4000 },
    .{ .key = "mu_roll", .label = "atrito de rolamento", .help = "pista: grama ≈ 0,08, asfalto ≈ 0,03", .default = .{ .number = 0.04 }, .minimum = 0, .maximum = 0.3 },
    .{ .key = "V_turn", .label = "V da curva", .unit = "m/s", .help = "a velocidade da curva sustentada (restrição de fator de carga); 0 = a de cruzeiro", .default = .{ .number = 0.0 }, .minimum = 0, .maximum = 60 },
    .{ .key = "mu_brake", .label = "atrito na frenagem", .help = "pouso: rodas freando na pista", .default = .{ .number = 0.3 }, .minimum = 0.05, .maximum = 1.0 },
    .{ .key = "obstacle_h", .label = "altura do obstáculo", .unit = "m", .help = "a decolagem 6GDL só vale se passar desta altura no fim da corrida (z_warning); a Regular 2026 pede 0,90 m a 55 m, R[7.8.0.1]", .default = .{ .number = 1.0 }, .minimum = 0.0, .maximum = 5.0 },
};

/// as regras de projeto (`DesignRules`)
pub const rule_fields = [_]Field{
    .{ .key = "wing_density", .label = "massa da asa por área", .unit = "kg/m²", .help = "estrutura + entelagem", .default = .{ .number = 1.1 }, .minimum = 0.1, .maximum = 6 },
    .{ .key = "tail_density", .label = "massa da empenagem por área", .unit = "kg/m²", .default = .{ .number = 0.7 }, .minimum = 0.1, .maximum = 6 },
    .{ .key = "boom_density", .label = "massa do tubo por metro", .unit = "kg/m", .default = .{ .number = 0.12 }, .minimum = 0.01, .maximum = 2 },
    .{ .key = "fuselage_width", .label = "largura da fuselagem", .unit = "m", .help = "pod do nariz até o bordo de fuga da asa", .default = .{ .number = 0.14 }, .minimum = 0.03, .maximum = 0.6 },
    .{ .key = "fuselage_height", .label = "altura da fuselagem", .unit = "m", .default = .{ .number = 0.16 }, .minimum = 0.03, .maximum = 0.6 },
    .{ .key = "fuselage_cd_wet", .label = "C_D da fuselagem (área molhada)", .help = "pod curto com trem: ≈ 0,04", .default = .{ .number = 0.04 }, .minimum = 0.005, .maximum = 0.2 },
    .{ .key = "fuselage_munk", .label = "fator de massa aparente da fuselagem (k2 − k1)", .help = "entra no momento de arfagem e de guinada da fuselagem; corpo alongado de fineza 6 a 8: ≈ 0,9", .default = .{ .number = 0.9 }, .minimum = 0.3, .maximum = 1 },
    .{ .key = "fuselage_density", .label = "massa da fuselagem por metro", .unit = "kg/m", .default = .{ .number = 0.7 }, .minimum = 0.05, .maximum = 5 },
    .{ .key = "systems_mass", .label = "sistemas", .unit = "kg", .help = "receptor, servos, fiação", .default = .{ .number = 0.35 }, .minimum = 0, .maximum = 5 },
    .{ .key = "gear_mass", .label = "trem de pouso", .unit = "kg", .default = .{ .number = 0.35 }, .minimum = 0, .maximum = 5 },
    .{ .key = "nose_length", .label = "nariz à frente da asa", .unit = "m", .help = "do bordo de ataque da asa até a hélice (tratora)", .default = .{ .number = 0.30 }, .minimum = 0.05, .maximum = 1.5 },
    .{ .key = "wing_z", .label = "altura da asa", .unit = "m", .help = "z do bordo de ataque (− = acima da fuselagem)", .default = .{ .number = -0.10 }, .minimum = -0.5, .maximum = 0.5 },
    .{ .key = "prop_clearance", .label = "folga da hélice ao chão", .unit = "m", .default = .{ .number = 0.05 }, .minimum = 0.0, .maximum = 0.5 },
    .{ .key = "main_gear_aft", .label = "trem principal atrás do CG", .unit = "m", .help = "≈ 15° de tombamento", .default = .{ .number = 0.06 }, .minimum = 0.0, .maximum = 0.5 },
    .{ .key = "track", .label = "bitola do trem", .unit = "m", .default = .{ .number = 0.45 }, .minimum = 0.1, .maximum = 2 },
    .{ .key = "de_max", .label = "profundor: curso para cabrar", .unit = "°", .help = "bordo de fuga para cima (rotação, C_L,max)", .default = .{ .number = 20.0 }, .minimum = 5, .maximum = 40 },
    .{ .key = "de_down", .label = "profundor: curso para picar", .unit = "°", .help = "cursos assimétricos: picar costuma ser menor; segura o nariz na corrida do motor inclinado", .default = .{ .number = 15.0 }, .minimum = 2, .maximum = 40 },
    .{ .key = "da_max", .label = "aileron: curso para cima", .unit = "°", .default = .{ .number = 20.0 }, .minimum = 5, .maximum = 40 },
    .{ .key = "power_limit", .label = "limite de potência do motor", .unit = "W", .help = "potência máxima que o avião todo pode tirar da bateria (um limitador, quando a regra pede); é dividida igual entre os motores. 0 = sem limite", .default = .{ .number = 0.0 }, .minimum = 0, .maximum = 20000 },
    // o refino das contas das etapas (os padrões são os de sempre)
    .{ .key = "ref_corrida_pontos", .label = "refino: velocidades testadas na corrida", .help = "a etapa Motores procura em que velocidade o nariz levanta sozinho e em qual o profundor roda o avião, nestas velocidades de 0,5 m/s a 1,6 × a de decolagem (até 256)", .default = .{ .number = 64 }, .minimum = 4, .maximum = 256 },
    .{ .key = "ref_bissecoes", .label = "refino: bisseções do profundor na corrida", .help = "a deflexão que segura o nariz no chão sai de uma busca por metades", .default = .{ .number = 30 }, .minimum = 1, .maximum = 100 },
    .{ .key = "ref_curvas_pontos", .label = "refino: pontos das curvas de tração e arrasto", .default = .{ .number = 120 }, .minimum = 4, .maximum = 5000 },
    .{ .key = "ref_rotacao_pontos", .label = "refino: velocidades da rotação", .help = "a velocidade de rotação é a primeira, de 0,5 a 40 m/s, em que o profundor todo cabrando levanta o nariz (até 256)", .default = .{ .number = 160 }, .minimum = 4, .maximum = 256 },
    .{ .key = "ref_massa_pontos", .label = "refino: massas da curva corrida × massa", .default = .{ .number = 25 }, .minimum = 3, .maximum = 500 },
    .{ .key = "ref_massa_tol", .label = "refino: tolerância da massa de projeto", .unit = "kg", .help = "o Estudo anda a massa de projeto até o MTOW da pista e para quando os dois diferem menos que isto", .default = .{ .number = 0.02 }, .minimum = 0.0001, .maximum = 5 },
    .{ .key = "ref_massa_voltas", .label = "refino: voltas da massa de projeto", .help = "voltas da média e, depois, da secante (método que segue a inclinação entre os dois últimos pontos)", .default = .{ .number = 10 }, .minimum = 1, .maximum = 100 },
    .{ .key = "da_down", .label = "aileron: curso para baixo", .unit = "°", .help = "aileron diferencial: desce menos do que sobe (menos guinada adversa)", .default = .{ .number = 12.0 }, .minimum = 2, .maximum = 40 },
};

/// o valor do campo na seção (ou o padrão do campo)
pub fn fieldNumber(section: *const ObjectMap, comptime fields: []const Field, key: []const u8) f64 {
    inline for (fields) |field| if (field.default == .number and std.mem.eql(u8, field.key, key)) return store.number(section, key, field.default.number);
    return store.number(section, key, 0);
}

/// densidade da atmosfera padrão na altitude `height` (m), troposfera (`isa_density` de `atmosphere.py`)
pub fn isaDensity(height: f64) f64 {
    const clamped = std.math.clamp(height, -2000.0, 11000.0);
    return 1.225 * std.math.pow(f64, 1.0 - 2.25577e-5 * clamped, 4.25588);
}

/// ρ do projeto (pela altitude-densidade das condições)
pub fn rho(project: *store.Project) f64 {
    return isaDensity(fieldNumber(project.section("requirements"), &requirement_fields, "density_altitude"));
}

/// "partida m = 12 kg · V = 13 m/s · AD 655 m (ρ = 1.150) · restrições: ..." (`Requirements.summary`)
pub fn requirementsSummary(memory: std.mem.Allocator, project: *store.Project) ![]const u8 {
    const requirements = project.section("requirements");
    var out: std.ArrayList(u8) = .empty;
    try out.print(memory, "partida m = {d} kg · V = {d} m/s · AD {d:.0} m (ρ = {d:.3}) · restrições: ", .{ fieldNumber(requirements, &requirement_fields, "mass"), fieldNumber(requirements, &requirement_fields, "V_cruise"), fieldNumber(requirements, &requirement_fields, "density_altitude"), rho(project) });
    var any = false;
    for ((try constraintList(project)).items) |item| {
        const constraint = readConstraint(item);
        if (!constraint.active) continue;
        if (any) try out.appendSlice(memory, "; ");
        try out.appendSlice(memory, try constraint.text(memory));
        any = true;
    }
    if (!any) try out.appendSlice(memory, "nenhuma");
    return out.items;
}

test "registro: número no jeito do Python e as restrições de partida" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2,5", format(&buffer, 2.5));
    try std.testing.expectEqualStrings("0,123", format(&buffer, 0.12345));
    try std.testing.expectEqualStrings("1500", format(&buffer, 1500));
    try std.testing.expect(default_constraints[0].holds(10.5));
    try std.testing.expectApproxEqAbs(@as(f64, 1.156), isaDensity(600), 2e-3);
}

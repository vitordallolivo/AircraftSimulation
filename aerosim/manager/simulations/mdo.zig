//! Mini-MDO em Zig (o par de `design/mdo.py`): o dimensionamento inicial como otimização. A geometria da asa
//! (envergadura, área, afilamento, perfis), a motorização (motor × hélice do catálogo, nº de motores, inclinação,
//! arranjo) e o envelope saem juntos do otimizador do núcleo (`core/src/sizing`), que maximiza o MTOW ou a
//! eficiência estrutural com as restrições ligadas. Aqui só se monta a configuração e se escreve o resultado.
//!
//! A empenagem não é dimensionada: entra como fração da área da asa (massa e arrasto).
//! As faixas e as listas (perfis, motores, hélices, arranjos) são as variáveis do projeto, em Condições e
//! restrições. Cada perfil entra com os números 2D do próprio perfil
//! (a fonte "modelo" do Python; a polar do NeuralFoil no Re da asa fica de fora).
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const catalog = @import("catalog");
const aerodynamics = @import("aerodynamics.zig");

const params_mod = aircraft_model.params;
const sizing = core.sizing;
const sizing_types = sizing.types;
const Variable = sizing_types.Variable;
const Quantity = sizing_types.Quantity;
const g0 = 9.80665;

/// a análise, com a interface de `simulation.check`
pub const Mdo = struct {
    pub const name: []const u8 = "mdo";
    pub const title: [:0]const u8 = "Mini-MDO (otimizador)";
    pub const area: []const u8 = "Dimensionamento inicial";
    pub const description: []const u8 = "Dimensionamento inicial como otimização, sem precisar de avião aberto (é ele que se procura): envergadura, área, afilamento, perfis, motor × hélice, número de motores, inclinação e arranjo saem juntos do otimizador do núcleo (PSO ou busca aleatória), que maximiza o MTOW ou a eficiência estrutural. As variáveis (faixas e listas de perfis, motores, hélices e arranjos), as condições, as regras de massa e as restrições são as de Condições e restrições…; uma restrição que o melhor não cumpre fica em vermelho no diagnóstico. A empenagem entra como fração da área da asa.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
    pub const standalone = withoutAircraft;
};

/// o Mini-MDO procura o avião: roda sem avião aberto
fn withoutAircraft(_: simulation.Values) bool {
    return true;
}

// ------------------------------------------------------------------ escolhas (a ordem do núcleo)
const kinds = [_][]const u8{ "convencional", "asa voadora", "tailsitter", "VTOL" }; // AircraftKind
const objectives = [_][]const u8{ "MTOW", "EE" }; // Objective
const methods = [_][]const u8{ "PSO (enxame de partículas)", "busca aleatória" }; // SearchMethod

/// um arranjo dos motores e o que ele muda nas contas (`LAYOUT_DATA` do Python)
const Layout = struct { name: []const u8, data: sizing_types.LayoutData };
const layouts = [_]Layout{
    .{ .name = "tratora no nariz", .data = .{ .n_min = 1, .n_max = 1, .n_step = 1, .thrust_factor = 1.0, .nacelle_CDS = 0.0, .mass_per_motor = 0.0 } },
    .{ .name = "dois motores na asa", .data = .{ .n_min = 2, .n_max = 8, .n_step = 2, .thrust_factor = 1.0, .nacelle_CDS = 0.004, .mass_per_motor = 0.12 } },
    .{ .name = "propulsora atrás da asa", .data = .{ .n_min = 1, .n_max = 1, .n_step = 1, .thrust_factor = 0.9, .nacelle_CDS = 0.0, .mass_per_motor = 0.05 } },
};

const layout_list = blk: {
    var names: [layouts.len][]const u8 = undefined;
    for (layouts, 0..) |layout, i| names[i] = layout.name;
    break :blk names;
};

/// os NACA de 4 dígitos que entram na lista além dos perfis da aeronave
const extra_airfoils = [_][]const u8{ "NACA 0012", "NACA 2412", "NACA 4412", "NACA 6412" };

/// as restrições de partida quando não há projeto aberto (os testes): as ligadas de `registry.default_constraints`
const default_constraints = [_]simulation.SprintConstraint{
    .{ .key = "V_S", .label = "velocidade de estol", .unit = "m/s", .op = "≤", .value = 11 },
    .{ .key = "b", .label = "envergadura", .unit = "m", .op = "≤", .value = 2.5 },
    .{ .key = "s_to", .label = "corrida de decolagem", .unit = "m", .op = "≤", .value = 50 },
    .{ .key = "RC", .label = "razão de subida máxima", .unit = "m/s", .op = "≥", .value = 1 },
};

/// a grandeza do núcleo com a chave do registro ("S", "b", "V_S"...: `sizing_types.q_names`); nula: fora do
/// dimensionamento inicial (comprimento, cargas pagas, margem estática: as etapas conferem)
fn quantityOf(name_key: []const u8) ?Quantity {
    for (sizing_types.q_names, 0..) |name, i| if (std.mem.eql(u8, name, name_key)) return @enumFromInt(@as(i32, @intCast(i)));
    return null;
}

/// o sentido da restrição do projeto ("≤", "≥", "=")
fn comparisonOf(op: []const u8) sizing_types.Comparison {
    if (std.mem.eql(u8, op, "≥")) return .at_least;
    if (std.mem.eql(u8, op, "=")) return .equal;
    return .at_most;
}

/// as restrições ligadas de "Condições e restrições" (sem projeto: as de partida)
fn projectConstraints(memory: std.mem.Allocator) ![]const simulation.SprintConstraint {
    const sprint = simulation.sprint orelse return &default_constraints;
    return sprint.constraints(memory);
}

/// as condições e as regras de "Condições e restrições" (sem projeto: as de partida)
fn projectConditions() simulation.SprintConditions {
    const sprint = simulation.sprint orelse return .{};
    return sprint.conditions();
}

/// uma variável contínua da busca: a entrada do projeto (Condições e restrições → Variáveis) e a faixa de partida
/// quando não há projeto (`INPUTS` do Python)
const RangeVariable = struct { variable: Variable, key: []const u8, label: []const u8, unit: []const u8, low: f64, high: f64, integer: bool = false };
const range_variables = [_]RangeVariable{
    .{ .variable = .span, .key = "wing.span", .label = "envergadura", .unit = "m", .low = 1.0, .high = 3.0 },
    .{ .variable = .area, .key = "wing.area", .label = "área da asa", .unit = "m²", .low = 0.3, .high = 1.5 },
    .{ .variable = .taper, .key = "wing.taper", .label = "afilamento", .unit = "", .low = 0.3, .high = 1.0 },
    .{ .variable = .tilt, .key = "power.tilt", .label = "inclinação do motor", .unit = "°", .low = 0, .high = 0 },
    .{ .variable = .motors, .key = "power.motors", .label = "nº de motores", .unit = "", .low = 1, .high = 1, .integer = true },
};

/// as variáveis do projeto (sem projeto: nenhuma, e a busca usa as faixas de partida)
fn projectVariables(memory: std.mem.Allocator) ![]const simulation.SprintVariable {
    const sprint = simulation.sprint orelse return &.{};
    return sprint.variables(memory);
}

fn findVariable(variables: []const simulation.SprintVariable, name: []const u8) ?simulation.SprintVariable {
    for (variables) |variable| if (std.mem.eql(u8, variable.key, name)) return variable;
    return null;
}

fn varies(variable: simulation.SprintVariable) bool {
    return std.mem.eql(u8, variable.mode, "variável");
}

/// a faixa de uma variável contínua: a do projeto se ela é "variável", o valor do rascunho se é fixa; sem projeto,
/// a de partida
fn rangeOf(variables: []const simulation.SprintVariable, field: RangeVariable) [2]f64 {
    const variable = findVariable(variables, field.key) orelse return .{ field.low, field.high };
    if (varies(variable)) return .{ @min(variable.lo, variable.hi), @max(variable.lo, variable.hi) };
    if (std.math.isFinite(variable.number)) return .{ variable.number, variable.number };
    return .{ field.low, field.high };
}

/// os itens de uma lista do projeto: as opções se ela é "variável" (sem opções: `everything`, "vazio = todos"),
/// senão o escolhido no rascunho; vazio sem nada
fn listOf(memory: std.mem.Allocator, variables: []const simulation.SprintVariable, name: []const u8, everything: []const []const u8) ![]const []const u8 {
    const variable = findVariable(variables, name) orelse return &.{};
    if (varies(variable)) {
        if (variable.options.len > 0) return variable.options;
        if (everything.len > 0) return everything;
    }
    if (variable.text.len > 0) return memory.dupe([]const u8, &.{variable.text});
    return &.{};
}

/// um perfil pelo nome: o do projeto ou da biblioteca; sem ele, o NACA pelo nome
fn airfoilNamed(memory: std.mem.Allocator, name: []const u8) !aircraft_model.aircraft.Airfoil {
    if (simulation.sprint) |sprint| if (try sprint.airfoil(memory, name)) |found| return found;
    return .{ .name = name };
}

const plots = [_]simulation.Plot{
    .{ .key = "mdo_hist", .title = "Objetivo por iteração (linha: o melhor até ali)", .xlabel = "iteração", .ylabel = "objetivo" },
    .{ .key = "mdo_cloud", .title = "Indivíduos: MTOW × área da asa", .xlabel = "área da asa (m²)", .ylabel = "MTOW (kg)" },
    .{ .key = "mdo_plan", .title = "Asa do indivíduo (clique num ponto acima; sem escolha, a do melhor)", .xlabel = "y (m)", .ylabel = "x (m)" },
    .{ .key = "mdo_TD", .title = "Tração e arrasto no MTOW", .xlabel = "V (m/s)", .ylabel = "força (N)" },
};

const color_feasible = "#1f77b4";
/// o grupo de escolha dos indivíduos nos gráficos
const pick_group = "indivíduo";
const color_infeasible = "#b0b0b0";
const color_best = "#d62728";
const color_drag = "#eb6834";

const RunState = struct {
    cfg: sizing_types.SizingCfg = .{},
    opts: sizing_types.OptOpts = .{},
    constraints: []const simulation.SprintConstraint = &.{}, // as de "Condições e restrições", na ordem de `cfg.cons`
    airfoil_names: [][]const u8 = &.{},
    set_names: [][]const u8 = &.{},
    layout_names: [][]const u8 = &.{},
    individuals: []sizing_types.Individual = &.{},
    evaluated: usize = 0,
    best: sizing_types.SizingOut = .{},
    wing_count: f64 = 1,
    skipped: []const u8 = "",
    done: bool = false,
};

// ------------------------------------------------------------------ campos
/// o perfil da primeira asa (sem lista no projeto)
fn wingAirfoil(aircraft: ?*const simulation.Aircraft) []const u8 {
    const plane = aircraft orelse return extra_airfoils[1];
    const wing = params_mod.firstSurface(plane, "wing") orelse return extra_airfoils[1];
    return wing.airfoil.name;
}

fn writeFields(out: *simulation.Writer, _: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var params: std.ArrayList(simulation.Param) = .empty;
    const search = "Busca";
    const kind = values.text("kind", kinds[0]);
    try params.append(memory, .{ .key = "kind", .label = "tipo de aeronave", .kind = .choice, .default = .{ .text = kinds[0] }, .choices = &kinds, .group = search, .rebuild = true, .help = "convencional: asas com empenagem; asa voadora/tailsitter: sem EH, C_L,max de equilíbrio menor; tailsitter decola na vertical; VTOL paira se a tração deixar" });
    if (std.mem.eql(u8, kind, kinds[0])) try params.append(memory, .{ .key = "wings", .label = "asas", .kind = .int, .default = .{ .number = 1 }, .minimum = 1, .maximum = 8, .group = search, .help = "asas de mesma envergadura que dividem a área (interferência de Prandtl entre elas)" });
    try params.appendSlice(memory, &.{
        .{ .key = "objective", .label = "maximizar", .kind = .choice, .default = .{ .text = objectives[0] }, .choices = &objectives, .group = search, .help = "MTOW ou EE = CP/PV" },
        .{ .key = "method", .label = "otimizador", .kind = .choice, .default = .{ .text = methods[0] }, .choices = &methods, .group = search, .help = "a busca aleatória serve de referência" },
        .{ .key = "particles", .label = "população", .kind = .int, .default = .{ .number = 24 }, .minimum = 2, .maximum = 256, .group = search, .help = "PSO: partículas por iteração" },
        .{ .key = "iterations", .label = "iterações", .kind = .int, .default = .{ .number = 40 }, .minimum = 1, .maximum = 2000, .group = search },
        .{ .key = "seed", .label = "semente", .kind = .int, .default = .{ .number = 1 }, .minimum = 0, .maximum = 1e6, .group = search, .help = "a mesma semente repete o resultado" },
        .{ .key = "penalty", .label = "penalidade", .default = .{ .number = 10 }, .minimum = 0, .maximum = 1000, .group = search, .help = "pontuação perdida por violação relativa das restrições" },
        .{ .key = "tail_area_frac", .label = "empenagem / asa (área)", .default = .{ .number = 0.25 }, .minimum = 0, .maximum = 1, .group = search, .help = "fração usada na massa e no arrasto" },
        .{ .key = "fuselage_CDS", .label = "C_D·S da fuselagem e trem", .default = .{ .number = 0.012 }, .minimum = 0, .maximum = 0.2, .unit = "m²", .group = search },
    });
    try simulation.writeSpecs(out, params.items, &plots, Mdo.description, .{});
}

// ------------------------------------------------------------------ a configuração do núcleo
fn choiceIndex(choices: []const []const u8, chosen: []const u8) usize {
    for (choices, 0..) |choice, i| if (std.mem.eql(u8, choice, chosen)) return i;
    return 0;
}

/// a unidade de tração do núcleo para um motor, uma hélice e uma bateria do catálogo (`prop_native` do Python)
fn propUnit(motor: catalog.Motor, propeller: catalog.Propeller, battery: catalog.Battery) core.types.PropUnit {
    var unit: core.types.PropUnit = .{ .model = .motor, .D = propeller.D, .Ip = propeller.Ip, .Jm = motor.Jm, .Kv = motor.Kv, .Rm = motor.Rm, .B = motor.B, .tauc = motor.tauc, .Imax = motor.Imax, .Voc = battery.voc(), .Rint = battery.Rint };
    const count = @min(propeller.J.len, propeller.CT.len, propeller.CP.len, core.limits.max_prop_pts);
    for (0..count) |i| {
        unit.J[i] = propeller.J[i];
        unit.CT[i] = propeller.CT[i];
        unit.CP[i] = propeller.CP[i];
    }
    unit.n_pts = @intCast(count);
    return unit;
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    const aircraft = run.aircraft;
    const cfg = &state.cfg;
    // as variáveis e as listas são as de "Condições e restrições → Variáveis" (as mesmas das etapas)
    const variables = try projectVariables(memory);
    var skipped: std.ArrayList(u8) = .empty;

    const kind = choiceIndex(&kinds, values.text("kind", kinds[0]));
    const wing_count: i32 = if (kind == 0) @intFromFloat(@max(1, @round(values.number("wings", 1)))) else 1;
    state.wing_count = @floatFromInt(wing_count);
    // as condições e as regras de massa são as de "Condições e restrições" (as mesmas das etapas)
    const conditions = projectConditions();
    const cruise_speed = if (conditions.V_cruise > 0) conditions.V_cruise else aerodynamics.cruise(aircraft);
    cfg.* = .{
        .kind = @enumFromInt(@as(i32, @intCast(kind))),
        .objective = @enumFromInt(@as(i32, @intCast(choiceIndex(&objectives, values.text("objective", objectives[0]))))),
        .wing_count = wing_count,
        .rho = core.constraints.isaRho(conditions.density_altitude),
        .mu = conditions.mu_roll,
        .V_turn = if (conditions.V_turn > 0) conditions.V_turn else cruise_speed,
        .mu_brake = conditions.mu_brake,
        .m_max = massCeiling(variables),
        .tail_area_frac = values.number("tail_area_frac", 0.25),
        .fuselage_CDS = values.number("fuselage_CDS", 0.012),
        .wing_density = conditions.wing_density,
        .tail_density = conditions.tail_density,
        .fuselage_mass = conditions.fuselage_density * 0.8,
        .systems_mass = conditions.systems_mass,
        .gear_mass = conditions.gear_mass,
    };
    state.opts = .{
        .method = @enumFromInt(@as(i32, @intCast(choiceIndex(&methods, values.text("method", methods[0]))))),
        .particles = @intFromFloat(@max(2, @round(values.number("particles", 24)))),
        .iterations = @intFromFloat(@max(1, @round(values.number("iterations", 40)))),
        .seed = @round(values.number("seed", 1)),
        .penalty = values.number("penalty", 10),
    };

    // perfis: os da lista do projeto (sem lista: o da asa); a ponta, se varia, entra na mesma lista
    var airfoil_list: std.ArrayList([]const u8) = .empty;
    try airfoil_list.appendSlice(memory, try listOf(memory, variables, "wing.airfoil", &.{}));
    if (airfoil_list.items.len == 0) try airfoil_list.append(memory, wingAirfoil(aircraft));
    const tip_varies = if (findVariable(variables, "wing.airfoil_tip")) |tip| varies(tip) and tip.options.len > 0 else false;
    if (tip_varies) for (findVariable(variables, "wing.airfoil_tip").?.options) |tip| {
        if (!containsName(airfoil_list.items, tip)) try airfoil_list.append(memory, tip);
    };
    var names: std.ArrayList([]const u8) = .empty;
    for (airfoil_list.items) |airfoil_name| {
        if (names.items.len >= sizing_types.max_airfoils) break;
        const numbers = params_mod.props2d(try airfoilNamed(memory, airfoil_name)) catch {
            try skipped.print(memory, "perfil {s} (sem contorno válido); ", .{airfoil_name});
            continue;
        };
        cfg.airfoils[names.items.len] = .{ .cla = numbers[0], .a0_deg = numbers[1], .clmax = numbers[2], .cd0 = numbers[3], .cm = numbers[4] };
        try names.append(memory, airfoil_name);
    }
    if (names.items.len == 0) {
        const fallback: aircraft_model.aircraft.Airfoil = .{ .name = extra_airfoils[1] };
        const numbers = params_mod.props2d(fallback) catch unreachable;
        cfg.airfoils[0] = .{ .cla = numbers[0], .a0_deg = numbers[1], .clmax = numbers[2], .cd0 = numbers[3], .cm = numbers[4] };
        try names.append(memory, fallback.name);
    }
    state.airfoil_names = names.items;
    cfg.n_airfoils = @intCast(names.items.len);
    const last_airfoil: f64 = @floatFromInt(names.items.len - 1);
    cfg.tip_same = if (tip_varies) 0 else 1;

    // conjuntos de tração: cada motor × cada hélice das listas do projeto, com a bateria do rascunho
    const battery_name = if (simulation.sprint) |sprint| try sprint.field_text(memory, "power_draft.battery") else "";
    const battery = if (catalog.find(catalog.Battery, &catalog.batteries, battery_name)) |found| found.* else catalog.batteries[0];
    var motors: std.ArrayList(catalog.Motor) = .empty;
    for (try listOf(memory, variables, "power.motor", try catalog.motorNames(memory))) |motor_name| {
        if (catalog.findMotor(motor_name)) |motor| try motors.append(memory, motor) else try skipped.print(memory, "motor {s} (fora do catálogo); ", .{motor_name});
    }
    if (motors.items.len == 0) try motors.append(memory, catalog.motors[0]);
    var propellers: std.ArrayList(catalog.Propeller) = .empty;
    for (try listOf(memory, variables, "power.propeller", try catalog.propellerNames(memory))) |propeller_name| {
        if (catalog.findPropeller(propeller_name)) |propeller| try propellers.append(memory, propeller) else try skipped.print(memory, "hélice {s} (fora do catálogo); ", .{propeller_name});
    }
    if (propellers.items.len == 0) try propellers.append(memory, catalog.propellers[0]);
    var set_names: std.ArrayList([]const u8) = .empty;
    for (motors.items) |motor| for (propellers.items) |propeller| {
        if (set_names.items.len >= sizing_types.max_sets) break;
        cfg.sets[set_names.items.len] = .{ .unit = propUnit(motor, propeller, battery), .mass = motor.mass + propeller.mass + battery.mass, .P_max = motor.Imax * battery.voc() };
        try set_names.append(memory, try std.fmt.allocPrint(memory, "{s} | {s}", .{ motor.name, propeller.name }));
    };
    state.set_names = set_names.items;
    cfg.n_sets = @intCast(set_names.items.len);

    // arranjos: os da lista do projeto que o dimensionamento inicial conhece
    var layout_names: std.ArrayList([]const u8) = .empty;
    for (try listOf(memory, variables, "power.layout", &layout_list)) |layout_name| {
        const layout = for (layouts) |candidate| {
            if (std.mem.eql(u8, candidate.name, layout_name)) break candidate;
        } else {
            try skipped.print(memory, "arranjo {s} (as etapas conferem); ", .{layout_name});
            continue;
        };
        if (containsName(layout_names.items, layout.name)) continue;
        cfg.layouts[layout_names.items.len] = layout.data;
        try layout_names.append(memory, layout.name);
    }
    if (layout_names.items.len == 0) {
        cfg.layouts[0] = layouts[0].data;
        try layout_names.append(memory, layouts[0].name);
    }
    state.layout_names = layout_names.items;
    cfg.n_layouts = @intCast(layout_names.items.len);

    // variáveis contínuas
    for (range_variables) |field| {
        const range = rangeOf(variables, field);
        cfg.vars[sizing_types.variable(field.variable)] = .{ .lo = range[0], .hi = range[1], .kind = if (field.integer) .integer else .continuous };
    }
    cfg.vars[sizing_types.variable(.airfoil)] = .{ .lo = 0, .hi = last_airfoil, .kind = .list };
    cfg.vars[sizing_types.variable(.airfoil_tip)] = .{ .lo = 0, .hi = if (tip_varies) last_airfoil else 0, .kind = .list };
    cfg.vars[sizing_types.variable(.set)] = .{ .lo = 0, .hi = @floatFromInt(set_names.items.len - 1), .kind = .list };
    cfg.vars[sizing_types.variable(.layout)] = .{ .lo = 0, .hi = @floatFromInt(layout_names.items.len - 1), .kind = .list };

    // as restrições ligadas de "Condições e restrições"; as que o dimensionamento inicial não calcula ficam para as
    // etapas
    var count: usize = 0;
    var used: std.ArrayList(simulation.SprintConstraint) = .empty;
    for (try projectConstraints(memory)) |constraint| {
        const which = quantityOf(constraint.key) orelse {
            try skipped.print(memory, "restrição {s} (as etapas conferem); ", .{constraint.label});
            continue;
        };
        if (count >= sizing_types.max_cons) break;
        cfg.cons[count] = .{ .q = which, .op = comparisonOf(constraint.op), .value = constraint.value, .tol = constraint.tol };
        try used.append(memory, constraint);
        count += 1;
    }
    cfg.n_cons = @intCast(count);
    state.constraints = used.items;
    state.skipped = skipped.items;

    const capacity: usize = @intCast(@as(i64, state.opts.particles) * state.opts.iterations);
    state.individuals = try memory.alloc(sizing_types.Individual, capacity);
    run.say("otimizando: {d} avaliações", .{capacity});
    run.progress = 0.05;
}

/// o teto da busca do MTOW: o máximo da massa do projeto se ela é "variável"; senão 30 kg
fn massCeiling(variables: []const simulation.SprintVariable) f64 {
    const mass = findVariable(variables, "req.mass") orelse return 30;
    return if (varies(mass)) @max(mass.lo, mass.hi) else 30;
}

fn containsName(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn advanceRun(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    if (state.done) return true;
    const memory = run.memory();
    const work = try memory.create(core.types.Params);
    work.* = .{};
    // a cada iteração: o progresso, e o "Parar" corta a busca ali mesmo (fica o melhor até então)
    const watch = struct {
        fn onIteration(context: ?*anyopaque, iteration: i32, recorded: usize) callconv(.c) i32 {
            const watched: *simulation.Run = @ptrCast(@alignCast(context.?));
            const watched_state: *RunState = @ptrCast(@alignCast(watched.state.?));
            const total: f32 = @floatFromInt(@max(watched_state.individuals.len, 1));
            watched.progress = 0.05 + 0.9 * @min(@as(f32, @floatFromInt(recorded)) / total, 1.0);
            watched.say("otimizando: iteração {d}, {d} avaliações", .{ iteration, recorded });
            return @intFromBool(watched.cancelled());
        }
    };
    sizing.optimize(&state.cfg, &state.opts, work, state.individuals, &state.evaluated, &state.best, watch.onIteration, run);
    state.done = true;
    run.progress = 1;
    return true;
}

// ------------------------------------------------------------------ resultado
fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn listItem(names: []const []const u8, value: f64) []const u8 {
    const index: usize = @intFromFloat(std.math.clamp(@round(value), 0, @as(f64, @floatFromInt(names.len - 1))));
    return names[index];
}

/// quem é melhor: o viável vence o inviável; depois a aptidão (`history` do Python)
fn better(candidate: sizing_types.Individual, current: sizing_types.Individual) bool {
    if (candidate.feasible != current.feasible) return candidate.feasible > current.feasible;
    return candidate.fitness > current.fitness;
}

/// o contorno da asa (as duas metades, trapezoidal; x para frente), como `planform` do Python
fn planform(memory: std.mem.Allocator, span: f64, area: f64, taper: f64) ![2][]const f64 {
    const ratio = @max(taper, 0.05);
    const root = 2 * area / (span * (1 + ratio));
    const tip = ratio * root;
    const half = span / 2;
    const sweep = (root - tip) / 4;
    return .{
        try memory.dupe(f64, &.{ 0, half, half, 0, -half, -half, 0 }),
        try memory.dupe(f64, &.{ 0, -sweep, -sweep - tip, -root, -sweep - tip, -sweep, 0 }),
    };
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    const best = state.best;
    const quantity = struct {
        fn of(result: sizing_types.SizingOut, which: Quantity) f64 {
            return result.q[sizing_types.quantity(which)];
        }
    }.of;
    const x = best.x;
    const mtow_objective = state.cfg.objective == .mtow;
    const objective_label: []const u8 = if (mtow_objective) "MTOW (kg)" else "EE";
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;

    try summary.append(memory, .{ "busca", try text(memory, "{s}, {d} avaliações, maximizar {s}", .{ methods[@intCast(@intFromEnum(state.opts.method))], state.evaluated, objective_label }) });
    try summary.append(memory, .{ "melhor: MTOW (kg), PV (kg), CP (kg), EE", try text(memory, "{d:.3}, {d:.3}, {d:.3}, {d:.3}", .{ quantity(best, .mtow), quantity(best, .empty_mass), quantity(best, .payload), quantity(best, .structural_efficiency) }) });
    try summary.append(memory, .{ "asa: b (m), S (m²), AR, afilamento, corda da raiz (m)", try text(memory, "{d:.3}, {d:.4}, {d:.2}, {d:.3}, {d:.3}", .{ x[sizing_types.variable(.span)], x[sizing_types.variable(.area)], quantity(best, .aspect_ratio), x[sizing_types.variable(.taper)], quantity(best, .root_chord) }) });
    try summary.append(memory, .{ "perfil da raiz / da ponta", try text(memory, "{s} / {s}", .{ listItem(state.airfoil_names, x[sizing_types.variable(.airfoil)]), if (state.cfg.tip_same == 1) listItem(state.airfoil_names, x[sizing_types.variable(.airfoil)]) else listItem(state.airfoil_names, x[sizing_types.variable(.airfoil_tip)]) }) });
    try summary.append(memory, .{ "motor | hélice", listItem(state.set_names, x[sizing_types.variable(.set)]) });
    try summary.append(memory, .{ "motores, inclinação (°), arranjo", try text(memory, "{d:.0}, {d:.2}, {s}", .{ x[sizing_types.variable(.motors)], x[sizing_types.variable(.tilt)], listItem(state.layout_names, x[sizing_types.variable(.layout)]) }) });
    try summary.append(memory, .{ "V_S, V máx., V de L/D máx. (m/s)", try text(memory, "{d:.2}, {d:.2}, {d:.2}", .{ quantity(best, .stall_speed), quantity(best, .max_speed), quantity(best, .best_glide_speed) }) });
    try summary.append(memory, .{ "corrida (m), subida (m/s), T/W, L/D máx.", try text(memory, "{d:.1}, {d:.2}, {d:.3}, {d:.2}", .{ quantity(best, .takeoff_run), quantity(best, .climb_rate), quantity(best, .thrust_to_weight), quantity(best, .max_lift_to_drag) }) });
    try summary.append(memory, .{ "polar: C_D0, K, C_L,max, C_L na corrida", try text(memory, "{d:.4}, {d:.4}, {d:.3}, {d:.3}", .{ best.CD0, best.K, best.CLmax, best.CLg }) });
    try summary.append(memory, .{ "perfis", "os números 2D do próprio perfil (modelo); o NeuralFoil no Re da asa fica no Python" });
    if (state.skipped.len > 0) try summary.append(memory, .{ "fora da busca", state.skipped });

    // as restrições no melhor
    const group = "restrições no melhor indivíduo";
    for (state.cfg.cons[0..@intCast(state.cfg.n_cons)], state.constraints) |constraint, field| {
        const value = quantity(best, constraint.q);
        const ok = sizing_types.violation(constraint, value) == 0;
        try checks.append(memory, .{
            .status = if (ok) .ok else .falha,
            .item = field.label,
            .value = try text(memory, "{d:.3} {s}", .{ value, field.unit }),
            .criterion = try text(memory, "{s} {s} {d} {s}", .{ field.label, field.op, constraint.value, field.unit }),
            .why = if (ok) "" else "o otimizador não achou um indivíduo que cumpra tudo",
            .fix = if (ok) "" else "em Condições e restrições: abrir a faixa das variáveis, pôr mais perfis, motores ou hélices nas listas, ou afrouxar a restrição",
            .group = group,
        });
    }
    // variáveis encostadas no limite (por que a asa parou de mudar)
    for (range_variables) |field| {
        const spec = state.cfg.vars[sizing_types.variable(field.variable)];
        if (spec.hi - spec.lo <= 1e-12) continue;
        const value = x[sizing_types.variable(field.variable)];
        const tolerance = 1e-3 * (spec.hi - spec.lo);
        const edge: ?[]const u8 = if (value >= spec.hi - tolerance) "máximo" else if (value <= spec.lo + tolerance) "mínimo" else null;
        if (edge) |which| try checks.append(memory, .{
            .status = .atencao,
            .item = try text(memory, "{s} no {s} da faixa", .{ field.label, which }),
            .value = try text(memory, "{d:.3} {s}", .{ value, field.unit }),
            .criterion = try text(memory, "faixa {d} a {d} {s}", .{ spec.lo, spec.hi, field.unit }),
            .why = "o otimizador quer ir além da faixa",
            .fix = "abrir a faixa em Condições e restrições → Variáveis, se a regra deixar",
            .group = "variáveis",
        });
    }
    try checks.append(memory, .{
        .status = if (best.feasible != 0) .ok else .falha,
        .item = "melhor indivíduo viável",
        .value = try text(memory, "violação {d:.4}", .{best.violation}),
        .criterion = "todas as restrições ligadas",
        .group = group,
    });

    const figures = try simulation.Figures.init(memory, &plots);
    const individuals = state.individuals[0..state.evaluated];
    // o objetivo de cada indivíduo (viáveis e inviáveis) e o melhor até cada iteração
    var feasible_x: std.ArrayList(f64) = .empty;
    var feasible_y: std.ArrayList(f64) = .empty;
    var infeasible_x: std.ArrayList(f64) = .empty;
    var infeasible_y: std.ArrayList(f64) = .empty;
    var cloud_feasible_x: std.ArrayList(f64) = .empty;
    var cloud_feasible_y: std.ArrayList(f64) = .empty;
    var cloud_infeasible_x: std.ArrayList(f64) = .empty;
    var cloud_infeasible_y: std.ArrayList(f64) = .empty;
    var feasible_ids: std.ArrayList(f64) = .empty;
    var infeasible_ids: std.ArrayList(f64) = .empty;
    var history_x: std.ArrayList(f64) = .empty;
    var history_y: std.ArrayList(f64) = .empty;
    var leader: ?sizing_types.Individual = null;
    var iteration: i32 = if (individuals.len > 0) individuals[0].iter else 0;
    for (individuals, 0..) |individual, i| {
        const objective = if (mtow_objective) individual.mtow else individual.ee;
        const iter: f64 = @floatFromInt(individual.iter);
        const area = individual.x[sizing_types.variable(.area)];
        const id: f64 = @floatFromInt(i);
        if (individual.feasible != 0) {
            try feasible_ids.append(memory, id);
            try feasible_x.append(memory, iter);
            try feasible_y.append(memory, objective);
            try cloud_feasible_x.append(memory, area);
            try cloud_feasible_y.append(memory, individual.mtow);
        } else {
            try infeasible_ids.append(memory, id);
            try infeasible_x.append(memory, iter);
            try infeasible_y.append(memory, objective);
            try cloud_infeasible_x.append(memory, area);
            try cloud_infeasible_y.append(memory, individual.mtow);
        }
        if (leader == null or better(individual, leader.?)) leader = individual;
        const last = i + 1 == individuals.len or individuals[i + 1].iter != individual.iter;
        if (last) {
            try history_x.append(memory, @floatFromInt(iteration));
            try history_y.append(memory, if (mtow_objective) leader.?.mtow else leader.?.ee);
            if (i + 1 < individuals.len) iteration = individuals[i + 1].iter;
        }
    }
    // os indivíduos são um grupo de escolha: clicar (ou arrastar) num ponto mostra a asa dele
    try figures.curve("mdo_hist", .{ .name = "inviáveis", .x = infeasible_x.items, .y = infeasible_y.items, .marker = "x", .size = 4, .color = color_infeasible, .pick = pick_group, .ids = infeasible_ids.items });
    try figures.curve("mdo_hist", .{ .name = "viáveis", .x = feasible_x.items, .y = feasible_y.items, .marker = "o", .size = 4, .color = color_feasible, .pick = pick_group, .ids = feasible_ids.items });
    try figures.curve("mdo_hist", .{ .name = try text(memory, "melhor ({s})", .{objective_label}), .x = history_x.items, .y = history_y.items, .width = 2, .color = color_best });
    try figures.curve("mdo_cloud", .{ .name = "inviáveis", .x = cloud_infeasible_x.items, .y = cloud_infeasible_y.items, .marker = "x", .size = 4, .color = color_infeasible, .pick = pick_group, .ids = infeasible_ids.items });
    try figures.curve("mdo_cloud", .{ .name = "viáveis", .x = cloud_feasible_x.items, .y = cloud_feasible_y.items, .marker = "o", .size = 4, .color = color_feasible, .pick = pick_group, .ids = feasible_ids.items });
    try figures.curve("mdo_cloud", .{ .name = "melhor", .x = try memory.dupe(f64, &.{x[sizing_types.variable(.area)]}), .y = try memory.dupe(f64, &.{quantity(best, .mtow)}), .marker = "o", .size = 9, .color = color_best });

    const outline = try planform(memory, x[sizing_types.variable(.span)], x[sizing_types.variable(.area)] / state.wing_count, x[sizing_types.variable(.taper)]);
    try figures.curve("mdo_plan", .{ .name = try text(memory, "melhor: b = {d:.2} m, S = {d:.3} m²", .{ x[sizing_types.variable(.span)], x[sizing_types.variable(.area)] / state.wing_count }), .x = outline[0], .y = outline[1], .width = 2, .color = color_feasible, .pick = pick_group, .shows = -1 });
    // a asa de cada indivíduo, que aparece quando ele é escolhido num dos gráficos de cima
    for (individuals, 0..) |individual, i| {
        const span = individual.x[sizing_types.variable(.span)];
        const area = individual.x[sizing_types.variable(.area)] / state.wing_count;
        const shape = try planform(memory, span, area, individual.x[sizing_types.variable(.taper)]);
        try figures.curve("mdo_plan", .{
            .name = try text(memory, "#{d} ({s}): b = {d:.2} m, S = {d:.3} m², MTOW = {d:.2} kg, {s}, {s}", .{ i, if (individual.feasible != 0) "viável" else "inviável", span, area, individual.mtow, listItem(state.airfoil_names, individual.x[sizing_types.variable(.airfoil)]), listItem(state.set_names, individual.x[sizing_types.variable(.set)]) }),
            .x = shape[0],
            .y = shape[1],
            .width = 2,
            .color = if (individual.feasible != 0) color_feasible else color_infeasible,
            .pick = pick_group,
            .shows = @floatFromInt(i),
        });
    }

    var curve_points: usize = sizing_types.n_curve;
    while (curve_points > 1 and best.V[curve_points - 1] == 0) curve_points -= 1;
    // a partir do estol: abaixo dele o arrasto induzido explode e esconde o cruzamento
    var first: usize = 0;
    while (first + 2 < curve_points and best.V[first] < quantity(best, .stall_speed)) first += 1;
    if (curve_points > first + 1) {
        try figures.curve("mdo_TD", .{ .name = "tração disponível", .x = try memory.dupe(f64, best.V[first..curve_points]), .y = try memory.dupe(f64, best.T[first..curve_points]), .color = color_feasible });
        try figures.curve("mdo_TD", .{ .name = "arrasto", .x = try memory.dupe(f64, best.V[first..curve_points]), .y = try memory.dupe(f64, best.D[first..curve_points]), .color = color_drag });
    }

    try simulation.beginResult(out, summary.items, checks.items);
    try figures.write(out, true);
    try simulation.endResult(out);
}

const testing = std.testing;

test "Mini-MDO: roda o otimizador e sai um indivíduo viável" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Mdo);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"particles\": 8, \"iterations\": 5}"));
    try testing.expect(try registered.advance(&run));
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
    const state: *RunState = @ptrCast(@alignCast(run.state.?));
    try testing.expectEqual(@as(usize, 40), state.evaluated);
    try testing.expect(state.best.q[sizing_types.quantity(.mtow)] > 0);
}

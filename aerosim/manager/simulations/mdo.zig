//! Mini-MDO em Zig (o par de `design/mdo.py`): o dimensionamento inicial como otimização. A geometria da asa
//! (envergadura, área, afilamento, perfis), a motorização (motor × hélice do catálogo, nº de motores, inclinação,
//! arranjo) e o envelope saem juntos do otimizador do núcleo (`core/src/sizing`), que maximiza o MTOW ou a
//! eficiência estrutural com as restrições ligadas. Aqui só se monta a configuração e se escreve o resultado.
//!
//! A empenagem não é dimensionada: entra como fração da área da asa (massa e arrasto).
//! Os perfis são os da aeronave aberta e os NACA de 4 dígitos do código, com os números 2D do próprio perfil
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
    pub const description: []const u8 = "Dimensionamento inicial como otimização, sem precisar de avião aberto (é ele que se procura): envergadura, área, afilamento, perfis, motor × hélice, número de motores, inclinação e arranjo saem juntos do otimizador do núcleo (PSO ou busca aleatória), que maximiza o MTOW ou a eficiência estrutural. As condições, as regras de massa e as restrições são as de Condições e restrições…; uma restrição que o melhor não cumpre fica em vermelho no diagnóstico. A empenagem entra como fração da área da asa.";
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

/// uma variável contínua do formulário: a faixa de partida (`INPUTS` do Python); mínimo = máximo deixa fixa
const RangeField = struct { variable: Variable, key: []const u8, label: []const u8, unit: []const u8, low: f64, high: f64, minimum: f64, maximum: f64, integer: bool = false };
const range_fields = [_]RangeField{
    .{ .variable = .span, .key = "span", .label = "envergadura", .unit = "m", .low = 1.0, .high = 3.0, .minimum = 0.2, .maximum = 10 },
    .{ .variable = .area, .key = "area", .label = "área da asa", .unit = "m²", .low = 0.3, .high = 1.5, .minimum = 0.02, .maximum = 10 },
    .{ .variable = .taper, .key = "taper", .label = "afilamento", .unit = "", .low = 0.3, .high = 1.0, .minimum = 0.05, .maximum = 1 },
    .{ .variable = .tilt, .key = "tilt", .label = "inclinação do motor", .unit = "°", .low = 0, .high = 0, .minimum = -10, .maximum = 20 },
    .{ .variable = .motors, .key = "motors", .label = "nº de motores", .unit = "", .low = 1, .high = 1, .minimum = 1, .maximum = 8, .integer = true },
};

const plots = [_]simulation.Plot{
    .{ .key = "mdo_hist", .title = "Objetivo por iteração (linha: o melhor até ali)", .xlabel = "iteração", .ylabel = "objetivo" },
    .{ .key = "mdo_cloud", .title = "Indivíduos: MTOW × área da asa", .xlabel = "área da asa (m²)", .ylabel = "MTOW (kg)" },
    .{ .key = "mdo_plan", .title = "Asa do melhor indivíduo (vista de cima)", .xlabel = "y (m)", .ylabel = "x (m)" },
    .{ .key = "mdo_TD", .title = "Tração e arrasto no MTOW", .xlabel = "V (m/s)", .ylabel = "força (N)" },
};

const color_feasible = "#1f77b4";
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
fn key(memory: std.mem.Allocator, prefix: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(memory, "{s}{d}", .{ prefix, index });
}

/// os perfis candidatos: os das superfícies da aeronave (sem repetir o nome) e os NACA do código
fn airfoilCandidates(memory: std.mem.Allocator, aircraft: ?*const simulation.Aircraft) ![]aircraft_model.aircraft.Airfoil {
    var out: std.ArrayList(aircraft_model.aircraft.Airfoil) = .empty;
    if (aircraft) |plane| for (plane.surfaces) |surface| {
        if (!surface.enabled or surface.vertical) continue;
        if (!contains(out.items, surface.airfoil.name)) try out.append(memory, surface.airfoil);
    };
    for (extra_airfoils) |naca| if (!contains(out.items, naca)) try out.append(memory, .{ .name = naca });
    return out.items;
}

fn contains(items: []const aircraft_model.aircraft.Airfoil, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}

/// o perfil da primeira asa (marcado por padrão)
fn wingAirfoil(aircraft: ?*const simulation.Aircraft) []const u8 {
    const plane = aircraft orelse return extra_airfoils[1];
    const wing = params_mod.firstSurface(plane, "wing") orelse return extra_airfoils[1];
    return wing.airfoil.name;
}

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var params: std.ArrayList(simulation.Param) = .empty;
    const search = "Busca";
    const variables = "Variáveis (mínimo = máximo: fixa)";
    const lists = "Listas (marcadas entram na busca)";
    const kind = values.text("kind", kinds[0]);
    try params.append(memory, .{ .key = "kind", .label = "tipo de aeronave", .kind = .choice, .default = .{ .text = kinds[0] }, .choices = &kinds, .group = search, .rebuild = true, .help = "convencional: asas com empenagem; asa voadora/tailsitter: sem EH, C_L,max de equilíbrio menor; tailsitter decola na vertical; VTOL paira se a tração deixar" });
    if (std.mem.eql(u8, kind, kinds[0])) try params.append(memory, .{ .key = "wings", .label = "asas", .kind = .int, .default = .{ .number = 1 }, .minimum = 1, .maximum = 8, .group = search, .help = "asas de mesma envergadura que dividem a área (interferência de Prandtl entre elas)" });
    try params.appendSlice(memory, &.{
        .{ .key = "objective", .label = "maximizar", .kind = .choice, .default = .{ .text = objectives[0] }, .choices = &objectives, .group = search, .help = "MTOW ou EE = CP/PV" },
        .{ .key = "method", .label = "otimizador", .kind = .choice, .default = .{ .text = methods[0] }, .choices = &methods, .group = search, .help = "a busca aleatória serve de referência" },
        .{ .key = "particles", .label = "população", .kind = .int, .default = .{ .number = 24 }, .minimum = 2, .maximum = 256, .group = search, .help = "PSO: partículas por iteração" },
        .{ .key = "iterations", .label = "iterações", .kind = .int, .default = .{ .number = 40 }, .minimum = 1, .maximum = 2000, .group = search },
        .{ .key = "seed", .label = "semente", .kind = .int, .default = .{ .number = 1 }, .minimum = 0, .maximum = 1e6, .group = search, .help = "a mesma semente repete o resultado" },
        .{ .key = "m_max", .label = "massa máxima na busca", .default = .{ .number = 30 }, .minimum = 1, .maximum = 200, .unit = "kg", .group = search, .help = "teto da busca do MTOW" },
        .{ .key = "penalty", .label = "penalidade", .default = .{ .number = 10 }, .minimum = 0, .maximum = 1000, .group = search, .help = "pontuação perdida por violação relativa das restrições" },
        .{ .key = "tail_area_frac", .label = "empenagem / asa (área)", .default = .{ .number = 0.25 }, .minimum = 0, .maximum = 1, .group = search, .help = "fração usada na massa e no arrasto" },
        .{ .key = "fuselage_CDS", .label = "C_D·S da fuselagem e trem", .default = .{ .number = 0.012 }, .minimum = 0, .maximum = 0.2, .unit = "m²", .group = search },
    });
    for (range_fields) |field| {
        const kind_of: @TypeOf(params.items[0].kind) = if (field.integer) .int else .float;
        try params.append(memory, .{ .key = try std.fmt.allocPrint(memory, "{s}_lo", .{field.key}), .label = try std.fmt.allocPrint(memory, "{s}: mínimo", .{field.label}), .kind = kind_of, .default = .{ .number = field.low }, .minimum = field.minimum, .maximum = field.maximum, .unit = field.unit, .group = variables });
        try params.append(memory, .{ .key = try std.fmt.allocPrint(memory, "{s}_hi", .{field.key}), .label = try std.fmt.allocPrint(memory, "{s}: máximo", .{field.label}), .kind = kind_of, .default = .{ .number = field.high }, .minimum = field.minimum, .maximum = field.maximum, .unit = field.unit, .group = variables });
    }

    const wing_airfoil = wingAirfoil(aircraft);
    for (try airfoilCandidates(memory, aircraft), 0..) |airfoil, i|
        try params.append(memory, .{ .key = try key(memory, "af", i), .label = try std.fmt.allocPrint(memory, "perfil: {s}", .{airfoil.name}), .kind = .bool, .default = .{ .toggle = std.mem.eql(u8, airfoil.name, wing_airfoil) }, .group = lists });
    try params.append(memory, .{ .key = "tip_varies", .label = "perfil da ponta também varia", .kind = .bool, .default = .{ .toggle = false }, .group = lists, .help = "a mesma asa com dois perfis; entre eles, interpolado" });
    for (catalog.motors, 0..) |motor, i|
        try params.append(memory, .{ .key = try key(memory, "mo", i), .label = try std.fmt.allocPrint(memory, "motor: {s}", .{motor.name}), .kind = .bool, .default = .{ .toggle = i == 0 }, .group = lists });
    for (catalog.propellers, 0..) |propeller, i|
        try params.append(memory, .{ .key = try key(memory, "pr", i), .label = try std.fmt.allocPrint(memory, "hélice: {s}", .{propeller.name}), .kind = .bool, .default = .{ .toggle = i == 0 }, .group = lists });
    var battery_names: [catalog.batteries.len][]const u8 = undefined;
    for (catalog.batteries, 0..) |battery, i| battery_names[i] = battery.name;
    try params.append(memory, .{ .key = "battery", .label = "bateria", .kind = .choice, .default = .{ .text = battery_names[0] }, .choices = &battery_names, .group = lists });
    for (layouts, 0..) |layout, i|
        try params.append(memory, .{ .key = try key(memory, "ly", i), .label = try std.fmt.allocPrint(memory, "arranjo: {s}", .{layout.name}), .kind = .bool, .default = .{ .toggle = i == 0 }, .group = lists });
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
        .m_max = values.number("m_max", 30),
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

    // perfis: os marcados (nenhum marcado: o da asa)
    const candidates = try airfoilCandidates(memory, aircraft);
    const wing_airfoil = wingAirfoil(aircraft);
    var names: std.ArrayList([]const u8) = .empty;
    for (candidates, 0..) |airfoil, i| {
        if (!values.toggle(try key(memory, "af", i), std.mem.eql(u8, airfoil.name, wing_airfoil))) continue;
        if (names.items.len >= sizing_types.max_airfoils) break;
        const numbers = params_mod.props2d(airfoil) catch {
            try skipped.print(memory, "perfil {s} (contorno inválido); ", .{airfoil.name});
            continue;
        };
        cfg.airfoils[names.items.len] = .{ .cla = numbers[0], .a0_deg = numbers[1], .clmax = numbers[2], .cd0 = numbers[3], .cm = numbers[4] };
        try names.append(memory, airfoil.name);
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
    const tip_varies = values.toggle("tip_varies", false);
    cfg.tip_same = if (tip_varies) 0 else 1;

    // conjuntos de tração: motor × hélice marcados, com a bateria escolhida
    const battery = catalog.batteries[choiceIndex(&batteryNames(), values.text("battery", catalog.batteries[0].name))];
    var set_names: std.ArrayList([]const u8) = .empty;
    for (catalog.motors, 0..) |motor, i| {
        if (!values.toggle(try key(memory, "mo", i), i == 0)) continue;
        for (catalog.propellers, 0..) |propeller, j| {
            if (!values.toggle(try key(memory, "pr", j), j == 0)) continue;
            if (set_names.items.len >= sizing_types.max_sets) break;
            cfg.sets[set_names.items.len] = .{ .unit = propUnit(motor, propeller, battery), .mass = motor.mass + propeller.mass + battery.mass, .P_max = motor.Imax * battery.voc() };
            try set_names.append(memory, try std.fmt.allocPrint(memory, "{s} | {s}", .{ motor.name, propeller.name }));
        }
    }
    if (set_names.items.len == 0) {
        cfg.sets[0] = .{ .unit = propUnit(catalog.motors[0], catalog.propellers[0], battery), .mass = catalog.motors[0].mass + catalog.propellers[0].mass + battery.mass, .P_max = catalog.motors[0].Imax * battery.voc() };
        try set_names.append(memory, try std.fmt.allocPrint(memory, "{s} | {s}", .{ catalog.motors[0].name, catalog.propellers[0].name }));
        try skipped.appendSlice(memory, "nenhum motor × hélice marcado: o primeiro do catálogo; ");
    }
    state.set_names = set_names.items;
    cfg.n_sets = @intCast(set_names.items.len);

    // arranjos
    var layout_names: std.ArrayList([]const u8) = .empty;
    for (layouts, 0..) |layout, i| {
        if (!values.toggle(try key(memory, "ly", i), i == 0)) continue;
        cfg.layouts[layout_names.items.len] = layout.data;
        try layout_names.append(memory, layout.name);
    }
    if (layout_names.items.len == 0) {
        cfg.layouts[0] = layouts[0].data;
        try layout_names.append(memory, layouts[0].name);
    }
    state.layout_names = layout_names.items;
    cfg.n_layouts = @intCast(layout_names.items.len);

    // variáveis
    for (range_fields) |field| {
        const low = values.number(try std.fmt.allocPrint(memory, "{s}_lo", .{field.key}), field.low);
        const high = values.number(try std.fmt.allocPrint(memory, "{s}_hi", .{field.key}), field.high);
        cfg.vars[sizing_types.variable(field.variable)] = .{ .lo = @min(low, high), .hi = @max(low, high), .kind = if (field.integer) .integer else .continuous };
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

fn batteryNames() [catalog.batteries.len][]const u8 {
    var out: [catalog.batteries.len][]const u8 = undefined;
    for (catalog.batteries, 0..) |battery, i| out[i] = battery.name;
    return out;
}

fn advanceRun(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    if (state.done) return true;
    const memory = run.memory();
    const work = try memory.create(core.types.Params);
    work.* = .{};
    sizing.optimize(&state.cfg, &state.opts, work, state.individuals, &state.evaluated, &state.best, null, null);
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
            .fix = if (ok) "" else "abrir a faixa das variáveis, marcar mais perfis ou conjuntos, ou afrouxar a restrição",
            .group = group,
        });
    }
    // variáveis encostadas no limite (por que a asa parou de mudar)
    for (range_fields) |field| {
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
            .fix = "abrir a faixa, se a regra deixar",
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
    var history_x: std.ArrayList(f64) = .empty;
    var history_y: std.ArrayList(f64) = .empty;
    var leader: ?sizing_types.Individual = null;
    var iteration: i32 = if (individuals.len > 0) individuals[0].iter else 0;
    for (individuals, 0..) |individual, i| {
        const objective = if (mtow_objective) individual.mtow else individual.ee;
        const iter: f64 = @floatFromInt(individual.iter);
        const area = individual.x[sizing_types.variable(.area)];
        if (individual.feasible != 0) {
            try feasible_x.append(memory, iter);
            try feasible_y.append(memory, objective);
            try cloud_feasible_x.append(memory, area);
            try cloud_feasible_y.append(memory, individual.mtow);
        } else {
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
    try figures.curve("mdo_hist", .{ .name = "inviáveis", .x = infeasible_x.items, .y = infeasible_y.items, .marker = "x", .size = 4, .color = color_infeasible });
    try figures.curve("mdo_hist", .{ .name = "viáveis", .x = feasible_x.items, .y = feasible_y.items, .marker = "o", .size = 4, .color = color_feasible });
    try figures.curve("mdo_hist", .{ .name = try text(memory, "melhor ({s})", .{objective_label}), .x = history_x.items, .y = history_y.items, .width = 2, .color = color_best });
    try figures.curve("mdo_cloud", .{ .name = "inviáveis", .x = cloud_infeasible_x.items, .y = cloud_infeasible_y.items, .marker = "x", .size = 4, .color = color_infeasible });
    try figures.curve("mdo_cloud", .{ .name = "viáveis", .x = cloud_feasible_x.items, .y = cloud_feasible_y.items, .marker = "o", .size = 4, .color = color_feasible });
    try figures.curve("mdo_cloud", .{ .name = "melhor", .x = try memory.dupe(f64, &.{x[sizing_types.variable(.area)]}), .y = try memory.dupe(f64, &.{quantity(best, .mtow)}), .marker = "o", .size = 9, .color = color_best });

    const outline = try planform(memory, x[sizing_types.variable(.span)], x[sizing_types.variable(.area)] / state.wing_count, x[sizing_types.variable(.taper)]);
    try figures.curve("mdo_plan", .{ .name = try text(memory, "b = {d:.2} m, S = {d:.3} m²", .{ x[sizing_types.variable(.span)], x[sizing_types.variable(.area)] / state.wing_count }), .x = outline[0], .y = outline[1], .width = 2, .color = color_feasible });

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

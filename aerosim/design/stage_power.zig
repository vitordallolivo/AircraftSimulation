//! A etapa "Motores e montagem" em Zig (`PowerStage` de `stages.py`, contas de `aerosim/design/power.py`): onde
//! ficam os motores, e com isso a bateria (posta onde o CG cai na margem), a carga paga (no CG), a fuselagem e o
//! trem. Mostra o desempenho rápido do avião montado (tração do motor + hélice e corrida no chão, do núcleo) e a
//! massa máxima que a pista permite. "Mandar para a Montagem" grava o avião em "meus aviões" e abre.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const catalog = @import("catalog");
const templates = @import("templates");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");
const airfoils = @import("stage_airfoils.zig");
const tail_stage = @import("stage_tail.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const model = aircraft_model.aircraft;
const ground = core.sizing.ground;
const motorprop = core.sizing.motorprop;

const gravity = 9.80665;
const munk = 0.9; // k2 − k1 de um corpo alongado (fineza ~ 6 a 8)
const layouts = [_][]const u8{ "tratora no nariz", "dois motores na asa", "propulsora atrás da asa", "livre: nariz + asa + atrás" };
const gears = [_][]const u8{ "triciclo", "convencional" };

/// os campos do rascunho (`PowerParams`)
const power_fields = [_]registry.Field{
    .{ .key = "name", .label = "nome", .help = "nome do avião que vai para a Montagem", .default = .{ .text = "avião 1" } },
    .{ .key = "set", .label = "conjunto", .help = "um dos conjuntos guardados na etapa Empenagem", .default = .{ .text = "conjunto 1" } },
    .{ .key = "layout", .label = "motores", .help = "livre: soma os motores do nariz, da asa e de trás (ex.: trimotor = 1 + 2 + 0; puxa-empurra = 1 + 0 + 1)", .default = .{ .text = "tratora no nariz" }, .choices = &layouts },
    .{ .key = "motor", .label = "motor", .default = .{ .text = "Scorpion A-5025-310Kv" } },
    .{ .key = "propeller", .label = "hélice", .default = .{ .text = "APC 15x8E" } },
    .{ .key = "battery", .label = "bateria", .help = "uma por motor", .default = .{ .text = "LiPo 6S 5000" } },
    .{ .key = "tilt", .label = "inclinação do motor", .unit = "°", .help = "+ eixo apontando para cima: parte da tração sustenta na corrida", .default = .{ .number = 0 }, .minimum = -10, .maximum = 15 },
    .{ .key = "motor_y", .label = "afastamento dos motores", .unit = "m", .help = "motores na asa: do centro ao eixo do primeiro par; 0 = o mínimo para a hélice livrar a fuselagem", .default = .{ .number = 0 }, .minimum = 0, .maximum = 1.5 },
    .{ .key = "wing_motors", .label = "motores na asa", .help = "arranjo na asa e livre: aos pares, espalhados na envergadura. No arranjo na asa, no mínimo 2", .default = .{ .number = 2 }, .minimum = 0, .maximum = 8, .integer = true },
    .{ .key = "nose_motors", .label = "motores no nariz", .help = "arranjo livre: tratora no nariz (0 ou 1)", .default = .{ .number = 1 }, .minimum = 0, .maximum = 1, .integer = true },
    .{ .key = "rear_motors", .label = "motores atrás", .help = "arranjo livre: propulsora atrás da asa (0 ou 1)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 1, .integer = true },
    .{ .key = "lapes", .label = "tem LAPES", .help = "carga lançada pela baia, no CG. Só diz se tem: os kg se decidem na Montagem", .default = .{ .toggle = true } },
    .{ .key = "n_lapes", .label = "quantas cargas LAPES", .help = "na mesma baia; a massa se define na Montagem", .default = .{ .number = 1 }, .minimum = 1, .maximum = 6, .integer = true },
    .{ .key = "liquid", .label = "tem carga líquida", .help = "água em tanque(s) no CG — mexe na curva (sloshing). Os litros se decidem na Montagem", .default = .{ .toggle = true } },
    .{ .key = "n_tanks", .label = "quantos tanques", .help = "lado a lado no CG", .default = .{ .number = 1 }, .minimum = 1, .maximum = 4, .integer = true },
    .{ .key = "gear", .label = "trem", .help = "triciclo: bequilha no nariz; convencional: bequilha na cauda", .default = .{ .text = "triciclo" }, .choices = &gears },
    .{ .key = "x_tdp", .label = "x_TDP: trem principal ao CG", .unit = "m", .help = "distância do CG de projeto ao trem principal: atrás dele no triciclo, à frente no convencional. 0 = a regra (triciclo) ou 10 cm (convencional)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 0.6 },
    .{ .key = "x_payload", .label = "x da carga paga ao CG", .unit = "m", .help = "onde fica a carga paga, medida do CG de projeto (+ = à frente). 0 = no CG; fora dele a bateria equilibra junto", .default = .{ .number = 0 }, .minimum = -0.5, .maximum = 0.5 },
    .{ .key = "x_tdn", .label = "x_TDN: bequilha à frente do CG", .unit = "m", .help = "triciclo: distância do CG de projeto à bequilha. 0 = automático (10 cm atrás do nariz)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 1.5 },
    .{ .key = "gear_h", .label = "altura do trem", .unit = "m", .help = "do eixo do corpo ao chão no trem principal. 0 = a mínima para a hélice livrar o chão parada", .default = .{ .number = 0 }, .minimum = 0, .maximum = 1 },
    .{ .key = "ground_pitch", .label = "atitude no chão", .unit = "°", .help = "triciclo: a bequilha mais comprida deixa o avião parado com o nariz para cima, e a asa corre nesse ângulo. 0 = nivelado", .default = .{ .number = 0 }, .minimum = 0, .maximum = 15 },
};

const plots = [_]simulation.Plot{
    .{ .key = "T", .title = "T, D × V", .xlabel = "V (m/s)", .ylabel = "N" },
    .{ .key = "RC", .title = "R/C × V", .xlabel = "V (m/s)", .ylabel = "m/s" },
    .{ .key = "to", .title = "s_TO × m", .xlabel = "m (kg)", .ylabel = "m" },
};

fn draft(project: *store.Project) *ObjectMap {
    return project.section("power_draft");
}

fn field(params: *const ObjectMap, key: []const u8) f64 {
    return registry.fieldNumber(params, &power_fields, key);
}

fn rule(project: *store.Project, key: []const u8) f64 {
    return registry.fieldNumber(project.section("rules"), &registry.rule_fields, key);
}

fn requirement(project: *store.Project, key: []const u8) f64 {
    return registry.fieldNumber(project.section("requirements"), &registry.requirement_fields, key);
}

/// (motores no nariz, pares na asa, motores atrás) do arranjo; o livre sem nenhum motor fica com o do nariz
fn motorCounts(params: *const ObjectMap) [3]usize {
    const layout = store.text(params, "layout", layouts[0]);
    if (std.mem.eql(u8, layout, layouts[0])) return .{ 1, 0, 0 };
    if (std.mem.eql(u8, layout, layouts[1])) return .{ 0, @max(@as(usize, @intFromFloat(@max(field(params, "wing_motors"), 0))) / 2, 1), 0 };
    if (std.mem.eql(u8, layout, layouts[2])) return .{ 0, 0, 1 };
    const counts = [3]usize{ @intFromFloat(std.math.clamp(field(params, "nose_motors"), 0, 1)), @as(usize, @intFromFloat(@max(field(params, "wing_motors"), 0))) / 2, @intFromFloat(std.math.clamp(field(params, "rear_motors"), 0, 1)) };
    return if (counts[0] + counts[1] + counts[2] == 0) .{ 1, 0, 0 } else counts;
}

fn unitOf(params: *const ObjectMap, name: []const u8, x: f64, y: f64, z: f64, sense: f64) model.Propulsion {
    var unit: model.Propulsion = .{ .name = name, .x = x, .y = y, .z = z, .tilt = field(params, "tilt"), .sense = sense };
    if (catalog.find(catalog.Motor, &catalog.motors, store.text(params, "motor", ""))) |motor| unit.motor = .{ .Kv = motor.Kv, .Rm = motor.Rm, .B = motor.B, .tauc = motor.tauc, .Imax = motor.Imax, .Jm = motor.Jm, .mass = motor.mass };
    if (catalog.find(catalog.Propeller, &catalog.propellers, store.text(params, "propeller", ""))) |propeller| unit.propeller = .{ .D = propeller.D, .Ip = propeller.Ip, .mass = propeller.mass, .J = propeller.J, .CT = propeller.CT, .CP = propeller.CP };
    if (catalog.find(catalog.Battery, &catalog.batteries, store.text(params, "battery", ""))) |battery| unit.battery = .{ .cells = battery.cells, .V_cell = battery.V_cell, .Rint = battery.Rint, .capacity_mAh = battery.capacity_mAh, .mass = battery.mass };
    return unit;
}

/// a tração de um motor (N) com acelerador cheio (o equilíbrio motor + hélice do núcleo)
fn unitThrust(unit: model.Propulsion, airspeed: f64, density: f64) f64 {
    var spec: motorprop.MotorProp = .{ .Kv = unit.motor.Kv, .Rm = unit.motor.Rm, .B = unit.motor.B, .tauc = unit.motor.tauc, .Imax = unit.motor.Imax, .Voc = unit.battery.voc(), .Rint = unit.battery.Rint, .D = unit.propeller.D };
    spec.D4 = std.math.pow(f64, spec.D, 4);
    spec.D5 = spec.D4 * spec.D;
    const count = @min(unit.propeller.J.len, motorprop.max_pts);
    spec.n = @intCast(count);
    @memcpy(spec.J[0..count], unit.propeller.J[0..count]);
    @memcpy(spec.CT[0..count], unit.propeller.CT[0..count]);
    @memcpy(spec.CP[0..count], unit.propeller.CP[0..count]);
    return motorprop.thrust(&spec, airspeed, density);
}

/// o momento de arfagem (+ cabra) da tração de cada motor em torno de (px, pz): eixo inclinado e fora do ponto
fn thrustMoment(units: []const model.Propulsion, each: f64, px: f64, pz: f64) f64 {
    var moment: f64 = 0;
    for (units) |unit| {
        const tilt = std.math.degreesToRadians(unit.tilt);
        const along = each * @cos(tilt);
        const down = -each * @sin(tilt);
        moment += (unit.z - pz) * along - (unit.x - px) * down;
    }
    return moment;
}

fn surfaceArea(surface: model.Surface) f64 {
    var half: f64 = 0;
    for (1..surface.sections.len) |k| half += 0.5 * (surface.sections[k - 1].chord + surface.sections[k].chord) * @abs(surface.sections[k].y - surface.sections[k - 1].y);
    return if (surface.symmetric and !surface.vertical) 2 * half else half;
}

/// o avião montado e as contas da montagem e do desempenho
pub const Assembled = struct {
    plane: model.Aircraft,
    built: tail_stage.Built,
    x_target: f64, // CG de projeto (x para a frente)
    h_n: f64,
    margin: f64,
    mass: f64,
    empty: f64,
    payload: f64,
    x_battery: f64,
    x_battery_used: f64,
    battery_fits: bool,
    ballast: f64,
    x_payload: f64,
    payload_moved: bool,
    margin_empty: f64,
    length: f64,
    stall_speed: f64,
    boom_hits_prop: bool,
    mass_rows: []const [4][]const u8,
    // a tração e a corrida
    cruise_thrust: f64 = 0,
    thrust_moment: f64 = 0,
    incidence_change: f64 = 0,
    hold: f64 = 0,
    hold_ok: bool = true,
    rotation_speed: f64 = std.math.inf(f64),
    liftoff_speed: f64 = 0,
    nose_load: f64 = std.math.nan(f64),
    ground_lift: ?f64 = null,
    // desempenho
    speeds: []const f64 = &.{},
    thrust: []const f64 = &.{},
    drag: []const f64 = &.{},
    climb: []const f64 = &.{},
    max_speed: f64 = std.math.nan(f64),
    climb_max: f64 = 0,
    climb_speed: f64 = 0,
    zero_drag: f64 = 0,
    ld_max: f64 = 0,
    ld_speed: f64 = 0,
    static_thrust: f64 = 0,
    thrust_weight: f64 = 0,
    takeoff_run: f64 = std.math.inf(f64),
    runway_mtow: f64 = std.math.nan(f64),
    masses: []const f64 = &.{},
    runs: []const f64 = &.{},
    cruise_trim_drag: f64 = 0, // C_D,trim da EH no cruzeiro
};

/// o conjunto guardado com este nome (senão o último)
pub fn chosenSet(project: *store.Project, params: *const ObjectMap) ?*ObjectMap {
    const sets = project.list("sets").items;
    if (sets.len == 0) return null;
    const wanted = store.text(params, "set", "");
    for (sets) |*item| if (item.* == .object and std.mem.eql(u8, store.nameOf(item.*), wanted)) return store.child(&item.object, "params");
    return if (sets[sets.len - 1] == .object) store.child(&sets[sets.len - 1].object, "params") else null;
}

pub fn assemble(context: *stages.Context, memory: std.mem.Allocator, params: *const ObjectMap) !?*Assembled {
    const project = &context.project;
    const set_params = chosenSet(project, params) orelse return null;
    const built = try tail_stage.build(context, memory, set_params, false) orelse return null;
    const result = built.result;
    const wing = built.wing;
    const area = wing.area;
    const chord = wing.mean_chord;
    const span = wing.span;
    const root_chord = built.shape.planform.root_chord;
    const x_le_mac = -(wing.aero_center - 0.25 * chord); // x para a frente: o bordo de ataque da raiz em 0
    const wing_z = rule(project, "wing_z");
    const density = registry.rho(project);
    const tailless = tail_stage.layoutOf(set_params) == .tailless;
    const tandem = tailless and built.wings.len > 1;

    var plane = try std.json.parseFromSliceLeaky(model.Aircraft, memory, templates.all[0].json, .{ .ignore_unknown_fields = true });
    plane.name = store.text(params, "name", "avião 1");
    for (built.surfaces) |*surface| if (std.mem.eql(u8, surface.role, "wing")) {
        surface.z += wing_z;
    };
    plane.surfaces = built.surfaces;
    plane.booms = built.booms;
    plane.boom = .{};
    plane.Sref = null;
    plane.cref = null;
    plane.bref = null;
    plane.tanks = &.{};
    plane.payload.enabled = false;
    plane.environment.density_altitude = requirement(project, "density_altitude");
    plane.environment.rho = density;
    plane.airfield.x_warning = firstConstraint(project, "s_to", plane.airfield.x_warning);
    plane.airfield.z_warning = requirement(project, "obstacle_h");
    if (store.flag(set_params, "flap_moment", false)) plane.modifiers = try memory.dupe(model.Modifier, &.{ .{ .kind = "solo.mccormick" }, .{ .kind = "comando.momento_flape" } });

    // fuselagem (pod) e motores
    const width = rule(project, "fuselage_width");
    const height = rule(project, "fuselage_height");
    const counts = motorCounts(params);
    const x_nose = if (counts[0] > 0) rule(project, "nose_length") else 0.6 * rule(project, "nose_length");
    var length = x_nose + root_chord + 0.05;
    if (tandem) length = @max(length, (x_nose + result.x_cg) / 0.5);
    var units: std.ArrayList(model.Propulsion) = .empty;
    if (counts[0] > 0) try units.append(memory, unitOf(params, "motor 1", x_nose, 0, 0, 1));
    if (counts[1] > 0) {
        const diameter = unitOf(params, "m", 0, 0, 0, 1).propeller.D;
        var offset = if (field(params, "motor_y") > 0) field(params, "motor_y") else @max(diameter / 2 + width / 2 + 0.05, 0.15);
        if (counts[0] > 0 and field(params, "motor_y") <= 0) offset = @max(offset, diameter + 0.05);
        for (0..counts[1]) |k| {
            const side = offset + @as(f64, @floatFromInt(k)) * (diameter + 0.05);
            const single = counts[1] == 1;
            try units.append(memory, unitOf(params, if (single) "motor esq" else try std.fmt.allocPrint(memory, "motor esq {d}", .{k + 1}), 0.17, -side, wing_z, 1));
            try units.append(memory, unitOf(params, if (single) "motor dir" else try std.fmt.allocPrint(memory, "motor dir {d}", .{k + 1}), 0.17, side, wing_z, -1));
        }
    }
    var second: ?model.Surface = null;
    if (tandem) for (built.surfaces[1..]) |surface| if (std.mem.eql(u8, surface.role, "wing")) {
        second = surface;
        break;
    };
    if (counts[2] > 0) {
        const x_rear, const z_rear = if (second) |rear| .{ rear.x - rear.sections[0].chord - 0.06, rear.z } else .{ -root_chord - 0.06, 0.0 };
        try units.append(memory, unitOf(params, if (units.items.len > 0) "motor atrás" else "motor 1", x_rear, 0, z_rear, if (counts[0] > 0) -1 else 1));
    }
    plane.propulsion = units.items;
    var diameter: f64 = 0;
    for (units.items) |unit| diameter = @max(diameter, unit.propeller.D);
    const volume = std.math.pi / 6.0 * width * height * length;
    const wetted = std.math.pi * 0.5 * (width + height) * length * 0.75;
    plane.fuselage = .{ .enabled = true, .x_nose = x_nose, .length = length, .width = width, .height = height, .z = 0, .CDS = rule(project, "fuselage_cd_wet") * wetted, .Cma = 2 * munk * volume / (area * chord), .Cnb = -2 * munk * volume / (area * span), .CYb = -0.15 };

    // o CG com a fuselagem (a margem continua a pedida)
    const h_n = result.h_n - plane.fuselage.Cma / wing.lift_slope;
    const h_target = h_n - store.number(set_params, "sm_target", 12) / 100;
    const x_target = x_le_mac - h_target * chord;

    // as massas da estrutura (nome, massa, x, z)
    const Part = struct { name: []const u8, mass: f64, x: f64, z: f64 };
    var parts: std.ArrayList(Part) = .empty;
    try parts.append(memory, .{ .name = "asa", .mass = area * rule(project, "wing_density"), .x = x_le_mac - 0.4 * chord, .z = wing_z });
    for (plane.surfaces[1..]) |surface| try parts.append(memory, .{ .name = surface.name, .mass = surfaceArea(surface) * rule(project, "tail_density"), .x = surface.x - 0.4 * surface.sections[0].chord, .z = surface.z });
    const boom: ?model.Boom = if (plane.booms.len > 0) plane.booms[0] else null;
    if (boom) |tube| {
        const middle = tube.middle();
        try parts.append(memory, .{ .name = "tubo de cauda", .mass = tube.length * rule(project, "boom_density"), .x = middle[0], .z = middle[2] });
    }
    try parts.append(memory, .{ .name = "fuselagem", .mass = length * rule(project, "fuselage_density"), .x = x_nose - 0.45 * length, .z = 0 });
    try parts.append(memory, .{ .name = "trem de pouso", .mass = rule(project, "gear_mass"), .x = x_target, .z = 0.1 });
    var structure: f64 = 0;
    var moment_x: f64 = 0;
    var moment_z: f64 = 0;
    for (parts.items) |part| {
        structure += part.mass;
        moment_x += part.mass * part.x;
        moment_z += part.mass * part.z;
    }
    const x_structure = moment_x / structure;
    const z_structure = moment_z / structure;
    var inertia = [3]f64{ 0, 0, 0 };
    for (parts.items) |part| {
        const dx = part.x - x_structure;
        const dz = part.z - z_structure;
        inertia[1] += part.mass * (dx * dx + dz * dz);
        inertia[0] += part.mass * dz * dz;
        inertia[2] += part.mass * dx * dx;
        if (std.mem.eql(u8, part.name, "asa")) {
            inertia[0] += part.mass * span * span / 12;
            inertia[2] += part.mass * (span * span + chord * chord) / 12;
            inertia[1] += part.mass * chord * chord / 12;
        } else if (std.mem.eql(u8, part.name, "tubo de cauda") or std.mem.eql(u8, part.name, "fuselagem")) {
            const long = if (std.mem.eql(u8, part.name, "fuselagem")) length else boom.?.length;
            inertia[1] += part.mass * long * long / 12;
            inertia[2] += part.mass * long * long / 12;
        }
    }
    var items: std.ArrayList(model.PointMass) = .empty;
    for (units.items) |unit| {
        const side: f64 = if (unit.x < 0) 1 else -1;
        try items.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}: motor", .{unit.name}), .mass = unit.motor.mass, .x = unit.x + side * 0.06, .y = unit.y, .z = unit.z });
        try items.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}: hélice", .{unit.name}), .mass = unit.propeller.mass, .x = unit.x, .y = unit.y, .z = unit.z });
    }
    try items.append(memory, .{ .name = "sistemas", .mass = rule(project, "systems_mass"), .x = 0.5 * x_nose });
    var battery_mass: f64 = 0;
    for (units.items) |unit| battery_mass += unit.battery.mass;
    var empty = structure + battery_mass;
    for (items.items) |item| empty += item.mass;
    const payload = @max(requirement(project, "mass") - empty, 0);
    var mass = empty + payload;
    const low = x_nose - length + 0.08;
    const high = x_nose - 0.12;
    const x_payload = if (field(params, "x_payload") != 0) std.math.clamp(x_target + field(params, "x_payload"), low, high) else x_target;
    var moment = structure * x_structure + payload * x_payload;
    for (items.items) |item| moment += item.mass * item.x;
    const x_battery = if (battery_mass > 0) (mass * x_target - moment) / battery_mass else x_target;
    const x_battery_used = std.math.clamp(x_battery, low, high);
    try items.append(memory, .{ .name = "bateria", .mass = battery_mass, .x = x_battery_used, .z = 0.02 });
    moment += battery_mass * x_battery_used;
    const balanced = @abs(x_battery_used - x_battery) < 1e-6;
    var ballast: f64 = 0;
    if (!balanced) {
        const x_ballast = if (x_battery > x_battery_used) x_nose - 0.04 else if (boom) |tube| tube.xEnd() + 0.05 else low;
        const needed = (mass * x_target - moment) / (x_ballast - x_target);
        if (needed > 0) {
            try items.append(memory, .{ .name = "lastro de equilíbrio", .mass = needed, .x = x_ballast });
            ballast = needed;
            mass += needed;
            moment += needed * x_ballast;
        }
    }
    plane.ballast = .{ .enabled = false, .mass = 0, .x = x_target };
    if (store.flag(params, "liquid", true)) {
        const count: usize = @intFromFloat(@max(field(params, "n_tanks"), 1));
        const tanks = try memory.alloc(model.Tank, count);
        for (tanks, 0..) |*tank, k| {
            const y = (@as(f64, @floatFromInt(k)) - @as(f64, @floatFromInt(count - 1)) / 2) * 0.13;
            tank.* = .{ .name = if (count > 1) try std.fmt.allocPrint(memory, "tanque {d}", .{k + 1}) else "tanque", .x = x_payload, .y = y, .z = 0.03, .side = 0.12, .volume = 0, .height = 0.08 };
        }
        plane.tanks = tanks;
    }
    if (store.flag(params, "lapes", true)) plane.payload = .{ .enabled = true, .mass = 0, .x = x_payload, .z = 0.06 };
    plane.mass = .{ .base_mass = structure, .base_cg = .{ x_structure, 0, z_structure }, .Ixx = @max(inertia[0], 1e-4), .Iyy = @max(inertia[1], 1e-4), .Izz = @max(inertia[2], 1e-4), .Ixz = 0, .items = items.items, .include_propulsion = false, .include_structure = false };
    var item_mass: f64 = 0;
    var item_z: f64 = 0;
    for (items.items) |item| {
        item_mass += item.mass;
        item_z += item.mass * item.z;
    }
    const z_cg = (structure * z_structure + item_z) / @max(structure + item_mass, 1e-9);
    plane.design_cg = .{ x_target, 0, z_cg };

    // o trem
    const clearance = rule(project, "prop_clearance");
    var gear_z = if (counts[1] == 0) diameter / 2 + clearance else @max(diameter / 2 + clearance + wing_z, 0.12);
    if (counts[1] > 0 and (counts[0] > 0 or counts[2] > 0)) gear_z = @max(gear_z, diameter / 2 + clearance);
    const lift_gear = @max(field(params, "gear_h") - gear_z, 0);
    gear_z += lift_gear;
    const x_main_offset = if (field(params, "x_tdp") > 0) field(params, "x_tdp") else rule(project, "main_gear_aft");
    const roll = requirement(project, "mu_roll");
    const boom_end: ?[3]f64 = if (boom) |tube| tube.end() else null;
    if (std.mem.eql(u8, store.text(params, "gear", gears[0]), gears[0])) {
        const x_nose_wheel = if (field(params, "x_tdn") > 0) x_target + field(params, "x_tdn") else x_nose - 0.10;
        const pitch = field(params, "ground_pitch");
        const z_nose_wheel = if (pitch <= 0) gear_z else gear_z + (x_nose_wheel - (x_target - x_main_offset)) * @tan(std.math.degreesToRadians(pitch));
        plane.gear = .{ .layout = "tricycle", .main_x = x_target - x_main_offset, .main_track = rule(project, "track"), .main_z = gear_z, .steer_x = x_nose_wheel, .steer_z = z_nose_wheel, .tail_skid = boom != null, .skid_x = if (boom_end) |end| end[0] else -1, .skid_z = if (boom_end) |end| end[2] else 0, .mu_roll = roll };
    } else {
        plane.gear = .{ .layout = "conventional", .main_x = x_target + (if (field(params, "x_tdp") > 0) field(params, "x_tdp") else 0.10), .main_track = rule(project, "track"), .main_z = gear_z, .steer_x = if (boom_end) |end| end[0] else x_target - 0.6, .steer_z = (if (boom_end) |end| end[2] else 0) + 0.05 + lift_gear, .steer_k = 1500, .steer_c = 40, .tail_skid = false, .mu_roll = roll };
    }
    const weight = mass * gravity;
    const stall_speed = @sqrt(2 * weight / (density * area * wing.lift_max));
    plane.takeoff.VR = @round(1.15 * stall_speed * 100) / 100;
    plane.takeoff.sR = 0;
    plane.autopilot.CL0 = wing.lift_zero + wing.lift_slope * std.math.degreesToRadians(wing.incidence);
    plane.autopilot.CLa = wing.lift_slope;

    // o comprimento total
    var front: f64 = x_nose;
    var back: f64 = x_nose;
    for (units.items) |unit| {
        front = @max(front, unit.x);
        back = @min(back, unit.x);
    }
    for (plane.surfaces) |surface| {
        front = @max(front, surface.x - surface.sections[0].chord);
        back = @min(back, surface.x - surface.sections[0].chord);
    }
    if (boom_end) |end| back = @min(back, end[0]);

    // a tabela de massas
    var rows: std.ArrayList([4][]const u8) = .empty;
    for (parts.items) |part| try rows.append(memory, .{ "PV", part.name, try std.fmt.allocPrint(memory, "{d:.3}", .{part.mass}), try std.fmt.allocPrint(memory, "{d:.3}", .{part.x}) });
    for (items.items) |item| try rows.append(memory, .{ "PV", item.name, try std.fmt.allocPrint(memory, "{d:.3}", .{item.mass}), try std.fmt.allocPrint(memory, "{d:.3}", .{item.x}) });
    if (payload > 0) try rows.append(memory, .{ "CP", "estimada = massa de projeto − PV (os kg na Montagem)", try std.fmt.allocPrint(memory, "{d:.3}", .{payload}), try std.fmt.allocPrint(memory, "{d:.3}", .{x_payload}) });
    const x_empty = (moment - payload * x_payload) / @max(mass - payload, 1e-9);

    const out = try memory.create(Assembled);
    out.* = .{
        .plane = plane,
        .built = built,
        .x_target = x_target,
        .h_n = h_n,
        .margin = 100 * (h_n - h_target),
        .mass = mass,
        .empty = mass - payload,
        .payload = payload,
        .x_battery = x_battery,
        .x_battery_used = x_battery_used,
        .battery_fits = balanced,
        .ballast = ballast,
        .x_payload = x_payload,
        .payload_moved = @abs(x_payload - x_target) > 1e-6,
        .margin_empty = 100 * (h_n - (x_le_mac - x_empty) / chord),
        .length = front - back,
        .stall_speed = stall_speed,
        .boom_hits_prop = counts[2] > 0 and boom != null and second == null,
        .mass_rows = rows.items,
    };
    try thrustTrim(context, memory, out, set_params, z_cg);
    try performance(context, memory, out);
    return out;
}

pub fn firstConstraint(project: *store.Project, key: []const u8, fallback: f64) f64 {
    for ((registry.constraintList(project) catch return fallback).items) |item| {
        const constraint = registry.readConstraint(item);
        if (constraint.active and std.mem.eql(u8, constraint.key, key)) return constraint.value;
    }
    return fallback;
}

/// o C_D0 do avião: as superfícies (C_d0 do perfil × área × η) mais a fuselagem e o tubo, na área da asa
fn zeroDrag(plane: model.Aircraft, area: f64) f64 {
    var total: f64 = 0;
    for (plane.surfaces) |surface| {
        const numbers = aircraft_model.params.props2d(surface.airfoil) catch [5]f64{ 0, 0, 0, surface.airfoil.cd0, 0 };
        total += numbers[3] * surfaceArea(surface) * surface.eta;
    }
    if (plane.fuselage.enabled) total += plane.fuselage.CDS;
    for (plane.booms) |tube| if (tube.enabled) {
        total += 0.006 * std.math.pi * tube.diameter * tube.length;
    };
    return total / area;
}

fn inducedFactor(assembled: *const Assembled) f64 {
    const wing = assembled.built.wing;
    return 1 / (std.math.pi * wing.aspect_ratio * std.math.clamp(wing.oswald, 0.5, 1.0));
}

/// a EH retrimada com o momento da tração (motor inclinado ou fora do CG) e o trim de decolagem (`thrust_trim`)
fn thrustTrim(context: *stages.Context, memory: std.mem.Allocator, assembled: *Assembled, set_params: *const ObjectMap, z_cg: f64) !void {
    const project = &context.project;
    const plane = &assembled.plane;
    const units = plane.propulsion;
    if (units.len == 0) return;
    const wing = assembled.built.wing;
    const result = assembled.built.result;
    const area = wing.area;
    const chord = wing.mean_chord;
    const density = registry.rho(project);
    const weight = assembled.mass * gravity;
    const count: f64 = @floatFromInt(units.len);
    const dynamic = 0.5 * density * std.math.pow(f64, requirement(project, "V_cruise"), 2);
    const factor = inducedFactor(assembled);
    const lift = weight / (dynamic * area);
    const cruise_thrust = dynamic * area * (zeroDrag(plane.*, area) + factor * lift * lift);
    const moment = thrustMoment(units, cruise_thrust / count, assembled.x_target, z_cg) / (dynamic * area * chord);
    var change: f64 = 0;
    if (result.statics) |statics| {
        change = moment / (statics.eta * result.volume_h * result.tail_slope);
        const surfaces = @constCast(plane.surfaces);
        for (surfaces) |*surface| if (std.mem.eql(u8, surface.role, "htail")) {
            surface.incidence += std.math.radiansToDegrees(change) * @cos(std.math.degreesToRadians(surface.dihedral));
        };
    }
    assembled.cruise_thrust = cruise_thrust;
    assembled.thrust_moment = moment;
    assembled.incidence_change = std.math.radiansToDegrees(change);
    if (!std.mem.eql(u8, plane.gear.layout, "tricycle")) return;
    _ = set_params;

    // a corrida: momentos no trem principal (+ cabra), com a tração do motor inclinado
    const gear_x = plane.gear.main_x;
    const gear_z = plane.gear.main_z;
    var ground_lift = result.ground_lift;
    const pitch = if (plane.gear.steer_x != gear_x) std.math.atan((plane.gear.steer_z - gear_z) / (plane.gear.steer_x - gear_x)) else 0;
    var weight_arm = assembled.x_target - gear_x;
    if (pitch > 0) {
        ground_lift += wing.lift_slope * pitch;
        weight_arm = weight_arm * @cos(pitch) - (gear_z - z_cg) * @sin(pitch);
    }
    const base = (plane.gear.steer_x - gear_x) * @cos(pitch);
    assembled.nose_load = if (base > 1e-6) weight_arm / base else 0;
    const liftoff = 1.1 * @sqrt(2 * weight / (density * area * wing.lift_max));
    const gear_aft = -gear_x; // m atrás do bordo de ataque da raiz
    const aero = struct {
        fn of(wing_result: anytype, tail_result: anytype, lift_ground: f64, deflection: f64, gear_at: f64, extra: f64) f64 {
            return wing_result.moment + lift_ground * (gear_at - wing_result.aero_center) / wing_result.mean_chord + tail_result.groundMoment(lift_ground, deflection, gear_at, extra);
        }
    }.of;
    const de_max = std.math.degreesToRadians(rule(project, "de_max"));
    const de_down = std.math.degreesToRadians(rule(project, "de_down"));
    const steps = 64;
    var early_speeds: [steps]f64 = undefined;
    var early_thrust: [steps]f64 = undefined;
    for (0..steps) |i| {
        early_speeds[i] = 0.5 + (1.6 * liftoff - 0.5) * @as(f64, @floatFromInt(i)) / (steps - 1);
        early_thrust[i] = unitThrust(units[0], early_speeds[i], density);
    }
    const Lifts = struct {
        fn any(speeds: []const f64, thrusts: []const f64, limit: f64, rho: f64, s: f64, c: f64, cm: f64, list: []const model.Propulsion, gx: f64, gz: f64, w: f64, arm: f64) bool {
            for (speeds, thrusts) |speed, thrust| {
                if (speed > limit) continue;
                if (0.5 * rho * speed * speed * s * c * cm + thrustMoment(list, thrust, gx, gz) - w * arm > 0) return true;
            }
            return false;
        }
    };
    const neutral = aero(wing, result, ground_lift, 0, gear_aft, change);
    if (Lifts.any(&early_speeds, &early_thrust, 0.95 * liftoff, density, area, chord, neutral, units, gear_x, gear_z, weight, weight_arm)) {
        var low: f64 = 0;
        var high = de_down;
        if (Lifts.any(&early_speeds, &early_thrust, 0.95 * liftoff, density, area, chord, aero(wing, result, ground_lift, high, gear_aft, change), units, gear_x, gear_z, weight, weight_arm)) {
            assembled.hold = rule(project, "de_down");
            assembled.hold_ok = false;
        } else {
            for (0..30) |_| {
                const middle = 0.5 * (low + high);
                if (Lifts.any(&early_speeds, &early_thrust, 0.95 * liftoff, density, area, chord, aero(wing, result, ground_lift, middle, gear_aft, change), units, gear_x, gear_z, weight, weight_arm)) low = middle else high = middle;
            }
            assembled.hold = std.math.radiansToDegrees(high);
        }
        plane.takeoff.de0 = @round(assembled.hold * 100) / 100;
    }
    const full = aero(wing, result, ground_lift, -de_max, gear_aft, change);
    for (early_speeds, early_thrust) |speed, thrust| {
        if (0.5 * density * speed * speed * area * chord * full + thrustMoment(units, thrust, gear_x, gear_z) - weight * weight_arm > 0) {
            assembled.rotation_speed = speed;
            break;
        }
    }
    if (pitch > 0) {
        assembled.ground_lift = ground_lift;
        assembled.rotation_speed = @min(assembled.rotation_speed, if (ground_lift > 0) @sqrt(2 * weight / (density * area * ground_lift)) else std.math.inf(f64));
    }
    assembled.liftoff_speed = liftoff;
    _ = memory;
}

/// o desempenho rápido: tração × arrasto, subida, corrida e o MTOW pela pista (`performance`)
fn performance(context: *stages.Context, memory: std.mem.Allocator, assembled: *Assembled) !void {
    const project = &context.project;
    const plane = assembled.plane;
    const units = plane.propulsion;
    const wing = assembled.built.wing;
    const result = assembled.built.result;
    const area = wing.area;
    const chord = wing.mean_chord;
    const density = registry.rho(project);
    const weight = assembled.mass * gravity;
    const zero = zeroDrag(plane, area);
    const factor = inducedFactor(assembled);
    const cruise = requirement(project, "V_cruise");
    const stall = assembled.stall_speed;
    const count = 120;
    const speeds = try memory.alloc(f64, count);
    const thrust = try memory.alloc(f64, count);
    const drag = try memory.alloc(f64, count);
    const climb = try memory.alloc(f64, count);
    const first = @max(0.8 * stall, 2.0);
    const last = @max(3.0 * stall, cruise * 1.8);
    var tilt: f64 = 0;
    for (units) |unit| tilt += unit.tilt;
    tilt = if (units.len > 0) std.math.degreesToRadians(tilt / @as(f64, @floatFromInt(units.len))) else 0;
    // o arrasto de trimagem da EH (C_L,h que equilibra, com o momento da tração crescendo com o arrasto)
    const cruise_lift = wing.lift_cruise;
    const cruise_drag = zero + factor * cruise_lift * cruise_lift;
    var best: usize = 0;
    var nearest: usize = 0;
    var trims: [count]f64 = undefined;
    for (0..count) |i| {
        const speed = first + (last - first) * @as(f64, @floatFromInt(i)) / (count - 1);
        speeds[i] = speed;
        var total: f64 = 0;
        for (units) |unit| total += unitThrust(unit, speed, density);
        thrust[i] = total;
        const dynamic = 0.5 * density * speed * speed;
        const lift = weight / (dynamic * area);
        const untrimmed = zero + factor * lift * lift;
        var trim: f64 = 0;
        if (result.statics) |statics| {
            const thrust_moment = assembled.thrust_moment * untrimmed / @max(cruise_drag, 1e-6);
            const tail_lift = (wing.moment + lift * (result.h_cg - result.h_ac) + thrust_moment) / (statics.eta * result.volume_h);
            const tail_aspect = @max(result.span_h * result.span_h / @max(result.area_h + (if (result.gamma > 0) result.area_v else 0), 1e-9), 1.0);
            trim = result.tail_area_share * tail_lift * tail_lift / (std.math.pi * 0.8 * tail_aspect);
        }
        drag[i] = dynamic * area * (untrimmed + trim);
        if (@abs(speed - cruise) < @abs(speeds[nearest] - cruise)) nearest = i;
        trims[i] = trim;
        climb[i] = (total * @cos(tilt) - drag[i]) * speed / weight;
        if (total * @cos(tilt) >= drag[i]) assembled.max_speed = speed;
        if (climb[i] > climb[best]) best = i;
    }
    assembled.cruise_trim_drag = trims[nearest];
    assembled.speeds = speeds;
    assembled.thrust = thrust;
    assembled.drag = drag;
    assembled.climb = climb;
    assembled.climb_max = climb[best];
    assembled.climb_speed = speeds[best];
    assembled.zero_drag = zero;
    assembled.ld_max = 0.5 / @sqrt(factor * zero);
    assembled.ld_speed = @sqrt(2 * weight / (density * area) * @sqrt(factor / zero));
    var static_thrust: f64 = 0;
    for (units) |unit| static_thrust += unitThrust(unit, 0, density);
    assembled.static_thrust = static_thrust;
    assembled.thrust_weight = static_thrust / weight;

    // a corrida no chão é do núcleo
    var run: ground.GroundRun = .{ .rho = density, .S = area, .CLg = assembled.ground_lift orelse result.ground_lift, .CD0 = zero, .K = factor, .CLmax = wing.lift_max, .mu = requirement(project, "mu_roll"), .sin_tl = @sin(tilt), .cos_tl = @cos(tilt), .lift_off = @intFromBool(assembled.ground_lift != null) };
    const grid = @min(count + 1, ground.max_grid);
    run.V[0] = 0;
    run.T[0] = static_thrust;
    for (1..grid) |i| {
        run.V[i] = speeds[i - 1];
        run.T[i] = thrust[i - 1];
    }
    run.n = @intCast(grid);
    if (std.mem.eql(u8, plane.gear.layout, "tricycle") and units.len > 0) {
        // a rotação: o momento do profundor todo cabrando mais o da tração, sem o do peso
        const rotation_points = 160;
        const gear_x = plane.gear.main_x;
        const gear_z = plane.gear.main_z;
        const full = wing.moment + run.CLg * (-gear_x - wing.aero_center) / chord + result.groundMoment(run.CLg, -std.math.degreesToRadians(rule(project, "de_max")), -gear_x, std.math.degreesToRadians(assembled.incidence_change));
        for (0..rotation_points) |i| {
            const speed = 0.5 + (40.0 - 0.5) * @as(f64, @floatFromInt(i)) / (rotation_points - 1);
            run.rot_V[i] = speed;
            run.rot_a[i] = 0.5 * density * speed * speed * area * chord * full + thrustMoment(units, unitThrust(units[0], speed, density), gear_x, gear_z);
        }
        var pitch: f64 = 0;
        if (plane.gear.steer_x != gear_x) pitch = std.math.atan((plane.gear.steer_z - gear_z) / (plane.gear.steer_x - gear_x));
        var weight_arm = assembled.x_target - gear_x;
        if (pitch > 0) weight_arm = weight_arm * @cos(pitch) - (gear_z - plane.design_cg.?[2]) * @sin(pitch);
        run.rot_arm = weight_arm;
        run.n_rot = rotation_points;
        run.rot_on = 1;
    }
    assembled.takeoff_run = ground.run(&run, assembled.mass);
    const runway = firstConstraint(project, "s_to", 50);
    const low = @max(assembled.empty, 0.1);
    assembled.runway_mtow = ground.mtow(&run, low, @max(4 * assembled.mass, 1.0), runway);
    const sweep = 25;
    const masses = try memory.alloc(f64, sweep);
    const runs = try memory.alloc(f64, sweep);
    const heaviest = @max(2.2 * assembled.mass, if (std.math.isFinite(assembled.runway_mtow)) assembled.runway_mtow else 0) * 1.05;
    const lightest = @max(assembled.empty, 0.5);
    for (masses, runs, 0..) |*item, *distance, i| {
        item.* = lightest + (heaviest - lightest) * @as(f64, @floatFromInt(i)) / (sweep - 1);
        const value = ground.run(&run, item.*);
        distance.* = if (std.math.isFinite(value)) value else std.math.nan(f64);
    }
    assembled.masses = masses;
    assembled.runs = runs;
}

// ------------------------------------------------------------------ pedidos
/// muda o projeto conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const project = &context.project;
    const params = draft(project);
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        if (try stages.applyFields(project, params, &power_fields, "", values) > 0) _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "load")) {
        const list = project.list("aircraft");
        const index = stages.within(request.index, list.items.len) orelse return "";
        const kept = store.child(&list.items[index].object, "params") orelse return "";
        try project.root.object.put(project.memory(), "power_draft", try stages.clone(project.memory(), .{ .object = kept.* }));
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        const list = project.list("aircraft");
        const index = stages.within(request.index, list.items.len) orelse return "";
        _ = list.orderedRemove(index);
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "keep")) {
        const owned = project.memory();
        const set_params = chosenSet(project, params) orelse return "Guarde um conjunto primeiro.";
        try store.setText(project, params, "set", store.text(set_params, "name", ""));
        var candidate: ObjectMap = .empty;
        try candidate.put(owned, "params", try stages.clone(owned, .{ .object = params.* }));
        for (project.list("sets").items) |item| if (std.mem.eql(u8, store.nameOf(item), store.text(set_params, "name", ""))) try candidate.put(owned, "set", try stages.clone(owned, item));
        try candidate.put(owned, "note", .{ .string = "" });
        const name = try owned.dupe(u8, store.text(params, "name", "avião 1"));
        const list = project.list("aircraft");
        try stages.put(list, .{ .object = candidate });
        var taken: std.ArrayList([]const u8) = .empty;
        for (list.items) |item| try taken.append(memory, store.nameOf(item));
        try store.setText(project, params, "name", try stages.nextName(owned, name, taken.items));
        _ = context.save();
        return std.fmt.allocPrint(memory, "guardado: {s}", .{name});
    }
    if (std.mem.eql(u8, request.do, "act")) {
        if (!std.mem.eql(u8, request.key, "send") and !std.mem.eql(u8, request.key, "perf")) return error.UnknownAction;
        return send(context, memory, std.mem.eql(u8, request.key, "perf"));
    }
    return "";
}

var sent_path: [1024]u8 = undefined;
var sent_len: usize = 0;
var sent_go: []const u8 = "";

/// grava o avião do rascunho em "meus aviões" (a pasta acima da sprint) e pede à tela para abri-lo
fn send(context: *stages.Context, memory: std.mem.Allocator, performance_next: bool) ![]const u8 {
    const assembled = try assemble(context, memory, draft(&context.project)) orelse return "Guarde um conjunto primeiro.";
    const root = std.fs.path.dirname(context.project.folder) orelse ".";
    var slug: std.ArrayList(u8) = .empty;
    for (assembled.plane.name) |char| try slug.append(memory, if (std.ascii.isAlphanumeric(char) or char == '-' or char == '.') char else '_');
    var path = try std.fmt.allocPrint(memory, "{s}/{s}.json", .{ root, slug.items });
    var k: usize = 2;
    while (std.Io.Dir.cwd().access(context.io, path, .{})) |_| : (k += 1) {
        path = try std.fmt.allocPrint(memory, "{s}/{s}_{d}.json", .{ root, slug.items, k });
    } else |_| {}
    var out: std.Io.Writer.Allocating = .init(memory);
    try std.json.Stringify.value(assembled.plane, .{ .emit_null_optional_fields = false }, &out.writer);
    std.Io.Dir.cwd().createDirPath(context.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = out.written() });
    const length = @min(path.len, sent_path.len);
    @memcpy(sent_path[0..length], path[0..length]);
    sent_len = length;
    sent_go = if (performance_next) "performance" else "";
    return std.fmt.allocPrint(memory, "{s}: gravado em {s} (a decolagem ainda não foi ajustada: ajuste em Desempenho → Missão)", .{ assembled.plane.name, path });
}

// ------------------------------------------------------------------ a página
fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn status(ok: bool, soft: bool) @FieldType(simulation.Check, "status") {
    return if (ok) .ok else if (soft) .atencao else .falha;
}

fn numberText(memory: std.mem.Allocator, value: f64) ![]const u8 {
    var buffer: [32]u8 = undefined;
    return memory.dupe(u8, registry.format(&buffer, value));
}

/// a página: o formulário, os aviões guardados, a conta, a tabela de massas e a vista 3D
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const project = &context.project;
    const params = draft(project);
    var set_names: std.ArrayList([]const u8) = .empty;
    for (project.list("sets").items) |item| try set_names.append(memory, store.nameOf(item));
    var motors: std.ArrayList([]const u8) = .empty;
    for (catalog.motors) |item| try motors.append(memory, item.name);
    var propellers: std.ArrayList([]const u8) = .empty;
    for (catalog.propellers) |item| try propellers.append(memory, item.name);
    var batteries: std.ArrayList([]const u8) = .empty;
    for (catalog.batteries) |item| try batteries.append(memory, item.name);
    var form: std.ArrayList(simulation.Param) = .empty;
    for (power_fields) |item| {
        var param = try stages.fieldParam(params, item, "", "", memory);
        const choices: ?[]const []const u8 = if (std.mem.eql(u8, item.key, "set")) set_names.items else if (std.mem.eql(u8, item.key, "motor")) motors.items else if (std.mem.eql(u8, item.key, "propeller")) propellers.items else if (std.mem.eql(u8, item.key, "battery")) batteries.items else null;
        if (choices) |list| {
            param.kind = .choice;
            param.choices = list;
        }
        try form.append(memory, param);
    }
    var kept: std.ArrayList([]const u8) = .empty;
    for (project.list("aircraft").items) |item| try kept.append(memory, store.nameOf(item));
    const actions = try memory.dupe(simulation.StageAction, &.{ .{ .key = "send", .label = "Mandar para a Montagem →", .help = "grava o avião do rascunho em 'meus aviões' e abre na Montagem" }, .{ .key = "perf", .label = "Usar em Desempenho →", .help = "grava o avião do rascunho e vai para as análises de Desempenho" } });
    var out: simulation.StagePage = .{
        .title = "Motores e montagem",
        .help = "Onde ficam os motores, e com isso a bateria (posta onde o CG cai na margem), a carga paga (no CG), a fuselagem e o trem. Mostra o desempenho rápido do avião montado e a massa máxima que a pista permite. 'Mandar para a Montagem' grava o avião e abre; 'Usar em Desempenho' faz o mesmo e vai para as análises de Desempenho.",
        .keep_label = "Guardar avião",
        .params = form.items,
        .kept = kept.items,
        .actions = actions,
    };
    if (sent_len > 0) {
        out.open = try memory.dupe(u8, sent_path[0..sent_len]);
        out.go = sent_go;
        sent_len = 0;
    }
    const assembled = try assemble(context, memory, params) orelse {
        out.message = "Guarde um conjunto primeiro (Estabilidade → Empenagem e comandos → Guardar conjunto).";
        return out;
    };
    const runway = firstConstraint(project, "s_to", std.math.nan(f64));
    const requested_mass = requirement(project, "mass");
    const cruise = requirement(project, "V_cruise");

    // os gráficos
    const figures = try simulation.Figures.init(memory, &plots);
    try figures.curve("T", .{ .name = "tração T", .x = assembled.speeds, .y = assembled.thrust, .color = "#1f77b4", .width = 2.4 });
    try figures.curve("T", .{ .name = "arrasto D", .x = assembled.speeds, .y = assembled.drag, .color = "#d62728", .width = 2.4 });
    try figures.guide("T", .{ .name = "estol", .value = assembled.stall_speed, .vertical = true, .color = "#7f7f7f" });
    try figures.guide("T", .{ .name = "cruzeiro", .value = cruise, .vertical = true, .color = "#2ca02c" });
    try figures.curve("RC", .{ .name = "razão de subida", .x = assembled.speeds, .y = assembled.climb, .color = "#1f77b4", .width = 2.4 });
    try figures.guide("RC", .{ .name = "0", .value = 0, .vertical = false, .color = "#7f7f7f", .dashed = true, .legend = false });
    try figures.curve("to", .{ .name = "corrida", .x = assembled.masses, .y = assembled.runs, .color = "#1f77b4", .width = 2.4 });
    if (std.math.isFinite(runway)) try figures.guide("to", .{ .name = "pista", .value = runway, .vertical = false, .color = "#d62728" });
    try figures.guide("to", .{ .name = "massa do avião", .value = assembled.mass, .vertical = true, .color = "#000000" });
    if (std.math.isFinite(assembled.runway_mtow)) try figures.guide("to", .{ .name = "MTOW pela pista", .value = assembled.runway_mtow, .vertical = true, .color = "#2ca02c" });

    // o resumo
    var summary: std.ArrayList([2][]const u8) = .empty;
    try summary.append(memory, .{ "PV (vazio), CP (carga paga), total (kg)", try text(memory, "{d:.3}, {d:.3}, {d:.3}", .{ assembled.empty, assembled.payload, assembled.mass }) });
    try summary.append(memory, .{ "fração de carga paga CP/total", try text(memory, "{d:.3}", .{assembled.payload / assembled.mass}) });
    if (assembled.ballast > 0) try summary.append(memory, .{ "lastro de equilíbrio (kg, entra no PV)", try text(memory, "{d:.3}", .{assembled.ballast}) });
    try summary.append(memory, .{ "CG (x m), margem estática com a fuselagem (% CMA)", try text(memory, "{d:.3}, {d:.1}", .{ assembled.x_target, assembled.margin }) });
    try summary.append(memory, .{ "comprimento total (m)", try text(memory, "{d:.3}", .{assembled.length}) });
    try summary.append(memory, .{ "V de estol, V máx. (m/s)", try text(memory, "{d:.2}, {d:.2}", .{ assembled.stall_speed, assembled.max_speed }) });
    try summary.append(memory, .{ "subida máx. (m/s) em V", try text(memory, "{d:.2} em {d:.1}", .{ assembled.climb_max, assembled.climb_speed }) });
    try summary.append(memory, .{ "C_D0, (L/D) máx., V de L/D máx.", try text(memory, "{d:.4}, {d:.2}, {d:.2}", .{ assembled.zero_drag, assembled.ld_max, assembled.ld_speed }) });
    try summary.append(memory, .{ "tração estática (N), T/W", try text(memory, "{d:.2}, {d:.3}", .{ assembled.static_thrust, assembled.thrust_weight }) });
    try summary.append(memory, .{ "corrida de decolagem (m)", try text(memory, "{d:.2}", .{assembled.takeoff_run}) });
    try summary.append(memory, .{ "MTOW pela pista (kg); CP possível = MTOW − PV (kg)", try text(memory, "{d:.3}; {d:.3}", .{ assembled.runway_mtow, assembled.runway_mtow - assembled.empty }) });
    try summary.append(memory, .{ "tração no cruzeiro (N), C_m dela, Δi_h (°), profundor na corrida (°)", try text(memory, "{d:.2}, {d:.4}, {d:.2}, {d:.2}", .{ assembled.cruise_thrust, assembled.thrust_moment, assembled.incidence_change, assembled.hold }) });

    // o diagnóstico (`aircraft_stage` de results.py)
    var checks: std.ArrayList(simulation.Check) = .empty;
    const group = "montagem";
    if (assembled.battery_fits and assembled.payload_moved) {
        try checks.append(memory, .{ .status = .ok, .item = "CG no alvo pela bateria e pela carga paga", .value = try text(memory, "bateria em x = {d:.2} m, carga em x = {d:.2} m", .{ assembled.x_battery_used, assembled.x_payload }), .criterion = "dentro da fuselagem", .why = try text(memory, "a carga fora do CG; sem ela, margem estática de {d:.1} %", .{assembled.margin_empty}), .group = group });
    } else if (assembled.battery_fits) {
        try checks.append(memory, .{ .status = .ok, .item = "CG no alvo pela bateria", .value = try text(memory, "bateria em x = {d:.2} m", .{assembled.x_battery_used}), .criterion = "dentro da fuselagem", .group = group });
    } else try checks.append(memory, .{ .status = .atencao, .item = "CG no alvo pela bateria", .value = try text(memory, "precisa de {d:.2} kg de lastro de equilíbrio", .{assembled.ballast}), .criterion = "sem lastro", .why = try text(memory, "a bateria não alcança o ponto que põe o CG no alvo (ficaria em x = {d:.2} m)", .{assembled.x_battery}), .fix = "nariz mais longo/curto, motores noutro lugar ou outra margem", .group = group });
    if (@abs(assembled.incidence_change) > 0.05) try checks.append(memory, .{ .status = .info, .item = "EH trimada com a tração", .value = try text(memory, "Δi_h = {d:.2}° (C_m da tração {d:.3})", .{ assembled.incidence_change, assembled.thrust_moment }), .criterion = "—", .why = "o eixo do motor dá momento no cruzeiro; a incidência da EH já o compensa: voa com o profundor neutro", .group = group });
    if (assembled.hold > 0) try checks.append(memory, .{ .status = status(assembled.hold_ok, false), .item = "trim de decolagem (motor inclinado)", .value = try text(memory, "profundor {d:.1}° picando na corrida", .{assembled.hold}), .criterion = try text(memory, "≤ curso de picar {d}°", .{rule(project, "de_down")}), .why = "com o profundor neutro o nariz sobe e o avião sai do chão antes da velocidade de voo", .fix = if (assembled.hold_ok) "" else "menos inclinação, EH com menos momento cabrador ou curso de picar maior", .group = group, .source = "momentos no trem principal" });
    if (assembled.liftoff_speed > 0) {
        const speed = assembled.rotation_speed;
        const ok = speed <= assembled.liftoff_speed;
        try checks.append(memory, .{ .status = status(ok, speed <= 1.3 * assembled.liftoff_speed), .item = "rotação com a tração (trem principal)", .value = if (std.math.isFinite(speed)) try text(memory, "a partir de {d:.1} m/s", .{speed}) else "não roda", .criterion = try text(memory, "≤ V de sair do chão ({d:.1} m/s)", .{assembled.liftoff_speed}), .why = if (ok) "" else "a tração passa acima do apoio do trem e pica o nariz: a rotação fica para depois da velocidade de sair do chão", .fix = if (ok) "" else "EH invertida/maior, trem principal mais perto do CG, motor mais baixo ou inclinado", .group = group, .source = "momentos no trem principal" });
    }
    const close = @abs(assembled.mass - requested_mass) <= 0.1 * requested_mass;
    try checks.append(memory, .{ .status = status(close, true), .item = "massa montada × massa estimada", .value = try text(memory, "{d:.2} kg", .{assembled.mass}), .criterion = try text(memory, "{d} kg ± 10 %", .{requested_mass}), .why = if (close) "" else "a asa foi dimensionada para outra massa (o ponto de partida)", .fix = if (close) "" else "o Estudo e ponto de projeto acerta a massa sozinho; ou mude a massa estimada em Condições e restrições", .group = group });
    if (assembled.boom_hits_prop) try checks.append(memory, .{ .status = .falha, .item = "hélice propulsora × tubo de cauda", .value = "atravessa", .criterion = "livre", .why = "a hélice gira onde passa o tubo", .fix = "tratora, dois motores na asa, ou cauda sem tubo", .group = group });
    const values = [_]struct { key: []const u8, value: f64 }{
        .{ .key = "length", .value = assembled.length },               .{ .key = "n_motor", .value = @floatFromInt(assembled.plane.propulsion.len) },
        .{ .key = "sm", .value = assembled.margin },                   .{ .key = "mass", .value = assembled.mass },
        .{ .key = "pv", .value = assembled.empty },                    .{ .key = "cp", .value = assembled.payload },
        .{ .key = "ee", .value = assembled.payload / assembled.empty }, .{ .key = "S", .value = assembled.built.wing.area },
        .{ .key = "b", .value = assembled.built.wing.span },           .{ .key = "AR", .value = assembled.built.wing.aspect_ratio },
        .{ .key = "V_S", .value = assembled.stall_speed },             .{ .key = "s_to", .value = assembled.takeoff_run },
        .{ .key = "V_max", .value = assembled.max_speed },             .{ .key = "RC", .value = assembled.climb_max },
        .{ .key = "TW", .value = assembled.thrust_weight },            .{ .key = "mtow", .value = assembled.runway_mtow },
        .{ .key = "n_surf", .value = @floatFromInt(assembled.plane.surfaces.len) },
    };
    for ((try registry.constraintList(project)).items) |item| {
        const constraint = registry.readConstraint(item);
        if (!constraint.active) continue;
        const value = for (values) |pair| {
            if (std.mem.eql(u8, pair.key, constraint.key)) break pair.value;
        } else continue;
        const info = registry.quantity(constraint.key);
        const ok = constraint.holds(value);
        const fix = if (std.mem.eql(u8, constraint.key, "s_to")) (if (std.math.isFinite(assembled.runway_mtow)) try text(memory, "MTOW pela corrida restrita = {d:.2} kg", .{assembled.runway_mtow}) else "tração/área não bastam para essa massa") else info.fix;
        try checks.append(memory, .{ .status = if (ok) .ok else .falha, .item = try text(memory, "restrição: {s}", .{info.label}), .value = try text(memory, "{s} {s}", .{ try numberText(memory, value), info.unit }), .criterion = try text(memory, "{s} {s} {s}", .{ constraint.op, try numberText(memory, constraint.value), info.unit }), .why = if (ok) "" else "não cumpre a restrição ativa", .fix = if (ok) "" else fix, .group = "restrições", .source = "restrições (Condições e restrições…)" });
    }
    const spare = std.math.isFinite(assembled.max_speed) and assembled.max_speed >= 1.15 * cruise;
    try checks.append(memory, .{ .status = status(spare, true), .item = "folga de tração no cruzeiro", .value = try text(memory, "V máx. = {d:.1} m/s", .{assembled.max_speed}), .criterion = try text(memory, "≥ 1,15 × {d} m/s", .{cruise}), .why = if (spare) "" else "pouca tração sobrando em cruzeiro", .fix = if (spare) "" else "hélice/motor maior ou menos arrasto", .group = "desempenho" });
    const climbs = assembled.climb_max >= 1.0;
    try checks.append(memory, .{ .status = status(climbs, true), .item = "subida", .value = try text(memory, "{d:.2} m/s", .{assembled.climb_max}), .criterion = "≥ 1 m/s", .why = if (climbs) "" else "sobe devagar", .group = "desempenho" });
    try checks.append(memory, .{ .status = .info, .item = "método", .value = "pontos de desempenho", .criterion = "—", .why = "C_D0 das superfícies, fuselagem e tubo + C_Di da linha sustentadora; tração do equilíbrio motor + hélice com acelerador cheio; corrida até 1,1 V_S", .group = "desempenho" });

    // a tabela de massas
    var rows: std.ArrayList([]const []const u8) = .empty;
    for (assembled.mass_rows) |row| try rows.append(memory, try memory.dupe([]const u8, &.{ row[0], row[1], row[2], row[3], try text(memory, "{d:.1}", .{100 * (std.fmt.parseFloat(f64, row[2]) catch 0) / assembled.mass}) }));
    try rows.append(memory, try memory.dupe([]const u8, &.{ "PV", "peso vazio", try text(memory, "{d:.3}", .{assembled.empty}), "", try text(memory, "{d:.1}", .{100 * assembled.empty / assembled.mass}) }));
    try rows.append(memory, try memory.dupe([]const u8, &.{ "CP", "carga paga", try text(memory, "{d:.3}", .{assembled.payload}), "", try text(memory, "{d:.1}", .{100 * assembled.payload / assembled.mass}) }));
    try rows.append(memory, try memory.dupe([]const u8, &.{ "", "total", try text(memory, "{d:.3}", .{assembled.mass}), try text(memory, "{d:.3} (CG)", .{assembled.x_target}), "100" }));
    if (std.math.isFinite(assembled.runway_mtow)) try rows.append(memory, try memory.dupe([]const u8, &.{ "", "MTOW pela pista → CP possível = MTOW − PV", try text(memory, "{d:.3}", .{assembled.runway_mtow}), "", try text(memory, "CP {d:.2} kg", .{assembled.runway_mtow - assembled.empty}) }));
    const tables = try memory.dupe(simulation.Table, &.{.{ .title = "Distribuição de massa", .headers = &.{ "grupo", "item", "massa (kg)", "x (m)", "% do total" }, .rows = rows.items }});

    out.summary = summary.items;
    out.checks = checks.items;
    out.figures = figures;
    out.tables = tables;
    out.view = try viewOf(memory, assembled.plane);
    return out;
}

fn viewOf(memory: std.mem.Allocator, plane: model.Aircraft) !?simulation.View {
    var diagnosis: model.Diag = .{};
    const pieces = aircraft_model.skeleton.build(memory, &plane, &diagnosis) catch return null;
    var meshes: std.ArrayList(simulation.Mesh) = .empty;
    for (pieces.pieces) |piece| try meshes.append(memory, .{ .kind = @tagName(piece.color), .vertices = piece.mesh.v, .faces = piece.mesh.f });
    return .{ .meshes = meshes.items, .cg = plane.design_cg };
}

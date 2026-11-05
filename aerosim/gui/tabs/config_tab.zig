//! O painel da Montagem, o par de `info_html` (`config_tab.py`): tudo o que dá para saber da configuração sem
//! simular. São a massa e o CG (com o líquido e a carga, e depois da soltura), as dimensões a partir do CG, a
//! aerodinâmica do núcleo (C_L0, C_Lα, C_Lmax, margem, ponto neutro, estol e volumes de cauda), a carga alar e a
//! tração estática, a propulsão, o trem, a pista, a LAPES e o percurso, com os avisos no fim. A conta é do núcleo
//! (`aircraft_model.params`, `core.mass`, `core.propulsion`) e das dimensões (`design/dims.zig`); aqui só se
//! juntam os números no texto que a tela mostra.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const manager = @import("manager");
const dims = @import("design");

const model = aircraft_model.aircraft;
const params = aircraft_model.params;
const Aircraft = model.Aircraft;
const geometry = manager.stability;
const gravity = 9.80665;

/// uma linha do painel; `warning` pinta o valor de vermelho
pub const Row = struct { item: []const u8, value: []const u8, warning: bool = false };
/// um bloco do painel, com o título
pub const Section = struct { title: []const u8, rows: []const Row };

/// o painel inteiro e os pontos que a vista 3D marca
pub const Panel = struct {
    name: []const u8,
    summary: []const u8, // o resumo da configuração (`Features.summary`)
    sections: []const Section,
    warnings: []const []const u8,
    cg: [3]f64,
    neutral_x: f64,
};

const Builder = struct {
    memory: std.mem.Allocator,
    rows: std.ArrayList(Row) = .empty,
    sections: std.ArrayList(Section) = .empty,

    fn add(builder: *Builder, item: []const u8, comptime format: []const u8, args: anytype) !void {
        try builder.rows.append(builder.memory, .{ .item = item, .value = try std.fmt.allocPrint(builder.memory, format, args) });
    }

    fn close(builder: *Builder, title: []const u8) !void {
        try builder.sections.append(builder.memory, .{ .title = title, .rows = try builder.rows.toOwnedSlice(builder.memory) });
    }
};

/// o painel do avião (`info_html`); o núcleo é configurado uma vez
pub fn panel(memory: std.mem.Allocator, aircraft: *const Aircraft) !Panel {
    const instance = try std.heap.page_allocator.create(core.runner.Instance);
    defer std.heap.page_allocator.destroy(instance);
    instance.* = .{};
    var diagnosis: model.Diag = .{};
    _ = try params.setup(aircraft, instance, &diagnosis);
    const info = params.staticCharacteristics(instance, aircraft);
    const zero_state = [_]f64{0} ** core.state.nx;
    const mass_props = core.mass.compute(instance.ctx(), &zero_state);
    const total = mass_props.m;
    const cg = [3]f64{ mass_props.rcg[0], mass_props.rcg[1], mass_props.rcg[2] };
    const references = params.references(aircraft);
    const area = references[0];
    const chord = references[1];
    const span = references[2];
    const leading = params.macLeadingEdge(aircraft);
    const fraction = struct {
        fn of(leading_edge: f64, mean_chord: f64, x: f64) f64 {
            return 100 * (leading_edge - x) / mean_chord;
        }
    }.of;
    const margin = 100 * info.static_margin;
    const neutral_x = cg[0] - info.static_margin * chord; // dC_m/dC_L = (x_NP − x_CG)/c, x + à frente
    var warnings: std.ArrayList([]const u8) = .empty;
    var builder: Builder = .{ .memory = memory };

    // ---- massa e CG
    const dry = params.dryMass(aircraft).m;
    var liquid: f64 = 0;
    for (aircraft.tanks) |tank| liquid += tank.rho * tank.volume / 1000.0;
    const payload = aircraft.payload;
    const carried = if (payload.enabled) payload.mass else 0;
    try builder.add("massa total", "{d:.3} kg", .{total});
    try builder.add("aeronave seca", "{d:.3} kg", .{dry});
    try builder.add("líquido nos tanques", "{d:.3} kg", .{liquid});
    try builder.add("carga LAPES", "{d:.3} kg", .{carried});
    if (aircraft.ballast.enabled) try builder.add("lastro", "{d:.3} kg em x = {d:.3} m", .{ aircraft.ballast.mass, aircraft.ballast.x }) else try builder.add("lastro", "—", .{});
    try builder.add("CG (x, y, z)", "({d:.3}, {d:.3}, {d:.3}) m", .{ cg[0], cg[1], cg[2] });
    try builder.add("CG em % da CMA", "{d:.1} %", .{fraction(leading, chord, cg[0])});
    if (payload.enabled and payload.mass > 0) { // a LAPES sai na soltura: o CG anda
        const after = total - payload.mass;
        const after_x = (total * cg[0] - payload.mass * payload.x) / after;
        try builder.add("CG depois da soltura", "x = {d:.3} m ({d:.1} % CMA), {d:.3} kg", .{ after_x, fraction(leading, chord, after_x), after });
    }
    try builder.add("Ixx, Iyy, Izz", "{d:.3}, {d:.3}, {d:.3} kg·m²", .{ mass_props.I[0][0], mass_props.I[1][1], mass_props.I[2][2] });
    try builder.close("Massa e CG");

    // ---- dimensões a partir do CG de projeto (ou do atual, sem projeto)
    const origin = dims.designCg(aircraft);
    if (aircraft.design_cg) |design| try builder.add("CG atual − CG de projeto", "({s}, {s}, {s}) m", .{ try signed(memory, cg[0] - design[0]), try signed(memory, cg[1] - design[1]), try signed(memory, cg[2] - design[2]) });
    const lines = try dims.dimensions(memory, aircraft, origin);
    for (lines[1..]) |line| {
        const position = if (line.delta) |delta| try std.fmt.allocPrint(memory, "({s}, {s}, {s})", .{ try signed(memory, delta[0]), try signed(memory, delta[1]), try signed(memory, delta[2]) }) else "";
        const value = if (line.value) |number| try std.fmt.allocPrint(memory, "= {d:.3}", .{number}) else "";
        const text = std.mem.trim(u8, try std.mem.join(memory, " ", &.{ position, value }), " ");
        try builder.rows.append(memory, .{ .item = line.item, .value = text });
    }
    try builder.close(if (aircraft.design_cg != null) "Dimensões a partir do CG de projeto (Δx, Δy, Δz) m" else "Dimensões a partir do CG atual (Δx, Δy, Δz) m");

    // ---- aerodinâmica do núcleo
    const margin_ok = margin >= 5 and margin <= 30;
    if (!margin_ok) try warnings.append(memory, try std.fmt.allocPrint(memory, "margem estática {d:.1} % fora de 5–30 %", .{margin}));
    try builder.add("S, b, AR", "{d:.3} m², {d:.2} m, {d:.2}", .{ area, span, span * span / area });
    try builder.add("CMA (c̄)", "{d:.3} m", .{chord});
    try builder.add("C_L0, C_Lα", "{d:.3}, {d:.2} /rad", .{ info.CL0, info.CLa });
    try builder.add("C_Lmax (α de estol)", "{d:.2} ({d:.1}°)", .{ info.CLmax, info.alpha_stall_deg });
    try builder.rows.append(memory, .{ .item = "margem estática", .value = try std.fmt.allocPrint(memory, "{d:.1} %", .{margin}), .warning = !margin_ok });
    try builder.add("ponto neutro x_NP", "{d:.3} m", .{neutral_x});
    try builder.add("V de estol", "{d:.2} m/s", .{info.Vs});
    const tails = geometry.tailVolumes(aircraft, cg[0], references);
    if (tails.horizontal_area > 0) try builder.add("volume de cauda horizontal V_H", "{d:.3} (braço {d:.2} m)", .{ tails.horizontal, tails.horizontal_arm });
    if (tails.vertical_area > 0) try builder.add("volume de cauda vertical V_V", "{d:.4} (braço {d:.2} m)", .{ tails.vertical, tails.vertical_arm });
    try builder.close("Aerodinâmica (núcleo)");

    // ---- cargas
    const weight = total * gravity;
    var static_thrust: f64 = 0;
    for (instance.p.prop[0..@intCast(instance.p.n_prop)]) |*unit| static_thrust += core.propulsion.point(&instance.p, unit, 0, 1).T;
    try builder.add("carga alar W/S", "{d:.1} N/m² ({d:.2} kg/m²)", .{ weight / area, total / area });
    try builder.add("tração estática total", "{d:.1} N", .{static_thrust});
    if (weight > 0) try builder.add("T/W estático", "{d:.3}", .{static_thrust / weight}) else try builder.add("T/W estático", "—", .{});
    try builder.close("Cargas");
    if (static_thrust / weight < 0.25) try warnings.append(memory, try std.fmt.allocPrint(memory, "T/W estático baixo ({d:.2})", .{static_thrust / weight}));

    // ---- propulsão
    for (aircraft.propulsion) |unit| if (unit.enabled) {
        const battery = unit.battery;
        const source = if (std.mem.eql(u8, unit.thrust_model, "poly")) try std.fmt.allocPrint(memory, "polinômio '{s}'", .{unit.thrust_poly.name}) else try std.fmt.allocPrint(memory, "{d:.0} Kv, hélice {d:.1}\"", .{ unit.motor.Kv, unit.propeller.D * 39.37 });
        try builder.add(unit.name, "{s}; bateria {d:.0}S {d:.0} mAh ({d:.0} Wh)", .{ source, battery.cells, battery.capacity_mAh, battery.voc() * battery.capacity_mAh / 1000 });
    };
    if (builder.rows.items.len > 0) try builder.close("Propulsão");

    // ---- trem de pouso
    try gearRows(&builder, aircraft, cg, &warnings);
    try builder.close("Trem de pouso");

    // ---- pista
    const field = aircraft.airfield;
    if (std.mem.eql(u8, field.takeoff_from, "chão")) try builder.add("decolagem", "do chão", .{}) else try builder.add("decolagem", "de uma mesa de {s} m de altura, {s} m à frente", .{ try geometry.general(memory, field.table_height), try geometry.general(memory, field.table_length) });
    if (std.mem.eql(u8, field.landing_on, "chão")) try builder.add("pouso", "no chão", .{}) else try builder.add("pouso", "numa plataforma de {s} m × {s} m", .{ try geometry.general(memory, field.platform_height), try geometry.general(memory, field.platform_length) });
    try builder.add("comprimento de pista exigido (x_warning)", "{s} m", .{try geometry.general(memory, field.x_warning)});
    try builder.add("altura mínima (z_warning)", "{s} m", .{try geometry.general(memory, field.z_warning)});
    if (field.landing_max > 0) try builder.add("distância máxima de pouso", "{s} m", .{try geometry.general(memory, field.landing_max)});
    try builder.close("Pista");

    // ---- LAPES
    if (payload.enabled) {
        try builder.add("massa", "{d:.2} kg", .{payload.mass});
        try builder.add("posição", "({d:.3}, {d:.3}, {d:.3}) m", .{ payload.x, payload.y, payload.z });
        var drop: ?model.MissionEvent = null;
        for (aircraft.mission.events) |event| if (drop == null and std.mem.eql(u8, event.kind, "drop")) {
            drop = event;
        };
        if (drop) |event| {
            const legs = aircraft.mission.legs;
            const leg_name = if (event.leg >= 0 and event.leg < legs.len) legs[@intCast(event.leg)].name else "?";
            try builder.add("soltura", "perna {d} ({s}), s = {d:.0} m", .{ event.leg, leg_name, event.s });
        } else try builder.add("soltura", "sem evento de soltura", .{});
        try builder.add("alvo", "n = {s} m, e = {s} m{s}", .{ try geometry.general(memory, payload.target_n), try geometry.general(memory, payload.target_e), if (payload.aim) " (procura o ponto)" else "" });
        try builder.close("LAPES");
    }

    // ---- percurso
    const segments = instance.p.seg[0..@intCast(instance.p.n_seg)];
    var length: f64 = 0;
    var highest: f64 = 0;
    for (segments) |segment| {
        length += segment.L;
        highest = @max(highest, segment.h1);
    }
    try builder.add("pernas", "{d}", .{segments.len});
    try builder.add("comprimento", "{d:.0} m", .{length});
    try builder.add("altura máx.", "{d:.0} m", .{highest});
    try builder.close("Percurso");

    const configuration = geometry.detectConfiguration(aircraft);
    return .{
        .name = aircraft.name,
        .summary = try geometry.configurationSummary(memory, aircraft, configuration),
        .sections = try builder.sections.toOwnedSlice(memory),
        .warnings = try warnings.toOwnedSlice(memory),
        .cg = cg,
        .neutral_x = neutral_x,
    };
}

/// o trem: tipo, distância entre eixos, peso na bequilha, bitola e o ângulo que encosta a cauda (as pernas de
/// `Gear.legs`)
fn gearRows(builder: *Builder, aircraft: *const Aircraft, cg: [3]f64, warnings: *std.ArrayList([]const u8)) !void {
    const gear = aircraft.gear;
    const memory = builder.memory;
    const Leg = struct { kind: []const u8, x: f64, y: f64, z: f64 };
    var legs: std.ArrayList(Leg) = .empty;
    if (std.mem.eql(u8, gear.layout, "custom")) {
        for (gear.custom) |leg| try legs.append(memory, .{ .kind = leg.kind, .x = leg.x, .y = leg.y, .z = leg.z });
    } else {
        try legs.append(memory, .{ .kind = "steer", .x = gear.steer_x, .y = 0, .z = gear.steer_z });
        try legs.append(memory, .{ .kind = "main", .x = gear.main_x, .y = -gear.main_track / 2, .z = gear.main_z });
        try legs.append(memory, .{ .kind = "main", .x = gear.main_x, .y = gear.main_track / 2, .z = gear.main_z });
        if (std.mem.eql(u8, gear.layout, "tricycle") and gear.tail_skid) try legs.append(memory, .{ .kind = "skid", .x = gear.skid_x, .y = 0, .z = gear.skid_z });
    }
    var main_legs: std.ArrayList(Leg) = .empty;
    var steer: ?Leg = null;
    var skid: ?Leg = null;
    for (legs.items) |leg| {
        if (std.mem.eql(u8, leg.kind, "main")) try main_legs.append(memory, leg);
        if (steer == null and std.mem.eql(u8, leg.kind, "steer")) steer = leg;
        if (skid == null and std.mem.eql(u8, leg.kind, "skid")) skid = leg;
    }
    try builder.add("tipo", "{s}", .{gear.layout});
    const mains = main_legs.items;
    if (mains.len > 0) if (steer) |nose| {
        try builder.add("distância entre eixos", "{d:.3} m", .{@abs(nose.x - mains[0].x)});
        if (std.mem.eql(u8, gear.layout, "tricycle")) {
            const share = if (nose.x != mains[0].x) (nose.x - cg[0]) / (nose.x - mains[0].x) else std.math.nan(f64);
            try builder.add("peso na bequilha (estático)", "{d:.1} %", .{100 * (1 - share)});
            if (!(1 - share >= 0.05 and 1 - share <= 0.25)) try warnings.append(memory, try std.fmt.allocPrint(memory, "peso na bequilha {d:.0} % (usual 5–20 %)", .{100 * (1 - share)}));
        }
    };
    if (mains.len >= 2) try builder.add("bitola", "{d:.3} m", .{@abs(mains[0].y - mains[mains.len - 1].y)});
    if (mains.len > 0) if (skid) |tail| if (mains[0].x > tail.x) {
        try builder.add("θ que encosta a cauda", "{d:.1}°", .{std.math.radiansToDegrees(std.math.atan2(mains[0].z - tail.z, mains[0].x - tail.x))});
    };
}

/// um número com o sinal sempre escrito, três casas (`{:+.3f}`)
fn signed(memory: std.mem.Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(memory, "{s}{d:.3}", .{ if (value < 0) "-" else "+", @abs(value) });
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "o painel da Montagem dá os números do Python no Convencional_original" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 24));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    const shown = try panel(memory, &loaded.ac);
    // o texto de `info_html` no Python, bloco por bloco
    const expected = [_]struct { []const u8, []const [2][]const u8 }{
        .{ "Massa e CG", &.{ .{ "massa total", "12.390 kg" }, .{ "aeronave seca", "8.390 kg" }, .{ "líquido nos tanques", "2.000 kg" }, .{ "carga LAPES", "2.000 kg" }, .{ "lastro", "—" }, .{ "CG (x, y, z)", "(0.008, 0.000, 0.021) m" }, .{ "CG em % da CMA", "31.7 %" }, .{ "CG depois da soltura", "x = 0.019 m (28.9 % CMA), 10.390 kg" }, .{ "Ixx, Iyy, Izz", "0.912, 1.237, 1.924 kg·m²" } } },
        .{ "Dimensões a partir do CG atual (Δx, Δy, Δz) m", &.{ .{ "altura do CG ao chão", "= 0.220" }, .{ "x_CG / CMA (do bordo de ataque da CMA)", "= 0.338" }, .{ "CA da asa (1/4 da CMA)", "(+0.035, +0.000, -0.120) = 0.088" }, .{ "bordo de ataque da raiz", "(+0.135, +0.000, -0.120) = 0.340" }, .{ "TDP (trem principal)", "(-0.050, +0.300, +0.220) = 0.050" }, .{ "TDN (bequilha)", "(+0.450, +0.000, +0.220) = 0.450" }, .{ "bitola", "= 0.600" }, .{ "ângulo de tombamento", "= 12.804" }, .{ "sapata de cauda", "(-1.100, +0.000, +0.000) = 0.220" }, .{ "motor 1: cubo da hélice", "(+0.550, +0.000, +0.000) = 0.029" }, .{ "EH: CA", "(-1.050, +0.000, -0.050) = 1.050" }, .{ "EH: altura ao chão", "= 0.270" }, .{ "EV: CA", "(-1.100, +0.000, -0.001) = 1.100" }, .{ "EV: altura ao chão", "= 0.221" }, .{ "tanque 1", "(+0.100, +0.000, +0.050) = 2.000" }, .{ "LAPES", "(-0.050, +0.000, +0.080) = 2.000" } } },
        .{ "Aerodinâmica (núcleo)", &.{ .{ "S, b, AR", "1.000 m², 2.50 m, 6.25" }, .{ "CMA (c̄)", "0.400 m" }, .{ "C_L0, C_Lα", "0.398, 4.75 /rad" }, .{ "C_Lmax (α de estol)", "1.65 (16.2°)" }, .{ "margem estática", "17.7 %" }, .{ "ponto neutro x_NP", "-0.063 m" }, .{ "V de estol", "10.97 m/s" }, .{ "volume de cauda horizontal V_H", "0.529 (braço 1.06 m)" }, .{ "volume de cauda vertical V_V", "0.0532 (braço 1.11 m)" } } },
        .{ "Cargas", &.{ .{ "carga alar W/S", "121.5 N/m² (12.39 kg/m²)" }, .{ "tração estática total", "27.6 N" }, .{ "T/W estático", "0.227" } } },
        .{ "Propulsão", &.{.{ "motor 1", "310 Kv, hélice 15.0\"; bateria 6S 5000 mAh (111 Wh)" }} },
        .{ "Trem de pouso", &.{ .{ "tipo", "tricycle" }, .{ "distância entre eixos", "0.500 m" }, .{ "peso na bequilha (estático)", "11.6 %" }, .{ "bitola", "0.600 m" }, .{ "θ que encosta a cauda", "11.8°" } } },
        .{ "Pista", &.{ .{ "decolagem", "do chão" }, .{ "pouso", "no chão" }, .{ "comprimento de pista exigido (x_warning)", "60 m" }, .{ "altura mínima (z_warning)", "1 m" } } },
        .{ "LAPES", &.{ .{ "massa", "2.00 kg" }, .{ "posição", "(-0.050, 0.000, 0.080) m" }, .{ "soltura", "perna 4 (passagem LAPES), s = 170 m" }, .{ "alvo", "n = 0 m, e = 0 m (procura o ponto)" } } },
        .{ "Percurso", &.{ .{ "pernas", "9" }, .{ "comprimento", "2049 m" }, .{ "altura máx.", "15 m" } } },
    };
    try testing.expectEqual(expected.len, shown.sections.len);
    for (expected, shown.sections) |want, got| {
        try testing.expectEqualStrings(want[0], got.title);
        try testing.expectEqual(want[1].len, got.rows.len);
        for (want[1], got.rows) |line, row| {
            try testing.expectEqualStrings(line[0], row.item);
            // num empate o último algarismo pode arredondar para o outro lado (0,0295 dá 0,029 no Python e 0,030
            // aqui; 16,25° dá 16,2 e 16,3): cada número com folga de uma unidade do último algarismo
            try expectSameNumbers(line[1], row.value);
        }
    }
    try testing.expectEqual(@as(usize, 1), shown.warnings.len);
    try testing.expectEqualStrings("T/W estático baixo (0.23)", shown.warnings[0]);
    try testing.expectEqualStrings("EH: EH; arfagem por elevator; rolagem por aileron; guinada por rudder; líquido livre (sloshing); carga lançável", shown.summary);
}

/// os números de dois textos, na ordem, iguais até uma unidade do último algarismo escrito, e o resto do texto igual
fn expectSameNumbers(expected: []const u8, found: []const u8) !void {
    var want: [8]f64 = undefined;
    var want_step: [8]f64 = undefined;
    var got: [8]f64 = undefined;
    var got_step: [8]f64 = undefined;
    const count = numbersIn(expected, &want, &want_step);
    try testing.expectEqual(count, numbersIn(found, &got, &got_step));
    for (want[0..count], got[0..count], want_step[0..count]) |number, other, step| try testing.expectApproxEqAbs(number, other, 1.001 * step);
    var expected_words: [256]u8 = undefined;
    var found_words: [256]u8 = undefined;
    try testing.expectEqualStrings(withoutDigits(expected, &expected_words), withoutDigits(found, &found_words));
}

fn numbersIn(text: []const u8, out: *[8]f64, steps: *[8]f64) usize {
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " (),=");
    while (tokens.next()) |token| if (std.fmt.parseFloat(f64, token)) |number| {
        if (count < out.len) {
            out[count] = number;
            const decimals = if (std.mem.indexOfScalar(u8, token, '.')) |dot| token.len - dot - 1 else 0;
            steps[count] = std.math.pow(f64, 10, -@as(f64, @floatFromInt(decimals)));
        }
        count += 1;
    } else |_| {};
    return count;
}

fn withoutDigits(text: []const u8, buffer: *[256]u8) []const u8 {
    var length: usize = 0;
    for (text) |char| if (!std.ascii.isDigit(char) and length < buffer.len) {
        buffer[length] = char;
        length += 1;
    };
    return buffer[0..length];
}

// ------------------------------------------------------------------ a lista de componentes e o editor da peça

const form_meta = manager.form_meta;

/// o tipo de peça da lista (`_fill_list`): as peças do avião e, depois, os dados que não são geometria
pub const Part = enum { surface, prop, tank, fuselage, boom, payload, ballast, gear, modifiers, airfield, mass, environment, performance, takeoff, autopilot, sim, mission };

/// uma linha da lista de componentes: a peça, qual delas (nas listas) e o texto
pub const Component = struct { part: Part, index: usize = 0, label: []const u8 };

/// os dados que não são geometria, na ordem e com o texto do Python (`NONGEOM`)
const nongeometric = [_]struct { Part, []const u8 }{
    .{ .airfield, "Pista: chão, mesa e plataforma" },
    .{ .mass, "Massa e inércia" },
    .{ .environment, "Ambiente: altitude-densidade (AD) e vento" },
    .{ .performance, "Envelope de voo: ângulo de cruzeiro, fator de carga" },
    .{ .takeoff, "Decolagem (acionamento do profundor)" },
    .{ .autopilot, "Piloto automático" },
    .{ .sim, "Integração" },
    .{ .mission, "Percurso: partida e eventos" },
};

/// os tubos que a lista mostra: os do formato novo ou o tubo único do formato antigo, se ligado
fn listedBooms(aircraft: *const Aircraft) []const model.Boom {
    if (aircraft.booms.len > 0) return aircraft.booms;
    return if (aircraft.boom.enabled) @as(*const [1]model.Boom, &aircraft.boom) else &.{};
}

/// a lista de componentes do avião, na ordem do Python (sem os ícones, que a fonte não tem)
pub fn components(memory: std.mem.Allocator, aircraft: *const Aircraft) ![]Component {
    var list: std.ArrayList(Component) = .empty;
    const off = struct {
        fn text(enabled: bool) []const u8 {
            return if (enabled) "" else " (desligado)";
        }
    }.text;
    for (aircraft.surfaces, 0..) |surface, i| {
        var label: std.ArrayList(u8) = .empty;
        try label.print(memory, "{s} ({s})", .{ surface.name, surface.role });
        // as asas ligadas (mesmo grupo), como `wing_group`
        if (std.mem.eql(u8, surface.role, "wing") and surface.group.len > 0) {
            var first = true;
            for (aircraft.surfaces, 0..) |other, k| {
                if (k == i or !other.enabled or !std.mem.eql(u8, other.role, "wing") or !std.mem.eql(u8, other.group, surface.group)) continue;
                try label.print(memory, "{s}{s}", .{ if (first) " ligada a " else ", ", other.name });
                first = false;
            }
        }
        try list.append(memory, .{ .part = .surface, .index = i, .label = label.items });
    }
    for (aircraft.propulsion, 0..) |unit, i| try list.append(memory, .{ .part = .prop, .index = i, .label = unit.name });
    for (aircraft.tanks, 0..) |tank, i| try list.append(memory, .{ .part = .tank, .index = i, .label = tank.name });
    try list.append(memory, .{ .part = .fuselage, .label = try std.fmt.allocPrint(memory, "fuselagem{s}", .{off(aircraft.fuselage.enabled)}) });
    for (listedBooms(aircraft), 0..) |boom, i| try list.append(memory, .{ .part = .boom, .index = i, .label = try std.fmt.allocPrint(memory, "{s}{s}", .{ boom.name, off(boom.enabled) }) });
    try list.append(memory, .{ .part = .payload, .label = try std.fmt.allocPrint(memory, "LAPES: carga e soltura{s}", .{off(aircraft.payload.enabled)}) });
    const ballast = aircraft.ballast;
    try list.append(memory, .{ .part = .ballast, .label = if (ballast.enabled) try std.fmt.allocPrint(memory, "Lastro ({s} kg)", .{try geometry.general(memory, ballast.mass)}) else "Lastro (desligado)" });
    try list.append(memory, .{ .part = .gear, .label = try std.fmt.allocPrint(memory, "trem de pouso ({s})", .{aircraft.gear.layout}) });
    try list.append(memory, .{ .part = .modifiers, .label = try std.fmt.allocPrint(memory, "Modificadores ({d} ligado(s))", .{activeModifiers(aircraft)}) });
    for (nongeometric) |entry| try list.append(memory, .{ .part = entry[0], .label = entry[1] });
    return list.items;
}

/// os modificadores ligados; o arquivo sem a chave tem o padrão da GUI (só o efeito solo de McCormick, ligado)
fn activeModifiers(aircraft: *const Aircraft) usize {
    const list = aircraft.modifiers orelse return 1;
    var count: usize = 0;
    for (list) |modifier| count += @intFromBool(modifier.enabled);
    return count;
}

/// como um campo aparece no editor (o `ParamSpec` de `forms.py`)
pub const FieldKind = enum { number, optional_number, integer, toggle, choice, text };

/// um campo do editor: o nome no arquivo, o texto da tela e o valor atual
pub const Spec = struct {
    name: []const u8,
    label: []const u8,
    unit: []const u8 = "",
    help: []const u8 = "",
    kind: FieldKind,
    number: f64 = 0,
    automatic: bool = false, // número opcional: "auto" (null no arquivo)
    checked: bool = false,
    text: []const u8 = "",
    choices: []const []const u8 = &.{},
    target: ?usize = null, // o item da lista `container` (ou dos modificadores) a que o campo pertence
    container: []const u8 = "", // "" o objeto da peça; senão a chave, nele, do objeto (o perfil) ou da lista (seções...)
    group: usize = 0, // o bloco do formulário (`Layout.groups`)
};

/// os campos que o Python deixa de fora de cada peça (`_edit`): têm editores próprios
fn excluded(part: Part) []const []const u8 {
    return switch (part) {
        .surface => &.{ "sections", "controls", "airfoil", "devices", "group" },
        .prop => &.{ "motor", "propeller", "battery" },
        .takeoff => &.{ "VR", "de0", "rate_de", "rate_thr" },
        .gear => &.{"custom"},
        .mass => &.{"items"},
        .mission => &.{ "legs", "events" },
        .environment => &.{"rho"},
        else => &.{},
    };
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// os campos de um valor de struct, pela ordem dos campos (a mesma da dataclass): número, número opcional, inteiro,
/// marcador e texto (escolha quando `form_meta` tem as opções); listas e structs dentro ficam de fora (editores
/// próprios), como em `forms.specs`
fn fieldsOf(memory: std.mem.Allocator, list: *std.ArrayList(Spec), value: anytype, exclude: []const []const u8) !void {
    return itemFieldsOf(memory, list, value, exclude, .{ .name = "", .label = "", .kind = .number }, null);
}

/// `fieldsOf` com o endereço do campo no arquivo (`template`: bloco, objeto ou item da lista) e as opções de "kind",
/// que dependem da lista (tipos de comando, de perna, de evento)
fn itemFieldsOf(memory: std.mem.Allocator, list: *std.ArrayList(Spec), value: anytype, exclude: []const []const u8, template: Spec, kinds: ?[]const []const u8) !void {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        if (!contains(exclude, field.name)) {
            const current = @field(value, field.name);
            var spec = template;
            spec.name = field.name;
            spec.label = form_meta.label(field.name);
            spec.unit = form_meta.unit(field.name);
            spec.help = form_meta.help(field.name);
            spec.kind = .number;
            const known = switch (field.type) {
                f64 => blk: {
                    spec.number = current;
                    break :blk true;
                },
                ?f64 => blk: {
                    spec.kind = .optional_number;
                    spec.automatic = current == null;
                    spec.number = current orelse 0;
                    break :blk true;
                },
                i64 => blk: {
                    spec.kind = .integer;
                    spec.number = @floatFromInt(current);
                    break :blk true;
                },
                bool => blk: {
                    spec.kind = .toggle;
                    spec.checked = current;
                    break :blk true;
                },
                []const u8 => blk: {
                    spec.text = current;
                    spec.kind = .text;
                    const listed = if (kinds != null and std.mem.eql(u8, field.name, "kind")) kinds else form_meta.choices(field.name);
                    if (listed) |options| {
                        spec.kind = .choice;
                        spec.choices = options;
                        if (!contains(options, current) and current.len > 0) { // o valor que saiu da lista fica como opção
                            const widened = try memory.alloc([]const u8, options.len + 1);
                            @memcpy(widened[0..options.len], options);
                            widened[options.len] = current;
                            spec.choices = widened;
                        }
                    }
                    break :blk true;
                },
                else => false,
            };
            if (known) try list.append(memory, spec);
        }
    }
}

/// os campos da peça escolhida, com os valores do avião
pub fn specs(memory: std.mem.Allocator, aircraft: *const Aircraft, component: Component) ![]Spec {
    var list: std.ArrayList(Spec) = .empty;
    const exclude = excluded(component.part);
    switch (component.part) {
        .surface => try fieldsOf(memory, &list, aircraft.surfaces[component.index], exclude),
        .prop => try fieldsOf(memory, &list, aircraft.propulsion[component.index], exclude),
        .tank => try fieldsOf(memory, &list, aircraft.tanks[component.index], exclude),
        .boom => try fieldsOf(memory, &list, listedBooms(aircraft)[component.index], exclude),
        .modifiers => {
            const defaults = [_]model.Modifier{.{}};
            const list_of = aircraft.modifiers orelse &defaults;
            for (list_of, 0..) |modifier, i| {
                const name = if (modifier.name.len > 0) modifier.name else modifier.kind;
                try list.append(memory, .{ .name = "enabled", .label = name, .kind = .toggle, .checked = modifier.enabled, .target = i, .help = modifier.kind });
            }
        },
        inline else => |part| try fieldsOf(memory, &list, @field(aircraft, @tagName(part)), exclude),
    }
    // "presa em": solta, a ponta de cada tubo ou a ponta de cada outra superfície (`mount_choices`)
    if (component.part == .surface) for (list.items) |*spec| if (std.mem.eql(u8, spec.name, "mount")) {
        spec.kind = .choice;
        spec.choices = try mountChoices(memory, aircraft, component.index);
        if (spec.text.len == 0) spec.text = "solta";
    };
    // asas ligadas (`_group_editor`): com qual outra asa esta forma um conjunto (tandem, biplano)
    if (component.part == .surface and std.mem.eql(u8, aircraft.surfaces[component.index].role, "wing")) {
        const surface = aircraft.surfaces[component.index];
        var options: std.ArrayList([]const u8) = .empty;
        try options.append(memory, "(nenhuma)");
        var current: []const u8 = "(nenhuma)";
        for (aircraft.surfaces, 0..) |other, j| {
            if (j == component.index or !std.mem.eql(u8, other.role, "wing")) continue;
            try options.append(memory, other.name);
            if (surface.group.len > 0 and std.mem.eql(u8, current, "(nenhuma)") and other.enabled and std.mem.eql(u8, other.group, surface.group)) current = other.name;
        }
        try list.append(memory, .{ .name = linked_field, .label = "ligada a", .kind = .choice, .text = current, .choices = options.items, .help = "asas ligadas formam um conjunto só: a área de referência é a soma, a CMA é a média pela área e a margem estática se mede nela. A linha sustentadora e o VLM já calculam a interferência entre elas" });
    }
    // a altitude-densidade é o número que se edita (o ρ sai dela ao gravar); o arquivo antigo, sem ela, a tira do ρ
    if (component.part == .environment) for (list.items) |*spec| if (std.mem.eql(u8, spec.name, "density_altitude")) {
        spec.kind = .number;
        spec.automatic = false;
        spec.number = aircraft.environment.densityAltitude();
    };
    return list.items;
}

/// os campos da soltura da LAPES: não são chaves da carga, são o evento "drop" do percurso que eles escrevem
const drop_on = "soltura: ligada";
const drop_leg = "soltura: perna";
const drop_distance = "soltura: distância";

/// troca o evento "drop" do percurso pelo dos campos da soltura (`_drop_editor`: sem ele, a carga não sai)
fn applyDrop(memory: std.mem.Allocator, document: *std.json.Value, fields: []const Spec) !void {
    var on = false;
    var leg: i64 = 0;
    var distance: f64 = 0;
    for (fields) |spec| {
        if (std.mem.eql(u8, spec.name, drop_on)) on = spec.checked;
        if (std.mem.eql(u8, spec.name, drop_leg)) leg = std.fmt.parseInt(i64, spec.text[0 .. std.mem.indexOfScalar(u8, spec.text, ':') orelse spec.text.len], 10) catch 0;
        if (std.mem.eql(u8, spec.name, drop_distance)) distance = spec.number;
    }
    const mission = try partNode(memory, document, .{ .part = .mission, .label = "" });
    const entry = try mission.getOrPut(memory, "events");
    if (!entry.found_existing or entry.value_ptr.* != .array) entry.value_ptr.* = .{ .array = std.json.Array.init(memory) };
    const events = &entry.value_ptr.array;
    var k: usize = 0;
    while (k < events.items.len) { // os outros eventos ficam; o "drop" sai
        const event = events.items[k];
        const kind = if (event == .object) event.object.get("kind") else null;
        if (kind != null and kind.? == .string and std.mem.eql(u8, kind.?.string, "drop")) {
            _ = events.orderedRemove(k);
        } else k += 1;
    }
    if (!on) return;
    var drop: std.json.ObjectMap = .empty;
    try drop.put(memory, "kind", .{ .string = "drop" });
    try drop.put(memory, "leg", .{ .integer = leg });
    try drop.put(memory, "s", .{ .float = distance });
    try events.append(.{ .object = drop });
}

/// o campo "ligada a" das asas: não é uma chave do arquivo, é o grupo (`group`) que ele muda
const linked_field = "ligada a";

/// liga a superfície `index` à asa chamada `mate` (`link_wings`), ou desliga se `mate` é "(nenhuma)" (`unlink_wing`:
/// a última que sobra sozinha no grupo também sai dele). O grupo novo ganha um id que nenhuma asa usa
fn linkWing(memory: std.mem.Allocator, document: *std.json.Value, index: usize, mate: []const u8) !void {
    const surfaces = (try listNode(memory, document, "surfaces")).items;
    const groupOf = struct {
        fn of(value: std.json.Value) []const u8 {
            if (value != .object) return "";
            const found = value.object.get("group") orelse return "";
            return if (found == .string) found.string else "";
        }
    }.of;
    const nameOf = struct {
        fn of(value: std.json.Value) []const u8 {
            if (value != .object) return "";
            const found = value.object.get("name") orelse return "";
            return if (found == .string) found.string else "";
        }
    }.of;
    if (index >= surfaces.len or surfaces[index] != .object) return error.MissingPart;
    const old_group = groupOf(surfaces[index]);
    // qual asa é a outra (a primeira com o nome, fora esta)
    var target: ?usize = null;
    for (surfaces, 0..) |surface, j| if (j != index and target == null and std.mem.eql(u8, nameOf(surface), mate)) {
        target = j;
    };
    if (target) |j| if (old_group.len > 0 and std.mem.eql(u8, groupOf(surfaces[j]), old_group)) return; // já ligadas
    // desliga: sai do grupo, e a que sobrar sozinha também
    try surfaces[index].object.put(memory, "group", .{ .string = "" });
    if (old_group.len > 0) {
        var rest: ?usize = null;
        var count: usize = 0;
        for (surfaces, 0..) |surface, j| if (std.mem.eql(u8, groupOf(surface), old_group)) {
            rest = j;
            count += 1;
        };
        if (count == 1) try surfaces[rest.?].object.put(memory, "group", .{ .string = "" });
    }
    const j = target orelse return;
    var group = groupOf(surfaces[j]);
    if (group.len == 0) { // um id novo: o primeiro "gN" que ninguém usa
        var number: usize = 1;
        while (true) : (number += 1) {
            const candidate = try std.fmt.allocPrint(memory, "g{d}", .{number});
            var taken = false;
            for (surfaces) |surface| taken = taken or std.mem.eql(u8, groupOf(surface), candidate);
            if (!taken) {
                group = candidate;
                break;
            }
        }
        try surfaces[j].object.put(memory, "group", .{ .string = group });
    }
    try surfaces[index].object.put(memory, "group", .{ .string = group });
}

/// onde a superfície `index` pode se prender (`mount_choices`): solta, na ponta de cada tubo, na ponta de cada outra
/// superfície e, nas espelhadas e não verticais, em cada uma das duas pontas (cauda em H)
fn mountChoices(memory: std.mem.Allocator, aircraft: *const Aircraft, index: usize) ![]const []const u8 {
    var options: std.ArrayList([]const u8) = .empty;
    try options.append(memory, "solta");
    for (0..aircraft.booms.len) |i| try options.append(memory, try std.fmt.allocPrint(memory, "tubo:{d}", .{i}));
    for (aircraft.surfaces, 0..) |other, j| {
        if (j == index) continue;
        try options.append(memory, try std.fmt.allocPrint(memory, "ponta:{d}", .{j}));
        if (other.symmetric and !other.vertical) {
            try options.append(memory, try std.fmt.allocPrint(memory, "ponta_dir:{d}", .{j}));
            try options.append(memory, try std.fmt.allocPrint(memory, "ponta_esq:{d}", .{j}));
        }
    }
    const current = aircraft.surfaces[index].mount;
    if (current.len > 0 and !contains(options.items, current)) try options.append(memory, current);
    return options.items;
}

/// leva as superfícies presas (`mount`) para o ponto delas (`model.applyMounts`) e grava x, y e z no arquivo;
/// devolve verdadeiro se alguma mudou de lugar (então o avião precisa ser lido de novo)
pub fn placeMounted(memory: std.mem.Allocator, document: *std.json.Value, aircraft: *const Aircraft) !bool {
    const placed = try memory.dupe(model.Surface, aircraft.surfaces);
    model.applyMounts(aircraft, placed);
    const surfaces = try listNode(memory, document, "surfaces");
    var moved = false;
    for (placed, aircraft.surfaces, 0..) |after, before, i| {
        if (after.x == before.x and after.y == before.y and after.z == before.z) continue;
        if (i >= surfaces.items.len or surfaces.items[i] != .object) continue;
        const object = &surfaces.items[i].object;
        try object.put(memory, "x", .{ .float = after.x });
        try object.put(memory, "y", .{ .float = after.y });
        try object.put(memory, "z", .{ .float = after.z });
        moved = true;
    }
    return moved;
}

/// uma lista da peça que o editor mostra item a item, com "+" e "−" (o `_list_editor` do Python)
pub const EditableList = struct { key: []const u8, item: []const u8 };

/// o formulário inteiro da peça: os campos simples (bloco 0), o perfil e as listas, um bloco por item
pub const Layout = struct {
    specs: []Spec,
    groups: []const []const u8, // o título de cada bloco ("" no 0: quem desenha põe o nome da peça)
    lists: []const EditableList,
};

/// os blocos de uma lista (`items`) da peça: um por item, com o título "seção 1", "seção 2"...
fn listBlocks(memory: std.mem.Allocator, fields: *std.ArrayList(Spec), groups: *std.ArrayList([]const u8), lists: *std.ArrayList(EditableList), items: anytype, key: []const u8, item: []const u8, exclude: []const []const u8, kinds: ?[]const []const u8) !void {
    try lists.append(memory, .{ .key = key, .item = item });
    for (items, 0..) |entry, i| {
        try groups.append(memory, try std.fmt.allocPrint(memory, "{s} {d}", .{ item, i + 1 }));
        try itemFieldsOf(memory, fields, entry, exclude, .{ .name = "", .label = "", .kind = .number, .container = key, .target = i, .group = groups.items.len - 1 }, kinds);
    }
}

/// o formulário da peça: `specs` mais o perfil, as seções e os comandos (superfície), as pernas (trem "custom"), as
/// massas pontuais (massa) e os eventos (percurso), como os editores do Python (`_edit`)
pub fn layout(memory: std.mem.Allocator, aircraft: *const Aircraft, component: Component) !Layout {
    var fields: std.ArrayList(Spec) = .empty;
    try fields.appendSlice(memory, try specs(memory, aircraft, component));
    var groups: std.ArrayList([]const u8) = .empty;
    try groups.append(memory, "");
    var lists: std.ArrayList(EditableList) = .empty;
    switch (component.part) {
        .surface => {
            const surface = aircraft.surfaces[component.index];
            try groups.append(memory, "perfil");
            try itemFieldsOf(memory, &fields, surface.airfoil, &.{ "coords", "path" }, .{ .name = "", .label = "", .kind = .number, .container = "airfoil", .group = groups.items.len - 1 }, null);
            try listBlocks(memory, &fields, &groups, &lists, surface.sections, "sections", "seção", &.{}, null);
            try listBlocks(memory, &fields, &groups, &lists, surface.controls, "controls", "comando", &.{}, &form_meta.control_kinds);
            if (!surface.vertical) try listBlocks(memory, &fields, &groups, &lists, surface.devices, "devices", "dispositivo", &.{}, &form_meta.device_kinds);
        },
        .prop => {
            // o modelo de tração (`_propulsion_choice`): motor, hélice e bateria, ou o polinômio do conjunto
            const unit = aircraft.propulsion[component.index];
            for (fields.items) |*spec| if (std.mem.eql(u8, spec.name, "thrust_model")) {
                spec.kind = .choice;
                spec.label = "modelo de tração";
                spec.choices = &form_meta.thrust_models;
            };
            const nested = .{ "motor", "propeller", "battery" };
            const titles = .{ "motor", "hélice", "bateria" };
            if (std.mem.eql(u8, unit.thrust_model, "poly")) {
                try groups.append(memory, "polinômio de tração");
                const start = fields.items.len;
                try itemFieldsOf(memory, &fields, unit.thrust_poly, &.{ "coefs", "name" }, .{ .name = "", .label = "", .kind = .number, .container = "thrust_poly", .group = groups.items.len - 1 }, null);
                for (fields.items[start..]) |*spec| if (std.mem.eql(u8, spec.name, "x_var") or std.mem.eql(u8, spec.name, "y_var")) {
                    spec.kind = .choice;
                    spec.choices = &form_meta.poly_variables;
                };
                // a tabela dos coeficientes (`POLY_TERMS`): um campo por termo, o que falta no arquivo vale 0
                try groups.append(memory, "coeficientes do polinômio");
                for (poly_terms, 0..) |term, k| try fields.append(memory, .{
                    .name = term,
                    .label = term,
                    .kind = .number,
                    .number = if (k < unit.thrust_poly.coefs.len) unit.thrust_poly.coefs[k] else 0,
                    .container = "thrust_poly",
                    .target = k,
                    .group = groups.items.len - 1,
                });
            } else inline for (nested, titles) |key, title| {
                try groups.append(memory, title);
                try itemFieldsOf(memory, &fields, @field(unit, key), &.{ "J", "CT", "CP" }, .{ .name = "", .label = "", .kind = .number, .container = key, .group = groups.items.len - 1 }, null);
            }
        },
        .payload => {
            // a soltura (`_drop_editor`): o evento "drop" do percurso, com a perna e a distância nela
            try groups.append(memory, "soltura (evento do percurso)");
            const group = groups.items.len - 1;
            var drop: ?model.MissionEvent = null;
            for (aircraft.mission.events) |event| if (drop == null and std.mem.eql(u8, event.kind, "drop")) {
                drop = event;
            };
            var legs: std.ArrayList([]const u8) = .empty;
            for (aircraft.mission.legs, 0..) |leg, i| try legs.append(memory, try std.fmt.allocPrint(memory, "{d}: {s}", .{ i, leg.name }));
            if (legs.items.len == 0) try legs.append(memory, "0: perna");
            const leg_index: usize = if (drop) |event| @intCast(std.math.clamp(event.leg, 0, @as(i64, @intCast(legs.items.len - 1)))) else 0;
            try fields.append(memory, .{ .name = drop_on, .label = "soltar a carga nesta missão", .kind = .toggle, .checked = drop != null, .group = group });
            try fields.append(memory, .{ .name = drop_leg, .label = "perna", .kind = .choice, .choices = legs.items, .text = legs.items[leg_index], .group = group });
            try fields.append(memory, .{ .name = drop_distance, .label = "distância na perna", .unit = "m", .kind = .number, .number = if (drop) |event| event.s else 0, .group = group });
        },
        .gear => if (std.mem.eql(u8, aircraft.gear.layout, "custom"))
            try listBlocks(memory, &fields, &groups, &lists, aircraft.gear.custom, "custom", "perna", &.{}, &form_meta.gear_kinds),
        .mass => try listBlocks(memory, &fields, &groups, &lists, aircraft.mass.items, "items", "massa pontual", &.{}, null),
        .mission => try listBlocks(memory, &fields, &groups, &lists, aircraft.mission.events, "events", "evento", &.{}, &form_meta.event_kinds),
        else => {},
    }
    return .{ .specs = fields.items, .groups = groups.items, .lists = lists.items };
}

/// a lista `key` da peça no arquivo (criada vazia se não há)
fn itemList(memory: std.mem.Allocator, document: *std.json.Value, component: Component, key: []const u8) !*std.json.Array {
    const node = try partNode(memory, document, component);
    const entry = try node.getOrPut(memory, key);
    if (!entry.found_existing or entry.value_ptr.* != .array) entry.value_ptr.* = .{ .array = std.json.Array.init(memory) };
    return &entry.value_ptr.array;
}

/// "+" de uma lista: um item novo, cópia do último (a seção nova 0,2 m além dele, para as seções não coincidirem);
/// a lista vazia ganha um item com os valores padrão
pub fn addItem(memory: std.mem.Allocator, document: *std.json.Value, aircraft: *const Aircraft, component: Component, key: []const u8) !void {
    const items = try itemList(memory, document, component, key);
    if (std.mem.eql(u8, key, "devices") and component.part == .surface) { // um winglet desligado, de altura 10 % da envergadura
        const surface = aircraft.surfaces[component.index];
        const span = if (surface.symmetric) 2 * model.semispan(&surface) else model.semispan(&surface);
        const height = @round(1000 * 0.1 * @max(span, 0.5)) / 1000;
        return items.append(try literal(memory, "{{\"kind\":\"winglet\",\"height\":{d},\"enabled\":false}}", .{height}));
    }
    if (items.items.len == 0 or items.items[items.items.len - 1] != .object) return items.append(.{ .object = .empty });
    var copy = try clone(memory, items.items[items.items.len - 1]);
    if (std.mem.eql(u8, key, "sections")) try copy.object.put(memory, "y", .{ .float = numberOf(copy.object, "y") + 0.2 });
    try items.append(copy);
}

/// "−" de uma lista: tira o último item; falso se a lista já está vazia
pub fn removeItem(memory: std.mem.Allocator, document: *std.json.Value, component: Component, key: []const u8) !bool {
    const items = try itemList(memory, document, component, key);
    if (items.items.len == 0) return false;
    _ = items.pop();
    return true;
}

/// o nó do avião no arquivo (a chave "aeronave" dos arquivos da sprint, ou a raiz)
fn aircraftNode(document: *std.json.Value) !*std.json.ObjectMap {
    if (document.* != .object) return error.NoAircraft;
    if (document.object.getPtr("aeronave")) |node| if (node.* == .object) return &node.object;
    return &document.object;
}

/// o objeto da peça no arquivo (criado vazio se o arquivo não tem a chave)
fn partNode(memory: std.mem.Allocator, document: *std.json.Value, component: Component) !*std.json.ObjectMap {
    const node = try aircraftNode(document);
    const list_key: ?[]const u8 = switch (component.part) {
        .surface => "surfaces",
        .prop => "propulsion",
        .tank => "tanks",
        .boom => if (node.get("booms")) |found| (if (found == .array and found.array.items.len > 0) "booms" else null) else null,
        else => null,
    };
    if (list_key) |key| {
        const items = node.getPtr(key) orelse return error.MissingPart;
        if (items.* != .array or component.index >= items.array.items.len) return error.MissingPart;
        const item = &items.array.items[component.index];
        if (item.* != .object) return error.MissingPart;
        return &item.object;
    }
    const key = if (component.part == .boom) "boom" else @tagName(component.part);
    const entry = try node.getOrPut(memory, key);
    if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
    return &entry.value_ptr.object;
}

/// grava os valores dos campos no arquivo (a árvore JSON, que guarda também o que o modelo do Zig não lê); a
/// altitude-densidade grava junto o ρ da atmosfera padrão, como `set_density_altitude`
pub fn apply(memory: std.mem.Allocator, document: *std.json.Value, component: Component, fields: []const Spec) !void {
    if (component.part == .modifiers) return applyModifiers(memory, document, fields);
    const part_node = try partNode(memory, document, component);
    if (component.part == .payload) try applyDrop(memory, document, fields);
    for (fields) |spec| {
        if (std.mem.startsWith(u8, spec.name, "soltura: ")) continue;
        if (component.part == .surface and std.mem.eql(u8, spec.name, linked_field)) {
            try linkWing(memory, document, component.index, spec.text);
            continue;
        }
        if (component.part == .prop and std.mem.eql(u8, spec.container, "thrust_poly") and spec.target != null) {
            try putCoefficient(memory, part_node, spec.target.?, spec.number);
            continue;
        }
        const node = try fieldNode(memory, part_node, spec);
        const value: std.json.Value = switch (spec.kind) {
            .number => .{ .float = spec.number },
            .optional_number => if (spec.automatic) .null else .{ .float = spec.number },
            .integer => .{ .integer = @intFromFloat(@round(spec.number)) },
            .toggle => .{ .bool = spec.checked },
            .choice, .text => .{ .string = try memory.dupe(u8, spec.text) },
        };
        try node.put(memory, spec.name, value);
        if (component.part == .environment and std.mem.eql(u8, spec.name, "density_altitude"))
            try node.put(memory, "rho", .{ .float = model.Environment.densityAt(spec.number) });
    }
}

/// os termos do polinômio de tração na ordem dos coeficientes (`POLY_TERMS` de `aerosim/model/catalog.py`): p_ij é
/// o termo x^i · y^j
pub const poly_terms = [_][]const u8{ "p00", "p10", "p01", "p20", "p11", "p02", "p30", "p21", "p12", "p03", "p40", "p31", "p22", "p13", "p04", "p50", "p41", "p32", "p23", "p14", "p05" };

/// grava o coeficiente `index` do polinômio de tração da peça (a lista cresce com zeros até ele, como no Python)
fn putCoefficient(memory: std.mem.Allocator, part_node: *std.json.ObjectMap, index: usize, value: f64) !void {
    const poly = try part_node.getOrPut(memory, "thrust_poly");
    if (!poly.found_existing or poly.value_ptr.* != .object) poly.value_ptr.* = .{ .object = .empty };
    const coefs = try poly.value_ptr.object.getOrPut(memory, "coefs");
    if (!coefs.found_existing or coefs.value_ptr.* != .array) coefs.value_ptr.* = .{ .array = std.json.Array.init(memory) };
    const list = &coefs.value_ptr.array;
    while (list.items.len < poly_terms.len) try list.append(.{ .float = 0 });
    list.items[index] = .{ .float = value };
}

/// o objeto onde o campo mora: o da peça, o objeto dentro dela (o perfil) ou o item da lista
fn fieldNode(memory: std.mem.Allocator, part_node: *std.json.ObjectMap, spec: Spec) !*std.json.ObjectMap {
    if (spec.container.len == 0) return part_node;
    const entry = try part_node.getOrPut(memory, spec.container);
    if (spec.target) |index| {
        if (entry.value_ptr.* != .array or index >= entry.value_ptr.array.items.len) return error.MissingPart;
        const item = &entry.value_ptr.array.items[index];
        if (item.* != .object) item.* = .{ .object = .empty };
        return &item.object;
    }
    if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
    return &entry.value_ptr.object;
}

/// liga e desliga os modificadores; o arquivo sem a lista ganha a do padrão (o efeito solo de McCormick)
fn applyModifiers(memory: std.mem.Allocator, document: *std.json.Value, fields: []const Spec) !void {
    const node = try aircraftNode(document);
    const entry = try node.getOrPut(memory, "modifiers");
    if (!entry.found_existing or entry.value_ptr.* != .array) {
        var item: std.json.ObjectMap = .empty;
        try item.put(memory, "kind", .{ .string = (model.Modifier{}).kind });
        try item.put(memory, "enabled", .{ .bool = true });
        var items = std.json.Array.init(memory);
        try items.append(.{ .object = item });
        entry.value_ptr.* = .{ .array = items };
    }
    const items = entry.value_ptr.array.items;
    for (fields) |spec| {
        const index = spec.target orelse continue;
        if (index >= items.len or items[index] != .object) continue;
        try items[index].object.put(memory, "enabled", .{ .bool = spec.checked });
    }
}

/// as peças que os botões "+" criam (`_add_wing`, `_add_tail`, `_add_motor`, `_add_boom`, `_add_tank`)
pub const NewPart = enum { wing, htail, vtail, motor, boom, tank };

/// a lista do arquivo onde mora cada tipo de peça que se acrescenta ou remove
fn listKey(part: Part) ?[]const u8 {
    return switch (part) {
        .surface => "surfaces",
        .prop => "propulsion",
        .tank => "tanks",
        .boom => "booms",
        else => null,
    };
}

/// a lista `key` do avião no arquivo (criada vazia se não há)
fn listNode(memory: std.mem.Allocator, document: *std.json.Value, key: []const u8) !*std.json.Array {
    const node = try aircraftNode(document);
    const entry = try node.getOrPut(memory, key);
    if (!entry.found_existing or entry.value_ptr.* != .array) entry.value_ptr.* = .{ .array = std.json.Array.init(memory) };
    return &entry.value_ptr.array;
}

/// uma cópia funda de um valor JSON (a peça copiada não divide memória com a original)
fn clone(memory: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .string => |text| .{ .string = try memory.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try memory.dupe(u8, text) },
        .array => |items| blk: {
            var copy = std.json.Array.init(memory);
            for (items.items) |item| try copy.append(try clone(memory, item));
            break :blk .{ .array = copy };
        },
        .object => |object| blk: {
            var copy: std.json.ObjectMap = .empty;
            var entries = object.iterator();
            while (entries.next()) |entry| try copy.put(memory, try memory.dupe(u8, entry.key_ptr.*), try clone(memory, entry.value_ptr.*));
            break :blk .{ .object = copy };
        },
        else => value,
    };
}

fn numberOf(object: std.json.ObjectMap, key: []const u8) f64 {
    const found = object.get(key) orelse return 0;
    return switch (found) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

/// acrescenta uma peça nova com os valores de partida do Python e devolve a linha dela na lista
pub fn add(memory: std.mem.Allocator, document: *std.json.Value, aircraft: *const Aircraft, new: NewPart) !Component {
    const key: []const u8 = switch (new) {
        .wing, .htail, .vtail => "surfaces",
        .motor => "propulsion",
        .boom => "booms",
        .tank => "tanks",
    };
    const items = try listNode(memory, document, key);
    const count = items.items.len;
    const old_boom = aircraft.boom;
    const tail_x = if (old_boom.enabled) old_boom.xEnd() + 0.2 else -0.9;
    var value: std.json.Value = undefined;
    switch (new) {
        .wing => value = try literal(memory, "{{\"name\":\"asa {d}\",\"role\":\"wing\",\"x\":0.1,\"z\":-0.1,\"incidence\":2.0,\"sections\":[{{\"y\":0.0,\"chord\":0.3}},{{\"y\":1.0,\"chord\":0.3}}],\"controls\":[{{\"kind\":\"aileron\",\"span_start\":0.6,\"span_end\":0.95,\"chord_frac\":0.25}}]}}", .{count}),
        .htail => value = try literal(memory, "{{\"name\":\"EH\",\"role\":\"htail\",\"x\":{d},\"sections\":[{{\"y\":0.0,\"chord\":0.2}},{{\"y\":0.4,\"chord\":0.2}}],\"incidence\":-1.0,\"airfoil\":{{\"name\":\"NACA 0012\"}},\"controls\":[{{\"kind\":\"elevator\",\"span_start\":0.0,\"span_end\":1.0,\"chord_frac\":0.35}}],\"eta\":0.9,\"downwash\":true}}", .{tail_x}),
        .vtail => value = try literal(memory, "{{\"name\":\"EV\",\"role\":\"vtail\",\"x\":{d},\"sections\":[{{\"y\":0.0,\"chord\":0.22}},{{\"y\":0.3,\"chord\":0.22}}],\"symmetric\":false,\"vertical\":true,\"airfoil\":{{\"name\":\"NACA 0012\"}},\"controls\":[{{\"kind\":\"rudder\",\"span_start\":0.0,\"span_end\":1.0,\"chord_frac\":0.35}}],\"eta\":0.9}}", .{tail_x}),
        .tank => value = try literal(memory, "{{\"name\":\"tanque {d}\",\"x\":0.05,\"y\":0.0,\"z\":0.0,\"side\":0.1,\"volume\":2.0,\"height\":0.08}}", .{count + 1}),
        .motor => {
            // a cópia do último motor (motor, hélice e bateria iguais), do outro lado e girando ao contrário
            if (count > 0 and items.items[count - 1] == .object) {
                value = try clone(memory, items.items[count - 1]);
                const base = items.items[count - 1].object;
                const side = numberOf(base, "y");
                try value.object.put(memory, "y", .{ .float = if (side != 0) -side else 0.5 });
                try value.object.put(memory, "sense", .{ .float = -(if (base.get("sense") != null) numberOf(base, "sense") else 1) });
            } else value = try literal(memory, "{{\"x\":0.5,\"y\":0.0,\"z\":0.0,\"sense\":1.0}}", .{});
            try value.object.put(memory, "name", .{ .string = try std.fmt.allocPrint(memory, "motor {d}", .{count + 1}) });
        },
        .boom => {
            // a cópia do último tubo, espelhada (o par do tubo duplo) ou ao lado
            if (count > 0 and items.items[count - 1] == .object) {
                value = try clone(memory, items.items[count - 1]);
                const base = items.items[count - 1].object;
                const side = numberOf(base, "y");
                const yaw = numberOf(base, "yaw");
                const mirrored = side != 0 or yaw != 0;
                try value.object.put(memory, "y", .{ .float = if (mirrored) -side else side + 0.3 });
                try value.object.put(memory, "yaw", .{ .float = if (mirrored) -yaw else yaw });
            } else value = try literal(memory, "{{\"enabled\":true,\"x_start\":-0.2,\"length\":0.8}}", .{});
            try value.object.put(memory, "name", .{ .string = try std.fmt.allocPrint(memory, "tubo {d}", .{count + 1}) });
        },
    }
    try items.append(value);
    return .{ .part = switch (new) {
        .wing, .htail, .vtail => .surface,
        .motor => .prop,
        .boom => .boom,
        .tank => .tank,
    }, .index = count, .label = "" };
}

/// um objeto JSON a partir do texto
fn literal(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, memory, try std.fmt.allocPrint(memory, format, args), .{});
}

/// remove a peça (`_remove`): as das listas saem do arquivo; a fuselagem e a LAPES só desligam. Uma asa que sai
/// do grupo deixa a última que sobra sozinha sem grupo; quem estava preso num tubo removido fica solto e os outros
/// tubos são renumerados. Devolve falso se a peça não se remove (os dados que não são geometria)
pub fn remove(memory: std.mem.Allocator, document: *std.json.Value, component: Component) !bool {
    const node = try aircraftNode(document);
    switch (component.part) {
        .fuselage, .payload => {
            const object = try partNode(memory, document, component);
            try object.put(memory, "enabled", .{ .bool = false });
            return true;
        },
        .surface, .prop, .tank, .boom => {},
        else => return false,
    }
    if (component.part == .boom and node.get("booms") == null) { // o tubo único do formato antigo: desliga
        const object = try partNode(memory, document, component);
        try object.put(memory, "enabled", .{ .bool = false });
        return true;
    }
    const items = try listNode(memory, document, listKey(component.part).?);
    if (component.index >= items.items.len) return false;
    const removed = items.orderedRemove(component.index);
    const surfaces = try listNode(memory, document, "surfaces");
    if (component.part == .surface and removed == .object) {
        const group = if (removed.object.get("group")) |found| (if (found == .string) found.string else "") else "";
        if (group.len > 0) {
            var rest: ?*std.json.ObjectMap = null;
            var count: usize = 0;
            for (surfaces.items) |*surface| if (surface.* == .object) {
                const other = surface.object.get("group") orelse continue;
                if (other == .string and std.mem.eql(u8, other.string, group)) {
                    rest = &surface.object;
                    count += 1;
                }
            };
            if (count == 1) try rest.?.put(memory, "group", .{ .string = "" });
        }
    }
    if (component.part == .boom) {
        for (surfaces.items) |*surface| if (surface.* == .object) {
            const mount = surface.object.get("mount") orelse continue;
            if (mount != .string or !std.mem.startsWith(u8, mount.string, "tubo:")) continue;
            const index = std.fmt.parseInt(usize, mount.string[5..], 10) catch continue;
            if (index == component.index) {
                try surface.object.put(memory, "mount", .{ .string = "" });
            } else if (index > component.index) {
                try surface.object.put(memory, "mount", .{ .string = try std.fmt.allocPrint(memory, "tubo:{d}", .{index - 1}) });
            }
        };
    }
    return true;
}

/// traz a peça `component` de outro arquivo (`source`): as das listas entram no fim da lista (uma superfície chega
/// solta e sem grupo, porque o tubo e as asas a que se prendia são do outro avião); as outras trocam a do avião
/// aberto. Devolve a linha dela na lista
pub fn importPart(memory: std.mem.Allocator, document: *std.json.Value, source: *std.json.Value, component: Component) !Component {
    const original = try partNode(memory, source, component);
    var copy = try clone(memory, .{ .object = original.* });
    if (listKey(component.part)) |key| {
        if (component.part == .surface) {
            try copy.object.put(memory, "group", .{ .string = "" });
            try copy.object.put(memory, "mount", .{ .string = "" });
        }
        const items = try listNode(memory, document, key);
        try items.append(copy);
        return .{ .part = component.part, .index = items.items.len - 1, .label = "" };
    }
    const node = try aircraftNode(document);
    try node.put(memory, if (component.part == .boom) "boom" else @tagName(component.part), copy);
    return .{ .part = component.part, .label = "" };
}

/// a linha da lista de uma peça do 3D pela chave dela no esqueleto ("surface:0", "prop:1", "fuselage", "gear"...)
pub fn componentOf(key: []const u8) ?Component {
    const colon = std.mem.indexOfScalar(u8, key, ':');
    const name = if (colon) |at| key[0..at] else key;
    const index = if (colon) |at| std.fmt.parseInt(usize, key[at + 1 ..], 10) catch return null else 0;
    const part = std.meta.stringToEnum(Part, name) orelse return null;
    return .{ .part = part, .index = index, .label = "" };
}

/// arrasta a peça `delta` metros (eixos do corpo): a posição dela no arquivo anda isso. A superfície espelhada e não
/// vertical fica no plano de simetria (só x e z); a fuselagem anda pelo nariz (x e z); o tubo, pelo início. Devolve
/// falso se a peça não se arrasta (o trem, os dados que não são geometria)
pub fn moveBy(memory: std.mem.Allocator, document: *std.json.Value, aircraft: *const Aircraft, component: Component, delta: [3]f64) !bool {
    const start: [3]f64, const keys: [3]?[]const u8 = switch (component.part) {
        .surface => blk: {
            const surface = aircraft.surfaces[component.index];
            break :blk .{ .{ surface.x, surface.y, surface.z }, .{ "x", if (surface.symmetric and !surface.vertical) null else "y", "z" } };
        },
        .prop => .{ .{ aircraft.propulsion[component.index].x, aircraft.propulsion[component.index].y, aircraft.propulsion[component.index].z }, .{ "x", "y", "z" } },
        .tank => .{ .{ aircraft.tanks[component.index].x, aircraft.tanks[component.index].y, aircraft.tanks[component.index].z }, .{ "x", "y", "z" } },
        .payload => .{ .{ aircraft.payload.x, aircraft.payload.y, aircraft.payload.z }, .{ "x", "y", "z" } },
        .ballast => .{ .{ aircraft.ballast.x, aircraft.ballast.y, aircraft.ballast.z }, .{ "x", "y", "z" } },
        .fuselage => .{ .{ aircraft.fuselage.x_nose, 0, aircraft.fuselage.z }, .{ "x_nose", null, "z" } },
        .boom => blk: {
            const listed = listedBooms(aircraft);
            if (component.index >= listed.len) return false;
            const boom = listed[component.index];
            break :blk .{ .{ boom.x_start, boom.y, boom.z }, .{ "x_start", "y", "z" } };
        },
        else => return false,
    };
    const node = try partNode(memory, document, component);
    for (keys, start, delta) |key, from, step| if (key) |name| try node.put(memory, name, .{ .float = from + step });
    return true;
}

/// grava o vento do ambiente (a caixa "Vento" da Montagem): a velocidade a 10 m (m/s) e de onde vem (graus)
pub fn setWind(memory: std.mem.Allocator, document: *std.json.Value, speed: f64, from: f64) !void {
    const environment = try partNode(memory, document, .{ .part = .environment, .label = "" });
    try environment.put(memory, "wind_speed", .{ .float = speed });
    try environment.put(memory, "wind_from", .{ .float = from });
}

/// dá ao avião o nome `name` (a variante nova: "nome (variante N)", como o Python)
pub fn rename(memory: std.mem.Allocator, document: *std.json.Value, name: []const u8) !void {
    const node = try aircraftNode(document);
    try node.put(memory, "name", .{ .string = try memory.dupe(u8, name) });
}

/// o texto do arquivo a gravar (indentado como o Python grava)
pub fn serialize(memory: std.mem.Allocator, document: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(memory, document, .{ .whitespace = .indent_2 });
}

test "a lista de componentes e o editor da asa, como no Python" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    const list = try components(memory, &loaded.ac);
    // a lista do Python (sem os ícones): asa, EH, EV, motor, tanque, fuselagem, LAPES, lastro, trem, modificadores e
    // os oito dados que não são geometria
    const expected = [_][]const u8{ "asa (wing)", "EH (htail)", "EV (vtail)", "motor 1", "tanque 1", "fuselagem", "LAPES: carga e soltura", "Lastro (desligado)", "trem de pouso (tricycle)", "Modificadores (1 ligado(s))" };
    for (expected, 0..) |text, i| try std.testing.expectEqualStrings(text, list[i].label);
    try std.testing.expectEqual(expected.len + nongeometric.len, list.len);
    // a asa: os campos do formulário do Python, na ordem
    const wing = try specs(memory, &loaded.ac, list[0]);
    const names = [_][]const u8{ "name", "role", "x", "y", "z", "dihedral", "incidence", "symmetric", "vertical", "oswald", "eta", "downwash", "enabled", "CLa", "CL0", "CLmax", "CD0", "Cmac", "eps0", "depsda", "mass", "mount", linked_field };
    try std.testing.expectEqual(names.len, wing.len);
    for (names, wing) |name, spec| try std.testing.expectEqualStrings(name, spec.name);
    try std.testing.expectEqualStrings("diedro", wing[5].label);
    try std.testing.expectEqual(@as(f64, 3), wing[5].number);
    try std.testing.expect(wing[13].automatic and !wing[14].automatic); // CLa auto, CL0 = 0,3
    try std.testing.expectEqual(@as(f64, 0.3), wing[14].number);

    // editar o diedro e pôr o CL0 em auto: o arquivo muda só nisso e lê de novo
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    const edited = try memory.dupe(Spec, wing);
    edited[5].number = 5;
    edited[14].automatic = true;
    try apply(memory, &document, list[0], edited);
    const text = try serialize(memory, document);
    var again = try model.parse(std.testing.allocator, text, &diagnosis);
    defer again.deinit();
    try std.testing.expectEqual(@as(f64, 5), again.ac.surfaces[0].dihedral);
    try std.testing.expect(again.ac.surfaces[0].CL0 == null);
    try std.testing.expectEqual(loaded.ac.surfaces[0].x, again.ac.surfaces[0].x);
    try std.testing.expectEqual(loaded.ac.surfaces[1].incidence, again.ac.surfaces[1].incidence);

    // a altitude-densidade grava o ρ junto
    const environment_at = for (list, 0..) |component, i| {
        if (component.part == .environment) break i;
    } else unreachable;
    const environment = try memory.dupe(Spec, try specs(memory, &again.ac, list[environment_at]));
    for (environment) |*spec| if (std.mem.eql(u8, spec.name, "density_altitude")) {
        spec.number = 1000;
    };
    try apply(memory, &document, list[environment_at], environment);
    var third = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer third.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1.1117), third.ac.environment.rho, 1e-4); // ISA a 1000 m

    // toda peça da lista abre e grava sem mudar o avião (o arquivo relido dá a mesma massa e o mesmo CG)
    for (list) |component| try apply(memory, &document, component, try specs(memory, &third.ac, component));
    var fourth = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer fourth.deinit();
    const before = params.dryMass(&third.ac);
    const after = params.dryMass(&fourth.ac);
    try std.testing.expectEqual(before.m, after.m);
    try std.testing.expectEqual(before.cg, after.cg);
    try std.testing.expectEqual(third.ac.environment.rho, fourth.ac.environment.rho);
}

test "acrescentar, remover e trazer peças de outro arquivo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    // um de cada: o arquivo relido tem as peças novas com os valores do Python
    for (std.enums.values(NewPart)) |new| _ = try add(memory, &document, &loaded.ac, new);
    var grown = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer grown.deinit();
    try std.testing.expectEqual(loaded.ac.surfaces.len + 3, grown.ac.surfaces.len);
    try std.testing.expectEqualStrings("asa 3", grown.ac.surfaces[3].name);
    try std.testing.expectEqual(@as(f64, 1.0), grown.ac.surfaces[3].sections[1].y);
    try std.testing.expectEqualStrings("rudder", grown.ac.surfaces[5].controls[0].kind);
    try std.testing.expectEqual(loaded.ac.propulsion.len + 1, grown.ac.propulsion.len);
    try std.testing.expectEqual(-loaded.ac.propulsion[0].sense, grown.ac.propulsion[1].sense);
    try std.testing.expectEqual(loaded.ac.propulsion[0].motor.Kv, grown.ac.propulsion[1].motor.Kv);
    try std.testing.expectEqual(@as(usize, 1), grown.ac.booms.len);
    try std.testing.expectEqualStrings("tanque 2", grown.ac.tanks[1].name);
    // remover a asa nova volta ao número de antes
    try std.testing.expect(try remove(memory, &document, .{ .part = .surface, .index = 3, .label = "" }));
    try std.testing.expect(!try remove(memory, &document, .{ .part = .environment, .label = "" }));
    // trazer a EH de outro avião
    const other_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Asa_voadora.json", memory, .limited(1 << 22));
    var other = try std.json.parseFromSliceLeaky(std.json.Value, memory, other_bytes, .{});
    var other_loaded = try model.parse(std.testing.allocator, other_bytes, &diagnosis);
    defer other_loaded.deinit();
    const imported = try importPart(memory, &document, &other, .{ .part = .surface, .index = 0, .label = "" });
    var final = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer final.deinit();
    try std.testing.expectEqual(loaded.ac.surfaces.len + 3, final.ac.surfaces.len);
    try std.testing.expectEqualStrings(other_loaded.ac.surfaces[0].name, final.ac.surfaces[imported.index].name);
    try std.testing.expectEqual(other_loaded.ac.surfaces[0].sections.len, final.ac.surfaces[imported.index].sections.len);
}

test "o editor da asa tem o perfil, as seções e os comandos, com + e −" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    const wing: Component = .{ .part = .surface, .index = 0, .label = "" };
    const form = try layout(memory, &loaded.ac, wing);
    // blocos: a peça, o perfil, as 2 seções e o aileron
    try std.testing.expectEqual(@as(usize, 2 + loaded.ac.surfaces[0].sections.len + loaded.ac.surfaces[0].controls.len + loaded.ac.surfaces[0].devices.len), form.groups.len);
    try std.testing.expectEqualStrings("seção 2", form.groups[3]);
    try std.testing.expectEqual(@as(usize, 3), form.lists.len);
    // a corda da ponta e o tipo do comando, gravados e lidos de novo
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    const edited = try memory.dupe(Spec, form.specs);
    for (edited) |*spec| {
        if (std.mem.eql(u8, spec.container, "sections") and spec.target == 1 and std.mem.eql(u8, spec.name, "chord")) spec.number = 0.25;
        if (std.mem.eql(u8, spec.container, "controls") and std.mem.eql(u8, spec.name, "kind")) {
            try std.testing.expectEqual(form_meta.control_kinds.len, spec.choices.len);
            spec.text = "flaperon";
        }
    }
    try apply(memory, &document, wing, edited);
    try addItem(memory, &document, &loaded.ac, wing, "sections");
    var again = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer again.deinit();
    const sections = again.ac.surfaces[0].sections;
    try std.testing.expectEqual(@as(f64, 0.25), sections[1].chord);
    try std.testing.expectEqual(@as(usize, 3), sections.len);
    try std.testing.expectApproxEqAbs(sections[1].y + 0.2, sections[2].y, 1e-12);
    try std.testing.expectEqualStrings("flaperon", again.ac.surfaces[0].controls[0].kind);
    try std.testing.expect(try removeItem(memory, &document, wing, "sections"));
    var third = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 2), third.ac.surfaces[0].sections.len);
}

test "presa em: a EH na ponta do tubo e a EV na ponta direita da EH, como no Python" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    const node = try aircraftNode(&document);
    try node.put(memory, "booms", try literal(memory, "[{{\"name\":\"tubo 1\",\"enabled\":true,\"x_start\":-0.2,\"length\":0.8,\"y\":0.0,\"z\":-0.02,\"pitch\":3.0,\"yaw\":0.0,\"diameter\":0.03}}]", .{}));
    const surfaces = node.getPtr("surfaces").?.array.items;
    try surfaces[1].object.put(memory, "mount", .{ .string = "tubo:0" });
    try surfaces[2].object.put(memory, "mount", .{ .string = "ponta_dir:1" });
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer loaded.deinit();
    try std.testing.expect(try placeMounted(memory, &document, &loaded.ac));
    var placed = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer placed.deinit();
    // `Aircraft.apply_constraints` no Python, no mesmo avião
    const expected = [_][3]f64{ .{ 0.135, 0.0, -0.12 }, .{ -0.7752968300536802, 0.0, -0.06186876499435508 }, .{ -0.7752968300536802, 0.4472135954999579, -0.06186876499435508 } };
    for (expected, placed.ac.surfaces) |point, surface| {
        try std.testing.expectApproxEqAbs(point[0], surface.x, 1e-12);
        try std.testing.expectApproxEqAbs(point[1], surface.y, 1e-12);
        try std.testing.expectApproxEqAbs(point[2], surface.z, 1e-12);
    }
    const options = try mountChoices(memory, &placed.ac, 2);
    try std.testing.expectEqualStrings("tubo:0", options[1]);
    try std.testing.expectEqualStrings("ponta_dir:1", options[6]); // solta, tubo:0, ponta:0 (e as duas pontas da asa), ponta:1
}

test "asas ligadas: ligar duas asas e desligar, como link_wings e unlink_wing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    const added = try add(memory, &document, &loaded.ac, .wing);
    var grown = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer grown.deinit();
    const wing = try memory.dupe(Spec, try specs(memory, &grown.ac, added));
    for (wing) |*spec| if (std.mem.eql(u8, spec.name, linked_field)) {
        try std.testing.expectEqualStrings("(nenhuma)", spec.text);
        spec.text = "asa";
    };
    try apply(memory, &document, added, wing);
    var linked = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer linked.deinit();
    try std.testing.expectEqualStrings("g1", linked.ac.surfaces[0].group);
    try std.testing.expectEqualStrings("g1", linked.ac.surfaces[3].group);
    const list = try components(memory, &linked.ac);
    try std.testing.expectEqualStrings("asa (wing) ligada a asa 3", list[0].label);
    for (wing) |*spec| if (std.mem.eql(u8, spec.name, linked_field)) {
        spec.text = "(nenhuma)";
    };
    try apply(memory, &document, added, wing);
    var alone = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer alone.deinit();
    try std.testing.expectEqualStrings("", alone.ac.surfaces[0].group);
    try std.testing.expectEqualStrings("", alone.ac.surfaces[3].group);
}

test "o motor mostra motor, hélice e bateria; a LAPES escreve a soltura no percurso" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    const motor: Component = .{ .part = .prop, .index = 0, .label = "" };
    const form = try layout(memory, &loaded.ac, motor);
    try std.testing.expectEqualStrings("hélice", form.groups[2]);
    const edited = try memory.dupe(Spec, form.specs);
    for (edited) |*spec| if (std.mem.eql(u8, spec.container, "propeller") and std.mem.eql(u8, spec.name, "D")) {
        spec.number = 0.4;
    };
    try apply(memory, &document, motor, edited);
    // a soltura na perna 1, a 30 m
    const payload: Component = .{ .part = .payload, .label = "" };
    const drop = try memory.dupe(Spec, (try layout(memory, &loaded.ac, payload)).specs);
    for (drop) |*spec| {
        if (std.mem.eql(u8, spec.name, drop_on)) spec.checked = true;
        if (std.mem.eql(u8, spec.name, drop_leg)) spec.text = spec.choices[@min(1, spec.choices.len - 1)];
        if (std.mem.eql(u8, spec.name, drop_distance)) spec.number = 30;
    }
    try apply(memory, &document, payload, drop);
    var again = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer again.deinit();
    try std.testing.expectEqual(@as(f64, 0.4), again.ac.propulsion[0].propeller.D);
    try std.testing.expectEqual(loaded.ac.propulsion[0].propeller.J.len, again.ac.propulsion[0].propeller.J.len); // a curva da hélice fica
    var drops: usize = 0;
    for (again.ac.mission.events) |event| if (std.mem.eql(u8, event.kind, "drop")) {
        drops += 1;
        try std.testing.expectEqual(@as(f64, 30), event.s);
    };
    try std.testing.expectEqual(@as(usize, 1), drops);
}

test "arrastar: a asa anda em x e z e fica no plano de simetria; a chave do 3D acha a peça" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Convencional_original.json", memory, .limited(1 << 22));
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{});
    const wing = componentOf("surface:0").?;
    try std.testing.expectEqual(Part.surface, wing.part);
    try std.testing.expect(componentOf("gear") != null and componentOf("nada:1") == null);
    try std.testing.expect(try moveBy(memory, &document, &loaded.ac, wing, .{ 0.1, 0.2, -0.05 }));
    try std.testing.expect(!try moveBy(memory, &document, &loaded.ac, componentOf("gear").?, .{ 0.1, 0, 0 }));
    var moved = try model.parse(std.testing.allocator, try serialize(memory, document), &diagnosis);
    defer moved.deinit();
    try std.testing.expectApproxEqAbs(loaded.ac.surfaces[0].x + 0.1, moved.ac.surfaces[0].x, 1e-12);
    try std.testing.expectEqual(loaded.ac.surfaces[0].y, moved.ac.surfaces[0].y);
    try std.testing.expectApproxEqAbs(loaded.ac.surfaces[0].z - 0.05, moved.ac.surfaces[0].z, 1e-12);
}

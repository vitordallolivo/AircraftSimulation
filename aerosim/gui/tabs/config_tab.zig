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

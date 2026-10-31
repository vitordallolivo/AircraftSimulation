//! Estabilidade → Estabilidade dinâmica: o avião em voo nivelado recebe uma rajada (vertical, lateral ou as duas) e a aba
//! mostra no tempo o ângulo de ataque, a derrapagem, o rolamento, o xCG e o ângulo do líquido de cada tanque. Com
//! tanques, voa duas vezes, com o líquido livre e travado, para ver o quanto o líquido muda a resposta.
//!
//! A conta é a do núcleo (`core/src/sim/gust.zig`, a dinâmica 6GDL com o pêndulo de Abramson nos tanques); aqui só se
//! monta o caso, se avança em fatias e se escreve o resultado.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const native = @import("native.zig");

const params_mod = aircraft_model.params;
const deg = 180.0 / std.math.pi;

pub const simulation = native.Simulation{
    .name = "estabilidade_dinamica",
    .title = "Estabilidade dinâmica",
    .area = "Estabilidade",
    .description = "O avião em voo nivelado recebe uma rajada 1 − cos (vertical, lateral ou as duas) e a resposta sai no " ++
        "tempo: ângulo de ataque, derrapagem, rolamento, o xCG e o ângulo do líquido de cada tanque. Com tanques, voa " ++
        "com o líquido livre e travado, para comparar. Tudo em Zig, no núcleo.",
    .specs = specs,
    .start = start,
    .advance = advance,
    .result = result,
};

const pilots = [_][]const u8{ "manche fixo", "piloto automático" };
const max_cases = 2;
const slice_seconds = 0.25; // de voo por fatia (poucos milissegundos de conta)

const plots = [_]native.Plot{
    .{ .key = "alpha", .title = "Ângulo de ataque", .xlabel = "t (s)", .ylabel = "α (°)" },
    .{ .key = "lateral", .title = "Derrapagem e rolamento", .xlabel = "t (s)", .ylabel = "°" },
    .{ .key = "load", .title = "Fator de carga", .xlabel = "t (s)", .ylabel = "n_z" },
    .{ .key = "xcg", .title = "xCG", .xlabel = "t (s)", .ylabel = "x_CG (% CMA)" },
    .{ .key = "liquid", .title = "Líquido", .xlabel = "t (s)", .ylabel = "ângulo (°)" },
};

fn cruise(aircraft: *const native.Aircraft) f64 {
    var speed: f64 = 0;
    for (aircraft.mission.legs) |leg| if (leg.V) |value| {
        speed = @max(speed, value);
    };
    return if (speed > 0) speed else aircraft.mission.V0;
}

/// a massa do avião como o arquivo descreve: a seca, a carga e o líquido dos tanques
fn totalMass(aircraft: *const native.Aircraft) f64 {
    var total = params_mod.dryMass(aircraft).m;
    if (aircraft.payload.enabled) total += aircraft.payload.mass;
    for (aircraft.tanks) |tank| total += tank.rho * tank.volume / 1000.0;
    return total;
}

fn specs(out: *native.Writer, aircraft: ?*const native.Aircraft, values: native.Values) anyerror!void {
    _ = values;
    const speed = if (aircraft) |plane| cruise(plane) else 15.0;
    const mass = if (aircraft) |plane| @round(totalMass(plane) * 1000.0) / 1000.0 else 0.0;
    const has_tanks = if (aircraft) |plane| plane.tanks.len > 0 else true;
    const params = [_]native.Param{
        .{ .key = "mass", .label = "massa total", .default = .{ .number = mass }, .minimum = 0, .unit = "kg", .group = "Massa", .help = "a do avião; acima dela, o que passa entra no CG (o MTOW, por exemplo)" },
        .{ .key = "V", .label = "velocidade", .default = .{ .number = speed }, .minimum = 3, .maximum = 80, .unit = "m/s", .group = "Voo" },
        .{ .key = "h", .label = "altura", .default = .{ .number = 50 }, .minimum = 5, .maximum = 3000, .unit = "m", .group = "Voo" },
        .{ .key = "pilot", .label = "comandos", .kind = .choice, .default = .{ .text = pilots[0] }, .choices = &pilots, .group = "Voo", .help = "manche fixo: os comandos ficam no equilíbrio (a resposta do avião); piloto automático: ele reage" },
        .{ .key = "up", .label = "rajada vertical", .default = .{ .number = 2 }, .minimum = -20, .maximum = 20, .unit = "m/s", .group = "Rajada", .help = "para cima é positivo" },
        .{ .key = "side", .label = "rajada lateral", .default = .{ .number = 0 }, .minimum = -20, .maximum = 20, .unit = "m/s", .group = "Rajada", .help = "positivo empurra para a direita" },
        .{ .key = "Tg", .label = "duração", .default = .{ .number = 1 }, .minimum = 0.05, .maximum = 20, .unit = "s", .group = "Rajada", .help = "a rajada 1 − cos sobe e desce neste tempo" },
        .{ .key = "tg", .label = "chega em", .default = .{ .number = 1 }, .minimum = 0, .maximum = 60, .unit = "s", .group = "Rajada" },
        .{ .key = "span", .label = "tempo máximo", .default = .{ .number = 30 }, .minimum = 1, .maximum = 120, .unit = "s", .group = "Rajada", .help = "o voo para antes, quando a resposta estabiliza" },
        .{ .key = "compare", .label = "comparar com o líquido travado", .kind = .bool, .default = .{ .toggle = has_tanks }, .group = "Líquido", .help = "voa de novo com o líquido parado nos tanques (mesma massa)" },
    };
    try native.writeSpecs(out, &params, &plots, simulation.description);
}

/// um voo: o caso, a instância do núcleo e o registro
const Flight = struct {
    case: core.gust.Case,
    instance: *core.runner.Instance,
    log: []core.types.LogRow,
    rows: usize = 0,
    started: bool = false,
    done: bool = false,
};

const State = struct {
    flights: [max_cases]Flight = undefined,
    count: usize = 0,
    current: usize = 0,
    mass: f64 = 0,
    alpha_trim: f64 = 0,
    mac: f64 = 0.3,
    mac_le: f64 = 0, // x do bordo de ataque da CMA (o 0 % da CMA)
    n_tanks: usize = 0,
};

fn start(run: *native.Run, values: native.Values) anyerror!void {
    const memory = run.memory();
    const state = try memory.create(State);
    state.* = .{};
    run.state = state;
    const aircraft = run.aircraft;
    const autopilot = std.mem.eql(u8, values.text("pilot", pilots[0]), pilots[1]);
    const base = core.gust.Case{
        .airspeed = values.number("V", cruise(aircraft)),
        .height = values.number("h", 50),
        .vertical = values.number("up", 2),
        .lateral = values.number("side", 0),
        .duration = values.number("Tg", 1),
        .start = values.number("tg", 1),
        .span = values.number("span", 30),
        .autopilot = autopilot,
    };
    state.n_tanks = aircraft.tanks.len;
    state.mac = params_mod.references(aircraft)[1];
    state.mac_le = params_mod.macLeadingEdge(aircraft);
    const compare = values.toggle("compare", true) and state.n_tanks > 0;
    state.count = if (compare) 2 else 1;
    for (state.flights[0..state.count], 0..) |*flight, k| {
        var case = base;
        case.liquid_free = k == 0;
        const instance = try memory.create(core.runner.Instance);
        instance.* = .{};
        var diagnosis: aircraft_model.aircraft.Diag = .{};
        _ = params_mod.setup(aircraft, instance, &diagnosis) catch |err| {
            run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
            return err;
        };
        state.mass = withMass(instance, values.number("mass", 0));
        const rows = @as(usize, @intFromFloat(@ceil(case.span / instance.p.dtlog))) + 16;
        flight.* = .{ .case = case, .instance = instance, .log = try memory.alloc(core.types.LogRow, rows) };
    }
}

/// a massa pedida (0 = a do avião): o que passa da do avião entra no CG; devolve a massa que voa
fn withMass(instance: *core.runner.Instance, wanted: f64) f64 {
    const params = &instance.p;
    const now = core.trim.Ctx.init(params, &instance.r.f);
    const extra = wanted - now.m;
    if (!(extra > 0)) return now.m;
    const center: [3]f64 = now.rcg;
    for (0..3) |i| params.r_dry[i] = (params.m_dry * params.r_dry[i] + extra * center[i]) / (params.m_dry + extra);
    params.m_dry += extra;
    return wanted;
}

fn advance(run: *native.Run) anyerror!bool {
    const state: *State = @ptrCast(@alignCast(run.state.?));
    if (state.current >= state.count) return true;
    const flight = &state.flights[state.current];
    if (!flight.started) {
        flight.started = true;
        core.gust.begin(flight.instance, flight.case) catch |err| {
            run.fail("o voo não começou ({s}): a velocidade dá para voar nivelado?", .{@errorName(err)});
            return err;
        };
    }
    flight.done = try core.gust.advance(flight.instance, flight.case, flight.log, &flight.rows, slice_seconds);
    const label: []const u8 = if (flight.case.liquid_free) "líquido livre" else "líquido travado";
    const fraction = @min(flight.instance.r.t / flight.case.span, 1.0);
    run.progress = @floatCast((@as(f64, @floatFromInt(state.current)) + fraction) / @as(f64, @floatFromInt(state.count)));
    run.say("{s}: t = {d:.1} s de {d:.0}", .{ label, flight.instance.r.t, flight.case.span });
    if (flight.done) state.current += 1;
    return state.current >= state.count;
}

/// uma coluna do registro de um voo, já na unidade do gráfico
fn column(memory: std.mem.Allocator, flight: *const Flight, comptime pick: fn (row: core.types.LogRow, first: core.types.LogRow) f64) ![]f64 {
    const values = try memory.alloc(f64, flight.rows);
    for (flight.log[0..flight.rows], 0..) |row, k| values[k] = pick(row, flight.log[0]);
    return values;
}

fn time(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.t;
}
fn alpha(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.alpha * deg;
}
fn beta(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.beta * deg;
}
fn bank(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.phi * deg;
}
fn load(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.nz;
}
/// o xCG em % da CMA a partir do bordo de ataque (como no resto da Estabilidade)
fn cgPercent(memory: std.mem.Allocator, flight: *const Flight, state: *const State) ![]f64 {
    const values = try memory.alloc(f64, flight.rows);
    for (flight.log[0..flight.rows], 0..) |row, k| values[k] = 100.0 * (state.mac_le - row.xcg) / state.mac;
    return values;
}

fn largest(values: []const f64, reference: f64) f64 {
    var peak: f64 = 0;
    for (values) |value| peak = @max(peak, @abs(value - reference));
    return peak;
}

fn result(run: *native.Run, out: *native.Writer) anyerror!void {
    const memory = run.memory();
    const state: *State = @ptrCast(@alignCast(run.state.?));
    const free = &state.flights[0];
    if (free.rows < 2) return error.NoRows;
    const t_free = try column(memory, free, time);
    const alpha_free = try column(memory, free, alpha);
    const cg_free = try cgPercent(memory, free, state);
    const alpha_trim = alpha_free[0];

    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(native.Check) = .empty;
    try summary.append(memory, .{ "massa (kg)", try std.fmt.allocPrint(memory, "{d:.2}", .{state.mass}) });
    try summary.append(memory, .{ "α de equilíbrio (°)", try std.fmt.allocPrint(memory, "{d:.2}", .{alpha_trim}) });

    const alpha_peak = largest(alpha_free, alpha_trim);
    const kinematic = std.math.atan(@abs(free.case.vertical) / free.case.airspeed) * deg;
    try checks.append(memory, .{ .status = .info, .item = "pico de Δα", .value = try std.fmt.allocPrint(memory, "{d:.2}°", .{alpha_peak}), .criterion = try std.fmt.allocPrint(memory, "atan(U/V) = {d:.2}°", .{kinematic}), .why = "a rajada vertical muda o ângulo de ataque; o avião arfa junto e o pico fica abaixo de atan(U/V)", .group = "rajada" });
    const back = @abs(alpha_free[alpha_free.len - 1] - alpha_trim);
    try checks.append(memory, .{
        .status = if (back < 0.5) .ok else .atencao,
        .item = "α volta ao equilíbrio",
        .value = try std.fmt.allocPrint(memory, "{d:.2}° no fim", .{back}),
        .criterion = "< 0,5°",
        .why = if (back < 0.5) "o curto período amortece a perturbação" else "o avião ainda oscila no fim: aumente o tempo de voo ou veja os modos na aba Avião montado",
        .group = "rajada",
    });
    const cg_swing = largest(cg_free, cg_free[0]);
    if (state.n_tanks > 0) {
        try checks.append(memory, .{ .status = .info, .item = "xCG", .value = try std.fmt.allocPrint(memory, "{d:.2} % CMA, anda até {d:.3} %", .{ cg_free[0], cg_swing }), .criterion = "líquido livre", .why = "o líquido que balança leva junto o CG", .group = "líquido" });
    } else try summary.append(memory, .{ "xCG (% CMA)", try std.fmt.allocPrint(memory, "{d:.2}", .{cg_free[0]}) });
    const settled = free.instance.r.t < free.case.span - 1e-6;
    try checks.append(memory, .{
        .status = if (settled) .ok else .atencao,
        .item = "estabilizou",
        .value = if (settled) try std.fmt.allocPrint(memory, "em t = {d:.1} s", .{free.instance.r.t}) else "não, até o tempo máximo",
        .criterion = "α, líquido e xCG parados por 1 s",
        .why = if (settled) "a resposta rápida acabou (a fugóide e a espiral, lentas, seguem)" else "o avião ainda oscila ou diverge: veja os modos na aba Avião montado ou ligue o piloto automático",
        .group = "rajada",
    });

    // o líquido de cada tanque (só no voo livre: travado fica parado)
    const palette = [_][]const u8{ "#17becf", "#8c564b", "#e377c2", "#7f7f7f", "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e" };
    var liquid: std.ArrayList(native.Curve) = .empty;
    for (0..@min(state.n_tanks, core.limits.max_tanks)) |i| {
        const pitch_swing = try memory.alloc(f64, free.rows);
        const roll_swing = try memory.alloc(f64, free.rows);
        var peak: f64 = 0;
        for (free.log[0..free.rows], 0..) |row, k| {
            pitch_swing[k] = row.slosh_x[i] * deg;
            roll_swing[k] = row.slosh_y[i] * deg;
            peak = @max(peak, @max(@abs(pitch_swing[k] - pitch_swing[0]), @abs(roll_swing[k] - roll_swing[0])));
        }
        const name = run.aircraft.tanks[i].name;
        try liquid.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}: frente-trás", .{name}), .x = t_free, .y = pitch_swing, .color = palette[i % palette.len] });
        try liquid.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}: lado", .{name}), .x = t_free, .y = roll_swing, .color = palette[i % palette.len], .dashed = true });
        try checks.append(memory, .{ .status = .info, .item = try std.fmt.allocPrint(memory, "ângulo do líquido: {s}", .{name}), .value = try std.fmt.allocPrint(memory, "{d:.1}°", .{peak}), .criterion = "maior desvio do repouso", .why = "pêndulo equivalente (Abramson, NASA SP-106)", .group = "líquido" });
    }

    try native.beginResult(out, summary.items, checks.items);
    const flights = state.flights[0..state.count];
    var curves: std.ArrayList(native.Curve) = .empty;
    try curves.ensureTotalCapacity(memory, 2 * flights.len);
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, time), .y = try column(memory, flight, alpha), .color = "#1f77b4", .dashed = !flight.case.liquid_free });
    try native.writePlot(out, plots[0], curves.items, true);
    curves.clearRetainingCapacity();
    for (flights) |*flight| {
        const t = try column(memory, flight, time);
        curves.appendAssumeCapacity(.{ .name = try std.fmt.allocPrint(memory, "β {s}", .{caseName(flight)}), .x = t, .y = try column(memory, flight, beta), .color = "#d62728", .dashed = !flight.case.liquid_free });
        curves.appendAssumeCapacity(.{ .name = try std.fmt.allocPrint(memory, "φ {s}", .{caseName(flight)}), .x = t, .y = try column(memory, flight, bank), .color = "#2ca02c", .dashed = !flight.case.liquid_free });
    }
    try native.writePlot(out, plots[1], curves.items, false);
    curves.clearRetainingCapacity();
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, time), .y = try column(memory, flight, load), .color = "#ff7f0e", .dashed = !flight.case.liquid_free });
    try native.writePlot(out, plots[2], curves.items, false);
    curves.clearRetainingCapacity();
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, time), .y = try cgPercent(memory, flight, state), .color = "#9467bd", .dashed = !flight.case.liquid_free });
    try native.writePlot(out, plots[3], curves.items, false);
    if (liquid.items.len > 0) try native.writePlot(out, plots[4], liquid.items, false);
    try native.endResult(out);
}

fn caseName(flight: *const Flight) []const u8 {
    return if (flight.case.liquid_free) "líquido livre" else "líquido travado";
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "campos e resultado no JSON da ponte; o líquido livre mexe o xCG e o travado não" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/S1223_monomotor_EH_convencional_Joinville.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    try testing.expect(loaded.ac.tanks.len > 0);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try specs(&text.writer, &loaded.ac, .{});
    const form = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer form.deinit();
    try testing.expectEqual(@as(usize, 10), form.value.object.get("params").?.array.items.len);

    var run = native.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    const values = native.Values.fromRequest(run.memory(), "\"op\": \"run\", \"values\": {\"span\": 4, \"up\": 3}");
    try start(&run, values);
    var slices: usize = 0;
    while (!try advance(&run)) slices += 1;
    try testing.expect(slices > 4); // andou em fatias
    text.clearRetainingCapacity();
    try result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    const charts = outcome.value.object.get("plots").?.array.items;
    try testing.expectEqual(@as(usize, 5), charts.len);
    const xcg = charts[3].object.get("curves").?.array.items;
    try testing.expectEqual(@as(usize, 2), xcg.len); // livre e travado
    const free_cg = xcg[0].object.get("y").?.array.items;
    const locked_cg = xcg[1].object.get("y").?.array.items;
    var free_moves: f64 = 0;
    var locked_moves: f64 = 0;
    for (free_cg) |value| free_moves = @max(free_moves, @abs(jsonNumber(value) - jsonNumber(free_cg[0])));
    for (locked_cg) |value| locked_moves = @max(locked_moves, @abs(jsonNumber(value) - jsonNumber(locked_cg[0])));
    try testing.expect(free_moves > 1e-4); // % CMA
    try testing.expect(locked_moves < 1e-9);
    // o CG em % da CMA bate com o da Estabilidade em Python (27,5 % no S1223 com a carga e o líquido)
    try testing.expectApproxEqAbs(@as(f64, 27.5), jsonNumber(free_cg[0]), 0.6);
}

fn jsonNumber(value: std.json.Value) f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

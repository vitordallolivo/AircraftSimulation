//! Desempenho do avião montado em Zig (o par de `performance.py`): os cálculos da planilha de desempenho, sem
//! simulação e sem piloto. A polar parabólica C_D = C_D0 + K C_L² sai do avião inteiro no núcleo e a tração
//! disponível T(V) das unidades propulsoras a todo acelerador; com isso o núcleo (`core/src/sim/simple_perf.zig`)
//! dá, por altitude (ISA), as potências, a subida, o planeio, os raios de curva, o V-n e a bateria (Peukert). Aqui
//! se monta a configuração, se varre o envelope de voo até o teto e se escrevem as curvas inteiras, com a área
//! segura sombreada, como na planilha.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");

const params_mod = aircraft_model.params;
const simple_perf = core.simple_perf;
const deg = 180.0 / std.math.pi;
const rad = std.math.pi / 180.0;
const g0 = 9.80665;

/// a análise, com a interface de `simulation.check`
pub const Performance = struct {
    pub const name: []const u8 = "performance";
    pub const title: [:0]const u8 = "Desempenho";
    pub const area: []const u8 = "Desempenho";
    pub const description: []const u8 = "Cálculos da planilha (sem simulação, sem piloto): envelope de voo, potências, " ++
        "subida, planeio, envelope de curvas, V-n e bateria — curvas inteiras e a área segura sombreada.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
};

const altitude_colors = [_][]const u8{ "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b" };
const banks_deg = [_]f64{ 5, 10, 15, 20, 25, 30, 35, 40 };
const bank_colors = [_][]const u8{ "#4472c4", "#ed7d31", "#a5a5a5", "#ffc000", "#5b9bd5", "#70ad47", "#264478", "#9e480e" };
const safe_color = "#2ca02c";
const black = "#000000";

/// os gráficos, na ordem da tela
const Chart = enum { envelope, power, thrust, climb, climb_angle, glide, turns, vn, endurance, range };
const plots = std.EnumArray(Chart, simulation.Plot).init(.{
    .envelope = .{ .key = "env", .title = "Envelope de voo", .xlabel = "V (m/s)", .ylabel = "h (m)" },
    .power = .{ .key = "spot", .title = "Potência", .xlabel = "V (m/s)", .ylabel = "P (W)" },
    .thrust = .{ .key = "stra", .title = "Tração", .xlabel = "V (m/s)", .ylabel = "T (N)" },
    .climb = .{ .key = "ssub", .title = "Razão de subida", .xlabel = "V (m/s)", .ylabel = "RC (m/s)" },
    .climb_angle = .{ .key = "sgam", .title = "Ângulo de subida", .xlabel = "V (m/s)", .ylabel = "γ (°)" },
    .glide = .{ .key = "sdes", .title = "Planeio", .xlabel = "V de planeio (m/s)", .ylabel = "R_s (m/s)" },
    .turns = .{ .key = "scur", .title = "Envelope de curvas", .xlabel = "R (m)", .ylabel = "V (m/s)" },
    .vn = .{ .key = "snv", .title = "Diagrama V-n", .xlabel = "V (m/s)", .ylabel = "n" },
    .endurance = .{ .key = "sbat", .title = "Autonomia da bateria", .xlabel = "V (m/s)", .ylabel = "t (min)" },
    .range = .{ .key = "sran", .title = "Alcance da bateria", .xlabel = "V (m/s)", .ylabel = "alcance (km)" },
});

const max_altitudes = 6;
pub const polar_speed = 12.0; // a velocidade da polar do núcleo (m/s), como `core_polar`
const top_speed = 35.0; // a maior V das curvas (m/s)
const envelope_step = 50.0; // o passo do envelope de voo (m)
const envelope_top = 9000.0;

/// as curvas numa altitude
const Altitude = struct {
    height: f64,
    rows: []simple_perf.SimpleRow,
    summary: simple_perf.SimpleSummary,
};

/// o envelope de voo, uma linha por altitude até o teto
const Envelope = struct {
    heights: std.ArrayList(f64) = .empty,
    min_speed: std.ArrayList(f64) = .empty, // V_min (P_d = P_r)
    max_speed: std.ArrayList(f64) = .empty,
    stall: std.ArrayList(f64) = .empty, // V_e
    maneuver: std.ArrayList(f64) = .empty, // V* = V_e √n
    cruise: std.ArrayList(f64) = .empty, // V de L/D máximo
    ceiling: ?f64 = null,
};

/// a polar parabólica do avião inteiro
const Polar = struct { CD0: f64, K: f64, CLmax: f64 };

const RunState = struct {
    polar: Polar = .{ .CD0 = 0, .K = 0, .CLmax = 0 },
    mass: f64 = 0,
    area: f64 = 0,
    load_factor: f64 = 2,
    bank_limit_deg: f64 = 30, // o φ máximo do piloto
    envelope: Envelope = .{},
    altitudes: []Altitude = &.{},
};

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    _ = values;
    // a primeira altitude é a altitude-densidade do avião (o ar do dia)
    var buffer: [64]u8 = undefined;
    const heights: []const u8 = if (aircraft) |plane| blk: {
        const density_altitude = @round(plane.environment.densityAltitude());
        break :blk std.fmt.bufPrint(&buffer, "{d}, {d}", .{ density_altitude, density_altitude + 900 }) catch "0, 900";
    } else "0, 900";
    const params = [_]simulation.Param{
        .{ .key = "h_list", .label = if (aircraft != null) "Altitudes dos gráficos (a 1ª = AD)" else "Altitudes dos gráficos", .kind = .floats, .default = .{ .text = heights }, .unit = "m", .help = "a primeira é a altitude-densidade da aeronave (Montagem → Ambiente)" },
        .{ .key = "mass", .label = "Massa (0 = da aeronave)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 1000, .unit = "kg" },
        .{ .key = "bat_n", .label = "Bateria: expoente de Peukert", .default = .{ .number = 1.05 }, .minimum = 1, .maximum = 1.6, .group = "Bateria" },
        .{ .key = "bat_eta", .label = "Bateria: rendimento total (motor, ESC, hélice)", .default = .{ .number = 0.6 }, .minimum = 0.05, .maximum = 1, .group = "Bateria" },
    };
    try simulation.writeSpecs(out, &params, plots.values[0..], Performance.description, .{});
}

/// C_D0, K e C_Lmax do avião inteiro pelo núcleo: C_L e C_D de −4° a 24° a 12 m/s e a reta de C_D contra C_L² de −2°
/// a 8° (como `core_polar` do Python), sem trimar
pub fn corePolar(params: *const core.types.Params, tc: core.trim.Ctx) Polar {
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var count: f64 = 0;
    var lift_max: f64 = -std.math.inf(f64);
    for (0..57) |i| {
        const alpha = (-4.0 + 0.5 * @as(f64, @floatFromInt(i))) * rad;
        const coefficients = core.aero.coeffs(params, polar_speed, alpha, 0, tc.rcg, .{ 0, 0, 0 });
        lift_max = @max(lift_max, coefficients.CL);
        if (alpha < -2 * rad - 1e-12 or alpha > 8 * rad + 1e-12) continue;
        const lift_squared = coefficients.CL * coefficients.CL;
        sx += lift_squared;
        sy += coefficients.CD;
        sxx += lift_squared * lift_squared;
        sxy += lift_squared * coefficients.CD;
        count += 1;
    }
    const slope = (count * sxy - sx * sy) / (count * sxx - sx * sx);
    return .{ .CD0 = (sy - slope * sx) / count, .K = slope, .CLmax = lift_max };
}

/// a configuração do núcleo sem a altitude: peso, polar, a tração somada das unidades ligadas e a bateria
fn baseConfig(instance: *core.runner.Instance, aircraft: *const simulation.Aircraft, state: *const RunState, values: simulation.Values) simple_perf.SimpleCfg {
    const params = &instance.p;
    var cfg: simple_perf.SimpleCfg = .{
        .W = state.mass * g0,
        .S = state.area,
        .CD0 = state.polar.CD0,
        .K = state.polar.K,
        .CLmax = state.polar.CLmax,
        .rho0 = aircraft.performance.rho0,
        .T0 = 288.15,
        .V_lo = 0.5,
        .V_hi = top_speed,
        .dV = 0.1,
        .n_load = state.load_factor,
        .bat_Rt = 1,
        .bat_n = values.number("bat_n", 1.05),
        .bat_eta = values.number("bat_eta", 0.6),
        .bat_C = 1,
        .bat_V = 1,
    };
    // a tração disponível: a soma das unidades a todo acelerador, de 0 a 36 m/s a cada 0,5 m/s (`thrust_curves`)
    const unit_count: usize = @intCast(params.n_prop);
    const points = @min(@as(usize, 73), simple_perf.max_pts);
    for (0..points) |k| {
        const speed = 0.5 * @as(f64, @floatFromInt(k));
        cfg.thr_V[k] = speed;
        var thrust: f64 = 0;
        for (params.prop[0..unit_count]) |*unit| thrust += core.propulsion.point(params, unit, speed, 1).T;
        cfg.thr_T[k] = thrust;
    }
    if (unit_count == 0) {
        cfg.thr_V[1] = top_speed;
        cfg.n_thr = 2;
    } else cfg.n_thr = @intCast(points);
    var tilt_sum: f64 = 0;
    var enabled: f64 = 0;
    var battery: ?aircraft_model.aircraft.Battery = null;
    for (aircraft.propulsion) |unit| {
        if (!unit.enabled) continue;
        tilt_sum += unit.tilt;
        enabled += 1;
        if (battery == null) battery = unit.battery;
    }
    if (enabled > 0) cfg.phi_T = tilt_sum / enabled * rad;
    if (battery) |pack| {
        cfg.bat_C = pack.capacity_mAh / 1000 * (if (aircraft.shared_battery) 1 else enabled);
        cfg.bat_V = pack.voc();
    }
    for (banks_deg, 0..) |bank, k| cfg.bank[k] = bank * rad;
    cfg.n_bank = banks_deg.len;
    return cfg;
}

/// quantas linhas o núcleo pode dar (uma por V, como o backend Python reserva)
fn rowCapacity(cfg: simple_perf.SimpleCfg) usize {
    return @as(usize, @intFromFloat((cfg.V_hi - cfg.V_lo) / cfg.dV)) + 2;
}

/// as linhas e o resumo do núcleo numa altitude
fn compute(memory: std.mem.Allocator, base: simple_perf.SimpleCfg, height: f64) !Altitude {
    var cfg = base;
    cfg.h = height;
    const rows = try memory.alloc(simple_perf.SimpleRow, rowCapacity(cfg));
    var summary: simple_perf.SimpleSummary = .{};
    const count = simple_perf.compute(&cfg, rows, &summary);
    return .{ .height = height, .rows = rows[0..count], .summary = summary };
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    const aircraft = run.aircraft;
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const info = params_mod.setup(aircraft, instance, &diagnosis) catch |err| {
        run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    state.polar = corePolar(&instance.p, core.trim.Ctx.init(&instance.p, &instance.r.f));
    const mass = values.number("mass", 0);
    state.mass = if (mass > 0) mass else info.mass;
    state.area = params_mod.references(aircraft)[0];
    state.load_factor = aircraft.performance.load_factor;
    state.bank_limit_deg = aircraft.autopilot.phimax;
    const base = baseConfig(instance, aircraft, state, values);
    run.progress = 0.2;

    // o envelope de voo: sobe de 50 em 50 m até o teto (nenhuma V com P_d ≥ P_r, ou V_max ≤ V_min)
    const scratch = try memory.alloc(simple_perf.SimpleRow, rowCapacity(base));
    var height: f64 = 0;
    while (height <= envelope_top + 1e-9) : (height += envelope_step) {
        var cfg = base;
        cfg.h = height;
        var summary: simple_perf.SimpleSummary = .{};
        _ = simple_perf.compute(&cfg, scratch, &summary);
        if (summary.ceiling_ok == 0 or summary.Vmax <= summary.Vmin) {
            state.envelope.ceiling = height;
            break;
        }
        const line = &state.envelope;
        try line.heights.append(memory, height);
        try line.min_speed.append(memory, summary.Vmin);
        try line.max_speed.append(memory, summary.Vmax);
        try line.stall.append(memory, summary.Vs);
        try line.maneuver.append(memory, summary.Vman);
        try line.cruise.append(memory, summary.V_LDmax);
    }
    run.progress = 0.6;

    var buffer: [max_altitudes]f64 = undefined;
    const density_altitude = @round(aircraft.environment.densityAltitude());
    const heights = values.numbers("h_list", &buffer, &.{ density_altitude, density_altitude + 900 });
    state.altitudes = try memory.alloc(Altitude, heights.len);
    for (heights, state.altitudes) |chosen, *altitude| altitude.* = try compute(memory, base, chosen);
    run.progress = 1;
}

fn advanceRun(_: *simulation.Run, _: *RunState) simulation.Error!bool {
    return true; // tudo sai no começo (o núcleo leva milissegundos por altitude)
}

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

/// as curvas e as retas de referência de um gráfico
const Lines = simulation.Figures.Figure;

/// o gráfico de `chart` entre os do resultado
fn figure(figures: simulation.Figures, chart: Chart) *Lines {
    return figures.get(plots.get(chart).key).?;
}

/// uma coluna das linhas, com NaN onde `shown` é falso
fn column(memory: std.mem.Allocator, rows: []const simple_perf.SimpleRow, comptime field: []const u8, shown: ?[]const bool) ![]f64 {
    const values = try memory.alloc(f64, rows.len);
    for (rows, values, 0..) |row, *value, k| value.* = if (shown == null or shown.?[k]) @field(row, field) else std.math.nan(f64);
    return values;
}

/// um ponto com estrela (o máximo de uma curva)
fn star(memory: std.mem.Allocator, label: []const u8, x: f64, y: f64, color: []const u8) !simulation.Curve {
    return .{ .name = label, .x = try memory.dupe(f64, &.{x}), .y = try memory.dupe(f64, &.{y}), .color = color, .marker = "star" };
}

fn maxOf(values: []const f64) f64 {
    var best = -std.math.inf(f64);
    for (values) |value| if (std.math.isFinite(value)) {
        best = @max(best, value);
    };
    return best;
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    const polar = state.polar;
    try summary.append(memory, .{ "polar", try text(memory, "núcleo: C_D0 = {d:.4}, K = {d:.4}, C_Lmax = {d:.2}", .{ polar.CD0, polar.K, polar.CLmax }) });
    try summary.append(memory, .{ "massa (kg)", try text(memory, "{d:.4}", .{state.mass}) });
    try summary.append(memory, .{ "S (m²)", try text(memory, "{d:.4}", .{state.area}) });
    try summary.append(memory, .{ "teto absoluto (m)", if (state.envelope.ceiling) |ceiling| try text(memory, "{d:.0}", .{ceiling}) else "> 9000" });

    const figures = try simulation.Figures.init(memory, plots.values[0..]);
    try envelopeChart(memory, state, figure(figures, .envelope));

    for (state.altitudes, 0..) |altitude, j| {
        const facts = altitude.summary;
        const prefix = try text(memory, "[h = {d} m] ", .{altitude.height});
        const entries = [_]struct { []const u8, []const u8, []const f64 }{
            .{ "ρ (kg/m³)", "{d:.4}", &.{facts.rho} },
            .{ "V_e, V*, V_cru (L/D máx.) (m/s)", "", &.{ facts.Vs, facts.Vman, facts.V_LDmax } },
            .{ "V_min, V_max (P_d = P_r) (m/s)", "", &.{ facts.Vmin, facts.Vmax } },
            .{ "RC máx. (m/s) @ V", "", &.{ facts.RCmax, facts.V_RCmax } },
            .{ "γ máx. (°)", "", &.{facts.gmax * deg} },
            .{ "E máx.; menor ângulo de planeio (°)", "", &.{ facts.Emax, facts.glide_min * deg } },
            .{ "menor razão de descida (m/s) @ V", "", &.{ facts.sink_min, facts.V_sink_min } },
            .{ "R mín. pela fórmula da planilha (m) @ V", "", &.{ facts.R_min, facts.V_Rmin } },
            .{ "autonomia máx. (min) @ V", "", &.{ 60 * facts.t_max, facts.V_tmax } },
            .{ "alcance máx. (km) @ V", "", &.{ facts.range_max / 1000, facts.V_range_max } },
        };
        for (entries) |entry| {
            var written: std.ArrayList(u8) = .empty;
            for (entry[2], 0..) |value, k| {
                if (k > 0) try written.appendSlice(memory, ", ");
                try written.print(memory, "{d:.4}", .{value});
            }
            try summary.append(memory, .{ try text(memory, "{s}{s}", .{ prefix, entry[0] }), written.items });
        }
        try altitudeChecks(memory, altitude, &checks);
        try altitudeCurves(memory, figures, altitude, j);
        if (j == 0) {
            try turnChart(memory, figure(figures, .turns), facts, state.bank_limit_deg);
            try vnChart(memory, figure(figures, .vn), altitude, state.load_factor);
        }
    }
    if (state.envelope.ceiling) |ceiling|
        try checks.append(memory, .{ .status = .info, .item = "teto absoluto", .value = try text(memory, "≈ {d:.0} m", .{ceiling}), .criterion = "V_min = V_max", .group = "envelope" });

    try simulation.beginResult(out, summary.items, checks.items);
    try figures.write(out, true);
    try simulation.endResult(out);
}

/// a faixa segura, V_min e V_max fechando no teto (o "domo" da planilha), V_e, V*, V_cru e o teto
fn envelopeChart(memory: std.mem.Allocator, state: *const RunState, lines: *Lines) !void {
    const line = &state.envelope;
    const count = line.heights.items.len;
    if (count == 0) return;
    var low: std.ArrayList(f64) = .empty;
    var high: std.ArrayList(f64) = .empty;
    var safe_heights: std.ArrayList(f64) = .empty;
    for (0..count) |k| {
        const lowest = @max(line.min_speed.items[k], line.stall.items[k]);
        const highest = @min(line.max_speed.items[k], line.maneuver.items[k]);
        if (highest <= lowest) continue;
        try low.append(memory, lowest);
        try high.append(memory, highest);
        try safe_heights.append(memory, line.heights.items[k]);
    }
    if (low.items.len > 0) try lines.curves.append(memory, .{ .name = "área segura", .x = low.items, .y = safe_heights.items, .fill_x = high.items, .color = safe_color });
    const last = count - 1;
    const middle = 0.5 * (line.min_speed.items[last] + line.max_speed.items[last]);
    const domed = try memory.alloc(f64, count + 1);
    @memcpy(domed[0..count], line.heights.items);
    domed[count] = line.heights.items[last] + 25;
    for ([_]struct { []const u8, []const f64, []const u8 }{ .{ "V_min", line.min_speed.items, "#4472c4" }, .{ "V_max", line.max_speed.items, "#c0504d" } }) |edge| {
        const speeds = try memory.alloc(f64, count + 1);
        @memcpy(speeds[0..count], edge[1]);
        speeds[count] = middle;
        try lines.curves.append(memory, .{ .name = edge[0], .x = speeds, .y = domed, .color = edge[2], .width = 2.2 });
    }
    try lines.curves.append(memory, .{ .name = "V_e", .x = line.stall.items, .y = line.heights.items, .color = "#9bbb59", .width = 2 });
    try lines.curves.append(memory, .{ .name = "V*", .x = line.maneuver.items, .y = line.heights.items, .color = "#8064a2", .width = 2 });
    try lines.curves.append(memory, .{ .name = "V_cru", .x = line.cruise.items, .y = line.heights.items, .color = "#4bacc6", .width = 2 });
    if (line.ceiling) |ceiling| try lines.guides.append(memory, .{ .name = try text(memory, "teto absoluto ≈ {d:.0} m", .{ceiling}), .value = ceiling, .vertical = false, .color = black, .dashed = true });
}

fn altitudeChecks(memory: std.mem.Allocator, altitude: Altitude, checks: *std.ArrayList(simulation.Check)) !void {
    const facts = altitude.summary;
    const group = try text(memory, "a {d} m", .{altitude.height});
    if (facts.ceiling_ok == 0) {
        try checks.append(memory, .{ .status = .falha, .item = try text(memory, "voo nivelado {s}", .{group}), .value = "P_d < P_r em todas as V", .criterion = "P_d ≥ P_r", .why = "a potência disponível não cobre a requerida em nenhuma velocidade", .fix = "mais tração, menos massa ou menos arrasto (C_D0)", .group = group });
        return;
    }
    const lowest = @max(facts.Vmin, facts.Vs);
    const highest = @min(facts.Vmax, facts.Vman);
    const band_ok = highest > lowest;
    try checks.append(memory, .{
        .status = if (band_ok) .ok else .falha,
        .item = try text(memory, "faixa segura de velocidades {s}", .{group}),
        .value = try text(memory, "{d:.1} a {d:.1} m/s", .{ lowest, highest }),
        .criterion = "max(V_min, V_e) < min(V_max, V*)",
        .why = if (band_ok) "" else "não sobra faixa entre o estol e a velocidade máxima/de manobra",
        .fix = if (band_ok) "" else "mais tração ou menos carga alar",
        .group = group,
    });
    const climbs = facts.RCmax > 0.5;
    try checks.append(memory, .{ .status = if (climbs) .ok else .atencao, .item = try text(memory, "razão de subida máxima {s}", .{group}), .value = try text(memory, "{d:.2} m/s", .{facts.RCmax}), .criterion = "> 0,5 m/s", .fix = if (climbs) "" else "mais potência ou menos arrasto", .group = group });
}

/// as curvas de uma altitude nos gráficos de potência, tração, subida, planeio e bateria
fn altitudeCurves(memory: std.mem.Allocator, figures: simulation.Figures, altitude: Altitude, j: usize) !void {
    const rows = altitude.rows;
    const facts = altitude.summary;
    const color = altitude_colors[j % altitude_colors.len];
    const label = try text(memory, "{d} m", .{altitude.height});
    const first = j == 0;
    const speeds = try column(memory, rows, "V", null);
    // só some o começo em que C_L → ∞ (V ≈ 0)
    const shown = try memory.alloc(bool, rows.len);
    for (rows, shown) |row, *visible| visible.* = row.V >= 0.3 * facts.Vs;
    // onde dá para voar nivelado: C_L ≤ C_Lmax e P_d ≥ P_r
    var band_start: ?usize = null;
    var band_end: usize = 0;
    for (rows, 0..) |row, k| if (row.ok > 0 and row.Pd >= row.Pr) {
        if (band_start == null) band_start = k;
        band_end = k + 1;
    };
    const power = figure(figures, .power);
    const thrust = figure(figures, .thrust);
    const climb = figure(figures, .climb);
    const climb_angle = figure(figures, .climb_angle);
    const glide = figure(figures, .glide);
    const endurance = figure(figures, .endurance);
    const range = figure(figures, .range);
    const available_power = try column(memory, rows, "Pd", null);
    const climb_rate = try column(memory, rows, "RC", shown);
    if (band_start) |start| {
        const band = speeds[start..band_end];
        const required_band = try column(memory, rows[start..band_end], "Pr", null);
        const climb_band = try column(memory, rows[start..band_end], "RC", null);
        try power.curves.append(memory, .{ .name = try text(memory, "sobra ({s})", .{label}), .x = band, .y = required_band, .fill = available_power[start..band_end], .color = safe_color, .legend = first });
        const zeros = try memory.alloc(f64, band.len);
        @memset(zeros, 0);
        try climb.curves.append(memory, .{ .name = try text(memory, "sobe ({s})", .{label}), .x = band, .y = zeros, .fill = climb_band, .color = safe_color, .legend = first });
        try endurance.curves.append(memory, .{ .name = try text(memory, "voo nivelado ({s})", .{label}), .x = try memory.dupe(f64, &.{ band[0], band[band.len - 1] }), .y = try memory.dupe(f64, &.{ 0, 0 }), .color = color, .vspan = true });
    }
    try power.curves.append(memory, .{ .name = try text(memory, "P_d ({s})", .{label}), .x = speeds, .y = available_power, .color = color, .width = 2 });
    try power.curves.append(memory, .{ .name = try text(memory, "P_r ({s})", .{label}), .x = speeds, .y = try column(memory, rows, "Pr", shown), .color = color, .dashed = true });
    const available_thrust = try column(memory, rows, "Td", null);
    try thrust.curves.append(memory, .{ .name = try text(memory, "T_d ({s})", .{label}), .x = speeds, .y = available_thrust, .color = color, .width = 2 });
    try thrust.curves.append(memory, .{ .name = try text(memory, "T_r ({s})", .{label}), .x = speeds, .y = try column(memory, rows, "Tr", shown), .color = color, .dashed = true });
    const last_speed = speeds[speeds.len - 1];
    if (first) { // a janela dos gráficos (as curvas ficam inteiras, fora dela também)
        const climb_top = @max(facts.RCmax, 0.5);
        const angle_top = @max(facts.gmax * deg, 2);
        power.plot.y_limits = .{ 0, 1.8 * maxOf(available_power) };
        thrust.plot.y_limits = .{ 0, 1.5 * maxOf(available_thrust) };
        climb.plot.y_limits = .{ -3 * climb_top, 1.6 * climb_top };
        climb_angle.plot.y_limits = .{ -3 * angle_top, 1.6 * angle_top };
        glide.plot.y_limits = .{ -4 * (facts.sink_min + 0.5), 0.3 };
        endurance.plot.y_limits = .{ 0, 1.5 * 60 * facts.t_max };
        range.plot.y_limits = .{ 0, 1.5 * facts.range_max / 1000 };
        for ([_]*Lines{ power, thrust, climb, climb_angle, glide, endurance, range }) |lines| lines.plot.x_limits = .{ 0, last_speed };
        try climb.guides.append(memory, .{ .name = "zero", .value = 0, .vertical = false, .color = black, .dashed = true, .legend = false });
    }
    try climb.curves.append(memory, .{ .name = try text(memory, "RC ({s})", .{label}), .x = speeds, .y = climb_rate, .color = color, .width = 2 });
    const angles = try memory.alloc(f64, rows.len);
    for (rows, angles, climb_rate) |row, *angle, rate| angle.* = if (std.math.isFinite(rate)) row.gam * deg else std.math.nan(f64);
    try climb_angle.curves.append(memory, .{ .name = try text(memory, "γ ({s})", .{label}), .x = speeds, .y = angles, .color = color, .width = 2 });
    for ([_]*Lines{ climb, climb_angle, power, thrust }) |lines|
        try lines.guides.append(memory, .{ .name = try text(memory, "V_e ({s})", .{label}), .value = facts.Vs, .vertical = true, .color = color, .dashed = true, .legend = false });
    try climb.curves.append(memory, try star(memory, try text(memory, "★ {d:.2} m/s ({s})", .{ facts.RCmax, label }), facts.V_RCmax, facts.RCmax, color));
    try climb_angle.curves.append(memory, try star(memory, try text(memory, "★ {d:.1}° ({s})", .{ facts.gmax * deg, label }), facts.V_gmax, facts.gmax * deg, color));

    // planeio (Figura 4.8): a razão de descida negativa contra a V de planeio, a curva inteira
    const glide_speed = try memory.alloc(f64, rows.len);
    const sink = try memory.alloc(f64, rows.len);
    for (rows, shown, glide_speed, sink) |row, visible, *speed, *rate| {
        const valid = visible and row.V_glide > 0;
        speed.* = if (valid) row.V_glide else std.math.nan(f64);
        rate.* = if (valid) -row.sink else std.math.nan(f64);
    }
    try glide.curves.append(memory, .{ .name = try text(memory, "R_s ({s})", .{label}), .x = glide_speed, .y = sink, .color = color, .width = 2 });
    try glide.guides.append(memory, .{ .name = try text(memory, "autonomia máx. ({s})", .{label}), .value = -facts.sink_min, .vertical = false, .color = color, .dashed = true });
    const tangent_end = 1.3 * facts.V_glide_min;
    const slope = @tan(facts.glide_min);
    try glide.curves.append(memory, .{ .name = try text(memory, "alcance máx. ({s})", .{label}), .x = try memory.dupe(f64, &.{ 0, tangent_end }), .y = try memory.dupe(f64, &.{ 0, -slope * tangent_end }), .color = black, .width = 1.4 });
    try glide.curves.append(memory, try star(memory, try text(memory, "★ {d:.1} m/s ({s})", .{ facts.V_glide_min, label }), facts.V_glide_min, -facts.V_glide_min * slope, color));

    // bateria: autonomia e alcance na potência requerida
    const minutes = try column(memory, rows, "t_bat", shown);
    for (minutes) |*value| value.* *= 60;
    const kilometers = try column(memory, rows, "range_bat", shown);
    for (kilometers) |*value| value.* /= 1000;
    try endurance.curves.append(memory, .{ .name = try text(memory, "autonomia ({s})", .{label}), .x = speeds, .y = minutes, .color = color, .width = 2 });
    try range.curves.append(memory, .{ .name = try text(memory, "alcance ({s})", .{label}), .x = speeds, .y = kilometers, .color = color, .width = 2 });
    try endurance.curves.append(memory, try star(memory, try text(memory, "★ {d:.1} min ({s})", .{ 60 * facts.t_max, label }), facts.V_tmax, 60 * facts.t_max, color));
    try range.curves.append(memory, try star(memory, try text(memory, "★ {d:.2} km ({s})", .{ facts.range_max / 1000, label }), facts.V_range_max, facts.range_max / 1000, color));
}

/// o envelope de curvas (Figura 4.7): V contra o raio R = V²/(g tan φ) para cada inclinação, com a área segura
/// entre V_e e V* e entre R(V*, φ máx. do piloto) e R(V*, 10°)
fn turnChart(memory: std.mem.Allocator, lines: *Lines, facts: simple_perf.SimpleSummary, bank_limit_deg: f64) !void {
    const stall = facts.Vs;
    const maneuver = facts.Vman;
    const point_count = 120;
    const top = 1.15 * maneuver;
    const largest_radius = 1.1 * maneuver * maneuver / (g0 * @tan((banks_deg[0] + 5) * rad));
    for (banks_deg, 0..) |bank, k| {
        var radii: std.ArrayList(f64) = .empty;
        var speeds: std.ArrayList(f64) = .empty;
        for (0..point_count) |i| {
            const speed = 0.5 + (top - 0.5) * @as(f64, @floatFromInt(i)) / (point_count - 1);
            const radius = speed * speed / (g0 * @tan(bank * rad));
            if (radius > largest_radius) continue;
            try radii.append(memory, radius);
            try speeds.append(memory, speed);
        }
        const load = 1 / @cos(bank * rad); // curva nivelada: n = 1/cos φ
        try lines.curves.append(memory, .{ .name = try text(memory, "{d}° (n = {d:.2})", .{ bank, load }), .x = radii.items, .y = speeds.items, .color = bank_colors[k % bank_colors.len], .width = 1.6 });
    }
    const tight = maneuver * maneuver / (g0 * @tan(bank_limit_deg * rad)); // φ máx. do piloto em V*
    const wide = maneuver * maneuver / (g0 * @tan(10 * rad)); // φ = 10° em V*
    try lines.curves.append(memory, .{ .name = "área segura", .x = try memory.dupe(f64, &.{ tight, wide }), .y = try memory.dupe(f64, &.{ stall, stall }), .fill = try memory.dupe(f64, &.{ maneuver, maneuver }), .color = safe_color });
    try lines.guides.append(memory, .{ .name = "V_min", .value = facts.Vmin, .vertical = false, .color = "#7f7f7f", .width = 2 });
    try lines.guides.append(memory, .{ .name = "V_e", .value = stall, .vertical = false, .color = "#9c8b00", .width = 2 });
    try lines.guides.append(memory, .{ .name = "V*", .value = maneuver, .vertical = false, .color = "#2f5597", .width = 2 });
    try lines.guides.append(memory, .{ .name = try text(memory, "R = {d:.0} m (φ = {d}°, n = {d:.2})", .{ tight, bank_limit_deg, 1 / @cos(bank_limit_deg * rad) }), .value = tight, .vertical = true, .color = safe_color, .width = 2.5 });
    try lines.guides.append(memory, .{ .name = try text(memory, "R = {d:.0} m (φ = 10°)", .{wide}), .value = wide, .vertical = true, .color = safe_color, .width = 2.5 });
}

/// o diagrama V-n: o limite do estol e o da tração, o fator de carga de projeto e a região segura até V_max
fn vnChart(memory: std.mem.Allocator, lines: *Lines, altitude: Altitude, load_factor: f64) !void {
    const rows = altitude.rows;
    const facts = altitude.summary;
    const top = if (facts.Vmax > 0) facts.Vmax else rows[rows.len - 1].V;
    var safe_speeds: std.ArrayList(f64) = .empty;
    var safe_limit: std.ArrayList(f64) = .empty;
    var speeds: std.ArrayList(f64) = .empty;
    var stall: std.ArrayList(f64) = .empty;
    var sustained: std.ArrayList(f64) = .empty;
    for (rows) |row| {
        if (row.V <= top) {
            try safe_speeds.append(memory, row.V);
            try safe_limit.append(memory, @min(row.n_stall, load_factor));
        }
        if (row.V <= 1.15 * top) {
            try speeds.append(memory, row.V);
            try stall.append(memory, row.n_stall);
            try sustained.append(memory, row.n_sust);
        }
    }
    const zeros = try memory.alloc(f64, safe_speeds.items.len);
    @memset(zeros, 0);
    try lines.curves.append(memory, .{ .name = "seguro", .x = safe_speeds.items, .y = zeros, .fill = safe_limit.items, .color = safe_color });
    try lines.curves.append(memory, .{ .name = "estol", .x = speeds.items, .y = stall.items, .color = "#d62728", .width = 2 });
    try lines.curves.append(memory, .{ .name = "tração", .x = speeds.items, .y = sustained.items, .color = "#ff7f0e", .width = 2 });
    try lines.guides.append(memory, .{ .name = try text(memory, "n = {d}", .{load_factor}), .value = load_factor, .vertical = false, .color = black, .dashed = true });
    try lines.guides.append(memory, .{ .name = try text(memory, "V* = {d:.1} m/s", .{facts.Vman}), .value = facts.Vman, .vertical = true, .color = black, .dashed = true });
    try lines.guides.append(memory, .{ .name = try text(memory, "V_max = {d:.1} m/s", .{top}), .value = top, .vertical = true, .color = "#d62728", .dashed = true });
}

const testing = std.testing;

test "Desempenho: a polar, o teto e as curvas por altitude batem com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Performance);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"h_list\": [0, 900]}"));
    try testing.expect(try registered.advance(&run));
    const state: *RunState = @ptrCast(@alignCast(run.state.?));
    // os números do Python (`performance.py`, `core_polar` e o resumo, Convencional_original)
    try testing.expectApproxEqAbs(@as(f64, 0.05057026000065569), state.polar.CD0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.055950050737193086), state.polar.K, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.6460732913591556), state.polar.CLmax, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 12.39), state.mass, 1e-9);
    try testing.expectEqual(@as(?f64, 2700), state.envelope.ceiling);
    const sea = state.altitudes[0].summary;
    try testing.expectApproxEqAbs(@as(f64, 10.977876996125188), sea.Vs, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 8.0), sea.Vmin, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 17.6), sea.Vmax, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.5867000135296746), sea.RCmax, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 23.425761811612784), 60 * sea.t_max, 1e-6);
    const high = state.altitudes[1].summary;
    try testing.expectApproxEqAbs(@as(f64, 1.1226020074689091), high.rho, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.3871166983819614), high.RCmax, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 17.586064321500253), high.range_max / 1000, 1e-6);
    try testing.expectEqual(@as(usize, 346), state.altitudes[0].rows.len);
    try testing.expectApproxEqAbs(@as(f64, 219.66201712648657), state.altitudes[0].rows[100].Pd, 1e-6);

    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 10), outcome.value.object.get("plots").?.array.items.len);
    const checks = outcome.value.object.get("checks").?.array.items;
    try testing.expectEqual(@as(usize, 5), checks.len); // faixa e subida em cada altitude, mais o teto
    try testing.expectEqualStrings("atencao", checks[3].object.get("status").?.string);
    try testing.expectEqualStrings("11.0 a 15.5 m/s", checks[0].object.get("value").?.string);
}

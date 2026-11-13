//! Voo nivelado e envelopes em Zig (o par de `envelope.py`): por altitude, V_min e V_max onde a potência disponível
//! cruza a requerida, V_e (estol), V* = V_e √n (manobra), V_cru e o teto absoluto, pelos dois métodos do núcleo
//! (`core/src/sim/envelope.zig`): a planilha (as fórmulas do Envelope_main original, polar parabólica) e o modelo
//! completo (o avião inteiro trimado em cada altitude e velocidade). Junto, a tabela de desempenho ao nível do mar
//! (`core/src/sim/trim.zig`, `performance`) e o diagnóstico do ângulo de cruzeiro. Aqui só se monta a configuração
//! a partir do avião, se roda um método por fatia e se escreve o resultado.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");

const params_mod = aircraft_model.params;
const envelope = core.envelope;
const deg = 180.0 / std.math.pi;
const rad = std.math.pi / 180.0;

/// a análise, com a interface de `simulation.check`
pub const Envelope = struct {
    pub const name: []const u8 = "envelope";
    pub const title: [:0]const u8 = "Voo nivelado e envelopes";
    pub const area: []const u8 = "Desempenho";
    pub const description: []const u8 = "Por altitude: V_min e V_max (P_d = P_r), V_e, V* = V_e·raiz(n), V_cru e o teto absoluto. " ++
        "Método da planilha (Envelope_main) ou trimagem da aeronave completa.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
};

const methods = [_][]const u8{ "planilha", "modelo completo", "os dois" };
const atmospheres = [_][]const u8{ "ISA", "fórmula da planilha" };
const below_choices = [_][]const u8{ "continua (polar sem estol)", "corta no estol" };
const method_help = "planilha: as fórmulas do Envelope_main original — polar parabólica C_D = C_Dpw + C_Dph·S_h/S_w + " ++
    "K·C_L² com os C_Dp e o K da planilha, ângulo de cruzeiro fixo, sem equilibrar o momento (a EH não trima). " ++
    "Modelo completo: o avião inteiro trimado em cada (h, V) — painéis, momentos, profundor e o estol de cada " ++
    "seção —, então cobra o arrasto de trimagem e costuma dar teto menor e V_min maior. A tração disponível é a " ++
    "mesma nos dois (as unidades propulsoras do avião com ρ(h)). Escolha um dos dois ou 'os dois' para comparar.";

/// as curvas do envelope, com a cor de cada uma
const envelope_curves = [_]struct { field: []const u8, color: []const u8 }{
    .{ .field = "Vmin", .color = "#1f77b4" },
    .{ .field = "Vmax", .color = "#d62728" },
    .{ .field = "Ve", .color = "#2ca02c" },
    .{ .field = "Vman", .color = "#ff7f0e" },
    .{ .field = "Vcru", .color = "#9467bd" },
};

const plot_comparison = simulation.Plot{ .key = "env_c", .title = "Envelopes comparados", .xlabel = "velocidade (m/s)", .ylabel = "altitude (m)" };
const other_plots = [_]simulation.Plot{
    .{ .key = "env_p", .title = "Envelope (planilha)", .xlabel = "velocidade (m/s)", .ylabel = "altitude (m)" },
    .{ .key = "env_m", .title = "Envelope (modelo)", .xlabel = "velocidade (m/s)", .ylabel = "altitude (m)" },
    .{ .key = "pot0", .title = "Potências", .xlabel = "$V$ (m/s)", .ylabel = "$P$ (W)" },
    .{ .key = "potT", .title = "Potência no teto", .xlabel = "$V$ (m/s)", .ylabel = "$P$ (W)" },
    .{ .key = "thr", .title = "Voo nivelado", .xlabel = "$V$ (m/s)", .ylabel = "— / graus" },
    .{ .key = "roc", .title = "Subida e planeio", .xlabel = "$V$ (m/s)", .ylabel = "m/s" },
    .{ .key = "acr", .title = "Ângulo de equilíbrio", .xlabel = "$V$ (m/s)", .ylabel = "$\\alpha$ (°)" },
    .{ .key = "raio", .title = "Raio mínimo", .xlabel = "$V$ (m/s)", .ylabel = "$R$ (m)" },
};
const all_plots = [_]simulation.Plot{plot_comparison} ++ other_plots;

const max_rows = 4096;

/// o que um método deu
const Outcome = struct {
    done: bool = false,
    cfg: envelope.EnvCfg = .{},
    rows: []envelope.EnvRow = &.{},
    ceiling: f64 = 0,
    near_ceiling: f64 = 0, // a altitude da curva "perto do teto"
    sea_level: Curves = .{},
    top: Curves = .{},
};

/// T_d e T_r (e as potências) contra V numa altitude
const Curves = struct {
    speeds: []f64 = &.{},
    available: []f64 = &.{}, // P_d = T_d V
    required: []f64 = &.{}, // P_r = T_r V
};

const Method = enum { sheet, model };

const RunState = struct {
    instance: *core.runner.Instance = undefined,
    info: params_mod.Info = .{},
    wanted: std.EnumArray(Method, bool) = .initFill(false),
    outcomes: std.EnumArray(Method, Outcome) = .initFill(.{}),
    table_wanted: bool = true,
    table: []core.types.PerfRow = &.{},
    table_done: bool = false,
    alpha_cruise_deg: f64 = 0,
    ceiling_min: f64 = 500,
    load_limit: f64 = 2,
    curve_points: usize = 300, // pontos das curvas de potência
};

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const cruise_text = if (aircraft) |plane| try std.fmt.allocPrint(memory, "{d}", .{plane.performance.alpha_cruise}) else "";
    const all_fields = [_]simulation.Param{
        .{ .key = "method", .label = "Método", .kind = .choice, .default = .{ .text = "os dois" }, .choices = &methods, .help = method_help, .rebuild = true },
        .{ .key = "below", .label = "Abaixo do estol (modelo completo)", .kind = .choice, .default = .{ .text = below_choices[0] }, .choices = &below_choices, .help = "continua: abaixo do V_e a trimagem usa a polar sem estol, só para achar onde a potência disponível cruza a requerida e mostrar a curva inteira (como a planilha). Esse trecho não é voável: o mínimo voável é max(V_min, V_e). Corta: o modelo para no estol e o V_min fica colado no V_e." },
        .{ .key = "atmos", .label = "Atmosfera", .kind = .choice, .default = .{ .text = "ISA" }, .choices = &atmospheres },
        .{ .key = "faithful", .label = "igual ao original", .kind = .bool, .default = .{ .toggle = false }, .help = "liga: mesmas contas do Envelope_main, para comparar com resultados antigos" },
        .{ .key = "h_step", .label = "Passo de altitude", .default = .{ .number = 50 }, .minimum = 1, .maximum = 1000, .unit = "m" },
        .{ .key = "h_max", .label = "Altitude máxima", .default = .{ .number = 6000 }, .minimum = 50, .maximum = 20000, .unit = "m" },
        .{ .key = "V_lo", .label = "V inicial", .default = .{ .number = 4 }, .minimum = 0.5, .maximum = 100, .unit = "m/s" },
        .{ .key = "V_hi", .label = "V final", .default = .{ .number = 30 }, .minimum = 1, .maximum = 200, .unit = "m/s" },
        .{ .key = "dV", .label = "Grade de V (depois bisseção)", .default = .{ .number = 0.05 }, .minimum = 0.001, .maximum = 2, .unit = "m/s" },
        .{ .key = "tol", .label = "Tolerância de V", .default = .{ .number = 1e-5 }, .minimum = 1e-8, .maximum = 0.1, .unit = "m/s" },
        .{ .key = "dV_modelo", .label = "Grade de V mínima do modelo completo", .default = .{ .number = 0.5 }, .minimum = 0.001, .maximum = 5, .unit = "m/s", .help = "o modelo completo trima o avião em cada V da grade (caro), então a grade dele nunca fica mais fina que isto; a bisseção acha o limite exato depois" },
        .{ .key = "curva_pontos", .label = "Pontos das curvas de potência", .default = .{ .number = 300 }, .minimum = 2, .maximum = 5000 },
        .{ .key = "n_load", .label = "Fator de carga n (0 = da aeronave)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 10 },
        .{ .key = "alpha_cruise", .label = "ângulo de cruzeiro", .kind = .floats, .default = .{ .text = cruise_text }, .unit = "°", .help = "começa com o do avião (Montagem → desempenho); mudar aqui vale só para esta análise. Planilha: V em que a sustentação nesse α iguala o peso. Modelo completo: V em que o α de equilíbrio é esse" },
        .{ .key = "table", .label = "Tabela de desempenho ao nível do mar", .kind = .bool, .default = .{ .toggle = true } },
    };
    // com só a planilha, o campo do modelo completo some; a comparação só aparece com os dois
    const method = values.text("method", "os dois");
    var fields: [all_fields.len]simulation.Param = undefined;
    var count: usize = 0;
    for (all_fields) |field| {
        if (std.mem.eql(u8, method, "planilha") and std.mem.eql(u8, field.key, "below")) continue;
        fields[count] = field;
        count += 1;
    }
    const plots: []const simulation.Plot = if (std.mem.eql(u8, method, "os dois")) &all_plots else &other_plots;
    try simulation.writeSpecs(out, fields[0..count], plots, Envelope.description, .{});
}

/// os dados da planilha a partir do avião (`sheet_config` do Python: a asa, a EH e `performance`)
fn sheetConfig(aircraft: *const simulation.Aircraft) params_mod.Error!envelope.EnvCfg {
    const performance = aircraft.performance;
    var cfg: envelope.EnvCfg = .{
        .cdp_x = performance.cdp_x,
        .cdpw_c1 = performance.cdp_wing[0],
        .cdpw_c2 = performance.cdp_wing[1],
        .cdph_c1 = performance.cdp_htail[0],
        .cdph_c2 = performance.cdp_htail[1],
        .rho0 = performance.rho0,
        .n_load = performance.load_factor,
        .alpha_cruise = performance.alpha_cruise * rad,
    };
    const downwash = try params_mod.wingDownwash(aircraft);
    cfg.eps0 = downwash[0];
    cfg.depsda = downwash[1];
    if (params_mod.firstSurface(aircraft, "wing")) |wing| {
        const wing_coeffs = try params_mod.coeffs(wing);
        cfg.Sw = params_mod.area(wing);
        cfg.CLa_w = wing_coeffs.CLa;
        cfg.CL0_w = wing_coeffs.CL0;
        cfg.CLmax_w = wing_coeffs.CLmax;
        cfg.iw = wing.incidence * rad;
        cfg.K = performance.K orelse 1.0 / (std.math.pi * wing.oswald * wing_coeffs.AR);
    }
    if (params_mod.firstSurface(aircraft, "htail")) |tail| {
        const tail_coeffs = try params_mod.coeffs(tail);
        cfg.Sh = params_mod.area(tail);
        cfg.CLa_h = tail_coeffs.CLa;
        cfg.CL0_h = tail_coeffs.CL0;
        cfg.CLmax_h = tail_coeffs.CLmax;
        cfg.ih = tail.incidence * rad;
        cfg.eps0 = if (tail.eps0) |angle| angle * rad else downwash[0];
        cfg.depsda = tail.depsda orelse downwash[1];
    } else {
        cfg.Sh = 0;
        cfg.CLa_h = 0;
        cfg.CL0_h = 0;
        cfg.CLmax_h = 0;
        cfg.ih = 0;
    }
    return cfg;
}

/// a configuração do núcleo de um método (`_cfg` do Python)
fn methodConfig(sheet: envelope.EnvCfg, values: simulation.Values, method: Method) envelope.EnvCfg {
    var cfg = sheet;
    const faithful = values.toggle("faithful", false);
    const atmosphere_text = if (faithful and method == .sheet) atmospheres[1] else values.text("atmos", atmospheres[0]);
    cfg.method = if (method == .sheet) .sheet else .model;
    cfg.atmos = if (std.mem.eql(u8, atmosphere_text, atmospheres[1])) .sheet else .isa;
    cfg.faithful = @intFromBool(faithful);
    cfg.below_stall = @intFromBool(method == .model and std.mem.eql(u8, values.text("below", below_choices[0]), below_choices[0]));
    cfg.h_step = @max(values.number("h_step", 50), 1);
    cfg.h_max = @max(values.number("h_max", 6000), cfg.h_step);
    cfg.V_lo = values.number("V_lo", 4);
    cfg.V_hi = @max(values.number("V_hi", 30), cfg.V_lo + 0.1);
    cfg.tol = values.number("tol", 1e-5);
    const grid = @max(values.number("dV", 0.05), 1e-3);
    cfg.dV = if (method == .sheet) grid else @max(grid, values.number("dV_modelo", 0.5));
    const load = values.number("n_load", 0);
    if (load > 0) cfg.n_load = load;
    var buffer: [1]f64 = undefined;
    const cruise = values.numbers("alpha_cruise", &buffer, &.{});
    if (cruise.len > 0) cfg.alpha_cruise = cruise[0] * rad;
    return cfg;
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    state.instance = try memory.create(core.runner.Instance);
    state.instance.* = .{};
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    state.info = params_mod.setup(run.aircraft, state.instance, &diagnosis) catch |err| {
        run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    const sheet = sheetConfig(run.aircraft) catch |err| {
        run.fail("os dados da planilha não saíram do avião ({s})", .{@errorName(err)});
        return err;
    };
    const method = values.text("method", "os dois");
    state.wanted.set(.sheet, !std.mem.eql(u8, method, "modelo completo"));
    state.wanted.set(.model, !std.mem.eql(u8, method, "planilha"));
    for ([_]Method{ .sheet, .model }) |which| {
        const outcome = state.outcomes.getPtr(which);
        outcome.cfg = methodConfig(sheet, values, which);
        const capacity = @min(@as(usize, @intFromFloat(outcome.cfg.h_max / outcome.cfg.h_step)) + 2, max_rows);
        outcome.rows = try memory.alloc(envelope.EnvRow, capacity);
    }
    state.table_wanted = values.toggle("table", true);
    state.alpha_cruise_deg = state.outcomes.get(if (state.wanted.get(.sheet)) .sheet else .model).cfg.alpha_cruise * deg;
    state.ceiling_min = run.aircraft.performance.ceiling_min;
    const load = values.number("n_load", 0);
    state.load_limit = if (load > 0) load else run.aircraft.performance.load_factor;
    state.curve_points = @intFromFloat(@max(@round(values.number("curva_pontos", 300)), 2));
}

/// as curvas de potência de um método numa altitude
fn powerCurves(memory: std.mem.Allocator, params: *const core.types.Params, cfg: *const envelope.EnvCfg, height: f64, curve_points: usize) !Curves {
    const speeds = try memory.alloc(f64, curve_points);
    const available = try memory.alloc(f64, curve_points);
    const required = try memory.alloc(f64, curve_points);
    const count = envelope.curve(params, cfg, height, speeds, available, required);
    for (speeds[0..count], available[0..count], required[0..count]) |speed, *thrust_available, *thrust_required| {
        thrust_available.* *= speed;
        thrust_required.* *= speed;
    }
    return .{ .speeds = speeds[0..count], .available = available[0..count], .required = required[0..count] };
}

/// um método por fatia, depois a tabela; verdadeiro quando acabou
fn advanceRun(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    const memory = run.memory();
    const params = &state.instance.p;
    for ([_]Method{ .sheet, .model }, 0..) |which, k| {
        const outcome = state.outcomes.getPtr(which);
        if (!state.wanted.get(which) or outcome.done) continue;
        run.say("envelope: {s}", .{methods[k]});
        const count = envelope.compute(params, &outcome.cfg, outcome.rows, &outcome.ceiling);
        outcome.rows = outcome.rows[0..count];
        outcome.near_ceiling = @max(outcome.ceiling - outcome.cfg.h_step, 0);
        outcome.sea_level = try powerCurves(memory, params, &outcome.cfg, 0, state.curve_points);
        outcome.top = try powerCurves(memory, params, &outcome.cfg, outcome.near_ceiling, state.curve_points);
        outcome.done = true;
        run.progress = @floatCast(@as(f64, @floatFromInt(k + 1)) / 3.0);
        return false;
    }
    if (state.table_wanted and !state.table_done) {
        run.say("tabela de desempenho (h = 0)", .{});
        const top = state.outcomes.get(.model).cfg.V_hi;
        const bottom = @max(state.outcomes.get(.model).cfg.V_lo, 2.0);
        const rows = try memory.alloc(core.types.PerfRow, @as(usize, @intFromFloat((top - bottom) / 0.5)) + 4);
        const count = core.trim.performance(core.trim.Ctx.init(params, &state.instance.r.f), top, bottom, 0.5, rows);
        state.table = rows[0..count];
        for (state.table) |*row| {
            inline for (.{ "alpha_level", "de_level", "gamma_max", "gamma_idle", "phi_stall", "phi_sust" }) |field| @field(row, field) *= deg;
            inline for (.{ "R_stall", "R_sust" }) |field| if (@field(row, field) > 1e6) {
                @field(row, field) = std.math.nan(f64);
            };
        }
        state.table_done = true;
    }
    run.progress = 1;
    return true;
}

/// uma coluna das linhas (o campo `field` de cada uma)
fn column(memory: std.mem.Allocator, comptime Row: type, rows: []const Row, comptime field: []const u8) ![]f64 {
    const values = try memory.alloc(f64, rows.len);
    for (rows, values) |row, *value| value.* = @field(row, field);
    return values;
}

/// um campo de uma linha de envelope pelo nome em tempo de execução
fn rowField(row: envelope.EnvRow, field: []const u8) f64 {
    inline for (@typeInfo(envelope.EnvRow).@"struct".fields) |candidate| {
        if (std.mem.eql(u8, candidate.name, field)) return @field(row, candidate.name);
    }
    return std.math.nan(f64);
}

fn envelopeColumn(memory: std.mem.Allocator, rows: []const envelope.EnvRow, field: []const u8) ![]f64 {
    const values = try memory.alloc(f64, rows.len);
    for (rows, values) |row, *value| value.* = rowField(row, field);
    return values;
}

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

const Summary = std.ArrayList([2][]const u8);

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    var summary: Summary = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    const keys = [_][]const u8{ "planilha", "modelo" };
    for ([_]Method{ .sheet, .model }, keys) |which, key| {
        if (!state.wanted.get(which)) continue;
        const outcome = state.outcomes.get(which);
        try summary.append(memory, .{ try text(memory, "[{s}] teto absoluto (m)", .{key}), try text(memory, "{d:.1}", .{outcome.ceiling}) });
        try summary.append(memory, .{ try text(memory, "[{s}] teto ≥ {d:.0} m", .{ key, state.ceiling_min }), if (outcome.ceiling >= state.ceiling_min) "sim" else "não" });
        if (outcome.rows.len > 0) {
            const first = outcome.rows[0];
            for (envelope_curves) |curve| try summary.append(memory, .{ try text(memory, "[{s}] {s} em h = 0 (m/s)", .{ key, curve.field }), try text(memory, "{d:.3}", .{rowField(first, curve.field)}) });
            try summary.append(memory, .{ try text(memory, "[{s}] V mínimo voável em h = 0 = max(V_min, V_e) (m/s)", .{key}), try text(memory, "{d:.3}", .{@max(first.Vmin, first.Ve)}) });
        }
        if (which == .sheet and outcome.cfg.faithful != 0)
            try summary.append(memory, .{ "[planilha] observação", "reproduz o original: arrasto com ρ/ρ0 (subestima P_r por ~ρ0) e densidade (1 + λh/T0)^(−g/λR − 1)" });
    }
    if (state.table.len > 0) try tableSummary(memory, state, &summary);
    try cruiseChecks(memory, state, &summary, &checks);
    try summary.append(memory, .{ "Vs", try text(memory, "{d:.3}", .{state.info.Vs}) });
    try summary.append(memory, .{ "massa", try text(memory, "{d:.3}", .{state.info.mass}) });
    try summary.append(memory, .{ "margem_estatica", try text(memory, "{d:.4}", .{state.info.static_margin}) });

    try simulation.beginResult(out, summary.items, checks.items);
    var first = true;
    if (state.wanted.get(.sheet) and state.wanted.get(.model)) {
        var curves: std.ArrayList(simulation.Curve) = .empty;
        for ([_]Method{ .sheet, .model }, [_][]const u8{ "planilha", "modelo completo" }) |which, label| {
            const rows = state.outcomes.get(which).rows;
            const heights = try column(memory, envelope.EnvRow, rows, "h");
            for (envelope_curves) |curve| try curves.append(memory, .{ .name = try text(memory, "{s} ({s})", .{ curve.field, label }), .x = try envelopeColumn(memory, rows, curve.field), .y = heights, .color = curve.color, .dashed = which == .model });
        }
        try simulation.writePlot(out, plot_comparison, curves.items, first);
        first = false;
    }
    for ([_]Method{ .sheet, .model }, 0..) |which, k| {
        var curves: std.ArrayList(simulation.Curve) = .empty;
        if (state.wanted.get(which)) {
            const rows = state.outcomes.get(which).rows;
            const heights = try column(memory, envelope.EnvRow, rows, "h");
            for (envelope_curves) |curve| try curves.append(memory, .{ .name = curve.field, .x = try envelopeColumn(memory, rows, curve.field), .y = heights, .color = curve.color });
        }
        try simulation.writePlot(out, other_plots[k], curves.items, first);
        first = false;
    }
    // as potências em h = 0 e perto do teto, de cada método
    inline for (.{ "sea_level", "top" }, 2..) |which_curves, plot_index| {
        var curves: std.ArrayList(simulation.Curve) = .empty;
        for ([_]Method{ .sheet, .model }, keys) |which, key| {
            if (!state.wanted.get(which)) continue;
            const outcome = state.outcomes.get(which);
            const power = @field(outcome, which_curves);
            const where = if (plot_index == 2) try text(memory, "{s}", .{key}) else try text(memory, "{s}, h = {d:.0} m", .{ key, outcome.near_ceiling });
            try curves.append(memory, .{ .name = try text(memory, "Pd ({s})", .{where}), .x = power.speeds, .y = power.available, .color = "#1f77b4", .dashed = which == .model });
            try curves.append(memory, .{ .name = try text(memory, "Pr ({s})", .{where}), .x = power.speeds, .y = power.required, .color = "#d62728", .dashed = which == .model });
        }
        try simulation.writePlot(out, other_plots[plot_index], curves.items, false);
    }
    try tablePlots(memory, state, out);
    try simulation.endResult(out);
}

/// o resumo da tabela de desempenho (V nivelado, a melhor razão de subida)
fn tableSummary(memory: std.mem.Allocator, state: *const RunState, summary: *Summary) !void {
    var level_min = std.math.inf(f64);
    var level_max = -std.math.inf(f64);
    var best_climb: ?core.types.PerfRow = null;
    for (state.table) |row| {
        if (row.ok_level > 0 and row.thr_level > 0.05 and row.thr_level <= 1.0) {
            level_min = @min(level_min, row.V);
            level_max = @max(level_max, row.V);
        }
        if (row.ok_climb > 0 and (best_climb == null or row.roc_max > best_climb.?.roc_max)) best_climb = row;
    }
    if (level_max >= level_min) {
        try summary.append(memory, .{ "V_max_nivelado", try text(memory, "{d:.3}", .{level_max}) });
        try summary.append(memory, .{ "V_min_nivelado", try text(memory, "{d:.3}", .{level_min}) });
    }
    if (best_climb) |row| {
        try summary.append(memory, .{ "roc_max", try text(memory, "{d:.4}", .{row.roc_max}) });
        try summary.append(memory, .{ "V_roc_max", try text(memory, "{d:.3}", .{row.V}) });
    }
}

/// a velocidade de cruzeiro de cada método em h = 0 contra o ângulo de cruzeiro pedido (`_cruise` do Python)
fn cruiseChecks(memory: std.mem.Allocator, state: *const RunState, summary: *Summary, checks: *std.ArrayList(simulation.Check)) !void {
    const group = "cruzeiro (h = 0)";
    const cruise = state.alpha_cruise_deg;
    // a faixa do α de equilíbrio dentro do envelope do modelo
    var range: ?[2]f64 = null;
    if (state.wanted.get(.model) and state.outcomes.get(.model).rows.len > 0) {
        const first = state.outcomes.get(.model).rows[0];
        for (state.table) |row| if (row.ok_level > 0 and row.V >= first.Vmin and row.V <= first.Vmax) {
            range = if (range) |known| .{ @min(known[0], row.alpha_level), @max(known[1], row.alpha_level) } else .{ row.alpha_level, row.alpha_level };
        };
    }
    for ([_]Method{ .sheet, .model }, [_][]const u8{ "planilha", "modelo completo" }) |which, label| {
        if (!state.wanted.get(which) or state.outcomes.get(which).rows.len == 0) continue;
        const first = state.outcomes.get(which).rows[0];
        const low = first.Vmin;
        const high = first.Vmax;
        const speed = first.Vcru;
        const item = try text(memory, "velocidade de cruzeiro ({s})", .{label});
        if (std.math.isFinite(speed) and low <= speed and speed <= high) {
            try checks.append(memory, .{ .status = .ok, .item = item, .value = try text(memory, "{d:.2} m/s", .{speed}), .criterion = try text(memory, "dentro do envelope ({d:.1} a {d:.1} m/s) com α de cruzeiro = {d}°", .{ low, high, cruise }), .group = group });
            continue;
        }
        var why: []const u8 = undefined;
        var fix: []const u8 = undefined;
        if (which == .sheet) {
            why = try text(memory, "com α = {d}°, a sustentação iguala o peso a {d:.2} m/s, fora de {d:.1} a {d:.1} m/s (onde a tração cobre o arrasto)", .{ cruise, speed, low, high });
            fix = "outro ângulo de cruzeiro, mais tração ou menos arrasto";
        } else {
            why = try text(memory, "o α de equilíbrio não passa por {d}° entre {d:.1} e {d:.1} m/s: o avião não voa nivelado nesse ângulo de cruzeiro", .{ cruise, low, high });
            if (range) |known| why = try text(memory, "{s} (dentro do envelope ele vai de {d:.1}° a {d:.1}°)", .{ why, known[0], known[1] });
            fix = if (range) |known| try text(memory, "ângulo de cruzeiro entre {d:.1}° e {d:.1}°", .{ known[0], known[1] }) else "ligue a tabela de desempenho para ver a faixa de α do envelope";
        }
        const value = if (std.math.isFinite(speed)) try text(memory, "{d:.2} m/s", .{speed}) else "não existe";
        try checks.append(memory, .{ .status = .atencao, .item = item, .value = value, .criterion = try text(memory, "dentro do envelope com α de cruzeiro = {d}°", .{cruise}), .why = why, .fix = fix, .group = group });
        try summary.append(memory, .{ try text(memory, "[{s}] V_cru", .{if (which == .sheet) "planilha" else "modelo"}), try text(memory, "{s}: {s}", .{ value, why }) });
    }
}

/// os gráficos da tabela de desempenho e o do ângulo de cruzeiro
fn tablePlots(memory: std.mem.Allocator, state: *const RunState, out: *simulation.Writer) !void {
    const rows = state.table;
    const speeds = try column(memory, core.types.PerfRow, rows, "V");
    var curves: std.ArrayList(simulation.Curve) = .empty;
    if (rows.len > 0) {
        try curves.append(memory, .{ .name = "thr_level", .x = speeds, .y = try column(memory, core.types.PerfRow, rows, "thr_level"), .color = "#1f77b4" });
        try curves.append(memory, .{ .name = "alpha_level", .x = speeds, .y = try column(memory, core.types.PerfRow, rows, "alpha_level"), .color = "#d62728" });
    }
    try simulation.writePlot(out, other_plots[4], curves.items, false);
    curves = .empty;
    if (rows.len > 0) {
        try curves.append(memory, .{ .name = "roc_max", .x = speeds, .y = try column(memory, core.types.PerfRow, rows, "roc_max"), .color = "#1f77b4" });
        try curves.append(memory, .{ .name = "roc_idle", .x = speeds, .y = try column(memory, core.types.PerfRow, rows, "roc_idle"), .color = "#d62728" });
    }
    try simulation.writePlot(out, other_plots[5], curves.items, false);
    // α de equilíbrio (só onde trima), o ângulo de cruzeiro e o V_cru e o envelope de cada método
    curves = .empty;
    var level_speeds: std.ArrayList(f64) = .empty;
    var level_alphas: std.ArrayList(f64) = .empty;
    for (rows) |row| if (row.ok_level > 0) {
        try level_speeds.append(memory, row.V);
        try level_alphas.append(memory, row.alpha_level);
    };
    var lowest: f64 = -5;
    var highest: f64 = 20;
    if (level_alphas.items.len > 0) {
        lowest = std.mem.min(f64, level_alphas.items);
        highest = std.mem.max(f64, level_alphas.items);
        try curves.append(memory, .{ .name = "α de equilíbrio (modelo completo)", .x = level_speeds.items, .y = level_alphas.items, .color = "#000000" });
    }
    const cruise = state.alpha_cruise_deg;
    lowest = @min(lowest, cruise);
    highest = @max(highest, cruise);
    const left = state.outcomes.get(.model).cfg.V_lo;
    const right = state.outcomes.get(.model).cfg.V_hi;
    try curves.append(memory, .{ .name = try text(memory, "ângulo de cruzeiro = {d}°", .{cruise}), .x = try memory.dupe(f64, &.{ left, right }), .y = try memory.dupe(f64, &.{ cruise, cruise }), .color = "#9467bd", .dashed = true });
    for ([_]Method{ .sheet, .model }, [_][]const u8{ "planilha", "modelo completo" }) |which, label| {
        if (!state.wanted.get(which) or state.outcomes.get(which).rows.len == 0) continue;
        const first = state.outcomes.get(which).rows[0];
        const color = if (which == .sheet) "#1f77b4" else "#d62728";
        const vertical = try memory.dupe(f64, &.{ lowest, highest });
        try curves.append(memory, .{ .name = try text(memory, "envelope ({s}): {d:.1} a {d:.1} m/s", .{ label, first.Vmin, first.Vmax }), .x = try memory.dupe(f64, &.{ first.Vmin, first.Vmin }), .y = vertical, .color = color, .dashed = true });
        try curves.append(memory, .{ .name = "", .x = try memory.dupe(f64, &.{ first.Vmax, first.Vmax }), .y = vertical, .color = color, .dashed = true, .legend = false });
        if (std.math.isFinite(first.Vcru)) try curves.append(memory, .{ .name = try text(memory, "V_cru ({s}) = {d:.2} m/s", .{ label, first.Vcru }), .x = try memory.dupe(f64, &.{ first.Vcru, first.Vcru }), .y = vertical, .color = color });
    }
    try simulation.writePlot(out, other_plots[6], curves.items, false);
    curves = .empty;
    if (rows.len > 0) {
        try curves.append(memory, .{ .name = "R_stall", .x = speeds, .y = try column(memory, core.types.PerfRow, rows, "R_stall"), .color = "#1f77b4" });
        try curves.append(memory, .{ .name = "R_sust", .x = speeds, .y = try column(memory, core.types.PerfRow, rows, "R_sust"), .color = "#d62728" });
    }
    try simulation.writePlot(out, other_plots[7], curves.items, false);
}

const testing = std.testing;

test "Envelope: os dois métodos e a tabela batem com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();

    // os dados da planilha, como `sheet_config` do Python
    const sheet = try sheetConfig(&loaded.ac);
    try testing.expectApproxEqAbs(@as(f64, 4.3877441602), sheet.CLa_w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.7478379861), sheet.CLa_h, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.4469319502), sheet.depsda, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0461586172), sheet.eps0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.059917155), sheet.K, 1e-9);

    const registered = simulation.register(Envelope);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"h_step\": 500}"));
    while (!try registered.advance(&run)) {}
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
    defer outcome.deinit();
    const summary = outcome.value.object.get("summary").?.object;
    // os números do Python (`envelope.py`, h_step = 500, o resto padrão)
    const expected = [_]struct { []const u8, f64, f64 }{
        .{ "[planilha] teto absoluto (m)", 4631.8359375, 0.1 },
        .{ "[planilha] Vmin em h = 0 (m/s)", 7.983517456, 1e-3 },
        .{ "[planilha] Vmax em h = 0 (m/s)", 23.053787231, 1e-3 },
        .{ "[planilha] Vcru em h = 0 (m/s)", 18.823144426, 1e-3 },
        .{ "[modelo] teto absoluto (m)", 2901.3671875, 0.1 },
        .{ "[modelo] Vmin em h = 0 (m/s)", 9.770996094, 1e-3 },
        .{ "[modelo] Vmax em h = 0 (m/s)", 17.916503906, 1e-3 },
        .{ "V_max_nivelado", 17.5, 1e-3 },
        .{ "V_min_nivelado", 11.0, 1e-3 },
        .{ "roc_max", 0.6089814803, 1e-4 },
        .{ "Vs", 10.971265479, 1e-3 },
        .{ "massa", 12.39, 1e-3 },
        .{ "margem_estatica", 0.1770120817, 1e-4 },
    };
    for (expected) |entry| {
        const found = summary.get(entry[0]) orelse {
            std.debug.print("falta no resumo: {s}\n", .{entry[0]});
            return error.TestUnexpectedResult;
        };
        testing.expectApproxEqAbs(entry[1], try std.fmt.parseFloat(f64, found.string), entry[2]) catch |err| {
            std.debug.print("{s}: {s}\n", .{ entry[0], found.string });
            return err;
        };
    }
    const checks = outcome.value.object.get("checks").?.array.items;
    try testing.expectEqual(@as(usize, 2), checks.len);
    try testing.expectEqualStrings("ok", checks[0].object.get("status").?.string);
    try testing.expectEqualStrings("atencao", checks[1].object.get("status").?.string);
    try testing.expectEqualStrings("ângulo de cruzeiro entre 2.6° e 16.0°", checks[1].object.get("fix").?.string);
    try testing.expectEqual(@as(usize, all_plots.len), outcome.value.object.get("plots").?.array.items.len);
}

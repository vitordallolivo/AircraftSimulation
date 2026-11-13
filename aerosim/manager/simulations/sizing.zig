//! Diagrama de restrições em Zig (o par de `sizing.py`): a tração por peso T/W (e a potência por massa P/m, para a
//! hélice) que cada requisito pede em função da carga alar W/S, a região viável, a faixa ótima, o ponto de projeto
//! (área de asa e motor para a massa de agora) e onde o avião aberto está. As contas são do núcleo
//! (`core/src/sizing/constraints.zig`); aqui só se monta a polar, se varre a W/S e se escreve.
//!
//! A polar vem de uma estimativa (antes de haver geometria) ou do avião inteiro no núcleo (a mesma polar da aba
//! Desempenho, pelas faixas). No Python a segunda vinha da aba Aerodinâmica, pelo método escolhido lá.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const performance = @import("performance.zig");

const params_mod = aircraft_model.params;
const constraints = core.constraints;
const Kind = constraints.Kind;
const Limit = constraints.Limit;
const g0 = constraints.g0;
const rad = std.math.pi / 180.0;

/// a análise, com a interface de `simulation.check`
pub const Sizing = struct {
    pub const name: []const u8 = "sizing";
    pub const title: [:0]const u8 = "Diagrama de restrições";
    pub const area: []const u8 = "Dimensionamento inicial";
    pub const description: []const u8 = "Diagrama de restrições: tração (e potência) por peso exigida por cada requisito em função da carga alar. Mostra a região viável, a faixa ótima e o ponto de projeto (área de asa e motor), e onde a aeronave atual está. A polar vem de uma estimativa ou do avião inteiro no núcleo.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
};

const sources = [_][]const u8{ "estimativa (sem geometria)", "o avião inteiro (núcleo)" };

const plots = [_]simulation.Plot{
    .{ .key = "c", .title = "Diagrama de restrições", .xlabel = "$W/S$ (N/m²)", .ylabel = "$T/W$" },
    .{ .key = "p", .title = "Potência específica", .xlabel = "$W/S$ (N/m²)", .ylabel = "$P/m$ (W/kg)" },
    .{ .key = "t", .title = "Tração exigida", .xlabel = "$V$ (m/s)", .ylabel = "$T/W$" },
};

/// a cor de cada requisito (a mesma em todos os gráficos)
const kind_color = std.EnumArray(Kind, []const u8).init(.{ .decolagem = "#2a78d6", .subida = "#eb6834", .gradiente = "#e87ba4", .cruzeiro = "#1baf7a", .vmax = "#4a3aa7", .curva = "#8c564b", .teto = "#17becf" });
const limit_color = std.EnumArray(Limit, []const u8).init(.{ .estol = "#e34948", .pouso = "#7f7f7f" });
const region_color = "#9ec5ee";
const best_color = "#eda100";
const design_color = "#0b0b0b";
const aircraft_color = "#d62728";

const max_speed_points = 1000; // o máximo de pontos da grade de V da tração

const RunState = struct {
    requirements: constraints.Requirements = .{},
    polar: constraints.ParabolicPolar = .{},
    polar_source: []const u8 = "",
    mass: f64 = 0,
    wing_area: f64 = 0,
    engines: usize = 0,
    grid_points: usize = 400, // a grade de W/S dos gráficos
    speed_points: usize = 50, // a grade de V da tração
    speeds: [max_speed_points]f64 = undefined,
    thrust: [max_speed_points]f64 = undefined, // a tração somada dos motores ligados, acelerador total (N)
    point: constraints.DesignPoint = undefined,
    tolerance_percent: f64 = 5,
    propeller_efficiency: f64 = 0.6,
};

/// a maior velocidade das pernas da missão (`_cruise_speed` do Python)
fn cruise(aircraft: *const simulation.Aircraft) f64 {
    var speed: f64 = 0;
    for (aircraft.mission.legs) |leg| if (leg.V) |value| {
        if (!leg.takeoff and !leg.landing) speed = @max(speed, value);
    };
    return if (speed > 0) speed else 15.0;
}

fn rounded(value: f64, digits: f64) f64 {
    return @round(value * digits) / digits;
}

/// o alongamento da asa (b²/S), com duas casas, ou 7 sem asa
fn wingAspect(aircraft: *const simulation.Aircraft) f64 {
    const wing = params_mod.firstSurface(aircraft, "wing") orelse return 7;
    const span = params_mod.span(wing);
    return rounded(span * span / params_mod.area(wing), 100);
}

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    const cruise_speed = if (aircraft) |plane| cruise(plane) else 15.0;
    const requirements_group = "Requisitos (0 desliga)";
    const polar_group = "Polar";
    const design_group = "Projeto";
    const aspect_ratio = if (aircraft) |plane| wingAspect(plane) else 7;
    const common = [_]simulation.Param{
        .{ .key = "V_stall", .label = "velocidade de estol máxima", .default = .{ .number = rounded(0.7 * cruise_speed, 10) }, .minimum = 2, .maximum = 60, .unit = "m/s", .group = requirements_group },
        .{ .key = "S_G", .label = "corrida de decolagem máxima", .default = .{ .number = 50 }, .minimum = 1, .maximum = 2000, .unit = "m", .group = requirements_group },
        .{ .key = "S_L", .label = "corrida de pouso máxima", .default = .{ .number = 0 }, .minimum = 0, .maximum = 2000, .unit = "m", .group = requirements_group },
        .{ .key = "V_cruise", .label = "velocidade de cruzeiro", .default = .{ .number = rounded(cruise_speed, 10) }, .minimum = 3, .maximum = 100, .unit = "m/s", .group = requirements_group },
        .{ .key = "V_max", .label = "velocidade máxima", .default = .{ .number = 0 }, .minimum = 0, .maximum = 150, .unit = "m/s", .group = requirements_group },
        .{ .key = "roc", .label = "razão de subida", .default = .{ .number = 2 }, .minimum = 0, .maximum = 30, .unit = "m/s", .group = requirements_group },
        .{ .key = "climb_grad", .label = "gradiente de subida", .default = .{ .number = 0 }, .minimum = 0, .maximum = 60, .unit = "%", .group = requirements_group },
        .{ .key = "V_climb", .label = "velocidade de subida", .default = .{ .number = rounded(0.85 * cruise_speed, 10) }, .minimum = 3, .maximum = 80, .unit = "m/s", .group = requirements_group },
        .{ .key = "n_turn", .label = "fator de carga em curva sustentada", .default = .{ .number = 2 }, .minimum = 1, .maximum = 6, .group = requirements_group },
        .{ .key = "V_turn", .label = "velocidade da curva", .default = .{ .number = rounded(cruise_speed, 10) }, .minimum = 3, .maximum = 80, .unit = "m/s", .group = requirements_group },
        .{ .key = "h_ceiling", .label = "teto", .default = .{ .number = 0 }, .minimum = 0, .maximum = 10000, .unit = "m", .group = requirements_group },
        .{ .key = "rho", .label = "densidade no campo", .default = .{ .number = if (aircraft) |plane| plane.environment.rho else 1.225 }, .minimum = 0.3, .maximum = 1.4, .unit = "kg/m³", .group = requirements_group },
        .{ .key = "source", .label = "de onde vem a polar", .kind = .choice, .default = .{ .text = sources[0] }, .choices = &sources, .group = polar_group, .rebuild = true, .help = "estimativa: dimensionamento antes da geometria; o avião inteiro: a polar do núcleo para a configuração aberta" },
    };
    const estimate = [_]simulation.Param{
        .{ .key = "Swet_S", .label = "área molhada / área de asa", .default = .{ .number = 4 }, .minimum = 2, .maximum = 10, .group = polar_group, .help = "Raymer fig. 12.4: ~4 para monomotor leve, ~3 para asa voadora" },
        .{ .key = "Cfe", .label = "atrito equivalente C_fe", .default = .{ .number = 0.0055 }, .minimum = 0.001, .maximum = 0.02, .group = polar_group, .help = "Raymer tab. 12.3: 0,0055 monomotor leve; 0,0045 bimotor leve; 0,0030 planador" },
        .{ .key = "AR", .label = "alongamento", .default = .{ .number = aspect_ratio }, .minimum = 1, .maximum = 40, .group = polar_group },
        .{ .key = "e", .label = "Oswald (0: Raymer pelo alongamento)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 1.2, .group = polar_group },
        .{ .key = "CLmax", .label = "C_Lmax", .default = .{ .number = 1.4 }, .minimum = 0.5, .maximum = 4, .group = polar_group },
        .{ .key = "CL_TO", .label = "C_L na corrida", .default = .{ .number = 0.5 }, .minimum = 0, .maximum = 2, .group = polar_group },
    };
    const tail = [_]simulation.Param{
        .{ .key = "mu", .label = "atrito de rolamento", .default = .{ .number = if (aircraft) |plane| plane.gear.mu_roll else 0.04 }, .minimum = 0, .maximum = 0.3, .group = polar_group },
        .{ .key = "mu_brake", .label = "atrito na frenagem", .default = .{ .number = if (aircraft) |plane| plane.gear.mu_brake else 0.3 }, .minimum = 0.05, .maximum = 1, .group = polar_group },
        .{ .key = "dCD_TO", .label = "C_D extra na corrida (trem, flape)", .default = .{ .number = 0.01 }, .minimum = 0, .maximum = 0.3, .group = polar_group },
        .{ .key = "tol", .label = "faixa ótima: T/W até o mínimo +", .default = .{ .number = 5 }, .minimum = 0.5, .maximum = 50, .unit = "%", .group = design_group },
        .{ .key = "grade_ws", .label = "refino: pontos de W/S dos gráficos", .default = .{ .number = 400 }, .minimum = 2, .maximum = 20000, .group = design_group },
        .{ .key = "grade_V", .label = "refino: pontos de V da tração", .default = .{ .number = 50 }, .minimum = 2, .maximum = 1000, .group = design_group, .help = "a tração dos motores é tabelada de 0 a 1,3 × a maior V dos requisitos com estes pontos; o que cada requisito tem de tração sai da interpolação nessa tabela" },
        .{ .key = "eta_p", .label = "eficiência da hélice (para P/m)", .default = .{ .number = 0.6 }, .minimum = 0.2, .maximum = 0.9, .group = design_group },
    };
    const estimated = std.mem.eql(u8, values.text("source", sources[0]), sources[0]);
    const with_estimate = common ++ estimate ++ tail;
    const without_estimate = common ++ tail;
    const params: []const simulation.Param = if (estimated) &with_estimate else &without_estimate;
    try simulation.writeSpecs(out, params, &plots, Sizing.description, .{});
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    const aircraft = run.aircraft;
    state.requirements = .{
        .rho = values.number("rho", aircraft.environment.rho),
        .V_stall = values.number("V_stall", rounded(0.7 * cruise(aircraft), 10)),
        .S_G = values.number("S_G", 50),
        .S_L = values.number("S_L", 0),
        .mu_brake = values.number("mu_brake", aircraft.gear.mu_brake),
        .V_cruise = values.number("V_cruise", rounded(cruise(aircraft), 10)),
        .V_max = values.number("V_max", 0),
        .V_climb = values.number("V_climb", rounded(0.85 * cruise(aircraft), 10)),
        .roc = values.number("roc", 2),
        .climb_grad = values.number("climb_grad", 0),
        .n_turn = values.number("n_turn", 2),
        .V_turn = values.number("V_turn", rounded(cruise(aircraft), 10)),
        .h_ceiling = values.number("h_ceiling", 0),
    };
    state.tolerance_percent = values.number("tol", 5);
    state.grid_points = @intFromFloat(std.math.clamp(@round(values.number("grade_ws", 400)), 2, 20000));
    state.speed_points = @intFromFloat(std.math.clamp(@round(values.number("grade_V", 50)), 2, max_speed_points));
    state.propeller_efficiency = values.number("eta_p", 0.6);
    const rolling = values.number("mu", aircraft.gear.mu_roll);
    const extra_drag = values.number("dCD_TO", 0.01);

    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const info = params_mod.setup(aircraft, instance, &diagnosis) catch |err| {
        run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    const params = &instance.p;
    run.progress = 0.1;

    if (std.mem.eql(u8, values.text("source", sources[0]), sources[0])) {
        const aspect_ratio = values.number("AR", wingAspect(aircraft));
        state.polar = constraints.estimatePolar(values.number("Swet_S", 4), values.number("Cfe", 0.0055), aspect_ratio, values.number("e", 0), values.number("CLmax", 1.4), values.number("CL_TO", 0.5), extra_drag, rolling);
        state.polar_source = try std.fmt.allocPrint(memory, "estimativa: C_D0 = C_fe·S_molhada/S, AR {d}", .{aspect_ratio});
    } else {
        const context = core.trim.Ctx.init(params, &instance.r.f);
        const fitted = performance.corePolar(params, context, .{});
        // o C_L a 0° é o da corrida (como `CL_a0` do ajuste do Python)
        const ground_lift = core.aero.coeffs(params, (performance.PolarSweep{}).speed, 0, 0, context.rcg, .{ 0, 0, 0 }).CL;
        state.polar = .{ .CD0 = fitted.CD0, .k = fitted.K, .CLmax = fitted.CLmax, .CL_TO = ground_lift, .CD_TO = fitted.CD0 + fitted.K * ground_lift * ground_lift + extra_drag, .mu = rolling };
        state.polar_source = "o avião inteiro no núcleo (faixas, a 12 m/s)";
    }

    state.mass = info.mass;
    state.wing_area = params_mod.references(aircraft)[0];
    state.engines = @intCast(params.n_prop);
    const top_speed = 1.3 * @max(state.requirements.V_max, state.requirements.V_cruise, 20.0);
    const last_speed: f64 = @floatFromInt(state.speed_points - 1);
    for (state.speeds[0..state.speed_points], state.thrust[0..state.speed_points], 0..) |*speed, *thrust, k| {
        speed.* = top_speed * @as(f64, @floatFromInt(k)) / last_speed;
        thrust.* = 0;
        for (params.prop[0..state.engines]) |*unit| thrust.* += core.propulsion.point(params, unit, speed.*, 1.0).T;
    }
    state.point = constraints.designPoint(state.requirements, state.polar, state.tolerance_percent / 100);
    run.progress = 1;
}

fn advanceRun(_: *simulation.Run, _: *RunState) simulation.Error!bool {
    return true; // tudo sai no começo (microssegundos)
}

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn pair(memory: std.mem.Allocator, a: f64, b: f64) ![]const f64 {
    return memory.dupe(f64, &.{ a, b });
}

/// a tração por peso disponível em `speed` (interpolada na grade de V)
fn available(state: *const RunState, speed: f64, weight: f64) f64 {
    return constraints.interp(speed, state.speeds[0..state.speed_points], state.thrust[0..state.speed_points]) / weight;
}

/// o que o avião tem na velocidade do requisito (o teto leva a tração à altitude)
fn availableFor(state: *const RunState, kind: Kind, speed: f64, weight: f64) f64 {
    const requirements = state.requirements;
    const factor = if (kind == .teto) std.math.pow(f64, constraints.isaRho(requirements.h_ceiling) / 1.225, requirements.thrust_rho_exp) else 1.0;
    return available(state, speed, weight) * factor;
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    const requirements = state.requirements;
    const polar = state.polar;
    const point = state.point;
    const weight = state.mass * g0;
    const aircraft_loading = weight / state.wing_area;
    const has_engine = state.engines > 0;
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    try summary.append(memory, .{ "polar", state.polar_source });
    try summary.append(memory, .{ "C_D0, k, C_Lmax", try text(memory, "{d:.4}, {d:.4}, {d:.3}", .{ polar.CD0, polar.k, polar.CLmax }) });
    try summary.append(memory, .{ "aeronave: massa (kg), S (m²), W/S (N/m²)", try text(memory, "{d:.3}, {d:.4}, {d:.1}", .{ state.mass, state.wing_area, aircraft_loading }) });

    // a grade de W/S dos gráficos, o envelope de todas as curvas e a altura do gráfico
    const top_loading = @max(1.3 * point.max_loading, 1.15 * aircraft_loading);
    const grid_points = state.grid_points;
    const last_loading: f64 = @floatFromInt(grid_points - 1);
    const loadings = try memory.alloc(f64, grid_points);
    for (loadings, 0..) |*loading, i| loading.* = 0.05 * top_loading + (top_loading - 0.05 * top_loading) * @as(f64, @floatFromInt(i)) / last_loading;
    const top_tw = @min(@max(2.5 * point.thrust_weight, if (has_engine) 1.5 * state.thrust[0] / weight else 0, 0.3), 3.0);

    const figures = try simulation.Figures.init(memory, &plots);
    // a região viável e a faixa ótima, sombreadas do envelope até o topo
    var feasible_x: std.ArrayList(f64) = .empty;
    var feasible_y: std.ArrayList(f64) = .empty;
    var band_x: std.ArrayList(f64) = .empty;
    var band_y: std.ArrayList(f64) = .empty;
    for (loadings) |loading| {
        if (loading > point.max_loading) continue;
        const bottom = @min(constraints.envelope(loading, requirements, polar).thrust_weight, top_tw);
        try feasible_x.append(memory, loading);
        try feasible_y.append(memory, bottom);
        if (loading >= point.band[0] and loading <= point.band[1]) {
            try band_x.append(memory, loading);
            try band_y.append(memory, bottom);
        }
    }
    const feasible_top = try memory.alloc(f64, feasible_x.items.len);
    @memset(feasible_top, top_tw);
    try figures.curve("c", .{ .name = "região viável", .x = feasible_x.items, .y = feasible_y.items, .fill = feasible_top, .color = region_color });
    try figures.curve("c", .{ .name = try text(memory, "faixa ótima (até +{d} %)", .{state.tolerance_percent}), .x = band_x.items, .y = band_y.items, .fill = feasible_top[0..band_x.items.len], .strong = true, .color = best_color });
    for ([_][]const u8{ "início", "fim" }, point.band) |which, loading|
        try figures.curve("c", .{ .name = try text(memory, "faixa ótima: {s} ({d:.0} N/m²)", .{ which, loading }), .x = try pair(memory, loading, loading), .y = try pair(memory, 0, top_tw), .dashed = true, .color = best_color });

    var power_top: f64 = 0;
    for (std.enums.values(Kind)) |kind| {
        if (!kind.active(requirements)) continue;
        const thrust_weight = try memory.alloc(f64, grid_points);
        const power = try memory.alloc(f64, grid_points);
        for (loadings, thrust_weight, power) |loading, *tw, *pw| {
            const needed = constraints.requiredThrustWeight(kind, loading, requirements, polar);
            tw.* = @min(needed, top_tw * 1.05);
            pw.* = @min(needed * constraints.conditionSpeed(kind, loading, requirements, polar) / state.propeller_efficiency * g0, 1e4);
            if (std.math.isFinite(pw.*)) power_top = @max(power_top, pw.*);
        }
        try figures.curve("c", .{ .name = kind.label(), .x = loadings, .y = thrust_weight, .color = kind_color.get(kind) });
        try figures.curve("p", .{ .name = kind.label(), .x = loadings, .y = power, .color = kind_color.get(kind) });
    }
    for (std.enums.values(Limit)) |limit| {
        const loading = constraints.limitLoading(limit, requirements, polar);
        if (!std.math.isFinite(loading)) continue;
        const label = try text(memory, "{s} (limite)", .{limit.label()});
        try figures.curve("c", .{ .name = label, .x = try pair(memory, loading, loading), .y = try pair(memory, 0, top_tw), .dashed = true, .color = limit_color.get(limit) });
        try figures.curve("p", .{ .name = label, .x = try pair(memory, loading, loading), .y = try pair(memory, 0, power_top), .dashed = true, .color = limit_color.get(limit) });
    }
    try figures.curve("c", .{ .name = "ponto de projeto", .x = try memory.dupe(f64, &.{point.wing_loading}), .y = try memory.dupe(f64, &.{point.thrust_weight}), .marker = "o", .color = design_color });
    if (has_engine) try figures.curve("c", .{ .name = "aeronave atual (tração estática)", .x = try memory.dupe(f64, &.{aircraft_loading}), .y = try memory.dupe(f64, &.{state.thrust[0] / weight}), .marker = "o", .color = aircraft_color });
    const design_speed = constraints.conditionSpeed(point.active, point.wing_loading, requirements, polar);
    try figures.curve("p", .{ .name = "ponto de projeto", .x = try memory.dupe(f64, &.{point.wing_loading}), .y = try memory.dupe(f64, &.{point.thrust_weight * design_speed / state.propeller_efficiency * g0}), .marker = "o", .color = design_color });

    // a tração do motor e o que cada requisito pede na W/S do avião
    if (has_engine) {
        const thrust_weight = try memory.alloc(f64, state.speed_points);
        for (thrust_weight, state.thrust[0..state.speed_points]) |*tw, thrust| tw.* = thrust / weight;
        try figures.curve("t", .{ .name = "disponível (acelerador total)", .x = try memory.dupe(f64, state.speeds[0..state.speed_points]), .y = thrust_weight, .color = "#1f77b4" });
    }
    const group = "requisitos";
    var inside = has_engine and aircraft_loading <= point.max_loading;
    for (std.enums.values(Kind)) |kind| {
        if (!kind.active(requirements)) continue;
        const speed = constraints.conditionSpeed(kind, aircraft_loading, requirements, polar);
        const needed = constraints.requiredThrustWeight(kind, aircraft_loading, requirements, polar);
        try figures.curve("t", .{ .name = try text(memory, "pedido: {s}", .{kind.label()}), .x = try memory.dupe(f64, &.{speed}), .y = try memory.dupe(f64, &.{needed}), .marker = "o", .color = kind_color.get(kind) });
        if (!has_engine) continue;
        if (available(state, speed, weight) < needed) inside = false;
        const have = availableFor(state, kind, speed, weight);
        const ok = have >= needed;
        try checks.append(memory, .{
            .status = if (ok) .ok else .falha,
            .item = kind.label(),
            .value = try text(memory, "disponível {d:.3} × exigido {d:.3} a {d:.1} m/s", .{ have, needed, speed }),
            .criterion = "T/W disponível ≥ exigido",
            .why = if (ok) "" else try text(memory, "com W/S = {d:.0} N/m² o motor entrega T/W {d:.3} nessa velocidade", .{ aircraft_loading, have }),
            .fix = if (ok) "" else try text(memory, "tração +{d:.0} % a {d:.1} m/s, ou levar a W/S para a faixa ótima", .{ 100 * (needed / @max(have, 1e-9) - 1), speed }),
            .group = group,
            .source = "Gudmundsson cap. 3; Raymer cap. 5",
        });
    }
    for (std.enums.values(Limit)) |limit| {
        const loading = constraints.limitLoading(limit, requirements, polar);
        if (!std.math.isFinite(loading)) continue;
        const ok = aircraft_loading <= loading;
        try checks.append(memory, .{
            .status = if (ok) .ok else .falha,
            .item = limit.label(),
            .value = try text(memory, "W/S {d:.0} × limite {d:.0} N/m²", .{ aircraft_loading, loading }),
            .criterion = "W/S ≤ limite",
            .why = if (ok) "" else if (limit == .estol) "carga alar alta demais para o C_Lmax" else "a velocidade de toque fica alta para frear na distância pedida",
            .fix = if (ok) "" else try text(memory, "área de asa ≥ {d:.3} m² (hoje {d:.3} m²) ou C_Lmax maior (flape)", .{ weight / loading, state.wing_area }),
            .group = group,
            .source = if (limit == .estol) "Raymer cap. 5" else "Raymer cap. 5 (pouso simplificado)",
        });
    }

    // o projeto
    const design_area = weight / point.wing_loading;
    const smallest_area = weight / point.band[1];
    const largest_area = weight / point.band[0];
    const design_power = point.thrust_weight * design_speed / state.propeller_efficiency * weight;
    try summary.append(memory, .{ "ponto de projeto: W/S (N/m²), T/W, quem manda", try text(memory, "{d:.1}, {d:.4}, {s}", .{ point.wing_loading, point.thrust_weight, point.active.label() }) });
    try summary.append(memory, .{ "faixa ótima: W/S (N/m²) e área de asa (m²)", try text(memory, "{d:.1}, {d:.1}, {d:.4}, {d:.4}", .{ point.band[0], point.band[1], smallest_area, largest_area }) });
    try summary.append(memory, .{ "limite de W/S", try text(memory, "{s} ({d:.0} N/m²)", .{ point.limiter.label(), point.max_loading }) });
    try checks.append(memory, .{
        .status = .info,
        .item = "ponto de projeto (menor motor que atende tudo)",
        .value = try text(memory, "W/S = {d:.0} N/m² → S = {d:.3} m²; T/W = {d:.3} (T = {d:.1} N, P ≈ {d:.0} W)", .{ point.wing_loading, design_area, point.thrust_weight, point.thrust_weight * weight, design_power }),
        .criterion = "acima de todas as curvas, à esquerda dos limites",
        .why = if (point.at_limit) try text(memory, "quem manda: {s}; encostado no limite de {s}", .{ point.active.label(), point.limiter.label() }) else try text(memory, "quem manda: {s}", .{point.active.label()}),
        .fix = try text(memory, "com a massa atual ({d:.2} kg): asa entre {d:.3} e {d:.3} m² fica a até +{d} % do T/W mínimo", .{ state.mass, smallest_area, largest_area, state.tolerance_percent }),
        .group = "projeto",
        .source = "Gudmundsson cap. 3",
    });
    try checks.append(memory, .{
        .status = if (inside) .ok else .falha,
        .item = "aeronave atual dentro da região viável",
        .value = try text(memory, "W/S = {d:.0} N/m², S = {d:.3} m²", .{ aircraft_loading, state.wing_area }),
        .criterion = "todos os requisitos ao mesmo tempo",
        .why = if (inside) "" else "ver os requisitos que falham acima",
        .fix = if (inside) "" else try text(memory, "ponto de projeto: S ≈ {d:.3} m² e T/W ≈ {d:.3} na condição de {s}", .{ design_area, point.thrust_weight, point.active.label() }),
        .group = "projeto",
    });

    try simulation.beginResult(out, summary.items, checks.items);
    try figures.write(out, true);
    try simulation.endResult(out);
}

const testing = std.testing;

test "Diagrama de restrições: o ponto de projeto e a aeronave batem com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Sizing);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {}"));
    try testing.expect(try registered.advance(&run));
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 3), outcome.value.object.get("plots").?.array.items.len);
    const state: *RunState = @ptrCast(@alignCast(run.state.?));
    // os números do Python (`sizing.py`, Convencional_original, campos padrão)
    try testing.expectApproxEqAbs(@as(f64, expected_mass), state.mass, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, expected_ws), state.point.wing_loading, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, expected_tw), state.point.thrust_weight, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, expected_static_thrust), state.thrust[0], 1e-6);
}

const expected_mass = 12.39;
const expected_ws = 61.164923852253764;
const expected_tw = 0.22837732726534005;
const expected_static_thrust = 0.22684750903424913 * 12.39 * 9.80665;

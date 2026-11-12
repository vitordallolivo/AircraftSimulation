//! A aerodinâmica do avião inteiro em Zig (o par de `aerodynamics.py`, a parte "avião completo" do Analisar): as
//! polares e as derivadas pelos métodos do núcleo (as faixas da simulação e as duas linhas sustentadoras), as métricas
//! de cada polar (C_Lα, C_Lmax, L/D, Oswald, ponto neutro), o diagnóstico (estol × cruzeiro, cruzeiro × L/D máximo,
//! concordância dos métodos) e as curvas do avião inteiro com o profundor e a derrapagem, como a simulação usa.
//!
//! O estudo das pontas de asa (winglet, placa, caixa e asa em C pelo plano de Trefftz, com o atrito descontado) é o
//! do núcleo (`core/src/loads/trefftz.zig`). Os métodos de fora do núcleo (lltdrek, AeroSandbox, AVL) rodam pelo
//! Python quando são marcados (`wings.zig`, `needsPython`).
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const wings = @import("wings.zig");
const stability = @import("stability.zig");
const trefftz = core.trefftz;

const params_mod = aircraft_model.params;
const model = aircraft_model.aircraft;
const rad = std.math.pi / 180.0;
const g0 = 9.80665;

/// os métodos de polar do núcleo (`ZigPanelSolver` e `CoreLLTSolver` do Python)
pub const Solver = enum {
    zig,
    zig_llt_gh,
    zig_llt,

    /// o rótulo das curvas e do resumo (`LABEL` de `aerodynamics.py`)
    pub fn label(solver: Solver) []const u8 {
        return switch (solver) {
            .zig => "modelo interno",
            .zig_llt_gh => "LLT do núcleo (G-H)",
            .zig_llt => "LLT do núcleo (P-S)",
        };
    }

    /// o método de carga com os mesmos parâmetros do núcleo
    fn loadMethod(solver: Solver) wings.LoadMethod {
        return switch (solver) {
            .zig => .faixas,
            .zig_llt_gh => .llt_gh,
            .zig_llt => .llt,
        };
    }

    /// por que dois métodos dão números diferentes (`_why_differ` de `aerodynamics.py`)
    fn note(solver: Solver) []const u8 {
        return switch (solver) {
            .zig => "núcleo: faixas com C_Lα de Helmbold, downwash ε0 + dε/dα α, fuselagem por coeficientes",
            .zig_llt => "linha sustentadora do núcleo (Phillips e Snyder): sem estol; não converge em β nem com enflechamento",
            .zig_llt_gh => "linha sustentadora do núcleo (Goates e Hunsaker): sem estol; fuselagem como na simulação",
        };
    }
};

/// as derivadas que cada polar dá (`DERIVATIVES` de `aerosim/interfaces/aero.py`)
pub const Derivative = enum { CLa, Cma, CYb, Clb, Cnb, CLq, Cmq, CYp, Clp, Cnp, CYr, Clr, Cnr, CLde, Cmde, Clda, Cnda, CYdr, Cldr, Cndr };

/// o caso de uma polar (`AeroCase`): velocidade, os α, o α das derivadas, o ponto dos momentos e as faixas da LLT
pub const Case = struct {
    airspeed: f64,
    alphas: []const f64, // graus
    alpha_derivatives: f64, // graus
    reference: [3]f64,
    per_side: usize = 12,
};

/// a polar de um método: C_L, C_D, C_m e a parte induzida em cada α, mais as derivadas no α das derivadas
pub const Polar = struct {
    solver: Solver,
    alphas: []const f64,
    lift: []f64,
    drag: []f64,
    moment: []f64,
    induced: []f64,
    derivatives: std.EnumArray(Derivative, f64),

    /// L/D em cada α (NaN onde C_D ≤ 0)
    pub fn efficiency(polar: Polar, memory: std.mem.Allocator) ![]f64 {
        const out = try memory.alloc(f64, polar.lift.len);
        for (out, polar.lift, polar.drag) |*value, lift, drag| value.* = if (drag > 0) lift / drag else std.math.nan(f64);
        return out;
    }
};

/// S, c, b e o bordo de ataque da CMA do avião (a referência das métricas)
pub const Reference = struct { area: f64, chord: f64, span: f64, mac_le: f64 };

/// a referência do avião, como o modelo universal do Python
pub fn reference(aircraft: *const simulation.Aircraft) Reference {
    const values = params_mod.references(aircraft);
    return .{ .area = values[0], .chord = values[1], .span = values[2], .mac_le = params_mod.macLeadingEdge(aircraft) };
}

/// o avião com todas as superfícies em `per_side` faixas por lado, mais estreitas na ponta, ou no maior número que cabe
/// no limite de painéis do núcleo (`refine_all` de `span_loads.py`)
fn refinedAll(memory: std.mem.Allocator, plane: simulation.Aircraft, per_side: usize, params: *core.types.Params) !simulation.Aircraft {
    var count = @min(per_side, wings.max_per_side);
    while (count > 0) : (count -= 1) {
        var candidate = plane;
        for (0..plane.surfaces.len) |index| candidate = try wings.refined(memory, candidate, index, count, true);
        if (wings.fits(&candidate, params)) return candidate;
    }
    return plane;
}

/// os coeficientes de um ponto: pelas faixas ou pela linha sustentadora (`aero_coeffs_ex`, `aero_coeffs_llt`)
fn evaluate(params: *const core.types.Params, solver: Solver, airspeed: f64, reference_point: [3]f64, point: Point) core.types.AeroCoeffs {
    const ref: core.vec.V3 = reference_point;
    const references = .{ params.bref, params.cref };
    const rates: core.vec.V3 = .{ point.roll * 2 * airspeed / references[0], point.pitch * 2 * airspeed / references[1], point.yaw * 2 * airspeed / references[0] };
    const deflections: core.vec.V3 = .{ point.elevator, point.aileron, point.rudder };
    return switch (solver) {
        .zig => core.aero.coeffsEx(params, airspeed, point.alpha, point.beta, rates, ref, deflections),
        .zig_llt, .zig_llt_gh => core.llt.coeffs(params, airspeed, point.alpha, point.beta, rates, ref, deflections, 50.0, null),
    };
}

/// um ponto de voo (`FlightPoint`): α e β em rad, as taxas adimensionais (p̂ = p b/2V...) e os comandos em rad
const Point = struct { alpha: f64, beta: f64 = 0, roll: f64 = 0, pitch: f64 = 0, yaw: f64 = 0, elevator: f64 = 0, aileron: f64 = 0, rudder: f64 = 0 };

const angle_step = 0.5 * rad; // `DA` de `aerosim/aero/base.py`
const rate_step = 0.01; // `DH`

/// a variável de uma derivada por diferença central, o passo e as saídas (`_PLAN` de `aerosim/aero/base.py`)
const Variation = struct { field: []const u8, step: f64, outputs: []const Derivative };
const plan = [_]Variation{
    .{ .field = "alpha", .step = angle_step, .outputs = &.{ .CLa, .Cma } },
    .{ .field = "beta", .step = angle_step, .outputs = &.{ .CYb, .Clb, .Cnb } },
    .{ .field = "roll", .step = rate_step, .outputs = &.{ .CYp, .Clp, .Cnp } },
    .{ .field = "pitch", .step = rate_step, .outputs = &.{ .CLq, .Cmq } },
    .{ .field = "yaw", .step = rate_step, .outputs = &.{ .CYr, .Clr, .Cnr } },
    .{ .field = "elevator", .step = angle_step, .outputs = &.{ .CLde, .Cmde } },
    .{ .field = "aileron", .step = angle_step, .outputs = &.{ .Clda, .Cnda } },
    .{ .field = "rudder", .step = angle_step, .outputs = &.{ .CYdr, .Cldr, .Cndr } },
};

/// o coeficiente que a derivada mede (C_L em C_Lα, C_n em C_nβ...)
fn coefficientOf(derivative: Derivative, coefficients: core.types.AeroCoeffs) f64 {
    const name = @tagName(derivative);
    if (std.mem.startsWith(u8, name, "CL")) return coefficients.CL;
    if (std.mem.startsWith(u8, name, "CY")) return coefficients.CY;
    if (std.mem.startsWith(u8, name, "Cm")) return coefficients.Cm;
    if (std.mem.startsWith(u8, name, "Cl")) return coefficients.Cl;
    return coefficients.Cn;
}

/// a polar e as derivadas de um método do núcleo (`AeroSolverBase.solve`): a varredura em α e as diferenças centrais
/// no α das derivadas
pub fn solve(run: *simulation.Run, plane: simulation.Aircraft, solver: Solver, case: Case) !Polar {
    const memory = run.memory();
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    const fine = if (solver == .zig) plane else try refinedAll(memory, plane, case.per_side, &instance.p);
    instance.* = .{};
    try wings.configure(run, instance, &fine, solver.loadMethod());
    const params = &instance.p;
    const count = case.alphas.len;
    var polar: Polar = .{
        .solver = solver,
        .alphas = case.alphas,
        .lift = try memory.alloc(f64, count),
        .drag = try memory.alloc(f64, count),
        .moment = try memory.alloc(f64, count),
        .induced = try memory.alloc(f64, count),
        .derivatives = std.EnumArray(Derivative, f64).initFill(std.math.nan(f64)),
    };
    for (case.alphas, 0..) |alpha, k| {
        const coefficients = evaluate(params, solver, case.airspeed, case.reference, .{ .alpha = alpha * rad });
        polar.lift[k] = coefficients.CL;
        polar.drag[k] = coefficients.CD;
        polar.moment[k] = coefficients.Cm;
        polar.induced[k] = coefficients.CDi;
    }
    const base = case.alpha_derivatives * rad;
    inline for (plan) |variation| {
        var plus: Point = .{ .alpha = base };
        var minus: Point = .{ .alpha = base };
        @field(plus, variation.field) += variation.step;
        @field(minus, variation.field) -= variation.step;
        const high = evaluate(params, solver, case.airspeed, case.reference, plus);
        const low = evaluate(params, solver, case.airspeed, case.reference, minus);
        for (variation.outputs) |output| polar.derivatives.set(output, (coefficientOf(output, high) - coefficientOf(output, low)) / (2 * variation.step));
    }
    return polar;
}

/// a reta dos mínimos quadrados y = a x + b (`np.polyfit(x, y, 1)`); null com menos de dois pontos
fn line(xs: []const f64, ys: []const f64) ?[2]f64 {
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (xs, ys) |x, y| {
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
    }
    const n: f64 = @floatFromInt(xs.len);
    const denominator = n * sxx - sx * sx;
    if (xs.len < 2 or denominator == 0) return null;
    const slope = (n * sxy - sx * sy) / denominator;
    return .{ slope, (sy - slope * sx) / n };
}

/// as métricas de uma polar (`polar_metrics`): null onde não dá para tirar
pub const Metrics = struct {
    lift_zero: ?f64 = null, // C_L0
    lift_slope: ?f64 = null, // C_Lα da reta de −2° a 6° (1/rad)
    lift_max: ?f64 = null,
    alpha_stall: ?f64 = null,
    drag_min: ?f64 = null,
    efficiency_max: ?f64 = null, // (L/D) máx.
    oswald: ?f64 = null, // e, da reta C_Di × C_L²
    neutral_point: ?f64 = null, // x (m)
    neutral_percent: ?f64 = null, // % da CMA
    static_margin: ?f64 = null, // % da CMA
};

/// C_L0, C_Lα, C_Lmax, α de estol, C_D mín., (L/D) máx., e (C_Di = C_L²/(π AR e)), o ponto neutro
/// x_np = x_ref + c C_mα / C_Lα e a margem estática (x_ref − x_np)/c (`polar_metrics` de `aerosim/aero/__init__.py`)
pub fn metrics(memory: std.mem.Allocator, polar: Polar, geometry: Reference, reference_x: f64) !Metrics {
    var out: Metrics = .{};
    var slope_x: std.ArrayList(f64) = .empty;
    var slope_y: std.ArrayList(f64) = .empty;
    var induced_x: std.ArrayList(f64) = .empty;
    var induced_y: std.ArrayList(f64) = .empty;
    for (polar.alphas, polar.lift, polar.induced) |alpha, lift, induced| {
        if (!std.math.isFinite(lift)) continue;
        const linear = alpha >= -2.0 and alpha <= 6.0;
        if (linear) {
            try slope_x.append(memory, alpha * rad);
            try slope_y.append(memory, lift);
        }
        if (linear and std.math.isFinite(induced) and @abs(lift) > 0.15) {
            try induced_x.append(memory, lift * lift);
            try induced_y.append(memory, induced);
        }
    }
    if (line(slope_x.items, slope_y.items)) |fit| {
        out.lift_slope = fit[0];
        out.lift_zero = fit[1];
    }
    for (polar.alphas, polar.lift, polar.drag) |alpha, lift, drag| {
        if (!std.math.isFinite(lift)) continue;
        if (out.lift_max == null or lift > out.lift_max.?) {
            out.lift_max = lift;
            out.alpha_stall = alpha;
        }
        out.drag_min = if (out.drag_min) |least| @min(least, drag) else drag;
        if (drag > 0) out.efficiency_max = if (out.efficiency_max) |best| @max(best, lift / drag) else lift / drag;
    }
    const aspect = geometry.span * geometry.span / geometry.area;
    if (line(induced_x.items, induced_y.items)) |fit| {
        if (fit[0] > 0) out.oswald = 1.0 / (std.math.pi * aspect * fit[0]);
    }
    const slope = polar.derivatives.get(.CLa);
    const moment = polar.derivatives.get(.Cma);
    if (std.math.isFinite(slope) and std.math.isFinite(moment) and @abs(slope) > 1e-9) {
        const neutral = reference_x + geometry.chord * moment / slope;
        out.neutral_point = neutral;
        out.neutral_percent = 100 * (geometry.mac_le - neutral) / geometry.chord;
        out.static_margin = 100 * (reference_x - neutral) / geometry.chord;
    }
    return out;
}

const raymerOswald = trefftz.raymerOswald;

// ------------------------------------------------------------------ os campos e os gráficos do avião completo

pub const group = "Avião completo (fuselagem, massa e CG)";
const group_full = "Avião completo (fuselagem, massa e CG): polar da aeronave completa (núcleo 6GDL)";
const group_tips = "Avião completo (fuselagem, massa e CG): dispositivos de asa";
const group_criteria = "Avião completo (fuselagem, massa e CG): critérios de aprovação";
const group_ground = "Avião completo (fuselagem, massa e CG): efeito solo";

/// a velocidade de cruzeiro do avião: a maior da missão (`_cruise_speed` de `stability.py`)
pub fn cruise(aircraft: *const simulation.Aircraft) f64 {
    var speed: f64 = 0;
    for (aircraft.mission.legs) |leg| if (leg.V) |value| {
        speed = @max(speed, value);
    };
    return if (speed > 0) speed else 15;
}

/// o avião está pronto para a análise inteira: tem superfície e massa (`not_ready` de `templates.py`)
pub fn ready(aircraft: *const simulation.Aircraft) bool {
    return aircraft.surfaces.len > 0 and params_mod.dryMass(aircraft).m > 0;
}

/// os campos do avião completo (`AerodynamicsSimulation.parameters_for`, sem os que vêm do Analisar)
pub fn appendFields(memory: std.mem.Allocator, params: *std.ArrayList(simulation.Param), aircraft: ?*const simulation.Aircraft) !void {
    const speed = if (aircraft) |plane| @round(cruise(plane) * 10) / 10 else 15;
    try params.appendSlice(memory, &.{
        .{ .key = "V_cruise", .label = "velocidade de cruzeiro", .default = .{ .number = speed }, .minimum = 3, .maximum = 80, .unit = "m/s", .group = group },
        .{ .key = "alpha_d", .label = "α das derivadas", .default = .{ .number = 2 }, .minimum = -5, .maximum = 12, .unit = "°", .group = group },
        .{ .key = "xcg", .label = "CG dos momentos", .default = .{ .number = -1 }, .minimum = -1, .maximum = 100, .unit = "% CMA", .group = group, .help = "−1: o da aeronave; em % da CMA a partir do bordo de ataque" },
        .{ .key = "full", .label = "aeronave inteira (δe e β)", .kind = .bool, .default = .{ .toggle = true }, .group = group_full, .help = "curvas da aeronave inteira com profundor e derrapagem, como a simulação usa" },
        .{ .key = "de", .label = "δe para comparar", .default = .{ .number = 10 }, .minimum = 0, .maximum = 30, .unit = "°", .group = group_full },
        .{ .key = "alpha_beta", .label = "α da varredura em β", .default = .{ .number = 4 }, .minimum = -5, .maximum = 15, .unit = "°", .group = group_full },
        .{ .key = "tips", .label = "explorar pontas de asa", .kind = .bool, .default = .{ .toggle = false }, .group = group_tips, .help = "winglet, placa, caixa e asa em C pelo plano de Trefftz, com o atrito descontado" },
        .{ .key = "hb_max", .label = "altura máxima estudada (h/b)", .default = .{ .number = 0.25 }, .minimum = 0.05, .maximum = 1, .group = group_tips },
        .{ .key = "Cf", .label = "coeficiente de atrito do dispositivo", .default = .{ .number = 0.006 }, .minimum = 0, .maximum = 0.05, .group = group_tips },
        .{ .key = "ground", .label = "estudar o efeito solo", .kind = .bool, .default = .{ .toggle = false }, .group = group_ground, .help = "C_L, C_Di e C_m do avião inteiro contra a altura da asa ao chão, pelo VLM com o chão espelhado, comparados com o fator de McCormick que a simulação usa" },
        .{ .key = "alpha_ground", .label = "α no solo", .default = .{ .number = 4 }, .minimum = -5, .maximum = 15, .unit = "°", .group = group_ground, .help = "o ângulo de ataque do avião durante o estudo (o da corrida ou da rotação)" },
        .{ .key = "hb_ground_max", .label = "altura máxima da asa (h/b)", .default = .{ .number = 1 }, .minimum = 0.1, .maximum = 3, .group = group_ground },
        .{ .key = "dev_gain", .label = "ganho mín. do dispositivo", .default = .{ .number = 0.5 }, .minimum = 0, .maximum = 20, .unit = "%", .group = group_criteria, .help = "o dispositivo de ponta compensa se reduzir o arrasto ao menos isto" },
        .{ .key = "tol_CLa", .label = "tolerância C_Lα e C_Lmax", .default = .{ .number = 12 }, .minimum = 1, .maximum = 100, .unit = "%", .group = group_criteria, .help = "diferença aceita entre os métodos" },
        .{ .key = "tol_np", .label = "tolerância ponto neutro", .default = .{ .number = 5 }, .minimum = 0.5, .maximum = 50, .unit = "% CMA", .group = group_criteria, .help = "diferença aceita entre os métodos" },
        .{ .key = "Vs_ratio", .label = "V de cruzeiro / V de estol mínima", .default = .{ .number = 1.3 }, .minimum = 1, .maximum = 3, .group = group_criteria },
        .{ .key = "LD_frac", .label = "L/D mín. no cruzeiro", .default = .{ .number = 90 }, .minimum = 10, .maximum = 100, .unit = "%", .group = group_criteria, .help = "fração do L/D máximo" },
    });
}

/// os gráficos do avião completo (os de `AerodynamicsSimulation.plots_for` com "ac_" na chave)
pub const plots = [_]simulation.Plot{
    .{ .key = "ac_CL", .title = "Avião completo: sustentação × ângulo de ataque", .xlabel = "α (°)", .ylabel = "C_L" },
    .{ .key = "ac_CD", .title = "Avião completo: polar de arrasto", .xlabel = "C_D", .ylabel = "C_L" },
    .{ .key = "ac_Cm", .title = "Avião completo: C_m no CG × α (tem de descer)", .xlabel = "α (°)", .ylabel = "C_m" },
    .{ .key = "ac_LD", .title = "Avião completo: L/D × C_L", .xlabel = "C_L", .ylabel = "L/D" },
    .{ .key = "ac_pa_CL", .title = "Aeronave completa: C_L × α com o profundor", .xlabel = "α (°)", .ylabel = "C_L" },
    .{ .key = "ac_pa_Cm", .title = "Aeronave completa: C_m no CG × α com o profundor", .xlabel = "α (°)", .ylabel = "C_m" },
    .{ .key = "ac_pa_CD", .title = "Aeronave completa: polar de arrasto", .xlabel = "C_D", .ylabel = "C_L" },
    .{ .key = "ac_pa_b", .title = "Aeronave completa: látero-direcional × β", .xlabel = "β (°)", .ylabel = "coeficiente (—)" },
    .{ .key = "ac_tip_e", .title = "Avião completo: ganho de eficiência de envergadura × altura do dispositivo", .xlabel = "altura do dispositivo / envergadura (h/b)", .ylabel = "e / e sem dispositivo" },
    .{ .key = "ac_gnd_CL", .title = "Efeito solo: C_L e C_Di relativos × altura", .xlabel = "altura da asa / envergadura (h/b)", .ylabel = "com chão / sem chão" },
    .{ .key = "ac_gnd_Cm", .title = "Efeito solo: ΔC_m no CG × altura", .xlabel = "altura da asa / envergadura (h/b)", .ylabel = "ΔC_m" },
    .{ .key = "ac_tip_d", .title = "Avião completo: variação do arrasto total no cruzeiro × altura (com atrito)", .xlabel = "altura do dispositivo / envergadura (h/b)", .ylabel = "ΔD (% do arrasto total)" },
};

const solver_colors = [_][]const u8{ "#000000", "#1f77b4", "#d62728" };

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

/// o que o avião completo deixa no resultado do Analisar
pub const Output = struct {
    summary: *std.ArrayList([2][]const u8),
    checks: *std.ArrayList(simulation.Check),
    figures: simulation.Figures,
};

/// o avião aberto inteiro, como a antiga subaba Avião montado (`AerodynamicsSimulation.run`), pelos métodos do
/// núcleo marcados: as polares no CG, as métricas, o diagnóstico e as curvas com o profundor e a derrapagem
pub fn analyze(run: *simulation.Run, values: simulation.Values, chosen: []const Solver, output: Output) !void {
    const memory = run.memory();
    const aircraft = run.aircraft;
    const summary = output.summary;
    const checks = output.checks;
    if (!ready(aircraft)) {
        try checks.append(memory, .{ .status = .info, .item = "avião completo", .value = "não analisado", .why = "o avião ainda não tem superfície ou massa", .group = "avião completo" });
        return;
    }
    const geometry = reference(aircraft);
    const aspect = geometry.span * geometry.span / geometry.area;
    // o ponto dos momentos: o CG da aeronave ou um x em % da CMA, na altura do CG
    const probe = try memory.create(core.runner.Instance);
    probe.* = .{};
    try wings.configure(run, probe, aircraft, .faixas);
    const balance = core.trim.Ctx.init(&probe.p, &probe.r.f);
    const xcg = values.number("xcg", -1);
    const reference_point: [3]f64 = .{ if (xcg >= 0) geometry.mac_le - xcg / 100 * geometry.chord else balance.rcg[0], 0, balance.rcg[2] };
    const mass = balance.m;
    const airspeed = values.number("V_cruise", cruise(aircraft));
    const density = aircraft.environment.rho;
    const cruise_lift = mass * g0 / (0.5 * density * airspeed * airspeed * geometry.area);
    const first = values.number("a0", -4);
    const last = values.number("a1", 22);
    const step = @max(values.number("da", 1), 0.05);
    const count: usize = @intFromFloat(@floor((last - first + 1e-9) / step) + 1);
    const alphas = try memory.alloc(f64, count);
    for (alphas, 0..) |*alpha, k| alpha.* = first + step * @as(f64, @floatFromInt(k));
    const case: Case = .{ .airspeed = airspeed, .alphas = alphas, .alpha_derivatives = values.number("alpha_d", 2), .reference = reference_point, .per_side = @intFromFloat(@max(values.number("n_span", 12), 1)) };

    const prefix = "avião completo · ";
    try summary.append(memory, .{ prefix ++ "CG dos momentos (m, % CMA)", try text(memory, "{d:.4}, {d:.1}", .{ reference_point[0], 100 * (geometry.mac_le - reference_point[0]) / geometry.chord }) });
    try summary.append(memory, .{ prefix ++ "S, c, b de referência; AR", try text(memory, "{d:.4}, {d:.4}, {d:.4}; {d:.3}", .{ geometry.area, geometry.chord, geometry.span, aspect }) });
    try summary.append(memory, .{ prefix ++ "C_L de cruzeiro (W/qS)", try text(memory, "{d:.4}", .{cruise_lift}) });

    var polars: std.ArrayList(Polar) = .empty;
    var all_metrics: std.ArrayList(Metrics) = .empty;
    var best_efficiency: f64 = 0;
    for (chosen, 0..) |solver, k| {
        const polar = solve(run, aircraft.*, solver, case) catch |err| {
            try checks.append(memory, .{ .status = .atencao, .item = try text(memory, "{s} falhou", .{solver.label()}), .value = @errorName(err), .group = "métodos" });
            continue;
        };
        const found = try metrics(memory, polar, geometry, reference_point[0]);
        try polars.append(memory, polar);
        try all_metrics.append(memory, found);
        const label = solver.label();
        const color = solver_colors[k % solver_colors.len];
        const efficiency = try polar.efficiency(memory);
        for (efficiency) |value| if (std.math.isFinite(value)) {
            best_efficiency = @max(best_efficiency, value);
        };
        try output.figures.curve("ac_CL", .{ .name = label, .x = alphas, .y = polar.lift, .color = color, .width = 2 });
        try output.figures.curve("ac_CD", .{ .name = label, .x = polar.drag, .y = polar.lift, .color = color, .width = 2 });
        try output.figures.curve("ac_Cm", .{ .name = label, .x = alphas, .y = polar.moment, .color = color, .width = 2 });
        try output.figures.curve("ac_LD", .{ .name = label, .x = polar.lift, .y = efficiency, .color = color, .width = 2 });
        try appendMetrics(memory, summary, try text(memory, "{s}[{s}] ", .{ prefix, label }), found);
        try summary.append(memory, .{ try text(memory, "{s}[{s}] derivadas (1/rad)", .{ prefix, label }), try derivativeText(memory, polar) });
    }
    if (polars.items.len > 0) {
        try output.figures.curve("ac_LD", .{ .name = "C_L de cruzeiro", .x = try memory.dupe(f64, &.{ cruise_lift, cruise_lift }), .y = try memory.dupe(f64, &.{ 0, best_efficiency }), .color = "#7f7f7f", .dashed = true });
    }
    if (polars.items.len == 0) {
        try checks.append(memory, .{ .status = .falha, .item = "nenhum método rodou", .value = "—", .fix = "marque o modelo interno ou uma linha sustentadora do núcleo", .group = "métodos" });
        return;
    }
    try diagnose(memory, values, polars.items, all_metrics.items, .{ .cruise_lift = cruise_lift, .airspeed = airspeed, .density = density, .mass = mass, .area = geometry.area, .aspect = aspect }, checks);
    if (values.toggle("full", true)) try fullCurves(run, values, airspeed, output);
    if (values.toggle("ground", false)) groundStudy(run, values, geometry, reference_point, output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try checks.append(memory, .{ .status = .atencao, .item = "efeito solo", .value = @errorName(err), .why = "o VLM com o chão não rodou", .group = "efeito solo" }),
    };
    if (values.toggle("tips", false)) {
        const drag_min = found_min: {
            var least = std.math.inf(f64);
            for (polars.items[0].drag) |drag| if (std.math.isFinite(drag)) {
                least = @min(least, drag);
            };
            break :found_min if (std.math.isFinite(least)) least else 0.03;
        };
        const planform = @min(all_metrics.items[0].oswald orelse raymerOswald(aspect), 1.0);
        try tipStudy(run, values, geometry, cruise_lift, drag_min, planform, output);
    }
}

/// a malha do VLM do estudo do efeito solo e o maior número de painéis que ele aceita
const ground_grid: core.vlm.Grid = .{ .chordwise = 4, .spanwise = 2 };
const ground_max_panels = 1200;

/// o estudo do efeito solo: o VLM com o chão espelhado (`core.vlm.groundCoefficients`) em várias alturas da asa,
/// com o avião girado pelo α no solo em torno do CG. Mostra C_L e C_Di relativos aos de sem chão, o fator de McCormick
/// que a simulação usa no induzido, e a variação do C_m no CG (que muda a rotação)
fn groundStudy(run: *simulation.Run, values: simulation.Values, geometry: Reference, reference_point: [3]f64, output: Output) !void {
    const memory = run.memory();
    const params = try memory.create(core.types.Params);
    params.* = .{};
    var diagnosis: model.Diag = .{};
    try params_mod.fill(run.aircraft, params, &diagnosis);
    core.aero.init(params);
    const count = core.vlm.panelCount(params, ground_grid);
    if (count == 0 or count > ground_max_panels) {
        try output.checks.append(memory, .{ .status = .atencao, .item = "efeito solo", .value = "não estudado", .why = try text(memory, "a malha do VLM teria {d} painéis (o limite é {d})", .{ count, ground_max_panels }), .group = "efeito solo" });
        return;
    }
    const buffers: core.vlm.Buffers = .{ .panels = try memory.alloc(core.vlm.Panel, count), .matrix = try memory.alloc(f64, count * count), .pivots = try memory.alloc(usize, count), .gamma = try memory.alloc(f64, count) };
    const alpha = values.number("alpha_ground", 4) * rad;
    const ref: core.vec.V3 = reference_point;
    // a altura da asa: a do centro de área das faixas da asa, girado por α em torno do CG
    var area: f64 = 0;
    var center: core.vec.V3 = core.vec.zero;
    const n_surf: usize = @intCast(@max(params.n_surf, 0));
    for (params.surf[0..n_surf]) |*surface| if (surface.group == .wing) {
        area += surface.S;
        center += core.vec.v3(surface.r) * core.vec.splat(surface.S);
    };
    if (area <= 0) return;
    center /= core.vec.splat(area);
    const relative = center - ref;
    const wing_above_cg = @sin(alpha) * relative[0] - @cos(alpha) * relative[2]; // z para baixo: acima é −z girado
    const free = try core.vlm.groundCoefficients(params, ground_grid, alpha, std.math.inf(f64), ref, buffers);
    const points = 16;
    const top = values.number("hb_ground_max", 1);
    const heights = try memory.alloc(f64, points);
    const lift_ratio = try memory.alloc(f64, points);
    const induced_ratio = try memory.alloc(f64, points);
    const mccormick_ratio = try memory.alloc(f64, points);
    const moment_change = try memory.alloc(f64, points);
    const tail_change = try memory.alloc(f64, points);
    const lowest = 0.05;
    for (0..points) |k| {
        // mais pontos perto do chão, onde o efeito muda depressa
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(points - 1));
        const height_ratio = lowest + (top - lowest) * t * t;
        const wing_height = height_ratio * geometry.span;
        const near = try core.vlm.groundCoefficients(params, ground_grid, alpha, wing_height + wing_above_cg, ref, buffers);
        heights[k] = height_ratio;
        lift_ratio[k] = near.CL / free.CL;
        induced_ratio[k] = (near.CDi / (near.CL * near.CL)) / (free.CDi / (free.CL * free.CL));
        mccormick_ratio[k] = core.modifiers.ground.mccormick(wing_height, geometry.span);
        moment_change[k] = near.Cm - free.Cm;
        tail_change[k] = near.CL_htail - free.CL_htail;
    }
    const one = try memory.dupe(f64, &.{ heights[0], heights[points - 1] });
    try output.figures.curve("ac_gnd_CL", .{ .name = "C_L (VLM com chão)", .x = heights, .y = lift_ratio, .color = "#1f77b4", .width = 2 });
    try output.figures.curve("ac_gnd_CL", .{ .name = "C_Di/C_L² (VLM com chão)", .x = heights, .y = induced_ratio, .color = "#d62728", .width = 2 });
    try output.figures.curve("ac_gnd_CL", .{ .name = "McCormick (o da simulação)", .x = heights, .y = mccormick_ratio, .color = "#d62728", .dashed = true });
    try output.figures.curve("ac_gnd_CL", .{ .name = "sem chão", .x = one, .y = try memory.dupe(f64, &.{ 1, 1 }), .color = "#7f7f7f", .dashed = true, .legend = false });
    try output.figures.curve("ac_gnd_Cm", .{ .name = "ΔC_m no CG", .x = heights, .y = moment_change, .color = "#1f77b4", .width = 2 });
    try output.figures.curve("ac_gnd_Cm", .{ .name = "ΔC_L da EH", .x = heights, .y = tail_change, .color = "#2ca02c", .width = 2 });
    const prefix = "efeito solo · ";
    try output.summary.append(memory, .{ prefix ++ "α, altura da asa acima do CG (m)", try text(memory, "{d:.1}°, {d:.3}", .{ alpha / rad, wing_above_cg }) });
    try output.summary.append(memory, .{ prefix ++ "C_L, C_Di, C_m sem chão (VLM)", try text(memory, "{d:.4}, {d:.5}, {d:.4}", .{ free.CL, free.CDi, free.Cm }) });
    try output.summary.append(memory, .{ prefix ++ "no h/b mais baixo: C_L, C_Di/C_L² (VLM), McCormick, ΔC_m", try text(memory, "×{d:.3}, ×{d:.3}, ×{d:.3}, {d:.4}", .{ lift_ratio[0], induced_ratio[0], mccormick_ratio[0], moment_change[0] }) });
}

/// a corda da ponta da asa principal (a última seção)
fn tipChord(aircraft: *const simulation.Aircraft, fallback: f64) f64 {
    const wing = params_mod.firstSurface(aircraft, "wing") orelse return fallback;
    var outer: ?model.Section = null;
    for (wing.sections) |section| if (outer == null or section.y > outer.?.y) {
        outer = section;
    };
    return if (outer) |section| section.chord else fallback;
}

/// o estudo das pontas de asa pelo plano de Trefftz (`_tips` de `aerodynamics.py`): o e ideal de cada dispositivo
/// genérico e a variação do arrasto total no cruzeiro, com o atrito da área molhada, contra as extensões de ponta
fn tipStudy(run: *simulation.Run, values: simulation.Values, geometry: Reference, cruise_lift: f64, drag_min: f64, planform: f64, output: Output) !void {
    const memory = run.memory();
    const devices_group = "dispositivos de asa";
    const configuration = stability.detectConfiguration(run.aircraft);
    var has_devices = configuration.tip_count > 0;
    if (params_mod.firstSurface(run.aircraft, "wing")) |wing| has_devices = has_devices or wing.devices.len > 0;
    const aspect = geometry.span * geometry.span / geometry.area;
    const induced = cruise_lift * cruise_lift / (std.math.pi * aspect * planform);
    const share = induced / (drag_min + induced);
    const gain = values.number("dev_gain", 0.5);
    const work = try memory.create(trefftz.Workspace);
    const study: trefftz.Study = .{ .span = geometry.span, .area = geometry.area, .lift = cruise_lift, .tip_chord = tipChord(run.aircraft, geometry.chord), .planform = planform, .friction = values.number("Cf", 0.006) };
    const count = 11;
    const heights = try memory.alloc(f64, count);
    const kinds = [_]trefftz.Kind{ .winglet, .placa, .caixa, .asa_c };
    var factor_columns: [kinds.len][]f64 = undefined;
    var drag_columns: [kinds.len][]f64 = undefined;
    for (&factor_columns, &drag_columns) |*factors, *drags| {
        factors.* = try memory.alloc(f64, count);
        drags.* = try memory.alloc(f64, count);
    }
    const same_moment = try memory.alloc(f64, count);
    const top = values.number("hb_max", 0.25);
    for (heights, 0..) |*height, k| {
        height.* = top * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count - 1));
        const point = trefftz.studyPoint(work, study, height.*) catch |err| {
            try output.checks.append(memory, .{ .status = .atencao, .item = "estudo das pontas", .value = @errorName(err), .why = "o traço passou do limite de painéis do núcleo", .fix = "diminua a altura máxima estudada", .group = devices_group });
            return;
        };
        for (kinds, 0..) |kind, j| {
            factor_columns[j][k] = point.efficiency.get(kind);
            drag_columns[j][k] = point.drag_change.get(kind) * share;
        }
        same_moment[k] = point.extension_same_moment * share;
    }
    const kind_colors = [_][]const u8{ "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728" };
    for (kinds, kind_colors, 0..) |kind, color, j| {
        const name = try text(memory, "{s} (genérico)", .{kind.title()});
        try output.figures.curve("ac_tip_e", .{ .name = name, .x = heights, .y = factor_columns[j], .color = color });
        try output.figures.curve("ac_tip_d", .{ .name = name, .x = heights, .y = drag_columns[j], .color = color });
    }
    try output.figures.curve("ac_tip_d", .{ .name = "extensão de ponta (mesmo momento na raiz)", .x = heights, .y = same_moment, .color = "#7f7f7f", .dashed = true });
    try output.figures.curve("ac_tip_d", .{ .name = "sem dispositivo", .x = try memory.dupe(f64, &.{ heights[0], heights[count - 1] }), .y = try memory.dupe(f64, &.{ 0, 0 }), .color = "#000000", .dashed = true });
    if (has_devices) {
        try output.checks.append(memory, .{ .status = .info, .item = "os dispositivos da asa compensam?", .value = "não avaliado aqui", .why = "a avaliação dos dispositivos que o avião já tem (o traço deles no plano de Trefftz) ainda é a do Python; o estudo genérico vale", .group = devices_group });
        return;
    }
    var best: usize = 0;
    for (drag_columns[0], 0..) |value, k| if (value < drag_columns[0][best]) {
        best = k;
    };
    const best_change = drag_columns[0][best];
    try output.checks.append(memory, .{
        .status = .info,
        .item = "vale a pena pôr winglet?",
        .value = if (best_change < -gain) try text(memory, "melhor h/b ≈ {d:.2} → ΔD = {d:.1} %", .{ heights[best], best_change }) else "não neste C_L de cruzeiro",
        .criterion = try text(memory, "ΔD ≤ −{d} %", .{gain}),
        .why = try text(memory, "induzido = {d:.0} % do arrasto de cruzeiro", .{100 * share}),
        .fix = "para testar: Configuração → asa → dispositivos → + adicionar",
        .group = devices_group,
        .source = "Trefftz (Munk; Kroo 2001)",
    });
}

fn appendMetrics(memory: std.mem.Allocator, summary: *std.ArrayList([2][]const u8), prefix: []const u8, found: Metrics) !void {
    const rows = [_]struct { name: []const u8, value: ?f64 }{
        .{ .name = "CL0", .value = found.lift_zero },
        .{ .name = "CLa_fit", .value = found.lift_slope },
        .{ .name = "CLmax", .value = found.lift_max },
        .{ .name = "alpha_stall", .value = found.alpha_stall },
        .{ .name = "CDmin", .value = found.drag_min },
        .{ .name = "LDmax", .value = found.efficiency_max },
        .{ .name = "e", .value = found.oswald },
        .{ .name = "x_np", .value = found.neutral_point },
        .{ .name = "x_np_mac", .value = found.neutral_percent },
        .{ .name = "SM", .value = found.static_margin },
    };
    for (rows) |row| if (row.value) |value| try summary.append(memory, .{ try text(memory, "{s}{s}", .{ prefix, row.name }), try text(memory, "{d:.4}", .{value}) });
}

fn derivativeText(memory: std.mem.Allocator, polar: Polar) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.enums.values(Derivative), 0..) |derivative, k| {
        try out.print(memory, "{s}{s} = {d:.4}", .{ if (k > 0) "; " else "", @tagName(derivative), polar.derivatives.get(derivative) });
    }
    return out.items;
}

/// o que o diagnóstico usa do caso
const Flight = struct { cruise_lift: f64, airspeed: f64, density: f64, mass: f64, area: f64, aspect: f64 };

/// estol × cruzeiro, cruzeiro × L/D máximo, Oswald e a concordância dos métodos (`_diagnose` de `aerodynamics.py`);
/// o primeiro método rodado é o principal
fn diagnose(memory: std.mem.Allocator, values: simulation.Values, polars: []const Polar, all_metrics: []const Metrics, flight: Flight, checks: *std.ArrayList(simulation.Check)) !void {
    const main = polars[0];
    const found = all_metrics[0];
    const performance = "desempenho aerodinâmico";
    if (found.lift_max) |lift_max| {
        const stall = @sqrt(2 * flight.mass * g0 / (flight.density * flight.area * lift_max));
        const ratio = values.number("Vs_ratio", 1.3);
        const ok = flight.airspeed >= ratio * stall;
        try checks.append(memory, .{ .status = if (ok) .ok else .falha, .item = "cruzeiro acima do estol", .value = try text(memory, "V_S = {d:.1} m/s; cruzeiro {d} m/s", .{ stall, flight.airspeed }), .criterion = try text(memory, "V ≥ {d} V_S", .{ratio}), .why = if (ok) "" else "o cruzeiro está perto do estol: pouca margem para rajada e curva", .fix = if (ok) "" else try text(memory, "cruzar a ≥ {d:.1} m/s ou aumentar a área/C_Lmax da asa", .{ratio * stall}), .group = performance });
    }
    // cruzeiro × L/D máximo: a L/D no C_L de cruzeiro, interpolada no ramo antes do estol (o Python passa a polar
    // inteira ao `np.interp`, que pede x crescente: depois do estol o C_L desce e a L/D de cruzeiro sai errada)
    var lifts: std.ArrayList(f64) = .empty;
    var ratios: std.ArrayList(f64) = .empty;
    var peak: usize = 0;
    for (main.lift, 0..) |lift, k| if (std.math.isFinite(lift) and (!std.math.isFinite(main.lift[peak]) or lift > main.lift[peak])) {
        peak = k;
    };
    for (main.lift[0 .. peak + 1], main.drag[0 .. peak + 1]) |lift, drag| if (std.math.isFinite(lift) and drag > 0) {
        try lifts.append(memory, lift);
        try ratios.append(memory, lift / drag);
    };
    if (lifts.items.len > 3) {
        var best: usize = 0;
        var low = lifts.items[0];
        var high = lifts.items[0];
        for (ratios.items, lifts.items, 0..) |ratio, lift, k| {
            if (ratio > ratios.items[best]) best = k;
            low = @min(low, lift);
            high = @max(high, lift);
        }
        const lift_best = lifts.items[best];
        const cruise_ratio = if (low <= flight.cruise_lift and flight.cruise_lift <= high) interpolate(flight.cruise_lift, lifts.items, ratios.items) else std.math.nan(f64);
        const best_speed = @sqrt(2 * flight.mass * g0 / (flight.density * flight.area * lift_best));
        const fraction = cruise_ratio / ratios.items[best];
        const wanted = values.number("LD_frac", 90) / 100;
        const ok = fraction >= wanted;
        try checks.append(memory, .{
            .status = if (ok) .ok else .atencao,
            .item = "cruzeiro perto do L/D máximo",
            .value = try text(memory, "{d:.1} de {d:.1} ({d:.0} %)", .{ cruise_ratio, ratios.items[best], 100 * fraction }),
            .criterion = try text(memory, "≥ {d:.0} % do L/D máx.", .{100 * wanted}),
            .why = if (ok) "" else try text(memory, "o C_L de cruzeiro ({d:.2}) está longe do C_L de L/D máx. ({d:.2})", .{ flight.cruise_lift, lift_best }),
            .fix = if (ok) "" else try text(memory, "V de L/D máx. = {d:.1} m/s; para cruzar a {d} m/s com L/D máx. a área da asa seria ≈ {d:.2} m²", .{ best_speed, flight.airspeed, flight.area * flight.cruise_lift / lift_best }),
            .group = performance,
        });
    }
    if (found.oswald) |oswald| {
        try checks.append(memory, .{ .status = .info, .item = "fator de Oswald", .value = try text(memory, "{d:.3} ({s}); Raymer {d:.3}", .{ oswald, main.solver.label(), raymerOswald(flight.aspect) }), .criterion = "—", .why = "e > 1 sai quando o ajuste pega a interação asa-EH ou o C_Di inclui torção; e baixo indica carregamento longe do elíptico (afilamento/torção)", .group = performance });
    }
    // a concordância de cada outro método com o principal
    const tolerance = values.number("tol_CLa", 12) / 100;
    const tolerance_neutral = values.number("tol_np", 5);
    for (polars[1..], all_metrics[1..]) |other, other_metrics| {
        const pairs = [_]struct { name: []const u8, key: []const u8, mine: ?f64, theirs: ?f64, absolute: bool }{
            .{ .name = "C_Lα", .key = "", .mine = found.lift_slope, .theirs = other_metrics.lift_slope, .absolute = false },
            .{ .name = "ponto neutro", .key = " — o ponto neutro depende de dε/dα na cauda e do C_mα da fuselagem", .mine = found.neutral_percent, .theirs = other_metrics.neutral_percent, .absolute = true },
            .{ .name = "C_Lmax", .key = " — o C_Lmax depende da polar 2D usada (modelo × NeuralFoil) e do estol na ponta", .mine = found.lift_max, .theirs = other_metrics.lift_max, .absolute = false },
        };
        for (pairs) |pair| {
            const mine = pair.mine orelse continue;
            const theirs = pair.theirs orelse continue;
            const bad = if (pair.absolute) @abs(mine - theirs) > tolerance_neutral else @abs(mine - theirs) > tolerance * @abs(mine);
            try checks.append(memory, .{
                .status = if (bad) .atencao else .ok,
                .item = try text(memory, "{s}: {s} × {s}", .{ pair.name, main.solver.label(), other.solver.label() }),
                .value = if (pair.absolute) try text(memory, "{d:.3} × {d:.3} % CMA", .{ mine, theirs }) else try text(memory, "{d:.3} × {d:.3}", .{ mine, theirs }),
                .criterion = if (pair.absolute) try text(memory, "diferença ≤ {d} % CMA", .{tolerance_neutral}) else try text(memory, "diferença ≤ {d:.0} %", .{100 * tolerance}),
                .why = if (bad) try text(memory, "{s}; {s}{s}", .{ main.solver.note(), other.solver.note(), pair.key }) else "",
                .fix = if (bad and other.solver == .zig) "o modelo interno é o que a simulação usa: se a diferença importa, ajuste C_Lα/dε/dα/C_mα da fuselagem no modelo" else "",
                .group = "métodos",
            });
        }
    }
}

/// interpolação linear em x crescente ou não ordenado (`np.interp` depois de ordenar)
fn interpolate(x: f64, xs: []const f64, ys: []const f64) f64 {
    var below: ?usize = null;
    var above: ?usize = null;
    for (xs, 0..) |value, k| {
        if (value <= x and (below == null or value > xs[below.?])) below = k;
        if (value >= x and (above == null or value < xs[above.?])) above = k;
    }
    const low = below orelse return ys[above.?];
    const high = above orelse return ys[low];
    if (xs[high] == xs[low]) return ys[low];
    return ys[low] + (ys[high] - ys[low]) * (x - xs[low]) / (xs[high] - xs[low]);
}

/// as curvas estáticas da aeronave inteira no núcleo (faixas e fuselagem), com o CG da aeronave: C_L, C_D e C_m em α com
/// δe = 0 e ±δe, e C_Y, C_l e C_n em β (`aircraft_curves` de `polar.py` e `_full` de `aerodynamics.py`)
fn fullCurves(run: *simulation.Run, values: simulation.Values, airspeed: f64, output: Output) !void {
    const memory = run.memory();
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    try wings.configure(run, instance, run.aircraft, .faixas);
    const params = &instance.p;
    const center = core.trim.Ctx.init(params, &instance.r.f).rcg;
    const deflection = values.number("de", 10);
    const first = values.number("a0", -4) - 4;
    const last = values.number("a1", 22) + 10;
    const count: usize = @intFromFloat(@floor((last - first + 1e-9) / 0.5) + 1);
    const columns = [_][]const u8{ "alpha", "CL", "CD", "Cm", "CL_wing", "CL_ht", "CL_de_m", "CL_de_p", "Cm_de_m", "Cm_de_p" };
    var table: [columns.len][]f64 = undefined;
    for (&table) |*column| column.* = try memory.alloc(f64, count);
    for (0..count) |k| {
        const alpha = first + 0.5 * @as(f64, @floatFromInt(k));
        const plain = core.aero.coeffs(params, airspeed, alpha * rad, 0, center, .{ 0, 0, 0 });
        const up = core.aero.coeffs(params, airspeed, alpha * rad, 0, center, .{ -deflection * rad, 0, 0 });
        const down = core.aero.coeffs(params, airspeed, alpha * rad, 0, center, .{ deflection * rad, 0, 0 });
        const row = [columns.len]f64{ alpha, plain.CL, plain.CD, plain.Cm, plain.CL_wing, plain.CL_ht, up.CL, down.CL, up.Cm, down.Cm };
        for (&table, row) |column, value| column[k] = value;
    }
    const alpha = table[0];
    const beta_count: usize = 81;
    const betas = try memory.alloc(f64, beta_count);
    const side = [3][]f64{ try memory.alloc(f64, beta_count), try memory.alloc(f64, beta_count), try memory.alloc(f64, beta_count) };
    const alpha_beta = values.number("alpha_beta", 4) * rad;
    for (betas, 0..) |*beta, k| {
        beta.* = -20 + 0.5 * @as(f64, @floatFromInt(k));
        const coefficients = core.aero.coeffs(params, airspeed, alpha_beta, beta.* * rad, center, .{ 0, 0, 0 });
        side[0][k] = coefficients.CY;
        side[1][k] = coefficients.Cl;
        side[2][k] = coefficients.Cn;
    }
    const figures = output.figures;
    try figures.curve("ac_pa_CL", .{ .name = "C_L total (δe = 0)", .x = alpha, .y = table[1], .color = "#000000", .width = 2.4 });
    try figures.curve("ac_pa_CL", .{ .name = "C_L da asa", .x = alpha, .y = table[4], .color = "#1f77b4" });
    var tail: f64 = 0;
    for (table[5]) |value| if (std.math.isFinite(value)) {
        tail = @max(tail, @abs(value));
    };
    if (tail > 1e-6) try figures.curve("ac_pa_CL", .{ .name = "C_L da EH", .x = alpha, .y = table[5], .color = "#2ca02c" });
    try figures.curve("ac_pa_CL", .{ .name = try text(memory, "δe = −{d}°", .{deflection}), .x = alpha, .y = table[6], .color = "#2ca02c", .dashed = true });
    try figures.curve("ac_pa_CL", .{ .name = try text(memory, "δe = +{d}°", .{deflection}), .x = alpha, .y = table[7], .color = "#d62728", .dashed = true });
    try figures.curve("ac_pa_Cm", .{ .name = try text(memory, "δe = −{d}° (cabra)", .{deflection}), .x = alpha, .y = table[8], .color = "#2ca02c" });
    try figures.curve("ac_pa_Cm", .{ .name = "δe = 0", .x = alpha, .y = table[3], .color = "#000000", .width = 2.4 });
    try figures.curve("ac_pa_Cm", .{ .name = try text(memory, "δe = +{d}° (pica)", .{deflection}), .x = alpha, .y = table[9], .color = "#d62728" });
    try figures.guide("ac_pa_Cm", .{ .name = "C_m = 0 (equilíbrio)", .value = 0, .vertical = false, .color = "#7f7f7f", .dashed = true });
    try figures.curve("ac_pa_CD", .{ .name = "aeronave completa", .x = table[2], .y = table[1], .color = "#000000", .width = 2.2 });
    const side_names = [3][]const u8{ "C_Y", "C_l (rolamento)", "C_n (guinada)" };
    const side_colors = [3][]const u8{ "#9467bd", "#1f77b4", "#d62728" };
    for (side, side_names, side_colors) |column, name, color| try figures.curve("ac_pa_b", .{ .name = name, .x = betas, .y = column, .color = color, .width = 2 });

    // C_nβ e C_lβ: a reta em |β| ≤ 5°
    var small_beta: std.ArrayList(f64) = .empty;
    var small_yaw: std.ArrayList(f64) = .empty;
    var small_roll: std.ArrayList(f64) = .empty;
    for (betas, side[2], side[1]) |beta, yaw, roll| if (@abs(beta) <= 5) {
        try small_beta.append(memory, beta * rad);
        try small_yaw.append(memory, yaw);
        try small_roll.append(memory, roll);
    };
    const yaw_slope = (line(small_beta.items, small_yaw.items) orelse [2]f64{ 0, 0 })[0];
    const roll_slope = (line(small_beta.items, small_roll.items) orelse [2]f64{ 0, 0 })[0];
    try output.summary.append(memory, .{ "avião completo · aeronave completa: C_nβ, C_lβ (1/rad)", try text(memory, "{d:.4}, {d:.4}", .{ yaw_slope, roll_slope }) });
    const whole = "aeronave completa (núcleo)";
    const checks = output.checks;
    try checks.append(memory, .{ .status = if (yaw_slope > 0) .ok else .falha, .item = "estabilidade direcional C_nβ", .value = try text(memory, "{d:.4} /rad", .{yaw_slope}), .criterion = "> 0", .why = if (yaw_slope > 0) "" else "a aeronave não volta o nariz para o vento", .fix = if (yaw_slope > 0) "" else "aumente a EV ou o braço dela", .group = whole });
    try checks.append(memory, .{ .status = if (roll_slope < 0) .ok else .atencao, .item = "efeito diedro C_lβ", .value = try text(memory, "{d:.4} /rad", .{roll_slope}), .criterion = "< 0", .why = if (roll_slope < 0) "" else "sem efeito diedro estabilizante", .fix = if (roll_slope < 0) "" else "aumente o diedro", .group = whole });
    // o profundor consegue equilibrar no C_L máximo?
    var peak: usize = 0;
    for (table[1], 0..) |lift, k| if (std.math.isFinite(lift) and (!std.math.isFinite(table[1][peak]) or lift > table[1][peak])) {
        peak = k;
    };
    const moment_up = table[8][peak];
    const balanced = moment_up >= 0;
    try checks.append(memory, .{ .status = if (balanced) .ok else .atencao, .item = try text(memory, "profundor equilibra no C_L máximo com δe = −{d}°", .{deflection}), .value = try text(memory, "C_m = {s}{d:.3}", .{ if (moment_up >= 0) "+" else "", moment_up }), .criterion = "≥ 0 (consegue cabrar até o estol)", .why = if (balanced) "" else "com esse δe o nariz não sobe até o C_L máximo", .fix = if (balanced) "" else "mais área/braço de profundor ou CG mais para trás", .group = whole });
}

const testing = std.testing;

test "Avião completo: as métricas do modelo interno e o C_nβ batem com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    const memory = run.memory();
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    const figures = try simulation.Figures.init(memory, &plots);
    const values = simulation.Values.fromRequest(memory, "\"values\": {\"V_cruise\": 15, \"tips\": true}");
    try analyze(&run, values, &.{.zig}, .{ .summary = &summary, .checks = &checks, .figures = figures });
    const wanted = [_]struct { key: []const u8, value: f64 }{
        .{ .key = "avião completo · [modelo interno] CL0", .value = 0.39785187456477183 },
        .{ .key = "avião completo · [modelo interno] CLa_fit", .value = 4.747310690562387 },
        .{ .key = "avião completo · [modelo interno] e", .value = 0.9059757335703595 },
        .{ .key = "avião completo · [modelo interno] x_np_mac", .value = 48.39172869849668 },
    };
    for (wanted) |item| {
        var found = false;
        for (summary.items) |row| if (std.mem.eql(u8, row[0], item.key)) {
            try testing.expectApproxEqAbs(item.value, try std.fmt.parseFloat(f64, row[1]), 1e-4);
            found = true;
        };
        try testing.expect(found);
    }
    var direction = false;
    for (checks.items) |check| if (std.mem.eql(u8, check.item, "estabilidade direcional C_nβ")) {
        try testing.expectEqualStrings("0.0661 /rad", check.value);
        direction = true;
    };
    try testing.expect(direction);
    // o estudo das pontas (Python: "melhor h/b ≈ 0.25 → ΔD = -9.4 %", induzido 46 % do arrasto de cruzeiro)
    var winglet = false;
    for (checks.items) |check| if (std.mem.eql(u8, check.item, "vale a pena pôr winglet?")) {
        try testing.expectEqualStrings("melhor h/b ≈ 0.25 → ΔD = -9.4 %", check.value);
        try testing.expectEqualStrings("induzido = 46 % do arrasto de cruzeiro", check.why);
        winglet = true;
    };
    try testing.expect(winglet);
}

test "Efeito solo: no avião original, perto do chão o C_L sobe, o induzido cai e longe volta a 1" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    const memory = run.memory();
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    const figures = try simulation.Figures.init(memory, &plots);
    const values = simulation.Values.fromRequest(memory, "\"values\": {\"ground\": true, \"alpha_ground\": 4, \"hb_ground_max\": 2}");
    const geometry = reference(&loaded.ac);
    try groundStudy(&run, values, geometry, .{ geometry.mac_le - 0.3 * geometry.chord, 0, 0 }, .{ .summary = &summary, .checks = &checks, .figures = figures });
    try testing.expectEqual(@as(usize, 3), summary.items.len);
    try testing.expectEqual(@as(usize, 0), checks.items.len);
    const lift = figures.get("ac_gnd_CL").?.curves.items;
    // perto do chão: C_L maior e induzido menor que sem chão; a 2 envergaduras, quase sem efeito
    const last = lift[0].y.len - 1;
    try testing.expect(lift[0].y[0] > 1.05 and lift[1].y[0] < 0.8);
    try testing.expectApproxEqAbs(@as(f64, 1), lift[0].y[last], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1), lift[1].y[last], 0.02);
    // o C_L cresce sempre que a asa desce
    for (1..lift[0].y.len) |k| try testing.expect(lift[0].y[k] <= lift[0].y[k - 1]);
}

//! Cargas em Zig (o par de `loads.py`): a carga aerodinâmica ao longo de cada superfície num ponto de voo (V, fator
//! de carga, α), com e sem a hélice, em gráficos ao longo da envergadura. O ponto sai do núcleo uma vez: a trimagem
//! (`core/src/sim/trim.zig`), se o α não foi imposto, e a rotação de equilíbrio de cada hélice. Cada método de carga do
//! núcleo (as faixas da simulação ou a linha sustentadora, `core/src/loads/llt.zig`) calcula nesse mesmo ponto, com
//! cada superfície refinada sozinha, como no Python (`aerosim/aero/span_loads.py`).
//!
//! O VLM do AeroSandbox roda pelo Python, só quando é escolhido (`python`); no site, o pacote só é baixado nessa hora.
//! A vista 3D da carga ainda é só do Python.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const wings = @import("wings.zig");

const params_mod = aircraft_model.params;
const model = aircraft_model.aircraft;
const LoadMethod = wings.LoadMethod;
const vec = core.vec;
const rad = std.math.pi / 180.0;
const deg = 180.0 / std.math.pi;
const g0 = 9.80665;
const max_panels = core.limits.max_surfaces;

/// a análise, com a interface de `simulation.check`
pub const Loads = struct {
    pub const name: []const u8 = "loads";
    pub const title: [:0]const u8 = "Cargas";
    pub const area: []const u8 = "Cargas";
    pub const description: []const u8 = "Carga aerodinâmica ao longo de cada superfície num ponto de voo (V, n, α), com e sem a hélice do conjunto motopropulsor do avião: sustentação por metro, α e velocidade locais. O VLM do AeroSandbox roda pelo Python quando escolhido.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
    pub const python = needsPython;
};

const propeller_choices = [_][]const u8{ "com hélice", "sem hélice", "comparar com e sem" };
const alpha_choices = [_][]const u8{ "da trimagem", "imposto" };
const colors = [_][]const u8{ "#1f4e8c", "#d95f02", "#2ca02c", "#9467bd" }; // um por (método, hélice), na ordem em que rodam

/// os papéis que têm gráfico
const Role = enum {
    wing,
    htail,
    vtail,

    fn label(role: Role) []const u8 {
        return switch (role) {
            .wing => "asa",
            .htail => "EH",
            .vtail => "EV",
        };
    }

    fn of(role_name: []const u8) ?Role {
        return std.meta.stringToEnum(Role, role_name);
    }
};

/// os campos ao longo da envergadura
const Field = enum {
    L,
    alpha_ef,
    V_rel,

    fn title(field: Field) []const u8 {
        return switch (field) {
            .L => "sustentação por metro",
            .alpha_ef => "α efetivo",
            .V_rel => "velocidade local / V",
        };
    }

    fn unit(field: Field) []const u8 {
        return switch (field) {
            .L => "L' (N/m)",
            .alpha_ef => "α (°)",
            .V_rel => "V/V∞",
        };
    }
};

/// a carga de uma superfície, em ordem ao longo da envergadura (`SurfaceLoad` do Python)
const SurfaceLoad = struct {
    name: []const u8,
    role: Role,
    position: []f64, // y (ou a altura, na deriva)
    fields: std.EnumArray(Field, []f64),
    lift: f64, // N
    drag: f64, // N
};

/// uma rodada: um método, com ou sem hélice
const Case = struct {
    label: []const u8,
    propellers: bool,
    surfaces: []SurfaceLoad,
};

/// o estado de uma hélice no ponto de voo
const Propeller = struct { name: []const u8, rpm: f64, thrust: f64, torque: f64, advance: f64 };

const RunState = struct {
    airspeed: f64 = 12,
    load_factor: f64 = 1,
    imposed: bool = false,
    alpha: f64 = 0, // °
    elevator: f64 = 0, // °
    weight: f64 = 0,
    trim_ok: bool = true,
    propellers: []Propeller = &.{},
    cases: []Case = &.{},
    methods: []const LoadMethod = &.{},
    slipstream: bool = false,
};

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    _ = values;
    const params = [_]simulation.Param{
        .{ .key = "V", .label = "Velocidade", .default = .{ .number = 12 }, .minimum = 2, .maximum = 80, .unit = "m/s" },
        .{ .key = "n", .label = "Fator de carga da trimagem", .default = .{ .number = 1 }, .minimum = 0.2, .maximum = 10, .help = "1: voo nivelado; > 1: curva coordenada com esse n" },
        .{ .key = "alpha_mode", .label = "α", .kind = .choice, .default = .{ .text = alpha_choices[0] }, .choices = &alpha_choices },
        .{ .key = "alpha", .label = "α imposto", .default = .{ .number = 4 }, .minimum = -15, .maximum = 25, .unit = "°", .help = "só vale com α = imposto (profundor 0)" },
        .{ .key = "helice", .label = "Hélice", .kind = .choice, .default = .{ .text = propeller_choices[2] }, .choices = &propeller_choices, .help = "com: a esteira e a tração das hélices entram nas superfícies (modificador de esteira do avião); sem: as superfícies não veem a hélice" },
        .{ .key = "method", .label = "Método", .kind = .choice, .default = .{ .text = wings.method_titles[0] }, .choices = &wings.method_titles, .help = "o VLM do AeroSandbox roda pelo Python" },
        .{ .key = "compare", .label = "Comparar com", .kind = .choice, .default = .{ .text = wings.none }, .choices = &wings.compare_titles, .help = "outro método no mesmo ponto de voo (mesmo α e profundor), sobreposto nos gráficos" },
        .{ .key = "vlm_span", .label = "VLM: faixas por lado", .kind = .int, .default = .{ .number = 0 }, .minimum = 0, .maximum = 200, .help = "refino do VLM nas cargas; 0: o padrão (40)" },
        .{ .key = "vlm_chord", .label = "VLM: painéis na corda", .kind = .int, .default = .{ .number = 0 }, .minimum = 0, .maximum = 40, .help = "refino do VLM nas cargas; 0: o padrão (6)" },
    };
    // um gráfico por papel que o avião tem e por campo
    var buffer: [std.enums.values(Role).len * std.enums.values(Field).len]simulation.Plot = undefined;
    var count: usize = 0;
    var keys: [buffer.len][24]u8 = undefined;
    var titles: [buffer.len][64]u8 = undefined;
    for (std.enums.values(Role)) |role| {
        if (aircraft) |plane| {
            const present = for (plane.surfaces) |surface| {
                if (surface.enabled and Role.of(surface.role) == role) break true;
            } else false;
            if (!present) continue;
        }
        for (std.enums.values(Field)) |field| {
            buffer[count] = .{
                .key = std.fmt.bufPrint(&keys[count], "{s}_{s}", .{ @tagName(field), @tagName(role) }) catch unreachable,
                .title = std.fmt.bufPrint(&titles[count], "{s}: {s}", .{ role.label(), field.title() }) catch unreachable,
                .xlabel = if (role == .vtail) "altura (m)" else "y (m)",
                .ylabel = field.unit(),
            };
            count += 1;
        }
    }
    try simulation.writeSpecs(out, &params, buffer[0..count], Loads.description, .{});
}

/// a rodada precisa do Python: um método de fora do núcleo
fn needsPython(values: simulation.Values) bool {
    for ([_][]const u8{ "method", "compare" }) |key| if (LoadMethod.fromTitle(values.text(key, wings.none))) |method| {
        if (!method.inCore()) return true;
    };
    return false;
}

/// a velocidade do ar no corpo a V, α (rad), sem derrapagem
fn relativeWind(airspeed: f64, alpha: f64) vec.V3 {
    return .{ airspeed * @cos(alpha), 0, airspeed * @sin(alpha) };
}

/// as cargas de cada superfície num ponto, por um método do núcleo: cada superfície refinada sozinha e o avião sem
/// refino para o resto (`CoreLoadMethod.strips` do Python)
fn strips(run: *simulation.Run, state: *const RunState, method: LoadMethod, propellers: bool) ![]SurfaceLoad {
    const memory = run.memory();
    const aircraft = run.aircraft;
    const lifting_line = method != .faixas;
    const wind = relativeWind(state.airspeed, state.alpha * rad);
    var thrusts: [core.limits.max_props]f64 = undefined;
    var torques: [core.limits.max_props]f64 = undefined;
    for (state.propellers, 0..) |propeller, i| {
        thrusts[i] = if (propellers) propeller.thrust else 0;
        torques[i] = if (propellers) propeller.torque else 0;
    }
    const done = try memory.alloc(bool, aircraft.surfaces.len);
    @memset(done, false);
    var out: std.ArrayList(SurfaceLoad) = .empty;
    const instance = try memory.create(core.runner.Instance);
    var jobs: std.ArrayList(?usize) = .empty;
    for (aircraft.surfaces, 0..) |surface, i| if (surface.enabled) try jobs.append(memory, i);
    try jobs.append(memory, null);
    for (jobs.items) |job| {
        instance.* = .{};
        const plane = if (job) |index| try wings.fitted(memory, aircraft.*, index, lifting_line, &instance.p) else aircraft.*;
        instance.* = .{};
        try wings.configure(run, instance, &plane, method);
        const params = &instance.p;
        const panel_count: usize = @intCast(params.n_surf);
        const prop_count: usize = @intCast(params.n_prop);
        var env = if (prop_count > 0) core.modifiers.envFrom(params, wind, vec.zero, thrusts[0..prop_count], torques[0..prop_count]) else core.modifiers.Env.none;
        env.no_interference = lifting_line;
        var panels: [max_panels]core.types.PanelState = undefined;
        const center = core.trim.Ctx.init(params, &instance.r.f).rcg;
        const controls = vec.V3{ state.elevator * rad, 0, 0 };
        _ = core.aero.computeTrace(params, wind, vec.zero, center, 50.0, controls, &env, panels[0..panel_count]);
        if (lifting_line) _ = core.llt.apply(params, wind, controls, panels[0..panel_count]);
        for (aircraft.surfaces, 0..) |surface, k| {
            if (!surface.enabled or done[k]) continue;
            if (job != null and job.? != k) continue;
            const role = Role.of(surface.role) orelse continue;
            var rows: std.ArrayList(usize) = .empty;
            for (params.surf[0..panel_count], panels[0..panel_count], 0..) |panel, state_of, i| {
                if (panel.owner == @as(i32, @intCast(k)) and state_of.group != .none) try rows.append(memory, i);
            }
            if (rows.items.len == 0) continue;
            const vertical = surface.vertical;
            const position = try memory.alloc(f64, rows.items.len);
            std.mem.sort(usize, rows.items, panels[0..panel_count], struct {
                fn less(all: []const core.types.PanelState, a: usize, b: usize) bool {
                    return all[a].r[1] < all[b].r[1];
                }
            }.less);
            if (vertical) std.mem.sort(usize, rows.items, panels[0..panel_count], struct {
                fn less(all: []const core.types.PanelState, a: usize, b: usize) bool {
                    return -all[a].r[2] < -all[b].r[2];
                }
            }.less);
            var fields = std.EnumArray(Field, []f64).initUndefined();
            for (std.enums.values(Field)) |field| fields.set(field, try memory.alloc(f64, rows.items.len));
            var lift: f64 = 0;
            var drag: f64 = 0;
            for (rows.items, 0..) |i, j| {
                const panel = panels[i];
                const width = panel.S / @max(panel.c, 1e-12);
                position[j] = if (vertical) -panel.r[2] else panel.r[1];
                fields.getPtr(.L).*[j] = panel.L / width;
                fields.getPtr(.alpha_ef).*[j] = panel.alpha * deg;
                fields.getPtr(.V_rel).*[j] = panel.V / state.airspeed;
                lift += panel.L;
                drag += panel.D;
            }
            try out.append(memory, .{ .name = surface.name, .role = role, .position = position, .fields = fields, .lift = lift, .drag = drag });
            done[k] = true;
        }
    }
    return out.items;
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    const aircraft = run.aircraft;
    state.airspeed = values.number("V", 12);
    state.load_factor = values.number("n", 1);
    state.imposed = std.mem.eql(u8, values.text("alpha_mode", alpha_choices[0]), alpha_choices[1]);

    // o ponto de voo: a trimagem e as hélices (`prepare` do Python)
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    var diagnosis: model.Diag = .{};
    params_mod.fill(aircraft, &instance.p, &diagnosis) catch |err| {
        run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    core.runner.configure(instance) catch |err| {
        run.fail("o núcleo recusou a configuração ({s})", .{@errorName(err)});
        return err;
    };
    const params = &instance.p;
    const context = core.trim.Ctx.init(params, &instance.r.f);
    state.weight = context.m * g0;
    var throttle: f64 = 1.0;
    if (state.imposed) {
        state.alpha = values.number("alpha", 4);
        state.elevator = 0;
    } else {
        const kind: core.types.TrimKind = if (@abs(state.load_factor - 1) < 1e-9) .level else .turn;
        const point = core.trim.solve(context, kind, state.airspeed, state.load_factor, null);
        state.trim_ok = point.ok != 0;
        state.alpha = point.alpha * deg;
        state.elevator = point.de * deg;
        throttle = point.thr;
    }
    const wind = relativeWind(state.airspeed, state.alpha * rad);
    const prop_count: usize = @intCast(params.n_prop);
    state.propellers = try memory.alloc(Propeller, prop_count);
    var unit_index: usize = 0;
    for (aircraft.propulsion) |unit| {
        if (!unit.enabled or unit_index >= prop_count) continue;
        const prop_unit = &params.prop[unit_index];
        const rotation = core.propulsion.equilibriumRps(params, prop_unit, wind, throttle);
        const output = core.propulsion.unit(params, prop_unit, core.propulsion.axis(params, prop_unit), wind, vec.zero, rotation, throttle, 0);
        state.propellers[unit_index] = .{ .name = unit.name, .rpm = rotation * 60, .thrust = output.T, .torque = output.Q, .advance = output.J };
        unit_index += 1;
    }
    if (aircraft.modifiers) |list| for (list) |modifier| {
        if (modifier.enabled and std.mem.indexOf(u8, modifier.kind, "esteira") != null) state.slipstream = true;
    };
    run.progress = 0.1;

    const main = LoadMethod.fromTitle(values.text("method", wings.method_titles[0])) orelse .llt;
    var methods: std.ArrayList(LoadMethod) = .empty;
    try methods.append(memory, main);
    if (LoadMethod.fromTitle(values.text("compare", wings.none))) |other| if (other != main) try methods.append(memory, other);
    state.methods = methods.items;
    const choice = values.text("helice", propeller_choices[2]);
    const with_list = [_]bool{true};
    const without_list = [_]bool{false};
    const both_list = [_]bool{ true, false };
    const options: []const bool = if (std.mem.eql(u8, choice, propeller_choices[0])) &with_list else if (std.mem.eql(u8, choice, propeller_choices[1])) &without_list else &both_list;
    var cases: std.ArrayList(Case) = .empty;
    for (options) |propellers| for (methods.items) |method| {
        const label = try std.fmt.allocPrint(memory, "{s}{s}{s}", .{ if (propellers) "com hélice" else "sem hélice", if (methods.items.len > 1) " · " else "", if (methods.items.len > 1) method.title() else "" });
        try cases.append(memory, .{ .label = label, .propellers = propellers, .surfaces = try strips(run, state, method, propellers and prop_count > 0) });
        run.progress = 0.1 + 0.9 * @as(f32, @floatFromInt(cases.items.len)) / @as(f32, @floatFromInt(options.len * methods.items.len));
    };
    state.cases = cases.items;
    run.progress = 1;
}

fn advanceRun(_: *simulation.Run, _: *RunState) simulation.Error!bool {
    return true; // as cargas saem inteiras no começo
}

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    const group = "ponto de voo";
    // os gráficos: os mesmos de `specs` para este avião
    var plot_list: std.ArrayList(simulation.Plot) = .empty;
    for (std.enums.values(Role)) |role| {
        const present = for (run.aircraft.surfaces) |surface| {
            if (surface.enabled and Role.of(surface.role) == role) break true;
        } else false;
        if (!present) continue;
        for (std.enums.values(Field)) |field| try plot_list.append(memory, .{
            .key = try text(memory, "{s}_{s}", .{ @tagName(field), @tagName(role) }),
            .title = try text(memory, "{s}: {s}", .{ role.label(), field.title() }),
            .xlabel = if (role == .vtail) "altura (m)" else "y (m)",
            .ylabel = field.unit(),
        });
    }
    const figures = try simulation.Figures.init(memory, plot_list.items);
    for (state.cases, 0..) |case, k| {
        const color = colors[k % colors.len];
        const prefix = try text(memory, "[{s}] ", .{case.label});
        const required = state.weight * (if (state.imposed) 1.0 else state.load_factor);
        var lift: f64 = 0;
        for (case.surfaces) |surface| {
            lift += surface.lift;
            for (std.enums.values(Field)) |field| {
                const key = try text(memory, "{s}_{s}", .{ @tagName(field), @tagName(surface.role) });
                try figures.curve(key, .{ .name = try text(memory, "{s}: {s}", .{ case.label, surface.name }), .x = surface.position, .y = surface.fields.get(field), .color = color, .width = 2, .dashed = !case.propellers });
            }
        }
        try summary.append(memory, .{ try text(memory, "{s}α (°), profundor (°)", .{prefix}), try text(memory, "{d:.3}, {d:.3}", .{ state.alpha, state.elevator }) });
        try summary.append(memory, .{ try text(memory, "{s}sustentação das superfícies (N); n·peso (N)", .{prefix}), try text(memory, "{d:.2}, {d:.2}", .{ lift, required }) });
        for (case.surfaces) |surface| try summary.append(memory, .{ try text(memory, "{s}{s}: sustentação (N), arrasto (N)", .{ prefix, surface.name }), try text(memory, "{d:.2}, {d:.3}", .{ surface.lift, surface.drag }) });
        for (state.propellers) |propeller| try summary.append(memory, .{ try text(memory, "{s}{s}: rpm, T (N), J", .{ prefix, propeller.name }), try text(memory, "{d:.0}, {d:.2}, {d:.3}", .{ propeller.rpm, propeller.thrust, propeller.advance }) });
        if (!state.imposed) {
            if (k == 0) try checks.append(memory, .{
                .status = if (state.trim_ok) .ok else .falha,
                .item = try text(memory, "trimagem {s}", .{case.label}),
                .value = try text(memory, "α = {d:.2}°, δe = {d:.2}°", .{ state.alpha, state.elevator }),
                .criterion = "converge",
                .why = if (state.trim_ok) "" else "o ponto pedido está fora do envelope (V baixa demais para o n?)",
                .fix = if (state.trim_ok) "" else "suba a velocidade ou baixe o fator de carga",
                .group = group,
            });
            if (required > 0) try checks.append(memory, .{ .status = .info, .item = try text(memory, "soma das cargas × n·peso {s}", .{case.label}), .value = try text(memory, "{s}{d:.1} %", .{ if (lift >= required) "+" else "", 100 * (lift - required) / required }), .why = "α e profundor vêm da trimagem do núcleo; cada método redistribui a carga do seu jeito, então a soma difere um pouco do peso", .group = group });
        }
    }
    if (state.propellers.len == 0) {
        try checks.append(memory, .{ .status = .info, .item = "hélice", .value = "o avião não tem motor ligado", .why = "as cargas saem sem hélice", .group = group });
    } else if (!state.slipstream) {
        try checks.append(memory, .{ .status = .info, .item = "esteira da hélice nas superfícies", .value = "modificador de esteira desligado", .why = "com hélice, só a tração e o torque mudam a trimagem; as superfícies não veem a esteira", .fix = "ligue 'esteira.disco' em Configuração → Modificadores", .group = group });
    }
    try summary.append(memory, .{ "métodos", "núcleo (core/src/loads/llt.zig e core/src/physics/aero.zig)" });
    try simulation.beginResult(out, summary.items, checks.items);
    try figures.write(out, true);
    try simulation.endResult(out);
}

const testing = std.testing;

test "Cargas: a trimagem e a sustentação de cada superfície batem com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Loads);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"helice\": \"com hélice\"}"));
    const state: *RunState = @ptrCast(@alignCast(run.state.?));
    try testing.expectApproxEqAbs(expected_alpha, state.alpha, 1e-6);
    try testing.expectApproxEqAbs(expected_wing_lift, state.cases[0].surfaces[0].lift, 1e-4);
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
}

// os números do Python (`loads.py`, Convencional_original, com hélice, linha sustentadora de Phillips e Snyder)
const expected_alpha: f64 = 11.766679580876728;
const expected_wing_lift: f64 = 122.12604134553246;

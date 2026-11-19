//! Tração em Zig (o par de `thrust.py`): a tração, a potência elétrica, a corrente e a eficiência da hélice de cada
//! motor ligado, em função da velocidade, para cada acelerador pedido. Cada ponto é o equilíbrio de rotação do motor
//! com a hélice do núcleo (`core/src/physics/propulsion.zig`, `point`); aqui só se varre a velocidade e se escreve.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");

const params_mod = aircraft_model.params;

/// a análise, com a interface de `simulation.check`
pub const Thrust = struct {
    pub const name: []const u8 = "thrust";
    pub const title: [:0]const u8 = "Tração";
    pub const area: []const u8 = "Desempenho";
    pub const description: []const u8 = "Curvas de tração, potência, corrente e eficiência da hélice em função da velocidade.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
};

const max_speeds = 2000;
const max_throttles = 8;
const default_throttles = [_]f64{ 1.0, 0.75, 0.5 };

const plots = [_]simulation.Plot{
    .{ .key = "T", .title = "Tração", .xlabel = "$V$ (m/s)", .ylabel = "$T$ (N)" },
    .{ .key = "P", .title = "Potência elétrica", .xlabel = "$V$ (m/s)", .ylabel = "$P$ (W)" },
    .{ .key = "I", .title = "Corrente", .xlabel = "$V$ (m/s)", .ylabel = "$I$ (A)" },
    .{ .key = "eta", .title = "Eficiência da hélice", .xlabel = "$V$ (m/s)", .ylabel = "$\\eta$" },
};

const palette = [_][]const u8{ "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#e377c2", "#17becf" };

/// uma curva: um motor num acelerador, um ponto por velocidade
const Sweep = struct {
    unit: []const u8,
    throttle: f64,
    points: []core.types.PropPoint,
};

const RunState = struct {
    speeds: []f64 = &.{},
    sweeps: []Sweep = &.{},
};

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    _ = values;
    const params = [_]simulation.Param{
        .{ .key = "V_max", .label = "V máxima", .default = .{ .number = 30 }, .minimum = 5, .maximum = 120, .unit = "m/s" },
        .{ .key = "dV", .label = "passo", .default = .{ .number = 0.5 }, .minimum = 0.1, .maximum = 5, .unit = "m/s" },
        .{ .key = "thr", .label = "Aceleradores", .kind = .floats, .default = .{ .text = "1.0, 0.75, 0.5" } },
    };
    try simulation.writeSpecs(out, &params, &plots, Thrust.description, .{ .solvers = &.{.propulsion}, .aircraft = aircraft });
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    // os parâmetros configurados pelo núcleo (a configuração deriva o que a hélice usa), sem calibrar o piloto
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    params_mod.fill(run.aircraft, &instance.p, &diagnosis) catch |err| {
        run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    core.runner.configure(instance) catch |err| {
        run.fail("o núcleo recusou a configuração ({s})", .{@errorName(err)});
        return err;
    };
    const params = &instance.p;
    const top_speed = std.math.clamp(values.number("V_max", 30), 1, 200);
    const step = std.math.clamp(values.number("dV", 0.5), 0.01, 50);
    const speed_count: usize = @min(@as(usize, @intFromFloat(@floor(top_speed / step + 1e-9))) + 1, max_speeds);
    state.speeds = try memory.alloc(f64, speed_count);
    for (state.speeds, 0..) |*speed, k| speed.* = step * @as(f64, @floatFromInt(k));

    var buffer: [max_throttles]f64 = undefined;
    const throttles = values.numbers("thr", &buffer, &default_throttles);
    const unit_count: usize = @intCast(params.n_prop);
    state.sweeps = try memory.alloc(Sweep, unit_count * throttles.len);
    var unit_index: usize = 0;
    for (run.aircraft.propulsion) |unit| {
        if (!unit.enabled) continue;
        if (unit_index >= unit_count) break;
        for (throttles, 0..) |throttle, t| {
            const points = try memory.alloc(core.types.PropPoint, speed_count);
            for (state.speeds, points) |speed, *point| point.* = core.propulsion.point(params, &params.prop[unit_index], speed, throttle);
            state.sweeps[unit_index * throttles.len + t] = .{ .unit = unit.name, .throttle = throttle, .points = points };
        }
        unit_index += 1;
    }
    run.progress = 1;
}

fn advanceRun(_: *simulation.Run, _: *RunState) simulation.Error!bool {
    return true; // a varredura toda sai no começo (uns milissegundos)
}

/// uma coluna de uma curva (o campo `field` de cada ponto)
fn column(memory: std.mem.Allocator, sweep: Sweep, comptime field: []const u8) ![]f64 {
    const values = try memory.alloc(f64, sweep.points.len);
    for (sweep.points, values) |point, *value| value.* = @field(point, field);
    return values;
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    // a tração estática de cada motor, no maior acelerador
    for (state.sweeps, 0..) |sweep, k| {
        const strongest = for (state.sweeps[0..k]) |other| {
            if (std.mem.eql(u8, other.unit, sweep.unit) and other.throttle >= sweep.throttle) break false;
        } else for (state.sweeps[k + 1 ..]) |other| {
            if (std.mem.eql(u8, other.unit, sweep.unit) and other.throttle > sweep.throttle) break false;
        } else true;
        if (!strongest) continue;
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "T estática {s}", .{sweep.unit}), try std.fmt.allocPrint(memory, "{d:.3}", .{sweep.points[0].T}) });
    }
    if (state.sweeps.len == 0) try checks.append(memory, .{ .status = .info, .item = "motores", .value = "nenhum ligado", .why = "sem motor ligado não há curva de tração" });
    try simulation.beginResult(out, summary.items, checks.items);
    const fields = [_][]const u8{ "T", "P_elec", "I", "eta_prop" };
    inline for (plots, fields, 0..) |plot, field, p| {
        const curves = try memory.alloc(simulation.Curve, state.sweeps.len);
        for (state.sweeps, curves, 0..) |sweep, *curve, k| curve.* = .{
            .name = try std.fmt.allocPrint(memory, "{s} @ {d}", .{ sweep.unit, sweep.throttle }),
            .x = state.speeds,
            .y = try column(memory, sweep, field),
            .color = palette[k % palette.len],
        };
        try simulation.writePlot(out, plot, curves, p == 0);
    }
    try simulation.endResult(out);
}

const testing = std.testing;

test "Tração: as curvas de cada motor e a tração estática no maior acelerador" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Bimotor_convencional_tubo_cauda_em_V.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Thrust);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"V_max\": 20, \"dV\": 1, \"thr\": [1, 0.5]}"));
    try testing.expect(try registered.advance(&run));
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try registered.result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    const plotted = outcome.value.object.get("plots").?.array.items;
    try testing.expectEqual(@as(usize, 4), plotted.len);
    const curves = plotted[0].object.get("curves").?.array.items;
    try testing.expectEqual(@as(usize, 2 * 2), curves.len); // dois motores, dois aceleradores
    const thrust = curves[0].object.get("y").?.array.items;
    try testing.expectEqual(@as(usize, 21), thrust.len);
    // os números do Python (`thrust.py: thrust_curves`, motor esq a 100 %): 16,575 N parado e −4,113 N a 20 m/s
    try testing.expectApproxEqAbs(@as(f64, 16.57521392), number(thrust[0]), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -4.11267889), number(thrust[20]), 1e-6);
    try testing.expectEqual(@as(usize, 2), outcome.value.object.get("summary").?.object.count());
}

fn number(value: std.json.Value) f64 {
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => std.math.nan(f64),
    };
}

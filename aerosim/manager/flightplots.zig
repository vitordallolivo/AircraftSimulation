//! Gráficos de um voo simulado em Zig (o par de `flightplots.py`), no estilo do simulador original em C: uma cor por
//! etapa do voo (corrida no chão, cada perna, rolagem), o fundo colorido por etapa nos gráficos no tempo, estrelas nos
//! eventos (decolou, piloto automático, soltura, impacto, toque, parada) e as janelas da decolagem, do pouso e da
//! soltura da carga (LAPES). Tudo aqui é função do registro e dos eventos: quem decide quais gráficos existem é a
//! análise, que passa os `simulation.Figures`.
const std = @import("std");
const core = @import("aerosim");
const simulation = @import("simulation");
const analysis = @import("analysis.zig");

const types = core.types;
const Figures = simulation.Figures;
const Row = types.LogRow;
const deg = 180.0 / std.math.pi;
const g0 = 9.80665;

/// as cores por etapa (as mesmas do original)
pub const stage_colors = [_][]const u8{ "#7f7f7f", "#d62728", "#ff7f0e", "#1f77b4", "#2ca02c", "#9467bd", "#8c564b", "#17becf", "#bcbd22", "#e377c2", "#000000", "#aec7e8", "#ffbb78" };
/// a cor da carga lançável
pub const payload_color = "#6a0dad";

/// a cor da etapa `k`
pub fn stageColor(k: usize) []const u8 {
    return stage_colors[k % stage_colors.len];
}

/// as referências que os gráficos marcam (`_refs` do Python)
pub const Refs = struct {
    stall_speed: f64 = 0, // V_s
    alpha_stall_deg: f64 = 14,
    lift_limit: f64 = 0.95, // kCL do piloto
    handover_height: f64 = 2, // h_t
    x_warning: f64 = 0,
    z_warning: ?f64 = null,
    landing_max: f64 = 0,
    load_limit: f64 = 0, // n de projeto
    tail_angle_deg: ?f64 = null, // θ em que a cauda toca o chão
};

/// um voo: o registro, os eventos e as etapas de cada linha
pub const Flight = struct {
    rows: []const Row,
    events: types.Events,
    stage: []const usize,
    names: []const []const u8,

    /// as etapas do voo a partir do registro e dos nomes das pernas
    pub fn init(memory: std.mem.Allocator, rows: []const Row, events: types.Events, legs: []const []const u8) !Flight {
        return .{ .rows = rows, .events = events, .stage = try analysis.stages(memory, rows, events), .names = try analysis.stageNames(memory, legs) };
    }
};

fn isAngle(comptime field: []const u8) bool {
    const angles = [_][]const u8{ "phi", "theta", "psi", "p", "q", "r", "alpha", "beta", "gamma", "chi", "de", "da", "dr", "dw", "phic", "alc", "thc" };
    inline for (angles) |angle| if (comptime std.mem.eql(u8, angle, field)) return true;
    return false;
}

/// o valor de um canal numa linha (os ângulos em graus, como `_col`)
pub fn value(row: Row, comptime field: []const u8) f64 {
    const raw: f64 = @field(row, field);
    return if (comptime isAngle(field)) raw * deg else raw;
}

/// um canal do registro inteiro
pub fn column(memory: std.mem.Allocator, rows: []const Row, comptime field: []const u8) ![]f64 {
    const out = try memory.alloc(f64, rows.len);
    for (rows, out) |row, *item| item.* = value(row, field);
    return out;
}

/// um canal onde `keep` é verdadeiro e NaN no resto
fn columnWhere(memory: std.mem.Allocator, rows: []const Row, comptime field: []const u8, keep: []const bool) ![]f64 {
    const out = try memory.alloc(f64, rows.len);
    for (rows, out, keep) |row, *item, kept| item.* = if (kept) value(row, field) else std.math.nan(f64);
    return out;
}

fn largestMagnitude(values: []const f64) f64 {
    var largest: f64 = 0;
    for (values) |item| if (std.math.isFinite(item)) {
        largest = @max(largest, @abs(item));
    };
    return largest;
}

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn one(memory: std.mem.Allocator, number: f64) ![]f64 {
    return memory.dupe(f64, &.{number});
}

/// a linha do registro no tempo `time` (a primeira com t ≥ time, como `np.searchsorted`)
fn indexAt(rows: []const Row, time: f64) usize {
    for (rows, 0..) |row, k| if (row.t >= time) return k;
    return rows.len - 1;
}

/// as linhas da etapa `k`, mais a primeira da seguinte (a linha não fica com buracos)
fn stageIndices(memory: std.mem.Allocator, flight: Flight, k: usize, extend: bool) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    for (flight.stage, 0..) |which, i| if (which == k) try indices.append(memory, i);
    if (extend and indices.items.len > 0) try indices.append(memory, @min(indices.items[indices.items.len - 1] + 1, flight.rows.len - 1));
    return indices.items;
}

/// uma curva por etapa, na cor dela, de `x_field` contra `y_field`
pub fn byStage(figures: Figures, key: []const u8, flight: Flight, comptime x_field: []const u8, comptime y_field: []const u8) !void {
    const memory = figures.memory;
    for (flight.names, 0..) |name, k| {
        const indices = try stageIndices(memory, flight, k, true);
        if (indices.len == 0) continue;
        const xs = try memory.alloc(f64, indices.len);
        const ys = try memory.alloc(f64, indices.len);
        for (indices, xs, ys) |i, *x, *y| {
            x.* = value(flight.rows[i], x_field);
            y.* = value(flight.rows[i], y_field);
        }
        try figures.curve(key, .{ .name = name, .x = xs, .y = ys, .color = stageColor(k), .width = 2.2 });
    }
}

/// o fundo colorido por etapa, em `x_field` (o tempo, em geral)
pub fn stageSpans(figures: Figures, key: []const u8, flight: Flight, comptime x_field: []const u8) !void {
    const memory = figures.memory;
    for (flight.names, 0..) |name, k| {
        const indices = try stageIndices(memory, flight, k, false);
        if (indices.len < 2) continue;
        const span = try memory.dupe(f64, &.{ value(flight.rows[indices[0]], x_field), value(flight.rows[indices[indices.len - 1]], x_field) });
        try figures.curve(key, .{ .name = name, .x = span, .y = try memory.dupe(f64, &.{ 0, 0 }), .color = stageColor(k), .vspan = true });
    }
}

/// um evento que aconteceu: o nome, o instante e a cor
const Event = struct { name: []const u8, time: f64, color: []const u8 };

fn eventPoints(memory: std.mem.Allocator, flight: Flight) ![]Event {
    var out: std.ArrayList(Event) = .empty;
    const events = flight.events;
    const last = flight.rows[flight.rows.len - 1].t;
    const candidates = [_]Event{
        .{ .name = "decolou", .time = events.tLO, .color = "#1f77b4" },
        .{ .name = "piloto automático", .time = events.tHt, .color = "#000000" },
        .{ .name = "soltura da carga", .time = events.trel, .color = payload_color },
        .{ .name = "toque no pouso", .time = events.tTD, .color = "#2ca02c" },
    };
    for (candidates) |candidate| if (candidate.time > 0 and candidate.time <= last) try out.append(memory, candidate);
    if (events.completed != 0 and events.tTD > 0) try out.append(memory, .{ .name = "parada", .time = last, .color = "#d62728" });
    return out.items;
}

/// as estrelas dos eventos num gráfico de `x_field` contra `y_field` (e o impacto da carga, no chão)
pub fn eventStars(figures: Figures, key: []const u8, flight: Flight, comptime x_field: []const u8, comptime y_field: []const u8) !void {
    const memory = figures.memory;
    for (try eventPoints(memory, flight)) |event| {
        const row = flight.rows[indexAt(flight.rows, event.time)];
        try figures.curve(key, .{ .name = try text(memory, "★ {s}", .{event.name}), .x = try one(memory, value(row, x_field)), .y = try one(memory, value(row, y_field)), .color = event.color, .marker = "star", .size = 18 });
    }
    if (flight.events.pk_t > 0) {
        const ground = [_]struct { []const u8, f64 }{ .{ "n", flight.events.pk_n }, .{ "e", flight.events.pk_e }, .{ "h", 0 } };
        const x = groundValue(&ground, x_field) orelse return;
        const y = groundValue(&ground, y_field) orelse return;
        try figures.curve(key, .{ .name = "★ impacto da carga", .x = try one(memory, x), .y = try one(memory, y), .color = payload_color, .marker = "star", .size = 18 });
    }
}

fn groundValue(ground: []const struct { []const u8, f64 }, field: []const u8) ?f64 {
    for (ground) |entry| if (std.mem.eql(u8, entry[0], field)) return entry[1];
    return null;
}

/// a carga com paraquedas (os canais pk_*)
fn payloadPath(figures: Figures, key: []const u8, flight: Flight, comptime x_field: []const u8, comptime y_field: []const u8) !void {
    const memory = figures.memory;
    var xs: std.ArrayList(f64) = .empty;
    var ys: std.ArrayList(f64) = .empty;
    for (flight.rows) |row| if (row.pk_h > 0) {
        try xs.append(memory, @field(row, "pk_" ++ x_field));
        try ys.append(memory, @field(row, "pk_" ++ y_field));
    };
    if (xs.items.len < 2) return;
    try figures.curve(key, .{ .name = "carga LAPES", .x = xs.items, .y = ys.items, .color = payload_color, .width = 3 });
}

fn anyTerrain(rows: []const Row) bool {
    for (rows) |row| if (row.hgnd > 0) return true;
    return false;
}

/// a trajetória em 3D e nos três planos, cada um com as etapas coloridas, a carga, os eventos e o terreno
pub fn trajectory(figures: Figures, flight: Flight, target: ?[2]f64) !void {
    const memory = figures.memory;
    const rows = flight.rows;
    // 3D: (e, n, h)
    for (flight.names, 0..) |name, k| {
        const indices = try stageIndices(memory, flight, k, true);
        if (indices.len == 0) continue;
        const points = try memory.alloc(f64, 3 * indices.len);
        for (indices, 0..) |i, j| points[3 * j ..][0..3].* = .{ rows[i].e, rows[i].n, rows[i].h };
        try figures.line("t3", .{ .name = name, .points = points, .color = stageColor(k), .width = 2.2 });
    }
    var carried: std.ArrayList(f64) = .empty;
    for (rows) |row| if (row.pk_h > 0) try carried.appendSlice(memory, &.{ row.pk_e, row.pk_n, row.pk_h });
    if (carried.items.len >= 6) try figures.line("t3", .{ .name = "carga LAPES", .points = carried.items, .color = payload_color, .width = 3 });
    const shadow = try memory.alloc(f64, 3 * rows.len);
    for (rows, 0..) |row, j| shadow[3 * j ..][0..3].* = .{ row.e, row.n, row.hgnd };
    try figures.line("t3", .{ .name = "sombra", .points = shadow, .color = "#b0b0b0", .width = 1 });
    for (try eventPoints(memory, flight)) |event| {
        const row = rows[indexAt(rows, event.time)];
        try figures.line("t3", .{ .name = event.name, .kind = .points, .points = try memory.dupe(f64, &.{ row.e, row.n, row.h }), .color = event.color, .size = 18 });
    }
    if (flight.events.pk_t > 0) try figures.line("t3", .{ .name = "impacto da carga", .kind = .points, .points = try memory.dupe(f64, &.{ flight.events.pk_e, flight.events.pk_n, 0 }), .color = payload_color, .size = 18 });
    // os planos: XY (n, e), XZ (n, h) e ZY (e, h)
    try byStage(figures, "xy", flight, "n", "e");
    try payloadPath(figures, "xy", flight, "n", "e");
    try eventStars(figures, "xy", flight, "n", "e");
    try byStage(figures, "xz", flight, "n", "h");
    try payloadPath(figures, "xz", flight, "n", "h");
    try eventStars(figures, "xz", flight, "n", "h");
    try byStage(figures, "zy", flight, "e", "h");
    try payloadPath(figures, "zy", flight, "e", "h");
    try eventStars(figures, "zy", flight, "e", "h");
    try terrainProfile(figures, "xz", rows);
    if (target) |aim| {
        try figures.curve("xy", .{ .name = "alvo da carga", .x = try one(memory, aim[0]), .y = try one(memory, aim[1]), .color = "#000000", .marker = "t", .size = 14 });
        try figures.curve("xz", .{ .name = "alvo da carga", .x = try one(memory, aim[0]), .y = try one(memory, 0), .color = "#000000", .marker = "t", .size = 14 });
    }
}

/// o chão, a mesa ou a plataforma sob o avião, ao longo de n
pub fn terrainProfile(figures: Figures, key: []const u8, rows: []const Row) !void {
    if (!anyTerrain(rows)) return;
    try figures.curve(key, .{ .name = "terreno", .x = try column(figures.memory, rows, "n"), .y = try column(figures.memory, rows, "hgnd"), .color = "#5b3a1a", .width = 3 });
}

/// uma curva no tempo
const TimeCurve = struct { name: []const u8, y: []const f64, color: []const u8, width: f64 };
/// uma reta horizontal de referência
const Level = struct { name: []const u8, value: f64, color: []const u8, dashed: bool = true };

fn timeFigure(figures: Figures, key: []const u8, flight: Flight, times: []const f64, curves: []const TimeCurve, levels: []const Level) !void {
    try stageSpans(figures, key, flight, "t");
    for (curves) |item| try figures.curve(key, .{ .name = item.name, .x = times, .y = item.y, .color = item.color, .width = item.width });
    for (levels) |level| try figures.guide(key, .{ .name = level.name, .value = level.value, .vertical = false, .color = level.color, .dashed = level.dashed });
}

fn unwrapDegrees(memory: std.mem.Allocator, rows: []const Row, comptime field: []const u8) ![]f64 {
    const out = try memory.alloc(f64, rows.len);
    var offset: f64 = 0;
    for (rows, out, 0..) |row, *item, k| {
        if (k > 0) {
            const jump = @field(row, field) - @field(rows[k - 1], field);
            if (jump > std.math.pi) offset -= 2 * std.math.pi else if (jump < -std.math.pi) offset += 2 * std.math.pi;
        }
        item.* = (@field(row, field) + offset) * deg;
    }
    return out;
}

/// os gráficos no tempo com o fundo por etapa: ângulos, rumo, velocidades, altura, C_L, C_D, momentos por parcela,
/// comandos, acelerador, subida, fator de carga, motor, energia e sloshing
pub fn timeSeries(figures: Figures, flight: Flight, refs: Refs, tanks: usize) !void {
    const memory = figures.memory;
    const rows = flight.rows;
    const times = try column(memory, rows, "t");
    const flying = try memory.alloc(bool, rows.len);
    for (rows, flying) |row, *flies| flies.* = row.Va > 6;

    try timeFigure(figures, "ang", flight, times, &.{
        .{ .name = "θ", .y = try column(memory, rows, "theta"), .color = "#1f77b4", .width = 1.4 },
        .{ .name = "α", .y = try columnWhere(memory, rows, "alpha", flying), .color = "#d62728", .width = 1.4 },
        .{ .name = "γ", .y = try column(memory, rows, "gamma"), .color = "#2ca02c", .width = 1.2 },
        .{ .name = "φ", .y = try column(memory, rows, "phi"), .color = "#ff7f0e", .width = 1.2 },
        .{ .name = "β", .y = try columnWhere(memory, rows, "beta", flying), .color = "#9467bd", .width = 1.0 },
    }, &.{.{ .name = "α de estol", .value = refs.alpha_stall_deg, .color = "#000000" }});
    try timeFigure(figures, "rumo", flight, times, &.{
        .{ .name = "ψ", .y = try unwrapDegrees(memory, rows, "psi"), .color = "#1f77b4", .width = 1.4 },
        .{ .name = "χ", .y = try unwrapDegrees(memory, rows, "chi"), .color = "#2ca02c", .width = 1.0 },
    }, &.{});
    const stall = refs.stall_speed;
    const speed_levels = [_]Level{ .{ .name = "V_s", .value = stall, .color = "#7f7f7f" }, .{ .name = "1,2 V_s", .value = 1.2 * stall, .color = "#7f7f7f" } };
    try timeFigure(figures, "vel", flight, times, &.{
        .{ .name = "V_a", .y = try column(memory, rows, "Va"), .color = "#d62728", .width = 1.6 },
        .{ .name = "V_g", .y = try column(memory, rows, "Vg"), .color = "#1f77b4", .width = 1.0 },
        .{ .name = "V_ref", .y = try column(memory, rows, "Vref"), .color = "#000000", .width = 0.8 },
    }, if (stall != 0) &speed_levels else &.{});
    const reference_on = try memory.alloc(bool, rows.len);
    for (rows, reference_on) |row, *on| on.* = flight.events.tHt >= 0 and row.t >= flight.events.tHt;
    var height_curves: std.ArrayList(TimeCurve) = .empty;
    try height_curves.appendSlice(memory, &.{
        .{ .name = "h", .y = try column(memory, rows, "h"), .color = "#d62728", .width = 1.6 },
        .{ .name = "h_ref", .y = try columnWhere(memory, rows, "href", reference_on), .color = "#000000", .width = 0.8 },
    });
    if (anyTerrain(rows)) try height_curves.append(memory, .{ .name = "terreno", .y = try column(memory, rows, "hgnd"), .color = "#5b3a1a", .width = 1.5 });
    try timeFigure(figures, "alt", flight, times, height_curves.items, &.{});
    try timeFigure(figures, "cl", flight, times, &.{
        .{ .name = "C_L", .y = try columnWhere(memory, rows, "CL", flying), .color = "#000000", .width = 1.6 },
        .{ .name = "C_L asa", .y = try columnWhere(memory, rows, "CL_wing", flying), .color = "#1f77b4", .width = 1.0 },
        .{ .name = "C_L EH", .y = try columnWhere(memory, rows, "CL_ht", flying), .color = "#2ca02c", .width = 1.0 },
        .{ .name = "C_L/C_Lmax", .y = try columnWhere(memory, rows, "ratioCL", flying), .color = "#d62728", .width = 0.9 },
    }, &.{.{ .name = "limite", .value = refs.lift_limit, .color = "#d62728" }});
    const drag = try columnWhere(memory, rows, "CD", flying);
    const induced = try columnWhere(memory, rows, "CDi", flying);
    const parasite = try memory.alloc(f64, rows.len);
    for (parasite, drag, induced) |*item, total, part| item.* = total - part;
    try timeFigure(figures, "cd", flight, times, &.{
        .{ .name = "C_D", .y = drag, .color = "#000000", .width = 1.6 },
        .{ .name = "C_Di", .y = induced, .color = "#1f77b4", .width = 1.0 },
        .{ .name = "C_D0", .y = parasite, .color = "#7f7f7f", .width = 1.0 },
    }, &.{});
    try momentFigure(figures, flight, times, "momL", "L");
    try momentFigure(figures, flight, times, "momM", "M");
    try momentFigure(figures, flight, times, "momN", "N");
    const commands = [_]TimeCurve{
        .{ .name = "δ_e", .y = try column(memory, rows, "de"), .color = "#2ca02c", .width = 1.2 },
        .{ .name = "δ_a", .y = try column(memory, rows, "da"), .color = "#1f77b4", .width = 1.2 },
        .{ .name = "δ_r", .y = try column(memory, rows, "dr"), .color = "#ff7f0e", .width = 1.2 },
        .{ .name = "δ_w", .y = try column(memory, rows, "dw"), .color = "#7f7f7f", .width = 1.0 },
    };
    var moving: std.ArrayList(TimeCurve) = .empty;
    for (commands) |command| if (largestMagnitude(command.y) > 1e-6) try moving.append(memory, command);
    try timeFigure(figures, "cmd", flight, times, if (moving.items.len > 0) moving.items else commands[0..1], &.{});
    try timeFigure(figures, "thr", flight, times, &.{.{ .name = "acelerador", .y = try column(memory, rows, "thr"), .color = "#d62728", .width = 1.4 }}, &.{});
    try timeFigure(figures, "roc", flight, times, &.{.{ .name = "dh/dt", .y = try column(memory, rows, "hdot"), .color = "#2ca02c", .width = 1.4 }}, &.{.{ .name = "zero", .value = 0, .color = "#000000" }});

    // fator de carga na curva: o n que a inclinação pede (curva nivelada, n = 1/cos φ) e o n em que a seção mais
    // carregada da asa chega ao C_Lmax na V do momento (n_estol = n_z/ratioCL). Quando n_z encosta em n_estol, a asa
    // estola. Anderson, Introduction to Flight, §6.17 (número das equações a conferir no PDF)
    const turn_load = try memory.alloc(f64, rows.len);
    const stall_load = try memory.alloc(f64, rows.len);
    var stalled_times: std.ArrayList(f64) = .empty;
    var stalled_loads: std.ArrayList(f64) = .empty;
    for (rows, flying, turn_load, stall_load) |row, flies, *turn, *at_stall| {
        const air = flies and row.h - row.hgnd > 0.3; // no chão o trem sustenta: n_z/ratioCL não diz nada
        turn.* = if (air) 1 / @max(@cos(row.phi), 1e-3) else std.math.nan(f64);
        at_stall.* = if (air and row.ratioCL > 0.05) row.nz / @max(row.ratioCL, 1e-9) else std.math.nan(f64);
        if (air and row.ratioCL >= 1) {
            try stalled_times.append(memory, row.t);
            try stalled_loads.append(memory, row.nz);
        }
    }
    var load_levels: std.ArrayList(Level) = .empty;
    try load_levels.append(memory, .{ .name = "1 g", .value = 1, .color = "#000000" });
    if (refs.load_limit != 0) try load_levels.append(memory, .{ .name = try text(memory, "n estrutural = {d}", .{refs.load_limit}), .value = refs.load_limit, .color = "#7f7f7f" });
    try timeFigure(figures, "nz", flight, times, &.{
        .{ .name = "n_z", .y = try column(memory, rows, "nz"), .color = "#d62728", .width = 1.4 },
        .{ .name = "n p/ curva nivelada (1/cos φ)", .y = turn_load, .color = "#1f77b4", .width = 1.0 },
        .{ .name = "n no estol (na V do momento)", .y = stall_load, .color = "#000000", .width = 1.2 },
    }, load_levels.items);
    if (stalled_times.items.len > 0) try figures.curve("nz", .{ .name = "estol (C_L = C_Lmax)", .x = stalled_times.items, .y = stalled_loads.items, .color = "#d62728", .marker = "x", .size = 7 });
    const rpm = try memory.alloc(f64, rows.len);
    const current = try column(memory, rows, "Ibat");
    for (rows, rpm) |row, *item| item.* = row.rpm[0] / 100;
    try timeFigure(figures, "motor", flight, times, &.{
        .{ .name = "rpm/100", .y = rpm, .color = "#d62728", .width = 1.2 },
        .{ .name = "I (A)", .y = current, .color = "#1f77b4", .width = 1.2 },
        .{ .name = "T (N)", .y = try column(memory, rows, "T"), .color = "#2ca02c", .width = 1.2 },
    }, &.{});
    try timeFigure(figures, "ene", flight, times, &.{.{ .name = "E (Wh)", .y = try column(memory, rows, "E"), .color = "#2ca02c", .width = 1.6 }}, &.{});
    if (tanks > 0) {
        const along = try memory.alloc(f64, rows.len);
        const across = try memory.alloc(f64, rows.len);
        for (rows, along, across) |row, *x, *y| {
            x.* = row.slosh_x[0] * deg;
            y.* = row.slosh_y[0] * deg;
        }
        if (largestMagnitude(along) > 1e-9 * deg) try timeFigure(figures, "slosh", flight, times, &.{
            .{ .name = "η_x", .y = along, .color = "#1f77b4", .width = 1.0 },
            .{ .name = "η_y", .y = across, .color = "#d62728", .width = 1.0 },
        }, &.{});
    }
}

/// as parcelas dos momentos (o canal do registro, o rótulo e a cor)
const components = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "wing", "asa", "#1f77b4" },     .{ "ht", "EH", "#2ca02c" },        .{ "vt", "EV", "#9467bd" },
    .{ "fus", "fuselagem", "#8c564b" }, .{ "prop", "hélice", "#d62728" },  .{ "gyro", "giroscópico", "#e377c2" },
    .{ "gear", "trem", "#7f7f7f" },     .{ "liq", "líquido", "#17becf" }, .{ "pay", "LAPES", payload_color },
};

fn momentFigure(figures: Figures, flight: Flight, times: []const f64, key: []const u8, comptime axis: []const u8) !void {
    const memory = figures.memory;
    var curves: std.ArrayList(TimeCurve) = .empty;
    inline for (components) |component| {
        const values = try column(memory, flight.rows, axis ++ "_" ++ component[0]);
        if (largestMagnitude(values) > 1e-6) try curves.append(memory, .{ .name = component[1], .y = values, .color = component[2], .width = 0.9 });
    }
    try curves.append(memory, .{ .name = "total", .y = try column(memory, flight.rows, axis ++ "_tot"), .color = "#000000", .width = 1.6 });
    try timeFigure(figures, key, flight, times, curves.items, &.{});
}

/// o passeio do CG no voo (% da CMA) e a margem estática ME = x_PN − x_CG (% da CMA), com o ponto neutro de manche
/// fixo fixo no voo; a faixa recomendada vai de `margin_min` a `margin_max` (os padrões da Estabilidade)
pub fn cgSeries(figures: Figures, flight: Flight, mac_leading_edge: f64, mac_chord: f64, neutral_percent: f64, margin_min: f64, margin_max: f64) !void {
    if (mac_chord <= 0) return;
    const memory = figures.memory;
    const rows = flight.rows;
    const times = try column(memory, rows, "t");
    const position = try memory.alloc(f64, rows.len);
    const margin = try memory.alloc(f64, rows.len);
    for (rows, position, margin) |row, *cg, *static_margin| {
        cg.* = 100 * (mac_leading_edge - row.xcg) / mac_chord;
        static_margin.* = neutral_percent - cg.*;
    }
    try timeFigure(figures, "cgp", flight, times, &.{.{ .name = "x_CG", .y = position, .color = "#d62728", .width = 2 }}, &.{
        .{ .name = "ponto neutro", .value = neutral_percent, .color = "#000000" },
        .{ .name = try text(memory, "limite traseiro (ME {d} %)", .{margin_min}), .value = neutral_percent - margin_min, .color = "#d62728" },
        .{ .name = try text(memory, "ME {d} %", .{margin_max}), .value = neutral_percent - margin_max, .color = "#7f7f7f" },
    });
    try timeFigure(figures, "mem", flight, times, &.{.{ .name = "margem estática", .y = margin, .color = "#1f77b4", .width = 2 }}, &.{
        .{ .name = try text(memory, "mínima ({d} %)", .{margin_min}), .value = margin_min, .color = "#d62728" },
        .{ .name = try text(memory, "máxima recomendada ({d} %)", .{margin_max}), .value = margin_max, .color = "#7f7f7f" },
    });
}

/// o fim da janela da decolagem: 4 s depois do piloto automático (ou o fim do registro)
fn takeoffEnd(flight: Flight) f64 {
    return if (flight.events.tHt > 0) flight.events.tHt + 4 else flight.rows[flight.rows.len - 1].t;
}

fn takeoffRows(flight: Flight) []const Row {
    const end = takeoffEnd(flight);
    var count: usize = 0;
    for (flight.rows) |row| {
        if (row.t > end) break;
        count += 1;
    }
    return flight.rows[0..count];
}

/// uma reta vertical da janela da decolagem
const Mark = struct { name: []const u8, at: f64, color: []const u8, dashed: bool = true, width: f64 = 0 };

/// a decolagem com a posição na pista no eixo x: altura e folga da cauda, velocidades, ângulos, comandos, reações e
/// momentos do trem, com as marcas do acionamento, da saída da bequilha, da decolagem e do piloto automático
pub fn takeoffWindow(figures: Figures, flight: Flight, refs: Refs, table_length: ?f64) !void {
    const memory = figures.memory;
    const rows = takeoffRows(flight);
    if (rows.len < 3) return;
    const events = flight.events;
    const positions = try column(memory, rows, "n");
    var marks: std.ArrayList(Mark) = .empty;
    if (events.tR >= 0) try marks.append(memory, .{ .name = "aciona o profundor", .at = interpolate(flight.rows, events.tR), .color = "#2ca02c" });
    if (events.tRot > 0) try marks.append(memory, .{ .name = "bequilha sai do chão", .at = events.nRot, .color = "#ff7f0e" });
    if (events.tLO > 0) try marks.append(memory, .{ .name = "decolou", .at = events.nLO, .color = "#1f77b4" });
    if (events.tHt > 0) try marks.append(memory, .{ .name = "h_t", .at = events.nHt, .color = "#000000" });
    if (table_length) |edge| try marks.append(memory, .{ .name = "borda da mesa", .at = edge, .color = "#5b3a1a" });
    if (refs.x_warning > 0) try marks.append(memory, .{ .name = try text(memory, "x_warning = {d} m", .{refs.x_warning}), .at = refs.x_warning, .color = "#d62728", .dashed = false, .width = 3 });
    const keys = [_][]const u8{ "dh", "dv", "da", "dc", "dr", "dm" };
    for (keys) |key| for (marks.items) |mark| try figures.guide(key, .{ .name = mark.name, .value = mark.at, .vertical = true, .color = mark.color, .dashed = mark.dashed, .width = mark.width });

    const rest = rows[0].h;
    const height = try memory.alloc(f64, rows.len);
    const tail = try memory.alloc(f64, rows.len);
    for (rows, height, tail) |row, *h, *clearance| {
        h.* = row.h - rest;
        clearance.* = if (row.htail < 1e6) row.htail else std.math.nan(f64);
    }
    try figures.curve("dh", .{ .name = "h do CG", .x = positions, .y = height, .color = "#d62728", .width = 1.6 });
    try figures.curve("dh", .{ .name = "folga da cauda", .x = positions, .y = tail, .color = "#7f7f7f", .width = 1.2 });
    if (anyTerrain(rows)) {
        const table = try memory.alloc(f64, rows.len);
        for (rows, table) |row, *item| item.* = row.hgnd - rows[0].hgnd;
        try figures.curve("dh", .{ .name = "mesa", .x = positions, .y = table, .color = "#5b3a1a", .width = 2 });
    }
    try figures.guide("dh", .{ .name = "h_t", .value = refs.handover_height, .vertical = false, .color = "#000000", .dashed = true });
    if (refs.z_warning) |z_warning| try figures.guide("dh", .{ .name = try text(memory, "z_warning = {d} m", .{z_warning}), .value = z_warning, .vertical = false, .color = "#d62728" });
    try figures.curve("dv", .{ .name = "V_a", .x = positions, .y = try column(memory, rows, "Va"), .color = "#d62728", .width = 1.6 });
    try figures.curve("dv", .{ .name = "V_g", .x = positions, .y = try column(memory, rows, "Vg"), .color = "#1f77b4", .width = 1.2 });
    if (refs.stall_speed != 0) {
        try figures.guide("dv", .{ .name = "V_s", .value = refs.stall_speed, .vertical = false, .color = "#000000", .dashed = true });
        try figures.guide("dv", .{ .name = "1,2 V_s", .value = 1.2 * refs.stall_speed, .vertical = false, .color = "#000000", .dashed = true });
    }
    try figures.curve("da", .{ .name = "θ", .x = positions, .y = try column(memory, rows, "theta"), .color = "#1f77b4", .width = 1.4 });
    try figures.curve("da", .{ .name = "α", .x = positions, .y = try column(memory, rows, "alpha"), .color = "#d62728", .width = 1.4 });
    try figures.curve("da", .{ .name = "γ", .x = positions, .y = try column(memory, rows, "gamma"), .color = "#2ca02c", .width = 1.2 });
    try figures.guide("da", .{ .name = "α de estol", .value = refs.alpha_stall_deg, .vertical = false, .color = "#d62728", .dashed = true });
    if (refs.tail_angle_deg) |angle| try figures.guide("da", .{ .name = "θ cauda", .value = angle, .vertical = false, .color = "#7f7f7f", .dashed = true });
    const throttle = try column(memory, rows, "thr");
    for (throttle) |*item| item.* *= 10;
    const commands = [_]struct { []const u8, []const f64, []const u8, f64 }{
        .{ "δ_e", try column(memory, rows, "de"), "#2ca02c", 1.4 },
        .{ "δ_w", try column(memory, rows, "dw"), "#7f7f7f", 1.0 },
        .{ "δ_r", try column(memory, rows, "dr"), "#ff7f0e", 1.0 },
        .{ "δ_a", try column(memory, rows, "da"), "#1f77b4", 1.0 },
        .{ "acel. × 10", throttle, "#d62728", 1.0 },
    };
    for (commands) |command| if (largestMagnitude(command[1]) > 1e-6) try figures.curve("dc", .{ .name = command[0], .x = positions, .y = command[1], .color = command[2], .width = command[3] });

    // as fases do artigo (Riboldi et al.): a corrida (eq. 5) até TDN = 0; a rotação (eq. 6) até R_N = 0
    const nose = try column(memory, rows, "Rnw");
    const main = try column(memory, rows, "Rmw");
    var rolling_end: usize = rows.len;
    for (nose, 0..) |item, k| if (item <= 0) {
        rolling_end = k;
        break;
    };
    for (nose[rolling_end..], main[rolling_end..], rows[rolling_end..]) |*front, *back, row| {
        front.* = 0;
        back.* = row.RN;
    }
    var rotation_end: usize = rows.len;
    for (rows[rolling_end..], rolling_end..) |row, k| if (row.RN <= 0) {
        rotation_end = k;
        break;
    };
    for (nose[rotation_end..], main[rotation_end..]) |*front, *back| {
        front.* = 0;
        back.* = 0;
    }
    const last = @min(rotation_end, rows.len - 1);
    for (nose[last + 1 ..], main[last + 1 ..]) |*front, *back| {
        front.* = std.math.nan(f64);
        back.* = std.math.nan(f64);
    }
    try figures.curve("dr", .{ .name = "TDN", .x = positions, .y = try column(memory, rows, "N_steer"), .color = "#ff7f0e", .width = 2 });
    try figures.curve("dr", .{ .name = "TDP", .x = positions, .y = try column(memory, rows, "N_main"), .color = "#1f77b4", .width = 2 });
    const skid = try column(memory, rows, "N_skid");
    if (largestMagnitude(skid) > 0) try figures.curve("dr", .{ .name = "cauda", .x = positions, .y = skid, .color = "#7f7f7f", .width = 1.2 });
    try figures.curve("dr", .{ .name = "TDN artigo", .x = positions, .y = nose, .color = "#ff7f0e", .width = 1, .dashed = true });
    try figures.curve("dr", .{ .name = "TDP artigo", .x = positions, .y = main, .color = "#1f77b4", .width = 1, .dashed = true });
    try figures.curve("dm", .{ .name = "L", .x = positions, .y = try column(memory, rows, "L_gear"), .color = "#1f77b4", .width = 1.4 });
    try figures.curve("dm", .{ .name = "M", .x = positions, .y = try column(memory, rows, "M_gear"), .color = "#d62728", .width = 1.6 });
    try figures.curve("dm", .{ .name = "N", .x = positions, .y = try column(memory, rows, "N_gear"), .color = "#2ca02c", .width = 1.4 });
}

/// n no instante `time` (interpolado no registro, como `np.interp`)
fn interpolate(rows: []const Row, time: f64) f64 {
    if (time <= rows[0].t) return rows[0].n;
    for (rows[1..], 1..) |row, k| if (row.t >= time) {
        const before = rows[k - 1];
        const span = row.t - before.t;
        return if (span > 0) before.n + (row.n - before.n) * (time - before.t) / span else row.n;
    };
    return rows[rows.len - 1].n;
}

/// o ângulo do avião (θ) e o da asa (θ + incidência) no tempo, na decolagem, com o estol da asa
pub fn takeoffAngles(figures: Figures, flight: Flight, wing_incidence_deg: f64, alpha_stall_deg: f64) !void {
    const memory = figures.memory;
    const rows = takeoffRows(flight);
    if (rows.len == 0) return;
    const times = try column(memory, rows, "t");
    const pitch = try column(memory, rows, "theta");
    const wing = try memory.alloc(f64, rows.len);
    const wing_alpha = try memory.alloc(f64, rows.len);
    for (rows, pitch, wing, wing_alpha) |row, theta, *angle, *alpha| {
        angle.* = theta + wing_incidence_deg;
        alpha.* = row.alpha * deg + wing_incidence_deg;
    }
    try figures.curve("dt", .{ .name = "θ", .x = times, .y = pitch, .color = "#1f77b4", .width = 2.2 });
    try figures.curve("dt", .{ .name = "θ + i_w", .x = times, .y = wing, .color = "#ff7f0e", .width = 2.2 });
    try figures.curve("dt", .{ .name = "α asa", .x = times, .y = wing_alpha, .color = "#2ca02c", .width = 1, .dashed = true });
    try figures.guide("dt", .{ .name = try text(memory, "estol ({d:.0}°)", .{alpha_stall_deg}), .value = alpha_stall_deg, .vertical = false, .color = "#d62728", .dashed = true });
    const marks = [_]struct { []const u8, f64 }{ .{ "aciona o profundor", flight.events.tR }, .{ "decolou", flight.events.tLO }, .{ "piloto automático", flight.events.tHt } };
    for (marks) |mark| if (mark[1] > 0) try figures.guide("dt", .{ .name = mark[0], .value = mark[1], .vertical = true, .color = "#7f7f7f", .dashed = true });
}

/// a decolagem no tempo: C_L, C_D, sustentação e arrasto, e cada momento junto do comando daquele eixo
pub fn takeoffTime(figures: Figures, flight: Flight, density: f64, area: f64) !void {
    const memory = figures.memory;
    const rows = takeoffRows(flight);
    if (rows.len == 0) return;
    const times = try column(memory, rows, "t");
    const lift = try memory.alloc(f64, rows.len);
    const drag = try memory.alloc(f64, rows.len);
    for (rows, lift, drag) |row, *force_lift, *force_drag| {
        const dynamic_area = 0.5 * density * row.Va * row.Va * area;
        force_lift.* = row.CL * dynamic_area;
        force_drag.* = row.CD * dynamic_area;
    }
    try figures.curve("tcl", .{ .name = "C_L", .x = times, .y = try column(memory, rows, "CL"), .color = "#000000", .width = 2 });
    try figures.curve("tcl", .{ .name = "C_L asa", .x = times, .y = try column(memory, rows, "CL_wing"), .color = "#1f77b4" });
    const tail = try column(memory, rows, "CL_ht");
    if (largestMagnitude(tail) > 1e-6) try figures.curve("tcl", .{ .name = "C_L EH", .x = times, .y = tail, .color = "#2ca02c" });
    try figures.curve("tcd", .{ .name = "C_D", .x = times, .y = try column(memory, rows, "CD"), .color = "#000000", .width = 2 });
    try figures.curve("tcd", .{ .name = "C_Di", .x = times, .y = try column(memory, rows, "CDi"), .color = "#1f77b4" });
    try figures.curve("tld", .{ .name = "L", .x = times, .y = lift, .color = "#1f77b4", .width = 2 });
    try figures.curve("tld", .{ .name = "D", .x = times, .y = drag, .color = "#d62728", .width = 2 });
    try figures.guide("tld", .{ .name = "W", .value = flight.rows[0].m * g0, .vertical = false, .color = "#7f7f7f", .dashed = true });
    inline for (.{ .{ "tmL", "L", "da", "δ_a", "#1f77b4" }, .{ "tmM", "M", "de", "δ_e", "#2ca02c" }, .{ "tmN", "N", "dr", "δ_r", "#1f77b4" } }) |axis| {
        try figures.curve(axis[0], .{ .name = axis[1] ++ " (N·m)", .x = times, .y = try column(memory, rows, axis[1] ++ "_tot"), .color = "#000000", .width = 2 });
        const command = try column(memory, rows, axis[2]);
        if (largestMagnitude(command) > 1e-6) try figures.curve(axis[0], .{ .name = axis[3] ++ " (°)", .x = times, .y = command, .color = axis[4], .dashed = true });
    }
    const marks = [_]struct { []const u8, f64 }{ .{ "aciona", flight.events.tR }, .{ "decolou", flight.events.tLO }, .{ "h_t", flight.events.tHt } };
    for (marks) |mark| if (mark[1] > 0) for ([_][]const u8{ "tcl", "tcd", "tld", "tmL", "tmM", "tmN" }) |key|
        try figures.guide(key, .{ .name = mark[0], .value = mark[1], .vertical = true, .color = "#7f7f7f", .dashed = true, .legend = false });
}

/// as reações e os momentos do trem depois do toque (a posição na pista no eixo x), a plataforma e o limite da
/// distância de pouso; `platform`: o começo e o fim da plataforma de pouso em n
pub fn landingWindow(figures: Figures, flight: Flight, refs: Refs, platform: ?[2]f64) !void {
    const events = flight.events;
    if (events.tTD <= 0) return;
    const memory = figures.memory;
    var start: usize = flight.rows.len;
    for (flight.rows, 0..) |row, k| if (row.t >= events.tTD - 1) {
        start = k;
        break;
    };
    const rows = flight.rows[start..];
    if (rows.len < 3) return;
    const positions = try column(memory, rows, "n");
    const touching = try memory.alloc(bool, rows.len);
    for (rows, touching) |row, *on| on.* = row.N_steer > 0 or row.N_main > 0;
    try figures.curve("pr", .{ .name = "TDN", .x = positions, .y = try column(memory, rows, "N_steer"), .color = "#ff7f0e", .width = 2 });
    try figures.curve("pr", .{ .name = "TDP", .x = positions, .y = try column(memory, rows, "N_main"), .color = "#1f77b4", .width = 2 });
    try figures.curve("pr", .{ .name = "TDN artigo", .x = positions, .y = try columnWhere(memory, rows, "Rnw", touching), .color = "#ff7f0e", .width = 1, .dashed = true });
    try figures.curve("pr", .{ .name = "TDP artigo", .x = positions, .y = try columnWhere(memory, rows, "Rmw", touching), .color = "#1f77b4", .width = 1, .dashed = true });
    try figures.curve("pm", .{ .name = "L", .x = positions, .y = try column(memory, rows, "L_gear"), .color = "#1f77b4", .width = 1.4 });
    try figures.curve("pm", .{ .name = "M", .x = positions, .y = try column(memory, rows, "M_gear"), .color = "#d62728", .width = 1.6 });
    try figures.curve("pm", .{ .name = "N", .x = positions, .y = try column(memory, rows, "N_gear"), .color = "#2ca02c", .width = 1.4 });
    for ([_][]const u8{ "pr", "pm" }) |key| {
        try figures.curve(key, .{ .name = "★ toque", .x = try one(memory, events.nTD), .y = try one(memory, 0), .color = "#2ca02c", .marker = "star" });
        if (events.completed != 0) try figures.curve(key, .{ .name = "★ parada", .x = try one(memory, events.nStop), .y = try one(memory, 0), .color = "#d62728", .marker = "star" });
        if (platform) |edges| try figures.curve(key, .{ .name = "plataforma de pouso", .x = try memory.dupe(f64, &edges), .y = try memory.dupe(f64, &.{ 0, 0 }), .color = "#5b3a1a", .vspan = true });
        if (refs.landing_max > 0) try figures.guide(key, .{ .name = "distância máxima de pouso", .value = events.nTD + refs.landing_max, .vertical = true, .color = "#d62728", .width = 3 });
    }
}

/// a folga da ponta da pá (a mais baixa) e da cauda sobre o terreno, só perto do chão (folga < 1 m), com a estrela
/// da batida da pá
pub fn groundClearance(figures: Figures, flight: Flight) !void {
    const memory = figures.memory;
    const near = 1.0;
    const rows = flight.rows;
    var close = false;
    for (rows) |row| close = close or row.hprop < near or row.htail < near;
    if (!close) return;
    const times = try column(memory, rows, "t");
    const blade = try memory.alloc(f64, rows.len);
    const tail = try memory.alloc(f64, rows.len);
    for (rows, blade, tail) |row, *prop, *skid| {
        prop.* = if (row.hprop < near) row.hprop else std.math.nan(f64);
        skid.* = if (row.htail < near) row.htail else std.math.nan(f64);
    }
    try figures.curve("fg", .{ .name = "folga da pá", .x = times, .y = blade, .color = "#d62728", .width = 1.6 });
    try figures.curve("fg", .{ .name = "folga da cauda", .x = times, .y = tail, .color = "#7f7f7f", .width = 1.2 });
    try figures.guide("fg", .{ .name = "chão", .value = 0, .vertical = false, .color = "#000000", .dashed = true });
    if (flight.events.tprop >= 0) try figures.curve("fg", .{ .name = "★ a pá tocou o chão", .x = try one(memory, flight.events.tprop), .y = try one(memory, 0), .color = "#d62728", .marker = "star" });
}

/// a soltura da carga de perto: o CG anda para trás com a carga, a massa cai, a resposta em arfagem e o avião e a
/// carga no plano xz
pub fn lapesWindow(figures: Figures, flight: Flight, target_north: ?f64) !void {
    const events = flight.events;
    if (events.tdrop <= 0) return;
    const memory = figures.memory;
    const before = 2.0;
    const after = 5.0;
    const drop = events.tdrop;
    var near: std.ArrayList(usize) = .empty;
    var wide: std.ArrayList(usize) = .empty;
    for (flight.rows, 0..) |row, k| {
        if (row.t >= drop - before and row.t <= drop + after) try near.append(memory, k);
        if (row.t >= drop - before and row.t <= drop + after + 4) try wide.append(memory, k);
    }
    if (near.items.len < 3) return;
    const count = near.items.len;
    const since = try memory.alloc(f64, count);
    for (near.items, since) |k, *time| time.* = flight.rows[k].t - drop;
    const extraction_end = if (events.trel > 0) events.trel - drop else 0;
    for ([_][]const u8{ "lc", "lm", "lp" }) |key| try figures.curve(key, .{ .name = "extração", .x = try memory.dupe(f64, &.{ 0, extraction_end }), .y = try memory.dupe(f64, &.{ 0, 0 }), .color = payload_color, .vspan = true });
    const pick = struct {
        fn of(memory_: std.mem.Allocator, rows: []const Row, indices: []const usize, comptime field: []const u8, scale: f64) ![]f64 {
            const out = try memory_.alloc(f64, indices.len);
            for (indices, out) |k, *item| item.* = value(rows[k], field) * scale;
            return out;
        }
    }.of;
    try figures.curve("lc", .{ .name = "x_CG", .x = since, .y = try pick(memory, flight.rows, near.items, "xcg", 100), .color = "#1f77b4" });
    try figures.curve("lc", .{ .name = "carga na baia", .x = since, .y = try pick(memory, flight.rows, near.items, "sL", 100), .color = payload_color });
    try figures.curve("lm", .{ .name = "m", .x = since, .y = try pick(memory, flight.rows, near.items, "m", 1), .color = "#d62728" });
    try figures.curve("lp", .{ .name = "θ (°)", .x = since, .y = try pick(memory, flight.rows, near.items, "theta", 1), .color = "#1f77b4" });
    try figures.curve("lp", .{ .name = "α (°)", .x = since, .y = try pick(memory, flight.rows, near.items, "alpha", 1), .color = "#d62728" });
    try figures.curve("lp", .{ .name = "q (°/s)", .x = since, .y = try pick(memory, flight.rows, near.items, "q", 1), .color = "#ff7f0e" });
    try figures.curve("lp", .{ .name = "δe (°)", .x = since, .y = try pick(memory, flight.rows, near.items, "de", 1), .color = "#2ca02c" });
    try figures.curve("lp", .{ .name = "M_LAPES (N·m)", .x = since, .y = try pick(memory, flight.rows, near.items, "M_pay", 1), .color = payload_color });
    try figures.curve("lx", .{ .name = "aeronave", .x = try pick(memory, flight.rows, wide.items, "n", 1), .y = try pick(memory, flight.rows, wide.items, "h", 1), .color = "#9467bd", .width = 2 });
    var carried_n: std.ArrayList(f64) = .empty;
    var carried_h: std.ArrayList(f64) = .empty;
    for (flight.rows) |row| if (row.pk_h > 0) {
        try carried_n.append(memory, row.pk_n);
        try carried_h.append(memory, row.pk_h);
    };
    if (carried_n.items.len > 0) try figures.curve("lx", .{ .name = "carga", .x = carried_n.items, .y = carried_h.items, .color = payload_color, .width = 3 });
    const at = flight.rows[indexAt(flight.rows, drop)];
    try figures.curve("lx", .{ .name = "★ extração", .x = try one(memory, at.n), .y = try one(memory, at.h), .color = payload_color, .marker = "star" });
    if (events.pk_t > 0) try figures.curve("lx", .{ .name = "★ impacto da carga", .x = try one(memory, events.pk_n), .y = try one(memory, 0), .color = "#d62728", .marker = "star" });
    if (target_north) |north| try figures.curve("lx", .{ .name = "alvo", .x = try one(memory, north), .y = try one(memory, 0), .color = "#000000", .marker = "t", .size = 14 });
}

/// a silhueta no corpo (x à frente, y à direita, z para baixo), em semienvergaduras: fuselagem, asa, EH e EV
const shape = [_][3]f64{
    .{ 0.45, 0, 0 },   .{ -0.75, 0, 0 },  .{ 0.05, -1, 0 },    .{ 0.05, 1, 0 },  .{ -0.05, -1, 0 }, .{ -0.05, 1, 0 },     .{ 0.05, -1, 0 },
    .{ -0.05, -1, 0 }, .{ 0.05, 1, 0 },   .{ -0.05, 1, 0 },    .{ -0.7, -0.35, 0 }, .{ -0.7, 0.35, 0 }, .{ -0.7, 0, 0 }, .{ -0.78, 0, -0.32 },
};

/// o avião desenhado a cada `step` metros da trajetória, na atitude daquele instante (a cor da etapa); `span`: a
/// envergadura desenhada (m)
pub fn aircraftGlyphs(figures: Figures, flight: Flight, step: f64, span: f64) !void {
    const memory = figures.memory;
    const rows = flight.rows;
    if (step <= 0 or rows.len == 0) return;
    var marks: std.ArrayList(usize) = .empty;
    var travelled: f64 = 0;
    var next: f64 = 0;
    for (rows, 0..) |row, k| {
        if (k > 0) travelled += std.math.hypot(row.n - rows[k - 1].n, row.e - rows[k - 1].e);
        if (travelled >= next) {
            if (marks.items.len == 0 or marks.items[marks.items.len - 1] != k) try marks.append(memory, k);
            while (next <= travelled) next += step;
        }
    }
    for (flight.names, 0..) |name, stage| {
        _ = name;
        var centers: std.ArrayList(f64) = .empty;
        var offsets: std.ArrayList(f64) = .empty;
        for (marks.items) |k| {
            if (flight.stage[k] != stage) continue;
            const row = rows[k];
            const sin_roll = @sin(row.phi);
            const cos_roll = @cos(row.phi);
            const sin_pitch = @sin(row.theta);
            const cos_pitch = @cos(row.theta);
            const sin_yaw = @sin(row.psi);
            const cos_yaw = @cos(row.psi);
            const rotation = [3][3]f64{
                .{ cos_pitch * cos_yaw, sin_roll * sin_pitch * cos_yaw - cos_roll * sin_yaw, cos_roll * sin_pitch * cos_yaw + sin_roll * sin_yaw },
                .{ cos_pitch * sin_yaw, sin_roll * sin_pitch * sin_yaw + cos_roll * cos_yaw, cos_roll * sin_pitch * sin_yaw - sin_roll * cos_yaw },
                .{ -sin_pitch, sin_roll * cos_pitch, cos_roll * cos_pitch },
            };
            for (shape) |corner| {
                var ned: [3]f64 = .{ 0, 0, 0 };
                for (0..3) |i| for (0..3) |j| {
                    ned[i] += rotation[i][j] * corner[j] * span / 2;
                };
                try centers.appendSlice(memory, &.{ row.e, row.n, row.h });
                try offsets.appendSlice(memory, &.{ ned[1], ned[0], -ned[2] });
            }
        }
        if (centers.items.len == 0) continue;
        try figures.line("t3", .{ .name = try text(memory, "✈ {s}", .{flight.names[stage]}), .kind = .segments, .points = centers.items, .offsets = offsets.items, .color = stageColor(stage), .legend = false, .width = 1.6 });
    }
}

/// uma linha da bateria por etapa
pub const BatteryRow = struct {
    name: []const u8,
    duration: f64,
    current_mean: f64,
    current_peak: f64,
    charge_mAh: f64,
    peukert_percent: f64,
    soc_end_percent: f64,
};

/// o tempo, a corrente média e a de pico, o consumo, a descarga e o SOC por etapa (Coulomb e Peukert, Traub 2011);
/// o SOC começa em 100 % e cai. Devolve a tabela e põe os gráficos `bat` e `batp`
pub fn batteryByStage(figures: Figures, flight: Flight, capacity_mAh: f64, peukert: f64, rated_hours: f64) ![]BatteryRow {
    const memory = figures.memory;
    const rows = flight.rows;
    if (rows.len == 0) return &.{};
    const count = rows.len;
    const current = try memory.alloc(f64, count);
    const steps = try memory.alloc(f64, count);
    const life = try memory.alloc(f64, count);
    const charge = try memory.alloc(f64, count);
    const discharge = try memory.alloc(f64, count);
    const capacity = @max(capacity_mAh / 1000, 1e-9);
    var charge_sum: f64 = 0;
    var discharge_sum: f64 = 0;
    for (rows, 0..) |row, k| {
        current[k] = @max(row.Ibat, 0);
        const step = if (k + 1 < count) rows[k + 1].t - row.t else 0;
        steps[k] = if (step > 0) step else 0;
        // Peukert: com corrente I o pacote dura t(I) = R_t (C / (I R_t))^n; a fração gasta é Σ dt / t(I)
        life[k] = if (current[k] > 1e-6) rated_hours * 3600 * std.math.pow(f64, capacity / @max(current[k] * rated_hours, 1e-9), peukert) else std.math.inf(f64);
        charge_sum += current[k] * steps[k];
        charge[k] = charge_sum / 3.6;
        if (std.math.isFinite(life[k])) discharge_sum += steps[k] / life[k];
        discharge[k] = discharge_sum * 100;
    }
    var table: std.ArrayList(BatteryRow) = .empty;
    for (flight.names, 0..) |name, stage| {
        var duration: f64 = 0;
        var charge_here: f64 = 0;
        var peak: f64 = 0;
        var used: f64 = 0;
        var last: ?usize = null;
        var lines: usize = 0;
        for (flight.stage, 0..) |which, k| if (which == stage) {
            lines += 1;
            duration += steps[k];
            charge_here += current[k] * steps[k];
            peak = @max(peak, current[k]);
            if (std.math.isFinite(life[k])) used += steps[k] / life[k];
            last = k;
        };
        if (lines < 2) continue;
        const mAh = charge_here / 3.6;
        try table.append(memory, .{ .name = name, .duration = duration, .current_mean = if (duration > 0) mAh * 3.6 / duration else 0, .current_peak = peak, .charge_mAh = mAh, .peukert_percent = used * 100, .soc_end_percent = 100 - discharge[last.?] });
    }
    var total_time: f64 = 0;
    var peak: f64 = 0;
    for (steps, current) |step, amps| {
        total_time += step;
        peak = @max(peak, amps);
    }
    try table.append(memory, .{ .name = "total", .duration = total_time, .current_mean = charge_sum / @max(total_time, 1e-9), .current_peak = peak, .charge_mAh = charge[count - 1], .peukert_percent = discharge[count - 1], .soc_end_percent = 100 - discharge[count - 1] });

    const times = try column(memory, rows, "t");
    try stageSpans(figures, "bat", flight, "t");
    try figures.curve("bat", .{ .name = "consumo", .x = times, .y = charge, .color = "#1f77b4", .width = 2.2 });
    try figures.guide("bat", .{ .name = try text(memory, "capacidade ({d:.0} mAh)", .{capacity_mAh}), .value = capacity_mAh, .vertical = false, .color = "#d62728", .width = 2 });
    const coulomb = try memory.alloc(f64, count);
    const remaining = try memory.alloc(f64, count);
    for (coulomb, remaining, charge, discharge) |*soc, *left, used, spent| {
        soc.* = 100 - used / capacity_mAh * 100;
        left.* = 100 - spent;
    }
    try stageSpans(figures, "batp", flight, "t");
    try figures.curve("batp", .{ .name = "SOC Coulomb", .x = times, .y = coulomb, .color = "#1f77b4", .width = 2 });
    try figures.curve("batp", .{ .name = "SOC Peukert", .x = times, .y = remaining, .color = "#d62728", .width = 2.4 });
    try figures.guide("batp", .{ .name = "reserva 20 %", .value = 20, .vertical = false, .color = "#d62728", .dashed = true });
    try figures.curve("batp", .{ .name = "I (A)", .x = times, .y = current, .color = "#7f7f7f", .width = 1 });
    return table.items;
}

test "os gráficos do voo compilam" {
    std.testing.refAllDecls(@This());
}

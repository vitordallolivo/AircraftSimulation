//! Pós-processamento dos registros em Zig (o par de `analysis.py`): as etapas do voo, a tabela por etapa e as
//! métricas de uma curva. Tudo aqui é conta sobre o registro do núcleo (`types.LogRow`), sem voar.
const std = @import("std");
const core = @import("aerosim");

const types = core.types;
const deg = 180.0 / std.math.pi;

/// a etapa de cada linha: 0 = corrida no chão, 1..N = pernas, N+1 = rolagem depois do toque
pub fn stages(memory: std.mem.Allocator, rows: []const types.LogRow, events: types.Events) ![]usize {
    const out = try memory.alloc(usize, rows.len);
    var last_segment: f64 = 0;
    for (rows) |row| last_segment = @max(last_segment, row.seg);
    for (rows, out) |row, *stage| {
        stage.* = @as(usize, @intFromFloat(@max(row.seg, 0))) + 1;
        if (events.tLO > 0 and row.t < events.tLO) stage.* = 0;
        if (events.tTD > 0 and row.t >= events.tTD) stage.* = @as(usize, @intFromFloat(last_segment)) + 2;
    }
    return out;
}

/// os nomes das etapas: a corrida, as pernas e a rolagem
pub fn stageNames(memory: std.mem.Allocator, legs: []const []const u8) ![]const []const u8 {
    const names = try memory.alloc([]const u8, legs.len + 2);
    names[0] = "corrida no chão";
    @memcpy(names[1 .. legs.len + 1], legs);
    names[legs.len + 1] = "rolagem";
    return names;
}

/// a derivada numérica de `values` (como `np.gradient`: centrada no meio, de um lado nas pontas)
pub fn gradient(memory: std.mem.Allocator, values: []const f64) ![]f64 {
    const out = try memory.alloc(f64, values.len);
    if (values.len < 2) {
        @memset(out, 0);
        return out;
    }
    out[0] = values[1] - values[0];
    out[values.len - 1] = values[values.len - 1] - values[values.len - 2];
    for (1..values.len - 1) |k| out[k] = 0.5 * (values[k + 1] - values[k - 1]);
    return out;
}

/// uma linha da tabela por etapa
pub const StageRow = struct {
    name: []const u8,
    start: f64,
    duration: f64,
    distance: f64,
    height_min: f64,
    height_max: f64,
    speed_min: f64,
    speed_mean: f64,
    speed_max: f64,
    speed_min_stall: f64, // V_a mínima / V_s
    climb_max: f64,
    descent_max: f64,
    bank_max_deg: f64,
    load_max: f64,
    alpha_max_deg: f64,
    lift_ratio_max: f64, // C_L/C_Lmax
    throttle_mean: f64,
    energy_Wh: f64,
};

/// a tabela por etapa (`stage_table`): uma linha por etapa com pelo menos duas linhas do registro
pub fn stageTable(memory: std.mem.Allocator, rows: []const types.LogRow, events: types.Events, legs: []const []const u8, stall_speed: f64) ![]StageRow {
    if (rows.len == 0) return &.{};
    const stage = try stages(memory, rows, events);
    const names = try stageNames(memory, legs);
    const times = try memory.alloc(f64, rows.len);
    for (rows, times) |row, *time| time.* = row.t;
    const steps = try gradient(memory, times);
    var out: std.ArrayList(StageRow) = .empty;
    for (names, 0..) |name, k| {
        var count: usize = 0;
        var first: ?usize = null;
        var last: usize = 0;
        var line: StageRow = .{ .name = name, .start = 0, .duration = 0, .distance = 0, .height_min = std.math.inf(f64), .height_max = -std.math.inf(f64), .speed_min = std.math.inf(f64), .speed_mean = 0, .speed_max = -std.math.inf(f64), .speed_min_stall = 0, .climb_max = -std.math.inf(f64), .descent_max = -std.math.inf(f64), .bank_max_deg = 0, .load_max = -std.math.inf(f64), .alpha_max_deg = -std.math.inf(f64), .lift_ratio_max = -std.math.inf(f64), .throttle_mean = 0, .energy_Wh = 0 };
        var flying = false;
        for (rows, stage, steps, 0..) |row, which, step, i| {
            if (which != k) continue;
            count += 1;
            if (first == null) first = i;
            last = i;
            line.distance += row.Vg * step;
            line.height_min = @min(line.height_min, row.h);
            line.height_max = @max(line.height_max, row.h);
            line.speed_min = @min(line.speed_min, row.Va);
            line.speed_max = @max(line.speed_max, row.Va);
            line.speed_mean += row.Va;
            line.climb_max = @max(line.climb_max, row.hdot);
            line.descent_max = @max(line.descent_max, -row.hdot);
            line.bank_max_deg = @max(line.bank_max_deg, @abs(row.phi) * deg);
            line.load_max = @max(line.load_max, row.nz);
            line.throttle_mean += row.thr;
            if (row.Va > 4) {
                flying = true;
                line.alpha_max_deg = @max(line.alpha_max_deg, row.alpha * deg);
                line.lift_ratio_max = @max(line.lift_ratio_max, row.ratioCL);
            }
        }
        if (count < 2) continue;
        const counted: f64 = @floatFromInt(count);
        line.start = rows[first.?].t;
        line.duration = rows[last].t - rows[first.?].t;
        line.speed_mean /= counted;
        line.throttle_mean /= counted;
        line.speed_min_stall = if (stall_speed != 0) line.speed_min / stall_speed else std.math.nan(f64);
        if (!flying) {
            line.alpha_max_deg = 0;
            line.lift_ratio_max = 0;
        }
        line.energy_Wh = rows[last].E - rows[first.?].E;
        try out.append(memory, line);
    }
    return out.items;
}

/// por que uma curva não passa
pub const TurnVerdict = enum {
    ok,
    never_reached, // não chegou à curva
    lost_control, // perda de controle
    wing_stall, // estol da asa
    alpha_limit, // asa no limite de α
    off_radius, // não segue o raio
    loses_height, // perde altura

    /// o texto na tela
    pub fn text(verdict: TurnVerdict) []const u8 {
        return switch (verdict) {
            .ok => "ok",
            .never_reached => "não chegou à curva",
            .lost_control => "perda de controle",
            .wing_stall => "estol da asa",
            .alpha_limit => "asa no limite de α",
            .off_radius => "não segue o raio",
            .loses_height => "perde altura",
        };
    }
};

/// as métricas de uma curva: o transitório inteiro e o regime (depois de 90°)
pub const Turn = struct {
    radius: f64,
    speed: f64 = std.math.nan(f64),
    ok: bool = false,
    verdict: TurnVerdict = .never_reached,
    lift_ratio_max: f64 = std.math.nan(f64),
    bank_max_deg: f64 = std.math.nan(f64),
    bank_steady_deg: f64 = std.math.nan(f64),
    load_max: f64 = std.math.nan(f64),
    load_steady: f64 = std.math.nan(f64),
    stall_load_steady: f64 = std.math.nan(f64), // o n em que a asa estola na V do momento
    speed_min: f64 = std.math.nan(f64),
    alpha_steady_deg: f64 = std.math.nan(f64),
    lift_ratio_steady: f64 = std.math.nan(f64),
    height_loss: f64 = std.math.nan(f64),
    climb_steady: f64 = std.math.nan(f64),
    track_error_p90: f64 = std.math.nan(f64),
    radius_flown: f64 = std.math.nan(f64),
    stall_time: f64 = std.math.nan(f64),
    alpha_limit_time: f64 = std.math.nan(f64),
};

/// a mediana (como `np.median`)
pub fn median(memory: std.mem.Allocator, values: []const f64) !f64 {
    return percentile(memory, values, 50);
}

/// o percentil `which` (0 a 100) com interpolação linear, como `np.percentile`
pub fn percentile(memory: std.mem.Allocator, values: []const f64, which: f64) !f64 {
    if (values.len == 0) return std.math.nan(f64);
    const sorted = try memory.dupe(f64, values);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const position = which / 100 * @as(f64, @floatFromInt(sorted.len - 1));
    const below: usize = @intFromFloat(@floor(position));
    const above = @min(below + 1, sorted.len - 1);
    const fraction = position - @floor(position);
    return sorted[below] + fraction * (sorted[above] - sorted[below]);
}

/// o que conta como "a curva foi bem feita" (`Turn.ok`); os padrões são os de sempre
pub const TurnCriteria = struct {
    bank_limit_deg: f64 = 75, // a maior inclinação aceita
    bank_slack_deg: f64 = 15, // quanto a inclinação pode passar desse limite num pico
    radius_tolerance: f64 = 3.0, // erro de trajetória e de raio aceito (m)...
    radius_fraction: f64 = 0.15, // ...ou esta fração do raio, o que for maior
    stall_time: f64 = 0.3, // tempo acima do limite de C_L/C_Lmax que reprova (s)
    height_loss: f64 = 3.0, // perda de altura aceita na curva (m)
    sink: f64 = 0.5, // razão de descida média aceita no trecho estável (m/s)
    lowest_height: f64 = 0.5, // a menor altura aceita (m)
    speed_fraction: f64 = 0.9, // a menor V aceita, em fração da V de estol
};

/// as métricas da curva do segmento `k` de raio `radius` (`evaluate_turn`)
pub fn evaluateTurn(memory: std.mem.Allocator, rows: []const types.LogRow, segment: types.Segment, k: usize, radius: f64, stall_speed: f64, lift_limit: f64, criteria: TurnCriteria) !Turn {
    const bank_limit_deg = criteria.bank_limit_deg;
    var inside: std.ArrayList(usize) = .empty;
    for (rows, 0..) |row, i| if (row.seg == @as(f64, @floatFromInt(k))) try inside.append(memory, i);
    if (inside.items.len < 5) return .{ .radius = radius };
    const times = try memory.alloc(f64, rows.len);
    for (rows, times) |row, *time| time.* = row.t;
    const steps = try gradient(memory, times);
    var steady: std.ArrayList(usize) = .empty;
    for (inside.items) |i| if (rows[i].s >= radius * std.math.pi / 2) try steady.append(memory, i);
    if (steady.items.len < 5) steady = inside;

    var turn: Turn = .{ .radius = radius, .speed = segment.V1 };
    var lift_ratio_max = -std.math.inf(f64);
    var bank_max: f64 = 0;
    var load_max = -std.math.inf(f64);
    var speed_min = std.math.inf(f64);
    var lowest = std.math.inf(f64);
    var stall_time: f64 = 0;
    var alpha_limit_time: f64 = 0;
    for (inside.items) |i| {
        const row = rows[i];
        lift_ratio_max = @max(lift_ratio_max, row.ratioCL);
        bank_max = @max(bank_max, @abs(row.phi) * deg);
        load_max = @max(load_max, row.nz);
        speed_min = @min(speed_min, row.Va);
        lowest = @min(lowest, row.h);
        if (row.ratioCL > lift_limit) stall_time += steps[i];
        if (row.alim > 0.5) alpha_limit_time += steps[i];
    }
    const count = steady.items.len;
    const banks = try memory.alloc(f64, count);
    const loads = try memory.alloc(f64, count);
    const alphas = try memory.alloc(f64, count);
    const ratios = try memory.alloc(f64, count);
    const errors = try memory.alloc(f64, count);
    const distances = try memory.alloc(f64, count);
    var climb_sum: f64 = 0;
    var stall_loads: std.ArrayList(f64) = .empty;
    for (steady.items, 0..) |i, j| {
        const row = rows[i];
        banks[j] = @abs(row.phi);
        loads[j] = row.nz;
        alphas[j] = row.alpha;
        ratios[j] = row.ratioCL;
        errors[j] = @abs(row.ect);
        distances[j] = std.math.hypot(row.n - segment.cn, row.e - segment.ce);
        climb_sum += row.hdot;
        // n em que a asa estola na V do momento: n_z C_Lmax/C_L = n_z/ratioCL (Anderson, Introduction to Flight, §6.17)
        if (row.ratioCL > 0.05) try stall_loads.append(memory, row.nz / row.ratioCL);
    }
    turn.lift_ratio_max = lift_ratio_max;
    turn.bank_max_deg = bank_max;
    turn.bank_steady_deg = (try median(memory, banks)) * deg;
    turn.load_max = load_max;
    turn.load_steady = try median(memory, loads);
    turn.speed_min = speed_min;
    turn.alpha_steady_deg = (try median(memory, alphas)) * deg;
    turn.lift_ratio_steady = try median(memory, ratios);
    turn.height_loss = rows[inside.items[0]].h - lowest;
    turn.climb_steady = climb_sum / @as(f64, @floatFromInt(count));
    turn.track_error_p90 = try percentile(memory, errors, 90);
    turn.radius_flown = try median(memory, distances);
    turn.stall_time = stall_time;
    turn.alpha_limit_time = alpha_limit_time;
    turn.stall_load_steady = if (stall_loads.items.len > 0) try median(memory, stall_loads.items) else std.math.nan(f64);

    const tolerance = @max(criteria.radius_tolerance, criteria.radius_fraction * radius);
    const stalls = stall_time > criteria.stall_time;
    const follows = turn.track_error_p90 <= tolerance and @abs(turn.radius_flown - radius) <= tolerance;
    const holds_height = turn.height_loss <= criteria.height_loss and turn.climb_steady > -criteria.sink;
    const controlled = bank_max <= bank_limit_deg + criteria.bank_slack_deg and lowest > criteria.lowest_height and speed_min > criteria.speed_fraction * stall_speed;
    turn.ok = controlled and !stalls and follows and holds_height;
    turn.verdict = if (turn.ok) .ok else if (!controlled) .lost_control else if (stalls) .wing_stall else if (alpha_limit_time > 0.3) .alpha_limit else if (!follows) .off_radius else .loses_height;
    return turn;
}

/// o menor raio a partir do qual todos os maiores também passam (NaN se nenhum)
pub fn minRadius(memory: std.mem.Allocator, turns: []const Turn) !f64 {
    const sorted = try memory.dupe(Turn, turns);
    std.mem.sort(Turn, sorted, {}, struct {
        fn less(_: void, left: Turn, right: Turn) bool {
            return left.radius < right.radius;
        }
    }.less);
    for (sorted, 0..) |turn, i| {
        const all_pass = for (sorted[i..]) |other| {
            if (!other.ok) break false;
        } else true;
        if (all_pass) return turn.radius;
    }
    return std.math.nan(f64);
}

test "a mediana e o percentil como o numpy" {
    const memory = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(memory);
    defer arena.deinit();
    try std.testing.expectEqual(@as(f64, 2.5), try median(arena.allocator(), &.{ 4, 1, 3, 2 }));
    try std.testing.expectApproxEqAbs(@as(f64, 3.7), try percentile(arena.allocator(), &.{ 1, 2, 3, 4 }, 90), 1e-12);
    const steps = try gradient(arena.allocator(), &.{ 0, 1, 4, 9 });
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 4, 5 }, steps);
}

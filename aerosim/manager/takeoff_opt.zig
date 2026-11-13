//! Decolagem para a competição em Zig (o par de `takeoff_opt.py`): os dois critérios da pista e o de não estolar, e a
//! busca do ponto de acionamento do profundor.
//!
//! O x_warning é o comprimento de pista: o avião tem de "decolar" antes dele. O z_warning é a altura que conta como
//! decolado, sobre a superfície de partida (chão ou mesa); com z ≤ 0 (mesa) decolou ao sair da borda e não pode
//! afundar mais que |z| abaixo dela, e em qualquer caso, depois de sair do chão, não pode descer abaixo de min(z, 0).
//! Até o fim da decolagem nenhuma superfície pode chegar ao C_Lmax (o `ratio_to` do núcleo): sem isso a busca
//! preferia a rotação mais agressiva, que sai do chão cedo e estola logo depois.
//!
//! O comando é o profundor (ou o elevon): no ponto s da pista ele vai para a deflexão de cabrar. A busca procura o s
//! que deixa a maior folga x_warning − n_dec, começando pela deflexão máxima e só usando uma menor se nenhuma posição
//! funcionar com a máxima; se nada funcionar, segura o profundor picando na corrida (25 % e 50 % do curso). A grade
//! testa `Settings.grid_points` pontos na pista; se nenhum passa, divide ao meio o trecho entre um acionamento cedo
//! demais e o seguinte, tarde demais (a janela que funciona pode ser mais estreita que a grade), e procura pela seção
//! áurea o acionamento que decola mais cedo em volta do melhor ponto (o mínimo pode cair entre dois pontos da grade);
//! depois refina em volta do melhor pela seção áurea. Se ainda nada passa, a busca por coordenadas varia os três
//! comandos (acionamento, deflexão de cabrar e profundor na corrida), um de cada vez, pela seção áurea. A bisseção
//! parte de onde o avião sai do chão sem acionar e divide a faixa até achar a janela. Todos os ajustes (`Settings`) e o erro aceito nos dois requisitos vêm da tela.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const runner = @import("runner.zig");

const types = core.types;
const scalar = core.optim.scalar;
const params_mod = aircraft_model.params;
const Aircraft = aircraft_model.aircraft.Aircraft;
const rad = std.math.pi / 180.0;


/// os ajustes da busca, todos campos da tela: quantos pontos a grade testa, até onde a janela do acionamento é
/// dividida e quanto se aceita passar dos requisitos da pista
pub const Settings = struct {
    grid_points: usize = 8, // pontos de acionamento testados na pista, de 0 a 95 % do x_warning
    position_tolerance: f64 = 0.25, // a janela do acionamento é dividida até ficar menor que isto (m)
    x_error: f64 = 0, // quanto o ponto de decolagem pode passar do x_warning e ainda contar como passou (m)
    z_error: f64 = 0, // quanto pode faltar de altura (z_warning) e ainda contar como passou (m)
    // quando nada passa: voltas da busca por coordenadas, que varia o acionamento, a deflexão de cabrar e o profundor
    // na corrida, um de cada vez, pela seção áurea (0 = não varia)
    coordinate_rounds: usize = 2,
    angle_tolerance: f64 = 0.25, // a seção áurea nos ângulos para quando a faixa fica menor que isto (graus)
    // as deflexões de cabrar testadas, em frações da deflexão máxima, da maior para a menor
    levels: [max_levels]f64 = .{ 1.0, 0.75, 0.5, 0.3, 0.15 } ++ .{0} ** (max_levels - 5),
    level_count: usize = 5,
    // o profundor picando na corrida, em frações da deflexão máxima (além do profundor do avião)
    holds: [max_holds]f64 = .{ 0.25, 0.5 } ++ .{0} ** (max_holds - 2),
    hold_count: usize = 2,
    grid_reach: f64 = 0.95, // a grade de acionamento vai de 0 até esta fração do x_warning
    refine_steps: usize = 5, // passos da seção áurea que refina o acionamento em volta do melhor
    stall_ratio: f64 = 1.0, // C_L/C_Lmax (a superfície mais carregada) que reprova a decolagem

    pub const max_levels = 12;
    pub const max_holds = 6;

    /// o profundor na corrida de cada tentativa: o do avião (null) e depois cada fração picando
    fn holdList(settings: *const Settings, deflection_max: f64, buffer: *[max_holds + 1]?f64) []const ?f64 {
        buffer[0] = null;
        for (settings.holds[0..settings.hold_count], 1..) |fraction, k| buffer[k] = fraction * deflection_max;
        return buffer[0 .. settings.hold_count + 1];
    }

    pub const max_grid_points = 64;
};

/// a busca do ponto de acionamento
pub const Search = enum {
    grid,
    bisection,

    /// o nome na tela
    pub fn label(search: Search) []const u8 {
        return switch (search) {
            .grid => "grade",
            .bisection => "bisseção",
        };
    }

    /// a busca pelo nome da tela (grade se o nome não é conhecido)
    pub fn named(name: []const u8) Search {
        return if (std.mem.eql(u8, name, "bisseção")) .bisection else .grid;
    }
};

/// as buscas, pelo nome da tela
pub const search_labels = [_][]const u8{ Search.grid.label(), Search.bisection.label() };

/// como acabou uma decolagem
pub const Status = enum {
    completed,
    stopped,
    timeout,
    crashed,
    stalled, // chegou ao C_Lmax antes do fim da decolagem
    fell, // caiu (ou afundou demais) nos 4 s depois de decolar

    /// o nome como o Python escreve
    pub fn text(status: Status) []const u8 {
        return switch (status) {
            .completed => "COMPLETED",
            .stopped => "STOPPED",
            .timeout => "TIMEOUT",
            .crashed => "CRASHED",
            .stalled => "ESTOLOU NA DECOLAGEM",
            .fell => "CAIU DEPOIS DE DECOLAR",
        };
    }

    fn of(status: core.runner.Status) Status {
        return switch (status) {
            .completed => .completed,
            .stopped => .stopped,
            .timeout => .timeout,
            else => .crashed,
        };
    }
};

/// uma decolagem avaliada
pub const Result = struct {
    position: f64, // o ponto de acionamento (m); NaN sem comando de arfagem
    deflection: f64, // a deflexão usada (graus, − cabra)
    hold: f64 = std.math.nan(f64), // o profundor na corrida até o acionamento (graus, + pica); NaN: o do avião
    takeoff_point: f64, // n_dec: onde "decolou" pelo critério (m); inf se não
    lowest: f64, // a menor altura sobre a superfície de partida depois de sair do chão (m)
    x_excess: f64, // quanto passou do x_warning (0 dentro)
    z_short: f64, // quanto faltou de altura (0 se ok)
    ok: bool,
    status: Status,
    events: types.Events,
    margin: f64, // x_warning − n_dec quando passa; −inf quando não

    /// acionou cedo demais: saiu do chão e afundou abaixo do permitido (além do erro aceito `z_error`), estolou ou
    /// caiu depois de sair
    fn early(result: Result, z_error: f64) bool {
        return result.z_short > z_error or result.status != .completed;
    }

    /// a ordem do "menos ruim" quando ninguém passa
    fn badness(result: Result) f64 {
        return result.x_excess + 10 * result.z_short;
    }
};

/// o comando de arfagem do avião ("profundor", "elevon"...), ou null sem nenhum
pub fn pitchControl(aircraft: *const Aircraft) ?[]const u8 {
    const kinds = [_]struct { []const u8, []const u8 }{
        .{ "elevator", "profundor" },
        .{ "elevon", "elevon" },
        .{ "ruddervator", "leme-profundor (cauda em V)" },
    };
    // o profundor primeiro; sem ele, o elevon ou o leme-profundor (`features.pitch`)
    for ([_][]const []const u8{ &.{"elevator"}, &.{ "elevon", "ruddervator" } }) |wanted| {
        for (aircraft.surfaces) |surface| {
            if (!surface.enabled or surface.sections.len < 2) continue;
            for (surface.controls) |control| for (wanted) |role| if (std.mem.eql(u8, control.role(), role)) {
                for (kinds) |kind| if (std.mem.eql(u8, kind[0], role)) return kind[1];
            };
        }
    }
    return null;
}

/// o que os critérios dão para o registro de uma decolagem
const Judgement = struct { takeoff_point: f64, lowest: f64, x_excess: f64, z_short: f64, ok: bool };

/// os critérios da pista a partir do registro (`judge` do Python)
pub fn judge(rows: []const types.LogRow, events: types.Events, x_warning: f64, z_warning: f64) Judgement {
    if (rows.len == 0) return .{ .takeoff_point = std.math.inf(f64), .lowest = 0, .x_excess = std.math.inf(f64), .z_short = @abs(z_warning), .ok = false };
    const rest = rows[0].h; // a superfície de partida (repouso = 0)
    const left = events.tLO > 0;
    var lowest = std.math.inf(f64);
    var highest = -std.math.inf(f64);
    var any_air = false;
    var first_up: ?f64 = null;
    for (rows) |row| {
        const height = row.h - rest;
        highest = @max(highest, height);
        if (left and row.t >= events.tLO) {
            any_air = true;
            lowest = @min(lowest, height);
        }
        if (first_up == null and height >= z_warning) first_up = row.n;
    }
    if (!any_air) lowest = 0;
    const floor = @min(z_warning, 0);
    const takeoff_point = if (z_warning > 0) first_up orelse std.math.inf(f64) else if (left) events.nLO else std.math.inf(f64);
    var z_short = if (any_air) @max(0, floor - lowest) else 0;
    if (z_warning > 0 and !std.math.isFinite(takeoff_point)) z_short = @max(z_short, z_warning - highest);
    const x_excess = @max(0, takeoff_point - x_warning);
    return .{ .takeoff_point = takeoff_point, .lowest = lowest, .x_excess = x_excess, .z_short = z_short, .ok = std.math.isFinite(takeoff_point) and x_excess == 0 and z_short == 0 };
}

/// as decolagens de um avião numa pista: uma instância do núcleo configurada uma vez (a pista da decolagem e o piloto
/// calibrado), em que entre uma decolagem e outra só muda o comando de decolagem, que o configure não lê
pub const Takeoffs = struct {
    memory: std.mem.Allocator,
    instance: *core.runner.Instance,
    takeoff: types.Takeoff, // o comando do avião (o que cada decolagem muda em cima dele)
    x_warning: f64,
    z_warning: f64,
    deflection_max: f64,
    control: ?[]const u8,
    settings: Settings = .{},
    log: std.ArrayList(types.LogRow) = .empty,
    crew: []Takeoffs = &.{}, // as cópias que voam as decolagens de uma grade em paralelo, uma por núcleo a mais

    /// configura a pista da decolagem para o avião, com o piloto já calibrado (`autopilot`); `dtlog` é o passo do
    /// registro (0,01 s na busca)
    pub fn init(memory: std.mem.Allocator, aircraft: *const Aircraft, autopilot: types.Autopilot, x_warning: f64, z_warning: f64, dtlog: f64, diagnosis: *aircraft_model.aircraft.Diag) !Takeoffs {
        var variant = aircraft.*;
        const end_height = @max(aircraft.takeoff.h_end, z_warning + 1);
        variant.takeoff.h_end = end_height;
        variant.sim.tmax = 60;
        variant.sim.dtlog = dtlog;
        // a pista: a corrida e um cruzeiro reto (`takeoff_runway`)
        const height = @max(15.0, end_height + 5);
        const speed = aircraft.mission.V0;
        const legs = try memory.dupe(aircraft_model.aircraft.Leg, &.{
            .{ .kind = "straight", .length = 300, .h = height, .V = speed, .name = "decolagem", .takeoff = true },
            .{ .kind = "straight", .length = 2000, .h = height, .V = speed, .name = "cruzeiro" },
        });
        variant.mission = .{ .name = "pista", .legs = legs, .h0 = height, .V0 = speed };
        const instance = try memory.create(core.runner.Instance);
        instance.* = .{};
        try params_mod.fill(&variant, &instance.p, diagnosis);
        instance.p.ap = autopilot;
        try core.runner.configure(instance);
        return .{
            .memory = memory,
            .instance = instance,
            .takeoff = instance.p.takeoff,
            .x_warning = x_warning,
            .z_warning = z_warning,
            .deflection_max = aircraft.autopilot.de_max,
            .control = pitchControl(aircraft),
        };
    }

    /// uma decolagem com acionamento em `position` (null: sem comando), a deflexão `deflection` (graus) e, se dado, o
    /// profundor `hold` (graus) na corrida; o registro fica em `takeoffs.log`
    pub fn evaluate(takeoffs: *Takeoffs, position: ?f64, deflection: f64, hold: ?f64) !Result {
        const instance = takeoffs.instance;
        instance.p.takeoff = takeoffs.takeoff;
        instance.p.takeoff.sR = if (position) |at| @max(at, 1e-6) else 1e9;
        instance.p.takeoff.VR = 1e9;
        instance.p.takeoff.de1 = deflection * rad;
        if (hold) |degrees| if (std.math.isFinite(degrees)) {
            instance.p.takeoff.de0 = degrees * rad;
        };
        try core.runner.resetGround(instance);
        takeoffs.log.clearRetainingCapacity();
        // a corrida até decolar e mais 4 s de voo
        const run = try runner.fly(instance, .{ .takeoff = true }, takeoffs.memory, &takeoffs.log);
        var status = Status.of(run.status);
        if (status == .completed) {
            const rest = if (takeoffs.log.items.len > 0) takeoffs.log.items[0].h else 0;
            const start = takeoffs.log.items.len;
            const after = try runner.fly(instance, .{ .time = instance.r.t + 4 }, takeoffs.memory, &takeoffs.log);
            var lowest = std.math.inf(f64);
            for (takeoffs.log.items[start..]) |row| lowest = @min(lowest, row.h);
            const later = takeoffs.log.items.len > start;
            takeoffs.log.items.len = start; // os critérios olham só a corrida
            if (after.status == .crashed or (later and lowest - rest < @max(takeoffs.z_warning, 0))) status = .fell;
        }
        const verdict = judge(takeoffs.log.items, run.events, takeoffs.x_warning, takeoffs.z_warning);
        if (status == .completed and run.events.ratio_to >= takeoffs.settings.stall_ratio) status = .stalled;
        // passa com o erro aceito nos dois requisitos (os dois zero: o critério exato)
        const settings = takeoffs.settings;
        const ok = std.math.isFinite(verdict.takeoff_point) and verdict.x_excess <= settings.x_error and verdict.z_short <= settings.z_error and status == .completed;
        return .{
            .position = position orelse std.math.nan(f64),
            .deflection = deflection,
            .hold = hold orelse std.math.nan(f64),
            .takeoff_point = verdict.takeoff_point,
            .lowest = verdict.lowest,
            .x_excess = verdict.x_excess,
            .z_short = verdict.z_short,
            .ok = ok,
            .status = status,
            .events = run.events,
            .margin = if (ok) takeoffs.x_warning - verdict.takeoff_point else -std.math.inf(f64),
        };
    }
};

/// sem threads neste alvo (a web): a grade voa em série
const no_threads = builtin.single_threaded or builtin.target.cpu.arch.isWasm();

/// voa as decolagens de `positions` (a mesma deflexão e o mesmo `hold`) e põe cada uma em `results`, na ordem. Cada
/// núcleo voa uma cópia da instância, então o resultado é o mesmo da série, bit a bit, com qualquer número de núcleos
fn evaluateMany(takeoffs: *Takeoffs, positions: []const f64, deflection: f64, hold: ?f64, results: []Result) !void {
    const cores = if (no_threads) 1 else std.Thread.getCpuCount() catch 1;
    const workers = @min(cores, positions.len);
    if (no_threads or workers <= 1) {
        for (positions, results) |position, *result| result.* = try takeoffs.evaluate(position, deflection, hold);
        return;
    }
    if (comptime no_threads) unreachable; // o resto (as threads) nem compila onde não há threads
    if (takeoffs.crew.len < workers - 1) {
        takeoffs.crew = try takeoffs.memory.alloc(Takeoffs, workers - 1);
        for (takeoffs.crew) |*member| {
            member.* = takeoffs.*;
            member.crew = &.{};
            member.log = .empty;
            member.instance = try takeoffs.memory.create(core.runner.Instance);
        }
    }
    const Shift = struct {
        takeoffs: *Takeoffs,
        first: usize,
        stride: usize,
        failure: ?anyerror = null,
        fn fly(shift: *@This(), all: []const f64, flown_deflection: f64, flown_hold: ?f64, out: []Result) void {
            var index = shift.first;
            while (index < all.len) : (index += shift.stride) {
                out[index] = shift.takeoffs.evaluate(all[index], flown_deflection, flown_hold) catch |err| {
                    shift.failure = err;
                    return;
                };
            }
        }
    };
    var shifts: [64]Shift = undefined;
    var threads: [64]?std.Thread = [_]?std.Thread{null} ** 64;
    const count = @min(workers, shifts.len);
    for (0..count) |k| {
        const member = if (k == 0) takeoffs else &takeoffs.crew[k - 1];
        if (k > 0) {
            // a cópia da instância de agora (o configure e a carga que quem chamou já aplicou)
            member.instance.* = takeoffs.instance.*;
            member.takeoff = takeoffs.takeoff;
        }
        shifts[k] = .{ .takeoffs = member, .first = k, .stride = count };
    }
    for (1..count) |k| threads[k] = std.Thread.spawn(.{}, Shift.fly, .{ &shifts[k], positions, deflection, hold, results }) catch null;
    shifts[0].fly(positions, deflection, hold, results);
    for (1..count) |k| {
        if (threads[k]) |thread| thread.join() else shifts[k].fly(positions, deflection, hold, results); // sem thread: voa aqui
    }
    for (shifts[0..count]) |shift| if (shift.failure) |err| return @as(EvaluateError, @errorCast(err));
}

const EvaluateError = @typeInfo(@typeInfo(@TypeOf(Takeoffs.evaluate)).@"fn".return_type.?).error_union.error_set;

/// o melhor acionamento e todas as decolagens testadas
pub const Outcome = struct {
    best: Result,
    tried: []Result,
};

/// o melhor ponto de acionamento (e a maior deflexão que funciona); `tolerance` (fração do x_warning, só na bisseção;
/// 0 = a busca de sempre) aceita errar um pouco para voar menos
pub fn optimize(takeoffs: *Takeoffs, search: Search, tolerance: f64) !Outcome {
    return searchWith(takeoffs, search, tolerance, true);
}

/// só se decola: a grade para no primeiro acionamento que passa, sem refinar o ponto (a busca do MTOW usa isto em
/// cada massa e refina só na massa achada)
pub fn feasible(takeoffs: *Takeoffs, search: Search, tolerance: f64) !Outcome {
    return searchWith(takeoffs, search, tolerance, false);
}

fn searchWith(takeoffs: *Takeoffs, search: Search, tolerance: f64, refine: bool) !Outcome {
    var tried: std.ArrayList(Result) = .empty;
    const memory = takeoffs.memory;
    if (takeoffs.control == null) {
        try tried.append(memory, try takeoffs.evaluate(null, 0, null));
        return .{ .best = tried.items[0], .tried = tried.items };
    }
    const best = switch (search) {
        .grid => try gridSearch(takeoffs, &tried, refine),
        .bisection => try bisect(takeoffs, &tried, tolerance),
    };
    return .{ .best = best orelse leastBad(tried.items), .tried = tried.items };
}

fn leastBad(tried: []const Result) Result {
    var chosen = tried[0];
    for (tried[1..]) |candidate| {
        if (candidate.badness() < chosen.badness() or (candidate.badness() == chosen.badness() and candidate.takeoff_point < chosen.takeoff_point)) chosen = candidate;
    }
    return chosen;
}


fn gridSearch(takeoffs: *Takeoffs, tried: *std.ArrayList(Result), refine: bool) !?Result {
    const memory = takeoffs.memory;
    const deflection_max = takeoffs.deflection_max;
    const settings = takeoffs.settings;
    const count = std.math.clamp(settings.grid_points, 3, Settings.max_grid_points);
    var grid_buffer: [Settings.max_grid_points]f64 = undefined;
    const grid = grid_buffer[0..count];
    const last = @max(takeoffs.x_warning, 5) * takeoffs.settings.grid_reach;
    for (grid, 0..) |*position, k| position.* = last * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count - 1));
    var found: ?Result = null;
    // profundor na corrida: o do avião; depois picando. Da deflexão máxima para baixo: para na primeira que passa
    var hold_buffer: [Settings.max_holds + 1]?f64 = undefined;
    holds: for (takeoffs.settings.holdList(deflection_max, &hold_buffer)) |hold| {
        for (takeoffs.settings.levels[0..takeoffs.settings.level_count]) |level| {
            var best_here: ?Result = null;
            var flown_buffer: [Settings.max_grid_points]Result = undefined;
            const flown = flown_buffer[0..count];
            try evaluateMany(takeoffs, grid, -level * deflection_max, hold, flown);
            for (flown) |result| {
                try tried.append(memory, result);
                if (result.ok and (best_here == null or result.margin > best_here.?.margin)) best_here = result;
            }
            // nenhum ponto passou: a janela que funciona pode ser mais estreita que o espaço da grade. Entre um ponto
            // que acionou cedo demais e o seguinte, que acionou tarde demais, a janela é dividida ao meio até achar
            // um acionamento que passa ou até ficar menor que a tolerância
            if (best_here == null) {
                for (flown[0 .. count - 1], flown[1..count]) |before, after| {
                    if (!before.early(settings.z_error) or after.early(settings.z_error)) continue;
                    if (try windowBetween(takeoffs, tried, before.position, after.position, -level * deflection_max, hold)) |good| {
                        best_here = good;
                        break;
                    }
                }
            }
            // ainda nada: o ponto de decolagem em função do acionamento tem um mínimo (cedo demais o avião corre
            // cabrado, com mais arrasto; tarde demais roda tarde), e o mínimo pode cair entre dois pontos da grade.
            // A seção áurea (busca do mínimo que reaproveita pontos) procura esse mínimo em volta do melhor ponto
            if (best_here == null) {
                if (closest(flown)) |center| best_here = try earliestNear(takeoffs, tried, center.position, grid[1] - grid[0], -level * deflection_max, hold);
            }
            if (best_here) |good| {
                found = good;
                break :holds;
            }
        }
    }
    // nada passou com as deflexões e os profundores fixos da lista: a busca por coordenadas varia os três comandos
    // (acionamento, deflexão de cabrar, profundor na corrida) a partir da decolagem mais cedo que não afundou
    if (found == null and settings.coordinate_rounds > 0) {
        if (closest(tried.items)) |seed| found = try coordinateSearch(takeoffs, tried, seed, grid[1] - grid[0]);
    }
    const start = found orelse return null;
    if (!refine) return start;
    // refina s (seção áurea) em volta do melhor, na mesma deflexão
    const spacing = grid[1] - grid[0];
    var search = scalar.GoldenSection.init(@max(0, start.position - spacing), start.position + spacing);
    const hold: ?f64 = if (std.math.isFinite(start.hold)) start.hold else null;
    var left = try takeoffs.evaluate(search.left, start.deflection, hold);
    var right = try takeoffs.evaluate(search.right, start.deflection, hold);
    try tried.append(memory, left);
    try tried.append(memory, right);
    for (0..takeoffs.settings.refine_steps) |_| {
        const left_better = left.margin >= right.margin;
        const point = search.shrink(left_better);
        if (left_better) {
            right = left;
            left = try takeoffs.evaluate(point, start.deflection, hold);
            try tried.append(memory, left);
        } else {
            left = right;
            right = try takeoffs.evaluate(point, start.deflection, hold);
            try tried.append(memory, right);
        }
    }
    var best = start;
    for ([_]Result{ left, right }) |candidate| if (candidate.margin > best.margin) {
        best = candidate;
    };
    return best;
}

/// o acionamento que decolou mais cedo sem afundar, estolar nem cair (a dica da seção áurea); null se nenhum
fn closest(flown: []const Result) ?Result {
    var chosen: ?Result = null;
    for (flown) |result| {
        if (result.status != .completed or result.z_short > 0 or !std.math.isFinite(result.takeoff_point)) continue;
        if (chosen == null or result.takeoff_point < chosen.?.takeoff_point) chosen = result;
    }
    return chosen;
}

/// a seção áurea em [center − spacing, center + spacing]: o acionamento com o ponto de decolagem mais cedo (os que
/// afundam, estolam ou caem contam como os piores), até a faixa ficar menor que a tolerância de posição. Devolve o
/// primeiro que passa, ou null
fn earliestNear(takeoffs: *Takeoffs, tried: *std.ArrayList(Result), center: f64, spacing: f64, deflection: f64, hold: ?f64) !?Result {
    const settings = takeoffs.settings;
    const score = earliness;
    var search = scalar.GoldenSection.init(@max(0, center - spacing), center + spacing);
    var left = try takeoffs.evaluate(search.left, deflection, hold);
    var right = try takeoffs.evaluate(search.right, deflection, hold);
    try tried.append(takeoffs.memory, left);
    try tried.append(takeoffs.memory, right);
    while (true) {
        if (left.ok) return left;
        if (right.ok) return right;
        if (search.high - search.low <= settings.position_tolerance) return null;
        const left_better = score(left, settings.z_error) >= score(right, settings.z_error);
        const point = search.shrink(left_better);
        if (left_better) {
            right = left;
            left = try takeoffs.evaluate(point, deflection, hold);
            try tried.append(takeoffs.memory, left);
        } else {
            left = right;
            right = try takeoffs.evaluate(point, deflection, hold);
            try tried.append(takeoffs.memory, right);
        }
    }
}

/// os três comandos da decolagem que a busca por coordenadas varia
const Command = struct {
    position: f64, // o ponto de acionamento (m)
    deflection: f64, // a deflexão de cabrar (graus, − cabra)
    hold: f64, // o profundor na corrida (graus, + pica)

    const Axis = enum { position, deflection, hold };

    fn with(command: Command, axis: Axis, value: f64) Command {
        var changed = command;
        switch (axis) {
            .position => changed.position = value,
            .deflection => changed.deflection = value,
            .hold => changed.hold = value,
        }
        return changed;
    }

    fn of(result: Result) Command {
        return .{ .position = result.position, .deflection = result.deflection, .hold = result.hold };
    }
};

/// a nota da seção áurea: decolar mais cedo é melhor; afundar, estolar ou cair é o pior
fn earliness(result: Result, z_error: f64) f64 {
    if (result.status != .completed or result.z_short > z_error or !std.math.isFinite(result.takeoff_point)) return -std.math.inf(f64);
    return -result.takeoff_point;
}

/// a busca por coordenadas (varia um comando de cada vez, com os outros parados): em cada volta, a seção áurea no
/// acionamento (± `spacing` em volta do de agora), na deflexão de cabrar (0 ao máximo) e no profundor na corrida
/// (0 a metade do máximo, picando). Devolve a primeira decolagem que passa, ou null depois de `coordinate_rounds`
fn coordinateSearch(takeoffs: *Takeoffs, tried: *std.ArrayList(Result), seed: Result, spacing: f64) !?Result {
    const settings = takeoffs.settings;
    const deflection_max = takeoffs.deflection_max;
    var current: Command = .{
        .position = seed.position,
        .deflection = seed.deflection,
        .hold = if (std.math.isFinite(seed.hold)) seed.hold else takeoffs.takeoff.de0 / rad,
    };
    var best_score = earliness(seed, settings.z_error);
    for (0..settings.coordinate_rounds) |_| {
        for ([_]Command.Axis{ .position, .deflection, .hold }) |axis| {
            const low: f64, const high: f64, const tolerance: f64 = switch (axis) {
                .position => .{ @max(0, current.position - spacing), current.position + spacing, settings.position_tolerance },
                .deflection => .{ -deflection_max, 0, settings.angle_tolerance },
                .hold => .{ 0, 0.5 * deflection_max, settings.angle_tolerance },
            };
            var search = scalar.GoldenSection.init(low, high);
            var left = try flyCommand(takeoffs, tried, current.with(axis, search.left));
            var right = try flyCommand(takeoffs, tried, current.with(axis, search.right));
            while (true) {
                if (left.ok) return left;
                if (right.ok) return right;
                if (search.high - search.low <= tolerance) break;
                const left_better = earliness(left, settings.z_error) >= earliness(right, settings.z_error);
                const point = search.shrink(left_better);
                if (left_better) {
                    right = left;
                    left = try flyCommand(takeoffs, tried, current.with(axis, point));
                } else {
                    left = right;
                    right = try flyCommand(takeoffs, tried, current.with(axis, point));
                }
            }
            // fica o melhor dos dois últimos, se ele decola mais cedo que o de agora
            const better = if (earliness(left, settings.z_error) >= earliness(right, settings.z_error)) left else right;
            const score = earliness(better, settings.z_error);
            if (score > best_score) {
                best_score = score;
                current = Command.of(better);
            }
        }
    }
    return null;
}

/// voa uma decolagem com os três comandos e a guarda na lista das testadas
fn flyCommand(takeoffs: *Takeoffs, tried: *std.ArrayList(Result), command: Command) !Result {
    const result = try takeoffs.evaluate(command.position, command.deflection, command.hold);
    try tried.append(takeoffs.memory, result);
    return result;
}

/// a janela do acionamento entre `early_at` (cedo demais) e `late_at` (tarde demais), dividida ao meio até a
/// tolerância de posição; o primeiro acionamento que passa, ou null se a janela não existe
fn windowBetween(takeoffs: *Takeoffs, tried: *std.ArrayList(Result), early_at: f64, late_at: f64, deflection: f64, hold: ?f64) !?Result {
    const settings = takeoffs.settings;
    var window: scalar.Bisection = .{ .low = early_at, .high = late_at };
    while (window.width() > settings.position_tolerance) {
        const result = try takeoffs.evaluate(window.middle(), deflection, hold);
        try tried.append(takeoffs.memory, result);
        if (result.ok) return result;
        window.move(result.position, if (result.early(settings.z_error)) .raise else .lower);
    }
    return null;
}

fn bisect(takeoffs: *Takeoffs, tried: *std.ArrayList(Result), tolerance: f64) !?Result {
    const memory = takeoffs.memory;
    const deflection_max = takeoffs.deflection_max;
    const x_warning = takeoffs.x_warning;
    var hold_buffer: [Settings.max_holds + 1]?f64 = undefined;
    for (takeoffs.settings.holdList(deflection_max, &hold_buffer)) |hold| {
        // a corrida sem acionar: acionar depois de onde o avião sai do chão sozinho não adianta
        const free = try takeoffs.evaluate(null, 0, hold);
        try tried.append(memory, free);
        const lift_off = if (free.events.tLO > 0) free.events.nLO else std.math.inf(f64);
        const top = if (std.math.isFinite(lift_off)) @min(lift_off, x_warning) else x_warning;
        var early = false;
        for (takeoffs.settings.levels[0..takeoffs.settings.level_count]) |level| {
            var bisection: scalar.Bisection = .{ .low = 0, .high = top };
            var good: ?Result = null;
            early = false;
            while (bisection.width() > @max(takeoffs.settings.position_tolerance, tolerance * x_warning)) {
                const result = try takeoffs.evaluate(bisection.middle(), -level * deflection_max, hold);
                try tried.append(memory, result);
                if (result.ok) {
                    if (good == null or result.margin > good.?.margin) good = result;
                    bisection.move(result.position, .lower); // passa: tenta antes, para ganhar folga
                } else if (result.early(takeoffs.settings.z_error)) {
                    bisection.move(result.position, .raise);
                    early = true;
                } else bisection.move(result.position, .lower);
            }
            if (good) |found| return found;
            if (tolerance > 0 and !early) break; // nem todo cabrando sai do chão a tempo: o resto só atrasa
        }
        if (tolerance > 0 and !early) break;
    }
    return null;
}

const testing = std.testing;

test "decolagem: a avaliação e as duas buscas batem com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const memory = arena.allocator();
    const calibrated = try memory.create(core.runner.Instance);
    calibrated.* = .{};
    _ = try params_mod.setup(&loaded.ac, calibrated, &diagnosis);
    var takeoffs = try Takeoffs.init(memory, &loaded.ac, calibrated.p.ap, 60, 1, 0.01, &diagnosis);
    try testing.expectEqualStrings("profundor", takeoffs.control.?);
    // os números do Python (`takeoff_opt.evaluate`, Convencional_original, x_warning 60 m, z_warning 1 m)
    const pulled = try takeoffs.evaluate(10, -20, null);
    try testing.expectApproxEqAbs(@as(f64, 61.306718343799844), pulled.takeoff_point, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.021769336353349905), pulled.lowest, 1e-9);
    try testing.expect(!pulled.ok and pulled.status == .completed);
    try testing.expectApproxEqAbs(@as(f64, 42.75867475264957), pulled.events.nLO, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.8998902241990436), pulled.events.ratio_to, 1e-9);
    const free = try takeoffs.evaluate(null, 0, null);
    try testing.expectApproxEqAbs(@as(f64, 93.5311820182738), free.takeoff_point, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 72.45684329289597), free.events.nLO, 1e-6);

    const grid = try optimize(&takeoffs, .grid, 0);
    try testing.expectEqual(@as(usize, 15), grid.tried.len);
    try testing.expectApproxEqAbs(@as(f64, 33.58612463677029), grid.best.position, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 54.22954161785073), grid.best.takeoff_point, 1e-6);
    const halves = try optimize(&takeoffs, .bisection, 0);
    try testing.expectEqual(@as(usize, 9), halves.tried.len);
    try testing.expectApproxEqAbs(@as(f64, 30.0), halves.best.position, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 55.70498728742467), halves.best.takeoff_point, 1e-6);
}

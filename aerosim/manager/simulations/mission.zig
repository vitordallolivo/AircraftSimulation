//! Missão em Zig (o par de `mission.py`): o voo simulado (6GDL) por etapa, a corrida no chão, cada perna do percurso
//! e a rolagem. São quatro modos. "missão": a decolagem otimizada para a pista (x_warning e z_warning) e depois o
//! resto, etapa por etapa; uma curva sem raio procura o menor que o avião faz, e cada etapa salva um checkpoint no
//! começo dela, para parar no fim de qualquer etapa, mudar o percurso dali para frente e continuar. "só decolagem":
//! o acionamento do profundor otimizado e a decolagem de perto. "curvas: raio mínimo": para cada V, o menor raio em
//! curva nivelada. "MTOW": a bisseção na massa, a maior que decola com x_warning e z_warning, otimizando o
//! acionamento (e testando o xCG da tabela) em cada massa; o MTOW achado fica guardado para os outros modos.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const runner = @import("../runner.zig");
const takeoff_opt = @import("../takeoff_opt.zig");
const analysis = @import("../analysis.zig");
const flightplots = @import("../flightplots.zig");

const types = core.types;
const params_mod = aircraft_model.params;
const model = aircraft_model.aircraft;
const Aircraft = model.Aircraft;
const Leg = model.Leg;
const deg = 180.0 / std.math.pi;
const rad = std.math.pi / 180.0;
const g0 = 9.80665;

/// a análise, com a interface de `simulation.check`
pub const Mission = struct {
    pub const name: []const u8 = "mission";
    pub const title: [:0]const u8 = "Missão";
    pub const area: []const u8 = "Desempenho";
    pub const description: []const u8 = "Voo simulado (6GDL) por etapa. A decolagem é otimizada para a pista (x_warning: " ++
        "comprimento, z_warning: altura que conta como decolado) e o resto do voo continua dali, etapa por etapa.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const edit = editGrid;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
};

/// o que a aba faz
const Mode = enum {
    mission,
    takeoff,
    turns,
    mtow,
    study,

    fn label(mode: Mode) []const u8 {
        return switch (mode) {
            .mission => "missão",
            .takeoff => "só decolagem",
            .turns => "curvas: raio mínimo",
            .mtow => "MTOW (x_warning e z_warning)",
            .study => "estudo e ponto de projeto: MTOW × uma variável",
        };
    }

    fn named(text: []const u8) Mode {
        for (std.enums.values(Mode)) |mode| if (std.mem.eql(u8, mode.label(), text)) return mode;
        return .mission;
    }
};
const mode_labels = [_][]const u8{ Mode.mission.label(), Mode.takeoff.label(), Mode.turns.label(), Mode.mtow.label(), Mode.study.label() };

/// o que o estudo varia no avião, um valor por vez, achando o MTOW da pista em cada um
const StudyVariable = enum {
    tilt,
    incidence,

    fn label(variable: StudyVariable) []const u8 {
        return switch (variable) {
            .tilt => "inclinação dos motores (°)",
            .incidence => "incidência da asa (°)",
        };
    }

    fn named(text: []const u8) StudyVariable {
        for (std.enums.values(StudyVariable)) |variable| if (std.mem.eql(u8, variable.label(), text)) return variable;
        return .tilt;
    }

    /// o valor de agora no avião (o do primeiro motor, o da primeira asa)
    fn current(variable: StudyVariable, aircraft: *const Aircraft) f64 {
        return switch (variable) {
            .tilt => if (aircraft.propulsion.len > 0) aircraft.propulsion[0].tilt else 0,
            .incidence => if (params_mod.firstSurface(aircraft, "wing")) |wing| wing.incidence else 0,
        };
    }

    /// o avião com este valor (todos os motores; as asas principais)
    fn applied(variable: StudyVariable, memory: std.mem.Allocator, aircraft: Aircraft, value: f64) !Aircraft {
        var out = aircraft;
        switch (variable) {
            .tilt => {
                const units = try memory.dupe(model.Propulsion, aircraft.propulsion);
                for (units) |*unit| unit.tilt = value;
                out.propulsion = units;
            },
            .incidence => {
                const surfaces = try memory.dupe(model.Surface, aircraft.surfaces);
                for (surfaces) |*surface| if (std.mem.eql(u8, surface.role, "wing")) {
                    surface.incidence = value;
                };
                out.surfaces = surfaces;
            },
        }
        return out;
    }
};
const study_labels = [_][]const u8{ StudyVariable.tilt.label(), StudyVariable.incidence.label() };
const group_study = "Estudo";

/// com que massa o voo sai
const MassSource = enum { plane, saved, hand };
const mass_labels = [_][]const u8{ "a do avião", "MTOW salvo desta pista", "na mão" };
const trigger_labels = [_][]const u8{ "otimizado", "na mão" };
const end_label = "fim da missão (parada na pista)";
const leg_kinds = [_][]const u8{ "decolagem", "reta", "curva", "pouso" };
const group_mass = "Massa e acionamento";
const group_gust = "Rajada";
const group_runway = "Pista";
const glyph_step = 10.0; // o avião desenhado no 3D a cada 10 m
const auto_fractions = [_]f64{ 1.0, 0.85, 0.7, 0.55, 0.42, 0.32 }; // raio automático: frações do φ máx. do piloto
const turn_banks = [_]f64{ 70, 65, 55, 45, 37, 30, 24, 18, 14 }; // as inclinações testadas nas curvas

// ------------------------------------------------------------------ a tabela da trajetória (guardada na aba)

const name_size = 48;

/// as pernas da tabela: começam com as do arquivo e guardam o que se mudou até abrir outro avião
const LegTable = struct {
    legs: [core.limits.max_segments]Leg = undefined,
    gusts: [core.limits.max_segments]?f64 = undefined,
    names: [core.limits.max_segments][name_size]u8 = undefined,
    name_lengths: [core.limits.max_segments]usize = undefined,
    count: usize = 0,
    source: u64 = 0,
    ready: bool = false,

    fn slice(table: *LegTable) []const Leg {
        return table.legs[0..table.count];
    }

    fn reset(table: *LegTable, aircraft: *const Aircraft) void {
        table.count = @min(aircraft.mission.legs.len, table.legs.len);
        for (aircraft.mission.legs[0..table.count], 0..) |leg, i| {
            table.legs[i] = leg;
            table.legs[i].kind = if (std.mem.eql(u8, leg.kind, "turn")) "turn" else "straight";
            table.gusts[i] = null;
            table.rename(i, leg.name);
        }
        for (aircraft.mission.events) |event| {
            if (!std.mem.eql(u8, event.kind, "gust") or event.leg < 0 or event.leg >= table.count) continue;
            table.gusts[@intCast(event.leg)] = event.s;
        }
        table.source = fingerprint(aircraft);
        table.ready = true;
    }

    fn sync(table: *LegTable, aircraft: *const Aircraft) void {
        if (!table.ready or table.source != fingerprint(aircraft)) table.reset(aircraft);
    }

    fn rename(table: *LegTable, i: usize, text: []const u8) void {
        const length = @min(text.len, name_size);
        @memcpy(table.names[i][0..length], text[0..length]);
        table.name_lengths[i] = length;
        table.legs[i].name = table.names[i][0..length];
    }

    fn move(table: *LegTable, from: usize, to: usize) void {
        table.legs[to] = table.legs[from];
        table.gusts[to] = table.gusts[from];
        table.names[to] = table.names[from];
        table.name_lengths[to] = table.name_lengths[from];
        table.legs[to].name = table.names[to][0..table.name_lengths[to]];
    }

    fn add(table: *LegTable, after: ?usize) void {
        if (table.count >= table.legs.len) return;
        const at = if (after) |row| @min(row + 1, table.count) else table.count;
        var k = table.count;
        while (k > at) : (k -= 1) table.move(k - 1, k);
        table.legs[at] = if (at > 0) table.legs[at - 1] else .{};
        table.legs[at].takeoff = false;
        table.gusts[at] = null;
        table.count += 1;
        var buffer: [name_size]u8 = undefined;
        table.rename(at, std.fmt.bufPrint(&buffer, "etapa {d}", .{at}) catch "etapa");
    }

    fn delete(table: *LegTable, row: usize) void {
        if (row >= table.count) return;
        for (row + 1..table.count) |k| table.move(k, k - 1);
        table.count -= 1;
    }

    /// o tipo da perna como a tabela mostra
    fn kindOf(leg: Leg) []const u8 {
        if (std.mem.eql(u8, leg.kind, "turn")) return "curva";
        if (leg.takeoff) return "decolagem";
        if (leg.landing) return "pouso";
        return "reta";
    }

    /// muda uma célula (`rows_to_legs` do Python)
    fn set(table: *LegTable, row: usize, key: []const u8, change: simulation.GridEdit) void {
        if (row >= table.count) return;
        const leg = &table.legs[row];
        const column = std.meta.stringToEnum(enum { name, kind, length, turn, radius, h, V, gust }, key) orelse return;
        const number = change.number();
        switch (column) {
            .name => table.rename(row, change.text()),
            .kind => {
                const text = change.text();
                const was_turn = std.mem.eql(u8, leg.kind, "turn");
                const turn = std.mem.eql(u8, text, "curva");
                if (turn and !was_turn) leg.angle = 90;
                leg.kind = if (turn) "turn" else "straight";
                const landing = std.mem.eql(u8, text, "pouso");
                if (landing and !leg.landing) leg.clearance = 50;
                leg.takeoff = std.mem.eql(u8, text, "decolagem");
                leg.landing = landing;
            },
            .length => if (number) |value| {
                leg.length = value;
            },
            .turn => if (number) |value| {
                leg.angle = @abs(value);
                leg.side = if (value >= 0) 1 else -1;
            },
            .radius => leg.radius = number orelse 0,
            .h => leg.h = number,
            .V => leg.V = number,
            .gust => table.gusts[row] = number,
        }
    }
};

var leg_table: LegTable = .{};

/// o que identifica o avião aberto: o nome e o percurso do arquivo
fn fingerprint(aircraft: *const Aircraft) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(aircraft.name);
    for (aircraft.mission.legs) |leg| {
        hasher.update(leg.name);
        hasher.update(leg.kind);
        for ([_]f64{ leg.length, leg.radius, leg.angle, leg.side, leg.h orelse -1e9, leg.V orelse -1e9 }) |value| hasher.update(std.mem.asBytes(&value));
    }
    return hasher.final();
}

const leg_columns = [_]simulation.Column{
    .{ .key = "name", .label = "etapa", .kind = .text },
    .{ .key = "kind", .label = "tipo", .kind = .choice, .choices = &leg_kinds },
    .{ .key = "length", .label = "distância (m)", .help = "comprimento da reta (decolagem, reta, pouso)" },
    .{ .key = "turn", .label = "virar (°)", .help = "quanto a aeronave gira na curva: + direita, − esquerda. A próxima etapa segue na direção nova" },
    .{ .key = "radius", .label = "raio (m)", .help = "raio da curva; vazio = automático (procura o menor que a aeronave faz)" },
    .{ .key = "h", .label = "altura (m)", .help = "altura ao fim da etapa; vazio = mantém a anterior" },
    .{ .key = "V", .label = "velocidade (m/s)", .help = "velocidade ao fim da etapa; vazio = mantém a anterior" },
    .{ .key = "gust", .label = "rajada em (m)", .help = "distância dentro da etapa em que a rajada chega; vazio = sem rajada (o tamanho e a duração ficam no grupo Rajada)" },
};

fn optionalCell(value: ?f64) simulation.Cell {
    return if (value) |number| .{ .number = number } else .{ .text = "" };
}

fn legGrid(memory: std.mem.Allocator) !simulation.Grid {
    const rows = try memory.alloc([]const simulation.Cell, leg_table.count);
    for (leg_table.slice(), 0..) |leg, i| {
        const turn = std.mem.eql(u8, leg.kind, "turn");
        const cells = try memory.alloc(simulation.Cell, leg_columns.len);
        cells[0] = .{ .text = leg.name };
        cells[1] = .{ .text = LegTable.kindOf(leg) };
        cells[2] = if (turn) .{ .text = "" } else .{ .number = leg.length };
        cells[3] = if (turn) .{ .number = (if (leg.side != 0) leg.side else 1) * leg.angle } else .{ .text = "" };
        cells[4] = if (turn and leg.radius > 0) .{ .number = leg.radius } else .{ .text = "" };
        cells[5] = optionalCell(leg.h);
        cells[6] = optionalCell(leg.V);
        cells[7] = optionalCell(leg_table.gusts[i]);
        rows[i] = cells;
    }
    return .{
        .name = "legs",
        .title = "Trajetória",
        .help = "uma linha por etapa; passe o mouse no cabeçalho para ver cada coluna",
        .note = "As mudanças valem nesta aba; o arquivo do avião não muda.",
        .columns = &leg_columns,
        .rows = rows,
        .buttons = &.{
            .{ .operation = "add", .label = "+ etapa", .help = "copia a selecionada logo abaixo dela" },
            .{ .operation = "delete", .label = "− etapa", .help = "apaga a selecionada" },
            .{ .operation = "reset", .label = "como no avião", .help = "volta ao percurso do arquivo" },
        },
    };
}

// ------------------------------------------------------------------ a tabela das massas do MTOW

/// mínimo, nominal e máximo da massa total (kg) e do xCG (% da CMA)
const MassTable = struct {
    total: [3]f64 = .{ 0, 0, 0 },
    center: [3]f64 = .{ 25, 25, 25 },
    source: u64 = 0,
    ready: bool = false,

    fn reset(table: *MassTable, aircraft: *const Aircraft) void {
        table.source = fingerprint(aircraft);
        table.ready = true;
        const loaded = baseline(aircraft) orelse return;
        const mass = round(loaded.mass, 1e3);
        const percent = round(loaded.dry_center_percent, 1e2);
        table.total = .{ mass, mass, round(mass + 6, 1e3) };
        table.center = .{ round(percent - 5, 1e2), percent, round(percent + 5, 1e2) };
    }

    fn sync(table: *MassTable, aircraft: *const Aircraft) void {
        if (!table.ready or table.source != fingerprint(aircraft)) table.reset(aircraft);
    }
};

var mass_table: MassTable = .{};

fn round(value: f64, scale: f64) f64 {
    return @round(value * scale) / scale;
}

const mass_columns = [_]simulation.Column{
    .{ .key = "item", .label = "", .kind = .label },
    .{ .key = "min", .label = "mínimo" },
    .{ .key = "nom", .label = "nominal" },
    .{ .key = "max", .label = "máximo" },
};

fn massGrid(memory: std.mem.Allocator) !simulation.Grid {
    const rows = try memory.alloc([]const simulation.Cell, 2);
    for ([_]struct { []const u8, [3]f64 }{ .{ "Massa total (kg)", mass_table.total }, .{ "xCG (% CMA)", mass_table.center } }, 0..) |line, i| {
        const cells = try memory.alloc(simulation.Cell, 4);
        cells[0] = .{ .text = line[0] };
        for (0..3) |k| cells[k + 1] = .{ .number = line[1][k] };
        rows[i] = cells;
    }
    return .{
        .name = "masses",
        .title = "Massas",
        .help = "a massa total vai do mínimo ao máximo (o que passa da montada entra no CG); o xCG, em % da CMA a partir do bordo de ataque, é testado nos três valores",
        .columns = &mass_columns,
        .rows = rows,
        .buttons = &.{.{ .operation = "reset", .label = "como no avião", .help = "volta à massa e ao CG do avião" }},
    };
}

fn editGrid(aircraft: ?*const simulation.Aircraft, change: simulation.GridEdit) simulation.Error!void {
    const operation = std.meta.stringToEnum(enum { set, add, delete, reset }, change.operation) orelse return;
    if (std.mem.eql(u8, change.grid, "legs")) {
        if (aircraft) |plane| leg_table.sync(plane);
        switch (operation) {
            .add => leg_table.add(change.row),
            .delete => if (change.row) |row| leg_table.delete(row),
            .reset => if (aircraft) |plane| leg_table.reset(plane),
            .set => if (change.row) |row| leg_table.set(row, change.key, change),
        }
    } else if (std.mem.eql(u8, change.grid, "masses")) {
        if (aircraft) |plane| mass_table.sync(plane);
        switch (operation) {
            .reset => if (aircraft) |plane| mass_table.reset(plane),
            .set => {
                const row = change.row orelse return;
                const column = std.meta.stringToEnum(enum { min, nom, max }, change.key) orelse return;
                const value = change.number() orelse return;
                const line = if (row == 0) &mass_table.total else &mass_table.center;
                line[@intFromEnum(column)] = value;
            },
            else => {},
        }
    }
}

// ------------------------------------------------------------------ os checkpoints e o MTOW salvo (enquanto a aba vive)

const Snapshot = @TypeOf(@as(core.runner.Instance, undefined).r);

/// um checkpoint no começo de cada etapa da missão, do avião aberto
const Checkpoints = struct {
    saved: [core.limits.max_segments + 1]?*Snapshot = [_]?*Snapshot{null} ** (core.limits.max_segments + 1),
    source: u64 = 0,

    fn sync(store: *Checkpoints, aircraft: *const Aircraft) void {
        const source = fingerprint(aircraft);
        if (store.source == source) return;
        store.clear();
        store.source = source;
    }

    fn clear(store: *Checkpoints) void {
        for (&store.saved) |*slot| if (slot.*) |snapshot| {
            std.heap.page_allocator.destroy(snapshot);
            slot.* = null;
        };
    }

    fn put(store: *Checkpoints, k: usize, instance: *const core.runner.Instance) void {
        if (k >= store.saved.len) return;
        if (store.saved[k] == null) store.saved[k] = std.heap.page_allocator.create(Snapshot) catch return;
        store.saved[k].?.* = instance.r;
    }

    fn get(store: *const Checkpoints, k: usize) ?*const Snapshot {
        return if (k < store.saved.len) store.saved[k] else null;
    }
};

var checkpoints: Checkpoints = .{};

/// a massa e o CG com que o avião voa: o que passa da massa montada entra no CG seco, e o CG pode ser levado a um x
pub const Loading = struct {
    mass: ?f64 = null, // a massa total (kg)
    center_x: ?f64 = null, // o x do CG do avião inteiro (m, corpo)

    /// muda os parâmetros já preenchidos (`fill`), antes do configure
    pub fn apply(loading: Loading, params: *types.Params) void {
        var scratch: types.Params = params.*;
        var scratch_run: core.runner.Instance = .{ .p = scratch };
        _ = &scratch_run;
        const now = core.trim.Ctx.init(params, &scratch_run.r.f);
        if (loading.mass) |wanted| if (wanted > now.m) {
            params.m_dry += wanted - now.m;
        };
        if (loading.center_x) |target| {
            const after = core.trim.Ctx.init(params, &scratch_run.r.f);
            params.r_dry[0] += (target - after.rcg[0]) * after.m / params.m_dry;
        }
        scratch = params.*;
    }
};

/// o MTOW que o modo MTOW achou para uma pista (o avião, x_warning e z_warning)
pub const SavedMtow = struct { source: u64, x_warning: f64, z_warning: f64, loading: Loading, mass: f64 };
var saved_mtows: [8]?SavedMtow = [_]?SavedMtow{null} ** 8;

fn savedFor(aircraft: *const Aircraft, x_warning: f64, z_warning: f64) ?SavedMtow {
    const source = fingerprint(aircraft);
    for (saved_mtows) |entry| if (entry) |saved| {
        if (saved.source == source and @abs(saved.x_warning - x_warning) < 1e-3 and @abs(saved.z_warning - z_warning) < 1e-3) return saved;
    };
    return null;
}

/// os MTOW salvos deste avião, na ordem da pista (x_warning, depois z_warning), como `saved_mtows` do Python
pub fn savedMtows(aircraft: *const Aircraft, out: *[saved_mtows.len]SavedMtow) []SavedMtow {
    const source = fingerprint(aircraft);
    var count: usize = 0;
    for (saved_mtows) |entry| if (entry) |saved| if (saved.source == source) {
        out[count] = saved;
        count += 1;
    };
    std.mem.sort(SavedMtow, out[0..count], {}, struct {
        fn before(_: void, a: SavedMtow, b: SavedMtow) bool {
            return if (a.x_warning != b.x_warning) a.x_warning < b.x_warning else a.z_warning < b.z_warning;
        }
    }.before);
    return out[0..count];
}

fn saveMtow(entry: SavedMtow) void {
    for (&saved_mtows) |*slot| if (slot.*) |saved| {
        if (saved.source == entry.source and @abs(saved.x_warning - entry.x_warning) < 1e-3 and @abs(saved.z_warning - entry.z_warning) < 1e-3) {
            slot.* = entry;
            return;
        }
    };
    for (&saved_mtows) |*slot| if (slot.* == null) {
        slot.* = entry;
        return;
    };
    saved_mtows[0] = entry;
}

// ------------------------------------------------------------------ o formulário

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const mode = Mode.named(values.text("mode", Mode.mission.label()));
    if (aircraft) |plane| {
        leg_table.sync(plane);
        mass_table.sync(plane);
    }
    var params: std.ArrayList(simulation.Param) = .empty;
    try params.append(memory, .{ .key = "mode", .label = "Análise", .kind = .choice, .default = .{ .text = Mode.mission.label() }, .choices = &mode_labels, .rebuild = true });
    const field = if (aircraft) |plane| plane.airfield else model.Airfield{};
    const runway = [_]simulation.Param{
        .{ .key = "x_warning", .label = "x_warning (pista)", .default = .{ .number = field.x_warning }, .minimum = 1, .maximum = 2000, .unit = "m", .group = group_runway, .help = "comprimento de pista: tem de 'decolar' (passar do z_warning) antes desta distância" },
        .{ .key = "z_warning", .label = "z_warning (altura)", .default = .{ .number = field.z_warning }, .minimum = -20, .maximum = 50, .unit = "m", .group = group_runway, .help = "altura sobre a superfície de partida que conta como decolado; ≤ 0 na mesa: quanto pode afundar abaixo dela" },
        .{ .key = "busca", .label = "Busca do acionamento", .kind = .choice, .default = .{ .text = takeoff_opt.search_labels[0] }, .choices = &takeoff_opt.search_labels, .group = group_runway, .help = "grade: 8 pontos na pista e refino em volta do melhor. bisseção: parte de onde o avião sai do chão sem acionar e divide a faixa até achar a janela" },
        .{ .key = "tolerancia", .label = "Tolerância da bisseção", .default = .{ .number = 0 }, .minimum = 0, .maximum = 20, .unit = "% x_warning", .group = group_runway, .help = "só na bisseção: aceita errar o acionamento até isto do x_warning e desiste cedo da massa que nem com o comando todo cabrando sai do chão a tempo. 0 = a busca de sempre" },
    };
    var hand: std.ArrayList(simulation.Param) = .empty;
    if (mode != .mtow) {
        try hand.append(memory, .{ .key = "mass_source", .label = "Massa", .kind = .choice, .default = .{ .text = mass_labels[0] }, .choices = &mass_labels, .rebuild = true, .group = group_mass, .help = "a do avião; o MTOW que o modo MTOW achou para esta pista (x_warning e z_warning), guardado enquanto o programa está aberto; ou a digitada" });
        if (std.mem.eql(u8, values.text("mass_source", ""), mass_labels[2])) {
            const total = if (aircraft) |plane| if (baseline(plane)) |known| round(known.mass, 1e3) else 5.0 else 5.0;
            try hand.append(memory, .{ .key = "mass_hand", .label = "Massa total", .default = .{ .number = total }, .minimum = 0.1, .maximum = 500, .unit = "kg", .group = group_mass, .help = "o que passa da massa do avião entra como massa no CG" });
        }
    }
    if (mode == .mission or mode == .takeoff) {
        try hand.append(memory, .{ .key = "trigger", .label = "Acionamento do profundor", .kind = .choice, .default = .{ .text = trigger_labels[0] }, .choices = &trigger_labels, .rebuild = true, .group = group_mass, .help = "otimizado para a pista ou o que se digita (sem procurar)" });
        if (std.mem.eql(u8, values.text("trigger", ""), trigger_labels[1])) {
            const takeoff = if (aircraft) |plane| plane.takeoff else model.Takeoff{};
            try hand.append(memory, .{ .key = "s_hand", .label = "Acionamento em", .default = .{ .number = if (takeoff.sR < 1e6) takeoff.sR else 10 }, .minimum = 0, .maximum = 2000, .unit = "m", .group = group_mass, .help = "distância da corrida em que o profundor é acionado" });
            try hand.append(memory, .{ .key = "de_hand", .label = "Deflexão", .default = .{ .number = takeoff.de1 }, .minimum = -45, .maximum = 45, .unit = "°", .group = group_mass, .help = "deflexão do profundor (− cabra)" });
        }
    }
    var grids: std.ArrayList(simulation.Grid) = .empty;
    switch (mode) {
        .mission => {
            try grids.append(memory, try legGrid(memory));
            var starts: std.ArrayList([]const u8) = .empty;
            var stops: std.ArrayList([]const u8) = .empty;
            try starts.append(memory, "chão");
            try stops.append(memory, end_label);
            const legs = leg_table.slice();
            for (legs, 0..) |leg, k| {
                if (k > 0) try starts.append(memory, try std.fmt.allocPrint(memory, "início: {s}", .{leg.name}));
                if (k + 1 < legs.len) try stops.append(memory, try std.fmt.allocPrint(memory, "fim: {s}", .{leg.name}));
            }
            try params.append(memory, .{ .key = "start", .label = "Começar de", .kind = .choice, .default = .{ .text = "chão" }, .choices = starts.items, .help = "do checkpoint salvo no início da etapa; se ainda não houver, voa até lá e salva" });
            try params.append(memory, .{ .key = "until", .label = "Parar em", .kind = .choice, .default = .{ .text = end_label }, .choices = stops.items, .help = "para no fim da etapa (salva o checkpoint para continuar dali)" });
            try params.appendSlice(memory, runway[0..2]);
            try params.appendSlice(memory, hand.items);
            const environment = if (aircraft) |plane| plane.environment else model.Environment{};
            const gust = gustVector(environment);
            try params.appendSlice(memory, &.{
                .{ .key = "gust_on", .label = "rajada ligada", .kind = .bool, .default = .{ .toggle = environment.gust }, .group = group_gust, .help = "liga as rajadas das etapas (coluna \"rajada em\" da Trajetória)" },
                .{ .key = "gust_up", .label = "vertical", .default = .{ .number = -gust[2] }, .minimum = -20, .maximum = 20, .unit = "m/s", .group = group_gust, .help = "para cima é positivo" },
                .{ .key = "gust_side", .label = "lateral", .default = .{ .number = gust[1] }, .minimum = -20, .maximum = 20, .unit = "m/s", .group = group_gust, .help = "para leste é positivo" },
                .{ .key = "gust_T", .label = "duração", .default = .{ .number = environment.gust_T }, .minimum = 0.05, .maximum = 20, .unit = "s", .group = group_gust, .help = "a rajada 1 − cos sobe e desce neste tempo" },
            });
        },
        .takeoff => {
            try params.appendSlice(memory, &runway);
            try params.appendSlice(memory, hand.items);
        },
        .turns => {
            try params.appendSlice(memory, runway[0..2]);
            try params.appendSlice(memory, hand.items);
            try params.append(memory, .{ .key = "V_list", .label = "Velocidades", .kind = .floats, .default = .{ .text = "13, 15, 17" }, .unit = "m/s", .help = "para cada V testa raios de inclinação 70° a 14° (R = V²/(g tan φ)) e acha o menor que a aeronave faz sem estolar, sem perder mais de 3 m e seguindo o raio" });
        },
        .mtow => {
            try params.appendSlice(memory, &runway);
            try grids.append(memory, try massGrid(memory));
        },
        .study => {
            const variable = StudyVariable.named(values.text("study_variable", study_labels[0]));
            const now = if (aircraft) |plane| variable.current(plane) else 0;
            try params.appendSlice(memory, &.{
                .{ .key = "study_variable", .label = "variar", .kind = .choice, .default = .{ .text = study_labels[0] }, .choices = &study_labels, .rebuild = true, .group = group_study, .help = "para cada valor, o MTOW desta pista (a mesma busca do modo MTOW); o melhor é o ponto de projeto" },
                .{ .key = "study_from", .label = "de", .default = .{ .number = now - 4 }, .minimum = -45, .maximum = 45, .unit = "°", .group = group_study },
                .{ .key = "study_to", .label = "até", .default = .{ .number = now + 4 }, .minimum = -45, .maximum = 45, .unit = "°", .group = group_study },
                .{ .key = "study_steps", .label = "valores", .kind = .int, .default = .{ .number = 5 }, .minimum = 2, .maximum = 21, .group = group_study, .help = "cada valor é um MTOW inteiro (uns segundos cada)" },
            });
            try params.appendSlice(memory, &runway);
            try grids.append(memory, try massGrid(memory));
        },
    }
    try simulation.writeSpecs(out, params.items, try plotsFor(memory, mode, aircraft), Mission.description, .{ .grids = grids.items });
}

fn gustVector(environment: model.Environment) [3]f64 {
    var vector = [3]f64{ 0, 0, -2 };
    for (environment.gust_U[0..@min(environment.gust_U.len, 3)], 0..) |item, k| vector[k] = item;
    return vector;
}

// ------------------------------------------------------------------ os gráficos de cada modo

fn plot(key: []const u8, title: []const u8, xlabel: []const u8, ylabel: []const u8) simulation.Plot {
    return .{ .key = key, .title = title, .xlabel = xlabel, .ylabel = ylabel };
}

const trajectory_plots = [_]simulation.Plot{
    .{ .key = "t3", .title = "Trajetória 3D", .xlabel = "e (m) — leste", .ylabel = "n (m) — eixo da pista", .kind = .track },
    plot("xz", "Plano XZ", "x (m)", "z (m)"),
    plot("xy", "Plano XY", "x (m)", "y (m)"),
    plot("zy", "Plano ZY", "y (m)", "z (m)"),
};
const takeoff_plots = [_]simulation.Plot{
    plot("dt", "Decolagem: ângulo da aeronave e da asa", "t (s)", "ângulo (°)"),
    plot("dh", "Decolagem: altura", "x (m)", "h (m)"),
    plot("dv", "Decolagem: velocidades", "x (m)", "V (m/s)"),
    plot("da", "Decolagem: θ, α, γ", "x (m)", "ângulo (°)"),
    plot("dc", "Decolagem: comandos", "x (m)", "°"),
    plot("dr", "Decolagem: reações no trem", "x (m)", "N"),
    plot("dm", "Decolagem: momentos do trem", "x (m)", "N·m"),
};
const optimization_plot = plot("op", "Acionamento do profundor × n_dec (★ escolhido)", "s (m)", "n_dec (m)");
const first_plots = [_]simulation.Plot{
    trajectory_plots[1],                                         takeoff_plots[0], takeoff_plots[5],
    plot("tcl", "Decolagem: C_L", "t (s)", "C_L"),               plot("tcd", "Decolagem: C_D", "t (s)", "C_D"),
    plot("tld", "Decolagem: sustentação e arrasto", "t (s)", "N"), plot("tmL", "Decolagem: rolamento L e δ_a", "t (s)", "N·m / °"),
    plot("tmM", "Decolagem: arfagem M e δ_e", "t (s)", "N·m / °"), plot("tmN", "Decolagem: guinada N e δ_r", "t (s)", "N·m / °"),
};
const rest_plots = [_]simulation.Plot{ takeoff_plots[1], takeoff_plots[2], takeoff_plots[3], takeoff_plots[4], takeoff_plots[6], trajectory_plots[0] };
const mtow_plots = [_]simulation.Plot{
    plot("mt", "MTOW: n_dec × massa (★ MTOW)", "m (kg)", "n_dec (m)"),
    plot("mc", "Massas × massa de decolagem", "m (kg)", "kg ou L"),
    plot("ma", "Acionamento, δ_e e xCG × massa", "m (kg)", "m / ° / % CMA"),
};
const study_plots = [_]simulation.Plot{
    plot("sm", "Estudo: MTOW × variável (★ ponto de projeto)", "variável", "MTOW (kg)"),
    plot("sd", "Estudo: corrida até decolar no MTOW", "variável", "n_dec (m)"),
};
const turn_plots = [_]simulation.Plot{
    plot("cv", "Curvas: trajetórias", "e (m)", "n (m)"),
    plot("cr", "C_L/C_Lmax × raio", "R (m)", "—"),
    plot("cp", "Inclinação × raio", "R (m)", "|φ| (°)"),
    plot("cn", "Fator de carga × raio (em regime)", "R (m)", "n"),
    plot("ct", "Curvas: fator de carga no tempo (— n_z, ··· n no estol)", "t desde o início da curva (s)", "n"),
    plot("ch", "Altura perdida × raio", "R (m)", "m"),
    plot("rmin", "Raio mínimo", "V (m/s)", "R mínimo (m)"),
};
const time_plots = [_]simulation.Plot{
    plot("vel", "Velocidades", "t (s)", "V (m/s)"),              plot("alt", "Altura", "t (s)", "h (m)"),
    plot("ang", "Ângulos", "t (s)", "ângulo (°)"),               plot("rumo", "Proa e curso", "t (s)", "ângulo (°)"),
    plot("momL", "Rolamento L", "t (s)", "N·m"),                 plot("momM", "Arfagem M", "t (s)", "N·m"),
    plot("momN", "Guinada N", "t (s)", "N·m"),                   plot("cmd", "Comandos", "t (s)", "δ (°)"),
    plot("thr", "Acelerador", "t (s)", "0–1"),                   plot("cl", "C_L", "t (s)", "C_L"),
    plot("cd", "C_D", "t (s)", "C_D"),                           plot("roc", "Razão de subida", "t (s)", "dh/dt (m/s)"),
    plot("nz", "Fator de carga", "t (s)", "n_z"),                plot("motor", "Motor", "t (s)", "rpm/100, A, N"),
    plot("ene", "Energia", "t (s)", "Wh"),                       plot("bat", "Consumo de bateria", "t (s)", "mAh"),
    plot("batp", "Bateria: SOC", "t (s)", "SOC (%) / I (A)"),    plot("cgp", "Passeio do CG (% CMA, a partir do bordo de ataque)", "t (s)", "% CMA"),
    plot("mem", "Margem estática ao longo do voo", "t (s)", "ME (% CMA)"),
};
const landing_plots = [_]simulation.Plot{
    plot("pr", "Pouso: reações no trem", "x (m)", "N"),
    plot("pm", "Pouso: momentos do trem", "x (m)", "N·m"),
    plot("fg", "Folga da pá e da cauda sobre o chão", "t (s)", "folga (m)"),
};
const lapes_plots = [_]simulation.Plot{
    plot("lx", "LAPES: plano XZ", "n (m)", "h (m)"),
    plot("lc", "LAPES: CG e carga", "t − t_soltura (s)", "cm"),
    plot("lm", "LAPES: massa", "t − t_soltura (s)", "kg"),
    plot("lp", "LAPES: arfagem", "t − t_soltura (s)", "° , °/s , N·m"),
    plot("ls", "LAPES: soltura × impacto", "s de soltura na perna (m)", "impacto n (m)"),
};

/// os gráficos do modo (`plots_for` do Python)
fn plotsFor(memory: std.mem.Allocator, mode: Mode, aircraft: ?*const Aircraft) ![]const simulation.Plot {
    var list: std.ArrayList(simulation.Plot) = .empty;
    switch (mode) {
        .takeoff => {
            try list.appendSlice(memory, &first_plots);
            try list.append(memory, optimization_plot);
            try list.appendSlice(memory, &rest_plots);
        },
        .study => try list.appendSlice(memory, &study_plots),
        .mtow => {
            try list.appendSlice(memory, &first_plots);
            try list.appendSlice(memory, &mtow_plots);
            try list.append(memory, optimization_plot);
            try list.appendSlice(memory, &rest_plots);
        },
        .turns => try list.appendSlice(memory, &turn_plots),
        .mission => {
            try list.appendSlice(memory, &trajectory_plots);
            try list.appendSlice(memory, &time_plots);
            if (aircraft == null or aircraft.?.tanks.len > 0) try list.append(memory, plot("slosh", "Sloshing", "t (s)", "ângulo (°)"));
            try list.append(memory, optimization_plot);
            try list.appendSlice(memory, &takeoff_plots);
            try list.appendSlice(memory, &landing_plots);
            if (aircraft == null or aircraft.?.payload.enabled) try list.appendSlice(memory, &lapes_plots);
        },
    }
    return list.items;
}

// ------------------------------------------------------------------ a rodada

/// a massa e o CG do avião do arquivo
const Baseline = struct { mass: f64, dry_center_percent: f64 };

fn baseline(aircraft: *const Aircraft) ?Baseline {
    const instance = std.heap.page_allocator.create(core.runner.Instance) catch return null;
    defer std.heap.page_allocator.destroy(instance);
    instance.* = .{};
    var diagnosis: model.Diag = .{};
    params_mod.fill(aircraft, &instance.p, &diagnosis) catch return null;
    core.runner.configure(instance) catch return null;
    const now = core.trim.Ctx.init(&instance.p, &instance.r.f);
    const chord = params_mod.references(aircraft)[1];
    return .{ .mass = now.m, .dry_center_percent = 100 * (params_mod.macLeadingEdge(aircraft) - instance.p.r_dry[0]) / chord };
}

/// uma etapa da rodada
const Phase = enum { search, fly, finish, done };

/// uma massa testada no MTOW
const MtowCase = struct {
    fraction: f64,
    mass: f64,
    best: takeoff_opt.Result,
    center_x: f64,
    tried: []takeoff_opt.Result,
};

/// uma curva testada
const TurnCase = struct { speed: f64, turn: analysis.Turn, rows: []const types.LogRow };

const RunState = struct {
    memory: std.mem.Allocator = undefined,
    mode: Mode = .mission,
    aircraft: Aircraft = .{}, // o avião da rodada (o percurso da tabela, a rajada do formulário)
    loading: Loading = .{},
    calibrated: *core.runner.Instance = undefined,
    info: params_mod.Info = .{},
    refs: flightplots.Refs = .{},
    x_warning: f64 = 60,
    z_warning: f64 = 1,
    search: takeoff_opt.Search = .grid,
    tolerance: f64 = 0,
    hand_trigger: ?[2]f64 = null, // (s, δe) digitados
    phase: Phase = .search,
    notes: std.ArrayList([]const u8) = .empty,
    checks: std.ArrayList(simulation.Check) = .empty,
    summary: std.ArrayList([2][]const u8) = .empty,
    figures: simulation.Figures = undefined,
    // decolagem
    best: ?takeoff_opt.Result = null,
    tried: []takeoff_opt.Result = &.{},
    // missão
    flight: *core.runner.Instance = undefined,
    legs: []Leg = &.{},
    events: []model.MissionEvent = &.{},
    leg_names: []const []const u8 = &.{},
    first: usize = 0,
    stop_at: usize = 0,
    current: usize = 0,
    log: std.ArrayList(types.LogRow) = .empty,
    status: ?core.runner.Status = null,
    radii: std.ArrayList(struct { []const u8, f64 }) = .empty,
    drop_leg: ?usize = null,
    aim: bool = false,
    // curvas
    speeds: []const f64 = &.{},
    turns: std.ArrayList(TurnCase) = .empty,
    turn_index: usize = 0,
    // MTOW
    center_options: []const f64 = &.{},
    cases: std.ArrayList(MtowCase) = .empty,
    bisection: struct { low: f64 = 0, high: f64 = 1, step: usize = 0, best: ?usize = null, mtow_fraction: ?f64 = null, stage: enum { low, high, bisect, refine, mission, done } = .low } = .{},
    // a busca do MTOW em duas fases: só a decolagem até achar a massa; depois a missão inteira nela. Se a missão
    // não completa, a bisseção volta com "decola e completa a missão" como critério
    with_mission: bool = false,
    good_center: ?f64 = null, // o xCG que decolou por último: o primeiro a tentar na massa seguinte
    simulations: usize = 0, // decolagens e missões voadas na busca (o limite é `simulation_limit`)
    // estudo: os valores da variável e o MTOW de cada um (NaN: não decola nem com a menor massa)
    study: struct {
        variable: StudyVariable = .tilt,
        base: Aircraft = .{},
        values: []const f64 = &.{},
        index: usize = 0,
        mtow: std.ArrayList(f64) = .empty,
        run_length: std.ArrayList(f64) = .empty,
    } = .{},
};

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    state.memory = memory;
    state.mode = Mode.named(values.text("mode", Mode.mission.label()));
    state.x_warning = values.number("x_warning", run.aircraft.airfield.x_warning);
    state.z_warning = values.number("z_warning", run.aircraft.airfield.z_warning);
    state.search = takeoff_opt.Search.named(values.text("busca", takeoff_opt.search_labels[0]));
    state.tolerance = values.number("tolerancia", 0) / 100;
    if (std.mem.eql(u8, values.text("trigger", ""), trigger_labels[1]))
        state.hand_trigger = .{ values.number("s_hand", run.aircraft.takeoff.sR), values.number("de_hand", run.aircraft.takeoff.de1) };
    state.aircraft = run.aircraft.*;
    if (state.mode == .mission) try applyTable(memory, &state.aircraft, values);
    // a massa do voo: a do avião, o MTOW salvo desta pista ou a digitada
    if (state.mode != .mtow and state.mode != .study) {
        const source = values.text("mass_source", mass_labels[0]);
        if (std.mem.eql(u8, source, mass_labels[1])) {
            const saved = savedFor(run.aircraft, state.x_warning, state.z_warning) orelse {
                run.fail("ainda não há MTOW salvo para x_warning = {d} m e z_warning = {d} m: rode antes o modo MTOW com esta pista", .{ state.x_warning, state.z_warning });
                return error.Failed;
            };
            state.loading = saved.loading;
        } else if (std.mem.eql(u8, source, mass_labels[2])) state.loading = .{ .mass = values.number("mass_hand", 0) };
    }
    state.calibrated = try memory.create(core.runner.Instance);
    state.calibrated.* = .{};
    var diagnosis: model.Diag = .{};
    state.info = calibrateWith(&state.aircraft, state.calibrated, state.loading, &diagnosis) catch |err| {
        run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    state.refs = refsOf(&state.aircraft, state.info, state.x_warning, state.z_warning);
    state.figures = try simulation.Figures.init(memory, try plotsFor(memory, state.mode, &state.aircraft));
    switch (state.mode) {
        .mission => try startMission(run, state, values),
        .turns => {
            var buffer: [16]f64 = undefined;
            state.speeds = try memory.dupe(f64, values.numbers("V_list", &buffer, &.{ 13, 15, 17 }));
        },
        .mtow, .study => {
            mass_table.sync(run.aircraft);
            var centers: std.ArrayList(f64) = .empty;
            const leading = params_mod.macLeadingEdge(&state.aircraft);
            const chord = params_mod.references(&state.aircraft)[1];
            for (mass_table.center) |percent| {
                const x = leading - percent / 100 * chord;
                for (centers.items) |known| {
                    if (known == x) break;
                } else try centers.append(memory, x);
            }
            std.mem.sort(f64, centers.items, {}, std.sort.asc(f64));
            state.center_options = centers.items;
            if (state.mode == .study) try startStudy(run, state, values);
        },
        .takeoff => {},
    }
    if (state.loading.mass != null and state.mode != .mtow and state.mode != .study)
        try state.checks.append(memory, .{ .status = .info, .item = "massa do voo", .value = try printed(memory, "{d:.2} kg", .{state.info.mass}), .criterion = values.text("mass_source", ""), .group = "Massa" });
}

/// fill, a massa do voo, configure e a calibração do piloto (`calibrate` do Python, com a massa da variante)
fn calibrateWith(aircraft: *const Aircraft, instance: *core.runner.Instance, loading: Loading, diagnosis: *model.Diag) !params_mod.Info {
    try params_mod.fill(aircraft, &instance.p, diagnosis);
    loading.apply(&instance.p);
    try core.runner.configure(instance);
    return params_mod.calibrate(aircraft, instance, diagnosis);
}

/// configura `instance` para voar `aircraft` com o piloto já calibrado e a massa do voo
fn configureFlight(aircraft: *const Aircraft, instance: *core.runner.Instance, autopilot: types.Autopilot, loading: Loading) !void {
    var diagnosis: model.Diag = .{};
    try params_mod.fill(aircraft, &instance.p, &diagnosis);
    loading.apply(&instance.p);
    instance.p.ap = autopilot;
    try core.runner.configure(instance);
}

fn refsOf(aircraft: *const Aircraft, info: params_mod.Info, x_warning: f64, z_warning: f64) flightplots.Refs {
    var refs: flightplots.Refs = .{
        .stall_speed = info.Vs,
        .alpha_stall_deg = info.alpha_stall_deg,
        .lift_limit = aircraft.autopilot.kCL,
        .handover_height = aircraft.takeoff.ht,
        .x_warning = x_warning,
        .z_warning = z_warning,
        .landing_max = aircraft.airfield.landing_max,
        .load_limit = aircraft.performance.load_factor,
    };
    // θ em que a cauda toca o chão: a reta das rodas principais até o patim
    const gear = aircraft.gear;
    var main: ?[2]f64 = null;
    var skid: ?[2]f64 = null;
    if (std.mem.eql(u8, gear.layout, "custom")) {
        for (gear.custom) |leg| {
            if (main == null and std.mem.eql(u8, leg.kind, "main")) main = .{ leg.x, leg.z };
            if (skid == null and std.mem.eql(u8, leg.kind, "skid")) skid = .{ leg.x, leg.z };
        }
    } else {
        main = .{ gear.main_x, gear.main_z };
        if (std.mem.eql(u8, gear.layout, "tricycle") and gear.tail_skid) skid = .{ gear.skid_x, gear.skid_z };
    }
    if (main != null and skid != null and main.?[0] > skid.?[0]) refs.tail_angle_deg = std.math.atan2(main.?[1] - skid.?[1], main.?[0] - skid.?[0]) * deg;
    return refs;
}

/// o percurso da tabela e a rajada do formulário no avião da rodada
fn applyTable(memory: std.mem.Allocator, aircraft: *Aircraft, values: simulation.Values) !void {
    leg_table.sync(aircraft);
    const legs = try memory.dupe(Leg, leg_table.slice());
    var events: std.ArrayList(model.MissionEvent) = .empty;
    for (aircraft.mission.events) |event| if (!std.mem.eql(u8, event.kind, "gust") and event.leg < legs.len) try events.append(memory, event);
    for (leg_table.gusts[0..leg_table.count], 0..) |gust, k| if (gust) |at| try events.append(memory, .{ .kind = "gust", .leg = @intCast(k), .s = at });
    aircraft.mission.legs = legs;
    aircraft.mission.events = events.items;
    const environment = &aircraft.environment;
    const before = gustVector(environment.*);
    environment.gust = values.toggle("gust_on", environment.gust);
    environment.gust_U = try memory.dupe(f64, &.{ before[0], values.number("gust_side", before[1]), -values.number("gust_up", -before[2]) });
    environment.gust_T = values.number("gust_T", environment.gust_T);
}

fn printed(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn advanceRun(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    switch (state.mode) {
        .takeoff => return advanceTakeoff(run, state),
        .mission => return advanceMission(run, state),
        .turns => return advanceTurns(run, state),
        .mtow => return advanceMtow(run, state),
        .study => return advanceStudy(run, state),
    }
}

// ------------------------------------------------------------------ decolagem

/// a decolagem com o acionamento otimizado para a pista ou o digitado (avaliado uma vez)
fn chooseTakeoff(state: *RunState, aircraft: *const Aircraft, loading: Loading) !takeoff_opt.Outcome {
    return searchTakeoff(state, aircraft, loading, true);
}

/// a decolagem numa massa: `refine` falso só procura um acionamento que passa (a bisseção do MTOW), verdadeiro
/// procura o melhor
fn searchTakeoff(state: *RunState, aircraft: *const Aircraft, loading: Loading, refine: bool) !takeoff_opt.Outcome {
    var diagnosis: model.Diag = .{};
    var takeoffs = try takeoff_opt.Takeoffs.init(state.memory, aircraft, state.calibrated.p.ap, state.x_warning, state.z_warning, 0.01, &diagnosis);
    loading.apply(&takeoffs.instance.p);
    try core.runner.configure(takeoffs.instance);
    takeoffs.takeoff = takeoffs.instance.p.takeoff;
    if (state.hand_trigger) |chosen| {
        const result = try takeoffs.evaluate(if (takeoffs.control != null) chosen[0] else null, chosen[1], null);
        const tried = try state.memory.dupe(takeoff_opt.Result, &.{result});
        return .{ .best = result, .tried = tried };
    }
    return if (refine) takeoff_opt.optimize(&takeoffs, state.search, state.tolerance) else takeoff_opt.feasible(&takeoffs, state.search, state.tolerance);
}

/// a decolagem escolhida voada de novo com o registro fino (0,005 s), para os gráficos
fn loggedTakeoff(state: *RunState, aircraft: *const Aircraft, loading: Loading, best: takeoff_opt.Result) !struct { result: takeoff_opt.Result, rows: []const types.LogRow } {
    var diagnosis: model.Diag = .{};
    var takeoffs = try takeoff_opt.Takeoffs.init(state.memory, aircraft, state.calibrated.p.ap, state.x_warning, state.z_warning, 0.005, &diagnosis);
    loading.apply(&takeoffs.instance.p);
    try core.runner.configure(takeoffs.instance);
    takeoffs.takeoff = takeoffs.instance.p.takeoff;
    const position: ?f64 = if (takeoffs.control != null) best.position else null;
    const hold: ?f64 = if (std.math.isFinite(best.hold)) best.hold else null;
    const result = try takeoffs.evaluate(position, best.deflection, hold);
    return .{ .result = result, .rows = try state.memory.dupe(types.LogRow, takeoffs.log.items) };
}

fn advanceTakeoff(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    switch (state.phase) {
        .search => {
            run.say("otimizando o acionamento do profundor", .{});
            const outcome = try chooseTakeoff(state, &state.aircraft, state.loading);
            state.best = outcome.best;
            state.tried = outcome.tried;
            state.phase = .finish;
            run.progress = 0.9;
            return false;
        },
        else => {
            const best = state.best.?;
            const flown = try loggedTakeoff(state, &state.aircraft, state.loading, best);
            try optimizationSeries(state, state.tried, best);
            if (flown.rows.len > 0) try takeoffSeries(state, flown.rows, flown.result.events);
            const memory = state.memory;
            const events = flown.result.events;
            try state.summary.appendSlice(memory, &.{
                .{ "status", flown.result.status.text() },
                .{ "x_warning", try printed(memory, "{d}", .{state.x_warning}) },
                .{ "z_warning", try printed(memory, "{d}", .{state.z_warning}) },
                .{ "n_dec", try printed(memory, "{d:.4}", .{flown.result.takeoff_point}) },
                .{ "folga_de_pista", try printed(memory, "{d:.4}", .{state.x_warning - flown.result.takeoff_point}) },
                .{ "acionamento_m", try printed(memory, "{d:.4}", .{best.position}) },
                .{ "deflexao_graus", try printed(memory, "{d}", .{best.deflection}) },
                .{ "V_ao_sair_do_chao", try printed(memory, "{d:.4}", .{events.VLO}) },
                .{ "n_saiu_do_chao", try printed(memory, "{d:.4}", .{events.nLO}) },
                .{ "massa", try printed(memory, "{d:.4}", .{state.info.mass}) },
            });
            try takeoffChecks(state, &state.aircraft, best);
            state.phase = .done;
            run.progress = 1;
            return true;
        },
    }
}

/// as decolagens testadas: uma linha por deflexão, ○ as que passam e × as que não, a estrela na escolhida
fn optimizationSeries(state: *RunState, tried: []const takeoff_opt.Result, best: takeoff_opt.Result) !void {
    const memory = state.memory;
    const figures = state.figures;
    const colors = [_][]const u8{ "#1f77b4", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf" };
    var levels: std.ArrayList(f64) = .empty;
    for (tried) |result| {
        for (levels.items) |known| {
            if (known == result.deflection) break;
        } else try levels.append(memory, result.deflection);
    }
    std.mem.sort(f64, levels.items, {}, std.sort.asc(f64));
    var finite_max = state.x_warning;
    for (tried) |result| if (std.math.isFinite(result.takeoff_point)) {
        finite_max = @max(finite_max, result.takeoff_point);
    };
    const ceiling = 1.15 * finite_max; // "não decolou": desenhado no alto do gráfico
    for (levels.items, 0..) |level, i| {
        var chosen: std.ArrayList(takeoff_opt.Result) = .empty;
        for (tried) |result| if (result.deflection == level and std.math.isFinite(result.position)) try chosen.append(memory, result);
        if (chosen.items.len == 0) continue;
        std.mem.sort(takeoff_opt.Result, chosen.items, {}, struct {
            fn less(_: void, left: takeoff_opt.Result, right: takeoff_opt.Result) bool {
                return left.position < right.position;
            }
        }.less);
        const color = colors[i % colors.len];
        var xs: std.ArrayList(f64) = .empty;
        var ys: std.ArrayList(f64) = .empty;
        var pass_x: std.ArrayList(f64) = .empty;
        var pass_y: std.ArrayList(f64) = .empty;
        var fail_x: std.ArrayList(f64) = .empty;
        var fail_y: std.ArrayList(f64) = .empty;
        var any_ok = false;
        for (chosen.items) |result| {
            const y = if (std.math.isFinite(result.takeoff_point)) result.takeoff_point else ceiling;
            try xs.append(memory, result.position);
            try ys.append(memory, y);
            if (result.ok) {
                any_ok = true;
                try pass_x.append(memory, result.position);
                try pass_y.append(memory, y);
            } else {
                try fail_x.append(memory, result.position);
                try fail_y.append(memory, y);
            }
        }
        const label = try printed(memory, "δe = {d}°{s}", .{ level, if (any_ok) "" else " (nenhum ponto passa; no alto: não decolou)" });
        try figures.curve("op", .{ .name = label, .x = xs.items, .y = ys.items, .color = color, .width = 1 });
        try figures.curve("op", .{ .name = "passa", .x = pass_x.items, .y = pass_y.items, .color = color, .marker = "o", .size = 9, .legend = false });
        try figures.curve("op", .{ .name = "não passa", .x = fail_x.items, .y = fail_y.items, .color = color, .marker = "x", .size = 11, .legend = false });
    }
    try figures.guide("op", .{ .name = try printed(memory, "x_warning ({d} m)", .{state.x_warning}), .value = state.x_warning, .vertical = false, .color = "#d62728", .width = 3 });
    if (std.math.isFinite(best.position) and std.math.isFinite(best.takeoff_point))
        try figures.curve("op", .{ .name = try printed(memory, "★ escolhido: {d:.1} m, δe = {d}°", .{ best.position, best.deflection }), .x = try memory.dupe(f64, &.{best.position}), .y = try memory.dupe(f64, &.{best.takeoff_point}), .color = "#ffcc00", .marker = "star", .size = 24 });
}

/// os gráficos da decolagem: a janela na pista, os ângulos, os coeficientes no tempo e a trajetória
fn takeoffSeries(state: *RunState, rows: []const types.LogRow, events: types.Events) !void {
    const memory = state.memory;
    const aircraft = &state.aircraft;
    const flight = try flightplots.Flight.init(memory, rows, events, &.{ "decolagem", "cruzeiro" });
    try flightplots.takeoffWindow(state.figures, flight, state.refs, tableEdge(aircraft));
    try flightplots.takeoffAngles(state.figures, flight, wingIncidence(aircraft), state.refs.alpha_stall_deg + wingIncidence(aircraft));
    try flightplots.takeoffTime(state.figures, flight, aircraft.environment.rho, params_mod.references(aircraft)[0]);
    try flightplots.trajectory(state.figures, flight, null);
}

fn tableEdge(aircraft: *const Aircraft) ?f64 {
    return if (std.mem.eql(u8, aircraft.airfield.takeoff_from, "mesa")) aircraft.airfield.table_length else null;
}

fn wingIncidence(aircraft: *const Aircraft) f64 {
    const wing = params_mod.firstSurface(aircraft, "wing") orelse return 0;
    return wing.incidence;
}

fn takeoffChecks(state: *RunState, aircraft: *const Aircraft, best: takeoff_opt.Result) !void {
    const memory = state.memory;
    const group = "Pista";
    const inside = best.x_excess == 0;
    try state.checks.append(memory, .{
        .status = if (inside) .ok else .falha,
        .item = "x_warning: decolou dentro da pista",
        .value = if (!std.math.isFinite(best.takeoff_point)) "não decolou" else try printed(memory, "n_dec = {d:.1} m", .{best.takeoff_point}),
        .criterion = try printed(memory, "≤ {d} m", .{state.x_warning}),
        .why = if (inside) "" else try printed(memory, "passou {d:.1} m do comprimento de pista", .{best.x_excess}),
        .fix = if (inside) "" else "menos massa, mais tração, mais C_Lmax ou mais área de asa",
        .group = group,
    });
    const high_enough = best.z_short == 0;
    try state.checks.append(memory, .{
        .status = if (high_enough) .ok else .falha,
        .item = "z_warning: altura que conta como decolado",
        .value = try printed(memory, "menor altura depois de sair do chão: {d:.2} m", .{best.lowest}),
        .criterion = try printed(memory, "z_warning = {d} m", .{state.z_warning}),
        .why = if (high_enough) "" else try printed(memory, "faltaram {d:.2} m", .{best.z_short}),
        .fix = if (high_enough) "" else "aciona o profundor antes ou com mais deflexão; mesa mais longa",
        .group = group,
    });
    if (takeoff_opt.pitchControl(aircraft)) |control| {
        try state.checks.append(memory, .{
            .status = .info,
            .item = try printed(memory, "acionamento do {s}", .{control}),
            .value = try printed(memory, "em {d:.1} m, deflexão {d}°", .{ best.position, best.deflection }),
            .criterion = try printed(memory, "máx. {d}°", .{aircraft.autopilot.de_max}),
            .why = if (best.ok) "a maior deflexão que funciona; ponto com a maior folga até o x_warning" else "nenhum ponto passou: este é o menos ruim",
            .fix = if (best.ok) "copie para Configuração → Decolagem (sR, de1)" else "",
            .group = group,
        });
        if (std.math.isFinite(best.hold)) try state.checks.append(memory, .{
            .status = .info,
            .item = "profundor segurado na corrida",
            .value = try printed(memory, "{d}° (pica) até o acionamento", .{best.hold}),
            .criterion = "—",
            .why = "com o profundor neutro o avião saía do chão antes de ter velocidade de voo (motor inclinado ou EH que cabra muito)",
            .fix = "Configuração → Decolagem (de0)",
            .group = group,
        });
    } else try state.checks.append(memory, .{ .status = .info, .item = "sem comando de arfagem", .value = "decola sozinha", .criterion = "—", .why = "a aeronave não tem profundor/elevon: não há acionamento a otimizar", .group = group });
}

// ------------------------------------------------------------------ missão

fn startMission(run: *simulation.Run, state: *RunState, values: simulation.Values) !void {
    const memory = state.memory;
    const aircraft = &state.aircraft;
    checkpoints.sync(run.aircraft);
    state.legs = try memory.dupe(Leg, aircraft.mission.legs);
    state.events = try memory.dupe(model.MissionEvent, aircraft.mission.events);
    const names = try memory.alloc([]const u8, state.legs.len);
    for (state.legs, names) |leg, *leg_name| leg_name.* = leg.name;
    state.leg_names = names;
    const count = state.legs.len;
    const start = values.text("start", "chão");
    const until = values.text("until", end_label);
    state.first = 0;
    if (std.mem.startsWith(u8, start, "início: ")) {
        for (names, 0..) |leg_name, k| if (std.mem.eql(u8, leg_name, start["início: ".len..])) {
            state.first = k;
        };
    }
    state.stop_at = count;
    if (std.mem.startsWith(u8, until, "fim: ")) {
        for (names, 0..) |leg_name, k| if (std.mem.eql(u8, leg_name, until["fim: ".len..])) {
            state.stop_at = k + 1;
        };
    }
    if (state.stop_at <= state.first) state.stop_at = count;
    for (state.events) |event| if (std.mem.eql(u8, event.kind, "drop") and aircraft.payload.enabled and event.leg >= 0) {
        state.drop_leg = @intCast(event.leg);
    };
    state.aim = aircraft.payload.aim and state.drop_leg != null;
    if (state.first > 0 and checkpoints.get(state.first) != null) state.phase = .fly;
}

/// o avião da rodada com o percurso e os eventos de agora
fn currentPlane(state: *RunState) Aircraft {
    var plane = state.aircraft;
    plane.mission.legs = state.legs;
    plane.mission.events = state.events;
    return plane;
}

/// o percurso mudou (raio automático, ponto de soltura): configura de novo e volta ao checkpoint
fn reconfigure(state: *RunState, back_to: *const Snapshot) !void {
    const plane = currentPlane(state);
    try configureFlight(&plane, state.flight, state.calibrated.p.ap, state.loading);
    state.flight.r = back_to.*;
}

fn advanceMission(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    const memory = state.memory;
    const count = state.legs.len;
    switch (state.phase) {
        .search => {
            run.say("otimizando o acionamento do profundor", .{});
            const outcome = try chooseTakeoff(state, &state.aircraft, state.loading);
            state.best = outcome.best;
            state.tried = outcome.tried;
            try optimizationSeries(state, outcome.tried, outcome.best);
            if (takeoff_opt.pitchControl(&state.aircraft) != null and std.math.isFinite(outcome.best.position)) {
                state.aircraft.takeoff.sR = outcome.best.position;
                state.aircraft.takeoff.de1 = outcome.best.deflection;
                if (std.math.isFinite(outcome.best.hold)) state.aircraft.takeoff.de0 = outcome.best.hold;
            }
            try takeoffChecks(state, &state.aircraft, outcome.best);
            state.phase = .fly;
            return false;
        },
        .fly => {
            if (state.current == 0 and state.status == null) try beginFlight(run, state);
            const k = state.current;
            if (k + 1 <= @min(state.stop_at, count - 1)) {
                run.say("etapa: {s}", .{state.leg_names[k]});
                run.progress = @floatCast(@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(@max(count, 1))));
                try prepareLeg(state, k);
                const outcome = try runner.fly(state.flight, .{ .segment = @intCast(k + 1) }, memory, &state.log);
                state.status = outcome.status;
                if (outcome.status != .stopped) {
                    state.phase = .finish;
                    return false;
                }
                checkpoints.put(k + 1, state.flight);
                state.current += 1;
                return false;
            }
            if (state.stop_at == count and (state.status == null or state.status.? == .stopped)) {
                try prepareLeg(state, k);
                run.say("etapa: {s}", .{state.leg_names[count - 1]});
                const outcome = try runner.fly(state.flight, .{}, memory, &state.log);
                state.status = outcome.status;
            }
            state.phase = .finish;
            return false;
        },
        .finish => {
            try finishMission(state);
            state.phase = .done;
            run.progress = 1;
            return true;
        },
        .done => return true,
    }
}

/// o começo do voo: do checkpoint da etapa pedida ou do chão (voando até ela sem registro, se preciso)
fn beginFlight(run: *simulation.Run, state: *RunState) !void {
    state.flight = try state.memory.create(core.runner.Instance);
    state.flight.* = .{};
    const plane = currentPlane(state);
    try configureFlight(&plane, state.flight, state.calibrated.p.ap, state.loading);
    const first = state.first;
    if (first > 0) if (checkpoints.get(first)) |snapshot| {
        state.flight.r = snapshot.*;
        state.current = first;
        state.status = .stopped;
        return;
    };
    try core.runner.resetGround(state.flight);
    checkpoints.put(0, state.flight);
    if (first > 0) {
        try state.notes.append(state.memory, try printed(state.memory, "não havia checkpoint no início de '{s}': voou do chão até lá e salvou", .{state.leg_names[first]}));
        for (0..first) |k| {
            run.say("chegando em '{s}': {s}", .{ state.leg_names[first], state.leg_names[k] });
            const outcome = try runner.fly(state.flight, .{ .segment = @intCast(k + 1) }, state.memory, null);
            if (outcome.status != .stopped) {
                run.fail("o voo terminou ({s}) em '{s}', antes de chegar em '{s}'", .{ runner.statusName(outcome.status), state.leg_names[k], state.leg_names[first] });
                return error.Failed;
            }
            checkpoints.put(k + 1, state.flight);
        }
    }
    state.current = first;
    state.status = .stopped;
}

/// antes da etapa k: o raio automático da curva e o ponto de soltura da LAPES (do checkpoint)
fn prepareLeg(state: *RunState, k: usize) !void {
    const snapshot = checkpoints.get(k) orelse return;
    const memory = state.memory;
    const leg = state.legs[k];
    if (std.mem.eql(u8, leg.kind, "turn") and leg.radius <= 0) {
        const chosen = try autoTurn(state, k, snapshot);
        state.legs[k].radius = chosen.radius;
        const ok = chosen.verdict == .ok;
        try state.checks.append(memory, .{
            .status = if (ok) .info else .atencao,
            .item = try printed(memory, "raio automático — {s}", .{leg.name}),
            .value = try printed(memory, "R = {d:.1} m", .{chosen.radius}),
            .criterion = "menor raio que a aeronave faz",
            .why = if (ok) "" else try printed(memory, "nenhum raio testado passou ({s}); usou o maior", .{chosen.verdict.text()}),
            .fix = if (ok) "" else "mais velocidade nessa curva",
            .group = "Curvas",
        });
        try state.radii.append(memory, .{ leg.name, chosen.radius });
        try reconfigure(state, snapshot);
    }
    if (state.aim and state.drop_leg.? == k) {
        try aimDrop(state, k, snapshot);
        try reconfigure(state, snapshot);
        state.aim = false;
    }
}

/// o raio da curva k automático: do checkpoint, testa raios do φ máx. do piloto para baixo e fica com o menor que passa
fn autoTurn(state: *RunState, k: usize, snapshot: *const Snapshot) !struct { radius: f64, verdict: analysis.TurnVerdict } {
    const memory = state.memory;
    const segment = state.flight.p.seg[k];
    const speed = @max(segment.V0, segment.V1);
    const climbs = @abs(segment.h1 - segment.h0) > 0.5;
    var best: ?f64 = null;
    var largest: f64 = 0;
    var last_verdict: analysis.TurnVerdict = .never_reached;
    const instance = try memory.create(core.runner.Instance);
    var rows: std.ArrayList(types.LogRow) = .empty;
    for (auto_fractions) |fraction| {
        const radius = @round(autoRadius(speed, state.aircraft.autopilot.phimax * fraction) * 10) / 10;
        largest = @max(largest, radius);
        var plane = currentPlane(state);
        const legs = try memory.dupe(Leg, state.legs);
        legs[k].radius = radius;
        plane.mission.legs = legs;
        instance.* = .{};
        try configureFlight(&plane, instance, state.calibrated.p.ap, state.loading);
        instance.r = snapshot.*;
        rows.clearRetainingCapacity();
        const length = instance.p.seg[k].L;
        _ = try runner.fly(instance, .{ .segment = @intCast(k + 1), .time = snapshot.t + 20 + 3 * length / @max(speed, 1) }, memory, &rows);
        var turn = try analysis.evaluateTurn(memory, rows.items, instance.p.seg[k], k, radius, state.info.Vs, state.aircraft.autopilot.kCL, 75);
        if (climbs and turn.verdict == .loses_height) { // curva que sobe ou desce: a altura não conta
            turn.ok = true;
            turn.verdict = .ok;
        }
        last_verdict = turn.verdict;
        if (turn.ok and (best == null or radius < best.?)) best = radius;
    }
    return if (best) |radius| .{ .radius = radius, .verdict = .ok } else .{ .radius = largest, .verdict = last_verdict };
}

/// o raio de uma curva nivelada a V com inclinação φ: R = V²/(g tan φ) (`auto_radius` do Python), pelo menos 3 m
fn autoRadius(speed: f64, bank_deg: f64) f64 {
    return @max(speed * speed / (g0 * @tan(bank_deg * rad)), 3.0);
}

/// a bisseção no ponto de soltura s (perna k) para a carga cair no alvo (n)
fn aimDrop(state: *RunState, k: usize, snapshot: *const Snapshot) !void {
    const memory = state.memory;
    const target = state.aircraft.payload.target_n;
    const length = state.flight.p.seg[k].L;
    // a soltura fica no mesmo lugar da lista: o checkpoint marca os eventos já feitos pela posição (`ev_done`)
    const drop_index = for (state.events, 0..) |event, index| {
        if (std.mem.eql(u8, event.kind, "drop")) break index;
    } else state.events.len;
    var history: std.ArrayList([2]f64) = .empty;
    const instance = try memory.create(core.runner.Instance);
    const Impact = struct {
        fn at(state_: *RunState, k_: usize, snapshot_: *const Snapshot, drop_index_: usize, instance_: *core.runner.Instance, position: f64, history_: *std.ArrayList([2]f64), target_: f64) !f64 {
            var plane = currentPlane(state_);
            plane.mission.events = try withDrop(state_.memory, state_.events, drop_index_, k_, position);
            instance_.* = .{};
            try configureFlight(&plane, instance_, state_.calibrated.p.ap, state_.loading);
            instance_.p.tmax = snapshot_.t + 300;
            instance_.r = snapshot_.*;
            var outcome = try runner.fly(instance_, .{ .segment = @intCast(k_ + 1) }, state_.memory, null);
            if (outcome.events.trel > 0 and outcome.events.pk_t <= 0) outcome = try runner.fly(instance_, .{ .time = instance_.r.t + 30 }, state_.memory, null); // a carga ainda no ar
            try history_.append(state_.memory, .{ position, outcome.events.pk_n });
            return outcome.events.pk_n - target_;
        }
    };
    var low = 0.05 * length;
    var high = 0.95 * length;
    var at_low = try Impact.at(state, k, snapshot, drop_index, instance, low, &history, target);
    const at_high = try Impact.at(state, k, snapshot, drop_index, instance, high, &history, target);
    var chosen: f64 = undefined;
    if ((at_low > 0) == (at_high > 0)) {
        chosen = if (@abs(at_low) < @abs(at_high)) low else high;
    } else {
        for (0..8) |_| {
            const middle = 0.5 * (low + high);
            const at_middle = try Impact.at(state, k, snapshot, drop_index, instance, middle, &history, target);
            if ((at_middle > 0) == (at_low > 0)) {
                low = middle;
                at_low = at_middle;
            } else high = middle;
        }
        chosen = 0.5 * (low + high);
    }
    std.mem.sort([2]f64, history.items, {}, struct {
        fn less(_: void, left: [2]f64, right: [2]f64) bool {
            return left[0] < right[0];
        }
    }.less);
    const xs = try memory.alloc(f64, history.items.len);
    const ys = try memory.alloc(f64, history.items.len);
    for (history.items, xs, ys) |entry, *x, *y| {
        x.* = entry[0];
        y.* = entry[1];
    }
    try state.figures.curve("ls", .{ .name = "impacto da carga", .x = xs, .y = ys, .color = flightplots.payload_color, .marker = "o", .line = true, .size = 9 });
    try state.figures.guide("ls", .{ .name = "alvo", .value = target, .vertical = false, .color = "#000000", .dashed = true });
    try state.figures.curve("ls", .{ .name = "★ soltura escolhida", .x = try memory.dupe(f64, &.{chosen}), .y = try memory.dupe(f64, &.{interpolate(xs, ys, chosen)}), .color = "#ffcc00", .marker = "star" });
    state.events = try withDrop(memory, state.events, drop_index, k, chosen);
}

/// os eventos com a soltura na perna k, em s: no lugar da que havia (índice `drop_index`) ou no fim
fn withDrop(memory: std.mem.Allocator, events: []const model.MissionEvent, drop_index: usize, k: usize, position: f64) ![]model.MissionEvent {
    const count = if (drop_index < events.len) events.len else events.len + 1;
    const copy = try memory.alloc(model.MissionEvent, count);
    @memcpy(copy[0..events.len], events);
    copy[drop_index] = .{ .kind = "drop", .leg = @intCast(k), .s = position };
    return copy;
}

fn interpolate(xs: []const f64, ys: []const f64, at: f64) f64 {
    if (xs.len == 0) return std.math.nan(f64);
    if (at <= xs[0]) return ys[0];
    for (xs[1..], 1..) |x, k| if (x >= at) {
        const span = x - xs[k - 1];
        return if (span > 0) ys[k - 1] + (ys[k] - ys[k - 1]) * (at - xs[k - 1]) / span else ys[k];
    };
    return ys[ys.len - 1];
}

/// o ponto neutro de manche fixo na velocidade de cruzeiro: x_PN = c C_mα/C_Lα com os momentos em (0, 0, z_CG)
/// (`Probe.neutral_point`), em % da CMA a partir do bordo de ataque
fn neutralPercent(state: *RunState) f64 {
    const instance = state.calibrated;
    const params = &instance.p;
    var speed: f64 = 0;
    for (params.seg[0..@intCast(params.n_seg)]) |segment| if (segment.takeoff == 0 and segment.landing == 0) {
        speed = @max(speed, segment.V1);
    };
    if (speed <= 0) speed = 15;
    const now = core.trim.Ctx.init(params, &instance.r.f);
    const reference = core.vec.v3(.{ 0, 0, now.rcg[2] });
    const step = 0.5 * rad;
    const alpha = 2 * rad;
    const up = core.aero.coeffsEx(params, speed, alpha + step, 0, core.vec.v3(.{ 0, 0, 0 }), reference, core.vec.v3(.{ 0, 0, 0 }));
    const down = core.aero.coeffsEx(params, speed, alpha - step, 0, core.vec.v3(.{ 0, 0, 0 }), reference, core.vec.v3(.{ 0, 0, 0 }));
    const references = params_mod.references(&state.aircraft);
    const chord = references[1];
    const neutral = chord * (up.Cm - down.Cm) / (up.CL - down.CL);
    return 100 * (params_mod.macLeadingEdge(&state.aircraft) - neutral) / chord;
}

fn finishMission(state: *RunState) !void {
    const memory = state.memory;
    const aircraft = &state.aircraft;
    const rows = state.log.items;
    const events = if (state.status != null) state.flight.r.ev else types.Events{};
    const figures = state.figures;
    var target: ?[2]f64 = null;
    if (state.drop_leg != null) target = .{ aircraft.payload.target_n, aircraft.payload.target_e };
    var table: []analysis.StageRow = &.{};
    var battery: []flightplots.BatteryRow = &.{};
    if (rows.len > 0) {
        const flight = try flightplots.Flight.init(memory, rows, events, state.leg_names);
        try flightplots.trajectory(figures, flight, target);
        try flightplots.timeSeries(figures, flight, state.refs, aircraft.tanks.len);
        var north_low = std.math.inf(f64);
        var north_high = -std.math.inf(f64);
        var east_low = std.math.inf(f64);
        var east_high = -std.math.inf(f64);
        for (rows) |row| {
            north_low = @min(north_low, row.n);
            north_high = @max(north_high, row.n);
            east_low = @min(east_low, row.e);
            east_high = @max(east_high, row.e);
        }
        const extent = @max(@max(north_high - north_low, east_high - east_low), 10);
        try flightplots.aircraftGlyphs(figures, flight, glyph_step, @max(params_mod.references(aircraft)[2], extent / 35));
        var capacity: f64 = 0;
        for (aircraft.propulsion) |unit| if (unit.enabled) {
            capacity += unit.battery.capacity_mAh;
        };
        if (aircraft.shared_battery and aircraft.propulsion.len > 0) capacity = aircraft.propulsion[0].battery.capacity_mAh;
        battery = try flightplots.batteryByStage(figures, flight, capacity);
        try flightplots.cgSeries(figures, flight, params_mod.macLeadingEdge(aircraft), params_mod.references(aircraft)[1], neutralPercent(state));
        if (state.first == 0) {
            try flightplots.takeoffWindow(figures, flight, state.refs, tableEdge(aircraft));
            try flightplots.takeoffAngles(figures, flight, wingIncidence(aircraft), state.refs.alpha_stall_deg + wingIncidence(aircraft));
            if (state.best == null) { // a decolagem da configuração: julga pelo registro
                const verdict = takeoff_opt.judge(rows, events, state.x_warning, state.z_warning);
                try takeoffChecks(state, aircraft, .{ .position = aircraft.takeoff.sR, .deflection = aircraft.takeoff.de1, .takeoff_point = verdict.takeoff_point, .lowest = verdict.lowest, .x_excess = verdict.x_excess, .z_short = verdict.z_short, .ok = verdict.ok, .status = .completed, .events = events, .margin = 0 });
            }
        }
        try flightplots.landingWindow(figures, flight, state.refs, platformEdges(state));
        try flightplots.groundClearance(figures, flight);
        try flightplots.lapesWindow(figures, flight, if (target) |aim| aim[0] else null);
        table = try analysis.stageTable(memory, rows, events, state.leg_names, state.info.Vs);
    }
    const status_text = if (state.status) |status| runner.statusName(status) else "—";
    try missionChecks(state, events, table, state.status, state.stop_at == state.legs.len, target);
    const summary = &state.summary;
    const number = struct {
        fn of(memory_: std.mem.Allocator, value: f64) ![]const u8 {
            return std.fmt.allocPrint(memory_, "{d:.4}", .{value});
        }
    }.of;
    try summary.appendSlice(memory, &.{
        .{ "status", status_text },
        .{ "t_fim", try number(memory, events.tend) },
        .{ "energia_Wh", try number(memory, events.E) },
        .{ "n_saiu_do_chao", try number(memory, events.nLO) },
        .{ "n_toque", try number(memory, events.nTD) },
        .{ "n_parada", try number(memory, events.nStop) },
        .{ "impacto_carga_n", try number(memory, events.pk_n) },
        .{ "impacto_carga_e", try number(memory, events.pk_e) },
        .{ "CL_CLmax_max", try number(memory, events.ratio_mission) },
        .{ "I_pico", try number(memory, events.Ipeak) },
    });
    var saved: std.ArrayList(u8) = .empty;
    for (state.leg_names, 0..) |leg_name, k| if (checkpoints.get(k) != null) {
        if (saved.items.len > 0) try saved.appendSlice(memory, ", ");
        try saved.print(memory, "missão: início de {s}", .{leg_name});
    };
    try summary.append(memory, .{ "checkpoints", saved.items });
    if (state.best) |best| {
        try summary.append(memory, .{ "acionamento_profundor_m", try number(memory, best.position) });
        try summary.append(memory, .{ "deflexao_graus", try number(memory, best.deflection) });
        try summary.append(memory, .{ "n_dec", try number(memory, best.takeoff_point) });
    }
    if (battery.len > 0) {
        for (battery) |line| try summary.append(memory, .{ try printed(memory, "consumo — {s}", .{line.name}), try printed(memory, "{d:.1} s, {d:.1} A, {d:.1} mAh, SOC no fim {d:.0} %", .{ line.duration, line.current_mean, line.charge_mAh, line.soc_end_percent }) });
        const total = battery[battery.len - 1];
        const enough = total.soc_end_percent > 20;
        try state.checks.append(memory, .{
            .status = if (enough) .ok else .falha,
            .item = "bateria ao fim do trecho",
            .value = try printed(memory, "SOC = {d:.0} % ({d:.0} mAh)", .{ total.soc_end_percent, total.charge_mAh }),
            .criterion = "> 20 % (Peukert)",
            .why = if (enough) "" else "a missão gasta quase toda a bateria",
            .fix = if (enough) "" else "bateria maior, menos tempo de voo ou menos corrente",
            .group = "Bateria",
        });
    }
    for (state.radii.items) |entry| try summary.append(memory, .{ try printed(memory, "raio automático — {s}", .{entry[0]}), try number(memory, entry[1]) });
    if (state.notes.items.len > 0) try summary.append(memory, .{ "observação", try std.mem.join(memory, "; ", state.notes.items) });
}

/// o começo e o fim (em n) da plataforma de pouso, quando o pouso é nela
fn platformEdges(state: *RunState) ?[2]f64 {
    if (!std.mem.eql(u8, state.aircraft.airfield.landing_on, "plataforma")) return null;
    const params = &state.flight.p;
    if (params.n_pad == 0) return null;
    const pad = params.pads[@intCast(params.n_pad - 1)];
    const end = pad.n0 + pad.L * @cos(pad.chi);
    return .{ @min(pad.n0, end), @max(pad.n0, end) };
}

fn missionChecks(state: *RunState, events: types.Events, table: []const analysis.StageRow, status: ?core.runner.Status, full: bool, target: ?[2]f64) !void {
    const memory = state.memory;
    const aircraft = &state.aircraft;
    const checks = &state.checks;
    const lift_limit = aircraft.autopilot.kCL;
    if (status == .crashed and events.tprop >= 0) {
        var diameter: f64 = 0;
        for (aircraft.propulsion) |unit| if (unit.enabled) {
            diameter = @max(diameter, unit.propeller.D);
        };
        try checks.append(memory, .{ .status = .falha, .item = "a hélice tocou o chão", .value = try printed(memory, "t = {d:.2} s, folga {d:.1} cm", .{ events.tprop, events.hpmin * 100 }), .criterion = "folga da ponta da pá > 0", .why = try printed(memory, "a ponta da pá (hélice de {d:.0}\") encostou no terreno", .{diameter / 0.0254}), .fix = "suba o motor, alongue o trem ou use uma hélice menor; veja a folga da pá no gráfico", .group = "Voo" });
    } else if (status == .crashed) {
        try checks.append(memory, .{ .status = .falha, .item = "a aeronave caiu ou divergiu", .value = try printed(memory, "t = {d:.1} s", .{events.tend}), .criterion = "terminar o voo", .why = "a simulação parou abaixo do terreno, capotada ou com estado não finito", .fix = "veja a etapa em que o voo terminou nos gráficos (fundo colorido) e o C_L/C_Lmax dela", .group = "Voo" });
    }
    for (table) |line| {
        if (line.lift_ratio_max > lift_limit) try checks.append(memory, .{ .status = .falha, .item = try printed(memory, "margem de estol — {s}", .{line.name}), .value = try printed(memory, "C_L/C_Lmax = {d:.2}", .{line.lift_ratio_max}), .criterion = try printed(memory, "≤ {d:.2}", .{lift_limit}), .why = "a meia asa mais carregada passou do limite de sustentação nessa etapa", .fix = "aumente a velocidade da etapa, o raio da curva ou a área de asa", .group = "Etapas" });
        const ground = std.mem.eql(u8, line.name, "corrida no chão") or std.mem.eql(u8, line.name, "rolagem");
        if (!ground and line.speed_min_stall < 1.1) try checks.append(memory, .{ .status = .atencao, .item = try printed(memory, "velocidade mínima — {s}", .{line.name}), .value = try printed(memory, "V/V_s = {d:.2}", .{line.speed_min_stall}), .criterion = "≥ 1,1", .why = "a velocidade chegou perto da de estol", .fix = "peça mais velocidade nessa perna", .group = "Etapas" });
    }
    const field = aircraft.airfield;
    if (full and std.mem.eql(u8, field.landing_on, "plataforma") and events.tTD > 0) {
        const on_top = field.platform_height - events.hgnd_td <= 1e-6;
        try checks.append(memory, .{ .status = if (on_top) .ok else .falha, .item = "pouso em cima da plataforma", .value = try printed(memory, "terreno no toque: {d:.2} m", .{events.hgnd_td}), .criterion = try printed(memory, "= {d} m", .{field.platform_height}), .why = if (on_top) "" else "tocou fora da plataforma", .fix = if (on_top) "" else "mude o início/comprimento da plataforma ou a folga do pouso", .group = "Pouso" });
    }
    if (target) |aim| if (events.pk_t > 0) {
        const miss = std.math.hypot(events.pk_n - aim[0], events.pk_e - aim[1]);
        try checks.append(memory, .{ .status = if (miss <= 5) .ok else .atencao, .item = "carga LAPES no alvo", .value = try printed(memory, "erro = {d:.1} m", .{miss}), .criterion = "≤ 5 m", .why = "distância entre o impacto da carga e o alvo configurado", .fix = "ligue 'procurar onde soltar' ou ajuste o evento de soltura", .group = "LAPES" });
    };
    if (full and events.tTD > 0 and events.completed != 0 and field.landing_max > 0) {
        const distance = events.nStop - events.nTD;
        try checks.append(memory, .{ .status = if (distance <= field.landing_max) .ok else .falha, .item = "distância de pouso (toque até parar)", .value = try printed(memory, "{d:.1} m", .{distance}), .criterion = try printed(memory, "≤ {d} m", .{field.landing_max}), .why = "rolagem depois do toque", .fix = "aproxime mais devagar ou aumente o atrito de frenagem", .group = "Pouso" });
    }
    try checks.append(memory, .{ .status = .info, .item = "energia gasta", .value = try printed(memory, "{d:.2} Wh", .{events.E}), .criterion = "—", .group = "Voo" });
}

// ------------------------------------------------------------------ curvas

fn advanceTurns(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    const memory = state.memory;
    if (state.turn_index >= state.speeds.len) {
        try finishTurns(state);
        run.progress = 1;
        return true;
    }
    const speed = state.speeds[state.turn_index];
    run.say("V = {d} m/s: raios", .{speed});
    run.progress = @floatCast(@as(f64, @floatFromInt(state.turn_index)) / @as(f64, @floatFromInt(state.speeds.len)));
    const height = 30.0;
    const angle = 240.0;
    var radii: std.ArrayList(f64) = .empty;
    for (turn_banks) |bank| {
        const radius = @round(autoRadius(speed, bank) * 10) / 10;
        for (radii.items) |known| {
            if (known == radius) break;
        } else try radii.append(memory, radius);
    }
    std.mem.sort(f64, radii.items, {}, std.sort.asc(f64));
    // a curva nivelada: uma reta para estabilizar, a curva e uma reta de saída (`level_turn`)
    const turnPlane = struct {
        fn of(memory_: std.mem.Allocator, base: *const Aircraft, speed_: f64, radius: f64) !Aircraft {
            var plane = base.*;
            plane.mission = .{ .name = "curva", .legs = try memory_.dupe(Leg, &.{
                .{ .kind = "straight", .length = 150, .h = height, .V = speed_, .name = "estabiliza" },
                .{ .kind = "turn", .radius = radius, .angle = angle, .side = 1, .h = height, .V = speed_, .name = "curva" },
                .{ .kind = "straight", .length = 300, .h = height, .V = speed_, .name = "saída" },
            }), .h0 = height, .V0 = speed_ };
            plane.sim.tmax = 1e6;
            return plane;
        }
    }.of;
    var autopilot = state.calibrated.p.ap;
    autopilot.phimax = 75 * rad;
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    const first_plane = try turnPlane(memory, &state.aircraft, speed, radii.items[radii.items.len - 1]);
    try configureFlight(&first_plane, instance, autopilot, state.loading);
    try core.runner.resetAir(instance, 0);
    _ = try runner.fly(instance, .{ .segment = 1 }, memory, null);
    const snapshot = try memory.create(Snapshot);
    snapshot.* = instance.r;
    for (radii.items) |radius| {
        const plane = try turnPlane(memory, &state.aircraft, speed, radius);
        instance.* = .{};
        try configureFlight(&plane, instance, autopilot, state.loading);
        instance.r = snapshot.*;
        var rows: std.ArrayList(types.LogRow) = .empty;
        _ = try runner.fly(instance, .{ .segment = 2, .time = snapshot.t + 30 + 3 * radius * angle * rad / speed }, memory, &rows);
        var turn = try analysis.evaluateTurn(memory, rows.items, instance.p.seg[1], 1, radius, state.info.Vs, state.aircraft.autopilot.kCL, 75);
        if (turn.height_loss > 3 and turn.ok) {
            turn.ok = false;
            turn.verdict = .loses_height;
        }
        try state.turns.append(memory, .{ .speed = speed, .turn = turn, .rows = rows.items });
    }
    state.turn_index += 1;
    return false;
}

fn finishTurns(state: *RunState) !void {
    const memory = state.memory;
    const figures = state.figures;
    const styles = [_]struct { []const u8, []const u8 }{ .{ "#2ca02c", "o" }, .{ "#d62728", "s" }, .{ "#9467bd", "t" }, .{ "#1f77b4", "d" }, .{ "#ff7f0e", "o" } };
    const load_limit = state.aircraft.performance.load_factor;
    var minimum_speeds: std.ArrayList(f64) = .empty;
    var minimum_radii: std.ArrayList(f64) = .empty;
    var minimum_loads: std.ArrayList(f64) = .empty;
    for (state.speeds, 0..) |speed, index| {
        var cases: std.ArrayList(TurnCase) = .empty;
        for (state.turns.items) |item| if (item.speed == speed) try cases.append(memory, item);
        const style = styles[index % styles.len];
        const turns = try memory.alloc(analysis.Turn, cases.items.len);
        for (cases.items, turns) |item, *turn| turn.* = item.turn;
        const smallest = try analysis.minRadius(memory, turns);
        if (index == state.speeds.len / 2) for (cases.items, 0..) |item, i| {
            if (item.rows.len == 0) continue;
            const color = flightplots.stageColor(1 + (i % 9));
            const label = try printed(memory, "R = {d} m — {s}", .{ item.turn.radius, item.turn.verdict.text() });
            try figures.curve("cv", .{ .name = try printed(memory, "V = {d} m/s, {s}", .{ speed, label }), .x = try flightplots.column(memory, item.rows, "e"), .y = try flightplots.column(memory, item.rows, "n"), .color = color, .width = if (item.turn.ok) 1.8 else 1.0, .dashed = !item.turn.ok });
            // n_z e o n em que a asa estola na V do momento (n_z/ratioCL), na perna da curva
            var times: std.ArrayList(f64) = .empty;
            var loads: std.ArrayList(f64) = .empty;
            var stall_loads: std.ArrayList(f64) = .empty;
            for (item.rows) |row| if (row.seg == 1) {
                try times.append(memory, row.t);
                try loads.append(memory, row.nz);
                try stall_loads.append(memory, if (row.ratioCL > 0.05) row.nz / @max(row.ratioCL, 1e-9) else std.math.nan(f64));
            };
            if (times.items.len > 5) {
                const start = times.items[0];
                for (times.items) |*time| time.* -= start;
                try figures.curve("ct", .{ .name = label, .x = times.items, .y = loads.items, .color = color, .width = 1.6 });
                try figures.curve("ct", .{ .name = try printed(memory, "{s} (estol)", .{label}), .x = times.items, .y = stall_loads.items, .color = color, .dashed = true, .width = 1, .legend = false });
            }
        };
        const radii = try memory.alloc(f64, turns.len);
        const stall_load = try memory.alloc(f64, turns.len);
        for (turns, radii, stall_load) |turn, *radius, *load| {
            radius.* = turn.radius;
            load.* = turn.stall_load_steady;
        }
        try figures.curve("cn", .{ .name = try printed(memory, "V = {d} m/s — n no estol", .{speed}), .x = radii, .y = stall_load, .color = style[0], .dashed = true, .width = 1.2 });
        const metrics = [_]struct { []const u8, enum { lift, bank, load, height } }{ .{ "cr", .lift }, .{ "cp", .bank }, .{ "cn", .load }, .{ "ch", .height } };
        for (metrics) |metric| {
            const values = try memory.alloc(f64, turns.len);
            var pass_x: std.ArrayList(f64) = .empty;
            var pass_y: std.ArrayList(f64) = .empty;
            var fail_x: std.ArrayList(f64) = .empty;
            var fail_y: std.ArrayList(f64) = .empty;
            for (turns, values) |turn, *item| {
                item.* = switch (metric[1]) {
                    .lift => turn.lift_ratio_max,
                    .bank => @min(turn.bank_steady_deg, 89),
                    .load => turn.load_steady,
                    .height => turn.height_loss,
                };
                if (turn.ok) {
                    try pass_x.append(memory, turn.radius);
                    try pass_y.append(memory, item.*);
                } else {
                    try fail_x.append(memory, turn.radius);
                    try fail_y.append(memory, item.*);
                }
            }
            try figures.curve(metric[0], .{ .name = try printed(memory, "V = {d} m/s — passa", .{speed}), .x = pass_x.items, .y = pass_y.items, .color = style[0], .marker = style[1], .size = 10 });
            try figures.curve(metric[0], .{ .name = try printed(memory, "V = {d} m/s — falha", .{speed}), .x = fail_x.items, .y = fail_y.items, .color = style[0], .marker = "x", .size = 12 });
            try figures.curve(metric[0], .{ .name = try printed(memory, "V = {d} m/s", .{speed}), .x = radii, .y = values, .color = style[0], .width = 0.8, .legend = false });
        }
        var load_at_minimum = std.math.nan(f64);
        for (turns) |turn| if (turn.ok and turn.radius == smallest) {
            load_at_minimum = turn.load_steady;
            break;
        };
        try minimum_speeds.append(memory, speed);
        try minimum_radii.append(memory, smallest);
        try minimum_loads.append(memory, load_at_minimum);
        if (std.math.isFinite(load_at_minimum)) {
            const within = load_at_minimum <= load_limit;
            try state.checks.append(memory, .{ .status = if (within) .ok else .atencao, .item = try printed(memory, "fator de carga no raio mínimo a {d} m/s", .{speed}), .value = try printed(memory, "n = {d:.2}", .{load_at_minimum}), .criterion = try printed(memory, "≤ {d} (n de projeto)", .{load_limit}), .why = if (within) "" else "a curva mais fechada passa do fator de carga de projeto da estrutura", .fix = if (within) "" else "abra a curva ou suba o n de projeto (Montagem → desempenho)", .group = "Curvas" });
        }
        // o raio que falha logo abaixo do mínimo diz por quê
        var reason: []const u8 = "";
        var reason_radius = -std.math.inf(f64);
        for (turns) |turn| if (!turn.ok and (!std.math.isFinite(smallest) or turn.radius < smallest) and turn.radius > reason_radius) {
            reason_radius = turn.radius;
            reason = turn.verdict.text();
        };
        const found = std.math.isFinite(smallest);
        try state.checks.append(memory, .{ .status = if (found) .info else .falha, .item = try printed(memory, "raio mínimo a {d} m/s", .{speed}), .value = if (found) try printed(memory, "{d:.1} m", .{smallest}) else "nenhum raio passa", .criterion = "menor R que passa", .why = if (reason.len > 0) try printed(memory, "o raio menor seguinte falha por: {s}", .{reason}) else "", .fix = if (reason.len > 0) "mais velocidade, mais área de asa ou mais tração" else "", .group = "Curvas" });
    }
    try figures.guide("cr", .{ .name = "limite C_L/C_Lmax", .value = state.aircraft.autopilot.kCL, .vertical = false, .color = "#d62728", .dashed = true });
    try figures.guide("ch", .{ .name = "limite", .value = 3, .vertical = false, .color = "#d62728", .dashed = true });
    const design = try printed(memory, "n de projeto = {d}", .{load_limit});
    try figures.guide("cn", .{ .name = design, .value = load_limit, .vertical = false, .color = "#d62728", .dashed = true });
    try figures.guide("ct", .{ .name = design, .value = load_limit, .vertical = false, .color = "#d62728", .dashed = true });
    try figures.curve("rmin", .{ .name = "R mínimo simulado", .x = minimum_speeds.items, .y = minimum_radii.items, .color = "#1f77b4", .marker = "o", .line = true });
    var best: ?usize = null;
    for (minimum_radii.items, 0..) |radius, k| if (std.math.isFinite(radius) and (best == null or radius < minimum_radii.items[best.?])) {
        best = k;
    };
    if (best) |k| try figures.curve("rmin", .{ .name = "★ menor raio", .x = minimum_speeds.items[k .. k + 1], .y = minimum_radii.items[k .. k + 1], .color = "#ffcc00", .marker = "star" });
    for (minimum_speeds.items, minimum_radii.items) |speed, radius| try state.summary.append(memory, .{ try printed(memory, "R_min @ {d} m/s", .{speed}), try printed(memory, "{d:.4}", .{radius}) });
    for (minimum_speeds.items, minimum_loads.items) |speed, load| try state.summary.append(memory, .{ try printed(memory, "n no R_min @ {d} m/s", .{speed}), try printed(memory, "{d:.4}", .{load}) });
    try state.summary.append(memory, .{ "Vs", try printed(memory, "{d:.4}", .{state.info.Vs}) });
}

// ------------------------------------------------------------------ MTOW

/// o máximo de simulações (decolagens e missões) da busca do MTOW: ao bater nele a busca para com o que achou
const simulation_limit = 10_000;

/// a decolagem numa massa (fração t entre o mínimo e o máximo), com o melhor xCG da tabela. `refine` falso é a
/// busca rápida da bisseção: o xCG que decolou por último vem primeiro e a primeira decolagem que passa basta
fn mtowCase(state: *RunState, fraction: f64, refine: bool) !MtowCase {
    const total = mass_table.total[0] + fraction * (mass_table.total[2] - mass_table.total[0]);
    var order: std.ArrayList(f64) = .empty;
    const first = if (refine) null else state.good_center;
    if (first) |center| try order.append(state.memory, center);
    for (state.center_options) |center| if (first == null or center != first.?) try order.append(state.memory, center);
    var chosen: ?MtowCase = null;
    for (order.items) |center| {
        const loading: Loading = .{ .mass = total, .center_x = center };
        const outcome = try searchTakeoff(state, &state.aircraft, loading, refine);
        state.simulations += outcome.tried.len;
        const better = if (chosen) |known| rank(outcome.best) > rank(known.best) else true;
        if (better) chosen = .{ .fraction = fraction, .mass = total, .best = outcome.best, .center_x = center, .tried = outcome.tried };
        // a busca rápida: passou, basta; e com um xCG que já decolou numa massa menor, ele decide sozinho (uma massa
        // maior não decola com um xCG que a menor nem precisou)
        if (!refine and (outcome.best.ok or first != null)) break;
        if (state.simulations >= simulation_limit) break;
    }
    if (chosen.?.best.ok) state.good_center = chosen.?.center_x;
    return chosen.?;
}

/// guarda o caso na lista (os gráficos) e devolve o índice
fn keepCase(state: *RunState, case: MtowCase) !usize {
    try state.cases.append(state.memory, case);
    return state.cases.items.len - 1;
}

/// voa a missão inteira na massa e no xCG do caso, com o acionamento do profundor achado: completa quando pousa e
/// para, sem bater no chão nem estourar o tempo. As curvas de raio automático usam o raio do φ máx. do piloto
fn missionCompletes(state: *RunState, case: MtowCase) !bool {
    const memory = state.memory;
    var plane = state.aircraft;
    if (takeoff_opt.pitchControl(&plane) != null and std.math.isFinite(case.best.position)) {
        plane.takeoff.sR = case.best.position;
        plane.takeoff.de1 = case.best.deflection;
        if (std.math.isFinite(case.best.hold)) plane.takeoff.de0 = case.best.hold;
    }
    const loading: Loading = .{ .mass = case.mass, .center_x = case.center_x };
    const instance = try memory.create(core.runner.Instance);
    instance.* = .{};
    try configureFlight(&plane, instance, state.calibrated.p.ap, loading);
    const legs = try memory.dupe(Leg, plane.mission.legs);
    var automatic = false;
    for (legs, 0..) |*leg, k| if (std.mem.eql(u8, leg.kind, "turn") and leg.radius <= 0) {
        const segment = instance.p.seg[k];
        leg.radius = @round(autoRadius(@max(segment.V0, segment.V1), plane.autopilot.phimax) * 10) / 10;
        automatic = true;
    };
    if (automatic) {
        plane.mission.legs = legs;
        instance.* = .{};
        try configureFlight(&plane, instance, state.calibrated.p.ap, loading);
    }
    try core.runner.resetGround(instance);
    const flown = try runner.fly(instance, .{}, memory, null);
    state.simulations += 1;
    return flown.status == .completed;
}

/// a rodada bateu no limite de simulações: avisa e termina com o que achou
fn stopAtLimit(state: *RunState) !void {
    const bisection = &state.bisection;
    try state.checks.append(state.memory, .{ .status = .atencao, .item = "limite de simulações da busca do MTOW", .value = try printed(state.memory, "{d} simulações", .{state.simulations}), .criterion = try printed(state.memory, "≤ {d}", .{simulation_limit}), .why = "a busca não fechou dentro do limite: possivelmente não existe massa que decola e completa a missão com estes x_warning e z_warning", .fix = "confira a pista, a tração e a missão; o MTOW mostrado é o melhor achado até o limite", .group = "MTOW" });
    bisection.mtow_fraction = null;
    if (bisection.best) |k| if (state.cases.items[k].best.ok) {
        bisection.mtow_fraction = state.cases.items[k].fraction;
    };
    bisection.stage = .done;
}

/// a ordem das decolagens: passa antes de não passar, depois a folga (ou o quanto faltou)
fn rank(result: takeoff_opt.Result) f64 {
    return if (result.ok) 1e6 + result.margin else -(result.x_excess + result.z_short);
}

/// passa no critério da fase: decola e, na segunda fase, completa a missão também
fn passes(state: *RunState, case: MtowCase) !bool {
    if (!case.best.ok) return false;
    if (!state.with_mission) return true;
    return missionCompletes(state, case);
}

/// a busca do MTOW: (1) bisseção só com a decolagem (rápida: o primeiro acionamento que passa); (2) na massa achada,
/// o profundor otimizado e a missão inteira; (3) se a missão não completa, a bisseção de novo, de baixo até essa
/// massa, com "decola e completa a missão" como critério. Tudo até `simulation_limit` simulações
fn advanceMtow(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    const bisection = &state.bisection;
    const same = mass_table.total[0] == mass_table.total[2];
    if (bisection.stage != .done and state.simulations >= simulation_limit) try stopAtLimit(state);
    const phase_name = if (state.with_mission) "decolagem e missão" else "só a decolagem";
    switch (bisection.stage) {
        .low => {
            run.say("MTOW ({s}): a menor massa", .{phase_name});
            const case = try mtowCase(state, 0, false);
            const ok = try passes(state, case);
            const k = try keepCase(state, case);
            bisection.best = k;
            if (!ok) {
                bisection.mtow_fraction = null;
                if (state.with_mission) try state.checks.append(state.memory, .{ .status = .falha, .item = "a missão não completa nem com a menor massa", .value = try printed(state.memory, "{d:.2} kg", .{case.mass}), .criterion = "pousar e parar", .fix = "veja a missão desta massa no modo Missão", .group = "MTOW" });
                bisection.stage = .done;
            } else if (same) {
                bisection.mtow_fraction = 0;
                bisection.stage = .refine;
            } else bisection.stage = if (state.with_mission) .bisect else .high; // a de cima já não completou
            return false;
        },
        .high => {
            run.say("MTOW ({s}): a maior massa", .{phase_name});
            const case = try mtowCase(state, 1, false);
            const ok = try passes(state, case);
            const k = try keepCase(state, case);
            if (ok) {
                bisection.best = k;
                bisection.mtow_fraction = 1;
                try state.checks.append(state.memory, .{ .status = .atencao, .item = "MTOW acima da tabela", .value = "decola com tudo no máximo", .criterion = "dentro", .fix = "aumente os máximos", .group = "MTOW" });
                bisection.stage = .refine;
            } else bisection.stage = .bisect;
            return false;
        },
        .bisect => {
            if (bisection.step >= 9) {
                bisection.mtow_fraction = bisection.low;
                bisection.stage = .refine;
                return false;
            }
            bisection.step += 1;
            run.say("MTOW ({s}): bisseção {d}/9", .{ phase_name, bisection.step });
            const share: f64 = if (state.with_mission) 0.5 else 0.9; // a segunda fase fica com a metade de cima
            const offset: f64 = if (state.with_mission) 0.5 else 0;
            run.progress = @floatCast(offset + share * @as(f64, @floatFromInt(bisection.step)) / 9);
            const middle = 0.5 * (bisection.low + bisection.high);
            const case = try mtowCase(state, middle, false);
            const ok = try passes(state, case);
            const k = try keepCase(state, case);
            if (ok) {
                bisection.low = middle;
                bisection.best = k;
            } else bisection.high = middle;
            return false;
        },
        .refine => {
            // o profundor otimizado na massa achada (a mesma conta do modo Decolagem); a busca rápida só garantiu
            // que alguma decolagem passa
            run.say("MTOW: otimizando o profundor na massa achada", .{});
            const fraction = bisection.mtow_fraction.?;
            const refined = try mtowCase(state, fraction, true);
            const k = bisection.best.?;
            const quick = state.cases.items[k];
            if (refined.best.ok) state.cases.items[k] = refined;
            if (!state.with_mission) {
                bisection.stage = .mission;
                return false;
            }
            // o refinado decola de outro jeito: se ele não completa a missão, fica o da bisseção, que completou
            if (refined.best.ok and !try missionCompletes(state, refined)) state.cases.items[k] = quick;
            try state.checks.append(state.memory, .{ .status = .ok, .item = "missão inteira no MTOW", .value = try printed(state.memory, "{d:.2} kg", .{state.cases.items[k].mass}), .criterion = "pousar e parar", .group = "MTOW" });
            bisection.stage = .done;
            return false;
        },
        .mission => {
            const case = state.cases.items[bisection.best.?];
            run.say("MTOW: a missão inteira com {d:.2} kg", .{case.mass});
            if (try missionCompletes(state, case)) {
                try state.checks.append(state.memory, .{ .status = .ok, .item = "missão inteira no MTOW", .value = try printed(state.memory, "{d:.2} kg", .{case.mass}), .criterion = "pousar e parar", .group = "MTOW" });
                bisection.stage = .done;
                return false;
            }
            // a missão não completa na massa só de decolagem: volta à bisseção, de baixo até ela, com a missão junto
            try state.notes.append(state.memory, try printed(state.memory, "com {d:.2} kg decola mas não completa a missão: a busca voltou com a missão no critério", .{case.mass}));
            state.with_mission = true;
            bisection.* = .{ .high = bisection.mtow_fraction.? };
            return false;
        },
        .done => {
            try finishMtow(run, state);
            try state.summary.append(state.memory, .{ "simulações da busca", try printed(state.memory, "{d}", .{state.simulations}) });
            run.progress = 1;
            return true;
        },
    }
}

// ------------------------------------------------------------------ estudo e ponto de projeto

/// os valores da variável (de, até, quantos) e o avião do primeiro
fn startStudy(run: *simulation.Run, state: *RunState, values: simulation.Values) !void {
    const memory = state.memory;
    const study = &state.study;
    study.variable = StudyVariable.named(values.text("study_variable", study_labels[0]));
    study.base = state.aircraft;
    const now = study.variable.current(&state.aircraft);
    const from = values.number("study_from", now - 4);
    const to = values.number("study_to", now + 4);
    const count: usize = @intFromFloat(@max(2, @min(21, @round(values.number("study_steps", 5)))));
    const list = try memory.alloc(f64, count);
    for (list, 0..) |*value, i| value.* = from + (to - from) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count - 1));
    study.values = list;
    try useStudyValue(run, state);
}

/// o avião do valor de agora, calibrado de novo, e a busca do MTOW do começo
fn useStudyValue(run: *simulation.Run, state: *RunState) !void {
    const study = &state.study;
    state.aircraft = try study.variable.applied(state.memory, study.base, study.values[study.index]);
    var diagnosis: model.Diag = .{};
    state.calibrated.* = .{};
    state.info = calibrateWith(&state.aircraft, state.calibrated, .{}, &diagnosis) catch |err| {
        run.fail("com {s} = {d}, o avião não montou no núcleo: {s} ({s})", .{ study.variable.label(), study.values[study.index], diagnosis.text(), @errorName(err) });
        return err;
    };
    state.cases.clearRetainingCapacity();
    state.bisection = .{};
    state.with_mission = false;
    state.good_center = null;
    state.simulations = 0;
}

/// um passo da busca do MTOW do valor de agora; ao fim dela, guarda o MTOW e passa ao próximo valor
fn advanceStudy(run: *simulation.Run, state: *RunState) simulation.Error!bool {
    const study = &state.study;
    if (study.index >= study.values.len) {
        try finishStudy(state);
        run.progress = 1;
        return true;
    }
    if (state.bisection.stage != .done) {
        _ = try advanceMtow(run, state);
        const total: f64 = @floatFromInt(study.values.len);
        run.progress = @floatCast((@as(f64, @floatFromInt(study.index)) + @as(f64, @floatFromInt(state.bisection.step)) / 10) / total);
        var step_text: [160]u8 = undefined;
        const step = std.mem.sliceTo(&run.message, 0);
        @memcpy(step_text[0..step.len], step);
        run.say("estudo: {s} = {d:.2} ({d}/{d}), {s}", .{ study.variable.label(), study.values[study.index], study.index + 1, study.values.len, step_text[0..step.len] });
        return false;
    }
    const decolou = state.bisection.mtow_fraction != null;
    const best = state.cases.items[state.bisection.best.?];
    try study.mtow.append(state.memory, if (decolou) best.mass else std.math.nan(f64));
    try study.run_length.append(state.memory, if (decolou) best.best.takeoff_point else std.math.nan(f64));
    study.index += 1;
    if (study.index < study.values.len) try useStudyValue(run, state);
    return false;
}

/// os gráficos do estudo e o ponto de projeto (o maior MTOW)
fn finishStudy(state: *RunState) !void {
    const memory = state.memory;
    const study = &state.study;
    const figures = state.figures;
    const label = study.variable.label();
    var best: ?usize = null;
    for (study.mtow.items, 0..) |mtow, i| {
        if (!std.math.isFinite(mtow)) continue;
        if (best == null or mtow > study.mtow.items[best.?]) best = i;
    }
    try figures.curve("sm", .{ .name = "MTOW", .x = study.values, .y = study.mtow.items, .color = "#2ca02c", .marker = "o", .size = 9, .line = true });
    try figures.curve("sd", .{ .name = "n_dec no MTOW", .x = study.values, .y = study.run_length.items, .color = "#1f77b4", .marker = "o", .size = 9, .line = true });
    try figures.guide("sd", .{ .name = try printed(memory, "x_warning = {d} m", .{state.x_warning}), .value = state.x_warning, .vertical = false, .color = "#d62728", .width = 2 });
    for (study.values, study.mtow.items) |value, mtow| try state.summary.append(memory, .{ try printed(memory, "MTOW (kg), {s} = {d:.2}", .{ label, value }), if (std.math.isFinite(mtow)) try printed(memory, "{d:.4}", .{mtow}) else "não decola" });
    const chosen = best orelse {
        try state.checks.append(memory, .{ .status = .falha, .item = "nenhum valor decola", .value = label, .criterion = try printed(memory, "x ≤ {d} m, z = {d} m", .{ state.x_warning, state.z_warning }), .fix = "abra a faixa, baixe os mínimos da tabela de massas ou aumente a pista", .group = "Estudo" });
        return;
    };
    const value = study.values[chosen];
    const mtow = study.mtow.items[chosen];
    try figures.curve("sm", .{ .name = "★ ponto de projeto", .x = try memory.dupe(f64, &.{value}), .y = try memory.dupe(f64, &.{mtow}), .color = "#ffcc00", .marker = "star", .size = 24 });
    try state.summary.append(memory, .{ "ponto de projeto", try printed(memory, "{s} = {d:.2}, MTOW = {d:.3} kg", .{ label, value, mtow }) });
    const edge = chosen == 0 or chosen + 1 == study.values.len;
    try state.checks.append(memory, .{
        .status = if (edge) .atencao else .info,
        .item = "ponto de projeto",
        .value = try printed(memory, "{s} = {d:.2}", .{ label, value }),
        .criterion = try printed(memory, "maior MTOW: {d:.2} kg", .{mtow}),
        .why = if (edge) "o melhor está na ponta da faixa: o máximo pode estar fora dela" else "",
        .fix = if (edge) "abra a faixa para esse lado" else "leve o valor para o avião (Montagem ou Motores e montagem)",
        .group = "Estudo",
    });
}

fn finishMtow(run: *simulation.Run, state: *RunState) !void {
    const memory = state.memory;
    const figures = state.figures;
    const leading = params_mod.macLeadingEdge(&state.aircraft);
    const chord = params_mod.references(&state.aircraft)[1];
    const percent = struct {
        fn of(leading_: f64, chord_: f64, x: f64) f64 {
            return 100 * (leading_ - x) / chord_;
        }
    }.of;
    const cases = try memory.dupe(MtowCase, state.cases.items);
    std.mem.sort(MtowCase, cases, {}, struct {
        fn less(_: void, left: MtowCase, right: MtowCase) bool {
            return left.mass < right.mass;
        }
    }.less);
    var pass_mass: std.ArrayList(f64) = .empty;
    var pass_point: std.ArrayList(f64) = .empty;
    var fail_mass: std.ArrayList(f64) = .empty;
    var fail_point: std.ArrayList(f64) = .empty;
    var all_mass: std.ArrayList(f64) = .empty;
    var positions: std.ArrayList(f64) = .empty;
    var deflections: std.ArrayList(f64) = .empty;
    var centers: std.ArrayList(f64) = .empty;
    for (cases) |item| {
        try all_mass.append(memory, item.mass);
        if (item.best.ok) {
            try pass_mass.append(memory, item.mass);
            try pass_point.append(memory, item.best.takeoff_point);
            try positions.append(memory, item.best.position);
            try deflections.append(memory, item.best.deflection);
            try centers.append(memory, percent(leading, chord, item.center_x));
        } else {
            try fail_mass.append(memory, item.mass);
            try fail_point.append(memory, if (std.math.isFinite(item.best.takeoff_point)) item.best.takeoff_point else std.math.nan(f64));
        }
    }
    try figures.curve("mt", .{ .name = "decola", .x = pass_mass.items, .y = pass_point.items, .color = "#2ca02c", .marker = "o", .size = 10 });
    try figures.curve("mt", .{ .name = "não decola", .x = fail_mass.items, .y = fail_point.items, .color = "#d62728", .marker = "x", .size = 12 });
    try figures.guide("mt", .{ .name = try printed(memory, "x_warning = {d} m", .{state.x_warning}), .value = state.x_warning, .vertical = false, .color = "#d62728", .width = 3 });
    try figures.curve("mc", .{ .name = "Massa total (kg)", .x = all_mass.items, .y = all_mass.items, .color = "#ff7f0e", .marker = "o", .line = true });
    try figures.curve("ma", .{ .name = "acionamento (m)", .x = pass_mass.items, .y = positions.items, .color = "#2ca02c", .marker = "o", .line = true });
    try figures.curve("ma", .{ .name = "δe (°)", .x = pass_mass.items, .y = deflections.items, .color = "#1f77b4", .marker = "s", .line = true });
    try figures.curve("ma", .{ .name = "xCG (% CMA)", .x = pass_mass.items, .y = centers.items, .color = "#9467bd", .marker = "d", .line = true });
    try state.summary.appendSlice(memory, &.{
        .{ "massa_atual", try printed(memory, "{d:.4}", .{state.info.mass}) },
        .{ "x_warning", try printed(memory, "{d}", .{state.x_warning}) },
        .{ "z_warning", try printed(memory, "{d}", .{state.z_warning}) },
    });
    const best = state.cases.items[state.bisection.best.?];
    if (state.bisection.mtow_fraction == null) {
        if (state.with_mission) return; // o motivo (a missão não completa) já está no diagnóstico
        try state.checks.append(memory, .{ .status = .falha, .item = "não decola nem com tudo no mínimo", .value = "x_warning ou z_warning", .criterion = try printed(memory, "x ≤ {d} m, z = {d} m", .{ state.x_warning, state.z_warning }), .fix = "baixe os mínimos, aumente a tração, a área de asa ou a pista", .group = "MTOW" });
        return;
    }
    const mtow = best.mass;
    const center_percent = percent(leading, chord, best.center_x);
    saveMtow(.{ .source = fingerprint(run.aircraft), .x_warning = state.x_warning, .z_warning = state.z_warning, .loading = .{ .mass = mtow, .center_x = best.center_x }, .mass = mtow });
    try state.summary.appendSlice(memory, &.{
        .{ "MTOW (kg)", try printed(memory, "{d:.4}", .{mtow}) },
        .{ "MTOW: Massa total (kg)", try printed(memory, "{d:.4}", .{mtow}) },
        .{ "MTOW: xCG (m)", try printed(memory, "{d:.4}", .{best.center_x}) },
        .{ "MTOW: xCG (% CMA)", try printed(memory, "{d:.4}", .{center_percent}) },
        .{ "acionamento (m)", try printed(memory, "{d:.4}", .{best.best.position}) },
        .{ "δe (°)", try printed(memory, "{d}", .{best.best.deflection}) },
        .{ "n_dec (m)", try printed(memory, "{d:.4}", .{best.best.takeoff_point}) },
    });
    const mtow_label = try printed(memory, "MTOW = {d:.2} kg", .{mtow});
    for ([_][]const u8{ "mt", "mc", "ma" }) |key| try figures.guide(key, .{ .name = mtow_label, .value = mtow, .vertical = true, .color = "#ffcc00", .width = 3 });
    try figures.curve("mt", .{ .name = "★ MTOW", .x = try memory.dupe(f64, &.{mtow}), .y = try memory.dupe(f64, &.{best.best.takeoff_point}), .color = "#ffcc00", .marker = "star", .size = 24 });
    try state.checks.append(memory, .{ .status = .info, .item = "MTOW", .value = try printed(memory, "{d:.2} kg", .{mtow}), .criterion = "x e z atendidos", .why = try printed(memory, "Massa total (kg) = {d:.2}; xCG = {d:.1} % CMA ({d:.3} m); acionamento em {d:.1} m, δe = {d}°", .{ mtow, center_percent, best.center_x, best.best.position, best.best.deflection }), .fix = "salvo: na missão, na decolagem e nas curvas, Massa → 'MTOW salvo desta pista'", .group = "MTOW" });
    try optimizationSeries(state, best.tried, best.best);
    const loading: Loading = .{ .mass = mtow, .center_x = best.center_x };
    const flown = try loggedTakeoff(state, &state.aircraft, loading, best.best);
    if (flown.rows.len > 0) try takeoffSeries(state, flown.rows, flown.result.events);
    try takeoffChecks(state, &state.aircraft, best.best);
}

// ------------------------------------------------------------------ o resultado

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    _ = run;
    try simulation.beginResult(out, state.summary.items, state.checks.items);
    try state.figures.write(out, true);
    try simulation.endResult(out);
}

const testing = std.testing;

test "Missão: só decolagem e a missão inteira no Convencional_original" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Mission);
    {
        var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
        defer run.arena.deinit();
        try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"mode\": \"só decolagem\"}"));
        while (!try registered.advance(&run)) {}
        const state: *RunState = @ptrCast(@alignCast(run.state.?));
        // o mesmo acionamento que a busca do Python acha (`takeoff_opt.optimize`, grade)
        try testing.expectApproxEqAbs(@as(f64, 33.58612463677029), state.best.?.position, 1e-6);
        var written: std.Io.Writer.Allocating = .init(gpa);
        defer written.deinit();
        try registered.result(&run, &written.writer);
        const outcome = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
        defer outcome.deinit();
        try testing.expect(outcome.value.object.get("plots").?.array.items.len > 10);
    }
    {
        var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
        defer run.arena.deinit();
        try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"mode\": \"missão\"}"));
        while (!try registered.advance(&run)) {}
        const state: *RunState = @ptrCast(@alignCast(run.state.?));
        try testing.expect(state.log.items.len > 100);
        // os números da Missão do Python no mesmo avião (`SimulationManager.run("mission", ...)`): o fim do voo e
        // o impacto da carga LAPES depois da busca do ponto de soltura
        const events = state.flight.r.ev;
        try testing.expectApproxEqAbs(@as(f64, 163.88), events.tend, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, -0.33374210025409823), events.pk_n, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 16.424624153425704), events.nStop, 1e-6);
        var written: std.Io.Writer.Allocating = .init(gpa);
        defer written.deinit();
        try registered.result(&run, &written.writer);
        const outcome = try std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
        defer outcome.deinit();
        try testing.expect(outcome.value.object.get("summary").?.object.get("status") != null);
    }
}

/// roda um modo da Missão no avião e devolve o resumo (`summary`) do JSON do resultado
fn summaryOf(gpa: std.mem.Allocator, aircraft: *const Aircraft, request: []const u8) !std.json.Parsed(std.json.Value) {
    const registered = simulation.register(Mission);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = aircraft };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), request));
    while (!try registered.advance(&run)) {}
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try registered.result(&run, &written.writer);
    return std.json.parseFromSlice(std.json.Value, gpa, written.written(), .{});
}

fn summaryNumber(parsed: std.json.Parsed(std.json.Value), key: []const u8) !f64 {
    const value = parsed.value.object.get("summary").?.object.get(key) orelse return error.TestUnexpectedResult;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .string => |text| try std.fmt.parseFloat(f64, text),
        else => error.TestUnexpectedResult,
    };
}

test "Missão: raio mínimo de curva igual ao do Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const parsed = try summaryOf(gpa, &loaded.ac, "\"values\": {\"mode\": \"curvas: raio mínimo\"}");
    defer parsed.deinit();
    // `SimulationManager.run("mission", ac, {"mode": "curvas: raio mínimo"})` no Convencional_original
    try testing.expectApproxEqAbs(@as(f64, 53.0), try summaryNumber(parsed, "R_min @ 13 m/s"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 39.7), try summaryNumber(parsed, "R_min @ 15 m/s"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 29.5), try summaryNumber(parsed, "R_min @ 17 m/s"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0749520553674288), try summaryNumber(parsed, "n no R_min @ 13 m/s"), 1e-3); // o resumo sai com 4 casas
}

test "Missão: MTOW igual ao do Python (lento: -Dlento -Dfiltro=MTOW)" {
    if (!@import("test_options").slow) return error.SkipZigTest;
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const parsed = try summaryOf(gpa, &loaded.ac, "\"values\": {\"mode\": \"MTOW (x_warning e z_warning)\"}");
    defer parsed.deinit();
    try testing.expectApproxEqAbs(@as(f64, 13.4446875), try summaryNumber(parsed, "MTOW (kg)"), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 59.7988483968584), try summaryNumber(parsed, "n_dec (m)"), 1e-4);
}

test "Missão: o estudo no valor de agora dá o MTOW do modo MTOW (lento: -Dlento -Dfiltro=estudo)" {
    if (!@import("test_options").slow) return error.SkipZigTest;
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const tilt = StudyVariable.tilt.current(&loaded.ac);
    var request: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&request, "\"values\": {{\"mode\": \"{s}\", \"study_from\": {d}, \"study_to\": {d}, \"study_steps\": 2}}", .{ Mode.study.label(), tilt, tilt + 4 });
    const parsed = try summaryOf(gpa, &loaded.ac, text);
    defer parsed.deinit();
    var key: [128]u8 = undefined;
    // o mesmo avião do modo MTOW: o mesmo MTOW (13,4446875 kg, o do teste do MTOW)
    try testing.expectApproxEqAbs(@as(f64, 13.4446875), try summaryNumber(parsed, try std.fmt.bufPrint(&key, "MTOW (kg), {s} = {d:.2}", .{ StudyVariable.tilt.label(), tilt })), 1e-3);
}

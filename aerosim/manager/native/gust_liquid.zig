//! Estabilidade → Estabilidade dinâmica: o avião em voo nivelado recebe uma rajada (vertical, lateral ou as duas) e a aba
//! mostra no tempo o ângulo de ataque, a derrapagem, o rolamento, o xCG e o ângulo do líquido de cada tanque. Com
//! tanques, voa duas vezes, com o líquido livre e travado, para ver o quanto o líquido muda a resposta.
//!
//! Os tanques ficam numa tabela da aba (onde estão, o tamanho, o volume e a massa de cada um) e a LAPES num grupo do
//! formulário (a massa, onde está e se ela sai no meio do voo). Os dois começam como o arquivo do avião diz, a aba
//! guarda o que se mudou até abrir outro avião, e a vista 3D mostra o avião com eles e o CG. Sem tanques ou sem LAPES,
//! a análise roda sem essa parte.
//!
//! Antes do voo saem os polos no equilíbrio (com o líquido livre, travado e sem a LAPES), para ver qual modo explica
//! o que o voo mostra: uma espiral instável, por exemplo, é o rolamento que cresce devagar no manche fixo.
//!
//! A conta é a do núcleo (`core/src/sim/gust.zig`, a dinâmica 6GDL com o pêndulo de Abramson nos tanques); aqui só se
//! monta o caso, se avança em fatias e se escreve o resultado.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const native = @import("native.zig");

const params_mod = aircraft_model.params;
const deg = 180.0 / std.math.pi;

pub const simulation = native.Simulation{
    .name = "estabilidade_dinamica",
    .title = "Estabilidade dinâmica",
    .area = "Estabilidade",
    .description = "O avião em voo nivelado recebe uma rajada 1 − cos (vertical, lateral ou as duas) e a resposta sai no " ++
        "tempo: ângulo de ataque, derrapagem, rolamento, o xCG e o ângulo do líquido de cada tanque. Com tanques, voa " ++
        "com o líquido livre e travado, para comparar. Tudo em Zig, no núcleo.",
    .specs = specs,
    .edit = edit,
    .start = start,
    .advance = advance,
    .result = result,
};

const pilots = [_][]const u8{ "manche fixo", "piloto automático" };
const max_cases = 2;
const slice_seconds = 0.25; // de voo por fatia (poucos milissegundos de conta)

const plots = [_]native.Plot{
    .{ .key = "alpha", .title = "Ângulo de ataque", .xlabel = "t (s)", .ylabel = "α (°)" },
    .{ .key = "lateral", .title = "Derrapagem e rolamento", .xlabel = "t (s)", .ylabel = "°" },
    .{ .key = "load", .title = "Fator de carga", .xlabel = "t (s)", .ylabel = "n_z" },
    .{ .key = "xcg", .title = "xCG", .xlabel = "t (s)", .ylabel = "x_CG (% CMA)" },
    .{ .key = "liquid", .title = "Líquido", .xlabel = "t (s)", .ylabel = "ângulo (°)" },
    .{ .key = "poles_plain", .title = "Polos", .xlabel = "Re (1/s)", .ylabel = "Im (rad/s)" },
    .{ .key = "poles_sloshing", .title = "Polos com sloshing", .xlabel = "Re (1/s)", .ylabel = "Im (rad/s)" },
    .{ .key = "poles_lapes", .title = "Polos com a LAPES", .xlabel = "Re (1/s)", .ylabel = "Im (rad/s)" },
    .{ .key = "poles_all", .title = "Todos os polos", .xlabel = "Re (1/s)", .ylabel = "Im (rad/s)" },
};
const plot_alpha = 0;
const plot_lateral = 1;
const plot_load = 2;
const plot_cg = 3;
const plot_liquid = 4;
const plot_poles = 5; // os três dos efeitos (`Effect`) e o de todos, nesta ordem

/// os polos ao longo do voo, cada um num modelo: sem efeitos (o corpo rígido, com o líquido travado e a LAPES a bordo),
/// com o líquido balançando (sloshing) e com a saída da LAPES
const Effect = enum { plain, sloshing, lapes };
const effect_color = std.EnumArray(Effect, []const u8).init(.{ .plain = "#7f7f7f", .sloshing = "#1f77b4", .lapes = "#ff7f0e" });
const effect_name = std.EnumArray(Effect, []const u8).init(.{ .plain = "sem efeitos", .sloshing = "sloshing", .lapes = "LAPES" });
const max_samples = 24; // instantes do voo em que se refazem os polos
const Mode = core.gust.Mode;
const mode_marker = std.EnumArray(Mode, []const u8).init(.{ .short_period = "o", .phugoid = "s", .dutch_roll = "d", .roll = "t", .spiral = "+", .liquid = "x" });
const mode_name = std.EnumArray(Mode, []const u8).init(.{ .short_period = "curto período", .phugoid = "fugóide", .dutch_roll = "dutch roll", .roll = "rolamento", .spiral = "espiral", .liquid = "líquido" });

fn cruise(aircraft: *const native.Aircraft) f64 {
    var speed: f64 = 0;
    for (aircraft.mission.legs) |leg| if (leg.V) |value| {
        speed = @max(speed, value);
    };
    return if (speed > 0) speed else aircraft.mission.V0;
}

// ------------------------------------------------------------------ os tanques e a LAPES da aba

const Tank = aircraft_model.aircraft.Tank;
const Payload = aircraft_model.aircraft.Payload;
const max_tanks = core.limits.max_tanks;
const name_size = 40;

/// os tanques da tabela: começam como os do arquivo e guardam o que se editou, até abrir outro avião (ou o mesmo
/// mudado na Montagem). Memória fixa, sem alocação: no máximo `max_tanks`, como o núcleo
const Layout = struct {
    source: u64 = 0, // a impressão do avião de onde os tanques vieram (`fingerprint`)
    ready: bool = false,
    count: usize = 0,
    tanks: [max_tanks]Tank = undefined,
    names: [max_tanks][name_size]u8 = undefined,
    name_lengths: [max_tanks]usize = undefined,

    fn slice(layout: *const Layout) []const Tank {
        return layout.tanks[0..layout.count];
    }

    /// os tanques do arquivo
    fn reset(layout: *Layout, aircraft: *const native.Aircraft) void {
        layout.count = @min(aircraft.tanks.len, max_tanks);
        for (aircraft.tanks[0..layout.count], 0..) |tank, i| {
            layout.tanks[i] = tank;
            layout.tanks[i].shape = staticShape(tank.shape); // o texto do arquivo some quando o avião lido é solto
            layout.rename(i, tank.name);
        }
        layout.source = fingerprint(aircraft);
        layout.ready = true;
    }

    /// volta aos do arquivo se o avião não é mais o mesmo
    fn sync(layout: *Layout, aircraft: *const native.Aircraft) void {
        if (!layout.ready or layout.source != fingerprint(aircraft)) layout.reset(aircraft);
    }

    fn rename(layout: *Layout, i: usize, name: []const u8) void {
        const length = @min(name.len, name_size);
        @memcpy(layout.names[i][0..length], name[0..length]);
        layout.name_lengths[i] = length;
        layout.tanks[i].name = layout.names[i][0..length];
    }

    /// um tanque novo logo abaixo de `after` (cópia dele) ou no fim
    fn add(layout: *Layout, after: ?usize) void {
        if (layout.count >= max_tanks) return;
        const at = if (after) |row| @min(row + 1, layout.count) else layout.count;
        var k = layout.count;
        while (k > at) : (k -= 1) layout.move(k - 1, k);
        layout.tanks[at] = if (after != null and at > 0) layout.tanks[at - 1] else .{};
        layout.count += 1;
        var name: [name_size]u8 = undefined;
        layout.rename(at, std.fmt.bufPrint(&name, "tanque {d}", .{layout.count}) catch "tanque");
    }

    fn delete(layout: *Layout, row: usize) void {
        if (row >= tanks_table.count) return;
        for (row + 1..layout.count) |k| layout.move(k, k - 1);
        layout.count -= 1;
    }

    fn move(layout: *Layout, from: usize, to: usize) void {
        layout.tanks[to] = layout.tanks[from];
        layout.names[to] = layout.names[from];
        layout.name_lengths[to] = layout.name_lengths[from];
        layout.tanks[to].name = layout.names[to][0..layout.name_lengths[to]];
    }
};

var tanks_table: Layout = .{};

/// o que identifica os tanques de um avião: o nome dele e cada número dos tanques
fn fingerprint(aircraft: *const native.Aircraft) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(aircraft.name);
    for (aircraft.tanks) |tank| {
        hasher.update(tank.name);
        hasher.update(tank.shape);
        for ([_]f64{ tank.x, tank.y, tank.z, tank.side, tank.volume, tank.height, tank.rho, tank.zeta }) |value| hasher.update(std.mem.asBytes(&value));
    }
    return hasher.final();
}

const shapes = [_][]const u8{ "quadrado", "cilindro" };

/// o formato num texto que não depende da memória do avião lido
fn staticShape(shape: []const u8) []const u8 {
    return if (std.mem.eql(u8, shape, "square")) "square" else "cylinder";
}

fn shapeLabel(tank: Tank) []const u8 {
    return if (std.mem.eql(u8, tank.shape, "square")) shapes[0] else shapes[1];
}

fn liquidMass(tank: Tank) f64 {
    return tank.rho * tank.volume / 1000.0;
}

const tank_columns = [_]native.Column{
    .{ .key = "name", .label = "nome", .kind = .text },
    .{ .key = "x", .label = "x (m)", .help = "a partir da referência do avião, para a frente" },
    .{ .key = "y", .label = "y (m)", .help = "para a direita" },
    .{ .key = "z", .label = "z (m)", .help = "para baixo" },
    .{ .key = "side", .label = "lado (m)", .help = "o lado da base quadrada ou o diâmetro do cilindro" },
    .{ .key = "height", .label = "altura (m)" },
    .{ .key = "volume", .label = "volume (L)" },
    .{ .key = "shape", .label = "formato", .kind = .choice, .choices = &shapes },
    .{ .key = "mass", .label = "massa (kg)", .kind = .label, .help = "a do líquido: densidade × volume" },
};

/// muda a tabela dos tanques
fn edit(aircraft: ?*const native.Aircraft, change: native.GridEdit) anyerror!void {
    if (aircraft) |plane| tanks_table.sync(plane);
    if (!std.mem.eql(u8, change.grid, "tanks")) return;
    const operation = std.meta.stringToEnum(enum { set, add, delete, reset }, change.operation) orelse return;
    switch (operation) {
        .add => tanks_table.add(change.row),
        .delete => if (change.row) |row| tanks_table.delete(row),
        .reset => if (aircraft) |plane| tanks_table.reset(plane) else {
            tanks_table.count = 0;
        },
        .set => {
            const row = change.row orelse return;
            if (row >= tanks_table.count) return;
            const tank = &tanks_table.tanks[row];
            if (std.mem.eql(u8, change.key, "name")) return tanks_table.rename(row, change.text());
            if (std.mem.eql(u8, change.key, "shape")) {
                tank.shape = if (std.mem.eql(u8, change.text(), shapes[0])) "square" else "cylinder";
                return;
            }
            const value = change.number() orelse return;
            const field = std.meta.stringToEnum(enum { x, y, z, side, height, volume }, change.key) orelse return;
            switch (field) {
                .x => tank.x = value,
                .y => tank.y = value,
                .z => tank.z = value,
                .side => tank.side = @max(value, 0.005),
                .height => tank.height = @max(value, 0.005),
                .volume => tank.volume = @max(value, 0),
            }
        },
    }
}

/// a LAPES do formulário (começa como a do arquivo)
fn payloadFrom(aircraft: *const native.Aircraft, values: native.Values) Payload {
    var payload = aircraft.payload;
    payload.enabled = values.toggle("lapes", aircraft.payload.enabled);
    payload.mass = @max(values.number("lapes_mass", aircraft.payload.mass), 0);
    payload.x = values.number("lapes_x", aircraft.payload.x);
    payload.y = values.number("lapes_y", aircraft.payload.y);
    payload.z = values.number("lapes_z", aircraft.payload.z);
    if (payload.mass <= 0) payload.enabled = false;
    return payload;
}

/// o avião da aba: o do arquivo com os tanques da tabela e a LAPES do formulário
fn configured(aircraft: *const native.Aircraft, values: native.Values) native.Aircraft {
    tanks_table.sync(aircraft);
    var plane = aircraft.*;
    plane.tanks = tanks_table.slice();
    plane.payload = payloadFrom(aircraft, values);
    return plane;
}

/// a massa pedida para o avião sem o líquido e a LAPES: o que passa da do arquivo entra no CG dele (seco)
fn withMass(instance: *core.runner.Instance, wanted: f64) void {
    if (wanted > instance.p.m_dry) instance.p.m_dry = wanted;
}

/// a massa e o CG do avião da aba, como o núcleo monta
const Balance = struct { mass: f64, center: [3]f64 };

fn balance(plane: *const native.Aircraft, values: native.Values) ?Balance {
    const instance = std.heap.page_allocator.create(core.runner.Instance) catch return null;
    defer std.heap.page_allocator.destroy(instance);
    instance.* = .{};
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    _ = params_mod.setup(plane, instance, &diagnosis) catch return null;
    withMass(instance, values.number("mass", 0));
    const now = core.trim.Ctx.init(&instance.p, &instance.r.f);
    return .{ .mass = now.m, .center = now.rcg };
}

/// a tabela dos tanques, com a massa de cada um e a soma na nota
fn tankGrid(memory: std.mem.Allocator, plane: *const native.Aircraft, mass: ?Balance) !native.Grid {
    const rows = try memory.alloc([]const native.Cell, plane.tanks.len);
    var liquid: f64 = 0;
    for (plane.tanks, 0..) |tank, i| {
        const cells = try memory.alloc(native.Cell, tank_columns.len);
        cells[0] = .{ .text = tank.name };
        cells[1] = .{ .number = tank.x };
        cells[2] = .{ .number = tank.y };
        cells[3] = .{ .number = tank.z };
        cells[4] = .{ .number = tank.side };
        cells[5] = .{ .number = tank.height };
        cells[6] = .{ .number = tank.volume };
        cells[7] = .{ .text = shapeLabel(tank) };
        cells[8] = .{ .text = try std.fmt.allocPrint(memory, "{d:.3}", .{liquidMass(tank)}) };
        liquid += liquidMass(tank);
        rows[i] = cells;
    }
    const lapes: f64 = if (plane.payload.enabled) plane.payload.mass else 0;
    const note = if (mass) |known|
        try std.fmt.allocPrint(memory, "Líquido: {d:.3} kg em {d} tanques. LAPES: {d:.3} kg. Avião: {d:.3} kg. Total: {d:.3} kg. " ++
            "As mudanças valem nesta aba; o arquivo do avião não muda.", .{ liquid, plane.tanks.len, lapes, known.mass - liquid - lapes, known.mass })
    else
        try std.fmt.allocPrint(memory, "Líquido: {d:.3} kg em {d} tanques. As mudanças valem nesta aba; o arquivo do avião não muda.", .{ liquid, plane.tanks.len });
    return .{
        .name = "tanks",
        .title = "Tanques de líquido",
        .help = "cada tanque vira um pêndulo equivalente (Abramson, NASA SP-106); sem tanques, a análise roda sem líquido",
        .note = note,
        .columns = &tank_columns,
        .rows = rows,
        .buttons = &.{
            .{ .operation = "add", .label = "+ tanque", .help = "copia o selecionado logo abaixo dele" },
            .{ .operation = "delete", .label = "− tanque", .help = "apaga o selecionado" },
            .{ .operation = "reset", .label = "como no avião", .help = "volta aos tanques do arquivo" },
        },
    };
}

/// a vista 3D: as peças do avião (`skeleton`, as mesmas da Montagem), com os tanques e a LAPES da aba, e o CG
fn view(memory: std.mem.Allocator, plane: *const native.Aircraft, mass: ?Balance) !?native.View {
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const built = aircraft_model.skeleton.build(memory, plane, &diagnosis) catch return null; // na arena da resposta
    var meshes: std.ArrayList(native.Mesh) = .empty;
    // as opacas primeiro e as transparentes (tanque, disco da hélice) por cima
    for ([_]bool{ false, true }) |translucent| for (built.pieces) |piece| {
        if ((aircraft_model.skeleton.rgba(piece.color)[3] < 1) != translucent) continue;
        try meshes.append(memory, .{ .kind = @tagName(piece.color), .vertices = piece.mesh.v, .faces = piece.mesh.f });
    };
    return .{ .meshes = meshes.items, .cg = if (mass) |known| known.center else null };
}

fn specs(out: *native.Writer, aircraft: ?*const native.Aircraft, values: native.Values) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const speed = if (aircraft) |plane| cruise(plane) else 15.0;
    const dry = if (aircraft) |plane| @round(params_mod.dryMass(plane).m * 1000.0) / 1000.0 else 0.0;
    const file_payload: Payload = if (aircraft) |plane| plane.payload else .{};
    var extras: native.Extras = .{};
    var has_tanks = true;
    if (aircraft) |source| {
        const plane = configured(source, values);
        has_tanks = plane.tanks.len > 0;
        const mass = balance(&plane, values);
        const grids = try memory.alloc(native.Grid, 1);
        grids[0] = try tankGrid(memory, &plane, mass);
        extras = .{ .grids = grids, .view = try view(memory, &plane, mass) };
    }
    const params = [_]native.Param{
        .{ .key = "mass", .label = "massa do avião", .default = .{ .number = dry }, .minimum = 0, .unit = "kg", .group = "Massa", .rebuild = true, .help = "sem o líquido e a LAPES; o que passa da do arquivo entra no CG do avião" },
        .{ .key = "lapes", .label = "LAPES no avião", .kind = .bool, .default = .{ .toggle = file_payload.enabled }, .group = "LAPES", .rebuild = true, .help = "a carga que sai pela rampa; desligada, a análise roda sem ela" },
        .{ .key = "lapes_mass", .label = "massa da LAPES", .default = .{ .number = file_payload.mass }, .minimum = 0, .unit = "kg", .group = "LAPES", .rebuild = true },
        .{ .key = "lapes_x", .label = "x da LAPES", .default = .{ .number = file_payload.x }, .unit = "m", .group = "LAPES", .rebuild = true, .help = "o centro da carga, para a frente" },
        .{ .key = "lapes_y", .label = "y da LAPES", .default = .{ .number = file_payload.y }, .unit = "m", .group = "LAPES", .rebuild = true },
        .{ .key = "lapes_z", .label = "z da LAPES", .default = .{ .number = file_payload.z }, .unit = "m", .group = "LAPES", .rebuild = true, .help = "para baixo" },
        .{ .key = "drop", .label = "soltar no voo", .kind = .bool, .default = .{ .toggle = false }, .group = "LAPES", .help = "a LAPES sai pela rampa no instante pedido e o voo segue sem ela" },
        .{ .key = "drop_t", .label = "soltar em", .default = .{ .number = 4 }, .minimum = 0, .maximum = 120, .unit = "s", .group = "LAPES" },
        .{ .key = "V", .label = "velocidade", .default = .{ .number = speed }, .minimum = 3, .maximum = 80, .unit = "m/s", .group = "Voo" },
        .{ .key = "h", .label = "altura", .default = .{ .number = 50 }, .minimum = 5, .maximum = 3000, .unit = "m", .group = "Voo" },
        .{ .key = "pilot", .label = "comandos", .kind = .choice, .default = .{ .text = pilots[0] }, .choices = &pilots, .group = "Voo", .help = "manche fixo: os comandos ficam no equilíbrio (a resposta do avião); piloto automático: ele reage" },
        .{ .key = "up", .label = "rajada vertical", .default = .{ .number = 2 }, .minimum = -20, .maximum = 20, .unit = "m/s", .group = "Rajada", .help = "para cima é positivo" },
        .{ .key = "side", .label = "rajada lateral", .default = .{ .number = 0 }, .minimum = -20, .maximum = 20, .unit = "m/s", .group = "Rajada", .help = "positivo empurra para a direita" },
        .{ .key = "Tg", .label = "duração", .default = .{ .number = 1 }, .minimum = 0.05, .maximum = 20, .unit = "s", .group = "Rajada", .help = "a rajada 1 − cos sobe e desce neste tempo" },
        .{ .key = "tg", .label = "chega em", .default = .{ .number = 1 }, .minimum = 0, .maximum = 60, .unit = "s", .group = "Rajada" },
        .{ .key = "span", .label = "tempo máximo", .default = .{ .number = 30 }, .minimum = 1, .maximum = 120, .unit = "s", .group = "Rajada", .help = "o voo para antes, quando a resposta estabiliza" },
        .{ .key = "compare", .label = "comparar com o líquido travado", .kind = .bool, .default = .{ .toggle = has_tanks }, .group = "Líquido", .help = "voa de novo com o líquido parado nos tanques (mesma massa)" },
    };
    try native.writeSpecs(out, &params, &plots, simulation.description, extras);
}

/// um voo: o caso, a instância do núcleo e o registro
const Flight = struct {
    case: core.gust.Case,
    instance: *core.runner.Instance,
    log: []core.types.LogRow,
    rows: usize = 0,
    started: bool = false,
    done: bool = false,
};

const State = struct {
    flights: [max_cases]Flight = undefined,
    count: usize = 0,
    current: usize = 0,
    mass: f64 = 0,
    alpha_trim: f64 = 0,
    mac: f64 = 0.3,
    mac_le: f64 = 0, // x do bordo de ataque da CMA (o 0 % da CMA)
    n_tanks: usize = 0,
    tank_names: [max_tanks][]const u8 = undefined,
    lapes: f64 = 0, // kg da LAPES no avião (0: sem)
    // os polos ao longo do voo livre, em `max_samples` instantes, para cada efeito (`Effect`); o primeiro é o
    // equilíbrio do começo
    loci: [std.meta.fields(Effect).len][max_samples]core.gust.Poles = undefined,
    samples: usize = 0,
};

/// os efeitos que valem neste voo: sem efeitos sempre; o sloshing com tanques; a LAPES se ela sai no voo
fn effects(state: *const State, free: *const Flight) std.EnumArray(Effect, bool) {
    return .init(.{ .plain = true, .sloshing = state.n_tanks > 0, .lapes = state.lapes > 0 and free.case.release != null and free.instance.r.f.released != 0 });
}

fn start(run: *native.Run, values: native.Values) anyerror!void {
    const memory = run.memory();
    const state = try memory.create(State);
    state.* = .{};
    run.state = state;
    const autopilot = std.mem.eql(u8, values.text("pilot", pilots[0]), pilots[1]);
    var base = core.gust.Case{
        .airspeed = values.number("V", cruise(run.aircraft)),
        .height = values.number("h", 50),
        .vertical = values.number("up", 2),
        .lateral = values.number("side", 0),
        .duration = values.number("Tg", 1),
        .start = values.number("tg", 1),
        .span = values.number("span", 30),
        .autopilot = autopilot,
    };
    const plane = try memory.create(native.Aircraft);
    plane.* = configured(run.aircraft, values);
    plane.tanks = try memory.dupe(Tank, plane.tanks); // a tabela pode mudar depois; a rodada fica com os de agora
    const aircraft = plane;
    state.n_tanks = aircraft.tanks.len;
    for (aircraft.tanks, 0..) |tank, i| state.tank_names[i] = try memory.dupe(u8, tank.name);
    state.lapes = if (aircraft.payload.enabled) aircraft.payload.mass else 0;
    if (state.lapes > 0 and values.toggle("drop", false)) base.release = values.number("drop_t", 4);
    state.mac = params_mod.references(aircraft)[1];
    state.mac_le = params_mod.macLeadingEdge(aircraft);
    const compare = values.toggle("compare", true) and state.n_tanks > 0;
    state.count = if (compare) 2 else 1;
    for (state.flights[0..state.count], 0..) |*flight, k| {
        var case = base;
        case.liquid_free = k == 0;
        const instance = try memory.create(core.runner.Instance);
        instance.* = .{};
        var diagnosis: aircraft_model.aircraft.Diag = .{};
        _ = params_mod.setup(aircraft, instance, &diagnosis) catch |err| {
            run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
            return err;
        };
        withMass(instance, values.number("mass", 0));
        state.mass = core.trim.Ctx.init(&instance.p, &instance.r.f).m;
        const rows = @as(usize, @intFromFloat(@ceil(case.span / instance.p.dtlog))) + 16;
        flight.* = .{ .case = case, .instance = instance, .log = try memory.alloc(core.types.LogRow, rows) };
    }
}

fn advance(run: *native.Run) anyerror!bool {
    const state: *State = @ptrCast(@alignCast(run.state.?));
    if (state.current >= state.count) return samplePoles(run, state);
    const flight = &state.flights[state.current];
    if (!flight.started) {
        flight.started = true;
        core.gust.begin(flight.instance, flight.case) catch |err| {
            run.fail("o voo não começou ({s}): a velocidade dá para voar nivelado?", .{@errorName(err)});
            return err;
        };
    }
    flight.done = try core.gust.advance(flight.instance, flight.case, flight.log, &flight.rows, slice_seconds);
    const label: []const u8 = if (flight.case.liquid_free) "líquido livre" else "líquido travado";
    const fraction = @min(flight.instance.r.t / flight.case.span, 1.0);
    run.progress = @floatCast((@as(f64, @floatFromInt(state.current)) + fraction) / @as(f64, @floatFromInt(state.count)));
    run.say("{s}: t = {d:.1} s de {d:.0}", .{ label, flight.instance.r.t, flight.case.span });
    if (flight.done) state.current += 1;
    return false; // os polos vêm depois dos voos
}

/// um instante do voo livre por fatia: os polos de cada efeito na velocidade daquele instante e com o que está a
/// bordo (a LAPES sai no instante em que saiu no voo); verdadeiro depois do último
fn samplePoles(run: *native.Run, state: *State) bool {
    if (state.samples >= max_samples) return true;
    const free = &state.flights[0];
    const instance = free.instance;
    const last = free.log[free.rows - 1].t;
    const moment = last * @as(f64, @floatFromInt(state.samples)) / @as(f64, max_samples - 1);
    var row = free.log[0];
    for (free.log[0..free.rows]) |line| {
        if (line.t > moment) break;
        row = line;
    }
    const airspeed = if (row.Va > 1) row.Va else free.case.airspeed;
    const active = effects(state, free);
    var aboard = instance.r.f;
    aboard.released = 0;
    aboard.extracting = 0;
    var after = aboard;
    after.released = @intFromBool(instance.r.f.released != 0 and moment >= instance.r.ev.trel);
    const k = state.samples;
    state.loci[@intFromEnum(Effect.plain)][k] = core.gust.poles(&instance.p, &aboard, airspeed, false);
    if (active.get(.sloshing)) state.loci[@intFromEnum(Effect.sloshing)][k] = core.gust.poles(&instance.p, &aboard, airspeed, true);
    if (active.get(.lapes)) state.loci[@intFromEnum(Effect.lapes)][k] = core.gust.poles(&instance.p, &after, airspeed, false);
    state.samples += 1;
    run.progress = 1;
    run.say("polos em t = {d:.1} s", .{moment});
    return state.samples >= max_samples;
}

/// uma coluna do registro de um voo, já na unidade do gráfico
fn column(memory: std.mem.Allocator, flight: *const Flight, comptime pick: fn (row: core.types.LogRow, first: core.types.LogRow) f64) ![]f64 {
    const values = try memory.alloc(f64, flight.rows);
    for (flight.log[0..flight.rows], 0..) |row, k| values[k] = pick(row, flight.log[0]);
    return values;
}

fn time(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.t;
}
fn alpha(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.alpha * deg;
}
fn beta(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.beta * deg;
}
fn bank(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.phi * deg;
}
fn load(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.nz;
}
/// o xCG em % da CMA a partir do bordo de ataque (como no resto da Estabilidade)
fn cgPercent(memory: std.mem.Allocator, flight: *const Flight, state: *const State) ![]f64 {
    const values = try memory.alloc(f64, flight.rows);
    for (flight.log[0..flight.rows], 0..) |row, k| values[k] = 100.0 * (state.mac_le - row.xcg) / state.mac;
    return values;
}

fn largest(values: []const f64, reference: f64) f64 {
    var peak: f64 = 0;
    for (values) |value| peak = @max(peak, @abs(value - reference));
    return peak;
}

fn result(run: *native.Run, out: *native.Writer) anyerror!void {
    const memory = run.memory();
    const state: *State = @ptrCast(@alignCast(run.state.?));
    const free = &state.flights[0];
    if (free.rows < 2) return error.NoRows;
    const t_free = try column(memory, free, time);
    const alpha_free = try column(memory, free, alpha);
    const cg_free = try cgPercent(memory, free, state);
    const alpha_trim = alpha_free[0];

    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(native.Check) = .empty;
    try summary.append(memory, .{ "massa (kg)", try std.fmt.allocPrint(memory, "{d:.3}", .{state.mass}) });
    try summary.append(memory, .{ "α de equilíbrio (°)", try std.fmt.allocPrint(memory, "{d:.2}", .{alpha_trim}) });

    const alpha_peak = largest(alpha_free, alpha_trim);
    const kinematic = std.math.atan(@abs(free.case.vertical) / free.case.airspeed) * deg;
    try checks.append(memory, .{ .status = .info, .item = "pico de Δα", .value = try std.fmt.allocPrint(memory, "{d:.2}°", .{alpha_peak}), .criterion = try std.fmt.allocPrint(memory, "atan(U/V) = {d:.2}°", .{kinematic}), .why = "a rajada vertical muda o ângulo de ataque; o avião arfa junto e o pico fica abaixo de atan(U/V)", .group = "rajada" });
    const back = @abs(alpha_free[alpha_free.len - 1] - alpha_trim);
    try checks.append(memory, .{
        .status = if (back < 0.5) .ok else .atencao,
        .item = "α volta ao equilíbrio",
        .value = try std.fmt.allocPrint(memory, "{d:.2}° no fim", .{back}),
        .criterion = "< 0,5°",
        .why = if (back < 0.5) "o curto período amortece a perturbação" else "o avião ainda oscila no fim: aumente o tempo de voo ou veja os modos na aba Avião montado",
        .group = "rajada",
    });
    // o quanto o líquido leva o CG: até a LAPES começar a sair (a rampa e a saída dela mexem muito mais)
    var before_drop = cg_free.len;
    if (free.case.release) |moment| for (free.log[0..free.rows], 0..) |row, k| if (row.t >= moment) {
        before_drop = @max(k, 1);
        break;
    };
    const cg_swing = largest(cg_free[0..before_drop], cg_free[0]);
    if (state.n_tanks > 0) {
        try checks.append(memory, .{ .status = .info, .item = "xCG", .value = try std.fmt.allocPrint(memory, "{d:.2} % CMA, anda até {d:.3} %", .{ cg_free[0], cg_swing }), .criterion = if (before_drop < cg_free.len) "líquido livre, antes da LAPES sair" else "líquido livre", .why = "o líquido que balança leva junto o CG", .group = "líquido" });
    } else try summary.append(memory, .{ "xCG (% CMA)", try std.fmt.allocPrint(memory, "{d:.2}", .{cg_free[0]}) });
    if (state.lapes > 0) try lapesChecks(memory, state, free, cg_free, &summary, &checks);
    const settled = free.instance.r.t < free.case.span - 1e-6;
    try checks.append(memory, .{
        .status = if (settled) .ok else .atencao,
        .item = "estabilizou",
        .value = if (settled) try std.fmt.allocPrint(memory, "em t = {d:.1} s", .{free.instance.r.t}) else "não, até o tempo máximo",
        .criterion = "α, líquido e xCG parados por 1 s",
        .why = if (settled) "a resposta rápida acabou (a fugóide e a espiral, lentas, seguem)" else "o avião ainda oscila ou diverge: veja os modos na aba Avião montado ou ligue o piloto automático",
        .group = "rajada",
    });

    // o líquido de cada tanque (só no voo livre: travado fica parado)
    const palette = [_][]const u8{ "#17becf", "#8c564b", "#e377c2", "#7f7f7f", "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e" };
    var liquid: std.ArrayList(native.Curve) = .empty;
    for (0..@min(state.n_tanks, core.limits.max_tanks)) |i| {
        const pitch_swing = try memory.alloc(f64, free.rows);
        const roll_swing = try memory.alloc(f64, free.rows);
        var peak: f64 = 0;
        for (free.log[0..free.rows], 0..) |row, k| {
            pitch_swing[k] = row.slosh_x[i] * deg;
            roll_swing[k] = row.slosh_y[i] * deg;
            peak = @max(peak, @max(@abs(pitch_swing[k] - pitch_swing[0]), @abs(roll_swing[k] - roll_swing[0])));
        }
        const name = state.tank_names[i];
        try liquid.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}: frente-trás", .{name}), .x = t_free, .y = pitch_swing, .color = palette[i % palette.len] });
        try liquid.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}: lado", .{name}), .x = t_free, .y = roll_swing, .color = palette[i % palette.len], .dashed = true });
        try checks.append(memory, .{ .status = .info, .item = try std.fmt.allocPrint(memory, "ângulo do líquido: {s}", .{name}), .value = try std.fmt.allocPrint(memory, "{d:.1}°", .{peak}), .criterion = "maior desvio do repouso", .why = "pêndulo equivalente (Abramson, NASA SP-106)", .group = "líquido" });
    }

    try poleChecks(memory, state, &checks);

    try native.beginResult(out, summary.items, checks.items);
    const flights = state.flights[0..state.count];
    var curves: std.ArrayList(native.Curve) = .empty;
    try curves.ensureTotalCapacity(memory, 2 * flights.len + 1);
    // a rajada tracejada junto da resposta que ela causa, como o comando nos gráficos do relatório: em graus, o
    // ângulo que ela soma ao vento relativo, atan(U/V)
    const gust_angles = try gustAngles(memory, free, t_free);
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, time), .y = try column(memory, flight, alpha), .color = "#1f77b4", .dashed = !flight.case.liquid_free });
    curves.appendAssumeCapacity(.{ .name = "rajada", .x = t_free, .y = gust_angles[0], .color = "#d62728", .dashed = true });
    try native.writePlot(out, plots[plot_alpha], curves.items, true);
    curves.clearRetainingCapacity();
    for (flights) |*flight| {
        const t = try column(memory, flight, time);
        curves.appendAssumeCapacity(.{ .name = try std.fmt.allocPrint(memory, "β {s}", .{caseName(flight)}), .x = t, .y = try column(memory, flight, beta), .color = "#d62728", .dashed = !flight.case.liquid_free });
        curves.appendAssumeCapacity(.{ .name = try std.fmt.allocPrint(memory, "φ {s}", .{caseName(flight)}), .x = t, .y = try column(memory, flight, bank), .color = "#2ca02c", .dashed = !flight.case.liquid_free });
    }
    if (free.case.lateral != 0) try curves.append(memory, .{ .name = "rajada", .x = t_free, .y = gust_angles[1], .color = "#000000", .dashed = true });
    try native.writePlot(out, plots[plot_lateral], curves.items, false);
    curves.clearRetainingCapacity();
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, time), .y = try column(memory, flight, load), .color = "#ff7f0e", .dashed = !flight.case.liquid_free });
    try native.writePlot(out, plots[plot_load], curves.items, false);
    curves.clearRetainingCapacity();
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, time), .y = try cgPercent(memory, flight, state), .color = "#9467bd", .dashed = !flight.case.liquid_free });
    try native.writePlot(out, plots[plot_cg], curves.items, false);
    if (liquid.items.len > 0) try native.writePlot(out, plots[plot_liquid], liquid.items, false);
    const active = effects(state, free);
    var shown: usize = 0;
    for (std.enums.values(Effect)) |effect| if (active.get(effect)) {
        try native.writePlot(out, plots[plot_poles + @as(usize, @intFromEnum(effect))], try locusCurves(memory, state, &.{effect}), false);
        shown += 1;
    };
    if (shown > 1) {
        var all: std.ArrayList(Effect) = .empty;
        for (std.enums.values(Effect)) |effect| if (active.get(effect)) try all.append(memory, effect);
        try native.writePlot(out, plots[plot_poles + 3], try locusCurves(memory, state, all.items), false);
    }
    try native.endResult(out);
}

/// a LAPES: a massa dela e, se saiu, quando, a massa que fica e o quanto o CG anda
fn lapesChecks(memory: std.mem.Allocator, state: *const State, free: *const Flight, cg_free: []const f64, summary: *std.ArrayList([2][]const u8), checks: *std.ArrayList(native.Check)) !void {
    try summary.append(memory, .{ "LAPES (kg)", try std.fmt.allocPrint(memory, "{d:.3}", .{state.lapes}) });
    const asked = free.case.release orelse return;
    const instance = free.instance;
    if (instance.r.f.released == 0) {
        try checks.append(memory, .{ .status = .atencao, .item = "LAPES saiu", .value = "não", .criterion = try std.fmt.allocPrint(memory, "pedida em t = {d:.1} s", .{asked}), .why = "o voo acabou antes de a carga terminar a rampa: aumente o tempo máximo", .group = "LAPES" });
        return;
    }
    const left = core.trim.Ctx.init(&instance.p, &instance.r.f).m;
    var after: usize = 0;
    while (after + 1 < free.rows and free.log[after].t < instance.r.ev.trel) after += 1;
    const cg_after = cg_free[@min(after + 1, cg_free.len - 1)];
    try summary.append(memory, .{ "massa depois da LAPES (kg)", try std.fmt.allocPrint(memory, "{d:.3}", .{left}) });
    try checks.append(memory, .{
        .status = .info,
        .item = "LAPES saiu",
        .value = try std.fmt.allocPrint(memory, "em t = {d:.2} s; fica {d:.2} kg", .{ instance.r.ev.trel, left }),
        .criterion = try std.fmt.allocPrint(memory, "pedida em t = {d:.1} s", .{asked}),
        .why = "a carga desliza pela rampa e sai; o voo segue com o resto da massa",
        .group = "LAPES",
    });
    try checks.append(memory, .{
        .status = .info,
        .item = "xCG sem a LAPES",
        .value = try std.fmt.allocPrint(memory, "{d:.2} → {d:.2} % CMA", .{ cg_free[0], cg_after }),
        .criterion = "antes → logo depois da saída",
        .why = "a massa da LAPES sai de onde ela estava e o CG vai para o lado oposto",
        .group = "LAPES",
    });
}

/// a rajada no tempo do voo como o ângulo que ela soma ao vento relativo (°): a vertical em α e a lateral em β. Sobe de
/// 0 ao pico e volta a 0 na duração pedida (a 1 − cos do núcleo)
fn gustAngles(memory: std.mem.Allocator, free: *const Flight, t: []const f64) ![2][]f64 {
    const instance = free.instance;
    const arrived = if (instance.r.tg >= 0) instance.r.tg else free.case.start;
    const up = try memory.alloc(f64, t.len);
    const side = try memory.alloc(f64, t.len);
    for (t, 0..) |moment, k| {
        const speed = core.gust.gustSpeed(&instance.p, moment, arrived);
        up[k] = std.math.atan(speed[0] / free.case.airspeed) * deg;
        side[k] = std.math.atan(speed[1] / free.case.airspeed) * deg;
    }
    return .{ up, side };
}

/// os polos de um instante de um modo, na ordem de cima para baixo (a mesma ordem em todos os instantes liga cada
/// polo ao seguinte)
fn modePoles(memory: std.mem.Allocator, poles: *const core.gust.Poles, mode: Mode) ![]const [2]f64 {
    var list: std.ArrayList([2]f64) = .empty;
    if (!poles.ok) return list.items;
    for (0..poles.count) |i| if (poles.mode[i] == mode) try list.append(memory, .{ poles.real[i], poles.imag[i] });
    std.mem.sort([2]f64, list.items, {}, struct {
        fn above(_: void, a: [2]f64, b: [2]f64) bool {
            return if (a[1] != b[1]) a[1] > b[1] else a[0] < b[0];
        }
    }.above);
    return list.items;
}

/// os polos de cada efeito ao longo do voo: uma curva fina por polo, que mostra para onde ele anda, e o ponto do começo
/// destacado com o símbolo do modo. A cor é a do efeito
fn locusCurves(memory: std.mem.Allocator, state: *const State, chosen: []const Effect) ![]const native.Curve {
    var curves: std.ArrayList(native.Curve) = .empty;
    var in_legend = std.EnumArray(Mode, bool).initFill(false); // cada símbolo uma vez na legenda
    for (chosen) |effect| {
        const color = effect_color.get(effect);
        const loci = state.loci[@intFromEnum(effect)][0..state.samples];
        var named_line = false;
        for (std.enums.values(Mode)) |mode| {
            var slots: usize = 0;
            for (loci) |*poles| slots = @max(slots, (try modePoles(memory, poles, mode)).len);
            for (0..slots) |slot| {
                const xs = try memory.alloc(f64, loci.len);
                const ys = try memory.alloc(f64, loci.len);
                for (loci, 0..) |*poles, k| {
                    const found = try modePoles(memory, poles, mode);
                    xs[k] = if (slot < found.len) found[slot][0] else std.math.nan(f64);
                    ys[k] = if (slot < found.len) found[slot][1] else std.math.nan(f64);
                }
                try curves.append(memory, .{ .name = effect_name.get(effect), .x = xs, .y = ys, .color = color, .legend = !named_line and chosen.len > 1 });
                named_line = true;
            }
            const first = try modePoles(memory, &loci[0], mode);
            if (first.len == 0) continue;
            const xs = try memory.alloc(f64, first.len);
            const ys = try memory.alloc(f64, first.len);
            for (first, 0..) |pole, i| {
                xs[i] = pole[0];
                ys[i] = pole[1];
            }
            try curves.append(memory, .{ .name = mode_name.get(mode), .x = xs, .y = ys, .color = color, .marker = mode_marker.get(mode), .size = 9, .legend = !in_legend.get(mode) });
            in_legend.set(mode, true);
        }
    }
    return curves.items;
}

/// o polo menos estável em palavras: o modo, σ e, se oscila, ω
fn describePole(memory: std.mem.Allocator, poles: *const core.gust.Poles) ![]const u8 {
    const worst = poles.leastStable();
    const sigma = poles.real[worst];
    const omega = @abs(poles.imag[worst]);
    const name = mode_name.get(poles.mode[worst]);
    if (omega > 1e-6) return std.fmt.allocPrint(memory, "{s}: σ = {d:.3} 1/s, ω = {d:.2} rad/s", .{ name, sigma, omega });
    return std.fmt.allocPrint(memory, "{s}: σ = {d:.3} 1/s", .{ name, sigma });
}

/// o diagnóstico dos polos no começo do voo: algum cresce? e quanto o líquido e a saída da LAPES mudam o menos estável
fn poleChecks(memory: std.mem.Allocator, state: *const State, checks: *std.ArrayList(native.Check)) !void {
    if (state.samples == 0) return;
    const free = &state.flights[0];
    const active = effects(state, free);
    const main = &state.loci[@intFromEnum(if (active.get(.sloshing)) Effect.sloshing else Effect.plain)][0];
    if (!main.ok) {
        try checks.append(memory, .{ .status = .atencao, .item = "polos", .value = "não saíram", .criterion = "equilíbrio nivelado", .why = "a trimagem ou o QR não convergiram nesta velocidade", .group = "polos" });
        return;
    }
    const sigma = main.largestReal();
    const growing = sigma > 1e-4;
    try checks.append(memory, .{
        .status = if (growing) .atencao else .ok,
        .item = "polos",
        .value = try describePole(memory, main),
        .criterion = "σ < 0 em todos (o menos estável)",
        .why = if (growing) try std.fmt.allocPrint(memory, "um modo cresce e dobra a cada {d:.1} s; se ele é lento (espiral, fugóide), o piloto ou o piloto automático seguram", .{@log(2.0) / sigma}) else "todos os modos amortecem",
        .group = "polos",
    });
    if (active.get(.sloshing)) {
        const plain = &state.loci[@intFromEnum(Effect.plain)][0];
        if (plain.ok) try checks.append(memory, .{ .status = .info, .item = "polos sem efeitos", .value = try describePole(memory, plain), .criterion = "o menos estável", .why = "o líquido travado: a diferença para o sloshing é o efeito do líquido balançando", .group = "polos" });
    }
    if (active.get(.lapes)) {
        const after = &state.loci[@intFromEnum(Effect.lapes)][state.samples - 1];
        if (after.ok) try checks.append(memory, .{ .status = .info, .item = "polos sem a LAPES", .value = try describePole(memory, after), .criterion = "o menos estável, no fim do voo", .why = "o avião depois da saída: mais leve e com outro CG", .group = "polos" });
    }
}

fn caseName(flight: *const Flight) []const u8 {
    return if (flight.case.liquid_free) "líquido livre" else "líquido travado";
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "campos e resultado no JSON da ponte; o líquido livre mexe o xCG e o travado não" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/S1223_monomotor_EH_convencional_Joinville.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    try testing.expect(loaded.ac.tanks.len > 0);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try specs(&text.writer, &loaded.ac, .{});
    const form = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer form.deinit();
    try testing.expectEqual(@as(usize, 17), form.value.object.get("params").?.array.items.len);
    // a tabela dos tanques, com a massa do líquido de cada um, e a vista 3D com os tanques e o CG
    const grid = form.value.object.get("grids").?.array.items[0];
    const first_row = grid.object.get("rows").?.array.items[0].array.items;
    const tank = loaded.ac.tanks[0];
    try testing.expectApproxEqAbs(tank.rho * tank.volume / 1000.0, try std.fmt.parseFloat(f64, first_row[8].string), 1e-3);
    const view_json = form.value.object.get("view").?.object;
    try testing.expect(view_json.get("meshes").?.array.items.len > 3);
    try testing.expectEqual(@as(usize, 3), view_json.get("markers").?.object.get("cg").?.array.items.len);

    var run = native.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    const values = native.Values.fromRequest(run.memory(), "\"op\": \"run\", \"values\": {\"span\": 4, \"up\": 3}");
    try start(&run, values);
    var slices: usize = 0;
    while (!try advance(&run)) slices += 1;
    try testing.expect(slices > 4); // andou em fatias
    text.clearRetainingCapacity();
    try result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    const charts = outcome.value.object.get("plots").?.array.items;
    // com tanques e sem soltar a LAPES: os gráficos no tempo e os polos sem efeitos, com sloshing e todos juntos
    try testing.expectEqual(@as(usize, 5 + 3), charts.len);
    const xcg = charts[plot_cg].object.get("curves").?.array.items;
    // a rajada tracejada no α: em graus, sobe de 0 a atan(3/V) e volta a 0
    const alpha_curves = charts[plot_alpha].object.get("curves").?.array.items;
    const gust_angle = alpha_curves[alpha_curves.len - 1].object.get("y").?.array.items;
    var gust_peak: f64 = 0;
    for (gust_angle) |value| gust_peak = @max(gust_peak, jsonNumber(value));
    try testing.expectApproxEqAbs(std.math.atan(3.0 / cruise(&loaded.ac)) * deg, gust_peak, 0.05);
    try testing.expectEqual(@as(f64, 0), jsonNumber(gust_angle[0]));
    try testing.expectEqual(@as(f64, 0), jsonNumber(gust_angle[gust_angle.len - 1]));
    try testing.expectEqualStrings("Polos com sloshing", charts[6].object.get("title").?.string);
    try testing.expectEqualStrings("Todos os polos", charts[7].object.get("title").?.string);
    const free_cg = xcg[0].object.get("y").?.array.items;
    const locked_cg = xcg[1].object.get("y").?.array.items;
    var free_moves: f64 = 0;
    var locked_moves: f64 = 0;
    for (free_cg) |value| free_moves = @max(free_moves, @abs(jsonNumber(value) - jsonNumber(free_cg[0])));
    for (locked_cg) |value| locked_moves = @max(locked_moves, @abs(jsonNumber(value) - jsonNumber(locked_cg[0])));
    try testing.expect(free_moves > 1e-4); // % CMA
    try testing.expect(locked_moves < 1e-9);
    // o CG em % da CMA bate com o da Estabilidade em Python (27,5 % no S1223 com a carga e o líquido)
    try testing.expectApproxEqAbs(@as(f64, 27.5), jsonNumber(free_cg[0]), 0.6);
}

test "a tabela dos tanques: soma, edita, apaga e volta ao arquivo; a LAPES solta deixa o resto da massa" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/S1223_monomotor_EH_convencional_Joinville.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const plane = &loaded.ac;
    tanks_table.reset(plane);
    const original = plane.tanks.len;
    try edit(plane, .{ .grid = "tanks", .operation = "add", .row = 0 });
    try testing.expectEqual(original + 1, tanks_table.count);
    try edit(plane, .{ .grid = "tanks", .operation = "set", .row = 1, .key = "volume", .value = .{ .string = "0,75" } });
    try edit(plane, .{ .grid = "tanks", .operation = "set", .row = 1, .key = "y", .value = .{ .float = -0.3 } });
    try edit(plane, .{ .grid = "tanks", .operation = "set", .row = 1, .key = "shape", .value = .{ .string = "cilindro" } });
    try testing.expectEqual(@as(f64, 0.75), tanks_table.tanks[1].volume);
    try testing.expectEqual(@as(f64, -0.3), tanks_table.tanks[1].y);
    try testing.expectEqualStrings("cylinder", tanks_table.tanks[1].shape);
    try edit(plane, .{ .grid = "tanks", .operation = "delete", .row = 0 });
    try testing.expectEqual(original, tanks_table.count);
    try testing.expectEqual(@as(f64, -0.3), tanks_table.tanks[0].y);
    try edit(plane, .{ .grid = "tanks", .operation = "reset" });
    try testing.expectEqual(plane.tanks[0].y, tanks_table.tanks[0].y);

    // sem tanques e com a LAPES solta em 2 s: roda sem a parte do líquido e o voo segue sem a carga
    for (0..original) |_| try edit(plane, .{ .grid = "tanks", .operation = "delete", .row = 0 });
    var run = native.Run{ .arena = .init(gpa), .aircraft = plane };
    defer run.arena.deinit();
    try start(&run, native.Values.fromRequest(run.memory(), "\"values\": {\"span\": 5, \"lapes\": true, \"lapes_mass\": 1.2, \"drop\": true, \"drop_t\": 2}"));
    while (!try advance(&run)) {}
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 4 + 3), outcome.value.object.get("plots").?.array.items.len); // sem o do líquido; polos sem efeitos, com a LAPES e todos
    const summary = outcome.value.object.get("summary").?.object;
    const before = try std.fmt.parseFloat(f64, summary.get("massa (kg)").?.string);
    const after = try std.fmt.parseFloat(f64, summary.get("massa depois da LAPES (kg)").?.string);
    try testing.expectApproxEqAbs(before - 1.2, after, 2e-3);
    tanks_table.reset(plane);
}

fn jsonNumber(value: std.json.Value) f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

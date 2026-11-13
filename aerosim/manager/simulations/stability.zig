//! As análises da Estabilidade em Zig (o par de `stability.py`). Por enquanto, a Estabilidade dinâmica: o avião em voo nivelado recebe uma rajada (vertical, lateral ou as duas) e a aba
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
const simulation = @import("simulation");

const params_mod = aircraft_model.params;
const model = aircraft_model.aircraft;
const Aircraft = model.Aircraft;
const mission = @import("mission.zig");
const deg = 180.0 / std.math.pi;

/// a análise, com a interface de `simulation.check`
pub const DynamicStability = struct {
    pub const name: []const u8 = "estabilidade_dinamica";
    pub const title: [:0]const u8 = "Estabilidade dinâmica";
    pub const area: []const u8 = "Estabilidade";
    pub const description: []const u8 = "O avião em voo nivelado recebe uma rajada 1 − cos (vertical, lateral ou as duas) e a resposta sai no " ++
        "tempo: ângulo de ataque, derrapagem, rolamento, o xCG e o ângulo do líquido de cada tanque. Com tanques, voa " ++
        "com o líquido livre e travado, para comparar. Tudo em Zig, no núcleo.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const edit = editTanks;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
};

const pilots = [_][]const u8{ "manche fixo", "piloto automático" };
const max_cases = 2;
const slice_seconds = 0.25; // de voo por fatia (poucos milissegundos de conta)

const plots = [_]simulation.Plot{
    .{ .key = "alpha", .title = "Ângulo de ataque", .xlabel = "$t$ (s)", .ylabel = "$\\alpha$ (°)" },
    .{ .key = "lateral", .title = "Derrapagem e rolamento", .xlabel = "$t$ (s)", .ylabel = "°" },
    .{ .key = "load", .title = "Fator de carga", .xlabel = "$t$ (s)", .ylabel = "$n_z$" },
    .{ .key = "xcg", .title = "Posição do CG", .xlabel = "$t$ (s)", .ylabel = "$x_{CG}$ (% CMA)" },
    .{ .key = "liquid", .title = "Líquido", .xlabel = "$t$ (s)", .ylabel = "ângulo (°)" },
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
const max_samples = 200; // o máximo de instantes do voo em que se refazem os polos
const Mode = core.gust.Mode;
const mode_marker = std.EnumArray(Mode, []const u8).init(.{ .short_period = "o", .phugoid = "s", .dutch_roll = "d", .roll = "t", .spiral = "+", .liquid = "x" });
const mode_name = std.EnumArray(Mode, []const u8).init(.{ .short_period = "curto período", .phugoid = "fugóide", .dutch_roll = "dutch roll", .roll = "rolamento", .spiral = "espiral", .liquid = "líquido" });

fn cruise(aircraft: *const simulation.Aircraft) f64 {
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
    fn reset(layout: *Layout, aircraft: *const simulation.Aircraft) void {
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
    fn sync(layout: *Layout, aircraft: *const simulation.Aircraft) void {
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
fn fingerprint(aircraft: *const simulation.Aircraft) u64 {
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

const tank_columns = [_]simulation.Column{
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
fn editTanks(aircraft: ?*const simulation.Aircraft, change: simulation.GridEdit) simulation.Error!void {
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
fn payloadFrom(aircraft: *const simulation.Aircraft, values: simulation.Values) Payload {
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
fn configured(aircraft: *const simulation.Aircraft, values: simulation.Values) simulation.Aircraft {
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

fn balance(plane: *const simulation.Aircraft, values: simulation.Values) ?Balance {
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
fn tankGrid(memory: std.mem.Allocator, plane: *const simulation.Aircraft, mass: ?Balance) !simulation.Grid {
    const rows = try memory.alloc([]const simulation.Cell, plane.tanks.len);
    var liquid: f64 = 0;
    for (plane.tanks, 0..) |tank, i| {
        const cells = try memory.alloc(simulation.Cell, tank_columns.len);
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
fn view(memory: std.mem.Allocator, plane: *const simulation.Aircraft, mass: ?Balance) !?simulation.View {
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const built = aircraft_model.skeleton.build(memory, plane, &diagnosis) catch return null; // na arena da resposta
    var meshes: std.ArrayList(simulation.Mesh) = .empty;
    // as opacas primeiro e as transparentes (tanque, disco da hélice) por cima
    for ([_]bool{ false, true }) |translucent| for (built.pieces) |piece| {
        if ((aircraft_model.skeleton.rgba(piece.color)[3] < 1) != translucent) continue;
        try meshes.append(memory, .{ .kind = @tagName(piece.color), .vertices = piece.mesh.v, .faces = piece.mesh.f });
    };
    return .{ .meshes = meshes.items, .cg = if (mass) |known| known.center else null };
}

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const speed = if (aircraft) |plane| cruise(plane) else 15.0;
    const dry = if (aircraft) |plane| @round(params_mod.dryMass(plane).m * 1000.0) / 1000.0 else 0.0;
    const file_payload: Payload = if (aircraft) |plane| plane.payload else .{};
    var extras: simulation.Extras = .{};
    var has_tanks = true;
    if (aircraft) |source| {
        const plane = configured(source, values);
        has_tanks = plane.tanks.len > 0;
        const mass = balance(&plane, values);
        const grids = try memory.alloc(simulation.Grid, 1);
        grids[0] = try tankGrid(memory, &plane, mass);
        extras = .{ .grids = grids, .view = try view(memory, &plane, mass) };
    }
    const params = [_]simulation.Param{
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
        .{ .key = "polos_instantes", .label = "instantes em que os polos são refeitos", .default = .{ .number = 24 }, .minimum = 2, .maximum = max_samples, .group = "Rajada", .help = "ao longo do voo o avião é linearizado de novo nestes instantes (igualmente espaçados) para mostrar o caminho dos polos" },
        .{ .key = "compare", .label = "comparar com o líquido travado", .kind = .bool, .default = .{ .toggle = has_tanks }, .group = "Líquido", .help = "voa de novo com o líquido parado nos tanques (mesma massa)" },
    };
    var with_refine = extras;
    with_refine.solvers = &.{ .trim, .equilibrium, .gust };
    with_refine.aircraft = aircraft;
    try simulation.writeSpecs(out, &(params ++ simulation.method_params), &plots, DynamicStability.description, with_refine);
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

const RunState = struct {
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
    wanted_samples: usize = 24, // instantes do voo em que se refazem os polos (campo "polos_instantes")
};

/// os efeitos que valem neste voo: sem efeitos sempre; o sloshing com tanques; a LAPES se ela sai no voo
fn effects(state: *const RunState, free: *const Flight) std.EnumArray(Effect, bool) {
    return .init(.{ .plain = true, .sloshing = state.n_tanks > 0, .lapes = state.lapes > 0 and free.case.release != null and free.instance.r.f.released != 0 });
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    const autopilot = std.mem.eql(u8, values.text("pilot", pilots[0]), pilots[1]);
    state.wanted_samples = @intFromFloat(std.math.clamp(@round(values.number("polos_instantes", 24)), 2, max_samples));
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
    const plane = try memory.create(simulation.Aircraft);
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
        _ = params_mod.setupWith(aircraft, instance, &diagnosis, values.methods()) catch |err| {
            run.fail("o avião não montou no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
            return err;
        };
        withMass(instance, values.number("mass", 0));
        state.mass = core.trim.Ctx.init(&instance.p, &instance.r.f).m;
        const rows = @as(usize, @intFromFloat(@ceil(case.span / instance.p.dtlog))) + 16;
        flight.* = .{ .case = case, .instance = instance, .log = try memory.alloc(core.types.LogRow, rows) };
    }
}

fn advanceRun(run: *simulation.Run, state: *RunState) simulation.Error!bool {
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
fn samplePoles(run: *simulation.Run, state: *RunState) bool {
    if (state.samples >= state.wanted_samples) return true;
    const free = &state.flights[0];
    const instance = free.instance;
    const last = free.log[free.rows - 1].t;
    const moment = last * @as(f64, @floatFromInt(state.samples)) / @as(f64, @floatFromInt(state.wanted_samples - 1));
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
    return state.samples >= state.wanted_samples;
}

/// uma coluna do registro de um voo, já na unidade do gráfico
fn column(memory: std.mem.Allocator, flight: *const Flight, comptime pick: fn (row: core.types.LogRow, first: core.types.LogRow) f64) ![]f64 {
    const values = try memory.alloc(f64, flight.rows);
    for (flight.log[0..flight.rows], 0..) |row, k| values[k] = pick(row, flight.log[0]);
    return values;
}

fn logTime(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.t;
}
fn logAlpha(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.alpha * deg;
}
fn logBeta(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.beta * deg;
}
fn logBank(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.phi * deg;
}
fn logLoad(row: core.types.LogRow, _: core.types.LogRow) f64 {
    return row.nz;
}
/// o xCG em % da CMA a partir do bordo de ataque (como no resto da Estabilidade)
fn cgPercent(memory: std.mem.Allocator, flight: *const Flight, state: *const RunState) ![]f64 {
    const values = try memory.alloc(f64, flight.rows);
    for (flight.log[0..flight.rows], 0..) |row, k| values[k] = 100.0 * (state.mac_le - row.xcg) / state.mac;
    return values;
}

fn largest(values: []const f64, reference: f64) f64 {
    var peak: f64 = 0;
    for (values) |value| peak = @max(peak, @abs(value - reference));
    return peak;
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    const free = &state.flights[0];
    if (free.rows < 2) return error.NoRows;
    const t_free = try column(memory, free, logTime);
    const alpha_free = try column(memory, free, logAlpha);
    const cg_free = try cgPercent(memory, free, state);
    const alpha_trim = alpha_free[0];

    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
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
    var liquid: std.ArrayList(simulation.Curve) = .empty;
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

    try simulation.beginResult(out, summary.items, checks.items);
    const flights = state.flights[0..state.count];
    var curves: std.ArrayList(simulation.Curve) = .empty;
    try curves.ensureTotalCapacity(memory, 2 * flights.len + 1);
    // a rajada tracejada junto da resposta que ela causa, como o comando nos gráficos do relatório: em graus, o
    // ângulo que ela soma ao vento relativo, atan(U/V)
    const gust_angles = try gustAngles(memory, free, t_free);
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, logTime), .y = try column(memory, flight, logAlpha), .color = "#1f77b4", .dashed = !flight.case.liquid_free });
    curves.appendAssumeCapacity(.{ .name = "rajada", .x = t_free, .y = gust_angles[0], .color = "#d62728", .dashed = true });
    try simulation.writePlot(out, plots[plot_alpha], curves.items, true);
    curves.clearRetainingCapacity();
    for (flights) |*flight| {
        const times = try column(memory, flight, logTime);
        curves.appendAssumeCapacity(.{ .name = try std.fmt.allocPrint(memory, "β {s}", .{caseName(flight)}), .x = times, .y = try column(memory, flight, logBeta), .color = "#d62728", .dashed = !flight.case.liquid_free });
        curves.appendAssumeCapacity(.{ .name = try std.fmt.allocPrint(memory, "φ {s}", .{caseName(flight)}), .x = times, .y = try column(memory, flight, logBank), .color = "#2ca02c", .dashed = !flight.case.liquid_free });
    }
    if (free.case.lateral != 0) try curves.append(memory, .{ .name = "rajada", .x = t_free, .y = gust_angles[1], .color = "#000000", .dashed = true });
    try simulation.writePlot(out, plots[plot_lateral], curves.items, false);
    curves.clearRetainingCapacity();
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, logTime), .y = try column(memory, flight, logLoad), .color = "#ff7f0e", .dashed = !flight.case.liquid_free });
    try simulation.writePlot(out, plots[plot_load], curves.items, false);
    curves.clearRetainingCapacity();
    for (flights) |*flight| curves.appendAssumeCapacity(.{ .name = caseName(flight), .x = try column(memory, flight, logTime), .y = try cgPercent(memory, flight, state), .color = "#9467bd", .dashed = !flight.case.liquid_free });
    try simulation.writePlot(out, plots[plot_cg], curves.items, false);
    if (liquid.items.len > 0) try simulation.writePlot(out, plots[plot_liquid], liquid.items, false);
    const active = effects(state, free);
    var shown: usize = 0;
    for (std.enums.values(Effect)) |effect| if (active.get(effect)) {
        try simulation.writePlot(out, plots[plot_poles + @as(usize, @intFromEnum(effect))], try locusCurves(memory, state, &.{effect}), false);
        shown += 1;
    };
    if (shown > 1) {
        var all: std.ArrayList(Effect) = .empty;
        for (std.enums.values(Effect)) |effect| if (active.get(effect)) try all.append(memory, effect);
        try simulation.writePlot(out, plots[plot_poles + 3], try locusCurves(memory, state, all.items), false);
    }
    try simulation.endResult(out);
}

/// a LAPES: a massa dela e, se saiu, quando, a massa que fica e o quanto o CG anda
fn lapesChecks(memory: std.mem.Allocator, state: *const RunState, free: *const Flight, cg_free: []const f64, summary: *std.ArrayList([2][]const u8), checks: *std.ArrayList(simulation.Check)) !void {
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
fn locusCurves(memory: std.mem.Allocator, state: *const RunState, chosen: []const Effect) ![]const simulation.Curve {
    var curves: std.ArrayList(simulation.Curve) = .empty;
    var in_legend = std.EnumArray(Mode, bool).initFill(false); // cada símbolo uma vez na legenda
    for (chosen) |effect| {
        const color = effect_color.get(effect);
        const loci = state.loci[@intFromEnum(effect)][0..state.samples];
        // com mais de um efeito, a legenda leva a cor de cada um (uma curva vazia só com o nome)
        if (chosen.len > 1) try curves.append(memory, .{ .name = effect_name.get(effect), .x = &.{}, .y = &.{}, .color = color });
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
                // o nome diz de qual polo é a curva (o cabeçalho do CSV); fora da legenda
                const name = try std.fmt.allocPrint(memory, "{s}: {s} {d}", .{ effect_name.get(effect), mode_name.get(mode), slot + 1 });
                try curves.append(memory, .{ .name = name, .x = xs, .y = ys, .color = color, .legend = false });
            }
            const first = try modePoles(memory, &loci[0], mode);
            if (first.len == 0) continue;
            const xs = try memory.alloc(f64, first.len);
            const ys = try memory.alloc(f64, first.len);
            for (first, 0..) |pole, i| {
                xs[i] = pole[0];
                ys[i] = pole[1];
            }
            const name = if (chosen.len > 1) try std.fmt.allocPrint(memory, "{s} ({s})", .{ mode_name.get(mode), effect_name.get(effect) }) else mode_name.get(mode);
            try curves.append(memory, .{ .name = if (in_legend.get(mode)) name else mode_name.get(mode), .x = xs, .y = ys, .color = color, .marker = mode_marker.get(mode), .size = 9, .legend = !in_legend.get(mode) });
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
fn poleChecks(memory: std.mem.Allocator, state: *const RunState, checks: *std.ArrayList(simulation.Check)) !void {
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

// ================================================================== Estabilidade (o avião montado)
//
// O par de `StabilitySimulation` (`stability.py`): diz se a configuração serve, por quê, e o que mudar. A ordem é a
// do dimensionamento: a estática longitudinal (ponto neutro, margem e deflexão de equilíbrio × CG, os limites do CG
// e a faixa prevista), a área do EH pela faixa de CG, a estática látero-direcional (C_nβ, C_lβ e a espiral), os
// comandos (rolagem, profundor e leme), a asa voadora (torção na ponta e o tamanho do elevon) e a dinâmica do modelo
// linear contra os critérios, com a correção procurada quando um modo não passa. A conta é a do núcleo
// (`core/src/sim/static.zig` e `modes.zig`); aqui ficam o formulário, as variações do avião e o texto do
// diagnóstico. Os campos e os gráficos seguem o que o avião tem (`Configuration`), sem nenhum tipo de avião fixo.

const sizing = core.static_stability;
const qualities = core.flight_modes;
const rad = std.math.pi / 180.0;

/// a análise, com a interface de `simulation.check`
pub const Stability = struct {
    pub const name: []const u8 = "stability";
    pub const title: [:0]const u8 = "Estabilidade";
    pub const area: []const u8 = "Estabilidade";
    pub const description: []const u8 = "Diz se a configuração é estável e controlável, por quê, e o que mudar: margem estática e " ++
        "limites de CG, área de EH, estabilidade direcional e lateral, modos dinâmicos (MIL-F-8785C) e " ++
        "tamanho dos comandos. Os campos e gráficos seguem a configuração da aeronave.";
    pub const State = StaticState;
    pub const specs = writeStaticFields;
    pub const start = startStatic;
    pub const advance = advanceStatic;
    pub const result = writeStaticResult;
};

const flight_mode_label = std.EnumArray(qualities.Mode, []const u8).init(.{ .short_period = "curto período", .phugoid = "fugóide", .dutch_roll = "dutch roll", .roll = "rolamento", .spiral = "espiral" });
const flight_mode_color = std.EnumArray(qualities.Mode, []const u8).init(.{ .short_period = "#1f77b4", .phugoid = "#ff7f0e", .dutch_roll = "#9467bd", .roll = "#2ca02c", .spiral = "#d62728" });
const flight_mode_marker = std.EnumArray(qualities.Mode, []const u8).init(.{ .short_period = "o", .phugoid = "s", .dutch_roll = "d", .roll = "t", .spiral = "x" });
const slow_modes = [_]qualities.Mode{ .phugoid, .dutch_roll, .spiral }; // os polos perto da origem, num gráfico só deles
const all_modes = [_]qualities.Mode{ .short_period, .phugoid, .dutch_roll, .roll, .spiral };
const speed_palette = [_][]const u8{ "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf" };

const norms = [_][]const u8{ "MIL-F-8785C", "personalizado", "nenhuma (só valores)" };
const flight_mass_sources = [_][]const u8{ "a do avião", "MTOW salvo", "na mão" };
const class_labels = [_][]const u8{ "I", "II", "III", "IV" };
const phase_labels = [_][]const u8{ "A", "B", "C" };

/// os grupos de critérios que se ligam e desligam: a chave do formulário, o rótulo e os campos (`GROUPS`)
const CriterionGroup = struct { key: []const u8, label: []const u8, check: qualities.Check, fields: []const CriterionField };
const CriterionField = struct { key: []const u8, label: []const u8, unit: []const u8, field: []const u8 };
const criterion_groups = [_]CriterionGroup{
    .{ .key = "sp", .label = "curto período", .check = .short_period, .fields = &.{ .{ .key = "sp_zeta_min", .label = "curto período: ζ mínimo", .unit = "", .field = "short_period_min" }, .{ .key = "sp_zeta_max", .label = "curto período: ζ máximo", .unit = "", .field = "short_period_max" } } },
    .{ .key = "ph", .label = "fugóide", .check = .phugoid, .fields = &.{.{ .key = "ph_zeta_min", .label = "fugóide: ζ mínimo", .unit = "", .field = "phugoid_min" }} },
    .{ .key = "dr", .label = "dutch roll", .check = .dutch_roll, .fields = &.{ .{ .key = "dr_zeta_min", .label = "dutch roll: ζ mínimo", .unit = "", .field = "dutch_damping_min" }, .{ .key = "dr_zw_min", .label = "dutch roll: ζ·ω_n mínimo", .unit = "rad/s", .field = "dutch_product_min" }, .{ .key = "dr_wn_min", .label = "dutch roll: ω_n mínimo", .unit = "rad/s", .field = "dutch_natural_min" } } },
    .{ .key = "roll_tau", .label = "rolamento", .check = .roll_time_constant, .fields = &.{.{ .key = "roll_tau_max", .label = "rolamento: constante de tempo máxima", .unit = "s", .field = "roll_tau_max" }} },
    .{ .key = "spiral", .label = "espiral", .check = .spiral, .fields = &.{.{ .key = "spiral_t2_min", .label = "espiral: tempo mínimo para dobrar", .unit = "s", .field = "spiral_double_min" }} },
    .{ .key = "roll", .label = "tempo de rolagem", .check = .roll, .fields = &.{ .{ .key = "roll_phi", .label = "rolagem: inclinar até", .unit = "°", .field = "roll_angle" }, .{ .key = "roll_t", .label = "rolagem: em no máximo", .unit = "s", .field = "roll_time" } } },
};

/// o texto do critério de cada linha da avaliação dos modos
fn checkLabel(check: qualities.Check) []const u8 {
    return switch (check) {
        .short_period => "ζ curto período",
        .phugoid => "ζ fugóide",
        .dutch_roll => "dutch roll ζ / ζω_n / ω_n",
        .roll_time_constant => "τ_R rolamento (s)",
        .spiral => "espiral: tempo para dobrar (s)",
        .roll => "tempo de rolagem",
    };
}

// ------------------------------------------------------------------ o que o avião tem

/// um comando: a superfície e qual dos comandos dela
pub const ControlRef = struct { surface: usize, control: usize };

/// o que a aeronave tem para a Estabilidade (`features` de `aerosim/model/features.py`): a asa, a EH, as derivas e as
/// da ponta da asa, os comandos de cada eixo, o líquido, a carga e os motores
pub const Configuration = struct {
    pub const max_list = 16;
    wing: ?usize = null,
    htail: ?usize = null,
    fins: [max_list]usize = undefined, // derivas (sem as da ponta)
    fin_count: usize = 0,
    tip_fins: [max_list]usize = undefined, // derivas soltas na ponta da asa
    tip_count: usize = 0,
    wing_group: usize = 0, // quantas asas voam juntas com a principal
    pitch: ?ControlRef = null,
    roll: ?ControlRef = null,
    yaw: ?ControlRef = null,
    liquid: bool = false,
    slosh: bool = false,
    payload: bool = false,
    multi_engine: bool = false,
    gear: bool = true,

    fn tailless(configuration: Configuration) bool {
        return configuration.htail == null;
    }

    /// o que o comando de um eixo faz pela mistura ("elevator", "elevon", "ruddervator", "aileron", "rudder"); "" sem
    fn kind(aircraft: *const Aircraft, reference: ?ControlRef) []const u8 {
        const found = reference orelse return "";
        return aircraft.surfaces[found.surface].controls[found.control].role();
    }

    /// a lista das derivas (as da ponta quando não há outras), para crescer a área
    fn finList(configuration: *const Configuration) []const usize {
        return if (configuration.fin_count > 0) configuration.fins[0..configuration.fin_count] else configuration.tip_fins[0..configuration.tip_count];
    }
};

fn usable(surface: *const model.Surface) bool {
    return surface.enabled and surface.sections.len > 1;
}

pub fn detectConfiguration(aircraft: *const Aircraft) Configuration {
    var out: Configuration = .{};
    for (aircraft.surfaces, 0..) |*surface, i| {
        if (!usable(surface)) continue;
        if (out.wing == null and std.mem.eql(u8, surface.role, "wing")) out.wing = i;
        if (out.htail == null and std.mem.eql(u8, surface.role, "htail")) out.htail = i;
    }
    var group_wings: [Configuration.max_list]usize = undefined;
    if (out.wing) |main| {
        const main_wing = &aircraft.surfaces[main];
        for (aircraft.surfaces, 0..) |*surface, i| {
            const joined = if (main_wing.group.len == 0) i == main else (surface.enabled and std.mem.eql(u8, surface.role, "wing") and std.mem.eql(u8, surface.group, main_wing.group));
            if (joined and usable(surface) and out.wing_group < group_wings.len) {
                group_wings[out.wing_group] = i;
                out.wing_group += 1;
            }
        }
    }
    for (aircraft.surfaces, 0..) |*surface, i| {
        if (!usable(surface) or !surface.vertical or std.mem.eql(u8, surface.role, "wing")) continue;
        var at_tip = false;
        for (group_wings[0..out.wing_group]) |wing_index| {
            const wing = &aircraft.surfaces[wing_index];
            const half = model.semispan(wing);
            if (half > 0 and @abs(@abs(surface.y) - (wing.y + half)) < 0.08 * half) at_tip = true;
        }
        if (at_tip) {
            if (out.tip_count < Configuration.max_list) {
                out.tip_fins[out.tip_count] = i;
                out.tip_count += 1;
            }
        } else if (out.fin_count < Configuration.max_list) {
            out.fins[out.fin_count] = i;
            out.fin_count += 1;
        }
    }
    out.pitch = findControl(aircraft, &.{"elevator"}) orelse findControl(aircraft, &.{ "elevon", "ruddervator" });
    out.roll = findControl(aircraft, &.{"aileron"}) orelse findControl(aircraft, &.{"elevon"});
    out.yaw = findControl(aircraft, &.{"rudder"}) orelse findControl(aircraft, &.{"ruddervator"});
    for (aircraft.tanks) |tank| if (tank.fill() > 0) {
        out.liquid = true;
    };
    out.slosh = out.liquid and aircraft.sim.slosh;
    out.payload = aircraft.payload.enabled;
    var engines: usize = 0;
    var off_center = false;
    for (aircraft.propulsion) |unit| if (unit.enabled) {
        engines += 1;
        if (@abs(unit.y) > 0.05) off_center = true;
    };
    out.multi_engine = engines > 1 and off_center;
    return out;
}

/// o primeiro comando (na ordem das superfícies) que faz um dos `kinds`
fn findControl(aircraft: *const Aircraft, kinds: []const []const u8) ?ControlRef {
    for (aircraft.surfaces, 0..) |*surface, i| {
        if (!usable(surface)) continue;
        for (surface.controls, 0..) |control, k| for (kinds) |wanted| {
            if (std.mem.eql(u8, control.role(), wanted)) return .{ .surface = i, .control = k };
        };
    }
    return null;
}

/// o resumo da configuração (`Features.summary`)
pub fn configurationSummary(memory: std.mem.Allocator, aircraft: *const Aircraft, configuration: Configuration) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (configuration.wing_group > 1) {
        var names: std.ArrayList(u8) = .empty;
        const main = aircraft.surfaces[configuration.wing.?];
        var first = true;
        for (aircraft.surfaces) |surface| {
            const joined = surface.enabled and std.mem.eql(u8, surface.role, "wing") and main.group.len > 0 and std.mem.eql(u8, surface.group, main.group) and surface.sections.len > 1;
            if (!joined) continue;
            if (!first) try names.appendSlice(memory, " + ");
            try names.appendSlice(memory, surface.name);
            first = false;
        }
        try parts.append(memory, try std.fmt.allocPrint(memory, "{d} asas: {s}", .{ configuration.wing_group, names.items }));
        if (configuration.htail) |tail| try parts.append(memory, try std.fmt.allocPrint(memory, "EH: {s}", .{aircraft.surfaces[tail].name}));
    } else if (configuration.htail) |tail| {
        try parts.append(memory, try std.fmt.allocPrint(memory, "EH: {s}", .{aircraft.surfaces[tail].name}));
    } else try parts.append(memory, "asa voadora (sem EH)");
    if (configuration.pitch != null) try parts.append(memory, try std.fmt.allocPrint(memory, "arfagem por {s}", .{Configuration.kind(aircraft, configuration.pitch)}));
    if (configuration.roll != null) try parts.append(memory, try std.fmt.allocPrint(memory, "rolagem por {s}", .{Configuration.kind(aircraft, configuration.roll)}));
    try parts.append(memory, if (configuration.yaw != null) try std.fmt.allocPrint(memory, "guinada por {s}", .{Configuration.kind(aircraft, configuration.yaw)}) else "sem leme");
    if (configuration.tip_count > 0) try parts.append(memory, try std.fmt.allocPrint(memory, "{d} deriva(s) na ponta da asa", .{configuration.tip_count}));
    for (aircraft.surfaces) |surface| {
        if (!usable(&surface) or surface.vertical) continue;
        for (surface.devices) |device| if (device.enabled and device.height > 0) {
            try parts.append(memory, try std.fmt.allocPrint(memory, "{s} em {s} (η = {d:.2}, h = {d:.3} m, cant {s}°)", .{ device.kind, surface.name, device.eta, device.height, try general(memory, device.cant) }));
        };
    }
    if (configuration.liquid) try parts.append(memory, if (configuration.slosh) "líquido livre (sloshing)" else "líquido travado");
    if (configuration.payload) try parts.append(memory, "carga lançável");
    return std.mem.join(memory, "; ", parts.items);
}

// ------------------------------------------------------------------ números no texto

/// um número como o `{:g}` do Python (6 algarismos significativos, sem zeros no fim)
pub fn general(memory: std.mem.Allocator, value: f64) ![]const u8 {
    return significantText(memory, value, 6);
}

/// um número com `digits` algarismos significativos, como `{:.Ng}` do Python ("inf" e "nan" como ele)
fn significantText(memory: std.mem.Allocator, value: f64, comptime digits: i32) ![]const u8 {
    if (std.math.isNan(value)) return "nan";
    if (std.math.isInf(value)) return if (value > 0) "inf" else "-inf";
    if (value == 0) return "0";
    var exponent: i32 = @intFromFloat(@floor(std.math.log10(@abs(value))));
    // o arredondamento pode subir uma casa (9,9996 com 4 algarismos vira 10)
    const scaled = @round(value / std.math.pow(f64, 10, @floatFromInt(exponent - digits + 1)));
    if (@abs(scaled) >= std.math.pow(f64, 10, digits)) exponent += 1;
    if (exponent < -4 or exponent >= digits) {
        const mantissa = value / std.math.pow(f64, 10, @floatFromInt(exponent));
        const head = trimmedZeros(try std.fmt.allocPrint(memory, "{d:.[1]}", .{ mantissa, @as(usize, @intCast(digits - 1)) }));
        return std.fmt.allocPrint(memory, "{s}e{s}{d:0>2}", .{ head, if (exponent < 0) "-" else "+", @abs(exponent) });
    }
    const decimals: usize = @intCast(@max(0, digits - 1 - exponent));
    return trimmedZeros(try std.fmt.allocPrint(memory, "{d:.[1]}", .{ value, decimals }));
}

fn trimmedZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (text[end - 1] == '0') end -= 1;
    if (text[end - 1] == '.') end -= 1;
    return text[0..end];
}

/// um valor do resumo ou do diagnóstico (`_fmt`): 3 algarismos, "∞" e "—" fora dos finitos
fn shortNumber(memory: std.mem.Allocator, value: f64) ![]const u8 {
    if (!std.math.isFinite(value)) return if (value > 0) "∞" else "—";
    return significantText(memory, value, 3);
}

/// uma lista de valores (`_fmt` de uma lista)
fn shortList(memory: std.mem.Allocator, values: []const f64) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (values) |value| try parts.append(memory, try shortNumber(memory, value));
    return std.mem.join(memory, ", ", parts.items);
}

/// um número com o sinal sempre escrito e sem casas (`{:+.0f}`)
fn signedWhole(memory: std.mem.Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(memory, "{s}{d:.0}", .{ if (value >= 0) "+" else "-", @abs(value) });
}

// ------------------------------------------------------------------ geometria do modelo (o `AircraftModel` do Python)

/// a CMA de uma superfície: o tamanho, a posição na envergadura e o x do centro aerodinâmico (25 %), como
/// `SurfaceModel.mac()`
pub const MeanChord = struct { chord: f64, station: f64, x_leading: f64, x_center: f64 };

pub fn meanChord(aircraft: *const Aircraft, surface: *const model.Surface) MeanChord {
    var buffer: [model.limits.sections]model.Section = undefined;
    const sections = model.sortedSections(surface, &buffer);
    var squares: f64 = 0;
    var area_sum: f64 = 0;
    var moment: f64 = 0;
    if (sections.len > 1) for (sections[0 .. sections.len - 1], sections[1..]) |inner, outer| {
        const width = outer.y - inner.y;
        squares += width * (inner.chord * inner.chord + inner.chord * outer.chord + outer.chord * outer.chord) / 3;
        area_sum += width * (inner.chord + outer.chord) / 2;
        moment += width * (inner.chord * (2 * inner.y + outer.y) + outer.chord * (inner.y + 2 * outer.y)) / 6;
    };
    const chord = if (area_sum > 0) squares / area_sum else 0;
    const station = if (area_sum > 0) moment / area_sum else 0;
    const x_leading = model.tailOnBoom(aircraft, surface).x - model.sectionAt(sections, station, "x_offset");
    return .{ .chord = chord, .station = station, .x_leading = x_leading, .x_center = x_leading - 0.25 * chord };
}

/// o ponto neutro pela soma das superfícies horizontais (Etkin e Reid, Dynamics of Flight, cap. 2; Nelson, Flight
/// Stability and Automatic Control, cap. 2; a conferir no PDF), como `analytic_np`:
/// x_np = [Σ C_Lα,i (1 − dε/dα)_i η_i (S_i/S) x_ca,i] / C_Lα + c C_mα,fus / C_Lα
fn analyticNeutralPoint(aircraft: *const Aircraft, area: f64, chord: f64) f64 {
    var sum: f64 = 0;
    var slope: f64 = 0;
    const downwash = params_mod.wingDownwash(aircraft) catch .{ 0, 0 };
    for (aircraft.surfaces) |*surface| {
        if (!surface.enabled or surface.vertical) continue;
        if (!std.mem.eql(u8, surface.role, "wing") and !std.mem.eql(u8, surface.role, "htail")) continue;
        const coefficients = params_mod.coeffs(surface) catch continue;
        const gradient = if (surface.downwash) (surface.depsda orelse downwash[1]) else 0;
        const weight = coefficients.CLa * (1 - gradient) * surface.eta * params_mod.area(surface) / area;
        sum += weight * meanChord(aircraft, surface).x_center;
        slope += weight;
    }
    const fuselage_moment = if (aircraft.fuselage.enabled) aircraft.fuselage.Cma else 0;
    return if (slope > 0) sum / slope + chord * fuselage_moment / slope else std.math.nan(f64);
}

/// os volumes de cauda e o que entra neles: as áreas das caudas e os braços do CG ao CA de cada uma (o da última
/// cauda de cada tipo, como no Python)
pub const TailVolumes = struct { horizontal: f64 = 0, vertical: f64 = 0, horizontal_arm: f64 = 0, vertical_arm: f64 = 0, horizontal_area: f64 = 0, vertical_area: f64 = 0 };

/// os volumes de cauda V_H = S_h l_h / (S c) e V_V = S_v l_v / (S b), com os braços do CG ao CA de cada cauda
/// (`tail_volumes`)
pub fn tailVolumes(aircraft: *const Aircraft, x_cg: f64, references: [3]f64) TailVolumes {
    var out: TailVolumes = .{};
    for (aircraft.surfaces) |*surface| {
        if (!surface.enabled) continue;
        const is_htail = std.mem.eql(u8, surface.role, "htail");
        if (!is_htail and !std.mem.eql(u8, surface.role, "vtail")) continue;
        const arm = x_cg - meanChord(aircraft, surface).x_center;
        const surface_area = params_mod.area(surface);
        if (is_htail) {
            out.horizontal += surface_area * arm / (references[0] * references[1]);
            out.horizontal_arm = arm;
            out.horizontal_area += surface_area;
        } else {
            out.vertical += surface_area * arm / (references[0] * references[2]);
            out.vertical_arm = arm;
            out.vertical_area += surface_area;
        }
    }
    return out;
}

/// a velocidade de cruzeiro: a maior das pernas que não são decolagem nem pouso (15 m/s sem pernas), como
/// `_cruise_speed`
fn cruiseSpeed(params: *const core.types.Params) f64 {
    var speed: f64 = 0;
    for (params.seg[0..@intCast(params.n_seg)]) |leg| if (leg.takeoff == 0 and leg.landing == 0) {
        speed = @max(speed, leg.V1);
    };
    return if (speed > 0) speed else 15;
}

// ------------------------------------------------------------------ as variações do avião

/// uma cópia do avião com outra lista de superfícies (as outras partes são as mesmas)
fn withSurfaces(memory: std.mem.Allocator, aircraft: *const Aircraft) !struct { plane: Aircraft, surfaces: []model.Surface } {
    var plane = aircraft.*;
    const surfaces = try memory.dupe(model.Surface, aircraft.surfaces);
    plane.surfaces = surfaces;
    return .{ .plane = plane, .surfaces = surfaces };
}

/// as superfícies `which` com a área × k e o mesmo alongamento (`scale_surfaces`)
fn scaledSurfaces(memory: std.mem.Allocator, aircraft: *const Aircraft, which: []const usize, factor: f64) !Aircraft {
    var copy = try withSurfaces(memory, aircraft);
    const length_factor = @sqrt(factor);
    for (which) |i| {
        const sections = try memory.dupe(model.Section, copy.surfaces[i].sections);
        for (sections) |*section| {
            section.y *= length_factor;
            section.chord *= length_factor;
            section.x_offset *= length_factor;
        }
        copy.surfaces[i].sections = sections;
    }
    return copy.plane;
}

/// a asa com `delta` graus a mais de diedro (`with_dihedral`)
fn withDihedral(memory: std.mem.Allocator, aircraft: *const Aircraft, wing: usize, delta: f64) !Aircraft {
    var copy = try withSurfaces(memory, aircraft);
    copy.surfaces[wing].dihedral += delta;
    return copy.plane;
}

/// a asa com a torção extra linear na envergadura: 0 na raiz, `delta` graus na ponta (negativo = washout)
/// (`with_washout`)
fn withWashout(memory: std.mem.Allocator, aircraft: *const Aircraft, wing: usize, delta: f64) !Aircraft {
    var copy = try withSurfaces(memory, aircraft);
    const half = model.semispan(&copy.surfaces[wing]);
    if (half <= 0) return copy.plane;
    const sections = try memory.dupe(model.Section, copy.surfaces[wing].sections);
    for (sections) |*section| section.twist += delta * section.y / half;
    copy.surfaces[wing].sections = sections;
    return copy.plane;
}

/// o elevon da asa com outra corda e outro começo (o fim fica) (`with_elevon`)
fn withElevon(memory: std.mem.Allocator, aircraft: *const Aircraft, wing: usize, chord_fraction: f64, start_fraction: f64) !Aircraft {
    var copy = try withSurfaces(memory, aircraft);
    const copied_controls = try memory.dupe(model.Control, copy.surfaces[wing].controls);
    for (copied_controls) |*control| if (std.mem.eql(u8, control.role(), "elevon")) {
        control.chord_frac = chord_fraction;
        control.span_start = start_fraction;
        control.tau = null;
    };
    copy.surfaces[wing].controls = copied_controls;
    return copy.plane;
}

/// o avião sem a carga ou sem o líquido
fn withoutPayload(aircraft: *const Aircraft) Aircraft {
    var plane = aircraft.*;
    plane.payload.enabled = false;
    return plane;
}

fn withoutLiquid(aircraft: *const Aircraft) Aircraft {
    var plane = aircraft.*;
    plane.tanks = &.{};
    return plane;
}

// ------------------------------------------------------------------ uma sessão do núcleo para um avião

/// o avião montado no núcleo (os parâmetros, a massa do voo e a configuração) e a sonda dele; a memória é do
/// `page_allocator`, solta em `deinit` (a análise monta dezenas de variações)
const Session = struct {
    instance: *core.runner.Instance,
    probe: sizing.Probe,

    fn open(aircraft: *const Aircraft, loading: ?mission.Loading, chosen: core.methods.Methods) !Session {
        const instance = try std.heap.page_allocator.create(core.runner.Instance);
        errdefer std.heap.page_allocator.destroy(instance);
        instance.* = .{};
        var diagnosis: model.Diag = .{};
        try params_mod.fill(aircraft, &instance.p, &diagnosis);
        chosen.apply(&instance.p);
        if (loading) |flight| flight.apply(&instance.p); // o que passa da massa montada entra no CG seco
        core.runner.configure(instance) catch return error.CoreConfig;
        return .{ .instance = instance, .probe = sizing.Probe.init(instance, params_mod.macLeadingEdge(aircraft)) };
    }

    fn close(session: *Session) void {
        std.heap.page_allocator.destroy(session.instance);
    }
};

/// os modos do modelo linear de um avião a V (`modes_at`); null se a trimagem falha
fn modesAt(aircraft: *const Aircraft, loading: ?mission.Loading, chosen: core.methods.Methods, airspeed: f64) ?struct { modes: qualities.Modes, model: core.linear.LinModel } {
    var session = Session.open(aircraft, loading, chosen) catch return null;
    defer session.close();
    const linear_model = core.linear.linearize(&session.instance.p, &session.instance.r.f, airspeed);
    if (linear_model.ok == 0) return null;
    const found = qualities.classify(&linear_model.A) orelse return null;
    return .{ .modes = found, .model = linear_model };
}

// ------------------------------------------------------------------ o formulário

/// os números do avião que o formulário e a rodada usam: a velocidade de cruzeiro e a massa do avião inteiro
const Basics = struct { cruise: f64 = 15, mass: f64 = 5 };

fn basicsOf(aircraft: *const Aircraft) Basics {
    var session = Session.open(aircraft, null, .{}) catch return .{};
    defer session.close();
    return .{ .cruise = cruiseSpeed(&session.instance.p), .mass = session.probe.mass };
}

/// os MTOW salvos deste avião, com o rótulo da pista ("55 m · 12.51 kg", com o z quando a mesma pista tem dois)
fn savedRuns(memory: std.mem.Allocator, aircraft: *const Aircraft) !struct { labels: []const []const u8, runs: []const mission.SavedMtow } {
    var buffer: [8]mission.SavedMtow = undefined;
    const found = mission.savedMtows(aircraft, &buffer);
    const labels = try memory.alloc([]const u8, found.len);
    for (found, 0..) |saved, k| {
        var twice = false;
        for (found, 0..) |other, j| if (j != k and other.x_warning == saved.x_warning) {
            twice = true;
        };
        const z_text = if (twice) try std.fmt.allocPrint(memory, " (z {s} m)", .{try general(memory, saved.z_warning)}) else "";
        labels[k] = try std.fmt.allocPrint(memory, "{s} m{s} · {d:.2} kg", .{ try general(memory, saved.x_warning), z_text, saved.mass });
    }
    return .{ .labels = labels, .runs = try memory.dupe(mission.SavedMtow, found) };
}

/// o que um avião ausente mostra: todos os campos (como o Python sem avião)
fn everything() Configuration {
    return .{ .wing = 0, .htail = 0, .pitch = .{ .surface = 0, .control = 0 }, .roll = .{ .surface = 0, .control = 0 }, .yaw = .{ .surface = 0, .control = 0 } };
}

fn writeStaticFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const params = try staticParams(memory, aircraft, values);
    try simulation.writeSpecs(out, params, try staticPlots(memory, aircraft, values), Stability.description, .{ .solvers = &.{ .trim, .equilibrium, .static, .stall_curve, .control_moment }, .aircraft = aircraft });
}

/// os campos pela configuração (`parameters_for`)
fn staticParams(memory: std.mem.Allocator, aircraft: ?*const Aircraft, values: simulation.Values) ![]const simulation.Param {
    const configuration = if (aircraft) |plane| detectConfiguration(plane) else everything();
    const known = aircraft == null;
    const basics: Basics = if (aircraft) |plane| basicsOf(plane) else .{};
    const autopilot = if (aircraft) |plane| plane.autopilot else model.Autopilot{};
    const roll_kind = if (aircraft) |plane| Configuration.kind(plane, configuration.roll) else "aileron";
    var list: std.ArrayList(simulation.Param) = .empty;
    const mass_group = "Massa";
    try list.append(memory, .{ .key = "mass_source", .label = "massa do voo", .kind = .choice, .default = .{ .text = flight_mass_sources[0] }, .choices = &flight_mass_sources, .rebuild = true, .group = mass_group, .help = "a do avião; o MTOW que o modo MTOW da Missão achou para uma pista; ou a digitada" });
    const source = values.text("mass_source", flight_mass_sources[0]);
    if (std.mem.eql(u8, source, flight_mass_sources[1])) {
        const saved = if (aircraft) |plane| try savedRuns(memory, plane) else null;
        const labels: []const []const u8 = if (saved != null and saved.?.labels.len > 0) saved.?.labels else &.{"nenhum salvo"};
        try list.append(memory, .{ .key = "mtow_run", .label = "pista do MTOW", .kind = .choice, .default = .{ .text = labels[0] }, .choices = labels, .group = mass_group, .help = "distância de decolagem e MTOW achado (Desempenho → Missão, modo MTOW)" });
    } else if (std.mem.eql(u8, source, flight_mass_sources[2])) {
        try list.append(memory, .{ .key = "mass_hand", .label = "massa total", .default = .{ .number = if (aircraft != null) @round(basics.mass * 1000) / 1000 else 5.0 }, .minimum = 0.1, .maximum = 500, .unit = "kg", .group = mass_group, .help = "o que passa da massa do avião entra como massa no CG" });
    }
    const flight = "Voo";
    const approval = "Critérios de aprovação";
    const cg_group = "Faixa de CG";
    const analyses = "Análises";
    try list.append(memory, .{ .key = "V", .label = "velocidade de cruzeiro", .default = .{ .number = @round(basics.cruise * 10) / 10 }, .minimum = 3, .maximum = 80, .unit = "m/s", .group = flight });
    try list.append(memory, .{ .key = "CL_frac", .label = "C_L no pouso", .default = .{ .number = 0.9 }, .minimum = 0.3, .maximum = 1.0, .group = flight, .help = "fração do C_Lmax que o profundor tem de equilibrar no pouso" });
    const has_gear = known or hasGear(aircraft.?);
    if (known or (has_gear and configuration.pitch != null)) {
        try list.append(memory, .{ .key = "roll_takeoff", .label = "decola rodando sobre o trem", .kind = .bool, .default = .{ .toggle = true }, .group = flight, .help = "desmarque se a aeronave é lançada à mão/catapulta: a rotação deixa de limitar o CG" });
        try list.append(memory, .{ .key = "theta_dd", .label = "aceleração de arfagem na rotação", .default = .{ .number = 10 }, .minimum = 1, .maximum = 40, .unit = "°/s²", .group = flight, .help = "aceleração angular pedida no trem principal em V_R" });
    }
    if (configuration.yaw != null) try list.append(memory, .{ .key = "Vw", .label = "vento cruzado (−1: 0,2 V_S)", .default = .{ .number = -1 }, .minimum = -1, .maximum = 20, .unit = "m/s", .group = flight, .help = "−1 usa 0,2 V_S (FAR 23.233)" });
    const norm = values.text("norm", norms[0]);
    try list.append(memory, .{ .key = "norm", .label = "critérios dos modos e da rolagem", .kind = .choice, .default = .{ .text = norms[0] }, .choices = &norms, .group = approval, .rebuild = true, .help = "MIL-F-8785C: nível 1 pela classe e fase; personalizado: ligue e digite cada critério; nenhuma: só mostra os valores (a norma pode não valer para o tipo de aeronave)" });
    if (std.mem.eql(u8, norm, norms[1])) {
        const base = qualities.mil8785c(.I, .B);
        for (criterion_groups) |group| {
            const use_key = try std.fmt.allocPrint(memory, "use_{s}", .{group.key});
            try list.append(memory, .{ .key = use_key, .label = try std.fmt.allocPrint(memory, "verificar {s}", .{group.label}), .kind = .bool, .default = .{ .toggle = true }, .group = approval, .rebuild = true });
            if (values.toggle(use_key, true)) for (group.fields) |field| {
                try list.append(memory, .{ .key = try std.fmt.allocPrint(memory, "crit_{s}", .{field.key}), .label = field.label, .default = .{ .number = criterionValue(base, field.field) }, .minimum = 0, .unit = field.unit, .group = approval });
            };
        }
    } else if (!std.mem.startsWith(u8, norm, "nenhuma")) {
        try list.append(memory, .{ .key = "cls", .label = "classe do avião", .kind = .choice, .default = .{ .text = "I" }, .choices = &class_labels, .group = approval, .help = "I: pequeno e leve; II: médio; III: grande; IV: alta manobrabilidade" });
        try list.append(memory, .{ .key = "cat", .label = "fase de voo", .kind = .choice, .default = .{ .text = "B" }, .choices = &phase_labels, .group = approval, .help = "A: manobras e precisão; B: subida, cruzeiro, descida; C: decolagem, aproximação, pouso" });
    }
    try list.append(memory, .{ .key = "SM_min", .label = "margem estática mínima", .default = .{ .number = 5 }, .minimum = 0, .maximum = 40, .unit = "% CMA", .group = approval, .help = "limite traseiro do CG (Raymer cap. 16; Sadraey cap. 6)" });
    try list.append(memory, .{ .key = "SM_max", .label = "margem estática máxima", .default = .{ .number = 15 }, .minimum = 1, .maximum = 60, .unit = "% CMA", .group = approval });
    try list.append(memory, .{ .key = "de_max", .label = "curso máximo de arfagem", .default = .{ .number = autopilot.de_max }, .minimum = 1, .maximum = 60, .unit = "°", .group = approval });
    if (configuration.roll != null) try list.append(memory, .{ .key = "da_max", .label = "curso máximo de rolagem", .default = .{ .number = autopilot.da_max }, .minimum = 1, .maximum = 60, .unit = "°", .group = approval });
    if (configuration.yaw != null) try list.append(memory, .{ .key = "dr_max", .label = "curso máximo do leme", .default = .{ .number = autopilot.dr_max }, .minimum = 1, .maximum = 60, .unit = "°", .group = approval });
    if (known or !(configuration.payload or configuration.liquid)) {
        try list.append(memory, .{ .key = "cg_var", .label = "variação prevista do CG (±)", .default = .{ .number = 2 }, .minimum = 0, .maximum = 30, .unit = "% CMA", .group = cg_group, .help = "sem carga lançável nem líquido, a variação do CG é informada" });
    } else {
        try list.append(memory, .{ .key = "cg_margin", .label = "folga de CG (±)", .default = .{ .number = 2 }, .minimum = 0, .maximum = 20, .unit = "% CMA", .group = cg_group, .help = "a variação com/sem carga e líquido é calculada" });
    }
    if (configuration.htail != null) try list.append(memory, .{ .key = "size_tail", .label = "dimensionar o EH", .kind = .bool, .default = .{ .toggle = true }, .group = analyses, .help = "área do EH pela faixa de CG" });
    if (!known and configuration.tailless()) {
        try list.append(memory, .{ .key = "size_elevon", .label = "dimensionar o elevon", .kind = .bool, .default = .{ .toggle = true }, .group = analyses, .help = "corda × envergadura" });
        try list.append(memory, .{ .key = "washout", .label = "calcular a torção", .kind = .bool, .default = .{ .toggle = true }, .group = analyses, .help = "torção na ponta para C_m0 > 0" });
    }
    if (std.mem.eql(u8, roll_kind, "aileron")) try list.append(memory, .{ .key = "eta_o", .label = "aileron: fim (fração da semiasa)", .default = .{ .number = 0.95 }, .minimum = 0.5, .maximum = 1.0, .group = analyses });
    try list.append(memory, .{ .key = "Vs_list", .label = "velocidades da análise dinâmica", .kind = .floats, .default = .{ .text = try speedListText(memory, basics.cruise) }, .unit = "m/s", .group = analyses });
    try list.append(memory, .{ .key = "whatif", .label = "procurar a correção", .kind = .bool, .default = .{ .toggle = true }, .group = analyses, .help = "refaz a análise com deriva maior / mais diedro / EH maior para dizer quanto mudar" });
    try list.append(memory, .{ .key = "resp", .label = "mostrar respostas no tempo", .kind = .bool, .default = .{ .toggle = false }, .group = analyses });
    if (!known and configuration.liquid) try list.append(memory, .{ .key = "slosh_lin", .label = "sloshing no modelo linear", .kind = .bool, .default = .{ .toggle = false }, .group = analyses, .help = "refaz os polos com o líquido dos tanques oscilando (pêndulo equivalente, Abramson SP-106): aparecem os modos do líquido e quanto os do avião se deslocam" });
    const refine = simulation.refine_group ++ ": estabilidade";
    try list.appendSlice(memory, &.{
        .{ .key = "cm_a0", .label = "C_m(α): α inicial", .default = .{ .number = -6 }, .minimum = -30, .maximum = 30, .unit = "°", .group = refine },
        .{ .key = "cm_a1", .label = "C_m(α): α final", .default = .{ .number = 20 }, .minimum = -30, .maximum = 60, .unit = "°", .group = refine },
        .{ .key = "cm_passo", .label = "C_m(α): passo", .default = .{ .number = 0.5 }, .minimum = 0.01, .maximum = 5, .unit = "°", .group = refine },
        .{ .key = "eh_tamanhos", .label = "tesoura: tamanhos de EH testados", .default = .{ .number = 18 }, .minimum = 2, .maximum = 200, .group = refine, .help = "o diagrama tesoura (limites do CG × área da EH) refaz os limites com a EH multiplicada por k, em tantos valores de k" },
        .{ .key = "eh_k0", .label = "tesoura: menor k da EH", .default = .{ .number = 0.3 }, .minimum = 0.05, .maximum = 1, .group = refine },
        .{ .key = "eh_k1", .label = "tesoura: maior k da EH", .default = .{ .number = 2 }, .minimum = 1, .maximum = 10, .group = refine },
        .{ .key = "resp_tempo", .label = "respostas no tempo: duração", .default = .{ .number = 12 }, .minimum = 0.5, .maximum = 300, .unit = "s", .group = refine },
        .{ .key = "resp_passo", .label = "respostas no tempo: passo", .default = .{ .number = 0.01 }, .minimum = 0.0001, .maximum = 1, .unit = "s", .group = refine },
    });
    if (std.mem.eql(u8, roll_kind, "elevon")) try list.appendSlice(memory, &.{
        .{ .key = "rolagem_bissecoes", .label = "elevon na rolagem: bisseções", .default = .{ .number = 40 }, .minimum = 1, .maximum = 200, .group = refine, .help = "a deflexão que dá a rolagem exigida sai de uma busca por metades entre 0 e a deflexão máxima testada" },
        .{ .key = "rolagem_delta_max", .label = "elevon na rolagem: deflexão máxima testada", .default = .{ .number = 60 }, .minimum = 5, .maximum = 90, .unit = "°", .group = refine },
    });
    if (configuration.tailless()) try list.appendSlice(memory, &.{
        .{ .key = "cl0_a0", .label = "C_L zero: α inicial da varredura", .default = .{ .number = -8 }, .minimum = -30, .maximum = 0, .unit = "°", .group = refine, .help = "asa voadora: o α de C_L = 0 (onde se mede o C_m0) é o primeiro da varredura com C_L ≥ 0" },
        .{ .key = "cl0_a1", .label = "C_L zero: α final da varredura", .default = .{ .number = 10 }, .minimum = 0, .maximum = 30, .unit = "°", .group = refine },
        .{ .key = "cl0_passo", .label = "C_L zero: passo", .default = .{ .number = 0.05 }, .minimum = 0.001, .maximum = 1, .unit = "°", .group = refine },
        .{ .key = "elevon_cordas", .label = "dimensionar elevon: cordas testadas (c_e/c)", .kind = .floats, .default = .{ .text = "0.2, 0.25, 0.3, 0.35, 0.4" }, .group = refine },
        .{ .key = "elevon_inicios", .label = "dimensionar elevon: começos testados (fração da semiasa)", .kind = .floats, .default = .{ .text = "0.2, 0.35, 0.5, 0.65" }, .group = refine },
    });
    try list.appendSlice(memory, &simulation.method_params);
    return list.items;
}

fn hasGear(aircraft: *const Aircraft) bool {
    var session = Session.open(aircraft, null, .{}) catch return true;
    defer session.close();
    return session.instance.p.n_gear > 0;
}

/// as sete velocidades da dinâmica, de 0,75 a 1,5 vez a de cruzeiro, arredondadas (`np.round(np.linspace(...))`)
fn speedListText(memory: std.mem.Allocator, cruise_speed: f64) ![]const u8 {
    var parts: [7][]const u8 = undefined;
    for (&parts, 0..) |*part, k| {
        const speed = 0.75 * cruise_speed + (1.5 - 0.75) * cruise_speed * @as(f64, @floatFromInt(k)) / 6.0;
        part.* = try general(memory, roundHalfEven(speed));
    }
    return std.mem.join(memory, ", ", &parts);
}

/// o arredondamento do numpy (metade para o par)
fn roundHalfEven(value: f64) f64 {
    const floor = @floor(value);
    const rest = value - floor;
    if (rest > 0.5) return floor + 1;
    if (rest < 0.5) return floor;
    return if (@mod(floor, 2) == 0) floor else floor + 1;
}

fn criterionValue(criteria: qualities.Criteria, comptime_field: []const u8) f64 {
    inline for (@typeInfo(qualities.Criteria).@"struct".fields) |field| {
        if (field.type == f64 and std.mem.eql(u8, field.name, comptime_field)) return @field(criteria, field.name);
    }
    return 0;
}

fn setCriterion(criteria: *qualities.Criteria, wanted_field: []const u8, value: f64) void {
    inline for (@typeInfo(qualities.Criteria).@"struct".fields) |field| {
        if (field.type == f64 and std.mem.eql(u8, field.name, wanted_field)) @field(criteria, field.name) = value;
    }
}

/// os critérios do formulário (`_criteria`)
fn criteriaFrom(values: simulation.Values) struct { criteria: qualities.Criteria, source: []const u8 } {
    const norm = values.text("norm", norms[0]);
    if (std.mem.eql(u8, norm, norms[1])) {
        var criteria = qualities.mil8785c(.I, .B);
        criteria.from_norm = false;
        criteria.used = .initEmpty();
        var key_buffer: [64]u8 = undefined;
        for (criterion_groups) |group| {
            const use_key = std.fmt.bufPrint(&key_buffer, "use_{s}", .{group.key}) catch continue;
            if (values.toggle(use_key, true)) criteria.used.insert(group.check);
            for (group.fields) |field| {
                const key = std.fmt.bufPrint(&key_buffer, "crit_{s}", .{field.key}) catch continue;
                setCriterion(&criteria, field.field, values.number(key, criterionValue(criteria, field.field)));
            }
        }
        return .{ .criteria = criteria, .source = "definido na aba" };
    }
    if (std.mem.startsWith(u8, norm, "nenhuma")) return .{ .criteria = qualities.noCriteria(), .source = "nenhum critério (só valores)" };
    const class = std.meta.stringToEnum(qualities.Class, values.text("cls", "I")) orelse .I;
    const phase = std.meta.stringToEnum(qualities.Phase, values.text("cat", "B")) orelse .B;
    return .{ .criteria = qualities.mil8785c(class, phase), .source = "" };
}

/// a fonte dos critérios da MIL-F-8785C, com a classe e a fase
fn criteriaSource(memory: std.mem.Allocator, criteria: qualities.Criteria, given: []const u8) ![]const u8 {
    if (given.len > 0) return given;
    return std.fmt.allocPrint(memory, "MIL-F-8785C, classe {s}, fase {s}, nível 1", .{ @tagName(criteria.class), @tagName(criteria.phase) });
}

// ------------------------------------------------------------------ os gráficos

fn staticPlot(key: []const u8, plot_title: []const u8, xlabel: []const u8, ylabel: []const u8) simulation.Plot {
    return .{ .key = key, .title = plot_title, .xlabel = xlabel, .ylabel = ylabel };
}

fn pitchWord(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "elevator")) return "profundor";
    if (std.mem.eql(u8, kind, "elevon")) return "elevon";
    if (std.mem.eql(u8, kind, "ruddervator")) return "cauda em V";
    return "comando de arfagem";
}

fn capitalized(memory: std.mem.Allocator, text: []const u8) ![]const u8 {
    const copy = try memory.dupe(u8, text);
    if (copy.len > 0) copy[0] = std.ascii.toUpper(copy[0]);
    return copy;
}

/// os gráficos pela configuração (`plots_for`)
fn staticPlots(memory: std.mem.Allocator, aircraft: ?*const Aircraft, values: simulation.Values) ![]const simulation.Plot {
    const configuration = if (aircraft) |plane| detectConfiguration(plane) else everything();
    const known = aircraft == null;
    const pitch_kind = if (aircraft) |plane| Configuration.kind(plane, configuration.pitch) else "elevator";
    const roll_kind = if (aircraft) |plane| Configuration.kind(plane, configuration.roll) else "aileron";
    const pitch = pitchWord(pitch_kind);
    const cg_x = "posição do CG (% da CMA, a partir do bordo de ataque)";
    var list: std.ArrayList(simulation.Plot) = .empty;
    try list.appendSlice(memory, &.{
        staticPlot("me", "Margem estática × posição do CG — onde o CG pode ficar", cg_x, "margem estática (% CMA)"),
        staticPlot("de", try std.fmt.allocPrint(memory, "Deflexão do {s} para equilibrar × posição do CG (tracejado: fim do curso)", .{pitch}), cg_x, try std.fmt.allocPrint(memory, "δ {s} (°)", .{pitch})),
        staticPlot("cm", "Momento de arfagem × ângulo de ataque no CG — tem de descer (estável); onde cruza o zero é o equilíbrio", "α (°)", "C_m"),
        staticPlot("trim", try std.fmt.allocPrint(memory, "{s} de equilíbrio × velocidade — deve crescer com V (estável com o comando fixo)", .{try capitalized(memory, pitch)}), "V (m/s)", try std.fmt.allocPrint(memory, "δ {s} (°)", .{pitch})),
        staticPlot("cnb", "Guinada × derrapagem: C_n(β) tem de subir (volta ao vento)", "β (°)", "C_n"),
        staticPlot("clb", "Rolamento × derrapagem: C_l(β) tem de descer (efeito diedro)", "β (°)", "C_l"),
    });
    if (configuration.htail != null) try list.append(memory, staticPlot("eh", "Área do EH × posição do CG — a faixa de CG prevista tem de caber entre os limites", "área do EH / área da asa (S_h/S)", cg_x));
    if (known or configuration.tailless()) try list.appendSlice(memory, &.{
        staticPlot("wo", "Asa voadora: C_m0 × torção na ponta — precisa ficar acima de zero", "torção extra na ponta (°, negativo = washout)", "C_m0"),
        staticPlot("wc", "Asa voadora: C_L máximo equilibrado × torção na ponta", "torção extra na ponta (°)", "C_L equilibrado"),
        staticPlot("es", "Asa voadora: C_L máximo equilibrado × tamanho do elevon", "início do elevon (fração da semiasa)", "C_L equilibrado"),
    });
    try list.appendSlice(memory, &.{
        staticPlot("zeta", "Amortecimento dos modos oscilatórios × V (tracejado: mínimo do nível 1)", "V (m/s)", "ζ"),
        staticPlot("tempo", "Rolamento (constante de tempo) e espiral (tempo para dobrar) × V", "V (m/s)", "s"),
        staticPlot("polos", "Polos dos modos", "Re λ (1/s)", "Im λ (rad/s)"),
        staticPlot("polos_lentos", "Polos lentos", "Re λ (1/s)", "Im λ (rad/s)"),
    });
    if (!known and configuration.liquid and values.toggle("slosh_lin", false)) try list.append(memory, staticPlot("liquido", "Polos com o líquido", "Re λ (1/s)", "Im λ (rad/s)"));
    if (!known and configuration.payload) try list.append(memory, staticPlot("solta", "Polos ao soltar a carga", "Re λ (1/s)", "Im λ (rad/s)"));
    if (std.mem.eql(u8, roll_kind, "aileron")) try list.append(memory, staticPlot("ail", "Aileron: tempo para inclinar × onde o aileron começa (tracejado: requisito)", "início do aileron (fração da semiasa)", "t (s)"));
    if (!known and std.mem.eql(u8, roll_kind, "elevon")) try list.append(memory, staticPlot("elv", "Elevon: curso para equilibrar + curso para rolar × V (tracejado: máximo)", "V (m/s)", "δ (°)"));
    if (std.mem.eql(u8, pitch_kind, "elevator") or std.mem.eql(u8, pitch_kind, "ruddervator")) try list.append(memory, staticPlot("prof", try std.fmt.allocPrint(memory, "{s}: deflexão para pousar e rodar × corda móvel", .{try capitalized(memory, pitch)}), "corda móvel / corda da superfície", "δ (°)"));
    if (configuration.yaw != null) try list.append(memory, staticPlot("leme", "Leme: deflexão em vento cruzado × corda do leme", "corda do leme / corda da deriva", "δ (°)"));
    try list.appendSlice(memory, &.{
        staticPlot("rlon", "Resposta a um doublet de 2° no comando de arfagem", "t (s)", "°/s, °, m/s"),
        staticPlot("rlat", "Resposta a um pulso de 5° no comando de rolagem", "t (s)", "°/s, °, m/s"),
    });
    return list.items;
}

// ------------------------------------------------------------------ a rodada

/// as etapas da rodada, uma fatia por passo (a tela mostra o progresso entre elas)
const StaticStage = enum { longitudinal, tailless, tail_area, dynamic, liquid, payload, verdict, done };

/// uma velocidade da análise dinâmica: o polo de cada modo (NaN onde não há)
const DynamicRow = struct {
    speed: f64,
    real: std.EnumArray(qualities.Mode, f64),
    imag: std.EnumArray(qualities.Mode, f64),
    damping: std.EnumArray(qualities.Mode, f64), // só dos que oscilam
    roll_tau: f64,
    spiral_double: f64, // só da espiral instável
};

/// um estilo de curva (os `_dash`, `_color`, `_symbol`... das séries do Python)
const Style = struct {
    dashed: bool = false,
    color: ?[]const u8 = null,
    marker: []const u8 = "",
    size: f64 = 0,
    line: bool = false,
    legend: bool = true,
    width: f64 = 0,
    vspan: bool = false,
};

const StaticState = struct {
    stage: StaticStage = .longitudinal,
    values: simulation.Values = .{},
    plane: Aircraft = undefined,
    loading: ?mission.Loading = null,
    chosen: core.methods.Methods = .{},
    configuration: Configuration = .{},
    criteria: qualities.Criteria = .{},
    criteria_source: []const u8 = "",
    figures: simulation.Figures = undefined,
    summary: std.ArrayList([2][]const u8) = .empty,
    checks: std.ArrayList(simulation.Check) = .empty,
    // o voo e os limites
    airspeed: f64 = 15,
    elevator_max: f64 = 0,
    aileron_max: f64 = 0,
    rudder_max: f64 = 0,
    margin_min: f64 = 5,
    margin_max: f64 = 15,
    theta_dd: f64 = 10,
    stall: f64 = 0,
    landing_speed: f64 = 0,
    landing_lift: f64 = 0,
    rotation_speed: ?f64 = null,
    cg_low: f64 = 0,
    cg_high: f64 = 0,
    pitch_name: []const u8 = "—",
    fin_word: []const u8 = "deriva",
    // a tesoura e a dinâmica, um passo por fatia
    step: usize = 0,
    tail_factors: []f64 = &.{},
    tail_limits: []sizing.Limits = &.{},
    speeds: []const f64 = &.{},
    rows: std.ArrayList(DynamicRow) = .empty,
    moving: std.ArrayList(DynamicRow) = .empty, // com o líquido oscilando
    liquid_poles: std.ArrayList([3]f64) = .empty, // (V, Re, Im) dos modos do líquido
    dropped: std.ArrayList(DynamicRow) = .empty, // sem a carga
};

fn startStatic(run: *simulation.Run, state: *StaticState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    state.values = values;
    state.chosen = values.methods();
    state.plane = run.aircraft.*;
    const basics = basicsOf(run.aircraft);
    // a massa do voo
    const source = values.text("mass_source", flight_mass_sources[0]);
    if (std.mem.eql(u8, source, flight_mass_sources[1])) {
        const saved = try savedRuns(memory, run.aircraft);
        const wanted = values.text("mtow_run", "");
        var found: ?mission.SavedMtow = null;
        for (saved.labels, saved.runs) |label, entry| if (std.mem.eql(u8, label, wanted)) {
            found = entry;
        };
        if (found == null and saved.runs.len > 0 and wanted.len == 0) found = saved.runs[0];
        if (found) |entry| {
            state.loading = entry.loading;
            try state.checks.append(memory, .{ .status = .info, .item = "massa do voo", .value = try std.fmt.allocPrint(memory, "{d:.2} kg", .{entry.mass}), .criterion = wanted, .why = try std.fmt.allocPrint(memory, "a do avião é {d:.2} kg", .{basics.mass}), .group = "Massa" });
        } else {
            try state.checks.append(memory, .{ .status = .falha, .item = "massa do voo", .value = "nenhum MTOW salvo", .criterion = "MTOW de uma pista", .why = "ainda não há MTOW salvo para este avião", .fix = "rodar Desempenho → Missão no modo MTOW com a pista desejada", .group = "Massa" });
            state.figures = try simulation.Figures.init(memory, &.{});
            state.stage = .done;
            return;
        }
    } else if (std.mem.eql(u8, source, flight_mass_sources[2])) {
        const mass = values.number("mass_hand", basics.mass);
        state.loading = .{ .mass = mass };
        try state.checks.append(memory, .{ .status = .info, .item = "massa do voo", .value = try std.fmt.allocPrint(memory, "{d:.2} kg", .{@max(mass, basics.mass)}), .criterion = source, .why = try std.fmt.allocPrint(memory, "a do avião é {d:.2} kg", .{basics.mass}), .group = "Massa" });
    }
    state.configuration = detectConfiguration(&state.plane);
    state.figures = try simulation.Figures.init(memory, try staticPlots(memory, &state.plane, values));
    const chosen = criteriaFrom(values);
    state.criteria = chosen.criteria;
    state.criteria_source = try criteriaSource(memory, chosen.criteria, chosen.source);
    try state.summary.append(memory, .{ "critérios", state.criteria_source });
    const autopilot = state.plane.autopilot;
    state.airspeed = values.number("V", @round(basics.cruise * 10) / 10);
    state.elevator_max = values.number("de_max", autopilot.de_max) * rad;
    state.aileron_max = values.number("da_max", autopilot.da_max) * rad;
    state.rudder_max = values.number("dr_max", autopilot.dr_max) * rad;
    state.margin_min = values.number("SM_min", 5);
    state.margin_max = values.number("SM_max", 15);
    var speed_buffer: [32]f64 = undefined;
    const fallback_speeds = try parseSpeeds(memory, try speedListText(memory, basics.cruise));
    state.speeds = try memory.dupe(f64, values.numbers("Vs_list", &speed_buffer, fallback_speeds));
    const configuration = state.configuration;
    if (configuration.pitch == null) try state.checks.append(memory, .{ .status = .falha, .item = "comando de arfagem", .value = "nenhum", .criterion = "profundor, elevon ou cauda em V", .why = "sem EH e sem elevon não há como equilibrar nem controlar em arfagem", .fix = "transformar os ailerons em elevons (Configuração → asa → comandos → tipo 'elevon') ou adicionar uma EH", .group = "estática longitudinal" });
    try state.summary.append(memory, .{ "configuração", try configurationSummary(memory, &state.plane, configuration) });
    if (configuration.wing == null) {
        state.checks.clearRetainingCapacity();
        try state.checks.append(memory, .{ .status = .falha, .item = "asa", .value = "nenhuma", .criterion = "a aeronave precisa de uma asa" });
        state.stage = .done;
        return;
    }
    state.pitch_name = blk: {
        const kind = Configuration.kind(&state.plane, configuration.pitch);
        if (std.mem.eql(u8, kind, "elevator")) break :blk "profundor";
        if (std.mem.eql(u8, kind, "elevon")) break :blk "elevon";
        if (std.mem.eql(u8, kind, "ruddervator")) break :blk "cauda em V";
        break :blk "—";
    };
    state.fin_word = if (configuration.fin_count > 0) "deriva" else if (configuration.tip_count > 0) "winglets/derivas de ponta" else "deriva";
}

fn parseSpeeds(memory: std.mem.Allocator, text: []const u8) ![]const f64 {
    var list: std.ArrayList(f64) = .empty;
    var pieces = std.mem.tokenizeAny(u8, text, ", ;");
    while (pieces.next()) |piece| try list.append(memory, std.fmt.parseFloat(f64, piece) catch continue);
    return list.items;
}

fn advanceStatic(run: *simulation.Run, state: *StaticState) simulation.Error!bool {
    switch (state.stage) {
        .longitudinal => {
            run.say("estática longitudinal, látero-direcional e comandos", .{});
            run.progress = 0.02;
            try longitudinal(run, state);
            state.stage = .tailless;
        },
        .tailless => {
            if (state.configuration.tailless()) {
                run.say("asa voadora: torção na ponta e tamanho do elevon", .{});
                run.progress = 0.42;
                try tailless(run, state);
            }
            state.stage = .tail_area;
            state.step = 0;
        },
        .tail_area => {
            if (state.configuration.htail == null or !state.values.toggle("size_tail", true)) {
                state.stage = .dynamic;
                state.step = 0;
                return false;
            }
            run.progress = 0.45;
            if (try tailAreaStep(run, state)) {
                state.stage = .dynamic;
                state.step = 0;
            }
        },
        .dynamic => {
            if (state.step < state.speeds.len) {
                const speed = state.speeds[state.step];
                run.say("modelo linear em V = {d:.1} m/s", .{speed});
                run.progress = @floatCast(0.6 + 0.25 * @as(f64, @floatFromInt(state.step)) / @as(f64, @floatFromInt(@max(state.speeds.len, 1))));
                if (modesAt(&state.plane, state.loading, state.chosen, speed)) |found| try state.rows.append(run.memory(), rowOf(speed, found.modes));
                state.step += 1;
            } else {
                try dynamicSeries(run.memory(), state);
                state.stage = .liquid;
                state.step = 0;
            }
        },
        .liquid => {
            if (!(state.configuration.liquid and state.values.toggle("slosh_lin", false)) or state.rows.items.len == 0) {
                state.stage = .payload;
                state.step = 0;
                return false;
            }
            run.say("modelo linear com o líquido oscilando", .{});
            run.progress = 0.83;
            if (state.step < state.rows.items.len) {
                try liquidStep(run.memory(), state, state.rows.items[state.step]);
                state.step += 1;
            } else {
                try liquidSeries(run.memory(), state);
                state.stage = .payload;
                state.step = 0;
            }
        },
        .payload => {
            if (!state.configuration.payload or state.rows.items.len == 0) {
                state.stage = .verdict;
                return false;
            }
            run.say("modelo linear sem a carga", .{});
            run.progress = 0.85;
            if (state.step < state.rows.items.len) {
                const speed = state.rows.items[state.step].speed;
                const dropped = withoutPayload(&state.plane);
                const found = modesAt(&dropped, state.loading, state.chosen, speed);
                try state.dropped.append(run.memory(), if (found) |modes| rowOf(speed, modes.modes) else emptyRow(speed));
                state.step += 1;
            } else {
                try releaseSeries(run.memory(), state, state.rows.items, state.dropped.items, "solta", .{ "com carga", "sem carga" });
                if (try releaseCheck(run.memory(), state.rows.items, state.dropped.items, state.airspeed, "polos ao soltar a carga", "sem a carga a massa, o CG e a inércia mudam, e os modos se deslocam (gráfico 'Polos ao soltar a carga')")) |item| try addCheck(run.memory(), state, item);
                state.stage = .verdict;
            }
        },
        .verdict => {
            run.say("modos contra os critérios", .{});
            run.progress = 0.95;
            try verdict(run, state);
            state.stage = .done;
        },
        .done => return true,
    }
    return state.stage == .done;
}

fn emptyRow(speed: f64) DynamicRow {
    const nan = std.math.nan(f64);
    return .{ .speed = speed, .real = .initFill(nan), .imag = .initFill(nan), .damping = .initFill(nan), .roll_tau = nan, .spiral_double = nan };
}

fn rowOf(speed: f64, found: qualities.Modes) DynamicRow {
    var row = emptyRow(speed);
    for (all_modes) |mode| if (found.get(mode)) |pole| {
        row.real.set(mode, pole.real);
        row.imag.set(mode, pole.imag);
        if (pole.imag > 0) row.damping.set(mode, pole.damping);
    };
    if (found.get(.roll)) |pole| row.roll_tau = pole.time_constant;
    if (found.get(.spiral)) |pole| if (pole.real > 0) {
        row.spiral_double = pole.double_time;
    };
    return row;
}

// ------------------------------------------------------------------ as curvas e o diagnóstico

/// uma curva no gráfico `key`; sem cor, a próxima da paleta do gráfico
fn addCurve(state: *StaticState, key: []const u8, curve_name: []const u8, x: []const f64, y: []const f64, style: Style) !void {
    const figure = state.figures.get(key) orelse return;
    const color = style.color orelse speed_palette[figure.curves.items.len % speed_palette.len];
    // a cópia na arena da rodada: as séries podem vir de um buffer da pilha (a varredura do CG, por exemplo)
    const memory = state.figures.memory;
    try figure.curves.append(memory, .{ .name = curve_name, .x = try memory.dupe(f64, x), .y = try memory.dupe(f64, y), .color = color, .dashed = style.dashed, .marker = style.marker, .size = style.size, .line = style.line, .legend = style.legend, .width = style.width, .vspan = style.vspan });
}

/// uma reta de dois pontos
fn segment(memory: std.mem.Allocator, first: f64, last: f64) ![]const f64 {
    const pair = try memory.alloc(f64, 2);
    pair[0] = first;
    pair[1] = last;
    return pair;
}

/// um item do diagnóstico com a fonte separada do critério (`_short`): "critério (Raymer cap. 16)" vira o critério
/// curto e a fonte
fn addCheck(memory: std.mem.Allocator, state: *StaticState, item: simulation.Check) !void {
    var short = item;
    if (short.source.len == 0) if (sourceSplit(item.criterion)) |parts| {
        short.criterion = parts[0];
        short.source = parts[1];
    };
    try state.checks.append(memory, short);
}

const source_words = [_][]const u8{ "MIL", "Raymer", "Sadraey", "Etkin", "Nelson", "FAR", "Torenbeek", "Nickel", "Munk", "Kroo" };

fn sourceSplit(criterion: []const u8) ?[2][]const u8 {
    const trimmed = std.mem.trimEnd(u8, criterion, " ");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return null;
    const open = std.mem.lastIndexOfScalar(u8, trimmed, '(') orelse return null;
    const inside = trimmed[open + 1 .. trimmed.len - 1];
    if (std.mem.indexOfAny(u8, inside, "()") != null) return null;
    for (source_words) |word| if (std.mem.indexOf(u8, inside, word) != null) {
        return .{ std.mem.trimEnd(u8, trimmed[0..open], " "), inside };
    };
    return null;
}

fn numberText(memory: std.mem.Allocator, value: f64) ![]const u8 {
    if (!std.math.isFinite(value)) return "—";
    return std.fmt.allocPrint(memory, "{d:.4}", .{value});
}

fn numbersText(memory: std.mem.Allocator, values: []const f64) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (values) |value| try parts.append(memory, try numberText(memory, value));
    return std.mem.join(memory, ", ", parts.items);
}

fn nanMin(values: []const f64) f64 {
    var low = std.math.inf(f64);
    for (values) |value| if (std.math.isFinite(value)) {
        low = @min(low, value);
    };
    return low;
}

fn nanMax(values: []const f64) f64 {
    var high = -std.math.inf(f64);
    for (values) |value| if (std.math.isFinite(value)) {
        high = @max(high, value);
    };
    return high;
}

/// a inclinação da reta dos mínimos quadrados (`np.polyfit(x, y, 1)[0]`)
fn slopeOf(xs: []const f64, ys: []const f64) f64 {
    var count: f64 = 0;
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    for (xs, ys) |x_value, y_value| {
        sum_x += x_value;
        sum_y += y_value;
        count += 1;
    }
    const mean_x = sum_x / count;
    const mean_y = sum_y / count;
    var top: f64 = 0;
    var bottom: f64 = 0;
    for (xs, ys) |x_value, y_value| {
        top += (x_value - mean_x) * (y_value - mean_y);
        bottom += (x_value - mean_x) * (x_value - mean_x);
    }
    return top / bottom;
}

fn linspace(memory: std.mem.Allocator, low: f64, high: f64, count: usize) ![]f64 {
    const out = try memory.alloc(f64, count);
    for (out, 0..) |*value, i| value.* = if (count > 1) low + (high - low) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count - 1)) else low;
    return out;
}

fn arange(memory: std.mem.Allocator, low: f64, high: f64, step_size: f64) ![]f64 {
    var list: std.ArrayList(f64) = .empty;
    var k: usize = 0;
    while (true) : (k += 1) {
        const value = low + step_size * @as(f64, @floatFromInt(k));
        if ((step_size > 0 and value >= high) or (step_size < 0 and value <= high)) break;
        try list.append(memory, value);
    }
    return list.items;
}

// ------------------------------------------------------------------ 1, 3 e 5a: estática longitudinal, látero-direcional e comandos

/// a distância em mm de uma fração da CMA
fn millimeters(percent: f64, chord: f64) f64 {
    return @abs(percent) / 100 * chord * 1000;
}

/// o CG (% CMA) de uma variação do avião
fn centerOf(aircraft: *const Aircraft, state: *const StaticState) !f64 {
    var session = try Session.open(aircraft, state.loading, state.chosen);
    defer session.close();
    return session.probe.fraction(session.probe.cg[0]);
}

fn longitudinal(run: *simulation.Run, state: *StaticState) !void {
    const memory = run.memory();
    const values = state.values;
    const configuration = state.configuration;
    var session = Session.open(&state.plane, state.loading, state.chosen) catch |err| {
        run.fail("o avião não montou no núcleo ({s})", .{@errorName(err)});
        return error.Failed;
    };
    defer session.close();
    const probe = &session.probe;
    const chord = probe.chord;
    const airspeed = state.airspeed;
    const pitch_name = state.pitch_name;
    var group: []const u8 = "estática longitudinal";

    // ---- o estol, o pouso e a rotação
    const lift_max = probe.liftMax(15, 0);
    const stall = probe.stallSpeed(lift_max);
    state.stall = stall;
    state.landing_speed = 1.3 * stall;
    const lift_fraction = values.number("CL_frac", 0.9);
    state.landing_lift = lift_fraction * lift_max;
    const has_gear = session.instance.p.n_gear > 0;
    if (has_gear and configuration.pitch != null) state.rotation_speed = if (state.plane.takeoff.VR > 0) state.plane.takeoff.VR else 1.1 * stall;
    const rotation_speed = state.rotation_speed;
    state.theta_dd = if (rotation_speed != null) values.number("theta_dd", 10) else 10;
    try state.summary.append(memory, .{ "C_Lmax, V_estol, V_pouso (1,3 V_S)", try numbersText(memory, &.{ lift_max, stall, state.landing_speed }) });

    // ---- o CG nas condições (com e sem a carga e o líquido) e a faixa prevista
    const cg_now = probe.fraction(probe.cg[0]);
    var condition_names: std.ArrayList([]const u8) = .empty;
    var condition_values: std.ArrayList(f64) = .empty;
    try condition_names.append(memory, "atual");
    try condition_values.append(memory, cg_now);
    if (configuration.payload) {
        try condition_names.append(memory, "sem carga");
        try condition_values.append(memory, try centerOf(&withoutPayload(&state.plane), state));
    }
    if (configuration.liquid) {
        const dry = withoutLiquid(&state.plane);
        try condition_names.append(memory, "sem líquido");
        try condition_values.append(memory, try centerOf(&dry, state));
        if (configuration.payload) {
            try condition_names.append(memory, "sem carga e sem líquido");
            try condition_values.append(memory, try centerOf(&withoutPayload(&dry), state));
        }
    }
    if (configuration.payload or configuration.liquid) {
        const spare = values.number("cg_margin", 2);
        state.cg_low = nanMin(condition_values.items) - spare;
        state.cg_high = nanMax(condition_values.items) + spare;
    } else {
        const spare = values.number("cg_var", 2);
        state.cg_low = cg_now - spare;
        state.cg_high = cg_now + spare;
    }
    const cg_low = state.cg_low;
    const cg_high = state.cg_high;
    {
        var parts: std.ArrayList([]const u8) = .empty;
        for (condition_names.items, condition_values.items) |label, value| try parts.append(memory, try std.fmt.allocPrint(memory, "{s}: {d:.2}", .{ label, value }));
        try state.summary.append(memory, .{ "CG nas condições (% CMA)", try std.mem.join(memory, ", ", parts.items) });
    }
    try state.summary.append(memory, .{ "faixa de CG prevista (% CMA)", try numbersText(memory, &.{ cg_low, cg_high }) });

    // ---- o ponto neutro, a margem e a varredura do CG
    const neutral = probe.fraction(probe.neutralPoint(airspeed));
    const references = params_mod.references(&state.plane);
    const analytic = probe.fraction(analyticNeutralPoint(&state.plane, references[0], references[1]));
    const margin = neutral - cg_now;
    try state.summary.append(memory, .{ "ponto neutro: núcleo, analítico (% CMA)", try numbersText(memory, &.{ neutral, analytic }) });
    try state.summary.append(memory, .{ "margem estática no CG atual (% CMA)", try numberText(memory, margin) });
    const grid = try linspace(memory, @min(cg_low, neutral - 45) - 5, neutral + 8, 45);
    var sweep: sizing.Sweep = .{};
    sizing.cgSweep(probe, grid, airspeed, state.landing_speed, state.landing_lift, rotation_speed orelse 0, state.theta_dd, &sweep);
    const cg_axis = sweep.cg[0..sweep.count];
    const margins = sweep.margin[0..sweep.count];
    const landing = sweep.landing[0..sweep.count];
    const cruise_elevator = sweep.cruise[0..sweep.count];
    const rotation = sweep.rotation[0..sweep.count];
    const limit_deg = state.elevator_max / rad;
    const forward_landing = sizing.limitCrossing(cg_axis, landing, limit_deg);
    const forward_rotation = if (rotation_speed != null) sizing.limitCrossing(cg_axis, rotation, limit_deg) else null;
    const forward_cruise = sizing.limitCrossing(cg_axis, cruise_elevator, limit_deg);
    const use_rotation = rotation_speed != null and values.toggle("roll_takeoff", true);
    var forward: ?f64 = null;
    for ([_]?f64{ forward_landing, if (use_rotation) forward_rotation else null, forward_cruise }) |candidate| if (candidate) |value| {
        forward = if (forward) |best| @max(best, value) else value;
    };
    const aft = neutral - state.margin_min;
    try state.summary.append(memory, .{ "limites de CG: dianteiro, traseiro (% CMA)", try std.fmt.allocPrint(memory, "{s}, {s}", .{ if (forward) |value| try numberText(memory, value) else "—", try numberText(memory, aft) }) });

    const ends = try segment(memory, cg_axis[0], cg_axis[cg_axis.len - 1]);
    try addCurve(state, "me", "margem estática", cg_axis, margins, .{});
    try addCurve(state, "me", try std.fmt.allocPrint(memory, "mínima ({s} %)", .{try general(memory, state.margin_min)}), ends, try segment(memory, state.margin_min, state.margin_min), .{ .dashed = true });
    try addCurve(state, "me", try std.fmt.allocPrint(memory, "máxima recomendada ({s} %)", .{try general(memory, state.margin_max)}), ends, try segment(memory, state.margin_max, state.margin_max), .{ .dashed = true });
    const margin_range = try segment(memory, nanMin(margins), nanMax(margins));
    for (condition_names.items, condition_values.items) |label, value| try addCurve(state, "me", try std.fmt.allocPrint(memory, "CG {s}", .{label}), try segment(memory, value, value), margin_range, .{});
    try addCurve(state, "de", try std.fmt.allocPrint(memory, "pouso (C_L = {d:.2})", .{state.landing_lift}), cg_axis, landing, .{});
    try addCurve(state, "de", try std.fmt.allocPrint(memory, "cruzeiro (V = {s} m/s)", .{try general(memory, airspeed)}), cg_axis, cruise_elevator, .{});
    if (rotation_speed) |speed| try addCurve(state, "de", try std.fmt.allocPrint(memory, "rotação (V_R = {d:.1} m/s)", .{speed}), cg_axis, rotation, .{});
    try addCurve(state, "de", "fim do curso", ends, try segment(memory, -limit_deg, -limit_deg), .{ .dashed = true });
    try addCurve(state, "de", "fim do curso (picar)", ends, try segment(memory, limit_deg, limit_deg), .{ .dashed = true });
    var deflection_low = @min(nanMin(landing), nanMin(cruise_elevator));
    var deflection_high = @max(nanMax(landing), nanMax(cruise_elevator));
    deflection_low = @min(deflection_low, -limit_deg);
    deflection_high = @max(deflection_high, limit_deg);
    const deflection_range = try segment(memory, deflection_low, deflection_high);
    try addCurve(state, "de", "CG atual", try segment(memory, cg_now, cg_now), deflection_range, .{});
    for ([_]struct { label: []const u8, value: ?f64 }{ .{ .label = "limite dianteiro", .value = forward }, .{ .label = "limite traseiro", .value = aft } }) |line| if (line.value) |value| {
        const curve_name = try std.fmt.allocPrint(memory, "{s} ({d:.1} %)", .{ line.label, value });
        try addCurve(state, "me", curve_name, try segment(memory, value, value), margin_range, .{ .dashed = true });
        try addCurve(state, "de", curve_name, try segment(memory, value, value), deflection_range, .{ .dashed = true });
    };

    // ---- a margem no CG atual
    const margin_criterion = try std.fmt.allocPrint(memory, "{s} % ≤ ME ≤ {s} % da CMA (Raymer cap. 16; Sadraey cap. 6)", .{ try general(memory, state.margin_min), try general(memory, state.margin_max) });
    const margin_value = try std.fmt.allocPrint(memory, "{d:.1} % (CG {d:.1} %, ponto neutro {d:.1} %)", .{ margin, cg_now, neutral });
    const margin_item = "margem estática no CG atual";
    if (margin < 0) {
        try addCheck(memory, state, .{ .status = .falha, .item = margin_item, .value = margin_value, .criterion = margin_criterion, .why = try std.fmt.allocPrint(memory, "o CG está {d:.0} mm atrás do ponto neutro: um aumento de α gera momento cabrador e o avião diverge em arfagem", .{millimeters(margin, chord)}), .fix = try std.fmt.allocPrint(memory, "levar o CG {d:.0} mm para frente (até {d:.1} % da CMA) ou aumentar o {s}", .{ millimeters(margin - state.margin_min, chord), aft, if (configuration.htail != null) "EH/braço da cauda (ver área do EH abaixo)" else "enflechamento/torção da ponta" }), .group = group });
    } else if (margin < state.margin_min) {
        try addCheck(memory, state, .{ .status = .atencao, .item = margin_item, .value = margin_value, .criterion = margin_criterion, .why = "estável, mas pouca margem: rajadas e erro de CG podem deixá-lo neutro", .fix = try std.fmt.allocPrint(memory, "levar o CG {d:.0} mm para frente (até {d:.1} %)", .{ millimeters(state.margin_min - margin, chord), aft }), .group = group });
    } else if (margin > state.margin_max) {
        try addCheck(memory, state, .{ .status = .atencao, .item = margin_item, .value = margin_value, .criterion = margin_criterion, .why = try std.fmt.allocPrint(memory, "estável demais: o {s} gasta curso para equilibrar e o avião fica pesado no comando", .{pitch_name}), .fix = try std.fmt.allocPrint(memory, "o CG pode ir {d:.0} mm para trás (até {d:.1} %)", .{ millimeters(margin - state.margin_max, chord), neutral - state.margin_max }), .group = group });
    } else try addCheck(memory, state, .{ .status = .ok, .item = margin_item, .value = margin_value, .criterion = margin_criterion, .group = group });
    if (@abs(neutral - analytic) > 8) try addCheck(memory, state, .{ .status = .info, .item = "ponto neutro: núcleo × fórmula clássica", .value = try std.fmt.allocPrint(memory, "{d:.1} % × {d:.1} %", .{ neutral, analytic }), .criterion = "diferença > 8 % da CMA", .why = "a fórmula (Etkin/Nelson) usa dε/dα da teoria e ignora interação da fuselagem com a asa; o núcleo usa a mesma física da simulação", .group = group });

    // ---- a faixa de CG
    const limit_text = try general(memory, limit_deg);
    if (forward) |front| {
        const why_front: []const u8 = if (forward_landing != null and front == forward_landing.?) "equilibrar o pouso" else if (forward_rotation != null and front == forward_rotation.?) "rodar na decolagem" else "equilibrar o cruzeiro";
        const range_text = try std.fmt.allocPrint(memory, "permitido {d:.1} … {d:.1} %; previsto {d:.1} … {d:.1} %", .{ front, aft, cg_low, cg_high });
        const criterion = try std.fmt.allocPrint(memory, "dianteiro: {s} no fim do curso ({s}°); traseiro: margem {s} %", .{ pitch_name, limit_text, try general(memory, state.margin_min) });
        var problems: std.ArrayList([]const u8) = .empty;
        if (cg_low < front) try problems.append(memory, try std.fmt.allocPrint(memory, "o CG mais dianteiro previsto ({d:.1} %) está {d:.0} mm à frente do limite: o {s} não consegue {s}", .{ cg_low, millimeters(front - cg_low, chord), pitch_name, why_front }));
        if (cg_high > aft) try problems.append(memory, try std.fmt.allocPrint(memory, "o CG mais traseiro previsto ({d:.1} %) está {d:.0} mm atrás do limite de margem mínima", .{ cg_high, millimeters(cg_high - aft, chord) }));
        var fix: []const u8 = "";
        if (aft <= front) {
            fix = try std.fmt.allocPrint(memory, "não existe CG que atenda os dois limites: o limite dianteiro ({s}, {d:.1} %) está atrás do traseiro ({d:.1} %). Ver os itens de pouso/rotação abaixo", .{ why_front, front, aft });
        } else if (aft - front < cg_high - cg_low) {
            fix = try std.fmt.allocPrint(memory, "a faixa permitida ({d:.1} %) é menor que a prevista ({d:.1} %): {s}", .{ aft - front, cg_high - cg_low, if (configuration.htail != null) "aumentar o EH (ver área do EH) ou o comando de arfagem" else "reduzir a variação do CG (posição dos tanques/carga perto do CG) ou aumentar o elevon" });
        } else if (problems.items.len > 0) {
            const shift = (front + aft) / 2 - (cg_low + cg_high) / 2;
            fix = try std.fmt.allocPrint(memory, "a faixa cabe: deslocar todo o CG {d:.0} mm {s} centraliza a faixa prevista", .{ millimeters(shift, chord), if (shift > 0) "para trás" else "para frente" });
        }
        try addCheck(memory, state, .{ .status = if (problems.items.len > 0) .falha else .ok, .item = "faixa de CG prevista dentro da permitida", .value = range_text, .criterion = criterion, .why = try std.mem.join(memory, "; ", problems.items), .fix = fix, .group = group });
    } else try addCheck(memory, state, .{ .status = .falha, .item = "limite dianteiro do CG", .value = "nenhum CG equilibra", .criterion = try std.fmt.allocPrint(memory, "|δ {s}| ≤ {s}° no pouso, cruzeiro e rotação", .{ pitch_name, limit_text }), .why = try std.fmt.allocPrint(memory, "o {s} não tem autoridade para equilibrar em nenhuma posição de CG analisada", .{pitch_name}), .fix = try std.fmt.allocPrint(memory, "aumentar a área/corda do {s} ou o braço; ou rever δ máximo ({s}°)", .{ pitch_name, limit_text }), .group = group });

    // ---- o C_L máximo equilibrado no CG mais dianteiro e o pouso
    const trimmed_max = probe.trimmedLiftMax(state.landing_speed, probe.xAt(cg_low), state.elevator_max);
    if (std.math.isFinite(trimmed_max)) {
        const trimmed_stall = @sqrt(2 * probe.weight / (probe.density * probe.area * trimmed_max));
        try state.summary.append(memory, .{ "C_Lmax equilibrado (CG dianteiro), V_estol equilibrada", try numbersText(memory, &.{ trimmed_max, trimmed_stall }) });
        const status: @TypeOf(@as(simulation.Check, undefined).status) = if (trimmed_max >= state.landing_lift) .ok else if (trimmed_max >= 0.75 * state.landing_lift) .atencao else .falha;
        const good = status == .ok;
        try addCheck(memory, state, .{
            .status = status,
            .item = try std.fmt.allocPrint(memory, "C_L de pouso equilibrado pelo {s} (CG {d:.1} %)", .{ pitch_name, cg_low }),
            .value = try std.fmt.allocPrint(memory, "máx. {d:.2} (pedido {d:.2} = {s} C_Lmax); V_estol equilibrada {d:.1} m/s", .{ trimmed_max, state.landing_lift, try general(memory, lift_fraction), trimmed_stall }),
            .criterion = try std.fmt.allocPrint(memory, "C_L equilibrado ≥ C_L de pouso com |δ| ≤ {s}°", .{limit_text}),
            .why = if (good) "" else try std.fmt.allocPrint(memory, "para equilibrar, o {s} cabra e {s}; o comando chega ao fim do curso antes", .{ pitch_name, if (configuration.tailless()) "tira sustentação da própria asa (asa voadora)" else "a força para baixo no EH cresce" }),
            .fix = if (good) "" else try std.fmt.allocPrint(memory, "pousar com C_L ≤ {d:.2} (V de pouso ≥ 1,3 × {d:.1} = {d:.1} m/s), levar o CG para trás ou aumentar o comando de arfagem", .{ trimmed_max, trimmed_stall, 1.3 * trimmed_stall }),
            .group = group,
        });
    }
    if (rotation_speed) |speed| {
        const acceleration = state.theta_dd;
        const now = probe.rotationElevator(speed, probe.cg[0], acceleration, null) / rad;
        const rotates = @abs(now) <= limit_deg;
        var why: []const u8 = "";
        var fix: []const u8 = "";
        if (!rotates) {
            const gear = sizing.gearForRotation(probe, speed, probe.cg[0], acceleration, state.elevator_max);
            const main_gear = probe.mainGear();
            why = try std.fmt.allocPrint(memory, "o peso à frente do trem principal ({d:.0} mm) e o {s} não vencem; θ̈ pedido {s} °/s²", .{ 1000 * (probe.cg[0] - main_gear[0]), if (configuration.tailless()) "braço curto do elevon (sem cauda)" else "momento do EH", try general(memory, acceleration) });
            if (gear.gear_x != null and gear.gear_x.? <= gear.tip_x) {
                fix = try std.fmt.allocPrint(memory, "trem principal {s} mm (x = {d:.3} m) já roda; limite de tombamento para trás (15°) em x = {d:.3} m", .{ try signedWhole(memory, 1000 * (gear.gear_x.? - main_gear[0])), gear.gear_x.?, gear.tip_x });
            } else fix = "nem o trem no limite de tombamento resolve: lançar à mão/catapulta (desmarcar 'decola rodando'), aumentar V_R ou o comando de arfagem";
        }
        try addCheck(memory, state, .{ .status = if (rotates) .ok else .falha, .item = try std.fmt.allocPrint(memory, "rotação na decolagem em V_R = {d:.1} m/s", .{speed}), .value = try std.fmt.allocPrint(memory, "δ = {d:.1}° no CG atual", .{now}), .criterion = try std.fmt.allocPrint(memory, "|δ| ≤ {s}° com θ̈ = {s} °/s² no trem principal", .{ limit_text, try general(memory, acceleration) }), .why = why, .fix = fix, .group = group });
    }

    // ---- a curva de equilíbrio × V
    var top_speed = airspeed;
    for (state.speeds) |speed| top_speed = @max(top_speed, speed);
    const trim_speeds = try arange(memory, @max(1.05 * stall, 3.0), top_speed + 0.01, 0.5);
    const trim_deflections = try memory.alloc(f64, trim_speeds.len);
    var good_speeds: std.ArrayList(f64) = .empty;
    var good_deflections: std.ArrayList(f64) = .empty;
    var saturated: std.ArrayList(f64) = .empty;
    const trim_context = core.trim.Ctx.init(&session.instance.p, &session.instance.r.f);
    for (trim_speeds, trim_deflections) |speed, *deflection| {
        const point = core.trim.solve(trim_context, .level, speed, 1.0, null);
        deflection.* = if (point.ok != 0) point.de / rad else std.math.nan(f64);
        if (point.ok != 0) {
            try good_speeds.append(memory, speed);
            try good_deflections.append(memory, point.de / rad);
            if (@abs(point.de / rad) > limit_deg) try saturated.append(memory, speed);
        }
    }
    try addCurve(state, "trim", "equilíbrio", trim_speeds, trim_deflections, .{});
    if (good_speeds.items.len >= 2) {
        const gradient = slopeOf(good_speeds.items, good_deflections.items);
        const rising = gradient > 0;
        try addCheck(memory, state, .{ .status = if (rising) .ok else .falha, .item = try std.fmt.allocPrint(memory, "{s} de equilíbrio cresce com V", .{pitch_name}), .value = try std.fmt.allocPrint(memory, "dδ/dV = {d:.2} °/(m/s)", .{gradient}), .criterion = "dδ/dV > 0 (Etkin & Reid: estabilidade com o comando fixo)", .why = if (rising) "" else "para acelerar o piloto teria de cabrar: sinal de margem negativa", .fix = if (rising) "" else "ver margem estática", .group = group });
        if (saturated.items.len > 0) try addCheck(memory, state, .{ .status = .falha, .item = try std.fmt.allocPrint(memory, "{s} satura em voo nivelado", .{pitch_name}), .value = try std.fmt.allocPrint(memory, "{d} velocidades (ex.: {d:.1} m/s)", .{ saturated.items.len, saturated.items[0] }), .criterion = try std.fmt.allocPrint(memory, "|δ| ≤ {s}°", .{limit_text}), .why = "o equilíbrio pede mais deflexão do que existe", .fix = "mover o CG para trás ou aumentar a autoridade de arfagem", .group = group });
    }
    // C_m(α)
    const alphas = try arange(memory, state.values.number("cm_a0", -6.0), state.values.number("cm_a1", 20.0) + 0.01, @max(state.values.number("cm_passo", 0.5), 0.01));
    for ([_]struct { label: []const u8, elevator: f64 }{ .{ .label = "neutro", .elevator = 0 }, .{ .label = "cabrar máximo", .elevator = -state.elevator_max }, .{ .label = "picar máximo", .elevator = state.elevator_max } }) |setting| {
        const moments = try memory.alloc(f64, alphas.len);
        for (alphas, moments) |angle, *moment| moment.* = probe.coeffs(airspeed, angle * rad, null, .{ .elevator = setting.elevator }).Cm;
        try addCurve(state, "cm", try std.fmt.allocPrint(memory, "{s} {s}", .{ pitch_name, setting.label }), alphas, moments, .{});
    }
    if (configuration.tailless()) {
        var zero_lift: ?f64 = null;
        const sweep_first = state.values.number("cl0_a0", -8.0);
        const sweep_last = state.values.number("cl0_a1", 10.0);
        const sweep_step = @max(state.values.number("cl0_passo", 0.05), 0.001);
        var k: usize = 0;
        while (k < 100_000) : (k += 1) {
            const alpha = sweep_first + sweep_step * @as(f64, @floatFromInt(k));
            if (alpha >= sweep_last) break;
            if (probe.coeffs(airspeed, alpha * rad, null, .{}).CL >= 0) {
                zero_lift = alpha * rad;
                break;
            }
        }
        const moment_zero = if (zero_lift) |alpha| probe.coeffs(airspeed, alpha, null, .{}).Cm else std.math.nan(f64);
        const positive = moment_zero > 0;
        try addCheck(memory, state, .{ .status = if (positive) .ok else .falha, .item = "asa voadora: C_m na sustentação nula (C_m0)", .value = try std.fmt.allocPrint(memory, "{d:.4}", .{moment_zero}), .criterion = "C_m0 > 0 para equilibrar com C_L > 0 e ser estável sem cauda (Nickel & Wohlfahrt, Tailless Aircraft)", .why = if (positive) "" else "o perfil/torção dá momento picador: para voar estável o elevon fica cabrado e come curso de rolagem", .fix = if (positive) "" else "perfil reflexo, mais torção negativa na ponta (washout) ou mais enflechamento", .group = group });
    } else {
        const tails = tailVolumes(&state.plane, probe.cg[0], references);
        const volumes = [2]f64{ tails.horizontal, tails.vertical };
        try state.summary.append(memory, .{ "volumes de cauda V_H, V_V", try numbersText(memory, &volumes) });
        try addCheck(memory, state, .{ .status = .info, .item = "volume de cauda horizontal V_H", .value = try std.fmt.allocPrint(memory, "{d:.3}", .{volumes[0]}), .criterion = "típicos (Raymer tab. 6.4): planador 0,50, experimental 0,50, aviação geral 0,70", .why = "referência histórica de partida; quem decide é a margem e os limites de CG acima", .group = group });
    }

    // ============ 3. estática látero-direcional
    run.progress = 0.25;
    group = "estática látero-direcional";
    const two = 2 * rad;
    const betas = try arange(memory, -15, 15.01, 1.0);
    const yawing = try memory.alloc(f64, betas.len);
    const rolling = try memory.alloc(f64, betas.len);
    for (betas, yawing, rolling) |beta, *yaw, *roll| {
        const point = probe.coeffs(airspeed, two, null, .{ .beta = beta * rad });
        yaw.* = point.Cn;
        roll.* = point.Cl;
    }
    try addCurve(state, "cnb", "beta", betas, yawing, .{});
    try addCurve(state, "clb", "beta", betas, rolling, .{});
    const sideslip = sizing.derivative(probe, airspeed, two, .beta, null, sizing.step);
    const directional = sideslip.Cn;
    const dihedral_effect = sideslip.Cl;
    const yaw_damping = sizing.yawDamping(probe, airspeed);
    const fins = configuration.finList();
    if (directional > 0) {
        try addCheck(memory, state, .{ .status = .ok, .item = "estabilidade direcional C_nβ", .value = try std.fmt.allocPrint(memory, "{d:.4} /rad", .{directional}), .criterion = "C_nβ > 0 (cata-vento)", .group = group });
    } else {
        var needed: ?f64 = null;
        if (fins.len > 0) for ([_]f64{ 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 }) |factor| {
            const bigger = try scaledSurfaces(memory, &state.plane, fins, factor);
            var variant = Session.open(&bigger, state.loading, state.chosen) catch continue;
            defer variant.close();
            if (sizing.derivative(&variant.probe, airspeed, two, .beta, null, sizing.step).Cn > 0) {
                needed = factor;
                break;
            }
        };
        try addCheck(memory, state, .{ .status = .falha, .item = "estabilidade direcional C_nβ", .value = try std.fmt.allocPrint(memory, "{d:.4} /rad", .{directional}), .criterion = "C_nβ > 0 (cata-vento)", .why = try std.fmt.allocPrint(memory, "a fuselagem ({s}/rad) e o resto desestabilizam mais do que a {s} estabiliza", .{ try std.fmt.allocPrint(memory, "{s}{d:.3}", .{ if (state.plane.fuselage.Cnb >= 0) "+" else "-", @abs(state.plane.fuselage.Cnb) }), state.fin_word }), .fix = if (needed) |factor| try std.fmt.allocPrint(memory, "área da {s} × {s} (mesma razão de aspecto) já dá C_nβ > 0", .{ state.fin_word, try general(memory, factor) }) else try std.fmt.allocPrint(memory, "aumentar a {s} (área ou braço)", .{state.fin_word}), .group = group });
    }
    const negative = dihedral_effect < 0;
    try addCheck(memory, state, .{ .status = if (negative) .ok else .falha, .item = "efeito diedro C_lβ", .value = try std.fmt.allocPrint(memory, "{d:.4} /rad", .{dihedral_effect}), .criterion = "C_lβ < 0", .why = if (negative) "" else "derrapar para um lado faz o avião rolar para o mesmo lado", .fix = if (negative) "" else "mais diedro, asa alta ou enflechamento", .group = group });
    const spiral = dihedral_effect * yaw_damping[0] - directional * yaw_damping[1];
    try addCheck(memory, state, .{ .status = if (spiral > 0) .ok else .info, .item = "critério da espiral C_lβ C_nr − C_nβ C_lr", .value = try std.fmt.allocPrint(memory, "{d:.5}", .{spiral}), .criterion = "> 0: espiral estável (Nelson, Flight Stability, cap. 5; Etkin & Reid)", .why = if (spiral > 0) "" else "efeito diedro fraco diante da estabilidade direcional: inclinado, o avião tende a fechar a curva sozinho (ver o tempo para dobrar na dinâmica — pode ser aceitável)", .group = group });

    // ============ 5a. comandos
    run.progress = 0.35;
    try controls(memory, state, &session);
}

/// o τ de um comando (o do arquivo ou o do perfil fino pela corda)
fn effectivenessOf(control: model.Control) f64 {
    return control.tau orelse aircraft_model.airfoil.flapEffectiveness(control.chord_frac);
}

/// a semiasa como o aileron a vê: o C_Lα, o comprimento e as seções
fn wingStrip(memory: std.mem.Allocator, aircraft: *const Aircraft, wing: usize) !sizing.WingStrip {
    const surface = &aircraft.surfaces[wing];
    var buffer: [model.limits.sections]model.Section = undefined;
    const sections = model.sortedSections(surface, &buffer);
    const ys = try memory.alloc(f64, sections.len);
    const chords = try memory.alloc(f64, sections.len);
    for (sections, 0..) |section, i| {
        ys[i] = section.y;
        chords[i] = section.chord;
    }
    const coefficients = params_mod.coeffs(surface) catch return error.Failed;
    return .{ .lift_slope = coefficients.CLa, .length = ys[ys.len - 1] - ys[0], .y = ys, .chord = chords };
}

fn controls(memory: std.mem.Allocator, state: *StaticState, session: *const Session) !void {
    const probe = &session.probe;
    const configuration = state.configuration;
    const values = state.values;
    const group = "comandos";
    const requirement = [2]f64{ state.criteria.roll_angle, state.criteria.roll_time };
    const roll_speed = if (state.criteria.phase == .C) state.landing_speed else state.airspeed;
    const aileron_deg = state.aileron_max / rad;
    const roll_kind = Configuration.kind(&state.plane, configuration.roll);
    const roll_on = state.criteria.on(.roll);
    if (std.mem.eql(u8, roll_kind, "aileron")) {
        const strip = try wingStrip(memory, &state.plane, configuration.wing.?);
        var chord_effectiveness: [sizing.aileron_chords.len]f64 = undefined;
        for (sizing.aileron_chords, 0..) |chord_fraction, k| chord_effectiveness[k] = aircraft_model.airfoil.flapEffectiveness(chord_fraction);
        const sized = sizing.aileronSizing(probe, roll_speed, strip, state.aileron_max, values.number("eta_o", 0.95), chord_effectiveness, requirement, .{ .start = 0, .end = 0, .effectiveness = 0 });
        for (sizing.aileron_chords, 0..) |chord_fraction, k| try addCurve(state, "ail", try std.fmt.allocPrint(memory, "ca/c={d:.2}", .{chord_fraction}), &sizing.aileron_starts, try memory.dupe(f64, &sized.times[k]), .{});
        const required = try memory.alloc(f64, sizing.aileron_starts.len);
        @memset(required, requirement[1]);
        try addCurve(state, "ail", "requisito", &sizing.aileron_starts, required, .{ .dashed = true });
        const criterion = try std.fmt.allocPrint(memory, "{s}° em ≤ {s} s (δa {s}°)", .{ try general(memory, requirement[0]), try general(memory, requirement[1]), try general(memory, aileron_deg) });
        if (!roll_on) {
            try addCheck(memory, state, .{ .status = .info, .item = try std.fmt.allocPrint(memory, "aileron: tempo para inclinar {s}°", .{try general(memory, requirement[0])}), .value = try std.fmt.allocPrint(memory, "{d:.2} s (p = {d:.0} °/s)", .{ sized.current_time, sized.current_rate }), .criterion = "—", .group = group });
        } else if (sized.current_time <= requirement[1]) {
            try addCheck(memory, state, .{ .status = .ok, .item = "aileron: rolagem", .value = try std.fmt.allocPrint(memory, "{d:.2} s (p = {d:.0} °/s a {d:.1} m/s)", .{ sized.current_time, sized.current_rate, roll_speed }), .criterion = criterion, .group = group, .source = state.criteria_source });
        } else {
            var parts: std.ArrayList([]const u8) = .empty;
            for (sizing.aileron_chords, 0..) |chord_fraction, k| if (std.math.isFinite(sized.best_start[k])) {
                try parts.append(memory, try std.fmt.allocPrint(memory, "ca/c={d:.2}: começar em {d:.2} da semiasa", .{ chord_fraction, sized.best_start[k] }));
            };
            const fix = if (parts.items.len > 0) try std.mem.join(memory, "; ", parts.items) else "aumentar corda/envergadura do aileron ou o curso";
            try addCheck(memory, state, .{ .status = .falha, .item = "aileron: rolagem", .value = try std.fmt.allocPrint(memory, "{d:.2} s", .{sized.current_time}), .criterion = criterion, .why = "C_lδa pequeno diante do amortecimento C_lp (aileron curto, perto da raiz ou corda pequena)", .fix = fix, .group = group, .source = state.criteria_source });
        }
    } else if (std.mem.eql(u8, roll_kind, "elevon")) {
        // o curso do elevon se divide entre equilibrar (arfagem) e rolar
        const damping = sizing.rollDamping(probe, roll_speed);
        const control_slope = sizing.derivative(probe, roll_speed, 2 * rad, .aileron, null, sizing.step).Cl;
        const speeds = try linspace(memory, @max(1.1 * state.stall, 3), 1.5 * state.airspeed, 12);
        const trim_part = try memory.alloc(f64, speeds.len);
        const roll_part = try memory.alloc(f64, speeds.len);
        const total = try memory.alloc(f64, speeds.len);
        const trim_context = core.trim.Ctx.init(&session.instance.p, &session.instance.r.f);
        for (speeds, 0..) |speed, i| {
            const point = core.trim.solve(trim_context, .level, speed, 1.0, null);
            trim_part[i] = if (point.ok != 0) @abs(point.de / rad) else std.math.nan(f64);
            const dynamic_pressure = 0.5 * probe.density * speed * speed;
            const time_constant = -2 * speed * probe.inertia[0][0] / (dynamic_pressure * probe.area * probe.span * probe.span * damping);
            var bisection: core.optim.scalar.Bisection = .{ .low = 0, .high = state.values.number("rolagem_delta_max", 60) * rad };
            for (0..@intFromFloat(@max(@round(state.values.number("rolagem_bissecoes", 40)), 1))) |_| {
                const middle = bisection.middle();
                const rate = -(control_slope / damping) * middle * 2 * speed / probe.span;
                bisection.move(middle, if (sizing.timeToBank(rate, time_constant, requirement[0] * rad) > requirement[1]) .raise else .lower);
            }
            roll_part[i] = bisection.high / rad;
            total[i] = trim_part[i] + roll_part[i];
        }
        try addCurve(state, "elv", "equilíbrio", speeds, trim_part, .{});
        try addCurve(state, "elv", "rolagem exigida", speeds, roll_part, .{});
        try addCurve(state, "elv", "soma", speeds, total, .{});
        const top = try memory.alloc(f64, speeds.len);
        @memset(top, aileron_deg);
        try addCurve(state, "elv", "máximo", speeds, top, .{ .dashed = true });
        var bad_low = std.math.inf(f64);
        var bad_high = -std.math.inf(f64);
        for (speeds, total) |speed, sum| if (std.math.isFinite(sum) and sum > aileron_deg) {
            bad_low = @min(bad_low, speed);
            bad_high = @max(bad_high, speed);
        };
        const criterion = try std.fmt.allocPrint(memory, "equilíbrio + rolagem ({s}° em {s} s) ≤ {s}°", .{ try general(memory, requirement[0]), try general(memory, requirement[1]), try general(memory, aileron_deg) });
        if (!roll_on) {
            try addCheck(memory, state, .{ .status = .info, .item = "elevon: curso usado no equilíbrio", .value = try std.fmt.allocPrint(memory, "máx. {d:.1}° de {s}°", .{ nanMax(trim_part), try general(memory, aileron_deg) }), .criterion = "—", .group = group });
        } else if (bad_low <= bad_high) {
            try addCheck(memory, state, .{ .status = .falha, .item = "elevon: curso para arfagem + rolagem", .value = try std.fmt.allocPrint(memory, "excede de {d:.1} a {d:.1} m/s", .{ bad_low, bad_high }), .criterion = criterion, .why = "nessas velocidades o equilíbrio come o curso que a rolagem precisa", .fix = "elevon com mais corda/envergadura, CG mais para trás (menos δ de equilíbrio) ou C_m0 maior (reflexo/washout)", .group = group });
        } else try addCheck(memory, state, .{ .status = .ok, .item = "elevon: curso para arfagem + rolagem", .value = try std.fmt.allocPrint(memory, "máx. {d:.1}° de {s}°", .{ nanMax(total), try general(memory, aileron_deg) }), .criterion = criterion, .group = group });
    } else try addCheck(memory, state, .{ .status = .falha, .item = "comando de rolagem", .value = "nenhum", .criterion = "aileron ou elevon", .fix = "adicionar ailerons", .group = group });

    const pitch_kind = Configuration.kind(&state.plane, configuration.pitch);
    if ((std.mem.eql(u8, pitch_kind, "elevator") or std.mem.eql(u8, pitch_kind, "ruddervator")) and state.rotation_speed != null) {
        const reference = configuration.pitch.?;
        const control = state.plane.surfaces[reference.surface].controls[reference.control];
        const now = effectivenessOf(control);
        var scale: [sizing.control_ratios.len]f64 = undefined;
        for (sizing.control_ratios, 0..) |ratio, i| scale[i] = aircraft_model.airfoil.flapEffectiveness(ratio) / now;
        const sized = sizing.elevatorSizing(probe, state.landing_speed, state.rotation_speed.?, state.cg_low, state.landing_lift, state.elevator_max, state.theta_dd, scale);
        try addCurve(state, "prof", "pouso", &sizing.control_ratios, try memory.dupe(f64, &sized.landing), .{});
        try addCurve(state, "prof", "rotação", &sizing.control_ratios, try memory.dupe(f64, &sized.rotation), .{});
        const end_line = try memory.alloc(f64, sizing.control_ratios.len);
        @memset(end_line, -state.elevator_max / rad);
        try addCurve(state, "prof", "fim do curso", &sizing.control_ratios, end_line, .{ .dashed = true });
        const enough = std.math.isFinite(sized.smallest) and control.chord_frac >= sized.smallest;
        const limit_text = try general(memory, state.elevator_max / rad);
        try addCheck(memory, state, .{
            .status = if (enough) .ok else .falha,
            .item = try std.fmt.allocPrint(memory, "{s}: corda móvel (CG mais dianteiro {d:.1} %)", .{ state.pitch_name, state.cg_low }),
            .value = try std.fmt.allocPrint(memory, "atual {d:.2}; mínima {s}", .{ control.chord_frac, try shortNumber(memory, sized.smallest) }),
            .criterion = try std.fmt.allocPrint(memory, "δ para pousar e rodar ≤ {s}°", .{limit_text}),
            .why = if (enough) "" else "com o CG mais dianteiro previsto o comando não equilibra/roda",
            .fix = if (enough) "" else if (std.math.isFinite(sized.smallest)) try std.fmt.allocPrint(memory, "corda móvel ≥ {d:.2}", .{sized.smallest}) else "nenhuma corda basta: aumentar a área do EH ou trazer o CG para trás",
            .group = group,
        });
    }
    if (configuration.yaw) |reference| {
        const wind_value = values.number("Vw", -1);
        const wind = if (wind_value >= 0) wind_value else 0.2 * state.stall;
        const control = state.plane.surfaces[reference.surface].controls[reference.control];
        const now = effectivenessOf(control);
        var scale: [sizing.control_ratios.len]f64 = undefined;
        for (sizing.control_ratios, 0..) |ratio, i| scale[i] = aircraft_model.airfoil.flapEffectiveness(ratio) / now;
        const engine = try farthestEngine(state, 1.2 * state.stall);
        const sized = sizing.rudderSizing(probe, state.landing_speed, wind, 1.2 * state.stall, state.rudder_max, scale, engine);
        try addCurve(state, "leme", "vento cruzado", &sizing.control_ratios, try memory.dupe(f64, &sized.crosswind), .{});
        if (sized.engine_out) |stopped| try addCurve(state, "leme", "motor crítico parado", &sizing.control_ratios, try memory.dupe(f64, &stopped), .{});
        const end_line = try memory.alloc(f64, sizing.control_ratios.len);
        @memset(end_line, state.rudder_max / rad);
        try addCurve(state, "leme", "fim do curso", &sizing.control_ratios, end_line, .{ .dashed = true });
        const enough = sized.crosswind_now <= state.rudder_max / rad;
        try addCheck(memory, state, .{
            .status = if (enough) .ok else .falha,
            .item = "leme: vento cruzado no pouso",
            .value = try std.fmt.allocPrint(memory, "δr = {d:.1}° (β = {d:.1}°, vento {d:.1} m/s)", .{ sized.crosswind_now, sized.sideslip, wind }),
            .criterion = try std.fmt.allocPrint(memory, "δr ≤ {s}° com 0,2 V_S de través (FAR 23.233)", .{try general(memory, state.rudder_max / rad)}),
            .why = if (enough) "" else "a deriva é estável demais para o leme que tem",
            .fix = if (enough) "" else try std.fmt.allocPrint(memory, "corda do leme ≥ {d:.2}", .{sized.smallest}),
            .group = group,
        });
    } else if (!configuration.tailless() or configuration.tip_count > 0) {
        try addCheck(memory, state, .{ .status = .info, .item = "leme", .value = "nenhum", .why = "sem leme a guinada é corrigida só pela rolagem; vento cruzado no pouso fica por conta do piloto (caranguejo)", .group = group });
    }
}

/// a tração e o y do motor mais afastado do plano de simetria a V, quando há mais de um motor
fn farthestEngine(state: *const StaticState, airspeed: f64) !?[2]f64 {
    var count: usize = 0;
    var farthest: ?usize = null;
    var distance: f64 = -1;
    for (state.plane.propulsion, 0..) |unit, i| if (unit.enabled) {
        if (@abs(unit.y) > distance) {
            distance = @abs(unit.y);
            farthest = i;
        }
        count += 1;
    };
    if (count <= 1) return null;
    var session = try Session.open(&state.plane, state.loading, state.chosen);
    defer session.close();
    // o índice entre os ligados, como `prop_point(i)`
    var index: usize = 0;
    for (state.plane.propulsion[0..farthest.?]) |unit| if (unit.enabled) {
        index += 1;
    };
    const params = &session.instance.p;
    const unit = &params.prop[index];
    return .{ core.propulsion.point(params, unit, airspeed, 1).T, unit.r[1] };
}

// ------------------------------------------------------------------ 2b. asa voadora

fn tailless(run: *simulation.Run, state: *StaticState) !void {
    const memory = run.memory();
    const wing = state.configuration.wing orelse return;
    const group = "asa voadora";
    if (state.values.toggle("washout", true)) {
        const twists = try arange(memory, 0, -10.01, -1.0);
        const moments = try memory.alloc(f64, twists.len);
        const lifts = try memory.alloc(f64, twists.len);
        for (twists, moments, lifts) |twist, *moment, *lift| {
            const twisted = try withWashout(memory, &state.plane, wing, twist);
            var session = Session.open(&twisted, state.loading, state.chosen) catch {
                moment.* = std.math.nan(f64);
                lift.* = std.math.nan(f64);
                continue;
            };
            defer session.close();
            moment.* = session.probe.momentAtZeroLift(state.airspeed);
            lift.* = session.probe.trimmedLiftMax(state.landing_speed, session.probe.xAt(state.cg_low), state.elevator_max);
        }
        const ends = try segment(memory, twists[0], twists[twists.len - 1]);
        try addCurve(state, "wo", "C_m0", twists, moments, .{});
        try addCurve(state, "wo", "zero", ends, try segment(memory, 0, 0), .{ .dashed = true });
        try addCurve(state, "wc", "C_L máximo equilibrado", twists, lifts, .{});
        try addCurve(state, "wc", "C_L de pouso pedido", ends, try segment(memory, state.landing_lift, state.landing_lift), .{ .dashed = true });
        var needed: ?f64 = null;
        for (twists, moments) |twist, moment| if (moment > 0) {
            needed = twist;
            break;
        };
        const source = "Nickel & Wohlfahrt, Tailless Aircraft";
        if (moments[0] > 0) {
            try addCheck(memory, state, .{ .status = .ok, .item = "torção na ponta (washout) para C_m0 > 0", .value = try std.fmt.allocPrint(memory, "atual já dá C_m0 = {d:.4}", .{moments[0]}), .criterion = "C_m0 > 0", .group = group, .source = source });
        } else if (needed) |twist| {
            try addCheck(memory, state, .{ .status = .falha, .item = "torção na ponta (washout) para C_m0 > 0", .value = try std.fmt.allocPrint(memory, "C_m0 = {d:.4}; precisa {s}°", .{ moments[0], try general(memory, twist) }), .criterion = "C_m0 > 0", .why = "a ponta enflechada atrás do CG precisa voar com menos α para dar momento cabrador", .fix = try std.fmt.allocPrint(memory, "adicionar {s}° de torção na ponta (linear da raiz à ponta) ou usar perfil reflexo", .{try general(memory, twist)}), .group = group, .source = source });
        } else try addCheck(memory, state, .{ .status = .falha, .item = "torção na ponta (washout) para C_m0 > 0", .value = "nem −10° resolve", .criterion = "C_m0 > 0", .why = "enflechamento pequeno: a torção na ponta tem braço curto", .fix = "aumentar o enflechamento ou usar perfil reflexo", .group = group });
    }
    const pitch = state.configuration.pitch;
    if (state.values.toggle("size_elevon", true) and std.mem.eql(u8, Configuration.kind(&state.plane, pitch), "elevon")) {
        const control = state.plane.surfaces[pitch.?.surface].controls[pitch.?.control];
        var chord_buffer: [16]f64 = undefined;
        var start_buffer: [16]f64 = undefined;
        const chord_fractions = state.values.numbers("elevon_cordas", &chord_buffer, &.{ 0.20, 0.25, 0.30, 0.35, 0.40 });
        const starts = try memory.dupe(f64, state.values.numbers("elevon_inicios", &start_buffer, &.{ 0.2, 0.35, 0.5, 0.65 }));
        var best: ?[4]f64 = null; // área, corda, começo, C_L
        for (chord_fractions) |chord_fraction| {
            const lifts = try memory.alloc(f64, starts.len);
            for (starts, lifts) |start, *lift| {
                lift.* = std.math.nan(f64);
                if (start >= control.span_end - 0.05) continue;
                const changed = try withElevon(memory, &state.plane, wing, chord_fraction, start);
                var session = Session.open(&changed, state.loading, state.chosen) catch continue;
                defer session.close();
                lift.* = session.probe.trimmedLiftMax(state.landing_speed, session.probe.xAt(state.cg_low), state.elevator_max);
                const size = chord_fraction * (control.span_end - start);
                if (std.math.isFinite(lift.*) and lift.* >= state.landing_lift and (best == null or size < best.?[0])) best = .{ size, chord_fraction, start, lift.* };
            }
            try addCurve(state, "es", try std.fmt.allocPrint(memory, "c_e/c = {d:.2}", .{chord_fraction}), starts, lifts, .{});
        }
        try addCurve(state, "es", "C_L de pouso pedido", try segment(memory, starts[0], starts[starts.len - 1]), try segment(memory, state.landing_lift, state.landing_lift), .{ .dashed = true });
        const current = try std.fmt.allocPrint(memory, "c_e/c {d:.2}, de {d:.2} a {d:.2} da semiasa", .{ control.chord_frac, control.span_start, control.span_end });
        const criterion = try std.fmt.allocPrint(memory, "C_L equilibrado ≥ {d:.2} no CG dianteiro", .{state.landing_lift});
        if (best) |found| {
            const big_enough = control.chord_frac * (control.span_end - control.span_start) >= found[0] - 1e-9;
            try addCheck(memory, state, .{ .status = if (big_enough) .ok else .info, .item = "menor elevon que equilibra o pouso", .value = try std.fmt.allocPrint(memory, "c_e/c {d:.2}, início {d:.2} (atual: {s})", .{ found[1], found[2], current }), .criterion = criterion, .group = group });
        } else try addCheck(memory, state, .{ .status = .falha, .item = "menor elevon que equilibra o pouso", .value = try std.fmt.allocPrint(memory, "nenhum até c_e/c 0,40 (atual: {s})", .{current}), .criterion = criterion, .why = "sem cauda, cabrar o elevon tira sustentação da própria asa: o C_L equilibrado fica limitado", .fix = "pousar com C_L menor (reduzir 'C_L a equilibrar no pouso'), CG mais para trás, ou washout/reflexo (ver a curva × torção)", .group = group });
    }
}

// ------------------------------------------------------------------ 2. a área do EH (tesoura)


/// um tamanho de EH por fatia: os limites do CG com a EH × k (de 0,3 a 2); verdadeiro quando acabou
fn tailAreaStep(run: *simulation.Run, state: *StaticState) !bool {
    const memory = run.memory();
    const tail_steps: usize = @intFromFloat(@max(@round(state.values.number("eh_tamanhos", 18)), 2));
    if (state.step == 0) {
        run.say("área do EH × faixa de CG", .{});
        state.tail_factors = try linspace(memory, state.values.number("eh_k0", 0.3), state.values.number("eh_k1", 2.0), tail_steps);
        state.tail_limits = try memory.alloc(sizing.Limits, tail_steps);
    }
    if (state.step < tail_steps) {
        var htails: std.ArrayList(usize) = .empty;
        for (state.plane.surfaces, 0..) |surface, i| if (std.mem.eql(u8, surface.role, "htail")) try htails.append(memory, i);
        const scaled = try scaledSurfaces(memory, &state.plane, htails.items, state.tail_factors[state.step]);
        var session = Session.open(&scaled, state.loading, state.chosen) catch |err| {
            run.fail("a EH × {d:.2} não montou no núcleo ({s})", .{ state.tail_factors[state.step], @errorName(err) });
            return error.Failed;
        };
        defer session.close();
        const rotation_speed = state.rotation_speed orelse 1.1 * state.stall;
        const acceleration: f64 = if (state.rotation_speed != null) state.theta_dd else 0;
        state.tail_limits[state.step] = sizing.scissorLimits(&session.probe, state.airspeed, state.margin_min / 100, state.values.number("CL_frac", 0.9), state.elevator_max, rotation_speed, acceleration);
        state.step += 1;
        return false;
    }
    // as curvas e o diagnóstico
    const references = params_mod.references(&state.plane);
    var tail_area: f64 = 0;
    for (state.plane.surfaces) |*surface| if (surface.enabled and std.mem.eql(u8, surface.role, "htail")) {
        tail_area += params_mod.area(surface);
    };
    const ratios = try memory.alloc(f64, tail_steps);
    const neutral = try memory.alloc(f64, tail_steps);
    const aft = try memory.alloc(f64, tail_steps);
    const control_limit = try memory.alloc(f64, tail_steps);
    const rotation_limit = try memory.alloc(f64, tail_steps);
    const forward = try memory.alloc(f64, tail_steps);
    var nearest: usize = 0;
    for (state.tail_limits, 0..) |limits, i| {
        ratios[i] = state.tail_factors[i] * tail_area / references[0];
        neutral[i] = limits.neutral;
        aft[i] = limits.aft;
        control_limit[i] = limits.forward_control;
        rotation_limit[i] = limits.forward_rotation;
        forward[i] = if (state.rotation_speed != null) limits.forward else limits.forward_control;
        if (@abs(state.tail_factors[i] - 1) < @abs(state.tail_factors[nearest] - 1)) nearest = i;
    }
    try addCurve(state, "eh", "limite dianteiro (pouso)", ratios, control_limit, .{});
    if (state.rotation_speed != null) try addCurve(state, "eh", "limite dianteiro (rotação)", ratios, rotation_limit, .{});
    try addCurve(state, "eh", try std.fmt.allocPrint(memory, "limite traseiro (margem {s} %)", .{try general(memory, state.margin_min)}), ratios, aft, .{});
    try addCurve(state, "eh", "ponto neutro", ratios, neutral, .{ .dashed = true });
    for ([_]struct { label: []const u8, value: f64 }{ .{ .label = "CG mais dianteiro previsto", .value = state.cg_low }, .{ .label = "CG mais traseiro previsto", .value = state.cg_high } }) |line| {
        try addCurve(state, "eh", line.label, try segment(memory, ratios[0], ratios[tail_steps - 1]), try segment(memory, line.value, line.value), .{ .dashed = true });
    }
    const now = ratios[nearest];
    const smallest = sizing.minTail(ratios, forward, aft, state.cg_low, state.cg_high);
    try state.summary.append(memory, .{ "S_h/S: atual, mínimo para a faixa de CG", try numbersText(memory, &.{ now, smallest }) });
    const group = "área do EH";
    const item = "área do EH para a faixa de CG";
    if (!std.math.isFinite(smallest)) {
        try addCheck(memory, state, .{ .status = .falha, .item = item, .value = try std.fmt.allocPrint(memory, "atual {d:.3}; nenhuma até {d:.3}", .{ now, ratios[tail_steps - 1] }), .criterion = "a faixa prevista cabe entre os limites dianteiro e traseiro", .why = "a faixa de CG prevista é larga demais para qualquer EH analisado (ou o comando é fraco)", .fix = "reduzir a variação do CG (tanques/carga perto do CG) ou aumentar o braço da cauda", .group = group });
    } else if (smallest > now) {
        try addCheck(memory, state, .{ .status = .falha, .item = item, .value = try std.fmt.allocPrint(memory, "atual {d:.3} < mínimo {d:.3}", .{ now, smallest }), .criterion = "a faixa prevista cabe entre os limites (Torenbeek cap. 9; Sadraey cap. 6)", .why = "com o EH atual a faixa de CG prevista não cabe entre estabilidade e controle", .fix = try std.fmt.allocPrint(memory, "aumentar a área do EH em {d:.0} % (S_h/S ≥ {d:.3}) ou o braço", .{ 100 * (smallest / now - 1), smallest }), .group = group });
    } else {
        const spare = now > 1.3 * smallest;
        try addCheck(memory, state, .{ .status = .ok, .item = item, .value = try std.fmt.allocPrint(memory, "atual {d:.3} ≥ mínimo {d:.3}", .{ now, smallest }), .criterion = "a faixa prevista cabe entre os limites (Torenbeek cap. 9; Sadraey cap. 6)", .why = if (spare) try std.fmt.allocPrint(memory, "sobra {d:.0} % de área", .{100 * (1 - smallest / now)}) else "", .fix = if (spare) try std.fmt.allocPrint(memory, "dá para reduzir o EH até S_h/S = {d:.3} (menos arrasto e massa)", .{smallest}) else "", .group = group });
    }
    return true;
}

// ------------------------------------------------------------------ 4. a dinâmica

fn rowColumn(memory: std.mem.Allocator, rows: []const DynamicRow, comptime field: []const u8, mode: ?qualities.Mode) ![]f64 {
    const out = try memory.alloc(f64, rows.len);
    for (rows, out) |row, *value| value.* = if (@TypeOf(@field(row, field)) == f64) @field(row, field) else @field(row, field).get(mode.?);
    return out;
}

/// o amortecimento, os tempos e os polos das velocidades da análise
fn dynamicSeries(memory: std.mem.Allocator, state: *StaticState) !void {
    const rows = state.rows.items;
    if (rows.len == 0) return;
    const speeds = try memory.alloc(f64, rows.len);
    for (rows, speeds) |row, *speed| speed.* = row.speed;
    const ends = try segment(memory, speeds[0], speeds[speeds.len - 1]);
    const criteria = state.criteria;
    for ([_]struct { mode: qualities.Mode, limit: f64 }{ .{ .mode = .short_period, .limit = criteria.short_period_min }, .{ .mode = .phugoid, .limit = criteria.phugoid_min }, .{ .mode = .dutch_roll, .limit = criteria.dutch_damping_min } }) |entry| {
        const label = flight_mode_label.get(entry.mode);
        try addCurve(state, "zeta", label, speeds, try rowColumn(memory, rows, "damping", entry.mode), .{});
        try addCurve(state, "zeta", try std.fmt.allocPrint(memory, "mínimo {s}", .{label}), ends, try segment(memory, entry.limit, entry.limit), .{ .dashed = true });
    }
    try addCurve(state, "tempo", "rolamento τ", speeds, try rowColumn(memory, rows, "roll_tau", null), .{});
    try addCurve(state, "tempo", "espiral: tempo para dobrar", speeds, try rowColumn(memory, rows, "spiral_double", null), .{});
    try addCurve(state, "tempo", "espiral mínimo", ends, try segment(memory, criteria.spiral_double_min, criteria.spiral_double_min), .{ .dashed = true });
    try addCurve(state, "tempo", "rolamento máximo", ends, try segment(memory, criteria.roll_tau_max, criteria.roll_tau_max), .{ .dashed = true });
    try poleSeries(memory, state, rows, &all_modes, "polos");
    try poleSeries(memory, state, rows, &slow_modes, "polos_lentos");
}

/// o mapa dos polos: λ = Re + i Im de cada modo em cada V (a metade de cima do plano), a faixa instável (Re > 0) e as
/// retas de ζ constante dos mínimos; um polo λ = −ζ ω_n ± i ω_n √(1 − ζ²) fica na reta que sai da origem com
/// cos θ = ζ (Etkin e Reid, Dynamics of Flight, cap. 6; a conferir no PDF), como `_pole_series`
fn poleSeries(memory: std.mem.Allocator, state: *StaticState, rows: []const DynamicRow, modes: []const qualities.Mode, key: []const u8) !void {
    var reach: f64 = 0;
    var right: f64 = 0;
    var high: f64 = 0;
    var any = false;
    for (modes) |mode| {
        var reals: std.ArrayList(f64) = .empty;
        var imags: std.ArrayList(f64) = .empty;
        for (rows) |row| {
            const real = row.real.get(mode);
            const imag = row.imag.get(mode);
            if (!std.math.isFinite(real) or !std.math.isFinite(imag)) continue;
            try reals.append(memory, real);
            try imags.append(memory, imag);
            reach = @max(reach, std.math.hypot(real, imag));
            if (!any) right = real;
            right = @max(right, real);
            high = @max(high, imag);
            any = true;
        }
        if (reals.items.len == 0) continue;
        try addCurve(state, key, flight_mode_label.get(mode), reals.items, imags.items, .{ .color = flight_mode_color.get(mode), .marker = flight_mode_marker.get(mode), .line = true, .size = 9 });
    }
    if (!any) return;
    const span = 1.1 * @max(reach, 1e-3);
    try addCurve(state, key, "instável (Re > 0)", try segment(memory, 0, @max(right, 0) + 0.08 * span), try segment(memory, 0, 0), .{ .vspan = true, .color = "#d62728" });
    for ([_]struct { mode: qualities.Mode, damping: f64 }{ .{ .mode = .short_period, .damping = state.criteria.short_period_min }, .{ .mode = .phugoid, .damping = state.criteria.phugoid_min }, .{ .mode = .dutch_roll, .damping = state.criteria.dutch_damping_min } }) |entry| {
        if (std.mem.indexOfScalar(qualities.Mode, modes, entry.mode) == null) continue;
        if (!(entry.damping > 0 and entry.damping < 1)) continue;
        const top = 1.15 * @max(high, 1e-3);
        const length = top / @sqrt(1 - entry.damping * entry.damping);
        try addCurve(state, key, try std.fmt.allocPrint(memory, "ζ = {s} ({s})", .{ try general(memory, entry.damping), flight_mode_label.get(entry.mode) }), try segment(memory, 0, -entry.damping * length), try segment(memory, 0, top), .{ .color = flight_mode_color.get(entry.mode), .dashed = true, .width = 1.0 });
    }
}

/// os polos de dois modelos, um par por V ligado por um traço fino (`_release_series`): com a carga e sem ela, ou com
/// o líquido parado e oscilando
fn releaseSeries(memory: std.mem.Allocator, state: *StaticState, before: []const DynamicRow, after: []const DynamicRow, key: []const u8, names: [2][]const u8) !void {
    for (all_modes) |mode| {
        var pairs: std.ArrayList([4]f64) = .empty;
        for (before, after) |old, new| {
            const pair = [4]f64{ old.real.get(mode), old.imag.get(mode), new.real.get(mode), new.imag.get(mode) };
            var finite = true;
            for (pair) |value| finite = finite and std.math.isFinite(value);
            if (finite) try pairs.append(memory, pair);
        }
        if (pairs.items.len == 0) continue;
        const count = pairs.items.len;
        const columns = try memory.alloc(f64, 4 * count);
        const motion_x = try memory.alloc(f64, 3 * count);
        const motion_y = try memory.alloc(f64, 3 * count);
        for (pairs.items, 0..) |pair, i| {
            for (0..4) |j| columns[j * count + i] = pair[j];
            motion_x[3 * i] = pair[0];
            motion_x[3 * i + 1] = pair[2];
            motion_x[3 * i + 2] = std.math.nan(f64);
            motion_y[3 * i] = pair[1];
            motion_y[3 * i + 1] = pair[3];
            motion_y[3 * i + 2] = std.math.nan(f64);
        }
        const label = flight_mode_label.get(mode);
        const color = flight_mode_color.get(mode);
        try addCurve(state, key, try std.fmt.allocPrint(memory, "{s}: {s}", .{ label, names[0] }), columns[0..count], columns[count .. 2 * count], .{ .color = color, .marker = flight_mode_marker.get(mode), .size = 9 });
        try addCurve(state, key, try std.fmt.allocPrint(memory, "{s}: {s}", .{ label, names[1] }), columns[2 * count .. 3 * count], columns[3 * count .. 4 * count], .{ .color = color, .marker = "+", .size = 12 });
        try addCurve(state, key, try std.fmt.allocPrint(memory, "{s}: movimento", .{label}), motion_x, motion_y, .{ .color = color, .width = 1.0, .legend = false });
    }
}

/// o que muda nos modos oscilatórios de um modelo para o outro na velocidade mais perto da análise
/// (`_release_check`); null se nenhum par oscila nos dois
fn releaseCheck(memory: std.mem.Allocator, before: []const DynamicRow, after: []const DynamicRow, airspeed: f64, item: []const u8, why: []const u8) !?simulation.Check {
    if (before.len == 0) return null;
    var nearest: usize = 0;
    for (before, 0..) |row, k| if (@abs(row.speed - airspeed) < @abs(before[nearest].speed - airspeed)) {
        nearest = k;
    };
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_]qualities.Mode{ .short_period, .phugoid, .dutch_roll }) |mode| {
        const old_real = before[nearest].real.get(mode);
        const old_imag = before[nearest].imag.get(mode);
        const new_real = after[nearest].real.get(mode);
        const new_imag = after[nearest].imag.get(mode);
        var finite = true;
        for ([_]f64{ old_real, old_imag, new_real, new_imag }) |value| finite = finite and std.math.isFinite(value);
        if (!finite or old_imag <= 0 or new_imag <= 0) continue;
        const old_size = std.math.hypot(old_real, old_imag);
        const new_size = std.math.hypot(new_real, new_imag);
        try parts.append(memory, try std.fmt.allocPrint(memory, "{s}: ζ {d:.2} → {d:.2}, ω_n {d:.2} → {d:.2}", .{ flight_mode_label.get(mode), -old_real / old_size, -new_real / new_size, old_size, new_size }));
    }
    if (parts.items.len == 0) return null;
    return .{ .status = .info, .item = item, .value = try std.mem.join(memory, "; ", parts.items), .criterion = try std.fmt.allocPrint(memory, "em V = {s} m/s", .{try general(memory, before[nearest].speed)}), .why = why, .group = "dinâmica" };
}

/// os polos com o líquido oscilando numa velocidade: cada modo do corpo rígido fica com o autovalor mais perto dele
/// (a metade de cima do plano); o que sobra são os modos do líquido (`_match_poles`)
fn liquidStep(memory: std.mem.Allocator, state: *StaticState, row: DynamicRow) !void {
    var session = try Session.open(&state.plane, state.loading, state.chosen);
    defer session.close();
    var real: [core.linear.nl_slosh]f64 = undefined;
    var imag: [core.linear.nl_slosh]f64 = undefined;
    var moved = emptyRow(row.speed);
    const count = qualities.liquidPoles(&session.instance.p, &session.instance.r.f, row.speed, &real, &imag) orelse {
        try state.moving.append(memory, moved);
        return;
    };
    var taken = [_]bool{false} ** core.linear.nl_slosh;
    for (0..count) |i| if (imag[i] < -1e-9) {
        taken[i] = true;
    };
    for (all_modes) |mode| {
        const reference_real = row.real.get(mode);
        const reference_imag = row.imag.get(mode);
        if (!std.math.isFinite(reference_real) or !std.math.isFinite(reference_imag)) continue;
        var nearest: ?usize = null;
        var distance = std.math.inf(f64);
        for (0..count) |i| {
            if (taken[i]) continue;
            const gap = std.math.hypot(real[i] - reference_real, imag[i] - reference_imag);
            if (gap < distance) {
                distance = gap;
                nearest = i;
            }
        }
        const closest = nearest orelse continue;
        taken[closest] = true;
        moved.real.set(mode, real[closest]);
        moved.imag.set(mode, @abs(imag[closest]));
    }
    try state.moving.append(memory, moved);
    for (0..count) |i| if (!taken[i] and imag[i] > 1e-9) try state.liquid_poles.append(memory, .{ row.speed, real[i], imag[i] });
}

fn liquidSeries(memory: std.mem.Allocator, state: *StaticState) !void {
    try releaseSeries(memory, state, state.rows.items, state.moving.items, "liquido", .{ "parado", "oscilando" });
    const liquid = state.liquid_poles.items;
    if (liquid.len > 0) {
        const reals = try memory.alloc(f64, liquid.len);
        const imags = try memory.alloc(f64, liquid.len);
        for (liquid, 0..) |pole, i| {
            reals[i] = pole[1];
            imags[i] = pole[2];
        }
        try addCurve(state, "liquido", "líquido", reals, imags, .{ .marker = "star", .color = "#17becf", .size = 14 });
    }
    var shifted = (try releaseCheck(memory, state.rows.items, state.moving.items, state.airspeed, "polos com o líquido oscilando", "o líquido que oscila troca forças com o avião e desloca os modos (gráfico 'Polos com o líquido')")) orelse return;
    var nearest: usize = 0;
    for (state.rows.items, 0..) |row, k| if (@abs(row.speed - state.airspeed) < @abs(state.rows.items[nearest].speed - state.airspeed)) {
        nearest = k;
    };
    var highest: ?[3]f64 = null;
    for (liquid) |pole| if (pole[0] == state.rows.items[nearest].speed) {
        if (highest == null or pole[2] > highest.?[2]) highest = pole;
    };
    if (highest) |pole| {
        const size = std.math.hypot(pole[1], pole[2]);
        shifted.why = try std.fmt.allocPrint(memory, "{s}; o líquido: ω_n = {d:.1} rad/s, ζ = {d:.3}", .{ shifted.why, size, -pole[1] / size });
    }
    try addCheck(memory, state, shifted);
}

// ------------------------------------------------------------------ os modos contra os critérios

/// a causa e o que fazer quando um modo não passa (`_mode_advice`)
fn modeAdvice(check: qualities.Check, tailless_wing: bool, fin_word: []const u8, memory: std.mem.Allocator) ![2][]const u8 {
    return switch (check) {
        .short_period => .{ "amortecimento em arfagem (C_mq) fraco diante da rigidez (C_mα)", if (!tailless_wing) "aumentar EH/braço (sobe C_mq) ou levar o CG para trás (reduz a rigidez)" else "asa voadora tem C_mq pequeno: aumentar enflechamento/envergadura ou reduzir a margem" },
        .phugoid => .{ "o fugóide troca altura por velocidade e é amortecido pelo arrasto: L/D alto amortece pouco (Lanchester: ζ ≈ 1/(√2 L/D))", "normalmente aceito pelo piloto/piloto automático; não dimensiona o avião" },
        .dutch_roll => .{ try std.fmt.allocPrint(memory, "pouco amortecimento em guinada (C_nr) ou diedro forte demais diante da {s}", .{fin_word}), try std.fmt.allocPrint(memory, "aumentar a {s} ou reduzir o diedro", .{fin_word}) },
        .roll_time_constant => .{ "amortecimento em rolamento pequeno para a inércia I_xx", "reduzir I_xx (massas longe da raiz)" },
        .spiral => .{ "efeito diedro fraco diante da estabilidade direcional (C_lβ C_nr < C_nβ C_lr)", "aumentar o diedro ou reduzir a deriva" },
        .roll => .{ "", "" },
    };
}

/// o limite de um critério no texto (`evaluate`)
fn limitText(memory: std.mem.Allocator, criteria: *const qualities.Criteria, check: qualities.Check) ![]const u8 {
    if (!criteria.on(check)) return "—";
    return switch (check) {
        .short_period => std.fmt.allocPrint(memory, "{s} a {s}", .{ try general(memory, criteria.short_period_min), try general(memory, criteria.short_period_max) }),
        .phugoid => std.fmt.allocPrint(memory, "≥ {s}", .{try general(memory, criteria.phugoid_min)}),
        .dutch_roll => std.fmt.allocPrint(memory, "≥ {s} / {s} / {s}", .{ try general(memory, criteria.dutch_damping_min), try general(memory, criteria.dutch_product_min), try general(memory, criteria.dutch_natural_min) }),
        .roll_time_constant => std.fmt.allocPrint(memory, "≤ {s} s", .{try general(memory, criteria.roll_tau_max)}),
        .spiral => std.fmt.allocPrint(memory, "≥ {s} s", .{try general(memory, criteria.spiral_double_min)}),
        .roll => "—",
    };
}

/// quanto mudar para o modo passar (`_whatif`): mais diedro para a espiral, a deriva maior para o dutch roll e o EH
/// maior para o curto período, refazendo o modelo linear; "" se não achou
fn whatIf(memory: std.mem.Allocator, state: *StaticState, check: qualities.Check) ![]const u8 {
    const configuration = state.configuration;
    const airspeed = state.airspeed;
    switch (check) {
        .spiral => if (configuration.wing) |wing| {
            for ([_]f64{ 1, 2, 3, 4, 5, 6, 8, 10 }) |delta| {
                const changed = try withDihedral(memory, &state.plane, wing, delta);
                const found = modesAt(&changed, state.loading, state.chosen, airspeed) orelse continue;
                if (qualities.passes(&found.modes, &state.criteria, .spiral) and qualities.passes(&found.modes, &state.criteria, .dutch_roll))
                    return std.fmt.allocPrint(memory, "+{d}° de diedro na asa leva a espiral ao nível 1 sem estragar o dutch roll", .{@as(i64, @intFromFloat(delta))});
            }
            return "nem +10° de diedro resolve: reduzir a deriva ou aceitar (o piloto corrige a espiral lenta)";
        },
        .dutch_roll => {
            const fins = configuration.finList();
            if (fins.len > 0) for ([_]f64{ 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 }) |factor| {
                const changed = try scaledSurfaces(memory, &state.plane, fins, factor);
                const found = modesAt(&changed, state.loading, state.chosen, airspeed) orelse continue;
                if (qualities.passes(&found.modes, &state.criteria, .dutch_roll)) return std.fmt.allocPrint(memory, "área da deriva × {s} leva o dutch roll ao nível 1", .{try general(memory, factor)});
            };
        },
        .short_period => if (configuration.htail != null) {
            var htails: std.ArrayList(usize) = .empty;
            for (state.plane.surfaces, 0..) |surface, i| if (std.mem.eql(u8, surface.role, "htail")) try htails.append(memory, i);
            for ([_]f64{ 1.25, 1.5, 1.75, 2.0 }) |factor| {
                const changed = try scaledSurfaces(memory, &state.plane, htails.items, factor);
                const found = modesAt(&changed, state.loading, state.chosen, airspeed) orelse continue;
                if (qualities.passes(&found.modes, &state.criteria, .short_period)) return std.fmt.allocPrint(memory, "área do EH × {s} leva o curto período ao nível 1", .{try general(memory, factor)});
            }
        },
        else => {},
    }
    return "";
}

fn verdict(run: *simulation.Run, state: *StaticState) !void {
    const memory = run.memory();
    const group = "dinâmica";
    const airspeed = state.airspeed;
    const found = modesAt(&state.plane, state.loading, state.chosen, airspeed) orelse {
        try addCheck(memory, state, .{ .status = .falha, .item = "equilíbrio em voo nivelado", .value = try std.fmt.allocPrint(memory, "não convergiu em {s} m/s", .{try general(memory, airspeed)}), .criterion = "trimagem do núcleo", .why = "sem equilíbrio não há modelo linear: falta tração, ou o comando de arfagem satura", .fix = "ver a faixa de CG e a curva de equilíbrio acima; testar outra velocidade", .group = group });
        try sloshNote(memory, state);
        return;
    };
    var rows: [5]qualities.Row = undefined;
    for (qualities.evaluate(&found.modes, &state.criteria, &rows)) |row| {
        const status: @TypeOf(@as(simulation.Check, undefined).status) = if (row.ok) |passed| (if (passed) .ok else if (row.level != null and row.level.? == 2) .atencao else .falha) else .info;
        var why: []const u8 = "";
        var fix: []const u8 = "";
        if (status == .falha or status == .atencao) {
            const advice = try modeAdvice(row.check, state.configuration.tailless(), state.fin_word, memory);
            why = advice[0];
            fix = advice[1];
            if (state.values.toggle("whatif", true)) {
                const found_fix = try whatIf(memory, state, row.check);
                if (found_fix.len > 0) fix = found_fix;
            }
        }
        var value = try shortList(memory, row.values[0..row.value_count]);
        if (row.level) |level| value = try std.fmt.allocPrint(memory, "{s} (nível {s})", .{ value, if (level < 4) try std.fmt.allocPrint(memory, "{d}", .{level}) else ">3" });
        try addCheck(memory, state, .{ .status = status, .item = checkLabel(row.check), .value = value, .criterion = try limitText(memory, &state.criteria, row.check), .why = why, .fix = fix, .group = group, .source = state.criteria_source });
    }
    for ([_]qualities.Mode{ .phugoid, .short_period, .dutch_roll, .roll, .spiral }) |mode| if (found.modes.get(mode)) |pole| if (pole.imag > 0) {
        try state.summary.append(memory, .{ try std.fmt.allocPrint(memory, "{s} a {s} m/s: ω_n (rad/s), ζ, período (s)", .{ flight_mode_label.get(mode), try general(memory, airspeed) }), try numbersText(memory, &.{ pole.natural, pole.damping, pole.period }) });
    };
    if (state.values.toggle("resp", false)) {
        try responseSeries(memory, state, &found.model, .{ .amplitude = 2 * rad, .channel = 0, .width = 0.5, .doublet = true }, "rlon", &.{ .pitch_rate, .pitch, .forward, .down });
        try responseSeries(memory, state, &found.model, .{ .amplitude = 5 * rad, .channel = 1, .width = 1.0, .doublet = false }, "rlat", &.{ .roll_rate, .yaw_rate, .bank, .side });
    }
    try sloshNote(memory, state);
}

fn sloshNote(memory: std.mem.Allocator, state: *StaticState) !void {
    if (state.configuration.slosh) try addCheck(memory, state, .{ .status = .info, .item = "líquido livre", .value = "sloshing ligado", .why = "estática e modelo linear tratam o líquido parado no CG (faixa de CG acima inclui sem líquido); o acoplamento dinâmico do sloshing só aparece nas simulações no tempo (Missão, Curvas)", .group = "dinâmica" });
}

/// os estados do modelo linear (u, v, w, p, q, r, φ, θ) com o nome da série do Python
const LinearState = enum(usize) {
    forward = 0,
    side = 1,
    down = 2,
    roll_rate = 3,
    pitch_rate = 4,
    yaw_rate = 5,
    bank = 6,
    pitch = 7,

    fn label(entry: LinearState) []const u8 {
        return switch (entry) {
            .forward => "u",
            .side => "v",
            .down => "w",
            .roll_rate => "p",
            .pitch_rate => "q",
            .yaw_rate => "r",
            .bank => "phi",
            .pitch => "theta",
        };
    }
};

/// a resposta linear a um doublet ou a um pulso em 12 s, de 0,01 em 0,01 s (`response`); as velocidades em m/s e
/// os ângulos e as taxas em graus
fn responseSeries(memory: std.mem.Allocator, state: *StaticState, linear_model: *const core.linear.LinModel, input: qualities.Input, key: []const u8, shown: []const LinearState) !void {
    const time_step = @max(state.values.number("resp_passo", 0.01), 1e-4);
    const duration = @max(state.values.number("resp_tempo", 12.0), time_step);
    const buffer = try memory.alloc([core.linear.nl]f64, @as(usize, @intFromFloat(@ceil(duration / time_step))) + 2);
    const count = qualities.respond(linear_model, input, duration, time_step, buffer);
    const times = try memory.alloc(f64, count);
    for (times, 0..) |*instant, k| instant.* = @as(f64, @floatFromInt(k)) * time_step;
    for (shown) |entry| {
        const index = @intFromEnum(entry);
        const series = try memory.alloc(f64, count);
        for (series, 0..) |*value, k| value.* = if (index < 3) buffer[k][index] else buffer[k][index] / rad;
        try addCurve(state, key, entry.label(), times, series, .{});
    }
}

// ------------------------------------------------------------------ o resultado

fn writeStaticResult(run: *simulation.Run, state: *StaticState, out: *simulation.Writer) simulation.Error!void {
    _ = run;
    try simulation.beginResult(out, state.summary.items, state.checks.items);
    try state.figures.write(out, true);
    try simulation.endResult(out);
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

/// a análise como a tela a vê (o `State` criado pelo framework)
const registered = simulation.register(DynamicStability);

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
    try writeFields(&text.writer, &loaded.ac, .{});
    const form = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer form.deinit();
    // os campos da análise e dos métodos; os de "Refino dos Solvers" (trimagem, equilíbrio, rajada) vêm à parte
    var own_fields: usize = 0;
    var refine_fields: usize = 0;
    for (form.value.object.get("params").?.array.items) |param| {
        if (std.mem.startsWith(u8, param.object.get("key").?.string, simulation.refine_key)) refine_fields += 1 else own_fields += 1;
    }
    try testing.expectEqual(@as(usize, 18 + simulation.method_params.len), own_fields); // 18 com os instantes dos polos
    try testing.expect(refine_fields > 0);
    // a tabela dos tanques, com a massa do líquido de cada um, e a vista 3D com os tanques e o CG
    const grid = form.value.object.get("grids").?.array.items[0];
    const first_row = grid.object.get("rows").?.array.items[0].array.items;
    const tank = loaded.ac.tanks[0];
    try testing.expectApproxEqAbs(tank.rho * tank.volume / 1000.0, try std.fmt.parseFloat(f64, first_row[8].string), 1e-3);
    const view_json = form.value.object.get("view").?.object;
    try testing.expect(view_json.get("meshes").?.array.items.len > 3);
    try testing.expectEqual(@as(usize, 3), view_json.get("markers").?.object.get("cg").?.array.items.len);

    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    const values = simulation.Values.fromRequest(run.memory(), "\"op\": \"run\", \"values\": {\"span\": 4, \"up\": 3}");
    try registered.start(&run, values);
    var slices: usize = 0;
    while (!try registered.advance(&run)) slices += 1;
    try testing.expect(slices > 4); // andou em fatias
    text.clearRetainingCapacity();
    try registered.result(&run, &text.writer);
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
    try editTanks(plane, .{ .grid = "tanks", .operation = "add", .row = 0 });
    try testing.expectEqual(original + 1, tanks_table.count);
    try editTanks(plane, .{ .grid = "tanks", .operation = "set", .row = 1, .key = "volume", .value = .{ .string = "0,75" } });
    try editTanks(plane, .{ .grid = "tanks", .operation = "set", .row = 1, .key = "y", .value = .{ .float = -0.3 } });
    try editTanks(plane, .{ .grid = "tanks", .operation = "set", .row = 1, .key = "shape", .value = .{ .string = "cilindro" } });
    try testing.expectEqual(@as(f64, 0.75), tanks_table.tanks[1].volume);
    try testing.expectEqual(@as(f64, -0.3), tanks_table.tanks[1].y);
    try testing.expectEqualStrings("cylinder", tanks_table.tanks[1].shape);
    try editTanks(plane, .{ .grid = "tanks", .operation = "delete", .row = 0 });
    try testing.expectEqual(original, tanks_table.count);
    try testing.expectEqual(@as(f64, -0.3), tanks_table.tanks[0].y);
    try editTanks(plane, .{ .grid = "tanks", .operation = "reset" });
    try testing.expectEqual(plane.tanks[0].y, tanks_table.tanks[0].y);

    // sem tanques e com a LAPES solta em 2 s: roda sem a parte do líquido e o voo segue sem a carga
    for (0..original) |_| try editTanks(plane, .{ .grid = "tanks", .operation = "delete", .row = 0 });
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = plane };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"span\": 5, \"lapes\": true, \"lapes_mass\": 1.2, \"drop\": true, \"drop_t\": 2}"));
    while (!try registered.advance(&run)) {}
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try registered.result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 4 + 3), outcome.value.object.get("plots").?.array.items.len); // sem o do líquido; polos sem efeitos, com a LAPES e todos
    const summary = outcome.value.object.get("summary").?.object;
    const before = try std.fmt.parseFloat(f64, summary.get("massa (kg)").?.string);
    const after = try std.fmt.parseFloat(f64, summary.get("massa depois da LAPES (kg)").?.string);
    try testing.expectApproxEqAbs(before - 1.2, after, 2e-3);
    tanks_table.reset(plane);
}

test "o método escolhido no formulário vale na rodada: a linha sustentadora voa" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    tanks_table.reset(&loaded.ac);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"span\": 3, \"compare\": false, \"aero_model\": \"linha sustentadora\"}"));
    const state: *RunState = @ptrCast(@alignCast(run.state.?));
    try testing.expectEqual(core.types.AeroModel.lifting_line, state.flights[0].instance.p.aero_model);
    while (!try registered.advance(&run)) {}
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try registered.result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    const summary = outcome.value.object.get("summary").?.object;
    try testing.expect(std.math.isFinite(try std.fmt.parseFloat(f64, summary.get("α de equilíbrio (°)").?.string)));
}

fn jsonNumber(value: std.json.Value) f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

test "a sonda da estabilidade estática dá os números do Python no Convencional_original" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const instance = try gpa.create(core.runner.Instance);
    defer gpa.destroy(instance);
    instance.* = .{};
    _ = try params_mod.setup(&loaded.ac, instance, &diagnosis);
    const static = core.static_stability;
    const probe = static.Probe.init(instance, params_mod.macLeadingEdge(&loaded.ac));
    // `Probe` e `sizing` de `aerosim/stability` no mesmo avião (V = 15 m/s; pouso a 1,3 V_S e 0,9 C_Lmax)
    try testing.expectApproxEqAbs(@as(f64, 12.39), probe.mass, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 48.36782672897627), probe.fraction(probe.neutralPoint(15)), 1e-6);
    const lift_max = probe.liftMax(15, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.648057806495107), lift_max, 1e-9);
    const stall = probe.stallSpeed(lift_max);
    try testing.expectApproxEqAbs(@as(f64, 10.971265478835653), stall, 1e-9);
    const x = probe.xAt(20);
    const trim = probe.trimAtLift(1.3 * stall, 0.9 * lift_max, x, .{ 0.1, 0 }).?;
    try testing.expectApproxEqAbs(@as(f64, 0.2650868051482738), trim[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -0.4001110553485697), trim[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.4123720945165297), probe.trimmedLiftMax(1.3 * stall, x, 20.0 / deg), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 19.54218481272443), probe.thrust(1.1 * stall, 1)[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.15254812054957279), probe.rotationElevator(1.1 * stall, probe.cg[0], 10, null), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.156088315180844), probe.momentAtZeroLift(15), 1e-9);
    const gear = static.gearForRotation(&probe, 1.1 * stall, probe.cg[0], 10, 20.0 / deg);
    try testing.expectApproxEqAbs(@as(f64, -0.11201892172952546), gear.gear_x.?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.04525497326042473), gear.tip_x, 1e-9);
    var sweep: static.Sweep = .{};
    const percents = [_]f64{ 0, 5, 10, 15, 20, 25, 30, 35, 40 };
    static.cgSweep(&probe, &percents, 15, 1.3 * stall, 0.9 * lift_max, 1.1 * stall, 10, &sweep);
    const landing = [_]f64{ std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), -22.92467480799833, -16.910687817981156, -11.199861041713897, -5.6408980607050765, -0.18091965150705688 };
    const cruise_elevator = [_]f64{ -18.12784747771461, -14.976612471563344, -11.843088956333636, -8.723575648897665, -5.616004044621141, -2.51878779840007, 0.5694704232969388, 3.6500572700390252, 6.7241730647298175 };
    const rotation = [_]f64{ -37.76040471766294, -33.179097701074504, -28.60103190971707, -24.026207343590606, -19.454624002695123, -14.886281887030625, -10.321180996597107, -5.7593213313945695, -1.2007028914230011 };
    for (0..percents.len) |k| {
        try testing.expectEqual(std.math.isNan(landing[k]), std.math.isNan(sweep.landing[k]));
        if (!std.math.isNan(landing[k])) try testing.expectApproxEqAbs(landing[k], sweep.landing[k], 1e-5);
        try testing.expectApproxEqAbs(cruise_elevator[k], sweep.cruise[k], 1e-5);
        try testing.expectApproxEqAbs(rotation[k], sweep.rotation[k], 1e-7);
    }
}



test "os modos e a MIL-F-8785C dão os números do Python no Convencional_original" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const instance = try gpa.create(core.runner.Instance);
    defer gpa.destroy(instance);
    instance.* = .{};
    _ = try params_mod.setup(&loaded.ac, instance, &diagnosis);
    const flight_modes = core.flight_modes;
    const linear_model = core.linear.linearize(&instance.p, &instance.r.f, 15);
    try testing.expect(linear_model.ok != 0);
    const found = flight_modes.classify(&linear_model.A).?;
    // `modes_at(backend, ac, 15)` de `aerosim/stability/sizing.py`
    try testing.expectApproxEqAbs(@as(f64, 0.10900043636240692), found.get(.phugoid).?.damping, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7.909808315900555), found.get(.short_period).?.natural, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.30326852752838535), found.get(.dutch_roll).?.damping, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.04463527080988007), found.get(.roll).?.time_constant, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.727028645879708), found.get(.spiral).?.double_time, 1e-9);
    var rows: [5]flight_modes.Row = undefined;
    const criteria = flight_modes.mil8785c(.I, .B);
    const evaluated = flight_modes.evaluate(&found, &criteria, &rows);
    try testing.expectEqual(@as(usize, 5), evaluated.len);
    for (evaluated[0..4]) |row| try testing.expectEqual(@as(?u8, 1), row.level);
    try testing.expectEqual(@as(?bool, false), evaluated[4].ok);
    try testing.expectEqual(@as(?u8, 3), evaluated[4].level);
}

test "a aba Estabilidade inteira dá o diagnóstico do Python no Convencional_original" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const analysis = simulation.register(Stability);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try analysis.specs(&text.writer, &loaded.ac, .{});
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    const values = simulation.Values.fromRequest(run.memory(), "\"op\": \"run\", \"values\": {}");
    try analysis.start(&run, values);
    while (!try analysis.advance(&run)) {}
    text.clearRetainingCapacity();
    try analysis.result(&run, &text.writer);
    const outcome = try std.json.parseFromSlice(std.json.Value, gpa, text.written(), .{});
    defer outcome.deinit();
    // os números de `SimulationManager(ZigBackend()).run("stability", ac, {})` no Python
    const summary = outcome.value.object.get("summary").?.object;
    try testing.expectEqualStrings("48.3678, 44.1573", summary.get("ponto neutro: núcleo, analítico (% CMA)").?.string);
    try testing.expectEqualStrings("22.3850, 43.3678", summary.get("limites de CG: dianteiro, traseiro (% CMA)").?.string);
    try testing.expectEqualStrings("26.9377, 38.1562", summary.get("faixa de CG prevista (% CMA)").?.string);
    try testing.expectEqualStrings("0.2000, 0.1492", summary.get("S_h/S: atual, mínimo para a faixa de CG").?.string);
    try testing.expectEqualStrings("7.9098, 0.5814, 0.9763", summary.get("curto período a 15 m/s: ω_n (rad/s), ζ, período (s)").?.string);
    const expected = [_][3][]const u8{
        .{ "atencao", "margem estática no CG atual", "16.6 % (CG 31.7 %, ponto neutro 48.4 %)" },
        .{ "ok", "faixa de CG prevista dentro da permitida", "permitido 22.4 … 43.4 %; previsto 26.9 … 38.2 %" },
        .{ "ok", "C_L de pouso equilibrado pelo profundor (CG 26.9 %)", "máx. 1.54 (pedido 1.48 = 0.9 C_Lmax); V_estol equilibrada 11.3 m/s" },
        .{ "ok", "rotação na decolagem em V_R = 12.5 m/s", "δ = -7.1° no CG atual" },
        .{ "ok", "profundor de equilíbrio cresce com V", "dδ/dV = 1.35 °/(m/s)" },
        .{ "info", "volume de cauda horizontal V_H", "0.529" },
        .{ "ok", "estabilidade direcional C_nβ", "0.0692 /rad" },
        .{ "ok", "efeito diedro C_lβ", "-0.0831 /rad" },
        .{ "info", "critério da espiral C_lβ C_nr − C_nβ C_lr", "-0.00438" },
        .{ "ok", "aileron: rolagem", "0.55 s (p = 119 °/s a 15.0 m/s)" },
        .{ "ok", "profundor: corda móvel (CG mais dianteiro 26.9 %)", "atual 0.35; mínima 0.15" },
        .{ "ok", "leme: vento cruzado no pouso", "δr = 11.7° (β = 8.7°, vento 2.2 m/s)" },
        .{ "ok", "área do EH para a faixa de CG", "atual 0.200 ≥ mínimo 0.149" },
        .{ "info", "polos ao soltar a carga", "curto período: ζ 0.58 → 0.60, ω_n 7.91 → 8.28; fugóide: ζ 0.11 → 0.13, ω_n 0.75 → 0.73; dutch roll: ζ 0.30 → 0.29, ω_n 3.95 → 3.97" },
        .{ "ok", "ζ curto período", "0.581 (nível 1)" },
        .{ "ok", "ζ fugóide", "0.109 (nível 1)" },
        .{ "ok", "dutch roll ζ / ζω_n / ω_n", "0.303, 1.2, 3.95 (nível 1)" },
        .{ "ok", "τ_R rolamento (s)", "0.0446 (nível 1)" },
        .{ "falha", "espiral: tempo para dobrar (s)", "5.73 (nível 3)" },
        .{ "info", "líquido livre", "sloshing ligado" },
    };
    const checks = outcome.value.object.get("checks").?.array.items;
    try testing.expectEqual(expected.len, checks.len);
    for (expected, checks) |want, got| {
        try testing.expectEqualStrings(want[0], got.object.get("status").?.string);
        try testing.expectEqualStrings(want[1], got.object.get("item").?.string);
        try testing.expectEqualStrings(want[2], got.object.get("value").?.string);
    }
    try testing.expectEqualStrings("+3° de diedro na asa leva a espiral ao nível 1 sem estragar o dutch roll", checks[18].object.get("fix").?.string);
    // as curvas de cada gráfico, na contagem das séries do Python
    const curve_counts = [_]usize{ 9, 8, 3, 1, 1, 1, 6, 6, 4, 9, 6, 15, 5, 3, 2 };
    const charts = outcome.value.object.get("plots").?.array.items;
    for (curve_counts, 0..) |count, k| try testing.expectEqual(count, charts[k].object.get("curves").?.array.items.len);
    // a margem e o profundor de pouso ao longo da varredura do CG, nas pontas
    const margin = charts[0].object.get("curves").?.array.items[0].object;
    const margin_x = margin.get("x").?.array.items;
    const margin_y = margin.get("y").?.array.items;
    try testing.expectEqual(@as(usize, 45), margin_x.len);
    try testing.expectApproxEqAbs(-1.6321732710237313, jsonNumber(margin_x[0]), 1e-6);
    try testing.expectApproxEqAbs(50.0, jsonNumber(margin_y[0]), 1e-6);
    try testing.expectApproxEqAbs(56.36782672897627, jsonNumber(margin_x[44]), 1e-6);
    try testing.expectApproxEqAbs(-8.0, jsonNumber(margin_y[44]), 1e-6);
    const landing = charts[1].object.get("curves").?.array.items[0].object.get("y").?.array.items;
    try testing.expectApproxEqAbs(17.28882970198655, jsonNumber(landing[landing.len - 1]), 1e-4);
}

//! O contrato das análises em Zig (o par de `simulation.py`): a página da tela (`aerosim/gui/page.zig`) pede os
//! campos e roda pelo mesmo JSON da ponte com o Python (`aerosim/bridge.py`), só que sem Python, também no navegador.
//!
//! Uma análise é um tipo com declarações conhecidas (o molde de `core.interface`, o mesmo dos tipos de aeronave do
//! dimensionamento): o nome, o título, a aba, a descrição, o estado da rodada (`State`) e as funções `specs`, `start`,
//! `advance`, `result` e, se a aba tem tabelas, `edit`. O manager (`aerosim/manager/manager.zig`) lista as análises
//! e `register` monta a tabela que a tela usa; falta ou assinatura errada é erro de compilação. O estado da rodada é tipado: o framework cria o `State` na
//! memória da rodada e cada função recebe `*State`, sem conversão de ponteiro na análise.
//!
//! Os métodos de cálculo (modelo do voo, linha sustentadora, refino; `core.methods`) são campos prontos
//! (`method_params`, lidos com `Values.methods`): uma análise que voa o avião põe esses campos e o usuário escolhe.
//! O AeroDrive usa os mesmos `core.methods`, fixos (`aerodrive/src/sim/methods.zig`).
//!
//! O contrato é o JSON da ponte. Os campos saem como `{"params": [...], "plots": [...], "description": ...}` e o
//! resultado como `{"summary": {...}, "checks": [...], "plots": [...]}`, com os mesmos nomes da `ISimulation`
//! (`aerosim/interfaces/simulation.py`). A rodada anda em fatias (`advance`), para a tela seguir desenhando, também no
//! navegador, onde não há thread.
const std = @import("std");
const aircraft_model = @import("aircraft_model");
const core = @import("aerosim");

pub const Aircraft = aircraft_model.aircraft.Aircraft;
pub const Surface = aircraft_model.aircraft.Surface;
pub const Methods = core.methods.Methods;
pub const Json = std.json.Value;
pub const Writer = std.Io.Writer;

/// o que dá errado numa análise: memória, escrita do JSON, montagem do avião no núcleo e o voo do núcleo. A
/// mensagem para a tela vai em `Run.fail`; o erro só diz que parou
/// `Failed`: a rodada parou e o motivo já está em `Run.failure`, escrito por `Run.fail`
pub const Error = error{ OutOfMemory, WriteFailed, NoRows, Failed } || std.Io.Writer.Error || aircraft_model.params.Error || core.gust.Error;

/// uma análise registrada, como a tela usa: os textos e as funções já com o estado da rodada por trás (`register`)
pub const Simulation = struct {
    name: []const u8, // o nome que a página guarda (como `ISimulation.name`)
    title: [:0]const u8, // o rótulo da subaba
    area: []const u8, // a aba de cima onde a subaba entra ("Estabilidade")
    description: []const u8,
    /// escreve os campos e os gráficos para o avião e os valores de agora (o avião pode faltar)
    specs: *const fn (out: *Writer, aircraft: ?*const Aircraft, values: Values) Error!void,
    /// uma edição numa tabela da aba (`grids`), guardada pela própria análise até a próxima rodada; nulo: sem tabelas
    edit: ?*const fn (aircraft: ?*const Aircraft, change: GridEdit) Error!void = null,
    /// prepara a rodada em `run` (o avião já foi lido)
    start: *const fn (run: *Run, values: Values) Error!void,
    /// avança uma fatia da rodada; verdadeiro quando acabou
    advance: *const fn (run: *Run) Error!bool,
    /// escreve o resultado da rodada que acabou
    result: *const fn (run: *Run, out: *Writer) Error!void,
    /// a rodada com estes valores precisa de um método de fora do núcleo (lltdrek, AeroSandbox, AVL): ela vai pela
    /// ponte com o Python, que no site só baixa o pacote do método nessa hora; nulo: tudo no núcleo
    python: ?*const fn (values: Values) bool = null,
    /// os avisos da rodada com estes valores (um método fora do que ele calcula bem, como a linha sustentadora numa
    /// asa curta): a tela mostra cada um por cima da janela e roda igual; nulo: nenhum aviso próprio
    alerts: ?*const fn (memory: std.mem.Allocator, aircraft: *const Aircraft, values: Values) Error![]const []const u8 = null,
    /// a rodada com estes valores não precisa do avião aberto (o Mini-MDO procura o avião; o Analisar com as asas
    /// da sprint): sem avião aberto, ela recebe um avião vazio; nulo: precisa do avião
    standalone: ?*const fn (values: Values) bool = null,
};

// ------------------------------------------------------------------ o projeto da sprint, para as análises
/// uma restrição de "Condições e restrições" (a chave da grandeza, como `design/registry.zig`, o sentido e o
/// limite), só as ligadas
pub const SprintConstraint = struct { key: []const u8, label: []const u8, unit: []const u8, op: []const u8, value: f64, tol: f64 = 0.02 };

/// as condições e as regras de massa de "Condições e restrições" que as análises usam (os padrões: os de
/// `design/registry.zig`)
pub const SprintConditions = struct {
    density_altitude: f64 = 600,
    mu_roll: f64 = 0.04,
    V_turn: f64 = 0,
    mu_brake: f64 = 0.3,
    V_cruise: f64 = 15,
    wing_density: f64 = 1.1,
    tail_density: f64 = 0.7,
    fuselage_density: f64 = 0.7,
    systems_mass: f64 = 0.35,
    gear_mass: f64 = 0.35,
};

/// o que as análises leem do projeto da sprint, sem depender das etapas (`design`, que preenche `sprint` ao abrir
/// a tela): as asas guardadas na etapa Asa e as condições e restrições. Tudo copiado para `memory`
pub const Sprint = struct {
    /// os nomes das asas guardadas
    wing_names: *const fn (memory: std.mem.Allocator) Error![]const []const u8,
    /// a asa guardada com este nome, como superfície do avião (bordo de ataque da raiz em x = 0); nula: não existe
    wing: *const fn (memory: std.mem.Allocator, name: []const u8) Error!?aircraft_model.aircraft.Surface,
    /// as restrições ligadas
    constraints: *const fn (memory: std.mem.Allocator) Error![]const SprintConstraint,
    /// as condições (altitude-densidade, atritos, V da curva, cruzeiro)
    conditions: *const fn () SprintConditions,
};

/// o projeto da sprint aberto na tela; nulo: sem etapas (os testes dos managers)
pub var sprint: ?Sprint = null;

/// confere em comptime que `Analysis` tem a interface de uma análise
pub fn check(comptime Analysis: type) void {
    const State = if (@hasDecl(Analysis, "State")) Analysis.State else @compileError("análise " ++ @typeName(Analysis) ++ " sem `State`");
    core.interface.require(Analysis, "análise", &.{
        .{ .name = "name", .type = []const u8 },
        .{ .name = "title", .type = [:0]const u8 },
        .{ .name = "area", .type = []const u8 },
        .{ .name = "description", .type = []const u8 },
        .{ .name = "specs", .type = fn (*Writer, ?*const Aircraft, Values) Error!void },
        .{ .name = "start", .type = fn (*Run, *State, Values) Error!void },
        .{ .name = "advance", .type = fn (*Run, *State) Error!bool },
        .{ .name = "result", .type = fn (*Run, *State, *Writer) Error!void },
    });
    if (comptime core.interface.has(Analysis, "edit")) core.interface.require(Analysis, "análise", &.{
        .{ .name = "edit", .type = fn (?*const Aircraft, GridEdit) Error!void },
    });
    if (comptime core.interface.has(Analysis, "python")) core.interface.require(Analysis, "análise", &.{
        .{ .name = "python", .type = fn (Values) bool },
    });
    if (comptime core.interface.has(Analysis, "alerts")) core.interface.require(Analysis, "análise", &.{
        .{ .name = "alerts", .type = fn (std.mem.Allocator, *const Aircraft, Values) Error![]const []const u8 },
    });
    if (comptime core.interface.has(Analysis, "standalone")) core.interface.require(Analysis, "análise", &.{
        .{ .name = "standalone", .type = fn (Values) bool },
    });
}

/// a tabela de uma análise: os textos dela e as funções que criam e passam o `State` da rodada
pub fn register(comptime Analysis: type) Simulation {
    check(Analysis);
    const State = Analysis.State;
    const wrapped = struct {
        fn state(run: *Run) *State {
            return @ptrCast(@alignCast(run.state.?));
        }
        fn start(run: *Run, values: Values) Error!void {
            const created = try run.memory().create(State);
            created.* = .{};
            run.state = created;
            return Analysis.start(run, created, values);
        }
        fn advance(run: *Run) Error!bool {
            return Analysis.advance(run, state(run));
        }
        fn result(run: *Run, out: *Writer) Error!void {
            return Analysis.result(run, state(run), out);
        }
    };
    return .{
        .name = Analysis.name,
        .title = Analysis.title,
        .area = Analysis.area,
        .description = Analysis.description,
        .specs = Analysis.specs,
        .edit = if (comptime core.interface.has(Analysis, "edit")) Analysis.edit else null,
        .python = if (comptime core.interface.has(Analysis, "python")) Analysis.python else null,
        .alerts = if (comptime core.interface.has(Analysis, "alerts")) Analysis.alerts else null,
        .standalone = if (comptime core.interface.has(Analysis, "standalone")) Analysis.standalone else null,
        .start = wrapped.start,
        .advance = wrapped.advance,
        .result = wrapped.result,
    };
}

/// os campos dos métodos de cálculo (`core.methods.Methods`), no grupo "Métodos"; as escolhas saem dos nomes dos
/// `enum` do núcleo, e o padrão é o de sempre
pub const method_params = [_]Param{
    .{ .key = "aero_model", .label = "modelo aerodinâmico", .kind = .choice, .default = .{ .text = "faixas" }, .choices = core.methods.choices(core.types.AeroModel), .group = "Métodos", .help = "quem dá as forças no voo: faixas (o de sempre), linha sustentadora ou a tabela do avião" },
    .{ .key = "llt_method", .label = "linha sustentadora", .kind = .choice, .default = .{ .text = "Phillips e Snyder" }, .choices = core.methods.choices(core.types.LiftingLineMethod), .group = "Métodos", .help = "a variante, quando o modelo é a linha sustentadora" },
    .{ .key = "slipstream_chord_samples", .label = "esteira: amostras na corda", .kind = .int, .default = .{ .number = 3 }, .minimum = 1, .maximum = 64, .group = "Métodos", .help = "refino da esteira da hélice (só com a esteira ligada)" },
    .{ .key = "slipstream_span_samples", .label = "esteira: amostras na envergadura", .kind = .int, .default = .{ .number = 16 }, .minimum = 1, .maximum = 64, .group = "Métodos", .help = "refino da esteira da hélice (só com a esteira ligada)" },
};

/// os valores do formulário, como a tela manda (`{"chave": valor}`)
pub const Values = struct {
    object: ?std.json.ObjectMap = null,

    /// os valores dentro de um pedido da tela (`"op": ..., "name": ..., "values": {...}`, sem as chaves de fora)
    pub fn fromRequest(memory: std.mem.Allocator, request: []const u8) Values {
        const whole = std.fmt.allocPrint(memory, "{{{s}}}", .{request}) catch return .{};
        const root = std.json.parseFromSliceLeaky(Json, memory, whole, .{}) catch return .{};
        if (root != .object) return .{};
        const values = root.object.get("values") orelse return .{};
        return if (values == .object) .{ .object = values.object } else .{};
    }

    /// um número (ou `fallback` se não veio)
    pub fn number(values: Values, key: []const u8, fallback: f64) f64 {
        const object = values.object orelse return fallback;
        return switch (object.get(key) orelse return fallback) {
            .float => |value| value,
            .integer => |value| @floatFromInt(value),
            else => fallback,
        };
    }

    /// um marcador
    pub fn toggle(values: Values, key: []const u8, fallback: bool) bool {
        const object = values.object orelse return fallback;
        const value = object.get(key) orelse return fallback;
        return if (value == .bool) value.bool else fallback;
    }

    /// o texto de uma escolha
    pub fn text(values: Values, key: []const u8, fallback: []const u8) []const u8 {
        const object = values.object orelse return fallback;
        const value = object.get(key) orelse return fallback;
        return if (value == .string) value.string else fallback;
    }

    /// uma lista de números de um campo `floats` (a tela manda `[1, 0.75]`; um texto "1, 0.75" também vale), em
    /// `buffer`; sem nenhum número vale `fallback`
    pub fn numbers(values: Values, key: []const u8, buffer: []f64, fallback: []const f64) []const f64 {
        const object = values.object orelse return fallback;
        var count: usize = 0;
        switch (object.get(key) orelse return fallback) {
            .array => |list| for (list.items) |item| {
                if (count >= buffer.len) break;
                buffer[count] = switch (item) {
                    .float => |value| value,
                    .integer => |value| @floatFromInt(value),
                    else => continue,
                };
                count += 1;
            },
            .string => |written| {
                var pieces = std.mem.tokenizeAny(u8, written, ", ;");
                while (pieces.next()) |piece| {
                    if (count >= buffer.len) break;
                    buffer[count] = std.fmt.parseFloat(f64, piece) catch continue;
                    count += 1;
                }
            },
            else => {},
        }
        return if (count > 0) buffer[0..count] else fallback;
    }

    /// os métodos de cálculo dos campos de `method_params` (o que faltar ou não existir: o padrão)
    pub fn methods(values: Values) Methods {
        const defaults: Methods = .{};
        const default_refinement = defaults.refinement;
        return .{
            .aero_model = core.methods.byName(core.types.AeroModel, values.text("aero_model", "")) orelse defaults.aero_model,
            .llt_method = core.methods.byName(core.types.LiftingLineMethod, values.text("llt_method", "")) orelse defaults.llt_method,
            .refinement = .{
                .slipstream_chord_samples = sampleCount(values.number("slipstream_chord_samples", @floatFromInt(default_refinement.slipstream_chord_samples))),
                .slipstream_span_samples = sampleCount(values.number("slipstream_span_samples", @floatFromInt(default_refinement.slipstream_span_samples))),
            },
        };
    }
};

/// um número de amostras do formulário, inteiro de 1 a 64
fn sampleCount(value: f64) i32 {
    if (!std.math.isFinite(value)) return 1;
    return @intFromFloat(std.math.clamp(@round(value), 1, 64));
}

/// uma edição numa tabela, como a tela manda (`"grid": ..., "edit": "set", "row": n, "key": ..., "value": ...`; os
/// botões mandam o `operation` deles no lugar de "set")
pub const GridEdit = struct {
    grid: []const u8,
    operation: []const u8,
    row: ?usize = null, // a linha editada ou a selecionada (nula: nenhuma)
    key: []const u8 = "",
    value: Json = .null,

    /// a edição dentro de um pedido da tela (nula se o pedido não é de tabela)
    pub fn fromRequest(memory: std.mem.Allocator, request: []const u8) ?GridEdit {
        const whole = std.fmt.allocPrint(memory, "{{{s}}}", .{request}) catch return null;
        const root = std.json.parseFromSliceLeaky(Json, memory, whole, .{}) catch return null;
        if (root != .object) return null;
        const grid = root.object.get("grid") orelse return null;
        const operation = root.object.get("edit") orelse return null;
        if (grid != .string or operation != .string) return null;
        var change: GridEdit = .{ .grid = grid.string, .operation = operation.string };
        if (root.object.get("row")) |row| if (row == .integer and row.integer >= 0) {
            change.row = @intCast(row.integer);
        };
        if (root.object.get("key")) |key| if (key == .string) {
            change.key = key.string;
        };
        change.value = root.object.get("value") orelse .null;
        return change;
    }

    /// o valor editado como número (o texto com vírgula também vale)
    pub fn number(change: GridEdit) ?f64 {
        return switch (change.value) {
            .float => |value| value,
            .integer => |value| @floatFromInt(value),
            .string => |value| std.fmt.parseFloat(f64, std.mem.trim(u8, value, " ")) catch blk: {
                var buffer: [64]u8 = undefined;
                if (value.len > buffer.len) break :blk null;
                const dotted = buffer[0..value.len];
                @memcpy(dotted, value);
                std.mem.replaceScalar(u8, dotted, ',', '.');
                break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, dotted, " ")) catch null;
            },
            else => null,
        };
    }

    /// o valor editado como texto (escolha ou nome)
    pub fn text(change: GridEdit) []const u8 {
        return if (change.value == .string) change.value.string else "";
    }
};

/// uma rodada: o avião lido, a memória dela, o progresso e o estado da análise
pub const Run = struct {
    arena: std.heap.ArenaAllocator,
    aircraft: *const Aircraft,
    state: ?*anyopaque = null,
    progress: f32 = 0, // de 0 a 1
    message: [160:0]u8 = [_:0]u8{0} ** 160,
    failure: [240:0]u8 = [_:0]u8{0} ** 240,

    pub fn memory(run: *Run) std.mem.Allocator {
        return run.arena.allocator();
    }

    /// o texto do progresso
    pub fn say(run: *Run, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(run.message[0 .. run.message.len - 1], fmt, args) catch run.message[0 .. run.message.len - 1];
        run.message[written.len] = 0;
    }

    /// o motivo de a rodada não ter saído (a tela mostra)
    pub fn fail(run: *Run, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(run.failure[0 .. run.failure.len - 1], fmt, args) catch run.failure[0 .. run.failure.len - 1];
        run.failure[written.len] = 0;
    }
};

// ------------------------------------------------------------------ o JSON da ponte

/// um campo do formulário (`ParamSpec`)
pub const Param = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { float, int, bool, choice, floats, str } = .float, // floats: uma lista de números num texto ("1, 0.75"); str: um texto livre
    default: union(enum) { number: f64, toggle: bool, text: []const u8 } = .{ .number = 0 },
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    unit: []const u8 = "",
    choices: []const []const u8 = &.{},
    group: []const u8 = "",
    help: []const u8 = "",
    rebuild: bool = false,
};

/// um gráfico (`PlotSpec`): só o título e os eixos; as curvas vêm no resultado
pub const Plot = struct {
    key: []const u8,
    title: []const u8,
    xlabel: []const u8,
    ylabel: []const u8,
    x_limits: ?[2]f64 = null, // a janela do eixo x (null: a das curvas)
    y_limits: ?[2]f64 = null,
    kind: enum { flat, track } = .flat, // track: a trajetória em 3D (x, y e a altura)
};

/// uma curva de um gráfico do resultado
pub const Curve = struct {
    name: []const u8,
    x: []const f64,
    y: []const f64,
    color: []const u8,
    dashed: bool = false,
    marker: []const u8 = "", // um símbolo em cada ponto, sem a linha ("x", "o", "+"); vazio: só a linha
    size: f64 = 0, // o tamanho do símbolo (0: o padrão)
    legend: bool = true, // falso: a curva não entra na legenda
    width: f64 = 0, // a espessura (0: a padrão)
    fill: []const f64 = &.{}, // a região sombreada até esta outra borda em y, no mesmo x
    fill_x: []const f64 = &.{}, // ou até esta outra borda em x, no mesmo y
    strong: bool = false, // a sombra mais forte
    vspan: bool = false, // uma faixa vertical sombreada de x[0] a x[1] (y é ignorado)
    line: bool = false, // com `marker`: liga os símbolos com a linha
};

/// uma reta de referência (cruzeiro, estol, teto): vertical em `value` de x ou horizontal em `value` de y, que
/// atravessa o que as curvas do gráfico ocupam
pub const Guide = struct {
    name: []const u8,
    value: f64,
    vertical: bool,
    color: []const u8,
    dashed: bool = false,
    legend: bool = true,
    width: f64 = 0,
};

/// uma linha da trajetória em 3D: os pontos (x, y, altura) em sequência, em metros
pub const TrackLine = struct {
    name: []const u8,
    kind: enum { line, points, segments } = .line, // segments: pares de pontos (a silhueta do avião)
    points: []const f64,
    offsets: []const f64 = &.{}, // segments: o desenho em metros em volta de cada ponto (a altura não é esticada)
    color: []const u8,
    width: f64 = 0, // 0: a padrão (1,5 nos segmentos, 2,5 nas linhas)
    legend: bool = true,
    marker: []const u8 = "star", // points
    size: f64 = 14,
};

/// os gráficos de um resultado, cada um com as curvas, as retas de referência e (no 3D) as linhas da trajetória,
/// na ordem dos `plots`; uma curva para um gráfico que não está na lista é ignorada
pub const Figures = struct {
    memory: std.mem.Allocator,
    list: []Figure,

    pub const Figure = struct {
        plot: Plot,
        curves: std.ArrayList(Curve) = .empty,
        guides: std.ArrayList(Guide) = .empty,
        lines: std.ArrayList(TrackLine) = .empty,
    };

    /// um gráfico vazio para cada `plots`
    pub fn init(memory: std.mem.Allocator, plots: []const Plot) !Figures {
        const list = try memory.alloc(Figure, plots.len);
        for (plots, list) |plot, *figure| figure.* = .{ .plot = plot };
        return .{ .memory = memory, .list = list };
    }

    /// o gráfico com esta chave
    pub fn get(figures: Figures, key: []const u8) ?*Figure {
        for (figures.list) |*figure| if (std.mem.eql(u8, figure.plot.key, key)) return figure;
        return null;
    }

    /// uma curva no gráfico `key`
    pub fn curve(figures: Figures, key: []const u8, item: Curve) !void {
        if (figures.get(key)) |figure| try figure.curves.append(figures.memory, item);
    }

    /// uma reta de referência no gráfico `key`
    pub fn guide(figures: Figures, key: []const u8, item: Guide) !void {
        if (figures.get(key)) |figure| try figure.guides.append(figures.memory, item);
    }

    /// uma linha da trajetória no gráfico 3D `key`
    pub fn line(figures: Figures, key: []const u8, item: TrackLine) !void {
        if (figures.get(key)) |figure| try figure.lines.append(figures.memory, item);
    }

    /// escreve todos os gráficos (`first`: é o primeiro da lista do resultado)
    pub fn write(figures: Figures, out: *Writer, first: bool) !void {
        for (figures.list, 0..) |*figure, k| {
            if (figure.plot.kind == .track) {
                try writeTrack(out, figure.plot, figure.lines.items, first and k == 0);
                continue;
            }
            const curves = try withGuides(figures.memory, figure.curves.items, figure.guides.items);
            try writePlot(out, figure.plot, curves, first and k == 0);
        }
    }
};

const max_track_points = 3000; // por linha da trajetória 3D (o resto é passo maior)

/// a trajetória 3D como a ponte do Python a escreve (`bridge._track`): a altura exagerada para a trajetória, que tem
/// centenas de metros e poucos de altura, não sair chata
pub fn writeTrack(out: *Writer, plot: Plot, lines: []const TrackLine, first: bool) !void {
    if (!first) try out.writeAll(", ");
    try writePlotHead(out, plot);
    var low = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var high = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (lines) |item| {
        var k: usize = 0;
        while (k + 2 < item.points.len) : (k += 3) {
            const point = item.points[k .. k + 3];
            if (!(std.math.isFinite(point[0]) and std.math.isFinite(point[1]) and std.math.isFinite(point[2]))) continue;
            for (0..3) |axis| {
                low[axis] = @min(low[axis], point[axis]);
                high[axis] = @max(high[axis], point[axis]);
            }
        }
    }
    if (!(low[0] <= high[0])) {
        try out.writeAll(", \"track\": null}");
        return;
    }
    const span = @max(@max(high[0] - low[0], high[1] - low[1]), 20);
    const scale = @max(1, @round(0.25 * span / @max(high[2] - low[2], 1)));
    try out.writeAll(", \"track\": {\"lines\": [");
    for (lines, 0..) |item, index| {
        if (index > 0) try out.writeAll(", ");
        var name = item.name;
        if (std.mem.startsWith(u8, name, "★ ")) name = name["★ ".len..];
        const kind = @tagName(item.kind);
        const width: f64 = if (item.width > 0) item.width else if (item.kind == .segments) 1.5 else 2.5;
        try out.print("{{\"name\": {f}, \"kind\": \"{s}\", \"color\": {f}, \"width\": {d}, \"legend\": {}", .{ str(std.mem.trim(u8, name, " ")), kind, str(item.color), width, item.legend });
        if (item.kind == .points) try out.print(", \"marker\": {f}, \"size\": {d}", .{ str(item.marker), item.size });
        try out.writeAll(", \"points\": [");
        const count = item.points.len / 3;
        const step: usize = if (item.kind == .line and count > max_track_points) (count + max_track_points - 1) / max_track_points else 1;
        var written: usize = 0;
        var point_index: usize = 0;
        while (point_index < count) : (point_index += step) {
            try writeTrackPoint(out, item, point_index, scale, written > 0);
            written += 1;
            if (step > 1 and point_index + step >= count and point_index != count - 1) try writeTrackPoint(out, item, count - 1, scale, true);
        }
        try out.writeAll("]}");
    }
    try out.print("], \"scale\": {d}, \"low\": [{d}, {d}, {d}], \"high\": [{d}, {d}, {d}], \"axes\": ", .{ scale, low[0], low[1], low[2] * scale, high[0], high[1], high[2] * scale });
    var axes: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&axes, "eixos: {s}, {s}, h (altura exagerada ×{d})", .{ plot.xlabel, plot.ylabel, scale }) catch "eixos";
    try out.print("{f}}}}}", .{str(text)});
}

fn writeTrackPoint(out: *Writer, item: TrackLine, index: usize, scale: f64, comma: bool) !void {
    var point = [3]f64{ item.points[3 * index], item.points[3 * index + 1], item.points[3 * index + 2] * scale };
    if (item.kind == .segments and item.offsets.len >= 3 * index + 3) {
        for (0..3) |axis| point[axis] += item.offsets[3 * index + axis];
    }
    if (comma) try out.writeAll(", ");
    for (point, 0..) |value, axis| {
        if (axis > 0) try out.writeAll(", ");
        if (std.math.isFinite(value)) try out.print("{d:.3}", .{value}) else try out.writeAll("null");
    }
}

/// junta as retas de referência às curvas, como curvas de dois pontos de uma borda à outra do que as curvas
/// ocupam; um nome que já está na legenda não entra de novo
pub fn withGuides(memory: std.mem.Allocator, curves: []const Curve, guides: []const Guide) ![]Curve {
    var low_x = std.math.inf(f64);
    var high_x = -std.math.inf(f64);
    var low_y = std.math.inf(f64);
    var high_y = -std.math.inf(f64);
    for (curves) |curve| {
        if (curve.vspan) continue;
        for (curve.x) |value| if (std.math.isFinite(value)) {
            low_x = @min(low_x, value);
            high_x = @max(high_x, value);
        };
        for (curve.y) |value| if (std.math.isFinite(value)) {
            low_y = @min(low_y, value);
            high_y = @max(high_y, value);
        };
    }
    const all = try memory.alloc(Curve, curves.len + guides.len);
    @memcpy(all[0..curves.len], curves);
    for (guides, all[curves.len..], 0..) |guide, *curve, k| {
        const low = if (guide.vertical) low_y else low_x;
        const high = if (guide.vertical) high_y else high_x;
        const span: [2]f64 = if (low <= high) .{ low, high } else .{ guide.value - 1, guide.value + 1 };
        const across = try memory.dupe(f64, &span);
        const at = try memory.dupe(f64, &.{ guide.value, guide.value });
        const named = for (all[0 .. curves.len + k]) |other| {
            if (other.legend and std.mem.eql(u8, other.name, guide.name)) break true;
        } else false;
        curve.* = .{
            .name = guide.name,
            .x = if (guide.vertical) at else across,
            .y = if (guide.vertical) across else at,
            .color = guide.color,
            .dashed = guide.dashed,
            .legend = guide.legend and !named,
            .width = guide.width,
        };
    }
    return all;
}

/// um item do diagnóstico (`Check`)
pub const Check = struct {
    status: enum { ok, atencao, falha, info },
    item: []const u8,
    value: []const u8,
    criterion: []const u8 = "",
    why: []const u8 = "",
    fix: []const u8 = "",
    group: []const u8 = "",
    source: []const u8 = "",
};

/// uma coluna de uma tabela editável: número, texto, escolha ou só leitura ("label")
pub const Column = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { float, text, choice, label, check } = .float,
    choices: []const []const u8 = &.{},
    help: []const u8 = "",
};

/// uma célula: número, texto (o texto também vale para as escolhas e as de leitura) ou sim/não (as de marcar)
pub const Cell = union(enum) { number: f64, text: []const u8, flag: bool, empty };

/// um botão abaixo da tabela: o que ele pede (`GridEdit.operation`) e o rótulo
pub const Button = struct { operation: []const u8, label: []const u8, help: []const u8 = "" };

/// uma tabela editável da aba (como as `stages.Grid` do Python)
pub const Grid = struct {
    name: []const u8,
    title: []const u8,
    help: []const u8 = "",
    note: []const u8 = "",
    columns: []const Column,
    rows: []const []const Cell,
    buttons: []const Button = &.{},
};

/// uma peça da vista 3D: o tipo (a cor da tela: "wing", "tank", "payload"...) e os triângulos, no corpo
pub const Mesh = struct {
    kind: []const u8,
    vertices: []const [3]f64,
    faces: []const [3]u32,
};

/// uma caixa da vista 3D para onde a câmera aproxima (o dispositivo de ponta que se está criando)
pub const Focus = struct { low: [3]f64, high: [3]f64 };

/// a vista 3D da aba: as peças, o CG e, se houver, a peça em foco
pub const View = struct {
    meshes: []const Mesh,
    cg: ?[3]f64 = null,
    focus: ?Focus = null,
};

/// o que vem nos campos além do formulário: as tabelas e a vista 3D
pub const Extras = struct {
    grids: []const Grid = &.{},
    view: ?View = null,
};

/// `{"params": [...], "plots": [...], "description": ..., "grids": [...], "view": {...}}`
pub fn writeSpecs(out: *Writer, params: []const Param, plots: []const Plot, description: []const u8, extras: Extras) !void {
    try out.writeAll("{\"params\": [");
    try writeParams(out, params, &.{});
    try out.writeAll("], \"plots\": [");
    for (plots, 0..) |plot, k| {
        if (k > 0) try out.writeAll(", ");
        try writePlotHead(out, plot);
        try out.writeAll("}");
    }
    try out.print("], \"description\": {f}, \"grids\": [", .{str(description)});
    for (extras.grids, 0..) |grid, k| {
        if (k > 0) try out.writeAll(", ");
        try writeGrid(out, grid);
    }
    try out.writeAll("]");
    if (extras.view) |view| try writeView(out, view);
    try out.writeAll("}");
}

/// os campos do formulário, separados por vírgula; os de `disabled` aparecem em cinza
fn writeParams(out: *Writer, params: []const Param, disabled: []const []const u8) !void {
    for (params, 0..) |param, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"key\": {f}, \"label\": {f}, \"kind\": \"{s}\", \"default\": ", .{ str(param.key), str(param.label), @tagName(param.kind) });
        switch (param.default) {
            .number => |value| try out.print("{d}", .{value}),
            .toggle => |value| try out.writeAll(if (value) "true" else "false"),
            .text => |value| try out.print("{f}", .{str(value)}),
        }
        try out.writeAll(", \"minimum\": ");
        try optionalNumber(out, param.minimum);
        try out.writeAll(", \"maximum\": ");
        try optionalNumber(out, param.maximum);
        try out.print(", \"unit\": {f}, \"choices\": [", .{str(param.unit)});
        for (param.choices, 0..) |choice, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{f}", .{str(choice)});
        }
        var enabled = true;
        for (disabled) |key| enabled = enabled and !std.mem.eql(u8, key, param.key);
        try out.print("], \"group\": {f}, \"help\": {f}, \"rebuild\": {}, \"enabled\": {}}}", .{ str(param.group), str(param.help), param.rebuild, enabled });
    }
}

// ------------------------------------------------------------------ as etapas da sprint

/// um botão da etapa: `arg` diz o que a tela pede antes ("" nada, "text" um texto, "file" um arquivo)
pub const StageAction = struct { key: []const u8, label: []const u8, arg: []const u8 = "", help: []const u8 = "", default: []const u8 = "" };

/// uma tabela de leitura (massas, dimensões): os títulos e as linhas em texto
pub const Table = struct { title: []const u8, headers: []const []const u8, rows: []const []const []const u8 };

/// a página inteira de uma etapa (a resposta de `Bridge.stage` do Python): o formulário, os guardados, os botões,
/// as tabelas editáveis e a conta
pub const StagePage = struct {
    title: []const u8,
    help: []const u8 = "",
    keep_label: []const u8 = "Guardar",
    params: []const Param = &.{},
    disabled: []const []const u8 = &.{},
    kept: []const []const u8 = &.{},
    actions: []const StageAction = &.{},
    requirements: []const u8 = "",
    message: []const u8 = "",
    open: []const u8 = "",
    go: []const u8 = "",
    grids: []const Grid = &.{},
    tables: []const Table = &.{},
    summary: []const [2][]const u8 = &.{},
    checks: []const Check = &.{},
    figures: ?Figures = null,
    view: ?View = null,
    /// avisos que a tela mostra por cima da janela quando aparecem (a linha sustentadora numa asa curta)
    alerts: []const []const u8 = &.{},
};

/// a página da etapa em JSON, no formato que a tela lê
pub fn writeStagePage(out: *Writer, page: StagePage) !void {
    try out.print("{{\"title\": {f}, \"help\": {f}, \"keep_label\": {f}, \"requirements\": {f}, \"message\": {f}, \"open\": {f}, \"go\": {f}, \"params\": [", .{ str(page.title), str(page.help), str(page.keep_label), str(page.requirements), str(page.message), str(page.open), str(page.go) });
    try writeParams(out, page.params, page.disabled);
    try out.writeAll("], \"kept\": [");
    for (page.kept, 0..) |name, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{f}", .{str(name)});
    }
    try out.writeAll("], \"alerts\": [");
    for (page.alerts, 0..) |text, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{f}", .{str(text)});
    }
    try out.writeAll("], \"actions\": [");
    for (page.actions, 0..) |action, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"key\": {f}, \"label\": {f}, \"arg\": {f}, \"help\": {f}, \"default\": {f}}}", .{ str(action.key), str(action.label), str(action.arg), str(action.help), str(action.default) });
    }
    try out.writeAll("], \"grids\": [");
    for (page.grids, 0..) |grid, k| {
        if (k > 0) try out.writeAll(", ");
        try writeGrid(out, grid);
    }
    try out.writeAll("], \"tables\": [");
    for (page.tables, 0..) |table, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"title\": {f}, \"headers\": [", .{str(table.title)});
        for (table.headers, 0..) |header, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{f}", .{str(header)});
        }
        try out.writeAll("], \"rows\": [");
        for (table.rows, 0..) |row, r| {
            if (r > 0) try out.writeAll(", ");
            try out.writeAll("[");
            for (row, 0..) |cell, c| {
                if (c > 0) try out.writeAll(", ");
                try out.print("{f}", .{str(cell)});
            }
            try out.writeAll("]");
        }
        try out.writeAll("]}");
    }
    try out.writeAll("], \"summary\": {");
    for (page.summary, 0..) |row, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{f}: {f}", .{ str(row[0]), str(row[1]) });
    }
    try out.writeAll("}, \"checks\": [");
    for (page.checks, 0..) |item, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"status\": \"{s}\", \"item\": {f}, \"value\": {f}, \"criterion\": {f}, \"why\": {f}, \"fix\": {f}, \"group\": {f}, \"source\": {f}}}", .{
            @tagName(item.status), str(item.item), str(item.value), str(item.criterion), str(item.why), str(item.fix), str(item.group), str(item.source),
        });
    }
    try out.writeAll("], \"plots\": [");
    if (page.figures) |figures| try figures.write(out, true);
    try out.writeAll("]");
    if (page.view) |view| try writeView(out, view);
    try out.writeAll("}");
}

fn writeGrid(out: *Writer, grid: Grid) !void {
    try out.print("{{\"name\": {f}, \"title\": {f}, \"help\": {f}, \"note\": {f}, \"columns\": [", .{ str(grid.name), str(grid.title), str(grid.help), str(grid.note) });
    for (grid.columns, 0..) |column, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"key\": {f}, \"label\": {f}, \"kind\": \"{s}\", \"help\": {f}, \"choices\": [", .{ str(column.key), str(column.label), @tagName(column.kind), str(column.help) });
        for (column.choices, 0..) |choice, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{f}", .{str(choice)});
        }
        try out.writeAll("]}");
    }
    try out.writeAll("], \"rows\": [");
    for (grid.rows, 0..) |row, r| {
        if (r > 0) try out.writeAll(", ");
        try out.writeAll("[");
        for (row, 0..) |cell, c| {
            if (c > 0) try out.writeAll(", ");
            switch (cell) {
                .number => |value| if (std.math.isFinite(value)) try out.print("{d}", .{value}) else try out.writeAll("null"),
                .text => |value| try out.print("{f}", .{str(value)}),
                .flag => |value| try out.writeAll(if (value) "true" else "false"),
                .empty => try out.writeAll("null"),
            }
        }
        try out.writeAll("]");
    }
    try out.writeAll("], \"buttons\": [");
    for (grid.buttons, 0..) |button, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("[{f}, {f}, {f}]", .{ str(button.operation), str(button.label), str(button.help) });
    }
    try out.writeAll("]}");
}

/// `, "view": {"meshes": [{"kind", "vertices": [x, y, z, ...], "faces": [a, b, c, ...]}], "markers": {"cg": [...]}}`
fn writeView(out: *Writer, view: View) !void {
    try out.writeAll(", \"view\": {\"meshes\": [");
    for (view.meshes, 0..) |mesh, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"kind\": {f}, \"vertices\": [", .{str(mesh.kind)});
        for (mesh.vertices, 0..) |point, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{d:.4}, {d:.4}, {d:.4}", .{ point[0], point[1], point[2] });
        }
        try out.writeAll("], \"faces\": [");
        for (mesh.faces, 0..) |face, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{d}, {d}, {d}", .{ face[0], face[1], face[2] });
        }
        try out.writeAll("]}");
    }
    try out.writeAll("], \"markers\": {");
    if (view.cg) |point| try out.print("\"cg\": [{d}, {d}, {d}]", .{ point[0], point[1], point[2] });
    if (view.focus) |box| try out.print("{s}\"focus\": [{d}, {d}, {d}, {d}, {d}, {d}]", .{ if (view.cg != null) ", " else "", box.low[0], box.low[1], box.low[2], box.high[0], box.high[1], box.high[2] });
    try out.writeAll("}}");
}

/// o começo do resultado: `{"status": ..., "summary": {...}, "checks": [...], "plots": [` (as curvas vêm depois, com
/// `writePlot`, e `endResult` fecha)
pub fn beginResult(out: *Writer, summary: []const [2][]const u8, checks: []const Check) !void {
    try out.writeAll("{\"status\": \"ok\", \"summary\": {");
    for (summary, 0..) |row, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{f}: {f}", .{ str(row[0]), str(row[1]) });
    }
    try out.writeAll("}, \"checks\": [");
    for (checks, 0..) |item, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"status\": \"{s}\", \"item\": {f}, \"value\": {f}, \"criterion\": {f}, \"why\": {f}, \"fix\": {f}, \"group\": {f}, \"source\": {f}}}", .{
            @tagName(item.status), str(item.item), str(item.value), str(item.criterion), str(item.why), str(item.fix), str(item.group), str(item.source),
        });
    }
    try out.writeAll("], \"plots\": [");
}

/// um gráfico do resultado com as curvas (`first`: é o primeiro da lista)
/// um campo pintado nas faces da vista de cargas (um valor por face)
pub const LoadsField = struct { name: []const u8, label: []const u8, signed: bool, values: []const f64 };
/// uma camada de setas da vista de cargas (origens e vetores em listas planas x, y, z)
pub const LoadsVectors = struct { name: []const u8, unit: []const u8, color: [4]f64, origins: []const f64, vectors: []const f64 };
/// uma malha do resto do avião (fuselagem, motor...), desenhada sem campo
/// uma malha do desenho do avião na vista de cargas; numa superfície, `nearest` diz a face do método mais perto de
/// cada vértice (a cor vem dela)
pub const LoadsMesh = struct { kind: []const u8, vertices: []const f64, faces: []const u32, nearest: []const u32 = &.{} };

/// a vista 3D de uma análise de carga (a `LoadView` da GUI PyQt, o `_loads` da ponte): a malha das faixas em
/// triângulos, a face de origem de cada triângulo, os campos por face, as setas, o resto do avião e o texto do caso
pub const LoadsView = struct {
    vertices: []const f64,
    triangles: []const u32,
    face: []const u32,
    fields: []const LoadsField,
    vectors: []const LoadsVectors,
    rest: []const LoadsMesh = &.{},
    /// as superfícies do desenho do avião, com espessura (pintadas pela face do método mais perto)
    surfaces: []const LoadsMesh = &.{},
    /// para onde o ar vai, nos eixos do corpo, e o texto da seta do vento relativo
    wind: ?[3]f64 = null,
    wind_label: []const u8 = "",
    info: []const u8 = "",
    elevation: ?f64 = null,
    azimuth: ?f64 = null,
};

fn indexList(out: *Writer, values: []const u32) !void {
    try out.writeAll("[");
    for (values, 0..) |value, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{d}", .{value});
    }
    try out.writeAll("]");
}

/// um gráfico "loads3d" com a vista de cargas
pub fn writeLoads(out: *Writer, plot: Plot, view: LoadsView, first: bool) !void {
    if (!first) try out.writeAll(", ");
    try out.print("{{\"key\": {f}, \"title\": {f}, \"xlabel\": \"\", \"ylabel\": \"\", \"kind\": \"loads3d\", \"loads\": {{\"vertices\": ", .{ str(plot.key), str(plot.title) });
    try numbers(out, view.vertices);
    try out.writeAll(", \"triangles\": ");
    try indexList(out, view.triangles);
    try out.writeAll(", \"face\": ");
    try indexList(out, view.face);
    try out.writeAll(", \"fields\": [");
    for (view.fields, 0..) |field, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"name\": {f}, \"label\": {f}, \"signed\": {}, \"values\": ", .{ str(field.name), str(field.label), field.signed });
        try numbers(out, field.values);
        try out.writeAll("}");
    }
    try out.writeAll("], \"vectors\": [");
    for (view.vectors, 0..) |layer, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"name\": {f}, \"unit\": {f}, \"color\": ", .{ str(layer.name), str(layer.unit) });
        try numbers(out, &layer.color);
        try out.writeAll(", \"origins\": ");
        try numbers(out, layer.origins);
        try out.writeAll(", \"vectors\": ");
        try numbers(out, layer.vectors);
        try out.writeAll("}");
    }
    try out.writeAll("], \"rest\": [");
    for (view.rest, 0..) |mesh, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"kind\": {f}, \"vertices\": ", .{str(mesh.kind)});
        try numbers(out, mesh.vertices);
        try out.writeAll(", \"faces\": ");
        try indexList(out, mesh.faces);
        try out.writeAll("}");
    }
    try out.writeAll("], \"surfaces\": [");
    for (view.surfaces, 0..) |mesh, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"kind\": {f}, \"vertices\": ", .{str(mesh.kind)});
        try numbers(out, mesh.vertices);
        try out.writeAll(", \"faces\": ");
        try indexList(out, mesh.faces);
        try out.writeAll(", \"nearest\": ");
        try indexList(out, mesh.nearest);
        try out.writeAll("}");
    }
    try out.writeAll("]");
    if (view.wind) |direction| {
        try out.writeAll(", \"wind\": {\"direction\": ");
        try numbers(out, &direction);
        try out.print(", \"label\": {f}}}", .{str(view.wind_label)});
    }
    try out.print(", \"info\": {f}, \"camera\": {{", .{str(view.info)});
    if (view.elevation) |value| try out.print("\"elevation\": {d}", .{value});
    if (view.azimuth) |value| try out.print("{s}\"azimuth\": {d}", .{ if (view.elevation != null) ", " else "", value });
    try out.writeAll("}}}");
}

pub fn writePlot(out: *Writer, plot: Plot, curves: []const Curve, first: bool) !void {
    if (!first) try out.writeAll(", ");
    try writePlotHead(out, plot);
    try out.writeAll(", \"curves\": [");
    for (curves, 0..) |curve, k| {
        if (k > 0) try out.writeAll(", ");
        try out.print("{{\"name\": {f}, \"color\": {f}, \"dashed\": {}, \"marker\": {f}, \"size\": {d}, \"legend\": {}, \"x\": ", .{ str(curve.name), str(curve.color), curve.dashed, str(curve.marker), curve.size, curve.legend });
        try numbers(out, curve.x);
        try out.writeAll(", \"y\": ");
        try numbers(out, curve.y);
        if (curve.width > 0) try out.print(", \"width\": {d}", .{curve.width});
        if (curve.fill.len > 0) {
            try out.writeAll(", \"fill\": ");
            try numbers(out, curve.fill);
        }
        if (curve.fill_x.len > 0) {
            try out.writeAll(", \"fill_x\": ");
            try numbers(out, curve.fill_x);
        }
        if (curve.strong) try out.writeAll(", \"strong\": true");
        if (curve.vspan) try out.writeAll(", \"vspan\": true");
        if (curve.line) try out.writeAll(", \"line\": true");
        try out.writeAll("}");
    }
    try out.writeAll("]}");
}

/// fecha o resultado
pub fn endResult(out: *Writer) !void {
    try out.writeAll("]}");
}

fn writePlotHead(out: *Writer, plot: Plot) !void {
    try out.print("{{\"key\": {f}, \"title\": {f}, \"xlabel\": {f}, \"ylabel\": {f}, \"kind\": \"{s}\"", .{ str(plot.key), str(plot.title), str(plot.xlabel), str(plot.ylabel), if (plot.kind == .track) "3d" else "2d" });
    if (plot.x_limits) |window| try out.print(", \"xlim\": [{d}, {d}]", .{ window[0], window[1] });
    if (plot.y_limits) |window| try out.print(", \"ylim\": [{d}, {d}]", .{ window[0], window[1] });
}

fn numbers(out: *Writer, values: []const f64) !void {
    try out.writeAll("[");
    for (values, 0..) |value, k| {
        if (k > 0) try out.writeAll(", ");
        if (std.math.isFinite(value)) try out.print("{d}", .{value}) else try out.writeAll("null");
    }
    try out.writeAll("]");
}

fn optionalNumber(out: *Writer, value: ?f64) !void {
    if (value) |number| try out.print("{d}", .{number}) else try out.writeAll("null");
}

fn str(text: []const u8) std.json.Formatter([]const u8) {
    return std.json.fmt(text, .{});
}


test "os métodos saem dos campos pelo nome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = Values.fromRequest(arena.allocator(), "\"values\": {\"aero_model\": \"lifting_line\", \"slipstream_span_samples\": 99}");
    const methods = values.methods();
    try std.testing.expectEqual(core.types.AeroModel.lifting_line, methods.aero_model);
    try std.testing.expectEqual(core.types.LiftingLineMethod.phillips_snyder, methods.llt_method);
    try std.testing.expectEqual(@as(i32, 64), methods.refinement.slipstream_span_samples);
    try std.testing.expectEqual(Methods{}, (Values{}).methods());
    var buffer: [8]f64 = undefined;
    const list = Values.fromRequest(arena.allocator(), "\"values\": {\"thr\": [1.0, 0.75, 0.5]}").numbers("thr", &buffer, &.{1});
    try std.testing.expectEqualSlices(f64, &.{ 1.0, 0.75, 0.5 }, list);
    try std.testing.expectEqualSlices(f64, &.{1}, (Values{}).numbers("thr", &buffer, &.{1}));
}

//! Analisar em Zig (o par de `wings.py`): a aerodinâmica só das superfícies escolhidas do avião aberto (uma asa, um
//! biplano, um tandem, asa e canard), sem trimar, sem fuselagem e sem hélice, como num túnel de vento. Cada α imposto
//! dá a sustentação de cada superfície pela varredura do núcleo (`core/src/loads/sweep.zig`), e o resumo do núcleo
//! tira o C_L do conjunto e de cada uma, o C_L máximo e onde o estol começa. No α da carga sai a distribuição ao longo
//! da envergadura, e o Reynolds de cada superfície entra no diagnóstico.
//!
//! A comparação dos métodos de polar do núcleo (faixas e as duas linhas sustentadoras) roda aqui nas superfícies
//! escolhidas, e o avião completo (`aerodynamics.zig`) no avião aberto inteiro.
//!
//! O que vem de fora do núcleo roda pelo Python, só quando é pedido (`python`): as asas da sprint ou da tabela de
//! Projetar, as chapas de ponta, o VLM do AeroSandbox como método de carga, os métodos de polar de fora (lltdrek,
//! AeroSandbox, AVL). No site, o pacote desses métodos só é baixado quando um deles é marcado.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const alert_rules = @import("../alerts.zig");
const aerodynamics = @import("aerodynamics.zig");

const params_mod = aircraft_model.params;
const model = aircraft_model.aircraft;
const sweep = core.sweep;
const max_panels = core.limits.max_surfaces;
const rad = std.math.pi / 180.0;

/// a análise, com a interface de `simulation.check`
pub const Wings = struct {
    pub const name: []const u8 = "wings";
    pub const title: [:0]const u8 = "Analisar";
    pub const area: []const u8 = "Aerodinâmica";
    pub const description: []const u8 = "Aerodinâmica só das superfícies escolhidas (uma asa, biplano, tandem, canard), sem trimar, sem fuselagem e sem hélice, como no túnel: C_L em α de cada superfície e do conjunto, C_L máximo, onde o estol começa e a carga ao longo da envergadura. O avião completo (polares no CG, profundor, derrapagem, L/D) roda no núcleo; os métodos de fora (AeroSandbox, lltdrek, AVL) rodam pelo Python quando marcados.";
    pub const State = RunState;
    pub const specs = writeFields;
    pub const start = startRun;
    pub const advance = advanceRun;
    pub const result = writeResult;
    pub const python = needsPython;
    pub const alerts = runAlerts;
    pub const standalone = fromSprint;
};

/// de onde vêm as asas: o avião aberto na Montagem, as asas guardadas do projeto (cada uma no x e na altura do
/// formulário) ou uma configuração guardada em Projetar (as asas no lugar delas, como a tabela "Asas do avião")
const SourceKind = enum { open, wings, config };
const open_prefix = "avião aberto";
const wings_prefix = "asas guardadas";
const config_prefix = "configuração: ";

fn kindOf(source: []const u8) SourceKind {
    if (std.mem.startsWith(u8, source, wings_prefix)) return .wings;
    if (std.mem.startsWith(u8, source, config_prefix)) return .config;
    return .open;
}

/// as asas guardadas na etapa Asa (vazio sem projeto)
fn sprintNames(memory: std.mem.Allocator) ![]const []const u8 {
    const sprint = simulation.sprint orelse return &.{};
    return sprint.wing_names(memory);
}

/// as opções da fonte, pelo nome: o avião aberto, as asas guardadas e cada configuração do projeto
fn sourceChoices(memory: std.mem.Allocator, aircraft: ?*const simulation.Aircraft) ![]const []const u8 {
    var choices: std.ArrayList([]const u8) = .empty;
    if (aircraft) |plane| if (plane.surfaces.len > 0) try choices.append(memory, try std.fmt.allocPrint(memory, "{s}: {s}", .{ open_prefix, plane.name }));
    if (simulation.sprint) |sprint| {
        const project = try sprint.project_name(memory);
        const names = try sprint.wing_names(memory);
        // as configurações primeiro: são o avião como Projetar montou
        for (try sprint.config_names(memory)) |name| try choices.append(memory, try std.fmt.allocPrint(memory, "{s}{s}", .{ config_prefix, name }));
        if (names.len > 0) try choices.append(memory, if (project.len > 0) try std.fmt.allocPrint(memory, "{s} do projeto {s} ({d})", .{ wings_prefix, project, names.len }) else try std.fmt.allocPrint(memory, "{s} do projeto ({d})", .{ wings_prefix, names.len }));
    }
    if (choices.items.len == 0) try choices.append(memory, "nenhum avião aberto nem asa guardada");
    return choices.items;
}

/// a fonte escolhida (a primeira das opções se a de antes sumiu)
fn sourceOf(memory: std.mem.Allocator, aircraft: ?*const simulation.Aircraft, values: simulation.Values) ![]const u8 {
    const choices = try sourceChoices(memory, aircraft);
    const chosen = values.text("source", choices[0]);
    for (choices) |choice| if (std.mem.eql(u8, choice, chosen)) return choice;
    // a de antes pelo tipo (o nome do avião ou o número de asas mudou)
    for (choices) |choice| if (kindOf(choice) == kindOf(chosen) and kindOf(chosen) != .config) return choice;
    return choices[0];
}

/// a prévia 3D das superfícies que entram (as peças da Montagem, só as de asa, cauda, comando e dispositivo)
fn previewOf(memory: std.mem.Allocator, plane: *const simulation.Aircraft) ?simulation.View {
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const built = aircraft_model.skeleton.build(memory, plane, &diagnosis) catch return null;
    var meshes: std.ArrayList(simulation.Mesh) = .empty;
    for (built.pieces) |piece| switch (piece.color) {
        .wing, .htail, .vtail, .control, .device => meshes.append(memory, .{ .kind = @tagName(piece.color), .vertices = piece.mesh.v, .faces = piece.mesh.f }) catch return null,
        else => {},
    };
    return .{ .meshes = meshes.items };
}

/// as asas do projeto rodam sem o avião aberto
fn fromSprint(values: simulation.Values) bool {
    return kindOf(values.text("source", open_prefix)) != .open;
}

/// o avião com as asas da fonte escolhida (`sprint_aircraft` do Python para as asas guardadas); o resto (ambiente)
/// vem de `base`
fn sourceAircraft(memory: std.mem.Allocator, base: *const simulation.Aircraft, source: []const u8, values: simulation.Values) !simulation.Aircraft {
    const kind = kindOf(source);
    if (kind == .open) return base.*;
    var plane = base.*;
    const sprint = simulation.sprint orelse return error.Failed;
    var surfaces: std.ArrayList(model.Surface) = .empty;
    if (kind == .config) {
        for (try sprint.config(memory, source[config_prefix.len..])) |surface| {
            var placed = surface;
            placed.role = "wing";
            try surfaces.append(memory, placed);
        }
        plane.name = source;
    } else {
        for (try sprintNames(memory), 0..) |name, i| {
            if (!values.toggle(try std.fmt.allocPrint(memory, "sprint_{d}", .{i}), i == 0)) continue;
            var surface = (try sprint.wing(memory, name)) orelse continue;
            surface.x = values.number(try std.fmt.allocPrint(memory, "x_{d}", .{i}), 0);
            surface.z = -values.number(try std.fmt.allocPrint(memory, "h_{d}", .{i}), 0); // z do corpo para baixo
            surface.incidence = 0; // α da varredura = α da corda da raiz
            surface.role = "wing";
            try surfaces.append(memory, surface);
        }
        plane.name = "asas guardadas";
    }
    plane.surfaces = surfaces.items;
    return plane;
}
pub const none = "nenhum";

/// os métodos de carga, com os mesmos títulos do Python (`aerosim.aero.all_load_methods`)
pub const LoadMethod = enum {
    llt,
    llt_gh,
    llt_nl,
    faixas,
    vlm_asb,

    /// o título na tela (o mesmo do Python)
    pub fn title(method: LoadMethod) []const u8 {
        return switch (method) {
            .llt => "linha sustentadora (Phillips e Snyder)",
            .llt_gh => "linha sustentadora (Goates e Hunsaker)",
            .llt_nl => "linha sustentadora não linear (estol por perfil)",
            .faixas => "faixas (o C_Lα da simulação)",
            .vlm_asb => "VLM do AeroSandbox",
        };
    }

    /// o método pelo título da tela
    pub fn fromTitle(shown: []const u8) ?LoadMethod {
        for (std.enums.values(LoadMethod)) |method| if (std.mem.eql(u8, method.title(), shown)) return method;
        return null;
    }

    /// o núcleo faz este método (senão ele é do Python)
    pub fn inCore(method: LoadMethod) bool {
        return method != .vlm_asb;
    }
};

/// os títulos dos métodos, na ordem do Python
pub const method_titles = blk: {
    var titles: [std.enums.values(LoadMethod).len][]const u8 = undefined;
    for (std.enums.values(LoadMethod), 0..) |method, i| titles[i] = method.title();
    const frozen = titles;
    break :blk frozen;
};
/// "nenhum" e os métodos, para o campo de comparar
pub const compare_titles = [_][]const u8{none} ++ method_titles;

/// os solvers da comparação dos métodos (os mesmos do Python, `SOLVERS`): os do núcleo rodam aqui, os outros pelo
/// Python; o modelo interno vem marcado
const Solver = struct { key: []const u8, label: []const u8, core: ?aerodynamics.Solver = null, on: bool = false };
const solvers = [_]Solver{
    .{ .key = "lltdrek", .label = "lltdrek (linha sustentadora não linear; pelo Python)" },
    .{ .key = "zig", .label = "modelo interno (faixas da simulação)", .core = .zig, .on = true },
    .{ .key = "zig_llt_gh", .label = "linha sustentadora do núcleo (Goates e Hunsaker)", .core = .zig_llt_gh },
    .{ .key = "zig_llt", .label = "linha sustentadora do núcleo (Phillips e Snyder)", .core = .zig_llt },
    .{ .key = "asb_vlm", .label = "AeroSandbox VLM (pelo Python)" },
    .{ .key = "asb_buildup", .label = "AeroSandbox AeroBuildup (pelo Python)" },
    .{ .key = "asb_ll", .label = "AeroSandbox LiftingLine (pelo Python)" },
    .{ .key = "avl", .label = "AVL (pelo Python)" },
};

/// Reynolds crítico dos perfis de aeromodelo: abaixo dele a bolha laminar tende a não recolar (Lissaman,
/// "Low-Reynolds-number airfoils", Annual Review of Fluid Mechanics 15, 1983; valor a conferir no PDF)
const critical_reynolds = 7e4;
const colors = [_][]const u8{ "#1f4e8c", "#d95f02", "#2ca02c", "#9467bd" };
const surface_colors = [_][]const u8{ "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#17becf" };
pub const max_per_side = 40; // `MAX_PER_SIDE` do Python

const plots = [_]simulation.Plot{
    .{ .key = "CL", .title = "C_L × α do conjunto", .xlabel = "α (°)", .ylabel = "C_L (soma das áreas)" },
    .{ .key = "CL_surf", .title = "C_L × α por superfície", .xlabel = "α (°)", .ylabel = "C_L (área dela)" },
    .{ .key = "cl_span", .title = "c_l × y", .xlabel = "y (m)", .ylabel = "c_l" },
    .{ .key = "L_span", .title = "L' × y", .xlabel = "y (m)", .ylabel = "L' (N/m)" },
    .{ .key = "pol_CL", .title = "Métodos: C_L × α", .xlabel = "α (°)", .ylabel = "C_L (soma das áreas)" },
    .{ .key = "pol_CD", .title = "Métodos: C_L × C_D", .xlabel = "C_D", .ylabel = "C_L (soma das áreas)" },
    .{ .key = "pol_Cm", .title = "Métodos: C_m × α", .xlabel = "α (°)", .ylabel = "C_m (soma das áreas, CMA da principal)" },
    .{ .key = "pol_LD", .title = "Métodos: L/D × C_L", .xlabel = "C_L", .ylabel = "L/D" },
} ++ aerodynamics.plots;

/// um método varrido: o C_L do conjunto e de cada dono em cada α, o resumo e a carga no α da carga
const MethodRun = struct {
    method: LoadMethod,
    total_cl: []f64,
    owner_cl: []f64, // α × dono
    summary: sweep.Summary,
    panel_owner: []i32,
    load_owner: []i32, // o dono de cada painel no α da carga
    load_span: []f64,
    load_cl: []f64,
    load_chord: []f64,
};

const RunState = struct {
    alphas: []f64 = &.{},
    alpha_load: f64 = 10,
    airspeed: f64 = 12,
    density: f64 = 1.225,
    owners: []const []const u8 = &.{},
    owner_area: []f64 = &.{},
    owner_chord: []f64 = &.{},
    runs: []MethodRun = &.{},
    density_altitude: f64 = 0,
    failure: []const u8 = "",
    // o que a comparação dos métodos e o avião completo já deixaram (calculado no começo, escrito no resultado)
    summary: std.ArrayList([2][]const u8) = .empty,
    checks: std.ArrayList(simulation.Check) = .empty,
    figures: ?simulation.Figures = null,
};

/// as superfícies ligadas do avião (as que dá para escolher)
fn surfaceKey(memory: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(memory, "surf_{d}", .{index});
}

fn writeFields(out: *simulation.Writer, aircraft: ?*const simulation.Aircraft, values: simulation.Values) simulation.Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var params: std.ArrayList(simulation.Param) = .empty;
    const source = try sourceOf(memory, aircraft, values);
    const kind = kindOf(source);
    const where = "De onde vêm as asas";
    try params.append(memory, .{ .key = "source", .label = "asas de", .kind = .choice, .default = .{ .text = source }, .choices = try sourceChoices(memory, aircraft), .group = where, .rebuild = true, .help = "o avião aberto na Montagem, as asas guardadas do projeto (sem avião aberto) ou uma configuração guardada em Projetar; a vista mostra o que entra" });
    if (kind == .wings) {
        const names = try sprintNames(memory);
        for (names, 0..) |name, i| try params.appendSlice(memory, &.{
            .{ .key = try std.fmt.allocPrint(memory, "sprint_{d}", .{i}), .label = try std.fmt.allocPrint(memory, "incluir: {s}", .{name}), .kind = .bool, .default = .{ .toggle = i == 0 }, .group = "Superfícies", .rebuild = true },
            .{ .key = try std.fmt.allocPrint(memory, "x_{d}", .{i}), .label = try std.fmt.allocPrint(memory, "{s}: x do bordo de ataque da raiz", .{name}), .default = .{ .number = 0 }, .minimum = -5, .maximum = 5, .unit = "m", .group = "Superfícies", .rebuild = true, .help = "+ para a frente; tandem e canard: uma asa à frente da outra" },
            .{ .key = try std.fmt.allocPrint(memory, "h_{d}", .{i}), .label = try std.fmt.allocPrint(memory, "{s}: altura", .{name}), .default = .{ .number = 0 }, .minimum = -3, .maximum = 3, .unit = "m", .group = "Superfícies", .rebuild = true, .help = "biplano: a asa de cima mais alta" },
        });
    }
    // as superfícies da fonte, para marcar quais entram (no avião aberto: as asas marcadas, as caudas não)
    const empty_plane: simulation.Aircraft = .{};
    const base = aircraft orelse &empty_plane;
    const plane = sourceAircraft(memory, base, source, values) catch base.*;
    if (kind != .wings) for (plane.surfaces, 0..) |surface, i| {
        if (!surface.enabled) continue;
        try params.append(memory, .{ .key = try surfaceKey(memory, i), .label = try std.fmt.allocPrint(memory, "incluir: {s}", .{surface.name}), .kind = .bool, .default = .{ .toggle = std.mem.eql(u8, surface.role, "wing") }, .group = "Superfícies", .rebuild = true });
    };
    // a prévia: só as superfícies que entram, sem fuselagem nem hélice
    const shown = wingsOnly(memory, &plane, values) catch plane;
    var marked: std.ArrayList(model.Surface) = .empty;
    for (shown.surfaces) |surface| if (surface.enabled) try marked.append(memory, surface);
    const bare: simulation.Aircraft = .{ .name = "prévia", .surfaces = marked.items };
    const preview = previewOf(memory, &bare);
    const case = "Caso";
    const loads = "Carga ao longo da envergadura";
    try params.appendSlice(memory, &.{
        .{ .key = "V", .label = "velocidade", .default = .{ .number = 12 }, .minimum = 2, .maximum = 80, .unit = "m/s", .group = case },
        .{ .key = "a0", .label = "α inicial", .default = .{ .number = -4 }, .minimum = -20, .maximum = 10, .unit = "°", .group = case },
        .{ .key = "a1", .label = "α final", .default = .{ .number = 22 }, .minimum = 2, .maximum = 40, .unit = "°", .group = case },
        .{ .key = "da", .label = "passo de α", .default = .{ .number = 1 }, .minimum = 0.25, .maximum = 5, .unit = "°", .group = case },
        .{ .key = "alpha_load", .label = "α da carga", .default = .{ .number = 10 }, .minimum = -10, .maximum = 40, .unit = "°", .group = case },
        .{ .key = "endplate", .label = "chapas nas pontas (altura / corda da ponta)", .default = .{ .number = 0 }, .minimum = 0, .maximum = 5, .group = case, .help = "0: sem chapas; > 0 roda pelo Python" },
        .{ .key = "xref", .label = "ponto dos momentos", .default = .{ .number = 25 }, .minimum = 0, .maximum = 100, .unit = "% CMA", .group = case },
        .{ .key = "method", .label = "método", .kind = .choice, .default = .{ .text = LoadMethod.llt_nl.title() }, .choices = &method_titles, .group = loads, .help = "o VLM do AeroSandbox roda pelo Python" },
        .{ .key = "compare", .label = "comparar com", .kind = .choice, .default = .{ .text = none }, .choices = &compare_titles, .group = loads },
        .{ .key = "vlm_span", .label = "VLM: faixas por lado", .kind = .int, .default = .{ .number = 0 }, .minimum = 0, .maximum = 200, .group = loads, .help = "refino do VLM; 0: o padrão (40)" },
        .{ .key = "vlm_chord", .label = "VLM: painéis na corda", .kind = .int, .default = .{ .number = 0 }, .minimum = 0, .maximum = 40, .group = loads, .help = "refino do VLM; 0: o padrão (6)" },
    });
    try appendStallFields(memory, &params, values);
    try appendGroundFields(memory, &params, values);
    if (kind == .open) {
        const whole = values.toggle("whole", if (aircraft) |opened| aerodynamics.ready(opened) else false);
        try params.append(memory, .{ .key = "whole", .label = "analisar também o avião completo", .kind = .bool, .default = .{ .toggle = whole }, .group = aerodynamics.group, .rebuild = true, .help = "o avião aberto inteiro, como voa: polares no CG, profundor e derrapagem, estol × cruzeiro, L/D" });
        if (whole) try aerodynamics.appendFields(memory, &params, aircraft);
    }
    const methods = "Comparação dos métodos (polares)";
    for (solvers) |solver| try params.append(memory, .{ .key = try std.fmt.allocPrint(memory, "use_{s}", .{solver.key}), .label = solver.label, .kind = .bool, .default = .{ .toggle = solver.on }, .group = methods });
    try params.appendSlice(memory, &.{
        .{ .key = "section", .label = "polar 2D dos perfis no lltdrek", .kind = .choice, .default = .{ .text = "modelo" }, .choices = &.{ "modelo", "neuralfoil" }, .group = methods },
        .{ .key = "n_span", .label = "painéis por semiasa", .kind = .int, .default = .{ .number = 12 }, .minimum = 4, .maximum = 40, .group = methods },
        .{ .key = "n_chord", .label = "painéis na corda (VLM, AVL)", .kind = .int, .default = .{ .number = 0 }, .minimum = 0, .maximum = 40, .group = methods },
    });
    try simulation.writeSpecs(out, params.items, &plots, Wings.description, .{ .view = preview });
}

/// o aviso da linha sustentadora (o método, a comparação ou uma polar) numa asa curta (`alerts.shortWing`)
fn runAlerts(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, values: simulation.Values) simulation.Error![]const []const u8 {
    var methods: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "method", "compare" }) |key| if (LoadMethod.fromTitle(values.text(key, none))) |method| {
        if (method == .llt or method == .llt_gh or method == .llt_nl) try methods.append(memory, method.title());
    };
    // as caixas da comparação dos métodos (polares) que são linha sustentadora
    var buffer: [32]u8 = undefined;
    for (solvers) |solver| {
        const lifting = std.mem.indexOf(u8, solver.label, "linha sustentadora") != null or std.mem.eql(u8, solver.key, "asb_ll");
        if (!lifting) continue;
        const key = std.fmt.bufPrint(&buffer, "use_{s}", .{solver.key}) catch continue;
        if (values.toggle(key, solver.on)) try methods.append(memory, solver.label);
    }
    if (methods.items.len == 0) return &.{};
    const warning = (try alert_rules.shortWing(memory, aircraft, methods.items[0], values)) orelse return &.{};
    return memory.dupe([]const u8, &.{warning});
}

/// a rodada precisa do Python: uma fonte de asas, um método ou uma comparação de fora do núcleo
fn needsPython(values: simulation.Values) bool {

    if (values.number("endplate", 0) > 0) return true;
    for ([_][]const u8{ "method", "compare" }) |key| if (LoadMethod.fromTitle(values.text(key, none))) |method| {
        if (!method.inCore()) return true;
    };
    var buffer: [32]u8 = undefined;
    for (solvers) |solver| {
        if (solver.core != null) continue;
        const key = std.fmt.bufPrint(&buffer, "use_{s}", .{solver.key}) catch continue;
        if (values.toggle(key, solver.on)) return true;
    }
    return false;
}

// ------------------------------------------------------------------ o avião só com as asas

/// o avião só com as superfícies escolhidas: sem fuselagem, sem motores, sem tanques e sem carga
fn wingsOnly(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, values: simulation.Values) !simulation.Aircraft {
    var plane = aircraft.*;
    plane.fuselage.enabled = false;
    const units = try memory.dupe(model.Propulsion, aircraft.propulsion);
    for (units) |*unit| unit.enabled = false;
    plane.propulsion = units;
    plane.tanks = &.{};
    plane.payload.enabled = false;
    plane.gear.layout = "custom";
    const surfaces = try memory.dupe(model.Surface, aircraft.surfaces);
    for (surfaces, 0..) |*surface, i| {
        if (!surface.enabled) continue;
        surface.enabled = values.toggle(try surfaceKey(memory, i), std.mem.eql(u8, surface.role, "wing"));
    }
    plane.surfaces = surfaces;
    return plane;
}

/// cópia do avião com a superfície `index` em `per_side` faixas da mesma geometria (`refine_surface` do Python); com
/// `tip`, faixas mais estreitas na ponta (y = y0 + (y1 − y0) sen(π t/2), o espaçamento que Phillips e Snyder (2000)
/// recomendam para a linha sustentadora convergir)
pub fn refined(memory: std.mem.Allocator, plane: simulation.Aircraft, index: usize, per_side: usize, tip: bool) !simulation.Aircraft {
    const surface = plane.surfaces[index];
    if (surface.sections.len < 2 or model.mixedAirfoils(&surface)) return plane;
    const sorted = try memory.dupe(model.Section, surface.sections);
    std.mem.sort(model.Section, sorted, {}, struct {
        fn less(_: void, a: model.Section, b: model.Section) bool {
            return a.y < b.y;
        }
    }.less);
    const first = sorted[0].y;
    const last = sorted[sorted.len - 1].y;
    var candidates: std.ArrayList(f64) = .empty;
    for (0..per_side + 1) |k| {
        var t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(per_side));
        if (tip) t = @sin(0.5 * std.math.pi * t);
        try candidates.append(memory, first + (last - first) * t);
    }
    for (sorted) |section| try candidates.append(memory, section.y);
    std.mem.sort(f64, candidates.items, {}, std.sort.asc(f64));
    var stations: std.ArrayList(f64) = .empty;
    for (candidates.items) |y| {
        if (stations.items.len == 0 or y - stations.items[stations.items.len - 1] > 1e-9) {
            try stations.append(memory, y);
        } else for (sorted) |section| if (@abs(y - section.y) < 1e-12) {
            stations.items[stations.items.len - 1] = y; // as seções originais ficam exatas
            break;
        };
    }
    const ys = try memory.alloc(f64, sorted.len);
    for (sorted, ys) |section, *y| y.* = section.y;
    const column = struct {
        fn of(scratch: std.mem.Allocator, all: []const model.Section, comptime field: []const u8) ![]f64 {
            const out = try scratch.alloc(f64, all.len);
            for (all, out) |section, *value| value.* = @field(section, field);
            return out;
        }
    };
    const chords = try column.of(memory, sorted, "chord");
    const offsets = try column.of(memory, sorted, "x_offset");
    const twists = try column.of(memory, sorted, "twist");
    const sections = try memory.alloc(model.Section, stations.items.len);
    for (sections, stations.items) |*section, y| section.* = .{
        .y = y,
        .chord = core.constraints.interp(y, ys, chords),
        .x_offset = core.constraints.interp(y, ys, offsets),
        .twist = core.constraints.interp(y, ys, twists),
    };
    const surfaces = try memory.dupe(model.Surface, plane.surfaces);
    surfaces[index].sections = sections;
    var out = plane;
    out.surfaces = surfaces;
    return out;
}

/// o núcleo aceita este avião (cabe no limite de painéis)
pub fn fits(plane: *const simulation.Aircraft, params: *core.types.Params) bool {
    var diagnosis: model.Diag = .{};
    params_mod.fill(plane, params, &diagnosis) catch return false;
    return params.n_surf <= max_panels;
}

/// a maior divisão da superfície que cabe no limite de painéis do núcleo (busca binária, como `_fit` do Python)
pub fn fitted(memory: std.mem.Allocator, plane: simulation.Aircraft, index: usize, tip: bool, params: *core.types.Params) !simulation.Aircraft {
    var low: usize = 1;
    var high: usize = max_per_side;
    var best = plane;
    while (low <= high) {
        const middle = (low + high) / 2;
        const candidate = try refined(memory, plane, index, middle, tip);
        if (fits(&candidate, params)) {
            best = candidate;
            low = middle + 1;
        } else high = middle - 1;
    }
    return best;
}

/// os parâmetros do núcleo para o método (a linha sustentadora com as escolhas do Python: `GOATES_HUNSAKER`,
/// `NONLINEAR` de `span_loads.py`)
pub fn configure(run: *simulation.Run, instance: *core.runner.Instance, plane: *const simulation.Aircraft, method: LoadMethod) !void {
    var diagnosis: model.Diag = .{};
    params_mod.fill(plane, &instance.p, &diagnosis) catch |err| {
        run.fail("as asas não montaram no núcleo: {s} ({s})", .{ diagnosis.text(), @errorName(err) });
        return err;
    };
    switch (method) {
        .llt_gh => {
            instance.p.llt_method = .goates_hunsaker;
            instance.p.llt_joint = 0.15;
            instance.p.llt_blend = 1.0;
        },
        .llt_nl => {
            instance.p.llt_method = .nonlinear;
            instance.p.llt_viscosity = 2.0;
        },
        .llt => instance.p.llt_method = .phillips_snyder,
        else => {},
    }
    core.runner.configure(instance) catch |err| {
        run.fail("o núcleo recusou as asas ({s})", .{@errorName(err)});
        return err;
    };
}

/// a varredura de um método: uma chamada por superfície refinada sozinha, mais uma do avião sem refino para o que
/// sobrou (`CoreLoadMethod.sweep` do Python); devolve também o c_l de cada painel no α da carga
fn sweepMethod(run: *simulation.Run, state: *RunState, plane: simulation.Aircraft, owner_of_surface: []const i32, method: LoadMethod) !MethodRun {
    const memory = run.memory();
    const owner_count = state.owners.len;
    const alpha_count = state.alphas.len;
    const lifting_line = method != .faixas;
    const radians = try memory.alloc(f64, alpha_count);
    for (radians, state.alphas) |*angle, alpha| angle.* = alpha * rad;
    const lift = try memory.alloc(f64, alpha_count * owner_count);
    @memset(lift, 0);
    const done = try memory.alloc(bool, owner_count);
    @memset(done, false);
    var section_cl: std.ArrayList([]f64) = .empty; // por job: α × painel com dono
    var panel_owner: std.ArrayList(i32) = .empty;
    var panel_span: std.ArrayList(f64) = .empty;
    var load_cl: std.ArrayList(f64) = .empty;
    var load_chord: std.ArrayList(f64) = .empty;
    const instance = try memory.create(core.runner.Instance);
    var jobs: std.ArrayList(?usize) = .empty;
    for (plane.surfaces, 0..) |surface, i| if (surface.enabled) try jobs.append(memory, i);
    try jobs.append(memory, null);
    for (jobs.items) |job| {
        instance.* = .{};
        const job_plane = if (job) |index| try fitted(memory, plane, index, lifting_line, &instance.p) else plane;
        instance.* = .{};
        try configure(run, instance, &job_plane, method);
        const params = &instance.p;
        const panel_count: usize = @intCast(params.n_surf);
        var owners: [max_panels]i32 = undefined;
        var any = false;
        for (params.surf[0..panel_count], owners[0..panel_count]) |panel, *owner| {
            owner.* = -1;
            if (panel.owner < 0 or panel.vertical != 0) continue;
            const index: usize = @intCast(panel.owner);
            if (index >= owner_of_surface.len or owner_of_surface[index] < 0) continue;
            const candidate = owner_of_surface[index];
            if (done[@intCast(candidate)] or (job != null and job.? != index)) continue;
            owner.* = candidate;
            any = true;
        }
        if (!any) continue;
        const job_lift = try memory.alloc(f64, alpha_count * owner_count);
        const area = try memory.alloc(f64, owner_count);
        const chord = try memory.alloc(f64, owner_count);
        const cl = try memory.alloc(f64, alpha_count * panel_count);
        const span = try memory.alloc(f64, panel_count);
        const kind: sweep.Method = if (lifting_line) .lifting_line else .strips;
        sweep.sweep(params, state.airspeed, radians, owners[0..panel_count], owner_count, kind, .{ .owner_lift = job_lift, .owner_area = area, .owner_chord = chord, .section_cl = cl, .panel_span = span }) catch {
            run.fail("a varredura do núcleo recusou as asas", .{});
            return error.Failed;
        };
        // a carga no α da carga, painel a painel
        const at_load = [_]f64{state.alpha_load * rad};
        const load_lift = try memory.alloc(f64, owner_count);
        const load_cls = try memory.alloc(f64, panel_count);
        sweep.sweep(params, state.airspeed, &at_load, owners[0..panel_count], owner_count, kind, .{ .owner_lift = load_lift, .owner_area = try memory.alloc(f64, owner_count), .owner_chord = try memory.alloc(f64, owner_count), .section_cl = load_cls, .panel_span = try memory.alloc(f64, panel_count) }) catch {
            run.fail("a varredura do núcleo recusou as asas", .{});
            return error.Failed;
        };
        var columns: std.ArrayList(usize) = .empty;
        for (owners[0..panel_count], 0..) |owner, i| if (owner >= 0) try columns.append(memory, i);
        for (0..owner_count) |o| {
            const tag: i32 = @intCast(o);
            const active = for (owners[0..panel_count]) |owner| {
                if (owner == tag) break true;
            } else false;
            if (!active) continue;
            for (0..alpha_count) |a| lift[a * owner_count + o] = job_lift[a * owner_count + o];
            state.owner_area[o] = area[o];
            state.owner_chord[o] = chord[o];
            done[o] = true;
        }
        const block = try memory.alloc(f64, alpha_count * columns.items.len);
        for (0..alpha_count) |a| for (columns.items, 0..) |panel, j| {
            block[a * columns.items.len + j] = cl[a * panel_count + panel];
        };
        try section_cl.append(memory, block);
        for (columns.items) |panel| {
            try panel_owner.append(memory, owners[panel]);
            try panel_span.append(memory, span[panel]);
            try load_cl.append(memory, load_cls[panel]);
            try load_chord.append(memory, params.surf[panel].c);
        }
    }
    // os painéis de todos os jobs lado a lado (`np.hstack`)
    const panel_total = panel_owner.items.len;
    const all_cl = try memory.alloc(f64, alpha_count * panel_total);
    var offset: usize = 0;
    for (section_cl.items) |block| {
        const width = block.len / @max(alpha_count, 1);
        for (0..alpha_count) |a| @memcpy(all_cl[a * panel_total + offset ..][0..width], block[a * width ..][0..width]);
        offset += width;
    }
    const total_cl = try memory.alloc(f64, alpha_count);
    const owner_cl = try memory.alloc(f64, alpha_count * owner_count);
    const dynamic_pressure = 0.5 * state.density * state.airspeed * state.airspeed;
    const summary = sweep.summarize(lift, state.owner_area, dynamic_pressure, all_cl, panel_owner.items, panel_span.items, total_cl, owner_cl) catch {
        run.fail("o resumo da varredura não saiu", .{});
        return error.Failed;
    };
    return .{ .method = method, .total_cl = total_cl, .owner_cl = owner_cl, .summary = summary, .panel_owner = panel_owner.items, .load_owner = panel_owner.items, .load_span = panel_span.items, .load_cl = load_cl.items, .load_chord = load_chord.items };
}

fn startRun(run: *simulation.Run, state: *RunState, values: simulation.Values) simulation.Error!void {
    const memory = run.memory();
    const source_plane = try sourceAircraft(memory, run.aircraft, values.text("source", open_prefix), values);
    const plane = try wingsOnly(memory, &source_plane, values);
    state.airspeed = values.number("V", 12);
    state.density = plane.environment.rho;
    state.density_altitude = plane.environment.densityAltitude();
    state.alpha_load = values.number("alpha_load", 10);
    const first = values.number("a0", -4);
    const last = values.number("a1", 22);
    const step = @max(values.number("da", 1), 0.05);
    const count: usize = @intFromFloat(@floor((last - first + 1e-9) / step) + 1);
    state.alphas = try memory.alloc(f64, count);
    for (state.alphas, 0..) |*alpha, k| alpha.* = first + step * @as(f64, @floatFromInt(k));

    // os donos: as superfícies horizontais escolhidas, na ordem do avião
    const owner_of_surface = try memory.alloc(i32, plane.surfaces.len);
    var owners: std.ArrayList([]const u8) = .empty;
    for (plane.surfaces, owner_of_surface) |surface, *owner| {
        owner.* = -1;
        if (!surface.enabled or surface.vertical) continue;
        owner.* = @intCast(owners.items.len);
        try owners.append(memory, surface.name);
    }
    if (owners.items.len == 0) {
        state.failure = "nenhuma superfície marcada";
        run.progress = 1;
        return;
    }
    state.owners = owners.items;
    state.owner_area = try memory.alloc(f64, owners.items.len);
    state.owner_chord = try memory.alloc(f64, owners.items.len);

    const main = LoadMethod.fromTitle(values.text("method", LoadMethod.llt_nl.title())) orelse .llt_nl;
    const other = LoadMethod.fromTitle(values.text("compare", none));
    var runs: std.ArrayList(MethodRun) = .empty;
    try runs.append(memory, try sweepMethod(run, state, plane, owner_of_surface, main));
    run.progress = 0.5;
    if (other) |method| if (method != main) try runs.append(memory, try sweepMethod(run, state, plane, owner_of_surface, method));
    state.runs = runs.items;
    run.progress = 0.6;

    // a comparação dos métodos de polar do núcleo nas superfícies escolhidas e o avião completo
    state.figures = try simulation.Figures.init(memory, if (groundMethod(values) == .off) &plots else &(plots ++ ground_plots));
    var chosen: std.ArrayList(aerodynamics.Solver) = .empty;
    for (solvers) |solver| if (solver.core) |core_solver| {
        if (values.toggle(try std.fmt.allocPrint(memory, "use_{s}", .{solver.key}), solver.on)) try chosen.append(memory, core_solver);
    };
    try compareSolvers(run, state, plane, values, chosen.items);
    if (values.toggle("stall_on", false)) try stallByStation(run, state, plane, values);
    if (groundMethod(values) != .off) try groundStudy(run, state, plane, values);
    run.progress = 0.75;
    if (!fromSprint(values) and values.toggle("whole", aerodynamics.ready(run.aircraft))) {
        try aerodynamics.analyze(run, values, chosen.items, .{ .summary = &state.summary, .checks = &state.checks, .figures = state.figures.? });
    }
    run.progress = 1;
}

/// as polares dos métodos do núcleo só nas superfícies escolhidas, na referência da soma das áreas (`compare_solvers`
/// na parte de `wings.py` que escala as polares pela área da asa principal sobre a soma)
fn compareSolvers(run: *simulation.Run, state: *RunState, plane: simulation.Aircraft, values: simulation.Values, chosen: []const aerodynamics.Solver) !void {
    if (chosen.len == 0) return;
    const memory = run.memory();
    if (params_mod.firstSurface(&plane, "wing") == null) {
        try state.checks.append(memory, .{ .status = .info, .item = "comparação dos métodos", .value = "sem asa principal", .why = "os métodos tomam a referência (S, c, b) da asa principal: marque uma superfície do tipo asa", .group = "métodos" });
        return;
    }
    const geometry = aerodynamics.reference(&plane);
    const reference_x = geometry.mac_le - values.number("xref", 25) / 100 * geometry.chord;
    const case: aerodynamics.Case = .{ .airspeed = state.airspeed, .alphas = state.alphas, .alpha_derivatives = state.alpha_load, .reference = .{ reference_x, 0, 0 }, .per_side = @intFromFloat(@max(values.number("n_span", 12), 1)) };
    var total_area: f64 = 0;
    for (state.owner_area) |area| total_area += area;
    const scale = if (total_area > 0) geometry.area / total_area else 1;
    try state.summary.append(memory, .{ "métricas dos métodos ([...] C_L0, C_Lmax...): na área da asa principal (m²)", try text(memory, "{d:.4}", .{geometry.area}) });
    const figures = state.figures.?;
    for (chosen, 0..) |solver, k| {
        const polar = aerodynamics.solve(run, plane, solver, case) catch |err| {
            try state.checks.append(memory, .{ .status = .atencao, .item = try text(memory, "{s} falhou", .{solver.label()}), .value = @errorName(err), .group = "métodos" });
            continue;
        };
        const found = try aerodynamics.metrics(memory, polar, geometry, reference_x);
        const label = solver.label();
        if (found.lift_max) |value| try state.summary.append(memory, .{ try text(memory, "[{s}] C_Lmax, α dele (°)", .{label}), try text(memory, "{d:.4}, {d}", .{ value, found.alpha_stall.? }) });
        if (found.lift_slope) |value| try state.summary.append(memory, .{ try text(memory, "[{s}] C_Lα (1/rad)", .{label}), try text(memory, "{d:.4}", .{value}) });
        for ([_][]f64{ polar.lift, polar.drag, polar.induced, polar.moment }) |column| for (column) |*value| {
            value.* *= scale;
        };
        const efficiency = try polar.efficiency(memory);
        const color = colors[(k + 1) % colors.len];
        try figures.curve("pol_CL", .{ .name = label, .x = state.alphas, .y = polar.lift, .color = color });
        try figures.curve("pol_CD", .{ .name = label, .x = polar.drag, .y = polar.lift, .color = color });
        try figures.curve("pol_Cm", .{ .name = label, .x = state.alphas, .y = polar.moment, .color = color });
        try figures.curve("pol_LD", .{ .name = label, .x = polar.lift, .y = efficiency, .color = color });
        try figures.curve("CL", .{ .name = label, .x = state.alphas, .y = polar.lift, .color = color, .dashed = true });
        if (state.owners.len == 1) try figures.curve("CL_surf", .{ .name = try text(memory, "{s} · {s}", .{ state.owners[0], label }), .x = state.alphas, .y = polar.lift, .color = color, .dashed = true });
    }
}

fn advanceRun(_: *simulation.Run, _: *RunState) simulation.Error!bool {
    return true; // a varredura sai inteira no começo (frações de segundo)
}

fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn writeResult(run: *simulation.Run, state: *RunState, out: *simulation.Writer) simulation.Error!void {
    const memory = run.memory();
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    const group = "asas";
    const figures = state.figures orelse try simulation.Figures.init(memory, &plots);
    if (state.failure.len > 0) {
        try checks.append(memory, .{ .status = .falha, .item = "superfícies", .value = state.failure, .fix = "marque ao menos uma superfície", .group = group });
    }
    const dynamic_pressure = 0.5 * state.density * state.airspeed * state.airspeed;
    const owner_count = state.owners.len;
    for (state.runs, 0..) |method_run, m| {
        const title = method_run.method.title();
        const color = colors[m % colors.len];
        try figures.curve("CL", .{ .name = title, .x = state.alphas, .y = method_run.total_cl, .color = color, .width = 2 });
        for (state.owners, 0..) |owner, k| {
            if (!(state.owner_area[k] > 0)) continue;
            const column = try memory.alloc(f64, state.alphas.len);
            for (column, 0..) |*value, a| value.* = method_run.owner_cl[a * owner_count + k];
            try figures.curve("CL_surf", .{ .name = try text(memory, "{s} · {s}", .{ owner, title }), .x = state.alphas, .y = column, .color = surface_colors[(k + m * owner_count) % surface_colors.len], .dashed = m > 0 });
        }
        const facts = method_run.summary;
        const prefix = try text(memory, "[{s}] ", .{title});
        try summary.append(memory, .{ try text(memory, "{s}C_L máximo, α dele (°)", .{prefix}), try text(memory, "{d:.4}, {d}", .{ facts.lift_max, state.alphas[facts.peak] }) });
        if (facts.peak == state.alphas.len - 1) {
            try checks.append(memory, .{ .status = .info, .item = try text(memory, "C_L máximo {s}", .{title}), .value = try text(memory, "no fim da varredura ({d}°)", .{state.alphas[state.alphas.len - 1]}), .why = "o C_L ainda sobe no último α (o método não tem estol, ou falta varrer mais)", .fix = "aumente o α final ou use a linha sustentadora não linear", .group = group });
        } else if (facts.onset_panel) |panel| {
            const fraction = facts.onset_fraction;
            const part: []const u8 = if (fraction < 1.0 / 3.0) "raiz" else if (fraction < 2.0 / 3.0) "meio" else "ponta";
            const where = try text(memory, "{s}: {s} (y/b/2 = {d:.2})", .{ state.owners[@intCast(method_run.panel_owner[panel])], part, fraction });
            try summary.append(memory, .{ try text(memory, "{s}onde o estol começa", .{prefix}), where });
            const tip = std.mem.eql(u8, part, "ponta");
            try checks.append(memory, .{ .status = if (tip) .atencao else .ok, .item = try text(memory, "início do estol {s}", .{title}), .value = where, .criterion = "da raiz para fora", .why = if (tip) "o estol na ponta tira o aileron e derruba a asa" else "", .fix = if (tip) "torção negativa na ponta, menos afilamento ou um perfil de c_l,max maior na ponta" else "", .group = group });
        }
        // a carga ao longo da envergadura no α da carga, por superfície, em ordem de y
        for (state.owners, 0..) |owner, k| {
            var order: std.ArrayList(usize) = .empty;
            for (method_run.load_owner, 0..) |panel_owner, i| if (panel_owner == @as(i32, @intCast(k))) try order.append(memory, i);
            if (order.items.len == 0) continue;
            std.mem.sort(usize, order.items, method_run.load_span, struct {
                fn less(span: []const f64, a: usize, b: usize) bool {
                    return span[a] < span[b];
                }
            }.less);
            const ys = try memory.alloc(f64, order.items.len);
            const cls = try memory.alloc(f64, order.items.len);
            const lifts = try memory.alloc(f64, order.items.len);
            for (order.items, ys, cls, lifts) |i, *y, *cl, *lift| {
                y.* = method_run.load_span[i];
                cl.* = method_run.load_cl[i];
                lift.* = dynamic_pressure * method_run.load_chord[i] * method_run.load_cl[i];
            }
            const name = try text(memory, "{s} · {s}", .{ owner, title });
            try figures.curve("cl_span", .{ .name = name, .x = ys, .y = cls, .color = surface_colors[(k + m * owner_count) % surface_colors.len], .dashed = m > 0 });
            try figures.curve("L_span", .{ .name = name, .x = ys, .y = lifts, .color = surface_colors[(k + m * owner_count) % surface_colors.len], .dashed = m > 0 });
        }
    }
    if (state.runs.len > 0) {
        var total_area: f64 = 0;
        for (state.owners, 0..) |owner, k| {
            total_area += state.owner_area[k];
            const reynolds = sweep.reynolds(state.density, state.airspeed, state.owner_chord[k], state.density_altitude);
            try summary.append(memory, .{ try text(memory, "{s}: Reynolds (corda média) a {d} m/s", .{ owner, state.airspeed }), try text(memory, "{d:.0}", .{reynolds}) });
            if (reynolds < critical_reynolds) try checks.append(memory, .{ .status = .atencao, .item = try text(memory, "Reynolds {s}", .{owner}), .value = try text(memory, "{d:.3}", .{reynolds}), .criterion = "≥ 7e+04", .why = "abaixo do Reynolds crítico dos perfis de aeromodelo a bolha laminar pode não recolar: o perfil perde sustentação, e a polar do perfil não mostra isso", .fix = "confira a polar do perfil nesse Reynolds", .group = group });
        }
        try summary.append(memory, .{ "área de referência (soma das horizontais, m²)", try text(memory, "{d:.4}", .{total_area}) });
    }
    try summary.append(memory, .{ "métodos de carga", "núcleo (core/src/loads/sweep.zig)" });
    try summary.appendSlice(memory, state.summary.items);
    try checks.appendSlice(memory, state.checks.items);
    try simulation.beginResult(out, summary.items, checks.items);
    try figures.write(out, true);
    try simulation.endResult(out);
}


// ------------------------------------------------------------------ estol por estação (VLM + polar)

/// o nome do método na tela, com o tipo dele em palavras simples
const stall_title = "VLM + polar (estol por estação: corrige o ângulo de cada faixa até o c_l bater com a polar 2D no Re dela)";
const stall_group = "VLM + polar (corrige o α de cada faixa pela polar 2D)";

/// os campos do método: ligar e, ligado, a malha e os ajustes do Newton (nada fica escondido)
fn appendStallFields(memory: std.mem.Allocator, params: *std.ArrayList(simulation.Param), values: simulation.Values) !void {
    const on = values.toggle("stall_on", false);
    try params.append(memory, .{ .key = "stall_on", .label = "ligar o estol por estação", .kind = .bool, .default = .{ .toggle = false }, .group = stall_group, .rebuild = true, .help = stall_title ++ ". O VLM (malha de vórtices) com a polar 2D de cada faixa: dá o C_L máximo das superfícies marcadas a partir das polares e onde o estol começa. Usa os α do Caso" });
    if (!on) return;
    try params.appendSlice(memory, &.{
        .{ .key = "stall_chord", .label = "painéis na corda", .kind = .int, .default = .{ .number = 4 }, .minimum = 1, .maximum = 12, .group = stall_group, .help = "painéis do VLM ao longo da corda de cada faixa" },
        .{ .key = "stall_span", .label = "divisões por faixa", .kind = .int, .default = .{ .number = 8 }, .minimum = 1, .maximum = 20, .group = stall_group, .help = "cada faixa do avião vira esta quantidade de estações" },
        .{ .key = "stall_iterations", .label = "iterações (Newton)", .kind = .int, .default = .{ .number = 40 }, .minimum = 1, .maximum = 500, .group = stall_group, .help = "iterações máximas do Newton (método que zera a diferença entre o c_l da polar e o do VLM) em cada α" },
        .{ .key = "stall_tolerance", .label = "tolerância no c_l", .default = .{ .number = 1e-7 }, .minimum = 1e-12, .maximum = 1e-2, .group = stall_group, .help = "o Newton para quando a maior |c_l da polar − c_l do VLM| fica abaixo disto" },
        .{ .key = "stall_halvings", .label = "cortes do passo", .kind = .int, .default = .{ .number = 8 }, .minimum = 0, .maximum = 30, .group = stall_group, .help = "busca linear: o passo do Newton é cortado pela metade até o erro cair, no máximo isto de vezes" },
        .{ .key = "stall_polar_from", .label = "polar: α inicial", .default = .{ .number = -20 }, .minimum = -40, .maximum = 0, .unit = "°", .group = stall_group, .help = "a polar 2D do modelo do perfil vai deste α ..." },
        .{ .key = "stall_polar_to", .label = "polar: α final", .default = .{ .number = 30 }, .minimum = 5, .maximum = 60, .unit = "°", .group = stall_group, .help = "... até este; depois do último ponto, o c_l sai de Viterna e Corrigan (fórmula empírica do pós-estol)" },
        .{ .key = "stall_polar_step", .label = "polar: passo", .default = .{ .number = 0.5 }, .minimum = 0.05, .maximum = 2, .unit = "°", .group = stall_group },
    });
}

/// o estol por estação nas superfícies marcadas: uma família de polares por superfície (a polar do modelo do perfil
/// dela), a varredura nos α do Caso com continuação e a carga no α da carga
fn stallByStation(run: *simulation.Run, state: *RunState, plane: simulation.Aircraft, values: simulation.Values) !void {
    const memory = run.memory();
    const figures = state.figures.?;
    const group = "estol por estação";
    const params = try memory.create(core.types.Params);
    params.* = .{};
    var diagnosis: model.Diag = .{};
    params_mod.fill(&plane, params, &diagnosis) catch {
        try state.checks.append(memory, .{ .status = .falha, .item = "estol por estação", .value = "as asas não montaram", .why = diagnosis.text(), .group = group });
        return;
    };
    core.aero.init(params);
    const grid: core.vlm.Grid = .{ .chordwise = @intFromFloat(@max(values.number("stall_chord", 4), 1)), .spanwise = @intFromFloat(@max(values.number("stall_span", 8), 1)) };
    const panel_count = core.vlm.panelCount(params, grid);
    if (panel_count == 0) {
        try state.checks.append(memory, .{ .status = .falha, .item = "estol por estação", .value = "sem painéis", .group = group });
        return;
    }
    const station_count = core.stall.stationCount(params, grid);
    // uma família por superfície do avião: a polar do modelo do perfil dela
    const polar_from = values.number("stall_polar_from", -20);
    const polar_to = values.number("stall_polar_to", 30);
    const polar_step = @max(values.number("stall_polar_step", 0.5), 0.05);
    const polar_points: usize = @min(@as(usize, @intFromFloat(@floor((polar_to - polar_from) / polar_step))) + 1, core.section.max_points);
    const polar_alphas = try memory.alloc(f64, polar_points);
    for (polar_alphas, 0..) |*alpha, k| alpha.* = polar_from + polar_step * @as(f64, @floatFromInt(k));
    const strip_count: usize = @intCast(params.n_surf);
    const families = try memory.alloc(core.stall.Family, @max(plane.surfaces.len, 1));
    for (families, 0..) |*family, i| {
        const airfoil = if (i < plane.surfaces.len) plane.surfaces[i].airfoil else model.Airfoil{};
        // o α de sustentação nula é o mesmo que o VLM usa na faixa (−C_L0/C_Lα da superfície): o método só fecha
        // se a polar e a malha concordam nele
        var zero_lift: f64 = 0;
        for (params.surf[0..strip_count]) |strip| if (strip.owner == @as(i32, @intCast(i)) and strip.CLa != 0) {
            zero_lift = -strip.CL0 / strip.CLa / rad;
            break;
        };
        const polar = try memory.create(core.section.Polar);
        polar.* = .{};
        core.section.modelPolar(.{ .cl_alpha = airfoil.cl_alpha, .alpha0 = zero_lift, .cl_max = airfoil.cl_max, .cd0 = airfoil.cd0, .cm_ac = airfoil.cm_ac orelse 0 }, polar_alphas, polar);
        family.* = .{ .reynolds = try memory.dupe(f64, &.{0}), .polars = polar[0..1] };
    }
    const of_strip = try memory.alloc(usize, strip_count);
    for (params.surf[0..strip_count], of_strip) |strip, *family| family.* = if (strip.owner >= 0 and @as(usize, @intCast(strip.owner)) < families.len) @intCast(strip.owner) else 0;
    const sections: core.stall.Sections = .{ .families = families, .of_strip = of_strip, .settings = .{
        .max_iterations = @intFromFloat(@max(values.number("stall_iterations", 40), 1)),
        .tolerance = values.number("stall_tolerance", 1e-7),
        .max_halvings = @intFromFloat(@max(values.number("stall_halvings", 8), 0)),
    } };
    const buffers: core.vlm.Buffers = .{ .panels = try memory.alloc(core.vlm.Panel, panel_count), .matrix = try memory.alloc(f64, panel_count * panel_count), .pivots = try memory.alloc(usize, panel_count), .gamma = try memory.alloc(f64, panel_count) };
    const work: core.stall.Work = .{
        .delta = try memory.alloc(f64, station_count),
        .residual = try memory.alloc(f64, station_count),
        .trial = try memory.alloc(f64, station_count),
        .jacobian = try memory.alloc(f64, station_count * station_count),
        .pivots = try memory.alloc(usize, station_count),
        .scratch = try memory.alloc(f64, panel_count),
        .stations = try memory.alloc(core.stall.Station, station_count),
    };
    @memset(work.delta, 0);
    const lift = try memory.alloc(f64, state.alphas.len);
    var lift_max = -std.math.inf(f64);
    var alpha_max: f64 = 0;
    var onset: ?struct { alpha: f64, position: f64 } = null;
    var failed: usize = 0;
    var beyond = false;
    for (state.alphas, lift) |alpha, *out| {
        const found = core.stall.next(params, grid, sections, alpha * rad, state.airspeed, state.density, .{ 0, 0, 0 }, buffers, work) catch |err| {
            try state.checks.append(memory, .{ .status = .falha, .item = "estol por estação", .value = try text(memory, "parou em α = {d}° ({s})", .{ alpha, @errorName(err) }), .group = group });
            out.* = std.math.nan(f64);
            continue;
        };
        out.* = found.coefficients.CL;
        if (!found.converged) failed += 1;
        if (found.coefficients.CL > lift_max) {
            lift_max = found.coefficients.CL;
            alpha_max = alpha;
        }
        for (work.stations[0..station_count]) |station| {
            if (station.beyond_polar) beyond = true;
            if (onset == null and station.stalled) onset = .{ .alpha = alpha, .position = station.span_position };
        }
    }
    try figures.curve("CL", .{ .name = "VLM + polar", .x = state.alphas, .y = lift, .color = "#6b46c1", .width = 2 });
    try state.summary.append(memory, .{ "[VLM + polar] C_L máximo, α dele (°)", try text(memory, "{d:.4}, {d}", .{ lift_max, alpha_max }) });
    try state.summary.append(memory, .{ "[VLM + polar] estações; painéis", try text(memory, "{d}; {d}", .{ station_count, panel_count }) });
    if (onset) |first| {
        const part: []const u8 = if (first.position < 1.0 / 3.0) "raiz" else if (first.position < 2.0 / 3.0) "meio" else "ponta";
        try state.summary.append(memory, .{ "[VLM + polar] o estol começa em", try text(memory, "α = {d}°, {s} (y/b/2 = {d:.2})", .{ first.alpha, part, first.position }) });
        try state.checks.append(memory, .{ .status = if (std.mem.eql(u8, part, "ponta")) .atencao else .ok, .item = "início do estol (VLM + polar)", .value = try text(memory, "{s} (y/b/2 = {d:.2})", .{ part, first.position }), .criterion = "da raiz para fora", .group = group });
    } else try state.checks.append(memory, .{ .status = .info, .item = "início do estol (VLM + polar)", .value = "nenhuma estação estolou", .fix = "aumente o α final do Caso", .group = group });
    if (failed > 0) try state.checks.append(memory, .{ .status = .atencao, .item = "Newton do estol por estação", .value = try text(memory, "{d} de {d} α sem convergir", .{ failed, state.alphas.len }), .criterion = "todos", .fix = "aumente as iterações ou a tolerância", .group = group });
    if (beyond) try state.checks.append(memory, .{ .status = .atencao, .item = "polar curta (estol por estação)", .value = "alguma estação passou do último ponto de uma polar que ainda não estolou", .fix = "aumente o α final da polar", .group = group });
    try state.checks.append(memory, .{ .status = .info, .item = "polar das faixas (estol por estação)", .value = "a polar do modelo do perfil (um Reynolds só)", .why = "o modelo do perfil não muda com o Reynolds", .group = group });
    // o c_l ao longo da envergadura no α da carga, e as estações estoladas
    @memset(work.delta, 0);
    _ = core.stall.point(params, grid, sections, state.alpha_load * rad, state.airspeed, state.density, .{ 0, 0, 0 }, buffers, work) catch return;
    const ys = try memory.alloc(f64, station_count);
    const cls = try memory.alloc(f64, station_count);
    var stalled_y: std.ArrayList(f64) = .empty;
    var stalled_cl: std.ArrayList(f64) = .empty;
    for (work.stations[0..station_count], ys, cls, 0..) |station, *y, *cl, j| {
        y.* = buffers.panels[j * grid.chordwise].control[1];
        cl.* = station.cl;
        if (station.stalled) {
            try stalled_y.append(memory, y.*);
            try stalled_cl.append(memory, station.cl);
        }
    }
    try figures.curve("cl_span", .{ .name = "VLM + polar", .x = ys, .y = cls, .color = "#6b46c1", .marker = "o", .size = 3 });
    if (stalled_y.items.len > 0) try figures.curve("cl_span", .{ .name = "estação estolada", .x = stalled_y.items, .y = stalled_cl.items, .color = "#c53030", .marker = "x", .size = 6 });
}

// ------------------------------------------------------------------ efeito do chão (análise)

const ground_group = "Efeito do chão";
/// os métodos do chão, com o tipo de cada um em palavras simples
const ground_methods = [_][]const u8{
    none,
    "McCormick (fórmula)",
    "VLM com imagem",
};
const GroundMethod = enum { off, mccormick, vlm_image };

fn groundMethod(values: simulation.Values) GroundMethod {
    const chosen = values.text("ground_method", none);
    for (ground_methods, 0..) |title, i| if (std.mem.eql(u8, title, chosen)) return @enumFromInt(i);
    return .off;
}

const ground_plots = [_]simulation.Plot{
    .{ .key = "ground_CL", .title = "Chão: ΔC_L × h/b", .xlabel = "h/b (altura da origem / envergadura)", .ylabel = "ΔC_L" },
    .{ .key = "ground_CDi", .title = "Chão: induzido × h/b", .xlabel = "h/b (altura da origem / envergadura)", .ylabel = "C_Di no chão / C_Di longe dele (mesmo C_L)" },
    .{ .key = "ground_Cm", .title = "Chão: ΔC_m × h/b", .xlabel = "h/b (altura da origem / envergadura)", .ylabel = "ΔC_m" },
};

/// os campos do efeito do chão: o método e, escolhido, as alturas, os α e a malha
fn appendGroundFields(memory: std.mem.Allocator, params: *std.ArrayList(simulation.Param), values: simulation.Values) !void {
    try params.append(memory, .{ .key = "ground_method", .label = "método", .kind = .choice, .default = .{ .text = none }, .choices = &ground_methods, .group = ground_group, .rebuild = true, .help = "o que o chão muda nas superfícies marcadas, de perto até longe dele. McCormick (fórmula empírica): só reduz o arrasto induzido. VLM com imagem (malha de vórtices espelhada no chão): muda a sustentação, o induzido e o momento" });
    const method = groundMethod(values);
    if (method == .off) return;
    try params.append(memory, .{ .key = "ground_heights", .label = "alturas (h/b)", .kind = .floats, .default = .{ .text = "0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.8, 1.2, 2" }, .group = ground_group, .help = "a altura da origem do avião sobre o chão, em envergaduras" });
    if (method != .vlm_image) return;
    try params.appendSlice(memory, &.{
        .{ .key = "ground_alphas", .label = "α", .kind = .floats, .default = .{ .text = "0, 4, 8, 12" }, .unit = "°", .group = ground_group, .help = "uma curva por α; o fator do induzido usa o mesmo α" },
        .{ .key = "ground_chord", .label = "painéis na corda", .kind = .int, .default = .{ .number = 2 }, .minimum = 1, .maximum = 12, .group = ground_group },
        .{ .key = "ground_span", .label = "divisões por faixa", .kind = .int, .default = .{ .number = 1 }, .minimum = 1, .maximum = 20, .group = ground_group },
    });
}

/// o efeito do chão nas superfícies marcadas, pelo método escolhido, em cada altura e α
fn groundStudy(run: *simulation.Run, state: *RunState, plane: simulation.Aircraft, values: simulation.Values) !void {
    const memory = run.memory();
    const figures = state.figures.?;
    const group = "efeito do chão";
    const method = groundMethod(values);
    var height_buffer: [64]f64 = undefined;
    const ratios = values.numbers("ground_heights", &height_buffer, &.{ 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.8, 1.2, 2 });
    if (ratios.len == 0) return;
    const params = try memory.create(core.types.Params);
    params.* = .{};
    var diagnosis: model.Diag = .{};
    params_mod.fill(&plane, params, &diagnosis) catch {
        try state.checks.append(memory, .{ .status = .falha, .item = "efeito do chão", .value = "as asas não montaram", .why = diagnosis.text(), .group = group });
        return;
    };
    core.aero.init(params);
    const span = params.bref;
    const xs = try memory.dupe(f64, ratios);
    try state.summary.append(memory, .{ "[chão] envergadura de referência (m)", try text(memory, "{d:.3}", .{span}) });
    if (method == .mccormick) {
        const factor = try memory.alloc(f64, ratios.len);
        for (ratios, factor) |ratio, *value| value.* = core.modifiers.ground.mccormick(ratio * span, span);
        try figures.curve("ground_CDi", .{ .name = "McCormick", .x = xs, .y = factor, .color = "#c05621", .width = 2 });
        try state.checks.append(memory, .{ .status = .info, .item = "efeito do chão (McCormick)", .value = "só o induzido muda", .why = "a fórmula não mexe no C_L nem no C_m; perto do chão ela corta o induzido demais", .fix = "compare com o VLM com imagem", .group = group });
        return;
    }
    // VLM com imagem: as forças com o chão menos as longe dele, no mesmo α
    var alpha_buffer: [16]f64 = undefined;
    const alphas = values.numbers("ground_alphas", &alpha_buffer, &.{ 0, 4, 8, 12 });
    const grid: core.vlm.Grid = .{ .chordwise = @intFromFloat(@max(values.number("ground_chord", 2), 1)), .spanwise = @intFromFloat(@max(values.number("ground_span", 1), 1)) };
    const panel_count = core.vlm.panelCount(params, grid);
    if (panel_count == 0) return;
    const buffers: core.vlm.Buffers = .{ .panels = try memory.alloc(core.vlm.Panel, panel_count), .matrix = try memory.alloc(f64, panel_count * panel_count), .pivots = try memory.alloc(usize, panel_count), .gamma = try memory.alloc(f64, panel_count) };
    try state.summary.append(memory, .{ "[chão] painéis do VLM", try text(memory, "{d}", .{panel_count}) });
    const origin: [3]f64 = .{ 0, 0, 0 };
    var touched = false;
    for (alphas, 0..) |alpha, k| {
        const free = core.vlm.groundCoefficients(params, grid, alpha * rad, std.math.inf(f64), origin, buffers) catch |err| {
            try state.checks.append(memory, .{ .status = .falha, .item = "efeito do chão", .value = try text(memory, "o VLM recusou a malha ({s})", .{@errorName(err)}), .group = group });
            return;
        };
        const lift = try memory.alloc(f64, ratios.len);
        const induced = try memory.alloc(f64, ratios.len);
        const moment = try memory.alloc(f64, ratios.len);
        for (ratios, lift, induced, moment) |ratio, *dl, *factor, *dm| {
            const near = core.vlm.groundCoefficients(params, grid, alpha * rad, ratio * span, origin, buffers) catch |err| switch (err) {
                error.BelowGround => {
                    touched = true;
                    dl.* = std.math.nan(f64);
                    factor.* = std.math.nan(f64);
                    dm.* = std.math.nan(f64);
                    continue;
                },
                else => {
                    try state.checks.append(memory, .{ .status = .falha, .item = "efeito do chão", .value = try text(memory, "o VLM recusou a malha ({s})", .{@errorName(err)}), .group = group });
                    return;
                },
            };
            dl.* = near.CL - free.CL;
            dm.* = near.Cm - free.Cm;
            // o induzido no mesmo C_L: C_Di/C_L² perto sobre longe
            factor.* = if (near.CL != 0 and free.CL != 0 and free.CDi != 0) (near.CDi / (near.CL * near.CL)) / (free.CDi / (free.CL * free.CL)) else std.math.nan(f64);
        }
        const name = try text(memory, "α = {d}°", .{alpha});
        const color = surface_colors[k % surface_colors.len];
        try figures.curve("ground_CL", .{ .name = name, .x = xs, .y = lift, .color = color, .width = 2 });
        try figures.curve("ground_CDi", .{ .name = name, .x = xs, .y = induced, .color = color, .width = 2 });
        try figures.curve("ground_Cm", .{ .name = name, .x = xs, .y = moment, .color = color, .width = 2 });
    }
    // o McCormick junto, para comparar o induzido
    const factor = try memory.alloc(f64, ratios.len);
    for (ratios, factor) |ratio, *value| value.* = core.modifiers.ground.mccormick(ratio * span, span);
    try figures.curve("ground_CDi", .{ .name = "McCormick", .x = xs, .y = factor, .color = "#4a5568", .dashed = true });
    if (touched) try state.checks.append(memory, .{ .status = .info, .item = "efeito do chão", .value = "alguma superfície encosta no chão nas alturas mais baixas", .fix = "comece as alturas mais alto", .group = group });
}

const testing = std.testing;

test "Analisar: o C_L máximo da asa do Convencional bate com o Python" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Wings);
    try testing.expect(!needsPython(.{}));
    for (expected) |case| {
        var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
        defer run.arena.deinit();
        const request = try std.fmt.allocPrint(run.memory(), "\"values\": {{\"method\": \"{s}\"}}", .{case.method.title()});
        try registered.start(&run, simulation.Values.fromRequest(run.memory(), request));
        const state: *RunState = @ptrCast(@alignCast(run.state.?));
        try testing.expectApproxEqAbs(case.lift_max, state.runs[0].summary.lift_max, 1e-6);
        try testing.expectEqual(case.peak, state.runs[0].summary.peak);
        var written: std.Io.Writer.Allocating = .init(gpa);
        defer written.deinit();
        try registered.result(&run, &written.writer);
    }
}

// os números do Python (`wings.py`, Convencional_original, só a asa, campos padrão): C_L máximo e o índice do α dele
const expected = [_]struct { method: LoadMethod, lift_max: f64, peak: usize }{
    .{ .method = .faixas, .lift_max = 1.5989062801644256, .peak = 20 },
    .{ .method = .llt_nl, .lift_max = 1.6516222836382326, .peak = 20 },
};

test "Analisar: o estol por estação (VLM + polar) na asa do Convencional dá um C_L máximo abaixo do c_l,max do perfil" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "../data/aircraft/Convencional_original.json", gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    const registered = simulation.register(Wings);
    var run = simulation.Run{ .arena = .init(gpa), .aircraft = &loaded.ac };
    defer run.arena.deinit();
    try registered.start(&run, simulation.Values.fromRequest(run.memory(), "\"values\": {\"stall_on\": true}"));
    const state: *RunState = @ptrCast(@alignCast(run.state.?));
    var lift_max: ?f64 = null;
    for (state.summary.items) |row| {
        if (std.mem.eql(u8, row[0], "[VLM + polar] C_L máximo, α dele (°)")) {
            const cut = std.mem.indexOfScalar(u8, row[1], ',').?;
            lift_max = try std.fmt.parseFloat(f64, row[1][0..cut]);
        }
    }
    var cl_max: f64 = 0;
    for (loaded.ac.surfaces) |surface| if (std.mem.eql(u8, surface.role, "wing")) {
        cl_max = surface.airfoil.cl_max;
    };
    try testing.expect(lift_max.? > 0.5 and lift_max.? < cl_max);
}

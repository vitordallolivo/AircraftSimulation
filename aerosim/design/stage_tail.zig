//! A etapa "Empenagem e comandos" em Zig (`TailStage` de `stages.py`): as superfícies que acompanham a asa guardada
//! (cauda convencional, em V, em H ou sem cauda), o tubo, o profundor, o leme e o aileron por volume de cauda. A conta
//! é a do núcleo (`core.tail`): CG na margem pedida, faixa de CG, incidência da EH, rotação, rolagem e direcional.
//! As asas vêm da configuração escolhida (ou da tabela de Projetar como está); guarde conjuntos para a etapa Motores.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");
const airfoils = @import("stage_airfoils.zig");
const wing_stage = @import("stage_wing.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const wing_line = core.wing_line;
const tail = core.tail;
const model = aircraft_model.aircraft;

const live_layout = "a tabela de Projetar";
const layouts = [_][]const u8{ "convencional", "em V", "sem cauda", "em H" };
const arm_from = [_][]const u8{ "CA da asa", "CG de projeto" };
const tail_airfoils = [_][]const u8{ "NACA 0012", "NACA 0010", "NACA 0009", "NACA 0008" };
const control_kinds = [_][]const u8{ "aileron", "elevator", "rudder", "elevon", "ruddervator", "flaperon", "flap" };
const rule_keys = [_][]const u8{ "elevator", "rudder", "aileron_start", "aileron_end", "aileron_chord" };
const control_keys = [_][]const u8{ "surface", "kind", "span_start", "span_end", "chord_frac", "pitch", "roll", "yaw" };

/// os campos do rascunho (`TailParams`, sem os da segunda asa, que vêm da configuração)
const tail_fields = [_]registry.Field{
    .{ .key = "name", .label = "nome", .default = .{ .text = "conjunto 1" } },
    .{ .key = "config", .label = "configuração", .help = "as asas do avião e onde ficam: uma configuração guardada em Projetar, ou a tabela de lá como está agora (vazia: só a asa abaixo)", .default = .{ .text = live_layout } },
    .{ .key = "wing", .label = "asa", .help = "uma das asas guardadas na etapa Asa", .default = .{ .text = "asa 1" } },
    .{ .key = "layout", .label = "cauda", .help = "convencional: EH + EV; em V: duas superfícies inclinadas; sem cauda: elevons na asa; em H: EH com uma EV em cada ponta", .default = .{ .text = "convencional" }, .choices = &layouts },
    .{ .key = "arm", .label = "braço da cauda", .unit = "m", .help = "até o centro aerodinâmico da cauda, medido de onde diz 'braço medido do'", .default = .{ .number = 0.95 }, .minimum = 0.2, .maximum = 3.0 },
    .{ .key = "arm_from", .label = "braço medido do", .help = "CA da asa: do centro aerodinâmico da asa (clássico); CG de projeto: do CG (como l_h na planilha antiga) — os volumes de cauda usam este braço", .default = .{ .text = "CA da asa" }, .choices = &arm_from },
    .{ .key = "VH", .label = "volume de cauda horizontal V_H", .help = "0,35 a 0,6 é o usual", .default = .{ .number = 0.45 }, .minimum = 0.1, .maximum = 1.2 },
    .{ .key = "VV", .label = "volume de cauda vertical V_V", .help = "0,02 a 0,05 é o usual", .default = .{ .number = 0.04 }, .minimum = 0.005, .maximum = 0.15 },
    .{ .key = "AR_h", .label = "alongamento da EH", .default = .{ .number = 4.0 }, .minimum = 1, .maximum = 10 },
    .{ .key = "AR_v", .label = "alongamento da EV", .help = "altura² / área", .default = .{ .number = 1.6 }, .minimum = 0.5, .maximum = 5 },
    .{ .key = "taper_h", .label = "afilamento da EH", .default = .{ .number = 1.0 }, .minimum = 0.3, .maximum = 1 },
    .{ .key = "taper_v", .label = "afilamento da EV", .default = .{ .number = 0.7 }, .minimum = 0.3, .maximum = 1 },
    .{ .key = "tail_airfoil", .label = "perfil da EH", .help = "NACA de 4 dígitos ou um da etapa Perfil (arqueado também: a incidência compensa)", .default = .{ .text = "NACA 0012" } },
    .{ .key = "tail_inverted", .label = "EH invertida", .help = "perfil montado de cabeça para baixo: sustentação para baixo e c_l negativo maior — momento cabrador para rodar na decolagem", .default = .{ .toggle = false } },
    .{ .key = "vtail_airfoil", .label = "perfil da EV", .help = "simétrico (arqueado empurra para o lado sem derrapar)", .default = .{ .text = "NACA 0012" } },
    .{ .key = "elevator", .label = "profundor (fração da corda)", .default = .{ .number = 0.35 }, .minimum = 0.1, .maximum = 0.6 },
    .{ .key = "rudder", .label = "leme (fração da corda)", .default = .{ .number = 0.35 }, .minimum = 0.1, .maximum = 0.6 },
    .{ .key = "aileron_start", .label = "aileron: início", .help = "fração da semienvergadura", .default = .{ .number = 0.55 }, .minimum = 0, .maximum = 0.95 },
    .{ .key = "aileron_end", .label = "aileron: fim", .default = .{ .number = 0.95 }, .minimum = 0.1, .maximum = 1 },
    .{ .key = "aileron_chord", .label = "aileron (fração da corda)", .default = .{ .number = 0.25 }, .minimum = 0.1, .maximum = 0.5 },
    .{ .key = "flap_moment", .label = "momento próprio dos comandos", .help = "o comando também muda o momento no quarto de corda da faixa (perfil fino), no núcleo. Liga o modificador comando.momento_flape no avião", .default = .{ .toggle = false } },
    .{ .key = "tip_fin", .label = "deriva na ponta (altura)", .unit = "m", .help = "sem cauda: uma superfície vertical em cada ponta da asa, com leme (estabilidade direcional). 0 = nenhuma", .default = .{ .number = 0 }, .minimum = 0, .maximum = 0.5 },
    .{ .key = "tip_fin_chord", .label = "deriva na ponta: corda", .help = "fração da corda da ponta da asa", .default = .{ .number = 0.6 }, .minimum = 0.2, .maximum = 1.2 },
    .{ .key = "sm_target", .label = "margem estática desejada", .unit = "% CMA", .help = "põe o CG aqui (a etapa Motores arruma as massas)", .default = .{ .number = 12 }, .minimum = 2, .maximum = 40 },
    .{ .key = "sm_min", .label = "margem estática mínima", .unit = "% CMA", .help = "limite traseiro do CG", .default = .{ .number = 5 }, .minimum = 0, .maximum = 20 },
    .{ .key = "tail_eta", .label = "η da cauda", .help = "pressão dinâmica na cauda / a do voo livre", .default = .{ .number = 0.9 }, .minimum = 0.5, .maximum = 1 },
    .{ .key = "boom_diameter", .label = "diâmetro do tubo", .unit = "m", .default = .{ .number = 0.025 }, .minimum = 0.005, .maximum = 0.1 },
    .{ .key = "vlm", .label = "VLM e convergência", .help = "roda o VLM do núcleo no conjunto inteiro (todas as superfícies, com as de a mais) em malhas cada vez mais finas: C_Lα, C_mα, ponto neutro, derivadas laterais e o quanto mudam com a malha. Desligado por padrão (leva alguns segundos)", .default = .{ .toggle = false } },
    .{ .key = "boom_pitch", .label = "inclinação do tubo", .unit = "°", .help = "+ ponta de trás para cima: a cauda sobe (sai da esteira da asa); o braço continua medido na horizontal", .default = .{ .number = 0 }, .minimum = -10, .maximum = 20 },
};

const plots = [_]simulation.Plot{
    .{ .key = "cm", .title = "C_m,CG × α", .xlabel = "α_raiz (°)", .ylabel = "C_m" },
    .{ .key = "de", .title = "δe × V", .xlabel = "V (m/s)", .ylabel = "δe (°, − cabra)" },
    .{ .key = "cg", .title = "x_CG (% CMA)", .xlabel = "% CMA", .ylabel = "" },
};
const vlm_plots = [_]simulation.Plot{
    .{ .key = "vlm_slope", .title = "VLM: C_Lα e C_mα × painéis", .xlabel = "painéis", .ylabel = "1/rad" },
    .{ .key = "vlm_np", .title = "VLM: ponto neutro × painéis", .xlabel = "painéis", .ylabel = "% CMA" },
    .{ .key = "vlm_lateral", .title = "VLM: derivadas laterais × painéis", .xlabel = "painéis", .ylabel = "1/rad" },
};
/// as malhas da convergência (corda × envergadura em cada faixa), da mais grossa para a mais fina
/// (primeiro na corda, depois na envergadura, onde o VLM converge devagar, com o erro ∝ 1/n)
const vlm_grids = [_]core.vlm.Grid{ .{ .chordwise = 1, .spanwise = 1 }, .{ .chordwise = 2, .spanwise = 1 }, .{ .chordwise = 4, .spanwise = 1 }, .{ .chordwise = 4, .spanwise = 2 }, .{ .chordwise = 4, .spanwise = 3 }, .{ .chordwise = 4, .spanwise = 4 }, .{ .chordwise = 4, .spanwise = 6 } };
const vlm_max_panels = 1200;

/// o VLM do conjunto em cada malha de `vlm_grids` (as que cabem em `vlm_max_panels`), momentos no CG do alvo
fn vlmStudy(memory: std.mem.Allocator, built: Built) ![]const core.vlm.Derivatives {
    const plane: model.Aircraft = .{ .name = "conjunto", .surfaces = built.surfaces, .booms = built.booms };
    const params = try memory.create(core.types.Params);
    params.* = .{};
    var diagnosis: model.Diag = .{};
    try aircraft_model.params.fill(&plane, params, &diagnosis);
    core.aero.init(params);
    var largest: usize = 0;
    for (vlm_grids) |grid| {
        const count = core.vlm.panelCount(params, grid);
        if (count <= vlm_max_panels) largest = @max(largest, count);
    }
    if (largest == 0) return &.{};
    const buffers: core.vlm.Buffers = .{ .panels = try memory.alloc(core.vlm.Panel, largest), .matrix = try memory.alloc(f64, largest * largest), .pivots = try memory.alloc(usize, largest), .gamma = try memory.alloc(f64, largest) };
    var out: std.ArrayList(core.vlm.Derivatives) = .empty;
    for (vlm_grids) |grid| {
        if (core.vlm.panelCount(params, grid) > vlm_max_panels) continue;
        try out.append(memory, try core.vlm.derivatives(params, grid, 0, .{ -built.result.x_cg, 0, 0 }, buffers));
    }
    return out.items;
}

/// a posição (% CMA) de um x do corpo, pela CMA da conta clássica (x_cg e x_np dela, atrás do bordo da raiz)
fn percentOf(result: *const tail.Result, body_x: f64) f64 {
    const chord = if (result.h_n != result.h_cg) (result.x_np - result.x_cg) / (result.h_n - result.h_cg) else 1;
    return 100 * (result.h_cg + (-body_x - result.x_cg) / chord);
}

const place_colors = [3][]const u8{ "#2ca02c", "#000000", "#d62728" };
const place_names = [3][]const u8{ "CG à frente (limite)", "CG no alvo", "CG atrás (limite)" };

fn draft(project: *store.Project) *ObjectMap {
    return project.section("tail_draft");
}

fn field(params: *const ObjectMap, key: []const u8) f64 {
    return registry.fieldNumber(params, &tail_fields, key);
}

pub fn layoutOf(params: *const ObjectMap) tail.Layout {
    const name = store.text(params, "layout", layouts[0]);
    if (std.mem.eql(u8, name, "em V")) return .v_tail;
    if (std.mem.eql(u8, name, "sem cauda")) return .tailless;
    if (std.mem.eql(u8, name, "em H")) return .h_tail;
    return .conventional;
}

// ------------------------------------------------------------------ as asas do conjunto
/// uma asa do conjunto: os parâmetros dela e onde fica em relação à primeira
const Placed = struct { name: []const u8, params: *const ObjectMap, dx: f64 = 0, dy: f64 = 0, dz: f64 = 0, di: f64 = 0, join: bool = false, devices: ?Value = null };

/// as linhas da configuração escolhida (ou da tabela de Projetar)
fn layoutRows(project: *store.Project) []const Value {
    const params = draft(project);
    const chosen = store.text(params, "config", live_layout);
    if (!std.mem.eql(u8, chosen, live_layout)) {
        for (project.list("configs").items) |item| if (item == .object and std.mem.eql(u8, store.text(&item.object, "name", ""), chosen)) {
            if (item.object.get("wings")) |wings| if (wings == .array) return wings.array.items;
        };
    }
    return project.list("wing_layout").items;
}

/// as asas do conjunto: a primeira da configuração (ou a do campo 'asa', senão a última guardada) e as outras
pub fn placedWings(project: *store.Project, memory: std.mem.Allocator) ![]const Placed {
    var out: std.ArrayList(Placed) = .empty;
    for (layoutRows(project)) |row| {
        if (row != .object) continue;
        const object = &row.object;
        const name = store.text(object, "wing", "");
        const params = wing_stage.wingOrDraft(project, name) orelse continue;
        try out.append(memory, .{ .name = name, .params = params, .dx = store.number(object, "dx", 0), .dy = store.number(object, "dy", 0), .dz = store.number(object, "dz", 0), .di = store.number(object, "di", 0), .join = store.flag(object, "join", false), .devices = object.get("devices") });
    }
    if (out.items.len > 0) return out.items;
    const wings = project.list("wings").items;
    if (wings.len == 0) return out.items;
    const wanted = store.text(draft(project), "wing", "");
    const name = if (wing_stage.keptWing(project, wanted) != null) wanted else store.nameOf(wings[wings.len - 1]);
    try out.append(memory, .{ .name = name, .params = wing_stage.keptWing(project, name).? });
    return out.items;
}

// ------------------------------------------------------------------ o perfil da cauda
fn tailAirfoil(context: *stages.Context, memory: std.mem.Allocator, name: []const u8, inverted: bool) !tail.TailAirfoil {
    var airfoil: model.Airfoil = if (airfoils.lookup(context, name)) |entry| try airfoils.airfoilOf(memory, entry) else .{ .name = name };
    if (airfoils.lookup(context, name) == null) {
        var digits: usize = 0;
        for (name) |char| digits += @intFromBool(std.ascii.isDigit(char));
        if (digits != 4) airfoil.name = "NACA 0012";
    }
    airfoil.inverted = false;
    const numbers = aircraft_model.params.props2d(airfoil) catch [5]f64{ airfoil.cl_alpha, 0, airfoil.cl_max, airfoil.cd0, 0 };
    var alphas: [73]f64 = undefined;
    for (&alphas, 0..) |*alpha, i| alpha.* = -16 + 0.5 * @as(f64, @floatFromInt(i));
    var polar: core.section.Polar = .{};
    core.section.modelPolar(.{ .cl_alpha = numbers[0], .alpha0 = numbers[1], .cl_max = numbers[2], .cd0 = numbers[3], .cm_ac = numbers[4] }, &alphas, &polar);
    var low: f64 = std.math.inf(f64);
    var high: f64 = -std.math.inf(f64);
    for (polar.cl[0..polar.count]) |lift| {
        low = @min(low, lift);
        high = @max(high, lift);
    }
    if (!std.math.isFinite(low)) {
        low = -numbers[2];
        high = numbers[2];
    }
    const slope: f64 = if (numbers[0] < 1) numbers[0] * 180.0 / std.math.pi else numbers[0];
    if (inverted) return .{ .lift_slope = slope, .alpha_zero = -numbers[1], .lift_low = -high, .lift_high = -low };
    return .{ .lift_slope = slope, .alpha_zero = numbers[1], .lift_low = low, .lift_high = high };
}

// ------------------------------------------------------------------ os comandos
const Command = struct { surface: []const u8, control: model.Control };

/// uma superfície a mais (EV ou EH) presa em qualquer superfície do conjunto, numa fração da semienvergadura dela:
/// uma EV na ponta da asa no lugar do winglet, no meio, ou duas (uma de cada lado)
const Extra = struct { kind: []const u8, host: []const u8, station: f64, sides: []const u8, size: f64, chord: f64, taper: f64 };
const extra_kinds = [_][]const u8{ "EV", "EH" };
const extra_sides = [_][]const u8{ "os dois lados", "direita", "esquerda" };

fn extraRows(memory: std.mem.Allocator, params: *const ObjectMap) ![]Extra {
    var out: std.ArrayList(Extra) = .empty;
    const list = params.get("extras") orelse return out.items;
    if (list != .array) return out.items;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const row = &item.object;
        try out.append(memory, .{ .kind = store.text(row, "kind", "EV"), .host = store.text(row, "host", ""), .station = store.number(row, "station", 1), .sides = store.text(row, "sides", extra_sides[0]), .size = store.number(row, "size", 0.2), .chord = store.number(row, "chord", 0.15), .taper = store.number(row, "taper", 0.7) });
    }
    return out.items;
}

/// o ponto (x, y, z) a uma fração da semienvergadura de `host`, do lado direito (`side` = 1) ou esquerdo (−1), no
/// bordo de ataque
fn stationPoint(host: model.Surface, station: f64, side: f64) [3]f64 {
    var buffer: [model.limits.sections]model.Section = undefined;
    const sections = model.sortedSections(&host, &buffer);
    const along = std.math.clamp(station, 0, 1) * model.semispan(&host);
    const offset = model.sectionAt(sections, along, "x_offset");
    if (host.vertical) return .{ host.x - offset, host.y, host.z - along };
    const dihedral = std.math.degreesToRadians(host.dihedral);
    const lateral = if (host.symmetric) host.y + side * along * @cos(dihedral) else host.y + along * @cos(dihedral);
    return .{ host.x - offset, lateral, host.z - along * @sin(dihedral) };
}

/// as superfícies a mais da tabela, presas no lugar
fn extraSurfaces(memory: std.mem.Allocator, rows: []const Extra, surfaces: []const model.Surface, fin_model: model.Airfoil, tail_model: model.Airfoil) ![]model.Surface {
    var out: std.ArrayList(model.Surface) = .empty;
    for (rows, 0..) |row, k| {
        const host = for (surfaces) |surface| {
            if (std.mem.eql(u8, surface.name, row.host)) break surface;
        } else continue;
        if (row.size <= 0 or row.chord <= 0) continue;
        const vertical = std.mem.eql(u8, row.kind, "EV");
        if (!vertical) {
            // uma EH a mais é inteira (as duas metades), centrada na linha do avião, na altura do ponto da raiz
            const at = stationPoint(host, 0, 1);
            const tip = row.chord * row.taper;
            try out.append(memory, .{ .name = try std.fmt.allocPrint(memory, "EH extra {d}", .{k + 1}), .role = "htail", .x = at[0], .z = at[2], .airfoil = tail_model, .eta = 0.9, .sections = try memory.dupe(model.Section, &.{ .{ .y = 0, .chord = row.chord }, .{ .y = row.size / 2, .chord = tip, .x_offset = (row.chord - tip) / 4 } }) });
            continue;
        }
        const both = std.mem.eql(u8, row.sides, extra_sides[0]);
        const left_only = std.mem.eql(u8, row.sides, extra_sides[2]);
        for ([_]f64{ 1, -1 }) |side| {
            if (!both and ((side > 0) == left_only)) continue;
            const at = stationPoint(host, row.station, side);
            var fin = try verticalSurface(memory, try std.fmt.allocPrint(memory, "EV extra {d}{s}", .{ k + 1, if (!both) "" else if (side > 0) " dir" else " esq" }), row.size, row.chord, row.taper, fin_model);
            fin.x = at[0];
            fin.y = at[1];
            fin.z = at[2];
            try out.append(memory, fin);
        }
    }
    return out.items;
}

/// a superfície de um comando que ainda não tem uma (ele não entra no avião até escolher)
const no_surface = "(sem superfície)";

/// os comandos da regra da etapa (aileron ou elevon na asa, profundor na EH, leme na EV) para as superfícies
fn ruleCommands(memory: std.mem.Allocator, params: *const ObjectMap, surfaces: []const model.Surface) ![]Command {
    var out: std.ArrayList(Command) = .empty;
    const start = field(params, "aileron_start");
    const end = @min(@max(field(params, "aileron_end"), start + 0.05), 1.0);
    const chord = field(params, "aileron_chord");
    const tailless = layoutOf(params) == .tailless;
    var wings: usize = 0;
    for (surfaces) |surface| {
        if (std.mem.eql(u8, surface.role, "wing")) {
            wings += 1;
            const tandem = tailless and wings == 2;
            if (wings > 2) continue;
            const kind = if (tandem) "elevator" else if (tailless and !hasSecond(surfaces)) "elevon" else "aileron";
            try out.append(memory, .{ .surface = surface.name, .control = .{ .kind = kind, .span_start = start, .span_end = end, .chord_frac = chord } });
        } else if (std.mem.eql(u8, surface.role, "htail")) {
            const kind = if (std.mem.eql(u8, surface.name, "cauda em V")) "ruddervator" else "elevator";
            try out.append(memory, .{ .surface = surface.name, .control = .{ .kind = kind, .span_start = 0, .span_end = 1, .chord_frac = field(params, "elevator") } });
        } else if (std.mem.eql(u8, surface.role, "vtail")) {
            try out.append(memory, .{ .surface = surface.name, .control = .{ .kind = "rudder", .span_start = 0, .span_end = 1, .chord_frac = field(params, "rudder") } });
        }
    }
    return out.items;
}

fn hasSecond(surfaces: []const model.Surface) bool {
    var wings: usize = 0;
    for (surfaces) |surface| wings += @intFromBool(std.mem.eql(u8, surface.role, "wing"));
    return wings > 1;
}

/// a tabela de comandos do rascunho
fn tableCommands(memory: std.mem.Allocator, params: *const ObjectMap) ![]Command {
    var out: std.ArrayList(Command) = .empty;
    const list = params.get("controls") orelse return out.items;
    if (list != .array) return out.items;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const control = store.child(&item.object, "control") orelse continue;
        var gains = model.kindGains(store.text(control, "kind", "aileron"));
        if (control.get("mix")) |mix| if (mix == .array and mix.array.items.len == 3) for (mix.array.items, 0..) |value, k| {
            gains[k] = switch (value) {
                .float => |x| x,
                .integer => |x| @floatFromInt(x),
                else => gains[k],
            };
        };
        try out.append(memory, .{ .surface = store.text(&item.object, "surface", ""), .control = .{ .kind = store.text(control, "kind", "aileron"), .span_start = store.number(control, "span_start", 0.6), .span_end = store.number(control, "span_end", 1), .chord_frac = store.number(control, "chord_frac", 0.25), .mix = gains } });
    }
    return out.items;
}

// ------------------------------------------------------------------ o conjunto
/// o conjunto montado: as superfícies (asas no lugar, cauda e tubo), a conta e as asas analisadas
pub const Built = struct {
    surfaces: []model.Surface,
    booms: []const model.Boom,
    result: *tail.Result,
    wing: *wing_line.Result,
    shape: wing_stage.Shape,
    wings: []const Placed,
    commands: []const Command,
};

fn verticalSurface(memory: std.mem.Allocator, name: []const u8, height: f64, root_chord: f64, taper: f64, airfoil: model.Airfoil) !model.Surface {
    const tip = root_chord * taper;
    return .{ .name = name, .role = "vtail", .vertical = true, .symmetric = false, .airfoil = airfoil, .eta = 0.9, .sections = try memory.dupe(model.Section, &.{ .{ .y = 0, .chord = root_chord }, .{ .y = height, .chord = tip, .x_offset = (root_chord - tip) / 4 } }) };
}

pub fn build(context: *stages.Context, memory: std.mem.Allocator, params: *const ObjectMap, use_rule: bool) !?Built {
    const project = &context.project;
    const wings = try placedWings(project, memory);
    if (wings.len == 0) return null;
    const layout = layoutOf(params);
    const rules = project.section("rules");
    const requirements = project.section("requirements");

    // as asas, analisadas, no lugar
    const wing_result = try memory.create(wing_line.Result);
    wing_result.* = .{};
    const shape = try wing_stage.analyze(context, memory, wings[0].params, wing_result);
    var surfaces: std.ArrayList(model.Surface) = .empty;
    var others: std.ArrayList(tail.OtherWing) = .empty;
    var planforms: std.ArrayList(*wing_line.Planform) = .empty;
    const first_planform = try memory.create(wing_line.Planform);
    first_planform.* = shape.planform;
    try planforms.append(memory, first_planform);
    for (wings, 0..) |placed, k| {
        var incidence = wing_result.incidence;
        var slope = wing_result.lift_slope;
        var planform = first_planform;
        if (k > 0) {
            const other = try memory.create(wing_line.Result);
            other.* = .{};
            const other_shape = try wing_stage.analyze(context, memory, placed.params, other);
            incidence = wing_result.incidence + placed.di;
            if (!std.mem.eql(u8, other_shape.names[0], shape.names[0])) incidence += other.alpha_zero - wing_result.alpha_zero;
            slope = other.lift_slope;
            planform = try memory.create(wing_line.Planform);
            planform.* = other_shape.planform;
            try planforms.append(memory, planform);
            try others.append(memory, .{ .planform = planform, .shift = placed.dx, .lift_slope = slope, .behind = placed.dx > 0 });
        }
        var surface = try wing_stage.surfaceOf(context, memory, placed.params, if (k > 0) try std.fmt.allocPrint(memory, "{s} ({d})", .{ placed.name, k + 1 }) else placed.name, incidence);
        surface.x = -placed.dx;
        surface.y = placed.dy;
        surface.z = -placed.dz;
        if (k > 0 and layout == .tailless and placed.dx > 0) {
            surface.downwash = true;
            surface.eta = field(params, "tail_eta");
        }
        if (placed.devices) |devices| if (devices == .array and devices.array.items.len > 0) {
            surface.devices = std.json.parseFromValueLeaky([]const model.Device, memory, devices, .{ .ignore_unknown_fields = true }) catch &.{};
        };
        try surfaces.append(memory, surface);
        if (k > 0 and placed.join) try wing_stage.joinTips(memory, &surfaces.items[0], &surfaces.items[surfaces.items.len - 1]);
    }

    // a conta do núcleo
    const horizontal = try tailAirfoil(context, memory, store.text(params, "tail_airfoil", "NACA 0012"), store.flag(params, "tail_inverted", false));
    const vertical = try tailAirfoil(context, memory, store.text(params, "vtail_airfoil", "NACA 0012"), false);
    const count = wing_result.alpha_count;
    const wing: tail.Wing = .{ .planform = first_planform, .area = wing_result.area, .mean_chord = wing_result.mean_chord, .span = wing_result.span, .aspect_ratio = wing_result.aspect_ratio, .lift_slope = wing_result.lift_slope, .lift_zero = wing_result.lift_zero, .moment = wing_result.moment, .lift_max = wing_result.lift_max, .lift_cruise = wing_result.lift_cruise, .incidence = wing_result.incidence, .stall_speed = wing_result.stall_speed, .aero_center = wing_result.aero_center, .alpha = wing_result.alpha[0..count], .lift = wing_result.lift[0..count] };
    const input: tail.Input = .{
        .layout = layout,
        .arm = field(params, "arm"),
        .arm_from_cg = std.mem.eql(u8, store.text(params, "arm_from", arm_from[0]), arm_from[1]),
        .tail_volume_h = field(params, "VH"),
        .tail_volume_v = field(params, "VV"),
        .aspect_h = field(params, "AR_h"),
        .aspect_v = field(params, "AR_v"),
        .taper_h = field(params, "taper_h"),
        .taper_v = field(params, "taper_v"),
        .elevator = field(params, "elevator"),
        .aileron_start = field(params, "aileron_start"),
        .aileron_end = field(params, "aileron_end"),
        .aileron_chord = field(params, "aileron_chord"),
        .margin_target = field(params, "sm_target"),
        .margin_min = field(params, "sm_min"),
        .eta = field(params, "tail_eta"),
        .boom_pitch = field(params, "boom_pitch"),
        .tip_fin = field(params, "tip_fin"),
        .tip_fin_chord = field(params, "tip_fin_chord"),
        .horizontal = horizontal,
        .vertical_slope = vertical.lift_slope,
        .mass = registry.fieldNumber(requirements, &registry.requirement_fields, "mass"),
        .density = registry.rho(project),
        .cruise_speed = registry.fieldNumber(requirements, &registry.requirement_fields, "V_cruise"),
        .elevator_up = registry.fieldNumber(rules, &registry.rule_fields, "de_max"),
        .elevator_down = registry.fieldNumber(rules, &registry.rule_fields, "de_down"),
        .aileron_up = registry.fieldNumber(rules, &registry.rule_fields, "da_max"),
        .aileron_down = registry.fieldNumber(rules, &registry.rule_fields, "da_down"),
        .gear_aft = registry.fieldNumber(rules, &registry.rule_fields, "main_gear_aft"),
        .tail_density = registry.fieldNumber(rules, &registry.rule_fields, "tail_density"),
        .boom_density = registry.fieldNumber(rules, &registry.rule_fields, "boom_density"),
    };

    // os comandos (a tabela manda em todos; vazia, a regra) e as faixas de arfagem nas asas
    const tail_model: model.Airfoil = .{ .name = store.text(params, "tail_airfoil", "NACA 0012"), .inverted = store.flag(params, "tail_inverted", false) };
    const fin_model: model.Airfoil = .{ .name = store.text(params, "vtail_airfoil", "NACA 0012") };
    const commands_rule = try ruleCommands(memory, params, surfaces.items);
    const table = if (use_rule) &[_]Command{} else try tableCommands(memory, params);
    const commands = if (table.len > 0) table else commands_rule;
    var strips: std.ArrayList(tail.PitchStrip) = .empty;
    if (layout == .tailless) for (commands) |command| for (surfaces.items, 0..) |surface, k| {
        if (k >= planforms.items.len or !std.mem.eql(u8, surface.name, command.surface)) continue;
        try strips.append(memory, .{ .planform = planforms.items[k], .shift = -surface.x, .span_start = command.control.span_start, .span_end = command.control.span_end, .chord_fraction = command.control.chord_frac, .gain = command.control.gains()[0] });
    };
    const result = try memory.create(tail.Result);
    tail.analyze(wing, others.items, strips.items, input, result);

    // as superfícies da cauda e o tubo, presos no lugar (as amarrações do modelo)
    var booms: []const model.Boom = &.{};
    if (layout != .tailless) {
        const semispan = result.span_h / 2;
        const root = result.root_chord_h;
        const tip = root * field(params, "taper_h");
        const name = if (layout == .v_tail) "cauda em V" else "EH";
        try surfaces.append(memory, .{ .name = name, .role = "htail", .x = -(result.tail_center - root / 4), .dihedral = result.gamma, .incidence = result.incidence_h * @cos(std.math.degreesToRadians(result.gamma)), .airfoil = tail_model, .eta = input.eta, .downwash = true, .mount = "tubo:0", .sections = try memory.dupe(model.Section, &.{ .{ .y = 0, .chord = root }, .{ .y = semispan, .chord = tip, .x_offset = (root - tip) / 4 } }) });
        const tail_index = surfaces.items.len - 1;
        if (layout == .conventional) {
            var fin = try verticalSurface(memory, "EV", result.height_v, result.root_chord_v, field(params, "taper_v"), fin_model);
            fin.mount = "tubo:0";
            try surfaces.append(memory, fin);
        } else if (layout == .h_tail) for ([_][]const u8{ "EV direita", "EV esquerda" }, [_][]const u8{ "ponta_dir", "ponta_esq" }) |fin_name, where| {
            var fin = try verticalSurface(memory, fin_name, result.height_v, result.root_chord_v, field(params, "taper_v"), fin_model);
            fin.mount = try std.fmt.allocPrint(memory, "{s}:{d}", .{ where, tail_index });
            try surfaces.append(memory, fin);
        };
        booms = try memory.dupe(model.Boom, &.{.{ .name = "tubo de cauda", .enabled = true, .x_start = -result.boom_start, .length = result.boom_length, .diameter = field(params, "boom_diameter"), .pitch = input.boom_pitch }});
    } else if (input.tip_fin > 0) {
        var host: usize = 0;
        for (surfaces.items, 0..) |surface, k| if (k > 0 and std.mem.eql(u8, surface.role, "wing") and -surface.x > 0) {
            host = k;
            break;
        };
        for ([_][]const u8{ "deriva direita", "deriva esquerda" }, [_][]const u8{ "ponta_dir", "ponta_esq" }) |fin_name, where| {
            var fin = try verticalSurface(memory, fin_name, input.tip_fin, result.root_chord_v, field(params, "taper_v"), fin_model);
            fin.mount = try std.fmt.allocPrint(memory, "{s}:{d}", .{ where, host });
            fin.eta = 1.0;
            try surfaces.append(memory, fin);
        }
    }
    // as superfícies a mais (EV ou EH em qualquer lugar), antes dos comandos para elas poderem ter os seus
    try surfaces.appendSlice(memory, try extraSurfaces(memory, try extraRows(memory, params), surfaces.items, fin_model, tail_model));
    // os comandos nas superfícies (a regra da cauda vale para as que acabaram de entrar)
    const all_commands = if (table.len > 0) table else try ruleCommands(memory, params, surfaces.items);
    for (surfaces.items) |*surface| {
        var own: std.ArrayList(model.Control) = .empty;
        for (all_commands) |command| if (std.mem.eql(u8, command.surface, surface.name)) try own.append(memory, command.control);
        surface.controls = own.items;
    }
    const plane: model.Aircraft = .{ .name = "conjunto", .surfaces = surfaces.items, .booms = booms };
    model.applyMounts(&plane, surfaces.items);
    return .{ .surfaces = surfaces.items, .booms = booms, .result = result, .wing = wing_result, .shape = shape, .wings = wings, .commands = all_commands };
}

fn viewOf(memory: std.mem.Allocator, built: Built) !?simulation.View {
    const plane: model.Aircraft = .{ .name = "conjunto", .surfaces = built.surfaces, .booms = built.booms };
    var diagnosis: model.Diag = .{};
    const pieces = aircraft_model.skeleton.build(memory, &plane, &diagnosis) catch return null;
    var meshes: std.ArrayList(simulation.Mesh) = .empty;
    for (pieces.pieces) |piece| switch (piece.color) {
        .wing, .htail, .vtail, .control, .device, .boom => try meshes.append(memory, .{ .kind = @tagName(piece.color), .vertices = piece.mesh.v, .faces = piece.mesh.f }),
        else => {},
    };
    return .{ .meshes = meshes.items, .cg = .{ -built.result.x_cg, 0, 0 } };
}

/// a caixa em volta de um comando (só o lado direito; numa superfície vertical, ela toda): a vista 3D aproxima dele
fn commandFocus(memory: std.mem.Allocator, built: Built, command: Command) !?simulation.Focus {
    const host = for (built.surfaces) |surface| {
        if (std.mem.eql(u8, surface.name, command.surface)) break surface;
    } else return null;
    var surface = host;
    surface.controls = try memory.dupe(model.Control, &.{command.control});
    surface.devices = &.{};
    const plane: model.Aircraft = .{ .name = "comando", .surfaces = &.{surface} };
    var diagnosis: model.Diag = .{};
    const pieces = aircraft_model.skeleton.build(memory, &plane, &diagnosis) catch return null;
    var low: [3]f64 = @splat(std.math.inf(f64));
    var high: [3]f64 = @splat(-std.math.inf(f64));
    for (pieces.pieces) |piece| {
        if (piece.color != .control) continue;
        for (piece.mesh.v) |point| {
            if (point[1] < -1e-6) continue;
            for (0..3) |i| {
                low[i] = @min(low[i], point[i]);
                high[i] = @max(high[i], point[i]);
            }
        }
    }
    if (!std.math.isFinite(low[0])) return null;
    return .{ .low = low, .high = high };
}

// ------------------------------------------------------------------ pedidos
fn numberOf(value: Value) ?f64 {
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        .string => |digits| std.fmt.parseFloat(f64, std.mem.trim(u8, digits, " ")) catch null,
        else => null,
    };
}

/// muda o projeto conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const project = &context.project;
    const params = draft(project);
    // a vista aproxima do comando só enquanto é ele que se edita ou que se clicou na tabela
    if (!std.mem.eql(u8, request.do, "show") and !std.mem.eql(u8, request.do, "grid")) context.focus_command = null;
    if (context.takeSelection("comandos")) |row| context.focus_command = row;
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        if (try stages.applyFields(project, params, &tail_fields, "", values) > 0) _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "load")) {
        const list = project.list("sets");
        const index = stages.within(request.index, list.items.len) orelse return "";
        const kept = store.child(&list.items[index].object, "params") orelse return "";
        try project.root.object.put(project.memory(), "tail_draft", try stages.clone(project.memory(), .{ .object = kept.* }));
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        const list = project.list("sets");
        const index = stages.within(request.index, list.items.len) orelse return "";
        _ = list.orderedRemove(index);
        _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "keep")) return keepSet(context, memory);
    if (std.mem.eql(u8, request.do, "grid")) {
        if (std.mem.eql(u8, request.grid, "comandos")) try editCommands(context, memory, request) else if (std.mem.eql(u8, request.grid, "extras")) try editExtras(context, memory, request) else return error.UnknownGrid;
        _ = context.save();
    }
    return "";
}

/// guarda o rascunho como conjunto (`keep_set`): os parâmetros e a cópia das asas; o rascunho ganha o próximo nome
fn keepSet(context: *stages.Context, memory: std.mem.Allocator) ![]const u8 {
    const project = &context.project;
    const owned = project.memory();
    const params = draft(project);
    const wings = try placedWings(project, memory);
    if (wings.len == 0) return "Guarde uma asa primeiro (Aerodinâmica → Projetar → Guardar asa).";
    try store.setText(project, params, "wing", wings[0].name);
    var candidate: ObjectMap = .empty;
    try candidate.put(owned, "params", try stages.clone(owned, .{ .object = params.* }));
    for (project.list("wings").items) |item| if (std.mem.eql(u8, store.nameOf(item), wings[0].name)) try candidate.put(owned, "wing", try stages.clone(owned, item));
    if (wings.len > 1) for (project.list("wings").items) |item| if (std.mem.eql(u8, store.nameOf(item), wings[1].name)) try candidate.put(owned, "wing2", try stages.clone(owned, item));
    try candidate.put(owned, "note", .{ .string = "" });
    const name = try owned.dupe(u8, store.text(params, "name", "conjunto 1"));
    const list = project.list("sets");
    try stages.put(list, .{ .object = candidate });
    var taken: std.ArrayList([]const u8) = .empty;
    for (list.items) |item| try taken.append(memory, store.nameOf(item));
    try store.setText(project, params, "name", try stages.nextName(owned, name, taken.items));
    try store.setText(project, project.section("power_draft"), "set", name);
    _ = context.save();
    return std.fmt.allocPrint(memory, "guardado: {s}", .{name});
}

fn commandValue(memory: std.mem.Allocator, command: Command) !Value {
    var control: ObjectMap = .empty;
    try control.put(memory, "kind", .{ .string = command.control.kind });
    try control.put(memory, "span_start", .{ .float = command.control.span_start });
    try control.put(memory, "span_end", .{ .float = command.control.span_end });
    try control.put(memory, "chord_frac", .{ .float = command.control.chord_frac });
    var mix = std.json.Array.init(memory);
    for (command.control.gains()) |gain| try mix.append(.{ .float = gain });
    try control.put(memory, "mix", .{ .array = mix });
    var row: ObjectMap = .empty;
    try row.put(memory, "surface", .{ .string = command.surface });
    try row.put(memory, "control", .{ .object = control });
    return .{ .object = row };
}

fn editExtras(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) !void {
    const project = &context.project;
    const owned = project.memory();
    const params = draft(project);
    const entry = try params.getOrPut(owned, "extras");
    if (!entry.found_existing or entry.value_ptr.* != .array) entry.value_ptr.* = .{ .array = std.json.Array.init(owned) };
    const rows = &entry.value_ptr.array;
    if (std.mem.eql(u8, request.edit, "add")) {
        // uma EV em cada ponta da primeira asa: o caso mais comum (no lugar do winglet)
        var host: []const u8 = "";
        if (try build(context, memory, params, false)) |built| host = built.surfaces[0].name;
        var row: ObjectMap = .empty;
        try row.put(owned, "kind", .{ .string = "EV" });
        try row.put(owned, "host", .{ .string = try owned.dupe(u8, host) });
        try row.put(owned, "station", .{ .float = 1 });
        try row.put(owned, "sides", .{ .string = extra_sides[0] });
        try row.put(owned, "size", .{ .float = 0.2 });
        try row.put(owned, "chord", .{ .float = 0.15 });
        try row.put(owned, "taper", .{ .float = 0.7 });
        try rows.append(.{ .object = row });
        return;
    }
    if (rows.items.len == 0) return;
    const index: usize = stages.within(request.row, rows.items.len) orelse rows.items.len - 1;
    if (std.mem.eql(u8, request.edit, "delete")) {
        _ = rows.orderedRemove(index);
        return;
    }
    if (!std.mem.eql(u8, request.edit, "set")) return error.UnknownEdit;
    const row = &rows.items[index].object;
    if (request.value == .string) return store.setText(project, row, request.key, request.value.string);
    const number = numberOf(request.value) orelse return;
    try store.setNumber(project, row, request.key, number);
}

fn editCommands(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) !void {
    const project = &context.project;
    const owned = project.memory();
    const params = draft(project);
    const entry = try params.getOrPut(owned, "controls");
    if (!entry.found_existing or entry.value_ptr.* != .array) entry.value_ptr.* = .{ .array = std.json.Array.init(owned) };
    const rows = &entry.value_ptr.array;
    const index: usize = stages.within(request.row, rows.items.len) orelse if (rows.items.len > 0) rows.items.len - 1 else 0;
    context.focus_command = null;
    if (std.mem.eql(u8, request.edit, "rule")) {
        const built = try build(context, memory, params, true) orelse return;
        rows.clearRetainingCapacity();
        for (built.commands) |command| try rows.append(try commandValue(owned, command));
        return;
    }
    if (std.mem.eql(u8, request.edit, "clear")) return rows.clearRetainingCapacity();
    if (std.mem.eql(u8, request.edit, "add")) {
        // primeiro o tipo, depois a superfície: o comando novo nasce sem superfície e a vista aproxima dele quando
        // ela é escolhida
        try rows.append(try commandValue(owned, .{ .surface = "", .control = .{ .kind = "aileron", .span_start = 0.6, .span_end = 1, .chord_frac = 0.25, .mix = .{ 0, 1, 0 } } }));
        context.focus_command = rows.items.len - 1;
        return;
    }
    if (rows.items.len == 0) return;
    if (std.mem.eql(u8, request.edit, "delete")) {
        _ = rows.orderedRemove(index);
        return;
    }
    if (!std.mem.eql(u8, request.edit, "set")) return error.UnknownEdit;
    context.focus_command = index;
    const row = &rows.items[index].object;
    if (std.mem.eql(u8, request.key, "surface")) {
        if (request.value == .string) try store.setText(project, row, "surface", if (std.mem.eql(u8, request.value.string, no_surface)) "" else request.value.string);
        return;
    }
    const control = store.child(row, "control") orelse return;
    if (std.mem.eql(u8, request.key, "kind")) {
        if (request.value == .string) try store.setText(project, control, "kind", request.value.string);
        return;
    }
    const number = numberOf(request.value) orelse return;
    for ([_][]const u8{ "pitch", "roll", "yaw" }, 0..) |axis, k| if (std.mem.eql(u8, request.key, axis)) {
        var gains = model.kindGains(store.text(control, "kind", "aileron"));
        if (control.get("mix")) |mix| if (mix == .array and mix.array.items.len == 3) for (mix.array.items, 0..) |value, i| {
            gains[i] = numberOf(value) orelse gains[i];
        };
        gains[k] = number;
        var mix = std.json.Array.init(owned);
        for (gains) |gain| try mix.append(.{ .float = gain });
        try control.put(owned, "mix", .{ .array = mix });
        return;
    };
    try store.setNumber(project, control, request.key, number);
}

// ------------------------------------------------------------------ a página
fn text(memory: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(memory, format, args);
}

fn status(ok: bool, soft: bool) @FieldType(simulation.Check, "status") {
    return if (ok) .ok else if (soft) .atencao else .falha;
}

/// a página: o formulário, os conjuntos guardados, a tabela de comandos, a conta e a vista 3D
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const project = &context.project;
    const params = draft(project);

    // o formulário, com as escolhas
    var configs: std.ArrayList([]const u8) = .empty;
    try configs.append(memory, live_layout);
    for (project.list("configs").items) |item| if (item == .object) try configs.append(memory, store.text(&item.object, "name", ""));
    var wing_names: std.ArrayList([]const u8) = .empty;
    for (project.list("wings").items) |item| try wing_names.append(memory, store.nameOf(item));
    var profiles: std.ArrayList([]const u8) = .empty;
    for (tail_airfoils) |name| try profiles.append(memory, name);
    for (try airfoils.names(context, memory)) |name| {
        var known = false;
        for (profiles.items) |other| known = known or std.mem.eql(u8, other, name);
        if (!known) try profiles.append(memory, name);
    }
    var form: std.ArrayList(simulation.Param) = .empty;
    for (tail_fields) |item| {
        var param = try stages.fieldParam(params, item, "", "", memory);
        if (std.mem.eql(u8, item.key, "config")) {
            param.kind = .choice;
            param.choices = configs.items;
        } else if (std.mem.eql(u8, item.key, "wing")) {
            param.kind = .choice;
            param.choices = wing_names.items;
        } else if (std.mem.eql(u8, item.key, "tail_airfoil") or std.mem.eql(u8, item.key, "vtail_airfoil")) {
            param.kind = .choice;
            param.choices = profiles.items;
        }
        try form.append(memory, param);
    }
    var disabled: std.ArrayList([]const u8) = .empty;
    if (layoutRows(project).len > 0) try disabled.append(memory, "wing");
    const has_table = if (params.get("controls")) |list| list == .array and list.array.items.len > 0 else false;
    if (has_table) for (rule_keys) |key| try disabled.append(memory, key);

    var kept: std.ArrayList([]const u8) = .empty;
    for (project.list("sets").items) |item| try kept.append(memory, store.nameOf(item));
    const base: simulation.StagePage = .{
        .title = "Empenagem e comandos",
        .help = "As superfícies que acompanham a asa guardada: cauda (convencional, em V ou sem cauda), tubo, profundor, leme e aileron, por volume de cauda. Põe o CG na margem pedida e diz a faixa de CG, a incidência da EH e se os comandos dão conta. Guarde conjuntos para a etapa Motores.",
        .keep_label = "Guardar conjunto",
        .params = form.items,
        .disabled = disabled.items,
        .kept = kept.items,
    };
    const built = try build(context, memory, params, false) orelse {
        var empty = base;
        empty.message = "Guarde uma asa primeiro (Aerodinâmica → Projetar → Guardar asa).";
        return empty;
    };
    const result = built.result;
    const layout = layoutOf(params);
    const rules = project.section("rules");
    const de_max = registry.fieldNumber(rules, &registry.rule_fields, "de_max");
    const de_down = registry.fieldNumber(rules, &registry.rule_fields, "de_down");

    // os gráficos
    const with_vlm = store.flag(params, "vlm", false);
    const figures = try simulation.Figures.init(memory, if (with_vlm) &(plots ++ vlm_plots) else &plots);
    const count = result.alpha_count;
    for (0..3) |k| {
        if (!result.with_limits and k != 1) continue;
        try figures.curve("cm", .{ .name = place_names[k], .x = try memory.dupe(f64, result.alpha[0..count]), .y = try memory.dupe(f64, result.moment[k][0..count]), .color = place_colors[k], .width = if (k == 1) 2.4 else 1.6 });
        try figures.curve("de", .{ .name = place_names[k], .x = try memory.dupe(f64, &result.speed), .y = try memory.dupe(f64, &result.elevator[k]), .color = place_colors[k], .width = if (k == 1) 2.4 else 1.6 });
    }
    try figures.guide("cm", .{ .name = "C_m = 0", .value = 0, .vertical = false, .color = "#7f7f7f", .dashed = true });
    try figures.guide("de", .{ .name = "fim do curso", .value = -de_max, .vertical = false, .color = "#d62728", .dashed = true });
    try figures.guide("de", .{ .name = "fim do curso ", .value = de_down, .vertical = false, .color = "#d62728", .dashed = true, .legend = false });
    try figures.guide("de", .{ .name = "cruzeiro", .value = registry.fieldNumber(project.section("requirements"), &registry.requirement_fields, "V_cruise"), .vertical = true, .color = "#7f7f7f" });
    if (result.with_limits) try figures.curve("cg", .{ .name = "faixa possível", .x = try memory.dupe(f64, &.{ 100 * result.h_fwd, 100 * result.h_aft }), .y = try memory.dupe(f64, &.{ 0, 0 }), .fill = try memory.dupe(f64, &.{ 1, 1 }), .color = "#2ca02c" });
    try figures.guide("cg", .{ .name = "ponto neutro", .value = 100 * result.h_n, .vertical = true, .color = "#d62728" });
    try figures.guide("cg", .{ .name = "CG no alvo", .value = 100 * result.h_cg, .vertical = true, .color = "#000000", .width = 2.4 });

    // o resumo
    var summary: std.ArrayList([2][]const u8) = .empty;
    try summary.append(memory, .{ "cauda", layouts[@intFromEnum(layout)] });
    if (layout != .tailless) {
        try summary.append(memory, .{ "S_h, S_v (m²)", try text(memory, "{d:.4}, {d:.4}", .{ result.area_h, result.area_v }) });
        try summary.append(memory, .{ "envergadura da EH, altura da EV (m)", try text(memory, "{d:.3}, {d:.3}", .{ result.span_h, result.height_v }) });
        try summary.append(memory, .{ "braço da cauda, tubo (m)", try text(memory, "{d:.3}, {d:.3}", .{ result.arm, result.boom_length }) });
        try summary.append(memory, .{ "V_H, V_V", try text(memory, "{d:.3}, {d:.4}", .{ result.volume_h, result.volume_v }) });
        try summary.append(memory, .{ "incidência da EH (°)", try text(memory, "{d:.2}", .{result.incidence_h}) });
        try summary.append(memory, .{ "dε/dα", try text(memory, "{d:.3}", .{result.downwash_slope}) });
        try summary.append(memory, .{ "C_nβ da cauda (1/rad)", try text(memory, "{d:.4}", .{result.yaw_stability}) });
        try summary.append(memory, .{ "massa da empenagem + tubo (kg)", try text(memory, "{d:.3}", .{result.mass_tail + result.mass_boom}) });
    }
    try summary.append(memory, .{ "ponto neutro (% CMA)", try text(memory, "{d:.1}", .{100 * result.h_n}) });
    try summary.append(memory, .{ "CG no alvo (% CMA; x em m)", try text(memory, "{d:.1}; {d:.3}", .{ 100 * result.h_cg, result.x_cg }) });
    if (result.with_limits) try summary.append(memory, .{ "faixa do CG (% CMA)", try text(memory, "{d:.1} a {d:.1}", .{ 100 * result.h_fwd, 100 * result.h_aft }) });
    try summary.append(memory, .{ "δe no cruzeiro, no C_L,max (°)", try text(memory, "{d:.2}, {d:.2}", .{ result.elevator_cruise, result.elevator_max_lift }) });
    try summary.append(memory, .{ "rolagem: p b/2V com o aileron todo", try text(memory, "{d:.3}", .{result.roll_rate}) });
    try summary.append(memory, .{ "rotação: V com profundor todo, V com δe = 0, V de sair do chão (m/s)", try text(memory, "{d:.1}, {d:.1}, {d:.1}", .{ result.rotation_speed, result.rotation_speed_neutral, result.liftoff_speed }) });

    // o diagnóstico (`set_stage` de results.py)
    var checks: std.ArrayList(simulation.Check) = .empty;
    const group = "empenagem e comandos";
    if (built.wings.len > 1) try checks.append(memory, .{ .status = .info, .item = "asas ligadas", .value = try text(memory, "{d} asas da configuração", .{built.wings.len}), .criterion = "—", .why = if (layout == .tailless) "tandem: o ponto neutro é a média dos CA ponderada pela sustentação de cada asa" else "a estática desta etapa é a da asa 1 com a cauda; com mais asas, a margem é a do avião inteiro no núcleo", .fix = "veja Aerodinâmica → Analisar depois de mandar para a Montagem", .group = group });
    if (layout != .tailless) {
        const width = 100 * (result.h_aft - result.h_fwd);
        const wide = width >= 15;
        try checks.append(memory, .{ .status = status(wide, width > 0), .item = "faixa de CG", .value = try text(memory, "{d:.0} % CMA", .{width}), .criterion = "≥ 15 % CMA", .why = if (wide) "" else "pouca folga para pôr bateria e carga", .fix = if (wide) "" else "mais V_H (área ou braço) ou mais profundor", .group = group });
        const inside = result.h_fwd <= result.h_cg and result.h_cg <= result.h_aft;
        try checks.append(memory, .{ .status = status(inside, false), .item = "CG pedido dentro da faixa", .value = try text(memory, "{d:.0} % CMA", .{100 * result.h_cg}), .criterion = try text(memory, "{d:.0} a {d:.0} %", .{ 100 * result.h_fwd, 100 * result.h_aft }), .why = if (inside) "" else "com a margem pedida o profundor não equilibra o C_L,max", .fix = if (inside) "" else "margem menor ou empenagem maior", .group = group });
        const usual = result.volume_h >= 0.3 and result.volume_h <= 0.7;
        try checks.append(memory, .{ .status = status(usual, true), .item = "volume de cauda horizontal", .value = try text(memory, "{d:.2}", .{result.volume_h}), .criterion = "0,3 a 0,7", .why = if (usual) "" else "fora do usual em aeromodelos", .group = group });
        const steady = result.yaw_stability >= 0.05;
        try checks.append(memory, .{ .status = status(steady, true), .item = "estabilidade direcional (cauda)", .value = try text(memory, "C_nβ = {d:.3} /rad", .{result.yaw_stability}), .criterion = "≥ 0,05", .why = if (steady) "" else "a cauda volta pouco o nariz para o vento (a fuselagem tira mais)", .fix = if (steady) "" else "mais V_V", .group = group });
        const holds = result.tail_lift_low <= result.tail_lift_needed and result.tail_lift_needed <= result.tail_lift_high;
        try checks.append(memory, .{ .status = status(holds, false), .item = "EH sem estolar no C_L,max", .value = try text(memory, "C_L da EH = {d:.2}", .{result.tail_lift_needed}), .criterion = try text(memory, "entre {d:.2} e {d:.2} (polar do perfil)", .{ result.tail_lift_low, result.tail_lift_high }), .why = if (holds) "" else "a EH precisaria de mais sustentação (para baixo) do que o perfil dá", .fix = if (holds) "" else "perfil invertido na EH, mais área (V_H) ou CG mais para trás", .group = group });
    } else {
        const trims = @abs(result.elevator_cruise) <= 0.5 * de_max;
        try checks.append(memory, .{ .status = status(trims, false), .item = "elevon equilibra o cruzeiro", .value = try text(memory, "δ = {d:.1}°", .{result.elevator_cruise}), .criterion = try text(memory, "|δ| ≤ {d}°", .{0.5 * de_max}), .why = if (trims) "" else "a asa sozinha tem C_m,ac negativo demais para a margem pedida", .fix = if (trims) "" else "perfil reflexo (c_m ≈ 0), enflechamento com washout ou margem menor", .group = group });
        if (result.fins > 0) {
            const steady = result.yaw_stability >= 0.05;
            try checks.append(memory, .{ .status = status(steady, true), .item = "direcional (derivas na ponta)", .value = try text(memory, "C_nβ = {d:.3} /rad", .{result.yaw_stability}), .criterion = "≥ 0,05", .why = if (steady) "" else "as derivas têm pouco braço até o CG", .fix = if (steady) "" else "derivas mais altas ou mais enflechamento", .group = group });
        } else try checks.append(memory, .{ .status = .atencao, .item = "direcional", .value = "sem deriva", .criterion = "—", .why = "asa voadora precisa de outra fonte de C_nβ", .fix = "derivas nas pontas (campo 'deriva na ponta') ou winglets", .group = group });
    }
    const balances = @abs(result.elevator_max_lift) <= de_max;
    try checks.append(memory, .{ .status = status(balances, false), .item = "profundor equilibra o C_L,max", .value = try text(memory, "δe = {d:.1}°", .{result.elevator_max_lift}), .criterion = try text(memory, "|δe| ≤ {d}°", .{de_max}), .why = if (balances) "" else "não dá para pousar devagar com o CG no alvo", .fix = if (balances) "" else "mais profundor/área de EH ou CG mais para trás", .group = group });
    const finite = std.math.isFinite(result.rotation_speed);
    const rotates = result.rotation_speed <= 0.9 * result.liftoff_speed;
    try checks.append(memory, .{ .status = status(rotates, finite and result.rotation_speed <= result.liftoff_speed), .item = "rotação na decolagem", .value = if (finite) try text(memory, "roda a partir de {d:.1} m/s", .{result.rotation_speed}) else "não roda", .criterion = try text(memory, "≤ 0,9 × V de sair do chão ({d:.1})", .{result.liftoff_speed}), .why = if (rotates) "" else "o profundor só levanta o nariz perto (ou depois) da velocidade de sair do chão: a corrida cresce e a rotação fica brusca", .fix = if (rotates) "" else "EH com perfil invertido (momento cabrador já com δe = 0), mais área de profundor, trem principal mais perto do CG ou CG mais para trás", .group = group, .source = "momentos no trem principal" });
    const rolls = result.roll_rate >= 0.07;
    try checks.append(memory, .{ .status = status(rolls, true), .item = "efetividade do aileron", .value = try text(memory, "p b/2V = {d:.3}", .{result.roll_rate}), .criterion = "≥ 0,07", .why = if (rolls) "" else "rola devagar", .fix = if (rolls) "" else "aileron mais longo ou de corda maior", .group = group });
    if (with_vlm) vlm: {
        const found = vlmStudy(memory, built) catch |err| {
            try checks.append(memory, .{ .status = .atencao, .item = "VLM", .value = @errorName(err), .criterion = "—", .why = "o conjunto não montou no núcleo para o VLM", .group = "VLM" });
            break :vlm;
        };
        if (found.len == 0) break :vlm;
        const panels = try memory.alloc(f64, found.len);
        const lift_slope = try memory.alloc(f64, found.len);
        const moment_slope = try memory.alloc(f64, found.len);
        const neutral = try memory.alloc(f64, found.len);
        const side_force = try memory.alloc(f64, found.len);
        const roll = try memory.alloc(f64, found.len);
        const yaw = try memory.alloc(f64, found.len);
        for (found, 0..) |item, k| {
            panels[k] = @floatFromInt(item.panels);
            lift_slope[k] = item.CLa;
            moment_slope[k] = item.Cma;
            neutral[k] = percentOf(result, item.neutral_x);
            side_force[k] = item.CYb;
            roll[k] = item.Clb;
            yaw[k] = item.Cnb;
        }
        try figures.curve("vlm_slope", .{ .name = "C_Lα", .x = panels, .y = lift_slope, .color = "#1f77b4", .marker = "o", .line = true });
        try figures.curve("vlm_slope", .{ .name = "C_mα (CG no alvo)", .x = panels, .y = moment_slope, .color = "#d62728", .marker = "s", .line = true });
        try figures.curve("vlm_np", .{ .name = "ponto neutro (VLM)", .x = panels, .y = neutral, .color = "#1f77b4", .marker = "o", .line = true });
        try figures.guide("vlm_np", .{ .name = "ponto neutro (clássico)", .value = 100 * result.h_n, .vertical = false, .color = "#d62728", .dashed = true });
        try figures.guide("vlm_np", .{ .name = "CG no alvo", .value = 100 * result.h_cg, .vertical = false, .color = "#000000" });
        try figures.curve("vlm_lateral", .{ .name = "C_Yβ", .x = panels, .y = side_force, .color = "#2ca02c", .marker = "o", .line = true });
        try figures.curve("vlm_lateral", .{ .name = "C_lβ", .x = panels, .y = roll, .color = "#9467bd", .marker = "s", .line = true });
        try figures.curve("vlm_lateral", .{ .name = "C_nβ", .x = panels, .y = yaw, .color = "#ff7f0e", .marker = "d", .line = true });
        const fine = found[found.len - 1];
        const fine_np = percentOf(result, fine.neutral_x);
        try summary.appendSlice(memory, &.{
            .{ "VLM: painéis da malha mais fina", try text(memory, "{d}", .{fine.panels}) },
            .{ "VLM: C_L e C_m no α = 0 do corpo", try text(memory, "{d:.4}, {d:.4}", .{ fine.at.CL, fine.at.Cm }) },
            .{ "VLM: C_L da asa e da EH no α = 0", try text(memory, "{d:.4}, {d:.4}", .{ fine.at.CL_wing, fine.at.CL_htail }) },
            .{ "VLM: C_Lα, C_mα (1/rad)", try text(memory, "{d:.3}, {d:.3}", .{ fine.CLa, fine.Cma }) },
            .{ "VLM: ponto neutro (% CMA), margem estática (% CMA)", try text(memory, "{d:.1}, {d:.1}", .{ fine_np, fine_np - 100 * result.h_cg }) },
            .{ "VLM: C_Yβ, C_lβ, C_nβ (1/rad)", try text(memory, "{d:.4}, {d:.4}, {d:.4}", .{ fine.CYb, fine.Clb, fine.Cnb }) },
            .{ "VLM: k de C_Di = k C_L²", try text(memory, "{d:.4}", .{fine.induced_factor}) },
        });
        // Richardson nas duas malhas mais finas (mesma corda, erro ∝ 1/n na envergadura): o valor da malha infinita
        // v∞ = (n₂ v₂ − n₁ v₁)/(n₂ − n₁) (Roache, "Verification and Validation in Computational Science", cap. 5 — a
        // conferir no PDF)
        var limit_lift = fine.CLa;
        var limit_np = fine_np;
        var limit_moment = fine.Cma;
        if (found.len >= 2 and vlm_grids[found.len - 2].chordwise == vlm_grids[found.len - 1].chordwise) {
            const before = found[found.len - 2];
            const n1: f64 = @floatFromInt(vlm_grids[found.len - 2].spanwise);
            const n2: f64 = @floatFromInt(vlm_grids[found.len - 1].spanwise);
            limit_lift = (n2 * fine.CLa - n1 * before.CLa) / (n2 - n1);
            limit_moment = (n2 * fine.Cma - n1 * before.Cma) / (n2 - n1);
            limit_np = (n2 * fine_np - n1 * percentOf(result, before.neutral_x)) / (n2 - n1);
            const change = 100 * @abs(fine.CLa - limit_lift) / @max(@abs(limit_lift), 1e-9);
            const np_change = @abs(fine_np - limit_np);
            const converged = change <= 2 and np_change <= 1;
            try checks.append(memory, .{ .status = if (converged) .ok else .atencao, .item = "VLM: convergência de malha", .value = try text(memory, "malha mais fina a {d:.2} % do C_Lα e a {d:.2} % CMA do ponto neutro da malha infinita", .{ change, np_change }), .criterion = "≤ 2 % e ≤ 1 % CMA", .why = if (converged) "" else "a malha mais fina ainda muda o resultado: vale o valor da malha infinita (Richardson)", .fix = if (converged) "" else "se o ponto neutro pula de uma malha para outra, alguma superfície está em cima de outra ou da esteira dela (uma EH a mais no plano da asa, por exemplo)", .group = "VLM" });
            try figures.guide("vlm_slope", .{ .name = "C_Lα da malha infinita", .value = limit_lift, .vertical = false, .color = "#1f77b4", .dashed = true });
            try figures.guide("vlm_np", .{ .name = "malha infinita", .value = limit_np, .vertical = false, .color = "#1f77b4", .dashed = true });
            try summary.append(memory, .{ "VLM na malha infinita: C_Lα, C_mα (1/rad), ponto neutro (% CMA)", try text(memory, "{d:.3}, {d:.3}, {d:.1}", .{ limit_lift, limit_moment, limit_np }) });
        }
        const stable = limit_moment < 0 and limit_np > 100 * result.h_cg;
        try checks.append(memory, .{ .status = if (stable) .ok else .falha, .item = "VLM: estável em arfagem no CG do alvo", .value = try text(memory, "C_mα = {d:.3} /rad; margem {d:.1} % CMA", .{ limit_moment, limit_np - 100 * result.h_cg }), .criterion = "C_mα < 0", .why = if (stable) "" else "com o conjunto inteiro no VLM, o ponto neutro fica à frente do CG", .fix = if (stable) "" else "mais V_H ou CG mais à frente", .group = "VLM" });
        try checks.append(memory, .{ .status = .info, .item = "VLM × clássico: ponto neutro", .value = try text(memory, "{d:.1} × {d:.1} % CMA (diferença {d:.1})", .{ limit_np, 100 * result.h_n, limit_np - 100 * result.h_n }), .criterion = "—", .why = "o VLM vê todas as superfícies juntas (downwash e interferência de verdade, sem estol nem fuselagem); o clássico usa dε/dα = 2a/(π AR)", .group = "VLM", .source = "Katz e Plotkin, seção 12.3" });
    }
    try checks.append(memory, .{ .status = .info, .item = "método", .value = "estática clássica (volume de cauda)", .criterion = "—", .why = "sem fuselagem (entra na etapa Motores); dε/dα = 2a/(π AR); a_h de Helmbold", .group = group });

    // a tabela de comandos
    var surface_names: std.ArrayList([]const u8) = .empty;
    try surface_names.append(memory, no_surface);
    for (built.surfaces) |surface| try surface_names.append(memory, surface.name);
    const table_rows = try tableCommands(memory, params);
    for (table_rows) |command| {
        if (command.surface.len == 0) continue;
        var known = false;
        for (surface_names.items) |name| known = known or std.mem.eql(u8, name, command.surface);
        if (!known) try surface_names.append(memory, command.surface);
    }
    var kinds: std.ArrayList([]const u8) = .empty;
    for (control_kinds) |kind| try kinds.append(memory, kind);
    const columns = try memory.dupe(simulation.Column, &.{
        .{ .key = "kind", .label = "tipo", .kind = .choice, .choices = kinds.items, .help = "só o nome (aileron, profundor, elevon...): o que ele faz são os ganhos" },
        .{ .key = "surface", .label = "superfície", .kind = .choice, .choices = surface_names.items, .help = "em qual superfície do conjunto ele fica; sem superfície, ele não entra no avião" },
        .{ .key = "span_start", .label = "início", .help = "fração da semienvergadura (0 = raiz)" },
        .{ .key = "span_end", .label = "fim", .help = "fração da semienvergadura (1 = ponta)" },
        .{ .key = "chord_frac", .label = "corda", .help = "fração da corda" },
        .{ .key = "pitch", .label = "arfagem", .help = "ganho de arfagem: +1 desce o bordo de fuga para picar (atrás do CG); −1 à frente do CG, onde descer cabra" },
        .{ .key = "roll", .label = "rolagem", .help = "ganho de rolagem: os dois lados em sentidos opostos" },
        .{ .key = "yaw", .label = "guinada", .help = "ganho de guinada" },
    });
    const rows = try memory.alloc([]const simulation.Cell, table_rows.len);
    for (table_rows, rows) |command, *cells| {
        const gains = command.control.gains();
        cells.* = try memory.dupe(simulation.Cell, &.{ .{ .text = command.control.kind }, .{ .text = if (command.surface.len == 0) no_surface else command.surface }, .{ .number = command.control.span_start }, .{ .number = command.control.span_end }, .{ .number = command.control.chord_frac }, .{ .number = gains[0] }, .{ .number = gains[1] }, .{ .number = gains[2] } });
    }
    // as superfícies a mais: presas em qualquer superfície que não seja uma delas
    var hosts: std.ArrayList([]const u8) = .empty;
    for (built.surfaces) |surface| if (!std.mem.startsWith(u8, surface.name, "EV extra") and !std.mem.startsWith(u8, surface.name, "EH extra")) try hosts.append(memory, surface.name);
    const extra_rows = try extraRows(memory, params);
    const extra_cells = try memory.alloc([]const simulation.Cell, extra_rows.len);
    for (extra_rows, extra_cells) |extra, *cells| cells.* = try memory.dupe(simulation.Cell, &.{ .{ .text = extra.kind }, .{ .text = extra.host }, .{ .number = extra.station }, .{ .text = extra.sides }, .{ .number = extra.size }, .{ .number = extra.chord }, .{ .number = extra.taper } });
    const extra_columns = try memory.dupe(simulation.Column, &.{
        .{ .key = "kind", .label = "tipo", .kind = .choice, .choices = &extra_kinds, .help = "EV: vertical; EH: horizontal inteira (as duas metades), centrada" },
        .{ .key = "host", .label = "presa em", .kind = .choice, .choices = hosts.items, .help = "a superfície onde ela fica" },
        .{ .key = "station", .label = "posição", .help = "fração da semienvergadura de onde está presa (0 = raiz, 1 = ponta); a EH usa a raiz" },
        .{ .key = "sides", .label = "lados", .kind = .choice, .choices = &extra_sides, .help = "os dois lados: duas EV, uma de cada lado" },
        .{ .key = "size", .label = "altura/env. (m)", .help = "a altura da EV ou a envergadura da EH" },
        .{ .key = "chord", .label = "corda (m)", .help = "a corda da raiz" },
        .{ .key = "taper", .label = "afilamento" },
    });

    const grids = try memory.dupe(simulation.Grid, &.{ .{ .name = "extras", .title = "Superfícies a mais", .columns = extra_columns, .rows = extra_cells, .note = "uma EV na ponta da asa no lugar do winglet, no meio dela, ou duas EV (ou EH) além da cauda. Elas entram no avião e na tabela de comandos; a conta do volume de cauda acima é a da cauda da regra.", .buttons = &.{ .{ .operation = "add", .label = "+ superfície", .help = "uma EV em cada ponta da asa, para editar" }, .{ .operation = "delete", .label = "− superfície", .help = "tira a selecionada" } } }, .{ .name = "comandos", .title = "Comandos", .columns = columns, .rows = rows, .note = "vazia: vale a regra da etapa ('da regra' mostra qual é). Com linhas, a tabela manda em todas as superfícies.", .help = "um comando por linha, em qualquer superfície do conjunto: o trecho da envergadura, a fração da corda e quanto ele responde a cada eixo (arfagem, rolagem, guinada). Um profundor à frente do CG leva arfagem −1.", .buttons = &.{ .{ .operation = "rule", .label = "da regra", .help = "enche a tabela com os comandos que a regra da etapa põe (aileron ou elevon na asa, profundor na EH, leme na EV), para editar" }, .{ .operation = "add", .label = "+ comando", .help = "um comando novo: escolha o tipo e depois a superfície" }, .{ .operation = "delete", .label = "− comando", .help = "tira o selecionado" }, .{ .operation = "clear", .label = "limpar", .help = "esvazia a tabela: volta a valer a regra da etapa" } } } });

    var out = base;
    out.grids = grids;
    out.summary = summary.items;
    out.checks = checks.items;
    out.figures = figures;
    out.view = try viewOf(memory, built);
    if (out.view) |*scene| if (context.focus_command) |focus| if (focus < table_rows.len) {
        scene.focus = try commandFocus(memory, built, table_rows[focus]);
    };
    return out;
}

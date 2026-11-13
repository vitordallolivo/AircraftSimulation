//! A etapa Perfis em Zig (`AirfoilStage` de `stages.py`): a lista de perfis candidatos do projeto (NACA, .dat ou só
//! parâmetros) e a polar 2D de cada um no Re do cruzeiro, pelo modelo do núcleo (`core.section.modelPolar`).
//! "Usar na asa" leva o selecionado para o rascunho da asa. A polar do NeuralFoil e a de arquivo do XFLR5 seguem
//! no Python.
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const stages = @import("stages.zig");
const library_stage = @import("stage_library.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Airfoil = aircraft_model.aircraft.Airfoil;
const air_viscosity = 1.81e-5; // μ do ar (`MU_AIR` de spec.py)

const plots = [_]simulation.Plot{
    .{ .key = "cl", .title = "Sustentação", .xlabel = "$\\alpha$ (°)", .ylabel = "$c_l$" },
    .{ .key = "polar", .title = "Polar de arrasto", .xlabel = "$c_d$", .ylabel = "$c_l$" },
    .{ .key = "ld", .title = "Eficiência", .xlabel = "$\\alpha$ (°)", .ylabel = "$c_l/c_d$" },
    .{ .key = "cm", .title = "Momento", .xlabel = "$\\alpha$ (°)", .ylabel = "$c_m$" },
    .{ .key = "shape", .title = "Contorno", .xlabel = "$x/c$", .ylabel = "$y/c$" },
};
const palette = [_][]const u8{ "#1f77b4", "#eb6834", "#1baf7a", "#d62728", "#4a3aa7", "#8c564b", "#e87ba4", "#17becf" };

const actions = [_]simulation.StageAction{
    .{ .key = "naca", .label = "+ NACA…", .arg = "text", .help = "código de 4 dígitos", .default = "4412" },
    .{ .key = "dat", .label = "+ .dat…", .arg = "file", .help = "contorno Selig ou Lednicer" },
    .{ .key = "param", .label = "+ só parâmetros", .help = "sem contorno: a1, α_L0, c_l,max, c_d0, c_m" },
};

const sources = [_][]const u8{"modelo"};

/// os campos do perfil no formulário (`airfoil.*`)
const airfoil_fields = [_]registry.Field{
    .{ .key = "name", .label = "nome", .default = .{ .text = "" } },
    .{ .key = "cl_alpha", .label = "a1 (inclinação 2D)", .unit = "1/rad", .default = .{ .number = 5.9 }, .minimum = 1, .maximum = 8 },
    .{ .key = "alpha0", .label = "α de sustentação nula", .unit = "°", .help = "vazio no projeto: pela linha média (perfil fino)", .default = .{ .number = 0 }, .minimum = -20, .maximum = 10 },
    .{ .key = "cl_max", .label = "c_l máx.", .default = .{ .number = 1.4 }, .minimum = 0.3, .maximum = 3.5 },
    .{ .key = "cd0", .label = "c_d0", .default = .{ .number = 0.01 }, .minimum = 0.003, .maximum = 0.1 },
    .{ .key = "cm_ac", .label = "c_m (centro aerodinâmico)", .help = "vazio no projeto: pela linha média (perfil fino)", .default = .{ .number = 0 }, .minimum = -0.5, .maximum = 0.2 },
    .{ .key = "inverted", .label = "invertido", .help = "montado de cabeça para baixo (EH)", .default = .{ .toggle = false } },
};

/// a lista de perfis do projeto (o padrão do Python, NACA 2412 e 4412, se ainda não existe)
pub fn entries(project: *store.Project) !*std.json.Array {
    const list = project.list("airfoils");
    if (list.items.len == 0) {
        for ([_][]const u8{ "NACA 2412", "NACA 4412" }) |name| try list.append(try newEntry(project.memory(), name, &.{}, null));
    }
    return list;
}

/// um candidato novo: o perfil (só nome e contorno; o resto com os padrões) e a fonte da polar
fn newEntry(memory: std.mem.Allocator, name: []const u8, coords: []const [2]f64, numbers: ?[3]f64) !Value {
    var airfoil = ObjectMap.empty;
    try airfoil.put(memory, "name", .{ .string = try memory.dupe(u8, name) });
    try airfoil.put(memory, "path", .{ .string = "" });
    try airfoil.put(memory, "cl_alpha", .{ .float = 5.9 });
    if (numbers) |given| {
        try airfoil.put(memory, "alpha0", .{ .float = given[0] });
        try airfoil.put(memory, "cl_max", .{ .float = given[2] });
        try airfoil.put(memory, "cm_ac", .{ .float = given[1] });
    } else {
        try airfoil.put(memory, "alpha0", .null);
        try airfoil.put(memory, "cl_max", .{ .float = 1.4 });
        try airfoil.put(memory, "cm_ac", .null);
    }
    try airfoil.put(memory, "cd0", .{ .float = 0.01 });
    var points = std.json.Array.init(memory);
    for (coords) |point| {
        var pair = std.json.Array.init(memory);
        try pair.append(.{ .float = point[0] });
        try pair.append(.{ .float = point[1] });
        try points.append(.{ .array = pair });
    }
    try airfoil.put(memory, "coords", .{ .array = points });
    try airfoil.put(memory, "inverted", .{ .bool = false });
    var entry = ObjectMap.empty;
    try entry.put(memory, "airfoil", .{ .object = airfoil });
    try entry.put(memory, "source", .{ .string = "modelo" });
    try entry.put(memory, "polar_file", .{ .string = "" });
    return .{ .object = entry };
}

/// os perfis da biblioteca: os .dat de `data/airfoils` (fora os NACA de 4 dígitos) e os que o usuário pôs na
/// biblioteca do programa (`biblioteca/perfis`), lidos uma vez
pub fn library(context: *stages.Context) []const Value {
    if (context.library) |known| return known;
    const memory = context.project.memory();
    var out: std.ArrayList(Value) = .empty;
    for ([_][]const u8{ "data/airfoils", "../data/airfoils" }) |folder| {
        const files = library_stage.datFiles(memory, context.io, folder) catch continue;
        if (files.len == 0) continue;
        appendDats(context, memory, files, &out);
        break;
    }
    if (library_stage.folder(memory, .airfoils)) |folder| {
        appendDats(context, memory, library_stage.datFiles(memory, context.io, folder) catch &.{}, &out);
    } else |_| {}
    context.library = out.items;
    return out.items;
}

/// os perfis destes .dat na lista (um nome que já está fica de fora)
fn appendDats(context: *stages.Context, memory: std.mem.Allocator, files: []const []const u8, out: *std.ArrayList(Value)) void {
    for (files) |path| {
        const read = readDat(memory, context.io, path) catch continue;
        if (std.mem.eql(u8, kindOf(.{ .name = read.name }, ""), "naca")) continue;
        const known = for (out.items) |entry| {
            if (std.mem.eql(u8, entryName(entry), read.name)) break true;
        } else false;
        if (known) continue;
        var entry = newEntry(memory, read.name, read.points, null) catch continue;
        if (airfoilObject(&entry)) |object| object.put(memory, "path", .{ .string = path }) catch {};
        out.append(memory, entry) catch continue;
    }
}

/// guarda uma cópia do .dat na biblioteca do programa, para ele aparecer em todos os projetos
fn keepInLibrary(context: *stages.Context, memory: std.mem.Allocator, path: []const u8, name: []const u8) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(context.io, path, memory, .limited(1 << 22)) catch return false;
    const folder = library_stage.folder(memory, .airfoils) catch return false;
    std.Io.Dir.cwd().createDirPath(context.io, folder) catch return false;
    const file = std.fs.path.join(memory, &.{ folder, library_stage.fileName(memory, name) catch return false }) catch return false;
    std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = file, .data = bytes }) catch return false;
    context.library = null;
    return true;
}

/// os nomes dos perfis: os da etapa Perfis primeiro, depois os da biblioteca (`airfoil_names`)
pub fn names(context: *stages.Context, memory: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ((try entries(&context.project)).items) |entry| try appendNew(memory, &out, entryName(entry));
    for (library(context)) |entry| try appendNew(memory, &out, entryName(entry));
    return out.items;
}

fn appendNew(memory: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |known| if (std.mem.eql(u8, known, name)) return;
    try list.append(memory, name);
}

/// o nome do perfil de um candidato
pub fn entryName(entry: Value) []const u8 {
    if (entry != .object) return "";
    const airfoil = entry.object.get("airfoil") orelse return "";
    return if (airfoil == .object) store.text(&airfoil.object, "name", "") else "";
}

/// o candidato com este nome: o da etapa Perfis, senão o da biblioteca (`DesignProject.airfoil`)
pub fn lookup(context: *stages.Context, name: []const u8) ?Value {
    const list = entries(&context.project) catch return null;
    for (list.items) |entry| if (std.mem.eql(u8, entryName(entry), name)) return entry;
    for (library(context)) |entry| if (std.mem.eql(u8, entryName(entry), name)) return entry;
    return null;
}

/// o perfil de uma seção da asa para a linha sustentadora: os números do perfil ajustados na polar do modelo
pub fn sectionOf(memory: std.mem.Allocator, entry: ?Value) !core.wing_line.SectionAirfoil {
    const airfoil = if (entry) |known| try airfoilOf(memory, known) else Airfoil{};
    const numbers = aircraft_model.params.props2d(airfoil) catch [5]f64{ airfoil.cl_alpha, 0, airfoil.cl_max, airfoil.cd0, 0 };
    const symmetric = @abs(numbers[1]) < 1e-9 and @abs(numbers[4]) < 1e-9;
    return core.wing_line.modelSection(.{ .cl_alpha = numbers[0], .alpha0 = numbers[1], .cl_max = numbers[2], .cd0 = numbers[3], .cm_ac = numbers[4] }, symmetric);
}

/// o perfil de um candidato, como o modelo do avião lê
pub fn airfoilOf(memory: std.mem.Allocator, entry: Value) !Airfoil {
    if (entry != .object) return .{};
    const value = entry.object.get("airfoil") orelse return .{};
    return std.json.parseFromValueLeaky(Airfoil, memory, value, .{ .ignore_unknown_fields = true });
}

fn airfoilObject(entry: *Value) ?*ObjectMap {
    if (entry.* != .object) return null;
    return store.child(&entry.object, "airfoil");
}

/// de onde vem o contorno (`kind` de airfoils.py): dat | contorno | naca | parâmetros
fn kindOf(airfoil: Airfoil, path: []const u8) []const u8 {
    if (path.len > 0) return "dat";
    if (airfoil.coords.len > 0) return "contorno";
    var digits: usize = 0;
    for (airfoil.name) |char| digits += @intFromBool(std.ascii.isDigit(char));
    if (std.ascii.indexOfIgnoreCase(airfoil.name, "naca") != null and digits == 4) return "naca";
    return "parâmetros";
}

/// a corda média aerodinâmica do rascunho da asa (trecho retangular + trapézio)
fn draftMac(project: *store.Project) f64 {
    const draft = project.section("wing_draft");
    const span = store.number(draft, "span", 2.4);
    const area = store.number(draft, "area", 0.85);
    const taper = store.number(draft, "taper", 0.6);
    const rectangular = store.number(draft, "rect_frac", 0.4);
    const root = area / (span * (rectangular + (1 - rectangular) * (1 + taper) / 2));
    const half_integral = root * root * (span / 2) * (rectangular + (1 - rectangular) * (1 + taper + taper * taper) / 3);
    return 2 * half_integral / area;
}

/// o Re do cruzeiro na corda média da asa (`AirfoilStage.reynolds`)
pub fn reynolds(project: *store.Project) f64 {
    const speed = registry.fieldNumber(project.section("requirements"), &registry.requirement_fields, "V_cruise");
    return registry.rho(project) * speed * draftMac(project) / air_viscosity;
}

/// lê um .dat (Selig ou Lednicer, `read_dat`): o nome e os pontos
fn readDat(memory: std.mem.Allocator, io: std.Io, path: []const u8) !struct { name: []const u8, points: [][2]f64 } {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 22));
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    var name: []const u8 = "";
    var points: std.ArrayList([2]f64) = .empty;
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (first) {
            first = false;
            name = line;
            continue;
        }
        var parts = std.mem.tokenizeAny(u8, line, " \t,");
        const a = std.fmt.parseFloat(f64, parts.next() orelse continue) catch continue;
        const b = std.fmt.parseFloat(f64, parts.next() orelse continue) catch continue;
        try points.append(memory, .{ a, b });
    }
    var out = points.items;
    if (out.len > 0 and out[0][0] > 1.5) { // Lednicer: a primeira linha traz as contagens
        const upper: usize = @intFromFloat(out[0][0]);
        const lower: usize = @intFromFloat(out[0][1]);
        if (1 + upper + lower > out.len) return error.InvalidAirfoil;
        const merged = try memory.alloc([2]f64, upper + lower - 1);
        for (0..upper) |i| merged[i] = out[upper - i];
        for (1..lower) |i| merged[upper + i - 1] = out[1 + upper + i];
        out = merged;
    }
    if (name.len == 0) name = std.fs.path.stem(path);
    return .{ .name = name, .points = out };
}

fn addEntry(context: *stages.Context, entry: Value, name: []const u8) ![]const u8 {
    const list = try entries(&context.project);
    for (list.items) |existing| {
        const airfoil = existing.object.get("airfoil") orelse continue;
        if (airfoil == .object and std.mem.eql(u8, store.text(&airfoil.object, "name", ""), name)) return "já está na lista.";
    }
    try list.append(entry);
    context.selected_airfoil = list.items.len - 1;
    _ = context.save();
    return "entrou";
}

/// muda o projeto conforme o pedido
pub fn apply(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const project = &context.project;
    const list = try entries(project);
    if (context.selected_airfoil >= list.items.len) context.selected_airfoil = if (list.items.len > 0) list.items.len - 1 else 0;
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        if (list.items.len == 0) return "";
        const entry = &list.items[context.selected_airfoil];
        var changed: usize = 0;
        if (airfoilObject(entry)) |airfoil| changed += try stages.applyFields(project, airfoil, &airfoil_fields, "airfoil.", values);
        if (changed > 0) _ = context.save();
        return "";
    }
    if (std.mem.eql(u8, request.do, "load")) {
        if (stages.within(request.index, list.items.len)) |index| context.selected_airfoil = index;
        return "";
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        if (stages.within(request.index, list.items.len)) |index| {
            _ = list.orderedRemove(index);
            _ = context.save();
        }
        return "";
    }
    if (std.mem.eql(u8, request.do, "keep")) {
        if (list.items.len == 0) return "";
        const airfoil = try airfoilOf(memory, list.items[context.selected_airfoil]);
        try store.setText(project, project.section("wing_draft"), "airfoil", airfoil.name);
        _ = context.save();
        return std.fmt.allocPrint(memory, "guardado: {s}", .{airfoil.name});
    }
    if (std.mem.eql(u8, request.do, "act")) {
        if (std.mem.eql(u8, request.key, "naca")) {
            var digits: [4]u8 = undefined;
            var count: usize = 0;
            for (request.arg) |char| if (std.ascii.isDigit(char)) {
                if (count < 4) digits[count] = char;
                count += 1;
            };
            if (count != 4) return "o código NACA tem 4 dígitos";
            const name = try std.fmt.allocPrint(project.memory(), "NACA {s}", .{&digits});
            const said = try addEntry(context, try newEntry(project.memory(), name, &.{}, null), name);
            return std.fmt.allocPrint(memory, "{s}: {s}", .{ said, name });
        }
        if (std.mem.eql(u8, request.key, "dat")) {
            const read = readDat(project.memory(), context.io, request.arg) catch return "não deu para ler o .dat";
            const said = try addEntry(context, try newEntry(project.memory(), read.name, read.points, null), read.name);
            const kept = keepInLibrary(context, memory, request.arg, read.name);
            return std.fmt.allocPrint(memory, "{s}: {s}{s}", .{ said, read.name, if (kept) " (e na biblioteca do programa)" else "" });
        }
        if (std.mem.eql(u8, request.key, "param")) {
            const name = try std.fmt.allocPrint(project.memory(), "perfil {d}", .{list.items.len + 1});
            const said = try addEntry(context, try newEntry(project.memory(), name, &.{}, .{ -3.0, -0.08, 1.5 }), name);
            return std.fmt.allocPrint(memory, "{s}: {s}", .{ said, name });
        }
        return error.UnknownAction;
    }
    return "";
}

/// a página: o perfil selecionado no formulário, a lista e as polares de todos
pub fn page(context: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const project = &context.project;
    const list = try entries(project);
    if (context.selected_airfoil >= list.items.len) context.selected_airfoil = if (list.items.len > 0) list.items.len - 1 else 0;

    var params: std.ArrayList(simulation.Param) = .empty;
    if (list.items.len > 0) {
        const entry = &list.items[context.selected_airfoil];
        const source = store.text(&entry.object, "source", "modelo");
        try params.append(memory, .{ .key = "source", .label = "polar por", .kind = .choice, .default = .{ .text = source }, .choices = if (std.mem.eql(u8, source, "modelo")) &sources else &.{ sources[0], source }, .help = "modelo: rápido (c_d constante); o NeuralFoil e a polar de arquivo seguem pelo Python" });
        if (airfoilObject(entry)) |object| {
            const airfoil = try airfoilOf(memory, entry.*);
            const thin = aircraft_model.params.props2d(airfoil) catch [5]f64{ airfoil.cl_alpha, 0, airfoil.cl_max, airfoil.cd0, 0 };
            for (airfoil_fields) |field| {
                var param = try stages.fieldParam(object, field, "airfoil.", "perfil", memory);
                if (std.mem.eql(u8, field.key, "alpha0") and airfoil.alpha0 == null) param.default = .{ .number = thin[1] };
                if (std.mem.eql(u8, field.key, "cm_ac") and airfoil.cm_ac == null) param.default = .{ .number = thin[4] };
                try params.append(memory, param);
            }
        }
    }

    var kept: std.ArrayList([]const u8) = .empty;
    for (list.items) |entry| {
        const airfoil = try airfoilOf(memory, entry);
        const path = if (entry.object.get("airfoil")) |object| store.text(&object.object, "path", "") else "";
        try kept.append(memory, try std.fmt.allocPrint(memory, "{s}   ({s}, polar: {s})", .{ airfoil.name, kindOf(airfoil, path), store.text(&entry.object, "source", "modelo") }));
    }

    // as polares no Re do cruzeiro
    const re = reynolds(project);
    var summary: std.ArrayList([2][]const u8) = .empty;
    var checks: std.ArrayList(simulation.Check) = .empty;
    try summary.append(memory, .{ "Re (cruzeiro, corda de referência)", try std.fmt.allocPrint(memory, "{d:.0}", .{re}) });
    const figures = try simulation.Figures.init(memory, &plots);
    var alphas: [73]f64 = undefined;
    for (&alphas, 0..) |*alpha, i| alpha.* = -16.0 + 0.5 * @as(f64, @floatFromInt(i));
    for (list.items, 0..) |entry, k| {
        const airfoil = try airfoilOf(memory, entry);
        const color = palette[k % palette.len];
        const numbers = aircraft_model.params.props2d(airfoil) catch {
            try checks.append(memory, .{ .status = .falha, .item = try std.fmt.allocPrint(memory, "{s}: polar", .{airfoil.name}), .value = "contorno inválido", .group = "perfis" });
            continue;
        };
        var polar: core.section.Polar = .{};
        core.section.modelPolar(.{ .cl_alpha = numbers[0], .alpha0 = numbers[1], .cl_max = numbers[2], .cd0 = numbers[3], .cm_ac = numbers[4] }, &alphas, &polar);
        const count = polar.count;
        const ratio = try memory.alloc(f64, count);
        var best_ratio: f64 = -std.math.inf(f64);
        var best_index: usize = 0;
        var peak_index: usize = 0;
        var least_drag: f64 = std.math.inf(f64);
        for (0..count) |i| {
            ratio[i] = if (polar.cd[i] > 0) polar.cl[i] / polar.cd[i] else std.math.nan(f64);
            if (ratio[i] > best_ratio) {
                best_ratio = ratio[i];
                best_index = i;
            }
            if (polar.cl[i] > polar.cl[peak_index]) peak_index = i;
            least_drag = @min(least_drag, polar.cd[i]);
        }
        const name = airfoil.name;
        try figures.curve("cl", .{ .name = name, .x = try memory.dupe(f64, polar.alpha[0..count]), .y = try memory.dupe(f64, polar.cl[0..count]), .color = color });
        try figures.curve("polar", .{ .name = name, .x = try memory.dupe(f64, polar.cd[0..count]), .y = try memory.dupe(f64, polar.cl[0..count]), .color = color });
        try figures.curve("ld", .{ .name = name, .x = try memory.dupe(f64, polar.alpha[0..count]), .y = ratio, .color = color });
        try figures.curve("cm", .{ .name = name, .x = try memory.dupe(f64, polar.alpha[0..count]), .y = try memory.dupe(f64, polar.cm[0..count]), .color = color });
        if (airfoil.coords.len > 0 or std.mem.eql(u8, kindOf(airfoil, ""), "naca")) {
            var profile: aircraft_model.airfoil.Profile = .{};
            if (aircraft_model.airfoil.full(airfoil.name, airfoil.coords, &profile)) {
                if (airfoil.inverted) aircraft_model.airfoil.invert(&profile);
                const points = profile.slice();
                const xs = try memory.alloc(f64, points.len);
                const ys = try memory.alloc(f64, points.len);
                for (points, xs, ys) |point, *x, *y| {
                    x.* = point[0];
                    y.* = point[1];
                }
                try figures.curve("shape", .{ .name = name, .x = xs, .y = ys, .color = color });
            } else |_| {}
        }
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "[{s}] polar por", .{name}), "modelo" });
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "[{s}] c_l,max; α de estol (°)", .{name}), try std.fmt.allocPrint(memory, "{d:.3}, {d:.1}", .{ polar.cl[peak_index], polar.alpha[peak_index] }) });
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "[{s}] (c_l/c_d) máx.; c_l nele", .{name}), try std.fmt.allocPrint(memory, "{d:.1}, {d:.3}", .{ best_ratio, polar.cl[best_index] }) });
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "[{s}] a1 (1/rad); α_L0 (°); c_m", .{name}), try std.fmt.allocPrint(memory, "{d:.3}, {d:.2}, {d:.4}", .{ numbers[0], numbers[1], numbers[4] }) });
        try summary.append(memory, .{ try std.fmt.allocPrint(memory, "[{s}] c_d mín.", .{name}), try std.fmt.allocPrint(memory, "{d:.4}", .{least_drag}) });
        try checks.append(memory, .{ .status = .info, .item = try std.fmt.allocPrint(memory, "{s}: c_d constante", .{name}), .value = "polar 'modelo'", .criterion = "—", .why = "o modelo do simulador não tem balde de arrasto: c_l/c_d não serve para comparar perfis", .fix = "use neuralfoil (se tiver contorno) ou importe a polar do XFLR5", .group = "perfis" });
    }
    if (re < 1e5) try checks.append(memory, .{ .status = .atencao, .item = "Reynolds baixo", .value = try std.fmt.allocPrint(memory, "{d:.0}", .{re}), .criterion = "≥ 100 000", .why = "abaixo de ~10⁵ as bolhas de separação mudam muito a polar; o modelo e a rede erram mais", .fix = "polar experimental ou XFLR5 com N_crit adequado", .group = "perfis" });

    return .{
        .title = "Perfil",
        .help = "Perfis candidatos e a polar 2D de cada um no Re do cruzeiro. O perfil pode vir de um código NACA, de um .dat ou só de parâmetros (sem contorno); um .dat trazido aqui também fica na biblioteca do programa e aparece nos outros projetos. 'Usar na asa' leva o perfil selecionado para a etapa Asa.",
        .keep_label = "Usar na asa →",
        .kept_title = "Candidatos",
        .params = params.items,
        .kept = kept.items,
        .actions = &actions,
        .summary = summary.items,
        .checks = checks.items,
        .figures = figures,
        .message = try std.fmt.allocPrint(memory, "Re = {d:.0} (cruzeiro, corda média da asa)", .{re}),
    };
}

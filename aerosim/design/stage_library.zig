//! A biblioteca do programa: os motores e as hélices que o usuário acrescenta, além dos que vêm com ele, e que
//! servem a todos os projetos (o par do "Importar catálogo" da GUI em Python). Cada item é um arquivo de texto
//! na pasta `biblioteca` dos projetos (`<pasta dos projetos>/biblioteca/motores` e `.../helices`); ao abrir a tela
//! e a cada mudança a pasta é lida de novo e os itens entram no catálogo (`catalog.setUserItems`), então as etapas,
//! as variáveis do projeto e o Mini-MDO os veem pelo nome. Os perfis .dat ficam em `.../perfis` (etapa Perfis).
//!
//!     biblioteca_motores   Biblioteca → Motores   o formulário de um motor novo e a tabela de todos
//!     biblioteca_helices   Biblioteca → Hélices   "+ .dat…" no formato padrão e as curvas C_T, C_P e η
const std = @import("std");
const simulation = @import("simulation");
const catalog = @import("catalog");
const stages = @import("stages.zig");

/// as subpastas da biblioteca
pub const Kind = enum {
    motors,
    propellers,
    airfoils,

    fn folderName(kind: Kind) []const u8 {
        return switch (kind) {
            .motors => "motores",
            .propellers => "helices",
            .airfoils => "perfis",
        };
    }
};

/// a pasta de um tipo de item da biblioteca
pub fn folder(memory: std.mem.Allocator, kind: Kind) ![]const u8 {
    return std.fs.path.join(memory, &.{ try stages.projectsRoot(memory), "biblioteca", kind.folderName() });
}

/// o nome de arquivo de um item (só letras, números, espaço, ponto, hífen e sublinhado)
pub fn fileName(memory: std.mem.Allocator, name: []const u8) ![]const u8 {
    const safe = try memory.dupe(u8, name);
    for (safe) |*char| if (!(std.ascii.isAlphanumeric(char.*) or char.* == ' ' or char.* == '-' or char.* == '_' or char.* == '.' or char.* >= 0x80)) {
        char.* = '_';
    };
    return std.fmt.allocPrint(memory, "{s}.dat", .{safe});
}

/// os arquivos .dat de uma pasta, em ordem de nome (caminhos inteiros)
pub fn datFiles(memory: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var walker = dir.iterate();
    while (walker.next(io) catch null) |item| {
        if (item.kind != .file or !std.ascii.endsWithIgnoreCase(item.name, ".dat")) continue;
        try out.append(memory, try std.fs.path.join(memory, &.{ path, item.name }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.items;
}

/// onde mora cada item do usuário (para apagar) e os arquivos que não deram para ler
const Loaded = struct { motor_files: []const []const u8 = &.{}, propeller_files: []const []const u8 = &.{}, problems: []const []const u8 = &.{} };
var loaded: Loaded = .{};

/// lê a biblioteca da pasta e troca os itens do catálogo. A memória de uma leitura nunca é liberada: uma análise
/// numa thread pode estar usando a lista anterior (a biblioteca muda poucas vezes)
pub fn reload(io: std.Io) void {
    const arena = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch return;
    arena.* = .init(std.heap.page_allocator);
    const memory = arena.allocator();
    read(memory, io) catch {};
}

fn read(memory: std.mem.Allocator, io: std.Io) !void {
    var motors: std.ArrayList(catalog.Motor) = .empty;
    var motor_files: std.ArrayList([]const u8) = .empty;
    var propellers: std.ArrayList(catalog.Propeller) = .empty;
    var propeller_files: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    for (try datFiles(memory, io, try folder(memory, .motors))) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 20)) catch continue;
        const motor = catalog.parseMotor(memory, text, std.fs.path.stem(path)) catch |err| {
            try problems.append(memory, try std.fmt.allocPrint(memory, "{s}: {s}", .{ std.fs.path.basename(path), problemText(err) }));
            continue;
        };
        if (catalog.find(catalog.Motor, &catalog.motors, motor.name) != null) continue;
        try motors.append(memory, motor);
        try motor_files.append(memory, path);
    }
    for (try datFiles(memory, io, try folder(memory, .propellers))) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 20)) catch continue;
        const propeller = catalog.parsePropeller(memory, text, std.fs.path.stem(path)) catch |err| {
            try problems.append(memory, try std.fmt.allocPrint(memory, "{s}: {s}", .{ std.fs.path.basename(path), problemText(err) }));
            continue;
        };
        if (catalog.find(catalog.Propeller, &catalog.propellers, propeller.name) != null) continue;
        try propellers.append(memory, propeller);
        try propeller_files.append(memory, path);
    }
    const items = try memory.create(catalog.UserItems);
    items.* = .{ .motors = motors.items, .propellers = propellers.items };
    catalog.setUserItems(items);
    loaded = .{ .motor_files = motor_files.items, .propeller_files = propeller_files.items, .problems = problems.items };
}

/// o motivo de um arquivo da biblioteca não entrar, em português
fn problemText(err: anyerror) []const u8 {
    return switch (err) {
        error.IncompleteMotor => "faltam Kv, Rm, Imax ou massa",
        error.MissingDiameter => "falta o diâmetro (\"# diametro: 0.30\" em m, ou \"12x6\" no nome)",
        error.ShortTable => "a tabela J, C_T, C_P precisa de duas linhas ou mais",
        error.UnsortedTable => "o J da tabela tem que crescer",
        else => @errorName(err),
    };
}

fn writeText(io: std.Io, memory: std.mem.Allocator, kind: Kind, name: []const u8, data: []const u8) ![]const u8 {
    const path = try folder(memory, kind);
    try std.Io.Dir.cwd().createDirPath(io, path);
    const file = try std.fs.path.join(memory, &.{ path, try fileName(memory, name) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = data });
    return file;
}

// ------------------------------------------------------------------ Motores
const motor_actions = [_]simulation.StageAction{
    .{ .key = "dat", .label = "+ .dat…", .arg = "file", .help = "um arquivo de motor (linhas \"chave: valor\": nome, Kv, Rm, Imax, massa; B, tauc e Jm opcionais)" },
};

/// o motor do formulário (o selecionado, ou o que se está escrevendo)
var motor_draft: catalog.Motor = catalog.motors[0];
var motor_name_buffer: [96]u8 = undefined;
var selected_motor: usize = 0;

fn setDraftName(name: []const u8) void {
    const length = @min(name.len, motor_name_buffer.len);
    @memcpy(motor_name_buffer[0..length], name[0..length]);
    motor_draft.name = motor_name_buffer[0..length];
}

fn allMotors(memory: std.mem.Allocator) ![]const catalog.Motor {
    var out: std.ArrayList(catalog.Motor) = .empty;
    try out.appendSlice(memory, &catalog.motors);
    try out.appendSlice(memory, catalog.userItems().motors);
    return out.items;
}

fn numberOf(values: *const std.json.ObjectMap, key: []const u8, current: f64) f64 {
    const value = values.get(key) orelse return current;
    return switch (value) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => current,
    };
}

/// muda a biblioteca de motores conforme o pedido
pub fn applyMotors(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const motors = try allMotors(memory);
    if (std.mem.eql(u8, request.do, "load")) {
        if (stages.within(request.index, motors.len)) |index| {
            selected_motor = index;
            motor_draft = motors[index];
            setDraftName(motors[index].name);
        }
        return "";
    }
    if (std.mem.eql(u8, request.do, "set")) {
        const values = request.values orelse return "";
        if (values.get("name")) |name| if (name == .string) setDraftName(name.string);
        motor_draft.Kv = numberOf(values, "Kv", motor_draft.Kv);
        motor_draft.Rm = numberOf(values, "Rm", motor_draft.Rm);
        motor_draft.Imax = numberOf(values, "Imax", motor_draft.Imax);
        motor_draft.mass = numberOf(values, "mass", motor_draft.mass);
        motor_draft.B = numberOf(values, "B", motor_draft.B);
        motor_draft.tauc = numberOf(values, "tauc", motor_draft.tauc);
        motor_draft.Jm = numberOf(values, "Jm", motor_draft.Jm);
        return "";
    }
    if (std.mem.eql(u8, request.do, "keep")) {
        const name = std.mem.trim(u8, motor_draft.name, " ");
        if (name.len == 0) return "dê um nome ao motor";
        if (catalog.find(catalog.Motor, &catalog.motors, name) != null) return "esse nome é de um motor que vem com o programa: mude o nome para guardar o seu";
        var motor = motor_draft;
        motor.name = name;
        if (std.mem.eql(u8, motor.source, "") or catalog.find(catalog.Motor, &catalog.motors, motor_draft.name) != null) motor.source = "biblioteca do usuário";
        var text: std.Io.Writer.Allocating = .init(memory);
        try catalog.writeMotor(&text.writer, motor);
        _ = writeText(context.io, memory, .motors, name, text.written()) catch return "não deu para gravar na pasta da biblioteca";
        reload(context.io);
        selected_motor = catalog.motors.len + catalog.userItems().motors.len - 1;
        for (catalog.userItems().motors, 0..) |item, k| if (std.mem.eql(u8, item.name, name)) {
            selected_motor = catalog.motors.len + k;
        };
        return std.fmt.allocPrint(memory, "guardado na biblioteca: {s}", .{name});
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        const index = stages.within(request.index, motors.len) orelse return "";
        if (index < catalog.motors.len) return "esse motor vem com o programa: não sai da lista";
        const file = loaded.motor_files[index - catalog.motors.len];
        std.Io.Dir.cwd().deleteFile(context.io, file) catch return "não deu para apagar o arquivo";
        reload(context.io);
        selected_motor = 0;
        return std.fmt.allocPrint(memory, "saiu da biblioteca: {s}", .{motors[index].name});
    }
    if (std.mem.eql(u8, request.do, "act") and std.mem.eql(u8, request.key, "dat")) {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, request.arg, memory, .limited(1 << 20)) catch return "não deu para ler o arquivo";
        const motor = catalog.parseMotor(memory, text, std.fs.path.stem(request.arg)) catch |err| return problemText(err);
        if (catalog.find(catalog.Motor, &catalog.motors, motor.name) != null) return "esse nome é de um motor que vem com o programa";
        var written: std.Io.Writer.Allocating = .init(memory);
        try catalog.writeMotor(&written.writer, motor);
        _ = writeText(context.io, memory, .motors, motor.name, written.written()) catch return "não deu para gravar na pasta da biblioteca";
        reload(context.io);
        return std.fmt.allocPrint(memory, "entrou na biblioteca: {s}", .{motor.name});
    }
    return "";
}

/// a página dos motores: o formulário, a lista (os do programa e os da biblioteca) e a tabela
pub fn motorPage(_: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const motors = try allMotors(memory);
    const group = "motor";
    const params = [_]simulation.Param{
        .{ .key = "name", .label = "nome", .kind = .str, .default = .{ .text = motor_draft.name }, .group = group },
        .{ .key = "Kv", .label = "Kv", .unit = "rpm/V", .default = .{ .number = motor_draft.Kv }, .minimum = 1, .maximum = 10000, .group = group },
        .{ .key = "Rm", .label = "resistência", .unit = "Ω", .default = .{ .number = motor_draft.Rm }, .minimum = 0.0001, .maximum = 10, .group = group },
        .{ .key = "Imax", .label = "corrente máxima", .unit = "A", .default = .{ .number = motor_draft.Imax }, .minimum = 0.1, .maximum = 500, .group = group },
        .{ .key = "mass", .label = "massa", .unit = "kg", .default = .{ .number = motor_draft.mass }, .minimum = 0.001, .maximum = 20, .group = group },
        .{ .key = "B", .label = "atrito viscoso B", .unit = "N·m·s", .default = .{ .number = motor_draft.B }, .minimum = 0, .maximum = 1, .group = group, .help = "opcional (0 sem dado)" },
        .{ .key = "tauc", .label = "atrito seco τc", .unit = "N·m", .default = .{ .number = motor_draft.tauc }, .minimum = 0, .maximum = 10, .group = group, .help = "opcional (0 sem dado)" },
        .{ .key = "Jm", .label = "inércia do rotor", .unit = "kg·m²", .default = .{ .number = motor_draft.Jm }, .minimum = 0, .maximum = 1, .group = group, .help = "opcional (0 sem dado)" },
    };
    var kept: std.ArrayList([]const u8) = .empty;
    var rows: std.ArrayList([]const []const u8) = .empty;
    for (motors, 0..) |motor, k| {
        const origin: []const u8 = if (k < catalog.motors.len) "vem com o programa" else "biblioteca";
        try kept.append(memory, try std.fmt.allocPrint(memory, "{s}   ({s})", .{ motor.name, origin }));
        try rows.append(memory, try memory.dupe([]const u8, &.{
            motor.name,
            try std.fmt.allocPrint(memory, "{d:.0}", .{motor.Kv}),
            try std.fmt.allocPrint(memory, "{d:.4}", .{motor.Rm}),
            try std.fmt.allocPrint(memory, "{d:.0}", .{motor.Imax}),
            try std.fmt.allocPrint(memory, "{d:.3}", .{motor.mass}),
            if (motor.source.len > 0) motor.source else origin,
        }));
    }
    const tables = try memory.dupe(simulation.Table, &.{.{ .title = "Motores", .headers = &.{ "nome", "Kv (rpm/V)", "R (Ω)", "I máx. (A)", "massa (kg)", "fonte" }, .rows = rows.items }});
    return .{
        .title = "Motor",
        .help = "Os motores que o programa conhece: os que vêm com ele e os da biblioteca, que valem para todos os projetos. Para acrescentar, preencha o formulário (ou parta de um da lista) e guarde com outro nome, ou traga um arquivo com \"+ .dat…\". Eles aparecem em Motores e montagem, nas variáveis do projeto e no Mini-MDO.",
        .keep_label = "Guardar na biblioteca",
        .kept_title = "Motores",
        .params = try memory.dupe(simulation.Param, &params),
        .kept = kept.items,
        .actions = &motor_actions,
        .tables = tables,
        .alerts = loaded.problems,
        .message = try std.fmt.allocPrint(memory, "{d} motores ({d} da biblioteca)", .{ motors.len, motors.len - catalog.motors.len }),
    };
}

// ------------------------------------------------------------------ Hélices
const propeller_actions = [_]simulation.StageAction{
    .{ .key = "dat", .label = "+ .dat…", .arg = "file", .help = "o .dat padrão: \"# nome:\", \"# diametro:\" (m) e as linhas J C_T C_P" },
};

const propeller_plots = [_]simulation.Plot{
    .{ .key = "ct", .title = "Coeficiente de tração", .xlabel = "$J$", .ylabel = "$C_T$" },
    .{ .key = "cp", .title = "Coeficiente de potência", .xlabel = "$J$", .ylabel = "$C_P$" },
    .{ .key = "eta", .title = "Eficiência", .xlabel = "$J$", .ylabel = "$\\eta$" },
};
const palette = [_][]const u8{ "#1f77b4", "#eb6834", "#1baf7a", "#d62728", "#4a3aa7", "#8c564b", "#e87ba4", "#17becf" };

var selected_propeller: usize = 0;

fn allPropellers(memory: std.mem.Allocator) ![]const catalog.Propeller {
    var out: std.ArrayList(catalog.Propeller) = .empty;
    try out.appendSlice(memory, &catalog.propellers);
    try out.appendSlice(memory, catalog.userItems().propellers);
    return out.items;
}

/// muda a biblioteca de hélices conforme o pedido
pub fn applyPropellers(context: *stages.Context, memory: std.mem.Allocator, request: stages.Request) ![]const u8 {
    const propellers = try allPropellers(memory);
    if (std.mem.eql(u8, request.do, "load")) {
        if (stages.within(request.index, propellers.len)) |index| selected_propeller = index;
        return "";
    }
    if (std.mem.eql(u8, request.do, "delete")) {
        const index = stages.within(request.index, propellers.len) orelse return "";
        if (index < catalog.propellers.len) return "essa hélice vem com o programa: não sai da lista";
        const file = loaded.propeller_files[index - catalog.propellers.len];
        std.Io.Dir.cwd().deleteFile(context.io, file) catch return "não deu para apagar o arquivo";
        reload(context.io);
        selected_propeller = 0;
        return std.fmt.allocPrint(memory, "saiu da biblioteca: {s}", .{propellers[index].name});
    }
    if (std.mem.eql(u8, request.do, "act") and std.mem.eql(u8, request.key, "dat")) {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, request.arg, memory, .limited(1 << 20)) catch return "não deu para ler o .dat";
        const propeller = catalog.parsePropeller(memory, text, std.fs.path.stem(request.arg)) catch |err| return problemText(err);
        if (catalog.find(catalog.Propeller, &catalog.propellers, propeller.name) != null) return "esse nome é de uma hélice que vem com o programa";
        // o arquivo vai como veio, com o nome escrito no cabeçalho para a próxima leitura achar o mesmo
        const header = try std.fmt.allocPrint(memory, "# nome: {s}\n# diametro: {d}\n# passo: {d}\n# massa: {d}\n# inercia: {d}\n# fonte: {s}\n", .{ propeller.name, propeller.D, propeller.pitch, propeller.mass, propeller.Ip, propeller.source });
        var data: std.ArrayList(u8) = .empty;
        try data.appendSlice(memory, header);
        try data.appendSlice(memory, "# J C_T C_P\n");
        for (propeller.J, propeller.CT, propeller.CP) |j, ct, cp| try data.print(memory, "{d} {d} {d}\n", .{ j, ct, cp });
        _ = writeText(context.io, memory, .propellers, propeller.name, data.items) catch return "não deu para gravar na pasta da biblioteca";
        reload(context.io);
        selected_propeller = catalog.propellers.len;
        for (catalog.userItems().propellers, 0..) |item, k| if (std.mem.eql(u8, item.name, propeller.name)) {
            selected_propeller = catalog.propellers.len + k;
        };
        return std.fmt.allocPrint(memory, "entrou na biblioteca: {s}", .{propeller.name});
    }
    return "";
}

/// a página das hélices: a lista, as curvas de todas e os números da selecionada
pub fn propellerPage(_: *stages.Context, memory: std.mem.Allocator) !simulation.StagePage {
    const propellers = try allPropellers(memory);
    if (selected_propeller >= propellers.len) selected_propeller = 0;
    var kept: std.ArrayList([]const u8) = .empty;
    const figures = try simulation.Figures.init(memory, &propeller_plots);
    for (propellers, 0..) |propeller, k| {
        const origin: []const u8 = if (k < catalog.propellers.len) "vem com o programa" else "biblioteca";
        try kept.append(memory, try std.fmt.allocPrint(memory, "{s}   ({s})", .{ propeller.name, origin }));
        // η = J·C_T/C_P (a definição da eficiência da hélice; McCormick, Aerodynamics, Aeronautics and Flight
        // Mechanics, cap. 6, a conferir no PDF); onde C_P ≤ 0 não há
        const efficiency = try memory.alloc(f64, propeller.J.len);
        for (efficiency, propeller.J, propeller.CT, propeller.CP) |*eta, j, ct, cp| eta.* = if (cp > 0 and ct >= 0) j * ct / cp else std.math.nan(f64);
        const color = palette[k % palette.len];
        const width: f64 = if (k == selected_propeller) 3 else 1.2;
        try figures.curve("ct", .{ .name = propeller.name, .x = propeller.J, .y = propeller.CT, .color = color, .width = width });
        try figures.curve("cp", .{ .name = propeller.name, .x = propeller.J, .y = propeller.CP, .color = color, .width = width });
        try figures.curve("eta", .{ .name = propeller.name, .x = propeller.J, .y = efficiency, .color = color, .width = width });
    }
    var summary: std.ArrayList([2][]const u8) = .empty;
    if (propellers.len > 0) {
        const chosen = propellers[selected_propeller];
        try summary.append(memory, .{ "hélice", chosen.name });
        try summary.append(memory, .{ "diâmetro, passo (m)", try std.fmt.allocPrint(memory, "{d:.4}, {d:.4}", .{ chosen.D, chosen.pitch }) });
        try summary.append(memory, .{ "massa (kg), inércia (kg·m²)", try std.fmt.allocPrint(memory, "{d:.4}, {e:.3}", .{ chosen.mass, chosen.Ip }) });
        try summary.append(memory, .{ "pontos da tabela; J máx.", try std.fmt.allocPrint(memory, "{d}; {d:.3}", .{ chosen.J.len, chosen.J[chosen.J.len - 1] }) });
        try summary.append(memory, .{ "fonte", chosen.source });
    }
    return .{
        .title = "Hélice",
        .keep_label = "",
        .help = "As hélices que o programa conhece: as que vêm com ele e as da biblioteca, que valem para todos os projetos. \"+ .dat…\" traz uma hélice no formato padrão: um cabeçalho com \"# nome: APC 12x6E\" e \"# diametro: 0.3048\" (m; sem ele, sai do \"12x6\" do nome, em polegadas), \"# passo\", \"# massa\" e \"# inercia\" opcionais, e as linhas \"J C_T C_P\" com J crescente (uma quarta coluna, como a η da base da UIUC, é ignorada).",
        .kept_title = "Hélices",
        .kept = kept.items,
        .actions = &propeller_actions,
        .summary = summary.items,
        .figures = figures,
        .alerts = loaded.problems,
        .message = try std.fmt.allocPrint(memory, "{d} hélices ({d} da biblioteca)", .{ propellers.len, propellers.len - catalog.propellers.len }),
    };
}

test "biblioteca: o nome do arquivo de um item" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const name = try fileName(memory, "APC 12x6E / teste");
    try testing.expectEqualStrings("APC 12x6E _ teste.dat", name);
}

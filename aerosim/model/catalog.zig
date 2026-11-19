//! Itens de catálogo em Zig (o par de `catalog.py`): motores, hélices e baterias que já vêm com o programa.
//!
//! As hélices genéricas são estimativas, não dados de fabricante: a curva da APC 15x8E escalada pelo passo
//! relativo (J de tração nula ≈ 0,85 P/D), feita em tempo de compilação como `generic_propeller` do Python.
const std = @import("std");

/// um motor elétrico (modelo de primeira ordem: Kv, resistência, atritos)
pub const Motor = struct {
    name: []const u8,
    /// rpm/V
    Kv: f64,
    /// resistência (Ω)
    Rm: f64,
    /// atrito viscoso (N·m·s)
    B: f64,
    /// atrito seco (N·m)
    tauc: f64,
    /// corrente máxima (A)
    Imax: f64,
    /// inércia do rotor (kg·m²)
    Jm: f64,
    /// kg
    mass: f64,
    source: []const u8 = "",
};

/// uma hélice: diâmetro, inércia, massa e a tabela J, C_T, C_P
pub const Propeller = struct {
    name: []const u8,
    /// diâmetro (m)
    D: f64,
    /// passo (m), só informativo
    pitch: f64,
    /// inércia (kg·m²)
    Ip: f64,
    mass: f64,
    J: []const f64,
    CT: []const f64,
    CP: []const f64,
    source: []const u8 = "",
};

/// um pacote de baterias
pub const Battery = struct {
    name: []const u8,
    cells: f64,
    V_cell: f64,
    /// resistência do pacote (Ω)
    Rint: f64,
    capacity_mAh: f64,
    mass: f64,
    source: []const u8 = "",

    /// tensão em aberto (V)
    pub fn voc(battery: Battery) f64 {
        return battery.cells * battery.V_cell;
    }
};

/// APC 15x8E a 6000 rpm (J, C_T, C_P do fabricante, vindos do código original)
const apc_15x8e = [_][3]f64{
    .{ 0.0000, 0.0896, 0.0299 }, .{ 0.0234, 0.0883, 0.0303 }, .{ 0.0468, 0.0869, 0.0307 }, .{ 0.0701, 0.0853, 0.0310 },
    .{ 0.0935, 0.0836, 0.0314 }, .{ 0.1169, 0.0818, 0.0316 }, .{ 0.1403, 0.0799, 0.0319 }, .{ 0.1637, 0.0778, 0.0320 },
    .{ 0.1871, 0.0756, 0.0321 }, .{ 0.2104, 0.0732, 0.0321 }, .{ 0.2338, 0.0706, 0.0320 }, .{ 0.2572, 0.0679, 0.0317 },
    .{ 0.2806, 0.0651, 0.0314 }, .{ 0.3040, 0.0620, 0.0309 }, .{ 0.3274, 0.0588, 0.0304 }, .{ 0.3507, 0.0555, 0.0296 },
    .{ 0.3741, 0.0520, 0.0288 }, .{ 0.3975, 0.0484, 0.0278 }, .{ 0.4209, 0.0446, 0.0266 }, .{ 0.4443, 0.0407, 0.0253 },
    .{ 0.4676, 0.0368, 0.0239 }, .{ 0.4910, 0.0327, 0.0224 }, .{ 0.5144, 0.0286, 0.0207 }, .{ 0.5378, 0.0245, 0.0189 },
    .{ 0.5612, 0.0203, 0.0170 }, .{ 0.5846, 0.0162, 0.0150 }, .{ 0.6079, 0.0120, 0.0129 }, .{ 0.6313, 0.0079, 0.0108 },
    .{ 0.6547, 0.0039, 0.0085 }, .{ 0.6781, 0.0000, 0.0062 },
};

fn column(comptime which: usize) [apc_15x8e.len]f64 {
    var out: [apc_15x8e.len]f64 = undefined;
    for (apc_15x8e, 0..) |row, i| out[i] = row[which];
    return out;
}

const apc_J = column(0);
const apc_CT = column(1);
const apc_CP = column(2);

/// interpolação linear em `xs` (crescente), com o valor da ponta fora da faixa (como `np.interp`)
fn interp(x: f64, xs: []const f64, ys: []const f64) f64 {
    if (x <= xs[0]) return ys[0];
    if (x >= xs[xs.len - 1]) return ys[ys.len - 1];
    var i: usize = 1;
    while (xs[i] < x) i += 1;
    const t = (x - xs[i - 1]) / (xs[i] - xs[i - 1]);
    return ys[i - 1] + t * (ys[i] - ys[i - 1]);
}

const generic_points = 25;

/// as tabelas J, C_T, C_P da hélice genérica: a curva da APC 15x8E escalada pelo passo relativo
fn genericTables(comptime diameter_in: f64, comptime pitch_in: f64) [3][generic_points]f64 {
    @setEvalBranchQuota(100_000);
    const pitch_ratio = pitch_in / diameter_in;
    const zero_thrust = 0.85 * pitch_ratio;
    const scale = zero_thrust / 0.6781;
    const thrust_factor = 0.75 + 0.25 * pitch_ratio / 0.533;
    const power_factor = std.math.pow(f64, pitch_ratio / 0.533, 1.2);
    var tables: [3][generic_points]f64 = undefined;
    for (0..generic_points) |i| {
        const advance = zero_thrust * @as(f64, @floatFromInt(i)) / (generic_points - 1);
        tables[0][i] = advance;
        tables[1][i] = interp(advance / scale, &apc_J, &apc_CT) * thrust_factor;
        tables[2][i] = interp(advance / scale, &apc_J, &apc_CP) * power_factor;
    }
    return tables;
}

const generic_13x6_5 = genericTables(13, 6.5);
const generic_11x7 = genericTables(11, 7);
const generic_16x10 = genericTables(16, 10);

/// hélice GENÉRICA (estimativa, não é dado de fabricante), como `generic_propeller` do Python
fn genericPropeller(comptime name: []const u8, comptime diameter_in: f64, comptime pitch_in: f64, comptime tables: *const [3][generic_points]f64) Propeller {
    const diameter = diameter_in * 0.0254;
    const ratio = diameter / 0.381;
    return .{
        .name = name,
        .D = diameter,
        .pitch = pitch_in * 0.0254,
        .Ip = 5.4e-4 * ratio * ratio * ratio * ratio * ratio,
        .mass = 0.05 * ratio * ratio * ratio,
        .J = &tables[0],
        .CT = &tables[1],
        .CP = &tables[2],
        .source = "genérica (estimada a partir da APC 15x8E)",
    };
}

/// os motores que vêm com o programa
pub const motors = [_]Motor{
    .{ .name = "Scorpion A-5025-310Kv", .Kv = 310.0, .Rm = 0.0174 + 0.003, .B = 32.4e-6, .tauc = 0.0155, .Imax = 80.0, .Jm = 1.0e-4, .mass = 0.53, .source = "dados do código original" },
    .{ .name = "Genérico 500Kv", .Kv = 500.0, .Rm = 0.045, .B = 2.0e-5, .tauc = 0.01, .Imax = 50.0, .Jm = 6e-5, .mass = 0.30, .source = "genérico (estimado)" },
    .{ .name = "Genérico 900Kv", .Kv = 900.0, .Rm = 0.08, .B = 1.0e-5, .tauc = 0.006, .Imax = 30.0, .Jm = 3e-5, .mass = 0.15, .source = "genérico (estimado)" },
};

/// as hélices que vêm com o programa
pub const propellers = [_]Propeller{
    .{ .name = "APC 15x8E", .D = 0.381, .pitch = 0.2032, .Ip = 5.4e-4, .mass = 0.06, .J = &apc_J, .CT = &apc_CT, .CP = &apc_CP, .source = "catálogo APC (6000 rpm)" },
    genericPropeller("Genérica 13x6.5", 13, 6.5, &generic_13x6_5),
    genericPropeller("Genérica 11x7", 11, 7, &generic_11x7),
    genericPropeller("Genérica 16x10", 16, 10, &generic_16x10),
};

/// as baterias que vêm com o programa
pub const batteries = [_]Battery{
    .{ .name = "LiPo 6S 5000", .cells = 6, .V_cell = 3.7, .Rint = 0.035, .capacity_mAh = 5000, .mass = 0.80, .source = "dados do código original" },
    .{ .name = "LiPo 4S 4000", .cells = 4, .V_cell = 3.7, .Rint = 0.030, .capacity_mAh = 4000, .mass = 0.45, .source = "genérica" },
    .{ .name = "LiPo 3S 2200", .cells = 3, .V_cell = 3.7, .Rint = 0.025, .capacity_mAh = 2200, .mass = 0.19, .source = "genérica" },
};

/// o item com este nome numa das listas
pub fn find(comptime Item: type, items: []const Item, name: []const u8) ?*const Item {
    for (items) |*item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
}

// ------------------------------------------------------------------ a biblioteca do usuário
/// os motores e as hélices que o usuário pôs na biblioteca do programa (lidos dos arquivos dela). A lista inteira é
/// trocada de uma vez quando a biblioteca muda; uma lista velha nunca é liberada, porque uma análise rodando numa
/// thread pode estar lendo ela
pub const UserItems = struct { motors: []const Motor = &.{}, propellers: []const Propeller = &.{} };

const no_user_items: UserItems = .{};
var user_items: std.atomic.Value(*const UserItems) = .init(&no_user_items);

/// troca os itens da biblioteca do usuário (`items` tem que viver até o fim do programa)
pub fn setUserItems(items: *const UserItems) void {
    user_items.store(items, .release);
}

/// os itens da biblioteca do usuário agora
pub fn userItems() *const UserItems {
    return user_items.load(.acquire);
}

/// o motor com este nome: o que vem com o programa, senão o da biblioteca
pub fn findMotor(name: []const u8) ?Motor {
    if (find(Motor, &motors, name)) |motor| return motor.*;
    if (find(Motor, userItems().motors, name)) |motor| return motor.*;
    return null;
}

/// a hélice com este nome: a que vem com o programa, senão a da biblioteca
pub fn findPropeller(name: []const u8) ?Propeller {
    if (find(Propeller, &propellers, name)) |propeller| return propeller.*;
    if (find(Propeller, userItems().propellers, name)) |propeller| return propeller.*;
    return null;
}

/// os nomes dos motores: os que vêm com o programa e os da biblioteca
pub fn motorNames(memory: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (motors) |motor| try out.append(memory, motor.name);
    for (userItems().motors) |motor| try out.append(memory, motor.name);
    return out.items;
}

/// os nomes das hélices: as que vêm com o programa e as da biblioteca
pub fn propellerNames(memory: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (propellers) |propeller| try out.append(memory, propeller.name);
    for (userItems().propellers) |propeller| try out.append(memory, propeller.name);
    return out.items;
}

// ------------------------------------------------------------------ os arquivos da biblioteca
/// uma linha "chave: valor" (ou "# chave: valor", ou "chave = valor"); nula se a linha não é assim
fn keyValue(line: []const u8) ?[2][]const u8 {
    const body = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, line, " \t\r"), "#"), " \t");
    const split = std.mem.indexOfAny(u8, body, ":=") orelse return null;
    const key = std.mem.trim(u8, body[0..split], " \t");
    const value = std.mem.trim(u8, body[split + 1 ..], " \t");
    if (key.len == 0 or value.len == 0) return null;
    return .{ key, value };
}

/// a chave sem acento e em minúsculas, para aceitar "diâmetro", "Diametro" e "diametro"
fn sameKey(key: []const u8, comptime wanted: []const []const u8) bool {
    inline for (wanted) |name| if (std.ascii.eqlIgnoreCase(key, name)) return true;
    return false;
}

fn number(text: []const u8) ?f64 {
    var parts = std.mem.tokenizeAny(u8, text, " \t");
    return std.fmt.parseFloat(f64, parts.next() orelse return null) catch null;
}

/// lê um motor no formato da biblioteca: linhas "chave: valor" com nome, Kv (rpm/V), Rm (Ω), Imax (A) e massa (kg);
/// B (N·m·s), tauc (N·m) e Jm (kg·m²) são opcionais (zero sem eles)
pub fn parseMotor(memory: std.mem.Allocator, text: []const u8, fallback_name: []const u8) !Motor {
    var motor: Motor = .{ .name = "", .Kv = 0, .Rm = 0, .B = 0, .tauc = 0, .Imax = 0, .Jm = 0, .mass = 0, .source = "biblioteca do usuário" };
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const pair = keyValue(line) orelse continue;
        if (sameKey(pair[0], &.{"nome"})) {
            motor.name = try memory.dupe(u8, pair[1]);
            continue;
        }
        if (sameKey(pair[0], &.{"fonte"})) {
            motor.source = try memory.dupe(u8, pair[1]);
            continue;
        }
        const value = number(pair[1]) orelse continue;
        if (sameKey(pair[0], &.{"kv"})) motor.Kv = value;
        if (sameKey(pair[0], &.{"rm"})) motor.Rm = value;
        if (sameKey(pair[0], &.{"imax"})) motor.Imax = value;
        if (sameKey(pair[0], &.{ "massa", "mass" })) motor.mass = value;
        if (sameKey(pair[0], &.{"b"})) motor.B = value;
        if (sameKey(pair[0], &.{"tauc"})) motor.tauc = value;
        if (sameKey(pair[0], &.{"jm"})) motor.Jm = value;
    }
    if (motor.name.len == 0) motor.name = try memory.dupe(u8, fallback_name);
    if (motor.Kv <= 0 or motor.Rm <= 0 or motor.Imax <= 0 or motor.mass <= 0) return error.IncompleteMotor;
    return motor;
}

/// escreve um motor no formato da biblioteca (o que `parseMotor` lê)
pub fn writeMotor(out: *std.Io.Writer, motor: Motor) !void {
    try out.print("# motor da biblioteca do AeroSim\nnome: {s}\nKv: {d}\nRm: {d}\nImax: {d}\nmassa: {d}\nB: {d}\ntauc: {d}\nJm: {d}\nfonte: {s}\n", .{ motor.name, motor.Kv, motor.Rm, motor.Imax, motor.mass, motor.B, motor.tauc, motor.Jm, motor.source });
}

/// o diâmetro e o passo (polegadas) de um nome como "APC 12x6E" ou "apc_10x4.7"; nulo se não tem
fn inchesInName(name: []const u8) ?[2]f64 {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (!std.ascii.isDigit(name[i])) continue;
        var end = i;
        while (end < name.len and (std.ascii.isDigit(name[end]) or name[end] == '.')) end += 1;
        if (end + 1 < name.len and (name[end] == 'x' or name[end] == 'X') and std.ascii.isDigit(name[end + 1])) {
            var pitch_end = end + 1;
            while (pitch_end < name.len and (std.ascii.isDigit(name[pitch_end]) or name[pitch_end] == '.')) pitch_end += 1;
            const diameter = std.fmt.parseFloat(f64, name[i..end]) catch return null;
            const pitch = std.fmt.parseFloat(f64, name[end + 1 .. pitch_end]) catch return null;
            return .{ diameter, pitch };
        }
        i = end;
    }
    return null;
}

/// lê uma hélice no .dat padrão da biblioteca: um cabeçalho "# chave: valor" (nome, diâmetro em m; passo em m,
/// massa em kg e inércia em kg·m² opcionais) e as linhas "J C_T C_P" (uma quarta coluna, como a η da base da UIUC,
/// é ignorada). Sem diâmetro, ele sai do nome ("12x6" em polegadas). Sem massa ou inércia, elas saem da APC 15x8E
/// escalada pelo diâmetro, como nas hélices genéricas
pub fn parsePropeller(memory: std.mem.Allocator, text: []const u8, fallback_name: []const u8) !Propeller {
    var name: []const u8 = "";
    var source: []const u8 = "biblioteca do usuário";
    var diameter: f64 = 0;
    var pitch: f64 = 0;
    var mass: ?f64 = null;
    var inertia: ?f64 = null;
    var advance: std.ArrayList(f64) = .empty;
    var thrust: std.ArrayList(f64) = .empty;
    var power: std.ArrayList(f64) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (keyValue(line)) |pair| {
            if (sameKey(pair[0], &.{"nome"})) name = try memory.dupe(u8, pair[1]);
            if (sameKey(pair[0], &.{"fonte"})) source = try memory.dupe(u8, pair[1]);
            const value = number(pair[1]) orelse continue;
            if (sameKey(pair[0], &.{ "diametro", "diâmetro", "d" })) diameter = value;
            if (sameKey(pair[0], &.{"passo"})) pitch = value;
            if (sameKey(pair[0], &.{ "massa", "mass" })) mass = value;
            if (sameKey(pair[0], &.{ "inercia", "inércia", "ip" })) inertia = value;
            continue;
        }
        var parts = std.mem.tokenizeAny(u8, line, " \t,;");
        const j = std.fmt.parseFloat(f64, parts.next() orelse continue) catch continue;
        const ct = std.fmt.parseFloat(f64, parts.next() orelse continue) catch continue;
        const cp = std.fmt.parseFloat(f64, parts.next() orelse continue) catch continue;
        if (advance.items.len > 0 and j <= advance.items[advance.items.len - 1]) return error.UnsortedTable;
        try advance.append(memory, j);
        try thrust.append(memory, ct);
        try power.append(memory, cp);
    }
    if (name.len == 0) name = try memory.dupe(u8, fallback_name);
    if (diameter <= 0) if (inchesInName(name)) |inches| {
        diameter = inches[0] * 0.0254;
        if (pitch <= 0) pitch = inches[1] * 0.0254;
    };
    if (diameter <= 0) return error.MissingDiameter;
    if (advance.items.len < 2) return error.ShortTable;
    const ratio = diameter / 0.381;
    return .{
        .name = name,
        .D = diameter,
        .pitch = pitch,
        .Ip = inertia orelse 5.4e-4 * ratio * ratio * ratio * ratio * ratio,
        .mass = mass orelse 0.05 * ratio * ratio * ratio,
        .J = advance.items,
        .CT = thrust.items,
        .CP = power.items,
        .source = source,
    };
}

test "catálogo: a hélice genérica tem a forma da APC" {
    const p = propellers[2];
    try std.testing.expectEqual(@as(usize, generic_points), p.J.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85 * 7.0 / 11.0), p.J[p.J.len - 1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p.CT[p.CT.len - 1], 1e-12);
    try std.testing.expect(find(Battery, &batteries, "LiPo 4S 4000") != null);
}

test "biblioteca: lê um motor e uma hélice nos arquivos do usuário" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var written: std.Io.Writer.Allocating = .init(memory);
    try writeMotor(&written.writer, motors[0]);
    const motor = try parseMotor(memory, written.written(), "x");
    try std.testing.expectEqualStrings(motors[0].name, motor.name);
    try std.testing.expectEqual(motors[0].Kv, motor.Kv);
    try std.testing.expectEqual(motors[0].Jm, motor.Jm);
    try std.testing.expectError(error.IncompleteMotor, parseMotor(memory, "nome: sem Kv\nRm: 0.1", "x"));

    // sem cabeçalho de diâmetro: sai do nome (12x6 pol.); a quarta coluna (η) é ignorada
    const propeller = try parsePropeller(memory, "# nome: APC 12x6E\n# J CT CP eta\n0.0 0.10 0.04 0\n0.3 0.07 0.04 0.5\n0.6 0.01 0.02 0.3\n", "x");
    try std.testing.expectApproxEqAbs(@as(f64, 12 * 0.0254), propeller.D, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6 * 0.0254), propeller.pitch, 1e-12);
    try std.testing.expectEqual(@as(usize, 3), propeller.J.len);
    try std.testing.expectEqual(@as(f64, 0.07), propeller.CT[1]);
    try std.testing.expectError(error.MissingDiameter, parsePropeller(memory, "0 0.1 0.04\n0.5 0.0 0.02", "hélice"));
    try std.testing.expectError(error.UnsortedTable, parsePropeller(memory, "diametro: 0.3\n0.5 0.1 0.04\n0.2 0.0 0.02", "hélice"));

    // um item da biblioteca aparece nas buscas pelo nome
    const items = try memory.create(UserItems);
    items.* = .{ .motors = try memory.dupe(Motor, &.{motor}), .propellers = try memory.dupe(Propeller, &.{propeller}) };
    setUserItems(items);
    defer setUserItems(&no_user_items);
    try std.testing.expect(findPropeller("APC 12x6E") != null);
    try std.testing.expectEqual(propellers.len + 1, (try propellerNames(memory)).len);
}

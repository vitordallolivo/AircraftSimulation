//! O avião da Montagem: lê o `.json` pelo modelo do AeroDrive (`aerodrive/src/model`, o mesmo que o simulador
//! usa), completa os perfis que o arquivo só aponta (um `.dat` em `airfoil.path`, como a GUI em Python faz em
//! `Airfoil.outline`) e monta as peças pelo esqueleto do AeroDrive: superfícies pelo perfil, comandos,
//! dispositivos, fuselagem, tubos, motores e hélices, tanques e líquido, carga, lastro e trem, nas cores da GUI.
//! Cada triângulo já sai com a cor e a sombra da vista 3D; a tela só desenha.
const std = @import("std");
const rl = @import("raylib");
const aircraft_model = @import("aircraft_model");
const view3d = @import("ui").view3d;

const model = aircraft_model.aircraft;
const skeleton = aircraft_model.skeleton;

pub const Triangle = struct {
    a: view3d.Body,
    b: view3d.Body,
    c: view3d.Body,
    color: rl.Color,
};

/// as peças de um avião prontas para a vista 3D: cada triângulo com a cor e a sombra
pub const Mesh = struct {
    skeleton: skeleton.Skeleton,
    arena: std.heap.ArenaAllocator,
    solid: []Triangle, // opacos (desenhados primeiro)
    translucent: []Triangle, // disco da hélice, tanque, líquido
    low: view3d.Body, // caixa que envolve o avião (corpo)
    high: view3d.Body,
    piece_count: usize,

    /// libera tudo
    pub fn deinit(mesh: *Mesh) void {
        mesh.skeleton.deinit();
        mesh.arena.deinit();
    }

    /// o centro da caixa
    pub fn center(mesh: *const Mesh) view3d.Body {
        return .{ 0.5 * (mesh.low[0] + mesh.high[0]), 0.5 * (mesh.low[1] + mesh.high[1]), 0.5 * (mesh.low[2] + mesh.high[2]) };
    }

    /// o maior lado da caixa (m)
    pub fn size(mesh: *const Mesh) f64 {
        return @max(mesh.high[0] - mesh.low[0], @max(mesh.high[1] - mesh.low[1], mesh.high[2] - mesh.low[2]));
    }

    /// desenha os triângulos (dentro de `View.begin`/`end`)
    pub fn draw(mesh: *const Mesh) void {
        for (mesh.solid) |t| view3d.triangle(t.a, t.b, t.c, t.color);
        for (mesh.translucent) |t| view3d.triangle(t.a, t.b, t.c, t.color);
    }
};

/// as peças do avião `ac` pelo esqueleto do AeroDrive
pub fn buildMesh(gpa: std.mem.Allocator, ac: *const model.Aircraft, diagnosis: *Diagnosis) !Mesh {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var built = try skeleton.build(gpa, ac, diagnosis);
    errdefer built.deinit();
    var solid: std.ArrayList(Triangle) = .empty;
    var translucent: std.ArrayList(Triangle) = .empty;
    var low: view3d.Body = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var high: view3d.Body = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (built.pieces) |piece| {
        const rgba = skeleton.rgba(piece.color);
        const color: rl.Color = .{ .r = @intFromFloat(rgba[0] * 255), .g = @intFromFloat(rgba[1] * 255), .b = @intFromFloat(rgba[2] * 255), .a = @intFromFloat(rgba[3] * 255) };
        const list = if (rgba[3] < 1) &translucent else &solid;
        for (piece.mesh.f) |face| {
            const a = piece.mesh.v[face[0]];
            const b = piece.mesh.v[face[1]];
            const c = piece.mesh.v[face[2]];
            try list.append(allocator, .{ .a = a, .b = b, .c = c, .color = view3d.shaded(a, b, c, color) });
        }
        for (piece.mesh.v) |point| {
            for (0..3) |k| {
                low[k] = @min(low[k], point[k]);
                high[k] = @max(high[k], point[k]);
            }
        }
    }
    if (solid.items.len + translucent.items.len == 0) {
        low = .{ -0.5, -0.5, -0.1 };
        high = .{ 0.5, 0.5, 0.1 };
    }
    return .{ .skeleton = built, .arena = arena, .solid = solid.items, .translucent = translucent.items, .low = low, .high = high, .piece_count = built.pieces.len };
}

/// o avião aberto: o que o arquivo diz e as peças dele
pub const Assembly = struct {
    loaded: model.Loaded,
    mesh: Mesh,
    name: [:0]const u8,
    source: []const u8, // o texto do arquivo, como foi lido (o que "Salvar" grava enquanto não há edição)
    path: []const u8,

    /// libera tudo
    pub fn deinit(assembly: *Assembly) void {
        assembly.mesh.deinit();
        assembly.loaded.deinit();
    }
};

/// o centro de massa do avião montado, com e sem a carga
pub const Balance = struct {
    empty_mass: f64,
    empty_cg: [3]f64, // sem a carga (a massa seca do AeroDrive: base, itens, lastro e, se o arquivo pede, motores e estrutura)
    mass: f64,
    cg: [3]f64, // com a carga, quando o avião leva carga (sem ela, igual ao vazio)
};

/// o CG pela soma das massas de `params.dryMass` (a mesma do AeroDrive e do núcleo), mais a carga como massa pontual
pub fn balance(ac: *const model.Aircraft) Balance {
    const dry = aircraft_model.params.dryMass(ac);
    var result: Balance = .{ .empty_mass = dry.m, .empty_cg = dry.cg, .mass = dry.m, .cg = dry.cg };
    const payload = ac.payload;
    if (payload.enabled and payload.mass > 0) {
        result.mass = dry.m + payload.mass;
        const where = [3]f64{ payload.x, payload.y, payload.z };
        for (0..3) |i| result.cg[i] = (dry.m * dry.cg[i] + payload.mass * where[i]) / result.mass;
    }
    return result;
}

pub const max_file_bytes = 1 << 24;

/// a mensagem do último erro (o nome do componente com problema, como o AeroDrive dá)
pub const Diagnosis = model.Diag;

/// lê o avião em `path` com os perfis que o arquivo só aponta (as análises em Zig usam este, sem as malhas)
pub fn loadAircraft(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diagnosis: *Diagnosis) !model.Loaded {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| {
        diagnosis.set("não consegui abrir '{s}' ({s})", .{ path, @errorName(err) });
        return err;
    };
    defer gpa.free(bytes);
    var loaded = try model.parse(gpa, bytes, diagnosis);
    errdefer loaded.deinit();
    try fillAirfoilFiles(loaded.arena.allocator(), io, path, bytes, &loaded.ac);
    return loaded;
}

/// lê o avião em `path` e monta as peças
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diagnosis: *Diagnosis) !Assembly {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| {
        diagnosis.set("não consegui abrir '{s}' ({s})", .{ path, @errorName(err) });
        return err;
    };
    defer gpa.free(bytes);
    var loaded = try model.parse(gpa, bytes, diagnosis);
    errdefer loaded.deinit();
    const allocator = loaded.arena.allocator();
    try fillAirfoilFiles(allocator, io, path, bytes, &loaded.ac);
    var mesh = try buildMesh(gpa, &loaded.ac, diagnosis);
    errdefer mesh.deinit();
    return .{ .loaded = loaded, .mesh = mesh, .name = try allocator.dupeZ(u8, loaded.ac.name), .source = try allocator.dupe(u8, bytes), .path = try allocator.dupe(u8, path) };
}

/// os perfis das superfícies que o arquivo só aponta (`airfoil.path`, sem `coords`): lê o `.dat`. O caminho é
/// relativo à raiz do repositório (como `data/airfoils/s1223.dat`), então procura subindo a partir do `.json`
pub fn fillAirfoilFiles(allocator: std.mem.Allocator, io: std.Io, json_path: []const u8, bytes: []const u8, ac: *model.Aircraft) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}) catch return;
    if (root != .object) return;
    const node = root.object.get("aeronave") orelse root;
    if (node != .object) return;
    const surfaces_node = node.object.get("surfaces") orelse return;
    if (surfaces_node != .array) return;
    const surfaces = @constCast(ac.surfaces); // a memória é a da leitura (arena), só desta aeronave
    for (surfaces_node.array.items, 0..) |item, i| {
        if (i >= surfaces.len or surfaces[i].airfoil.coords.len > 0 or item != .object) continue;
        const airfoil = item.object.get("airfoil") orelse continue;
        if (airfoil != .object) continue;
        const path_node = airfoil.object.get("path") orelse continue;
        if (path_node != .string or path_node.string.len == 0) continue;
        const text = readNear(allocator, io, json_path, path_node.string) orelse continue;
        surfaces[i].airfoil.coords = parseDat(allocator, text) catch continue;
    }
}

/// lê `relative` tal como está ou a partir de cada pasta acima do `.json` (até a raiz do repositório)
fn readNear(allocator: std.mem.Allocator, io: std.Io, json_path: []const u8, relative: []const u8) ?[]u8 {
    if (std.Io.Dir.cwd().readFileAlloc(io, relative, allocator, .limited(1 << 20))) |text| return text else |_| {}
    var folder: ?[]const u8 = std.fs.path.dirname(json_path);
    var level: usize = 0;
    while (folder) |dir| : (level += 1) {
        if (level > 5) break;
        const candidate = std.fs.path.join(allocator, &.{ dir, relative }) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, .limited(1 << 20))) |text| return text else |_| {}
        folder = std.fs.path.dirname(dir);
    }
    return null;
}

/// contorno de um `.dat`: Selig (um contorno contínuo) ou Lednicer (a primeira linha de números é a contagem de
/// pontos das duas metades); igual a `read_dat` de `aerosim/model/airfoil.py`
pub fn parseDat(allocator: std.mem.Allocator, text: []const u8) ![]const [2]f64 {
    var points: std.ArrayList([2]f64) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    _ = lines.next(); // o nome
    while (lines.next()) |raw| {
        var fields = std.mem.tokenizeAny(u8, raw, " \t,");
        const first = fields.next() orelse continue;
        const second = fields.next() orelse continue;
        const x = std.fmt.parseFloat(f64, first) catch continue;
        const y = std.fmt.parseFloat(f64, second) catch continue;
        try points.append(allocator, .{ x, y });
    }
    const all = points.items;
    if (all.len > 0 and all[0][0] > 1.5) { // Lednicer
        const upper_count: usize = @intFromFloat(all[0][0]);
        const lower_count: usize = @intFromFloat(all[0][1]);
        if (1 + upper_count + lower_count > all.len or upper_count == 0 or lower_count == 0) return error.InvalidAirfoil;
        const upper = all[1 .. 1 + upper_count];
        const lower = all[1 + upper_count .. 1 + upper_count + lower_count];
        var outline = try allocator.alloc([2]f64, upper_count + lower_count - 1);
        for (upper, 0..) |point, k| outline[upper_count - 1 - k] = point;
        @memcpy(outline[upper_count..], lower[1..]);
        return outline;
    }
    if (all.len < 3) return error.InvalidAirfoil;
    return all;
}

/// o avião de exemplo que a Montagem abre sozinha, procurado a partir da pasta atual e das de cima
pub const example_file = "data/aircraft/S1223_monomotor_EH_convencional_Joinville.json";

/// o caminho do avião de exemplo, se ele existir perto da pasta atual
pub fn findExample(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    var prefix: []const u8 = "";
    for (0..4) |_| {
        const candidate = std.mem.concat(allocator, u8, &.{ prefix, example_file }) catch return null;
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
        prefix = std.mem.concat(allocator, u8, &.{ prefix, "../" }) catch return null;
    }
    return null;
}

test "perfil .dat: Selig e Lednicer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selig = try parseDat(arena.allocator(), "NACA 0012\n1.0 0.0\n0.5 0.05\n0.0 0.0\n0.5 -0.05\n1.0 0.0\n");
    try std.testing.expectEqual(@as(usize, 5), selig.len);
    try std.testing.expectEqual(@as(f64, 0.05), selig[1][1]);
    // Lednicer: metades do bordo de ataque para trás; vira bordo de fuga -> extradorso -> intradorso
    const lednicer = try parseDat(arena.allocator(), "perfil\n3. 3.\n\n0.0 0.0\n0.5 0.05\n1.0 0.0\n\n0.0 0.0\n0.5 -0.05\n1.0 0.0\n");
    try std.testing.expectEqual(@as(usize, 5), lednicer.len);
    try std.testing.expectEqual(@as(f64, 1.0), lednicer[0][0]);
    try std.testing.expectEqual(@as(f64, 0.0), lednicer[2][0]);
    try std.testing.expectEqual(@as(f64, -0.05), lednicer[3][1]);
}

//! O projeto de dimensionamento que as etapas compartilham, como o `DesignProject` da GUI em Python
//! (`aerosim/design/project.py`): as condições de projeto, a lista de perfis candidatos da etapa Perfis (começa com
//! o NACA 2412 e o NACA 4412) e a asa em desenho da etapa Projetar (começa retangular). A biblioteca
//! `data/airfoils` fica à parte: os `.dat` dela entram nas escolhas de perfil da asa sem passar pela lista.
const std = @import("std");
const core = @import("aerosim");
const stage = @import("airfoil_stage.zig");
const assembly_mod = @import("assembly.zig");

const section = core.section;
const wing_line = core.wing_line;

pub const max_airfoils = stage.max_candidates;

/// as condições de projeto (o `Requirements` da GUI) e a massa da asa por área (das regras)
pub const Requirements = struct {
    mass: f64 = 10, // kg, ponto de partida
    airspeed: f64 = 15, // m/s, cruzeiro
    altitude: f64 = 600, // m, altitude-densidade
    wing_density: f64 = 1.1, // kg/m²

    /// as condições do jeito que a linha sustentadora pede
    pub fn conditions(requirements: Requirements) wing_line.Conditions {
        return .{ .mass = requirements.mass, .airspeed = requirements.airspeed, .density = wing_line.isaDensity(requirements.altitude), .wing_density = requirements.wing_density };
    }
};

pub const max_wings = 8;

/// um nome curto guardado por valor
pub const Name = struct {
    pub const capacity = 64;
    bytes: [capacity]u8 = undefined,
    len: usize = 0,

    /// o nome `value` (cortado na capacidade)
    pub fn of(value: []const u8) Name {
        var name: Name = .{};
        name.len = @min(value.len, capacity);
        @memcpy(name.bytes[0..name.len], value[0..name.len]);
        return name;
    }

    /// o texto do nome
    pub fn text(name: *const Name) []const u8 {
        return name.bytes[0..name.len];
    }
};

/// uma asa guardada: a planta e os perfis da raiz e da ponta (vazio: o da raiz)
pub const SavedWing = struct {
    name: Name,
    wing: wing_line.Trapezoid,
    root: Name,
    tip: Name,
};

pub const Design = struct {
    requirements: Requirements = .{},
    airfoils: [max_airfoils]stage.Candidate = undefined,
    airfoil_count: usize = 0,
    library: [max_airfoils]stage.Candidate = undefined, // data/airfoils, sem os NACA
    library_count: usize = 0,
    wing: wing_line.Trapezoid = .{ .taper = 1, .rect_fraction = 1 }, // a asa em desenho: retangular
    root_airfoil: [64]u8 = undefined, // o nome do perfil da raiz da asa ("Usar na asa")
    root_airfoil_len: usize = 0,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    version: u32 = 0, // sobe a cada mudança da lista (a etapa Projetar refaz as escolhas)
    wings: [max_wings]SavedWing = undefined, // as asas guardadas em Projetar, para comparar
    wing_count: usize = 0,
    wing_name: Name = Name.of("Asa 1"), // o nome que a asa em desenho vai ter ao ser guardada

    /// os dois perfis do começo e a biblioteca
    pub fn start(design: *Design) void {
        for ([_][]const u8{ "NACA 2412", "NACA 4412" }) |name| design.add(stage.fromOutline(design.arena.allocator(), name, &.{}, "naca") catch continue);
        design.setRoot("NACA 2412");
        design.loadLibrary();
    }

    /// o alocador do que entra na lista (vive enquanto o projeto viver)
    pub fn allocator(design: *Design) std.mem.Allocator {
        return design.arena.allocator();
    }

    /// acrescenta um candidato; falso se a lista está cheia ou o nome já existe
    pub fn add(design: *Design, candidate: stage.Candidate) void {
        if (design.airfoil_count == max_airfoils or design.find(candidate.name) != null) return;
        design.airfoils[design.airfoil_count] = candidate;
        design.airfoil_count += 1;
        design.version +%= 1;
    }

    /// o índice do candidato de nome `name`
    pub fn find(design: *const Design, name: []const u8) ?usize {
        for (design.airfoils[0..design.airfoil_count], 0..) |candidate, k| if (std.mem.eql(u8, candidate.name, name)) return k;
        return null;
    }

    /// tira o candidato `index` da lista
    pub fn remove(design: *Design, index: usize) void {
        if (index >= design.airfoil_count) return;
        for (index..design.airfoil_count - 1) |k| design.airfoils[k] = design.airfoils[k + 1];
        design.airfoil_count -= 1;
        design.version +%= 1;
    }

    /// marca que um candidato mudou (números, fonte da polar)
    pub fn touch(design: *Design) void {
        design.version +%= 1;
    }

    /// guarda a asa em desenho com o nome dela (uma de mesmo nome é trocada) e passa o nome do desenho para o
    /// seguinte livre ("Asa 2"...), como `keep_wing` da GUI em Python; falso se a lista está cheia
    pub fn keepWing(design: *Design, root: []const u8, tip: []const u8) bool {
        const saved: SavedWing = .{ .name = design.wing_name, .wing = design.wing, .root = Name.of(root), .tip = Name.of(tip) };
        if (design.findWing(design.wing_name.text())) |k| {
            design.wings[k] = saved;
        } else {
            if (design.wing_count == max_wings) return false;
            design.wings[design.wing_count] = saved;
            design.wing_count += 1;
        }
        var number: usize = design.wing_count + 1;
        while (true) : (number += 1) {
            var buffer: [Name.capacity]u8 = undefined;
            const next = std.fmt.bufPrint(&buffer, "Asa {d}", .{number}) catch break;
            if (design.findWing(next) == null) {
                design.wing_name = Name.of(next);
                break;
            }
        }
        design.version +%= 1;
        return true;
    }

    /// o índice da asa guardada com o nome `name`
    pub fn findWing(design: *const Design, name: []const u8) ?usize {
        for (design.wings[0..design.wing_count], 0..) |saved, k| if (std.mem.eql(u8, saved.name.text(), name)) return k;
        return null;
    }

    /// tira a asa guardada `index`
    pub fn removeWing(design: *Design, index: usize) void {
        if (index >= design.wing_count) return;
        for (index..design.wing_count - 1) |k| design.wings[k] = design.wings[k + 1];
        design.wing_count -= 1;
        design.version +%= 1;
    }

    /// a asa guardada `index` volta para o desenho (com o nome e os perfis dela)
    pub fn loadWing(design: *Design, index: usize) void {
        if (index >= design.wing_count) return;
        const saved = design.wings[index];
        design.wing = saved.wing;
        design.wing_name = saved.name;
        design.setRoot(saved.root.text());
    }

    /// o perfil da raiz da asa passa a ser `name`
    pub fn setRoot(design: *Design, name: []const u8) void {
        const length = @min(name.len, design.root_airfoil.len);
        @memcpy(design.root_airfoil[0..length], name[0..length]);
        design.root_airfoil_len = length;
        design.version +%= 1;
    }

    /// o nome do perfil da raiz da asa
    pub fn rootAirfoil(design: *const Design) []const u8 {
        return design.root_airfoil[0..design.root_airfoil_len];
    }

    /// o Reynolds de cruzeiro na corda média da asa em desenho (o que a etapa Perfis usa)
    pub fn reynolds(design: *const Design) f64 {
        const planform = wing_line.planformOf(design.wing, false);
        return wing_line.reynolds(design.requirements.conditions(), planform.meanChord());
    }

    /// os `.dat` de `data/airfoils` que não são NACA (os NACA saem do código), procurando a pasta perto da atual
    fn loadLibrary(design: *Design) void {
        const memory = design.allocator();
        const folder = libraryFolder(memory) orelse return;
        var dir = std.Io.Dir.cwd().openDir(io(), folder, .{ .iterate = true }) catch return;
        defer dir.close(io());
        var names: [64][]const u8 = undefined;
        var name_count: usize = 0;
        var iterator = dir.iterate();
        while (iterator.next(io()) catch null) |entry| {
            if (name_count == names.len or !std.ascii.endsWithIgnoreCase(entry.name, ".dat")) continue;
            names[name_count] = memory.dupe(u8, entry.name) catch continue;
            name_count += 1;
        }
        std.mem.sort([]const u8, names[0..name_count], {}, lessText);
        for (names[0..name_count]) |file_name| {
            if (design.library_count == max_airfoils) break;
            const path = std.fs.path.join(memory, &.{ folder, file_name }) catch continue;
            const candidate = readDat(memory, path) catch continue;
            if (stage.isNaca4(candidate.name)) continue;
            design.library[design.library_count] = candidate;
            design.library_count += 1;
        }
    }
};

/// a pasta `data/airfoils`, a partir da atual ou das de cima
pub fn libraryFolder(memory: std.mem.Allocator) ?[]const u8 {
    var prefix: []const u8 = "";
    for (0..4) |_| {
        const candidate = std.mem.concat(memory, u8, &.{ prefix, "data/airfoils" }) catch return null;
        if (std.Io.Dir.cwd().access(io(), candidate, .{})) |_| return candidate else |_| {}
        prefix = std.mem.concat(memory, u8, &.{ prefix, "../" }) catch return null;
    }
    return null;
}

/// um perfil de um `.dat` (o nome na primeira linha; senão o do arquivo), como `from_dat` da GUI
pub fn readDat(memory: std.mem.Allocator, path: []const u8) !stage.Candidate {
    const text = try std.Io.Dir.cwd().readFileAlloc(io(), path, memory, .limited(1 << 20));
    const coords = try assembly_mod.parseDat(memory, text);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    const first = std.mem.trim(u8, lines.next() orelse "", " \t");
    return stage.fromOutline(memory, if (first.len > 0) first else std.fs.path.stem(path), coords, "dat");
}

/// a polar do XFLR5/XFOIL de `path`, lida para um candidato (`read_polar_file` da GUI)
pub fn readPolar(memory: std.mem.Allocator, path: []const u8, candidate: *stage.Candidate) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(io(), path, memory, .limited(1 << 22));
    const measured = try memory.create(section.Polar);
    candidate.measured_reynolds = try stage.readPolarText(text, measured);
    candidate.measured = measured;
    var methods = candidate.methods;
    methods.insert(.arquivo);
    stage.setMethods(candidate, methods);
}

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// a leitura de arquivos (sem threads)
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

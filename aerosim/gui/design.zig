//! O projeto de dimensionamento que as etapas compartilham, como o `DesignProject` da GUI em Python
//! (`aerosim/design/project.py`): as condições de projeto, a lista de perfis candidatos da etapa Perfis (começa com
//! o NACA 2412 e o NACA 4412) e a asa em desenho da etapa Projetar (começa retangular). A biblioteca
//! `data/airfoils` fica à parte: os `.dat` dela entram nas escolhas de perfil da asa sem passar pela lista.
const std = @import("std");
const core = @import("aerosim");
const stage = @import("airfoil_stage.zig");
const assembly_mod = @import("assembly.zig");
pub const registry = @import("registry.zig");

const section = core.section;
const wing_line = core.wing_line;

pub const max_airfoils = stage.max_candidates;

/// as condições de projeto, o `Requirements` de `aerosim/design/spec.py` (as restrições ficam à parte, em
/// `Design.constraints`)
pub const Requirements = struct {
    mass: f64 = 10, // kg, ponto de partida
    airspeed: f64 = 15, // m/s, cruzeiro
    altitude: f64 = 600, // m, altitude-densidade
    rolling_friction: f64 = 0.04, // atrito de rolamento na pista
    turn_speed: f64 = 0, // m/s, a V da curva sustentada (0 = a de cruzeiro)
    brake_friction: f64 = 0.3, // atrito na frenagem do pouso
    obstacle_height: f64 = 1, // m, a altura a passar no fim da corrida de decolagem

    /// as condições do jeito que a linha sustentadora pede (a massa da asa por área vem das regras)
    pub fn conditions(requirements: Requirements, rules: Rules) wing_line.Conditions {
        return .{ .mass = requirements.mass, .airspeed = requirements.airspeed, .density = wing_line.isaDensity(requirements.altitude), .wing_density = rules.wing_density };
    }

    /// o resumo da barra de requisitos, como `Requirements.summary` da GUI
    pub fn summary(requirements: Requirements, constraints: *const registry.Constraints, buffer: []u8) []const u8 {
        var mass: [24]u8 = undefined;
        var speed: [24]u8 = undefined;
        var list: [600]u8 = undefined;
        return std.fmt.bufPrint(buffer, "partida m = {s} kg · V = {s} m/s · AD {d:.0} m (ρ = {d:.3}) · restrições: {s}", .{
            trimmed(&mass, requirements.mass),         trimmed(&speed, requirements.airspeed), requirements.altitude,
            wing_line.isaDensity(requirements.altitude), constraints.summary(&list),
        }) catch "";
    }
};

/// um número sem zeros sobrando (o `:g` do Python para os valores da barra)
fn trimmed(buffer: []u8, value: f64) []const u8 {
    const text = std.fmt.bufPrint(buffer, "{d:.4}", .{value}) catch return "";
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

/// as regras de projeto, o `DesignRules` de `aerosim/design/spec.py`: massas por área e por metro, fuselagem, trem e
/// cursos dos comandos
pub const Rules = struct {
    wing_density: f64 = 1.1, // kg/m²
    tail_density: f64 = 0.7, // kg/m²
    boom_density: f64 = 0.12, // kg/m
    fuselage_width: f64 = 0.14, // m
    fuselage_height: f64 = 0.16, // m
    fuselage_drag: f64 = 0.04, // C_D da fuselagem (área molhada)
    fuselage_density: f64 = 0.7, // kg/m
    systems_mass: f64 = 0.35, // kg
    gear_mass: f64 = 0.35, // kg
    nose_length: f64 = 0.30, // m
    wing_height: f64 = -0.10, // m (− = acima da fuselagem)
    propeller_clearance: f64 = 0.05, // m
    main_gear_aft: f64 = 0.06, // m
    track: f64 = 0.45, // m
    elevator_up: f64 = 20, // °
    elevator_down: f64 = 15, // °
    aileron_up: f64 = 20, // °
    aileron_down: f64 = 12, // °
};

/// os motores escolhidos para as variáveis de projeto (o `PowerParams` da GUI; a etapa Motores ainda vai usar)
pub const Power = struct {
    motor: Name = Name.of("Scorpion A-5025-310Kv"),
    propeller: Name = Name.of("APC 15x8E"),
    layout: Name = Name.of("tratora no nariz"),
    tilt: f64 = 0, // °
    wing_motors: f64 = 2,
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

/// uma partição da tabela da asa, com o perfil pelo nome (vazio = o da raiz), o `WingPartition` da GUI
pub const WingPartition = struct {
    span: f64 = 1,
    chord: f64 = 0.3,
    taper: f64 = 1,
    airfoil: Name = .{},
    offset: f64 = 0,
    twist: f64 = 0,
};

/// a asa como se decide na etapa Asa (o `WingParams` da GUI): o trapézio ou a tabela de partições, o perfil da
/// ponta, o diedro e o ângulo de cruzeiro (no trapézio)
pub const WingParams = struct {
    trapezoid: wing_line.Trapezoid = .{ .taper = 1, .rect_fraction = 1 }, // começa retangular
    table: bool = false, // planta "tabela de seções"
    partitions: [wing_line.max_partitions]WingPartition = undefined,
    partition_count: usize = 0,
    tip: Name = .{}, // o perfil da ponta no trapézio (vazio = o da raiz)
    dihedral: f64 = 2, // °

    /// a tabela vale (planta "tabela" com alguma partição de envergadura)?
    pub fn usesTable(params: *const WingParams) bool {
        if (!params.table) return false;
        for (params.partitions[0..params.partition_count]) |partition| if (partition.span > 0) return true;
        return false;
    }

    /// as partições no formato do núcleo (o perfil de cada uma pelo índice que `airfoilIndex` dá ao nome)
    pub fn corePartitions(params: *const WingParams, out: *[wing_line.max_partitions]wing_line.Partition, context: anytype, comptime airfoilIndex: fn (@TypeOf(context), []const u8) usize) []const wing_line.Partition {
        for (params.partitions[0..params.partition_count], 0..) |partition, k| {
            out[k] = .{ .span = partition.span, .chord = partition.chord, .taper = partition.taper, .airfoil = airfoilIndex(context, partition.airfoil.text()), .offset = partition.offset, .twist = partition.twist };
        }
        return out[0..params.partition_count];
    }

    /// a planta (só a geometria: os perfis não contam)
    pub fn planform(params: *const WingParams) wing_line.Planform {
        if (!params.usesTable()) return wing_line.planformOf(params.trapezoid, false);
        var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
        return wing_line.planformOfPartitions(params.corePartitions(&partitions, {}, struct {
            fn none(_: void, _: []const u8) usize {
                return 0;
            }
        }.none));
    }

    /// acerta os campos que saem dos outros, como `sync` da GUI: na tabela, a envergadura, a área e a corda da
    /// raiz são as da tabela; no trapézio, a área (por corda) ou a corda da raiz (por área)
    pub fn sync(params: *WingParams) void {
        const trapezoid = &params.trapezoid;
        if (params.usesTable()) {
            var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
            for (params.partitions[0..params.partition_count], 0..) |partition, k| partitions[k] = .{ .span = partition.span, .chord = partition.chord, .taper = partition.taper };
            const sum = wing_line.totals(partitions[0..params.partition_count]);
            trapezoid.span = round6(sum.span);
            trapezoid.area = round6(sum.area);
            for (params.partitions[0..params.partition_count]) |partition| {
                if (partition.span > 0) {
                    trapezoid.root_chord = partition.chord;
                    break;
                }
            }
            return;
        }
        const shape = wing_line.planformOf(trapezoid.*, false);
        if (trapezoid.size_by_chord) trapezoid.area = round6(shape.area()) else trapezoid.root_chord = round6(shape.root_chord);
    }

    /// refaz a tabela a partir do trapézio atual (`partitions_from_trapezoid` da GUI)
    pub fn partitionsFromTrapezoid(params: *WingParams, root: []const u8) void {
        var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
        const has_tip = params.tip.len > 0;
        const count = wing_line.partitionsFromTrapezoid(params.trapezoid, @intFromBool(has_tip), &partitions);
        for (partitions[0..count], 0..) |partition, k| {
            params.partitions[k] = .{ .span = partition.span, .chord = partition.chord, .taper = partition.taper, .offset = partition.offset, .twist = partition.twist, .airfoil = if (partition.airfoil == 1) params.tip else Name.of(root) };
        }
        params.partition_count = count;
    }
};

fn round6(value: f64) f64 {
    return @round(value * 1e6) / 1e6;
}

/// uma asa guardada: a asa e o perfil da raiz
pub const SavedWing = struct {
    name: Name,
    wing: WingParams,
    root: Name,
};

pub const Design = struct {
    requirements: Requirements = .{},
    rules: Rules = .{},
    constraints: registry.Constraints = .{},
    variables: [registry.input_count]registry.Variable = registry.defaultVariables(),
    values: registry.Values = registry.no_values, // o que a última etapa que rodou calculou (a coluna "calculado")
    power: Power = .{},
    requirements_open: bool = false, // a janela "Condições e restrições…" pedida por alguma etapa
    airfoils: [max_airfoils]stage.Candidate = undefined,
    airfoil_count: usize = 0,
    library: [max_airfoils]stage.Candidate = undefined, // data/airfoils, sem os NACA
    library_count: usize = 0,
    wing: WingParams = .{}, // a asa em desenho
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
    pub fn keepWing(design: *Design, root: []const u8) bool {
        const saved: SavedWing = .{ .name = design.wing_name, .wing = design.wing, .root = Name.of(root) };
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
        const planform = design.wing.planform();
        return wing_line.reynolds(design.requirements.conditions(design.rules), planform.meanChord());
    }

    /// o resumo da barra de requisitos
    pub fn requirementsSummary(design: *const Design, buffer: []u8) []const u8 {
        return design.requirements.summary(&design.constraints, buffer);
    }

    /// o valor de agora de uma entrada numérica (a coluna "valor (fixo)" das variáveis)
    pub fn inputNumber(design: *const Design, input: registry.Input) f64 {
        const wing = design.wing.trapezoid;
        return switch (input) {
            .wing_span => wing.span,
            .wing_area => wing.area,
            .wing_taper => wing.taper,
            .wing_rect_fraction => wing.rect_fraction,
            .wing_alpha_cruise => wing.alpha_cruise,
            .power_tilt => design.power.tilt,
            .power_motors => design.power.wing_motors,
            .cruise_speed => design.requirements.airspeed,
            .mass => design.requirements.mass,
            else => std.math.nan(f64),
        };
    }

    /// troca o valor de uma entrada numérica
    pub fn setInputNumber(design: *Design, input: registry.Input, value: f64) void {
        const wing = &design.wing.trapezoid;
        switch (input) {
            .wing_span => wing.span = value,
            .wing_area => wing.area = value,
            .wing_taper => wing.taper = value,
            .wing_rect_fraction => wing.rect_fraction = value,
            .wing_alpha_cruise => wing.alpha_cruise = value,
            .power_tilt => design.power.tilt = value,
            .power_motors => design.power.wing_motors = @round(value),
            .cruise_speed => design.requirements.airspeed = value,
            .mass => design.requirements.mass = value,
            else => return,
        }
        design.wing.sync();
        design.touch();
    }

    /// o valor de agora de uma entrada de lista (um nome)
    pub fn inputText(design: *const Design, input: registry.Input) []const u8 {
        return switch (input) {
            .wing_airfoil => design.rootAirfoil(),
            .wing_airfoil_tip => design.wing.tip.text(),
            .power_motor => design.power.motor.text(),
            .power_propeller => design.power.propeller.text(),
            .power_layout => design.power.layout.text(),
            else => "",
        };
    }

    /// troca o valor de uma entrada de lista
    pub fn setInputText(design: *Design, input: registry.Input, value: []const u8) void {
        switch (input) {
            .wing_airfoil => design.setRoot(value),
            .wing_airfoil_tip => design.wing.tip = Name.of(value),
            .power_motor => design.power.motor = Name.of(value),
            .power_propeller => design.power.propeller = Name.of(value),
            .power_layout => design.power.layout = Name.of(value),
            else => return,
        }
        design.touch();
    }

    /// tudo o que uma variável de lista pode escolher (`available` da GUI); escreve os nomes em `out`
    pub fn available(design: *const Design, input: registry.Input, out: [][]const u8) [][]const u8 {
        var count: usize = 0;
        switch (input) {
            .wing_airfoil, .wing_airfoil_tip => {
                for (design.airfoils[0..design.airfoil_count]) |candidate| {
                    if (count == out.len) break;
                    out[count] = candidate.name;
                    count += 1;
                }
                for (design.library[0..design.library_count]) |candidate| {
                    if (count == out.len) break;
                    if (design.find(candidate.name) != null) continue;
                    out[count] = candidate.name;
                    count += 1;
                }
            },
            .power_motor, .power_propeller, .power_layout => {
                const names: []const []const u8 = switch (input) {
                    .power_motor => &registry.catalog_motors,
                    .power_propeller => &registry.catalog_propellers,
                    else => &registry.layouts,
                };
                for (names) |name| {
                    if (count == out.len) break;
                    out[count] = name;
                    count += 1;
                }
            },
            else => {},
        }
        return out[0..count];
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

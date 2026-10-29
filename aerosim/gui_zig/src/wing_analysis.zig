//! A análise das asas do avião aberto (a aba Aerodinâmica → Analisar), em Zig: o mesmo caminho da simulação "Asas"
//! do aerosim em Python (`aerosim/manager/simulations/wings.py` + `CoreLoadMethod.sweep` de
//! `aerosim/aero/span_loads.py`).
//!
//!   1. o avião só com as superfícies escolhidas, sem fuselagem, motores, tanques e carga (`wings_only`);
//!   2. para cada superfície, uma cópia com ela dividida no maior número de faixas por lado que cabe no limite de
//!      painéis do núcleo (`_fit`; na linha sustentadora, faixas mais estreitas na ponta, y = y0 + (y1 − y0)
//!      sen(π t/2), o espaçamento de Phillips e Snyder 2000);
//!   3. os parâmetros do núcleo pelo modelo do AeroDrive (`sim/params.zig`, a porta de `build_model` + tradutor) e a
//!      varredura em α do núcleo (`core/src/loads/sweep.zig`), contando só os painéis da superfície refinada;
//!   4. o resumo do núcleo (C_L de cada superfície e do conjunto, C_L máximo, onde o estol começa).
const std = @import("std");
const core = @import("aerosim");
const aircraft_model = @import("aircraft_model");

const model = aircraft_model.aircraft;
const skeleton = aircraft_model.skeleton;
const panel_params = aircraft_model.params;
const types = core.types;
const sweep = core.sweep;

pub const max_owners = 8;
pub const max_alphas = 128;
pub const max_panels = core.limits.max_surfaces * max_owners;
/// o mais fino por lado que se tenta (`MAX_PER_SIDE` em Python), limitado pelas seções que o modelo aceita
const max_per_side = @min(40, model.limits.sections - 2);

pub const Method = enum { lifting_line, strips };

/// o que a aba pede
pub const Input = struct {
    chosen: [max_owners]bool = [_]bool{false} ** max_owners, // por superfície sustentadora não vertical, na ordem
    airspeed: f64 = 12,
    alpha_start: f64 = -4,
    alpha_end: f64 = 22,
    alpha_step: f64 = 1,
    alpha_load: f64 = 10,
    method: Method = .lifting_line,
};

/// o resultado de um método
pub const Result = struct {
    method: Method = .lifting_line,
    alpha_count: usize = 0,
    alphas_deg: [max_alphas]f64 = undefined,
    owner_count: usize = 0,
    owner_names: [max_owners][]const u8 = undefined,
    owner_lift: [max_alphas * max_owners]f64 = undefined, // N
    owner_area: [max_owners]f64 = undefined,
    owner_chord: [max_owners]f64 = undefined,
    owner_cl: [max_alphas * max_owners]f64 = undefined,
    total_cl: [max_alphas]f64 = undefined,
    summary: sweep.Summary = undefined,
    // os painéis contados (os da superfície refinada de cada rodada), na ordem das rodadas
    panel_count: usize = 0,
    panel_owner: [max_panels]i32 = undefined,
    panel_span: [max_panels]f64 = undefined, // y no corpo (m)
    section_cl: [max_alphas * max_panels]f64 = undefined, // α × painel
    // no α da carga
    load_cl: [max_panels]f64 = undefined,
    load: [max_panels]f64 = undefined, // L' = q c c_l (N/m)
    panel_point: [max_panels][3]f64 = undefined, // ponto do painel no corpo (1/4 da corda média)
    panel_chord: [max_panels]f64 = undefined,
    dynamic_pressure: f64 = 0,
    density: f64 = 0,
    reynolds: f64 = 0, // na corda média da primeira superfície

    /// c_l do painel `panel` no α de índice `alpha`
    pub fn sectionCl(result: *const Result, alpha: usize, panel: usize) f64 {
        return result.section_cl[alpha * max_panels + panel];
    }
};

pub const Error = error{ NoSurface, BadInput, TooManySurfaces } || panel_params.Error || sweep.SweepError || std.mem.Allocator.Error;

/// as superfícies que podem entrar (ligadas, com duas seções ou mais, não verticais), na ordem do avião
pub fn liftingSurfaces(ac: *const model.Aircraft, out: *[max_owners]usize) []usize {
    var count: usize = 0;
    for (ac.surfaces, 0..) |surface, i| {
        if (!surface.enabled or surface.vertical or surface.sections.len < 2) continue;
        if (count == max_owners) break;
        out[count] = i;
        count += 1;
    }
    return out[0..count];
}

/// a escolha padrão de Python: só as asas (`role == "wing"`)
pub fn defaultChoice(ac: *const model.Aircraft) [max_owners]bool {
    var indices: [max_owners]usize = undefined;
    var chosen = [_]bool{false} ** max_owners;
    for (liftingSurfaces(ac, &indices), 0..) |index, k| chosen[k] = std.mem.eql(u8, ac.surfaces[index].role, "wing");
    return chosen;
}

/// roda a análise; `allocator` guarda as cópias do avião (use uma arena)
pub fn run(allocator: std.mem.Allocator, ac: *const model.Aircraft, input: Input, result: *Result) Error!void {
    if (!(input.alpha_step > 0) or !(input.alpha_end >= input.alpha_start) or !(input.airspeed > 0)) return error.BadInput;
    result.* = .{ .method = input.method };
    var alpha: f64 = input.alpha_start;
    while (alpha <= input.alpha_end + 1e-9 and result.alpha_count < max_alphas) : (alpha = input.alpha_start + @as(f64, @floatFromInt(result.alpha_count)) * input.alpha_step) {
        result.alphas_deg[result.alpha_count] = alpha;
        result.alpha_count += 1;
    }
    const alpha_count = result.alpha_count;

    // 1. só as superfícies escolhidas
    var owners_of_surface = [_]i32{-1} ** max_surfaces;
    const wings = try wingsOnly(allocator, ac, input.chosen, &owners_of_surface);
    for (owners_of_surface[0..ac.surfaces.len], 0..) |owner, index| {
        if (owner < 0) continue;
        result.owner_names[@intCast(owner)] = ac.surfaces[index].name;
        result.owner_count = @max(result.owner_count, @as(usize, @intCast(owner)) + 1);
    }
    if (result.owner_count == 0) return error.NoSurface;
    const owner_count = result.owner_count;

    result.density = wings.aircraft.environment.rho;
    result.dynamic_pressure = 0.5 * result.density * input.airspeed * input.airspeed;
    var radians: [max_alphas]f64 = undefined;
    for (result.alphas_deg[0..alpha_count], 0..) |a, i| radians[i] = a * std.math.pi / 180;
    const load_alpha = [_]f64{input.alpha_load * std.math.pi / 180};
    @memset(result.owner_lift[0 .. alpha_count * owner_count], 0);

    // 2 e 3. uma rodada por superfície, refinada sozinha
    var params: types.Params = undefined;
    for (wings.surfaces_mut, 0..) |surface, index| {
        const owner = owners_of_surface[index];
        if (owner < 0 or !surface.enabled) continue;
        const refined = try fit(allocator, &wings.aircraft, index, input.method == .lifting_line, &params);
        var panel_owner = [_]i32{-1} ** core.limits.max_surfaces;
        try markPanels(refined, index, owner, &panel_owner);
        const panel_count: usize = @intCast(params.n_surf);
        if (input.method == .lifting_line) { // a linha sustentadora não linear (`NONLINEAR` em Python)
            params.llt_nonlinear = 1;
            params.llt_viscosity = 2.0;
        }
        core.aero.init(&params);
        core.llt.prepare(&params);

        var lift: [max_alphas * max_owners]f64 = undefined;
        var area: [max_owners]f64 = undefined;
        var chord: [max_owners]f64 = undefined;
        var cl: [max_alphas * core.limits.max_surfaces]f64 = undefined;
        var span: [core.limits.max_surfaces]f64 = undefined;
        const core_method: sweep.Method = if (input.method == .lifting_line) .lifting_line else .strips;
        try sweep.sweep(&params, input.airspeed, radians[0..alpha_count], panel_owner[0..panel_count], owner_count, core_method, .{
            .owner_lift = lift[0 .. alpha_count * owner_count],
            .owner_area = area[0..owner_count],
            .owner_chord = chord[0..owner_count],
            .section_cl = cl[0 .. alpha_count * panel_count],
            .panel_span = span[0..panel_count],
        });
        const k: usize = @intCast(owner);
        for (0..alpha_count) |a| result.owner_lift[a * owner_count + k] = lift[a * owner_count + k];
        result.owner_area[k] = area[k];
        result.owner_chord[k] = chord[k];

        var one_lift: [max_owners]f64 = undefined;
        var one_cl: [core.limits.max_surfaces]f64 = undefined;
        try sweep.sweep(&params, input.airspeed, &load_alpha, panel_owner[0..panel_count], owner_count, core_method, .{
            .owner_lift = one_lift[0..owner_count],
            .owner_area = area[0..owner_count],
            .owner_chord = chord[0..owner_count],
            .section_cl = one_cl[0..panel_count],
            .panel_span = span[0..panel_count],
        });
        for (0..panel_count) |i| {
            if (panel_owner[i] < 0) continue;
            const j = result.panel_count;
            result.panel_owner[j] = panel_owner[i];
            result.panel_span[j] = span[i];
            for (0..alpha_count) |a| result.section_cl[a * max_panels + j] = cl[a * panel_count + i];
            result.load_cl[j] = one_cl[i];
            result.panel_chord[j] = params.surf[i].c;
            result.load[j] = result.dynamic_pressure * params.surf[i].c * one_cl[i]; // L' = q c c_l
            result.panel_point[j] = params.surf[i].r;
            result.panel_count += 1;
        }
    }

    // 4. o resumo do núcleo (o section_cl na forma α × painel contado)
    const panel_count = result.panel_count;
    const packed_cl = try allocator.alloc(f64, alpha_count * panel_count);
    for (0..alpha_count) |a| {
        for (0..panel_count) |j| packed_cl[a * panel_count + j] = result.section_cl[a * max_panels + j];
    }
    result.summary = try sweep.summarize(result.owner_lift[0 .. alpha_count * owner_count], result.owner_area[0..owner_count], result.dynamic_pressure, packed_cl, result.panel_owner[0..panel_count], result.panel_span[0..panel_count], result.total_cl[0..alpha_count], result.owner_cl[0 .. alpha_count * owner_count]);
    result.reynolds = sweep.reynolds(result.density, input.airspeed, result.owner_chord[0], 0);
}

const WingsOnly = struct {
    aircraft: model.Aircraft,
    surfaces_mut: []model.Surface,
};

/// o maior número de superfícies que um avião pode ter aqui
pub const max_surfaces = 64;

/// cópia do avião só com as superfícies escolhidas (`chosen`, na ordem de `liftingSurfaces`), sem fuselagem, sem
/// motores, sem tanques e sem carga (`wings_only` + `strip_aircraft` em Python); `owners` recebe o dono de cada
/// superfície (−1: fora)
pub fn wingsOnly(allocator: std.mem.Allocator, ac: *const model.Aircraft, chosen: [max_owners]bool, owners: *[max_surfaces]i32) Error!*WingsOnly {
    if (ac.surfaces.len > max_surfaces) return error.TooManySurfaces;
    const out = try allocator.create(WingsOnly);
    out.aircraft = ac.*;
    out.surfaces_mut = try allocator.dupe(model.Surface, ac.surfaces);
    out.aircraft.surfaces = out.surfaces_mut;
    out.aircraft.fuselage.enabled = false;
    const units = try allocator.dupe(model.Propulsion, ac.propulsion);
    for (units) |*unit| unit.enabled = false;
    out.aircraft.propulsion = units;
    out.aircraft.tanks = &.{};
    out.aircraft.payload.enabled = false;
    out.aircraft.gear.layout = "custom";
    @memset(owners, -1);
    var indices: [max_owners]usize = undefined;
    var count: i32 = 0;
    for (liftingSurfaces(ac, &indices), 0..) |index, k| {
        if (!chosen[k]) continue;
        owners[index] = count;
        count += 1;
    }
    for (out.surfaces_mut, 0..) |*surface, index| {
        if (owners[index] < 0) surface.enabled = false;
    }
    return out;
}

/// a cópia com a superfície `index` no maior número de faixas por lado que cabe no limite de painéis do núcleo
/// (`_fit`: busca binária); escreve os parâmetros dela em `params`
fn fit(allocator: std.mem.Allocator, ac: *const model.Aircraft, index: usize, tip: bool, params: *types.Params) Error!*const model.Aircraft {
    var low: usize = 1;
    var high: usize = max_per_side;
    var best: ?*const model.Aircraft = null;
    var diagnosis: model.Diag = .{};
    while (low <= high) {
        const middle = (low + high) / 2;
        const candidate = try refineSurface(allocator, ac, index, middle, tip);
        if (panelCount(candidate) <= core.limits.max_surfaces) {
            best = candidate;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    const chosen = best orelse ac;
    try panel_params.fill(chosen, params, &diagnosis);
    return chosen;
}

/// cópia do avião com a superfície `index` em `per_side` faixas, a mesma geometria (`refine_surface`): as seções
/// originais ficam exatas e as novas interpolam corda, recuo e torção. Com perfil por seção, não refina
fn refineSurface(allocator: std.mem.Allocator, ac: *const model.Aircraft, index: usize, per_side: usize, tip: bool) Error!*const model.Aircraft {
    const copy = try allocator.create(model.Aircraft);
    copy.* = ac.*;
    const surfaces = try allocator.dupe(model.Surface, ac.surfaces);
    copy.surfaces = surfaces;
    const surface = &surfaces[index];
    if (surface.sections.len < 2 or model.mixedAirfoils(surface)) return copy;
    var sorted_buffer: [model.limits.sections]model.Section = undefined;
    const sorted = model.sortedSections(surface, &sorted_buffer);
    const y0 = sorted[0].y;
    const y1 = sorted[sorted.len - 1].y;
    var ys: [max_per_side + 1 + model.limits.sections]f64 = undefined;
    var count: usize = 0;
    for (0..per_side + 1) |k| {
        var t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(per_side));
        if (tip) t = @sin(0.5 * std.math.pi * t);
        ys[count] = y0 + (y1 - y0) * t;
        count += 1;
    }
    for (sorted) |q| {
        ys[count] = q.y;
        count += 1;
    }
    std.mem.sort(f64, ys[0..count], {}, std.sort.asc(f64));
    var kept: [ys.len]f64 = undefined;
    var kept_count: usize = 0;
    for (ys[0..count]) |y| {
        if (kept_count == 0 or y - kept[kept_count - 1] > 1e-9) {
            kept[kept_count] = y;
            kept_count += 1;
        } else if (isOriginal(sorted, y)) kept[kept_count - 1] = y; // a seção original fica exata
    }
    if (kept_count > model.limits.sections) return copy;
    const sections = try allocator.alloc(model.Section, kept_count);
    for (kept[0..kept_count], sections) |y, *section| {
        section.* = .{ .y = y, .chord = model.sectionAt(sorted, y, "chord"), .x_offset = model.sectionAt(sorted, y, "x_offset"), .twist = model.sectionAt(sorted, y, "twist") };
    }
    surface.sections = sections;
    return copy;
}

fn isOriginal(sorted: []const model.Section, y: f64) bool {
    for (sorted) |q| if (@abs(q.y - y) < 1e-12) return true;
    return false;
}

/// quantos painéis o núcleo recebe deste avião (a mesma conta de `sim/params.zig`: faixas entre estações, dos dois
/// lados se espelhada, e 3 por perna de dispositivo)
fn panelCount(ac: *const model.Aircraft) usize {
    var total: usize = 0;
    for (ac.surfaces) |*surface| {
        if (!surface.enabled or surface.sections.len < 2) continue;
        total += surfacePanelCount(ac, surface) + devicePanelCount(surface);
    }
    return total;
}

fn surfacePanelCount(ac: *const model.Aircraft, surface: *const model.Surface) usize {
    var buffer: [model.limits.sections * 3]skeleton.Station = undefined;
    const stations = skeleton.stations(ac, surface, &buffer);
    if (stations.len < 2) return 0;
    var strips: usize = 0;
    for (stations[0 .. stations.len - 1], stations[1..]) |a, b| {
        if (b.s - a.s >= 1e-6) strips += 1;
    }
    const sides: usize = if (surface.symmetric and !surface.vertical) 2 else 1;
    return strips * sides;
}

fn devicePanelCount(surface: *const model.Surface) usize {
    if (surface.vertical) return 0;
    var total: usize = 0;
    for (surface.devices) |device| {
        if (!device.enabled or device.height <= 0) continue;
        const parts: usize = if (std.mem.eql(u8, device.kind, "placa")) 2 else 1;
        const sides: usize = if (surface.symmetric) 2 else 1;
        total += parts * 3 * sides;
    }
    return total;
}

/// o dono de cada painel: só os da superfície `index` (sem os dispositivos) contam, com o dono `owner`
fn markPanels(ac: *const model.Aircraft, index: usize, owner: i32, panel_owner: []i32) Error!void {
    var start: usize = 0;
    for (ac.surfaces, 0..) |*surface, i| {
        if (!surface.enabled or surface.sections.len < 2) continue;
        const own = surfacePanelCount(ac, surface);
        if (i == index) {
            if (start + own > panel_owner.len) return error.TooManySurfaces;
            @memset(panel_owner[start .. start + own], owner);
        }
        start += own + devicePanelCount(surface);
    }
}

test "análise das asas: o S1223 de data/aircraft pela linha sustentadora e pelas faixas" {
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "../../data/aircraft/S1223_monomotor_EH_convencional_Joinville.json", std.testing.allocator, .limited(1 << 24)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    var diagnosis: model.Diag = .{};
    var loaded = try model.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try std.testing.allocator.create(Result);
    defer std.testing.allocator.destroy(result);
    var input: Input = .{ .chosen = defaultChoice(&loaded.ac) };
    try run(arena.allocator(), &loaded.ac, input, result);
    try std.testing.expectEqual(@as(usize, 1), result.owner_count);
    try std.testing.expectEqualStrings("asa", result.owner_names[0]);
    // a asa refinada: muitos painéis, todos dela
    try std.testing.expect(result.panel_count >= 20);
    // a 4° (índice 8) o C_L sobe com α e fica abaixo do 2π α da placa plana mais o C_L0 do S1223
    try std.testing.expect(result.total_cl[8] > result.total_cl[6]);
    try std.testing.expect(result.summary.lift_max > 1.0 and result.summary.lift_max < 2.5);
    input.method = .strips;
    const strips = try std.testing.allocator.create(Result);
    defer std.testing.allocator.destroy(strips);
    try run(arena.allocator(), &loaded.ac, input, strips);
    try std.testing.expectApproxEqRel(result.total_cl[8], strips.total_cl[8], 0.15);
    // os mesmos números da GUI em Python (`load_method("llt_nl"/"faixas").sweep` + `wing_sweep_summary`, V = 12 m/s,
    // só a asa), rodados em 2026-10-29: C_L a 4° e o C_L máximo (a 15°)
    try std.testing.expectApproxEqAbs(@as(f64, 1.1609), result.total_cl[8], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 2.1584), result.summary.lift_max, 1e-3);
    try std.testing.expectEqual(@as(usize, 19), result.summary.peak);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0975), strips.total_cl[8], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0226), strips.summary.lift_max, 1e-3);
    // asa e EH juntas: dois donos, cada um com os painéis dele, e o C_L do conjunto entre os dois
    input.method = .lifting_line;
    input.chosen[1] = true;
    try run(arena.allocator(), &loaded.ac, input, strips);
    try std.testing.expectEqual(@as(usize, 2), strips.owner_count);
    try std.testing.expectEqualStrings("EH", strips.owner_names[1]);
    try std.testing.expect(strips.owner_area[1] > 0 and strips.owner_area[1] < strips.owner_area[0]);
    for (strips.panel_owner[0..strips.panel_count]) |owner| try std.testing.expect(owner == 0 or owner == 1);
}

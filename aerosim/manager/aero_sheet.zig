//! A planilha de aerodinâmica que o programa gera depois de simular, no formato das planilhas de aerodinâmica das
//! equipes: na aba "Aerodin", um bloco por asa, lado a lado, com
//!
//! - a faixa do título com o nome da asa;
//! - os parâmetros (ambiente: V, ρ, ν e o Reynolds da CMA; asa: envergadura e partições, cordas, afilamento,
//!   perfis, altura do CA ao solo, área, alongamento, recuos, CA, CMA, C_Lmax, C_Lα, C_L0, C_Di0, α de estol,
//!   C_mac, Oswald e corda média geométrica), com o rótulo em rosa, o símbolo e a unidade, os dados do projeto em
//!   azul e o que sai da conta em verde;
//! - a sustentação no estol e em α = 0 (N);
//! - os coeficientes em cada α (C_Di, C_m, C_L, C_Dp, C_D e C_L/C_D), com o α de estol marcado;
//! - a distribuição de sustentação (o c_l de cada estação da raiz para a ponta em cada α);
//! - os gráficos de C_L × α e da polar.
//!
//! Os números saem da asa sozinha (sem fuselagem nem hélice) pela análise "Analisar" (`wings.surfaceSheet`): o C_L
//! e o c_l por estação da linha sustentadora não linear (com o estol), o C_Di, o C_m e o C_D da polar das faixas;
//! aqui só se arruma em células.
const std = @import("std");
const core = @import("aerosim");
const simulation = @import("simulation");
const wings = @import("simulations/wings.zig");
const aerodynamics = @import("simulations/aerodynamics.zig");

const writer = core.xlsx_writer;
const wing_line = core.wing_line;
const deg = 180.0 / std.math.pi;

/// a faixa de α das tabelas (°), de grau em grau, como nas planilhas
pub const alpha_first = -5.0;
pub const alpha_last = 20.0;

const title_top = 2; // a faixa do título vai da linha 2 à 5
const title_bottom = 5;
const header_row = 7; // os nomes das colunas; os números a partir da 9
const first_data_row = 9;
const block_gap = 2; // colunas vazias entre um bloco e o seguinte

/// se a superfície `index` entra na planilha: `include` tem uma entrada por superfície do avião (null: todas)
pub fn included(include: ?[]const bool, index: usize) bool {
    const chosen = include orelse return true;
    return index < chosen.len and chosen[index];
}

/// a pasta de trabalho da aerodinâmica do avião (uma asa por bloco, na velocidade de cruzeiro); devolve os bytes.
/// `include` diz que superfícies entram (uma entrada por superfície do avião; null: todas); a conta é sempre a do
/// avião inteiro, só o que se mostra muda
pub fn workbook(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, include: ?[]const bool) ![]const u8 {
    var run: simulation.Run = .{ .arena = .init(memory), .aircraft = aircraft };
    const count: usize = @intFromFloat(alpha_last - alpha_first + 1);
    const alphas = try memory.alloc(f64, count);
    for (alphas, 0..) |*alpha, k| alpha.* = alpha_first + @as(f64, @floatFromInt(k));
    const airspeed = cruiseSpeed(aircraft);

    var sheet = writer.Sheet{ .name = "Aerodin" };
    var left: u32 = 2;
    for (aircraft.surfaces, 0..) |surface, index| {
        if (!surface.enabled or surface.vertical or !std.mem.eql(u8, surface.role, "wing") or !included(include, index)) continue;
        const result = wings.surfaceSheet(&run, index, airspeed, alphas) catch continue;
        left = try wingBlock(memory, &sheet, left, surface, result) + block_gap;
    }
    const polars = try polarSheet(memory, &run, aircraft, airspeed, alphas, include);
    var sheets = [_]writer.Sheet{ sheet, polars };
    return writer.write(memory, &sheets);
}

/// a linha dos títulos e a primeira linha de números da aba de polares
const polar_header_row = 6;
const polar_first_row = 7;

/// o que a aba de polares guarda de uma superfície: onde ela está na lista do avião, o sufixo das colunas (o da
/// planilha da equipe, "w", "h" ou "v", quando ela é a única do papel; o nome dela, quando há outras) e se ela
/// ganha as colunas na própria área ("nPond")
const PolarSurface = struct {
    index: usize,
    suffix: []const u8,
    own_area_columns: bool,
    vertical: bool,
};

/// as superfícies ligadas e escolhidas, as horizontais primeiro, na ordem da lista do avião
fn polarSurfaces(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, include: ?[]const bool) ![]PolarSurface {
    var list: std.ArrayList(PolarSurface) = .empty;
    for ([_]bool{ false, true }) |vertical_pass| {
        for (aircraft.surfaces, 0..) |surface, index| {
            if (!surface.enabled or surface.vertical != vertical_pass or !included(include, index)) continue;
            var same_role: usize = 0;
            for (aircraft.surfaces) |other| same_role += @intFromBool(other.enabled and std.mem.eql(u8, other.role, surface.role));
            const letter: []const u8 = if (std.mem.eql(u8, surface.role, "wing")) "w" else if (std.mem.eql(u8, surface.role, "htail")) "h" else if (std.mem.eql(u8, surface.role, "vtail")) "v" else surface.name;
            const suffix = if (same_role == 1) letter else try std.fmt.allocPrint(memory, " {s}", .{surface.name});
            try list.append(memory, .{ .index = index, .suffix = suffix, .own_area_columns = !surface.vertical and !std.mem.eql(u8, surface.role, "wing"), .vertical = surface.vertical });
        }
    }
    return list.items;
}

/// uma coluna da aba de polares: o título e o valor em cada α
const PolarColumn = struct {
    name: []const u8,
    values: []f64,
};

/// "Polares <avião>": o avião inteiro separado por superfície em cada α (cada asa, cada EH, a fuselagem e cada EV,
/// como na planilha da equipe, que tem uma de cada), com as áreas e as incidências no alto e os gráficos de
/// sustentação, arrasto e da polar ao lado
fn polarSheet(memory: std.mem.Allocator, run: *simulation.Run, aircraft: *const simulation.Aircraft, airspeed: f64, alphas: []const f64, include: ?[]const bool) !writer.Sheet {
    var sheet = writer.Sheet{ .name = try writer.sheetName(memory, try std.fmt.allocPrint(memory, "Polares {s}", .{aircraft.name})) };
    const found = try aerodynamics.surfacePolar(run, aircraft.*, airspeed, alphas);
    const surfaces = try polarSurfaces(memory, aircraft, include);
    const nan = std.math.nan(f64);
    const body = core.limits.groupIndex(.fuselage);
    const first_area = if (found.len > 0) found[0].area else &[_]f64{};
    const first_group = if (found.len > 0) found[0].group else core.aero.GroupCoeffs{};
    const wing_area = first_group.area[core.limits.groupIndex(.wing)];

    // as áreas e as incidências das superfícies horizontais, uma por coluna de quatro
    var top_column: u32 = 1;
    for (surfaces) |entry| {
        if (entry.vertical) continue;
        const surface = aircraft.surfaces[entry.index];
        try sheet.text(memory, 1, top_column, try std.fmt.allocPrint(memory, "S{s} (m²)", .{entry.suffix}), .header);
        try sheet.number(memory, 1, top_column + 1, if (entry.index < first_area.len) first_area[entry.index] else nan, .blue_value);
        try sheet.text(memory, 3, top_column, try std.fmt.allocPrint(memory, "Incidência {s} (°)", .{surface.name}), .header);
        try sheet.number(memory, 3, top_column + 1, surface.incidence, .blue_value);
        top_column += 3;
    }
    try sheet.text(memory, 1, top_column + 1, try std.fmt.allocPrint(memory, "V = {d:.1} m/s; coeficientes na área da asa, pelas faixas do núcleo", .{airspeed}), .normal);

    // as colunas: α do avião, cada superfície horizontal, a fuselagem, cada vertical e o avião inteiro
    var columns: std.ArrayList(PolarColumn) = .empty;
    const Builder = struct {
        memory: std.mem.Allocator,
        columns: *std.ArrayList(PolarColumn),
        count: usize,
        fn add(self: @This(), name: []const u8) ![]f64 {
            const values = try self.memory.alloc(f64, self.count);
            try self.columns.append(self.memory, .{ .name = name, .values = values });
            return values;
        }
    };
    const builder: Builder = .{ .memory = memory, .columns = &columns, .count = alphas.len };
    const plane_alpha = try builder.add("α avião");
    @memcpy(plane_alpha, alphas);
    var lift_columns: std.ArrayList(usize) = .empty;
    var drag_columns: std.ArrayList(usize) = .empty;
    for (surfaces) |entry| {
        if (entry.vertical) continue;
        const own_area = if (entry.index < first_area.len) first_area[entry.index] else 0;
        const ratio = if (own_area > 0) wing_area / own_area else nan;
        const alpha_column = try builder.add(try std.fmt.allocPrint(memory, "α{s}", .{entry.suffix}));
        try lift_columns.append(memory, columns.items.len);
        const lift = try builder.add(try std.fmt.allocPrint(memory, "CL{s}", .{entry.suffix}));
        const lift_own = if (entry.own_area_columns) try builder.add(try std.fmt.allocPrint(memory, "CL{s}(nPond)", .{entry.suffix})) else try memory.alloc(f64, 0);
        const induced = try builder.add(try std.fmt.allocPrint(memory, "CDi{s}", .{entry.suffix}));
        const induced_own = if (entry.own_area_columns) try builder.add(try std.fmt.allocPrint(memory, "CDi{s}(nPond)", .{entry.suffix})) else try memory.alloc(f64, 0);
        const parasite = try builder.add(try std.fmt.allocPrint(memory, "CDp{s}", .{entry.suffix}));
        try drag_columns.append(memory, columns.items.len);
        const drag = try builder.add(try std.fmt.allocPrint(memory, "CD{s}", .{entry.suffix}));
        for (found, 0..) |item, k| {
            alpha_column[k] = item.alpha[entry.index] * deg;
            lift[k] = item.lift[entry.index];
            induced[k] = item.induced[entry.index];
            parasite[k] = item.drag[entry.index] - item.induced[entry.index];
            drag[k] = item.drag[entry.index];
            if (entry.own_area_columns) {
                lift_own[k] = lift[k] * ratio;
                induced_own[k] = induced[k] * ratio;
            }
        }
    }
    try drag_columns.append(memory, columns.items.len);
    const body_drag = try builder.add("CDf");
    for (found, 0..) |item, k| body_drag[k] = item.group.drag[body];
    for (surfaces) |entry| {
        if (!entry.vertical) continue;
        const drag = try builder.add(try std.fmt.allocPrint(memory, "CD{s}", .{entry.suffix}));
        for (found, 0..) |item, k| drag[k] = item.drag[entry.index];
    }
    const plane_alpha_again = try builder.add("α avião");
    @memcpy(plane_alpha_again, alphas);
    const total_lift_column = columns.items.len;
    const total_lift = try builder.add("CL global");
    const total_drag_column = columns.items.len;
    const total_drag = try builder.add("CD global");
    const radians = try builder.add("α (rad)");
    const normal = try builder.add("CN global");
    const efficiency = try builder.add("CL/CD");
    for (found, alphas, 0..) |item, alpha, k| {
        total_lift[k] = item.group.total.CL;
        total_drag[k] = item.group.total.CD;
        radians[k] = alpha / deg;
        normal[k] = item.group.total.CN;
        efficiency[k] = if (total_drag[k] > 0) total_lift[k] / total_drag[k] else nan;
    }

    // a tabela
    const right: u32 = @intCast(columns.items.len);
    try sheet.text(memory, 5, 1, try std.fmt.allocPrint(memory, "Polares {s}", .{aircraft.name}), .light_green_value);
    try sheet.merge(memory, 5, 1, 5, right, .light_green_value);
    for (columns.items, 1..) |column, number| {
        const at: u32 = @intCast(number);
        try sheet.text(memory, polar_header_row, at, column.name, .pink_label);
        try sheet.width(memory, at, 11);
        const is_alpha = std.mem.eql(u8, column.name, "α avião");
        for (column.values, 0..) |value, k| try sheet.number(memory, polar_first_row + @as(u32, @intCast(k)), at, value, if (is_alpha) .cyan_label else .number);
    }

    // os gráficos: uma curva por superfície horizontal, a fuselagem no arrasto e o avião inteiro
    const last_row = polar_first_row + @as(u32, @intCast(alphas.len)) - 1;
    const chart_left = right + 2;
    const series = struct {
        fn of(name: []const u8, x: u32, y: u32, last: u32) writer.ChartSeries {
            return .{ .name = name, .x_column = x, .y_column = y, .first_row = polar_first_row, .last_row = last };
        }
    }.of;
    var lift_series: std.ArrayList(writer.ChartSeries) = .empty;
    var horizontal: usize = 0;
    for (surfaces) |entry| {
        if (entry.vertical) continue;
        try lift_series.append(memory, series(aircraft.surfaces[entry.index].name, 1, @intCast(lift_columns.items[horizontal] + 1), last_row));
        horizontal += 1;
    }
    try lift_series.append(memory, series("avião", 1, @intCast(total_lift_column + 1), last_row));
    var drag_series: std.ArrayList(writer.ChartSeries) = .empty;
    horizontal = 0;
    for (surfaces) |entry| {
        if (entry.vertical) continue;
        try drag_series.append(memory, series(aircraft.surfaces[entry.index].name, 1, @intCast(drag_columns.items[horizontal] + 1), last_row));
        horizontal += 1;
    }
    try drag_series.append(memory, series("fuselagem", 1, @intCast(drag_columns.items[horizontal] + 1), last_row));
    try drag_series.append(memory, series("avião", 1, @intCast(total_drag_column + 1), last_row));
    try sheet.chart(memory, .{ .title = "Sustentação", .x_label = "α (°)", .y_label = "C_L", .series = lift_series.items, .from_column = chart_left, .from_row = 2, .to_column = chart_left + 8, .to_row = 20 });
    try sheet.chart(memory, .{ .title = "Arrasto", .x_label = "α (°)", .y_label = "C_D", .series = drag_series.items, .from_column = chart_left + 9, .from_row = 2, .to_column = chart_left + 17, .to_row = 20 });
    try sheet.chart(memory, .{
        .title = "Polar",
        .x_label = "C_D",
        .y_label = "C_L",
        .series = try memory.dupe(writer.ChartSeries, &.{series("avião", @intCast(total_drag_column + 1), @intCast(total_lift_column + 1), last_row)}),
        .from_column = chart_left,
        .from_row = 22,
        .to_column = chart_left + 8,
        .to_row = 40,
    });
    return sheet;
}

/// a velocidade das tabelas: a de cruzeiro do avião (a mesma do "avião completo" do Analisar)
fn cruiseSpeed(aircraft: *const simulation.Aircraft) f64 {
    return aerodynamics.cruise(aircraft);
}

/// a planta da superfície (as seções da raiz para a ponta), para área, CMA e CA
fn planformOf(surface: simulation.Surface) wing_line.Planform {
    var planform: wing_line.Planform = .{ .semispan = 0, .break_y = 0, .root_chord = 0, .tip_chord = 0 };
    const count = @min(surface.sections.len, planform.sections.len);
    for (surface.sections[0..count], 0..) |section, k| planform.sections[k] = .{ .y = section.y, .chord = section.chord, .offset = section.x_offset, .twist = section.twist };
    planform.count = count;
    if (count > 0) {
        planform.root_chord = surface.sections[0].chord;
        planform.tip_chord = surface.sections[count - 1].chord;
        planform.semispan = surface.sections[count - 1].y;
    }
    return planform;
}

/// uma linha de parâmetro: nome, símbolo e unidade
fn label(memory: std.mem.Allocator, sheet: *writer.Sheet, row: u32, left: u32, name: []const u8, symbol: []const u8, unit: []const u8) !void {
    try sheet.text(memory, row, left, name, .pink_label);
    try sheet.text(memory, row, left + 1, symbol, .cyan_label);
    try sheet.text(memory, row, left + 2, unit, .yellow_label);
}

/// um parâmetro com um valor só, em azul (dado) ou verde (calculado)
fn parameter(memory: std.mem.Allocator, sheet: *writer.Sheet, row: u32, left: u32, name: []const u8, symbol: []const u8, unit: []const u8, value: f64, calculated: bool) !void {
    try label(memory, sheet, row, left, name, symbol, unit);
    try sheet.number(memory, row, left + 3, value, if (calculated) .light_green_value else .blue_value);
}

/// o bloco de uma asa a partir da coluna `left`; devolve a última coluna usada
fn wingBlock(memory: std.mem.Allocator, sheet: *writer.Sheet, left: u32, surface: simulation.Surface, result: wings.SurfaceSheet) !u32 {
    const station_count: u32 = @intCast(result.stations.len);
    const coefficients_left = left + 8; // α, C_Di, C_m, C_L, C_Dp, C_D, C_L/C_D
    const distribution_left = coefficients_left + 8; // α e uma coluna por estação
    const right = distribution_left + station_count;

    // o título
    try sheet.merge(memory, title_top, left, title_bottom, right, .wing_title);
    try sheet.text(memory, title_top, left, surface.name, .wing_title);

    // os parâmetros
    for ([_][]const u8{ "Parâmetro", "Símbolo", "Unidade", "Valor" }, 0..) |name, k| try sheet.text(memory, header_row, left + @as(u32, @intCast(k)), name, .boxed);
    try sheet.merge(memory, 8, left, 8, left + 3, .boxed);
    try sheet.text(memory, 8, left, "Ambiente", .boxed);
    const planform = planformOf(surface);
    const mac = planform.meanChord();
    const viscosity = core.sweep.airViscosity(core.sweep.isaTemperature(result.density_altitude)) / result.density;
    try parameter(memory, sheet, 9, left, "Velocidade", "V", "[m/s]", result.airspeed, false);
    try parameter(memory, sheet, 10, left, "Densidade", "ρ", "[kg/m³]", result.density, false);
    try parameter(memory, sheet, 11, left, "Viscosidade cinemática", "ν", "[1e-5 m²/s]", viscosity * 1e5, true);
    try parameter(memory, sheet, 12, left, "Reynolds (CMA)", "Re", "-", result.airspeed * mac / viscosity, true);

    try sheet.merge(memory, 14, left, 14, left + 2, .boxed);
    try sheet.text(memory, 14, left, "Asa", .boxed);
    try sheet.text(memory, 14, left + 3, "Total / partições", .boxed);
    const sections = surface.sections;
    const span = 2 * planform.semispan;
    const area = planform.area();
    // envergadura: a total e o comprimento de cada partição (da raiz para a ponta)
    try parameter(memory, sheet, 15, left, "Envergadura", "b", "[m]", span, false);
    for (sections[1..@max(sections.len, 1)], 1..) |section, k| try sheet.number(memory, 15, left + 3 + @as(u32, @intCast(k)), section.y - sections[k - 1].y, .blue_value);
    try label(memory, sheet, 16, left, "Corda", "c", "[m]");
    for (sections, 0..) |section, k| try sheet.number(memory, 16, left + 3 + @as(u32, @intCast(k)), section.chord, .blue_value);
    try parameter(memory, sheet, 17, left, "Afilamento", "λ", "-", if (planform.root_chord > 0) planform.tip_chord / planform.root_chord else std.math.nan(f64), true);
    try label(memory, sheet, 18, left, "Perfil", "perfil", "-");
    for (sections, 0..) |section, k| {
        const airfoil = if (section.airfoil) |own| own.name else surface.airfoil.name;
        try sheet.text(memory, 18, left + 3 + @as(u32, @intCast(k)), airfoil, .blue_value);
    }
    if (sections.len == 0) try sheet.text(memory, 18, left + 3, surface.airfoil.name, .blue_value);
    try parameter(memory, sheet, 19, left, "Altura do CA ao solo", "z", "[m]", surface.z, false);
    try parameter(memory, sheet, 20, left, "Área", "S", "[m²]", area, true);
    try parameter(memory, sheet, 21, left, "Alongamento", "AR", "-", span * span / area, true);
    try label(memory, sheet, 22, left, "Recuos", "offset", "[m]");
    for (sections, 0..) |section, k| try sheet.number(memory, 22, left + 3 + @as(u32, @intCast(k)), section.x_offset, .blue_value);
    try parameter(memory, sheet, 23, left, "Posição do CA da asa", "x_CA", "% c raiz", if (planform.root_chord > 0) 100 * planform.aeroCenter() / planform.root_chord else std.math.nan(f64), true);
    try parameter(memory, sheet, 24, left, "Corda média aerodinâmica", "CMA", "[m]", mac, true);
    const metrics = result.metrics;
    const nan = std.math.nan(f64);
    try parameter(memory, sheet, 25, left, "C_Lmax", "", "-", metrics.lift_max orelse nan, true);
    try parameter(memory, sheet, 26, left, "C_Lα", "", "1/°", if (metrics.lift_slope) |slope| slope / deg else nan, true);
    try parameter(memory, sheet, 27, left, "C_L0", "", "-", metrics.lift_zero orelse nan, true);
    const zero = indexOf(result.alphas, 0);
    try parameter(memory, sheet, 28, left, "C_Di0", "", "-", if (zero) |k| result.induced[k] else nan, true);
    try parameter(memory, sheet, 29, left, "α de estol", "", "°", metrics.alpha_stall orelse nan, true);
    try parameter(memory, sheet, 30, left, "C_mac", "", "-", if (zero) |k| result.moment[k] else nan, true);
    try parameter(memory, sheet, 31, left, "Número de Oswald", "e", "-", metrics.oswald orelse nan, true);
    try parameter(memory, sheet, 32, left, "Corda média geométrica", "c̄", "[m]", if (span > 0) area / span else nan, true);
    try sheet.text(memory, 34, left, "C_L e c_l: linha sustentadora não linear do núcleo; C_Di, C_m e C_D: faixas", .normal);

    // a sustentação em α = 0 e no estol (N)
    const dynamic_pressure = 0.5 * result.density * result.airspeed * result.airspeed;
    try sheet.text(memory, header_row, left + 5, "Sustentação 0 (N)", .header);
    try sheet.text(memory, header_row, left + 6, "Sustentação máx. (N)", .header);
    try sheet.number(memory, 8, left + 5, if (metrics.lift_zero) |lift| dynamic_pressure * area * lift else nan, .light_green_value);
    try sheet.number(memory, 8, left + 6, if (metrics.lift_max) |lift| dynamic_pressure * area * lift else nan, .light_green_value);

    // os coeficientes em cada α
    try sheet.merge(memory, header_row, coefficients_left, header_row, coefficients_left + 6, .header);
    try sheet.text(memory, header_row, coefficients_left, "Coeficientes", .header);
    for ([_][]const u8{ "α (°)", "C_Di", "C_m", "C_L", "C_Dp", "C_D", "C_L/C_D" }, 0..) |name, k| try sheet.text(memory, 8, coefficients_left + @as(u32, @intCast(k)), name, .header);
    for (result.alphas, 0..) |alpha, k| {
        const row = first_data_row + @as(u32, @intCast(k));
        const drag = result.drag[k];
        try sheet.number(memory, row, coefficients_left, alpha, .number);
        try sheet.number(memory, row, coefficients_left + 1, result.induced[k], .number);
        try sheet.number(memory, row, coefficients_left + 2, result.moment[k], .number);
        try sheet.number(memory, row, coefficients_left + 3, result.lift[k], .number);
        try sheet.number(memory, row, coefficients_left + 4, drag - result.induced[k], .number);
        try sheet.number(memory, row, coefficients_left + 5, drag, .number);
        try sheet.number(memory, row, coefficients_left + 6, if (drag > 0) result.lift[k] / drag else nan, .number);
        if (metrics.alpha_stall) |stall| if (alpha == stall) try sheet.text(memory, row, coefficients_left - 1, "Estol", .header);
    }

    // a distribuição de sustentação: uma linha por α, uma coluna por estação (y no cabeçalho)
    try sheet.merge(memory, header_row, distribution_left, header_row, right, .header);
    try sheet.text(memory, header_row, distribution_left, "Distribuição de sustentação (c_l; y em m no cabeçalho)", .header);
    try sheet.text(memory, 8, distribution_left, "α (°)", .header);
    for (result.stations, 0..) |y, j| try sheet.text(memory, 8, distribution_left + 1 + @as(u32, @intCast(j)), try std.fmt.allocPrint(memory, "{d:.3}", .{y}), .header);
    for (result.alphas, 0..) |alpha, k| {
        const row = first_data_row + @as(u32, @intCast(k));
        try sheet.number(memory, row, distribution_left, alpha, .number);
        for (0..result.stations.len) |j| try sheet.number(memory, row, distribution_left + 1 + @as(u32, @intCast(j)), result.section_cl[k * result.stations.len + j], .number);
    }

    // larguras e gráficos
    for ([_]f32{ 26, 9, 10, 13, 11, 16, 18 }, 0..) |characters, k| try sheet.width(memory, left + @as(u32, @intCast(k)), characters);
    const last_row = first_data_row + @as(u32, @intCast(result.alphas.len)) - 1;
    const chart_top = last_row + 3;
    try sheet.chart(memory, .{
        .title = "Sustentação",
        .x_label = "α (°)",
        .y_label = "C_L",
        .series = try memory.dupe(writer.ChartSeries, &.{.{ .name = surface.name, .x_column = coefficients_left, .y_column = coefficients_left + 3, .first_row = first_data_row, .last_row = last_row }}),
        .from_column = coefficients_left,
        .from_row = chart_top,
        .to_column = coefficients_left + 7,
        .to_row = chart_top + 18,
    });
    try sheet.chart(memory, .{
        .title = "Polar",
        .x_label = "C_D",
        .y_label = "C_L",
        .series = try memory.dupe(writer.ChartSeries, &.{.{ .name = surface.name, .x_column = coefficients_left + 5, .y_column = coefficients_left + 3, .first_row = first_data_row, .last_row = last_row }}),
        .from_column = coefficients_left + 8,
        .from_row = chart_top,
        .to_column = coefficients_left + 15,
        .to_row = chart_top + 18,
    });
    return right;
}

/// o índice de `value` na lista (null se não estiver)
fn indexOf(list: []const f64, value: f64) ?usize {
    for (list, 0..) |item, k| if (item == value) return k;
    return null;
}

test "a planilha de aerodinâmica do avião de exemplo: um bloco por asa, coeficientes e distribuição" {
    const aircraft_model = @import("aircraft_model");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../data/aircraft/Convencional_original.aero", memory, .limited(1 << 24));
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    const book = try core.xlsx.Workbook.parse(memory, try workbook(memory, &loaded.ac, null));
    try std.testing.expectEqual(@as(usize, 2), book.sheets.len);
    try std.testing.expectEqualStrings("Aerodin", book.sheets[0].name);
    // o bloco da asa começa em B: o título em B2 e "Parâmetro" em B7
    const corner = book.cell("Aerodin", "B7") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Parâmetro", corner.text);
}

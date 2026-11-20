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

/// a pasta de trabalho da aerodinâmica do avião (uma asa por bloco, na velocidade de cruzeiro); devolve os bytes
pub fn workbook(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft) ![]const u8 {
    var run: simulation.Run = .{ .arena = .init(memory), .aircraft = aircraft };
    const count: usize = @intFromFloat(alpha_last - alpha_first + 1);
    const alphas = try memory.alloc(f64, count);
    for (alphas, 0..) |*alpha, k| alpha.* = alpha_first + @as(f64, @floatFromInt(k));
    const airspeed = cruiseSpeed(aircraft);

    var sheet = writer.Sheet{ .name = "Aerodin" };
    var left: u32 = 2;
    for (aircraft.surfaces, 0..) |surface, index| {
        if (!surface.enabled or surface.vertical or !std.mem.eql(u8, surface.role, "wing")) continue;
        const result = wings.surfaceSheet(&run, index, airspeed, alphas) catch continue;
        left = try wingBlock(memory, &sheet, left, surface, result) + block_gap;
    }
    const polars = try polarSheet(memory, &run, aircraft, airspeed, alphas);
    var sheets = [_]writer.Sheet{ sheet, polars };
    return writer.write(memory, &sheets);
}

/// as colunas da aba de polares, na ordem da planilha da equipe ("nPond": na área do próprio EH, não na da asa)
const polar_headers = [_][]const u8{ "α avião", "α asa", "CLw", "CDiw", "CDpw", "CDw", "α EH", "CLh", "CLh(nPond)", "CDih", "CDih(nPond)", "CDph", "CDh", "CDf", "CDv", "α avião", "CL global", "CD global", "α (rad)", "CN global", "CL/CD" };
const polar_header_row = 6;
const polar_first_row = 7;

/// "Polares <avião>": o avião inteiro (fuselagem, EH e EV) separado por componente em cada α, com as áreas e as
/// incidências no alto e os gráficos de sustentação, arrasto e da polar ao lado
fn polarSheet(memory: std.mem.Allocator, run: *simulation.Run, aircraft: *const simulation.Aircraft, airspeed: f64, alphas: []const f64) !writer.Sheet {
    var sheet = writer.Sheet{ .name = try writer.sheetName(memory, try std.fmt.allocPrint(memory, "Polares {s}", .{aircraft.name})) };
    const found = try aerodynamics.componentPolar(run, aircraft.*, airspeed, alphas);
    const wing = core.limits.groupIndex(.wing);
    const tail = core.limits.groupIndex(.htail);
    const fin = core.limits.groupIndex(.vtail);
    const body = core.limits.groupIndex(.fuselage);
    const nan = std.math.nan(f64);
    const first = if (found.len > 0) found[0] else core.aero.GroupCoeffs{};
    const wing_area = first.area[wing];
    const tail_area = first.area[tail];
    // as áreas e as incidências da asa e do EH (a primeira superfície de cada papel)
    var wing_incidence: f64 = nan;
    var tail_incidence: f64 = nan;
    for (aircraft.surfaces) |surface| {
        if (!surface.enabled or surface.vertical) continue;
        if (std.mem.eql(u8, surface.role, "wing") and std.math.isNan(wing_incidence)) wing_incidence = surface.incidence;
        if (!std.mem.eql(u8, surface.role, "wing") and std.math.isNan(tail_incidence)) tail_incidence = surface.incidence;
    }
    try sheet.text(memory, 1, 1, "Sw (m²)", .header);
    try sheet.number(memory, 1, 2, wing_area, .blue_value);
    try sheet.text(memory, 1, 3, "Incidência asa (°)", .header);
    try sheet.number(memory, 1, 4, wing_incidence, .blue_value);
    try sheet.text(memory, 3, 1, "Sh (m²)", .header);
    try sheet.number(memory, 3, 2, tail_area, .blue_value);
    try sheet.text(memory, 3, 3, "Incidência EH (°)", .header);
    try sheet.number(memory, 3, 4, tail_incidence, .blue_value);
    try sheet.text(memory, 1, 6, try std.fmt.allocPrint(memory, "V = {d:.1} m/s; coeficientes na área da asa, pelas faixas do núcleo", .{airspeed}), .normal);

    const right: u32 = polar_headers.len;
    try sheet.text(memory, 5, 1, try std.fmt.allocPrint(memory, "Polares {s}", .{aircraft.name}), .light_green_value);
    try sheet.merge(memory, 5, 1, 5, right, .light_green_value);
    for (polar_headers, 1..) |name, column| {
        try sheet.text(memory, polar_header_row, @intCast(column), name, .pink_label);
        try sheet.width(memory, @intCast(column), 11);
    }
    const ratio_tail = if (tail_area > 0) wing_area / tail_area else nan;
    for (alphas, found, 0..) |alpha, item, k| {
        const row = polar_first_row + @as(u32, @intCast(k));
        const lift = item.total.CL;
        const drag = item.total.CD;
        const values = [_]f64{
            alpha,                                        item.alpha[wing] * deg,      item.lift[wing],         item.induced[wing],
            item.drag[wing] - item.induced[wing],          item.drag[wing],             item.alpha[tail] * deg,  item.lift[tail],
            item.lift[tail] * ratio_tail,                  item.induced[tail],          item.induced[tail] * ratio_tail, item.drag[tail] - item.induced[tail],
            item.drag[tail],                               item.drag[body],             item.drag[fin],          alpha,
            lift,                                          drag,                        alpha / deg,             item.total.CN,
            if (drag > 0) lift / drag else nan,
        };
        for (values, 1..) |value, column| try sheet.number(memory, row, @intCast(column), value, if (column == 1 or column == 16) .cyan_label else .number);
    }
    const last_row = polar_first_row + @as(u32, @intCast(alphas.len)) - 1;
    const chart_left = right + 2;
    const series = struct {
        fn of(name: []const u8, x: u32, y: u32, last: u32) writer.ChartSeries {
            return .{ .name = name, .x_column = x, .y_column = y, .first_row = polar_first_row, .last_row = last };
        }
    }.of;
    try sheet.chart(memory, .{
        .title = "Sustentação",
        .x_label = "α (°)",
        .y_label = "C_L",
        .series = try memory.dupe(writer.ChartSeries, &.{ series("asa", 1, 3, last_row), series("EH", 1, 8, last_row), series("avião", 1, 17, last_row) }),
        .from_column = chart_left,
        .from_row = 2,
        .to_column = chart_left + 8,
        .to_row = 20,
    });
    try sheet.chart(memory, .{
        .title = "Arrasto",
        .x_label = "α (°)",
        .y_label = "C_D",
        .series = try memory.dupe(writer.ChartSeries, &.{ series("asa", 1, 6, last_row), series("EH", 1, 13, last_row), series("fuselagem", 1, 14, last_row), series("avião", 1, 18, last_row) }),
        .from_column = chart_left + 9,
        .from_row = 2,
        .to_column = chart_left + 17,
        .to_row = 20,
    });
    try sheet.chart(memory, .{
        .title = "Polar",
        .x_label = "C_D",
        .y_label = "C_L",
        .series = try memory.dupe(writer.ChartSeries, &.{series("avião", 18, 17, last_row)}),
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
    const book = try core.xlsx.Workbook.parse(memory, try workbook(memory, &loaded.ac));
    try std.testing.expectEqual(@as(usize, 2), book.sheets.len);
    try std.testing.expectEqualStrings("Aerodin", book.sheets[0].name);
    // o bloco da asa começa em B: o título em B2 e "Parâmetro" em B7
    const corner = book.cell("Aerodin", "B7") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Parâmetro", corner.text);
}

//! A planilha de desempenho que o programa gera depois de simular, no formato das planilhas de desempenho das
//! equipes (uma aba por assunto, uma tabela por altitude lado a lado a partir da coluna H, os dados e os gráficos
//! à esquerda):
//!
//! - "Tração e potência": a rotação e a tração estática do polinômio do motor e os p_ij no alto; ρ0, λ, T0, R, W,
//!   K, S, C_D0 e o ρ de cada altitude; V, T_d, T_r, C_L, C_D, P_d e P_r;
//! - "Subida": razão e ângulo de subida;
//! - "Descida": o planeio no C_L de cada V (E, γ, V de planeio, razão de descida);
//! - "Manobra": os limites de curva (estol e tração) e o raio mínimo;
//! - "Curva x velocidade": n e R para cada inclinação;
//! - "Envelope de voo": V_min, V_max, V_e, V* e V de cruzeiro em cada altitude até o teto;
//! - "Dimensionamento inicial": o diagrama de restrições (T/W de cada requisito contra W/S) e o ponto de projeto.
//!
//! Os números são os das análises "Voo nivelado e envelopes" (o desempenho da planilha do núcleo,
//! `core.simple_perf`, por `performance.sheetState`) e "Diagrama de restrições" (`sizing.sheetState`), com os
//! padrões da tela; aqui só se arruma em células.
const std = @import("std");
const core = @import("aerosim");
const simulation = @import("simulation");
const performance = @import("simulations/performance.zig");
const sizing = @import("simulations/sizing.zig");

const writer = core.xlsx_writer;
const simple_perf = core.simple_perf;
const gravity = core.limits.g0;
const deg = 180.0 / std.math.pi;

/// as altitudes das tabelas quando a tela não diz outras (m), na ordem das colunas
pub const default_altitudes = [_]f64{ 0, 600, 1000 };

/// o passo de V das tabelas (m/s), como nas planilhas
pub const speed_step = 0.5;

const first_table_column = 8; // a primeira tabela começa na coluna H, como na planilha
const title_row = 11; // a faixa "Altitude (600m)"; os nomes das colunas embaixo e os números a partir da 13
const chart_left = 1;
const chart_right = 7;
const chart_height = 20;

/// a pasta de trabalho do desempenho do avião nas `altitudes` (m); devolve os bytes do `.xlsx`
pub fn workbook(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, altitudes: []const f64) ![]const u8 {
    const state = try performance.sheetState(memory, aircraft, altitudes, speed_step);
    var sheets = [_]writer.Sheet{
        try tractionSheet(memory, aircraft, &state),
        try climbSheet(memory, &state),
        try glideSheet(memory, &state),
        try maneuverSheet(memory, &state),
        try turnSheet(memory, &state),
        try envelopeSheet(memory, &state),
        try sizingSheet(memory, try sizing.sheetState(memory, aircraft)),
    };
    return writer.write(memory, &sheets);
}

/// uma coluna da tabela: o nome, o estilo e de onde sai o número de cada linha
const Column = struct {
    header: []const u8,
    style: writer.Style = .number_2,
    value: *const fn (row: simple_perf.SimpleRow, bank: usize) f64,
};

fn field(comptime name: []const u8) *const fn (simple_perf.SimpleRow, usize) f64 {
    return struct {
        fn get(row: simple_perf.SimpleRow, _: usize) f64 {
            return @field(row, name);
        }
    }.get;
}

fn fieldInDegrees(comptime name: []const u8) *const fn (simple_perf.SimpleRow, usize) f64 {
    return struct {
        fn get(row: simple_perf.SimpleRow, _: usize) f64 {
            return @field(row, name) * deg;
        }
    }.get;
}

/// a linha da tabela onde fica o ponto `index` (a primeira com números é a `title_row + 2`)
fn rowOf(index: usize) u32 {
    return title_row + 2 + @as(u32, @intCast(index));
}

/// uma tabela com a faixa `title` em cima, a partir da coluna `left`; devolve a última linha com números
fn table(memory: std.mem.Allocator, sheet: *writer.Sheet, left: u32, title: []const u8, columns: []const Column, rows: []const simple_perf.SimpleRow, bank: usize) !u32 {
    const right = left + @as(u32, @intCast(columns.len)) - 1;
    try sheet.text(memory, title_row, left, title, .header);
    if (right > left) try sheet.merge(memory, title_row, left, title_row, right, .header);
    for (columns, 0..) |column, j| {
        const at = left + @as(u32, @intCast(j));
        try sheet.text(memory, title_row + 1, at, column.header, .header);
        try sheet.width(memory, at, @floatFromInt(@max(10, std.unicode.utf8CountCodepoints(column.header) catch 10) + 1));
        for (rows, 0..) |row, i| try sheet.number(memory, rowOf(i), at, column.value(row, bank), column.style);
    }
    return rowOf(@max(rows.len, 1) - 1);
}

/// o rótulo da faixa de uma altitude
fn altitudeTitle(memory: std.mem.Allocator, height: f64) ![]const u8 {
    return std.fmt.allocPrint(memory, "Altitude ({d:.0}m)", .{height});
}

/// a primeira linha voável (C_L ≤ C_L máx.): os gráficos começam nela, porque abaixo do estol as curvas disparam
fn firstFlyable(rows: []const simple_perf.SimpleRow) usize {
    for (rows, 0..) |row, i| if (row.ok != 0) return i;
    return 0;
}

/// a largura das colunas da esquerda (A a G), como na planilha
fn leftWidths(memory: std.mem.Allocator, sheet: *writer.Sheet) !void {
    for ([_]f32{ 8.9, 26, 11, 12, 12, 18.1, 4 }, 1..) |characters, column| try sheet.width(memory, @intCast(column), characters);
}

/// um par nome e valor da coluna B e C (com borda), na linha `row`
fn pair(memory: std.mem.Allocator, sheet: *writer.Sheet, row: u32, name: []const u8, value: f64) !void {
    try sheet.text(memory, row, 2, name, .boxed);
    try sheet.number(memory, row, 3, value, .number);
}

/// "Tração e potência"
fn tractionSheet(memory: std.mem.Allocator, aircraft: *const simulation.Aircraft, state: *const performance.RunState) !writer.Sheet {
    var sheet = writer.Sheet{ .name = "Tração e potência" };
    try polynomialBlock(memory, &sheet, aircraft);
    const base = state.base;
    const values = [_]struct { []const u8, f64 }{
        .{ "rho0", base.rho0 },     .{ "lambda", base.lapse }, .{ "T0", base.T0 }, .{ "R", base.Rgas },
        .{ "W", base.W },           .{ "K", base.K },          .{ "S", base.S },   .{ "Cd0", base.CD0 },
        .{ "Clmax", base.CLmax },
    };
    for (values, 0..) |item, i| try pair(memory, &sheet, 18 + @as(u32, @intCast(i)), item[0], item[1]);
    const columns = [_]Column{
        .{ .header = "V [m/s]", .value = field("V") },
        .{ .header = "Td[N]", .value = field("Td") },
        .{ .header = "Tr[N]", .value = field("Tr") },
        .{ .header = "Cl", .style = .number, .value = field("CL") },
        .{ .header = "Cd", .style = .number, .value = field("CD") },
        .{ .header = "Pd[W]", .value = field("Pd") },
        .{ .header = "Pr[W]", .value = field("Pr") },
    };
    var thrust: std.ArrayList(writer.ChartSeries) = .empty;
    var power: std.ArrayList(writer.ChartSeries) = .empty;
    for (state.altitudes, 0..) |altitude, k| {
        const left = first_table_column + @as(u32, @intCast(k * (columns.len + 1)));
        const last = try table(memory, &sheet, left, try altitudeTitle(memory, altitude.height), &columns, altitude.rows, 0);
        const first = rowOf(firstFlyable(altitude.rows));
        // o ρ de cada altitude na coluna F, como na planilha
        const rho_row: u32 = 18 + 3 * @as(u32, @intCast(k));
        try sheet.text(memory, rho_row, 6, try std.fmt.allocPrint(memory, "Cálculo do rho({d:.0})", .{altitude.height}), .boxed);
        try sheet.number(memory, rho_row + 1, 6, altitude.summary.rho, .number);
        const where = try std.fmt.allocPrint(memory, "{d:.0} m", .{altitude.height});
        try thrust.append(memory, .{ .name = try std.fmt.allocPrint(memory, "Td {s}", .{where}), .x_column = left, .y_column = left + 1, .first_row = first, .last_row = last });
        try thrust.append(memory, .{ .name = try std.fmt.allocPrint(memory, "Tr {s}", .{where}), .x_column = left, .y_column = left + 2, .first_row = first, .last_row = last });
        try power.append(memory, .{ .name = try std.fmt.allocPrint(memory, "Pd {s}", .{where}), .x_column = left, .y_column = left + 5, .first_row = first, .last_row = last });
        try power.append(memory, .{ .name = try std.fmt.allocPrint(memory, "Pr {s}", .{where}), .x_column = left, .y_column = left + 6, .first_row = first, .last_row = last });
    }
    try sheet.chart(memory, .{ .title = "Tração", .x_label = "V [m/s]", .y_label = "T [N]", .series = thrust.items, .from_column = chart_left, .from_row = 30, .to_column = chart_right, .to_row = 30 + chart_height });
    try sheet.chart(memory, .{ .title = "Potência", .x_label = "V [m/s]", .y_label = "P [W]", .series = power.items, .from_column = chart_left, .from_row = 52, .to_column = chart_right, .to_row = 52 + chart_height });
    try leftWidths(memory, &sheet);
    return sheet;
}

/// a rotação e a tração estática (H5:I6) e os coeficientes p_ij (linhas 8 e 9) do primeiro motor com polinômio;
/// sem polinômio, nada
fn polynomialBlock(memory: std.mem.Allocator, sheet: *writer.Sheet, aircraft: *const simulation.Aircraft) !void {
    const unit = for (aircraft.propulsion) |candidate| {
        if (std.mem.eql(u8, candidate.thrust_model, "poly") and candidate.thrust_poly.coefs.len > 0) break candidate;
    } else return;
    const poly = unit.thrust_poly;
    try sheet.text(memory, 5, first_table_column, "To Corrigida", .dark_header);
    try sheet.text(memory, 5, first_table_column + 1, "Rotação", .dark_header);
    // a tração estática está somada no p00 (o núcleo guarda um polinômio só); a rotação é o x fixo
    try sheet.number(memory, 6, first_table_column, poly.coefs[0], .orange_value);
    try sheet.number(memory, 6, first_table_column + 1, if (std.mem.eql(u8, poly.x_var, "const")) poly.x_const else poly.y_const, .green_value);
    const Poly = core.types.ThrustPoly;
    inline for (0..Poly.n_coef) |k| {
        const column: u32 = first_table_column + k;
        try sheet.text(memory, 8, column, Poly.name(k), .black_header);
        const value = if (k == 0) 0 else if (k < poly.coefs.len) poly.coefs[k] else 0; // o p00 já foi para a T0
        try sheet.number(memory, 9, column, value, .purple_value);
    }
}

/// "Subida": a razão e o ângulo de subida (P_d − P_r)/W por altitude; à esquerda, o máximo de cada uma
fn climbSheet(memory: std.mem.Allocator, state: *const performance.RunState) !writer.Sheet {
    var sheet = writer.Sheet{ .name = "Subida" };
    const columns = [_]Column{
        .{ .header = "v[m/s]", .value = field("V") },
        .{ .header = "Razão subida", .style = .number, .value = field("RC") },
        .{ .header = "Ângulo subida(rad)", .style = .number, .value = field("gam") },
        .{ .header = "Ângulo subida(graus)", .value = fieldInDegrees("gam") },
    };
    var series: std.ArrayList(writer.ChartSeries) = .empty;
    for (state.altitudes, 0..) |altitude, k| {
        const left = first_table_column + @as(u32, @intCast(k * (columns.len + 1)));
        const last = try table(memory, &sheet, left, try altitudeTitle(memory, altitude.height), &columns, altitude.rows, 0);
        try series.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{d:.0} m", .{altitude.height}), .x_column = left, .y_column = left + 1, .first_row = rowOf(firstFlyable(altitude.rows)), .last_row = last });
        const row = 12 + 2 * @as(u32, @intCast(k));
        try pair(memory, &sheet, row, try std.fmt.allocPrint(memory, "Max {d:.0} (m/s)", .{altitude.height}), altitude.summary.RCmax);
        try pair(memory, &sheet, row + 1, "em V (m/s)", altitude.summary.V_RCmax);
    }
    try sheet.chart(memory, .{ .title = "Razão de subida", .x_label = "V [m/s]", .y_label = "RC [m/s]", .series = series.items, .from_column = chart_left, .from_row = 22, .to_column = chart_right, .to_row = 22 + chart_height });
    try leftWidths(memory, &sheet);
    return sheet;
}

/// "Descida": o planeio no C_L de cada V; à esquerda, o E máximo e a menor razão de descida
fn glideSheet(memory: std.mem.Allocator, state: *const performance.RunState) !writer.Sheet {
    var sheet = writer.Sheet{ .name = "Descida" };
    const columns = [_]Column{
        .{ .header = "Cl", .style = .number, .value = field("CL") },
        .{ .header = "Cd", .style = .number, .value = field("CD") },
        .{ .header = "V [m/s]", .value = field("V") },
        .{ .header = "E", .value = field("E") },
        .{ .header = "Gama [rad]", .style = .number, .value = field("gam_glide") },
        .{ .header = "Gama [graus]", .value = fieldInDegrees("gam_glide") },
        .{ .header = "Vplaneio [m/s]", .value = field("V_glide") },
        .{ .header = "Razão descida [m/s]", .style = .number, .value = field("sink") },
    };
    var series: std.ArrayList(writer.ChartSeries) = .empty;
    for (state.altitudes, 0..) |altitude, k| {
        const left = first_table_column + @as(u32, @intCast(k * (columns.len + 1)));
        const last = try table(memory, &sheet, left, try altitudeTitle(memory, altitude.height), &columns, altitude.rows, 0);
        try series.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{d:.0} m", .{altitude.height}), .x_column = left + 6, .y_column = left + 7, .first_row = rowOf(firstFlyable(altitude.rows)), .last_row = last });
        const row = 15 + 3 * @as(u32, @intCast(k));
        try pair(memory, &sheet, row, try std.fmt.allocPrint(memory, "Emáx ({d:.0}m)", .{altitude.height}), altitude.summary.Emax);
        try pair(memory, &sheet, row + 1, "menor descida (m/s)", altitude.summary.sink_min);
    }
    try sheet.chart(memory, .{ .title = "Planeio", .x_label = "V planeio [m/s]", .y_label = "razão de descida [m/s]", .series = series.items, .from_column = chart_left, .from_row = 26, .to_column = chart_right, .to_row = 26 + chart_height });
    try leftWidths(memory, &sheet);
    return sheet;
}

/// "Manobra": a curva limitada pelo estol e pela tração em cada V; à esquerda, (T/W) máx., carga alar e o raio
/// mínimo com a sua V, n e inclinação
fn maneuverSheet(memory: std.mem.Allocator, state: *const performance.RunState) !writer.Sheet {
    var sheet = writer.Sheet{ .name = "Manobra" };
    const columns = [_]Column{
        .{ .header = "V [m/s]", .value = field("V") },
        .{ .header = "n estol", .style = .number, .value = field("n_stall") },
        .{ .header = "n sustentado", .style = .number, .value = field("n_sust") },
        .{ .header = "R estol [m]", .value = field("R_stall") },
        .{ .header = "R sustentado [m]", .value = field("R_sust") },
    };
    var series: std.ArrayList(writer.ChartSeries) = .empty;
    for (state.altitudes, 0..) |altitude, k| {
        const left = first_table_column + @as(u32, @intCast(k * (columns.len + 1)));
        const last = try table(memory, &sheet, left, try altitudeTitle(memory, altitude.height), &columns, altitude.rows, 0);
        try series.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{d:.0} m", .{altitude.height}), .x_column = left, .y_column = left + 4, .first_row = rowOf(firstFlyable(altitude.rows)), .last_row = last });
        const summary = altitude.summary;
        const row = 12 + 7 * @as(u32, @intCast(k));
        try sheet.text(memory, row, 2, try altitudeTitle(memory, altitude.height), .header);
        try sheet.merge(memory, row, 2, row, 3, .header);
        try pair(memory, &sheet, row + 1, "(T/W)max", summary.TW_max);
        try pair(memory, &sheet, row + 2, "Carga Alar [N/m²]", summary.WS);
        try pair(memory, &sheet, row + 3, "Vr[min] [m/s]", summary.V_Rmin);
        try pair(memory, &sheet, row + 4, "Nr [min]", summary.n_Rmin);
        try pair(memory, &sheet, row + 5, "R [min] [m]", summary.R_min);
    }
    try sheet.chart(memory, .{ .title = "Raio sustentado", .x_label = "V [m/s]", .y_label = "R [m]", .series = series.items, .from_column = chart_left, .from_row = 34, .to_column = chart_right, .to_row = 34 + chart_height });
    try leftWidths(memory, &sheet);
    return sheet;
}

/// "Curva x velocidade": para cada inclinação, V, n = 1/cos φ e R = V²/(g tan φ), na primeira altitude
fn turnSheet(memory: std.mem.Allocator, state: *const performance.RunState) !writer.Sheet {
    var sheet = writer.Sheet{ .name = "Curva x velocidade" };
    if (state.altitudes.len == 0) return sheet;
    const rows = state.altitudes[0].rows;
    const banks = state.refinement.banks[0..state.refinement.bank_count];
    var series: std.ArrayList(writer.ChartSeries) = .empty;
    const bank_columns = struct {
        fn radius(row: simple_perf.SimpleRow, bank: usize) f64 {
            return row.R_bank[bank];
        }
        fn speed(row: simple_perf.SimpleRow, _: usize) f64 {
            return row.V;
        }
    };
    for (banks, 0..) |bank, k| {
        const left = 2 + @as(u32, @intCast(k * 3));
        const load = try std.fmt.allocPrint(memory, "n = {d:.3}", .{1 / @cos(bank * std.math.pi / 180)});
        const columns = [_]Column{
            .{ .header = "V[m/s]", .value = bank_columns.speed },
            .{ .header = "R [m]", .value = bank_columns.radius },
        };
        const title = try std.fmt.allocPrint(memory, "{d}° ({s})", .{ bank, load });
        // a tabela de cada inclinação ocupa 2 colunas (+ uma de folga); a faixa leva o n da inclinação
        const last = try table(memory, &sheet, left, title, &columns, rows, k);
        try series.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{d}°", .{bank}), .x_column = left + 1, .y_column = left, .first_row = rowOf(firstFlyable(rows)), .last_row = last });
    }
    const right = 2 + @as(u32, @intCast(banks.len * 3)) - 2;
    try sheet.text(memory, 2, 2, try std.fmt.allocPrint(memory, "Curva x velocidade · {s}", .{try altitudeTitle(memory, state.altitudes[0].height)}), .title);
    try sheet.merge(memory, 2, 2, 2, right, .title);
    try sheet.chart(memory, .{ .title = "Envelope de curvas", .x_label = "R [m]", .y_label = "V [m/s]", .series = series.items, .from_column = right + 1, .from_row = 4, .to_column = right + 9, .to_row = 4 + chart_height });
    return sheet;
}

/// "Envelope de voo": uma linha por altitude até o teto, com o gráfico das velocidades contra a altitude
fn envelopeSheet(memory: std.mem.Allocator, state: *const performance.RunState) !writer.Sheet {
    var sheet = writer.Sheet{ .name = "Envelope de voo" };
    const line = state.envelope;
    const columns = [_]struct { header: []const u8, values: []const f64 }{
        .{ .header = "Altitude [m]", .values = line.heights.items },
        .{ .header = "Vmin [m/s]", .values = line.min_speed.items },
        .{ .header = "Vmax [m/s]", .values = line.max_speed.items },
        .{ .header = "Ve [m/s]", .values = line.stall.items },
        .{ .header = "V* [m/s]", .values = line.maneuver.items },
        .{ .header = "Vcru [m/s]", .values = line.cruise.items },
    };
    const left = first_table_column;
    try sheet.text(memory, title_row, left, "Envelope de voo", .header);
    try sheet.merge(memory, title_row, left, title_row, left + columns.len - 1, .header);
    for (columns, 0..) |column, j| {
        const at = left + @as(u32, @intCast(j));
        try sheet.text(memory, title_row + 1, at, column.header, .header);
        try sheet.width(memory, at, 12);
        for (column.values, 0..) |value, i| try sheet.number(memory, rowOf(i), at, value, if (j == 0) .boxed else .number_2);
    }
    try pair(memory, &sheet, 12, "Teto [m]", line.ceiling orelse std.math.nan(f64));
    try pair(memory, &sheet, 13, "n de projeto (V*)", state.load_factor);
    if (line.heights.items.len > 0) {
        const last = rowOf(line.heights.items.len - 1);
        var series: std.ArrayList(writer.ChartSeries) = .empty;
        for (columns[1..], 1..) |column, j| try series.append(memory, .{ .name = column.header, .x_column = left + @as(u32, @intCast(j)), .y_column = left, .first_row = rowOf(0), .last_row = last });
        try sheet.chart(memory, .{ .title = "Envelope de voo", .x_label = "V [m/s]", .y_label = "h [m]", .series = series.items, .from_column = chart_left, .from_row = 16, .to_column = chart_right, .to_row = 16 + chart_height });
    }
    try leftWidths(memory, &sheet);
    return sheet;
}

/// "Dimensionamento inicial": à esquerda os requisitos, a polar, o avião e o ponto de projeto; a partir da H, a
/// T/W que cada requisito pede contra a carga alar (o diagrama de restrições), com o gráfico
fn sizingSheet(memory: std.mem.Allocator, state: sizing.RunState) !writer.Sheet {
    const constraints = core.constraints;
    var sheet = writer.Sheet{ .name = "Dimensionamento inicial" };
    const requirements = state.requirements;
    const polar = state.polar;
    const point = state.point;
    const weight = state.mass * gravity;
    const loading = weight / state.wing_area;
    const static_thrust = if (state.engines > 0) state.thrust[0] / weight else std.math.nan(f64);
    const blocks = [_]struct { title: []const u8, items: []const struct { []const u8, f64 } }{
        .{ .title = "Requisitos", .items = &.{
            .{ "rho [kg/m³]", requirements.rho },             .{ "V estol máx. [m/s]", requirements.V_stall },
            .{ "Corrida decolagem [m]", requirements.S_G },   .{ "V cruzeiro [m/s]", requirements.V_cruise },
            .{ "V subida [m/s]", requirements.V_climb },      .{ "Razão subida [m/s]", requirements.roc },
            .{ "n em curva", requirements.n_turn },           .{ "V curva [m/s]", requirements.V_turn },
        } },
        .{ .title = "Polar", .items = &.{ .{ "Cd0", polar.CD0 }, .{ "k", polar.k }, .{ "Clmax", polar.CLmax } } },
        .{ .title = "Aeronave atual", .items = &.{
            .{ "Massa [kg]", state.mass }, .{ "S [m²]", state.wing_area }, .{ "W/S [N/m²]", loading }, .{ "T/W estática", static_thrust },
        } },
        .{ .title = "Ponto de projeto", .items = &.{
            .{ "W/S [N/m²]", point.wing_loading },                  .{ "T/W", point.thrust_weight },
            .{ "Área de asa [m²]", weight / point.wing_loading },   .{ "Tração [N]", point.thrust_weight * weight },
            .{ "Faixa ótima: início [N/m²]", point.band[0] },       .{ "Faixa ótima: fim [N/m²]", point.band[1] },
            .{ "W/S máxima (limite) [N/m²]", point.max_loading },
        } },
    };
    var row: u32 = 3;
    for (blocks) |block| {
        try sheet.text(memory, row, 2, block.title, .header);
        try sheet.merge(memory, row, 2, row, 3, .header);
        row += 1;
        for (block.items) |item| {
            try pair(memory, &sheet, row, item[0], item[1]);
            row += 1;
        }
        row += 1;
    }

    // a grade de W/S e a T/W de cada requisito; acima do topo do gráfico a célula fica vazia (a curva dispara)
    const points = 60;
    const top_loading = @max(1.3 * point.max_loading, 1.15 * loading);
    const top_tw = @min(@max(2.5 * point.thrust_weight, if (state.engines > 0) 1.5 * static_thrust else 0, 0.3), 3.0);
    const left = first_table_column;
    var kinds: std.ArrayList(constraints.Kind) = .empty;
    for (std.enums.values(constraints.Kind)) |kind| if (kind.active(requirements)) try kinds.append(memory, kind);
    try sheet.text(memory, title_row, left, "Diagrama de restrições (T/W)", .header);
    try sheet.merge(memory, title_row, left, title_row, left + @as(u32, @intCast(kinds.items.len)) + 1, .header);
    try sheet.text(memory, title_row + 1, left, "W/S [N/m²]", .header);
    try sheet.width(memory, left, 12);
    for (kinds.items, 1..) |kind, j| {
        try sheet.text(memory, title_row + 1, left + @as(u32, @intCast(j)), kind.label(), .header);
        try sheet.width(memory, left + @as(u32, @intCast(j)), @floatFromInt(@max(12, kind.label().len)));
    }
    const envelope_column = left + @as(u32, @intCast(kinds.items.len)) + 1;
    try sheet.text(memory, title_row + 1, envelope_column, "envoltória", .header);
    try sheet.width(memory, envelope_column, 12);
    for (0..points) |i| {
        const wing_loading = 0.05 * top_loading + 0.95 * top_loading * @as(f64, @floatFromInt(i)) / (points - 1);
        try sheet.number(memory, rowOf(i), left, wing_loading, .number_2);
        for (kinds.items, 1..) |kind, j| {
            const needed = constraints.requiredThrustWeight(kind, wing_loading, requirements, polar);
            try sheet.number(memory, rowOf(i), left + @as(u32, @intCast(j)), if (needed <= top_tw) needed else std.math.nan(f64), .number);
        }
        const bottom = constraints.envelope(wing_loading, requirements, polar).thrust_weight;
        try sheet.number(memory, rowOf(i), envelope_column, if (wing_loading <= point.max_loading and bottom <= top_tw) bottom else std.math.nan(f64), .number);
    }
    var series: std.ArrayList(writer.ChartSeries) = .empty;
    for (kinds.items, 1..) |kind, j| try series.append(memory, .{ .name = kind.label(), .x_column = left, .y_column = left + @as(u32, @intCast(j)), .first_row = rowOf(0), .last_row = rowOf(points - 1) });
    try series.append(memory, .{ .name = "envoltória", .x_column = left, .y_column = envelope_column, .first_row = rowOf(0), .last_row = rowOf(points - 1) });
    try sheet.chart(memory, .{ .title = "Diagrama de restrições", .x_label = "W/S [N/m²]", .y_label = "T/W", .series = series.items, .from_column = chart_left, .from_row = row + 1, .to_column = chart_right, .to_row = row + 1 + chart_height });
    try leftWidths(memory, &sheet);
    return sheet;
}

test "a planilha de desempenho do avião de exemplo: as abas, as três altitudes e as contas da planilha" {
    const aircraft_model = @import("aircraft_model");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../data/aircraft/Convencional_original.aero", memory, .limited(1 << 24));
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    var loaded = try aircraft_model.aircraft.parse(std.testing.allocator, bytes, &diagnosis);
    defer loaded.deinit();
    const book = try core.xlsx.Workbook.parse(memory, try workbook(memory, &loaded.ac, &default_altitudes));
    try std.testing.expectEqual(@as(usize, 7), book.sheets.len);
    try std.testing.expectEqualStrings("Envelope de voo", book.sheets[5].name);
    try std.testing.expectEqualStrings("Dimensionamento inicial", book.sheets[6].name);
    const sheet = book.sheets[0];
    try std.testing.expectEqualStrings("Tração e potência", sheet.name);
    try std.testing.expectEqualStrings("Altitude (600m)", sheet.at(title_row, first_table_column + 8).?.text);
    try std.testing.expectEqualStrings("Tr[N]", sheet.at(title_row + 1, first_table_column + 2).?.text);
    // V = 10 m/s (a 20ª linha, V de 0,5 em 0,5): T_r = W C_D/C_L e P_r = T_r V
    const row = rowOf(19);
    try std.testing.expectApproxEqAbs(@as(f64, 10), sheet.at(row, first_table_column).?.number, 1e-9);
    const weight = sheet.at(22, 3).?.number;
    const lift = sheet.at(row, first_table_column + 3).?.number;
    const drag = sheet.at(row, first_table_column + 4).?.number;
    const required = sheet.at(row, first_table_column + 2).?.number;
    try std.testing.expectApproxEqRel(weight * drag / lift, required, 1e-6);
    try std.testing.expectApproxEqRel(required * 10, sheet.at(row, first_table_column + 6).?.number, 1e-9);
    // o ρ cai com a altitude
    try std.testing.expect(sheet.at(22, 6).?.number < sheet.at(19, 6).?.number);
    // subida: RC = (P_d − P_r)/W na mesma V
    const climb = book.sheets[1];
    const excess = (sheet.at(row, first_table_column + 5).?.number - sheet.at(row, first_table_column + 6).?.number) / weight;
    try std.testing.expectApproxEqRel(excess, climb.at(row, first_table_column + 1).?.number, 1e-6);
}

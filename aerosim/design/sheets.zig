//! Planilha…: trazer dados de uma planilha `.xlsx` qualquer (as das equipes) sem mapa de células. Cada área tem o
//! botão que abre a janela da planilha (`gui/sheet_window.zig`), que mostra a aba como o Excel e chama as funções
//! daqui. O usuário abre a planilha, vê as abas e as células, marca um bloco (o canto de cima, ou o intervalo inteiro: a
//! primeira linha do bloco são os títulos das colunas), diz o que o bloco é e qual coluna é qual (o programa sugere
//! pelos títulos) e guarda com o nome que quiser. Cada combinação guardada vira um `.csv` na pasta da biblioteca
//! (`<pasta dos projetos>/biblioteca/planilhas`), que vale para todos os projetos; os motores vão direto para a
//! biblioteca de motores.
//!
//!     polar            α, C_L, C_D, C_m             uma curva do avião ou de uma peça
//!     distribuição     y, c_l                        a sustentação ao longo da envergadura
//!     curva            x, y                          qualquer curva por velocidade (tração, subida, curva...)
//!     motores          nome, Kv, R, I máx., massa    uma linha por motor
const std = @import("std");
const core = @import("aerosim");
const catalog = @import("catalog");
const stages = @import("stages.zig");
const library = @import("stage_library.zig");

pub const xlsx = core.xlsx;

/// o que um bloco pode ser
pub const Kind = enum {
    polar,
    distribution,
    curve,
    motors,
    envelope,
    sizing,
    takeoff,
    thrust_polynomial,

    /// o nome na tela (e no `# tipo:` do .csv)
    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .polar => "polar",
            .distribution => "distribuição de sustentação",
            .curve => "curva (x, y)",
            .motors => "motores",
            .envelope => "envelope de voo (tração por velocidade)",
            .sizing => "dimensionamento inicial (diagrama de restrições)",
            .takeoff => "missão e decolagem (por tempo)",
            .thrust_polynomial => "polinômio de tração T(V, rpm)",
        };
    }

    /// o nome curto, da aba da janela
    pub fn short(kind: Kind) []const u8 {
        return switch (kind) {
            .polar => "Polar",
            .distribution => "Distribuição",
            .curve => "Curva",
            .motors => "Motores",
            .envelope => "Envelope de voo",
            .sizing => "Dimensionamento inicial",
            .takeoff => "Missão e decolagem",
            .thrust_polynomial => "Polinômio de tração",
        };
    }

    /// as colunas que o bloco precisa (as obrigatórias primeiro)
    pub fn roles(kind: Kind) []const Role {
        return switch (kind) {
            .polar => &polar_roles,
            .distribution => &distribution_roles,
            .curve => &curve_roles,
            .motors => &motor_roles,
            .envelope => &envelope_roles,
            .sizing => &sizing_roles,
            .takeoff => &takeoff_roles,
            .thrust_polynomial => &.{},
        };
    }
};

/// uma coluna que o tipo pede: a chave (o título no .csv), o nome na tela e os começos de título que a sugerem
pub const Role = struct { key: []const u8, label: []const u8, hints: []const []const u8, required: bool = true };

const polar_roles = [_]Role{
    .{ .key = "alpha", .label = "α (°)", .hints = &.{ "alpha", "alfa", "α", "aoa" } },
    .{ .key = "CL", .label = "C_L", .hints = &.{"cl"} },
    .{ .key = "CD", .label = "C_D", .hints = &.{"cd"}, .required = false },
    .{ .key = "Cm", .label = "C_m", .hints = &.{"cm"}, .required = false },
};
const distribution_roles = [_]Role{
    .{ .key = "y", .label = "y (posição na envergadura)", .hints = &.{ "y", "2y", "eta", "η", "envergadura", "span" } },
    .{ .key = "cl", .label = "c_l (sustentação local)", .hints = &.{ "cl", "c_l" } },
};
const curve_roles = [_]Role{
    .{ .key = "x", .label = "eixo x", .hints = &.{ "v", "velocidade", "x" } },
    .{ .key = "y", .label = "eixo y", .hints = &.{} },
};
const motor_roles = [_]Role{
    .{ .key = "name", .label = "nome", .hints = &.{ "modelo", "nome", "motor", "model" } },
    .{ .key = "Kv", .label = "Kv (rpm/V)", .hints = &.{"kv"} },
    .{ .key = "Rm", .label = "resistência (Ω)", .hints = &.{ "rm", "r ", "resist" } },
    .{ .key = "Imax", .label = "corrente máxima (A)", .hints = &.{ "imax", "i max", "i_max", "corrente" }, .required = false },
    .{ .key = "mass", .label = "massa (kg)", .hints = &.{ "massa", "mass", "peso" }, .required = false },
};

/// tração disponível e requerida por velocidade, como nas planilhas de desempenho das equipes; a potência é opcional
const envelope_roles = [_]Role{
    .{ .key = "V", .label = "V (m/s)", .hints = &.{ "v ", "v[", "v(", "velocidade", "speed" } },
    .{ .key = "T_disp", .label = "tração disponível (N)", .hints = &.{ "td", "t disp", "t_disp", "tdisp", "tração disp", "tracao disp", "ta" } },
    .{ .key = "T_req", .label = "tração requerida (N)", .hints = &.{ "tr", "t req", "t_req", "treq", "tração req", "tracao req" } },
    .{ .key = "P_disp", .label = "potência disponível (W)", .hints = &.{ "pd", "p disp", "p_disp", "pdisp", "pa" }, .required = false },
    .{ .key = "P_req", .label = "potência requerida (W)", .hints = &.{ "pr", "p req", "p_req", "preq" }, .required = false },
};
/// o diagrama de restrições: T/W exigido por requisito em função da carga alar
const sizing_roles = [_]Role{
    .{ .key = "WS", .label = "carga alar W/S (N/m²)", .hints = &.{ "w/s", "ws", "w_s", "carga alar", "wing loading" } },
    .{ .key = "TW_decolagem", .label = "T/W decolagem", .hints = &.{ "decol", "t/w dec", "takeoff", "take-off" } },
    .{ .key = "TW_subida", .label = "T/W subida", .hints = &.{ "subida", "climb" }, .required = false },
    .{ .key = "TW_curva", .label = "T/W curva", .hints = &.{ "curva", "turn" }, .required = false },
    .{ .key = "TW_cruzeiro", .label = "T/W cruzeiro", .hints = &.{ "cruzeiro", "cruise" }, .required = false },
    .{ .key = "TW_teto", .label = "T/W teto", .hints = &.{ "teto", "ceiling" }, .required = false },
};

/// a decolagem ou a missão no tempo: posição, velocidade e altura (a tração é opcional)
const takeoff_roles = [_]Role{
    .{ .key = "t", .label = "tempo (s)", .hints = &.{ "t ", "t[", "t(", "tempo", "time" } },
    .{ .key = "x", .label = "distância (m)", .hints = &.{ "x", "s ", "s[", "dist", "pista" } },
    .{ .key = "V", .label = "V (m/s)", .hints = &.{ "v ", "v[", "v(", "velocidade" }, .required = false },
    .{ .key = "h", .label = "altura (m)", .hints = &.{ "h ", "h[", "h(", "altura", "altitude" }, .required = false },
    .{ .key = "T", .label = "tração (N)", .hints = &.{ "tração", "tracao", "thrust", "t_" }, .required = false },
};

const none = "—";
const kinds = [_]Kind{ .polar, .distribution, .curve, .motors, .envelope, .sizing, .takeoff, .thrust_polynomial };

/// a planilha aberta e o que está marcado nela (fica entre um pedido e outro)
const Draft = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    path: []const u8 = "",
    book: ?xlsx.Workbook = null,
    sheet: usize = 0,
    range: []const u8 = "",
    kind: Kind = .polar,
    name: []const u8 = "",
    /// a coluna do bloco de cada papel (`null`: nenhuma)
    columns: [8]?usize = @splat(null),
    /// as colunas foram escolhidas à mão (não sugerir de novo)
    columns_chosen: bool = false,
    /// motores: o que vale quando a planilha não tem a coluna
    default_imax: f64 = 40,
    default_mass: f64 = 0.2,
    /// polinômio de tração: as células da tração estática e da rotação, a unidade e qual variável é o x
    static_cell: []const u8 = "",
    rpm_cell: []const u8 = "",
    kgf: bool = true,
    x_is_rpm: bool = true,
    v_max: f64 = 30,
    /// a linha do polinômio quando a tabela tem uma hélice por linha (0 = a primeira)
    poly_row: u32 = 0,
    /// a área que abriu a janela
    area_buffer: [48]u8 = undefined,
    area_len: usize = 0,
};
var draft: Draft = .{};
/// a memória dos textos do rascunho (nome, intervalo), trocada a cada pedido
var text_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// a pasta das combinações guardadas
pub fn folder(memory: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(memory, &.{ try stages.projectsRoot(memory), "biblioteca", "planilhas" });
}

// ------------------------------------------------------------------ o bloco

/// um bloco da planilha: os títulos das colunas e os números (NaN onde a célula não tem número; o texto fica em
/// `texts`, para os nomes dos motores)
pub const Block = struct {
    first_row: u32,
    first_column: u32,
    last_row: u32,
    headers: []const []const u8,
    numbers: []const []const f64, // [coluna][linha]
    texts: []const []const []const u8, // [coluna][linha]

    pub fn rowCount(block: Block) usize {
        return if (block.numbers.len > 0) block.numbers[0].len else 0;
    }
};

/// o endereço de uma coluna ("A", "AB") a partir do número (de 1)
pub fn columnName(buffer: *[4]u8, column: u32) []const u8 {
    var number = column;
    var length: usize = 0;
    var reversed: [4]u8 = undefined;
    while (number > 0 and length < 4) : (length += 1) {
        number -= 1;
        reversed[length] = @intCast('A' + number % 26);
        number /= 26;
    }
    for (0..length) |i| buffer[i] = reversed[length - 1 - i];
    return buffer[0..length];
}

/// o texto de uma célula para a tela (o número curto, o texto como está)
fn cellText(memory: std.mem.Allocator, value: ?xlsx.Value) ![]const u8 {
    const cell = value orelse return "";
    return switch (cell) {
        .number => |number| try std.fmt.allocPrint(memory, "{d:.4}", .{number}),
        .text => |text| text,
        .boolean => |flag| if (flag) "verdadeiro" else "falso",
    };
}

/// o bloco marcado por `range`: "B6:R40", ou só o canto de cima ("B6"), e então o bloco vai para a direita enquanto
/// houver título e para baixo enquanto alguma coluna tiver número
pub fn readBlock(memory: std.mem.Allocator, sheet: xlsx.Sheet, range: []const u8) !Block {
    const trimmed = std.mem.trim(u8, range, " ");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':');
    const top = try xlsx.parseAddress(if (colon) |at| trimmed[0..at] else trimmed);
    var last_column: u32 = top.column;
    var last_row: u32 = top.row;
    if (colon) |at| {
        const bottom = try xlsx.parseAddress(trimmed[at + 1 ..]);
        last_column = @max(bottom.column, top.column);
        last_row = @max(bottom.row, top.row);
    } else {
        while (last_column < top.column + 200 and sheet.at(top.row, last_column + 1) != null) last_column += 1;
        const end = sheet.lastRow();
        last_row = top.row;
        var row = top.row + 1;
        while (row <= end) : (row += 1) {
            var any = false;
            var column = top.column;
            while (column <= last_column) : (column += 1) {
                if (sheet.at(row, column)) |value| if (value.asNumber() != null) {
                    any = true;
                    break;
                };
            }
            if (!any) break;
            last_row = row;
        }
    }
    const width = last_column - top.column + 1;
    const height = last_row - top.row;
    const headers = try memory.alloc([]const u8, width);
    const numbers = try memory.alloc([]const f64, width);
    const texts = try memory.alloc([]const []const u8, width);
    for (0..width) |k| {
        const column: u32 = top.column + @as(u32, @intCast(k));
        var letters: [4]u8 = undefined;
        const header = try cellText(memory, sheet.at(top.row, column));
        headers[k] = if (header.len > 0) header else try memory.dupe(u8, columnName(&letters, column));
        const column_numbers = try memory.alloc(f64, height);
        const column_texts = try memory.alloc([]const u8, height);
        for (0..height) |j| {
            const value = sheet.at(top.row + 1 + @as(u32, @intCast(j)), column);
            column_numbers[j] = if (value) |cell| cell.asNumber() orelse std.math.nan(f64) else std.math.nan(f64);
            column_texts[j] = try cellText(memory, value);
        }
        numbers[k] = column_numbers;
        texts[k] = column_texts;
    }
    return .{ .first_row = top.row, .first_column = top.column, .last_row = last_row, .headers = headers, .numbers = numbers, .texts = texts };
}

/// o canto de cima do maior bloco da aba ("AN8"), ou null: um bloco é uma fila de títulos (textos) lado a lado com
/// números logo embaixo de cada um; ganha o de mais células (colunas × linhas com número; no empate, o primeiro), para
/// que uma tabela comprida vença uma fila larga de uma linha só (os coeficientes de um polinômio)
pub fn detectBlock(memory: std.mem.Allocator, sheet: xlsx.Sheet) !?[]const u8 {
    var best_size: u64 = 0;
    var best: ?xlsx.Cell = null;
    for (sheet.cells) |cell| {
        if (!isTitle(sheet, cell.row, cell.column)) continue;
        if (cell.column > 1 and isTitle(sheet, cell.row, cell.column - 1)) continue; // não é o começo da fila
        var width: u32 = 0;
        while (isTitle(sheet, cell.row, cell.column + width)) width += 1;
        if (width < 2) continue;
        // as linhas com algum número embaixo dos títulos
        var height: u32 = 0;
        while (height < 10000) : (height += 1) {
            const row = cell.row + 1 + height;
            var any = false;
            for (0..width) |k| if (sheet.at(row, cell.column + @as(u32, @intCast(k)))) |value| {
                if (value.asNumber() != null) any = true;
            };
            if (!any) break;
        }
        const size = @as(u64, width) * height;
        if (size > best_size) {
            best_size = size;
            best = cell;
        }
    }
    const corner = best orelse return null;
    var letters: [4]u8 = undefined;
    return try std.fmt.allocPrint(memory, "{s}{d}", .{ columnName(&letters, corner.column), corner.row });
}

/// a célula é um título de coluna: um texto com um número logo embaixo (ou uma linha abaixo: a primeira linha da
/// tabela às vezes fica vazia nessa coluna, como a razão de subida em V = 0)
fn isTitle(sheet: xlsx.Sheet, row: u32, column: u32) bool {
    const value = sheet.at(row, column) orelse return false;
    if (value != .text) return false;
    for ([_]u32{ 1, 2 }) |offset| {
        const below = sheet.at(row + offset, column) orelse continue;
        if (below.asNumber() != null) return true;
        if (below == .text) return false;
    }
    return false;
}

/// a coluna sugerida para cada papel: a primeira cujo título começa por uma das pistas (sem repetir coluna); a curva
/// sem pista pega as colunas na ordem
pub fn suggest(kind: Kind, headers: []const []const u8) [8]?usize {
    var chosen: [8]?usize = @splat(null);
    var used = [_]bool{false} ** 256;
    for (kind.roles(), 0..) |role, r| {
        for (headers, 0..) |header, k| {
            if (k >= used.len or used[k]) continue;
            const text = std.mem.trimStart(u8, header, " ");
            for (role.hints) |hint| if (text.len >= hint.len and std.ascii.eqlIgnoreCase(text[0..hint.len], hint)) {
                chosen[r] = k;
                break;
            };
            if (chosen[r] != null) {
                used[k] = true;
                break;
            }
        }
        // sem pista que bata, a coluna obrigatória pega a próxima livre só nos tipos genéricos; no envelope, no
        // diagrama de restrições e na decolagem uma coluna qualquer daria um gráfico sem sentido
        const blind = switch (kind) {
            .polar, .distribution, .curve, .motors => true,
            else => false,
        };
        if (chosen[r] == null and role.required and blind) for (0..@min(headers.len, used.len)) |k| if (!used[k]) {
            chosen[r] = k;
            used[k] = true;
            break;
        };
    }
    return chosen;
}

// ------------------------------------------------------------------ o polinômio de tração

const ThrustPoly = core.types.ThrustPoly;

/// gravidade padrão, para passar de kgf a N
const standard_gravity = 9.80665;

/// o termo de um título "p01" (i = 0, j = 1), ou null
pub fn polyTerm(header: []const u8) ?[2]u32 {
    const text = std.mem.trim(u8, header, " ");
    if (text.len != 3 or (text[0] != 'p' and text[0] != 'P')) return null;
    if (!std.ascii.isDigit(text[1]) or !std.ascii.isDigit(text[2])) return null;
    return .{ text[1] - '0', text[2] - '0' };
}

fn isPolyTitle(sheet: xlsx.Sheet, row: u32, column: u32) bool {
    const value = sheet.at(row, column) orelse return false;
    if (value != .text or polyTerm(value.text) == null) return false;
    const below = sheet.at(row + 1, column) orelse return false;
    return below.asNumber() != null;
}

/// a fila dos coeficientes "p00 p10 p01 ..." com os números embaixo, como intervalo ("H8:Z9"), ou null
pub fn detectPolynomial(memory: std.mem.Allocator, sheet: xlsx.Sheet) !?[]const u8 {
    for (sheet.cells) |cell| {
        if (!isPolyTitle(sheet, cell.row, cell.column)) continue;
        if (cell.column > 1 and isPolyTitle(sheet, cell.row, cell.column - 1)) continue;
        var width: u32 = 0;
        while (isPolyTitle(sheet, cell.row, cell.column + width)) width += 1;
        // uma hélice por linha (a aba de polinômios das hélices): o bloco desce enquanto houver número embaixo
        var rows: u32 = 1;
        while (sheet.at(cell.row + rows + 1, cell.column)) |below| : (rows += 1) if (below.asNumber() == null) break;
        var first: [4]u8 = undefined;
        var last: [4]u8 = undefined;
        return try std.fmt.allocPrint(memory, "{s}{d}:{s}{d}", .{ columnName(&first, cell.column), cell.row, columnName(&last, cell.column + width - 1), cell.row + rows });
    }
    return null;
}

/// o endereço do número logo abaixo do primeiro título que começa por uma das pistas ("To Corrigida" → "H6")
pub fn findLabeled(memory: std.mem.Allocator, sheet: xlsx.Sheet, hints: []const []const u8) !?[]const u8 {
    for (hints) |hint| for (sheet.cells) |cell| {
        if (cell.value != .text) continue;
        const text = std.mem.trimStart(u8, cell.value.text, " ");
        if (text.len < hint.len or !std.ascii.eqlIgnoreCase(text[0..hint.len], hint)) continue;
        // "To": o título é só isso (ou seguido de espaço), para não pegar "Total"
        if (text.len > hint.len and std.ascii.isAlphabetic(text[hint.len]) and hint.len <= 2) continue;
        const below = sheet.at(cell.row + 1, cell.column) orelse continue;
        if (below.asNumber() == null) continue;
        var letters: [4]u8 = undefined;
        return try std.fmt.allocPrint(memory, "{s}{d}", .{ columnName(&letters, cell.column), cell.row + 1 });
    };
    return null;
}

/// o polinômio de tração da planilha, como as equipes ajustam no MATLAB (Curve Fitting Toolbox, modelos `poly22` a
/// `poly55`: f(x, y) = Σ p_ij x^i y^j; a conferir na documentação do MATLAB). A tração estática corrigida T0 entra
/// como termo constante, como na planilha: T = (T0 + p01·V + p02·V² + p03·V³)·9,81 com x = rotação e y = V
pub const Polynomial = struct {
    coefficients: [ThrustPoly.n_coef]f64 = @splat(0),
    static_thrust: f64 = 0,
    rpm: f64 = 0,
    /// 1 com o polinômio em N; a gravidade com ele em kgf
    gain: f64 = 1,
    x_is_rpm: bool = true,

    /// a tração (N) na velocidade `speed` (m/s), na rotação da planilha, ao nível do mar
    pub fn thrust(polynomial: Polynomial, speed: f64) f64 {
        const x_value = if (polynomial.x_is_rpm) polynomial.rpm else speed;
        const y_value = if (polynomial.x_is_rpm) speed else polynomial.rpm;
        return polynomial.gain * (polynomial.static_thrust + ThrustPoly.eval(&polynomial.coefficients, x_value, y_value));
    }
};

pub const PolynomialError = error{ NoCoefficients, DegreeTooHigh, BadCell };

/// lê os coeficientes do bloco (títulos pij e os números embaixo), a tração estática e a rotação
pub fn readPolynomial(sheet: xlsx.Sheet, range_text: []const u8, static_cell: []const u8, rpm_cell: []const u8, options: PolynomialOptions) PolynomialError!Polynomial {
    const range = xlsx.parseRange(std.mem.trim(u8, range_text, " ")) catch return error.BadCell;
    var polynomial = Polynomial{ .gain = if (options.kgf) standard_gravity else 1, .x_is_rpm = options.x_is_rpm };
    var found: usize = 0;
    var column = range.first_column;
    while (column <= range.last_column) : (column += 1) {
        const title = sheet.at(range.first_row, column) orelse continue;
        if (title != .text) continue;
        const term = polyTerm(title.text) orelse continue;
        const value = (sheet.at(range.first_row + 1 + options.row, column) orelse continue).asNumber() orelse continue;
        const index = for (ThrustPoly.exps, 0..) |exponent, k| {
            if (exponent[0] == term[0] and exponent[1] == term[1]) break k;
        } else return error.DegreeTooHigh;
        polynomial.coefficients[index] = value;
        found += 1;
    }
    if (found == 0) return error.NoCoefficients;
    if (static_cell.len > 0) polynomial.static_thrust = (try rowCell(sheet, range, static_cell, options.row)).asNumber() orelse return error.BadCell;
    if (rpm_cell.len > 0) polynomial.rpm = (try rowCell(sheet, range, rpm_cell, options.row)).asNumber() orelse return error.BadCell;
    return polynomial;
}

/// a célula `address`; quando ela está na primeira linha de números do bloco (o título dela fica na fila dos p_ij,
/// uma hélice por linha), desce junto com a linha escolhida
fn rowCell(sheet: xlsx.Sheet, range: xlsx.Range, address: []const u8, row: u32) PolynomialError!xlsx.Value {
    const cell = xlsx.parseRange(std.mem.trim(u8, address, " ")) catch return error.BadCell;
    const shifted = if (cell.first_row == range.first_row + 1) cell.first_row + row else cell.first_row;
    return sheet.at(shifted, cell.first_column) orelse error.BadCell;
}

/// o nome de cada linha do bloco do polinômio (o primeiro texto à esquerda dos coeficientes, "12x7"), ou "linha N"
pub fn polynomialRows(memory: std.mem.Allocator) ![]const []const u8 {
    const book = draft.book orelse return &.{};
    if (draft.sheet >= book.sheets.len) return &.{};
    return rowNames(memory, book.sheets[draft.sheet], draft.range);
}

/// o nome de cada linha de números do bloco `range_text`: o primeiro texto à esquerda dele na linha, ou "linha N"
pub fn rowNames(memory: std.mem.Allocator, sheet: xlsx.Sheet, range_text: []const u8) ![]const []const u8 {
    const range = xlsx.parseRange(std.mem.trim(u8, range_text, " ")) catch return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var row = range.first_row + 1;
    while (row <= range.last_row) : (row += 1) {
        var name: []const u8 = "";
        var column = range.first_column;
        while (column > 1 and name.len == 0) {
            column -= 1;
            if (sheet.at(row, column)) |value| if (value == .text) {
                name = std.mem.trim(u8, value.text, " ");
            };
        }
        try names.append(memory, if (name.len > 0) name else try std.fmt.allocPrint(memory, "linha {d}", .{row}));
    }
    return names.items;
}

/// o polinômio marcado na planilha aberta, ou o problema dele (para a tela)
pub fn markedPolynomial() PolynomialError!Polynomial {
    const book = draft.book orelse return error.NoCoefficients;
    if (draft.sheet >= book.sheets.len) return error.NoCoefficients;
    return readPolynomial(book.sheets[draft.sheet], draft.range, draft.static_cell, draft.rpm_cell, polynomialOptions());
}

/// a curva T(V) de 0 a `v_max` em `count` pontos
pub fn polynomialCurve(memory: std.mem.Allocator, polynomial: Polynomial, v_max: f64, count: usize) !struct { speeds: []f64, thrusts: []f64 } {
    const speeds = try memory.alloc(f64, count);
    const thrusts = try memory.alloc(f64, count);
    for (speeds, thrusts, 0..) |*speed, *thrust_value, k| {
        speed.* = v_max * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count - 1));
        thrust_value.* = polynomial.thrust(speed.*);
    }
    return .{ .speeds = speeds, .thrusts = thrusts };
}

/// o polinômio em .csv: as constantes em `# valor:` e uma linha por coeficiente (i, j, p)
pub fn writePolynomialCsv(out: *std.Io.Writer, source: []const u8, area: []const u8, polynomial: Polynomial) !void {
    try out.print("# tipo: thrust_polynomial\n# fonte: {s}\n", .{source});
    if (area.len > 0) try out.print("# área: {s}\n", .{area});
    try out.print("# valor: T0 = {d}\n# valor: rpm = {d}\n# valor: ganho_N = {d}\n# valor: x_rotacao = {d}\n", .{ polynomial.static_thrust, polynomial.rpm, polynomial.gain, @intFromBool(polynomial.x_is_rpm) });
    try out.writeAll("i,j,p\n");
    for (ThrustPoly.exps, polynomial.coefficients) |exponent, coefficient| if (coefficient != 0) {
        try out.print("{d},{d},{d}\n", .{ exponent[0], exponent[1], coefficient });
    };
}

/// o polinômio de volta de uma combinação guardada
pub fn polynomialOf(saved: Saved) Polynomial {
    var polynomial = Polynomial{};
    for (saved.values) |item| {
        if (std.mem.eql(u8, item.name, "T0")) polynomial.static_thrust = item.value;
        if (std.mem.eql(u8, item.name, "rpm")) polynomial.rpm = item.value;
        if (std.mem.eql(u8, item.name, "ganho_N")) polynomial.gain = item.value;
        if (std.mem.eql(u8, item.name, "x_rotacao")) polynomial.x_is_rpm = item.value != 0;
    }
    if (saved.columns.len < 3) return polynomial;
    for (0..saved.columns[0].len) |row| {
        const i: u32 = @intFromFloat(saved.columns[0][row]);
        const j: u32 = @intFromFloat(saved.columns[1][row]);
        for (ThrustPoly.exps, 0..) |exponent, k| if (exponent[0] == i and exponent[1] == j) {
            polynomial.coefficients[k] = saved.columns[2][row];
        };
    }
    return polynomial;
}

/// liga o polinômio a todos os motores do avião (a árvore do arquivo, com ou sem o invólucro "aeronave"): o modelo de
/// tração vira "poly" e o `thrust_poly` leva os coeficientes com T0 somado ao p00, a rotação como constante, o ganho
/// da unidade e a correção de densidade ρ/ρ0 da planilha. Devolve quantos motores receberam
pub fn putPolynomial(memory: std.mem.Allocator, document: *std.json.Value, polynomial: Polynomial, label: []const u8, source: []const u8) !usize {
    if (document.* != .object) return 0;
    var root = &document.object;
    if (root.getPtr("aeronave")) |inner| if (inner.* == .object) {
        root = &inner.object;
    };
    const units = root.getPtr("propulsion") orelse return 0;
    if (units.* != .array) return 0;
    var poly: std.json.ObjectMap = .empty;
    try poly.put(memory, "name", .{ .string = try memory.dupe(u8, label) });
    var list = std.json.Array.init(memory);
    for (polynomial.coefficients, 0..) |coefficient, k| try list.append(.{ .float = if (k == 0) coefficient + polynomial.static_thrust else coefficient });
    try poly.put(memory, "coefs", .{ .array = list });
    try poly.put(memory, "x_var", .{ .string = if (polynomial.x_is_rpm) "const" else "V" });
    try poly.put(memory, "y_var", .{ .string = if (polynomial.x_is_rpm) "V" else "const" });
    try poly.put(memory, "x_const", .{ .float = if (polynomial.x_is_rpm) polynomial.rpm else 0 });
    try poly.put(memory, "y_const", .{ .float = if (polynomial.x_is_rpm) 0 else polynomial.rpm });
    try poly.put(memory, "gain", .{ .float = polynomial.gain });
    // a planilha corrige a tração por ρ/ρ0 (o expoente 1), com ρ0 do nível do mar
    try poly.put(memory, "rho_exp", .{ .float = 1 });
    try poly.put(memory, "rho0", .{ .float = 1.225 });
    try poly.put(memory, "xmax", .{ .float = 0 });
    try poly.put(memory, "ymax", .{ .float = 0 });
    try poly.put(memory, "T0", .{ .float = polynomial.static_thrust });
    try poly.put(memory, "n", .{ .float = polynomial.rpm });
    try poly.put(memory, "source", .{ .string = try memory.dupe(u8, source) });
    var count: usize = 0;
    for (units.array.items) |*unit| if (unit.* == .object) {
        try unit.object.put(memory, "thrust_model", .{ .string = "poly" });
        try unit.object.put(memory, "thrust_poly", .{ .object = try poly.clone(memory) });
        count += 1;
    };
    return count;
}

/// o polinômio marcado e de onde ele veio ("planilha.xlsx, aba Tração, H8:AB9"), para ligar ao avião
pub fn markedSource(memory: std.mem.Allocator) ![]const u8 {
    const book = draft.book orelse return "";
    if (draft.sheet >= book.sheets.len) return "";
    return std.fmt.allocPrint(memory, "{s}, aba {s}, {s}", .{ std.fs.path.basename(draft.path), book.sheets[draft.sheet].name, draft.range });
}

// ------------------------------------------------------------------ o .csv de uma combinação

/// uma constante guardada junto com a combinação
pub const NamedValue = struct { name: []const u8, value: f64 };

/// uma combinação guardada: o tipo, de onde veio e as colunas (os papéis do tipo)
pub const Saved = struct {
    name: []const u8,
    kind: Kind,
    source: []const u8,
    /// a área em que foi guardada ("" nas antigas)
    area: []const u8 = "",
    /// as constantes (`# valor: nome = número`), como a tração estática do polinômio
    values: []const NamedValue = &.{},
    headers: []const []const u8,
    columns: []const []const f64,
};

/// a combinação em .csv: `# tipo:`, `# fonte:`, os títulos (as chaves dos papéis) e uma linha por ponto
pub fn writeCsv(out: *std.Io.Writer, kind: Kind, source: []const u8, area: []const u8, block: Block, columns: [8]?usize) !void {
    try out.print("# tipo: {s}\n# fonte: {s}\n", .{ @tagName(kind), source });
    if (area.len > 0) try out.print("# área: {s}\n", .{area});
    var first = true;
    for (kind.roles(), 0..) |role, r| if (columns[r] != null) {
        if (!first) try out.writeByte(',');
        try out.writeAll(role.key);
        first = false;
    };
    try out.writeByte('\n');
    for (0..block.rowCount()) |j| {
        // um ponto sem as colunas obrigatórias não entra
        var complete = true;
        for (kind.roles(), 0..) |role, r| if (role.required) if (columns[r]) |k| {
            if (std.math.isNan(block.numbers[k][j])) complete = false;
        };
        if (!complete) continue;
        first = true;
        for (kind.roles(), 0..) |_, r| if (columns[r]) |k| {
            if (!first) try out.writeByte(',');
            const value = block.numbers[k][j];
            if (!std.math.isNan(value)) try out.print("{d}", .{value});
            first = false;
        };
        try out.writeByte('\n');
    }
}

/// lê de volta uma combinação guardada em .csv
pub fn readCsv(memory: std.mem.Allocator, name: []const u8, text: []const u8) !Saved {
    var kind: Kind = .curve;
    var source: []const u8 = "";
    var area: []const u8 = "";
    var values: std.ArrayList(NamedValue) = .empty;
    var headers: []const []const u8 = &.{};
    var columns: std.ArrayList(std.ArrayList(f64)) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            const body = std.mem.trim(u8, line[1..], " ");
            if (std.mem.startsWith(u8, body, "tipo:")) kind = std.meta.stringToEnum(Kind, std.mem.trim(u8, body[5..], " ")) orelse .curve;
            if (std.mem.startsWith(u8, body, "fonte:")) source = try memory.dupe(u8, std.mem.trim(u8, body[6..], " "));
            if (std.mem.startsWith(u8, body, "valor:")) if (std.mem.indexOfScalar(u8, body, '=')) |equal| {
                const value_name = try memory.dupe(u8, std.mem.trim(u8, body[6..equal], " "));
                const number = std.fmt.parseFloat(f64, std.mem.trim(u8, body[equal + 1 ..], " ")) catch continue;
                try values.append(memory, .{ .name = value_name, .value = number });
            };
            if (std.mem.startsWith(u8, body, "área:")) area = try memory.dupe(u8, std.mem.trim(u8, body["área:".len..], " "));
            continue;
        }
        var cells = std.mem.splitScalar(u8, line, ',');
        if (headers.len == 0) {
            var names: std.ArrayList([]const u8) = .empty;
            while (cells.next()) |cell| {
                try names.append(memory, try memory.dupe(u8, std.mem.trim(u8, cell, " ")));
                try columns.append(memory, .empty);
            }
            headers = names.items;
            continue;
        }
        var k: usize = 0;
        while (cells.next()) |cell| : (k += 1) if (k < columns.items.len) {
            const value = std.fmt.parseFloat(f64, std.mem.trim(u8, cell, " ")) catch std.math.nan(f64);
            try columns.items[k].append(memory, value);
        };
    }
    const out = try memory.alloc([]const f64, columns.items.len);
    for (columns.items, out) |list, *column| column.* = list.items;
    return .{ .name = name, .kind = kind, .source = source, .area = area, .values = values.items, .headers = headers, .columns = out };
}

/// as combinações guardadas, em ordem de nome
fn savedFiles(memory: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const path = try folder(memory);
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var walker = dir.iterate();
    while (walker.next(io) catch null) |item| {
        if (item.kind != .file or !std.ascii.endsWithIgnoreCase(item.name, ".csv")) continue;
        try out.append(memory, try std.fs.path.join(memory, &.{ path, item.name }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.items;
}

// ------------------------------------------------------------------ a planilha aberta

/// os tipos de bloco que cada área usa (o primeiro é o padrão); as outras áreas usam todos
pub fn kindsFor(area: []const u8) []const Kind {
    const table = [_]struct { []const u8, []const Kind }{
        .{ "Aerodinâmica", &.{ .polar, .distribution, .curve } },
        .{ "Estabilidade", &.{ .polar, .curve } },
        .{ "Desempenho", &.{ .envelope, .sizing, .takeoff, .thrust_polynomial, .curve, .motors } },
        .{ "Dimensionamento inicial", &.{ .sizing, .curve } },
        .{ "Biblioteca", &.{ .polar, .distribution, .curve, .motors, .thrust_polynomial } },
        .{ "Cargas", &.{ .distribution, .curve } },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], area)) return entry[1];
    return &kinds;
}

/// a área que abriu a janela: o tipo passa a ser um dos dela (e vai no `# área:` do .csv)
pub fn setArea(area: []const u8) void {
    const length = @min(area.len, draft.area_buffer.len);
    @memcpy(draft.area_buffer[0..length], area[0..length]);
    draft.area_len = length;
    const allowed = kindsFor(area);
    if (std.mem.indexOfScalar(Kind, allowed, draft.kind) == null) setKind(allowed[0]);
}

/// abre a planilha do arquivo; devolve "" ou o problema, para a tela
pub fn open(io: std.Io, path: []const u8) ![]const u8 {
    const area = draft.area_buffer;
    const area_len = draft.area_len;
    const kind_before = draft.kind;
    if (draft.arena) |old| {
        old.deinit();
        std.heap.page_allocator.destroy(old);
    }
    const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(std.heap.page_allocator);
    draft = .{ .arena = arena, .area_buffer = area, .area_len = area_len, .kind = kind_before };
    const memory = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(64 << 20)) catch return "não deu para ler a planilha";
    draft.book = xlsx.Workbook.parse(memory, bytes) catch return "o arquivo não abriu como planilha .xlsx";
    draft.path = try memory.dupe(u8, path);
    detectRange();
    return "";
}

/// a planilha aberta, ou null
pub fn workbook() ?xlsx.Workbook {
    return draft.book;
}

/// o caminho da planilha aberta ("" sem planilha)
pub fn openedPath() []const u8 {
    return draft.path;
}

/// a aba mostrada (o índice em `workbook().sheets`)
pub fn sheetIndex() usize {
    return draft.sheet;
}

/// troca a aba e marca o primeiro bloco dela
pub fn selectSheet(index: usize) void {
    const book = draft.book orelse return;
    if (index >= book.sheets.len or index == draft.sheet) return;
    draft.sheet = index;
    detectRange();
}

/// o bloco marcado ("B6" ou "B6:R40"; "" sem bloco)
pub fn markedRange() []const u8 {
    return draft.range;
}

/// marca o bloco e sugere as colunas pelos títulos dele
pub fn setRange(text: []const u8) void {
    if (std.mem.eql(u8, text, draft.range)) return;
    draft.range = text_arena.allocator().dupe(u8, text) catch return;
    suggestColumns();
}

/// o tipo do bloco
pub fn markedKind() Kind {
    return draft.kind;
}

/// muda o tipo do bloco e sugere as colunas de novo
pub fn setKind(chosen: Kind) void {
    if (chosen == draft.kind) return;
    const was_polynomial = draft.kind == .thrust_polynomial;
    draft.kind = chosen;
    // o polinômio é outro tipo de bloco (uma fila de coeficientes): procura de novo ao entrar e ao sair dele
    if (was_polynomial or chosen == .thrust_polynomial) return detectRange();
    suggestColumns();
}

/// polinômio de tração: as células da tração estática e da rotação ("H6", "I6")
pub fn polynomialCells() struct { static_thrust: []const u8, rpm: []const u8 } {
    return .{ .static_thrust = draft.static_cell, .rpm = draft.rpm_cell };
}

/// muda as células da tração estática e da rotação
pub fn setPolynomialCells(static_thrust: []const u8, rpm: []const u8) void {
    const keep_memory = text_arena.allocator();
    if (!std.mem.eql(u8, static_thrust, draft.static_cell)) draft.static_cell = keep_memory.dupe(u8, static_thrust) catch draft.static_cell;
    if (!std.mem.eql(u8, rpm, draft.rpm_cell)) draft.rpm_cell = keep_memory.dupe(u8, rpm) catch draft.rpm_cell;
}

/// polinômio de tração: a unidade (kgf ou N), qual variável é o x do ajuste e até que velocidade desenhar
pub const PolynomialOptions = struct { kgf: bool, x_is_rpm: bool, v_max: f64, row: u32 = 0 };

/// as opções do polinômio de tração
pub fn polynomialOptions() PolynomialOptions {
    return .{ .kgf = draft.kgf, .x_is_rpm = draft.x_is_rpm, .v_max = draft.v_max, .row = draft.poly_row };
}

/// muda as opções do polinômio de tração
pub fn setPolynomialOptions(options: PolynomialOptions) void {
    draft.kgf = options.kgf;
    draft.x_is_rpm = options.x_is_rpm;
    if (options.v_max > 0) draft.v_max = options.v_max;
    draft.poly_row = options.row;
}

/// a coluna do bloco (índice em `Block.headers`) escolhida para o papel, ou null
pub fn roleColumn(role: usize) ?usize {
    return if (role < draft.columns.len) draft.columns[role] else null;
}

/// escolhe a coluna do bloco para o papel (null: nenhuma)
pub fn setColumn(role: usize, chosen: ?usize) void {
    if (role < draft.columns.len) draft.columns[role] = chosen;
}

/// o nome que a combinação vai ter
pub fn comboName() []const u8 {
    return draft.name;
}

/// muda o nome da combinação
pub fn setName(text: []const u8) void {
    if (std.mem.eql(u8, text, draft.name)) return;
    draft.name = text_arena.allocator().dupe(u8, text) catch return;
}

/// motores: a corrente máxima e a massa que valem quando a planilha não tem a coluna
pub fn motorDefaults() struct { imax: f64, mass: f64 } {
    return .{ .imax = draft.default_imax, .mass = draft.default_mass };
}

/// muda a corrente máxima e a massa dos motores sem coluna
pub fn setMotorDefaults(imax: f64, mass: f64) void {
    if (imax > 0) draft.default_imax = imax;
    if (mass > 0) draft.default_mass = mass;
}

/// o bloco marcado lido da aba, ou null (sem planilha, sem bloco ou endereço inválido)
pub fn markedBlock(memory: std.mem.Allocator) ?Block {
    const book = draft.book orelse return null;
    if (draft.sheet >= book.sheets.len or draft.range.len == 0) return null;
    return readBlock(memory, book.sheets[draft.sheet], draft.range) catch null;
}

/// o texto da célula como o Excel mostra: o número com as casas do formato dela (ou até 4, sem zeros à direita)
pub fn displayText(memory: std.mem.Allocator, value: ?xlsx.Value, style: xlsx.Style) ![]const u8 {
    const cell = value orelse return "";
    switch (cell) {
        .number => |raw| {
            const number = if (style.percent) raw * 100 else raw;
            const suffix: []const u8 = if (style.percent) "%" else "";
            if (style.decimals) |decimals| return std.fmt.allocPrint(memory, "{[value]d:.[precision]}{[suffix]s}", .{ .value = number, .precision = @min(decimals, 10), .suffix = suffix });
            if (number == @round(number) and @abs(number) < 1e15) return std.fmt.allocPrint(memory, "{d:.0}{s}", .{ number, suffix });
            const text = try std.fmt.allocPrint(memory, "{d:.4}", .{number});
            return std.fmt.allocPrint(memory, "{s}{s}", .{ std.mem.trimEnd(u8, std.mem.trimEnd(u8, text, "0"), "."), suffix });
        },
        else => return cellText(memory, cell),
    }
}

/// marca o primeiro bloco da aba escolhida (o usuário muda se não for esse) e sugere as colunas
fn detectRange() void {
    const book = draft.book orelse return;
    if (draft.sheet >= book.sheets.len) return;
    const sheet = book.sheets[draft.sheet];
    const keep_memory = text_arena.allocator();
    if (draft.kind == .thrust_polynomial) {
        draft.range = (detectPolynomial(keep_memory, sheet) catch null) orelse "";
        draft.poly_row = 0;
        draft.static_cell = (findLabeled(keep_memory, sheet, &.{ "to", "t0", "tração est", "tracao est", "t est" }) catch null) orelse "";
        draft.rpm_cell = (findLabeled(keep_memory, sheet, &.{ "rotação", "rotacao", "rpm", "n [" }) catch null) orelse "";
    } else draft.range = (detectBlock(keep_memory, sheet) catch null) orelse "";
    suggestColumns();
}

fn suggestColumns() void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    draft.columns = if (markedBlock(scratch.allocator())) |marked| suggest(draft.kind, marked.headers) else @splat(null);
}

/// guarda o bloco marcado com o nome dado: um .csv na pasta, ou os motores na biblioteca de motores
pub fn keep(io: std.Io, memory: std.mem.Allocator) ![]const u8 {
    if (draft.kind == .thrust_polynomial) return keepPolynomial(io, memory);
    const marked = markedBlock(memory) orelse return "abra uma planilha e marque o bloco (arraste sobre as células, ou escreva B6 ou B6:R40)";
    for (draft.kind.roles(), 0..) |role, r| if (role.required and draft.columns[r] == null) return std.fmt.allocPrint(memory, "falta dizer qual coluna é {s}", .{role.label});
    const book = draft.book.?;
    const source = try std.fmt.allocPrint(memory, "{s}, aba {s}, {s}", .{ std.fs.path.basename(draft.path), book.sheets[draft.sheet].name, draft.range });
    if (draft.kind == .motors) return keepMotors(io, memory, marked, source);
    const chosen_name = std.mem.trim(u8, draft.name, " ");
    if (chosen_name.len == 0) return "dê um nome à combinação";
    var text: std.Io.Writer.Allocating = .init(memory);
    try writeCsv(&text.writer, draft.kind, source, draft.area_buffer[0..draft.area_len], marked, draft.columns);
    return writeKept(io, memory, chosen_name, text.written());
}

/// guarda o polinômio de tração marcado com o nome dado
fn keepPolynomial(io: std.Io, memory: std.mem.Allocator) ![]const u8 {
    const polynomial = markedPolynomial() catch |err| return switch (err) {
        error.NoCoefficients => "marque a fila dos coeficientes (os títulos p00, p10, p01... e os números embaixo)",
        error.DegreeTooHigh => "o polinômio passa do grau 5 (poly55): os termos a mais não cabem",
        error.BadCell => "a célula da tração estática ou da rotação não tem número",
    };
    const chosen_name = std.mem.trim(u8, draft.name, " ");
    if (chosen_name.len == 0) return "dê um nome ao polinômio";
    const book = draft.book.?;
    const source = try std.fmt.allocPrint(memory, "{s}, aba {s}, {s}", .{ std.fs.path.basename(draft.path), book.sheets[draft.sheet].name, draft.range });
    var text: std.Io.Writer.Allocating = .init(memory);
    try writePolynomialCsv(&text.writer, source, draft.area_buffer[0..draft.area_len], polynomial);
    return writeKept(io, memory, chosen_name, text.written());
}

/// grava o texto de uma combinação na pasta da biblioteca
fn writeKept(io: std.Io, memory: std.mem.Allocator, chosen_name: []const u8, text: []const u8) ![]const u8 {
    const directory = try folder(memory);
    std.Io.Dir.cwd().createDirPath(io, directory) catch return "não deu para criar a pasta da biblioteca";
    const file_name = try library.fileName(memory, chosen_name);
    const file = try std.fs.path.join(memory, &.{ directory, try std.fmt.allocPrint(memory, "{s}.csv", .{std.fs.path.stem(file_name)}) });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text }) catch return "não deu para gravar na pasta da biblioteca";
    return std.fmt.allocPrint(memory, "guardado na biblioteca: {s} ({s})", .{ chosen_name, draft.kind.label() });
}

/// uma linha por motor: os que já existem com o mesmo nome ficam de fora
fn keepMotors(io: std.Io, memory: std.mem.Allocator, marked: Block, source: []const u8) ![]const u8 {
    var count: usize = 0;
    var skipped: usize = 0;
    for (0..marked.rowCount()) |j| {
        const motor_name = std.mem.trim(u8, marked.texts[draft.columns[0].?][j], " ");
        const kv = marked.numbers[draft.columns[1].?][j];
        const resistance = marked.numbers[draft.columns[2].?][j];
        if (motor_name.len == 0 or !(kv > 0) or !(resistance > 0)) {
            skipped += 1;
            continue;
        }
        const imax = if (draft.columns[3]) |k| marked.numbers[k][j] else draft.default_imax;
        const mass = if (draft.columns[4]) |k| marked.numbers[k][j] else draft.default_mass;
        // dois motores da planilha com o mesmo nome (o mesmo modelo em Kv diferentes): o Kv entra no nome
        const full_name = try std.fmt.allocPrint(memory, "{s} {d:.0}kv", .{ motor_name, kv });
        if (catalog.find(catalog.Motor, &catalog.motors, full_name) != null) {
            skipped += 1;
            continue;
        }
        const motor: catalog.Motor = .{
            .name = full_name,
            .Kv = kv,
            .Rm = resistance,
            .B = 0,
            .tauc = 0,
            .Imax = if (imax > 0) imax else draft.default_imax,
            .Jm = 0,
            .mass = if (mass > 0) mass else draft.default_mass,
            .source = source,
        };
        library.storeMotor(io, memory, motor) catch return "não deu para gravar na pasta da biblioteca";
        count += 1;
    }
    library.reload(io);
    return std.fmt.allocPrint(memory, "entraram {d} motores na biblioteca (Biblioteca → Motores); {d} linhas sem nome, Kv ou resistência ficaram de fora", .{ count, skipped });
}

/// uma combinação guardada e o arquivo dela
pub const Kept = struct { file: []const u8, saved: Saved };

/// as combinações guardadas na biblioteca, em ordem de nome
pub fn keptList(memory: std.mem.Allocator, io: std.Io) ![]const Kept {
    var out: std.ArrayList(Kept) = .empty;
    for (try savedFiles(memory, io)) |file| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, file, memory, .limited(16 << 20)) catch continue;
        const saved = readCsv(memory, std.fs.path.stem(file), text) catch continue;
        try out.append(memory, .{ .file = file, .saved = saved });
    }
    return out.items;
}

/// tira uma combinação da biblioteca
pub fn deleteKept(io: std.Io, file: []const u8) bool {
    std.Io.Dir.cwd().deleteFile(io, file) catch return false;
    return true;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "o nome da coluna pelo número, como no Excel" {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("A", columnName(&buffer, 1));
    try testing.expectEqualStrings("Z", columnName(&buffer, 26));
    try testing.expectEqualStrings("AA", columnName(&buffer, 27));
    try testing.expectEqualStrings("AZ", columnName(&buffer, 52));
}

/// uma aba de teste: títulos na linha 2 (B2:E2) e três linhas de números, com uma linha vazia depois
fn testSheet(memory: std.mem.Allocator) !xlsx.Sheet {
    var cells: std.ArrayList(xlsx.Cell) = .empty;
    try cells.append(memory, .{ .row = 1, .column = 1, .value = .{ .text = "Polares do avião" } });
    const titles = [_][]const u8{ "Alpha avião", "CLw", "CDiw", "CDw" };
    for (titles, 0..) |title, k| try cells.append(memory, .{ .row = 2, .column = 2 + @as(u32, @intCast(k)), .value = .{ .text = title } });
    for (0..3) |j| for (0..4) |k| {
        const value: f64 = if (k == 0) @as(f64, @floatFromInt(j)) * 2 - 2 else 0.1 * @as(f64, @floatFromInt(j + k));
        try cells.append(memory, .{ .row = 3 + @as(u32, @intCast(j)), .column = 2 + @as(u32, @intCast(k)), .value = .{ .number = value } });
    };
    try cells.append(memory, .{ .row = 8, .column = 2, .value = .{ .text = "outra coisa" } });
    return .{ .name = "Polares", .cells = cells.items };
}

test "o bloco pelo canto de cima vai até o último título e a última linha com número" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const sheet = try testSheet(memory);
    const block = try readBlock(memory, sheet, "B2");
    try testing.expectEqual(@as(usize, 4), block.headers.len);
    try testing.expectEqual(@as(usize, 3), block.rowCount());
    try testing.expectEqualStrings("CLw", block.headers[1]);
    try testing.expectEqual(@as(f64, 2), block.numbers[0][2]);
    // o intervalo inteiro, menor que o bloco
    const part = try readBlock(memory, sheet, "B2:C3");
    try testing.expectEqual(@as(usize, 2), part.headers.len);
    try testing.expectEqual(@as(usize, 1), part.rowCount());
    try testing.expectError(error.BadCell, readBlock(memory, sheet, "linha 2"));
}

test "o primeiro bloco da aba: dois títulos lado a lado com números embaixo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    try testing.expectEqualStrings("B2", (try detectBlock(memory, try testSheet(memory))).?);
}

test "as colunas sugeridas pelos títulos; a polar vira .csv e volta igual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const block = try readBlock(memory, try testSheet(memory), "B2");
    const columns = suggest(.polar, block.headers);
    try testing.expectEqual(@as(?usize, 0), columns[0]); // "Alpha avião"
    try testing.expectEqual(@as(?usize, 1), columns[1]); // "CLw"
    try testing.expectEqual(@as(?usize, 2), columns[2]); // "CDiw", o primeiro C_D
    try testing.expectEqual(@as(?usize, null), columns[3]); // sem C_m
    var text: std.Io.Writer.Allocating = .init(memory);
    try writeCsv(&text.writer, .polar, "teste.xlsx, aba Polares, B2", "Aerodinâmica", block, columns);
    try testing.expect(std.mem.startsWith(u8, text.written(), "# tipo: polar\n# fonte: teste.xlsx, aba Polares, B2\n# área: Aerodinâmica\nalpha,CL,CD\n-2,0.1,0.2\n"));
    const saved = try readCsv(memory, "Aura", text.written());
    try testing.expectEqual(Kind.polar, saved.kind);
    try testing.expectEqualStrings("Aerodinâmica", saved.area);
    try testing.expectEqual(@as(usize, 3), saved.columns.len);
    try testing.expectEqual(@as(f64, 2), saved.columns[0][2]);
    try testing.expectEqual(@as(f64, 0.4), saved.columns[2][2]);
}


test "o número aparece com as casas do formato da célula" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    try testing.expectEqualStrings("0.123", try displayText(memory, .{ .number = 0.12345 }, .{ .decimals = 3 }));
    try testing.expectEqualStrings("12.5%", try displayText(memory, .{ .number = 0.125 }, .{ .decimals = 1, .percent = true }));
    try testing.expectEqualStrings("4", try displayText(memory, .{ .number = 4 }, .{}));
    try testing.expectEqualStrings("0.1235", try displayText(memory, .{ .number = 0.123456 }, .{}));
    try testing.expectEqualStrings("Alpha", try displayText(memory, .{ .text = "Alpha" }, .{}));
}

test "cada área oferece os tipos dela" {
    try testing.expectEqual(Kind.polar, kindsFor("Aerodinâmica")[0]);
    try testing.expectEqual(@as(usize, 5), kindsFor("Biblioteca").len);
    try testing.expectEqual(Kind.envelope, kindsFor("Desempenho")[0]);
    try testing.expectEqual(Kind.sizing, kindsFor("Dimensionamento inicial")[0]);
}

test "a tabela comprida vence a fila larga de uma linha só" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var cells: std.ArrayList(xlsx.Cell) = .empty;
    // linha 2: seis coeficientes com uma linha de números; linha 5: V, Td e Tr com quatro linhas
    for (0..6) |k| {
        try cells.append(memory, .{ .row = 2, .column = 1 + @as(u32, @intCast(k)), .value = .{ .text = "p" } });
        try cells.append(memory, .{ .row = 3, .column = 1 + @as(u32, @intCast(k)), .value = .{ .number = 0 } });
    }
    const titles = [_][]const u8{ "V [m/s]", "Td[N]", "Tr[N]" };
    for (titles, 0..) |title, k| try cells.append(memory, .{ .row = 5, .column = 1 + @as(u32, @intCast(k)), .value = .{ .text = title } });
    for (0..4) |j| for (0..3) |k| try cells.append(memory, .{ .row = 6 + @as(u32, @intCast(j)), .column = 1 + @as(u32, @intCast(k)), .value = .{ .number = @floatFromInt(j + k) } });
    std.mem.sort(xlsx.Cell, cells.items, {}, struct {
        fn before(_: void, left: xlsx.Cell, right: xlsx.Cell) bool {
            return left.row < right.row or (left.row == right.row and left.column < right.column);
        }
    }.before);
    const sheet: xlsx.Sheet = .{ .name = "Tração", .cells = cells.items };
    try testing.expectEqualStrings("A5", (try detectBlock(memory, sheet)).?);
    // e as colunas do envelope saem pelos títulos
    const block = try readBlock(memory, sheet, "A5");
    const columns = suggest(.envelope, block.headers);
    try testing.expectEqual(@as(?usize, 0), columns[0]);
    try testing.expectEqual(@as(?usize, 1), columns[1]);
    try testing.expectEqual(@as(?usize, 2), columns[2]);
}

test "o polinômio de tração da planilha: T0 e os termos em V na rotação dada" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var cells: std.ArrayList(xlsx.Cell) = .empty;
    // como na planilha de desempenho: "To Corrigida" e "Rotação" em H5:I6, os coeficientes em H8:K9
    try cells.append(memory, .{ .row = 5, .column = 8, .value = .{ .text = "To Corrigida " } });
    try cells.append(memory, .{ .row = 5, .column = 9, .value = .{ .text = "Rotação" } });
    try cells.append(memory, .{ .row = 6, .column = 8, .value = .{ .number = 6.75 } });
    try cells.append(memory, .{ .row = 6, .column = 9, .value = .{ .number = 8500 } });
    const terms = [_][]const u8{ "p00", "p10", "p01", "p20", "p11", "p02", "p30", "p21", "p12", "p03" };
    const values = [_]f64{ 0, 0, -0.0763, 0, 0, 0.00141, 0, 0, 0, -0.00085 };
    for (terms, values, 0..) |term, value, k| {
        try cells.append(memory, .{ .row = 8, .column = 8 + @as(u32, @intCast(k)), .value = .{ .text = term } });
        try cells.append(memory, .{ .row = 9, .column = 8 + @as(u32, @intCast(k)), .value = .{ .number = value } });
    }
    // a aba guarda as células em ordem de linha e coluna (a busca é binária)
    std.mem.sort(xlsx.Cell, cells.items, {}, struct {
        fn before(_: void, left: xlsx.Cell, right: xlsx.Cell) bool {
            return left.row < right.row or (left.row == right.row and left.column < right.column);
        }
    }.before);
    const sheet: xlsx.Sheet = .{ .name = "Tração", .cells = cells.items };
    const range = (try detectPolynomial(memory, sheet)).?;
    try testing.expectEqualStrings("H8:Q9", range);
    try testing.expectEqualStrings("H6", (try findLabeled(memory, sheet, &.{ "to", "t0" })).?);
    try testing.expectEqualStrings("I6", (try findLabeled(memory, sheet, &.{"rotação"})).?);
    const polynomial = try readPolynomial(sheet, range, "H6", "I6", .{ .kgf = true, .x_is_rpm = true, .v_max = 30 });
    // V = 0: a tração estática, 6,75 kgf
    try testing.expectApproxEqAbs(6.75 * standard_gravity, polynomial.thrust(0), 1e-9);
    // V = 10 m/s: 6,75 − 0,763 + 0,141 − 0,85 = 5,278 kgf (a conta da planilha, sem a correção de densidade)
    try testing.expectApproxEqAbs(5.278 * standard_gravity, polynomial.thrust(10), 1e-9);
    // e volta igual do .csv
    var text: std.Io.Writer.Allocating = .init(memory);
    try writePolynomialCsv(&text.writer, "teste", "Desempenho", polynomial);
    const back = polynomialOf(try readCsv(memory, "Fulcrum", text.written()));
    try testing.expectApproxEqAbs(polynomial.thrust(12), back.thrust(12), 1e-9);
}

test "uma hélice por linha: o bloco desce pelas linhas e T0 e a rotação vêm da linha escolhida" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var cells: std.ArrayList(xlsx.Cell) = .empty;
    // como a aba de polinômios das hélices: nome em A, p00..p01 em B:D, a rotação em E e a T0 em F, uma hélice por linha
    const titles = [_][]const u8{ "Hélice", "p00", "p10", "p01", "Rotação", "To Corrigida" };
    for (titles, 1..) |title, column| try cells.append(memory, .{ .row = 2, .column = @intCast(column), .value = .{ .text = title } });
    const rows = [_]struct { []const u8, [5]f64 }{ .{ "12x7", .{ 0, 0, -0.1, 11160, 3.1 } }, .{ "12x8", .{ 0, 0, -0.2, 10440, 3.2 } } };
    for (rows, 3..) |item, row| {
        try cells.append(memory, .{ .row = @intCast(row), .column = 1, .value = .{ .text = item[0] } });
        for (item[1], 2..) |value, column| try cells.append(memory, .{ .row = @intCast(row), .column = @intCast(column), .value = .{ .number = value } });
    }
    const sheet: xlsx.Sheet = .{ .name = "Thrust_polynomial_method", .cells = cells.items };
    const range = (try detectPolynomial(memory, sheet)).?;
    try testing.expectEqualStrings("B2:D4", range);
    const names = try rowNames(memory, sheet, range);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("12x8", names[1]);
    const static_cell = (try findLabeled(memory, sheet, &.{ "to", "t0" })).?;
    const rpm_cell = (try findLabeled(memory, sheet, &.{"rotação"})).?;
    // a segunda hélice: T0 = 3,2 kgf, rotação 10440 e p01 = −0,2 (em V)
    const second = try readPolynomial(sheet, range, static_cell, rpm_cell, .{ .kgf = true, .x_is_rpm = true, .v_max = 30, .row = 1 });
    try testing.expectApproxEqAbs(@as(f64, 10440), second.rpm, 1e-12);
    try testing.expectApproxEqAbs((3.2 - 0.2 * 10) * standard_gravity, second.thrust(10), 1e-9);
    const first = try readPolynomial(sheet, range, static_cell, rpm_cell, .{ .kgf = true, .x_is_rpm = true, .v_max = 30 });
    try testing.expectApproxEqAbs(@as(f64, 3.1) * standard_gravity, first.thrust(0), 1e-9);
}

test "o polinômio vai para os motores do avião e dá a mesma tração pelo polinômio do núcleo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var document = try std.json.parseFromSliceLeaky(std.json.Value, memory, "{\"aeronave\":{\"propulsion\":[{\"name\":\"m1\"},{\"name\":\"m2\"}]}}", .{});
    var polynomial = Polynomial{ .static_thrust = 6.75, .rpm = 8500, .gain = standard_gravity };
    polynomial.coefficients[2] = -0.0763; // p01
    polynomial.coefficients[5] = 0.00141; // p02
    try testing.expectEqual(@as(usize, 2), try putPolynomial(memory, &document, polynomial, "Fulcrum", "teste"));
    const unit = document.object.get("aeronave").?.object.get("propulsion").?.array.items[1].object;
    try testing.expectEqualStrings("poly", unit.get("thrust_model").?.string);
    const poly = unit.get("thrust_poly").?.object;
    var coefficients: [ThrustPoly.n_coef]f64 = @splat(0);
    for (poly.get("coefs").?.array.items, 0..) |item, k| coefficients[k] = item.float;
    // o que o núcleo calcula (x = a rotação constante, y = V) é a tração da planilha
    const core_thrust = poly.get("gain").?.float * ThrustPoly.eval(&coefficients, poly.get("x_const").?.float, 12);
    try testing.expectApproxEqAbs(polynomial.thrust(12), core_thrust, 1e-9);
}

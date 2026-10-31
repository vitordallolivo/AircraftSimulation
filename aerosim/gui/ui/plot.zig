//! Gráfico de linhas dentro de um cartão: eixos com marcas redondas, grade fraca, as curvas na paleta do tema
//! (uma cor por curva, tracejada se pedido) e a legenda embaixo, quebrando em linhas. Também faz nuvem de pontos
//! colorida por um valor (o mapa do aeroopt).
//!
//! Todo gráfico de linhas tem o mesmo comportamento, em qualquer tela: um clique num nome da legenda liga ou
//! desliga aquela curva (as desligadas ficam apagadas na legenda e saem dos eixos), e o botão direito abre um menu
//! para marcar as curvas e exportar o gráfico em PNG, em PDF ou só os dados das curvas marcadas em CSV. O estado
//! de cada gráfico (as curvas desligadas) fica guardado pelo título, entre um quadro e outro.
const std = @import("std");
const system = @import("system.zig");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const numbers = @import("numbers.zig");
const dialogs = @import("dialogs.zig");
const export_file = @import("export.zig");
const tex = @import("tex.zig");

/// uma curva: x e y do mesmo tamanho
pub const Series = struct {
    name: [:0]const u8,
    xs: []const f64,
    ys: []const f64,
    dashed: bool = false,
    points: bool = false, // só os pontos, sem ligar
    color_index: ?usize = null, // cor fixa da paleta (senão, a ordem da curva)
    color: ?rl.Color = null, // a cor que o resultado pediu (vence a da paleta)
    width: f32 = 2.2,
    in_legend: bool = true, // falso: a reta repetida (o outro lado do fim do curso) não aparece de novo na legenda
    // região sombreada até a outra borda: `fill_ys` no mesmo x (sobra de potência, subida) ou `fill_xs` no mesmo y
    // (o envelope de voo, de V_min a V_max em cada altitude)
    fill_ys: []const f64 = &.{},
    fill_xs: []const f64 = &.{},
    strong: bool = false, // a sombra mais forte
    marker: Marker = .none, // um símbolo em cada ponto (a estrela do máximo)
    marker_size: f32 = 0, // 0: o padrão do símbolo
    marker_line: bool = false, // com marcador, liga os pontos também
    span: bool = false, // faixa vertical sombreada de xs[0] a xs[1] (o trecho do voo nivelado)

    /// a cor desta curva, sendo a `index`-ésima do gráfico
    pub fn colorAt(s: Series, index: usize) rl.Color {
        return s.color orelse theme.plotColor(s.color_index orelse index);
    }
};

/// os símbolos de ponto, os mesmos nomes da GUI PyQt (`_symbol`): "o", "star", "s", "t", "d", "+", "x"
pub const Marker = enum {
    none,
    circle,
    star,
    square,
    triangle,
    diamond,
    plus,
    cross,

    /// o símbolo pelo nome que vem do Python
    pub fn named(name: []const u8) Marker {
        const names = [_]struct { []const u8, Marker }{
            .{ "o", .circle },  .{ "star", .star },   .{ "s", .square }, .{ "t", .triangle }, .{ "^", .triangle },
            .{ "v", .triangle }, .{ "d", .diamond }, .{ "+", .plus },   .{ "x", .cross },
        };
        for (names) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
        return if (name.len > 0) .circle else .none;
    }
};

/// pontos coloridos por um valor (azul → laranja), sem legenda de curvas
pub const Cloud = struct {
    xs: []const f64,
    ys: []const f64,
    values: []const f64,
    value_name: [:0]const u8,
    highlight: ?usize = null, // um ponto marcado (o melhor)
};

pub const Axes = struct {
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
    equal_axes: bool = false, // a mesma escala em x e em y (um contorno de perfil)
    // a escala pedida pelo resultado (`_xlim`, `_ylim`): as curvas seguem inteiras, cortadas na borda
    x_limits: ?numbers.Range = null,
    y_limits: ?numbers.Range = null,
};

pub const Frame = struct {
    area: rl.Rectangle,
    x_range: numbers.Range,
    y_range: numbers.Range,

    /// ponto dos dados → pixel
    pub fn toScreen(frame: Frame, x: f64, y: f64) rl.Vector2 {
        const fx = (x - frame.x_range.low) / (frame.x_range.high - frame.x_range.low);
        const fy = (y - frame.y_range.low) / (frame.y_range.high - frame.y_range.low);
        return .{ .x = frame.area.x + @as(f32, @floatCast(fx)) * frame.area.width, .y = frame.area.y + frame.area.height - @as(f32, @floatCast(fy)) * frame.area.height };
    }
};

/// cartão com o gráfico das curvas (com a legenda que liga e desliga e o menu do botão direito)
pub fn lines(ui: *widgets.Ui, rect: rl.Rectangle, axes: Axes, series: []const Series) void {
    const state = stateFor(axes.title);
    if (state.pending) |kind| {
        state.pending = null;
        exportPlot(ui, rect, axes, series, state, kind);
    }
    drawLines(ui, rect, axes, series, state, true);
    // o botão direito no cartão abre o menu deste gráfico
    if (ui.right_clicked and ui.hovering(rect)) {
        menu.open = true;
        menu.key = state.key;
        menu.at = ui.mouse;
        menu.is_table = false;
        ui.right_clicked = false;
    }
    if (menu.open and menu.key == state.key) menu.capture(axes, series, state);
}

fn drawLines(ui: *widgets.Ui, rect: rl.Rectangle, axes: Axes, series: []const Series, state: *State, interactive: bool) void {
    const inner = widgets.card(ui, rect, axes.title);
    var x_range: ?numbers.Range = null;
    var y_range: ?numbers.Range = null;
    // as faixas juntam os dados das curvas ligadas; uma reta vertical (x igual) ou horizontal só entra com o
    // valor dela, sem a meia unidade de folga que `Range.of` dá a um valor único
    for (series) |s| {
        if (state.isHidden(s.name)) continue;
        if (s.span) {
            if (extent(s.xs)) |rx| x_range = if (x_range) |r| r.merge(rx) else rx;
            continue;
        }
        var rx = extent(s.xs) orelse continue;
        var ry = extent(s.ys) orelse continue;
        if (extent(s.fill_xs)) |other| rx = rx.merge(other);
        if (extent(s.fill_ys)) |other| ry = ry.merge(other);
        x_range = if (x_range) |r| r.merge(rx) else rx;
        y_range = if (y_range) |r| r.merge(ry) else ry;
    }
    if (x_range) |r| x_range = numbers.Range.of(&.{ r.low, r.high }, 0);
    if (y_range) |r| y_range = numbers.Range.of(&.{ r.low, r.high }, 0.06);
    if (axes.x_limits) |limits| x_range = limits;
    if (axes.y_limits) |limits| y_range = limits;
    const legend_height = legendHeight(ui, inner.width, series);
    const frame = drawFrame(ui, inner, axes, x_range orelse .{ .low = 0, .high = 1 }, y_range orelse .{ .low = 0, .high = 1 }, legend_height, axes.equal_axes);
    ui.pushClip(.{ .x = frame.area.x, .y = frame.area.y - 1, .width = frame.area.width + 1, .height = frame.area.height + 2 });
    // as sombras primeiro, embaixo das linhas
    for (series, 0..) |s, i| {
        if (state.isHidden(s.name)) continue;
        if (s.span and s.xs.len >= 2) {
            const a = frame.toScreen(s.xs[0], frame.y_range.high);
            const b = frame.toScreen(s.xs[1], frame.y_range.low);
            rl.drawRectangleRec(.{ .x = @min(a.x, b.x), .y = a.y, .width = @abs(b.x - a.x), .height = b.y - a.y }, shade(s.colorAt(i), false));
        }
        if (s.fill_ys.len > 0 or s.fill_xs.len > 0) fillBetween(frame, s, shade(s.colorAt(i), s.strong));
    }
    for (series, 0..) |s, i| {
        if (state.isHidden(s.name) or s.span) continue;
        const color = s.colorAt(i);
        const n = @min(s.xs.len, s.ys.len);
        if (s.marker != .none) {
            if (s.marker_line) connect(frame, s, color);
            for (0..n) |k| if (std.math.isFinite(s.xs[k]) and std.math.isFinite(s.ys[k])) drawMarker(s.marker, frame.toScreen(s.xs[k], s.ys[k]), if (s.marker_size > 0) s.marker_size else defaultMarkerSize(s.marker), color);
            continue;
        }
        if (s.fill_ys.len > 0 or s.fill_xs.len > 0) { // a borda da sombra, fina
            var thin = s;
            thin.width = 1;
            connect(frame, thin, color);
            continue;
        }
        if (s.points) {
            for (0..n) |k| if (std.math.isFinite(s.ys[k])) rl.drawCircleV(frame.toScreen(s.xs[k], s.ys[k]), 3, color);
            continue;
        }
        connect(frame, s, color);
    }
    ui.popClip();
    drawLegend(ui, .{ .x = inner.x + 10, .y = inner.y + inner.height - legend_height + 4, .width = inner.width - 20, .height = legend_height }, series, state, interactive);
}

// ------------------------------------------------------------------ tabela de dados

/// uma célula: o texto da tela e, se for número, o valor inteiro (o que vai para o CSV)
pub const Cell = struct {
    text: [:0]const u8,
    value: ?f64 = null,
    color: ?rl.Color = null,
};

/// cartão com uma tabela de dados: cabeçalho e linhas, em colunas de larguras `widths` (frações da largura; a
/// última fica com o resto). O botão direito exporta a tabela em CSV, com os números inteiros
pub fn table(ui: *widgets.Ui, rect: rl.Rectangle, title: [:0]const u8, headers: []const [:0]const u8, rows: []const []const Cell, widths: []const f32) void {
    const state = stateFor(title);
    if (state.pending) |_| {
        state.pending = null;
        exportTable(state, headers, rows);
    }
    const inner = widgets.labeledCard(ui, rect, title);
    var columns: [24]f32 = undefined;
    var x = inner.x;
    for (headers, 0..) |_, k| {
        if (k >= columns.len) break;
        columns[k] = x;
        x += inner.width * (if (k < widths.len) widths[k] else 0);
    }
    const count = @min(headers.len, columns.len);
    for (headers[0..count], 0..) |header, k| theme.text(ui.fonts.regular, header, columns[k], inner.y, 13, theme.colors.accent);
    var y = inner.y + 24;
    for (rows) |row| {
        for (row[0..@min(row.len, count)], 0..) |cell, k| theme.text(ui.fonts.regular, cell.text, columns[k], y, 14, cell.color orelse (if (k == 0) theme.colors.label else theme.colors.ink));
        y += 24;
        rl.drawRectangleRec(.{ .x = inner.x, .y = y - 5, .width = inner.width, .height = 1 }, theme.colors.grid);
    }
    if (ui.right_clicked and ui.hovering(rect)) {
        menu.open = true;
        menu.key = state.key;
        menu.at = ui.mouse;
        menu.is_table = true;
        menu.count = 0;
        menu.title_len = @min(title.len, menu.title.len);
        @memcpy(menu.title[0..menu.title_len], title[0..menu.title_len]);
        ui.right_clicked = false;
    }
}

/// a altura de uma tabela com `rows` linhas (para quem arruma os cartões)
pub fn tableHeight(rows: usize) f32 {
    return 34 + 8 + 24 + 24 * @as(f32, @floatFromInt(rows)) + 12;
}

fn exportTable(state: *State, headers: []const [:0]const u8, rows: []const []const Cell) void {
    const path = state.path[0..state.path_len];
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    writeTable(&out.writer, headers, rows) catch return setNote("não gravou {s}: sem memória", .{std.fs.path.basename(path)});
    std.Io.Dir.cwd().writeFile(fileIo(), .{ .sub_path = path, .data = out.written() }) catch |err| return setNote("não gravou {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
    system.offerDownload(path);
    setNote("gravado: {s} ({d} linhas)", .{ path, rows.len });
}

/// a tabela em CSV: o cabeçalho e uma linha por linha, com o número inteiro onde a célula tem valor
fn writeTable(writer: *std.Io.Writer, headers: []const [:0]const u8, rows: []const []const Cell) !void {
    for (headers, 0..) |header, k| {
        if (k > 0) try writer.writeByte(',');
        try export_file.writeText(writer, header);
    }
    try writer.writeAll("\n");
    for (rows) |row| {
        for (row, 0..) |cell, k| {
            if (k > 0) try writer.writeByte(',');
            if (cell.value) |value| {
                if (std.math.isFinite(value)) try writer.print("{d}", .{value});
            } else try export_file.writeText(writer, cell.text);
        }
        try writer.writeAll("\n");
    }
}

// ------------------------------------------------------------------ o estado de cada gráfico

pub const ExportKind = enum { png, pdf, csv };

const max_hidden = 16;

const State = struct {
    key: u64 = 0,
    hidden: [max_hidden]u64 = undefined, // os nomes (o hash) das curvas desligadas
    hidden_count: usize = 0,
    pending: ?ExportKind = null, // exportar no próximo quadro, com os dados de então
    path: [600]u8 = undefined,
    path_len: usize = 0,

    fn isHidden(state: *const State, name: []const u8) bool {
        const id = std.hash.Wyhash.hash(0, name);
        for (state.hidden[0..state.hidden_count]) |hidden| if (hidden == id) return true;
        return false;
    }

    fn toggle(state: *State, name: []const u8) void {
        const id = std.hash.Wyhash.hash(0, name);
        for (state.hidden[0..state.hidden_count], 0..) |hidden, k| if (hidden == id) {
            state.hidden[k] = state.hidden[state.hidden_count - 1];
            state.hidden_count -= 1;
            return;
        };
        if (state.hidden_count < max_hidden) {
            state.hidden[state.hidden_count] = id;
            state.hidden_count += 1;
        }
    }
};

var states: [128]State = undefined;
var state_count: usize = 0;
var spare_state: State = .{};

fn stateFor(title: []const u8) *State {
    const key = std.hash.Wyhash.hash(1, title);
    for (states[0..state_count]) |*state| if (state.key == key) return state;
    if (state_count == states.len) {
        spare_state = .{ .key = key };
        return &spare_state;
    }
    states[state_count] = .{ .key = key };
    state_count += 1;
    return &states[state_count - 1];
}

fn findState(key: u64) ?*State {
    for (states[0..state_count]) |*state| if (state.key == key) return state;
    return null;
}

// ------------------------------------------------------------------ o menu do botão direito e a gravação

const max_menu_series = 16;

/// o menu aberto: guarda os nomes das curvas do gráfico (copiados a cada quadro), para desenhar por cima de tudo
const Menu = struct {
    open: bool = false,
    key: u64 = 0,
    at: rl.Vector2 = .{ .x = 0, .y = 0 },
    title: [128]u8 = undefined,
    title_len: usize = 0,
    names: [max_menu_series][64:0]u8 = undefined,
    checked: [max_menu_series]bool = undefined,
    count: usize = 0,
    is_table: bool = false, // uma tabela: só exportar em CSV

    fn capture(m: *Menu, axes: Axes, series: []const Series, state: *const State) void {
        m.title_len = @min(axes.title.len, m.title.len);
        @memcpy(m.title[0..m.title_len], axes.title[0..m.title_len]);
        m.count = @min(series.len, max_menu_series);
        for (series[0..m.count], 0..) |s, k| {
            _ = widgets.format(&m.names[k], "{s}", .{s.name});
            m.checked[k] = !state.isHidden(s.name);
        }
    }
};

var menu: Menu = .{};
var saver: dialogs.FilePicker = .{};
var saver_kind: ExportKind = .png;
var saver_key: u64 = 0;
var note: [200:0]u8 = [_:0]u8{0} ** 200; // o resultado da última gravação
var note_frames: u32 = 0;

const actions = [_][:0]const u8{ "Exportar imagem PNG...", "Exportar PDF...", "Exportar CSV (curvas marcadas)...", "Marcar todas as curvas" };
const menu_row: f32 = 28;
const menu_width: f32 = 300;

const table_actions = [_][:0]const u8{"Exportar a tabela em CSV..."};

fn menuActions() []const [:0]const u8 {
    return if (menu.is_table) &table_actions else &actions;
}

fn menuRect(screen: rl.Rectangle) rl.Rectangle {
    const rows: f32 = @floatFromInt(menuActions().len + menu.count);
    const label_height: f32 = if (menu.is_table) 0 else 26;
    const height = 12 + menu_row * rows + label_height;
    return .{ .x = @min(menu.at.x, screen.width - menu_width - 4), .y = @min(menu.at.y, screen.height - height - 4), .width = menu_width, .height = height };
}

/// verdadeiro enquanto o menu ou o seletor de arquivo está aberto (a tela de baixo não recebe o clique)
pub fn overlayActive() bool {
    return menu.open or saver.open;
}

/// desenha o menu aberto, o seletor de arquivo e o aviso da última gravação; chamar depois da tela
pub fn overlay(ui: *widgets.Ui, width: f32, height: f32) void {
    const screen: rl.Rectangle = .{ .x = 0, .y = 0, .width = width, .height = height };
    if (note_frames > 0) {
        note_frames -= 1;
        const text = std.mem.sliceTo(&note, 0);
        const w = theme.textWidth(ui.fonts.regular, text, 14) + 24;
        const box: rl.Rectangle = .{ .x = width - w - 16, .y = height - 46, .width = w, .height = 32 };
        widgets.rounded(box, 8, theme.colors.ink);
        theme.text(ui.fonts.regular, text, box.x + 12, box.y + 8, 14, theme.colors.on_accent);
    }
    if (saver.open) {
        if (saver.draw(ui, screen)) |path| {
            if (findState(saver_key)) |state| {
                state.path_len = @min(path.len, state.path.len);
                @memcpy(state.path[0..state.path_len], path[0..state.path_len]);
                state.pending = saver_kind;
            }
        }
        return;
    }
    if (!menu.open) return;
    const area = menuRect(screen);
    if ((ui.clicked or ui.right_clicked) and !rl.checkCollisionPointRec(ui.mouse, area)) {
        menu.open = false;
        return;
    }
    if (rl.isKeyPressed(.escape)) {
        menu.open = false;
        return;
    }
    rl.drawRectangleRounded(.{ .x = area.x + 2, .y = area.y + 3, .width = area.width, .height = area.height }, 0.05, 6, .{ .r = 0, .g = 0, .b = 0, .a = 28 });
    widgets.rounded(area, 6, theme.colors.field);
    widgets.roundedLines(area, 6, theme.colors.line);
    var y = area.y + 6;
    for (menuActions(), 0..) |caption, k| {
        const row: rl.Rectangle = .{ .x = area.x + 4, .y = y, .width = area.width - 8, .height = menu_row };
        if (rl.checkCollisionPointRec(ui.mouse, row)) widgets.rounded(row, 4, theme.colors.hover);
        theme.text(ui.fonts.regular, caption, row.x + 10, row.y + 6, 14, theme.colors.accent);
        if (ui.clicked and rl.checkCollisionPointRec(ui.mouse, row)) chooseAction(if (menu.is_table) 2 else k);
        y += menu_row;
    }
    if (menu.is_table) {
        ui.click_taken = true;
        return;
    }
    theme.text(ui.fonts.regular, "curvas (marcadas = no gráfico e no CSV):", area.x + 12, y + 6, 12, theme.colors.muted);
    y += 26;
    for (0..menu.count) |k| {
        const row: rl.Rectangle = .{ .x = area.x + 4, .y = y, .width = area.width - 8, .height = menu_row };
        if (rl.checkCollisionPointRec(ui.mouse, row)) widgets.rounded(row, 4, theme.colors.hover);
        widgets.checkBox(.{ .x = row.x + 8, .y = row.y + 6, .width = 16, .height = 16 }, menu.checked[k]);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&menu.names[k], 0), row.x + 32, row.y + 6, 13, theme.colors.ink);
        if (ui.clicked and rl.checkCollisionPointRec(ui.mouse, row)) {
            if (findState(menu.key)) |state| state.toggle(std.mem.sliceTo(&menu.names[k], 0));
            menu.checked[k] = !menu.checked[k];
        }
        y += menu_row;
    }
    ui.click_taken = true;
}

fn chooseAction(index: usize) void {
    if (index == 3) {
        if (findState(menu.key)) |state| state.hidden_count = 0;
        menu.open = false;
        return;
    }
    const kinds = [_]ExportKind{ .png, .pdf, .csv };
    const extensions = [_][]const []const u8{ &.{".png"}, &.{".pdf"}, &.{".csv"} };
    saver_kind = kinds[index];
    saver_key = menu.key;
    var name_buffer: [160]u8 = undefined;
    const name = export_file.fileName(&name_buffer, menu.title[0..menu.title_len], @tagName(saver_kind));
    const titles = [_][]const u8{ "Exportar o gráfico (PNG)", "Exportar o gráfico (PDF)", "Exportar os dados (CSV)" };
    // na pasta pessoal: a pasta do programa instalado pode não aceitar escrita
    var home_buffer: [512]u8 = undefined;
    saver.showSave(titles[index], dialogs.home(&home_buffer), extensions[index], name);
    menu.open = false;
}

fn setNote(comptime format: []const u8, args: anytype) void {
    _ = std.fmt.bufPrintZ(&note, format, args) catch {};
    note_frames = 240;
}

fn fileIo() std.Io {
    return system.io();
}

/// grava o gráfico: CSV com as curvas marcadas; PNG e PDF com a imagem do cartão desenhada de novo numa textura,
/// em escala 2 (fica nítida impressa)
fn exportPlot(ui: *widgets.Ui, rect: rl.Rectangle, axes: Axes, series: []const Series, state: *State, kind: ExportKind) void {
    const path = state.path[0..state.path_len];
    const gpa = std.heap.page_allocator;
    if (kind == .csv) {
        var columns: [2 * 32]export_file.Column = undefined;
        var headers: [2 * 32][160]u8 = undefined;
        var count: usize = 0;
        for (series) |s| {
            if (state.isHidden(s.name) or count + 2 > columns.len) continue;
            const n = @min(s.xs.len, s.ys.len);
            columns[count] = .{ .name = std.fmt.bufPrint(&headers[count], "{s} · {s}", .{ s.name, axes.x_label }) catch s.name, .values = s.xs[0..n] };
            columns[count + 1] = .{ .name = std.fmt.bufPrint(&headers[count + 1], "{s} · {s}", .{ s.name, axes.y_label }) catch s.name, .values = s.ys[0..n] };
            count += 2;
        }
        export_file.saveCsv(gpa, fileIo(), path, columns[0..count]) catch |err| return setNote("não gravou {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        system.offerDownload(path);
        return setNote("gravado: {s} ({d} curvas)", .{ path, count / 2 });
    }
    const scale: f32 = 2;
    const width: i32 = @intFromFloat(@ceil(rect.width * scale));
    const height: i32 = @intFromFloat(@ceil(rect.height * scale));
    const target = rl.loadRenderTexture(width, height) catch return setNote("não gravou: sem memória de vídeo", .{});
    defer rl.unloadRenderTexture(target);
    // desenha o cartão de novo na textura: sem recorte da tela, sem mouse, com a câmera levando o cartão para (0, 0)
    const clips = ui.suspendClips();
    const mouse = ui.mouse;
    const clicked = ui.clicked;
    ui.mouse = .{ .x = -1e6, .y = -1e6 };
    ui.clicked = false;
    ui.clip_origin = .{ .x = rect.x, .y = rect.y };
    ui.clip_scale = scale;
    rl.beginTextureMode(target);
    rl.clearBackground(rl.Color.white);
    rl.beginMode2D(.{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = rect.x, .y = rect.y }, .rotation = 0, .zoom = scale });
    drawLines(ui, rect, axes, series, state, false);
    rl.endMode2D();
    rl.endTextureMode();
    ui.clip_origin = .{ .x = 0, .y = 0 };
    ui.clip_scale = 1;
    ui.mouse = mouse;
    ui.clicked = clicked;
    ui.resumeClips(clips);
    var image = rl.loadImageFromTexture(target.texture) catch return setNote("não gravou: não li a imagem", .{});
    defer rl.unloadImage(image);
    rl.imageFlipVertical(&image); // a textura sai de cabeça para baixo
    if (kind == .png) {
        var zero_path: [601]u8 = undefined;
        const text = std.fmt.bufPrintZ(&zero_path, "{s}", .{path}) catch return;
        if (!rl.exportImage(image, text)) return setNote("não gravou {s}", .{std.fs.path.basename(path)});
        system.offerDownload(path);
        return setNote("gravado: {s}", .{path});
    }
    rl.imageFormat(&image, .uncompressed_r8g8b8);
    const pixels: [*]const u8 = @ptrCast(image.data);
    const bytes = pixels[0..@as(usize, @intCast(width * height * 3))];
    // a página no tamanho do cartão na tela (1 pixel da tela = 0,75 pt, os 96 dpi de costume)
    export_file.savePdf(gpa, fileIo(), path, bytes, @intCast(width), @intCast(height), rect.width * 0.75, rect.height * 0.75) catch |err| return setNote("não gravou {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
    system.offerDownload(path);
    setNote("gravado: {s}", .{path});
}

/// o menor e o maior valor finito (null se não houver)
/// a linha que liga os pontos de `s` (um ponto que não é número corta a linha, como o `connect="finite"` da PyQt)
fn connect(frame: Frame, s: Series, color: rl.Color) void {
    const n = @min(s.xs.len, s.ys.len);
    var k: usize = 1;
    while (k < n) : (k += 1) {
        if (!finite2(s.xs[k - 1], s.ys[k - 1]) or !finite2(s.xs[k], s.ys[k])) continue;
        const a = frame.toScreen(s.xs[k - 1], s.ys[k - 1]);
        const b = frame.toScreen(s.xs[k], s.ys[k]);
        if (s.dashed) dashedLine(a, b, color) else rl.drawLineEx(a, b, s.width, color);
    }
}

fn finite2(x: f64, y: f64) bool {
    return std.math.isFinite(x) and std.math.isFinite(y);
}

/// a cor da sombra: a da curva, transparente (mais forte com `_strong`, como na GUI PyQt)
fn shade(color: rl.Color, strong: bool) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = if (strong) 110 else 45 };
}

/// a região entre a curva e a outra borda (`fill_ys` no mesmo x ou `fill_xs` no mesmo y), um quadrilátero por trecho
fn fillBetween(frame: Frame, s: Series, color: rl.Color) void {
    const along_x = s.fill_ys.len > 0;
    const other = if (along_x) s.fill_ys else s.fill_xs;
    const n = @min(@min(s.xs.len, s.ys.len), other.len);
    var k: usize = 1;
    while (k < n) : (k += 1) {
        if (!finite2(s.xs[k - 1], s.ys[k - 1]) or !finite2(s.xs[k], s.ys[k])) continue;
        if (!std.math.isFinite(other[k - 1]) or !std.math.isFinite(other[k])) continue;
        const a = frame.toScreen(s.xs[k - 1], s.ys[k - 1]);
        const b = frame.toScreen(s.xs[k], s.ys[k]);
        const c = if (along_x) frame.toScreen(s.xs[k], other[k]) else frame.toScreen(other[k], s.ys[k]);
        const d = if (along_x) frame.toScreen(s.xs[k - 1], other[k - 1]) else frame.toScreen(other[k - 1], s.ys[k - 1]);
        triangle(a, b, c, color);
        triangle(a, c, d, color);
    }
}

/// um triângulo cheio em qualquer ordem dos vértices (o raylib só desenha os de um sentido)
fn triangle(a: rl.Vector2, b: rl.Vector2, c: rl.Vector2, color: rl.Color) void {
    const turn = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (turn < 0) rl.drawTriangle(a, b, c, color) else rl.drawTriangle(a, c, b, color);
}

fn defaultMarkerSize(marker: Marker) f32 {
    return if (marker == .star) 18 else 11;
}

/// um símbolo de `size` pixels centrado em `at`, cheio na cor e com a borda escura (como na GUI PyQt)
pub fn drawMarker(marker: Marker, at: rl.Vector2, size: f32, color: rl.Color) void {
    const r = size / 2;
    const edge = theme.colors.ink;
    switch (marker) {
        .none => {},
        .circle => {
            rl.drawCircleV(at, r, color);
            rl.drawCircleLinesV(at, r, edge);
        },
        .square => {
            const box: rl.Rectangle = .{ .x = at.x - r, .y = at.y - r, .width = 2 * r, .height = 2 * r };
            rl.drawRectangleRec(box, color);
            rl.drawRectangleLinesEx(box, 1, edge);
        },
        .triangle, .diamond, .star => {
            // o contorno: 3 pontas (triângulo), 4 (losango) ou 5 com as reentrâncias (estrela)
            var corners: [10]rl.Vector2 = undefined;
            const count: usize = switch (marker) {
                .triangle => 3,
                .diamond => 4,
                else => 10,
            };
            for (0..count) |k| {
                const angle = -std.math.pi / 2.0 + 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(count));
                const radius = if (marker == .star and k % 2 == 1) r * 0.42 else r;
                corners[k] = .{ .x = at.x + radius * @cos(angle), .y = at.y + radius * @sin(angle) };
            }
            for (0..count) |k| triangle(at, corners[k], corners[(k + 1) % count], color);
            for (0..count) |k| rl.drawLineEx(corners[k], corners[(k + 1) % count], 1, edge);
        },
        .plus, .cross => {
            const d: f32 = if (marker == .cross) r * 0.7 else r;
            if (marker == .plus) {
                rl.drawLineEx(.{ .x = at.x - d, .y = at.y }, .{ .x = at.x + d, .y = at.y }, 2, color);
                rl.drawLineEx(.{ .x = at.x, .y = at.y - d }, .{ .x = at.x, .y = at.y + d }, 2, color);
            } else {
                rl.drawLineEx(.{ .x = at.x - d, .y = at.y - d }, .{ .x = at.x + d, .y = at.y + d }, 2, color);
                rl.drawLineEx(.{ .x = at.x - d, .y = at.y + d }, .{ .x = at.x + d, .y = at.y - d }, 2, color);
            }
        },
    }
}

fn extent(values: []const f64) ?numbers.Range {
    var low = std.math.inf(f64);
    var high = -std.math.inf(f64);
    for (values) |v| if (std.math.isFinite(v)) {
        low = @min(low, v);
        high = @max(high, v);
    };
    return if (low <= high) .{ .low = low, .high = high } else null;
}

/// cartão com a nuvem de pontos colorida pelo valor (com a barra de cores)
pub fn cloud(ui: *widgets.Ui, rect: rl.Rectangle, axes: Axes, points: Cloud) void {
    const inner = widgets.card(ui, rect, axes.title);
    const value_range = numbers.Range.of(points.values, 0);
    const frame = drawFrame(ui, .{ .x = inner.x, .y = inner.y, .width = inner.width - 64, .height = inner.height }, axes, numbers.Range.of(points.xs, 0.04), numbers.Range.of(points.ys, 0.06), 0, false);
    const n = @min(points.xs.len, @min(points.ys.len, points.values.len));
    for (0..n) |k| {
        const t = (points.values[k] - value_range.low) / (value_range.high - value_range.low);
        rl.drawCircleV(frame.toScreen(points.xs[k], points.ys[k]), 4, ramp(@floatCast(t)));
    }
    if (points.highlight) |best| if (best < n) {
        const center = frame.toScreen(points.xs[best], points.ys[best]);
        rl.drawCircleLinesV(center, 9, theme.colors.ink);
        rl.drawCircleLinesV(center, 10, theme.colors.ink);
    };
    colorBar(ui, .{ .x = inner.x + inner.width - 46, .y = frame.area.y, .width = 12, .height = frame.area.height }, value_range, points.value_name);
}

/// escala de cor contínua para um valor (0 = menor, 1 = maior): a viridis, que cresce em claridade de forma
/// uniforme e não inventa um "meio" que os dados não têm (cinco cores de referência, interpoladas)
pub fn ramp(fraction: f32) rl.Color {
    const stops = [_]rl.Color{ theme.hex(0x440154), theme.hex(0x3b528b), theme.hex(0x21918c), theme.hex(0x5ec962), theme.hex(0xfde725) };
    const t = std.math.clamp(fraction, 0, 1) * @as(f32, @floatFromInt(stops.len - 1));
    const k: usize = @min(@as(usize, @intFromFloat(@floor(t))), stops.len - 2);
    const s = t - @as(f32, @floatFromInt(k));
    const lerp = struct {
        fn f(a: u8, b: u8, w: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * w));
        }
    }.f;
    const a = stops[k];
    const b = stops[k + 1];
    return .{ .r = lerp(a.r, b.r, s), .g = lerp(a.g, b.g, s), .b = lerp(a.b, b.b, s), .a = 255 };
}

/// barra vertical da escala de cor, com marcas redondas e o nome do valor
pub fn colorBar(ui: *widgets.Ui, bar: rl.Rectangle, range: numbers.Range, name: [:0]const u8) void {
    const steps: usize = 64;
    const h = bar.height / @as(f32, @floatFromInt(steps));
    for (0..steps) |k| {
        const f = (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(steps));
        rl.drawRectangleRec(.{ .x = bar.x, .y = bar.y + bar.height - @as(f32, @floatFromInt(k + 1)) * h, .width = bar.width, .height = h + 0.5 }, ramp(f));
    }
    const step = numbers.niceStep(range.high - range.low, 4);
    var buffer: [32]u8 = undefined;
    var v = @ceil(range.low / step) * step;
    while (v <= range.high + step * 1e-9) : (v += step) {
        const f: f32 = @floatCast((v - range.low) / (range.high - range.low));
        const y = bar.y + bar.height - f * bar.height;
        rl.drawLineEx(.{ .x = bar.x + bar.width, .y = y }, .{ .x = bar.x + bar.width + 4, .y = y }, 1, theme.colors.muted);
        theme.text(ui.fonts.mono, tickText(&buffer, v, step), bar.x + bar.width + 6, y - 7, 12, theme.colors.muted);
    }
    theme.text(ui.fonts.regular, name, bar.x, bar.y + bar.height + 8, 12, theme.colors.label);
}

/// eixos, marcas, grade e rótulos; devolve onde desenhar
pub fn drawFrame(ui: *widgets.Ui, inner: rl.Rectangle, axes: Axes, x_data: numbers.Range, y_data: numbers.Range, legend_height: f32, equal_axes: bool) Frame {
    const area: rl.Rectangle = .{ .x = inner.x + 58, .y = inner.y + 6, .width = inner.width - 70, .height = inner.height - 52 - legend_height };
    var x_range_data = x_data;
    var y_range_data = y_data;
    if (equal_axes) { // o mesmo metro por pixel nos dois eixos (a geometria não deforma)
        const per_pixel = @max((x_data.high - x_data.low) / area.width, (y_data.high - y_data.low) / area.height);
        const cx = 0.5 * (x_data.low + x_data.high);
        const cy = 0.5 * (y_data.low + y_data.high);
        x_range_data = .{ .low = cx - per_pixel * area.width / 2, .high = cx + per_pixel * area.width / 2 };
        y_range_data = .{ .low = cy - per_pixel * area.height / 2, .high = cy + per_pixel * area.height / 2 };
    }
    const x_step = numbers.niceStep(x_range_data.high - x_range_data.low, 6);
    const y_step = numbers.niceStep(y_range_data.high - y_range_data.low, 5);
    const frame: Frame = .{ .area = area, .x_range = x_range_data, .y_range = y_range_data };
    var buffer: [32]u8 = undefined;
    // grade e marcas de x
    var x = @ceil(x_range_data.low / x_step) * x_step;
    while (x <= x_range_data.high + x_step * 1e-9) : (x += x_step) {
        const p = frame.toScreen(x, y_range_data.low);
        const is_zero = @abs(x) < x_step * 1e-6;
        rl.drawLineEx(.{ .x = p.x, .y = area.y }, .{ .x = p.x, .y = area.y + area.height }, 1, if (is_zero) theme.colors.line else theme.colors.grid);
        const tick = tickText(&buffer, x, x_step);
        const w = theme.textWidth(ui.fonts.mono, tick, 12);
        theme.text(ui.fonts.mono, tick, p.x - w / 2, area.y + area.height + 6, 12, theme.colors.muted);
    }
    // grade e marcas de y
    var y = @ceil(y_range_data.low / y_step) * y_step;
    while (y <= y_range_data.high + y_step * 1e-9) : (y += y_step) {
        const p = frame.toScreen(x_range_data.low, y);
        const is_zero = @abs(y) < y_step * 1e-6;
        rl.drawLineEx(.{ .x = area.x, .y = p.y }, .{ .x = area.x + area.width, .y = p.y }, 1, if (is_zero) theme.colors.line else theme.colors.grid);
        const tick = tickText(&buffer, y, y_step);
        const w = theme.textWidth(ui.fonts.mono, tick, 12);
        theme.text(ui.fonts.mono, tick, area.x - w - 8, p.y - 7, 12, theme.colors.muted);
    }
    // rótulos dos eixos
    const xw = tex.width(ui.fonts.regular, axes.x_label, 13);
    _ = tex.draw(ui.fonts.regular, axes.x_label, area.x + (area.width - xw) / 2, area.y + area.height + 24, 13, theme.colors.label);
    const yw = tex.width(ui.fonts.regular, axes.y_label, 13);
    tex.drawRotated(ui.fonts.regular, axes.y_label, inner.x + 2, area.y + (area.height + yw) / 2, 13, theme.colors.label);
    return frame;
}

fn tickText(buffer: []u8, value: f64, step: f64) [:0]const u8 {
    const decimals = numbers.decimalsFor(step);
    const v = if (@abs(value) < step * 1e-6) 0 else value;
    return switch (decimals) {
        0 => std.fmt.bufPrintZ(buffer, "{d:.0}", .{v}),
        1 => std.fmt.bufPrintZ(buffer, "{d:.1}", .{v}),
        2 => std.fmt.bufPrintZ(buffer, "{d:.2}", .{v}),
        3 => std.fmt.bufPrintZ(buffer, "{d:.3}", .{v}),
        else => std.fmt.bufPrintZ(buffer, "{e:.1}", .{v}),
    } catch "…";
}

fn dashedLine(a: rl.Vector2, b: rl.Vector2, color: rl.Color) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.5) return;
    const dash: f32 = 7;
    var s: f32 = 0;
    while (s < length) : (s += dash * 2) {
        const e = @min(s + dash, length);
        rl.drawLineEx(.{ .x = a.x + dx * s / length, .y = a.y + dy * s / length }, .{ .x = a.x + dx * e / length, .y = a.y + dy * e / length }, 2.2, color);
    }
}

const legend_row: f32 = 18;

fn legendItemWidth(ui: *widgets.Ui, name: [:0]const u8) f32 {
    return 28 + tex.width(ui.fonts.regular, name, 12) + 18;
}

fn legendHeight(ui: *widgets.Ui, width: f32, series: []const Series) f32 {
    if (series.len == 0) return 0;
    var rows: f32 = 1;
    var x: f32 = 0;
    for (series) |s| {
        if (!s.in_legend) continue;
        const w = legendItemWidth(ui, s.name);
        if (x > 0 and x + w > width - 20) {
            rows += 1;
            x = 0;
        }
        x += w;
    }
    return rows * legend_row + 6;
}

fn drawLegend(ui: *widgets.Ui, rect: rl.Rectangle, series: []const Series, state: *State, interactive: bool) void {
    var x = rect.x;
    var y = rect.y;
    for (series, 0..) |s, i| {
        if (!s.in_legend) continue;
        const w = legendItemWidth(ui, s.name);
        if (x > rect.x and x + w > rect.x + rect.width) {
            x = rect.x;
            y += legend_row;
        }
        const hidden = state.isHidden(s.name);
        const item: rl.Rectangle = .{ .x = x - 3, .y = y - 2, .width = w - 12, .height = legend_row };
        if (interactive and ui.hovering(item)) widgets.rounded(item, 4, theme.colors.hover);
        if (interactive and ui.clickedIn(item)) state.toggle(s.name);
        const color = if (hidden) theme.colors.line else s.colorAt(i);
        if (s.span or s.fill_ys.len > 0 or s.fill_xs.len > 0) {
            rl.drawRectangleRec(.{ .x = x + 2, .y = y + 2, .width = 18, .height = 10 }, shade(color, true));
        } else if (s.marker != .none) drawMarker(s.marker, .{ .x = x + 11, .y = y + 7 }, 11, color) else if (s.points) rl.drawCircleV(.{ .x = x + 11, .y = y + 7 }, 3.5, color) else if (s.dashed) dashedLine(.{ .x = x, .y = y + 7 }, .{ .x = x + 22, .y = y + 7 }, color) else rl.drawLineEx(.{ .x = x, .y = y + 7 }, .{ .x = x + 22, .y = y + 7 }, 2.2, color);
        _ = tex.draw(ui.fonts.regular, s.name, x + 28, y, 12, if (hidden) theme.colors.muted else theme.colors.label);
        if (hidden) rl.drawLineEx(.{ .x = x + 26, .y = y + 7 }, .{ .x = x + w - 16, .y = y + 7 }, 1, theme.colors.muted);
        x += w;
    }
}

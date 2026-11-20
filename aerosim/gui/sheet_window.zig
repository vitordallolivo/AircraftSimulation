//! A janela "Planilha…" de cada área: a planilha `.xlsx` aparece como no Excel, a partir do A1, com a largura das
//! colunas, a altura das linhas, as células mescladas e as cores, o negrito e as bordas do próprio arquivo. Arrastar
//! sobre as células marca o bloco (um clique só marca o canto de cima, e o bloco desce sozinho enquanto houver
//! números); ao lado ficam o tipo do bloco (os da área), qual coluna é qual, o nome e o gráfico do bloco. A conta
//! (ler o bloco, sugerir as colunas, guardar) é de `design/sheets.zig`; aqui só se desenha e se passa o pedido.
//!
//!     roda          desce e sobe as linhas          Shift + roda    anda pelas colunas
//!     Ctrl + roda   aproxima e afasta               Esc             fecha
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const design = @import("design");

const widgets = ui_kit.widgets;
const theme = ui_kit.theme;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const sheets = design.sheets;
const xlsx = sheets.xlsx;

/// largura da coluna dos números das linhas e altura da linha das letras das colunas
const row_header_width: f32 = 46;
const column_header_height: f32 = 22;
/// o papel do Excel: a folha é sempre branca, com a grade cinza, nos dois modos de cor (as cores são do arquivo)
const paper = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const gridline = rl.Color{ .r = 218, .g = 220, .b = 224, .a = 255 };
const max_visible = 256;

/// uma célula da aba (linha e coluna de 1)
const Place = struct { row: u32 = 1, column: u32 = 1 };

pub const SheetWindow = struct {
    open: bool = false,
    area_buffer: [48]u8 = undefined,
    area_len: usize = 0,
    /// a primeira linha e coluna à vista (a rolagem anda de célula em célula)
    first_row: u32 = 1,
    first_column: u32 = 1,
    zoom: f32 = 1,
    dragging: bool = false,
    /// o bloco que a grade já mostrou (outro bloco: a grade anda até ele)
    seen_range: [32]u8 = undefined,
    seen_range_len: usize = 0,
    anchor: Place = .{},
    current: Place = .{},
    picker: ui_kit.dialogs.FilePicker = .{},
    /// no navegador: o seletor do aparelho está aberto e o arquivo escolhido vem para cá
    waiting_device: bool = false,
    message: [240:0]u8 = [_:0]u8{0} ** 240,
    // o formulário do lado: tipo, colunas e nome
    groups: [3]form_mod.Group = .{ .{ .title = "Bloco" }, .{ .title = "Qual coluna é qual" }, .{ .title = "Guardar" } },
    fields: [12]form_mod.Field = undefined,
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    labels: [12][64:0]u8 = undefined,
    header_choices: [4096:0]u8 = [_:0]u8{0} ** 4096,
    /// o tipo, a aba e o bloco para os quais o formulário foi montado
    built_kind: ?sheets.Kind = null,
    built_sheet: usize = 0,
    built_range: [32]u8 = undefined,
    built_range_len: usize = 0,
    built_book: ?*const anyopaque = null,
    frame: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    /// abre a janela para a área `area` (os tipos de bloco são os dela)
    pub fn show(window: *SheetWindow, area: []const u8) void {
        window.area_len = @min(area.len, window.area_buffer.len);
        @memcpy(window.area_buffer[0..window.area_len], area[0..window.area_len]);
        sheets.setArea(area);
        window.open = true;
        window.built_kind = null;
        window.say("", .{});
        if (sheets.workbook() == null) window.pick();
    }

    /// a área da tela por trás (quando a janela abriu antes de as áreas chegarem, como no print)
    pub fn follow(window: *SheetWindow, area: []const u8) void {
        if (window.area_len > 0 or area.len == 0) return;
        window.area_len = @min(area.len, window.area_buffer.len);
        @memcpy(window.area_buffer[0..window.area_len], area[0..window.area_len]);
        sheets.setArea(area);
        window.built_kind = null;
    }

    fn areaName(window: *const SheetWindow) []const u8 {
        return window.area_buffer[0..window.area_len];
    }

    fn say(window: *SheetWindow, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&window.message, fmt, args) catch {};
    }

    /// pede a planilha: no navegador, o seletor do aparelho; no PC, a janela de arquivos
    fn pick(window: *SheetWindow) void {
        if (ui_kit.system.pickFromDevice()) {
            window.waiting_device = true;
            return;
        }
        window.picker.show("Abrir planilha (.xlsx)", ".", &.{".xlsx"});
    }

    /// abre a planilha escolhida (pela janela de arquivos, pelo aparelho ou arrastada para a tela)
    pub fn openPath(window: *SheetWindow, path: []const u8) void {
        window.waiting_device = false;
        window.picker.open = false;
        const problem = sheets.open(ui_kit.system.io(), path) catch "faltou memória para abrir a planilha";
        window.first_row = 1;
        window.first_column = 1;
        window.built_kind = null;
        if (problem.len > 0) return window.say("{s}", .{problem});
        sheets.setArea(window.areaName());
        window.say("aberta: {s}. Arraste sobre as células para marcar o bloco (a primeira linha são os títulos)", .{std.fs.path.basename(path)});
    }

    /// desenha a janela por cima de `whole`
    pub fn draw(window: *SheetWindow, ui: *widgets.Ui, whole: rl.Rectangle) void {
        if (!window.open) return;
        _ = window.frame.reset(.retain_capacity);
        const memory = window.frame.allocator();
        const picker_open = window.picker.open;
        const wheel = ui.wheel;
        if (picker_open) {
            ui.click_taken = true;
            ui.wheel = 0;
        }
        rl.drawRectangleRec(whole, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const margin: f32 = if (ui_kit.phone.isPhone(whole.width)) 6 else 28;
        const box: rl.Rectangle = .{ .x = whole.x + margin, .y = whole.y + margin, .width = whole.width - 2 * margin, .height = whole.height - 2 * margin };
        const title = std.fmt.allocPrintSentinel(memory, "Planilha · {s}", .{window.areaName()}, 0) catch "Planilha";
        const inner = widgets.card(ui, box, title);

        // a barra de cima: abrir, o arquivo e o bloco marcado
        const bar_y = inner.y + 2;
        if (ui_kit.dialogs.button(ui, .{ .x = inner.x + 6, .y = bar_y, .width = 150, .height = 30 }, "Abrir planilha…")) window.pick();
        const opened = sheets.openedPath();
        const file_text = std.fmt.allocPrintSentinel(memory, "{s}", .{if (opened.len > 0) std.fs.path.basename(opened) else "nenhuma planilha aberta"}, 0) catch "";
        theme.text(ui.fonts.bold, file_text, inner.x + 170, bar_y + 7, 15, theme.colors.ink);
        const range_x = inner.x + 180 + theme.textWidth(ui.fonts.bold, file_text, 15) + 20;
        const range_text = std.fmt.allocPrintSentinel(memory, "bloco {s}", .{if (sheets.markedRange().len > 0) sheets.markedRange() else "—"}, 0) catch "";
        theme.text(ui.fonts.regular, range_text, range_x, bar_y + 7, 15, theme.colors.accent);
        theme.text(ui.fonts.regular, "arraste sobre as células para marcar o bloco · um clique marca só o canto de cima (o bloco desce enquanto houver números)", range_x + theme.textWidth(ui.fonts.regular, range_text, 15) + 18, bar_y + 8, 13, theme.colors.muted);

        const side_width = @min(400, inner.width * 0.32);
        const body_top = bar_y + 40;
        const body: rl.Rectangle = .{ .x = inner.x, .y = body_top, .width = inner.width - side_width - 12, .height = inner.y + inner.height - body_top };
        const side: rl.Rectangle = .{ .x = body.x + body.width + 12, .y = body_top, .width = side_width, .height = body.height };

        if (sheets.workbook()) |book| {
            const tabs_height: f32 = 32;
            const grid: rl.Rectangle = .{ .x = body.x, .y = body.y, .width = body.width, .height = body.height - tabs_height };
            const index = @min(sheets.sheetIndex(), book.sheets.len - 1);
            window.drawGrid(ui, memory, grid, book.sheets[index]);
            const labels: [][:0]const u8 = memory.alloc([:0]const u8, book.sheets.len) catch &.{};
            for (labels, book.sheets) |*label, sheet| label.* = memory.dupeZ(u8, sheet.name) catch "";
            var active = index;
            ui.pushClip(.{ .x = body.x, .y = grid.y + grid.height, .width = body.width, .height = tabs_height });
            if (widgets.tabBar(ui, .{ .x = body.x, .y = grid.y + grid.height, .width = body.width, .height = tabs_height }, labels, &active, 13)) {
                sheets.selectSheet(active);
                window.first_row = 1;
                window.first_column = 1;
            }
            ui.popClip();
        } else {
            widgets.rounded(body, 8, theme.colors.background);
            const hint: [:0]const u8 = if (window.waiting_device) "escolha a planilha no seletor do aparelho" else "abra uma planilha .xlsx com \"Abrir planilha…\"";
            const width = theme.textWidth(ui.fonts.regular, hint, 16);
            theme.text(ui.fonts.regular, hint, body.x + (body.width - width) / 2, body.y + body.height / 2 - 8, 16, theme.colors.muted);
        }
        window.drawSide(ui, memory, side);

        if (!picker_open and window.form.editing == null and rl.isKeyPressed(.escape)) window.open = false;
        ui.click_taken = true;
        ui.wheel = 0;
        if (picker_open) {
            ui.click_taken = false;
            ui.wheel = wheel;
            if (window.picker.draw(ui, whole)) |path| window.openPath(path);
            ui.click_taken = true;
            ui.wheel = 0;
        }
    }

    // ------------------------------------------------------------------ a grade

    fn columnPixels(window: *const SheetWindow, sheet: xlsx.Sheet, column: u32) f32 {
        return xlsx.pixels(sheet.columnWidth(column)) * window.zoom;
    }

    fn rowPixels(window: *const SheetWindow, sheet: xlsx.Sheet, row: u32) f32 {
        return sheet.rowHeight(row) * 4.0 / 3.0 * window.zoom;
    }

    /// a borda esquerda da coluna na tela (a coluna pode estar antes da primeira à vista)
    fn columnLeft(window: *const SheetWindow, sheet: xlsx.Sheet, origin: f32, column: u32) f32 {
        var x = origin;
        if (column >= window.first_column) {
            var k = window.first_column;
            while (k < column and k < window.first_column + 2000) : (k += 1) x += window.columnPixels(sheet, k);
        } else {
            var k = column;
            while (k < window.first_column) : (k += 1) x -= window.columnPixels(sheet, k);
        }
        return x;
    }

    fn rowTop(window: *const SheetWindow, sheet: xlsx.Sheet, origin: f32, row: u32) f32 {
        var y = origin;
        if (row >= window.first_row) {
            var k = window.first_row;
            while (k < row and k < window.first_row + 2000) : (k += 1) y += window.rowPixels(sheet, k);
        } else {
            var k = row;
            while (k < window.first_row) : (k += 1) y -= window.rowPixels(sheet, k);
        }
        return y;
    }

    /// o retângulo marcado: o bloco lido (no modo do canto, até onde ele desce) ou o arraste em curso
    fn selection(window: *const SheetWindow, memory: std.mem.Allocator) ?xlsx.Range {
        if (window.dragging) return .{
            .first_row = @min(window.anchor.row, window.current.row),
            .first_column = @min(window.anchor.column, window.current.column),
            .last_row = @max(window.anchor.row, window.current.row),
            .last_column = @max(window.anchor.column, window.current.column),
        };
        const marked = sheets.markedBlock(memory) orelse return null;
        return .{
            .first_row = marked.first_row,
            .first_column = marked.first_column,
            .last_row = marked.last_row,
            .last_column = marked.first_column + @as(u32, @intCast(marked.headers.len)) - 1,
        };
    }

    fn drawGrid(window: *SheetWindow, ui: *widgets.Ui, memory: std.mem.Allocator, rect: rl.Rectangle, sheet: xlsx.Sheet) void {
        const last_row = @max(sheet.lastStyledRow(), 1);
        const last_column = @max(sheet.lastColumn(), 1);
        // rolagem: a roda desce as linhas; com Shift, anda pelas colunas; com Ctrl, aproxima
        if (ui.hovering(rect) and !ui.click_taken) {
            const sideways = rl.getMouseWheelMoveV().x;
            if (rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control)) {
                if (ui.wheel != 0) window.zoom = std.math.clamp(window.zoom * (if (ui.wheel > 0) @as(f32, 1.1) else @as(f32, 1.0 / 1.1)), 0.4, 2.5);
            } else if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift) or sideways != 0) {
                const step = if (sideways != 0) -sideways else ui.wheel;
                window.first_column = scrolled(window.first_column, -step * 2, last_column);
            } else if (ui.wheel != 0) window.first_row = scrolled(window.first_row, -ui.wheel * 3, last_row);
        }

        rl.drawRectangleRec(rect, theme.colors.panel);
        const cells: rl.Rectangle = .{ .x = rect.x + row_header_width, .y = rect.y + column_header_height, .width = rect.width - row_header_width, .height = rect.height - column_header_height };
        rl.drawRectangleRec(cells, paper);

        // as colunas e linhas à vista
        var column_x: [max_visible + 1]f32 = undefined;
        var column_count: usize = 0;
        var x = cells.x;
        while (column_count < max_visible and x < cells.x + cells.width) : (column_count += 1) {
            column_x[column_count] = x;
            x += window.columnPixels(sheet, window.first_column + @as(u32, @intCast(column_count)));
        }
        column_x[column_count] = x;
        var row_y: [max_visible + 1]f32 = undefined;
        var row_count: usize = 0;
        var y = cells.y;
        while (row_count < max_visible and y < cells.y + cells.height) : (row_count += 1) {
            row_y[row_count] = y;
            y += window.rowPixels(sheet, window.first_row + @as(u32, @intCast(row_count)));
        }
        row_y[row_count] = y;

        const marked = window.selection(memory);
        // o bloco achado sozinho (ou escrito) fora da vista: a grade anda até ele
        if (!window.dragging and !std.mem.eql(u8, sheets.markedRange(), window.seen_range[0..window.seen_range_len])) {
            window.seen_range_len = @min(sheets.markedRange().len, window.seen_range.len);
            @memcpy(window.seen_range[0..window.seen_range_len], sheets.markedRange()[0..window.seen_range_len]);
            if (marked) |range| {
                const last_visible_column = window.first_column + @as(u32, @intCast(column_count)) -| 2;
                const last_visible_row = window.first_row + @as(u32, @intCast(row_count)) -| 2;
                if (range.first_column < window.first_column or range.first_column > last_visible_column) window.first_column = @max(range.first_column, 2) - 1;
                if (range.first_row < window.first_row or range.first_row > last_visible_row) window.first_row = @max(range.first_row, 3) - 2;
            }
        }
        ui.pushClip(cells);
        // a grade fina, por baixo das cores
        for (column_x[0 .. column_count + 1]) |line_x| rl.drawLineV(.{ .x = line_x, .y = cells.y }, .{ .x = line_x, .y = @min(y, cells.y + cells.height) }, gridline);
        for (row_y[0 .. row_count + 1]) |line_y| rl.drawLineV(.{ .x = cells.x, .y = line_y }, .{ .x = @min(x, cells.x + cells.width), .y = line_y }, gridline);

        // as células: o fundo e as bordas de cada uma (a mesclada, uma vez, com o estilo do canto)
        for (0..row_count) |j| for (0..column_count) |i| {
            const row = window.first_row + @as(u32, @intCast(j));
            const column = window.first_column + @as(u32, @intCast(i));
            if (sheet.mergeAt(row, column)) |merge| {
                const first_visible_row = @max(merge.first_row, window.first_row);
                const first_visible_column = @max(merge.first_column, window.first_column);
                if (row != first_visible_row or column != first_visible_column) continue;
                const box = window.mergeRect(sheet, cells, merge);
                window.drawCell(ui, memory, sheet, box, merge.first_row, merge.first_column, true, cells);
                continue;
            }
            const box: rl.Rectangle = .{ .x = column_x[i], .y = row_y[j], .width = column_x[i + 1] - column_x[i], .height = row_y[j + 1] - row_y[j] };
            if (box.width <= 0) continue;
            window.drawCell(ui, memory, sheet, box, row, column, false, cells);
        };

        // o bloco marcado: um véu azul e a borda grossa
        if (marked) |range| {
            const left = window.columnLeft(sheet, cells.x, range.first_column);
            const top = window.rowTop(sheet, cells.y, range.first_row);
            const right = window.columnLeft(sheet, cells.x, range.last_column + 1);
            const bottom = window.rowTop(sheet, cells.y, range.last_row + 1);
            const box: rl.Rectangle = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
            rl.drawRectangleRec(box, rl.colorAlpha(theme.colors.accent, 0.12));
            rl.drawRectangleLinesEx(box, 2.5, theme.colors.accent);
            // a linha dos títulos, um pouco mais forte
            const header_bottom = window.rowTop(sheet, cells.y, range.first_row + 1);
            rl.drawRectangleRec(.{ .x = left, .y = top, .width = right - left, .height = header_bottom - top }, rl.colorAlpha(theme.colors.accent, 0.12));
        }
        ui.popClip();

        // as letras das colunas e os números das linhas
        ui.pushClip(.{ .x = cells.x, .y = rect.y, .width = cells.width, .height = column_header_height });
        for (0..column_count) |i| {
            const column = window.first_column + @as(u32, @intCast(i));
            const box: rl.Rectangle = .{ .x = column_x[i], .y = rect.y, .width = column_x[i + 1] - column_x[i], .height = column_header_height };
            const inside = if (marked) |range| column >= range.first_column and column <= range.last_column else false;
            if (inside) rl.drawRectangleRec(box, rl.colorAlpha(theme.colors.accent, 0.25));
            rl.drawLineV(.{ .x = box.x, .y = box.y }, .{ .x = box.x, .y = box.y + box.height }, theme.colors.line);
            var letters: [4]u8 = undefined;
            const name = memory.dupeZ(u8, sheets.columnName(&letters, column)) catch "";
            const width = theme.textWidth(ui.fonts.regular, name, 12);
            if (box.width > width) theme.text(ui.fonts.regular, name, box.x + (box.width - width) / 2, box.y + 4, 12, if (inside) theme.colors.accent else theme.colors.muted);
        }
        ui.popClip();
        ui.pushClip(.{ .x = rect.x, .y = cells.y, .width = row_header_width, .height = cells.height });
        for (0..row_count) |j| {
            const row = window.first_row + @as(u32, @intCast(j));
            const box: rl.Rectangle = .{ .x = rect.x, .y = row_y[j], .width = row_header_width, .height = row_y[j + 1] - row_y[j] };
            const inside = if (marked) |range| row >= range.first_row and row <= range.last_row else false;
            if (inside) rl.drawRectangleRec(box, rl.colorAlpha(theme.colors.accent, 0.25));
            rl.drawLineV(.{ .x = box.x, .y = box.y }, .{ .x = box.x + box.width, .y = box.y }, theme.colors.line);
            const number = std.fmt.allocPrintSentinel(memory, "{d}", .{row}, 0) catch "";
            const width = theme.textWidth(ui.fonts.regular, number, 12);
            if (box.height > 10) theme.text(ui.fonts.regular, number, box.x + (box.width - width) / 2, box.y + (box.height - 12) / 2, 12, if (inside) theme.colors.accent else theme.colors.muted);
        }
        ui.popClip();

        // marcar: apertar numa célula começa, arrastar estende, soltar marca o bloco
        if (!ui.click_taken and ui.pressed and ui.hovering(cells)) if (placeAt(ui.mouse, window.first_row, window.first_column, column_x[0 .. column_count + 1], row_y[0 .. row_count + 1])) |place| {
            window.dragging = true;
            window.anchor = place;
            window.current = place;
        };
        if (window.dragging) {
            if (placeAt(ui.mouse, window.first_row, window.first_column, column_x[0 .. column_count + 1], row_y[0 .. row_count + 1])) |place| window.current = place;
            if (!rl.isMouseButtonDown(.left)) {
                window.dragging = false;
                var first: [4]u8 = undefined;
                var last: [4]u8 = undefined;
                const top_row = @min(window.anchor.row, window.current.row);
                const left_column = @min(window.anchor.column, window.current.column);
                const text = if (window.anchor.row == window.current.row and window.anchor.column == window.current.column)
                    std.fmt.allocPrint(memory, "{s}{d}", .{ sheets.columnName(&first, left_column), top_row })
                else
                    std.fmt.allocPrint(memory, "{s}{d}:{s}{d}", .{ sheets.columnName(&first, left_column), top_row, sheets.columnName(&last, @max(window.anchor.column, window.current.column)), @max(window.anchor.row, window.current.row) });
                if (text) |range| sheets.setRange(range) else |_| {}
            }
        }
        rl.drawRectangleLinesEx(rect, 1, theme.colors.line);
    }

    fn mergeRect(window: *const SheetWindow, sheet: xlsx.Sheet, cells: rl.Rectangle, merge: xlsx.Range) rl.Rectangle {
        const left = window.columnLeft(sheet, cells.x, merge.first_column);
        const top = window.rowTop(sheet, cells.y, merge.first_row);
        const right = window.columnLeft(sheet, cells.x, merge.last_column + 1);
        const bottom = window.rowTop(sheet, cells.y, merge.last_row + 1);
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }

    /// uma célula (ou um grupo mesclado) com o fundo, as bordas e o texto do arquivo
    fn drawCell(window: *const SheetWindow, ui: *widgets.Ui, memory: std.mem.Allocator, sheet: xlsx.Sheet, box: rl.Rectangle, row: u32, column: u32, merged: bool, cells: rl.Rectangle) void {
        const style = sheet.styleAt(row, column);
        if (style.fill) |fill| rl.drawRectangleRec(box, color(fill)) else if (merged) rl.drawRectangleRec(.{ .x = box.x + 1, .y = box.y + 1, .width = box.width - 1, .height = box.height - 1 }, paper);
        const ink = rl.Color{ .r = 30, .g = 30, .b = 30, .a = 255 };
        if (style.borders.left) rl.drawLineEx(.{ .x = box.x, .y = box.y }, .{ .x = box.x, .y = box.y + box.height }, 1, ink);
        if (style.borders.right) rl.drawLineEx(.{ .x = box.x + box.width, .y = box.y }, .{ .x = box.x + box.width, .y = box.y + box.height }, 1, ink);
        if (style.borders.top) rl.drawLineEx(.{ .x = box.x, .y = box.y }, .{ .x = box.x + box.width, .y = box.y }, 1, ink);
        if (style.borders.bottom) rl.drawLineEx(.{ .x = box.x, .y = box.y + box.height }, .{ .x = box.x + box.width, .y = box.y + box.height }, 1, ink);
        const value = sheet.at(row, column) orelse return;
        const text = sheets.displayText(memory, value, style) catch return;
        if (text.len == 0) return;
        var shown: [:0]const u8 = memory.dupeZ(u8, text) catch return;
        const size = std.math.clamp(style.size * 4.0 / 3.0 * 0.9 * window.zoom, 7, 64);
        const font = if (style.bold) ui.fonts.bold else ui.fonts.regular;
        var width = theme.textWidth(font, shown, size);
        const is_number = value == .number;
        // o número que não cabe: no formato "Geral" perde casas, como no Excel; sem caber nem assim, "#"
        if (is_number and !merged and width > box.width - 4) {
            var fitted = false;
            if (style.decimals == null) {
                var decimals: u8 = 4;
                while (true) : (decimals -= 1) {
                    var shorter = style;
                    shorter.decimals = decimals;
                    const retry = sheets.displayText(memory, value, shorter) catch break;
                    shown = memory.dupeZ(u8, retry) catch break;
                    width = theme.textWidth(font, shown, size);
                    if (width <= box.width - 4) {
                        fitted = true;
                        break;
                    }
                    if (decimals == 0) break;
                }
            }
            if (!fitted) {
                shown = "#";
                width = theme.textWidth(font, shown, size);
            }
        }
        const alignment: xlsx.Alignment = if (style.alignment == .general) (if (is_number) .right else .left) else style.alignment;
        // o texto à esquerda passa por cima das vizinhas vazias, como no Excel
        var clip = box;
        if (!merged and alignment == .left and width > box.width) {
            var next = column + 1;
            var right = box.x + box.width;
            while (right < cells.x + cells.width and next < column + 30 and sheet.at(row, next) == null and sheet.mergeAt(row, next) == null) : (next += 1) {
                right += window.columnPixels(sheet, next);
                if (right - box.x >= width + 6) break;
            }
            clip.width = right - box.x;
        }
        const text_x = switch (alignment) {
            .center => box.x + (box.width - width) / 2,
            .right => box.x + box.width - width - 3,
            else => box.x + 3,
        };
        ui.pushClip(clip);
        theme.text(font, shown, text_x, box.y + (box.height - size) / 2, size, color(style.font_color));
        ui.popClip();
    }

    // ------------------------------------------------------------------ o lado: tipo, colunas, nome e gráfico

    /// monta o formulário de novo quando o tipo, a aba ou o bloco mudaram
    fn rebuild(window: *SheetWindow, memory: std.mem.Allocator) void {
        const range = sheets.markedRange();
        const book_id: ?*const anyopaque = if (sheets.workbook()) |book| @ptrCast(book.sheets.ptr) else null;
        if (window.built_kind == sheets.markedKind() and window.built_sheet == sheets.sheetIndex() and book_id == window.built_book and
            std.mem.eql(u8, range, window.built_range[0..window.built_range_len])) return;
        // o nome digitado sem Enter não se perde ao montar de novo
        for (window.form.fields) |*field| if (field.kind == .text and field.group == 2) sheets.setName(field.textValue());
        window.built_kind = sheets.markedKind();
        window.built_sheet = sheets.sheetIndex();
        window.built_book = book_id;
        window.built_range_len = @min(range.len, window.built_range.len);
        @memcpy(window.built_range[0..window.built_range_len], range[0..window.built_range_len]);

        window.groups[1].title = if (sheets.markedKind() == .thrust_polynomial) "Polinômio" else "Qual coluna é qual";
        var count: usize = 0;
        window.fields[count] = .{ .label = "bloco", .group = 0, .kind = .text, .help = "o canto de cima (B6: a linha 6 tem os títulos; o bloco desce enquanto houver números) ou o intervalo inteiro (B6:R40); Enter confirma" };
        window.fields[count].setText(range);
        count += 1;
        // as colunas: "—" e os títulos do bloco
        var headers_writer = std.Io.Writer.fixed(window.header_choices[0 .. window.header_choices.len - 1]);
        headers_writer.writeAll("—") catch {};
        const marked = sheets.markedBlock(memory);
        if (marked) |block| for (block.headers) |header| {
            headers_writer.writeByte(';') catch {};
            for (header) |char| headers_writer.writeByte(if (char == ';' or char == '\n' or char == '\r') ' ' else char) catch {};
        };
        window.header_choices[headers_writer.end] = 0;
        const header_choices = window.header_choices[0..headers_writer.end :0];
        for (sheets.markedKind().roles(), 0..) |role, r| {
            if (count >= window.fields.len - 3) break;
            const label = std.fmt.bufPrintZ(&window.labels[count], "{s}{s}", .{ role.label, if (role.required) "" else " (opcional)" }) catch "";
            const current: i32 = if (sheets.roleColumn(r)) |k| @intCast(k + 1) else 0;
            window.fields[count] = .{ .label = label, .group = 1, .kind = .choice, .choices = header_choices, .choice = current };
            count += 1;
        }
        if (sheets.markedKind() == .thrust_polynomial) {
            const cells = sheets.polynomialCells();
            const options = sheets.polynomialOptions();
            window.fields[count] = .{ .label = "tração estática T0 (célula)", .group = 1, .kind = .text, .help = "a célula com a tração estática corrigida (V = 0), que entra como termo constante; Enter confirma" };
            window.fields[count].setText(cells.static_thrust);
            window.fields[count + 1] = .{ .label = "rotação (célula)", .group = 1, .kind = .text, .help = "a célula com a rotação do motor (rpm) em que o polinômio é avaliado; Enter confirma" };
            window.fields[count + 1].setText(cells.rpm);
            window.fields[count + 2] = .{ .label = "unidade da tração", .group = 1, .kind = .choice, .choices = "kgf;N", .choice = if (options.kgf) 0 else 1 };
            window.fields[count + 3] = .{ .label = "x do ajuste", .group = 1, .kind = .choice, .choices = "rotação (y = V);velocidade (y = rotação)", .choice = if (options.x_is_rpm) 0 else 1, .help = "no MATLAB, p_ij multiplica x^i·y^j: na planilha de desempenho p01 multiplica V, então x é a rotação" };
            window.fields[count + 4] = .{ .label = "V máxima do gráfico", .unit = "m/s", .group = 1, .number = options.v_max, .minimum = 1, .maximum = 200 };
            count += 5;
        }
        if (sheets.markedKind() == .motors) {
            const defaults = sheets.motorDefaults();
            window.fields[count] = .{ .label = "corrente máx. sem coluna", .unit = "A", .group = 2, .number = defaults.imax, .minimum = 0.1, .maximum = 500 };
            window.fields[count + 1] = .{ .label = "massa sem coluna", .unit = "kg", .group = 2, .number = defaults.mass, .minimum = 0.001, .maximum = 20 };
            count += 2;
        } else {
            window.fields[count] = .{ .label = "nome", .group = 2, .kind = .text, .help = "o nome que você quiser: é assim que ela aparece nas análises" };
            window.fields[count].setText(sheets.comboName());
            count += 1;
        }
        window.form = .{ .groups = &window.groups, .fields = window.fields[0..count] };
    }

    /// passa o que mudou no formulário para a planilha aberta
    fn readForm(window: *SheetWindow) void {
        const fields = window.form.fields;
        const typed = std.mem.trim(u8, fields[0].textValue(), " ");
        if (!std.mem.eql(u8, typed, sheets.markedRange())) {
            sheets.setRange(typed);
            return;
        }
        var index: usize = 1;
        for (sheets.markedKind().roles(), 0..) |_, r| {
            if (index >= fields.len or fields[index].group != 1) break;
            const choice = fields[index].choice;
            sheets.setColumn(r, if (choice > 0) @as(usize, @intCast(choice - 1)) else null);
            index += 1;
        }
        if (sheets.markedKind() == .thrust_polynomial and index + 4 < fields.len) {
            sheets.setPolynomialCells(std.mem.trim(u8, fields[index].textValue(), " "), std.mem.trim(u8, fields[index + 1].textValue(), " "));
            sheets.setPolynomialOptions(.{ .kgf = fields[index + 2].choice == 0, .x_is_rpm = fields[index + 3].choice == 0, .v_max = fields[index + 4].number });
            index += 5;
        }
        if (sheets.markedKind() == .motors) {
            if (index + 1 < fields.len) sheets.setMotorDefaults(fields[index].number, fields[index + 1].number);
        } else if (index < fields.len) sheets.setName(fields[index].textValue());
    }

    fn drawSide(window: *SheetWindow, ui: *widgets.Ui, memory: std.mem.Allocator, side: rl.Rectangle) void {
        const buttons_height: f32 = 44;
        const message_height: f32 = 54;
        const has_book = sheets.workbook() != null;
        var top = side.y;
        // o tipo do bloco em abas: só os que a área usa
        const allowed = sheets.kindsFor(window.areaName());
        const tab_labels: [][:0]const u8 = memory.alloc([:0]const u8, allowed.len) catch &.{};
        var active: usize = 0;
        for (allowed, 0..) |kind, k| {
            if (k < tab_labels.len) tab_labels[k] = memory.dupeZ(u8, kind.short()) catch "";
            if (kind == sheets.markedKind()) active = k;
        }
        if (kindTabs(ui, side.x, top, side.width, tab_labels, &active)) |height| {
            top += height + 6;
        } else {
            window.readForm();
            sheets.setKind(allowed[active]);
            top += 40;
        }
        if (has_book) {
            window.rebuild(memory);
            const form_height = @min(window.form.contentHeight(), side.height * 0.5);
            if (window.form.draw(ui, .{ .x = side.x, .y = top, .width = side.width, .height = form_height })) window.readForm();
            top += form_height + 8;
            // o gráfico do bloco, com as colunas escolhidas
            const plot_height = side.y + side.height - buttons_height - message_height - top;
            if (plot_height > 120) {
                window.drawBlockPlot(ui, memory, .{ .x = side.x, .y = top, .width = side.width, .height = plot_height });
            }
        }
        const message = std.mem.sliceTo(&window.message, 0);
        _ = widgets.paragraph(ui.fonts.regular, message, side.x + 4, side.y + side.height - buttons_height - message_height + 4, side.width - 8, 13, theme.colors.label);
        const buttons_y = side.y + side.height - buttons_height + 8;
        if (ui_kit.dialogs.button(ui, .{ .x = side.x, .y = buttons_y, .width = 110, .height = 34 }, "Fechar")) window.open = false;
        const keep_label: [:0]const u8 = if (sheets.markedKind() == .motors) "Guardar os motores" else "Guardar a combinação";
        if (widgets.primaryButton(ui, .{ .x = side.x + 122, .y = buttons_y, .width = side.width - 122, .height = 34 }, keep_label, has_book)) {
            window.readForm();
            const said = sheets.keep(ui_kit.system.io(), memory) catch "não deu para guardar";
            window.say("{s}", .{said});
        }
    }

    fn drawBlockPlot(window: *SheetWindow, ui: *widgets.Ui, memory: std.mem.Allocator, rect: rl.Rectangle) void {
        _ = window;
        const kind = sheets.markedKind();
        if (kind == .thrust_polynomial) {
            var series: std.ArrayList(plot.Series) = .empty;
            if (sheets.markedPolynomial()) |polynomial| {
                if (sheets.polynomialCurve(memory, polynomial, sheets.polynomialOptions().v_max, 61)) |curve| {
                    const name = std.fmt.allocPrintSentinel(memory, "{d:.0} rpm", .{polynomial.rpm}, 0) catch "T(V)";
                    series.append(memory, .{ .name = name, .xs = curve.speeds, .ys = curve.thrusts }) catch {};
                } else |_| {}
            } else |_| {}
            plot.lines(ui, rect, .{ .title = "Polinômio de tração", .x_label = "V (m/s)", .y_label = "T (N)" }, series.items);
            return;
        }
        const roles = kind.roles();
        var series: std.ArrayList(plot.Series) = .empty;
        if (kind != .motors) if (sheets.markedBlock(memory)) |block| if (sheets.roleColumn(0)) |x_column| {
            for (roles[1..], 1..) |role, r| if (sheets.roleColumn(r)) |k| {
                // a potência tem outra unidade: o gráfico do envelope fica só com as trações
                if (std.mem.startsWith(u8, role.key, "P_")) continue;
                // a curva genérica leva o título da coluna da planilha; os outros tipos, o nome do papel
                const name = memory.dupeZ(u8, if (kind == .curve) block.headers[k] else role.label) catch continue;
                series.append(memory, .{ .name = name, .xs = block.numbers[x_column], .ys = block.numbers[k], .color_index = r - 1 }) catch {};
            };
        };
        const x_header: []const u8 = if (kind == .curve) (if (sheets.markedBlock(memory)) |block| (if (sheets.roleColumn(0)) |k| block.headers[k] else roles[0].label) else roles[0].label) else roles[0].label;
        const x_label = memory.dupeZ(u8, x_header) catch "";
        const title = memory.dupeZ(u8, kind.short()) catch "";
        const y_label: [:0]const u8 = switch (kind) {
            .envelope => "T (N)",
            .sizing => "T/W",
            else => "",
        };
        plot.lines(ui, rect, .{ .title = title, .x_label = x_label, .y_label = y_label }, series.items);
    }
};

/// as abas do tipo do bloco, quebrando em linhas quando não cabem numa só; devolve a altura usada, ou null se o
/// clique trocou a aba (`active` já é a nova)
fn kindTabs(ui: *widgets.Ui, left: f32, top: f32, width: f32, labels: []const [:0]const u8, active: *usize) ?f32 {
    const size: f32 = 13;
    const height: f32 = 28;
    var x = left;
    var y = top;
    var changed = false;
    for (labels, 0..) |caption, i| {
        const tab_width = theme.textWidth(ui.fonts.regular, caption, size) + 26;
        if (x + tab_width > left + width and x > left) {
            x = left;
            y += height + 4;
        }
        const tab: rl.Rectangle = .{ .x = x, .y = y, .width = tab_width, .height = height };
        const is_active = i == active.*;
        widgets.rounded(tab, 7, if (is_active) theme.colors.selected else if (ui.hovering(tab)) theme.colors.hover else theme.colors.panel);
        if (is_active) rl.drawRectangleRec(.{ .x = tab.x + 8, .y = tab.y + tab.height - 3, .width = tab.width - 16, .height = 3 }, theme.colors.accent);
        theme.text(ui.fonts.regular, caption, tab.x + 13, tab.y + (height - size) / 2, size, if (is_active) theme.colors.accent else theme.colors.ink);
        if (!is_active and ui.clickedIn(tab)) {
            active.* = i;
            changed = true;
        }
        x += tab_width + 4;
    }
    return if (changed) null else y + height - top;
}

/// a célula sob o mouse, pelas bordas das colunas e linhas à vista
fn placeAt(mouse: rl.Vector2, first_row: u32, first_column: u32, column_x: []const f32, row_y: []const f32) ?Place {
    var column: ?u32 = null;
    for (column_x[0 .. column_x.len - 1], 0..) |left, i| if (mouse.x >= left and mouse.x < column_x[i + 1]) {
        column = first_column + @as(u32, @intCast(i));
    };
    var row: ?u32 = null;
    for (row_y[0 .. row_y.len - 1], 0..) |top, j| if (mouse.y >= top and mouse.y < row_y[j + 1]) {
        row = first_row + @as(u32, @intCast(j));
    };
    return .{ .row = row orelse return null, .column = column orelse return null };
}

/// a primeira linha (ou coluna) depois de rolar `delta`, entre 1 e o fim da aba (com uma folga)
fn scrolled(first: u32, delta: f32, last: u32) u32 {
    const moved = @as(f32, @floatFromInt(first)) + @round(delta);
    return @intFromFloat(std.math.clamp(moved, 1, @as(f32, @floatFromInt(last + 5))));
}

/// 0xRRGGBB → cor do raylib
fn color(rgb: u32) rl.Color {
    return .{ .r = @intCast((rgb >> 16) & 0xFF), .g = @intCast((rgb >> 8) & 0xFF), .b = @intCast(rgb & 0xFF), .a = 255 };
}

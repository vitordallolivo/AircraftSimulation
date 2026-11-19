//! A tabela que se edita no lugar, como o `QTableWidget` da GUI em Python: uma linha por item, colunas de número,
//! texto, escolha, marcar, botão ou só leitura, e uma linha selecionada (o "+ partição" entra depois dela, o
//! "− restrição" tira ela). Serve às partições da asa, às restrições e às variáveis de projeto. Quem chama monta as
//! células a cada quadro com os valores de agora e recebe de volta o que se editou (`Edit`), que aplica ele mesmo.
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const numbers = @import("numbers.zig");

pub const Kind = enum { number, text, choice, check, button, label };

/// uma coluna: o título, o tipo das células, a largura (fração da tabela; 0 = divide o que sobra) e a dica. Nenhuma
/// coluna fica mais estreita que o título dela (ou que a maior opção, numa escolha): se não cabem todas, a tabela
/// fica mais larga que a caixa e rola para o lado
pub const Column = struct {
    title: [:0]const u8,
    kind: Kind,
    width: f32 = 0,
    help: [:0]const u8 = "",
};

/// uma célula, montada por quem chama a cada quadro
pub const Cell = struct {
    number: f64 = 0, // .number
    text: [:0]const u8 = "", // .text, .label e o rótulo de .button
    choices: [:0]const u8 = "", // .choice: opções separadas por ";"
    choice: i32 = 0,
    checked: bool = false, // .check
    enabled: bool = true,
    blank: bool = false, // .number sem valor nesta linha: a caixa fica vazia
    color: ?rl.Color = null, // a cor do texto (ex.: "✖ não cumpre" em vermelho)
    fill: ?rl.Color = null, // o fundo (o estado do diagnóstico)
};

/// o que mudou numa célula
pub const Edit = struct {
    row: usize,
    column: usize,
    value: union(enum) { number: f64, text: []const u8, choice: i32, check: bool, pressed },
};

pub const row_height: f32 = 28;
pub const header_height: f32 = 28;
/// a barra de rolar para o lado, embaixo da tabela, quando as colunas não cabem
pub const bar_height: f32 = 10;
const max_columns = 16;
/// a coluna de escolha não passa disso só por causa de uma opção comprida (a dica mostra o resto)
const choice_maximum: f32 = 170;
/// nem uma coluna de texto (o nome de uma entrada); o resto aparece na dica
const text_maximum: f32 = 280;

/// a altura da tabela com `rows` linhas, sem a barra de rolar
pub fn height(rows: usize) f32 {
    return header_height + row_height * @as(f32, @floatFromInt(rows)) + 2;
}

/// o estado da tabela entre quadros: a linha selecionada e a célula em edição
pub const EditTable = struct {
    selected: ?usize = null,
    editing: ?[2]usize = null, // número ou texto sendo digitado
    open_choice: ?[2]usize = null, // escolha com a lista aberta
    opening: bool = false, // a lista abriu neste quadro (o raygui veria o mesmo clique e fecharia)
    edit_text: [64:0]u8 = [_:0]u8{0} ** 64,
    edit_fresh: bool = false, // o valor antigo está todo marcado: digitar troca ele inteiro
    edit_start: usize = 0,
    // onde a tabela foi desenhada (para a lista aberta, desenhada por cima depois)
    origin: rl.Vector2 = .{ .x = 0, .y = 0 },
    table_width: f32 = 0,
    open_cell: Cell = .{},
    // as colunas como foram desenhadas neste quadro (já com a rolagem), para a lista aberta
    lefts: [max_columns]f32 = undefined,
    widths: [max_columns]f32 = undefined,
    // rolagem para o lado: quanto as colunas passam da caixa e onde se está
    overflow: f32 = 0,
    scroll: f32 = 0,
    dragging_bar: bool = false,

    /// a altura da tabela com `rows` linhas, com a barra de rolar se as colunas não couberam no último quadro
    pub fn fullHeight(table: *const EditTable, rows: usize) f32 {
        return height(rows) + if (table.overflow > 0) bar_height + 2 else 0;
    }

    /// desenha a tabela a partir de (x, y) na largura `width`; devolve a edição feita neste quadro, se houver.
    /// Depois de fechar os recortes, chamar `drawOpen` (a lista aberta de uma escolha fica por cima)
    pub fn draw(table: *EditTable, ui: *widgets.Ui, x: f32, y: f32, width: f32, columns: []const Column, cells: []const []const Cell) ?Edit {
        table.origin = .{ .x = x, .y = y };
        table.table_width = width;
        if (table.selected) |row| {
            if (row >= cells.len) table.selected = if (cells.len > 0) cells.len - 1 else null;
        }
        const natural = layout(ui, columns, cells, width, &table.widths);
        table.overflow = @max(0, natural - width);
        table.scrollSideways(ui, x, y, width, cells.len);
        var left = x - table.scroll;
        for (columns, 0..) |_, c| {
            table.lefts[c] = left;
            left += table.widths[c];
        }
        const lefts = table.lefts;
        const widths = table.widths;
        // a lista aberta pega o clique antes das células de baixo
        if (table.open_choice) |place| {
            if (place[0] < cells.len) {
                const options = std.mem.count(u8, cells[place[0]][place[1]].choices, ";") + 1;
                const list = table.cellRect(columns, place[0], place[1]);
                const whole: rl.Rectangle = .{ .x = list.x, .y = list.y, .width = list.width, .height = list.height * @as(f32, @floatFromInt(options + 1)) };
                if (ui.clicked and rl.checkCollisionPointRec(ui.mouse, whole)) ui.click_taken = true;
            } else table.open_choice = null;
        }
        const frame: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = height(cells.len) };
        widgets.rounded(frame, 5, theme.colors.field);
        rl.drawRectangleRec(.{ .x = x, .y = y, .width = width, .height = header_height }, theme.colors.panel);
        ui.pushClip(frame);
        for (columns, 0..) |column, c| {
            ui.pushClip(.{ .x = lefts[c], .y = y, .width = widths[c] - 2, .height = header_height });
            theme.text(ui.fonts.regular, column.title, lefts[c] + 6, y + 6, 13, theme.colors.label);
            ui.popClip();
            ui.tooltip(.{ .x = lefts[c], .y = y, .width = widths[c], .height = header_height }, column.help);
        }
        var edit: ?Edit = null;
        for (cells, 0..) |row, r| {
            const top = y + header_height + row_height * @as(f32, @floatFromInt(r));
            const line: rl.Rectangle = .{ .x = x, .y = top, .width = width, .height = row_height };
            // um clique em qualquer lugar da linha a seleciona (antes das células, que pegam o clique)
            if (ui.clicked and !ui.click_taken and ui.hovering(line)) table.selected = r;
            if (table.selected == r) rl.drawRectangleRec(line, theme.colors.selected);
            rl.drawRectangleRec(.{ .x = x, .y = top, .width = width, .height = 1 }, theme.colors.grid);
            for (columns, row, 0..) |column, cell, c| {
                const box: rl.Rectangle = .{ .x = lefts[c] + 2, .y = top + 2, .width = widths[c] - 4, .height = row_height - 4 };
                if (table.drawCell(ui, column.kind, cell, box, r, c)) |value| edit = .{ .row = r, .column = c, .value = value };
            }
        }
        ui.popClip();
        widgets.roundedLines(frame, 5, theme.colors.line);
        if (table.overflow > 0) table.drawBar(x, y + height(cells.len) + 2, width);
        return edit;
    }

    /// a roda do mouse com Shift (ou a roda de lado) e o arrasto da barra rolam as colunas
    fn scrollSideways(table: *EditTable, ui: *widgets.Ui, x: f32, y: f32, width: f32, rows: usize) void {
        if (table.overflow <= 0) {
            table.scroll = 0;
            return;
        }
        const whole: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = height(rows) + bar_height + 2 };
        if (ui.hovering(whole)) {
            const sideways = rl.getMouseWheelMoveV().x;
            const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
            if (sideways != 0) table.scroll -= sideways * 40;
            if (shift and ui.wheel != 0) {
                table.scroll -= ui.wheel * 40;
                ui.wheel = 0; // não rola a barra lateral junto
            }
        }
        const bar: rl.Rectangle = .{ .x = x, .y = y + height(rows) + 2, .width = width, .height = bar_height };
        if (ui.clickedIn(bar)) table.dragging_bar = true;
        if (!rl.isMouseButtonDown(.left)) table.dragging_bar = false;
        if (table.dragging_bar) {
            const knob = width * width / (width + table.overflow);
            table.scroll = (ui.mouse.x - x - knob / 2) / (width - knob) * table.overflow;
        }
        table.scroll = std.math.clamp(table.scroll, 0, table.overflow);
    }

    fn drawBar(table: *const EditTable, x: f32, y: f32, width: f32) void {
        const knob = width * width / (width + table.overflow);
        const start = x + (width - knob) * table.scroll / table.overflow;
        widgets.rounded(.{ .x = x, .y = y, .width = width, .height = bar_height }, 4, theme.colors.panel);
        widgets.rounded(.{ .x = start, .y = y + 1, .width = knob, .height = bar_height - 2 }, 4, if (table.dragging_bar) theme.colors.accent else theme.colors.line);
    }

    /// a lista aberta de uma escolha, por cima de tudo; devolve a escolha feita
    pub fn drawOpen(table: *EditTable, ui: *widgets.Ui, columns: []const Column) ?Edit {
        _ = ui;
        const place = table.open_choice orelse return null;
        const control = table.cellRect(columns, place[0], place[1]);
        if (table.opening) { // no quadro em que abriu, o clique é o de abrir
            table.opening = false;
            return null;
        }
        var active: i32 = table.open_cell.choice;
        if (rg.dropdownBox(control, table.open_cell.choices, &active, true) != 0) {
            table.open_choice = null;
            if (active != table.open_cell.choice) return .{ .row = place[0], .column = place[1], .value = .{ .choice = active } };
        }
        return null;
    }

    fn cellRect(table: *const EditTable, columns: []const Column, row: usize, column: usize) rl.Rectangle {
        _ = columns;
        const top = table.origin.y + header_height + row_height * @as(f32, @floatFromInt(row));
        return .{ .x = table.lefts[column] + 2, .y = top + 2, .width = table.widths[column] - 4, .height = row_height - 4 };
    }

    fn drawCell(table: *EditTable, ui: *widgets.Ui, kind: Kind, cell: Cell, box: rl.Rectangle, row: usize, column: usize) ?@FieldType(Edit, "value") {
        var buffer: [64]u8 = undefined;
        const ink = cell.color orelse (if (cell.enabled) theme.colors.ink else theme.colors.muted);
        if (cell.fill) |fill| widgets.rounded(box, 4, fill);
        const here = [2]usize{ row, column };
        const editing = if (table.editing) |place| place[0] == row and place[1] == column else false;
        switch (kind) {
            .label => {
                ui.pushClip(box);
                theme.text(ui.fonts.regular, cell.text, box.x + 4, box.y + 4, 13, ink);
                ui.popClip();
                ui.tooltip(box, if (theme.textWidth(ui.fonts.regular, cell.text, 13) > box.width - 8) cell.text else "");
            },
            .check => {
                const square: rl.Rectangle = .{ .x = box.x + 4, .y = box.y + (box.height - 16) / 2, .width = 16, .height = 16 };
                widgets.checkBox(square, cell.checked);
                if (cell.enabled and ui.clickedIn(box)) return .{ .check = !cell.checked };
            },
            .button => {
                if (!cell.enabled and cell.text.len == 0) return null; // sem botão nesta linha
                const hover = cell.enabled and ui.hovering(box);
                widgets.rounded(box, 4, if (hover) theme.colors.hover else if (cell.enabled) theme.colors.field else theme.colors.panel);
                widgets.roundedLines(box, 4, theme.colors.line);
                ui.pushClip(box);
                theme.text(ui.fonts.regular, cell.text, box.x + 6, box.y + 4, 13, if (cell.enabled) theme.colors.accent else theme.colors.muted);
                ui.popClip();
                if (cell.enabled and ui.clickedIn(box)) return .pressed;
            },
            .choice => {
                widgets.rounded(box, 4, if (cell.enabled) theme.colors.field else theme.colors.panel);
                widgets.roundedLines(box, 4, theme.colors.line);
                var options = std.mem.splitScalar(u8, cell.choices, ';');
                var k: i32 = 0;
                var current: []const u8 = "";
                while (options.next()) |option| : (k += 1) {
                    if (k == cell.choice) current = option;
                }
                ui.pushClip(.{ .x = box.x, .y = box.y, .width = box.width - 16, .height = box.height });
                theme.text(ui.fonts.regular, widgets.format(&buffer, "{s}", .{current}), box.x + 5, box.y + 4, 13, ink);
                ui.popClip();
                widgets.disclosure(box.x + box.width - 9, box.y + box.height / 2, 7, true, theme.colors.muted);
                if (table.open_choice) |place| {
                    if (place[0] == row and place[1] == column) table.open_cell = cell;
                }
                if (cell.enabled and ui.clickedIn(box)) {
                    table.open_choice = here;
                    table.open_cell = cell;
                    table.opening = true;
                }
            },
            .number, .text => {
                if (editing) {
                    const done = rg.textBox(box, &table.edit_text, true);
                    widgets.replaceOnType(ui, box, &table.edit_text, &table.edit_fresh, table.edit_start);
                    if (done) {
                        table.editing = null;
                        const typed = std.mem.trim(u8, std.mem.sliceTo(&table.edit_text, 0), " ");
                        if (kind == .text) return .{ .text = typed };
                        // aceita vírgula decimal, como a tabela do Python
                        var copy: [64]u8 = undefined;
                        @memcpy(copy[0..typed.len], typed);
                        for (copy[0..typed.len]) |*ch| if (ch.* == ',') {
                            ch.* = '.';
                        };
                        const value = std.fmt.parseFloat(f64, copy[0..typed.len]) catch return null;
                        return .{ .number = value };
                    }
                    return null;
                }
                widgets.rounded(box, 4, if (cell.enabled) theme.colors.field else theme.colors.panel);
                const shown = if (cell.blank) "" else if (kind == .number) numbers.numberText(&buffer, cell.number) else cell.text;
                ui.pushClip(box);
                theme.text(ui.fonts.mono, shown, box.x + 5, box.y + 4, 13, ink);
                ui.popClip();
                if (cell.enabled and ui.clickedIn(box)) {
                    table.editing = here;
                    table.selected = row;
                    table.edit_text = [_:0]u8{0} ** 64;
                    const length = @min(shown.len, 63);
                    @memcpy(table.edit_text[0..length], shown[0..length]);
                    widgets.caretToEnd(ui, &table.edit_text);
                    table.edit_fresh = true;
                    table.edit_start = length;
                }
            },
        }
        return null;
    }
};

/// as larguras das colunas: cada uma tem o mínimo que mostra o título inteiro (ou a opção escolhida, numa escolha),
/// e o que sobra da caixa se divide pelas frações (as de largura dada, e as outras em partes iguais do resto);
/// devolve a largura somada, que passa de `width` quando nem os mínimos cabem
fn layout(ui: *const widgets.Ui, columns: []const Column, cells: []const []const Cell, width: f32, widths: *[max_columns]f32) f32 {
    var fixed: f32 = 0;
    var free: f32 = 0;
    for (columns) |column| {
        if (column.width > 0) fixed += column.width else free += 1;
    }
    const rest = @max(0, 1 - fixed);
    var shares: f32 = 0;
    var minimums: f32 = 0;
    for (columns, 0..) |column, c| {
        widths[c] = minimum(ui, column, c, cells);
        minimums += widths[c];
        shares += if (column.width > 0) column.width else rest / @max(free, 1);
    }
    const spare = @max(0, width - minimums);
    for (columns, 0..) |column, c| {
        const share = if (column.width > 0) column.width else rest / @max(free, 1);
        widths[c] += spare * share / @max(shares, 1e-6);
    }
    return minimums + spare;
}

/// o mais estreito que a coluna pode ficar: o título inteiro, o maior número da coluna e, numa escolha, a opção
/// escolhida mais comprida
fn minimum(ui: *const widgets.Ui, column: Column, c: usize, cells: []const []const Cell) f32 {
    var narrowest = theme.textWidth(ui.fonts.regular, column.title, 13) + 14;
    if (column.kind == .number) {
        var buffer: [64]u8 = undefined;
        for (cells) |row| {
            if (c >= row.len) continue;
            if (!row[c].blank) narrowest = @max(narrowest, theme.textWidth(ui.fonts.mono, numbers.numberText(&buffer, row[c].number), 13) + 14);
        }
    }
    if (column.kind == .label or column.kind == .text) {
        for (cells) |row| {
            if (c < row.len) narrowest = @max(narrowest, @min(text_maximum, theme.textWidth(ui.fonts.regular, row[c].text, 13) + 16));
        }
    }
    if (column.kind != .choice) return narrowest;
    for (cells) |row| {
        if (c >= row.len) continue;
        var options = std.mem.splitScalar(u8, row[c].choices, ';');
        var k: i32 = 0;
        while (options.next()) |option| : (k += 1) {
            if (k != row[c].choice) continue;
            var buffer: [128]u8 = undefined;
            const shown = widgets.format(&buffer, "{s}", .{option});
            narrowest = @max(narrowest, @min(choice_maximum, theme.textWidth(ui.fonts.regular, shown, 13) + 30));
        }
    }
    return narrowest;
}

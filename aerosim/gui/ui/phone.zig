//! O jeito celular das telas: quando a janela é estreita (um celular em pé), a tela troca as abas de cima pela
//! barra de baixo com as áreas (as que não cabem ficam no "Mais"), as subabas viram fichas que rolam de lado e as
//! entradas sobem numa folha por cima do resultado, em três alturas (recolhida, meia e cheia). Aqui ficam só as
//! peças; quem decide o que vai em cada uma é a tela (`aerosim/gui/screen.zig`) e a página (`page.zig`).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

/// abaixo desta largura a tela usa o jeito celular
pub const narrow_width: f32 = 720;
/// a altura do cabeçalho curto
pub const header_height: f32 = 48;
/// a altura da faixa das fichas (subabas)
pub const chips_height: f32 = 42;
/// a altura da barra de baixo
pub const bar_height: f32 = 56;
/// quantas áreas a barra mostra antes do "Mais"
const bar_slots = 4;
/// a faixa de cima da folha que se pega para puxar
pub const handle_height: f32 = 18;

/// verdadeiro quando a janela de `width` pede o jeito celular
pub fn isPhone(width: f32) bool {
    return width < narrow_width;
}

/// o cabeçalho curto: a logo, o nome e os botões encostados à direita; devolve o índice do botão tocado
pub fn header(ui: *widgets.Ui, width: f32, program_name: [:0]const u8, buttons: []const [:0]const u8) ?usize {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = width, .height = header_height }, theme.colors.panel);
    const logo_width = ui.logo.draw(8, 8, header_height - 16);
    theme.text(ui.fonts.regular, program_name, 16 + logo_width, 12, 21, theme.colors.accent);
    var pressed: ?usize = null;
    var x = width - 6;
    var k = buttons.len;
    while (k > 0) {
        k -= 1;
        const caption = buttons[k];
        const button_width = theme.textWidth(ui.fonts.regular, caption, 15) + 20;
        x -= button_width;
        const rect: rl.Rectangle = .{ .x = x, .y = 8, .width = button_width, .height = header_height - 16 };
        widgets.rounded(rect, 7, if (ui.hovering(rect)) theme.colors.hover else theme.colors.background);
        theme.text(ui.fonts.regular, caption, rect.x + 10, rect.y + 8, 15, theme.colors.accent);
        if (ui.clickedIn(rect)) pressed = k;
        x -= 6;
    }
    rl.drawRectangleRec(.{ .x = 0, .y = header_height - 1, .width = width, .height = 1 }, theme.colors.line);
    return pressed;
}

/// `label` encurtado para caber em `room` pixels: a primeira palavra e, se ainda não couber, cortada com "."
pub fn shortLabel(font: rl.Font, label: []const u8, size: f32, room: f32, buffer: *[64:0]u8) [:0]const u8 {
    const whole = widgets.format(buffer, "{s}", .{label});
    if (theme.textWidth(font, whole, size) <= room) return whole;
    const word = std.mem.sliceTo(label, ' ');
    var length = @min(word.len, buffer.len - 2);
    while (length > 1) {
        // não corta no meio de uma letra acentuada (bytes de continuação do UTF-8)
        if (length < word.len and (word[length] & 0xC0) == 0x80) {
            length -= 1;
            continue;
        }
        const cut = word.len > length;
        @memcpy(buffer[0..length], word[0..length]);
        if (cut) buffer[length] = '.';
        const end = length + @intFromBool(cut);
        buffer[end] = 0;
        if (theme.textWidth(font, buffer[0..end :0], size) <= room) return buffer[0..end :0];
        length -= 1;
    }
    return widgets.format(buffer, "{s}", .{word[0..@min(word.len, 1)]});
}

/// a barra de baixo: as primeiras áreas e, se sobrar alguma, o "Mais" (abre a lista das outras em `more_open`);
/// devolve verdadeiro se trocou de área
pub fn bottomBar(ui: *widgets.Ui, rect: rl.Rectangle, labels: []const [:0]const u8, active: *usize, more_open: *bool) bool {
    rl.drawRectangleRec(rect, theme.colors.panel);
    rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1 }, theme.colors.line);
    const has_more = labels.len > bar_slots + 1;
    const shown = if (has_more) bar_slots else labels.len;
    const slots = shown + @intFromBool(has_more);
    if (slots == 0) return false;
    const slot_width = rect.width / @as(f32, @floatFromInt(slots));
    var changed = false;
    for (0..slots) |k| {
        const is_more = has_more and k == shown;
        const slot: rl.Rectangle = .{ .x = rect.x + @as(f32, @floatFromInt(k)) * slot_width, .y = rect.y + 1, .width = slot_width, .height = rect.height - 1 };
        const is_active = if (is_more) (active.* >= shown or more_open.*) else (active.* == k and !more_open.*);
        if (is_active) {
            widgets.rounded(.{ .x = slot.x + 6, .y = slot.y + 6, .width = slot.width - 12, .height = slot.height - 12 }, 10, theme.colors.selected);
            rl.drawRectangleRec(.{ .x = slot.x + slot.width / 2 - 14, .y = slot.y + slot.height - 5, .width = 28, .height = 3 }, theme.colors.accent);
        }
        var buffer: [64:0]u8 = undefined;
        const caption = if (is_more) "Mais" else shortLabel(ui.fonts.regular, labels[k], 13, slot_width - 8, &buffer);
        const caption_width = theme.textWidth(if (is_active) ui.fonts.bold else ui.fonts.regular, caption, 13);
        theme.text(if (is_active) ui.fonts.bold else ui.fonts.regular, caption, slot.x + (slot.width - caption_width) / 2, slot.y + (slot.height - 13) / 2 - 1, 13, if (is_active) theme.colors.accent else theme.colors.ink);
        if (ui.clickedIn(slot)) {
            if (is_more) more_open.* = !more_open.* else {
                more_open.* = false;
                if (active.* != k) {
                    active.* = k;
                    changed = true;
                }
            }
        }
    }
    return changed;
}

/// a lista do "Mais", por cima do resultado e encostada na barra: as áreas que não couberam; tocar fora fecha.
/// Chamada com o clique ainda livre (antes da página); devolve verdadeiro se trocou de área
pub fn moreMenu(ui: *widgets.Ui, area: rl.Rectangle, labels: []const [:0]const u8, active: *usize, open: *bool) bool {
    if (labels.len <= bar_slots + 1) {
        open.* = false;
        return false;
    }
    rl.drawRectangleRec(area, .{ .r = 20, .g = 30, .b = 50, .a = 70 });
    const row_height: f32 = 52;
    const rest = labels[bar_slots..];
    const height = @as(f32, @floatFromInt(rest.len)) * row_height + 12;
    const box: rl.Rectangle = .{ .x = area.x + 8, .y = area.y + area.height - height - 8, .width = area.width - 16, .height = height };
    widgets.rounded(box, 12, theme.colors.background);
    widgets.roundedLines(box, 12, theme.colors.line);
    var changed = false;
    for (rest, 0..) |label, k| {
        const index = bar_slots + k;
        const row: rl.Rectangle = .{ .x = box.x + 6, .y = box.y + 6 + @as(f32, @floatFromInt(k)) * row_height, .width = box.width - 12, .height = row_height };
        if (index == active.*) {
            widgets.rounded(row, 8, theme.colors.selected);
            rl.drawRectangleRec(.{ .x = row.x, .y = row.y + 8, .width = 4, .height = row.height - 16 }, theme.colors.accent);
        }
        theme.text(ui.fonts.regular, label, row.x + 16, row.y + (row_height - 17) / 2, 17, if (index == active.*) theme.colors.accent else theme.colors.ink);
        theme.text(ui.fonts.regular, ">", row.x + row.width - 22, row.y + (row_height - 17) / 2, 17, theme.colors.muted);
        if (k + 1 < rest.len) rl.drawRectangleRec(.{ .x = row.x + 12, .y = row.y + row_height - 1, .width = row.width - 24, .height = 1 }, theme.colors.grid);
        if (ui.clickedIn(row)) {
            open.* = false;
            if (active.* != index) {
                active.* = index;
                changed = true;
            }
        }
    }
    // o toque fora da lista fecha (a barra de baixo fica fora de `area` e trata o próprio toque)
    if (ui.clickedIn(area)) open.* = false;
    ui.click_taken = true;
    ui.wheel = 0;
    ui.drag_used = true;
    return changed;
}

/// as fichas das subabas: uma linha que rola de lado (o dedo ou a roda) quando não cabe
pub const Chips = struct {
    offset: f32 = 0,
    content_width: f32 = 0,
    shown_active: ?usize = null, // a ficha ativa do quadro anterior: trocada de fora, a linha rola até ela

    /// desenha as fichas de `labels` em `rect`; devolve verdadeiro se trocou a ativa
    pub fn draw(chips: *Chips, ui: *widgets.Ui, rect: rl.Rectangle, labels: []const [:0]const u8, active: *usize) bool {
        rl.drawRectangleRec(rect, theme.colors.background);
        rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 }, theme.colors.grid);
        const size: f32 = 14;
        const limit = @max(0, chips.content_width - rect.width);
        if (ui.hovering(rect) and ui.wheel != 0) {
            chips.offset -= ui.wheel * 48;
            ui.wheel = 0;
        }
        if (ui.dragIn(rect)) {
            chips.offset -= ui.drag_delta.x;
            ui.drag_used = true;
        }
        // a ativa trocada de fora (outra área, a linha de comando): a linha leva ela para dentro da faixa
        var follow = chips.shown_active != active.*;
        chips.shown_active = active.*;
        var changed = false;
        ui.pushClip(rect);
        defer ui.popClip();
        for (0..2) |pass| {
            chips.offset = std.math.clamp(chips.offset, 0, limit);
            var x = rect.x + 10 - chips.offset;
            for (labels, 0..) |caption, k| {
                const chip_width = theme.textWidth(ui.fonts.regular, caption, size) + 26;
                const chip: rl.Rectangle = .{ .x = x, .y = rect.y + 7, .width = chip_width, .height = rect.height - 14 };
                if (pass == 0) {
                    if (follow and k == active.*) {
                        if (chip.x < rect.x + 10) chips.offset -= rect.x + 10 - chip.x;
                        if (chip.x + chip.width > rect.x + rect.width - 10) chips.offset += chip.x + chip.width - (rect.x + rect.width - 10);
                    }
                } else {
                    const is_active = k == active.*;
                    widgets.rounded(chip, chip.height / 2, if (is_active) theme.colors.selected else theme.colors.panel);
                    theme.text(if (is_active) ui.fonts.bold else ui.fonts.regular, caption, chip.x + 13, chip.y + (chip.height - size) / 2, size, if (is_active) theme.colors.accent else theme.colors.ink);
                    if (ui.clickedIn(chip) and !is_active) {
                        active.* = k;
                        chips.shown_active = k;
                        changed = true;
                    }
                }
                x += chip_width + 6;
            }
            chips.content_width = x + chips.offset - rect.x + 4;
            follow = false;
        }
        return changed;
    }
};

/// a altura da folha
pub const Level = enum {
    collapsed,
    half,
    full,

    /// a próxima ao tocar na alça: recolhida → meia → cheia → recolhida
    fn next(level: Level) Level {
        return switch (level) {
            .collapsed => .half,
            .half => .full,
            .full => .collapsed,
        };
    }
};

/// a folha das entradas: sobe de baixo por cima do resultado; a alça (a faixa de cima) puxa ou, tocada, troca a altura
pub const Sheet = struct {
    level: Level = .half,
    drag_height: ?f32 = null, // puxando: a altura da folha na mão
    grab_height: f32 = 0, // a altura quando o dedo desceu na alça
    grab_y: f32 = 0, // onde o dedo desceu na alça
    last_y: f32 = 0, // onde o dedo estava no último quadro segurando (ao soltar, o mouse pode já estar longe)

    /// a altura de cada nível em `area` (a folha recolhida mostra só a alça e a linha `head`)
    fn height(level: Level, area: rl.Rectangle, head: f32) f32 {
        const collapsed = handle_height + head;
        return switch (level) {
            .collapsed => collapsed,
            .half => @max(collapsed, area.height * 0.5),
            .full => @max(collapsed, area.height - 64),
        };
    }

    /// trata a alça e devolve o retângulo da folha em `area` (antes de desenhar o que fica por baixo)
    pub fn place(sheet: *Sheet, ui: *widgets.Ui, area: rl.Rectangle, head: f32) rl.Rectangle {
        var shown = height(sheet.level, area, head);
        if (sheet.drag_height) |dragged| shown = dragged;
        const grip: rl.Rectangle = .{ .x = area.x, .y = area.y + area.height - shown, .width = area.width, .height = handle_height };
        if (ui.pressed and !ui.click_taken and ui.hovering(grip)) {
            sheet.grab_height = shown;
            sheet.grab_y = ui.mouse.y;
            sheet.drag_height = shown;
        }
        if (sheet.drag_height != null) {
            if (ui.held) {
                sheet.last_y = ui.mouse.y;
                const moved = ui.mouse.y - sheet.grab_y;
                sheet.drag_height = std.math.clamp(sheet.grab_height - moved, height(.collapsed, area, head), height(.full, area, head));
                shown = sheet.drag_height.?;
                ui.drag_used = true;
            } else {
                // soltou: parada é toque (a próxima altura); andando, a altura mais perto
                const moved = @abs(sheet.last_y - sheet.grab_y);
                if (moved < 10) sheet.level = sheet.level.next() else {
                    var best: Level = .collapsed;
                    for (std.enums.values(Level)) |level| {
                        if (@abs(height(level, area, head) - shown) < @abs(height(best, area, head) - shown)) best = level;
                    }
                    sheet.level = best;
                }
                sheet.drag_height = null;
                shown = height(sheet.level, area, head);
                ui.click_taken = true;
            }
        }
        if (ui.clicked and ui.hovering(grip)) ui.click_taken = true;
        return .{ .x = area.x, .y = area.y + area.height - shown, .width = area.width, .height = shown };
    }

    /// o fundo da folha (cantos de cima redondos, uma sombra leve) e a alça; devolve a área de dentro, abaixo da alça
    pub fn drawBack(rect: rl.Rectangle) rl.Rectangle {
        rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y - 3, .width = rect.width, .height = 3 }, .{ .r = 20, .g = 30, .b = 50, .a = 25 });
        widgets.rounded(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = @min(rect.height, 40) }, 14, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y + 20, .width = rect.width, .height = rect.height - 20 }, theme.colors.panel);
        widgets.rounded(.{ .x = rect.x + rect.width / 2 - 22, .y = rect.y + 7, .width = 44, .height = 5 }, 3, theme.colors.line);
        return .{ .x = rect.x, .y = rect.y + handle_height, .width = rect.width, .height = rect.height - handle_height };
    }
};

test "rótulo curto cabe e não corta letra acentuada" {
    // sem a janela não há fonte: só a regra do corte de UTF-8
    const word = "Aerodinâmica";
    var length: usize = 8; // cairia no meio do "â"
    while (length > 0 and (word[length] & 0xC0) == 0x80) length -= 1;
    try std.testing.expect(std.unicode.utf8ValidateSlice(word[0..length]));
}

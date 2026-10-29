//! As peças de escolha que as abas repetem: a lista de itens com um selecionado (a lista de candidatos de Perfis,
//! de asas guardadas, de motores...), a grade de botões de ação embaixo dela ("+ NACA", "Remover"...) e o menu de
//! marcar, um botão que abre caixas de marcar para escolher um ou mais itens (os métodos de polar, os métodos de
//! carga...). Cada uma guarda só o estado da tela (rolagem, aberto); os itens e o que está marcado são de quem chama.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const dialogs = @import("dialogs.zig");

/// uma lista de itens, um deles selecionado, com rolagem pela roda
pub const ItemList = struct {
    scroll: f32 = 0,
    pub const line_height: f32 = 24;

    /// desenha os `labels` em `rect`; devolve o índice clicado, se for outro que não o `selected`
    pub fn draw(list: *ItemList, ui: *widgets.Ui, rect: rl.Rectangle, labels: []const [:0]const u8, selected: usize) ?usize {
        widgets.rounded(rect, 6, theme.colors.field);
        widgets.roundedLines(rect, 6, theme.colors.line);
        const total = @as(f32, @floatFromInt(labels.len)) * line_height;
        if (ui.hovering(rect)) list.scroll = std.math.clamp(list.scroll - ui.wheel * line_height, 0, @max(0, total - rect.height + 4));
        var picked: ?usize = null;
        rl.beginScissorMode(@intFromFloat(rect.x + 1), @intFromFloat(rect.y + 1), @intFromFloat(rect.width - 2), @intFromFloat(rect.height - 2));
        defer rl.endScissorMode();
        for (labels, 0..) |label, k| {
            const row: rl.Rectangle = .{ .x = rect.x + 3, .y = rect.y + 2 + line_height * @as(f32, @floatFromInt(k)) - list.scroll, .width = rect.width - 6, .height = line_height };
            if (k == selected) widgets.rounded(row, 4, theme.colors.selected) else if (ui.hovering(row) and ui.hovering(rect)) widgets.rounded(row, 4, theme.colors.hover);
            theme.text(ui.fonts.regular, label, row.x + 6, row.y + 4, 14, theme.colors.ink);
            if (ui.hovering(rect) and ui.clickedIn(row) and k != selected) picked = k;
        }
        return picked;
    }
};

/// botões de ação em grade (`columns` por linha); devolve o índice do apertado e a altura usada em `height`
pub fn buttonGrid(ui: *widgets.Ui, x: f32, y: f32, width: f32, captions: []const [:0]const u8, columns: usize, height: *f32) ?usize {
    const gap: f32 = 8;
    const button_width = (width - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    var pressed: ?usize = null;
    for (captions, 0..) |caption, k| {
        const column: f32 = @floatFromInt(k % columns);
        const row: f32 = @floatFromInt(k / columns);
        if (dialogs.button(ui, .{ .x = x + column * (button_width + gap), .y = y + 36 * row, .width = button_width, .height = 30 }, caption)) pressed = k;
    }
    const rows = (captions.len + columns - 1) / columns;
    height.* = 36 * @as(f32, @floatFromInt(rows));
    return pressed;
}

/// um item do menu de marcar
pub const CheckItem = struct {
    label: [:0]const u8,
    checked: bool,
    enabled: bool = true,
};

/// o botão que abre um menu de caixas de marcar. Em dois tempos, porque o menu aberto cobre o que está embaixo:
/// `update` antes dos widgets de baixo (fica com o clique e diz qual item trocou) e `draw` depois deles
pub const CheckMenu = struct {
    open: bool = false,
    const row_height: f32 = 30;

    fn popup(toggle: rl.Rectangle, count: usize) rl.Rectangle {
        return .{ .x = toggle.x, .y = toggle.y + toggle.height + 2, .width = toggle.width, .height = 8 + row_height * @as(f32, @floatFromInt(count)) };
    }

    /// trata o clique: no botão abre e fecha, num item devolve o índice dele, fora fecha
    pub fn update(menu: *CheckMenu, ui: *widgets.Ui, toggle: rl.Rectangle, count: usize) ?usize {
        if (!ui.clicked or ui.click_taken) return null;
        if (ui.hovering(toggle)) {
            menu.open = !menu.open;
            ui.click_taken = true;
            return null;
        }
        if (!menu.open) return null;
        const area = popup(toggle, count);
        if (!ui.hovering(area)) {
            menu.open = false;
            return null;
        }
        ui.click_taken = true;
        const row: usize = @intFromFloat(@max(0, (ui.mouse.y - area.y - 4) / row_height));
        return if (row < count) row else null;
    }

    /// desenha o botão com `caption` e, aberto, as caixas dos `items` (um item desligado aparece apagado)
    pub fn draw(menu: *const CheckMenu, ui: *widgets.Ui, toggle: rl.Rectangle, caption: []const u8, items: []const CheckItem) void {
        widgets.rounded(toggle, 6, if (ui.hovering(toggle)) theme.colors.hover else theme.colors.field);
        widgets.roundedLines(toggle, 6, theme.colors.line);
        var text: [96:0]u8 = undefined;
        const shown = widgets.format(&text, "{s}  ▼", .{caption});
        const width = theme.textWidth(ui.fonts.regular, shown, 14);
        theme.text(ui.fonts.regular, shown, toggle.x + (toggle.width - width) / 2, toggle.y + (toggle.height - 15) / 2, 14, theme.colors.accent);
        if (!menu.open) return;
        const area = popup(toggle, items.len);
        widgets.rounded(area, 6, theme.colors.field);
        widgets.roundedLines(area, 6, theme.colors.line);
        for (items, 0..) |item, k| {
            const row: rl.Rectangle = .{ .x = area.x + 4, .y = area.y + 4 + row_height * @as(f32, @floatFromInt(k)), .width = area.width - 8, .height = row_height };
            if (ui.hovering(row) and item.enabled) widgets.rounded(row, 4, theme.colors.hover);
            const box: rl.Rectangle = .{ .x = row.x + 6, .y = row.y + 7, .width = 16, .height = 16 };
            widgets.rounded(box, 4, if (item.checked) theme.colors.accent else theme.colors.field);
            if (!item.checked) widgets.roundedLines(box, 4, theme.colors.line);
            if (item.checked) theme.text(ui.fonts.regular, "✓", box.x + 2, box.y - 1, 15, theme.colors.on_accent);
            theme.text(ui.fonts.regular, item.label, row.x + 30, row.y + 7, 13, if (item.enabled) theme.colors.ink else theme.colors.muted);
        }
    }
};

/// o texto curto do que está marcado ("modelo, arquivo"), com os nomes `names`
pub fn checkedText(buffer: []u8, names: []const []const u8, checked: []const bool) [:0]const u8 {
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    var first = true;
    for (names, checked) |name, on| {
        if (!on) continue;
        writer.print("{s}{s}", .{ if (first) "" else ", ", name }) catch {};
        first = false;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

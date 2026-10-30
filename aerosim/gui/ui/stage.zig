//! As peças que toda etapa do dimensionamento repete, como o `StagePage` da GUI em Python: a barra de requisitos
//! (sempre à vista, com o botão "Condições e restrições…"), o título da etapa com o "?" de ajuda, a caixa
//! "Guardados" (a lista do que se guardou, "Carregar no rascunho" e "Apagar"), a janela com abas por cima da tela e
//! o seletor de itens de uma lista (com busca, marcar e desmarcar todos). A etapa Asa usa todas; Perfis, Empenagem e
//! Motores usam as mesmas.
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const dialogs = @import("dialogs.zig");
const menus = @import("menus.zig");

const requirements_caption = "Condições e restrições…";
const requirements_help = "condições (massa de partida, velocidade, AD, pista), restrições ligáveis (≤, ≥, =), variáveis de projeto (fixo, variável, calculado) e regras (massas, fuselagem, trem)";

/// a altura da barra de requisitos com o texto `summary` na largura `width`
pub fn reqBarHeight(ui: *widgets.Ui, summary: []const u8, width: f32) f32 {
    const button_width = theme.textWidth(ui.fonts.regular, requirements_caption, 14) + 24;
    return @max(30, widgets.paragraphHeight(ui.fonts.regular, summary, width - button_width - 22, 12) + 8);
}

/// a barra de requisitos: o resumo das condições e das restrições ativas e o botão que abre a janela de editar;
/// devolve verdadeiro no clique do botão
pub fn reqBar(ui: *widgets.Ui, x: f32, y: f32, width: f32, summary: []const u8) bool {
    const button_width = theme.textWidth(ui.fonts.regular, requirements_caption, 14) + 24;
    const bar_height = reqBarHeight(ui, summary, width);
    const box: rl.Rectangle = .{ .x = x, .y = y, .width = width - button_width - 8, .height = bar_height };
    widgets.rounded(box, 3, theme.hex(0xeef3fa));
    _ = widgets.paragraph(ui.fonts.regular, summary, box.x + 4, box.y + 4, box.width - 8, 12, theme.hex(0x333344));
    const button: rl.Rectangle = .{ .x = x + width - button_width, .y = y + (bar_height - 28) / 2, .width = button_width, .height = 28 };
    ui.tooltip(button, requirements_help);
    return dialogs.button(ui, button, requirements_caption);
}

/// o título da etapa em negrito azul, com o "?" de ajuda; devolve a altura usada
pub fn title(ui: *widgets.Ui, x: f32, y: f32, text: [:0]const u8, help: [:0]const u8) f32 {
    theme.text(ui.fonts.regular, text, x, y, 18, theme.colors.accent);
    if (help.len > 0) widgets.helpMark(ui, x + theme.textWidth(ui.fonts.regular, text, 18) + 8, y + 2, help);
    return 28;
}

/// o que se pediu na caixa "Guardados"
pub const KeptAction = enum { load, remove };

/// a caixa "Guardados (n)": a lista do que a etapa guardou e os botões "Carregar no rascunho" e "Apagar"
pub const KeptBox = struct {
    list: menus.ItemList = .{},
    selected: usize = 0,

    /// a altura da caixa
    pub const height: f32 = 30 + 110 + 8 + 36 + 6;

    /// desenha a caixa em (x, y) na largura `width`; devolve o botão apertado (com a linha em `selected`)
    pub fn draw(box: *KeptBox, ui: *widgets.Ui, x: f32, y: f32, width: f32, labels: []const [:0]const u8) ?KeptAction {
        var caption: [48]u8 = undefined;
        const frame: rl.Rectangle = .{ .x = x, .y = y + 8, .width = width, .height = height - 8 };
        widgets.roundedLines(frame, 5, theme.colors.line);
        const text = widgets.format(&caption, "Guardados ({d})", .{labels.len});
        const text_width = theme.textWidth(ui.fonts.regular, text, 14);
        rl.drawRectangleRec(.{ .x = x + 8, .y = y, .width = text_width + 8, .height = 16 }, theme.colors.panel);
        theme.text(ui.fonts.regular, text, x + 12, y, 14, theme.colors.ink);
        box.selected = @min(box.selected, labels.len -| 1);
        if (box.list.draw(ui, .{ .x = x + 8, .y = y + 24, .width = width - 16, .height = 110 }, labels, box.selected)) |picked| box.selected = picked;
        var pressed: f32 = 0;
        const actions = [_][:0]const u8{ "Carregar no rascunho", "Apagar" };
        const button = menus.buttonGrid(ui, x + 8, y + 24 + 110 + 8, width - 16, &actions, 2, &pressed) orelse return null;
        if (labels.len == 0) return null;
        return if (button == 0) .load else .remove;
    }
};

/// uma janela com abas por cima da tela (a de baixo não recebe o clique enquanto ela está aberta); fecha no botão
/// "Fechar" ou no Esc
pub const TabbedDialog = struct {
    open: bool = false,
    tab: usize = 0,

    /// desenha a moldura, o título e as abas; devolve a área do conteúdo da aba aberta (null se fechada)
    pub fn begin(dialog: *TabbedDialog, ui: *widgets.Ui, screen: rl.Rectangle, caption: [:0]const u8, tabs: []const [:0]const u8) ?rl.Rectangle {
        if (!dialog.open) return null;
        if (rl.isKeyPressed(.escape)) {
            dialog.open = false;
            return null;
        }
        rl.drawRectangleRec(screen, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const box = dialog.frame(screen);
        const inner = widgets.card(ui, box, caption);
        _ = widgets.tabBar(ui, .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = 34 }, tabs, &dialog.tab, 14);
        return .{ .x = inner.x, .y = inner.y + 42, .width = inner.width, .height = inner.height - 42 - 44 };
    }

    /// o botão "Fechar" e o fim da janela (o clique e a roda não passam para a tela de baixo)
    pub fn end(dialog: *TabbedDialog, ui: *widgets.Ui, screen: rl.Rectangle) void {
        const box = dialog.frame(screen);
        if (widgets.primaryButton(ui, .{ .x = box.x + box.width - 130, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "Fechar", true)) dialog.open = false;
        ui.click_taken = true;
        ui.wheel = 0;
    }

    fn frame(dialog: *const TabbedDialog, screen: rl.Rectangle) rl.Rectangle {
        _ = dialog;
        const width = @min(screen.width - 40, 960);
        const height = @min(screen.height - 40, 660);
        return .{ .x = screen.x + (screen.width - width) / 2, .y = screen.y + (screen.height - height) / 2, .width = width, .height = height };
    }
};

pub const max_picks = 64;

/// escolher itens de uma lista, como o `ListPicker` da GUI: busca pelo nome, marcar ou desmarcar todos os que a
/// busca mostra, a contagem e OK/Cancelar
pub const ListPicker = struct {
    open: bool = false,
    caption: [96:0]u8 = [_:0]u8{0} ** 96,
    search: [64:0]u8 = [_:0]u8{0} ** 64,
    editing_search: bool = false,
    names: [max_picks][]const u8 = undefined,
    checked: [max_picks]bool = undefined,
    count: usize = 0,
    list: menus.ItemList = .{},
    owner: usize = 0, // quem abriu (a variável), para quem chama saber a quem vai a resposta

    /// abre com os itens `names`, marcados os de `chosen` (nada escolhido = todos)
    pub fn show(picker: *ListPicker, caption: []const u8, names: []const []const u8, chosen: []const []const u8, owner: usize) void {
        _ = widgets.format(&picker.caption, "Escolher: {s}", .{caption});
        picker.search = [_:0]u8{0} ** 64;
        picker.count = @min(names.len, max_picks);
        for (names[0..picker.count], 0..) |name, k| {
            picker.names[k] = name;
            picker.checked[k] = chosen.len == 0;
            for (chosen) |pick| {
                if (std.mem.eql(u8, pick, name)) picker.checked[k] = true;
            }
        }
        picker.owner = owner;
        picker.open = true;
    }

    fn visible(picker: *const ListPicker, k: usize) bool {
        const typed = std.mem.trim(u8, std.mem.sliceTo(&picker.search, 0), " ");
        return typed.len == 0 or std.ascii.indexOfIgnoreCase(picker.names[k], typed) != null;
    }

    /// desenha por cima de `screen`; devolve verdadeiro no OK (os marcados ficam em `checked`)
    pub fn draw(picker: *ListPicker, ui: *widgets.Ui, screen: rl.Rectangle) bool {
        if (!picker.open) return false;
        if (rl.isKeyPressed(.escape)) {
            picker.open = false;
            return false;
        }
        rl.drawRectangleRec(screen, .{ .r = 20, .g = 30, .b = 50, .a = 60 });
        const box: rl.Rectangle = .{ .x = screen.x + (screen.width - 440) / 2, .y = screen.y + @max(20, (screen.height - 540) / 2), .width = 440, .height = 540 };
        const inner = widgets.card(ui, box, std.mem.sliceTo(&picker.caption, 0));
        const field: rl.Rectangle = .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = 30 };
        if (ui.clickedIn(field)) picker.editing_search = true;
        _ = rg.textBox(field, &picker.search, picker.editing_search);
        if (std.mem.sliceTo(&picker.search, 0).len == 0) theme.text(ui.fonts.regular, "pesquisar…", field.x + 8, field.y + 7, 14, theme.colors.muted);
        // a lista com as caixas de marcar
        const area: rl.Rectangle = .{ .x = inner.x, .y = inner.y + 38, .width = inner.width, .height = inner.height - 38 - 118 };
        widgets.rounded(area, 6, theme.colors.field);
        widgets.roundedLines(area, 6, theme.colors.line);
        var shown: usize = 0;
        for (0..picker.count) |k| shown += @intFromBool(picker.visible(k));
        const line_height = menus.ItemList.line_height;
        const limit = @max(0, @as(f32, @floatFromInt(shown)) * line_height - area.height + 4);
        if (ui.hovering(area) and ui.wheel != 0) picker.list.scroll -= ui.wheel * line_height;
        picker.list.scroll = std.math.clamp(picker.list.scroll, 0, limit);
        ui.pushClip(area);
        var row_index: f32 = 0;
        for (0..picker.count) |k| {
            if (!picker.visible(k)) continue;
            const row: rl.Rectangle = .{ .x = area.x + 4, .y = area.y + 2 + row_index * line_height - picker.list.scroll, .width = area.width - 8, .height = line_height };
            row_index += 1;
            if (ui.hovering(row)) widgets.rounded(row, 4, theme.colors.hover);
            widgets.checkBox(.{ .x = row.x + 4, .y = row.y + 4, .width = 16, .height = 16 }, picker.checked[k]);
            var label: [96]u8 = undefined;
            theme.text(ui.fonts.regular, widgets.format(&label, "{s}", .{picker.names[k]}), row.x + 28, row.y + 4, 14, theme.colors.ink);
            if (ui.clickedIn(row)) picker.checked[k] = !picker.checked[k];
        }
        ui.popClip();
        var y = area.y + area.height + 8;
        var pressed: f32 = 0;
        const actions = [_][:0]const u8{ "Marcar todos", "Desmarcar todos" };
        if (menus.buttonGrid(ui, inner.x, y, inner.width, &actions, 2, &pressed)) |button| {
            for (0..picker.count) |k| {
                if (picker.visible(k)) picker.checked[k] = button == 0;
            }
        }
        y += pressed + 2;
        var marked: usize = 0;
        for (picker.checked[0..picker.count]) |on| marked += @intFromBool(on);
        var count_text: [96]u8 = undefined;
        const summary = if (shown < picker.count) widgets.format(&count_text, "{d} de {d} marcados · {d} na busca", .{ marked, picker.count, shown }) else widgets.format(&count_text, "{d} de {d} marcados", .{ marked, picker.count });
        theme.text(ui.fonts.regular, summary, inner.x, y, 14, theme.colors.label);
        var accepted = false;
        if (dialogs.button(ui, .{ .x = box.x + box.width - 250, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "Cancelar")) picker.open = false;
        if (widgets.primaryButton(ui, .{ .x = box.x + box.width - 130, .y = box.y + box.height - 46, .width = 110, .height = 32 }, "OK", true)) {
            picker.open = false;
            accepted = true;
        }
        ui.click_taken = true;
        ui.wheel = 0;
        return accepted;
    }

    /// os nomes marcados (em `out`); todos marcados = nenhum ("todos", inclusive os que entrarem depois)
    pub fn selected(picker: *const ListPicker, out: [][]const u8) [][]const u8 {
        var count: usize = 0;
        for (0..picker.count) |k| {
            if (picker.checked[k] and count < out.len) {
                out[count] = picker.names[k];
                count += 1;
            }
        }
        return out[0..count];
    }
};

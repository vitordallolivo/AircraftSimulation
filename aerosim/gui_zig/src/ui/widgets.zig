//! Os pedaços comuns das telas: o contexto de desenho (fontes, logo, mouse), o cabeçalho com a logo, a barra de
//! abas, o botão inclinado e o cartão. Tudo é desenhado a cada quadro (modo imediato, como o raygui).
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");
const shapes = @import("shapes.zig");

/// o que todo widget precisa: fontes, logo e o estado do mouse neste quadro
pub const Ui = struct {
    fonts: theme.Fonts,
    logo: theme.Logo,
    mouse: rl.Vector2 = .{ .x = 0, .y = 0 },
    clicked: bool = false,
    wheel: f32 = 0,
    // um clique já usado por um widget de cima (ex.: a lista aberta de uma escolha) não vale para os de baixo
    click_taken: bool = false,

    /// abre fontes e logo e ajusta o estilo do raygui às cores do tema; precisa da janela aberta
    pub fn init() !Ui {
        const ui: Ui = .{ .fonts = theme.Fonts.load(), .logo = try theme.Logo.load() };
        styleRaygui(ui.fonts.mono);
        return ui;
    }

    /// libera fontes e logo
    pub fn deinit(ui: *Ui) void {
        ui.logo.deinit();
        ui.fonts.deinit();
    }

    /// lê o mouse no começo do quadro
    pub fn beginFrame(ui: *Ui) void {
        ui.mouse = rl.getMousePosition();
        ui.clicked = rl.isMouseButtonPressed(.left);
        ui.wheel = rl.getMouseWheelMove();
        ui.click_taken = false;
    }

    /// verdadeiro se o mouse está em `rect`
    pub fn hovering(ui: *const Ui, rect: rl.Rectangle) bool {
        return rl.checkCollisionPointRec(ui.mouse, rect);
    }

    /// verdadeiro se houve clique em `rect` neste quadro (e ninguém usou o clique antes)
    pub fn clickedIn(ui: *Ui, rect: rl.Rectangle) bool {
        if (!ui.clicked or ui.click_taken or !ui.hovering(rect)) return false;
        ui.click_taken = true;
        return true;
    }
};

/// cor do raygui no formato dele (0xRRGGBBAA)
fn rgba(color: rl.Color) i32 {
    const value: u32 = (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
    return @bitCast(value);
}

/// o raygui (caixas de texto, listas, marcadores) no visual do tema
fn styleRaygui(font: rl.Font) void {
    rg.setFont(font);
    rg.setStyle(.default, .text_size, 15);
    rg.setStyle(.default, .text_spacing, 1);
    rg.setStyle(.default, .background_color, rgba(theme.colors.field));
    rg.setStyle(.default, .line_color, rgba(theme.colors.line));
    rg.setStyle(.default, .border_width, 1);
    rg.setStyle(.default, .border_color_normal, rgba(theme.colors.line));
    rg.setStyle(.default, .base_color_normal, rgba(theme.colors.field));
    rg.setStyle(.default, .text_color_normal, rgba(theme.colors.ink));
    rg.setStyle(.default, .border_color_focused, rgba(theme.colors.accent));
    rg.setStyle(.default, .base_color_focused, rgba(theme.colors.panel));
    rg.setStyle(.default, .text_color_focused, rgba(theme.colors.ink));
    rg.setStyle(.default, .border_color_pressed, rgba(theme.colors.accent));
    rg.setStyle(.default, .base_color_pressed, rgba(theme.colors.accent));
    rg.setStyle(.default, .text_color_pressed, rgba(theme.colors.on_accent));
    rg.setStyle(.default, .text_padding, 6);
}

pub const header_height: f32 = 46;

/// cabeçalho: bloco escuro com a logo azul e o nome do programa, o corte no destaque, os botões, o nome do avião
/// e, à direita, a troca de modo de cor;
/// devolve o índice do botão clicado
pub fn header(ui: *Ui, width: f32, program_name: [:0]const u8, buttons: []const [:0]const u8, subtitle: [:0]const u8) ?usize {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = width, .height = header_height }, theme.colors.panel);
    const block: f32 = 176;
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = block, .height = header_height }, theme.colors.strip);
    shapes.slanted(.{ .x = block - 6, .y = 0, .width = 14, .height = header_height }, 8, theme.colors.accent);
    ui.logo.draw(12, 8, 26, theme.colors.logo);
    theme.text(ui.fonts.bold, program_name, 80, 14, 17, theme.colors.strip_text);
    var x: f32 = block + 22;
    var pressed: ?usize = null;
    for (buttons, 0..) |caption, i| {
        const w = theme.textWidth(ui.fonts.regular, caption, 15) + 26;
        const rect: rl.Rectangle = .{ .x = x, .y = 8, .width = w, .height = header_height - 16 };
        rl.drawRectangleRec(rect, if (ui.hovering(rect)) theme.colors.panel else theme.colors.field);
        rl.drawRectangleLinesEx(rect, 1, theme.colors.line);
        theme.text(ui.fonts.regular, caption, rect.x + 13, rect.y + 7, 15, theme.colors.ink);
        if (ui.clickedIn(rect)) pressed = i;
        x += w + 8;
    }
    theme.text(ui.fonts.regular, subtitle, x + 14, 15, 15, theme.colors.muted);
    // à direita, a troca entre o modo claro e o escuro
    const mode_caption: [:0]const u8 = if (theme.mode == .claro) "Modo escuro" else "Modo claro";
    const mode_width = theme.textWidth(ui.fonts.regular, mode_caption, 15) + 26;
    const mode_rect: rl.Rectangle = .{ .x = width - mode_width - 14, .y = 8, .width = mode_width, .height = header_height - 16 };
    rl.drawRectangleRec(mode_rect, if (ui.hovering(mode_rect)) theme.colors.panel else theme.colors.field);
    rl.drawRectangleLinesEx(mode_rect, 1, theme.colors.line);
    theme.text(ui.fonts.regular, mode_caption, mode_rect.x + 13, mode_rect.y + 7, 15, theme.colors.ink);
    if (ui.clickedIn(mode_rect)) {
        theme.use(if (theme.mode == .claro) .escuro else .claro);
        styleRaygui(ui.fonts.mono);
    }
    rl.drawRectangleRec(.{ .x = 0, .y = header_height - 3, .width = width, .height = 3 }, theme.colors.accent);
    return pressed;
}

/// barra de abas em caixa alta: a ativa vira um paralelogramo laranja; devolve verdadeiro se mudou
pub fn tabBar(ui: *Ui, rect: rl.Rectangle, labels: []const [:0]const u8, active: *usize, background: rl.Color, size: f32) bool {
    rl.drawRectangleRec(rect, background);
    var x = rect.x + 14;
    var changed = false;
    for (labels, 0..) |caption, i| {
        const w = theme.textWidth(ui.fonts.bold, caption, size) + 34;
        const tab: rl.Rectangle = .{ .x = x, .y = rect.y + 4, .width = w, .height = rect.height - 4 };
        const is_active = i == active.*;
        if (is_active) shapes.slanted(tab, 10, theme.colors.accent);
        const color = if (is_active) theme.colors.on_accent else if (theme.isDark(background)) (if (ui.hovering(tab)) theme.hex(0xffffff) else theme.colors.strip_label) else if (ui.hovering(tab)) theme.colors.ink else theme.colors.label;
        theme.text(ui.fonts.bold, caption, tab.x + 17, tab.y + (tab.height - size) / 2, size, color);
        if (ui.clickedIn(tab) and !is_active) {
            active.* = i;
            changed = true;
        }
        x += w + 4;
    }
    rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y + rect.height - 3, .width = rect.width, .height = 3 }, theme.colors.accent);
    return changed;
}

/// botão principal (laranja, inclinado, texto preto em caixa alta); devolve verdadeiro no clique
pub fn primaryButton(ui: *Ui, rect: rl.Rectangle, caption: [:0]const u8, enabled: bool) bool {
    const hover = enabled and ui.hovering(rect);
    const color = if (!enabled) theme.colors.line else if (hover) theme.colors.accent_hover else theme.colors.accent;
    shapes.slanted(rect, 12, color);
    const size: f32 = 16;
    const w = theme.textWidth(ui.fonts.bold, caption, size);
    theme.text(ui.fonts.bold, caption, rect.x + (rect.width - w) / 2, rect.y + (rect.height - size) / 2, size, theme.colors.on_accent);
    return enabled and ui.clickedIn(rect);
}

/// cartão: fundo de cantos cortados com a borda de cima laranja e o título; devolve a área de dentro
pub fn card(ui: *Ui, rect: rl.Rectangle, title: [:0]const u8) rl.Rectangle {
    shapes.cutCorners(rect, 18, theme.colors.panel);
    shapes.cutCornersTopEdge(rect, 18, 3, theme.colors.accent);
    const size: f32 = 15;
    const w = theme.textWidth(ui.fonts.regular, title, size);
    theme.text(ui.fonts.regular, title, rect.x + (rect.width - w) / 2, rect.y + 12, size, theme.colors.ink);
    return .{ .x = rect.x + 10, .y = rect.y + 34, .width = rect.width - 20, .height = rect.height - 44 };
}

/// cartão com o título numa etiqueta laranja à esquerda (tabelas: diagnóstico, resumo)
pub fn labeledCard(ui: *Ui, rect: rl.Rectangle, title: [:0]const u8) rl.Rectangle {
    shapes.cutCorners(rect, 18, theme.colors.panel);
    shapes.cutCornersTopEdge(rect, 18, 3, theme.colors.accent);
    const size: f32 = 13;
    const w = theme.textWidth(ui.fonts.bold, title, size) + 20;
    rl.drawRectangleRec(.{ .x = rect.x + 10, .y = rect.y + 12, .width = w, .height = 22 }, theme.colors.accent);
    theme.text(ui.fonts.bold, title, rect.x + 20, rect.y + 16, size, theme.colors.on_accent);
    return .{ .x = rect.x + 10, .y = rect.y + 42, .width = rect.width - 20, .height = rect.height - 52 };
}

/// a cor de um estado do diagnóstico
pub fn statusColor(status: Status) rl.Color {
    return switch (status) {
        .ok => theme.colors.ok,
        .atencao => theme.colors.warning,
        .falha => theme.colors.failure,
        .info => theme.colors.muted,
    };
}

/// os estados de um item do diagnóstico (os mesmos do aerosim em Python)
pub const Status = enum { ok, atencao, falha, info };

/// uma linha de tabela: colunas em x fixos, texto cortado na largura da coluna
pub fn tableRow(ui: *Ui, y: f32, columns: []const f32, cells: []const [:0]const u8, colors: []const rl.Color, size: f32) void {
    for (cells, 0..) |cell, i| {
        theme.text(ui.fonts.regular, cell, columns[i], y, size, colors[@min(i, colors.len - 1)]);
    }
}

/// texto formatado num buffer (para números nas telas)
pub fn format(buffer: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintZ(buffer, fmt, args) catch "…";
}

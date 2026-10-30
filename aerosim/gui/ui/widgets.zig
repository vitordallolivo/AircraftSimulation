//! Os pedaços comuns das telas, no desenho do AeroDrive: o contexto de desenho (fontes, logo, mouse), o cabeçalho
//! com a logo, a barra de abas, o botão, o cartão e a barra de progresso. Tudo é desenhado a cada quadro (modo
//! imediato, como o raygui).
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");

/// o que todo widget precisa: fontes, logo e o estado do mouse neste quadro
pub const Ui = struct {
    fonts: theme.Fonts,
    logo: theme.Logo,
    mouse: rl.Vector2 = .{ .x = 0, .y = 0 },
    clicked: bool = false,
    right_clicked: bool = false, // o botão direito (o menu dos gráficos)
    wheel: f32 = 0,
    // um clique já usado por um widget de cima (ex.: a lista aberta de uma escolha) não vale para os de baixo
    click_taken: bool = false,
    // os recortes abertos (uma área rolável dentro de outra): só o que está dentro do último se desenha e recebe
    // o mouse, então um campo que rolou para fora da barra lateral não pega o clique das abas
    clips: [8]rl.Rectangle = undefined,
    clip_count: usize = 0,
    // desenhando numa imagem (exportar um gráfico): o recorte da tela vira o da imagem, (p - origem) · escala
    clip_origin: rl.Vector2 = .{ .x = 0, .y = 0 },
    clip_scale: f32 = 1,

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
        ui.right_clicked = rl.isMouseButtonPressed(.right);
        ui.wheel = rl.getMouseWheelMove();
        ui.click_taken = false;
    }

    /// verdadeiro se o mouse está em `rect` (e dentro do recorte aberto)
    pub fn hovering(ui: *const Ui, rect: rl.Rectangle) bool {
        if (ui.clip_count > 0 and !rl.checkCollisionPointRec(ui.mouse, ui.clips[ui.clip_count - 1])) return false;
        return rl.checkCollisionPointRec(ui.mouse, rect);
    }

    /// abre um recorte: daqui até `popClip` só se desenha dentro de `rect` (e do recorte de fora, se houver)
    pub fn pushClip(ui: *Ui, rect: rl.Rectangle) void {
        const inside = if (ui.clip_count > 0) intersection(ui.clips[ui.clip_count - 1], rect) else rect;
        if (ui.clip_count < ui.clips.len) {
            ui.clips[ui.clip_count] = inside;
            ui.clip_count += 1;
        }
        ui.scissor(inside);
    }

    /// fecha o último recorte e volta ao de fora
    pub fn popClip(ui: *Ui) void {
        if (ui.clip_count == 0) return;
        ui.clip_count -= 1;
        if (ui.clip_count > 0) ui.scissor(ui.clips[ui.clip_count - 1]) else rl.endScissorMode();
    }

    /// guarda os recortes abertos e desliga o recorte (antes de desenhar numa textura); devolve quantos eram
    pub fn suspendClips(ui: *Ui) usize {
        const count = ui.clip_count;
        ui.clip_count = 0;
        rl.endScissorMode();
        return count;
    }

    /// volta aos recortes guardados por `suspendClips`
    pub fn resumeClips(ui: *Ui, count: usize) void {
        ui.clip_count = count;
        if (count > 0) ui.scissor(ui.clips[count - 1]);
    }

    fn scissor(ui: *const Ui, rect: rl.Rectangle) void {
        const scale = ui.clip_scale;
        const x = (rect.x - ui.clip_origin.x) * scale;
        const y = (rect.y - ui.clip_origin.y) * scale;
        rl.beginScissorMode(@intFromFloat(@floor(x)), @intFromFloat(@floor(y)), @intFromFloat(@ceil(rect.width * scale)), @intFromFloat(@ceil(rect.height * scale)));
    }

    /// verdadeiro se houve clique em `rect` neste quadro (e ninguém usou o clique antes)
    pub fn clickedIn(ui: *Ui, rect: rl.Rectangle) bool {
        if (!ui.clicked or ui.click_taken or !ui.hovering(rect)) return false;
        ui.click_taken = true;
        return true;
    }
};

fn intersection(a: rl.Rectangle, b: rl.Rectangle) rl.Rectangle {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    return .{ .x = left, .y = top, .width = @max(0, right - left), .height = @max(0, bottom - top) };
}

/// a caixa de marcar: azul com o visto desenhado (duas linhas, sem depender de a fonte ter o "✓") ou branca
pub fn checkBox(box: rl.Rectangle, checked: bool) void {
    rounded(box, 4, if (checked) theme.colors.accent else theme.colors.field);
    if (!checked) {
        roundedLines(box, 4, theme.colors.line);
        return;
    }
    const left: rl.Vector2 = .{ .x = box.x + box.width * 0.22, .y = box.y + box.height * 0.52 };
    const bottom: rl.Vector2 = .{ .x = box.x + box.width * 0.42, .y = box.y + box.height * 0.72 };
    const right: rl.Vector2 = .{ .x = box.x + box.width * 0.78, .y = box.y + box.height * 0.30 };
    rl.drawLineEx(left, bottom, 2.2, theme.colors.on_accent);
    rl.drawLineEx(bottom, right, 2.2, theme.colors.on_accent);
    rl.drawCircleV(bottom, 1.1, theme.colors.on_accent);
}

/// o triângulo de abrir e fechar: para baixo (aberto) ou para a direita (fechado), centrado em (x, y)
pub fn disclosure(x: f32, y: f32, size: f32, open: bool, color: rl.Color) void {
    const half = size / 2;
    if (open) {
        rl.drawTriangle(.{ .x = x - half, .y = y - half * 0.6 }, .{ .x = x, .y = y + half * 0.6 }, .{ .x = x + half, .y = y - half * 0.6 }, color);
    } else {
        rl.drawTriangle(.{ .x = x - half * 0.6, .y = y - half }, .{ .x = x - half * 0.6, .y = y + half }, .{ .x = x + half * 0.6, .y = y }, color);
    }
}

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
    rg.setStyle(.default, .base_color_focused, rgba(theme.colors.hover));
    rg.setStyle(.default, .text_color_focused, rgba(theme.colors.ink));
    rg.setStyle(.default, .border_color_pressed, rgba(theme.colors.accent));
    rg.setStyle(.default, .base_color_pressed, rgba(theme.colors.accent));
    rg.setStyle(.default, .text_color_pressed, rgba(theme.colors.on_accent));
    rg.setStyle(.default, .background_color, rgba(theme.colors.field));
    rg.setStyle(.default, .text_padding, 6);
}

pub const header_height: f32 = 52;

/// raio dos cantos (fração do lado menor, como o `drawRectangleRounded` pede) para um canto de `radius` pixels
fn roundness(rect: rl.Rectangle, radius: f32) f32 {
    return std.math.clamp(2 * radius / @max(@min(rect.width, rect.height), 1), 0, 1);
}

/// retângulo de cantos arredondados
pub fn rounded(rect: rl.Rectangle, radius: f32, color: rl.Color) void {
    rl.drawRectangleRounded(rect, roundness(rect, radius), 6, color);
}

/// contorno de cantos arredondados
pub fn roundedLines(rect: rl.Rectangle, radius: f32, color: rl.Color) void {
    rl.drawRectangleRoundedLinesEx(rect, roundness(rect, radius), 6, 1, color);
}

/// cabeçalho: a logo, o nome do programa em azul, os botões e o nome do avião; devolve o índice do botão clicado
pub fn header(ui: *Ui, width: f32, program_name: [:0]const u8, buttons: []const [:0]const u8, subtitle: [:0]const u8) ?usize {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = width, .height = header_height }, theme.colors.panel);
    const logo_width = ui.logo.draw(14, 8, header_height - 16);
    theme.text(ui.fonts.regular, program_name, 24 + logo_width, 13, 24, theme.colors.accent);
    var x: f32 = 24 + logo_width + theme.textWidth(ui.fonts.regular, program_name, 24) + 28;
    var pressed: ?usize = null;
    for (buttons, 0..) |caption, i| {
        const w = theme.textWidth(ui.fonts.regular, caption, 15) + 28;
        const rect: rl.Rectangle = .{ .x = x, .y = 10, .width = w, .height = header_height - 20 };
        if (ui.hovering(rect)) rounded(rect, 7, theme.colors.hover);
        theme.text(ui.fonts.regular, caption, rect.x + 14, rect.y + 8, 15, theme.colors.ink);
        if (ui.clickedIn(rect)) pressed = i;
        x += w + 6;
    }
    theme.text(ui.fonts.regular, subtitle, x + 16, 18, 14, theme.colors.muted);
    rl.drawRectangleRec(.{ .x = 0, .y = header_height - 1, .width = width, .height = 1 }, theme.colors.line);
    return pressed;
}

/// barra de abas: a ativa fica no fundo azul claro, com o texto e um traço embaixo em azul; devolve verdadeiro se
/// mudou
pub fn tabBar(ui: *Ui, rect: rl.Rectangle, labels: []const [:0]const u8, active: *usize, size: f32) bool {
    rl.drawRectangleRec(rect, theme.colors.panel);
    var x = rect.x + 12;
    var changed = false;
    for (labels, 0..) |caption, i| {
        const w = theme.textWidth(ui.fonts.regular, caption, size) + 32;
        const tab: rl.Rectangle = .{ .x = x, .y = rect.y + 4, .width = w, .height = rect.height - 8 };
        const is_active = i == active.*;
        if (is_active) {
            rounded(tab, 7, theme.colors.selected);
            rl.drawRectangleRec(.{ .x = tab.x + 10, .y = tab.y + tab.height - 3, .width = tab.width - 20, .height = 3 }, theme.colors.accent);
        } else if (ui.hovering(tab)) rounded(tab, 7, theme.colors.hover);
        theme.text(ui.fonts.regular, caption, tab.x + 16, tab.y + (tab.height - size) / 2, size, if (is_active) theme.colors.accent else theme.colors.ink);
        if (ui.clickedIn(tab) and !is_active) {
            active.* = i;
            changed = true;
        }
        x += w + 4;
    }
    rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 }, theme.colors.line);
    return changed;
}

/// botão principal (azul, texto branco); devolve verdadeiro no clique
pub fn primaryButton(ui: *Ui, rect: rl.Rectangle, caption: [:0]const u8, enabled: bool) bool {
    const hover = enabled and ui.hovering(rect);
    rounded(rect, 8, if (!enabled) theme.colors.line else if (hover) theme.colors.accent_hover else theme.colors.accent);
    const size: f32 = 17;
    const w = theme.textWidth(ui.fonts.regular, caption, size);
    theme.text(ui.fonts.regular, caption, rect.x + (rect.width - w) / 2, rect.y + (rect.height - size) / 2, size, theme.colors.on_accent);
    return enabled and ui.clickedIn(rect);
}

/// barra de progresso (a fração `fill` de 0 a 1 em azul)
pub fn progressBar(rect: rl.Rectangle, fill: f32) void {
    rounded(rect, rect.height / 2, theme.colors.line);
    const width = rect.width * std.math.clamp(fill, 0, 1);
    if (width > 0) rounded(.{ .x = rect.x, .y = rect.y, .width = width, .height = rect.height }, rect.height / 2, theme.colors.accent);
}

/// cartão: fundo branco de cantos arredondados, borda fina e o título em azul; devolve a área de dentro
pub fn card(ui: *Ui, rect: rl.Rectangle, title: [:0]const u8) rl.Rectangle {
    rounded(rect, 10, theme.colors.field);
    roundedLines(rect, 10, theme.colors.line);
    theme.text(ui.fonts.regular, title, rect.x + 16, rect.y + 11, 16, theme.colors.accent);
    return .{ .x = rect.x + 10, .y = rect.y + 34, .width = rect.width - 20, .height = rect.height - 44 };
}

/// cartão de tabela (diagnóstico, resumo): o mesmo cartão, com mais espaço abaixo do título
pub fn labeledCard(ui: *Ui, rect: rl.Rectangle, title: [:0]const u8) rl.Rectangle {
    const inner = card(ui, rect, title);
    return .{ .x = inner.x + 6, .y = inner.y + 8, .width = inner.width - 12, .height = inner.height - 8 };
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

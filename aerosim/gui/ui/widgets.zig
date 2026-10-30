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
    // a dica do que está sob o mouse (o `setToolTip` do Qt): marcada durante o quadro, desenhada no fim dele
    tip: [:0]const u8 = "",
    tip_key: usize = 0, // o retângulo da dica, para saber há quanto tempo o mouse está nele
    tip_since: f64 = 0,

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
        ui.tip = "";
    }

    /// a dica `text` aparece se o mouse fica um instante em `rect` (desenhada por `drawTip`, no fim do quadro)
    pub fn tooltip(ui: *Ui, rect: rl.Rectangle, text: [:0]const u8) void {
        // com uma janela por cima (o clique da tela de baixo já foi tomado), a de baixo não dá dica
        if (text.len == 0 or ui.click_taken or !ui.hovering(rect)) return;
        const key = @as(usize, @intFromFloat(@max(0, rect.x))) *% 73856093 ^ @as(usize, @intFromFloat(@max(0, rect.y))) *% 19349663;
        if (key != ui.tip_key) {
            ui.tip_key = key;
            ui.tip_since = rl.getTime();
        }
        ui.tip = text;
    }

    /// desenha a dica marcada neste quadro, perto do mouse (depois de tudo, fora dos recortes)
    pub fn drawTip(ui: *Ui, screen_width: f32, screen_height: f32) void {
        if (ui.tip.len == 0 or rl.getTime() - ui.tip_since < 0.45) return;
        const width: f32 = @min(380, screen_width - 16);
        const height = paragraphHeight(ui.fonts.regular, ui.tip, width - 16, 13) + 12;
        const x = @min(ui.mouse.x + 14, screen_width - width - 8);
        const y = if (ui.mouse.y + 22 + height > screen_height) ui.mouse.y - height - 8 else ui.mouse.y + 22;
        const box: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = height };
        rounded(box, 5, theme.hex(0xfffbe6));
        roundedLines(box, 5, theme.colors.line);
        _ = paragraph(ui.fonts.regular, ui.tip, x + 8, y + 6, width - 16, 13, theme.colors.ink);
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

/// texto corrido quebrado em linhas de até `width` (nas palavras e no "\n"); devolve a altura usada
pub fn paragraph(font: rl.Font, content: []const u8, x: f32, y: f32, width: f32, size: f32, color: rl.Color) f32 {
    return wrapText(font, content, x, y, width, size, color, true);
}

/// a altura que `paragraph` usaria
pub fn paragraphHeight(font: rl.Font, content: []const u8, width: f32, size: f32) f32 {
    return wrapText(font, content, 0, 0, width, size, theme.colors.ink, false);
}

fn wrapText(font: rl.Font, content: []const u8, x: f32, y: f32, width: f32, size: f32, color: rl.Color, draw_it: bool) f32 {
    const line_height = size + 4;
    var line: [512:0]u8 = undefined;
    var line_len: usize = 0;
    var lines: f32 = 0;
    var paragraphs = std.mem.splitScalar(u8, content, '\n');
    while (paragraphs.next()) |part| {
        var words = std.mem.tokenizeScalar(u8, part, ' ');
        line_len = 0;
        while (words.next()) |word| {
            const extra = word.len + @intFromBool(line_len > 0);
            if (line_len + extra >= line.len) break;
            var trial = line;
            var trial_len = line_len;
            if (trial_len > 0) {
                trial[trial_len] = ' ';
                trial_len += 1;
            }
            @memcpy(trial[trial_len..][0..word.len], word);
            trial_len += word.len;
            trial[trial_len] = 0;
            if (line_len > 0 and theme.textWidth(font, trial[0..trial_len :0], size) > width) {
                line[line_len] = 0;
                if (draw_it) theme.text(font, line[0..line_len :0], x, y + lines * line_height, size, color);
                lines += 1;
                @memcpy(line[0..word.len], word);
                line_len = word.len;
            } else {
                line = trial;
                line_len = trial_len;
            }
        }
        line[line_len] = 0;
        if (draw_it and line_len > 0) theme.text(font, line[0..line_len :0], x, y + lines * line_height, size, color);
        lines += 1;
    }
    return lines * line_height;
}

/// põe o cursor do texto do raygui no fim de `buffer` (ao começar a editar um campo, digitar acrescenta no fim):
/// o raygui só põe o cursor por um clique dentro do texto, então ele vê, num recorte vazio, uma caixa montada para o
/// mouse cair logo depois do texto
pub fn caretToEnd(ui: *Ui, buffer: [:0]u8) void {
    const length = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    const padding: f32 = @floatFromInt(rg.getStyle(.default, .text_padding));
    const width = rg.getTextWidth(buffer[0..length :0]);
    const fake: rl.Rectangle = .{ .x = ui.mouse.x - @as(f32, @floatFromInt(width)) - padding - 6, .y = ui.mouse.y - 10, .width = @as(f32, @floatFromInt(width)) + 2 * padding + 40, .height = 20 };
    ui.pushClip(.{ .x = 0, .y = 0, .width = 0, .height = 0 });
    _ = rg.textBox(fake, buffer, true);
    ui.popClip();
}

/// a divisa entre duas áreas lado a lado (o formulário e os resultados): arrastar muda a largura da da esquerda.
/// Chamar `update` antes de desenhar as áreas (o clique na divisa não chega nelas) e `draw` depois
pub const Splitter = struct {
    width: f32,
    dragging: bool = false,
    hovered: bool = false,

    const grip_half: f32 = 4;

    /// lê o mouse: arrastando a divisa em `left + width`, a largura segue o mouse entre `minimum` e `maximum`
    pub fn update(splitter: *Splitter, ui: *Ui, left: f32, top: f32, height: f32, minimum: f32, maximum: f32) void {
        const grip: rl.Rectangle = .{ .x = left + splitter.width - grip_half, .y = top, .width = 2 * grip_half, .height = height };
        splitter.hovered = !ui.click_taken and ui.hovering(grip);
        if (splitter.hovered and ui.clicked) {
            splitter.dragging = true;
            ui.click_taken = true;
        }
        if (splitter.dragging) {
            if (rl.isMouseButtonDown(.left)) {
                splitter.width = std.math.clamp(ui.mouse.x - left, minimum, @max(minimum, maximum));
            } else splitter.dragging = false;
        }
        rl.setMouseCursor(if (splitter.hovered or splitter.dragging) .resize_ew else .default);
    }

    /// a linha da divisa, marcada com o mouse em cima ou arrastando
    pub fn draw(splitter: *const Splitter, left: f32, top: f32, height: f32) void {
        const active = splitter.hovered or splitter.dragging;
        const thickness: f32 = if (active) 3 else 1;
        rl.drawRectangleRec(.{ .x = left + splitter.width - thickness / 2, .y = top, .width = thickness, .height = height }, if (active) theme.colors.accent else theme.colors.line);
    }
};

/// um campo que acabou de entrar em edição mostra o valor antigo todo marcado: a primeira tecla de texto troca o
/// valor inteiro pelo que se digita (como selecionar tudo), e apagar ou mover o cursor volta à edição normal.
/// Chamar logo depois do `rg.textBox` do campo, com o comprimento do texto quando a edição começou
pub fn replaceOnType(ui: *Ui, box: rl.Rectangle, buffer: [:0]u8, fresh: *bool, start_length: usize) void {
    if (!fresh.*) return;
    const length = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    if (length > start_length) {                 // digitou: fica só o que entrou depois do valor antigo
        const typed = length - start_length;
        std.mem.copyForwards(u8, buffer[0..typed], buffer[start_length..length]);
        @memset(buffer[typed..], 0);
        fresh.* = false;
        caretToEnd(ui, buffer);
        return;
    }
    if (length < start_length or rl.isKeyPressed(.left) or rl.isKeyPressed(.right) or rl.isKeyPressed(.home) or
        rl.isKeyPressed(.end))
    {
        fresh.* = false;
        return;
    }
    const padding: f32 = @floatFromInt(rg.getStyle(.default, .text_padding));
    const width: f32 = @floatFromInt(rg.getTextWidth(buffer[0..length :0]));
    var marked = theme.colors.accent;
    marked.a = 70;
    rl.drawRectangleRec(.{ .x = box.x + padding, .y = box.y + 3, .width = @min(width + 2, box.width - 2 * padding), .height = box.height - 6 }, marked);
}

/// o "?" de ajuda ao lado de um título: a dica `text` com o mouse em cima
pub fn helpMark(ui: *Ui, x: f32, y: f32, text: [:0]const u8) void {
    const center: rl.Vector2 = .{ .x = x + 8, .y = y + 8 };
    rl.drawCircleV(center, 8, theme.colors.selected);
    rl.drawCircleLinesV(center, 8, theme.colors.accent);
    theme.text(ui.fonts.regular, "?", x + 4.5, y + 0.5, 13, theme.colors.accent);
    ui.tooltip(.{ .x = x, .y = y, .width = 16, .height = 16 }, text);
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

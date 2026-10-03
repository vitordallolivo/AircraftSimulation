//! Widgets dos menus (modo imediato): cada quadro a tela chama `begin`, os widgets na ordem em que
//! aparecem e `end`. O mesmo menu anda pelo mouse (passar por cima destaca, clicar ativa), pelo
//! teclado (setas, Enter, Esc) e pelo controle (direcional ou analógico, A, B):
//!   ↑ ↓      muda o item em destaque          ← →   muda o valor (deslizador, opção, liga/desliga)
//!   Enter/A  ativa                             Esc/B  volta
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");

pub const Rect = rl.Rectangle;

pub const Nav = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    accept: bool = false,
    back: bool = false,
};

pub const Ui = struct {
    fonts: *const theme.Fonts,
    focus: usize = 0,
    count: usize = 0,
    last_count: usize = 0,
    nav: Nav = .{},
    mouse: rl.Vector2 = .{ .x = 0, .y = 0 },
    mouse_moved: bool = false,
    clicked: bool = false,
    down: bool = false,
    stick_nav: bool = true, // o analógico também navega (o menu de controle desliga)
    repeat_t: f64 = 0, // repetição ao segurar uma direção
    held: u8 = 0,
    dragging: ?usize = null,
    hovering: bool = false,

    pub fn begin(u: *Ui, dt: f64) void {
        u.count = 0;
        u.hovering = false;
        const m = rl.getMousePosition();
        u.mouse_moved = @abs(m.x - u.mouse.x) + @abs(m.y - u.mouse.y) > 0.5;
        u.mouse = m;
        u.clicked = rl.isMouseButtonPressed(.left);
        u.down = rl.isMouseButtonDown(.left);
        if (!u.down) u.dragging = null;
        var n: Nav = .{};
        const pad = rl.isGamepadAvailable(0);
        n.up = rl.isKeyPressed(.up) or (pad and rl.isGamepadButtonPressed(0, .left_face_up));
        n.down = rl.isKeyPressed(.down) or (pad and rl.isGamepadButtonPressed(0, .left_face_down));
        n.left = rl.isKeyPressed(.left) or (pad and rl.isGamepadButtonPressed(0, .left_face_left));
        n.right = rl.isKeyPressed(.right) or (pad and rl.isGamepadButtonPressed(0, .left_face_right));
        n.accept = rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter) or (pad and rl.isGamepadButtonPressed(0, .right_face_down));
        n.back = rl.isKeyPressed(.escape) or rl.isKeyPressed(.backspace) or (pad and rl.isGamepadButtonPressed(0, .right_face_right));
        // segurar uma direção (tecla, direcional ou analógico) repete: 0,35 s e depois a cada 0,08 s
        var dir: u8 = 0;
        if (rl.isKeyDown(.up) or (pad and rl.isGamepadButtonDown(0, .left_face_up))) dir = 1;
        if (rl.isKeyDown(.down) or (pad and rl.isGamepadButtonDown(0, .left_face_down))) dir = 2;
        if (rl.isKeyDown(.left) or (pad and rl.isGamepadButtonDown(0, .left_face_left))) dir = 3;
        if (rl.isKeyDown(.right) or (pad and rl.isGamepadButtonDown(0, .left_face_right))) dir = 4;
        if (pad and u.stick_nav and dir == 0) {
            const x = rl.getGamepadAxisMovement(0, .left_x);
            const y = rl.getGamepadAxisMovement(0, .left_y);
            if (@abs(y) > 0.6 and @abs(y) > @abs(x)) dir = if (y < 0) 1 else 2;
            if (@abs(x) > 0.6 and @abs(x) >= @abs(y)) dir = if (x < 0) 3 else 4;
            if (dir != 0 and u.held == 0) switch (dir) { // primeira inclinação do analógico
                1 => n.up = true,
                2 => n.down = true,
                3 => n.left = true,
                else => n.right = true,
            };
        }
        if (dir != 0 and dir == u.held) {
            u.repeat_t += dt;
            if (u.repeat_t > 0.35) {
                u.repeat_t -= 0.08;
                switch (dir) {
                    1 => n.up = true,
                    2 => n.down = true,
                    3 => n.left = true,
                    else => n.right = true,
                }
            }
        } else u.repeat_t = 0;
        u.held = dir;
        u.nav = n;
        if (u.last_count > 0) {
            if (n.up) u.focus = (u.focus + u.last_count - 1) % u.last_count;
            if (n.down) u.focus = (u.focus + 1) % u.last_count;
        }
    }

    pub fn end(u: *Ui) void {
        u.last_count = u.count;
        if (u.count > 0 and u.focus >= u.count) u.focus = u.count - 1;
        rl.setMouseCursor(if (u.hovering) .pointing_hand else .default);
    }

    /// novo menu (volta o destaque para o primeiro item)
    pub fn reset(u: *Ui) void {
        u.focus = 0;
        u.last_count = 0;
    }

    pub const Item = struct { id: usize, focused: bool, hovered: bool, activated: bool };

    fn item(u: *Ui, r: Rect) Item {
        const id = u.count;
        u.count += 1;
        const hovered = rl.checkCollisionPointRec(u.mouse, r);
        if (hovered) u.hovering = true;
        if (hovered and (u.mouse_moved or u.clicked)) u.focus = id;
        const focused = u.focus == id;
        return .{ .id = id, .focused = focused, .hovered = hovered, .activated = (focused and u.nav.accept) or (hovered and u.clicked) };
    }

    fn highlight(r: Rect, it: Item) void {
        if (it.focused) {
            rl.drawRectangleRounded(r, 0.22, 6, theme.selected);
            rl.drawRectangleRounded(.{ .x = r.x, .y = r.y + 6, .width = 4, .height = r.height - 12 }, 1, 4, theme.title);
        } else if (it.hovered) rl.drawRectangleRounded(r, 0.22, 6, theme.hover);
    }

    /// item de menu (texto grande; `hint` pequeno à direita)
    pub fn menuItem(u: *Ui, r: Rect, label: [:0]const u8, hint: ?[:0]const u8) bool {
        const it = u.item(r);
        highlight(r, it);
        const size = @min(26, r.height * 0.58);
        u.fonts.draw(label, r.x + 18, r.y + (r.height - size) / 2, size, if (it.focused) theme.title else theme.text);
        if (hint) |h| u.fonts.draw(h, r.x + r.width - u.fonts.width(h, 15) - 14, r.y + (r.height - 15) / 2, 15, theme.muted);
        return it.activated;
    }

    pub fn button(u: *Ui, r: Rect, label: [:0]const u8, primary: bool) bool {
        const it = u.item(r);
        const bg = if (primary) (if (it.focused or it.hovered) theme.title_hi else theme.title) else (if (it.focused) theme.selected else if (it.hovered) theme.hover else theme.panel_alt);
        rl.drawRectangleRounded(r, 0.3, 6, bg);
        if (it.focused) rl.drawRectangleRoundedLinesEx(r, 0.3, 6, 2, theme.title);
        const size = @min(22, r.height * 0.5);
        u.fonts.draw(label, r.x + (r.width - u.fonts.width(label, size)) / 2, r.y + (r.height - size) / 2, size, if (primary) rl.Color.white else theme.text);
        return it.activated;
    }

    /// liga/desliga (Enter, clique, ← →)
    pub fn toggle(u: *Ui, r: Rect, label: [:0]const u8, v: *bool) bool {
        const it = u.item(r);
        highlight(r, it);
        const changed = it.activated or (it.focused and (u.nav.left or u.nav.right));
        if (changed) v.* = !v.*;
        u.fonts.draw(label, r.x + 14, r.y + (r.height - 19) / 2, 19, theme.text);
        const sw: Rect = .{ .x = r.x + r.width - 62, .y = r.y + (r.height - 24) / 2, .width = 46, .height = 24 };
        rl.drawRectangleRounded(sw, 1, 8, if (v.*) theme.ok else theme.muted_light);
        rl.drawCircleV(.{ .x = if (v.*) sw.x + sw.width - 12 else sw.x + 12, .y = sw.y + 12 }, 9, .white);
        return changed;
    }

    /// deslizador: ← → anda `step`; arrastar a barra com o mouse
    pub fn slider(u: *Ui, r: Rect, label: [:0]const u8, v: *f64, lo: f64, hi: f64, step: f64, comptime fmt: []const u8, scale: f64) bool {
        const it = u.item(r);
        highlight(r, it);
        const old = v.*;
        if (!std.math.isFinite(v.*)) v.* = lo;
        if (it.focused and u.nav.left) v.* -= step;
        if (it.focused and u.nav.right) v.* += step;
        const label_w = @max(150, r.width * 0.36);
        const bar: Rect = .{ .x = r.x + label_w, .y = r.y + r.height / 2 - 4, .width = r.width - label_w - 90, .height = 8 };
        const grab: Rect = .{ .x = bar.x - 8, .y = r.y, .width = bar.width + 16, .height = r.height };
        if (u.clicked and rl.checkCollisionPointRec(u.mouse, grab)) u.dragging = it.id;
        if (u.dragging == it.id and u.down and bar.width > 1) {
            const f = std.math.clamp((u.mouse.x - bar.x) / bar.width, 0, 1);
            v.* = lo + (hi - lo) * @as(f64, f);
            if (step > 0) v.* = lo + @round((v.* - lo) / step) * step;
        }
        v.* = std.math.clamp(v.*, lo, hi);
        u.fonts.draw(label, r.x + 14, r.y + (r.height - 19) / 2, 19, theme.text);
        rl.drawRectangleRounded(bar, 1, 6, theme.muted_light);
        const frac: f32 = @floatCast(if (hi > lo) (v.* - lo) / (hi - lo) else 0);
        rl.drawRectangleRounded(.{ .x = bar.x, .y = bar.y, .width = frac * bar.width, .height = bar.height }, 1, 6, theme.title);
        rl.drawCircleV(.{ .x = bar.x + frac * bar.width, .y = bar.y + 4 }, if (it.focused or u.dragging == it.id) 10 else 8, if (it.focused) theme.title else theme.title_hi);
        var buf: [32]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&buf, fmt, .{v.* * scale}) catch "";
        u.fonts.draw(txt, r.x + r.width - 80, r.y + (r.height - 18) / 2, 18, theme.muted);
        return v.* != old;
    }

    /// escolha entre opções: ← → (ou clique) passa para a próxima
    pub fn choice(u: *Ui, r: Rect, label: [:0]const u8, idx: *usize, options: []const [:0]const u8) bool {
        const it = u.item(r);
        highlight(r, it);
        if (options.len == 0) return false;
        const old = idx.*;
        if (idx.* >= options.len) idx.* = 0;
        if (it.focused and u.nav.left) idx.* = (idx.* + options.len - 1) % options.len;
        if ((it.focused and u.nav.right) or it.activated) idx.* = (idx.* + 1) % options.len;
        u.fonts.draw(label, r.x + 14, r.y + (r.height - 19) / 2, 19, theme.text);
        const opt = options[idx.*];
        const ow = u.fonts.width(opt, 19);
        const right = r.x + r.width - 16;
        u.fonts.draw("‹", right - ow - 26, r.y + (r.height - 20) / 2, 20, theme.muted);
        u.fonts.draw(opt, right - ow - 10, r.y + (r.height - 19) / 2, 19, theme.title);
        u.fonts.draw("›", right - 4, r.y + (r.height - 20) / 2, 20, theme.muted);
        return idx.* != old;
    }

    /// linha de lista (selecionável); `selected` = a escolhida no momento
    pub fn listRow(u: *Ui, r: Rect, label: [:0]const u8, selected: bool, note: ?[:0]const u8) bool {
        const it = u.item(r);
        highlight(r, it);
        if (selected) rl.drawCircleV(.{ .x = r.x + 14, .y = r.y + r.height / 2 }, 5, theme.accent);
        var size: f32 = 19;
        const room = r.width - 40 - if (note) |n| u.fonts.width(n, 14) + 12 else 0;
        while (size > 12 and u.fonts.width(label, size) > room) size -= 1;
        u.fonts.draw(label, r.x + 28, r.y + (r.height - size) / 2, size, if (selected) theme.title else theme.text);
        if (note) |n| u.fonts.draw(n, r.x + r.width - u.fonts.width(n, 14) - 10, r.y + (r.height - 14) / 2, 14, theme.muted);
        return it.activated;
    }

    /// item que existe mas está fora da área visível (rolagem): conta para a navegação, não desenha
    pub fn hidden(u: *Ui) Item {
        const id = u.count;
        u.count += 1;
        const focused = u.focus == id;
        return .{ .id = id, .focused = focused, .hovered = false, .activated = focused and u.nav.accept };
    }

    /// o número que o próximo item vai ter (para saber se o destaque está numa lista)
    pub fn nextId(u: *const Ui) usize {
        return u.count;
    }

    /// voltar (Esc, Backspace, B)
    pub fn back(u: *const Ui) bool {
        return u.nav.back;
    }
};

pub const Row = struct { text: [:0]const u8, selected: bool = false, note: ?[:0]const u8 = null, header: bool = false };

/// lista com rolagem: só desenha o que cabe; o destaque (teclado/controle) puxa a rolagem
pub const ScrollList = struct {
    scroll: usize = 0,

    /// `row(ctx, i)` dá o texto de cada linha; devolve a linha ativada. Cabeçalhos (`header`)
    /// não recebem destaque: o teclado/controle pula por cima deles.
    pub fn draw(sl: *ScrollList, u: *Ui, area: Rect, row_h: f32, n: usize, ctx: anytype, comptime row: fn (@TypeOf(ctx), usize) Row) ?usize {
        const first = u.nextId();
        const fit: usize = @intFromFloat(@max(1, @floor(area.height / row_h)));
        // a linha que tem o destaque (contando só as que não são cabeçalho)
        var id = first;
        var focused_row: ?usize = null;
        var last_header: usize = 0;
        for (0..n) |i| {
            if (row(ctx, i).header) {
                last_header = i;
                continue;
            }
            if (id == u.focus) {
                focused_row = i;
                break;
            }
            id += 1;
        }
        if (focused_row) |fi| {
            const top = if (last_header + 1 == fi) last_header else fi; // mostra o cabeçalho junto
            if (top < sl.scroll) sl.scroll = top;
            if (fi >= sl.scroll + fit) sl.scroll = fi + 1 - fit;
        }
        if (rl.checkCollisionPointRec(u.mouse, area)) {
            const w = rl.getMouseWheelMove();
            if (w > 0 and sl.scroll > 0) sl.scroll -= 1;
            if (w < 0) sl.scroll += 1;
        }
        sl.scroll = @min(sl.scroll, if (n > fit) n - fit else 0);
        var hit: ?usize = null;
        for (0..n) |i| {
            const rw = row(ctx, i);
            const visible = i >= sl.scroll and i < sl.scroll + fit;
            const r: Rect = .{ .x = area.x, .y = area.y + @as(f32, @floatFromInt(i -| sl.scroll)) * row_h, .width = area.width - 10, .height = row_h - 2 };
            if (rw.header) {
                if (visible) u.fonts.draw(rw.text, r.x + 10, r.y + r.height - 20, 16, theme.muted);
                continue;
            }
            if (visible) {
                if (u.listRow(r, rw.text, rw.selected, rw.note)) hit = i;
            } else if (u.hidden().activated) hit = i;
        }
        if (n > fit) { // barra de rolagem
            const fr = @as(f32, @floatFromInt(fit)) / @as(f32, @floatFromInt(n));
            const off = @as(f32, @floatFromInt(sl.scroll)) / @as(f32, @floatFromInt(n));
            rl.drawRectangleRounded(.{ .x = area.x + area.width - 5, .y = area.y + off * area.height, .width = 4, .height = fr * area.height }, 1, 4, theme.muted_light);
        }
        return hit;
    }
};

/// coluna de itens um embaixo do outro
pub const Column = struct {
    x: f32,
    y: f32,
    w: f32,
    gap: f32 = 8,

    pub fn next(c: *Column, h: f32) Rect {
        const r: Rect = .{ .x = c.x, .y = c.y, .width = c.w, .height = h };
        c.y += h + c.gap;
        return r;
    }

    pub fn space(c: *Column, h: f32) void {
        c.y += h;
    }
};

/// título de tela + dica de teclas embaixo (o padrão de todos os menus)
pub fn header(f: *const theme.Fonts, title: [:0]const u8, sub: ?[:0]const u8) void {
    f.draw(title, 40, 30, 38, theme.title);
    if (sub) |s| f.draw(s, 42, 76, 17, theme.muted);
}

pub fn footer(f: *const theme.Fonts, text: [:0]const u8) void {
    const H: f32 = @floatFromInt(rl.getScreenHeight());
    f.draw(text, 40, H - 32, 15, theme.muted);
}

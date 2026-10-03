//! Símbolos dos botões nas dicas da tela: com controle ligado, o botão do Xbox (símbolo branco
//! num fundo escuro: A B X Y redondos, LB RB RT, START, BACK, direcional, analógicos); sem
//! controle, a tecla equivalente.
//!
//!   glyphs.hints(&fontes, x, y, &.{ .{ .btn = .a, .key = "Enter", .label = "abrir" }, ... });
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");

const ch = @import("../input/channels.zig");

/// os botões do controle (os mesmos de `channels.Pad`) + o direcional inteiro
pub const Btn = enum { a, b, x, y, lb, rb, lt, rt, back, start, ls, rs, up, down, left, right, dpad };

pub fn fromPad(p: ch.Pad) Btn {
    return @enumFromInt(@intFromEnum(p));
}

pub const Hint = struct { btn: Btn, key: [:0]const u8, label: [:0]const u8 };

const dark: rl.Color = .{ .r = 34, .g = 38, .b = 48, .a = 235 };
const white: rl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const dim: rl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 90 };

/// mostrar os símbolos do controle mesmo sem controle ligado (fotos `--shot ... controle`)
pub var force_pad = false;

pub fn padShown() bool {
    return force_pad or rl.isGamepadAvailable(0);
}

/// desenha o botão com altura `h` a partir de (x, y); devolve a largura
pub fn button(f: *const theme.Fonts, b: Btn, x: f32, y: f32, h: f32) f32 {
    const r = h / 2;
    const c: rl.Vector2 = .{ .x = x + r, .y = y + r };
    switch (b) {
        .a, .b, .x, .y => {
            rl.drawCircleV(c, r, dark);
            const t: [:0]const u8 = switch (b) {
                .a => "A",
                .b => "B",
                .x => "X",
                else => "Y",
            };
            const s = h * 0.62;
            f.draw(t, c.x - f.width(t, s) / 2, c.y - s / 2, s, white);
            return h;
        },
        .lb, .rb, .lt, .rt, .start, .back => {
            const t: [:0]const u8 = switch (b) {
                .lb => "LB",
                .rb => "RB",
                .lt => "LT",
                .rt => "RT",
                .start => "START",
                else => "BACK",
            };
            const s = if (b == .start or b == .back) h * 0.42 else h * 0.55;
            const w = f.width(t, s) + h * 0.7;
            rl.drawRectangleRounded(.{ .x = x, .y = y, .width = w, .height = h }, 0.5, 8, dark);
            f.draw(t, x + (w - f.width(t, s)) / 2, y + (h - s) / 2, s, white);
            return w;
        },
        .dpad, .up, .down, .left, .right => {
            rl.drawCircleV(c, r, dark);
            const a = h * 0.17; // meia largura do braço
            const l = h * 0.36; // comprimento do braço
            const arm = struct {
                fn col(bb: Btn, me: Btn) rl.Color {
                    return if (bb == .dpad or bb == me) white else dim;
                }
            }.col;
            rl.drawRectangleRec(.{ .x = c.x - a, .y = c.y - l, .width = 2 * a, .height = l }, arm(b, .up));
            rl.drawRectangleRec(.{ .x = c.x - a, .y = c.y, .width = 2 * a, .height = l }, arm(b, .down));
            rl.drawRectangleRec(.{ .x = c.x - l, .y = c.y - a, .width = l, .height = 2 * a }, arm(b, .left));
            rl.drawRectangleRec(.{ .x = c.x, .y = c.y - a, .width = l, .height = 2 * a }, arm(b, .right));
            return h;
        },
        .ls, .rs => {
            rl.drawCircleV(c, r, dark);
            rl.drawRing(c, r * 0.5, r * 0.68, 0, 360, 24, white);
            const t: [:0]const u8 = if (b == .ls) "L" else "R";
            const s = h * 0.34;
            f.draw(t, c.x - f.width(t, s) / 2, c.y - s / 2, s, white);
            return h;
        },
    }
}

/// tecla do teclado (fundo claro, borda)
pub fn key(f: *const theme.Fonts, t: [:0]const u8, x: f32, y: f32, h: f32) f32 {
    const s = h * 0.55;
    const w = @max(h, f.width(t, s) + h * 0.6);
    const r: rl.Rectangle = .{ .x = x, .y = y, .width = w, .height = h };
    rl.drawRectangleRounded(r, 0.3, 6, .{ .r = 250, .g = 250, .b = 252, .a = 240 });
    rl.drawRectangleRoundedLinesEx(r, 0.3, 6, 1.2, theme.muted);
    f.draw(t, x + (w - f.width(t, s)) / 2, y + (h - s) / 2, s, theme.text);
    return w;
}

/// linha de dicas (botão/tecla + o que faz); devolve a largura total
pub fn hints(f: *const theme.Fonts, x: f32, y: f32, items: []const Hint, color: rl.Color) f32 {
    const pad = padShown();
    const h: f32 = 22;
    var cx = x;
    for (items) |it| {
        cx += if (pad) button(f, it.btn, cx, y, h) else key(f, it.key, cx, y, h);
        cx += 6;
        f.draw(it.label, cx, y + (h - 15) / 2, 15, color);
        cx += f.width(it.label, 15) + 18;
    }
    return cx - x;
}

/// largura que `hints` vai ocupar (para alinhar à direita)
pub fn hintsWidth(f: *const theme.Fonts, items: []const Hint) f32 {
    const pad = padShown();
    const h: f32 = 22;
    var w: f32 = 0;
    for (items) |it| {
        w += if (pad) widthOf(f, it.btn, h) else @max(h, f.width(it.key, h * 0.55) + h * 0.6);
        w += 6 + f.width(it.label, 15) + 18;
    }
    return w;
}

fn widthOf(f: *const theme.Fonts, b: Btn, h: f32) f32 {
    return switch (b) {
        .lb, .rb, .lt, .rt => f.width("LB", h * 0.55) + h * 0.7,
        .start => f.width("START", h * 0.42) + h * 0.7,
        .back => f.width("BACK", h * 0.42) + h * 0.7,
        else => h,
    };
}

//! Aparência das telas (mesma linguagem da GUI: fundo claro, azul nos títulos, pouco texto), a
//! fonte com acentos (procura uma do sistema; sem nenhuma, usa a do raylib) e os widgets simples.
const std = @import("std");
const rl = @import("raylib");
const platform = @import("../sys/platform.zig");

pub const bg: rl.Color = .{ .r = 245, .g = 246, .b = 250, .a = 255 }; // fundo do 3D (o da GUI)
pub const sky: rl.Color = .{ .r = 112, .g = 172, .b = 236, .a = 255 }; // céu do voo (saturado)
pub const sky_low: rl.Color = .{ .r = 196, .g = 226, .b = 250, .a = 255 }; // perto do horizonte
pub const panel: rl.Color = .{ .r = 232, .g = 236, .b = 243, .a = 255 };
pub const panel_alt: rl.Color = .{ .r = 220, .g = 226, .b = 236, .a = 255 };
pub const hover: rl.Color = .{ .r = 218, .g = 228, .b = 244, .a = 255 };
pub const muted_light: rl.Color = .{ .r = 196, .g = 202, .b = 214, .a = 255 };
pub const title_hi: rl.Color = .{ .r = 46, .g = 110, .b = 196, .a = 255 };
pub const shade: rl.Color = .{ .r = 10, .g = 20, .b = 40, .a = 150 }; // escurece o fundo (pausa)
pub const panel_glass: rl.Color = .{ .r = 245, .g = 247, .b = 250, .a = 215 };
pub const title: rl.Color = .{ .r = 31, .g = 78, .b = 140, .a = 255 }; // #1f4e8c
pub const text: rl.Color = .{ .r = 40, .g = 40, .b = 46, .a = 255 };
pub const muted: rl.Color = .{ .r = 120, .g = 124, .b = 134, .a = 255 };
pub const accent: rl.Color = .{ .r = 242, .g = 166, .b = 38, .a = 255 }; // cor dos comandos
pub const selected: rl.Color = .{ .r = 200, .g = 214, .b = 236, .a = 255 };
pub const danger: rl.Color = .{ .r = 214, .g = 39, .b = 40, .a = 255 };
pub const ok: rl.Color = .{ .r = 44, .g = 160, .b = 44, .a = 255 };

// no navegador, a fonte que o build põe no pacote (build.zig, `web_font_candidates`)
const candidates = (if (platform.in_browser) [_][:0]const u8{"/fonts/aerodrive.ttf"} else [_][:0]const u8{}) ++ [_][:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
};

pub const Fonts = struct {
    body: rl.Font,
    owned: bool,

    pub fn load() Fonts {
        const extra = [_]i32{ 0x2022, 0x2190, 0x2191, 0x2192, 0x2193, 0x03B4, 0x24D8, 0x2039, 0x203A, 0x03B8, 0x03B1, 0x03B3, 0x03C6, 0x03B2, 0x03C8, 0x03C7, 0x25CF, 0x25B6, 0x2016, 0x2605, 0x2014, 0x2013, 0x2082, 0x00B2, 0x21C4 };
        var cps: [224 + extra.len]i32 = undefined; // ASCII + Latin-1 (acentos) + símbolos usados
        for (0..224) |i| cps[i] = @intCast(32 + i);
        @memcpy(cps[224..], &extra);
        for (candidates) |p| {
            if (rl.fileExists(p)) {
                const f = rl.loadFontEx(p, 40, &cps) catch continue;
                rl.setTextureFilter(f.texture, .bilinear);
                return .{ .body = f, .owned = true };
            }
        }
        return .{ .body = rl.getFontDefault() catch unreachable, .owned = false };
    }

    pub fn deinit(f: *Fonts) void {
        if (f.owned) rl.unloadFont(f.body);
    }

    pub fn draw(f: *const Fonts, s: [:0]const u8, x: f32, y: f32, size: f32, col: rl.Color) void {
        rl.drawTextEx(f.body, s, .{ .x = x, .y = y }, size, 0.5, col);
    }

    pub fn width(f: *const Fonts, s: [:0]const u8, size: f32) f32 {
        return rl.measureTextEx(f.body, s, size, 0.5).x;
    }
};

/// barra de comando: centrada (−max..max, em graus) ou de 0 a 1 (em %)
pub fn commandBar(f: *const Fonts, name: [:0]const u8, v: f64, max: f64, centered: bool, x: f32, y: f32, w: f32) void {
    var buf: [32]u8 = undefined;
    f.draw(name, x, y, 17, text);
    const bx = x + 100;
    const bw = w - 100 - 56;
    rl.drawRectangleRounded(.{ .x = bx, .y = y + 4, .width = bw, .height = 11 }, 0.5, 6, selected);
    const frac: f32 = @floatCast(if (std.math.isFinite(v / max)) std.math.clamp(v / max, -1, 1) else 0);
    if (centered) {
        const mid = bx + bw / 2;
        const len = frac * bw / 2;
        rl.drawRectangleRec(.{ .x = if (len < 0) mid + len else mid, .y = y + 4, .width = @abs(len), .height = 11 }, accent);
        rl.drawLineEx(.{ .x = mid, .y = y }, .{ .x = mid, .y = y + 19 }, 1.5, muted);
        const deg = std.math.radiansToDegrees(v);
        f.draw(std.fmt.bufPrintZ(&buf, "{d:.0}°", .{if (@abs(deg) < 0.5) 0 else deg}) catch "", bx + bw + 8, y, 15, muted);
    } else {
        rl.drawRectangleRec(.{ .x = bx, .y = y + 4, .width = frac * bw, .height = 11 }, accent);
        f.draw(std.fmt.bufPrintZ(&buf, "{d:.0} %", .{100 * v}) catch "", bx + bw + 8, y, 15, muted);
    }
}

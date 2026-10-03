//! Aparência das telas (mesma linguagem da GUI: fundo claro, azul nos títulos, pouco texto) e a
//! fonte com acentos (procura uma do sistema; sem nenhuma, usa a do raylib).
const std = @import("std");
const c = @import("c");

pub const bg: c.Color = .{ .r = 245, .g = 246, .b = 250, .a = 255 }; // fundo do 3D (o da GUI)
pub const panel: c.Color = .{ .r = 232, .g = 236, .b = 243, .a = 255 };
pub const title: c.Color = .{ .r = 31, .g = 78, .b = 140, .a = 255 }; // #1f4e8c
pub const text: c.Color = .{ .r = 40, .g = 40, .b = 46, .a = 255 };
pub const muted: c.Color = .{ .r = 120, .g = 124, .b = 134, .a = 255 };
pub const accent: c.Color = .{ .r = 242, .g = 166, .b = 38, .a = 255 }; // cor dos comandos
pub const selected: c.Color = .{ .r = 200, .g = 214, .b = 236, .a = 255 };

const candidates = [_][:0]const u8{
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
    body: c.Font,
    owned: bool,

    pub fn load() Fonts {
        var cps: [224 + 4]c_int = undefined; // ASCII + Latin-1 (acentos) + símbolos usados
        for (0..224) |i| cps[i] = @intCast(32 + i);
        cps[224] = 0x2022; // •
        cps[225] = 0x2192; // →
        cps[226] = 0x03B4; // δ
        cps[227] = 0x24D8; // ⓘ
        for (candidates) |p| {
            if (c.FileExists(p.ptr)) {
                const f = c.LoadFontEx(p.ptr, 40, &cps, cps.len);
                if (f.texture.id != 0) {
                    c.SetTextureFilter(f.texture, c.TEXTURE_FILTER_BILINEAR);
                    return .{ .body = f, .owned = true };
                }
            }
        }
        return .{ .body = c.GetFontDefault(), .owned = false };
    }

    pub fn deinit(f: *Fonts) void {
        if (f.owned) c.UnloadFont(f.body);
    }

    pub fn draw(f: *const Fonts, s: [:0]const u8, x: f32, y: f32, size: f32, col: c.Color) void {
        c.DrawTextEx(f.body, s.ptr, .{ .x = x, .y = y }, size, 0.5, col);
    }

    pub fn width(f: *const Fonts, s: [:0]const u8, size: f32) f32 {
        return c.MeasureTextEx(f.body, s.ptr, size, 0.5).x;
    }
};

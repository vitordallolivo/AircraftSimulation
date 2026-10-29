//! O visual da interface (o "tema 6" escolhido no protótipo em HTML): grafite, laranja e preto, cantos cortados,
//! abas e botões inclinados, a logo do albatroz em azul. Aqui ficam as cores, as fontes e a logo.
const std = @import("std");
const rl = @import("raylib");

/// uma cor a partir de 0xRRGGBB (opaca)
pub fn hex(rgb: u24) rl.Color {
    return .{ .r = @truncate(rgb >> 16), .g = @truncate(rgb >> 8), .b = @truncate(rgb), .a = 255 };
}

/// a mesma cor com outra opacidade (0..1)
pub fn withAlpha(color: rl.Color, alpha: f32) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = @intFromFloat(std.math.clamp(alpha, 0, 1) * 255) };
}

pub const background = hex(0x25282c); // fundo da área dos gráficos
pub const panel = hex(0x2f3338); // cartões e grupos do formulário
pub const sidebar = hex(0x1b1d20); // coluna do formulário
pub const black = hex(0x0e0f11); // faixas pretas (cabeçalho, abas, títulos dos grupos)
pub const field = hex(0x17191c); // caixa de um valor
pub const line = hex(0x474d55); // bordas e grade forte
pub const grid = hex(0x3a3f46); // grade dos gráficos
pub const ink = hex(0xe3e5e8); // texto
pub const label = hex(0xc9ced5); // rótulo de um campo
pub const muted = hex(0x9aa1ab); // texto secundário (unidades, eixos)
pub const orange = hex(0xff6a13); // destaque
pub const albatross_blue = hex(0x2f8bff); // a logo

/// as cores das curvas, em ordem (a paleta aprovada: 10 cores bem distintas no fundo escuro)
pub const plot_colors = [_]rl.Color{
    hex(0xff8a3d), hex(0x4dabf7), hex(0x69db7c), hex(0xff6b6b), hex(0xb197fc),
    hex(0x3bc9db), hex(0xffd43b), hex(0xf783ac), hex(0xa9e34b), hex(0xced4da),
};

/// cor da curva `index` (dá a volta na paleta)
pub fn plotColor(index: usize) rl.Color {
    return plot_colors[index % plot_colors.len];
}

/// as fontes do sistema que servem (com acentos e letras gregas); sem nenhuma, a do raylib
const regular_candidates = [_][:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
};
const bold_candidates = [_][:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
};
const mono_candidates = [_][:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "C:/Windows/Fonts/consola.ttf",
    "/System/Library/Fonts/Menlo.ttc",
};

/// os caracteres carregados: ASCII, Latin-1 (acentos, ×, ², °) e os símbolos que as telas usam
fn codepoints() [224 + extra_symbols.len]i32 {
    var all: [224 + extra_symbols.len]i32 = undefined;
    for (0..224) |i| all[i] = @intCast(32 + i);
    @memcpy(all[224..], &extra_symbols);
    return all;
}
const extra_symbols = [_]i32{
    0x03B1, 0x03B2, 0x03B4, 0x03B5, 0x03B7, 0x03BB, 0x03C1, 0x03C3, // α β δ ε η λ ρ σ
    0x0394, 0x2014, 0x2013, 0x2192, 0x25B6, 0x25BC, 0x25B8, 0x2022, // Δ — – → ▶ ▼ ▸ •
    0x2082, 0x2264, 0x2265, 0x221E, 0x00B7, 0x2713, // ₂ ≤ ≥ ∞ · ✓
};

fn loadFirst(paths: []const [:0]const u8, cps: []const i32) ?rl.Font {
    for (paths) |path| {
        if (!rl.fileExists(path)) continue;
        const font = rl.loadFontEx(path, 48, cps) catch continue;
        rl.setTextureFilter(font.texture, .bilinear);
        return font;
    }
    return null;
}

pub const Fonts = struct {
    regular: rl.Font,
    bold: rl.Font,
    mono: rl.Font,
    owned: bool,

    /// carrega as três fontes (texto, títulos, números); precisa da janela aberta
    pub fn load() Fonts {
        const cps = codepoints();
        const fallback = rl.getFontDefault() catch unreachable;
        const regular = loadFirst(&regular_candidates, &cps) orelse return .{ .regular = fallback, .bold = fallback, .mono = fallback, .owned = false };
        return .{
            .regular = regular,
            .bold = loadFirst(&bold_candidates, &cps) orelse regular,
            .mono = loadFirst(&mono_candidates, &cps) orelse regular,
            .owned = true,
        };
    }

    /// libera as fontes carregadas
    pub fn deinit(fonts: *Fonts) void {
        if (!fonts.owned) return;
        rl.unloadFont(fonts.mono);
        rl.unloadFont(fonts.bold);
        rl.unloadFont(fonts.regular);
    }
};

/// espaçamento entre letras de um texto de tamanho `size`
pub fn spacing(size: f32) f32 {
    return size * 0.04;
}

/// escreve `text` com o canto de cima à esquerda em (x, y)
pub fn text(font: rl.Font, content: [:0]const u8, x: f32, y: f32, size: f32, color: rl.Color) void {
    rl.drawTextEx(font, content, .{ .x = @round(x), .y = @round(y) }, size, spacing(size), color);
}

/// largura de `text` em pixels
pub fn textWidth(font: rl.Font, content: [:0]const u8, size: f32) f32 {
    return rl.measureTextEx(font, content, size, spacing(size)).x;
}

/// a logo do albatroz numa cor só (a forma da imagem, pintada na hora de desenhar)
pub const Logo = struct {
    texture: rl.Texture2D,

    const png = @embedFile("../assets/albatroz.png");

    /// carrega a logo branca (o desenho pinta com a cor pedida); precisa da janela aberta
    pub fn load() !Logo {
        var image = try rl.loadImageFromMemory(".png", png);
        defer rl.unloadImage(image);
        rl.imageColorBrightness(&image, 255); // tudo branco, mantendo a transparência
        const texture = try rl.loadTextureFromImage(image);
        rl.setTextureFilter(texture, .bilinear);
        return .{ .texture = texture };
    }

    /// libera a textura
    pub fn deinit(logo: *Logo) void {
        rl.unloadTexture(logo.texture);
    }

    /// desenha a logo com altura `height`, o canto de cima à esquerda em (x, y)
    pub fn draw(logo: *const Logo, x: f32, y: f32, height: f32, color: rl.Color) void {
        const source_width: f32 = @floatFromInt(logo.texture.width);
        const source_height: f32 = @floatFromInt(logo.texture.height);
        const width = height * source_width / source_height;
        rl.drawTexturePro(logo.texture, .{ .x = 0, .y = 0, .width = source_width, .height = source_height }, .{ .x = x, .y = y, .width = width, .height = height }, .{ .x = 0, .y = 0 }, 0, color);
    }
};

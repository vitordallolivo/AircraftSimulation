//! O visual da interface, o mesmo do AeroDrive: fundo claro, cantos arredondados, azul nos títulos e pouco texto.
//! Aqui ficam as cores, as fontes e a logo do albatroz (nas cores dela).
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

/// os papéis das cores
pub const Palette = struct {
    background: rl.Color, // fundo da tela e do 3D
    panel: rl.Color, // cabeçalho, abas, coluna do formulário
    selected: rl.Color, // aba ativa, grupo com o mouse em cima
    hover: rl.Color,
    field: rl.Color, // cartões e caixas de valor
    line: rl.Color, // bordas e a linha do zero
    grid: rl.Color, // grade dos gráficos
    ink: rl.Color, // texto
    label: rl.Color, // rótulo de um campo
    muted: rl.Color, // texto secundário (unidades, eixos)
    accent: rl.Color, // títulos, aba ativa, botão principal, marcador ligado
    accent_hover: rl.Color,
    on_accent: rl.Color, // texto sobre o destaque
    ok: rl.Color,
    warning: rl.Color,
    failure: rl.Color,
    /// as cores das curvas, em ordem: 10 cores bem distintas no fundo claro
    plot: [10]rl.Color,
};

/// as cores do AeroDrive (`aerodrive/src/ui/theme.zig`), as mesmas da GUI em Python: fundo claro, azul nos títulos
pub const colors: Palette = .{
    .background = hex(0xf5f6fa),
    .panel = hex(0xe8ecf3),
    .selected = hex(0xc8d6ec),
    .hover = hex(0xdae4f4),
    .field = hex(0xffffff),
    .line = hex(0xc4cad6),
    .grid = hex(0xe3e7ee),
    .ink = hex(0x28282e),
    .label = hex(0x28282e),
    .muted = hex(0x787c86),
    .accent = hex(0x1f4e8c),
    .accent_hover = hex(0x2e6ec4),
    .on_accent = hex(0xffffff),
    .ok = hex(0x2ca02c),
    .warning = hex(0xd98200),
    .failure = hex(0xd62728),
    .plot = .{
        hex(0xd9480f), hex(0x1864ab), hex(0x2b8a3e), hex(0xc92a2a), hex(0x6741d9),
        hex(0x0b7285), hex(0xe67700), hex(0xa61e4d), hex(0x5c940d), hex(0x343a40),
    },
};

/// cor da curva `index` (dá a volta na paleta)
pub fn plotColor(index: usize) rl.Color {
    return colors.plot[index % colors.plot.len];
}


/// as fontes do sistema que servem (com acentos e letras gregas); sem nenhuma, a do raylib. As de `/fonts` são as que
/// vão no pacote do navegador (`aerosim/build.zig`, `webFiles`)
const regular_candidates = [_][:0]const u8{
    "/fonts/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
};
const bold_candidates = [_][:0]const u8{
    "/fonts/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
};
const mono_candidates = [_][:0]const u8{
    "/fonts/DejaVuSansMono.ttf",
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
    0x2082, 0x2264, 0x2265, 0x221E, 0x00B7, 0x2713, 0x2212, // ₂ ≤ ≥ ∞ · ✓ −
    0x2026, 0x2714, 0x2716, 0x24D8, 0x03B8, 0x03BC, // … ✔ ✖ ⓘ θ μ
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

/// a logo do albatroz, nas cores dela
pub const Logo = struct {
    texture: rl.Texture2D,

    const png = @embedFile("albatroz.png");

    /// carrega a logo; precisa da janela aberta
    pub fn load() !Logo {
        const image = try rl.loadImageFromMemory(".png", png);
        defer rl.unloadImage(image);
        var texture = try rl.loadTextureFromImage(image);
        // a logo sai em uns 80 px de 800: sem as reduções prontas (mipmaps), a imagem perde traços e o
        // "Aero Design" vira ruído
        rl.genTextureMipmaps(&texture);
        rl.setTextureFilter(texture, .trilinear);
        return .{ .texture = texture };
    }

    /// libera a textura
    pub fn deinit(logo: *Logo) void {
        rl.unloadTexture(logo.texture);
    }

    /// desenha a logo com altura `height`, o canto de cima à esquerda em (x, y); devolve a largura
    pub fn draw(logo: *const Logo, x: f32, y: f32, height: f32) f32 {
        const source_width: f32 = @floatFromInt(logo.texture.width);
        const source_height: f32 = @floatFromInt(logo.texture.height);
        const width = height * source_width / source_height;
        rl.drawTexturePro(logo.texture, .{ .x = 0, .y = 0, .width = source_width, .height = source_height }, .{ .x = x, .y = y, .width = width, .height = height }, .{ .x = 0, .y = 0 }, 0, .white);
        return width;
    }
};

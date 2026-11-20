//! O visual da interface, o mesmo do AeroDrive: cantos arredondados, uma cor de destaque e pouco texto. São dois
//! modos (`Mode`): o claro (o padrão), com fundo claro e tudo em azul, e o escuro, quase preto com o destaque em
//! laranja; nos dois o que está escolhido brilha de leve na cor do destaque (`glow`). Os gráficos não brilham.
//! Aqui ficam as cores, as fontes e a logo de cada programa (uma para o modo claro, outra para o escuro).
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
    glow: rl.Color, // o brilho em volta do que está escolhido (o destaque, transparente)
    note: rl.Color, // fundo das dicas e das legendas
    /// as cores das curvas, em ordem: 10 cores bem distintas no fundo do modo
    plot: [10]rl.Color,
};

/// o modo das cores
pub const Mode = enum { light, dark };

/// o modo claro, o do AeroDrive (`aerodrive/src/ui/theme.zig`): fundo claro e tudo em azul, com um brilho azulado
pub const light: Palette = .{
    .background = hex(0xf5f6fa),
    .panel = hex(0xe9ebf0),
    .selected = hex(0xdce9ff),
    .hover = hex(0xe8f0fd),
    .field = hex(0xffffff),
    .line = hex(0xcfd3db),
    .grid = hex(0xe3e7ee),
    .ink = hex(0x1d1f24),
    .label = hex(0x1d1f24),
    .muted = hex(0x6f747e),
    .accent = hex(0x0d5fd9),
    .accent_hover = hex(0x2b78ef),
    .on_accent = hex(0xffffff),
    .ok = hex(0x2ca02c),
    .warning = hex(0xd98200),
    .failure = hex(0xd62728),
    .glow = .{ .r = 0x0d, .g = 0x5f, .b = 0xd9, .a = 46 },
    .note = hex(0xf1f6ff),
    .plot = .{
        hex(0x0d5fd9), hex(0x2b8a3e), hex(0xae3ec9), hex(0xc92a2a), hex(0x0b7285),
        hex(0xe67700), hex(0x6741d9), hex(0xa61e4d), hex(0x5c940d), hex(0x343a40),
    },
};

/// o modo escuro: fundo quase preto, texto branco e o destaque em laranja, com brilho
pub const dark: Palette = .{
    .background = hex(0x0d0e11),
    .panel = hex(0x16181d),
    .selected = hex(0x2a1a0e),
    .hover = hex(0x22252c),
    .field = hex(0x1f2229),
    .line = hex(0x2c3038),
    .grid = hex(0x23262d),
    .ink = hex(0xeef0f3),
    .label = hex(0xd6d9df),
    .muted = hex(0x8b919c),
    .accent = hex(0xff7a1a),
    .accent_hover = hex(0xff9a4a),
    .on_accent = hex(0x111111),
    .ok = hex(0x51cf66),
    .warning = hex(0xfcc419),
    .failure = hex(0xff6b6b),
    .glow = .{ .r = 0xff, .g = 0x6e, .b = 0x14, .a = 70 },
    .note = hex(0x1c1f26),
    .plot = .{
        hex(0x4dabf7), hex(0xff922b), hex(0x69db7c), hex(0xff6b6b), hex(0xb197fc),
        hex(0x3bc9db), hex(0xffd43b), hex(0xf783ac), hex(0xa9e34b), hex(0xced4da),
    },
};

/// as cores em uso (as do modo escolhido por `setMode`)
pub var colors: Palette = light;
/// o modo em uso
pub var mode: Mode = .light;

/// troca o modo das cores (quem estiliza outra biblioteca, como o raygui, refaz o estilo: `widgets.Ui.setMode`)
pub fn setMode(chosen: Mode) void {
    mode = chosen;
    colors = switch (chosen) {
        .light => light,
        .dark => dark,
    };
}

/// `color` legível no fundo do modo: no escuro, uma cor escura (as fixas das curvas, como o azul-marinho) clareia
pub fn readable(color: rl.Color) rl.Color {
    if (mode == .light) return color;
    const luminance = (0.299 * @as(f32, @floatFromInt(color.r)) + 0.587 * @as(f32, @floatFromInt(color.g)) + 0.114 * @as(f32, @floatFromInt(color.b))) / 255;
    if (luminance >= 0.5) return color;
    return rl.colorLerp(color, hex(0xffffff), 0.5 - luminance + 0.15);
}

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
    0x2605, 0x2191, 0x2193, 0x2708, // ★ (o máximo de uma curva, na legenda) ↑ ↓ (mover a linha de uma tabela) ✈
    0x03B3, 0x03B6, 0x03BA, 0x03BD, 0x03BE, 0x03C0, 0x03C4, 0x03C6, // γ ζ κ ν ξ π τ φ (o TeX dos gráficos)
    0x03C7, 0x03C8, 0x03C9, 0x0393, 0x039B, 0x03A9, 0x2248, 0x2202, // χ ψ ω Γ Λ Ω ≈ ∂
};

/// tamanho da primeira carga de cada fonte; o texto sai de uma cópia no tamanho exato dele (`exact`)
const atlas_size = 28;

/// de onde uma fonte veio, para carregar de novo em outro tamanho
const Source = union(enum) { path: [:0]const u8, memory: []const u8 };

/// as fontes carregadas e de onde vieram (pela textura da primeira carga)
var sources: [8]struct { texture: u32, source: Source } = undefined;
var source_count: usize = 0;

/// as cópias em cada tamanho já pedido
var sized: [96]struct { texture: u32, pixels: i32, font: rl.Font } = undefined;
var sized_count: usize = 0;

fn remember(font: rl.Font, source: Source) void {
    if (source_count == sources.len) return;
    sources[source_count] = .{ .texture = font.texture.id, .source = source };
    source_count += 1;
}

/// a fonte desenhada no tamanho exato `pixels`, um pixel da textura para um da tela. Reduzir uma textura grande (48
/// ou 28 px para 12 a 16) apaga os traços finos e deixa as letras borradas ou comprimidas; o desenho no tamanho certo
/// sai como o sistema desenha. A cópia é feita na primeira vez e guardada; sem a origem (fonte padrão, navegador)
/// ou com a lista cheia, fica a fonte original
fn exact(font: rl.Font, pixels: i32) rl.Font {
    if (pixels < 6 or pixels > 96) return font;
    for (sized[0..sized_count]) |entry| {
        if (entry.texture == font.texture.id and entry.pixels == pixels) return entry.font;
    }
    if (sized_count == sized.len) return font;
    const source = for (sources[0..source_count]) |entry| {
        if (entry.texture == font.texture.id) break entry.source;
    } else return font;
    const cps = codepoints();
    const copy = switch (source) {
        .path => |path| rl.loadFontEx(path, pixels, &cps),
        .memory => |bytes| rl.loadFontFromMemory(".ttf", bytes, pixels, &cps),
    } catch return font;
    rl.setTextureFilter(copy.texture, .point);
    sized[sized_count] = .{ .texture = font.texture.id, .pixels = pixels, .font = copy };
    sized_count += 1;
    return copy;
}

fn loadFirst(paths: []const [:0]const u8, cps: []const i32) ?rl.Font {
    for (paths) |path| {
        if (!rl.fileExists(path)) continue;
        const font = rl.loadFontEx(path, atlas_size, cps) catch continue;
        rl.setTextureFilter(font.texture, .bilinear);
        remember(font, .{ .path = path });
        return font;
    }
    return null;
}

/// a Computer Modern (a fonte do LaTeX, na versão Unicode CMU; licença SIL OFL em `fonts/OFL.txt`), que vai dentro
/// do programa: a matemática dos gráficos (o que está entre `$`) sai nela, com as variáveis em itálico
const math_upright_file = @embedFile("fonts/cmunrm.ttf");
const math_italic_file = @embedFile("fonts/cmunti.ttf");

/// carrega as duas fontes da matemática e as entrega ao TeX dos gráficos; sem elas, a matemática fica na fonte do texto
fn loadMathFonts(cps: []const i32) void {
    const upright = rl.loadFontFromMemory(".ttf", math_upright_file, atlas_size, cps) catch return;
    const italic = rl.loadFontFromMemory(".ttf", math_italic_file, atlas_size, cps) catch {
        rl.unloadFont(upright);
        return;
    };
    rl.setTextureFilter(upright.texture, .bilinear);
    rl.setTextureFilter(italic.texture, .bilinear);
    remember(upright, .{ .memory = math_upright_file });
    remember(italic, .{ .memory = math_italic_file });
    @import("tex.zig").math_fonts = .{ .upright = upright, .italic = italic };
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
        loadMathFonts(&cps);
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
        for (sized[0..sized_count]) |entry| rl.unloadFont(entry.font);
        sized_count = 0;
        source_count = 0;
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
    const pixels = @round(size);
    rl.drawTextEx(exact(font, @intFromFloat(pixels)), content, .{ .x = @round(x), .y = @round(y) }, pixels, spacing(pixels), color);
}

/// largura de `text` em pixels
pub fn textWidth(font: rl.Font, content: [:0]const u8, size: f32) f32 {
    const pixels = @round(size);
    return rl.measureTextEx(exact(font, @intFromFloat(pixels)), content, pixels, spacing(pixels)).x;
}

/// os programas que têm logo própria (o nome é o título da janela)
pub const Program = enum { aerosim, aeroopt, aerodrive };

/// a logo do programa: o ícone de cantos redondos, numa versão para o modo claro e noutra para o escuro
pub const Logo = struct {
    light: rl.Texture2D,
    dark: rl.Texture2D,

    /// o brilho que passa pela logo a cada poucos segundos (o mesmo do nome do avião aberto); `brilho=nao` no print
    pub var shine: bool = true;

    /// o PNG da logo de `program`, no modo `chosen` (o ícone da janela usa o do escuro)
    pub fn png(program: Program, chosen: Mode) []const u8 {
        return switch (program) {
            .aerosim => if (chosen == .dark) @embedFile("logos/aerosim_escuro.png") else @embedFile("logos/aerosim_claro.png"),
            .aeroopt => if (chosen == .dark) @embedFile("logos/aeroopt_escuro.png") else @embedFile("logos/aeroopt_claro.png"),
            .aerodrive => if (chosen == .dark) @embedFile("logos/aerodrive_escuro.png") else @embedFile("logos/aerodrive_claro.png"),
        };
    }

    /// carrega as duas versões da logo de `program`; precisa da janela aberta
    pub fn load(program: Program) !Logo {
        return .{ .light = try texture(png(program, .light)), .dark = try texture(png(program, .dark)) };
    }

    fn texture(bytes: []const u8) !rl.Texture2D {
        const image = try rl.loadImageFromMemory(".png", bytes);
        defer rl.unloadImage(image);
        var loaded = try rl.loadTextureFromImage(image);
        // a logo sai em uns 40 px de 256: sem as reduções prontas (mipmaps), as linhas finas viram ruído
        rl.genTextureMipmaps(&loaded);
        rl.setTextureFilter(loaded, .trilinear);
        return loaded;
    }

    /// libera as texturas
    pub fn deinit(logo: *Logo) void {
        rl.unloadTexture(logo.light);
        rl.unloadTexture(logo.dark);
    }

    /// desenha a logo do modo atual com altura `height`, o canto de cima à esquerda em (x, y), com o brilho que
    /// passa em diagonal (`now`: o relógio da tela, em segundos); devolve a largura
    pub fn draw(logo: *const Logo, x: f32, y: f32, height: f32, now: f64) f32 {
        const shown = if (mode == .dark) logo.dark else logo.light;
        const source_width: f32 = @floatFromInt(shown.width);
        const source_height: f32 = @floatFromInt(shown.height);
        const width = height * source_width / source_height;
        rl.drawTexturePro(shown, .{ .x = 0, .y = 0, .width = source_width, .height = source_height }, .{ .x = x, .y = y, .width = width, .height = height }, .{ .x = 0, .y = 0 }, 0, .white);
        if (shine) {
            // uma faixa clara inclinada que atravessa o ícone no começo de cada período e some no resto
            const period: f64 = 3.2;
            const phase: f32 = @floatCast(@mod(now, period) / period);
            const band = height * 0.28;
            const center = x - band + phase * (width + 2 * band) * 1.6;
            rl.beginScissorMode(@intFromFloat(x + 3), @intFromFloat(y + 3), @intFromFloat(width - 6), @intFromFloat(height - 6));
            defer rl.endScissorMode();
            const layers = [_]struct { width: f32, alpha: f32 }{ .{ .width = 1.0, .alpha = 0.16 }, .{ .width = 0.55, .alpha = 0.26 }, .{ .width = 0.25, .alpha = 0.38 } };
            for (layers) |layer| {
                const strip: rl.Rectangle = .{ .x = center, .y = y + height / 2, .width = band * layer.width, .height = height * 1.8 };
                rl.drawRectanglePro(strip, .{ .x = strip.width / 2, .y = strip.height / 2 }, 22, rl.fade(.white, layer.alpha));
            }
        }
        return width;
    }
};

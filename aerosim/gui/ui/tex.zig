//! Um pedaço de TeX nos textos dos gráficos: o que fica entre `$...$` vira matemática, com índice (`C_L`,
//! `C_{m\alpha}`), expoente (`m^2`), letras gregas e símbolos (`\alpha`, `\delta_e`, `\times`, `\le`). Fora do `$`, o
//! texto sai como sempre. Não é o TeX inteiro: só o que um título, um eixo ou uma legenda precisam, e sem itálico
//! (a fonte da tela não tem). Um texto sem `$` sai igual ao de `theme.text`.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");

/// o tamanho do índice e do expoente em relação ao texto, e o menor tamanho que ainda se lê
const script_scale: f32 = 0.78;
const script_minimum: f32 = 9;

/// os operadores que ganham um espaço de cada lado, como no TeX (`C_L \times \alpha`, `C_m = 0`)
const binary_operators = [_][]const u8{ "times", "cdot", "le", "ge", "approx", "pm", "to", "=", "<", ">" };

const Symbol = struct { name: []const u8, text: [:0]const u8 };

/// os comandos que viram um caractere (os que as telas usam; a fonte carrega cada um em `theme.codepoints`)
const symbols = [_]Symbol{
    .{ .name = "alpha", .text = "α" },   .{ .name = "beta", .text = "β" },    .{ .name = "gamma", .text = "γ" },
    .{ .name = "delta", .text = "δ" },   .{ .name = "epsilon", .text = "ε" }, .{ .name = "varepsilon", .text = "ε" },
    .{ .name = "zeta", .text = "ζ" },    .{ .name = "eta", .text = "η" },     .{ .name = "theta", .text = "θ" },
    .{ .name = "kappa", .text = "κ" },   .{ .name = "lambda", .text = "λ" },  .{ .name = "mu", .text = "μ" },
    .{ .name = "nu", .text = "ν" },      .{ .name = "xi", .text = "ξ" },      .{ .name = "pi", .text = "π" },
    .{ .name = "rho", .text = "ρ" },     .{ .name = "sigma", .text = "σ" },   .{ .name = "tau", .text = "τ" },
    .{ .name = "phi", .text = "φ" },     .{ .name = "chi", .text = "χ" },     .{ .name = "psi", .text = "ψ" },
    .{ .name = "omega", .text = "ω" },   .{ .name = "Gamma", .text = "Γ" },   .{ .name = "Delta", .text = "Δ" },
    .{ .name = "Lambda", .text = "Λ" },  .{ .name = "Omega", .text = "Ω" },   .{ .name = "times", .text = "×" },
    .{ .name = "cdot", .text = "·" },    .{ .name = "le", .text = "≤" },      .{ .name = "ge", .text = "≥" },
    .{ .name = "approx", .text = "≈" },  .{ .name = "pm", .text = "±" },      .{ .name = "infty", .text = "∞" },
    .{ .name = "partial", .text = "∂" }, .{ .name = "to", .text = "→" },      .{ .name = "circ", .text = "°" },
    .{ .name = "%", .text = "%" },       .{ .name = ",", .text = " " },       .{ .name = " ", .text = " " },
    .{ .name = "_", .text = "_" },       .{ .name = "$", .text = "$" },
};

/// desenha `content` em (x, y), com o que estiver entre `$` como matemática; devolve a largura
pub fn draw(font: rl.Font, content: [:0]const u8, x: f32, y: f32, size: f32, color: rl.Color) f32 {
    if (std.mem.indexOfScalar(u8, content, '$') == null) {
        theme.text(font, content, x, y, size, color);
        return theme.textWidth(font, content, size);
    }
    var pen: Pen = .{ .font = font, .x = x, .color = color, .drawing = true };
    pen.line(content, y, size);
    return pen.x - x;
}

/// desenha `content` girado 90° (de baixo para cima, o rótulo do eixo y), começando em (x, y) embaixo
pub fn drawRotated(font: rl.Font, content: [:0]const u8, x: f32, y: f32, size: f32, color: rl.Color) void {
    if (std.mem.indexOfScalar(u8, content, '$') == null) {
        rl.drawTextPro(font, content, .{ .x = x, .y = y }, .{ .x = 0, .y = 0 }, -90, size, theme.spacing(size), color);
        return;
    }
    var pen: Pen = .{ .font = font, .x = y, .color = color, .drawing = true, .rotated = true };
    pen.line(content, x, size);
}

/// a largura de `content` como `draw` desenharia
pub fn width(font: rl.Font, content: [:0]const u8, size: f32) f32 {
    if (std.mem.indexOfScalar(u8, content, '$') == null) return theme.textWidth(font, content, size);
    var pen: Pen = .{ .font = font, .x = 0, .color = rl.Color.blank, .drawing = false };
    pen.line(content, 0, size);
    return pen.x;
}

/// `content` sem o TeX, para onde só cabe texto simples (o nome de uma coluna no CSV, um texto girado):
/// `$C_L \times \alpha$` → `C_L × α`
pub fn plain(content: []const u8, buffer: []u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < content.len and out < buffer.len) {
        const ch = content[i];
        if (ch == '$' or ch == '{' or ch == '}') {
            i += 1;
            continue;
        }
        if (ch == '\\') {
            const name = commandName(content, i + 1);
            i += 1 + name.len;
            const shown: []const u8 = if (lookup(name)) |s| s else name;
            const n = @min(shown.len, buffer.len - out);
            @memcpy(buffer[out..][0..n], shown[0..n]);
            out += n;
            continue;
        }
        buffer[out] = ch;
        out += 1;
        i += 1;
    }
    return buffer[0..out];
}

/// o "lápis" que anda da esquerda para a direita, desenhando ou só medindo
const Pen = struct {
    font: rl.Font,
    x: f32,
    color: rl.Color,
    drawing: bool,
    rotated: bool = false, // girado 90°: o lápis sobe (x é a altura na tela) e "para baixo" é para a direita

    /// a linha toda: texto comum fora do `$`, matemática dentro
    fn line(pen: *Pen, content: []const u8, y: f32, size: f32) void {
        var math = false;
        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '$') {
                math = !math;
                i += 1;
                continue;
            }
            if (!math) {
                const end = std.mem.indexOfScalarPos(u8, content, i, '$') orelse content.len;
                pen.run(content[i..end], y, size);
                i = end;
                continue;
            }
            i = pen.atom(content, i, y, size);
        }
    }

    /// um átomo da matemática a partir de `i` (um caractere, um comando, um grupo `{...}` com o índice e o
    /// expoente que vierem atrás); devolve onde parou
    fn atom(pen: *Pen, content: []const u8, start: usize, y: f32, size: f32) usize {
        var i = start;
        const ch = content[i];
        if (ch == '_' or ch == '^') {
            const script_size = @max(size * script_scale, @min(size, script_minimum));
            const shift = if (ch == '_') size * 0.42 else -size * 0.08;
            return pen.atom(content, i + 1, y + shift, script_size);
        }
        if (ch == '{') {
            i += 1;
            while (i < content.len and content[i] != '}' and content[i] != '$') i = pen.atom(content, i, y, size);
            return if (i < content.len and content[i] == '}') i + 1 else i;
        }
        if (ch == '}') return i + 1;
        if (ch == ' ') return i + 1; // na matemática o espaço não conta (como no TeX); `\,` é que dá espaço
        if (ch == '\\') {
            const name = commandName(content, i + 1);
            i += 1 + name.len;
            if (std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "text")) return i; // o grupo vem depois
            pen.operator(name, lookup(name) orelse name, y, size);
            return i;
        }
        const length = std.unicode.utf8ByteSequenceLength(ch) catch 1;
        const end = @min(content.len, i + length);
        pen.operator(content[i..end], content[i..end], y, size);
        return end;
    }

    /// um símbolo; se for um operador (`\times`, `=`), com um espaço de cada lado
    fn operator(pen: *Pen, name: []const u8, shown: []const u8, y: f32, size: f32) void {
        var binary = false;
        for (binary_operators) |op| binary = binary or std.mem.eql(u8, op, name);
        const gap = if (binary) size * 0.28 else 0;
        pen.advance(gap);
        pen.run(shown, y, size);
        pen.advance(gap);
    }

    fn advance(pen: *Pen, distance: f32) void {
        if (pen.rotated) pen.x -= distance else pen.x += distance;
    }

    /// um pedaço de texto simples no tamanho `size`, com a base no mesmo lugar do texto em volta
    fn run(pen: *Pen, piece: []const u8, y: f32, size: f32) void {
        if (piece.len == 0) return;
        var buffer: [256:0]u8 = undefined;
        const n = @min(piece.len, buffer.len);
        @memcpy(buffer[0..n], piece[0..n]);
        buffer[n] = 0;
        const text = buffer[0..n :0];
        const step = theme.textWidth(pen.font, text, size) + theme.spacing(size);
        if (pen.drawing and pen.rotated) {
            rl.drawTextPro(pen.font, text, .{ .x = y, .y = pen.x }, .{ .x = 0, .y = 0 }, -90, size, theme.spacing(size), pen.color);
        } else if (pen.drawing) theme.text(pen.font, text, pen.x, y, size, pen.color);
        pen.advance(step);
    }
};

/// o nome de um comando depois da barra: letras (`alpha`) ou um sinal só (`\,`, `\%`)
fn commandName(content: []const u8, start: usize) []const u8 {
    if (start >= content.len) return "";
    var end = start;
    while (end < content.len and std.ascii.isAlphabetic(content[end])) end += 1;
    return if (end > start) content[start..end] else content[start .. start + 1];
}

fn lookup(name: []const u8) ?[:0]const u8 {
    for (symbols) |s| if (std.mem.eql(u8, s.name, name)) return s.text;
    return null;
}

test "plain tira o TeX" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("C_L × α", plain("$C_L \\times \\alpha$", &buffer));
    try std.testing.expectEqualStrings("δ_e (°)", plain("$\\delta_e$ (°)", &buffer));
}

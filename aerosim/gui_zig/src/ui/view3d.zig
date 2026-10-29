//! Vista 3D dentro de um cartão, com as mesmas ideias da vista do aerosim em Python (`aerosim/gui/widgets/view3d.py`
//! e `load_view.py`): as superfícies na cor do tipo delas (asa azul, profundor verde, leme roxo...), sombreadas dos
//! dois lados por uma luz fixa, as arestas das faixas, os vetores de carga, o chão quadriculado e os eixos do corpo.
//! O 3D é desenhado numa textura do tamanho do cartão e colado na tela; arrastar com o mouse gira, a roda aproxima.
//!
//! As coordenadas que entram são as do corpo (x para a frente, y para a direita, z para baixo), em metros; a vista
//! converte para o raylib (y para cima).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

/// um ponto ou vetor no corpo (m)
pub const Body = [3]f64;

/// as cores de cada tipo de peça, as mesmas de `COLORS` em `aerosim/gui/widgets/view3d.py`
pub const Kind = enum { wing, htail, vtail, control, device, fuselage, boom, motor };

/// a cor de um tipo de peça
pub fn kindColor(kind: Kind) rl.Color {
    return switch (kind) {
        .wing => fraction(0.30, 0.55, 0.85),
        .htail => fraction(0.35, 0.70, 0.45),
        .vtail => fraction(0.55, 0.45, 0.80),
        .control => fraction(0.95, 0.65, 0.15),
        .device => fraction(0.20, 0.62, 0.62),
        .fuselage => fraction(0.75, 0.75, 0.78),
        .boom => fraction(0.40, 0.40, 0.42),
        .motor => fraction(0.85, 0.25, 0.25),
    };
}

/// cor a partir de frações de 0 a 1 (como no pyqtgraph)
pub fn fraction(red: f32, green: f32, blue: f32) rl.Color {
    return .{ .r = @intFromFloat(red * 255), .g = @intFromFloat(green * 255), .b = @intFromFloat(blue * 255), .a = 255 };
}

/// a cor da camada "sustentação" da vista de cargas (`aerosim/aero/span_loads.py`)
pub fn liftColor() rl.Color {
    return fraction(0.05, 0.45, 0.15);
}

/// corpo → raylib: x do raylib = y do corpo, y do raylib = −z (para cima), z do raylib = −x
pub fn toWorld(point: Body) rl.Vector3 {
    return .{ .x = @floatCast(point[1]), .y = @floatCast(-point[2]), .z = @floatCast(-point[0]) };
}

// a luz da vista em Python, (0.4, −0.5, 0.75) no OpenGL dela, que no corpo é (0.4, 0.5, −0.75)
const light: Body = .{ 0.4 / 0.98742, 0.5 / 0.98742, -0.75 / 0.98742 };

const max_labels = 8;

const Label = struct {
    position: rl.Vector3,
    text: [:0]const u8,
    color: rl.Color,
};

pub const View = struct {
    texture: ?rl.RenderTexture2D = null,
    azimuth: f32 = -130, // graus, como a câmera da vista em Python
    elevation: f32 = 22,
    zoom: f32 = 1,
    dragging: bool = false,
    camera: rl.Camera3D = undefined,
    labels: [max_labels]Label = undefined,
    label_count: usize = 0,

    /// libera a textura
    pub fn deinit(view: *View) void {
        if (view.texture) |texture| rl.unloadRenderTexture(texture);
        view.texture = null;
    }

    /// arrastar dentro de `rect` gira, a roda aproxima (e não rola a página); chamar antes de quem usa a roda
    pub fn handleInput(view: *View, ui: *widgets.Ui, rect: rl.Rectangle) void {
        if (ui.clicked and !ui.click_taken and ui.hovering(rect)) view.dragging = true;
        if (!rl.isMouseButtonDown(.left)) view.dragging = false;
        if (view.dragging) {
            const delta = rl.getMouseDelta();
            view.azimuth -= delta.x * 0.4;
            view.elevation = std.math.clamp(view.elevation + delta.y * 0.4, -85, 85);
        }
        if (ui.hovering(rect) and ui.wheel != 0) {
            view.zoom = std.math.clamp(view.zoom * std.math.pow(f32, 0.9, ui.wheel), 0.2, 5);
            ui.wheel = 0;
        }
    }

    /// começa a desenhar o 3D na textura do tamanho de `rect`, com a câmera olhando para `center` a uma distância
    /// que mostra uma cena de tamanho `size` (m); devolve falso se o retângulo é pequeno demais
    pub fn begin(view: *View, rect: rl.Rectangle, center: Body, size: f64) bool {
        const width: i32 = @intFromFloat(@max(rect.width, 0));
        const height: i32 = @intFromFloat(@max(rect.height, 0));
        if (width < 8 or height < 8) return false;
        if (view.texture) |texture| {
            if (texture.texture.width != width or texture.texture.height != height) view.deinit();
        }
        if (view.texture == null) view.texture = rl.loadRenderTexture(width, height) catch return false;
        // a câmera na direção (azimute, elevação) do OpenGL da vista em Python, passada para o corpo
        const azimuth = std.math.degreesToRadians(view.azimuth);
        const elevation = std.math.degreesToRadians(view.elevation);
        const direction: Body = .{ @cos(elevation) * @cos(azimuth), -@cos(elevation) * @sin(azimuth), -@sin(elevation) };
        const distance = 1.25 * size * view.zoom;
        const target = toWorld(center);
        const offset = toWorld(.{ direction[0] * distance, direction[1] * distance, direction[2] * distance });
        view.camera = .{
            .position = .{ .x = target.x + offset.x, .y = target.y + offset.y, .z = target.z + offset.z },
            .target = target,
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .fovy = 35,
            .projection = .perspective,
        };
        view.label_count = 0;
        rl.beginTextureMode(view.texture.?);
        rl.clearBackground(theme.colors.background); // o fundo do 3D da GUI e do AeroDrive
        rl.beginMode3D(view.camera);
        return true;
    }

    /// termina o 3D (depois de `begin`)
    pub fn end(view: *View) void {
        _ = view;
        rl.endMode3D();
        rl.endTextureMode();
    }

    /// guarda um texto preso a um ponto do 3D (escrito por cima em `blit`)
    pub fn label(view: *View, position: Body, text: [:0]const u8, color: rl.Color) void {
        if (view.label_count == max_labels) return;
        view.labels[view.label_count] = .{ .position = toWorld(position), .text = text, .color = color };
        view.label_count += 1;
    }

    /// cola a imagem em `rect` e escreve os textos
    pub fn blit(view: *const View, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const target = view.texture orelse return;
        const texture = target.texture;
        rl.drawTextureRec(texture, .{ .x = 0, .y = 0, .width = @floatFromInt(texture.width), .height = @floatFromInt(-texture.height) }, .{ .x = rect.x, .y = rect.y }, .white);
        for (view.labels[0..view.label_count]) |item| {
            const at = rl.getWorldToScreenEx(item.position, view.camera, texture.width, texture.height);
            theme.text(ui.fonts.regular, item.text, rect.x + at.x, rect.y + at.y - 7, 13, item.color);
        }
    }
};

fn subtract(a: Body, b: Body) Body {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross(a: Body, b: Body) Body {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn scaled(color: rl.Color, factor: f64) rl.Color {
    const f: f32 = @floatCast(@min(factor, 1));
    return .{ .r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * f), .g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * f), .b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * f), .a = color.a };
}

/// a cor de um triângulo com a sombra da vista em Python: cor × (0,45 + 0,6 |n·luz|)
pub fn shaded(a: Body, b: Body, c: Body, color: rl.Color) rl.Color {
    const normal = cross(subtract(b, a), subtract(c, a));
    const length = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
    const facing = if (length > 0) @abs(normal[0] * light[0] + normal[1] * light[1] + normal[2] * light[2]) / length else 1;
    return scaled(color, 0.45 + 0.6 * facing);
}

/// triângulo já sombreado, visto dos dois lados
pub fn triangle(a: Body, b: Body, c: Body, color: rl.Color) void {
    const wa = toWorld(a);
    const wb = toWorld(b);
    const wc = toWorld(c);
    rl.drawTriangle3D(wa, wb, wc, color);
    rl.drawTriangle3D(wa, wc, wb, color);
}

/// quadrilátero plano `a b c d` sombreado dos dois lados como no shader `aero_twosided` da vista em Python:
/// cor × (0,45 + 0,6 |n·luz|)
pub fn quad(a: Body, b: Body, c: Body, d: Body, color: rl.Color) void {
    const normal = cross(subtract(c, a), subtract(d, b));
    const length = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
    const facing = if (length > 0) @abs(normal[0] * light[0] + normal[1] * light[1] + normal[2] * light[2]) / length else 1;
    const shade = scaled(color, 0.45 + 0.6 * facing);
    const wa = toWorld(a);
    const wb = toWorld(b);
    const wc = toWorld(c);
    const wd = toWorld(d);
    // as duas faces (o raylib descarta a de trás)
    rl.drawTriangle3D(wa, wb, wc, shade);
    rl.drawTriangle3D(wa, wc, wd, shade);
    rl.drawTriangle3D(wa, wc, wb, shade);
    rl.drawTriangle3D(wa, wd, wc, shade);
}

/// segmento fino (aresta de faixa, grade)
pub fn segment(a: Body, b: Body, color: rl.Color) void {
    rl.drawLine3D(toWorld(a), toWorld(b), color);
}

/// vetor de `origin` a `origin + vector`, com haste e ponta em cone de comprimento `head` (m)
pub fn arrow(origin: Body, vector: Body, head: f64, color: rl.Color) void {
    const length = @sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
    if (length < 1e-9) return;
    const tip: Body = .{ origin[0] + vector[0], origin[1] + vector[1], origin[2] + vector[2] };
    const cone = @min(head, length);
    const neck: Body = .{ tip[0] - vector[0] / length * cone, tip[1] - vector[1] / length * cone, tip[2] - vector[2] / length * cone };
    const radius: f32 = @floatCast(head * 0.12);
    rl.drawCylinderEx(toWorld(origin), toWorld(neck), radius, radius, 6, color);
    rl.drawCylinderEx(toWorld(neck), toWorld(tip), @floatCast(head * 0.35), 0, 10, color);
}

/// o chão quadriculado na altura `z` (corpo), de lado `size` e passo `step`, centrado em (x, y)
pub fn floor(center: Body, z: f64, size: f64, step: f64) void {
    const color = theme.withAlpha(theme.colors.ink, 0.16);
    const count: usize = @intFromFloat(@ceil(size / step));
    const half = @as(f64, @floatFromInt(count)) * step / 2;
    for (0..count + 1) |i| {
        const offset = -half + @as(f64, @floatFromInt(i)) * step;
        segment(.{ center[0] + offset, center[1] - half, z }, .{ center[0] + offset, center[1] + half, z }, color);
        segment(.{ center[0] - half, center[1] + offset, z }, .{ center[0] + half, center[1] + offset, z }, color);
    }
}

/// os eixos do corpo em `origin` (frente +x em vermelho, direita +y em verde, cima em azul), como na vista em Python
pub fn bodyAxes(view: *View, origin: Body, length: f64) void {
    const axes = [_]struct { direction: Body, name: [:0]const u8, color: rl.Color }{
        .{ .direction = .{ 1, 0, 0 }, .name = "frente (+x)", .color = fraction(0.80, 0.10, 0.10) },
        .{ .direction = .{ 0, 1, 0 }, .name = "direita (+y)", .color = fraction(0.10, 0.55, 0.10) },
        .{ .direction = .{ 0, 0, -1 }, .name = "cima", .color = fraction(0.10, 0.25, 0.85) },
    };
    for (axes) |axis| {
        const vector: Body = .{ axis.direction[0] * length, axis.direction[1] * length, axis.direction[2] * length };
        arrow(origin, vector, length * 0.22, axis.color);
        view.label(.{ origin[0] + 1.2 * vector[0], origin[1] + 1.2 * vector[1], origin[2] + 1.2 * vector[2] }, axis.name, axis.color);
    }
}

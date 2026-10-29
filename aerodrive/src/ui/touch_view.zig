//! Desenha os controles por toque (`input/touch.zig`) sobre o voo: os dois manches com a bolinha
//! onde o dedo está, a marca do acelerador e os botões de pausa e câmera.
const std = @import("std");
const rl = @import("raylib");
const touch = @import("../input/touch.zig");
const theme = @import("theme.zig");

const ring: rl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 150 };
const fill: rl.Color = .{ .r = 20, .g = 40, .b = 80, .a = 70 };
const knob: rl.Color = .{ .r = 255, .g = 255, .b = 255, .a = 200 };
const pressed_fill: rl.Color = .{ .r = 242, .g = 166, .b = 38, .a = 200 };

/// manches e botões na posição de `touch.layout` para a tela atual
pub fn draw(fonts: *const theme.Fonts, state: touch.State) void {
    const area = touch.layout(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()));
    drawStick(fonts, area.left, state.left_knob, "motor · leme");
    drawStick(fonts, area.right, state.right_knob, "arfagem · rolagem");
    // acelerador: a altura da bolinha fica; uma barra ao lado mostra quanto
    const left = area.left;
    const bar: rl.Rectangle = .{ .x = left.center.x + left.radius + 10, .y = left.center.y - left.radius, .width = 8, .height = 2 * left.radius };
    rl.drawRectangleRec(bar, fill);
    const level: f32 = @floatCast(std.math.clamp(state.throttle, 0, 1));
    rl.drawRectangleRec(.{ .x = bar.x, .y = bar.y + bar.height * (1 - level), .width = bar.width, .height = bar.height * level }, theme.accent);

    const labels = std.EnumArray(touch.Button, [:0]const u8).init(.{ .pause = "pausa", .camera = "câmera" });
    for (std.enums.values(touch.Button)) |button| {
        const spot = area.buttons.get(button);
        const center: rl.Vector2 = .{ .x = spot.center.x, .y = spot.center.y };
        rl.drawCircleV(center, spot.radius, if (state.held.contains(button)) pressed_fill else fill);
        rl.drawRing(center, spot.radius - 2, spot.radius, 0, 360, 48, ring);
        const label = labels.get(button);
        const size = @max(12, 0.32 * spot.radius);
        fonts.draw(label, center.x - 0.5 * fonts.width(label, size), center.y - 0.5 * size, size, .white);
    }
}

fn drawStick(fonts: *const theme.Fonts, stick: touch.Stick, position: touch.Point, label: [:0]const u8) void {
    const center: rl.Vector2 = .{ .x = stick.center.x, .y = stick.center.y };
    rl.drawCircleV(center, stick.radius, fill);
    rl.drawRing(center, stick.radius - 2, stick.radius, 0, 360, 64, ring);
    rl.drawLineEx(.{ .x = center.x - stick.radius, .y = center.y }, .{ .x = center.x + stick.radius, .y = center.y }, 1, ring);
    rl.drawLineEx(.{ .x = center.x, .y = center.y - stick.radius }, .{ .x = center.x, .y = center.y + stick.radius }, 1, ring);
    const knob_radius = 0.32 * stick.radius;
    rl.drawCircleV(.{ .x = center.x + position.x * stick.radius, .y = center.y + position.y * stick.radius }, knob_radius, knob);
    const size = @max(12, 0.16 * stick.radius);
    fonts.draw(label, center.x - 0.5 * fonts.width(label, size), center.y - stick.radius - size - 6, size, .white);
}

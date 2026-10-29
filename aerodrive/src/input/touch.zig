//! Controles por toque (celular, tablet): dois manches virtuais e dois botões, desenhados sobre o
//! voo (`ui/touch_view.zig`). Só a conta fica aqui (sem raylib): onde cada peça fica na tela e o
//! que os dedos fazem com ela. O resultado entra nos mesmos canais do teclado (`channels.Raw`,
//! campos `key_*`), então vale em qualquer esquema de controle.
//!
//!   manche esquerdo   acelerador (para cima = mais; fica onde o dedo deixou) e leme (volta ao centro)
//!   manche direito    arfagem (para baixo = puxar) e rolagem (voltam ao centro)   — como no rádio modo 2
//!   botões            pausa e câmera, no alto, entre o painel e o minimapa
//!
//!   var controls: touch.Controls = .{};
//!   const state = controls.update(touch.layout(largura, altura), dedos);   // dedos: []const Point
//!   raw.key_elev = state.elevator;  ...;  if (state.pressed(.pause)) ...
const std = @import("std");
const fuzz = @import("../util/fuzz.zig");

pub const Point = struct { x: f32, y: f32 };

pub const Stick = struct {
    center: Point,
    radius: f32,
};

pub const Button = enum { pause, camera };

pub const ButtonArea = struct {
    center: Point,
    radius: f32,
};

pub const Layout = struct {
    left: Stick,
    right: Stick,
    buttons: std.EnumArray(Button, ButtonArea),
};

/// onde fica cada peça numa tela `width` × `height`: manches nos cantos de baixo, botões no alto
pub fn layout(width: f32, height: f32) Layout {
    const short_side = @max(1, @min(width, height));
    const radius = 0.17 * short_side;
    const margin = 0.08 * short_side;
    const stick_y = height - radius - margin;
    const button_radius = 0.07 * short_side;
    const button_y = 0.11 * short_side + button_radius;
    return .{
        .left = .{ .center = .{ .x = margin + radius, .y = stick_y }, .radius = radius },
        .right = .{ .center = .{ .x = width - margin - radius, .y = stick_y }, .radius = radius },
        .buttons = .init(.{
            .pause = .{ .center = .{ .x = 0.5 * width - 2.2 * button_radius, .y = button_y }, .radius = button_radius },
            .camera = .{ .center = .{ .x = 0.5 * width + 2.2 * button_radius, .y = button_y }, .radius = button_radius },
        }),
    };
}

/// o que os dedos pedem neste quadro (−1..1 nos canais centrados; acelerador 0..1)
pub const State = struct {
    elevator: f64 = 0, // + = puxar (como `channels.Raw.key_elev`)
    aileron: f64 = 0,
    rudder: f64 = 0,
    throttle: f64 = 0,
    left_knob: Point = .{ .x = 0, .y = 0 }, // posição da bolinha de cada manche (−1..1), para desenhar
    right_knob: Point = .{ .x = 0, .y = 0 },
    held: std.EnumSet(Button) = .initEmpty(),
    just_pressed: std.EnumSet(Button) = .initEmpty(),

    /// o botão foi tocado agora (não estava no quadro anterior)
    pub fn pressed(state: State, button: Button) bool {
        return state.just_pressed.contains(button);
    }
};

pub const Controls = struct {
    throttle: f64 = 0, // o acelerador fica onde o dedo deixou
    held_before: std.EnumSet(Button) = .initEmpty(),

    /// lê os dedos: cada manche segue o dedo mais perto dentro da sua metade da tela (fora dos botões)
    pub fn update(controls: *Controls, area: Layout, fingers: []const Point) State {
        var state: State = .{};
        var left_finger: ?Point = null;
        var right_finger: ?Point = null;
        var left_distance = std.math.inf(f32);
        var right_distance = std.math.inf(f32);
        const middle = 0.5 * (area.left.center.x + area.right.center.x);
        fingers: for (fingers) |finger| {
            if (!std.math.isFinite(finger.x) or !std.math.isFinite(finger.y)) continue;
            for (std.enums.values(Button)) |button| {
                const spot = area.buttons.get(button);
                if (distance(finger, spot.center) <= 1.3 * spot.radius) {
                    state.held.insert(button);
                    continue :fingers;
                }
            }
            if (finger.x < middle) {
                const finger_distance = distance(finger, area.left.center);
                if (finger_distance < left_distance) {
                    left_distance = finger_distance;
                    left_finger = finger;
                }
            } else {
                const finger_distance = distance(finger, area.right.center);
                if (finger_distance < right_distance) {
                    right_distance = finger_distance;
                    right_finger = finger;
                }
            }
        }
        if (left_finger) |finger| {
            const knob = offset(area.left, finger);
            controls.throttle = std.math.clamp(0.5 - 0.5 * knob.y, 0, 1);
            state.rudder = knob.x;
        }
        state.left_knob = .{ .x = @floatCast(state.rudder), .y = @floatCast(1 - 2 * controls.throttle) };
        if (right_finger) |finger| {
            const knob = offset(area.right, finger);
            state.aileron = knob.x;
            state.elevator = knob.y;
            state.right_knob = .{ .x = @floatCast(knob.x), .y = @floatCast(knob.y) };
        }
        state.throttle = controls.throttle;
        var fresh = state.held;
        fresh.setIntersection(controls.held_before.complement());
        state.just_pressed = fresh;
        controls.held_before = state.held;
        return state;
    }
};

/// onde o dedo está em relação ao manche, dentro do círculo de raio 1 (x para a direita, y para baixo)
fn offset(stick: Stick, finger: Point) struct { x: f64, y: f64 } {
    var x: f64 = (finger.x - stick.center.x) / stick.radius;
    var y: f64 = (finger.y - stick.center.y) / stick.radius;
    const length = @sqrt(x * x + y * y);
    if (length > 1) {
        x /= length;
        y /= length;
    }
    return .{ .x = x, .y = y };
}

fn distance(a: Point, b: Point) f32 {
    return std.math.hypot(a.x - b.x, a.y - b.y);
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "manche direito: puxar e rolar; solto volta ao centro" {
    const area = layout(1280, 600);
    var controls: Controls = .{};
    const right = area.right;
    var state = controls.update(area, &.{.{ .x = right.center.x + right.radius, .y = right.center.y + right.radius }});
    try testing.expectApproxEqAbs(@as(f64, std.math.sqrt1_2), state.aileron, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, std.math.sqrt1_2), state.elevator, 1e-6); // para baixo = puxar
    state = controls.update(area, &.{});
    try testing.expectEqual(@as(f64, 0), state.aileron);
    try testing.expectEqual(@as(f64, 0), state.elevator);
}

test "acelerador fica onde o dedo deixou; leme volta ao centro" {
    const area = layout(1280, 600);
    var controls: Controls = .{};
    const left = area.left;
    var state = controls.update(area, &.{.{ .x = left.center.x + 0.5 * left.radius, .y = left.center.y - 0.5 * left.radius }});
    try testing.expectApproxEqAbs(@as(f64, 0.75), state.throttle, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.5), state.rudder, 1e-6);
    state = controls.update(area, &.{});
    try testing.expectApproxEqAbs(@as(f64, 0.75), state.throttle, 1e-6);
    try testing.expectEqual(@as(f64, 0), state.rudder);
}

test "botão conta uma vez por toque e não mexe nos manches" {
    const area = layout(844, 390);
    var controls: Controls = .{};
    const pause = area.buttons.get(.pause).center;
    var state = controls.update(area, &.{pause});
    try testing.expect(state.pressed(.pause) and !state.pressed(.camera));
    try testing.expectEqual(@as(f64, 0), state.rudder);
    state = controls.update(area, &.{pause});
    try testing.expect(!state.pressed(.pause) and state.held.contains(.pause));
    state = controls.update(area, &.{});
    state = controls.update(area, &.{pause});
    try testing.expect(state.pressed(.pause));
}

test "as peças cabem num celular deitado sem se sobrepor" {
    for ([_][2]f32{ .{ 844, 390 }, .{ 1280, 591 }, .{ 640, 360 } }) |size| {
        const area = layout(size[0], size[1]);
        try testing.expect(area.left.center.x - area.left.radius >= 0 and area.right.center.x + area.right.radius <= size[0]);
        try testing.expect(area.left.center.y + area.left.radius <= size[1]);
        try testing.expect(area.left.center.x + area.left.radius < area.right.center.x - area.right.radius);
        const pause = area.buttons.get(.pause);
        try testing.expect(pause.center.y + pause.radius < area.left.center.y - area.left.radius);
    }
}

fn fuzzControls(_: void, source: *fuzz.Src) anyerror!void {
    var controls: Controls = .{};
    const area = layout(@floatCast(source.range(1, 4000)), @floatCast(source.range(1, 4000)));
    var fingers: [6]Point = undefined;
    for (0..8) |_| {
        const count: usize = source.int(u8, 0, fingers.len);
        for (fingers[0..count]) |*finger| finger.* = .{ .x = @floatCast(source.mostly(-100, 5000)), .y = @floatCast(source.mostly(-100, 5000)) };
        const state = controls.update(area, fingers[0..count]);
        for ([_]f64{ state.elevator, state.aileron, state.rudder }) |value| try testing.expect(value >= -1 and value <= 1);
        try testing.expect(state.throttle >= 0 and state.throttle <= 1);
    }
}

test "fuzz: toque" {
    try fuzz.check({}, fuzzControls, .{});
}

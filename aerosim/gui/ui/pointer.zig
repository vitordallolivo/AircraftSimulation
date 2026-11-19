//! O ponteiro das telas, igual no PC e no celular: o mouse ou o dedo viram as mesmas coisas (desceu, segura,
//! clicou, arrastou, passou de lado). Só a conta fica aqui, sem raylib, como os manches do AeroDrive
//! (`aerodrive/src/input/touch.zig`): quem lê a entrada (`widgets.Ui.beginFrame`) passa o que o raylib diz e usa o
//! resultado. Assim o aerosim e o aeroopt tratam o toque do mesmo jeito.
//!
//!   mouse   o clique vale ao descer (como sempre foi no PC)
//!   dedo    o raylib move o mouse com o dedo mas não aperta o botão; o toque vale como clique ao soltar, se o
//!           dedo quase não andou. Andando, ele arrasta (rola a área onde desceu); solto andando mais de lado que
//!           de pé, é a passada (trocar de gráfico)
//!
//!   var pointer: Pointer = .{};
//!   const now = pointer.update(.{ .mouse = posição, .mouse_pressed = ..., .mouse_down = ..., .finger = dedo_ou_null });
//!   if (now.clicked) ...;  if (now.dragging) rolar(now.delta.y);
const std = @import("std");

pub const Point = struct { x: f32 = 0, y: f32 = 0 };

/// quanto o dedo pode andar e ainda valer como toque (acima disso é arraste)
pub const slop: f32 = 10;
/// o menor caminho de lado que vale como passada
pub const swipe_distance: f32 = 48;

/// o que a plataforma diz neste quadro
pub const Input = struct {
    mouse: Point = .{},
    mouse_pressed: bool = false,
    mouse_down: bool = false,
    finger: ?Point = null, // o primeiro dedo na tela, se houver
};

/// o ponteiro neste quadro
pub const Frame = struct {
    at: Point = .{}, // onde está (o dedo solto fica onde saiu)
    clicked: bool = false,
    held: bool = false,
    pressed: bool = false, // desceu neste quadro
    press_point: Point = .{}, // onde desceu
    delta: Point = .{}, // quanto andou neste quadro, segurando
    dragging: bool = false, // desde que desceu, andou mais que a folga do toque
    swipe: f32 = 0, // ao soltar uma passada: quanto andou de lado (negativo: para a esquerda)
    touch: bool = false, // o último gesto veio do dedo
};

/// o estado entre os quadros
pub const Pointer = struct {
    touch: bool = false,
    finger_down: bool = false,
    last: Point = .{},
    press_point: Point = .{},
    dragging: bool = false,

    /// lê um quadro
    pub fn update(pointer: *Pointer, input: Input) Frame {
        if (input.finger) |point| {
            var frame: Frame = .{ .at = point, .held = true, .touch = true };
            if (!pointer.finger_down) {
                pointer.finger_down = true;
                pointer.press_point = point;
                pointer.last = point;
                pointer.dragging = false;
                frame.pressed = true;
            }
            frame.delta = .{ .x = point.x - pointer.last.x, .y = point.y - pointer.last.y };
            pointer.last = point;
            if (@abs(point.x - pointer.press_point.x) + @abs(point.y - pointer.press_point.y) > slop) pointer.dragging = true;
            pointer.touch = true;
            frame.dragging = pointer.dragging;
            frame.press_point = pointer.press_point;
            return frame;
        }
        if (pointer.finger_down) {
            // soltou o dedo: parado é clique; andando de lado, passada
            pointer.finger_down = false;
            var frame: Frame = .{ .at = pointer.last, .touch = true, .press_point = pointer.press_point, .dragging = pointer.dragging };
            const across = pointer.last.x - pointer.press_point.x;
            const along = pointer.last.y - pointer.press_point.y;
            if (!pointer.dragging) frame.clicked = true else if (@abs(across) > swipe_distance and @abs(across) > 1.5 * @abs(along)) frame.swipe = across;
            return frame;
        }
        // o mouse: um clique de verdade tira do jeito toque
        if (input.mouse_pressed) {
            pointer.touch = false;
            pointer.press_point = input.mouse;
            pointer.dragging = false;
        }
        if (input.mouse_down and @abs(input.mouse.x - pointer.press_point.x) + @abs(input.mouse.y - pointer.press_point.y) > slop) pointer.dragging = true;
        const at = if (pointer.touch) pointer.last else input.mouse;
        const frame: Frame = .{
            .at = at,
            .clicked = input.mouse_pressed,
            .held = input.mouse_down,
            .pressed = input.mouse_pressed,
            .press_point = pointer.press_point,
            .delta = if (input.mouse_down) .{ .x = input.mouse.x - pointer.last.x, .y = input.mouse.y - pointer.last.y } else .{},
            .dragging = input.mouse_down and pointer.dragging,
            .touch = pointer.touch,
        };
        if (!pointer.touch) pointer.last = input.mouse;
        return frame;
    }
};

test "toque parado é clique ao soltar" {
    var pointer: Pointer = .{};
    const down = pointer.update(.{ .finger = .{ .x = 100, .y = 200 } });
    try std.testing.expect(down.pressed and down.held and !down.clicked and down.touch);
    _ = pointer.update(.{ .finger = .{ .x = 103, .y = 202 } }); // tremida dentro da folga
    const up = pointer.update(.{});
    try std.testing.expect(up.clicked and !up.held);
    try std.testing.expectEqual(@as(f32, 103), up.at.x);
}

test "arraste rola e não clica" {
    var pointer: Pointer = .{};
    _ = pointer.update(.{ .finger = .{ .x = 100, .y = 300 } });
    const moving = pointer.update(.{ .finger = .{ .x = 100, .y = 260 } });
    try std.testing.expect(moving.dragging);
    try std.testing.expectEqual(@as(f32, -40), moving.delta.y);
    const up = pointer.update(.{});
    try std.testing.expect(!up.clicked and up.swipe == 0);
}

test "passada de lado ao soltar" {
    var pointer: Pointer = .{};
    _ = pointer.update(.{ .finger = .{ .x = 300, .y = 300 } });
    _ = pointer.update(.{ .finger = .{ .x = 200, .y = 310 } });
    const up = pointer.update(.{});
    try std.testing.expectEqual(@as(f32, -100), up.swipe);
}

test "mouse clica ao descer e sai do jeito toque" {
    var pointer: Pointer = .{};
    _ = pointer.update(.{ .finger = .{ .x = 10, .y = 10 } });
    _ = pointer.update(.{});
    const click = pointer.update(.{ .mouse = .{ .x = 50, .y = 60 }, .mouse_pressed = true, .mouse_down = true });
    try std.testing.expect(click.clicked and click.pressed and !click.touch);
    try std.testing.expectEqual(@as(f32, 50), click.at.x);
}

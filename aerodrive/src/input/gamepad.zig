//! Leitura do controle e do teclado (raylib) → entrada bruta dos canais + botões de ação do voo.
//! As contas (curvas, rampa do aileron) ficam em `channels.zig`; aqui só o que está apertado.
//!
//!   controle                         teclado
//!   analógico esq.  profundor/leme   setas ↑↓ / A D
//!   LB / RB         aileron          setas ← →
//!   RT              motor            W / S (sobe e desce devagar)
//!   Start           pausa            Esc ou P
//!   Y               manual ⇄ auto    M
//!   X               solta o LAPES    L
//!   Back (View)     grava / para     G
//!   B               troca a câmera   C
//!   (painel F3: tecla F3)
const std = @import("std");
const rl = @import("raylib");
const ch = @import("channels.zig");

pub const Actions = struct {
    pause: bool = false,
    toggle_mode: bool = false,
    drop: bool = false,
    record: bool = false,
    camera: bool = false,
    dev: bool = false,
};

pub const Reader = struct {
    thr_key: f64 = 0, // acelerador pelo teclado (W/S)
    pad_seen: bool = false,

    /// estado bruto dos canais neste quadro
    pub fn raw(r: *Reader, dt: f64) ch.Raw {
        var out: ch.Raw = .{};
        if (rl.isGamepadAvailable(0)) {
            r.pad_seen = true;
            out.stick_x = rl.getGamepadAxisMovement(0, .left_x);
            out.stick_y = rl.getGamepadAxisMovement(0, .left_y);
            out.rt = 0.5 * (rl.getGamepadAxisMovement(0, .right_trigger) + 1);
            out.lb = rl.isGamepadButtonDown(0, .left_trigger_1);
            out.rb = rl.isGamepadButtonDown(0, .right_trigger_1);
        }
        if (rl.isKeyDown(.down)) out.stick_y = 1;
        if (rl.isKeyDown(.up)) out.stick_y = -1;
        if (rl.isKeyDown(.a)) out.stick_x = -1;
        if (rl.isKeyDown(.d)) out.stick_x = 1;
        out.lb = out.lb or rl.isKeyDown(.left);
        out.rb = out.rb or rl.isKeyDown(.right);
        if (rl.isKeyDown(.w)) r.thr_key = @min(1, r.thr_key + 0.6 * dt);
        if (rl.isKeyDown(.s)) r.thr_key = @max(0, r.thr_key - 0.6 * dt);
        out.rt = @max(out.rt, r.thr_key);
        return out;
    }

    pub fn actions(_: *const Reader) Actions {
        const pad = rl.isGamepadAvailable(0);
        const b = struct {
            fn f(p: bool, btn: rl.GamepadButton) bool {
                return p and rl.isGamepadButtonPressed(0, btn);
            }
        }.f;
        return .{
            .pause = rl.isKeyPressed(.escape) or rl.isKeyPressed(.p) or b(pad, .middle_right),
            .toggle_mode = rl.isKeyPressed(.m) or b(pad, .right_face_up),
            .drop = rl.isKeyPressed(.l) or b(pad, .right_face_left),
            .record = rl.isKeyPressed(.g) or b(pad, .middle_left),
            .camera = rl.isKeyPressed(.c) or b(pad, .right_face_right),
            .dev = rl.isKeyPressed(.f3),
        };
    }
};

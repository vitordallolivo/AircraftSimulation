//! Leitura do controle e do teclado (raylib) → o que está apertado (`channels.Raw`) + botões de
//! ação do voo. Qual eixo faz o quê depende do esquema (`channels.Scheme`); as curvas ficam em
//! `channels.zig`. Os botões de ação vêm de `ch.Bindings` (menu Controle):
//!
//!   botão (padrão, remapeável)  teclado    faz
//!   Start                       Esc / P    pausa
//!   Y                           M          manual ⇄ automático
//!   X                           L          solta o LAPES
//!   Back (View)                 G          grava / para
//!   B                           C          troca a câmera
//!   direcional ↑                R          recomeça
//!   —                           F3         painel de desempenho
//!
//! Teclado nos comandos: setas ↑↓ profundor, ← → aileron, A/D leme, W/S motor.
const std = @import("std");
const rl = @import("raylib");
const ch = @import("channels.zig");

pub const Actions = struct {
    pause: bool = false,
    toggle_mode: bool = false,
    drop: bool = false,
    record: bool = false,
    camera: bool = false,
    restart: bool = false,
    dev: bool = false,
};

pub const Reader = struct {
    thr_key: ?f64 = null, // acelerador pelo teclado (W/S); null até a primeira tecla

    /// estado bruto (eixos do controle + teclado) neste quadro
    pub fn raw(r: *Reader, dt: f64) ch.Raw {
        var out: ch.Raw = .{};
        if (rl.isGamepadAvailable(0)) {
            out.lx = rl.getGamepadAxisMovement(0, .left_x);
            out.ly = rl.getGamepadAxisMovement(0, .left_y);
            out.rx = rl.getGamepadAxisMovement(0, .right_x);
            out.ry = rl.getGamepadAxisMovement(0, .right_y);
            out.rt = 0.5 * (rl.getGamepadAxisMovement(0, .right_trigger) + 1);
            out.lt = 0.5 * (rl.getGamepadAxisMovement(0, .left_trigger) + 1);
            out.lb = rl.isGamepadButtonDown(0, .left_trigger_1);
            out.rb = rl.isGamepadButtonDown(0, .right_trigger_1);
        }
        if (rl.isKeyDown(.down)) out.key_elev = 1;
        if (rl.isKeyDown(.up)) out.key_elev = -1;
        if (rl.isKeyDown(.left)) out.key_ail = -1;
        if (rl.isKeyDown(.right)) out.key_ail = 1;
        if (rl.isKeyDown(.a)) out.key_rud = -1;
        if (rl.isKeyDown(.d)) out.key_rud = 1;
        if (rl.isKeyDown(.w)) r.thr_key = @min(1, (r.thr_key orelse 0) + 0.6 * dt);
        if (rl.isKeyDown(.s)) r.thr_key = @max(0, (r.thr_key orelse 0) - 0.6 * dt);
        out.key_thr = r.thr_key;
        return out;
    }

    /// ações pelos botões configurados (menu Controle) e pelas teclas fixas
    pub fn actions(_: *const Reader, bind: ch.Bindings) Actions {
        const pad = rl.isGamepadAvailable(0);
        const b = struct {
            fn f(p: bool, btn: ch.Pad) bool {
                return p and rl.isGamepadButtonPressed(0, toRaylib(btn));
            }
        }.f;
        return .{
            .pause = rl.isKeyPressed(.escape) or rl.isKeyPressed(.p) or b(pad, bind.pause),
            .toggle_mode = rl.isKeyPressed(.m) or b(pad, bind.mode),
            .drop = rl.isKeyPressed(.l) or b(pad, bind.drop),
            .record = rl.isKeyPressed(.g) or b(pad, bind.record),
            .camera = rl.isKeyPressed(.c) or b(pad, bind.camera),
            .restart = rl.isKeyPressed(.r) or b(pad, bind.restart),
            .dev = rl.isKeyPressed(.f3),
        };
    }
};

pub fn toRaylib(p: ch.Pad) rl.GamepadButton {
    return switch (p) {
        .a => .right_face_down,
        .b => .right_face_right,
        .x => .right_face_left,
        .y => .right_face_up,
        .lb => .left_trigger_1,
        .rb => .right_trigger_1,
        .lt => .left_trigger_2,
        .rt => .right_trigger_2,
        .back => .middle_left,
        .start => .middle_right,
        .ls => .left_thumb,
        .rs => .right_thumb,
        .up => .left_face_up,
        .down => .left_face_down,
        .left => .left_face_left,
        .right => .left_face_right,
    };
}

/// o botão apertado neste quadro (para remapear), se houver
pub fn pressedButton() ?ch.Pad {
    if (!rl.isGamepadAvailable(0)) return null;
    inline for (@typeInfo(ch.Pad).@"enum".fields) |f| {
        const p: ch.Pad = @enumFromInt(f.value);
        if (rl.isGamepadButtonPressed(0, toRaylib(p))) return p;
    }
    return null;
}


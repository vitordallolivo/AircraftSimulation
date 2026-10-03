//! Pausa (Start / Esc no voo): o voo congelado por trás e o menu — continuar, ajustar controle e
//! câmera (as mesmas telas do menu inicial), parar/começar a gravação, recomeçar ou sair.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const PauseMenu = struct {
    pub fn enter(_: *PauseMenu, app: *App) void {
        app.audio.silence();
    }

    pub fn frame(_: *PauseMenu, app: *App, _: f64) Next {
        app.screens.flight.drawFrozen(app);
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = W, .height = H }, theme.shade);
        const pw: f32 = @min(460, W - 40);
        const ph: f32 = 470;
        const panel: rl.Rectangle = .{ .x = (W - pw) / 2, .y = @max(20, (H - ph) / 2), .width = pw, .height = ph };
        rl.drawRectangleRounded(panel, 0.06, 8, theme.panel);
        app.fonts.draw("Pausa", panel.x + 28, panel.y + 22, 34, theme.title);
        var col: widgets.Column = .{ .x = panel.x + 16, .y = panel.y + 80, .w = pw - 32, .gap = 4 };
        var next: Next = .stay;
        const b = app.profile().buttons;
        const g = @import("../ui/glyphs.zig");
        if (app.ui.menuItemKey(col.next(50), "Continuar", .{ .btn = g.fromPad(b.pause), .key = "Esc", .label = "" })) next = .back;
        if (app.ui.menuItem(col.next(50), "Controle", "curvas")) next = .{ .open = .control };
        if (app.ui.menuItem(col.next(50), "Câmera", null)) next = .{ .open = .camera };
        if (app.ui.menuItemKey(col.next(50), if (app.recording()) "Parar a gravação ●" else "Gravar", .{ .btn = g.fromPad(b.record), .key = "G", .label = "" })) {
            if (app.recording()) app.stopRecording() else app.startRecording();
            next = .back;
        }
        if (app.ui.menuItemKey(col.next(50), "Recomeçar", .{ .btn = g.fromPad(b.restart), .key = "R", .label = "" })) {
            app.screens.flight.restart(app);
            next = .back;
        }
        if (app.ui.menuItem(col.next(50), "Menu inicial", null)) next = .home;
        if (app.ui.menuItem(col.next(50), "Sair do jogo", null)) next = .quit;
        const gp = @import("../input/gamepad.zig");
        if (app.ui.back() or rl.isGamepadButtonPressed(0, gp.toRaylib(b.pause)) or rl.isKeyPressed(.p)) next = .back;
        return next;
    }
};

//! Opções (do menu inicial): Controle, Câmera, Som, Voos gravados e a tela (janela ou tela cheia,
//! painel de desempenho). Na pausa do voo os mesmos itens aparecem direto.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const OptionsMenu = struct {
    pub fn frame(_: *OptionsMenu, app: *App, _: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Opções", null);
        var col: widgets.Column = .{ .x = 28, .y = 100, .w = @min(560, W - 56), .gap = 4 };
        var next: Next = .stay;
        if (app.ui.menuItem(col.next(48), "Controle", "comandos, curvas e botões")) next = .{ .open = .control };
        if (app.ui.menuItem(col.next(48), "Câmera", null)) next = .{ .open = .camera };
        if (app.ui.menuItem(col.next(48), "Som", "volume e teste")) next = .{ .open = .sound };
        if (app.ui.menuItem(col.next(48), "Voos gravados", "vídeo e dados")) next = .{ .open = .recordings };
        col.space(12);
        var fs = app.settings.fullscreen;
        if (app.ui.toggle(col.next(44), "Tela cheia (F11)", &fs)) app.setFullscreen(fs);
        _ = app.ui.toggle(col.next(44), "Painel de desempenho (F3)", &app.settings.dev_overlay);
        if (app.keep_awake.active()) {
            app.fonts.draw("a tela não escurece enquanto o jogo estiver aberto", col.x + 14, col.next(24).y, 15, theme.muted);
        }
        widgets.footer(&app.fonts, &.{ widgets.nav, widgets.accept, widgets.back_hint });
        if (app.ui.back()) return .back;
        return next;
    }
};

//! Som: volume geral e o teste do motor — o acelerador de teste (ou o gatilho RT / W e S) muda a
//! altura e o volume do som da hélice, igual ao voo.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const SoundMenu = struct {
    test_thr: f64 = 0.3,
    play: bool = true,

    pub fn frame(m: *SoundMenu, app: *App, dt: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Som", "o som da hélice sobe e fica mais alto com o motor");
        var col: widgets.Column = .{ .x = 40, .y = 120, .w = @min(620, W - 80), .gap = 8 };
        _ = app.ui.slider(col.next(44), "Volume", &app.settings.volume, 0, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.toggle(col.next(44), "Testar o motor", &m.play);
        _ = app.ui.slider(col.next(44), "Acelerador de teste", &m.test_thr, 0, 1, 0.05, "{d:.0} %", 100);
        const raw = app.reader.raw(dt); // o gatilho também acelera
        const level = @max(m.test_thr, raw.rt);
        if (m.play) app.audio.update(level, app.settings.volume, dt) else app.audio.silence();

        col.space(12);
        const o = app.audio.last;
        meter(&app.fonts, col.next(30), "altura", (o.pitch - 0.1) / 1.9, "{d:.2}×", o.pitch);
        meter(&app.fonts, col.next(30), "volume", o.volume, "{d:.0} %", 100 * o.volume);
        col.space(10);
        if (!app.audio.available()) app.fonts.draw("sem saída de som neste computador (o jogo segue sem som)", col.x + 14, col.next(24).y, 16, theme.danger);
        widgets.footer(&app.fonts, "↑↓: escolher · ← →: mudar · RT / W S: acelerar · Esc / B: voltar");
        if (app.ui.back()) {
            app.audio.silence();
            return .back;
        }
        return .stay;
    }
};

fn meter(f: *const theme.Fonts, r: rl.Rectangle, label: [:0]const u8, frac: f32, comptime fmt: []const u8, v: f32) void {
    f.draw(label, r.x + 14, r.y + 5, 18, theme.text);
    const bar: rl.Rectangle = .{ .x = r.x + 150, .y = r.y + 10, .width = r.width - 240, .height = 10 };
    rl.drawRectangleRounded(bar, 1, 6, theme.muted_light);
    rl.drawRectangleRounded(.{ .x = bar.x, .y = bar.y, .width = bar.width * std.math.clamp(frac, 0, 1), .height = bar.height }, 1, 6, theme.accent);
    var buf: [24]u8 = undefined;
    f.draw(std.fmt.bufPrintZ(&buf, fmt, .{v}) catch "", r.x + r.width - 80, r.y + 5, 17, theme.muted);
}

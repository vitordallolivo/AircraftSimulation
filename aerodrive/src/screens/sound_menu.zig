//! Som: volume geral e o teste — o acelerador de teste (ou o gatilho / W e S) muda a altura e o
//! volume da hélice, e a velocidade de teste muda o som do vento, igual ao voo.
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
    test_wind: f64 = 15, // m/s

    pub fn frame(m: *SoundMenu, app: *App, dt: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Som", "o som da hélice sobe e fica mais alto com o motor");
        var col: widgets.Column = .{ .x = 40, .y = 120, .w = @min(620, W - 80), .gap = 8 };
        _ = app.ui.slider(col.next(44), "Volume", &app.settings.volume, 0, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.toggle(col.next(44), "Testar o motor", &m.play);
        _ = app.ui.slider(col.next(44), "Acelerador de teste", &m.test_thr, 0, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(44), "Vento de teste (velocidade)", &m.test_wind, 0, 35, 1, "{d:.0} m/s", 1);
        const raw = app.reader.raw(dt); // o gatilho / W também acelera
        const level = @max(m.test_thr, @max(raw.rt, raw.key_thr orelse 0));
        if (m.play) {
            app.audio.update(level, app.settings.volume, dt);
            app.audio.updateWind(m.test_wind, app.settings.volume);
        } else app.audio.silence();

        col.space(12);
        const o = app.audio.last;
        meter(&app.fonts, col.next(30), "altura", (o.pitch - 0.1) / 1.9, "{d:.2}×", o.pitch);
        meter(&app.fonts, col.next(30), "volume", o.volume, "{d:.0} %", 100 * o.volume);
        const w = app.audio.last_wind;
        meter(&app.fonts, col.next(30), "vento: altura", (w.pitch - 0.1) / 1.9, "{d:.2}×", w.pitch);
        meter(&app.fonts, col.next(30), "vento: volume", w.volume, "{d:.0} %", 100 * w.volume);
        col.space(10);
        if (!app.audio.available()) app.fonts.draw("sem saída de som neste computador (o jogo segue sem som)", col.x + 14, col.next(24).y, 16, theme.danger);
        widgets.footer(&app.fonts, &.{ widgets.nav, widgets.change, .{ .btn = .rt, .key = "W S", .label = "acelerar" }, widgets.back_hint });
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

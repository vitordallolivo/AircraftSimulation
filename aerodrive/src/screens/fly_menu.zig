//! Voar: onde começa (chão ou mesa), onde pousa (chão ou plataforma), quem pilota no começo
//! (manual por padrão; um botão troca durante o voo), a câmera inicial e os quadros por segundo.
//! Tudo fica lembrado para este avião. "Decolar" abre o voo.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const platform = @import("../sys/platform.zig");
const browser = @import("../sys/browser.zig");
const session = @import("../sim/session.zig");
const settings = @import("../app/settings.zig");
const ch = @import("../input/channels.zig");
const glyphs = @import("../ui/glyphs.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

const scenarios = [_][:0]const u8{ session.Scenario.ground.label(), session.Scenario.table.label() };
const landings = [_][:0]const u8{ session.Landing.ground.label(), session.Landing.platform.label() };
const modes = [_][:0]const u8{ session.Mode.manual.label(), session.Mode.autopilot.label() };
const cams = [_][:0]const u8{ "Perseguição", "Piloto no chão", "Livre" };
const cam_kinds = [_]settings.CameraKind{ .chase, .ground, .orbit };
const fpss = [_][:0]const u8{ "60", "30" };

pub const FlyMenu = struct {
    pub fn frame(_: *FlyMenu, app: *App, _: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Voar", if (app.plane) |p| p.name else "nenhum avião aberto");
        const s = app.session();
        var col: widgets.Column = .{ .x = 40, .y = 116, .w = @min(640, W - 80), .gap = 6 };

        var sc: usize = @intFromEnum(s.scenario);
        if (app.ui.choice(col.next(42), "Decola de", &sc, &scenarios)) s.scenario = @enumFromInt(sc);
        if (s.scenario == .table) {
            _ = app.ui.slider(col.next(42), "Altura da mesa", &s.table_height, 0.2, 3, 0.1, "{d:.1} m", 1);
            _ = app.ui.slider(col.next(42), "Comprimento da mesa", &s.table_length, 3, 40, 1, "{d:.0} m", 1);
        }
        var ld: usize = @intFromEnum(s.landing);
        if (app.ui.choice(col.next(42), "Pousa em", &ld, &landings)) s.landing = @enumFromInt(ld);
        var md: usize = @intFromEnum(s.start_mode);
        if (app.ui.choice(col.next(42), "Quem pilota", &md, &modes)) s.start_mode = @enumFromInt(md);
        const c = app.camera();
        var ck: usize = std.mem.indexOfScalar(settings.CameraKind, &cam_kinds, c.start) orelse 0;
        if (app.ui.choice(col.next(42), "Câmera", &ck, &cams)) c.start = cam_kinds[ck];
        var fi: usize = if (app.settings.fps == 30) 1 else 0;
        if (app.ui.choice(col.next(42), "Quadros por segundo", &fi, &fpss)) {
            app.settings.fps = if (fi == 1) 30 else 60;
            if (platform.in_browser) browser.setFrameRate(app.settings.fps) else rl.setTargetFPS(@intCast(app.settings.fps));
        }
        col.space(14);
        var next: Next = .stay;
        if (app.ui.button(col.next(54), "Decolar", true)) {
            if (app.startFlight()) next = .{ .open = .flight };
        }
        col.space(14);
        // os botões do voo (os configurados no menu Controle)
        app.fonts.draw("No voo", col.x + 4, col.next(24).y, 17, theme.title);
        const b = app.profile().buttons;
        var items: [ch.Action.all.len]glyphs.Hint = undefined;
        for (ch.Action.all, 0..) |a, i| items[i] = .{ .btn = glyphs.fromPad(b.get(a)), .key = a.key(), .label = a.label() };
        _ = glyphs.hints(&app.fonts, col.x + 4, col.next(28).y, items[0..3], theme.text);
        _ = glyphs.hints(&app.fonts, col.x + 4, col.next(28).y, items[3..], theme.text);
        if (app.planeError()) |e| {
            var buf: [300]u8 = undefined;
            app.fonts.draw(std.fmt.bufPrintZ(&buf, "{s}", .{e[0..@min(e.len, 280)]}) catch "", col.x + 4, col.next(22).y, 16, theme.danger);
        }
        widgets.footer(&app.fonts, &.{ widgets.nav, widgets.change, .{ .btn = .a, .key = "Enter", .label = "decolar" }, widgets.back_hint });
        if (app.ui.back()) return .back;
        return next;
    }
};

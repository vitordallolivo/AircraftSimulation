//! Voar: onde começa (chão ou mesa), quem pilota no começo (manual por padrão; o botão Y troca
//! durante o voo), a câmera inicial e os quadros por segundo. "Decolar" abre o voo.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const session = @import("../sim/session.zig");
const settings = @import("../app/settings.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

const scenarios = [_][:0]const u8{ session.Scenario.ground.label(), session.Scenario.table.label() };
const modes = [_][:0]const u8{ session.Mode.manual.label(), session.Mode.autopilot.label() };
const cams = [_][:0]const u8{ "Perseguição", "Piloto no chão", "Livre" };
const fpss = [_][:0]const u8{ "60", "30" };

pub const FlyMenu = struct {
    pub fn frame(_: *FlyMenu, app: *App, _: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Voar", if (app.plane) |p| p.name else "nenhum avião aberto");
        const s = &app.settings;
        const w = @min(640, W - 80);
        var col: widgets.Column = .{ .x = 40, .y = 120, .w = w, .gap = 8 };

        var sc: usize = @intFromEnum(s.session.scenario);
        if (app.ui.choice(col.next(44), "Começar", &sc, &scenarios)) s.session.scenario = @enumFromInt(sc);
        if (s.session.scenario == .table) {
            _ = app.ui.slider(col.next(44), "Altura da mesa", &s.session.table_height, 0.2, 3, 0.1, "{d:.1} m", 1);
            _ = app.ui.slider(col.next(44), "Comprimento da mesa", &s.session.table_length, 3, 40, 1, "{d:.0} m", 1);
        }
        var md: usize = @intFromEnum(s.session.start_mode);
        if (app.ui.choice(col.next(44), "Quem pilota", &md, &modes)) s.session.start_mode = @enumFromInt(md);
        var ck: usize = switch (s.camera.start) {
            .chase => 0,
            .ground => 1,
            .orbit => 2,
        };
        if (app.ui.choice(col.next(44), "Câmera", &ck, &cams)) s.camera.start = ([_]settings.CameraKind{ .chase, .ground, .orbit })[ck];
        var fi: usize = if (s.fps == 30) 1 else 0;
        if (app.ui.choice(col.next(44), "Quadros por segundo", &fi, &fpss)) {
            s.fps = if (fi == 1) 30 else 60;
            rl.setTargetFPS(@intCast(s.fps));
        }
        col.space(16);
        var next: Next = .stay;
        if (app.ui.button(col.next(56), "Decolar", true)) {
            if (app.startFlight()) next = .{ .open = .flight };
        }
        col.space(10);
        const tips = [_][:0]const u8{
            "No voo: Start / Esc pausa · Y / M troca manual e automático · X / L solta o LAPES",
            "Back / G grava vídeo e dados · B / C troca a câmera · F3 desempenho",
        };
        for (tips) |t| app.fonts.draw(t, col.x + 4, col.next(22).y, 16, theme.muted);
        if (app.planeError()) |e| {
            var buf: [300]u8 = undefined;
            app.fonts.draw(std.fmt.bufPrintZ(&buf, "{s}", .{e[0..@min(e.len, 280)]}) catch "", col.x + 4, col.next(22).y, 16, theme.danger);
        }
        widgets.footer(&app.fonts, "↑↓: escolher · ← →: mudar · Enter / A: decolar · Esc / B: voltar");
        if (app.ui.back()) return .back;
        return next;
    }
};

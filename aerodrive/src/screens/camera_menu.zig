//! Câmera: distância e altura da perseguição (em envergaduras), campo de visão e a câmera
//! inicial; a prévia mostra o avião voando sobre a pista exatamente como vai ficar.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const settings = @import("../app/settings.zig");
const cam = @import("../camera/camera.zig");
const pose = @import("../gfx/pose.zig");
const render = @import("../gfx/render.zig");
const field = @import("../world/field.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const Preview = @import("../ui/preview.zig").Preview;

const App = app_mod.App;
const Next = app_mod.Next;

const cams = [_][:0]const u8{ "Perseguição", "Piloto no chão", "Livre" };

pub const CameraMenu = struct {
    preview: Preview = .{},
    fld: ?field.Field = null,
    t: f64 = 0,

    pub fn deinit(m: *CameraMenu, _: *App) void {
        m.preview.deinit();
    }

    pub fn frame(m: *CameraMenu, app: *App, dt: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        m.t += dt;
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Câmera", "perseguição: atrás e acima do avião, seguindo a proa");
        const c = &app.settings.camera;
        const lw = @min(560, W * 0.4);
        var col: widgets.Column = .{ .x = 40, .y = 120, .w = lw, .gap = 8 };
        var ck: usize = switch (c.start) {
            .chase => 0,
            .ground => 1,
            .orbit => 2,
        };
        if (app.ui.choice(col.next(44), "Câmera ao decolar", &ck, &cams)) c.start = ([_]settings.CameraKind{ .chase, .ground, .orbit })[ck];
        _ = app.ui.slider(col.next(44), "Distância", &c.chase_distance, 0.8, 15, 0.1, "{d:.1}×", 1);
        _ = app.ui.slider(col.next(44), "Altura", &c.chase_height, -0.5, 5, 0.1, "{d:.1}×", 1);
        _ = app.ui.slider(col.next(44), "Campo de visão", &c.fov, 25, 100, 1, "{d:.0}°", 1);
        if (app.ui.button(col.next(44), "Restaurar padrão", false)) c.* = .{ .start = c.start };
        col.space(8);
        var buf: [96]u8 = undefined;
        if (app.plane) |p| app.fonts.draw(std.fmt.bufPrintZ(&buf, "× = envergaduras ({d:.2} m neste avião)", .{p.span}) catch "", col.x + 14, col.next(24).y, 16, theme.muted);
        app.fonts.draw("No voo: B / C troca a câmera; roda do mouse aproxima", col.x + 14, col.next(24).y, 16, theme.muted);

        // prévia: o avião em curva suave a 12 m sobre a pista
        const r: rl.Rectangle = .{ .x = col.x + lw + 30, .y = 120, .width = W - (col.x + lw + 30) - 40, .height = H - 180 };
        if (app.plane) |*p| if (r.width > 60) {
            if (m.fld == null) m.fld = field.build(60, &.{}, &.{});
            const psi = 0.25 * @sin(0.3 * m.t);
            const pos: [3]f64 = .{ 40 + 8 * m.t - 200 * @floor((40 + 8 * m.t) / 200), 0, -12 };
            var ch: cam.Chase = .{ .distance = c.chase_distance * p.span, .height = c.chase_height * p.span, .fov_deg = c.fov, .heading = psi, .target = pos };
            ch.distance = @max(ch.distance, 0.5);
            const Ctx = struct { m: *CameraMenu, scene: *const render.Scene, body: pose.Rigid };
            m.preview.render(r, theme.sky, ch.view(), Ctx{ .m = m, .scene = &p.scene, .body = pose.body(pos, -0.3 * @cos(0.3 * m.t), 0.05, psi) }, struct {
                fn f(x: Ctx) void {
                    render.drawField(&x.m.fld.?);
                    x.scene.draw(x.body, .{}, null);
                }
            }.f);
            m.preview.blit(r);
            rl.drawRectangleLinesEx(r, 1, theme.muted_light);
        };
        widgets.footer(&app.fonts, "↑↓: escolher · ← →: mudar · Esc / B: voltar");
        return if (app.ui.back()) .back else .stay;
    }
};

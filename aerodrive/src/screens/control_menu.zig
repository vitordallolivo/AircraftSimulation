//! Controle: a curva de cada canal que o avião tem (motor, aileron, profundor, leme — detectados
//! pelas superfícies do arquivo): zona morta, expo, curso, trim, inverter e deflexão máxima. O
//! gráfico mostra a curva e o ponto do controle agora; à direita, zoom na peça mexendo.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const features = @import("../model/features.zig");
const ch = @import("../input/channels.zig");
const pose = @import("../gfx/pose.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const Showcase = @import("../ui/showcase.zig").Showcase;

const App = app_mod.App;
const Next = app_mod.Next;

pub const ControlMenu = struct {
    channel: usize = 0,
    show: Showcase = .{ .spin = false },
    state: ch.State = .{},
    prop: f64 = 0,

    pub fn enter(m: *ControlMenu, app: *App) void {
        m.planeChanged(app);
    }

    pub fn planeChanged(m: *ControlMenu, app: *App) void {
        if (app.plane) |*p| m.show.frame(&p.skel);
        m.channel = 0;
    }

    pub fn deinit(m: *ControlMenu, _: *App) void {
        m.show.deinit();
    }

    pub fn frame(m: *ControlMenu, app: *App, dt: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Controle", "a curva de cada comando; mexa no controle para ver o ponto andar");

        const feats = if (app.plane) |p| p.feats else features.Features{ .throttle = true, .roll_by = "aileron", .pitch_by = "profundor", .yaw_by = "leme" };
        var buf: [4]features.Channel = undefined;
        const chans = feats.channels(&buf);
        if (chans.len == 0) {
            app.fonts.draw("este avião não tem comandos", 40, 130, 20, theme.muted);
            return if (app.ui.back()) .back else .stay;
        }
        m.channel = @min(m.channel, chans.len - 1);
        var labels: [4][:0]const u8 = undefined;
        for (chans, 0..) |c, i| labels[i] = c.label();

        const lw = @min(520, W * 0.38);
        var col: widgets.Column = .{ .x = 40, .y = 112, .w = lw, .gap = 6 };
        _ = app.ui.choice(col.next(44), "Canal", &m.channel, labels[0..chans.len]);
        const c = chans[m.channel];
        const p = &app.settings.profile;
        const curve: *ch.Curve = switch (c) {
            .throttle => &p.throttle,
            .aileron => &p.aileron,
            .elevator => &p.elevator,
            .rudder => &p.rudder,
        };
        const by: []const u8 = switch (c) {
            .throttle => "",
            .aileron => feats.roll_by,
            .elevator => feats.pitch_by,
            .rudder => feats.yaw_by,
        };
        col.space(4);
        _ = app.ui.slider(col.next(40), "Zona morta", &curve.deadzone, 0, 0.5, 0.01, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(40), "Expo", &curve.expo, 0, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(40), "Curso", &curve.rate, 0.05, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(40), "Trim", &curve.trim, -0.25, 0.25, 0.01, "{d:.0} %", 100);
        _ = app.ui.toggle(col.next(40), "Inverter", &curve.invert);
        const deg: f64 = 180.0 / std.math.pi;
        const lim = 45.0 / deg;
        switch (c) {
            .elevator => _ = app.ui.slider(col.next(40), "Deflexão máxima", &p.de_max, 2 / deg, lim, 1 / deg, "{d:.0}°", deg),
            .aileron => {
                _ = app.ui.slider(col.next(40), "Deflexão máxima", &p.da_max, 2 / deg, lim, 1 / deg, "{d:.0}°", deg);
                _ = app.ui.slider(col.next(40), "Velocidade LB/RB", &p.aileron_rate, 0.5, 15, 0.5, "{d:.1}/s", 1);
            },
            .rudder => _ = app.ui.slider(col.next(40), "Deflexão máxima", &p.dr_max, 2 / deg, lim, 1 / deg, "{d:.0}°", deg),
            .throttle => {},
        }
        col.space(6);
        if (app.ui.button(col.next(42), "Restaurar padrão deste canal", false)) {
            const d: ch.Profile = .{};
            curve.* = switch (c) {
                .throttle => d.throttle,
                .aileron => d.aileron,
                .elevator => d.elevator,
                .rudder => d.rudder,
            };
        }
        if (by.len > 0) {
            var b2: [64]u8 = undefined;
            app.fonts.draw(std.fmt.bufPrintZ(&b2, "neste avião: {s}", .{by}) catch "", col.x + 14, col.next(24).y, 16, theme.muted);
        }

        // entrada ao vivo
        const raw = app.reader.raw(dt);
        const cmd = m.state.step(p.*, raw, dt);
        const x_in: f64 = switch (c) {
            .throttle => 2 * raw.rt - 1,
            .aileron => m.state.aileron,
            .elevator => raw.stick_y,
            .rudder => raw.stick_x,
        };
        const gx = col.x + lw + 40;
        const gsize = @min(W - gx - 40, H * 0.42);
        curveGraph(&app.fonts, .{ .x = gx, .y = 116, .width = gsize, .height = gsize }, curve.*, x_in, c == .throttle);

        // zoom na peça
        m.prop += cmd.thr * 60 * dt;
        const r3: rl.Rectangle = .{ .x = gx, .y = 116 + gsize + 24, .width = W - gx - 40, .height = H - (116 + gsize + 24) - 50 };
        if (app.plane) |*pl| if (r3.height > 60) {
            const f = features.focus(&pl.skel, c);
            m.show.focusOn(if (f) |q| q.p else null, if (f) |q| q.size else 1, dt);
            m.show.input(r3, dt);
            var st: pose.DriveState = .{ .de = cmd.de, .da = cmd.da, .dr = cmd.dr };
            for (&st.prop_angle) |*a| a.* = m.prop;
            m.show.draw(r3, &pl.scene, st);
        };
        widgets.footer(&app.fonts, "direcional ↑↓: escolher · ← →: mudar · o analógico e os gatilhos mexem o ponto · Esc / B: voltar");
        return if (app.ui.back()) .back else .stay;
    }
};

/// a curva (entrada −1..1 → saída) e o ponto atual
fn curveGraph(f: *const theme.Fonts, r: rl.Rectangle, k: ch.Curve, x_in: f64, throttle: bool) void {
    rl.drawRectangleRec(r, theme.bg);
    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    rl.drawLineEx(.{ .x = r.x, .y = cy }, .{ .x = r.x + r.width, .y = cy }, 1, theme.muted_light);
    rl.drawLineEx(.{ .x = cx, .y = r.y }, .{ .x = cx, .y = r.y + r.height }, 1, theme.muted_light);
    rl.drawLineEx(.{ .x = r.x, .y = r.y + r.height }, .{ .x = r.x + r.width, .y = r.y }, 1, .{ .r = 0, .g = 0, .b = 0, .a = 30 }); // linear
    var prev: ?rl.Vector2 = null;
    var i: usize = 0;
    while (i <= 120) : (i += 1) {
        const x = -1 + 2 * @as(f64, @floatFromInt(i)) / 120;
        const v = k.apply(x);
        const pt: rl.Vector2 = .{ .x = cx + @as(f32, @floatCast(x)) * r.width / 2, .y = cy - @as(f32, @floatCast(v)) * r.height / 2 };
        if (prev) |q| rl.drawLineEx(q, pt, 3, theme.title);
        prev = pt;
    }
    const xi = if (std.math.isFinite(x_in)) std.math.clamp(x_in, -1, 1) else 0;
    const v = k.apply(xi);
    const dot: rl.Vector2 = .{ .x = cx + @as(f32, @floatCast(xi)) * r.width / 2, .y = cy - @as(f32, @floatCast(v)) * r.height / 2 };
    rl.drawCircleV(dot, 9, theme.accent);
    rl.drawRing(dot, 9, 11, 0, 360, 24, .white);
    var buf: [48]u8 = undefined;
    const out = if (throttle) std.fmt.bufPrintZ(&buf, "saída {d:.0} %", .{50 * (v + 1)}) catch "" else std.fmt.bufPrintZ(&buf, "saída {d:.0} %", .{100 * v}) catch "";
    f.draw(out, r.x + 10, r.y + 8, 17, theme.text);
    f.draw("entrada", r.x + r.width - 70, cy + 6, 14, theme.muted);
}

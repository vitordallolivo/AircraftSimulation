//! Controle, em duas abas:
//!   Comandos  esquema (Xbox, rádio modo 2/1, personalizado), de onde cada canal lê (eixo,
//!             gatilho ou LB/RB) e a curva de cada canal que o avião tem (detectados pelas
//!             superfícies): zona morta, expo, curso, trim, inverter, deflexão máxima. O gráfico
//!             mostra o ponto do controle agora; à direita, zoom na peça mexendo.
//!   Botões    cada ação do voo (pausa, modo, LAPES, gravar, câmera, recomeçar): escolher e apertar
//!             o botão novo. Botão já usado troca de lugar com o antigo (nunca dois iguais).
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const features = @import("../model/features.zig");
const ch = @import("../input/channels.zig");
const gamepad = @import("../input/gamepad.zig");
const pose = @import("../gfx/pose.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const glyphs = @import("../ui/glyphs.zig");
const Showcase = @import("../ui/showcase.zig").Showcase;

const App = app_mod.App;
const Next = app_mod.Next;

const tabs = [_][:0]const u8{ "Comandos", "Botões" };
const schemes = [_][:0]const u8{ ch.Scheme.xbox.label(), ch.Scheme.radio2.label(), ch.Scheme.radio1.label(), ch.Scheme.custom.label() };
const source_labels = blk: {
    var l: [ch.Source.all.len][:0]const u8 = undefined;
    for (ch.Source.all, 0..) |s, i| l[i] = s.label();
    break :blk l;
};

pub const ControlMenu = struct {
    tab: usize = 0,
    channel: usize = 0,
    show: Showcase = .{ .spin = false },
    state: ch.State = .{},
    prop: f64 = 0,
    capturing: ?ch.Action = null, // esperando o botão novo
    capture_t: f64 = 0,

    pub fn enter(m: *ControlMenu, app: *App) void {
        m.planeChanged(app);
        m.capturing = null;
    }

    pub fn planeChanged(m: *ControlMenu, app: *App) void {
        if (app.plane) |*p| m.show.frame(&p.skel);
        m.channel = 0;
    }

    pub fn deinit(m: *ControlMenu, _: *App) void {
        m.show.deinit();
    }

    pub fn frame(m: *ControlMenu, app: *App, dt: f64) Next {
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Controle", "de onde vem cada comando, a curva de cada um e os botões do voo");
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const lw = @min(540, W * 0.4);
        var col: widgets.Column = .{ .x = 40, .y = 108, .w = lw, .gap = 6 };
        if (m.capturing == null) {
            _ = app.ui.choice(col.next(42), "Aba", &m.tab, &tabs);
            var own = app.plane_cfg.own_controls;
            if (app.plane != null and app.ui.toggle(col.next(40), "Só para este avião", &own)) app.setOwnControls(own);
        } else col.space(94);
        return if (m.tab == 0) m.commands(app, dt, &col) else m.buttons(app, dt, &col);
    }

    fn commands(m: *ControlMenu, app: *App, dt: f64, col: *widgets.Column) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const p = app.profile();
        var sc: usize = @intFromEnum(p.scheme);
        if (app.ui.choice(col.next(42), "Esquema", &sc, &schemes)) p.applyScheme(@enumFromInt(sc));

        const feats = if (app.plane) |pl| pl.feats else features.Features{ .throttle = true, .roll_by = "aileron", .pitch_by = "profundor", .yaw_by = "leme" };
        var buf: [4]features.Channel = undefined;
        const chans = feats.channels(&buf);
        if (chans.len == 0) {
            app.fonts.draw("este avião não tem comandos", col.x + 14, col.next(30).y, 18, theme.muted);
            return if (app.ui.back()) .back else .stay;
        }
        m.channel = @min(m.channel, chans.len - 1);
        var labels: [4][:0]const u8 = undefined;
        for (chans, 0..) |c, i| labels[i] = c.label();
        _ = app.ui.choice(col.next(42), "Canal", &m.channel, labels[0..chans.len]);
        const c = chans[m.channel];
        const curve: *ch.Curve = switch (c) {
            .throttle => &p.throttle,
            .aileron => &p.aileron,
            .elevator => &p.elevator,
            .rudder => &p.rudder,
        };
        const src: *ch.Source = switch (c) {
            .throttle => &p.src_thr,
            .aileron => &p.src_ail,
            .elevator => &p.src_elev,
            .rudder => &p.src_rud,
        };
        var si: usize = std.mem.indexOfScalar(ch.Source, &ch.Source.all, src.*) orelse 0;
        if (app.ui.choice(col.next(42), "Entrada", &si, &source_labels)) {
            src.* = ch.Source.all[si];
            p.scheme = .custom;
        }
        _ = app.ui.slider(col.next(38), "Zona morta", &curve.deadzone, 0, 0.5, 0.01, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(38), "Expo", &curve.expo, 0, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(38), "Curso", &curve.rate, 0.05, 1, 0.05, "{d:.0} %", 100);
        _ = app.ui.slider(col.next(38), "Trim", &curve.trim, -0.25, 0.25, 0.01, "{d:.0} %", 100);
        _ = app.ui.toggle(col.next(38), "Inverter", &curve.invert);
        const deg: f64 = 180.0 / std.math.pi;
        const lim = 45.0 / deg;
        switch (c) {
            .elevator => _ = app.ui.slider(col.next(38), "Deflexão máxima", &p.de_max, 2 / deg, lim, 1 / deg, "{d:.0}°", deg),
            .aileron => _ = app.ui.slider(col.next(38), "Deflexão máxima", &p.da_max, 2 / deg, lim, 1 / deg, "{d:.0}°", deg),
            .rudder => _ = app.ui.slider(col.next(38), "Deflexão máxima", &p.dr_max, 2 / deg, lim, 1 / deg, "{d:.0}°", deg),
            .throttle => {},
        }
        if (src.* == .buttons) _ = app.ui.slider(col.next(38), "Velocidade LB/RB", &p.button_rate, 0.5, 15, 0.5, "{d:.1}/s", 1);
        if (app.ui.button(col.next(40), "Restaurar padrão deste canal", false)) {
            const d: ch.Profile = .{};
            curve.* = switch (c) {
                .throttle => d.throttle,
                .aileron => d.aileron,
                .elevator => d.elevator,
                .rudder => d.rudder,
            };
        }
        const by: []const u8 = switch (c) {
            .throttle => "",
            .aileron => feats.roll_by,
            .elevator => feats.pitch_by,
            .rudder => feats.yaw_by,
        };
        if (by.len > 0) {
            var b2: [64]u8 = undefined;
            app.fonts.draw(std.fmt.bufPrintZ(&b2, "neste avião: {s}", .{by}) catch "", col.x + 14, col.next(22).y, 15, theme.muted);
        }

        // entrada ao vivo
        const raw = app.reader.raw(dt);
        const in = m.state.inputs(p.*, raw, dt);
        const cmd = m.state.step(p.*, raw, 0);
        const x_in: f64 = switch (c) {
            .throttle => in.thr,
            .aileron => in.ail,
            .elevator => in.elev,
            .rudder => in.rud,
        };
        const gx = col.x + col.w + 40;
        const gsize = @min(W - gx - 40, H * 0.4);
        curveGraph(&app.fonts, .{ .x = gx, .y = 112, .width = gsize, .height = gsize }, curve.*, x_in, c == .throttle);

        // zoom na peça
        m.prop += cmd.thr * 60 * dt;
        const r3: rl.Rectangle = .{ .x = gx, .y = 112 + gsize + 20, .width = W - gx - 40, .height = H - (112 + gsize + 20) - 54 };
        if (app.plane) |*pl| if (r3.height > 60) {
            const f = features.focus(&pl.skel, c);
            m.show.focusOn(if (f) |q| q.p else null, if (f) |q| q.size else 1, dt);
            m.show.input(r3, dt);
            var st: pose.DriveState = .{ .de = cmd.de, .da = cmd.da, .dr = cmd.dr };
            for (&st.prop_angle) |*a| a.* = m.prop;
            m.show.draw(r3, &pl.scene, st);
        };
        widgets.footer(&app.fonts, &.{ .{ .btn = .up, .key = "↑↓", .label = "escolher" }, .{ .btn = .left, .key = "← →", .label = "mudar" }, .{ .btn = .ls, .key = "W A S D", .label = "mexer o ponto" }, widgets.back_hint });
        return if (app.ui.back()) .back else .stay;
    }

    fn buttons(m: *ControlMenu, app: *App, dt: f64, col: *widgets.Column) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const b = &app.profile().buttons;
        if (m.capturing) |a| { // esperando o botão novo: só ele (ou Esc) conta
            m.capture_t += dt;
            if (m.capture_t > 0.15) if (gamepad.pressedButton()) |pb| {
                b.set(a, pb);
                m.capturing = null;
                app.ui.feedback = true;
                return .stay;
            };
            if (rl.isKeyPressed(.escape) or m.capture_t > 8) m.capturing = null;
            rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = W, .height = H }, theme.shade);
            const box: rl.Rectangle = .{ .x = W / 2 - 260, .y = H / 2 - 80, .width = 520, .height = 160 };
            rl.drawRectangleRounded(box, 0.08, 8, theme.panel);
            app.fonts.draw(a.label(), box.x + 28, box.y + 24, 26, theme.title);
            app.fonts.draw(if (rl.isGamepadAvailable(0)) "aperte o botão novo no controle" else "ligue um controle para remapear", box.x + 28, box.y + 70, 19, theme.text);
            app.fonts.draw("Esc cancela", box.x + 28, box.y + 108, 15, theme.muted);
            return .stay;
        }
        app.fonts.draw("Escolha a ação e aperte o botão novo. As teclas do teclado não mudam.", col.x + 14, col.next(26).y, 15, theme.muted);
        for (ch.Action.all) |a| {
            const r = col.next(46);
            const pb = b.get(a);
            if (app.ui.menuItemKey(r, a.label(), .{ .btn = glyphs.fromPad(pb), .key = a.key(), .label = "" })) {
                m.capturing = a;
                m.capture_t = 0;
            }
            // sem controle ligado a dica mostra a tecla; o botão configurado fica ao lado
            if (!glyphs.padShown()) _ = glyphs.button(&app.fonts, glyphs.fromPad(pb), r.x + r.width + 12, r.y + 11, 24);
        }
        col.space(8);
        if (app.ui.button(col.next(42), "Restaurar botões padrão", false)) b.* = .{};
        widgets.footer(&app.fonts, &.{ widgets.nav, .{ .btn = .a, .key = "Enter", .label = "remapear" }, widgets.back_hint });
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

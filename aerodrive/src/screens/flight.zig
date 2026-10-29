//! Voo: o drive_manager avança a física em tempo real; no manual, o controle (com as curvas do
//! menu Controle) vai direto às superfícies; no automático, o piloto do núcleo segue o percurso.
//! Desenha céu, campo, setas fracas do vento, rastro, a aeronave, HUD, minimapa e o aviso de
//! gravação. Botões (remapeáveis no menu Controle): pausa, manual ⇄ automático, LAPES, gravar,
//! câmera, recomeçar.
const std = @import("std");
const rl = @import("raylib");
const v3 = @import("../math/vec3.zig");
const app_mod = @import("../app/app.zig");
const settings = @import("../app/settings.zig");
const pose = @import("../gfx/pose.zig");
const render = @import("../gfx/render.zig");
const cam = @import("../camera/camera.zig");
const field = @import("../world/field.zig");
const theme = @import("../ui/theme.zig");
const minimap = @import("../ui/minimap_view.zig");
const touch_view = @import("../ui/touch_view.zig");
const dm_mod = @import("../sim/drive_manager.zig");
const ch = @import("../input/channels.zig");
const glyphs = @import("../ui/glyphs.zig");

fn short(a: ch.Action) [:0]const u8 {
    return switch (a) {
        .pause => "pausa",
        .mode => "modo",
        .drop => "LAPES",
        .record => "gravar",
        .camera => "câmera",
        .restart => "recomeçar",
    };
}

const App = app_mod.App;
const Next = app_mod.Next;

const max_trail = 6000;
const kinds = [_]settings.CameraKind{ .chase, .ground, .orbit };

pub const Flight = struct {
    fld: field.Field = .{},
    cam_kind: settings.CameraKind = .chase,
    cams: [3]cam.Camera = .{ .{ .chase = .{} }, .{ .ground = .{} }, .{ .orbit = .{} } },
    trail: [max_trail]v3.V3 = undefined,
    n_trail: usize = 0,
    trail_t: f64 = 0,
    wind_t: f64 = 0,
    wind_lines: [600]field.Line = undefined,

    /// novo voo (o drive_manager já foi montado)
    pub fn begin(fl: *Flight, app: *App) void {
        const dm = &(app.dm orelse return);
        const p = &dm.inst.p;
        fl.fld = field.build(app.flight_ac.airfield.x_warning, p.seg[0..@intCast(p.n_seg)], p.pads[0..@intCast(p.n_pad)]);
        const span = if (app.plane) |pl| pl.span else 2;
        var orbit = cam.Orbit.framing(span);
        orbit.distance = 4 * span;
        fl.cams = .{
            .{ .chase = .{} },
            // piloto no chão: à direita da pista, perto do meio da corrida de decolagem
            .{ .ground = .{ .eye = .{ 0.5 * app.flight_ac.airfield.x_warning, 14, -1.7 }, .size = span } },
            .{ .orbit = orbit },
        };
        fl.cam_kind = app.camera().start;
        fl.applyCamera(app);
        fl.n_trail = 0;
        fl.trail_t = 0;
        _ = dm.step(0);
    }

    /// distância/altura/fov da perseguição vindos das configurações
    fn applyCamera(fl: *Flight, app: *App) void {
        const span = if (app.plane) |pl| pl.span else 2;
        const c = app.camera();
        fl.cams[0].chase.distance = @max(c.chase_distance * span, 0.5);
        fl.cams[0].chase.height = c.chase_height * span;
        fl.cams[0].chase.fov_deg = c.fov;
    }

    pub fn enter(fl: *Flight, app: *App) void {
        fl.applyCamera(app); // voltando da pausa (talvez da tela de câmera)
    }

    pub fn restart(fl: *Flight, app: *App) void {
        const dm = &(app.dm orelse return);
        app.stopRecording();
        dm.mode = app.session().start_mode;
        dm.restart() catch {};
        app.channel_state = .{};
        fl.n_trail = 0;
        fl.trail_t = 0;
        _ = dm.step(0);
    }

    fn camIndex(fl: *const Flight) usize {
        return switch (fl.cam_kind) {
            .chase => 0,
            .ground => 1,
            .orbit => 2,
        };
    }

    fn record(fl: *Flight, f: *const dm_mod.Frame) void {
        if (f.t - fl.trail_t >= 0.1 and fl.n_trail < max_trail) {
            fl.trail[fl.n_trail] = f.pos_ned;
            fl.n_trail += 1;
            fl.trail_t = f.t;
        }
    }

    /// só avança (sem desenhar) — para pular para um instante (fotos)
    pub fn advance(fl: *Flight, app: *App, dt: f64) void {
        const dm = &(app.dm orelse return);
        fl.record(dm.step(dt));
        if (app.rec) |*r| if (dm.last) |row| r.addRow(&row);
    }

    pub fn frame(fl: *Flight, app: *App, dt_in: f64) Next {
        const dm = &(app.dm orelse return .home);
        const dt = if (std.math.isFinite(dt_in)) std.math.clamp(dt_in, 0, 0.05) else 0;
        const prof = app.profile();
        const act = app.reader.actions(prof.buttons);
        if (act.pause) return .{ .open = .pause };
        if (act.restart) {
            fl.restart(app);
            return .stay;
        }
        if (act.toggle_mode) dm.toggleMode();
        if (act.drop) dm.dropPayload();
        if (act.camera) {
            fl.cam_kind = kinds[(fl.camIndex() + 1) % kinds.len];
        }
        if (act.record) {
            if (app.recording()) app.stopRecording() else app.startRecording();
        }

        // comandos do piloto (no automático o controle fica parado, mas a rampa acompanha)
        const cmd = app.channel_state.step(app.effectiveProfile(), app.reader.raw(dt), dt);
        if (dm.mode == .manual) dm.setCommands(.{ .de = cmd.de, .da = cmd.da, .dr = cmd.dr, .thr = cmd.thr });
        const f = dm.step(dt);
        fl.record(f);
        if (app.rec) |*r| if (dm.last) |row| r.addRow(&row);
        app.audio.update(if (f.phase == .landed or f.phase == .crashed) 0 else f.thr, app.settings.volume, dt);
        app.audio.updateWind(f.Va, app.settings.volume);

        var in: cam.Input = .{ .target = f.pos_ned, .heading = f.psi, .zoom = rl.getMouseWheelMove() };
        if (rl.isMouseButtonDown(.left) and !app.reader.touchActive()) { // no toque o dedo é dos manches
            const d = rl.getMouseDelta();
            in.drag = .{ -d.x, d.y };
        }
        const right_free = for ([_]@TypeOf(prof.src_elev){ prof.src_elev, prof.src_ail, prof.src_rud, prof.src_thr }) |sv| {
            if (sv == .rx or sv == .ry) break false;
        } else true;
        if (right_free and rl.isGamepadAvailable(0)) { // analógico direito livre: gira a câmera
            const x = rl.getGamepadAxisMovement(0, .right_x);
            const y = rl.getGamepadAxisMovement(0, .right_y);
            if (@abs(x) > 0.15 or @abs(y) > 0.15) in.drag = .{ -x * 600 * dt, y * 400 * dt };
        }
        fl.cams[fl.camIndex()].update(in, dt);
        fl.wind_t += dt;
        fl.draw(app, f);
        return .stay;
    }

    /// o último quadro, sem avançar (atrás da pausa)
    pub fn drawFrozen(fl: *Flight, app: *App) void {
        const dm = &(app.dm orelse return);
        fl.draw(app, &dm.frame);
    }

    fn draw(fl: *Flight, app: *App, f: *const dm_mod.Frame) void {
        const plane = &(app.plane orelse return);
        const W = rl.getScreenWidth();
        const H = rl.getScreenHeight();
        rl.clearBackground(theme.sky);
        rl.drawRectangleGradientV(0, 0, W, H, theme.sky, theme.sky_low);
        rl.beginMode3D(render.camera3d(fl.cams[fl.camIndex()].view()));
        render.drawField(&fl.fld);
        const env = app.flight_ac.environment;
        for (field.windArrows(f.pos_ned[0], f.pos_ned[1], env.wind_from, env.wind_speed, fl.wind_t, &fl.wind_lines)) |l| rl.drawLine3D(render.toScreen(l.a), render.toScreen(l.b), .{ .r = l.color[0], .g = l.color[1], .b = l.color[2], .a = l.color[3] });
        render.drawTrail(fl.trail[0..fl.n_trail], .{ .r = 230, .g = 40, .b = 40, .a = 220 });
        var payload: ?pose.Rigid = null;
        if (f.payload_ned) |pk| { // a carga solta: mesma proa, na posição dela
            const R = v3.bodyToNed(0, 0, f.psi);
            const r = app.flight_ac.payload;
            payload = .{ .R = R, .t = v3.sub(pk, v3.apply(R, .{ r.x, r.y, r.z })) };
        }
        plane.scene.draw(pose.body(f.pos_ned, f.phi, f.theta, f.psi), f.drive, payload);
        rl.endMode3D();
        fl.hud(app, f);
    }

    fn hud(fl: *const Flight, app: *App, f: *const dm_mod.Frame) void {
        const ft = &app.fonts;
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const dm = &app.dm.?;
        var buf: [128]u8 = undefined;

        // canto superior esquerdo: quem pilota, etapa, t, V, h
        rl.drawRectangleRounded(.{ .x = 12, .y = 12, .width = 340, .height = 156 }, 0.08, 6, theme.panel_glass);
        const manual = f.mode == .manual;
        const badge: rl.Rectangle = .{ .x = 24, .y = 22, .width = if (manual) 110 else 190, .height = 30 };
        rl.drawRectangleRounded(badge, 0.5, 6, if (manual) theme.accent else theme.title);
        ft.draw(if (manual) "MANUAL" else "AUTOMÁTICO", badge.x + 12, badge.y + 5, 19, .white);
        _ = glyphs.hints(ft, badge.x + badge.width + 10, badge.y + 4, &.{.{ .btn = glyphs.fromPad(app.profile().buttons.mode), .key = "M", .label = "trocar" }}, theme.muted);
        const legs = app.flight_ac.mission.legs;
        const stage: []const u8 = if (f.phase == .ground_run) "na pista" else if (manual) "voo livre" else if (f.seg < legs.len) legs[f.seg].name else "rolagem";
        ft.draw(std.fmt.bufPrintZ(&buf, "{s} · t = {d:.1} s", .{ stage, f.t }) catch "", 26, 60, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "V = {d:.1} m/s", .{f.Va}) catch "", 26, 86, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "h = {d:.1} m", .{-f.pos_ned[2]}) catch "", 186, 86, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "α = {d:.1}°", .{std.math.radiansToDegrees(f.alpha)}) catch "", 26, 110, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "n = {d:.2}", .{f.nz}) catch "", 186, 110, 18, theme.text);
        const ph: struct { [:0]const u8, rl.Color } = switch (f.phase) {
            .ground_run => .{ "na pista", theme.muted },
            .flying => .{ "voando", theme.ok },
            .landed => .{ "pousou e parou", theme.ok },
            .crashed => .{ "caiu — recomece", theme.danger },
            .timeout => .{ "tempo máximo", theme.muted },
        };
        ft.draw(ph[0], 26, 136, 18, ph[1]);

        // com toque: os manches no lugar do painel de comandos e das dicas de teclas
        const touched = app.reader.touchActive();
        if (touched) touch_view.draw(ft, app.reader.touch_state);

        // canto inferior esquerdo: o que vai para as superfícies
        if (!touched) rl.drawRectangleRounded(.{ .x = 12, .y = H - 150, .width = 340, .height = 138 }, 0.08, 6, theme.panel_glass);
        const ap = &dm.inst.p.ap;
        const pr = app.effectiveProfile();
        const de_max = if (manual) pr.de_max else ap.de_max;
        const da_max = if (manual) pr.da_max else ap.da_max;
        const dr_max = if (manual) pr.dr_max else ap.dr_max;
        var y = H - 140;
        const feats = if (app.plane) |p| p.feats else @import("../model/features.zig").Features{};
        if (!touched and feats.has(.elevator)) {
            theme.commandBar(ft, "profundor", f.drive.de, de_max, true, 26, y, 310);
            y += 30;
        }
        if (!touched and feats.has(.aileron)) {
            theme.commandBar(ft, "aileron", f.drive.da, da_max, true, 26, y, 310);
            y += 30;
        }
        if (!touched and feats.has(.rudder)) {
            theme.commandBar(ft, "leme", f.drive.dr, dr_max, true, 26, y, 310);
            y += 30;
        }
        if (!touched and feats.has(.throttle)) theme.commandBar(ft, "motor", f.thr, 1, false, 26, y, 310);

        // canto superior direito: minimapa
        const ms: f32 = @min(240, @min(W, H) * 0.32);
        const env = app.flight_ac.environment;
        minimap.draw(ft, .{ .x = W - ms - 14, .y = 14, .width = ms, .height = ms }, .{ .fld = &fl.fld, .trail = fl.trail[0..fl.n_trail], .pos = f.pos_ned, .psi = f.psi, .payload = f.payload_ned, .wind_from_deg = env.wind_from, .wind_speed = env.wind_speed });

        // gravação, LAPES e recados
        var ry = 14 + ms + 12;
        if (app.rec) |r| {
            const blink = @mod(app.time, 1.0) < 0.6;
            if (blink) rl.drawCircleV(.{ .x = W - ms, .y = ry + 10 }, 7, theme.danger);
            const dur = r.t_last - (r.t0 orelse r.t_last);
            ft.draw(std.fmt.bufPrintZ(&buf, "gravando {d:.0} s{s}", .{ dur, if (r.video == null) " (só dados)" else "" }) catch "", W - ms + 14, ry, 17, theme.danger);
            ry += 26;
        }
        if (feats.payload and dm.hasPayload() and f.payload_ned == null) {
            _ = glyphs.hints(ft, W - ms - 14, ry, &.{.{ .btn = glyphs.fromPad(app.profile().buttons.drop), .key = "L", .label = "soltar o LAPES" }}, theme.text);
            ry += 22;
        }
        if (app.message()) |msg| {
            const s = std.fmt.bufPrintZ(&buf, "{s}", .{msg[0..@min(msg.len, 120)]}) catch "";
            ft.draw(s, W - ft.width(s, 15) - 16, H - 52, 15, theme.text);
        }
        // dicas: os botões configurados (símbolo do controle, ou a tecla)
        const b = app.profile().buttons;
        var items: [ch.Action.all.len]glyphs.Hint = undefined;
        for (ch.Action.all, 0..) |a, i| items[i] = .{ .btn = glyphs.fromPad(b.get(a)), .key = a.key(), .label = short(a) };
        if (!touched) _ = glyphs.hints(ft, W - glyphs.hintsWidth(ft, &items) - 4, H - 34, &items, theme.text);
    }
};

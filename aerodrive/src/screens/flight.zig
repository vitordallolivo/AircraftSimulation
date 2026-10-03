//! Voo: o drive_manager avança a física em tempo real (30 ou 60 quadros por segundo) e a tela
//! desenha o campo, o rastro, a aeronave com as superfícies que o piloto automático comanda, e um
//! HUD mínimo. Teclas: C troca a câmera, Espaço pausa, R recomeça, Esc volta ao hangar.
const std = @import("std");
const rl = @import("raylib");
const v3 = @import("../math/vec3.zig");
const model = @import("../model/aircraft.zig");
const pose = @import("../gfx/pose.zig");
const render = @import("../gfx/render.zig");
const cam = @import("../camera/camera.zig");
const field = @import("../world/field.zig");
const theme = @import("../ui/theme.zig");
const dm_mod = @import("../sim/drive_manager.zig");

pub const Action = enum { none, back };

pub const CameraKind = enum { ground, chase, orbit };

const max_trail = 4000;

pub const Flight = struct {
    dm: *dm_mod.DriveManager,
    scene: *const render.Scene,
    ac: *const model.Aircraft,
    field: field.Field,
    cam_kind: CameraKind = .ground,
    cams: [3]cam.Camera,
    paused: bool = false,
    fps: u32,
    trail: [max_trail]v3.V3 = undefined,
    n_trail: usize = 0,
    trail_t: f64 = 0,

    pub fn init(dm: *dm_mod.DriveManager, scene: *const render.Scene, ac: *const model.Aircraft, fps: u32, start_cam: CameraKind, span: f64) Flight {
        const p = &dm.inst.p;
        const f = field.build(ac.airfield.x_warning, p.seg[0..@intCast(p.n_seg)], p.pads[0..@intCast(p.n_pad)]);
        var orbit = cam.Orbit.framing(span);
        orbit.distance = 4 * span;
        return .{
            .dm = dm,
            .scene = scene,
            .ac = ac,
            .field = f,
            .cam_kind = start_cam,
            // piloto no chão: à direita da pista, perto do meio da corrida de decolagem
            .cams = .{ .{ .ground = .{ .eye = .{ 0.5 * ac.airfield.x_warning, 14, -1.7 }, .size = span } }, .{ .chase = .{ .distance = 3.5 * span, .height = 0.8 * span } }, .{ .orbit = orbit } },
            .fps = fps,
        };
    }

    fn camera(fl: *Flight) *cam.Camera {
        return &fl.cams[@intFromEnum(fl.cam_kind)];
    }

    /// só avança a física (sem desenhar) e guarda o rastro — para pular para um instante
    pub fn advance(fl: *Flight, dt: f64) void {
        const f = fl.dm.step(dt);
        fl.record(f);
    }

    fn record(fl: *Flight, f: *const dm_mod.Frame) void {
        if (f.t - fl.trail_t >= 0.1 and fl.n_trail < max_trail) {
            fl.trail[fl.n_trail] = f.pos_ned;
            fl.n_trail += 1;
            fl.trail_t = f.t;
        }
    }

    /// avança e desenha um quadro; `dt` = tempo de simulação deste quadro
    pub fn frame(fl: *Flight, fonts: *const theme.Fonts, dt: f64) Action {
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.backspace)) return .back;
        if (rl.isKeyPressed(.space)) fl.paused = !fl.paused;
        if (rl.isKeyPressed(.c)) fl.cam_kind = @enumFromInt((@intFromEnum(fl.cam_kind) + 1) % 3);
        if (rl.isKeyPressed(.r)) {
            fl.dm.restart() catch {};
            fl.n_trail = 0;
            fl.trail_t = 0;
        }
        const f = fl.dm.step(if (fl.paused) 0 else dt);
        if (!fl.paused) fl.record(f);
        var in: cam.Input = .{ .target = f.pos_ned, .heading = f.psi, .zoom = rl.getMouseWheelMove() };
        if (rl.isMouseButtonDown(.left)) {
            const d = rl.getMouseDelta();
            in.drag = .{ -d.x, d.y };
        }
        fl.camera().update(in, dt);

        const body = pose.body(f.pos_ned, f.phi, f.theta, f.psi);
        var payload: ?pose.Rigid = null;
        if (f.payload_ned) |pk| { // a carga solta: mesma proa, na posição dela
            const R = v3.bodyToNed(0, 0, f.psi);
            const r = fl.ac.payload;
            payload = .{ .R = R, .t = v3.sub(pk, v3.apply(R, .{ r.x, r.y, r.z })) };
        }

        rl.beginDrawing();
        rl.clearBackground(theme.sky);
        rl.beginMode3D(render.camera3d(fl.camera().view()));
        render.drawField(&fl.field);
        render.drawTrail(fl.trail[0..fl.n_trail], .{ .r = 214, .g = 39, .b = 40, .a = 200 });
        fl.scene.draw(body, f.drive, payload);
        rl.endMode3D();
        fl.hud(fonts, f);
        rl.endDrawing();
        return .none;
    }

    fn hud(fl: *const Flight, ft: *const theme.Fonts, f: *const dm_mod.Frame) void {
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        var buf: [96]u8 = undefined;
        // canto superior esquerdo: modo, tempo, etapa, V e h
        rl.drawRectangleRounded(.{ .x = 12, .y = 12, .width = 330, .height = 150 }, 0.08, 6, theme.panel_glass);
        ft.draw("piloto automático", 26, 22, 22, theme.title);
        const legs = fl.ac.mission.legs;
        const stage: []const u8 = if (f.phase == .ground_run) "corrida no chão" else if (f.seg < legs.len) legs[f.seg].name else "rolagem";
        ft.draw(std.fmt.bufPrintZ(&buf, "{s}", .{stage}) catch "", 26, 52, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "t = {d:.1} s", .{f.t}) catch "", 26, 80, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "V = {d:.1} m/s", .{f.Va}) catch "", 26, 104, 18, theme.text);
        ft.draw(std.fmt.bufPrintZ(&buf, "h = {d:.1} m", .{-f.pos_ned[2]}) catch "", 176, 104, 18, theme.text);
        const ph: struct { [:0]const u8, rl.Color } = switch (f.phase) {
            .ground_run => .{ "na pista", theme.muted },
            .flying => .{ "voando", theme.ok },
            .landed => .{ "pousou e parou", theme.ok },
            .crashed => .{ "caiu", theme.danger },
            .timeout => .{ "tempo máximo", theme.muted },
        };
        ft.draw(ph[0], 26, 130, 18, ph[1]);
        if (fl.paused) ft.draw("pausado", 176, 130, 18, theme.danger);
        // canto inferior esquerdo: o que o piloto manda nas superfícies
        rl.drawRectangleRounded(.{ .x = 12, .y = H - 150, .width = 330, .height = 138 }, 0.08, 6, theme.panel_glass);
        const ap = &fl.dm.inst.p.ap;
        theme.commandBar(ft, "profundor", f.drive.de, ap.de_max, true, 26, H - 140, 300);
        theme.commandBar(ft, "aileron", f.drive.da, ap.da_max, true, 26, H - 110, 300);
        theme.commandBar(ft, "leme", f.drive.dr, ap.dr_max, true, 26, H - 80, 300);
        theme.commandBar(ft, "motor", f.thr, 1, false, 26, H - 50, 300);
        // canto superior direito: câmera e teclas
        const cname: [:0]const u8 = switch (fl.cam_kind) {
            .ground => "câmera: piloto no chão",
            .chase => "câmera: perseguição",
            .orbit => "câmera: livre",
        };
        ft.draw(cname, W - ft.width(cname, 18) - 20, 18, 18, theme.text);
        const keys: [:0]const u8 = "C: câmera · Espaço: pausa · R: recomeça · Esc: hangar";
        ft.draw(keys, W - ft.width(keys, 15) - 20, 44, 15, theme.muted);
        ft.draw(std.fmt.bufPrintZ(&buf, "{d} fps", .{rl.getFPS()}) catch "", W - 80, H - 30, 15, theme.muted);
    }
};

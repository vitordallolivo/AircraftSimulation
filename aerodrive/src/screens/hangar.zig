//! Hangar (menu inicial): menu à esquerda, a aeronave à direita, viva — mexer no controle
//! deflete as superfícies e o gatilho gira a hélice.
const std = @import("std");
const c = @import("c");
const v3 = @import("../math/vec3.zig");
const sk = @import("../model/skeleton.zig");
const pose = @import("../gfx/pose.zig");
const render = @import("../gfx/render.zig");
const cam = @import("../camera/camera.zig");
const ch = @import("../input/channels.zig");
const theme = @import("../ui/theme.zig");

const menu = [_][:0]const u8{ "Voar", "Aeronave", "Controle", "Mapa", "Câmera", "Gravação", "Voos gravados" };

pub const Options = struct {
    demo: bool = false, // comandos se mexendo sozinhos (para ver as superfícies)
    view: ?[3]f64 = null, // azimute, elevação (graus), zoom (× enquadramento)
};

pub const Hangar = struct {
    name: [:0]const u8,
    n_pieces: usize,
    scene: render.Scene,
    camera: cam.Camera,
    center: v3.V3,
    below: f64, // do centro até o ponto mais baixo (onde fica a grade)
    rt: ?c.RenderTexture2D = null,
    profile: ch.Profile = .{},
    input: ch.State = .{},
    thr_key: f64 = 0,
    cmd: ch.Commands = .{},
    prop: f64 = 0,
    t: f64 = 0,
    opts: Options,

    pub fn init(gpa: std.mem.Allocator, name: [:0]const u8, skel: *const sk.Skeleton, opts: Options) !Hangar {
        var lo: v3.V3 = .{ 1e9, 1e9, 1e9 };
        var hi: v3.V3 = .{ -1e9, -1e9, -1e9 };
        for (skel.pieces) |p| for (p.mesh.v) |q| for (0..3) |k| {
            lo[k] = @min(lo[k], q[k]);
            hi[k] = @max(hi[k], q[k]);
        };
        const center = v3.scale(v3.add(lo, hi), 0.5);
        var orbit = cam.Orbit.framing(0.5 * v3.norm(v3.sub(hi, lo)));
        orbit.target = center;
        if (opts.view) |vw| {
            orbit.azimuth_deg = vw[0];
            orbit.elevation_deg = vw[1];
            orbit.distance = std.math.clamp(orbit.distance * vw[2], orbit.min_distance, orbit.max_distance);
        }
        return .{
            .name = name,
            .n_pieces = skel.pieces.len,
            .scene = try render.Scene.init(gpa, skel),
            .camera = .{ .orbit = orbit },
            .center = center,
            .below = hi[2] - center[2] + 0.02,
            .opts = opts,
        };
    }

    pub fn deinit(h: *Hangar) void {
        if (h.rt) |rt| c.UnloadRenderTexture(rt);
        h.scene.deinit();
    }

    fn readInput(h: *Hangar, dt: f64) void {
        var r: ch.Raw = .{};
        if (c.IsGamepadAvailable(0)) {
            r.stick_x = c.GetGamepadAxisMovement(0, c.GAMEPAD_AXIS_LEFT_X);
            r.stick_y = c.GetGamepadAxisMovement(0, c.GAMEPAD_AXIS_LEFT_Y);
            r.rt = 0.5 * (c.GetGamepadAxisMovement(0, c.GAMEPAD_AXIS_RIGHT_TRIGGER) + 1);
            r.lb = c.IsGamepadButtonDown(0, c.GAMEPAD_BUTTON_LEFT_TRIGGER_1);
            r.rb = c.IsGamepadButtonDown(0, c.GAMEPAD_BUTTON_RIGHT_TRIGGER_1);
        }
        // teclado: setas = profundor/aileron, A/D = leme, W/S = motor
        if (c.IsKeyDown(c.KEY_DOWN)) r.stick_y = 1;
        if (c.IsKeyDown(c.KEY_UP)) r.stick_y = -1;
        if (c.IsKeyDown(c.KEY_A)) r.stick_x = -1;
        if (c.IsKeyDown(c.KEY_D)) r.stick_x = 1;
        r.lb = r.lb or c.IsKeyDown(c.KEY_LEFT);
        r.rb = r.rb or c.IsKeyDown(c.KEY_RIGHT);
        if (c.IsKeyDown(c.KEY_W)) h.thr_key = @min(1, h.thr_key + dt);
        if (c.IsKeyDown(c.KEY_S)) h.thr_key = @max(0, h.thr_key - dt);
        r.rt = @max(r.rt, h.thr_key);
        h.cmd = h.input.step(h.profile, r, dt);
        if (h.opts.demo) { // demonstração: tudo se mexendo (fixo no instante t para as fotos)
            const t = h.t;
            h.cmd = .{ .de = h.profile.de_max * @sin(1.1 * t + 1.2), .da = h.profile.da_max * @sin(1.7 * t + 1.0), .dr = h.profile.dr_max * @sin(0.8 * t + 0.9), .thr = 0.8 };
        }
    }

    /// um quadro inteiro (entrada, 3D numa textura à direita, painel à esquerda)
    pub fn frame(h: *Hangar, fonts: *const theme.Fonts, dt: f64) void {
        h.t += dt;
        h.readInput(dt);
        h.prop += h.cmd.thr * 60.0 * dt; // só visual (a rotação real vem do núcleo no voo)

        const W = c.GetScreenWidth();
        const H = c.GetScreenHeight();
        const left: c_int = @max(300, @divTrunc(W * 34, 100));
        const w3 = @max(W - left, 64);
        if (h.rt == null or h.rt.?.texture.width != w3 or h.rt.?.texture.height != H) {
            if (h.rt) |rt| c.UnloadRenderTexture(rt);
            h.rt = c.LoadRenderTexture(w3, H);
        }
        // câmera: arrastar com o mouse sobre o 3D gira, a roda aproxima
        const m = c.GetMousePosition();
        var in: cam.Input = .{};
        if (m.x >= @as(f32, @floatFromInt(left))) {
            if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) {
                const d = c.GetMouseDelta();
                in.drag = .{ -d.x, d.y };
            }
            in.zoom = c.GetMouseWheelMove();
        }
        h.camera.update(in, dt);

        var st: pose.DriveState = .{ .de = h.cmd.de, .da = h.cmd.da, .dr = h.cmd.dr };
        for (&st.prop_angle) |*a| a.* = h.prop;

        c.BeginTextureMode(h.rt.?);
        c.ClearBackground(theme.bg);
        c.BeginMode3D(render.camera3d(h.camera.view()));
        c.rlPushMatrix();
        const g = render.toScreen(h.center);
        c.rlTranslatef(g.x, 0, g.z);
        render.hangarGrid(h.below - h.center[2]);
        c.rlPopMatrix();
        h.scene.draw(.{}, st);
        c.EndMode3D();
        c.EndTextureMode();

        c.BeginDrawing();
        c.ClearBackground(theme.panel);
        const tex = h.rt.?.texture;
        c.DrawTextureRec(tex, .{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(-tex.height) }, .{ .x = @floatFromInt(left), .y = 0 }, c.WHITE);
        h.panel(fonts, @floatFromInt(left), @floatFromInt(H));
        c.EndDrawing();
    }

    fn panel(h: *const Hangar, f: *const theme.Fonts, w: f32, H: f32) void {
        const x: f32 = 28;
        f.draw("aerodrive", x, 24, 40, theme.title);
        var ns: f32 = 22; // nome comprido: letra menor para caber no painel
        while (ns > 12 and f.width(h.name, ns) > w - 2 * x) ns -= 1;
        f.draw(h.name, x, 74 + (22 - ns) / 2, ns, theme.text);
        var buf: [64]u8 = undefined;
        f.draw(std.fmt.bufPrintZ(&buf, "{d} peças", .{h.n_pieces}) catch "", x, 100, 16, theme.muted);
        var y: f32 = 150;
        for (menu, 0..) |item, i| {
            if (i == 0) c.DrawRectangleRounded(.{ .x = x - 10, .y = y - 6, .width = w - 2 * x + 20, .height = 38 }, 0.25, 6, theme.selected);
            f.draw(item, x, y, 24, if (i == 0) theme.title else theme.muted);
            y += 44;
        }
        // comandos ao vivo
        y = @max(y + 16, H - 240);
        f.draw("Comandos", x, y, 20, theme.title);
        y += 32;
        const bars = [_]struct { name: [:0]const u8, v: f64, max: f64, center: bool }{
            .{ .name = "profundor", .v = h.cmd.de, .max = h.profile.de_max, .center = true },
            .{ .name = "aileron", .v = h.cmd.da, .max = h.profile.da_max, .center = true },
            .{ .name = "leme", .v = h.cmd.dr, .max = h.profile.dr_max, .center = true },
            .{ .name = "motor", .v = h.cmd.thr, .max = 1, .center = false },
        };
        const bx = x + 110;
        const bw = w - bx - x - 60;
        for (bars) |b| {
            f.draw(b.name, x, y, 18, theme.text);
            c.DrawRectangleRounded(.{ .x = bx, .y = y + 4, .width = bw, .height = 12 }, 0.5, 6, theme.selected);
            const frac: f32 = @floatCast(std.math.clamp(b.v / b.max, -1, 1));
            if (b.center) {
                const mid = bx + bw / 2;
                const len = frac * bw / 2;
                c.DrawRectangleRec(.{ .x = if (len < 0) mid + len else mid, .y = y + 4, .width = @abs(len), .height = 12 }, theme.accent);
                c.DrawLineEx(.{ .x = mid, .y = y }, .{ .x = mid, .y = y + 20 }, 1.5, theme.muted);
                const deg = std.math.radiansToDegrees(b.v);
                f.draw(std.fmt.bufPrintZ(&buf, "{d:.0}°", .{if (@abs(deg) < 0.5) 0 else deg}) catch "", bx + bw + 8, y, 16, theme.muted);
            } else {
                c.DrawRectangleRec(.{ .x = bx, .y = y + 4, .width = frac * bw, .height = 12 }, theme.accent);
                f.draw(std.fmt.bufPrintZ(&buf, "{d:.0} %", .{100 * b.v}) catch "", bx + bw + 8, y, 16, theme.muted);
            }
            y += 30;
        }
        f.draw("analógico: profundor e leme · LB/RB: aileron · RT: motor", x, H - 52, 15, theme.muted);
        f.draw("teclado: setas, A/D, W/S · mouse: girar e zoom", x, H - 30, 15, theme.muted);
    }
};

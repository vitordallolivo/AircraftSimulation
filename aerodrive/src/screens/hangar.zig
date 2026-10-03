//! Hangar (menu inicial): menu à esquerda, a aeronave à direita, viva — mexer no controle
//! deflete as superfícies e o gatilho gira a hélice. Enter (ou clicar em "Voar") vai para o voo.
const std = @import("std");
const rl = @import("raylib");
const v3 = @import("../math/vec3.zig");
const sk = @import("../model/skeleton.zig");
const pose = @import("../gfx/pose.zig");
const render = @import("../gfx/render.zig");
const cam = @import("../camera/camera.zig");
const ch = @import("../input/channels.zig");
const theme = @import("../ui/theme.zig");

const menu = [_][:0]const u8{ "Voar (piloto automático)", "Aeronave", "Controle", "Mapa", "Câmera", "Gravação", "Voos gravados" };

pub const Options = struct {
    demo: bool = false, // comandos se mexendo sozinhos (para ver as superfícies)
    view: ?[3]f64 = null, // azimute, elevação (graus), zoom (× enquadramento)
};

pub const Action = enum { none, fly };

pub const Hangar = struct {
    name: [:0]const u8,
    n_pieces: usize,
    scene: *const render.Scene,
    camera: cam.Camera,
    center: v3.V3,
    below: f64,
    rt: ?rl.RenderTexture2D = null,
    profile: ch.Profile = .{},
    input: ch.State = .{},
    thr_key: f64 = 0,
    cmd: ch.Commands = .{},
    prop: f64 = 0,
    t: f64 = 0,
    opts: Options,

    pub fn init(name: [:0]const u8, skel: *const sk.Skeleton, scene: *const render.Scene, opts: Options) Hangar {
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
        return .{ .name = name, .n_pieces = skel.pieces.len, .scene = scene, .camera = .{ .orbit = orbit }, .center = center, .below = hi[2] - center[2] + 0.02, .opts = opts };
    }

    pub fn deinit(h: *Hangar) void {
        if (h.rt) |rt| rl.unloadRenderTexture(rt);
        h.rt = null;
    }

    fn readInput(h: *Hangar, dt: f64) void {
        var r: ch.Raw = .{};
        if (rl.isGamepadAvailable(0)) {
            r.stick_x = rl.getGamepadAxisMovement(0, .left_x);
            r.stick_y = rl.getGamepadAxisMovement(0, .left_y);
            r.rt = 0.5 * (rl.getGamepadAxisMovement(0, .right_trigger) + 1);
            r.lb = rl.isGamepadButtonDown(0, .left_trigger_1);
            r.rb = rl.isGamepadButtonDown(0, .right_trigger_1);
        }
        // teclado: setas = profundor/aileron, A/D = leme, W/S = motor
        if (rl.isKeyDown(.down)) r.stick_y = 1;
        if (rl.isKeyDown(.up)) r.stick_y = -1;
        if (rl.isKeyDown(.a)) r.stick_x = -1;
        if (rl.isKeyDown(.d)) r.stick_x = 1;
        r.lb = r.lb or rl.isKeyDown(.left);
        r.rb = r.rb or rl.isKeyDown(.right);
        if (rl.isKeyDown(.w)) h.thr_key = @min(1, h.thr_key + dt);
        if (rl.isKeyDown(.s)) h.thr_key = @max(0, h.thr_key - dt);
        r.rt = @max(r.rt, h.thr_key);
        h.cmd = h.input.step(h.profile, r, dt);
        if (h.opts.demo) { // demonstração: tudo se mexendo (fixo no instante t para as fotos)
            const t = h.t;
            h.cmd = .{ .de = h.profile.de_max * @sin(1.1 * t + 1.2), .da = h.profile.da_max * @sin(1.7 * t + 1.0), .dr = h.profile.dr_max * @sin(0.8 * t + 0.9), .thr = 0.8 };
        }
    }

    /// um quadro inteiro (entrada, 3D numa textura à direita, painel à esquerda)
    pub fn frame(h: *Hangar, fonts: *const theme.Fonts, dt: f64) Action {
        h.t += dt;
        h.readInput(dt);
        h.prop += h.cmd.thr * 60.0 * dt; // só visual (no voo a rotação vem do núcleo)

        const W = rl.getScreenWidth();
        const H = rl.getScreenHeight();
        const left: i32 = @max(300, @divTrunc(W * 34, 100));
        const w3 = @max(W - left, 64);
        if (h.rt == null or h.rt.?.texture.width != w3 or h.rt.?.texture.height != H) {
            if (h.rt) |rt| rl.unloadRenderTexture(rt);
            h.rt = rl.loadRenderTexture(w3, H) catch null;
        }
        const m = rl.getMousePosition();
        var in: cam.Input = .{};
        var action: Action = .none;
        if (m.x >= @as(f32, @floatFromInt(left))) {
            if (rl.isMouseButtonDown(.left)) {
                const d = rl.getMouseDelta();
                in.drag = .{ -d.x, d.y };
            }
            in.zoom = rl.getMouseWheelMove();
        } else if (rl.isMouseButtonPressed(.left) and m.y >= 144 and m.y <= 182) action = .fly;
        if (rl.isKeyPressed(.enter) or rl.isGamepadButtonPressed(0, .middle_right)) action = .fly;
        h.camera.update(in, dt);

        var st: pose.DriveState = .{ .de = h.cmd.de, .da = h.cmd.da, .dr = h.cmd.dr };
        for (&st.prop_angle) |*a| a.* = h.prop;

        if (h.rt) |rt| {
            rl.beginTextureMode(rt);
            rl.clearBackground(theme.bg);
            rl.beginMode3D(render.camera3d(h.camera.view()));
            render.hangarGrid(h.center, h.below - h.center[2]);
            h.scene.draw(.{}, st, null);
            rl.endMode3D();
            rl.endTextureMode();
        }
        rl.beginDrawing();
        rl.clearBackground(theme.panel);
        if (h.rt) |rt| {
            const tex = rt.texture;
            rl.drawTextureRec(tex, .{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(-tex.height) }, .{ .x = @floatFromInt(left), .y = 0 }, .white);
        }
        h.panel(fonts, @floatFromInt(left), @floatFromInt(H));
        rl.endDrawing();
        return action;
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
            if (i == 0) rl.drawRectangleRounded(.{ .x = x - 10, .y = y - 6, .width = w - 2 * x + 20, .height = 38 }, 0.25, 6, theme.selected);
            f.draw(item, x, y, 24, if (i == 0) theme.title else theme.muted);
            y += 44;
        }
        y = @max(y + 16, H - 240);
        f.draw("Comandos", x, y, 20, theme.title);
        y += 32;
        const p = h.profile;
        theme.commandBar(f, "profundor", h.cmd.de, p.de_max, true, x, y, w - 2 * x);
        theme.commandBar(f, "aileron", h.cmd.da, p.da_max, true, x, y + 30, w - 2 * x);
        theme.commandBar(f, "leme", h.cmd.dr, p.dr_max, true, x, y + 60, w - 2 * x);
        theme.commandBar(f, "motor", h.cmd.thr, 1, false, x, y + 90, w - 2 * x);
        f.draw("analógico: profundor e leme · LB/RB: aileron · RT: motor", x, H - 52, 15, theme.muted);
        f.draw("teclado: setas, A/D, W/S · mouse: girar e zoom · Enter: voar", x, H - 30, 15, theme.muted);
    }
};

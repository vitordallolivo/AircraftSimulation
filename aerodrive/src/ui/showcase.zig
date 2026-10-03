//! A aeronave em exposição num retângulo do menu: gira devagar sozinha, arrastar gira, a roda
//! aproxima, e as superfícies obedecem ao `DriveState` (controle ao vivo). `focusOn` aproxima a
//! câmera de um ponto (o zoom numa superfície no menu de controle).
const std = @import("std");
const rl = @import("raylib");
const v3 = @import("../math/vec3.zig");
const sk = @import("../model/skeleton.zig");
const pose = @import("../gfx/pose.zig");
const render = @import("../gfx/render.zig");
const cam = @import("../camera/camera.zig");
const theme = @import("theme.zig");
const Preview = @import("preview.zig").Preview;

pub const Showcase = struct {
    orbit: cam.Orbit = .{},
    center: v3.V3 = .{ 0, 0, 0 },
    below: f64 = 0.3,
    radius: f64 = 1,
    preview: Preview = .{},
    idle: f64 = 0, // s sem mexer (volta a girar sozinha)
    spin: bool = true,

    /// enquadra o esqueleto (chame quando o avião muda)
    pub fn frame(s: *Showcase, skel: *const sk.Skeleton) void {
        var lo: v3.V3 = .{ 1e9, 1e9, 1e9 };
        var hi: v3.V3 = .{ -1e9, -1e9, -1e9 };
        for (skel.pieces) |p| for (p.mesh.v) |q| for (0..3) |k| {
            lo[k] = @min(lo[k], q[k]);
            hi[k] = @max(hi[k], q[k]);
        };
        if (lo[0] > hi[0]) {
            lo = .{ -1, -1, -1 };
            hi = .{ 1, 1, 1 };
        }
        s.center = v3.scale(v3.add(lo, hi), 0.5);
        s.radius = 0.5 * v3.norm(v3.sub(hi, lo));
        s.below = hi[2] + 0.02;
        const az = s.orbit.azimuth_deg;
        const el = s.orbit.elevation_deg;
        s.orbit = cam.Orbit.framing(s.radius);
        s.orbit.azimuth_deg = az;
        s.orbit.elevation_deg = el;
        s.orbit.target = s.center;
    }

    /// aproxima de um ponto do corpo (null = volta ao avião inteiro)
    pub fn focusOn(s: *Showcase, p: ?v3.V3, size: f64, dt: f64) void {
        const tgt = p orelse s.center;
        const dist = if (p != null) std.math.clamp(2.2 * size, s.orbit.min_distance, s.orbit.max_distance) else cam.Orbit.framing(s.radius).distance;
        const k = std.math.clamp(6 * dt, 0, 1);
        s.orbit.target = v3.add(s.orbit.target, v3.scale(v3.sub(tgt, s.orbit.target), k));
        s.orbit.distance += (dist - s.orbit.distance) * k;
    }

    /// mouse sobre o retângulo gira e aproxima; parado, gira sozinho
    pub fn input(s: *Showcase, r: rl.Rectangle, dt: f64) void {
        var in: cam.Input = .{};
        const m = rl.getMousePosition();
        if (rl.checkCollisionPointRec(m, r)) {
            if (rl.isMouseButtonDown(.left)) {
                const d = rl.getMouseDelta();
                in.drag = .{ -d.x, d.y };
                s.idle = 0;
            }
            const w = rl.getMouseWheelMove();
            if (w != 0) s.idle = 0;
            in.zoom = w;
        }
        // analógico direito também gira
        if (rl.isGamepadAvailable(0)) {
            const x = rl.getGamepadAxisMovement(0, .right_x);
            const y = rl.getGamepadAxisMovement(0, .right_y);
            if (@abs(x) > 0.15 or @abs(y) > 0.15) {
                in.drag = .{ -x * 600 * dt, y * 400 * dt };
                s.idle = 0;
            }
        }
        s.idle += dt;
        if (s.spin and s.idle > 3) in.drag[0] += -18 * dt / 0.4; // 18°/s
        s.orbit.update(in, dt);
    }

    pub fn draw(s: *Showcase, r: rl.Rectangle, scene: *const render.Scene, st: pose.DriveState) void {
        const Ctx = struct { s: *Showcase, scene: *const render.Scene, st: pose.DriveState };
        s.preview.render(r, theme.bg, s.orbit.view(), Ctx{ .s = s, .scene = scene, .st = st }, struct {
            fn f(c: Ctx) void {
                render.hangarGrid(c.s.center, c.s.below);
                c.scene.draw(.{}, c.st, null);
            }
        }.f);
        s.preview.blit(r);
    }

    pub fn deinit(s: *Showcase) void {
        s.preview.deinit();
    }
};

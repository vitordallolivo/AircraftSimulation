//! Desenha o minimapa (plano XY, norte para cima): pista, percurso planejado, rastro, carga solta,
//! o avião (triângulo na proa) e o vento. A escala vem de `world/minimap.zig`.
const std = @import("std");
const rl = @import("raylib");
const v3 = @import("../math/vec3.zig");
const field = @import("../world/field.zig");
const mm = @import("../world/minimap.zig");
const theme = @import("theme.zig");

pub const Input = struct {
    fld: *const field.Field,
    trail: []const v3.V3,
    pos: v3.V3,
    psi: f64,
    payload: ?v3.V3 = null,
    wind_from_deg: f64 = 0,
    wind_speed: f64 = 0,
};

pub fn draw(f: *const theme.Fonts, r: rl.Rectangle, in: Input) void {
    rl.drawRectangleRounded(r, 0.06, 6, .{ .r = 20, .g = 60, .b = 20, .a = 150 });
    var b: mm.Bounds = .{};
    for (in.fld.lineSlice()) |l| if (std.mem.eql(u8, &l.color, &field.colors.path)) {
        b.add(l.a);
        b.add(l.b);
    };
    const rw = in.fld.runway;
    b.add(.{ rw.n - rw.L / 2, rw.e, 0 });
    b.add(.{ rw.n + rw.L / 2, rw.e, 0 });
    for (in.trail) |p| b.add(p);
    b.add(in.pos);
    const size = @min(r.width, r.height) - 16;
    const m = b.map(r.x + r.width / 2, r.y + r.height / 2, size);
    const P = struct {
        fn v(mp: mm.Map, p: v3.V3) rl.Vector2 {
            const s = mp.toScreen(p[0], p[1]);
            return .{ .x = s[0], .y = s[1] };
        }
    };
    rl.beginScissorMode(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), @intFromFloat(r.height));
    // pista
    const a = P.v(m, .{ rw.n - rw.L / 2, rw.e, 0 });
    const c = P.v(m, .{ rw.n + rw.L / 2, rw.e, 0 });
    rl.drawLineEx(a, c, @max(2, @as(f32, @floatCast(rw.W * m.scale))), .{ .r = 90, .g = 94, .b = 100, .a = 255 });
    // mesa / plataforma
    for (in.fld.boxSlice()) |bx| {
        const p = P.v(m, .{ bx.n, bx.e, 0 });
        rl.drawCircleV(p, 4, .{ .r = bx.color[0], .g = bx.color[1], .b = bx.color[2], .a = 255 });
    }
    // percurso planejado
    for (in.fld.lineSlice()) |l| if (std.mem.eql(u8, &l.color, &field.colors.path)) {
        rl.drawLineEx(P.v(m, l.a), P.v(m, l.b), 1.5, .{ .r = 120, .g = 190, .b = 255, .a = 200 });
    };
    // rastro
    if (in.trail.len > 1) for (in.trail[0 .. in.trail.len - 1], in.trail[1..]) |p, q| rl.drawLineEx(P.v(m, p), P.v(m, q), 2, .{ .r = 255, .g = 80, .b = 70, .a = 230 });
    if (in.payload) |pk| rl.drawCircleV(P.v(m, pk), 4, .{ .r = 200, .g = 140, .b = 60, .a = 255 });
    // avião: triângulo apontando a proa
    const ctr = P.v(m, in.pos);
    const psi: f32 = @floatCast(if (std.math.isFinite(in.psi)) in.psi else 0);
    const fwd: rl.Vector2 = .{ .x = @sin(psi), .y = -@cos(psi) };
    const side: rl.Vector2 = .{ .x = -fwd.y, .y = fwd.x };
    const tip: rl.Vector2 = .{ .x = ctr.x + fwd.x * 9, .y = ctr.y + fwd.y * 9 };
    const l: rl.Vector2 = .{ .x = ctr.x - fwd.x * 6 - side.x * 6, .y = ctr.y - fwd.y * 6 - side.y * 6 };
    const rr: rl.Vector2 = .{ .x = ctr.x - fwd.x * 6 + side.x * 6, .y = ctr.y - fwd.y * 6 + side.y * 6 };
    rl.drawTriangle(tip, l, rr, .white);
    rl.drawTriangle(tip, rr, l, .white);
    rl.endScissorMode();
    // norte e vento
    f.draw("N", r.x + r.width - 18, r.y + 6, 15, .white);
    if (in.wind_speed > 0.1) {
        const to: f32 = @floatCast(std.math.degreesToRadians(in.wind_from_deg) + std.math.pi);
        const o: rl.Vector2 = .{ .x = r.x + 20, .y = r.y + 20 };
        const d: rl.Vector2 = .{ .x = @sin(to) * 11, .y = -@cos(to) * 11 };
        rl.drawLineEx(.{ .x = o.x - d.x, .y = o.y - d.y }, .{ .x = o.x + d.x, .y = o.y + d.y }, 2, .{ .r = 255, .g = 255, .b = 255, .a = 200 });
        rl.drawCircleV(.{ .x = o.x + d.x, .y = o.y + d.y }, 3, .white);
        var buf: [16]u8 = undefined;
        f.draw(std.fmt.bufPrintZ(&buf, "{d:.1} m/s", .{in.wind_speed}) catch "", r.x + 36, r.y + 12, 13, .white);
    }
}

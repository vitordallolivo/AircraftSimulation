//! Painel de desenvolvedor (F3, como no Minecraft): quadros por segundo, tempo do quadro, memória
//! e CPU do processo, tela, controle e, no voo, o tempo simulado e a posição.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const theme = @import("theme.zig");

pub fn draw(app: *app_mod.App) void {
    const f = &app.fonts;
    var lines: [10][:0]const u8 = undefined;
    var bufs: [10][96]u8 = undefined;
    var n: usize = 0;
    const s = app.sampler.sample;
    const add = struct {
        fn a(l: *[10][:0]const u8, b: *[10][96]u8, k: *usize, comptime fmt: []const u8, args: anytype) void {
            if (k.* >= l.len) return;
            l[k.*] = std.fmt.bufPrintZ(&b[k.*], fmt, args) catch "";
            k.* += 1;
        }
    }.a;
    add(&lines, &bufs, &n, "AeroDrive · {d} fps · quadro {d:.1} ms", .{ rl.getFPS(), 1000 * rl.getFrameTime() });
    if (s.ram_bytes) |b| add(&lines, &bufs, &n, "RAM {d:.1} MB", .{@as(f64, @floatFromInt(b)) / (1024 * 1024)}) else add(&lines, &bufs, &n, "RAM —", .{});
    if (s.cpu_percent) |c| add(&lines, &bufs, &n, "CPU {d:.0} % (de um núcleo)", .{c}) else add(&lines, &bufs, &n, "CPU —", .{});
    add(&lines, &bufs, &n, "tela {d}×{d} · alvo {d} fps", .{ rl.getScreenWidth(), rl.getScreenHeight(), app.settings.fps });
    if (rl.isGamepadAvailable(0)) add(&lines, &bufs, &n, "controle: {s}", .{rl.getGamepadName(0)}) else add(&lines, &bufs, &n, "controle: nenhum (teclado)", .{});
    add(&lines, &bufs, &n, "som: {s}", .{if (app.audio.available()) "ok" else "sem saída"});
    if (app.dm) |dm| {
        const fr = dm.frame;
        add(&lines, &bufs, &n, "sim t = {d:.2} s · n {d:.1} e {d:.1} h {d:.1} m", .{ fr.t, fr.pos_ned[0], fr.pos_ned[1], -fr.pos_ned[2] });
        add(&lines, &bufs, &n, "rpm {d:.0} · I {d:.1} A · E {d:.2} Wh", .{ fr.rpm, fr.current, fr.energy_wh });
    }
    var w: f32 = 0;
    for (lines[0..n]) |l| w = @max(w, f.width(l, 15));
    const x: f32 = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2 - w / 2 - 10;
    rl.drawRectangleRounded(.{ .x = x, .y = 8, .width = w + 20, .height = @as(f32, @floatFromInt(n)) * 19 + 12 }, 0.1, 6, .{ .r = 0, .g = 0, .b = 0, .a = 170 });
    for (lines[0..n], 0..) |l, i| f.draw(l, x + 10, 14 + @as(f32, @floatFromInt(i)) * 19, 15, .{ .r = 230, .g = 240, .b = 230, .a = 255 });
}

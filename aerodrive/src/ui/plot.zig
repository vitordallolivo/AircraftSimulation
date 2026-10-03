//! Gráfico de linhas (raylib) para os voos gravados: eixos com marcas redondas, grade fraca,
//! até 3 curvas com legenda e, com o mouse em cima, a linha vertical e os valores no ponto.
//! Planos (XY…) usam a mesma escala nos dois eixos.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const pages = @import("../record/pages.zig");
const datalog = @import("../record/datalog.zig");

/// cores fixas por ordem de curva (as da GUI)
pub const colors = [_]rl.Color{
    .{ .r = 31, .g = 119, .b = 180, .a = 255 },
    .{ .r = 255, .g = 127, .b = 14, .a = 255 },
    .{ .r = 44, .g = 160, .b = 44, .a = 255 },
};

pub fn draw(f: *const theme.Fonts, r: rl.Rectangle, page: *const pages.Page, t: *const datalog.Table) void {
    rl.drawRectangleRec(r, theme.bg);
    const xs = t.col(page.x) orelse return;
    // área do desenho (margens para os números)
    const a: rl.Rectangle = .{ .x = r.x + 70, .y = r.y + 44, .width = r.width - 90, .height = r.height - 100 };
    if (a.width < 40 or a.height < 40) return;
    var xr = pages.range(xs, page.x_scale);
    var yr: pages.Range = .{ .lo = std.math.inf(f64), .hi = -std.math.inf(f64) };
    for (page.ys) |s| if (t.col(s.col)) |ys| {
        const q = pages.range(ys, s.scale);
        yr.lo = @min(yr.lo, q.lo);
        yr.hi = @max(yr.hi, q.hi);
    };
    if (!(yr.lo < yr.hi)) yr = .{ .lo = 0, .hi = 1 };
    if (page.equal_axes) { // mesma escala (m/px) nos dois eixos
        const sx = (xr.hi - xr.lo) / a.width;
        const sy = (yr.hi - yr.lo) / a.height;
        const s = @max(sx, sy);
        const cx = 0.5 * (xr.lo + xr.hi);
        const cy = 0.5 * (yr.lo + yr.hi);
        xr = .{ .lo = cx - s * a.width / 2, .hi = cx + s * a.width / 2 };
        yr = .{ .lo = cy - s * a.height / 2, .hi = cy + s * a.height / 2 };
    } else { // 5 % de folga em cima e embaixo
        const pad = 0.05 * (yr.hi - yr.lo);
        yr = .{ .lo = yr.lo - pad, .hi = yr.hi + pad };
    }
    const X = struct {
        fn px(v: f64, rg: pages.Range, lo: f32, len: f32) f32 {
            const fr = (v - rg.lo) / (rg.hi - rg.lo);
            return lo + @as(f32, @floatCast(std.math.clamp(fr, -0.1, 1.1))) * len;
        }
    };
    var buf: [48]u8 = undefined;
    // grade e números
    const tx = pages.ticks(xr.lo, xr.hi, 8);
    for (0..tx.n) |i| {
        const v = tx.first + @as(f64, @floatFromInt(i)) * tx.step;
        const x = X.px(v, xr, a.x, a.width);
        rl.drawLineEx(.{ .x = x, .y = a.y }, .{ .x = x, .y = a.y + a.height }, 1, .{ .r = 0, .g = 0, .b = 0, .a = 22 });
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{roundTick(v, tx.step)}) catch "";
        f.draw(s, x - f.width(s, 14) / 2, a.y + a.height + 6, 14, theme.muted);
    }
    const ty = pages.ticks(yr.lo, yr.hi, 6);
    for (0..ty.n) |i| {
        const v = ty.first + @as(f64, @floatFromInt(i)) * ty.step;
        const y = a.y + a.height - (X.px(v, yr, 0, a.height));
        rl.drawLineEx(.{ .x = a.x, .y = y }, .{ .x = a.x + a.width, .y = y }, 1, .{ .r = 0, .g = 0, .b = 0, .a = 22 });
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{roundTick(v, ty.step)}) catch "";
        f.draw(s, a.x - f.width(s, 14) - 8, y - 7, 14, theme.muted);
    }
    rl.drawRectangleLinesEx(a, 1, theme.muted_light);
    f.draw(page.title, r.x + 12, r.y + 10, 20, theme.title);
    f.draw(page.xlabel, a.x + a.width / 2 - f.width(page.xlabel, 15) / 2, a.y + a.height + 26, 15, theme.text);
    f.draw(page.ylabel, r.x + 8, a.y - 22, 15, theme.text);

    // curvas (no máximo ~2000 segmentos)
    rl.beginScissorMode(@intFromFloat(a.x), @intFromFloat(a.y), @intFromFloat(a.width), @intFromFloat(a.height));
    var lx = a.x + a.width;
    var k: usize = 0;
    for (page.ys) |s| {
        const ys = t.col(s.col) orelse continue;
        const col = colors[k % colors.len];
        const n = @min(xs.len, ys.len);
        const stride = @max(1, n / 2000);
        var prev: ?rl.Vector2 = null;
        var i: usize = 0;
        while (i < n) : (i += stride) {
            const xv = xs[i] * page.x_scale;
            const yv = ys[i] * s.scale;
            if (!std.math.isFinite(xv) or !std.math.isFinite(yv)) {
                prev = null;
                continue;
            }
            const p: rl.Vector2 = .{ .x = X.px(xv, xr, a.x, a.width), .y = a.y + a.height - X.px(yv, yr, 0, a.height) };
            if (prev) |q| rl.drawLineEx(q, p, 2, col);
            prev = p;
        }
        k += 1;
    }
    rl.endScissorMode();
    // legenda (em cima, à direita)
    for (page.ys) |s| if (t.col(s.col) != null) {
        lx -= f.width(s.label, 15) + 34;
    };
    k = 0;
    for (page.ys) |s| {
        if (t.col(s.col) == null) continue;
        rl.drawRectangleRounded(.{ .x = lx, .y = r.y + 16, .width = 16, .height = 4 }, 1, 4, colors[k % colors.len]);
        f.draw(s.label, lx + 20, r.y + 10, 15, theme.text);
        lx += f.width(s.label, 15) + 34;
        k += 1;
    }

    // mouse em cima: ponto mais próximo no eixo x (ou na tela, nos planos) e os valores
    const m = rl.getMousePosition();
    if (!rl.checkCollisionPointRec(m, a)) return;
    var best: ?usize = null;
    var bd: f32 = std.math.inf(f32);
    const n = xs.len;
    const stride = @max(1, n / 4000);
    var i: usize = 0;
    while (i < n) : (i += stride) {
        const xv = xs[i] * page.x_scale;
        if (!std.math.isFinite(xv)) continue;
        const px = X.px(xv, xr, a.x, a.width);
        var d = @abs(px - m.x);
        if (page.equal_axes) if (t.col(page.ys[0].col)) |ys| {
            const yv = ys[i] * page.ys[0].scale;
            if (!std.math.isFinite(yv)) continue;
            const py = a.y + a.height - X.px(yv, yr, 0, a.height);
            d = std.math.hypot(px - m.x, py - m.y);
        };
        if (d < bd) {
            bd = d;
            best = i;
        }
    }
    const bi = best orelse return;
    const bx = X.px(xs[bi] * page.x_scale, xr, a.x, a.width);
    rl.drawLineEx(.{ .x = bx, .y = a.y }, .{ .x = bx, .y = a.y + a.height }, 1, theme.muted);
    // caixa com os valores
    var lines: [5][:0]const u8 = undefined;
    var lb: [5][64]u8 = undefined;
    var nl: usize = 0;
    lines[nl] = std.fmt.bufPrintZ(&lb[nl], "{s} = {d:.2}", .{ page.x, xs[bi] * page.x_scale }) catch "";
    nl += 1;
    if (t.col("t")) |tt| if (!std.mem.eql(u8, page.x, "t")) {
        lines[nl] = std.fmt.bufPrintZ(&lb[nl], "t = {d:.2} s", .{tt[bi]}) catch "";
        nl += 1;
    };
    k = 0;
    for (page.ys) |s| {
        const ys = t.col(s.col) orelse continue;
        const yv = ys[bi] * s.scale;
        if (nl < lines.len) {
            lines[nl] = std.fmt.bufPrintZ(&lb[nl], "{s} = {d:.3}", .{ s.label, yv }) catch "";
            nl += 1;
        }
        if (std.math.isFinite(yv)) rl.drawCircleV(.{ .x = bx, .y = a.y + a.height - X.px(yv, yr, 0, a.height) }, 5, colors[k % colors.len]);
        k += 1;
    }
    var bw: f32 = 0;
    for (lines[0..nl]) |l| bw = @max(bw, f.width(l, 15));
    const bxp = if (bx + 16 + bw + 16 < a.x + a.width) bx + 12 else bx - bw - 28;
    const box: rl.Rectangle = .{ .x = bxp, .y = a.y + 10, .width = bw + 16, .height = @as(f32, @floatFromInt(nl)) * 20 + 10 };
    rl.drawRectangleRounded(box, 0.15, 6, .{ .r = 255, .g = 255, .b = 255, .a = 235 });
    rl.drawRectangleRoundedLinesEx(box, 0.15, 6, 1, theme.muted_light);
    for (lines[0..nl], 0..) |l, j| f.draw(l, box.x + 8, box.y + 6 + @as(f32, @floatFromInt(j)) * 20, 15, theme.text);
}

/// tira o "lixo" de ponto flutuante das marcas (0.30000000000000004 → 0.3)
fn roundTick(v: f64, step: f64) f64 {
    const r = @round(v / step) * step;
    return if (@abs(r) < 1e-9 * step) 0 else @round(r * 1e6) / 1e6;
}

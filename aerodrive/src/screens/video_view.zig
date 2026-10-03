//! Assistir o vídeo de um voo gravado dentro do jogo. A / Espaço: pausa e continua · ← →: volta e
//! avança 5 s · barra embaixo: clicar pula para o instante · B / Esc: volta.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const vp = @import("../record/video_player.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const VideoView = struct {
    info: ?vp.Info = null,
    dec: ?vp.Decoder = null,
    tex: ?rl.Texture2D = null,
    clock: f64 = 0, // instante mostrado (s)
    paused: bool = false,
    err: ?[:0]const u8 = null,
    path_buf: [1100]u8 = undefined,
    path_len: usize = 0,

    fn path(v: *const VideoView) []const u8 {
        return v.path_buf[0..v.path_len];
    }

    pub fn enter(v: *VideoView, app: *App) void {
        v.close(app);
        v.err = null;
        v.paused = false;
        v.clock = 0;
        const p = std.fmt.bufPrint(&v.path_buf, "{s}/video.mp4", .{app.viewer_dir[0..app.viewer_dir_len]}) catch return;
        v.path_len = p.len;
        v.info = vp.probe(app.io, app.gpa, p) catch |e| {
            v.err = if (e == error.NoFfmpeg) "precisa do ffmpeg instalado para assistir aqui" else "não consegui abrir o vídeo";
            return;
        };
        v.seek(app, 0);
    }

    fn seek(v: *VideoView, app: *App, t: f64) void {
        const info = v.info orelse return;
        if (v.dec) |*d| d.stop(app.io);
        v.dec = null;
        v.dec = vp.Decoder.start(app.io, app.gpa, v.path(), info, t, 1280) catch {
            v.err = "não consegui decodificar o vídeo";
            return;
        };
        const d = &v.dec.?;
        if (v.tex) |tx| if (tx.width != d.w or tx.height != d.h) {
            rl.unloadTexture(tx);
            v.tex = null;
        };
        if (v.tex == null) {
            const img = rl.genImageColor(@intCast(d.w), @intCast(d.h), .black);
            defer rl.unloadImage(img);
            v.tex = rl.loadTextureFromImage(img) catch null;
        }
        if (d.next()) if (v.tex) |tx| rl.updateTexture(tx, d.frame.ptr);
        v.clock = @max(d.t, 0);
    }

    fn close(v: *VideoView, app: *App) void {
        if (v.dec) |*d| d.stop(app.io);
        v.dec = null;
        if (v.tex) |t| rl.unloadTexture(t);
        v.tex = null;
    }

    pub fn deinit(v: *VideoView, app: *App) void {
        v.close(app);
    }

    pub fn frame(v: *VideoView, app: *App, dt: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.clearBackground(.{ .r = 16, .g = 18, .b = 22, .a = 255 });
        if (app.ui.back()) {
            v.close(app);
            return .back;
        }
        if (v.err) |e| {
            app.fonts.draw(e, 40, 60, 20, .white);
            widgets.footer(&app.fonts, &.{widgets.back_hint});
            return .stay;
        }
        const info = v.info orelse return .stay;
        const dur = @max(info.duration, 0.01);
        if (app.ui.nav.accept or rl.isKeyPressed(.space)) {
            app.ui.feedback = true;
            v.paused = !v.paused;
        }
        if (app.ui.nav.left) v.seek(app, @max(v.clock - 5, 0));
        if (app.ui.nav.right) v.seek(app, @min(v.clock + 5, dur - 0.05));
        // avança os quadros no tempo real
        if (!v.paused) if (v.dec) |*d| {
            v.clock += if (std.math.isFinite(dt)) std.math.clamp(dt, 0, 0.25) else 0;
            var got = false;
            var guard: usize = 0;
            while (d.t + d.dt <= v.clock and guard < 8) : (guard += 1) {
                if (!d.next()) break;
                got = true;
            }
            if (got) if (v.tex) |tx| rl.updateTexture(tx, d.frame.ptr);
            if (d.ended) v.paused = true; // fim: para no último quadro
        };
        // imagem no maior retângulo que cabe
        const bar_h: f32 = 64;
        if (v.tex) |tx| {
            const tw: f32 = @floatFromInt(tx.width);
            const th: f32 = @floatFromInt(tx.height);
            const sc = @min(W / tw, (H - bar_h) / th);
            const dw = tw * sc;
            const dh = th * sc;
            rl.drawTexturePro(tx, .{ .x = 0, .y = 0, .width = tw, .height = th }, .{ .x = (W - dw) / 2, .y = (H - bar_h - dh) / 2, .width = dw, .height = dh }, .{ .x = 0, .y = 0 }, 0, .white);
        }
        // barra do tempo (clicar pula)
        const bar: rl.Rectangle = .{ .x = 40, .y = H - bar_h + 8, .width = W - 80, .height = 8 };
        rl.drawRectangleRounded(bar, 1, 6, .{ .r = 80, .g = 84, .b = 92, .a = 255 });
        const fr: f32 = @floatCast(std.math.clamp(v.clock / dur, 0, 1));
        rl.drawRectangleRounded(.{ .x = bar.x, .y = bar.y, .width = bar.width * fr, .height = bar.height }, 1, 6, theme.accent);
        rl.drawCircleV(.{ .x = bar.x + bar.width * fr, .y = bar.y + 4 }, 8, .white);
        const m = rl.getMousePosition();
        if (rl.isMouseButtonPressed(.left) and m.y > bar.y - 12 and m.y < bar.y + 20 and m.x >= bar.x and m.x <= bar.x + bar.width) {
            v.seek(app, @as(f64, (m.x - bar.x) / bar.width) * dur);
        }
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrintZ(&buf, "{d:.0}:{d:0>2} / {d:.0}:{d:0>2}{s}", .{ @floor(v.clock / 60), @as(u32, @intFromFloat(@mod(v.clock, 60))), @floor(dur / 60), @as(u32, @intFromFloat(@mod(dur, 60))), if (v.paused) "  ‖ pausado" else "" }) catch "";
        app.fonts.draw(t, bar.x + bar.width - app.fonts.width(t, 16), bar.y + 16, 16, .white);
        widgets.footer(&app.fonts, &.{ .{ .btn = .a, .key = "Espaço", .label = if (v.paused) "continuar" else "pausar" }, .{ .btn = .left, .key = "← →", .label = "5 s" }, widgets.back_hint });
        return .stay;
    }
};

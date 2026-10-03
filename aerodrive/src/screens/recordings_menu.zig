//! Voos gravados: as gravações (mais novas primeiro); escolhida uma, abrir o vídeo (no tocador do
//! sistema) ou os dados (todos os gráficos, como na aba Missão).
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const recorder = @import("../record/recorder.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const RecordingsMenu = struct {
    cat: ?recorder.Catalog = null,
    list: widgets.ScrollList = .{},
    sel: ?usize = null,

    pub fn enter(m: *RecordingsMenu, app: *App) void {
        if (m.cat) |*c| c.deinit();
        m.cat = recorder.list(app.io, app.gpa, app.paths.recordings) catch null;
        if (m.sel) |s| if (m.cat == null or s >= m.cat.?.entries.len) {
            m.sel = null;
        };
    }

    pub fn deinit(m: *RecordingsMenu, _: *App) void {
        if (m.cat) |*c| c.deinit();
        m.cat = null;
    }

    fn row(m: *const RecordingsMenu, i: usize) widgets.Row {
        const e = m.cat.?.entries[i];
        return .{ .text = e.name, .selected = m.sel == i, .note = if (e.has_video) "vídeo + dados" else "dados" };
    }

    pub fn frame(m: *RecordingsMenu, app: *App, _: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.clearBackground(theme.panel);
        var buf: [1200]u8 = undefined;
        widgets.header(&app.fonts, "Voos gravados", std.fmt.bufPrintZ(&buf, "pasta: {s}", .{app.paths.recordings}) catch null);
        const entries = if (m.cat) |c| c.entries else &.{};
        const lw = @max(360, W * 0.5);
        if (entries.len == 0) {
            app.fonts.draw("Nenhum voo gravado ainda. No voo, aperte Back (ou G) para gravar e de novo para parar.", 40, 130, 18, theme.muted);
        } else if (m.list.draw(&app.ui, .{ .x = 28, .y = 110, .width = lw, .height = H - 160 }, 40, entries.len, m, row)) |i| m.sel = i;

        var next: Next = .stay;
        if (m.sel) |s| if (s < entries.len) {
            const e = entries[s];
            var col: widgets.Column = .{ .x = 28 + lw + 30, .y = 120, .w = W - (28 + lw + 30) - 40, .gap = 10 };
            app.fonts.draw(e.name, col.x, col.next(30).y, 18, theme.title);
            if (e.has_data and app.ui.button(col.next(50), "Ver os dados (gráficos)", true)) {
                const n = @min(e.dir.len, app.viewer_dir.len);
                @memcpy(app.viewer_dir[0..n], e.dir[0..n]);
                app.viewer_dir_len = n;
                next = .{ .open = .viewer };
            }
            if (e.has_video and app.ui.button(col.next(50), "Abrir o vídeo", false)) {
                const p = std.fmt.bufPrintZ(&buf, "{s}/video.mp4", .{e.dir}) catch "";
                if (p.len > 0) rl.openURL(p);
            }
            if (app.ui.button(col.next(50), "Abrir a pasta", false)) {
                const p = std.fmt.bufPrintZ(&buf, "{s}", .{e.dir}) catch "";
                if (p.len > 0) rl.openURL(p);
            }
        };
        widgets.footer(&app.fonts, &.{ widgets.nav, .{ .btn = .a, .key = "Enter", .label = "selecionar" }, widgets.back_hint });
        if (app.ui.back()) return .back;
        return next;
    }
};

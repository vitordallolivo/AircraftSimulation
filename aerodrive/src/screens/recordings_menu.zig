//! Voos gravados: as gravações (mais novas primeiro); escolhida uma: assistir o vídeo aqui dentro
//! (ou no tocador do sistema), ver os dados (todos os gráficos, como na aba Missão), abrir a pasta,
//! apagar o vídeo ou a gravação inteira (aperta duas vezes para confirmar).
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const recorder = @import("../record/recorder.zig");
const platform = @import("../sys/platform.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const RecordingsMenu = struct {
    cat: ?recorder.Catalog = null,
    list: widgets.ScrollList = .{},
    sel: ?usize = null,
    confirm: ?enum { video, all } = null, // apagar: aperta de novo para confirmar

    pub fn enter(m: *RecordingsMenu, app: *App) void {
        if (m.cat) |*c| c.deinit();
        m.cat = recorder.list(app.files, app.gpa, app.paths.recordings) catch null;
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
        } else if (m.list.draw(&app.ui, .{ .x = 28, .y = 110, .width = lw, .height = H - 160 }, 40, entries.len, m, row)) |i| {
            m.sel = i;
            m.confirm = null;
        }

        var next: Next = .stay;
        if (m.sel) |s| if (s < entries.len) {
            const e = entries[s];
            var col: widgets.Column = .{ .x = 28 + lw + 30, .y = 120, .w = W - (28 + lw + 30) - 40, .gap = 10 };
            app.fonts.draw(e.name, col.x, col.next(30).y, 18, theme.title);
            const pick = struct {
                fn f(a: *App, dir: []const u8) void {
                    const n = @min(dir.len, a.viewer_dir.len);
                    @memcpy(a.viewer_dir[0..n], dir[0..n]);
                    a.viewer_dir_len = n;
                }
            }.f;
            if (e.has_video and app.ui.button(col.next(48), "Assistir o vídeo", true)) {
                pick(app, e.dir);
                next = .{ .open = .video };
            }
            if (e.has_data and app.ui.button(col.next(48), "Ver os dados (gráficos)", !e.has_video)) {
                pick(app, e.dir);
                next = .{ .open = .viewer };
            }
            if (e.has_video and app.ui.button(col.next(44), "Abrir no tocador do sistema", false)) {
                const p = std.fmt.bufPrintZ(&buf, "{s}/video.mp4", .{e.dir}) catch "";
                if (p.len > 0) rl.openURL(p);
            }
            if (!platform.in_browser and app.ui.button(col.next(44), "Abrir a pasta", false)) {
                const p = std.fmt.bufPrintZ(&buf, "{s}", .{e.dir}) catch "";
                if (p.len > 0) rl.openURL(p);
            }
            col.space(10);
            // apagar: o primeiro aperto pede confirmação, o segundo apaga
            if (e.has_video and app.ui.button(col.next(44), if (m.confirm == .video) "Apertar de novo: apagar o vídeo" else "Apagar o vídeo", false)) {
                if (m.confirm == .video) {
                    _ = recorder.deleteVideo(app.files, e.dir);
                    m.confirm = null;
                    m.enter(app);
                } else m.confirm = .video;
            }
            if (app.ui.button(col.next(44), if (m.confirm == .all) "Apertar de novo: apagar tudo" else "Apagar a gravação (vídeo e dados)", false)) {
                if (m.confirm == .all) {
                    _ = recorder.deleteRecording(app.files, e.dir);
                    m.confirm = null;
                    m.sel = null;
                    m.enter(app);
                } else m.confirm = .all;
            }
        };
        widgets.footer(&app.fonts, &.{ widgets.nav, .{ .btn = .a, .key = "Enter", .label = "selecionar" }, widgets.back_hint });
        if (app.ui.back()) return .back;
        return next;
    }
};

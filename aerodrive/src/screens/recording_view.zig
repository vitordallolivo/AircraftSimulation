//! Dados de um voo gravado: a lista de gráficos disponíveis à esquerda (as grandezas da aba Missão)
//! e o gráfico escolhido à direita, com os valores sob o mouse. ← → também trocam de gráfico.
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const datalog = @import("../record/datalog.zig");
const pages = @import("../record/pages.zig");
const plot = @import("../ui/plot.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const App = app_mod.App;
const Next = app_mod.Next;

pub const RecordingView = struct {
    table: ?datalog.Table = null,
    avail: [pages.all.len]usize = undefined,
    n: usize = 0,
    page: usize = 0,
    list: widgets.ScrollList = .{},
    err: ?[]const u8 = null,

    pub fn enter(v: *RecordingView, app: *App) void {
        v.deinit(app);
        v.err = null;
        v.page = 0;
        var buf: [1100]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/dados.csv", .{app.viewer_dir[0..app.viewer_dir_len]}) catch return;
        const bytes = app.files.read(app.gpa, path, 512 << 20) catch {
            v.err = "não consegui ler dados.csv";
            return;
        };
        defer app.gpa.free(bytes);
        v.table = datalog.Table.parse(app.gpa, bytes) catch {
            v.err = "dados.csv vazio ou estranho";
            return;
        };
        v.n = pages.list(&v.table.?, &v.avail).len;
    }

    pub fn deinit(v: *RecordingView, _: *App) void {
        if (v.table) |*t| t.deinit();
        v.table = null;
        v.n = 0;
    }

    fn row(v: *const RecordingView, i: usize) widgets.Row {
        return .{ .text = pages.all[v.avail[i]].title, .selected = v.page == i };
    }

    pub fn frame(v: *RecordingView, app: *App, _: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.clearBackground(theme.panel);
        var buf: [256]u8 = undefined;
        const dir = app.viewer_dir[0..app.viewer_dir_len];
        widgets.header(&app.fonts, "Dados do voo", std.fmt.bufPrintZ(&buf, "{s}", .{std.fs.path.basename(dir)}) catch null);
        if (v.err) |e| {
            app.fonts.draw(std.fmt.bufPrintZ(&buf, "{s}", .{e}) catch "", 40, 130, 18, theme.danger);
            return if (app.ui.back()) .back else .stay;
        }
        const t = &(v.table orelse return if (app.ui.back()) .back else .stay);
        if (v.n == 0) {
            app.fonts.draw("o arquivo não tem nenhuma grandeza conhecida", 40, 130, 18, theme.muted);
            return if (app.ui.back()) .back else .stay;
        }
        const lw: f32 = 280;
        if (v.list.draw(&app.ui, .{ .x = 28, .y = 110, .width = lw, .height = H - 160 }, 34, v.n, v, row)) |i| v.page = i;
        if (app.ui.nav.right) v.page = (v.page + 1) % v.n;
        if (app.ui.nav.left) v.page = (v.page + v.n - 1) % v.n;
        const r: rl.Rectangle = .{ .x = 28 + lw + 24, .y = 110, .width = W - (28 + lw + 24) - 30, .height = H - 160 };
        plot.draw(&app.fonts, r, &pages.all[v.avail[v.page]], t);
        widgets.footer(&app.fonts, &.{ .{ .btn = .dpad, .key = "↑↓", .label = "gráfico" }, .{ .btn = .rs, .key = "mouse", .label = "valores sob o mouse" }, widgets.back_hint });
        const nr = std.fmt.bufPrintZ(&buf, "{d} linhas", .{t.rows()}) catch "";
        app.fonts.draw(nr, W - app.fonts.width(nr, 15) - 30, H - 34, 15, theme.muted);
        return if (app.ui.back()) .back else .stay;
    }
};

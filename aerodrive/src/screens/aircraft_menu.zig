//! Aeronave: escolher o arquivo (exemplos e "meus aviões" da GUI) — o modelo 3D troca na hora —,
//! ligar/desligar o sloshing (se tiver tanque) e o LAPES (se tiver carga), e o vento (velocidade e
//! de onde vem, com a rosa dos ventos).
//!
//! "Abrir arquivo do computador...": no navegador abre o seletor de arquivo da página (o .json
//! chega pelo `sys/browser.zig` e vai para a biblioteca guardada no navegador) e "Exportar"
//! baixa o .json do avião aberto; no nativo o item explica que basta arrastar o .json para a
//! janela (o arquivo arrastado abre direto, sem diálogo de sistema).
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const library = @import("../app/library.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const Showcase = @import("../ui/showcase.zig").Showcase;
const platform = @import("../sys/platform.zig");
const browser = @import("../sys/browser.zig");

const App = app_mod.App;
const Next = app_mod.Next;

const RowKind = union(enum) { header: library.Group, entry: usize };

pub const AircraftMenu = struct {
    show: Showcase = .{},
    list: widgets.ScrollList = .{},
    rows: [library.max_entries + 2]RowKind = undefined,
    n_rows: usize = 0,
    app: ?*App = null,

    pub fn enter(m: *AircraftMenu, app: *App) void {
        m.app = app;
        app.rescanLibrary();
        m.planeChanged(app);
    }

    /// a biblioteca mudou (avião novo aberto do computador): refaz a lista
    pub fn libraryChanged(m: *AircraftMenu, app: *App) void {
        m.build(app);
    }

    fn build(m: *AircraftMenu, app: *App) void {
        m.n_rows = 0;
        var last: ?library.Group = null;
        for (app.lib.entries, 0..) |e, i| {
            if (m.n_rows + 2 > m.rows.len) break;
            if (last != e.group) {
                m.rows[m.n_rows] = .{ .header = e.group };
                m.n_rows += 1;
                last = e.group;
            }
            m.rows[m.n_rows] = .{ .entry = i };
            m.n_rows += 1;
        }
    }

    pub fn planeChanged(m: *AircraftMenu, app: *App) void {
        if (app.plane) |*p| m.show.frame(&p.skel);
    }

    pub fn deinit(m: *AircraftMenu, _: *App) void {
        m.show.deinit();
    }

    fn row(m: *const AircraftMenu, i: usize) widgets.Row {
        const app = m.app.?;
        return switch (m.rows[i]) {
            .header => |g| .{ .text = g.label(), .header = true },
            .entry => |k| blk: {
                const e = app.lib.entries[k];
                const cur = if (app.plane) |p| std.mem.eql(u8, p.path, e.path) else false;
                break :blk .{ .text = e.name, .selected = cur };
            },
        };
    }

    pub fn frame(m: *AircraftMenu, app: *App, dt: f64) Next {
        m.app = app;
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.clearBackground(theme.panel);
        widgets.header(&app.fonts, "Aeronave", "escolha o arquivo; o modelo troca na hora");

        // lista de arquivos à esquerda; embaixo, abrir do computador (e exportar, no navegador)
        const lw = @max(300, W * 0.3);
        const file_rows: f32 = if (platform.in_browser) 2 else 1;
        const area: rl.Rectangle = .{ .x = 28, .y = 110, .width = lw, .height = H - 160 - file_rows * 46 };
        if (m.n_rows == 0) {
            app.fonts.draw("nenhum .json em data/aircraft nem em ~/aerosim_aeronaves", area.x + 10, area.y + 10, 16, theme.muted);
        } else if (m.list.draw(&app.ui, area, 38, m.n_rows, m, row)) |i| switch (m.rows[i]) {
            .entry => |k| if (app.loadPlane(app.lib.entries[k].path)) m.planeChanged(app),
            .header => {},
        };
        var files_column: widgets.Column = .{ .x = area.x, .y = area.y + area.height + 6, .w = lw, .gap = 6 };
        if (app.ui.menuItem(files_column.next(40), "Abrir arquivo do computador...", null)) {
            if (platform.in_browser) browser.openFilePicker() else app.note("arraste o arquivo .json para esta janela", .{});
        }
        if (platform.in_browser and app.ui.menuItem(files_column.next(40), "Exportar o avião (.json)", null)) exportPlane(app);
        if (rl.isFileDropped()) openDropped(app, m);
        if (app.message()) |text| {
            var message_buf: [200]u8 = undefined;
            app.fonts.draw(std.fmt.bufPrintZ(&message_buf, "{s}", .{text}) catch "", area.x + lw + 28, 84, 16, theme.muted);
        }

        // à direita: o avião e as opções
        const x = area.x + area.width + 28;
        const rw = W - x - 28;
        const r3: rl.Rectangle = .{ .x = x, .y = 110, .width = rw, .height = @max(160, H * 0.42) };
        if (app.plane) |*p| {
            m.show.input(r3, dt);
            m.show.draw(r3, &p.scene, .{});
            app.fonts.draw(p.name, r3.x + 12, r3.y + 10, 20, theme.title);
        }
        if (app.planeError()) |e| {
            var buf: [300]u8 = undefined;
            rl.drawRectangleRec(.{ .x = r3.x, .y = r3.y + r3.height - 30, .width = r3.width, .height = 30 }, .{ .r = 255, .g = 235, .b = 235, .a = 240 });
            app.fonts.draw(std.fmt.bufPrintZ(&buf, "não abriu: {s}", .{e[0..@min(e.len, 280)]}) catch "", r3.x + 10, r3.y + r3.height - 24, 15, theme.danger);
        }

        var col: widgets.Column = .{ .x = x, .y = r3.y + r3.height + 16, .w = rw - 190, .gap = 6 };
        const s = app.session();
        const feats = if (app.plane) |p| p.feats else @import("../model/features.zig").Features{};
        if (feats.tanks > 0) {
            _ = app.ui.toggle(col.next(40), "Sloshing (líquido mexendo nos tanques)", &s.slosh);
        } else app.fonts.draw("Sloshing: este avião não tem tanques", col.x + 14, col.next(40).y + 10, 17, theme.muted);
        if (feats.payload) {
            _ = app.ui.toggle(col.next(40), "Carga LAPES a bordo", &s.payload);
        } else app.fonts.draw("LAPES: este avião não leva carga", col.x + 14, col.next(40).y + 10, 17, theme.muted);
        _ = app.ui.slider(col.next(40), "Vento", &s.wind_speed, 0, 15, 0.5, "{d:.1} m/s", 1);
        _ = app.ui.slider(col.next(40), "Vem de", &s.wind_from, 0, 355, 5, "{d:.0}°", 1);
        compass(&app.fonts, .{ .x = x + rw - 90, .y = r3.y + r3.height + 100 }, 70, s.wind_from, s.wind_speed);

        widgets.footer(&app.fonts, &.{ widgets.nav, .{ .btn = .a, .key = "Enter", .label = "abrir o avião" }, widgets.change, widgets.back_hint });
        return if (app.ui.back()) .back else .stay;
    }
};

/// o primeiro .json arrastado para a janela abre direto do lugar onde está (nativo)
fn openDropped(app: *App, m: *AircraftMenu) void {
    const dropped = rl.loadDroppedFiles();
    defer rl.unloadDroppedFiles(dropped);
    for (0..dropped.count) |i| {
        const path = std.mem.span(dropped.paths[i]);
        if (!std.ascii.endsWithIgnoreCase(path, ".json")) continue;
        if (app.loadPlane(path)) m.planeChanged(app);
        return;
    }
    app.note("arraste um arquivo .json", .{});
}

/// baixa o .json do avião aberto (navegador)
fn exportPlane(app: *App) void {
    const plane = app.plane orelse return;
    const bytes = app.planeBytes() orelse return app.note("não consegui ler o avião aberto", .{});
    defer app.gpa.free(bytes);
    browser.download(std.fs.path.basename(plane.path), bytes);
}

/// rosa dos ventos: N para cima; a seta mostra para onde o vento sopra
pub fn compass(f: *const theme.Fonts, c: rl.Vector2, r: f32, from_deg: f64, speed: f64) void {
    rl.drawCircleV(c, r, theme.bg);
    rl.drawRing(c, r - 2, r, 0, 360, 48, theme.muted_light);
    const labels = [_][:0]const u8{ "N", "L", "S", "O" };
    for (labels, 0..) |l, i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 2;
        f.draw(l, c.x + (r - 14) * @sin(a) - 5, c.y - (r - 14) * @cos(a) - 9, 16, if (i == 0) theme.title else theme.muted);
    }
    if (speed < 0.05) {
        f.draw("calmo", c.x - 20, c.y - 8, 15, theme.muted);
        return;
    }
    const to: f32 = @floatCast(std.math.degreesToRadians(from_deg) + std.math.pi); // para onde sopra
    const d: rl.Vector2 = .{ .x = @sin(to), .y = -@cos(to) };
    const tail: rl.Vector2 = .{ .x = c.x - d.x * (r - 24), .y = c.y - d.y * (r - 24) };
    const tip: rl.Vector2 = .{ .x = c.x + d.x * (r - 24), .y = c.y + d.y * (r - 24) };
    rl.drawLineEx(tail, tip, 4, theme.title);
    const side: rl.Vector2 = .{ .x = -d.y, .y = d.x };
    rl.drawTriangle(.{ .x = tip.x + d.x * 10, .y = tip.y + d.y * 10 }, .{ .x = tip.x - side.x * 8, .y = tip.y - side.y * 8 }, .{ .x = tip.x + side.x * 8, .y = tip.y + side.y * 8 }, theme.title);
    rl.drawTriangle(.{ .x = tip.x + d.x * 10, .y = tip.y + d.y * 10 }, .{ .x = tip.x + side.x * 8, .y = tip.y + side.y * 8 }, .{ .x = tip.x - side.x * 8, .y = tip.y - side.y * 8 }, theme.title);
}

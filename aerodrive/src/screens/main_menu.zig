//! Menu inicial: logo da Albatroz, "AeroDrive", o avião escolhido e os itens; à direita a aeronave
//! em exposição, viva (o controle mexe nas superfícies e o gatilho gira a hélice).
const std = @import("std");
const rl = @import("raylib");
const app_mod = @import("../app/app.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const Showcase = @import("../ui/showcase.zig").Showcase;
const pose = @import("../gfx/pose.zig");
const ch = @import("../input/channels.zig");
const platform = @import("../sys/platform.zig");

const App = app_mod.App;
const Next = app_mod.Next;

const Item = struct { label: [:0]const u8, hint: ?[:0]const u8, next: Next };
const items = [_]Item{
    .{ .label = "Voar", .hint = null, .next = .{ .open = .fly } },
    .{ .label = "Aeronave", .hint = "arquivo, vento, LAPES", .next = .{ .open = .aircraft } },
    .{ .label = "Opções", .hint = "controle, câmera, som, voos gravados", .next = .{ .open = .options } },
    // no navegador, "Sair" volta à tela inicial do site
    .{ .label = if (platform.in_browser) "Voltar ao início" else "Sair", .hint = null, .next = .quit },
};

pub const MainMenu = struct {
    show: Showcase = .{},
    input: ch.State = .{},
    prop: f64 = 0,

    pub fn planeChanged(m: *MainMenu, app: *App) void {
        if (app.plane) |*p| m.show.frame(&p.skel);
    }

    pub fn enter(m: *MainMenu, app: *App) void {
        m.planeChanged(app);
    }

    pub fn deinit(m: *MainMenu, _: *App) void {
        m.show.deinit();
    }

    pub fn frame(m: *MainMenu, app: *App, dt: f64) Next {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const left = @max(360, W * 0.34);
        const r3: rl.Rectangle = .{ .x = left, .y = 0, .width = W - left, .height = H };
        rl.clearBackground(theme.panel);

        // aeronave viva à direita
        const cmd = m.input.step(app.effectiveProfile(), app.reader.raw(dt), dt);
        m.prop += cmd.thr * 60 * dt;
        if (app.plane) |*p| {
            m.show.input(r3, dt);
            var st: pose.DriveState = .{ .de = cmd.de, .da = cmd.da, .dr = cmd.dr };
            for (&st.prop_angle) |*a| a.* = m.prop;
            m.show.draw(r3, &p.scene, st);
        }

        // logo + nome do jogo
        var y: f32 = 26;
        const x: f32 = 32;
        if (app.logo) |t| {
            const lw = @min(left - 2 * x, 320);
            const lh = lw * @as(f32, @floatFromInt(t.height)) / @as(f32, @floatFromInt(t.width));
            rl.drawTexturePro(t, .{ .x = 0, .y = 0, .width = @floatFromInt(t.width), .height = @floatFromInt(t.height) }, .{ .x = x, .y = y, .width = lw, .height = lh }, .{ .x = 0, .y = 0 }, 0, .white);
            y += lh + 10;
        }
        app.fonts.draw("AeroDrive", x, y, 46, theme.title);
        y += 54;
        if (app.plane) |p| {
            var size: f32 = 20;
            while (size > 12 and app.fonts.width(p.name, size) > left - 2 * x) size -= 1;
            app.fonts.draw(p.name, x, y, size, theme.text);
        } else app.fonts.draw("nenhum avião aberto", x, y, 20, theme.danger);
        y += 40;

        var col: widgets.Column = .{ .x = x - 12, .y = y, .w = left - 2 * x + 24, .gap = 4 };
        const row_h = std.math.clamp((H - y - 60) / @as(f32, items.len) - 4, 34, 50);
        var next: Next = .stay;
        for (items) |it| {
            const disabled = it.next == .open and it.next.open == .fly and app.plane == null;
            if (app.ui.menuItem(col.next(row_h), it.label, if (disabled) "abra um avião" else it.hint) and !disabled) next = it.next;
        }
        if (app.planeError()) |e| {
            var buf: [300]u8 = undefined;
            app.fonts.draw(std.fmt.bufPrintZ(&buf, "{s}", .{e[0..@min(e.len, 280)]}) catch "", x, H - 56, 15, theme.danger);
        }
        widgets.footer(&app.fonts, &.{ widgets.nav, widgets.accept, .{ .btn = .rs, .key = "mouse", .label = "girar o avião" } });
        if (platform.in_browser and app.ui.back()) next = .quit; // Esc no menu inicial: volta à tela inicial do site
        return next;
    }
};

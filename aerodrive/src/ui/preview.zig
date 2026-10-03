//! Janela 3D dentro de um menu (a aeronave girando, o zoom numa superfície, a vista da câmera de
//! perseguição): desenha numa textura do tamanho do retângulo e cola a textura na tela.
//!
//!   var pv: Preview = .{};
//!   pv.render(rect, fundo, vista, ctx, desenhar);   // desenhar(ctx) chamado dentro do 3D
//!   pv.deinit();
const std = @import("std");
const rl = @import("raylib");
const gfx = @import("../gfx/render.zig");
const cam = @import("../camera/camera.zig");

pub const Preview = struct {
    rt: ?rl.RenderTexture2D = null,

    pub fn deinit(p: *Preview) void {
        if (p.rt) |rt| rl.unloadRenderTexture(rt);
        p.rt = null;
    }

    fn ensure(p: *Preview, w: i32, h: i32) ?rl.RenderTexture2D {
        if (w < 8 or h < 8) return null;
        if (p.rt) |rt| if (rt.texture.width == w and rt.texture.height == h) return rt;
        p.deinit();
        p.rt = rl.loadRenderTexture(w, h) catch null;
        return p.rt;
    }

    /// desenha o 3D numa textura (chame antes de `rl.beginDrawing`) — depois `blit`
    pub fn render(p: *Preview, r: rl.Rectangle, bg: rl.Color, view: cam.View, ctx: anytype, comptime draw: fn (@TypeOf(ctx)) void) void {
        const rt = p.ensure(@intFromFloat(@max(r.width, 0)), @intFromFloat(@max(r.height, 0))) orelse return;
        rl.beginTextureMode(rt);
        rl.clearBackground(bg);
        rl.beginMode3D(gfx.camera3d(view));
        draw(ctx);
        rl.endMode3D();
        rl.endTextureMode();
    }

    /// cola a última imagem no retângulo (com cantos arredondados no contorno)
    pub fn blit(p: *const Preview, r: rl.Rectangle) void {
        const rt = p.rt orelse return;
        const t = rt.texture;
        rl.drawTextureRec(t, .{ .x = 0, .y = 0, .width = @floatFromInt(t.width), .height = @floatFromInt(-t.height) }, .{ .x = r.x, .y = r.y }, .white);
    }
};

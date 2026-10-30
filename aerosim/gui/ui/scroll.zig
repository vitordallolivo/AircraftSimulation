//! A área rolável: tudo o que não cabe na altura (a barra lateral, a coluna dos gráficos) rola pela roda do mouse ou
//! pela barra fina da direita, que dá para arrastar. Quem desenha pede o topo do conteúdo em `begin`, desenha a partir
//! dele e diz em `end` até onde foi; a altura do conteúdo vale para o quadro seguinte. Uma área dentro de outra (a
//! lista de candidatos dentro da barra lateral) rola primeiro, e a de fora só recebe a roda que sobrou.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

const bar_width: f32 = 8;
const wheel_step: f32 = 48;

pub const ScrollArea = struct {
    offset: f32 = 0,
    content_height: f32 = 0, // a altura do conteúdo no último quadro
    grab: ?f32 = null, // arrastando a barra: a distância do mouse ao topo do cursor

    fn maxOffset(area: *const ScrollArea, rect: rl.Rectangle) f32 {
        return @max(0, area.content_height - rect.height);
    }

    fn thumb(area: *const ScrollArea, rect: rl.Rectangle) rl.Rectangle {
        const height = @max(28, rect.height * rect.height / @max(area.content_height, 1));
        const travel = rect.height - height;
        const fraction = if (area.maxOffset(rect) > 0) area.offset / area.maxOffset(rect) else 0;
        return .{ .x = rect.x + rect.width - bar_width - 2, .y = rect.y + travel * fraction, .width = bar_width, .height = height };
    }

    /// trata a barra (clique e arraste), abre o recorte e devolve o y do topo do conteúdo
    pub fn begin(area: *ScrollArea, ui: *widgets.Ui, rect: rl.Rectangle) f32 {
        const limit = area.maxOffset(rect);
        if (limit > 0) {
            const handle = area.thumb(rect);
            const track: rl.Rectangle = .{ .x = handle.x - 2, .y = rect.y, .width = bar_width + 4, .height = rect.height };
            if (ui.clicked and !ui.click_taken and ui.hovering(track)) {
                ui.click_taken = true;
                // no cursor, segura onde pegou; fora dele, o cursor pula para o mouse
                area.grab = if (ui.hovering(handle)) ui.mouse.y - handle.y else handle.height / 2;
            }
            if (area.grab) |grab| {
                if (rl.isMouseButtonDown(.left)) {
                    const travel = rect.height - handle.height;
                    if (travel > 0) area.offset = std.math.clamp((ui.mouse.y - grab - rect.y) / travel, 0, 1) * limit;
                } else area.grab = null;
            }
        } else area.grab = null;
        area.offset = std.math.clamp(area.offset, 0, limit);
        ui.pushClip(rect);
        return rect.y - area.offset;
    }

    /// fecha o recorte; `bottom` é o y onde o conteúdo terminou. A roda que ninguém de dentro usou rola esta área,
    /// e a barra aparece quando o conteúdo não cabe
    pub fn end(area: *ScrollArea, ui: *widgets.Ui, rect: rl.Rectangle, bottom: f32) void {
        ui.popClip();
        area.content_height = bottom + area.offset - rect.y;
        const limit = area.maxOffset(rect);
        if (ui.wheel != 0 and ui.hovering(rect) and limit > 0) {
            area.offset = std.math.clamp(area.offset - ui.wheel * wheel_step, 0, limit);
            ui.wheel = 0;
        }
        area.offset = std.math.clamp(area.offset, 0, limit);
        if (limit <= 0) return;
        const handle = area.thumb(rect);
        const active = area.grab != null or ui.hovering(.{ .x = handle.x - 2, .y = rect.y, .width = bar_width + 4, .height = rect.height });
        widgets.rounded(.{ .x = handle.x, .y = rect.y + 2, .width = bar_width, .height = rect.height - 4 }, bar_width / 2, theme.colors.hover);
        widgets.rounded(handle, bar_width / 2, if (active) theme.colors.accent else theme.colors.line);
    }

    /// leva o conteúdo para o topo
    pub fn reset(area: *ScrollArea) void {
        area.offset = 0;
    }
};

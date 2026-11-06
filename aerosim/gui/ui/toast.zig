//! Os avisos por cima da janela: uma caixa laranja no canto de cima à direita, que some sozinha depois de uns
//! segundos ou com um clique. Quem roda uma conta chama `show` com o texto (a linha sustentadora numa asa curta, por
//! exemplo); o laço do programa (`app.zig`) desenha os avisos por cima de tudo em cada quadro.
//!
//!     toast.show("Rodar a linha sustentadora com AR < 4 pode fazer os valores divergirem");
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

/// quantos avisos cabem ao mesmo tempo (um novo empurra o mais velho)
pub const max_shown = 4;
/// quanto tempo cada aviso fica na tela (s)
pub const seconds_shown = 9.0;

const Notice = struct {
    text: [400:0]u8 = [_:0]u8{0} ** 400,
    until: f64 = 0,
    box: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, // onde saiu no último quadro
};

var notices: [max_shown]Notice = [_]Notice{.{}} ** max_shown;
var shown_count: usize = 0;

/// mostra `text` por `seconds_shown` segundos; o mesmo texto que já está na tela só ganha mais tempo
pub fn show(text: []const u8) void {
    const until = rl.getTime() + seconds_shown;
    for (notices[0..shown_count]) |*notice| if (std.mem.eql(u8, std.mem.sliceTo(&notice.text, 0), text)) {
        notice.until = until;
        return;
    };
    if (shown_count == max_shown) {
        std.mem.copyForwards(Notice, notices[0 .. max_shown - 1], notices[1..max_shown]);
        shown_count -= 1;
    }
    var notice: Notice = .{ .until = until };
    const length = @min(text.len, notice.text.len);
    @memcpy(notice.text[0..length], text[0..length]);
    notices[shown_count] = notice;
    shown_count += 1;
}

/// quantos avisos estão na tela
pub fn count() usize {
    return shown_count;
}

/// antes da tela: um clique num aviso fecha ele, e a tela de baixo não recebe o clique
pub fn takeClick(ui: *widgets.Ui) void {
    if (!ui.clicked or ui.click_taken) return;
    for (notices[0..shown_count], 0..) |notice, index| if (ui.hovering(notice.box)) {
        ui.click_taken = true;
        std.mem.copyForwards(Notice, notices[index .. shown_count - 1], notices[index + 1 .. shown_count]);
        shown_count -= 1;
        return;
    };
}

/// desenha os avisos no canto de cima à direita de uma janela `width` × `height`
pub fn draw(ui: *widgets.Ui, width: f32, height: f32) void {
    _ = height;
    const now = rl.getTime();
    var kept: usize = 0;
    for (notices[0..shown_count]) |notice| if (notice.until > now) {
        notices[kept] = notice;
        kept += 1;
    };
    shown_count = kept;
    const box_width = @min(480, width - 32);
    const x = width - box_width - 16;
    var y: f32 = 96;
    for (notices[0..shown_count]) |*notice| {
        const text = std.mem.sliceTo(&notice.text, 0);
        const text_height = widgets.paragraphHeight(ui.fonts.regular, text, box_width - 24, 14);
        const box: rl.Rectangle = .{ .x = x, .y = y, .width = box_width, .height = text_height + 40 };
        widgets.rounded(box, 6, theme.hex(0xfff4e0));
        widgets.roundedLines(box, 6, theme.hex(0xe08a00));
        rl.drawRectangleRec(.{ .x = box.x, .y = box.y + 6, .width = 4, .height = box.height - 12 }, theme.hex(0xe08a00));
        theme.text(ui.fonts.bold, "Aviso", box.x + 12, box.y + 8, 14, theme.hex(0xa35a00));
        theme.text(ui.fonts.regular, "clique para fechar", box.x + box.width - 128, box.y + 9, 12, theme.colors.muted);
        _ = widgets.paragraph(ui.fonts.regular, text, box.x + 12, box.y + 28, box_width - 24, 14, theme.colors.ink);
        notice.box = box;
        y += box.height + 8;
    }
}

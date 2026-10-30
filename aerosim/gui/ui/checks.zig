//! O diagnóstico de uma etapa, como o `ChecksPanel` da GUI em Python: uma linha por verificação (estado, o que se
//! verificou, o valor e o limite), as falhas primeiro, e embaixo o porquê e o que fazer da linha selecionada. As
//! etapas do dimensionamento (Asa, Empenagem, Motores...) e as análises usam o mesmo painel.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

/// uma verificação: o estado, o item, o valor achado, o limite (critério), o porquê, o que fazer e de onde vem
pub const Check = struct {
    status: widgets.Status,
    item: []const u8,
    value: []const u8 = "",
    criterion: []const u8 = "",
    why: []const u8 = "",
    fix: []const u8 = "",
    source: []const u8 = "",
};

pub const max_checks = 24;
const row_height: f32 = 26;
const detail_height: f32 = 64;

/// o texto do estado, como na GUI em Python
pub fn statusText(status: widgets.Status) [:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .atencao => "atenção",
        .falha => "falha",
        .info => "info",
    };
}

fn rank(status: widgets.Status) u8 {
    return switch (status) {
        .falha => 0,
        .atencao => 1,
        .ok => 2,
        .info => 3,
    };
}

/// o painel: guarda só a linha selecionada
pub const ChecksPanel = struct {
    selected: usize = 0,

    /// a altura que o painel ocupa com `count` verificações
    pub fn height(count: usize) f32 {
        return 34 + 26 + row_height * @as(f32, @floatFromInt(count)) + detail_height + 8;
    }

    /// desenha as verificações num cartão em `rect` (as falhas primeiro); clicar numa linha mostra o detalhe dela
    pub fn draw(panel: *ChecksPanel, ui: *widgets.Ui, rect: rl.Rectangle, checks: []const Check) void {
        const inner = widgets.labeledCard(ui, rect, "Diagnóstico");
        widgets.helpMark(ui, rect.x + 16 + theme.textWidth(ui.fonts.regular, "Diagnóstico", 16) + 8, rect.y + 11, "clique numa linha para ver o porquê e o que mudar");
        // a ordem: falha, atenção, ok, info (estável dentro de cada estado)
        var order: [max_checks]usize = undefined;
        const count = @min(checks.len, max_checks);
        for (0..count) |k| order[k] = k;
        std.sort.insertion(usize, order[0..count], checks, struct {
            fn less(list: []const Check, a: usize, b: usize) bool {
                return rank(list[a].status) < rank(list[b].status);
            }
        }.less);
        panel.selected = @min(panel.selected, count -| 1);
        const columns = [_]f32{ inner.x + 4, inner.x + 84, inner.x + inner.width * 0.45, inner.x + inner.width * 0.72 };
        const headers = [_][:0]const u8{ "estado", "verificação", "valor", "limite" };
        for (headers, columns) |caption, x| theme.text(ui.fonts.regular, caption, x + 4, inner.y, 13, theme.colors.muted);
        var y = inner.y + 22;
        var texts: [3][160]u8 = undefined;
        for (order[0..count], 0..) |index, k| {
            const check = checks[index];
            const line: rl.Rectangle = .{ .x = inner.x, .y = y, .width = inner.width, .height = row_height };
            if (k == panel.selected) rl.drawRectangleRec(line, theme.colors.selected);
            widgets.rounded(.{ .x = columns[0], .y = y + 3, .width = 72, .height = row_height - 6 }, 4, theme.withAlpha(widgets.statusColor(check.status), 0.25));
            theme.text(ui.fonts.regular, statusText(check.status), columns[0] + 8, y + 5, 13, theme.colors.ink);
            const cells = [_][]const u8{ check.item, check.value, check.criterion };
            for (cells, 1..) |cell, c| {
                const right = if (c + 1 < columns.len) columns[c + 1] else inner.x + inner.width;
                const box: rl.Rectangle = .{ .x = columns[c], .y = y, .width = right - columns[c] - 6, .height = row_height };
                ui.pushClip(box);
                theme.text(ui.fonts.regular, widgets.format(&texts[c - 1], "{s}", .{cell}), columns[c] + 4, y + 5, 13, theme.colors.ink);
                ui.popClip();
            }
            if (ui.clickedIn(line)) panel.selected = k;
            y += row_height;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 1, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
        if (count == 0) return;
        // o detalhe da linha selecionada
        const check = checks[order[panel.selected]];
        var detail: [600]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&detail);
        writer.print("{s}", .{check.item}) catch {};
        if (check.why.len > 0) writer.print(" · por quê: {s}", .{check.why}) catch {};
        if (check.fix.len > 0) writer.print(" · o que fazer: {s}", .{check.fix}) catch {};
        if (check.source.len > 0) writer.print(" · critério: {s}", .{check.source}) catch {};
        _ = widgets.paragraph(ui.fonts.regular, writer.buffered(), inner.x + 4, y + 8, inner.width - 8, 13, theme.colors.label);
    }
};

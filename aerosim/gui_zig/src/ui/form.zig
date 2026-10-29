//! O formulário lateral: campos agrupados (cada grupo com a faixa preta e a borda laranja, abre e fecha no
//! clique), número, marcador e escolha. A tela descreve os campos numa lista (o equivalente do `ParamSpec` do
//! aerosim em Python) e o mesmo código desenha o formulário de qualquer aba. A edição de número e a lista de
//! escolhas são do raygui.
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const numbers = @import("numbers.zig");
const numberText = numbers.numberText;

pub const Kind = enum { number, toggle, choice };

/// um campo do formulário
pub const Field = struct {
    label: [:0]const u8,
    unit: [:0]const u8 = "",
    group: usize, // índice em `Form.groups`
    kind: Kind = .number,
    number: f64 = 0,
    minimum: f64 = -std.math.inf(f64),
    maximum: f64 = std.math.inf(f64),
    checked: bool = false,
    choices: [:0]const u8 = "", // opções separadas por ";" (o formato do raygui)
    choice: i32 = 0,
};

pub const Group = struct {
    title: [:0]const u8,
    open: bool = true,
};

const row_height: f32 = 30;
const band_height: f32 = 30;
const control_width: f32 = 132;

/// estado do formulário entre quadros: rolagem e o campo em edição
pub const Form = struct {
    groups: []Group,
    fields: []Field,
    scroll: f32 = 0,
    editing: ?usize = null, // número sendo digitado
    open_choice: ?usize = null, // escolha com a lista aberta
    edit_text: [32:0]u8 = [_:0]u8{0} ** 32,

    /// altura total do conteúdo (para a rolagem)
    pub fn contentHeight(form: *const Form) f32 {
        var height: f32 = 8;
        for (form.groups, 0..) |group, g| {
            height += band_height + 10;
            if (group.open) height += row_height * @as(f32, @floatFromInt(form.countIn(g))) + 6;
        }
        return height;
    }

    fn countIn(form: *const Form, group_index: usize) usize {
        var count: usize = 0;
        for (form.fields) |field| count += @intFromBool(field.group == group_index);
        return count;
    }

    /// desenha o formulário em `rect`; devolve verdadeiro se algum valor mudou
    pub fn draw(form: *Form, ui: *widgets.Ui, rect: rl.Rectangle) bool {
        var changed = false;
        // a lista aberta fica por cima de tudo e pega o clique antes dos campos
        const choice_rect = if (form.open_choice) |i| form.fieldRect(rect, i) else null;
        if (choice_rect) |r| {
            const options = std.mem.count(u8, form.fields[form.open_choice.?].choices, ";") + 1;
            const list: rl.Rectangle = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height * @as(f32, @floatFromInt(options + 1)) };
            if (ui.hovering(list) and ui.clicked) ui.click_taken = true;
        }
        if (ui.hovering(rect) and form.open_choice == null) {
            const visible = rect.height;
            const max_scroll = @max(0, form.contentHeight() - visible);
            form.scroll = std.math.clamp(form.scroll - ui.wheel * 40, 0, max_scroll);
        }
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        var y = rect.y + 8 - form.scroll;
        for (form.groups, 0..) |*group, g| {
            const band: rl.Rectangle = .{ .x = rect.x + 10, .y = y, .width = rect.width - 20, .height = band_height };
            rl.drawRectangleRec(band, theme.colors.band);
            rl.drawRectangleRec(.{ .x = band.x, .y = band.y, .width = 5, .height = band.height }, theme.colors.accent);
            const arrow: [:0]const u8 = if (group.open) "▼" else "▸";
            theme.text(ui.fonts.bold, arrow, band.x + 14, band.y + 8, 12, theme.colors.band_text);
            theme.text(ui.fonts.bold, group.title, band.x + 32, band.y + 8, 13, theme.colors.band_text);
            if (ui.clickedIn(band)) group.open = !group.open;
            y += band_height;
            if (group.open) {
                const body: rl.Rectangle = .{ .x = band.x, .y = y, .width = band.width, .height = row_height * @as(f32, @floatFromInt(form.countIn(g))) + 6 };
                rl.drawRectangleRec(body, theme.colors.panel);
                y += 3;
                for (form.fields, 0..) |*field, i| {
                    if (field.group != g) continue;
                    changed = form.drawField(ui, i, field, band.x + 10, y, band.width - 20) or changed;
                    y += row_height;
                }
                y += 3;
            }
            y += 10;
        }
        rl.endScissorMode();
        if (form.open_choice) |i| changed = form.drawOpenChoice(ui, i, rect) or changed;
        return changed;
    }

    /// onde fica o controle do campo `index` (para a lista aberta, desenhada por cima)
    fn fieldRect(form: *const Form, rect: rl.Rectangle, index: usize) ?rl.Rectangle {
        var y = rect.y + 8 - form.scroll;
        for (form.groups, 0..) |group, g| {
            y += band_height;
            if (group.open) {
                y += 3;
                for (form.fields, 0..) |field, i| {
                    if (field.group != g) continue;
                    if (i == index) return .{ .x = rect.x + rect.width - 20 - control_width, .y = y + 3, .width = control_width, .height = row_height - 6 };
                    y += row_height;
                }
                y += 3;
            }
            y += 10;
        }
        return null;
    }

    fn drawField(form: *Form, ui: *widgets.Ui, index: usize, field: *Field, x: f32, y: f32, width: f32) bool {
        var buffer: [96]u8 = undefined;
        const control: rl.Rectangle = .{ .x = x + width - control_width, .y = y + 3, .width = control_width, .height = row_height - 6 };
        switch (field.kind) {
            .toggle => {
                const box: rl.Rectangle = .{ .x = x, .y = y + 7, .width = 16, .height = 16 };
                rl.drawRectangleRec(box, if (field.checked) theme.colors.accent else theme.colors.field);
                rl.drawRectangleLinesEx(box, 1, if (field.checked) theme.colors.accent else theme.colors.line);
                if (field.checked) theme.text(ui.fonts.bold, "✓", box.x + 2, box.y - 1, 15, theme.colors.on_accent);
                theme.text(ui.fonts.regular, field.label, x + 26, y + 7, 14, theme.colors.label);
                const row: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = row_height };
                if (ui.clickedIn(row)) {
                    field.checked = !field.checked;
                    return true;
                }
                return false;
            },
            .number, .choice => {
                const caption = if (field.unit.len > 0) widgets.format(&buffer, "{s} ({s})", .{ field.label, field.unit }) else field.label;
                theme.text(ui.fonts.regular, caption, x, y + 7, 14, theme.colors.label);
            },
        }
        if (field.kind == .choice) {
            rl.drawRectangleRec(control, theme.colors.field);
            rl.drawRectangleRec(.{ .x = control.x, .y = control.y + control.height - 2, .width = control.width, .height = 2 }, theme.colors.accent);
            var options = std.mem.splitScalar(u8, field.choices, ';');
            var k: i32 = 0;
            var current: []const u8 = "";
            while (options.next()) |option| : (k += 1) {
                if (k == field.choice) current = option;
            }
            var text_buffer: [96]u8 = undefined;
            const shown = widgets.format(&text_buffer, "{s}", .{current});
            rl.beginScissorMode(@intFromFloat(control.x), @intFromFloat(control.y), @intFromFloat(control.width - 18), @intFromFloat(control.height));
            theme.text(ui.fonts.mono, shown, control.x + 6, control.y + 5, 14, theme.colors.ink);
            rl.endScissorMode();
            theme.text(ui.fonts.bold, "▼", control.x + control.width - 16, control.y + 6, 11, theme.colors.accent);
            if (ui.clickedIn(control)) form.open_choice = index;
            return false;
        }
        // número: o raygui edita o texto; fora da edição, o valor em fonte monoespaçada
        if (form.editing == index) {
            const done = rg.textBox(control, &form.edit_text, true);
            if (done) {
                form.editing = null;
                const typed = std.mem.sliceTo(&form.edit_text, 0);
                const value = std.fmt.parseFloat(f64, std.mem.trim(u8, typed, " ")) catch return false;
                field.number = std.math.clamp(value, field.minimum, field.maximum);
                return true;
            }
            return false;
        }
        rl.drawRectangleRec(control, theme.colors.field);
        rl.drawRectangleRec(.{ .x = control.x, .y = control.y + control.height - 2, .width = control.width, .height = 2 }, theme.colors.accent);
        theme.text(ui.fonts.mono, numberText(&buffer, field.number), control.x + 6, control.y + 5, 14, theme.colors.ink);
        if (ui.clickedIn(control)) {
            form.editing = index;
            form.edit_text = [_:0]u8{0} ** 32;
            const typed = numberText(&buffer, field.number);
            @memcpy(form.edit_text[0..typed.len], typed);
        }
        return false;
    }

    fn drawOpenChoice(form: *Form, ui: *widgets.Ui, index: usize, rect: rl.Rectangle) bool {
        const field = &form.fields[index];
        const control = form.fieldRect(rect, index) orelse {
            form.open_choice = null;
            return false;
        };
        var active: i32 = field.choice;
        const pressed = rg.dropdownBox(control, field.choices, &active, true);
        if (pressed != 0) {
            form.open_choice = null;
            const changed = active != field.choice;
            field.choice = active;
            return changed;
        }
        _ = ui;
        return false;
    }
};

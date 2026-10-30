//! O formulário lateral: campos agrupados (cada grupo com o título em azul, abre e fecha no clique), número, marcador e escolha. A tela descreve os campos numa lista (o equivalente do `ParamSpec` do
//! aerosim em Python) e o mesmo código desenha o formulário de qualquer aba. A edição de número e a lista de
//! escolhas são do raygui.
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const scroll = @import("scroll.zig");
const numbers = @import("numbers.zig");
const numberText = numbers.numberText;

pub const Kind = enum { number, toggle, choice, text };

/// a caixa de um valor: branca, de cantos arredondados, borda fina
fn fieldBox(control: rl.Rectangle) void {
    widgets.rounded(control, 5, theme.colors.field);
    widgets.roundedLines(control, 5, theme.colors.line);
}

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
    text: [48:0]u8 = [_:0]u8{0} ** 48, // o valor de um campo de texto (um nome)
    enabled: bool = true, // desligado: aparece em cinza e não edita (o campo que outro modo calcula)
    help: [:0]const u8 = "", // a dica com o mouse em cima do rótulo

    /// o texto de um campo de texto
    pub fn textValue(field: *const Field) []const u8 {
        return std.mem.sliceTo(&field.text, 0);
    }

    /// troca o texto de um campo de texto
    pub fn setText(field: *Field, value: []const u8) void {
        field.text = [_:0]u8{0} ** 48;
        const length = @min(value.len, 47);
        @memcpy(field.text[0..length], value[0..length]);
    }
};

pub const Group = struct {
    title: [:0]const u8,
    open: bool = true,
};

const row_height: f32 = 30;
const band_height: f32 = 30;
const control_width: f32 = 112;

/// estado do formulário entre quadros: rolagem e o campo em edição
pub const Form = struct {
    groups: []Group,
    fields: []Field,
    area: scroll.ScrollArea = .{},
    editing: ?usize = null, // número sendo digitado
    open_choice: ?usize = null, // escolha com a lista aberta
    opening: bool = false, // a lista abriu neste quadro (o raygui veria o mesmo clique e fecharia)
    edit_text: [32:0]u8 = [_:0]u8{0} ** 32,
    origin: rl.Vector2 = .{ .x = 0, .y = 0 }, // onde o formulário foi desenhado no último quadro
    width: f32 = 0,

    /// altura total do conteúdo
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

    /// desenha o formulário em `rect`, com a rolagem própria; devolve verdadeiro se algum valor mudou
    pub fn draw(form: *Form, ui: *widgets.Ui, rect: rl.Rectangle) bool {
        const top = form.area.begin(ui, rect);
        var changed = form.drawAt(ui, rect.x, top, rect.width);
        form.area.end(ui, rect, top + form.contentHeight());
        changed = form.drawOpen(ui) or changed;
        return changed;
    }

    /// desenha o formulário a partir de (x, y), sem rolagem própria (dentro de uma área rolável de quem chama, que
    /// soma `contentHeight` ao y). Depois de fechar o recorte, chamar `drawOpen` para a lista aberta ficar por cima
    pub fn drawAt(form: *Form, ui: *widgets.Ui, x: f32, top: f32, width: f32) bool {
        form.origin = .{ .x = x, .y = top };
        form.width = width;
        var changed = false;
        // a lista aberta fica por cima de tudo e pega o clique antes dos campos (mesmo fora do recorte)
        if (form.open_choice) |index| {
            if (form.fieldRect(index)) |r| {
                const options = std.mem.count(u8, form.fields[index].choices, ";") + 1;
                const list: rl.Rectangle = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height * @as(f32, @floatFromInt(options + 1)) };
                if (ui.clicked and rl.checkCollisionPointRec(ui.mouse, list)) ui.click_taken = true;
            }
        }
        var y = top + 8;
        for (form.groups, 0..) |*group, g| {
            const band: rl.Rectangle = .{ .x = x + 10, .y = y, .width = width - 20, .height = band_height };
            if (ui.hovering(band)) widgets.rounded(band, 7, theme.colors.hover);
            widgets.disclosure(band.x + 14, band.y + band_height / 2, 9, group.open, theme.colors.accent);
            theme.text(ui.fonts.regular, group.title, band.x + 28, band.y + 6, 16, theme.colors.accent);
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
        return changed;
    }

    /// a lista aberta de uma escolha, por cima do resto (fora de qualquer recorte)
    pub fn drawOpen(form: *Form, ui: *widgets.Ui) bool {
        const index = form.open_choice orelse return false;
        return form.drawOpenChoice(ui, index);
    }

    /// onde fica o controle do campo `index` (para a lista aberta, desenhada por cima)
    fn fieldRect(form: *const Form, index: usize) ?rl.Rectangle {
        const x = form.origin.x + 10;
        const width = form.width - 20;
        var y = form.origin.y + 8;
        for (form.groups, 0..) |group, g| {
            y += band_height;
            if (group.open) {
                y += 3;
                for (form.fields, 0..) |field, i| {
                    if (field.group != g) continue;
                    if (i == index) return .{ .x = x + 10 + width - 20 - control_width, .y = y + 3, .width = control_width, .height = row_height - 6 };
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
        const label_color = if (field.enabled) theme.colors.label else theme.colors.muted;
        ui.tooltip(.{ .x = x, .y = y, .width = width - control_width - 4, .height = row_height }, field.help);
        if (!field.enabled) {
            if (form.editing == index) form.editing = null;
            if (form.open_choice == index) form.open_choice = null;
        }
        switch (field.kind) {
            .toggle => {
                widgets.checkBox(.{ .x = x, .y = y + 7, .width = 16, .height = 16 }, field.checked);
                theme.text(ui.fonts.regular, field.label, x + 26, y + 7, 14, label_color);
                const row: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = row_height };
                if (field.enabled and ui.clickedIn(row)) {
                    field.checked = !field.checked;
                    return true;
                }
                return false;
            },
            .number, .choice, .text => {
                const caption = if (field.unit.len > 0) widgets.format(&buffer, "{s} ({s})", .{ field.label, field.unit }) else field.label;
                theme.text(ui.fonts.regular, caption, x, y + 7, 14, label_color);
            },
        }
        if (field.kind == .text) {
            if (form.editing == index) {
                if (rg.textBox(control, &field.text, true)) {
                    form.editing = null;
                    return true;
                }
                return false;
            }
            fieldBox(control);
            ui.pushClip(control);
            theme.text(ui.fonts.mono, field.text[0..field.textValue().len :0], control.x + 6, control.y + 5, 14, if (field.enabled) theme.colors.ink else theme.colors.muted);
            ui.popClip();
            if (field.enabled and ui.clickedIn(control)) {
                form.editing = index;
                widgets.caretToEnd(ui, &field.text);
            }
            return false;
        }
        if (field.kind == .choice) {
            fieldBox(control);
            var options = std.mem.splitScalar(u8, field.choices, ';');
            var k: i32 = 0;
            var current: []const u8 = "";
            while (options.next()) |option| : (k += 1) {
                if (k == field.choice) current = option;
            }
            var text_buffer: [96]u8 = undefined;
            const shown = widgets.format(&text_buffer, "{s}", .{current});
            ui.pushClip(.{ .x = control.x, .y = control.y, .width = control.width - 18, .height = control.height });
            theme.text(ui.fonts.mono, shown, control.x + 6, control.y + 5, 14, if (field.enabled) theme.colors.ink else theme.colors.muted);
            ui.popClip();
            widgets.disclosure(control.x + control.width - 11, control.y + control.height / 2, 8, true, theme.colors.muted);
            if (field.enabled and ui.clickedIn(control)) {
                form.open_choice = index;
                form.opening = true;
            }
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
        if (field.enabled) fieldBox(control) else widgets.rounded(control, 5, theme.colors.panel);
        theme.text(ui.fonts.mono, numberText(&buffer, field.number), control.x + 6, control.y + 5, 14, if (field.enabled) theme.colors.ink else theme.colors.muted);
        if (field.enabled and ui.clickedIn(control)) {
            form.editing = index;
            form.edit_text = [_:0]u8{0} ** 32;
            const typed = numberText(&buffer, field.number);
            @memcpy(form.edit_text[0..typed.len], typed);
            widgets.caretToEnd(ui, &form.edit_text);
        }
        return false;
    }

    fn drawOpenChoice(form: *Form, ui: *widgets.Ui, index: usize) bool {
        const field = &form.fields[index];
        const control = form.fieldRect(index) orelse {
            form.open_choice = null;
            return false;
        };
        if (form.opening) { // no quadro em que abriu, o clique é o de abrir
            form.opening = false;
            return false;
        }
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

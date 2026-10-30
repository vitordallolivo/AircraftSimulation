//! A janela "Condições e restrições…", como o `RequirementsDialog` da GUI em Python: quatro abas que editam o
//! projeto no lugar (cada mudança refaz as etapas). Condições: massa de partida, velocidade, altitude-densidade e
//! pista. Restrições: uma linha por restrição (ativa, grandeza, operador, valor, unidade, o último valor calculado e
//! se cumpre), com "+ restrição" e "− restrição". Variáveis: cada entrada de projeto fixa, variável (com mín. e máx.,
//! ou as opções de uma lista) ou calculada, e "Limites a partir das restrições". Regras de projeto: massas, fuselagem,
//! trem e cursos dos comandos. Qualquer etapa abre a janela pela barra de requisitos.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const table_mod = ui_kit.table;
const design_mod = @import("design.zig");
const registry = design_mod.registry;

const Field = form_mod.Field;

/// um campo do formulário ligado a um número de uma struct (pelo nome do campo dela)
const Binding = struct { name: []const u8, field: Field };

const condition_bindings = [_]Binding{
    .{ .name = "mass", .field = .{ .label = "massa estimada (ponto de partida)", .unit = "kg", .group = 0, .minimum = 0.2, .maximum = 60, .help = "dá o C_L de cruzeiro e a carga alar das primeiras etapas; o ponto de projeto acerta a massa de verdade (o MTOW é saída, não requisito)" } },
    .{ .name = "airspeed", .field = .{ .label = "velocidade de cruzeiro", .unit = "m/s", .group = 0, .minimum = 3, .maximum = 60 } },
    .{ .name = "altitude", .field = .{ .label = "altitude-densidade (AD)", .unit = "m", .group = 0, .minimum = -500, .maximum = 4000, .help = "atmosfera padrão com a densidade do dia" } },
    .{ .name = "rolling_friction", .field = .{ .label = "atrito de rolamento", .group = 0, .minimum = 0, .maximum = 0.3, .help = "pista: grama ≈ 0,08, asfalto ≈ 0,03" } },
    .{ .name = "turn_speed", .field = .{ .label = "V da curva", .unit = "m/s", .group = 0, .minimum = 0, .maximum = 60, .help = "a velocidade da curva sustentada (restrição de fator de carga); 0 = a de cruzeiro" } },
    .{ .name = "brake_friction", .field = .{ .label = "atrito na frenagem", .group = 0, .minimum = 0.05, .maximum = 1, .help = "pouso: rodas freando na pista" } },
    .{ .name = "obstacle_height", .field = .{ .label = "altura do obstáculo", .unit = "m", .group = 0, .minimum = 0, .maximum = 5, .help = "a decolagem 6GDL só vale se passar desta altura no fim da corrida (z_warning); a Regular 2026 pede 0,90 m a 55 m, R[7.8.0.1]" } },
};

const rule_bindings = [_]Binding{
    .{ .name = "wing_density", .field = .{ .label = "massa da asa por área", .unit = "kg/m²", .group = 0, .minimum = 0.1, .maximum = 6, .help = "estrutura + entelagem" } },
    .{ .name = "tail_density", .field = .{ .label = "massa da empenagem por área", .unit = "kg/m²", .group = 0, .minimum = 0.1, .maximum = 6 } },
    .{ .name = "boom_density", .field = .{ .label = "massa do tubo por metro", .unit = "kg/m", .group = 0, .minimum = 0.01, .maximum = 2 } },
    .{ .name = "fuselage_width", .field = .{ .label = "largura da fuselagem", .unit = "m", .group = 1, .minimum = 0.03, .maximum = 0.6, .help = "pod do nariz até o bordo de fuga da asa" } },
    .{ .name = "fuselage_height", .field = .{ .label = "altura da fuselagem", .unit = "m", .group = 1, .minimum = 0.03, .maximum = 0.6 } },
    .{ .name = "fuselage_drag", .field = .{ .label = "C_D da fuselagem (área molhada)", .group = 1, .minimum = 0.005, .maximum = 0.2, .help = "pod curto com trem: ≈ 0,04" } },
    .{ .name = "fuselage_density", .field = .{ .label = "massa da fuselagem por metro", .unit = "kg/m", .group = 1, .minimum = 0.05, .maximum = 5 } },
    .{ .name = "systems_mass", .field = .{ .label = "sistemas", .unit = "kg", .group = 0, .minimum = 0, .maximum = 5, .help = "receptor, servos, fiação" } },
    .{ .name = "gear_mass", .field = .{ .label = "trem de pouso", .unit = "kg", .group = 0, .minimum = 0, .maximum = 5 } },
    .{ .name = "nose_length", .field = .{ .label = "nariz à frente da asa", .unit = "m", .group = 1, .minimum = 0.05, .maximum = 1.5, .help = "do bordo de ataque da asa até a hélice (tratora)" } },
    .{ .name = "wing_height", .field = .{ .label = "altura da asa", .unit = "m", .group = 1, .minimum = -0.5, .maximum = 0.5, .help = "z do bordo de ataque (− = acima da fuselagem)" } },
    .{ .name = "propeller_clearance", .field = .{ .label = "folga da hélice ao chão", .unit = "m", .group = 2, .minimum = 0, .maximum = 0.5 } },
    .{ .name = "main_gear_aft", .field = .{ .label = "trem principal atrás do CG", .unit = "m", .group = 2, .minimum = 0, .maximum = 0.5, .help = "≈ 15° de tombamento" } },
    .{ .name = "track", .field = .{ .label = "bitola do trem", .unit = "m", .group = 2, .minimum = 0.1, .maximum = 2 } },
    .{ .name = "elevator_up", .field = .{ .label = "profundor: curso para cabrar", .unit = "°", .group = 3, .minimum = 5, .maximum = 40, .help = "bordo de fuga para cima (rotação, C_L,max)" } },
    .{ .name = "elevator_down", .field = .{ .label = "profundor: curso para picar", .unit = "°", .group = 3, .minimum = 2, .maximum = 40, .help = "cursos assimétricos: picar costuma ser menor; segura o nariz na corrida do motor inclinado" } },
    .{ .name = "aileron_up", .field = .{ .label = "aileron: curso para cima", .unit = "°", .group = 3, .minimum = 5, .maximum = 40 } },
    .{ .name = "aileron_down", .field = .{ .label = "aileron: curso para baixo", .unit = "°", .group = 3, .minimum = 2, .maximum = 40, .help = "aileron diferencial: desce menos do que sobe (menos guinada adversa)" } },
};

fn fieldsOf(comptime bindings: []const Binding) [bindings.len]Field {
    var out: [bindings.len]Field = undefined;
    for (bindings, 0..) |binding, k| out[k] = binding.field;
    return out;
}

/// os campos de `bindings` recebem os números de `source` (e devolvem com `store`)
fn load(comptime bindings: []const Binding, fields: []Field, source: anytype) void {
    inline for (bindings, 0..) |binding, k| fields[k].number = @field(source, binding.name);
}

fn store(comptime bindings: []const Binding, fields: []const Field, target: anytype) void {
    inline for (bindings, 0..) |binding, k| @field(target, binding.name) = fields[k].number;
}

const tabs = [_][:0]const u8{ "Condições", "Restrições", "Variáveis", "Regras de projeto" };

const constraint_columns = [_]table_mod.Column{
    .{ .title = "ativa", .kind = .check, .width = 0.07 },
    .{ .title = "grandeza", .kind = .choice, .width = 0 },
    .{ .title = "op.", .kind = .choice, .width = 0.07 },
    .{ .title = "valor", .kind = .number, .width = 0.11 },
    .{ .title = "unid.", .kind = .label, .width = 0.08 },
    .{ .title = "calculado", .kind = .label, .width = 0.11 },
    .{ .title = "situação", .kind = .label, .width = 0.14 },
};

const variable_columns = [_]table_mod.Column{
    .{ .title = "entrada", .kind = .label, .width = 0 },
    .{ .title = "modo", .kind = .choice, .width = 0.12 },
    .{ .title = "valor (fixo)", .kind = .text, .width = 0.16 },
    .{ .title = "mín.", .kind = .number, .width = 0.08 },
    .{ .title = "máx.", .kind = .number, .width = 0.08 },
    .{ .title = "opções (listas)", .kind = .button, .width = 0.2, .help = "escolher na lista (com busca); nada marcado = todos" },
};

/// as grandezas na ordem do registro, separadas por ";" (as opções da coluna "grandeza")
const quantity_choices: [:0]const u8 = blk: {
    var text: []const u8 = "";
    for (0..registry.quantity_count) |k| {
        const quantity: registry.Quantity = @enumFromInt(k);
        text = text ++ (if (k > 0) ";" else "") ++ quantity.info().label;
    }
    break :blk text ++ "";
};

pub const RequirementsDialog = struct {
    dialog: ui_kit.stage.TabbedDialog = .{},
    conditions: [condition_bindings.len]Field = fieldsOf(&condition_bindings),
    condition_groups: [1]form_mod.Group = .{.{ .title = "Condições de projeto" }},
    condition_form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    rules: [rule_bindings.len]Field = fieldsOf(&rule_bindings),
    rule_groups: [4]form_mod.Group = .{ .{ .title = "Massas" }, .{ .title = "Fuselagem e asa" }, .{ .title = "Trem de pouso" }, .{ .title = "Cursos dos comandos" } },
    rule_form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    constraint_table: table_mod.EditTable = .{},
    constraint_scroll: ui_kit.scroll.ScrollArea = .{},
    variable_scroll: ui_kit.scroll.ScrollArea = .{},
    variable_table: table_mod.EditTable = .{},
    picker: ui_kit.stage.ListPicker = .{},
    message: [300:0]u8 = [_:0]u8{0} ** 300,

    /// abre a janela (na aba em que estava)
    pub fn show(dialog: *RequirementsDialog) void {
        dialog.dialog.open = true;
        dialog.message[0] = 0;
    }

    /// a janela está aberta? (a tela de baixo não recebe o clique)
    pub fn isOpen(dialog: *const RequirementsDialog) bool {
        return dialog.dialog.open;
    }

    /// desenha a janela por cima de `screen` e aplica no projeto o que se editou
    pub fn draw(dialog: *RequirementsDialog, ui: *widgets.Ui, screen: rl.Rectangle, design: *design_mod.Design) void {
        if (dialog.picker.open) { // o seletor de opções fica por cima da janela
            const saved = ui.click_taken;
            ui.click_taken = true;
            dialog.drawBody(ui, screen, design);
            ui.click_taken = saved;
            if (dialog.picker.draw(ui, screen)) {
                var names: [ui_kit.stage.max_picks][]const u8 = undefined;
                const chosen = dialog.picker.selected(&names);
                design.variables[dialog.picker.owner].setOptions(chosen, dialog.picker.count);
                design.touch();
            }
            return;
        }
        dialog.drawBody(ui, screen, design);
    }

    fn drawBody(dialog: *RequirementsDialog, ui: *widgets.Ui, screen: rl.Rectangle, design: *design_mod.Design) void {
        const area = dialog.dialog.begin(ui, screen, "Condições, restrições e variáveis de projeto", &tabs) orelse return;
        switch (dialog.dialog.tab) {
            0 => {
                if (dialog.condition_form.fields.len == 0) dialog.condition_form = .{ .groups = &dialog.condition_groups, .fields = &dialog.conditions };
                load(&condition_bindings, &dialog.conditions, design.requirements);
                if (dialog.condition_form.draw(ui, area)) {
                    store(&condition_bindings, &dialog.conditions, &design.requirements);
                    design.touch();
                }
            },
            1 => dialog.drawConstraints(ui, area, design),
            2 => dialog.drawVariables(ui, area, design),
            else => {
                if (dialog.rule_form.fields.len == 0) dialog.rule_form = .{ .groups = &dialog.rule_groups, .fields = &dialog.rules };
                load(&rule_bindings, &dialog.rules, design.rules);
                if (dialog.rule_form.draw(ui, area)) {
                    store(&rule_bindings, &dialog.rules, &design.rules);
                    design.touch();
                }
            },
        }
        dialog.dialog.end(ui, screen);
    }

    fn drawConstraints(dialog: *RequirementsDialog, ui: *widgets.Ui, area: rl.Rectangle, design: *design_mod.Design) void {
        const note = "Restrições de projeto: ligue/desligue sem perder o valor. As etapas conferem as ativas no diagnóstico; o estudo marca como inviável o ponto que não cumpre. 'calculado' é o valor da última etapa que rodou.";
        var y = area.y + widgets.paragraph(ui.fonts.regular, note, area.x, area.y, area.width, 13, theme.colors.muted) + 6;
        const list = design.constraints.slice();
        var cells: [registry.max_constraints][constraint_columns.len]table_mod.Cell = undefined;
        var rows: [registry.max_constraints][]const table_mod.Cell = undefined;
        var texts: [registry.max_constraints][3][48:0]u8 = undefined;
        for (list, 0..) |constraint, r| {
            const info = constraint.quantity.info();
            const value = design.values[@intFromEnum(constraint.quantity)];
            var number: [32]u8 = undefined;
            const status: [:0]const u8 = if (!constraint.active) "desligada" else if (value == null) "—" else if (constraint.holds(value.?)) "✔ cumpre" else "✖ não cumpre";
            cells[r] = .{
                .{ .checked = constraint.active },
                .{ .choices = quantity_choices, .choice = @intCast(@intFromEnum(constraint.quantity)) },
                .{ .choices = "≤;≥;=", .choice = @intCast(@intFromEnum(constraint.op)) },
                .{ .number = constraint.value },
                .{ .text = widgets.format(&texts[r][0], "{s}", .{info.unit}) },
                .{ .text = if (value) |known| widgets.format(&texts[r][1], "{s}", .{registry.shortNumber(&number, known)}) else "—" },
                .{ .text = widgets.format(&texts[r][2], "{s}", .{status}), .color = if (std.mem.startsWith(u8, status, "✖")) theme.colors.failure else if (std.mem.startsWith(u8, status, "✔")) theme.colors.ok else null },
            };
            rows[r] = &cells[r];
        }
        const table_height = table_mod.height(list.len);
        const buttons_height: f32 = 40;
        // a tabela rola se não cabe
        const room = area.height - (y - area.y) - buttons_height;
        const shown: rl.Rectangle = .{ .x = area.x, .y = y, .width = area.width, .height = @min(room, table_height) };
        const top = dialog.constraint_scroll.begin(ui, shown);
        const edit = dialog.constraint_table.draw(ui, area.x, top, area.width - 12, &constraint_columns, rows[0..list.len]);
        dialog.constraint_scroll.end(ui, shown, top + table_height);
        y += shown.height + 8;
        var pressed: f32 = 0;
        const actions = [_][:0]const u8{ "+ restrição", "− restrição" };
        if (ui_kit.menus.buttonGrid(ui, area.x, y, @min(area.width, 360), &actions, 2, &pressed)) |button| {
            if (button == 0) {
                _ = design.constraints.add();
                dialog.constraint_table.selected = design.constraints.count - 1;
            } else if (dialog.constraint_table.selected) |row| design.constraints.remove(row);
            design.touch();
        }
        const open_edit = dialog.constraint_table.drawOpen(ui, &constraint_columns);
        if (edit orelse open_edit) |change| {
            const constraint = &design.constraints.items[change.row];
            switch (change.value) {
                .check => |on| constraint.active = on,
                .choice => |index| {
                    if (change.column == 1) constraint.quantity = @enumFromInt(@as(usize, @intCast(index))) else constraint.op = @enumFromInt(@as(usize, @intCast(index)));
                },
                .number => |value| constraint.value = value,
                else => {},
            }
            design.touch();
        }
    }

    fn drawVariables(dialog: *RequirementsDialog, ui: *widgets.Ui, area: rl.Rectangle, design: *design_mod.Design) void {
        const note = "Entradas de projeto: fixo = o valor do rascunho da etapa; variável = o otimizador procura entre mín. e máx. (listas: entre as opções); calculado = sai das contas (ex.: a massa, que o ponto de projeto acerta). PV e MTOW são saídas.";
        var y = area.y + widgets.paragraph(ui.fonts.regular, note, area.x, area.y, area.width, 13, theme.colors.muted) + 6;
        var cells: [registry.input_count][variable_columns.len]table_mod.Cell = undefined;
        var rows: [registry.input_count][]const table_mod.Cell = undefined;
        var texts: [registry.input_count][3][96:0]u8 = undefined;
        for (&design.variables, 0..) |*variable, r| {
            const info = variable.input.info();
            var number: [32]u8 = undefined;
            const current = if (info.list) design.inputText(variable.input) else ui_kit.numbers.numberText(&number, design.inputNumber(variable.input));
            cells[r] = .{
                .{ .text = if (info.list or info.unit.len == 0) widgets.format(&texts[r][0], "{s}", .{info.label}) else widgets.format(&texts[r][0], "{s} ({s})", .{ info.label, info.unit }) },
                .{ .choices = registry.mode_names, .choice = @intCast(@intFromEnum(variable.mode)) },
                .{ .text = widgets.format(&texts[r][1], "{s}", .{current}) },
                .{ .number = variable.low, .enabled = !info.list },
                .{ .number = variable.high, .enabled = !info.list },
                .{ .text = if (info.list) dialog.optionsText(&texts[r][2], design, variable) else "", .enabled = info.list },
            };
            rows[r] = &cells[r];
        }
        const room = area.height - (y - area.y) - 70;
        const table_height = table_mod.height(registry.input_count);
        const shown: rl.Rectangle = .{ .x = area.x, .y = y, .width = area.width, .height = @min(room, table_height) };
        const top = dialog.variable_scroll.begin(ui, shown);
        const edit = dialog.variable_table.draw(ui, area.x, top, area.width - 12, &variable_columns, &rows);
        dialog.variable_scroll.end(ui, shown, top + table_height);
        y += shown.height + 8;
        if (ui_kit.dialogs.button(ui, .{ .x = area.x, .y = y, .width = 280, .height = 30 }, "Limites a partir das restrições")) {
            var changed: [registry.input_count]bool = undefined;
            const count = registry.boundsFromConstraints(&design.constraints, &design.variables, &changed);
            var writer: std.Io.Writer = .fixed(dialog.message[0 .. dialog.message.len - 1]);
            writer.writeAll("limites das restrições: ") catch {};
            if (count == 0) writer.writeAll("nenhuma restrição ativa limita uma variável (envergadura, área, nº de motores)") catch {};
            var first = true;
            for (changed, 0..) |on, k| {
                if (!on) continue;
                const variable = design.variables[k];
                writer.print("{s}{s}: {d}…{d}", .{ if (first) "" else "; ", variable.input.info().label, variable.low, variable.high }) catch {};
                first = false;
            }
            dialog.message[writer.end] = 0;
            design.touch();
        }
        ui.tooltip(.{ .x = area.x, .y = y, .width = 280, .height = 30 }, "as restrições ativas viram limites: envergadura ≤ → máx. da envergadura, área ≥/≤ → mín./máx. da área, nº de motores → mín./máx. de motores");
        theme.text(ui.fonts.regular, std.mem.sliceTo(&dialog.message, 0), area.x, y + 38, 13, theme.colors.muted);
        const open_edit = dialog.variable_table.drawOpen(ui, &variable_columns);
        if (edit orelse open_edit) |change| {
            const variable = &design.variables[change.row];
            switch (change.value) {
                .choice => |index| variable.mode = @enumFromInt(@as(usize, @intCast(index))),
                .number => |value| {
                    if (change.column == 3) variable.low = value else variable.high = value;
                },
                .text => |typed| {
                    if (variable.input.info().list) design.setInputText(variable.input, typed) else {
                        const value = std.fmt.parseFloat(f64, typed) catch return;
                        design.setInputNumber(variable.input, value);
                    }
                },
                .pressed => {
                    var names: [ui_kit.stage.max_picks][]const u8 = undefined;
                    const all = design.available(variable.input, &names);
                    var chosen: [registry.max_options][]const u8 = undefined;
                    for (0..variable.option_count) |k| chosen[k] = variable.option(k);
                    dialog.picker.show(variable.input.info().label, all, chosen[0..variable.option_count], change.row);
                },
                else => {},
            }
            design.touch();
        }
    }

    /// o texto do botão de opções: "todos (n) …" ou "2 de 5: a, b"
    fn optionsText(dialog: *const RequirementsDialog, buffer: *[96:0]u8, design: *const design_mod.Design, variable: *const registry.Variable) [:0]const u8 {
        _ = dialog;
        var names: [ui_kit.stage.max_picks][]const u8 = undefined;
        const total = design.available(variable.input, &names).len;
        if (variable.option_count == 0) return widgets.format(buffer, "todos ({d}) …", .{total});
        var list: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&list);
        for (0..variable.option_count) |k| writer.print("{s}{s}", .{ if (k > 0) ", " else "", variable.option(k) }) catch break;
        const joined = writer.buffered();
        if (joined.len < 40) return widgets.format(buffer, "{d} de {d}: {s}", .{ variable.option_count, total, joined });
        return widgets.format(buffer, "{d} de {d}: {s}…", .{ variable.option_count, total, joined[0..37] });
    }
};

//! A aba Aerodinâmica → Perfis: os perfis candidatos e a polar 2D de cada um, como a página Perfis da GUI em
//! Python. À esquerda, quais candidatos entram (os do avião aberto, os da biblioteca `data/airfoils`, os `.dat` e
//! as polares do XFLR5 arrastados para a janela, um NACA pelo código) e o caso que dá o Reynolds; à direita, c_l,
//! a polar, c_l/c_d e c_m em α, o contorno, o diagnóstico e a tabela dos números. A conta é a de
//! `airfoil_stage.zig` (e do núcleo, `physics/section.zig`).
const std = @import("std");
const rl = @import("raylib");
const aircraft_model = @import("aircraft_model");
const core = @import("aerosim");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const stage = @import("airfoil_stage.zig");
const assembly_mod = @import("assembly.zig");

const model = aircraft_model.aircraft;
const section = core.section;
const max_candidates = stage.max_candidates;

const Group = enum(usize) { aircraft, library, dropped, case };

/// os campos fixos (depois dos candidatos)
const FieldId = enum(usize) { naca, airspeed, chord, density };

const fixed_fields = [_]form_mod.Field{
    .{ .label = "código NACA (0: nenhum)", .group = @intFromEnum(Group.case), .number = 0, .minimum = 0, .maximum = 9999 },
    .{ .label = "velocidade de cruzeiro", .unit = "m/s", .group = @intFromEnum(Group.case), .number = 12, .minimum = 2, .maximum = 80 },
    .{ .label = "corda de referência", .unit = "m", .group = @intFromEnum(Group.case), .number = 0.3, .minimum = 0.02, .maximum = 3 },
    .{ .label = "densidade do ar", .unit = "kg/m³", .group = @intFromEnum(Group.case), .number = 1.225, .minimum = 0.5, .maximum = 1.4 },
};

pub const AirfoilTab = struct {
    groups: [4]form_mod.Group = .{ .{ .title = "Do avião" }, .{ .title = "Biblioteca (data/airfoils)" }, .{ .title = "Arrastados (.dat, polar)" }, .{ .title = "NACA e Reynolds" } },
    fields: [max_candidates + fixed_fields.len]form_mod.Field = undefined,
    labels: [max_candidates][96:0]u8 = undefined,
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    pool: [max_candidates]stage.Candidate = undefined, // os candidatos, na ordem dos campos
    pool_groups: [max_candidates]Group = undefined,
    pool_count: usize = 0,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator), // avião e biblioteca
    dropped_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator), // o que se arrastou
    dropped: [max_candidates]stage.Candidate = undefined,
    dropped_count: usize = 0,
    naca: stage.Candidate = undefined,
    naca_code: u32 = 0,
    naca_name: [16]u8 = undefined,
    naca_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    // o que se mostra (refeito a cada mudança)
    shown: [max_candidates + 1]*const stage.Candidate = undefined,
    shown_names: [max_candidates + 1][64:0]u8 = undefined,
    outcomes: [max_candidates + 1]stage.Outcome = undefined,
    contour_x: [max_candidates + 1][]f64 = undefined,
    contour_y: [max_candidates + 1][]f64 = undefined,
    contour_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    shown_count: usize = 0,
    reynolds: f64 = 0,
    message: [200:0]u8 = [_:0]u8{0} ** 200,
    scroll: f32 = 0,

    /// troca o avião: refaz a lista (os perfis do avião marcados, a biblioteca desmarcada) e a corda de referência
    pub fn setAircraft(tab: *AirfoilTab, ac: ?*const model.Aircraft, reference_chord: ?f64) void {
        const keep = if (tab.pool_count + fixed_fields.len == tab.form.fields.len and tab.form.fields.len > 0) tab.fields[tab.pool_count..][0..fixed_fields.len].* else fixed_fields;
        var checked_before: [max_candidates]bool = undefined;
        const old_count = tab.pool_count;
        for (0..old_count) |k| checked_before[k] = tab.fields[k].checked;
        _ = tab.arena.reset(.retain_capacity);
        const allocator = tab.arena.allocator();
        tab.pool_count = 0;
        if (ac) |plane| {
            const count = stage.aircraftCandidates(allocator, plane, &tab.pool) catch 0;
            for (0..count) |k| tab.pool_groups[k] = .aircraft;
            tab.pool_count = count;
        }
        tab.loadLibrary(allocator);
        for (tab.dropped[0..tab.dropped_count]) |candidate| {
            if (tab.pool_count == max_candidates) break;
            tab.pool[tab.pool_count] = candidate;
            tab.pool_groups[tab.pool_count] = .dropped;
            tab.pool_count += 1;
        }
        for (0..tab.pool_count) |k| {
            const candidate = &tab.pool[k];
            const label = widgets.format(&tab.labels[k], "{s} ({s})", .{ candidate.name, candidate.origin });
            const checked = tab.pool_groups[k] != .library;
            tab.fields[k] = .{ .label = label, .group = @intFromEnum(tab.pool_groups[k]), .kind = .toggle, .checked = checked };
        }
        tab.fields[tab.pool_count..][0..fixed_fields.len].* = keep;
        if (reference_chord) |chord| tab.fields[tab.pool_count + @intFromEnum(FieldId.chord)].number = @round(chord * 1e4) / 1e4;
        tab.form = .{ .groups = &tab.groups, .fields = tab.fields[0 .. tab.pool_count + fixed_fields.len] };
        tab.refresh();
    }

    /// os `.dat` de `data/airfoils` que não são NACA (os NACA já saem do código), procurando a pasta perto da atual
    fn loadLibrary(tab: *AirfoilTab, allocator: std.mem.Allocator) void {
        const folder = findLibrary(allocator) orelse return;
        var dir = std.Io.Dir.cwd().openDir(io(), folder, .{ .iterate = true }) catch return;
        defer dir.close(io());
        var names: [max_candidates][]const u8 = undefined;
        var name_count: usize = 0;
        var iterator = dir.iterate();
        while (iterator.next(io()) catch null) |entry| {
            if (name_count == names.len or !std.ascii.endsWithIgnoreCase(entry.name, ".dat")) continue;
            names[name_count] = allocator.dupe(u8, entry.name) catch continue;
            name_count += 1;
        }
        std.mem.sort([]const u8, names[0..name_count], {}, lessText);
        for (names[0..name_count]) |file_name| {
            if (tab.pool_count == max_candidates) break;
            const path = std.fs.path.join(allocator, &.{ folder, file_name }) catch continue;
            const candidate = readDat(allocator, path, "biblioteca") catch continue;
            if (stage.isNaca4(candidate.name) or tab.has(candidate.name)) continue;
            tab.pool[tab.pool_count] = candidate;
            tab.pool_groups[tab.pool_count] = .library;
            tab.pool_count += 1;
        }
    }

    fn has(tab: *const AirfoilTab, name: []const u8) bool {
        for (tab.pool[0..tab.pool_count]) |candidate| if (std.mem.eql(u8, candidate.name, name)) return true;
        return false;
    }

    /// um arquivo arrastado para a janela: `.dat` vira candidato; polar (`.txt`, `.csv`, `.pol`) vira candidato com
    /// a polar medida. Devolve falso se não for um dos dois
    pub fn addFile(tab: *AirfoilTab, path: []const u8, ac: ?*const model.Aircraft, reference_chord: ?f64) bool {
        const extension = std.fs.path.extension(path);
        const is_dat = std.ascii.eqlIgnoreCase(extension, ".dat");
        const is_polar = std.ascii.eqlIgnoreCase(extension, ".txt") or std.ascii.eqlIgnoreCase(extension, ".csv") or std.ascii.eqlIgnoreCase(extension, ".pol");
        if (!is_dat and !is_polar) return false;
        if (tab.dropped_count == max_candidates) {
            tab.setMessage("lista cheia ({d} candidatos)", .{max_candidates});
            return true;
        }
        const allocator = tab.dropped_arena.allocator();
        const candidate = (if (is_dat) readDat(allocator, path, "arrastado") else readPolar(allocator, path)) catch |err| {
            tab.setMessage("não li '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return true;
        };
        tab.dropped[tab.dropped_count] = candidate;
        tab.dropped_count += 1;
        tab.setAircraft(ac, reference_chord);
        return true;
    }

    fn field(tab: *AirfoilTab, id: FieldId) *form_mod.Field {
        return &tab.fields[tab.pool_count + @intFromEnum(id)];
    }

    fn setMessage(tab: *AirfoilTab, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&tab.message, fmt, args) catch {};
    }

    /// refaz as polares dos candidatos marcados e o Reynolds
    fn refresh(tab: *AirfoilTab) void {
        tab.updateNaca();
        _ = tab.contour_arena.reset(.retain_capacity);
        const allocator = tab.contour_arena.allocator();
        tab.shown_count = 0;
        for (0..tab.pool_count) |k| {
            if (tab.fields[k].checked) tab.show(allocator, &tab.pool[k]);
        }
        if (tab.naca_code != 0) tab.show(allocator, &tab.naca);
        tab.reynolds = section.reynolds(tab.field(.density).number, tab.field(.airspeed).number, tab.field(.chord).number);
        if (tab.shown_count == 0) {
            tab.setMessage("marque ao menos um perfil", .{});
        } else {
            tab.setMessage("Re = {d:.0} (cruzeiro, corda de referência)", .{tab.reynolds});
        }
    }

    fn show(tab: *AirfoilTab, allocator: std.mem.Allocator, candidate: *const stage.Candidate) void {
        const k = tab.shown_count;
        tab.shown[k] = candidate;
        _ = widgets.format(&tab.shown_names[k], "{s}", .{candidate.name});
        stage.evaluate(candidate, &tab.outcomes[k]);
        const n = candidate.outline.len;
        tab.contour_x[k] = allocator.alloc(f64, n) catch &.{};
        tab.contour_y[k] = allocator.alloc(f64, n) catch &.{};
        if (tab.contour_x[k].len == n and tab.contour_y[k].len == n) {
            for (candidate.outline, 0..) |point, i| {
                tab.contour_x[k][i] = point[0];
                tab.contour_y[k][i] = point[1];
            }
        }
        tab.shown_count += 1;
    }

    /// o candidato NACA do campo (refeito só quando o código muda)
    fn updateNaca(tab: *AirfoilTab) void {
        const value = tab.field(.naca).number;
        const code: u32 = if (value >= 1 and value <= 9999) @intFromFloat(@round(value)) else 0;
        if (code == tab.naca_code) return;
        tab.naca_code = 0;
        if (code == 0) return;
        _ = tab.naca_arena.reset(.retain_capacity);
        const name = std.fmt.bufPrint(&tab.naca_name, "NACA {d:0>4}", .{code}) catch return;
        tab.naca = stage.fromOutline(tab.naca_arena.allocator(), name, &.{}, "NACA") catch return;
        tab.naca_code = code;
    }

    /// desenha a aba em `rect` (formulário à esquerda, gráficos à direita)
    pub fn draw(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const sidebar_width: f32 = 360;
        tab.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
        tab.drawPlots(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
    }

    fn drawSidebar(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const footer_height: f32 = 64;
        const form_rect: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - footer_height - 4 };
        const footer: rl.Rectangle = .{ .x = rect.x, .y = rect.y + rect.height - footer_height, .width = rect.width - 1, .height = footer_height };
        rl.drawRectangleRec(.{ .x = footer.x, .y = footer.y, .width = footer.width, .height = 1 }, theme.colors.line);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), footer.x + 12, footer.y + 12, 13, theme.colors.label);
        theme.text(ui.fonts.regular, "arraste um .dat ou a polar do XFLR5 para a janela", footer.x + 12, footer.y + 34, 12, theme.colors.muted);
        if (tab.pool_count + fixed_fields.len == tab.form.fields.len) {
            if (tab.form.draw(ui, form_rect)) tab.refresh();
        }
    }

    fn drawPlots(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 400;
        const summary_height: f32 = 90 + 26 * @as(f32, @floatFromInt(tab.shown_count));
        const content_height = 3 * (row_height + gap) + summary_height + 2 * gap;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        if (ui.hovering(rect)) tab.scroll = std.math.clamp(tab.scroll - ui.wheel * 60, 0, @max(0, content_height - rect.height));
        rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
        defer rl.endScissorMode();
        if (tab.shown_count == 0) {
            theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), rect.x + 40, rect.y + 40, 16, theme.colors.muted);
            return;
        }
        var y = rect.y + gap - tab.scroll;
        var lift: [max_candidates + 1]plot.Series = undefined;
        var drag: [max_candidates + 1]plot.Series = undefined;
        var efficiency: [max_candidates + 1]plot.Series = undefined;
        var moment: [max_candidates + 1]plot.Series = undefined;
        var outline: [max_candidates + 1]plot.Series = undefined;
        var outline_count: usize = 0;
        for (0..tab.shown_count) |k| {
            const polar = &tab.outcomes[k].polar;
            const n = polar.count;
            const name = std.mem.sliceTo(&tab.shown_names[k], 0);
            lift[k] = .{ .name = name, .xs = polar.alpha[0..n], .ys = polar.cl[0..n], .color_index = k };
            drag[k] = .{ .name = name, .xs = polar.cd[0..n], .ys = polar.cl[0..n], .color_index = k };
            efficiency[k] = .{ .name = name, .xs = polar.alpha[0..n], .ys = tab.outcomes[k].ld[0..n], .color_index = k };
            moment[k] = .{ .name = name, .xs = polar.alpha[0..n], .ys = polar.cm[0..n], .color_index = k };
            if (tab.contour_x[k].len > 0) {
                outline[outline_count] = .{ .name = name, .xs = tab.contour_x[k], .ys = tab.contour_y[k], .color_index = k };
                outline_count += 1;
            }
        }
        const count = tab.shown_count;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "c_l × α", .x_label = "α (°)", .y_label = "c_l" }, lift[0..count]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "Polar c_l × c_d", .x_label = "c_d", .y_label = "c_l" }, drag[0..count]);
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "Eficiência c_l/c_d × α", .x_label = "α (°)", .y_label = "c_l/c_d" }, efficiency[0..count]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "c_m × α", .x_label = "α (°)", .y_label = "c_m" }, moment[0..count]);
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "Contorno", .x_label = "x/c", .y_label = "y/c", .equal_axes = true }, outline[0..outline_count]);
        tab.drawDiagnosis(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height });
        y += row_height + gap;
        tab.drawSummary(ui, .{ .x = x0, .y = y, .width = rect.width - 2 * gap, .height = summary_height });
    }

    fn drawDiagnosis(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Diagnóstico");
        const columns = [_]f32{ inner.x, inner.x + 80, inner.x + 290 };
        var y = inner.y;
        var buffers: [2][160]u8 = undefined;
        const Row = struct { status: widgets.Status, item: [:0]const u8, value: [:0]const u8 };
        var rows: [max_candidates + 2]Row = undefined;
        var row_count: usize = 0;
        var names: [max_candidates + 1][96]u8 = undefined;
        var values: [max_candidates + 1][96]u8 = undefined;
        rows[row_count] = .{ .status = if (tab.reynolds < 1e5) .atencao else .ok, .item = "Reynolds", .value = widgets.format(&buffers[0], "{d:.0} {s}", .{ tab.reynolds, if (tab.reynolds < 1e5) "(abaixo de 10⁵ as bolhas mudam muito a polar)" else "" }) };
        row_count += 1;
        for (0..tab.shown_count) |k| {
            const candidate = tab.shown[k];
            const metrics = tab.outcomes[k].metrics orelse {
                rows[row_count] = .{ .status = .falha, .item = widgets.format(&names[k], "{s}: polar", .{candidate.name}), .value = "poucos pontos na faixa de α" };
                row_count += 1;
                continue;
            };
            if (candidate.source == .arquivo and std.math.isFinite(candidate.measured_reynolds) and @abs(candidate.measured_reynolds / tab.reynolds - 1) > 0.3) {
                rows[row_count] = .{ .status = .atencao, .item = widgets.format(&names[k], "{s}: Re da polar", .{candidate.name}), .value = widgets.format(&values[k], "{d:.0} (≈ {d:.0}): exporte do XFLR5 no Re de cruzeiro", .{ candidate.measured_reynolds, tab.reynolds }) };
                row_count += 1;
            } else if (metrics.cd_constant) {
                rows[row_count] = .{ .status = .info, .item = widgets.format(&names[k], "{s}: c_d constante", .{candidate.name}), .value = "o modelo não tem balde de arrasto: use a polar do XFLR5" };
                row_count += 1;
            }
        }
        for (rows[0..row_count]) |row| {
            const labels = [_][:0]const u8{ @tagName(row.status), row.item, row.value };
            const colors = [_]rl.Color{ widgets.statusColor(row.status), theme.colors.ink, theme.colors.label };
            widgets.tableRow(ui, y, &columns, &labels, &colors, 14);
            y += 26;
            rl.drawRectangleRec(.{ .x = inner.x, .y = y - 6, .width = inner.width, .height = 1 }, theme.colors.grid);
        }
        if (row_count == 1) theme.text(ui.fonts.regular, "nenhum aviso nos perfis marcados", inner.x, y + 4, 13, theme.colors.muted);
    }

    fn drawSummary(tab: *AirfoilTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const inner = widgets.labeledCard(ui, rect, "Números de cada perfil (o que segue para a asa)");
        const headers = [_][:0]const u8{ "perfil", "polar por", "c_l,max", "α estol (°)", "(c_l/c_d) máx.", "c_l nele", "a1 (1/rad)", "α_L0 (°)", "c_m", "c_d mín." };
        var columns: [headers.len]f32 = undefined;
        const first: f32 = 220;
        const step = (inner.width - first) / @as(f32, @floatFromInt(headers.len - 1));
        for (&columns, 0..) |*x, i| x.* = if (i == 0) inner.x else inner.x + first + step * @as(f32, @floatFromInt(i - 1));
        const header_colors = [_]rl.Color{theme.colors.accent};
        widgets.tableRow(ui, inner.y, &columns, &headers, &header_colors, 13);
        var y = inner.y + 26;
        for (0..tab.shown_count) |k| {
            const metrics = tab.outcomes[k].metrics orelse continue;
            var buffers: [headers.len][48]u8 = undefined;
            _ = &buffers[0];
            const source: []const u8 = if (tab.shown[k].source == .arquivo) "arquivo" else "modelo";
            const cells = [_][:0]const u8{
                std.mem.sliceTo(&tab.shown_names[k], 0),
                widgets.format(&buffers[1], "{s}", .{source}),
                widgets.format(&buffers[2], "{d:.3}", .{metrics.cl_max}),
                widgets.format(&buffers[3], "{d:.1}", .{metrics.alpha_stall}),
                widgets.format(&buffers[4], "{d:.1}", .{metrics.ld_max}),
                widgets.format(&buffers[5], "{d:.3}", .{metrics.cl_at_ld}),
                widgets.format(&buffers[6], "{d:.3}", .{metrics.cl_alpha}),
                widgets.format(&buffers[7], "{d:.2}", .{metrics.alpha0}),
                widgets.format(&buffers[8], "{d:.3}", .{metrics.cm}),
                widgets.format(&buffers[9], "{d:.4}", .{metrics.cd_min}),
            };
            const colors = [_]rl.Color{ theme.plotColor(k), theme.colors.label, theme.colors.ink };
            widgets.tableRow(ui, y, &columns, &cells, &colors, 14);
            y += 26;
        }
    }
};

/// um `.dat` (nome na primeira linha; senão o do arquivo)
fn readDat(allocator: std.mem.Allocator, path: []const u8, origin: []const u8) !stage.Candidate {
    const text = try std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(1 << 20));
    const coords = try assembly_mod.parseDat(allocator, text);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    const first = std.mem.trim(u8, lines.next() orelse "", " \t");
    const stem = std.fs.path.stem(path);
    return stage.fromOutline(allocator, if (first.len > 0) first else stem, coords, origin);
}

/// a polar do XFLR5/XFOIL: um candidato sem contorno, com a polar medida
fn readPolar(allocator: std.mem.Allocator, path: []const u8) !stage.Candidate {
    const text = try std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(1 << 22));
    const measured = try allocator.create(section.Polar);
    const reynolds = try stage.readPolarText(text, measured);
    return .{
        .name = try allocator.dupe(u8, std.fs.path.stem(path)),
        .origin = "polar",
        .numbers = .{ .cl_alpha = stage.default_numbers.cl_alpha, .alpha0 = 0, .cl_max = stage.default_numbers.cl_max, .cd0 = stage.default_numbers.cd0, .cm_ac = 0 },
        .source = .arquivo,
        .measured = measured,
        .measured_reynolds = reynolds,
    };
}

/// a pasta `data/airfoils` a partir da atual ou das de cima
fn findLibrary(allocator: std.mem.Allocator) ?[]const u8 {
    var prefix: []const u8 = "";
    for (0..4) |_| {
        const candidate = std.mem.concat(allocator, u8, &.{ prefix, "data/airfoils" }) catch return null;
        if (std.Io.Dir.cwd().access(io(), candidate, .{})) |_| return candidate else |_| {}
        prefix = std.mem.concat(allocator, u8, &.{ prefix, "../" }) catch return null;
    }
    return null;
}

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// a leitura de arquivos (sem threads)
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

//! A tela do aerosim: cabeçalho, abas das áreas e subabas da Aerodinâmica. Cada aba feita mora no arquivo dela
//! (`analyze_tab.zig`, a Montagem aqui mesmo); o avião aberto (`assembly.zig`) é o mesmo para todas. As abas que
//! ainda não foram feitas mostram só o lugar delas.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const view3d = ui_kit.view3d;
const analyze_tab = @import("analyze_tab.zig");
const airfoil_tab = @import("airfoil_tab.zig");
const wing_tab = @import("wing_tab.zig");
const assembly_mod = @import("assembly.zig");
const aircraft_model = @import("aircraft_model");

const areas = [_][:0]const u8{ "Dimensionamento", "Aerodinâmica", "Estabilidade", "Desempenho", "Cargas", "Montagem" };
const aero_tabs = [_][:0]const u8{ "Perfis", "Projetar", "Analisar" };

pub const Screen = struct {
    area: usize = 1,
    aero_tab: usize = 2,
    scroll: f32 = 0, // rolagem inicial (prints), passada à aba aberta
    analyze: analyze_tab.AnalyzeTab = .{},
    airfoils: airfoil_tab.AirfoilTab = .{},
    wing: wing_tab.WingTab = .{},
    assembly_view: view3d.View = .{}, // a vista 3D da Montagem
    assembly: ?assembly_mod.Assembly = null, // o avião aberto
    assembly_note: [240:0]u8 = [_:0]u8{0} ** 240,

    /// abre a aba de área `index` (0 = Dimensionamento ... 5 = Montagem; 6, 7 e 8 = Aerodinâmica → Perfis, Projetar
    /// e Analisar), para os prints
    pub fn selectTab(screen: *Screen, index: usize) void {
        if (index >= areas.len) {
            screen.area = 1;
            screen.aero_tab = @min(index - areas.len, aero_tabs.len - 1);
        } else screen.area = index;
    }

    /// liga o formulário às listas da própria tela e roda a análise uma vez (chamar com a janela aberta e a tela
    /// já no lugar final)
    pub fn start(screen: *Screen) void {
        var buffer: [512]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        if (assembly_mod.findExample(fixed.allocator(), io())) |path| screen.openFile(path) else {
            screen.analyze.setAircraft(null);
            screen.airfoils.setAircraft(null, null);
        }
    }

    /// o avião aberto, se houver
    fn aircraft(screen: *Screen) ?*const aircraft_model.aircraft.Aircraft {
        return if (screen.assembly) |*opened| &opened.loaded.ac else null;
    }

    /// a corda média aerodinâmica da primeira superfície da análise das asas (a corda do Reynolds dos perfis)
    fn referenceChord(screen: *Screen) ?f64 {
        const result = screen.analyze.results[0] orelse screen.analyze.results[1] orelse return null;
        return if (result.owner_count > 0) result.owner_chord[0] else null;
    }

    /// abre o avião em `path` (.json) na Montagem
    pub fn openFile(screen: *Screen, path: []const u8) void {
        var diagnosis: assembly_mod.Diagnosis = .{};
        const loaded = assembly_mod.load(std.heap.page_allocator, io(), path, &diagnosis) catch |err| {
            const reason = if (diagnosis.len > 0) diagnosis.text() else @errorName(err);
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não abriu '{s}': {s}", .{ std.fs.path.basename(path), reason }) catch {};
            return;
        };
        if (screen.assembly) |*old| old.deinit();
        screen.assembly = loaded;
        screen.analyze.setAircraft(screen.aircraft());
        screen.airfoils.setAircraft(screen.aircraft(), screen.referenceChord());
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · {d} peças · arraste outro .json para a janela para trocar · arraste para girar, roda para aproximar", .{ std.fs.path.basename(path), loaded.mesh.piece_count }) catch {};
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.colors.background);
        if (rl.isFileDropped()) {
            const dropped = rl.loadDroppedFiles();
            defer rl.unloadDroppedFiles(dropped);
            for (0..dropped.count) |k| {
                const path = std.mem.sliceTo(dropped.paths[k], 0);
                if (screen.airfoils.addFile(path, screen.aircraft(), screen.referenceChord())) {
                    screen.area = 1;
                    screen.aero_tab = 0;
                } else {
                    screen.openFile(path);
                    screen.area = 5;
                }
            }
        }
        // conteúdo primeiro, cabeçalho e abas por cima (a rolagem passa por baixo deles)
        const top = widgets.header_height + 38 + 32;
        if (screen.scroll > 0) { // a rolagem pedida na linha de comando vai para a aba aberta
            screen.analyze.scroll = screen.scroll;
            screen.airfoils.scroll = screen.scroll;
            screen.wing.scroll = screen.scroll;
            screen.scroll = 0;
        }
        if (screen.area == 1 and screen.aero_tab == 0) {
            screen.airfoils.draw(ui, .{ .x = 0, .y = top, .width = width, .height = height - top });
        } else if (screen.area == 1 and screen.aero_tab == 1) {
            screen.wing.syncAirfoils(&screen.airfoils);
            screen.wing.draw(ui, .{ .x = 0, .y = top, .width = width, .height = height - top });
        } else if (screen.area == 1 and screen.aero_tab == 2) {
            screen.analyze.draw(ui, .{ .x = 0, .y = top, .width = width, .height = height - top }, screen.aircraft());
        } else if (screen.area == 5) {
            screen.drawAssembly(ui, .{ .x = 0, .y = top, .width = width, .height = height - top });
        } else {
            placeholder(ui, .{ .x = 0, .y = top, .width = width, .height = height - top }, if (screen.area == 1) aero_tabs[screen.aero_tab] else areas[screen.area]);
        }
        if (widgets.header(ui, width, "AeroSim", &.{ "Abrir avião (.json)", "Salvar .json" }, "contas no núcleo em Zig")) |_|
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "para abrir: arraste o .json para a janela; o diálogo de arquivo e o salvar entram depois", .{}) catch {};
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, &areas, &screen.area, 14);
        if (screen.area == 1) {
            _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, &aero_tabs, &screen.aero_tab, 13);
        } else {
            rl.drawRectangleRec(.{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, theme.colors.panel);
        }
    }

    /// a Montagem: o avião aberto em 3D, todas as peças nas cores da GUI, com o chão e os eixos do corpo
    fn drawAssembly(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const card_rect: rl.Rectangle = .{ .x = rect.x + 12, .y = rect.y + 12, .width = rect.width - 24, .height = rect.height - 24 };
        const area = cardInside(card_rect);
        screen.assembly_view.handleInput(ui, area);
        var title_buffer: [160]u8 = undefined;
        var title: [:0]const u8 = "Montagem: nenhum avião aberto (arraste um .json para a janela)";
        if (screen.assembly) |*opened| {
            const plane = &opened.mesh;
            title = widgets.format(&title_buffer, "Montagem: {s}", .{opened.name});
            const size = plane.size();
            const middle = plane.center();
            if (screen.assembly_view.begin(area, middle, 1.1 * size)) {
                defer screen.assembly_view.end();
                // o chão um pouco abaixo da peça mais baixa (z para baixo), quadriculado de 25 cm
                view3d.floor(.{ middle[0], middle[1], 0 }, plane.high[2] + 0.02, 1.6 * size, 0.25);
                plane.draw();
                view3d.bodyAxes(&screen.assembly_view, .{ plane.low[0] - 0.12 * size, plane.low[1] - 0.12 * size, plane.high[2] + 0.04 * size }, 0.14 * size);
            }
        }
        _ = widgets.card(ui, card_rect, title);
        if (screen.assembly != null) screen.assembly_view.blit(ui, area);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.assembly_note, 0), area.x + 6, area.y + area.height - 18, 12, theme.colors.muted);
    }
};

/// a leitura de arquivos (sem threads)
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// a parte de dentro de um cartão onde vai a imagem 3D (abaixo do título)
fn cardInside(rect: rl.Rectangle) rl.Rectangle {
    return .{ .x = rect.x + 4, .y = rect.y + 34, .width = rect.width - 8, .height = rect.height - 40 };
}

/// o lugar de uma aba que ainda não foi feita
fn placeholder(ui: *widgets.Ui, rect: rl.Rectangle, name: [:0]const u8) void {
    const box: rl.Rectangle = .{ .x = rect.x + 40, .y = rect.y + 40, .width = @min(rect.width - 80, 620), .height = 150 };
    const inner = widgets.labeledCard(ui, box, name);
    theme.text(ui.fonts.regular, "esta aba ainda não foi feita em Zig; o desenho segue o mesmo tema", inner.x, inner.y + 10, 15, theme.colors.label);
}

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
const design_mod = @import("design.zig");
const requirements_dialog = @import("requirements_dialog.zig");
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
    design: design_mod.Design = .{}, // o projeto de dimensionamento (Perfis e Projetar)
    requirements: requirements_dialog.RequirementsDialog = .{}, // "Condições e restrições…", aberta por qualquer etapa
    files: ui_kit.dialogs.FilePicker = .{}, // abrir e salvar o avião (cabeçalho)
    assembly_view: view3d.View = .{}, // a vista 3D da Montagem
    assembly: ?assembly_mod.Assembly = null, // o avião aberto
    assembly_note: [240:0]u8 = [_:0]u8{0} ** 240,
    loader: ui_kit.jobs.Job = .{}, // lê o .json fora do laço da tela
    loading: Loading = .{},

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
        screen.design.start();
        screen.airfoils.attach(&screen.design);
        screen.wing.attach(&screen.design);
        var buffer: [512]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        if (assembly_mod.findExample(fixed.allocator(), io())) |path| screen.openFile(path) else screen.analyze.setAircraft(null);
    }

    /// a aba da janela "Condições e restrições…" pelo nome do comando (prints)
fn requirementsTab(name: []const u8) ?usize {
    const names = [_][]const u8{ "condicoes", "restricoes", "variaveis", "regras" };
    for (names, 0..) |candidate, k| if (std.mem.eql(u8, candidate, name)) return k;
    return null;
}

/// o avião aberto, se houver
    fn aircraft(screen: *Screen) ?*const aircraft_model.aircraft.Aircraft {
        return if (screen.assembly) |*opened| &opened.loaded.ac else null;
    }

    /// um comando pelo nome (`acao=` da linha de comando, para os prints): "naca", "dat", "polar" abrem os
    /// diálogos de Perfis
    pub fn command(screen: *Screen, name: []const u8) void {
        if (std.mem.eql(u8, name, "abrir")) {
            var buffer: [256]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&buffer);
            const folder = if (screen.assembly) |*opened| std.fs.path.dirname(opened.path) orelse "." else exampleFolder(fixed.allocator());
            screen.files.show("Abrir avião (.json)", folder, &.{".json"});
        } else if (std.mem.eql(u8, name, "salvar")) {
            const opened = &(screen.assembly orelse {
                _ = std.fmt.bufPrintZ(&screen.assembly_note, "nenhum avião aberto para salvar", .{}) catch {};
                return;
            });
            screen.files.showSave("Salvar avião (.json)", std.fs.path.dirname(opened.path) orelse ".", &.{".json"}, std.fs.path.basename(opened.path));
        } else if (requirementsTab(name)) |tab| {
            screen.requirements.show();
            screen.requirements.dialog.tab = tab;
        } else if (std.mem.eql(u8, name, "tabela")) {
            screen.wing.command(name);
        } else screen.airfoils.command(name);
    }

    /// grava o avião aberto em `path`; enquanto não há edição, é o texto do arquivo como foi lido
    fn save(screen: *Screen, path: []const u8) void {
        const opened = &(screen.assembly orelse return);
        std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = opened.source }) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não salvou '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) }) catch {};
            return;
        };
        ui_kit.system.offerDownload(path);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "salvo em {s}", .{path}) catch {};
    }

    /// abre o arquivo `path`: um `.dat` ou uma polar vão para Perfis; um `.json` é o avião (Montagem)
    pub fn openFile(screen: *Screen, path: []const u8) void {
        if (screen.airfoils.addFile(path)) return;
        screen.openAircraft(path);
    }

    /// abre o avião em `path` (.json) na Montagem: a leitura e as peças saem numa thread; a tela segue desenhando e
    /// troca o avião quando ela acaba (`collectAircraft`)
    fn openAircraft(screen: *Screen, path: []const u8) void {
        if (screen.loader.running()) {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "ainda abrindo {s}...", .{std.fs.path.basename(screen.loading.pathText())}) catch {};
            return;
        }
        screen.loader.cancel();
        const copied = @min(path.len, screen.loading.path.len);
        @memcpy(screen.loading.path[0..copied], path[0..copied]);
        screen.loading.path_len = copied;
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "abrindo {s}...", .{std.fs.path.basename(path)}) catch {};
        _ = screen.loader.start(Loading.work, .{&screen.loading});
        screen.collectAircraft();
    }

    /// no quadro em que a leitura acabou: troca o avião aberto (antes, espera a análise que lia o antigo)
    fn collectAircraft(screen: *Screen) void {
        if (!screen.loader.finished()) return;
        const path = screen.loading.pathText();
        const loaded = screen.loading.result orelse {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não abriu '{s}': {s}", .{ std.fs.path.basename(path), screen.loading.reasonText() }) catch {};
            return;
        };
        screen.loading.result = null;
        screen.analyze.cancel();
        if (screen.assembly) |*old| old.deinit();
        screen.assembly = loaded;
        screen.analyze.setAircraft(screen.aircraft());
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · {d} peças · arraste outro .json para a janela para trocar · arraste para girar, roda para aproximar", .{ std.fs.path.basename(path), loaded.mesh.piece_count }) catch {};
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.colors.background);
        screen.collectAircraft();
        if (rl.isFileDropped()) {
            const dropped = rl.loadDroppedFiles();
            defer rl.unloadDroppedFiles(dropped);
            for (0..dropped.count) |k| {
                const path = std.mem.sliceTo(dropped.paths[k], 0);
                if (screen.airfoils.addFile(path)) {
                    screen.area = 1;
                    screen.aero_tab = 0;
                } else {
                    screen.openAircraft(path);
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
        // com uma janela aberta (seletor de arquivo, pergunta), a tela de baixo não recebe o clique nem a roda
        if (screen.design.requirements_open) {
            screen.design.requirements_open = false;
            screen.requirements.show();
        }
        const modal = screen.airfoils.modalOpen() or screen.files.open or screen.requirements.isOpen();
        const wheel = ui.wheel;
        if (modal) {
            ui.click_taken = true;
            ui.wheel = 0;
        }
        if (screen.area == 1 and screen.aero_tab == 0) {
            if (screen.airfoils.draw(ui, .{ .x = 0, .y = top, .width = width, .height = height - top })) screen.aero_tab = 1;
        } else if (screen.area == 1 and screen.aero_tab == 1) {
            screen.wing.draw(ui, .{ .x = 0, .y = top, .width = width, .height = height - top });
        } else if (screen.area == 1 and screen.aero_tab == 2) {
            screen.analyze.draw(ui, .{ .x = 0, .y = top, .width = width, .height = height - top }, screen.aircraft());
        } else if (screen.area == 5) {
            screen.drawAssembly(ui, .{ .x = 0, .y = top, .width = width, .height = height - top });
        } else {
            placeholder(ui, .{ .x = 0, .y = top, .width = width, .height = height - top }, if (screen.area == 1) aero_tabs[screen.aero_tab] else areas[screen.area]);
        }
        if (widgets.header(ui, width, "AeroSim", &.{ "Abrir avião (.json)", "Salvar .json" }, "contas no núcleo em Zig")) |button| {
            if (button == 0) screen.command("abrir") else screen.command("salvar");
        }
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, &areas, &screen.area, 14);
        if (screen.area == 1) {
            _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, &aero_tabs, &screen.aero_tab, 13);
        } else {
            rl.drawRectangleRec(.{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, theme.colors.panel);
        }
        if (modal) {
            ui.click_taken = false;
            ui.wheel = wheel;
            const whole: rl.Rectangle = .{ .x = 0, .y = 0, .width = width, .height = height };
            screen.airfoils.drawModal(ui, whole);
            screen.requirements.draw(ui, whole, &screen.design);
            const saving = screen.files.saving;
            if (screen.files.draw(ui, whole)) |path| {
                if (saving) screen.save(path) else {
                    screen.openAircraft(path);
                    screen.area = 5;
                }
            }
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
                drawBalance(&screen.assembly_view, assembly_mod.balance(&opened.loaded.ac), plane.low[2], size);
                view3d.bodyAxes(&screen.assembly_view, .{ plane.low[0] - 0.12 * size, plane.low[1] - 0.12 * size, plane.high[2] + 0.04 * size }, 0.14 * size);
            }
        }
        _ = widgets.card(ui, card_rect, title);
        if (screen.assembly != null) screen.assembly_view.blit(ui, area);
        theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.assembly_note, 0), area.x + 6, area.y + area.height - 18, 12, theme.colors.muted);
    }
};

/// o pedido de leitura de um avião e o que a thread devolve
const Loading = struct {
    path: [1024]u8 = undefined,
    path_len: usize = 0,
    result: ?assembly_mod.Assembly = null,
    reason: [200]u8 = undefined,
    reason_len: usize = 0,

    fn pathText(loading: *const Loading) []const u8 {
        return loading.path[0..loading.path_len];
    }

    fn reasonText(loading: *const Loading) []const u8 {
        return loading.reason[0..loading.reason_len];
    }

    /// roda na thread: lê o `.json` e monta as peças
    fn work(loading: *Loading) void {
        var diagnosis: assembly_mod.Diagnosis = .{};
        loading.result = assembly_mod.load(std.heap.page_allocator, io(), loading.pathText(), &diagnosis) catch |err| {
            const reason = if (diagnosis.len > 0) diagnosis.text() else @errorName(err);
            const copied = @min(reason.len, loading.reason.len);
            @memcpy(loading.reason[0..copied], reason[0..copied]);
            loading.reason_len = copied;
            loading.result = null;
            return;
        };
    }
};

/// a pasta dos aviões de exemplo (`data/aircraft`), perto da atual
fn exampleFolder(memory: std.mem.Allocator) []const u8 {
    const example = assembly_mod.findExample(memory, io()) orelse return ".";
    return std.fs.path.dirname(example) orelse ".";
}

/// a leitura de arquivos (sem threads)
fn io() std.Io {
    return ui_kit.system.io();
}

/// o CG na Montagem: uma cruz nos três eixos e uma haste até acima do avião com o rótulo (com a carga; o vazio em
/// cinza quando é outro ponto)
fn drawBalance(view: *view3d.View, weights: assembly_mod.Balance, top: f64, size: f64) void {
    const loaded_color = theme.hex(0xd62728);
    const empty_color = theme.colors.muted;
    const arm = 0.04 * size;
    const moved = @abs(weights.cg[0] - weights.empty_cg[0]) + @abs(weights.cg[2] - weights.empty_cg[2]) > 1e-4;
    if (moved) {
        cross(weights.empty_cg, arm, empty_color);
        view.label(.{ weights.empty_cg[0], weights.empty_cg[1], weights.empty_cg[2] + 0.05 * size }, widgets.format(&empty_label, "CG vazio ({d:.2} kg)", .{weights.empty_mass}), empty_color);
    }
    cross(weights.cg, arm, loaded_color);
    view3d.segment(weights.cg, .{ weights.cg[0], weights.cg[1], top - 0.1 * size }, loaded_color);
    view.label(.{ weights.cg[0], weights.cg[1], top - 0.1 * size }, widgets.format(&loaded_label, "CG  x = {d:.3} m  ({d:.2} kg)", .{ weights.cg[0], weights.mass }), loaded_color);
}

// os textos dos rótulos ficam vivos até o `blit` da vista
var empty_label: [64]u8 = undefined;
var loaded_label: [64]u8 = undefined;

fn cross(center: [3]f64, arm: f64, color: rl.Color) void {
    for (0..3) |axis| {
        var from = center;
        var to = center;
        from[axis] -= arm;
        to[axis] += arm;
        view3d.segment(from, to, color);
    }
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

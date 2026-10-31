//! A tela do aerosim: o cabeçalho, as abas das áreas e as subabas de cada uma, na mesma arrumação da GUI PyQt
//! (`aerosim/gui/main_window.py`). As abas vêm do Python (`python_bridge.zig`, pedido "layout"): cada subaba é uma
//! `Page` (`page.zig`), uma análise do Simulation Manager ou uma etapa da sprint, que a tela desenha a partir do que
//! o Python descreve. A Montagem é daqui mesmo: o avião aberto em 3D (`assembly.zig`), com o CG.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const view3d = ui_kit.view3d;
const jobs = ui_kit.jobs;
const page_mod = @import("page.zig");
const python_bridge = @import("python_bridge.zig");
const assembly_mod = @import("assembly.zig");
const aircraft_model = @import("aircraft_model");

const Page = page_mod.Page;
const Json = std.json.Value;

/// uma área: o título na barra de cima e as subabas (uma `Page` cada; `null` é a Montagem)
const Area = struct {
    title: [:0]const u8,
    single: bool, // uma página só, sem a barra de subabas
    labels: []const [:0]const u8,
    pages: []?*Page,
    active: usize = 0,
};

/// o pedido das abas ao Python, na thread
const LayoutLoader = struct {
    job: jobs.Job = .{},
    waiter: python_bridge.Waiter = .{},
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    reply: ?Json = null,
    asked: bool = false,
    loading: bool = false, // no navegador: a página ainda está carregando o Python (pede de novo no quadro seguinte)

    fn work(loader: *LayoutLoader, bridge: *python_bridge.Bridge, process: ?std.Io) void {
        loader.waiter.memory = loader.arena.allocator();
        bridge.start(process) catch |err| {
            if (err == error.PythonLoading) {
                loader.loading = true;
                return;
            }
            if (ui_kit.system.in_browser) {
                _ = std.fmt.bufPrintZ(&loader.waiter.failure, "o Python da página não carregou (o motivo está no console do navegador); a Montagem funciona", .{}) catch {};
            } else {
                _ = std.fmt.bufPrintZ(&loader.waiter.failure, "não abriu o Python ({s}): rode da pasta do repositório, com as dependências instaladas; a Montagem funciona", .{@errorName(err)}) catch {};
            }
            return;
        };
        loader.reply = bridge.request(&loader.waiter, "\"op\": \"layout\"") catch null;
    }
};

const waiting_labels = [_][:0]const u8{ "Python…", "Montagem" };

pub const Screen = struct {
    area: usize = 0,
    scroll: f32 = 0, // rolagem inicial (prints), passada à página aberta
    io: ?std.Io = null, // a `Io` do processo (o programa a passa em `ui/app.zig`): a ponte abre o Python com ela
    bridge: python_bridge.Bridge = .{},
    layout: LayoutLoader = .{},
    areas: []Area = &.{},
    area_labels: []const [:0]const u8 = &waiting_labels,
    shown: ?*Page = null, // a página do último quadro (trocar de página pede ela de novo)
    requirements: Page = .{ .kind = .stage, .name = "requisitos", .title = "Condições e restrições", .grids_beside = true },
    requirements_open: bool = false,
    pending_tab: ?usize = null, // aba=N da linha de comando, até as abas chegarem
    pending_run: bool = false, // acao=rodar, idem
    pending_file: [1024]u8 = undefined, // um perfil arrastado antes de as abas chegarem
    pending_file_len: usize = 0,
    files: ui_kit.dialogs.FilePicker = .{}, // abrir e salvar o avião (cabeçalho)
    assembly_view: view3d.View = .{}, // a vista 3D da Montagem
    assembly: ?assembly_mod.Assembly = null, // o avião aberto
    assembly_note: [240:0]u8 = [_:0]u8{0} ** 240,
    loader: ui_kit.jobs.Job = .{}, // lê o .json fora do laço da tela
    loading: Loading = .{},
    message: [240:0]u8 = [_:0]u8{0} ** 240,

    /// abre a subaba de número `index`, contando todas em ordem (a Montagem é a última), para os prints
    pub fn selectTab(screen: *Screen, index: usize) void {
        screen.pending_tab = index;
    }

    /// pede as abas ao Python e abre o avião de exemplo (chamar com a janela aberta)
    pub fn start(screen: *Screen) void {
        screen.requirements.bridge = &screen.bridge;
        var buffer: [512]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        if (assembly_mod.findExample(fixed.allocator(), io())) |path| screen.openFile(path);
    }

    /// um comando pelo nome (`acao=` da linha de comando, para os prints): "abrir", "salvar", "rodar" (roda a análise
    /// aberta assim que os campos chegam)
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
        } else if (std.mem.eql(u8, name, "rodar")) {
            screen.pending_run = true;
        } else if (std.mem.eql(u8, name, "condicoes")) {
            screen.requirements_open = true;
        }
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

    /// abre o arquivo `path`: um `.json` é o avião (Montagem); um `.dat` ou uma polar vão para a etapa Perfis
    pub fn openFile(screen: *Screen, path: []const u8) void {
        if (std.mem.endsWith(u8, path, ".json")) return screen.openAircraft(path);
        const perfis = screen.findPage("perfis") orelse {
            const length = @min(path.len, screen.pending_file.len);
            @memcpy(screen.pending_file[0..length], path[0..length]);
            screen.pending_file_len = length;
            return;
        };
        perfis.act(if (std.mem.endsWith(u8, path, ".dat")) "dat" else "polar", path);
        screen.showPage(perfis);
    }

    /// a página de uma análise ou etapa pelo nome
    fn findPage(screen: *Screen, name: []const u8) ?*Page {
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| if (std.mem.eql(u8, page.name, name)) return page;
        return null;
    }

    /// leva a tela até a página `target`
    fn showPage(screen: *Screen, target: *Page) void {
        for (screen.areas, 0..) |*area, a| for (area.pages, 0..) |maybe, k| if (maybe == target) {
            screen.area = a;
            area.active = k;
        };
    }

    /// leva a tela até a Montagem
    fn showAssembly(screen: *Screen) void {
        for (screen.areas, 0..) |*area, a| for (area.pages, 0..) |maybe, k| if (maybe == null) {
            screen.area = a;
            area.active = k;
        };
        if (screen.areas.len == 0) screen.area = 1;
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

    /// no quadro em que a leitura acabou: troca o avião aberto e avisa as páginas (o Python abre o mesmo arquivo)
    fn collectAircraft(screen: *Screen) void {
        if (!screen.loader.finished()) return;
        const path = screen.loading.pathText();
        const loaded = screen.loading.result orelse {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não abriu '{s}': {s}", .{ std.fs.path.basename(path), screen.loading.reasonText() }) catch {};
            return;
        };
        screen.loading.result = null;
        if (screen.assembly) |*old| old.deinit();
        screen.assembly = loaded;
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| page.setAircraftPath(loaded.path);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · {d} peças · arraste outro .json para a janela para trocar · arraste para girar, roda para aproximar", .{ std.fs.path.basename(path), loaded.mesh.piece_count }) catch {};
    }

    /// pede as abas na primeira vez e monta as áreas quando a resposta chega
    fn collectLayout(screen: *Screen) void {
        const loader = &screen.layout;
        if (!loader.asked) {
            loader.asked = true;
            _ = std.fmt.bufPrintZ(&screen.message, "abrindo o Python (os managers das análises)...", .{}) catch {};
            _ = loader.job.start(LayoutLoader.work, .{ loader, &screen.bridge, screen.io });
        }
        if (!loader.job.finished()) return;
        if (loader.loading) {
            loader.loading = false;
            loader.asked = false;
            _ = std.fmt.bufPrintZ(&screen.message, "carregando o Python no navegador (os managers das análises)...", .{}) catch {};
            return;
        }
        const reply = loader.reply orelse {
            _ = std.fmt.bufPrintZ(&screen.message, "{s}", .{std.mem.sliceTo(&loader.waiter.failure, 0)}) catch {};
            return;
        };
        screen.buildAreas(reply) catch {
            _ = std.fmt.bufPrintZ(&screen.message, "as abas vieram fora do esperado", .{}) catch {};
            return;
        };
        screen.message[0] = 0;
    }

    /// as áreas e as páginas a partir da resposta "layout"
    fn buildAreas(screen: *Screen, reply: Json) !void {
        const memory = screen.layout.arena.allocator();
        const items = (reply.object.get("areas") orelse return error.BadReply).array.items;
        const areas = try memory.alloc(Area, items.len);
        const labels = try memory.alloc([:0]const u8, items.len);
        const path = if (screen.assembly) |*opened| opened.path else "";
        for (items, 0..) |item, a| {
            const tabs = (item.object.get("tabs") orelse return error.BadReply).array.items;
            const tab_labels = try memory.alloc([:0]const u8, tabs.len);
            const pages = try memory.alloc(?*Page, tabs.len);
            for (tabs, 0..) |tab, k| {
                tab_labels[k] = try memory.dupeZ(u8, stringField(tab, "title"));
                const kind_text = stringField(tab, "kind");
                if (std.mem.eql(u8, kind_text, "assembly")) {
                    pages[k] = null;
                    continue;
                }
                const page = try std.heap.page_allocator.create(Page);
                page.* = .{
                    .kind = if (std.mem.eql(u8, kind_text, "sim")) .simulation else if (std.mem.eql(u8, kind_text, "stage")) .stage else .todo,
                    .name = try memory.dupe(u8, stringField(tab, "name")),
                    .title = tab_labels[k],
                    .bridge = &screen.bridge,
                };
                page.setAircraftPath(path);
                page.stale = false;
                pages[k] = page;
            }
            labels[a] = try memory.dupeZ(u8, stringField(item, "title"));
            areas[a] = .{ .title = labels[a], .single = flag(item, "single"), .labels = tab_labels, .pages = pages };
        }
        screen.areas = areas;
        screen.area_labels = labels;
        screen.area = @min(screen.area, areas.len - 1);
        // o padrão é a Aerodinâmica → Analisar, como a aba que o aerosim em Zig abria antes
        if (screen.pending_tab == null) for (areas, 0..) |*area, a| if (std.mem.eql(u8, area.title, "Aerodinâmica")) {
            screen.area = a;
            area.active = area.pages.len - 1;
        };
        if (screen.pending_tab) |index| {
            var count: usize = 0;
            for (areas, 0..) |*area, a| for (area.pages, 0..) |_, k| {
                if (count == index) {
                    screen.area = a;
                    area.active = k;
                }
                count += 1;
            };
            screen.pending_tab = null;
        }
        if (screen.pending_file_len > 0) {
            const length = screen.pending_file_len;
            screen.pending_file_len = 0;
            screen.openFile(screen.pending_file[0..length]);
        }
    }

    /// desenha a tela inteira e trata o mouse
    pub fn draw(screen: *Screen, ui: *widgets.Ui, width: f32, height: f32) void {
        rl.clearBackground(theme.colors.background);
        screen.collectAircraft();
        screen.collectLayout();
        if (rl.isFileDropped()) {
            const dropped = rl.loadDroppedFiles();
            defer rl.unloadDroppedFiles(dropped);
            for (0..dropped.count) |k| {
                const path = std.mem.sliceTo(dropped.paths[k], 0);
                screen.openFile(path);
                if (std.mem.endsWith(u8, path, ".json")) screen.showAssembly();
            }
        }
        // a página aberta
        const page: ?*Page = if (screen.areas.len > 0) screen.areas[screen.area].pages[screen.areas[screen.area].active] else null;
        const single = screen.areas.len == 0 or screen.areas[screen.area].single;
        const top = widgets.header_height + 38 + (if (single) @as(f32, 0) else 32);
        // com uma janela aberta (seletor de arquivo, pergunta, condições), a tela de baixo não recebe o clique nem a roda
        const page_modal = if (page) |p| p.modalOpen() else false;
        const modal = screen.files.open or screen.requirements_open or page_modal;
        const wheel = ui.wheel;
        if (modal) {
            ui.click_taken = true;
            ui.wheel = 0;
        }
        const content: rl.Rectangle = .{ .x = 0, .y = top, .width = width, .height = height - top };
        if (page) |p| {
            p.process_io = screen.io;
            if (screen.shown != p) {
                if (screen.shown != null) p.markStale(); // outra página pode ter mudado o projeto
                screen.shown = p;
            }
            if (screen.pending_run) {
                p.command("rodar");
                screen.pending_run = false;
            }
            if (screen.scroll > 0) {
                p.scroll_to = screen.scroll;
                screen.scroll = 0;
            }
            p.draw(ui, content);
            if (p.wants_requirements) {
                p.wants_requirements = false;
                screen.requirements_open = true;
                screen.requirements.stale = true;
            }
            if (p.takeOpened()) |path| {
                screen.openAircraft(path);
                if (screen.findPage(p.goTo())) |target| screen.showPage(target) else screen.showAssembly();
            }
        } else if (screen.areas.len == 0 and screen.area == 0) {
            screen.drawWaiting(ui, content);
        } else {
            screen.shown = null;
            screen.drawAssembly(ui, content);
        }
        if (widgets.header(ui, width, "AeroSim", &.{ "Abrir avião (.json)", "Salvar .json" }, "managers em Python, contas no núcleo em Zig")) |button| {
            if (button == 0) screen.command("abrir") else screen.command("salvar");
        }
        _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, screen.area_labels, &screen.area, 14);
        if (!single) {
            const area = &screen.areas[screen.area];
            _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, area.labels, &area.active, 13);
        }
        if (modal) {
            ui.click_taken = false;
            ui.wheel = wheel;
            const whole: rl.Rectangle = .{ .x = 0, .y = 0, .width = width, .height = height };
            if (page) |p| p.drawModal(ui, whole);
            if (screen.requirements_open) screen.drawRequirements(ui, whole);
            const saving = screen.files.saving;
            if (screen.files.draw(ui, whole)) |path| {
                if (saving) screen.save(path) else {
                    screen.openAircraft(path);
                    screen.showAssembly();
                }
            }
        }
    }

    /// "Condições e restrições…": a etapa "requisitos" numa janela por cima; ao fechar, as etapas refazem a conta
    fn drawRequirements(screen: *Screen, ui: *widgets.Ui, whole: rl.Rectangle) void {
        rl.drawRectangleRec(whole, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const box: rl.Rectangle = .{ .x = whole.x + 60, .y = whole.y + 50, .width = whole.width - 120, .height = whole.height - 100 };
        _ = widgets.card(ui, box, "Condições, restrições e variáveis de projeto");
        screen.requirements.process_io = screen.io;
        screen.requirements.draw(ui, .{ .x = box.x + 4, .y = box.y + 40, .width = box.width - 8, .height = box.height - 90 });
        const close: rl.Rectangle = .{ .x = box.x + box.width - 140, .y = box.y + box.height - 44, .width = 120, .height = 32 };
        if (widgets.primaryButton(ui, close, "Fechar", true) or rl.isKeyPressed(.escape)) {
            screen.requirements_open = false;
            for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |p| if (p.kind == .stage) p.markStale();
        }
        ui.click_taken = true;
        ui.wheel = 0;
    }

    /// antes de as abas chegarem do Python
    fn drawWaiting(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const box: rl.Rectangle = .{ .x = rect.x + 40, .y = rect.y + 40, .width = @min(rect.width - 80, 720), .height = 150 };
        const inner = widgets.labeledCard(ui, box, "As abas vêm do Python");
        _ = widgets.paragraph(ui.fonts.regular, std.mem.sliceTo(&screen.message, 0), inner.x, inner.y + 10, inner.width, 15, theme.colors.label);
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

/// o texto de `key` num objeto JSON ("" se não há)
fn stringField(value: Json, key: []const u8) []const u8 {
    if (value != .object) return "";
    const found = value.object.get(key) orelse return "";
    return if (found == .string) found.string else "";
}

fn flag(value: Json, key: []const u8) bool {
    if (value != .object) return false;
    const found = value.object.get(key) orelse return false;
    return found == .bool and found.bool;
}

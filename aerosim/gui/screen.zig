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
const config_tab = @import("tabs/config_tab.zig");
const aircraft_model = @import("aircraft_model");
const manager = @import("manager");
const design = @import("design");

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
    fleet: [max_fleet]?assembly_mod.Assembly = [_]?assembly_mod.Assembly{null} ** max_fleet, // os outros aviões
    // abertos (as variantes); o lugar `fleet_current` fica vazio, porque esse está em `assembly`
    fleet_count: usize = 0,
    fleet_current: usize = 0,
    assembly_note: [240:0]u8 = [_:0]u8{0} ** 240,
    assembly_panel: ?AssemblyPanel = null, // o resumo ao lado do 3D (`config_tab.panel`), refeito ao abrir
    assembly_scroll: ui_kit.scroll.ScrollArea = .{},
    assembly_drag: ?PieceDrag = null, // a peça sendo arrastada no 3D
    assembly_angle: ViewAngle = .free, // a vista da Montagem: 3D livre ou lateral, superior e frontal em escala
    assembly_editor: ?AssemblyEditor = null, // a lista de componentes e o editor da peça escolhida
    pending_assembly: [256]u8 = undefined, // acao=montagem:...: botões ("+ EH"), "peca=N", "editar=campo=valor", "trazer=arquivo#N" ou "vista=Lateral", até o avião abrir
    pending_assembly_len: usize = 0,
    importing_file: bool = false, // a janela de arquivos aberta é a de trazer uma peça de outro avião
    loader: ui_kit.jobs.Job = .{}, // lê o .json fora do laço da tela
    loading: Loading = .{},
    message: [240:0]u8 = [_:0]u8{0} ** 240,

    /// abre a subaba de número `index`, contando todas em ordem (a Montagem é a última), para os prints
    pub fn selectTab(screen: *Screen, index: usize) void {
        screen.pending_tab = index;
    }

    /// a tela ainda vai mudar sozinha (aba ou "rodar" pendente, uma conta andando): o print espera
    pub fn busy(screen: *const Screen) bool {
        if (screen.pending_tab != null or screen.pending_run or screen.pending_assembly_len > 0) return true;
        const page = screen.shown orelse return false;
        return page.settling();
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
        } else if (std.mem.startsWith(u8, name, "montagem:")) { // um botão da Montagem pelo nome, para os prints
            const length = @min(name.len - 9, screen.pending_assembly.len - screen.pending_assembly_len);
            @memcpy(screen.pending_assembly[screen.pending_assembly_len..][0..length], name[9..][0..length]);
            screen.pending_assembly_len += length;
            if (screen.pending_assembly_len < screen.pending_assembly.len) {
                screen.pending_assembly[screen.pending_assembly_len] = ';';
                screen.pending_assembly_len += 1;
            }
        } else if (std.mem.eql(u8, name, "condicoes")) {
            screen.requirements_open = true;
        }
    }

    /// a edição do formulário vai para o arquivo aberto: grava na árvore, lê o avião de novo e refaz o 3D, o resumo e
    /// o formulário (o que "Salvar" grava passa a ser o texto editado)
    fn applyEdit(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        const editor = &(screen.assembly_editor orelse return);
        editor.readBack();
        const component = editor.list[editor.selected];
        config_tab.apply(opened.document_arena.allocator(), &opened.document, component, editor.specs) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "a edição não vale: {s}", .{@errorName(err)}) catch {};
            return;
        };
        screen.commitDocument(null);
    }

    /// lê de novo o avião da árvore do arquivo (depois de editar, acrescentar, remover ou trazer uma peça) e refaz o
    /// 3D, o resumo e a lista; `select` é a peça a deixar escolhida (null: a mesma linha)
    fn commitDocument(screen: *Screen, select: ?config_tab.Component) void {
        const opened = &(screen.assembly orelse return);
        const editor = &(screen.assembly_editor orelse return);
        var diagnosis: assembly_mod.Diagnosis = .{};
        const failed = blk: {
            const text = config_tab.serialize(std.heap.page_allocator, opened.document) catch |err| break :blk @errorName(err);
            defer std.heap.page_allocator.free(text);
            opened.reload(std.heap.page_allocator, io(), text, &diagnosis) catch |err| break :blk if (diagnosis.len > 0) diagnosis.text() else @errorName(err);
            // as superfícies presas ("presa em") vão para o ponto delas, e o avião é lido de novo
            const moved = config_tab.placeMounted(opened.document_arena.allocator(), &opened.document, &opened.loaded.ac) catch |err| break :blk @errorName(err);
            if (moved) {
                const placed = config_tab.serialize(std.heap.page_allocator, opened.document) catch |err| break :blk @errorName(err);
                defer std.heap.page_allocator.free(placed);
                opened.reload(std.heap.page_allocator, io(), placed, &diagnosis) catch |err| break :blk if (diagnosis.len > 0) diagnosis.text() else @errorName(err);
            }
            break :blk null;
        };
        if (failed) |reason| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "a edição não vale e foi desfeita: {s}", .{reason}) catch {};
            // a árvore volta a ser a do último avião que valeu (e o formulário, os valores dele)
            if (std.json.parseFromSliceLeaky(std.json.Value, opened.document_arena.allocator(), opened.source, .{})) |previous| {
                opened.document = previous;
            } else |_| {}
            editor.rebuild(&opened.loaded.ac) catch {};
            return;
        }
        if (screen.assembly_panel) |*old| old.deinit();
        screen.assembly_panel = AssemblyPanel.build(&opened.loaded.ac) catch null;
        if (select) |wanted| {
            const fresh = config_tab.components(editor.arena.allocator(), &opened.loaded.ac) catch &.{};
            for (fresh, 0..) |component, i| if (component.part == wanted.part and component.index == wanted.index) {
                editor.selected = i;
            };
            editor.form.area = .{};
        }
        editor.rebuild(&opened.loaded.ac) catch {};
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · editado (Salvar grava) · {d} peças", .{ std.fs.path.basename(opened.path), opened.mesh.piece_count }) catch {};
    }

    /// clicar numa peça no 3D escolhe ela na lista; arrastar move ela no plano da tela, e soltar grava a posição.
    /// Clicar fora das peças gira a vista, como antes
    fn dragPiece(screen: *Screen, ui: *widgets.Ui, area: rl.Rectangle) void {
        const opened = &(screen.assembly orelse return);
        const editor = &(screen.assembly_editor orelse return);
        if (screen.assembly_drag) |*drag| {
            if (rl.isMouseButtonDown(.left)) {
                const axes = screen.assembly_view.screenAxes();
                const scale = screen.assembly_view.metersPerPixel(area, drag.depth);
                const dx: f64 = ui.mouse.x - drag.start.x;
                const dy: f64 = ui.mouse.y - drag.start.y;
                for (&drag.offset, axes[0], axes[1]) |*moved, right, up| moved.* = scale * (dx * right - dy * up);
                return;
            }
            // soltou: grava
            const offset = drag.offset;
            const component = config_tab.componentOf(opened.mesh.components[drag.component]);
            screen.assembly_drag = null;
            if (@abs(offset[0]) + @abs(offset[1]) + @abs(offset[2]) < 1e-4) return;
            const target = component orelse return;
            const moved = config_tab.moveBy(opened.document_arena.allocator(), &opened.document, &opened.loaded.ac, target, offset) catch false;
            if (moved) screen.commitDocument(null);
            return;
        }
        if (!ui.clicked or ui.click_taken or !ui.hovering(area)) return;
        const ray = screen.assembly_view.ray(ui.mouse, area) orelse return;
        const hit = opened.mesh.pick(ray) orelse return;
        ui.click_taken = true; // a vista não gira
        const key = opened.mesh.components[hit.component];
        if (config_tab.componentOf(key)) |component| {
            for (editor.list, 0..) |row, i| if (row.part == component.part and row.index == component.index and i != editor.selected) {
                editor.selected = i;
                editor.form.area = .{};
                editor.want_rebuild = true;
            };
        }
        screen.assembly_drag = .{ .component = hit.component, .start = ui.mouse, .depth = hit.distance };
    }

    /// "Restaurar": o avião volta a ser o do arquivo como foi aberto (desfaz todas as edições)
    fn restoreAircraft(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        opened.document = std.json.parseFromSliceLeaky(std.json.Value, opened.document_arena.allocator(), opened.original, .{}) catch return;
        screen.commitDocument(null);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · restaurado como foi aberto", .{std.fs.path.basename(opened.path)}) catch {};
    }

    /// "Acertar o CG" (`design.balance.rebalance`): move a bateria ou o lastro para o CG voltar ao de projeto
    fn fitCg(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        const memory = opened.document_arena.allocator();
        const result = design.balance.rebalance(memory, &opened.loaded.ac) catch return;
        if (result.mover) |mover| {
            const written = blk: {
                const node = if (opened.document.object.getPtr("aeronave")) |inner| &inner.object else &opened.document.object;
                switch (mover) {
                    .item => |index| {
                        const mass = node.getPtr("mass") orelse break :blk false;
                        const items = mass.object.getPtr("items") orelse break :blk false;
                        if (index >= items.array.items.len) break :blk false;
                        items.array.items[index].object.put(memory, "x", .{ .float = result.x }) catch break :blk false;
                    },
                    .ballast => {
                        const ballast = node.getPtr("ballast") orelse break :blk false;
                        ballast.object.put(memory, "x", .{ .float = result.x }) catch break :blk false;
                    },
                }
                break :blk true;
            };
            if (written) screen.commitDocument(null);
        }
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s}{s}", .{ if (result.ok) "CG acertado: " else "CG não acertado: ", result.message }) catch {};
    }

    /// um botão embaixo da lista: acrescenta uma peça, remove a escolhida ou abre outro arquivo para trazer uma peça dele
    fn partButton(screen: *Screen, pressed: usize) void {
        const opened = &(screen.assembly orelse return);
        const editor = &(screen.assembly_editor orelse return);
        const memory = opened.document_arena.allocator();
        if (pressed < new_parts.len) {
            const added = config_tab.add(memory, &opened.document, &opened.loaded.ac, new_parts[pressed]) catch |err| {
                _ = std.fmt.bufPrintZ(&screen.assembly_note, "não acrescentou: {s}", .{@errorName(err)}) catch {};
                return;
            };
            return screen.commitDocument(added);
        }
        if (pressed == new_parts.len) { // Remover
            const component = editor.list[editor.selected];
            const removed = config_tab.remove(memory, &opened.document, component) catch false;
            if (!removed) {
                _ = std.fmt.bufPrintZ(&screen.assembly_note, "'{s}' não se remove (é um dado do avião, não uma peça)", .{component.label}) catch {};
                return;
            }
            if (editor.selected > 0 and editor.selected + 1 >= editor.list.len) editor.selected -= 1;
            return screen.commitDocument(null);
        }
        screen.importing_file = true; // Trazer de outro .json
        screen.files.show("Trazer uma peça de outro avião (.json)", std.fs.path.dirname(opened.path) orelse ".", &.{".json"});
    }

    /// os comandos da Montagem pedidos na linha de comando, agora que o avião abriu
    fn runPendingAssembly(screen: *Screen) void {
        var pending: [256]u8 = undefined;
        const length = screen.pending_assembly_len;
        @memcpy(pending[0..length], screen.pending_assembly[0..length]);
        screen.pending_assembly_len = 0;
        var steps = std.mem.tokenizeScalar(u8, pending[0..length], ';');
        while (steps.next()) |step| {
            if (std.mem.startsWith(u8, step, "vista=")) {
                for (std.enums.values(ViewAngle)) |angle| if (std.ascii.eqlIgnoreCase(angle.caption(), step[6..])) {
                    screen.assembly_angle = angle;
                };
            } else if (std.mem.startsWith(u8, step, "editar=")) { // editar=campo=valor na peça escolhida
                const rest = step[7..];
                const equal = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
                const editor = &screen.assembly_editor.?;
                const opened = &screen.assembly.?;
                for (editor.specs) |*spec| if (std.mem.eql(u8, spec.name, rest[0..equal])) {
                    const value = rest[equal + 1 ..];
                    switch (spec.kind) {
                        .number, .integer, .optional_number => {
                            spec.number = std.fmt.parseFloat(f64, value) catch spec.number;
                            spec.automatic = false;
                        },
                        .toggle => spec.checked = std.mem.eql(u8, value, "sim"),
                        .choice, .text => spec.text = value,
                    }
                    break;
                };
                config_tab.apply(opened.document_arena.allocator(), &opened.document, editor.list[editor.selected], editor.specs) catch continue;
                screen.commitDocument(null);
            } else if (std.mem.startsWith(u8, step, "peca=")) {
                const index = std.fmt.parseInt(usize, step[5..], 10) catch continue;
                const editor = &screen.assembly_editor.?;
                editor.selected = index;
                editor.rebuild(&screen.assembly.?.loaded.ac) catch {};
            } else if (std.mem.startsWith(u8, step, "trazer=")) {
                const hash = std.mem.lastIndexOfScalar(u8, step, '#') orelse continue;
                screen.startImport(step[7..hash]);
                const index = std.fmt.parseInt(usize, step[hash + 1 ..], 10) catch continue;
                screen.importPart(index);
            } else if (std.mem.startsWith(u8, step, "mover=")) { // mover=dx dy dz na peça escolhida (o que o arraste grava)
                var offset: view3d.Body = .{ 0, 0, 0 };
                var numbers = std.mem.tokenizeScalar(u8, step[6..], ' ');
                for (&offset) |*moved| moved.* = std.fmt.parseFloat(f64, numbers.next() orelse "0") catch 0;
                const editor = &screen.assembly_editor.?;
                const opened = &screen.assembly.?;
                const moved = config_tab.moveBy(opened.document_arena.allocator(), &opened.document, &opened.loaded.ac, editor.list[editor.selected], offset) catch false;
                if (moved) screen.commitDocument(null);
            } else if (std.mem.eql(u8, step, "Restaurar")) {
                screen.restoreAircraft();
            } else if (std.mem.eql(u8, step, "Acertar o CG")) {
                screen.fitCg();
            } else {
                for (part_buttons, 0..) |caption, i| if (std.mem.eql(u8, caption, step)) screen.partButton(i);
                for (fleet_buttons, 0..) |caption, i| if (std.mem.eql(u8, caption, step)) screen.fleetButton(i);
            }
        }
    }

    /// um botão da barra dos aviões abertos (`fleet_buttons`)
    fn fleetButton(screen: *Screen, pressed: usize) void {
        switch (pressed) {
            0 => if (screen.fleet_current > 0) screen.selectAircraft(screen.fleet_current - 1),
            1 => screen.selectAircraft(screen.fleet_current + 1),
            2 => screen.addVariant(),
            else => screen.closeAircraft(),
        }
    }

    /// "+" ou "−" de uma lista da peça (seções, comandos...)
    fn listButton(screen: *Screen, pressed: usize) void {
        const opened = &(screen.assembly orelse return);
        const editor = &(screen.assembly_editor orelse return);
        const list = editor.lists[pressed / 2];
        const component = editor.list[editor.selected];
        const memory = opened.document_arena.allocator();
        if (pressed % 2 == 0) {
            config_tab.addItem(memory, &opened.document, &opened.loaded.ac, component, list.key) catch return;
        } else {
            const removed = config_tab.removeItem(memory, &opened.document, component, list.key) catch false;
            if (!removed) return;
        }
        screen.commitDocument(null);
    }

    /// abriu o arquivo de onde trazer a peça: mostra as peças dele no lugar da lista
    fn startImport(screen: *Screen, path: []const u8) void {
        const editor = &(screen.assembly_editor orelse return);
        editor.stopImport();
        editor.importing = ImportSource.read(path) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não abriu '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) }) catch {};
            return;
        };
    }

    /// traz a peça `index` do arquivo aberto para importar
    fn importPart(screen: *Screen, index: usize) void {
        const opened = &(screen.assembly orelse return);
        const editor = &(screen.assembly_editor orelse return);
        const source = &(editor.importing orelse return);
        const imported = config_tab.importPart(opened.document_arena.allocator(), &opened.document, &source.document, source.list[index]) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não trouxe a peça: {s}", .{@errorName(err)}) catch {};
            return;
        };
        editor.stopImport();
        screen.commitDocument(imported);
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
        if (screen.fleet_count == 0) screen.fleet_count = 1; // abrir troca o avião atual; os outros ficam
        screen.showSwitched();
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · {d} peças · arraste outro .json para a janela para trocar · arraste para girar, roda para aproximar", .{ std.fs.path.basename(path), loaded.mesh.piece_count }) catch {};
    }

    /// depois de trocar o avião atual (abrir, variante, troca, fechar): o resumo, a lista e o editor são do novo, e as
    /// páginas passam a usar o arquivo dele
    fn showSwitched(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        if (screen.assembly_panel) |*old| old.deinit();
        screen.assembly_panel = AssemblyPanel.build(&opened.loaded.ac) catch null;
        if (screen.assembly_editor == null) screen.assembly_editor = .{};
        const editor = &screen.assembly_editor.?;
        editor.stopImport();
        editor.selected = 0;
        editor.form.area = .{};
        editor.rebuild(&opened.loaded.ac) catch {};
        screen.assembly_drag = null;
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| page.setAircraftPath(opened.path);
    }

    /// passa para o avião aberto `index` (a barra "Anterior", "Próximo"); o atual fica guardado como está
    fn selectAircraft(screen: *Screen, index: usize) void {
        if (index >= screen.fleet_count or index == screen.fleet_current or screen.assembly == null) return;
        screen.fleet[screen.fleet_current] = screen.assembly;
        screen.assembly = screen.fleet[index];
        screen.fleet[index] = null;
        screen.fleet_current = index;
        screen.showSwitched();
        screen.fleetNote("aberto");
    }

    /// "+ Variante": uma cópia do avião atual, com as edições dele, para variar a partir dele, e passa para ela
    fn addVariant(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        if (screen.fleet_count >= max_fleet) {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "já há {d} aviões abertos; feche um antes", .{max_fleet}) catch {};
            return;
        }
        var diagnosis: assembly_mod.Diagnosis = .{};
        const copy = assembly_mod.fromBytes(std.heap.page_allocator, io(), opened.path, opened.source, &diagnosis) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "a variante não abriu: {s}", .{if (diagnosis.len > 0) diagnosis.text() else @errorName(err)}) catch {};
            return;
        };
        var name_buffer: [160]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s} (variante {d})", .{ opened.loaded.ac.name, screen.fleet_count + 1 }) catch opened.loaded.ac.name;
        screen.fleet[screen.fleet_current] = screen.assembly;
        screen.assembly = copy;
        screen.fleet_current = screen.fleet_count;
        screen.fleet_count += 1;
        const fresh = &screen.assembly.?;
        config_tab.rename(fresh.document_arena.allocator(), &fresh.document, name) catch {};
        screen.showSwitched();
        screen.commitDocument(null);
        screen.fleetNote("variante nova");
    }

    /// "Fechar": fecha o avião atual e passa para o vizinho (o último que sobra não fecha)
    fn closeAircraft(screen: *Screen) void {
        if (screen.fleet_count <= 1) return;
        if (screen.assembly) |*old| old.deinit();
        const removed = screen.fleet_current;
        for (removed..screen.fleet_count - 1) |slot| screen.fleet[slot] = screen.fleet[slot + 1];
        screen.fleet_count -= 1;
        screen.fleet[screen.fleet_count] = null;
        screen.fleet_current = @min(removed, screen.fleet_count - 1);
        screen.assembly = screen.fleet[screen.fleet_current];
        screen.fleet[screen.fleet_current] = null;
        screen.showSwitched();
        screen.fleetNote("aberto");
    }

    /// a nota embaixo do 3D: qual avião é este entre os abertos
    fn fleetNote(screen: *Screen, what: []const u8) void {
        const opened = &(screen.assembly orelse return);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s}: {s} ({d} de {d}) · {d} peças", .{ what, opened.loaded.ac.name, screen.fleet_current + 1, screen.fleet_count, opened.mesh.piece_count }) catch {};
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

    /// a análise em Zig entra como subaba nova nesta área (é da área e nenhuma subaba do Python tem o nome dela)
    fn appended(simulation: *const manager.Simulation, area_title: []const u8, tabs: []const Json) bool {
        if (!std.mem.eql(u8, simulation.area, area_title)) return false;
        for (tabs) |tab| if (std.mem.eql(u8, stringField(tab, "name"), simulation.name)) return false;
        return true;
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
            const area_title = stringField(item, "title");
            // uma análise em Zig com o nome de uma do Python toma o lugar dela na mesma subaba; as outras em Zig desta
            // área entram depois das do Python (`manager/manager.zig`)
            var zig_analyses: usize = 0;
            for (&manager.all) |*simulation| zig_analyses += @intFromBool(appended(simulation, area_title, tabs));
            const tab_labels = try memory.alloc([:0]const u8, tabs.len + zig_analyses);
            const pages = try memory.alloc(?*Page, tabs.len + zig_analyses);
            for (tabs, 0..) |tab, k| {
                tab_labels[k] = try memory.dupeZ(u8, stringField(tab, "title"));
                const kind_text = stringField(tab, "kind");
                if (std.mem.eql(u8, kind_text, "assembly")) {
                    pages[k] = null;
                    continue;
                }
                const page = try std.heap.page_allocator.create(Page);
                const is_simulation = std.mem.eql(u8, kind_text, "sim");
                const in_zig = if (is_simulation) manager.find(stringField(tab, "name")) else null;
                page.* = .{
                    .kind = if (is_simulation) .simulation else if (std.mem.eql(u8, kind_text, "stage")) .stage else .todo,
                    .name = try memory.dupe(u8, stringField(tab, "name")),
                    .title = tab_labels[k],
                    .bridge = &screen.bridge,
                    .analysis = in_zig, // já portada para o Zig: roda sem o Python
                    .grids_beside = false,
                };
                page.setAircraftPath(path);
                page.stale = false;
                pages[k] = page;
            }
            var slot = tabs.len;
            for (&manager.all) |*simulation| if (appended(simulation, area_title, tabs)) {
                const page = try std.heap.page_allocator.create(Page);
                page.* = .{ .kind = .simulation, .name = simulation.name, .title = simulation.title, .bridge = &screen.bridge, .analysis = simulation, .grids_beside = true };
                page.setAircraftPath(path);
                page.stale = false;
                tab_labels[slot] = simulation.title;
                pages[slot] = page;
                slot += 1;
            };
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
                if (saving) screen.save(path) else if (screen.importing_file) {
                    screen.importing_file = false;
                    screen.startImport(path);
                } else {
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

    /// a Montagem: à esquerda o resumo do avião (massa e CG, dimensões, aerodinâmica...), à direita o avião aberto em
    /// 3D, todas as peças nas cores da GUI, com o chão e os eixos do corpo
    fn drawAssembly(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        // à esquerda a lista de componentes e o resumo embaixo; à direita o editor da peça; no meio o 3D
        const side_width: f32 = if (screen.assembly_panel != null) @min(460, rect.width * 0.3) else 0;
        const editor_width: f32 = if (screen.assembly_editor != null and screen.assembly != null) @min(400, rect.width * 0.26) else 0;
        var list_height: f32 = 0;
        if (screen.pending_assembly_len > 0 and screen.assembly != null and screen.assembly_editor != null) screen.runPendingAssembly();
        if (screen.assembly_editor) |*editor| if (screen.assembly) |*opened| if (editor.want_rebuild) {
            editor.want_rebuild = false;
            editor.rebuild(&opened.loaded.ac) catch {};
        };
        if (screen.assembly_editor) |*editor| if (screen.assembly) |*opened| {
            // os aviões abertos (a barra das variantes do Python): qual é este, trocar, uma variante nova e fechar
            var fleet_buffer: [200]u8 = undefined;
            theme.text(ui.fonts.bold, widgets.format(&fleet_buffer, "Avião {d} de {d}: {s}", .{ screen.fleet_current + 1, screen.fleet_count, opened.loaded.ac.name }), rect.x + 16, rect.y + 12, 15, theme.colors.ink);
            var fleet_height: f32 = 0;
            if (ui_kit.menus.buttonGrid(ui, rect.x + 12, rect.y + 34, side_width - 6, &fleet_buttons, 4, &fleet_height)) |pressed| {
                screen.fleetButton(pressed);
                return;
            }
            const wind_top = 34 + fleet_height + 10;
            // o vento (a caixa "Vento" do Python): a velocidade a 10 m e de onde vem, de 1 m/s e de 15° por clique
            const environment = opened.loaded.ac.environment;
            var wind_buffer: [96]u8 = undefined;
            theme.text(ui.fonts.bold, widgets.format(&wind_buffer, "Vento: {d:.1} m/s a 10 m, vem de {d:.0}°", .{ environment.wind_speed, environment.wind_from }), rect.x + 16, rect.y + wind_top, 15, theme.colors.ink);
            var wind_height: f32 = 0;
            const wind_buttons = [_][:0]const u8{ "− 1 m/s", "+ 1 m/s", "−15°", "+15°" };
            if (ui_kit.menus.buttonGrid(ui, rect.x + 12, rect.y + wind_top + 22, side_width - 6, &wind_buttons, 4, &wind_height)) |pressed| {
                const speed = @max(0, environment.wind_speed + switch (pressed) {
                    0 => @as(f64, -1),
                    1 => 1,
                    else => 0,
                });
                const turned = environment.wind_from + switch (pressed) {
                    2 => @as(f64, -15),
                    3 => 15,
                    else => 0,
                };
                const from = @mod(turned + 180, 360) - 180; // −180 a 180, como o mostrador do Python
                config_tab.setWind(opened.document_arena.allocator(), &opened.document, speed, from) catch {};
                screen.commitDocument(null);
            }
            const top = wind_top + 22 + wind_height + 8;
            list_height = @min(300, rect.height * 0.32);
            const list_rect: rl.Rectangle = .{ .x = rect.x + 12, .y = rect.y + top, .width = side_width - 6, .height = list_height };
            var buttons_height: f32 = 0;
            if (editor.importing) |*source| {
                if (source.drawList(ui, list_rect)) |picked| screen.importPart(picked);
                if (ui_kit.menus.buttonGrid(ui, list_rect.x, list_rect.y + list_height + 8, list_rect.width, &.{"Cancelar"}, 1, &buttons_height) != null) editor.stopImport();
            } else {
                editor.drawList(ui, list_rect);
                if (ui_kit.menus.buttonGrid(ui, list_rect.x, list_rect.y + list_height + 8, list_rect.width, &part_buttons, 4, &buttons_height)) |pressed| screen.partButton(pressed);
            }
            list_height += top - 12 + 8 + buttons_height + 6;
        };
        if (screen.assembly_panel) |*shown| shown.draw(ui, &screen.assembly_scroll, .{ .x = rect.x + 12, .y = rect.y + 12 + list_height, .width = side_width - 6, .height = rect.height - 24 - list_height });
        if (editor_width > 0) {
            const editor = &screen.assembly_editor.?;
            const editor_rect: rl.Rectangle = .{ .x = rect.x + rect.width - 12 - editor_width + 6, .y = rect.y + 12, .width = editor_width - 6, .height = rect.height - 24 };
            var list_button: ?usize = null;
            if (editor.drawForm(ui, editor_rect, &list_button)) screen.applyEdit();
            if (list_button) |pressed| screen.listButton(pressed);
        }
        const card_rect: rl.Rectangle = .{ .x = rect.x + 12 + side_width, .y = rect.y + 12, .width = rect.width - 24 - side_width - editor_width, .height = rect.height - 24 };
        const area = cardInside(card_rect);
        screen.dragPiece(ui, area);
        screen.assembly_view.handleInput(ui, area);
        if (screen.assembly_view.dragging) screen.assembly_angle = .free;
        screen.assembly_angle.aim(&screen.assembly_view);
        var title_buffer: [160]u8 = undefined;
        var title: [:0]const u8 = "Montagem: nenhum avião aberto (arraste um .json para a janela)";
        if (screen.assembly) |*opened| {
            const plane = &opened.mesh;
            // o nome do avião está no resumo; o título curto deixa lugar para os botões
            title = widgets.format(&title_buffer, "Montagem", .{});
            // na lateral (cortada no plano de simetria), o zoom é no comprimento e na altura, sem a envergadura
            const size = if (screen.assembly_angle == .side) @max(plane.high[0] - plane.low[0], plane.high[2] - plane.low[2]) else plane.size();
            const middle = plane.center();
            // a vista mais estreita (com o resumo ao lado) afasta a câmera para caberem o avião e os eixos
            const narrow: f64 = if (screen.assembly_angle != .free) 1.0 else @max(1.0, 1.6 * area.height / @max(area.width, 1));
            if (screen.assembly_view.begin(area, middle, 1.1 * size * narrow)) {
                defer screen.assembly_view.end();
                // o chão um pouco abaixo da peça mais baixa (z para baixo), quadriculado de 25 cm
                view3d.floor(.{ middle[0], middle[1], 0 }, plane.high[2] + 0.02, 1.6 * size, 0.25);
                // a lateral é um corte: só a metade do lado de lá do plano de simetria (y ≥ 0), vista de dentro
                const moving: ?u16 = if (screen.assembly_drag) |drag| drag.component else null;
                const offset: [3]f64 = if (screen.assembly_drag) |drag| drag.offset else .{ 0, 0, 0 };
                if (screen.assembly_angle == .side) plane.drawCut(1, 0) else plane.drawMoving(moving, offset);
                const weights = assembly_mod.balance(&opened.loaded.ac);
                // o CG e as cotas por cima das peças (sem o teste de profundidade), para se verem atrás da asa
                rl.gl.rlDrawRenderBatchActive();
                rl.gl.rlDisableDepthTest();
                drawBalance(&screen.assembly_view, weights, plane.low[2], size);
                drawWind(&screen.assembly_view, opened.loaded.ac.environment, middle, plane.low[2], size);
                if (screen.assembly_angle != .free) drawCgDimensions(&screen.assembly_view, screen.assembly_angle, weights.cg, size);
                rl.gl.rlDrawRenderBatchActive();
                rl.gl.rlEnableDepthTest();
                view3d.bodyAxes(&screen.assembly_view, .{ plane.low[0] - 0.12 * size, plane.low[1] - 0.12 * size, plane.high[2] + 0.04 * size }, 0.14 * size);
            }
        }
        _ = widgets.card(ui, card_rect, title);
        if (screen.assembly) |*opened| {
            screen.assembly_view.blit(ui, area);
            // o símbolo do CG por cima de tudo (na imagem já colada): o círculo em quartos preto e branco
            const weights = assembly_mod.balance(&opened.loaded.ac);
            if (screen.assembly_view.project(weights.cg, area)) |at| {
                ui.pushClip(area);
                defer ui.popClip();
                drawCgSymbol(at, 7);
                theme.text(ui.fonts.bold, "CG", at.x + 12, at.y - 8, 14, theme.hex(0xd62728));
            }
            // numa vista em escala, as coordenadas do CG que ela mostra, a partir da referência (0, 0, 0)
            const axes: ?[2]usize = switch (screen.assembly_angle) {
                .side => .{ 0, 2 },
                .top => .{ 0, 1 },
                .front => .{ 1, 2 },
                .free => null,
            };
            if (axes) |shown| {
                const cg = assembly_mod.balance(&opened.loaded.ac).cg;
                const names = [3][]const u8{ "x", "y", "z" };
                var buffer: [160]u8 = undefined;
                const text = widgets.format(&buffer, "{s}_CG = {d:.3} m     {s}_CG = {d:.3} m     (a partir da referência, a cruz cinza)", .{ names[shown[0]], cg[shown[0]], names[shown[1]], cg[shown[1]] });
                theme.text(ui.fonts.bold, text, area.x + 10, area.y + 8, 16, theme.hex(0xd62728));
            }
        }
        // "Restaurar" e "Acertar o CG", antes dos botões das vistas
        if (screen.assembly != null) {
            const actions = [_][:0]const u8{ "Restaurar", "Acertar o CG" };
            for (actions, 0..) |caption, k| {
                const button_width: f32 = 110;
                const button: rl.Rectangle = .{ .x = card_rect.x + card_rect.width - 8 - 4 * (86 + 6) - 12 - (2 - @as(f32, @floatFromInt(k))) * (button_width + 6), .y = card_rect.y + 5, .width = button_width, .height = 26 };
                if (ui_kit.dialogs.button(ui, button, caption)) {
                    if (k == 0) screen.restoreAircraft() else screen.fitCg();
                }
            }
        }
        // os botões das vistas, à direita do título (por cima do cartão); arrastar volta ao 3D livre
        for (std.enums.values(ViewAngle), 0..) |angle, k| {
            const button_width: f32 = 86;
            const button: rl.Rectangle = .{ .x = card_rect.x + card_rect.width - 8 - (4 - @as(f32, @floatFromInt(k))) * (button_width + 6), .y = card_rect.y + 5, .width = button_width, .height = 26 };
            if (ui_kit.dialogs.button(ui, button, angle.caption())) screen.assembly_angle = angle;
            if (screen.assembly_angle == angle) rl.drawRectangleLinesEx(button, 2, theme.colors.accent);
        }
        theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.assembly_note, 0), area.x + 6, area.y + area.height - 18, 12, theme.colors.muted);
    }
};

/// a lista de componentes da Montagem e o formulário da peça escolhida (`_fill_list` e `_edit` do Python): os campos
/// saem de `config_tab.specs`, a edição vai para a árvore do arquivo (`config_tab.apply`) e o avião é lido de novo
const AssemblyEditor = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    list: []const config_tab.Component = &.{},
    labels: []const [:0]const u8 = &.{},
    selected: usize = 0,
    specs: []config_tab.Spec = &.{},
    first_field: []usize = &.{}, // o primeiro campo do formulário de cada `specs[i]` (o número opcional tem dois)
    form: ui_kit.form.Form = .{ .groups = &.{}, .fields = &.{} },
    list_scroll: ui_kit.scroll.ScrollArea = .{},
    title: [:0]const u8 = "",
    lists: []const config_tab.EditableList = &.{}, // as listas da peça (seções, comandos...), com "+" e "−"
    list_buttons: []const [:0]const u8 = &.{},
    want_rebuild: bool = false, // escolheu outra peça: refazer o formulário no quadro
    importing: ?ImportSource = null, // o outro avião de onde trazer uma peça (a lista mostra as peças dele)

    /// fecha o outro avião sem trazer nada
    fn stopImport(editor: *AssemblyEditor) void {
        if (editor.importing) |*source| source.deinit();
        editor.importing = null;
    }

    /// refaz a lista e os campos da peça escolhida com os valores de `aircraft`
    fn rebuild(editor: *AssemblyEditor, aircraft: *const aircraft_model.aircraft.Aircraft) !void {
        _ = editor.arena.reset(.retain_capacity);
        const memory = editor.arena.allocator();
        editor.list = try config_tab.components(memory, aircraft);
        const labels = try memory.alloc([:0]const u8, editor.list.len);
        for (editor.list, labels) |component, *label| label.* = try memory.dupeZ(u8, component.label);
        editor.labels = labels;
        if (editor.selected >= editor.list.len) editor.selected = 0;
        const component = editor.list[editor.selected];
        editor.title = labels[editor.selected];
        const form_layout = try config_tab.layout(memory, aircraft, component);
        editor.specs = form_layout.specs;
        editor.lists = form_layout.lists;
        const captions = try memory.alloc([:0]const u8, 2 * form_layout.lists.len);
        for (form_layout.lists, 0..) |list, k| {
            captions[2 * k] = try std.fmt.allocPrintSentinel(memory, "+ {s}", .{list.item}, 0);
            captions[2 * k + 1] = try std.fmt.allocPrintSentinel(memory, "− {s}", .{list.item}, 0);
        }
        editor.list_buttons = captions;
        var fields: std.ArrayList(ui_kit.form.Field) = .empty;
        editor.first_field = try memory.alloc(usize, editor.specs.len);
        for (editor.specs, editor.first_field) |spec, *first| {
            first.* = fields.items.len;
            const label = try memory.dupeZ(u8, spec.label);
            const unit = try memory.dupeZ(u8, spec.unit);
            const help = try memory.dupeZ(u8, spec.help);
            var field: ui_kit.form.Field = .{ .label = label, .unit = unit, .help = help, .group = spec.group };
            switch (spec.kind) {
                .number, .integer => field.number = spec.number,
                .optional_number => {
                    try fields.append(memory, .{ .label = try std.fmt.allocPrintSentinel(memory, "{s}: auto", .{spec.label}, 0), .help = help, .group = spec.group, .kind = .toggle, .checked = spec.automatic });
                    field.number = spec.number;
                    field.enabled = !spec.automatic;
                },
                .toggle => {
                    field.kind = .toggle;
                    field.checked = spec.checked;
                },
                .choice => {
                    field.kind = .choice;
                    field.choices = try std.mem.joinZ(memory, ";", spec.choices);
                    for (spec.choices, 0..) |option, k| if (std.mem.eql(u8, option, spec.text)) {
                        field.choice = @intCast(k);
                    };
                },
                .text => {
                    field.kind = .text;
                    field.setText(spec.text);
                },
            }
            try fields.append(memory, field);
        }
        const groups = try memory.alloc(ui_kit.form.Group, form_layout.groups.len);
        for (groups, form_layout.groups, 0..) |*group, title, g| group.* = .{ .title = if (g == 0) editor.title else try memory.dupeZ(u8, title) };
        editor.form.groups = groups;
        editor.form.fields = fields.items;
        editor.form.editing = null;
        editor.form.open_choice = null;
    }

    /// os valores do formulário de volta nos campos
    fn readBack(editor: *AssemblyEditor) void {
        const fields = editor.form.fields;
        for (editor.specs, editor.first_field) |*spec, first| {
            switch (spec.kind) {
                .number, .integer => spec.number = fields[first].number,
                .optional_number => {
                    spec.automatic = fields[first].checked;
                    spec.number = fields[first + 1].number;
                },
                .toggle => spec.checked = fields[first].checked,
                .choice => spec.text = if (fields[first].choice >= 0 and fields[first].choice < spec.choices.len) spec.choices[@intCast(fields[first].choice)] else spec.text,
                .text => spec.text = fields[first].textValue(),
            }
        }
    }

    /// a lista de componentes, um por linha; o clique escolhe a peça
    fn drawList(editor: *AssemblyEditor, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const row_height: f32 = 22;
        theme.text(ui.fonts.bold, "Componentes", rect.x + 4, rect.y, 16, theme.colors.ink);
        const box: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 24, .width = rect.width, .height = rect.height - 24 };
        rl.drawRectangleRec(box, theme.colors.field);
        rl.drawRectangleLinesEx(box, 1, theme.colors.line);
        var y = editor.list_scroll.begin(ui, box);
        var picked: ?usize = null;
        for (editor.labels, 0..) |label, i| {
            const row: rl.Rectangle = .{ .x = box.x + 1, .y = y, .width = box.width - 14, .height = row_height };
            if (i == editor.selected) rl.drawRectangleRec(row, theme.colors.accent_hover) else if (ui.hovering(row)) rl.drawRectangleRec(row, theme.colors.hover);
            theme.text(ui.fonts.regular, label, row.x + 6, row.y + 3, 14, if (i == editor.selected) theme.colors.on_accent else theme.colors.ink);
            if (ui.clickedIn(row)) picked = i;
            y += row_height;
        }
        editor.list_scroll.end(ui, box, y + 4);
        if (picked) |index| if (index != editor.selected) {
            editor.selected = index;
            editor.form.area = .{};
            editor.want_rebuild = true;
        };
    }

    /// o formulário da peça e, embaixo, o "+" e o "−" de cada lista; verdadeiro se um valor mudou (`list_button` diz
    /// qual botão foi apertado)
    fn drawForm(editor: *AssemblyEditor, ui: *widgets.Ui, rect: rl.Rectangle, list_button: *?usize) bool {
        var buttons_height: f32 = 36 * @as(f32, @floatFromInt(editor.lists.len));
        var form_rect = rect;
        form_rect.height -= buttons_height + (if (editor.lists.len > 0) @as(f32, 8) else 0);
        if (editor.lists.len > 0) list_button.* = ui_kit.menus.buttonGrid(ui, rect.x, form_rect.y + form_rect.height + 8, rect.width, editor.list_buttons, 2, &buttons_height);
        const changed = editor.form.draw(ui, form_rect);
        // o número opcional: a caixa só edita fora do "auto"
        for (editor.specs, editor.first_field) |spec, first| if (spec.kind == .optional_number) {
            editor.form.fields[first + 1].enabled = !editor.form.fields[first].checked;
        };
        return changed;
    }
};

/// os botões embaixo da lista de componentes, na ordem do Python, mais o de trazer uma peça de outro arquivo
const new_parts = [_]config_tab.NewPart{ .wing, .htail, .vtail, .motor, .boom, .tank };
/// a barra dos aviões abertos na Montagem
const fleet_buttons = [_][:0]const u8{ "Anterior", "Próximo", "+ Variante", "Fechar" };
/// quantos aviões ficam abertos ao mesmo tempo
const max_fleet = 8;

const part_buttons = [_][:0]const u8{ "+ Asa", "+ EH", "+ EV", "+ Motor", "+ Tubo", "+ Tanque", "Remover", "Trazer de .json" };

/// o outro avião aberto para trazer uma peça dele: a árvore do arquivo e a lista das peças
const ImportSource = struct {
    arena: *std.heap.ArenaAllocator, // fora da struct: as listas da árvore guardam o ponteiro do alocador
    document: std.json.Value,
    list: []const config_tab.Component,
    labels: []const [:0]const u8,
    title: [:0]const u8,
    scroll: ui_kit.scroll.ScrollArea = .{},

    fn read(path: []const u8) !ImportSource {
        const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        errdefer std.heap.page_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, memory, .limited(assembly_mod.max_file_bytes));
        var diagnosis: assembly_mod.Diagnosis = .{};
        var loaded = try aircraft_model.aircraft.parse(std.heap.page_allocator, bytes, &diagnosis);
        defer loaded.deinit();
        const list = try config_tab.components(memory, &loaded.ac);
        const labels = try memory.alloc([:0]const u8, list.len);
        for (list, labels) |*component, *label| {
            component.label = try memory.dupe(u8, component.label);
            label.* = try memory.dupeZ(u8, component.label);
        }
        return .{
            .arena = arena,
            .document = try std.json.parseFromSliceLeaky(std.json.Value, memory, bytes, .{}),
            .list = list,
            .labels = labels,
            .title = try std.fmt.allocPrintSentinel(memory, "Trazer de {s}", .{loaded.ac.name}, 0),
        };
    }

    fn deinit(source: *ImportSource) void {
        source.arena.deinit();
        std.heap.page_allocator.destroy(source.arena);
    }

    /// as peças do outro avião; devolve a clicada
    fn drawList(source: *ImportSource, ui: *widgets.Ui, rect: rl.Rectangle) ?usize {
        const row_height: f32 = 22;
        theme.text(ui.fonts.bold, source.title, rect.x + 4, rect.y, 16, theme.colors.accent);
        const box: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 24, .width = rect.width, .height = rect.height - 24 };
        rl.drawRectangleRec(box, theme.colors.field);
        rl.drawRectangleLinesEx(box, 1, theme.colors.accent);
        var y = source.scroll.begin(ui, box);
        var picked: ?usize = null;
        for (source.labels, 0..) |label, i| {
            const row: rl.Rectangle = .{ .x = box.x + 1, .y = y, .width = box.width - 14, .height = row_height };
            if (ui.hovering(row)) rl.drawRectangleRec(row, theme.colors.hover);
            theme.text(ui.fonts.regular, label, row.x + 6, row.y + 3, 14, theme.colors.ink);
            if (ui.clickedIn(row)) picked = i;
            y += row_height;
        }
        source.scroll.end(ui, box, y + 4);
        return picked;
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

/// de onde se olha a Montagem: o 3D livre (arrastar gira) ou uma vista em escala, sem perspectiva, para ler o CG
const ViewAngle = enum {
    free,
    side, // de lado (do −y): x e z
    top, // de cima: x e y
    front, // de frente: y e z

    fn caption(angle: ViewAngle) [:0]const u8 {
        return switch (angle) {
            .free => "3D",
            .side => "Lateral",
            .top => "Superior",
            .front => "Frontal",
        };
    }

    /// põe a câmera na direção da vista (azimute e elevação de `View.begin`)
    fn aim(angle: ViewAngle, view: *view3d.View) void {
        if (angle == .free) {
            if (view.orthographic) {
                view.orthographic = false;
                view.azimuth = -130;
                view.elevation = 22;
            }
            return;
        }
        view.orthographic = true;
        const direction: [2]f32 = switch (angle) {
            .side => .{ 90, 0 },
            .top => .{ 180, 89.9 }, // quase a pino: a câmera de cima com o nariz para cima na tela
            .front => .{ 0, 0 },
            .free => unreachable,
        };
        view.azimuth = direction[0];
        view.elevation = direction[1];
    }
};

/// a peça sendo arrastada no 3D: onde o mouse apertou, a que distância do olho ela está e quanto já andou (m)
const PieceDrag = struct {
    component: u16,
    start: rl.Vector2,
    depth: f64,
    offset: [3]f64 = .{ 0, 0, 0 },
};

/// a seta do vento (azul, como na Montagem em Python): acima do avião, apontando para onde o vento sopra; o ângulo é
/// de onde ele vem, 0 = de frente (+x), 90 = da direita (+y)
fn drawWind(view: *view3d.View, environment: aircraft_model.aircraft.Environment, center: [3]f64, top: f64, size: f64) void {
    if (!(environment.wind_speed > 0)) return;
    const color = theme.hex(0x1f77b4);
    const from = std.math.degreesToRadians(environment.wind_from);
    const toward = [2]f64{ -@cos(from), -@sin(from) }; // para onde sopra
    const length = 0.35 * size;
    const height = top - 0.15 * size;
    const tip: [3]f64 = .{ center[0] + 0.5 * length * toward[0], center[1] + 0.5 * length * toward[1], height };
    const tail: [3]f64 = .{ tip[0] - length * toward[0], tip[1] - length * toward[1], height };
    view3d.segment(tail, tip, color);
    const head = 0.08 * size;
    for ([2]f64{ 1, -1 }) |side| {
        const back: [3]f64 = .{ tip[0] - head * toward[0] - side * 0.5 * head * toward[1], tip[1] - head * toward[1] + side * 0.5 * head * toward[0], height };
        view3d.segment(tip, back, color);
    }
    view.label(tail, widgets.format(&wind_label, "vento {d:.1} m/s", .{environment.wind_speed}), color);
}

var wind_label: [40]u8 = undefined;

/// o símbolo do centro de gravidade: um círculo em quatro quartos, pretos e brancos alternados, com a borda vermelha
fn drawCgSymbol(center: rl.Vector2, radius: f32) void {
    rl.drawCircleV(center, radius + 2, theme.hex(0xd62728));
    for (0..4) |quarter| {
        const start: f32 = 90 * @as(f32, @floatFromInt(quarter));
        rl.drawCircleSector(center, radius, start, start + 90, 16, if (quarter % 2 == 0) rl.Color.black else rl.Color.white);
    }
}

/// as cotas do CG numa vista em escala: da referência (0, 0, 0) até o CG pelos dois eixos que a vista mostra
fn drawCgDimensions(view: *view3d.View, angle: ViewAngle, cg: [3]f64, size: f64) void {
    const color = theme.hex(0xd62728);
    const origin: [3]f64 = .{ 0, 0, 0 };
    const axes: [2]usize = switch (angle) {
        .side => .{ 0, 2 },
        .top => .{ 0, 1 },
        .front => .{ 1, 2 },
        .free => return,
    };
    var corner = origin;
    corner[axes[0]] = cg[axes[0]];
    view3d.segment(origin, corner, color);
    view3d.segment(corner, cg, color);
    cross(origin, 0.03 * size, theme.colors.muted);
    _ = view;
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

/// o resumo da Montagem pronto para desenhar: o texto do painel em células da tabela, numa arena só dele
const AssemblyPanel = struct {
    arena: std.heap.ArenaAllocator,
    name: [:0]const u8,
    summary: []const u8,
    titles: []const [:0]const u8,
    tables: []const []const []const ui_kit.plot.Cell,
    warnings: []const []const u8,

    fn build(aircraft: *const aircraft_model.aircraft.Aircraft) !AssemblyPanel {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const panel = try config_tab.panel(memory, aircraft);
        const titles = try memory.alloc([:0]const u8, panel.sections.len);
        const tables = try memory.alloc([]const []const ui_kit.plot.Cell, panel.sections.len);
        for (panel.sections, titles, tables) |section, *title, *table| {
            title.* = try memory.dupeZ(u8, section.title);
            const rows = try memory.alloc([]const ui_kit.plot.Cell, section.rows.len);
            for (section.rows, rows) |row, *cells| {
                const pair = try memory.alloc(ui_kit.plot.Cell, 2);
                pair[0] = .{ .text = try memory.dupeZ(u8, row.item) };
                pair[1] = .{ .text = try memory.dupeZ(u8, row.value), .color = if (row.warning) theme.hex(0xbb0000) else null };
                cells.* = pair;
            }
            table.* = rows;
        }
        return .{ .arena = arena, .name = try memory.dupeZ(u8, panel.name), .summary = panel.summary, .titles = titles, .tables = tables, .warnings = panel.warnings };
    }

    fn deinit(shown: *AssemblyPanel) void {
        shown.arena.deinit();
    }

    /// os blocos um embaixo do outro, com a rolagem
    fn draw(shown: *const AssemblyPanel, ui: *widgets.Ui, area: *ui_kit.scroll.ScrollArea, rect: rl.Rectangle) void {
        var y = area.begin(ui, rect);
        const width = rect.width - 14;
        theme.text(ui.fonts.bold, shown.name, rect.x + 4, y + 4, 18, theme.colors.ink);
        y += 30;
        y += widgets.paragraph(ui.fonts.regular, shown.summary, rect.x + 4, y, width - 8, 14, theme.colors.label) + 10;
        for (shown.titles, shown.tables) |title, rows| {
            const height = ui_kit.plot.tableHeight(rows.len);
            ui_kit.plot.table(ui, .{ .x = rect.x, .y = y, .width = width, .height = height }, title, &.{ "item", "valor" }, rows, &.{ 0.52, 0.48 });
            y += height + 10;
        }
        if (shown.warnings.len > 0) {
            theme.text(ui.fonts.bold, "Avisos", rect.x + 4, y, 16, theme.hex(0xbb0000));
            y += 24;
            for (shown.warnings) |warning| y += widgets.paragraph(ui.fonts.regular, warning, rect.x + 12, y, width - 16, 14, theme.hex(0xbb0000)) + 4;
        }
        area.end(ui, rect, y + 10);
    }
};

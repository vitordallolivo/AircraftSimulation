//! A tela do aerosim: o cabeçalho, as abas das áreas e as subabas de cada uma, na mesma arrumação da antiga GUI PyQt.
//! As abas vêm de `manager.layout` (`aerosim/manager/manager.zig`): cada subaba é uma
//! `Page` (`page.zig`), uma análise do Simulation Manager ou uma etapa da sprint. A Montagem é daqui mesmo: o avião aberto em 3D (`assembly.zig`), com o CG.
const std = @import("std");
const rl = @import("raylib");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const view3d = ui_kit.view3d;
const templates = @import("templates");
const jobs = ui_kit.jobs;
const page_mod = @import("page.zig");
const python_bridge = @import("python_bridge.zig");
const data_sources = @import("data_sources");
const assembly_mod = @import("assembly.zig");
const config_tab = @import("tabs/config_tab.zig");
const aircraft_model = @import("aircraft_model");
const manager = @import("manager");
const design = @import("design");
const sheet_window = @import("sheet_window.zig");
const zon_json = @import("aerosim").zon_json;

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

const waiting_labels = [_][:0]const u8{"Montagem"};

pub const Screen = struct {
    area: usize = 0,
    scroll: f32 = 0, // rolagem inicial (prints), passada à página aberta
    io: ?std.Io = null, // a `Io` do processo (o programa a passa em `ui/app.zig`): a ponte abre o Python com ela
    bridge: python_bridge.Bridge = .{},
    layout_memory: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator), // as áreas e os títulos
    areas: []Area = &.{},
    area_labels: []const [:0]const u8 = &waiting_labels,
    shown: ?*Page = null, // a página do último quadro (trocar de página pede ela de novo)
    requirements: Page = .{ .kind = .stage, .name = "requisitos", .title = "Condições e restrições", .grids_beside = true },
    requirements_open: bool = false,
    sheet_window: sheet_window.SheetWindow = .{}, // a janela "Planilha…" da área aberta
    // o jeito celular (janela estreita, `ui/phone.zig`): as fichas das subabas e a lista do "Mais" da barra de baixo
    area_chips: ui_kit.phone.Chips = .{},
    more_open: bool = false,
    pending_tab: ?usize = null, // aba=N da linha de comando, até as abas chegarem
    pending_run: bool = false, // acao=rodar, idem
    pending_stage: [512]u8 = undefined, // acao=etapa:<botão>: aperta o botão da etapa quando ela abrir
    pending_stage_len: usize = 0,
    pending_file: [1024]u8 = undefined, // um perfil arrastado antes de as abas chegarem
    pending_file_len: usize = 0,
    cellmap_workbook: [1024]u8 = undefined, // a planilha por endereço de célula que espera o arquivo de mapa
    cellmap_workbook_len: usize = 0,
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
    // a Montagem no celular: a folha embaixo do 3D e as fichas dela (Peças, Peça escolhida, Resumo)
    assembly_sheet: ui_kit.phone.Sheet = .{},
    assembly_tabs: ui_kit.phone.Chips = .{},
    assembly_tab: usize = 0,
    assembly_drag: ?PieceDrag = null, // a peça sendo arrastada no 3D
    drag_lock: DragLock = .screen, // por onde a peça arrastada anda: no plano da tela ou só num eixo
    restore_open: bool = false, // o menu do "Restaurar" aberto: como foi aberto ou um modelo padrão
    assembly_angle: ViewAngle = .free, // a vista da Montagem: 3D livre ou lateral, superior e frontal em escala
    assembly_editor: ?AssemblyEditor = null, // a lista de componentes e o editor da peça escolhida
    pending_assembly: [256]u8 = undefined, // acao=montagem:...: botões ("+ EH"), "peca=N", "editar=campo=valor", "trazer=arquivo#N" ou "vista=Lateral", até o avião abrir
    pending_assembly_len: usize = 0,
    pending_undo: usize = 0, // acao=desfazer: Ctrl+Z pelos prints, quando a tela estiver pronta
    undoing: bool = false, // o Ctrl+Z está refazendo o avião (essa mudança não vai para o histórico)
    importing_file: bool = false, // a janela de arquivos aberta é a de trazer uma peça de outro avião
    pending_export: bool = false, // "Exportar…" pedido: a prévia abre quando o avião estiver aberto
    loader: ui_kit.jobs.Job = .{}, // lê o .json fora do laço da tela
    loading: Loading = .{},
    message: [240:0]u8 = [_:0]u8{0} ** 240,
    // abrir pelo usuário (Abrir…, arrastar, outro projeto): o avião que chega fecha os outros abertos e apaga os
    // resultados de antes; a remontagem do projeto pelas etapas não
    fresh_open: bool = false,
    // o que está aberto, na linha de cima: o avião (e a variante) e o projeto
    in_use: [256:0]u8 = [_:0]u8{0} ** 256, // o projeto, ao lado do nome
    in_use_name: [160:0]u8 = [_:0]u8{0} ** 160, // o nome do avião (e da variante), em destaque
    // a primeira edição de um avião montado vira uma variante: a janela pede o nome dela
    variant_prompt: ui_kit.dialogs.TextPrompt = .{},
    variant_base: usize = 0, // o avião de onde a variante saiu (Cancelar volta para ele)
    variant_list: ui_kit.menus.ItemList = .{}, // a lista "Variantes" da Montagem
    keep_base: bool = false, // edições que não fazem variante (Salvar grava o refino no arquivo)

    /// abre a subaba de número `index`, contando todas em ordem (a Montagem é a última), para os prints
    pub fn selectTab(screen: *Screen, index: usize) void {
        screen.pending_tab = index;
    }

    /// a tela ainda vai mudar sozinha (aba ou "rodar" pendente, uma conta andando): o print espera
    pub fn busy(screen: *const Screen) bool {
        if (screen.pending_export) return true;
        if (screen.pending_tab != null or screen.pending_run or screen.pending_stage_len > 0 or screen.pending_assembly_len > 0 or screen.pending_undo > 0) return true;
        const page = screen.shown orelse return false;
        return page.settling();
    }

    /// prepara a tela (chamar com a janela aberta). Abre vazia: nenhum avião e um projeto novo, sem nada guardado;
    /// "Abrir" traz um avião ou um projeto da sprint
    pub fn start(screen: *Screen) void {
        screen.requirements.bridge = &screen.bridge;
        design.stages.connect(io());
        // o avião do projeto (o último aberto), se ele já tiver um: a Montagem e as análises começam com ele
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (design.stages.projectAircraft(io(), arena.allocator())) |path| screen.openAircraft(path);
    }

    /// um comando pelo nome (`acao=` da linha de comando, para os prints): "abrir", "salvar", "rodar" (roda a análise
    /// aberta assim que os campos chegam)
    pub fn command(screen: *Screen, name: []const u8) void {
        if (std.mem.eql(u8, name, "novo")) {
            screen.newAircraft();
        } else if (std.mem.eql(u8, name, "abrir")) {
            var buffer: [256]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&buffer);
            const folder = if (screen.assembly) |*opened| std.fs.path.dirname(opened.path) orelse "." else exampleFolder(fixed.allocator());
            screen.files.show("Abrir avião (.aero, .json, .cfg ou .xlsx)", folder, &data_sources.aircraft_extensions);
        } else if (std.mem.eql(u8, name, "salvar")) {
            const opened = &(screen.assembly orelse {
                _ = std.fmt.bufPrintZ(&screen.assembly_note, "nenhum avião aberto para salvar", .{}) catch {};
                return;
            });
            // o avião aberto de um .cfg ou .xlsx antigo é salvo em .json, com o mesmo nome
            var name_buffer: [256]u8 = undefined;
            const base = std.fs.path.basename(opened.path);
            const aero_name = if (data_sources.Format.fromPath(base) == .aero) base else std.fmt.bufPrint(&name_buffer, "{s}.aero", .{std.fs.path.stem(base)}) catch base;
            screen.files.showSave("Salvar avião (.aero)", std.fs.path.dirname(opened.path) orelse ".", &.{".aero"}, aero_name);
        } else if (std.mem.eql(u8, name, "rodar")) {
            screen.pending_run = true;
        } else if (std.mem.startsWith(u8, name, "etapa:") or std.mem.startsWith(u8, name, "campo:")) {
            screen.pending_stage_len = @min(name.len, screen.pending_stage.len);
            @memcpy(screen.pending_stage[0..screen.pending_stage_len], name[0..screen.pending_stage_len]);
        } else if (std.mem.startsWith(u8, name, "montagem:")) { // um botão da Montagem pelo nome, para os prints
            const length = @min(name.len - 9, screen.pending_assembly.len - screen.pending_assembly_len);
            @memcpy(screen.pending_assembly[screen.pending_assembly_len..][0..length], name[9..][0..length]);
            screen.pending_assembly_len += length;
            if (screen.pending_assembly_len < screen.pending_assembly.len) {
                screen.pending_assembly[screen.pending_assembly_len] = ';';
                screen.pending_assembly_len += 1;
            }
        } else if (std.mem.startsWith(u8, name, "planilha:")) { // a janela da planilha da área aberta (prints)
            screen.openSheetWindow();
            screen.sheet_window.openPath(name["planilha:".len..]);
        } else if (std.mem.startsWith(u8, name, "bloco:")) { // marca o bloco da planilha aberta (prints)
            design.sheets.setRange(name["bloco:".len..]);
        } else if (std.mem.startsWith(u8, name, "salvar_em:")) { // salva o avião aberto no caminho (prints)
            screen.save(name["salvar_em:".len..]);
        } else if (std.mem.eql(u8, name, "exportar")) { // "Exportar…": a prévia da planilha de desempenho, e dela se grava
            screen.pending_export = true;
        } else if (std.mem.startsWith(u8, name, "exportar_em:")) { // a prévia, gravada no caminho assim que montar (prints)
            screen.pending_export = true;
            sheet_window.saveWhenReady(name["exportar_em:".len..]);
        } else if (std.mem.eql(u8, name, "fechar_planilha")) {
            screen.sheet_window.open = false;
        } else if (std.mem.eql(u8, name, "usar_polinomio")) { // "Usar no motor do avião" (prints)
            screen.usePolynomial();
        } else if (std.mem.startsWith(u8, name, "tipo:")) { // a aba do tipo do bloco, pelo nome interno (prints)
            if (std.meta.stringToEnum(design.sheets.Kind, name["tipo:".len..])) |kind| design.sheets.setKind(kind);
        } else if (std.mem.startsWith(u8, name, "dados_excel:")) { // "Exportar → Dados em Excel" do gráfico com esse título (prints)
            ui_kit.plot.requestExport(name["dados_excel:".len..], .xlsx);
        } else if (std.mem.startsWith(u8, name, "salvar_dados:")) { // grava a prévia dos dados no caminho (prints)
            sheet_window.saveWhenReady(name["salvar_dados:".len..]);
        } else if (std.mem.startsWith(u8, name, "desmarcar:")) { // tira o conjunto N (de 0) da prévia da exportação (prints)
            const index = std.fmt.parseInt(usize, name["desmarcar:".len..], 10) catch 0;
            if (index < sheet_window.max_choices) sheet_window.pending_unchecked[index] = true;
        } else if (std.mem.startsWith(u8, name, "aba_previa:")) { // a aba mostrada na prévia da exportação, de 0 (prints)
            sheet_window.preview.export_data.sheet = std.fmt.parseInt(usize, name["aba_previa:".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, name, "rolar:")) { // a primeira linha e coluna à vista na planilha: rolar:linha.coluna (prints)
            var parts = std.mem.splitScalar(u8, name["rolar:".len..], '.');
            const row = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
            screen.sheet_window.pending_scroll = .{ .row = row, .column = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1 };
        } else if (std.mem.startsWith(u8, name, "folha:")) { // a aba da planilha, de 0 (prints)
            design.sheets.selectSheet(std.fmt.parseInt(usize, name["folha:".len..], 10) catch 0);
        } else if (std.mem.eql(u8, name, "condicoes")) {
            screen.requirements_open = true;
        } else if (std.mem.startsWith(u8, name, "projeto:")) { // abre um projeto da sprint (prints)
            screen.openProject(name[8..]);
        } else if (std.mem.eql(u8, name, "desfazer")) {
            screen.pending_undo += 1;
        }
    }

    /// "Usar no motor do avião": o polinômio marcado na planilha vai para todos os motores do avião aberto
    fn usePolynomial(screen: *Screen) void {
        const window = &screen.sheet_window;
        const opened = &(screen.assembly orelse return window.say("abra um avião antes (ou rode Motores e montagem): o polinômio vai para os motores dele", .{}));
        const polynomial = design.sheets.markedPolynomial() catch return window.say("o polinômio marcado não vale: marque os coeficientes e as células de T0 e da rotação", .{});
        const memory = opened.document_arena.allocator();
        const name = design.sheets.comboName();
        const source = design.sheets.markedSource(memory) catch "";
        const count = design.sheets.putPolynomial(memory, &opened.document, polynomial, if (name.len > 0) name else "da planilha", source) catch 0;
        if (count == 0) return window.say("o avião aberto não tem motor para receber o polinômio", .{});
        screen.commitDocument(null);
        window.say("o polinômio vai para {d} motor{s} de {s} (modelo de tração: polinômio). Salve o avião para guardar", .{ count, if (count == 1) "" else "es", opened.loaded.ac.name });
    }

    /// "Exportar…" da área aberta: simula, monta a planilha no formato da equipe (Desempenho, Aerodinâmica) e mostra
    /// a prévia (a mesma do "Exportar" dos gráficos); é nela que se escolhe onde gravar
    fn previewSheets(screen: *Screen) void {
        const area = if (screen.areas.len > 0) screen.areas[screen.area].title else "Desempenho";
        if (std.mem.eql(u8, area, "Aerodinâmica")) return screen.previewAerodynamics();
        if (std.mem.eql(u8, area, "Estabilidade")) return screen.previewStability();
        var note: [512]u8 = undefined;
        const opened = &(screen.assembly orelse return ui_kit.toast.show("abra um avião antes de exportar"));
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const sheet = manager.performance_sheet;
        const bytes = sheet.workbook(arena.allocator(), &opened.loaded.ac, &sheet.default_altitudes) catch |err| {
            return ui_kit.toast.show(std.fmt.bufPrint(&note, "não exportou: {s}", .{@errorName(err)}) catch "não exportou");
        };
        var name_buffer: [256]u8 = undefined;
        const file_name = std.fmt.bufPrint(&name_buffer, "{s}_desempenho.xlsx", .{std.fs.path.stem(opened.path)}) catch "desempenho.xlsx";
        sheet_window.previewWorkbook("Desempenho", file_name, bytes);
    }

    /// a planilha de aerodinâmica (um bloco por asa) na prévia, com a lista das superfícies para escolher
    fn previewAerodynamics(screen: *Screen) void {
        const opened = &(screen.assembly orelse return ui_kit.toast.show("abra um avião antes de exportar"));
        var name_buffer: [256]u8 = undefined;
        const file_name = std.fmt.bufPrint(&name_buffer, "{s}_aerodinamica.xlsx", .{std.fs.path.stem(opened.path)}) catch "aerodinamica.xlsx";
        sheet_export.start(&opened.loaded.ac, .aerodynamics);
        sheet_window.previewWorkbookWithChoices("Aerodinâmica", file_name, sheet_export.labels(), sheet_export.rebuild);
    }

    /// a prévia da planilha de estabilidade e controle (no formato da Outputs), com a lista das superfícies
    fn previewStability(screen: *Screen) void {
        const opened = &(screen.assembly orelse return ui_kit.toast.show("abra um avião antes de exportar"));
        var name_buffer: [256]u8 = undefined;
        const file_name = std.fmt.bufPrint(&name_buffer, "{s}_estabilidade.xlsx", .{std.fs.path.stem(opened.path)}) catch "estabilidade.xlsx";
        sheet_export.start(&opened.loaded.ac, .stability);
        sheet_window.previewWorkbookWithChoices("Estabilidade", file_name, sheet_export.labels(), sheet_export.rebuild);
    }

    /// a janela "Planilha…" para a área aberta
    fn openSheetWindow(screen: *Screen) void {
        const title = if (screen.areas.len > 0) screen.areas[screen.area].title else "";
        screen.sheet_window.show(title);
    }

    /// abre o projeto da sprint em `path` no lugar do aberto; as etapas pedem a página de novo
    fn openProject(screen: *Screen, path: []const u8) void {
        design.stages.openProject(io(), path) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.message, "não abriu o projeto '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) }) catch {};
            return;
        };
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| if (page.kind == .stage) page.markStale();
        screen.requirements.markStale();
        screen.clearResults();
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "projeto aberto: {s}", .{path}) catch {};
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (design.stages.projectAircraft(io(), arena.allocator())) |aircraft_path| {
            // o avião que o projeto montou: abre sem trocar o projeto
            screen.fresh_open = true;
            screen.openAircraft(aircraft_path);
        }
        screen.noteInUse();
    }

    /// Ctrl+Z: desfaz a última mudança do que está na tela (a janela das condições, a página aberta ou a Montagem)
    fn undo(screen: *Screen) void {
        if (screen.files.open) return;
        if (screen.requirements_open) return screen.requirements.undo();
        const page: ?*Page = if (screen.areas.len > 0) screen.areas[screen.area].pages[screen.areas[screen.area].active] else null;
        if (page) |p| return p.undo();
        screen.undoAssembly();
    }

    /// desfaz a última mudança no avião da Montagem (mover, editar, acrescentar, remover, vento, restaurar)
    fn undoAssembly(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        const previous = opened.history.pop() orelse {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "nada para desfazer", .{}) catch {};
            return;
        };
        defer opened.history.release(previous);
        opened.document = std.json.parseFromSliceLeaky(std.json.Value, opened.document_arena.allocator(), previous, .{ .allocate = .alloc_always }) catch return;
        screen.undoing = true;
        defer screen.undoing = false;
        screen.commitDocument(null);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "desfeito (Ctrl+Z) · {d} passo{s} para trás ainda", .{ opened.history.count, if (opened.history.count == 1) "" else "s" }) catch {};
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
        // o avião de antes vai para o Ctrl+Z (sai de novo se a edição não vale ou não mudou nada)
        const remembered = !screen.undoing;
        if (remembered) opened.history.push(opened.source);
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
        if (remembered) if (opened.history.count > 0 and std.mem.eql(u8, opened.history.steps[opened.history.count - 1], opened.source)) {
            opened.history.release(opened.history.pop().?); // nada mudou (ou não valeu): não é um passo
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
        // as análises rodam o avião editado, mesmo antes de salvar
        screen.shareAircraft();
        // a primeira mudança no avião montado não mexe nele: vira uma variante, e a janela pede o nome dela
        if (remembered and !opened.variant and !screen.keep_base and opened.history.count > 0) screen.branchVariant();
    }

    /// a mudança que acabou de entrar no avião montado vai para uma variante nova: o avião volta a ser como era, a
    /// cópia com a mudança passa a ser o avião atual, e a janela pede o nome dela (Cancelar desfaz a variante)
    fn branchVariant(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        if (screen.fleet_count >= max_fleet) return; // sem lugar: a mudança fica no próprio avião, como antes
        var diagnosis: assembly_mod.Diagnosis = .{};
        var copy = assembly_mod.fromBytes(std.heap.page_allocator, io(), opened.path, opened.source, &diagnosis) catch return;
        copy.variant = true;
        // o avião de onde saiu volta ao texto de antes da mudança (o passo sai do Ctrl+Z dele)
        const before = opened.history.pop() orelse {
            copy.deinit();
            return;
        };
        defer opened.history.release(before);
        opened.reload(std.heap.page_allocator, io(), before, &diagnosis) catch {};
        if (std.json.parseFromSliceLeaky(std.json.Value, opened.document_arena.allocator(), opened.source, .{})) |previous| {
            opened.document = previous;
        } else |_| {}
        screen.variant_base = screen.fleet_current;
        screen.fleet[screen.fleet_current] = screen.assembly;
        screen.assembly = copy;
        screen.fleet_current = screen.fleet_count;
        screen.fleet_count += 1;
        screen.showSwitched();
        var name_buffer: [64]u8 = undefined;
        const suggestion = std.fmt.bufPrint(&name_buffer, "variante {d}", .{screen.fleet_count - 1}) catch "variante";
        screen.variant_prompt.show("Nova variante", "o avião montado fica como está; nome desta variante:", suggestion);
    }

    /// o nome que a janela deu à variante nova: o avião passa a se chamar "<avião> — <nome>"
    fn nameVariant(screen: *Screen, typed: []const u8) void {
        const opened = &(screen.assembly orelse return);
        if (!opened.variant) return;
        const base_name = if (screen.fleet[screen.variant_base]) |*base| base.loaded.ac.name else opened.loaded.ac.name;
        const trimmed = std.mem.trim(u8, typed, " ");
        var name_buffer: [160]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s} — {s}", .{ base_name, if (trimmed.len > 0) trimmed else "variante" }) catch base_name;
        config_tab.rename(opened.document_arena.allocator(), &opened.document, name) catch {};
        screen.commitDocument(null);
        // o nome não é um passo do Ctrl+Z da variante
        if (opened.history.pop()) |step| opened.history.release(step);
        screen.fleetNote("variante nova");
    }

    /// Cancelar na janela da variante: a variante fecha e volta o avião de onde ela saiu, sem a mudança
    fn dropVariant(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        if (!opened.variant or screen.fleet_count <= 1) return;
        const base = screen.variant_base;
        screen.closeAircraft();
        screen.selectAircraft(@min(base, screen.fleet_count - 1));
        screen.fleetNote("variante desfeita");
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
                // a trava ("só x", "só y", "só z"): fica só a parte do movimento ao longo do eixo
                if (screen.drag_lock.axis()) |kept| {
                    for (&drag.offset, 0..) |*moved, k| if (k != kept) {
                        moved.* = 0;
                    };
                }
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
        // a faixa de baixo (a trava do arraste e a nota) e o menu do "Restaurar" aberto não pegam peça
        if (screen.restore_open or ui.mouse.y > area.y + area.height - 62) return;
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

    /// "Restaurar → modelo padrão": o avião vira o modelo `index` de `templates.all` (as edições se perdem, como no
    /// Python); "Salvar" grava o modelo no arquivo aberto
    fn restoreTemplate(screen: *Screen, index: usize) void {
        const opened = &(screen.assembly orelse return);
        if (index >= templates.all.len) return;
        const chosen = templates.all[index];
        opened.document = std.json.parseFromSliceLeaky(std.json.Value, opened.document_arena.allocator(), chosen.json, .{}) catch return;
        screen.showSwitched();
        screen.commitDocument(null);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "modelo padrão: {s} (Salvar grava)", .{chosen.name}) catch {};
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
        screen.importing_file = true; // Trazer de outro avião
        screen.files.show("Trazer uma peça de outro avião", std.fs.path.dirname(opened.path) orelse ".", &data_sources.aircraft_extensions);
    }

    /// os comandos da Montagem pedidos na linha de comando, agora que o avião abriu
    fn runPendingAssembly(screen: *Screen) void {
        var pending: [256]u8 = undefined;
        const length = screen.pending_assembly_len;
        @memcpy(pending[0..length], screen.pending_assembly[0..length]);
        screen.pending_assembly_len = 0;
        var steps = std.mem.tokenizeScalar(u8, pending[0..length], ';');
        while (steps.next()) |step| {
            if (std.mem.startsWith(u8, step, "variante=")) { // responde a janela do nome da variante
                screen.variant_prompt.open = false;
                screen.nameVariant(step["variante=".len..]);
            } else if (std.mem.startsWith(u8, step, "salvar=")) { // salva o avião aberto (com as variantes) no caminho
                screen.save(step["salvar=".len..]);
            } else if (std.mem.startsWith(u8, step, "ver=")) { // mostra o avião `N` da lista das variantes (de 0)
                screen.selectAircraft(std.fmt.parseInt(usize, step["ver=".len..], 10) catch continue);
            } else if (std.mem.startsWith(u8, step, "vista=")) {
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
            } else if (std.mem.startsWith(u8, step, "modelo=")) { // Restaurar → modelo padrão N
                screen.restoreTemplate(std.fmt.parseInt(usize, step[7..], 10) catch continue);
            } else if (std.mem.startsWith(u8, step, "arraste=")) {
                for (std.enums.values(DragLock)) |lock| if (std.mem.eql(u8, lock.caption(), step[8..])) {
                    screen.drag_lock = lock;
                };
            } else if (std.mem.eql(u8, step, "menu restaurar")) {
                screen.restore_open = true;
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
        // o "Refino dos Solvers" das análises vai junto no arquivo do avião
        if (opened.document == .object) {
            const node = if (opened.document.object.getPtr("aeronave")) |inner| (if (inner.* == .object) &inner.object else &opened.document.object) else &opened.document.object;
            page_mod.shared.numericsInto(opened.document_arena.allocator(), node) catch {};
            screen.keep_base = true;
            defer screen.keep_base = false;
            screen.commitDocument(null);
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        const variants = screen.variantParts(memory) catch &.{};
        const data = aeroBytes(memory, path, opened.path, screen.baseSource() orelse opened.source, design.stages.projectPart(memory), variants) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não salvou '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) }) catch {};
            return;
        };
        std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = data }) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não salvou '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) }) catch {};
            return;
        };
        ui_kit.system.offerDownload(path);
        // o arquivo salvo é o aberto daqui em diante: o projeto passa a gravar nele, e ele volta na próxima vez
        if (data_sources.Format.fromPath(path) == .aero) {
            design.stages.adoptDocument(io(), path);
            opened.path = opened.document_arena.allocator().dupe(u8, path) catch opened.path;
            for (screen.fleet[0..screen.fleet_count]) |*slot| if (slot.*) |*other| {
                other.path = other.document_arena.allocator().dupe(u8, path) catch other.path;
            };
            screen.shareAircraft();
        }
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "salvo em {s}", .{path}) catch {};
    }

    /// os bytes a gravar em `path`: o `.aero` com a data de agora e a de criação do arquivo que já estava lá (ou do
    /// aberto, `source_path`); outra extensão grava o texto JSON como está
    fn aeroBytes(memory: std.mem.Allocator, path: []const u8, source_path: []const u8, json: []const u8, project: ?aircraft_model.aero_file.Part, variants: []const aircraft_model.aero_file.Part) ![]const u8 {
        const aero_file = aircraft_model.aero_file;
        if (data_sources.Format.fromPath(path) != .aero) return json;
        var created: []const u8 = "";
        // as outras partes do arquivo de origem vão junto; o projeto é o de agora (ou nenhum)
        var parts: std.ArrayList(aero_file.Part) = .empty;
        for ([_][]const u8{ path, source_path }, 0..) |candidate, k| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io(), candidate, memory, .limited(assembly_mod.max_file_bytes)) catch continue;
            if (created.len == 0) created = aero_file.createdOf(memory, bytes);
            if (k == 1 and aero_file.looksLike(bytes)) {
                var diagnosis: aircraft_model.aircraft.Diag = .{};
                if (aero_file.readDocument(memory, bytes, &diagnosis)) |document| {
                    for (document.parts) |item| if (!std.mem.eql(u8, item.name, aero_file.project_part) and !std.mem.startsWith(u8, item.name, variant_prefix)) try parts.append(memory, item);
                } else |_| {}
            }
        }
        if (project) |part| try parts.append(memory, part);
        try parts.appendSlice(memory, variants);
        return aero_file.writeDocument(memory, json, .{ .program = "aerosim", .now = try aero_file.isoNow(memory, io()), .created = created }, parts.items);
    }

    /// abre o arquivo `path`: um `.aero` é o avião (Montagem); um `.json` é o avião antigo ou um projeto da sprint; um `.dat` ou uma polar vão
    /// para a etapa Perfis
    pub fn openFile(screen: *Screen, path: []const u8) void {
        const format = data_sources.Format.fromPath(path);
        // a janela "Planilha…" aberta: a planilha escolhida (no aparelho ou arrastada) vai para ela
        if (format == .xlsx and screen.sheet_window.open) return screen.sheet_window.openPath(path);
        if (format == .xlsx) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, arena.allocator(), .limited(assembly_mod.max_file_bytes)) catch return screen.openAircraftFresh(path);
            if (data_sources.isProgramWorkbook(arena.allocator(), bytes)) return screen.openAircraftFresh(path);
            // uma planilha das equipes (por endereço de célula): pede o mapa que diz de qual célula sai cada campo
            screen.cellmap_workbook_len = @min(path.len, screen.cellmap_workbook.len);
            @memcpy(screen.cellmap_workbook[0..screen.cellmap_workbook_len], path[0..screen.cellmap_workbook_len]);
            screen.files.show("Mapa de células desta planilha (.json)", "data/mappings", &.{".json"});
            return;
        }
        if (format == .ini or format == .aero) return screen.openAircraftFresh(path);
        if (format == .json) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, std.heap.page_allocator, .limited(assembly_mod.max_file_bytes)) catch return screen.openAircraftFresh(path);
            defer std.heap.page_allocator.free(bytes);
            if (screen.cellmap_workbook_len > 0 and data_sources.cellmap.isMap(bytes)) return screen.importCellMap(bytes);
            if (design.stages.isProject(bytes)) return screen.openProject(path);
            return screen.openAircraftFresh(path);
        }
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
    /// lê a planilha que esperava o mapa (`map_bytes`), partindo do avião aberto (ou do modelo do mapa, sem avião),
    /// grava o avião em `<pasta dos projetos>/importados/<planilha>.json` e o abre
    fn importCellMap(screen: *Screen, map_bytes: []const u8) void {
        const workbook_path = screen.cellmap_workbook[0..screen.cellmap_workbook_len];
        screen.cellmap_workbook_len = 0;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        const fail = struct {
            fn note(target: *Screen, comptime format: []const u8, args: anytype) void {
                _ = std.fmt.bufPrintZ(&target.assembly_note, format, args) catch {};
            }
        }.note;
        const workbook = std.Io.Dir.cwd().readFileAlloc(io(), workbook_path, memory, .limited(assembly_mod.max_file_bytes)) catch return fail(screen, "não consegui ler a planilha", .{});
        const base = if (screen.assembly) |*opened| opened.source else data_sources.cellmap.baseTemplate(map_bytes) orelse templates.all[0].json;
        const result = data_sources.cellmap.read(memory, map_bytes, workbook, base) catch |err| return fail(screen, "o mapa não leu a planilha ({s})", .{@errorName(err)});
        const folder = std.fs.path.join(memory, &.{ design.stages.projectsRoot(memory) catch return, "importados" }) catch return;
        std.Io.Dir.cwd().createDirPath(io(), folder) catch return fail(screen, "não consegui criar {s}", .{folder});
        const target = std.fmt.allocPrint(memory, "{s}/{s}.aero", .{ folder, std.fs.path.stem(workbook_path) }) catch return;
        const aero = aeroBytes(memory, target, workbook_path, result.json, null, &.{}) catch return fail(screen, "não consegui montar {s}", .{target});
        std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = target, .data = aero }) catch return fail(screen, "não consegui gravar {s}", .{target});
        screen.openAircraftFresh(target);
        if (result.warnings.len > 0) fail(screen, "planilha lida com {d} avisos; o primeiro: {s}", .{ result.warnings.len, result.warnings[0] });
    }

    /// abre o avião em `path` pedido pelo usuário (Abrir…, arrastar, outro projeto): ele fecha os outros aviões
    /// abertos e apaga os resultados de antes
    fn openAircraftFresh(screen: *Screen, path: []const u8) void {
        // uma coisa aberta por vez: o `.aero` traz o projeto dele (ou nenhum), e o projeto de antes fecha
        if (data_sources.Format.fromPath(path) == .aero) {
            design.stages.openDocument(io(), path) catch {};
        } else {
            design.stages.closeProject(io()) catch {};
        }
        screen.markStagesStale();
        screen.fresh_open = true;
        screen.openAircraft(path);
    }

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
            screen.fresh_open = false;
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "não abriu '{s}': {s}", .{ std.fs.path.basename(path), screen.loading.reasonText() }) catch {};
            return;
        };
        screen.loading.result = null;
        screen.adoptAircraft(loaded);
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "{s} · {d} peças · arraste outro avião para a janela para trocar · arraste para girar, roda para aproximar", .{ std.fs.path.basename(path), loaded.mesh.piece_count }) catch {};
    }

    /// troca o avião atual por `loaded`; aberto pelo usuário (`fresh_open`), fecha os outros e apaga os resultados
    fn adoptAircraft(screen: *Screen, loaded: assembly_mod.Assembly) void {
        screen.variant_prompt.open = false;
        // o projeto remontou o avião enquanto se olha uma variante: troca só o avião montado, e a variante fica
        if (!screen.fresh_open) if (screen.assembly) |*current| if (current.variant) {
            for (screen.fleet[0..screen.fleet_count]) |*slot| if (slot.*) |*base| if (!base.variant) {
                base.deinit();
                slot.* = loaded;
                screen.noteInUse();
                return;
            };
        };
        if (screen.assembly) |*old| old.deinit();
        screen.assembly = loaded;
        if (screen.fresh_open) {
            // abriu outro arquivo: os outros aviões e variantes abertos fecham, e os resultados de antes somem
            screen.fresh_open = false;
            for (screen.fleet[0..screen.fleet_count]) |*slot| if (slot.*) |*other| {
                other.deinit();
                slot.* = null;
            };
            screen.fleet_count = 1;
            screen.fleet_current = 0;
            screen.clearResults();
            screen.loadVariants();
        }
        if (screen.fleet_count == 0) screen.fleet_count = 1; // a remontagem do projeto troca o avião atual; os outros ficam
        screen.showSwitched();
    }

    /// as variantes guardadas no `.aero` aberto (as partes `variantes/`) entram na lista, depois do avião montado
    fn loadVariants(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        if (data_sources.Format.fromPath(opened.path) != .aero) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io(), opened.path, memory, .limited(assembly_mod.max_file_bytes)) catch return;
        var diagnosis: aircraft_model.aircraft.Diag = .{};
        const document = aircraft_model.aero_file.readDocument(memory, bytes, &diagnosis) catch return;
        for (document.parts) |item| {
            if (!std.mem.startsWith(u8, item.name, variant_prefix) or screen.fleet_count >= max_fleet) continue;
            const json = zon_json.zonToJson(memory, item.data) catch continue;
            var variant = assembly_mod.fromBytes(std.heap.page_allocator, io(), opened.path, json, &diagnosis) catch continue;
            variant.variant = true;
            screen.fleet[screen.fleet_count] = variant;
            screen.fleet_count += 1;
        }
    }

    /// as variantes abertas como partes do `.aero` ("Salvar" leva o avião montado e todas as variantes juntos)
    fn variantParts(screen: *Screen, memory: std.mem.Allocator) ![]const aircraft_model.aero_file.Part {
        var parts: std.ArrayList(aircraft_model.aero_file.Part) = .empty;
        for (0..screen.fleet_count) |k| {
            const entry: ?*const assembly_mod.Assembly = if (k == screen.fleet_current) (if (screen.assembly) |*current| current else null) else if (screen.fleet[k]) |*other| other else null;
            const plane = entry orelse continue;
            if (!plane.variant) continue;
            try parts.append(memory, .{ .name = try std.fmt.allocPrint(memory, "{s}{d:0>2}.zon", .{ variant_prefix, parts.items.len + 1 }), .data = try zon_json.jsonToZon(memory, plane.source) });
        }
        return parts.items;
    }

    /// o texto do avião montado (o que não é variante) da lista; nulo: só há variantes abertas
    fn baseSource(screen: *Screen) ?[]const u8 {
        if (screen.assembly) |*current| if (!current.variant) return current.source;
        for (screen.fleet[0..screen.fleet_count]) |*slot| if (slot.*) |*base| if (!base.variant) return base.source;
        return null;
    }

    /// "Novo": um avião novo, do modelo padrão, no lugar de tudo o que estava aberto ("Salvar" pede onde gravar)
    fn newAircraft(screen: *Screen) void {
        var diagnosis: assembly_mod.Diagnosis = .{};
        const loaded = assembly_mod.fromBytes(std.heap.page_allocator, io(), "novo.aero", templates.all[0].json, &diagnosis) catch |err| {
            _ = std.fmt.bufPrintZ(&screen.assembly_note, "o avião novo não abriu: {s}", .{if (diagnosis.len > 0) diagnosis.text() else @errorName(err)}) catch {};
            return;
        };
        design.stages.closeProject(io()) catch {};
        screen.markStagesStale();
        screen.fresh_open = true;
        screen.adoptAircraft(loaded);
        screen.showAssembly();
        _ = std.fmt.bufPrintZ(&screen.assembly_note, "avião novo ({s}) · Salvar escolhe onde gravar", .{templates.all[0].name}) catch {};
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
        screen.shareAircraft();
    }

    /// as páginas passam a usar o avião atual da Montagem como ele está na tela (edições não salvas e variante)
    fn shareAircraft(screen: *Screen) void {
        const opened = &(screen.assembly orelse return);
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| page.setAircraft(opened.path, opened.source);
        screen.noteInUse();
    }

    /// o arquivo aberto mudou: as etapas e a janela das condições pedem a página de novo (o projeto é outro)
    fn markStagesStale(screen: *Screen) void {
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| if (page.kind == .stage) page.markStale();
        screen.requirements.markStale();
    }

    /// apaga os resultados das análises (abriu outro avião ou projeto)
    fn clearResults(screen: *Screen) void {
        for (screen.areas) |area| for (area.pages) |maybe| if (maybe) |page| page.clearResult();
    }

    /// a linha de cima diz com que avião as análises rodam (e qual variante) e qual projeto as etapas mostram
    fn noteInUse(screen: *Screen) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const project = design.stages.projectName(arena.allocator());
        const opened = &(screen.assembly orelse return);
        _ = std.fmt.bufPrintZ(&screen.in_use_name, "{s}", .{opened.loaded.ac.name}) catch {};
        _ = (if (project.len > 0)
            std.fmt.bufPrintZ(&screen.in_use, "projeto: {s}", .{project})
        else
            std.fmt.bufPrintZ(&screen.in_use, "sem projeto", .{})) catch {};
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
        fresh.variant = true;
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

    /// monta as áreas na primeira vez, da tabela em Zig (`manager.layout`): nada vem do Python
    fn collectLayout(screen: *Screen) void {
        if (screen.areas.len > 0) return;
        screen.buildAreas() catch {
            _ = std.fmt.bufPrintZ(&screen.message, "sem memória para as abas", .{}) catch {};
        };
    }

    /// a análise em Zig entra como subaba nova nesta área (é da área e nenhuma subaba da tabela tem o nome dela)
    fn appended(simulation: *const manager.Simulation, area: manager.Area) bool {
        if (!std.mem.eql(u8, simulation.area, area.title)) return false;
        for (area.tabs) |tab| if (std.mem.eql(u8, tab.name, simulation.name)) return false;
        return true;
    }

    /// uma página nova (`null` é a Montagem)
    fn newPage(screen: *Screen, tab: manager.Tab, path: []const u8, grids_beside: bool) !?*Page {
        if (tab.kind == .assembly) return null;
        const page = try std.heap.page_allocator.create(Page);
        const in_zig = if (tab.kind == .simulation) manager.find(tab.name) else null;
        page.* = .{
            .kind = switch (tab.kind) {
                .simulation => .simulation,
                .stage => .stage,
                else => .todo,
            },
            .name = tab.name,
            .title = tab.title,
            .bridge = &screen.bridge,
            .analysis = in_zig, // já portada para o Zig: roda sem o Python
            .grids_beside = grids_beside,
        };
        page.setAircraftPath(path);
        page.stale = false;
        return page;
    }

    /// as áreas e as páginas a partir de `manager.layout`, com as análises em Zig que não estão nela no fim da área
    fn buildAreas(screen: *Screen) !void {
        const memory = screen.layout_memory.allocator();
        const areas = try memory.alloc(Area, manager.layout.len);
        const labels = try memory.alloc([:0]const u8, manager.layout.len);
        const path = if (screen.assembly) |*opened| opened.path else "";
        for (manager.layout, 0..) |area, a| {
            var zig_analyses: usize = 0;
            for (&manager.all) |*simulation| zig_analyses += @intFromBool(appended(simulation, area));
            const tab_labels = try memory.alloc([:0]const u8, area.tabs.len + zig_analyses);
            const pages = try memory.alloc(?*Page, area.tabs.len + zig_analyses);
            for (area.tabs, 0..) |tab, k| {
                tab_labels[k] = tab.title;
                pages[k] = try screen.newPage(tab, path, false);
            }
            var slot = area.tabs.len;
            for (&manager.all) |*simulation| if (appended(simulation, area)) {
                tab_labels[slot] = simulation.title;
                pages[slot] = try screen.newPage(.{ .title = simulation.title, .kind = .simulation, .name = simulation.name }, path, true);
                slot += 1;
            };
            labels[a] = area.title;
            areas[a] = .{ .title = area.title, .single = area.single, .labels = tab_labels, .pages = pages };
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
        // acao=montagem:... (prints): os comandos só rodam com a Montagem na tela
        if (screen.pending_assembly_len > 0 and screen.assembly != null and screen.areas.len > 0) screen.showAssembly();
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
        if (screen.pending_export and screen.assembly != null) {
            screen.pending_export = false;
            screen.previewSheets();
        }
        if (rl.isFileDropped()) {
            const dropped = rl.loadDroppedFiles();
            defer rl.unloadDroppedFiles(dropped);
            for (0..dropped.count) |k| {
                const path = std.mem.sliceTo(dropped.paths[k], 0);
                screen.openFile(path);
                if (data_sources.Format.fromPath(path) != null) screen.showAssembly();
            }
        }
        if (ui_kit.undo.pressed()) screen.undo();
        // a página aberta
        const page: ?*Page = if (screen.areas.len > 0) screen.areas[screen.area].pages[screen.areas[screen.area].active] else null;
        const single = screen.areas.len == 0 or screen.areas[screen.area].single;
        // a janela estreita (um celular em pé): cabeçalho curto, as subabas em fichas e as áreas na barra de baixo
        const phone = ui_kit.phone.isPhone(width);
        if (!phone) screen.more_open = false;
        const top = if (phone) ui_kit.phone.header_height + (if (single) @as(f32, 0) else ui_kit.phone.chips_height) else widgets.header_height + 38 + (if (single) @as(f32, 0) else 32);
        const bottom: f32 = if (phone) ui_kit.phone.bar_height else 0;
        // com uma janela aberta (seletor de arquivo, pergunta, condições), a tela de baixo não recebe o clique nem a roda
        const page_modal = if (page) |p| p.modalOpen() else false;
        // "Exportar → Dados em Excel" dos gráficos e tabelas: a prévia monta a planilha antes de gravar
        ui_kit.plot.data_export = sheet_window.previewData;
        const modal = screen.files.open or screen.requirements_open or screen.sheet_window.open or sheet_window.preview.open or screen.variant_prompt.open or page_modal;
        const wheel = ui.wheel;
        if (modal) {
            ui.click_taken = true;
            ui.wheel = 0;
        }
        const content: rl.Rectangle = .{ .x = 0, .y = top, .width = width, .height = height - top - bottom };
        // a lista do "Mais" aberta fica por cima da página: a página não recebe o toque
        if (screen.more_open and !modal) {
            ui.click_taken = true;
            ui.wheel = 0;
        }
        if (page) |p| {
            p.process_io = screen.io;
            p.phone = phone;
            if (screen.shown != p) {
                if (screen.shown != null) p.markStale(); // outra página pode ter mudado o projeto
                screen.shown = p;
            }
            if (screen.pending_run) {
                p.command("rodar");
                screen.pending_run = false;
            }
            if (screen.pending_stage_len > 0) {
                p.command(screen.pending_stage[0..screen.pending_stage_len]);
                screen.pending_stage_len = 0;
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
            if (p.takeReloaded()) |path| screen.openAircraft(path);
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
        // acao=desfazer (prints): um Ctrl+Z quando o que estava pendente acabou
        if (screen.pending_undo > 0 and screen.pending_stage_len == 0 and screen.pending_assembly_len == 0 and screen.pending_tab == null and !(if (page) |p| p.settling() else false)) {
            screen.pending_undo -= 1;
            screen.undo();
        }
        if (screen.more_open and !modal) {
            ui.click_taken = false;
            ui.wheel = wheel;
        }
        if (phone) {
            var marks: [16]ui_kit.phone.Mark = undefined;
            const marked = areaMarks(screen.area_labels, &marks);
            if (screen.more_open and !modal) _ = ui_kit.phone.moreMenu(ui, content, screen.area_labels, marked, &screen.area, &screen.more_open);
            if (ui_kit.phone.header(ui, width, "AeroSim", &.{ "Novo", "Abrir", "Salvar" })) |button| {
                // no navegador do celular, "Abrir" pega o arquivo do aparelho (a página esconde a barra dela)
                switch (button) {
                    0 => screen.command("novo"),
                    1 => if (!ui_kit.system.pickFromDevice()) screen.command("abrir"),
                    else => screen.command("salvar"),
                }
            }
            if (!single) {
                const area = &screen.areas[screen.area];
                const tint = if (screen.area < marked.len) marked[screen.area].color else theme.colors.accent;
                _ = screen.area_chips.draw(ui, .{ .x = 0, .y = ui_kit.phone.header_height, .width = width, .height = ui_kit.phone.chips_height }, area.labels, &area.active, tint);
            }
            _ = ui_kit.phone.bottomBar(ui, .{ .x = 0, .y = height - bottom, .width = width, .height = bottom }, screen.area_labels, marked, &screen.area, &screen.more_open);
        } else {
            if (widgets.header(ui, width, "AeroSim", &.{ "Novo", "Abrir…", "Salvar" }, &screen.in_use_name, &screen.in_use)) |button| {
                // no navegador, "Abrir" pega o arquivo do computador (o seletor do sistema), não a pasta da página
                switch (button) {
                    0 => screen.command("novo"),
                    1 => if (!ui_kit.system.pickFromDevice()) screen.command("abrir"),
                    else => screen.command("salvar"),
                }
            }
            _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height, .width = width, .height = 38 }, screen.area_labels, &screen.area, 14);
            if (!single) {
                const area = &screen.areas[screen.area];
                _ = widgets.tabBar(ui, .{ .x = 0, .y = widgets.header_height + 38, .width = width, .height = 32 }, area.labels, &area.active, 13);
            }
            // "Planilha…": trazer dados de uma planilha para esta área (na Montagem não tem)
            if (screen.areas.len > 0 and !std.mem.eql(u8, screen.areas[screen.area].title, "Montagem")) {
                const row_y = widgets.header_height + (if (single) @as(f32, 0) else 38);
                const row_height: f32 = if (single) 38 else 32;
                if (ui_kit.dialogs.button(ui, .{ .x = width - 128, .y = row_y + 4, .width = 116, .height = row_height - 8 }, "Planilha…")) screen.openSheetWindow();
                // "Exportar…" (nas áreas que têm planilha da equipe): simula e gera a planilha daquela área
                if (exportable(screen.areas[screen.area].title) and ui_kit.dialogs.button(ui, .{ .x = width - 252, .y = row_y + 4, .width = 116, .height = row_height - 8 }, "Exportar…")) screen.command("exportar");
            }
        }
        if (modal) {
            ui.click_taken = false;
            ui.wheel = wheel;
            const whole: rl.Rectangle = .{ .x = 0, .y = 0, .width = width, .height = height };
            if (page) |p| p.drawModal(ui, whole);
            if (screen.requirements_open) screen.drawRequirements(ui, whole);
            if (screen.areas.len > 0) screen.sheet_window.follow(screen.areas[screen.area].title);
            screen.sheet_window.draw(ui, whole);
            sheet_window.preview.draw(ui, whole);
            if (screen.sheet_window.wants_aircraft) {
                screen.sheet_window.wants_aircraft = false;
                screen.usePolynomial();
            }
            if (screen.variant_prompt.open) {
                if (screen.variant_prompt.draw(ui, whole)) |typed| screen.nameVariant(typed) else if (!screen.variant_prompt.open) screen.dropVariant();
            }
            const saving = screen.files.saving;
            if (screen.files.draw(ui, whole)) |path| {
                if (saving) screen.save(path) else if (screen.importing_file) {
                    screen.importing_file = false;
                    screen.startImport(path);
                } else {
                    screen.openFile(path);
                    screen.showAssembly();
                }
            }
        }
    }

    /// "Condições e restrições…": a etapa "requisitos" numa janela por cima; ao fechar, as etapas refazem a conta
    fn drawRequirements(screen: *Screen, ui: *widgets.Ui, whole: rl.Rectangle) void {
        rl.drawRectangleRec(whole, .{ .r = 20, .g = 30, .b = 50, .a = 90 });
        const margin: f32 = if (ui_kit.phone.isPhone(whole.width)) 6 else 60;
        const box: rl.Rectangle = .{ .x = whole.x + margin, .y = whole.y + margin * 5 / 6, .width = whole.width - 2 * margin, .height = whole.height - margin * 5 / 3 };
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
        const phone = ui_kit.phone.isPhone(rect.width);
        if (screen.pending_assembly_len > 0 and screen.assembly != null and screen.assembly_editor != null) screen.runPendingAssembly();
        if (screen.assembly_editor) |*editor| if (screen.assembly) |*opened| if (editor.want_rebuild) {
            editor.want_rebuild = false;
            editor.rebuild(&opened.loaded.ac) catch {};
        };
        if (phone) return screen.drawAssemblyPhone(ui, rect);
        const list_height = screen.drawAssemblySide(ui, rect, side_width) orelse return;
        if (screen.assembly_panel) |*shown| shown.draw(ui, &screen.assembly_scroll, .{ .x = rect.x + 12, .y = rect.y + 12 + list_height, .width = side_width - 6, .height = rect.height - 24 - list_height });
        if (editor_width > 0) screen.drawAssemblyEditor(ui, .{ .x = rect.x + rect.width - 12 - editor_width + 6, .y = rect.y + 12, .width = editor_width - 6, .height = rect.height - 24 });
        const card_rect: rl.Rectangle = .{ .x = rect.x + 12 + side_width, .y = rect.y + 12, .width = rect.width - 24 - side_width - editor_width, .height = rect.height - 24 };
        screen.drawAssemblyView(ui, card_rect, false);
    }

    /// a coluna da esquerda da Montagem: os aviões abertos, o vento, a lista das peças e os botões; devolve a altura
    /// usada (nulo: trocou de avião, o resto do quadro não vale)
    fn drawAssemblySide(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle, side_width: f32) ?f32 {
        var list_height: f32 = 0;
        if (screen.assembly_editor) |*editor| if (screen.assembly) |*opened| {
            // os aviões abertos (a barra das variantes do Python): qual é este, trocar, uma variante nova e fechar
            var fleet_buffer: [200]u8 = undefined;
            theme.text(ui.fonts.bold, if (screen.fleet_count > 1) "Variantes (clique para ver)" else widgets.format(&fleet_buffer, "Avião: {s}", .{opened.loaded.ac.name}), rect.x + 16, rect.y + 12, 15, theme.colors.ink);
            // a lista do avião montado e das variantes dele: clicar mostra a escolhida (e as análises passam a usá-la)
            var variants_height: f32 = 0;
            if (screen.fleet_count > 1) {
                var labels: [max_fleet][:0]const u8 = undefined;
                var label_buffers: [max_fleet][168]u8 = undefined;
                for (0..screen.fleet_count) |k| {
                    const entry: ?*const assembly_mod.Assembly = if (k == screen.fleet_current) opened else if (screen.fleet[k]) |*other| other else null;
                    labels[k] = if (entry) |plane| widgets.format(&label_buffers[k], "{s}{s}", .{ plane.loaded.ac.name, if (plane.variant) "" else "  (montado)" }) else "";
                }
                variants_height = @min(@as(f32, @floatFromInt(screen.fleet_count)), 4) * ui_kit.menus.ItemList.line_height + 6;
                if (screen.variant_list.draw(ui, .{ .x = rect.x + 12, .y = rect.y + 34, .width = side_width - 6, .height = variants_height }, labels[0..screen.fleet_count], screen.fleet_current)) |picked| {
                    screen.selectAircraft(picked);
                    return null;
                }
                variants_height += 8;
            }
            var fleet_height: f32 = 0;
            if (ui_kit.menus.buttonGrid(ui, rect.x + 12, rect.y + 34 + variants_height, side_width - 6, &fleet_buttons, 4, &fleet_height)) |pressed| {
                screen.fleetButton(pressed);
                return null;
            }
            const wind_top = 34 + variants_height + fleet_height + 10;
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
        return list_height;
    }

    /// o formulário da peça escolhida na Montagem
    fn drawAssemblyEditor(screen: *Screen, ui: *widgets.Ui, editor_rect: rl.Rectangle) void {
        const editor = &screen.assembly_editor.?;
        var list_button: ?usize = null;
        if (editor.drawForm(ui, editor_rect, &list_button)) screen.applyEdit();
        if (list_button) |pressed| screen.listButton(pressed);
    }

    /// a Montagem no celular: o 3D em cima e a folha embaixo, com as fichas Peças, Peça escolhida e Resumo
    fn drawAssemblyPhone(screen: *Screen, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const tabs_height: f32 = 44;
        const sheet = screen.assembly_sheet.place(ui, rect, tabs_height);
        screen.drawAssemblyView(ui, .{ .x = rect.x + 8, .y = rect.y + 8, .width = rect.width - 16, .height = @max(80, sheet.y - rect.y - 16) }, true);
        const inner = ui_kit.phone.Sheet.drawBack(sheet);
        const tabs = [_][:0]const u8{ "Peças", "Peça escolhida", "Resumo" };
        _ = screen.assembly_tabs.draw(ui, .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = tabs_height }, &tabs, &screen.assembly_tab, theme.hex(0xa61e4d));
        const body: rl.Rectangle = .{ .x = inner.x, .y = inner.y + tabs_height, .width = inner.width, .height = @max(0, inner.height - tabs_height) };
        if (body.height < 40) return;
        ui.pushClip(body);
        defer ui.popClip();
        switch (screen.assembly_tab) {
            0 => _ = screen.drawAssemblySide(ui, .{ .x = body.x - 4, .y = body.y - 4, .width = body.width, .height = body.height }, body.width - 12),
            1 => if (screen.assembly_editor != null and screen.assembly != null) screen.drawAssemblyEditor(ui, .{ .x = body.x + 8, .y = body.y + 4, .width = body.width - 16, .height = body.height - 8 }),
            else => if (screen.assembly_panel) |*shown| shown.draw(ui, &screen.assembly_scroll, .{ .x = body.x + 8, .y = body.y + 4, .width = body.width - 16, .height = body.height - 8 }),
        }
    }

    /// o cartão do 3D da Montagem em `card_rect`, com os botões das vistas, o Restaurar, o Acertar o CG e a trava do
    /// arraste (no celular, em grades dentro do cartão)
    fn drawAssemblyView(screen: *Screen, ui: *widgets.Ui, card_rect: rl.Rectangle, phone: bool) void {
        const area = cardInside(card_rect);
        screen.dragPiece(ui, area);
        screen.assembly_view.handleInput(ui, area);
        if (screen.assembly_view.dragging) screen.assembly_angle = .free;
        screen.assembly_angle.aim(&screen.assembly_view);
        var title_buffer: [160]u8 = undefined;
        var title: [:0]const u8 = "Montagem: nenhum avião aberto (arraste um .aero para a janela)";
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
                if (screen.assembly_panel) |shown| drawNeutralPoint(&screen.assembly_view, shown.neutral_x, size);
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
                const text = if (phone)
                    widgets.format(&buffer, "{s}_CG = {d:.3} m   {s}_CG = {d:.3} m", .{ names[shown[0]], cg[shown[0]], names[shown[1]], cg[shown[1]] })
                else
                    widgets.format(&buffer, "{s}_CG = {d:.3} m     {s}_CG = {d:.3} m     (a partir da referência, a cruz cinza)", .{ names[shown[0]], cg[shown[0]], names[shown[1]], cg[shown[1]] });
                theme.text(ui.fonts.bold, text, area.x + 10, if (phone) area.y + area.height - 64 else area.y + 8, if (phone) 14 else 16, theme.hex(0xd62728));
            }
        }
        // "Restaurar" e "Acertar o CG", antes dos botões das vistas
        var restore_at: ?rl.Vector2 = null;
        // no celular: as vistas e as duas ações numa grade de três no alto do 3D, a trava do arraste numa de quatro
        // embaixo
        if (phone) {
            var captions: [6][:0]const u8 = undefined;
            for (std.enums.values(ViewAngle), 0..) |angle, k| captions[k] = angle.caption();
            captions[4] = "Restaurar";
            captions[5] = "Acertar o CG";
            var used: f32 = 0;
            const grid_x = area.x + 6;
            const grid_y = area.y + 6;
            const grid_width = area.width - 12;
            const pressed = if (screen.assembly != null) ui_kit.menus.buttonGrid(ui, grid_x, grid_y, grid_width, &captions, 3, &used) else ui_kit.menus.buttonGrid(ui, grid_x, grid_y, grid_width, captions[0..4], 4, &used);
            const cell_width = (grid_width - 2 * 6) / 3;
            for (std.enums.values(ViewAngle), 0..) |angle, k| if (screen.assembly_angle == angle and screen.assembly != null) {
                rl.drawRectangleLinesEx(.{ .x = grid_x + @as(f32, @floatFromInt(k % 3)) * (cell_width + 6), .y = grid_y + @as(f32, @floatFromInt(k / 3)) * (used / 2), .width = cell_width, .height = used / 2 - 6 }, 2, theme.colors.accent);
            };
            if (pressed) |index| {
                if (index < 4) screen.assembly_angle = std.enums.values(ViewAngle)[index] else if (index == 4) screen.restore_open = !screen.restore_open else screen.fitCg();
            }
            if (screen.restore_open) restore_at = .{ .x = area.x + 6, .y = grid_y + used };
            if (screen.assembly != null) {
                var lock_captions: [std.enums.values(DragLock).len][:0]const u8 = undefined;
                for (std.enums.values(DragLock), 0..) |lock, k| lock_captions[k] = lock.caption();
                var lock_used: f32 = 0;
                if (ui_kit.menus.buttonGrid(ui, grid_x, area.y + area.height - 40, grid_width, &lock_captions, lock_captions.len, &lock_used)) |index| screen.drag_lock = std.enums.values(DragLock)[index];
            }
        } else if (screen.assembly != null) {
            const actions = [_][:0]const u8{ "Restaurar", "Acertar o CG" };
            for (actions, 0..) |caption, k| {
                const button_width: f32 = 110;
                const button: rl.Rectangle = .{ .x = card_rect.x + card_rect.width - 8 - 4 * (86 + 6) - 12 - (2 - @as(f32, @floatFromInt(k))) * (button_width + 6), .y = card_rect.y + 5, .width = button_width, .height = 26 };
                if (ui_kit.dialogs.button(ui, button, caption)) {
                    if (k == 0) screen.restore_open = !screen.restore_open else screen.fitCg();
                }
                if (k == 0 and screen.restore_open) restore_at = .{ .x = button.x, .y = button.y + button.height + 4 };
            }
        }
        // os botões das vistas, à direita do título (por cima do cartão); arrastar volta ao 3D livre
        for (if (phone) &[_]ViewAngle{} else std.enums.values(ViewAngle), 0..) |angle, k| {
            const button_width: f32 = 86;
            const button: rl.Rectangle = .{ .x = card_rect.x + card_rect.width - 8 - (4 - @as(f32, @floatFromInt(k))) * (button_width + 6), .y = card_rect.y + 5, .width = button_width, .height = 26 };
            if (ui_kit.dialogs.button(ui, button, angle.caption())) screen.assembly_angle = angle;
            if (screen.assembly_angle == angle) rl.drawRectangleLinesEx(button, 2, theme.colors.accent);
        }
        if (!phone) theme.text(ui.fonts.regular, std.mem.sliceTo(&screen.assembly_note, 0), area.x + 6, area.y + area.height - 18, 12, theme.colors.muted);
        // a trava do arraste, no canto de baixo à direita do 3D
        if (screen.assembly != null and !phone) {
            const lock_width: f32 = 96;
            const locks = std.enums.values(DragLock);
            const row_x = area.x + area.width - @as(f32, @floatFromInt(locks.len)) * (lock_width + 4) - 4;
            const row_y = area.y + area.height - 58;
            theme.text(ui.fonts.regular, "arraste:", row_x - 62, row_y + 6, 13, theme.colors.muted);
            for (locks, 0..) |lock, k| {
                const button: rl.Rectangle = .{ .x = row_x + @as(f32, @floatFromInt(k)) * (lock_width + 4), .y = row_y, .width = lock_width, .height = 26 };
                if (ui_kit.dialogs.button(ui, button, lock.caption())) screen.drag_lock = lock;
                if (screen.drag_lock == lock) rl.drawRectangleLinesEx(button, 2, theme.colors.accent);
            }
        }
        // o menu do "Restaurar", por cima de tudo: como foi aberto ou um dos modelos padrão
        if (restore_at) |corner| {
            var captions: [1 + templates.all.len][:0]const u8 = undefined;
            var caption_buffers: [templates.all.len][96]u8 = undefined;
            captions[0] = "como estava ao abrir";
            for (templates.all, 0..) |template, k| captions[k + 1] = widgets.format(&caption_buffers[k], "modelo padrão: {s}", .{template.name});
            const menu_width: f32 = @min(400, card_rect.x + card_rect.width - corner.x - 4);
            const box: rl.Rectangle = .{ .x = corner.x, .y = corner.y, .width = menu_width, .height = @as(f32, @floatFromInt(captions.len)) * 34 + 8 };
            rl.drawRectangleRec(box, theme.colors.panel);
            rl.drawRectangleLinesEx(box, 1, theme.colors.muted);
            var used: f32 = 0;
            if (ui_kit.menus.buttonGrid(ui, box.x + 4, box.y + 4, menu_width - 8, &captions, 1, &used)) |pressed| {
                screen.restore_open = false;
                if (pressed == 0) screen.restoreAircraft() else screen.restoreTemplate(pressed - 1);
            }
        }
    }
};

/// o símbolo e a cor de cada área no celular, pelo título que vem de `manager.layout` (uma área nova sem símbolo
/// ganha o círculo e uma cor da paleta)
fn areaMarks(labels: []const [:0]const u8, marks: *[16]ui_kit.phone.Mark) []const ui_kit.phone.Mark {
    const known = [_]struct { title: []const u8, mark: ui_kit.phone.Mark }{
        .{ .title = "Biblioteca", .mark = .{ .symbol = .library, .color = theme.hex(0x6741d9) } },
        .{ .title = "Dimensionamento", .mark = .{ .symbol = .sizing, .color = theme.hex(0x0b7285) } },
        .{ .title = "Aerodinâmica", .mark = .{ .symbol = .aerodynamics, .color = theme.hex(0x1864ab) } },
        .{ .title = "Estabilidade", .mark = .{ .symbol = .stability, .color = theme.hex(0x2b8a3e) } },
        .{ .title = "Desempenho", .mark = .{ .symbol = .performance, .color = theme.hex(0xe67700) } },
        .{ .title = "Cargas", .mark = .{ .symbol = .loads, .color = theme.hex(0xc92a2a) } },
        .{ .title = "Montagem", .mark = .{ .symbol = .assembly, .color = theme.hex(0xa61e4d) } },
    };
    const count = @min(labels.len, marks.len);
    for (labels[0..count], 0..) |label, k| {
        marks[k] = .{ .color = theme.plotColor(k) };
        for (known) |entry| if (std.mem.startsWith(u8, label, entry.title)) {
            marks[k] = entry.mark;
        };
    }
    return marks[0..count];
}

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
/// por onde a peça arrastada no 3D anda (o "arraste:" do Python): no plano da tela ou só ao longo de um eixo
const DragLock = enum {
    screen,
    x,
    y,
    z,

    /// o texto do botão
    fn caption(lock: DragLock) [:0]const u8 {
        return switch (lock) {
            .screen => "plano da tela",
            .x => "só x",
            .y => "só y",
            .z => "só z",
        };
    }

    /// o eixo que fica (nulo: os três, no plano da tela)
    fn axis(lock: DragLock) ?usize {
        return switch (lock) {
            .screen => null,
            .x => 0,
            .y => 1,
            .z => 2,
        };
    }
};

/// a barra dos aviões abertos na Montagem
const fleet_buttons = [_][:0]const u8{ "Anterior", "Próximo", "+ Variante", "Fechar" };
/// quantos aviões ficam abertos ao mesmo tempo
const max_fleet = 8;
/// as variantes dentro do `.aero`: uma parte por variante, `variantes/01.zon`, `variantes/02.zon`...
const variant_prefix = "variantes/";

const part_buttons = [_][:0]const u8{ "+ Asa", "+ EH", "+ EV", "+ Motor", "+ Tubo", "+ Tanque", "Remover", "Trazer de outro" };

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
        var diagnosis: assembly_mod.Diagnosis = .{};
        const bytes = try assembly_mod.readAircraftText(memory, io(), path, &diagnosis);
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
/// o ponto neutro: um traço vertical verde em x_NP, no plano de simetria (o `_draw_markers` do Python, ±0,3 m)
fn drawNeutralPoint(view: *view3d.View, neutral_x: f64, size: f64) void {
    if (!std.math.isFinite(neutral_x)) return;
    const color = theme.hex(0x1a9a1a);
    const half = @max(0.3, 0.12 * size);
    view3d.segment(.{ neutral_x, 0, -half }, .{ neutral_x, 0, half }, color);
    view3d.segment(.{ neutral_x + 0.004 * size, 0, -half }, .{ neutral_x + 0.004 * size, 0, half }, color);
    view.label(.{ neutral_x, 0, -half - 0.02 * size }, "PN", color);
}

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

/// o resumo da Montagem pronto para desenhar: o texto do painel em células da tabela, numa arena só dele
const AssemblyPanel = struct {
    arena: std.heap.ArenaAllocator,
    name: [:0]const u8,
    summary: []const u8,
    titles: []const [:0]const u8,
    tables: []const []const []const ui_kit.plot.Cell,
    warnings: []const []const u8,
    neutral_x: f64, // o ponto neutro (o traço verde no 3D, como o `set_markers` do Python)

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
        return .{ .arena = arena, .name = try memory.dupeZ(u8, panel.name), .summary = panel.summary, .titles = titles, .tables = tables, .warnings = panel.warnings, .neutral_x = panel.neutral_x };
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
            ui_kit.plot.table(ui, .{ .x = rect.x, .y = y, .width = width, .height = height }, title, &.{ "item", "valor" }, rows, &.{ 0.36, 0.64 });
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

/// a área tem planilha da equipe para exportar (o botão "Exportar…" aparece nela)
fn exportable(area: []const u8) bool {
    for ([_][]const u8{ "Desempenho", "Aerodinâmica", "Estabilidade" }) |name| if (std.mem.eql(u8, area, name)) return true;
    return false;
}

/// o que a prévia do "Exportar…" precisa para refazer a planilha quando o usuário marca ou desmarca uma superfície:
/// o avião, que planilha é e, para cada caixa da lista, a superfície dela
const sheet_export = struct {
    const Kind = enum { aerodynamics, stability };
    var aircraft: ?*const aircraft_model.aircraft.Aircraft = null;
    var kind: Kind = .aerodynamics;
    var surface_of: [sheet_window.max_choices]usize = undefined;
    var names: [sheet_window.max_choices][]const u8 = undefined;
    var name_storage: [sheet_window.max_choices][64]u8 = undefined;
    var count: usize = 0;
    var arena: ?std.heap.ArenaAllocator = null;

    /// guarda o avião e monta a lista: uma caixa por superfície ligada, com o papel dela
    fn start(plane: *const aircraft_model.aircraft.Aircraft, which: Kind) void {
        aircraft = plane;
        kind = which;
        count = 0;
        for (plane.surfaces, 0..) |surface, index| {
            if (!surface.enabled or count == sheet_window.max_choices) continue;
            const role = if (std.mem.eql(u8, surface.role, "wing")) "asa" else if (std.mem.eql(u8, surface.role, "htail")) "EH" else if (std.mem.eql(u8, surface.role, "vtail")) "EV" else surface.role;
            // o papel entre parênteses, a não ser que o nome já seja ele ("EH", "asa")
            names[count] = if (std.ascii.eqlIgnoreCase(surface.name, role)) surface.name else std.fmt.bufPrint(&name_storage[count], "{s} ({s})", .{ surface.name, role }) catch surface.name;
            surface_of[count] = index;
            count += 1;
        }
    }

    fn labels() []const []const u8 {
        return names[0..count];
    }

    /// monta a planilha com as superfícies marcadas; os bytes valem até a próxima chamada
    fn rebuild(chosen: []const bool) ?[]const u8 {
        const plane = aircraft orelse return null;
        if (arena) |*old| old.deinit();
        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const memory = arena.?.allocator();
        const include = memory.alloc(bool, plane.surfaces.len) catch return null;
        @memset(include, false);
        for (chosen, surface_of[0..chosen.len]) |on, index| include[index] = on;
        var note: [512]u8 = undefined;
        const built = switch (kind) {
            .aerodynamics => manager.aero_sheet.workbook(memory, plane, include),
            .stability => manager.stability_sheet.workbook(memory, plane, include),
        };
        return built catch |err| {
            ui_kit.toast.show(std.fmt.bufPrint(&note, "não exportou: {s}", .{@errorName(err)}) catch "não exportou");
            return null;
        };
    }
};

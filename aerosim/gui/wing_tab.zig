//! A aba Aerodinâmica → Projetar: a etapa Asa do dimensionamento, peça por peça como o `WingPage` da GUI em Python
//! (`aerosim/gui/design/pages.py`). À esquerda, a barra de requisitos ("Condições e restrições…"), o título com a
//! ajuda, o rascunho da asa (nome, planta trapézio ou tabela de seções, perfis, envergadura, área ou corda,
//! afilamento, trecho retangular, enflechamento, torção, diedro, ângulo de cruzeiro), a tabela de partições (na
//! planta "tabela"), "Guardar asa" e a caixa "Guardados". À direita, a asa em 3D com o ponto neutro, C_L em α até o
//! estol, a polar, L/D, o c_l ao longo da envergadura (onde o estol começa), o diagnóstico (com as restrições ativas
//! da asa) e os resultados. A conta é a do núcleo, `core/src/sizing/wing_line.zig`.
const std = @import("std");
const rl = @import("raylib");
const core = @import("aerosim");
const ui_kit = @import("ui");
const theme = ui_kit.theme;
const widgets = ui_kit.widgets;
const form_mod = ui_kit.form;
const plot = ui_kit.plot;
const view3d = ui_kit.view3d;
const table_mod = ui_kit.table;
const checks_mod = ui_kit.checks;
const stage_ui = ui_kit.stage;
const numbers = ui_kit.numbers;
const aircraft_model = @import("aircraft_model");
const stage = @import("airfoil_stage.zig");
const design_mod = @import("design.zig");
const assembly = @import("assembly.zig");

const model = aircraft_model.aircraft;
const registry = design_mod.registry;
const Name = design_mod.Name;
const wing_line = core.wing_line;

const help = "A asa a partir do perfil escolhido: forma em planta, linha sustentadora, onde o estol começa, polar e L/D. A incidência sai do ângulo de cruzeiro. Guarde as asas que quiser comparar: a etapa Empenagem parte de uma delas.";

const FieldId = enum(usize) { name, planform, size_by, root_chord, root_airfoil, tip_airfoil, span, area, taper, rect_fraction, sweep, twist, dihedral, alpha_cruise };

const default_fields = [_]form_mod.Field{
    .{ .label = "nome", .group = 0, .kind = .text },
    .{ .label = "planta", .group = 0, .kind = .choice, .choices = "trapézio;tabela de seções", .help = "trapézio: envergadura, área ou corda, afilamento e trecho retangular; tabela de seções: uma linha por seção (y, corda, perfil, recuo, torção), quantas quiser" },
    .{ .label = "dimensionar por", .group = 0, .kind = .choice, .choices = "área;corda", .help = "área: digite a área e a corda sai dela; corda: digite a corda da raiz e a área sai (trapézio)" },
    .{ .label = "corda da raiz", .unit = "m", .group = 0, .number = 0.35, .minimum = 0.03, .maximum = 3, .help = "vale com 'dimensionar por' = corda" },
    .{ .label = "perfil (raiz)", .group = 0, .kind = .choice, .choices = "", .help = "um dos perfis da etapa Perfil" },
    .{ .label = "perfil da ponta", .group = 0, .kind = .choice, .choices = "", .help = "vazio = o mesmo da raiz; outro perfil: a asa vai do perfil da raiz (e do trecho retangular) ao da ponta, interpolando" },
    .{ .label = "envergadura", .unit = "m", .group = 0, .number = 2.4, .minimum = 0.3, .maximum = 8, .help = "de ponta a ponta" },
    .{ .label = "área", .unit = "m²", .group = 0, .number = 0.85, .minimum = 0.05, .maximum = 5, .help = "área em planta (as duas semiasas)" },
    .{ .label = "afilamento", .group = 0, .number = 1, .minimum = 0.2, .maximum = 1, .help = "corda da ponta / corda da raiz (no trecho trapezoidal)" },
    .{ .label = "trecho retangular", .group = 0, .number = 1, .minimum = 0, .maximum = 1, .help = "fração da semienvergadura com corda constante" },
    .{ .label = "enflechamento (c/4)", .unit = "°", .group = 0, .number = 0, .minimum = -10, .maximum = 45, .help = "da linha de 1/4 da corda no trecho trapezoidal" },
    .{ .label = "torção na ponta", .unit = "°", .group = 0, .number = -1, .minimum = -8, .maximum = 4, .help = "− = washout (a ponta estola depois)" },
    .{ .label = "diedro", .unit = "°", .group = 0, .number = 2, .minimum = -5, .maximum = 15 },
    .{ .label = "ângulo de cruzeiro (fuselagem)", .unit = "°", .group = 0, .number = 0, .minimum = -4, .maximum = 8, .help = "a asa é calada para a fuselagem voar neste ângulo no cruzeiro" },
};

/// os campos que só valem no trapézio (desligados na tabela), `TRAPEZOID_ONLY` da GUI
const trapezoid_only = [_]FieldId{ .span, .area, .root_chord, .size_by, .taper, .rect_fraction, .sweep, .twist, .root_airfoil, .tip_airfoil };

const partition_columns = [_]table_mod.Column{
    .{ .title = "enverg. (m)", .kind = .number, .width = 0.16, .help = "quanto a partição soma na envergadura total (metade de cada lado)" },
    .{ .title = "corda (m)", .kind = .number, .width = 0.14, .help = "corda no começo da partição (do lado do centro)" },
    .{ .title = "afil.", .kind = .number, .width = 0.1, .help = "corda no fim / corda no começo (1 = reta)" },
    .{ .title = "perfil", .kind = .choice, .width = 0, .help = "perfil no fim da partição (vazio = o da raiz); ao longo dela ele passa do da anterior para este" },
    .{ .title = "recuo (m)", .kind = .number, .width = 0.14, .help = "quanto o bordo de ataque anda para trás ao longo da partição (enflechamento): move o centro aerodinâmico, e com ele o CG de projeto. 0 = bordo de ataque reto" },
    .{ .title = "θ (°)", .kind = .number, .width = 0.1, .help = "torção no fim da partição, em relação à raiz: − = washout, a ponta estola depois (o aileron continua mandando no estol), custa um pouco de sustentação" },
};
const partitions_help = "uma linha por partição, como na planilha: envergadura, corda, afilamento, perfil, recuo e torção. A envergadura total é a soma das partições. Uma asa reta é uma linha só (afilamento 1).";

const max_choices = design_mod.max_airfoils * 2;
const summary_rows = 14;
const max_used = wing_line.max_partitions + 1; // perfis numa asa: o da raiz e um por partição

/// uma asa analisada: o resultado, a planta e os perfis de cada seção (o 0 é o da raiz)
const Analysis = struct {
    result: wing_line.Result = .{},
    planform: wing_line.Planform = undefined,
    used: [max_used]*const stage.Candidate = undefined,
    used_count: usize = 0,
};

pub const WingTab = struct {
    groups: [1]form_mod.Group = .{.{ .title = "Asa (rascunho)" }},
    fields: [default_fields.len]form_mod.Field = default_fields,
    form: form_mod.Form = .{ .groups = &.{}, .fields = &.{} },
    root_choices: [max_choices * 64:0]u8 = [_:0]u8{0} ** (max_choices * 64),
    tip_choices: [max_choices * 64 + 32:0]u8 = [_:0]u8{0} ** (max_choices * 64 + 32),
    candidates: [max_choices]*const stage.Candidate = undefined, // na ordem das escolhas
    candidate_count: usize = 0,
    design: *design_mod.Design = undefined,
    seen_version: u32 = std.math.maxInt(u32),
    draft: Analysis = .{},
    has_result: bool = false,
    root_name: [64:0]u8 = [_:0]u8{0} ** 64,
    message: [200:0]u8 = [_:0]u8{0} ** 200,
    scroll: f32 = 0,
    plots: ui_kit.scroll.ScrollArea = .{}, // a coluna da direita
    view: view3d.View = .{}, // a asa em 3D
    mesh: ?assembly.Mesh = null,
    sections: [wing_line.max_sections]model.Section = undefined, // as seções da asa do 3D
    side: ui_kit.scroll.ScrollArea = .{}, // a barra lateral
    kept: stage_ui.KeptBox = .{}, // as asas guardadas
    partitions: table_mod.EditTable = .{}, // a tabela de partições
    checks: checks_mod.ChecksPanel = .{},
    saved: [design_mod.max_wings]Analysis = undefined, // as guardadas, para comparar nos gráficos
    saved_ok: [design_mod.max_wings]bool = [_]bool{false} ** design_mod.max_wings,
    // o diagnóstico da última rodada (os textos moram aqui)
    check_list: [checks_mod.max_checks]checks_mod.Check = undefined,
    check_count: usize = 0,
    check_text: [checks_mod.max_checks][4][160]u8 = undefined,
    // curvas montadas a cada rodada
    cruise_line: [2][2]f64 = undefined, // a reta vertical do C_L de cruzeiro no gráfico de L/D
    max_line: [2][wing_line.stations]f64 = undefined,
    onset_x: [2]f64 = undefined,
    onset_y: [2]f64 = undefined,

    fn field(tab: *WingTab, id: FieldId) *form_mod.Field {
        return &tab.fields[@intFromEnum(id)];
    }

    fn setMessage(tab: *WingTab, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrintZ(&tab.message, fmt, args) catch {};
    }

    /// liga a aba ao projeto (as escolhas de perfil, as condições e a asa em desenho)
    pub fn attach(tab: *WingTab, design: *design_mod.Design) void {
        tab.design = design;
        tab.syncDesign();
    }

    /// um comando pelo nome (prints): "tabela" passa a planta para a tabela de seções
    pub fn command(tab: *WingTab, name: []const u8) void {
        if (std.mem.eql(u8, name, "tabela")) {
            tab.field(.planform).choice = 1;
            tab.run();
        }
    }

    /// refaz as escolhas de perfil e o formulário quando o projeto muda (os perfis de Perfis, a biblioteca, as
    /// condições editadas na janela de requisitos, uma asa guardada carregada no rascunho)
    fn syncDesign(tab: *WingTab) void {
        const design = tab.design;
        if (design.version == tab.seen_version) return;
        tab.seen_version = design.version;
        tab.candidate_count = 0;
        var root_writer: std.Io.Writer = .fixed(&tab.root_choices);
        var tip_writer: std.Io.Writer = .fixed(&tab.tip_choices);
        tip_writer.writeAll("(o da raiz)") catch {};
        for (design.airfoils[0..design.airfoil_count]) |*candidate| tab.addChoice(candidate, &root_writer, &tip_writer);
        for (design.library[0..design.library_count]) |*candidate| {
            if (design.find(candidate.name) == null) tab.addChoice(candidate, &root_writer, &tip_writer);
        }
        tab.root_choices[root_writer.end] = 0;
        tab.tip_choices[tip_writer.end] = 0;
        tab.field(.root_airfoil).choices = tab.root_choices[0..root_writer.end :0];
        tab.field(.tip_airfoil).choices = tab.tip_choices[0..tip_writer.end :0];
        tab.loadFields();
        const kept_scroll = tab.form.area;
        tab.form = .{ .groups = &tab.groups, .fields = &tab.fields, .area = kept_scroll };
        tab.analyzeSaved();
        tab.run();
    }

    /// o formulário recebe a asa em desenho do projeto
    fn loadFields(tab: *WingTab) void {
        const design = tab.design;
        const wing = design.wing;
        const trapezoid = wing.trapezoid;
        tab.field(.name).setText(design.wing_name.text());
        tab.field(.planform).choice = @intFromBool(wing.table);
        tab.field(.size_by).choice = @intFromBool(trapezoid.size_by_chord);
        tab.field(.root_chord).number = trapezoid.root_chord;
        tab.field(.root_airfoil).choice = @intCast(tab.indexOf(design.rootAirfoil()) orelse 0);
        tab.field(.tip_airfoil).choice = if (tab.indexOf(wing.tip.text())) |k| @intCast(k + 1) else 0;
        tab.field(.span).number = trapezoid.span;
        tab.field(.area).number = trapezoid.area;
        tab.field(.taper).number = trapezoid.taper;
        tab.field(.rect_fraction).number = trapezoid.rect_fraction;
        tab.field(.sweep).number = trapezoid.sweep;
        tab.field(.twist).number = trapezoid.twist;
        tab.field(.dihedral).number = wing.dihedral;
        tab.field(.alpha_cruise).number = trapezoid.alpha_cruise;
    }

    /// o projeto recebe o formulário
    fn storeFields(tab: *WingTab) void {
        const design = tab.design;
        const wing = &design.wing;
        const trapezoid = &wing.trapezoid;
        const name = std.mem.trim(u8, tab.field(.name).textValue(), " ");
        if (name.len > 0) design.wing_name = Name.of(name);
        const was_table = wing.table;
        wing.table = tab.field(.planform).choice == 1;
        trapezoid.size_by_chord = tab.field(.size_by).choice == 1;
        trapezoid.root_chord = tab.field(.root_chord).number;
        trapezoid.span = tab.field(.span).number;
        trapezoid.area = tab.field(.area).number;
        trapezoid.taper = tab.field(.taper).number;
        trapezoid.rect_fraction = tab.field(.rect_fraction).number;
        trapezoid.sweep = tab.field(.sweep).number;
        trapezoid.twist = tab.field(.twist).number;
        trapezoid.alpha_cruise = tab.field(.alpha_cruise).number;
        wing.dihedral = tab.field(.dihedral).number;
        if (tab.candidate_count > 0) {
            const root_index: usize = @intCast(std.math.clamp(tab.field(.root_airfoil).choice, 0, @as(i32, @intCast(tab.candidate_count - 1))));
            const root = tab.candidates[root_index].name;
            if (!std.mem.eql(u8, design.rootAirfoil(), root)) design.setRoot(root);
            const tip_choice = tab.field(.tip_airfoil).choice;
            wing.tip = if (tip_choice > 0 and tip_choice <= tab.candidate_count) Name.of(tab.candidates[@intCast(tip_choice - 1)].name) else .{};
            if (std.mem.eql(u8, wing.tip.text(), root)) wing.tip = .{};
        }
        // a tabela começa do trapézio, na primeira vez que se escolhe a planta "tabela"
        if (wing.table and (!was_table or wing.partition_count == 0) and wing.partition_count == 0) wing.partitionsFromTrapezoid(design.rootAirfoil());
        wing.sync();
        // os campos que saem dos outros (área ou corda; na tabela, envergadura, área e corda) voltam ao formulário
        tab.field(.span).number = trapezoid.span;
        tab.field(.area).number = trapezoid.area;
        tab.field(.root_chord).number = trapezoid.root_chord;
        tab.enableFields();
    }

    /// liga e desliga os campos pela planta e pelo "dimensionar por" (`_mode_changed` da GUI)
    fn enableFields(tab: *WingTab) void {
        const table = tab.design.wing.table;
        for (&tab.fields) |*one| one.enabled = true;
        if (table) {
            for (trapezoid_only) |id| tab.field(id).enabled = false;
        } else {
            const by_chord = tab.field(.size_by).choice == 1;
            tab.field(.root_chord).enabled = by_chord;
            tab.field(.area).enabled = !by_chord;
        }
    }

    fn indexOf(tab: *const WingTab, name: []const u8) ?usize {
        for (tab.candidates[0..tab.candidate_count], 0..) |candidate, k| if (std.mem.eql(u8, candidate.name, name)) return k;
        return null;
    }

    fn addChoice(tab: *WingTab, candidate: *const stage.Candidate, root_writer: *std.Io.Writer, tip_writer: *std.Io.Writer) void {
        if (tab.candidate_count == max_choices) return;
        const separator = if (tab.candidate_count > 0) ";" else "";
        root_writer.print("{s}{s}", .{ separator, candidate.name }) catch return;
        tip_writer.print(";{s}", .{candidate.name}) catch return;
        tab.candidates[tab.candidate_count] = candidate;
        tab.candidate_count += 1;
    }

    /// analisa uma asa (a do rascunho ou uma guardada): monta a planta, os perfis de cada seção e roda a linha
    /// sustentadora; falso se o perfil da raiz não existe mais
    fn analyze(tab: *WingTab, params: *const design_mod.WingParams, root_name: []const u8, out: *Analysis) bool {
        const conditions = tab.design.requirements.conditions(tab.design.rules);
        const table = params.usesTable();
        // na tabela, a raiz é o perfil da primeira partição (se ela tem um), como `sync` da GUI
        const first = if (table and params.partition_count > 0) params.partitions[0].airfoil.text() else "";
        const root_index = tab.indexOf(if (first.len > 0) first else root_name) orelse return false;
        out.used[0] = tab.candidates[root_index];
        out.used_count = 1;
        var sections: [max_used]wing_line.SectionAirfoil = undefined;
        if (table) {
            var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
            for (params.partitions[0..params.partition_count], 0..) |partition, k| {
                partitions[k] = .{ .span = partition.span, .chord = partition.chord, .taper = partition.taper, .offset = partition.offset, .twist = partition.twist, .airfoil = tab.usedIndex(out, partition.airfoil.text()) };
            }
            out.planform = wing_line.planformOfPartitions(partitions[0..params.partition_count]);
        } else {
            const tip_index = if (params.tip.len > 0) tab.indexOf(params.tip.text()) else null;
            if (tip_index) |index| {
                out.used[1] = tab.candidates[index];
                out.used_count = 2;
            }
            out.planform = wing_line.planformOf(params.trapezoid, tip_index != null);
        }
        var pointers: [max_used]*const wing_line.SectionAirfoil = undefined;
        for (out.used[0..out.used_count], 0..) |candidate, k| {
            sections[k] = stage.wingSection(candidate);
            pointers[k] = &sections[k];
        }
        wing_line.analyzePlanform(&out.planform, pointers[0..out.used_count], params.trapezoid.alpha_cruise, conditions, &out.result);
        return true;
    }

    /// o índice do perfil `name` na lista da asa (acrescenta se é novo); vazio ou o da raiz = 0
    fn usedIndex(tab: *const WingTab, analysis: *Analysis, name: []const u8) usize {
        if (name.len == 0) return 0;
        for (analysis.used[0..analysis.used_count], 0..) |candidate, k| if (std.mem.eql(u8, candidate.name, name)) return k;
        const index = tab.indexOf(name) orelse return 0;
        if (analysis.used_count == max_used) return 0;
        analysis.used[analysis.used_count] = tab.candidates[index];
        analysis.used_count += 1;
        return analysis.used_count - 1;
    }

    /// refaz as contas das asas guardadas nas condições de agora (as curvas finas dos gráficos)
    fn analyzeSaved(tab: *WingTab) void {
        const design = tab.design;
        for (design.wings[0..design.wing_count], 0..) |*saved, k| tab.saved_ok[k] = tab.analyze(&saved.wing, saved.root.text(), &tab.saved[k]);
    }

    /// roda a etapa Asa com o que está no formulário e na tabela
    pub fn run(tab: *WingTab) void {
        tab.has_result = false;
        if (tab.candidate_count == 0) {
            tab.setMessage("nenhum perfil: acrescente um em Perfis", .{});
            return;
        }
        tab.storeFields();
        const design = tab.design;
        design.touch();
        tab.seen_version = design.version;
        if (!tab.analyze(&design.wing, design.rootAirfoil(), &tab.draft)) {
            tab.setMessage("o perfil da raiz não está mais na lista", .{});
            return;
        }
        _ = widgets.format(&tab.root_name, "{s}", .{tab.draft.used[0].name});
        tab.has_result = true;
        const r = &tab.draft.result;
        // o que a asa responde nas restrições (S, b, AR, V_S, corda máxima), para o diagnóstico e a janela de
        // requisitos ("calculado")
        var widest: f64 = 0;
        for (tab.draft.planform.sections[0..tab.draft.planform.count]) |station| widest = @max(widest, station.chord);
        design.values[@intFromEnum(registry.Quantity.area)] = r.area;
        design.values[@intFromEnum(registry.Quantity.span)] = r.span;
        design.values[@intFromEnum(registry.Quantity.aspect_ratio)] = r.aspect_ratio;
        design.values[@intFromEnum(registry.Quantity.stall_speed)] = r.stall_speed;
        design.values[@intFromEnum(registry.Quantity.root_chord)] = widest;
        tab.buildShapes();
        tab.buildChecks();
        tab.buildWing();
        tab.setMessage("", .{});
    }

    /// a asa do 3D: um avião só com ela (sem trem, fuselagem nem motor, como `_only_wing` da GUI), com as seções da
    /// planta, o diedro, a incidência e o contorno do perfil de cada seção
    fn buildWing(tab: *WingTab) void {
        if (tab.mesh) |*old| old.deinit();
        tab.mesh = null;
        const analysis = &tab.draft;
        const planform = &analysis.planform;
        for (planform.sections[0..planform.count], 0..) |station, k| {
            const own = analysis.used[station.airfoil];
            const other = k > 0 and station.airfoil != 0;
            tab.sections[k] = .{ .y = station.y, .chord = station.chord, .x_offset = station.offset, .twist = station.twist, .airfoil = if (other) .{ .name = own.name, .coords = own.outline } else null };
        }
        const root = analysis.used[0];
        const surfaces = [_]model.Surface{.{ .name = "asa", .sections = tab.sections[0..planform.count], .dihedral = tab.design.wing.dihedral, .incidence = analysis.result.incidence, .airfoil = .{ .name = root.name, .coords = root.outline } }};
        const plane: model.Aircraft = .{ .name = "prévia", .surfaces = &surfaces, .gear = .{ .layout = "custom" } };
        var diagnosis: assembly.Diagnosis = .{};
        tab.mesh = assembly.buildMesh(std.heap.page_allocator, &plane, &diagnosis) catch null;
    }

    /// as retas de referência dos gráficos
    fn buildShapes(tab: *WingTab) void {
        const r = &tab.draft.result;
        tab.cruise_line = .{ .{ r.lift_cruise, r.lift_cruise }, .{ 0, r.ld_max } };
        tab.onset_x = .{ r.stall_fraction, r.stall_fraction };
        var low: f64 = 0;
        var high: f64 = 0;
        for (0..wing_line.stations) |i| {
            low = @min(low, @min(r.cl_cruise[i], r.cl_stall[i]));
            high = @max(high, @max(r.cl_stall[i], r.cl_max_local[i]));
            tab.max_line[0][i] = r.span_fraction[i];
            tab.max_line[1][i] = r.cl_max_local[i];
        }
        tab.onset_y = .{ low, high };
    }

    fn addCheck(tab: *WingTab, check: checks_mod.Check) void {
        if (tab.check_count == checks_mod.max_checks) return;
        tab.check_list[tab.check_count] = check;
        tab.check_count += 1;
    }

    fn checkText(tab: *WingTab, slot: usize, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&tab.check_text[tab.check_count][slot], fmt, args) catch "";
    }

    /// o diagnóstico, como `wing_stage` da GUI: as restrições ativas da asa, onde o estol começa, cruzeiro perto do
    /// L/D máximo, cruzeiro longe do estol, Re na ponta e o método
    fn buildChecks(tab: *WingTab) void {
        const r = &tab.draft.result;
        const design = tab.design;
        tab.check_count = 0;
        var verdicts: [registry.max_constraints]registry.Verdict = undefined;
        const count = registry.verdicts(&design.constraints, &design.values, .asa, &verdicts);
        for (verdicts[0..count]) |verdict| {
            const constraint = verdict.constraint;
            const info = constraint.quantity.info();
            var number: [32]u8 = undefined;
            var limit: [32]u8 = undefined;
            const value = tab.checkText(0, "{s} {s}", .{ registry.shortNumber(&number, verdict.value), info.unit });
            const criterion = tab.checkText(1, "{s} {s} {s}", .{ constraint.op.symbol(), registry.shortNumber(&limit, constraint.value), info.unit });
            // V de estol: a área que bastaria com este C_L,max
            const fix = if (verdict.holds) "" else if (constraint.quantity == .stall_speed and constraint.op == .at_most)
                tab.checkText(2, "área ≥ {d:.2} m² ou perfil de c_l,max maior", .{r.area * std.math.pow(f64, r.stall_speed / constraint.value, 2)})
            else
                info.fix;
            tab.addCheck(.{ .status = if (verdict.holds) .ok else .falha, .item = tab.checkText(3, "restrição: {s}", .{info.label}), .value = std.mem.trimEnd(u8, value, " "), .criterion = std.mem.trimEnd(u8, criterion, " "), .why = if (verdict.holds) "" else "não cumpre a restrição ativa", .fix = fix, .source = "restrições (Condições e restrições…)" });
        }
        const onset = r.stall_fraction;
        const onset_status: widgets.Status = if (onset <= 0.5) .ok else if (onset <= 0.8) .atencao else .falha;
        tab.addCheck(.{ .status = onset_status, .item = "onde o estol começa", .value = tab.checkText(0, "2y/b = {d:.2}", .{onset}), .criterion = "≤ 0,5 (perto da raiz)", .why = if (onset_status == .ok) "" else "estol na ponta: o aileron perde efeito e a asa tende a cair para um lado", .fix = if (onset_status == .ok) "" else "mais washout (torção negativa na ponta) ou menos afilamento" });
        if (std.math.isFinite(r.ld_cruise) and r.ld_max > 0) {
            const ratio = r.ld_cruise / r.ld_max;
            const good = ratio >= 0.9;
            tab.addCheck(.{ .status = if (good) .ok else .atencao, .item = "cruzeiro perto do L/D máx. da asa", .value = tab.checkText(0, "{d:.0} %", .{100 * ratio}), .criterion = "≥ 90 %", .why = if (good) "" else tab.checkText(1, "o C_L de cruzeiro ({d:.2}) longe do de L/D máx. ({d:.2})", .{ r.lift_cruise, r.lift_at_ld }), .fix = if (good) "" else "mude a área ou a velocidade de cruzeiro" });
        }
        if (r.lift_cruise > 0.85 * r.lift_max) {
            tab.addCheck(.{ .status = .falha, .item = "cruzeiro abaixo do estol", .value = tab.checkText(0, "C_L {d:.2} de {d:.2}", .{ r.lift_cruise, r.lift_max }), .criterion = "≤ 85 %", .why = "a asa cruza quase estolada", .fix = "mais área ou mais velocidade" });
        }
        if (r.reynolds_tip < 8e4) {
            var number: [32]u8 = undefined;
            tab.addCheck(.{ .status = .atencao, .item = "Re na ponta", .value = tab.checkText(0, "{s}", .{numbers.significant(&number, r.reynolds_tip, 3)}), .criterion = "≥ 80 000", .why = "a ponta voa num Re em que o perfil perde c_l,max", .fix = "afilamento menor ou corda maior" });
        }
        tab.addCheck(.{ .status = .info, .item = "método", .value = "linha sustentadora (Glauert)", .criterion = "—", .why = "seção crítica para o estol; c_d da polar 2D no c_l local; sem fuselagem" });
    }

    /// desenha a aba em `rect`
    pub fn draw(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        tab.syncDesign();
        const sidebar_width: f32 = 420;
        tab.drawSidebar(ui, .{ .x = rect.x, .y = rect.y, .width = sidebar_width, .height = rect.height });
        tab.drawRight(ui, .{ .x = rect.x + sidebar_width, .y = rect.y, .width = rect.width - sidebar_width, .height = rect.height });
    }

    /// a barra lateral, como a esquerda do `StagePage`: requisitos, título, rascunho, partições, "Guardar asa" e
    /// "Guardados", tudo numa área que rola
    fn drawSidebar(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const design = tab.design;
        rl.drawRectangleRec(rect, theme.colors.panel);
        rl.drawRectangleRec(.{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, theme.colors.line);
        const body: rl.Rectangle = .{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 1, .height = rect.height - 4 };
        const x = rect.x + 12;
        const width = rect.width - 24 - 10;
        const top = tab.side.begin(ui, body);
        var y = top + 6;
        var summary_buffer: [900]u8 = undefined;
        const summary = design.requirementsSummary(&summary_buffer);
        if (stage_ui.reqBar(ui, x, y, width, summary)) design.requirements_open = true;
        y += stage_ui.reqBarHeight(ui, summary, width) + 8;
        y += stage_ui.title(ui, x, y, "Asa", help);
        var changed = false;
        if (tab.form.fields.len > 0) {
            changed = tab.form.drawAt(ui, rect.x, y, body.width - 10);
            y += tab.form.contentHeight();
        }
        // a tabela de partições, logo abaixo do formulário (só na planta "tabela")
        var table_edit: ?table_mod.Edit = null;
        if (design.wing.table) {
            y = tab.drawPartitions(ui, x, y, width, &table_edit) + 8;
        }
        var caption: [96:0]u8 = undefined;
        if (widgets.primaryButton(ui, .{ .x = x, .y = y, .width = width, .height = 32 }, widgets.format(&caption, "Guardar asa  ({s})", .{design.wing_name.text()}), tab.has_result)) {
            const name = design.wing_name;
            if (design.keepWing(tab.draft.used[0].name)) {
                tab.setMessage("guardado: {s}", .{name.text()});
                tab.analyzeSaved();
            } else tab.setMessage("a lista de asas está cheia", .{});
        }
        y += 44;
        var labels: [design_mod.max_wings][:0]const u8 = undefined;
        var label_text: [design_mod.max_wings][96:0]u8 = undefined;
        for (design.wings[0..design.wing_count], 0..) |*saved, k| labels[k] = widgets.format(&label_text[k], "{s}", .{saved.name.text()});
        if (tab.kept.draw(ui, x, y, width, labels[0..design.wing_count])) |action| {
            const index = tab.kept.selected;
            switch (action) {
                .load => {
                    tab.setMessage("no rascunho: {s}", .{design.wings[index].name.text()});
                    design.loadWing(index);
                },
                .remove => design.removeWing(index),
            }
        }
        y += stage_ui.KeptBox.height + 8;
        theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), x, y, 13, theme.colors.label);
        y += 24;
        tab.side.end(ui, body, y);
        if (tab.form.drawOpen(ui)) changed = true;
        const open_edit = tab.partitions.drawOpen(ui, &partition_columns);
        if (table_edit orelse open_edit) |edit| {
            tab.applyPartition(edit);
            changed = true;
        }
        if (changed) tab.run();
    }

    /// a caixa "Partições (do centro para a ponta)": a tabela, os totais e "+ partição", "− partição", "do trapézio";
    /// devolve onde ela acaba
    fn drawPartitions(tab: *WingTab, ui: *widgets.Ui, x: f32, top: f32, width: f32, edit: *?table_mod.Edit) f32 {
        const wing = &tab.design.wing;
        var y = top + 8;
        const caption = "Partições (do centro para a ponta)";
        const rows = wing.partition_count;
        var totals_text: [160:0]u8 = undefined;
        var partitions: [wing_line.max_partitions]wing_line.Partition = undefined;
        for (wing.partitions[0..rows], 0..) |partition, k| partitions[k] = .{ .span = partition.span, .chord = partition.chord, .taper = partition.taper };
        const sum = wing_line.totals(partitions[0..rows]);
        const totals = widgets.format(&totals_text, "envergadura total: {d:.3} m · área: {d:.4} m² · alongamento: {d:.2}", .{ sum.span, sum.area, if (sum.area > 0) sum.span * sum.span / sum.area else std.math.nan(f64) });
        const totals_height = widgets.paragraphHeight(ui.fonts.regular, totals, width - 16, 13);
        const box_height = 30 + table_mod.height(rows) + totals_height + 50;
        const frame: rl.Rectangle = .{ .x = x, .y = y, .width = width, .height = box_height };
        widgets.roundedLines(frame, 5, theme.colors.line);
        const caption_width = theme.textWidth(ui.fonts.regular, caption, 14);
        rl.drawRectangleRec(.{ .x = x + 8, .y = y - 8, .width = caption_width + 30, .height = 16 }, theme.colors.panel);
        theme.text(ui.fonts.regular, caption, x + 12, y - 8, 14, theme.colors.ink);
        widgets.helpMark(ui, x + 16 + caption_width, y - 8, partitions_help);
        y += 16;
        // as células com os valores de agora
        var cells: [wing_line.max_partitions][partition_columns.len]table_mod.Cell = undefined;
        var row_list: [wing_line.max_partitions][]const table_mod.Cell = undefined;
        for (wing.partitions[0..rows], 0..) |partition, r| {
            const choice: i32 = if (tab.indexOf(partition.airfoil.text())) |k| @intCast(k + 1) else 0;
            cells[r] = .{
                .{ .number = partition.span },
                .{ .number = partition.chord },
                .{ .number = partition.taper },
                .{ .choices = tab.field(.tip_airfoil).choices, .choice = choice },
                .{ .number = partition.offset },
                .{ .number = partition.twist },
            };
            row_list[r] = &cells[r];
        }
        edit.* = tab.partitions.draw(ui, x + 6, y, width - 12, &partition_columns, row_list[0..rows]);
        y += table_mod.height(rows) + 6;
        y += widgets.paragraph(ui.fonts.regular, totals, x + 8, y, width - 16, 13, theme.colors.ink) + 6;
        var pressed: f32 = 0;
        const actions = [_][:0]const u8{ "+ partição", "− partição", "do trapézio" };
        const tips = [_][:0]const u8{ "nova partição depois da selecionada (ou no fim), começando com a corda em que a anterior termina", "apaga a selecionada (fica pelo menos uma)", "refaz a tabela a partir do trapézio atual" };
        const button_width = (width - 12 - 16) / 3;
        for (tips, 0..) |tip, k| ui.tooltip(.{ .x = x + 6 + @as(f32, @floatFromInt(k)) * (button_width + 8), .y = y, .width = button_width, .height = 30 }, tip);
        if (ui_kit.menus.buttonGrid(ui, x + 6, y, width - 12, &actions, 3, &pressed)) |button| {
            const selected = tab.partitions.selected orelse rows -| 1;
            switch (button) {
                0 => if (rows < wing_line.max_partitions and rows > 0) {
                    const after = @min(selected, rows - 1);
                    const previous = wing.partitions[after];
                    var k = rows;
                    while (k > after + 1) : (k -= 1) wing.partitions[k] = wing.partitions[k - 1];
                    wing.partitions[after + 1] = .{ .span = 0.2, .chord = @round(previous.chord * previous.taper * 1e4) / 1e4, .taper = 1, .airfoil = previous.airfoil, .offset = 0, .twist = previous.twist };
                    wing.partition_count += 1;
                    tab.partitions.selected = after + 1;
                },
                1 => if (rows > 1) {
                    const gone = @min(selected, rows - 1);
                    for (gone..rows - 1) |k| wing.partitions[k] = wing.partitions[k + 1];
                    wing.partition_count -= 1;
                },
                else => {
                    const was = wing.table;
                    wing.table = false;
                    wing.partitionsFromTrapezoid(tab.design.rootAirfoil());
                    wing.table = was;
                },
            }
            edit.* = .{ .row = 0, .column = 0, .value = .{ .number = wing.partitions[0].span } }; // refaz a conta
        }
        return top + 8 + box_height;
    }

    /// aplica uma edição da tabela de partições (envergadura, corda e afilamento não ficam negativos)
    fn applyPartition(tab: *WingTab, edit: table_mod.Edit) void {
        const wing = &tab.design.wing;
        if (edit.row >= wing.partition_count) return;
        const partition = &wing.partitions[edit.row];
        switch (edit.value) {
            .number => |typed| {
                const value = if (edit.column <= 2) @max(typed, 0) else typed;
                switch (edit.column) {
                    0 => partition.span = value,
                    1 => partition.chord = value,
                    2 => partition.taper = value,
                    4 => partition.offset = value,
                    5 => partition.twist = value,
                    else => {},
                }
            },
            .choice => |index| partition.airfoil = if (index > 0 and index <= tab.candidate_count) Name.of(tab.candidates[@intCast(index - 1)].name) else .{},
            else => {},
        }
    }

    /// a direita, como a do `StagePage`: a asa em 3D, a mensagem, os gráficos (duas colunas), o diagnóstico e os
    /// resultados, numa área que rola
    fn drawRight(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const gap: f32 = 12;
        const column_width = (rect.width - 3 * gap) / 2;
        const row_height: f32 = 300;
        const view_height: f32 = 300;
        const checks_height = checks_mod.ChecksPanel.height(tab.check_count);
        const summary_height: f32 = plot.tableHeight(summary_rows);
        const content_height = view_height + gap + 2 * (row_height + gap) + checks_height + gap + summary_height + 2 * gap;
        const x0 = rect.x + gap;
        const x1 = x0 + column_width + gap;
        tab.plots.content_height = content_height;
        if (tab.scroll > 0) { // a rolagem pedida na linha de comando (prints)
            tab.plots.offset = tab.scroll;
            tab.scroll = 0;
        }
        tab.plots.offset = std.math.clamp(tab.plots.offset, 0, @max(0, content_height - rect.height));
        // a asa em 3D primeiro; a imagem sai numa textura, feita antes do recorte da coluna
        const view_card: rl.Rectangle = .{ .x = x0, .y = rect.y + gap - tab.plots.offset, .width = rect.width - 2 * gap, .height = view_height };
        const view_area = cardInside(view_card);
        if (tab.mesh) |*wing| {
            tab.view.handleInput(ui, view_area);
            const size = wing.size();
            const middle = wing.center();
            tab.view.label_count = 0;
            if (tab.view.begin(view_area, middle, 0.8 * size)) {
                defer tab.view.end();
                view3d.floor(.{ middle[0], middle[1], 0 }, wing.high[2] + 0.05 * size, 1.4 * size, 0.25);
                wing.draw();
                // o ponto neutro da asa (o centro aerodinâmico), como o marcador `np_x` da GUI
                const neutral: view3d.Body = .{ -tab.draft.result.aero_center, 0, wing.low[2] - 0.04 * size };
                const marker = theme.hex(0xd62728);
                view3d.segment(.{ neutral[0], neutral[1], wing.low[2] - 0.12 * size }, .{ neutral[0], neutral[1], wing.high[2] + 0.04 * size }, marker);
                view3d.segment(.{ neutral[0] - 0.03 * size, 0, neutral[2] }, .{ neutral[0] + 0.03 * size, 0, neutral[2] }, marker);
                view3d.segment(.{ neutral[0], -0.03 * size, neutral[2] }, .{ neutral[0], 0.03 * size, neutral[2] }, marker);
                tab.view.label(.{ neutral[0], neutral[1], wing.low[2] - 0.12 * size }, "PN", marker);
                view3d.bodyAxes(&tab.view, .{ wing.low[0] - 0.25 * size, wing.low[1], wing.high[2] }, 0.1 * size);
            }
        }
        const top = tab.plots.begin(ui, rect);
        defer tab.plots.end(ui, rect, top + content_height);
        if (!tab.has_result) {
            theme.text(ui.fonts.regular, std.mem.sliceTo(&tab.message, 0), rect.x + 40, rect.y + 40, 16, theme.colors.failure);
            return;
        }
        const r = &tab.draft.result;
        const n = r.alpha_count;
        var title_buffer: [200]u8 = undefined;
        const planform = &tab.draft.planform;
        _ = widgets.card(ui, view_card, widgets.format(&title_buffer, "A asa: envergadura {d:.2} m · corda da raiz {d:.3} m · ponta {d:.3} m · PN = ponto neutro (arraste para girar, roda para aproximar)", .{ 2 * planform.semispan, planform.root_chord, planform.tip_chord }));
        if (tab.mesh != null) tab.view.blit(ui, view_area);
        var y = top + gap + view_height + gap;
        // a asa em desenho, grossa, e as guardadas (menos a de mesmo nome), pontilhadas, para comparar
        var name_buffer: [Name.capacity + 1:0]u8 = undefined;
        const name = widgets.format(&name_buffer, "{s}", .{tab.design.wing_name.text()});
        var lift_series: [1 + design_mod.max_wings]plot.Series = undefined;
        var ld_series: [2 + design_mod.max_wings]plot.Series = undefined;
        var saved_names: [design_mod.max_wings][Name.capacity + 1:0]u8 = undefined;
        lift_series[0] = .{ .name = name, .xs = r.alpha[0..n], .ys = r.lift[0..n], .color_index = 0 };
        ld_series[0] = .{ .name = name, .xs = r.lift[0..n], .ys = r.ld[0..n], .color_index = 0 };
        ld_series[1] = .{ .name = "C_L de cruzeiro", .xs = &tab.cruise_line[0], .ys = &tab.cruise_line[1], .color_index = 7, .dashed = true };
        var compared: usize = 0;
        for (tab.design.wings[0..tab.design.wing_count], 0..) |*saved, k| {
            if (!tab.saved_ok[k] or std.mem.eql(u8, saved.name.text(), tab.design.wing_name.text())) continue;
            const other = &tab.saved[k].result;
            const count = other.alpha_count;
            const label = widgets.format(&saved_names[compared], "{s}", .{saved.name.text()});
            lift_series[1 + compared] = .{ .name = label, .xs = other.alpha[0..count], .ys = other.lift[0..count], .color_index = 3 + compared, .dashed = true };
            ld_series[2 + compared] = .{ .name = label, .xs = other.lift[0..count], .ys = other.ld[0..count], .color_index = 3 + compared, .dashed = true };
            compared += 1;
        }
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "C_L × α da asa (até o estol)", .x_label = "α da raiz (°)", .y_label = "C_L" }, lift_series[0 .. 1 + compared]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "Polar da asa: induzido, perfil e total", .x_label = "C_D", .y_label = "C_L" }, &.{
            .{ .name = "total", .xs = r.drag[0..n], .ys = r.lift[0..n], .color_index = 0 },
            .{ .name = "induzido", .xs = r.induced[0..n], .ys = r.lift[0..n], .color_index = 1, .dashed = true },
            .{ .name = "perfil", .xs = r.profile[0..n], .ys = r.lift[0..n], .color_index = 2, .dashed = true },
        });
        y += row_height + gap;
        plot.lines(ui, .{ .x = x0, .y = y, .width = column_width, .height = row_height }, .{ .title = "L/D × C_L (tracejado: cruzeiro)", .x_label = "C_L", .y_label = "L/D" }, ld_series[0 .. 2 + compared]);
        plot.lines(ui, .{ .x = x1, .y = y, .width = column_width, .height = row_height }, .{ .title = "c_l na envergadura: onde o estol começa", .x_label = "posição na semiasa (2y/b)", .y_label = "c_l" }, &.{
            .{ .name = "c_l no cruzeiro", .xs = &r.span_fraction, .ys = &r.cl_cruise, .color_index = 0 },
            .{ .name = "c_l no estol", .xs = &r.span_fraction, .ys = &r.cl_stall, .color_index = 1 },
            .{ .name = "c_l,max do perfil", .xs = &tab.max_line[0], .ys = &tab.max_line[1], .color_index = 1, .dashed = true },
            .{ .name = "onde começa", .xs = &tab.onset_x, .ys = &tab.onset_y, .color_index = 3, .dashed = true },
        });
        y += row_height + gap;
        tab.checks.draw(ui, .{ .x = x0, .y = y, .width = rect.width - 2 * gap, .height = checks_height }, tab.check_list[0..tab.check_count]);
        y += checks_height + gap;
        tab.drawSummary(ui, .{ .x = x0, .y = y, .width = rect.width - 2 * gap, .height = summary_height });
    }

    /// os resultados da asa, as mesmas linhas de `wing_stage` da GUI (grandeza e valor; listas separadas por vírgula)
    fn drawSummary(tab: *WingTab, ui: *widgets.Ui, rect: rl.Rectangle) void {
        const r = &tab.draft.result;
        const planform = &tab.draft.planform;
        var texts: [summary_rows][2][160:0]u8 = undefined;
        var cells: [summary_rows][2]plot.Cell = undefined;
        var rows: [summary_rows][]const plot.Cell = undefined;
        const Row = struct { name: []const u8, values: []const f64 = &.{}, text: ?[]const u8 = null };
        var reynolds: [32]u8 = undefined;
        var source: [96]u8 = undefined;
        const items = [summary_rows]Row{
            .{ .name = "b, S, AR", .values = &.{ r.span, r.area, r.aspect_ratio } },
            .{ .name = "corda da raiz, da ponta, CMA (m)", .values = &.{ planform.root_chord, planform.tip_chord, r.mean_chord } },
            .{ .name = "perfil (polar por)", .text = std.fmt.bufPrint(&source, "{s} ({s}, Re {s})", .{ tab.draft.used[0].name, @tagName(tab.draft.used[0].source), numbers.significant(&reynolds, r.reynolds, 3) }) catch "" },
            .{ .name = "C_Lα (1/rad), C_L0, α_L0 (°)", .values = &.{ r.lift_slope, r.lift_zero, r.alpha_zero } },
            .{ .name = "C_L,max, α de estol (°)", .values = &.{ r.lift_max, r.alpha_stall } },
            .{ .name = "estol começa em (2y/b)", .values = &.{r.stall_fraction} },
            .{ .name = "Oswald e (no cruzeiro)", .values = &.{r.oswald} },
            .{ .name = "(L/D) máx., C_L nele", .values = &.{ r.ld_max, r.lift_at_ld } },
            .{ .name = "cruzeiro: C_L, α da asa (°), L/D", .values = &.{ r.lift_cruise, r.alpha_cruise, r.ld_cruise } },
            .{ .name = "incidência da asa (°)", .values = &.{r.incidence} },
            .{ .name = "V de estol (massa estimada)", .values = &.{r.stall_speed} },
            .{ .name = "carga alar (kg/m²)", .values = &.{r.wing_loading} },
            .{ .name = "massa estimada da asa (kg)", .values = &.{r.wing_mass} },
            .{ .name = "Re na raiz, na ponta", .values = &.{ r.reynolds_root, r.reynolds_tip } },
        };
        for (items, 0..) |item, k| {
            var value_text: []const u8 = undefined;
            var joined: [160]u8 = undefined;
            if (item.text) |text| value_text = text else {
                var writer: std.Io.Writer = .fixed(&joined);
                for (item.values, 0..) |value, i| {
                    var number: [32]u8 = undefined;
                    writer.print("{s}{s}", .{ if (i > 0) ", " else "", numbers.significant(&number, value, 4) }) catch {};
                }
                value_text = writer.buffered();
            }
            cells[k] = .{
                .{ .text = widgets.format(&texts[k][0], "{s}", .{item.name}) },
                .{ .text = widgets.format(&texts[k][1], "{s}", .{value_text}), .value = if (item.values.len == 1) item.values[0] else null },
            };
            rows[k] = &cells[k];
        }
        plot.table(ui, rect, "Resultados", &.{ "grandeza", "valor" }, &rows, &.{0.5});
    }
};

/// a parte de dentro de um cartão onde vai a imagem 3D (abaixo do título)
fn cardInside(rect: rl.Rectangle) rl.Rectangle {
    return .{ .x = rect.x + 4, .y = rect.y + 34, .width = rect.width - 8, .height = rect.height - 40 };
}

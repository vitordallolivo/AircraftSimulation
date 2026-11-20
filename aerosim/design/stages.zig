//! As etapas da sprint em Zig (o par de `aerosim/manager/stages.py`): cada etapa mexe no projeto (`store.Project`) e
//! devolve a página inteira (formulário, guardados, botões, tabelas editáveis e a conta) no mesmo formato da ponte
//! do Python, então a tela desenha igual. A tela chama `handle` com o pedido; uma etapa que ainda não está aqui
//! segue pelo Python (`find` devolve nulo).
//!
//!     requisitos   "Condições e restrições"        condições, regras, restrições e variáveis do projeto
//!     perfis       Aerodinâmica → Perfis           candidatos e a polar 2D de cada um
//!
//! O programa abre com um projeto vazio, numa pasta nova (`$AEROSIM_PROJETOS/projetos/projeto_<data>`, senão
//! `~/aerosim_aeronaves/projetos/...`), criada só na primeira mudança; o que se muda é gravado na hora. Um projeto
//! que já existe (o `sprint.json` de uma pasta, como a do Python em `~/aerosim_aeronaves/sprint`) abre por
//! `openProject`.
const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const project_aircraft = @import("project_aircraft.zig");
const airfoil_stage = @import("stage_airfoils.zig");
const wing_stage = @import("stage_wing.zig");
const requirements_stage = @import("stage_requirements.zig");
const tail_stage = @import("stage_tail.zig");
const power_stage = @import("stage_power.zig");
const study_stage = @import("stage_study.zig");
const library_stage = @import("stage_library.zig");

const aircraft_model = @import("aircraft_model");
const zon_json = @import("aerosim").zon_json;
const aero_file = aircraft_model.aero_file;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// o que as etapas dividem: o projeto aberto, onde ele grava e a `Io` dos arquivos
pub const Context = struct {
    project: store.Project,
    io: std.Io,
    /// o perfil selecionado na etapa Perfis
    selected_airfoil: usize = 0,
    /// o valor de cada grandeza das restrições (`registry.quantities`) na última etapa que a calculou (a asa ou o
    /// avião montado); NaN: nenhuma ainda. A coluna "calculado" das restrições mostra
    computed: [registry.quantities.len]f64 = [_]f64{std.math.nan(f64)} ** registry.quantities.len,
    /// os estados anteriores do projeto (o JSON inteiro), para o Ctrl+Z ("undo"); o último é o mais recente
    history: std.ArrayList([]u8) = .empty,
    /// o dispositivo de ponta (a linha da tabela de Projetar) que se está editando: a vista 3D aproxima dele
    focus_device: ?usize = null,
    /// o comando (a linha da tabela de Empenagem e comandos) que se está editando: a vista 3D aproxima dele
    focus_command: ?usize = null,
    /// a linha que se clicou numa tabela (o pedido "select"), até a etapa dela usar
    selected_grid: [32]u8 = undefined,
    selected_grid_len: usize = 0,
    selected_row: ?usize = null,
    /// os perfis da biblioteca (`data/airfoils`), lidos uma vez, como candidatos do projeto
    library: ?[]const Value = null,
    /// o projeto tem pasta escolhida (aberto ou criado por "Novo projeto…"); sem ela, nada é gravado e a tela pede a
    /// pasta antes de guardar
    named: bool = true,
    /// o arquivo aberto tem projeto: as etapas gravam nele e remontam o avião; falso (um avião aberto sem projeto,
    /// ou o começo sem nada): o que se mexe nas etapas fica na memória e o avião aberto não é tocado
    has_project: bool = true,

    /// guarda `before` (o projeto antes de um pedido que o mudou) para o Ctrl+Z
    fn remember(context: *Context, before: []u8) void {
        const gpa = std.heap.page_allocator;
        if (context.history.items.len >= undo_capacity) gpa.free(context.history.orderedRemove(0));
        context.history.append(gpa, before) catch gpa.free(before);
    }

    /// volta o projeto ao estado de antes do último pedido que o mudou; falso: nada para desfazer
    fn undo(context: *Context) !bool {
        const previous = context.history.pop() orelse return false;
        defer std.heap.page_allocator.free(previous);
        const memory = context.project.memory();
        context.project.root = try std.json.parseFromSliceLeaky(Value, memory, previous, .{ .allocate = .alloc_always });
        try context.project.reserve();
        context.focus_device = null;
        _ = context.save();
        return true;
    }

    /// a linha clicada na tabela `grid`, se foi nela; a escolha é usada uma vez
    /// guarda o valor que uma etapa calculou para a grandeza `key` das restrições
    pub fn rememberValue(context: *Context, key: []const u8, value: f64) void {
        for (registry.quantities, 0..) |item, i| if (std.mem.eql(u8, item.key, key)) {
            context.computed[i] = value;
        };
    }

    /// o último valor calculado da grandeza `key`, ou null
    pub fn lastComputed(context: *const Context, key: []const u8) ?f64 {
        for (registry.quantities, 0..) |item, i| if (std.mem.eql(u8, item.key, key)) {
            return if (std.math.isFinite(context.computed[i])) context.computed[i] else null;
        };
        return null;
    }

    pub fn takeSelection(context: *Context, grid: []const u8) ?usize {
        const row = context.selected_row orelse return null;
        if (!std.mem.eql(u8, context.selected_grid[0..context.selected_grid_len], grid)) return null;
        context.selected_row = null;
        return row;
    }

    /// grava o projeto (uma falha de gravação não derruba a etapa: a mensagem avisa)
    pub fn save(context: *Context) bool {
        if (!context.named or !context.has_project) return true; // ainda sem pasta ou sem projeto: fica na memória
        if (context.project.document.len > 0) return saveDocument(context);
        context.project.save(context.io) catch return false;
        return true;
    }

    /// o projeto vai para a parte `projeto.zon` do `.aero` aberto; o avião e as outras partes ficam
    fn saveDocument(context: *Context) bool {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const memory = scratch.allocator();
        const part: aero_file.Part = .{ .name = aero_file.project_part, .data = zon_json.toZon(memory, context.project.root) catch return false };
        return writeIntoDocument(context, memory, null, part);
    }
};

/// regrava o `.aero` do projeto com o avião `json` (nulo: o do arquivo) e a parte do projeto
pub fn writeIntoDocument(context: *Context, memory: std.mem.Allocator, json: ?[]const u8, part: aero_file.Part) bool {
    const path = context.project.document;
    const now = aero_file.isoNow(memory, context.io) catch return false;
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(context.io, path, memory, .limited(1 << 26)) catch return false;
    const written = aero_file.rewrite(memory, bytes, json, &.{part}, "aerosim", now, &diagnosis) catch return false;
    const temporary = std.fmt.allocPrint(memory, "{s}.tmp", .{path}) catch return false;
    std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = temporary, .data = written }) catch return false;
    std.Io.Dir.rename(std.Io.Dir.cwd(), temporary, std.Io.Dir.cwd(), path, context.io) catch return false;
    return true;
}

/// a parte do projeto em ZON, para gravar junto com o avião ("Salvar"); nula: o arquivo aberto não tem projeto
pub fn projectPart(memory: std.mem.Allocator) ?aero_file.Part {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return null;
    if (!current.has_project or !current.named) return null;
    return .{ .name = aero_file.project_part, .data = zon_json.toZon(memory, current.project.root) catch return null };
}

/// o projeto montado a partir do `.aero` em `path`: a parte `projeto.zon` dele, ou vazio (e `has_project` falso)
fn documentContext(io: std.Io, path: []const u8) !Context {
    const gpa = std.heap.page_allocator;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    var project = try store.empty(gpa, stem);
    errdefer project.deinit();
    project.document = try project.memory().dupe(u8, path);
    var found = false;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, scratch.allocator(), .limited(1 << 26))) |bytes| {
        var diagnosis: aircraft_model.aircraft.Diag = .{};
        if (aero_file.readDocument(scratch.allocator(), bytes, &diagnosis)) |document| {
            for (document.parts) |item| if (std.mem.eql(u8, item.name, aero_file.project_part)) {
                const root = try zon_json.read(project.memory(), try project.memory().dupe(u8, item.data));
                if (root == .object) {
                    project.root = root;
                    try project.reserve();
                    found = true;
                }
            };
        } else |_| {}
    } else |_| {}
    return .{ .project = project, .io = io, .has_project = found };
}

/// abre o `.aero` em `path` no lugar de tudo: o projeto dele (se tiver) passa a ser o das etapas, e ele é o arquivo
/// que o programa abre da próxima vez
pub fn openDocument(io: std.Io, path: []const u8) !void {
    const context = try documentContext(io, path);
    rememberProject(io, path);
    useContext(context);
}

/// um avião aberto sem projeto (um `.json`, `.cfg` ou planilha antigos, ou "Novo"): as etapas ficam vazias e não
/// tocam no avião
pub fn closeProject(io: std.Io) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const project = try store.empty(std.heap.page_allocator, try newFolder(scratch.allocator(), io));
    useContext(.{ .project = project, .io = io, .named = false, .has_project = false });
}

/// "Salvar" gravou o avião em `path` (com o projeto, se havia): o projeto passa a morar nesse arquivo
pub fn adoptDocument(io: std.Io, path: []const u8) void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return;
    const memory = current.project.memory();
    current.project.document = memory.dupe(u8, path) catch return;
    current.project.folder = memory.dupe(u8, path[0 .. path.len - std.fs.path.extension(path).len]) catch return;
    if (current.has_project) current.named = true;
    rememberProject(io, path);
}

/// um pedido da tela a uma etapa (`do`: show, set, keep, load, delete, act, grid)
pub const Request = struct {
    do: []const u8 = "show",
    values: ?*const ObjectMap = null,
    index: i64 = -1,
    key: []const u8 = "",
    arg: []const u8 = "",
    grid: []const u8 = "",
    edit: []const u8 = "set",
    row: i64 = -1,
    value: Value = .null,
};

/// uma etapa: o que ela responde a cada pedido. `page` monta a página depois do pedido; o resto muda o projeto e
/// devolve a mensagem para a tela
pub const Stage = struct {
    name: []const u8,
    apply: *const fn (context: *Context, memory: std.mem.Allocator, request: Request) anyerror![]const u8,
    page: *const fn (context: *Context, memory: std.mem.Allocator) anyerror!simulation.StagePage,
    /// a etapa é do programa, não do projeto (a biblioteca): guardar não pede a pasta do projeto
    program: bool = false,
};

/// as etapas que já estão em Zig
pub const all = [_]Stage{
    .{ .name = "requisitos", .apply = requirements_stage.apply, .page = requirements_stage.page },
    .{ .name = "perfis", .apply = airfoil_stage.apply, .page = airfoil_stage.page },
    .{ .name = "asa", .apply = wing_stage.apply, .page = wing_stage.page },
    .{ .name = "empenagem", .apply = tail_stage.apply, .page = tail_stage.page },
    .{ .name = "motores", .apply = power_stage.apply, .page = power_stage.page },
    .{ .name = "estudo", .apply = study_stage.apply, .page = study_stage.page },
    .{ .name = "biblioteca_motores", .apply = library_stage.applyMotors, .page = library_stage.motorPage, .program = true },
    .{ .name = "biblioteca_helices", .apply = library_stage.applyPropellers, .page = library_stage.propellerPage, .program = true },
};

/// a etapa em Zig com este nome (nulo: ela segue pelo Python)
pub fn find(name: []const u8) ?*const Stage {
    for (&all) |*stage| if (std.mem.eql(u8, stage.name, name)) return stage;
    return null;
}

/// quantos pedidos dá para desfazer em cada projeto
const undo_capacity = 64;

var shared: ?Context = null;
var lock: std.atomic.Mutex = .unlocked;

/// a pasta dos projetos (a do Python: `default_root()`)
pub fn projectsRoot(memory: std.mem.Allocator) ![]const u8 {
    if (builtin.link_libc) {
        if (std.c.getenv("AEROSIM_PROJETOS")) |root| return memory.dupe(u8, std.mem.span(root));
        if (std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE")) |home| return std.fs.path.join(memory, &.{ std.mem.span(home), "aerosim_aeronaves" });
    }
    return memory.dupe(u8, "aerosim_aeronaves");
}

/// a pasta de um projeto novo: `projetos/projeto_AAAA-MM-DD_HHMMSS` (UTC), para nunca gravar por cima de outro
fn newFolder(memory: std.mem.Allocator, io: std.Io) ![]const u8 {
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const seconds: u64 = @intCast(@max(@divFloor(now, std.time.ns_per_s), 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    const name = try std.fmt.allocPrint(memory, "projeto_{d}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
    return std.fs.path.join(memory, &.{ try projectsRoot(memory), "projetos", name });
}

/// o contexto aberto: o projeto aberto por `openProject` ou, no começo, um vazio (nada guardado, nenhuma asa nem
/// conjunto) que grava numa pasta nova
fn opened(io: std.Io) !*Context {
    if (shared) |*existing| return existing;
    const gpa = std.heap.page_allocator;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    // volta ao último projeto, de onde parou; senão, um vazio sem pasta
    if (try lastProject(scratch.allocator(), io)) |path| {
        if (std.mem.endsWith(u8, path, aero_file.extension)) {
            if (documentContext(io, path)) |context| {
                shared = context;
                return &shared.?;
            } else |_| {}
        } else if (store.open(gpa, io, path)) |project| {
            shared = .{ .project = project, .io = io };
            return &shared.?;
        } else |_| {}
    }
    shared = .{ .project = try store.empty(gpa, try newFolder(scratch.allocator(), io)), .io = io, .named = false, .has_project = false };
    return &shared.?;
}

/// o arquivo que guarda a pasta do último projeto aberto ou criado
fn lastProjectFile(memory: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(memory, &.{ try projectsRoot(memory), "ultimo_projeto.txt" });
}

/// a pasta do último projeto, se ela ainda tem o projeto
fn lastProject(memory: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, try lastProjectFile(memory), memory, .limited(4096)) catch return null;
    const path = std.mem.trim(u8, bytes, " \r\n");
    if (path.len == 0) return null;
    if (std.mem.endsWith(u8, path, aero_file.extension)) {
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return path else |_| return null;
    }
    for ([_][]const u8{ store.main_name, store.legacy_name }) |name| {
        const file = try std.fs.path.join(memory, &.{ path, name });
        if (std.Io.Dir.cwd().access(io, file, .{})) |_| return path else |_| {}
    }
    return null;
}

/// lembra a pasta do projeto para a próxima vez
fn rememberProject(io: std.Io, folder: []const u8) void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const memory = scratch.allocator();
    const file = lastProjectFile(memory) catch return;
    if (std.fs.path.dirname(file)) |parent| std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = folder }) catch {};
}

/// "Novo projeto…" / a pasta pedida antes de guardar: o projeto de agora passa a gravar em `folder`, que vira o
/// projeto da próxima vez
fn nameProject(context: *Context, folder: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, folder, " ");
    if (trimmed.len == 0) return "nenhuma pasta escolhida";
    context.project.folder = try context.project.memory().dupe(u8, trimmed);
    context.project.document = "";
    context.named = true;
    context.has_project = true;
    context.project.save(context.io) catch return "não deu para gravar nessa pasta";
    rememberProject(context.io, context.project.folder);
    return "projeto gravado nesta pasta; ao abrir de novo, ele volta daqui";
}

/// abre o projeto em `path` (a pasta, o `sprint.json` dela ou um `.json` antigo) no lugar do aberto; o Ctrl+Z
/// começa do zero
pub fn openProject(io: std.Io, path: []const u8) !void {
    const project = try store.open(std.heap.page_allocator, io, path);
    rememberProject(io, project.folder);
    use(project, io);
}

/// o `.json` em `bytes` é um projeto da sprint (e não um avião): o `sprint.json` novo, um arquivo de asa dele ou
/// o `.json` antigo de um arquivo só, com os requisitos e as asas guardadas
pub fn isProject(bytes: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(Value, arena.allocator(), bytes, .{}) catch return false;
    if (parsed != .object) return false;
    const format = store.text(&parsed.object, "format", "");
    if (std.mem.startsWith(u8, format, "aerosim-sprint")) return true;
    return parsed.object.get("requirements") != null and parsed.object.get("wings") != null;
}

// ------------------------------------------------------------------ o projeto para as análises
/// o que as análises leem do projeto aberto (`simulation.sprint`): a tela liga ao abrir
pub const sprint_source: simulation.Sprint = .{ .wing_names = sprintWingNames, .wing = sprintWing, .config_names = sprintConfigNames, .config = sprintConfig, .project_name = sprintProjectName, .variables = sprintVariables, .airfoil = sprintAirfoil, .field_text = sprintFieldText, .constraints = sprintConstraints, .conditions = sprintConditions, .cg_list = sprintCgList };

fn sprintCgList(memory: std.mem.Allocator) simulation.Error![]const f64 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return &.{};
    return tail_stage.projectCgList(current, memory) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

fn sprintConfigNames(memory: std.mem.Allocator) simulation.Error![]const []const u8 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (current.project.list("configs").items) |item| {
        if (item != .object) continue;
        const name = store.text(&item.object, "name", "");
        if (name.len > 0) try names.append(memory, try memory.dupe(u8, name));
    }
    return names.items;
}

fn sprintConfig(memory: std.mem.Allocator, name: []const u8) simulation.Error![]const simulation.Surface {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return &.{};
    return wing_stage.configSurfaces(current, memory, name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

fn sprintVariables(memory: std.mem.Allocator) simulation.Error![]const simulation.SprintVariable {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return &.{};
    const project = &current.project;
    var out: std.ArrayList(simulation.SprintVariable) = .empty;
    for ((try registry.variableList(project)).items) |item| {
        if (item != .object) continue;
        const object = &item.object;
        const input = registry.input(store.text(object, "key", "")) orelse continue;
        const place = registry.inputPlace(input);
        const section = project.section(place[0]);
        var options: std.ArrayList([]const u8) = .empty;
        if (object.get("options")) |list| if (list == .array) for (list.array.items) |option| {
            if (option == .string) try options.append(memory, try memory.dupe(u8, option.string));
        };
        try out.append(memory, .{
            .key = try memory.dupe(u8, input.key),
            .mode = try memory.dupe(u8, store.text(object, "mode", "fixo")),
            .lo = store.number(object, "lo", input.lo),
            .hi = store.number(object, "hi", input.hi),
            .number = store.number(section, place[1], std.math.nan(f64)),
            .text = try memory.dupe(u8, store.text(section, place[1], "")),
            .options = options.items,
        });
    }
    return out.items;
}

fn sprintAirfoil(memory: std.mem.Allocator, name: []const u8) simulation.Error!?simulation.Airfoil {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return null;
    const entry = airfoil_stage.lookup(current, name) orelse return null;
    return airfoil_stage.stageAirfoil(current, memory, entry) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

fn sprintFieldText(memory: std.mem.Allocator, path: []const u8) simulation.Error![]const u8 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return "";
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return "";
    return memory.dupe(u8, store.text(current.project.section(path[0..dot]), path[dot + 1 ..], ""));
}

fn sprintProjectName(memory: std.mem.Allocator) simulation.Error![]const u8 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return "";
    if (!current.named or !current.has_project) return "";
    return memory.dupe(u8, std.fs.path.basename(current.project.folder));
}

/// o nome do projeto aberto (a pasta); vazio se ele ainda não tem nome
pub fn projectName(memory: std.mem.Allocator) []const u8 {
    return sprintProjectName(memory) catch "";
}

/// liga o projeto aberto às análises (o Analisar lista as asas guardadas; o Mini-MDO usa as restrições)
pub fn connect(io: std.Io) void {
    simulation.sprint = sprint_source;
    // os motores e as hélices da biblioteca do usuário entram no catálogo
    library_stage.reload(io);
    // o projeto abre já (o último, de onde parou): o Analisar e o Mini-MDO leem ele antes de qualquer etapa
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    _ = opened(io) catch {};
}

/// o avião do projeto aberto (montado e gravado se mudou); nulo: o projeto ainda não tem avião
pub fn projectAircraft(io: std.Io, memory: std.mem.Allocator) ?[]const u8 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = opened(io) catch return null;
    // o `.aero` aberto da última vez: o avião é ele (com o projeto dentro, remontado se mudou)
    if (current.project.document.len > 0) {
        return (project_aircraft.sync(current, memory) catch null) orelse (memory.dupe(u8, current.project.document) catch null);
    }
    if (!current.has_project) return null;
    if ((project_aircraft.build(current, memory) catch null) == null) return null;
    return (project_aircraft.sync(current, memory) catch null) orelse (project_aircraft.path(current, memory) catch null);
}

fn sprintWingNames(memory: std.mem.Allocator) simulation.Error![]const []const u8 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (current.project.list("wings").items) |item| {
        const name = store.nameOf(item);
        if (name.len > 0) try names.append(memory, try memory.dupe(u8, name));
    }
    return names.items;
}

fn sprintWing(memory: std.mem.Allocator, name: []const u8) simulation.Error!?simulation.Surface {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return null;
    const params = wing_stage.keptWing(&current.project, name) orelse return null;
    return wing_stage.surfaceOf(current, memory, params, try memory.dupe(u8, name), 0) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

fn sprintConstraints(memory: std.mem.Allocator) simulation.Error![]const simulation.SprintConstraint {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    var out: std.ArrayList(simulation.SprintConstraint) = .empty;
    const add = struct {
        fn one(list: *std.ArrayList(simulation.SprintConstraint), gpa: std.mem.Allocator, constraint: registry.Constraint) !void {
            if (!constraint.active) return;
            const info = registry.quantity(constraint.key);
            try list.append(gpa, .{ .key = try gpa.dupe(u8, constraint.key), .label = info.label, .unit = info.unit, .op = try gpa.dupe(u8, constraint.op), .value = constraint.value, .tol = constraint.tol });
        }
    }.one;
    if (shared) |*current| {
        for ((try registry.constraintList(&current.project)).items) |item| try add(&out, memory, registry.readConstraint(item));
    } else for (registry.default_constraints) |constraint| try add(&out, memory, constraint);
    return out.items;
}

fn sprintConditions() simulation.SprintConditions {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = if (shared) |*existing| existing else return .{};
    const requirements = current.project.section("requirements");
    const rules = current.project.section("rules");
    const fields = &registry.requirement_fields;
    const rule_fields = &registry.rule_fields;
    return .{
        .wing_density = registry.fieldNumber(rules, rule_fields, "wing_density"),
        .tail_density = registry.fieldNumber(rules, rule_fields, "tail_density"),
        .fuselage_density = registry.fieldNumber(rules, rule_fields, "fuselage_density"),
        .systems_mass = registry.fieldNumber(rules, rule_fields, "systems_mass"),
        .gear_mass = registry.fieldNumber(rules, rule_fields, "gear_mass"),
        .density_altitude = registry.fieldNumber(requirements, fields, "density_altitude"),
        .mu_roll = registry.fieldNumber(requirements, fields, "mu_roll"),
        .V_turn = registry.fieldNumber(requirements, fields, "V_turn"),
        .mu_brake = registry.fieldNumber(requirements, fields, "mu_brake"),
        .V_cruise = registry.fieldNumber(requirements, fields, "V_cruise"),
    };
}

/// troca o projeto (abrir outra pasta; os testes usam um projeto da pasta `data`)
pub fn use(project: store.Project, io: std.Io) void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    if (shared) |*existing| {
        existing.project.deinit();
        for (existing.history.items) |state| std.heap.page_allocator.free(state);
        existing.history.deinit(std.heap.page_allocator);
    }
    shared = .{ .project = project, .io = io };
}

/// troca o contexto inteiro (o projeto e o que se sabe dele); o Ctrl+Z começa do zero
fn useContext(context: Context) void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    if (shared) |*existing| {
        existing.project.deinit();
        for (existing.history.items) |state| std.heap.page_allocator.free(state);
        existing.history.deinit(std.heap.page_allocator);
    }
    shared = context;
}

/// atende o pedido (`fields`: o JSON do pedido sem as chaves, como a tela manda à ponte) e devolve a página em JSON,
/// já lida, na memória `memory`
pub fn handle(memory: std.mem.Allocator, io: std.Io, fields: []const u8) !Value {
    const text = try std.fmt.allocPrint(memory, "{{{s}}}", .{fields});
    const parsed = try std.json.parseFromSliceLeaky(Value, memory, text, .{});
    if (parsed != .object) return error.BadRequest;
    const object = &parsed.object;
    const name = store.text(object, "name", "");
    const stage = find(name) orelse return error.UnknownStage;
    var request: Request = .{ .do = store.text(object, "do", "show"), .key = store.text(object, "key", ""), .arg = store.text(object, "arg", ""), .grid = store.text(object, "grid", ""), .edit = store.text(object, "edit", "set"), .index = @intFromFloat(store.number(object, "index", -1)), .row = @intFromFloat(store.number(object, "row", -1)), .value = object.get("value") orelse .null };
    if (store.child(object, "values")) |values| request.values = values;

    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const current = try opened(io);
    // clicar numa linha de tabela não muda o projeto: a etapa só fica sabendo (a vista aproxima do item) e mostra
    if (std.mem.eql(u8, request.do, "grid") and std.mem.eql(u8, request.edit, "select")) {
        const length = @min(request.grid.len, current.selected_grid.len);
        @memcpy(current.selected_grid[0..length], request.grid[0..length]);
        current.selected_grid_len = length;
        current.selected_row = if (request.row >= 0) @intCast(request.row) else null;
        request.do = "show";
    }
    // Ctrl+Z: o projeto volta ao de antes do último pedido que mudou algo; os outros pedidos guardam o de antes
    // "Novo projeto…" ou a pasta pedida antes do primeiro "Guardar": vale para qualquer etapa
    if (std.mem.eql(u8, request.do, "project")) {
        const said = if (std.mem.eql(u8, request.key, "new")) try nameProject(current, request.arg) else "";
        var page = try stage.page(current, memory);
        page.reload = (project_aircraft.sync(current, memory) catch null) orelse "";
        page.requirements = try registry.requirementsSummary(memory, &current.project);
        page.project = current.project.folder;
        page.project_named = current.named;
        if (said.len > 0) page.message = said;
        var out: std.Io.Writer.Allocating = .init(memory);
        try simulation.writeStagePage(&out.writer, page);
        return std.json.parseFromSliceLeaky(Value, memory, out.written(), .{});
    }
    var changed = false;
    const message = if (std.mem.eql(u8, request.do, "undo")) blk: {
        changed = try current.undo();
        break :blk if (changed) "desfeito" else "nada para desfazer";
    }
    else if (std.mem.eql(u8, request.do, "show"))
        try stage.apply(current, memory, request)
    else blk: {
        const gpa = std.heap.page_allocator;
        const before = try std.json.Stringify.valueAlloc(gpa, current.project.root, .{});
        const said = stage.apply(current, memory, request) catch |err| {
            gpa.free(before);
            return err;
        };
        const after = try std.json.Stringify.valueAlloc(memory, current.project.root, .{});
        if (std.mem.eql(u8, before, after)) gpa.free(before) else {
            current.remember(before);
            changed = true;
        }
        break :blk said;
    };
    var page = try stage.page(current, memory);
    // o avião do projeto acompanha as etapas: mudou o projeto, a Montagem e as análises recebem o avião de novo
    if (changed and !stage.program) page.reload = (project_aircraft.sync(current, memory) catch null) orelse "";
    page.requirements = try registry.requirementsSummary(memory, &current.project);
    page.project = current.project.folder;
    page.project_named = current.named or stage.program;
    if (stage.program) {
        page.project = "";
        page.requirements = "";
    }
    if (message.len > 0) page.message = message;
    var out: std.Io.Writer.Allocating = .init(memory);
    try simulation.writeStagePage(&out.writer, page);
    return std.json.parseFromSliceLeaky(Value, memory, out.written(), .{});
}

// ------------------------------------------------------------------ ajudas das etapas
/// um campo de uma seção do projeto no formulário (`forms.specs`): o valor de agora como padrão
pub fn fieldParam(section: *const ObjectMap, field: registry.Field, prefix: []const u8, group: []const u8, memory: std.mem.Allocator) !simulation.Param {
    const key = try std.fmt.allocPrint(memory, "{s}{s}", .{ prefix, field.key });
    return switch (field.default) {
        .number => |fallback| .{ .key = key, .label = field.label, .kind = if (field.integer) .int else .float, .default = .{ .number = store.number(section, field.key, fallback) }, .minimum = field.minimum, .maximum = field.maximum, .unit = field.unit, .help = field.help, .group = group },
        .toggle => |fallback| .{ .key = key, .label = field.label, .kind = .bool, .default = .{ .toggle = store.flag(section, field.key, fallback) }, .help = field.help, .group = group },
        .text => |fallback| .{ .key = key, .label = field.label, .kind = if (field.choices.len > 0) .choice else .str, .default = .{ .text = store.text(section, field.key, fallback) }, .choices = field.choices, .help = field.help, .group = group },
    };
}

/// grava na seção os valores do formulário com este prefixo (`forms.apply`); devolve quantos mudaram
pub fn applyFields(project: *store.Project, section: *ObjectMap, fields: []const registry.Field, prefix: []const u8, values: *const ObjectMap) !usize {
    var changed: usize = 0;
    for (fields) |field| {
        var buffer: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, field.key }) catch continue;
        const value = values.get(key) orelse continue;
        switch (field.default) {
            .number => |fallback| {
                const number = switch (value) {
                    .float => |x| x,
                    .integer => |x| @as(f64, @floatFromInt(x)),
                    else => continue,
                };
                if (store.number(section, field.key, fallback) == number) continue;
                try store.setNumber(project, section, field.key, number);
            },
            .toggle => |fallback| {
                if (value != .bool or store.flag(section, field.key, fallback) == value.bool) continue;
                try section.put(project.memory(), field.key, .{ .bool = value.bool });
            },
            .text => |fallback| {
                if (value != .string or std.mem.eql(u8, store.text(section, field.key, fallback), value.string)) continue;
                try store.setText(project, section, field.key, value.string);
            },
        }
        changed += 1;
    }
    return changed;
}

/// o próximo nome livre: "asa 1" → "asa 2" (`next_name` de project.py)
pub fn nextName(memory: std.mem.Allocator, name: []const u8, taken: []const []const u8) ![]const u8 {
    var base = name;
    var number: usize = 1;
    if (std.mem.lastIndexOfScalar(u8, name, ' ')) |space| {
        if (std.fmt.parseInt(usize, name[space + 1 ..], 10)) |parsed| {
            base = name[0..space];
            number = parsed;
        } else |_| {}
    }
    while (true) : (number += 1) {
        const candidate = try std.fmt.allocPrint(memory, "{s} {d}", .{ base, number });
        var used = false;
        for (taken) |other| used = used or std.mem.eql(u8, other, candidate);
        if (!used) return candidate;
    }
}

/// guarda `candidate` na lista (o mesmo nome em `params.name` substitui)
pub fn put(list: *std.json.Array, candidate: Value) !void {
    const name = store.nameOf(candidate);
    for (list.items) |*item| if (std.mem.eql(u8, store.nameOf(item.*), name)) {
        item.* = candidate;
        return;
    };
    try list.append(candidate);
}

/// uma cópia funda de um valor JSON (as etapas guardam cópias: mudar o rascunho depois não muda o guardado)
pub fn clone(memory: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .object => |object| blk: {
            var out: ObjectMap = .empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| try out.put(memory, entry.key_ptr.*, try clone(memory, entry.value_ptr.*));
            break :blk .{ .object = out };
        },
        .array => |array| blk: {
            var out = std.json.Array.init(memory);
            for (array.items) |item| try out.append(try clone(memory, item));
            break :blk .{ .array = out };
        },
        else => value,
    };
}

/// o índice pedido dentro de `count` itens (nulo: fora)
pub fn within(index: i64, count: usize) ?usize {
    if (index < 0 or index >= count) return null;
    return @intCast(index);
}

test {
    _ = registry;
}

test "etapas em Zig: cada uma monta a página do projeto de exemplo, com a conta" {
    const io = std.testing.io;
    var project = try store.open(std.heap.page_allocator, io, "../data/sprint/projeto_s1223.json");
    project.folder = ".zig-cache/teste_sprint"; // nunca gravar em data/
    use(project, io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    for (all) |stage| {
        const request = try std.fmt.allocPrint(memory, "\"name\": \"{s}\", \"do\": \"show\"", .{stage.name});
        const reply = try handle(memory, io, request);
        try std.testing.expect(reply == .object);
        try std.testing.expect(reply.object.get("params") != null);
        if (std.mem.eql(u8, stage.name, "estudo") or std.mem.eql(u8, stage.name, "requisitos")) continue;
        const summary = reply.object.get("summary") orelse return error.SemConta;
        try std.testing.expect(summary == .array or summary == .object);
    }
}

test "Ctrl+Z da etapa: o projeto volta ao de antes do último pedido que mudou algo" {
    const io = std.testing.io;
    var project = try store.open(std.heap.page_allocator, io, "../data/sprint/projeto_s1223.json");
    project.folder = ".zig-cache/teste_desfazer"; // nunca gravar em data/
    use(project, io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    _ = try handle(memory, io, "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"asas\", \"edit\": \"add\", \"row\": -1");
    _ = try handle(memory, io, "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"dispositivos\", \"edit\": \"add\", \"row\": -1");
    const devices = struct {
        fn count() usize {
            const rows = shared.?.project.list("wing_layout").items;
            var total: usize = 0;
            for (rows) |row| if (row.object.get("devices")) |list| {
                total += list.array.items.len;
            };
            return total;
        }
    }.count;
    try std.testing.expectEqual(@as(usize, 1), devices());
    try std.testing.expect(shared.?.focus_device != null); // a vista aproxima do dispositivo novo
    const page = try handle(memory, io, "\"name\": \"asa\", \"do\": \"undo\"");
    try std.testing.expectEqualStrings("desfeito", page.object.get("message").?.string);
    try std.testing.expectEqual(@as(usize, 0), devices());
    try std.testing.expectEqual(@as(usize, 1), shared.?.project.list("wing_layout").items.len);
    _ = try handle(memory, io, "\"name\": \"asa\", \"do\": \"undo\"");
    try std.testing.expectEqual(@as(usize, 0), shared.?.project.list("wing_layout").items.len);
    const nothing = try handle(memory, io, "\"name\": \"asa\", \"do\": \"undo\"");
    try std.testing.expectEqualStrings("nada para desfazer", nothing.object.get("message").?.string);
}

test "pedidos em sequência, cada um com a memória dele liberada depois (como a tela): o projeto não guarda nada dela" {
    const io = std.testing.io;
    use(try store.empty(std.heap.page_allocator, ".zig-cache/teste_memoria"), io);
    const requests = [_][]const u8{
        "\"name\": \"asa\", \"do\": \"keep\"", // o projeto vazio: o rascunho ainda sem nome
        "\"name\": \"asa\", \"do\": \"set\", \"values\": {\"name\": \"asa de cima\", \"span\": 2.0}",
        "\"name\": \"asa\", \"do\": \"keep\"",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"asas\", \"edit\": \"add\", \"row\": -1",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"asas\", \"edit\": \"add\", \"row\": -1",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"asas\", \"edit\": \"set\", \"row\": 1, \"key\": \"wing\", \"value\": \"asa de cima\"",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"asas\", \"edit\": \"set\", \"row\": 1, \"key\": \"dz\", \"value\": 0.3",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"asas\", \"edit\": \"set\", \"row\": 1, \"key\": \"novo\", \"value\": 0.3",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"dispositivos\", \"edit\": \"add\", \"row\": -1",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"dispositivos\", \"edit\": \"set\", \"row\": 0, \"key\": \"kind\", \"value\": \"cerca\"",
        "\"name\": \"asa\", \"do\": \"grid\", \"grid\": \"dispositivos\", \"edit\": \"set\", \"row\": 0, \"key\": \"wing\", \"value\": \"2: asa de cima\"",
        "\"name\": \"asa\", \"do\": \"act\", \"key\": \"config\", \"arg\": \"biplano\"",
        "\"name\": \"requisitos\", \"do\": \"grid\", \"grid\": \"restricoes\", \"edit\": \"set\", \"row\": 0, \"key\": \"op\", \"value\": \"≥\"",
        "\"name\": \"requisitos\", \"do\": \"grid\", \"grid\": \"variaveis\", \"edit\": \"set\", \"row\": 0, \"key\": \"options\", \"value\": \"a, b\"",
        "\"name\": \"empenagem\", \"do\": \"keep\"",
        "\"name\": \"motores\", \"do\": \"keep\"",
        "\"name\": \"asa\", \"do\": \"undo\"",
        "\"name\": \"asa\", \"do\": \"keep\"",
    };
    for (requests) |request| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const text = try arena.allocator().dupe(u8, request);
        _ = handle(arena.allocator(), io, text) catch {};
        @memset(text, 0xaa);
        arena.deinit();
        // nenhum texto do projeto pode apontar para a memória do pedido que acabou
        const written = try std.json.Stringify.valueAlloc(std.testing.allocator, shared.?.project.root, .{});
        defer std.testing.allocator.free(written);
        try std.testing.expect(std.unicode.utf8ValidateSlice(written));
    }
    for (shared.?.project.list("wings").items) |wing| try std.testing.expect(store.nameOf(wing).len > 0);
}

test "o .aero leva o projeto: aberto sem projeto não muda nada, gravado e aberto de novo volta com o projeto e o mesmo avião" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const path = ".zig-cache/teste_documento.aero"; // uma cópia, nunca em data/
    const original = try std.Io.Dir.cwd().readFileAlloc(io, "../data/aircraft/Asa_voadora.aero", memory, .limited(1 << 26));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });
    // o avião de exemplo não tem projeto: as etapas não gravam nada nele
    var first = try documentContext(io, path);
    defer first.project.deinit();
    try std.testing.expect(!first.has_project);
    try std.testing.expect(first.save());
    try std.testing.expectEqualSlices(u8, original, try std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 26)));
    // com projeto: ele vai para a parte projeto.zon, e o avião continua o mesmo
    first.has_project = true;
    try store.setNumber(&first.project, first.project.section("requirements"), "V_cruise", 17);
    try std.testing.expect(first.save());
    var second = try documentContext(io, path);
    defer second.project.deinit();
    try std.testing.expect(second.has_project);
    try std.testing.expectEqual(@as(f64, 17), store.number(second.project.section("requirements"), "V_cruise", 0));
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const before = try aero_file.readDocument(memory, original, &diagnosis);
    const after = try aero_file.readDocument(memory, try std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 26)), &diagnosis);
    try std.testing.expectEqualStrings(before.json, after.json);
}

test "com o projeto dentro do .aero, a remontagem pelas etapas regrava o avião do mesmo arquivo" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const path = ".zig-cache/teste_documento_projeto.aero";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.Io.Dir.cwd().readFileAlloc(io, "../data/aircraft/Asa_voadora.aero", memory, .limited(1 << 26)) });
    var context = try documentContext(io, path);
    defer context.project.deinit();
    // o projeto de exemplo (com configurações guardadas) passa a morar no arquivo
    var sample = try store.open(std.heap.page_allocator, io, "../data/sprint/projeto_s1223.json");
    defer sample.deinit();
    context.project.root = try clone(context.project.memory(), sample.root);
    try context.project.reserve();
    context.has_project = true;
    const written = (try project_aircraft.sync(&context, memory)) orelse return error.NadaGravado;
    try std.testing.expectEqualStrings(path, written);
    var diagnosis: aircraft_model.aircraft.Diag = .{};
    const document = try aero_file.readDocument(memory, try std.Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(1 << 26)), &diagnosis);
    try std.testing.expect(std.mem.indexOf(u8, document.json, "Asa voadora") == null); // o avião agora é o do projeto
    var has_part = false;
    for (document.parts) |item| has_part = has_part or std.mem.eql(u8, item.name, aero_file.project_part);
    try std.testing.expect(has_part);
}

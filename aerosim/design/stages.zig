//! As etapas da sprint em Zig (o par de `aerosim/manager/stages.py`): cada etapa mexe no projeto (`store.Project`) e
//! devolve a página inteira (formulário, guardados, botões, tabelas editáveis e a conta) no mesmo formato da ponte
//! do Python, então a tela desenha igual. A tela chama `handle` com o pedido; uma etapa que ainda não está aqui
//! segue pelo Python (`find` devolve nulo).
//!
//!     requisitos   "Condições e restrições"        condições, regras, restrições e variáveis do projeto
//!     perfis       Aerodinâmica → Perfis           candidatos e a polar 2D de cada um
//!
//! O projeto fica na pasta da sprint (a mesma do Python: `$AEROSIM_PROJETOS/sprint`, senão
//! `~/aerosim_aeronaves/sprint`) e é gravado a cada mudança.
const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("simulation");
const store = @import("store.zig");
const registry = @import("registry.zig");
const airfoil_stage = @import("stage_airfoils.zig");
const wing_stage = @import("stage_wing.zig");
const requirements_stage = @import("stage_requirements.zig");
const tail_stage = @import("stage_tail.zig");
const power_stage = @import("stage_power.zig");
const study_stage = @import("stage_study.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// o que as etapas dividem: o projeto aberto, onde ele grava e a `Io` dos arquivos
pub const Context = struct {
    project: store.Project,
    io: std.Io,
    /// o perfil selecionado na etapa Perfis
    selected_airfoil: usize = 0,
    /// os perfis da biblioteca (`data/airfoils`), lidos uma vez, como candidatos do projeto
    library: ?[]const Value = null,

    /// grava o projeto (uma falha de gravação não derruba a etapa: a mensagem avisa)
    pub fn save(context: *Context) bool {
        context.project.save(context.io) catch return false;
        return true;
    }
};

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
};

/// as etapas que já estão em Zig
pub const all = [_]Stage{
    .{ .name = "requisitos", .apply = requirements_stage.apply, .page = requirements_stage.page },
    .{ .name = "perfis", .apply = airfoil_stage.apply, .page = airfoil_stage.page },
    .{ .name = "asa", .apply = wing_stage.apply, .page = wing_stage.page },
    .{ .name = "empenagem", .apply = tail_stage.apply, .page = tail_stage.page },
    .{ .name = "motores", .apply = power_stage.apply, .page = power_stage.page },
    .{ .name = "estudo", .apply = study_stage.apply, .page = study_stage.page },
};

/// a etapa em Zig com este nome (nulo: ela segue pelo Python)
pub fn find(name: []const u8) ?*const Stage {
    for (&all) |*stage| if (std.mem.eql(u8, stage.name, name)) return stage;
    return null;
}

var shared: ?Context = null;
var lock: std.atomic.Mutex = .unlocked;

/// a pasta da sprint (a do Python: `default_root()` + "sprint")
fn defaultFolder(memory: std.mem.Allocator) ![]const u8 {
    if (builtin.link_libc) {
        if (std.c.getenv("AEROSIM_PROJETOS")) |root| return std.fs.path.join(memory, &.{ std.mem.span(root), "sprint" });
        if (std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE")) |home| return std.fs.path.join(memory, &.{ std.mem.span(home), "aerosim_aeronaves", "sprint" });
    }
    return memory.dupe(u8, "aerosim_aeronaves/sprint");
}

/// o contexto aberto (o projeto da pasta da sprint, ou um vazio que grava lá)
fn opened(io: std.Io) !*Context {
    if (shared) |*existing| return existing;
    const gpa = std.heap.page_allocator;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const folder = try defaultFolder(scratch.allocator());
    const project = store.open(gpa, io, folder) catch try store.empty(gpa, folder);
    shared = .{ .project = project, .io = io };
    return &shared.?;
}

/// troca o projeto (abrir outra pasta; os testes usam um projeto da pasta `data`)
pub fn use(project: store.Project, io: std.Io) void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    if (shared) |*existing| existing.project.deinit();
    shared = .{ .project = project, .io = io };
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
    const message = try stage.apply(current, memory, request);
    var page = try stage.page(current, memory);
    page.requirements = try registry.requirementsSummary(memory, &current.project);
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

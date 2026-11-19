//! O arquivo `.aero`: um avião inteiro num arquivo só, no lugar dos vários `.json`. Por dentro é um zip (como o
//! `.xlsx`) com os textos em ZON (a notação de objetos do Zig: o próprio Zig lê e grava, sem biblioteca):
//!
//!   manifesto.zon   o formato e a versão dele, o programa que gravou, quando foi criado e modificado, o nome
//!   aviao.zon       o avião (`aircraft.Aircraft`: superfícies, fuselagem, trem, massas, motores, missão)
//!   outras partes   o que quem grava quiser levar junto (`Part`: o projeto, resultados em CSV, imagens em PNG)
//!
//! Um arquivo de uma versão de formato mais nova do que esta avisa (`error.NewerFormat`) em vez de ler errado.
//!
//!     const bytes = try aero_file.write(arena, &avião, .{ .program = "aerosim", .now = "2026-11-19T21:00:00Z" }, &.{});
//!     var lido = try aero_file.read(gpa, bytes, &diag);   // lido.plane.ac, lido.manifest, lido.parts
//!     defer lido.deinit();
const std = @import("std");
const core = @import("aerosim");
const aircraft = @import("aircraft.zig");

const zip = core.zip;
const zon_json = core.zon_json;

/// a extensão dos arquivos de avião
pub const extension = ".aero";
/// a versão do formato que este código grava e lê
pub const format_version: u32 = 1;

const manifest_name = "manifesto.zon";
const aircraft_name = "aviao.zon";

/// o que o arquivo diz de si
pub const Manifest = struct {
    formato: []const u8 = "aero",
    versao: u32 = format_version,
    programa: []const u8 = "",
    criado_em: []const u8 = "",
    modificado_em: []const u8 = "",
    nome: []const u8 = "",
};

/// uma parte a mais dentro do arquivo (o projeto, um CSV, uma imagem)
pub const Part = struct { name: []const u8, data: []const u8 };

/// quem grava e quando (texto ISO 8601); `created` vazio: o arquivo é novo e nasce agora
pub const Stamp = struct { program: []const u8, now: []const u8, created: []const u8 = "" };

pub const Error = aircraft.Error;

/// o arquivo lido: o avião (conferido), o manifesto e as outras partes
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    plane: aircraft.Loaded,
    manifest: Manifest,
    parts: []const Part,

    /// libera tudo o que a leitura alocou
    pub fn deinit(loaded: *Loaded) void {
        loaded.plane.deinit();
        loaded.arena.deinit();
    }

    /// a parte com este nome, se o arquivo tiver
    pub fn part(loaded: *const Loaded, name: []const u8) ?[]const u8 {
        for (loaded.parts) |item| if (std.mem.eql(u8, item.name, name)) return item.data;
        return null;
    }
};

/// verdadeiro se `bytes` parece um `.aero` (um zip; quem lê confere o manifesto)
pub fn looksLike(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
}

/// a hora de agora em texto ISO 8601, em UTC (`2026-11-19T21:00:00Z`), para o `Stamp`
pub fn isoNow(memory: std.mem.Allocator, io: std.Io) ![]const u8 {
    const nanoseconds = std.Io.Clock.real.now(io).nanoseconds;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(@divFloor(nanoseconds, std.time.ns_per_s), 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.allocPrint(memory, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

/// a data de criação gravada no `.aero` em `bytes` ("" se não for um `.aero` ou não tiver), para gravar de novo
/// sem perder quando o avião nasceu
pub fn createdOf(memory: std.mem.Allocator, bytes: []const u8) []const u8 {
    if (!looksLike(bytes)) return "";
    var diagnosis: aircraft.Diag = .{};
    const document = readDocument(memory, bytes, &diagnosis) catch return "";
    return document.manifest.criado_em;
}

/// grava o avião `plane` com o manifesto (as datas de `stamp`) e as partes `extra`; devolve os bytes do arquivo
pub fn write(memory: std.mem.Allocator, plane: *const aircraft.Aircraft, stamp: Stamp, extra: []const Part) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(memory, plane.*, .{ .emit_null_optional_fields = false });
    return writeDocument(memory, json, stamp, extra);
}

/// grava o avião dado pelo texto JSON `json` (o documento inteiro, como a Montagem guarda: o que não é do avião vai
/// junto e volta igual); o nome do manifesto é o `name` do avião
pub fn writeDocument(memory: std.mem.Allocator, json: []const u8, stamp: Stamp, extra: []const Part) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, memory, json, .{});
    // o `.json` da biblioteca antiga embrulha o avião (`"aeronave"`, com formato e data): o manifesto toma esse lugar
    const root = if (parsed == .object) if (parsed.object.get("aeronave")) |inner| (if (inner == .object) inner else parsed) else parsed else parsed;
    const name = if (root == .object) if (root.object.get("name")) |value| if (value == .string) value.string else "" else "" else "";
    const manifest: Manifest = .{
        .programa = stamp.program,
        .criado_em = if (stamp.created.len > 0) stamp.created else stamp.now,
        .modificado_em = stamp.now,
        .nome = name,
    };
    var zip_out: zip.Writer = .{};
    try zip_out.add(memory, manifest_name, try zon(memory, manifest));
    try zip_out.add(memory, aircraft_name, try zon_json.toZon(memory, root));
    for (extra) |item| try zip_out.add(memory, item.name, item.data);
    return zip_out.finish(memory);
}

/// o arquivo aberto sem conferir o avião: o manifesto, o avião em texto JSON e as outras partes (memória de `memory`)
pub const Document = struct { manifest: Manifest, json: []const u8, parts: []const Part };

/// abre um `.aero` e devolve o avião como texto JSON (quem lê o avião em JSON lê o `.aero` por aqui)
pub fn readDocument(memory: std.mem.Allocator, bytes: []const u8, diag: *aircraft.Diag) (Error || std.mem.Allocator.Error)!Document {
    const archive = zip.Archive.open(memory, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.set("o arquivo não é um .aero (não abriu como zip)", .{});
        return error.NotAero;
    };
    const manifest_entry = archive.find(manifest_name) orelse {
        diag.set("o arquivo não tem o {s}", .{manifest_name});
        return error.NotAero;
    };
    const manifest = parseZon(Manifest, memory, try extractPart(archive, memory, manifest_entry, diag)) catch {
        diag.set("o {s} está quebrado", .{manifest_name});
        return error.BadManifest;
    };
    if (!std.mem.eql(u8, manifest.formato, "aero")) {
        diag.set("o arquivo não é de avião (formato '{s}')", .{manifest.formato});
        return error.NotAero;
    }
    if (manifest.versao > format_version) {
        diag.set("o arquivo é da versão {d} do formato; este programa lê até a {d}: atualize o programa", .{ manifest.versao, format_version });
        return error.NewerFormat;
    }
    const plane_entry = archive.find(aircraft_name) orelse {
        diag.set("o arquivo não tem o {s}", .{aircraft_name});
        return error.BadAircraft;
    };
    const json = zon_json.zonToJson(memory, try extractPart(archive, memory, plane_entry, diag)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.set("o {s} está quebrado", .{aircraft_name});
        return error.BadAircraft;
    };
    var parts: std.ArrayList(Part) = .empty;
    for (archive.entries) |entry| {
        if (std.mem.eql(u8, entry.name, manifest_name) or std.mem.eql(u8, entry.name, aircraft_name)) continue;
        try parts.append(memory, .{ .name = entry.name, .data = try extractPart(archive, memory, entry, diag) });
    }
    return .{ .manifest = manifest, .json = json, .parts = parts.items };
}

/// o texto JSON `json` como ele volta de um `.aero` (`Document.json`), para comparar um avião com o do arquivo
pub fn canonicalJson(memory: std.mem.Allocator, json: []const u8) ![]const u8 {
    return zon_json.zonToJson(memory, try zon_json.jsonToZon(memory, json));
}

/// lê um `.aero` e confere o avião (`aircraft.validate`)
pub fn read(gpa: std.mem.Allocator, bytes: []const u8, diag: *aircraft.Diag) (Error || std.mem.Allocator.Error)!Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const document = try readDocument(memory, bytes, diag);
    const plane = try aircraft.parse(gpa, document.json, diag);
    return .{ .arena = arena, .plane = plane, .manifest = document.manifest, .parts = document.parts };
}

fn extractPart(archive: zip.Archive, memory: std.mem.Allocator, entry: zip.Archive.Entry, diag: *aircraft.Diag) (Error || std.mem.Allocator.Error)![]const u8 {
    return archive.extract(memory, entry) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.set("a parte {s} não abriu", .{entry.name});
        return error.NotAero;
    };
}

/// um valor em ZON com todos os campos (o manifesto: quem abre o arquivo vê o formato e a versão)
fn zon(memory: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(memory);
    try std.zon.stringify.serialize(value, .{}, &out.writer);
    return out.written();
}

fn parseZon(comptime T: type, memory: std.mem.Allocator, text: []const u8) !T {
    @setEvalBranchQuota(100_000);
    const source = try memory.dupeZ(u8, text);
    return std.zon.parse.fromSliceAlloc(T, memory, source, null, .{ .ignore_unknown_fields = true });
}

test "um avião de exemplo vai para .aero e volta igual, com as datas no manifesto" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const memory = arena.allocator();
    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../data/aircraft/Bimotor_convencional_tubo_cauda_em_V.aero", memory, .limited(1 << 24));
    var diagnosis: aircraft.Diag = .{};
    var original = try aircraft.parse(gpa, json, &diagnosis);
    defer original.deinit();

    const extra = [_]Part{.{ .name = "resultados/polar.csv", .data = "alpha,CL\n0,0.4\n" }};
    const bytes = try write(memory, &original.ac, .{ .program = "aerosim 0.3.1", .now = "2026-11-19T21:00:00Z", .created = "2026-11-01T10:00:00Z" }, &extra);
    try std.testing.expect(looksLike(bytes));

    var loaded = try read(gpa, bytes, &diagnosis);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("2026-11-01T10:00:00Z", loaded.manifest.criado_em);
    try std.testing.expectEqualStrings("2026-11-19T21:00:00Z", loaded.manifest.modificado_em);
    try std.testing.expectEqualStrings(original.ac.name, loaded.manifest.nome);
    try std.testing.expectEqualStrings("alpha,CL\n0,0.4\n", loaded.part("resultados/polar.csv").?);
    // o avião é o mesmo: os dois em JSON saem iguais, campo por campo
    const before = try std.json.Stringify.valueAlloc(memory, original.ac, .{});
    const after = try std.json.Stringify.valueAlloc(memory, loaded.plane.ac, .{});
    try std.testing.expectEqualStrings(before, after);
}

test "um .aero de uma versão de formato mais nova avisa em vez de ler errado" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var zip_out: zip.Writer = .{};
    try zip_out.add(memory, manifest_name, try zon(memory, Manifest{ .versao = format_version + 1 }));
    const bytes = try zip_out.finish(memory);
    var diagnosis: aircraft.Diag = .{};
    try std.testing.expectError(error.NewerFormat, read(std.testing.allocator, bytes, &diagnosis));
}

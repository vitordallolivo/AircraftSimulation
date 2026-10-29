//! Interface de armazenamento por caminho: ler, gravar, listar e apagar. Configurações, biblioteca
//! de aviões, configurações por avião e gravações passam por aqui, e quem usa não sabe onde os
//! arquivos ficam. Há duas implementações:
//!
//!   DiskStorage      o disco, pelo `std.Io` (o programa nativo; é o que já se fazia antes)
//!   BrowserStorage   o sistema de arquivos do emscripten no navegador; a pasta /aerodrive fica no
//!                    IndexedDB (IDBFS) e o JS sincroniza depois de cada gravação (`FS.syncfs`)
//!
//!   var disk: DiskStorage = .{ .io = io };
//!   const files = disk.storage();
//!   try files.write("pasta/config.json", bytes);          // cria as pastas que faltam
//!   const bytes = try files.read(gpa, "pasta/config.json", 1 << 20);
//!   var listing = try files.list(gpa, "pasta");           // listing.entries: nome e tipo
//!   defer listing.deinit();
const std = @import("std");
const browser = @import("../sys/browser.zig");
const fuzz = @import("../util/fuzz.zig");

pub const Error = error{
    NotFound,
    /// maior que o limite pedido na leitura
    TooBig,
    /// o destino recusou (disco cheio, sem permissão, caminho inválido...)
    Failed,
    OutOfMemory,
};

pub const Kind = enum { file, folder };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

/// o conteúdo de uma pasta; os nomes ficam na arena (`deinit` libera tudo)
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},

    /// libera os nomes e a lista
    pub fn deinit(listing: *Listing) void {
        listing.arena.deinit();
    }

    /// o item com este nome, se houver
    pub fn find(listing: *const Listing, name: []const u8) ?Entry {
        for (listing.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }
};

pub const Storage = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) Error![]u8,
        write: *const fn (context: *anyopaque, path: []const u8, bytes: []const u8) Error!void,
        list: *const fn (context: *anyopaque, gpa: std.mem.Allocator, folder: []const u8) Error!Listing,
        remove: *const fn (context: *anyopaque, path: []const u8) Error!void,
    };

    /// o arquivo inteiro (o chamador libera com `gpa`); maior que `max_bytes` = `error.TooBig`
    pub fn read(storage: Storage, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) Error![]u8 {
        return storage.vtable.read(storage.context, gpa, path, max_bytes);
    }

    /// grava o arquivo inteiro (substitui o que havia), criando as pastas que faltam
    pub fn write(storage: Storage, path: []const u8, bytes: []const u8) Error!void {
        return storage.vtable.write(storage.context, path, bytes);
    }

    /// arquivos e subpastas de `folder`, sem ordem garantida; pasta que não existe = `error.NotFound`
    pub fn list(storage: Storage, gpa: std.mem.Allocator, folder: []const u8) Error!Listing {
        return storage.vtable.list(storage.context, gpa, folder);
    }

    /// apaga o arquivo, ou a pasta com tudo o que tem dentro
    pub fn remove(storage: Storage, path: []const u8) Error!void {
        return storage.vtable.remove(storage.context, path);
    }
};

/// o disco, a partir da pasta atual (caminhos relativos ou absolutos)
pub const DiskStorage = struct {
    io: std.Io,

    /// a interface com este disco
    pub fn storage(disk: *DiskStorage) Storage {
        return .{ .context = disk, .vtable = &.{ .read = read, .write = write, .list = list, .remove = remove } };
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) Error![]u8 {
        const disk: *DiskStorage = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(disk.io, path, gpa, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => error.NotFound,
            error.StreamTooLong => error.TooBig,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
    }

    fn write(context: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        const disk: *DiskStorage = @ptrCast(@alignCast(context));
        if (std.fs.path.dirname(path)) |folder| std.Io.Dir.cwd().createDirPath(disk.io, folder) catch {};
        std.Io.Dir.cwd().writeFile(disk.io, .{ .sub_path = path, .data = bytes }) catch return error.Failed;
    }

    fn list(context: *anyopaque, gpa: std.mem.Allocator, folder: []const u8) Error!Listing {
        const disk: *DiskStorage = @ptrCast(@alignCast(context));
        var dir = std.Io.Dir.cwd().openDir(disk.io, folder, .{ .iterate = true }) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir => error.NotFound,
            else => error.Failed,
        };
        defer dir.close(disk.io);
        var listing: Listing = .{ .arena = .init(gpa) };
        errdefer listing.deinit();
        const arena = listing.arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        var iterator = dir.iterate();
        while (iterator.next(disk.io) catch null) |entry| {
            const kind: Kind = switch (entry.kind) {
                .file, .sym_link => .file,
                .directory => .folder,
                else => continue,
            };
            try entries.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = kind });
        }
        listing.entries = entries.items;
        return listing;
    }

    fn remove(context: *anyopaque, path: []const u8) Error!void {
        const disk: *DiskStorage = @ptrCast(@alignCast(context));
        std.Io.Dir.cwd().deleteTree(disk.io, path) catch return error.Failed;
    }
};

/// o sistema de arquivos do emscripten (só existe no alvo web); o que fica em /aerodrive persiste
pub const BrowserStorage = struct {
    /// a interface com o armazenamento do navegador
    pub fn storage(browser_storage: *BrowserStorage) Storage {
        return .{ .context = browser_storage, .vtable = &.{ .read = read, .write = write, .list = list, .remove = remove } };
    }

    fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) Error![]u8 {
        const size = browser.fileSize(path) orelse return error.NotFound;
        if (size > max_bytes) return error.TooBig;
        const bytes = try gpa.alloc(u8, size);
        errdefer gpa.free(bytes);
        if (!browser.fileRead(path, bytes)) return error.Failed;
        return bytes;
    }

    fn write(_: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        if (!browser.fileWrite(path, bytes)) return error.Failed;
    }

    fn list(_: *anyopaque, gpa: std.mem.Allocator, folder: []const u8) Error!Listing {
        var listing: Listing = .{ .arena = .init(gpa) };
        errdefer listing.deinit();
        const arena = listing.arena.allocator();
        const text = try browser.folderList(arena, folder) orelse return error.NotFound;
        listing.entries = try parseListing(arena, text);
        return listing;
    }

    fn remove(_: *anyopaque, path: []const u8) Error!void {
        if (!browser.pathRemove(path)) return error.Failed;
    }
};

/// a listagem que o JS devolve: um nome por linha, pastas terminadas em "/"
pub fn parseListing(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const is_folder = std.mem.endsWith(u8, line, "/");
        const name = if (is_folder) line[0 .. line.len - 1] else line;
        if (name.len == 0) continue;
        try entries.append(arena, .{ .name = name, .kind = if (is_folder) .folder else .file });
    }
    return entries.items;
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

test "disco: grava criando pastas, lê, lista e apaga" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [512]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var disk: DiskStorage = .{ .io = testing.io };
    const files = disk.storage();
    var path_buf: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/a/b/avião.json", .{root});
    try files.write(path, "{\"x\":1}");
    const bytes = try files.read(testing.allocator, path, 100);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"x\":1}", bytes);
    try testing.expectError(error.TooBig, files.read(testing.allocator, path, 3));

    var folder_buf: [600]u8 = undefined;
    var listing = try files.list(testing.allocator, try std.fmt.bufPrint(&folder_buf, "{s}/a", .{root}));
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expect(listing.find("b").?.kind == .folder);

    try files.remove(try std.fmt.bufPrint(&folder_buf, "{s}/a", .{root}));
    try testing.expectError(error.NotFound, files.read(testing.allocator, path, 100));
    try testing.expectError(error.NotFound, files.list(testing.allocator, try std.fmt.bufPrint(&folder_buf, "{s}/a", .{root})));
}

test "listagem do navegador: pastas com barra, linhas vazias puladas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try parseListing(arena.allocator(), "Asa.json\nvoo_2026/\n\n/\nB c.json");
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expect(entries[0].kind == .file and std.mem.eql(u8, entries[0].name, "Asa.json"));
    try testing.expect(entries[1].kind == .folder and std.mem.eql(u8, entries[1].name, "voo_2026"));
    try testing.expectEqualStrings("B c.json", entries[2].name);
}

fn fuzzListing(_: void, source: *fuzz.Src) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    const entries = try parseListing(arena.allocator(), buf[0..source.bytes(&buf)]);
    for (entries) |entry| try testing.expect(entry.name.len > 0 and std.mem.indexOfScalar(u8, entry.name, '\n') == null);
}

test "fuzz: listagem do navegador" {
    try fuzz.check({}, fuzzListing, .{});
}

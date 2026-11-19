//! Interface de armazenamento chave → bytes (e o valor em ZON por cima, no arquivo `.aerocfg`). Quem guarda
//! configurações não sabe onde ficam: `FileStore` grava um arquivo por chave numa pasta (pelo
//! `storage.Storage`: disco no nativo, IndexedDB no navegador); `MemStore` guarda na memória (testes). Outra
//! implementação (nuvem, banco) é só outro `VTable`. O `.json` das versões antigas ainda é lido (e regravado
//! como `.aerocfg` na próxima gravação).
//!
//!   var fs = FileStore{ .files = disk.storage(), .root = "~/.config/aerodrive/avioes" };
//!   const st = fs.store();
//!   st.saveValue(gpa, chave, valor);
//!   const v = st.loadValue(T, gpa, chave) orelse padrão;
const std = @import("std");
const storage = @import("storage.zig");
const fz = @import("../util/fuzz.zig");

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// bytes da chave (o chamador libera com `gpa`), ou null se não existe/não deu
        load: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, key: []const u8) ?[]u8,
        /// grava; false se não deu (quem chama segue sem travar)
        save: *const fn (ptr: *anyopaque, key: []const u8, bytes: []const u8) bool,
    };

    pub fn load(s: Store, gpa: std.mem.Allocator, key: []const u8) ?[]u8 {
        return s.vtable.load(s.ptr, gpa, key);
    }

    pub fn save(s: Store, key: []const u8, bytes: []const u8) bool {
        return s.vtable.save(s.ptr, key, bytes);
    }

    /// o texto da chave → T (campos faltando = padrão, desconhecidos ignorados); quebrado/ausente = null.
    /// T só pode ter números, bools, enums e structs (nada que aponte para o texto lido).
    pub fn loadValue(s: Store, comptime T: type, gpa: std.mem.Allocator, key: []const u8) ?T {
        const bytes = s.load(gpa, key) orelse return null;
        defer gpa.free(bytes);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        return decode(T, arena.allocator(), bytes) catch null;
    }

    /// grava `value` em ZON na chave
    pub fn saveValue(s: Store, gpa: std.mem.Allocator, key: []const u8, value: anytype) bool {
        const text = encode(gpa, value) catch return false;
        defer gpa.free(text);
        return s.save(key, text);
    }
};

/// a extensão dos arquivos de configuração
pub const extension = ".aerocfg";

/// o texto de uma configuração → T (memória de `memory`): ZON, ou o JSON das versões antigas (começa com `{`)
pub fn decode(comptime T: type, memory: std.mem.Allocator, bytes: []const u8) !T {
    const text = std.mem.trimStart(u8, bytes, " \t\r\n");
    if (text.len > 0 and text[0] == '{') return std.json.parseFromSliceLeaky(T, memory, text, .{ .ignore_unknown_fields = true });
    const source = try memory.dupeZ(u8, bytes);
    return std.zon.parse.fromSliceAlloc(T, memory, source, null, .{ .ignore_unknown_fields = true });
}

/// `value` em ZON (o chamador libera com `gpa`)
pub fn encode(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.zon.stringify.serialize(value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// um arquivo `<root>/<chave>.aerocfg` por chave (lê o `<chave>.json` antigo se o novo ainda não existe)
pub const FileStore = struct {
    files: storage.Storage,
    root: []const u8,

    pub fn store(f: *FileStore) Store {
        return .{ .ptr = f, .vtable = &.{ .load = load, .save = save } };
    }

    fn path(f: *const FileStore, buf: []u8, key: []const u8, file_extension: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ f.root, key, file_extension }) catch null;
    }

    fn load(ptr: *anyopaque, gpa: std.mem.Allocator, key: []const u8) ?[]u8 {
        const file_store: *FileStore = @ptrCast(@alignCast(ptr));
        var path_buf: [1200]u8 = undefined;
        for ([_][]const u8{ extension, ".json" }) |file_extension| {
            const file_path = file_store.path(&path_buf, key, file_extension) orelse return null;
            if (file_store.files.read(gpa, file_path, 1 << 20)) |bytes| return bytes else |_| {}
        }
        return null;
    }

    fn save(ptr: *anyopaque, key: []const u8, bytes: []const u8) bool {
        const file_store: *FileStore = @ptrCast(@alignCast(ptr));
        var path_buf: [1200]u8 = undefined;
        const file_path = file_store.path(&path_buf, key, extension) orelse return false;
        file_store.files.write(file_path, bytes) catch return false;
        return true;
    }
};

/// na memória (testes)
pub const MemStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(m: *MemStore) void {
        var it = m.map.iterator();
        while (it.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.*);
        }
        m.map.deinit(m.gpa);
    }

    pub fn store(m: *MemStore) Store {
        return .{ .ptr = m, .vtable = &.{ .load = load, .save = save } };
    }

    fn load(ptr: *anyopaque, gpa: std.mem.Allocator, key: []const u8) ?[]u8 {
        const m: *MemStore = @ptrCast(@alignCast(ptr));
        const v = m.map.get(key) orelse return null;
        return gpa.dupe(u8, v) catch null;
    }

    fn save(ptr: *anyopaque, key: []const u8, bytes: []const u8) bool {
        const m: *MemStore = @ptrCast(@alignCast(ptr));
        const v = m.gpa.dupe(u8, bytes) catch return false;
        if (m.map.getPtr(key)) |old| {
            m.gpa.free(old.*);
            old.* = v;
            return true;
        }
        const k = m.gpa.dupe(u8, key) catch {
            m.gpa.free(v);
            return false;
        };
        m.map.put(m.gpa, k, v) catch {
            m.gpa.free(k);
            m.gpa.free(v);
            return false;
        };
        return true;
    }
};

/// chave de arquivo segura para um caminho qualquer: nome do arquivo (só letras, números, _ e -)
/// + 8 dígitos do hash do caminho inteiro (dois "aviao.json" em pastas diferentes não se misturam)
pub fn keyFor(buf: *[64]u8, path: []const u8) []const u8 {
    const base = std.fs.path.stem(std.fs.path.basename(path));
    var n: usize = 0;
    for (base) |c| {
        if (n >= 40) break;
        buf[n] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
        n += 1;
    }
    if (n == 0) {
        buf[0] = 'x';
        n = 1;
    }
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, path));
    const tail = std.fmt.bufPrint(buf[n..], "-{x:0>8}", .{h}) catch unreachable;
    return buf[0 .. n + tail.len];
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

const Demo = struct { a: f64 = 1, b: bool = false, c: enum { x, y } = .x };

test "ida e volta pela interface em ZON; o JSON antigo ainda lê; texto quebrado = null" {
    var m: MemStore = .{ .gpa = testing.allocator };
    defer m.deinit();
    const s = m.store();
    try testing.expect(s.saveValue(testing.allocator, "k", Demo{ .a = 3, .c = .y }));
    const text = s.load(testing.allocator, "k").?;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".c = .y") != null);
    const d = s.loadValue(Demo, testing.allocator, "k").?;
    try testing.expectEqual(@as(f64, 3), d.a);
    try testing.expect(d.c == .y);
    try testing.expect(s.save("velho", "{\"a\": 2, \"b\": true}"));
    try testing.expectEqual(@as(f64, 2), s.loadValue(Demo, testing.allocator, "velho").?.a);
    try testing.expect(s.save("k", "{quebrado"));
    try testing.expect(s.loadValue(Demo, testing.allocator, "k") == null);
    try testing.expect(s.save("k", ".{ .a = "));
    try testing.expect(s.loadValue(Demo, testing.allocator, "k") == null);
    try testing.expect(s.loadValue(Demo, testing.allocator, "não existe") == null);
}

test "arquivo: grava e lê na pasta" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var pb: [600]u8 = undefined;
    var disk: storage.DiskStorage = .{ .io = testing.io };
    var f: FileStore = .{ .files = disk.storage(), .root = try std.fmt.bufPrint(&pb, "{s}/sub/avioes", .{root}) };
    const s = f.store();
    try testing.expect(s.saveValue(testing.allocator, "Asa-1", Demo{ .b = true }));
    try testing.expect(s.loadValue(Demo, testing.allocator, "Asa-1").?.b);
    var file_buf: [700]u8 = undefined;
    _ = try std.Io.Dir.cwd().statFile(testing.io, try std.fmt.bufPrint(&file_buf, "{s}/Asa-1.aerocfg", .{f.root}), .{});
}

test "chave: só caracteres seguros, caminhos diferentes = chaves diferentes" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const k1 = keyFor(&b1, "../data/aircraft/Asa voadora.json");
    const k2 = keyFor(&b2, "/home/x/aviões/Asa voadora.json");
    try testing.expect(std.mem.startsWith(u8, k1, "Asa_voadora-"));
    try testing.expect(!std.mem.eql(u8, k1, k2));
}

fn fuzzStore(_: void, src: *fz.Src) anyerror!void {
    var m: MemStore = .{ .gpa = testing.allocator };
    defer m.deinit();
    const s = m.store();
    var kb: [80]u8 = undefined;
    var vb: [200]u8 = undefined;
    while (!src.chance(6)) {
        var key_buf: [64]u8 = undefined;
        const key = keyFor(&key_buf, kb[0..src.bytes(&kb)]);
        for (key) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '_' or c == '-');
        _ = s.save(key, vb[0..src.bytes(&vb)]);
        _ = s.loadValue(Demo, testing.allocator, key); // bytes quaisquer: null ou valor, nunca trava
    }
}

test "fuzz: armazenamento" {
    try fz.check({}, fuzzStore, .{});
}

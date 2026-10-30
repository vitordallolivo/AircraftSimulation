//! O `std.Io` das telas no navegador. No Zig 0.16 o `std.Io.Threaded` não compila para emscripten (o mesmo motivo
//! de `aerodrive/src/sys/browser_io.zig`), então o alvo web usa a `std.Io.failing` da biblioteca (tudo responde
//! "não dá", sem travar) com as partes que as telas usam feitas pela libc do emscripten, que guarda os arquivos na
//! memória (o MEMFS: os exemplos empacotados no .data, o que se arrasta para a página e o que se salva):
//!
//!   pastas      abrir, listar e fechar (o seletor de arquivos e a biblioteca de perfis)
//!   arquivos    abrir, criar, ler, escrever, tamanho e fechar (abrir e salvar avião, exportar gráfico)
//!   caminhos    existe? (`access`) e o caminho absoluto (`realPathFile`)
//!   saída       stdout e stderr vão para o console do navegador
//!   relógio     `Clock.real` pela data do navegador; os outros pelo `performance.now`
//!
//! O resto (processos, rede, threads) falha como na `failing`, e quem chama segue sem aquilo.
const std = @import("std");
const emscripten = std.os.emscripten;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

/// a `Io` do navegador (uma só, sem estado por instância)
pub const io: Io = .{ .userdata = null, .vtable = &vtable };

const vtable: Io.VTable = blk: {
    var table = Io.failing.vtable.*;
    table.swapCancelProtection = swapCancelProtection;
    table.checkCancel = checkCancel;
    table.operate = operate;
    table.lockStderr = lockStderr;
    table.tryLockStderr = tryLockStderr;
    table.unlockStderr = unlockStderr;
    table.now = now;
    table.dirOpenDir = dirOpenDir;
    table.dirRead = dirRead;
    table.dirClose = dirClose;
    table.dirAccess = dirAccess;
    table.dirOpenFile = dirOpenFile;
    table.dirCreateFile = dirCreateFile;
    table.dirRealPathFile = dirRealPathFile;
    table.fileClose = fileClose;
    table.fileLength = fileLength;
    table.fileStat = fileStat;
    table.fileReadPositional = fileReadPositional;
    table.fileWritePositional = fileWritePositional;
    table.fileSeekTo = fileSeekTo;
    table.fileSeekBy = fileSeekBy;
    break :blk table;
};

// a libc do emscripten (musl); declaradas aqui porque o `std.c` só as declara para outros sistemas
const DirStream = opaque {};
const DirEntry = extern struct { inode: u64, offset: i64, record_length: u16, kind: u8, name: [256]u8 };
extern "c" fn fdopendir(handle: c_int) ?*DirStream;
extern "c" fn readdir(stream: *DirStream) ?*DirEntry;
extern "c" fn rewinddir(stream: *DirStream) void;
extern "c" fn closedir(stream: *DirStream) c_int;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
extern "c" fn lseek(handle: c_int, offset: i64, whence: c_int) i64;
extern "c" fn emscripten_date_now() f64;

const seek_set = 0;
const seek_current = 1;
const seek_end = 2;
// os tipos de `d_type` (dirent.h do musl)
const entry_directory = 4;
const entry_file = 8;

var cancel_protection: Io.CancelProtection = .unblocked;

fn swapCancelProtection(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const previous = cancel_protection;
    cancel_protection = new;
    return previous;
}

fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}

/// o caminho com o zero no fim (as funções da libc pedem assim)
fn terminated(buffer: *[std.fs.max_path_bytes:0]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0].ptr;
}

fn openError() File.OpenError {
    return switch (std.c._errno().*) {
        @intFromEnum(std.c.E.NOENT) => error.FileNotFound,
        @intFromEnum(std.c.E.ACCES) => error.AccessDenied,
        @intFromEnum(std.c.E.ISDIR) => error.IsDir,
        @intFromEnum(std.c.E.NOTDIR) => error.NotDir,
        @intFromEnum(std.c.E.EXIST) => error.PathAlreadyExists,
        else => error.Unexpected,
    };
}

// ---- pastas: o descritor da pasta é o `handle`; a listagem (o `DIR*` da libc) fica numa tabela por descritor

const max_open_folders = 16;
var folder_handles: [max_open_folders]c_int = [_]c_int{-1} ** max_open_folders;
var folder_streams: [max_open_folders]?*DirStream = [_]?*DirStream{null} ** max_open_folders;

fn dirOpenDir(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.OpenOptions) Dir.OpenError!Dir {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = terminated(&buffer, sub_path) orelse return error.NameTooLong;
    const handle = std.c.openat(dir.handle, path, .{ .DIRECTORY = true, .ACCMODE = .RDONLY });
    if (handle < 0) return switch (std.c._errno().*) {
        @intFromEnum(std.c.E.NOENT) => error.FileNotFound,
        @intFromEnum(std.c.E.NOTDIR) => error.NotDir,
        @intFromEnum(std.c.E.ACCES) => error.AccessDenied,
        else => error.Unexpected,
    };
    return .{ .handle = handle };
}

fn folderStream(handle: c_int) ?*DirStream {
    for (folder_handles, 0..) |known, i| if (known == handle) return folder_streams[i];
    for (&folder_handles, 0..) |*slot, i| if (slot.* == -1) {
        const stream = fdopendir(handle) orelse return null;
        slot.* = handle;
        folder_streams[i] = stream;
        return stream;
    };
    return null;
}

fn dirRead(_: ?*anyopaque, reader: *Dir.Reader, entries: []Dir.Entry) Dir.Reader.Error!usize {
    const stream = folderStream(reader.dir.handle) orelse return error.SystemResources;
    if (reader.state == .reset) {
        rewinddir(stream);
        reader.state = .reading;
        reader.index = 0;
        reader.end = 0;
    }
    if (reader.state == .finished) return 0;
    // os nomes ficam no `buffer` do leitor até a próxima leitura
    var used: usize = 0;
    var count: usize = 0;
    while (count < entries.len) {
        const entry = readdir(stream) orelse {
            reader.state = .finished;
            break;
        };
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (used + name.len > reader.buffer.len) break;
        @memcpy(reader.buffer[used..][0..name.len], name);
        entries[count] = .{
            .name = reader.buffer[used..][0..name.len],
            .kind = switch (entry.kind) {
                entry_directory => .directory,
                entry_file => .file,
                else => .unknown,
            },
            .inode = @intCast(entry.inode),
        };
        used += name.len;
        count += 1;
        if (count == 1 and used > reader.buffer.len / 2) break; // um nome longo: devolve antes de faltar espaço
    }
    return count;
}

fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    for (dirs) |dir| {
        if (dir.handle == std.posix.AT.FDCWD) continue;
        var closed = false;
        for (&folder_handles, 0..) |*slot, i| if (slot.* == dir.handle) {
            _ = closedir(folder_streams[i].?); // fecha também o descritor
            slot.* = -1;
            folder_streams[i] = null;
            closed = true;
        };
        if (!closed) _ = std.c.close(dir.handle);
    }
}

fn dirAccess(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.AccessOptions) Dir.AccessError!void {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = terminated(&buffer, sub_path) orelse return error.NameTooLong;
    if (std.c.faccessat(dir.handle, path, 0, 0) != 0) return error.FileNotFound;
}

fn dirRealPathFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, out: []u8) Dir.RealPathFileError!usize {
    if (dir.handle != std.posix.AT.FDCWD) return error.Unexpected;
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = terminated(&buffer, sub_path) orelse return error.NameTooLong;
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const result = realpath(path, &resolved) orelse return error.FileNotFound;
    const text = std.mem.sliceTo(result, 0);
    if (text.len > out.len) return error.NameTooLong;
    @memcpy(out[0..text.len], text);
    return text.len;
}

// ---- arquivos

fn dirOpenFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = terminated(&buffer, sub_path) orelse return error.NameTooLong;
    const handle = std.c.openat(dir.handle, path, .{ .ACCMODE = switch (options.mode) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    } });
    if (handle < 0) return openError();
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn dirCreateFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = terminated(&buffer, sub_path) orelse return error.NameTooLong;
    const handle = std.c.openat(dir.handle, path, .{
        .ACCMODE = if (options.read) .RDWR else .WRONLY,
        .CREAT = true,
        .TRUNC = options.truncate,
        .EXCL = options.exclusive,
    }, @as(c_uint, 0o666));
    if (handle < 0) return openError();
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn fileClose(_: ?*anyopaque, files: []const File) void {
    for (files) |file| _ = std.c.close(file.handle);
}

fn fileLength(_: ?*anyopaque, file: File) File.LengthError!u64 {
    const here = lseek(file.handle, 0, seek_current);
    const end = lseek(file.handle, 0, seek_end);
    _ = lseek(file.handle, here, seek_set);
    if (end < 0) return error.Unexpected;
    return @intCast(end);
}

fn fileStat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const size = fileLength(userdata, file) catch return error.Unexpected;
    const zero: Io.Timestamp = .{ .nanoseconds = 0 };
    return .{
        .inode = 0,
        .nlink = 1,
        .size = size,
        .permissions = .default_file,
        .kind = .file,
        .atime = null,
        .mtime = zero,
        .ctime = zero,
        .block_size = 1,
    };
}

fn fileReadPositional(_: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    var total: usize = 0;
    for (data) |chunk| {
        if (chunk.len == 0) continue;
        const count = std.c.pread(file.handle, chunk.ptr, chunk.len, @intCast(offset + total));
        if (count < 0) return error.InputOutput;
        total += @intCast(count);
        if (@as(usize, @intCast(count)) < chunk.len) break;
    }
    return total;
}

fn fileWritePositional(_: ?*anyopaque, file: File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) File.WritePositionalError!usize {
    var written: usize = 0;
    written += try writeAt(file.handle, header, offset + written);
    if (data.len == 0) return written;
    for (data[0 .. data.len - 1]) |chunk| written += try writeAt(file.handle, chunk, offset + written);
    for (0..splat) |_| written += try writeAt(file.handle, data[data.len - 1], offset + written);
    return written;
}

fn writeAt(handle: File.Handle, bytes: []const u8, offset: u64) error{InputOutput}!usize {
    var done: usize = 0;
    while (done < bytes.len) {
        const count = std.c.pwrite(handle, bytes[done..].ptr, bytes.len - done, @intCast(offset + done));
        if (count <= 0) return error.InputOutput;
        done += @intCast(count);
    }
    return bytes.len;
}

fn fileSeekTo(_: ?*anyopaque, file: File, offset: u64) File.SeekError!void {
    if (lseek(file.handle, @intCast(offset), seek_set) < 0) return error.Unseekable;
}

fn fileSeekBy(_: ?*anyopaque, file: File, offset: i64) File.SeekError!void {
    if (lseek(file.handle, offset, seek_current) < 0) return error.Unseekable;
}

// ---- leitura e escrita em sequência (arquivos abertos, stdout e stderr)

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_write_streaming => |write| .{ .file_write_streaming = writeStreaming(write) },
        .file_read_streaming => |read| .{ .file_read_streaming = readStreaming(read) },
        else => Io.failingOperate(userdata, operation),
    };
}

fn readStreaming(read: Io.Operation.FileReadStreaming) Io.Operation.FileReadStreaming.Result {
    var total: usize = 0;
    for (read.data) |chunk| {
        if (chunk.len == 0) continue;
        const count = std.c.read(read.file.handle, chunk.ptr, chunk.len);
        if (count < 0) return error.InputOutput;
        total += @intCast(count);
        if (@as(usize, @intCast(count)) < chunk.len) break;
    }
    if (total == 0) return error.EndOfStream;
    return total;
}

fn writeStreaming(write: Io.Operation.FileWriteStreaming) Io.Operation.FileWriteStreaming.Result {
    var written = try writeAll(write.file.handle, write.header);
    if (write.data.len == 0) return written;
    for (write.data[0 .. write.data.len - 1]) |chunk| written += try writeAll(write.file.handle, chunk);
    for (0..write.splat) |_| written += try writeAll(write.file.handle, write.data[write.data.len - 1]);
    return written;
}

fn writeAll(handle: File.Handle, bytes: []const u8) error{InputOutput}!usize {
    var done: usize = 0;
    while (done < bytes.len) {
        const count = std.c.write(handle, bytes[done..].ptr, bytes.len - done);
        if (count <= 0) return error.InputOutput;
        done += @intCast(count);
    }
    return bytes.len;
}

var stderr_buffer: [256]u8 = undefined;
var stderr_writer: File.Writer = undefined;

fn lockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    stderr_writer = File.stderr().writerStreaming(io, &stderr_buffer);
    return .{ .file_writer = &stderr_writer, .terminal_mode = .no_color };
}

fn tryLockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    return try lockStderr(userdata, mode);
}

fn unlockStderr(_: ?*anyopaque) void {
    stderr_writer.interface.flush() catch {};
}

fn now(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const milliseconds = switch (clock) {
        .real => emscripten_date_now(),
        else => emscripten.emscripten_get_now(),
    };
    return .{ .nanoseconds = @intFromFloat(milliseconds * std.time.ns_per_ms) };
}

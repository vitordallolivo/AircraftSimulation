//! O `std.Io` do navegador. No Zig 0.16 o `std.Io.Threaded` não compila para emscripten (o
//! `W.STOPSIG` de `std/os/emscripten.zig` devolve u32 onde se espera um enum), e ele é a `Io`
//! padrão até do `std.debug.print`. Por isso o alvo web usa esta: a `std.Io.failing` da
//! biblioteca (tudo responde "não dá", sem travar) com quatro partes de verdade:
//!
//!   escrita em arquivo aberto   stdout/stderr vão para o console do navegador (`write` do emscripten)
//!   stderr travado              o que o `std.debug.print` e as panes usam
//!   relógio                     `Clock.real` pela data do navegador; os outros pelo `performance.now`
//!   cancelamento                uma thread só: nada se cancela
//!
//! Arquivos não passam por aqui: o jogo lê e grava pela interface `app/storage.zig`. Quem ainda
//! chama `std.Io.Dir` no navegador (painel F3 lendo /proc, ffmpeg do vídeo) recebe um erro e
//! segue sem aquilo, como no nativo quando falta o programa.
const std = @import("std");
const emscripten = std.os.emscripten;

/// a `Io` do navegador (uma só, sem estado por instância)
pub const io: std.Io = .{ .userdata = null, .vtable = &vtable };

const vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.swapCancelProtection = swapCancelProtection;
    table.checkCancel = checkCancel;
    table.operate = operate;
    table.lockStderr = lockStderr;
    table.tryLockStderr = tryLockStderr;
    table.unlockStderr = unlockStderr;
    table.now = now;
    break :blk table;
};

extern "c" fn emscripten_date_now() f64;

var cancel_protection: std.Io.CancelProtection = .unblocked;

fn swapCancelProtection(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
    const previous = cancel_protection;
    cancel_protection = new;
    return previous;
}

fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {}

/// só a escrita em arquivo aberto (na prática stdout e stderr); o resto falha como na `failing`
fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    return switch (operation) {
        .file_write_streaming => |write| .{ .file_write_streaming = writeStreaming(write) },
        else => std.Io.failingOperate(userdata, operation),
    };
}

fn writeStreaming(write: std.Io.Operation.FileWriteStreaming) std.Io.Operation.FileWriteStreaming.Result {
    var written = try writeAll(write.file.handle, write.header);
    if (write.data.len == 0) return written;
    for (write.data[0 .. write.data.len - 1]) |chunk| written += try writeAll(write.file.handle, chunk);
    for (0..write.splat) |_| written += try writeAll(write.file.handle, write.data[write.data.len - 1]);
    return written;
}

fn writeAll(handle: std.Io.File.Handle, bytes: []const u8) error{InputOutput}!usize {
    var done: usize = 0;
    while (done < bytes.len) {
        const count = std.c.write(handle, bytes[done..].ptr, bytes.len - done);
        if (count <= 0) return error.InputOutput;
        done += @intCast(count);
    }
    return bytes.len;
}

var stderr_buffer: [256]u8 = undefined;
var stderr_writer: std.Io.File.Writer = undefined;

fn lockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    return .{ .file_writer = &stderr_writer, .terminal_mode = .no_color };
}

fn tryLockStderr(userdata: ?*anyopaque, mode: ?std.Io.Terminal.Mode) std.Io.Cancelable!?std.Io.LockedStderr {
    return try lockStderr(userdata, mode);
}

fn unlockStderr(_: ?*anyopaque) void {
    stderr_writer.interface.flush() catch {};
}

fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const milliseconds = switch (clock) {
        .real => emscripten_date_now(),
        else => emscripten.emscripten_get_now(),
    };
    return .{ .nanoseconds = @intFromFloat(milliseconds * std.time.ns_per_ms) };
}

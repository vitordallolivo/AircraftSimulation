//! A ponte com os managers em Python (`aerosim/bridge.py`): a tela abre `python -m aerosim.bridge` como processo
//! filho e conversa por uma mensagem JSON por linha, na entrada e na saída padrão dele. Aqui só se manda o pedido e
//! se lê a resposta; quem desenha é `python_tab.zig`, e quem calcula é o Python (que chama o núcleo).
//!
//! Os pedidos são bloqueantes: quem chama `request` está numa `Job` (`ui/jobs.zig`), fora do laço da tela. As linhas
//! de progresso que chegam antes da resposta atualizam `progress` e `progress_text`, que a tela lê a cada quadro.
//! No navegador não há processo filho: lá a ponte vai ser o Pyodide num web worker (etapa seguinte do plano).
const std = @import("std");
const ui_kit = @import("ui");

pub const Error = error{ NotStarted, PythonNotFound, BridgeClosed, BadReply, NotInBrowser };

/// o processo do Python e o leitor da saída dele
pub const Bridge = struct {
    child: ?std.process.Child = null,
    read_buffer: [1 << 16]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    next_id: u32 = 1,
    progress: std.atomic.Value(u32) = .init(0), // fração × 1000 da rodada em andamento
    progress_text: [160:0]u8 = [_:0]u8{0} ** 160,
    opened_path: [1024]u8 = undefined, // o avião que o Python já tem aberto
    opened_len: usize = 0,

    /// abre o Python na pasta do repositório (onde está `aerosim/bridge.py`) e espera a linha de pronto
    pub fn start(bridge: *Bridge, io: std.Io, memory: std.mem.Allocator) !void {
        if (bridge.child != null) return;
        if (ui_kit.system.in_browser) return Error.NotInBrowser;
        var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = findRepository(io, &folder_buffer) orelse {
            std.debug.print("ponte: não achei aerosim/bridge.py subindo da pasta atual\n", .{});
            return Error.PythonNotFound;
        };
        const candidates = [_][]const u8{ "python3", "python" };
        for (candidates) |program| {
            const child = std.process.spawn(io, .{
                .argv = &.{ program, "-m", "aerosim.bridge" },
                .cwd = .{ .path = root },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            }) catch |err| {
                std.debug.print("ponte: {s} não abriu: {s}\n", .{ program, @errorName(err) });
                continue;
            };
            bridge.child = child;
            bridge.reader = child.stdout.?.readerStreaming(io, &bridge.read_buffer);
            bridge.opened_len = 0;
            // a primeira linha é {"id": 0, "ok": true, "ready": true}
            var arena = std.heap.ArenaAllocator.init(memory);
            defer arena.deinit();
            _ = bridge.readReply(arena.allocator(), 0) catch |err| {
                bridge.stop(io);
                return err;
            };
            return;
        }
        return Error.PythonNotFound;
    }

    /// fecha a entrada do Python (ele sai sozinho) e espera o processo
    pub fn stop(bridge: *Bridge, io: std.Io) void {
        var child = bridge.child orelse return;
        bridge.child = null;
        if (child.stdin) |stdin| stdin.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
    }

    /// manda `{"id": n, <campos>}` (o texto de `fields` já em JSON, sem as chaves de fora) e devolve a resposta,
    /// no `memory` de quem chama. Resposta com `"ok": false` vira `error.BadReply`, com o texto em `failure`
    pub fn request(bridge: *Bridge, io: std.Io, memory: std.mem.Allocator, fields: []const u8, failure: *[240:0]u8) !std.json.Value {
        const child = bridge.child orelse return Error.NotStarted;
        const id = bridge.next_id;
        bridge.next_id += 1;
        bridge.progress.store(0, .release);
        const line = try std.fmt.allocPrint(memory, "{{\"id\": {d}, {s}}}\n", .{ id, fields });
        child.stdin.?.writeStreamingAll(io, line) catch return Error.BridgeClosed;
        const reply = try bridge.readReply(memory, id);
        if (reply.object.get("ok")) |ok| if (ok == .bool and ok.bool) return reply;
        const text = if (reply.object.get("error")) |message| (if (message == .string) message.string else "erro sem texto") else "erro sem texto";
        _ = std.fmt.bufPrintZ(failure, "{s}", .{text[0..@min(text.len, failure.len - 1)]}) catch {};
        return Error.BadReply;
    }

    /// pede para parar a rodada em andamento (a resposta dela chega como "cancelado")
    pub fn cancel(bridge: *Bridge, io: std.Io) void {
        const child = bridge.child orelse return;
        child.stdin.?.writeStreamingAll(io, "{\"op\": \"cancel\"}\n") catch {};
    }

    /// verdadeiro se o Python já tem este avião aberto
    pub fn hasOpened(bridge: *const Bridge, path: []const u8) bool {
        return std.mem.eql(u8, bridge.opened_path[0..bridge.opened_len], path);
    }

    /// guarda qual avião o Python tem aberto
    pub fn markOpened(bridge: *Bridge, path: []const u8) void {
        const length = @min(path.len, bridge.opened_path.len);
        @memcpy(bridge.opened_path[0..length], path[0..length]);
        bridge.opened_len = length;
    }

    /// lê linhas até a resposta do pedido `id` (as de progresso no caminho vão para `progress`)
    fn readReply(bridge: *Bridge, memory: std.mem.Allocator, id: u32) !std.json.Value {
        var line: std.Io.Writer.Allocating = .init(memory);
        while (true) {
            line.clearRetainingCapacity();
            _ = bridge.reader.interface.streamDelimiter(&line.writer, '\n') catch return Error.BridgeClosed;
            bridge.reader.interface.toss(1);
            const value = std.json.parseFromSliceLeaky(std.json.Value, memory, line.written(), .{ .allocate = .alloc_always }) catch return Error.BadReply;
            if (value != .object) return Error.BadReply;
            const reply_id = value.object.get("id") orelse continue;
            if (reply_id != .integer or reply_id.integer != id) continue;
            if (value.object.get("progress")) |fraction| {
                const number: f64 = switch (fraction) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => 0,
                };
                bridge.progress.store(@intFromFloat(std.math.clamp(number, 0, 1) * 1000), .release);
                if (value.object.get("message")) |message| if (message == .string) {
                    _ = std.fmt.bufPrintZ(&bridge.progress_text, "{s}", .{message.string[0..@min(message.string.len, bridge.progress_text.len - 1)]}) catch {};
                };
                continue;
            }
            return value;
        }
    }
};

/// a pasta do repositório: a primeira, subindo a partir da atual, que tem `aerosim/bridge.py`
fn findRepository(io: std.Io, buffer: []u8) ?[]const u8 {
    const length = std.process.currentPath(io, buffer) catch return null;
    var folder: []const u8 = buffer[0..length];
    while (true) {
        var probe: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&probe, "{s}/aerosim/bridge.py", .{folder}) catch return null;
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return folder else |_| {}
        folder = std.fs.path.dirname(folder) orelse return null;
    }
}

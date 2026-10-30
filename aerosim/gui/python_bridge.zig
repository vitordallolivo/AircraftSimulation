//! A ponte com os managers em Python (`aerosim/bridge.py`): a tela abre `python -m aerosim.bridge` como processo
//! filho e conversa por uma mensagem JSON por linha, na entrada e na saída padrão dele. Aqui só se manda o pedido e
//! se lê a resposta; quem desenha é `page.zig`, e quem calcula é o Python (que chama o núcleo).
//!
//! Um processo serve todas as abas. Cada pedido leva um número (`id`), e uma thread lê as respostas e entrega cada
//! uma a quem pediu (um `Waiter`), porque o Python responde fora de ordem: uma rodada longa não segura as outras abas.
//! Quem chama `request` está numa `Job` (`ui/jobs.zig`), fora do laço da tela, e espera ali a resposta dele. As
//! linhas de progresso que chegam antes atualizam o `Waiter`, que a tela lê a cada quadro.
//! No navegador não há processo filho: lá a ponte vai ser o Pyodide num web worker (a etapa seguinte do plano).
const std = @import("std");
const ui_kit = @import("ui");

pub const Error = error{ NotStarted, PythonNotFound, BridgeClosed, BadReply, NotInBrowser };

const max_waiting = 32;

/// um pedido em andamento: a resposta chega aqui, na memória de quem pediu
pub const Waiter = struct {
    id: u32 = 0,
    memory: std.mem.Allocator = undefined,
    reply: ?std.json.Value = null,
    done: std.atomic.Value(bool) = .init(false),
    progress: std.atomic.Value(u32) = .init(0), // fração × 1000 de uma rodada
    progress_text: [160:0]u8 = [_:0]u8{0} ** 160,
    failure: [240:0]u8 = [_:0]u8{0} ** 240,

    /// o progresso de 0 a 1
    pub fn fraction(waiter: *const Waiter) f32 {
        return @as(f32, @floatFromInt(waiter.progress.load(.acquire))) / 1000;
    }
};

/// o processo do Python, quem lê a saída dele e quem espera resposta
pub const Bridge = struct {
    child: ?std.process.Child = null,
    io: std.Io = undefined,
    read_buffer: [1 << 16]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    reader_thread: ?std.Thread = null,
    next_id: std.atomic.Value(u32) = .init(1),
    start_lock: std.Io.Mutex = .init,
    write_lock: std.Io.Mutex = .init,
    waiting_lock: std.Io.Mutex = .init,
    waiting: [max_waiting]?*Waiter = [_]?*Waiter{null} ** max_waiting,
    closed: std.atomic.Value(bool) = .init(false),
    opened_path: [1024]u8 = undefined, // o avião que o Python já tem aberto
    opened_len: usize = 0,
    open_lock: std.Io.Mutex = .init,

    /// abre o Python na pasta do repositório (onde está `aerosim/bridge.py`), espera a linha de pronto e põe a
    /// thread de leitura para rodar; `io` é a do processo (o Python herda o ambiente dela)
    pub fn start(bridge: *Bridge, io: std.Io) !void {
        if (ui_kit.system.in_browser) return Error.NotInBrowser;
        bridge.start_lock.lockUncancelable(io);
        defer bridge.start_lock.unlock(io);
        if (bridge.child != null and !bridge.closed.load(.acquire)) return;
        bridge.io = io;
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
            bridge.closed.store(false, .release);
            // a primeira linha é {"id": 0, "ok": true, "ready": true}
            var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer line.deinit();
            bridge.readLine(&line) catch {
                bridge.stop();
                continue;
            };
            bridge.reader_thread = std.Thread.spawn(.{}, readLoop, .{bridge}) catch return Error.BridgeClosed;
            return;
        }
        return Error.PythonNotFound;
    }

    /// fecha a entrada do Python (ele sai sozinho) e espera o processo
    pub fn stop(bridge: *Bridge) void {
        var child = bridge.child orelse return;
        bridge.child = null;
        if (child.stdin) |stdin| stdin.close(bridge.io);
        child.stdin = null;
        _ = child.wait(bridge.io) catch {};
    }

    /// manda `{"id": n, <campos>}` (`fields`: o JSON do pedido sem as chaves de fora) e espera a resposta, que fica
    /// em `waiter.reply`, na `waiter.memory`. Resposta com `"ok": false` vira `error.BadReply`, com o texto em
    /// `waiter.failure`
    pub fn request(bridge: *Bridge, waiter: *Waiter, fields: []const u8) !std.json.Value {
        const child = bridge.child orelse return Error.NotStarted;
        waiter.id = bridge.next_id.fetchAdd(1, .monotonic);
        waiter.reply = null;
        waiter.done.store(false, .release);
        waiter.progress.store(0, .release);
        waiter.progress_text[0] = 0;
        waiter.failure[0] = 0;
        if (!bridge.enlist(waiter)) return Error.BridgeClosed;
        const line = try std.fmt.allocPrint(waiter.memory, "{{\"id\": {d}, {s}}}\n", .{ waiter.id, fields });
        {
            bridge.write_lock.lockUncancelable(bridge.io);
            defer bridge.write_lock.unlock(bridge.io);
            child.stdin.?.writeStreamingAll(bridge.io, line) catch {
                bridge.delist(waiter);
                return Error.BridgeClosed;
            };
        }
        while (!waiter.done.load(.acquire)) std.Io.sleep(bridge.io, .fromMilliseconds(2), .awake) catch {};
        const reply = waiter.reply orelse return Error.BridgeClosed;
        if (reply.object.get("ok")) |ok| if (ok == .bool and ok.bool) return reply;
        const text = if (reply.object.get("error")) |message| (if (message == .string) message.string else "erro sem texto") else "erro sem texto";
        _ = std.fmt.bufPrintZ(&waiter.failure, "{s}", .{text[0..@min(text.len, waiter.failure.len - 1)]}) catch {};
        return Error.BadReply;
    }

    /// faz o Python abrir o avião `path`, se ainda não é o que ele tem aberto (uma aba de cada vez)
    pub fn openAircraft(bridge: *Bridge, waiter: *Waiter, path: []const u8) !void {
        if (path.len == 0) return;
        bridge.open_lock.lockUncancelable(bridge.io);
        defer bridge.open_lock.unlock(bridge.io);
        if (std.mem.eql(u8, bridge.opened_path[0..bridge.opened_len], path)) return;
        const fields = try std.fmt.allocPrint(waiter.memory, "\"op\": \"open\", \"path\": {f}", .{std.json.fmt(path, .{})});
        _ = try bridge.request(waiter, fields);
        const length = @min(path.len, bridge.opened_path.len);
        @memcpy(bridge.opened_path[0..length], path[0..length]);
        bridge.opened_len = length;
    }

    /// pede para parar a rodada de `waiter` (a resposta dela chega como "cancelado")
    pub fn cancel(bridge: *Bridge, waiter: *const Waiter) void {
        const child = bridge.child orelse return;
        var text: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&text, "{{\"op\": \"cancel\", \"target\": {d}}}\n", .{waiter.id}) catch return;
        bridge.write_lock.lockUncancelable(bridge.io);
        defer bridge.write_lock.unlock(bridge.io);
        child.stdin.?.writeStreamingAll(bridge.io, line) catch {};
    }

    fn enlist(bridge: *Bridge, waiter: *Waiter) bool {
        bridge.waiting_lock.lockUncancelable(bridge.io);
        defer bridge.waiting_lock.unlock(bridge.io);
        for (&bridge.waiting) |*slot| if (slot.* == null) {
            slot.* = waiter;
            return true;
        };
        return false;
    }

    fn delist(bridge: *Bridge, waiter: *Waiter) void {
        bridge.waiting_lock.lockUncancelable(bridge.io);
        defer bridge.waiting_lock.unlock(bridge.io);
        for (&bridge.waiting) |*slot| if (slot.* == waiter) {
            slot.* = null;
        };
    }

    /// quem espera o pedido `id` (tirado da lista se `remove`)
    fn find(bridge: *Bridge, id: i64, remove: bool) ?*Waiter {
        bridge.waiting_lock.lockUncancelable(bridge.io);
        defer bridge.waiting_lock.unlock(bridge.io);
        for (&bridge.waiting) |*slot| if (slot.*) |waiter| if (waiter.id == id) {
            if (remove) slot.* = null;
            return waiter;
        };
        return null;
    }

    fn readLine(bridge: *Bridge, line: *std.Io.Writer.Allocating) !void {
        line.clearRetainingCapacity();
        _ = bridge.reader.interface.streamDelimiter(&line.writer, '\n') catch return Error.BridgeClosed;
        bridge.reader.interface.toss(1);
    }

    /// a thread de leitura: cada linha vai para quem pediu; quando o Python fecha, todos os que esperam acordam sem
    /// resposta
    fn readLoop(bridge: *Bridge) void {
        var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer line.deinit();
        while (true) {
            bridge.readLine(&line) catch break;
            const id = lineId(line.written()) orelse continue;
            if (isProgress(line.written())) {
                const waiter = bridge.find(id, false) orelse continue;
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const value = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line.written(), .{}) catch continue;
                if (value != .object) continue;
                const number: f64 = switch (value.object.get("progress") orelse .null) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => 0,
                };
                waiter.progress.store(@intFromFloat(std.math.clamp(number, 0, 1) * 1000), .release);
                if (value.object.get("message")) |message| if (message == .string) {
                    _ = std.fmt.bufPrintZ(&waiter.progress_text, "{s}", .{message.string[0..@min(message.string.len, waiter.progress_text.len - 1)]}) catch {};
                };
                continue;
            }
            const waiter = bridge.find(id, true) orelse continue;
            const value = std.json.parseFromSliceLeaky(std.json.Value, waiter.memory, line.written(), .{ .allocate = .alloc_always }) catch null;
            waiter.reply = if (value != null and value.? == .object) value else null;
            waiter.done.store(true, .release);
        }
        bridge.closed.store(true, .release);
        bridge.waiting_lock.lockUncancelable(bridge.io);
        defer bridge.waiting_lock.unlock(bridge.io);
        for (&bridge.waiting) |*slot| if (slot.*) |waiter| {
            waiter.reply = null;
            waiter.done.store(true, .release);
            slot.* = null;
        };
    }
};

/// o `id` de uma linha sem ler o JSON inteiro (ele vem primeiro: {"id": 12, ...})
fn lineId(line: []const u8) ?i64 {
    const start = (std.mem.indexOf(u8, line, "\"id\":") orelse return null) + 5;
    var end = start;
    while (end < line.len and (line[end] == ' ' or line[end] == '-' or std.ascii.isDigit(line[end]))) end += 1;
    return std.fmt.parseInt(i64, std.mem.trim(u8, line[start..end], " "), 10) catch null;
}

/// uma linha de progresso ({"id", "progress", "message"}) e não a resposta
fn isProgress(line: []const u8) bool {
    return std.mem.indexOf(u8, line[0..@min(line.len, 40)], "\"progress\":") != null;
}

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

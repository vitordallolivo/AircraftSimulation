//! A ponte com os métodos de fora do núcleo (lltdrek, AeroSandbox, AVL), que são bibliotecas em Python: a tela abre
//! `python -m aerosim.bridge` (o adaptador) como processo filho e conversa por uma mensagem JSON por linha, na
//! entrada e na saída padrão dele. Aqui só se manda o pedido e se lê a resposta; quem pede é a análise
//! (`simulation.External`), e quem desenha é `page.zig`.
//!
//! Um processo serve todas as abas. Cada pedido leva um número (`id`), e uma thread lê as respostas e entrega cada
//! uma a quem pediu (um `Waiter`), porque o Python responde fora de ordem: uma rodada longa não segura as outras abas.
//! Quem chama `request` está numa `Job` (`ui/jobs.zig`), fora do laço da tela, e espera ali a resposta dele. As
//! linhas de progresso que chegam antes atualizam o `Waiter`, que a tela lê a cada quadro.
//! No navegador não há processo filho nem thread: o Pyodide roda o mesmo `aerosim/bridge.py` na página
//! (`aerosim/gui/web/python.html`, num iframe), e cada pedido é uma chamada ao JavaScript que volta já com a resposta
//! (`Module.pythonCall`). A tela fica parada enquanto a conta roda, como as outras contas longas no navegador.
//! No pacote instalável (`zig build pacote`) o Python vem junto, na pasta `app/` ao lado do programa (`app/python`,
//! com o adaptador e as bibliotecas); a ponte usa esse antes do Python do sistema.
const std = @import("std");
const builtin = @import("builtin");
const ui_kit = @import("ui");

pub const Error = error{ NotStarted, PythonNotFound, BridgeClosed, BadReply, PythonLoading };

const in_browser = ui_kit.system.in_browser;
const emscripten = std.os.emscripten;

const max_waiting = 32;

/// o Python que o pacote instalável leva, relativo à pasta `app/`
const bundled_python = if (builtin.os.tag == .windows) "python/python.exe" else "python/bin/python3";

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
    browser_ready: bool = false, // no navegador: o Pyodide da página já respondeu que está pronto

    /// abre o Python na pasta do repositório (onde está `aerosim/bridge.py`), espera a linha de pronto e põe a
    /// thread de leitura para rodar; `process` é a `Io` do processo (o Python herda o ambiente dela). No navegador
    /// só confere se a página já carregou o Python (`error.PythonLoading` enquanto não)
    pub fn start(bridge: *Bridge, process: ?std.Io) !void {
        if (in_browser) {
            if (bridge.browser_ready) return;
            bridge.io = ui_kit.system.io();
            // 1 pronto, 0 carregando, -2 falhou (`aerosim/gui/web/python.html`)
            switch (emscripten.emscripten_run_script_int("Module.pythonState ? Module.pythonState() : 0")) {
                1 => bridge.browser_ready = true,
                0 => return Error.PythonLoading,
                else => return Error.PythonNotFound,
            }
            return;
        }
        const io = process orelse return Error.NotStarted;
        bridge.start_lock.lockUncancelable(io);
        defer bridge.start_lock.unlock(io);
        if (bridge.child != null and !bridge.closed.load(.acquire)) return;
        bridge.io = io;
        var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = findRepository(io, &folder_buffer) orelse {
            std.debug.print("ponte: não achei aerosim/bridge.py subindo da pasta atual\n", .{});
            return Error.PythonNotFound;
        };
        var bundled_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const bundled = std.fmt.bufPrint(&bundled_buffer, "{s}/{s}", .{ root, bundled_python }) catch "";
        const has_bundled = bundled.len > 0 and if (std.Io.Dir.cwd().access(io, bundled, .{})) |_| true else |_| false;
        const candidates = [_][]const u8{ if (has_bundled) bundled else "python3", "python3", "python" };
        for (candidates) |program| {
            const child = std.process.spawn(io, .{
                .argv = &.{ program, "-m", "aerosim.bridge" },
                .cwd = .{ .path = root },
                .create_no_window = true, // no Windows, o Python não abre uma janela de console
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            }) catch |err| {
                std.debug.print("ponte: {s} não abriu: {s}\n", .{ program, @errorName(err) });
                continue;
            };
            bridge.child = child;
            bridge.reader = child.stdout.?.readerStreaming(io, &bridge.read_buffer);
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

    /// o "Parar" de emergência: mata o Python no meio da conta (o pedido que esperava volta sem resposta); o
    /// próximo pedido abre outro
    pub fn kill(bridge: *Bridge) void {
        if (in_browser) return;
        var child = bridge.child orelse return;
        bridge.child = null;
        bridge.write_lock.lockUncancelable(bridge.io);
        defer bridge.write_lock.unlock(bridge.io);
        child.kill(bridge.io);
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
        if (in_browser) return bridge.requestInPage(waiter, fields);
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
        return checkReply(waiter);
    }

    /// o pedido no navegador: o JSON vai como objeto para `Module.pythonCall` (JSON é JavaScript válido) e a resposta
    /// volta como texto, na hora
    fn requestInPage(bridge: *Bridge, waiter: *Waiter, fields: []const u8) !std.json.Value {
        if (!bridge.browser_ready) return Error.NotStarted;
        waiter.id = bridge.next_id.fetchAdd(1, .monotonic);
        waiter.reply = null;
        waiter.failure[0] = 0;
        const script = try std.fmt.allocPrintSentinel(waiter.memory, "Module.pythonCall({{\"id\": {d}, {s}}})", .{ waiter.id, fields }, 0);
        const answer = emscripten.emscripten_run_script_string(script.ptr) orelse return Error.BridgeClosed;
        const value = std.json.parseFromSliceLeaky(std.json.Value, waiter.memory, std.mem.sliceTo(answer, 0), .{ .allocate = .alloc_always }) catch return Error.BadReply;
        waiter.reply = if (value == .object) value else return Error.BadReply;
        waiter.done.store(true, .release);
        return checkReply(waiter);
    }

    /// a resposta guardada em `waiter`, ou `error.BadReply` com o texto do erro em `waiter.failure`
    fn checkReply(waiter: *Waiter) !std.json.Value {
        const reply = waiter.reply orelse return Error.BridgeClosed;
        if (reply.object.get("ok")) |ok| if (ok == .bool and ok.bool) return reply;
        const text = if (reply.object.get("error")) |message| (if (message == .string) message.string else "erro sem texto") else "erro sem texto";
        _ = std.fmt.bufPrintZ(&waiter.failure, "{s}", .{text[0..@min(text.len, waiter.failure.len - 1)]}) catch {};
        return Error.BadReply;
    }

    /// pede para parar a rodada de `waiter` (a resposta dela chega como "cancelado")
    pub fn cancel(bridge: *Bridge, waiter: *const Waiter) void {
        if (in_browser) return; // no navegador nada roda junto com a conta: não há como pedir
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

/// a pasta onde está `aerosim/bridge.py`: a `app/` ao lado do programa (o pacote instalável) ou a primeira, subindo
/// a partir da atual (o repositório)
fn findRepository(io: std.Io, buffer: []u8) ?[]const u8 {
    if (std.process.executableDirPath(io, buffer)) |length| {
        if (std.fmt.bufPrint(buffer[length..], "/app", .{})) |added| {
            const app = buffer[0 .. length + added.len];
            var probe: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrint(&probe, "{s}/aerosim/bridge.py", .{app})) |path| {
                if (std.Io.Dir.cwd().access(io, path, .{})) |_| return app else |_| {}
            } else |_| {}
        } else |_| {}
    } else |_| {}
    const length = std.process.currentPath(io, buffer) catch return null;
    var folder: []const u8 = buffer[0..length];
    while (true) {
        var probe: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&probe, "{s}/aerosim/bridge.py", .{folder}) catch return null;
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return folder else |_| {}
        folder = std.fs.path.dirname(folder) orelse return null;
    }
}

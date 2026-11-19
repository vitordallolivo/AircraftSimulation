//! As contas longas fora do laço da tela: uma `Job` roda uma função numa thread própria, e a tela continua
//! desenhando e respondendo enquanto isso (a GUI não faz conta, só pede e mostra). Quando a thread acaba, a tela
//! pega o resultado no próximo quadro (`finished`). No print (`--shot`) e onde não há threads (a web), a função roda
//! na hora, no mesmo lugar.
const std = @import("std");
const builtin = @import("builtin");

/// sem threads neste alvo (a web): as contas rodam sempre na hora
const no_threads = builtin.single_threaded or builtin.target.cpu.arch.isWasm();

/// verdadeiro: as contas rodam na hora, sem thread (o `--shot` liga, para o print sair com o resultado)
pub var synchronous: bool = no_threads;

pub const Job = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    active: bool = false,
    started_at: i128 = 0,

    /// roda `function(args...)` numa thread; falso se outra conta ainda está rodando
    pub fn start(job: *Job, comptime function: anytype, args: anytype) bool {
        if (job.active) return false;
        job.active = true;
        job.done.store(false, .release);
        if (no_threads or synchronous) {
            @call(.auto, function, args);
            job.done.store(true, .release);
            return true;
        }
        const Wrapper = struct {
            fn run(owner: *Job, inner: @TypeOf(args)) void {
                @call(.auto, function, inner);
                owner.done.store(true, .release);
            }
        };
        job.thread = std.Thread.spawn(.{}, Wrapper.run, .{ job, args }) catch {
            // sem thread: roda aqui mesmo
            @call(.auto, function, args);
            job.done.store(true, .release);
            return true;
        };
        return true;
    }

    /// verdadeiro enquanto a conta roda
    pub fn running(job: *const Job) bool {
        return job.active and !job.done.load(.acquire);
    }

    /// verdadeiro uma vez, no primeiro quadro depois que a conta acabou (a thread já foi recolhida)
    pub fn finished(job: *Job) bool {
        if (!job.active or !job.done.load(.acquire)) return false;
        if (job.thread) |thread| thread.join();
        job.thread = null;
        job.active = false;
        return true;
    }

    /// espera a conta acabar e joga o resultado fora (antes de trocar o que ela está lendo, como o avião aberto)
    pub fn cancel(job: *Job) void {
        if (job.thread) |thread| thread.join();
        job.thread = null;
        job.active = false;
    }
};

/// verdadeiro onde há threads (o programa instalado); na web as contas andam em fatias no quadro
pub const threads_available = !no_threads;

/// a caixa de mensagens entre a thread da conta e a tela: uma fila de um produtor e um consumidor, sem trava. A conta
/// só escreve (`push`) e a tela só lê (`pop`), a cada quadro, como numa conexão de rede; nenhuma das duas espera a
/// outra. Cheia, `push` devolve falso e quem manda decide se descarta (o progresso) ou tenta de novo (o fim)
pub fn Mailbox(comptime Item: type, comptime size: usize) type {
    return struct {
        items: [size]Item = undefined,
        head: std.atomic.Value(usize) = .init(0), // o próximo a ler: só a tela escreve
        tail: std.atomic.Value(usize) = .init(0), // o próximo a escrever: só a conta escreve

        const Queue = @This();

        /// põe uma mensagem na fila (da thread da conta); falso se está cheia
        pub fn push(queue: *Queue, item: Item) bool {
            const tail = queue.tail.load(.monotonic);
            if (tail - queue.head.load(.acquire) == size) return false;
            queue.items[tail % size] = item;
            queue.tail.store(tail + 1, .release);
            return true;
        }

        /// tira a mensagem mais antiga (da tela); nulo se não há nenhuma
        pub fn pop(queue: *Queue) ?Item {
            const head = queue.head.load(.monotonic);
            if (head == queue.tail.load(.acquire)) return null;
            const item = queue.items[head % size];
            queue.head.store(head + 1, .release);
            return item;
        }
    };
}

test "a caixa de mensagens entrega na ordem e recusa cheia" {
    var box: Mailbox(u32, 4) = .{};
    for (0..4) |i| try std.testing.expect(box.push(@intCast(i)));
    try std.testing.expect(!box.push(9));
    for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), box.pop().?);
    try std.testing.expect(box.pop() == null);
}

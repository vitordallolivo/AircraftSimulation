//! O histórico do Ctrl+Z: cada mudança guarda antes uma cópia do estado em texto (o `.json` do avião, os valores
//! do formulário), e desfazer devolve a última. Guarda até `capacity` passos; o mais antigo sai quando enche.
//!
//!     var history: undo.History = .{};
//!     history.push(texto_antes_da_mudança);
//!     if (history.pop()) |anterior| { defer history.release(anterior); ... }
const std = @import("std");

/// quantos passos dá para desfazer
pub const capacity = 64;

/// a pilha dos estados anteriores, cada um uma cópia na memória do processo
pub const History = struct {
    steps: [capacity][]u8 = undefined,
    count: usize = 0,

    /// guarda uma cópia de `state` (o estado antes da mudança); o mesmo texto do topo não entra duas vezes
    pub fn push(history: *History, state: []const u8) void {
        if (history.count > 0 and std.mem.eql(u8, history.steps[history.count - 1], state)) return;
        const copy = std.heap.page_allocator.dupe(u8, state) catch return;
        if (history.count == capacity) {
            std.heap.page_allocator.free(history.steps[0]);
            std.mem.copyForwards([]u8, history.steps[0 .. capacity - 1], history.steps[1..capacity]);
            history.count -= 1;
        }
        history.steps[history.count] = copy;
        history.count += 1;
    }

    /// tira o último estado guardado (nulo: nada para desfazer); devolver com `release` depois de usar
    pub fn pop(history: *History) ?[]u8 {
        if (history.count == 0) return null;
        history.count -= 1;
        return history.steps[history.count];
    }

    /// solta um estado tirado com `pop`
    pub fn release(history: *History, state: []u8) void {
        _ = history;
        std.heap.page_allocator.free(state);
    }

    /// esquece tudo (outro avião aberto)
    pub fn clear(history: *History) void {
        while (history.pop()) |state| history.release(state);
    }
};

/// Ctrl+Z (ou Cmd+Z) apertado neste quadro
pub fn pressed() bool {
    const rl = @import("raylib");
    const control = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
    return control and rl.isKeyPressed(.z);
}

test "desfazer devolve na ordem inversa e não repete o topo" {
    var history: History = .{};
    defer history.clear();
    history.push("a");
    history.push("b");
    history.push("b");
    try std.testing.expectEqual(@as(usize, 2), history.count);
    const last = history.pop().?;
    defer history.release(last);
    try std.testing.expectEqualStrings("b", last);
    for (0..capacity + 3) |_| history.push(if (history.count % 2 == 0) "x" else "y");
    try std.testing.expectEqual(@as(usize, capacity), history.count);
}

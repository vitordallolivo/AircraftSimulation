//! Executa o programa de pilha da pontuação (`types.Program`): as entradas de um candidato entram nas
//! primeiras vagas, e cada operação lê e escreve vagas e a pilha. No fim, todas as vagas (constantes,
//! faixas, termos, nota, condições de validade) ficam preenchidas, para a GUI mostrar a nota fator por fator.
//!
//! `check` confere o programa uma vez (índices, profundidade da pilha, vaga lida antes de escrita); depois
//! `run` só faz contas, sem conferir de novo. As funções são as da std (`@exp`, `std.math.pow`): a nota de
//! um regulamento precisa sair igual à conta à mão, e as tabelas rápidas do `fmath` não garantem isso.
const std = @import("std");
const T = @import("types.zig");

pub const Error = enum(i32) {
    ok = 0,
    bad_size = -1, // contadores fora dos limites
    bad_op = -2,
    bad_index = -3, // constante, vaga ou faixa que não existe
    stack = -4, // pilha estoura, falta operando ou sobra valor
    read_before_write = -5,
    double_write = -6,
};

pub fn check(p: *const T.Program) Error {
    if (p.n_ops < 0 or p.n_ops > T.max_ops or p.n_consts < 0 or p.n_consts > T.max_consts or
        p.n_tiers < 0 or p.n_tiers > T.max_tiers or p.n_inputs < 0 or p.n_slots < p.n_inputs or
        p.n_slots > T.max_slots) return .bad_size;
    for (p.tiers[0..@intCast(p.n_tiers)]) |t| if (t.n < 0 or t.n > T.max_steps) return .bad_size;
    var written: [T.max_slots]bool = @splat(false);
    for (0..@intCast(p.n_inputs)) |i| written[i] = true;
    var depth: i32 = 0;
    for (p.ops[0..@intCast(p.n_ops)], p.args[0..@intCast(p.n_ops)]) |code, a| {
        const op = std.enums.fromInt(T.Op, code) orelse return .bad_op;
        switch (op) {
            .@"const" => {
                if (a < 0 or a >= p.n_consts) return .bad_index;
                depth += 1;
            },
            .load => {
                if (a < 0 or a >= p.n_slots) return .bad_index;
                if (!written[@intCast(a)]) return .read_before_write;
                depth += 1;
            },
            .store => {
                if (a < 0 or a >= p.n_slots) return .bad_index;
                if (written[@intCast(a)]) return .double_write;
                written[@intCast(a)] = true;
                depth -= 1;
            },
            .add, .sub, .mul, .div, .pow, .min, .max => depth -= 1,
            .neg, .exp, .abs => {},
            .tier => if (a < 0 or a >= p.n_tiers) return .bad_index,
        }
        const need: i32 = switch (op) {
            .@"const", .load => 0,
            .add, .sub, .mul, .div, .pow, .min, .max => 1, // depois de tirar um, sobra pelo menos um
            else => 0,
        };
        if (depth < need or depth > T.max_stack) return .stack;
        if (op != .@"const" and op != .load and depth < 0) return .stack;
    }
    return if (depth == 0) .ok else .stack;
}

fn tier(t: *const T.Tier, x: f64) f64 {
    for (t.limits[0..@intCast(t.n)], t.values[0..@intCast(t.n)]) |lim, v| {
        if (x <= lim) return v;
    }
    return t.outside;
}

/// calcula todas as vagas; `slots[0..n_inputs]` já trazem as entradas. O programa tem de ter passado no `check`
pub fn run(p: *const T.Program, slots: *[T.max_slots]f64) void {
    var st: [T.max_stack]f64 = undefined;
    var sp: usize = 0;
    for (p.ops[0..@intCast(p.n_ops)], p.args[0..@intCast(p.n_ops)]) |code, a| {
        const op: T.Op = @enumFromInt(code);
        const ua: usize = @intCast(@max(a, 0));
        switch (op) {
            .@"const" => {
                st[sp] = p.consts[ua];
                sp += 1;
            },
            .load => {
                st[sp] = slots[ua];
                sp += 1;
            },
            .store => {
                sp -= 1;
                slots[ua] = st[sp];
            },
            .add, .sub, .mul, .div, .pow, .min, .max => {
                sp -= 1;
                const y = st[sp];
                const x = st[sp - 1];
                st[sp - 1] = switch (op) {
                    .add => x + y,
                    .sub => x - y,
                    .mul => x * y,
                    .div => x / y,
                    .pow => std.math.pow(f64, x, y),
                    .min => @min(x, y),
                    .max => @max(x, y),
                    else => unreachable,
                };
            },
            .neg => st[sp - 1] = -st[sp - 1],
            .exp => st[sp - 1] = @exp(st[sp - 1]),
            .abs => st[sp - 1] = @abs(st[sp - 1]),
            .tier => st[sp - 1] = tier(&p.tiers[ua], st[sp - 1]),
        }
    }
}

/// vários candidatos de uma vez: a linha k das entradas começa em `inputs[k * in_stride]` e as vagas dela
/// vão para `out[k * out_stride ..][0..n_slots]`
pub fn runMany(p: *const T.Program, inputs: []const f64, in_stride: usize, rows: usize, out: []f64, out_stride: usize) void {
    const ni: usize = @intCast(p.n_inputs);
    const ns: usize = @intCast(p.n_slots);
    var slots: [T.max_slots]f64 = undefined;
    for (0..rows) |k| {
        @memcpy(slots[0..ni], inputs[k * in_stride ..][0..ni]);
        run(p, &slots);
        @memcpy(out[k * out_stride ..][0..ns], slots[0..ns]);
    }
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

fn program(ops: []const T.Op, args: []const i32, consts: []const f64, n_inputs: i32, n_slots: i32) T.Program {
    var p: T.Program = .{};
    for (ops, args, 0..) |o, a, i| {
        p.ops[i] = @intFromEnum(o);
        p.args[i] = a;
    }
    p.n_ops = @intCast(ops.len);
    @memcpy(p.consts[0..consts.len], consts);
    p.n_consts = @intCast(consts.len);
    p.n_inputs = n_inputs;
    p.n_slots = n_slots;
    return p;
}

test "F_Bat do regulamento da Micro 2026 (eq. 9.4) escrito à mão como programa" {
    // f = max(0.2, 0.85 / (0.85 + exp((1000 m - 298) / 37.7 - 4.8)))
    const p = program(
        &.{ .@"const", .@"const", .@"const", .@"const", .load, .mul, .@"const", .sub, .@"const", .div, .@"const", .sub, .exp, .add, .div, .max, .store },
        &.{ 0, 1, 1, 2, 0, 0, 3, 0, 4, 0, 5, 0, 0, 0, 0, 0, 1 },
        &.{ 0.2, 0.85, 1000, 298, 37.7, 4.8 },
        1,
        2,
    );
    try testing.expectEqual(Error.ok, check(&p));
    // valores da eq. 9.4 e do texto da seção 9.8.4 (p. 87): ~1 até 300 g, ~0,8 em 420 g, 0,2 a partir de ~520 g
    const cases = [_][2]f64{ .{ 0.300, 0.989894 }, .{ 0.420, 0.802407 }, .{ 0.550, 0.2 } };
    for (cases) |c| {
        var s: [T.max_slots]f64 = undefined;
        s[0] = c[0];
        run(&p, &s);
        try testing.expectApproxEqAbs(c[1], s[1], 1e-6);
    }
}

test "faixa: primeiro limite que cabe, fora acima de todos e com NaN" {
    var p = program(&.{ .load, .tier, .store }, &.{ 0, 0, 1 }, &.{}, 1, 2);
    p.n_tiers = 1;
    p.tiers[0] = .{ .n = 3, .outside = 0 };
    p.tiers[0].limits[0..3].* = .{ 1, 4, 8 };
    p.tiers[0].values[0..3].* = .{ 250, 170, 110 };
    try testing.expectEqual(Error.ok, check(&p));
    for ([_][2]f64{ .{ 0.5, 250 }, .{ 1.0, 250 }, .{ 3.9, 170 }, .{ 8.0, 110 }, .{ 8.01, 0 }, .{ std.math.nan(f64), 0 } }) |c| {
        var s: [T.max_slots]f64 = undefined;
        s[0] = c[0];
        run(&p, &s);
        try testing.expectEqual(c[1], s[1]);
    }
}

test "check recusa programa malformado" {
    try testing.expectEqual(Error.stack, check(&program(&.{.add}, &.{0}, &.{}, 0, 0)));
    try testing.expectEqual(Error.stack, check(&program(&.{.load}, &.{0}, &.{}, 1, 1)));
    try testing.expectEqual(Error.read_before_write, check(&program(&.{ .load, .store }, &.{ 1, 2 }, &.{}, 1, 3)));
    try testing.expectEqual(Error.double_write, check(&program(&.{ .load, .store }, &.{ 0, 0 }, &.{}, 1, 1)));
    try testing.expectEqual(Error.bad_index, check(&program(&.{ .@"const", .store }, &.{ 3, 1 }, &.{1}, 1, 2)));
    var p = program(&.{}, &.{}, &.{}, 0, 0);
    p.ops[0] = 99;
    p.n_ops = 1;
    try testing.expectEqual(Error.bad_op, check(&p));
    p.n_slots = T.max_slots + 1;
    try testing.expectEqual(Error.bad_size, check(&p));
}

test "runMany dá o mesmo que run linha a linha" {
    const p = program(&.{ .load, .load, .mul, .store }, &.{ 0, 1, 0, 2 }, &.{}, 2, 3);
    const inp = [_]f64{ 1, 2, 0, 3, 4, 0, 5, 6, 0 };
    var out: [3 * 4]f64 = undefined;
    runMany(&p, &inp, 3, 3, &out, 4);
    for (0..3) |k| try testing.expectEqual(inp[3 * k] * inp[3 * k + 1], out[4 * k + 2]);
}

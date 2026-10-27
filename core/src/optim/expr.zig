//! Executa o programa de pilha da pontuação (`types.Program`): as entradas de um candidato entram nas
//! primeiras vagas, e cada operação lê e escreve vagas e a pilha. No fim, todas as vagas (constantes,
//! faixas, termos, nota, condições de validade) ficam preenchidas, para a GUI mostrar a nota fator por fator.
//!
//! `check` confere o programa uma vez (índices, profundidade da pilha, vaga lida antes de escrita); depois
//! `run` só faz contas, sem conferir de novo. As funções são as da std (`@exp`, `std.math.pow`): a nota de
//! um regulamento precisa sair igual à conta à mão, e as tabelas rápidas do `fmath` não garantem isso.
const std = @import("std");
const types = @import("types.zig");

pub const Error = enum(i32) {
    ok = 0,
    bad_size = -1, // contadores fora dos limites
    bad_op = -2,
    bad_index = -3, // constante, vaga ou faixa que não existe
    stack = -4, // pilha estoura, falta operando ou sobra valor
    read_before_write = -5,
    double_write = -6,
};

/// confere o programa uma vez (índices, profundidade da pilha, vaga lida antes de escrita); `.ok` se pode rodar
pub fn check(program: *const types.Program) Error {
    if (program.n_ops < 0 or program.n_ops > types.max_ops or program.n_consts < 0 or program.n_consts > types.max_consts or
        program.n_tiers < 0 or program.n_tiers > types.max_tiers or program.n_inputs < 0 or program.n_slots < program.n_inputs or
        program.n_slots > types.max_slots) return .bad_size;
    for (program.tiers[0..@intCast(program.n_tiers)]) |tier_def| if (tier_def.n < 0 or tier_def.n > types.max_steps) return .bad_size;
    var written: [types.max_slots]bool = @splat(false);
    for (0..@intCast(program.n_inputs)) |i| written[i] = true;
    var depth: i32 = 0;
    for (program.ops[0..@intCast(program.n_ops)], program.args[0..@intCast(program.n_ops)]) |code, arg| {
        const op = std.enums.fromInt(types.Op, code) orelse return .bad_op;
        switch (op) {
            .@"const" => {
                if (arg < 0 or arg >= program.n_consts) return .bad_index;
                depth += 1;
            },
            .load => {
                if (arg < 0 or arg >= program.n_slots) return .bad_index;
                if (!written[@intCast(arg)]) return .read_before_write;
                depth += 1;
            },
            .store => {
                if (arg < 0 or arg >= program.n_slots) return .bad_index;
                if (written[@intCast(arg)]) return .double_write;
                written[@intCast(arg)] = true;
                depth -= 1;
            },
            .add, .sub, .mul, .div, .pow, .min, .max => depth -= 1,
            .neg, .exp, .abs => {},
            .tier => if (arg < 0 or arg >= program.n_tiers) return .bad_index,
        }
        const need: i32 = switch (op) {
            .@"const", .load => 0,
            .add, .sub, .mul, .div, .pow, .min, .max => 1, // depois de tirar um, sobra pelo menos um
            else => 0,
        };
        if (depth < need or depth > types.max_stack) return .stack;
        if (op != .@"const" and op != .load and depth < 0) return .stack;
    }
    return if (depth == 0) .ok else .stack;
}

fn tier(tier_def: *const types.Tier, value: f64) f64 {
    for (tier_def.limits[0..@intCast(tier_def.n)], tier_def.values[0..@intCast(tier_def.n)]) |lim, tier_value| {
        if (value <= lim) return tier_value;
    }
    return tier_def.outside;
}

/// calcula todas as vagas; `slots[0..n_inputs]` já trazem as entradas. O programa tem de ter passado no `check`
pub fn run(program: *const types.Program, slots: *[types.max_slots]f64) void {
    var stack: [types.max_stack]f64 = undefined;
    var top: usize = 0;
    for (program.ops[0..@intCast(program.n_ops)], program.args[0..@intCast(program.n_ops)]) |code, arg| {
        const op: types.Op = @enumFromInt(code);
        const arg_index: usize = @intCast(@max(arg, 0));
        switch (op) {
            .@"const" => {
                stack[top] = program.consts[arg_index];
                top += 1;
            },
            .load => {
                stack[top] = slots[arg_index];
                top += 1;
            },
            .store => {
                top -= 1;
                slots[arg_index] = stack[top];
            },
            .add, .sub, .mul, .div, .pow, .min, .max => {
                top -= 1;
                const rhs = stack[top];
                const lhs = stack[top - 1];
                stack[top - 1] = switch (op) {
                    .add => lhs + rhs,
                    .sub => lhs - rhs,
                    .mul => lhs * rhs,
                    .div => lhs / rhs,
                    .pow => std.math.pow(f64, lhs, rhs),
                    .min => @min(lhs, rhs),
                    .max => @max(lhs, rhs),
                    else => unreachable,
                };
            },
            .neg => stack[top - 1] = -stack[top - 1],
            .exp => stack[top - 1] = @exp(stack[top - 1]),
            .abs => stack[top - 1] = @abs(stack[top - 1]),
            .tier => stack[top - 1] = tier(&program.tiers[arg_index], stack[top - 1]),
        }
    }
}

/// vários candidatos de uma vez: a linha k das entradas começa em `inputs[k * in_stride]` e as vagas dela
/// vão para `out[k * out_stride ..][0..n_slots]`
pub fn runMany(program: *const types.Program, inputs: []const f64, in_stride: usize, rows: usize, out: []f64, out_stride: usize) void {
    const input_count: usize = @intCast(program.n_inputs);
    const slot_count: usize = @intCast(program.n_slots);
    var slots: [types.max_slots]f64 = undefined;
    for (0..rows) |k| {
        @memcpy(slots[0..input_count], inputs[k * in_stride ..][0..input_count]);
        run(program, &slots);
        @memcpy(out[k * out_stride ..][0..slot_count], slots[0..slot_count]);
    }
}

// ------------------------------------------------------------------ testes
const testing = std.testing;

fn makeProgram(ops: []const types.Op, args: []const i32, consts: []const f64, n_inputs: i32, n_slots: i32) types.Program {
    var prog: types.Program = .{};
    for (ops, args, 0..) |op, arg, i| {
        prog.ops[i] = @intFromEnum(op);
        prog.args[i] = arg;
    }
    prog.n_ops = @intCast(ops.len);
    @memcpy(prog.consts[0..consts.len], consts);
    prog.n_consts = @intCast(consts.len);
    prog.n_inputs = n_inputs;
    prog.n_slots = n_slots;
    return prog;
}

test "F_Bat do regulamento da Micro 2026 (eq. 9.4) escrito à mão como programa" {
    // f = max(0.2, 0.85 / (0.85 + exp((1000 m - 298) / 37.7 - 4.8)))
    const prog = makeProgram(
        &.{ .@"const", .@"const", .@"const", .@"const", .load, .mul, .@"const", .sub, .@"const", .div, .@"const", .sub, .exp, .add, .div, .max, .store },
        &.{ 0, 1, 1, 2, 0, 0, 3, 0, 4, 0, 5, 0, 0, 0, 0, 0, 1 },
        &.{ 0.2, 0.85, 1000, 298, 37.7, 4.8 },
        1,
        2,
    );
    try testing.expectEqual(Error.ok, check(&prog));
    // valores da eq. 9.4 e do texto da seção 9.8.4 (p. 87): ~1 até 300 g, ~0,8 em 420 g, 0,2 a partir de ~520 g
    const cases = [_][2]f64{ .{ 0.300, 0.989894 }, .{ 0.420, 0.802407 }, .{ 0.550, 0.2 } };
    for (cases) |case| {
        var slots: [types.max_slots]f64 = undefined;
        slots[0] = case[0];
        run(&prog, &slots);
        try testing.expectApproxEqAbs(case[1], slots[1], 1e-6);
    }
}

test "faixa: primeiro limite que cabe, fora acima de todos e com NaN" {
    var prog = makeProgram(&.{ .load, .tier, .store }, &.{ 0, 0, 1 }, &.{}, 1, 2);
    prog.n_tiers = 1;
    prog.tiers[0] = .{ .n = 3, .outside = 0 };
    prog.tiers[0].limits[0..3].* = .{ 1, 4, 8 };
    prog.tiers[0].values[0..3].* = .{ 250, 170, 110 };
    try testing.expectEqual(Error.ok, check(&prog));
    for ([_][2]f64{ .{ 0.5, 250 }, .{ 1.0, 250 }, .{ 3.9, 170 }, .{ 8.0, 110 }, .{ 8.01, 0 }, .{ std.math.nan(f64), 0 } }) |case| {
        var slots: [types.max_slots]f64 = undefined;
        slots[0] = case[0];
        run(&prog, &slots);
        try testing.expectEqual(case[1], slots[1]);
    }
}

test "check recusa programa malformado" {
    try testing.expectEqual(Error.stack, check(&makeProgram(&.{.add}, &.{0}, &.{}, 0, 0)));
    try testing.expectEqual(Error.stack, check(&makeProgram(&.{.load}, &.{0}, &.{}, 1, 1)));
    try testing.expectEqual(Error.read_before_write, check(&makeProgram(&.{ .load, .store }, &.{ 1, 2 }, &.{}, 1, 3)));
    try testing.expectEqual(Error.double_write, check(&makeProgram(&.{ .load, .store }, &.{ 0, 0 }, &.{}, 1, 1)));
    try testing.expectEqual(Error.bad_index, check(&makeProgram(&.{ .@"const", .store }, &.{ 3, 1 }, &.{1}, 1, 2)));
    var prog = makeProgram(&.{}, &.{}, &.{}, 0, 0);
    prog.ops[0] = 99;
    prog.n_ops = 1;
    try testing.expectEqual(Error.bad_op, check(&prog));
    prog.n_slots = types.max_slots + 1;
    try testing.expectEqual(Error.bad_size, check(&prog));
}

test "runMany dá o mesmo que run linha a linha" {
    const prog = makeProgram(&.{ .load, .load, .mul, .store }, &.{ 0, 1, 0, 2 }, &.{}, 2, 3);
    const inp = [_]f64{ 1, 2, 0, 3, 4, 0, 5, 6, 0 };
    var out: [3 * 4]f64 = undefined;
    runMany(&prog, &inp, 3, 3, &out, 4);
    for (0..3) |k| try testing.expectEqual(inp[3 * k] * inp[3 * k + 1], out[4 * k + 2]);
}
